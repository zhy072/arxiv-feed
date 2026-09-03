"""精搜: topic search with a time window, ranked by citations or by big labs; summaries by Codex.

Flow (POST /search returns after step 3, the rest runs in a background thread):
 1. Codex turns the (Chinese) topic into an intent + 4-8 English phrases (or the user gives phrases).
 2. arXiv API relevance search over those phrases within the submittedDate window (≤300 hits).
 3. Upsert into `papers`, record the search, return results in relevance order.
 4. Codex scores every candidate's relevance to the topic (0-3); only clearly relevant ones stay.
 5. Semantic Scholar batch → citation counts (one call, retried on 429); sort, keep the top 80.
 6. Codex batches → TL;DR / tags / labs (labs read from the paper's first-page author block).
 7. Local embeddings so likes/saves on results shape the profile.
"""
from __future__ import annotations

import json
import re
import threading
import time
import traceback
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import date, timedelta

import feedparser
import httpx

from . import config, db, embed, llm
from . import topics as topics_mod


class SearchError(RuntimeError):
    pass


ARXIV_API = "https://export.arxiv.org/api/query"
S2_BATCH = "https://api.semanticscholar.org/graph/v1/paper/batch"
UA = {"User-Agent": "arxiv-feed/0.2 (personal reader)"}
CANDIDATES = 150  # combined-query hits returned immediately (first paint)
PER_PHRASE = 100  # extra hits fetched per phrase in the background, so no phrase crowds out the others
MAX_CANDIDATES = 500  # cap on what the Codex relevance filter has to read
MAX_RESULTS = 80
MIN_RELEVANCE = 2  # 3 = core work, 2 = clearly relevant, 1 = tangential, 0 = unrelated


def _pats(pairs):
    return [(re.compile(p), label) for p, label in pairs]


# Industry labs rank above big academic groups. Patterns run on lower-cased institution names.
INDUSTRY = _pats([
    (r"\bgoogle\b", "Google"), (r"\bdeepmind\b", "DeepMind"), (r"\bopenai\b", "OpenAI"),
    (r"\banthropic\b", "Anthropic"), (r"\bmeta\b|\bfacebook\b", "Meta"), (r"\bmicrosoft\b", "Microsoft"),
    (r"\bnvidia\b", "NVIDIA"), (r"\bapple\b", "Apple"), (r"\bamazon\b|\baws\b", "Amazon"),
    (r"\bbytedance\b|\btiktok\b|\bseed\b", "ByteDance"), (r"\btencent\b|\bhunyuan\b", "Tencent"),
    (r"\balibaba\b|\bdamo\b|\bqwen\b|\btongyi\b", "Alibaba"), (r"\bbaidu\b", "Baidu"),
    (r"\bkuaishou\b|\bkwai\b|\bkling\b", "Kuaishou"), (r"\bsensetime\b", "SenseTime"), (r"\bhuawei\b", "Huawei"),
    (r"\bdeepseek\b", "DeepSeek"), (r"\bxai\b", "xAI"), (r"\bstability\b", "Stability AI"), (r"\brunway\b", "Runway"),
    (r"\bpika\b", "Pika"), (r"\bluma\b", "Luma"), (r"\badobe\b", "Adobe"), (r"\bsnap\b", "Snap"),
    (r"\bminimax\b", "MiniMax"), (r"\bmoonshot\b", "Moonshot"), (r"\bzhipu\b", "Zhipu"), (r"\bstepfun\b", "StepFun"),
    (r"shanghai (ai|artificial intelligence) lab", "Shanghai AI Lab"), (r"\bmistral\b", "Mistral"),
    (r"\bcohere\b", "Cohere"), (r"\bsalesforce\b", "Salesforce"), (r"\bibm\b", "IBM"), (r"\bintel\b", "Intel"),
    (r"\bqualcomm\b", "Qualcomm"), (r"\bsamsung\b", "Samsung"), (r"\bnaver\b", "NAVER"), (r"\bsony\b", "Sony"),
    (r"allen institute|\bai2\b", "AI2"), (r"hugging ?face", "Hugging Face"), (r"\bxiaomi\b", "Xiaomi"),
    (r"\bmeituan\b", "Meituan"), (r"ant group|\bantgroup\b", "Ant Group"), (r"\bnetease\b", "NetEase"),
    (r"\bmidjourney\b", "Midjourney"), (r"\bcharacter\.?ai\b", "Character.AI"), (r"\bshengshu\b", "Shengshu"),
])

