"""Batched exhaustive-root search with a regret-matched simultaneous policy."""

from __future__ import annotations

import random
from collections.abc import Generator, Sequence
from concurrent.futures import Future, ThreadPoolExecutor
from dataclasses import dataclass, field
from typing import Any, TypeAlias, cast

from .decision_quality import shape_redundant_action_priors
from .native import SearchServer, Snapshot
from .network import BattleTransformer

PayoffMatrix: TypeAlias = list[list[float]]

_PARTY_MON_WIDTH = 22
_FULL_SIDE_WIDTH = 181
_PARTY_SIZE = 6
_FIGHT_ACTIONS = range(4)
_SWITCH_ACTIONS = range(4, 10)


@dataclass(frozen=True)
class SearchResult:
    player_policy: tuple[float, ...]
    enemy_policy: tuple[float, ...]
    player_action: int
    enemy_action: int
    root_value: float
    nodes: int
    solver: str
    exploitability: float | None
    payoff_spread: float | None
    payoff_matrix: tuple[tuple[float, ...], ...] | None
    diagnostics: dict[str, float | int] | None = None


@dataclass(frozen=True)
class JointSearchConfig:
    chance_samples_per_joint: int = 1
    max_depth: int = 1
    regret_iterations: int = 256
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


def _cap_switch_mass(
    policy: tuple[float, ...],
    priors: list[float],
    legal: list[int],
    cap: float,
) -> tuple[float, ...]:
    switches = [action for action in legal if action in _SWITCH_ACTIONS]
    recipients = [action for action in legal if action not in _SWITCH_ACTIONS]
    switch_mass = sum(policy[action] for action in switches)
    if not switches or not recipients or switch_mass <= cap:
        return policy
    result = list(policy)
    scale = cap / switch_mass
    for action in switches:
        result[action] *= scale
    removed = switch_mass - cap
    recipient_mass = sum(result[action] for action in recipients)
    if recipient_mass > 0:
        for action in recipients:
            result[action] += removed * result[action] / recipient_mass
    else:
        prior_mass = sum(priors[action] for action in recipients)
        for action in recipients:
            weight = (
                priors[action] / prior_mass if prior_mass > 0 else 1.0 / len(recipients)
            )
            result[action] += removed * weight
    return tuple(result)


def _switch_cap(advantage: float) -> float:
    if advantage <= 0.02:
        return 0.10
    if advantage <= 0.10:
        return 0.20
    return 0.30


def _gate_voluntary_switches(
    payoff: PayoffMatrix,
    player_policy: tuple[float, ...],
    enemy_policy: tuple[float, ...],
    player_priors: list[float],
    enemy_priors: list[float],
    player_legal: list[int],
    enemy_legal: list[int],
) -> tuple[tuple[float, ...], tuple[float, ...]]:
    player_moves = [action for action in player_legal if action in _FIGHT_ACTIONS]
    player_switches = [action for action in player_legal if action in _SWITCH_ACTIONS]
    enemy_moves = [action for action in enemy_legal if action in _FIGHT_ACTIONS]
    enemy_switches = [action for action in enemy_legal if action in _SWITCH_ACTIONS]
    if player_moves and player_switches:
        row_values = [
            sum(enemy_policy[enemy] * payoff[action][enemy] for enemy in enemy_legal)
            for action in range(len(payoff))
        ]
        advantage = max(row_values[action] for action in player_switches) - max(
            row_values[action] for action in player_moves
        )
        player_policy = _cap_switch_mass(
            player_policy, player_priors, player_legal, _switch_cap(advantage)
        )
    if enemy_moves and enemy_switches:
        column_values = [
            sum(
                player_policy[player] * payoff[player][action]
                for player in player_legal
            )
            for action in range(len(payoff))
        ]
        advantage = min(column_values[action] for action in enemy_moves) - min(
            column_values[action] for action in enemy_switches
        )
        enemy_policy = _cap_switch_mass(
            enemy_policy, enemy_priors, enemy_legal, _switch_cap(advantage)
        )
    return player_policy, enemy_policy


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


def _strategy(
    regrets: list[float], priors: list[float], legal: list[int]
) -> list[float]:
    positive = sum(max(0.0, regrets[action]) for action in legal)
    strategy = [0.0] * len(regrets)
    if positive > 0.0:
        for action in legal:
            strategy[action] = max(0.0, regrets[action]) / positive
        return strategy
    prior_total = sum(priors[action] for action in legal)
    if prior_total > 0.0:
        for action in legal:
            strategy[action] = priors[action] / prior_total
    else:
        for action in legal:
            strategy[action] = 1.0 / len(legal)
    return strategy


