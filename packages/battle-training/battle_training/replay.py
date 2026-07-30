"""Reconstruct cartridge replay manifests from recorded deterministic battles."""

from __future__ import annotations

from dataclasses import dataclass, replace
from threading import Lock
from typing import Any

from .native import SearchServer, build_search_server

REPLAY_PROFILE = "pokered-recorded-link-replay-v2"

_SEARCH_SERVER_LOCK = Lock()
_SEARCH_SERVER_READY = False

_PARTY_COUNT = {"player": 0xD163, "enemy": 0xD89C}
_PARTY_SPECIES = {"player": 0xD164, "enemy": 0xD89D}
_PARTY_MONS = {"player": 0xD16B, "enemy": 0xD8A4}
_PARTY_OT_NAMES = {"player": 0xD273, "enemy": 0xD9AC}
_PARTY_NICKNAMES = {"player": 0xD2B5, "enemy": 0xD9EE}
_ACTIVE_INDEX = {"player": 0xCC2F, "enemy": 0xCFE8}
_RNG_LIST = 0xD148
_RNG_INDEX = 0xCCDE
_ACTIVE_HP = {"player": 0xD015, "enemy": 0xCFE6}
_ACTIVE_STATUS = {"player": 0xD018, "enemy": 0xCFE9}
_ACTIVE_PP = {"player": 0xD02D, "enemy": 0xCFFE}
_UNMODIFIED = {"player": 0xCD0F, "enemy": 0xCD23}
_STAT_STAGES = {"player": 0xCD1A, "enemy": 0xCD2E}
_BATTLE_STATUS = {"player": 0xD062, "enemy": 0xD067}
_NUM_ATTACKS_LEFT = {"player": 0xD06A, "enemy": 0xD06F}
_CONFUSED_COUNTER = {"player": 0xD06B, "enemy": 0xD070}
_TOXIC_COUNTER = {"player": 0xD06C, "enemy": 0xD071}
_DISABLED_MOVE = {"player": 0xD06D, "enemy": 0xD072}
_DISABLED_MOVE_NUMBER = {"player": 0xCCEE, "enemy": 0xCCEF}
_SUBSTITUTE_HP = {"player": 0xCCD7, "enemy": 0xCCD8}
_BIDE_DAMAGE = {"player": 0xD074, "enemy": 0xCD05}
_MINIMIZED = {"player": 0xCCF7, "enemy": 0xCCF3}
_MOVE_SCRATCH = {"player": 0xCFD2, "enemy": 0xCFCC}
_SELECTED_MOVE = {"player": 0xCCDC, "enemy": 0xCCDD}
_MOVE_LIST_INDEX = {"player": 0xCC2E, "enemy": 0xCCE2}
_USED_MOVE = {"player": 0xCCF1, "enemy": 0xCCF2}
_SHARED_DAMAGE = 0xD0D7
_PARTY_MON_SIZE = 0x2C
_NAME_SIZE = 11
_MAX_PARTY = 6
_MAX_CHECKPOINT_BYTES = 768
_TRAINER_PICTURE_CLASSES = tuple(
    trainer_class for trainer_class in range(1, 48) if trainer_class not in {13, 27}
)


@dataclass(frozen=True)
class ReplayCoordinates:
    root_seed: int
    reset_episode: int
    player_size: int
    enemy_size: int
    level100: bool
    swapped: bool
    balanced_final_species: bool


def _u16(value: object) -> tuple[int, int]:
    integer = int(value)
    if not 0 <= integer <= 0xFFFF:
        raise ValueError(f"16-bit replay value is out of range: {integer}")
    return integer >> 8, integer & 0xFF


def _game_text(value: str) -> list[int]:
    """Encode a short nickname in the canonical English Gen-I character map."""
    punctuation = {" ": 0x7F, "-": 0xE3, ".": 0xE8, "'": 0xE0}
    encoded: list[int] = []
    for character in value.upper()[:10]:
        if "A" <= character <= "Z":
            encoded.append(0x80 + ord(character) - ord("A"))
        elif "0" <= character <= "9":
            encoded.append(0xF6 + ord(character) - ord("0"))
        else:
            encoded.append(punctuation.get(character, 0x7F))
    return (encoded + [0x50] * _NAME_SIZE)[:_NAME_SIZE]


