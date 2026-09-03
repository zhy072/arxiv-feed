from __future__ import annotations
import os
from pathlib import Path

from dotenv import load_dotenv

BASE_DIR = Path(os.environ.get("ARXIV_HOME", Path(__file__).resolve().parent.parent))
load_dotenv(BASE_DIR / ".env")

DATA_DIR = Path(os.environ.get("ARXIV_DATA_DIR", BASE_DIR / "data"))
DATA_DIR.mkdir(parents=True, exist_ok=True)
DB_PATH = DATA_DIR / "arxiv.db"

CATEGORIES = [
    c.strip()
    for c in os.environ.get(
        "ARXIV_CATEGORIES", "cs.CV,cs.LG,cs.CL,cs.AI,cs.MM,cs.SD,eess.AS,eess.IV"
    ).split(",")
    if c.strip()
]

# All LLM work goes through the Codex CLI bundled with the ChatGPT desktop app
# (logged in via ~/.codex/auth.json), invoked as `codex exec`.
CODEX_BIN = os.environ.get("CODEX_BIN", "/Applications/ChatGPT.app/Contents/Resources/codex")
CODEX_MODEL = os.environ.get("CODEX_MODEL", "gpt-5.6-sol")
SUMMARY_EFFORT = os.environ.get("SUMMARY_EFFORT", "low")
INTERPRET_EFFORT = os.environ.get("INTERPRET_EFFORT", "xhigh")
SUMMARY_BATCH = int(os.environ.get("SUMMARY_BATCH", "15"))  # papers per codex call
SUMMARY_LIMIT = int(os.environ.get("SUMMARY_LIMIT", "600"))  # newest pending papers per update
SUMMARY_WORKERS = int(os.environ.get("SUMMARY_WORKERS", "3"))
PRE_INTERPRET = int(os.environ.get("PRE_INTERPRET", "0"))  # >0: also deep-read the top N of the feed during an update
INTERPRET_WORKERS = int(os.environ.get("INTERPRET_WORKERS", "2"))
CODEX_MAX_CONCURRENCY = int(os.environ.get("CODEX_MAX_CONCURRENCY", "4"))

# 精搜: Codex needs to know the user's field to disambiguate topics; S2 key is optional (higher rate limits).
RESEARCH_CONTEXT = os.environ.get("RESEARCH_CONTEXT", "AI 研究")  # the app's settings override this (prefs)
DEFAULT_TOPICS = [t.strip() for t in os.environ.get("DEFAULT_TOPICS", "").split(",") if t.strip()]
SEARCH_FILTER_EFFORT = os.environ.get("SEARCH_FILTER_EFFORT", "low")
S2_API_KEY = os.environ.get("S2_API_KEY", "")

API_TOKEN = os.environ.get("API_TOKEN", "")  # empty = no auth (service only listens on loopback)
API_HOST = os.environ.get("API_HOST", "127.0.0.1")
API_PORT = int(os.environ.get("API_PORT", "8787"))
