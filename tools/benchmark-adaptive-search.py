#!/usr/bin/env python3
"""Measure the controlled root-only ceiling of the learned search router."""

from __future__ import annotations

import argparse
import json
import random
import sys
import time
from pathlib import Path

import torch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "packages" / "battle-training"))

from battle_training import FULL_ACTION_COUNT, FULL_FEATURE_COUNT
from battle_training.joint_search import JointSearchConfig, SimultaneousTreeSearch
from battle_training.native import SearchServer, build_search_server
from battle_training.network import (
    BattleTransformer,
    TransformerConfig,
    configure_determinism,
)


def _roots(server: SearchServer, seed: int, count: int) -> list[object]:
    snapshots = []
    sizes = [(size, size) for size in range(1, 7)] + [(1, 6), (6, 1)]
    for index in range(count):
        player, enemy = sizes[index % len(sizes)]
        reset = server.reset if index == 0 else server.reset_append
        snapshots.append(reset(seed, index, player, enemy))
    return snapshots


def _profile(
    network: BattleTransformer, seed: int, roots: int, adaptive: bool
) -> tuple[dict[str, object], list[object]]:
    config = JointSearchConfig(
        max_depth=4,
        inference_batch_size=256,
        max_actions_per_side=13,
        expansion_budget=320,
        minimum_expansion_budget=192,
        regret_iterations_per_update=16,
        deeper_joint_rotations=2,
        adaptive_search=adaptive,
        adaptive_deep_threshold=0.99,
        adaptive_force_deep_fraction=0.0,
        adaptive_exploitability_threshold=10.0,
        adaptive_payoff_spread_threshold=10.0,
    )
    with SearchServer() as server:
        snapshots = _roots(server, seed, roots)
        searches = [
            SimultaneousTreeSearch(
                server,
                network,
                network,
                config,
                random.Random(seed + 10_000 + index),
                random.Random(seed + 20_000 + index),
                random.Random(seed + 30_000 + index),
            )
            for index in range(roots)
        ]
        started = time.perf_counter()
        results = SimultaneousTreeSearch.search_many(
            searches, snapshots, sample_actions=False
        )
        elapsed = time.perf_counter() - started
    return (
        {
            "elapsed_seconds": elapsed,
            "milliseconds_per_root": elapsed * 1000 / roots,
            "mean_transitions": sum(result.nodes for result in results) / roots,
            "deep_fraction": sum(
                int(result.diagnostics["adaptive_deep_selected"]) for result in results
            )
            / roots,
            "mean_router_score": sum(
                float(result.diagnostics["adaptive_router_score"]) for result in results
            )
            / roots,
        },
        results,
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--roots", type=int, default=16)
    parser.add_argument("--seed", type=int, default=77_110_031)
    parser.add_argument("--engine", choices=("eager", "compiled"), default="compiled")
    arguments = parser.parse_args()
    if not torch.cuda.is_available():
        raise SystemExit("CUDA is required")

    configure_determinism(arguments.seed)
    build_search_server()
    device = torch.device("cuda")
    network = (
        BattleTransformer(
            TransformerConfig(
                feature_count=FULL_FEATURE_COUNT,
                action_count=FULL_ACTION_COUNT,
                d_model=128,
                heads=8,
                layers=4,
                feedforward=512,
                precision="bf16",
                token_layout="semantic-entity-v1",
                joint_policy_heads=True,
                distilled_leaf_evaluator=True,
                leaf_hidden=64,
                adaptive_budget_head=True,
            )
        )
        .to(device)
        .eval()
    )
    with torch.no_grad():
        network.budget.bias.fill_(-10.0)
    network.configure_inference(arguments.engine)

    # Populate static compiler buckets before the measured identical-seed probes.
    _profile(network, arguments.seed - 1, arguments.roots, False)
    _profile(network, arguments.seed - 2, arguments.roots, True)
    full, full_results = _profile(network, arguments.seed, arguments.roots, False)
    adaptive, adaptive_results = _profile(
        network, arguments.seed, arguments.roots, True
    )
    policy_l1 = (
        sum(
            sum(
                abs(left - right)
                for left, right in zip(
                    full_result.player_policy,
                    adaptive_result.player_policy,
                    strict=True,
                )
            )
            + sum(
                abs(left - right)
                for left, right in zip(
                    full_result.enemy_policy,
                    adaptive_result.enemy_policy,
                    strict=True,
                )
            )
            for full_result, adaptive_result in zip(
                full_results, adaptive_results, strict=True
            )
        )
        / arguments.roots
    )
    print(
        json.dumps(
            {
                "schema": "adaptive-search-controlled-ceiling-v1",
                "device": torch.cuda.get_device_name(device),
                "engine": arguments.engine,
                "roots": arguments.roots,
                "full": full,
                "adaptive": adaptive,
                "speedup": float(full["elapsed_seconds"])
                / float(adaptive["elapsed_seconds"]),
                "mean_two_side_policy_l1": policy_l1,
                "caveat": (
                    "Router bias and safety thresholds were forced to root-only; "
                    "this is a throughput ceiling, not a strength result."
                ),
            },
            indent=2,
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
