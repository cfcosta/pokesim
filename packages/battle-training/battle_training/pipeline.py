"""End-to-end collection, learning, evaluation, and replay verification."""

from __future__ import annotations

import json
import tempfile
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

from . import ENTROPY, PROFILE, SCHEMA
from .artifacts import build_manifest, sha256, verify_manifest, write_json
from .model import MoveValueModel
from .worker import (
    WorkerRequest,
    build_worker,
    run_worker,
    write_request,
)


@dataclass(frozen=True)
class PipelineConfig:
    iterations: int
    episodes_per_side: int
    evaluation_episodes_per_side: int
    budget: int
    epsilon_byte: int
    train_seed: int
    evaluation_seed: int
    discount: float = 0.97


def _evaluation_metrics(path: Path) -> dict[str, Any]:
    stops: dict[str, int] = {}
    wins = losses = draws = transitions = 0
    with path.open() as source:
        for line in source:
            row = json.loads(line)
            if row["type"] != "episode":
                continue
            stops[row["stop"]] = stops.get(row["stop"], 0) + 1
            transitions += row["transitions"]
            if row["return"] == 1:
                wins += 1
            elif row["return"] == -1:
                losses += 1
            elif row["return"] == 0:
                draws += 1
    finished = wins + losses + draws
    return {
        "wins": wins,
        "losses": losses,
        "draws": draws,
        "finished": finished,
        "stops": stops,
        "transitions": transitions,
        "score": (wins + 0.5 * draws) / finished if finished else None,
    }


def _combined_evaluation(
    player: dict[str, Any], enemy: dict[str, Any]
) -> dict[str, Any]:
    finished = player["finished"] + enemy["finished"]
    wins = player["wins"] + enemy["wins"]
    draws = player["draws"] + enemy["draws"]
    return {
        "player_side": player,
        "enemy_side": enemy,
        "combined_finished": finished,
        "combined_score": (wins + 0.5 * draws) / finished if finished else None,
    }


def _evaluate(
    root: Path,
    checkpoint_index: int,
    weights: Path,
    config: PipelineConfig,
) -> dict[str, Any]:
    metrics: dict[str, dict[str, Any]] = {}
    for offset, side in enumerate(("player", "enemy")):
        request = WorkerRequest(
            episodes=config.evaluation_episodes_per_side,
            seed=config.evaluation_seed + offset,
            budget=config.budget,
            epsilon_byte=0,
            weights=weights,
            controlled_side=side,
            emit_transitions=False,
        )
        shard = root / "evaluations" / f"policy-{checkpoint_index:03d}-{side}.jsonl"
        summary = run_worker(shard, request)
        write_request(shard.with_suffix(".request.json"), root, request, summary)
        metrics[side] = _evaluation_metrics(shard)
    combined = _combined_evaluation(metrics["player"], metrics["enemy"])
    write_json(root / "evaluations" / f"policy-{checkpoint_index:03d}.json", combined)
    return combined


def _replay_one(root: Path, request_path: Path, shard_path: Path) -> dict[str, Any]:
    payload = json.loads(request_path.read_text())
    raw = payload["request"]
    request = WorkerRequest(
        episodes=raw["episodes"],
        seed=raw["seed"],
        budget=raw["budget"],
        epsilon_byte=raw["epsilon_byte"],
        weights=root / raw["weights"],
        controlled_side=raw["controlled_side"],
        emit_transitions=raw["emit_transitions"],
    )
    with tempfile.TemporaryDirectory(prefix="battle-training-replay-") as temporary:
        replay = Path(temporary) / "replay.jsonl"
        summary = run_worker(replay, request)
        expected = sha256(shard_path)
        if (
            summary["sha256"] != expected
            or replay.read_bytes() != shard_path.read_bytes()
        ):
            raise ValueError(f"deterministic replay mismatch: {shard_path}")
    return {
        "shard": shard_path.relative_to(root).as_posix(),
        "request": request_path.relative_to(root).as_posix(),
        "sha256": expected,
        "byte_identical": True,
    }