def solve_zero_sum_regret(
    payoff: PayoffMatrix,
    player_priors: list[float],
    enemy_priors: list[float],
    player_legal: list[int],
    enemy_legal: list[int],
    iterations: int,
) -> tuple[tuple[float, ...], tuple[float, ...], float, float]:
    """Approximate a zero-sum matrix equilibrium with regret matching+."""
    if iterations < 1:
        raise ValueError("regret iterations must be positive")
    action_count = len(payoff)
    player_regrets = [0.0] * action_count
    enemy_regrets = [0.0] * action_count
    player_sum = [0.0] * action_count
    enemy_sum = [0.0] * action_count
    for _ in range(iterations):
        player = _strategy(player_regrets, player_priors, player_legal)
        enemy = _strategy(enemy_regrets, enemy_priors, enemy_legal)
        for action in player_legal:
            player_sum[action] += player[action]
        for action in enemy_legal:
            enemy_sum[action] += enemy[action]
        row_values = [0.0] * action_count
        column_values = [0.0] * action_count
        for player_action in player_legal:
            row_values[player_action] = sum(
                enemy[enemy_action] * payoff[player_action][enemy_action]
                for enemy_action in enemy_legal
            )
        for enemy_action in enemy_legal:
            column_values[enemy_action] = sum(
                player[player_action] * payoff[player_action][enemy_action]
                for player_action in player_legal
            )
        value = sum(
            player[player_action] * row_values[player_action]
            for player_action in player_legal
        )
        for action in player_legal:
            player_regrets[action] = max(
                0.0, player_regrets[action] + row_values[action] - value
            )
        for action in enemy_legal:
            enemy_regrets[action] = max(
                0.0, enemy_regrets[action] + value - column_values[action]
            )
    player_average = tuple(value / iterations for value in player_sum)
    enemy_average = tuple(value / iterations for value in enemy_sum)
    row_best_response = max(
        sum(
            enemy_average[enemy_action] * payoff[player_action][enemy_action]
            for enemy_action in enemy_legal
        )
        for player_action in player_legal
    )
    column_best_response = min(
        sum(
            player_average[player_action] * payoff[player_action][enemy_action]
            for player_action in player_legal
        )
        for enemy_action in enemy_legal
    )
    value = sum(
        player_average[player_action]
        * enemy_average[enemy_action]
        * payoff[player_action][enemy_action]
        for player_action in player_legal
        for enemy_action in enemy_legal
    )
    return (
        player_average,
        enemy_average,
        value,
        row_best_response - column_best_response,
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
    def _feature_identity(feature: Sequence[int]) -> tuple[str, bytes | tuple[int, ...]]:
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
            player_policy = root_player[0]
            enemy_policy = root_enemy[0]
            return SearchResult(
                tuple(player_policy),
                tuple(enemy_policy),
                _sample(player_policy, self.selection_rng),
                _sample(enemy_policy, self.selection_rng),
                root_values[0],
                len(trajectories),
                "network-fallback-on-semantic-divergence-v1",
                None,
                None,
                None,
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
        player_policy, enemy_policy = _gate_voluntary_switches(
            payoff,
            player_policy,
            enemy_policy,
            root_player[0],
            root_enemy[0],
            player_legal,
            enemy_legal,
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
            solver="tactical-switch-gated-joint-regret-crn-v1",
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


_Frontier: TypeAlias = _NativeFrontier | _InferenceFrontier
_FrontierResponse: TypeAlias = list[Snapshot] | list[tuple[float, float]]


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
        self._evaluation_cache: dict[int, tuple[list[float], list[float], float]] = {}
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
        self._deep_native_calls = 0
        self._deep_native_rows = 0
        self._deep_native_waves = 0
        self._deep_overlap_waves = 0

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
            players, enemies, values = self._evaluate_many([snapshot])
            evaluation = (players[0], enemies[0], values[0])
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

    @staticmethod
    def _matrix_value(
        payoff: PayoffMatrix,
        player_policy: tuple[float, ...],
        enemy_policy: tuple[float, ...],
        player_legal: list[int],
        enemy_legal: list[int],
    ) -> float:
        return sum(
            player_policy[player] * enemy_policy[enemy] * payoff[player][enemy]
            for player in player_legal
            for enemy in enemy_legal
        )

    @staticmethod
    def _exploitability(
        payoff: PayoffMatrix,
        player_policy: tuple[float, ...],
        enemy_policy: tuple[float, ...],
        player_legal: list[int],
        enemy_legal: list[int],
    ) -> float:
        row_best = max(
            sum(enemy_policy[enemy] * payoff[player][enemy] for enemy in enemy_legal)
            for player in player_legal
        )
        column_best = min(
            sum(
                player_policy[player] * payoff[player][enemy] for player in player_legal
            )
            for enemy in enemy_legal
        )
        return row_best - column_best

    def _solve_node(self, node: _TreeNode) -> None:
        player: tuple[float, ...] = ()
        enemy: tuple[float, ...] = ()
        for _ in range(self.config.regret_iterations_per_update):
            raw_player = tuple(
                _strategy(
                    node.player_regrets,
                    node.player_priors,
                    node.player_legal,
                )
            )
            raw_enemy = tuple(
                _strategy(
                    node.enemy_regrets,
                    node.enemy_priors,
                    node.enemy_legal,
                )
            )
            player, enemy = _gate_voluntary_switches(
                node.payoff,
                raw_player,
                raw_enemy,
                node.player_priors,
                node.enemy_priors,
                node.player_legal,
                node.enemy_legal,
            )
            row_values = [0.0] * self.action_count
            column_values = [0.0] * self.action_count
            for player_action in node.player_legal:
                row_values[player_action] = sum(
                    enemy[enemy_action] * node.payoff[player_action][enemy_action]
                    for enemy_action in node.enemy_legal
                )
            for enemy_action in node.enemy_legal:
                column_values[enemy_action] = sum(
                    player[player_action] * node.payoff[player_action][enemy_action]
                    for player_action in node.player_legal
                )
            value = sum(
                player[player_action] * row_values[player_action]
                for player_action in node.player_legal
            )
            for action in node.player_legal:
                node.player_regrets[action] = max(
                    0.0,
                    node.player_regrets[action] + row_values[action] - value,
                )
                node.player_strategy_sum[action] += player[action]
            for action in node.enemy_legal:
                node.enemy_regrets[action] = max(
                    0.0,
                    node.enemy_regrets[action] + value - column_values[action],
                )
                node.enemy_strategy_sum[action] += enemy[action]
            node.solve_count += 1
        node.player_policy = player
        node.enemy_policy = enemy
        node.root_value = self._matrix_value(
            node.payoff,
            player,
            enemy,
            node.player_legal,
            node.enemy_legal,
        )
        node.exploitability = self._exploitability(
            node.payoff,
            player,
            enemy,
            node.player_legal,
            node.enemy_legal,
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
        """Evaluate side-canonical rows once per network identity and exact key."""
        outputs: dict[
            tuple[int, int, int], tuple[list[float], float]
        ] = {}
        known: dict[
            tuple[int, str, bytes | tuple[int, ...], int],
            tuple[list[float], float],
        ] = {}
        missing: dict[
            tuple[int, str, bytes | tuple[int, ...], int], dict[str, Any]
        ] = {}
        for group_id, search, snapshots in groups:
            # Preserve the historical per-root player-block/enemy-block order.
            for side, network in (
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
                    key = search._cache_key(network, feature, mask)
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
                            "network": network,
                            "feature": feature,
                            "mask": mask,
                            "consumers": [consumer],
                        }
        by_network: dict[int, list[tuple[Any, dict[str, Any]]]] = {}
        for key, item in missing.items():
            by_network.setdefault(id(item["network"]), []).append((key, item))
        calls = rows = 0
        for items in by_network.values():
            network = items[0][1]["network"]
            batch_size = max(
                consumer[3].config.inference_batch_size
                for _, item in items
                for consumer in item["consumers"]
            )
            for start in range(0, len(items), batch_size):
                batch = items[start : start + batch_size]
                policies, values = network.evaluate(
                    [item[1]["feature"] for item in batch],
                    [item[1]["mask"] for item in batch],
                )
                calls += 1
                rows += len(batch)
                for (key, item), policy, value in zip(
                    batch, policies, values, strict=True
                ):
                    cached = (policy, value)
                    known[key] = cached
                    for group_id, position, side, search in item["consumers"]:
                        search._inference_cache[key] = cached
                        outputs[(group_id, position, side)] = cached
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
        return results, calls, rows

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
        evaluated, calls, rows = cls._pooled_evaluate(active_groups)
        results = {}
        for group_id, _, snapshots in groups:
            active_values = iter(evaluated.get(group_id, ([], [], []))[2])
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

    def _mixed_policy(
        self, policy: tuple[float, ...], legal: list[int], visits: int
    ) -> list[float]:
        epsilon = max(0.02, self.config.exploration / ((visits + 1) ** 0.5))
        result = [0.0] * self.action_count
        for action in legal:
            result[action] = (1.0 - epsilon) * policy[action] + epsilon / len(legal)
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
            node.player_policy, node.player_legal, node.visits
        )
        enemy_policy = self._mixed_policy(
            node.enemy_policy, node.enemy_legal, node.visits
        )
        player_action = _sample(player_policy, self.selection_rng)
        enemy_action = _sample(enemy_policy, self.selection_rng)
        cost = 0
        pair = (player_action, enemy_action)
        if pair not in node.outcomes and remaining <= 0:
            return node.root_value, 0, False
        fresh = pair not in node.outcomes or (
            remaining > 0 and self.selection_rng.random() < self.config.chance_resample
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
                child = self._make_node(successor)
                node.children[successor.handle] = child
            if not child.expanded:
                expansion_cost = self._joint_cost(child)
                if cost + expansion_cost <= remaining:
                    cost += (yield from self._expand_frontier(child, False))
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
                child_value, child_cost, child_learned = yield from self._simulate_frontier(
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

    @staticmethod
    def _average_policy(
        strategy_sum: list[float], solves: int, fallback: tuple[float, ...]
    ) -> tuple[float, ...]:
        if solves <= 0:
            return fallback
        return tuple(value / solves for value in strategy_sum)

    def _diagnostics(
        self, simulations: int, converged: bool, root: _TreeNode | None
    ) -> dict[str, float | int]:
        diagnostics: dict[str, float | int] = {
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
            "deep_native_calls": self._deep_native_calls,
            "deep_native_rows": self._deep_native_rows,
            "deep_native_waves": self._deep_native_waves,
            "mean_deep_native_batch": (
                self._deep_native_rows / max(1, self._deep_native_calls)
            ),
            "deep_overlap_waves": self._deep_overlap_waves,
        }
        if root is not None:
            diagnostics["root_joint_actions"] = len(root.player_legal) * len(
                root.enemy_legal
            )
            diagnostics["root_solves"] = root.solve_count
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
            tuple(player_policy),
            tuple(enemy_policy),
            _sample(player_policy, self.selection_rng),
            _sample(enemy_policy, self.selection_rng),
            value,
            transitions,
            "network-fallback-on-semantic-divergence-v1",
            None,
            None,
            None,
            self._diagnostics(simulations, False, None),
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
        previous_player: tuple[float, ...] | None = None
        previous_enemy: tuple[float, ...] | None = None
        stable_updates = 0
        try:
            attempts_without_learning = 0
            while transitions < self.config.expansion_budget:
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
        player_policy = self._average_policy(
            root.player_strategy_sum, root.solve_count, root.player_policy
        )
        enemy_policy = self._average_policy(
            root.enemy_strategy_sum, root.solve_count, root.enemy_policy
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
        root_value = self._matrix_value(
            root.payoff,
            player_policy,
            enemy_policy,
            root.player_legal,
            root.enemy_legal,
        )
        exploitability = self._exploitability(
            root.payoff,
            player_policy,
            enemy_policy,
            root.player_legal,
            root.enemy_legal,
        )
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
            "simultaneous-matrix-tree-rmplus-v1",
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
        completed: dict[int, SearchResult] = {}
        inference_calls = inference_rows = inference_waves = 0
        native_calls = native_rows = native_waves = overlap_waves = 0
        native_executor = ThreadPoolExecutor(max_workers=1)
        while generators:
            frontiers: dict[int, _Frontier] = {}
            for index in sorted(generators):
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
            if native and not inference and len(native) > 1:
                split = len(native) // 2
                leading, native = native[:split], native[split:]
                leading_requests = [
                    request
                    for _, frontier in leading
                    for request in frontier.requests
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
                        else:
                            native.append((index, next_frontier))
                    offset = stop
            requests = [
                request for _, frontier in native for request in frontier.requests
            ]
            pending_native: Future[list[Snapshot]] | None = None
            snapshots: list[Snapshot] | None = None
            if requests and inference:
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
            search.server is not first.server or search.action_count != first.action_count
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
        player_priors = [root_evaluations[index][0][0] for index in range(len(searches))]
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