def _party_mon_bytes(mon: dict[str, Any]) -> list[int]:
    moves = list(mon["moves"])
    if len(moves) != 4:
        raise ValueError("recorded replay Pokémon must have four move slots")
    result = [0] * _PARTY_MON_SIZE
    result[0] = int(mon["species"])
    result[1:3] = _u16(mon["hp"])
    result[3] = int(mon["box_level"])
    result[4] = int(mon["status"])
    result[5] = int(mon["type1"])
    result[6] = int(mon["type2"])
    result[7] = int(mon["catch_rate"])
    result[8:12] = [int(move["id"]) for move in moves]
    # OT ID, experience, and stat experience are inert in link battles. Keep the
    # synthesized values zero and install matching player/OT IDs in the ROM.
    result[27:29] = _u16(mon["dvs"])
    result[29:33] = [int(move["pp"]) | (int(move["pp_ups"]) << 6) for move in moves]
    result[33] = int(mon["level"])
    stats = (
        mon["max_hp"],
        mon["attack"],
        mon["defense"],
        mon["speed"],
        mon["special"],
    )
    cursor = 34
    for stat in stats:
        result[cursor : cursor + 2] = _u16(stat)
        cursor += 2
    if any(not 0 <= value <= 0xFF for value in result):
        raise ValueError("recorded replay party byte is out of range")
    return result


def _party_payload(side: dict[str, Any], owner: str) -> dict[str, Any]:
    party = list(side["party"])
    if not 1 <= len(party) <= _MAX_PARTY:
        raise ValueError("recorded replay party size must be between one and six")
    structures = [value for mon in party for value in _party_mon_bytes(mon)]
    structures.extend([0] * (_MAX_PARTY * _PARTY_MON_SIZE - len(structures)))
    species = [int(mon["species"]) for mon in party]
    species.extend([0xFF] + [0] * (_MAX_PARTY - len(species)))
    nicknames = [value for mon in party for value in _game_text(str(mon["name"]))]
    nicknames.extend([0x50] * (_MAX_PARTY * _NAME_SIZE - len(nicknames)))
    owner_name = _game_text(owner)
    ot_names = (owner_name * _MAX_PARTY)[: _MAX_PARTY * _NAME_SIZE]
    return {
        "count": len(party),
        "species": species[: _MAX_PARTY + 1],
        "structures": structures,
        "ot_names": ot_names,
        "nicknames": nicknames,
    }


def _state_signature(inspection: dict[str, Any]) -> dict[str, Any]:
    def side(name: str) -> dict[str, Any]:
        value = inspection[name]
        return {
            "active": int(value["active"]),
            "party": [
                {
                    "species": int(mon["species"]),
                    "hp": int(mon["hp"]),
                    "max_hp": int(mon["max_hp"]),
                    "status": int(mon["status"]),
                    "pp": [int(move["pp"]) for move in mon["moves"]],
                }
                for mon in value["party"]
            ],
        }

    return {
        "request": inspection["request"],
        "player": side("player"),
        "enemy": side("enemy"),
    }


def _recorded_signature(value: dict[str, Any]) -> dict[str, Any]:
    def side(name: str) -> dict[str, Any]:
        source = value[name]
        return {
            "active": int(source["active"]),
            "party": [
                {
                    "species": int(mon.get("species", -1)),
                    "hp": int(mon["hp"]),
                    "max_hp": int(mon["max_hp"]),
                    "status": int(mon["status"]),
                    "pp": [int(move["pp"]) for move in mon.get("moves", [])],
                }
                for mon in source["party"]
            ],
        }

    return {
        "request": value["request"],
        "player": side("player"),
        "enemy": side("enemy"),
    }