def run_pipeline(root: Path, config: PipelineConfig) -> dict[str, Any]:
    if root.exists() and any(root.iterdir()):
        raise FileExistsError(f"output directory is not empty: {root}")
    root.mkdir(parents=True, exist_ok=True)
    build_worker()
    write_json(
        root / "run.json",
        {
            "pipeline": "terminal-return-move-value-v1",
            "profile": PROFILE,
            "schema": SCHEMA,
            "entropy": ENTROPY,
            "config": asdict(config),
        },
    )

    model = MoveValueModel()
    checkpoints: list[dict[str, Any]] = []
    evaluations: list[dict[str, Any]] = []
    checkpoint = model.checkpoint(root / "checkpoints", 0, {"kind": "neutral"})
    checkpoints.append(checkpoint)
    evaluations.append(_evaluate(root, 0, checkpoint["weights"], config))

    first_shard: Path | None = None
    first_request: Path | None = None
    for iteration in range(1, config.iterations + 1):
        updates: list[dict[str, Any]] = []
        source_weights = checkpoints[-1]["weights"]
        for side_index, side in enumerate(("player", "enemy")):
            request = WorkerRequest(
                episodes=config.episodes_per_side,
                seed=config.train_seed + iteration * 100 + side_index,
                budget=config.budget,
                epsilon_byte=config.epsilon_byte,
                weights=source_weights,
                controlled_side=side,
                emit_transitions=True,
            )
            shard = root / "shards" / f"iteration-{iteration:03d}-{side}.jsonl"
            request_path = shard.with_suffix(".request.json")
            summary = run_worker(shard, request)
            write_request(request_path, root, request, summary)
            update = model.update_shard(shard, config.discount)
            updates.append({"side": side, "summary": summary, "learner": update})
            if first_shard is None:
                first_shard, first_request = shard, request_path
        checkpoint = model.checkpoint(
            root / "checkpoints",
            iteration,
            {
                "kind": "terminal-return-update",
                "iteration": iteration,
                "sources": updates,
            },
        )
        checkpoints.append(checkpoint)
        evaluations.append(_evaluate(root, iteration, checkpoint["weights"], config))

    if first_shard is None or first_request is None:
        raise ValueError("at least one training iteration is required")
    if not any(model.counts) or model.scores == [1000] * len(model.scores):
        raise ValueError("training produced no checkpoint update")

    replay = _replay_one(root, first_request, first_shard)
    write_json(root / "replay-verification.json", replay)
    baseline = evaluations[0]["combined_score"]
    final = evaluations[-1]["combined_score"]
    summary = {
        "profile": PROFILE,
        "iterations": config.iterations,
        "labeled_move_updates": sum(model.counts),
        "moves_updated": sum(count > 0 for count in model.counts),
        "baseline_score": baseline,
        "final_score": final,
        "score_delta": None if baseline is None or final is None else final - baseline,
        "final_checkpoint": checkpoints[-1]["checkpoint"].relative_to(root).as_posix(),
        "final_weights_sha256": checkpoints[-1]["weights_sha256"],
        "deterministic_replay": replay,
    }
    write_json(root / "summary.json", summary)
    write_json(root / "manifest.json", build_manifest(root))
    errors = verify_manifest(root)
    if errors:
        raise ValueError("artifact verification failed: " + "; ".join(errors))
    return summary


def verify_run(root: Path) -> dict[str, Any]:
    build_worker()
    errors = verify_manifest(root)
    if errors:
        raise ValueError("artifact verification failed: " + "; ".join(errors))
    replay = json.loads((root / "replay-verification.json").read_text())
    result = _replay_one(root, root / replay["request"], root / replay["shard"])
    if result["sha256"] != replay["sha256"]:
        raise ValueError("replay verification record differs")
    return {
        "manifest_files": len(
            json.loads((root / "manifest.json").read_text())["files"]
        ),
        "replay": result,
        "summary": json.loads((root / "summary.json").read_text()),
    }
