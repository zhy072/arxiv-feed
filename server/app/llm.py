"""LLM calls through the Codex CLI bundled with the ChatGPT desktop app (`codex exec`)."""
from __future__ import annotations

import json
import os
import re
import subprocess
import tempfile
import threading
import time
from html import unescape
from pathlib import Path

import httpx

from . import config


class CodexError(RuntimeError):
    pass


# Cap concurrent codex processes across summaries, pre-interpretation and on-demand requests.
_slots = threading.BoundedSemaphore(max(1, config.CODEX_MAX_CONCURRENCY))


def available() -> bool:
    return os.access(config.CODEX_BIN, os.X_OK)


def _env() -> dict:
    env = dict(os.environ)
    env.setdefault("HOME", str(Path.home()))
    env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:" + env.get("PATH", "")
    env["NO_COLOR"] = "1"
    return env


def run_codex(prompt: str, effort: str, schema: dict | None = None,
              timeout: int = 1800, attempts: int = 2) -> str:
    """Run one non-interactive Codex turn and return the agent's final message."""
    if not available():
        raise CodexError(f"codex CLI not found at {config.CODEX_BIN}")
    last: Exception | None = None
    for attempt in range(attempts):
        with tempfile.TemporaryDirectory(prefix="arxiv-codex-") as tmp:
            out = Path(tmp) / "last_message.txt"
            cmd = [
                config.CODEX_BIN, "exec",
                "--skip-git-repo-check", "--ignore-user-config", "--ephemeral",
                "--color", "never", "-s", "read-only", "-C", tmp,
                "-m", config.CODEX_MODEL,
                "-c", f"model_reasoning_effort={effort}",
                "-o", str(out),
            ]
            if schema is not None:
                schema_path = Path(tmp) / "schema.json"
                schema_path.write_text(json.dumps(schema), encoding="utf-8")
                cmd += ["--output-schema", str(schema_path)]
            cmd.append("-")  # prompt on stdin
            try:
                with _slots:
                    proc = subprocess.run(
                        cmd, input=prompt, capture_output=True, text=True,
                        timeout=timeout, env=_env(),
                    )
            except subprocess.TimeoutExpired as e:
                raise CodexError(f"codex timed out after {timeout}s") from e
            text = out.read_text(encoding="utf-8").strip() if out.exists() else ""
            if proc.returncode == 0 and text:
                return text
            tail = proc.stderr.strip()[-600:]
            last = CodexError(f"codex exit {proc.returncode} (empty={not text}): {tail}")
        time.sleep(5 * (attempt + 1))
    raise last  # type: ignore[misc]


def _parse_json(text: str):
    text = text.strip()
    text = re.sub(r"^```(?:json)?\s*", "", text)
    text = re.sub(r"\s*```$", "", text)
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass
    starts = [i for i in (text.find("{"), text.find("[")) if i >= 0]
    end = max(text.rfind("}"), text.rfind("]"))
    if not starts or end < 0:
        raise CodexError(f"no JSON in codex reply: {text[:200]!r}")
    return json.loads(text[min(starts) : end + 1])


# --- summaries -------------------------------------------------------------

SUMMARY_SCHEMA = {
    "type": "object",
    "properties": {
        "papers": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "id": {"type": "string"},
                    "tldr": {"type": "string"},
                    "tags": {"type": "array", "items": {"type": "string"}},
                    "task": {"type": "string"},
                    "method": {"type": "string"},
                    "labs": {"type": "array", "items": {"type": "string"}},
                },
                "required": ["id", "tldr", "tags", "task", "method", "labs"],
                "additionalProperties": False,
            },
        }
    },
    "required": ["papers"],
    "additionalProperties": False,
}

SUMMARIZE_PROMPT = """你是论文速览助手。下面有 {n} 篇 arXiv 论文，每篇给了 id、标题、作者和摘要（部分还给了论文首页的作者/机构片段）。请为每一篇输出：
- tldr：中文 2-3 句话速览——做了什么、怎么做的、效果如何。写给该领域研究者看，专业术语保留英文。
- tags：3-6 个细粒度标签（例如 "视频生成"、"全双工语音"、"KV cache 压缩" 这种粒度；不要 "深度学习"、"计算机视觉" 这类大词）。
- task：一句话描述该文解决的问题/任务。
- method：一句话描述核心方法/技术路线。
- labs：作者所属的机构/公司列表（英文规范简称，如 "Google DeepMind"、"Tsinghua University"、"ByteDance"），只根据给出的首页片段判断，最多 4 个；没有给首页片段或看不出来就输出 []，不要猜。

输出一个 JSON 对象：{{"papers": [{{"id": "...", "tldr": "...", "tags": ["..."], "task": "...", "method": "...", "labs": ["..."]}}, ...]}}。
id 必须与输入完全一致，每篇都要有，不要遗漏，不要输出其它内容。"""


