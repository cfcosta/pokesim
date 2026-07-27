from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import torch
from battle_training.arena import _mean_ci95, _paired_coordinates, skill_probe_report
from battle_training.artifacts import build_manifest, verify_manifest, write_json
from battle_training.cli import parser as training_parser
from battle_training.joint_search import (
    _cap_switch_mass,
    _tactical_potential,
    solve_zero_sum_regret,
)
from battle_training.model import MoveValueModel
from battle_training.network import BattleTransformer, TransformerConfig
from battle_training.transformer_pipeline import _load_examples, _scheduled_for_opponent


class MoveValueModelTests(unittest.TestCase):
    def test_terminal_returns_update_scores_and_ignore_unlabeled_rows(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            shard = Path(temporary) / "shard.jsonl"
            rows = [
                {"type": "episode", "episode": 0, "transitions": 2},
                {
                    "type": "transition",
                    "episode": 0,
                    "step": 0,
                    "return": 1,
                    "move_id": 55,
                    "action_id": 0,
                    "legal_mask": 1,
                },
                {
                    "type": "transition",
                    "episode": 0,
                    "step": 1,
                    "return": 1,
                    "move_id": 55,
                    "action_id": 0,
                    "legal_mask": 1,
                },
                {"type": "episode", "episode": 1, "transitions": 1},
                {
                    "type": "transition",
                    "episode": 1,
                    "step": 0,
                    "return": None,
                    "move_id": 33,
                    "action_id": 0,
                    "legal_mask": 1,
                },
            ]
            shard.write_text("".join(json.dumps(row) + "\n" for row in rows))
            model = MoveValueModel()
            result = model.update_shard(shard, discount=0.5)
            self.assertEqual(result, {"updates": 2, "skipped_unlabeled": 1})
            self.assertEqual(model.counts[55], 2)
            self.assertEqual(model.returns[55], 1.5)
            self.assertEqual(model.scores[55], 1750)
            self.assertEqual(model.counts[33], 0)

    def test_checkpoint_round_trip(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            model = MoveValueModel()
            model.returns[10] = -1.0
            model.counts[10] = 1
            artifact = model.checkpoint(root, 3, {"test": True})
            restored = MoveValueModel.from_checkpoint(artifact["checkpoint"])
            self.assertEqual(restored.scores, model.scores)
            self.assertEqual(len(artifact["weights"].read_text().splitlines()), 166)


class TransformerTests(unittest.TestCase):
    def test_regret_matching_finds_matching_pennies_equilibrium(self) -> None:
        payoff = [
            [1.0, -1.0, 0.0, 0.0],
            [-1.0, 1.0, 0.0, 0.0],
            [0.0] * 4,
            [0.0] * 4,
        ]
        player, enemy, value, exploitability = solve_zero_sum_regret(
            payoff,
            [0.5, 0.5, 0.0, 0.0],
            [0.5, 0.5, 0.0, 0.0],
            [0, 1],
            [0, 1],
            256,
        )
        self.assertAlmostEqual(player[0], 0.5, places=6)
        self.assertAlmostEqual(enemy[0], 0.5, places=6)
        self.assertAlmostEqual(value, 0.0, places=6)
        self.assertAlmostEqual(exploitability, 0.0, places=6)

    def test_regret_matching_finds_dominant_actions(self) -> None:
        payoff = [
            [1.0, -1.0, 0.0, 0.0],
            [0.0, -2.0, 0.0, 0.0],
            [0.0] * 4,
            [0.0] * 4,
        ]
        player, enemy, _, exploitability = solve_zero_sum_regret(
            payoff,
            [0.5, 0.5, 0.0, 0.0],
            [0.5, 0.5, 0.0, 0.0],
            [0, 1],
            [0, 1],
            1024,
        )
        self.assertGreater(player[0], 0.99)
        self.assertGreater(enemy[1], 0.99)
        self.assertLess(exploitability, 0.01)

    def test_production_defaults_are_safe_overnight_configuration(self) -> None:
        arguments = training_parser().parse_args(
            ["transformer-train", "--output", "/tmp/overnight"]
        )
        self.assertEqual(arguments.iterations * arguments.episodes, 15_000)
        self.assertEqual(arguments.iterations, 30)
        self.assertEqual(arguments.episodes, 500)
        self.assertEqual(arguments.arena_episodes, 1024)
        self.assertEqual(arguments.search_depth, 4)
        self.assertEqual(arguments.epochs, 2)
        self.assertEqual(arguments.batch_size, 128)
        self.assertEqual(arguments.learning_rate, 2e-4)
        self.assertEqual(arguments.promotion_games, 1024)
        self.assertEqual(arguments.probe_games, 256)

    def test_paired_arena_reuses_resets_and_spans_seeds(self) -> None:
        self.assertEqual(_paired_coordinates(100, 8, 0), _paired_coordinates(100, 8, 1))
        self.assertNotEqual(
            _paired_coordinates(100, 8, 0), _paired_coordinates(100, 8, 2)
        )
        low, high = _mean_ci95([1.0] * 512)
        self.assertEqual((low, high), (1.0, 1.0))

    def test_skill_probes_reject_switch_churn(self) -> None:
        skills = {
            "damaging_moves": 200,
            "mean_move_effectiveness_vs_best": 0.7,
            "status_uses": 100,
            "status_success_rate": 0.5,
            "status_wasted": 40,
            "voluntary_switches": 40,
            "voluntary_switch_rate": 0.1,
            "switch_completion_rate": 1.0,
            "matchup_improvement_rate": 0.55,
        }
        candidate = dict(skills)
        candidate["voluntary_switch_rate"] = 0.47
        report = skill_probe_report(
            {"candidate_skills": candidate, "baseline_skills": skills}
        )
        self.assertFalse(report["switch"]["pass"])
        self.assertFalse(report["pass"])

    def test_fixed_opponent_schedule_is_exact_and_periodic(self) -> None:
        schedule = [_scheduled_for_opponent(episode, 0.5) for episode in range(1000)]
        self.assertEqual(sum(schedule), 500)
        self.assertEqual(schedule[:6], [False, True, False, True, False, True])

    def test_replay_loader_retains_legal_policy_masks(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            shard = Path(temporary) / "examples.jsonl"
            shard.write_text(
                json.dumps(
                    {
                        "type": "example",
                        "features": [0] * 100,
                        "policy": [0.5, 0.0, 0.5, 0.0],
                        "value": 1,
                        "legal_mask": 0b0101,
                    }
                )
                + "\n"
            )
            _, _, _, masks, weights = _load_examples([shard])
            self.assertEqual(weights.tolist(), [1.0])
            self.assertEqual(masks.tolist(), [[True, False, True, False]])

    def test_full_party_models_stay_under_one_million_parameters(self) -> None:
        configs = [
            TransformerConfig(
                feature_count=477,
                action_count=13,
                d_model=64,
                heads=4,
                layers=2,
                feedforward=192,
            ),
            TransformerConfig(
                feature_count=477,
                action_count=13,
                d_model=96,
                heads=4,
                layers=3,
                feedforward=384,
            ),
            TransformerConfig(
                feature_count=477,
                action_count=13,
                d_model=128,
                heads=8,
                layers=4,
                feedforward=512,
            ),
        ]
        counts = [
            sum(
                parameter.numel()
                for parameter in BattleTransformer(config).parameters()
            )
            for config in configs
        ]
        self.assertEqual(counts, [152078, 441518, 938510])
        self.assertTrue(all(count <= 1_000_000 for count in counts))

    def test_switch_cap_preserves_all_legal_actions(self) -> None:
        policy = tuple([0.05] * 4 + [0.125] * 6 + [0.05, 0.0, 0.0])
        capped = _cap_switch_mass(policy, list(policy), list(range(11)), 0.2)
        self.assertAlmostEqual(sum(capped), 1.0)
        self.assertAlmostEqual(sum(capped[4:10]), 0.2)
        self.assertTrue(all(capped[action] > 0 for action in range(10)))

    def test_tactical_potential_rewards_hp_and_status_advantage(self) -> None:
        features = [0] * 477
        for side in (0, 181):
            for slot in range(6):
                base = side + slot * 22
                features[base + 1] = 100
                features[base + 13] = 100
        neutral = _tactical_potential(tuple(features))
        features[182] = 50
        damaged = _tactical_potential(tuple(features))
        features[184] = 4
        statused = _tactical_potential(tuple(features))
        self.assertGreater(damaged, neutral)
        self.assertGreater(statused, damaged)

    def test_policy_masks_and_value_bounds(self) -> None:
        torch.manual_seed(7)
        network = BattleTransformer(
            TransformerConfig(d_model=32, heads=4, layers=1, feedforward=64)
        ).eval()
        policies, values = network.evaluate([[0] * 100, [1] * 100], [0b0101, 0b1010])
        self.assertAlmostEqual(sum(policies[0]), 1.0, places=6)
        self.assertAlmostEqual(sum(policies[1]), 1.0, places=6)
        self.assertEqual(policies[0][1], 0.0)
        self.assertEqual(policies[0][3], 0.0)
        self.assertEqual(policies[1][0], 0.0)
        self.assertEqual(policies[1][2], 0.0)
        self.assertTrue(all(-1.0 <= value <= 1.0 for value in values))


class ManifestTests(unittest.TestCase):
    def test_manifest_detects_tampering(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "artifact.txt").write_text("original\n")
            write_json(root / "manifest.json", build_manifest(root))
            self.assertEqual(verify_manifest(root), [])
            (root / "artifact.txt").write_text("changed\n")
            self.assertTrue(verify_manifest(root))


if __name__ == "__main__":
    unittest.main()