ACADEMIC = _pats([
    (r"\bstanford\b", "Stanford"), (r"\bmit\b|massachusetts institute of technology", "MIT"),
    (r"\bberkeley\b", "UC Berkeley"), (r"carnegie mellon|\bcmu\b", "CMU"), (r"\bprinceton\b", "Princeton"),
    (r"\bharvard\b", "Harvard"), (r"\bcaltech\b|california institute of technology", "Caltech"),
    (r"\bcornell\b", "Cornell"), (r"\bcolumbia\b", "Columbia"), (r"new york university|\bnyu\b", "NYU"),
    (r"university of washington", "UW"), (r"\buiuc\b|urbana", "UIUC"), (r"\bucla\b", "UCLA"),
    (r"\bucsd\b|san diego", "UCSD"), (r"university of michigan", "Michigan"),
    (r"georgia tech|georgia institute of technology", "Georgia Tech"), (r"university of toronto", "Toronto"),
    (r"\bmila\b", "Mila"), (r"\boxford\b", "Oxford"), (r"\bcambridge\b", "Cambridge"),
    (r"imperial college", "Imperial"), (r"\bucl\b|university college london", "UCL"),
    (r"\beth\b|eth z(u|ü)rich", "ETH Zurich"), (r"\bepfl\b", "EPFL"), (r"max planck", "Max Planck"),
    (r"t(ü|ue|u)bingen", "Tübingen"), (r"\btsinghua\b", "Tsinghua"), (r"\bpeking\b|\bpku\b", "PKU"),
    (r"university of hong kong|\bhku\b", "HKU"), (r"chinese university of hong kong|\bcuhk\b", "CUHK"),
    (r"\bhkust\b|hong kong university of science", "HKUST"), (r"national university of singapore|\bnus\b", "NUS"),
    (r"\bnanyang\b|\bntu\b", "NTU"), (r"\bkaist\b", "KAIST"), (r"seoul national", "SNU"),
    (r"university of tokyo", "Tokyo"), (r"\bzhejiang\b", "Zhejiang"), (r"shanghai jiao tong|\bsjtu\b", "SJTU"),
    (r"\bfudan\b", "Fudan"), (r"\bustc\b|university of science and technology of china", "USTC"),
    (r"nanjing university", "Nanjing"), (r"chinese academy of sciences|\bcas\b|\bcasia\b", "CAS"),
    (r"tel aviv", "Tel Aviv"), (r"\btechnion\b", "Technion"), (r"\bweizmann\b", "Weizmann"),
    (r"\bwaterloo\b", "Waterloo"), (r"british columbia|\bubc\b", "UBC"), (r"\bkaust\b", "KAUST"),
    (r"\bmbzuai\b", "MBZUAI"), (r"texas at austin|\but austin\b", "UT Austin"), (r"johns hopkins|\bjhu\b", "JHU"),
    (r"university of pennsylvania|\bupenn\b", "UPenn"), (r"\bedinburgh\b", "Edinburgh"), (r"\bmcgill\b", "McGill"),
    (r"\bwisconsin\b", "Wisconsin"), (r"university of maryland", "UMD"), (r"\bpurdue\b", "Purdue"),
])

_KNOWN = {name for _, name in INDUSTRY} | {name for _, name in ACADEMIC}


