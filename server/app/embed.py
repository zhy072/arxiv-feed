"""Dependency-free text embeddings: hashed unigrams + bigrams, sublinear tf, L2-normalised.

Not a neural embedding, but once the text carries the LLM's fine-grained tags and the
task/method sentences, cosine similarity on these vectors tracks "same topic" well enough
for a personal feed — and it costs nothing and needs no model download.
"""
from __future__ import annotations

import hashlib
import json
import math
import re

import numpy as np

DIM = 2048

_WORD = re.compile(r"[a-z0-9][a-z0-9+\-.]*")
_CJK = re.compile(r"[㐀-䶿一-鿿]+")
_STOP = set(
    """a an the of and or to in for on with by as at from is are was were be been being we our
    this that these those it its which can may via using based into than then also such not no
    more most both each other over under between within without across use used propose proposed
    present presents paper method methods approach approaches model models result results show
    shows demonstrate novel new task tasks data set sets however while where when their they
    has have had does do did""".split()
)


def tokens(text: str) -> list[str]:
    text = text.lower()
    words = [w.strip(".-") for w in _WORD.findall(text)]
    words = [w for w in words if len(w) > 1 and w not in _STOP]
    out = list(words)
    out.extend(f"{a}_{b}" for a, b in zip(words, words[1:]))
    for run in _CJK.findall(text):
        out.extend(run[i : i + 2] for i in range(len(run) - 1))
        if len(run) == 1:
            out.append(run)
    return out


def _slot(token: str) -> tuple[int, float]:
    h = int.from_bytes(hashlib.blake2b(token.encode("utf-8"), digest_size=8).digest(), "little")
    return h % DIM, 1.0 if h & (1 << 63) else -1.0


def embed(parts) -> np.ndarray:
    """parts: iterable of (text, weight). Returns a unit-length float32 vector."""
    counts: dict[str, float] = {}
    for text, weight in parts:
        if not text:
            continue
        for t in tokens(text):
            counts[t] = counts.get(t, 0.0) + weight
    vec = np.zeros(DIM, dtype=np.float32)
    for t, c in counts.items():
        i, sign = _slot(t)
        vec[i] += sign * (1.0 + math.log(c))
    norm = float(np.linalg.norm(vec))
    return vec / norm if norm > 1e-9 else vec


def embed_paper(row) -> np.ndarray:
    """row: mapping with title/abstract and (optionally) tags/task/method from the summary."""
    tags = json.loads(row["tags"]) if row["tags"] else []
    return embed(
        [
            (row["title"], 3.0),
            (" ".join(str(t) for t in tags), 4.0),
            (row["task"] or "", 2.0),
            (row["method"] or "", 2.0),
            (row["abstract"], 1.0),
        ]
    )
