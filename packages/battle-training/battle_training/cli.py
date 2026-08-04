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


def _leaf_hidden_layers(text: str) -> tuple[int, ...]:
    sizes = tuple(int(part) for part in text.split(","))
    if not sizes or any(size < 1 for size in sizes):
        raise ValueError("leaf hidden sizes must be positive")
    return sizes


def _lr_milestones(text: str) -> tuple[int, ...]:
    milestones = tuple(int(part) for part in text.split(","))
    if any(milestone < 1 for milestone in milestones):
        raise ValueError("learning-rate milestones must be positive iterations")
    return milestones


def _capacity_defaults(smoke: bool) -> dict[str, object]:
    """Parser defaults for every flag a capacity preset may fill in."""
    return {
        "d_model": 64 if smoke else 256,
        "heads": 4 if smoke else 8,
        "layers": 2 if smoke else 6,
        "feedforward": 192 if smoke else 1024,
        "leaf_hidden_layers": None,
        "replay_window": 2,
        "lr_schedule": "constant",
        "lr_milestones": (),
    }


_CAPACITY_PRESETS: dict[str, dict[str, object]] = {
    "tier-a": {
        "d_model": 192,
        "heads": 8,
        "layers": 6,
        "feedforward": 768,
        "leaf_hidden_layers": (256, 128),
        "replay_window": 3,
        "lr_schedule": "step",
        "lr_milestones": (10, 20),
    },
}


