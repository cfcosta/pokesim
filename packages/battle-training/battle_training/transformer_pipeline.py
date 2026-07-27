"""Full-party transformer + batched simultaneous-search training pipeline."""

from __future__ import annotations

import copy
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

from . import ENTROPY, FULL_PARTY_SIZE, FULL_PROFILE, FULL_SCHEMA
from .arena import (
    ArenaConfig,
    run_paired_arena,
    run_traced_arena,
    skill_probe_report,
    write_arena_report,
)
from .artifacts import build_manifest, sha256, verify_manifest, write_json, write_new
from .joint_search import BatchedJointRegretSearch, JointSearchConfig, SearchResult
from .native import NativeRequestTimeout, SearchServer, build_search_server
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
    opponent_checkpoints: tuple[str, ...] = ()
    opponent_fraction: float = 0.5
    historical_window: int = 4
    promotion_games: int = 1024
    promotion_seed_count: int = 8
    probe_games: int = 256
    probe_seed_count: int = 8
    minimum_promotion_score: float = 0.50
    enforce_quality_gate: bool = True
    chance_samples_per_joint: int = 1
    regret_iterations: int = 256
    inference_batch_size: int = 96
    max_actions_per_side: int = 13
    replay_window: int = 2
    search_every: int = 10


def _pipeline_id() -> str:
    return "transformer-full6v6-tactical-joint-regret-v2"


def _scheduled_for_opponent(episode: int, fraction: float) -> bool:
    """Periodic deterministic mixture with an exact count for rational fractions."""
    return math.floor((episode + 1) * fraction) > math.floor(episode * fraction)


def _new_search(
    server: SearchServer,
    player: BattleTransformer,
    enemy: BattleTransformer,
    config: TransformerPipelineConfig,
    selection_rng: random.Random,
    chance_rng: random.Random,
) -> BatchedJointRegretSearch:
    return BatchedJointRegretSearch(
        server,
        player,
        enemy,
        JointSearchConfig(
            config.chance_samples_per_joint,
            config.search_depth,
            config.regret_iterations,
            config.inference_batch_size,
            config.max_actions_per_side,
        ),
        selection_rng,
        chance_rng,
    )


def _sample_policy(probabilities: list[float], rng: random.Random) -> int:
    threshold = rng.random()
    cumulative = 0.0
    for action, probability in enumerate(probabilities):
        cumulative += probability
        if threshold <= cumulative:
            return action
    return max(
        index for index, probability in enumerate(probabilities) if probability > 0
    )


def _policy_rollout(
    player: BattleTransformer,
    enemy: BattleTransformer,
    snapshot: Any,
    rng: random.Random,
) -> SearchResult:
    if player is enemy:
        policies, values = player.evaluate(
            [snapshot.player_features, snapshot.enemy_features],
            [snapshot.player_mask, snapshot.enemy_mask],
        )
        player_policy, enemy_policy = policies
        player_value, enemy_value = values
    else:
        player_policies, player_values = player.evaluate(
            [snapshot.player_features], [snapshot.player_mask]
        )
        enemy_policies, enemy_values = enemy.evaluate(
            [snapshot.enemy_features], [snapshot.enemy_mask]
        )
        player_policy, enemy_policy = player_policies[0], enemy_policies[0]
        player_value, enemy_value = player_values[0], enemy_values[0]
    value = max(-1.0, min(1.0, (player_value - enemy_value) / 2.0))
    return SearchResult(
        tuple(player_policy),
        tuple(enemy_policy),
        _sample_policy(player_policy, rng),
        _sample_policy(enemy_policy, rng),
        value,
        0,
        "network-policy-rollout-v1",
        None,
        None,
        None,
    )


