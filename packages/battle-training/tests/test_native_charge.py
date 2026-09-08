from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from battle_training.native import SearchServer


class NativeChargeTests(unittest.TestCase):
    def test_sky_attack_charges_before_damage_can_freeze(self):
        records = json.loads(
            (Path(__file__).parent / "fixtures/division-freeze-pair.json").read_text()
        )
        record = records[0]
        with SearchServer(popular_gate=64) as server:
            root = server.reset(
                record["reset_seed"],
                record["reset_episode"],
                6,
                6,
                level100=False,
                balanced_final_species=True,
            )
            for step in record["steps"]:
                self.assertEqual(root.player_hash, step["player_state_hash"])
                self.assertEqual(root.enemy_hash, step["enemy_state_hash"])
                root = server.episode_steps(
                    [(root.handle, step["player_action"], step["enemy_action"])]
                )[0]
            step = record["search_steps"][0]
            prepared = server.search_step(
                root.handle,
                step["player_action"],
                step["enemy_action"],
                step["chance_seed"],
            )
            before = server.inspect(prepared.handle)
            self.assertEqual(before["player"]["battle"]["name"], "Zapdos")
            self.assertEqual(before["enemy"]["battle"]["defense"], 513)
            step = record["search_steps"][1]
            charged = server.search_step(
                prepared.handle,
                step["player_action"],
                step["enemy_action"],
                step["chance_seed"],
            )
            self.assertIsNone(charged.divergence)
            after = server.inspect(charged.handle)
            self.assertTrue(after["player"]["replay"]["status"][0] & 16)
            self.assertEqual(
                after["player"]["moves"][0]["pp"], before["player"]["moves"][0]["pp"]
            )
            self.assertEqual(after["rng"]["index"], 0)
            # The release still reaches the cartridge's zero-divisor freeze.
            released = server.search_step(charged.handle, 10, 2, 1)
            self.assertEqual(released.divergence, "division-freeze")


if __name__ == "__main__":
    unittest.main()
