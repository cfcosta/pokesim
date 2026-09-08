from __future__ import annotations

import random
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from battle_training.joint_search import JointSearchConfig, SimultaneousTreeSearch


class OrientedNetwork:
    config = SimpleNamespace(
        action_count=2,
        joint_policy_heads=True,
        distilled_leaf_evaluator=True,
        distilled_leaf_policy=True,
    )

    def evaluate_joint(self, rows, own_masks, opponent_masks):
        return (
            [[0.8, 0.2] for _ in rows],
            [[0.3, 0.7] for _ in rows],
            [float(row[0]) / 10 for row in rows],
        )

    def evaluate_leaf_joint(self, rows, own_masks, opponent_masks):
        return (
            [[0.6, 0.4] for _ in rows],
            [[0.9, 0.1] for _ in rows],
            [float(row[0]) / 20 for row in rows],
        )

    def evaluate_leaf(self, rows):
        return [float(row[0]) / 20 for row in rows]


def snapshot():
    return SimpleNamespace(
        handle=0,
        player_mask=3,
        enemy_mask=3,
        done=False,
        divergence=None,
        player_features=np.array([8], dtype=np.int64),
        enemy_features=np.array([2], dtype=np.int64),
    )


def search(network=None, **kwargs):
    network = network or OrientedNetwork()
    return SimultaneousTreeSearch(
        None,
        network,
        network,
        JointSearchConfig(),
        random.Random(1),
        random.Random(2),
        **kwargs,
    )


class SearchContractTests(unittest.TestCase):
    def test_search_preserves_terminal_win_value_without_tactical_bonus(self):
        evaluator = search()
        better = evaluator._shaped_leaf_value(0.0, snapshot(), 0.6, -0.2)
        worse = evaluator._shaped_leaf_value(0.0, snapshot(), 0.4, 0.2)
        self.assertEqual(better, 0.6)
        self.assertEqual(worse, 0.4)

    def test_split_halves_measure_uncertainty_without_changing_mean_solution(self):
        evaluator = search()
        evaluator.config = JointSearchConfig(
            chance_samples_per_joint=2, split_half_reliability=True
        )
        node = evaluator._make_node(snapshot(), ([0.5, 0.5], [0.5, 0.5], 0.0))
        for half, payoffs in enumerate(((0.9, 0.1), (-0.5, 0.1))):
            for action, value in enumerate(payoffs):
                for enemy in range(2):
                    evaluator._record_value(node, action, enemy, value, half)
        expected = evaluator._solve_matrix(node, node.payoff)
        actual = evaluator._root_equilibrium(node)
        np.testing.assert_allclose(actual[0], expected[0], atol=1e-12)
        self.assertGreater(evaluator._split_half_player_distance, 0.9)

    def test_enemy_controller_uses_its_own_canonical_value_and_heads(self):
        evaluator = search(evaluation_side="enemy")
        result, _, _ = evaluator._pooled_evaluate([(0, evaluator, [snapshot()])])
        player, enemy, values = result[0]
        self.assertEqual(player, [[0.3, 0.7]])
        self.assertEqual(enemy, [[0.8, 0.2]])
        self.assertEqual(values, [-0.2])

    def test_enemy_distilled_controller_uses_its_own_canonical_value_and_heads(self):
        evaluator = search(evaluation_side="enemy")
        result, _, _ = evaluator._pooled_leaf_evaluate([(0, evaluator, [snapshot()])])
        player, enemy, values = result[0]
        self.assertEqual(player, [[0.9, 0.1]])
        self.assertEqual(enemy, [[0.6, 0.4]])
        self.assertEqual(values, [-0.1])
        leaves, _, _ = evaluator._pooled_leaf_values([(0, evaluator, [snapshot()])])
        self.assertEqual(leaves[0], [-0.1])

    def test_full_evaluator_is_used_even_if_network_has_distilled_heads(self):
        evaluator = search()
        result, _, _ = evaluator._pooled_successor_values(
            [(0, evaluator, [snapshot()])]
        )
        self.assertEqual(result[0], [(0.8, 0.8)])

    def test_unavailable_distilled_heads_report_effective_full_evaluator(self):
        network = OrientedNetwork()
        network.config = SimpleNamespace(action_count=2, joint_policy_heads=True)
        evaluator = search(network)
        evaluator.config = JointSearchConfig(leaf_evaluator="distilled")
        diagnostics = evaluator._diagnostics(None)
        self.assertEqual(diagnostics["requested_leaf_evaluator"], "distilled")
        self.assertEqual(diagnostics["leaf_evaluator"], "full")
        self.assertEqual(diagnostics["interior_evaluator"], "full")

    def test_solver_diagnostics_report_actual_arithmetic(self):
        evaluator = search()
        node = evaluator._make_node(snapshot(), ([0.5, 0.5], [0.5, 0.5], 0.0))
        node.solve_backend = "triton-anchored-f32-v1"
        evaluator._solver_backends = {node.solve_backend: 3, "rust-anchored-f64-v1": 1}
        diagnostics = evaluator._diagnostics(node)
        self.assertEqual(diagnostics["root_solver"], "triton-anchored-f32-v1")
        self.assertEqual(diagnostics["solver_cuda_matrices"], 3)
        self.assertEqual(diagnostics["solver_matrix_count"], 4)
        self.assertNotIn("solver_seconds_allocated", diagnostics)


if __name__ == "__main__":
    unittest.main()
