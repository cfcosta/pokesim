from __future__ import annotations

import json
import random
import sys
import tempfile
import unittest
from dataclasses import asdict, replace
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import torch
from battle_training.arena import (
    SkillMetrics,
    _evaluation_level100,
    _evaluation_party_sizes,
    _mean_ci95,
    _paired_coordinates,
    _setup_move_name,
    _update_side_metrics,
    skill_probe_report,
)
from battle_training.artifacts import (
    build_manifest,
    sha256,
    verify_manifest,
    write_json,
)
from battle_training.cli import parser as training_parser
from battle_training.decision_quality import (
    DecisionQualityMetrics,
    classify_feature_decision,
    shape_redundant_action_priors,
)
from battle_training.joint_search import (
    JointSearchConfig,
    SimultaneousTreeSearch,
    _cap_switch_mass,
    _tactical_potential,
    solve_zero_sum_regret,
)
from battle_training.model import MoveValueModel
from battle_training.monitor import (
    build_dashboard_snapshot,
    build_match_detail,
    write_monitor_state,
)
from battle_training.native import Snapshot, _decode_features
from battle_training.network import (
    BattleTransformer,
    TransformerConfig,
    load_checkpoint,
    load_network,
    save_network,
    warm_start_network,
)
from battle_training.red_ai_heuristics import (
    TRAINER_CLASS_PROFILES,
    normalized_trainer_policy,
)
from battle_training.transformer_pipeline import (
    TransformerPipelineConfig,
    _collection_quality,
    _gradient_report,
    _heuristic_population,
    _load_completed_prefix,
    _load_examples,
    _pipeline_id,
    _resume_config,
    _scheduled_for_opponent,
    _select_training_opponent,
    _training_level100,
    _training_pair,
    _training_pair_leg,
    _training_party_sizes,
    _validate_collection_pairs,
)


def _toy_features() -> tuple[int, ...]:
    features = [0] * 492
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


class _DeferredEvaluation:
    def __init__(
        self,
        trace: list[str],
        name: str,
        result: tuple[list[list[float]], list[float]],
    ) -> None:
        self.trace = trace
        self.name = name
        self.output = result

    def result(self) -> tuple[list[list[float]], list[float]]:
        self.trace.append(f"result:{self.name}")
        return self.output


class _DeferredToyNetwork(_ToyNetwork):
    def __init__(self, trace: list[str], name: str) -> None:
        super().__init__()
        self.trace = trace
        self.name = name

    def begin_evaluate(self, features: object, masks: list[int]) -> _DeferredEvaluation:
        self.trace.append(f"begin:{self.name}")
        result = super().evaluate(features, masks)
        return _DeferredEvaluation(self.trace, self.name, result)

    def evaluate(
        self, features: object, masks: list[int]
    ) -> tuple[list[list[float]], list[float]]:
        raise AssertionError("pooled inference serialized a deferred network")


class _JointToyNetwork(_ToyNetwork):
    config = SimpleNamespace(action_count=2, joint_policy_heads=True)

    def evaluate_joint(
        self,
        features: object,
        player_masks: list[int],
        enemy_masks: list[int],
    ) -> tuple[list[list[float]], list[list[float]], list[float]]:
        del features, enemy_masks
        self.batches.append(len(player_masks))
        return (
            [[1.0, 0.0] for _ in player_masks],
            [[0.0, 1.0] for _ in player_masks],
            [0.25 for _ in player_masks],
        )

    def evaluate(
        self, features: object, masks: list[int]
    ) -> tuple[list[list[float]], list[float]]:
        raise AssertionError("mirror search did not use joint evaluation")


class _LeafToyNetwork(_JointToyNetwork):
    config = SimpleNamespace(
        action_count=2,
        joint_policy_heads=True,
        distilled_leaf_evaluator=True,
    )

    def evaluate_leaf(self, features: object) -> list[float]:
        self.batches.append(len(features))  # type: ignore[arg-type]
        return [0.5 for _ in features]  # type: ignore[union-attr]


class _ToyServer:
    def __init__(self) -> None:
        self.states: dict[int, tuple[int, int]] = {0: (0, 0)}
        self.next_handle = 1
        self.batches: list[int] = []

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
        self.batches.append(len(requests))
        return [self.search_step(*request) for request in requests]


class _DivergentToyServer(_ToyServer):
    def search_steps(self, requests: list[tuple[int, int, int, int]]) -> list[Snapshot]:
        return [
            replace(snapshot, divergence="toy-search-divergence")
            for snapshot in super().search_steps(requests)
        ]


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


