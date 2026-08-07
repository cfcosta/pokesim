"""Traced variable-party arenas and policy-skill diagnostics."""

from __future__ import annotations

import math
import multiprocessing
import random
import tempfile
import time
from collections.abc import Callable
from concurrent.futures import ProcessPoolExecutor, as_completed
from dataclasses import asdict, dataclass, field, replace
from pathlib import Path
from typing import Any, Self

import torch

from . import (
    FULL_CAMPAIGN_COUNT,
    FULL_PARTY_SIZE,
    FULL_PROFILE,
    generated_level100,
    generated_party_sizes,
    generated_schedule_names,
)
from .artifacts import write_json
from .decision_quality import (
    DecisionQualityMetrics,
    classify_feature_decision,
    shape_redundant_action_priors,
)
from .joint_search import (
    JointSearchConfig,
    SearchResult,
    SimultaneousTreeSearch,
    legal_actions,
)
from .monitor import write_actor_progress
from .native import NativeRequestTimeout, SearchServer
from .network import (
    BattleTransformer,
    TransformerConfig,
    choose_device,
    configure_determinism,
)
from .rmplus_native import RUST_RMPLUS_BACKEND

_FIXED_DAMAGE_MOVES = {68, 69, 82, 101, 149, 162}
# Self-buffs, screens, and persistent defensive/utility setup. Charge turns,
# healing, opponent status, Haze, Mimic, Metronome, and Transform are excluded.
_SETUP_MOVE_IDS = {
    14,  # Swords Dance
    54,  # Mist
    74,  # Growth
    96,  # Meditate
    97,  # Agility
    104,  # Double Team
    106,  # Harden
    107,  # Minimize
    110,  # Withdraw
    111,  # Defense Curl
    112,  # Barrier
    113,  # Light Screen
    115,  # Reflect
    116,  # Focus Energy
    133,  # Amnesia
    151,  # Acid Armor
    159,  # Sharpen
    160,  # Conversion
    164,  # Substitute
}
_CAMPAIGN_NAMES = (
    "Brock",
    "Misty",
    "Lt. Surge",
    "Erika",
    "Koga",
    "Sabrina",
    "Blaine",
    "Giovanni",
    "Lance",
)
assert len(_CAMPAIGN_NAMES) == FULL_CAMPAIGN_COUNT
_SUCCESS_EVENTS = {
    "status-applied",
    "stage-changed",
    "healed",
    "screen",
    "transformed",
    "seeded",
    "disabled",
}


@dataclass(frozen=True)
class ArenaConfig:
    games: int
    budget: int = 512
    chance_samples_per_joint: int = 1
    search_depth: int = 4
    regret_iterations: int = 2048
    inference_batch_size: int = 256
    max_actions_per_side: int = 13
    tree_regret_iterations: int = 16
    redundant_action_prior_scale: float = 0.25
    prior_anchor_temperature: float = 0.02
    seed: int = 0
    replay_games: int = 3
    seed_count: int = 8
    balanced_final_species: bool = True
    generated_schedule_version: int = 3
    rmplus_backend: str = RUST_RMPLUS_BACKEND
    cfr_plus_solves: bool = True
    policy_only: bool = False
    matchup_value_cap: float = 0.9
    matchup_filter_attempts: int = 4
    matchup_plan: dict[int, int] | None = None
    popular_gate: int = 64


@dataclass(frozen=True)
class ArenaTelemetry:
    """Mutable, non-artifact progress emitted by independent arena workers."""

    directory: Path
    stage: str
    iteration: int
    recent_battles: int = 40


@dataclass
class SkillMetrics:
    damaging_moves: int = 0
    effectiveness_ratio_sum: float = 0.0
    best_effectiveness_choices: int = 0
    super_effective_choices: int = 0
    status_uses: int = 0
    status_successes: int = 0
    status_failures: int = 0
    status_wasted: int = 0
    ordinary_actions: int = 0
    voluntary_switches: int = 0
    completed_voluntary_switches: int = 0
    matchup_improving_switches: int = 0
    setup_uses: int = 0
    setup_move_counts: dict[str, int] = field(default_factory=dict)
    decision_quality: DecisionQualityMetrics = field(
        default_factory=DecisionQualityMetrics
    )
    effectiveness_ratios: list[float] = field(default_factory=list)

    def merge(self, other: SkillMetrics) -> None:
        for name in (
            "damaging_moves",
            "best_effectiveness_choices",
            "super_effective_choices",
            "status_uses",
            "status_successes",
            "status_failures",
            "status_wasted",
            "ordinary_actions",
            "voluntary_switches",
            "completed_voluntary_switches",
            "matchup_improving_switches",
            "setup_uses",
        ):
            setattr(self, name, getattr(self, name) + getattr(other, name))
        for name, count in other.setup_move_counts.items():
            self.setup_move_counts[name] = self.setup_move_counts.get(name, 0) + count
        self.decision_quality.merge(other.decision_quality)
        for ratio in other.effectiveness_ratios:
            self.effectiveness_ratio_sum += ratio
            self.effectiveness_ratios.append(ratio)

    def report(self) -> dict[str, Any]:
        result = asdict(self)
        result.pop("effectiveness_ratios")
        result.pop("decision_quality")
        result.update(self.decision_quality.report())
        result["mean_move_effectiveness_vs_best"] = (
            self.effectiveness_ratio_sum / self.damaging_moves
            if self.damaging_moves
            else None
        )
        result["best_move_choice_rate"] = (
            self.best_effectiveness_choices / self.damaging_moves
            if self.damaging_moves
            else None
        )
        result["status_success_rate"] = (
            self.status_successes / self.status_uses if self.status_uses else None
        )
        result["voluntary_switch_rate"] = (
            self.voluntary_switches / self.ordinary_actions
            if self.ordinary_actions
            else None
        )
        result["setup_use_rate"] = (
            self.setup_uses / self.ordinary_actions if self.ordinary_actions else None
        )
        result["switch_completion_rate"] = (
            self.completed_voluntary_switches / self.voluntary_switches
            if self.voluntary_switches
            else None
        )
        result["matchup_improvement_rate"] = (
            self.matchup_improving_switches / self.completed_voluntary_switches
            if self.completed_voluntary_switches
            else None
        )
        return result


@dataclass
class Replay:
    lines: list[str] = field(default_factory=list)

    def add(self, line: str) -> None:
        self.lines.append(line)

    def text(self) -> str:
        return "\n".join(self.lines) + "\n"


@dataclass
class _FastArenaEpisode:
    game: int
    candidate_player: bool
    player: BattleTransformer | None
    enemy: BattleTransformer | None
    selection_rng: random.Random | None
    chance_rng: random.Random | None
    player_size: int
    enemy_size: int
    level100: bool
    campaign_index: int
    snapshot: Any
    result: int | None = None
    stop: str = "truncated"
    reason: str | None = None
    initial: dict[str, Any] | None = None
    final: dict[str, Any] | None = None
    timeline: list[dict[str, Any]] = field(default_factory=list)
    inspection: dict[str, Any] | None = None


@dataclass
class _TracedArenaEpisode(_FastArenaEpisode):
    replay: Replay | None = None
    replay_path: Path | None = None
    candidate_metrics: SkillMetrics = field(default_factory=SkillMetrics)
    baseline_metrics: SkillMetrics = field(default_factory=SkillMetrics)


def _compact_inspection(inspection: dict[str, Any]) -> dict[str, Any]:
    def side(name: str) -> dict[str, Any]:
        source = inspection[name]
        return {
            "active": source["active"],
            "party": [dict(member) for member in source["party"]],
            "moves": [dict(move) for move in source["moves"]],
            "stages": list(source["stages"]),
            "volatile": list(source["volatile"]),
        }

    return {
        "request": inspection["request"],
        "player": side("player"),
        "enemy": side("enemy"),
        "events": [dict(event) for event in inspection.get("events", [])],
    }


def _choice_detail(
    inspection: dict[str, Any], side_name: str, action: int
) -> dict[str, Any]:
    side = inspection[side_name]
    active_index = int(side["active"])
    party = side["party"]
    active = party[active_index]
    detail: dict[str, Any] = {
        "action": action,
        "actor": active["name"],
        "actor_slot": active_index,
    }
    if 0 <= action < 4:
        moves = side.get("moves", [])
        move = moves[action] if action < len(moves) else None
        return {**detail, "kind": "move", "move": dict(move) if move else None}
    if 4 <= action < 10:
        target_index = action - 4
        target = party[target_index] if target_index < len(party) else None
        return {
            **detail,
            "kind": "switch",
            "target_slot": target_index,
            "target": target["name"] if target else None,
        }
    return {
        **detail,
        "kind": {10: "no-action", 11: "struggle", 12: "run"}.get(action, "unknown"),
    }


def _compact_turn_inspection(inspection: dict[str, Any]) -> dict[str, Any]:
    def side_state(name: str) -> dict[str, Any]:
        side = inspection[name]
        active_index = int(side["active"])
        active = side["party"][active_index]
        return {
            "active": active_index,
            "name": active["name"],
            "hp": active["hp"],
            "max_hp": active["max_hp"],
            "status": active["status"],
            "party": [
                {
                    "name": member["name"],
                    "hp": member["hp"],
                    "max_hp": member["max_hp"],
                    "status": member["status"],
                }
                for member in side["party"]
            ],
        }

    return {
        "request": inspection["request"],
        "player": side_state("player"),
        "enemy": side_state("enemy"),
        "events": [dict(event) for event in inspection.get("events", [])],
    }


def _joint_search_config(config: ArenaConfig) -> JointSearchConfig:
    return JointSearchConfig(
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
    )


def _rmplus_search_many(
    server: SearchServer,
    episodes: list[_FastArenaEpisode],
    config: ArenaConfig,
) -> list[SearchResult]:
    search_config = _joint_search_config(config)
    return SimultaneousTreeSearch.search_many(
        [
            SimultaneousTreeSearch(
                server,
                episode.player,
                episode.enemy,
                search_config,
                episode.selection_rng,
                episode.chance_rng,
            )
            for episode in episodes
        ],
        [episode.snapshot for episode in episodes],
        sample_actions=True,
    )


def _policy_priors(
    network: Any,
    features: list[Any],
    masks: list[int],
    requests: list[str],
    config: ArenaConfig,
) -> list[list[float]]:
    size = config.inference_batch_size
    policies: list[list[float]] = []
    for start in range(0, len(features), size):
        batch_policies, _ = network.evaluate(
            features[start : start + size], masks[start : start + size]
        )
        policies.extend(batch_policies)
    scale = (
        config.redundant_action_prior_scale
        if isinstance(network, BattleTransformer)
        else 1.0
    )
    return [
        shape_redundant_action_priors(policy, feature, mask, scale)
        if request == "battle"
        else policy
        for policy, feature, mask, request in zip(
            policies, features, masks, requests, strict=True
        )
    ]


def _argmax_legal(policy: list[float], mask: int) -> int:
    legal = legal_actions(mask, len(policy))
    if not legal:
        raise ValueError("policy argmax requires at least one legal action")
    # Ties break to the lowest action so the lane stays deterministic.
    return max(legal, key=lambda action: (policy[action], -action))


