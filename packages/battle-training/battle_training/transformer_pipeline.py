"""Full-party transformer + batched simultaneous-search training pipeline."""

from __future__ import annotations

import heapq
import json
import math
import multiprocessing
import random
import shutil
import tempfile
import time
from collections.abc import Callable, Iterable
from concurrent.futures import ProcessPoolExecutor
from dataclasses import asdict, dataclass, field, replace
from pathlib import Path
from typing import Any

import numpy as np
import torch
from torch import Tensor

from . import (
    ENTROPY,
    FULL_PARTY_SIZE,
    FULL_PROFILE,
    FULL_SCHEMA,
    generated_level100,
    generated_party_sizes,
    generated_schedule_names,
)
from .arena import (
    _MATCHUP_FILTER_VERSION,
    ArenaConfig,
    ArenaEvaluationPool,
    ArenaReportJob,
    ArenaTelemetry,
    _abs_value_summary,
    _choice_detail,
    _compact_inspection,
    _compact_turn_inspection,
    _party_strata,
    _setup_move_name,
    run_campaign_arena,
    run_paired_arena,
    run_traced_arena,
    skill_probe_report,
    write_arena_reports_parallel,
)
from .artifacts import build_manifest, sha256, verify_manifest, write_json, write_new
from .decision_quality import (
    DecisionQualityMetrics,
    classify_feature_decision,
)
from .joint_search import (
    JointSearchConfig,
    RootPriorNoise,
    SearchResult,
    SimultaneousTreeSearch,
)
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
from .rmplus_native import RUST_RMPLUS_BACKEND, native_available, native_metadata


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
    token_layout: str = "semantic-entity-v1"
    lr_schedule: str = "constant"
    lr_milestones: tuple[int, ...] = ()
    lr_decay_factor: float = 0.1
    joint_policy_heads: bool = True
    distilled_leaf_evaluator: bool = True
    leaf_hidden: int = 64
    leaf_hidden_layers: tuple[int, ...] | None = None
    leaf_loss_weight: float = 0.25
    leaf_ema_decay: float = 0.0
    collection_epsilon: float = 0.0
    collection_epsilon_turns: int = 0
    policy_target_smoothing: float = 0.0
    collection_dirichlet_alpha: float = 0.0
    collection_dirichlet_weight: float = 0.25
    collection_dirichlet_total: float = 0.0
    frontier_buffer_size: int = 256
    frontier_restart_fraction: float = 0.25
    frontier_reset_cap: int = 8
    frontier_episode_cap: int = 2
    split_half_reliability: bool = True
    prior_regret: bool = True
    policy_reliability_floor: float = 1.0
    matchup_value_cap: float = 0.9
    matchup_filter_attempts: int = 4
    matchup_lopsided_accept: float = 0.15
    team_replay_fraction: float = 0.15
    team_replay_buffer_size: int = 256
    popular_gate: int = 64
    opponent_checkpoints: tuple[str, ...] = ()
    opponent_fraction: float = 0.5
    model_opponent_share: float = 0.5
    historical_window: int = 4
    shadow_opponent_window: int = 0
    promotion_games: int = 2048
    promotion_seed_count: int = 8
    promotion_policy_games: int = 0
    probe_games: int = 256
    probe_seed_count: int = 8
    campaign_games: int = 288
    campaign_seed_count: int = 8
    minimum_promotion_score: float = 0.50
    promotion_nonfinish_policy: str = "losses"
    promotion_pooled_z: float = 0.0
    bootstrap_promotion: bool = False
    enforce_quality_gate: bool = True
    chance_samples_per_joint: int = 1
    regret_iterations: int = 2048
    inference_batch_size: int = 256
    max_actions_per_side: int = 13
    replay_window: int = 2
    search_every: int = 1
    tree_regret_iterations: int = 16
    actor_batch_size: int = 16
    actor_processes: int = 1
    eval_processes: int = 1
    precision: str = "bf16"
    inference_engine: str = "auto"
    warm_start_checkpoint: str | None = None
    warm_start_incumbent_checkpoint: str | None = None
    heuristic_opponents: bool = True
    value_loss_weight: float = 0.25
    redundant_action_prior_scale: float = 0.25
    prior_anchor_temperature: float = 0.02
    balanced_final_species: bool = True
    generated_schedule_version: int = 3
    rmplus_backend: str = RUST_RMPLUS_BACKEND
    cfr_plus_solves: bool = True


class _HeuristicNetwork:
    """Deterministic non-self-play policy with a neutral leaf value."""

    def __init__(self, style: str) -> None:
        self.style = style
        self.config = type(
            "HeuristicConfig",
            (),
            {
                "action_count": 13,
                "distilled_leaf_evaluator": True,
            },
        )()

    def __reduce__(self) -> tuple[Any, tuple[str]]:
        # Rebuild the dynamic config class instead of asking multiprocessing to
        # pickle it when final-report opponents cross a spawned-worker boundary.
        return self.__class__, (self.style,)

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

    @staticmethod
    def evaluate_leaf(features: list[tuple[int, ...]]) -> list[float]:
        return [0.0] * len(features)


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
    reset_seed: int
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
    exploration_rng: random.Random
    prior_noise_rng: random.Random
    initial: dict[str, Any] | None = None
    final: dict[str, Any] | None = None
    inspection: dict[str, Any] | None = None
    timeline: list[dict[str, Any]] = field(default_factory=list)
    frontier_snapshots: dict[int, Snapshot] = field(default_factory=dict)
    frontier_restart: dict[str, Any] | None = None
    team_replay: dict[str, Any] | None = None


def _pipeline_id(
    balanced_final_species: bool = True, generated_schedule_version: int = 3
) -> str:
    del balanced_final_species, generated_schedule_version
    return "transformer-variable-party-bf16-rmplus-v30-prior-regret-frontier-5m-16k"


def _serialized_network_config(config: TransformerConfig) -> dict[str, Any]:
    """Match the JSON representation persisted in run metadata."""
    return json.loads(json.dumps(asdict(config)))


def _configure_inference(models: Iterable[Any], engine: str) -> None:
    for model in models:
        if isinstance(model, BattleTransformer):
            model.configure_inference(engine)


def _scheduled_for_opponent(episode: int, fraction: float) -> bool:
    """Periodic deterministic mixture with an exact count for rational fractions."""
    return math.floor((episode + 1) * fraction) > math.floor(episode * fraction)


def _select_training_opponent(
    opponents: list[tuple[Any, str]], ordinal: int, model_share: float
) -> tuple[Any, str, int]:
    """Choose a model or heuristic opponent with an exact deterministic share.

    The returned ordinal is local to the selected population and drives the
    first-leg controller-side alternation independently for each population.
    """
    models = [row for row in opponents if not isinstance(row[0], _HeuristicNetwork)]
    heuristics = [row for row in opponents if isinstance(row[0], _HeuristicNetwork)]
    if not models or not heuristics:
        group = models or heuristics
        local_ordinal = ordinal
    elif _scheduled_for_opponent(ordinal, model_share):
        group = models
        local_ordinal = math.floor((ordinal + 1) * model_share) - 1
    else:
        group = heuristics
        selected_models = math.floor((ordinal + 1) * model_share)
        local_ordinal = ordinal - selected_models
    model, identity = group[local_ordinal % len(group)]
    return model, identity, local_ordinal


def _assemble_population(
    opponents: list[tuple[Any, str]],
    incumbent: tuple[Any, str],
    initial: tuple[Any, str],
    historical: list[tuple[Any, str]],
    shadow_pool: list[tuple[Any, str]],
    *,
    historical_window: int,
    shadow_window: int,
) -> list[tuple[Any, str]]:
    """Assemble the per-iteration opponent population, deduplicated by identity.

    With ``shadow_window`` zero this reproduces the legacy population exactly:
    fixed opponents, the incumbent, the initial anchor when it differs from the
    incumbent, and the accepted lineage. A positive ``shadow_window`` extends it
    with the most recent shadow-learner checkpoints regardless of acceptance;
    shadows of accepted iterations deduplicate against the lineage entries.
    """
    population = list(opponents) + [incumbent]
    if incumbent[1] != initial[1]:
        population.append(initial)
    if historical_window:
        population.extend(historical[:-1][-historical_window:])
    if shadow_window:
        population.extend(shadow_pool[-shadow_window:])
    return list(
        {identity: (model, identity) for model, identity in population}.values()
    )


def _append_shadow_opponent(
    shadow_pool: list[tuple[Any, str]], entry: tuple[Any, str], window: int
) -> None:
    if window <= 0:
        return
    shadow_pool.append(entry)
    while len(shadow_pool) > window:
        shadow_pool.pop(0)


def _shadow_seed_iterations(completed: int, window: int) -> list[int]:
    if window <= 0 or completed <= 0:
        return []
    return list(range(max(1, completed - window + 1), completed + 1))


_UINT64_MASK = (1 << 64) - 1
_ACTOR_ENTROPY_VERSION = "splitmix64-domain-separated-episode-v2"
_RESET_DOMAIN = 0x7265736574
_SELECTION_DOMAIN = 0x73656C656374
_CHANCE_DOMAIN = 0x6368616E6365
_OPPONENT_DOMAIN = 0x6F70706F6E656E74
_EXPLORATION_DOMAIN = 0x6578706C6F7265
_PRIOR_NOISE_DOMAIN = 0x7072696F72
_FRONTIER_PLAN_DOMAIN = 0x66726F6E74696572
_MATCHUP_DOMAIN = 0x6D61746368
_MATCHUP_ACCEPT_DOMAIN = 0x616363657074
_TEAM_REPLAY_PLAN_DOMAIN = 0x7465616D


def _splitmix64(value: int) -> int:
    z = (value + 0x9E3779B97F4A7C15) & _UINT64_MASK
    z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & _UINT64_MASK
    z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & _UINT64_MASK
    return (z ^ (z >> 31)) & _UINT64_MASK


def _training_entropy_seed(root: int, iteration: int, episode: int, domain: int) -> int:
    """Derive one replayable UInt64 seed from an explicit entropy coordinate."""
    state = _splitmix64((root & _UINT64_MASK) ^ _splitmix64(domain & _UINT64_MASK))
    state = _splitmix64(state ^ (iteration & _UINT64_MASK))
    return _splitmix64(state ^ (episode & _UINT64_MASK))


def _training_pair(episode: int) -> int:
    return episode // 2


def _training_pair_leg(episode: int) -> int:
    return episode % 2


def _training_party_index(iteration: int, episode: int) -> int:
    return _training_pair(episode) + (iteration - 1) * 13


def _training_party_sizes(
    iteration: int, episode: int, schedule_version: int = 3
) -> tuple[int, int]:
    """Give both legs the same teams while retaining the full size schedule."""
    return generated_party_sizes(
        _training_party_index(iteration, episode), schedule_version
    )


def _training_level100(iteration: int, episode: int, schedule_version: int = 3) -> bool:
    return generated_level100(
        _training_party_index(iteration, episode), schedule_version
    )


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
    reset_coordinates: set[tuple[object, object]] = set()
    for pair in range(expected_games // 2):
        first = by_episode[pair * 2]
        second = by_episode[pair * 2 + 1]
        if first.get("pair") != pair or second.get("pair") != pair:
            raise RuntimeError(f"collection pair {pair} has incorrect identity")
        if first.get("pair_leg") != 0 or second.get("pair_leg") != 1:
            raise RuntimeError(f"collection pair {pair} has incorrect leg order")
        shared = (
            "reset_seed",
            "reset_episode",
            "pair_player_party_size",
            "pair_enemy_party_size",
            "level_profile",
            "episode_kind",
            "opponent",
        )
        if any(first.get(name) != second.get(name) for name in shared):
            raise RuntimeError(f"collection pair {pair} does not share one reset")
        reset_coordinate = (first.get("reset_seed"), first.get("reset_episode"))
        if not first.get("frontier_restart"):
            if reset_coordinate in reset_coordinates:
                raise RuntimeError(
                    f"collection pair {pair} reused another pair's reset coordinate"
                )
            reset_coordinates.add(reset_coordinate)
        first_initial = first.get("initial") or {}
        second_initial = second.get("initial") or {}
        if bool(first.get("frontier_restart")) != bool(second.get("frontier_restart")):
            raise RuntimeError(f"collection pair {pair} split a frontier restart")
        if bool(first.get("team_replay")) != bool(second.get("team_replay")):
            raise RuntimeError(f"collection pair {pair} split a team replay")
        if first.get("frontier_restart"):
            if first.get("teams_swapped") != second.get("teams_swapped"):
                raise RuntimeError(f"frontier pair {pair} diverged in team orientation")
            if first.get("initial") != second.get("initial"):
                raise RuntimeError(f"frontier pair {pair} did not replay one state")
        elif first["episode_kind"] == "mirror":
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
    prior_noise: RootPriorNoise | None = None,
) -> SimultaneousTreeSearch:
    return SimultaneousTreeSearch(
        server,
        player,
        enemy,
        JointSearchConfig(
            chance_samples_per_joint=config.chance_samples_per_joint,
            max_depth=config.search_depth,
            regret_iterations=config.regret_iterations,
            inference_batch_size=config.inference_batch_size,
            max_actions_per_side=config.max_actions_per_side,
            regret_iterations_per_update=config.tree_regret_iterations,
            redundant_action_prior_scale=config.redundant_action_prior_scale,
            prior_anchor_temperature=config.prior_anchor_temperature,
            rmplus_backend=config.rmplus_backend,
            cfr_plus_solves=config.cfr_plus_solves,
            split_half_reliability=config.split_half_reliability,
            prior_regret=config.prior_regret,
        ),
        selection_rng,
        chance_rng,
        prior_noise,
    )


def _arena_config(
    config: TransformerPipelineConfig,
    games: int,
    seed: int,
    seed_count: int,
    *,
    replay_games: int = 0,
    policy_only: bool = False,
    matchup_filter: bool = False,
) -> ArenaConfig:
    return ArenaConfig(
        games=games,
        budget=config.episode_budget,
        chance_samples_per_joint=config.chance_samples_per_joint,
        search_depth=config.search_depth,
        regret_iterations=config.regret_iterations,
        inference_batch_size=config.inference_batch_size,
        max_actions_per_side=config.max_actions_per_side,
        tree_regret_iterations=config.tree_regret_iterations,
        redundant_action_prior_scale=config.redundant_action_prior_scale,
        prior_anchor_temperature=config.prior_anchor_temperature,
        seed=seed,
        replay_games=replay_games,
        seed_count=seed_count,
        balanced_final_species=config.balanced_final_species,
        generated_schedule_version=config.generated_schedule_version,
        rmplus_backend=config.rmplus_backend,
        cfr_plus_solves=config.cfr_plus_solves,
        policy_only=policy_only,
        matchup_value_cap=config.matchup_value_cap if matchup_filter else 0.0,
        matchup_filter_attempts=config.matchup_filter_attempts,
        popular_gate=config.popular_gate,
    )