def _policy_entropy(policy: list[float]) -> float:
    return -sum(
        probability * math.log(probability) for probability in policy if probability
    )


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
    opponents: list[tuple[BattleTransformer, str]] | None = None,
) -> dict[str, Any]:
    selection_rng = random.Random(config.seed + iteration * 1_000_003)
    chance_rng = random.Random(config.seed + iteration * 1_000_033 + 17)
    meta: dict[str, Any] = {
        "type": "meta",
        "format": "full6v6-joint-regret-policy-value-jsonl-v1",
        "profile": FULL_PROFILE,
        "schema": FULL_SCHEMA,
        "entropy": ENTROPY,
        "chance": "fresh-root-v1",
        "solver": "tactical-switch-gated-joint-regret-crn-v1",
        "iteration": iteration,
        "episodes": config.selfplay_episodes,
        "depth": config.search_depth,
        "seed": config.seed,
        "party_size": FULL_PARTY_SIZE,
        "chance_samples_per_joint": config.chance_samples_per_joint,
        "regret_iterations": config.regret_iterations,
        "inference_batch_size": config.inference_batch_size,
        "max_actions_per_side": config.max_actions_per_side,
        "search_every": config.search_every,
    }
    opponents = opponents or []
    if opponents:
        meta["opponents"] = {
            "kind": "anchored-historical-round-robin",
            "sha256": [identity for _, identity in opponents],
            "fraction": config.opponent_fraction,
            "schedule": "balanced-periodic-round-robin-v1",
        }
    rows: list[dict[str, Any]] = [meta]
    finished = truncated = semantic_divergences = examples = transitions = 0
    mirror_episodes = opponent_episodes = 0
    candidate_player_episodes = candidate_enemy_episodes = 0
    opponent_counts = {identity: 0 for _, identity in opponents}
    with SearchServer() as server:
        for episode in range(config.selfplay_episodes):
            versus_opponent = bool(opponents) and _scheduled_for_opponent(
                episode, config.opponent_fraction
            )
            opponent_identity: str | None = None
            if versus_opponent:
                opponent_index = opponent_episodes % len(opponents)
                opponent_round = opponent_episodes // len(opponents)
                opponent, opponent_identity = opponents[opponent_index]
                candidate_player = opponent_round % 2 == 0
                player_network = network if candidate_player else opponent
                enemy_network = opponent if candidate_player else network
                episode_kind = "fixed-opponent"
                opponent_episodes += 1
                opponent_counts[opponent_identity] += 1
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
                searched = decision % config.search_every == 0
                if searched:
                    search = _new_search(
                        server,
                        player_network,
                        enemy_network,
                        config,
                        selection_rng,
                        chance_rng,
                    )
                    result = search.search(snapshot, sample_actions=True)
                else:
                    result = _policy_rollout(
                        player_network, enemy_network, snapshot, selection_rng
                    )
                valid_search_target = searched and result.payoff_matrix is not None
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
                    "target_kind": (
                        "joint-regret" if valid_search_target else "policy-rollout"
                    ),
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
                    "target_kind": (
                        "joint-regret" if valid_search_target else "policy-rollout"
                    ),
                }
                player_row["legal_mask"] = snapshot.player_mask
                enemy_row["legal_mask"] = snapshot.enemy_mask
                player_row["request"] = snapshot.request
                enemy_row["request"] = snapshot.request
                if result.exploitability is not None:
                    player_row["search_exploitability"] = result.exploitability
                    enemy_row["search_exploitability"] = result.exploitability
                    player_row["payoff_spread"] = result.payoff_spread
                    enemy_row["payoff_spread"] = result.payoff_spread
                if opponents:
                    player_row["episode_kind"] = episode_kind
                    enemy_row["episode_kind"] = episode_kind
                    player_row["opponent_sha256"] = opponent_identity
                    enemy_row["opponent_sha256"] = opponent_identity
                if not versus_opponent or candidate_player:
                    pending.append(player_row)
                if not versus_opponent or not candidate_player:
                    pending.append(enemy_row)
                snapshot = server.episode_step(
                    snapshot.handle, result.player_action, result.enemy_action
                )
                transitions += 1
                if snapshot.divergence is not None:
                    rows.append(
                        {
                            "type": "episode",
                            "episode": episode,
                            "stop": "semantic-divergence",
                            "reason": snapshot.divergence,
                            "return": None,
                            "decisions": decision + 1,
                        }
                    )
                    semantic_divergences += 1
                    break
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
        raise ValueError("full-party search produced no terminal training examples")
    example_rows = [row for row in rows if row["type"] == "example"]
    exploitabilities = [
        row["search_exploitability"]
        for row in example_rows
        if "search_exploitability" in row
    ]
    payoff_spreads = [
        row["payoff_spread"] for row in example_rows if "payoff_spread" in row
    ]
    return {
        "finished": finished,
        "truncated": truncated,
        "semantic_divergences": semantic_divergences,
        "examples": examples,
        "transitions": transitions,
        "mirror_episodes": mirror_episodes,
        "opponent_episodes": opponent_episodes,
        "candidate_player_episodes": candidate_player_episodes,
        "candidate_enemy_episodes": candidate_enemy_episodes,
        "opponent_counts": opponent_counts,
        "mean_target_entropy": sum(
            _policy_entropy(row["policy"]) for row in example_rows
        )
        / len(example_rows),
        "mean_search_exploitability": (
            sum(exploitabilities) / len(exploitabilities) if exploitabilities else None
        ),
        "mean_payoff_spread": (
            sum(payoff_spreads) / len(payoff_spreads) if payoff_spreads else None
        ),
        "mean_decisions": transitions / config.selfplay_episodes,
        "voluntary_switch_rate": sum(
            row["action"] in range(4, 10)
            for row in example_rows
            if row["request"] == "battle"
        )
        / max(1, sum(row["request"] == "battle" for row in example_rows)),
        "sha256": sha256(path),
        "bytes": path.stat().st_size,
    }


