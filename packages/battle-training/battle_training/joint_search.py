"""Batched exhaustive-root search with a regret-matched simultaneous policy."""

from __future__ import annotations

import math
import random
from collections.abc import Generator, Sequence
from concurrent.futures import Future, ThreadPoolExecutor
from dataclasses import dataclass, field
from typing import Any, cast

import numpy as np

from .decision_quality import shape_redundant_action_priors
from .native import SearchServer, Snapshot
from .network import BattleTransformer
from .rmplus_native import (
    PYTHON_REFERENCE_BACKEND,
    RUST_RMPLUS_BACKEND,
    solver_identity,
)
from .rmplus_native import (
    solve_cold as solve_cold_native,
)
from .rmplus_native import (
    solve_warm as solve_warm_native,
)

type PayoffMatrix = list[list[float]]

_PARTY_MON_WIDTH = 22
_FULL_SIDE_WIDTH = 181
_PARTY_SIZE = 6


@dataclass(frozen=True)
class SearchResult:
    player_policy: tuple[float, ...]
    enemy_policy: tuple[float, ...]
    player_action: int | None
    enemy_action: int | None
    root_value: float
    nodes: int
    solver: str
    exploitability: float | None
    payoff_spread: float | None
    payoff_matrix: tuple[tuple[float, ...], ...] | None
    diagnostics: dict[str, float | int | str] | None = None
    failure: str | None = None


@dataclass(frozen=True)
class JointSearchConfig:
    chance_samples_per_joint: int = 1
    max_depth: int = 1
    regret_iterations: int = 2048
    inference_batch_size: int = 256
    max_actions_per_side: int = 13
    expansion_budget: int = 320
    exploration: float = 0.10
    chance_resample: float = 0.10
    regret_iterations_per_update: int = 16
    deeper_joint_rotations: int = 2
    minimum_expansion_budget: int = 192
    convergence_tolerance: float = 0.005
    convergence_patience: int = 8
    redundant_action_prior_scale: float = 1.0
    adaptive_search: bool = False
    adaptive_deep_threshold: float = 0.55
    adaptive_force_deep_fraction: float = 0.10
    adaptive_exploitability_threshold: float = 0.08
    adaptive_payoff_spread_threshold: float = 0.75
    rmplus_backend: str = PYTHON_REFERENCE_BACKEND
    cfr_plus_solves: bool = False


def legal_actions(mask: int, action_count: int) -> list[int]:
    return [action for action in range(action_count) if mask & (1 << action)]


def _tactical_potential(features: Sequence[int]) -> float:
    """Dense, antisymmetric HP/faint/status potential from canonical party rows."""

    def side(offset: int) -> tuple[float, int, int]:
        hp_fraction = 0.0
        alive = 0
        statused = 0
        for slot in range(_PARTY_SIZE):
            base = offset + slot * _PARTY_MON_WIDTH
            hp = int(features[base + 1])
            status = int(features[base + 3])
            max_hp = int(features[base + 13])
            hp_fraction += hp / max(1, max_hp)
            alive += int(hp > 0)
            statused += int(hp > 0 and status != 0)
        return hp_fraction / _PARTY_SIZE, alive, statused

    own_hp, own_alive, own_status = side(0)
    foe_hp, foe_alive, foe_status = side(_FULL_SIDE_WIDTH)
    return (
        own_hp
        - foe_hp
        + 0.10 * (own_alive - foe_alive) / _PARTY_SIZE
        + 0.05 * (foe_status - own_status) / _PARTY_SIZE
    )


def _sample(probabilities: list[float], rng: random.Random) -> int:
    threshold = rng.random()
    cumulative = 0.0
    for action, probability in enumerate(probabilities):
        cumulative += probability
        if threshold <= cumulative:
            return action
    return max(
        index for index, probability in enumerate(probabilities) if probability > 0
    )


def _normalized_prior(priors: list[float], legal: list[int]) -> np.ndarray:
    values = np.asarray([priors[action] for action in legal], dtype=np.float64)
    total = float(values.sum())
    if total > 0.0:
        return values / total
    return np.full(len(legal), 1.0 / len(legal), dtype=np.float64)


def solve_zero_sum_regret(
    payoff: PayoffMatrix,
    player_priors: list[float],
    enemy_priors: list[float],
    player_legal: list[int],
    enemy_legal: list[int],
    iterations: int,
) -> tuple[tuple[float, ...], tuple[float, ...], float, float]:
    """Approximate a zero-sum matrix equilibrium with regret matching+.

    The solver operates on the legal submatrix in float64 NumPy.  Keeping the
    iteration loop in Python preserves deterministic RM+ update order while
    vectorized matrix products make production-quality root solves cheap.
    """
    if iterations < 1:
        raise ValueError("regret iterations must be positive")
    if not player_legal or not enemy_legal:
        raise ValueError("each side needs at least one legal action")
    action_count = len(payoff)
    matrix = np.asarray(payoff, dtype=np.float64)[np.ix_(player_legal, enemy_legal)]
    player_prior = np.asarray(
        [player_priors[action] for action in player_legal], dtype=np.float64
    )
    enemy_prior = np.asarray(
        [enemy_priors[action] for action in enemy_legal], dtype=np.float64
    )
    player_prior_total = float(player_prior.sum())
    enemy_prior_total = float(enemy_prior.sum())
    if player_prior_total > 0.0:
        player_prior /= player_prior_total
    else:
        player_prior.fill(1.0 / len(player_legal))
    if enemy_prior_total > 0.0:
        enemy_prior /= enemy_prior_total
    else:
        enemy_prior.fill(1.0 / len(enemy_legal))

    player_regrets = np.zeros(len(player_legal), dtype=np.float64)
    enemy_regrets = np.zeros(len(enemy_legal), dtype=np.float64)
    player_sum = np.zeros(len(player_legal), dtype=np.float64)
    enemy_sum = np.zeros(len(enemy_legal), dtype=np.float64)
    for _ in range(iterations):
        player_positive = np.maximum(player_regrets, 0.0)
        player_total = float(player_positive.sum())
        player = player_positive / player_total if player_total > 0.0 else player_prior
        enemy_positive = np.maximum(enemy_regrets, 0.0)
        enemy_total = float(enemy_positive.sum())
        enemy = enemy_positive / enemy_total if enemy_total > 0.0 else enemy_prior
        player_sum += player
        enemy_sum += enemy
        row_values = matrix @ enemy
        column_values = player @ matrix
        current_value = float(player @ row_values)
        player_regrets = np.maximum(0.0, player_regrets + row_values - current_value)
        enemy_regrets = np.maximum(0.0, enemy_regrets + current_value - column_values)

    player_legal_average = player_sum / iterations
    enemy_legal_average = enemy_sum / iterations
    player_average = [0.0] * action_count
    enemy_average = [0.0] * action_count
    for index, action in enumerate(player_legal):
        player_average[action] = float(player_legal_average[index])
    for index, action in enumerate(enemy_legal):
        enemy_average[action] = float(enemy_legal_average[index])
    row_values = matrix @ enemy_legal_average
    column_values = player_legal_average @ matrix
    value = float(player_legal_average @ row_values)
    return (
        tuple(player_average),
        tuple(enemy_average),
        value,
        float(row_values.max() - column_values.min()),
    )