def classify_labs(labs) -> tuple[list[str], int]:
    """labs: institution names from the paper's first page → (display labels, score).
    score = tier*10 + matched count; tier 3 = industry lab, 2 = big academic group, 0 = nothing known."""
    labels, tier, hits = [], 0, 0
    for raw in labs or []:
        s = str(raw).strip()
        if not s:
            continue
        low = s.lower()
        label, t = None, 0
        for pat, name in INDUSTRY:
            if pat.search(low):
                label, t = name, 3
                break
        if label is None:
            for pat, name in ACADEMIC:
                if pat.search(low):
                    label, t = name, 2
                    break
        if label:
            hits += 1
            tier = max(tier, t)
            labels.append(label)
        else:
            labels.append(s[:40])
    known = [l for l in dict.fromkeys(labels) if l in _KNOWN]
    other = [l for l in dict.fromkeys(labels) if l not in _KNOWN]
    return (known + other)[:3], ((tier * 10 + min(hits, 9)) if tier else 0)


# --- query expansion ---------------------------------------------------------

EXPAND_SCHEMA = {
    "type": "object",
    "properties": {
        "intent": {"type": "string"},
        "phrases": {"type": "array", "items": {"type": "string"}},
        "label": {"type": "string"},
    },
    "required": ["intent", "phrases", "label"],
    "additionalProperties": False,
}

EXPAND_PROMPT = """你是学术检索助手，服务的用户是一位 AI 研究者，主要方向：{context}。
用户给了一个研究方向，请：
1. 判断它最可能的含义，用一句英文写成 intent。注意歧义：在这位用户的语境里，"量化" 默认指模型量化（low-bit weights/activations、PTQ/QAT、高效推理），不是 vector quantization / tokenizer，除非用户明确写了 VQ；"视频模型" 默认指视频生成或视频理解模型。
2. 给出 4-8 个用于 arXiv 全文检索的英文短语（同义词、缩写、常见相关术语），每个 2-5 个词。每个短语都必须自带方向限定词，能单独命中这个方向（例如 "video diffusion quantization"、"quantized video generation"、"low-bit video DiT"）；不要给会命中大量无关文献的通用短语（例如单独的 "post-training quantization"、"W4A4"、"efficient inference"）。
3. 给一个简短英文名 label。
只输出 JSON：{{"intent": "...", "phrases": ["..."], "label": "..."}}。
研究方向：{topic}"""


def expand_query(topic: str) -> tuple[str, list[str], str]:
    try:
        prompt = EXPAND_PROMPT.format(context=topics_mod.research_context(), topic=topic)
        data = llm._parse_json(llm.run_codex(prompt, "low", schema=EXPAND_SCHEMA, timeout=120))
        phrases = [str(p).strip().strip('"') for p in (data.get("phrases") or []) if str(p).strip()]
        intent = str(data.get("intent") or topic).strip()
        label = str(data.get("label") or topic).strip()
        if phrases:
            return intent, phrases[:8], label
    except Exception:  # noqa: BLE001 - fall back to the literal topic
        traceback.print_exc()
    return topic, [topic], topic


# --- arXiv relevance search --------------------------------------------------

_STOP = {"a", "an", "the", "of", "for", "and", "or", "in", "on", "with", "to", "via", "using", "based", "at", "by"}


def _phrase_query(phrase: str) -> str:
    """arXiv's all:"..." is an exact phrase match, which technical multi-word phrases rarely satisfy verbatim,
    so also accept the words co-occurring anywhere (the Codex relevance filter handles the noise)."""
    words = [w for w in re.findall(r"[A-Za-z0-9][A-Za-z0-9\-\+\.]*", phrase) if w.lower() not in _STOP]
    exact = f'all:"{phrase}"'
    if len(words) <= 1:
        return exact
    loose = " AND ".join(f'all:"{w}"' for w in words)
    return f"({exact} OR ({loose}))"


