from __future__ import annotations

import unittest

from battle_training.replay import (
    ReplayCoordinates,
    _coordinates_for_replay,
    _expected_memory,
    _game_text,
    _party_mon_bytes,
    _recorded_state_for_replay,
    _swap_request,
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
            {"config": {"seed": 20_260_726, "balanced_final_species": True}},
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
        self.assertTrue(coordinates.balanced_final_species)

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

    def test_enemy_candidate_replay_swaps_parties_and_forced_request(self) -> None:
        recorded = {
            "request": "forced-enemy",
            "player": {"active": 0, "party": [{"name": "baseline"}]},
            "enemy": {"active": 1, "party": [{"name": "candidate"}]},
            "rng": {"list": list(range(10)), "index": 2},
        }
        replay = _recorded_state_for_replay(recorded, True)
        self.assertEqual(replay["request"], "forced-player")
        self.assertEqual(replay["player"]["party"][0]["name"], "candidate")
        self.assertEqual(replay["enemy"]["party"][0]["name"], "baseline")
        self.assertIs(replay["rng"], recorded["rng"])
        self.assertEqual(_swap_request("battle"), "battle")

    def test_enemy_candidate_replay_inverts_generator_side_swap(self) -> None:
        coordinates = ReplayCoordinates(
            root_seed=10,
            reset_episode=20,
            player_size=3,
            enemy_size=6,
            level100=False,
            swapped=False,
            balanced_final_species=True,
        )
        replay = _coordinates_for_replay(coordinates, True)
        self.assertTrue(replay.swapped)
        self.assertEqual((replay.player_size, replay.enemy_size), (3, 6))
        self.assertFalse(_coordinates_for_replay(replay, True).swapped)

    def test_checkpoint_covers_party_active_volatile_and_rng(self) -> None:
        member = mon()

        def side() -> dict[str, object]:
            return {
                "active": 0,
                "party": [member] * 6,
                "battle": member,
                "stages": [7, 8, 9, 10, 11, 12],
                "replay": {
                    "unmodified": [40, 120, 79, 66, 85, 72],
                    "status": [0x10, 0x20, 0x40],
                    "counters": [2, 3, 4],
                    "disabled": [0x25, 2],
                    "substitute_hp": 31,
                    "bide_damage": 0x1234,
                    "minimized": 1,
                    "selection": [130, 39, 100, 0, 100, 15, 130, 2],
                    "last_move": 129,
                },
            }

        inspection = {
            "request": "battle",
            "player": side(),
            "enemy": side(),
            "rng": {"list": list(range(10)), "index": 4},
            "shared_damage": 0x5678,
        }
        memory = dict(_expected_memory(inspection))
        self.assertEqual(len(memory), 676)
        self.assertEqual(memory[0xD16B], 130)
        self.assertEqual(memory[0xD014], 130)
        self.assertEqual(memory[0xD8A4], 130)
        self.assertEqual(memory[0xCFE5], 130)
        self.assertEqual(memory[0xD062], 0x10)
        self.assertEqual(memory[0xD063], 0x20)
        self.assertEqual(memory[0xD06A], 2)
        self.assertEqual(memory[0xCCEE], 2)
        self.assertEqual(memory[0xD074], 0x12)
        self.assertEqual(memory[0xD075], 0x34)
        self.assertEqual(memory[0xCFD2], 130)
        self.assertEqual(memory[0xCCDC], 130)
        self.assertEqual(memory[0xD0D7], 0x56)
        self.assertEqual(memory[0xD0D8], 0x78)
        self.assertEqual(memory[0xCCDE], 4)
        self.assertEqual(
            [memory[0xD148 + index] for index in range(10)], list(range(10))
        )


if __name__ == "__main__":
    unittest.main()
