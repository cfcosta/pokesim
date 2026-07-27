#!/usr/bin/env python3
"""Benchmark lossy policy-ranked root-action pruning against full 6v6 search."""

from __future__ import annotations

import argparse
import json
import random
import statistics
import time
from pathlib import Path

from battle_training.joint_search import (
    BatchedJointRegretSearch,
    JointSearchConfig,
    legal_actions,
)
from battle_training.native import SearchServer, build_search_server
from battle_training.network import choose_device, load_network


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("checkpoint", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--roots", type=int, default=64)
    parser.add_argument("--seed", type=int, default=71_000_000)
    parser.add_argument("--device", default="auto")
    parser.add_argument("--caps", type=int, nargs="+", default=[4, 6, 13])
    return parser.parse_args()


def main() -> int:
    args = arguments()
    if args.roots < 1 or not args.caps or any(cap < 1 or cap > 13 for cap in args.caps):
        raise SystemExit("roots must be positive and caps must be in 1..13")
    build_search_server()
    network = load_network(args.checkpoint.resolve(), choose_device(args.device))
    timings = {cap: [] for cap in args.caps}
    nodes = {cap: [] for cap in args.caps}
    coverage = {cap: [] for cap in args.caps}
    real_rng = random.Random(args.seed + 1)
    root_index = 0
    with SearchServer() as server:
        for episode in range(args.roots * 2):
            snapshot = server.reset(args.seed, episode)
            for _ in range(64):
                if snapshot.done or snapshot.divergence is not None:
                    break
                player_legal = legal_actions(snapshot.player_mask, 13)
                enemy_legal = legal_actions(snapshot.enemy_mask, 13)
                if (
                    snapshot.request == "battle"
                    and len(player_legal) >= 6
                    and len(enemy_legal) >= 6
                    and root_index < args.roots
                ):
                    if root_index == 0:
                        warmup = BatchedJointRegretSearch(
                            server,
                            network,
                            network,
                            JointSearchConfig(1, 1, 32, 96, max(args.caps)),
                            random.Random(args.seed + 30_000),
                            random.Random(args.seed + 40_000),
                        )
                        warmup.search(snapshot, sample_actions=False)
                    for cap in args.caps:
                        search = BatchedJointRegretSearch(
                            server,
                            network,
                            network,
                            JointSearchConfig(1, 1, 256, 96, cap),
                            random.Random(args.seed + 10_000 + root_index),
                            random.Random(args.seed + 20_000 + root_index),
                        )
                        started = time.perf_counter()
                        result = search.search(snapshot, sample_actions=False)
                        timings[cap].append((time.perf_counter() - started) * 1000)
                        nodes[cap].append(result.nodes)
                        coverage[cap].append(
                            (
                                min(len(player_legal), cap) / len(player_legal)
                                + min(len(enemy_legal), cap) / len(enemy_legal)
                            )
                            / 2
                        )
                    root_index += 1
                snapshot = server.episode_step(
                    snapshot.handle,
                    real_rng.choice(player_legal),
                    real_rng.choice(enemy_legal),
                )
                if snapshot.done or snapshot.divergence is not None:
                    break
                snapshot = server.compact(snapshot.handle)
                if root_index >= args.roots:
                    break
            if root_index >= args.roots:
                break
    if root_index != args.roots:
        raise RuntimeError(f"collected only {root_index}/{args.roots} roots")
    report: dict[str, object] = {
        "checkpoint": str(args.checkpoint.resolve()),
        "roots": args.roots,
        "warning": (
            "Caps below 13 are lossy policy-ranked action pruning and do not "
            "satisfy complete legal-action consideration."
        ),
        "caps": {},
    }
    cap_report = report["caps"]
    assert isinstance(cap_report, dict)
    for cap in args.caps:
        ordered = sorted(timings[cap])
        cap_report[str(cap)] = {
            "mean_ms": statistics.mean(ordered),
            "median_ms": statistics.median(ordered),
            "p95_ms": ordered[max(0, int(0.95 * len(ordered)) - 1)],
            "mean_nodes": statistics.mean(nodes[cap]),
            "mean_action_coverage": statistics.mean(coverage[cap]),
        }
    full = statistics.mean(timings[max(args.caps)])
    report["speedup_vs_largest_cap"] = {
        str(cap): full / statistics.mean(timings[cap]) for cap in args.caps
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
