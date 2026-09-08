from __future__ import annotations

import shutil
import subprocess
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from battle_training.native import SEARCH_SERVER, SearchServer


@unittest.skipUnless(SEARCH_SERVER.is_file(), "native search server is not built")
class MirrorMoveNativeTest(unittest.TestCase):
    @unittest.skipUnless(shutil.which("lake"), "Lean toolchain is unavailable")
    def test_metronome_recursive_wrappers_and_explicit_mimic_handoff(self):
        fixture = Path(__file__).parent / "fixtures" / "NestedMoveContinuation.lean"
        lean_project = Path(__file__).resolve().parents[2] / "battle-lean"
        result = subprocess.run(
            ["lake", "-d", str(lean_project), "env", "lean", str(fixture)],
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_first_actor_copy_preserves_the_committed_opposing_action(self):
        with SearchServer() as server:
            root = server.reset(
                772131, 2, 6, 6, level100=True, balanced_final_species=True
            )
            switched = server.search_step(root.handle, 6, 8, 8332583627480706287)
            # Both use Agility, giving the faster player a copyable move from
            # the previous turn. Its nested action must retain enemy Fury Attack.
            prepared = server.search_step(switched.handle, 3, 3, 7847643833579780240)
            before = server.inspect(prepared.handle)
            self.assertEqual(before["enemy"]["replay"]["last_move"], 97)
            outcome = server.search_step(prepared.handle, 1, 0, 7847643833579780240)
            self.assertIsNone(outcome.divergence)
            self.assertEqual(outcome.turn, prepared.turn + 1)
            after = server.inspect(outcome.handle)
            self.assertEqual(
                after["player"]["stages"][2], before["player"]["stages"][2] + 2
            )
            self.assertLess(
                after["player"]["battle"]["hp"], before["player"]["battle"]["hp"]
            )
            for side, slot in (("player", 1), ("enemy", 0)):
                self.assertEqual(
                    after[side]["moves"][slot]["pp"],
                    before[side]["moves"][slot]["pp"] - 1,
                )

    def test_mirror_move_still_copies_an_ordinary_setup_move(self):
        with SearchServer() as server:
            root = server.reset(
                772131, 2, 6, 6, level100=True, balanced_final_species=True
            )
            switched = server.search_step(root.handle, 6, 8, 8332583627480706287)
            before = server.inspect(switched.handle)
            self.assertEqual(before["player"]["moves"][3]["id"], 97)
            outcome = server.search_step(switched.handle, 3, 1, 7847643833579780240)
            self.assertIsNone(outcome.divergence)
            self.assertEqual(outcome.turn, switched.turn + 1)
            after = server.inspect(outcome.handle)
            for side, slot in (("player", 3), ("enemy", 1)):
                self.assertEqual(
                    after[side]["stages"][2], before[side]["stages"][2] + 2
                )
                self.assertEqual(
                    after[side]["moves"][slot]["pp"],
                    before[side]["moves"][slot]["pp"] - 1,
                )

    def test_two_mirror_moves_without_copyable_history_finish_the_turn(self):
        # Cartridge MirrorMoveCopyMove rejects both zero and Mirror Move (119).
        # The second actor sees the first actor's failed Mirror Move, not a
        # recursively callable move. This is the exact benchmark failure path.
        with SearchServer() as server:
            root = server.reset(
                772131, 2, 6, 6, level100=True, balanced_final_species=True
            )
            for player_switch in (6, 9):
                for chance in (8332583627480706287, 243432512997280765):
                    with self.subTest(player_switch=player_switch, chance=chance):
                        switched = server.search_step(
                            root.handle, player_switch, 8, chance
                        )
                        before = server.inspect(switched.handle)
                        outcome = server.search_step(
                            switched.handle, 1, 1, 7847643833579780240
                        )
                        self.assertIsNone(outcome.divergence)
                        self.assertEqual(outcome.request, "battle")
                        self.assertEqual(outcome.turn, switched.turn + 1)
                        after = server.inspect(outcome.handle)
                        for side in ("player", "enemy"):
                            self.assertEqual(before[side]["moves"][1]["id"], 119)
                            self.assertEqual(
                                after[side]["battle"]["hp"],
                                before[side]["battle"]["hp"],
                            )
                            self.assertEqual(
                                after[side]["moves"][1]["pp"],
                                before[side]["moves"][1]["pp"] - 1,
                            )
                            self.assertEqual(after[side]["replay"]["last_move"], 119)


if __name__ == "__main__":
    unittest.main()