def _evaluation_progress(
    root: Path,
    stage: str,
    iteration: int,
    label: str,
    **details: Any,
) -> Callable[[int, int], None]:
    def report(completed: int, total: int) -> None:
        write_monitor_state(
            root,
            stage,
            iteration=iteration,
            message=f"{label}: {completed:,} / {total:,}",
            completed=completed,
            games=total,
            **details,
        )

    return report


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


def _epsilon_active(epsilon: float, turns: int, decision: int) -> bool:
    if epsilon <= 0.0:
        return False
    return turns == 0 or decision < turns


def _uniform_legal_action(legal_mask: int, rng: random.Random) -> int:
    return rng.choice(
        [
            action
            for action in range(legal_mask.bit_length())
            if legal_mask & (1 << action)
        ]
    )


def _explore_search_result(
    result: SearchResult,
    actor: _ActorEpisode,
    config: TransformerPipelineConfig,
    decision: int,
) -> SearchResult:
    # Epsilon mixes only the EXECUTED action; policy and value targets keep
    # the pure solve mixture. Opponent sides never explore so checkpoint and
    # heuristic opponents stay unperturbed references.
    if not _epsilon_active(
        config.collection_epsilon, config.collection_epsilon_turns, decision
    ):
        return result
    epsilon = config.collection_epsilon
    rng = actor.exploration_rng
    player_action = result.player_action
    enemy_action = result.enemy_action
    if (actor.episode_kind == "mirror" or actor.candidate_player) and (
        rng.random() < epsilon
    ):
        player_action = _uniform_legal_action(actor.snapshot.player_mask, rng)
    if (actor.episode_kind == "mirror" or not actor.candidate_player) and (
        rng.random() < epsilon
    ):
        enemy_action = _uniform_legal_action(actor.snapshot.enemy_mask, rng)
    if (player_action, enemy_action) == (result.player_action, result.enemy_action):
        return result
    return replace(result, player_action=player_action, enemy_action=enemy_action)


def _epsilon_meta(config: TransformerPipelineConfig) -> dict[str, Any]:
    if not config.collection_epsilon:
        return {}
    return {
        "action_exploration": "epsilon-uniform-executed-v1",
        "collection_epsilon": config.collection_epsilon,
        "collection_epsilon_turns": config.collection_epsilon_turns,
    }


def _collection_prior_noise(
    config: TransformerPipelineConfig, rng: random.Random
) -> RootPriorNoise | None:
    # Alpha and total both zero disable the mixer entirely: legacy runs keep
    # pure priors and never touch the dedicated noise RNG stream.
    if (
        config.collection_dirichlet_alpha <= 0.0
        and config.collection_dirichlet_total <= 0.0
    ):
        return None
    return RootPriorNoise(
        alpha=config.collection_dirichlet_alpha,
        weight=config.collection_dirichlet_weight,
        rng=rng,
        total=config.collection_dirichlet_total,
    )


def _dirichlet_meta(config: TransformerPipelineConfig) -> dict[str, Any]:
    if not (config.collection_dirichlet_alpha or config.collection_dirichlet_total):
        return {}
    tag = (
        "dirichlet-legal-scaled-v2"
        if config.collection_dirichlet_total > 0.0
        else "dirichlet-legal-support-v1"
    )
    return {
        "root_prior_noise": tag,
        "collection_dirichlet_alpha": config.collection_dirichlet_alpha,
        "collection_dirichlet_weight": config.collection_dirichlet_weight,
        "collection_dirichlet_total": config.collection_dirichlet_total,
    }


def _smoothed_policy(
    policy: list[float], legal_mask: int, smoothing: float
) -> list[float]:
    # Mixes the solve policy with uniform mass over the LEGAL support only;
    # illegal actions keep exactly zero probability.
    if smoothing <= 0.0:
        return policy
    legal = [action for action in range(len(policy)) if legal_mask & (1 << action)]
    if not legal:
        return policy
    uniform = smoothing / len(legal)
    smoothed = [0.0] * len(policy)
    for action in legal:
        smoothed[action] = (1.0 - smoothing) * policy[action] + uniform
    return smoothed


_FRONTIER_VERSION = "prior-regret-capped-v2"
_FRONTIER_KL_FLOOR = 1e-9
_FRONTIER_COMPACT_SLACK = 16


def _policy_kl(policy: list[float], prior: list[float], legal_mask: int) -> float:
    """KL(solve policy ‖ network prior) over the legal support only."""
    total = 0.0
    for action, probability in enumerate(policy):
        if not legal_mask & (1 << action) or probability <= 0.0:
            continue
        floored = max(prior[action], _FRONTIER_KL_FLOOR)
        total += probability * math.log(probability / floored)
    return max(total, 0.0)


def _frontier_regret(row: dict[str, Any]) -> float | None:
    """This row's own prior regret, net of the split-half noise floor.

    Search publishes both sides' regret on every row, so the side the row was
    written for picks its own. Returns None when the solve did not measure it,
    which is what keeps the legacy KL score reachable.
    """
    if row.get("side") == "enemy":
        regret = row.get("root_enemy_prior_regret")
        noise = row.get("root_enemy_prior_regret_noise")
    else:
        regret = row.get("root_prior_regret")
        noise = row.get("root_prior_regret_noise")
    if regret is None:
        return None
    return max(0.0, float(regret) - float(noise or 0.0))


def _frontier_score(row: dict[str, Any], prior: list[float]) -> dict[str, float]:
    """How much revisiting this state is worth.

    Prior regret is the value the network prior gives up by playing itself
    against the solved opponent, so it is exactly the cost of not searching
    here. The KL it replaces measured the wrong thing: a root matrix estimated
    from a couple of chance worlds solves to a near-pure policy whose argmax is
    noise, and a well-calibrated hedged prior scores its *maximum* KL against
    those samples. That inversion is how a single unresolvable position came to
    own 253 of one iteration's 256 buffer entries.
    """
    value_surprise = abs(row["search_value"] - row["value"])
    regret = _frontier_regret(row)
    if regret is None:
        policy_kl = _policy_kl(row["policy"], prior, row["legal_mask"])
        return {
            "score": value_surprise + policy_kl,
            "value_surprise": value_surprise,
            "policy_kl": policy_kl,
        }
    return {
        "score": regret,
        "value_surprise": value_surprise,
        "prior_regret": regret,
    }


@dataclass(order=True)
class _FrontierItem:
    """One scored candidate, shared by the buffer's global and group heaps.

    Ordering is (score, order) only; `order` is unique, so a comparison never
    reaches the unorderable entry dict. Retiring an item flips `live` in every
    heap holding it at once, which is what lets a group cap evict an entry the
    global heap already accepted.
    """

    score: float
    order: int
    entry: dict[str, Any] = field(compare=False)
    keys: tuple[Any, ...] = field(compare=False, default=())
    live: bool = field(compare=False, default=True)


class _FrontierBuffer:
    """Bounded top-N buffer over scored entries; earlier entries win ties.

    The optional caps bound how many entries any one originating reset or any
    one episode may hold. Without them a position search cannot resolve takes
    the whole buffer, and the restart fraction then aims a quarter of the next
    iteration's episodes at that single battle.
    """

    def __init__(self, capacity: int, reset_cap: int = 0, episode_cap: int = 0) -> None:
        self.capacity = max(capacity, 0)
        self.reset_cap = max(reset_cap, 0)
        self.episode_cap = max(episode_cap, 0)
        self._heap: list[_FrontierItem] = []
        self._groups: dict[Any, list[_FrontierItem]] = {}
        self._counts: dict[Any, int] = {}
        self._live = 0
        self._counter = 0

    def _caps(self, entry: dict[str, Any]) -> list[tuple[Any, int]]:
        caps: list[tuple[Any, int]] = []
        if self.reset_cap:
            reset = entry.get("reset")
            # The reset recipe is a flat dict of scalars; a frontier restart
            # carries the recipe it branched from, so every replay of one
            # battle lands in the same group as the battle itself.
            key = tuple(sorted(reset.items())) if isinstance(reset, dict) else reset
            caps.append((("reset", key), self.reset_cap))
        if self.episode_cap:
            caps.append((("episode", entry.get("episode")), self.episode_cap))
        return caps

    @staticmethod
    def _weakest(heap: list[_FrontierItem]) -> _FrontierItem:
        while not heap[0].live:
            heapq.heappop(heap)
        return heap[0]

    def _retire(self, item: _FrontierItem) -> None:
        item.live = False
        self._live -= 1
        for key in item.keys:
            self._counts[key] -= 1

    def consider(self, entry: dict[str, Any]) -> None:
        if not self.capacity:
            return
        caps = self._caps(entry)
        item = _FrontierItem(
            entry["score"], -self._counter, entry, tuple(key for key, _ in caps)
        )
        self._counter += 1
        for key, cap in caps:
            if self._counts.get(key, 0) >= cap and item <= self._weakest(
                self._groups[key]
            ):
                return
        if self._live >= self.capacity and item <= self._weakest(self._heap):
            return
        for key, cap in caps:
            # An earlier cap may have retired an item this group also held, so
            # the count is re-read rather than reused from the check above.
            if self._counts.get(key, 0) >= cap:
                self._retire(self._weakest(self._groups[key]))
            heapq.heappush(self._groups.setdefault(key, []), item)
            self._counts[key] = self._counts.get(key, 0) + 1
        heapq.heappush(self._heap, item)
        self._live += 1
        if self._live > self.capacity:
            self._retire(self._weakest(self._heap))
        self._compact()

    def _compact(self) -> None:
        # Retired items stay buried until they surface, and a group whose
        # entries all died would otherwise keep its key forever. Rebuilding
        # once the dead outnumber the live keeps both bounded by capacity
        # rather than by the number of decisions considered.
        if len(self._heap) <= 2 * self.capacity + _FRONTIER_COMPACT_SLACK:
            return
        self._heap = [item for item in self._heap if item.live]
        heapq.heapify(self._heap)
        groups: dict[Any, list[_FrontierItem]] = {}
        for item in self._heap:
            for key in item.keys:
                groups.setdefault(key, []).append(item)
        for group in groups.values():
            heapq.heapify(group)
        self._groups = groups
        self._counts = {key: len(group) for key, group in groups.items()}

    def entries(self) -> list[dict[str, Any]]:
        ranked = sorted((item for item in self._heap if item.live), reverse=True)
        return [item.entry for item in ranked]


def _serialized_snapshot(snapshot: Snapshot) -> dict[str, Any]:
    # The native handle is session-local; frontier consumers re-derive a live
    # handle by replaying the reset recipe, so it is dropped here.
    return {
        "player_features": snapshot.player_features.tolist(),
        "enemy_features": snapshot.enemy_features.tolist(),
        "player_mask": snapshot.player_mask,
        "enemy_mask": snapshot.enemy_mask,
        "player_hash": snapshot.player_hash,
        "enemy_hash": snapshot.enemy_hash,
        "turn": snapshot.turn,
        "terminal": snapshot.terminal,
        "done": snapshot.done,
        "terminal_return": snapshot.terminal_return,
        "request": snapshot.request,
        "divergence": snapshot.divergence,
    }


def _snapshot_from_serialized(data: dict[str, Any]) -> Snapshot:
    player_features = np.asarray(data["player_features"], dtype=np.int64)
    enemy_features = np.asarray(data["enemy_features"], dtype=np.int64)
    player_features.flags.writeable = False
    enemy_features.flags.writeable = False
    return Snapshot(
        handle=-1,
        player_features=player_features,
        enemy_features=enemy_features,
        player_mask=data["player_mask"],
        enemy_mask=data["enemy_mask"],
        player_hash=data["player_hash"],
        enemy_hash=data["enemy_hash"],
        turn=data["turn"],
        terminal=data["terminal"],
        done=data["done"],
        terminal_return=data["terminal_return"],
        request=data["request"],
        divergence=data["divergence"],
    )


def _frontier_entry(
    config: TransformerPipelineConfig,
    iteration: int,
    actor: _ActorEpisode,
    row: dict[str, Any],
    components: dict[str, float],
    snapshot: Snapshot,
) -> dict[str, Any]:
    return {
        "type": "frontier",
        "iteration": iteration,
        "episode": actor.episode,
        "pair": actor.pair,
        "pair_leg": actor.pair_leg,
        "episode_kind": actor.episode_kind,
        "side": row["side"],
        "decision": row["decision"],
        "target_kind": row["target_kind"],
        "search_value": row["search_value"],
        "value": row["value"],
        **components,
        "reset": (
            dict(actor.frontier_restart["reset"])
            if actor.frontier_restart
            else {
                "seed": actor.reset_seed,
                "episode": actor.reset_episode,
                "player_size": actor.pair_player_size,
                "enemy_size": actor.pair_enemy_size,
                "level100": actor.level100,
                "swapped": actor.teams_swapped,
                "balanced_final_species": config.balanced_final_species,
            }
        ),
        "actions": [
            *(actor.frontier_restart["actions"] if actor.frontier_restart else []),
            *(
                [turn["player_action"], turn["enemy_action"]]
                for turn in actor.timeline[: row["decision"]]
            ),
        ],
        "snapshot": _serialized_snapshot(snapshot),
    }


def _merged_frontier(
    entry_lists: list[list[dict[str, Any]]],
    capacity: int,
    reset_cap: int = 0,
    episode_cap: int = 0,
) -> list[dict[str, Any]]:
    # Each worker capped only its own slice, so the caps are re-applied here:
    # a battle split across two workers would otherwise pass both.
    merged = _FrontierBuffer(capacity, reset_cap, episode_cap)
    for entries in entry_lists:
        for entry in entries:
            merged.consider(entry)
    return merged.entries()


def _frontier_meta(config: TransformerPipelineConfig) -> dict[str, Any]:
    if not config.frontier_buffer_size:
        return {}
    meta = {
        "frontier_buffer": _FRONTIER_VERSION,
        "frontier_buffer_size": config.frontier_buffer_size,
    }
    if config.frontier_reset_cap:
        meta["frontier_reset_cap"] = config.frontier_reset_cap
    if config.frontier_episode_cap:
        meta["frontier_episode_cap"] = config.frontier_episode_cap
    return meta


def _finalize_frontier(
    metrics: dict[str, Any],
    path: Path,
    iteration: int,
    config: TransformerPipelineConfig,
) -> dict[str, Any]:
    if "frontier" not in metrics:
        return metrics
    entries = metrics.pop("frontier")
    frontier_path = path.with_name(f"frontier-{iteration:03d}.jsonl")
    header = {
        "type": "frontier-meta",
        "version": _FRONTIER_VERSION,
        "iteration": iteration,
        "capacity": config.frontier_buffer_size,
        "entries": len(entries),
        "score": (
            "prior-regret-minus-split-half-noise"
            if getattr(config, "prior_regret", False)
            else "value-surprise-plus-policy-kl"
        ),
    }
    _jsonl(frontier_path, [header, *entries])
    scores = [entry["score"] for entry in entries]
    metrics["frontier"] = {
        "version": _FRONTIER_VERSION,
        "capacity": config.frontier_buffer_size,
        "entries": len(entries),
        "path": frontier_path.name,
        "max_score": max(scores) if scores else None,
        "min_score": min(scores) if scores else None,
    }
    return metrics


