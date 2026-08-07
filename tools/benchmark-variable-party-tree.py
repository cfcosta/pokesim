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
from battle_training.transformer_pipeline import (
    TransformerPipelineConfig,
    _collect_rows,
)


class TimedNetwork:
    def __init__(self, inner: Any) -> None:
        self.inner = inner
        self.config = inner.config
        self.seconds = 0.0
        self.calls: collections.Counter[int] = collections.Counter()
        self.seconds_by_batch: collections.defaultdict[int, float] = (
            collections.defaultdict(float)
        )

    def _record(self, size: int, started: float) -> None:
        elapsed = time.perf_counter() - started
        self.seconds += elapsed
        self.calls[size] += 1
        self.seconds_by_batch[size] += elapsed

    def evaluate(self, features: Any, masks: list[int]) -> Any:
        started = time.perf_counter()
        result = self.inner.evaluate(features, masks)
        self._record(len(masks), started)
        return result

    def evaluate_joint(
        self, features: Any, own_masks: list[int], opponent_masks: list[int]
    ) -> Any:
        started = time.perf_counter()
        result = self.inner.evaluate_joint(features, own_masks, opponent_masks)
        self._record(len(own_masks), started)
        return result

    def evaluate_leaf(self, features: Any) -> Any:
        started = time.perf_counter()
        result = self.inner.evaluate_leaf(features)
        self._record(len(features), started)
        return result


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
        total = 0.0
        end = 0.0
        for start, stop in sorted(self.intervals):
            if start >= end:
                total += stop - start
            elif stop > end:
                total += stop - end
            end = max(end, stop)
        return total

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
) -> tuple[dict[str, Any], list[Any]]:
    with SearchServer() as raw_server:
        server = TimedServer(raw_server)
        snapshots = []
        for index, (player_size, enemy_size) in enumerate(party_sizes(roots)):
            reset = server.reset if index == 0 else server.reset_append
            snapshots.append(reset(seed, index, player_size, enemy_size))
        timed_network = TimedNetwork(network)
        config = JointSearchConfig(
            chance_samples_per_joint=1,
            max_depth=depth,
            regret_iterations=256,
            inference_batch_size=256,
            max_actions_per_side=13,
            regret_iterations_per_update=16,
        )
        searches = [
            SimultaneousTreeSearch(
                server,
                timed_network,
                timed_network,
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
    diagnostics = [result.diagnostics for result in results]
    assert all(row is not None for row in diagnostics)
    network_examples = sum(size * calls for size, calls in timed_network.calls.items())
    native_transitions = sum(size * calls for size, calls in server.calls.items())
    native_seconds = server.wall_seconds()
    report = {
        "roots": roots,
        "depth": depth,
        "elapsed_seconds": elapsed,
        "milliseconds_per_root": elapsed * 1000 / roots,
        "network_seconds": timed_network.seconds,
        "native_seconds": native_seconds,
        "python_seconds": elapsed - timed_network.seconds - native_seconds,
        "network_fraction": timed_network.seconds / elapsed,
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
        "mean_simulations": sum(row["tree_simulations"] for row in diagnostics) / roots,
        "mean_depth": sum(row["tree_max_depth"] for row in diagnostics) / roots,
        "convergence_rate": sum(row["tree_converged"] for row in diagnostics) / roots,
        "mean_inference_cache_hit_rate": sum(
            row["inference_cache_hit_rate"] for row in diagnostics
        )
        / roots,
        "inference_cache_hits": max(row["inference_cache_hits"] for row in diagnostics),
        "inference_cache_misses": max(
            row["inference_cache_misses"] for row in diagnostics
        ),
        "deep_inference_calls": max(row["deep_inference_calls"] for row in diagnostics),
        "mean_deep_inference_batch": max(
            row["mean_deep_inference_batch"] for row in diagnostics
        ),
        "deep_native_calls": max(row["deep_native_calls"] for row in diagnostics),
        "mean_deep_native_batch": max(
            row["mean_deep_native_batch"] for row in diagnostics
        ),
        "deep_overlap_waves": max(row["deep_overlap_waves"] for row in diagnostics),
        "root_joint_actions": [row["root_joint_actions"] for row in diagnostics],
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
        search_depth=4,
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
    network: Any, episodes: int, seed: int, name: str, depth: int
) -> dict[str, Any]:
    config = dataclasses.replace(
        collection_config(network, episodes, seed),
        search_depth=depth,
    )
    path = Path(f"/tmp/variable-party-tree-{name}.jsonl")
    path.unlink(missing_ok=True)
    started = time.perf_counter()
    metrics = _collect_rows(path, network, config, 1, [])
    elapsed = time.perf_counter() - started
    return {
        "name": name,
        "episodes": episodes,
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
                "mean_tree_simulations",
                "mean_tree_max_depth",
                "mean_chance_outcomes",
                "tree_convergence_rate",
                "mean_cross_root_batch_size",
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
    arguments = parser.parse_args()
    if arguments.roots < 1 or not 0 <= arguments.collection_episodes <= 64:
        raise SystemExit("roots must be positive; collection episodes must be in 0..64")
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
    for name, depth in (
        ("depth-1", 1),
        ("depth-2", 2),
        ("depth-4", 4),
        ("depth-8", 8),
    ):
        profile, results = search_profile(
            network, arguments.roots, arguments.seed, depth
        )
        profile["name"] = name
        profiles.append(profile)
        result_sets[depth] = results
    reference = result_sets[4]
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
            "mean_two_side_policy_l1_vs_depth_4": sum(l1) / len(l1),
            "argmax_disagreement_fraction_vs_depth_4": (
                disagreements / (2 * len(results))
            ),
        }
    collections = []
    if arguments.collection_episodes:
        for name, depth in (
            ("depth-1", 1),
            ("depth-2", 2),
            ("depth-4", 4),
            ("depth-8", 8),
        ):
            collections.append(
                collection_profile(
                    network,
                    arguments.collection_episodes,
                    arguments.seed + 1_000_000,
                    name,
                    depth,
                )
            )
    report = {
        "checkpoint": str(arguments.checkpoint.resolve()),
        "device": str(device),
        "roots": arguments.roots,
        "party_sizes": party_sizes(arguments.roots),
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
