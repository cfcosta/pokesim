"""Batched exhaustive-root search with a regret-matched simultaneous policy."""

from __future__ import annotations

import random
from dataclasses import dataclass
from typing import TypeAlias

from .mcts import SearchResult, legal_actions
from .native import SearchServer, Snapshot
from .network import ACTION_COUNT, BattleTransformer

PayoffMatrix: TypeAlias = list[list[float]]


@dataclass(frozen=True)
class JointSearchConfig:
    chance_samples_per_joint: int = 8
    max_depth: int = 4
    regret_iterations: int = 256
    inference_batch_size: int = 96


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
    strategy = [0.0] * ACTION_COUNT
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
    player_regrets = [0.0] * ACTION_COUNT
    enemy_regrets = [0.0] * ACTION_COUNT
    player_sum = [0.0] * ACTION_COUNT
    enemy_sum = [0.0] * ACTION_COUNT
    for _ in range(iterations):
        player = _strategy(player_regrets, player_priors, player_legal)
        enemy = _strategy(enemy_regrets, enemy_priors, enemy_legal)
        for action in player_legal:
            player_sum[action] += player[action]
        for action in enemy_legal:
            enemy_sum[action] += enemy[action]
        row_values = [0.0] * ACTION_COUNT
        column_values = [0.0] * ACTION_COUNT
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
        self.server = server
        self.player_network = player_network
        self.enemy_network = enemy_network
        self.config = config
        self.selection_rng = selection_rng
        self.chance_rng = chance_rng

    @staticmethod
    def _network_batches(
        network: BattleTransformer,
        features: list[tuple[int, ...]],
        masks: list[int],
        batch_size: int,
    ) -> tuple[list[list[float]], list[float]]:
        policies: list[list[float]] = []
        values: list[float] = []
        for start in range(0, len(features), batch_size):
            batch_policies, batch_values = network.evaluate(
                features[start : start + batch_size],
                masks[start : start + batch_size],
            )
            policies.extend(batch_policies)
            values.extend(batch_values)
        return policies, values

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
        combined = [
            max(-1.0, min(1.0, (player - enemy) / 2.0))
            for player, enemy in zip(player_values, enemy_values, strict=True)
        ]
        return player_policies, enemy_policies, combined

    def search(self, snapshot: Snapshot, sample_actions: bool = True) -> SearchResult:
        if snapshot.done:
            raise ValueError("cannot search a terminal state")
        root_player, root_enemy, _ = self._evaluate_many([snapshot])
        player_legal = legal_actions(snapshot.player_mask)
        enemy_legal = legal_actions(snapshot.enemy_mask)
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
                    values[index] = value
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
        payoff: PayoffMatrix = [[0.0] * ACTION_COUNT for _ in range(ACTION_COUNT)]
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
            solver="batched-joint-regret-crn-v1",
            exploitability=exploitability,
            payoff_spread=max(legal_payoffs) - min(legal_payoffs),
            payoff_matrix=tuple(tuple(row) for row in payoff),
        )