def _load_frontier_buffer(path: Path) -> list[dict[str, Any]]:
    with path.open() as handle:
        rows = [json.loads(line) for line in handle if line.strip()]
    if not rows or rows[0].get("type") != "frontier-meta":
        raise ValueError(f"missing frontier-meta header in {path}")
    if rows[0].get("version") != _FRONTIER_VERSION:
        raise ValueError(f"unsupported frontier buffer version in {path}")
    return rows[1:]


_FRONTIER_RESTART_VERSION = "prior-iteration-replay-v1"


def _frontier_restart_entries(source: str | None) -> list[dict[str, Any]]:
    if source is None:
        return []
    path = Path(source)
    if not path.exists():
        return []
    return _load_frontier_buffer(path)


def _frontier_restart_plan(
    config: TransformerPipelineConfig, iteration: int, entry_count: int
) -> dict[int, int]:
    fraction = config.frontier_restart_fraction
    if fraction <= 0.0 or entry_count <= 0:
        return {}
    pairs = config.selfplay_episodes // 2
    count = min(int(fraction * config.selfplay_episodes) // 2, pairs)
    if count <= 0:
        return {}
    rng = random.Random(
        _training_entropy_seed(config.seed, iteration, 0, _FRONTIER_PLAN_DOMAIN)
    )
    selected = sorted(rng.sample(range(pairs), count))
    return {pair: rng.randrange(entry_count) for pair in selected}


def _replay_frontier_entry(
    server: SearchServer, snapshot: Snapshot, entry: dict[str, Any]
) -> Snapshot:
    for player_action, enemy_action in entry["actions"]:
        snapshot = server.episode_step(snapshot.handle, player_action, enemy_action)
    recorded = entry["snapshot"]
    if (
        snapshot.player_hash != recorded["player_hash"]
        or snapshot.enemy_hash != recorded["enemy_hash"]
    ):
        raise RuntimeError("frontier replay diverged from the recorded snapshot")
    return snapshot


def _frontier_restart_meta(config: TransformerPipelineConfig) -> dict[str, Any]:
    if not config.frontier_restart_fraction:
        return {}
    return {
        "frontier_restarts": _FRONTIER_RESTART_VERSION,
        "frontier_restart_fraction": config.frontier_restart_fraction,
    }


_TEAM_REPLAY_VERSION = "hard-team-replay-v1"


def _scheduled_size_mix_enforced(config: TransformerPipelineConfig) -> bool:
    """Recipe-driven resets replace scheduled size combos, skewing the mix."""
    return not (config.frontier_restart_fraction or config.team_replay_fraction)


def _hard_team_score(
    first: dict[str, Any], second: dict[str, Any], episode_budget: int
) -> dict[str, Any] | None:
    """Score one mirror pair's team matchup by how contested it stayed.

    Sweeps (the same team wins both orientations) score below any contested
    pair; within each class longer battles score higher, so truncated pairs
    that exhaust the budget without a verdict rank as the hardest matchups.
    Opponent pairs, frontier restarts, and semantic divergences are not
    comparable team evidence and yield no score.
    """
    if first.get("episode_kind") != "mirror" or second.get("episode_kind") != "mirror":
        return None
    if first.get("frontier_restart") or second.get("frontier_restart"):
        return None
    if any(leg["stop"] not in ("finished", "truncated") for leg in (first, second)):
        return None
    team_returns = [
        first["return"],
        -second["return"] if second["return"] is not None else None,
    ]
    contested = not (team_returns[0] == team_returns[1] and team_returns[0] in (1, -1))
    length = (first["decisions"] + second["decisions"]) / (2 * episode_budget)
    return {
        "score": (1.0 if contested else 0.0) + length,
        "contested": contested,
        "team_returns": team_returns,
        "decisions": [first["decisions"], second["decisions"]],
    }


def _hard_team_candidates(
    episode_records: list[dict[str, Any]],
    config: TransformerPipelineConfig,
    iteration: int,
) -> dict[str, Any]:
    """Fingerprint every scorable pair's reset recipe, hardest first."""
    legs: dict[int, dict[int, dict[str, Any]]] = {}
    for record in episode_records:
        legs.setdefault(int(record["pair"]), {})[int(record["pair_leg"])] = record
    entries: list[dict[str, Any]] = []
    for pair, sides in sorted(legs.items()):
        first, second = sides.get(0), sides.get(1)
        if first is None or second is None:
            continue
        scored = _hard_team_score(first, second, config.episode_budget)
        if scored is None:
            continue
        entries.append(
            {
                "type": "hard-team",
                "iteration": iteration,
                "pair": pair,
                **scored,
                "replayed": bool(first.get("team_replay")),
                "reset": {
                    "seed": first["reset_seed"],
                    "episode": first["reset_episode"],
                    "player_size": first["pair_player_party_size"],
                    "enemy_size": first["pair_enemy_party_size"],
                    "level100": first["level_profile"] == "level100",
                    "balanced_final_species": (
                        first["species_profile"] == "balanced-final-u16-v1"
                    ),
                },
            }
        )
    entries.sort(key=lambda entry: -entry["score"])
    return {
        "entries": entries,
        "replayed_pairs": sum(entry["replayed"] for entry in entries),
    }


def _merge_hard_teams(
    fresh: list[dict[str, Any]],
    previous: list[dict[str, Any]],
    capacity: int,
) -> list[dict[str, Any]]:
    """Keep the hardest recipes; a replayed matchup's fresh score supersedes.

    Deduplication runs on the full reset recipe, so a hard team that the
    candidate has since learned to beat re-enters with its new low score and
    falls out of the buffer instead of looping forever.
    """

    def fingerprint(entry: dict[str, Any]) -> tuple[tuple[str, Any], ...]:
        return tuple(sorted(entry["reset"].items()))

    merged = {fingerprint(entry): entry for entry in previous}
    merged.update((fingerprint(entry), entry) for entry in fresh)
    ranked = sorted(
        merged.values(),
        key=lambda entry: (-entry["score"], -entry["iteration"], entry["pair"]),
    )
    return ranked[:capacity]


def _team_replay_meta(config: TransformerPipelineConfig) -> dict[str, Any]:
    if not config.team_replay_fraction or not config.team_replay_buffer_size:
        return {}
    return {
        "team_replay": _TEAM_REPLAY_VERSION,
        "team_replay_fraction": config.team_replay_fraction,
        "team_replay_buffer_size": config.team_replay_buffer_size,
    }


def _finalize_hard_teams(
    metrics: dict[str, Any],
    path: Path,
    iteration: int,
    config: TransformerPipelineConfig,
) -> dict[str, Any]:
    candidates = metrics.pop("hard_team_candidates", None)
    if not config.team_replay_fraction or not config.team_replay_buffer_size:
        return metrics
    fresh = candidates["entries"] if candidates else []
    previous = _team_replay_entries(
        str(path.with_name(f"hard-teams-{iteration - 1:03d}.jsonl"))
    )
    entries = _merge_hard_teams(fresh, previous, config.team_replay_buffer_size)
    buffer_path = path.with_name(f"hard-teams-{iteration:03d}.jsonl")
    header = {
        "type": "hard-team-meta",
        "version": _TEAM_REPLAY_VERSION,
        "iteration": iteration,
        "capacity": config.team_replay_buffer_size,
        "entries": len(entries),
        "score": "contested-outcome+length",
    }
    _jsonl(buffer_path, [header, *entries])
    scores = [entry["score"] for entry in entries]
    fresh_entries = sum(entry["iteration"] == iteration for entry in entries)
    metrics["team_replay"] = {
        "version": _TEAM_REPLAY_VERSION,
        "fraction": config.team_replay_fraction,
        "capacity": config.team_replay_buffer_size,
        "entries": len(entries),
        "path": buffer_path.name,
        "scored_pairs": len(fresh),
        "contested_pairs": sum(entry["contested"] for entry in fresh),
        "replayed_pairs": candidates["replayed_pairs"] if candidates else 0,
        "fresh_entries": fresh_entries,
        "carried_entries": len(entries) - fresh_entries,
        "max_score": max(scores) if scores else None,
        "min_score": min(scores) if scores else None,
    }
    return metrics


def _load_hard_team_buffer(path: Path) -> list[dict[str, Any]]:
    with path.open() as handle:
        rows = [json.loads(line) for line in handle if line.strip()]
    if not rows or rows[0].get("type") != "hard-team-meta":
        raise ValueError(f"missing hard-team-meta header in {path}")
    if rows[0].get("version") != _TEAM_REPLAY_VERSION:
        raise ValueError(f"unsupported hard-team buffer version in {path}")
    return rows[1:]


def _team_replay_entries(source: str | None) -> list[dict[str, Any]]:
    if source is None:
        return []
    path = Path(source)
    if not path.exists():
        return []
    return _load_hard_team_buffer(path)


def _team_replay_plan(
    config: TransformerPipelineConfig,
    iteration: int,
    entry_count: int,
    exclude: Iterable[int] = (),
) -> dict[int, int]:
    """Assign buffered hard-team recipes to fresh turn-zero pairs.

    Unlike frontier restarts this replays no actions: the recipe only pins the
    teams, and the pair fights from turn zero in both orientations so the
    matchup gets re-scored. Entries are drawn without replacement to keep the
    replayed slice of the curriculum diverse.
    """
    fraction = config.team_replay_fraction
    if fraction <= 0.0 or entry_count <= 0:
        return {}
    pairs = config.selfplay_episodes // 2
    excluded = set(exclude)
    candidates = [pair for pair in range(pairs) if pair not in excluded]
    count = min(
        int(fraction * config.selfplay_episodes) // 2, len(candidates), entry_count
    )
    if count <= 0:
        return {}
    rng = random.Random(
        _training_entropy_seed(config.seed, iteration, 0, _TEAM_REPLAY_PLAN_DOMAIN)
    )
    selected = sorted(rng.sample(candidates, count))
    indices = rng.sample(range(entry_count), count)
    return dict(zip(selected, indices, strict=True))


def _matchup_attempt_seed(root_seed: int, iteration: int, attempt: int) -> int:
    """Attempt 0 replays the legacy reset stream; retries get their own domain."""
    if attempt <= 0:
        return _training_entropy_seed(root_seed, iteration, 0, _RESET_DOMAIN)
    return _training_entropy_seed(root_seed, iteration, attempt, _MATCHUP_DOMAIN)


def _pair_reset_seed(
    config: TransformerPipelineConfig,
    iteration: int,
    matchup_plan: dict[int, int] | None,
    pair: int,
) -> int:
    return _matchup_attempt_seed(
        config.seed, iteration, (matchup_plan or {}).get(pair, 0)
    )


def _matchup_filter_meta(config: TransformerPipelineConfig) -> dict[str, Any]:
    if not config.matchup_value_cap:
        return {}
    return {
        "matchup_filter": _MATCHUP_FILTER_VERSION,
        "matchup_value_cap": config.matchup_value_cap,
        "matchup_filter_attempts": config.matchup_filter_attempts,
        "matchup_lopsided_accept": config.matchup_lopsided_accept,
    }


def _matchup_filter_plan(
    server: SearchServer,
    network: Any,
    config: TransformerPipelineConfig,
    iteration: int,
    *,
    exclude: Iterable[int] = (),
    chunk_size: int = 512,
) -> tuple[dict[int, int], dict[str, Any]]:
    """Choose per-pair reset attempts whose predicted turn-zero value is contested.

    Selection happens on the incumbent network's pre-game state value, never on
    realized outcomes, so retained training targets stay conditionally
    unbiased. Rejected pairs resample teams while holding the scheduled size
    combo fixed; a calibration coin keeps a share of lopsided pairs so the
    value head never loses its extreme anchors.
    """
    started = time.perf_counter()
    cap = config.matchup_value_cap
    total_pairs = config.selfplay_episodes // 2
    excluded = {pair for pair in exclude if 0 <= pair < total_pairs}
    probed = [pair for pair in range(total_pairs) if pair not in excluded]
    coins = {
        pair: random.Random(
            _training_entropy_seed(config.seed, iteration, pair, _MATCHUP_ACCEPT_DOMAIN)
        )
        for pair in probed
    }
    accepted_attempt: dict[int, int] = {}
    accepted_value: dict[int, float] = {}
    initial_values: dict[int, float] = {}
    soft_accepted = 0
    fallback = 0
    candidate_resets = 0
    pending = list(probed)
    for attempt in range(config.matchup_filter_attempts):
        if not pending:
            break
        last_attempt = attempt == config.matchup_filter_attempts - 1
        seed = _matchup_attempt_seed(config.seed, iteration, attempt)
        survivors: list[int] = []
        for start in range(0, len(pending), chunk_size):
            chunk = pending[start : start + chunk_size]
            features = []
            masks = []
            for offset, pair in enumerate(chunk):
                player_size, enemy_size = _training_party_sizes(
                    iteration, 2 * pair, config.generated_schedule_version
                )
                reset = server.reset if offset == 0 else server.reset_append
                snapshot = reset(
                    seed,
                    pair,
                    player_size,
                    enemy_size,
                    level100=_training_level100(
                        iteration, 2 * pair, config.generated_schedule_version
                    ),
                    swapped=False,
                    balanced_final_species=config.balanced_final_species,
                )
                candidate_resets += 1
                features.append(snapshot.player_features)
                masks.append(snapshot.player_mask)
            _, values = network.evaluate(features, masks)
            for pair, value in zip(chunk, values, strict=True):
                magnitude = abs(float(value))
                if attempt == 0:
                    initial_values[pair] = magnitude
                if magnitude <= cap:
                    accepted_attempt[pair] = attempt
                    accepted_value[pair] = magnitude
                elif coins[pair].random() < config.matchup_lopsided_accept:
                    soft_accepted += 1
                    accepted_attempt[pair] = attempt
                    accepted_value[pair] = magnitude
                elif last_attempt:
                    fallback += 1
                    accepted_attempt[pair] = attempt
                    accepted_value[pair] = magnitude
                else:
                    survivors.append(pair)
        pending = survivors
    plan = {pair: attempt for pair, attempt in accepted_attempt.items() if attempt > 0}
    histogram: dict[str, int] = {}
    for attempt in accepted_attempt.values():
        histogram[str(attempt)] = histogram.get(str(attempt), 0) + 1
    strata: dict[str, dict[str, int]] = {}
    for pair in probed:
        for stratum in _party_strata(
            *_training_party_sizes(
                iteration, 2 * pair, config.generated_schedule_version
            )
        ):
            bucket = strata.setdefault(stratum, {"pairs": 0, "resampled": 0})
            bucket["pairs"] += 1
            bucket["resampled"] += int(pair in plan)
    stats = {
        "enabled": True,
        "cap": cap,
        "attempts": config.matchup_filter_attempts,
        "lopsided_accept": config.matchup_lopsided_accept,
        "pairs": total_pairs,
        "excluded_pairs": len(excluded),
        "resampled_pairs": len(plan),
        "soft_accepted_pairs": soft_accepted,
        "fallback_pairs": fallback,
        "candidate_resets": candidate_resets,
        "attempt_histogram": histogram,
        "turn_zero_abs_value": {
            "initial": _abs_value_summary(
                [initial_values[pair] for pair in probed], cap
            ),
            "final": _abs_value_summary([accepted_value[pair] for pair in probed], cap),
        },
        "strata": strata,
        "seconds": round(time.perf_counter() - started, 3),
    }
    return plan, stats


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


def _frontier_priors(
    network: Any, rows: list[dict[str, Any]], batch_size: int
) -> list[list[float]]:
    """Score completed-episode rows without exceeding the inference contract."""
    if batch_size <= 0:
        raise ValueError("frontier inference batch size must be positive")
    priors: list[list[float]] = []
    for start in range(0, len(rows), batch_size):
        batch = rows[start : start + batch_size]
        batch_priors, _ = network.evaluate(
            [row["features"] for row in batch],
            [row["legal_mask"] for row in batch],
        )
        priors.extend(batch_priors)
    return priors


def _collect_rows_single(
    path: Path,
    network: BattleTransformer,
    config: TransformerPipelineConfig,
    iteration: int,
    opponents: list[tuple[Any, str]] | None = None,
    episode_indices: list[int] | None = None,
    progress_path: Path | None = None,
    process: int = 0,
    frontier_source: str | None = None,
    matchup_plan: dict[int, int] | None = None,
    team_source: str | None = None,
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
        "format": "variable-party-joint-regret-policy-value-jsonl-v4",
        "profile": FULL_PROFILE,
        "schema": FULL_SCHEMA,
        "entropy": ENTROPY,
        "actor_entropy": _ACTOR_ENTROPY_VERSION,
        "chance": "fresh-root-v1",
        "solver": "simultaneous-tree-anchored-qre-v8",
        "rmplus_backend": config.rmplus_backend,
        "cfr_plus_solves": config.cfr_plus_solves,
        "action_selector": ("simultaneous-tree-anchored-qre-every-decision-v8"),
        "iteration": iteration,
        "episodes": len(episode_indices),
        "depth": config.search_depth,
        "seed": config.seed,
        "max_party_size": FULL_PARTY_SIZE,
        "party_size_schedule": generated_schedule_names(
            config.generated_schedule_version
        )[0],
        "level_schedule": generated_schedule_names(config.generated_schedule_version)[
            1
        ],
        "species_schedule": (
            "near-uniform-final-species-u16-v1"
            if config.balanced_final_species
            else "progression-weighted-final-species-v1"
        ),
        "chance_samples_per_joint": config.chance_samples_per_joint,
        "regret_iterations": config.regret_iterations,
        "inference_batch_size": config.inference_batch_size,
        "max_actions_per_side": config.max_actions_per_side,
        "search_every": config.search_every,
        "tree_regret_iterations": config.tree_regret_iterations,
        "redundant_action_prior_scale": config.redundant_action_prior_scale,
        "prior_anchor_temperature": config.prior_anchor_temperature,
        "redundant_action_prior": "non-excluding-static-context-v1",
        "decision_quality_version": "static-active-context-v1",
        "actor_batch_size": config.actor_batch_size,
        "actor_processes": config.actor_processes,
        "pairing": "same-reset-opposite-controller-sides-v1",
        "pairs": config.selfplay_episodes // 2,
        **_epsilon_meta(config),
        **_dirichlet_meta(config),
        **_frontier_meta(config),
        **_frontier_restart_meta(config),
        **_matchup_filter_meta(config),
        **_team_replay_meta(config),
    }
    opponents = opponents or []
    if opponents:
        meta["opponents"] = {
            "kind": "checkpoint-and-heuristic-stratified-round-robin",
            "identities": [identity for _, identity in opponents],
            "fraction": config.opponent_fraction,
            "model_share_within_opponent_pairs": config.model_opponent_share,
            "schedule": "balanced-model-heuristic-round-robin-v2",
        }
    rows: list[dict[str, Any]] = [meta]
    smoothing = config.policy_target_smoothing
    finished = truncated = semantic_divergences = examples = transitions = 0
    mirror_episodes = opponent_episodes = 0
    model_opponent_episodes = heuristic_opponent_episodes = 0
    candidate_player_episodes = candidate_enemy_episodes = 0
    popular_player_episodes = popular_enemy_episodes = 0
    opponent_counts = {identity: 0 for _, identity in opponents}
    party_size_counts = {
        f"{player}v{enemy}": 0
        for player in range(1, FULL_PARTY_SIZE + 1)
        for enemy in range(1, FULL_PARTY_SIZE + 1)
    }
    player_wins = enemy_wins = draws = 0
    candidate_wins = candidate_losses = candidate_draws = 0
    scheduled_level100_six_vs_six = 0
    total_decisions = ordinary_actions = voluntary_switches = setup_uses = 0
    setup_move_counts: dict[str, int] = {}
    species_counts: dict[str, int] = {}
    decision_quality = DecisionQualityMetrics()
    recent_battles: list[dict[str, Any]] = []
    frontier = _FrontierBuffer(
        config.frontier_buffer_size,
        config.frontier_reset_cap,
        config.frontier_episode_cap,
    )
    restart_entries = _frontier_restart_entries(frontier_source)
    restart_plan = _frontier_restart_plan(config, iteration, len(restart_entries))
    frontier_restart_episodes = 0
    replay_entries = _team_replay_entries(team_source)
    replay_plan = _team_replay_plan(
        config, iteration, len(replay_entries), exclude=restart_plan
    )
    team_replay_episodes = 0

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
            "reset_seed": actor.reset_seed,
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
            "species_profile": (
                "balanced-final-u16-v1"
                if config.balanced_final_species
                else "progression-weighted-v1"
            ),
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
        if actor.frontier_restart is not None:
            record["frontier_restart"] = True
            record["frontier_source"] = {
                "iteration": actor.frontier_restart["iteration"],
                "episode": actor.frontier_restart["episode"],
                "decision": actor.frontier_restart["decision"],
                "score": actor.frontier_restart["score"],
            }
        if actor.team_replay is not None:
            record["team_replay"] = True
            record["team_replay_source"] = {
                "iteration": actor.team_replay["iteration"],
                "pair": actor.team_replay["pair"],
                "score": actor.team_replay["score"],
            }
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

    with SearchServer(popular_gate=config.popular_gate) as server:
        for batch_start in range(0, len(episode_indices), config.actor_batch_size):
            batch = episode_indices[batch_start : batch_start + config.actor_batch_size]
            active: list[_ActorEpisode] = []
            for offset, episode in enumerate(batch):
                pair = _training_pair(episode)
                pair_leg = _training_pair_leg(episode)
                reset_episode = pair
                restart_entry = (
                    restart_entries[restart_plan[pair]]
                    if pair in restart_plan
                    else None
                )
                replay_entry = (
                    replay_entries[replay_plan[pair]] if pair in replay_plan else None
                )
                versus_opponent = (
                    restart_entry is None
                    and replay_entry is None
                    and bool(opponents)
                    and _scheduled_for_opponent(pair, config.opponent_fraction)
                )
                opponent_identity: str | None = None
                if versus_opponent:
                    opponent_ordinal = math.floor(pair * config.opponent_fraction)
                    opponent, opponent_identity, local_ordinal = (
                        _select_training_opponent(
                            opponents, opponent_ordinal, config.model_opponent_share
                        )
                    )
                    population_size = sum(
                        isinstance(candidate, _HeuristicNetwork)
                        == isinstance(opponent, _HeuristicNetwork)
                        for candidate, _ in opponents
                    )
                    opponent_round = local_ordinal // population_size
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
                    if isinstance(opponent, _HeuristicNetwork):
                        heuristic_opponent_episodes += 1
                    else:
                        model_opponent_episodes += 1
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
                reset_seed = _pair_reset_seed(config, iteration, matchup_plan, pair)
                pair_player_size, pair_enemy_size = _training_party_sizes(
                    iteration, episode, config.generated_schedule_version
                )
                level100 = _training_level100(
                    iteration, episode, config.generated_schedule_version
                )
                teams_swapped = episode_kind == "mirror" and pair_leg == 1
                balanced_final_species = config.balanced_final_species
                if restart_entry is not None:
                    recipe = restart_entry["reset"]
                    reset_seed = recipe["seed"]
                    reset_episode = recipe["episode"]
                    pair_player_size = recipe["player_size"]
                    pair_enemy_size = recipe["enemy_size"]
                    level100 = recipe["level100"]
                    teams_swapped = recipe["swapped"]
                    balanced_final_species = recipe["balanced_final_species"]
                if replay_entry is not None:
                    # Pin the recorded teams but fight from turn zero, leaving
                    # teams_swapped to leg parity so both orientations rescore.
                    recipe = replay_entry["reset"]
                    reset_seed = recipe["seed"]
                    reset_episode = recipe["episode"]
                    pair_player_size = recipe["player_size"]
                    pair_enemy_size = recipe["enemy_size"]
                    level100 = recipe["level100"]
                    balanced_final_species = recipe["balanced_final_species"]
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
                        balanced_final_species=balanced_final_species,
                    )
                    if offset == 0
                    else server.reset_append(
                        reset_seed,
                        reset_episode,
                        pair_player_size,
                        pair_enemy_size,
                        level100=level100,
                        swapped=teams_swapped,
                        balanced_final_species=balanced_final_species,
                    )
                )
                popular_player_episodes += int(snapshot.player_popular)
                popular_enemy_episodes += int(snapshot.enemy_popular)
                active.append(
                    _ActorEpisode(
                        episode=episode,
                        pair=pair,
                        pair_leg=pair_leg,
                        reset_seed=reset_seed,
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
                            _training_entropy_seed(
                                config.seed, iteration, episode, _SELECTION_DOMAIN
                            )
                        ),
                        chance_rng=random.Random(
                            _training_entropy_seed(
                                config.seed, iteration, episode, _CHANCE_DOMAIN
                            )
                        ),
                        opponent_rng=random.Random(
                            _training_entropy_seed(
                                config.seed, iteration, episode, _OPPONENT_DOMAIN
                            )
                        ),
                        exploration_rng=random.Random(
                            _training_entropy_seed(
                                config.seed, iteration, episode, _EXPLORATION_DOMAIN
                            )
                        ),
                        prior_noise_rng=random.Random(
                            _training_entropy_seed(
                                config.seed, iteration, episode, _PRIOR_NOISE_DOMAIN
                            )
                        ),
                        frontier_restart=restart_entry,
                        team_replay=replay_entry,
                    )
                )
            for actor in active:
                if actor.frontier_restart is not None:
                    actor.snapshot = _replay_frontier_entry(
                        server, actor.snapshot, actor.frontier_restart
                    )
                    frontier_restart_episodes += 1
                if actor.team_replay is not None:
                    team_replay_episodes += 1
            inspections = server.inspect_many(
                [actor.snapshot.handle for actor in active]
            )
            for actor, inspection in zip(active, inspections, strict=True):
                actor.inspection = inspection
                actor.initial = _compact_inspection(inspection)
                if actor.pair_leg == 0 and actor.frontier_restart is None:
                    for side in ("player", "enemy"):
                        for mon in inspection[side]["party"]:
                            key = f"{int(mon['dex']):03d}:{mon['name']}"
                            species_counts[key] = species_counts.get(key, 0) + 1
            for decision in range(config.episode_budget):
                results: dict[int, SearchResult] = {}
                actor_results = SimultaneousTreeSearch.search_many(
                    [
                        _new_search(
                            server,
                            actor.player_network,
                            actor.enemy_network,
                            config,
                            actor.selection_rng,
                            actor.chance_rng,
                            prior_noise=_collection_prior_noise(
                                config, actor.prior_noise_rng
                            ),
                        )
                        for actor in active
                    ],
                    [actor.snapshot for actor in active],
                    sample_actions=True,
                )
                searchable: list[_ActorEpisode] = []
                available_results: list[SearchResult] = []
                for actor, result in zip(active, actor_results, strict=True):
                    if result.failure is not None:
                        actor.final = _compact_inspection(actor.inspection)
                        append_episode(
                            actor,
                            "semantic-divergence",
                            decision,
                            reason=result.failure,
                        )
                        semantic_divergences += 1
                    else:
                        searchable.append(actor)
                        available_results.append(result)
                active = searchable
                actor_results = available_results
                if not active:
                    break
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
                    results[actor.episode] = _explore_search_result(
                        result, actor, config, decision
                    )
                for actor in active:
                    result = results[actor.episode]
                    snapshot = actor.snapshot
                    if frontier.capacity:
                        actor.frontier_snapshots[decision] = snapshot
                    valid_search_target = result.payoff_matrix is not None
                    search_diagnostics = result.diagnostics or {}
                    if valid_search_target:
                        target_kind = "joint-regret"
                    else:
                        raise RuntimeError("available RM+ search lacks a payoff matrix")
                    player_choice = _choice_detail(
                        actor.inspection, "player", result.player_action
                    )
                    enemy_choice = _choice_detail(
                        actor.inspection, "enemy", result.enemy_action
                    )
                    player_setup = (
                        _setup_move_name(player_choice["move"])
                        if snapshot.request == "battle"
                        and isinstance(player_choice.get("move"), dict)
                        else None
                    )
                    enemy_setup = (
                        _setup_move_name(enemy_choice["move"])
                        if snapshot.request == "battle"
                        and isinstance(enemy_choice.get("move"), dict)
                        else None
                    )
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
                            "player_choice": player_choice,
                            "enemy_choice": enemy_choice,
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
                            "chance_outcomes": search_diagnostics.get(
                                "chance_outcomes"
                            ),
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
                        "policy": _smoothed_policy(
                            list(result.player_policy), snapshot.player_mask, smoothing
                        ),
                        "opponent_policy": _smoothed_policy(
                            list(result.enemy_policy), snapshot.enemy_mask, smoothing
                        ),
                        "opponent_legal_mask": snapshot.enemy_mask,
                        "search_value": result.root_value,
                        "action": result.player_action,
                        "target_kind": target_kind,
                        "legal_mask": snapshot.player_mask,
                        "request": snapshot.request,
                        "player_party_size": actor.player_size,
                        "enemy_party_size": actor.enemy_size,
                    }
                    if player_setup is not None:
                        player_row["setup_move"] = player_setup
                    enemy_row = {
                        "type": "example",
                        "episode": actor.episode,
                        "pair": actor.pair,
                        "pair_leg": actor.pair_leg,
                        "decision": decision,
                        "side": "enemy",
                        "state_hash": snapshot.enemy_hash,
                        "features": snapshot.enemy_features.tolist(),
                        "policy": _smoothed_policy(
                            list(result.enemy_policy), snapshot.enemy_mask, smoothing
                        ),
                        "opponent_policy": _smoothed_policy(
                            list(result.player_policy), snapshot.player_mask, smoothing
                        ),
                        "opponent_legal_mask": snapshot.player_mask,
                        "search_value": -result.root_value,
                        "action": result.enemy_action,
                        "target_kind": target_kind,
                        "legal_mask": snapshot.enemy_mask,
                        "request": snapshot.request,
                        "player_party_size": actor.player_size,
                        "enemy_party_size": actor.enemy_size,
                    }
                    if enemy_setup is not None:
                        enemy_row["setup_move"] = enemy_setup
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
                                flags = classify_feature_decision(
                                    row["features"], row["action"]
                                )
                                decision_quality.observe(flags)
                                labels = flags.labels()
                                if labels:
                                    row["decision_quality"] = labels
                                setup_move = row.get("setup_move")
                                if setup_move is not None:
                                    setup_uses += 1
                                    setup_move_counts[setup_move] = (
                                        setup_move_counts.get(setup_move, 0) + 1
                                    )
                        if frontier.capacity and actor.pending:
                            priors = _frontier_priors(
                                network,
                                actor.pending,
                                config.inference_batch_size,
                            )
                            for row, prior in zip(actor.pending, priors, strict=True):
                                frontier.consider(
                                    _frontier_entry(
                                        config,
                                        iteration,
                                        actor,
                                        row,
                                        _frontier_score(row, prior),
                                        actor.frontier_snapshots[row["decision"]],
                                    )
                                )
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
                    setup_uses=setup_uses,
                    setup_use_rate=setup_uses / max(1, ordinary_actions),
                    setup_move_counts=setup_move_counts,
                    species_counts=species_counts,
                    species_schedule=meta["species_schedule"],
                    decision_quality_version="static-active-context-v1",
                    **decision_quality.report(),
                    mirror_episodes=mirror_episodes,
                    opponent_episodes=opponent_episodes,
                    model_opponent_episodes=model_opponent_episodes,
                    heuristic_opponent_episodes=heuristic_opponent_episodes,
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
    schedule_denominator = 4 if config.generated_schedule_version == 2 else 3
    schedule_tolerance = 2 * (schedule_denominator - 1)
    if (
        len(episode_indices) == config.selfplay_episodes
        and _scheduled_size_mix_enforced(config)
        and abs(six_vs_six_battles * schedule_denominator - len(episode_indices))
        > schedule_tolerance
    ):
        raise RuntimeError("collection 6v6 schedule differs from its target")
    if (
        len(episode_indices) == config.selfplay_episodes
        and _scheduled_size_mix_enforced(config)
        and abs(level100_six_vs_six_battles * schedule_denominator - six_vs_six_battles)
        > schedule_tolerance
    ):
        raise RuntimeError("collection level-100 6v6 schedule differs from its target")
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
        "party_size_schedule": generated_schedule_names(
            config.generated_schedule_version
        )[0],
        "level_schedule": generated_schedule_names(config.generated_schedule_version)[
            1
        ],
        "species_schedule": (
            "near-uniform-final-species-u16-v1"
            if config.balanced_final_species
            else "progression-weighted-final-species-v1"
        ),
        "target_6v6_fraction": 1 / schedule_denominator,
        "level100_6v6_fraction": 1 / schedule_denominator,
        "six_vs_six_battles": six_vs_six_battles,
        "level100_six_vs_six_battles": level100_six_vs_six_battles,
        "voluntary_switches": voluntary_switches,
        "setup_uses": setup_uses,
        "setup_move_counts": setup_move_counts,
        "species_counts": species_counts,
        "decision_quality_version": "static-active-context-v1",
        **decision_quality.report(),
        "ordinary_actions": ordinary_actions,
        "examples": examples,
        "transitions": transitions,
        "mirror_episodes": mirror_episodes,
        **(
            {"frontier_restart_episodes": frontier_restart_episodes}
            if config.frontier_restart_fraction
            else {}
        ),
        **(
            {"team_replay_episodes": team_replay_episodes}
            if config.team_replay_fraction
            else {}
        ),
        "opponent_episodes": opponent_episodes,
        "model_opponent_episodes": model_opponent_episodes,
        "heuristic_opponent_episodes": heuristic_opponent_episodes,
        "candidate_player_episodes": candidate_player_episodes,
        "candidate_enemy_episodes": candidate_enemy_episodes,
        "popular_gate": config.popular_gate,
        "popular_player_episodes": popular_player_episodes,
        "popular_enemy_episodes": popular_enemy_episodes,
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
        "setup_use_rate": sum("setup_move" in row for row in example_rows)
        / max(1, sum(row["request"] == "battle" for row in example_rows)),
        **({"frontier": frontier.entries()} if frontier.capacity else {}),
        **(
            {
                "hard_team_candidates": _hard_team_candidates(
                    episode_rows, config, iteration
                )
            }
            if config.team_replay_fraction and config.team_replay_buffer_size
            else {}
        ),
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
    frontier_source: str | None = None,
    matchup_plan: dict[int, int] | None = None,
    team_source: str | None = None,
) -> dict[str, Any]:
    torch.set_num_threads(1)
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
        frontier_source=frontier_source,
        matchup_plan=matchup_plan,
        team_source=team_source,
    )


