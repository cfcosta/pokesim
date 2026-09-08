from __future__ import annotations

import sys
import unittest
from dataclasses import replace
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import torch
from battle_training.decision import (
    DecisionSearchError,
    decide_battle,
    warm_decision_network,
)
from battle_training.joint_search import JointSearchConfig, SearchResult
from battle_training.native import NativeRequestTimeout


class _Clock:
    now = 0.0

    def __call__(self):
        return self.now


def _result(policy=(0.75, 0.25), **extra):
    return SearchResult(
        player_policy=policy,
        enemy_policy=(0.2, 0.8),
        player_action=0,
        enemy_action=1,
        root_value=0.4,
        nodes=4,
        solver="test-complete-matrix",
        exploitability=0.01,
        payoff_spread=0.5,
        payoff_matrix=((0.4, 0.2), (0.1, 0.3)),
        diagnostics={"root_joint_actions": 4, "chance_outcomes": 4},
        **extra,
    )


class DecisionTests(unittest.TestCase):
    def setUp(self):
        self.clock = _Clock()
        self.server = SimpleNamespace(
            search_rows_requested=0, search_rows_deduplicated=0
        )
        self.network = SimpleNamespace(config=SimpleNamespace(action_count=2))
        self.snapshot = SimpleNamespace(
            player_mask=3, enemy_mask=3, done=False, divergence=None
        )
        self.config = JointSearchConfig(
            max_depth=2,
            chance_samples_per_joint=4,
            interior_actions_per_side=2,
        )

    def _decide(self, durations, results=None, **kwargs):
        records = []
        results = iter(results or [_result()] * len(durations))
        durations = iter(durations)

        def constructor(server, player, enemy, config, selection, chance, **options):
            records.append(
                (server, player, enemy, config, chance.getrandbits(64), options)
            )

            def search(snapshot, *, sample_actions):
                self.assertIs(snapshot, self.snapshot)
                self.assertFalse(sample_actions)
                self.clock.now += next(durations)
                server.search_rows_requested += 4
                result = next(results)
                if isinstance(result, Exception):
                    raise result
                return result

            return SimpleNamespace(search=search)

        with mock.patch(
            "battle_training.decision.SimultaneousTreeSearch", side_effect=constructor
        ):
            report = decide_battle(
                self.server,
                self.network,
                self.snapshot,
                search_config=self.config,
                clock=self.clock,
                **kwargs,
            )
        return report, records

    def test_first_complete_search_is_returned_with_explicit_overrun(self):
        report, records = self._decide([3.2])
        self.assertEqual(len(records), 1)
        self.assertEqual(len(report.passes), 1)
        self.assertAlmostEqual(report.budget_overrun_seconds, 0.2)
        self.assertEqual(report.stop_reason, "budget-exhausted")
        self.assertEqual(report.policy.dtype, torch.float32)
        self.assertEqual(report.policy.device.type, "cpu")
        self.assertEqual(report.policy.tolist(), [0.75, 0.25])
        self.assertAlmostEqual(report.value.item(), 0.4)

    def test_serving_defaults_match_production_search_settings(self):
        self.config = None
        _, records = self._decide([3.1])
        config = records[0][3]
        self.assertEqual(config.redundant_action_prior_scale, 0.25)
        self.assertEqual(config.interior_chance_samples, 2)
        self.assertEqual(config.leaf_evaluator, "full")
        self.assertEqual(config.solver_backend, "auto")

    def test_next_pass_is_not_started_when_estimate_does_not_fit(self):
        report, records = self._decide([1.2])
        self.assertEqual(len(records), 1)
        self.assertEqual(report.stop_reason, "next-pass-would-exceed-budget")
        self.assertEqual(report.elapsed_seconds, 1.2)
        self.assertGreater(report.next_pass_estimate_seconds, 1.8)

    def test_depth_is_preferred_after_two_chance_samples(self):
        report, records = self._decide([0.05, 0.05, 0.05, 0.05])
        self.assertEqual(
            [
                (record[3].max_depth, record[3].chance_samples_per_joint)
                for record in records
            ],
            [(1, 1), (1, 2), (2, 2), (2, 4)],
        )
        self.assertEqual(report.stop_reason, "search-limits-reached")
        self.assertEqual(report.selected_depth, 2)
        self.assertEqual(report.selected_chance_samples, 4)
        self.assertEqual(len({record[4] for record in records}), 1)

    def test_chance_refinement_is_used_when_more_depth_will_not_fit(self):
        report, records = self._decide([0.4, 0.4, 0.4], budget_seconds=2.0)
        self.assertEqual(
            [
                (record[3].max_depth, record[3].chance_samples_per_joint)
                for record in records
            ],
            [(1, 1), (1, 2), (1, 4)],
        )
        self.assertEqual(report.selected_depth, 1)

    def test_failed_refinement_preserves_last_completed_matrix(self):
        failed = replace(
            _result(), failure="search-semantic-divergence", payoff_matrix=None
        )
        report, records = self._decide(
            [0.1, 0.2], [_result(), failed], sample_action=False
        )
        self.assertEqual(len(records), 2)
        self.assertEqual(report.action, 0)
        self.assertEqual(report.selected_chance_samples, 1)
        self.assertEqual(report.stop_reason, "refinement-failed")
        self.assertFalse(report.passes[-1].completed)
        self.assertEqual(report.passes[-1].failure, "search-semantic-divergence")
        self.assertEqual(report.total_nodes, 8)

    def test_initial_failure_cannot_be_reported_as_search_assisted(self):
        failed = replace(
            _result(), failure="search-semantic-divergence", payoff_matrix=None
        )
        with self.assertRaisesRegex(DecisionSearchError, "no complete search"):
            self._decide([0.1], [failed])

    def test_native_timeout_is_fatal_even_after_a_complete_pass(self):
        with self.assertRaisesRegex(
            DecisionSearchError, "recreate the server"
        ) as caught:
            self._decide([0.1, 60.0], [_result(), NativeRequestTimeout("batch", 60.0)])
        self.assertIsInstance(caught.exception.__cause__, NativeRequestTimeout)

    def test_unpredicted_later_overrun_is_reported_with_complete_result(self):
        report, records = self._decide([0.1, 3.0])
        self.assertEqual(len(records), 2)
        self.assertEqual(report.selected_chance_samples, 2)
        self.assertAlmostEqual(report.budget_overrun_seconds, 0.1)
        self.assertTrue(all(item.completed for item in report.passes))

    def test_tensor_outputs_remain_cpu_when_default_device_is_changed(self):
        with torch.device("meta"):
            report, _ = self._decide([3.1])
        self.assertEqual(report.policy.device.type, "cpu")
        self.assertEqual(report.opponent_policy.device.type, "cpu")
        self.assertEqual(report.value.device.type, "cpu")

    def test_missing_matrix_is_not_accepted_as_complete_search(self):
        with self.assertRaisesRegex(DecisionSearchError, "no complete search"):
            self._decide([0.1], [replace(_result(), payoff_matrix=None)])

    def test_enemy_controller_uses_own_policy_and_value_perspective(self):
        report, records = self._decide([3.1], side="enemy", sample_action=False)
        self.assertIs(records[0][1], self.network)
        self.assertIs(records[0][2], self.network)
        self.assertEqual(records[0][-1], {"evaluation_side": "enemy"})
        self.assertEqual(report.action, 1)
        self.assertAlmostEqual(report.policy[1].item(), 0.8)
        self.assertAlmostEqual(report.value.item(), -0.4)
        self.assertIsNone(report.search_result.player_action)
        self.assertEqual(report.search_result.enemy_action, 1)

    def test_default_action_sampling_preserves_mixed_policy(self):
        actions = []
        for seed in range(30):
            self.clock.now = 0.0
            report, _ = self._decide([3.1], seed=seed)
            actions.append(report.action)
        self.assertEqual(set(actions), {0, 1})

    def test_invalid_budget_fails_before_search(self):
        for budget in (0.0, -1.0, float("inf"), float("nan")):
            with (
                self.subTest(budget=budget),
                self.assertRaisesRegex(ValueError, "budget_seconds"),
            ):
                self._decide([], budget_seconds=budget)

    def test_terminal_root_fails_before_search(self):
        self.snapshot.done = True
        with self.assertRaisesRegex(ValueError, "terminal"):
            self._decide([])

    def test_inference_root_must_cover_every_legal_action(self):
        self.config = replace(self.config, max_actions_per_side=1)
        with self.assertRaisesRegex(ValueError, "every legal root action"):
            self._decide([])

    def test_illegal_policy_mass_is_rejected(self):
        self.snapshot.player_mask = 1
        with self.assertRaisesRegex(DecisionSearchError, "no complete search"):
            self._decide([0.1], [_result()])


