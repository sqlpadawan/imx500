#!/usr/bin/env python3
"""
build_summary.py — Summarize IMX500 event logs into summary.json

Reads all events.jsonl* files in /var/log/imx500/, counts "enter" events by
date and label, and writes /var/log/imx500/summary.json for the dashboard.

Run at startup from imx500_capture_wrapper.sh before launching the capture
script, so the dashboard reflects all historical data each day.

Usage:
    python3 build_summary.py
    python3 build_summary.py --log-dir /var/log/imx500 --out /var/log/imx500/summary.json
"""

import argparse
import json
import os
from collections import defaultdict
from pathlib import Path

LOG_DIR_DEFAULT = Path("/var/log/imx500")
OUT_DEFAULT     = LOG_DIR_DEFAULT / "summary.json"


def summarize(log_dir: Path, out_path: Path) -> None:
    # day → label → count
    counts: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))

    log_files = sorted(log_dir.glob("events.jsonl*"))
    if not log_files:
        print(f"[build_summary] No event log files found in {log_dir}")

    for log_file in log_files:
        print(f"[build_summary] Reading {log_file.name}")
        try:
            with open(log_file, encoding="utf-8") as f:
                for lineno, line in enumerate(f, 1):
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        record = json.loads(line)
                    except json.JSONDecodeError:
                        print(f"[build_summary]   Skipping malformed line {lineno} in {log_file.name}")
                        continue

                    # Only count "enter" events — one per object appearance
                    if record.get("event") != "enter":
                        continue

                    ts    = record.get("ts", "")
                    label = record.get("label", "unknown")

                    # Extract date portion from ISO timestamp (YYYY-MM-DD)
                    date = ts[:10] if len(ts) >= 10 else "unknown"
                    counts[date][label] += 1

        except OSError as e:
            print(f"[build_summary] Error reading {log_file}: {e}")

    # Build output structure sorted by date descending (most recent first)
    days = []
    for date in sorted(counts.keys(), reverse=True):
        label_counts = counts[date]
        total = sum(label_counts.values())
        days.append({
            "date":   date,
            "total":  total,
            "labels": dict(sorted(label_counts.items(), key=lambda x: x[1], reverse=True)),
        })

    summary = {"days": days}

    out_path.parent.mkdir(parents=True, exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2)

    print(f"[build_summary] Wrote {len(days)} day(s) to {out_path}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Summarize IMX500 event logs into summary.json")
    parser.add_argument("--log-dir", type=Path, default=LOG_DIR_DEFAULT,
                        help=f"Directory containing events.jsonl files (default: {LOG_DIR_DEFAULT})")
    parser.add_argument("--out", type=Path, default=OUT_DEFAULT,
                        help=f"Output path for summary.json (default: {OUT_DEFAULT})")
    args = parser.parse_args()

    summarize(args.log_dir, args.out)


if __name__ == "__main__":
    main()