def _norm_id(s: str) -> str:
    return re.sub(r"v\d+$", "", str(s or "").strip())


def summarize_batch(rows, snippets: dict | None = None) -> dict:
    """rows: sqlite rows with arxiv_id/title/abstract(/authors). snippets: {arxiv_id: first-page author block}.
    Returns {arxiv_id: summary} for usable replies (summary includes a `labs` list)."""
    rows = list(rows)
    parts = []
    for i, r in enumerate(rows):
        try:
            authors = ", ".join(json.loads(r["authors"] or "[]")[:12])
        except (KeyError, IndexError, TypeError, json.JSONDecodeError):
            authors = ""
        block = f"### 第 {i + 1} 篇\nid: {r['arxiv_id']}\n标题: {r['title']}\n作者: {authors}\n"
        snippet = (snippets or {}).get(r["arxiv_id"], "")
        if snippet:
            block += f"首页作者/机构片段: {snippet[:1500]}\n"
        block += f"摘要: {r['abstract']}"
        parts.append(block)
    prompt = SUMMARIZE_PROMPT.format(n=len(rows)) + "\n\n" + "\n\n".join(parts)
    reply = run_codex(prompt, config.SUMMARY_EFFORT, schema=SUMMARY_SCHEMA, timeout=900)
    data = _parse_json(reply)
    items = data.get("papers") if isinstance(data, dict) else data
    if not isinstance(items, list):
        raise CodexError(f"unexpected summary payload: {reply[:200]!r}")

    by_id = {r["arxiv_id"]: r for r in rows}
    out = {}
    for idx, item in enumerate(items):
        if not isinstance(item, dict):
            continue
        pid = _norm_id(item.get("id"))
        if pid not in by_id and len(items) == len(rows):
            pid = rows[idx]["arxiv_id"]  # model mangled the id but kept the order
        tldr = str(item.get("tldr") or "").strip()
        if pid not in by_id or not tldr:
            continue
        tags = item.get("tags") or []
        if not isinstance(tags, list):
            tags = [str(tags)]
        labs = item.get("labs") or []
        if not isinstance(labs, list):
            labs = [str(labs)]
        out[pid] = {
            "tldr": tldr,
            "tags": [str(t).strip() for t in tags if str(t).strip()][:8],
            "task": str(item.get("task") or "").strip(),
            "method": str(item.get("method") or "").strip(),
            "labs": [str(l).strip() for l in labs if str(l).strip()][:4],
        }
    return out


# --- deep interpretation ---------------------------------------------------

INTERPRET_SYSTEM = """你是资深研究员，为一位 AI 方向的研究生做论文深度解读。基于给定的论文内容（可能是全文，也可能只有摘要），输出结构化的中文 Markdown 解读，包含以下小节：

## 一句话定位
## 动机与背景
（这个问题为什么重要、已有方法卡在哪里）
## 方法详解
（核心思路、关键设计、与主流做法的差异点；如有关键公式或架构用文字讲清楚）
## 实验与结果
（关键数字、对比对象、结果说明了什么；如果只有摘要则基于摘要说明并注明）
## 局限与启发
（局限性，以及哪些思路值得借鉴或可以迁移到其他方向）

专业术语保留英文，内容要具体，不要空话。只输出解读正文，不要复述这段要求。"""


def _html_to_text(html: str) -> str:
    html = re.sub(r"(?is)<(script|style|noscript|svg|math)[^>]*>.*?</\1>", " ", html)
    html = re.sub(r"(?s)<[^>]+>", " ", html)
    text = unescape(html)
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n\s*\n+", "\n\n", text)
    return text.strip()


def fetch_fulltext(arxiv_id: str, version: int = 1):
    urls = [
        f"https://arxiv.org/html/{arxiv_id}v{version}",
        f"https://ar5iv.labs.arxiv.org/html/{arxiv_id}",
    ]
    for url in urls:
        try:
            r = httpx.get(
                url,
                timeout=60,
                follow_redirects=True,
                headers={"User-Agent": "arxiv-feed/0.2 (personal reader)"},
            )
            if r.status_code == 200 and len(r.text) > 3000:
                text = _html_to_text(r.text)
                if len(text) > 2000:
                    return text
        except httpx.HTTPError:
            continue
    return None


def interpret(paper: dict) -> str:
    fulltext = fetch_fulltext(paper["arxiv_id"], paper.get("version") or 1)
    body = fulltext[:50000] if fulltext else f"（未获取到全文，以下仅为摘要）\n{paper['abstract']}"
    prompt = (
        f"{INTERPRET_SYSTEM}\n\n"
        f"标题: {paper['title']}\n"
        f"arXiv ID: {paper['arxiv_id']}\n"
        f"分类: {paper.get('categories', '')}\n\n"
        f"论文内容:\n{body}"
    )
    return run_codex(prompt, config.INTERPRET_EFFORT, timeout=2400).strip()
