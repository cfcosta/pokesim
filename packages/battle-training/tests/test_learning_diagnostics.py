from __future__ import annotations

import json
import math
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import torch
from battle_training.transformer_pipeline import (
    _example_rows,
    _heldout_diagnostics,
    _load_examples,
    _load_partitioned_examples,
    _rows_to_examples,
)


class _FixedNetwork(torch.nn.Module):
    def __init__(self, logits: list[list[float]], opponent_logits=None, *, leaf=False):
        super().__init__()
        self.anchor = torch.nn.Parameter(torch.zeros(()))
        self.register_buffer("logits", torch.tensor(logits))
        self.register_buffer(
            "opponent_logits",
            torch.tensor(opponent_logits if opponent_logits is not None else logits),
        )
        self.config = SimpleNamespace(
            joint_policy_heads=True,
            distilled_leaf_policy=leaf,
            distilled_leaf_evaluator=leaf,
        )

    def forward_joint(self, features):
        indices = features[:, 0]
        return (
            self.logits[indices],
            self.opponent_logits[indices],
            torch.zeros(len(features), device=features.device),
        )

    def leaf_joint_forward(self, features):
        return self.forward_joint(features)


def _row(episode: int, feature: int, **extra) -> dict:
    return {
        "type": "example",
        "episode": episode,
        "features": [feature],
        "policy": [1.0, 0.0],
        "opponent_policy": [1.0, 0.0],
        "value": 1.0,
        "legal_mask": 3,
        **extra,
    }


class HeldoutMetricTests(unittest.TestCase):
    def _diagnostics(self, network, rows, *, floor=1.0, batch_size=2):
        return _heldout_diagnostics(
            network,
            _rows_to_examples(rows, floor),
            [(1, row["episode"]) for row in rows],
            batch_size,
        )

    def test_two_correct_policy_heads_report_full_agreement(self):
        report = self._diagnostics(_FixedNetwork([[2.0, 0.0]]), [_row(0, 0)])
        self.assertEqual(report["policy_top_action_agreement"], 1.0)

    def test_one_correct_policy_head_reports_half_agreement(self):
        report = self._diagnostics(
            _FixedNetwork([[2.0, 0.0]], [[0.0, 2.0]]), [_row(0, 0)]
        )
        self.assertEqual(report["policy_top_action_agreement"], 0.5)

    def test_agreement_uses_fractional_reliability_weights(self):
        rows = [
            _row(0, 0, root_split_half_distance=0.75),
            _row(1, 1, root_split_half_distance=0.0),
            _row(2, 0, target_kind="policy-rollout"),
        ]
        report = self._diagnostics(
            _FixedNetwork([[2.0, 0.0], [0.0, 2.0]]), rows, floor=0.0
        )
        self.assertAlmostEqual(report["policy_top_action_agreement"], 0.2)

    def test_small_weight_sum_does_not_shrink_policy_metrics(self):
        report = self._diagnostics(
            _FixedNetwork([[2.0, 0.0]], leaf=True),
            [_row(0, 0, root_split_half_distance=0.9)],
            floor=0.0,
        )
        expected = math.log1p(math.exp(-2.0))
        self.assertAlmostEqual(report["policy_cross_entropy"], expected, places=6)
        self.assertAlmostEqual(report["policy_kl"], expected, places=6)
        self.assertAlmostEqual(report["leaf_policy_kl"], expected, places=6)
        self.assertEqual(report["policy_top_action_agreement"], 1.0)

    def test_no_policy_targets_reports_unavailable_policy_metrics(self):
        report = self._diagnostics(
            _FixedNetwork([[2.0, 0.0]], leaf=True),
            [_row(0, 0, target_kind="policy-rollout")],
        )
        for name in (
            "policy_cross_entropy",
            "policy_target_entropy",
            "policy_kl",
            "leaf_policy_kl",
            "policy_top_action_agreement",
        ):
            self.assertIsNone(report[name], name)
        self.assertEqual(report["value_mse_equal_row"], 1.0)

    def test_metrics_do_not_depend_on_batch_size(self):
        network = _FixedNetwork([[2.0, 0.0], [0.0, 2.0]], leaf=True)
        rows = [
            _row(0, 0, root_split_half_distance=0.75),
            _row(1, 1, root_split_half_distance=0.0),
            _row(1, 0, root_split_half_distance=0.5),
        ]
        individual = self._diagnostics(network, rows, floor=0.0, batch_size=1)
        batched = self._diagnostics(network, rows, floor=0.0, batch_size=3)
        for name, value in individual.items():
            if isinstance(value, float):
                self.assertAlmostEqual(value, batched[name], places=6, msg=name)
            else:
                self.assertEqual(value, batched[name], name)


class ResetPairSplitTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def _write(self, iteration, rows, *, name=None):
        path = self.root / (name or f"iteration-{iteration:03d}.jsonl")
        records = [{"type": "meta", "iteration": iteration}, *rows]
        path.write_text("".join(json.dumps(row) + "\n" for row in records))
        return path

    def _features(self, paths):
        training, heldout, battles = _load_partitioned_examples(paths)
        return set(training[0][:, 0].tolist()), set(heldout[0][:, 0].tolist()), battles

    def test_legacy_paired_legs_and_all_their_rows_stay_together(self):
        rows = [_row(episode, episode) for episode in range(40)]
        rows += [_row(episode, episode) for episode in range(40)]
        path = self._write(1, rows)
        training, heldout, battles = self._features([path])
        self.assertEqual(heldout, {0, 1, 20, 21})
        self.assertEqual(training, set(range(40)) - heldout)
        self.assertEqual(len(battles), 8)
        self.assertFalse({ep // 2 for ep in training} & {ep // 2 for ep in heldout})

    def test_four_game_smoke_has_two_whole_pairs_every_iteration(self):
        for iteration in range(1, 13):
            with self.subTest(iteration=iteration):
                path = self._write(iteration, [_row(ep, ep) for ep in range(4)])
                training, heldout, _ = self._features([path])
                self.assertEqual(training, {2, 3})
                self.assertEqual(heldout, {0, 1})

    def test_frontier_and_hard_team_replays_follow_original_reset(self):
        paths = []
        # Two subsequent shards move each original reset to a different pair.
        # Episode records deliberately follow examples, as in actor output.
        for iteration, origins in ((1, [0, 1, 2]), (2, [2, 0, 1]), (3, [1, 2, 0])):
            rows = []
            for pair, reset_episode in enumerate(origins):
                for leg in range(2):
                    episode = pair * 2 + leg
                    rows.append(
                        _row(episode, reset_episode * 100 + iteration * 10 + leg)
                    )
                    rows.append(
                        {
                            "type": "episode",
                            "episode": episode,
                            "pair": pair,
                            "reset_seed": 1234,
                            "reset_episode": reset_episode,
                            "teams_swapped": bool(leg),
                            "frontier_restart": iteration == 2,
                            "team_replay": iteration == 3,
                        }
                    )
            paths.append(self._write(iteration, rows))
        training, heldout, _ = self._features(paths)
        self.assertEqual({value // 100 for value in training}, {1, 2})
        self.assertEqual({value // 100 for value in heldout}, {0})
        for subset in (paths[:2], paths[1:], list(reversed(paths))):
            sub_training, sub_heldout, _ = self._features(subset)
            self.assertLessEqual(sub_training, training)
            self.assertLessEqual(sub_heldout, heldout)

    def test_direct_example_provenance_supports_compact_shards(self):
        path = self._write(
            3,
            [
                _row(0, 0, reset_seed=1234, reset_episode=1),
                _row(1, 1, reset_seed=1234, reset_episode=1),
                _row(2, 2, reset_seed=1234, reset_episode=0),
                _row(3, 3, reset_seed=1234, reset_episode=0),
            ],
        )
        training, heldout, _ = self._features([path])
        self.assertEqual(training, {0, 1})
        self.assertEqual(heldout, {2, 3})

    def test_metadata_iteration_survives_shard_renaming(self):
        path = self._write(7, [_row(ep, ep) for ep in range(4)], name="copy.jsonl")
        self.assertEqual({row["shard_iteration"] for row in _example_rows([path])}, {7})

    def test_legacy_replay_ancestry_resolves_through_multiple_shards(self):
        original = self._write(1, [_row(ep, ep) for ep in range(4)])
        frontier = self._write(
            2,
            [
                _row(0, 20),
                _row(2, 22),
                {
                    "type": "episode",
                    "episode": 2,
                    "frontier_source": {"iteration": 1, "episode": 2},
                },
            ],
        )
        replay = self._write(
            3,
            [
                _row(0, 30),
                _row(2, 32),
                {
                    "type": "episode",
                    "episode": 0,
                    "team_replay_source": {"iteration": 2, "pair": 1},
                },
            ],
        )
        training, heldout, _ = self._features([replay, frontier, original])
        self.assertEqual(training, {2, 3, 22, 30, 32})
        self.assertEqual(heldout, {0, 1, 20})

    def test_legacy_replay_without_original_provenance_fails_clearly(self):
        path = self._write(
            3,
            [
                _row(0, 30),
                _row(2, 32),
                {
                    "type": "episode",
                    "episode": 0,
                    "frontier_source": {"iteration": 2, "episode": 2},
                },
            ],
        )
        with self.assertRaisesRegex(
            ValueError, "missing original reset-pair provenance"
        ):
            _load_partitioned_examples([path])

    def test_conflicting_pair_provenance_is_rejected(self):
        path = self._write(
            1,
            [
                _row(0, 0, reset_seed=1234, reset_episode=0),
                _row(1, 1, reset_seed=1234, reset_episode=1),
                _row(2, 2),
            ],
        )
        with self.assertRaisesRegex(ValueError, "conflicting reset-pair provenance"):
            _load_partitioned_examples([path])

    def test_cyclic_replay_ancestry_is_rejected(self):
        first = self._write(
            1,
            [_row(0, 0, team_replay_source={"iteration": 2, "pair": 0})],
        )
        second = self._write(
            2,
            [_row(0, 1, team_replay_source={"iteration": 1, "pair": 0})],
        )
        with self.assertRaisesRegex(ValueError, "cyclic reset-pair provenance"):
            _load_partitioned_examples([first, second])

    def test_single_reset_cannot_be_split_without_leakage(self):
        path = self._write(1, [_row(0, 0), _row(1, 1)])
        with self.assertRaisesRegex(ValueError, "reset-pair.*empty partition"):
            _load_partitioned_examples([path])

    def test_plain_tensor_loader_accepts_rows_without_battle_provenance(self):
        row = _row(0, 42)
        del row["episode"]
        path = self._write(1, [row])
        self.assertEqual(_load_examples([path])[0].tolist(), [[42]])
        with self.assertRaisesRegex(ValueError, "requires episode provenance"):
            _load_partitioned_examples([path])

    def test_sparse_reset_sample_fails_instead_of_moving_holdout_membership(self):
        path = self._write(1, [_row(ep, ep) for ep in range(2, 6)])
        with self.assertRaisesRegex(ValueError, "reset-pair.*empty partition"):
            _load_partitioned_examples([path])


if __name__ == "__main__":
    unittest.main()
