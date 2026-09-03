"""关注词条 for the 发现 feed: user-maintained topics, each expanded by Codex into English keywords."""
from __future__ import annotations

import json
import threading
import traceback

from . import config, db, embed, llm

PREF_KEY = "topics"
CONTEXT_KEY = "research_context"


def research_context() -> str:
    """What the user works on, for Codex to disambiguate topics. Set in the app's settings; .env is the fallback."""
    return (db.get_pref(CONTEXT_KEY) or config.RESEARCH_CONTEXT or "AI 研究").strip()


def set_research_context(text: str):
    db.set_pref(CONTEXT_KEY, " ".join(text.split()))

EXPAND_SCHEMA = {
    "type": "object",
    "properties": {
        "topics": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {"name": {"type": "string"}, "keywords": {"type": "array", "items": {"type": "string"}}},
                "required": ["name", "keywords"],
                "additionalProperties": False,
            },
        }
    },
    "required": ["topics"],
    "additionalProperties": False,
}

EXPAND_PROMPT = """你是学术检索助手，用户是 AI 研究者（主要方向：{context}）。下面是用户在论文流里关注的方向，请为每个方向给 3-6 个英文关键词短语，用于在论文标题/摘要里做子串匹配：每个 1-4 个词、具体、自带方向限定词（例如 "video diffusion quantization"、"full-duplex speech"），把该方向最常见的英文叫法放在第一个。注意：在这位用户的语境里 "量化" 指模型量化（low-bit），不是 vector quantization。
只输出 JSON：{{"topics": [{{"name": "...", "keywords": ["..."]}}]}}，name 必须与输入完全一致。
方向列表：{names}"""

_lock = threading.Lock()
_expanding = False


def get_topics() -> list[dict]:
    """[{name, keywords}] — seeds the defaults on first use and back-fills keywords in the background."""
    topics = db.get_pref(PREF_KEY)
    if topics is None:
        topics = [{"name": n, "keywords": []} for n in config.DEFAULT_TOPICS]
        db.set_pref(PREF_KEY, topics)
    if any(not t.get("keywords") for t in topics):
        _expand_missing_async()
    return topics


def set_topics(names: list[str]) -> list[dict]:
    """Replace the topic list; keeps keywords of unchanged topics, expands the new ones with Codex."""
    names = list(dict.fromkeys(" ".join(n.split()) for n in names if n and n.strip()))
    old = {t["name"]: t.get("keywords") or [] for t in (db.get_pref(PREF_KEY) or [])}
    fresh = [n for n in names if not old.get(n)]
    expanded = expand(fresh) if fresh else {}
    topics = [{"name": n, "keywords": old.get(n) or expanded.get(n, [])} for n in names]
    db.set_pref(PREF_KEY, topics)
    return topics


def expand(names: list[str]) -> dict:
    if not names or not llm.available():
        return {}
    try:
        prompt = EXPAND_PROMPT.format(context=research_context(), names=json.dumps(names, ensure_ascii=False))
        data = llm._parse_json(llm.run_codex(prompt, "low", schema=EXPAND_SCHEMA, timeout=180))
        out = {}
        for t in data.get("topics") or []:
            if isinstance(t, dict) and t.get("name") in names:
                out[t["name"]] = [str(k).strip() for k in (t.get("keywords") or []) if str(k).strip()][:6]
        return out
    except Exception:  # noqa: BLE001 - topics still work by name / embedding
        traceback.print_exc()
        return {}


def _expand_missing_async():
    global _expanding
    with _lock:
        if _expanding:
            return
        _expanding = True

    def work():
        global _expanding
        try:
            topics = db.get_pref(PREF_KEY) or []
            missing = [t["name"] for t in topics if not t.get("keywords")]
            got = expand(missing)
            if got:
                for t in topics:
                    if not t.get("keywords") and got.get(t["name"]):
                        t["keywords"] = got[t["name"]]
                db.set_pref(PREF_KEY, topics)
        finally:
            with _lock:
                _expanding = False

    threading.Thread(target=work, daemon=True).start()


def scoring_topics(topics: list[dict]):
    """→ [(name, name_lower, [keyword_lower...], unit vector)] ready for recommend.build_feed."""
    out = []
    for t in topics:
        name = t["name"]
        kws = [k.lower() for k in (t.get("keywords") or [])]
        vec = embed.embed([(name, 3.0), (" ".join(t.get("keywords") or []), 1.0)])
        out.append((name, name.lower(), kws, vec))
    return out
