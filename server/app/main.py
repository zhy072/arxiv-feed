from __future__ import annotations
import json
from typing import Optional

from fastapi import Depends, FastAPI, Header, HTTPException
from pydantic import BaseModel

from . import config, db, llm, pipeline, recommend, search, topics

app = FastAPI(title="arxiv-feed", version="0.2.0")
db.init_db()

VALID_EVENT_KINDS = {"impression", "click", "dwell", "like", "dislike", "save", "unlike", "unsave"}


def auth(authorization: Optional[str] = Header(default=None)):
    if not config.API_TOKEN:
        return
    if authorization != f"Bearer {config.API_TOKEN}":
        raise HTTPException(status_code=401, detail="invalid token")


def paper_out(row, include_interpretation: bool = False) -> dict:
    d = dict(row)
    out = {
        "arxiv_id": d["arxiv_id"],
        "title": d["title"],
        "abstract": d.get("abstract"),
        "authors": json.loads(d.get("authors") or "[]"),
        "categories": json.loads(d.get("categories") or "[]"),
        "published": d.get("published"),
        "tldr": d.get("tldr"),
        "tags": json.loads(d["tags"]) if d.get("tags") else [],
        "task": d.get("task"),
        "method": d.get("method"),
        "has_interpretation": bool(d.get("interpretation")),
        "abs_url": f"https://arxiv.org/abs/{d['arxiv_id']}",
        "pdf_url": f"https://arxiv.org/pdf/{d['arxiv_id']}",
        "liked": bool(d.get("liked") or 0),
        "saved": bool(d.get("saved") or 0),
        "citation_count": d.get("citation_count"),
        "venue": d.get("venue") or None,
        "affiliations": json.loads(d["affiliations"]) if d.get("affiliations") else [],
        "affil_score": d.get("affil_score") or 0,
        "relevance": d.get("relevance"),
    }
    if include_interpretation:
        out["interpretation"] = d.get("interpretation")
    return out


class Event(BaseModel):
    arxiv_id: str
    kind: str
    value: Optional[float] = None


class EventsIn(BaseModel):
    events: list[Event]


class SearchIn(BaseModel):
    topic: str
    months: int = 12
    phrases: Optional[list[str]] = None  # explicit English phrases skip the Codex translation


def search_out(payload: dict) -> dict:
    payload["papers"] = [paper_out(r) for r in payload["papers"]]
    return payload


def _version() -> str:
    try:
        return (config.BASE_DIR / "VERSION").read_text().strip() or "dev"
    except OSError:
        return "dev"


@app.get("/health")
def health():
    return {"ok": True, "codex": llm.available(), "version": _version()}


@app.get("/feed", dependencies=[Depends(auth)])
def feed(limit: int = 20):
    with db.get_conn() as conn:
        rows, matched = recommend.build_feed(conn, limit=max(1, min(limit, 50)))
    papers = []
    for r in rows:
        d = paper_out(r)
        d["matched_topic"] = matched.get(r["arxiv_id"])
        papers.append(d)
    return {"papers": papers}


class TopicsIn(BaseModel):
    topics: list[str]


class ContextIn(BaseModel):
    context: str


@app.get("/prefs/context", dependencies=[Depends(auth)])
def get_context():
    return {"context": topics.research_context()}


@app.put("/prefs/context", dependencies=[Depends(auth)])
def put_context(body: ContextIn):
    topics.set_research_context(body.context)
    return {"context": topics.research_context()}


@app.get("/prefs/topics", dependencies=[Depends(auth)])
def get_topics():
    return {"topics": topics.get_topics()}


@app.put("/prefs/topics", dependencies=[Depends(auth)])
def put_topics(body: TopicsIn):
    """Replace the followed topics; new ones get English keywords from Codex (a few seconds)."""
    return {"topics": topics.set_topics(body.topics)}


@app.get("/saved", dependencies=[Depends(auth)])
def saved(limit: int = 200):
    rows = db.saved_papers(limit=max(1, min(limit, 1000)))
    return {"papers": [paper_out(r) for r in rows]}


@app.get("/papers/{arxiv_id:path}", dependencies=[Depends(auth)])
def get_paper(arxiv_id: str):
    row = db.get_paper(arxiv_id)
    if row is None:
        raise HTTPException(status_code=404, detail="paper not found")
    return paper_out(row, include_interpretation=True)


@app.post("/papers/{arxiv_id:path}/interpret", dependencies=[Depends(auth)])
def interpret_paper(arxiv_id: str):
    row = db.get_paper(arxiv_id)
    if row is None:
        raise HTTPException(status_code=404, detail="paper not found")
    if row["interpretation"]:
        return {"arxiv_id": arxiv_id, "interpretation": row["interpretation"], "cached": True}
    if not llm.available():
        raise HTTPException(status_code=503, detail=f"找不到 Codex CLI：{config.CODEX_BIN}")
    try:
        text = llm.interpret(dict(row))
    except llm.CodexError as e:
        raise HTTPException(status_code=502, detail=str(e)) from e
    if not text:
        raise HTTPException(status_code=502, detail="interpretation came back empty")
    db.save_interpretation(arxiv_id, text)
    return {"arxiv_id": arxiv_id, "interpretation": text, "cached": False}


@app.post("/events", dependencies=[Depends(auth)])
def post_events(body: EventsIn):
    bad = [e.kind for e in body.events if e.kind not in VALID_EVENT_KINDS]
    if bad:
        raise HTTPException(status_code=422, detail=f"invalid event kinds: {bad}")
    db.add_events([(e.arxiv_id, e.kind, e.value) for e in body.events])
    return {"ok": True, "count": len(body.events)}


@app.post("/search", dependencies=[Depends(auth)])
def run_search(body: SearchIn):
    """精搜: topic → Semantic Scholar (citations, labs) → arXiv papers, summarised in the background."""
    try:
        return search_out(search.run(body.topic, max(1, min(body.months, 120)), phrases=body.phrases))
    except search.SearchError as e:
        raise HTTPException(status_code=502, detail=str(e)) from e


@app.get("/search/{search_id}", dependencies=[Depends(auth)])
def get_search(search_id: int):
    try:
        return search_out(search.payload(search_id))
    except search.SearchError as e:
        raise HTTPException(status_code=404, detail=str(e)) from e


@app.post("/update", dependencies=[Depends(auth)])
def start_update(days: int = 7, interpret: bool = False):
    """Fetch today's papers and run the Codex summaries in the background (deep-reads only if asked)."""
    started = pipeline.start(days_back=max(1, min(days, 14)), interpret=interpret)
    return {"started": started, "status": pipeline.status()}


@app.get("/update/status", dependencies=[Depends(auth)])
def update_status():
    return pipeline.status()


@app.get("/stats", dependencies=[Depends(auth)])
def get_stats():
    s = db.stats()
    s["codex_available"] = llm.available()
    return s