def _assert_matches_recording(
    inspection: dict[str, Any], recorded: dict[str, Any], label: str
) -> None:
    actual = _state_signature(inspection)
    expected = _recorded_signature(recorded)
    # Per-turn compact states intentionally omit species and PP. Initial/final
    # states retain them, so compare only fields present in the recording.
    for side in ("player", "enemy"):
        for actual_mon, expected_mon in zip(
            actual[side]["party"], expected[side]["party"], strict=True
        ):
            if expected_mon["species"] < 0:
                actual_mon.pop("species")
                expected_mon.pop("species")
            if not expected_mon["pp"]:
                actual_mon.pop("pp")
                expected_mon.pop("pp")
    if actual != expected:
        raise ValueError(f"deterministic replay reconstruction diverged at {label}")


def _expected_memory(inspection: dict[str, Any]) -> list[list[int]]:
    expected: dict[int, int] = {}
    for name in ("player", "enemy"):
        side = inspection[name]
        active = side["battle"]
        expected[_ACTIVE_INDEX[name]] = int(side["active"])
        party_active = _party_mon_bytes(active)
        battle_active = (
            party_active[:12]
            + party_active[27:29]
            + party_active[33:44]
            + party_active[29:33]
        )
        if len(battle_active) != 29:
            raise AssertionError("battle replay structure must contain 29 bytes")
        battle_active[3] = int(side["active"])
        for offset, value in enumerate(battle_active):
            expected[_ACTIVE_HP[name] - 1 + offset] = value
        for slot, mon in enumerate(side["party"]):
            base = _PARTY_MONS[name] + slot * _PARTY_MON_SIZE
            for offset, value in enumerate(_party_mon_bytes(mon)):
                expected[base + offset] = value

        replay = side["replay"]
        level, max_hp, attack, defense, speed, special = map(int, replay["unmodified"])
        unmodified = [level]
        for value in (max_hp, attack, defense, speed, special):
            unmodified.extend(_u16(value))
        for offset, value in enumerate(unmodified):
            expected[_UNMODIFIED[name] + offset] = value
        for offset, value in enumerate(side["stages"]):
            expected[_STAT_STAGES[name] + offset] = int(value)
        for offset, value in enumerate(replay["status"]):
            expected[_BATTLE_STATUS[name] + offset] = int(value)
        num_attacks, confused, toxic = map(int, replay["counters"])
        expected[_NUM_ATTACKS_LEFT[name]] = num_attacks
        expected[_CONFUSED_COUNTER[name]] = confused
        expected[_TOXIC_COUNTER[name]] = toxic
        disabled, disabled_number = map(int, replay["disabled"])
        expected[_DISABLED_MOVE[name]] = disabled
        expected[_DISABLED_MOVE_NUMBER[name]] = disabled_number
        expected[_SUBSTITUTE_HP[name]] = int(replay["substitute_hp"])
        bide_high, bide_low = _u16(replay["bide_damage"])
        expected[_BIDE_DAMAGE[name]] = bide_high
        expected[_BIDE_DAMAGE[name] + 1] = bide_low
        expected[_MINIMIZED[name]] = int(replay["minimized"])
        selection = list(map(int, replay["selection"]))
        if len(selection) != 8:
            raise ValueError("recorded replay move scratch must have eight fields")
        for offset, value in enumerate(selection[:6]):
            expected[_MOVE_SCRATCH[name] + offset] = value
        expected[_SELECTED_MOVE[name]] = selection[6]
        expected[_MOVE_LIST_INDEX[name]] = selection[7]
        expected[_USED_MOVE[name]] = int(replay["last_move"])
    rng = inspection["rng"]
    for index, value in enumerate(rng["list"]):
        expected[_RNG_LIST + index] = int(value)
    expected[_RNG_INDEX] = int(rng["index"])
    damage_high, damage_low = _u16(inspection["shared_damage"])
    expected[_SHARED_DAMAGE] = damage_high
    expected[_SHARED_DAMAGE + 1] = damage_low
    if len(expected) > _MAX_CHECKPOINT_BYTES:
        raise ValueError(
            f"recorded replay checkpoint has {len(expected)} bytes; "
            f"adapter limit is {_MAX_CHECKPOINT_BYTES}"
        )
    return [[address, value] for address, value in sorted(expected.items())]


