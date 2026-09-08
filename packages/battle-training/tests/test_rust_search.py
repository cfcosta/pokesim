"""Behavioral parity of the native scheduler and the frozen Python reference."""

from __future__ import annotations

import random
import unittest
from dataclasses import replace
from unittest.mock import patch

from battle_training.joint_search import (
    JointSearchConfig,
    RootPriorNoise,
    SimultaneousTreeSearch,
)
from battle_training.search_native import RustSimultaneousTreeSearch
from test_pipeline import (
    _ChanceSplitToyServer,
    _DeferredDistilledToyNetwork,
    _DistilledPolicyToyNetwork,
    _DistinctFeatureToyServer,
    _DivergentToyServer,
    _LeafToyNetwork,
    _PotentialLadderToyServer,
    _ThirteenActionToyNetwork,
    _ToyNetwork,
    _ToyServer,
)


class TraceServer(_DistinctFeatureToyServer):
    def __init__(self):
        super().__init__()
        self.requests = []

    def search_steps(self, requests):
        self.requests.append(list(requests))
        return super().search_steps(requests)


class InteriorDivergenceServer(TraceServer):
    def search_steps(self, requests):
        rows = super().search_steps(requests)
        if len(self.requests) == 2 and rows:
            rows[0] = replace(rows[0], divergence="interior-failure")
        return rows


class WideServer(TraceServer):
    def _snapshot(self, handle, done=False, result=None):
        return replace(
            super()._snapshot(handle, done, result),
            player_mask=0b1010101100111,
            enemy_mask=0b1110011001010,
        )


