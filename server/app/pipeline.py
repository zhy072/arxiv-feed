"""Daily update: fetch arXiv → Codex summaries → local embeddings → Codex deep-reads for the top of the feed.

Runs either synchronously (run_pipeline.py) or in a background thread started from the API,
publishing progress through `status()` so the Mac app can show it.
"""
from __future__ import annotations

import threading
import traceback
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone

from . import arxiv_fetch, config, db, embed, llm, recommend

_lock = threading.Lock()
_state = {
    "running": False,
    "stage": "idle",
    "message": "",
    "started_at": None,
    "finished_at": None,
    "error": None,
    "fetched": 0,
    "new": 0,
    "summarized": 0,
    "summary_total": 0,
    "embedded": 0,
    "interpreted": 0,
    "interpret_total": 0,
    "log": [],
}


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _set(**kw):
    with _lock:
        _state.update(kw)


def _log(msg: str):
    print(f"[pipeline] {msg}", flush=True)
    with _lock:
        _state["log"] = (_state["log"] + [msg])[-40:]
        _state["message"] = msg


def status() -> dict:
    with _lock:
        return dict(_state)


def start(days_back: int = 7, interpret: bool = False) -> bool:
    """Kick off an update in the background. Returns False if one is already running."""
    with _lock:
        if _state["running"]:
            return False
        _state.update(
            running=True, stage="starting", message="", started_at=_now(), finished_at=None,
            error=None, fetched=0, new=0, summarized=0, summary_total=0, embedded=0,
            interpreted=0, interpret_total=0, log=[],
        )
    threading.Thread(target=_guarded_run, args=(days_back, interpret), daemon=True).start()
    return True


def _guarded_run(days_back: int, interpret: bool):
    try:
        run(days_back=days_back, interpret=interpret)
    except Exception as e:  # noqa: BLE001 - surface anything to the UI
        traceback.print_exc()
        _set(error=str(e), stage="error")
        _log(f"更新失败：{e}")
    finally:
        _set(running=False, finished_at=_now())


def run(days_back: int = 7, interpret: bool = False):
    """Deep-reads only happen here when explicitly asked for (interpret=True and PRE_INTERPRET>0);
    by default they are generated on demand when a paper is opened in the app."""
    db.init_db()
    _set(stage="fetch")
    _log(f"抓取 {', '.join(config.CATEGORIES)} 最近 {days_back} 天")
    papers = arxiv_fetch.fetch_recent(config.CATEGORIES, days_back=days_back)
    new = db.upsert_papers(papers)
    _set(fetched=len(papers), new=new)
    _log(f"抓到 {len(papers)} 篇，新增 {new} 篇")

    if not llm.available():
        _log(f"找不到 Codex CLI（{config.CODEX_BIN}），跳过速览和解读")
        _embed_pending()
        _set(stage="done")
        return

    _summarize_pending()
    _embed_pending()
    if interpret and config.PRE_INTERPRET > 0:
        _pre_interpret()
    _set(stage="done")
    s = db.stats()
    _log(f"完成：共 {s['papers']} 篇，{s['with_tldr']} 篇有速览，{s['interpreted']} 篇有解读")


def _summarize_pending():
    rows = db.pending_summaries(limit=config.SUMMARY_LIMIT)
    size = max(1, config.SUMMARY_BATCH)
    batches = [rows[i : i + size] for i in range(0, len(rows), size)]
    _set(stage="summarize", summary_total=len(rows), summarized=0)
    if not rows:
        _log("没有需要生成速览的论文")
        return
    _log(f"用 Codex（{config.SUMMARY_EFFORT}）生成 {len(rows)} 篇速览，分 {len(batches)} 批")

    def work(batch):
        results = llm.summarize_batch(batch)
        for pid, data in results.items():
            data.pop("labs", None)  # no first-page snippet in the daily run → nothing reliable to store
            db.save_summary(pid, data)
        return len(results), len(batch) - len(results)

    done = failed = 0
    with ThreadPoolExecutor(max_workers=max(1, config.SUMMARY_WORKERS)) as ex:
        futures = [ex.submit(work, b) for b in batches]
        for f in as_completed(futures):
            try:
                ok, missing = f.result()
                done += ok
                failed += missing
            except Exception as e:  # noqa: BLE001
                failed += size
                _log(f"一批速览失败：{str(e)[:200]}")
            _set(summarized=done)
            _log(f"速览进度 {done}/{len(rows)}")
    _log(f"速览完成：{done} 篇成功，{failed} 篇留到下次重试")


def _embed_pending():
    rows = db.pending_embeddings()
    _set(stage="embed", embedded=0)
    if not rows:
        return
    _log(f"计算 {len(rows)} 篇的主题向量")
    pairs = []
    for i, r in enumerate(rows, 1):
        pairs.append((r["arxiv_id"], embed.embed_paper(r)))
        if len(pairs) >= 500:
            db.save_embeddings(pairs)
            pairs = []
            _set(embedded=i)
    if pairs:
        db.save_embeddings(pairs)
    _set(embedded=len(rows))


def _pre_interpret():
    with db.get_conn() as conn:
        rows, _ = recommend.build_feed(conn, limit=config.PRE_INTERPRET)
    todo = [dict(r) for r in rows if not r["interpretation"]]
    _set(stage="interpret", interpret_total=len(todo), interpreted=0)
    if not todo:
        _log("推荐位上的论文都已有解读")
        return
    _log(f"用 Codex（{config.INTERPRET_EFFORT}）深度解读推荐位前 {len(todo)} 篇，每篇要几分钟")

    def work(p):
        text = llm.interpret(p)
        if not text:
            raise llm.CodexError("empty interpretation")
        db.save_interpretation(p["arxiv_id"], text)
        return p["title"]

    done = 0
    with ThreadPoolExecutor(max_workers=max(1, config.INTERPRET_WORKERS)) as ex:
        futures = [ex.submit(work, p) for p in todo]
        for f in as_completed(futures):
            try:
                title = f.result()
                done += 1
                _set(interpreted=done)
                _log(f"解读完成 {done}/{len(todo)}：{title[:60]}")
            except Exception as e:  # noqa: BLE001
                _log(f"一篇解读失败：{str(e)[:200]}")
