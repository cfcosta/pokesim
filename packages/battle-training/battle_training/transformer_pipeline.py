"""AlphaZero-style transformer + simultaneous-MCTS training pipeline."""

from __future__ import annotations

import json
import math
import random
import tempfile
from collections.abc import Iterable
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

import torch
from torch import Tensor

from . import ENTROPY, PROFILE, SCHEMA
from .artifacts import build_manifest, sha256, verify_manifest, write_json, write_new
from .mcts import SearchConfig, SimultaneousMCTS
from .native import SearchServer, build_search_server
from .network import (
    BattleTransformer,
    TransformerConfig,
    choose_device,
    configure_determinism,
    load_network,
    save_network,
)


@dataclass(frozen=True)
class TransformerPipelineConfig:
    iterations: int
    selfplay_episodes: int
    arena_episodes: int
    episode_budget: int
    simulations: int
    search_depth: int
    epochs: int
    batch_size: int
    learning_rate: float
    weight_decay: float
    seed: int
    device: str
    d_model: int
    heads: int
    layers: int
    feedforward: int
    opponent_checkpoint: str | None = None
    opponent_fraction: float = 0.0


def _scheduled_for_opponent(episode: int, fraction: float) -> bool:
    """Periodic deterministic mixture with an exact count for rational fractions."""
    return math.floor((episode + 1) * fraction) > math.floor(episode * fraction)


def _jsonl(path: Path, rows: Iterable[dict[str, Any]]) -> None:
    payload = b"".join(
        (json.dumps(row, sort_keys=True, separators=(",", ":")) + "\n").encode()
        for row in rows
    )
    write_new(path, payload)


def _collect_rows(
    path: Path,
    network: BattleTransformer,
    config: TransformerPipelineConfig,
    iteration: int,
    opponent: BattleTransformer | None = None,
    opponent_sha256: str | None = None,
) -> dict[str, Any]:
    search_config = SearchConfig(config.simulations, config.search_depth)
    selection_rng = random.Random(config.seed + iteration * 1_000_003)
    chance_rng = random.Random(config.seed + iteration * 1_000_033 + 17)
    meta: dict[str, Any] = {
        "type": "meta",
        "format": "mcts-policy-value-jsonl-v1",
        "profile": PROFILE,
        "schema": SCHEMA,
        "entropy": ENTROPY,
        "chance": "fresh-root-v1",
        "solver": "simultaneous-exp3-mcts-v1",
        "iteration": iteration,
        "episodes": config.selfplay_episodes,
        "simulations": config.simulations,
        "depth": config.search_depth,
        "seed": config.seed,
    }
    if opponent is not None:
        meta["opponent"] = {
            "kind": "fixed-checkpoint",
            "sha256": opponent_sha256,
            "fraction": config.opponent_fraction,
            "schedule": "balanced-periodic-v1",
        }
    rows: list[dict[str, Any]] = [meta]
    finished = truncated = examples = transitions = 0
    mirror_episodes = opponent_episodes = 0
    candidate_player_episodes = candidate_enemy_episodes = 0
    with SearchServer() as server:
        for episode in range(config.selfplay_episodes):
            versus_opponent = opponent is not None and _scheduled_for_opponent(
                episode, config.opponent_fraction
            )
            if versus_opponent:
                candidate_player = opponent_episodes % 2 == 0
                player_network = network if candidate_player else opponent
                enemy_network = opponent if candidate_player else network
                episode_kind = "fixed-opponent"
                opponent_episodes += 1
                if candidate_player:
                    candidate_player_episodes += 1
                else:
                    candidate_enemy_episodes += 1
            else:
                candidate_player = True
                player_network = network
                enemy_network = network
                episode_kind = "mirror"
                mirror_episodes += 1
            snapshot = server.reset(config.seed + iteration * 10_000, episode)
            pending: list[dict[str, Any]] = []
            for decision in range(config.episode_budget):
                search = SimultaneousMCTS(
                    server,
                    player_network,
                    enemy_network,
                    search_config,
                    selection_rng,
                    chance_rng,
                )
                result = search.search(snapshot, sample_actions=True)
                player_row = {
                    "type": "example",
                    "episode": episode,
                    "decision": decision,
                    "side": "player",
                    "state_hash": snapshot.player_hash,
                    "features": list(snapshot.player_features),
                    "policy": list(result.player_policy),
                    "search_value": result.root_value,
                    "action": result.player_action,
                }
                enemy_row = {
                    "type": "example",
                    "episode": episode,
                    "decision": decision,
                    "side": "enemy",
                    "state_hash": snapshot.enemy_hash,
                    "features": list(snapshot.enemy_features),
                    "policy": list(result.enemy_policy),
                    "search_value": -result.root_value,
                    "action": result.enemy_action,
                }
                if opponent is not None:
                    player_row["episode_kind"] = episode_kind
                    enemy_row["episode_kind"] = episode_kind
                if not versus_opponent or candidate_player:
                    pending.append(player_row)
                if not versus_opponent or not candidate_player:
                    pending.append(enemy_row)
                snapshot = server.episode_step(
                    snapshot.handle, result.player_action, result.enemy_action
                )
                transitions += 1
                if snapshot.done:
                    reward = int(snapshot.terminal_return or 0)
                    for row in pending:
                        row["value"] = reward if row["side"] == "player" else -reward
                    rows.extend(pending)
                    examples += len(pending)
                    rows.append(
                        {
                            "type": "episode",
                            "episode": episode,
                            "stop": "finished",
                            "return": reward,
                            "decisions": decision + 1,
                        }
                    )
                    finished += 1
                    break
                snapshot = server.compact(snapshot.handle)
            else:
                rows.append(
                    {
                        "type": "episode",
                        "episode": episode,
                        "stop": "truncated",
                        "return": None,
                        "decisions": config.episode_budget,
                    }
                )
                truncated += 1
    _jsonl(path, rows)
    if not examples:
        raise ValueError("MCTS self-play produced no terminal training examples")
    return {
        "finished": finished,
        "truncated": truncated,
        "examples": examples,
        "transitions": transitions,
        "mirror_episodes": mirror_episodes,
        "opponent_episodes": opponent_episodes,
        "candidate_player_episodes": candidate_player_episodes,
        "candidate_enemy_episodes": candidate_enemy_episodes,
        "sha256": sha256(path),
        "bytes": path.stat().st_size,
    }


