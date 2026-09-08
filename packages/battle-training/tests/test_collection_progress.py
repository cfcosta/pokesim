from __future__ import annotations

import json
import sys
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import torch
from battle_training import transformer_pipeline as pipeline
from battle_training.monitor import build_dashboard_snapshot, build_match_detail
from battle_training.native import SearchServer
from battle_training.network import BattleTransformer, TransformerConfig


class _ProbeComplete(Exception):
    pass


class CollectionProgressTests(unittest.TestCase):
    def test_finished_battle_is_visible_while_its_batch_is_still_running(self):
        class OneFinishedServer(SearchServer):
            def episode_steps(self, steps):
                snapshots = super().episode_steps(steps)
                return [
                    replace(
                        s,
                        done=index == 0,
                        terminal=index == 0,
                        terminal_return=1 if index == 0 else None,
                    )
                    for index, s in enumerate(snapshots)
                ]

        config = pipeline.TransformerPipelineConfig(
            iterations=1,
            selfplay_episodes=4,
            arena_episodes=4,
            episode_budget=4,
            search_depth=1,
            epochs=1,
            batch_size=1,
            learning_rate=1e-3,
            weight_decay=0,
            seed=1,
            device="cpu",
            d_model=8,
            heads=2,
            layers=1,
            feedforward=16,
            actor_batch_size=2,
            actor_processes=1,
            frontier_buffer_size=0,
            regret_iterations=8,
            max_actions_per_side=2,
        )
        self.addCleanup(torch.set_num_threads, torch.get_num_threads())
        torch.set_num_threads(1)
        network = BattleTransformer(
            TransformerConfig(
                feature_count=492,
                action_count=13,
                d_model=8,
                heads=2,
                layers=1,
                feedforward=16,
                joint_policy_heads=True,
            )
        ).eval()
        search = pipeline.search_controllers_many
        calls = 0
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            progress = root / ".monitor" / "actor-00.json"

            def observe_search(*args, **kwargs):
                nonlocal calls
                calls += 1
                if calls == 1:
                    report = json.loads(progress.read_text())
                    self.assertEqual(report["active_battles"], 2)
                    self.assertEqual(report["decision"], 0)
                    self.assertEqual(report["completed"], 0)
                if calls == 2:
                    report = json.loads(progress.read_text())
                    self.assertEqual(report["completed"], 1)
                    self.assertEqual(report["finished"], 1)
                    self.assertEqual(report["active_battles"], 1)
                    self.assertEqual(report["decision"], 1)
                    self.assertEqual(report["transitions"], 2)
                    self.assertEqual(report["mean_decisions"], 1)
                    self.assertGreater(report["examples"], 0)
                    dashboard = build_dashboard_snapshot(root)
                    self.assertEqual(dashboard["collection"]["completed"], 1)
                    self.assertEqual(dashboard["collection"]["active_battles"], 1)
                    battle = build_match_detail(root, "selfplay", 1, 0)
                    self.assertEqual(battle["stop"], "finished")
                    self.assertEqual(len(battle["timeline"]), 1)
                    self.assertFalse((root / "shard.jsonl").exists())
                    raise _ProbeComplete
                return search(*args, **kwargs)

            with (
                patch.object(pipeline, "SearchServer", OneFinishedServer),
                patch.object(pipeline, "search_controllers_many", observe_search),
                self.assertRaises(_ProbeComplete),
            ):
                pipeline._collect_rows_single(
                    root / "shard.jsonl",
                    network,
                    config,
                    1,
                    episode_indices=[0, 1],
                    progress_path=progress,
                )

            # Reporting must not change the generated shard or double-count
            # battles when the rest of the batch finishes.
            with patch.object(pipeline, "SearchServer", OneFinishedServer):
                for filename, progress_path in [
                    ("with.jsonl", progress),
                    ("without.jsonl", None),
                ]:
                    pipeline._collect_rows_single(
                        root / filename,
                        network,
                        config,
                        1,
                        episode_indices=[0, 1],
                        progress_path=progress_path,
                    )
            self.assertEqual(
                (root / "with.jsonl").read_bytes(),
                (root / "without.jsonl").read_bytes(),
            )
            report = json.loads(progress.read_text())
            self.assertEqual(report["completed"], 2)
            self.assertEqual(report["active_battles"], 0)
            self.assertEqual(report["finished"], 2)
            self.assertEqual(report["mean_decisions"], 1.5)


if __name__ == "__main__":
    unittest.main()
