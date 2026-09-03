from __future__ import annotations
import random
from datetime import datetime, timezone

import numpy as np

from . import topics as topics_mod

EVENT_WEIGHTS = {"save": 3.0, "like": 2.0, "click": 1.0, "dwell": 1.0, "dislike": -2.0}
PROFILE_HALF_LIFE_DAYS = 14.0
RECENCY_HALF_LIFE_DAYS = 3.0
SIM_WEIGHT = 0.65
RECENCY_WEIGHT = 0.35
# With followed topics (关注词条): profile / topic / recency.
TOPIC_MIX = (0.35, 0.35, 0.30)
TOPIC_ONLY_MIX = (0.55, 0.45)  # topic / recency when there is no behaviour profile yet
EXPLORE_SLOTS = 2
CANDIDATE_POOL = 3000


def _parse_ts(s: str) -> datetime:
    try:
        return datetime.fromisoformat((s or "").replace("Z", "+00:00"))
    except ValueError:
        return datetime.now(timezone.utc)


def interest_vector(conn):
    """Time-decayed weighted average of embeddings of papers the user interacted with."""
    rows = conn.execute(
        "SELECT e.id, e.arxiv_id, e.kind, e.value, e.created_at, p.embedding FROM events e"
        " JOIN papers p ON p.arxiv_id = e.arxiv_id"
        " WHERE p.embedding IS NOT NULL AND e.kind IN ('save','like','click','dwell','dislike')"
    ).fetchall()
    if not rows:
        return None
    # A like/save that was later undone (unlike/unsave) should not shape the profile.
    undone = {}
    for r in conn.execute(
        "SELECT arxiv_id, kind, MAX(id) AS last_id FROM events"
        " WHERE kind IN ('unlike','unsave') GROUP BY arxiv_id, kind"
    ):
        undone[(r["arxiv_id"], "like" if r["kind"] == "unlike" else "save")] = r["last_id"]
    now = datetime.now(timezone.utc)
    acc = None
    total = 0.0
    for r in rows:
        if r["id"] < undone.get((r["arxiv_id"], r["kind"]), -1):
            continue
        w = EVENT_WEIGHTS[r["kind"]]
        if r["kind"] == "dwell":
            w *= min((r["value"] or 0.0) / 60.0, 2.0)
        age_days = max((now - _parse_ts(r["created_at"])).total_seconds() / 86400.0, 0.0)
        w *= 0.5 ** (age_days / PROFILE_HALF_LIFE_DAYS)
        v = np.frombuffer(r["embedding"], dtype=np.float32)
        acc = v * w if acc is None else acc + v * w
        total += abs(w)
    if acc is None or total == 0.0:
        return None
    norm = np.linalg.norm(acc)
    if norm < 1e-9:
        return None
    return acc / norm


def topic_match(row, topics) -> tuple[float, str | None]:
    """How strongly a paper hits one of the followed topics: name/keyword in title or tags → 1.0,
    in the abstract → 0.85, otherwise a scaled embedding similarity. Returns (score, topic name)."""
    title = (row["title"] or "").lower()
    abstract = (row["abstract"] or "").lower()
    tags = (row["tags"] or "").lower()
    best, best_name = 0.0, None
    for name, name_l, kws, _vec in topics:
        if name_l in title or name_l in tags:
            return 1.0, name
        score = 0.85 if name_l in abstract else 0.0
        for kw in kws:
            if kw in title or kw in tags:
                return 1.0, name
            if kw in abstract:
                score = max(score, 0.85)
        if score > best:
            best, best_name = score, name
    if best == 0.0 and row["embedding"]:
        v = np.frombuffer(row["embedding"], dtype=np.float32)
        n = np.linalg.norm(v)
        if n > 1e-9:
            v = v / n
            for name, _l, _k, vec in topics:
                s = min(1.0, float(np.dot(vec, v)) * 2.5)
                if s >= 0.3 and s > best:
                    best, best_name = s, name
    return best, best_name


def build_feed(conn, limit: int = 20):
    """→ (rows, {arxiv_id: matched topic name})."""
    topics = topics_mod.scoring_topics(topics_mod.get_topics())
    seen = {
        r[0]
        for r in conn.execute(
            "SELECT DISTINCT arxiv_id FROM events"
            " WHERE kind IN ('impression','click','like','dislike','save')"
        )
    }
    rows = conn.execute(
        "SELECT * FROM papers ORDER BY published DESC LIMIT ?", (CANDIDATE_POOL,)
    ).fetchall()
    cands = [r for r in rows if r["arxiv_id"] not in seen]
    if not cands:
        return [], {}

    profile = interest_vector(conn)
    now = datetime.now(timezone.utc)
    scored = []
    matched = {}
    for r in cands:
        age_days = max((now - _parse_ts(r["published"])).total_seconds() / 86400.0, 0.0)
        recency = 0.5 ** (age_days / RECENCY_HALF_LIFE_DAYS)
        sim = 0.0
        if profile is not None and r["embedding"]:
            v = np.frombuffer(r["embedding"], dtype=np.float32)
            n = np.linalg.norm(v)
            if n > 1e-9:
                sim = float(np.dot(profile, v / n))
        topic, topic_name = topic_match(r, topics) if topics else (0.0, None)
        if topic_name:
            matched[r["arxiv_id"]] = topic_name
        if topics and profile is not None:
            score = TOPIC_MIX[0] * sim + TOPIC_MIX[1] * topic + TOPIC_MIX[2] * recency
        elif topics:
            score = TOPIC_ONLY_MIX[0] * topic + TOPIC_ONLY_MIX[1] * recency
        elif profile is not None:
            score = SIM_WEIGHT * sim + RECENCY_WEIGHT * recency
        else:
            score = recency
        scored.append((score, r))
    scored.sort(key=lambda t: -t[0])

    # Without a profile, scoring is recency-only and explore slots are meaningless.
    head = max(limit - EXPLORE_SLOTS, 1) if profile is not None else limit
    picked = [r for _, r in scored[:head]]
    rest = [r for _, r in scored[head:300]]
    if rest and profile is not None:
        picked.extend(random.sample(rest, min(EXPLORE_SLOTS, len(rest))))
    picked = picked[:limit]
    return picked, {r["arxiv_id"]: matched[r["arxiv_id"]] for r in picked if r["arxiv_id"] in matched}