def _merge_collection_rows(
    path: Path,
    worker_paths: list[Path],
    worker_metrics: list[dict[str, Any]],
    config: TransformerPipelineConfig,
    iteration: int,
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
    setup_move_counts: dict[str, int] = {}
    species_counts: dict[str, int] = {}
    for metrics in worker_metrics:
        for name, count in metrics["opponent_counts"].items():
            opponent_counts[name] = opponent_counts.get(name, 0) + count
        for name, count in metrics["party_size_counts"].items():
            party_size_counts[name] = party_size_counts.get(name, 0) + count
        for name, count in metrics["setup_move_counts"].items():
            setup_move_counts[name] = setup_move_counts.get(name, 0) + count
        for name, count in metrics.get("species_counts", {}).items():
            species_counts[name] = species_counts.get(name, 0) + count
    transitions = total("transitions")
    decision_quality = DecisionQualityMetrics(
        major_status_attempts=total("major_status_attempts"),
        redundant_status_same=total("redundant_status_same"),
        redundant_status_other=total("redundant_status_other"),
        stat_setup_attempts=total("stat_setup_attempts"),
        capped_stat_setup=total("capped_stat_setup"),
        ohko_attempts=total("ohko_attempts"),
        ohko_into_faster=total("ohko_into_faster"),
    )
    six_vs_six_battles = party_size_counts.get("6v6", 0)
    level100_six_vs_six_battles = total("level100_six_vs_six_battles")
    schedule_denominator = 4 if config.generated_schedule_version == 2 else 3
    schedule_tolerance = 2 * (schedule_denominator - 1)
    if (
        _scheduled_size_mix_enforced(config)
        and abs(six_vs_six_battles * schedule_denominator - config.selfplay_episodes)
        > schedule_tolerance
    ):
        raise RuntimeError("collection 6v6 schedule differs from its target")
    if (
        _scheduled_size_mix_enforced(config)
        and abs(level100_six_vs_six_battles * schedule_denominator - six_vs_six_battles)
        > schedule_tolerance
    ):
        raise RuntimeError("collection level-100 6v6 schedule differs from its target")
    merged = {
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
        "mirror_episodes": total("mirror_episodes"),
        **(
            {"frontier_restart_episodes": total("frontier_restart_episodes")}
            if config.frontier_restart_fraction
            else {}
        ),
        **(
            {"team_replay_episodes": total("team_replay_episodes")}
            if config.team_replay_fraction
            else {}
        ),
        "opponent_episodes": total("opponent_episodes"),
        "model_opponent_episodes": total("model_opponent_episodes"),
        "heuristic_opponent_episodes": total("heuristic_opponent_episodes"),
        "candidate_player_episodes": total("candidate_player_episodes"),
        "candidate_enemy_episodes": total("candidate_enemy_episodes"),
        "popular_gate": config.popular_gate,
        "popular_player_episodes": total("popular_player_episodes"),
        "popular_enemy_episodes": total("popular_enemy_episodes"),
        "opponent_counts": opponent_counts,
        "party_size_counts": party_size_counts,
        "party_size_schedule": generated_schedule_names(
            config.generated_schedule_version
        )[0],
        "level_schedule": generated_schedule_names(config.generated_schedule_version)[
            1
        ],
        "species_schedule": (
            "near-uniform-final-species-u16-v1"
            if config.balanced_final_species
            else "progression-weighted-final-species-v1"
        ),
        "target_6v6_fraction": 1 / schedule_denominator,
        "level100_6v6_fraction": 1 / schedule_denominator,
        "six_vs_six_battles": six_vs_six_battles,
        "level100_six_vs_six_battles": level100_six_vs_six_battles,
        "setup_uses": total("setup_uses"),
        "setup_move_counts": setup_move_counts,
        "species_counts": species_counts,
        "decision_quality_version": "static-active-context-v1",
        **decision_quality.report(),
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
        "mean_chance_outcomes": tree_mean("chance_outcomes"),
        "mean_sampled_joint_coverage": tree_mean("sampled_joint_coverage"),
        "mean_cross_root_batch_size": tree_mean("cross_root_batch_size"),
        "mean_cross_root_root_leaves": tree_mean("cross_root_root_leaves"),
        "mean_decisions": transitions / config.selfplay_episodes,
        "voluntary_switch_rate": sum(
            row["action"] in range(4, 10)
            for row in example_rows
            if row["request"] == "battle"
        )
        / max(1, sum(row["request"] == "battle" for row in example_rows)),
        "setup_use_rate": sum("setup_move" in row for row in example_rows)
        / max(1, sum(row["request"] == "battle" for row in example_rows)),
        "actor_shards": actor_shards,
        "sha256": sha256(path),
        "bytes": path.stat().st_size,
    }
    if config.frontier_buffer_size:
        merged["frontier"] = _merged_frontier(
            [metrics.get("frontier", []) for metrics in worker_metrics],
            config.frontier_buffer_size,
            config.frontier_reset_cap,
            config.frontier_episode_cap,
        )
    if config.team_replay_fraction and config.team_replay_buffer_size:
        # Round-robin episode partitioning puts a pair's two legs on different
        # workers, so per-worker candidate lists are structurally incomplete;
        # rescore the merged rows instead of concatenating them.
        merged["hard_team_candidates"] = _hard_team_candidates(
            episode_rows, config, iteration
        )
    return merged


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
    frontier_source = (
        str(path.with_name(f"frontier-{iteration - 1:03d}.jsonl"))
        if config.frontier_restart_fraction > 0.0 and iteration > 0
        else None
    )
    team_source = (
        str(path.with_name(f"hard-teams-{iteration - 1:03d}.jsonl"))
        if config.team_replay_fraction > 0.0
        and config.team_replay_buffer_size > 0
        and iteration > 0
        else None
    )
    matchup_plan: dict[int, int] | None = None
    matchup_stats: dict[str, Any] | None = None
    if config.matchup_value_cap > 0.0:
        # Frontier restart and team replay pairs replay recorded resets, so
        # probing them would waste incumbent evaluations on seeds the recipes
        # override anyway.
        restart_pairs = _frontier_restart_plan(
            config, iteration, len(_frontier_restart_entries(frontier_source))
        )
        replay_pairs = _team_replay_plan(
            config,
            iteration,
            len(_team_replay_entries(team_source)),
            exclude=restart_pairs,
        )
        with SearchServer(popular_gate=config.popular_gate) as probe_server:
            matchup_plan, matchup_stats = _matchup_filter_plan(
                probe_server,
                network,
                config,
                iteration,
                exclude={**restart_pairs, **replay_pairs},
                chunk_size=config.inference_batch_size,
            )
    if config.actor_processes == 1:
        metrics = _collect_rows_single(
            path,
            network,
            config,
            iteration,
            opponents,
            progress_path=progress_dir / "actor-00.json",
            frontier_source=frontier_source,
            matchup_plan=matchup_plan,
            team_source=team_source,
        )
        if matchup_stats is not None:
            metrics["matchup_filter"] = matchup_stats
        return _finalize_hard_teams(
            _finalize_frontier(metrics, path, iteration, config),
            path,
            iteration,
            config,
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
                    frontier_source,
                    matchup_plan,
                    team_source,
                )
                for process, (worker_path, episodes) in enumerate(
                    zip(worker_paths, partitions, strict=True)
                )
            ]
            metrics = [future.result() for future in futures]
        merged = _merge_collection_rows(path, worker_paths, metrics, config, iteration)
        if matchup_stats is not None:
            merged["matchup_filter"] = matchup_stats
        return _finalize_hard_teams(
            _finalize_frontier(merged, path, iteration, config),
            path,
            iteration,
            config,
        )