def _load_examples(paths: list[Path]) -> tuple[Tensor, Tensor, Tensor, Tensor, Tensor]:
    features: list[list[int]] = []
    policies: list[list[float]] = []
    values: list[float] = []
    legal_masks: list[list[bool]] = []
    policy_weights: list[float] = []
    for path in paths:
        with path.open() as source:
            for line in source:
                row = json.loads(line)
                if row["type"] != "example":
                    continue
                features.append(row["features"])
                policies.append(row["policy"])
                values.append(row["value"])
                mask = row["legal_mask"]
                legal_masks.append(
                    [bool(mask & (1 << action)) for action in range(len(row["policy"]))]
                )
                policy_weights.append(
                    0.0 if row.get("target_kind") == "policy-rollout" else 1.0
                )
    return (
        torch.tensor(features, dtype=torch.long),
        torch.tensor(policies, dtype=torch.float32),
        torch.tensor(values, dtype=torch.float32),
        torch.tensor(legal_masks, dtype=torch.bool),
        torch.tensor(policy_weights, dtype=torch.float32),
    )


def _train_network(
    network: BattleTransformer,
    optimizer: torch.optim.Optimizer,
    shards: list[Path],
    config: TransformerPipelineConfig,
    iteration: int,
) -> dict[str, Any]:
    device = next(network.parameters()).device
    features, target_policy, target_value, legal_masks, policy_weights = _load_examples(
        shards
    )
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
            batch_legal = legal_masks[indexes].to(device)
            batch_policy_weight = policy_weights[indexes].to(device)
            logits, values = network(batch_features)
            logits = logits.masked_fill(~batch_legal, torch.finfo(logits.dtype).min)
            policy_rows = -(batch_policy * torch.log_softmax(logits, dim=-1)).sum(
                dim=-1
            )
            policy_loss = (
                policy_rows * batch_policy_weight
            ).sum() / batch_policy_weight.sum().clamp_min(1.0)
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
    for _ in range(config.episode_budget):
        search = _new_search(server, player, enemy, config, selection_rng, chance_rng)
        result = search.search(snapshot, sample_actions=True)
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