def _policy_argmax_actions(
    episodes: list[_FastArenaEpisode],
    config: ArenaConfig,
) -> list[SearchResult]:
    """Play each side's own network priors greedily, without any search."""
    priors: dict[str, list[list[float]]] = {
        "player": [[] for _ in episodes],
        "enemy": [[] for _ in episodes],
    }
    for side in ("player", "enemy"):
        groups: dict[int, tuple[Any, list[int]]] = {}
        for index, episode in enumerate(episodes):
            network = getattr(episode, side)
            entry = groups.setdefault(id(network), (network, []))
            entry[1].append(index)
        for network, indexes in groups.values():
            snapshots = [episodes[index].snapshot for index in indexes]
            shaped = _policy_priors(
                network,
                [getattr(snapshot, f"{side}_features") for snapshot in snapshots],
                [getattr(snapshot, f"{side}_mask") for snapshot in snapshots],
                [snapshot.request for snapshot in snapshots],
                config,
            )
            for index, policy in zip(indexes, shaped, strict=True):
                priors[side][index] = policy
    results: list[SearchResult] = []
    for index, episode in enumerate(episodes):
        player_policy = priors["player"][index]
        enemy_policy = priors["enemy"][index]
        results.append(
            SearchResult(
                player_policy=tuple(player_policy),
                enemy_policy=tuple(enemy_policy),
                player_action=_argmax_legal(
                    player_policy, episode.snapshot.player_mask
                ),
                enemy_action=_argmax_legal(enemy_policy, episode.snapshot.enemy_mask),
                root_value=0.0,
                nodes=0,
                solver="network-policy-argmax-v1",
                exploitability=None,
                payoff_spread=None,
                payoff_matrix=None,
            )
        )
    return results


def _legal(mask: int, action: int) -> bool:
    return bool(mask & (1 << action))


def _move_score(move: dict[str, Any]) -> int:
    return int(move["power"]) * int(move["effectiveness"]) * int(move["accuracy"])


def _is_status(move: dict[str, Any]) -> bool:
    return int(move["power"]) == 0 and int(move["id"]) not in _FIXED_DAMAGE_MOVES


def _setup_move_name(move: dict[str, Any]) -> str | None:
    move_id = int(move["id"])
    if move_id not in _SETUP_MOVE_IDS:
        return None
    return str(move.get("name") or f"move-{move_id}")


def _active(side: dict[str, Any]) -> dict[str, Any]:
    return side["party"][side["active"]]


def _best_damage_score(side: dict[str, Any], mask: int) -> int:
    return max(
        (
            _move_score(move)
            for slot, move in enumerate(side["moves"])
            if _legal(mask, slot) and int(move["power"]) > 0
        ),
        default=0,
    )


def _matchup_advantage(inspection: dict[str, Any], side_index: int) -> int:
    own_name = "player" if side_index == 0 else "enemy"
    opponent_name = "enemy" if side_index == 0 else "player"
    own_mask = inspection[f"{own_name}_mask"]
    opponent_mask = inspection[f"{opponent_name}_mask"]
    return _best_damage_score(inspection[own_name], own_mask) - _best_damage_score(
        inspection[opponent_name], opponent_mask
    )


def _effect_actors(events: list[dict[str, Any]]) -> tuple[set[int], set[int]]:
    current: int | None = None
    successful: set[int] = set()
    blocked: set[int] = set()
    for event in events:
        if event["kind"] == "action":
            current = int(event["side"])
        elif event["kind"] == "status-blocked":
            blocked.add(int(event["side"]))
        elif event["kind"] in _SUCCESS_EVENTS and current is not None:
            successful.add(current)
    return successful, blocked


def _update_side_metrics(
    metrics: SkillMetrics,
    side_index: int,
    action: int,
    features: Any,
    before: dict[str, Any],
    after: dict[str, Any],
    request: str,
) -> None:
    side_name = "player" if side_index == 0 else "enemy"
    mask = before[f"{side_name}_mask"]
    if request == "battle":
        metrics.ordinary_actions += 1
    if request == "battle" and 0 <= action < 4:
        quality_flags = classify_feature_decision(features, action)
        metrics.decision_quality.observe(quality_flags)
        move = before[side_name]["moves"][action]
        setup_name = _setup_move_name(move)
        if setup_name is not None:
            metrics.setup_uses += 1
            metrics.setup_move_counts[setup_name] = (
                metrics.setup_move_counts.get(setup_name, 0) + 1
            )
        if int(move["power"]) > 0 and not quality_flags.ohko_into_faster:
            chosen = _move_score(move)
            best = _best_damage_score(before[side_name], mask)
            metrics.damaging_moves += 1
            if best:
                ratio = chosen / best
                metrics.effectiveness_ratio_sum += ratio
                metrics.effectiveness_ratios.append(ratio)
                if chosen == best:
                    metrics.best_effectiveness_choices += 1
            if int(move["effectiveness"]) > 100:
                metrics.super_effective_choices += 1
        elif _is_status(move) and not (
            quality_flags.redundant_status_same
            or quality_flags.redundant_status_other
            or quality_flags.capped_stat_setup
        ):
            metrics.status_uses += 1
            successful, blocked = _effect_actors(after["events"])
            if side_index in successful:
                metrics.status_successes += 1
            elif side_index in blocked:
                metrics.status_failures += 1
            else:
                metrics.status_wasted += 1
    elif request == "battle" and 4 <= action < 10:
        metrics.voluntary_switches += 1
        completed = after[side_name]["active"] != before[side_name]["active"]
        if completed:
            metrics.completed_voluntary_switches += 1
            if _matchup_advantage(after, side_index) > _matchup_advantage(
                before, side_index
            ):
                metrics.matchup_improving_switches += 1


def _preview(replay: Replay, inspection: dict[str, Any]) -> None:
    replay.add("|player|p1|Player 1")
    replay.add("|player|p2|Player 2")
    replay.add(f"|teamsize|p1|{len(inspection['player']['party'])}")
    replay.add(f"|teamsize|p2|{len(inspection['enemy']['party'])}")
    replay.add("|gametype|singles")
    replay.add("|gen|1")
    replay.add("|tier|[Gen 1] Full Link Variable Party")
    for code, name in (("p1", "player"), ("p2", "enemy")):
        for mon in inspection[name]["party"]:
            replay.add(f"|poke|{code}|{mon['name']}, L{mon['level']}|")
    replay.add("|teampreview")
    replay.add("|start")
    for code, name in (("p1", "player"), ("p2", "enemy")):
        mon = _active(inspection[name])
        replay.add(
            f"|switch|{code}a: {mon['name']}|{mon['name']}, L{mon['level']}|"
            f"{mon['hp']}/{mon['max_hp']}"
        )


def _action_line(
    replay: Replay,
    side_index: int,
    action: int,
    inspection: dict[str, Any],
    request: str,
) -> None:
    side_name = "player" if side_index == 0 else "enemy"
    opponent_name = "enemy" if side_index == 0 else "player"
    code = "p1" if side_index == 0 else "p2"
    opponent_code = "p2" if side_index == 0 else "p1"
    actor = _active(inspection[side_name])
    target = _active(inspection[opponent_name])
    if request.startswith("mimic"):
        move = inspection[opponent_name]["moves"][action]
        replay.add(f"|-message|{code} selected {move['name']} for Mimic.")
    elif action < 4:
        move = inspection[side_name]["moves"][action]
        replay.add(
            f"|move|{code}a: {actor['name']}|{move['name']}|"
            f"{opponent_code}a: {target['name']}"
        )
    elif 4 <= action < 10:
        mon = inspection[side_name]["party"][action - 4]
        replay.add(f"|-message|{code} requested a switch to {mon['name']}.")
    elif action == 11:
        replay.add(
            f"|move|{code}a: {actor['name']}|Struggle|"
            f"{opponent_code}a: {target['name']}"
        )


def _event_lines(
    replay: Replay, before: dict[str, Any], inspection: dict[str, Any]
) -> None:
    explicit_switches = {
        int(event["side"])
        for event in inspection["events"]
        if event["kind"] == "switch"
    }
    for side_index, side_name, code in (
        (0, "player", "p1"),
        (1, "enemy", "p2"),
    ):
        if (
            side_index not in explicit_switches
            and before[side_name]["active"] != inspection[side_name]["active"]
        ):
            switched = _active(inspection[side_name])
            replay.add(
                f"|switch|{code}a: {switched['name']}|{switched['name']}, "
                f"L{switched['level']}|{switched['hp']}/{switched['max_hp']}"
            )
    for event in inspection["events"]:
        kind = event["kind"]
        side_index = int(event.get("side", 0))
        side_name = "player" if side_index == 0 else "enemy"
        code = "p1" if side_index == 0 else "p2"
        mon = _active(inspection[side_name])
        if kind == "damage":
            replay.add(f"|-damage|{code}a: {mon['name']}|{event['hp']}/{mon['max_hp']}")
        elif kind == "faint":
            replay.add(f"|faint|{code}a: {mon['name']}")
        elif kind == "switch":
            switched = inspection[side_name]["party"][int(event["target"])]
            replay.add(
                f"|switch|{code}a: {switched['name']}|{switched['name']}, "
                f"L{switched['level']}|{switched['hp']}/{switched['max_hp']}"
            )
        elif kind == "status-applied":
            replay.add(f"|-status|{code}a: {mon['name']}|0x{int(event['value']):02x}")
        elif kind == "status-blocked":
            replay.add(f"|cant|{code}a: {mon['name']}|status")
        elif kind in _SUCCESS_EVENTS:
            replay.add(f"|-message|{kind} resolved.")


def _paired_coordinates(seed: int, seed_count: int, game: int) -> tuple[int, int]:
    pair = game // 2
    seed_index = pair % seed_count
    sample_index = pair // seed_count
    return seed + 90_000_000 + seed_index * 1_000_003, sample_index


def _mean_ci95(values: list[float]) -> tuple[float, float]:
    mean = sum(values) / len(values)
    if len(values) < 2:
        return mean, mean
    variance = sum((value - mean) ** 2 for value in values) / (len(values) - 1)
    radius = 1.96 * math.sqrt(variance / len(values))
    return max(0.0, mean - radius), min(1.0, mean + radius)


def _score_moments(values: list[float]) -> list[float | int]:
    # Sufficient statistics for pooling paired scores across arenas without
    # persisting the raw per-pair lists.
    return [
        float(sum(values)),
        float(sum(value * value for value in values)),
        len(values),
    ]


def _pair_outcome_report(pair_scores: list[float]) -> dict[str, int | float | None]:
    # Gate sensitivity: only pairs that deviate from 0.5 carry promotion
    # evidence, so surface how many side-swapped pairs mirrored exactly.
    pairs = len(pair_scores)
    candidate_sweeps = sum(1 for score in pair_scores if score == 1.0)
    incumbent_sweeps = sum(1 for score in pair_scores if score == 0.0)
    balanced = sum(1 for score in pair_scores if score == 0.5)
    candidate_leaning = sum(1 for score in pair_scores if score > 0.5)
    incumbent_leaning = sum(1 for score in pair_scores if score < 0.5)
    decisive = candidate_leaning + incumbent_leaning
    return {
        "pairs": pairs,
        "candidate_sweeps": candidate_sweeps,
        "incumbent_sweeps": incumbent_sweeps,
        "balanced": balanced,
        "mixed": pairs - candidate_sweeps - incumbent_sweeps - balanced,
        "decisive": decisive,
        "decisive_fraction": decisive / pairs if pairs else None,
        "decisive_candidate_share": (
            candidate_leaning / decisive if decisive else None
        ),
        "decisive_sign_z": (
            (candidate_leaning - incumbent_leaning) / math.sqrt(decisive)
            if decisive
            else None
        ),
    }