ExampleTensors = tuple[Tensor, Tensor, Tensor, Tensor, Tensor, Tensor, Tensor]


def _policy_reliability(row: dict[str, Any], floor: float) -> float:
    """How much of this row's policy target survived the split-half check.

    `root_split_half_distance` is the total-variation distance between the two
    common-random-number solves of the same root matrix, so zero means both
    chance worlds agreed exactly and one means they shared no mass at all. The
    weight interpolates between `floor` at total disagreement and one at total
    agreement; a floor of one is the legacy behaviour of trusting every target
    the same, and a row search never split-half checked keeps full weight.
    """
    if row.get("side") == "enemy":
        distance = row.get("root_split_half_enemy_distance")
    else:
        distance = row.get("root_split_half_distance")
    if distance is None:
        return 1.0
    agreement = min(1.0, max(0.0, 1.0 - float(distance)))
    return floor + (1.0 - floor) * agreement


def _rows_to_examples(rows: list[dict[str, Any]], floor: float = 1.0) -> ExampleTensors:
    features = [row["features"] for row in rows]
    policies = [row["policy"] for row in rows]
    opponent_policies = [row.get("opponent_policy", row["policy"]) for row in rows]
    values = [row["value"] for row in rows]
    legal_masks = [
        [
            bool(row["legal_mask"] & (1 << action))
            for action in range(len(row["policy"]))
        ]
        for row in rows
    ]
    opponent_legal_masks = [
        [
            bool(row.get("opponent_legal_mask", row["legal_mask"]) & (1 << action))
            for action in range(len(row["policy"]))
        ]
        for row in rows
    ]
    policy_weights = [
        0.0
        if row.get("target_kind") == "policy-rollout"
        else _policy_reliability(row, floor)
        for row in rows
    ]
    return (
        torch.tensor(features, dtype=torch.long),
        torch.tensor(policies, dtype=torch.float32),
        torch.tensor(opponent_policies, dtype=torch.float32),
        torch.tensor(values, dtype=torch.float32),
        torch.tensor(legal_masks, dtype=torch.bool),
        torch.tensor(opponent_legal_masks, dtype=torch.bool),
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


def _load_examples(paths: list[Path], floor: float = 1.0) -> ExampleTensors:
    return _rows_to_examples(_example_rows(paths), floor)


def _load_partitioned_examples(
    paths: list[Path],
    floor: float = 1.0,
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
        _rows_to_examples(training_rows, floor),
        _rows_to_examples(heldout_rows, floor),
        heldout_battles,
    )


def _heldout_diagnostics(
    network: BattleTransformer,
    examples: ExampleTensors,
    battle_ids: list[tuple[int, int]],
    batch_size: int,
) -> dict[str, Any]:
    (
        features,
        target_policy,
        target_opponent_policy,
        target_value,
        legal_masks,
        opponent_legal_masks,
        policy_weights,
    ) = examples
    device = next(network.parameters()).device
    squared_errors: list[float] = []
    leaf_squared_errors: list[float] = []
    leaf_distillation_errors: list[float] = []
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
            batch_opponent_policy = target_opponent_policy[start:stop].to(device)
            batch_value = target_value[start:stop].to(device)
            batch_legal = legal_masks[start:stop].to(device)
            batch_opponent_legal = opponent_legal_masks[start:stop].to(device)
            batch_weights = policy_weights[start:stop].to(device)
            if network.config.joint_policy_heads:
                logits, opponent_logits, values = network.forward_joint(batch_features)
            else:
                logits, values = network(batch_features)
                opponent_logits = logits
            logits = logits.masked_fill(~batch_legal, torch.finfo(logits.dtype).min)
            opponent_logits = opponent_logits.masked_fill(
                ~batch_opponent_legal, torch.finfo(opponent_logits.dtype).min
            )
            log_policy = torch.log_softmax(logits, dim=-1)
            opponent_log_policy = torch.log_softmax(opponent_logits, dim=-1)
            cross_entropy = -(batch_policy * log_policy).sum(dim=-1)
            opponent_cross_entropy = -(batch_opponent_policy * opponent_log_policy).sum(
                dim=-1
            )
            entropy = -(batch_policy * batch_policy.clamp_min(1e-12).log()).sum(dim=-1)
            opponent_entropy = -(
                batch_opponent_policy * batch_opponent_policy.clamp_min(1e-12).log()
            ).sum(dim=-1)
            policy_cross_entropy += float(
                ((cross_entropy + opponent_cross_entropy) * batch_weights).sum()
            )
            target_entropy += float(
                ((entropy + opponent_entropy) * batch_weights).sum()
            )
            weighted_policy_rows += 2.0 * float(batch_weights.sum())
            top_action_matches += int(
                (
                    (
                        logits.argmax(dim=-1).eq(batch_policy.argmax(dim=-1))
                        + opponent_logits.argmax(dim=-1).eq(
                            batch_opponent_policy.argmax(dim=-1)
                        )
                    )
                    * batch_weights.bool()
                )
                .sum()
                .item()
            )
            squared_errors.extend(
                (values - batch_value).square().float().cpu().tolist()
            )
            if network.config.distilled_leaf_evaluator:
                leaf_values = network.leaf_forward(batch_features)
                leaf_squared_errors.extend(
                    (leaf_values - batch_value).square().float().cpu().tolist()
                )
                leaf_distillation_errors.extend(
                    (leaf_values - values).square().float().cpu().tolist()
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
        "leaf_value_mse": (
            sum(leaf_squared_errors) / len(leaf_squared_errors)
            if leaf_squared_errors
            else None
        ),
        "leaf_main_distillation_mse": (
            sum(leaf_distillation_errors) / len(leaf_distillation_errors)
            if leaf_distillation_errors
            else None
        ),
        "policy_cross_entropy": mean_cross_entropy,
        "policy_target_entropy": mean_target_entropy,
        "policy_kl": mean_cross_entropy - mean_target_entropy,
        "policy_top_action_agreement": top_action_matches
        / max(1.0, weighted_policy_rows),
    }


def _gradient_report(
    samples: list[tuple[float, float, float | None]], value_loss_weight: float = 1.0
) -> dict[str, Any]:
    if not samples:
        return {
            "samples": 0,
            "cosine_samples": 0,
            "policy_trunk_norm": None,
            "value_trunk_norm": None,
            "value_policy_norm_ratio": None,
            "weighted_value_trunk_norm": None,
            "weighted_value_policy_norm_ratio": None,
            "value_loss_weight": value_loss_weight,
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
        "weighted_value_trunk_norm": value_norm * value_loss_weight,
        "weighted_value_policy_norm_ratio": (
            value_norm * value_loss_weight / max(policy_norm, 1e-12)
        ),
        "value_loss_weight": value_loss_weight,
        "mean_cosine": sum(cosines) / len(cosines) if cosines else None,
        "negative_cosine_fraction": (
            sum(cosine < 0.0 for cosine in cosines) / len(cosines) if cosines else None
        ),
    }


def _leaf_parameters(network: BattleTransformer) -> dict[str, Tensor]:
    return {
        name: parameter
        for name, parameter in network.named_parameters()
        if name.startswith("leaf_value.")
    }


def _initial_leaf_ema_state(
    network: BattleTransformer, decay: float
) -> dict[str, dict[str, Tensor]] | None:
    """Track a lagged (EMA) copy of the leaf evaluator beside its raw weights.

    Outside training the network carries the lagged copy, so search leaves,
    arena candidates, and deployed checkpoints all see the smoothed evaluator;
    the raw weights in "training" continue to learn between the swaps.
    """
    if decay <= 0.0 or not network.config.distilled_leaf_evaluator:
        return None
    leaf = {
        name: parameter.detach().clone()
        for name, parameter in _leaf_parameters(network).items()
    }
    return {
        "average": leaf,
        "training": {name: tensor.clone() for name, tensor in leaf.items()},
    }


def _begin_leaf_training(
    network: BattleTransformer, state: dict[str, dict[str, Tensor]] | None
) -> None:
    if state is None:
        return
    with torch.no_grad():
        for name, parameter in _leaf_parameters(network).items():
            parameter.copy_(state["training"][name])


def _update_leaf_ema(
    network: BattleTransformer,
    state: dict[str, dict[str, Tensor]] | None,
    decay: float,
) -> None:
    if state is None:
        return
    with torch.no_grad():
        for name, parameter in _leaf_parameters(network).items():
            state["average"][name].mul_(decay).add_(parameter, alpha=1.0 - decay)


def _end_leaf_training(
    network: BattleTransformer, state: dict[str, dict[str, Tensor]] | None
) -> None:
    if state is None:
        return
    with torch.no_grad():
        for name, parameter in _leaf_parameters(network).items():
            state["training"][name].copy_(parameter)
            parameter.copy_(state["average"][name])


def _leaf_ema_checkpoint_state(
    state: dict[str, dict[str, Tensor]] | None,
) -> dict[str, dict[str, Tensor]] | None:
    if state is None:
        return None
    return {
        key: {name: tensor.detach().cpu().clone() for name, tensor in group.items()}
        for key, group in state.items()
    }


def _learning_rate_for_iteration(
    config: TransformerPipelineConfig, iteration: int
) -> float:
    if config.lr_schedule == "constant":
        return config.learning_rate
    passed = sum(1 for milestone in config.lr_milestones if milestone <= iteration)
    return config.learning_rate * config.lr_decay_factor**passed


def _apply_learning_rate(
    optimizer: torch.optim.Optimizer, learning_rate: float
) -> None:
    for group in optimizer.param_groups:
        group["lr"] = learning_rate


def _train_network(
    network: BattleTransformer,
    optimizer: torch.optim.Optimizer,
    shards: list[Path],
    config: TransformerPipelineConfig,
    iteration: int,
    leaf_ema_state: dict[str, dict[str, Tensor]] | None = None,
) -> dict[str, Any]:
    device = next(network.parameters()).device
    training_examples, heldout_examples, heldout_battles = _load_partitioned_examples(
        shards, config.policy_reliability_floor
    )
    (
        features,
        target_policy,
        target_opponent_policy,
        target_value,
        legal_masks,
        opponent_legal_masks,
        policy_weights,
    ) = training_examples
    generator = torch.Generator(device="cpu").manual_seed(config.seed + iteration)
    trunk_parameters = [
        parameter
        for name, parameter in network.named_parameters()
        if not name.startswith(("policy.", "opponent_policy.", "value.", "leaf_value."))
    ]
    heldout_before = _heldout_diagnostics(
        network, heldout_examples, heldout_battles, config.inference_batch_size
    )
    _begin_leaf_training(network, leaf_ema_state)
    network.train()
    history: list[dict[str, float]] = []
    diagnostic_epochs: list[dict[str, Any]] = []
    for epoch in range(config.epochs):
        permutation = torch.randperm(len(features), generator=generator)
        policy_total = value_total = leaf_total = total_total = 0.0
        gradient_samples: list[tuple[float, float, float | None]] = []
        batches = 0
        for start in range(0, len(features), config.batch_size):
            indexes = permutation[start : start + config.batch_size]
            batch_features = features[indexes].to(device)
            batch_policy = target_policy[indexes].to(device)
            batch_opponent_policy = target_opponent_policy[indexes].to(device)
            batch_value = target_value[indexes].to(device)
            batch_legal = legal_masks[indexes].to(device)
            batch_opponent_legal = opponent_legal_masks[indexes].to(device)
            batch_policy_weight = policy_weights[indexes].to(device)
            if network.config.joint_policy_heads:
                logits, opponent_logits, values = network.forward_joint(batch_features)
            else:
                logits, values = network(batch_features)
                opponent_logits = logits
            logits = logits.masked_fill(~batch_legal, torch.finfo(logits.dtype).min)
            opponent_logits = opponent_logits.masked_fill(
                ~batch_opponent_legal, torch.finfo(opponent_logits.dtype).min
            )
            policy_rows = -(batch_policy * torch.log_softmax(logits, dim=-1)).sum(
                dim=-1
            )
            opponent_policy_rows = -(
                batch_opponent_policy * torch.log_softmax(opponent_logits, dim=-1)
            ).sum(dim=-1)
            policy_loss = (
                (policy_rows + opponent_policy_rows) * batch_policy_weight
            ).sum() / (2.0 * batch_policy_weight.sum()).clamp_min(1.0)
            value_loss = torch.nn.functional.mse_loss(values, batch_value)
            if network.config.distilled_leaf_evaluator:
                leaf_values = network.leaf_forward(batch_features)
                leaf_target_loss = torch.nn.functional.mse_loss(
                    leaf_values, batch_value
                )
                leaf_distillation_loss = torch.nn.functional.mse_loss(
                    leaf_values, values.detach()
                )
                leaf_loss = 0.5 * (leaf_target_loss + leaf_distillation_loss)
            else:
                leaf_loss = value_loss.new_zeros(())
            loss = (
                policy_loss
                + config.value_loss_weight * value_loss
                + config.leaf_loss_weight * leaf_loss
            )
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
            _update_leaf_ema(network, leaf_ema_state, config.leaf_ema_decay)
            policy_total += float(policy_loss.detach())
            value_total += float(value_loss.detach())
            leaf_total += float(leaf_loss.detach())
            total_total += float(loss.detach())
            batches += 1
        history.append(
            {
                "epoch": epoch,
                "policy_loss": policy_total / batches,
                "value_loss": value_total / batches,
                "weighted_value_loss": config.value_loss_weight * value_total / batches,
                "leaf_loss": leaf_total / batches,
                "weighted_leaf_loss": config.leaf_loss_weight * leaf_total / batches,
                "total_loss": total_total / batches,
            }
        )
        heldout = _heldout_diagnostics(
            network, heldout_examples, heldout_battles, config.inference_batch_size
        )
        gradient = _gradient_report(gradient_samples, config.value_loss_weight)
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
    _end_leaf_training(network, leaf_ema_state)
    leaf_ema_report: dict[str, float] | None = None
    if leaf_ema_state is not None:
        leaf_ema_report = {
            "decay": config.leaf_ema_decay,
            "lag_l2": math.sqrt(
                sum(
                    float(
                        (state_average - leaf_ema_state["training"][name])
                        .square()
                        .sum()
                    )
                    for name, state_average in leaf_ema_state["average"].items()
                )
            ),
        }
    return {
        "examples": len(features),
        "leaf_ema": leaf_ema_report,
        "heldout_examples": len(heldout_examples[0]),
        "heldout_battles": len(set(heldout_battles)),
        "epochs": config.epochs,
        "value_loss_weight": config.value_loss_weight,
        "leaf_loss_weight": config.leaf_loss_weight,
        "objective": "dual-policy-value-and-leaf-v5",
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
    player_size, enemy_size = generated_party_sizes(
        pair, config.generated_schedule_version
    )
    snapshot = server.reset(
        config.seed + 90_000_000,
        episode,
        player_size,
        enemy_size,
        level100=generated_level100(pair, config.generated_schedule_version),
        balanced_final_species=config.balanced_final_species,
    )
    for _ in range(config.episode_budget):
        search = _new_search(server, player, enemy, config, selection_rng, chance_rng)
        result = search.search(snapshot, sample_actions=True)
        if result.failure is not None:
            return None
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
    with SearchServer(popular_gate=config.popular_gate) as server:
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
    metrics: dict[str, Any],
    config: TransformerPipelineConfig,
) -> dict[str, Any]:
    reasons: list[str] = []
    episodes = config.selfplay_episodes
    if metrics["truncated"] / episodes > 0.01:
        reasons.append("horizon-truncation-rate-above-1pct")
    if metrics["semantic_divergences"] / episodes > 0.01:
        reasons.append("semantic-divergence-rate-above-1pct")
    if metrics["mean_decisions"] > 96:
        reasons.append("mean-battle-length-above-96")
    if metrics["finished"] / episodes < 0.98:
        reasons.append("finished-rate-below-98pct")
    return {
        "version": "completion-v6",
        "pass": not reasons,
        "reasons": reasons,
    }


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


def _normalized_saved_config(raw_config: dict[str, Any]) -> dict[str, Any]:
    """Fill run.json config fields that postdate the recorded run.

    Every default here must reproduce the exact behavior the older pipeline
    had before the field existed, so resumed runs stay bit-compatible.
    """
    normalized = dict(raw_config)
    normalized.setdefault("precision", "fp32")
    normalized.setdefault("balanced_final_species", False)
    normalized.setdefault("generated_schedule_version", 2)
    # V16 runs created before observational decision-quality probes used raw
    # network priors. Preserve that exact resume behavior.
    normalized.setdefault("redundant_action_prior_scale", 1.0)
    normalized.setdefault("prior_anchor_temperature", 0.02)
    normalized.setdefault("leaf_hidden_layers", None)
    normalized.setdefault("leaf_ema_decay", 0.0)
    normalized.setdefault("promotion_nonfinish_policy", "losses")
    normalized.setdefault("promotion_pooled_z", 0.0)
    normalized.setdefault("promotion_policy_games", 0)
    normalized.setdefault("bootstrap_promotion", False)
    normalized.setdefault("lr_schedule", "constant")
    normalized.setdefault("lr_milestones", ())
    normalized.setdefault("lr_decay_factor", 0.1)
    normalized.setdefault("shadow_opponent_window", 0)
    normalized.setdefault("collection_epsilon", 0.0)
    normalized.setdefault("collection_epsilon_turns", 0)
    normalized.setdefault("policy_target_smoothing", 0.0)
    normalized.setdefault("collection_dirichlet_alpha", 0.0)
    normalized.setdefault("collection_dirichlet_weight", 0.25)
    normalized.setdefault("collection_dirichlet_total", 0.0)
    normalized.setdefault("frontier_buffer_size", 256)
    normalized.setdefault("frontier_restart_fraction", 0.25)
    normalized.setdefault("frontier_reset_cap", 8)
    normalized.setdefault("frontier_episode_cap", 2)
    normalized.setdefault("split_half_reliability", True)
    normalized.setdefault("prior_regret", True)
    normalized.setdefault("policy_reliability_floor", 1.0)
    normalized.setdefault("matchup_value_cap", 0.9)
    normalized.setdefault("matchup_filter_attempts", 4)
    normalized.setdefault("matchup_lopsided_accept", 0.15)
    normalized.setdefault("team_replay_fraction", 0.15)
    normalized.setdefault("team_replay_buffer_size", 256)
    normalized.setdefault("popular_gate", 64)
    return normalized


def _resume_config(root: Path) -> TransformerPipelineConfig:
    run_path = root / "run.json"
    if not run_path.is_file():
        raise FileNotFoundError(f"resume metadata is missing: {run_path}")
    run = json.loads(run_path.read_text())
    if run.get("profile") != FULL_PROFILE or run.get("schema") != FULL_SCHEMA:
        raise ValueError("resume mechanics profile or tensor schema differs")
    raw_config = _normalized_saved_config(run["config"])
    if run.get("pipeline") != _pipeline_id(
        raw_config["balanced_final_species"], raw_config["generated_schedule_version"]
    ):
        raise ValueError(
            "resume pipeline version differs from the current implementation"
        )
    return TransformerPipelineConfig(**raw_config)


def resume_transformer_pipeline(root: Path) -> dict[str, Any]:
    """Continue an interrupted run from its last committed iteration."""
    return run_transformer_pipeline(root, _resume_config(root), resume=True)


def _promotion_gate_scores(
    promotion: dict[str, Any], policy: str
) -> tuple[float | None, float | None]:
    """Select the paired score and CI lower bound the promotion gate compares.

    "losses" keeps the historical scoring where every non-finish counts as a
    candidate loss; "exclude-pairs" scores only pairs whose both legs finished,
    so infrastructure stops cannot veto an otherwise superior candidate. The
    arena quality gate still bounds how many non-finishes can be excluded.
    Returns (None, None) when the exclusion leaves no finished pairs.
    """
    if policy == "losses":
        return (
            promotion["score_with_nonfinishes_as_losses"],
            promotion["paired_score_ci95"][0],
        )
    if policy == "exclude-pairs":
        return (
            promotion["score_excluding_nonfinish_pairs"],
            promotion["paired_score_ci95_excluding_nonfinish_pairs"][0],
        )
    raise ValueError("promotion_nonfinish_policy must be 'losses' or 'exclude-pairs'")


def _policy_gate_superior(
    policy_gate: dict[str, Any], policy: str, minimum_score: float
) -> bool:
    """Decide whether the net-only policy-argmax lane shows superiority.

    The search-mediated promotion arena plays both models through the same
    converged solver, which can equalize sides even when the raw policies
    differ. This lane compares the networks' own argmax play, so it carries
    its own quality gates rather than joining the enforced conjunction.
    """
    if not policy_gate.get("data_quality_pass") or not policy_gate.get("quality_pass"):
        return False
    score, ci_low = _promotion_gate_scores(policy_gate, policy)
    if score is None or ci_low is None:
        return False
    return score >= minimum_score and ci_low >= 0.50


def _pooled_promotion_evidence(
    pooled: dict[str, Any] | None,
    promotion: dict[str, Any],
    policy: str,
    minimum_score: float,
    threshold: float,
) -> dict[str, Any]:
    """Fold one promotion arena into the group-sequential evidence pool.

    Consecutive shadow learners face the same incumbent until a promotion
    lands, so their paired scores accumulate as evidence about the lineage.
    The pool triggers once the pooled mean clears the minimum score with a
    z-statistic at or above the configured threshold; it resets whenever a
    candidate is promoted.
    """
    if policy == "losses":
        moments = promotion["paired_score_moments"]
    elif policy == "exclude-pairs":
        moments = promotion["paired_score_moments_excluding_nonfinish_pairs"]
    else:
        raise ValueError(
            "promotion_nonfinish_policy must be 'losses' or 'exclude-pairs'"
        )
    score_sum, score_sumsq, pairs = moments
    iterations = 1
    if pooled is not None:
        score_sum += pooled["score_sum"]
        score_sumsq += pooled["score_sumsq"]
        pairs += pooled["pairs"]
        iterations = pooled["iterations"] + 1
    mean = score_sum / pairs if pairs else None
    z = None
    if pairs >= 2:
        variance = (score_sumsq - score_sum * score_sum / pairs) / (pairs - 1)
        if variance > 0.0:
            z = (mean - 0.5) / math.sqrt(variance / pairs)
    return {
        "iterations": iterations,
        "pairs": pairs,
        "score_sum": score_sum,
        "score_sumsq": score_sumsq,
        "mean": mean,
        "z": z,
        "threshold": threshold,
        "triggered": z is not None and z >= threshold and mean >= minimum_score,
    }


def _resumed_pooled_evidence(
    training: list[dict[str, Any]],
    lane: str = "promotion",
) -> dict[str, Any] | None:
    """Restore the evidence pool from the last committed iteration.

    Records written before pooling existed carry no pool and restart it
    empty, and an accepted promotion resets the pool because the incumbent
    it measured is gone. Secondary gate lanes store their pool under their
    own record inside the promotion dict.
    """
    if not training:
        return None
    promotion = training[-1].get("promotion") or {}
    if promotion.get("accepted"):
        return None
    record = promotion if lane == "promotion" else (promotion.get(lane) or {})
    return record.get("pooled")


def _lineage_promotions(training: list[dict[str, Any]]) -> int:
    return sum(
        1 for record in training if (record.get("promotion") or {}).get("accepted")
    )


def _bootstrap_waiver_active(
    config: TransformerPipelineConfig, training: list[dict[str, Any]]
) -> bool:
    """Decide whether generation zero may promote without superiority proof.

    Until the first promotion lands, the incumbent is the random
    initialization, and demanding CI-low >= 0.50 against it stalls the
    lineage when search play equalizes the sides. A warm-started incumbent
    is a real model, so it keeps the full statistical requirement.
    """
    return (
        config.bootstrap_promotion
        and config.warm_start_incumbent_checkpoint is None
        and _lineage_promotions(training) == 0
    )


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
    if config.search_every != 1:
        raise ValueError("RM+ action selection requires search_every = 1")
    if config.rmplus_backend != RUST_RMPLUS_BACKEND or not config.cfr_plus_solves:
        raise ValueError("V26 requires the native Rust CFR+ solver")
    if not native_available():
        raise RuntimeError("V26 native Rust CFR+ library is unavailable")
    if config.tree_regret_iterations < 1:
        raise ValueError("tree_regret_iterations must be positive")
    if not 0.0 <= config.leaf_ema_decay < 1.0:
        raise ValueError("leaf_ema_decay must be in [0, 1)")
    if config.promotion_nonfinish_policy not in ("losses", "exclude-pairs"):
        raise ValueError(
            "promotion_nonfinish_policy must be 'losses' or 'exclude-pairs'"
        )
    if config.promotion_pooled_z < 0.0:
        raise ValueError("promotion_pooled_z must be nonnegative")
    if config.lr_schedule not in ("constant", "step"):
        raise ValueError("lr_schedule must be 'constant' or 'step'")
    if not 0.0 < config.lr_decay_factor <= 1.0:
        raise ValueError("lr_decay_factor must be in (0, 1]")
    milestones = list(config.lr_milestones)
    if any(milestone < 1 for milestone in milestones) or milestones != sorted(
        set(milestones)
    ):
        raise ValueError(
            "lr_milestones must be strictly increasing positive iterations"
        )
    if not 0.0 <= config.collection_epsilon <= 1.0:
        raise ValueError("collection_epsilon must be in [0, 1]")
    if config.collection_epsilon_turns < 0:
        raise ValueError("collection_epsilon_turns must be nonnegative")
    if not 0.0 <= config.policy_target_smoothing <= 1.0:
        raise ValueError("policy_target_smoothing must be in [0, 1]")
    if config.collection_dirichlet_alpha < 0.0:
        raise ValueError("collection_dirichlet_alpha must be nonnegative")
    if not 0.0 <= config.collection_dirichlet_weight <= 1.0:
        raise ValueError("collection_dirichlet_weight must be in [0, 1]")
    if config.collection_dirichlet_total < 0.0:
        raise ValueError("collection_dirichlet_total must be nonnegative")
    if config.frontier_buffer_size < 0:
        raise ValueError("frontier_buffer_size must be nonnegative")
    if not 0.0 <= config.frontier_restart_fraction <= 0.25:
        raise ValueError("frontier_restart_fraction must be in [0, 0.25]")
    if config.frontier_reset_cap < 0:
        raise ValueError("frontier_reset_cap must be nonnegative")
    if config.frontier_episode_cap < 0:
        raise ValueError("frontier_episode_cap must be nonnegative")
    if config.prior_regret and not config.split_half_reliability:
        raise ValueError(
            "prior_regret needs split_half_reliability for its noise floor"
        )
    if not 0.0 <= config.policy_reliability_floor <= 1.0:
        raise ValueError("policy_reliability_floor must be in [0, 1]")
    if config.policy_reliability_floor < 1.0 and not config.split_half_reliability:
        raise ValueError(
            "policy_reliability_floor needs split_half_reliability for its distances"
        )
    if not 0.0 <= config.matchup_value_cap < 1.0:
        raise ValueError("matchup_value_cap must be in [0, 1)")
    if config.matchup_filter_attempts < 1:
        raise ValueError("matchup_filter_attempts must be positive")
    if not 0.0 <= config.matchup_lopsided_accept <= 1.0:
        raise ValueError("matchup_lopsided_accept must be in [0, 1]")
    if config.team_replay_buffer_size < 0:
        raise ValueError("team_replay_buffer_size must be nonnegative")
    if not 0.0 <= config.team_replay_fraction <= 0.25:
        raise ValueError("team_replay_fraction must be in [0, 0.25]")
    if config.team_replay_fraction and not config.team_replay_buffer_size:
        raise ValueError("team_replay_buffer_size must be positive with team replay")
    if not 0 <= config.popular_gate <= 64:
        raise ValueError("popular_gate must be in [0, 64]")
    if config.generated_schedule_version not in {2, 3}:
        raise ValueError("generated_schedule_version must be 2 or 3")
    if config.balanced_final_species and config.generated_schedule_version != 3:
        raise ValueError("balanced final species requires generated schedule v3")
    if config.actor_batch_size < 1:
        raise ValueError("actor_batch_size must be positive")
    if not 1 <= config.actor_processes <= min(16, config.selfplay_episodes):
        raise ValueError("actor_processes must be in 1..min(16, selfplay_episodes)")
    if not 1 <= config.eval_processes <= 16:
        raise ValueError("eval_processes must be in 1..16")
    if config.precision not in {"bf16", "fp32"}:
        raise ValueError("precision must be bf16 or fp32")
    if config.token_layout not in {"scalar-v1", "semantic-entity-v1"}:
        raise ValueError("token_layout must be scalar-v1 or semantic-entity-v1")
    if config.token_layout == "semantic-entity-v1" and config.token_group_size != 1:
        raise ValueError("semantic entity tokens require token_group_size = 1")
    if config.max_actions_per_side < 13:
        raise ValueError(
            "full-party training must consider the complete action dictionary"
        )
    if config.replay_window < 1:
        raise ValueError("replay_window must be positive")
    if config.epochs < 1:
        raise ValueError("epochs must be positive")
    if not 0.0 < config.value_loss_weight <= 1.0:
        raise ValueError("value_loss_weight must be in (0, 1]")
    if config.leaf_hidden < 1:
        raise ValueError("leaf_hidden must be positive")
    if not 0.0 <= config.leaf_loss_weight <= 1.0:
        raise ValueError("leaf_loss_weight must be in [0, 1]")
    if not 0.0 < config.redundant_action_prior_scale <= 1.0:
        raise ValueError("redundant_action_prior_scale must be in (0, 1]")
    if not 0.0 <= config.prior_anchor_temperature <= 1.0:
        raise ValueError("prior_anchor_temperature must be in [0, 1]")
    if config.historical_window < 0:
        raise ValueError("historical_window must be nonnegative")
    if config.promotion_games < 2 or config.promotion_games % 2:
        raise ValueError("promotion_games must be an even number of at least two")
    if config.promotion_policy_games < 0:
        raise ValueError("promotion_policy_games must be nonnegative")
    if config.promotion_policy_games and (
        config.promotion_policy_games % 2
        or config.promotion_policy_games < 2 * config.promotion_seed_count
    ):
        raise ValueError(
            "promotion_policy_games must be even and cover every promotion seed"
        )
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
    if not 0.0 <= config.model_opponent_share <= 1.0:
        raise ValueError("model_opponent_share must be in [0, 1]")
    if config.shadow_opponent_window < 0:
        raise ValueError("shadow_opponent_window must be nonnegative")
    build_search_server()
    with SearchServer(popular_gate=config.popular_gate) as protocol:
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
        token_layout=config.token_layout,
        joint_policy_heads=config.joint_policy_heads,
        distilled_leaf_evaluator=config.distilled_leaf_evaluator,
        leaf_hidden=config.leaf_hidden,
        leaf_hidden_layers=config.leaf_hidden_layers,
    )
    opponents: list[tuple[Any, str]] = []
    opponent_metadata: list[dict[str, Any]] = []
    initial_checkpoint = root / "checkpoints" / "policy-000.pt"

    if resume:
        run_metadata = json.loads((root / "run.json").read_text())
        saved_config = _normalized_saved_config(run_metadata.get("config", {}))
        if saved_config != asdict(config):
            raise ValueError("resume configuration differs from immutable run metadata")
        if run_metadata.get("network") != _serialized_network_config(model_config):
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
        if completed > config.iterations:
            raise ValueError("completed iterations exceed the configured run length")
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
        leaf_ema_state = _initial_leaf_ema_state(network, config.leaf_ema_decay)
        if leaf_ema_state is not None:
            saved_leaf_ema = latest_payload.get("leaf_ema")
            if isinstance(saved_leaf_ema, dict):
                for key in ("average", "training"):
                    for name, tensor in saved_leaf_ema[key].items():
                        leaf_ema_state[key][name] = tensor.to(device)
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
            warm_payload = load_checkpoint(warm_copy, device)
            source_feature_count = int(warm_payload["config"]["feature_count"])
            network = warm_start_network(warm_copy, model_config, device)
            warm_start_metadata = {
                "checkpoint": warm_copy.relative_to(root).as_posix(),
                "sha256": warm_sha,
                "method": (
                    "same-schema-copy-v1"
                    if source_feature_count == model_config.feature_count
                    else "extend-position-table-v1"
                ),
            }
        else:
            network = BattleTransformer(model_config).to(device)
            network.eval()
        incumbent_warm_start_metadata: dict[str, Any] | None = None
        if config.warm_start_incumbent_checkpoint is not None:
            if config.warm_start_checkpoint is None:
                raise ValueError(
                    "an incumbent warm start requires a learner warm start"
                )
            incumbent_source = Path(config.warm_start_incumbent_checkpoint).resolve()
            incumbent_sha = sha256(incumbent_source)
            incumbent_copy = root / "warm-start" / "incumbent.pt"
            write_new(incumbent_copy, incumbent_source.read_bytes())
            incumbent_payload = load_checkpoint(incumbent_copy, device)
            incumbent_feature_count = int(incumbent_payload["config"]["feature_count"])
            incumbent_network = warm_start_network(incumbent_copy, model_config, device)
            incumbent_warm_start_metadata = {
                "checkpoint": incumbent_copy.relative_to(root).as_posix(),
                "sha256": incumbent_sha,
                "method": (
                    "same-schema-deployed-copy-v1"
                    if incumbent_feature_count == model_config.feature_count
                    else "extend-deployed-position-table-v1"
                ),
            }
        else:
            incumbent_network = network.detached_copy(device)
        write_json(
            root / "run.json",
            {
                "pipeline": _pipeline_id(
                    config.balanced_final_species, config.generated_schedule_version
                ),
                "profile": FULL_PROFILE,
                "schema": FULL_SCHEMA,
                "max_party_size": FULL_PARTY_SIZE,
                "party_size_schedule": generated_schedule_names(
                    config.generated_schedule_version
                )[0],
                "level_schedule": generated_schedule_names(
                    config.generated_schedule_version
                )[1],
                "species_schedule": (
                    "near-uniform-final-species-u16-v1"
                    if config.balanced_final_species
                    else "progression-weighted-final-species-v1"
                ),
                "chance": "fresh-root-v1",
                "rmplus": native_metadata(),
                "search_solver": ("simultaneous-tree-anchored-qre-v8"),
                "action_selector": ("simultaneous-tree-anchored-qre-every-decision-v8"),
                "collection_pairing": "same-reset-opposite-controller-sides-v1",
                "learning_lineage": "persistent-shadow-v1",
                "deployment_lineage": "quality-gated-incumbent-v1",
                "evaluation_topology": "persistent-process-pool-full-utilization-v1",
                "final_evaluation_topology": "parallel-independent-arena-pool-v1",
                "config": asdict(config),
                "network": asdict(model_config),
                "parameter_count": sum(
                    parameter.numel() for parameter in network.parameters()
                ),
                "opponents": opponent_metadata,
                "warm_start": warm_start_metadata,
                "incumbent_warm_start": incumbent_warm_start_metadata,
                "torch": torch.__version__,
                "device": str(device),
                "device_name": torch.cuda.get_device_name(device)
                if device.type == "cuda"
                else "cpu",
            },
        )
        leaf_ema_state = _initial_leaf_ema_state(network, config.leaf_ema_decay)
        initial_state: dict[str, object] = {"learner_model": network.state_dict()}
        if leaf_ema_state is not None:
            initial_state["leaf_ema"] = _leaf_ema_checkpoint_state(leaf_ema_state)
        save_network(
            initial_checkpoint,
            incumbent_network,
            None,
            {
                "iteration": 0,
                "kind": "initial",
                "warm_start": warm_start_metadata,
                "incumbent_warm_start": incumbent_warm_start_metadata,
                "learning_lineage": "persistent-shadow-v1",
            },
            initial_state,
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
    shadow_pool: list[tuple[Any, str]] = []
    for shadow_iteration in _shadow_seed_iterations(
        first_iteration - 1, config.shadow_opponent_window
    ):
        shadow_checkpoint = root / "checkpoints" / f"policy-{shadow_iteration:03d}.pt"
        shadow_state = load_checkpoint(shadow_checkpoint, device).get("learner_model")
        if not isinstance(shadow_state, dict):
            continue
        shadow_network = BattleTransformer(model_config).to(device)
        shadow_network.load_state_dict(shadow_state)
        shadow_network.eval()
        shadow_pool.append((shadow_network, sha256(shadow_checkpoint)))
    _configure_inference(
        [network, incumbent_network, initial, initial_anchor]
        + [model for model, _ in opponents]
        + [model for model, _ in historical]
        + [model for model, _ in shadow_pool],
        config.inference_engine,
    )
    write_monitor_state(
        root,
        "ready",
        iteration=first_iteration,
        message="Models loaded; collection is ready",
    )
    pooled_evidence = _resumed_pooled_evidence(training)
    policy_pooled_evidence = _resumed_pooled_evidence(training, "policy_gate")
    for iteration in range(first_iteration, config.iterations + 1):
        population = _assemble_population(
            opponents,
            (incumbent_network, incumbent_identity),
            (initial_anchor, initial_identity),
            historical,
            shadow_pool,
            historical_window=config.historical_window,
            shadow_window=config.shadow_opponent_window,
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
        learning_rate = _learning_rate_for_iteration(config, iteration)
        _apply_learning_rate(optimizer, learning_rate)
        training_metrics = _train_network(
            network, optimizer, training_shards, config, iteration, leaf_ema_state
        )
        training_metrics["learning_rate"] = learning_rate
        if device.type == "cuda":
            torch.cuda.empty_cache()
        evaluation_pool = ArenaEvaluationPool(
            network, incumbent_network, config.eval_processes
        )
        write_monitor_state(
            root,
            "promotion",
            iteration=iteration,
            message=f"Running {config.promotion_games:,} paired promotion games",
            games=config.promotion_games,
            training_diagnostics=training_metrics["diagnostics"]["latest"],
        )
        try:
            promotion = run_paired_arena(
                network,
                incumbent_network,
                _arena_config(
                    config,
                    config.promotion_games,
                    config.seed + 70_000_000 + iteration * 10_007,
                    config.promotion_seed_count,
                    matchup_filter=True,
                ),
                capture_details=True,
                processes=config.eval_processes,
                pool=evaluation_pool,
                progress=_evaluation_progress(
                    root,
                    "promotion",
                    iteration,
                    "Running paired promotion games",
                    training_diagnostics=training_metrics["diagnostics"]["latest"],
                ),
                telemetry=ArenaTelemetry(root / ".monitor", "promotion", iteration),
            )
        except BaseException:
            evaluation_pool.close()
            raise
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
        policy_gate: dict[str, Any] | None = None
        if config.promotion_policy_games > 0:
            write_monitor_state(
                root,
                "promotion",
                iteration=iteration,
                message=(
                    f"Running {config.promotion_policy_games:,} "
                    "net-only policy gate games"
                ),
                games=config.promotion_policy_games,
                training_diagnostics=training_metrics["diagnostics"]["latest"],
            )
            try:
                policy_gate = run_paired_arena(
                    network,
                    incumbent_network,
                    _arena_config(
                        config,
                        config.promotion_policy_games,
                        config.seed + 75_000_000 + iteration * 10_037,
                        config.promotion_seed_count,
                        policy_only=True,
                        matchup_filter=True,
                    ),
                    processes=config.eval_processes,
                    pool=evaluation_pool,
                    progress=_evaluation_progress(
                        root,
                        "promotion",
                        iteration,
                        "Running net-only policy gate games",
                        training_diagnostics=(
                            training_metrics["diagnostics"]["latest"]
                        ),
                    ),
                )
            except BaseException:
                evaluation_pool.close()
                raise
            policy_gate["battles"] = []
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
        try:
            probe_arena = run_traced_arena(
                network,
                incumbent_network,
                _arena_config(
                    config,
                    config.probe_games,
                    config.seed + 80_000_000 + iteration * 10_009,
                    config.probe_seed_count,
                ),
                processes=config.eval_processes,
                pool=evaluation_pool,
                progress=_evaluation_progress(
                    root,
                    "probes",
                    iteration,
                    "Running held-out skill probes",
                    promotion=live_promotion,
                    training_diagnostics=training_metrics["diagnostics"]["latest"],
                ),
            )
        except BaseException:
            evaluation_pool.close()
            raise
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
        try:
            campaign_arena = run_campaign_arena(
                network,
                incumbent_network,
                _arena_config(
                    config,
                    config.campaign_games,
                    config.seed + 85_000_000 + iteration * 10_019,
                    config.campaign_seed_count,
                ),
                processes=config.eval_processes,
                pool=evaluation_pool,
                progress=_evaluation_progress(
                    root,
                    "campaign",
                    iteration,
                    "Running campaign battles",
                    promotion=live_promotion,
                    probes_pass=probes["pass"],
                    training_diagnostics=training_metrics["diagnostics"]["latest"],
                ),
            )
        finally:
            evaluation_pool.close()
        promotion_score, confidence_low = _promotion_gate_scores(
            promotion, config.promotion_nonfinish_policy
        )
        statistically_superior = (
            promotion_score is not None
            and confidence_low is not None
            and promotion_score >= config.minimum_promotion_score
            and confidence_low >= 0.50
        )
        if config.promotion_pooled_z > 0.0:
            pooled_evidence = _pooled_promotion_evidence(
                pooled_evidence,
                promotion,
                config.promotion_nonfinish_policy,
                config.minimum_promotion_score,
                config.promotion_pooled_z,
            )
            statistically_superior = (
                statistically_superior or pooled_evidence["triggered"]
            )
        else:
            pooled_evidence = None
        policy_superior = False
        if policy_gate is not None:
            policy_superior = _policy_gate_superior(
                policy_gate,
                config.promotion_nonfinish_policy,
                config.minimum_promotion_score,
            )
            if config.promotion_pooled_z > 0.0:
                policy_pooled_evidence = _pooled_promotion_evidence(
                    policy_pooled_evidence,
                    policy_gate,
                    config.promotion_nonfinish_policy,
                    config.minimum_promotion_score,
                    config.promotion_pooled_z,
                )
                if policy_gate["data_quality_pass"] and policy_gate["quality_pass"]:
                    policy_superior = (
                        policy_superior or policy_pooled_evidence["triggered"]
                    )
            else:
                policy_pooled_evidence = None
            policy_gate["superior"] = policy_superior
            policy_gate["pooled"] = policy_pooled_evidence
            statistically_superior = statistically_superior or policy_superior
        else:
            policy_pooled_evidence = None
        bootstrap_waiver = _bootstrap_waiver_active(config, training)
        superiority_satisfied = statistically_superior or (
            bootstrap_waiver
            and promotion_score is not None
            and promotion_score >= config.minimum_promotion_score
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
                and superiority_satisfied
                and probes["pass"]
            )
        else:
            accepted = (
                promotion["data_quality_pass"]
                and promotion["quality_pass"]
                and probe_arena["data_quality_pass"]
                and probe_arena["quality_pass"]
                and promotion_score is not None
                and promotion_score >= config.minimum_promotion_score
            )
        promotion["statistically_superior"] = statistically_superior
        promotion["minimum_score"] = config.minimum_promotion_score
        promotion["nonfinish_policy"] = config.promotion_nonfinish_policy
        promotion["pooled"] = pooled_evidence
        promotion["policy_gate"] = policy_gate
        promotion["bootstrap_promotion"] = {
            "eligible": bootstrap_waiver,
            "applied": bool(
                config.enforce_quality_gate
                and accepted
                and bootstrap_waiver
                and not statistically_superior
            ),
        }
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
            pooled_evidence = None
            policy_pooled_evidence = None
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
        iteration_state: dict[str, object] = {"learner_model": network.state_dict()}
        if leaf_ema_state is not None:
            iteration_state["leaf_ema"] = _leaf_ema_checkpoint_state(leaf_ema_state)
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
            iteration_state,
        )
        if accepted:
            incumbent_identity = sha256(checkpoint)
            historical.append(
                (incumbent_network.detached_copy(device), incumbent_identity)
            )
        if len(historical) > config.historical_window + 1:
            historical.pop(0)
        if config.shadow_opponent_window:
            _append_shadow_opponent(
                shadow_pool,
                (network.detached_copy(device), sha256(checkpoint)),
                config.shadow_opponent_window,
            )
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
    arena_config = _arena_config(
        config,
        config.arena_episodes,
        config.seed,
        min(8, config.arena_episodes // 2),
        replay_games=min(3, config.arena_episodes),
    )
    final_arena_jobs = [
        ArenaReportJob(root / "arena" / "final-vs-initial", initial, arena_config),
        *[
            ArenaReportJob(
                root / "arena" / f"final-vs-fixed-{index:03d}",
                opponent,
                arena_config,
            )
            for index, (opponent, _) in enumerate(opponents)
        ],
    ]

    def final_arena_progress(completed: int, total: int) -> None:
        write_monitor_state(
            root,
            "final-arena",
            iteration=config.iterations,
            message=f"Running final model evaluations: {completed:,} / {total:,} arenas",
            completed=completed,
            games=total,
            evaluation_unit="arenas",
        )

    final_arena_reports: list[dict[str, Any] | None] = [None for _ in final_arena_jobs]
    pending_final_jobs = []
    pending_final_indexes = []
    for index, job in enumerate(final_arena_jobs):
        summary_path = job.output / "summary.json"
        replay_paths = [
            job.output / "replays" / f"game-{game:05d}.log"
            for game in range(job.config.replay_games)
        ]
        if summary_path.is_file() and all(path.is_file() for path in replay_paths):
            report = json.loads(summary_path.read_text())
            if (
                report.get("config") != asdict(job.config)
                or report.get("side_swap_complete") is not True
            ):
                raise ValueError(
                    f"completed final arena report is incompatible: {summary_path}"
                )
            final_arena_reports[index] = report
        else:
            pending_final_jobs.append(job)
            pending_final_indexes.append(index)
    reused_final_arenas = len(final_arena_jobs) - len(pending_final_jobs)
    if reused_final_arenas:
        final_arena_progress(reused_final_arenas, len(final_arena_jobs))

    def pending_final_arena_progress(completed: int, _: int) -> None:
        final_arena_progress(
            reused_final_arenas + completed,
            len(final_arena_jobs),
        )

    pending_final_reports = write_arena_reports_parallel(
        incumbent_network,
        pending_final_jobs,
        config.eval_processes,
        progress=pending_final_arena_progress,
    )
    for index, report in zip(pending_final_indexes, pending_final_reports, strict=True):
        final_arena_reports[index] = report
    if any(report is None for report in final_arena_reports):
        raise RuntimeError("final arena report scheduling returned incomplete results")
    complete_final_arena_reports = [
        report for report in final_arena_reports if report is not None
    ]
    arena = complete_final_arena_reports[0]
    opponent_arenas = complete_final_arena_reports[1:]
    for result, (_, identity) in zip(opponent_arenas, opponents, strict=True):
        result["opponent_sha256"] = identity

    with tempfile.TemporaryDirectory(prefix="battle-transformer-replay-") as temporary:
        replay_path = Path(temporary) / "replay.jsonl"
        replay_payload = load_checkpoint(initial_checkpoint, device)
        replay_learner = replay_payload.get("learner_model")
        if not isinstance(replay_learner, dict):
            raise TypeError("initial checkpoint lacks replay learner state")
        replay_network = BattleTransformer(model_config).to(device)
        replay_network.load_state_dict(replay_learner)
        replay_network.eval()
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
        "pipeline": _pipeline_id(
            config.balanced_final_species, config.generated_schedule_version
        ),
        "device": str(device),
        "rmplus": native_metadata(),
        "action_selector": ("simultaneous-tree-anchored-qre-every-decision-v8"),
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
        "evaluation_topology": "persistent-process-pool-full-utilization-v1",
        "final_evaluation_topology": "parallel-independent-arena-pool-v1",
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
