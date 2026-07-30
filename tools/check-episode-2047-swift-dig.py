#!/usr/bin/env python3
"""Replay promotion game 2047's Dig/Swift interaction through Lean."""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "packages" / "battle-training"))

from battle_training.native import SearchServer

PREFIX_ACTIONS = (
    (3, 3),
    (0, 3),
    (1, 1),
    (1, 3),
    (1, 3),
    (1, 6),
    (0, 0),
    (3, 2),
    (6, 10),
    (3, 3),
    (3, 10),
    (10, 8),
    (0, 3),
    (1, 10),
    (7, 10),
    (2, 2),
    (9, 10),
    (0, 2),
    (8, 10),
    (0, 0),
    (1, 2),
    (5, 10),
)


def move_pp(inspection: dict[str, Any], side: str, move: str) -> int:
    for entry in inspection[side]["moves"]:
        if entry["name"] == move:
            return int(entry["pp"])
    raise AssertionError(f"{side} has no {move} move")


def main() -> int:
    # V17 promotion iteration 4, game 2047: pair 1023, seed index 7,
    # sample index 127 under paired arena schedule v1.
    with SearchServer() as server:
        state = server.reset(
            187_300_775,
            127,
            6,
            6,
            balanced_final_species=True,
        )
        for player, enemy in PREFIX_ACTIONS[:12]:
            state = server.episode_step(state.handle, player, enemy)

        # The first Dig in the recording demonstrates the complementary gate:
        # ordinary Confusion misses while Golem is underground.
        state = server.episode_step(state.handle, *PREFIX_ACTIONS[12])
        first_charge = server.inspect(state.handle)
        assert first_charge["enemy"]["volatile"][0] == 0x50
        state = server.episode_step(state.handle, *PREFIX_ACTIONS[13])
        first_release = server.inspect(state.handle)
        assert first_release["enemy"]["volatile"][0] == 0
        assert first_release["enemy"]["party"][4]["hp"] == 250
        assert first_release["events"][2] == {"kind": "missed", "side": 0}

        for player, enemy in PREFIX_ACTIONS[14:]:
            state = server.episode_step(state.handle, player, enemy)

        before = server.inspect(state.handle)
        assert before["player"]["battle"]["name"] == "Sandslash"
        assert before["enemy"]["battle"]["name"] == "Golem"
        assert before["enemy"]["volatile"][0] == 0
        assert before["enemy"]["party"][4]["hp"] == 190
        assert move_pp(before, "enemy", "Dig") == 9

        # Golem starts Dig first. Its status byte becomes $50 (charging and
        # invulnerable), but Sandslash's Swift still takes the ROM's early hit
        # return and deals seven damage without an accuracy RNG draw.
        state = server.episode_step(state.handle, 2, 3)
        buried = server.inspect(state.handle)
        assert buried["enemy"]["volatile"][0] == 0x50
        assert buried["enemy"]["party"][4]["hp"] == 183
        assert buried["rng"]["index"] == 2
        assert move_pp(buried, "enemy", "Dig") == 9
        assert buried["events"] == [
            {"kind": "action", "side": 1, "action": 3},
            {"kind": "move-executed", "side": 1, "move_id": 91, "move": "Dig"},
            {"kind": "action", "side": 0, "action": 2},
            {
                "kind": "move-executed",
                "side": 0,
                "move_id": 129,
                "move": "Swift",
            },
            {"kind": "damage", "side": 1, "amount": 7, "hp": 183},
        ]

        # The automatic continuation clears both bits before Dig deals damage;
        # Sandslash's later Fury Swipes therefore attacks a visible Golem.
        state = server.episode_step(state.handle, 3, 10)
        released = server.inspect(state.handle)
        assert released["enemy"]["volatile"][0] == 0
        assert released["player"]["party"][1]["hp"] == 28
        assert released["enemy"]["party"][4]["hp"] == 177
        assert move_pp(released, "enemy", "Dig") == 8

    print(
        "PASS game 2047 Swift/Dig: Dig status=$50, Swift dealt 7, "
        "Dig continuation cleared status and decremented PP once"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
