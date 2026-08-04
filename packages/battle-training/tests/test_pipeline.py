from __future__ import annotations

import hashlib
import inspect
import json
import math
import pickle
import random
import sys
import tempfile
import unittest
from dataclasses import asdict, replace
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import numpy as np
import torch

from battle_training.arena import (
    ArenaConfig,
    ArenaReportJob,
    Replay,
    SkillMetrics,
    _arena_batch_spans,
    _arena_parallel_batch_size,
    _arena_span_partition,
    _battle_finished,
    _evaluation_level100,
    _evaluation_party_sizes,
    _FastArenaEpisode,
    _finished_pair_scores,
    _live_arena_report,
    _load_arena_model,
    _load_final_arena_baseline,
    _mean_ci95,
    _pair_outcome_report,
    _paired_coordinates,
    _policy_argmax_actions,
    _score_moments,
    _serialized_arena_model,
    _serialized_final_arena_baseline,
    _setup_move_name,
    _slim_arena_episode,
    _slim_traced_episode,
    _TracedArenaEpisode,
    _update_side_metrics,
    run_paired_arena,
    run_traced_arena,
    skill_probe_report,
    write_arena_reports_parallel,
)
from battle_training.artifacts import (
    build_manifest,
    sha256,
    verify_manifest,
    write_json,
)
from battle_training.cli import (
    _CAPACITY_PRESETS,
    _apply_capacity_preset,
)
from battle_training.cli import (
    parser as training_parser,
)
from battle_training.decision_quality import (
    DecisionQualityMetrics,
    classify_feature_decision,
    shape_redundant_action_priors,
)
from battle_training.joint_search import (
    JointSearchConfig,
    RootPriorNoise,
    SearchResult,
    SimultaneousTreeSearch,
    _dirichlet_noised_priors,
    _tactical_potential,
    solve_zero_sum_regret,
)
from battle_training.model import MoveValueModel
from battle_training.monitor import (
    build_dashboard_snapshot,
    build_match_detail,
    write_monitor_state,
)
from battle_training.native import (
    NativeRequestTimeout,
    SearchServer,
    Snapshot,
    _decode_features,
    _episode_lineage,
    _root_lineage,
    _search_lineage,
)
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
from battle_training.rmplus_native import (
    PYTHON_REFERENCE_BACKEND,
    RUST_RMPLUS_BACKEND,
    native_available,
)
from battle_training.rmplus_native import (
    solve_cold as solve_cold_native,
)
from battle_training.transformer_pipeline import (
    _ACTOR_ENTROPY_VERSION,
    _CHANCE_DOMAIN,
    _EXPLORATION_DOMAIN,
    _FRONTIER_PLAN_DOMAIN,
    _OPPONENT_DOMAIN,
    _PRIOR_NOISE_DOMAIN,
    _RESET_DOMAIN,
    _SELECTION_DOMAIN,
    _TIER_DOMAIN,
    TransformerPipelineConfig,
    _append_shadow_opponent,
    _apply_learning_rate,
    _arena,
    _arena_config,
    _assemble_population,
    _begin_leaf_training,
    _bootstrap_waiver_active,
    _collect_rows_single,
    _collection_prior_noise,
    _collection_quality,
    _dirichlet_meta,
    _end_leaf_training,
    _epsilon_meta,
    _explore_search_result,
    _finalize_frontier,
    _frontier_entry,
    _frontier_meta,
    _frontier_priors,
    _frontier_restart_entries,
    _frontier_restart_meta,
    _frontier_restart_plan,
    _frontier_score,
    _FrontierBuffer,
    _gradient_report,
    _heuristic_population,
    _HeuristicNetwork,
    _initial_leaf_ema_state,
    _leaf_ema_checkpoint_state,
    _learning_rate_for_iteration,
    _lineage_promotions,
    _load_completed_prefix,
    _load_examples,
    _load_frontier_buffer,
    _merged_frontier,
    _new_search,
    _normalized_saved_config,
    _pipeline_id,
    _play_game,
    _policy_entropy,
    _policy_gate_superior,
    _policy_kl,
    _pooled_promotion_evidence,
    _pooled_root_only_share,
    _promotion_gate_scores,
    _replay_frontier_entry,
    _resume_config,
    _resumed_pooled_evidence,
    _scheduled_for_opponent,
    _select_training_opponent,
    _serialized_network_config,
    _serialized_snapshot,
    _shadow_seed_iterations,
    _smoothed_policy,
    _snapshot_from_serialized,
    _training_entropy_seed,
    _training_level100,
    _training_pair,
    _training_pair_leg,
    _training_party_sizes,
    _uniform_legal_action,
    _update_leaf_ema,
    _validate_collection_pairs,
)


def _paired_battle(
    game: int, stop: str | None, candidate_return: int | None, score: float
) -> dict[str, object]:
    return {
        "game": game,
        "pair": game // 2,
        "stop": stop,
        "candidate_return": candidate_return,
        "score": score,
    }


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


class _AdaptiveToyNetwork(_LeafToyNetwork):
    config = SimpleNamespace(
        action_count=2,
        joint_policy_heads=True,
        distilled_leaf_evaluator=True,
        adaptive_budget_head=True,
    )

    @staticmethod
    def evaluate_budget(features: object) -> list[float]:
        return [0.0 for _ in features]  # type: ignore[union-attr]


class _ThirteenActionToyNetwork:
    config = SimpleNamespace(
        action_count=13,
        joint_policy_heads=False,
        distilled_leaf_evaluator=False,
        adaptive_budget_head=False,
    )

    @staticmethod
    def evaluate(
        features: object, masks: list[int]
    ) -> tuple[list[list[float]], list[float]]:
        del features
        policies = []
        for mask in masks:
            legal = [action for action in range(13) if mask & (1 << action)]
            policies.append(
                [1.0 / len(legal) if action in legal else 0.0 for action in range(13)]
            )
        return policies, [0.0] * len(masks)


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


class _DistinctFeatureToyServer(_ToyServer):
    def _snapshot(
        self, handle: int, done: bool = False, result: int | None = None
    ) -> Snapshot:
        snapshot = super()._snapshot(handle, done, result)
        player = list(snapshot.player_features)
        enemy = list(snapshot.enemy_features)
        player[0] = handle
        enemy[0] = handle
        return replace(
            snapshot,
            player_features=tuple(player),
            enemy_features=tuple(enemy),
        )


class _DivergentToyServer(_ToyServer):
    def search_steps(self, requests: list[tuple[int, int, int, int]]) -> list[Snapshot]:
        return [
            replace(snapshot, divergence="toy-search-divergence")
            for snapshot in super().search_steps(requests)
        ]


class _FakeLeanServer(SearchServer):
    """In-memory stand-in for the Lean process behind ``SearchServer``.

    States are (content, rng, turn) tuples where children derive purely from
    the parent state plus the request, mirroring the deterministic engine:
    search steps consume the supplied chance seed, episode steps consume the
    state-embedded rng stream.
    """

    def __init__(self) -> None:
        self.request_timeout = 60.0
        self.feature_count = 4
        self.action_count = 13
        self.campaign_count = 2
        self._lineage = {}
        self._dedup_window = {}
        self.search_rows_requested = 0
        self.search_rows_deduplicated = 0
        self.native_search_rows = 0
        self._states: list[tuple[bytes, bytes, int]] = []

    @staticmethod
    def _digest(*parts: bytes) -> bytes:
        return hashlib.blake2b(b"|".join(parts), digest_size=16).digest()

    def _row(self, handle: int) -> dict[str, object]:
        content, _, turn = self._states[handle]
        return {
            "handle": handle,
            "feature_encoding": "json-nat-array",
            "player_features": [byte % 251 for byte in content[: self.feature_count]],
            "enemy_features": [byte % 241 for byte in content[: self.feature_count]],
            "player_mask": 0b11,
            "enemy_mask": 0b11,
            "player_hash": content.hex(),
            "enemy_hash": content.hex(),
            "turn": turn,
            "request": "battle",
            "divergence": None,
            "terminal": False,
            "done": False,
            "return": None,
        }

    def _append_state(self, content: bytes, rng: bytes, turn: int) -> int:
        self._states.append((content, rng, turn))
        return len(self._states) - 1

    def _request(self, command: str) -> dict[str, object]:
        operation, _, payload = command.partition("|")
        if operation.startswith("reset"):
            if not operation.endswith("-append"):
                self._states.clear()
            content_key = f"{operation.removesuffix('-append')}|{payload}".encode()
            handle = self._append_state(
                self._digest(b"root", content_key),
                self._digest(b"root-rng", content_key),
                0,
            )
            return self._row(handle)
        if operation in ("batch", "batch-episode"):
            rows = []
            for spec in payload.split(";"):
                handle, player, enemy, seed = (int(part) for part in spec.split(","))
                content, rng, turn = self._states[handle]
                if operation == "batch":
                    self.native_search_rows += 1
                    chance = seed.to_bytes(8, "little")
                    child_rng = self._digest(b"step-rng", rng, chance)
                else:
                    chance = rng
                    child_rng = self._digest(b"episode-rng", rng)
                child = self._digest(b"child", content, bytes((player, enemy)), chance)
                rows.append(self._row(self._append_state(child, child_rng, turn + 1)))
            return {"snapshots": rows}
        if operation == "compact-handles":
            keep = [int(part) for part in payload.split(",")]
            self._states = [self._states[handle] for handle in keep]
            return {"handles": list(range(len(keep)))}
        raise AssertionError(f"unexpected native command: {command}")