def arxiv_search(phrases: list[str], months: int, limit: int = CANDIDATES) -> list[dict]:
    start = date.today() - timedelta(days=int(months * 30.4))
    end = date.today() + timedelta(days=1)
    terms = " OR ".join(_phrase_query(p) for p in phrases)
    query = f"({terms}) AND submittedDate:[{start:%Y%m%d}0000 TO {end:%Y%m%d}0000]"
    last: Exception | None = None
    for attempt in range(3):
        try:
            r = httpx.get(
                ARXIV_API,
                params={"search_query": query, "sortBy": "relevance", "max_results": limit},
                headers=UA, timeout=120, follow_redirects=True,
            )
        except httpx.HTTPError as e:
            last = SearchError(f"连不上 arXiv：{e}")
            time.sleep(3 * (attempt + 1))
            continue
        if r.status_code != 200:
            last = SearchError(f"arXiv HTTP {r.status_code}")
            time.sleep(3 * (attempt + 1))
            continue
        feed = feedparser.parse(r.text)
        items = []
        for e in feed.entries:
            m = re.search(r"abs/(.+?)(v\d+)?$", e.get("id", ""))
            if not m or not e.get("title"):
                continue
            items.append({
                "arxiv_id": m.group(1),
                "version": int(m.group(2)[1:]) if m.group(2) else 1,
                "title": " ".join(e.title.split()),
                "abstract": " ".join((e.get("summary") or "").split()) or "(摘要暂缺)",
                "authors": [a.get("name") for a in e.get("authors", []) if a.get("name")],
                "categories": [t.get("term") for t in e.get("tags", []) if t.get("term")],
                "published": e.get("published"),
            })
        return items
    raise last  # type: ignore[misc]


def widen_candidates(phrases: list[str], months: int, items: list[dict]) -> list[dict]:
    """Per-phrase arXiv queries (3s apart, arXiv etiquette), interleaved so every phrase contributes."""
    per_phrase = []
    for i, phrase in enumerate(phrases):
        if i:
            time.sleep(3)
        try:
            per_phrase.append(arxiv_search([phrase], months, limit=PER_PHRASE))
        except SearchError as e:
            print(f"[search] per-phrase query failed for {phrase!r}: {e}", flush=True)
    merged = {it["arxiv_id"]: it for it in items}
    extra = []
    for rank in range(PER_PHRASE):
        for lst in per_phrase:
            if rank < len(lst) and lst[rank]["arxiv_id"] not in merged:
                merged[lst[rank]["arxiv_id"]] = lst[rank]
                extra.append(lst[rank])
    return (items + extra)[:MAX_CANDIDATES]


# --- Codex relevance filter --------------------------------------------------

RELEVANCE_SCHEMA = {
    "type": "object",
    "properties": {
        "scores": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {"id": {"type": "string"}, "score": {"type": "integer"}},
                "required": ["id", "score"],
                "additionalProperties": False,
            },
        }
    },
    "required": ["scores"],
    "additionalProperties": False,
}

RELEVANCE_PROMPT = """你是论文筛选助手。用户要找的方向：「{topic}」（理解为：{intent}）。
下面是关键词检索到的 {n} 篇候选论文（id、标题、摘要开头）。请逐篇判断它和这个方向的相关程度：
3 = 就是这个方向的核心工作；2 = 明确相关（方法或应用直接落在这个方向）；1 = 只是沾边（顺带提到，或只是同一大领域）；0 = 无关。
只输出 JSON：{{"scores": [{{"id": "...", "score": 3}}, ...]}}，只列 score ≥ 1 的论文，id 必须与输入完全一致。"""


def relevance_filter(topic: str, intent: str, items: list[dict]) -> dict | None:
    """→ {arxiv_id: 0-3}; None when Codex failed (caller keeps everything)."""
    listing = "\n\n".join(
        f"id: {it['arxiv_id']}\n标题: {it['title']}\n摘要: {it['abstract'][:350]}" for it in items
    )
    prompt = RELEVANCE_PROMPT.format(topic=topic, intent=intent, n=len(items)) + "\n\n" + listing
    try:
        data = llm._parse_json(llm.run_codex(prompt, config.SEARCH_FILTER_EFFORT, schema=RELEVANCE_SCHEMA, timeout=900))
    except Exception:  # noqa: BLE001
        traceback.print_exc()
        return None
    out = {}
    for s in data.get("scores") or []:
        if not isinstance(s, dict):
            continue
        try:
            out[llm._norm_id(s.get("id"))] = max(0, min(3, int(s.get("score"))))
        except (TypeError, ValueError):
            continue
    return out