def _collection_quality(
    metrics: dict[str, Any], config: TransformerPipelineConfig
) -> dict[str, Any]:
    reasons: list[str] = []
    episodes = config.selfplay_episodes
    if metrics["truncated"] / episodes > 0.01:
        reasons.append("horizon-truncation-rate-above-1pct")
    if metrics["semantic_divergences"] / episodes > 0.01:
        reasons.append("semantic-divergence-rate-above-1pct")
    if metrics["voluntary_switch_rate"] > 0.20:
        reasons.append("voluntary-switch-rate-above-20pct")
    if metrics["mean_decisions"] > 96:
        reasons.append("mean-battle-length-above-96")
    if metrics["finished"] / episodes < 0.98:
        reasons.append("finished-rate-below-98pct")
    return {"pass": not reasons, "reasons": reasons}


def run_transformer_pipeline(
    root: Path, config: TransformerPipelineConfig
) -> dict[str, Any]:
    if root.exists() and any(root.iterdir()):
        raise FileExistsError(f"output directory is not empty: {root}")
    if config.arena_episodes < 4 or config.arena_episodes % 2:
        raise ValueError("arena_episodes must be an even number of at least four")
    root.mkdir(parents=True, exist_ok=True)
    if config.search_every < 1:
        raise ValueError("search_every must be positive")
    if config.max_actions_per_side < 13:
        raise ValueError(
            "full-party training must consider the complete action dictionary"
        )
    if config.replay_window < 1:
        raise ValueError("replay_window must be positive")
    if config.historical_window < 0:
        raise ValueError("historical_window must be nonnegative")
    if config.promotion_games < 2 or config.promotion_games % 2:
        raise ValueError("promotion_games must be an even number of at least two")
    if config.probe_games < 2 or config.probe_games % 2:
        raise ValueError("probe_games must be an even number of at least two")
    if config.promotion_seed_count < 2 or config.probe_seed_count < 2:
        raise ValueError("promotion and probe arenas require multiple seeds")
    if config.promotion_games < 2 * config.promotion_seed_count:
        raise ValueError("promotion games must cover every promotion seed")
    if config.probe_games < 2 * config.probe_seed_count:
        raise ValueError("probe games must cover every probe seed")
    if not 0.0 <= config.minimum_promotion_score <= 1.0:
        raise ValueError("minimum_promotion_score must be in [0, 1]")
    if config.enforce_quality_gate:
        if config.promotion_games < 1024:
            raise ValueError(
                "quality-gated training requires at least 1024 promotion games"
            )
        if config.minimum_promotion_score < 0.50:
            raise ValueError(
                "quality-gated training requires a promotion score of at least 50%"
            )
    if not 0.0 <= config.opponent_fraction <= 1.0:
        raise ValueError("opponent_fraction must be in [0, 1]")
    build_search_server()
    with SearchServer() as protocol:
        feature_count = protocol.feature_count
        action_count = protocol.action_count
    configure_determinism(config.seed)
    device = choose_device(config.device)
    opponents: list[tuple[BattleTransformer, str]] = []
    opponent_metadata: list[dict[str, Any]] = []
    for index, source_name in enumerate(config.opponent_checkpoints):
        opponent_source = Path(source_name).resolve()
        opponent_sha = sha256(opponent_source)
        opponent_copy = root / "opponents" / f"fixed-{index:03d}.pt"
        write_new(opponent_copy, opponent_source.read_bytes())
        opponents.append((load_network(opponent_copy, device), opponent_sha))
        opponent_metadata.append(
            {
                "kind": "fixed-checkpoint",
                "checkpoint": opponent_copy.relative_to(root).as_posix(),
                "sha256": opponent_sha,
            }
        )
    model_config = TransformerConfig(
        feature_count=feature_count,
        action_count=action_count,
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
            "pipeline": _pipeline_id(),
            "profile": FULL_PROFILE,
            "schema": FULL_SCHEMA,
            "party_size": FULL_PARTY_SIZE,
            "chance": "fresh-root-v1",
            "search_solver": "tactical-switch-gated-joint-regret-crn-v1",
            "config": asdict(config),
            "network": asdict(model_config),
            "parameter_count": sum(
                parameter.numel() for parameter in network.parameters()
            ),
            "opponents": opponent_metadata,
            "torch": torch.__version__,
            "device": str(device),
            "device_name": torch.cuda.get_device_name(device)
            if device.type == "cuda"
            else "cpu",
        },
    )
    initial_checkpoint = root / "checkpoints" / "policy-000.pt"
    save_network(initial_checkpoint, network, None, {"iteration": 0, "kind": "initial"})
    initial_identity = sha256(initial_checkpoint)
    initial_anchor = initial.detached_copy(device)
    historical: list[tuple[BattleTransformer, str]] = []
    shards: list[Path] = []
    collection: list[dict[str, Any]] = []
    training: list[dict[str, Any]] = []
    optimizer = torch.optim.AdamW(
        network.parameters(), lr=config.learning_rate, weight_decay=config.weight_decay
    )
    for iteration in range(1, config.iterations + 1):
        population = opponents + [(initial_anchor, initial_identity)]
        if config.historical_window:
            population.extend(historical[:-1][-config.historical_window :])
        population = list(
            {identity: (model, identity) for model, identity in population}.values()
        )
        shard = root / "shards" / f"iteration-{iteration:03d}.jsonl"
        try:
            collection_metrics = _collect_rows(
                shard, network, config, iteration, population
            )
        except NativeRequestTimeout as error:
            write_json(
                root / "metrics" / f"iteration-{iteration:03d}.json",
                {
                    "collection": {
                        "status": "failed",
                        "mechanics_timeouts": 1,
                        "operation": error.operation,
                        "timeout_seconds": error.seconds,
                    },
                    "data_quality_pass": False,
                },
            )
            raise
        collection_quality = _collection_quality(collection_metrics, config)
        collection_metrics["quality"] = collection_quality
        shards.append(shard)
        collection.append(collection_metrics)
        training_shards = shards[-config.replay_window :]
        incumbent = network.detached_copy(device)
        incumbent_state = copy.deepcopy(network.state_dict())
        optimizer_state = copy.deepcopy(optimizer.state_dict())
        training_metrics = _train_network(
            network, optimizer, training_shards, config, iteration
        )
        promotion = run_paired_arena(
            network,
            incumbent,
            config.promotion_games,
            config.episode_budget,
            config.seed + 70_000_000 + iteration * 10_007,
            config.promotion_seed_count,
        )
        probe_arena = run_traced_arena(
            network,
            incumbent,
            ArenaConfig(
                games=config.probe_games,
                budget=config.episode_budget,
                seed=config.seed + 80_000_000 + iteration * 10_009,
                replay_games=0,
                seed_count=config.probe_seed_count,
            ),
        )
        probes = skill_probe_report(probe_arena)
        promotion_score = promotion["score_with_nonfinishes_as_losses"]
        confidence_low = promotion["paired_score_ci95"][0]
        statistically_superior = (
            promotion_score >= config.minimum_promotion_score and confidence_low >= 0.50
        )
        if config.enforce_quality_gate:
            accepted = (
                collection_quality["pass"]
                and promotion["data_quality_pass"]
                and promotion["quality_pass"]
                and probe_arena["data_quality_pass"]
                and probe_arena["quality_pass"]
                and statistically_superior
                and probes["pass"]
            )
        else:
            accepted = (
                promotion["data_quality_pass"]
                and promotion["quality_pass"]
                and probe_arena["data_quality_pass"]
                and probe_arena["quality_pass"]
                and promotion_score >= config.minimum_promotion_score
            )
        promotion["statistically_superior"] = statistically_superior
        promotion["minimum_score"] = config.minimum_promotion_score
        promotion["held_out_probes"] = probes
        promotion["probe_arena"] = probe_arena
        promotion["accepted"] = accepted
        if not accepted:
            network.load_state_dict(incumbent_state)
            optimizer.load_state_dict(optimizer_state)
            network.eval()
        training_metrics["promotion"] = promotion
        training.append(training_metrics)
        checkpoint = root / "checkpoints" / f"policy-{iteration:03d}.pt"
        save_network(
            checkpoint,
            network,
            optimizer,
            {
                "iteration": iteration,
                "source_shards": [
                    path.relative_to(root).as_posix() for path in training_shards
                ],
                "collection": collection_metrics,
                "training": training_metrics,
            },
        )
        if accepted:
            historical.append((network.detached_copy(device), sha256(checkpoint)))
        if len(historical) > config.historical_window + 1:
            historical.pop(0)
        write_json(
            root / "metrics" / f"iteration-{iteration:03d}.json",
            {
                "collection": collection_metrics,
                "training": training_metrics,
                "promotion": promotion,
            },
        )
    distance = _parameter_distance(initial, network)
    arena_config = ArenaConfig(
        games=config.arena_episodes,
        budget=config.episode_budget,
        chance_samples_per_joint=config.chance_samples_per_joint,
        search_depth=config.search_depth,
        regret_iterations=config.regret_iterations,
        inference_batch_size=config.inference_batch_size,
        max_actions_per_side=13,
        seed=config.seed,
        replay_games=min(3, config.arena_episodes),
        seed_count=min(8, config.arena_episodes // 2),
    )
    arena = write_arena_report(
        root / "arena" / "final-vs-initial", network, initial, arena_config
    )
    opponent_arenas = []
    for index, (opponent, identity) in enumerate(opponents):
        result = write_arena_report(
            root / "arena" / f"final-vs-fixed-{index:03d}",
            network,
            opponent,
            arena_config,
        )
        result["opponent_sha256"] = identity
        opponent_arenas.append(result)

    with tempfile.TemporaryDirectory(prefix="battle-transformer-replay-") as temporary:
        replay_path = Path(temporary) / "replay.jsonl"
        replay_network = load_network(initial_checkpoint, device)
        replay_opponents = opponents + [(initial_anchor, initial_identity)]
        replay_opponents = list(
            {
                identity: (model, identity) for model, identity in replay_opponents
            }.values()
        )
        replay_metrics = _collect_rows(
            replay_path, replay_network, config, 1, replay_opponents
        )
        replay_identical = replay_path.read_bytes() == shards[0].read_bytes()
        if not replay_identical:
            raise ValueError("full-party search shard failed deterministic replay")
    replay = {
        "shard": shards[0].relative_to(root).as_posix(),
        "sha256": replay_metrics["sha256"],
        "byte_identical": True,
    }
    accepted_updates = sum(item["promotion"]["accepted"] for item in training)
    collection_quality_pass = all(item["quality"]["pass"] for item in collection)
    evaluation_data_quality_pass = (
        arena["data_quality_pass"]
        and all(item["data_quality_pass"] for item in opponent_arenas)
        and all(item["promotion"]["data_quality_pass"] for item in training)
        and all(
            item["promotion"]["probe_arena"]["data_quality_pass"] for item in training
        )
    )
    evaluation_quality_pass = (
        arena["quality_pass"]
        and all(item["quality_pass"] for item in opponent_arenas)
        and all(item["promotion"]["quality_pass"] for item in training)
        and all(item["promotion"]["probe_arena"]["quality_pass"] for item in training)
    )
    data_quality_pass = evaluation_data_quality_pass
    model_quality_pass = accepted_updates > 0 and all(
        item["promotion"]["statistically_superior"]
        and item["promotion"]["held_out_probes"]["pass"]
        for item in training
        if item["promotion"]["accepted"]
    )
    quality_gate_pass = (
        data_quality_pass
        and collection_quality_pass
        and evaluation_quality_pass
        and (model_quality_pass or not config.enforce_quality_gate)
    )
    summary = {
        "pipeline": _pipeline_id(),
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
        "accepted_updates": accepted_updates,
        "final_training_loss": training[-1]["history"][-1],
        "arena": arena,
        "opponent_arenas": opponent_arenas,
        "opponents": opponent_metadata,
        "data_quality_pass": data_quality_pass,
        "model_quality_pass": model_quality_pass,
        "quality_gate": {
            "pass": quality_gate_pass,
            "collection_quality_pass": collection_quality_pass,
            "evaluation_data_quality_pass": evaluation_data_quality_pass,
            "evaluation_nonfinish_quality_pass": evaluation_quality_pass,
            "at_least_one_promoted_update": accepted_updates > 0,
            "accepted_updates_passed_paired_confidence": (
                accepted_updates > 0
                and all(
                    item["promotion"]["statistically_superior"]
                    for item in training
                    if item["promotion"]["accepted"]
                )
            ),
            "accepted_updates_passed_skill_probes": (
                accepted_updates > 0
                and all(
                    item["promotion"]["held_out_probes"]["pass"]
                    for item in training
                    if item["promotion"]["accepted"]
                )
            ),
            "semantic_cycles_scored_as_losses": True,
            "deterministic_replay": True,
        },
        "deterministic_replay": replay,
    }
    write_json(root / "summary.json", summary)
    write_json(root / "manifest.json", build_manifest(root))
    errors = verify_manifest(root)
    if errors:
        raise ValueError("artifact verification failed: " + "; ".join(errors))
    return summary


def verify_transformer_run(root: Path) -> dict[str, Any]:
    """Verify hashes and regenerate the first full-party search shard."""
    build_search_server()
    errors = verify_manifest(root)
    if errors:
        raise ValueError("artifact verification failed: " + "; ".join(errors))
    summary = json.loads((root / "summary.json").read_text())
    run = json.loads((root / "run.json").read_text())
    config = TransformerPipelineConfig(**run["config"])
    if not summary.get("data_quality_pass", False):
        raise ValueError("training run failed the expanded data-quality gate")
    if config.enforce_quality_gate and not summary.get("quality_gate", {}).get(
        "pass", False
    ):
        raise ValueError("training run did not promote a statistically supported model")
    configure_determinism(config.seed)
    device = choose_device(config.device)
    initial_path = root / "checkpoints" / "policy-000.pt"
    network = load_network(initial_path, device)
    opponents: list[tuple[BattleTransformer, str]] = [
        (load_network(initial_path, device), sha256(initial_path))
    ]
    for opponent_metadata in run.get("opponents", []):
        opponent_path = root / opponent_metadata["checkpoint"]
        opponent_sha = sha256(opponent_path)
        if opponent_sha != opponent_metadata["sha256"]:
            raise ValueError("fixed opponent checkpoint hash mismatch")
        opponents.append((load_network(opponent_path, device), opponent_sha))
    opponents = list(
        {identity: (model, identity) for model, identity in opponents}.values()
    )
    shard = root / "shards" / "iteration-001.jsonl"
    with tempfile.TemporaryDirectory(prefix="battle-transformer-verify-") as temporary:
        replay = Path(temporary) / "replay.jsonl"
        metrics = _collect_rows(replay, network, config, 1, opponents)
        if replay.read_bytes() != shard.read_bytes():
            raise ValueError(
                "full-party search shard failed deterministic verification"
            )
    return {
        "manifest_files": len(
            json.loads((root / "manifest.json").read_text())["files"]
        ),
        "replay": {
            "shard": shard.relative_to(root).as_posix(),
            "sha256": metrics["sha256"],
            "byte_identical": True,
        },
        "summary": summary,
    }
