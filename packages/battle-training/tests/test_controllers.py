from __future__ import annotations

import random
import sys
import unittest
from dataclasses import replace
from pathlib import Path
from types import SimpleNamespace

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from battle_training.controller import search_controllers_many
from battle_training.joint_search import JointSearchConfig, SimultaneousTreeSearch
from battle_training.native import Snapshot
from battle_training.network import BattleTransformer, TransformerConfig


class _MatrixNetwork:
    """A known continuation payoff, with deliberately independent view heads."""

    supports_deferred_evaluation = False

    def __init__(self, matrix, *, enemy_matrix=None):
        self.matrix = matrix
        self.enemy_matrix = matrix if enemy_matrix is None else enemy_matrix
        self.views = []
        self.config = SimpleNamespace(
            action_count=2,
            joint_policy_heads=True,
            distilled_leaf_evaluator=False,
            distilled_leaf_policy=False,
        )

    def evaluate_joint(self, features, own_masks, opponent_masks):
        values = []
        for feature in features:
            view, leaf, player, enemy = feature[-4:]
            self.views.append(int(view))
            matrix = self.matrix if view == 0 else self.enemy_matrix
            value = 0.0 if leaf == 0 else matrix[player][enemy]
            values.append(value if view == 0 else -value)
        priors = [[0.5, 0.5] for _ in features]
        return priors, priors, values


class _DirectNetwork(_MatrixNetwork):
    search_assisted = False

    def __init__(self):
        super().__init__([[0.0, 0.0], [0.0, 0.0]])
        self.direct_calls = 0

    def evaluate(self, features, masks):
        self.direct_calls += len(features)
        return [[0.0, 1.0] for _ in features], [0.0 for _ in features]

    def evaluate_joint(self, *args):
        raise AssertionError("a direct policy must never be searched")


class _LeafNetwork(_MatrixNetwork):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.config.distilled_leaf_evaluator = True
        self.config.distilled_leaf_policy = True
        self.leaf_views = []

    def evaluate_leaf(self, features):
        self.leaf_views.extend(int(feature[-4]) for feature in features)
        return self.evaluate_joint(features, [], [])[2]

    def evaluate_leaf_joint(self, features, own_masks, opponent_masks):
        self.leaf_views.extend(int(feature[-4]) for feature in features)
        return self.evaluate_joint(features, own_masks, opponent_masks)


class _ShapedNetwork(BattleTransformer):
    supports_deferred_evaluation = False

    def __init__(self):
        super().__init__(
            TransformerConfig(
                feature_count=492,
                action_count=2,
                d_model=8,
                heads=2,
                layers=1,
                feedforward=16,
                joint_policy_heads=True,
                distilled_leaf_evaluator=True,
                distilled_leaf_policy=True,
            )
        )

    def evaluate_joint(self, features, own_masks, opponent_masks):
        return (
            [[0.5, 0.5] for _ in features],
            [[0.5, 0.5] for _ in features],
            [0.0 for _ in features],
        )

    evaluate_leaf_joint = evaluate_joint


class _MatrixServer:
    def __init__(self):
        self.count = 0
        self.chance_requests = []

    @staticmethod
    def snapshot(handle=0, player=0, enemy=0):
        features = np.zeros(492, dtype=np.int64)
        features[-4:] = (0, int(handle != 0), player, enemy)
        enemy_features = features.copy()
        enemy_features[-4] = 1
        return Snapshot(
            handle=handle,
            player_features=features,
            enemy_features=enemy_features,
            player_mask=3,
            enemy_mask=3,
            player_hash="",
            enemy_hash="",
            turn=int(handle != 0),
            terminal=False,
            done=False,
            terminal_return=None,
            request="battle",
            divergence=None,
        )

    def search_steps(self, requests):
        result = []
        for handle, player, enemy, seed in requests:
            self.chance_requests.append((handle, player, enemy, seed))
            self.count += 1
            result.append(self.snapshot(self.count, player, enemy))
        return result


class _InteriorDivergentServer(_MatrixServer):
    def search_steps(self, requests):
        successors = super().search_steps(requests)
        return [
            replace(snapshot, divergence="interior-native-divergence")
            if request[0] != 0 and request[1:3] == (1, 1)
            else snapshot
            for request, snapshot in zip(requests, successors, strict=True)
        ]