# --- Semantic Scholar citations ---------------------------------------------

def s2_citations(ids: list[str]) -> dict | None:
    """One batch call → {arxiv_id: {citation_count, venue}}. None when S2 keeps refusing (shared rate limit)."""
    if not ids:
        return {}
    headers = dict(UA)
    if config.S2_API_KEY:
        headers["x-api-key"] = config.S2_API_KEY
    for attempt in range(5):
        try:
            r = httpx.post(
                S2_BATCH,
                params={"fields": "citationCount,venue,externalIds"},
                json={"ids": [f"ARXIV:{a}" for a in ids]},
                headers=headers, timeout=60,
            )
        except httpx.HTTPError:
            time.sleep(3)
            continue
        if r.status_code == 200:
            out = {}
            for p in r.json():
                if not p:
                    continue
                aid = (p.get("externalIds") or {}).get("ArXiv")
                if aid:
                    out[aid] = {"citation_count": int(p.get("citationCount") or 0), "venue": p.get("venue") or ""}
            return out
        if r.status_code in (429, 500, 502, 503):
            time.sleep(5 * (attempt + 1))
            continue
        print(f"[search] S2 batch HTTP {r.status_code}: {r.text[:200]}", flush=True)
        return None
    return None


# --- first-page author block (for labs) --------------------------------------

def author_block(arxiv_id: str, version: int = 1) -> str:
    """Text between the title and the abstract of the arXiv HTML rendering (authors + affiliations)."""
    urls = [
        f"https://arxiv.org/html/{arxiv_id}v{version}",
        f"https://arxiv.org/html/{arxiv_id}",
        f"https://ar5iv.labs.arxiv.org/html/{arxiv_id}",
    ]
    for url in urls:
        try:
            r = httpx.get(url, headers={**UA, "Range": "bytes=0-150000"}, timeout=30, follow_redirects=True)
        except httpx.HTTPError:
            continue
        if r.status_code not in (200, 206) or len(r.text) < 1500:
            continue
        html = r.text[:150000]
        # LaTeXML markup: <h1> title, then the authors block, then <div class="ltx_abstract">.
        # (The page's own nav mentions "abstract" too, so cut on markup rather than on text.)
        start = html.find("<h1")
        if start < 0:
            start = html.find('class="ltx_authors"')
        if start < 0:
            continue
        end = html.find('class="ltx_abstract"', start)
        chunk = html[start:end] if end > start else html[start : start + 8000]
        block = re.sub(r"\s+", " ", llm._html_to_text(chunk)).strip()
        if block:
            return block[:1500]
    return ""


# --- orchestration -----------------------------------------------------------

_active: set[int] = set()
_lock = threading.Lock()


def run(topic: str, months: int, phrases: list[str] | None = None) -> dict:
    topic = " ".join(topic.split())
    if not topic:
        raise SearchError("请输入要精搜的方向")
    phrases = [" ".join(p.split()) for p in (phrases or []) if p and p.strip()]
    if phrases:
        intent, label = topic, topic  # user-supplied English phrases: no translation step
    else:
        intent, phrases, label = expand_query(topic)
    items = arxiv_search(phrases, months)
    query = " | ".join(phrases)
    if not items and len(phrases) <= 1:
        search_id = db.create_search(topic, query, label, months, [], 0, intent=intent)
        return payload(search_id)

    db.upsert_search_papers(items)
    ids = [it["arxiv_id"] for it in items]
    search_id = db.create_search(topic, query, label, months, ids, len(ids), intent=intent)
    with _lock:
        _active.add(search_id)
    threading.Thread(target=_enrich, args=(search_id, topic, intent, phrases, months, items), daemon=True).start()
    return payload(search_id)


