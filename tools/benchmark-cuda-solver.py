#!/usr/bin/env python3
"""Synchronized anchored-solver benchmarks, including host transfers and masks."""

from __future__ import annotations

import argparse
import functools
import json
import platform
import statistics
import sys
import time
from pathlib import Path

import numpy as np
import torch
import triton

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "packages" / "battle-training"))

from battle_training.rmplus_native import native_metadata
from battle_training.solver_cuda import (
    _compact,
    _kernel,
    cuda_solver_available,
    solve_anchored_batch,
)


def inputs(
    batch: int, actions: int, legal_count: int, seed: int
) -> tuple[np.ndarray, ...]:
    rng = np.random.default_rng(seed)
    matrix = rng.uniform(-1, 1, (batch, actions, actions))
    player = rng.random((batch, actions))
    enemy = rng.random((batch, actions))
    masks = []
    for _ in range(2):
        mask = np.zeros((batch, actions), dtype=bool)
        for row in mask:
            count = (
                int(rng.integers(1, actions + 1)) if legal_count == 0 else legal_count
            )
            row[rng.choice(actions, size=count, replace=False)] = True
        masks.append(mask)
    player[0] = 0
    enemy[0] = 0
    matrix[0] = 0
    return matrix, player, enemy, *masks


def statistics_ms(samples: list[float]) -> dict[str, float]:
    return {
        "median_ms": statistics.median(samples),
        "p95_ms": float(np.percentile(samples, 95)),
        "min_ms": min(samples),
        "max_ms": max(samples),
    }


def measure(function: object, rounds: int) -> dict[str, float]:
    times = []
    for _ in range(rounds):
        torch.cuda.synchronize()
        start = time.perf_counter()
        function()  # type: ignore[operator]
        torch.cuda.synchronize()
        times.append((time.perf_counter() - start) * 1000)
    return statistics_ms(times)


def regularized_gap(
    args: tuple[np.ndarray, ...], result: object, temperature: float
) -> float:
    matrix, priors_p, priors_q, masks_p, masks_q = args
    gaps = []
    for i in range(len(matrix)):
        m = matrix[i][np.ix_(masks_p[i], masks_q[i])]
        p = result.player_policy[i][masks_p[i]]  # type: ignore[attr-defined]
        q = result.enemy_policy[i][masks_q[i]]  # type: ignore[attr-defined]
        anchors = []
        for prior, mask in ((priors_p[i], masks_p[i]), (priors_q[i], masks_q[i])):
            prior = prior[mask]
            prior = (
                prior / prior.sum()
                if prior.sum() > 0
                else np.full(len(prior), 1 / len(prior))
            )
            prior = np.maximum(prior, 1e-9)
            anchors.append(prior / prior.sum())
        a, b = anchors

        def logsumexp(values: np.ndarray) -> float:
            top = float(values.max())
            return top + float(np.log(np.exp(values - top).sum()))

        def kl(values: np.ndarray, prior: np.ndarray) -> float:
            legal = values > 0
            return float((values[legal] * np.log(values[legal] / prior[legal])).sum())

        gap = temperature * (
            logsumexp(np.log(a) + m @ q / temperature)
            + logsumexp(np.log(b) - p @ m / temperature)
            + kl(p, a)
            + kl(q, b)
        )
        gaps.append(gap)
    return float(max(gaps))


