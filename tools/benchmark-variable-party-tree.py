#!/usr/bin/env python3
"""Profile variable-party simultaneous tree search and collection throughput."""

from __future__ import annotations

import argparse
import collections
import dataclasses
import json
import math
import random
import threading
import time
from pathlib import Path
from typing import Any

from battle_training.joint_search import JointSearchConfig, SimultaneousTreeSearch
from battle_training.native import SearchServer, build_search_server
from battle_training.network import choose_device, load_network
from battle_training.rmplus_native import RUST_RMPLUS_BACKEND
from battle_training.transformer_pipeline import (
    TransformerPipelineConfig,
    _collect_rows,
)

_INFERENCE_KINDS = (
    "evaluate",
    "evaluate_joint",
    "evaluate_leaf",
    "evaluate_leaf_joint",
)


def merged_seconds(intervals: list[tuple[float, float]]) -> float:
    """Wall-clock covered by a set of possibly overlapping intervals.

    Inference and native stepping run concurrently, so summing their busy
    time double-counts the overlap and can exceed the search's own elapsed
    time. Merging first keeps every reported fraction below one.
    """
    total = 0.0
    end = 0.0
    for start, stop in sorted(intervals):
        if start >= end:
            total += stop - start
        elif stop > end:
            total += stop - end
        end = max(end, stop)
    return total


class _TimedTicket:
    """Charges a deferred batch's settle to the network that launched it."""

    def __init__(self, timer: NetworkTimer, size: int, inner: Any) -> None:
        self.timer = timer
        self.size = size
        self.inner = inner

    def result(self) -> Any:
        started = time.perf_counter()
        output = self.inner.result()
        self.timer.record(self.size, started, count=False)
        return output


class NetworkTimer:
    """Times the real network in place instead of wrapping it in a proxy.

    A proxy hides two things the search checks for by identity: the
    isinstance test that decides whether redundant-action priors get shaped,
    and the begin_*/result pair that lets a batch launch before it settles.
    Shadowing the bound methods on the instance keeps both, so the profile
    describes the same search a training run performs.
    """

    def __init__(self, network: Any) -> None:
        self.network = network
        self.seconds = 0.0
        self.calls: collections.Counter[int] = collections.Counter()
        self.seconds_by_batch: collections.defaultdict[int, float] = (
            collections.defaultdict(float)
        )
        self.lock = threading.Lock()
        self.intervals: list[tuple[float, float]] = []
        self.restore: list[tuple[str, Any]] = []
        for kind in _INFERENCE_KINDS:
            for name in (kind, f"begin_{kind}"):
                inner = getattr(network, name, None)
                if inner is not None:
                    self.restore.append((name, inner))
                    setattr(network, name, self._wrap(name, inner))

    def _wrap(self, name: str, inner: Any) -> Any:
        deferred = name.startswith("begin_")

        def timed(*arguments: Any) -> Any:
            size = len(arguments[0])
            started = time.perf_counter()
            result = inner(*arguments)
            self.record(size, started)
            return _TimedTicket(self, size, result) if deferred else result

        return timed

    def record(self, size: int, started: float, *, count: bool = True) -> None:
        finished = time.perf_counter()
        elapsed = finished - started
        with self.lock:
            self.seconds += elapsed
            self.seconds_by_batch[size] += elapsed
            self.intervals.append((started, finished))
            if count:
                self.calls[size] += 1

    def wall_seconds(self) -> float:
        return merged_seconds(self.intervals)

    def close(self) -> None:
        for name, inner in self.restore:
            setattr(self.network, name, inner)
        self.restore = []


