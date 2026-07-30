"""Traced variable-party arenas and policy-skill diagnostics."""

from __future__ import annotations

import math
import random
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

from . import (
    FULL_CAMPAIGN_COUNT,
    FULL_PARTY_SIZE,
    FULL_PROFILE,
    GENERATED_LEVEL_SCHEDULE,
    GENERATED_PARTY_SCHEDULE,
    generated_level100,
    generated_party_sizes,
)
from .artifacts import write_json
from .joint_search import JointSearchConfig, SimultaneousTreeSearch
from .native import NativeRequestTimeout, SearchServer
from .network import BattleTransformer

_FIXED_DAMAGE_MOVES = {68, 69, 82, 101, 149, 162}
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
    search_depth: int = 1
    regret_iterations: int = 256
    inference_batch_size: int = 256
    max_actions_per_side: int = 13
    seed: int = 0
    replay_games: int = 3
    search_every: int = 0
    seed_count: int = 8


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
        ):
            setattr(self, name, getattr(self, name) + getattr(other, name))
        for ratio in other.effectiveness_ratios:
            self.effectiveness_ratio_sum += ratio
            self.effectiveness_ratios.append(ratio)

    def report(self) -> dict[str, Any]:
        result = asdict(self)
        result.pop("effectiveness_ratios")
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
    player: BattleTransformer
    enemy: BattleTransformer
    player_rng: random.Random
    enemy_rng: random.Random
    player_size: int
    enemy_size: int
    level100: bool
    campaign_index: int
    snapshot: Any
    result: int | None = None
    stop: str = "truncated"
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
        "kind": {10: "no-action", 11: "struggle", 12: "run"}.get(
            action, "unknown"
        ),
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


def _network_actions_split(
    player: BattleTransformer,
    enemy: BattleTransformer,
    snapshot: Any,
    player_rng: random.Random,
    enemy_rng: random.Random,
) -> tuple[int, int]:
    if player is enemy:
        policies, _ = player.evaluate(
            [snapshot.player_features, snapshot.enemy_features],
            [snapshot.player_mask, snapshot.enemy_mask],
        )
        return _sample_policy(policies[0], player_rng), _sample_policy(
            policies[1], enemy_rng
        )
    player_policy, _ = player.evaluate(
        [snapshot.player_features], [snapshot.player_mask]
    )
    enemy_policy, _ = enemy.evaluate([snapshot.enemy_features], [snapshot.enemy_mask])
    return _sample_policy(player_policy[0], player_rng), _sample_policy(
        enemy_policy[0], enemy_rng
    )


def _network_actions_many(
    episodes: list[_FastArenaEpisode], batch_size: int = 256
) -> list[tuple[int, int]]:
    grouped: dict[int, list[tuple[int, int, Any, int, BattleTransformer]]] = {}
    for index, episode in enumerate(episodes):
        grouped.setdefault(id(episode.player), []).append(
            (
                index,
                0,
                episode.snapshot.player_features,
                episode.snapshot.player_mask,
                episode.player,
            )
        )
        grouped.setdefault(id(episode.enemy), []).append(
            (
                index,
                1,
                episode.snapshot.enemy_features,
                episode.snapshot.enemy_mask,
                episode.enemy,
            )
        )
    policies: dict[tuple[int, int], list[float]] = {}
    for items in grouped.values():
        network = items[0][4]
        for start in range(0, len(items), batch_size):
            batch = items[start : start + batch_size]
            outputs, _ = network.evaluate(
                [item[2] for item in batch], [item[3] for item in batch]
            )
            for item, policy in zip(batch, outputs, strict=True):
                policies[(item[0], item[1])] = policy
    return [
        (
            _sample_policy(policies[(index, 0)], episode.player_rng),
            _sample_policy(policies[(index, 1)], episode.enemy_rng),
        )
        for index, episode in enumerate(episodes)
    ]


def _network_actions(
    player: BattleTransformer,
    enemy: BattleTransformer,
    snapshot: Any,
    rng: random.Random,
) -> tuple[int, int]:
    return _network_actions_split(player, enemy, snapshot, rng, rng)


def _legal(mask: int, action: int) -> bool:
    return bool(mask & (1 << action))


def _move_score(move: dict[str, Any]) -> int:
    return int(move["power"]) * int(move["effectiveness"]) * int(move["accuracy"])


