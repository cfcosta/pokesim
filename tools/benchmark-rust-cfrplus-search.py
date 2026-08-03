#!/usr/bin/env python3
"""Compare Python RM+, native RM+, and native CFR+ on exact deep searches."""

from __future__ import annotations

import argparse
import json
import random
import sys
import time
from pathlib import Path
from typing import Any

import torch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "packages" / "battle-training"))

from battle_training.joint_search import JointSearchConfig, SimultaneousTreeSearch
from battle_training.native import SearchServer, build_search_server
from battle_training.network import load_network
from battle_training.rmplus_native import (
    PYTHON_REFERENCE_BACKEND,
    RUST_RMPLUS_BACKEND,
)


def _profile(
    network: Any,
    seed: int,
    roots: int,
    backend: str,
    cfr_plus: bool,
    depth: int,
    budget: int,
    iterations: int,
) -> tuple[dict[str, Any], list[Any]]:
    config = JointSearchConfig(
        max_depth=depth,
        regret_iterations=iterations,
        inference_batch_size=256,
        max_actions_per_side=13,
        expansion_budget=budget,
        exploration=0.10,
        chance_resample=0.10,
        regret_iterations_per_update=16,
        deeper_joint_rotations=2,
        minimum_expansion_budget=min(192, budget),
        convergence_tolerance=0.005,
        convergence_patience=8,
        adaptive_search=False,
        rmplus_backend=backend,
        cfr_plus_solves=cfr_plus,
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
    return (
        {
            "backend": backend,
            "cfr_plus": cfr_plus,
            "elapsed_seconds": elapsed,
            "milliseconds_per_root": elapsed * 1000 / roots,
            "roots_per_second": roots / elapsed,
            "mean_exploitability": sum(
                float(result.exploitability) for result in results
            )
            / roots,
            "mean_transitions": sum(result.nodes for result in results) / roots,
        },
        results,
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--roots", type=int, default=64)
    parser.add_argument("--seed", type=int, default=77_110_031)
    parser.add_argument("--depth", type=int, default=4)
    parser.add_argument("--budget", type=int, default=320)
    parser.add_argument("--iterations", type=int, default=2048)
    parser.add_argument("--engine", choices=("eager", "compiled"), default="compiled")
    arguments = parser.parse_args()
    if arguments.roots < 1 or arguments.depth < 1 or arguments.budget < 1:
        raise SystemExit("roots, depth, and budget must be positive")
    if not torch.cuda.is_available():
        raise SystemExit("CUDA is required")

    build_search_server()
    device = torch.device("cuda")
    checkpoint = arguments.checkpoint.resolve()
    network = load_network(checkpoint, device)
    network.configure_inference(arguments.engine)
    _profile(
        network,
        arguments.seed - 1,
        min(16, arguments.roots),
        RUST_RMPLUS_BACKEND,
        True,
        arguments.depth,
        arguments.budget,
        arguments.iterations,
    )
    variants = (
        (PYTHON_REFERENCE_BACKEND, False),
        (RUST_RMPLUS_BACKEND, False),
        (RUST_RMPLUS_BACKEND, True),
    )
    rows = []
    results = []
    for backend, cfr_plus in variants:
        row, variant_results = _profile(
            network,
            arguments.seed,
            arguments.roots,
            backend,
            cfr_plus,
            arguments.depth,
            arguments.budget,
            arguments.iterations,
        )
        rows.append(row)
        results.append(variant_results)
    baseline = results[0]
    report = {
        "schema": "exact-search-rust-rmplus-cfrplus-v1",
        "checkpoint": str(checkpoint),
        "device": torch.cuda.get_device_name(device),
        "engine": arguments.engine,
        "roots": arguments.roots,
        "depth": arguments.depth,
        "budget": arguments.budget,
        "iterations": arguments.iterations,
        "variants": rows,
        "native_uniform_speedup": (
            rows[0]["elapsed_seconds"] / rows[1]["elapsed_seconds"]
        ),
        "native_cfrplus_speedup": (
            rows[0]["elapsed_seconds"] / rows[2]["elapsed_seconds"]
        ),
        "uniform_greedy_joint_action_changes": sum(
            (left.player_action, left.enemy_action)
            != (right.player_action, right.enemy_action)
            for left, right in zip(baseline, results[1], strict=True)
        ),
        "cfrplus_greedy_joint_action_changes": sum(
            (left.player_action, left.enemy_action)
            != (right.player_action, right.enemy_action)
            for left, right in zip(baseline, results[2], strict=True)
        ),
        "uniform_identical_payoff_matrices": all(
            left.payoff_matrix == right.payoff_matrix
            for left, right in zip(baseline, results[1], strict=True)
        ),
        "caveat": (
            "Solver and exact-search evidence does not replace same-reset "
            "side-swapped playing-strength gates."
        ),
    }
    print(json.dumps(report, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
