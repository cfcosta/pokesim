from __future__ import annotations

import json
import random
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import torch
from battle_training.arena import _mean_ci95, _paired_coordinates, skill_probe_report
from battle_training.artifacts import build_manifest, verify_manifest, write_json
from battle_training.cli import parser as training_parser
from battle_training.joint_search import (
    JointSearchConfig,
    SimultaneousTreeSearch,
    _cap_switch_mass,
    _tactical_potential,
    solve_zero_sum_regret,
)
from battle_training.model import MoveValueModel
from battle_training.native import Snapshot
from battle_training.network import BattleTransformer, TransformerConfig
from battle_training.transformer_pipeline import _load_examples, _scheduled_for_opponent


def _toy_features() -> tuple[int, ...]:
    features = [0] * 478
    for side in (0, 181):
        for slot in range(6):
            base = side + slot * 22
            features[base + 1] = 100
            features[base + 13] = 100
    return tuple(features)


class _ToyNetwork:
    config = SimpleNamespace(action_count=2)

    def __init__(self) -> None:
        self.batches: list[int] = []

    def evaluate(
        self, features: object, masks: list[int]
    ) -> tuple[list[list[float]], list[float]]:
        self.batches.append(len(masks))
        policies = []
        for mask in masks:
            legal = [action for action in range(2) if mask & (1 << action)]
            policy = [0.0, 0.0]
            for action in legal:
                policy[action] = 1.0 / len(legal)
            policies.append(policy)
        return policies, [0.0] * len(masks)


class _ToyServer:
    def __init__(self) -> None:
        self.states: dict[int, tuple[int, int]] = {0: (0, 0)}
        self.next_handle = 1

    def _snapshot(
        self, handle: int, done: bool = False, result: int | None = None
    ) -> Snapshot:
        return Snapshot(
            handle=handle,
            player_features=_toy_features(),
            enemy_features=_toy_features(),
            player_mask=0b11,
            enemy_mask=0b11,
            player_hash=str(handle),
            enemy_hash=str(handle),
            turn=self.states[handle][0],
            terminal=done,
            done=done,
            terminal_return=result,
            request="battle",
            divergence=None,
        )

    def search_step(
        self, handle: int, player_action: int, enemy_action: int, chance_seed: int
    ) -> Snapshot:
        del chance_seed
        stage, root_player_action = self.states[handle]
        child = self.next_handle
        self.next_handle += 1
        if stage == 0:
            self.states[child] = (1, player_action)
            return self._snapshot(child)
        self.states[child] = (2, root_player_action)
        result = (
            (1 if player_action == enemy_action else -1)
            if root_player_action == 0
            else -1
        )
        return self._snapshot(child, done=True, result=result)

    def search_steps(self, requests: list[tuple[int, int, int, int]]) -> list[Snapshot]:
        return [self.search_step(*request) for request in requests]


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

    def test_simultaneous_tree_backs_up_deeper_equilibrium_values(self) -> None:
        server = _ToyServer()
        network = _ToyNetwork()
        search = SimultaneousTreeSearch(
            server,  # type: ignore[arg-type]
            network,  # type: ignore[arg-type]
            network,  # type: ignore[arg-type]
            JointSearchConfig(
                chance_samples_per_joint=1,
                max_depth=2,
                regret_iterations=64,
                inference_batch_size=16,
                max_actions_per_side=2,
                expansion_budget=128,
                exploration=0.2,
                chance_resample=1.0,
                regret_iterations_per_update=16,
                deeper_joint_rotations=2,
                minimum_expansion_budget=4,
            ),
            random.Random(7),
            random.Random(11),
        )
        result = search.search(server._snapshot(0), sample_actions=False)
        self.assertEqual(result.solver, "simultaneous-matrix-tree-rmplus-v1")
        self.assertGreater(result.player_policy[0], 0.8)
        self.assertEqual(result.diagnostics["tree_max_depth"], 1)
        self.assertEqual(result.diagnostics["root_joint_actions"], 4)
        self.assertEqual(result.diagnostics["sampled_joint_coverage"], 1.0)

    def test_cross_root_search_batches_root_inference(self) -> None:
        server = _ToyServer()
        server.states[100] = (0, 0)
        network = _ToyNetwork()
        config = JointSearchConfig(
            chance_samples_per_joint=1,
            max_depth=2,
            regret_iterations=64,
            inference_batch_size=32,
            max_actions_per_side=2,
            expansion_budget=32,
            exploration=0.2,
            chance_resample=1.0,
            regret_iterations_per_update=8,
            deeper_joint_rotations=2,
            minimum_expansion_budget=4,
        )
        searches = [
            SimultaneousTreeSearch(
                server,  # type: ignore[arg-type]
                network,  # type: ignore[arg-type]
                network,  # type: ignore[arg-type]
                config,
                random.Random(seed),
                random.Random(seed + 100),
            )
            for seed in (1, 2)
        ]
        results = SimultaneousTreeSearch.search_many(
            searches, [server._snapshot(0), server._snapshot(100)]
        )
        scalar_results = []
        for seed in (1, 2):
            scalar_server = _ToyServer()
            scalar_search = SimultaneousTreeSearch(
                scalar_server,  # type: ignore[arg-type]
                network,  # type: ignore[arg-type]
                network,  # type: ignore[arg-type]
                config,
                random.Random(seed),
                random.Random(seed + 100),
            )
            scalar_results.append(scalar_search.search(scalar_server._snapshot(0)))
        self.assertEqual(len(results), 2)
        self.assertEqual(
            [result.player_policy for result in results],
            [result.player_policy for result in scalar_results],
        )
        self.assertEqual(
            [result.enemy_policy for result in results],
            [result.enemy_policy for result in scalar_results],
        )
        self.assertEqual(
            [result.root_value for result in results],
            [result.root_value for result in scalar_results],
        )
        self.assertTrue(
            all(result.diagnostics["cross_root_batch_size"] == 2 for result in results)
        )
        self.assertGreaterEqual(max(network.batches), 16)

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
        self.assertEqual(arguments.tree_expansion_budget, 320)
        self.assertEqual(arguments.tree_regret_iterations, 16)
        self.assertEqual(arguments.tree_deeper_joint_rotations, 2)
        self.assertEqual(arguments.tree_minimum_budget, 192)
        self.assertEqual(arguments.tree_convergence_patience, 8)
        self.assertEqual(arguments.actor_batch_size, 16)

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
                feature_count=478,
                action_count=13,
                d_model=64,
                heads=4,
                layers=2,
                feedforward=192,
            ),
            TransformerConfig(
                feature_count=478,
                action_count=13,
                d_model=96,
                heads=4,
                layers=3,
                feedforward=384,
            ),
            TransformerConfig(
                feature_count=478,
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
        self.assertEqual(counts, [152142, 441614, 938638])
        self.assertTrue(all(count <= 1_000_000 for count in counts))

    def test_switch_cap_preserves_all_legal_actions(self) -> None:
        policy = tuple([0.05] * 4 + [0.125] * 6 + [0.05, 0.0, 0.0])
        capped = _cap_switch_mass(policy, list(policy), list(range(11)), 0.2)
        self.assertAlmostEqual(sum(capped), 1.0)
        self.assertAlmostEqual(sum(capped[4:10]), 0.2)
        self.assertTrue(all(capped[action] > 0 for action in range(10)))

    def test_tactical_potential_rewards_hp_and_status_advantage(self) -> None:
        features = [0] * 478
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
