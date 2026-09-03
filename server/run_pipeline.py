#!/usr/bin/env python3
import argparse

from app import pipeline

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Fetch + summarize + embed daily arXiv papers")
    # arXiv announces with up to ~4 days of lag vs submittedDate (weekend batches),
    # so the window must stay comfortably larger than the lag; upsert dedups repeats.
    parser.add_argument("--days", type=int, default=7, help="how many days back to fetch")
    parser.add_argument(
        "--interpret", action="store_true",
        help="also deep-read the top PRE_INTERPRET papers of the feed (off by default; done on demand in the app)",
    )
    args = parser.parse_args()
    pipeline.run(days_back=args.days, interpret=args.interpret)