class DecisionWarmupTests(unittest.TestCase):
    def setUp(self):
        self.clock = _Clock()
        self.calls = []
        self.resolved = []
        self.network = SimpleNamespace(
            config=SimpleNamespace(
                joint_policy_heads=True,
                distilled_leaf_evaluator=True,
                distilled_leaf_policy=True,
                precision="bf16",
            ),
            _inference_engine="compiled",
            eval=lambda: None,
        )
        for kind in (
            "evaluate",
            "evaluate_joint",
            "evaluate_leaf",
            "evaluate_leaf_joint",
        ):

            def begin(features, *masks, kind=kind):
                entry = (kind, tuple(tuple(row) for row in features), masks)
                self.calls.append(entry)

                def result():
                    self.resolved.append(entry)
                    self.clock.now += 0.01

                return SimpleNamespace(result=result)

            setattr(self.network, f"begin_{kind}", begin)
        self.snapshot = SimpleNamespace(
            player_features=[1, 2], enemy_features=[3, 4], player_mask=3, enemy_mask=1
        )

    def test_every_static_bucket_and_deferred_evaluation_path_is_settled(self):
        report = warm_decision_network(self.network, self.snapshot, clock=self.clock)
        self.assertEqual(report.bucket_sizes, (2, 4, 8, 16, 32, 64, 96, 128, 192, 256))
        self.assertEqual(report.launches, 2 * 10 * 4)
        self.assertEqual(self.calls, self.resolved)
        self.assertAlmostEqual(report.elapsed_seconds, 0.8)
        self.assertEqual(report.precision, "bf16")
        self.assertEqual({len(row[1]) for row in self.calls}, set(report.bucket_sizes))
        self.assertTrue(
            all(
                {features for features in row[1]} == {(1, 2), (3, 4)}
                for row in self.calls
            )
        )

    def test_partial_last_bucket_does_not_exceed_inference_batch_limit(self):
        report = warm_decision_network(
            self.network,
            self.snapshot,
            search_config=JointSearchConfig(inference_batch_size=10),
            clock=self.clock,
        )
        self.assertEqual(report.bucket_sizes, (2, 4, 8, 16))
        self.assertEqual({len(row[1]) for row in self.calls}, {2, 4, 8, 10})

    def test_unavailable_optional_network_heads_are_not_invoked(self):
        self.network.config.joint_policy_heads = False
        self.network.config.distilled_leaf_policy = False
        self.network.config.distilled_leaf_evaluator = False
        report = warm_decision_network(self.network, self.snapshot, clock=self.clock)
        self.assertEqual(report.evaluation_kinds, ("evaluate",))
        self.assertEqual(report.launches, 20)


if __name__ == "__main__":
    unittest.main()
