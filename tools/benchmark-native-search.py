#!/usr/bin/env python3
"""Benchmark the Lean search server without neural inference."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import statistics
import time
from pathlib import Path

from battle_training import native


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def legal_actions(mask: int) -> list[int]:
    return [action for action in range(13) if mask & (1 << action)]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--repeats", type=int, default=60)
    parser.add_argument("--seed", type=int, default=987_654_321)
    arguments = parser.parse_args()
    if arguments.repeats < 3:
        raise SystemExit("repeats must be at least three")
    if arguments.binary is None:
        native.build_search_server()
        binary = native.SEARCH_SERVER
    else:
        binary = arguments.binary.resolve()
        if not binary.is_file():
            raise SystemExit(f"search server does not exist: {binary}")
        native.SEARCH_SERVER = binary

    measurements = []
    with native.SearchServer() as server:
        root = server.reset(arguments.seed, 17, 6, 6)
        player_actions = legal_actions(root.player_mask)
        enemy_actions = legal_actions(root.enemy_mask)
        for batch_size in (1, 8, 16, 32, 96):
            # Compaction clears decision-local deduplication outside the timed
            # region. Repeating warmed requests otherwise measures cache hits,
            # not native simulation, projection, or wire IO.
            root = server.compact_many([root])[0]
            requests = [
                (
                    root.handle,
                    player_actions[index % len(player_actions)],
                    enemy_actions[(index * 3) % len(enemy_actions)],
                    arguments.seed + index,
                )
                for index in range(batch_size)
            ]
            for _ in range(3):
                server.search_steps(requests)
            elapsed = []
            native_rows = 0
            for _ in range(arguments.repeats):
                root = server.compact_many([root])[0]
                requested_before = server.search_rows_requested
                deduplicated_before = server.search_rows_deduplicated
                started = time.perf_counter_ns()
                snapshots = server.search_steps(requests)
                elapsed.append((time.perf_counter_ns() - started) / 1000)
                fresh_rows = (
                    server.search_rows_requested
                    - requested_before
                    - (server.search_rows_deduplicated - deduplicated_before)
                )
                if fresh_rows != batch_size:
                    raise RuntimeError(
                        "fresh benchmark unexpectedly reused cached rows"
                    )
                native_rows += fresh_rows
                if len(snapshots) != batch_size:
                    raise RuntimeError("native benchmark lost a branch")
                if any(
                    len(snapshot.player_features) != server.feature_count
                    for snapshot in snapshots
                ):
                    raise RuntimeError("native benchmark received an invalid schema")
            median_us = statistics.median(elapsed)
            ordered = sorted(elapsed)
            cached_elapsed = []
            requested_before = server.search_rows_requested
            deduplicated_before = server.search_rows_deduplicated
            for _ in range(arguments.repeats):
                started = time.perf_counter_ns()
                server.search_steps(requests)
                cached_elapsed.append((time.perf_counter_ns() - started) / 1000)
            cached_native_rows = (
                server.search_rows_requested
                - requested_before
                - (server.search_rows_deduplicated - deduplicated_before)
            )
            if cached_native_rows != 0:
                raise RuntimeError("cache-hit benchmark unexpectedly simulated rows")
            measurements.append(
                {
                    "batch_size": batch_size,
                    "repeats": arguments.repeats,
                    "median_us": median_us,
                    "minimum_us": ordered[0],
                    "p95_us": ordered[math.ceil(len(ordered) * 0.95) - 1],
                    "median_us_per_transition": median_us / batch_size,
                    "fresh_native_rows": native_rows,
                    "cache_hit_median_us": statistics.median(cached_elapsed),
                    "cache_hit_native_rows": cached_native_rows,
                }
            )
        compacted = snapshots[:16]
        compaction_elapsed = []
        for _ in range(arguments.repeats):
            started = time.perf_counter_ns()
            compacted = server.compact_many(compacted)
            compaction_elapsed.append((time.perf_counter_ns() - started) / 1000)
        compact_ordered = sorted(compaction_elapsed)
        compaction = {
            "snapshots": len(compacted),
            "repeats": arguments.repeats,
            "median_us": statistics.median(compaction_elapsed),
            "minimum_us": compact_ordered[0],
            "p95_us": compact_ordered[math.ceil(len(compact_ordered) * 0.95) - 1],
        }

    report = {
        "binary": str(binary.resolve()),
        "binary_sha256": sha256(binary),
        "profile": native.FULL_PROFILE,
        "schema": native.FULL_SCHEMA,
        "measurements": measurements,
        "compaction": compaction,
        "scope": "fresh-chance native mechanics, projection, wire IO and decoding; "
        "dedup is cleared outside each timed sample; cache hits and compaction "
        "are reported separately",
    }
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