class BatchedJointRegretSearch:
    """Covers every root joint action, batches rollouts, then solves its matrix."""

    def __init__(
        self,
        server: SearchServer,
        player_network: BattleTransformer,
        enemy_network: BattleTransformer,
        config: JointSearchConfig,
        selection_rng: random.Random,
        chance_rng: random.Random,
    ) -> None:
        if config.chance_samples_per_joint < 1:
            raise ValueError("chance samples per joint must be positive")
        if config.max_depth < 1:
            raise ValueError("search depth must be positive")
        if config.inference_batch_size < 1:
            raise ValueError("inference batch size must be positive")
        if config.max_actions_per_side < 1:
            raise ValueError("max actions per side must be positive")
        if not 0.0 < config.redundant_action_prior_scale <= 1.0:
            raise ValueError("redundant action prior scale must be in (0, 1]")
        self.server = server
        self.player_network = player_network
        self.enemy_network = enemy_network
        if player_network.config.action_count != enemy_network.config.action_count:
            raise ValueError("player and enemy action dictionaries differ")
        self.action_count = player_network.config.action_count
        self.config = config
        self.selection_rng = selection_rng
        self.chance_rng = chance_rng
        self._inference_cache: dict[
            tuple[int, str, bytes | tuple[int, ...], int],
            tuple[list[float], float],
        ] = {}
        self._inference_cache_stats = {"hits": 0, "misses": 0}

    @staticmethod
    def _feature_identity(
        feature: Sequence[int],
    ) -> tuple[str, bytes | tuple[int, ...]]:
        dtype = getattr(feature, "dtype", None)
        tobytes = getattr(feature, "tobytes", None)
        if dtype is not None and tobytes is not None:
            return dtype.str, tobytes()
        return "python-int", tuple(feature)

    def _cache_key(
        self, network: BattleTransformer, feature: Sequence[int], mask: int
    ) -> tuple[int, str, bytes | tuple[int, ...], int]:
        return (id(network), *self._feature_identity(feature), mask)

    def _network_batches(
        self,
        network: BattleTransformer,
        features: list[Sequence[int]],
        masks: list[int],
        batch_size: int,
    ) -> tuple[list[list[float]], list[float]]:
        keys = [
            self._cache_key(network, feature, mask)
            for feature, mask in zip(features, masks, strict=True)
        ]
        missing: dict[
            tuple[int, str, bytes | tuple[int, ...], int],
            tuple[Sequence[int], int],
        ] = {}
        for key, feature, mask in zip(keys, features, masks, strict=True):
            if key in self._inference_cache or key in missing:
                self._inference_cache_stats["hits"] += 1
            else:
                self._inference_cache_stats["misses"] += 1
                missing[key] = (feature, mask)
        missing_items = list(missing.items())
        for start in range(0, len(missing_items), batch_size):
            batch = missing_items[start : start + batch_size]
            batch_policies, batch_values = network.evaluate(
                [item[1][0] for item in batch],
                [item[1][1] for item in batch],
            )
            for (key, _), policy, value in zip(
                batch, batch_policies, batch_values, strict=True
            ):
                self._inference_cache[key] = (policy, value)
        cached = [self._inference_cache[key] for key in keys]
        return [item[0] for item in cached], [item[1] for item in cached]

    def _evaluate_many(
        self, snapshots: list[Snapshot]
    ) -> tuple[list[list[float]], list[list[float]], list[float]]:
        if not snapshots:
            return [], [], []
        size = self.config.inference_batch_size
        if self.player_network is self.enemy_network:
            features = [snapshot.player_features for snapshot in snapshots] + [
                snapshot.enemy_features for snapshot in snapshots
            ]
            masks = [snapshot.player_mask for snapshot in snapshots] + [
                snapshot.enemy_mask for snapshot in snapshots
            ]
            policies, values = self._network_batches(
                self.player_network, features, masks, size
            )
            count = len(snapshots)
            player_policies = policies[:count]
            enemy_policies = policies[count:]
            player_values = values[:count]
            enemy_values = values[count:]
        else:
            player_policies, player_values = self._network_batches(
                self.player_network,
                [snapshot.player_features for snapshot in snapshots],
                [snapshot.player_mask for snapshot in snapshots],
                size,
            )
            enemy_policies, enemy_values = self._network_batches(
                self.enemy_network,
                [snapshot.enemy_features for snapshot in snapshots],
                [snapshot.enemy_mask for snapshot in snapshots],
                size,
            )
        player_scale = (
            self.config.redundant_action_prior_scale
            if isinstance(self.player_network, BattleTransformer)
            else 1.0
        )
        enemy_scale = (
            self.config.redundant_action_prior_scale
            if isinstance(self.enemy_network, BattleTransformer)
            else 1.0
        )
        player_policies = [
            shape_redundant_action_priors(
                policy,
                snapshot.player_features,
                snapshot.player_mask,
                player_scale,
            )
            if snapshot.request == "battle"
            else policy
            for policy, snapshot in zip(player_policies, snapshots, strict=True)
        ]
        enemy_policies = [
            shape_redundant_action_priors(
                policy,
                snapshot.enemy_features,
                snapshot.enemy_mask,
                enemy_scale,
            )
            if snapshot.request == "battle"
            else policy
            for policy, snapshot in zip(enemy_policies, snapshots, strict=True)
        ]
        combined = [
            max(-1.0, min(1.0, (player - enemy) / 2.0))
            for player, enemy in zip(player_values, enemy_values, strict=True)
        ]
        return player_policies, enemy_policies, combined

    def search(self, snapshot: Snapshot, sample_actions: bool = True) -> SearchResult:
        if snapshot.done:
            raise ValueError("cannot search a terminal state")
        root_player, root_enemy, root_values = self._evaluate_many([snapshot])
        player_legal = legal_actions(snapshot.player_mask, self.action_count)
        enemy_legal = legal_actions(snapshot.enemy_mask, self.action_count)
        player_legal = sorted(
            player_legal, key=lambda action: (-root_player[0][action], action)
        )[: self.config.max_actions_per_side]
        enemy_legal = sorted(
            enemy_legal, key=lambda action: (-root_enemy[0][action], action)
        )[: self.config.max_actions_per_side]
        root_samples = [
            (player, enemy, sample)
            for player in player_legal
            for enemy in enemy_legal
            for sample in range(self.config.chance_samples_per_joint)
        ]
        root_chance = [
            self.chance_rng.getrandbits(63)
            for _ in range(self.config.chance_samples_per_joint)
        ]
        requests = [
            (snapshot.handle, player, enemy, root_chance[sample])
            for player, enemy, sample in root_samples
        ]
        trajectories = self.server.search_steps(requests)
        if any(successor.divergence is not None for successor in trajectories):
            return SearchResult(
                tuple(0.0 for _ in range(self.action_count)),
                tuple(0.0 for _ in range(self.action_count)),
                None,
                None,
                root_values[0],
                len(trajectories),
                "rmplus-unavailable-on-semantic-divergence-v1",
                None,
                None,
                None,
                failure="search-semantic-divergence",
            )
        root_potential = _tactical_potential(snapshot.player_features)
        transition_count = len(trajectories)
        values: list[float | None] = [None] * len(trajectories)
        for depth in range(1, self.config.max_depth + 1):
            active_indexes: list[int] = []
            active_snapshots: list[Snapshot] = []
            for index, successor in enumerate(trajectories):
                if values[index] is not None:
                    continue
                if successor.done:
                    values[index] = float(successor.terminal_return or 0)
                else:
                    active_indexes.append(index)
                    active_snapshots.append(successor)
            if not active_snapshots:
                break
            player_policies, enemy_policies, leaf_values = self._evaluate_many(
                active_snapshots
            )
            if depth >= self.config.max_depth:
                for index, value in zip(active_indexes, leaf_values, strict=True):
                    tactical_delta = (
                        _tactical_potential(trajectories[index].player_features)
                        - root_potential
                    )
                    values[index] = max(-1.0, min(1.0, value + tactical_delta))
                break
            rollout_chance = [
                self.chance_rng.getrandbits(63)
                for _ in range(self.config.chance_samples_per_joint)
            ]
            rollout_requests = [
                (
                    successor.handle,
                    _sample(player_policy, self.selection_rng),
                    _sample(enemy_policy, self.selection_rng),
                    rollout_chance[root_samples[index][2]],
                )
                for index, successor, player_policy, enemy_policy in zip(
                    active_indexes,
                    active_snapshots,
                    player_policies,
                    enemy_policies,
                    strict=True,
                )
            ]
            next_snapshots = self.server.search_steps(rollout_requests)
            transition_count += len(next_snapshots)
            for index, successor in zip(active_indexes, next_snapshots, strict=True):
                trajectories[index] = successor
        if any(value is None for value in values):
            raise RuntimeError("batched search left an unevaluated trajectory")
        payoff: PayoffMatrix = [
            [0.0] * self.action_count for _ in range(self.action_count)
        ]
        totals: dict[tuple[int, int], float] = {}
        counts: dict[tuple[int, int], int] = {}
        for sample, value in zip(root_samples, values, strict=True):
            pair = (sample[0], sample[1])
            totals[pair] = totals.get(pair, 0.0) + float(value)
            counts[pair] = counts.get(pair, 0) + 1
        for pair, total in totals.items():
            payoff[pair[0]][pair[1]] = total / counts[pair]
        player_policy, enemy_policy, root_value, exploitability = solve_zero_sum_regret(
            payoff,
            root_player[0],
            root_enemy[0],
            player_legal,
            enemy_legal,
            self.config.regret_iterations,
        )
        root_value = sum(
            player_policy[player] * enemy_policy[enemy] * payoff[player][enemy]
            for player in player_legal
            for enemy in enemy_legal
        )
        row_best_response = max(
            sum(enemy_policy[enemy] * payoff[player][enemy] for enemy in enemy_legal)
            for player in player_legal
        )
        column_best_response = min(
            sum(
                player_policy[player] * payoff[player][enemy] for player in player_legal
            )
            for enemy in enemy_legal
        )
        exploitability = row_best_response - column_best_response
        if sample_actions:
            player_action = _sample(list(player_policy), self.selection_rng)
            enemy_action = _sample(list(enemy_policy), self.selection_rng)
        else:
            player_action = max(player_legal, key=lambda action: player_policy[action])
            enemy_action = max(enemy_legal, key=lambda action: enemy_policy[action])
        legal_payoffs = [
            payoff[player][enemy] for player in player_legal for enemy in enemy_legal
        ]
        return SearchResult(
            player_policy,
            enemy_policy,
            player_action,
            enemy_action,
            root_value,
            transition_count,
            solver="simultaneous-joint-regret-crn-v2",
            exploitability=exploitability,
            payoff_spread=max(legal_payoffs) - min(legal_payoffs),
            payoff_matrix=tuple(tuple(row) for row in payoff),
        )


class _TreeDivergence(RuntimeError):
    pass


@dataclass
class _TreeOutcome:
    snapshot: Snapshot
    tactical_delta: float
    leaf_value: float


@dataclass
class _TreeNode:
    snapshot: Snapshot
    player_priors: list[float]
    enemy_priors: list[float]
    leaf_value: float
    player_legal: list[int]
    enemy_legal: list[int]
    payoff: PayoffMatrix
    counts: list[list[int]]
    outcomes: dict[tuple[int, int], list[_TreeOutcome]] = field(default_factory=dict)
    children: dict[int, _TreeNode] = field(default_factory=dict)
    player_policy: tuple[float, ...] = ()
    enemy_policy: tuple[float, ...] = ()
    root_value: float = 0.0
    exploitability: float = 0.0
    online_exploitability: float = 0.0
    expanded: bool = False
    visits: int = 0
    solve_count: int = 0
    player_strategy_sum: list[float] = field(default_factory=list)
    enemy_strategy_sum: list[float] = field(default_factory=list)
    player_regrets: list[float] = field(default_factory=list)
    enemy_regrets: list[float] = field(default_factory=list)
    sampled_pairs: set[tuple[int, int]] = field(default_factory=set)