class RustSearchParityTests(unittest.TestCase):
    def compare(
        self,
        configs,
        server_type=TraceServer,
        network_type=_ToyNetwork,
        sampled=True,
        noise=False,
        distinct=False,
        repeat=False,
    ):
        observations = []
        for implementation in (SimultaneousTreeSearch, RustSimultaneousTreeSearch):
            server = server_type()
            shared = network_type()
            searches, snapshots = [], []
            for index, config in enumerate(configs):
                handle = index * 100
                server.states[handle] = (0, 0)
                opponent = network_type() if distinct else shared
                searches.append(
                    implementation(
                        server,
                        shared,
                        opponent,
                        config,
                        random.Random(7 + index),
                        random.Random(11 + index),
                        RootPriorNoise(0.3, 0.25, random.Random(93 + index), total=1.5)
                        if noise
                        else None,
                        evaluation_side="enemy" if index % 2 else "player",
                    )
                )
                snapshots.append(server._snapshot(handle))
            results = implementation.search_many(searches, snapshots, sampled)
            if repeat:
                results += implementation.search_many(searches, snapshots, sampled)
            observations.append(
                (
                    results,
                    getattr(server, "requests", server.batches),
                    [s.chance_rng.getstate() for s in searches],
                    [s.selection_rng.getstate() for s in searches],
                    [
                        s.prior_noise.rng.getstate() if s.prior_noise else None
                        for s in searches
                    ],
                )
            )
        self.assertEqual(observations[0], observations[1])

    def test_depth_width_chance_and_cross_root_order(self):
        for depth in (1, 2, 4):
            for width in (1, 2):
                with self.subTest(depth=depth, width=width):
                    config = JointSearchConfig(
                        max_depth=depth,
                        max_actions_per_side=width,
                        interior_actions_per_side=width,
                        chance_samples_per_joint=3,
                        interior_chance_samples=2,
                        regret_iterations=16,
                    )
                    self.compare([config, replace(config, max_depth=1)], repeat=True)

    def test_root_noise_sampling_and_distinct_opponent_networks(self):
        config = JointSearchConfig(
            max_depth=2,
            regret_iterations=16,
            split_half_reliability=True,
            prior_regret=True,
            chance_samples_per_joint=3,
        )
        self.compare([config, config], sampled=True, noise=True, distinct=True)
        self.compare([config], sampled=False, noise=True)

    def test_split_half_coverage_and_mean_solution(self):
        for count in (1, 2, 3, 4):
            self.compare(
                [
                    JointSearchConfig(
                        regret_iterations=16,
                        chance_samples_per_joint=count,
                        split_half_reliability=True,
                        prior_regret=True,
                    )
                ],
                _ChanceSplitToyServer,
                _DeferredDistilledToyNetwork,
                _DistilledPolicyToyNetwork,
                _ThirteenActionToyNetwork,
            )

    def test_terminal_and_distilled_frontiers(self):
        config = JointSearchConfig(
            max_depth=3, regret_iterations=16, leaf_evaluator="distilled"
        )
        self.compare([config], _ToyServer, _LeafToyNetwork)
        self.compare([config], _PotentialLadderToyServer, _ToyNetwork)

    def test_divergences_fail_closed_at_root_and_interior(self):
        config = JointSearchConfig(max_depth=3, regret_iterations=16)
        self.compare([config, config], _DivergentToyServer)
        self.compare([config, replace(config, max_depth=1)], InteriorDivergenceServer)

    def test_native_path_does_not_delegate_tree_work_to_python(self):
        server = TraceServer()
        network = _ToyNetwork()
        search = RustSimultaneousTreeSearch(
            server,
            network,
            network,
            JointSearchConfig(max_depth=2, regret_iterations=16),
            random.Random(7),
            random.Random(11),
        )
        with (
            patch.object(
                SimultaneousTreeSearch,
                "_make_node",
                side_effect=AssertionError("Python node"),
            ),
            patch.object(
                SimultaneousTreeSearch,
                "_open_subgames",
                side_effect=AssertionError("Python expansion"),
            ),
            patch.object(
                SimultaneousTreeSearch,
                "_settle",
                side_effect=AssertionError("Python backup"),
            ),
            patch.object(
                SimultaneousTreeSearch,
                "_install_expansion",
                side_effect=AssertionError("Python install"),
            ),
        ):
            self.assertEqual(search.search(server._snapshot(0)).failure, None)

    def test_distilled_policy_and_deferred_evaluation(self):
        config = JointSearchConfig(
            max_depth=3,
            regret_iterations=16,
            leaf_evaluator="distilled",
            interior_actions_per_side=1,
        )
        for network in (_DistilledPolicyToyNetwork, _DeferredDistilledToyNetwork):
            self.compare(
                [config, replace(config, leaf_evaluator="full")],
                TraceServer,
                network,
                distinct=False,
            )

    def test_all_cpu_solver_variants(self):
        from battle_training.rmplus_native import RUST_RMPLUS_BACKEND

        for temperature, cfr in ((0.02, False), (0.0, False), (0.0, True)):
            config = JointSearchConfig(
                max_depth=2,
                regret_iterations=16,
                chance_samples_per_joint=2,
                split_half_reliability=True,
                prior_regret=True,
                rmplus_backend=RUST_RMPLUS_BACKEND,
                solver_backend="rust",
                prior_anchor_temperature=temperature,
                cfr_plus_solves=cfr,
            )
            self.compare([config, config], distinct=True)

    def test_full_action_schema_and_sparse_masks(self):
        self.compare(
            [
                JointSearchConfig(
                    max_depth=2,
                    regret_iterations=8,
                    chance_samples_per_joint=3,
                    interior_chance_samples=3,
                    split_half_reliability=True,
                    prior_regret=True,
                )
            ],
            WideServer,
            _ThirteenActionToyNetwork,
            noise=True,
        )

    def test_seeded_configuration_sweep(self):
        rng = random.Random(7412)
        for trial in range(20):
            configs = [
                JointSearchConfig(
                    max_depth=rng.randint(1, 4),
                    max_actions_per_side=rng.randint(1, 2),
                    interior_actions_per_side=rng.randint(1, 2),
                    chance_samples_per_joint=rng.randint(1, 4),
                    interior_chance_samples=rng.randint(1, 3),
                    split_half_reliability=bool(rng.randrange(2)),
                    prior_regret=bool(rng.randrange(2)),
                    regret_iterations=8,
                    prior_anchor_temperature=rng.choice([0.0, 0.02]),
                )
                for _ in range(3)
            ]
            with self.subTest(trial=trial):
                self.compare(configs, noise=trial % 2 == 0, sampled=trial % 3 == 0)

    def test_dispatch_and_cli_preserve_old_run_configuration(self):
        from battle_training.cli import parser
        from battle_training.transformer_pipeline import _normalized_saved_config

        self.assertEqual(
            _normalized_saved_config({})["orchestration_backend"], "python"
        )
        for command, args in (
            ("transformer-train", []),
            ("arena", ["--candidate", "/tmp/a", "--baseline", "/tmp/b"]),
        ):
            parsed = parser().parse_args([command, "--output", "/tmp/parity", *args])
            self.assertEqual(parsed.orchestration_backend, "rust")
        server = TraceServer()
        net = _ToyNetwork()
        search = SimultaneousTreeSearch(
            server,
            net,
            net,
            JointSearchConfig(
                orchestration_backend="rust", max_depth=2, regret_iterations=8
            ),
            random.Random(1),
            random.Random(2),
        )
        with patch.object(
            SimultaneousTreeSearch,
            "_open_subgames",
            side_effect=AssertionError("Python orchestration"),
        ):
            self.assertIsNone(search.search(server._snapshot(0)).failure)

    def test_service_exception_releases_native_tree(self):
        from battle_training.search_native import _Engine

        original = _Engine.close
        released = []

        def close(engine):
            original(engine)
            released.append(not bool(engine.handle))

        server = TraceServer()
        net = _ToyNetwork()
        search = RustSimultaneousTreeSearch(
            server, net, net, JointSearchConfig(), random.Random(1), random.Random(2)
        )
        with (
            patch.object(_Engine, "close", close),
            patch.object(
                server, "search_steps", side_effect=TimeoutError("test timeout")
            ),
            self.assertRaisesRegex(TimeoutError, "test timeout"),
        ):
            search.search(server._snapshot(0))
        self.assertEqual(released, [True])

    def test_same_search_object_can_appear_twice_and_be_reused(self):
        observed = []
        for cls in (SimultaneousTreeSearch, RustSimultaneousTreeSearch):
            server, net = TraceServer(), _ToyNetwork()
            search = cls(
                server,
                net,
                net,
                JointSearchConfig(
                    max_depth=2,
                    regret_iterations=8,
                    chance_samples_per_joint=2,
                    split_half_reliability=True,
                ),
                random.Random(1),
                random.Random(2),
            )
            snapshots = [server._snapshot(0), server._snapshot(0)]
            results = cls.search_many([search, search], snapshots)
            results += cls.search_many([search, search], snapshots)
            observed.append(
                (
                    results,
                    server.requests,
                    search.chance_rng.getstate(),
                    search.selection_rng.getstate(),
                )
            )
        self.assertEqual(*observed)

    def test_missing_native_library_never_falls_back_or_consumes_rng(self):
        from battle_training.search_native import NativeSearchError

        server, net = TraceServer(), _ToyNetwork()
        search = RustSimultaneousTreeSearch(
            server, net, net, JointSearchConfig(), random.Random(1), random.Random(2)
        )
        state = search.chance_rng.getstate()
        with (
            patch(
                "battle_training.search_native._library",
                side_effect=NativeSearchError("missing"),
            ),
            self.assertRaisesRegex(NativeSearchError, "missing"),
        ):
            search.search(server._snapshot(0))
        self.assertEqual(state, search.chance_rng.getstate())
        self.assertEqual(server.requests, [])

    def test_invalid_batches_match_reference_validation(self):
        for cls in (SimultaneousTreeSearch, RustSimultaneousTreeSearch):
            server, net = TraceServer(), _ToyNetwork()
            search = cls(
                server,
                net,
                net,
                JointSearchConfig(),
                random.Random(1),
                random.Random(2),
            )
            for searches, snapshots in (
                ([], []),
                ([search], []),
                ([search], [replace(server._snapshot(0), done=True)]),
            ):
                with self.assertRaises(ValueError):
                    cls.search_many(searches, snapshots)
            other = cls(
                TraceServer(),
                net,
                net,
                JointSearchConfig(),
                random.Random(1),
                random.Random(2),
            )
            with self.assertRaisesRegex(ValueError, "one server"):
                cls.search_many(
                    [search, other], [server._snapshot(0), server._snapshot(0)]
                )