def _load_examples(paths: list[Path]) -> tuple[Tensor, Tensor, Tensor]:
    features: list[list[int]] = []
    policies: list[list[float]] = []
    values: list[float] = []
    for path in paths:
        with path.open() as source:
            for line in source:
                row = json.loads(line)
                if row["type"] != "example":
                    continue
                features.append(row["features"])
                policies.append(row["policy"])
                values.append(row["value"])
    return (
        torch.tensor(features, dtype=torch.long),
        torch.tensor(policies, dtype=torch.float32),
        torch.tensor(values, dtype=torch.float32),
    )


def _train_network(
    network: BattleTransformer,
    optimizer: torch.optim.Optimizer,
    shards: list[Path],
    config: TransformerPipelineConfig,
    iteration: int,
) -> dict[str, Any]:
    device = next(network.parameters()).device
    features, target_policy, target_value = _load_examples(shards)
    generator = torch.Generator(device="cpu").manual_seed(config.seed + iteration)
    network.train()
    history: list[dict[str, float]] = []
    for epoch in range(config.epochs):
        permutation = torch.randperm(len(features), generator=generator)
        policy_total = value_total = total_total = 0.0
        batches = 0
        for start in range(0, len(features), config.batch_size):
            indexes = permutation[start : start + config.batch_size]
            batch_features = features[indexes].to(device)
            batch_policy = target_policy[indexes].to(device)
            batch_value = target_value[indexes].to(device)
            logits, values = network(batch_features)
            policy_loss = (
                -(batch_policy * torch.log_softmax(logits, dim=-1)).sum(dim=-1).mean()
            )
            value_loss = torch.nn.functional.mse_loss(values, batch_value)
            loss = policy_loss + value_loss
            optimizer.zero_grad(set_to_none=True)
            loss.backward()
            torch.nn.utils.clip_grad_norm_(network.parameters(), 1.0)
            optimizer.step()
            policy_total += float(policy_loss.detach())
            value_total += float(value_loss.detach())
            total_total += float(loss.detach())
            batches += 1
        history.append(
            {
                "epoch": epoch,
                "policy_loss": policy_total / batches,
                "value_loss": value_total / batches,
                "total_loss": total_total / batches,
            }
        )
    network.eval()
    return {
        "examples": len(features),
        "epochs": config.epochs,
        "batches_per_epoch": math.ceil(len(features) / config.batch_size),
        "history": history,
    }


def _play_game(
    server: SearchServer,
    player: BattleTransformer,
    enemy: BattleTransformer,
    config: TransformerPipelineConfig,
    episode: int,
    selection_rng: random.Random,
    chance_rng: random.Random,
) -> int | None:
    snapshot = server.reset(config.seed + 90_000_000, episode)
    search_config = SearchConfig(config.simulations, config.search_depth)
    for _ in range(config.episode_budget):
        search = SimultaneousMCTS(
            server, player, enemy, search_config, selection_rng, chance_rng
        )
        result = search.search(snapshot, sample_actions=False)
        snapshot = server.episode_step(
            snapshot.handle, result.player_action, result.enemy_action
        )
        if snapshot.done:
            return snapshot.terminal_return
        snapshot = server.compact(snapshot.handle)
    return None


