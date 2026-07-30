from __future__ import annotations

import unittest

from battle_training.replay import (
    _expected_memory,
    _game_text,
    _party_mon_bytes,
    replay_coordinates,
    replay_trainer_class,
)


def mon(*, hp: int = 120, status: int = 0) -> dict[str, object]:
    return {
        "species": 130,
        "name": "Golbat",
        "level": 40,
        "box_level": 0,
        "hp": hp,
        "max_hp": 120,
        "attack": 79,
        "defense": 66,
        "speed": 85,
        "special": 72,
        "status": status,
        "type1": 3,
        "type2": 2,
        "catch_rate": 90,
        "dvs": 55209,
        "moves": [
            {"id": move, "pp": 10 + move, "pp_ups": move % 4} for move in range(1, 5)
        ],
    }


class ReplayManifestTests(unittest.TestCase):
    def test_party_mon_bytes_match_gen_one_layout(self) -> None:
        encoded = _party_mon_bytes(mon(hp=0x1234, status=0x40))
        self.assertEqual(len(encoded), 0x2C)
        self.assertEqual(encoded[:12], [130, 0x12, 0x34, 0, 0x40, 3, 2, 90, 1, 2, 3, 4])
        self.assertEqual(encoded[27:29], [0xD7, 0xA9])
        self.assertEqual(encoded[33], 40)
        self.assertEqual(encoded[34:44], [0, 120, 0, 79, 0, 66, 0, 85, 0, 72])

    def test_game_text_is_terminated_and_fixed_width(self) -> None:
        self.assertEqual(
            _game_text("Mr. Mime"),
            [0x8C, 0x91, 0xE8, 0x7F, 0x8C, 0x88, 0x8C, 0x84, 0x50, 0x50, 0x50],
        )

    def test_selfplay_coordinates_recover_training_reset(self) -> None:
        coordinates = replay_coordinates(
            {"config": {"seed": 20_260_726}},
            {
                "kind": "selfplay",
                "iteration": 3,
                "reset_episode": 1023,
                "pair_player_party_size": 3,
                "pair_enemy_party_size": 5,
                "level_profile": "distributed",
                "teams_swapped": False,
            },
        )
        self.assertEqual(coordinates.root_seed, 20_290_726)
        self.assertEqual(coordinates.reset_episode, 1023)
        self.assertEqual((coordinates.player_size, coordinates.enemy_size), (3, 5))

    def test_promotion_coordinates_recover_paired_arena_reset(self) -> None:
        coordinates = replay_coordinates(
            {"config": {"seed": 100, "promotion_seed_count": 8}},
            {
                "kind": "promotion",
                "iteration": 2,
                "game": 18,
                "player_party_size": 4,
                "enemy_party_size": 6,
                "level_profile": "level100",
            },
        )
        arena_seed = 100 + 70_000_000 + 2 * 10_007
        self.assertEqual(coordinates.root_seed, arena_seed + 90_000_000 + 1_000_003)
        self.assertEqual(coordinates.reset_episode, 1)
        self.assertTrue(coordinates.level100)

    def test_trainer_picture_is_stable_and_skips_unused_classes(self) -> None:
        coordinates = replay_coordinates(
            {"config": {"seed": 20_260_726}},
            {
                "kind": "selfplay",
                "iteration": 13,
                "reset_episode": 8,
                "pair_player_party_size": 6,
                "pair_enemy_party_size": 6,
                "level_profile": "distributed",
                "teams_swapped": False,
            },
        )
        trainer_class = replay_trainer_class(coordinates, 16)
        self.assertEqual(trainer_class, 15)
        self.assertNotIn(trainer_class, {0, 13, 27})

    def test_checkpoint_covers_party_active_mon_and_rng(self) -> None:
        member = mon()
        inspection = {
            "request": "battle",
            "player": {"active": 0, "party": [member]},
            "enemy": {"active": 0, "party": [member]},
            "rng": {"list": list(range(10)), "index": 4},
        }
        memory = dict(_expected_memory(inspection))
        self.assertEqual(memory[0xD16B], 130)
        self.assertEqual(memory[0xD014], 130)
        self.assertEqual(memory[0xD8A4], 130)
        self.assertEqual(memory[0xCFE5], 130)
        self.assertEqual(memory[0xCCDE], 4)
        self.assertEqual(
            [memory[0xD148 + index] for index in range(10)], list(range(10))
        )


if __name__ == "__main__":
    unittest.main()