class TimedServer:
    def __init__(self, inner: SearchServer) -> None:
        self.inner = inner
        self.seconds = 0.0
        self.calls: collections.Counter[int] = collections.Counter()
        self.seconds_by_batch: collections.defaultdict[int, float] = (
            collections.defaultdict(float)
        )
        self.lock = threading.Lock()
        self.intervals: list[tuple[float, float]] = []

    def _record(self, size: int, started: float) -> None:
        finished = time.perf_counter()
        elapsed = finished - started
        with self.lock:
            self.seconds += elapsed
            self.calls[size] += 1
            self.seconds_by_batch[size] += elapsed
            self.intervals.append((started, finished))

    def wall_seconds(self) -> float:
        return merged_seconds(self.intervals)

    def search_steps(self, requests: list[tuple[int, int, int, int]]) -> Any:
        started = time.perf_counter()
        result = self.inner.search_steps(requests)
        self._record(len(requests), started)
        return result

    def search_step(self, *arguments: Any) -> Any:
        started = time.perf_counter()
        result = self.inner.search_step(*arguments)
        self._record(1, started)
        return result

    def __getattr__(self, name: str) -> Any:
        return getattr(self.inner, name)


def party_sizes(roots: int) -> list[tuple[int, int]]:
    preferred = [(size, size) for size in range(1, 7)] + [(1, 6), (6, 1)]
    all_sizes = [(player, enemy) for player in range(1, 7) for enemy in range(1, 7)]
    ordered = preferred + [pair for pair in all_sizes if pair not in preferred]
    return [ordered[index % len(ordered)] for index in range(roots)]


def entropy(policy: tuple[float, ...]) -> float:
    return -sum(value * math.log(value) for value in policy if value)


def search_profile(
    network: Any,
    roots: int,
    seed: int,
    depth: int,
    width: int,
) -> tuple[dict[str, Any], list[Any]]:
    timed_network = NetworkTimer(network)
    try:
        with SearchServer() as raw_server:
            server = TimedServer(raw_server)
            snapshots = []
            for index, (player_size, enemy_size) in enumerate(party_sizes(roots)):
                reset = server.reset if index == 0 else server.reset_append
                snapshots.append(reset(seed, index, player_size, enemy_size))
            config = JointSearchConfig(
                chance_samples_per_joint=1,
                max_depth=depth,
                regret_iterations=256,
                inference_batch_size=256,
                max_actions_per_side=13,
                interior_actions_per_side=width,
                regret_iterations_per_update=16,
                # Training solves on the Rust CFR+ kernel; the dataclass
                # default is the pure-Python mirror-prox reference, which is
                # an order of magnitude slower and would swamp every other
                # cost the profile is trying to attribute.
                rmplus_backend=RUST_RMPLUS_BACKEND,
                cfr_plus_solves=True,
            )
            searches = [
                SimultaneousTreeSearch(
                    server,
                    network,
                    network,
                    config,
                    random.Random(seed + 10_000 + index),
                    random.Random(seed + 20_000 + index),
                )
                for index in range(roots)
            ]
            started = time.perf_counter()
            results = SimultaneousTreeSearch.search_many(
                searches, snapshots, sample_actions=False
            )
            elapsed = time.perf_counter() - started
    finally:
        timed_network.close()
    diagnostics = [result.diagnostics for result in results]
    assert all(row is not None for row in diagnostics)
    network_examples = sum(size * calls for size, calls in timed_network.calls.items())
    native_transitions = sum(size * calls for size, calls in server.calls.items())
    network_seconds = timed_network.wall_seconds()
    native_seconds = server.wall_seconds()
    busy_seconds = merged_seconds(timed_network.intervals + server.intervals)
    report = {
        "roots": roots,
        "depth": depth,
        "interior_width": width,
        "elapsed_seconds": elapsed,
        "milliseconds_per_root": elapsed * 1000 / roots,
        "network_seconds": network_seconds,
        "native_seconds": native_seconds,
        # Deferred batches settle while native stepping is in flight, so the
        # two overlap; only what neither covers is the solver and bookkeeping.
        "overlap_seconds": network_seconds + native_seconds - busy_seconds,
        "python_seconds": elapsed - busy_seconds,
        "network_fraction": network_seconds / elapsed,
        "native_fraction": native_seconds / elapsed,
        "network_calls": sum(timed_network.calls.values()),
        "network_examples": network_examples,
        "mean_network_batch": (network_examples / sum(timed_network.calls.values())),
        "network_batches": [
            {
                "size": size,
                "calls": timed_network.calls[size],
                "examples": size * timed_network.calls[size],
                "seconds": timed_network.seconds_by_batch[size],
            }
            for size in sorted(timed_network.calls)
        ],
        "native_calls": sum(server.calls.values()),
        "native_transitions": native_transitions,
        "native_batches": [
            {
                "size": size,
                "calls": server.calls[size],
                "transitions": size * server.calls[size],
                "seconds": server.seconds_by_batch[size],
            }
            for size in sorted(server.calls)
        ],
        "mean_transitions": sum(result.nodes for result in results) / roots,
        "mean_tree_nodes": sum(row["tree_nodes"] for row in diagnostics) / roots,
        "mean_depth": sum(row["tree_depth"] for row in diagnostics) / roots,
        # What a second ply actually buys: how many interior matrices were
        # solved, and how often one of them preferred a different action than
        # the root cell it was refining.
        "mean_interior_nodes": sum(row["tree_interior_nodes"] for row in diagnostics)
        / roots,
        "mean_interior_divergences": sum(
            row["tree_interior_divergences"] for row in diagnostics
        )
        / roots,
        "mean_chance_outcomes": sum(row["chance_outcomes"] for row in diagnostics)
        / roots,
        "mean_sampled_joint_coverage": sum(
            row["sampled_joint_coverage"] for row in diagnostics
        )
        / roots,
        "mean_inference_cache_hit_rate": sum(
            row["inference_cache_hit_rate"] for row in diagnostics
        )
        / roots,
        "inference_cache_hits": max(row["inference_cache_hits"] for row in diagnostics),
        "inference_cache_misses": max(
            row["inference_cache_misses"] for row in diagnostics
        ),
        "cross_root_batch_size": max(
            row["cross_root_batch_size"] for row in diagnostics
        ),
        "cross_root_root_leaves": max(
            row["cross_root_root_leaves"] for row in diagnostics
        ),
        # Root-only keys: a diverged search reports no root at all.
        "mean_root_solves": sum(row.get("root_solves") or 0 for row in diagnostics)
        / roots,
        "mean_root_final_exploitability": sum(
            row.get("root_final_exploitability") or 0.0 for row in diagnostics
        )
        / roots,
        "root_joint_actions": [row.get("root_joint_actions") for row in diagnostics],
        "mean_exploitability": sum(result.exploitability or 0.0 for result in results)
        / roots,
        "mean_policy_entropy": sum(
            (entropy(result.player_policy) + entropy(result.enemy_policy)) / 2
            for result in results
        )
        / roots,
    }
    return report, results