def _arena(
    candidate: BattleTransformer,
    baseline: BattleTransformer,
    config: TransformerPipelineConfig,
) -> dict[str, Any]:
    selection_rng = random.Random(config.seed + 0xA7E9A)
    chance_rng = random.Random(config.seed + 0xA7E9B)
    wins = losses = draws = truncated = 0
    games: list[dict[str, Any]] = []
    with SearchServer() as server:
        for episode in range(config.arena_episodes):
            candidate_player = episode % 2 == 0
            result = _play_game(
                server,
                candidate if candidate_player else baseline,
                baseline if candidate_player else candidate,
                config,
                episode,
                selection_rng,
                chance_rng,
            )
            candidate_result = result if candidate_player or result is None else -result
            if candidate_result == 1:
                wins += 1
            elif candidate_result == -1:
                losses += 1
            elif candidate_result == 0:
                draws += 1
            else:
                truncated += 1
            games.append(
                {
                    "episode": episode,
                    "candidate_side": "player" if candidate_player else "enemy",
                    "candidate_return": candidate_result,
                }
            )
    finished = wins + losses + draws
    return {
        "wins": wins,
        "losses": losses,
        "draws": draws,
        "truncated": truncated,
        "finished": finished,
        "score": (wins + 0.5 * draws) / finished if finished else None,
        "games": games,
    }


def _parameter_distance(before: BattleTransformer, after: BattleTransformer) -> float:
    total = torch.zeros((), device=next(after.parameters()).device)
    for left, right in zip(before.parameters(), after.parameters(), strict=True):
        total += torch.sum((left.to(total.device) - right) ** 2)
    return float(torch.sqrt(total).detach().cpu())