def kernel_only(
    args: tuple[np.ndarray, ...],
    iterations: int,
    temperature: float,
    precision: str,
    rounds: int,
) -> dict[str, float]:
    compact, _, _ = _compact(args)
    batch, actions = compact[1].shape
    dtype = torch.float32 if precision == "fp32" else torch.float64
    tensors = [
        torch.from_numpy(array).to(
            "cuda", dtype=torch.bool if array.dtype == np.bool_ else dtype
        )
        for array in compact
    ]
    output = torch.empty((batch, 2 * actions + 2), device="cuda", dtype=dtype)

    def launch() -> None:
        _kernel()[(batch,)](
            *tensors,
            output,
            iterations,
            temperature,
            ACTIONS=actions,
            BLOCK=triton.next_power_of_2(actions),
            num_warps=1,
            enable_fp_fusion=False,
        )

    launch()
    torch.cuda.synchronize()
    samples = []
    for _ in range(rounds):
        start = torch.cuda.Event(enable_timing=True)
        finish = torch.cuda.Event(enable_timing=True)
        start.record()
        launch()
        finish.record()
        finish.synchronize()
        samples.append(start.elapsed_time(finish))
    return statistics_ms(samples)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--batches", type=int, nargs="+", default=[1, 16, 64, 256])
    parser.add_argument(
        "--legal-counts",
        type=int,
        nargs="+",
        default=[3, 9, 13, 0],
        help="0 uses mixed legal counts",
    )
    parser.add_argument("--iterations", type=int, default=2048)
    parser.add_argument("--temperature", type=float, default=0.02)
    parser.add_argument("--rounds", type=int, default=7)
    parser.add_argument(
        "--precisions", nargs="+", choices=["fp32", "fp64"], default=["fp32", "fp64"]
    )
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if (
        args.rounds < 1
        or any(batch < 1 for batch in args.batches)
        or any(count < 0 or count > 13 for count in args.legal_counts)
    ):
        parser.error("positive rounds/batches and legal counts in [0, 13] required")
    if not cuda_solver_available():
        raise SystemExit(
            "CUDA/Triton driver unavailable; on NixOS set TRITON_LIBCUDA_PATH to the libcuda directory"
        )
    rows = []
    for legal_count in args.legal_counts:
        for batch in args.batches:
            data = inputs(batch, 13, legal_count, 20260908)
            reference = solve_anchored_batch(
                *data, args.iterations, args.temperature, backend="rust"
            )
            rust = measure(
                functools.partial(
                    solve_anchored_batch,
                    *data,
                    args.iterations,
                    args.temperature,
                    backend="rust",
                ),
                args.rounds,
            )
            for precision in args.precisions:
                started = time.perf_counter()
                actual = solve_anchored_batch(
                    *data,
                    args.iterations,
                    args.temperature,
                    backend="cuda",
                    precision=precision,
                )
                first_ms = (time.perf_counter() - started) * 1000
                # The initial call includes first-use JIT only when its shape
                # and temperature were not already compiled in Triton's cache.
                timings = measure(
                    functools.partial(
                        solve_anchored_batch,
                        *data,
                        args.iterations,
                        args.temperature,
                        backend="cuda",
                        precision=precision,
                    ),
                    args.rounds,
                )
                errors = {
                    field: float(
                        np.max(
                            np.abs(getattr(actual, field) - getattr(reference, field))
                        )
                    )
                    for field in (
                        "player_policy",
                        "enemy_policy",
                        "value",
                        "exploitability",
                    )
                }
                tolerance = 2e-5 if precision == "fp32" else 2e-10
                if max(errors.values()) > tolerance:
                    raise RuntimeError(f"differential tolerance exceeded: {errors}")
                row = {
                    "batch": batch,
                    "legal_count": legal_count,
                    "precision": precision,
                    "backend": actual.backend,
                    "first_call_ms": first_ms,
                    "rust_host_to_host": rust,
                    "cuda_host_to_host": timings,
                    "cuda_kernel_events": kernel_only(
                        data, args.iterations, args.temperature, precision, args.rounds
                    ),
                    "host_to_host_speedup": rust["median_ms"] / timings["median_ms"],
                    "max_absolute_error": errors,
                    "max_regularized_gap": regularized_gap(
                        data, actual, args.temperature
                    ),
                    "native_max_regularized_gap": regularized_gap(
                        data, reference, args.temperature
                    ),
                }
                rows.append(row)
                print(
                    f"legal={legal_count or 'mixed'} batch={batch} {precision} host={timings['median_ms']:.3f}ms speedup={row['host_to_host_speedup']:.2f}x max_error={max(errors.values()):.3g}",
                    file=sys.stderr,
                    flush=True,
                )
    report = {
        "schema": "anchored-cuda-solver-benchmark-v1",
        "device": torch.cuda.get_device_name(),
        "torch": torch.__version__,
        "triton": triton.__version__,
        "python": platform.python_version(),
        "native": native_metadata(),
        "iterations": args.iterations,
        "temperature": args.temperature,
        "rounds": args.rounds,
        "timing": "Host-to-host includes validation, legal packing, allocation, H2D, kernel, D2H and policy scatter; synchronized before and after. CUDA events include only the resident-input kernel. JIT warmup excluded from steady samples.",
        "caveat": "Synthetic matrix workload on the live desktop GPU; no end-to-end battle-strength or globally optimal hardware claim.",
        "rows": rows,
    }
    encoded = json.dumps(report, indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded)
    else:
        print(encoded, end="")


if __name__ == "__main__":
    main()