class NativeTransitionDedupTests(unittest.TestCase):
    def _mirror_batch(
        self, server: _FakeLeanServer
    ) -> tuple[Snapshot, Snapshot, Snapshot]:
        first = server.reset(11, 7, 3, 3)
        second = server.reset_append(11, 7, 3, 3)
        other = server.reset_append(11, 9, 3, 3)
        return first, second, other

    def test_lineage_digests_are_deterministic_and_domain_separated(self) -> None:
        root = _root_lineage("reset|11|7|3|3|0")
        self.assertEqual(root, _root_lineage("reset|11|7|3|3|0"))
        self.assertNotEqual(root, _root_lineage("reset|11|8|3|3|0"))
        search = _search_lineage(root, 1, 2, 55)
        self.assertEqual(search, _search_lineage(root, 1, 2, 55))
        self.assertNotEqual(search, _search_lineage(root, 1, 2, 56))
        self.assertNotEqual(search, _search_lineage(root, 2, 1, 55))
        self.assertNotEqual(search, _search_lineage(search, 1, 2, 55))
        episode = _episode_lineage(root, 1, 2)
        self.assertNotEqual(episode, _search_lineage(root, 1, 2, 0))
        for digest in (root, search, episode):
            self.assertEqual(len(digest), 16)

    def test_mirror_search_requests_collapse_to_one_native_row(self) -> None:
        server = _FakeLeanServer()
        first, second, other = self._mirror_batch(server)
        results = server.search_steps(
            [
                (first.handle, 1, 2, 55),
                (second.handle, 1, 2, 55),
                (other.handle, 1, 2, 55),
            ]
        )
        self.assertEqual(server.native_search_rows, 2)
        self.assertEqual(server.search_rows_requested, 3)
        self.assertEqual(server.search_rows_deduplicated, 1)
        self.assertIs(results[0], results[1])
        self.assertEqual(results[0].player_hash, results[1].player_hash)
        self.assertNotEqual(results[0].player_hash, results[2].player_hash)

    def test_window_serves_identical_request_from_previous_call(self) -> None:
        server = _FakeLeanServer()
        first, second, _ = self._mirror_batch(server)
        wave_one = server.search_steps([(first.handle, 1, 2, 55)])
        rows_after_first = server.native_search_rows
        wave_two = server.search_steps([(second.handle, 1, 2, 55)])
        self.assertEqual(server.native_search_rows, rows_after_first)
        self.assertEqual(server.search_rows_deduplicated, 1)
        self.assertIs(wave_two[0], wave_one[0])

    def test_distinct_seeds_and_actions_never_deduplicate(self) -> None:
        server = _FakeLeanServer()
        first, second, _ = self._mirror_batch(server)
        server.search_steps(
            [
                (first.handle, 1, 2, 55),
                (second.handle, 1, 2, 56),
                (first.handle, 2, 1, 55),
                (second.handle, 1, 1, 55),
            ]
        )
        self.assertEqual(server.native_search_rows, 4)
        self.assertEqual(server.search_rows_deduplicated, 0)

    def test_episode_steps_extend_lineage_and_clear_window(self) -> None:
        server = _FakeLeanServer()
        first, second, _ = self._mirror_batch(server)
        wave = server.search_steps(
            [(first.handle, 1, 2, 55), (second.handle, 1, 2, 55)]
        )
        children = server.episode_steps([(first.handle, 4, 5), (second.handle, 4, 5)])
        self.assertNotEqual(children[0].handle, children[1].handle)
        self.assertEqual(children[0].player_hash, children[1].player_hash)
        rows_before = server.native_search_rows
        repeat = server.search_steps([(second.handle, 1, 2, 55)])
        self.assertEqual(server.native_search_rows, rows_before + 1)
        self.assertEqual(repeat[0].player_hash, wave[0].player_hash)
        next_wave = server.search_steps(
            [(children[0].handle, 3, 3, 77), (children[1].handle, 3, 3, 77)]
        )
        self.assertEqual(server.native_search_rows, rows_before + 2)
        self.assertIs(next_wave[0], next_wave[1])

    def test_compact_remaps_lineage_and_preserves_dedup(self) -> None:
        server = _FakeLeanServer()
        first, second, _ = self._mirror_batch(server)
        children = server.episode_steps([(first.handle, 4, 5), (second.handle, 4, 5)])
        compacted = server.compact_many(children)
        self.assertEqual([snapshot.handle for snapshot in compacted], [0, 1])
        wave = server.search_steps(
            [(compacted[0].handle, 1, 2, 91), (compacted[1].handle, 1, 2, 91)]
        )
        self.assertEqual(server.native_search_rows, 1)
        self.assertIs(wave[0], wave[1])

    def test_unknown_lineage_rows_pass_through_untracked(self) -> None:
        server = _FakeLeanServer()
        first, second, _ = self._mirror_batch(server)
        del server._lineage[first.handle]
        results = server.search_steps(
            [(first.handle, 1, 2, 55), (second.handle, 1, 2, 55)]
        )
        self.assertEqual(server.native_search_rows, 2)
        self.assertEqual(server.search_rows_deduplicated, 0)
        self.assertNotIn(results[0].handle, server._lineage)
        self.assertIn(results[1].handle, server._lineage)

    def test_reset_clears_lineage_so_recycled_handles_never_alias(self) -> None:
        server = _FakeLeanServer()
        first, second, _ = self._mirror_batch(server)
        server.search_steps([(first.handle, 1, 2, 55), (second.handle, 1, 2, 55)])
        fresh_first = server.reset(11, 7, 3, 3)
        self.assertEqual(set(server._lineage), {fresh_first.handle})
        fresh_second = server.reset_append(11, 7, 3, 3)
        rows_before = server.native_search_rows
        wave = server.search_steps(
            [(fresh_first.handle, 1, 2, 55), (fresh_second.handle, 1, 2, 55)]
        )
        self.assertEqual(server.native_search_rows, rows_before + 1)
        self.assertIs(wave[0], wave[1])

    def test_campaign_reset_lineage_matches_across_append_variants(self) -> None:
        server = _FakeLeanServer()
        first = server.reset_campaign(11, 7, 1)
        second = server.reset_campaign_append(11, 7, 1)
        other = server.reset_campaign_append(11, 7, 0)
        wave = server.search_steps(
            [
                (first.handle, 1, 2, 55),
                (second.handle, 1, 2, 55),
                (other.handle, 1, 2, 55),
            ]
        )
        self.assertEqual(server.native_search_rows, 2)
        self.assertIs(wave[0], wave[1])
        self.assertNotEqual(wave[0].player_hash, wave[2].player_hash)


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

    def test_dashboard_aggregates_live_promotion_battles(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            progress = root / ".monitor"
            progress.mkdir()
            write_monitor_state(
                root,
                "promotion",
                iteration=2,
                message="Running paired promotion games",
                games=4,
            )
            for process, wins, score, pair_score, games in (
                (0, 2, 2.0, 1.0, (0, 1)),
                (1, 1, 1.0, 0.5, (2, 3)),
            ):
                (progress / f"arena-promotion-002-{process:02d}.json").write_text(
                    json.dumps(
                        {
                            "updated_at": f"9999-01-01T00:00:0{process}Z",
                            "process": process,
                            "stage": "promotion",
                            "iteration": 2,
                            "completed": 2,
                            "total": 2,
                            "arena_games": 4,
                            "finished": 2,
                            "wins": wins,
                            "losses": 2 - wins,
                            "draws": 0,
                            "truncated": 0,
                            "semantic_divergences": 0,
                            "mechanics_timeouts": 0,
                            "score_sum": score,
                            "pair_score_sum": pair_score,
                            "pair_score_sumsq": pair_score * pair_score,
                            "pairs": 1,
                            "recent_battles": [
                                {
                                    "game": game,
                                    "candidate_side": (
                                        "player" if game % 2 == 0 else "enemy"
                                    ),
                                    "candidate_return": 1 if game < 3 else -1,
                                    "score": 1.0 if game < 3 else 0.0,
                                    "stop": "finished",
                                }
                                for game in games
                            ],
                        }
                    )
                )
            dashboard = build_dashboard_snapshot(root)
            evaluation = dashboard["evaluation"]
            self.assertTrue(evaluation["live"])
            self.assertEqual(evaluation["completed"], 4)
            self.assertEqual(evaluation["games"], 4)
            self.assertEqual(evaluation["wins"], 3)
            self.assertEqual(evaluation["losses"], 1)
            self.assertEqual(evaluation["score_with_nonfinishes_as_losses"], 0.75)
            self.assertEqual(evaluation["paired_score_ci95"], [0.26, 1.0])
            self.assertEqual(
                [battle["game"] for battle in evaluation["battles"]],
                [0, 1, 2, 3],
            )
            self.assertEqual(dashboard["status"]["completed"], 4)
            self.assertIn("4 / 4", dashboard["status"]["message"])


class TransformerTests(unittest.TestCase):
    def test_frontier_priors_respect_inference_batch_limit(self) -> None:
        class RecordingNetwork:
            def __init__(self) -> None:
                self.batch_sizes: list[int] = []

            def evaluate(self, features, masks):
                self.batch_sizes.append(len(features))
                return [[float(mask)] for mask in masks], [0.0] * len(features)

        network = RecordingNetwork()
        rows = [{"features": [index], "legal_mask": index + 1} for index in range(294)]
        priors = _frontier_priors(network, rows, 256)
        self.assertEqual(network.batch_sizes, [256, 38])
        self.assertEqual(priors[0], [1.0])
        self.assertEqual(priors[-1], [294.0])
        with self.assertRaisesRegex(ValueError, "must be positive"):
            _frontier_priors(network, rows, 0)

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

    def test_native_timeout_round_trips_across_actor_processes(self) -> None:
        timeout = NativeRequestTimeout("batch", 15.0)
        restored = pickle.loads(pickle.dumps(timeout))
        self.assertEqual(restored.operation, "batch")
        self.assertEqual(restored.seconds, 15.0)
        self.assertEqual(
            str(restored), "native search operation 'batch' exceeded 15.0s"
        )

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

    def test_fresh_root_solver_ignores_stale_online_strategy_sums(self) -> None:
        server = _ToyServer()
        network = _ToyNetwork()
        search = SimultaneousTreeSearch(
            server,
            network,
            network,
            JointSearchConfig(regret_iterations=2048),
            random.Random(1),
            random.Random(2),
        )
        node = search._make_node(server._snapshot(0), ([0.5, 0.5], [0.5, 0.5], 0.0))
        node.payoff = [[1.0, -1.0], [-1.0, 1.0]]
        node.player_strategy_sum = [1000.0, 0.0]
        node.enemy_strategy_sum = [1000.0, 0.0]
        node.solve_count = 1000
        player, enemy, value, exploitability = search._root_equilibrium(node)
        self.assertAlmostEqual(player[0], 0.5, places=3)
        self.assertAlmostEqual(enemy[0], 0.5, places=3)
        self.assertAlmostEqual(value, 0.0, places=3)
        self.assertLess(exploitability, 0.005)

    def test_native_uniform_rmplus_matches_the_python_reference(self) -> None:
        payoff = [
            [0.71, -0.42, 0.19],
            [-0.83, 0.37, 0.54],
            [-0.28, 0.91, -0.66],
        ]
        priors = [0.2, 0.3, 0.5]
        expected = solve_zero_sum_regret(
            payoff, priors, list(reversed(priors)), [0, 1, 2], [0, 1, 2], 2048
        )
        actual = solve_cold_native(
            payoff,
            priors,
            list(reversed(priors)),
            [0, 1, 2],
            [0, 1, 2],
            2048,
            cfr_plus=False,
        )
        self.assertTrue(native_available())
        for expected_policy, actual_policy in zip(
            expected[:2], actual[:2], strict=True
        ):
            for expected_value, actual_value in zip(
                expected_policy, actual_policy, strict=True
            ):
                self.assertAlmostEqual(expected_value, actual_value, places=12)
        self.assertAlmostEqual(expected[2], actual[2], places=12)
        self.assertAlmostEqual(expected[3], actual[3], places=12)
        self.assertEqual(
            actual,
            solve_cold_native(
                payoff,
                priors,
                list(reversed(priors)),
                [0, 1, 2],
                [0, 1, 2],
                2048,
                cfr_plus=False,
            ),
        )

    def test_native_cfrplus_improves_fixed_budget_convergence(self) -> None:
        payoff = [
            [0.71, -0.42, 0.19],
            [-0.83, 0.37, 0.54],
            [-0.28, 0.91, -0.66],
        ]
        priors = [1 / 3] * 3
        uniform = solve_cold_native(
            payoff, priors, priors, [0, 1, 2], [0, 1, 2], 64, cfr_plus=False
        )
        accelerated = solve_cold_native(
            payoff, priors, priors, [0, 1, 2], [0, 1, 2], 64, cfr_plus=True
        )
        self.assertLess(accelerated[3], uniform[3])

    def test_native_uniform_warm_state_matches_python_reference(self) -> None:
        server = _ToyServer()
        network = _ToyNetwork()
        searches = [
            SimultaneousTreeSearch(
                server,
                network,
                network,
                JointSearchConfig(
                    regret_iterations_per_update=32,
                    rmplus_backend=backend,
                ),
                random.Random(1),
                random.Random(2),
            )
            for backend in (PYTHON_REFERENCE_BACKEND, RUST_RMPLUS_BACKEND)
        ]
        nodes = [
            search._make_node(server._snapshot(0), ([0.35, 0.65], [0.6, 0.4], 0.0))
            for search in searches
        ]
        for node in nodes:
            node.payoff = [[0.8, -0.3], [-0.6, 0.5]]
        for search, node in zip(searches, nodes, strict=True):
            search._solve_node(node)
        for name in (
            "player_policy",
            "enemy_policy",
            "player_regrets",
            "enemy_regrets",
            "player_strategy_sum",
            "enemy_strategy_sum",
        ):
            for expected, actual in zip(
                getattr(nodes[0], name), getattr(nodes[1], name), strict=True
            ):
                self.assertAlmostEqual(expected, actual, places=12)
        self.assertAlmostEqual(nodes[0].root_value, nodes[1].root_value, places=12)
        self.assertAlmostEqual(
            nodes[0].exploitability, nodes[1].exploitability, places=12
        )
        self.assertEqual(nodes[0].solve_count, nodes[1].solve_count)

    def test_native_cfrplus_warm_state_uses_linear_averaging(self) -> None:
        server = _ToyServer()
        network = _ToyNetwork()
        search = SimultaneousTreeSearch(
            server,
            network,
            network,
            JointSearchConfig(
                regret_iterations_per_update=16,
                rmplus_backend=RUST_RMPLUS_BACKEND,
                cfr_plus_solves=True,
            ),
            random.Random(1),
            random.Random(2),
        )
        node = search._make_node(server._snapshot(0), ([0.5, 0.5], [0.5, 0.5], 0.0))
        node.payoff = [[0.8, -0.3], [-0.6, 0.5]]
        search._solve_node(node)
        self.assertEqual(node.solve_count, 16)
        self.assertAlmostEqual(sum(node.player_strategy_sum), 136.0, places=10)
        self.assertAlmostEqual(sum(node.enemy_strategy_sum), 136.0, places=10)
        average = search._average_policy(
            node.player_strategy_sum, node.solve_count, node.player_policy
        )
        self.assertAlmostEqual(sum(average), 1.0, places=12)

    def test_tree_rmplus_does_not_cap_equilibrium_switch_mass(self) -> None:
        server = _ToyServer()
        network = _ThirteenActionToyNetwork()
        search = SimultaneousTreeSearch(
            server,
            network,
            network,
            JointSearchConfig(regret_iterations_per_update=64),
            random.Random(1),
            random.Random(2),
        )
        snapshot = replace(
            server._snapshot(0), player_mask=(1 << 0) | (1 << 4), enemy_mask=1
        )
        priors = [0.0] * 13
        priors[0] = priors[4] = 0.5
        enemy_priors = [0.0] * 13
        enemy_priors[0] = 1.0
        node = search._make_node(snapshot, (priors, enemy_priors, 0.0))
        node.payoff[4][0] = 1.0
        search._solve_node(node)
        self.assertGreater(node.player_policy[4], 0.9)

    def test_tree_solver_accumulates_rmplus_state_across_updates(self) -> None:
        server = _ToyServer()
        network = _ThirteenActionToyNetwork()
        search = SimultaneousTreeSearch(
            server,
            network,
            network,
            JointSearchConfig(regret_iterations_per_update=64),
            random.Random(1),
            random.Random(2),
        )
        mask = (1 << 0) | (1 << 4)
        snapshot = replace(server._snapshot(0), player_mask=mask, enemy_mask=mask)
        priors = [0.0] * 13
        priors[0] = priors[4] = 0.5
        node = search._make_node(snapshot, (list(priors), list(priors), 0.0))
        # Player action 4 strictly dominates action 0; enemy column 0 strictly
        # dominates column 4, so the last iterate settles on the pure pair
        # (4, 0) with value 0.4.
        node.payoff[0][0] = -0.6
        node.payoff[0][4] = -0.2
        node.payoff[4][0] = 0.4
        node.payoff[4][4] = 0.8
        search._solve_node(node)
        self.assertEqual(node.solve_count, 64)
        self.assertGreater(node.player_policy[4], 0.95)
        self.assertGreater(node.enemy_policy[0], 0.95)
        self.assertAlmostEqual(node.root_value, 0.4, places=1)
        self.assertLess(node.exploitability, 0.2)
        self.assertAlmostEqual(sum(node.player_strategy_sum), 64.0, places=6)
        self.assertAlmostEqual(sum(node.enemy_strategy_sum), 64.0, places=6)
        self.assertTrue(all(regret >= 0.0 for regret in node.player_regrets))
        self.assertTrue(all(regret >= 0.0 for regret in node.enemy_regrets))
        first_dominant_mass = node.player_policy[4]
        search._solve_node(node)
        self.assertEqual(node.solve_count, 128)
        self.assertGreaterEqual(node.player_policy[4], first_dominant_mass - 0.01)
        self.assertAlmostEqual(sum(node.player_strategy_sum), 128.0, places=6)

    def test_chance_resampling_decays_with_evidence(self) -> None:
        server = _ToyServer()
        network = _ToyNetwork()
        search = SimultaneousTreeSearch(
            server,
            network,
            network,
            JointSearchConfig(chance_resample=0.1),
            random.Random(1),
            random.Random(2),
        )
        self.assertEqual(search._chance_resample_probability(1), 1.0)
        self.assertEqual(search._chance_resample_probability(4), 0.5)
        self.assertEqual(search._chance_resample_probability(100), 0.1)

    def test_tree_exploration_uses_neural_progressive_bias(self) -> None:
        server = _ToyServer()
        network = _ToyNetwork()
        search = SimultaneousTreeSearch(
            server,
            network,
            network,
            JointSearchConfig(exploration=0.2),
            random.Random(1),
            random.Random(2),
        )
        mixed = search._mixed_policy((1.0, 0.0), [0.0, 1.0], [0, 1], 0)
        self.assertAlmostEqual(mixed[0], 0.8)
        self.assertAlmostEqual(mixed[1], 0.2)

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
                rmplus_backend=RUST_RMPLUS_BACKEND,
                cfr_plus_solves=True,
            ),
            random.Random(7),
            random.Random(11),
        )
        result = search.search(server._snapshot(0), sample_actions=False)
        self.assertEqual(
            result.solver,
            "simultaneous-matrix-tree-rust-cfrplus-pooled-node-v4",
        )
        self.assertEqual(result.diagnostics["root_solver"], "rust-cfrplus-f64-v1")
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

    def test_expanded_node_full_evaluations_use_pooled_joint_frontiers(self) -> None:
        server = _DistinctFeatureToyServer()
        server.states[100] = (0, 0)
        network = _LeafToyNetwork()
        config = JointSearchConfig(
            max_depth=2,
            inference_batch_size=32,
            max_actions_per_side=2,
            expansion_budget=16,
            chance_resample=1.0,
            regret_iterations_per_update=4,
            minimum_expansion_budget=4,
        )
        results = SimultaneousTreeSearch.search_many(
            [
                SimultaneousTreeSearch(
                    server,
                    network,
                    network,
                    config,
                    random.Random(index + 1),
                    random.Random(index + 101),
                )
                for index in range(2)
            ],
            [server._snapshot(0), server._snapshot(100)],
        )
        self.assertEqual(len(results), 2)
        self.assertTrue(
            all(
                result.diagnostics["deep_full_inference_rows"] > 0 for result in results
            )
        )
        self.assertTrue(
            all(
                result.diagnostics["mean_deep_full_inference_batch"] >= 2
                for result in results
            )
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
        self.assertEqual(arguments.iterations * arguments.episodes, 491_520)
        self.assertEqual(arguments.iterations, 30)
        self.assertEqual(arguments.episodes, 16_384)
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
        self.assertEqual(arguments.opponent_fraction, 0.67)
        self.assertEqual(arguments.model_opponent_share, 0.5)
        self.assertEqual(arguments.promotion_games, 2048)
        self.assertEqual(arguments.promotion_policy_games, 2048)
        self.assertEqual(arguments.probe_games, 256)
        self.assertEqual(arguments.campaign_games, 288)
        self.assertEqual(arguments.tree_expansion_budget, 320)
        self.assertEqual(arguments.chance_samples_per_joint, 2)
        self.assertEqual(arguments.regret_iterations, 2048)
        self.assertEqual(arguments.tree_regret_iterations, 16)
        self.assertEqual(arguments.tree_deeper_joint_rotations, 2)
        self.assertEqual(arguments.tree_minimum_budget, 192)
        self.assertEqual(arguments.tree_convergence_patience, 8)
        self.assertEqual(arguments.deep_search_fraction, 1.0)
        self.assertEqual(arguments.actor_batch_size, 64)
        self.assertEqual(arguments.actor_processes, 8)
        self.assertEqual(arguments.eval_processes, 12)
        self.assertEqual(arguments.token_group_size, 1)
        self.assertEqual(arguments.token_layout, "semantic-entity-v1")
        self.assertTrue(arguments.joint_policy_heads)
        self.assertTrue(arguments.distilled_leaf_evaluator)
        self.assertEqual(arguments.leaf_hidden, 64)
        self.assertIsNone(arguments.leaf_hidden_layers)
        self.assertEqual(arguments.leaf_ema_decay, 0.995)
        self.assertEqual(arguments.leaf_loss_weight, 0.25)
        self.assertEqual(arguments.promotion_nonfinish_policy, "losses")
        self.assertEqual(arguments.promotion_pooled_z, 1.96)
        self.assertTrue(arguments.bootstrap_promotion)
        self.assertEqual(arguments.lr_schedule, "step")
        self.assertEqual(arguments.lr_milestones, (10, 20))
        self.assertEqual(arguments.lr_decay_factor, 0.1)
        self.assertIsNone(arguments.capacity_preset)
        self.assertEqual(arguments.replay_window, 3)
        self.assertTrue(arguments.adaptive_search)
        self.assertEqual(arguments.adaptive_warmup_iterations, 1)
        self.assertEqual(arguments.adaptive_deep_threshold, 0.50)
        self.assertEqual(arguments.adaptive_force_deep_fraction, 0.10)
        self.assertEqual(arguments.adaptive_max_false_negative_rate, 0.10)
        self.assertEqual(arguments.adaptive_fn_pool_window, 1)
        self.assertEqual(arguments.shadow_opponent_window, 6)
        self.assertEqual(arguments.router_fn_exposure_floor, 0.02)
        self.assertEqual(arguments.collection_epsilon, 0.05)
        self.assertEqual(arguments.collection_epsilon_turns, 8)
        self.assertEqual(arguments.policy_target_smoothing, 0.02)
        self.assertEqual(arguments.collection_dirichlet_alpha, 0.6)
        self.assertEqual(arguments.collection_dirichlet_weight, 0.25)
        self.assertEqual(arguments.collection_dirichlet_total, 10.0)
        self.assertEqual(arguments.frontier_buffer_size, 256)
        self.assertEqual(arguments.frontier_restart_fraction, 0.25)
        self.assertEqual(arguments.budget_loss_weight, 0.05)
        self.assertEqual(arguments.budget_positive_weight, 4.0)
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
        self.assertTrue(arena.adaptive_search)
        self.assertEqual(arena.adaptive_deep_threshold, 0.50)
        self.assertEqual(arena.adaptive_force_deep_fraction, 0.10)

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

    def test_leaf_hidden_layers_flow_from_the_cli(self) -> None:
        arguments = training_parser().parse_args(
            [
                "transformer-train",
                "--output",
                "/tmp/leaf-layers",
                "--leaf-hidden-layers",
                "256,128",
            ]
        )
        self.assertEqual(arguments.leaf_hidden_layers, (256, 128))
        with self.assertRaises(SystemExit):
            training_parser().parse_args(
                [
                    "transformer-train",
                    "--output",
                    "/tmp/leaf-layers",
                    "--leaf-hidden-layers",
                    "256,zero",
                ]
            )

    def test_saved_config_normalization_defaults_new_fields(self) -> None:
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
        config.pop("leaf_hidden_layers")
        config.pop("leaf_ema_decay")
        config.pop("promotion_nonfinish_policy")
        config.pop("promotion_pooled_z")
        config.pop("promotion_policy_games")
        config.pop("bootstrap_promotion")
        config.pop("adaptive_fn_pool_window")
        config.pop("lr_schedule")
        config.pop("lr_milestones")
        config.pop("lr_decay_factor")
        config.pop("shadow_opponent_window")
        config.pop("router_fn_exposure_floor")
        config.pop("collection_epsilon")
        config.pop("collection_epsilon_turns")
        config.pop("policy_target_smoothing")
        config.pop("collection_dirichlet_alpha")
        config.pop("collection_dirichlet_weight")
        config.pop("collection_dirichlet_total")
        config.pop("frontier_buffer_size")
        config.pop("frontier_restart_fraction")
        normalized = _normalized_saved_config(config)
        self.assertIsNone(normalized["leaf_hidden_layers"])
        self.assertEqual(normalized["leaf_ema_decay"], 0.0)
        self.assertEqual(normalized["promotion_nonfinish_policy"], "losses")
        self.assertEqual(normalized["promotion_pooled_z"], 0.0)
        self.assertEqual(normalized["promotion_policy_games"], 0)
        self.assertFalse(normalized["bootstrap_promotion"])
        self.assertEqual(normalized["adaptive_fn_pool_window"], 1)
        self.assertEqual(normalized["lr_schedule"], "constant")
        self.assertEqual(normalized["lr_milestones"], ())
        self.assertEqual(normalized["lr_decay_factor"], 0.1)
        self.assertEqual(normalized["shadow_opponent_window"], 0)
        self.assertEqual(normalized["router_fn_exposure_floor"], 0.0)
        self.assertEqual(normalized["collection_epsilon"], 0.0)
        self.assertEqual(normalized["collection_epsilon_turns"], 0)
        self.assertEqual(normalized["policy_target_smoothing"], 0.0)
        self.assertEqual(normalized["collection_dirichlet_alpha"], 0.0)
        self.assertEqual(normalized["collection_dirichlet_weight"], 0.25)
        self.assertEqual(normalized["collection_dirichlet_total"], 0.0)
        self.assertEqual(normalized["frontier_buffer_size"], 0)
        self.assertEqual(normalized["frontier_restart_fraction"], 0.0)
        self.assertEqual(normalized, asdict(TransformerPipelineConfig(**config)))
        self.assertNotIn("leaf_hidden_layers", config)

    def _leaf_ema_network(self) -> BattleTransformer:
        return BattleTransformer(
            TransformerConfig(
                feature_count=8,
                action_count=2,
                d_model=8,
                heads=2,
                layers=1,
                feedforward=16,
                distilled_leaf_evaluator=True,
            )
        )

    def test_leaf_ema_state_lags_training_and_swaps_on_exit(self) -> None:
        network = self._leaf_ema_network()
        with torch.no_grad():
            for name, parameter in network.named_parameters():
                if name.startswith("leaf_value."):
                    parameter.fill_(1.0)
        state = _initial_leaf_ema_state(network, 0.5)
        self.assertIsNotNone(state)
        _begin_leaf_training(network, state)
        with torch.no_grad():
            for name, parameter in network.named_parameters():
                if name.startswith("leaf_value."):
                    parameter.fill_(3.0)
        _update_leaf_ema(network, state, 0.5)
        _end_leaf_training(network, state)
        for name, parameter in network.named_parameters():
            if name.startswith("leaf_value."):
                torch.testing.assert_close(parameter, torch.full_like(parameter, 2.0))
                torch.testing.assert_close(
                    state["training"][name],
                    torch.full_like(parameter, 3.0),
                )

    def test_leaf_ema_restores_raw_weights_for_the_next_epoch(self) -> None:
        network = self._leaf_ema_network()
        state = _initial_leaf_ema_state(network, 0.9)
        _begin_leaf_training(network, state)
        with torch.no_grad():
            network.leaf_value[0].bias.fill_(5.0)
        _update_leaf_ema(network, state, 0.9)
        _end_leaf_training(network, state)
        _begin_leaf_training(network, state)
        torch.testing.assert_close(
            network.leaf_value[0].bias,
            torch.full_like(network.leaf_value[0].bias, 5.0),
        )

    def test_leaf_ema_state_is_disabled_at_zero_decay(self) -> None:
        network = self._leaf_ema_network()
        self.assertIsNone(_initial_leaf_ema_state(network, 0.0))
        before = {
            name: parameter.detach().clone()
            for name, parameter in network.named_parameters()
        }
        _begin_leaf_training(network, None)
        _update_leaf_ema(network, None, 0.0)
        _end_leaf_training(network, None)
        for name, parameter in network.named_parameters():
            torch.testing.assert_close(parameter, before[name])
        self.assertIsNone(_leaf_ema_checkpoint_state(None))

    def test_leaf_ema_checkpoint_state_is_a_detached_cpu_copy(self) -> None:
        network = self._leaf_ema_network()
        state = _initial_leaf_ema_state(network, 0.5)
        saved = _leaf_ema_checkpoint_state(state)
        for key in ("average", "training"):
            for tensor in saved[key].values():
                self.assertEqual(tensor.device.type, "cpu")
                self.assertFalse(tensor.requires_grad)
        with torch.no_grad():
            state["average"]["leaf_value.0.bias"].fill_(9.0)
        self.assertFalse(
            torch.equal(
                saved["average"]["leaf_value.0.bias"],
                state["average"]["leaf_value.0.bias"],
            )
        )

    def test_finished_pair_scores_drop_pairs_with_any_nonfinish(self) -> None:
        battles = [
            _paired_battle(0, "finished", 1, 1.0),
            _paired_battle(1, "finished", -1, 0.0),
            _paired_battle(2, "truncated", None, 0.0),
            _paired_battle(3, "finished", 1, 1.0),
            _paired_battle(4, "mechanics-timeout", 1, 0.0),
            _paired_battle(5, "finished", 0, 0.5),
            _paired_battle(6, "finished", 0, 0.5),
            _paired_battle(7, "finished", 0, 0.5),
        ]
        self.assertTrue(_battle_finished(battles[0]))
        self.assertFalse(_battle_finished(battles[2]))
        self.assertFalse(_battle_finished(battles[4]))
        self.assertEqual(_finished_pair_scores(battles), [0.5, 0.5])
        self.assertEqual(_finished_pair_scores([]), [])

    def test_exclude_pairs_policy_recovers_a_nonfinish_dragged_gate(self) -> None:
        battles = []
        for pair in range(20):
            battles.append(_paired_battle(2 * pair, "finished", 1, 1.0))
            battles.append(_paired_battle(2 * pair + 1, "finished", -1, 0.0))
        battles.append(_paired_battle(40, "semantic-divergence", None, 0.0))
        battles.append(_paired_battle(41, "finished", -1, 0.0))
        battles.append(_paired_battle(42, "truncated", None, 0.0))
        battles.append(_paired_battle(43, "truncated", None, 0.0))
        losses_pairs = [
            (battles[game]["score"] + battles[game + 1]["score"]) / 2.0
            for game in range(0, len(battles), 2)
        ]
        self.assertLess(sum(losses_pairs) / len(losses_pairs), 0.5)
        self.assertLess(_mean_ci95(losses_pairs)[0], 0.5)
        excluded = _finished_pair_scores(battles)
        self.assertEqual(excluded, [0.5] * 20)
        self.assertEqual(_mean_ci95(excluded), (0.5, 0.5))

    def test_promotion_gate_scores_follow_the_nonfinish_policy(self) -> None:
        promotion = {
            "score_with_nonfinishes_as_losses": 0.4545,
            "paired_score_ci95": [0.44, 0.47],
            "score_excluding_nonfinish_pairs": 0.5,
            "paired_score_ci95_excluding_nonfinish_pairs": [0.5, 0.5],
        }
        self.assertEqual(_promotion_gate_scores(promotion, "losses"), (0.4545, 0.44))
        self.assertEqual(_promotion_gate_scores(promotion, "exclude-pairs"), (0.5, 0.5))
        empty = {
            "score_with_nonfinishes_as_losses": 0.0,
            "paired_score_ci95": [0.0, 0.0],
            "score_excluding_nonfinish_pairs": None,
            "paired_score_ci95_excluding_nonfinish_pairs": [None, None],
        }
        self.assertEqual(_promotion_gate_scores(empty, "exclude-pairs"), (None, None))

    def test_promotion_nonfinish_policy_flows_from_the_cli(self) -> None:
        arguments = training_parser().parse_args(
            [
                "transformer-train",
                "--output",
                "/tmp/nonfinish-policy",
                "--promotion-nonfinish-policy",
                "exclude-pairs",
            ]
        )
        self.assertEqual(arguments.promotion_nonfinish_policy, "exclude-pairs")
        with self.assertRaises(SystemExit):
            training_parser().parse_args(
                [
                    "transformer-train",
                    "--output",
                    "/tmp/nonfinish-policy",
                    "--promotion-nonfinish-policy",
                    "ignore",
                ]
            )

    def test_promotion_nonfinish_policy_is_validated(self) -> None:
        with self.assertRaisesRegex(ValueError, "promotion_nonfinish_policy"):
            _promotion_gate_scores({}, "ignore")

    def test_score_moments_summarize_paired_scores(self) -> None:
        self.assertEqual(_score_moments([1.0, 0.5, 0.5]), [2.0, 1.5, 3])
        self.assertEqual(_score_moments([]), [0.0, 0.0, 0])

    def test_pair_outcomes_expose_gate_sensitivity(self) -> None:
        report = _pair_outcome_report([1.0, 1.0, 0.0, 0.5, 0.5, 0.5, 0.75, 0.25, 0.25])
        self.assertEqual(report["pairs"], 9)
        self.assertEqual(report["candidate_sweeps"], 2)
        self.assertEqual(report["incumbent_sweeps"], 1)
        self.assertEqual(report["balanced"], 3)
        self.assertEqual(report["mixed"], 3)
        self.assertEqual(report["decisive"], 6)
        self.assertAlmostEqual(report["decisive_fraction"], 6 / 9)
        self.assertAlmostEqual(report["decisive_candidate_share"], 0.5)
        self.assertAlmostEqual(report["decisive_sign_z"], 0.0)
        lopsided = _pair_outcome_report([1.0, 1.0, 1.0, 1.0, 0.0, 0.5])
        self.assertEqual(lopsided["decisive"], 5)
        self.assertAlmostEqual(lopsided["decisive_candidate_share"], 0.8)
        self.assertAlmostEqual(lopsided["decisive_sign_z"], 3 / math.sqrt(5))
        empty = _pair_outcome_report([])
        self.assertEqual(empty["pairs"], 0)
        self.assertEqual(empty["decisive"], 0)
        self.assertIsNone(empty["decisive_fraction"])
        self.assertIsNone(empty["decisive_candidate_share"])
        self.assertIsNone(empty["decisive_sign_z"])
        frozen = _pair_outcome_report([0.5, 0.5])
        self.assertEqual(frozen["decisive"], 0)
        self.assertEqual(frozen["decisive_fraction"], 0.0)
        self.assertIsNone(frozen["decisive_candidate_share"])
        self.assertIsNone(frozen["decisive_sign_z"])

    def test_paired_arena_report_includes_pair_outcomes(self) -> None:
        torch.manual_seed(0)

        def tiny() -> BattleTransformer:
            network = BattleTransformer(
                TransformerConfig(
                    feature_count=492,
                    action_count=13,
                    d_model=8,
                    heads=2,
                    layers=1,
                    feedforward=16,
                    precision="fp32",
                )
            )
            network.eval()
            return network

        config = ArenaConfig(
            games=4,
            budget=64,
            chance_samples_per_joint=1,
            search_depth=1,
            regret_iterations=8,
            inference_batch_size=64,
            max_actions_per_side=2,
            tree_expansion_budget=2,
            tree_minimum_budget=1,
            tree_regret_iterations=1,
            tree_convergence_patience=1,
            adaptive_search=False,
            seed=1234,
            seed_count=2,
        )
        report = run_paired_arena(tiny(), tiny(), config)
        outcomes = report["pair_outcomes"]
        self.assertEqual(outcomes["pairs"], 2)
        self.assertEqual(
            outcomes["candidate_sweeps"]
            + outcomes["incumbent_sweeps"]
            + outcomes["balanced"]
            + outcomes["mixed"],
            2,
        )
        pair_scores = [
            (
                report["battles"][2 * pair]["score"]
                + report["battles"][2 * pair + 1]["score"]
            )
            / 2
            for pair in range(2)
        ]
        self.assertEqual(outcomes, _pair_outcome_report(pair_scores))

    def test_policy_only_arena_selects_deterministic_network_argmax(self) -> None:
        torch.manual_seed(1)

        def tiny() -> BattleTransformer:
            network = BattleTransformer(
                TransformerConfig(
                    feature_count=492,
                    action_count=13,
                    d_model=8,
                    heads=2,
                    layers=1,
                    feedforward=16,
                    precision="fp32",
                )
            )
            network.eval()
            return network

        self.assertFalse(ArenaConfig(games=4, seed_count=2).policy_only)
        candidate = tiny()
        baseline = tiny()
        config = ArenaConfig(
            games=4,
            budget=64,
            inference_batch_size=64,
            seed=4321,
            seed_count=2,
            policy_only=True,
        )
        report = run_paired_arena(candidate, baseline, config)
        self.assertEqual(report["action_selector"], "network-policy-argmax-v1")
        self.assertIsNone(report["search"])
        self.assertEqual(report["games"], 4)
        self.assertEqual(report["pair_outcomes"]["pairs"], 2)
        repeat = run_paired_arena(candidate, baseline, config)
        self.assertEqual(
            [battle["score"] for battle in report["battles"]],
            [battle["score"] for battle in repeat["battles"]],
        )

    def test_policy_argmax_actions_use_each_sides_own_priors(self) -> None:
        class _PriorNetwork:
            def __init__(self, priors: dict[tuple[int, ...], list[float]]) -> None:
                self.priors = priors
                self.calls: list[int] = []

            def evaluate(
                self, features: list[tuple[int, ...]], masks: list[int]
            ) -> tuple[list[list[float]], list[float]]:
                self.calls.append(len(masks))
                policies = [list(self.priors[tuple(row)]) for row in features]
                return policies, [0.0] * len(masks)

        candidate = _PriorNetwork({(1, 0): [0.1, 0.7, 0.2], (0, 1): [0.5, 0.5, 0.0]})
        baseline = _PriorNetwork({(2, 0): [0.9, 0.05, 0.05], (0, 2): [0.2, 0.3, 0.5]})

        def snapshot(
            player_features: tuple[int, ...],
            player_mask: int,
            enemy_features: tuple[int, ...],
            enemy_mask: int,
        ) -> SimpleNamespace:
            return SimpleNamespace(
                request="switch",
                player_features=player_features,
                player_mask=player_mask,
                enemy_features=enemy_features,
                enemy_mask=enemy_mask,
            )

        def episode(
            game: int, candidate_player: bool, snap: SimpleNamespace
        ) -> _FastArenaEpisode:
            return _FastArenaEpisode(
                game=game,
                candidate_player=candidate_player,
                player=candidate if candidate_player else baseline,
                enemy=baseline if candidate_player else candidate,
                selection_rng=None,
                chance_rng=None,
                budget_rng=None,
                player_size=3,
                enemy_size=3,
                level100=False,
                campaign_index=0,
                snapshot=snap,
            )

        episodes = [
            episode(0, True, snapshot((1, 0), 0b111, (0, 2), 0b110)),
            episode(1, False, snapshot((2, 0), 0b011, (0, 1), 0b011)),
        ]
        results = _policy_argmax_actions(
            episodes, ArenaConfig(games=4, seed_count=2, policy_only=True)
        )
        self.assertEqual([result.failure for result in results], [None, None])
        self.assertEqual(
            [result.solver for result in results], ["network-policy-argmax-v1"] * 2
        )
        self.assertEqual(results[0].player_action, 1)
        self.assertEqual(results[0].enemy_action, 2)
        self.assertEqual(results[1].player_action, 0)
        # The candidate's enemy-side priors tie at 0.5; ties break to the
        # lowest legal action so the lane stays deterministic.
        self.assertEqual(results[1].enemy_action, 0)
        self.assertEqual(candidate.calls, [1, 1])
        self.assertEqual(baseline.calls, [1, 1])

    def test_pooled_evidence_accumulates_until_the_z_threshold(self) -> None:
        iteration = {"paired_score_moments": [530.0, 530.0, 1000]}
        first = _pooled_promotion_evidence(None, iteration, "losses", 0.50, 2.25)
        self.assertEqual(first["iterations"], 1)
        self.assertEqual(first["pairs"], 1000)
        self.assertAlmostEqual(first["mean"], 0.53)
        self.assertAlmostEqual(first["z"], 1.8998, places=3)
        self.assertFalse(first["triggered"])
        second = _pooled_promotion_evidence(first, iteration, "losses", 0.50, 2.25)
        self.assertEqual(second["iterations"], 2)
        self.assertEqual(second["pairs"], 2000)
        self.assertAlmostEqual(second["mean"], 0.53)
        self.assertAlmostEqual(second["z"], 2.6875, places=3)
        self.assertTrue(second["triggered"])
        self.assertEqual(second["threshold"], 2.25)

    def test_pooled_evidence_respects_policy_and_minimum_score(self) -> None:
        iteration = {
            "paired_score_moments": [0.0, 0.0, 0],
            "paired_score_moments_excluding_nonfinish_pairs": [1060.0, 1060.0, 2000],
        }
        pooled = _pooled_promotion_evidence(
            None, iteration, "exclude-pairs", 0.50, 2.25
        )
        self.assertEqual(pooled["pairs"], 2000)
        self.assertTrue(pooled["triggered"])
        held_back = _pooled_promotion_evidence(
            None, iteration, "exclude-pairs", 0.55, 2.25
        )
        self.assertFalse(held_back["triggered"])
        with self.assertRaisesRegex(ValueError, "promotion_nonfinish_policy"):
            _pooled_promotion_evidence(None, iteration, "ignore", 0.50, 2.25)

    def test_pooled_evidence_handles_degenerate_samples(self) -> None:
        empty = _pooled_promotion_evidence(
            None, {"paired_score_moments": [0.0, 0.0, 0]}, "losses", 0.50, 2.25
        )
        self.assertIsNone(empty["mean"])
        self.assertIsNone(empty["z"])
        self.assertFalse(empty["triggered"])
        constant = _pooled_promotion_evidence(
            None, {"paired_score_moments": [50.0, 25.0, 100]}, "losses", 0.50, 2.25
        )
        self.assertAlmostEqual(constant["mean"], 0.5)
        self.assertIsNone(constant["z"])
        self.assertFalse(constant["triggered"])

    def test_resumed_pooled_evidence_survives_only_unaccepted_records(self) -> None:
        pooled = {"iterations": 2, "pairs": 2000}
        self.assertIsNone(_resumed_pooled_evidence([]))
        self.assertIsNone(
            _resumed_pooled_evidence(
                [{"promotion": {"accepted": True, "pooled": pooled}}]
            )
        )
        self.assertEqual(
            _resumed_pooled_evidence(
                [{"promotion": {"accepted": False, "pooled": pooled}}]
            ),
            pooled,
        )
        self.assertIsNone(
            _resumed_pooled_evidence([{"promotion": {"accepted": False}}])
        )
        self.assertIsNone(_resumed_pooled_evidence([{}]))

    def test_resumed_pooled_evidence_reads_the_requested_lane(self) -> None:
        pooled = {"iterations": 3, "pairs": 3000}
        record = [
            {
                "promotion": {
                    "accepted": False,
                    "pooled": {"iterations": 1, "pairs": 1000},
                    "policy_gate": {"pooled": pooled},
                }
            }
        ]
        self.assertEqual(_resumed_pooled_evidence(record, "policy_gate"), pooled)
        self.assertEqual(
            _resumed_pooled_evidence(record), {"iterations": 1, "pairs": 1000}
        )
        self.assertIsNone(_resumed_pooled_evidence([], "policy_gate"))
        accepted = [
            {"promotion": {"accepted": True, "policy_gate": {"pooled": pooled}}}
        ]
        self.assertIsNone(_resumed_pooled_evidence(accepted, "policy_gate"))
        self.assertIsNone(
            _resumed_pooled_evidence(
                [{"promotion": {"accepted": False}}], "policy_gate"
            )
        )
        self.assertIsNone(
            _resumed_pooled_evidence(
                [{"promotion": {"accepted": False, "policy_gate": None}}],
                "policy_gate",
            )
        )

    def test_lineage_promotions_counts_accepted_records(self) -> None:
        self.assertEqual(_lineage_promotions([]), 0)
        records = [
            {"promotion": {"accepted": False}},
            {"promotion": {"accepted": True}},
            {},
            {"promotion": {"accepted": True}},
        ]
        self.assertEqual(_lineage_promotions(records), 2)

    def test_bootstrap_waiver_requires_pristine_lineage(self) -> None:
        config = TransformerPipelineConfig(
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
            bootstrap_promotion=True,
        )
        self.assertTrue(_bootstrap_waiver_active(config, []))
        self.assertTrue(
            _bootstrap_waiver_active(config, [{"promotion": {"accepted": False}}])
        )
        self.assertFalse(
            _bootstrap_waiver_active(config, [{"promotion": {"accepted": True}}])
        )
        self.assertFalse(
            _bootstrap_waiver_active(
                config,
                [
                    {"promotion": {"accepted": True}},
                    {"promotion": {"accepted": False}},
                ],
            )
        )
        self.assertFalse(
            _bootstrap_waiver_active(replace(config, bootstrap_promotion=False), [])
        )
        self.assertFalse(
            _bootstrap_waiver_active(
                replace(config, warm_start_incumbent_checkpoint="/tmp/incumbent.pt"),
                [],
            )
        )

    def test_policy_gate_superior_requires_quality_and_confidence(self) -> None:
        def lane(**overrides: object) -> dict[str, object]:
            report: dict[str, object] = {
                "data_quality_pass": True,
                "quality_pass": True,
                "score_with_nonfinishes_as_losses": 0.55,
                "paired_score_ci95": [0.52, 0.58],
            }
            report.update(overrides)
            return report

        self.assertTrue(_policy_gate_superior(lane(), "losses", 0.50))
        self.assertFalse(
            _policy_gate_superior(lane(quality_pass=False), "losses", 0.50)
        )
        self.assertFalse(
            _policy_gate_superior(lane(data_quality_pass=False), "losses", 0.50)
        )
        self.assertFalse(
            _policy_gate_superior(lane(paired_score_ci95=[0.49, 0.60]), "losses", 0.50)
        )
        self.assertFalse(
            _policy_gate_superior(
                lane(score_with_nonfinishes_as_losses=0.49), "losses", 0.50
            )
        )
        self.assertFalse(_policy_gate_superior(lane(), "losses", 0.56))
        excluded = lane(
            score_excluding_nonfinish_pairs=0.60,
            paired_score_ci95_excluding_nonfinish_pairs=[0.55, 0.65],
        )
        self.assertTrue(_policy_gate_superior(excluded, "exclude-pairs", 0.50))
        empty = lane(
            score_excluding_nonfinish_pairs=None,
            paired_score_ci95_excluding_nonfinish_pairs=[None, None],
        )
        self.assertFalse(_policy_gate_superior(empty, "exclude-pairs", 0.50))

    def test_promotion_policy_games_flow_from_the_cli(self) -> None:
        arguments = training_parser().parse_args(
            ["transformer-train", "--output", "/tmp/policy-lane"]
        )
        self.assertEqual(arguments.promotion_policy_games, 2048)
        smoke = training_parser().parse_args(
            ["transformer-smoke", "--output", "/tmp/policy-lane"]
        )
        self.assertEqual(smoke.promotion_policy_games, 4)
        disabled = training_parser().parse_args(
            [
                "transformer-train",
                "--output",
                "/tmp/policy-lane",
                "--promotion-policy-games",
                "0",
            ]
        )
        self.assertEqual(disabled.promotion_policy_games, 0)
        config = TransformerPipelineConfig(
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
        self.assertEqual(config.promotion_policy_games, 0)
        gate_config = _arena_config(config, 4, 99, 2, policy_only=True)
        self.assertTrue(gate_config.policy_only)
        self.assertFalse(_arena_config(config, 4, 99, 2).policy_only)

    def test_bootstrap_promotion_flows_from_the_cli(self) -> None:
        arguments = training_parser().parse_args(
            ["transformer-train", "--output", "/tmp/bootstrap"]
        )
        self.assertTrue(arguments.bootstrap_promotion)
        disabled = training_parser().parse_args(
            [
                "transformer-train",
                "--output",
                "/tmp/bootstrap",
                "--no-bootstrap-promotion",
            ]
        )
        self.assertFalse(disabled.bootstrap_promotion)
        config = TransformerPipelineConfig(
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
        self.assertFalse(config.bootstrap_promotion)

    def test_promotion_pooled_z_flows_from_the_cli(self) -> None:
        arguments = training_parser().parse_args(
            [
                "transformer-train",
                "--output",
                "/tmp/pooled-z",
                "--promotion-pooled-z",
                "2.25",
            ]
        )
        self.assertEqual(arguments.promotion_pooled_z, 2.25)

    def test_adaptive_fn_pool_window_flows_from_the_cli(self) -> None:
        arguments = training_parser().parse_args(
            [
                "transformer-train",
                "--output",
                "/tmp/fn-pool",
                "--adaptive-fn-pool-window",
                "3",
            ]
        )
        self.assertEqual(arguments.adaptive_fn_pool_window, 3)

    def test_learning_rate_schedule_steps_at_milestones(self) -> None:
        config = SimpleNamespace(
            learning_rate=2e-4,
            lr_schedule="step",
            lr_milestones=(8, 16),
            lr_decay_factor=0.1,
        )
        self.assertEqual(_learning_rate_for_iteration(config, 1), 2e-4)
        self.assertEqual(_learning_rate_for_iteration(config, 7), 2e-4)
        self.assertAlmostEqual(_learning_rate_for_iteration(config, 8), 2e-5)
        self.assertAlmostEqual(_learning_rate_for_iteration(config, 15), 2e-5)
        self.assertAlmostEqual(_learning_rate_for_iteration(config, 16), 2e-6)
        self.assertAlmostEqual(_learning_rate_for_iteration(config, 40), 2e-6)
        constant = SimpleNamespace(
            learning_rate=2e-4,
            lr_schedule="constant",
            lr_milestones=(8,),
            lr_decay_factor=0.1,
        )
        self.assertEqual(_learning_rate_for_iteration(constant, 40), 2e-4)
        resumed = SimpleNamespace(
            learning_rate=2e-4,
            lr_schedule="step",
            lr_milestones=[8, 16],
            lr_decay_factor=0.5,
        )
        self.assertAlmostEqual(_learning_rate_for_iteration(resumed, 20), 5e-5)

    def test_apply_learning_rate_updates_every_param_group(self) -> None:
        network = self._leaf_ema_network()
        optimizer = torch.optim.AdamW(network.parameters(), lr=2e-4)
        _apply_learning_rate(optimizer, 5e-5)
        self.assertEqual([group["lr"] for group in optimizer.param_groups], [5e-5])

    def test_lr_schedule_flows_from_the_cli(self) -> None:
        arguments = training_parser().parse_args(
            [
                "transformer-train",
                "--output",
                "/tmp/lr-schedule",
                "--lr-schedule",
                "step",
                "--lr-milestones",
                "8,16",
                "--lr-decay-factor",
                "0.5",
            ]
        )
        self.assertEqual(arguments.lr_schedule, "step")
        self.assertEqual(arguments.lr_milestones, (8, 16))
        self.assertEqual(arguments.lr_decay_factor, 0.5)
        for invalid in (
            ["--lr-milestones", "8,zero"],
            ["--lr-schedule", "cosine"],
        ):
            with self.assertRaises(SystemExit):
                training_parser().parse_args(
                    ["transformer-train", "--output", "/tmp/lr-schedule", *invalid]
                )

    def test_capacity_preset_tier_a_fills_unset_flags(self) -> None:
        for command in ("transformer-train", "transformer-smoke"):
            arguments = _apply_capacity_preset(
                training_parser().parse_args(
                    [command, "--output", "/tmp/tier-a", "--capacity-preset", "tier-a"]
                )
            )
            self.assertEqual(arguments.d_model, 192)
            self.assertEqual(arguments.heads, 8)
            self.assertEqual(arguments.layers, 6)
            self.assertEqual(arguments.feedforward, 768)
            self.assertEqual(arguments.leaf_hidden_layers, (256, 128))
            self.assertEqual(arguments.replay_window, 3)
            self.assertEqual(arguments.lr_schedule, "step")
            self.assertEqual(arguments.lr_milestones, (10, 20))

    def test_capacity_preset_yields_to_explicit_flags(self) -> None:
        arguments = _apply_capacity_preset(
            training_parser().parse_args(
                [
                    "transformer-train",
                    "--output",
                    "/tmp/tier-a",
                    "--capacity-preset",
                    "tier-a",
                    "--d-model",
                    "160",
                    "--lr-milestones",
                    "12,24",
                ]
            )
        )
        self.assertEqual(arguments.d_model, 160)
        self.assertEqual(arguments.lr_milestones, (12, 24))
        self.assertEqual(arguments.heads, 8)
        self.assertEqual(arguments.layers, 6)
        self.assertEqual(arguments.feedforward, 768)
        self.assertEqual(arguments.leaf_hidden_layers, (256, 128))
        self.assertEqual(arguments.replay_window, 3)
        self.assertEqual(arguments.lr_schedule, "step")

    def test_capacity_preset_leaves_production_defaults_without_it(self) -> None:
        train = _apply_capacity_preset(
            training_parser().parse_args(["transformer-train", "--output", "/tmp/run"])
        )
        self.assertIsNone(train.capacity_preset)
        self.assertEqual(
            (train.d_model, train.heads, train.layers, train.feedforward),
            (256, 8, 6, 1024),
        )
        network = BattleTransformer(
            TransformerConfig(
                feature_count=492,
                action_count=13,
                d_model=train.d_model,
                heads=train.heads,
                layers=train.layers,
                feedforward=train.feedforward,
                token_group_size=train.token_group_size,
                token_layout=train.token_layout,
                joint_policy_heads=train.joint_policy_heads,
                distilled_leaf_evaluator=train.distilled_leaf_evaluator,
                leaf_hidden=train.leaf_hidden,
                leaf_hidden_layers=train.leaf_hidden_layers,
                adaptive_budget_head=train.adaptive_search,
            )
        )
        self.assertEqual(
            sum(parameter.numel() for parameter in network.parameters()), 5_025_245
        )
        self.assertIsNone(train.leaf_hidden_layers)
        self.assertEqual(train.replay_window, 3)
        self.assertEqual(train.lr_schedule, "step")
        self.assertEqual(train.lr_milestones, (10, 20))
        smoke = _apply_capacity_preset(
            training_parser().parse_args(["transformer-smoke", "--output", "/tmp/run"])
        )
        self.assertEqual(
            (smoke.d_model, smoke.heads, smoke.layers, smoke.feedforward),
            (64, 4, 2, 192),
        )
        verify = _apply_capacity_preset(training_parser().parse_args(["verify", "run"]))
        self.assertEqual(verify.run, Path("run"))
        with self.assertRaises(SystemExit):
            training_parser().parse_args(
                [
                    "transformer-train",
                    "--output",
                    "/tmp/run",
                    "--capacity-preset",
                    "tier-b",
                ]
            )

    def test_tier_a_preset_matches_the_audited_parameter_count(self) -> None:
        preset = _CAPACITY_PRESETS["tier-a"]
        network = BattleTransformer(
            TransformerConfig(
                feature_count=492,
                action_count=13,
                d_model=preset["d_model"],
                heads=preset["heads"],
                layers=preset["layers"],
                feedforward=preset["feedforward"],
                token_group_size=1,
                token_layout="semantic-entity-v1",
                joint_policy_heads=True,
                distilled_leaf_evaluator=True,
                leaf_hidden_layers=preset["leaf_hidden_layers"],
                adaptive_budget_head=True,
            )
        )
        total = sum(parameter.numel() for parameter in network.parameters())
        self.assertEqual(total, 3_004_317)
        leaf = sum(
            value.numel()
            for key, value in network.state_dict().items()
            if key.startswith("leaf_value.")
        )
        self.assertEqual(leaf, 159_233)
        self.assertEqual(
            _serialized_network_config(network.config)["leaf_hidden_layers"],
            [256, 128],
        )

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

    def test_arena_batch_spans_align_with_sequential_batching(self) -> None:
        self.assertEqual(
            _arena_batch_spans(288, 128), [(0, 128), (128, 256), (256, 288)]
        )
        self.assertEqual(_arena_batch_spans(256, 128), [(0, 128), (128, 256)])
        self.assertEqual(_arena_batch_spans(4, 128), [(0, 4)])
        with self.assertRaisesRegex(ValueError, "even"):
            _arena_batch_spans(288, 127)

    def test_parallel_arena_batch_size_uses_all_workers_with_complete_pairs(
        self,
    ) -> None:
        self.assertEqual(_arena_parallel_batch_size(2048, 128, 8), 128)
        self.assertEqual(_arena_parallel_batch_size(2048, 128, 10), 104)
        self.assertEqual(_arena_parallel_batch_size(2048, 128, 12), 86)
        self.assertEqual(_arena_parallel_batch_size(288, 128, 8), 36)
        self.assertEqual(_arena_parallel_batch_size(256, 64, 8), 32)
        self.assertEqual(_arena_parallel_batch_size(8, 128, 16), 2)
        for games, maximum, processes in (
            (2048, 128, 8),
            (2048, 128, 12),
            (288, 128, 12),
            (256, 64, 12),
        ):
            size = _arena_parallel_batch_size(games, maximum, processes)
            spans = _arena_batch_spans(games, size)
            partitions = [
                rows for rows in _arena_span_partition(spans, processes) if rows
            ]
            self.assertEqual(len(partitions), processes)
            self.assertEqual(
                sorted(span for rows in partitions for span in rows), spans
            )
            self.assertTrue(all((stop - start) % 2 == 0 for start, stop in spans))
        for arguments, message in (
            ((3, 128, 8), "even"),
            ((8, 127, 8), "even"),
            ((8, 128, 0), "positive"),
        ):
            with self.assertRaisesRegex(ValueError, message):
                _arena_parallel_batch_size(*arguments)

    def test_arena_span_partition_covers_every_batch_once(self) -> None:
        spans = _arena_batch_spans(2048, 128)
        partitions = _arena_span_partition(spans, 8)
        self.assertEqual(len(partitions), 8)
        self.assertEqual(sorted(span for rows in partitions for span in rows), spans)
        self.assertEqual(partitions[0][:2], [(0, 128), (1024, 1152)])
        self.assertEqual(partitions[1][0], (128, 256))
        ragged = _arena_span_partition(_arena_batch_spans(288, 128), 8)
        self.assertEqual([len(rows) for rows in ragged], [1, 1, 1, 0, 0, 0, 0, 0])

    def test_arena_worker_payload_round_trips_transformer_models(self) -> None:
        network = BattleTransformer(
            TransformerConfig(
                feature_count=8,
                action_count=2,
                d_model=8,
                heads=2,
                layers=1,
                feedforward=16,
                precision="fp32",
            )
        )
        record = _serialized_arena_model(network)
        loaded = _load_arena_model(record, torch.device("cpu"))
        self.assertIsInstance(loaded, BattleTransformer)
        self.assertFalse(loaded.training)
        self.assertEqual(loaded.inference_engine, network.inference_engine)
        for name, value in network.state_dict().items():
            self.assertTrue(torch.equal(value, loaded.state_dict()[name]))
        with self.assertRaises(TypeError):
            _serialized_arena_model(_ToyNetwork())

    def test_final_arena_baselines_round_trip_without_changing_controllers(
        self,
    ) -> None:
        network = BattleTransformer(
            TransformerConfig(
                feature_count=8,
                action_count=2,
                d_model=8,
                heads=2,
                layers=1,
                feedforward=16,
                precision="fp32",
            )
        )
        transformer_record = _serialized_final_arena_baseline(network)
        self.assertEqual(transformer_record["kind"], "transformer")
        loaded = _load_final_arena_baseline(transformer_record, torch.device("cpu"))
        self.assertIsInstance(loaded, BattleTransformer)
        controller = _ToyNetwork()
        controller_record = _serialized_final_arena_baseline(controller)
        self.assertEqual(controller_record["kind"], "controller")
        self.assertIs(
            _load_final_arena_baseline(controller_record, torch.device("cpu")),
            controller,
        )
        with self.assertRaisesRegex(ValueError, "unknown"):
            _load_final_arena_baseline({"kind": "bad"}, torch.device("cpu"))

    def test_final_arena_parallel_jobs_require_unique_outputs(self) -> None:
        network = BattleTransformer(
            TransformerConfig(
                feature_count=8,
                action_count=2,
                d_model=8,
                heads=2,
                layers=1,
                feedforward=16,
                precision="fp32",
            )
        )
        config = ArenaConfig(games=8, seed_count=2)
        jobs = [
            ArenaReportJob(Path("same"), _ToyNetwork(), config),
            ArenaReportJob(Path("same"), _ToyNetwork(), config),
        ]
        with self.assertRaisesRegex(ValueError, "unique"):
            write_arena_reports_parallel(network, jobs, 2)
        for processes in (0, 17):
            with self.assertRaisesRegex(ValueError, "processes"):
                write_arena_reports_parallel(network, [], processes)

    def test_parallel_arena_episodes_travel_without_models_or_native_state(
        self,
    ) -> None:
        episode = _FastArenaEpisode(
            game=3,
            candidate_player=False,
            player=object(),
            enemy=object(),
            selection_rng=random.Random(0),
            chance_rng=random.Random(1),
            budget_rng=random.Random(2),
            player_size=6,
            enemy_size=5,
            level100=True,
            campaign_index=4,
            snapshot=object(),
            result=1,
            stop="finished",
            reason=None,
            initial={"request": "battle"},
            final={"request": "battle"},
            timeline=[{"turn": 1}],
            inspection={"request": "battle"},
        )
        slim = _slim_arena_episode(episode)
        self.assertEqual(
            (
                slim.game,
                slim.candidate_player,
                slim.player_size,
                slim.enemy_size,
                slim.level100,
                slim.campaign_index,
                slim.result,
                slim.stop,
                slim.reason,
            ),
            (3, False, 6, 5, True, 4, 1, "finished", None),
        )
        self.assertEqual(slim.initial, {"request": "battle"})
        self.assertEqual(slim.final, {"request": "battle"})
        self.assertEqual(slim.timeline, [{"turn": 1}])
        for name in (
            "player",
            "enemy",
            "selection_rng",
            "chance_rng",
            "budget_rng",
            "snapshot",
            "inspection",
        ):
            self.assertIsNone(getattr(slim, name))
        pickle.dumps(slim)

    def test_live_arena_report_emits_incremental_battle_telemetry(self) -> None:
        def episode(
            game: int,
            candidate_player: bool,
            result: int | None,
            stop: str,
        ) -> _FastArenaEpisode:
            return _FastArenaEpisode(
                game=game,
                candidate_player=candidate_player,
                player=None,
                enemy=None,
                selection_rng=None,
                chance_rng=None,
                budget_rng=None,
                player_size=2,
                enemy_size=3,
                level100=False,
                campaign_index=0,
                snapshot=None,
                result=result,
                stop=stop,
            )

        report = _live_arena_report(
            [
                episode(0, True, 1, "finished"),
                episode(1, False, -1, "finished"),
                episode(2, True, None, "semantic-divergence"),
                episode(3, False, None, "truncated"),
            ],
            ArenaConfig(games=4, seed_count=2),
            False,
            3,
        )
        self.assertEqual(report["finished"], 2)
        self.assertEqual(report["wins"], 2)
        self.assertEqual(report["semantic_divergences"], 1)
        self.assertEqual(report["truncated"], 1)
        self.assertEqual(report["score_sum"], 2.0)
        self.assertEqual(report["pairs"], 2)
        self.assertEqual(
            [battle["game"] for battle in report["recent_battles"]], [1, 2, 3]
        )
        self.assertEqual(report["recent_battles"][0]["candidate_return"], 1)

    def test_paired_arena_rejects_invalid_process_counts(self) -> None:
        config = ArenaConfig(games=8, seed_count=2)
        for processes in (0, 17):
            with self.assertRaisesRegex(ValueError, "processes"):
                run_paired_arena(
                    _ToyNetwork(), _ToyNetwork(), config, processes=processes
                )

    def test_parallel_traced_episodes_travel_with_replays_and_metrics(self) -> None:
        candidate_metrics = SkillMetrics(damaging_moves=4, best_effectiveness_choices=2)
        baseline_metrics = SkillMetrics(status_uses=3, status_successes=1)
        episode = _TracedArenaEpisode(
            game=5,
            candidate_player=False,
            player=object(),
            enemy=object(),
            selection_rng=random.Random(0),
            chance_rng=random.Random(1),
            budget_rng=random.Random(2),
            player_size=4,
            enemy_size=4,
            level100=False,
            campaign_index=0,
            snapshot=object(),
            result=-1,
            stop="finished",
            inspection={"request": "battle"},
            replay=Replay(lines=["|start", "|turn|1"]),
            replay_path=Path("replays/game-00005.log"),
            candidate_metrics=candidate_metrics,
            baseline_metrics=baseline_metrics,
        )
        slim = _slim_traced_episode(episode)
        self.assertEqual(
            (slim.game, slim.candidate_player, slim.result, slim.stop),
            (5, False, -1, "finished"),
        )
        self.assertEqual(slim.replay.lines, ["|start", "|turn|1"])
        self.assertEqual(slim.replay_path, Path("replays/game-00005.log"))
        self.assertEqual(slim.candidate_metrics, candidate_metrics)
        self.assertEqual(slim.baseline_metrics, baseline_metrics)
        for name in (
            "player",
            "enemy",
            "selection_rng",
            "chance_rng",
            "budget_rng",
            "snapshot",
            "inspection",
        ):
            self.assertIsNone(getattr(slim, name))
        pickle.dumps(slim)

    def test_traced_arena_rejects_invalid_process_counts(self) -> None:
        config = ArenaConfig(games=8, seed_count=2)
        for processes in (0, 17):
            with self.assertRaisesRegex(ValueError, "processes"):
                run_traced_arena(
                    _ToyNetwork(), _ToyNetwork(), config, processes=processes
                )

    def test_resume_defaults_legacy_runs_to_sequential_evaluation(self) -> None:
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
            config.pop("eval_processes")
            write_json(
                root / "run.json",
                {
                    "pipeline": _pipeline_id(),
                    "profile": "full-link-party-1to6-perfect-v2",
                    "schema": "full-link-party-state-v4",
                    "config": config,
                },
            )
            self.assertEqual(_resume_config(root).eval_processes, 1)

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

    def test_redundant_action_shaping_matches_flag_classification(self) -> None:
        policy = [0.35, 0.3, 0.2, 0.1, 0.05] + [0.0] * 8
        move_sets = (
            (86, 92, 45, 34),  # Thunder Wave, Toxic, Sing, Body Slam
            (14, 97, 32, 0),  # Swords Dance, Agility, Horn Drill, empty slot
            (12, 86, 14, 33),  # Guillotine, Thunder Wave, Swords Dance, Tackle
        )
        for moves in move_sets:
            for target_status in (0, 0x02, 0x08, 0x40):
                for attack_stage in (6, 13):
                    for target_speed in (99, 101):
                        features = [0] * 492
                        for slot, move in enumerate(moves):
                            features[140 + slot] = move
                        features[159] = attack_stage
                        features[149] = 100
                        features[317] = target_status
                        features[330] = target_speed
                        self.assertIs(
                            shape_redundant_action_priors(
                                policy, features, 0b1111, 1.0
                            ),
                            policy,
                        )
                        for mask in (0b1111, 0b10101, 0b0110):
                            shaped = shape_redundant_action_priors(
                                policy, features, mask, 0.25
                            )
                            expected = list(policy)
                            for action in range(4):
                                if (
                                    mask & (1 << action)
                                    and classify_feature_decision(
                                        features, action
                                    ).statically_redundant
                                ):
                                    expected[action] *= 0.25
                            legal = [
                                action
                                for action in range(len(policy))
                                if mask & (1 << action)
                            ]
                            total = sum(expected[action] for action in legal)
                            for action in legal:
                                expected[action] /= total
                            self.assertEqual(shaped, expected)

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
        config = SimpleNamespace(
            selfplay_episodes=100,
            adaptive_fn_pool_window=1,
            router_fn_exposure_floor=0.0,
        )
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
        self.assertEqual(report["version"], "completion-and-router-integrity-v3")
        self.assertTrue(report["pass"])
        self.assertEqual(report["reasons"], [])
        self.assertNotIn("pooled_router", report)

    def test_collection_quality_gates_witnessed_router_false_negatives(self) -> None:
        config = SimpleNamespace(
            selfplay_episodes=100,
            adaptive_max_false_negative_rate=0.10,
            adaptive_fn_pool_window=1,
            router_fn_exposure_floor=0.0,
        )
        report = _collection_quality(
            {
                "truncated": 0,
                "semantic_divergences": 0,
                "mean_decisions": 20.0,
                "finished": 100,
                "forced_router_samples": 200,
                "forced_router_false_negative_rate": 0.11,
            },
            config,
        )
        self.assertFalse(report["pass"])
        self.assertIn(
            "adaptive-router-false-negative-rate-above-limit", report["reasons"]
        )

    def _router_iteration(
        self, samples: int, false_negatives: int
    ) -> dict[str, object]:
        return {
            "truncated": 0,
            "semantic_divergences": 0,
            "mean_decisions": 20.0,
            "finished": 100,
            "forced_router_samples": samples,
            "forced_router_false_negatives": false_negatives,
            "forced_router_false_negative_rate": false_negatives / max(1, samples),
        }

    def test_pooled_router_false_negatives_gate_across_iterations(self) -> None:
        config = SimpleNamespace(
            selfplay_episodes=100,
            adaptive_max_false_negative_rate=0.10,
            adaptive_fn_pool_window=3,
            router_fn_exposure_floor=0.0,
        )
        history = [self._router_iteration(60, 12), self._router_iteration(60, 12)]
        report = _collection_quality(self._router_iteration(60, 12), config, history)
        self.assertEqual(report["version"], "completion-and-pooled-router-integrity-v4")
        self.assertFalse(report["pass"])
        self.assertEqual(
            report["reasons"],
            ["adaptive-router-pooled-false-negative-rate-above-limit"],
        )
        self.assertEqual(
            report["pooled_router"],
            {
                "window": 3,
                "iterations": 3,
                "samples": 180,
                "false_negatives": 36,
                "rate": 0.2,
            },
        )

    def test_pooled_router_window_uses_only_recent_history(self) -> None:
        config = SimpleNamespace(
            selfplay_episodes=100,
            adaptive_max_false_negative_rate=0.10,
            adaptive_fn_pool_window=2,
            router_fn_exposure_floor=0.0,
        )
        history = [self._router_iteration(400, 200), self._router_iteration(200, 0)]
        report = _collection_quality(self._router_iteration(200, 0), config, history)
        self.assertTrue(report["pass"])
        self.assertEqual(report["pooled_router"]["samples"], 400)
        self.assertEqual(report["pooled_router"]["false_negatives"], 0)

    def test_pooled_router_respects_the_sample_floor(self) -> None:
        config = SimpleNamespace(
            selfplay_episodes=100,
            adaptive_max_false_negative_rate=0.10,
            adaptive_fn_pool_window=3,
            router_fn_exposure_floor=0.0,
        )
        report = _collection_quality(self._router_iteration(20, 10), config, [])
        self.assertTrue(report["pass"])
        self.assertEqual(report["pooled_router"]["samples"], 20)
        self.assertEqual(report["pooled_router"]["iterations"], 1)

    def test_fixed_opponent_schedule_is_exact_and_periodic(self) -> None:
        schedule = [_scheduled_for_opponent(episode, 0.5) for episode in range(1000)]
        self.assertEqual(sum(schedule), 500)
        self.assertEqual(schedule[:6], [False, True, False, True, False, True])

    def test_heuristic_controller_round_trips_through_spawn_pickle(self) -> None:
        controller = _HeuristicNetwork("aggressive")
        loaded = pickle.loads(pickle.dumps(controller))
        self.assertEqual(loaded.style, controller.style)
        self.assertEqual(loaded.config.action_count, 13)
        self.assertTrue(loaded.config.distilled_leaf_evaluator)

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
            "transformer-variable-party-bf16-rmplus-v29-domain-seeded-5m-16k",
        )
        self.assertEqual(
            _pipeline_id(False, 2),
            "transformer-variable-party-bf16-rmplus-v29-domain-seeded-5m-16k",
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

    def test_training_entropy_is_domain_separated_and_episode_unique(self) -> None:
        self.assertEqual(
            _ACTOR_ENTROPY_VERSION, "splitmix64-domain-separated-episode-v2"
        )
        domains = (
            _RESET_DOMAIN,
            _SELECTION_DOMAIN,
            _CHANCE_DOMAIN,
            _OPPONENT_DOMAIN,
            _TIER_DOMAIN,
            _EXPLORATION_DOMAIN,
            _PRIOR_NOISE_DOMAIN,
        )
        seeds = {
            _training_entropy_seed(20260726, iteration, episode, domain)
            for iteration in range(1, 5)
            for episode in range(1024)
            for domain in domains
        }
        self.assertEqual(len(seeds), 4 * 1024 * len(domains))
        reset_coordinates = {
            (
                _training_entropy_seed(20260726, iteration, 0, _RESET_DOMAIN),
                pair,
            )
            for iteration in range(1, 31)
            for pair in range(8192)
        }
        self.assertEqual(len(reset_coordinates), 30 * 8192)
        self.assertEqual(
            _training_entropy_seed(20260726, 1, 0, _SELECTION_DOMAIN),
            10456798846194407138,
        )

    def test_collection_pair_validator_requires_same_reset_and_side_swap(self) -> None:
        common = {
            "pair": 0,
            "reset_seed": 123,
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

    def test_collection_pair_validator_rejects_cross_pair_reset_reuse(self) -> None:
        rows = []
        for pair in range(2):
            for leg, side in enumerate(("player", "enemy")):
                rows.append(
                    {
                        "episode": pair * 2 + leg,
                        "pair": pair,
                        "pair_leg": leg,
                        "reset_seed": 123,
                        "reset_episode": 7,
                        "pair_player_party_size": 2,
                        "pair_enemy_party_size": 5,
                        "teams_swapped": False,
                        "player_party_size": 2,
                        "enemy_party_size": 5,
                        "level_profile": "distributed",
                        "episode_kind": "heuristic-opponent",
                        "opponent": "heuristic-red-trainer-01-youngster-v1",
                        "candidate_side": side,
                        "initial": {"player": "team-a", "enemy": "team-b"},
                    }
                )
        with self.assertRaisesRegex(RuntimeError, "reused another pair"):
            _validate_collection_pairs(rows, 4)

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
            _, _, _, _, masks, _, weights, _, budget_weights = _load_examples([shard])
            self.assertEqual(weights.tolist(), [1.0])
            self.assertEqual(budget_weights.tolist(), [0.0])
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

    def test_adaptive_router_skips_stable_roots_but_retains_rmplus(self) -> None:
        server = _ToyServer()
        network = _AdaptiveToyNetwork()
        config = JointSearchConfig(
            max_depth=2,
            expansion_budget=16,
            minimum_expansion_budget=4,
            adaptive_search=True,
            adaptive_deep_threshold=0.6,
            adaptive_force_deep_fraction=0.0,
            adaptive_exploitability_threshold=1.0,
            adaptive_payoff_spread_threshold=2.0,
        )
        result = SimultaneousTreeSearch(
            server,
            network,
            network,
            config,
            random.Random(1),
            random.Random(2),
        ).search(server._snapshot(0), sample_actions=False)
        self.assertEqual(result.nodes, 4)
        self.assertEqual(
            result.solver, "simultaneous-matrix-tree-rmplus-pooled-node-v3"
        )
        self.assertEqual(result.diagnostics["adaptive_deep_selected"], 0)
        self.assertEqual(result.diagnostics["adaptive_reason"], "router-stable-root")
        self.assertIsNotNone(result.payoff_matrix)

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
                adaptive_budget_head=True,
            )
        ).eval()
        values = network.evaluate_leaf([[0] * 492, [65535] * 492])
        self.assertEqual(len(values), 2)
        self.assertTrue(all(-1.0 <= value <= 1.0 for value in values))
        self.assertEqual(
            sum(parameter.numel() for parameter in network.parameters()), 937949
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

    def test_empty_legal_masks_are_rejected_at_launch(self) -> None:
        torch.manual_seed(7)
        network = BattleTransformer(
            TransformerConfig(d_model=32, heads=4, layers=1, feedforward=64)
        ).eval()
        features = [[0] * 100, [1] * 100]
        with self.assertRaisesRegex(ValueError, "empty legal mask"):
            network.evaluate(features, [0b0101, 0])
        joint = BattleTransformer(
            TransformerConfig(
                d_model=32,
                heads=4,
                layers=1,
                feedforward=64,
                joint_policy_heads=True,
            )
        ).eval()
        with self.assertRaisesRegex(ValueError, "empty legal mask"):
            joint.evaluate_joint(features, [0, 0b1010], [0b0101, 0b0101])
        with self.assertRaisesRegex(ValueError, "empty legal mask"):
            joint.evaluate_joint(features, [0b0101, 0b1010], [0b0101, 0])

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


class ShadowOpponentPoolTest(unittest.TestCase):
    def test_assemble_population_zero_window_matches_legacy(self) -> None:
        opponents = [("heuristic-model", "heuristic-aggressive-v1")]
        incumbent = ("incumbent-model", "sha-004")
        initial = ("initial-model", "sha-000")
        historical = [("model-1", "sha-001"), ("model-4", "sha-004")]
        shadows = [("shadow-4", "sha-004"), ("shadow-5", "sha-005")]
        population = _assemble_population(
            opponents,
            incumbent,
            initial,
            historical,
            shadows,
            historical_window=4,
            shadow_window=0,
        )
        legacy = list(opponents) + [incumbent, initial]
        legacy.extend(historical[:-1][-4:])
        legacy = list(
            {identity: (model, identity) for model, identity in legacy}.values()
        )
        self.assertEqual(population, legacy)
        self.assertNotIn("sha-005", [identity for _, identity in population])

    def test_assemble_population_skips_initial_when_it_is_the_incumbent(self) -> None:
        population = _assemble_population(
            [],
            ("model", "sha-000"),
            ("model", "sha-000"),
            [],
            [],
            historical_window=4,
            shadow_window=0,
        )
        self.assertEqual(population, [("model", "sha-000")])

    def test_assemble_population_admits_recent_shadows_deduplicated(self) -> None:
        # Accepts {1, 4}, rejects {2, 3, 5}: the accepted lineage carries
        # iterations 1 and 4, the shadow window carries 4 and 5, and the
        # accepted iteration 4 appears exactly once after deduplication.
        opponents = [("heuristic-model", "heuristic-aggressive-v1")]
        incumbent = ("incumbent-model", "sha-004")
        initial = ("initial-model", "sha-000")
        historical = [("model-1", "sha-001"), ("model-4", "sha-004")]
        shadows = [("shadow-4", "sha-004"), ("shadow-5", "sha-005")]
        population = _assemble_population(
            opponents,
            incumbent,
            initial,
            historical,
            shadows,
            historical_window=4,
            shadow_window=2,
        )
        self.assertEqual(
            [identity for _, identity in population],
            ["heuristic-aggressive-v1", "sha-004", "sha-000", "sha-001", "sha-005"],
        )

    def test_assemble_population_shadow_window_bounds_the_extension(self) -> None:
        shadows = [(f"shadow-{index}", f"sha-{index:03d}") for index in range(1, 6)]
        population = _assemble_population(
            [],
            ("incumbent-model", "sha-incumbent"),
            ("initial-model", "sha-000"),
            [],
            shadows,
            historical_window=0,
            shadow_window=2,
        )
        self.assertEqual(
            [identity for _, identity in population],
            ["sha-incumbent", "sha-000", "sha-004", "sha-005"],
        )

    def test_append_shadow_opponent_trims_to_window(self) -> None:
        pool: list[tuple[str, str]] = []
        for index in range(4):
            _append_shadow_opponent(pool, (f"model-{index}", f"sha-{index}"), 2)
        self.assertEqual(pool, [("model-2", "sha-2"), ("model-3", "sha-3")])
        untouched: list[tuple[str, str]] = []
        _append_shadow_opponent(untouched, ("model", "sha"), 0)
        self.assertEqual(untouched, [])

    def test_shadow_seed_iterations_cover_the_completed_suffix(self) -> None:
        self.assertEqual(_shadow_seed_iterations(0, 6), [])
        self.assertEqual(_shadow_seed_iterations(5, 0), [])
        self.assertEqual(_shadow_seed_iterations(5, 2), [4, 5])
        self.assertEqual(_shadow_seed_iterations(3, 6), [1, 2, 3])

    def test_shadow_opponent_window_flows_from_the_cli(self) -> None:
        arguments = training_parser().parse_args(
            [
                "transformer-train",
                "--output",
                "/tmp/shadow-pool",
                "--shadow-opponent-window",
                "6",
            ]
        )
        self.assertEqual(arguments.shadow_opponent_window, 6)


class ExposureAwareRouterGateTest(unittest.TestCase):
    def _entry(
        self,
        samples: int,
        false_negatives: int,
        root_only: int = 0,
        deep: int = 0,
    ) -> dict[str, object]:
        return {
            "truncated": 0,
            "semantic_divergences": 0,
            "mean_decisions": 20.0,
            "finished": 100,
            "forced_router_samples": samples,
            "forced_router_false_negatives": false_negatives,
            "forced_router_false_negative_rate": false_negatives / max(1, samples),
            "root_only_decisions": root_only,
            "deep_search_decisions": deep,
        }

    def _config(self, window: int, floor: float) -> SimpleNamespace:
        return SimpleNamespace(
            selfplay_episodes=100,
            adaptive_max_false_negative_rate=0.10,
            adaptive_fn_pool_window=window,
            router_fn_exposure_floor=floor,
        )

    def test_pooled_root_only_share_pools_decision_counts(self) -> None:
        entries = [
            {"root_only_decisions": 1, "deep_search_decisions": 399},
            {"root_only_decisions": 3, "deep_search_decisions": 397},
        ]
        self.assertAlmostEqual(_pooled_root_only_share(entries), 4 / 800)
        self.assertEqual(_pooled_root_only_share([{}]), 0.0)

    def test_low_exposure_downgrades_the_pooled_breach(self) -> None:
        history = [self._entry(60, 12, 1, 399), self._entry(60, 12, 2, 398)]
        report = _collection_quality(
            self._entry(60, 12, 1, 399), self._config(3, 0.02), history
        )
        self.assertTrue(report["pass"])
        self.assertEqual(
            report["reasons"],
            ["adaptive-router-pooled-false-negative-rate-above-limit"],
        )
        self.assertEqual(
            report["version"], "completion-and-exposure-aware-router-integrity-v5"
        )
        self.assertEqual(report["router_exposure"]["floor"], 0.02)
        self.assertAlmostEqual(report["router_exposure"]["share"], 4 / 1200)
        self.assertEqual(report["pooled_router"]["samples"], 180)

    def test_high_exposure_keeps_the_pooled_gate_blocking(self) -> None:
        history = [self._entry(60, 12, 30, 370), self._entry(60, 12, 30, 370)]
        report = _collection_quality(
            self._entry(60, 12, 30, 370), self._config(3, 0.02), history
        )
        self.assertFalse(report["pass"])
        self.assertEqual(
            report["reasons"],
            ["adaptive-router-pooled-false-negative-rate-above-limit"],
        )
        self.assertEqual(
            report["version"], "completion-and-exposure-aware-router-integrity-v5"
        )
        self.assertAlmostEqual(report["router_exposure"]["share"], 90 / 1200)

    def test_zero_floor_preserves_the_legacy_gate(self) -> None:
        history = [self._entry(60, 12), self._entry(60, 12)]
        report = _collection_quality(self._entry(60, 12), self._config(3, 0.0), history)
        self.assertFalse(report["pass"])
        self.assertEqual(report["version"], "completion-and-pooled-router-integrity-v4")
        self.assertNotIn("router_exposure", report)

    def test_low_exposure_downgrades_the_witnessed_breach(self) -> None:
        entry = self._entry(200, 30, 1, 399)
        report = _collection_quality(entry, self._config(1, 0.02))
        self.assertTrue(report["pass"])
        self.assertEqual(
            report["reasons"], ["adaptive-router-false-negative-rate-above-limit"]
        )
        self.assertEqual(
            report["version"], "completion-and-exposure-aware-router-integrity-v5"
        )
        self.assertNotIn("pooled_router", report)

    def test_completion_breaches_still_block_at_low_exposure(self) -> None:
        entry = self._entry(60, 12, 1, 399)
        entry["truncated"] = 5
        history = [self._entry(60, 12, 1, 399), self._entry(60, 12, 2, 398)]
        report = _collection_quality(entry, self._config(3, 0.02), history)
        self.assertFalse(report["pass"])
        self.assertEqual(
            report["reasons"],
            [
                "horizon-truncation-rate-above-1pct",
                "adaptive-router-pooled-false-negative-rate-above-limit",
            ],
        )

    def test_router_fn_exposure_floor_flows_from_the_cli(self) -> None:
        arguments = training_parser().parse_args(
            [
                "transformer-train",
                "--output",
                "/tmp/exposure-floor",
                "--router-fn-exposure-floor",
                "0.02",
            ]
        )
        self.assertEqual(arguments.router_fn_exposure_floor, 0.02)


class _ExplodingRng:
    def __init__(self, complaint: str) -> None:
        self.complaint = complaint

    def random(self) -> float:
        raise AssertionError(self.complaint)

    def choice(self, sequence: list[int]) -> int:
        raise AssertionError(self.complaint)


class CollectionEpsilonTest(unittest.TestCase):
    def _result(self, player_action: int = 2, enemy_action: int = 0) -> SearchResult:
        return SearchResult(
            player_policy=(0.25, 0.25, 0.5),
            enemy_policy=(1.0, 0.0, 0.0),
            player_action=player_action,
            enemy_action=enemy_action,
            root_value=0.125,
            nodes=1,
            solver="test",
            exploitability=None,
            payoff_spread=None,
            payoff_matrix=((0.0,),),
        )

    def _actor(
        self,
        kind: str,
        candidate_player: bool,
        rng: object,
        player_mask: int = 0b111,
        enemy_mask: int = 0b111,
    ) -> SimpleNamespace:
        return SimpleNamespace(
            snapshot=SimpleNamespace(player_mask=player_mask, enemy_mask=enemy_mask),
            episode_kind=kind,
            candidate_player=candidate_player,
            exploration_rng=rng,
        )

    def _config(self, epsilon: float, turns: int = 0) -> SimpleNamespace:
        return SimpleNamespace(
            collection_epsilon=epsilon, collection_epsilon_turns=turns
        )

    def test_zero_epsilon_returns_the_same_result_without_rng(self) -> None:
        result = self._result()
        actor = self._actor(
            "mirror", True, _ExplodingRng("rng consumed with epsilon disabled")
        )
        explored = _explore_search_result(result, actor, self._config(0.0), 0)
        self.assertIs(explored, result)

    def test_full_epsilon_redraws_uniformly_over_legal_actions(self) -> None:
        rng = random.Random(2026)
        config = self._config(1.0)
        counts = {0: 0, 1: 0, 2: 0}
        rounds = 3000
        for _ in range(rounds):
            actor = self._actor("mirror", True, rng)
            explored = _explore_search_result(self._result(), actor, config, 0)
            counts[explored.player_action] += 1
        for count in counts.values():
            self.assertAlmostEqual(count / rounds, 1 / 3, delta=0.04)

    def test_intermediate_epsilon_mixes_at_the_configured_rate(self) -> None:
        rng = random.Random(17)
        config = self._config(0.25)
        redrawn = 0
        rounds = 4000
        for _ in range(rounds):
            actor = self._actor("checkpoint-opponent", True, rng)
            explored = _explore_search_result(self._result(), actor, config, 0)
            redrawn += explored.player_action != 2
        self.assertAlmostEqual(redrawn / rounds, 0.25 * 2 / 3, delta=0.02)

    def test_targets_survive_exploration_untouched(self) -> None:
        rng = random.Random(7)
        result = self._result()
        actor = self._actor("mirror", True, rng)
        explored = _explore_search_result(result, actor, self._config(1.0), 0)
        self.assertEqual(explored.player_policy, result.player_policy)
        self.assertEqual(explored.enemy_policy, result.enemy_policy)
        self.assertEqual(explored.root_value, result.root_value)
        self.assertEqual(explored.payoff_matrix, result.payoff_matrix)

    def test_only_the_candidate_side_explores_against_opponents(self) -> None:
        rng = random.Random(11)
        config = self._config(1.0)
        for _ in range(50):
            explored = _explore_search_result(
                self._result(), self._actor("checkpoint-opponent", True, rng), config, 0
            )
            self.assertEqual(explored.enemy_action, 0)
        for _ in range(50):
            explored = _explore_search_result(
                self._result(),
                self._actor("heuristic-opponent", False, rng),
                config,
                0,
            )
            self.assertEqual(explored.player_action, 2)

    def test_epsilon_turns_caps_exploration_to_early_decisions(self) -> None:
        config = self._config(1.0, turns=3)
        actor = self._actor(
            "mirror", True, random.Random(13), player_mask=0b10, enemy_mask=0b10
        )
        for decision in range(3):
            explored = _explore_search_result(
                self._result(0, 0), actor, config, decision
            )
            self.assertEqual((explored.player_action, explored.enemy_action), (1, 1))
        actor.exploration_rng = _ExplodingRng("rng consumed past the epsilon turn cap")
        for decision in (3, 4, 100):
            result = self._result(0, 0)
            self.assertIs(
                _explore_search_result(result, actor, config, decision), result
            )

    def test_uniform_legal_action_only_draws_set_bits(self) -> None:
        rng = random.Random(3)
        draws = {_uniform_legal_action(0b101001, rng) for _ in range(200)}
        self.assertEqual(draws, {0, 3, 5})

    def test_meta_tags_appear_only_when_enabled(self) -> None:
        self.assertEqual(_epsilon_meta(self._config(0.0)), {})
        self.assertEqual(
            _epsilon_meta(self._config(0.1, turns=12)),
            {
                "action_exploration": "epsilon-uniform-executed-v1",
                "collection_epsilon": 0.1,
                "collection_epsilon_turns": 12,
            },
        )

    def test_eval_paths_never_reference_epsilon(self) -> None:
        source = inspect.getsource(_play_game) + inspect.getsource(_arena)
        self.assertNotIn("collection_epsilon", source)
        self.assertNotIn("_explore_search_result", source)

    def test_collection_epsilon_flows_from_the_cli(self) -> None:
        arguments = training_parser().parse_args(
            [
                "transformer-train",
                "--output",
                "/tmp/epsilon",
                "--collection-epsilon",
                "0.05",
                "--collection-epsilon-turns",
                "12",
            ]
        )
        self.assertEqual(arguments.collection_epsilon, 0.05)
        self.assertEqual(arguments.collection_epsilon_turns, 12)


class PolicyTargetSmoothingTest(unittest.TestCase):
    def test_zero_smoothing_returns_the_same_list(self) -> None:
        policy = [0.75, 0.25, 0.0, 0.0]
        self.assertIs(_smoothed_policy(policy, 0b0011, 0.0), policy)

    def test_mixture_math_is_exact_over_the_legal_support(self) -> None:
        smoothed = _smoothed_policy([0.9, 0.1, 0.0, 0.0], 0b0011, 0.05)
        self.assertAlmostEqual(smoothed[0], 0.95 * 0.9 + 0.025)
        self.assertAlmostEqual(smoothed[1], 0.95 * 0.1 + 0.025)
        self.assertEqual(smoothed[2:], [0.0, 0.0])
        self.assertAlmostEqual(sum(smoothed), 1.0)

    def test_illegal_actions_keep_exactly_zero_mass(self) -> None:
        smoothed = _smoothed_policy([0.5, 0.0, 0.5, 0.0, 0.0], 0b00101, 0.2)
        self.assertEqual(smoothed[1], 0.0)
        self.assertEqual(smoothed[3], 0.0)
        self.assertEqual(smoothed[4], 0.0)
        self.assertAlmostEqual(sum(smoothed), 1.0)

    def test_near_one_hot_targets_gain_the_computed_entropy_floor(self) -> None:
        one_hot = [1.0, 0.0, 0.0, 0.0]
        self.assertEqual(_policy_entropy(one_hot), 0.0)
        smoothed = _smoothed_policy(one_hot, 0b1111, 0.04)
        expected = [0.96 + 0.01, 0.01, 0.01, 0.01]
        for actual, want in zip(smoothed, expected, strict=True):
            self.assertAlmostEqual(actual, want)
        self.assertAlmostEqual(
            _policy_entropy(smoothed),
            -(0.97 * math.log(0.97) + 3 * 0.01 * math.log(0.01)),
        )

    def test_policy_target_smoothing_flows_from_the_cli(self) -> None:
        arguments = training_parser().parse_args(
            [
                "transformer-train",
                "--output",
                "/tmp/smoothing",
                "--policy-target-smoothing",
                "0.05",
            ]
        )
        self.assertEqual(arguments.policy_target_smoothing, 0.05)


class DirichletRootNoiseTest(unittest.TestCase):
    _PRIORS = (0.3, 0.05, 0.05, 0.25, 0.1, 0.25)
    _MASK = 0b101001  # legal support {0, 3, 5}

    def _noise(
        self,
        alpha: float = 0.6,
        weight: float = 0.25,
        seed: int = 7,
        total: float = 0.0,
    ) -> RootPriorNoise:
        return RootPriorNoise(
            alpha=alpha, weight=weight, rng=random.Random(seed), total=total
        )

    def _search(self, **kwargs: object) -> SimultaneousTreeSearch:
        network = SimpleNamespace(config=SimpleNamespace(action_count=3))
        return SimultaneousTreeSearch(
            object(),
            network,
            network,
            JointSearchConfig(),
            random.Random(0),
            random.Random(1),
            **kwargs,
        )

    def test_noise_touches_only_the_legal_support(self) -> None:
        noised = _dirichlet_noised_priors(self._PRIORS, self._MASK, self._noise())
        for illegal in (1, 2, 4):
            self.assertEqual(noised[illegal], self._PRIORS[illegal])
        self.assertNotEqual(
            [noised[action] for action in (0, 3, 5)],
            [self._PRIORS[action] for action in (0, 3, 5)],
        )

    def test_noise_preserves_legal_and_total_prior_mass(self) -> None:
        noised = _dirichlet_noised_priors(self._PRIORS, self._MASK, self._noise())
        self.assertAlmostEqual(sum(noised), sum(self._PRIORS), places=12)
        self.assertAlmostEqual(
            sum(noised[action] for action in (0, 3, 5)),
            sum(self._PRIORS[action] for action in (0, 3, 5)),
            places=12,
        )

    def test_mixture_matches_a_manual_gamma_replay(self) -> None:
        noised = _dirichlet_noised_priors(
            self._PRIORS, self._MASK, self._noise(seed=11)
        )
        rng = random.Random(11)
        samples = [rng.gammavariate(0.6, 1.0) for _ in range(3)]
        total = sum(samples)
        legal_mass = sum(self._PRIORS[action] for action in (0, 3, 5))
        for action, sample in zip((0, 3, 5), samples, strict=True):
            expected = 0.75 * self._PRIORS[action] + 0.25 * legal_mass * (
                sample / total
            )
            self.assertAlmostEqual(noised[action], expected, places=12)

    def test_total_concentration_scales_alpha_by_the_legal_count(self) -> None:
        # AlphaZero scales alpha inversely with the legal-move count; a total
        # concentration of 9 over the 3-action legal support is alpha 3.
        scaled = _dirichlet_noised_priors(
            self._PRIORS, self._MASK, self._noise(alpha=0.6, seed=11, total=9.0)
        )
        equivalent = _dirichlet_noised_priors(
            self._PRIORS, self._MASK, self._noise(alpha=3.0, seed=11)
        )
        fixed = _dirichlet_noised_priors(
            self._PRIORS, self._MASK, self._noise(alpha=0.6, seed=11)
        )
        self.assertEqual(scaled, equivalent)
        self.assertNotEqual(scaled, fixed)

    def test_total_defaults_to_zero_preserving_fixed_alpha(self) -> None:
        noise = RootPriorNoise(alpha=0.6, weight=0.25, rng=random.Random(7))
        self.assertEqual(noise.total, 0.0)

    def test_fixed_seed_is_deterministic_and_seed_dependent(self) -> None:
        first = _dirichlet_noised_priors(self._PRIORS, self._MASK, self._noise(seed=5))
        second = _dirichlet_noised_priors(self._PRIORS, self._MASK, self._noise(seed=5))
        other = _dirichlet_noised_priors(self._PRIORS, self._MASK, self._noise(seed=6))
        self.assertEqual(first, second)
        self.assertNotEqual(first, other)

    def test_zero_weight_keeps_prior_values_exactly(self) -> None:
        noised = _dirichlet_noised_priors(
            self._PRIORS, self._MASK, self._noise(weight=0.0)
        )
        self.assertEqual(noised, list(self._PRIORS))

    def test_empty_legal_mask_returns_the_input_untouched(self) -> None:
        priors = [0.5, 0.5]
        noise = RootPriorNoise(
            alpha=0.6,
            weight=0.25,
            rng=_ExplodingRng("rng consumed with no legal actions"),
        )
        self.assertIs(_dirichlet_noised_priors(priors, 0, noise), priors)

    def test_collection_wiring_disables_noise_at_alpha_zero(self) -> None:
        config = SimpleNamespace(
            collection_dirichlet_alpha=0.0,
            collection_dirichlet_weight=0.25,
            collection_dirichlet_total=0.0,
        )
        self.assertIsNone(
            _collection_prior_noise(
                config, _ExplodingRng("rng touched with alpha disabled")
            )
        )

    def test_collection_wiring_builds_noise_from_the_config(self) -> None:
        rng = random.Random(3)
        config = SimpleNamespace(
            collection_dirichlet_alpha=0.6,
            collection_dirichlet_weight=0.3,
            collection_dirichlet_total=0.0,
        )
        noise = _collection_prior_noise(config, rng)
        self.assertEqual((noise.alpha, noise.weight, noise.total), (0.6, 0.3, 0.0))
        self.assertIs(noise.rng, rng)

    def test_collection_wiring_enables_noise_via_total_alone(self) -> None:
        rng = random.Random(3)
        config = SimpleNamespace(
            collection_dirichlet_alpha=0.0,
            collection_dirichlet_weight=0.25,
            collection_dirichlet_total=10.0,
        )
        noise = _collection_prior_noise(config, rng)
        self.assertIsNotNone(noise)
        self.assertEqual(noise.total, 10.0)

    def test_search_defaults_to_no_prior_noise(self) -> None:
        self.assertIsNone(self._search().prior_noise)

    def test_search_stores_an_explicit_prior_noise(self) -> None:
        noise = self._noise()
        self.assertIs(self._search(prior_noise=noise).prior_noise, noise)

    def test_promotion_paths_never_reference_dirichlet_noise(self) -> None:
        source = inspect.getsource(_play_game) + inspect.getsource(_arena)
        self.assertNotIn("prior_noise", source)
        self.assertNotIn("dirichlet", source.lower())
        default = inspect.signature(_new_search).parameters["prior_noise"].default
        self.assertIsNone(default)

    def test_meta_tags_appear_only_when_enabled(self) -> None:
        disabled = SimpleNamespace(
            collection_dirichlet_alpha=0.0,
            collection_dirichlet_weight=0.25,
            collection_dirichlet_total=0.0,
        )
        self.assertEqual(_dirichlet_meta(disabled), {})
        enabled = SimpleNamespace(
            collection_dirichlet_alpha=0.6,
            collection_dirichlet_weight=0.3,
            collection_dirichlet_total=0.0,
        )
        self.assertEqual(
            _dirichlet_meta(enabled),
            {
                "root_prior_noise": "dirichlet-legal-support-v1",
                "collection_dirichlet_alpha": 0.6,
                "collection_dirichlet_weight": 0.3,
                "collection_dirichlet_total": 0.0,
            },
        )
        scaled = SimpleNamespace(
            collection_dirichlet_alpha=0.6,
            collection_dirichlet_weight=0.25,
            collection_dirichlet_total=10.0,
        )
        self.assertEqual(
            _dirichlet_meta(scaled),
            {
                "root_prior_noise": "dirichlet-legal-scaled-v2",
                "collection_dirichlet_alpha": 0.6,
                "collection_dirichlet_weight": 0.25,
                "collection_dirichlet_total": 10.0,
            },
        )

    def test_collection_dirichlet_flows_from_the_cli(self) -> None:
        arguments = training_parser().parse_args(
            [
                "transformer-train",
                "--output",
                "/tmp/dirichlet",
                "--collection-dirichlet-alpha",
                "0.6",
                "--collection-dirichlet-weight",
                "0.3",
                "--collection-dirichlet-total",
                "6.5",
            ]
        )
        self.assertEqual(arguments.collection_dirichlet_alpha, 0.6)
        self.assertEqual(arguments.collection_dirichlet_weight, 0.3)
        self.assertEqual(arguments.collection_dirichlet_total, 6.5)


class FrontierBufferTest(unittest.TestCase):
    @staticmethod
    def _entry(score: float, tag: str) -> dict[str, float | str]:
        return {"score": score, "tag": tag}

    @staticmethod
    def _snapshot() -> Snapshot:
        return Snapshot(
            handle=7,
            player_features=np.asarray([1, 2, 3], dtype=np.int64),
            enemy_features=np.asarray([4, 5], dtype=np.int64),
            player_mask=0b101,
            enemy_mask=0b011,
            player_hash="abc",
            enemy_hash="def",
            turn=9,
            terminal=False,
            done=False,
            terminal_return=None,
            request="move",
            divergence=None,
        )

    def test_zero_capacity_buffer_stores_nothing(self) -> None:
        buffer = _FrontierBuffer(0)
        self.assertFalse(buffer.capacity)
        buffer.consider(self._entry(5.0, "a"))
        self.assertEqual(buffer.entries(), [])

    def test_buffer_keeps_the_top_scores(self) -> None:
        buffer = _FrontierBuffer(3)
        for score in [1.0, 5.0, 3.0, 4.0, 2.0]:
            buffer.consider(self._entry(score, str(score)))
        self.assertEqual(
            [entry["score"] for entry in buffer.entries()], [5.0, 4.0, 3.0]
        )

    def test_tied_scores_keep_the_earliest_entry(self) -> None:
        buffer = _FrontierBuffer(2)
        for tag in ["first", "second", "third"]:
            buffer.consider(self._entry(1.0, tag))
        self.assertEqual(
            [entry["tag"] for entry in buffer.entries()], ["first", "second"]
        )

    def test_buffer_is_bounded_at_capacity(self) -> None:
        buffer = _FrontierBuffer(4)
        for index in range(50):
            buffer.consider(self._entry(float(index % 7), str(index)))
        entries = buffer.entries()
        self.assertEqual([entry["score"] for entry in entries], [6.0] * 4)
        self.assertEqual([entry["tag"] for entry in entries], ["6", "13", "20", "27"])

    def test_policy_kl_matches_manual_computation(self) -> None:
        kl = _policy_kl([0.5, 0.25, 0.25, 0.7], [0.25, 0.5, 0.25, 0.9], 0b0111)
        self.assertAlmostEqual(kl, 0.25 * math.log(2.0), places=12)

    def test_policy_kl_is_zero_for_identical_distributions(self) -> None:
        policy = [0.4, 0.6, 0.0]
        self.assertEqual(_policy_kl(policy, policy, 0b011), 0.0)

    def test_policy_kl_floors_a_zero_prior(self) -> None:
        kl = _policy_kl([1.0, 0.0], [0.0, 1.0], 0b11)
        self.assertAlmostEqual(kl, math.log(1e9), places=6)

    def test_frontier_score_combines_surprise_and_kl(self) -> None:
        row = {
            "search_value": 0.6,
            "value": -1,
            "policy": [0.5, 0.25, 0.25, 0.7],
            "legal_mask": 0b0111,
        }
        components = _frontier_score(row, [0.25, 0.5, 0.25, 0.9])
        kl = 0.25 * math.log(2.0)
        self.assertAlmostEqual(components["value_surprise"], 1.6, places=12)
        self.assertAlmostEqual(components["policy_kl"], kl, places=12)
        self.assertAlmostEqual(components["score"], 1.6 + kl, places=12)

    def test_snapshot_round_trips_through_json(self) -> None:
        snapshot = self._snapshot()
        serialized = _serialized_snapshot(snapshot)
        self.assertNotIn("handle", serialized)
        restored = _snapshot_from_serialized(json.loads(json.dumps(serialized)))
        self.assertEqual(restored.handle, -1)
        np.testing.assert_array_equal(restored.player_features, [1, 2, 3])
        np.testing.assert_array_equal(restored.enemy_features, [4, 5])
        self.assertEqual(restored.player_features.dtype, np.int64)
        self.assertFalse(restored.player_features.flags.writeable)
        self.assertFalse(restored.enemy_features.flags.writeable)
        for name in (
            "player_mask",
            "enemy_mask",
            "player_hash",
            "enemy_hash",
            "turn",
            "terminal",
            "done",
            "terminal_return",
            "request",
            "divergence",
        ):
            self.assertEqual(getattr(restored, name), getattr(snapshot, name))

    def test_frontier_entry_assembles_recipe_actions_and_snapshot(self) -> None:
        actor = SimpleNamespace(
            episode=5,
            pair=2,
            pair_leg=1,
            reset_seed=_training_entropy_seed(97, 3, 0, _RESET_DOMAIN),
            reset_episode=2,
            pair_player_size=3,
            pair_enemy_size=2,
            level100=True,
            teams_swapped=True,
            episode_kind="mirror",
            timeline=[
                {"player_action": 0, "enemy_action": 4},
                {"player_action": 6, "enemy_action": 1},
                {"player_action": 2, "enemy_action": 2},
            ],
            frontier_restart=None,
        )
        config = SimpleNamespace(seed=97, balanced_final_species=True)
        row = {
            "decision": 2,
            "side": "player",
            "target_kind": "search",
            "search_value": 0.25,
            "value": -1,
        }
        components = {"score": 1.5, "value_surprise": 1.25, "policy_kl": 0.25}
        snapshot = self._snapshot()
        entry = _frontier_entry(config, 3, actor, row, components, snapshot)
        self.assertEqual(entry["type"], "frontier")
        self.assertEqual(entry["iteration"], 3)
        self.assertEqual(entry["episode"], 5)
        self.assertEqual(entry["pair"], 2)
        self.assertEqual(entry["pair_leg"], 1)
        self.assertEqual(entry["episode_kind"], "mirror")
        self.assertEqual(entry["side"], "player")
        self.assertEqual(entry["decision"], 2)
        self.assertEqual(entry["target_kind"], "search")
        self.assertEqual(entry["search_value"], 0.25)
        self.assertEqual(entry["value"], -1)
        self.assertEqual(entry["score"], 1.5)
        self.assertEqual(entry["value_surprise"], 1.25)
        self.assertEqual(entry["policy_kl"], 0.25)
        self.assertEqual(
            entry["reset"],
            {
                "seed": _training_entropy_seed(97, 3, 0, _RESET_DOMAIN),
                "episode": 2,
                "player_size": 3,
                "enemy_size": 2,
                "level100": True,
                "swapped": True,
                "balanced_final_species": True,
            },
        )
        self.assertEqual(entry["actions"], [[0, 4], [6, 1]])
        self.assertEqual(entry["snapshot"], _serialized_snapshot(snapshot))
        json.dumps(entry)

    def test_finalize_frontier_writes_the_buffer_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "iteration-004.jsonl"
            config = SimpleNamespace(frontier_buffer_size=2)
            entries = [
                {"type": "frontier", "score": 2.0, "tag": "hi"},
                {"type": "frontier", "score": 1.0, "tag": "lo"},
            ]
            metrics = _finalize_frontier(
                {"episodes": 8, "frontier": entries}, path, 4, config
            )
            self.assertEqual(metrics["episodes"], 8)
            self.assertEqual(
                metrics["frontier"],
                {
                    "version": "surprise-topn-v1",
                    "capacity": 2,
                    "entries": 2,
                    "path": "frontier-004.jsonl",
                    "max_score": 2.0,
                    "min_score": 1.0,
                },
            )
            frontier_path = path.with_name("frontier-004.jsonl")
            lines = frontier_path.read_text().splitlines()
            self.assertEqual(len(lines), 3)
            header = json.loads(lines[0])
            self.assertEqual(header["type"], "frontier-meta")
            self.assertEqual(header["version"], "surprise-topn-v1")
            self.assertEqual(header["iteration"], 4)
            self.assertEqual(header["capacity"], 2)
            self.assertEqual(header["entries"], 2)
            self.assertEqual(_load_frontier_buffer(frontier_path), entries)

    def test_finalize_frontier_without_entries_touches_nothing(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "iteration-007.jsonl"
            config = SimpleNamespace(frontier_buffer_size=0)
            metrics = _finalize_frontier({"episodes": 3}, path, 7, config)
            self.assertEqual(metrics, {"episodes": 3})
            self.assertEqual(list(Path(tmp).iterdir()), [])

    def test_finalize_frontier_records_an_empty_enabled_buffer(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "iteration-002.jsonl"
            config = SimpleNamespace(frontier_buffer_size=2)
            metrics = _finalize_frontier({"frontier": []}, path, 2, config)
            self.assertEqual(metrics["frontier"]["entries"], 0)
            self.assertIsNone(metrics["frontier"]["max_score"])
            self.assertIsNone(metrics["frontier"]["min_score"])
            frontier_path = path.with_name("frontier-002.jsonl")
            self.assertEqual(_load_frontier_buffer(frontier_path), [])

    def test_merged_frontier_reselects_across_workers(self) -> None:
        worker_a = [self._entry(3.0, "a3"), self._entry(1.0, "a1")]
        worker_b = [self._entry(4.0, "b4"), self._entry(2.0, "b2")]
        merged = _merged_frontier([worker_a, worker_b], 3)
        self.assertEqual([entry["tag"] for entry in merged], ["b4", "a3", "b2"])

    def test_frontier_meta_tags_appear_only_when_enabled(self) -> None:
        self.assertEqual(_frontier_meta(SimpleNamespace(frontier_buffer_size=0)), {})
        self.assertEqual(
            _frontier_meta(SimpleNamespace(frontier_buffer_size=128)),
            {"frontier_buffer": "surprise-topn-v1", "frontier_buffer_size": 128},
        )

    def test_load_frontier_buffer_rejects_unknown_versions(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "frontier-001.jsonl"
            path.write_text(
                json.dumps({"type": "frontier-meta", "version": "other-v9"}) + "\n"
            )
            with self.assertRaises(ValueError):
                _load_frontier_buffer(path)

    def test_promotion_paths_never_reference_the_frontier(self) -> None:
        source = inspect.getsource(_play_game) + inspect.getsource(_arena)
        self.assertNotIn("frontier", source.lower())

    def test_frontier_buffer_size_flows_from_the_cli(self) -> None:
        arguments = training_parser().parse_args(
            [
                "transformer-train",
                "--output",
                "/tmp/frontier",
                "--frontier-buffer-size",
                "128",
            ]
        )
        self.assertEqual(arguments.frontier_buffer_size, 128)


class FrontierRestartTest(unittest.TestCase):
    @staticmethod
    def _snapshot(handle: int, player_hash: str, enemy_hash: str) -> Snapshot:
        return Snapshot(
            handle=handle,
            player_features=np.asarray([1, 2], dtype=np.int64),
            enemy_features=np.asarray([3, 4], dtype=np.int64),
            player_mask=0b101,
            enemy_mask=0b011,
            player_hash=player_hash,
            enemy_hash=enemy_hash,
            turn=3,
            terminal=False,
            done=False,
            terminal_return=None,
            request="move",
            divergence=None,
        )

    @staticmethod
    def _config(**overrides: float) -> SimpleNamespace:
        values: dict[str, float] = {
            "seed": 11,
            "selfplay_episodes": 4096,
            "frontier_restart_fraction": 0.25,
        }
        values.update(overrides)
        return SimpleNamespace(**values)

    def test_restart_plan_is_empty_when_disabled_or_starved(self) -> None:
        disabled = self._config(frontier_restart_fraction=0.0)
        self.assertEqual(_frontier_restart_plan(disabled, 3, 64), {})
        self.assertEqual(_frontier_restart_plan(self._config(), 3, 0), {})

    def test_restart_plan_rounds_odd_budgets_down_to_whole_pairs(self) -> None:
        config = self._config(selfplay_episodes=10, frontier_restart_fraction=0.1)
        self.assertEqual(_frontier_restart_plan(config, 1, 4), {})

    def test_restart_plan_selects_the_configured_fraction_of_pairs(self) -> None:
        plan = _frontier_restart_plan(self._config(), 3, 64)
        self.assertEqual(len(plan), 512)
        self.assertTrue(all(0 <= pair < 2048 for pair in plan))
        self.assertTrue(all(0 <= index < 64 for index in plan.values()))
        self.assertEqual(plan, _frontier_restart_plan(self._config(), 3, 64))

    def test_restart_plan_replays_the_documented_rng_stream(self) -> None:
        config = self._config(selfplay_episodes=8)
        rng = random.Random(_training_entropy_seed(11, 2, 0, _FRONTIER_PLAN_DOMAIN))
        selected = sorted(rng.sample(range(4), 1))
        expected = {pair: rng.randrange(5) for pair in selected}
        self.assertEqual(_frontier_restart_plan(config, 2, 5), expected)

    def test_restart_entries_fall_back_to_empty_without_a_source(self) -> None:
        self.assertEqual(_frontier_restart_entries(None), [])
        with tempfile.TemporaryDirectory() as tmp:
            missing = Path(tmp) / "frontier-004.jsonl"
            self.assertEqual(_frontier_restart_entries(str(missing)), [])

    def test_restart_entries_load_a_prior_buffer(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "iteration-005.jsonl"
            entries = [
                {"type": "frontier", "score": 2.0, "episode": 9},
                {"type": "frontier", "score": 1.5, "episode": 4},
            ]
            config = SimpleNamespace(frontier_buffer_size=4)
            _finalize_frontier({"frontier": list(entries)}, path, 5, config)
            source = path.with_name("frontier-005.jsonl")
            self.assertEqual(_frontier_restart_entries(str(source)), entries)

    def test_replay_reproduces_the_recorded_state(self) -> None:
        steps: list[tuple[int, int, int]] = []
        scripted = [
            self._snapshot(11, "p1", "e1"),
            self._snapshot(12, "p2", "e2"),
        ]

        def episode_step(handle: int, player: int, enemy: int) -> Snapshot:
            steps.append((handle, player, enemy))
            return scripted[len(steps) - 1]

        server = SimpleNamespace(episode_step=episode_step)
        entry = {
            "actions": [[0, 4], [6, 1]],
            "snapshot": {"player_hash": "p2", "enemy_hash": "e2"},
        }
        final = _replay_frontier_entry(server, self._snapshot(10, "p0", "e0"), entry)
        self.assertEqual(steps, [(10, 0, 4), (11, 6, 1)])
        self.assertEqual(final.handle, 12)

    def test_replay_raises_when_hashes_diverge(self) -> None:
        def episode_step(handle: int, player: int, enemy: int) -> Snapshot:
            return self._snapshot(21, "p1", "e1")

        server = SimpleNamespace(episode_step=episode_step)
        entry = {
            "actions": [[2, 3]],
            "snapshot": {"player_hash": "p1", "enemy_hash": "e-other"},
        }
        with self.assertRaisesRegex(RuntimeError, "frontier replay"):
            _replay_frontier_entry(server, self._snapshot(20, "p0", "e0"), entry)

    def test_pair_validator_accepts_a_replayed_frontier_pair(self) -> None:
        common = {
            "pair": 0,
            "reset_episode": 4,
            "pair_player_party_size": 3,
            "pair_enemy_party_size": 2,
            "teams_swapped": True,
            "player_party_size": 2,
            "enemy_party_size": 3,
            "level_profile": "distributed",
            "episode_kind": "mirror",
            "opponent": "self-play",
            "candidate_side": "both",
            "frontier_restart": True,
            "initial": {"player": "team-b", "enemy": "team-a"},
        }
        rows = [
            {**common, "episode": 0, "pair_leg": 0},
            {**common, "episode": 1, "pair_leg": 1},
        ]
        _validate_collection_pairs(rows, 2)

    def test_pair_validator_rejects_a_diverged_frontier_replay(self) -> None:
        common = {
            "pair": 0,
            "reset_episode": 4,
            "pair_player_party_size": 3,
            "pair_enemy_party_size": 2,
            "teams_swapped": False,
            "player_party_size": 3,
            "enemy_party_size": 2,
            "level_profile": "distributed",
            "episode_kind": "mirror",
            "opponent": "self-play",
            "candidate_side": "both",
            "frontier_restart": True,
            "initial": {"player": "team-a", "enemy": "team-b"},
        }
        rows = [
            {**common, "episode": 0, "pair_leg": 0},
            {**common, "episode": 1, "pair_leg": 1},
        ]
        rows[1] = {**rows[1], "initial": {"player": "team-c", "enemy": "team-b"}}
        with self.assertRaisesRegex(RuntimeError, "did not replay one state"):
            _validate_collection_pairs(rows, 2)
        rows[1] = {**rows[0], "episode": 1, "pair_leg": 1, "teams_swapped": True}
        with self.assertRaisesRegex(RuntimeError, "diverged in team orientation"):
            _validate_collection_pairs(rows, 2)

    def test_pair_validator_rejects_a_split_frontier_restart(self) -> None:
        common = {
            "pair": 0,
            "reset_episode": 4,
            "pair_player_party_size": 3,
            "pair_enemy_party_size": 2,
            "teams_swapped": False,
            "player_party_size": 3,
            "enemy_party_size": 2,
            "level_profile": "distributed",
            "episode_kind": "mirror",
            "opponent": "self-play",
            "candidate_side": "both",
            "initial": {"player": "team-a", "enemy": "team-b"},
        }
        rows = [
            {**common, "episode": 0, "pair_leg": 0, "frontier_restart": True},
            {**common, "episode": 1, "pair_leg": 1},
        ]
        with self.assertRaisesRegex(RuntimeError, "split a frontier restart"):
            _validate_collection_pairs(rows, 2)

    def test_frontier_entry_chains_replayed_provenance(self) -> None:
        source = {
            "reset": {
                "seed": 55,
                "episode": 1,
                "player_size": 4,
                "enemy_size": 4,
                "level100": False,
                "swapped": True,
                "balanced_final_species": True,
            },
            "actions": [[5, 5], [1, 0]],
        }
        actor = SimpleNamespace(
            episode=6,
            pair=3,
            pair_leg=0,
            reset_episode=1,
            pair_player_size=4,
            pair_enemy_size=4,
            level100=False,
            teams_swapped=True,
            episode_kind="mirror",
            timeline=[{"player_action": 2, "enemy_action": 3}],
            frontier_restart=source,
        )
        config = SimpleNamespace(seed=97, balanced_final_species=False)
        row = {
            "side": "player",
            "decision": 1,
            "target_kind": "search",
            "search_value": 0.25,
            "value": 1,
        }
        components = {"score": 0.9, "value_surprise": 0.75, "policy_kl": 0.15}
        entry = _frontier_entry(
            config, 4, actor, row, components, self._snapshot(3, "p", "e")
        )
        self.assertEqual(entry["reset"], source["reset"])
        self.assertEqual(entry["actions"], [[5, 5], [1, 0], [2, 3]])

    def test_restart_meta_tags_appear_only_when_enabled(self) -> None:
        disabled = SimpleNamespace(frontier_restart_fraction=0.0)
        self.assertEqual(_frontier_restart_meta(disabled), {})
        enabled = SimpleNamespace(frontier_restart_fraction=0.25)
        self.assertEqual(
            _frontier_restart_meta(enabled),
            {
                "frontier_restarts": "prior-iteration-replay-v1",
                "frontier_restart_fraction": 0.25,
            },
        )

    def test_collection_worker_defaults_to_no_frontier_source(self) -> None:
        parameters = inspect.signature(_collect_rows_single).parameters
        self.assertIsNone(parameters["frontier_source"].default)

    def test_frontier_restart_fraction_flows_from_the_cli(self) -> None:
        arguments = training_parser().parse_args(
            [
                "transformer-train",
                "--output",
                "/tmp/frontier",
                "--frontier-restart-fraction",
                "0.2",
            ]
        )
        self.assertEqual(arguments.frontier_restart_fraction, 0.2)


if __name__ == "__main__":
    unittest.main()