def run_transformer_pipeline(
    root: Path, config: TransformerPipelineConfig
) -> dict[str, Any]:
    if root.exists() and any(root.iterdir()):
        raise FileExistsError(f"output directory is not empty: {root}")
    root.mkdir(parents=True, exist_ok=True)
    if not 0.0 <= config.opponent_fraction <= 1.0:
        raise ValueError("opponent_fraction must be in [0, 1]")
    if (config.opponent_checkpoint is None) != (config.opponent_fraction == 0.0):
        raise ValueError(
            "opponent_checkpoint and a positive opponent_fraction must be supplied together"
        )
    build_search_server()
    configure_determinism(config.seed)
    device = choose_device(config.device)
    opponent: BattleTransformer | None = None
    opponent_sha: str | None = None
    opponent_metadata: dict[str, Any] | None = None
    if config.opponent_checkpoint is not None:
        opponent_source = Path(config.opponent_checkpoint).resolve()
        opponent_sha = sha256(opponent_source)
        opponent_copy = root / "opponents" / "fixed-checkpoint.pt"
        write_new(opponent_copy, opponent_source.read_bytes())
        opponent = load_network(opponent_copy, device)
        opponent_metadata = {
            "kind": "fixed-checkpoint",
            "checkpoint": opponent_copy.relative_to(root).as_posix(),
            "sha256": opponent_sha,
            "fraction": config.opponent_fraction,
            "schedule": "balanced-periodic-v1",
        }
    model_config = TransformerConfig(
        d_model=config.d_model,
        heads=config.heads,
        layers=config.layers,
        feedforward=config.feedforward,
    )
    network = BattleTransformer(model_config).to(device)
    network.eval()
    initial = network.detached_copy(device)
    write_json(
        root / "run.json",
        {
            "pipeline": "transformer-simultaneous-exp3-mcts-v1",
            "profile": PROFILE,
            "schema": SCHEMA,
            "chance": "fresh-root-v1",
            "config": asdict(config),
            "network": asdict(model_config),
            "parameter_count": sum(
                parameter.numel() for parameter in network.parameters()
            ),
            "opponent": opponent_metadata,
            "torch": torch.__version__,
            "device": str(device),
            "device_name": torch.cuda.get_device_name(device)
            if device.type == "cuda"
            else "cpu",
        },
    )
    initial_checkpoint = root / "checkpoints" / "policy-000.pt"
    save_network(initial_checkpoint, network, None, {"iteration": 0, "kind": "initial"})
    shards: list[Path] = []
    collection: list[dict[str, Any]] = []
    training: list[dict[str, Any]] = []
    optimizer = torch.optim.AdamW(
        network.parameters(), lr=config.learning_rate, weight_decay=config.weight_decay
    )
    for iteration in range(1, config.iterations + 1):
        shard = root / "shards" / f"iteration-{iteration:03d}.jsonl"
        collection_metrics = _collect_rows(
            shard, network, config, iteration, opponent, opponent_sha
        )
        shards.append(shard)
        collection.append(collection_metrics)
        training_metrics = _train_network(network, optimizer, shards, config, iteration)
        training.append(training_metrics)
        checkpoint = root / "checkpoints" / f"policy-{iteration:03d}.pt"
        save_network(
            checkpoint,
            network,
            optimizer,
            {
                "iteration": iteration,
                "source_shards": [path.relative_to(root).as_posix() for path in shards],
                "collection": collection_metrics,
                "training": training_metrics,
            },
        )
        write_json(
            root / "metrics" / f"iteration-{iteration:03d}.json",
            {"collection": collection_metrics, "training": training_metrics},
        )
    distance = _parameter_distance(initial, network)
    if distance == 0.0:
        raise ValueError("transformer parameters did not update")
    arena = _arena(network, initial, config)
    write_json(root / "arena" / "final-vs-initial.json", arena)
    opponent_arena = _arena(network, opponent, config) if opponent is not None else None
    if opponent_arena is not None:
        write_json(root / "arena" / "final-vs-fixed-opponent.json", opponent_arena)

    with tempfile.TemporaryDirectory(prefix="battle-transformer-replay-") as temporary:
        replay_path = Path(temporary) / "replay.jsonl"
        replay_network = load_network(initial_checkpoint, device)
        replay_metrics = _collect_rows(
            replay_path, replay_network, config, 1, opponent, opponent_sha
        )
        replay_identical = replay_path.read_bytes() == shards[0].read_bytes()
        if not replay_identical:
            raise ValueError("MCTS self-play shard failed deterministic replay")
    replay = {
        "shard": shards[0].relative_to(root).as_posix(),
        "sha256": replay_metrics["sha256"],
        "byte_identical": True,
    }
    summary = {
        "pipeline": "transformer-simultaneous-exp3-mcts-v1",
        "device": str(device),
        "iterations": config.iterations,
        "selfplay_battles": config.iterations * config.selfplay_episodes,
        "mirror_battles": sum(item["mirror_episodes"] for item in collection),
        "opponent_battles": sum(item["opponent_episodes"] for item in collection),
        "parameter_count": sum(parameter.numel() for parameter in network.parameters()),
        "examples": sum(item["examples"] for item in collection),
        "parameter_l2_delta": distance,
        "initial_checkpoint_sha256": sha256(initial_checkpoint),
        "final_checkpoint": f"checkpoints/policy-{config.iterations:03d}.pt",
        "final_checkpoint_sha256": sha256(
            root / "checkpoints" / f"policy-{config.iterations:03d}.pt"
        ),
        "final_training_loss": training[-1]["history"][-1],
        "arena": arena,
        "opponent_arena": opponent_arena,
        "opponent": opponent_metadata,
        "deterministic_replay": replay,
    }
    write_json(root / "summary.json", summary)
    write_json(root / "manifest.json", build_manifest(root))
    errors = verify_manifest(root)
    if errors:
        raise ValueError("artifact verification failed: " + "; ".join(errors))
    return summary


def verify_transformer_run(root: Path) -> dict[str, Any]:
    """Verify hashes and regenerate the first MCTS shard from checkpoint zero."""
    build_search_server()
    errors = verify_manifest(root)
    if errors:
        raise ValueError("artifact verification failed: " + "; ".join(errors))
    run = json.loads((root / "run.json").read_text())
    config = TransformerPipelineConfig(**run["config"])
    configure_determinism(config.seed)
    device = choose_device(config.device)
    network = load_network(root / "checkpoints" / "policy-000.pt", device)
    opponent_metadata = run.get("opponent")
    opponent = None
    opponent_sha = None
    if opponent_metadata is not None:
        opponent_path = root / opponent_metadata["checkpoint"]
        opponent_sha = sha256(opponent_path)
        if opponent_sha != opponent_metadata["sha256"]:
            raise ValueError("fixed opponent checkpoint hash mismatch")
        opponent = load_network(opponent_path, device)
    shard = root / "shards" / "iteration-001.jsonl"
    with tempfile.TemporaryDirectory(prefix="battle-transformer-verify-") as temporary:
        replay = Path(temporary) / "replay.jsonl"
        metrics = _collect_rows(replay, network, config, 1, opponent, opponent_sha)
        if replay.read_bytes() != shard.read_bytes():
            raise ValueError("MCTS self-play shard failed deterministic verification")
    return {
        "manifest_files": len(
            json.loads((root / "manifest.json").read_text())["files"]
        ),
        "replay": {
            "shard": shard.relative_to(root).as_posix(),
            "sha256": metrics["sha256"],
            "byte_identical": True,
        },
        "summary": json.loads((root / "summary.json").read_text()),
    }