def replay_trainer_class(coordinates: ReplayCoordinates, source_match: int) -> int:
    """Choose a stable valid trainer picture for one recorded battle."""
    return _TRAINER_PICTURE_CLASSES[
        (coordinates.root_seed + coordinates.reset_episode * 17 + source_match * 31)
        % len(_TRAINER_PICTURE_CLASSES)
    ]


def _swap_request(request: str) -> str:
    return {
        "battle": "battle",
        "forced-player": "forced-enemy",
        "forced-enemy": "forced-player",
    }[request]


def _recorded_state_for_replay(
    value: dict[str, Any], swap_sides: bool
) -> dict[str, Any]:
    if not swap_sides:
        return value
    return {
        **value,
        "request": _swap_request(str(value["request"])),
        "player": value["enemy"],
        "enemy": value["player"],
    }


def _coordinates_for_replay(
    coordinates: ReplayCoordinates, swap_sides: bool
) -> ReplayCoordinates:
    return (
        replace(coordinates, swapped=not coordinates.swapped)
        if swap_sides
        else coordinates
    )


def replay_coordinates(
    run: dict[str, Any], detail: dict[str, Any]
) -> ReplayCoordinates:
    config = run.get("config", {})
    seed = int(config["seed"])
    iteration = int(detail["iteration"])
    kind = str(detail["kind"])
    if kind == "selfplay":
        return ReplayCoordinates(
            root_seed=seed + iteration * 10_000,
            reset_episode=int(detail["reset_episode"]),
            player_size=int(detail["pair_player_party_size"]),
            enemy_size=int(detail["pair_enemy_party_size"]),
            level100=detail["level_profile"] == "level100",
            swapped=bool(detail["teams_swapped"]),
            balanced_final_species=bool(config.get("balanced_final_species", False)),
        )
    if kind == "promotion":
        arena_seed = seed + 70_000_000 + iteration * 10_007
        game = int(detail["game"])
        pair = game // 2
        seed_count = int(config.get("promotion_seed_count", 8))
        seed_index = pair % seed_count
        sample_index = pair // seed_count
        return ReplayCoordinates(
            root_seed=arena_seed + 90_000_000 + seed_index * 1_000_003,
            reset_episode=sample_index,
            player_size=int(detail["player_party_size"]),
            enemy_size=int(detail["enemy_party_size"]),
            level100=detail["level_profile"] == "level100",
            swapped=False,
            balanced_final_species=bool(config.get("balanced_final_species", False)),
        )
    raise ValueError("recorded replay kind must be selfplay or promotion")


def _reconstruct_replay(
    detail: dict[str, Any],
    recorded_coordinates: ReplayCoordinates,
    swap_sides: bool,
) -> tuple[
    ReplayCoordinates,
    dict[str, Any],
    list[dict[str, Any]],
    list[dict[str, Any]],
    int,
]:
    """Replay one orientation and fail unless every recorded boundary agrees."""
    coordinates = _coordinates_for_replay(recorded_coordinates, swap_sides)
    with SearchServer(request_timeout=30.0) as server:
        snapshot = server.reset(
            coordinates.root_seed,
            coordinates.reset_episode,
            coordinates.player_size,
            coordinates.enemy_size,
            level100=coordinates.level100,
            swapped=coordinates.swapped,
            balanced_final_species=coordinates.balanced_final_species,
        )
        initial = server.inspect(snapshot.handle)
        _assert_matches_recording(
            initial,
            _recorded_state_for_replay(detail["initial"], swap_sides),
            "initial state",
        )
        checkpoints: list[dict[str, Any]] = []
        actions: list[dict[str, Any]] = []
        for decision, turn in enumerate(detail["timeline"]):
            request = (
                _swap_request(str(turn["request"]))
                if swap_sides
                else str(turn["request"])
            )
            if snapshot.request != request:
                raise ValueError(
                    f"deterministic replay request diverged at decision {decision}"
                )
            player_action = int(
                turn["enemy_action"] if swap_sides else turn["player_action"]
            )
            enemy_action = int(
                turn["player_action"] if swap_sides else turn["enemy_action"]
            )
            snapshot = server.episode_step(snapshot.handle, player_action, enemy_action)
            after = server.inspect(snapshot.handle)
            _assert_matches_recording(
                after,
                _recorded_state_for_replay(turn["after"], swap_sides),
                f"decision {decision + 1}",
            )
            actions.append(
                {
                    "request": request,
                    "player": player_action,
                    "enemy": enemy_action,
                }
            )
            checkpoints.append(
                {
                    "decision": decision + 1,
                    "request": after["request"],
                    "memory": _expected_memory(after),
                }
            )
        if not snapshot.done or snapshot.terminal_return not in {-1, 1}:
            raise ValueError(
                "recorded replay action transcript did not finish decisively"
            )
        outcome = int(snapshot.terminal_return)
        final = server.inspect(snapshot.handle)
        _assert_matches_recording(
            final,
            _recorded_state_for_replay(detail["final"], swap_sides),
            "final state",
        )
    return coordinates, initial, actions, checkpoints, outcome


