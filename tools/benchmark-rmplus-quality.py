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
from battle_training.rmplus_native import solve_cold as solve_cold_native


def _matrices(seed: int, count: int, actions: int) -> list[list[list[float]]]:
    rng = random.Random(seed)
    return [
        [[rng.uniform(-1.0, 1.0) for _ in range(actions)] for _ in range(actions)]
        for _ in range(count)
    ]


def _profile(
    matrices: list[list[list[float]]],
    iterations: int,
    *,
    backend: str = "python",
    cfr_plus: bool = False,
) -> tuple[
    dict[str, float | int],
    list[tuple[tuple[float, ...], tuple[float, ...], float, float]],
]:
    actions = len(matrices[0])
    priors = [1.0 / actions] * actions
    legal = list(range(actions))
    started = time.perf_counter()
    if backend == "python":
        results = [
            solve_zero_sum_regret(matrix, priors, priors, legal, legal, iterations)
            for matrix in matrices
        ]
    elif backend == "rust":
        results = [
            solve_cold_native(
                matrix,
                priors,
                priors,
                legal,
                legal,
                iterations,
                cfr_plus=cfr_plus,
            )
            for matrix in matrices
        ]
    else:
        raise ValueError(f"unknown solver backend: {backend}")
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
    parser.add_argument(
        "--cfr-iterations",
        type=int,
        nargs="+",
        default=(64, 128, 256, 2048),
    )
    arguments = parser.parse_args()
    if arguments.matrices < 1 or arguments.actions < 1:
        raise SystemExit("matrices and actions must be positive")

    matrices = _matrices(arguments.seed, arguments.matrices, arguments.actions)
    baseline, _ = _profile(matrices, arguments.baseline_iterations)
    production, first = _profile(matrices, arguments.production_iterations)
    _, repeated = _profile(matrices, arguments.production_iterations)
    deterministic = first == repeated
    native_uniform, native_results = _profile(
        matrices, arguments.production_iterations, backend="rust"
    )
    _, native_repeated = _profile(
        matrices, arguments.production_iterations, backend="rust"
    )
    cfr_profiles = {}
    for iterations in arguments.cfr_iterations:
        profile, _ = _profile(matrices, iterations, backend="rust", cfr_plus=True)
        cfr_profiles[str(iterations)] = profile
    policy_l1 = [
        sum(
            abs(left - right)
            for left, right in zip(
                (*python[0], *python[1]), (*native[0], *native[1]), strict=True
            )
        )
        for python, native in zip(first, native_results, strict=True)
    ]
    report = {
        "schema": "fresh-root-rmplus-quality-v2-rust-cfrplus",
        "seed": arguments.seed,
        "actions": arguments.actions,
        "baseline": baseline,
        "production": production,
        "native_uniform": native_uniform,
        "native_cfrplus": cfr_profiles,
        "native_uniform_speedup": (
            float(production["elapsed_seconds"])
            / float(native_uniform["elapsed_seconds"])
        ),
        "native_uniform_max_policy_l1_vs_python": max(policy_l1),
        "native_byte_stable_results": native_results == native_repeated,
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
        raise SystemExit("repeated deterministic Python RM+ solve differed")
    if native_results != native_repeated:
        raise SystemExit("repeated deterministic native RM+ solve differed")
    if max(policy_l1) > 1e-12:
        raise SystemExit("native uniform RM+ differs materially from Python")


if __name__ == "__main__":
    main()
