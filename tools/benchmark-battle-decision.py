#!/usr/bin/env python3
"""Measure cold and warm production decisions on native level-100 6v6 roots."""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
import statistics
import sys
import time
from dataclasses import asdict
from pathlib import Path

import torch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "packages" / "battle-training"))

from battle_training import FULL_ACTION_COUNT, FULL_FEATURE_COUNT
from battle_training.artifacts import sha256
from battle_training.decision import (
    BattleDecision,
    decide_battle,
    warm_decision_network,
)
from battle_training.joint_search import JointSearchConfig
from battle_training.native import SEARCH_SERVER, SearchServer, build_search_server
from battle_training.network import (
    BattleTransformer,
    TransformerConfig,
    choose_device,
    configure_determinism,
    load_network,
)
from battle_training.rmplus_native import RUST_RMPLUS_BACKEND


def _record(decision: BattleDecision, episode: int, root) -> dict:
    return {
        "episode": episode,
        "root_player_hash": root.player_hash,
        "root_enemy_hash": root.enemy_hash,
        "root_legal_joint_actions": root.player_mask.bit_count()
        * root.enemy_mask.bit_count(),
        "side": decision.side,
        "action": decision.action,
        "policy": decision.policy.tolist(),
        "opponent_policy": decision.opponent_policy.tolist(),
        "value": decision.value.item(),
        "selected_depth": decision.selected_depth,
        "selected_chance_samples": decision.selected_chance_samples,
        "total_nodes_all_passes": decision.total_nodes,
        "native_rows_requested": decision.native_rows_requested,
        "native_rows_deduplicated": decision.native_rows_deduplicated,
        "elapsed_seconds": decision.elapsed_seconds,
        "budget_seconds": decision.budget_seconds,
        "budget_overrun_seconds": decision.budget_overrun_seconds,
        "stop_reason": decision.stop_reason,
        "next_pass_estimate_seconds": decision.next_pass_estimate_seconds,
        "passes": [asdict(item) for item in decision.passes],
        "selected_search_diagnostics": decision.search_result.diagnostics,
        "exploitability": decision.search_result.exploitability,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint", type=Path)
    parser.add_argument(
        "--checkpoint-component", choices=("incumbent", "learner"), default="incumbent"
    )
    parser.add_argument("--device", default="auto")
    parser.add_argument(
        "--engine", choices=("eager", "compiled", "auto"), default="eager"
    )
    parser.add_argument("--side", choices=("player", "enemy"), default="player")
    parser.add_argument("--decisions", type=int, default=8)
    parser.add_argument("--warmup-decisions", type=int, default=2)
    parser.add_argument("--budget-seconds", type=float, default=3.0)
    parser.add_argument("--max-depth", type=int, default=2)
    parser.add_argument("--chance-samples", type=int, default=4)
    parser.add_argument("--interior-actions", type=int, default=3)
    parser.add_argument("--interior-chance-samples", type=int, default=2)
    parser.add_argument(
        "--precision",
        choices=("bf16", "fp32"),
        default="bf16",
        help="scratch precision; checkpoints preserve saved precision",
    )
    parser.add_argument(
        "--prewarm-buckets",
        action="store_true",
        help="compile every inference bucket after the cold measurement and before warmed decisions",
    )
    parser.add_argument("--inference-batch-size", type=int, default=256)
    parser.add_argument("--regret-iterations", type=int, default=2048)
    parser.add_argument("--redundant-action-prior-scale", type=float, default=0.25)
    parser.add_argument("--d-model", type=int, default=256, help="scratch model width")
    parser.add_argument("--layers", type=int, default=6, help="scratch model depth")
    parser.add_argument(
        "--heads", type=int, default=8, help="scratch model attention heads"
    )
    parser.add_argument(
        "--feedforward", type=int, default=1024, help="scratch model feedforward width"
    )
    parser.add_argument(
        "--solver-backend", choices=("auto", "rust", "cuda"), default="auto"
    )
    parser.add_argument(
        "--leaf-evaluator", choices=("full", "distilled"), default="full"
    )
    parser.add_argument("--seed", type=int, default=772131)
    parser.add_argument("--rebuild-native", action="store_true")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.decisions < 1 or args.warmup_decisions < 0:
        parser.error("decisions must be positive and warmup-decisions nonnegative")
    if args.checkpoint is None and args.checkpoint_component != "incumbent":
        parser.error("checkpoint-component requires a checkpoint")

    setup_started = time.monotonic()
    build_started = time.monotonic()
    if args.rebuild_native or not SEARCH_SERVER.is_file():
        build_search_server()
    native_build_seconds = time.monotonic() - build_started
    source_hashes = {
        str(path.relative_to(ROOT)): sha256(path)
        for path in (
            SEARCH_SERVER,
            Path(__file__).resolve(),
            ROOT / "packages/battle-training/battle_training/decision.py",
            ROOT / "packages/battle-training/battle_training/joint_search.py",
            ROOT / "packages/battle-training/battle_training/network.py",
            ROOT / "packages/battle-training/battle_training/solver_cuda.py",
            ROOT / "packages/battle-training/battle_training/rmplus_native.py",
        )
    }
    device = choose_device(args.device)
    configure_determinism(args.seed)
    load_started = time.monotonic()
    checkpoint_info = None
    if args.checkpoint is not None:
        path = args.checkpoint.resolve()
        key = "model" if args.checkpoint_component == "incumbent" else "learner_model"
        state = "deployed" if args.checkpoint_component == "incumbent" else "learner"
        network = load_network(path, device, state=state)
        model_config = network.config
        checkpoint_info = {
            "path": str(path),
            "component": args.checkpoint_component,
            "state_key": key,
        }
        with path.open("rb") as source:
            checkpoint_info["sha256"] = hashlib.file_digest(
                source, "sha256"
            ).hexdigest()
    else:
        model_config = TransformerConfig(
            feature_count=FULL_FEATURE_COUNT,
            action_count=FULL_ACTION_COUNT,
            d_model=args.d_model,
            heads=args.heads,
            layers=args.layers,
            feedforward=args.feedforward,
            precision=args.precision,
            token_layout="semantic-entity-v1",
            joint_policy_heads=True,
            distilled_leaf_evaluator=args.leaf_evaluator == "distilled",
            distilled_leaf_policy=args.leaf_evaluator == "distilled",
        )
        network = BattleTransformer(model_config).to(device)
    if (
        model_config.feature_count != FULL_FEATURE_COUNT
        or model_config.action_count != FULL_ACTION_COUNT
    ):
        parser.error("benchmark requires the full-party state and action schema")
    network.eval()
    network.configure_inference(args.engine)
    if device.type == "cuda":
        torch.cuda.synchronize(device)
    model_load_seconds = time.monotonic() - load_started
    config = JointSearchConfig(
        max_depth=args.max_depth,
        chance_samples_per_joint=args.chance_samples,
        regret_iterations=args.regret_iterations,
        interior_actions_per_side=args.interior_actions,
        interior_chance_samples=args.interior_chance_samples,
        inference_batch_size=args.inference_batch_size,
        max_actions_per_side=FULL_ACTION_COUNT,
        redundant_action_prior_scale=args.redundant_action_prior_scale,
        rmplus_backend=RUST_RMPLUS_BACKEND,
        solver_backend=args.solver_backend,
        leaf_evaluator=args.leaf_evaluator,
    )
    server_started = time.monotonic()
    with SearchServer() as server:
        server_start_seconds = time.monotonic() - server_started
        setup_seconds = time.monotonic() - setup_started

        def decision(episode: int):
            root = server.reset(
                args.seed, episode, 6, 6, level100=True, balanced_final_species=True
            )
            if device.type == "cuda":
                torch.cuda.reset_peak_memory_stats(device)
            result = decide_battle(
                server,
                network,
                root,
                side=args.side,
                search_config=config,
                budget_seconds=args.budget_seconds,
                seed=args.seed + episode,
            )
            record = _record(result, episode, root)
            record["cuda_peak_allocated_bytes"] = (
                torch.cuda.max_memory_allocated(device)
                if device.type == "cuda"
                else None
            )
            record["cuda_peak_reserved_bytes"] = (
                torch.cuda.max_memory_reserved(device)
                if device.type == "cuda"
                else None
            )
            return record

        cold = decision(0)
        shape_warmup = None
        if args.prewarm_buckets:
            warmup_snapshot = server.reset(
                args.seed, 0, 6, 6, level100=True, balanced_final_species=True
            )
            shape_warmup = asdict(
                warm_decision_network(network, warmup_snapshot, search_config=config)
            )
        warmups = [decision(episode + 1) for episode in range(args.warmup_decisions)]
        measurements = [
            decision(args.warmup_decisions + index + 1)
            for index in range(args.decisions)
        ]
    elapsed = sorted(item["elapsed_seconds"] for item in measurements)
    report = {
        "schema": "battle-decision-budget-v1",
        "model_kind": "loaded-checkpoint"
        if checkpoint_info
        else "untrained-scratch-performance-only",
        "checkpoint": checkpoint_info,
        "model_config": asdict(model_config),
        "model_parameters": sum(
            parameter.numel() for parameter in network.parameters()
        ),
        "search_limits": asdict(config),
        "source_sha256": source_hashes,
        "environment": {
            "platform": platform.platform(),
            "python": platform.python_version(),
            "torch": torch.__version__,
            "device": str(device),
            "gpu": torch.cuda.get_device_name(device)
            if device.type == "cuda"
            else None,
            "engine_requested": args.engine,
            "engine_selected": network._inference_engine,
            "seed": args.seed,
        },
        "timing_boundary": "decide_battle entry through completed search and CPU action/tensor packing; excludes reset and caller JSON serialization",
        "cold_boundary": "first decision in a fresh process; existing torch/triton compiler disk caches are preserved",
        "memory_boundary": "PyTorch allocator peak allocated/reserved bytes per decision; excludes CUDA context and driver memory",
        "population": "independent generated level100 6v6 turn-zero roots; each reset clears native decision-cache reuse",
        "budget_contract": "3 seconds by default is an admission target; nonpreemptible complete passes may overrun; observed maximum is not a guarantee",
        "setup": {
            "total_seconds": setup_seconds,
            "native_build_seconds": native_build_seconds,
            "model_load_seconds": model_load_seconds,
            "server_start_seconds": server_start_seconds,
        },
        "cold_first_decision": cold,
        "inference_shape_warmup": shape_warmup,
        "warmup_decisions": warmups,
        "warm_decisions": measurements,
        "warm_summary": {
            "peak_cuda_allocated_bytes": max(
                item["cuda_peak_allocated_bytes"] for item in measurements
            )
            if device.type == "cuda"
            else None,
            "peak_cuda_reserved_bytes": max(
                item["cuda_peak_reserved_bytes"] for item in measurements
            )
            if device.type == "cuda"
            else None,
            "count": len(elapsed),
            "median_seconds": statistics.median(elapsed),
            "observed_p95_seconds": elapsed[max(0, math_ceil_95(len(elapsed)) - 1)],
            "observed_max_seconds": max(elapsed),
            "budget_overruns": sum(
                item["budget_overrun_seconds"] > 0 for item in measurements
            ),
            "completed_passes": sum(
                sum(p["completed"] for p in item["passes"]) for item in measurements
            ),
            "failed_passes": sum(
                sum(not p["completed"] for p in item["passes"]) for item in measurements
            ),
            "total_nodes": sum(item["total_nodes_all_passes"] for item in measurements),
        },
        "caveat": "This measures implementation latency and completed search work, not playing strength. The scratch model has not learned to play. Compiled paths or shapes first encountered later can still incur compilation beyond warmup.",
    }
    rendered = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.output is not None:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered)
    print(rendered, end="")


def math_ceil_95(count: int) -> int:
    """Nearest-rank observed percentile; no interpolation or population claim."""
    return (95 * count + 99) // 100


if __name__ == "__main__":
    main()