def build_replay_manifest(
    run: dict[str, Any], detail: dict[str, Any]
) -> dict[str, Any]:
    """Recreate and validate one battle before handing it to the ROM adapter."""
    global _SEARCH_SERVER_READY
    with _SEARCH_SERVER_LOCK:
        if not _SEARCH_SERVER_READY:
            build_search_server()
            _SEARCH_SERVER_READY = True
    recorded_coordinates = replay_coordinates(run, detail)
    swap_requested = detail.get("candidate_side") == "enemy"
    swap_sides = swap_requested
    swap_fallback: str | None = None
    try:
        coordinates, initial, actions, checkpoints, outcome = _reconstruct_replay(
            detail, recorded_coordinates, swap_sides
        )
    except ValueError as error:
        if not swap_requested:
            raise
        # Red's simultaneous double-faint replacement order is physically
        # player-first. Transposing both sides can therefore change the first
        # forced request even though the generated teams and actions transpose.
        # Preserve the exact recorded orientation rather than fabricating an
        # intermediate boundary or rejecting an otherwise replayable battle.
        swap_fallback = str(error)
        swap_sides = False
        coordinates, initial, actions, checkpoints, outcome = _reconstruct_replay(
            detail, recorded_coordinates, swap_sides
        )

    source_match = int(detail.get("episode", detail.get("game", -1)))
    trainer_class = replay_trainer_class(coordinates, source_match)
    source_candidate_side = detail.get("candidate_side")
    replay_candidate_side = (
        "player" if swap_sides else source_candidate_side
    )
    return {
        "version": REPLAY_PROFILE,
        "source": {
            "kind": detail["kind"],
            "iteration": int(detail["iteration"]),
            "match": source_match,
        },
        "presentation": {
            "trainer_class": trainer_class,
            "trainer_party": 1,
            "candidate_side": replay_candidate_side,
            "source_candidate_side": source_candidate_side,
            "perspective_swap_requested": swap_requested,
            "perspective_swapped": swap_sides,
            "perspective_swap_fallback": swap_fallback,
        },
        "coordinates": {
            "root_seed": coordinates.root_seed,
            "reset_episode": coordinates.reset_episode,
            "level100": coordinates.level100,
            "swapped": coordinates.swapped,
            "recorded_swapped": recorded_coordinates.swapped,
            "balanced_final_species": coordinates.balanced_final_species,
        },
        "initial": {
            "player": _party_payload(initial["player"], "RED"),
            "enemy": _party_payload(initial["enemy"], "MODEL"),
            "rng": {
                "list": [int(value) for value in initial["rng"]["list"]],
                "index": int(initial["rng"]["index"]),
            },
        },
        "actions": actions,
        "checkpoints": checkpoints,
        "outcome": outcome,
        "decision_count": len(actions),
        "validation": {
            "lean_replayed": True,
            "recording_matched": True,
            "synthesized_inert_party_fields": [
                "ot_id",
                "experience",
                "stat_experience",
            ],
        },
    }
