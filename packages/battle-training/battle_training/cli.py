"""Command-line entry point for training and artifact verification."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from .arena import ArenaConfig, write_arena_report
from .monitor import serve_monitor, write_monitor_state
from .network import choose_device, load_network
from .pipeline import PipelineConfig, run_pipeline, verify_run
from .transformer_pipeline import (
    TransformerPipelineConfig,
    resume_transformer_pipeline,
    run_transformer_pipeline,
    verify_transformer_run,
)


def _failure_message(error: Exception) -> str:
    details = str(error).splitlines()
    return f"{type(error).__name__}: {details[0] if details else 'no detail'}"


def _pipeline_parser(subparsers: argparse._SubParsersAction, name: str) -> None:
    smoke = name.endswith("smoke")
    parser = subparsers.add_parser(name)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--iterations", type=int, default=2 if smoke else 8)
    parser.add_argument("--episodes", type=int, default=128 if smoke else 2000)
    parser.add_argument("--eval-episodes", type=int, default=256 if smoke else 4000)
    parser.add_argument("--budget", type=int, default=128)
    parser.add_argument("--epsilon-byte", type=int, default=64)
    parser.add_argument("--train-seed", type=int, default=20260726)
    parser.add_argument("--evaluation-seed", type=int, default=90210)
    parser.add_argument("--discount", type=float, default=0.97)


def _transformer_parser(subparsers: argparse._SubParsersAction, name: str) -> None:
    smoke = name == "transformer-smoke"
    parser = subparsers.add_parser(name)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--iterations", type=int, default=1 if smoke else 30)
    parser.add_argument("--episodes", type=int, default=4 if smoke else 2048)
    parser.add_argument("--arena-episodes", type=int, default=4 if smoke else 1024)
    parser.add_argument("--budget", type=int, default=64 if smoke else 512)
    parser.add_argument("--search-depth", type=int, default=1 if smoke else 4)
    parser.add_argument("--epochs", type=int, default=1)
    parser.add_argument("--batch-size", type=int, default=32 if smoke else 128)
    parser.add_argument("--learning-rate", type=float, default=3e-4 if smoke else 2e-4)
    parser.add_argument("--weight-decay", type=float, default=1e-4)
    parser.add_argument("--value-loss-weight", type=float, default=0.25)
    parser.add_argument("--redundant-action-prior-scale", type=float, default=0.25)
    parser.add_argument(
        "--weighted-final-species",
        action="store_false",
        dest="balanced_final_species",
        help="retain the legacy evolution-weighted final-species distribution",
    )
    parser.set_defaults(balanced_final_species=True)
    parser.add_argument("--seed", type=int, default=20260726)
    parser.add_argument("--device", default="auto")
    parser.add_argument("--precision", choices=("bf16", "fp32"), default="bf16")
    parser.add_argument(
        "--inference-engine",
        choices=("auto", "eager", "compiled"),
        default="auto",
    )
    parser.add_argument("--warm-start-checkpoint", type=Path)
    parser.add_argument("--warm-start-incumbent-checkpoint", type=Path)
    parser.add_argument(
        "--no-heuristic-opponents", dest="heuristic_opponents", action="store_false"
    )
    parser.add_argument("--d-model", type=int, default=64 if smoke else 128)
    parser.add_argument("--heads", type=int, default=4 if smoke else 8)
    parser.add_argument("--layers", type=int, default=2 if smoke else 4)
    parser.add_argument("--feedforward", type=int, default=192 if smoke else 512)
    parser.add_argument("--token-group-size", type=int, choices=(1, 2, 4, 8), default=1)
    parser.add_argument(
        "--token-layout",
        choices=("scalar-v1", "semantic-entity-v1"),
        default="semantic-entity-v1",
    )
    parser.add_argument(
        "--single-policy-head",
        action="store_false",
        dest="joint_policy_heads",
        help="disable the production dual-policy physical-state evaluator",
    )
    parser.set_defaults(joint_policy_heads=True)
    parser.add_argument(
        "--no-distilled-leaf",
        action="store_false",
        dest="distilled_leaf_evaluator",
    )
    parser.set_defaults(distilled_leaf_evaluator=True)
    parser.add_argument("--leaf-hidden", type=int, default=64)
    parser.add_argument("--leaf-loss-weight", type=float, default=0.25)
    parser.add_argument("--chance-samples-per-joint", type=int, default=1)
    parser.add_argument("--regret-iterations", type=int, default=256)
    parser.add_argument("--inference-batch-size", type=int, default=256)
    parser.add_argument("--max-actions-per-side", type=int, default=13)
    parser.add_argument("--replay-window", type=int, default=2)
    parser.add_argument(
        "--search-every",
        type=int,
        choices=(1,),
        default=1,
        help="fixed at one: every neural action is selected by RM+ search",
    )
    parser.add_argument("--tree-expansion-budget", type=int, default=320)
    parser.add_argument("--tree-exploration", type=float, default=0.10)
    parser.add_argument("--tree-chance-resample", type=float, default=0.10)
    parser.add_argument("--tree-regret-iterations", type=int, default=16)
    parser.add_argument("--tree-deeper-joint-rotations", type=int, default=2)
    parser.add_argument("--tree-minimum-budget", type=int, default=192)
    parser.add_argument("--tree-convergence-tolerance", type=float, default=0.005)
    parser.add_argument("--tree-convergence-patience", type=int, default=8)
    parser.add_argument("--deep-search-fraction", type=float, default=1.0)
    parser.add_argument("--actor-batch-size", type=int, default=16)
    parser.add_argument("--actor-processes", type=int, default=1 if smoke else 2)
    parser.add_argument("--opponent-checkpoint", type=Path, action="append", default=[])
    parser.add_argument("--opponent-fraction", type=float, default=0.5)
    parser.add_argument("--model-opponent-share", type=float, default=0.5)
    parser.add_argument("--historical-window", type=int, default=4)
    parser.add_argument("--promotion-games", type=int, default=16 if smoke else 2048)
    parser.add_argument("--promotion-seed-count", type=int, default=2 if smoke else 8)
    parser.add_argument("--probe-games", type=int, default=16 if smoke else 256)
    parser.add_argument("--probe-seed-count", type=int, default=2 if smoke else 8)
    parser.add_argument("--campaign-games", type=int, default=18 if smoke else 288)
    parser.add_argument("--campaign-seed-count", type=int, default=2 if smoke else 8)
    parser.add_argument(
        "--minimum-promotion-score", type=float, default=0.0 if smoke else 0.50
    )


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(prog="battle-train")
    subparsers = result.add_subparsers(dest="command", required=True)
    _pipeline_parser(subparsers, "tabular-smoke")
    _pipeline_parser(subparsers, "tabular-train")
    _transformer_parser(subparsers, "transformer-smoke")
    _transformer_parser(subparsers, "transformer-train")
    resume = subparsers.add_parser("transformer-resume")
    resume.add_argument("--output", type=Path, required=True)
    monitor = subparsers.add_parser("monitor")
    monitor.add_argument("--run", type=Path, required=True)
    monitor.add_argument("--host", default="127.0.0.1")
    monitor.add_argument("--port", type=int, default=8765)
    monitor.add_argument("--open", dest="open_browser", action="store_true")
    arena = subparsers.add_parser("arena")
    arena.add_argument("--candidate", type=Path, required=True)
    arena.add_argument("--baseline", type=Path, required=True)
    arena.add_argument("--output", type=Path, required=True)
    arena.add_argument("--games", type=int, default=10000)
    arena.add_argument("--budget", type=int, default=512)
    arena.add_argument("--chance-samples-per-joint", type=int, default=1)
    arena.add_argument("--search-depth", type=int, default=4)
    arena.add_argument("--regret-iterations", type=int, default=256)
    arena.add_argument("--inference-batch-size", type=int, default=256)
    arena.add_argument("--tree-expansion-budget", type=int, default=320)
    arena.add_argument("--tree-exploration", type=float, default=0.10)
    arena.add_argument("--tree-chance-resample", type=float, default=0.10)
    arena.add_argument("--tree-regret-iterations", type=int, default=16)
    arena.add_argument("--tree-deeper-joint-rotations", type=int, default=2)
    arena.add_argument("--tree-minimum-budget", type=int, default=192)
    arena.add_argument("--tree-convergence-tolerance", type=float, default=0.005)
    arena.add_argument("--tree-convergence-patience", type=int, default=8)
    arena.add_argument("--redundant-action-prior-scale", type=float, default=0.25)
    arena.add_argument("--seed", type=int, default=90210)
    arena.add_argument("--device", default="auto")
    arena.add_argument(
        "--inference-engine",
        choices=("auto", "eager", "compiled"),
        default="auto",
    )
    arena.add_argument("--replay-games", type=int, default=3)
    arena.add_argument("--seed-count", type=int, default=8)
    verify = subparsers.add_parser("verify")
    verify.add_argument("run", type=Path)
    return result


def main(argv: list[str] | None = None) -> int:
    arguments = parser().parse_args(argv)
    if arguments.command == "monitor":
        serve_monitor(
            arguments.run,
            host=arguments.host,
            port=arguments.port,
            open_browser=arguments.open_browser,
        )
        return 0
    if arguments.command == "arena":
        device = choose_device(arguments.device)
        candidate = load_network(arguments.candidate.resolve(), device)
        baseline = load_network(arguments.baseline.resolve(), device)
        candidate.configure_inference(arguments.inference_engine)
        baseline.configure_inference(arguments.inference_engine)
        report = write_arena_report(
            arguments.output.resolve(),
            candidate,
            baseline,
            ArenaConfig(
                games=arguments.games,
                budget=arguments.budget,
                chance_samples_per_joint=arguments.chance_samples_per_joint,
                search_depth=arguments.search_depth,
                regret_iterations=arguments.regret_iterations,
                inference_batch_size=arguments.inference_batch_size,
                max_actions_per_side=13,
                tree_expansion_budget=arguments.tree_expansion_budget,
                tree_exploration=arguments.tree_exploration,
                tree_chance_resample=arguments.tree_chance_resample,
                tree_regret_iterations=arguments.tree_regret_iterations,
                tree_deeper_joint_rotations=arguments.tree_deeper_joint_rotations,
                tree_minimum_budget=arguments.tree_minimum_budget,
                tree_convergence_tolerance=arguments.tree_convergence_tolerance,
                tree_convergence_patience=arguments.tree_convergence_patience,
                redundant_action_prior_scale=(arguments.redundant_action_prior_scale),
                seed=arguments.seed,
                replay_games=arguments.replay_games,
                seed_count=arguments.seed_count,
            ),
        )
    elif arguments.command == "verify":
        summary = json.loads((arguments.run / "summary.json").read_text())
        if str(summary.get("pipeline", "")).startswith("transformer-"):
            report = verify_transformer_run(arguments.run.resolve())
        else:
            report = verify_run(arguments.run.resolve())
    elif arguments.command == "transformer-resume":
        try:
            report = resume_transformer_pipeline(arguments.output.resolve())
        except Exception as error:
            write_monitor_state(
                arguments.output.resolve(),
                "failed",
                message=_failure_message(error),
            )
            raise
    elif arguments.command.startswith("transformer-"):
        if (
            arguments.iterations < 1
            or arguments.episodes < 1
            or arguments.arena_episodes < 1
        ):
            raise SystemExit("iterations and episode counts must be positive")
        config = TransformerPipelineConfig(
            iterations=arguments.iterations,
            selfplay_episodes=arguments.episodes,
            arena_episodes=arguments.arena_episodes,
            episode_budget=arguments.budget,
            search_depth=arguments.search_depth,
            epochs=arguments.epochs,
            batch_size=arguments.batch_size,
            learning_rate=arguments.learning_rate,
            weight_decay=arguments.weight_decay,
            seed=arguments.seed,
            device=arguments.device,
            d_model=arguments.d_model,
            heads=arguments.heads,
            layers=arguments.layers,
            feedforward=arguments.feedforward,
            token_group_size=arguments.token_group_size,
            token_layout=arguments.token_layout,
            joint_policy_heads=arguments.joint_policy_heads,
            distilled_leaf_evaluator=arguments.distilled_leaf_evaluator,
            leaf_hidden=arguments.leaf_hidden,
            leaf_loss_weight=arguments.leaf_loss_weight,
            opponent_checkpoints=tuple(
                str(path.resolve()) for path in arguments.opponent_checkpoint
            ),
            opponent_fraction=arguments.opponent_fraction,
            model_opponent_share=arguments.model_opponent_share,
            historical_window=arguments.historical_window,
            promotion_games=arguments.promotion_games,
            promotion_seed_count=arguments.promotion_seed_count,
            probe_games=arguments.probe_games,
            probe_seed_count=arguments.probe_seed_count,
            campaign_games=arguments.campaign_games,
            campaign_seed_count=arguments.campaign_seed_count,
            minimum_promotion_score=arguments.minimum_promotion_score,
            enforce_quality_gate=arguments.command == "transformer-train",
            chance_samples_per_joint=arguments.chance_samples_per_joint,
            regret_iterations=arguments.regret_iterations,
            inference_batch_size=arguments.inference_batch_size,
            max_actions_per_side=arguments.max_actions_per_side,
            replay_window=arguments.replay_window,
            search_every=arguments.search_every,
            tree_expansion_budget=arguments.tree_expansion_budget,
            tree_exploration=arguments.tree_exploration,
            tree_chance_resample=arguments.tree_chance_resample,
            tree_regret_iterations=arguments.tree_regret_iterations,
            tree_deeper_joint_rotations=arguments.tree_deeper_joint_rotations,
            tree_minimum_budget=arguments.tree_minimum_budget,
            tree_convergence_tolerance=arguments.tree_convergence_tolerance,
            tree_convergence_patience=arguments.tree_convergence_patience,
            deep_search_fraction=arguments.deep_search_fraction,
            actor_batch_size=arguments.actor_batch_size,
            actor_processes=arguments.actor_processes,
            precision=arguments.precision,
            inference_engine=arguments.inference_engine,
            value_loss_weight=arguments.value_loss_weight,
            redundant_action_prior_scale=arguments.redundant_action_prior_scale,
            balanced_final_species=arguments.balanced_final_species,
            warm_start_checkpoint=(
                str(arguments.warm_start_checkpoint.resolve())
                if arguments.warm_start_checkpoint is not None
                else None
            ),
            warm_start_incumbent_checkpoint=(
                str(arguments.warm_start_incumbent_checkpoint.resolve())
                if arguments.warm_start_incumbent_checkpoint is not None
                else None
            ),
            heuristic_opponents=arguments.heuristic_opponents,
        )
        try:
            report = run_transformer_pipeline(arguments.output.resolve(), config)
        except Exception as error:
            write_monitor_state(
                arguments.output.resolve(),
                "failed",
                message=_failure_message(error),
            )
            raise
    else:
        if (
            arguments.iterations < 1
            or arguments.episodes < 1
            or arguments.eval_episodes < 1
        ):
            raise SystemExit("iterations and episode counts must be positive")
        config = PipelineConfig(
            iterations=arguments.iterations,
            episodes_per_side=arguments.episodes,
            evaluation_episodes_per_side=arguments.eval_episodes,
            budget=arguments.budget,
            epsilon_byte=arguments.epsilon_byte,
            train_seed=arguments.train_seed,
            evaluation_seed=arguments.evaluation_seed,
            discount=arguments.discount,
        )
        report = run_pipeline(arguments.output.resolve(), config)
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0
