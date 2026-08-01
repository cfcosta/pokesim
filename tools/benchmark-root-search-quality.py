#!/usr/bin/env python3
"""Compare fresh RM+ solve budgets on exact complete Pokemon root matrices."""

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

from battle_training.joint_search import JointSearchConfig, SimultaneousTreeSearch
from battle_training.native import SearchServer, build_search_server
from battle_training.network import load_network


def _profile(
    network: object, seed: int, roots: int, iterations: int
) -> tuple[dict[str, object], list[object]]:
    config = JointSearchConfig(
        max_depth=1,
        regret_iterations=iterations,
        inference_batch_size=256,
        max_actions_per_side=13,
        expansion_budget=320,
        adaptive_search=False,
    )
    with SearchServer() as server:
        snapshots = []
        for index in range(roots):
            size = 1 + index % 6
            reset = server.reset if index == 0 else server.reset_append
            snapshots.append(reset(seed, index, size, size))
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
    exploitabilities = [float(result.exploitability) for result in results]
    return (
        {
            "iterations": iterations,
            "elapsed_seconds": elapsed,
            "milliseconds_per_root": elapsed * 1000 / roots,
            "mean_exploitability": sum(exploitabilities) / roots,
            "max_exploitability": max(exploitabilities),
            "mean_joint_actions": sum(
                int(result.diagnostics["root_joint_actions"]) for result in results
            )
            / roots,
        },
        results,
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--roots", type=int, default=16)
    parser.add_argument("--seed", type=int, default=77_110_031)
    parser.add_argument("--engine", choices=("eager", "compiled"), default="compiled")
    parser.add_argument("--baseline-iterations", type=int, default=256)
    parser.add_argument("--production-iterations", type=int, default=2048)
    arguments = parser.parse_args()
    if not torch.cuda.is_available():
        raise SystemExit("CUDA is required")

    build_search_server()
    device = torch.device("cuda")
    network = load_network(arguments.checkpoint.resolve(), device)
    network.configure_inference(arguments.engine)
    # Compile and allocate static buckets outside the measured identical roots.
    _profile(
        network, arguments.seed - 1, arguments.roots, arguments.baseline_iterations
    )
    baseline, baseline_results = _profile(
        network, arguments.seed, arguments.roots, arguments.baseline_iterations
    )
    production, production_results = _profile(
        network, arguments.seed, arguments.roots, arguments.production_iterations
    )
    same_matrices = all(
        left.payoff_matrix == right.payoff_matrix
        for left, right in zip(baseline_results, production_results, strict=True)
    )
    action_changes = sum(
        left.player_action != right.player_action
        or left.enemy_action != right.enemy_action
        for left, right in zip(baseline_results, production_results, strict=True)
    )
    report = {
        "schema": "pokemon-complete-root-rmplus-quality-v1",
        "device": torch.cuda.get_device_name(device),
        "engine": arguments.engine,
        "checkpoint": str(arguments.checkpoint.resolve()),
        "roots": arguments.roots,
        "baseline": baseline,
        "production": production,
        "identical_payoff_matrices": same_matrices,
        "greedy_joint_action_changes": action_changes,
        "mean_exploitability_reduction": (
            float(baseline["mean_exploitability"])
            / max(1e-12, float(production["mean_exploitability"]))
        ),
        "caveat": (
            "This isolates root-solver convergence on exact battle matrices; it "
            "does not replace paired playing-strength promotion gates."
        ),
    }
    print(json.dumps(report, indent=2, sort_keys=True))
    if not same_matrices:
        raise SystemExit("solver budgets received different root payoff matrices")


if __name__ == "__main__":
    main()