def _battle_finished(battle: dict[str, Any]) -> bool:
    # Mirrors the paired-arena scoring branch order: an infrastructure stop is a
    # non-finish even when the engine still reported a result for the episode.
    if battle["stop"] in ("mechanics-timeout", "semantic-divergence"):
        return False
    return battle["candidate_return"] in (1, -1, 0)


def _finished_pair_scores(battles: list[dict[str, Any]]) -> list[float]:
    legs_by_pair: dict[int, list[dict[str, Any]]] = {}
    for battle in battles:
        legs_by_pair.setdefault(battle["pair"], []).append(battle)
    scores = []
    for pair in sorted(legs_by_pair):
        legs = legs_by_pair[pair]
        if len(legs) == 2 and all(_battle_finished(leg) for leg in legs):
            scores.append(sum(leg["score"] for leg in legs) / 2)
    return scores


def _evaluation_party_sizes(pair: int, schedule_version: int = 3) -> tuple[int, int]:
    return generated_party_sizes(pair, schedule_version)


def _evaluation_level100(pair: int, schedule_version: int = 3) -> bool:
    return generated_level100(pair, schedule_version)


def _generated_party_report(games: int, schedule_version: int = 3) -> dict[str, Any]:
    six_vs_six_games = 2 * sum(
        _evaluation_party_sizes(pair, schedule_version)
        == (FULL_PARTY_SIZE, FULL_PARTY_SIZE)
        for pair in range(games // 2)
    )
    level100_six_vs_six_games = 2 * sum(
        _evaluation_level100(pair, schedule_version) for pair in range(games // 2)
    )
    denominator = 4 if schedule_version == 2 else 3
    if abs(six_vs_six_games * denominator - games) > 2 * (denominator - 1):
        raise RuntimeError("generated arena 6v6 schedule differs from its target")
    if abs(level100_six_vs_six_games * denominator - six_vs_six_games) > 2 * (
        denominator - 1
    ):
        raise RuntimeError(
            "generated arena level-100 6v6 schedule differs from its target"
        )
    return {
        "party_size_schedule": generated_schedule_names(schedule_version)[0],
        "level_schedule": generated_schedule_names(schedule_version)[1],
        "target_6v6_fraction": 1 / denominator,
        "level100_6v6_fraction": 1 / denominator,
        "six_vs_six_games": six_vs_six_games,
        "level100_six_vs_six_games": level100_six_vs_six_games,
        "side_swap_complete": True,
        "candidate_player_games": games // 2,
        "candidate_enemy_games": games // 2,
    }


def _party_strata(player_size: int, enemy_size: int) -> tuple[str, ...]:
    result = []
    if player_size <= 2 and enemy_size <= 2:
        result.append("party-1to2")
    if 3 <= player_size <= 4 and 3 <= enemy_size <= 4:
        result.append("party-3to4")
    if player_size >= 5 and enemy_size >= 5:
        result.append("party-5to6")
    if player_size != enemy_size:
        result.append("unequal-party")
    return tuple(result)


_MATCHUP_FILTER_VERSION = "predicted-turn-zero-value-v1"
_MATCHUP_ATTEMPT_STRIDE = 61_000_181


def _matchup_root_seed(root_seed: int, attempt: int) -> int:
    """Attempt 0 replays the legacy reset stream; retries hop a prime lane."""
    return root_seed + attempt * _MATCHUP_ATTEMPT_STRIDE


def _abs_value_summary(values: list[float], cap: float) -> dict[str, float]:
    if not values:
        return {"mean": 0.0, "p50": 0.0, "p90": 0.0, "p99": 0.0, "lopsided_share": 0.0}
    ordered = sorted(values)

    def quantile(share: float) -> float:
        return ordered[int(share * (len(ordered) - 1))]

    return {
        "mean": sum(ordered) / len(ordered),
        "p50": quantile(0.50),
        "p90": quantile(0.90),
        "p99": quantile(0.99),
        "lopsided_share": sum(value > cap for value in ordered) / len(ordered),
    }


def _arena_matchup_plan(
    server: SearchServer,
    network: Any,
    config: ArenaConfig,
) -> tuple[dict[int, int], dict[str, Any]]:
    """Choose per-pair reset attempts whose predicted turn-zero value is contested.

    Arena games are not training data, so lopsided pairs are rejected outright:
    each one scores an exact 0.5 that dilutes the paired z toward null, and
    resampling them buys gate power at fixed game count. The incumbent probes
    every candidate reset so selection stays candidate-independent within a
    gate; both legs of a pair share the accepted attempt.
    """
    started = time.perf_counter()
    cap = config.matchup_value_cap
    total_pairs = config.games // 2
    chunk_size = max(1, config.inference_batch_size)
    accepted_attempt: dict[int, int] = {}
    accepted_value: dict[int, float] = {}
    initial_values: dict[int, float] = {}
    fallback = 0
    candidate_resets = 0
    pending = list(range(total_pairs))
    for attempt in range(config.matchup_filter_attempts):
        if not pending:
            break
        last_attempt = attempt == config.matchup_filter_attempts - 1
        survivors: list[int] = []
        for start in range(0, len(pending), chunk_size):
            chunk = pending[start : start + chunk_size]
            features = []
            masks = []
            for offset, pair in enumerate(chunk):
                player_size, enemy_size = _evaluation_party_sizes(
                    pair, config.generated_schedule_version
                )
                root_seed, reset_episode = _paired_coordinates(
                    config.seed, config.seed_count, 2 * pair
                )
                reset = server.reset if offset == 0 else server.reset_append
                snapshot = reset(
                    _matchup_root_seed(root_seed, attempt),
                    reset_episode,
                    player_size,
                    enemy_size,
                    level100=_evaluation_level100(
                        pair, config.generated_schedule_version
                    ),
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
    for pair in range(total_pairs):
        for stratum in _party_strata(
            *_evaluation_party_sizes(pair, config.generated_schedule_version)
        ):
            bucket = strata.setdefault(stratum, {"pairs": 0, "resampled": 0})
            bucket["pairs"] += 1
            bucket["resampled"] += int(pair in plan)
    stats = {
        "enabled": True,
        "filter": _MATCHUP_FILTER_VERSION,
        "cap": cap,
        "attempts": config.matchup_filter_attempts,
        "pairs": total_pairs,
        "resampled_pairs": len(plan),
        "fallback_pairs": fallback,
        "candidate_resets": candidate_resets,
        "attempt_histogram": histogram,
        "plan": {str(pair): attempt for pair, attempt in sorted(plan.items())},
        "turn_zero_abs_value": {
            "initial": _abs_value_summary(
                [initial_values[pair] for pair in range(total_pairs)], cap
            ),
            "final": _abs_value_summary(
                [accepted_value[pair] for pair in range(total_pairs)], cap
            ),
        },
        "strata": strata,
        "seconds": round(time.perf_counter() - started, 3),
    }
    return plan, stats


def _stratified_report(scores: dict[str, list[float]]) -> dict[str, Any]:
    strata: dict[str, Any] = {}
    for name in ("party-1to2", "party-3to4", "party-5to6", "unequal-party"):
        values = scores[name]
        if values:
            low, high = _mean_ci95(values)
            score = sum(values) / len(values)
            passed = score >= 0.45 and low >= 0.35
        else:
            low = high = score = None
            passed = False
        strata[name] = {
            "pairs": len(values),
            "score": score,
            "paired_score_ci95": [low, high],
            "minimum_score": 0.45,
            "minimum_ci95_low": 0.35,
            "pass": passed,
        }
    return {"pass": all(row["pass"] for row in strata.values()), "groups": strata}


def _campaign_report(
    scores: dict[int, list[float]], robust_score: float
) -> dict[str, Any]:
    """Veto promotion per campaign case only where a deficit was witnessed.

    A campaign arena splits its pairs nine ways, so a single case carries a
    handful of them and its point estimate is mostly noise.  Vetoing on the
    point estimate therefore blocks a candidate roughly as often when it is
    even as when it is behind, and one such case sinks the whole gate.  The
    case must clear the floor across its paired interval before it counts as
    evidence of a deficit; the well-powered overall score is what carries the
    positive claim.
    """
    cases: dict[str, Any] = {}
    for index, name in enumerate(_CAMPAIGN_NAMES):
        values = scores.get(index, [])
        if values:
            low, high = _mean_ci95(values)
            case_score = sum(values) / len(values)
        else:
            low = high = case_score = None
        cases[name] = {
            "pairs": len(values),
            "score": case_score,
            "paired_score_ci95": [low, high],
            "pass": high is not None and high >= 0.40,
        }
    return {
        "pass": robust_score >= 0.45 and all(case["pass"] for case in cases.values()),
        "minimum_overall_score": 0.45,
        "minimum_case_ci95_high": 0.40,
        "cases": cases,
    }


def _arena_batch_spans(games: int, batch_size: int) -> list[tuple[int, int]]:
    """Slice games into the exact server-level batches a sequential run uses."""
    if batch_size < 2 or batch_size % 2:
        raise ValueError("arena batch size must be a positive even number")
    return [
        (start, min(games, start + batch_size)) for start in range(0, games, batch_size)
    ]


def _arena_span_partition(
    spans: list[tuple[int, int]], processes: int
) -> list[list[tuple[int, int]]]:
    return [spans[process::processes] for process in range(processes)]


def _arena_parallel_batch_size(games: int, maximum: int, processes: int) -> int:
    """Keep every worker useful without exceeding the proven batch ceiling."""
    if games < 2 or games % 2:
        raise ValueError("parallel arena games must be a positive even number")
    if maximum < 2 or maximum % 2:
        raise ValueError("parallel arena maximum batch must be positive and even")
    if processes < 1:
        raise ValueError("parallel arena processes must be positive")
    useful_processes = min(processes, games // 2)
    waves = math.ceil(games / (maximum * useful_processes))
    target_spans = useful_processes * waves
    pairs_per_span = math.ceil((games // 2) / target_spans)
    return min(maximum, 2 * pairs_per_span)


def _serialized_arena_model(model: BattleTransformer) -> dict[str, Any]:
    if not isinstance(model, BattleTransformer):
        raise TypeError("parallel arena evaluation requires transformer models")
    return {
        "config": asdict(model.config),
        "state": {
            name: value.detach().cpu() for name, value in model.state_dict().items()
        },
        "engine": model.inference_engine,
    }


def _load_arena_model(
    record: dict[str, Any], device: torch.device
) -> BattleTransformer:
    network = BattleTransformer(TransformerConfig(**record["config"])).to(device)
    network.load_state_dict(record["state"])
    network.eval()
    network.configure_inference(record["engine"])
    return network


def _slim_arena_episode(episode: _FastArenaEpisode) -> _FastArenaEpisode:
    """Keep only the fields the reports read so results pickle cheaply."""
    return _FastArenaEpisode(
        game=episode.game,
        candidate_player=episode.candidate_player,
        player=None,
        enemy=None,
        selection_rng=None,
        chance_rng=None,
        player_size=episode.player_size,
        enemy_size=episode.enemy_size,
        level100=episode.level100,
        campaign_index=episode.campaign_index,
        snapshot=None,
        result=episode.result,
        stop=episode.stop,
        reason=episode.reason,
        initial=episode.initial,
        final=episode.final,
        timeline=episode.timeline,
        inspection=None,
    )


def _arena_battle_record(
    episode: _FastArenaEpisode,
    config: ArenaConfig,
    campaign: bool,
    *,
    capture_details: bool = False,
) -> dict[str, Any]:
    candidate_result = (
        episode.result
        if episode.candidate_player or episode.result is None
        else -episode.result
    )
    if episode.stop in {"mechanics-timeout", "semantic-divergence"}:
        score = 0.0
    elif candidate_result == 1:
        score = 1.0
    elif candidate_result == -1:
        score = 0.0
    elif candidate_result == 0:
        score = 0.5
    else:
        score = 0.0
    battle = {
        "game": episode.game,
        "pair": episode.game // 2,
        "candidate_side": "player" if episode.candidate_player else "enemy",
        "player_party_size": episode.player_size,
        "enemy_party_size": episode.enemy_size,
        "level_profile": "level100" if episode.level100 else "distributed",
        "campaign": (_CAMPAIGN_NAMES[episode.campaign_index] if campaign else None),
        "stop": episode.stop,
        "reason": (
            episode.reason
            if episode.reason is not None
            else (
                f"decision-horizon-{config.budget}"
                if episode.stop == "truncated"
                else None
            )
        ),
        "candidate_return": candidate_result,
        "score": score,
    }
    if capture_details:
        battle["initial"] = episode.initial
        battle["final"] = episode.final
        battle["timeline"] = episode.timeline
    return battle


def _live_arena_report(
    episodes: list[_FastArenaEpisode],
    config: ArenaConfig,
    campaign: bool,
    recent_battles: int,
) -> dict[str, Any]:
    battles = [
        _arena_battle_record(episode, config, campaign)
        for episode in sorted(episodes, key=lambda item: item.game)
    ]
    scored = [
        battle
        for battle in battles
        if battle["stop"] not in {"semantic-divergence", "mechanics-timeout"}
    ]
    wins = sum(battle["candidate_return"] == 1 for battle in scored)
    losses = sum(battle["candidate_return"] == -1 for battle in scored)
    draws = sum(battle["candidate_return"] == 0 for battle in scored)
    semantic_divergences = sum(
        battle["stop"] == "semantic-divergence" for battle in battles
    )
    mechanics_timeouts = sum(
        battle["stop"] == "mechanics-timeout" for battle in battles
    )
    truncated = (
        len(battles) - wins - losses - draws - semantic_divergences - mechanics_timeouts
    )
    pair_scores: dict[int, list[float]] = {}
    for battle in battles:
        pair_scores.setdefault(int(battle["pair"]), []).append(float(battle["score"]))
    complete_pair_scores = [
        sum(values) / 2 for values in pair_scores.values() if len(values) == 2
    ]
    return {
        "finished": wins + losses + draws,
        "wins": wins,
        "losses": losses,
        "draws": draws,
        "truncated": truncated,
        "semantic_divergences": semantic_divergences,
        "mechanics_timeouts": mechanics_timeouts,
        "score_sum": float(sum(battle["score"] for battle in battles)),
        "pair_score_sum": float(sum(complete_pair_scores)),
        "pair_score_sumsq": float(sum(score * score for score in complete_pair_scores)),
        "pairs": len(complete_pair_scores),
        "recent_battles": battles[-recent_battles:],
    }


_ARENA_PROCESS_MODELS: tuple[BattleTransformer, BattleTransformer] | None = None


def _initialize_arena_process(payload_path: str) -> None:
    """Load both evaluation models once for all stages in this worker."""
    global _ARENA_PROCESS_MODELS
    torch.set_num_threads(1)
    payload = torch.load(payload_path, map_location="cpu", weights_only=False)
    device = choose_device(payload["device"])
    _ARENA_PROCESS_MODELS = (
        _load_arena_model(payload["candidate"], device),
        _load_arena_model(payload["baseline"], device),
    )


def _arena_process_task(
    mode: str,
    config: ArenaConfig,
    campaign: bool,
    capture_details: bool,
    replay_dir: Path | None,
    spans: list[tuple[int, int]],
    telemetry: ArenaTelemetry | None,
    telemetry_path: Path | None,
    process: int,
    assigned_games: int,
) -> list[_FastArenaEpisode] | list[_TracedArenaEpisode]:
    if _ARENA_PROCESS_MODELS is None:
        raise RuntimeError("arena process models were not initialized")
    configure_determinism(config.seed)
    candidate, baseline = _ARENA_PROCESS_MODELS
    if mode == "fast":
        live_episodes: list[_FastArenaEpisode] = []
        seen_games: set[int] = set()
        last_publish = 0.0

        def publish(force: bool = False) -> None:
            nonlocal last_publish
            if telemetry is None or telemetry_path is None:
                return
            now = time.monotonic()
            if not force and now - last_publish < 1.0:
                return
            report = _live_arena_report(
                live_episodes, config, campaign, telemetry.recent_battles
            )
            write_actor_progress(
                telemetry_path,
                process,
                len(live_episodes),
                assigned_games,
                stage=telemetry.stage,
                iteration=telemetry.iteration,
                arena_games=config.games,
                **report,
            )
            last_publish = now

        def episode_progress(episodes: list[_FastArenaEpisode]) -> None:
            fresh = [episode for episode in episodes if episode.game not in seen_games]
            if not fresh:
                return
            seen_games.update(episode.game for episode in fresh)
            live_episodes.extend(fresh)
            publish()

        episodes = _run_fast_arena_spans(
            candidate,
            baseline,
            config,
            campaign,
            spans,
            capture_details,
            episode_progress=episode_progress if telemetry is not None else None,
        )
        publish(force=True)
        return [_slim_arena_episode(episode) for episode in episodes]
    if mode == "traced":
        return [
            _slim_traced_episode(episode)
            for episode in _run_traced_arena_spans(
                candidate, baseline, config, replay_dir, spans
            )
        ]
    raise ValueError(f"unknown arena process mode: {mode}")


class ArenaEvaluationPool:
    """Persistent spawned workers shared by one iteration's evaluation stages."""

    def __init__(
        self,
        candidate: BattleTransformer,
        baseline: BattleTransformer,
        processes: int,
    ) -> None:
        if not 1 <= processes <= 16:
            raise ValueError("arena pool processes must be in 1..16")
        self.processes = processes
        self._temporary = tempfile.TemporaryDirectory(prefix="arena-eval-pool-")
        payload_path = Path(self._temporary.name) / "models.pt"
        torch.save(
            {
                "device": str(next(candidate.parameters()).device),
                "candidate": _serialized_arena_model(candidate),
                "baseline": _serialized_arena_model(baseline),
            },
            payload_path,
        )
        self._executor = ProcessPoolExecutor(
            max_workers=processes,
            mp_context=multiprocessing.get_context("spawn"),
            initializer=_initialize_arena_process,
            initargs=(str(payload_path),),
        )
        self._closed = False

    def _run(
        self,
        mode: str,
        config: ArenaConfig,
        spans: list[tuple[int, int]],
        *,
        campaign: bool = False,
        capture_details: bool = False,
        replay_dir: Path | None = None,
        progress: Callable[[int, int], None] | None = None,
        telemetry: ArenaTelemetry | None = None,
    ) -> list[_FastArenaEpisode] | list[_TracedArenaEpisode]:
        if self._closed:
            raise RuntimeError("arena evaluation pool is closed")
        if telemetry is not None:
            if mode != "fast":
                raise ValueError("live arena telemetry requires fast evaluation")
            telemetry.directory.mkdir(parents=True, exist_ok=True)
            pattern = f"arena-{telemetry.stage}-{telemetry.iteration:03d}-*.json"
            for path in telemetry.directory.glob(pattern):
                path.unlink()
        partitions = [
            rows for rows in _arena_span_partition(spans, self.processes) if rows
        ]
        futures = {
            self._executor.submit(
                _arena_process_task,
                mode,
                config,
                campaign,
                capture_details,
                replay_dir,
                rows,
                telemetry,
                (
                    telemetry.directory
                    / (
                        f"arena-{telemetry.stage}-{telemetry.iteration:03d}-"
                        f"{process:02d}.json"
                    )
                    if telemetry is not None
                    else None
                ),
                process,
                sum(stop - start for start, stop in rows),
            ): sum(stop - start for start, stop in rows)
            for process, rows in enumerate(partitions)
        }
        episodes: list[_FastArenaEpisode] | list[_TracedArenaEpisode] = []
        completed = 0
        for future in as_completed(futures):
            episodes.extend(future.result())
            completed += futures[future]
            if progress is not None:
                progress(completed, config.games)
        return sorted(episodes, key=lambda episode: episode.game)

    def run_fast(
        self,
        config: ArenaConfig,
        campaign: bool,
        spans: list[tuple[int, int]],
        capture_details: bool,
        progress: Callable[[int, int], None] | None = None,
        telemetry: ArenaTelemetry | None = None,
    ) -> list[_FastArenaEpisode]:
        return list(
            self._run(
                "fast",
                config,
                spans,
                campaign=campaign,
                capture_details=capture_details,
                progress=progress,
                telemetry=telemetry,
            )
        )

    def run_traced(
        self,
        config: ArenaConfig,
        replay_dir: Path | None,
        spans: list[tuple[int, int]],
        progress: Callable[[int, int], None] | None = None,
    ) -> list[_TracedArenaEpisode]:
        return list(
            self._run(
                "traced",
                config,
                spans,
                replay_dir=replay_dir,
                progress=progress,
            )
        )

    def close(self) -> None:
        if self._closed:
            return
        self._executor.shutdown()
        self._temporary.cleanup()
        self._closed = True

    def __enter__(self) -> Self:
        return self

    def __exit__(self, *_: object) -> None:
        self.close()


def _run_fast_arena_parallel(
    candidate: BattleTransformer,
    baseline: BattleTransformer,
    config: ArenaConfig,
    campaign: bool,
    spans: list[tuple[int, int]],
    capture_details: bool,
    processes: int,
    progress: Callable[[int, int], None] | None = None,
    telemetry: ArenaTelemetry | None = None,
) -> list[_FastArenaEpisode]:
    with ArenaEvaluationPool(candidate, baseline, processes) as pool:
        return pool.run_fast(
            config,
            campaign,
            spans,
            capture_details,
            progress=progress,
            telemetry=telemetry,
        )


def _run_fast_arena_games(
    candidate: BattleTransformer,
    baseline: BattleTransformer,
    config: ArenaConfig,
    campaign: bool,
    batch_size: int = 128,
    capture_details: bool = False,
    processes: int = 1,
    pool: ArenaEvaluationPool | None = None,
    progress: Callable[[int, int], None] | None = None,
    telemetry: ArenaTelemetry | None = None,
) -> list[_FastArenaEpisode]:
    parallelism = pool.processes if pool is not None else processes
    if parallelism > 1:
        batch_size = _arena_parallel_batch_size(config.games, batch_size, parallelism)
    spans = _arena_batch_spans(config.games, batch_size)
    if pool is not None:
        return pool.run_fast(
            config,
            campaign,
            spans,
            capture_details,
            progress=progress,
            telemetry=telemetry,
        )
    if processes > 1 and len(spans) > 1:
        return _run_fast_arena_parallel(
            candidate,
            baseline,
            config,
            campaign,
            spans,
            capture_details,
            processes,
            progress,
            telemetry,
        )
    episodes = _run_fast_arena_spans(
        candidate, baseline, config, campaign, spans, capture_details
    )
    if progress is not None:
        progress(config.games, config.games)
    return episodes


def _run_fast_arena_spans(
    candidate: BattleTransformer,
    baseline: BattleTransformer,
    config: ArenaConfig,
    campaign: bool,
    spans: list[tuple[int, int]],
    capture_details: bool,
    episode_progress: Callable[[list[_FastArenaEpisode]], None] | None = None,
) -> list[_FastArenaEpisode]:
    budget = config.budget
    seed = config.seed
    seed_count = config.seed_count
    completed: list[_FastArenaEpisode] = []
    server = SearchServer(popular_gate=config.popular_gate)
    try:
        for batch_start, batch_stop in spans:
            episodes = []
            for game in range(batch_start, batch_stop):
                pair = game // 2
                candidate_player = game % 2 == 0
                selection_rng = random.Random(seed + 30_000_019 + pair * 2_000_003)
                chance_rng = random.Random(seed + 40_000_033 + pair * 2_000_003)
                player_size, enemy_size = _evaluation_party_sizes(
                    pair, config.generated_schedule_version
                )
                episodes.append(
                    _FastArenaEpisode(
                        game=game,
                        candidate_player=candidate_player,
                        player=candidate if candidate_player else baseline,
                        enemy=baseline if candidate_player else candidate,
                        selection_rng=selection_rng,
                        chance_rng=chance_rng,
                        player_size=player_size,
                        enemy_size=enemy_size,
                        level100=not campaign
                        and _evaluation_level100(
                            pair, config.generated_schedule_version
                        ),
                        campaign_index=pair % len(_CAMPAIGN_NAMES),
                        snapshot=None,
                    )
                )
            try:
                for offset, episode in enumerate(episodes):
                    root_seed, reset_episode = _paired_coordinates(
                        seed, seed_count, episode.game
                    )
                    if campaign:
                        reset = (
                            server.reset_campaign
                            if offset == 0
                            else server.reset_campaign_append
                        )
                        episode.snapshot = reset(
                            root_seed,
                            reset_episode,
                            episode.campaign_index,
                            balanced_final_species=config.balanced_final_species,
                        )
                    else:
                        root_seed = _matchup_root_seed(
                            root_seed,
                            (config.matchup_plan or {}).get(episode.game // 2, 0),
                        )
                        reset = server.reset if offset == 0 else server.reset_append
                        episode.snapshot = reset(
                            root_seed,
                            reset_episode,
                            episode.player_size,
                            episode.enemy_size,
                            level100=episode.level100,
                            balanced_final_species=config.balanced_final_species,
                        )
                if capture_details:
                    inspections = server.inspect_many(
                        [episode.snapshot.handle for episode in episodes]
                    )
                    for episode, inspection in zip(episodes, inspections, strict=True):
                        episode.inspection = inspection
                        episode.initial = _compact_inspection(inspection)
                active = episodes.copy()
                for decision in range(budget):
                    if not active:
                        break
                    search_results = (
                        _policy_argmax_actions(active, config)
                        if config.policy_only
                        else _rmplus_search_many(server, active, config)
                    )
                    searchable: list[_FastArenaEpisode] = []
                    available_results: list[SearchResult] = []
                    search_failures: list[_FastArenaEpisode] = []
                    for episode, result in zip(active, search_results, strict=True):
                        if result.failure is not None:
                            episode.stop = "semantic-divergence"
                            episode.reason = result.failure
                            if capture_details:
                                episode.final = _compact_inspection(episode.inspection)
                            search_failures.append(episode)
                        else:
                            searchable.append(episode)
                            available_results.append(result)
                    if episode_progress is not None and search_failures:
                        episode_progress(search_failures)
                    active = searchable
                    search_results = available_results
                    if not active:
                        break
                    actions = [
                        (result.player_action, result.enemy_action)
                        for result in search_results
                    ]
                    if capture_details:
                        for episode, result in zip(active, search_results, strict=True):
                            player_action = result.player_action
                            enemy_action = result.enemy_action
                            episode.timeline.append(
                                {
                                    "turn": decision + 1,
                                    "request": episode.snapshot.request,
                                    "before": _compact_turn_inspection(
                                        episode.inspection
                                    ),
                                    "search_solver": result.solver,
                                    "search_diagnostics": result.diagnostics,
                                    "player_action": player_action,
                                    "enemy_action": enemy_action,
                                    "player_choice": _choice_detail(
                                        episode.inspection, "player", player_action
                                    ),
                                    "enemy_choice": _choice_detail(
                                        episode.inspection, "enemy", enemy_action
                                    ),
                                    "player_legal_mask": episode.snapshot.player_mask,
                                    "enemy_legal_mask": episode.snapshot.enemy_mask,
                                    "player_state_hash": episode.snapshot.player_hash,
                                    "enemy_state_hash": episode.snapshot.enemy_hash,
                                }
                            )
                    snapshots = server.episode_steps(
                        [
                            (episode.snapshot.handle, player_action, enemy_action)
                            for episode, (player_action, enemy_action) in zip(
                                active, actions, strict=True
                            )
                        ]
                    )
                    if capture_details:
                        inspections = server.inspect_many(
                            [snapshot.handle for snapshot in snapshots]
                        )
                        for episode, inspection in zip(
                            active, inspections, strict=True
                        ):
                            episode.inspection = inspection
                            episode.timeline[-1]["after"] = _compact_turn_inspection(
                                inspection
                            )
                    survivors = []
                    stopped = []
                    for episode, snapshot in zip(active, snapshots, strict=True):
                        episode.snapshot = snapshot
                        if snapshot.divergence is not None:
                            episode.stop = "semantic-divergence"
                            episode.reason = snapshot.divergence
                            stopped.append(episode)
                        elif snapshot.done:
                            episode.result = snapshot.terminal_return
                            episode.stop = "finished"
                            stopped.append(episode)
                        else:
                            survivors.append(episode)
                    if capture_details and stopped:
                        for episode in stopped:
                            episode.final = _compact_inspection(episode.inspection)
                    if episode_progress is not None and stopped:
                        episode_progress(stopped)
                    active = survivors
                    if active:
                        compacted = server.compact_many(
                            [episode.snapshot for episode in active]
                        )
                        for episode, snapshot in zip(active, compacted, strict=True):
                            episode.snapshot = snapshot
                if capture_details and active:
                    inspections = server.inspect_many(
                        [episode.snapshot.handle for episode in active]
                    )
                    for episode, inspection in zip(active, inspections, strict=True):
                        episode.final = _compact_inspection(inspection)
            except NativeRequestTimeout:
                for episode in episodes:
                    if episode.stop == "truncated":
                        episode.stop = "mechanics-timeout"
                server.close()
                server = SearchServer(popular_gate=config.popular_gate)
            if episode_progress is not None:
                episode_progress(episodes)
            completed.extend(episodes)
    finally:
        server.close()
    return sorted(completed, key=lambda episode: episode.game)


def run_paired_arena(
    candidate: BattleTransformer,
    baseline: BattleTransformer,
    config: ArenaConfig,
    *,
    campaign: bool = False,
    capture_details: bool = False,
    processes: int = 1,
    pool: ArenaEvaluationPool | None = None,
    progress: Callable[[int, int], None] | None = None,
    telemetry: ArenaTelemetry | None = None,
) -> dict[str, Any]:
    """RM+-selected paired evaluation with nonfinishes scored as losses."""
    games = config.games
    if not 1 <= processes <= 16:
        raise ValueError("paired arena processes must be in 1..16")
    if games < 2 or games % 2:
        raise ValueError("paired arena games must be a positive even number")
    if config.seed_count < 2 or games < 2 * config.seed_count:
        raise ValueError(
            "paired arena requires at least two seeds and one pair per seed"
        )
    if not 0.0 <= config.matchup_value_cap < 1.0:
        raise ValueError("arena matchup_value_cap must be in [0, 1)")
    if config.matchup_filter_attempts < 1:
        raise ValueError("arena matchup_filter_attempts must be positive")
    if not 0 <= config.popular_gate <= 256:
        raise ValueError("arena popular_gate must be in [0, 256]")
    matchup_stats: dict[str, Any] | None = None
    if config.matchup_value_cap > 0.0 and not campaign and config.matchup_plan is None:
        # Campaign suites pin their rosters, and arena games are not training
        # data, so the contested-matchup filter probes with the incumbent and
        # hard-rejects lopsided generated pairs before any game is played. A
        # caller-supplied plan already fixes the resets, and re-probing would
        # overwrite it with whatever this incumbent happens to prefer.
        with SearchServer(popular_gate=config.popular_gate) as probe_server:
            matchup_plan, matchup_stats = _arena_matchup_plan(
                probe_server, baseline, config
            )
        if matchup_plan:
            config = replace(config, matchup_plan=matchup_plan)
    wins = losses = draws = truncated = semantic_divergences = mechanics_timeouts = 0
    game_scores: list[float] = []
    battles: list[dict[str, Any]] = []
    pair_scores: list[float] = []
    pair_score: list[float] = []
    stratum_scores: dict[str, list[float]] = {
        "party-1to2": [],
        "party-3to4": [],
        "party-5to6": [],
        "unequal-party": [],
    }
    campaign_scores: dict[int, list[float]] = {
        index: [] for index in range(len(_CAMPAIGN_NAMES))
    }
    episodes = _run_fast_arena_games(
        candidate,
        baseline,
        config,
        campaign,
        capture_details=capture_details,
        processes=processes,
        pool=pool,
        progress=progress,
        telemetry=telemetry,
    )
    for pair in range(games // 2):
        first, second = episodes[2 * pair : 2 * pair + 2]
        if (
            first.game != 2 * pair
            or second.game != 2 * pair + 1
            or not first.candidate_player
            or second.candidate_player
            or first.player_size != second.player_size
            or first.enemy_size != second.enemy_size
            or first.level100 != second.level100
            or first.campaign_index != second.campaign_index
        ):
            raise RuntimeError("paired arena failed its complete model-side swap")
    for episode in episodes:
        battle = _arena_battle_record(
            episode, config, campaign, capture_details=capture_details
        )
        candidate_result = battle["candidate_return"]
        score = battle["score"]
        if episode.stop == "mechanics-timeout":
            mechanics_timeouts += 1
        elif episode.stop == "semantic-divergence":
            semantic_divergences += 1
        elif candidate_result == 1:
            wins += 1
        elif candidate_result == -1:
            losses += 1
        elif candidate_result == 0:
            draws += 1
        else:
            truncated += 1
        game_scores.append(score)
        battles.append(battle)
        pair_score.append(score)
        if len(pair_score) == 2:
            paired = sum(pair_score) / 2
            pair_scores.append(paired)
            if campaign:
                campaign_scores[episode.campaign_index].append(paired)
            else:
                for stratum in _party_strata(episode.player_size, episode.enemy_size):
                    stratum_scores[stratum].append(paired)
            pair_score = []
    robust_score = sum(game_scores) / games
    ci_low, ci_high = _mean_ci95(pair_scores)
    finished_pair_scores = _finished_pair_scores(battles)
    if finished_pair_scores:
        excluded_score = sum(finished_pair_scores) / len(finished_pair_scores)
        excluded_ci = list(_mean_ci95(finished_pair_scores))
    else:
        excluded_score = None
        excluded_ci = [None, None]
    finished = wins + losses + draws
    campaign_report = _campaign_report(campaign_scores, robust_score)
    campaign_report["pass"] = campaign and campaign_report["pass"]
    return {
        "games": games,
        "pairs": games // 2,
        "seed_count": config.seed_count,
        "pairing": "same-reset-complete-model-side-swap-v2",
        "action_selector": (
            "network-policy-argmax-v1"
            if config.policy_only
            else "simultaneous-matrix-root-anchored-qre-every-decision-v7"
        ),
        "search": (
            None if config.policy_only else asdict(_joint_search_config(config))
        ),
        **(
            {
                "side_swap_complete": True,
                "candidate_player_games": games // 2,
                "candidate_enemy_games": games // 2,
                "party_size_schedule": "fixed-campaign-suite-v1",
                "minimum_6v6_fraction": None,
                "six_vs_six_games": None,
            }
            if campaign
            else _generated_party_report(games, config.generated_schedule_version)
        ),
        "strata": None if campaign else _stratified_report(stratum_scores),
        "campaign": campaign_report if campaign else None,
        "matchup_filter": matchup_stats,
        "wins": wins,
        "losses": losses,
        "draws": draws,
        "truncated": truncated,
        "semantic_divergences": semantic_divergences,
        "mechanics_timeouts": mechanics_timeouts,
        "finished": finished,
        "score": (wins + 0.5 * draws) / finished if finished else None,
        "score_with_nonfinishes_as_losses": robust_score,
        "paired_score_ci95": [ci_low, ci_high],
        "paired_score_moments": _score_moments(pair_scores),
        "pair_outcomes": _pair_outcome_report(pair_scores),
        "finished_pairs": len(finished_pair_scores),
        "score_excluding_nonfinish_pairs": excluded_score,
        "paired_score_ci95_excluding_nonfinish_pairs": excluded_ci,
        "paired_score_moments_excluding_nonfinish_pairs": _score_moments(
            finished_pair_scores
        ),
        "battles": battles,
        "data_quality_pass": mechanics_timeouts == 0,
        "quality_pass": (
            mechanics_timeouts == 0
            and truncated + semantic_divergences <= max(1, math.floor(0.02 * games))
        ),
    }


def run_campaign_arena(
    candidate: BattleTransformer,
    baseline: BattleTransformer,
    config: ArenaConfig,
    *,
    processes: int = 1,
    pool: ArenaEvaluationPool | None = None,
    progress: Callable[[int, int], None] | None = None,
) -> dict[str, Any]:
    """Evaluate both model sides across the fixed patched campaign suite."""
    if config.games < 2 * len(_CAMPAIGN_NAMES):
        raise ValueError("campaign arena requires at least one pair per fixed team")
    return run_paired_arena(
        candidate,
        baseline,
        config,
        campaign=True,
        processes=processes,
        pool=pool,
        progress=progress,
    )


def _traced_summary(
    config: ArenaConfig,
    wins: int,
    losses: int,
    draws: int,
    truncated: int,
    semantic_divergences: int,
    mechanics_timeouts: int,
    game_scores: list[float],
    candidate_metrics: SkillMetrics,
    baseline_metrics: SkillMetrics,
) -> dict[str, Any]:
    finished = wins + losses + draws
    pair_scores = [
        (game_scores[index] + game_scores[index + 1]) / 2
        for index in range(0, len(game_scores), 2)
    ]
    ci_low, ci_high = _mean_ci95(pair_scores)
    stratum_scores: dict[str, list[float]] = {
        "party-1to2": [],
        "party-3to4": [],
        "party-5to6": [],
        "unequal-party": [],
    }
    for pair, score in enumerate(pair_scores):
        player_size, enemy_size = _evaluation_party_sizes(
            pair, config.generated_schedule_version
        )
        for stratum in _party_strata(player_size, enemy_size):
            stratum_scores[stratum].append(score)
    return {
        "profile": FULL_PROFILE,
        "max_party_size": FULL_PARTY_SIZE,
        **_generated_party_report(config.games, config.generated_schedule_version),
        "strata": _stratified_report(stratum_scores),
        "games": config.games,
        "wins": wins,
        "losses": losses,
        "draws": draws,
        "truncated": truncated,
        "semantic_divergences": semantic_divergences,
        "mechanics_timeouts": mechanics_timeouts,
        "data_quality_pass": mechanics_timeouts == 0,
        "quality_pass": (
            mechanics_timeouts == 0
            and truncated + semantic_divergences
            <= max(1, math.floor(0.02 * config.games))
        ),
        "finished": finished,
        "score": (wins + 0.5 * draws) / finished if finished else None,
        "score_with_nonfinishes_as_losses": sum(game_scores) / config.games,
        "paired_score_ci95": [ci_low, ci_high],
        "candidate_skills": candidate_metrics.report(),
        "baseline_skills": baseline_metrics.report(),
        "config": asdict(config),
    }


def _slim_traced_episode(episode: _TracedArenaEpisode) -> _TracedArenaEpisode:
    """Keep only the fields the traced summary reads so results pickle cheaply."""
    return _TracedArenaEpisode(
        game=episode.game,
        candidate_player=episode.candidate_player,
        player=None,
        enemy=None,
        selection_rng=None,
        chance_rng=None,
        player_size=episode.player_size,
        enemy_size=episode.enemy_size,
        level100=episode.level100,
        campaign_index=episode.campaign_index,
        snapshot=None,
        result=episode.result,
        stop=episode.stop,
        reason=episode.reason,
        inspection=None,
        replay=episode.replay,
        replay_path=episode.replay_path,
        candidate_metrics=episode.candidate_metrics,
        baseline_metrics=episode.baseline_metrics,
    )


def _run_traced_arena_parallel(
    candidate: BattleTransformer,
    baseline: BattleTransformer,
    config: ArenaConfig,
    replay_dir: Path | None,
    spans: list[tuple[int, int]],
    processes: int,
    progress: Callable[[int, int], None] | None = None,
) -> list[_TracedArenaEpisode]:
    """Fan traced batches across processes; per-pair RNGs keep games identical."""
    with ArenaEvaluationPool(candidate, baseline, processes) as pool:
        return pool.run_traced(config, replay_dir, spans, progress=progress)


def _run_traced_arena_spans(
    candidate: BattleTransformer,
    baseline: BattleTransformer,
    config: ArenaConfig,
    replay_dir: Path | None,
    spans: list[tuple[int, int]],
) -> list[_TracedArenaEpisode]:
    """Play the given server-level batches on one native search server."""
    all_episodes: list[_TracedArenaEpisode] = []
    server = SearchServer(popular_gate=config.popular_gate)
    try:
        for batch_start, batch_stop in spans:
            episodes = []
            for game in range(batch_start, batch_stop):
                pair = game // 2
                candidate_player = game % 2 == 0
                selection_rng = random.Random(
                    config.seed + 30_000_019 + pair * 2_000_003
                )
                chance_rng = random.Random(config.seed + 40_000_033 + pair * 2_000_003)
                player_size, enemy_size = _evaluation_party_sizes(
                    pair, config.generated_schedule_version
                )
                replay = Replay() if game < config.replay_games else None
                episodes.append(
                    _TracedArenaEpisode(
                        game=game,
                        candidate_player=candidate_player,
                        player=candidate if candidate_player else baseline,
                        enemy=baseline if candidate_player else candidate,
                        selection_rng=selection_rng,
                        chance_rng=chance_rng,
                        player_size=player_size,
                        enemy_size=enemy_size,
                        level100=_evaluation_level100(
                            pair, config.generated_schedule_version
                        ),
                        campaign_index=0,
                        snapshot=None,
                        replay=replay,
                        replay_path=(
                            replay_dir / f"game-{game:05d}.log"
                            if replay is not None and replay_dir is not None
                            else None
                        ),
                    )
                )
            active = episodes.copy()
            try:
                for offset, episode in enumerate(episodes):
                    root_seed, reset_episode = _paired_coordinates(
                        config.seed, config.seed_count, episode.game
                    )
                    root_seed = _matchup_root_seed(
                        root_seed,
                        (config.matchup_plan or {}).get(episode.game // 2, 0),
                    )
                    reset = server.reset if offset == 0 else server.reset_append
                    episode.snapshot = reset(
                        root_seed,
                        reset_episode,
                        episode.player_size,
                        episode.enemy_size,
                        level100=episode.level100,
                        balanced_final_species=config.balanced_final_species,
                    )
                inspections = server.inspect_many(
                    [episode.snapshot.handle for episode in active]
                )
                for episode, inspection in zip(active, inspections, strict=True):
                    inspection["player_mask"] = episode.snapshot.player_mask
                    inspection["enemy_mask"] = episode.snapshot.enemy_mask
                    episode.inspection = inspection
                    if episode.replay is not None:
                        _preview(episode.replay, inspection)
                for decision in range(config.budget):
                    if not active:
                        break
                    search_results = _rmplus_search_many(server, active, config)
                    searchable: list[_TracedArenaEpisode] = []
                    available_results: list[SearchResult] = []
                    for episode, result in zip(active, search_results, strict=True):
                        if result.failure is not None:
                            episode.stop = "semantic-divergence"
                            if episode.replay is not None:
                                episode.replay.add(
                                    "|message|RM+ search unavailable: " + result.failure
                                )
                        else:
                            searchable.append(episode)
                            available_results.append(result)
                    active = searchable
                    search_results = available_results
                    if not active:
                        break
                    actions = [
                        (result.player_action, result.enemy_action)
                        for result in search_results
                    ]
                    for episode, result in zip(active, search_results, strict=True):
                        if episode.replay is not None:
                            assert episode.inspection is not None
                            episode.replay.add(f"|turn|{decision + 1}")
                            _action_line(
                                episode.replay,
                                0,
                                result.player_action,
                                episode.inspection,
                                episode.snapshot.request,
                            )
                            _action_line(
                                episode.replay,
                                1,
                                result.enemy_action,
                                episode.inspection,
                                episode.snapshot.request,
                            )
                    snapshots = server.episode_steps(
                        [
                            (episode.snapshot.handle, player_action, enemy_action)
                            for episode, (player_action, enemy_action) in zip(
                                active, actions, strict=True
                            )
                        ]
                    )
                    inspect_episodes = [
                        episode
                        for episode, snapshot in zip(active, snapshots, strict=True)
                        if snapshot.divergence is None
                    ]
                    after_rows = server.inspect_many(
                        [
                            snapshot.handle
                            for snapshot in snapshots
                            if snapshot.divergence is None
                        ]
                    )
                    after_by_game = {
                        episode.game: inspection
                        for episode, inspection in zip(
                            inspect_episodes, after_rows, strict=True
                        )
                    }
                    survivors = []
                    for episode, snapshot, actions_row in zip(
                        active, snapshots, actions, strict=True
                    ):
                        before = episode.inspection
                        assert before is not None
                        prior_snapshot = episode.snapshot
                        episode.snapshot = snapshot
                        if snapshot.divergence is not None:
                            episode.stop = "semantic-divergence"
                            if episode.replay is not None:
                                episode.replay.add(
                                    "|message|Semantic divergence: "
                                    + snapshot.divergence
                                )
                            continue
                        after = after_by_game[episode.game]
                        after["player_mask"] = snapshot.player_mask
                        after["enemy_mask"] = snapshot.enemy_mask
                        player_action, enemy_action = actions_row
                        player_metrics = (
                            episode.candidate_metrics
                            if episode.candidate_player
                            else episode.baseline_metrics
                        )
                        enemy_metrics = (
                            episode.baseline_metrics
                            if episode.candidate_player
                            else episode.candidate_metrics
                        )
                        _update_side_metrics(
                            player_metrics,
                            0,
                            player_action,
                            prior_snapshot.player_features,
                            before,
                            after,
                            before["request"],
                        )
                        _update_side_metrics(
                            enemy_metrics,
                            1,
                            enemy_action,
                            prior_snapshot.enemy_features,
                            before,
                            after,
                            before["request"],
                        )
                        if episode.replay is not None:
                            _event_lines(episode.replay, before, after)
                        episode.inspection = after
                        if snapshot.done:
                            episode.result = snapshot.terminal_return
                            episode.stop = "finished"
                        else:
                            survivors.append(episode)
                    active = survivors
                    if active:
                        compacted = server.compact_many(
                            [episode.snapshot for episode in active]
                        )
                        for episode, snapshot in zip(active, compacted, strict=True):
                            episode.snapshot = snapshot
                    for episode in episodes:
                        if episode.replay_path is not None:
                            episode.replay_path.write_text(episode.replay.text())
            except NativeRequestTimeout as error:
                for episode in active:
                    episode.stop = "mechanics-timeout"
                    if episode.replay is not None:
                        episode.replay.add(f"|message|Mechanics timeout: {error}")
                        if episode.replay_path is not None:
                            episode.replay_path.write_text(episode.replay.text())
                server.close()
                server = SearchServer(popular_gate=config.popular_gate)
            all_episodes.extend(episodes)
    finally:
        server.close()
    return all_episodes


def _run_traced_arena_batched(
    candidate: BattleTransformer,
    baseline: BattleTransformer,
    config: ArenaConfig,
    replay_dir: Path | None,
    processes: int = 1,
    pool: ArenaEvaluationPool | None = None,
    progress: Callable[[int, int], None] | None = None,
) -> dict[str, Any]:
    candidate_metrics = SkillMetrics()
    baseline_metrics = SkillMetrics()
    if replay_dir is not None:
        replay_dir.mkdir(parents=True, exist_ok=True)
    parallelism = pool.processes if pool is not None else processes
    batch_size = (
        _arena_parallel_batch_size(config.games, 64, parallelism)
        if parallelism > 1
        else 64
    )
    spans = _arena_batch_spans(config.games, batch_size)
    if pool is not None:
        all_episodes = pool.run_traced(config, replay_dir, spans, progress=progress)
    elif processes > 1 and len(spans) > 1:
        all_episodes = _run_traced_arena_parallel(
            candidate, baseline, config, replay_dir, spans, processes, progress
        )
    else:
        all_episodes = _run_traced_arena_spans(
            candidate, baseline, config, replay_dir, spans
        )
        if progress is not None:
            progress(config.games, config.games)
    wins = losses = draws = truncated = semantic_divergences = mechanics_timeouts = 0
    game_scores = []
    for episode in sorted(all_episodes, key=lambda item: item.game):
        candidate_metrics.merge(episode.candidate_metrics)
        baseline_metrics.merge(episode.baseline_metrics)
        candidate_result = (
            episode.result
            if episode.candidate_player or episode.result is None
            else -episode.result
        )
        if episode.stop == "mechanics-timeout":
            mechanics_timeouts += 1
            score = 0.0
        elif episode.stop == "semantic-divergence":
            semantic_divergences += 1
            score = 0.0
        elif candidate_result == 1:
            wins += 1
            score = 1.0
        elif candidate_result == -1:
            losses += 1
            score = 0.0
        elif candidate_result == 0:
            draws += 1
            score = 0.5
        else:
            truncated += 1
            score = 0.0
        game_scores.append(score)
        if episode.replay is not None and episode.replay_path is not None:
            if episode.stop == "finished" and candidate_result == 1:
                episode.replay.add("|win|Candidate")
            elif episode.stop == "finished" and candidate_result == -1:
                episode.replay.add("|win|Baseline")
            elif episode.stop == "finished" and candidate_result == 0:
                episode.replay.add("|tie")
            elif episode.stop == "truncated":
                episode.replay.add(
                    "|message|Battle truncated without a terminal result."
                )
            episode.replay_path.write_text(episode.replay.text())
    result = _traced_summary(
        config,
        wins,
        losses,
        draws,
        truncated,
        semantic_divergences,
        mechanics_timeouts,
        game_scores,
        candidate_metrics,
        baseline_metrics,
    )
    result["action_selector"] = (
        "simultaneous-matrix-root-anchored-qre-every-decision-v7"
    )
    result["search"] = asdict(_joint_search_config(config))
    return result


def run_traced_arena(
    candidate: BattleTransformer,
    baseline: BattleTransformer,
    config: ArenaConfig,
    replay_dir: Path | None = None,
    *,
    processes: int = 1,
    pool: ArenaEvaluationPool | None = None,
    progress: Callable[[int, int], None] | None = None,
) -> dict[str, Any]:
    if not 1 <= processes <= 16:
        raise ValueError("traced arena processes must be in 1..16")
    if (
        config.games % 2
        or config.seed_count < 2
        or config.games < 2 * config.seed_count
    ):
        raise ValueError(
            "traced arena requires even games and at least one pair for each seed"
        )
    return _run_traced_arena_batched(
        candidate,
        baseline,
        config,
        replay_dir,
        processes=processes,
        pool=pool,
        progress=progress,
    )


def _run_traced_arena_sequential(
    candidate: BattleTransformer,
    baseline: BattleTransformer,
    config: ArenaConfig,
    replay_dir: Path | None = None,
) -> dict[str, Any]:
    if (
        config.games % 2
        or config.seed_count < 2
        or config.games < 2 * config.seed_count
    ):
        raise ValueError(
            "traced arena requires even games and at least one pair for each seed"
        )
    selection_rng = random.Random(config.seed + 0xA7E9A)
    chance_rng = random.Random(config.seed + 0xA7E9B)
    search_config = _joint_search_config(config)
    candidate_metrics = SkillMetrics()
    baseline_metrics = SkillMetrics()
    wins = losses = draws = truncated = semantic_divergences = mechanics_timeouts = 0
    game_scores: list[float] = []
    if replay_dir is not None:
        replay_dir.mkdir(parents=True, exist_ok=True)
    for episode in range(config.games):
        candidate_player = episode % 2 == 0
        player = candidate if candidate_player else baseline
        enemy = baseline if candidate_player else candidate
        pair = episode // 2
        player_size, enemy_size = _evaluation_party_sizes(
            pair, config.generated_schedule_version
        )
        replay = Replay() if episode < config.replay_games else None
        replay_path = (
            replay_dir / f"game-{episode:05d}.log"
            if replay is not None and replay_dir is not None
            else None
        )
        result_value: int | None = None
        timed_out = False
        semantic_divergence = False
        try:
            # A fresh process makes a timed-out mechanics state disposable; no
            # opaque native handle is ever reconstructed or mislabeled.
            with SearchServer(popular_gate=config.popular_gate) as server:
                root_seed, reset_episode = _paired_coordinates(
                    config.seed, config.seed_count, episode
                )
                root_seed = _matchup_root_seed(
                    root_seed, (config.matchup_plan or {}).get(pair, 0)
                )
                snapshot = server.reset(
                    root_seed,
                    reset_episode,
                    player_size,
                    enemy_size,
                    level100=_evaluation_level100(
                        pair, config.generated_schedule_version
                    ),
                    balanced_final_species=config.balanced_final_species,
                )
                initial = server.inspect(snapshot.handle)
                initial["player_mask"] = snapshot.player_mask
                initial["enemy_mask"] = snapshot.enemy_mask
                if replay is not None:
                    _preview(replay, initial)
                    if replay_path is not None:
                        replay_path.write_text(replay.text())
                for decision in range(config.budget):
                    before = server.inspect(snapshot.handle)
                    before["player_mask"] = snapshot.player_mask
                    before["enemy_mask"] = snapshot.enemy_mask
                    search = SimultaneousTreeSearch(
                        server,
                        player,
                        enemy,
                        search_config,
                        selection_rng,
                        chance_rng,
                    )
                    result = search.search(snapshot, sample_actions=True)
                    if result.failure is not None:
                        semantic_divergence = True
                        semantic_divergences += 1
                        if replay is not None:
                            replay.add(
                                "|message|RM+ search unavailable: " + result.failure
                            )
                        break
                    player_action = result.player_action
                    enemy_action = result.enemy_action
                    if replay is not None:
                        replay.add(f"|turn|{decision + 1}")
                        _action_line(replay, 0, player_action, before, snapshot.request)
                        _action_line(replay, 1, enemy_action, before, snapshot.request)
                        if replay_path is not None:
                            replay_path.write_text(replay.text())
                    player_features = snapshot.player_features
                    enemy_features = snapshot.enemy_features
                    snapshot = server.episode_step(
                        snapshot.handle, player_action, enemy_action
                    )
                    if snapshot.divergence is not None:
                        semantic_divergence = True
                        semantic_divergences += 1
                        if replay is not None:
                            replay.add(
                                "|message|Semantic divergence: " + snapshot.divergence
                            )
                            if replay_path is not None:
                                replay_path.write_text(replay.text())
                        break
                    after = server.inspect(snapshot.handle)
                    after["player_mask"] = snapshot.player_mask
                    after["enemy_mask"] = snapshot.enemy_mask
                    player_metrics = (
                        candidate_metrics if candidate_player else baseline_metrics
                    )
                    enemy_metrics = (
                        baseline_metrics if candidate_player else candidate_metrics
                    )
                    _update_side_metrics(
                        player_metrics,
                        0,
                        player_action,
                        player_features,
                        before,
                        after,
                        before["request"],
                    )
                    _update_side_metrics(
                        enemy_metrics,
                        1,
                        enemy_action,
                        enemy_features,
                        before,
                        after,
                        before["request"],
                    )
                    if replay is not None:
                        _event_lines(replay, before, after)
                        if replay_path is not None:
                            replay_path.write_text(replay.text())
                    if snapshot.done:
                        result_value = snapshot.terminal_return
                        break
                    snapshot = server.compact(snapshot)
        except NativeRequestTimeout as error:
            timed_out = True
            mechanics_timeouts += 1
            if replay is not None:
                replay.add(f"|message|Mechanics timeout: {error}")
                if replay_path is not None:
                    replay_path.write_text(replay.text())
        candidate_result = (
            result_value if candidate_player or result_value is None else -result_value
        )
        if timed_out or semantic_divergence:
            score = 0.0
        elif candidate_result == 1:
            wins += 1
            score = 1.0
        elif candidate_result == -1:
            losses += 1
            score = 0.0
        elif candidate_result == 0:
            draws += 1
            score = 0.5
        else:
            truncated += 1
            score = 0.0
        game_scores.append(score)
        if (
            replay is not None
            and replay_path is not None
            and not timed_out
            and not semantic_divergence
        ):
            if candidate_result == 1:
                replay.add("|win|Candidate")
            elif candidate_result == -1:
                replay.add("|win|Baseline")
            elif candidate_result == 0:
                replay.add("|tie")
            else:
                replay.add("|message|Battle truncated without a terminal result.")
            replay_path.write_text(replay.text())
    finished = wins + losses + draws
    pair_scores = [
        (game_scores[index] + game_scores[index + 1]) / 2
        for index in range(0, len(game_scores), 2)
    ]
    ci_low, ci_high = _mean_ci95(pair_scores)
    stratum_scores: dict[str, list[float]] = {
        "party-1to2": [],
        "party-3to4": [],
        "party-5to6": [],
        "unequal-party": [],
    }
    for pair, score in enumerate(pair_scores):
        player_size, enemy_size = _evaluation_party_sizes(
            pair, config.generated_schedule_version
        )
        for stratum in _party_strata(player_size, enemy_size):
            stratum_scores[stratum].append(score)
    return {
        "profile": FULL_PROFILE,
        "max_party_size": FULL_PARTY_SIZE,
        **_generated_party_report(config.games, config.generated_schedule_version),
        "strata": _stratified_report(stratum_scores),
        "games": config.games,
        "wins": wins,
        "losses": losses,
        "draws": draws,
        "truncated": truncated,
        "semantic_divergences": semantic_divergences,
        "mechanics_timeouts": mechanics_timeouts,
        "data_quality_pass": mechanics_timeouts == 0,
        "quality_pass": (
            mechanics_timeouts == 0
            and truncated + semantic_divergences
            <= max(1, math.floor(0.02 * config.games))
        ),
        "finished": finished,
        "score": (wins + 0.5 * draws) / finished if finished else None,
        "score_with_nonfinishes_as_losses": sum(game_scores) / config.games,
        "paired_score_ci95": [ci_low, ci_high],
        "candidate_skills": candidate_metrics.report(),
        "baseline_skills": baseline_metrics.report(),
        "config": asdict(config),
    }


def skill_probe_report(arena: dict[str, Any]) -> dict[str, Any]:
    """Gate type/status regressions while retaining switching as a diagnostic."""
    candidate = arena["candidate_skills"]
    baseline = arena["baseline_skills"]

    def difference(name: str) -> float | None:
        left = candidate.get(name)
        right = baseline.get(name)
        return None if left is None or right is None else float(left) - float(right)

    type_delta = difference("mean_move_effectiveness_vs_best")
    status_delta = difference("status_success_rate")
    setup_delta = difference("setup_use_rate")
    switch_delta = difference("matchup_improvement_rate")
    quality_names = (
        "major_status_attempts",
        "redundant_status_same",
        "redundant_status_other",
        "redundant_status_rate",
        "stat_setup_attempts",
        "capped_stat_setup",
        "capped_stat_setup_rate",
        "ohko_attempts",
        "ohko_into_faster",
        "ohko_into_faster_rate",
    )
    candidate_quality = {name: candidate.get(name, 0) for name in quality_names}
    baseline_quality = {name: baseline.get(name, 0) for name in quality_names}
    candidate_waste_rate = (
        candidate["status_wasted"] / candidate["status_uses"]
        if candidate["status_uses"]
        else None
    )
    baseline_waste_rate = (
        baseline["status_wasted"] / baseline["status_uses"]
        if baseline["status_uses"]
        else None
    )
    type_pass = (
        candidate["damaging_moves"] >= 100
        and baseline["damaging_moves"] >= 100
        and type_delta is not None
        and type_delta >= -0.02
    )
    status_pass = (
        candidate["status_uses"] >= 50
        and baseline["status_uses"] >= 50
        and status_delta is not None
        and status_delta >= -0.05
        and candidate_waste_rate is not None
        and baseline_waste_rate is not None
        and candidate_waste_rate <= baseline_waste_rate + 0.05
    )
    return {
        "gate_version": "type-status-only-v2",
        "type": {
            "pass": type_pass,
            "candidate_mean_effectiveness_ratio": candidate[
                "mean_move_effectiveness_vs_best"
            ],
            "baseline_mean_effectiveness_ratio": baseline[
                "mean_move_effectiveness_vs_best"
            ],
            "delta": type_delta,
        },
        "status": {
            "pass": status_pass,
            "candidate_success_rate": candidate["status_success_rate"],
            "baseline_success_rate": baseline["status_success_rate"],
            "success_rate_delta": status_delta,
            "candidate_waste_rate": candidate_waste_rate,
            "baseline_waste_rate": baseline_waste_rate,
        },
        "decision_quality": {
            "gated": False,
            "pass": None,
            "candidate": candidate_quality,
            "baseline": baseline_quality,
        },
        "setup": {
            "gated": False,
            "pass": None,
            "candidate_uses": candidate["setup_uses"],
            "baseline_uses": baseline["setup_uses"],
            "candidate_use_rate": candidate["setup_use_rate"],
            "baseline_use_rate": baseline["setup_use_rate"],
            "use_rate_delta": setup_delta,
            "candidate_move_counts": candidate["setup_move_counts"],
            "baseline_move_counts": baseline["setup_move_counts"],
        },
        "switch": {
            "gated": False,
            "pass": None,
            "candidate_request_rate": candidate["voluntary_switch_rate"],
            "candidate_completion_rate": candidate["switch_completion_rate"],
            "candidate_matchup_improvement_rate": candidate["matchup_improvement_rate"],
            "baseline_matchup_improvement_rate": baseline["matchup_improvement_rate"],
            "matchup_improvement_delta": switch_delta,
        },
        "pass": type_pass and status_pass,
    }


def write_arena_report(
    output: Path,
    candidate: BattleTransformer,
    baseline: BattleTransformer,
    config: ArenaConfig,
) -> dict[str, Any]:
    output.mkdir(parents=True, exist_ok=True)
    result = run_traced_arena(candidate, baseline, config, output / "replays")
    write_json(output / "summary.json", result)
    return result


@dataclass(frozen=True)
class ArenaReportJob:
    """One independent final-report arena with its own output directory."""

    output: Path
    baseline: Any
    config: ArenaConfig


def _serialized_final_arena_baseline(baseline: Any) -> dict[str, Any]:
    if isinstance(baseline, BattleTransformer):
        return {"kind": "transformer", "model": _serialized_arena_model(baseline)}
    return {"kind": "controller", "model": baseline}


def _load_final_arena_baseline(record: dict[str, Any], device: torch.device) -> Any:
    if record["kind"] == "transformer":
        return _load_arena_model(record["model"], device)
    if record["kind"] == "controller":
        return record["model"]
    raise ValueError(f"unknown final arena baseline kind: {record['kind']}")


_FINAL_ARENA_PROCESS_CANDIDATE: BattleTransformer | None = None
_FINAL_ARENA_PROCESS_DEVICE: torch.device | None = None


def _initialize_final_arena_process(payload_path: str) -> None:
    """Load the deployed candidate once per final-report worker."""
    global _FINAL_ARENA_PROCESS_CANDIDATE, _FINAL_ARENA_PROCESS_DEVICE
    torch.set_num_threads(1)
    payload = torch.load(payload_path, map_location="cpu", weights_only=False)
    device = choose_device(payload["device"])
    _FINAL_ARENA_PROCESS_DEVICE = device
    _FINAL_ARENA_PROCESS_CANDIDATE = _load_arena_model(payload["candidate"], device)


def _final_arena_report_task(
    output: Path,
    baseline_record: dict[str, Any],
    config: ArenaConfig,
) -> dict[str, Any]:
    if _FINAL_ARENA_PROCESS_CANDIDATE is None or _FINAL_ARENA_PROCESS_DEVICE is None:
        raise RuntimeError("final arena process candidate was not initialized")
    configure_determinism(config.seed)
    baseline = _load_final_arena_baseline(baseline_record, _FINAL_ARENA_PROCESS_DEVICE)
    return write_arena_report(output, _FINAL_ARENA_PROCESS_CANDIDATE, baseline, config)


def write_arena_reports_parallel(
    candidate: BattleTransformer,
    jobs: list[ArenaReportJob],
    processes: int,
    progress: Callable[[int, int], None] | None = None,
) -> list[dict[str, Any]]:
    """Run independent reports concurrently without repartitioning any arena."""
    if not 1 <= processes <= 16:
        raise ValueError("final arena report processes must be in 1..16")
    if len({job.output for job in jobs}) != len(jobs):
        raise ValueError("final arena report output directories must be unique")
    if not jobs:
        return []
    if processes == 1 or len(jobs) == 1:
        results = []
        for job in jobs:
            results.append(
                write_arena_report(job.output, candidate, job.baseline, job.config)
            )
            if progress is not None:
                progress(len(results), len(jobs))
        return results

    with tempfile.TemporaryDirectory(prefix="final-arena-report-pool-") as temporary:
        payload_path = Path(temporary) / "candidate.pt"
        torch.save(
            {
                "device": str(next(candidate.parameters()).device),
                "candidate": _serialized_arena_model(candidate),
            },
            payload_path,
        )
        results: list[dict[str, Any] | None] = [None] * len(jobs)
        with ProcessPoolExecutor(
            max_workers=min(processes, len(jobs)),
            mp_context=multiprocessing.get_context("spawn"),
            initializer=_initialize_final_arena_process,
            initargs=(str(payload_path),),
        ) as executor:
            futures = {
                executor.submit(
                    _final_arena_report_task,
                    job.output,
                    _serialized_final_arena_baseline(job.baseline),
                    job.config,
                ): index
                for index, job in enumerate(jobs)
            }
            for completed, future in enumerate(as_completed(futures), start=1):
                results[futures[future]] = future.result()
                if progress is not None:
                    progress(completed, len(jobs))
    if any(result is None for result in results):
        raise RuntimeError("final arena report pool returned incomplete results")
    return [result for result in results if result is not None]