def payload(search_id: int) -> dict:
    meta, rows = db.get_search(search_id)
    if meta is None:
        raise SearchError("search not found")
    with _lock:
        active = search_id in _active
    return {
        "search_id": meta["id"],
        "topic": meta["topic"],
        "intent": meta["intent"],
        "query": meta["query"],
        "label": meta["label"],
        "months": meta["months"],
        "total": meta["total"],
        "pending": sum(1 for r in rows if not r["tldr"]),
        "filtered": bool(rows) and all(r["relevance"] is not None for r in rows),
        "citations_ready": bool(rows) and all(r["citation_count"] is not None for r in rows),
        "active": active,
        "papers": rows,
    }


def _enrich(search_id: int, topic: str, intent: str, phrases: list[str], months: int, items: list[dict]):
    """Background: widen candidates → relevance filter → citations → trim → Codex summaries + labs → embeddings."""
    try:
        if len(phrases) > 1:
            items = widen_candidates(phrases, months, items)
            db.upsert_search_papers(items)
            db.trim_search(search_id, [(it["arxiv_id"], None) for it in items], total=len(items))
        if not items:
            return
        scores = relevance_filter(topic, intent, items)
        if scores is None:
            print("[search] relevance filter failed; keeping every candidate", flush=True)
            kept = [(it, 1) for it in items]
        else:
            scored = [(it, scores.get(it["arxiv_id"], 0)) for it in items]
            kept = [(it, s) for it, s in scored if s >= MIN_RELEVANCE]
            if len(kept) < 12:
                kept = [(it, s) for it, s in scored if s >= 1]

        ids = [it["arxiv_id"] for it, _ in kept]
        cites = s2_citations(ids)
        if cites is None:
            print("[search] citations unavailable; ordering by relevance only", flush=True)
            cites = {}
        db.set_citations([
            (a, cites.get(a, {}).get("citation_count", 0), cites.get(a, {}).get("venue", "")) for a in ids
        ])
        kept.sort(key=lambda t: (
            -cites.get(t[0]["arxiv_id"], {}).get("citation_count", 0), -t[1], t[0].get("published") or "",
        ))
        kept.sort(key=lambda t: (-cites.get(t[0]["arxiv_id"], {}).get("citation_count", 0), -t[1]))
        keep = kept[:MAX_RESULTS]
        db.trim_search(search_id, [(it["arxiv_id"], s) for it, s in keep], total=len(kept))

        rows = db.papers_by_ids([it["arxiv_id"] for it, _ in keep])
        todo = [r for r in rows if not r["tldr"] or r["affiliations"] is None]
        version = {it["arxiv_id"]: it["version"] for it, _ in keep}
        size = max(1, config.SUMMARY_BATCH)
        batches = [todo[i : i + size] for i in range(0, len(todo), size)]

        def work(batch):
            snippets = {r["arxiv_id"]: author_block(r["arxiv_id"], version.get(r["arxiv_id"], 1)) for r in batch}
            for pid, data in llm.summarize_batch(batch, snippets=snippets).items():
                labels, score = classify_labs(data.pop("labs", []))
                data["affiliations"] = labels
                data["affil_score"] = score
                db.save_summary(pid, data)

        with ThreadPoolExecutor(max_workers=max(1, config.SUMMARY_WORKERS)) as ex:
            for f in as_completed([ex.submit(work, b) for b in batches]):
                try:
                    f.result()
                except Exception:  # noqa: BLE001
                    traceback.print_exc()

        rows = db.papers_by_ids([it["arxiv_id"] for it, _ in keep])
        db.save_embeddings([(r["arxiv_id"], embed.embed_paper(r)) for r in rows if r["embedding"] is None])
    except Exception:  # noqa: BLE001
        traceback.print_exc()
    finally:
        with _lock:
            _active.discard(search_id)