class MonitorTests(unittest.TestCase):
    def test_dashboard_projects_live_model_and_promotion_artifacts(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "metrics").mkdir()
            (root / "checkpoints").mkdir()
            (root / "run.json").write_text(
                json.dumps(
                    {
                        "pipeline": "transformer-test-v1",
                        "profile": "test-profile",
                        "schema": "test-schema",
                        "parameter_count": 1234,
                        "device": "cpu",
                        "network": {
                            "feature_count": 492,
                            "d_model": 32,
                            "heads": 4,
                            "layers": 1,
                            "feedforward": 64,
                            "precision": "bf16",
                            "token_group_size": 1,
                        },
                        "config": {"iterations": 2},
                    }
                )
            )
            (root / "checkpoints" / "policy-001.pt").write_bytes(b"checkpoint")
            (root / "metrics" / "iteration-001.json").write_text(
                json.dumps(
                    {
                        "collection": {"finished": 4, "examples": 20},
                        "training": {
                            "history": [{"policy_loss": 1.0, "value_loss": 0.5}]
                        },
                        "promotion": {
                            "accepted": True,
                            "score_with_nonfinishes_as_losses": 0.6,
                            "paired_score_ci95": [0.51, 0.69],
                            "battles": [{"game": 0, "score": 1.0}],
                        },
                    }
                )
            )
            write_monitor_state(root, "promotion", iteration=2, message="Running arena")
            snapshot = build_dashboard_snapshot(root)
            self.assertEqual(snapshot["status"]["stage"], "promotion")
            self.assertEqual(snapshot["model"]["checkpoint"]["iteration"], 1)
            self.assertEqual(snapshot["latest"]["promotion"]["battles"][0]["game"], 0)
            self.assertEqual(len(snapshot["iterations"]), 1)

    def test_monitor_cli_defaults_to_loopback(self) -> None:
        arguments = training_parser().parse_args(["monitor", "--run", "/tmp/training"])
        self.assertEqual(arguments.host, "127.0.0.1")
        self.assertEqual(arguments.port, 8765)
        self.assertFalse(arguments.open_browser)

    def test_dashboard_marks_a_dead_training_process_failed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "monitor-state.json").write_text(
                json.dumps(
                    {
                        "stage": "collection",
                        "pid": 2**31 - 1,
                        "iteration": 1,
                    }
                )
            )
            status = build_dashboard_snapshot(root)["status"]
            self.assertEqual(status["stage"], "failed")
            self.assertEqual(status["last_stage"], "collection")

    def test_monitor_loads_match_details_without_polling_all_timelines(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            progress = root / ".monitor"
            progress.mkdir()
            (progress / "actor-00.json").write_text(
                json.dumps(
                    {
                        "iteration": 2,
                        "recent_battles": [{"episode": 7, "timeline": [{"turn": 1}]}],
                    }
                )
            )
            live = build_match_detail(root, "selfplay", 2, 7)
            self.assertEqual(live["timeline"], [{"turn": 1}])
            write_json(
                root / "matches" / "promotion-002.json",
                {"battles": [{"game": 3, "timeline": [{"turn": 4}]}]},
            )
            promotion = build_match_detail(root, "promotion", 2, 3)
            self.assertEqual(promotion["timeline"], [{"turn": 4}])
            write_json(
                root / "matches" / "promotion-002" / "game-00004.json",
                {"game": 4, "timeline": [{"turn": 5}]},
            )
            direct = build_match_detail(root, "promotion", 2, 4)
            self.assertEqual(direct["timeline"], [{"turn": 5}])
            self.assertIsNone(build_match_detail(root, "promotion", 2, 5))

    def test_dashboard_aggregates_live_selfplay_results(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            progress = root / ".monitor"
            progress.mkdir()
            for process, player_wins in ((0, 3), (1, 2)):
                (progress / f"actor-{process:02d}.json").write_text(
                    json.dumps(
                        {
                            "process": process,
                            "decision_quality_version": "static-active-context-v1",
                            "species_schedule": "near-uniform-final-species-u16-v1",
                            "species_counts": {"001:Bulbasaur": 2, "151:Mew": 1},
                            "completed": 4,
                            "total": 10,
                            "finished": 4,
                            "player_wins": player_wins,
                            "enemy_wins": 4 - player_wins,
                            "transitions": 20,
                            "ordinary_actions": 16,
                            "voluntary_switches": 2,
                            "setup_uses": 3,
                            "setup_move_counts": {"Reflect": 2, "Agility": 1},
                            "mirror_episodes": 2,
                            "opponent_episodes": 2,
                            "model_opponent_episodes": 1,
                            "heuristic_opponent_episodes": 1,
                            "major_status_attempts": 4,
                            "redundant_status_same": 1,
                            "redundant_status_other": 1,
                            "stat_setup_attempts": 2,
                            "capped_stat_setup": 1,
                            "ohko_attempts": 2,
                            "ohko_into_faster": 1,
                            "party_size_counts": {"1v1": 4},
                            "recent_battles": [
                                {
                                    "episode": process,
                                    "stop": "finished",
                                    "return": 1,
                                    "initial": {"player": {}},
                                    "timeline": [{"turn": 1}],
                                }
                            ],
                        }
                    )
                )
            dashboard = build_dashboard_snapshot(root)
            collection = dashboard["collection"]
            self.assertEqual(collection["completed"], 8)
            self.assertEqual(collection["player_wins"], 5)
            self.assertEqual(collection["party_size_counts"]["1v1"], 8)
            self.assertEqual(collection["voluntary_switch_rate"], 0.125)
            self.assertEqual(collection["setup_uses"], 6)
            self.assertEqual(collection["setup_use_rate"], 0.1875)
            self.assertEqual(collection["setup_move_counts"]["Reflect"], 4)
            self.assertEqual(collection["mirror_episodes"], 4)
            self.assertEqual(collection["model_opponent_episodes"], 2)
            self.assertEqual(collection["heuristic_opponent_episodes"], 2)
            self.assertEqual(collection["redundant_status_rate"], 0.5)
            self.assertEqual(collection["capped_stat_setup_rate"], 0.5)
            self.assertEqual(collection["ohko_into_faster_rate"], 0.5)
            self.assertEqual(
                collection["decision_quality_version"], "static-active-context-v1"
            )
            self.assertEqual(collection["distinct_species"], 2)
            self.assertEqual(collection["minimum_species_appearances"], 2)
            self.assertEqual(collection["maximum_species_appearances"], 4)
            self.assertEqual(len(collection["recent_battles"]), 2)
            self.assertNotIn("timeline", collection["recent_battles"][0])
            self.assertNotIn("recent_battles", dashboard["actors"][0])


class TransformerTests(unittest.TestCase):
    def test_inference_engine_auto_falls_back_to_eager_on_cpu(self) -> None:
        network = BattleTransformer(
            TransformerConfig(
                feature_count=8,
                action_count=4,
                d_model=8,
                heads=2,
                layers=1,
                feedforward=16,
            )
        )
        network.configure_inference("auto")
        self.assertEqual(network.inference_engine, "eager")
        with self.assertRaisesRegex(ValueError, "requires CUDA"):
            network.configure_inference("compiled")

    def test_native_feature_decoding_supports_packed_and_fallback_rows(self) -> None:
        packed = {"feature_encoding": "u16le-base64", "player_features": "NBLNqw=="}
        fallback = {"player_features": [0x1234, 0xABCD]}
        packed_features = _decode_features(packed, "player")
        fallback_features = _decode_features(fallback, "player")
        self.assertEqual(packed_features.tolist(), [0x1234, 0xABCD])
        self.assertEqual(fallback_features.tolist(), [0x1234, 0xABCD])
        self.assertEqual(packed_features.dtype.str, "<u2")
        self.assertFalse(packed_features.flags.writeable)

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

    def test_search_divergence_never_falls_back_to_raw_policy_actions(self) -> None:
        server = _DivergentToyServer()
        network = _ToyNetwork()
        search = SimultaneousTreeSearch(
            server,  # type: ignore[arg-type]
            network,  # type: ignore[arg-type]
            network,  # type: ignore[arg-type]
            JointSearchConfig(
                max_depth=1,
                max_actions_per_side=2,
                expansion_budget=4,
                minimum_expansion_budget=1,
            ),
            random.Random(7),
            random.Random(11),
        )
        result = search.search(server._snapshot(0))
        self.assertEqual(result.failure, "search-semantic-divergence")
        self.assertIsNone(result.player_action)
        self.assertIsNone(result.enemy_action)
        self.assertEqual(sum(result.player_policy), 0.0)
        self.assertEqual(sum(result.enemy_policy), 0.0)
        self.assertEqual(result.solver, "rmplus-unavailable-on-semantic-divergence-v1")

    def test_cross_root_search_batches_and_caches_inference(self) -> None:
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
        self.assertEqual(max(network.batches), 1)
        self.assertGreater(max(server.batches), 4)
        self.assertTrue(
            all(result.diagnostics["inference_cache_hits"] > 0 for result in results)
        )
        self.assertTrue(
            all(result.diagnostics["deep_inference_waves"] > 0 for result in results)
        )
        self.assertTrue(
            all(result.diagnostics["mean_deep_native_batch"] >= 1 for result in results)
        )
        self.assertTrue(
            all(result.diagnostics["deep_overlap_waves"] > 0 for result in results)
        )

    def test_complete_root_and_deep_tiers_share_one_frontier(self) -> None:
        server = _ToyServer()
        server.states[100] = (0, 0)
        network = _ToyNetwork()
        configs = [
            JointSearchConfig(
                max_depth=2,
                inference_batch_size=32,
                max_actions_per_side=2,
                expansion_budget=1,
                minimum_expansion_budget=1,
            ),
            JointSearchConfig(
                max_depth=2,
                inference_batch_size=32,
                max_actions_per_side=2,
                expansion_budget=16,
                minimum_expansion_budget=4,
            ),
        ]
        results = SimultaneousTreeSearch.search_many(
            [
                SimultaneousTreeSearch(
                    server,  # type: ignore[arg-type]
                    network,  # type: ignore[arg-type]
                    network,  # type: ignore[arg-type]
                    config,
                    random.Random(index + 1),
                    random.Random(index + 101),
                )
                for index, config in enumerate(configs)
            ],
            [server._snapshot(0), server._snapshot(100)],
        )
        self.assertEqual(results[0].nodes, 4)
        self.assertGreater(results[1].nodes, results[0].nodes)
        self.assertIsNotNone(results[0].payoff_matrix)

    def test_cross_root_search_pools_shared_networks_across_opponents(self) -> None:
        server = _ToyServer()
        server.states[100] = (0, 0)
        candidate = _ToyNetwork()
        opponent = _ToyNetwork()
        config = JointSearchConfig(
            max_depth=2,
            inference_batch_size=32,
            max_actions_per_side=2,
            expansion_budget=16,
            chance_resample=1.0,
            regret_iterations_per_update=4,
            minimum_expansion_budget=4,
        )
        searches = [
            SimultaneousTreeSearch(
                server,  # type: ignore[arg-type]
                candidate,  # type: ignore[arg-type]
                enemy,  # type: ignore[arg-type]
                config,
                random.Random(index + 1),
                random.Random(index + 101),
            )
            for index, enemy in enumerate((candidate, opponent))
        ]
        results = SimultaneousTreeSearch.search_many(
            searches, [server._snapshot(0), server._snapshot(100)]
        )
        self.assertEqual(len(results), 2)
        self.assertTrue(candidate.batches)
        self.assertTrue(opponent.batches)
        self.assertTrue(
            all(result.diagnostics["cross_root_batch_size"] == 2 for result in results)
        )

    def test_production_defaults_use_search_at_every_decision(self) -> None:
        arguments = training_parser().parse_args(
            ["transformer-train", "--output", "/tmp/overnight"]
        )
        self.assertEqual(arguments.iterations * arguments.episodes, 61_440)
        self.assertEqual(arguments.iterations, 30)
        self.assertEqual(arguments.episodes, 2048)
        self.assertEqual(arguments.arena_episodes, 1024)
        self.assertEqual(arguments.search_depth, 4)
        self.assertEqual(arguments.budget, 512)
        self.assertEqual(arguments.search_every, 1)
        self.assertEqual(arguments.epochs, 1)
        self.assertEqual(arguments.batch_size, 128)
        self.assertEqual(arguments.learning_rate, 2e-4)
        self.assertEqual(arguments.value_loss_weight, 0.25)
        self.assertEqual(arguments.redundant_action_prior_scale, 0.25)
        self.assertTrue(arguments.balanced_final_species)
        self.assertEqual(arguments.model_opponent_share, 0.5)
        self.assertEqual(arguments.promotion_games, 2048)
        self.assertEqual(arguments.probe_games, 256)
        self.assertEqual(arguments.campaign_games, 288)
        self.assertEqual(arguments.tree_expansion_budget, 320)
        self.assertEqual(arguments.tree_regret_iterations, 16)
        self.assertEqual(arguments.tree_deeper_joint_rotations, 2)
        self.assertEqual(arguments.tree_minimum_budget, 192)
        self.assertEqual(arguments.tree_convergence_patience, 8)
        self.assertEqual(arguments.deep_search_fraction, 1.0)
        self.assertEqual(arguments.actor_batch_size, 16)
        self.assertEqual(arguments.actor_processes, 2)
        self.assertEqual(arguments.token_group_size, 1)
        self.assertEqual(arguments.token_layout, "semantic-entity-v1")
        self.assertTrue(arguments.joint_policy_heads)
        self.assertTrue(arguments.distilled_leaf_evaluator)
        self.assertEqual(arguments.leaf_hidden, 64)
        self.assertEqual(arguments.leaf_loss_weight, 0.25)
        self.assertEqual(arguments.precision, "bf16")
        self.assertEqual(arguments.inference_engine, "auto")
        self.assertTrue(arguments.heuristic_opponents)
        self.assertIsNone(arguments.warm_start_checkpoint)
        self.assertIsNone(arguments.warm_start_incumbent_checkpoint)
        weighted = training_parser().parse_args(
            [
                "transformer-train",
                "--output",
                "/tmp/weighted",
                "--weighted-final-species",
            ]
        )
        self.assertFalse(weighted.balanced_final_species)
        resume = training_parser().parse_args(
            ["transformer-resume", "--output", "/tmp/overnight"]
        )
        self.assertEqual(resume.command, "transformer-resume")
        with self.assertRaises(SystemExit):
            training_parser().parse_args(
                [
                    "transformer-train",
                    "--output",
                    "/tmp/invalid-sparse-search",
                    "--search-every",
                    "2",
                ]
            )
        arena = training_parser().parse_args(
            [
                "arena",
                "--candidate",
                "/tmp/candidate.pt",
                "--baseline",
                "/tmp/baseline.pt",
                "--output",
                "/tmp/arena",
            ]
        )
        self.assertFalse(hasattr(arena, "search_every"))
        self.assertEqual(arena.search_depth, 4)
        self.assertEqual(arena.tree_expansion_budget, 320)
        self.assertEqual(arena.redundant_action_prior_scale, 0.25)

    def test_pre_rmplus_everywhere_lineage_cannot_resume(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = asdict(
                TransformerPipelineConfig(
                    iterations=1,
                    selfplay_episodes=8,
                    arena_episodes=8,
                    episode_budget=64,
                    search_depth=1,
                    epochs=1,
                    batch_size=8,
                    learning_rate=1e-3,
                    weight_decay=0.0,
                    seed=1,
                    device="cpu",
                    d_model=8,
                    heads=2,
                    layers=1,
                    feedforward=16,
                )
            )
            config.pop("balanced_final_species")
            config.pop("generated_schedule_version")
            write_json(
                root / "run.json",
                {
                    "pipeline": "transformer-variable-party-bf16-tree-v16",
                    "profile": "full-link-party-1to6-perfect-v2",
                    "schema": "full-link-party-state-v4",
                    "config": config,
                },
            )
            with self.assertRaisesRegex(ValueError, "resume pipeline version differs"):
                _resume_config(root)

    def test_resume_loads_complete_prefix_and_archives_partial_iteration(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = TransformerConfig(
                feature_count=8,
                action_count=2,
                d_model=8,
                heads=2,
                layers=1,
                feedforward=16,
                precision="fp32",
            )
            network = BattleTransformer(config)
            optimizer = torch.optim.AdamW(network.parameters(), lr=1e-3)
            save_network(
                root / "checkpoints" / "policy-000.pt",
                network,
                None,
                {"iteration": 0, "kind": "initial"},
            )
            shard = root / "shards" / "iteration-001.jsonl"
            shard.parent.mkdir(parents=True)
            shard.write_text('{"type":"meta"}\n')
            collection = {"sha256": sha256(shard), "quality": {"pass": True}}
            training = {"promotion": {"accepted": False}}
            save_network(
                root / "checkpoints" / "policy-001.pt",
                network,
                optimizer,
                {
                    "iteration": 1,
                    "source_shards": ["shards/iteration-001.jsonl"],
                    "collection": collection,
                    "training": training,
                },
            )
            partial_shard = root / "shards" / "iteration-002.jsonl"
            partial_shard.write_text('{"type":"meta"}\n')
            write_json(
                root / "metrics" / "iteration-002.json",
                {"collection": {"status": "failed"}},
            )

            completed, shards, collections, trainings, accepted = (
                _load_completed_prefix(root)
            )

            self.assertEqual(completed, 1)
            self.assertEqual(shards, [shard])
            self.assertEqual(collections, [collection])
            self.assertEqual(trainings, [training])
            self.assertEqual(accepted, [])
            self.assertTrue((root / "metrics" / "iteration-001.json").is_file())
            self.assertFalse(partial_shard.exists())
            attempt = root / "attempts" / "iteration-002-attempt-001"
            self.assertTrue((attempt / "shards" / partial_shard.name).is_file())
            self.assertTrue((attempt / "metrics" / "iteration-002.json").is_file())

    def test_paired_arena_reuses_resets_and_spans_seeds(self) -> None:
        self.assertEqual(_paired_coordinates(100, 8, 0), _paired_coordinates(100, 8, 1))
        self.assertNotEqual(
            _paired_coordinates(100, 8, 0), _paired_coordinates(100, 8, 2)
        )
        schedule = [_evaluation_party_sizes(pair) for pair in range(512)]
        self.assertEqual(schedule.count((6, 6)), 171)
        level100 = [_evaluation_level100(pair) for pair in range(512)]
        self.assertEqual(sum(level100), 57)
        legacy_schedule = [_evaluation_party_sizes(pair, 2) for pair in range(512)]
        legacy_level100 = [_evaluation_level100(pair, 2) for pair in range(512)]
        self.assertEqual(legacy_schedule.count((6, 6)), 128)
        self.assertEqual(sum(legacy_level100), 32)
        self.assertTrue(
            all(
                not selected or schedule[index] == (6, 6)
                for index, selected in enumerate(level100)
            )
        )
        low, high = _mean_ci95([1.0] * 512)
        self.assertEqual((low, high), (1.0, 1.0))

    def test_skill_probes_observe_switching_without_gating_it(self) -> None:
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
            "setup_uses": 12,
            "setup_use_rate": 0.03,
            "setup_move_counts": {"Swords Dance": 7, "Reflect": 5},
        }
        candidate = dict(skills)
        candidate["voluntary_switch_rate"] = 0.47
        report = skill_probe_report(
            {"candidate_skills": candidate, "baseline_skills": skills}
        )
        self.assertIsNone(report["switch"]["pass"])
        self.assertFalse(report["switch"]["gated"])
        self.assertEqual(report["gate_version"], "type-status-only-v2")
        self.assertIsNone(report["setup"]["pass"])
        self.assertIsNone(report["decision_quality"]["pass"])
        self.assertFalse(report["decision_quality"]["gated"])
        self.assertEqual(report["setup"]["candidate_uses"], 12)
        self.assertEqual(report["setup"]["candidate_move_counts"]["Swords Dance"], 7)
        self.assertTrue(report["pass"])

    def test_decision_quality_probes_classify_static_redundancy(self) -> None:
        features = [0] * 492
        features[140] = 86  # own active move 0: Thunder Wave
        features[317] = 0x40  # opposing active is already paralyzed
        features[149] = 100  # current own active speed
        features[330] = 101  # current opposing active speed
        status = classify_feature_decision(features, 0)
        self.assertTrue(status.major_status_attempt)
        self.assertTrue(status.redundant_status_same)
        self.assertFalse(status.redundant_status_other)

        features[317] = 0x02  # sleep occupies the major-status slot
        status = classify_feature_decision(features, 0)
        self.assertFalse(status.redundant_status_same)
        self.assertTrue(status.redundant_status_other)

        features[140] = 14  # Swords Dance
        features[159] = 13  # Attack is already +6
        setup = classify_feature_decision(features, 0)
        self.assertTrue(setup.stat_setup_attempt)
        self.assertTrue(setup.capped_stat_setup)

        features[140] = 32  # Horn Drill
        ohko = classify_feature_decision(features, 0)
        self.assertTrue(ohko.ohko_attempt)
        self.assertTrue(ohko.ohko_into_faster)
        features[330] = 100
        self.assertFalse(classify_feature_decision(features, 0).ohko_into_faster)

        metrics = DecisionQualityMetrics()
        for row in (status, setup, ohko):
            metrics.observe(row)
        report = metrics.report()
        self.assertEqual(report["redundant_status_rate"], 1.0)
        self.assertEqual(report["capped_stat_setup_rate"], 1.0)
        self.assertEqual(report["ohko_into_faster_rate"], 1.0)

    def test_observational_quality_probes_do_not_enter_gated_denominators(self) -> None:
        features = [0] * 492
        features[317] = 0x40
        features[149] = 100
        features[330] = 101
        metrics = SkillMetrics()
        after = {"events": []}

        features[140] = 86
        before = {
            "player_mask": 1,
            "player": {"moves": [{"id": 86, "name": "Thunder Wave", "power": 0}]},
        }
        _update_side_metrics(metrics, 0, 0, features, before, after, "battle")

        features[140] = 14
        features[159] = 13
        before["player"]["moves"][0] = {
            "id": 14,
            "name": "Swords Dance",
            "power": 0,
        }
        _update_side_metrics(metrics, 0, 0, features, before, after, "battle")

        features[140] = 32
        before["player"]["moves"][0] = {
            "id": 32,
            "name": "Horn Drill",
            "power": 1,
        }
        _update_side_metrics(metrics, 0, 0, features, before, after, "battle")

        report = metrics.report()
        self.assertEqual(report["status_uses"], 0)
        self.assertEqual(report["damaging_moves"], 0)
        self.assertEqual(report["setup_uses"], 1)
        self.assertEqual(report["redundant_status_same"], 1)
        self.assertEqual(report["capped_stat_setup"], 1)
        self.assertEqual(report["ohko_into_faster"], 1)

    def test_redundant_action_shaping_preserves_every_legal_action(self) -> None:
        features = [0] * 492
        features[140] = 86  # redundant Thunder Wave
        features[141] = 34  # ordinary Body Slam
        features[317] = 0x40
        policy = [0.4, 0.3, 0.2, 0.1] + [0.0] * 9
        shaped = shape_redundant_action_priors(policy, features, 0b1111, 0.25)
        self.assertAlmostEqual(sum(shaped), 1.0)
        self.assertTrue(all(shaped[action] > 0.0 for action in range(4)))
        self.assertLess(shaped[0], policy[0])
        self.assertGreater(shaped[1], policy[1])

    def test_setup_move_observation_is_explicit_and_ungated(self) -> None:
        self.assertEqual(
            _setup_move_name({"id": 14, "name": "Swords Dance"}), "Swords Dance"
        )
        for move_id in (92, 105, 130, 144):
            self.assertIsNone(_setup_move_name({"id": move_id, "name": "other"}))
        metrics = SkillMetrics(
            ordinary_actions=40,
            setup_uses=6,
            setup_move_counts={"Swords Dance": 4, "Reflect": 2},
        ).report()
        self.assertEqual(metrics["setup_use_rate"], 0.15)
        self.assertEqual(metrics["setup_move_counts"]["Reflect"], 2)

    def test_collection_quality_does_not_gate_switch_rate(self) -> None:
        config = SimpleNamespace(selfplay_episodes=100)
        report = _collection_quality(
            {
                "truncated": 0,
                "semantic_divergences": 0,
                "voluntary_switch_rate": 0.95,
                "mean_decisions": 20.0,
                "finished": 100,
            },
            config,
        )
        self.assertEqual(report["version"], "completion-integrity-v2")
        self.assertTrue(report["pass"])
        self.assertEqual(report["reasons"], [])

    def test_fixed_opponent_schedule_is_exact_and_periodic(self) -> None:
        schedule = [_scheduled_for_opponent(episode, 0.5) for episode in range(1000)]
        self.assertEqual(sum(schedule), 500)
        self.assertEqual(schedule[:6], [False, True, False, True, False, True])

    def test_model_and_heuristic_opponents_receive_exact_balanced_shares(self) -> None:
        heuristics = _heuristic_population()[:3]
        models = [(_ToyNetwork(), "model-a"), (_ToyNetwork(), "model-b")]
        opponents = [*heuristics, *models]
        selected = [
            _select_training_opponent(opponents, ordinal, 0.5) for ordinal in range(20)
        ]
        identities = [identity for _, identity, _ in selected]
        self.assertEqual(
            sum(identity.startswith("model-") for identity in identities), 10
        )
        self.assertEqual(identities[1::2], ["model-a", "model-b"] * 5)
        self.assertEqual(
            identities[0::2],
            [identity for _, identity in heuristics] * 3 + [heuristics[0][1]],
        )
        self.assertEqual(
            [ordinal for _, _, ordinal in selected[:6]], [0, 0, 1, 1, 2, 2]
        )

    def test_training_schedule_pairs_every_reset_and_side_assignment(self) -> None:
        self.assertEqual(
            _pipeline_id(),
            "transformer-variable-party-bf16-rmplus-v21-distilled-leaf",
        )
        self.assertEqual(
            _pipeline_id(False, 2),
            "transformer-variable-party-bf16-rmplus-v21-distilled-leaf",
        )
        for episode in range(0, 128, 2):
            self.assertEqual(_training_pair(episode), _training_pair(episode + 1))
            self.assertEqual(
                (_training_pair_leg(episode), _training_pair_leg(episode + 1)), (0, 1)
            )
            self.assertEqual(
                _training_party_sizes(1, episode),
                _training_party_sizes(1, episode + 1),
            )
            self.assertEqual(
                _training_level100(1, episode),
                _training_level100(1, episode + 1),
            )
            self.assertEqual(
                _scheduled_for_opponent(_training_pair(episode), 0.5),
                _scheduled_for_opponent(_training_pair(episode + 1), 0.5),
            )

    def test_collection_pair_validator_requires_same_reset_and_side_swap(self) -> None:
        common = {
            "pair": 0,
            "reset_episode": 0,
            "pair_player_party_size": 2,
            "pair_enemy_party_size": 5,
            "teams_swapped": False,
            "player_party_size": 2,
            "enemy_party_size": 5,
            "level_profile": "distributed",
            "episode_kind": "heuristic-opponent",
            "opponent": "heuristic-red-trainer-01-youngster-v1",
        }
        rows = [
            {
                **common,
                "episode": 0,
                "pair_leg": 0,
                "candidate_side": "player",
                "initial": {"player": "team-a", "enemy": "team-b"},
            },
            {
                **common,
                "episode": 1,
                "pair_leg": 1,
                "candidate_side": "enemy",
                "initial": {"player": "team-a", "enemy": "team-b"},
            },
        ]
        _validate_collection_pairs(rows, 2)
        rows[1]["initial"] = {"player": "team-c", "enemy": "team-b"}
        with self.assertRaisesRegex(RuntimeError, "different initial teams"):
            _validate_collection_pairs(rows, 2)

    def test_collection_pair_validator_accepts_mirror_team_swap(self) -> None:
        common = {
            "pair": 0,
            "reset_episode": 0,
            "pair_player_party_size": 2,
            "pair_enemy_party_size": 5,
            "level_profile": "distributed",
            "episode_kind": "mirror",
            "opponent": "self-play",
            "candidate_side": "both",
        }
        rows = [
            {
                **common,
                "episode": 0,
                "pair_leg": 0,
                "teams_swapped": False,
                "player_party_size": 2,
                "enemy_party_size": 5,
                "initial": {"player": "team-a", "enemy": "team-b"},
            },
            {
                **common,
                "episode": 1,
                "pair_leg": 1,
                "teams_swapped": True,
                "player_party_size": 5,
                "enemy_party_size": 2,
                "initial": {"player": "team-b", "enemy": "team-a"},
            },
        ]
        _validate_collection_pairs(rows, 2)

    def test_training_schedule_covers_all_sizes_with_one_third_6v6(self) -> None:
        expected = {(player, enemy) for player in range(1, 7) for enemy in range(1, 7)}
        for iteration in (1, 2):
            schedule = [
                _training_party_sizes(iteration, episode) for episode in range(2048)
            ]
            self.assertEqual(set(schedule), expected)
            six_vs_six = schedule.count((6, 6))
            self.assertLessEqual(abs(six_vs_six * 3 - len(schedule)), 4)
            level100 = [
                _training_level100(iteration, episode) for episode in range(2048)
            ]
            self.assertLessEqual(abs(sum(level100) * 3 - six_vs_six), 4)
            self.assertTrue(
                all(
                    not selected or schedule[index] == (6, 6)
                    for index, selected in enumerate(level100)
                )
            )

    def test_checkpoint_separates_deployed_and_shadow_models(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            config = TransformerConfig(
                feature_count=8,
                action_count=2,
                d_model=8,
                heads=2,
                layers=1,
                feedforward=16,
                precision="fp32",
            )
            deployed = BattleTransformer(config)
            learner = deployed.detached_copy(torch.device("cpu"))
            with torch.no_grad():
                learner.policy.bias.add_(1.0)
            path = Path(temporary) / "lineage.pt"
            save_network(
                path,
                deployed,
                None,
                {"iteration": 1},
                {"learner_model": learner.state_dict()},
            )
            loaded_deployed = load_network(path, torch.device("cpu"))
            payload = load_checkpoint(path, torch.device("cpu"))
            self.assertTrue(
                torch.equal(loaded_deployed.policy.bias, deployed.policy.bias)
            )
            self.assertTrue(
                torch.equal(
                    payload["learner_model"]["policy.bias"], learner.policy.bias
                )
            )
            self.assertFalse(
                torch.equal(
                    payload["learner_model"]["policy.bias"],
                    loaded_deployed.policy.bias,
                )
            )

    def test_v3_checkpoint_warm_starts_v4_position_table(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source_config = TransformerConfig(
                feature_count=478,
                action_count=13,
                d_model=16,
                heads=4,
                layers=1,
                feedforward=32,
                precision="fp32",
            )
            source = BattleTransformer(source_config)
            source_path = Path(temporary) / "v3.pt"
            save_network(source_path, source, None, {"iteration": 0})
            target_config = TransformerConfig(
                feature_count=492,
                action_count=13,
                d_model=16,
                heads=4,
                layers=1,
                feedforward=32,
                precision="bf16",
            )
            target = warm_start_network(source_path, target_config, torch.device("cpu"))
            source_state = source.state_dict()
            target_state = target.state_dict()
            for name, source_value in source_state.items():
                target_value = target_state[name]
                if name == "position.weight":
                    self.assertTrue(
                        torch.equal(target_value[: source_value.shape[0]], source_value)
                    )
                    self.assertEqual(target_value.shape[0], 493)
                else:
                    self.assertTrue(torch.equal(target_value, source_value), name)

    def test_same_schema_checkpoint_warm_starts_exactly(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            config = TransformerConfig(
                feature_count=492,
                action_count=13,
                d_model=16,
                heads=4,
                layers=1,
                feedforward=32,
                precision="bf16",
            )
            source = BattleTransformer(config)
            source_path = Path(temporary) / "same-schema.pt"
            save_network(source_path, source, None, {"iteration": 4})
            target = warm_start_network(source_path, config, torch.device("cpu"))
            for name, source_value in source.state_dict().items():
                self.assertTrue(
                    torch.equal(target.state_dict()[name], source_value), name
                )

    def test_gradient_diagnostics_report_norm_conflict(self) -> None:
        report = _gradient_report(
            [(0.1, 2.4, -0.2), (0.2, 2.4, 0.1), (0.0, 1.0, None)], 0.25
        )
        self.assertEqual(report["samples"], 3)
        self.assertEqual(report["cosine_samples"], 2)
        self.assertAlmostEqual(report["value_policy_norm_ratio"], 19.3333333333)
        self.assertAlmostEqual(report["weighted_value_policy_norm_ratio"], 4.8333333333)
        self.assertEqual(report["value_loss_weight"], 0.25)
        self.assertAlmostEqual(report["mean_cosine"], -0.05)
        self.assertEqual(report["negative_cosine_fraction"], 0.5)

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
            _, _, _, _, masks, _, weights = _load_examples([shard])
            self.assertEqual(weights.tolist(), [1.0])
            self.assertEqual(masks.tolist(), [[True, False, True, False]])

    def test_full_party_models_stay_under_one_million_parameters(self) -> None:
        configs = [
            TransformerConfig(
                feature_count=492,
                action_count=13,
                d_model=64,
                heads=4,
                layers=2,
                feedforward=192,
            ),
            TransformerConfig(
                feature_count=492,
                action_count=13,
                d_model=96,
                heads=4,
                layers=3,
                feedforward=384,
            ),
            TransformerConfig(
                feature_count=492,
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
        semantic = BattleTransformer(
            TransformerConfig(
                feature_count=492,
                action_count=13,
                d_model=128,
                heads=8,
                layers=4,
                feedforward=512,
                token_layout="semantic-entity-v1",
            )
        )
        semantic_count = sum(parameter.numel() for parameter in semantic.parameters())
        joint = BattleTransformer(replace(semantic.config, joint_policy_heads=True))
        joint_count = sum(parameter.numel() for parameter in joint.parameters())
        self.assertEqual(counts, [153038, 442958, 940430])
        self.assertEqual(semantic_count, 900366)
        self.assertEqual(joint_count, 902043)
        self.assertTrue(
            all(count <= 1_000_000 for count in [*counts, semantic_count, joint_count])
        )

    def test_switch_cap_preserves_all_legal_actions(self) -> None:
        policy = tuple([0.05] * 4 + [0.125] * 6 + [0.05, 0.0, 0.0])
        capped = _cap_switch_mass(policy, list(policy), list(range(11)), 0.2)
        self.assertAlmostEqual(sum(capped), 1.0)
        self.assertAlmostEqual(sum(capped[4:10]), 0.2)
        self.assertTrue(all(capped[action] > 0 for action in range(10)))

    def test_tactical_potential_rewards_hp_and_status_advantage(self) -> None:
        features = [0] * 492
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

    def test_distilled_leaf_value_is_bounded_and_keeps_model_under_budget(self) -> None:
        torch.manual_seed(12)
        network = BattleTransformer(
            TransformerConfig(
                feature_count=492,
                action_count=13,
                d_model=128,
                heads=8,
                layers=4,
                feedforward=512,
                token_layout="semantic-entity-v1",
                joint_policy_heads=True,
                distilled_leaf_evaluator=True,
                leaf_hidden=64,
            )
        ).eval()
        values = network.evaluate_leaf([[0] * 492, [65535] * 492])
        self.assertEqual(len(values), 2)
        self.assertTrue(all(-1.0 <= value <= 1.0 for value in values))
        self.assertEqual(
            sum(parameter.numel() for parameter in network.parameters()), 937820
        )

    def test_pooled_successors_use_the_leaf_evaluator(self) -> None:
        network = _LeafToyNetwork()
        server = _ToyServer()
        search = SimultaneousTreeSearch(
            server,
            network,
            network,
            JointSearchConfig(
                max_depth=1,
                expansion_budget=4,
                minimum_expansion_budget=1,
            ),
            random.Random(1),
            random.Random(2),
        )
        evaluated, calls, rows = SimultaneousTreeSearch._pooled_successor_values(
            [(0, search, [server._snapshot(0)])]
        )
        self.assertEqual(evaluated, {0: [(0.5, 0.5)]})
        self.assertEqual(calls, 1)
        self.assertEqual(rows, 1)
        self.assertEqual(network.batches, [1])

    def test_joint_heads_mask_both_policies_and_share_one_value(self) -> None:
        torch.manual_seed(8)
        network = BattleTransformer(
            TransformerConfig(
                feature_count=492,
                action_count=13,
                d_model=32,
                heads=4,
                layers=1,
                feedforward=64,
                token_layout="semantic-entity-v1",
                joint_policy_heads=True,
            )
        ).eval()
        own, opponent, values = network.evaluate_joint(
            [[0] * 492, [1] * 492], [0b0001, 0b0010], [0b0100, 0b1000]
        )
        self.assertEqual(own[0][0], 1.0)
        self.assertEqual(own[1][1], 1.0)
        self.assertEqual(opponent[0][2], 1.0)
        self.assertEqual(opponent[1][3], 1.0)
        self.assertTrue(all(-1.0 <= value <= 1.0 for value in values))

    def test_mirror_pooled_evaluation_uses_one_physical_state_forward(self) -> None:
        network = _JointToyNetwork()
        server = _ToyServer()
        search = SimultaneousTreeSearch(
            server,
            network,
            network,
            JointSearchConfig(
                max_depth=1,
                expansion_budget=4,
                minimum_expansion_budget=1,
            ),
            random.Random(1),
            random.Random(2),
        )
        evaluated, calls, rows = SimultaneousTreeSearch._pooled_evaluate(
            [(0, search, [server._snapshot(0)])]
        )
        self.assertEqual(calls, 1)
        self.assertEqual(rows, 1)
        self.assertEqual(evaluated[0][0], [[1.0, 0.0]])
        self.assertEqual(evaluated[0][1], [[0.0, 1.0]])
        self.assertEqual(evaluated[0][2], [0.25])

    def test_deferred_evaluation_matches_synchronous_cpu_evaluation(self) -> None:
        torch.manual_seed(9)
        network = BattleTransformer(
            TransformerConfig(d_model=32, heads=4, layers=1, feedforward=64)
        ).eval()
        features = [[0] * 100, [1] * 100]
        masks = [0b0101, 0b1010]
        expected = network.evaluate(features, masks)
        actual = network.begin_evaluate(features, masks).result()
        for left, right in zip(expected[0], actual[0], strict=True):
            self.assertEqual(left, right)
        self.assertEqual(expected[1], actual[1])

    def test_policy_masks_and_value_bounds(self) -> None:
        torch.manual_seed(7)
        network = BattleTransformer(
            TransformerConfig(d_model=32, heads=4, layers=1, feedforward=64)
        ).eval()
        self.assertEqual(network.config.precision, "bf16")
        self.assertTrue(
            all(parameter.dtype == torch.float32 for parameter in network.parameters())
        )
        logits, raw_values = network(torch.zeros((2, 100), dtype=torch.long))
        self.assertEqual(logits.dtype, torch.float32)
        self.assertEqual(raw_values.dtype, torch.float32)
        policies, values = network.evaluate([[0] * 100, [1] * 100], [0b0101, 0b1010])
        self.assertAlmostEqual(sum(policies[0]), 1.0, places=6)
        self.assertAlmostEqual(sum(policies[1]), 1.0, places=6)
        self.assertEqual(policies[0][1], 0.0)
        self.assertEqual(policies[0][3], 0.0)
        self.assertEqual(policies[1][0], 0.0)
        self.assertEqual(policies[1][2], 0.0)
        self.assertTrue(all(-1.0 <= value <= 1.0 for value in values))

    def test_pooled_inference_launches_all_networks_before_waiting(self) -> None:
        trace: list[str] = []
        player = _DeferredToyNetwork(trace, "player")
        enemy = _DeferredToyNetwork(trace, "enemy")
        server = _ToyServer()
        search = SimultaneousTreeSearch(
            server,
            player,
            enemy,
            JointSearchConfig(
                max_depth=1,
                expansion_budget=4,
                minimum_expansion_budget=1,
                inference_batch_size=1,
            ),
            random.Random(1),
            random.Random(2),
        )
        first = server._snapshot(0)
        second = replace(
            first,
            handle=1,
            player_features=tuple([1] + list(first.player_features[1:])),
            enemy_features=tuple([2] + list(first.enemy_features[1:])),
        )
        _, calls, rows = SimultaneousTreeSearch._pooled_evaluate(
            [(0, search, [first, second])]
        )
        self.assertEqual(calls, 4)
        self.assertEqual(rows, 4)
        self.assertEqual(
            trace,
            [
                "begin:player",
                "begin:player",
                "begin:enemy",
                "begin:enemy",
                "result:player",
                "result:player",
                "result:enemy",
                "result:enemy",
            ],
        )

    def test_semantic_entity_tokens_bind_fields_and_reduce_sequence_length(
        self,
    ) -> None:
        torch.manual_seed(11)
        network = BattleTransformer(
            TransformerConfig(
                feature_count=492,
                action_count=13,
                d_model=32,
                heads=4,
                layers=1,
                feedforward=64,
                token_layout="semantic-entity-v1",
            )
        ).eval()
        self.assertEqual(network.sequence_length, 32)
        left = [0] * 492
        right = [0] * 492
        left[1] = 100
        right[3] = 100
        _, left_tokens = network._semantic_tokens(torch.tensor([left]))
        _, right_tokens = network._semantic_tokens(torch.tensor([right]))
        self.assertFalse(torch.equal(left_tokens, right_tokens))

    def test_semantic_layout_requires_full_v4_schema(self) -> None:
        with self.assertRaisesRegex(ValueError, "492-field"):
            BattleTransformer(
                TransformerConfig(
                    feature_count=100,
                    token_layout="semantic-entity-v1",
                )
            )

    def test_grouped_scalar_tokens_reduce_sequence_length(self) -> None:
        network = BattleTransformer(
            TransformerConfig(
                feature_count=492,
                action_count=13,
                d_model=32,
                heads=4,
                layers=1,
                feedforward=64,
                token_group_size=8,
            )
        ).eval()
        self.assertEqual(network.sequence_length, 63)
        policies, values = network.evaluate([[0] * 492, [1] * 492], [1, 2])
        self.assertEqual(len(policies), 2)
        self.assertEqual(policies[0][0], 1.0)
        self.assertEqual(policies[1][1], 1.0)
        self.assertTrue(all(-1.0 <= value <= 1.0 for value in values))

    def test_legacy_checkpoint_retains_fp32_precision(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "legacy.pt"
            network = BattleTransformer(
                TransformerConfig(
                    d_model=32,
                    heads=4,
                    layers=1,
                    feedforward=64,
                    precision="fp32",
                )
            )
            config = {
                "feature_count": 100,
                "action_count": 4,
                "d_model": 32,
                "heads": 4,
                "layers": 1,
                "feedforward": 64,
            }
            torch.save(
                {
                    "format": "battle-transformer-policy-value-v1",
                    "config": config,
                    "model": network.state_dict(),
                    "optimizer": None,
                    "metadata": {},
                    "torch_rng": torch.random.get_rng_state(),
                },
                path,
            )
            restored = load_network(path, torch.device("cpu"))
            self.assertEqual(restored.config.precision, "fp32")


class RedTrainerHeuristicTests(unittest.TestCase):
    @staticmethod
    def _features(
        *,
        moves: tuple[int, int, int, int] = (1, 2, 3, 4),
        descriptors: tuple[tuple[int, int, int], ...] = (
            (0, 40, 0),
            (0, 40, 0),
            (0, 40, 0),
            (0, 40, 0),
        ),
        target_status: int = 0,
        target_types: tuple[int, int] = (0, 0),
        hp: int = 100,
        max_hp: int = 100,
    ) -> tuple[int, ...]:
        features = [0] * 492
        features[134] = hp
        features[146] = max_hp
        for slot, move in enumerate(moves):
            features[140 + slot] = move
        for slot, (effect, power, move_type) in enumerate(descriptors):
            base = 362 + slot * 6
            features[base] = effect
            features[base + 1] = power
            features[base + 2] = move_type
        features[317] = target_status
        features[318], features[319] = target_types
        return tuple(features)

    def test_population_contains_every_canonical_trainer_class(self) -> None:
        self.assertEqual(len(TRAINER_CLASS_PROFILES), 47)
        self.assertEqual(
            [profile.class_id for profile in TRAINER_CLASS_PROFILES],
            list(range(1, 48)),
        )
        self.assertEqual(len({profile.slug for profile in TRAINER_CLASS_PROFILES}), 47)
        population = _heuristic_population()
        self.assertEqual(len(population), 49)
        identities = [identity for _, identity in population]
        self.assertEqual(
            identities[:2],
            [
                "heuristic-aggressive-v1",
                "heuristic-switch-heavy-v1",
            ],
        )
        self.assertEqual(
            identities[2:],
            [profile.identity for profile in TRAINER_CLASS_PROFILES],
        )

    def test_generic_selection_preserves_biased_slot_buckets(self) -> None:
        policy = normalized_trainer_policy(
            self._features(), 0b1111, TRAINER_CLASS_PROFILES[0]
        )
        self.assertEqual(policy[:4], [63 / 256, 64 / 256, 63 / 256, 66 / 256])
        self.assertEqual(sum(policy[4:]), 0.0)

    def test_layer_one_avoids_redundant_status_move(self) -> None:
        features = self._features(
            moves=(1, 2, 0, 0),
            descriptors=((0x01, 0, 0x18), (0, 40, 0), (0, 0, 0), (0, 0, 0)),
            target_status=0x08,
        )
        policy = normalized_trainer_policy(features, 0b0011, TRAINER_CLASS_PROFILES[1])
        self.assertEqual(policy[0], 0.0)
        self.assertEqual(policy[1], 1.0)

    def test_layer_three_keeps_first_matching_dual_type_bug(self) -> None:
        features = self._features(
            moves=(1, 2, 0, 0),
            descriptors=((0, 40, 0x03), (0, 40, 0x14), (0, 0, 0), (0, 0, 0)),
            target_types=(0x07, 0x03),
        )
        policy = normalized_trainer_policy(features, 0b0011, TRAINER_CLASS_PROFILES[3])
        self.assertEqual(policy[0], 0.0)
        self.assertEqual(policy[1], 1.0)

    def test_representable_switch_routines_keep_cartridge_probabilities(self) -> None:
        features = self._features(moves=(1, 2, 0, 0))
        juggler = normalized_trainer_policy(
            features, 0b1_0000 | 0b0011, TRAINER_CLASS_PROFILES[20]
        )
        agatha = normalized_trainer_policy(
            features, 0b1_0000 | 0b0011, TRAINER_CLASS_PROFILES[45]
        )
        self.assertAlmostEqual(juggler[4], 64 / 256)
        self.assertAlmostEqual(agatha[4], 20 / 256)

    def test_cooltrainer_f_switch_and_item_projection_are_distinct(self) -> None:
        profile = TRAINER_CLASS_PROFILES[31]
        switching = normalized_trainer_policy(
            self._features(moves=(1, 2, 0, 0), hp=15),
            0b1_0000 | 0b0011,
            profile,
        )
        item_projection = normalized_trainer_policy(
            self._features(moves=(1, 2, 0, 0), hp=5),
            0b1_0000 | 0b0011,
            profile,
        )
        self.assertEqual(switching[4], 1.0)
        self.assertEqual(item_projection[4], 0.0)
        self.assertAlmostEqual(sum(item_projection[:4]), 1.0)


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
