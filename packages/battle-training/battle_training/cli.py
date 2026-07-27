"""Command-line entry point for training and artifact verification."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from .arena import ArenaConfig, write_arena_report
from .network import choose_device, load_network
from .pipeline import PipelineConfig, run_pipeline, verify_run
from .transformer_pipeline import (
    TransformerPipelineConfig,
    run_transformer_pipeline,
    verify_transformer_run,
)


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
    parser.add_argument("--iterations", type=int, default=1 if smoke else 20)
    parser.add_argument("--episodes", type=int, default=4 if smoke else 256)
    parser.add_argument("--arena-episodes", type=int, default=4 if smoke else 128)
    parser.add_argument("--budget", type=int, default=64 if smoke else 256)
    parser.add_argument("--search-depth", type=int, default=1 if smoke else 2)
    parser.add_argument("--epochs", type=int, default=3 if smoke else 8)
    parser.add_argument("--batch-size", type=int, default=32 if smoke else 256)
    parser.add_argument("--learning-rate", type=float, default=3e-4)
    parser.add_argument("--weight-decay", type=float, default=1e-4)
    parser.add_argument("--seed", type=int, default=20260726)
    parser.add_argument("--device", default="auto")
    parser.add_argument("--d-model", type=int, default=64 if smoke else 128)
    parser.add_argument("--heads", type=int, default=4 if smoke else 8)
    parser.add_argument("--layers", type=int, default=2 if smoke else 4)
    parser.add_argument("--feedforward", type=int, default=192 if smoke else 512)
    parser.add_argument("--chance-samples-per-joint", type=int, default=1)
    parser.add_argument("--regret-iterations", type=int, default=256)
    parser.add_argument("--inference-batch-size", type=int, default=96)
    parser.add_argument("--max-actions-per-side", type=int, default=13)
    parser.add_argument("--replay-window", type=int, default=2)
    parser.add_argument("--search-every", type=int, default=10)
    parser.add_argument("--opponent-checkpoint", type=Path, action="append", default=[])
    parser.add_argument("--opponent-fraction", type=float, default=0.0)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(prog="battle-train")
    subparsers = result.add_subparsers(dest="command", required=True)
    _pipeline_parser(subparsers, "tabular-smoke")
    _pipeline_parser(subparsers, "tabular-train")
    _transformer_parser(subparsers, "transformer-smoke")
    _transformer_parser(subparsers, "transformer-train")
    arena = subparsers.add_parser("arena")
    arena.add_argument("--candidate", type=Path, required=True)
    arena.add_argument("--baseline", type=Path, required=True)
    arena.add_argument("--output", type=Path, required=True)
    arena.add_argument("--games", type=int, default=10000)
    arena.add_argument("--budget", type=int, default=256)
    arena.add_argument("--chance-samples-per-joint", type=int, default=1)
    arena.add_argument("--search-depth", type=int, default=1)
    arena.add_argument("--regret-iterations", type=int, default=256)
    arena.add_argument("--inference-batch-size", type=int, default=96)
    arena.add_argument("--seed", type=int, default=90210)
    arena.add_argument("--device", default="auto")
    arena.add_argument("--replay-games", type=int, default=3)
    arena.add_argument("--search-every", type=int, default=0)
    verify = subparsers.add_parser("verify")
    verify.add_argument("run", type=Path)
    return result


def main(argv: list[str] | None = None) -> int:
    arguments = parser().parse_args(argv)
    if arguments.command == "arena":
        device = choose_device(arguments.device)
        candidate = load_network(arguments.candidate.resolve(), device)
        baseline = load_network(arguments.baseline.resolve(), device)
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
                seed=arguments.seed,
                replay_games=arguments.replay_games,
                search_every=arguments.search_every,
            ),
        )
    elif arguments.command == "verify":
        summary = json.loads((arguments.run / "summary.json").read_text())
        if str(summary.get("pipeline", "")).startswith("transformer-"):
            report = verify_transformer_run(arguments.run.resolve())
        else:
            report = verify_run(arguments.run.resolve())
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
            opponent_checkpoints=tuple(
                str(path.resolve()) for path in arguments.opponent_checkpoint
            ),
            opponent_fraction=arguments.opponent_fraction,
            chance_samples_per_joint=arguments.chance_samples_per_joint,
            regret_iterations=arguments.regret_iterations,
            inference_batch_size=arguments.inference_batch_size,
            max_actions_per_side=arguments.max_actions_per_side,
            replay_window=arguments.replay_window,
            search_every=arguments.search_every,
        )
        report = run_transformer_pipeline(arguments.output.resolve(), config)
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