class IndependentControllersTest(unittest.TestCase):
    def decision(
        self, player, enemy, *, sample=False, selection=None, chance=None, **settings
    ):
        server = _MatrixServer()
        template = SimultaneousTreeSearch(
            server,
            player,
            enemy,
            JointSearchConfig(
                max_depth=1,
                chance_samples_per_joint=2,
                max_actions_per_side=2,
                prior_anchor_temperature=0.0,
                **settings,
            ),
            random.Random(7) if selection is None else selection,
            random.Random(11) if chance is None else chance,
        )
        decision = search_controllers_many([template], [server.snapshot()], sample)[0]
        return decision, server

    def test_opponent_values_cannot_change_player_controller(self):
        candidate = _MatrixNetwork([[0.8, 0.8], [-0.8, -0.8]])
        first, _ = self.decision(candidate, _MatrixNetwork([[0.9, -0.9], [0.9, -0.9]]))
        second, _ = self.decision(candidate, _MatrixNetwork([[-0.9, 0.9], [-0.9, 0.9]]))
        self.assertEqual(first.player.player_policy, second.player.player_policy)
        self.assertEqual(first.player.payoff_matrix, second.player.payoff_matrix)
        self.assertEqual(first.player.player_action, 0)
        self.assertNotEqual(first.enemy.enemy_action, second.enemy.enemy_action)
        self.assertEqual(set(candidate.views), {0})

    def test_enemy_controller_uses_its_own_view_and_keeps_both_teacher_heads(self):
        candidate = _MatrixNetwork(
            [[0.8, -0.8], [0.8, -0.8]],
            enemy_matrix=[[-0.8, 0.8], [-0.8, 0.8]],
        )
        first, _ = self.decision(_MatrixNetwork([[0.8, 0.8], [-0.8, -0.8]]), candidate)
        second, _ = self.decision(_MatrixNetwork([[-0.8, -0.8], [0.8, 0.8]]), candidate)
        self.assertEqual(first.enemy.player_policy, second.enemy.player_policy)
        self.assertEqual(first.enemy.enemy_policy, second.enemy.enemy_policy)
        self.assertEqual(first.enemy.enemy_action, 0)
        self.assertEqual(set(candidate.views), {1})
        self.assertNotEqual(first.player.player_action, second.player.player_action)

    def test_mirror_evaluates_both_canonical_views_without_assuming_symmetry(self):
        network = _MatrixNetwork(
            [[0.8, -0.8], [0.8, -0.8]],
            enemy_matrix=[[-0.8, 0.8], [-0.8, 0.8]],
        )
        decision, server = self.decision(network, network)
        self.assertEqual(set(network.views), {0, 1})
        self.assertEqual(decision.enemy.enemy_action, 0)
        self.assertIsNot(decision.player, decision.enemy)
        # Both private payoff estimates use the same chance worlds for each cell.
        seeds = [request[3] for request in server.chance_requests]
        self.assertEqual(seeds[: len(seeds) // 2], seeds[len(seeds) // 2 :])

    def test_direct_opponent_is_sampled_without_a_search_or_value_blending(self):
        candidate = _MatrixNetwork([[0.8, 0.8], [-0.8, -0.8]])
        direct = _DirectNetwork()
        decision, _ = self.decision(candidate, direct)
        self.assertEqual(decision.player.player_action, 0)
        self.assertEqual(decision.enemy.enemy_action, 1)
        self.assertAlmostEqual(decision.player.root_value, 0.8, places=2)
        self.assertEqual(direct.direct_calls, 1)
        self.assertIsNone(decision.enemy.payoff_matrix)

    def test_controller_kind_cannot_change_candidate_random_stream(self):
        candidate = _MatrixNetwork([[0.0, 0.0], [0.0, 0.0]])
        selection = [random.Random(8), random.Random(8)]
        chance = [random.Random(12), random.Random(12)]
        opponents = [_DirectNetwork(), _MatrixNetwork([[0.9, -0.9], [0.9, -0.9]])]
        decisions = [
            self.decision(
                candidate,
                opponent,
                sample=True,
                selection=selection[i],
                chance=chance[i],
            )[0]
            for i, opponent in enumerate(opponents)
        ]
        self.assertEqual(
            decisions[0].player.player_action, decisions[1].player.player_action
        )
        self.assertEqual(selection[0].getstate(), selection[1].getstate())
        self.assertEqual(chance[0].getstate(), chance[1].getstate())

    def test_executed_actions_have_no_fictitious_shared_equilibrium(self):
        decision, _ = self.decision(
            _MatrixNetwork([[0.8, 0.8], [-0.8, -0.8]]),
            _MatrixNetwork([[0.8, -0.8], [0.8, -0.8]]),
        )
        result = decision.executed()
        self.assertEqual((result.player_action, result.enemy_action), (0, 1))
        self.assertIsNone(result.payoff_matrix)
        self.assertIsNone(result.exploitability)
        self.assertIn("player_root_value", result.diagnostics)
        self.assertIn("enemy_root_value", result.diagnostics)

    def test_distilled_values_use_each_controllers_canonical_view(self):
        candidate = _LeafNetwork(
            [[0.8, -0.8], [0.8, -0.8]],
            enemy_matrix=[[-0.8, 0.8], [-0.8, 0.8]],
        )
        decision, _ = self.decision(
            _DirectNetwork(), candidate, leaf_evaluator="distilled"
        )
        self.assertEqual(decision.enemy.enemy_action, 0)
        self.assertEqual(set(candidate.leaf_views), {1})

    def test_full_mode_does_not_depend_on_unrelated_distilled_roots(self):
        server = _MatrixServer()
        network = _LeafNetwork([[0.1, 0.1], [0.1, 0.1]])
        searches = [
            SimultaneousTreeSearch(
                server,
                network,
                network,
                JointSearchConfig(leaf_evaluator=mode),
                random.Random(1),
                random.Random(2),
            )
            for mode in ("full", "distilled")
        ]
        roots = [server.snapshot(), server.snapshot()]
        SimultaneousTreeSearch._pooled_successor_values(
            [(i, search, [roots[i]]) for i, search in enumerate(searches)]
        )
        self.assertEqual(network.leaf_views, [0])
        self.assertEqual(network.views, [0, 0])

    def test_pooled_prior_shaping_preserves_each_search_configuration(self):
        server = _MatrixServer()
        network = _ShapedNetwork()
        snapshot = server.snapshot()
        features = snapshot.player_features.copy()
        features[140] = 86  # Thunder Wave against an already paralyzed target.
        features[317] = 0x40
        snapshot = replace(snapshot, player_features=features)
        for evaluator in (
            SimultaneousTreeSearch._pooled_evaluate,
            SimultaneousTreeSearch._pooled_leaf_evaluate,
        ):
            with self.subTest(evaluator=evaluator.__name__):
                searches = [
                    SimultaneousTreeSearch(
                        server,
                        network,
                        network,
                        JointSearchConfig(redundant_action_prior_scale=scale),
                        random.Random(1),
                        random.Random(2),
                    )
                    for scale in (1.0, 0.1)
                ]
                evaluated, _, _ = evaluator(
                    [
                        (index, search, [snapshot])
                        for index, search in enumerate(searches)
                    ]
                )
                self.assertAlmostEqual(evaluated[0][0][0][0], 0.5)
                self.assertAlmostEqual(evaluated[1][0][0][0], 1.0 / 11.0)

    def test_interior_mechanics_divergence_cannot_publish_fallback_actions(self):
        server = _InteriorDivergentServer()
        network = _MatrixNetwork([[0.8, 0.8], [-0.8, -0.8]])
        template = SimultaneousTreeSearch(
            server,
            network,
            network,
            JointSearchConfig(
                max_depth=2, max_actions_per_side=2, interior_actions_per_side=2
            ),
            random.Random(1),
            random.Random(2),
        )
        decision = search_controllers_many([template], [server.snapshot()])[0]
        self.assertEqual(decision.failure, "search-semantic-divergence")
        self.assertIsNone(decision.player.payoff_matrix)
        self.assertIsNone(decision.enemy.payoff_matrix)
        result = decision.executed()
        self.assertIsNone(result.player_action)
        self.assertIsNone(result.enemy_action)


if __name__ == "__main__":
    unittest.main()