def collection_config(
    network: Any, episodes: int, seed: int
) -> TransformerPipelineConfig:
    model = network.config
    return TransformerPipelineConfig(
        iterations=1,
        selfplay_episodes=episodes,
        arena_episodes=4,
        episode_budget=128,
        search_depth=2,
        epochs=1,
        batch_size=128,
        learning_rate=2e-4,
        weight_decay=1e-4,
        seed=seed,
        device="cuda",
        d_model=model.d_model,
        heads=model.heads,
        layers=model.layers,
        feedforward=model.feedforward,
        promotion_games=16,
        promotion_seed_count=2,
        probe_games=16,
        probe_seed_count=2,
        campaign_games=18,
        campaign_seed_count=2,
        minimum_promotion_score=0.0,
        enforce_quality_gate=False,
        actor_batch_size=min(16, episodes),
        precision=model.precision,
        heuristic_opponents=False,
    )


def collection_profile(
    network: Any, episodes: int, seed: int, name: str, depth: int, width: int
) -> dict[str, Any]:
    config = dataclasses.replace(
        collection_config(network, episodes, seed),
        search_depth=depth,
        interior_actions_per_side=width,
    )
    path = Path(f"/tmp/variable-party-tree-{name}.jsonl")
    path.unlink(missing_ok=True)
    started = time.perf_counter()
    metrics = _collect_rows(path, network, config, 1, [])
    elapsed = time.perf_counter() - started
    return {
        "name": name,
        "episodes": episodes,
        "depth": depth,
        "interior_width": width,
        "elapsed_seconds": elapsed,
        "battles_per_second": episodes / elapsed,
        "decisions_per_second": metrics["transitions"] / elapsed,
        "estimated_minutes_per_500_battles": elapsed / episodes * 500 / 60,
        **{
            key: metrics[key]
            for key in (
                "finished",
                "truncated",
                "semantic_divergences",
                "transitions",
                "examples",
                "mean_decisions",
                "mean_tree_nodes",
                "mean_chance_outcomes",
                "mean_sampled_joint_coverage",
                "mean_cross_root_batch_size",
                "mean_cross_root_root_leaves",
            )
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("checkpoint", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--roots", type=int, default=8)
    parser.add_argument("--collection-episodes", type=int, default=0)
    parser.add_argument("--seed", type=int, default=77_110_031)
    parser.add_argument("--device", default="cuda")
    parser.add_argument(
        "--depths",
        type=lambda text: tuple(int(part) for part in text.split(",")),
        default=(1, 2, 3),
        help=(
            "plies to sweep; every ply past the root multiplies the tree by "
            "the interior width squared, so this stays small on purpose"
        ),
    )
    parser.add_argument("--interior-width", type=int, default=3)
    arguments = parser.parse_args()
    if arguments.roots < 1 or not 0 <= arguments.collection_episodes <= 64:
        raise SystemExit("roots must be positive; collection episodes must be in 0..64")
    if not arguments.depths or any(depth < 1 for depth in arguments.depths):
        raise SystemExit("depths must be a comma-separated list of positive plies")
    if arguments.interior_width < 1:
        raise SystemExit("interior width must be positive")
    build_search_server()
    device = choose_device(arguments.device)
    network = load_network(arguments.checkpoint.resolve(), device)
    if device.type == "cuda":
        with SearchServer() as server:
            warm = server.reset(arguments.seed, 0, 6, 6)
            network.evaluate(
                [warm.player_features] * 96,
                [warm.player_mask] * 96,
            )
    profiles = []
    result_sets: dict[int, list[Any]] = {}
    for depth in arguments.depths:
        profile, results = search_profile(
            network, arguments.roots, arguments.seed, depth, arguments.interior_width
        )
        profile["name"] = f"depth-{depth}"
        profiles.append(profile)
        result_sets[depth] = results
    # The deepest sweep is the closest thing to ground truth on offer, so it
    # is what the shallower ones are scored against.
    deepest = max(result_sets)
    reference = result_sets[deepest]
    stability = {}
    for depth, results in result_sets.items():
        l1 = []
        disagreements = 0
        for result, target in zip(results, reference, strict=True):
            l1.append(
                sum(
                    abs(left - right)
                    for left, right in zip(
                        result.player_policy, target.player_policy, strict=True
                    )
                )
                + sum(
                    abs(left - right)
                    for left, right in zip(
                        result.enemy_policy, target.enemy_policy, strict=True
                    )
                )
            )
            disagreements += max(
                range(13), key=lambda action: result.player_policy[action]
            ) != max(range(13), key=lambda action: target.player_policy[action])
            disagreements += max(
                range(13), key=lambda action: result.enemy_policy[action]
            ) != max(range(13), key=lambda action: target.enemy_policy[action])
        stability[str(depth)] = {
            "mean_two_side_policy_l1_vs_deepest": sum(l1) / len(l1),
            "argmax_disagreement_fraction_vs_deepest": (
                disagreements / (2 * len(results))
            ),
        }
    collections = []
    if arguments.collection_episodes:
        for depth in arguments.depths:
            collections.append(
                collection_profile(
                    network,
                    arguments.collection_episodes,
                    arguments.seed + 1_000_000,
                    f"depth-{depth}",
                    depth,
                    arguments.interior_width,
                )
            )
    report = {
        "checkpoint": str(arguments.checkpoint.resolve()),
        "device": str(device),
        "roots": arguments.roots,
        "party_sizes": party_sizes(arguments.roots),
        "interior_width": arguments.interior_width,
        "stability_reference_depth": deepest,
        "profiles": profiles,
        "target_stability": stability,
        "collection": collections,
        "caveat": "Performance benchmark only; other depths change the teacher.",
    }
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
