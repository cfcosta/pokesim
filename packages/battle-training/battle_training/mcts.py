"""Stochastic simultaneous-move MCTS with Exp3 selection at each node."""

from __future__ import annotations

import math
import random
from dataclasses import dataclass, field

from .native import SearchServer, Snapshot
from .network import ACTION_COUNT, BattleTransformer


@dataclass(frozen=True)
class SearchConfig:
    simulations: int = 64
    max_depth: int = 4
    exp3_gamma: float = 0.12
    exp3_eta: float = 0.08


@dataclass(frozen=True)
class SearchResult:
    player_policy: tuple[float, ...]
    enemy_policy: tuple[float, ...]
    player_action: int
    enemy_action: int
    root_value: float
    nodes: int
    solver: str = "simultaneous-exp3-mcts-v1"
    exploitability: float | None = None
    payoff_spread: float | None = None
    payoff_matrix: tuple[tuple[float, ...], ...] | None = None


def legal_actions(mask: int) -> list[int]:
    return [action for action in range(ACTION_COUNT) if mask & (1 << action)]


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


def _normalize_visits(
    visits: list[int], priors: list[float], legal: list[int]
) -> tuple[float, ...]:
    total = sum(visits[action] for action in legal)
    if total:
        return tuple(
            visits[action] / total if action in legal else 0.0 for action in range(4)
        )
    prior_total = sum(priors[action] for action in legal)
    return tuple(
        priors[action] / prior_total if action in legal and prior_total else 0.0
        for action in range(4)
    )


@dataclass
class Node:
    snapshot: Snapshot
    player_priors: list[float]
    enemy_priors: list[float]
    leaf_value: float
    player_log_weights: list[float] = field(default_factory=lambda: [float("-inf")] * 4)
    enemy_log_weights: list[float] = field(default_factory=lambda: [float("-inf")] * 4)
    player_visits: list[int] = field(default_factory=lambda: [0] * 4)
    enemy_visits: list[int] = field(default_factory=lambda: [0] * 4)
    children: dict[tuple[int, int, str, str], Node] = field(default_factory=dict)

    def __post_init__(self) -> None:
        for action in legal_actions(self.snapshot.player_mask):
            self.player_log_weights[action] = math.log(
                max(self.player_priors[action], 1e-8)
            )
        for action in legal_actions(self.snapshot.enemy_mask):
            self.enemy_log_weights[action] = math.log(
                max(self.enemy_priors[action], 1e-8)
            )

    @staticmethod
    def _distribution(
        log_weights: list[float], legal: list[int], gamma: float
    ) -> list[float]:
        maximum = max(log_weights[action] for action in legal)
        weights = [0.0] * ACTION_COUNT
        for action in legal:
            weights[action] = math.exp(log_weights[action] - maximum)
        total = sum(weights)
        distribution = [0.0] * ACTION_COUNT
        for action in legal:
            exploitation = weights[action] / total
            distribution[action] = (1.0 - gamma) * exploitation + gamma / len(legal)
        return distribution

    def select(
        self, config: SearchConfig, rng: random.Random
    ) -> tuple[int, float, int, float]:
        player_legal = legal_actions(self.snapshot.player_mask)
        enemy_legal = legal_actions(self.snapshot.enemy_mask)
        player = self._distribution(
            self.player_log_weights, player_legal, config.exp3_gamma
        )
        enemy = self._distribution(
            self.enemy_log_weights, enemy_legal, config.exp3_gamma
        )
        player_action = _sample(player, rng)
        enemy_action = _sample(enemy, rng)
        return player_action, player[player_action], enemy_action, enemy[enemy_action]

    def update(
        self,
        player_action: int,
        player_probability: float,
        enemy_action: int,
        enemy_probability: float,
        value: float,
        config: SearchConfig,
    ) -> None:
        player_count = len(legal_actions(self.snapshot.player_mask))
        enemy_count = len(legal_actions(self.snapshot.enemy_mask))
        player_gain = (value + 1.0) * 0.5
        enemy_gain = (-value + 1.0) * 0.5
        self.player_log_weights[player_action] += (
            config.exp3_eta * player_gain / (player_probability * player_count)
        )
        self.enemy_log_weights[enemy_action] += (
            config.exp3_eta * enemy_gain / (enemy_probability * enemy_count)
        )
        self.player_log_weights[player_action] = max(
            -40.0, min(40.0, self.player_log_weights[player_action])
        )
        self.enemy_log_weights[enemy_action] = max(
            -40.0, min(40.0, self.enemy_log_weights[enemy_action])
        )
        self.player_visits[player_action] += 1
        self.enemy_visits[enemy_action] += 1


