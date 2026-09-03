from __future__ import annotations
import re
import time
from datetime import datetime, timedelta, timezone

import feedparser
import httpx

API_URL = "https://export.arxiv.org/api/query"
PAGE_SIZE = 200
MAX_PAGES = 40
ID_RE = re.compile(r"^(?P<id>.+?)v(?P<ver>\d+)$")


def _clean(text: str) -> str:
    return re.sub(r"\s+", " ", text or "").strip()


def _get_page(query: str, start: int) -> feedparser.FeedParserDict:
    params = {
        "search_query": query,
        "sortBy": "submittedDate",
        "sortOrder": "descending",
        "start": start,
        "max_results": PAGE_SIZE,
    }
    last_exc = None
    for attempt in range(3):
        try:
            r = httpx.get(
                API_URL,
                params=params,
                timeout=60,
                follow_redirects=True,
                headers={"User-Agent": "arxiv-feed/0.1 (personal reader)"},
            )
            r.raise_for_status()
            feed = feedparser.parse(r.text)
            if feed.entries or attempt == 2:
                return feed
        except httpx.HTTPError as e:
            last_exc = e
        time.sleep(5)
    if last_exc:
        raise last_exc
    return feedparser.parse("")


def fetch_recent(categories, days_back: int = 7):
    """Fetch papers submitted within the last `days_back` days for the given categories."""
    cutoff = datetime.now(timezone.utc) - timedelta(days=days_back)
    query = " OR ".join(f"cat:{c}" for c in categories)
    papers = {}
    for page in range(MAX_PAGES):
        feed = _get_page(query, page * PAGE_SIZE)
        if not feed.entries:
            break
        reached_cutoff = False
        for e in feed.entries:
            # Malformed/truncated feeds can yield entries without a parsable date.
            if not e.get("published_parsed"):
                continue
            published = datetime(*e.published_parsed[:6], tzinfo=timezone.utc)
            if published < cutoff:
                reached_cutoff = True
                break
            raw_id = e.id.rsplit("/abs/", 1)[-1]
            m = ID_RE.match(raw_id)
            arxiv_id, version = (m.group("id"), int(m.group("ver"))) if m else (raw_id, 1)
            papers[arxiv_id] = {
                "arxiv_id": arxiv_id,
                "version": version,
                "title": _clean(e.title),
                "abstract": _clean(e.summary),
                "authors": [a.name for a in e.get("authors", [])],
                "categories": [t["term"] for t in e.get("tags", [])],
                "published": published.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "updated": _clean(e.get("updated", "")),
            }
        if reached_cutoff or len(feed.entries) < PAGE_SIZE:
            break
        time.sleep(3)  # arXiv API politeness: >= 3s between requests
    return list(papers.values())
