#!/usr/bin/env python3
"""Compare native and CUDA matrix solvers inside identical full-neural searches."""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
import random
import statistics
import sys
import time
from dataclasses import asdict, replace
from pathlib import Path

import numpy as np
import torch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "packages" / "battle-training"))

from battle_training import FULL_ACTION_COUNT, FULL_FEATURE_COUNT
from battle_training.decision import warm_decision_network
from battle_training.joint_search import JointSearchConfig, SimultaneousTreeSearch
from battle_training.native import SEARCH_SERVER, SearchServer
from battle_training.network import (
    BattleTransformer,
    TransformerConfig,
    configure_determinism,
)
from battle_training.rmplus_native import RUST_RMPLUS_BACKEND, native_metadata
from battle_training.solver_cuda import cuda_solver_available


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--roots", type=int, default=8)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--seed", type=int, default=20260908)
    parser.add_argument("--engine", choices=("eager", "compiled"), default="compiled")
    parser.add_argument("--depth", type=int, default=2)
    parser.add_argument("--chance-samples", type=int, default=4)
    parser.add_argument("--interior-actions", type=int, default=3)
    parser.add_argument("--interior-chance-samples", type=int, default=2)
    parser.add_argument("--iterations", type=int, default=2048)
    parser.add_argument("--d-model", type=int, default=256)
    parser.add_argument("--layers", type=int, default=6)
    parser.add_argument(
        "--output", type=Path, default=ROOT / "output" / "fixed-search-benchmark.json"
    )
    args = parser.parse_args()
    if args.roots < 1 or args.repeats < 1:
        parser.error("roots and repeats must be positive")
    if not cuda_solver_available():
        raise SystemExit("CUDA/Triton unavailable")
    if not SEARCH_SERVER.is_file():
        raise SystemExit("Build the current native search server before benchmarking")

    configure_determinism(args.seed)
    model_config = TransformerConfig(
        feature_count=FULL_FEATURE_COUNT,
        action_count=FULL_ACTION_COUNT,
        d_model=args.d_model,
        heads=8,
        layers=args.layers,
        feedforward=4 * args.d_model,
        precision="bf16",
        token_layout="semantic-entity-v1",
        joint_policy_heads=True,
    )
    network = BattleTransformer(model_config)
    # Scratch production models intentionally start with zero output heads.
    # Nonzero synthetic heads make numerical parity sensitive to leaf values
    # and position-dependent action preferences, without claiming trained play.
    with torch.no_grad():
        for head in (network.policy, network.opponent_policy, network.value[-2]):
            torch.nn.init.normal_(head.weight, std=0.02)
    weights = hashlib.sha256()
    for name, tensor in network.state_dict().items():
        weights.update(name.encode())
        weights.update(tensor.contiguous().numpy().tobytes())
    network.to("cuda").eval()
    network.configure_inference(args.engine)
    config = JointSearchConfig(
        max_depth=args.depth,
        chance_samples_per_joint=args.chance_samples,
        interior_actions_per_side=args.interior_actions,
        interior_chance_samples=args.interior_chance_samples,
        regret_iterations=args.iterations,
        inference_batch_size=256,
        rmplus_backend=RUST_RMPLUS_BACKEND,
        leaf_evaluator="full",
        solver_precision="fp32",
    )
    rows = []
    with SearchServer() as server:

        def roots():
            result = []
            for episode in range(args.roots):
                reset = server.reset if episode == 0 else server.reset_append
                result.append(
                    reset(
                        args.seed,
                        episode,
                        6,
                        6,
                        level100=True,
                        balanced_final_species=True,
                    )
                )
            return result

        snapshots = roots()
        snapshot_identity = [
            {
                "player_hash": item.player_hash,
                "enemy_hash": item.enemy_hash,
                "player_mask": item.player_mask,
                "enemy_mask": item.enemy_mask,
            }
            for item in snapshots
        ]
        warmup = asdict(
            warm_decision_network(network, snapshots[0], search_config=config)
        )

        def measure(backend: str, label: str) -> dict:
            snapshots = roots()
            searches = [
                SimultaneousTreeSearch(
                    server,
                    network,
                    network,
                    replace(config, solver_backend=backend),
                    random.Random(args.seed + 1000 + index),
                    random.Random(args.seed + 2000 + index),
                )
                for index in range(args.roots)
            ]
            requested = server.search_rows_requested
            deduplicated = server.search_rows_deduplicated
            torch.cuda.synchronize()
            started = time.perf_counter()
            results = SimultaneousTreeSearch.search_many(
                searches, snapshots, sample_actions=False
            )
            torch.cuda.synchronize()
            elapsed = time.perf_counter() - started
            if any(result.failure for result in results):
                raise RuntimeError(
                    f"search failed: {[result.failure for result in results]}"
                )
            record = {
                "label": label,
                "requested_backend": backend,
                "elapsed_seconds": elapsed,
                "solver_seconds": sum(search._solver_seconds for search in searches),
                "native_rows_requested": server.search_rows_requested - requested,
                "native_rows_deduplicated": server.search_rows_deduplicated
                - deduplicated,
                "native_rows_executed": (server.search_rows_requested - requested)
                - (server.search_rows_deduplicated - deduplicated),
                "nodes": sum(result.nodes for result in results),
                "solver_matrix_count": sum(
                    int(result.diagnostics["solver_matrix_count"]) for result in results
                ),
                "solver_cuda_matrices": sum(
                    int(result.diagnostics["solver_cuda_matrices"])
                    for result in results
                ),
                "results": [asdict(result) for result in results],
            }
            print(
                f"{label} {backend}: {elapsed:.3f}s total, {record['solver_seconds']:.3f}s solver, {record['native_rows_requested']} native rows, {record['solver_cuda_matrices']} CUDA matrices",
                file=sys.stderr,
                flush=True,
            )
            return record

        # Each backend's first complete fixed search warms simulator/inference
        # paths and the shape-specific solver; excluded from steady repeats.
        cold = [measure(backend, "search-warmup") for backend in ("rust", "auto")]
        for repeat in range(args.repeats):
            # Alternate order to avoid systematically favoring warm caches or
            # one direction of thermal drift on the live desktop GPU.
            for backend in ("rust", "auto") if repeat % 2 == 0 else ("auto", "rust"):
                rows.append(measure(backend, f"repeat-{repeat}"))

    baseline = next(row for row in rows if row["requested_backend"] == "rust")
    comparisons = []
    for row in rows:
        errors = {}
        for field in (
            "player_policy",
            "enemy_policy",
            "root_value",
            "payoff_matrix",
            "exploitability",
        ):
            expected = np.asarray(
                [result[field] for result in baseline["results"]], dtype=np.float64
            )
            actual = np.asarray(
                [result[field] for result in row["results"]], dtype=np.float64
            )
            errors[field] = float(np.max(np.abs(expected - actual)))
        comparisons.append(
            {
                "label": row["label"],
                "backend": row["requested_backend"],
                "max_absolute_error": errors,
                "same_native_work": all(
                    row[field] == baseline[field]
                    for field in (
                        "native_rows_requested",
                        "native_rows_deduplicated",
                        "nodes",
                        "solver_matrix_count",
                    )
                ),
            }
        )
    medians = {
        backend: statistics.median(
            row["elapsed_seconds"]
            for row in rows
            if row["requested_backend"] == backend
        )
        for backend in ("rust", "auto")
    }
    max_error = max(
        error
        for comparison in comparisons
        for error in comparison["max_absolute_error"].values()
    )
    valid = max_error <= 2e-5 and all(row["same_native_work"] for row in comparisons)
    report = {
        "schema": "fixed-work-search-benchmark-v1",
        "device": torch.cuda.get_device_name(),
        "torch": torch.__version__,
        "python": platform.python_version(),
        "network": asdict(model_config),
        "network_sha256": weights.hexdigest(),
        "network_kind": "untrained deterministic scratch weights with nonzero synthetic heads",
        "engine": network.inference_engine,
        "config": asdict(config),
        "native_search_sha256": hashlib.sha256(SEARCH_SERVER.read_bytes()).hexdigest(),
        "native_solver": native_metadata(),
        "seed": args.seed,
        "root_snapshots": snapshot_identity,
        "timing": "Fixed search_many wall time includes native transitions, host orchestration, full BF16 neural inference and transfers, matrix solvers and diagnostics; synchronized at both boundaries. Root reset, model load and startup/first-search warmups excluded from steady samples. Both arms use the identical CUDA neural evaluator; only matrix solver dispatch changes.",
        "shape_warmup": warmup,
        "search_warmups": cold,
        "rows": rows,
        "comparisons": comparisons,
        "parity_passed": valid,
        "median_seconds": medians,
        "end_to_end_speedup": medians["rust"] / medians["auto"],
        "caveat": "Live desktop GPU, fixed synthetic network and root cohort; neither a battle-strength result nor a per-turn latency guarantee.",
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(
        f"End-to-end speedup: {report['end_to_end_speedup']:.2f}x; maximum error {max_error:.3g}; parity={valid}",
        file=sys.stderr,
    )
    if not valid:
        raise SystemExit(
            "Fixed-work parity validation failed; inspect the saved report"
        )


if __name__ == "__main__":
    main()
