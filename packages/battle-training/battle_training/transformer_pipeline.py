"""Full-party transformer + batched simultaneous-search training pipeline."""

from __future__ import annotations

import json
import math
import multiprocessing
import random
import shutil
import tempfile
from collections.abc import Iterable
from concurrent.futures import ProcessPoolExecutor
from dataclasses import asdict, dataclass, field, replace
from pathlib import Path
from typing import Any

import torch
from torch import Tensor

from . import (
    ENTROPY,
    FULL_PARTY_SIZE,
    FULL_PROFILE,
    FULL_SCHEMA,
    GENERATED_LEVEL_SCHEDULE,
    GENERATED_PARTY_SCHEDULE,
    generated_level100,
    generated_party_sizes,
)
from .arena import (
    ArenaConfig,
    _choice_detail,
    _compact_inspection,
    _compact_turn_inspection,
    run_campaign_arena,
    run_paired_arena,
    run_traced_arena,
    skill_probe_report,
    write_arena_report,
)
from .artifacts import build_manifest, sha256, verify_manifest, write_json, write_new
from .joint_search import JointSearchConfig, SearchResult, SimultaneousTreeSearch
from .monitor import write_actor_progress, write_monitor_state
from .native import NativeRequestTimeout, SearchServer, Snapshot, build_search_server
from .network import (
    BattleTransformer,
    TransformerConfig,
    choose_device,
    configure_determinism,
    load_checkpoint,
    load_network,
    save_network,
    warm_start_network,
)
from .red_ai_heuristics import (
    TRAINER_CLASS_PROFILES,
    normalized_trainer_policy,
    trainer_profile_for_style,
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
    token_group_size: int = 1
    opponent_checkpoints: tuple[str, ...] = ()
    opponent_fraction: float = 0.5
    historical_window: int = 4
    promotion_games: int = 1024
    promotion_seed_count: int = 8
    probe_games: int = 256
    probe_seed_count: int = 8
    campaign_games: int = 288
    campaign_seed_count: int = 8
    minimum_promotion_score: float = 0.50
    enforce_quality_gate: bool = True
    chance_samples_per_joint: int = 1
    regret_iterations: int = 256
    inference_batch_size: int = 256
    max_actions_per_side: int = 13
    replay_window: int = 2
    search_every: int = 1
    tree_expansion_budget: int = 320
    tree_exploration: float = 0.10
    tree_chance_resample: float = 0.10
    tree_regret_iterations: int = 16
    tree_deeper_joint_rotations: int = 2
    tree_minimum_budget: int = 192
    tree_convergence_tolerance: float = 0.005
    tree_convergence_patience: int = 8
    deep_search_fraction: float = 1.0
    actor_batch_size: int = 16
    actor_processes: int = 1
    precision: str = "bf16"
    inference_engine: str = "auto"
    warm_start_checkpoint: str | None = None
    heuristic_opponents: bool = True


class _HeuristicNetwork:
    """Deterministic non-self-play policy with a neutral leaf value."""

    def __init__(self, style: str) -> None:
        self.style = style
        self.config = type("HeuristicConfig", (), {"action_count": 13})()

    def evaluate(
        self, features: list[tuple[int, ...]], masks: list[int]
    ) -> tuple[list[list[float]], list[float]]:
        policies = []
        trainer_profile = trainer_profile_for_style(self.style)
        for row, mask in zip(features, masks, strict=True):
            if trainer_profile is not None:
                policies.append(normalized_trainer_policy(row, mask, trainer_profile))
                continue
            weights = [0.0] * 13
            for action in range(13):
                if not mask & (1 << action):
                    continue
                if action < 4:
                    tactical = int(row[362 + action * 6 + 5])
                    weights[action] = 1.0 + tactical
                    if self.style == "switch-heavy":
                        weights[action] *= 0.10
                elif 4 <= action < 10:
                    slot = action - 4
                    outgoing = int(row[410 + slot * 2])
                    incoming = int(row[411 + slot * 2])
                    advantage = max(0, outgoing - incoming)
                    weights[action] = 1.0 + advantage
                    if self.style == "aggressive":
                        weights[action] *= 0.02
                    elif self.style == "switch-heavy":
                        weights[action] *= 8.0
                else:
                    weights[action] = 0.01
            total = sum(weights)
            policies.append([weight / total for weight in weights])
        return policies, [0.0] * len(features)


def _heuristic_population() -> list[tuple[_HeuristicNetwork, str]]:
    general = [
        (_HeuristicNetwork("aggressive"), "heuristic-aggressive-v1"),
        (_HeuristicNetwork("switch-heavy"), "heuristic-switch-heavy-v1"),
    ]
    trainers = [
        (_HeuristicNetwork(profile.style), profile.identity)
        for profile in TRAINER_CLASS_PROFILES
    ]
    return general + trainers


@dataclass
class _ActorEpisode:
    episode: int
    pair: int
    pair_leg: int
    reset_episode: int
    pair_player_size: int
    pair_enemy_size: int
    teams_swapped: bool
    player_network: Any
    enemy_network: Any
    episode_kind: str
    opponent_identity: str | None
    candidate_player: bool
    player_size: int
    enemy_size: int
    level100: bool
    snapshot: Snapshot
    pending: list[dict[str, Any]]
    selection_rng: random.Random
    chance_rng: random.Random
    opponent_rng: random.Random
    tier_rng: random.Random
    initial: dict[str, Any] | None = None
    final: dict[str, Any] | None = None
    inspection: dict[str, Any] | None = None
    timeline: list[dict[str, Any]] = field(default_factory=list)


def _pipeline_id() -> str:
    return "transformer-variable-party-bf16-tree-v15"


def _configure_inference(models: Iterable[Any], engine: str) -> None:
    for model in models:
        if isinstance(model, BattleTransformer):
            model.configure_inference(engine)


def _scheduled_for_opponent(episode: int, fraction: float) -> bool:
    """Periodic deterministic mixture with an exact count for rational fractions."""
    return math.floor((episode + 1) * fraction) > math.floor(episode * fraction)


def _training_pair(episode: int) -> int:
    return episode // 2


def _training_pair_leg(episode: int) -> int:
    return episode % 2


def _training_party_index(iteration: int, episode: int) -> int:
    return _training_pair(episode) + (iteration - 1) * 13


def _training_party_sizes(iteration: int, episode: int) -> tuple[int, int]:
    """Give both legs the same teams while retaining the full size schedule."""
    return generated_party_sizes(_training_party_index(iteration, episode))


def _training_level100(iteration: int, episode: int) -> bool:
    return generated_level100(_training_party_index(iteration, episode))


def _validate_collection_pairs(
    episode_rows: list[dict[str, Any]], expected_games: int
) -> None:
    if expected_games % 2:
        raise RuntimeError("paired collection requires an even game count")
    by_episode = {int(row["episode"]): row for row in episode_rows}
    if len(by_episode) != expected_games or set(by_episode) != set(
        range(expected_games)
    ):
        raise RuntimeError(
            "collection does not contain exactly one row per paired game"
        )
    for pair in range(expected_games // 2):
        first = by_episode[pair * 2]
        second = by_episode[pair * 2 + 1]
        if first.get("pair") != pair or second.get("pair") != pair:
            raise RuntimeError(f"collection pair {pair} has incorrect identity")
        if first.get("pair_leg") != 0 or second.get("pair_leg") != 1:
            raise RuntimeError(f"collection pair {pair} has incorrect leg order")
        shared = (
            "reset_episode",
            "pair_player_party_size",
            "pair_enemy_party_size",
            "level_profile",
            "episode_kind",
            "opponent",
        )
        if any(first.get(name) != second.get(name) for name in shared):
            raise RuntimeError(f"collection pair {pair} does not share one reset")
        first_initial = first.get("initial") or {}
        second_initial = second.get("initial") or {}
        if first["episode_kind"] == "mirror":
            expected_sizes = (
                first.get("pair_player_party_size"),
                first.get("pair_enemy_party_size"),
            )
            if (
                first.get("teams_swapped") is not False
                or second.get("teams_swapped") is not True
            ):
                raise RuntimeError(f"mirror pair {pair} did not swap teams")
            if (
                (first.get("player_party_size"), first.get("enemy_party_size"))
                != expected_sizes
                or (second.get("enemy_party_size"), second.get("player_party_size"))
                != expected_sizes
                or first_initial.get("player") != second_initial.get("enemy")
                or first_initial.get("enemy") != second_initial.get("player")
            ):
                raise RuntimeError(f"mirror pair {pair} is not an exact team swap")
        else:
            if first.get("initial") != second.get("initial"):
                raise RuntimeError(
                    f"collection pair {pair} has different initial teams"
                )
            if first.get("teams_swapped") or second.get("teams_swapped"):
                raise RuntimeError(f"opponent pair {pair} unexpectedly swapped teams")
            if {
                first.get("candidate_side"),
                second.get("candidate_side"),
            } != {"player", "enemy"}:
                raise RuntimeError(
                    f"collection pair {pair} did not swap candidate sides"
                )


def _new_search(
    server: SearchServer,
    player: BattleTransformer,
    enemy: BattleTransformer,
    config: TransformerPipelineConfig,
    selection_rng: random.Random,
    chance_rng: random.Random,
    *,
    deep: bool = True,
) -> SimultaneousTreeSearch:
    return SimultaneousTreeSearch(
        server,
        player,
        enemy,
        JointSearchConfig(
            config.chance_samples_per_joint,
            config.search_depth,
            config.regret_iterations,
            config.inference_batch_size,
            config.max_actions_per_side,
            config.tree_expansion_budget if deep else 1,
            config.tree_exploration,
            config.tree_chance_resample,
            config.tree_regret_iterations,
            config.tree_deeper_joint_rotations,
            config.tree_minimum_budget if deep else 1,
            config.tree_convergence_tolerance,
            config.tree_convergence_patience,
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


def _policy_rollout_many(
    player: BattleTransformer,
    enemy: BattleTransformer,
    snapshots: list[Snapshot],
    rngs: list[random.Random],
) -> list[SearchResult]:
    if not snapshots:
        return []
    if len(rngs) != len(snapshots):
        raise ValueError("policy rollout requires one RNG per snapshot")
    if player is enemy:
        policies, values = player.evaluate(
            [snapshot.player_features for snapshot in snapshots]
            + [snapshot.enemy_features for snapshot in snapshots],
            [snapshot.player_mask for snapshot in snapshots]
            + [snapshot.enemy_mask for snapshot in snapshots],
        )
        count = len(snapshots)
        player_policies, enemy_policies = policies[:count], policies[count:]
        player_values, enemy_values = values[:count], values[count:]
    else:
        player_policies, player_values = player.evaluate(
            [snapshot.player_features for snapshot in snapshots],
            [snapshot.player_mask for snapshot in snapshots],
        )
        enemy_policies, enemy_values = enemy.evaluate(
            [snapshot.enemy_features for snapshot in snapshots],
            [snapshot.enemy_mask for snapshot in snapshots],
        )
    results: list[SearchResult] = []
    for player_policy, enemy_policy, player_value, enemy_value, rng in zip(
        player_policies,
        enemy_policies,
        player_values,
        enemy_values,
        rngs,
        strict=True,
    ):
        value = max(-1.0, min(1.0, (player_value - enemy_value) / 2.0))
        results.append(
            SearchResult(
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
        )
    return results


def _policy_rollout_actor_many(actors: list[_ActorEpisode]) -> list[SearchResult]:
    grouped: dict[int, list[tuple[int, int, Any, int, Any]]] = {}
    for index, actor in enumerate(actors):
        grouped.setdefault(id(actor.player_network), []).append(
            (
                index,
                0,
                actor.snapshot.player_features,
                actor.snapshot.player_mask,
                actor.player_network,
            )
        )
        grouped.setdefault(id(actor.enemy_network), []).append(
            (
                index,
                1,
                actor.snapshot.enemy_features,
                actor.snapshot.enemy_mask,
                actor.enemy_network,
            )
        )
    outputs: dict[tuple[int, int], tuple[list[float], float]] = {}
    for items in grouped.values():
        policies, values = items[0][4].evaluate(
            [item[2] for item in items], [item[3] for item in items]
        )
        for item, policy, value in zip(items, policies, values, strict=True):
            outputs[(item[0], item[1])] = (policy, value)
    results = []
    for index, actor in enumerate(actors):
        player_policy, player_value = outputs[(index, 0)]
        enemy_policy, enemy_value = outputs[(index, 1)]
        value = max(-1.0, min(1.0, (player_value - enemy_value) / 2.0))
        results.append(
            SearchResult(
                tuple(player_policy),
                tuple(enemy_policy),
                _sample_policy(player_policy, actor.selection_rng),
                _sample_policy(enemy_policy, actor.selection_rng),
                value,
                0,
                "network-policy-rollout-v1",
                None,
                None,
                None,
            )
        )
    return results


def _policy_rollout(
    player: BattleTransformer,
    enemy: BattleTransformer,
    snapshot: Snapshot,
    rng: random.Random,
) -> SearchResult:
    return _policy_rollout_many(player, enemy, [snapshot], [rng])[0]


def _policy_entropy(policy: list[float]) -> float:
    return -sum(
        probability * math.log(probability) for probability in policy if probability
    )


def _top_policy(
    policy: list[float],
    legal_mask: int,
    inspection: dict[str, Any],
    side_name: str,
) -> list[dict[str, Any]]:
    ranked = sorted(
        (
            (action, float(probability))
            for action, probability in enumerate(policy)
            if legal_mask & (1 << action)
        ),
        key=lambda item: (-item[1], item[0]),
    )
    return [
        {
            **_choice_detail(inspection, side_name, action),
            "probability": probability,
        }
        for action, probability in ranked[:3]
    ]


def _jsonl(path: Path, rows: Iterable[dict[str, Any]]) -> None:
    payload = b"".join(
        (json.dumps(row, sort_keys=True, separators=(",", ":")) + "\n").encode()
        for row in rows
    )
    write_new(path, payload)


def _collect_rows_single(
    path: Path,
    network: BattleTransformer,
    config: TransformerPipelineConfig,
    iteration: int,
    opponents: list[tuple[Any, str]] | None = None,
    episode_indices: list[int] | None = None,
    progress_path: Path | None = None,
    process: int = 0,
) -> dict[str, Any]:
    if episode_indices is None:
        episode_indices = list(range(config.selfplay_episodes))
    if not episode_indices:
        raise ValueError("collection worker requires at least one episode")
    if progress_path is not None:
        write_actor_progress(
            progress_path, process, 0, len(episode_indices), iteration=iteration
        )
    completed_episodes = 0
    meta: dict[str, Any] = {
        "type": "meta",
        "format": "variable-party-joint-regret-policy-value-jsonl-v2",
        "profile": FULL_PROFILE,
        "schema": FULL_SCHEMA,
        "entropy": ENTROPY,
        "chance": "fresh-root-v1",
        "solver": "simultaneous-matrix-tree-rmplus-v1",
        "iteration": iteration,
        "episodes": len(episode_indices),
        "depth": config.search_depth,
        "seed": config.seed,
        "max_party_size": FULL_PARTY_SIZE,
        "party_size_schedule": GENERATED_PARTY_SCHEDULE,
        "level_schedule": GENERATED_LEVEL_SCHEDULE,
        "chance_samples_per_joint": config.chance_samples_per_joint,
        "regret_iterations": config.regret_iterations,
        "inference_batch_size": config.inference_batch_size,
        "max_actions_per_side": config.max_actions_per_side,
        "search_every": config.search_every,
        "tree_expansion_budget": config.tree_expansion_budget,
        "tree_exploration": config.tree_exploration,
        "tree_chance_resample": config.tree_chance_resample,
        "tree_regret_iterations": config.tree_regret_iterations,
        "tree_deeper_joint_rotations": config.tree_deeper_joint_rotations,
        "tree_minimum_budget": config.tree_minimum_budget,
        "tree_convergence_tolerance": config.tree_convergence_tolerance,
        "tree_convergence_patience": config.tree_convergence_patience,
        "deep_search_fraction": config.deep_search_fraction,
        "deep_search_schedule": "independent-episode-tier-v1",
        "actor_batch_size": config.actor_batch_size,
        "actor_processes": config.actor_processes,
        "pairing": "same-reset-opposite-controller-sides-v1",
        "pairs": config.selfplay_episodes // 2,
    }
    opponents = opponents or []
    if opponents:
        meta["opponents"] = {
            "kind": "checkpoint-and-heuristic-round-robin",
            "identities": [identity for _, identity in opponents],
            "fraction": config.opponent_fraction,
            "schedule": "balanced-periodic-round-robin-v1",
        }
    rows: list[dict[str, Any]] = [meta]
    finished = truncated = semantic_divergences = examples = transitions = 0
    deep_search_decisions = root_only_decisions = 0
    mirror_episodes = opponent_episodes = 0
    candidate_player_episodes = candidate_enemy_episodes = 0
    opponent_counts = {identity: 0 for _, identity in opponents}
    party_size_counts = {
        f"{player}v{enemy}": 0
        for player in range(1, FULL_PARTY_SIZE + 1)
        for enemy in range(1, FULL_PARTY_SIZE + 1)
    }
    player_wins = enemy_wins = draws = 0
    candidate_wins = candidate_losses = candidate_draws = 0
    scheduled_level100_six_vs_six = 0
    total_decisions = ordinary_actions = voluntary_switches = 0
    recent_battles: list[dict[str, Any]] = []

    def append_episode(
        actor: _ActorEpisode,
        stop: str,
        decisions: int,
        reward: int | None = None,
        reason: str | None = None,
    ) -> None:
        nonlocal player_wins, enemy_wins, draws
        nonlocal candidate_wins, candidate_losses, candidate_draws, total_decisions
        candidate_return = (
            (reward if actor.candidate_player else -reward)
            if reward is not None and actor.episode_kind != "mirror"
            else None
        )
        record: dict[str, Any] = {
            "type": "episode",
            "episode": actor.episode,
            "pair": actor.pair,
            "pair_leg": actor.pair_leg,
            "reset_episode": actor.reset_episode,
            "pair_player_party_size": actor.pair_player_size,
            "pair_enemy_party_size": actor.pair_enemy_size,
            "teams_swapped": actor.teams_swapped,
            "stop": stop,
            "return": reward,
            "candidate_return": candidate_return,
            "decisions": decisions,
            "player_party_size": actor.player_size,
            "enemy_party_size": actor.enemy_size,
            "level_profile": "level100" if actor.level100 else "distributed",
            "episode_kind": actor.episode_kind,
            "opponent": actor.opponent_identity or "self-play",
            "candidate_side": (
                "both"
                if actor.episode_kind == "mirror"
                else "player"
                if actor.candidate_player
                else "enemy"
            ),
            "initial": actor.initial,
            "final": actor.final,
            "timeline": actor.timeline,
        }
        if reason is not None:
            record["reason"] = reason
        rows.append(record)
        total_decisions += decisions
        if reward == 1:
            player_wins += 1
        elif reward == -1:
            enemy_wins += 1
        elif reward == 0:
            draws += 1
        if candidate_return == 1:
            candidate_wins += 1
        elif candidate_return == -1:
            candidate_losses += 1
        elif candidate_return == 0:
            candidate_draws += 1
        recent_battles.append(
            {name: value for name, value in record.items() if name != "type"}
        )
        del recent_battles[:-64]

    with SearchServer() as server:
        for batch_start in range(0, len(episode_indices), config.actor_batch_size):
            batch = episode_indices[batch_start : batch_start + config.actor_batch_size]
            active: list[_ActorEpisode] = []
            for offset, episode in enumerate(batch):
                pair = _training_pair(episode)
                pair_leg = _training_pair_leg(episode)
                reset_episode = pair
                versus_opponent = bool(opponents) and _scheduled_for_opponent(
                    pair, config.opponent_fraction
                )
                opponent_identity: str | None = None
                if versus_opponent:
                    opponent_ordinal = math.floor(pair * config.opponent_fraction)
                    opponent_index = opponent_ordinal % len(opponents)
                    opponent_round = opponent_ordinal // len(opponents)
                    opponent, opponent_identity = opponents[opponent_index]
                    first_candidate_player = opponent_round % 2 == 0
                    candidate_player = (
                        first_candidate_player
                        if pair_leg == 0
                        else not first_candidate_player
                    )
                    player_network = network if candidate_player else opponent
                    enemy_network = opponent if candidate_player else network
                    episode_kind = (
                        "heuristic-opponent"
                        if isinstance(opponent, _HeuristicNetwork)
                        else "checkpoint-opponent"
                    )
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
                reset_seed = config.seed + iteration * 10_000
                pair_player_size, pair_enemy_size = _training_party_sizes(
                    iteration, episode
                )
                level100 = _training_level100(iteration, episode)
                teams_swapped = episode_kind == "mirror" and pair_leg == 1
                player_size, enemy_size = (
                    (pair_enemy_size, pair_player_size)
                    if teams_swapped
                    else (pair_player_size, pair_enemy_size)
                )
                party_size_counts[f"{player_size}v{enemy_size}"] += 1
                scheduled_level100_six_vs_six += int(level100)
                snapshot = (
                    server.reset(
                        reset_seed,
                        reset_episode,
                        pair_player_size,
                        pair_enemy_size,
                        level100=level100,
                        swapped=teams_swapped,
                    )
                    if offset == 0
                    else server.reset_append(
                        reset_seed,
                        reset_episode,
                        pair_player_size,
                        pair_enemy_size,
                        level100=level100,
                        swapped=teams_swapped,
                    )
                )
                active.append(
                    _ActorEpisode(
                        episode=episode,
                        pair=pair,
                        pair_leg=pair_leg,
                        reset_episode=reset_episode,
                        pair_player_size=pair_player_size,
                        pair_enemy_size=pair_enemy_size,
                        teams_swapped=teams_swapped,
                        player_network=player_network,
                        enemy_network=enemy_network,
                        episode_kind=episode_kind,
                        opponent_identity=opponent_identity,
                        candidate_player=candidate_player,
                        player_size=player_size,
                        enemy_size=enemy_size,
                        level100=level100,
                        snapshot=snapshot,
                        pending=[],
                        selection_rng=random.Random(
                            config.seed + iteration * 1_000_003 + episode * 10_007
                        ),
                        chance_rng=random.Random(
                            config.seed + iteration * 1_000_033 + episode * 10_009 + 17
                        ),
                        opponent_rng=random.Random(
                            config.seed + iteration * 1_000_037 + episode * 10_043 + 29
                        ),
                        tier_rng=random.Random(
                            config.seed + iteration * 1_000_081 + episode * 10_049 + 43
                        ),
                    )
                )
            inspections = server.inspect_many(
                [actor.snapshot.handle for actor in active]
            )
            for actor, inspection in zip(active, inspections, strict=True):
                actor.inspection = inspection
                actor.initial = _compact_inspection(inspection)
            for decision in range(config.episode_budget):
                searched = decision % config.search_every == 0
                results: dict[int, SearchResult] = {}
                deep_by_episode = {
                    actor.episode: searched
                    and actor.tier_rng.random() < config.deep_search_fraction
                    for actor in active
                }
                if searched:
                    actor_results = SimultaneousTreeSearch.search_many(
                        [
                            _new_search(
                                server,
                                actor.player_network,
                                actor.enemy_network,
                                config,
                                actor.selection_rng,
                                actor.chance_rng,
                                deep=deep_by_episode[actor.episode],
                            )
                            for actor in active
                        ],
                        [actor.snapshot for actor in active],
                        sample_actions=True,
                    )
                else:
                    actor_results = _policy_rollout_actor_many(active)
                for actor, result in zip(active, actor_results, strict=True):
                    if actor.episode_kind == "heuristic-opponent":
                        heuristic = (
                            actor.enemy_network
                            if actor.candidate_player
                            else actor.player_network
                        )
                        features = (
                            actor.snapshot.enemy_features
                            if actor.candidate_player
                            else actor.snapshot.player_features
                        )
                        mask = (
                            actor.snapshot.enemy_mask
                            if actor.candidate_player
                            else actor.snapshot.player_mask
                        )
                        policy, _ = heuristic.evaluate([features], [mask])
                        action = _sample_policy(policy[0], actor.opponent_rng)
                        result = (
                            replace(result, enemy_action=action)
                            if actor.candidate_player
                            else replace(result, player_action=action)
                        )
                    results[actor.episode] = result
                for actor in active:
                    result = results[actor.episode]
                    snapshot = actor.snapshot
                    valid_search_target = searched and result.payoff_matrix is not None
                    if valid_search_target:
                        if deep_by_episode[actor.episode]:
                            target_kind = "joint-regret"
                            deep_search_decisions += 1
                        else:
                            target_kind = "joint-regret-root"
                            root_only_decisions += 1
                    else:
                        target_kind = "policy-rollout"
                    search_diagnostics = result.diagnostics or {}
                    actor.timeline.append(
                        {
                            "turn": decision + 1,
                            "request": snapshot.request,
                            "before": _compact_turn_inspection(actor.inspection),
                            "target_kind": target_kind,
                            "root_value": result.root_value,
                            "exploitability": result.exploitability,
                            "payoff_spread": result.payoff_spread,
                            "player_action": result.player_action,
                            "enemy_action": result.enemy_action,
                            "player_choice": _choice_detail(
                                actor.inspection, "player", result.player_action
                            ),
                            "enemy_choice": _choice_detail(
                                actor.inspection, "enemy", result.enemy_action
                            ),
                            "player_legal_mask": snapshot.player_mask,
                            "enemy_legal_mask": snapshot.enemy_mask,
                            "player_state_hash": snapshot.player_hash,
                            "enemy_state_hash": snapshot.enemy_hash,
                            "player_top_policy": _top_policy(
                                list(result.player_policy),
                                snapshot.player_mask,
                                actor.inspection,
                                "player",
                            ),
                            "enemy_top_policy": _top_policy(
                                list(result.enemy_policy),
                                snapshot.enemy_mask,
                                actor.inspection,
                                "enemy",
                            ),
                            "tree_nodes": search_diagnostics.get("tree_nodes"),
                            "tree_simulations": search_diagnostics.get(
                                "tree_simulations"
                            ),
                            "tree_max_depth": search_diagnostics.get("tree_max_depth"),
                            "chance_outcomes": search_diagnostics.get(
                                "chance_outcomes"
                            ),
                            "tree_converged": search_diagnostics.get("tree_converged"),
                        }
                    )
                    player_row = {
                        "type": "example",
                        "episode": actor.episode,
                        "pair": actor.pair,
                        "pair_leg": actor.pair_leg,
                        "decision": decision,
                        "side": "player",
                        "state_hash": snapshot.player_hash,
                        "features": snapshot.player_features.tolist(),
                        "policy": list(result.player_policy),
                        "search_value": result.root_value,
                        "action": result.player_action,
                        "target_kind": target_kind,
                        "legal_mask": snapshot.player_mask,
                        "request": snapshot.request,
                        "player_party_size": actor.player_size,
                        "enemy_party_size": actor.enemy_size,
                    }
                    enemy_row = {
                        "type": "example",
                        "episode": actor.episode,
                        "pair": actor.pair,
                        "pair_leg": actor.pair_leg,
                        "decision": decision,
                        "side": "enemy",
                        "state_hash": snapshot.enemy_hash,
                        "features": snapshot.enemy_features.tolist(),
                        "policy": list(result.enemy_policy),
                        "search_value": -result.root_value,
                        "action": result.enemy_action,
                        "target_kind": target_kind,
                        "legal_mask": snapshot.enemy_mask,
                        "request": snapshot.request,
                        "player_party_size": actor.player_size,
                        "enemy_party_size": actor.enemy_size,
                    }
                    if result.exploitability is not None:
                        player_row["search_exploitability"] = result.exploitability
                        enemy_row["search_exploitability"] = result.exploitability
                        player_row["payoff_spread"] = result.payoff_spread
                        enemy_row["payoff_spread"] = result.payoff_spread
                    if result.diagnostics is not None:
                        for name, value in result.diagnostics.items():
                            player_row[name] = value
                            enemy_row[name] = value
                    if opponents:
                        player_row["episode_kind"] = actor.episode_kind
                        enemy_row["episode_kind"] = actor.episode_kind
                        player_row["opponent_sha256"] = actor.opponent_identity
                        enemy_row["opponent_sha256"] = actor.opponent_identity
                    if actor.episode_kind == "mirror" or actor.candidate_player:
                        actor.pending.append(player_row)
                    if actor.episode_kind == "mirror" or not actor.candidate_player:
                        actor.pending.append(enemy_row)
                next_snapshots = server.episode_steps(
                    [
                        (
                            actor.snapshot.handle,
                            results[actor.episode].player_action,
                            results[actor.episode].enemy_action,
                        )
                        for actor in active
                    ]
                )
                transitions += len(active)
                inspections = server.inspect_many(
                    [snapshot.handle for snapshot in next_snapshots]
                )
                for actor, inspection in zip(active, inspections, strict=True):
                    actor.inspection = inspection
                    actor.timeline[-1]["after"] = _compact_turn_inspection(inspection)
                survivors: list[_ActorEpisode] = []
                for actor, snapshot in zip(active, next_snapshots, strict=True):
                    if snapshot.divergence is not None:
                        actor.final = _compact_inspection(actor.inspection)
                        append_episode(
                            actor,
                            "semantic-divergence",
                            decision + 1,
                            reason=snapshot.divergence,
                        )
                        semantic_divergences += 1
                    elif snapshot.done:
                        actor.final = _compact_inspection(actor.inspection)
                        reward = int(snapshot.terminal_return or 0)
                        for row in actor.pending:
                            row["value"] = (
                                reward if row["side"] == "player" else -reward
                            )
                            if row["request"] == "battle":
                                ordinary_actions += 1
                                voluntary_switches += row["action"] in range(4, 10)
                        rows.extend(actor.pending)
                        examples += len(actor.pending)
                        append_episode(actor, "finished", decision + 1, reward)
                        finished += 1
                    else:
                        actor.snapshot = snapshot
                        survivors.append(actor)
                active = survivors
                if not active:
                    break
                compacted = server.compact_many([actor.snapshot for actor in active])
                for actor, snapshot in zip(active, compacted, strict=True):
                    actor.snapshot = snapshot
            for actor in active:
                actor.final = _compact_inspection(actor.inspection)
                append_episode(
                    actor,
                    "truncated",
                    config.episode_budget,
                    reason=f"decision-horizon-{config.episode_budget}",
                )
                truncated += 1
            completed_episodes += len(batch)
            if progress_path is not None:
                write_actor_progress(
                    progress_path,
                    process,
                    completed_episodes,
                    len(episode_indices),
                    iteration=iteration,
                    finished=finished,
                    truncated=truncated,
                    semantic_divergences=semantic_divergences,
                    transitions=transitions,
                    examples=examples,
                    player_wins=player_wins,
                    enemy_wins=enemy_wins,
                    draws=draws,
                    candidate_wins=candidate_wins,
                    candidate_losses=candidate_losses,
                    candidate_draws=candidate_draws,
                    mean_decisions=total_decisions / completed_episodes,
                    voluntary_switches=voluntary_switches,
                    ordinary_actions=ordinary_actions,
                    voluntary_switch_rate=voluntary_switches / max(1, ordinary_actions),
                    deep_search_decisions=deep_search_decisions,
                    root_only_decisions=root_only_decisions,
                    mirror_episodes=mirror_episodes,
                    opponent_episodes=opponent_episodes,
                    opponent_counts=opponent_counts,
                    party_size_counts=party_size_counts,
                    six_vs_six_battles=party_size_counts.get("6v6", 0),
                    level100_six_vs_six_battles=scheduled_level100_six_vs_six,
                    recent_battles=recent_battles,
                )
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
    tree_rows = [row for row in example_rows if "tree_nodes" in row]
    episode_rows = [row for row in rows if row["type"] == "episode"]
    if len(episode_indices) == config.selfplay_episodes:
        _validate_collection_pairs(episode_rows, config.selfplay_episodes)
    six_vs_six_battles = party_size_counts.get("6v6", 0)
    level100_six_vs_six_battles = sum(
        row["player_party_size"] == FULL_PARTY_SIZE
        and row["enemy_party_size"] == FULL_PARTY_SIZE
        and row["level_profile"] == "level100"
        for row in episode_rows
    )
    if len(
        episode_indices
    ) == config.selfplay_episodes and six_vs_six_battles * 4 < len(episode_indices):
        raise RuntimeError("collection schedule fell below 25% 6v6")
    if (
        len(episode_indices) == config.selfplay_episodes
        and six_vs_six_battles >= 4
        and level100_six_vs_six_battles * 4 != six_vs_six_battles
    ):
        raise RuntimeError("collection schedule is not exactly 25% level-100 6v6")
    return {
        "finished": finished,
        "truncated": truncated,
        "semantic_divergences": semantic_divergences,
        "player_wins": player_wins,
        "enemy_wins": enemy_wins,
        "draws": draws,
        "candidate_wins": candidate_wins,
        "candidate_losses": candidate_losses,
        "candidate_draws": candidate_draws,
        "recent_battles": recent_battles,
        "pairing": "same-reset-opposite-controller-sides-v1",
        "pairs": len(episode_indices) // 2,
        "party_size_schedule": GENERATED_PARTY_SCHEDULE,
        "level_schedule": GENERATED_LEVEL_SCHEDULE,
        "minimum_6v6_fraction": 0.25,
        "level100_6v6_fraction": 0.25,
        "six_vs_six_battles": six_vs_six_battles,
        "level100_six_vs_six_battles": level100_six_vs_six_battles,
        "voluntary_switches": voluntary_switches,
        "ordinary_actions": ordinary_actions,
        "examples": examples,
        "transitions": transitions,
        "deep_search_decisions": deep_search_decisions,
        "root_only_decisions": root_only_decisions,
        "mirror_episodes": mirror_episodes,
        "opponent_episodes": opponent_episodes,
        "candidate_player_episodes": candidate_player_episodes,
        "candidate_enemy_episodes": candidate_enemy_episodes,
        "opponent_counts": opponent_counts,
        "party_size_counts": party_size_counts,
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
        "mean_tree_nodes": (
            sum(row["tree_nodes"] for row in tree_rows) / len(tree_rows)
            if tree_rows
            else None
        ),
        "mean_tree_simulations": (
            sum(row["tree_simulations"] for row in tree_rows) / len(tree_rows)
            if tree_rows
            else None
        ),
        "mean_tree_max_depth": (
            sum(row["tree_max_depth"] for row in tree_rows) / len(tree_rows)
            if tree_rows
            else None
        ),
        "mean_chance_outcomes": (
            sum(row["chance_outcomes"] for row in tree_rows) / len(tree_rows)
            if tree_rows
            else None
        ),
        "mean_sampled_joint_coverage": (
            sum(row["sampled_joint_coverage"] for row in tree_rows) / len(tree_rows)
            if tree_rows
            else None
        ),
        "tree_convergence_rate": (
            sum(row["tree_converged"] for row in tree_rows) / len(tree_rows)
            if tree_rows
            else None
        ),
        "mean_cross_root_batch_size": (
            sum(row["cross_root_batch_size"] for row in tree_rows) / len(tree_rows)
            if tree_rows
            else None
        ),
        "mean_cross_root_root_leaves": (
            sum(row["cross_root_root_leaves"] for row in tree_rows) / len(tree_rows)
            if tree_rows
            else None
        ),
        "mean_decisions": transitions / len(episode_indices),
        "voluntary_switch_rate": sum(
            row["action"] in range(4, 10)
            for row in example_rows
            if row["request"] == "battle"
        )
        / max(1, sum(row["request"] == "battle" for row in example_rows)),
        "sha256": sha256(path),
        "bytes": path.stat().st_size,
    }


def _serialized_model(model: Any) -> dict[str, Any]:
    if isinstance(model, _HeuristicNetwork):
        return {"kind": "heuristic", "style": model.style}
    if not isinstance(model, BattleTransformer):
        raise TypeError("actor process received an unsupported opponent model")
    return {
        "kind": "transformer",
        "config": asdict(model.config),
        "state": {
            name: value.detach().cpu() for name, value in model.state_dict().items()
        },
    }


def _load_serialized_model(record: dict[str, Any], device: torch.device) -> Any:
    if record["kind"] == "heuristic":
        return _HeuristicNetwork(record["style"])
    network = BattleTransformer(TransformerConfig(**record["config"])).to(device)
    network.load_state_dict(record["state"])
    network.eval()
    return network


def _collection_process_worker(
    shard: str,
    model_payload: str,
    config: TransformerPipelineConfig,
    iteration: int,
    episode_indices: list[int],
    progress_path: str,
    process: int,
) -> dict[str, Any]:
    configure_determinism(config.seed + iteration)
    device = choose_device(config.device)
    payload = torch.load(model_payload, map_location="cpu", weights_only=False)
    network = _load_serialized_model(payload["candidate"], device)
    opponents = [
        (_load_serialized_model(record, device), identity)
        for record, identity in payload["opponents"]
    ]
    _configure_inference(
        [network, *(opponent for opponent, _ in opponents)],
        config.inference_engine,
    )
    return _collect_rows_single(
        Path(shard),
        network,
        replace(config, actor_processes=1),
        iteration,
        opponents,
        episode_indices,
        Path(progress_path),
        process,
    )


def _merge_collection_rows(
    path: Path,
    worker_paths: list[Path],
    worker_metrics: list[dict[str, Any]],
    config: TransformerPipelineConfig,
) -> dict[str, Any]:
    rows = []
    actor_shards = []
    meta: dict[str, Any] | None = None
    for process, worker_path in enumerate(worker_paths):
        worker_rows = [
            json.loads(line) for line in worker_path.read_text().splitlines()
        ]
        worker_meta, *data_rows = worker_rows
        if meta is None:
            meta = worker_meta
        rows.extend(data_rows)
        actor_shards.append(
            {
                "process": process,
                "sha256": sha256(worker_path),
                "bytes": worker_path.stat().st_size,
                "episodes": worker_metrics[process]["finished"]
                + worker_metrics[process]["truncated"]
                + worker_metrics[process]["semantic_divergences"],
            }
        )
    assert meta is not None
    meta["episodes"] = config.selfplay_episodes
    meta["actor_processes"] = config.actor_processes
    rows.sort(
        key=lambda row: (
            row["episode"],
            0 if row["type"] == "example" else 1,
            row.get("decision", config.episode_budget),
            0 if row.get("side") == "player" else 1,
        )
    )
    _jsonl(path, [meta, *rows])
    example_rows = [row for row in rows if row["type"] == "example"]
    episode_rows = [row for row in rows if row["type"] == "episode"]
    _validate_collection_pairs(episode_rows, config.selfplay_episodes)
    recent_battles = [
        {
            name: value
            for name, value in row.items()
            if name not in {"type", "initial", "final", "timeline"}
        }
        for row in sorted(
            episode_rows, key=lambda row: int(row["episode"]), reverse=True
        )[:20]
    ]
    tree_rows = [row for row in example_rows if "tree_nodes" in row]
    exploitabilities = [
        row["search_exploitability"]
        for row in example_rows
        if "search_exploitability" in row
    ]
    payoff_spreads = [
        row["payoff_spread"] for row in example_rows if "payoff_spread" in row
    ]

    def total(name: str) -> int:
        return sum(int(metrics[name]) for metrics in worker_metrics)

    def tree_mean(name: str) -> float | None:
        return (
            sum(float(row[name]) for row in tree_rows) / len(tree_rows)
            if tree_rows
            else None
        )

    opponent_counts: dict[str, int] = {}
    party_size_counts: dict[str, int] = {}
    for metrics in worker_metrics:
        for name, count in metrics["opponent_counts"].items():
            opponent_counts[name] = opponent_counts.get(name, 0) + count
        for name, count in metrics["party_size_counts"].items():
            party_size_counts[name] = party_size_counts.get(name, 0) + count
    transitions = total("transitions")
    six_vs_six_battles = party_size_counts.get("6v6", 0)
    level100_six_vs_six_battles = total("level100_six_vs_six_battles")
    if six_vs_six_battles * 4 < config.selfplay_episodes:
        raise RuntimeError("collection schedule fell below 25% 6v6")
    if (
        six_vs_six_battles >= 4
        and level100_six_vs_six_battles * 4 != six_vs_six_battles
    ):
        raise RuntimeError("collection schedule is not exactly 25% level-100 6v6")
    return {
        "finished": total("finished"),
        "truncated": total("truncated"),
        "semantic_divergences": total("semantic_divergences"),
        "player_wins": sum(row.get("return") == 1 for row in episode_rows),
        "enemy_wins": sum(row.get("return") == -1 for row in episode_rows),
        "draws": sum(row.get("return") == 0 for row in episode_rows),
        "candidate_wins": sum(row.get("candidate_return") == 1 for row in episode_rows),
        "candidate_losses": sum(
            row.get("candidate_return") == -1 for row in episode_rows
        ),
        "candidate_draws": sum(
            row.get("candidate_return") == 0 for row in episode_rows
        ),
        "recent_battles": recent_battles,
        "pairing": "same-reset-opposite-controller-sides-v1",
        "pairs": config.selfplay_episodes // 2,
        "examples": len(example_rows),
        "transitions": transitions,
        "deep_search_decisions": total("deep_search_decisions"),
        "root_only_decisions": total("root_only_decisions"),
        "mirror_episodes": total("mirror_episodes"),
        "opponent_episodes": total("opponent_episodes"),
        "candidate_player_episodes": total("candidate_player_episodes"),
        "candidate_enemy_episodes": total("candidate_enemy_episodes"),
        "opponent_counts": opponent_counts,
        "party_size_counts": party_size_counts,
        "party_size_schedule": GENERATED_PARTY_SCHEDULE,
        "level_schedule": GENERATED_LEVEL_SCHEDULE,
        "minimum_6v6_fraction": 0.25,
        "level100_6v6_fraction": 0.25,
        "six_vs_six_battles": six_vs_six_battles,
        "level100_six_vs_six_battles": level100_six_vs_six_battles,
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
        "mean_tree_nodes": tree_mean("tree_nodes"),
        "mean_tree_simulations": tree_mean("tree_simulations"),
        "mean_tree_max_depth": tree_mean("tree_max_depth"),
        "mean_chance_outcomes": tree_mean("chance_outcomes"),
        "mean_sampled_joint_coverage": tree_mean("sampled_joint_coverage"),
        "tree_convergence_rate": tree_mean("tree_converged"),
        "mean_cross_root_batch_size": tree_mean("cross_root_batch_size"),
        "mean_cross_root_root_leaves": tree_mean("cross_root_root_leaves"),
        "mean_decisions": transitions / config.selfplay_episodes,
        "voluntary_switch_rate": sum(
            row["action"] in range(4, 10)
            for row in example_rows
            if row["request"] == "battle"
        )
        / max(1, sum(row["request"] == "battle" for row in example_rows)),
        "actor_shards": actor_shards,
        "sha256": sha256(path),
        "bytes": path.stat().st_size,
    }


def _collect_rows(
    path: Path,
    network: BattleTransformer,
    config: TransformerPipelineConfig,
    iteration: int,
    opponents: list[tuple[Any, str]] | None = None,
    monitor_root: Path | None = None,
) -> dict[str, Any]:
    progress_dir = (
        monitor_root / ".monitor" if monitor_root is not None else path.parent
    )
    progress_dir.mkdir(parents=True, exist_ok=True)
    for old_progress in progress_dir.glob("actor-*.json"):
        old_progress.unlink()
    if config.actor_processes == 1:
        return _collect_rows_single(
            path,
            network,
            config,
            iteration,
            opponents,
            progress_path=progress_dir / "actor-00.json",
        )
    opponents = opponents or []
    payload = {
        "candidate": _serialized_model(network),
        "opponents": [
            (_serialized_model(opponent), identity) for opponent, identity in opponents
        ],
    }
    partitions = [
        list(range(process, config.selfplay_episodes, config.actor_processes))
        for process in range(config.actor_processes)
    ]
    context = multiprocessing.get_context("spawn")
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="battle-actors-", dir=path.parent) as raw:
        temporary = Path(raw)
        model_payload = temporary / "models.pt"
        torch.save(payload, model_payload)
        worker_paths = [
            temporary / f"actor-{process:02d}.jsonl"
            for process in range(config.actor_processes)
        ]
        with ProcessPoolExecutor(
            max_workers=config.actor_processes, mp_context=context
        ) as executor:
            futures = [
                executor.submit(
                    _collection_process_worker,
                    str(worker_path),
                    str(model_payload),
                    config,
                    iteration,
                    episodes,
                    str(progress_dir / f"actor-{process:02d}.json"),
                    process,
                )
                for process, (worker_path, episodes) in enumerate(
                    zip(worker_paths, partitions, strict=True)
                )
            ]
            metrics = [future.result() for future in futures]
        return _merge_collection_rows(path, worker_paths, metrics, config)


ExampleTensors = tuple[Tensor, Tensor, Tensor, Tensor, Tensor]


def _rows_to_examples(rows: list[dict[str, Any]]) -> ExampleTensors:
    features = [row["features"] for row in rows]
    policies = [row["policy"] for row in rows]
    values = [row["value"] for row in rows]
    legal_masks = [
        [
            bool(row["legal_mask"] & (1 << action))
            for action in range(len(row["policy"]))
        ]
        for row in rows
    ]
    policy_weights = [
        0.0 if row.get("target_kind") == "policy-rollout" else 1.0 for row in rows
    ]
    return (
        torch.tensor(features, dtype=torch.long),
        torch.tensor(policies, dtype=torch.float32),
        torch.tensor(values, dtype=torch.float32),
        torch.tensor(legal_masks, dtype=torch.bool),
        torch.tensor(policy_weights, dtype=torch.float32),
    )


def _example_rows(paths: list[Path]) -> list[dict[str, Any]]:
    rows = []
    for path_index, path in enumerate(paths):
        raw_iteration = path.stem.removeprefix("iteration-")
        shard_iteration = (
            int(raw_iteration) if raw_iteration.isdigit() else path_index + 1
        )
        with path.open() as source:
            for line in source:
                row = json.loads(line)
                if row["type"] == "example":
                    row["shard_iteration"] = shard_iteration
                    rows.append(row)
    return rows


def _load_examples(paths: list[Path]) -> ExampleTensors:
    return _rows_to_examples(_example_rows(paths))


def _load_partitioned_examples(
    paths: list[Path],
) -> tuple[ExampleTensors, ExampleTensors, list[tuple[int, int]]]:
    training_rows = []
    heldout_rows = []
    heldout_battles = []
    for row in _example_rows(paths):
        shard_iteration = int(row["shard_iteration"])
        episode = int(row["episode"])
        heldout = episode % 10 == (shard_iteration - 1) % 10
        if heldout:
            heldout_rows.append(row)
            heldout_battles.append((shard_iteration, episode))
        else:
            training_rows.append(row)
    if not training_rows or not heldout_rows:
        raise ValueError("whole-battle diagnostic split produced an empty partition")
    return (
        _rows_to_examples(training_rows),
        _rows_to_examples(heldout_rows),
        heldout_battles,
    )


def _heldout_diagnostics(
    network: BattleTransformer,
    examples: ExampleTensors,
    battle_ids: list[tuple[int, int]],
    batch_size: int,
) -> dict[str, Any]:
    features, target_policy, target_value, legal_masks, policy_weights = examples
    device = next(network.parameters()).device
    squared_errors: list[float] = []
    policy_cross_entropy = 0.0
    target_entropy = 0.0
    top_action_matches = 0
    weighted_policy_rows = 0.0
    network.eval()
    with torch.inference_mode():
        for start in range(0, len(features), batch_size):
            stop = min(len(features), start + batch_size)
            batch_features = features[start:stop].to(device)
            batch_policy = target_policy[start:stop].to(device)
            batch_value = target_value[start:stop].to(device)
            batch_legal = legal_masks[start:stop].to(device)
            batch_weights = policy_weights[start:stop].to(device)
            logits, values = network(batch_features)
            logits = logits.masked_fill(~batch_legal, torch.finfo(logits.dtype).min)
            log_policy = torch.log_softmax(logits, dim=-1)
            cross_entropy = -(batch_policy * log_policy).sum(dim=-1)
            entropy = -(batch_policy * batch_policy.clamp_min(1e-12).log()).sum(dim=-1)
            policy_cross_entropy += float((cross_entropy * batch_weights).sum())
            target_entropy += float((entropy * batch_weights).sum())
            weighted_policy_rows += float(batch_weights.sum())
            top_action_matches += int(
                (
                    logits.argmax(dim=-1).eq(batch_policy.argmax(dim=-1))
                    * batch_weights.bool()
                )
                .sum()
                .item()
            )
            squared_errors.extend(
                (values - batch_value).square().float().cpu().tolist()
            )
    battle_errors: dict[tuple[int, int], list[float]] = {}
    for battle, error in zip(battle_ids, squared_errors, strict=True):
        battle_errors.setdefault(battle, []).append(error)
    row_value_mse = sum(squared_errors) / len(squared_errors)
    battle_value_mse = sum(
        sum(errors) / len(errors) for errors in battle_errors.values()
    ) / len(battle_errors)
    zero_value_mse = float(target_value.square().mean())
    mean_cross_entropy = policy_cross_entropy / max(1.0, weighted_policy_rows)
    mean_target_entropy = target_entropy / max(1.0, weighted_policy_rows)
    return {
        "split": "whole-battle-shard-episode-mod10-v1",
        "rows": len(features),
        "battles": len(battle_errors),
        "value_mse_equal_row": row_value_mse,
        "value_mse_equal_battle": battle_value_mse,
        "zero_value_mse": zero_value_mse,
        "value_mse_vs_zero_equal_row": row_value_mse - zero_value_mse,
        "policy_cross_entropy": mean_cross_entropy,
        "policy_target_entropy": mean_target_entropy,
        "policy_kl": mean_cross_entropy - mean_target_entropy,
        "policy_top_action_agreement": top_action_matches
        / max(1.0, weighted_policy_rows),
    }


def _gradient_report(
    samples: list[tuple[float, float, float | None]],
) -> dict[str, Any]:
    if not samples:
        return {
            "samples": 0,
            "cosine_samples": 0,
            "policy_trunk_norm": None,
            "value_trunk_norm": None,
            "value_policy_norm_ratio": None,
            "mean_cosine": None,
            "negative_cosine_fraction": None,
        }
    policy_norm = sum(sample[0] for sample in samples) / len(samples)
    value_norm = sum(sample[1] for sample in samples) / len(samples)
    cosines = [sample[2] for sample in samples if sample[2] is not None]
    return {
        "samples": len(samples),
        "cosine_samples": len(cosines),
        "policy_trunk_norm": policy_norm,
        "value_trunk_norm": value_norm,
        "value_policy_norm_ratio": value_norm / max(policy_norm, 1e-12),
        "mean_cosine": sum(cosines) / len(cosines) if cosines else None,
        "negative_cosine_fraction": (
            sum(cosine < 0.0 for cosine in cosines) / len(cosines) if cosines else None
        ),
    }


def _train_network(
    network: BattleTransformer,
    optimizer: torch.optim.Optimizer,
    shards: list[Path],
    config: TransformerPipelineConfig,
    iteration: int,
) -> dict[str, Any]:
    device = next(network.parameters()).device
    training_examples, heldout_examples, heldout_battles = _load_partitioned_examples(
        shards
    )
    features, target_policy, target_value, legal_masks, policy_weights = (
        training_examples
    )
    generator = torch.Generator(device="cpu").manual_seed(config.seed + iteration)
    trunk_parameters = [
        parameter
        for name, parameter in network.named_parameters()
        if not name.startswith(("policy.", "value."))
    ]
    heldout_before = _heldout_diagnostics(
        network, heldout_examples, heldout_battles, config.inference_batch_size
    )
    network.train()
    history: list[dict[str, float]] = []
    diagnostic_epochs: list[dict[str, Any]] = []
    for epoch in range(config.epochs):
        permutation = torch.randperm(len(features), generator=generator)
        policy_total = value_total = total_total = 0.0
        gradient_samples: list[tuple[float, float, float | None]] = []
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
            if len(gradient_samples) < 8:
                policy_gradients = torch.autograd.grad(
                    policy_loss,
                    trunk_parameters,
                    retain_graph=True,
                    allow_unused=True,
                )
                value_gradients = torch.autograd.grad(
                    value_loss,
                    trunk_parameters,
                    retain_graph=True,
                    allow_unused=True,
                )
                policy_squared = sum(
                    gradient.float().square().sum()
                    for gradient in policy_gradients
                    if gradient is not None
                )
                value_squared = sum(
                    gradient.float().square().sum()
                    for gradient in value_gradients
                    if gradient is not None
                )
                gradient_dot = sum(
                    policy_gradient.float().mul(value_gradient.float()).sum()
                    for policy_gradient, value_gradient in zip(
                        policy_gradients, value_gradients, strict=True
                    )
                    if policy_gradient is not None and value_gradient is not None
                )
                policy_norm = float(policy_squared.sqrt())
                value_norm = float(value_squared.sqrt())
                gradient_samples.append(
                    (
                        policy_norm,
                        value_norm,
                        (
                            float(gradient_dot) / (policy_norm * value_norm)
                            if policy_norm > 0.0 and value_norm > 0.0
                            else None
                        ),
                    )
                )
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
        heldout = _heldout_diagnostics(
            network, heldout_examples, heldout_battles, config.inference_batch_size
        )
        gradient = _gradient_report(gradient_samples)
        epoch_diagnostics = {
            "epoch": epoch,
            "gradient": gradient,
            "heldout": heldout,
        }
        diagnostic_epochs.append(epoch_diagnostics)
        print(
            json.dumps(
                {
                    "event": "training-diagnostics",
                    "iteration": iteration,
                    **epoch_diagnostics,
                },
                sort_keys=True,
            ),
            flush=True,
        )
        network.train()
    network.eval()
    return {
        "examples": len(features),
        "heldout_examples": len(heldout_examples[0]),
        "heldout_battles": len(set(heldout_battles)),
        "epochs": config.epochs,
        "batches_per_epoch": math.ceil(len(features) / config.batch_size),
        "history": history,
        "diagnostics": {
            "heldout_before": heldout_before,
            "epochs": diagnostic_epochs,
            "latest": diagnostic_epochs[-1],
        },
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
    pair = episode // 2
    player_size, enemy_size = generated_party_sizes(pair)
    snapshot = server.reset(
        config.seed + 90_000_000,
        episode,
        player_size,
        enemy_size,
        level100=generated_level100(pair),
    )
    for _ in range(config.episode_budget):
        search = _new_search(server, player, enemy, config, selection_rng, chance_rng)
        result = search.search(snapshot, sample_actions=True)
        snapshot = server.episode_step(
            snapshot.handle, result.player_action, result.enemy_action
        )
        if snapshot.done:
            return snapshot.terminal_return
        snapshot = server.compact(snapshot)
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


def _iteration_numbers(directory: Path, prefix: str, suffix: str) -> set[int]:
    numbers: set[int] = set()
    for path in directory.glob(f"{prefix}*{suffix}"):
        raw = path.name.removeprefix(prefix).removesuffix(suffix)
        if raw.isdigit():
            numbers.add(int(raw))
    return numbers


def _archive_incomplete_iteration(
    root: Path, iteration: int, artifacts: list[Path]
) -> None:
    if not artifacts:
        return
    attempts = root / "attempts"
    attempt = 1
    while True:
        destination = attempts / f"iteration-{iteration:03d}-attempt-{attempt:03d}"
        if not destination.exists():
            break
        attempt += 1
    records = []
    for source in artifacts:
        relative = source.relative_to(root)
        records.append(
            {
                "path": relative.as_posix(),
                "bytes": source.stat().st_size,
                "sha256": sha256(source),
            }
        )
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        source.replace(target)
    write_json(
        destination / "resume.json",
        {
            "reason": "incomplete-iteration-without-checkpoint",
            "iteration": iteration,
            "artifacts": records,
        },
    )


def _load_completed_prefix(
    root: Path,
) -> tuple[
    int,
    list[Path],
    list[dict[str, Any]],
    list[dict[str, Any]],
    list[int],
]:
    checkpoint_dir = root / "checkpoints"
    shard_dir = root / "shards"
    metric_dir = root / "metrics"
    checkpoint_numbers = _iteration_numbers(checkpoint_dir, "policy-", ".pt") - {0}
    if checkpoint_numbers:
        completed = max(checkpoint_numbers)
        expected = set(range(1, completed + 1))
        if checkpoint_numbers != expected:
            raise ValueError("resume checkpoints are not a contiguous iteration prefix")
    else:
        completed = 0

    shard_numbers = _iteration_numbers(shard_dir, "iteration-", ".jsonl")
    metric_numbers = _iteration_numbers(metric_dir, "iteration-", ".json")
    orphan_numbers = (shard_numbers | metric_numbers) - checkpoint_numbers
    if orphan_numbers:
        if orphan_numbers != {completed + 1}:
            raise ValueError(
                "resume found noncontiguous incomplete iteration artifacts"
            )
        iteration = completed + 1
        artifacts = [
            path
            for path in (
                shard_dir / f"iteration-{iteration:03d}.jsonl",
                metric_dir / f"iteration-{iteration:03d}.json",
            )
            if path.is_file()
        ]
        _archive_incomplete_iteration(root, iteration, artifacts)
        shard_numbers.discard(iteration)
        metric_numbers.discard(iteration)

    if shard_numbers != checkpoint_numbers:
        raise ValueError("each completed checkpoint must have exactly one replay shard")

    shards: list[Path] = []
    collection: list[dict[str, Any]] = []
    training: list[dict[str, Any]] = []
    accepted: list[int] = []
    for iteration in range(1, completed + 1):
        checkpoint = checkpoint_dir / f"policy-{iteration:03d}.pt"
        shard = shard_dir / f"iteration-{iteration:03d}.jsonl"
        payload = load_checkpoint(checkpoint, torch.device("cpu"))
        metadata = payload.get("metadata")
        if not isinstance(metadata, dict) or metadata.get("iteration") != iteration:
            raise ValueError(f"checkpoint {iteration} has invalid iteration metadata")
        collection_metrics = metadata.get("collection")
        training_metrics = metadata.get("training")
        if not isinstance(collection_metrics, dict) or not isinstance(
            training_metrics, dict
        ):
            raise TypeError(f"checkpoint {iteration} lacks resumable metrics")
        if collection_metrics.get("sha256") != sha256(shard):
            raise ValueError(f"checkpoint {iteration} replay shard hash mismatch")
        expected_metric = {
            "collection": collection_metrics,
            "training": training_metrics,
            "promotion": training_metrics.get("promotion"),
        }
        metric = metric_dir / f"iteration-{iteration:03d}.json"
        if metric.is_file():
            if json.loads(metric.read_text()) != expected_metric:
                raise ValueError(
                    f"iteration {iteration} metric disagrees with checkpoint"
                )
        else:
            write_json(metric, expected_metric)
        shards.append(shard)
        collection.append(collection_metrics)
        training.append(training_metrics)
        promotion = training_metrics.get("promotion")
        if isinstance(promotion, dict) and promotion.get("accepted") is True:
            accepted.append(iteration)
    return completed, shards, collection, training, accepted


def _resume_config(root: Path) -> TransformerPipelineConfig:
    run_path = root / "run.json"
    if not run_path.is_file():
        raise FileNotFoundError(f"resume metadata is missing: {run_path}")
    run = json.loads(run_path.read_text())
    if run.get("pipeline") != _pipeline_id():
        raise ValueError(
            "resume pipeline version differs from the current implementation"
        )
    if run.get("profile") != FULL_PROFILE or run.get("schema") != FULL_SCHEMA:
        raise ValueError("resume mechanics profile or tensor schema differs")
    raw_config = dict(run["config"])
    raw_config.setdefault("precision", "fp32")
    return TransformerPipelineConfig(**raw_config)


def resume_transformer_pipeline(root: Path) -> dict[str, Any]:
    """Continue an interrupted run from its last committed iteration."""
    return run_transformer_pipeline(root, _resume_config(root), resume=True)


def run_transformer_pipeline(
    root: Path, config: TransformerPipelineConfig, *, resume: bool = False
) -> dict[str, Any]:
    if resume:
        if not root.is_dir():
            raise FileNotFoundError(f"resume output directory is missing: {root}")
        if (root / "summary.json").exists() or (root / "manifest.json").exists():
            raise ValueError("training run is already complete")
    elif root.exists() and any(root.iterdir()):
        raise FileExistsError(f"output directory is not empty: {root}")
    if config.arena_episodes < 4 or config.arena_episodes % 2:
        raise ValueError("arena_episodes must be an even number of at least four")
    root.mkdir(parents=True, exist_ok=True)
    write_monitor_state(root, "initializing", message="Validating native protocol")
    if config.selfplay_episodes < 4 or config.selfplay_episodes % 4:
        raise ValueError("selfplay_episodes must be a positive multiple of four")
    if config.search_every < 1:
        raise ValueError("search_every must be positive")
    if config.tree_expansion_budget < 1:
        raise ValueError("tree_expansion_budget must be positive")
    if not 0.0 <= config.tree_exploration <= 1.0:
        raise ValueError("tree_exploration must be in [0, 1]")
    if not 0.0 <= config.tree_chance_resample <= 1.0:
        raise ValueError("tree_chance_resample must be in [0, 1]")
    if config.tree_regret_iterations < 1:
        raise ValueError("tree_regret_iterations must be positive")
    if config.tree_deeper_joint_rotations < 1:
        raise ValueError("tree_deeper_joint_rotations must be positive")
    if not 1 <= config.tree_minimum_budget <= config.tree_expansion_budget:
        raise ValueError("tree_minimum_budget must be in 1..tree_expansion_budget")
    if config.tree_convergence_tolerance < 0.0:
        raise ValueError("tree_convergence_tolerance must be nonnegative")
    if config.tree_convergence_patience < 1:
        raise ValueError("tree_convergence_patience must be positive")
    if not 0.0 <= config.deep_search_fraction <= 1.0:
        raise ValueError("deep_search_fraction must be in [0, 1]")
    if config.actor_batch_size < 1:
        raise ValueError("actor_batch_size must be positive")
    if not 1 <= config.actor_processes <= min(4, config.selfplay_episodes):
        raise ValueError("actor_processes must be in 1..min(4, selfplay_episodes)")
    if config.precision not in {"bf16", "fp32"}:
        raise ValueError("precision must be bf16 or fp32")
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
    if config.campaign_games < 18 or config.campaign_games % 2:
        raise ValueError("campaign_games must be even and cover all nine fixed teams")
    if (
        config.promotion_seed_count < 2
        or config.probe_seed_count < 2
        or config.campaign_seed_count < 2
    ):
        raise ValueError("promotion, probe, and campaign arenas require multiple seeds")
    if config.promotion_games < 2 * config.promotion_seed_count:
        raise ValueError("promotion games must cover every promotion seed")
    if config.probe_games < 2 * config.probe_seed_count:
        raise ValueError("probe games must cover every probe seed")
    if config.campaign_games < 2 * config.campaign_seed_count:
        raise ValueError("campaign games must cover every campaign seed")
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
        if config.campaign_games < 288:
            raise ValueError(
                "quality-gated training requires at least 288 campaign games"
            )
    if not 0.0 <= config.opponent_fraction <= 1.0:
        raise ValueError("opponent_fraction must be in [0, 1]")
    build_search_server()
    with SearchServer() as protocol:
        feature_count = protocol.feature_count
        action_count = protocol.action_count
    configure_determinism(config.seed)
    device = choose_device(config.device)
    if (
        config.precision == "bf16"
        and device.type == "cuda"
        and not torch.cuda.is_bf16_supported()
    ):
        raise RuntimeError("bf16 training requires a bf16-capable CUDA device")
    if config.precision == "bf16" and device.type not in {"cpu", "cuda"}:
        raise RuntimeError(f"bf16 training is unsupported on {device.type}")
    if config.inference_engine not in {"auto", "eager", "compiled"}:
        raise ValueError("inference_engine must be auto, eager, or compiled")
    if config.inference_engine == "compiled" and device.type != "cuda":
        raise ValueError("compiled inference requires CUDA")
    model_config = TransformerConfig(
        feature_count=feature_count,
        action_count=action_count,
        d_model=config.d_model,
        heads=config.heads,
        layers=config.layers,
        feedforward=config.feedforward,
        precision=config.precision,
        token_group_size=config.token_group_size,
    )
    opponents: list[tuple[Any, str]] = []
    opponent_metadata: list[dict[str, Any]] = []
    initial_checkpoint = root / "checkpoints" / "policy-000.pt"

    if resume:
        run_metadata = json.loads((root / "run.json").read_text())
        if run_metadata.get("config") != asdict(config):
            raise ValueError("resume configuration differs from immutable run metadata")
        if run_metadata.get("network") != asdict(model_config):
            raise ValueError("resume network shape differs from the native protocol")
        for metadata in run_metadata.get("opponents", []):
            if metadata["kind"] == "fixed-checkpoint":
                opponent_copy = root / metadata["checkpoint"]
                opponent_sha = sha256(opponent_copy)
                if opponent_sha != metadata["sha256"]:
                    raise ValueError("resume fixed-opponent hash mismatch")
                opponents.append((load_network(opponent_copy, device), opponent_sha))
            elif metadata["kind"] == "heuristic":
                style = metadata["style"]
                opponents.append((_HeuristicNetwork(style), metadata["identity"]))
            else:
                raise ValueError("resume opponent kind is unknown")
            opponent_metadata.append(metadata)
        if not initial_checkpoint.is_file():
            raise FileNotFoundError("resume initial checkpoint is missing")
        completed, shards, collection, training, accepted_iterations = (
            _load_completed_prefix(root)
        )
        if completed >= config.iterations:
            raise ValueError("all configured training iterations are already complete")
        latest_checkpoint = root / "checkpoints" / f"policy-{completed:03d}.pt"
        incumbent_network = load_network(latest_checkpoint, device)
        if incumbent_network.config != model_config:
            raise ValueError("resume checkpoint network configuration differs")
        latest_payload = load_checkpoint(latest_checkpoint, device)
        learner_state = latest_payload.get("learner_model")
        if not isinstance(learner_state, dict):
            raise ValueError("resume checkpoint lacks persistent learner state")
        network = BattleTransformer(model_config).to(device)
        network.load_state_dict(learner_state)
        network.eval()
        optimizer = torch.optim.AdamW(
            network.parameters(),
            lr=config.learning_rate,
            weight_decay=config.weight_decay,
        )
        if completed:
            optimizer_state = latest_payload.get("optimizer")
            if optimizer_state is None:
                raise ValueError("resume checkpoint lacks AdamW state")
            optimizer.load_state_dict(optimizer_state)
        torch_rng = latest_payload.get("torch_rng")
        if isinstance(torch_rng, Tensor):
            torch.random.set_rng_state(torch_rng.cpu())
        first_iteration = completed + 1
    else:
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
        if config.heuristic_opponents:
            for heuristic, identity in _heuristic_population():
                opponents.append((heuristic, identity))
                opponent_metadata.append(
                    {
                        "kind": "heuristic",
                        "style": heuristic.style,
                        "identity": identity,
                    }
                )
        warm_start_metadata: dict[str, Any] | None = None
        if config.warm_start_checkpoint is not None:
            warm_source = Path(config.warm_start_checkpoint).resolve()
            warm_sha = sha256(warm_source)
            warm_copy = root / "warm-start" / "source.pt"
            write_new(warm_copy, warm_source.read_bytes())
            network = warm_start_network(warm_copy, model_config, device)
            warm_start_metadata = {
                "checkpoint": warm_copy.relative_to(root).as_posix(),
                "sha256": warm_sha,
                "method": "extend-position-table-v1",
            }
        else:
            network = BattleTransformer(model_config).to(device)
            network.eval()
        incumbent_network = network.detached_copy(device)
        write_json(
            root / "run.json",
            {
                "pipeline": _pipeline_id(),
                "profile": FULL_PROFILE,
                "schema": FULL_SCHEMA,
                "max_party_size": FULL_PARTY_SIZE,
                "party_size_schedule": GENERATED_PARTY_SCHEDULE,
                "level_schedule": GENERATED_LEVEL_SCHEDULE,
                "chance": "fresh-root-v1",
                "search_solver": "simultaneous-matrix-tree-rmplus-v1",
                "collection_pairing": "same-reset-opposite-controller-sides-v1",
                "learning_lineage": "persistent-shadow-v1",
                "deployment_lineage": "quality-gated-incumbent-v1",
                "config": asdict(config),
                "network": asdict(model_config),
                "parameter_count": sum(
                    parameter.numel() for parameter in network.parameters()
                ),
                "opponents": opponent_metadata,
                "warm_start": warm_start_metadata,
                "torch": torch.__version__,
                "device": str(device),
                "device_name": torch.cuda.get_device_name(device)
                if device.type == "cuda"
                else "cpu",
            },
        )
        save_network(
            initial_checkpoint,
            incumbent_network,
            None,
            {
                "iteration": 0,
                "kind": "initial",
                "warm_start": warm_start_metadata,
                "learning_lineage": "persistent-shadow-v1",
            },
            {"learner_model": network.state_dict()},
        )
        shards = []
        collection = []
        training = []
        accepted_iterations = []
        optimizer = torch.optim.AdamW(
            network.parameters(),
            lr=config.learning_rate,
            weight_decay=config.weight_decay,
        )
        first_iteration = 1

    initial = load_network(initial_checkpoint, device)
    initial_identity = sha256(initial_checkpoint)
    initial_anchor = initial.detached_copy(device)
    incumbent_identity = (
        sha256(root / "checkpoints" / f"policy-{accepted_iterations[-1]:03d}.pt")
        if accepted_iterations
        else initial_identity
    )
    historical = [
        (
            load_network(root / "checkpoints" / f"policy-{iteration:03d}.pt", device),
            sha256(root / "checkpoints" / f"policy-{iteration:03d}.pt"),
        )
        for iteration in accepted_iterations[-(config.historical_window + 1) :]
    ]
    _configure_inference(
        [network, incumbent_network, initial, initial_anchor]
        + [model for model, _ in opponents]
        + [model for model, _ in historical],
        config.inference_engine,
    )
    write_monitor_state(
        root,
        "ready",
        iteration=first_iteration,
        message="Models loaded; collection is ready",
    )
    for iteration in range(first_iteration, config.iterations + 1):
        population = opponents + [(incumbent_network, incumbent_identity)]
        if incumbent_identity != initial_identity:
            population.append((initial_anchor, initial_identity))
        if config.historical_window:
            population.extend(historical[:-1][-config.historical_window :])
        population = list(
            {identity: (model, identity) for model, identity in population}.values()
        )
        shard = root / "shards" / f"iteration-{iteration:03d}.jsonl"
        write_monitor_state(
            root,
            "collection",
            iteration=iteration,
            message=f"Collecting {config.selfplay_episodes} self-play battles",
            battles=config.selfplay_episodes,
        )
        try:
            collection_metrics = _collect_rows(
                shard, network, config, iteration, population, monitor_root=root
            )
        except NativeRequestTimeout as error:
            write_monitor_state(
                root,
                "failed",
                iteration=iteration,
                message=f"Native collection timeout: {error.operation}",
            )
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
        write_monitor_state(
            root,
            "training",
            iteration=iteration,
            message=f"Optimizing on {collection_metrics['examples']:,} examples",
            collection={
                "finished": collection_metrics["finished"],
                "examples": collection_metrics["examples"],
                "transitions": collection_metrics["transitions"],
            },
        )
        training_metrics = _train_network(
            network, optimizer, training_shards, config, iteration
        )
        write_monitor_state(
            root,
            "promotion",
            iteration=iteration,
            message=f"Running {config.promotion_games:,} paired promotion games",
            games=config.promotion_games,
            training_diagnostics=training_metrics["diagnostics"]["latest"],
        )
        promotion = run_paired_arena(
            network,
            incumbent_network,
            config.promotion_games,
            config.episode_budget,
            config.seed + 70_000_000 + iteration * 10_007,
            config.promotion_seed_count,
            capture_details=True,
        )
        promotion_detail_dir = root / "matches" / f"promotion-{iteration:03d}"
        for battle in promotion["battles"]:
            write_json(
                promotion_detail_dir / f"game-{battle['game']:05d}.json",
                {"kind": "promotion", "iteration": iteration, **battle},
            )
        write_json(
            promotion_detail_dir / "index.json",
            {
                "iteration": iteration,
                "pairing": promotion["pairing"],
                "side_swap_complete": promotion["side_swap_complete"],
                "games": promotion["games"],
            },
        )
        promotion["detail_artifact"] = (
            promotion_detail_dir.relative_to(root).as_posix() + "/game-{game:05d}.json"
        )
        promotion["battles"] = [
            {
                name: value
                for name, value in battle.items()
                if name not in {"initial", "final", "timeline"}
            }
            for battle in promotion["battles"]
        ]
        live_promotion = {
            "games": promotion["games"],
            "wins": promotion["wins"],
            "losses": promotion["losses"],
            "draws": promotion["draws"],
            "truncated": promotion["truncated"],
            "semantic_divergences": promotion["semantic_divergences"],
            "score_with_nonfinishes_as_losses": promotion[
                "score_with_nonfinishes_as_losses"
            ],
            "paired_score_ci95": promotion["paired_score_ci95"],
            "battles": promotion["battles"][-40:],
        }
        write_monitor_state(
            root,
            "probes",
            iteration=iteration,
            message=f"Running {config.probe_games:,} held-out skill probes",
            games=config.probe_games,
            promotion=live_promotion,
            training_diagnostics=training_metrics["diagnostics"]["latest"],
        )
        probe_arena = run_traced_arena(
            network,
            incumbent_network,
            ArenaConfig(
                games=config.probe_games,
                budget=config.episode_budget,
                seed=config.seed + 80_000_000 + iteration * 10_009,
                replay_games=0,
                seed_count=config.probe_seed_count,
            ),
        )
        probes = skill_probe_report(probe_arena)
        write_monitor_state(
            root,
            "campaign",
            iteration=iteration,
            message=f"Running {config.campaign_games:,} campaign battles",
            games=config.campaign_games,
            promotion=live_promotion,
            probes_pass=probes["pass"],
            training_diagnostics=training_metrics["diagnostics"]["latest"],
        )
        campaign_arena = run_campaign_arena(
            network,
            incumbent_network,
            config.campaign_games,
            config.episode_budget,
            config.seed + 85_000_000 + iteration * 10_019,
            config.campaign_seed_count,
        )
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
                and promotion["strata"]["pass"]
                and campaign_arena["data_quality_pass"]
                and campaign_arena["quality_pass"]
                and campaign_arena["campaign"]["pass"]
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
        promotion["stratified_party_gate"] = promotion["strata"]["pass"]
        promotion["held_out_probes"] = probes
        promotion["probe_arena"] = probe_arena
        promotion["campaign_arena"] = campaign_arena
        promotion["campaign_gate"] = campaign_arena["campaign"]["pass"]
        promotion["accepted"] = accepted
        promotion["learner_persisted"] = True
        promotion["deployment_updated"] = accepted
        if accepted:
            incumbent_network.load_state_dict(network.state_dict())
            incumbent_network.eval()
        training_metrics["promotion"] = promotion
        training.append(training_metrics)
        write_monitor_state(
            root,
            "checkpoint",
            iteration=iteration,
            message=(
                "Publishing promoted model"
                if accepted
                else "Incumbent retained; shadow learner continues"
            ),
            accepted=accepted,
            promotion_score=promotion_score,
            confidence_low=confidence_low,
            promotion={**live_promotion, "accepted": accepted},
            training_diagnostics=training_metrics["diagnostics"]["latest"],
        )
        checkpoint = root / "checkpoints" / f"policy-{iteration:03d}.pt"
        save_network(
            checkpoint,
            incumbent_network,
            optimizer,
            {
                "iteration": iteration,
                "source_shards": [
                    path.relative_to(root).as_posix() for path in training_shards
                ],
                "collection": collection_metrics,
                "training": training_metrics,
                "learning_lineage": "persistent-shadow-v1",
                "deployment_lineage": "quality-gated-incumbent-v1",
            },
            {"learner_model": network.state_dict()},
        )
        if accepted:
            incumbent_identity = sha256(checkpoint)
            historical.append(
                (incumbent_network.detached_copy(device), incumbent_identity)
            )
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
        write_monitor_state(
            root,
            "iteration-complete",
            iteration=iteration,
            message=(
                "Candidate promoted"
                if accepted
                else "Incumbent retained; shadow learner carried forward"
            ),
            accepted=accepted,
            promotion_score=promotion_score,
            confidence_low=confidence_low,
        )
    write_monitor_state(
        root,
        "final-arena",
        iteration=config.iterations,
        message="Running final model evaluations",
    )
    deployed_distance = _parameter_distance(initial, incumbent_network)
    learner_distance = _parameter_distance(initial, network)
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
        root / "arena" / "final-vs-initial", incumbent_network, initial, arena_config
    )
    opponent_arenas = []
    for index, (opponent, identity) in enumerate(opponents):
        result = write_arena_report(
            root / "arena" / f"final-vs-fixed-{index:03d}",
            incumbent_network,
            opponent,
            arena_config,
        )
        result["opponent_sha256"] = identity
        opponent_arenas.append(result)

    with tempfile.TemporaryDirectory(prefix="battle-transformer-replay-") as temporary:
        replay_path = Path(temporary) / "replay.jsonl"
        replay_network = load_network(initial_checkpoint, device)
        replay_network.configure_inference(config.inference_engine)
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
        and all(
            item["promotion"]["campaign_arena"]["data_quality_pass"]
            for item in training
        )
    )
    evaluation_quality_pass = (
        arena["quality_pass"]
        and all(item["quality_pass"] for item in opponent_arenas)
        and all(item["promotion"]["quality_pass"] for item in training)
        and all(item["promotion"]["probe_arena"]["quality_pass"] for item in training)
        and all(
            item["promotion"]["campaign_arena"]["quality_pass"] for item in training
        )
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
        "parameter_count": sum(
            parameter.numel() for parameter in incumbent_network.parameters()
        ),
        "examples": sum(item["examples"] for item in collection),
        "parameter_l2_delta": deployed_distance,
        "deployed_parameter_l2_delta": deployed_distance,
        "learner_parameter_l2_delta": learner_distance,
        "learning_lineage": "persistent-shadow-v1",
        "deployment_lineage": "quality-gated-incumbent-v1",
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
            "accepted_updates_passed_party_strata": (
                accepted_updates > 0
                and all(
                    item["promotion"]["stratified_party_gate"]
                    for item in training
                    if item["promotion"]["accepted"]
                )
            ),
            "accepted_updates_passed_campaign_suite": (
                accepted_updates > 0
                and all(
                    item["promotion"]["campaign_gate"]
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
    write_monitor_state(
        root,
        "completed",
        iteration=config.iterations,
        message="Training complete; publishing immutable manifest",
        accepted_updates=accepted_updates,
        quality_gate_pass=quality_gate_pass,
    )
    (root / "monitor-state.json").unlink(missing_ok=True)
    shutil.rmtree(root / ".monitor", ignore_errors=True)
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
    raw_config = dict(run["config"])
    # Runs written before v5 used strict FP32 and must replay under that contract.
    raw_config.setdefault("precision", "fp32")
    raw_config.setdefault("inference_engine", "eager")
    config = TransformerPipelineConfig(**raw_config)
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
    opponents: list[tuple[Any, str]] = []
    for opponent_metadata in run.get("opponents", []):
        if opponent_metadata["kind"] == "fixed-checkpoint":
            opponent_path = root / opponent_metadata["checkpoint"]
            opponent_sha = sha256(opponent_path)
            if opponent_sha != opponent_metadata["sha256"]:
                raise ValueError("fixed opponent checkpoint hash mismatch")
            opponents.append((load_network(opponent_path, device), opponent_sha))
        elif opponent_metadata["kind"] == "heuristic":
            opponents.append(
                (
                    _HeuristicNetwork(opponent_metadata["style"]),
                    opponent_metadata["identity"],
                )
            )
        else:
            raise ValueError("opponent kind is unknown")
    opponents.append((load_network(initial_path, device), sha256(initial_path)))
    opponents = list(
        {identity: (model, identity) for model, identity in opponents}.values()
    )
    _configure_inference(
        [network] + [model for model, _ in opponents], config.inference_engine
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