class SimultaneousMCTS:
    """Sampled-chance tree search; the server alone executes transitions."""

    def __init__(
        self,
        server: SearchServer,
        player_network: BattleTransformer,
        enemy_network: BattleTransformer,
        config: SearchConfig,
        selection_rng: random.Random,
        chance_rng: random.Random,
    ) -> None:
        self.server = server
        self.player_network = player_network
        self.enemy_network = enemy_network
        self.config = config
        self.selection_rng = selection_rng
        self.chance_rng = chance_rng
        self.node_count = 0

    def _evaluate(self, snapshot: Snapshot) -> tuple[list[float], list[float], float]:
        if self.player_network is self.enemy_network:
            policies, values = self.player_network.evaluate(
                [snapshot.player_features, snapshot.enemy_features],
                [snapshot.player_mask, snapshot.enemy_mask],
            )
            return (
                policies[0],
                policies[1],
                max(-1.0, min(1.0, (values[0] - values[1]) / 2)),
            )
        player_policy, player_value = self.player_network.evaluate(
            [snapshot.player_features], [snapshot.player_mask]
        )
        enemy_policy, enemy_value = self.enemy_network.evaluate(
            [snapshot.enemy_features], [snapshot.enemy_mask]
        )
        return (
            player_policy[0],
            enemy_policy[0],
            max(-1.0, min(1.0, (player_value[0] - enemy_value[0]) / 2)),
        )

    def _node(self, snapshot: Snapshot) -> Node:
        player, enemy, value = self._evaluate(snapshot)
        self.node_count += 1
        return Node(snapshot, player, enemy, value)

    def _simulate(self, node: Node, depth: int) -> float:
        if node.snapshot.done:
            return float(node.snapshot.terminal_return or 0)
        player, player_probability, enemy, enemy_probability = node.select(
            self.config, self.selection_rng
        )
        successor = self.server.search_step(
            node.snapshot.handle, player, enemy, self.chance_rng.getrandbits(63)
        )
        if successor.done:
            value = float(successor.terminal_return or 0)
        else:
            key = (player, enemy, successor.player_hash, successor.enemy_hash)
            child = node.children.get(key)
            if child is None:
                child = self._node(successor)
                node.children[key] = child
                value = child.leaf_value
            elif depth + 1 >= self.config.max_depth:
                value = child.leaf_value
            else:
                value = self._simulate(child, depth + 1)
        node.update(
            player,
            player_probability,
            enemy,
            enemy_probability,
            value,
            self.config,
        )
        return value

    def search(self, snapshot: Snapshot, sample_actions: bool = True) -> SearchResult:
        self.node_count = 0
        if snapshot.done:
            raise ValueError("cannot search a terminal state")
        root = self._node(snapshot)
        values = [self._simulate(root, 0) for _ in range(self.config.simulations)]
        player_policy = _normalize_visits(
            root.player_visits, root.player_priors, legal_actions(snapshot.player_mask)
        )
        enemy_policy = _normalize_visits(
            root.enemy_visits, root.enemy_priors, legal_actions(snapshot.enemy_mask)
        )
        if sample_actions:
            player_action = _sample(list(player_policy), self.selection_rng)
            enemy_action = _sample(list(enemy_policy), self.selection_rng)
        else:
            player_action = max(range(4), key=lambda action: player_policy[action])
            enemy_action = max(range(4), key=lambda action: enemy_policy[action])
        return SearchResult(
            player_policy,
            enemy_policy,
            player_action,
            enemy_action,
            sum(values) / len(values),
            self.node_count,
        )
