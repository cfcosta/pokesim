#!/usr/bin/env python3
"""Reproducible native full-party RL smoke benchmark (not a semantics oracle)."""
from __future__ import annotations

import argparse
import json
import resource
import statistics
import subprocess
import time
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument(
        "--exe",
        type=Path,
        default=Path("packages/battle-lean/.lake/build/bin/battleFullSelfPlay"),
    )
    args = parser.parse_args()
    elapsed: list[float] = []
    transitions: list[int] = []
    for _ in range(args.runs):
        started = time.perf_counter()
        result = subprocess.run([str(args.exe)], text=True, capture_output=True)
        elapsed.append(time.perf_counter() - started)
        if result.returncode or "PASS 100/100" not in result.stdout:
            print(result.stdout, end="")
            print(result.stderr, end="")
            return result.returncode or 1
        line = next(line for line in result.stdout.splitlines() if "transitions=" in line)
        transitions.append(int(line.rsplit("transitions=", 1)[1]))
    report = {
        "runs": args.runs,
        "episodes_per_run": 100,
        "transitions_per_run": transitions,
        "median_seconds": statistics.median(elapsed),
        "min_seconds": min(elapsed),
        "max_seconds": max(elapsed),
        "max_rss_kb": resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss,
    }
    print(json.dumps(report, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
