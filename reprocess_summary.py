#!/usr/bin/env python3
"""
reprocess_summary.py — Rebuild summary.json from raw logs with corrected dedup.

The original tracking used a bucket divisor of 6px, which caused a single
vehicle moving across the frame to generate many separate "enter" events as
its bbox origin drifted by just 6px at a time. This script post-processes the
raw logs and collapses those duplicate enters into single events before
counting.

Dedup logic:
  Two "enter" events are considered the same physical object if:
    - Same label
    - Bbox origins within SPATIAL_THRESHOLD pixels of each other (x and y)
    - Timestamps within TIME_WINDOW_S seconds of each other

The earliest event in each cluster is kept; the rest are discarded.

Usage:
    python3 reprocess_summary.py
    python3 reprocess_summary.py --log-dir /var/log/imx500 --out /var/log/imx500/summary.json
    python3 reprocess_summary.py --dry-run        # print stats, don't write
    python3 reprocess_summary.py --spatial 64 --time-window 15
"""

import argparse
import json
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

LOG_DIR_DEFAULT    = Path("/var/log/imx500")
OUT_DEFAULT        = LOG_DIR_DEFAULT / "summary.json"
SPATIAL_THRESHOLD  = 64    # px — max x or y distance to treat as same object
TIME_WINDOW_S      = 15.0  # seconds — max time gap within a cluster


def bbox_distance(b1: list, b2: list) -> float:
    """Max of x-distance and y-distance between two bbox origins."""
    return max(abs(b1[0] - b2[0]), abs(b1[1] - b2[1]))


def dedup_enters(enters: list[dict]) -> list[dict]:
    """
    Collapse enter events that represent the same physical object passing
    through the frame. Returns a deduplicated list, keeping the first event
    from each cluster.

    Algorithm: greedy single-pass. Sort by timestamp. For each event, check
    whether it falls within SPATIAL_THRESHOLD and TIME_WINDOW_S of any active
    cluster anchor. If yes, merge into that cluster. If no, start a new cluster.
    Expire clusters whose anchor is more than TIME_WINDOW_S old.
    """
    if not enters:
        return []

    sorted_events = sorted(enters, key=lambda e: e["ts"])
    kept   = []        # anchor event for each active cluster
    result = []        # deduplicated output

    for event in sorted_events:
        t     = datetime.fromisoformat(event["ts"]).timestamp()
        label = event["label"]
        bbox  = event["bbox"]

        # Expire clusters that are too old
        kept = [k for k in kept
                if t - datetime.fromisoformat(k["ts"]).timestamp() <= TIME_WINDOW_S]

        # Look for a matching active cluster (same label, close bbox)
        matched = False
        for anchor in kept:
            if anchor["label"] == label and bbox_distance(anchor["bbox"], bbox) <= SPATIAL_THRESHOLD:
                matched = True
                break

        if not matched:
            # New cluster — keep this event
            kept.append(event)
            result.append(event)
        # else: duplicate — discard

    return result


def summarize(log_dir: Path, out_path: Path, dry_run: bool,
              spatial: int, time_window: float) -> None:
    global SPATIAL_THRESHOLD, TIME_WINDOW_S
    SPATIAL_THRESHOLD = spatial
    TIME_WINDOW_S     = time_window

    # day → label → count  (raw and deduped)
    raw_counts:   dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    dedup_counts: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))

    # Collect all enter events across all log files, grouped by date
    enters_by_date: dict[str, list[dict]] = defaultdict(list)

    log_files = sorted(log_dir.glob("events.jsonl*"))
    if not log_files:
        print(f"[reprocess] No event log files found in {log_dir}")
        return

    total_raw = 0
    for log_file in log_files:
        print(f"[reprocess] Reading {log_file.name}")
        try:
            with open(log_file, encoding="utf-8") as f:
                for lineno, line in enumerate(f, 1):
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        record = json.loads(line)
                    except json.JSONDecodeError:
                        print(f"[reprocess]   Skipping malformed line {lineno} in {log_file.name}")
                        continue

                    if record.get("event") != "enter":
                        continue

                    ts    = record.get("ts", "")
                    date  = ts[:10] if len(ts) >= 10 else "unknown"
                    label = record.get("label", "unknown")

                    raw_counts[date][label] += 1
                    enters_by_date[date].append(record)
                    total_raw += 1

        except OSError as e:
            print(f"[reprocess] Error reading {log_file}: {e}")

    # Dedup per day and count
    total_dedup = 0
    for date, enters in sorted(enters_by_date.items()):
        deduped = dedup_enters(enters)
        for event in deduped:
            dedup_counts[date][event["label"]] += 1
        total_dedup += len(deduped)

    # Print comparison
    print()
    print(f"{'Date':<12}  {'Raw':>6}  {'Dedup':>6}  {'Reduction':>10}  By label")
    print("-" * 70)
    for date in sorted(raw_counts.keys(), reverse=True):
        raw_total   = sum(raw_counts[date].values())
        dedup_total = sum(dedup_counts[date].values())
        pct         = 100 * (1 - dedup_total / raw_total) if raw_total else 0
        label_str   = "  ".join(
            f"{lbl}:{dedup_counts[date].get(lbl,0)}"
            for lbl in sorted(raw_counts[date])
        )
        print(f"{date:<12}  {raw_total:>6}  {dedup_total:>6}  {pct:>9.0f}%  {label_str}")

    print("-" * 70)
    overall_pct = 100 * (1 - total_dedup / total_raw) if total_raw else 0
    print(f"{'TOTAL':<12}  {total_raw:>6}  {total_dedup:>6}  {overall_pct:>9.0f}%")
    print()
    print(f"Spatial threshold: {SPATIAL_THRESHOLD}px   Time window: {TIME_WINDOW_S}s")
    print()

    if dry_run:
        print("[reprocess] Dry run — summary.json not written.")
        return

    # Build output structure
    days = []
    for date in sorted(dedup_counts.keys(), reverse=True):
        label_counts = dedup_counts[date]
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

    print(f"[reprocess] Wrote {len(days)} day(s) to {out_path}")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Rebuild summary.json from raw logs with corrected dedup")
    parser.add_argument("--log-dir", type=Path, default=LOG_DIR_DEFAULT,
                        help=f"Directory containing events.jsonl files (default: {LOG_DIR_DEFAULT})")
    parser.add_argument("--out", type=Path, default=OUT_DEFAULT,
                        help=f"Output path for summary.json (default: {OUT_DEFAULT})")
    parser.add_argument("--dry-run", action="store_true",
                        help="Print stats only, do not write summary.json")
    parser.add_argument("--spatial", type=int, default=SPATIAL_THRESHOLD,
                        help=f"Spatial dedup threshold in pixels (default: {SPATIAL_THRESHOLD})")
    parser.add_argument("--time-window", type=float, default=TIME_WINDOW_S,
                        help=f"Time window in seconds for clustering (default: {TIME_WINDOW_S})")
    args = parser.parse_args()

    summarize(args.log_dir, args.out, args.dry_run, args.spatial, args.time_window)


if __name__ == "__main__":
    main()