def _apply_capacity_preset(arguments: argparse.Namespace) -> argparse.Namespace:
    preset_name = getattr(arguments, "capacity_preset", None)
    if preset_name is None:
        return arguments
    # Preset values only fill flags still at their parser defaults, so any
    # explicitly passed flag wins over the preset.
    defaults = _capacity_defaults(arguments.command == "transformer-smoke")
    for name, value in _CAPACITY_PRESETS[preset_name].items():
        if getattr(arguments, name) == defaults[name]:
            setattr(arguments, name, value)
    return arguments


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
    defaults = _capacity_defaults(smoke)
    parser = subparsers.add_parser(name)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--iterations", type=int, default=1 if smoke else 30)
    parser.add_argument("--episodes", type=int, default=4 if smoke else 16384)
    parser.add_argument("--arena-episodes", type=int, default=4 if smoke else 1024)
    parser.add_argument("--budget", type=int, default=64 if smoke else 512)
    parser.add_argument("--search-depth", type=int, default=1 if smoke else 4)
    parser.add_argument("--epochs", type=int, default=1)
    parser.add_argument("--batch-size", type=int, default=32 if smoke else 128)
    parser.add_argument("--learning-rate", type=float, default=3e-4 if smoke else 2e-4)
    parser.add_argument("--weight-decay", type=float, default=1e-4)
    parser.add_argument(
        "--lr-schedule", choices=("constant", "step"), default=defaults["lr_schedule"]
    )
    parser.add_argument(
        "--lr-milestones", type=_lr_milestones, default=defaults["lr_milestones"]
    )
    parser.add_argument("--lr-decay-factor", type=float, default=0.1)
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
    parser.add_argument(
        "--capacity-preset", choices=tuple(_CAPACITY_PRESETS), default=None
    )
    parser.add_argument("--d-model", type=int, default=defaults["d_model"])
    parser.add_argument("--heads", type=int, default=defaults["heads"])
    parser.add_argument("--layers", type=int, default=defaults["layers"])
    parser.add_argument("--feedforward", type=int, default=defaults["feedforward"])
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
    parser.add_argument(
        "--leaf-hidden-layers",
        type=_leaf_hidden_layers,
        default=defaults["leaf_hidden_layers"],
        help="comma-separated hidden sizes replacing the two leaf-hidden layers",
    )
    parser.add_argument("--leaf-loss-weight", type=float, default=0.25)
    parser.add_argument(
        "--leaf-ema-decay",
        type=float,
        default=0.0,
        help="per-step EMA decay for the deployed leaf evaluator; 0 disables",
    )
    parser.add_argument(
        "--no-adaptive-search", action="store_false", dest="adaptive_search"
    )
    parser.set_defaults(adaptive_search=True)
    parser.add_argument("--adaptive-warmup-iterations", type=int, default=1)
    parser.add_argument("--adaptive-deep-threshold", type=float, default=0.55)
    parser.add_argument("--adaptive-force-deep-fraction", type=float, default=0.10)
    parser.add_argument("--adaptive-exploitability-threshold", type=float, default=0.08)
    parser.add_argument("--adaptive-payoff-spread-threshold", type=float, default=0.75)
    parser.add_argument("--adaptive-max-false-negative-rate", type=float, default=0.10)
    parser.add_argument("--adaptive-fn-pool-window", type=int, default=1)
    parser.add_argument("--router-fn-exposure-floor", type=float, default=0.02)
    parser.add_argument("--collection-epsilon", type=float, default=0.05)
    parser.add_argument("--collection-epsilon-turns", type=int, default=8)
    parser.add_argument("--policy-target-smoothing", type=float, default=0.02)
    parser.add_argument("--collection-dirichlet-alpha", type=float, default=0.6)
    parser.add_argument("--collection-dirichlet-weight", type=float, default=0.25)
    parser.add_argument("--collection-dirichlet-total", type=float, default=10.0)
    parser.add_argument("--frontier-buffer-size", type=int, default=256)
    parser.add_argument("--frontier-restart-fraction", type=float, default=0.25)
    parser.add_argument("--budget-loss-weight", type=float, default=0.05)
    parser.add_argument("--budget-positive-weight", type=float, default=4.0)
    parser.add_argument("--chance-samples-per-joint", type=int, default=2)
    parser.add_argument("--regret-iterations", type=int, default=2048)
    parser.add_argument("--inference-batch-size", type=int, default=256)
    parser.add_argument("--max-actions-per-side", type=int, default=13)
    parser.add_argument("--replay-window", type=int, default=defaults["replay_window"])
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
    parser.add_argument("--actor-batch-size", type=int, default=16 if smoke else 64)
    parser.add_argument("--actor-processes", type=int, default=1 if smoke else 8)
    parser.add_argument("--eval-processes", type=int, default=1 if smoke else 12)
    parser.add_argument("--opponent-checkpoint", type=Path, action="append", default=[])
    parser.add_argument("--opponent-fraction", type=float, default=0.67)
    parser.add_argument("--model-opponent-share", type=float, default=0.5)
    parser.add_argument("--historical-window", type=int, default=4)
    parser.add_argument("--shadow-opponent-window", type=int, default=6)
    parser.add_argument("--promotion-games", type=int, default=16 if smoke else 2048)
    parser.add_argument(
        "--promotion-policy-games", type=int, default=4 if smoke else 2048
    )
    parser.add_argument("--promotion-seed-count", type=int, default=2 if smoke else 8)
    parser.add_argument("--probe-games", type=int, default=16 if smoke else 256)
    parser.add_argument("--probe-seed-count", type=int, default=2 if smoke else 8)
    parser.add_argument("--campaign-games", type=int, default=18 if smoke else 288)
    parser.add_argument("--campaign-seed-count", type=int, default=2 if smoke else 8)
    parser.add_argument(
        "--minimum-promotion-score", type=float, default=0.0 if smoke else 0.50
    )
    parser.add_argument(
        "--promotion-nonfinish-policy",
        choices=("losses", "exclude-pairs"),
        default="losses",
    )
    parser.add_argument("--promotion-pooled-z", type=float, default=1.96)
    parser.add_argument(
        "--no-bootstrap-promotion",
        action="store_false",
        dest="bootstrap_promotion",
        help="require full statistical superiority even against the random-init incumbent",
    )
    parser.set_defaults(bootstrap_promotion=True)


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
    arena.add_argument("--regret-iterations", type=int, default=2048)
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
    arena.add_argument(
        "--no-adaptive-search", action="store_false", dest="adaptive_search"
    )
    arena.set_defaults(adaptive_search=True)
    arena.add_argument("--adaptive-deep-threshold", type=float, default=0.55)
    arena.add_argument("--adaptive-force-deep-fraction", type=float, default=0.10)
    arena.add_argument("--adaptive-exploitability-threshold", type=float, default=0.08)
    arena.add_argument("--adaptive-payoff-spread-threshold", type=float, default=0.75)
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
    arguments = _apply_capacity_preset(parser().parse_args(argv))
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
                adaptive_search=arguments.adaptive_search,
                adaptive_deep_threshold=arguments.adaptive_deep_threshold,
                adaptive_force_deep_fraction=(arguments.adaptive_force_deep_fraction),
                adaptive_exploitability_threshold=(
                    arguments.adaptive_exploitability_threshold
                ),
                adaptive_payoff_spread_threshold=(
                    arguments.adaptive_payoff_spread_threshold
                ),
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
            lr_schedule=arguments.lr_schedule,
            lr_milestones=arguments.lr_milestones,
            lr_decay_factor=arguments.lr_decay_factor,
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
            leaf_hidden_layers=arguments.leaf_hidden_layers,
            leaf_loss_weight=arguments.leaf_loss_weight,
            leaf_ema_decay=arguments.leaf_ema_decay,
            adaptive_search=arguments.adaptive_search,
            adaptive_warmup_iterations=arguments.adaptive_warmup_iterations,
            adaptive_deep_threshold=arguments.adaptive_deep_threshold,
            adaptive_force_deep_fraction=arguments.adaptive_force_deep_fraction,
            adaptive_exploitability_threshold=(
                arguments.adaptive_exploitability_threshold
            ),
            adaptive_payoff_spread_threshold=(
                arguments.adaptive_payoff_spread_threshold
            ),
            adaptive_max_false_negative_rate=(
                arguments.adaptive_max_false_negative_rate
            ),
            adaptive_fn_pool_window=arguments.adaptive_fn_pool_window,
            router_fn_exposure_floor=arguments.router_fn_exposure_floor,
            collection_epsilon=arguments.collection_epsilon,
            collection_epsilon_turns=arguments.collection_epsilon_turns,
            policy_target_smoothing=arguments.policy_target_smoothing,
            collection_dirichlet_alpha=arguments.collection_dirichlet_alpha,
            collection_dirichlet_weight=arguments.collection_dirichlet_weight,
            collection_dirichlet_total=arguments.collection_dirichlet_total,
            frontier_buffer_size=arguments.frontier_buffer_size,
            frontier_restart_fraction=arguments.frontier_restart_fraction,
            budget_loss_weight=arguments.budget_loss_weight,
            budget_positive_weight=arguments.budget_positive_weight,
            opponent_checkpoints=tuple(
                str(path.resolve()) for path in arguments.opponent_checkpoint
            ),
            opponent_fraction=arguments.opponent_fraction,
            model_opponent_share=arguments.model_opponent_share,
            historical_window=arguments.historical_window,
            shadow_opponent_window=arguments.shadow_opponent_window,
            promotion_games=arguments.promotion_games,
            promotion_policy_games=arguments.promotion_policy_games,
            promotion_seed_count=arguments.promotion_seed_count,
            probe_games=arguments.probe_games,
            probe_seed_count=arguments.probe_seed_count,
            campaign_games=arguments.campaign_games,
            campaign_seed_count=arguments.campaign_seed_count,
            minimum_promotion_score=arguments.minimum_promotion_score,
            promotion_nonfinish_policy=arguments.promotion_nonfinish_policy,
            promotion_pooled_z=arguments.promotion_pooled_z,
            bootstrap_promotion=arguments.bootstrap_promotion,
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
            eval_processes=arguments.eval_processes,
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
