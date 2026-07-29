#!/usr/bin/env python3
"""Replay the episode-606 Fly failure through the corrected Lean worker."""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "packages" / "battle-training"))

from battle_training.native import SearchServer


def move_pp(inspection: dict[str, Any], side: str, move: str) -> int:
    for entry in inspection[side]["moves"]:
        if entry["name"] == move:
            return int(entry["pp"])
    raise AssertionError(f"{side} has no {move} move")


def main() -> int:
    with SearchServer() as server:
        state = server.reset(20_270_726, 606, 6, 5)
        assert state.player_hash == "14308556790426612293"
        assert state.enemy_hash == "5771328148750474122"

        # Episode 606: Submission KOs Zubat, slot 5 Pidgeot replaces it, then
        # Pidgeot selects Fly while Machamp selects Leer.
        for player, enemy in ((0, 3), (9, 10), (2, 0)):
            state = server.episode_step(state.handle, player, enemy)

        charged = server.inspect(state.handle)
        assert state.player_mask == 1 << 10  # no-action only
        assert charged["player"]["volatile"][0] == 0x50
        assert move_pp(charged, "player", "Fly") == 15
        assert charged["events"][-1] == {"kind": "missed", "side": 1}

        # Unlike the historical trace, the policy cannot select Fly again.
        # The sole no-action command executes the retained Fly automatically.
        state = server.episode_step(state.handle, 10, 3)
        continued = server.inspect(state.handle)
        assert state.player_mask == 495
        assert continued["player"]["volatile"][0] == 0
        assert move_pp(continued, "player", "Fly") == 14
        assert continued["player"]["party"][5]["hp"] == 88
        assert continued["enemy"]["party"][0]["hp"] == 68
        assert continued["events"][:3] == [
            {"kind": "action", "side": 0, "action": 10},
            {
                "kind": "move-executed",
                "side": 0,
                "move_id": 19,
                "move": "Fly",
            },
            {"kind": "damage", "side": 1, "amount": 125, "hp": 94},
        ]

    print(
        "PASS episode 606 Fly: setup=0x50, legal=no-action, "
        "retained Fly dealt 125, PP=14, flags=0"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
