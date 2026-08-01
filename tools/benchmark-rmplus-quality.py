#!/usr/bin/env python3
"""Benchmark fresh RM+ root-solve quality and deterministic CPU cost."""

from __future__ import annotations

import argparse
import json
import random
import statistics
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "packages" / "battle-training"))

from battle_training.joint_search import solve_zero_sum_regret


def _matrices(seed: int, count: int, actions: int) -> list[list[list[float]]]:
    rng = random.Random(seed)
    return [
        [[rng.uniform(-1.0, 1.0) for _ in range(actions)] for _ in range(actions)]
        for _ in range(count)
    ]


def _profile(
    matrices: list[list[list[float]]], iterations: int
) -> tuple[
    dict[str, float | int],
    list[tuple[tuple[float, ...], tuple[float, ...], float, float]],
]:
    actions = len(matrices[0])
    priors = [1.0 / actions] * actions
    legal = list(range(actions))
    started = time.perf_counter()
    results = [
        solve_zero_sum_regret(matrix, priors, priors, legal, legal, iterations)
        for matrix in matrices
    ]
    elapsed = time.perf_counter() - started
    exploitabilities = [result[3] for result in results]
    ordered = sorted(exploitabilities)
    p95 = ordered[min(len(ordered) - 1, int(0.95 * len(ordered)))]
    return (
        {
            "iterations": iterations,
            "matrices": len(matrices),
            "elapsed_seconds": elapsed,
            "milliseconds_per_matrix": elapsed * 1000 / len(matrices),
            "mean_exploitability": statistics.fmean(exploitabilities),
            "p95_exploitability": p95,
            "max_exploitability": max(exploitabilities),
        },
        results,
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--matrices", type=int, default=128)
    parser.add_argument("--actions", type=int, default=13)
    parser.add_argument("--seed", type=int, default=77_110_031)
    parser.add_argument("--baseline-iterations", type=int, default=256)
    parser.add_argument("--production-iterations", type=int, default=2048)
    arguments = parser.parse_args()
    if arguments.matrices < 1 or arguments.actions < 1:
        raise SystemExit("matrices and actions must be positive")

    matrices = _matrices(arguments.seed, arguments.matrices, arguments.actions)
    baseline, _ = _profile(matrices, arguments.baseline_iterations)
    production, first = _profile(matrices, arguments.production_iterations)
    _, repeated = _profile(matrices, arguments.production_iterations)
    deterministic = first == repeated
    report = {
        "schema": "fresh-root-rmplus-quality-v1",
        "seed": arguments.seed,
        "actions": arguments.actions,
        "baseline": baseline,
        "production": production,
        "mean_exploitability_reduction": (
            float(baseline["mean_exploitability"])
            / float(production["mean_exploitability"])
        ),
        "byte_stable_python_results": deterministic,
        "caveat": (
            "Random zero-sum matrices measure solver convergence, not Pokemon "
            "playing strength; paired arena gates remain authoritative."
        ),
    }
    print(json.dumps(report, indent=2, sort_keys=True))
    if not deterministic:
        raise SystemExit("repeated deterministic RM+ solve differed")


if __name__ == "__main__":
    main()