def _is_status(move: dict[str, Any]) -> bool:
    return int(move["power"]) == 0 and int(move["id"]) not in _FIXED_DAMAGE_MOVES


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
    before: dict[str, Any],
    after: dict[str, Any],
    request: str,
) -> None:
    side_name = "player" if side_index == 0 else "enemy"
    mask = before[f"{side_name}_mask"]
    if request == "battle":
        metrics.ordinary_actions += 1
    if request == "battle" and 0 <= action < 4:
        move = before[side_name]["moves"][action]
        if int(move["power"]) > 0:
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
        elif _is_status(move):
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


def _evaluation_party_sizes(pair: int) -> tuple[int, int]:
    return generated_party_sizes(pair)


def _evaluation_level100(pair: int) -> bool:
    return generated_level100(pair)


def _generated_party_report(games: int) -> dict[str, Any]:
    six_vs_six_games = 2 * sum(
        _evaluation_party_sizes(pair) == (FULL_PARTY_SIZE, FULL_PARTY_SIZE)
        for pair in range(games // 2)
    )
    level100_six_vs_six_games = 2 * sum(
        _evaluation_level100(pair) for pair in range(games // 2)
    )
    if six_vs_six_games * 4 < games:
        raise RuntimeError("generated arena schedule fell below 25% 6v6")
    if (
        six_vs_six_games >= 8
        and level100_six_vs_six_games * 4 != six_vs_six_games
    ):
        raise RuntimeError("generated arena schedule is not exactly 25% level-100 6v6")
    return {
        "party_size_schedule": GENERATED_PARTY_SCHEDULE,
        "level_schedule": GENERATED_LEVEL_SCHEDULE,
        "minimum_6v6_fraction": 0.25,
        "level100_6v6_fraction": 0.25,
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


def _run_fast_arena_games(
    candidate: BattleTransformer,
    baseline: BattleTransformer,
    games: int,
    budget: int,
    seed: int,
    seed_count: int,
    campaign: bool,
    batch_size: int = 256,
    capture_details: bool = False,
) -> list[_FastArenaEpisode]:
    completed: list[_FastArenaEpisode] = []
    server = SearchServer()
    try:
        for batch_start in range(0, games, batch_size):
            batch_stop = min(games, batch_start + batch_size)
            episodes = []
            for game in range(batch_start, batch_stop):
                pair = game // 2
                candidate_player = game % 2 == 0
                candidate_rng = random.Random(seed + 30_000_019 + pair * 2_000_003)
                baseline_rng = random.Random(seed + 40_000_033 + pair * 2_000_003)
                player_size, enemy_size = _evaluation_party_sizes(pair)
                episodes.append(
                    _FastArenaEpisode(
                        game=game,
                        candidate_player=candidate_player,
                        player=candidate if candidate_player else baseline,
                        enemy=baseline if candidate_player else candidate,
                        player_rng=(
                            candidate_rng if candidate_player else baseline_rng
                        ),
                        enemy_rng=(
                            baseline_rng if candidate_player else candidate_rng
                        ),
                        player_size=player_size,
                        enemy_size=enemy_size,
                        level100=not campaign and _evaluation_level100(pair),
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
                            root_seed, reset_episode, episode.campaign_index
                        )
                    else:
                        reset = server.reset if offset == 0 else server.reset_append
                        episode.snapshot = reset(
                            root_seed,
                            reset_episode,
                            episode.player_size,
                            episode.enemy_size,
                            level100=episode.level100,
                        )
                if capture_details:
                    inspections = server.inspect_many(
                        [episode.snapshot.handle for episode in episodes]
                    )
                    for episode, inspection in zip(
                        episodes, inspections, strict=True
                    ):
                        episode.inspection = inspection
                        episode.initial = _compact_inspection(inspection)
                active = episodes.copy()
                for decision in range(budget):
                    if not active:
                        break
                    actions = _network_actions_many(active, batch_size)
                    if capture_details:
                        for episode, (player_action, enemy_action) in zip(
                            active, actions, strict=True
                        ):
                            episode.timeline.append(
                                {
                                    "turn": decision + 1,
                                    "request": episode.snapshot.request,
                                    "before": _compact_turn_inspection(
                                        episode.inspection
                                    ),
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
                            episode.timeline[-1]["after"] = (
                                _compact_turn_inspection(inspection)
                            )
                    survivors = []
                    stopped = []
                    for episode, snapshot in zip(active, snapshots, strict=True):
                        episode.snapshot = snapshot
                        if snapshot.divergence is not None:
                            episode.stop = "semantic-divergence"
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
                server = SearchServer()
            completed.extend(episodes)
    finally:
        server.close()
    return sorted(completed, key=lambda episode: episode.game)


def run_paired_arena(
    candidate: BattleTransformer,
    baseline: BattleTransformer,
    games: int,
    budget: int,
    seed: int,
    seed_count: int = 8,
    *,
    campaign: bool = False,
    capture_details: bool = False,
) -> dict[str, Any]:
    """Fast paired, side-swapped evaluation with nonfinishes scored as losses."""
    if games < 2 or games % 2:
        raise ValueError("paired arena games must be a positive even number")
    if seed_count < 2 or games < 2 * seed_count:
        raise ValueError(
            "paired arena requires at least two seeds and one pair per seed"
        )
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
        games,
        budget,
        seed,
        seed_count,
        campaign,
        capture_details=capture_details,
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
        battle = {
            "game": episode.game,
            "pair": episode.game // 2,
            "candidate_side": "player" if episode.candidate_player else "enemy",
            "player_party_size": episode.player_size,
            "enemy_party_size": episode.enemy_size,
            "level_profile": "level100" if episode.level100 else "distributed",
            "campaign": (
                _CAMPAIGN_NAMES[episode.campaign_index] if campaign else None
            ),
            "stop": episode.stop,
            "reason": (
                f"decision-horizon-{budget}"
                if episode.stop == "truncated"
                else None
            ),
            "candidate_return": candidate_result,
            "score": score,
        }
        if capture_details:
            battle["initial"] = episode.initial
            battle["final"] = episode.final
            battle["timeline"] = episode.timeline
        battles.append(battle)
        pair_score.append(score)
        if len(pair_score) == 2:
            paired = sum(pair_score) / 2
            pair_scores.append(paired)
            if campaign:
                campaign_scores[episode.campaign_index].append(paired)
            else:
                for stratum in _party_strata(
                    episode.player_size, episode.enemy_size
                ):
                    stratum_scores[stratum].append(paired)
            pair_score = []
    robust_score = sum(game_scores) / games
    ci_low, ci_high = _mean_ci95(pair_scores)
    finished = wins + losses + draws
    campaign_cases = {}
    for index, name in enumerate(_CAMPAIGN_NAMES):
        values = campaign_scores[index]
        if values:
            low, high = _mean_ci95(values)
            case_score = sum(values) / len(values)
        else:
            low = high = case_score = None
        campaign_cases[name] = {
            "pairs": len(values),
            "score": case_score,
            "paired_score_ci95": [low, high],
            "pass": case_score is not None and case_score >= 0.40,
        }
    campaign_report = {
        "pass": (
            campaign
            and robust_score >= 0.45
            and all(case["pass"] for case in campaign_cases.values())
        ),
        "minimum_overall_score": 0.45,
        "minimum_case_score": 0.40,
        "cases": campaign_cases,
    }
    return {
        "games": games,
        "pairs": games // 2,
        "seed_count": seed_count,
        "pairing": "same-reset-complete-model-side-swap-v2",
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
            else _generated_party_report(games)
        ),
        "strata": None if campaign else _stratified_report(stratum_scores),
        "campaign": campaign_report if campaign else None,
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
    games: int,
    budget: int,
    seed: int,
    seed_count: int = 8,
) -> dict[str, Any]:
    """Evaluate both model sides across the fixed patched campaign suite."""
    if games < 2 * len(_CAMPAIGN_NAMES):
        raise ValueError("campaign arena requires at least one pair per fixed team")
    return run_paired_arena(
        candidate,
        baseline,
        games,
        budget,
        seed,
        seed_count,
        campaign=True,
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
        player_size, enemy_size = _evaluation_party_sizes(pair)
        for stratum in _party_strata(player_size, enemy_size):
            stratum_scores[stratum].append(score)
    return {
        "profile": FULL_PROFILE,
        "max_party_size": FULL_PARTY_SIZE,
        **_generated_party_report(config.games),
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


def _run_traced_arena_batched(
    candidate: BattleTransformer,
    baseline: BattleTransformer,
    config: ArenaConfig,
    replay_dir: Path | None,
) -> dict[str, Any]:
    candidate_metrics = SkillMetrics()
    baseline_metrics = SkillMetrics()
    all_episodes: list[_TracedArenaEpisode] = []
    if replay_dir is not None:
        replay_dir.mkdir(parents=True, exist_ok=True)
    server = SearchServer()
    try:
        for batch_start in range(0, config.games, 64):
            batch_stop = min(config.games, batch_start + 64)
            episodes = []
            for game in range(batch_start, batch_stop):
                pair = game // 2
                candidate_player = game % 2 == 0
                candidate_rng = random.Random(
                    config.seed + 30_000_019 + pair * 2_000_003
                )
                baseline_rng = random.Random(
                    config.seed + 40_000_033 + pair * 2_000_003
                )
                player_size, enemy_size = _evaluation_party_sizes(pair)
                replay = Replay() if game < config.replay_games else None
                episodes.append(
                    _TracedArenaEpisode(
                        game=game,
                        candidate_player=candidate_player,
                        player=candidate if candidate_player else baseline,
                        enemy=baseline if candidate_player else candidate,
                        player_rng=(
                            candidate_rng if candidate_player else baseline_rng
                        ),
                        enemy_rng=(
                            baseline_rng if candidate_player else candidate_rng
                        ),
                        player_size=player_size,
                        enemy_size=enemy_size,
                        level100=_evaluation_level100(pair),
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
                    reset = server.reset if offset == 0 else server.reset_append
                    episode.snapshot = reset(
                        root_seed,
                        reset_episode,
                        episode.player_size,
                        episode.enemy_size,
                        level100=episode.level100,
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
                    actions = _network_actions_many(
                        active, config.inference_batch_size
                    )
                    for episode, (player_action, enemy_action) in zip(
                        active, actions, strict=True
                    ):
                        if episode.replay is not None:
                            assert episode.inspection is not None
                            episode.replay.add(f"|turn|{decision + 1}")
                            _action_line(
                                episode.replay,
                                0,
                                player_action,
                                episode.inspection,
                                episode.snapshot.request,
                            )
                            _action_line(
                                episode.replay,
                                1,
                                enemy_action,
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
                            before,
                            after,
                            before["request"],
                        )
                        _update_side_metrics(
                            enemy_metrics,
                            1,
                            enemy_action,
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
                server = SearchServer()
            all_episodes.extend(episodes)
    finally:
        server.close()
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
    return _traced_summary(
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


def run_traced_arena(
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
    if config.search_every:
        return _run_traced_arena_sequential(
            candidate, baseline, config, replay_dir
        )
    return _run_traced_arena_batched(candidate, baseline, config, replay_dir)


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
    search_config = JointSearchConfig(
        config.chance_samples_per_joint,
        config.search_depth,
        config.regret_iterations,
        config.inference_batch_size,
        config.max_actions_per_side,
    )
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
        player_size, enemy_size = _evaluation_party_sizes(pair)
        candidate_rng = random.Random(config.seed + 30_000_019 + pair * 2_000_003)
        baseline_rng = random.Random(config.seed + 40_000_033 + pair * 2_000_003)
        player_rng = candidate_rng if candidate_player else baseline_rng
        enemy_rng = baseline_rng if candidate_player else candidate_rng
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
            with SearchServer() as server:
                root_seed, reset_episode = _paired_coordinates(
                    config.seed, config.seed_count, episode
                )
                snapshot = server.reset(
                    root_seed,
                    reset_episode,
                    player_size,
                    enemy_size,
                    level100=_evaluation_level100(pair),
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
                    if config.search_every and decision % config.search_every == 0:
                        search = SimultaneousTreeSearch(
                            server,
                            player,
                            enemy,
                            search_config,
                            selection_rng,
                            chance_rng,
                        )
                        result = search.search(snapshot, sample_actions=True)
                        player_action = result.player_action
                        enemy_action = result.enemy_action
                    else:
                        player_action, enemy_action = _network_actions_split(
                            player, enemy, snapshot, player_rng, enemy_rng
                        )
                    if replay is not None:
                        replay.add(f"|turn|{decision + 1}")
                        _action_line(replay, 0, player_action, before, snapshot.request)
                        _action_line(replay, 1, enemy_action, before, snapshot.request)
                        if replay_path is not None:
                            replay_path.write_text(replay.text())
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
                        before,
                        after,
                        before["request"],
                    )
                    _update_side_metrics(
                        enemy_metrics,
                        1,
                        enemy_action,
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
        player_size, enemy_size = _evaluation_party_sizes(pair)
        for stratum in _party_strata(player_size, enemy_size):
            stratum_scores[stratum].append(score)
    return {
        "profile": FULL_PROFILE,
        "max_party_size": FULL_PARTY_SIZE,
        **_generated_party_report(config.games),
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
    switch_delta = difference("matchup_improvement_rate")
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