@dataclass(frozen=True)
class _NativeFrontier:
    requests: list[tuple[int, int, int, int]]


@dataclass(frozen=True)
class _InferenceFrontier:
    snapshots: list[Snapshot]


@dataclass(frozen=True)
class _NodeInferenceFrontier:
    snapshots: list[Snapshot]


type _NodeEvaluation = tuple[list[float], list[float], float]
type _Frontier = _NativeFrontier | _InferenceFrontier | _NodeInferenceFrontier
type _FrontierResponse = (
    list[Snapshot] | list[tuple[float, float]] | list[_NodeEvaluation]
)


class SimultaneousTreeSearch(BatchedJointRegretSearch):
    """Matrix-valued SM-MCTS with RM+ at every expanded simultaneous node.

    Expansion covers the complete legal joint matrix. Later visits spend their
    budget on equilibrium-relevant descendants and explicit fresh chance
    outcomes instead of independent disposable rollout trajectories.
    """

    def __init__(
        self,
        server: SearchServer,
        player_network: BattleTransformer,
        enemy_network: BattleTransformer,
        config: JointSearchConfig,
        selection_rng: random.Random,
        chance_rng: random.Random,
        budget_rng: random.Random | None = None,
    ) -> None:
        super().__init__(
            server,
            player_network,
            enemy_network,
            config,
            selection_rng,
            chance_rng,
        )
        if config.expansion_budget < 1:
            raise ValueError("tree expansion budget must be positive")
        if not 0.0 <= config.exploration <= 1.0:
            raise ValueError("tree exploration must be in [0, 1]")
        if not 0.0 <= config.chance_resample <= 1.0:
            raise ValueError("tree chance resampling must be in [0, 1]")
        if config.regret_iterations_per_update < 1:
            raise ValueError("tree regret iterations per update must be positive")
        if config.deeper_joint_rotations < 1:
            raise ValueError("deeper joint rotations must be positive")
        if not 1 <= config.minimum_expansion_budget <= config.expansion_budget:
            raise ValueError("minimum tree budget must be in 1..expansion_budget")
        if config.convergence_tolerance < 0.0:
            raise ValueError("tree convergence tolerance must be nonnegative")
        if config.convergence_patience < 1:
            raise ValueError("tree convergence patience must be positive")
        if not 0.0 <= config.adaptive_deep_threshold <= 1.0:
            raise ValueError("adaptive deep threshold must be in [0, 1]")
        if not 0.0 <= config.adaptive_force_deep_fraction <= 1.0:
            raise ValueError("adaptive force-deep fraction must be in [0, 1]")
        if config.adaptive_exploitability_threshold < 0.0:
            raise ValueError("adaptive exploitability threshold must be nonnegative")
        if config.adaptive_payoff_spread_threshold < 0.0:
            raise ValueError("adaptive payoff-spread threshold must be nonnegative")
        if config.rmplus_backend not in {
            PYTHON_REFERENCE_BACKEND,
            RUST_RMPLUS_BACKEND,
        }:
            raise ValueError(f"unsupported RM+ backend: {config.rmplus_backend!r}")
        if config.cfr_plus_solves and config.rmplus_backend != RUST_RMPLUS_BACKEND:
            raise ValueError("CFR+ requires the native Rust RM+ backend")
        self._evaluation_cache: dict[int, tuple[list[float], list[float], float]] = {}
        self._joint_inference_cache: dict[
            tuple[int, str, bytes | tuple[int, ...], int, int],
            tuple[list[float], list[float], float],
        ] = {}
        self._leaf_inference_cache: dict[
            tuple[int, str, bytes | tuple[int, ...]], float
        ] = {}
        self._expanded_nodes = 0
        self._chance_outcomes = 0
        self._max_depth_reached = 0
        self._sampled_joint_pairs = 0
        self._possible_joint_pairs = 0
        self._cross_root_batch_size = 1
        self._cross_root_root_leaves = 0
        self._deep_inference_calls = 0
        self._deep_inference_rows = 0
        self._deep_inference_waves = 0
        self._deep_full_inference_calls = 0
        self._deep_full_inference_rows = 0
        self._deep_full_inference_waves = 0
        self._deep_native_calls = 0
        self._deep_native_rows = 0
        self._deep_native_waves = 0
        self._deep_overlap_waves = 0
        self.budget_rng = budget_rng or random.Random(0)
        self._adaptive_deep_selected = True
        self._adaptive_router_score = 1.0
        self._adaptive_reason = "adaptive-disabled"
        self._deep_policy_change = 0.0
        self._deep_action_changed = 0
        self._deep_search_needed = -1

    def _legal_from_priors(self, mask: int, priors: list[float]) -> list[int]:
        actions = legal_actions(mask, self.action_count)
        return sorted(actions, key=lambda action: (-priors[action], action))[
            : self.config.max_actions_per_side
        ]

    def _make_node(
        self,
        snapshot: Snapshot,
        evaluation: tuple[list[float], list[float], float] | None = None,
    ) -> _TreeNode:
        if evaluation is None:
            evaluation = self._evaluation_cache.get(snapshot.handle)
        if evaluation is None:
            raise RuntimeError("tree node construction requires pooled full evaluation")
        player_priors, enemy_priors, leaf_value = evaluation
        self._evaluation_cache[snapshot.handle] = evaluation
        player_legal = self._legal_from_priors(snapshot.player_mask, player_priors)
        enemy_legal = self._legal_from_priors(snapshot.enemy_mask, enemy_priors)
        node = _TreeNode(
            snapshot=snapshot,
            player_priors=player_priors,
            enemy_priors=enemy_priors,
            leaf_value=leaf_value,
            player_legal=player_legal,
            enemy_legal=enemy_legal,
            payoff=[[0.0] * self.action_count for _ in range(self.action_count)],
            counts=[[0] * self.action_count for _ in range(self.action_count)],
            player_strategy_sum=[0.0] * self.action_count,
            enemy_strategy_sum=[0.0] * self.action_count,
            player_regrets=[0.0] * self.action_count,
            enemy_regrets=[0.0] * self.action_count,
        )
        for player_action in player_legal:
            for enemy_action in enemy_legal:
                node.payoff[player_action][enemy_action] = leaf_value
        return node

    def _solve_node(self, node: _TreeNode) -> None:
        """Advance one warm-started RM+ or CFR+ node solve."""
        if self.config.rmplus_backend == RUST_RMPLUS_BACKEND:
            result = solve_warm_native(
                node.payoff,
                node.player_priors,
                node.enemy_priors,
                node.player_legal,
                node.enemy_legal,
                node.player_regrets,
                node.enemy_regrets,
                node.player_strategy_sum,
                node.enemy_strategy_sum,
                node.solve_count,
                self.config.regret_iterations_per_update,
                cfr_plus=self.config.cfr_plus_solves,
            )
            node.player_regrets = result.player_regrets
            node.enemy_regrets = result.enemy_regrets
            node.player_strategy_sum = result.player_strategy_sum
            node.enemy_strategy_sum = result.enemy_strategy_sum
            node.solve_count = result.solve_count
            node.player_policy = tuple(result.player_policy)
            node.enemy_policy = tuple(result.enemy_policy)
            node.root_value = result.value
            node.exploitability = result.exploitability
            return

        player_legal = node.player_legal
        enemy_legal = node.enemy_legal
        matrix = np.asarray(node.payoff, dtype=np.float64)[
            np.ix_(player_legal, enemy_legal)
        ]
        player_regrets = np.asarray(
            [node.player_regrets[action] for action in player_legal], dtype=np.float64
        )
        enemy_regrets = np.asarray(
            [node.enemy_regrets[action] for action in enemy_legal], dtype=np.float64
        )
        player_prior = _normalized_prior(node.player_priors, player_legal)
        enemy_prior = _normalized_prior(node.enemy_priors, enemy_legal)
        player_sum = np.zeros(len(player_legal), dtype=np.float64)
        enemy_sum = np.zeros(len(enemy_legal), dtype=np.float64)
        player = player_prior
        enemy = enemy_prior
        for _ in range(self.config.regret_iterations_per_update):
            player_positive = np.maximum(player_regrets, 0.0)
            player_total = float(player_positive.sum())
            player = (
                player_positive / player_total if player_total > 0.0 else player_prior
            )
            enemy_positive = np.maximum(enemy_regrets, 0.0)
            enemy_total = float(enemy_positive.sum())
            enemy = enemy_positive / enemy_total if enemy_total > 0.0 else enemy_prior
            player_sum += player
            enemy_sum += enemy
            row_values = matrix @ enemy
            column_values = player @ matrix
            value = float(player @ row_values)
            player_regrets = np.maximum(0.0, player_regrets + row_values - value)
            enemy_regrets = np.maximum(0.0, enemy_regrets + value - column_values)
        for index, action in enumerate(player_legal):
            node.player_regrets[action] = float(player_regrets[index])
            node.player_strategy_sum[action] += float(player_sum[index])
        for index, action in enumerate(enemy_legal):
            node.enemy_regrets[action] = float(enemy_regrets[index])
            node.enemy_strategy_sum[action] += float(enemy_sum[index])
        node.solve_count += self.config.regret_iterations_per_update
        player_policy = [0.0] * self.action_count
        enemy_policy = [0.0] * self.action_count
        for index, action in enumerate(player_legal):
            player_policy[action] = float(player[index])
        for index, action in enumerate(enemy_legal):
            enemy_policy[action] = float(enemy[index])
        node.player_policy = tuple(player_policy)
        node.enemy_policy = tuple(enemy_policy)
        row_values = matrix @ enemy
        node.root_value = float(player @ row_values)
        node.exploitability = float(row_values.max() - (player @ matrix).min())

    def _root_equilibrium(
        self, node: _TreeNode
    ) -> tuple[tuple[float, ...], tuple[float, ...], float, float]:
        """Solve the current root matrix without stale online-search averages."""
        if self.config.rmplus_backend == RUST_RMPLUS_BACKEND:
            return solve_cold_native(
                node.payoff,
                node.player_priors,
                node.enemy_priors,
                node.player_legal,
                node.enemy_legal,
                self.config.regret_iterations,
                cfr_plus=self.config.cfr_plus_solves,
            )
        return solve_zero_sum_regret(
            node.payoff,
            node.player_priors,
            node.enemy_priors,
            node.player_legal,
            node.enemy_legal,
            self.config.regret_iterations,
        )

    @staticmethod
    def _record_value(
        node: _TreeNode, player_action: int, enemy_action: int, value: float
    ) -> None:
        count = node.counts[player_action][enemy_action]
        current = node.payoff[player_action][enemy_action]
        node.payoff[player_action][enemy_action] = (current * count + value) / (
            count + 1
        )
        node.counts[player_action][enemy_action] = count + 1

    @classmethod
    def _pooled_evaluate(
        cls,
        groups: list[tuple[int, SimultaneousTreeSearch, list[Snapshot]]],
    ) -> tuple[
        dict[int, tuple[list[list[float]], list[list[float]], list[float]]],
        int,
        int,
    ]:
        """Evaluate exact rows once, using one physical forward for mirrors."""
        outputs: dict[tuple[int, int, int], tuple[list[float], float]] = {}
        known: dict[
            tuple[int, str, bytes | tuple[int, ...], int],
            tuple[list[float], float],
        ] = {}
        joint_known: dict[
            tuple[int, str, bytes | tuple[int, ...], int, int],
            tuple[list[float], list[float], float],
        ] = {}
        missing: dict[
            tuple[int, str, bytes | tuple[int, ...], int], dict[str, Any]
        ] = {}
        joint_missing: dict[
            tuple[int, str, bytes | tuple[int, ...], int, int], dict[str, Any]
        ] = {}

        for group_id, search, snapshots in groups:
            network = search.player_network
            joint = network is search.enemy_network and bool(
                getattr(network.config, "joint_policy_heads", False)
            )
            if joint:
                for position, snapshot in enumerate(snapshots):
                    if snapshot.player_mask == 0 or snapshot.enemy_mask == 0:
                        inspection = search.server.inspect(snapshot.handle)
                        raise ValueError(
                            "search reached a nonterminal state with an empty legal mask: "
                            f"handle={snapshot.handle} turn={snapshot.turn} "
                            f"request={snapshot.request} player_mask={snapshot.player_mask} "
                            f"enemy_mask={snapshot.enemy_mask} inspection={inspection!r}"
                        )
                    identity = search._feature_identity(snapshot.player_features)
                    key = (
                        id(network),
                        *identity,
                        snapshot.player_mask,
                        snapshot.enemy_mask,
                    )
                    cached = search._joint_inference_cache.get(key) or joint_known.get(
                        key
                    )
                    consumer = (group_id, position, search)
                    if cached is not None:
                        search._inference_cache_stats["hits"] += 1
                        search._joint_inference_cache[key] = cached
                        joint_known[key] = cached
                        outputs[(group_id, position, 0)] = (cached[0], cached[2])
                        outputs[(group_id, position, 1)] = (cached[1], -cached[2])
                    elif key in joint_missing:
                        search._inference_cache_stats["hits"] += 1
                        joint_missing[key]["consumers"].append(consumer)
                    else:
                        search._inference_cache_stats["misses"] += 1
                        joint_missing[key] = {
                            "network": network,
                            "feature": snapshot.player_features,
                            "opponent_feature": snapshot.enemy_features,
                            "own_mask": snapshot.player_mask,
                            "opponent_mask": snapshot.enemy_mask,
                            "consumers": [consumer],
                        }
                continue

            # Distinct controllers retain one side-canonical forward per model.
            for side, side_network in (
                (0, search.player_network),
                (1, search.enemy_network),
            ):
                for position, snapshot in enumerate(snapshots):
                    feature = (
                        snapshot.player_features
                        if side == 0
                        else snapshot.enemy_features
                    )
                    mask = snapshot.player_mask if side == 0 else snapshot.enemy_mask
                    if mask == 0:
                        inspection = search.server.inspect(snapshot.handle)
                        raise ValueError(
                            "search reached a nonterminal state with an empty legal mask: "
                            f"side={side} handle={snapshot.handle} turn={snapshot.turn} "
                            f"request={snapshot.request} player_mask={snapshot.player_mask} "
                            f"enemy_mask={snapshot.enemy_mask} inspection={inspection!r}"
                        )
                    key = search._cache_key(side_network, feature, mask)
                    cached = search._inference_cache.get(key) or known.get(key)
                    consumer = (group_id, position, side, search)
                    if cached is not None:
                        search._inference_cache_stats["hits"] += 1
                        search._inference_cache[key] = cached
                        known[key] = cached
                        outputs[(group_id, position, side)] = cached
                    elif key in missing:
                        search._inference_cache_stats["hits"] += 1
                        missing[key]["consumers"].append(consumer)
                    else:
                        search._inference_cache_stats["misses"] += 1
                        missing[key] = {
                            "network": side_network,
                            "feature": feature,
                            "mask": mask,
                            "consumers": [consumer],
                        }

        by_network: dict[int, list[tuple[Any, dict[str, Any]]]] = {}
        for key, item in missing.items():
            by_network.setdefault(id(item["network"]), []).append((key, item))
        batches: list[tuple[Any, list[tuple[Any, dict[str, Any]]]]] = []
        for items in by_network.values():
            network = items[0][1]["network"]
            batch_size = max(
                consumer[3].config.inference_batch_size
                for _, item in items
                for consumer in item["consumers"]
            )
            for start in range(0, len(items), batch_size):
                batches.append((network, items[start : start + batch_size]))

        joint_by_network: dict[int, list[tuple[Any, dict[str, Any]]]] = {}
        for key, item in joint_missing.items():
            joint_by_network.setdefault(id(item["network"]), []).append((key, item))
        joint_batches: list[tuple[Any, list[tuple[Any, dict[str, Any]]]]] = []
        for items in joint_by_network.values():
            network = items[0][1]["network"]
            batch_size = max(
                consumer[2].config.inference_batch_size
                for _, item in items
                for consumer in item["consumers"]
            )
            for start in range(0, len(items), batch_size):
                joint_batches.append((network, items[start : start + batch_size]))

        pending: list[tuple[list[tuple[Any, dict[str, Any]]], Any]] = []
        synchronous: list[tuple[Any, list[tuple[Any, dict[str, Any]]]]] = []
        for network, batch in batches:
            begin = getattr(network, "begin_evaluate", None)
            can_defer = getattr(network, "supports_deferred_evaluation", True)
            if begin is None or not can_defer:
                synchronous.append((network, batch))
            else:
                pending.append(
                    (
                        batch,
                        begin(
                            [item[1]["feature"] for item in batch],
                            [item[1]["mask"] for item in batch],
                        ),
                    )
                )

        joint_pending: list[tuple[list[tuple[Any, dict[str, Any]]], Any]] = []
        joint_synchronous: list[tuple[Any, list[tuple[Any, dict[str, Any]]]]] = []
        for network, batch in joint_batches:
            begin = getattr(network, "begin_evaluate_joint", None)
            can_defer = getattr(network, "supports_deferred_evaluation", True)
            if begin is None or not can_defer:
                joint_synchronous.append((network, batch))
            else:
                joint_pending.append(
                    (
                        batch,
                        begin(
                            [item[1]["feature"] for item in batch],
                            [item[1]["own_mask"] for item in batch],
                            [item[1]["opponent_mask"] for item in batch],
                        ),
                    )
                )

        completed = []
        for network, batch in synchronous:
            policies, values = network.evaluate(
                [item[1]["feature"] for item in batch],
                [item[1]["mask"] for item in batch],
            )
            completed.append((batch, policies, values))
        for batch, ticket in pending:
            policies, values = ticket.result()
            completed.append((batch, policies, values))
        for batch, policies, values in completed:
            for (key, item), policy, value in zip(batch, policies, values, strict=True):
                network = item["network"]
                if isinstance(network, BattleTransformer):
                    scale = item["consumers"][0][3].config.redundant_action_prior_scale
                    policy = shape_redundant_action_priors(
                        policy, item["feature"], item["mask"], scale
                    )
                cached = (policy, value)
                known[key] = cached
                for group_id, position, side, search in item["consumers"]:
                    search._inference_cache[key] = cached
                    outputs[(group_id, position, side)] = cached

        joint_completed = []
        for network, batch in joint_synchronous:
            own, opponent, values = network.evaluate_joint(
                [item[1]["feature"] for item in batch],
                [item[1]["own_mask"] for item in batch],
                [item[1]["opponent_mask"] for item in batch],
            )
            joint_completed.append((batch, own, opponent, values))
        for batch, ticket in joint_pending:
            own, opponent, values = ticket.result()
            joint_completed.append((batch, own, opponent, values))
        for batch, own, opponent, values in joint_completed:
            for (key, item), player, enemy, value in zip(
                batch, own, opponent, values, strict=True
            ):
                network = item["network"]
                if isinstance(network, BattleTransformer):
                    scale = item["consumers"][0][2].config.redundant_action_prior_scale
                    player = shape_redundant_action_priors(
                        player, item["feature"], item["own_mask"], scale
                    )
                    enemy = shape_redundant_action_priors(
                        enemy,
                        item["opponent_feature"],
                        item["opponent_mask"],
                        scale,
                    )
                cached = (player, enemy, value)
                joint_known[key] = cached
                for group_id, position, search in item["consumers"]:
                    search._joint_inference_cache[key] = cached
                    outputs[(group_id, position, 0)] = (player, value)
                    outputs[(group_id, position, 1)] = (enemy, -value)

        results = {}
        for group_id, search, snapshots in groups:
            player_policies = [
                outputs[(group_id, position, 0)][0]
                for position in range(len(snapshots))
            ]
            enemy_policies = [
                outputs[(group_id, position, 1)][0]
                for position in range(len(snapshots))
            ]
            values = [
                max(
                    -1.0,
                    min(
                        1.0,
                        (
                            outputs[(group_id, position, 0)][1]
                            - outputs[(group_id, position, 1)][1]
                        )
                        / 2.0,
                    ),
                )
                for position in range(len(snapshots))
            ]
            for snapshot, player, enemy, value in zip(
                snapshots, player_policies, enemy_policies, values, strict=True
            ):
                search._evaluation_cache[snapshot.handle] = (player, enemy, value)
            results[group_id] = (player_policies, enemy_policies, values)
        calls = len(batches) + len(joint_batches)
        rows = sum(len(batch) for _, batch in [*batches, *joint_batches])
        return results, calls, rows

    @classmethod
    def _pooled_leaf_values(
        cls,
        groups: list[tuple[int, SimultaneousTreeSearch, list[Snapshot]]],
    ) -> tuple[dict[int, list[float]], int, int]:
        outputs: dict[tuple[int, int, int], float] = {}
        known: dict[tuple[int, str, bytes | tuple[int, ...]], float] = {}
        missing: dict[tuple[int, str, bytes | tuple[int, ...]], dict[str, Any]] = {}
        for group_id, search, snapshots in groups:
            mirror = search.player_network is search.enemy_network
            sides = (
                ((0, search.player_network),)
                if mirror
                else (
                    (0, search.player_network),
                    (1, search.enemy_network),
                )
            )
            for side, network in sides:
                for position, snapshot in enumerate(snapshots):
                    feature = (
                        snapshot.player_features
                        if side == 0
                        else snapshot.enemy_features
                    )
                    key = (id(network), *search._feature_identity(feature))
                    cached = search._leaf_inference_cache.get(key) or known.get(key)
                    consumer = (group_id, position, side, mirror, search)
                    if cached is not None:
                        search._inference_cache_stats["hits"] += 1
                        search._leaf_inference_cache[key] = cached
                        known[key] = cached
                        outputs[(group_id, position, side)] = cached
                        if mirror:
                            outputs[(group_id, position, 1)] = -cached
                    elif key in missing:
                        search._inference_cache_stats["hits"] += 1
                        missing[key]["consumers"].append(consumer)
                    else:
                        search._inference_cache_stats["misses"] += 1
                        missing[key] = {
                            "network": network,
                            "feature": feature,
                            "consumers": [consumer],
                        }

        by_network: dict[int, list[tuple[Any, dict[str, Any]]]] = {}
        for key, item in missing.items():
            by_network.setdefault(id(item["network"]), []).append((key, item))
        batches = []
        for items in by_network.values():
            network = items[0][1]["network"]
            batch_size = max(
                consumer[4].config.inference_batch_size
                for _, item in items
                for consumer in item["consumers"]
            )
            for start in range(0, len(items), batch_size):
                batches.append((network, items[start : start + batch_size]))

        pending = []
        synchronous = []
        for network, batch in batches:
            begin = getattr(network, "begin_evaluate_leaf", None)
            can_defer = getattr(network, "supports_deferred_evaluation", True)
            if begin is None or not can_defer:
                synchronous.append((network, batch))
            else:
                pending.append((batch, begin([item[1]["feature"] for item in batch])))
        completed = []
        for network, batch in synchronous:
            completed.append(
                (
                    batch,
                    network.evaluate_leaf([item[1]["feature"] for item in batch]),
                )
            )
        for batch, ticket in pending:
            completed.append((batch, ticket.result()))
        for batch, values in completed:
            for (key, item), value in zip(batch, values, strict=True):
                known[key] = value
                for group_id, position, side, mirror, search in item["consumers"]:
                    search._leaf_inference_cache[key] = value
                    outputs[(group_id, position, side)] = value
                    if mirror:
                        outputs[(group_id, position, 1)] = -value

        results = {}
        for group_id, _, snapshots in groups:
            results[group_id] = [
                max(
                    -1.0,
                    min(
                        1.0,
                        (
                            outputs[(group_id, position, 0)]
                            - outputs[(group_id, position, 1)]
                        )
                        / 2.0,
                    ),
                )
                for position in range(len(snapshots))
            ]
        return (
            results,
            len(batches),
            sum(len(batch) for _, batch in batches),
        )

    @classmethod
    def _pooled_successor_values(
        cls,
        groups: list[tuple[int, SimultaneousTreeSearch, list[Snapshot]]],
    ) -> tuple[dict[int, list[tuple[float, float]]], int, int]:
        if any(
            snapshot.divergence is not None
            for _, _, snapshots in groups
            for snapshot in snapshots
        ):
            raise _TreeDivergence("semantic divergence in pooled tree frontier")
        active_groups = []
        for group_id, search, snapshots in groups:
            active = [snapshot for snapshot in snapshots if not snapshot.done]
            if active:
                active_groups.append((group_id, search, active))
        use_distilled = all(
            bool(
                getattr(search.player_network.config, "distilled_leaf_evaluator", False)
            )
            and bool(
                getattr(search.enemy_network.config, "distilled_leaf_evaluator", False)
            )
            for _, search, _ in active_groups
        )
        if use_distilled:
            leaf_values, calls, rows = cls._pooled_leaf_values(active_groups)
        else:
            evaluated, calls, rows = cls._pooled_evaluate(active_groups)
            leaf_values = {
                group_id: values[2] for group_id, values in evaluated.items()
            }
        results = {}
        for group_id, _, snapshots in groups:
            active_values = iter(leaf_values.get(group_id, []))
            values = []
            for snapshot in snapshots:
                value = (
                    float(snapshot.terminal_return or 0)
                    if snapshot.done
                    else next(active_values)
                )
                values.append((value, value))
            results[group_id] = values
        return results, calls, rows

    def _expansion_pairs(
        self, node: _TreeNode, full_matrix: bool
    ) -> list[tuple[int, int]]:
        if full_matrix:
            return [
                (player, enemy)
                for player in node.player_legal
                for enemy in node.enemy_legal
            ]
        pair_count = max(len(node.player_legal), len(node.enemy_legal))
        rotations = min(self.config.deeper_joint_rotations, len(node.enemy_legal))
        pairs: list[tuple[int, int]] = []
        for rotation in range(rotations):
            for index in range(pair_count):
                pair = (
                    node.player_legal[index % len(node.player_legal)],
                    node.enemy_legal[(index + rotation) % len(node.enemy_legal)],
                )
                if pair not in pairs:
                    pairs.append(pair)
        return pairs

    def _expansion_spec(
        self, node: _TreeNode, full_matrix: bool
    ) -> tuple[list[tuple[int, int, int]], list[tuple[int, int, int, int]]]:
        pairs = self._expansion_pairs(node, full_matrix)
        samples = [
            (player, enemy, sample)
            for player, enemy in pairs
            for sample in range(self.config.chance_samples_per_joint)
        ]
        chance = [
            self.chance_rng.getrandbits(63)
            for _ in range(self.config.chance_samples_per_joint)
        ]
        requests = [
            (node.snapshot.handle, player, enemy, chance[sample])
            for player, enemy, sample in samples
        ]
        return samples, requests

    def _install_expansion(
        self,
        node: _TreeNode,
        samples: list[tuple[int, int, int]],
        successors: list[Snapshot],
        evaluated: list[tuple[float, float]],
    ) -> int:
        pairs = list(dict.fromkeys((player, enemy) for player, enemy, _ in samples))
        parent_potential = _tactical_potential(node.snapshot.player_features)
        for sample, successor, evaluation in zip(
            samples, successors, evaluated, strict=True
        ):
            player, enemy, _ = sample
            leaf_value = evaluation[0]
            if successor.done:
                delta = 0.0
                shaped = leaf_value
            else:
                delta = (
                    _tactical_potential(successor.player_features) - parent_potential
                )
                shaped = max(-1.0, min(1.0, leaf_value + delta))
            node.outcomes.setdefault((player, enemy), []).append(
                _TreeOutcome(successor, delta, leaf_value)
            )
            self._record_value(node, player, enemy, shaped)
        node.sampled_pairs.update(pairs)
        node.expanded = True
        self._expanded_nodes += 1
        self._possible_joint_pairs += len(node.player_legal) * len(node.enemy_legal)
        self._sampled_joint_pairs += len(pairs)
        self._chance_outcomes += len(successors)
        self._solve_node(node)
        return len(successors)

    def _expand_frontier(
        self, node: _TreeNode, full_matrix: bool = False
    ) -> Generator[_Frontier, _FrontierResponse, int]:
        samples, requests = self._expansion_spec(node, full_matrix)
        response = yield _NativeFrontier(requests)
        successors = cast(list[Snapshot], response)
        if any(successor.divergence is not None for successor in successors):
            raise _TreeDivergence("semantic divergence in tree expansion")
        response = yield _InferenceFrontier(successors)
        evaluated = cast(list[tuple[float, float]], response)
        return self._install_expansion(node, samples, successors, evaluated)

    def _chance_resample_probability(self, evidence: int) -> float:
        """Sample uncertain chance outcomes aggressively, then decay to the floor."""
        if evidence < 1:
            return 1.0
        return max(self.config.chance_resample, 1.0 / math.sqrt(evidence))

    def _mixed_policy(
        self,
        policy: tuple[float, ...],
        priors: list[float],
        legal: list[int],
        visits: int,
    ) -> list[float]:
        """Progressively mix RM+ with neural priors while retaining legal support."""
        epsilon = max(0.02, self.config.exploration / ((visits + 1) ** 0.5))
        prior_total = sum(priors[action] for action in legal)
        result = [0.0] * self.action_count
        for action in legal:
            exploration = (
                priors[action] / prior_total if prior_total > 0.0 else 1.0 / len(legal)
            )
            result[action] = (1.0 - epsilon) * policy[action] + epsilon * exploration
        return result

    def _new_chance_outcome_frontier(
        self, node: _TreeNode, player_action: int, enemy_action: int
    ) -> Generator[_Frontier, _FrontierResponse, _TreeOutcome]:
        response = yield _NativeFrontier(
            [
                (
                    node.snapshot.handle,
                    player_action,
                    enemy_action,
                    self.chance_rng.getrandbits(63),
                )
            ]
        )
        successor = cast(list[Snapshot], response)[0]
        if successor.divergence is not None:
            raise _TreeDivergence("semantic divergence in tree simulation")
        response = yield _InferenceFrontier([successor])
        evaluated = cast(list[tuple[float, float]], response)[0][0]
        if successor.done:
            delta = 0.0
        else:
            delta = _tactical_potential(
                successor.player_features
            ) - _tactical_potential(node.snapshot.player_features)
        outcome = _TreeOutcome(successor, delta, evaluated)
        pair = (player_action, enemy_action)
        node.outcomes.setdefault(pair, []).append(outcome)
        if pair not in node.sampled_pairs:
            node.sampled_pairs.add(pair)
            self._sampled_joint_pairs += 1
        self._chance_outcomes += 1
        return outcome

    def _joint_cost(self, node: _TreeNode) -> int:
        return (
            len(self._expansion_pairs(node, False))
            * self.config.chance_samples_per_joint
        )

    def _simulate_frontier(
        self, node: _TreeNode, depth: int, remaining: int
    ) -> Generator[_Frontier, _FrontierResponse, tuple[float, int, bool]]:
        self._max_depth_reached = max(self._max_depth_reached, depth)
        node.visits += 1
        player_policy = self._mixed_policy(
            tuple(node.player_policy),
            node.player_priors,
            node.player_legal,
            node.visits,
        )
        enemy_policy = self._mixed_policy(
            tuple(node.enemy_policy),
            node.enemy_priors,
            node.enemy_legal,
            node.visits,
        )
        player_action = _sample(player_policy, self.selection_rng)
        enemy_action = _sample(enemy_policy, self.selection_rng)
        cost = 0
        pair = (player_action, enemy_action)
        if pair not in node.outcomes and remaining <= 0:
            return node.root_value, 0, False
        evidence = len(node.outcomes.get(pair, ()))
        fresh = pair not in node.outcomes or (
            remaining > 0
            and self.selection_rng.random()
            < self._chance_resample_probability(evidence)
        )
        if fresh:
            outcome = yield from self._new_chance_outcome_frontier(
                node, player_action, enemy_action
            )
            cost = 1
        else:
            outcomes = node.outcomes[pair]
            outcome = outcomes[self.selection_rng.randrange(len(outcomes))]
        successor = outcome.snapshot
        if successor.done:
            value = float(successor.terminal_return or 0)
            learned = fresh
        elif depth + 1 >= self.config.max_depth:
            value = max(-1.0, min(1.0, outcome.leaf_value + outcome.tactical_delta))
            learned = fresh
        else:
            child = node.children.get(successor.handle)
            if child is None:
                response = yield _NodeInferenceFrontier([successor])
                evaluation = cast(list[_NodeEvaluation], response)[0]
                child = self._make_node(successor, evaluation)
                node.children[successor.handle] = child
            if not child.expanded:
                expansion_cost = self._joint_cost(child)
                if cost + expansion_cost <= remaining:
                    cost += yield from self._expand_frontier(child, False)
                    self._max_depth_reached = max(self._max_depth_reached, depth + 1)
                    value = max(
                        -1.0,
                        min(1.0, outcome.tactical_delta + child.root_value),
                    )
                    learned = True
                else:
                    value = max(
                        -1.0,
                        min(1.0, outcome.leaf_value + outcome.tactical_delta),
                    )
                    learned = fresh
            else:
                (
                    child_value,
                    child_cost,
                    child_learned,
                ) = yield from self._simulate_frontier(
                    child, depth + 1, remaining - cost
                )
                learned = fresh or child_learned
                cost += child_cost
                value = max(
                    -1.0,
                    min(1.0, outcome.tactical_delta + child_value),
                )
        if learned:
            self._record_value(node, player_action, enemy_action, value)
            self._solve_node(node)
        return value, cost, learned

    def _average_policy(
        self, strategy_sum: list[float], solves: int, fallback: tuple[float, ...]
    ) -> tuple[float, ...]:
        if solves <= 0:
            return fallback
        weight = solves * (solves + 1) / 2 if self.config.cfr_plus_solves else solves
        return tuple(value / weight for value in strategy_sum)

    @classmethod
    def _pooled_budget_scores(
        cls,
        groups: list[tuple[int, SimultaneousTreeSearch, Snapshot]],
    ) -> dict[int, float]:
        outputs: dict[tuple[int, int], float] = {}
        by_network: dict[int, dict[str, Any]] = {}
        for group_id, search, snapshot in groups:
            mirror = search.player_network is search.enemy_network
            controllers = (
                ((0, search.player_network),)
                if mirror
                else (
                    (0, search.player_network),
                    (1, search.enemy_network),
                )
            )
            for side, network in controllers:
                feature = (
                    snapshot.player_features if side == 0 else snapshot.enemy_features
                )
                if not bool(
                    getattr(network.config, "adaptive_budget_head", False)
                ) or not hasattr(network, "evaluate_budget"):
                    score = 1.0
                    outputs[(group_id, side)] = score
                    if mirror:
                        outputs[(group_id, 1)] = score
                    continue
                bucket = by_network.setdefault(
                    id(network), {"network": network, "items": []}
                )
                bucket["items"].append((group_id, side, mirror, feature, search))
        for bucket in by_network.values():
            items = bucket["items"]
            network = bucket["network"]
            batch_size = max(item[4].config.inference_batch_size for item in items)
            for start in range(0, len(items), batch_size):
                batch = items[start : start + batch_size]
                scores = network.evaluate_budget([item[3] for item in batch])
                for (group_id, side, mirror, _, _), score in zip(
                    batch, scores, strict=True
                ):
                    outputs[(group_id, side)] = score
                    if mirror:
                        outputs[(group_id, 1)] = score
        return {
            group_id: max(outputs[(group_id, 0)], outputs[(group_id, 1)])
            for group_id, _, _ in groups
        }

    @staticmethod
    def _policy_entropy(policy: tuple[float, ...]) -> float:
        return -sum(
            probability * math.log(probability) for probability in policy if probability
        )

    def _choose_adaptive_depth(
        self, root: _TreeNode, router_score: float
    ) -> tuple[bool, str]:
        if not self.config.adaptive_search:
            return True, "adaptive-disabled"
        if self.config.max_depth <= 1:
            return False, "configured-root-only"
        if router_score >= self.config.adaptive_deep_threshold:
            return True, "learned-router"
        if root.online_exploitability >= self.config.adaptive_exploitability_threshold:
            return True, "root-online-exploitability"
        legal_payoffs = [
            root.payoff[player][enemy]
            for player in root.player_legal
            for enemy in root.enemy_legal
        ]
        payoff_spread = max(legal_payoffs) - min(legal_payoffs)
        entropy = self._policy_entropy(root.player_policy) + self._policy_entropy(
            root.enemy_policy
        )
        if (
            payoff_spread >= self.config.adaptive_payoff_spread_threshold
            and entropy >= 1.0
        ):
            return True, "root-payoff-uncertainty"
        if self.budget_rng.random() < self.config.adaptive_force_deep_fraction:
            return True, "forced-calibration-sample"
        return False, "router-stable-root"

    def _diagnostics(
        self, simulations: int, converged: bool, root: _TreeNode | None
    ) -> dict[str, float | int | str]:
        diagnostics: dict[str, float | int | str] = {
            "tree_nodes": self._expanded_nodes,
            "tree_simulations": simulations,
            "tree_max_depth": self._max_depth_reached,
            "chance_outcomes": self._chance_outcomes,
            "sampled_joint_coverage": (
                self._sampled_joint_pairs / self._possible_joint_pairs
                if self._possible_joint_pairs
                else 0.0
            ),
            "tree_converged": int(converged),
            "cross_root_batch_size": self._cross_root_batch_size,
            "cross_root_root_leaves": self._cross_root_root_leaves,
            "inference_cache_hits": self._inference_cache_stats["hits"],
            "inference_cache_misses": self._inference_cache_stats["misses"],
            "inference_cache_hit_rate": (
                self._inference_cache_stats["hits"]
                / max(1, sum(self._inference_cache_stats.values()))
            ),
            "deep_inference_calls": self._deep_inference_calls,
            "deep_inference_rows": self._deep_inference_rows,
            "deep_inference_waves": self._deep_inference_waves,
            "mean_deep_inference_batch": (
                self._deep_inference_rows / max(1, self._deep_inference_calls)
            ),
            "deep_full_inference_calls": self._deep_full_inference_calls,
            "deep_full_inference_rows": self._deep_full_inference_rows,
            "deep_full_inference_waves": self._deep_full_inference_waves,
            "mean_deep_full_inference_batch": (
                self._deep_full_inference_rows / max(1, self._deep_full_inference_calls)
            ),
            "deep_native_calls": self._deep_native_calls,
            "deep_native_rows": self._deep_native_rows,
            "deep_native_waves": self._deep_native_waves,
            "mean_deep_native_batch": (
                self._deep_native_rows / max(1, self._deep_native_calls)
            ),
            "deep_overlap_waves": self._deep_overlap_waves,
            "adaptive_deep_selected": int(self._adaptive_deep_selected),
            "adaptive_router_score": self._adaptive_router_score,
            "adaptive_reason": self._adaptive_reason,
            "deep_policy_change": self._deep_policy_change,
            "deep_action_changed": self._deep_action_changed,
            "deep_search_needed": self._deep_search_needed,
        }
        if root is not None:
            diagnostics["root_joint_actions"] = len(root.player_legal) * len(
                root.enemy_legal
            )
            diagnostics["root_solves"] = root.solve_count
            diagnostics["root_online_exploitability"] = root.online_exploitability
            diagnostics["root_final_exploitability"] = root.exploitability
            diagnostics["root_equilibrium_iterations"] = self.config.regret_iterations
            diagnostics["root_solver"] = solver_identity(
                self.config.rmplus_backend, self.config.cfr_plus_solves
            )
        return diagnostics

    def _fallback(
        self,
        player_policy: list[float],
        enemy_policy: list[float],
        value: float,
        transitions: int,
        simulations: int,
    ) -> SearchResult:
        return SearchResult(
            tuple(0.0 for _ in range(self.action_count)),
            tuple(0.0 for _ in range(self.action_count)),
            None,
            None,
            value,
            transitions,
            "rmplus-unavailable-on-semantic-divergence-v1",
            None,
            None,
            None,
            self._diagnostics(simulations, False, None),
            "search-semantic-divergence",
        )

    def _finish_root_frontier(
        self,
        root: _TreeNode,
        player_prior: list[float],
        enemy_prior: list[float],
        prior_value: float,
        transitions: int,
        sample_actions: bool,
    ) -> Generator[_Frontier, _FrontierResponse, SearchResult]:
        simulations = 0
        converged = False
        initial_player = tuple(root.player_policy)
        initial_enemy = tuple(root.enemy_policy)
        initial_value = root.root_value
        previous_player: tuple[float, ...] | None = initial_player
        previous_enemy: tuple[float, ...] | None = initial_enemy
        stable_updates = 0
        try:
            attempts_without_learning = 0
            while (
                self._adaptive_deep_selected
                and transitions < self.config.expansion_budget
            ):
                _, cost, learned = yield from self._simulate_frontier(
                    root, 0, self.config.expansion_budget - transitions
                )
                transitions += cost
                if learned:
                    simulations += 1
                    attempts_without_learning = 0
                    current_player = self._average_policy(
                        root.player_strategy_sum,
                        root.solve_count,
                        root.player_policy,
                    )
                    current_enemy = self._average_policy(
                        root.enemy_strategy_sum,
                        root.solve_count,
                        root.enemy_policy,
                    )
                    if previous_player is not None and previous_enemy is not None:
                        change = sum(
                            abs(left - right)
                            for left, right in zip(
                                current_player, previous_player, strict=True
                            )
                        ) + sum(
                            abs(left - right)
                            for left, right in zip(
                                current_enemy, previous_enemy, strict=True
                            )
                        )
                        stable_updates = (
                            stable_updates + 1
                            if change <= self.config.convergence_tolerance
                            else 0
                        )
                    previous_player = current_player
                    previous_enemy = current_enemy
                    if (
                        transitions >= self.config.minimum_expansion_budget
                        and self._max_depth_reached >= self.config.max_depth - 1
                        and stable_updates >= self.config.convergence_patience
                    ):
                        converged = True
                        break
                else:
                    attempts_without_learning += 1
                    if attempts_without_learning >= 64:
                        break
        except _TreeDivergence:
            return self._fallback(
                player_prior,
                enemy_prior,
                prior_value,
                transitions,
                simulations,
            )
        if self._adaptive_deep_selected:
            player_policy, enemy_policy, final_value, exploitability = (
                self._root_equilibrium(root)
            )
            root.player_policy = list(player_policy)
            root.enemy_policy = list(enemy_policy)
            root.root_value = final_value
            root.exploitability = exploitability
        else:
            player_policy = initial_player
            enemy_policy = initial_enemy
            final_value = initial_value
            exploitability = root.exploitability
        self._deep_policy_change = sum(
            abs(left - right)
            for left, right in zip(player_policy, initial_player, strict=True)
        ) + sum(
            abs(left - right)
            for left, right in zip(enemy_policy, initial_enemy, strict=True)
        )
        self._deep_action_changed = int(
            max(root.player_legal, key=lambda action: player_policy[action])
            != max(root.player_legal, key=lambda action: initial_player[action])
            or max(root.enemy_legal, key=lambda action: enemy_policy[action])
            != max(root.enemy_legal, key=lambda action: initial_enemy[action])
        )
        self._deep_search_needed = (
            int(
                self._deep_action_changed
                or self._deep_policy_change >= 0.25
                or abs(final_value - initial_value) >= 0.10
            )
            if self._adaptive_deep_selected
            else -1
        )
        if sample_actions:
            player_action = _sample(list(player_policy), self.selection_rng)
            enemy_action = _sample(list(enemy_policy), self.selection_rng)
        else:
            player_action = max(
                root.player_legal, key=lambda action: player_policy[action]
            )
            enemy_action = max(
                root.enemy_legal, key=lambda action: enemy_policy[action]
            )
        root_value = final_value
        legal_payoffs = [
            root.payoff[player][enemy]
            for player in root.player_legal
            for enemy in root.enemy_legal
        ]
        return SearchResult(
            player_policy,
            enemy_policy,
            player_action,
            enemy_action,
            root_value,
            transitions,
            (
                "simultaneous-matrix-tree-rust-cfrplus-pooled-node-v4"
                if self.config.cfr_plus_solves
                else "simultaneous-matrix-tree-rust-rmplus-pooled-node-v4"
                if self.config.rmplus_backend == RUST_RMPLUS_BACKEND
                else "simultaneous-matrix-tree-rmplus-pooled-node-v3"
            ),
            exploitability,
            max(legal_payoffs) - min(legal_payoffs),
            tuple(tuple(row) for row in root.payoff),
            self._diagnostics(simulations, converged, root),
        )

    def search(self, snapshot: Snapshot, sample_actions: bool = True) -> SearchResult:
        return self.search_many([self], [snapshot], sample_actions)[0]

    @classmethod
    def _finish_many(
        cls,
        jobs: list[
            tuple[
                int,
                SimultaneousTreeSearch,
                _TreeNode,
                list[float],
                list[float],
                float,
                int,
                bool,
            ]
        ],
    ) -> list[tuple[int, SearchResult]]:
        if not jobs:
            return []
        searches = {job[0]: job[1] for job in jobs}
        generators = {
            index: search._finish_root_frontier(
                root, player, enemy, value, transitions, sample
            )
            for index, search, root, player, enemy, value, transitions, sample in jobs
        }
        started: set[int] = set()
        responses: dict[int, _FrontierResponse] = {}
        waiting_full: dict[int, tuple[SimultaneousTreeSearch, list[Snapshot]]] = {}
        completed: dict[int, SearchResult] = {}
        inference_calls = inference_rows = inference_waves = 0
        full_inference_calls = full_inference_rows = full_inference_waves = 0
        native_calls = native_rows = native_waves = overlap_waves = 0
        native_executor = ThreadPoolExecutor(max_workers=1)
        while generators:
            frontiers: dict[int, _Frontier] = {}
            for index in sorted(generators):
                if index in waiting_full:
                    continue
                generator = generators[index]
                try:
                    if index in started:
                        frontier = generator.send(responses.pop(index))
                    else:
                        frontier = next(generator)
                        started.add(index)
                    frontiers[index] = frontier
                except StopIteration as stop:
                    completed[index] = stop.value
            for index in completed.keys() & generators.keys():
                del generators[index]
            native = [
                (index, frontier)
                for index, frontier in frontiers.items()
                if isinstance(frontier, _NativeFrontier)
            ]
            inference = [
                (index, searches[index], frontier.snapshots)
                for index, frontier in frontiers.items()
                if isinstance(frontier, _InferenceFrontier)
            ]
            for index, frontier in frontiers.items():
                if isinstance(frontier, _NodeInferenceFrontier):
                    waiting_full[index] = (searches[index], frontier.snapshots)
            full_inference: list[
                tuple[int, SimultaneousTreeSearch, list[Snapshot]]
            ] = []
            if native and not inference and len(native) > 1:
                split = len(native) // 2
                leading, native = native[:split], native[split:]
                leading_requests = [
                    request for _, frontier in leading for request in frontier.requests
                ]
                leading_snapshots = jobs[0][1].server.search_steps(leading_requests)
                native_calls += 1
                native_rows += len(leading_requests)
                native_waves += 1
                offset = 0
                for index, frontier in leading:
                    stop = offset + len(frontier.requests)
                    try:
                        next_frontier = generators[index].send(
                            leading_snapshots[offset:stop]
                        )
                    except StopIteration as stopped:
                        completed[index] = stopped.value
                        del generators[index]
                    else:
                        if isinstance(next_frontier, _InferenceFrontier):
                            inference.append(
                                (index, searches[index], next_frontier.snapshots)
                            )
                        elif isinstance(next_frontier, _NodeInferenceFrontier):
                            waiting_full[index] = (
                                searches[index],
                                next_frontier.snapshots,
                            )
                        else:
                            native.append((index, next_frontier))
                    offset = stop
            full_batch_limit = max(
                (
                    search.config.inference_batch_size
                    for search, _ in waiting_full.values()
                ),
                default=0,
            )
            if waiting_full and (
                len(waiting_full) >= full_batch_limit or (not native and not inference)
            ):
                full_inference = [
                    (index, search, snapshots)
                    for index, (search, snapshots) in sorted(waiting_full.items())
                ]
                waiting_full.clear()
            requests = [
                request for _, frontier in native for request in frontier.requests
            ]
            pending_native: Future[list[Snapshot]] | None = None
            snapshots: list[Snapshot] | None = None
            if requests and (inference or full_inference):
                pending_native = native_executor.submit(
                    jobs[0][1].server.search_steps, requests
                )
                overlap_waves += 1
            elif requests:
                snapshots = jobs[0][1].server.search_steps(requests)
            if inference:
                values, calls, rows = cls._pooled_successor_values(inference)
                responses.update(values)
                inference_calls += calls
                inference_rows += rows
                inference_waves += 1
            if full_inference:
                evaluated, calls, rows = cls._pooled_evaluate(full_inference)
                for index, (players, enemies, values) in evaluated.items():
                    responses[index] = list(zip(players, enemies, values, strict=True))
                full_inference_calls += calls
                full_inference_rows += rows
                full_inference_waves += 1
            if pending_native is not None:
                snapshots = pending_native.result()
            if snapshots is not None:
                offset = 0
                for index, frontier in native:
                    stop = offset + len(frontier.requests)
                    responses[index] = snapshots[offset:stop]
                    offset = stop
                native_calls += 1
                native_rows += len(requests)
                native_waves += 1
        native_executor.shutdown()
        enriched = []
        for index, result in sorted(completed.items()):
            search = searches[index]
            search._deep_inference_calls = inference_calls
            search._deep_inference_rows = inference_rows
            search._deep_inference_waves = inference_waves
            search._deep_full_inference_calls = full_inference_calls
            search._deep_full_inference_rows = full_inference_rows
            search._deep_full_inference_waves = full_inference_waves
            search._deep_native_calls = native_calls
            search._deep_native_rows = native_rows
            search._deep_native_waves = native_waves
            search._deep_overlap_waves = overlap_waves
            diagnostics = dict(result.diagnostics or {})
            diagnostics.update(
                {
                    "inference_cache_hits": search._inference_cache_stats["hits"],
                    "inference_cache_misses": search._inference_cache_stats["misses"],
                    "inference_cache_hit_rate": search._inference_cache_stats["hits"]
                    / max(1, sum(search._inference_cache_stats.values())),
                    "deep_inference_calls": inference_calls,
                    "deep_inference_rows": inference_rows,
                    "deep_inference_waves": inference_waves,
                    "mean_deep_inference_batch": inference_rows
                    / max(1, inference_calls),
                    "deep_full_inference_calls": full_inference_calls,
                    "deep_full_inference_rows": full_inference_rows,
                    "deep_full_inference_waves": full_inference_waves,
                    "mean_deep_full_inference_batch": full_inference_rows
                    / max(1, full_inference_calls),
                    "deep_native_calls": native_calls,
                    "deep_native_rows": native_rows,
                    "deep_native_waves": native_waves,
                    "mean_deep_native_batch": native_rows / max(1, native_calls),
                    "deep_overlap_waves": overlap_waves,
                }
            )
            enriched.append(
                (
                    index,
                    SearchResult(
                        result.player_policy,
                        result.enemy_policy,
                        result.player_action,
                        result.enemy_action,
                        result.root_value,
                        result.nodes,
                        result.solver,
                        result.exploitability,
                        result.payoff_spread,
                        result.payoff_matrix,
                        diagnostics,
                        result.failure,
                    ),
                )
            )
        return enriched

    @classmethod
    def search_many(
        cls,
        searches: list[SimultaneousTreeSearch],
        snapshots: list[Snapshot],
        sample_actions: bool = True,
    ) -> list[SearchResult]:
        """Batch root transitions and inference across independent live roots."""
        if not searches or len(searches) != len(snapshots):
            raise ValueError("search_many requires one search per snapshot")
        first = searches[0]
        if any(snapshot.done for snapshot in snapshots):
            raise ValueError("cannot search a terminal state")
        if any(
            search.server is not first.server
            or search.action_count != first.action_count
            for search in searches[1:]
        ):
            raise ValueError("cross-root batches require one server and action schema")
        root_evaluations, _, _ = cls._pooled_evaluate(
            [
                (index, search, [snapshot])
                for index, (search, snapshot) in enumerate(
                    zip(searches, snapshots, strict=True)
                )
            ]
        )
        player_priors = [
            root_evaluations[index][0][0] for index in range(len(searches))
        ]
        enemy_priors = [root_evaluations[index][1][0] for index in range(len(searches))]
        prior_values = [root_evaluations[index][2][0] for index in range(len(searches))]
        roots = [
            search._make_node(
                snapshot,
                (player_priors[index], enemy_priors[index], prior_values[index]),
            )
            for index, (search, snapshot) in enumerate(
                zip(searches, snapshots, strict=True)
            )
        ]
        specs = [
            search._expansion_spec(root, True)
            for search, root in zip(searches, roots, strict=True)
        ]
        requests = [request for _, root_requests in specs for request in root_requests]
        successors = first.server.search_steps(requests)
        offsets: list[tuple[int, int]] = []
        start = 0
        for _, root_requests in specs:
            end = start + len(root_requests)
            offsets.append((start, end))
            start = end
        good = [
            not any(
                successor.divergence is not None for successor in successors[left:right]
            )
            for left, right in offsets
        ]
        root_groups = [
            (index, searches[index], successors[left:right])
            for index, ((left, right), is_good) in enumerate(
                zip(offsets, good, strict=True)
            )
            if is_good
        ]
        root_values, _, _ = cls._pooled_successor_values(root_groups)
        adaptive_groups = [
            (index, searches[index], snapshots[index])
            for index, is_good in enumerate(good)
            if is_good and searches[index].config.adaptive_search
        ]
        router_scores = cls._pooled_budget_scores(adaptive_groups)
        results: list[SearchResult | None] = [None] * len(searches)
        finish_jobs = []
        batch_size = len(searches)
        for index, (search, root, spec, bounds, is_good) in enumerate(
            zip(searches, roots, specs, offsets, good, strict=True)
        ):
            left, right = bounds
            root_successors = successors[left:right]
            search._cross_root_batch_size = batch_size
            search._cross_root_root_leaves = len(root_successors)
            if not is_good:
                results[index] = search._fallback(
                    player_priors[index],
                    enemy_priors[index],
                    prior_values[index],
                    len(root_successors),
                    0,
                )
                continue
            transitions = search._install_expansion(
                root, spec[0], root_successors, root_values[index]
            )
            root.online_exploitability = root.exploitability
            player_policy, enemy_policy, value, exploitability = (
                search._root_equilibrium(root)
            )
            root.player_policy = list(player_policy)
            root.enemy_policy = list(enemy_policy)
            root.root_value = value
            root.exploitability = exploitability
            router_score = router_scores.get(index, 1.0)
            selected, reason = search._choose_adaptive_depth(root, router_score)
            search._adaptive_deep_selected = selected
            search._adaptive_router_score = router_score
            search._adaptive_reason = reason
            finish_jobs.append(
                (
                    index,
                    search,
                    root,
                    player_priors[index],
                    enemy_priors[index],
                    prior_values[index],
                    transitions,
                    sample_actions,
                )
            )
        for index, result in cls._finish_many(finish_jobs):
            results[index] = result
        if any(result is None for result in results):
            raise RuntimeError("cross-root scheduler left an unfinished search")
        return cast(list[SearchResult], results)
