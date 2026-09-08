"""Batched exhaustive-root search with a regret-matched simultaneous policy."""

from __future__ import annotations

import math
import random
import time
from collections.abc import Sequence
from dataclasses import dataclass, field
from typing import Any, cast

import numpy as np
from numpy.typing import NDArray

from .decision_quality import shape_redundant_action_priors
from .native import SearchServer, Snapshot
from .network import BattleTransformer
from .rmplus_native import (
    PYTHON_REFERENCE_BACKEND,
    RUST_RMPLUS_BACKEND,
    solver_identity,
)
from .rmplus_native import (
    solve_anchored as solve_anchored_native,
)
from .rmplus_native import (
    solve_cold as solve_cold_native,
)
from .rmplus_native import (
    solve_warm as solve_warm_native,
)

type PayoffMatrix = list[list[float]]

# The smallest positive f64, matching the native kernel's log floor exactly so
# the two implementations agree bit for bit on degenerate priors.
_LOG_FLOOR = float(np.finfo(np.float64).tiny)
# Smallest share the prior anchor may assign to any legal action; see
# `_floored_prior` for why an exact zero cannot be allowed through.
_ANCHOR_FLOOR = 1e-9

_PARTY_MON_WIDTH = 22
_FULL_SIDE_WIDTH = 181
_PARTY_SIZE = 6
_SPLIT_HALVES = 2

# Canonical row offsets, pinned against the encoder itself by the layout
# guards in `Battle/RL/FullTraining.lean`.
_MON_HP = 1
_MON_STATUS = 3
_MON_MOVES = 7
_MON_MAX_HP = 13
_MON_PP = 18
_MOVE_SLOTS = 4
_ACTIVE_INDEX_OFFSET = _PARTY_MON_WIDTH * _PARTY_SIZE
_ACTIVE_MON_OFFSET = _ACTIVE_INDEX_OFFSET + 1
_ACTIVE_STAGE_OFFSET = _ACTIVE_MON_OFFSET + _PARTY_MON_WIDTH + 4
_STAGE_COUNT = 6
_NEUTRAL_STAGE = 7
_STAGE_BAND = 6

# Cartridge PP packing: the low six bits are the remaining uses and the top
# two are the mon's PP Ups, which are roster trivia rather than battle state.
_PP_MASK = 0x3F
# A move slot at or above this many remaining uses is treated as unconstrained;
# below it the reserve term supplies a per-use gradient into the Struggle cliff.
_PP_REFERENCE = 16

_ALIVE_WEIGHT = 0.10
_STATUS_WEIGHT = 0.05
_USABLE_MOVE_WEIGHT = 0.10
_PP_RESERVE_WEIGHT = 0.05
_STAGE_WEIGHT = 0.02


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
    interior_actions_per_side: int = 3
    interior_chance_samples: int = 1
    regret_iterations_per_update: int = 16
    redundant_action_prior_scale: float = 1.0
    prior_anchor_temperature: float = 0.02
    rmplus_backend: str = PYTHON_REFERENCE_BACKEND
    cfr_plus_solves: bool = False
    split_half_reliability: bool = False
    prior_regret: bool = False
    leaf_evaluator: str = "full"
    solver_backend: str = "auto"
    solver_precision: str = "fp32"
    orchestration_backend: str = "python"


def legal_actions(mask: int, action_count: int) -> list[int]:
    return [action for action in range(action_count) if mask & (1 << action)]


@dataclass(frozen=True)
class RootPriorNoise:
    """AlphaZero-style Dirichlet mixing for root priors on collection solves."""

    alpha: float
    weight: float
    rng: random.Random
    total: float = 0.0


def _dirichlet_noised_priors(
    priors: Sequence[float], mask: int, noise: RootPriorNoise
) -> Sequence[float]:
    # Mixes a Dirichlet(alpha) draw into the LEGAL support only, rescaled so
    # the legal prior mass (and therefore the full-vector sum) is preserved;
    # illegal entries keep their exact input values. A positive total spreads
    # a fixed concentration across the legal support (alpha = total / n),
    # matching AlphaZero's inverse scaling with the legal-move count.
    legal = legal_actions(mask, len(priors))
    if not legal:
        return priors
    alpha = noise.total / len(legal) if noise.total > 0.0 else noise.alpha
    samples = [noise.rng.gammavariate(alpha, 1.0) for _ in legal]
    total = sum(samples)
    if total <= 0.0:
        return priors
    legal_mass = sum(priors[action] for action in legal)
    noised = list(priors)
    for action, sample in zip(legal, samples, strict=True):
        noised[action] = (1.0 - noise.weight) * priors[
            action
        ] + noise.weight * legal_mass * (sample / total)
    return noised


@dataclass(frozen=True)
class _SidePotentials:
    """The per-side quantities the tactical potential differences.

    Every field is one value per row of the batch, so the difference that
    forms the potential is a handful of vector operations rather than one
    Python scan per position.
    """

    hp: NDArray[np.float64]
    alive: NDArray[np.int64]
    statused: NDArray[np.int64]
    usable_moves: NDArray[np.float64]
    pp_reserve: NDArray[np.float64]
    stages: NDArray[np.float64]


def _side_potentials(rows: NDArray[np.int64], offset: int) -> _SidePotentials:
    # The six party rows are cartridge storage. `SideState.syncOutgoing` copies
    # the battle mon back into its row only on switch-out and faint, so the
    # row belonging to `activeIndex` still holds pre-battle HP, status and PP
    # for the whole time that mon is fighting. Read it from the active block
    # instead, which is the authoritative live copy.
    active_index = rows[:, offset + _ACTIVE_INDEX_OFFSET][:, None]
    slots = np.arange(_PARTY_SIZE)[None, :]
    bases = np.where(
        slots == active_index,
        offset + _ACTIVE_MON_OFFSET,
        offset + slots * _PARTY_MON_WIDTH,
    )

    def column(field: int) -> NDArray[np.int64]:
        return np.take_along_axis(rows, bases + field, axis=1)

    def move_columns(field: int) -> NDArray[np.int64]:
        return np.stack([column(field + move) for move in range(_MOVE_SLOTS)], axis=2)

    hp = column(_MON_HP)
    # A fainted mon still contributes its (zero) HP share before being skipped
    # for everything else, exactly as the per-slot scan did.
    hp_fraction = (hp / np.maximum(1, column(_MON_MAX_HP))).sum(axis=1)
    live = hp > 0
    known_slots = move_columns(_MON_MOVES) != 0
    pp = move_columns(_MON_PP) & _PP_MASK
    known = known_slots.sum(axis=2)
    counted = live & (known > 0)
    # Guards the division for slots that are about to be masked away anyway.
    denominator = np.maximum(1, known)
    with_pp = (known_slots & (pp > 0)).sum(axis=2)
    remaining = np.where(known_slots, pp, 0).sum(axis=2)
    stages = rows[
        :,
        offset + _ACTIVE_STAGE_OFFSET : offset + _ACTIVE_STAGE_OFFSET + _STAGE_COUNT,
    ]
    stages = np.clip(stages, _NEUTRAL_STAGE - _STAGE_BAND, _NEUTRAL_STAGE + _STAGE_BAND)
    return _SidePotentials(
        hp=hp_fraction / _PARTY_SIZE,
        alive=live.sum(axis=1),
        statused=(live & (column(_MON_STATUS) != 0)).sum(axis=1),
        usable_moves=np.where(counted, with_pp / denominator, 0.0).sum(axis=1)
        / _PARTY_SIZE,
        pp_reserve=np.where(
            counted, np.minimum(1.0, remaining / (denominator * _PP_REFERENCE)), 0.0
        ).sum(axis=1)
        / _PARTY_SIZE,
        stages=((stages - _NEUTRAL_STAGE) / _STAGE_BAND).sum(axis=1),
    )


def _tactical_potentials(batch: Sequence[Sequence[int]]) -> NDArray[np.float64]:
    """Dense, antisymmetric potential over HP, faints, status, PP and stages.

    PP earns two terms because it fails in two ways. `usable_moves` is the
    fraction of a mon's real move slots that still have a use left, so it
    reaches zero exactly when that mon is forced to Struggle -- the cliff
    `Battle/Full/Action.lean` proves. `pp_reserve` grades the approach to that
    cliff, so a long attrition race has a per-turn gradient instead of a flat
    landscape terminated by one discontinuity.

    Search prices whole batches of leaves at once, so this reads a batch. A
    tree spends this once per level-set rather than once per leaf, which is
    what keeps the shaping cost flat as depth grows the tree underneath it.
    """

    if len(batch) == 0:
        return np.zeros(0, dtype=np.float64)
    rows = np.asarray(batch, dtype=np.int64)
    own = _side_potentials(rows, 0)
    foe = _side_potentials(rows, _FULL_SIDE_WIDTH)
    return (
        own.hp
        - foe.hp
        + _ALIVE_WEIGHT * (own.alive - foe.alive) / _PARTY_SIZE
        + _STATUS_WEIGHT * (foe.statused - own.statused) / _PARTY_SIZE
        + _USABLE_MOVE_WEIGHT * (own.usable_moves - foe.usable_moves)
        + _PP_RESERVE_WEIGHT * (own.pp_reserve - foe.pp_reserve)
        + _STAGE_WEIGHT * (own.stages - foe.stages)
    )


def _tactical_potential(features: Sequence[int]) -> float:
    """One position's tactical potential, for the callers that hold only one.

    Deliberately a wrapper rather than a second implementation: the batched
    form is what search prices leaves with, and two scans of the same layout
    would be free to drift apart under exactly the edits this file invites.
    """

    return float(_tactical_potentials([features])[0])


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


def _soft_normalize(logits: np.ndarray) -> np.ndarray:
    weights = np.exp(logits - logits.max())
    return weights / weights.sum()


def _floored_prior(priors: list[float], legal: list[int]) -> np.ndarray:
    """The normalized prior with every action held above `_ANCHOR_FLOOR`.

    KL to an exact zero is infinite, so an unfloored anchor would turn a head
    that emitted 0.0 into a hard ban rather than a strong preference.  At the
    temperatures we ship the floor caps the anchor's pull at roughly 0.4 payoff
    units, well inside the [-1, 1] range a decisive matrix can produce.
    """
    values = np.maximum(_normalized_prior(priors, legal), _ANCHOR_FLOOR)
    return values / values.sum()


def solve_anchored_zero_sum(
    payoff: PayoffMatrix,
    player_priors: list[float],
    enemy_priors: list[float],
    player_legal: list[int],
    enemy_legal: list[int],
    iterations: int,
    temperature: float,
) -> tuple[tuple[float, ...], tuple[float, ...], float, float]:
    """Solve the prior-anchored saddle `pi' M mu - t*KL(pi||p) + t*KL(mu||q)`.

    Plain regret matching hands back an arbitrary point of the equilibrium set,
    so wherever the matrix is indifferent -- which is most of a search tree --
    the network prior has no say in what gets played.  The KL terms make the
    saddle strictly convex-concave: the solution is unique, moves continuously
    with the payoff, and falls back to the prior exactly where the matrix has
    nothing to say.  The iteration is KL-proximal extragradient; the half step
    cancels the rotation that leaves plain best response orbiting the solution.
    """
    if iterations < 1:
        raise ValueError("regret iterations must be positive")
    if not player_legal or not enemy_legal:
        raise ValueError("each side needs at least one legal action")
    if not math.isfinite(temperature) or temperature <= 0.0:
        raise ValueError("anchor temperature must be finite and positive")
    action_count = len(payoff)
    matrix = np.asarray(payoff, dtype=np.float64)[np.ix_(player_legal, enemy_legal)]
    player = _floored_prior(player_priors, player_legal)
    enemy = _floored_prior(enemy_priors, enemy_legal)
    log_player_prior = np.log(player)
    log_enemy_prior = np.log(enemy)
    # Convergence needs step * max|M| <= 1; search payoffs are clamped to
    # [-1, 1] so this is 1.0 in practice and only shrinks defensively.
    step = 1.0 / max(1.0, float(np.abs(matrix).max()))
    scale = 1.0 / (1.0 + step * temperature)

    def prox(current: np.ndarray, log_anchor: np.ndarray, gradient: np.ndarray):
        return _soft_normalize(
            scale
            * (
                step * gradient
                + step * temperature * log_anchor
                + np.log(np.maximum(current, _LOG_FLOOR))
            )
        )

    for _ in range(iterations):
        half_player = prox(player, log_player_prior, matrix @ enemy)
        half_enemy = prox(enemy, log_enemy_prior, -(player @ matrix))
        # Both full steps leave from the same base point with the gradient read
        # at the half point -- that ordering is the extragradient correction.
        player, enemy = (
            prox(player, log_player_prior, matrix @ half_enemy),
            prox(enemy, log_enemy_prior, -(half_player @ matrix)),
        )

    player_average = [0.0] * action_count
    enemy_average = [0.0] * action_count
    for index, action in enumerate(player_legal):
        player_average[action] = float(player[index])
    for index, action in enumerate(enemy_legal):
        enemy_average[action] = float(enemy[index])
    row_values = matrix @ enemy
    column_values = player @ matrix
    return (
        tuple(player_average),
        tuple(enemy_average),
        float(player @ row_values),
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
        if not 0.0 <= config.prior_anchor_temperature <= 1.0:
            raise ValueError("prior_anchor_temperature must be in [0, 1]")
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
                potentials = _tactical_potentials(
                    [trajectories[index].player_features for index in active_indexes]
                ).tolist()
                for index, value, potential in zip(
                    active_indexes, leaf_values, potentials, strict=True
                ):
                    tactical_delta = potential - root_potential
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
class _TreeNode:
    snapshot: Snapshot
    player_priors: list[float]
    enemy_priors: list[float]
    leaf_value: float
    player_legal: list[int]
    enemy_legal: list[int]
    payoff: PayoffMatrix
    counts: list[list[int]]
    player_policy: tuple[float, ...] = ()
    enemy_policy: tuple[float, ...] = ()
    root_value: float = 0.0
    exploitability: float = 0.0
    online_exploitability: float = 0.0
    expanded: bool = False
    solve_count: int = 0
    solve_backend: str = ""
    player_strategy_sum: list[float] = field(default_factory=list)
    enemy_strategy_sum: list[float] = field(default_factory=list)
    player_regrets: list[float] = field(default_factory=list)
    enemy_regrets: list[float] = field(default_factory=list)
    sampled_pairs: set[tuple[int, int]] = field(default_factory=set)
    half_payoff: list[PayoffMatrix] = field(default_factory=list)
    half_counts: list[list[list[int]]] = field(default_factory=list)


@dataclass
class _Expansion:
    """One node's sampled successors, held open until the values arrive.

    `children[i]` is the subgame opened on successor `i`, or None when that
    successor ended the battle, sat at the depth limit, or came back from a
    step the engine flagged as divergent. `values[i]` is what the successor is
    worth to the root once it settles, whichever way it got there.
    """

    root: int
    node: _TreeNode
    samples: list[tuple[int, int, int]]
    successors: list[Snapshot]
    children: list[_TreeNode | None] = field(default_factory=list)
    values: list[float | None] = field(default_factory=list)

    def __post_init__(self) -> None:
        self.children = [None] * len(self.successors)
        self.values = [None] * len(self.successors)


class SimultaneousTreeSearch(BatchedJointRegretSearch):
    """A regular tree of exhaustive matrices, each solved to an equilibrium.

    Every legal joint pair at the root is stepped and evaluated, so each cell of
    the payoff matrix rests on the same number of chance samples as every other.
    Past the root the rule stays uniform rather than selective: `max_depth`
    levels down, *every* cell of *every* matrix opens its own subgame at
    `interior_actions_per_side` wide, and the equilibrium value of that subgame
    is what the parent cell is worth.  The regularity is the whole point -- an
    expansion that refined only the cells the current policy already likes would
    replace balanced estimates with lopsided ones and move the root solve for
    reasons that have nothing to do with the position.

    Deeper matrices explicitly simulate responses that a shallow search must
    estimate through the learned continuation value. Interior action selection
    and finite chance sampling are approximations; solving those matrices does
    not establish an equilibrium of the complete battle.
    """

    def __init__(
        self,
        server: SearchServer,
        player_network: BattleTransformer,
        enemy_network: BattleTransformer,
        config: JointSearchConfig,
        selection_rng: random.Random,
        chance_rng: random.Random,
        prior_noise: RootPriorNoise | None = None,
        *,
        evaluation_side: str = "player",
    ) -> None:
        super().__init__(
            server,
            player_network,
            enemy_network,
            config,
            selection_rng,
            chance_rng,
        )
        if evaluation_side not in {"player", "enemy"}:
            raise ValueError("evaluation_side must be player or enemy")
        if config.leaf_evaluator not in {"full", "distilled"}:
            raise ValueError("leaf_evaluator must be full or distilled")
        if config.solver_backend not in {"auto", "rust", "cuda"}:
            raise ValueError("solver_backend must be auto, rust or cuda")
        if config.solver_precision not in {"fp32", "fp64"}:
            raise ValueError("solver_precision must be fp32 or fp64")
        if config.orchestration_backend not in {"python", "rust"}:
            raise ValueError("orchestration_backend must be python or rust")
        self.evaluation_side = evaluation_side
        if config.regret_iterations_per_update < 1:
            raise ValueError("tree regret iterations per update must be positive")
        if config.interior_actions_per_side < 1:
            raise ValueError("interior actions per side must be positive")
        if config.interior_chance_samples < 1:
            raise ValueError("interior chance samples must be positive")
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
        self._leaf_joint_inference_cache: dict[
            tuple[int, str, bytes | tuple[int, ...], int, int],
            tuple[list[float], list[float], float],
        ] = {}
        self._expanded_nodes = 0
        self._chance_outcomes = 0
        self._sampled_joint_pairs = 0
        self._possible_joint_pairs = 0
        self._cross_root_batch_size = 1
        self._cross_root_root_leaves = 0
        self.prior_noise = prior_noise
        self._split_half_available = 0
        self._split_half_player_distance = 0.0
        self._split_half_enemy_distance = 0.0
        self._split_half_value_gap = 0.0
        self._prior_regret_noise = 0.0
        self._enemy_prior_regret_noise = 0.0
        self._interior_nodes = 0
        self._interior_divergences = 0
        self._solver_backends: dict[str, int] = {}
        self._solver_seconds = 0.0

    def _legal_from_priors(
        self, mask: int, priors: list[float], width: int
    ) -> list[int]:
        actions = legal_actions(mask, self.action_count)
        return sorted(actions, key=lambda action: (-priors[action], action))[:width]

    def _make_node(
        self,
        snapshot: Snapshot,
        evaluation: tuple[list[float], list[float], float] | None = None,
        width: int | None = None,
    ) -> _TreeNode:
        if evaluation is None:
            evaluation = self._evaluation_cache.get(snapshot.handle)
        if evaluation is None:
            raise RuntimeError("tree node construction requires pooled full evaluation")
        if width is None:
            width = self.config.max_actions_per_side
        player_priors, enemy_priors, leaf_value = evaluation
        self._evaluation_cache[snapshot.handle] = evaluation
        player_legal = self._legal_from_priors(
            snapshot.player_mask, player_priors, width
        )
        enemy_legal = self._legal_from_priors(snapshot.enemy_mask, enemy_priors, width)
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
        if self.config.split_half_reliability:
            for _ in range(_SPLIT_HALVES):
                half = [[0.0] * self.action_count for _ in range(self.action_count)]
                for player_action in player_legal:
                    for enemy_action in enemy_legal:
                        half[player_action][enemy_action] = leaf_value
                node.half_payoff.append(half)
                node.half_counts.append(
                    [[0] * self.action_count for _ in range(self.action_count)]
                )
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

    def _solve_matrix_reference(
        self, node: _TreeNode, payoff: PayoffMatrix
    ) -> tuple[tuple[float, ...], tuple[float, ...], float, float]:
        temperature = self.config.prior_anchor_temperature
        if temperature > 0.0:
            if self.config.rmplus_backend == RUST_RMPLUS_BACKEND:
                return solve_anchored_native(
                    payoff,
                    node.player_priors,
                    node.enemy_priors,
                    node.player_legal,
                    node.enemy_legal,
                    self.config.regret_iterations,
                    temperature=temperature,
                )
            return solve_anchored_zero_sum(
                payoff,
                node.player_priors,
                node.enemy_priors,
                node.player_legal,
                node.enemy_legal,
                self.config.regret_iterations,
                temperature,
            )
        if self.config.rmplus_backend == RUST_RMPLUS_BACKEND:
            return solve_cold_native(
                payoff,
                node.player_priors,
                node.enemy_priors,
                node.player_legal,
                node.enemy_legal,
                self.config.regret_iterations,
                cfr_plus=self.config.cfr_plus_solves,
            )
        return solve_zero_sum_regret(
            payoff,
            node.player_priors,
            node.enemy_priors,
            node.player_legal,
            node.enemy_legal,
            self.config.regret_iterations,
        )

    def _solve_matrix(self, node: _TreeNode, payoff: PayoffMatrix):
        return self._solve_matrices([(self, node, payoff)])[0]

    @classmethod
    def _solve_matrices(
        cls, jobs: list[tuple[SimultaneousTreeSearch, _TreeNode, PayoffMatrix]]
    ):
        """Batch independent same-level games without changing their estimates."""
        from .solver_cuda import solve_anchored_batch

        groups: dict[tuple, list[int]] = {}
        results: list[Any] = [None] * len(jobs)
        for index, (search, _, _) in enumerate(jobs):
            config = search.config
            device = "cpu"
            if isinstance(search.player_network, BattleTransformer):
                device = str(next(search.player_network.parameters()).device)
            backend = config.solver_backend
            if backend == "auto" and not device.startswith("cuda"):
                backend = "rust"
            key = (
                search.action_count,
                config.regret_iterations,
                config.prior_anchor_temperature,
                config.rmplus_backend,
                config.cfr_plus_solves,
                backend,
                device,
                config.solver_precision,
            )
            groups.setdefault(key, []).append(index)
        for key, indexes in groups.items():
            (
                actions,
                iterations,
                temperature,
                arithmetic,
                _,
                backend,
                device,
                precision,
            ) = key
            started = time.perf_counter()
            if temperature > 0 and arithmetic == RUST_RMPLUS_BACKEND:
                player_masks = np.zeros((len(indexes), actions), dtype=np.bool_)
                enemy_masks = np.zeros_like(player_masks)
                for row, index in enumerate(indexes):
                    node = jobs[index][1]
                    player_masks[row, node.player_legal] = True
                    enemy_masks[row, node.enemy_legal] = True
                batch = solve_anchored_batch(
                    [jobs[index][2] for index in indexes],
                    [jobs[index][1].player_priors for index in indexes],
                    [jobs[index][1].enemy_priors for index in indexes],
                    player_masks,
                    enemy_masks,
                    iterations,
                    temperature,
                    backend=backend,
                    device=device if device.startswith("cuda") else None,
                    precision=precision,
                )
                for row, index in enumerate(indexes):
                    results[index] = batch.row(row)
                actual_backend = batch.backend
            else:
                if backend == "cuda":
                    raise ValueError(
                        "CUDA matrix solving requires the positive-temperature anchored solver"
                    )
                for index in indexes:
                    search, node, payoff = jobs[index]
                    results[index] = search._solve_matrix_reference(node, payoff)
                actual_backend = solver_identity(
                    arithmetic, jobs[indexes[0]][0].config.cfr_plus_solves, temperature
                )
            elapsed = time.perf_counter() - started
            for index in indexes:
                search = jobs[index][0]
                jobs[index][1].solve_backend = actual_backend
                search._solver_backends[actual_backend] = (
                    search._solver_backends.get(actual_backend, 0) + 1
                )
                search._solver_seconds += elapsed / len(indexes)
        return results

    def _half_is_covered(self, node: _TreeNode, half: int) -> bool:
        counts = node.half_counts[half]
        return all(
            counts[player][enemy] > 0
            for player in node.player_legal
            for enemy in node.enemy_legal
        )

    def _matrix_metrics(
        self,
        node: _TreeNode,
        payoff: PayoffMatrix,
        player_policy: Sequence[float],
        enemy_policy: Sequence[float],
    ) -> tuple[float, float]:
        """Value and exploitability of an arbitrary pair against the mean matrix."""
        matrix = np.asarray(payoff, dtype=np.float64)[
            np.ix_(node.player_legal, node.enemy_legal)
        ]
        player = np.asarray(
            [player_policy[action] for action in node.player_legal], dtype=np.float64
        )
        enemy = np.asarray(
            [enemy_policy[action] for action in node.enemy_legal], dtype=np.float64
        )
        row_values = matrix @ enemy
        column_values = player @ matrix
        return (
            float(player @ row_values),
            float(row_values.max() - column_values.min()),
        )

    def _prior_regret(
        self,
        node: _TreeNode,
        payoff: PayoffMatrix,
        player_policy: Sequence[float],
        enemy_policy: Sequence[float],
    ) -> tuple[float, float]:
        """Value each side gives up by playing its prior against the solution.

        The prior here is the one search itself consumed -- already redundancy
        shaped and restricted to the searched legal set -- so this is the exact
        cost of skipping the search at this state rather than a distance
        between two distributions. Unlike a policy KL it is bounded by the
        payoff range and it goes to zero when the solve is a near-tie, which is
        when a large KL against a near-pure sample means nothing.
        """
        matrix = np.asarray(payoff, dtype=np.float64)[
            np.ix_(node.player_legal, node.enemy_legal)
        ]
        player = _normalized_prior(list(player_policy), node.player_legal)
        enemy = _normalized_prior(list(enemy_policy), node.enemy_legal)
        player_prior = _normalized_prior(node.player_priors, node.player_legal)
        enemy_prior = _normalized_prior(node.enemy_priors, node.enemy_legal)
        row_values = matrix @ enemy
        column_values = -(player @ matrix)
        # Both solved policies best-respond within the solve, so each gap is
        # nonnegative up to solver error; the clamp absorbs only that error.
        return (
            max(0.0, float((player - player_prior) @ row_values)),
            max(0.0, float((enemy - enemy_prior) @ column_values)),
        )

    def _root_equilibrium(
        self,
        node: _TreeNode,
        solved: Any = None,
        half_solutions: Any = None,
    ) -> tuple[tuple[float, ...], tuple[float, ...], float, float]:
        """Solve the current root matrix without stale online-search averages.

        Split-half solves only measure uncertainty. The published strategy is
        always the solution to the mean payoff matrix.
        """
        player_policy, enemy_policy, value, exploitability = (
            self._solve_matrix(node, node.payoff) if solved is None else solved
        )
        if not self.config.split_half_reliability or not node.half_payoff:
            return player_policy, enemy_policy, value, exploitability
        self._split_half_available = 0
        self._split_half_player_distance = 0.0
        self._split_half_enemy_distance = 0.0
        self._split_half_value_gap = 0.0
        self._prior_regret_noise = 0.0
        self._enemy_prior_regret_noise = 0.0
        if not all(
            self._half_is_covered(node, half) for half in range(len(node.half_payoff))
        ):
            return player_policy, enemy_policy, value, exploitability
        halves = (
            half_solutions
            if half_solutions is not None
            else [
                self._solve_matrix(node, payoff)
                for payoff in node.half_payoff[:_SPLIT_HALVES]
            ]
        )
        first, second = halves[0], halves[1]
        self._split_half_available = 1
        self._split_half_player_distance = 0.5 * sum(
            abs(left - right) for left, right in zip(first[0], second[0], strict=True)
        )
        self._split_half_enemy_distance = 0.5 * sum(
            abs(left - right) for left, right in zip(first[1], second[1], strict=True)
        )
        self._split_half_value_gap = abs(first[2] - second[2])
        if self.config.prior_regret:
            # Each world is scored on its own matrix against its own solve, so
            # the spread between them is the noise in the published regret
            # rather than noise in some adjacent quantity.
            regrets = [
                self._prior_regret(node, payoff, solve[0], solve[1])
                for payoff, solve in zip(
                    node.half_payoff[:_SPLIT_HALVES], halves, strict=True
                )
            ]
            self._prior_regret_noise = abs(regrets[0][0] - regrets[1][0])
            self._enemy_prior_regret_noise = abs(regrets[0][1] - regrets[1][1])
        # The halves measure uncertainty. Actions and training labels must use
        # the solution to the expected payoff, not an average of solutions to
        # individually observed chance outcomes.
        return player_policy, enemy_policy, value, exploitability

    @staticmethod
    def _record_value(
        node: _TreeNode,
        player_action: int,
        enemy_action: int,
        value: float,
        half: int | None = None,
    ) -> None:
        count = node.counts[player_action][enemy_action]
        current = node.payoff[player_action][enemy_action]
        node.payoff[player_action][enemy_action] = (current * count + value) / (
            count + 1
        )
        node.counts[player_action][enemy_action] = count + 1
        if half is None or not node.half_payoff:
            return
        index = half % len(node.half_payoff)
        half_count = node.half_counts[index][player_action][enemy_action]
        half_current = node.half_payoff[index][player_action][enemy_action]
        node.half_payoff[index][player_action][enemy_action] = (
            half_current * half_count + value
        ) / (half_count + 1)
        node.half_counts[index][player_action][enemy_action] = half_count + 1

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
                    owner = 0 if search.evaluation_side == "player" else 1
                    feature = (
                        snapshot.player_features
                        if owner == 0
                        else snapshot.enemy_features
                    )
                    opponent_feature = (
                        snapshot.enemy_features
                        if owner == 0
                        else snapshot.player_features
                    )
                    own_mask = (
                        snapshot.player_mask if owner == 0 else snapshot.enemy_mask
                    )
                    opponent_mask = (
                        snapshot.enemy_mask if owner == 0 else snapshot.player_mask
                    )
                    identity = search._feature_identity(feature)
                    key = (
                        id(network),
                        *identity,
                        own_mask,
                        opponent_mask,
                        search.config.redundant_action_prior_scale,
                    )
                    cached = search._joint_inference_cache.get(key) or joint_known.get(
                        key
                    )
                    consumer = (group_id, position, search)
                    if cached is not None:
                        search._inference_cache_stats["hits"] += 1
                        search._joint_inference_cache[key] = cached
                        joint_known[key] = cached
                        outputs[(group_id, position, owner)] = (cached[0], cached[2])
                        outputs[(group_id, position, 1 - owner)] = (
                            cached[1],
                            -cached[2],
                        )
                    elif key in joint_missing:
                        search._inference_cache_stats["hits"] += 1
                        joint_missing[key]["consumers"].append(consumer)
                    else:
                        search._inference_cache_stats["misses"] += 1
                        joint_missing[key] = {
                            "network": network,
                            "feature": feature,
                            "opponent_feature": opponent_feature,
                            "own_mask": own_mask,
                            "opponent_mask": opponent_mask,
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
                    key = (
                        *search._cache_key(side_network, feature, mask),
                        search.config.redundant_action_prior_scale,
                    )
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
                    owner = 0 if search.evaluation_side == "player" else 1
                    outputs[(group_id, position, owner)] = (player, value)
                    outputs[(group_id, position, 1 - owner)] = (enemy, -value)

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
                (
                    outputs[(group_id, position, 0)][1]
                    if search.evaluation_side == "player"
                    else -outputs[(group_id, position, 1)][1]
                )
                if search.player_network is search.enemy_network
                else max(
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

    @staticmethod
    def _place_leaf_joint(
        outputs: dict[tuple[int, int, int], tuple[list[float], float]],
        consumer: tuple[int, int, int, bool, SimultaneousTreeSearch],
        evaluated: tuple[list[float], list[float], float],
    ) -> None:
        """Route one distilled forward to the side or sides that asked for it."""
        group_id, position, side, mirror, _ = consumer
        own, opponent, value = evaluated
        outputs[(group_id, position, side)] = (own, value)
        if mirror:
            outputs[(group_id, position, 1 - side)] = (opponent, -value)

    @classmethod
    def _pooled_leaf_evaluate(
        cls,
        groups: list[tuple[int, SimultaneousTreeSearch, list[Snapshot]]],
    ) -> tuple[
        dict[int, tuple[list[list[float]], list[list[float]], list[float]]],
        int,
        int,
    ]:
        """Price nodes off the distilled trunk instead of the encoder.

        A mirror pays one distilled forward per node and reads both sides out
        of it, exactly as the encoder's joint head does; distinct controllers
        pay one each and keep only their own side.  Either way the trunk is a
        small MLP over raw features, which is what makes interior priors cheap
        enough to ask for at every cell of every matrix.
        """
        outputs: dict[tuple[int, int, int], tuple[list[float], float]] = {}
        known: dict[
            tuple[int, str, bytes | tuple[int, ...], int, int],
            tuple[list[float], list[float], float],
        ] = {}
        missing: dict[
            tuple[int, str, bytes | tuple[int, ...], int, int], dict[str, Any]
        ] = {}
        for group_id, search, snapshots in groups:
            mirror = search.player_network is search.enemy_network
            sides = (
                (
                    (
                        (0 if search.evaluation_side == "player" else 1),
                        search.player_network,
                    ),
                )
                if mirror
                else (
                    (0, search.player_network),
                    (1, search.enemy_network),
                )
            )
            for side, network in sides:
                for position, snapshot in enumerate(snapshots):
                    own_first = side == 0
                    feature = (
                        snapshot.player_features
                        if own_first
                        else snapshot.enemy_features
                    )
                    opponent_feature = (
                        snapshot.enemy_features
                        if own_first
                        else snapshot.player_features
                    )
                    own_mask = (
                        snapshot.player_mask if own_first else snapshot.enemy_mask
                    )
                    opponent_mask = (
                        snapshot.enemy_mask if own_first else snapshot.player_mask
                    )
                    if own_mask == 0 or opponent_mask == 0:
                        inspection = search.server.inspect(snapshot.handle)
                        raise ValueError(
                            "search reached a nonterminal state with an empty legal mask: "
                            f"side={side} handle={snapshot.handle} turn={snapshot.turn} "
                            f"request={snapshot.request} player_mask={snapshot.player_mask} "
                            f"enemy_mask={snapshot.enemy_mask} inspection={inspection!r}"
                        )
                    key = (
                        id(network),
                        *search._feature_identity(feature),
                        own_mask,
                        opponent_mask,
                        search.config.redundant_action_prior_scale,
                    )
                    cached = search._leaf_joint_inference_cache.get(key) or known.get(
                        key
                    )
                    consumer = (group_id, position, side, mirror, search)
                    if cached is not None:
                        search._inference_cache_stats["hits"] += 1
                        search._leaf_joint_inference_cache[key] = cached
                        known[key] = cached
                        cls._place_leaf_joint(outputs, consumer, cached)
                    elif key in missing:
                        search._inference_cache_stats["hits"] += 1
                        missing[key]["consumers"].append(consumer)
                    else:
                        search._inference_cache_stats["misses"] += 1
                        missing[key] = {
                            "network": network,
                            "feature": feature,
                            "opponent_feature": opponent_feature,
                            "own_mask": own_mask,
                            "opponent_mask": opponent_mask,
                            "consumers": [consumer],
                        }

        by_network: dict[int, list[tuple[Any, dict[str, Any]]]] = {}
        for key, item in missing.items():
            by_network.setdefault(id(item["network"]), []).append((key, item))
        batches: list[tuple[Any, list[tuple[Any, dict[str, Any]]]]] = []
        for items in by_network.values():
            network = items[0][1]["network"]
            batch_size = max(
                consumer[4].config.inference_batch_size
                for _, item in items
                for consumer in item["consumers"]
            )
            for start in range(0, len(items), batch_size):
                batches.append((network, items[start : start + batch_size]))

        pending: list[tuple[list[tuple[Any, dict[str, Any]]], Any]] = []
        synchronous: list[tuple[Any, list[tuple[Any, dict[str, Any]]]]] = []
        for network, batch in batches:
            begin = getattr(network, "begin_evaluate_leaf_joint", None)
            can_defer = getattr(network, "supports_deferred_evaluation", True)
            if begin is None or not can_defer:
                synchronous.append((network, batch))
            else:
                pending.append(
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
            own, opponent, values = network.evaluate_leaf_joint(
                [item[1]["feature"] for item in batch],
                [item[1]["own_mask"] for item in batch],
                [item[1]["opponent_mask"] for item in batch],
            )
            completed.append((batch, own, opponent, values))
        for batch, ticket in pending:
            own, opponent, values = ticket.result()
            completed.append((batch, own, opponent, values))
        for batch, own, opponent, values in completed:
            for (key, item), player, enemy, value in zip(
                batch, own, opponent, values, strict=True
            ):
                network = item["network"]
                if isinstance(network, BattleTransformer):
                    scale = item["consumers"][0][4].config.redundant_action_prior_scale
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
                known[key] = cached
                for consumer in item["consumers"]:
                    consumer[4]._leaf_joint_inference_cache[key] = cached
                    cls._place_leaf_joint(outputs, consumer, cached)

        results = {}
        for group_id, _, snapshots in groups:
            results[group_id] = (
                [
                    outputs[(group_id, position, 0)][0]
                    for position in range(len(snapshots))
                ],
                [
                    outputs[(group_id, position, 1)][0]
                    for position in range(len(snapshots))
                ],
                [
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
                ],
            )
        return results, len(batches), sum(len(batch) for _, batch in batches)

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
                (
                    (
                        (0 if search.evaluation_side == "player" else 1),
                        search.player_network,
                    ),
                )
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
                    cached = search._leaf_inference_cache.get(key)
                    if cached is None:
                        cached = known.get(key)
                    consumer = (group_id, position, side, mirror, search)
                    if cached is not None:
                        search._inference_cache_stats["hits"] += 1
                        search._leaf_inference_cache[key] = cached
                        known[key] = cached
                        outputs[(group_id, position, side)] = cached
                        if mirror:
                            outputs[(group_id, position, 1 - side)] = -cached
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
                        outputs[(group_id, position, 1 - side)] = -value

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
        distilled_groups = [
            (group_id, search, snapshots)
            for group_id, search, snapshots in active_groups
            if search.config.leaf_evaluator == "distilled"
            and bool(
                getattr(search.player_network.config, "distilled_leaf_evaluator", False)
            )
            and bool(
                getattr(search.enemy_network.config, "distilled_leaf_evaluator", False)
            )
        ]
        distilled_ids = {group_id for group_id, _, _ in distilled_groups}
        full_groups = [
            group for group in active_groups if group[0] not in distilled_ids
        ]
        leaf_values, calls, rows = {}, 0, 0
        if distilled_groups:
            leaf_values, calls, rows = cls._pooled_leaf_values(distilled_groups)
        if full_groups:
            evaluated, full_calls, full_rows = cls._pooled_evaluate(full_groups)
            calls += full_calls
            rows += full_rows
            leaf_values.update(
                {group_id: values[2] for group_id, values in evaluated.items()}
            )
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

    def _expansion_pairs(self, node: _TreeNode) -> list[tuple[int, int]]:
        return [
            (player, enemy)
            for player in node.player_legal
            for enemy in node.enemy_legal
        ]

    def _chance_seeds(self, count: int) -> list[int]:
        """Draw the chance worlds one whole level of the tree will share.

        Every matrix at a given depth is stepped through the same seeds, so
        sibling subgames differ by the actions that reached them and by nothing
        else.  Redrawing per node would leave each cell priced against its own
        private world, and the differences between cells would be noise.
        """
        return [self.chance_rng.getrandbits(63) for _ in range(count)]

    def _expansion_spec(
        self, node: _TreeNode, chance_seeds: list[int] | None = None
    ) -> tuple[list[tuple[int, int, int]], list[tuple[int, int, int, int]]]:
        if chance_seeds is None:
            chance_seeds = self._chance_seeds(self.config.chance_samples_per_joint)
        pairs = self._expansion_pairs(node)
        samples = [
            (player, enemy, sample)
            for player, enemy in pairs
            for sample in range(len(chance_seeds))
        ]
        requests = [
            (node.snapshot.handle, player, enemy, chance_seeds[sample])
            for player, enemy, sample in samples
        ]
        return samples, requests

    def _shaped_leaf_value(
        self,
        root_potential: float,
        successor: Snapshot,
        leaf_value: float,
        potential: float,
    ) -> float:
        """Return the win-outcome continuation value without heuristic rewards.

        Kept as a compatibility hook for audit tooling. The model learns raw
        terminal returns, so adding a potential here changes its objective.
        """
        del root_potential, successor, potential
        return leaf_value

    def _install_expansion(
        self,
        node: _TreeNode,
        samples: list[tuple[int, int, int]],
        values: list[float],
    ) -> int:
        """Record one root-relative value per sampled successor of `node`."""
        pairs = list(dict.fromkeys((player, enemy) for player, enemy, _ in samples))
        for (player, enemy, chance_world), value in zip(samples, values, strict=True):
            self._record_value(node, player, enemy, value, chance_world)
        node.sampled_pairs.update(pairs)
        node.expanded = True
        self._expanded_nodes += 1
        self._possible_joint_pairs += len(node.player_legal) * len(node.enemy_legal)
        self._sampled_joint_pairs += len(pairs)
        self._chance_outcomes += len(values)
        return len(values)

    def _diagnostics(self, root: _TreeNode | None) -> dict[str, float | int | str]:
        diagnostics: dict[str, float | int | str] = {
            "tree_nodes": self._expanded_nodes,
            "tree_depth": self.config.max_depth,
            "tree_interior_nodes": self._interior_nodes,
            "tree_interior_divergences": self._interior_divergences,
            "evaluation_side": self.evaluation_side,
            "requested_leaf_evaluator": self.config.leaf_evaluator,
            "leaf_evaluator": (
                "distilled"
                if self.config.leaf_evaluator == "distilled"
                and all(
                    bool(getattr(network.config, "distilled_leaf_evaluator", False))
                    for network in (self.player_network, self.enemy_network)
                )
                else "full"
            ),
            "interior_evaluator": (
                "distilled"
                if self.config.leaf_evaluator == "distilled"
                and all(
                    bool(getattr(network.config, "distilled_leaf_policy", False))
                    for network in (self.player_network, self.enemy_network)
                )
                else "full"
            ),
            "solver_backend_counts": ",".join(
                f"{backend}:{count}"
                for backend, count in sorted(self._solver_backends.items())
            ),
            "solver_matrix_count": sum(self._solver_backends.values()),
            "solver_cuda_matrices": sum(
                count
                for backend, count in self._solver_backends.items()
                if backend.startswith("triton-")
            ),
            "chance_outcomes": self._chance_outcomes,
            "sampled_joint_coverage": (
                self._sampled_joint_pairs / self._possible_joint_pairs
                if self._possible_joint_pairs
                else 0.0
            ),
            "cross_root_batch_size": self._cross_root_batch_size,
            "cross_root_root_leaves": self._cross_root_root_leaves,
            "inference_cache_hits": self._inference_cache_stats["hits"],
            "inference_cache_misses": self._inference_cache_stats["misses"],
            "inference_cache_hit_rate": (
                self._inference_cache_stats["hits"]
                / max(1, sum(self._inference_cache_stats.values()))
            ),
        }
        if root is not None:
            diagnostics["root_joint_actions"] = len(root.player_legal) * len(
                root.enemy_legal
            )
            diagnostics["root_solves"] = root.solve_count
            diagnostics["root_online_exploitability"] = root.online_exploitability
            diagnostics["root_final_exploitability"] = root.exploitability
            diagnostics["root_equilibrium_iterations"] = self.config.regret_iterations
            diagnostics["root_solver"] = root.solve_backend or "not-solved"
            diagnostics["root_anchor_temperature"] = (
                self.config.prior_anchor_temperature
            )
            if self.config.split_half_reliability:
                diagnostics["root_split_half_available"] = self._split_half_available
                diagnostics["root_split_half_distance"] = (
                    self._split_half_player_distance
                )
                diagnostics["root_split_half_enemy_distance"] = (
                    self._split_half_enemy_distance
                )
                diagnostics["root_split_half_value_gap"] = self._split_half_value_gap
            if self.config.prior_regret:
                regret, enemy_regret = self._prior_regret(
                    root, root.payoff, root.player_policy, root.enemy_policy
                )
                diagnostics["root_prior_regret"] = regret
                diagnostics["root_enemy_prior_regret"] = enemy_regret
                if self.config.split_half_reliability:
                    diagnostics["root_prior_regret_noise"] = self._prior_regret_noise
                    diagnostics["root_enemy_prior_regret_noise"] = (
                        self._enemy_prior_regret_noise
                    )
        return diagnostics

    def _fallback(
        self,
        player_policy: list[float],
        enemy_policy: list[float],
        value: float,
        transitions: int,
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
            self._diagnostics(None),
            "search-semantic-divergence",
        )

    def _finish_root(
        self,
        root: _TreeNode,
        transitions: int,
        sample_actions: bool,
    ) -> SearchResult:
        """Publish the root equilibrium `search_many` already solved.

        Nothing is refined between the solve and here.  The exhaustive root
        expansion pairs every cell against the same chance draws, and any
        further sampling would have to pick which cells to revisit -- which in
        practice means the ones the current policy already prefers, so the
        matrix drifts toward whatever the search happened to try first.
        """
        player_policy = tuple(root.player_policy)
        enemy_policy = tuple(root.enemy_policy)
        exploitability = root.exploitability
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
            root.root_value,
            transitions,
            (
                "simultaneous-win-value-anchored-v9"
                if self.config.prior_anchor_temperature > 0.0
                else "simultaneous-win-value-cfrplus-v9"
                if self.config.cfr_plus_solves
                else "simultaneous-win-value-rust-rmplus-v9"
                if self.config.rmplus_backend == RUST_RMPLUS_BACKEND
                else "simultaneous-win-value-rmplus-v9"
            ),
            exploitability,
            max(legal_payoffs) - min(legal_payoffs),
            tuple(tuple(row) for row in root.payoff),
            self._diagnostics(root),
        )

    def search(self, snapshot: Snapshot, sample_actions: bool = True) -> SearchResult:
        return self.search_many([self], [snapshot], sample_actions)[0]

    @classmethod
    def search_many(
        cls,
        searches: list[SimultaneousTreeSearch],
        snapshots: list[Snapshot],
        sample_actions: bool = True,
    ) -> list[SearchResult]:
        """Batch root transitions and inference across independent live roots."""
        backends = {search.config.orchestration_backend for search in searches}
        if len(backends) > 1:
            raise ValueError("cross-root batches require one orchestration backend")
        if backends == {"rust"}:
            from .search_native import RustSimultaneousTreeSearch

            return RustSimultaneousTreeSearch.search_many(
                searches, snapshots, sample_actions
            )
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
        for index, (search, snapshot) in enumerate(
            zip(searches, snapshots, strict=True)
        ):
            noise = search.prior_noise
            if noise is None:
                continue
            player_priors[index] = _dirichlet_noised_priors(
                player_priors[index], snapshot.player_mask, noise
            )
            enemy_priors[index] = _dirichlet_noised_priors(
                enemy_priors[index], snapshot.enemy_mask, noise
            )
        roots = [
            search._make_node(
                snapshot,
                (player_priors[index], enemy_priors[index], prior_values[index]),
            )
            for index, (search, snapshot) in enumerate(
                zip(searches, snapshots, strict=True)
            )
        ]
        root_seeds = [
            search._chance_seeds(search.config.chance_samples_per_joint)
            for search in searches
        ]
        specs = [
            search._expansion_spec(root, seeds)
            for search, root, seeds in zip(searches, roots, root_seeds, strict=True)
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
        levels = [
            [
                _Expansion(index, roots[index], specs[index][0], successors[left:right])
                for index, ((left, right), is_good) in enumerate(
                    zip(offsets, good, strict=True)
                )
                if is_good
            ]
        ]
        deepest = max(search.config.max_depth for search in searches)
        for depth in range(2, deepest + 1):
            frontier = cls._open_subgames(searches, levels[-1], depth)
            if not frontier:
                break
            levels.append(frontier)
        transitions = cls._settle(searches, levels)
        root_jobs = []
        root_slots = {}
        for index, (search, root, is_good) in enumerate(
            zip(searches, roots, good, strict=True)
        ):
            if not is_good or search._interior_divergences:
                good[index] = False
                continue
            slots = [len(root_jobs)]
            root_jobs.append((search, root, root.payoff))
            if (
                search.config.split_half_reliability
                and root.half_payoff
                and all(
                    search._half_is_covered(root, half)
                    for half in range(len(root.half_payoff))
                )
            ):
                for payoff in root.half_payoff[:_SPLIT_HALVES]:
                    slots.append(len(root_jobs))
                    root_jobs.append((search, root, payoff))
            root_slots[index] = slots
        root_solutions = cls._solve_matrices(root_jobs)
        results: list[SearchResult | None] = [None] * len(searches)
        batch_size = len(searches)
        for index, (search, root, bounds, is_good) in enumerate(
            zip(searches, roots, offsets, good, strict=True)
        ):
            left, right = bounds
            search._cross_root_batch_size = batch_size
            search._cross_root_root_leaves = right - left
            if not is_good:
                results[index] = search._fallback(
                    player_priors[index],
                    enemy_priors[index],
                    prior_values[index],
                    right - left,
                )
                continue
            slots = root_slots[index]
            player_policy, enemy_policy, value, exploitability = (
                search._root_equilibrium(
                    root,
                    root_solutions[slots[0]],
                    [root_solutions[slot] for slot in slots[1:]]
                    if len(slots) > 1
                    else None,
                )
            )
            root.player_policy = list(player_policy)
            root.enemy_policy = list(enemy_policy)
            root.root_value = value
            root.exploitability = exploitability
            root.solve_count = search.config.regret_iterations
            results[index] = search._finish_root(
                root, transitions[index], sample_actions
            )
        if any(result is None for result in results):
            raise RuntimeError("cross-root scheduler left an unfinished search")
        return cast(list[SearchResult], results)

    @classmethod
    def _open_subgames(
        cls,
        searches: list[SimultaneousTreeSearch],
        level: list[_Expansion],
        depth: int,
    ) -> list[_Expansion]:
        """Open one subgame under every live successor of `level`, in one batch.

        The rule is the same for every cell: a successor that is still playable
        gets a matrix `interior_actions_per_side` wide, stepped through the
        chance worlds its whole level shares.  Nothing here consults a policy
        about which cells deserve the work, because a cell refined more than its
        neighbours is no longer comparable to them.
        """
        opening: list[tuple[_Expansion, int]] = []
        frontier_snapshots: dict[int, list[Snapshot]] = {}
        for expansion in level:
            if searches[expansion.root].config.max_depth < depth:
                continue
            for position, successor in enumerate(expansion.successors):
                if successor.done:
                    continue
                opening.append((expansion, position))
                frontier_snapshots.setdefault(expansion.root, []).append(successor)
        if not opening:
            return []
        frontier_groups = [
            (root, searches[root], snapshots)
            for root, snapshots in frontier_snapshots.items()
        ]
        # Select the evaluator per controller, independently of the other
        # searches sharing this batch. Full encoder evaluation is the default.
        distilled_groups = [
            group
            for group in frontier_groups
            if group[1].config.leaf_evaluator == "distilled"
            and all(
                bool(getattr(network.config, "distilled_leaf_policy", False))
                for network in (group[1].player_network, group[1].enemy_network)
            )
        ]
        distilled_ids = {group[0] for group in distilled_groups}
        full_groups = [
            group for group in frontier_groups if group[0] not in distilled_ids
        ]
        evaluations = {}
        if distilled_groups:
            result, _, _ = cls._pooled_leaf_evaluate(distilled_groups)
            evaluations.update(result)
        if full_groups:
            result, _, _ = cls._pooled_evaluate(full_groups)
            evaluations.update(result)
        slots = dict.fromkeys(frontier_snapshots, 0)
        seeds = {
            root: searches[root]._chance_seeds(
                searches[root].config.interior_chance_samples
            )
            for root in frontier_snapshots
        }
        staged: list[tuple[_Expansion, int, _TreeNode, list[tuple[int, int, int]]]] = []
        requests: list[tuple[int, int, int, int]] = []
        bounds: list[tuple[int, int]] = []
        for expansion, position in opening:
            search = searches[expansion.root]
            slot = slots[expansion.root]
            slots[expansion.root] = slot + 1
            player, enemy, values = evaluations[expansion.root]
            node = search._make_node(
                expansion.successors[position],
                (player[slot], enemy[slot], values[slot]),
                width=search.config.interior_actions_per_side,
            )
            samples, node_requests = search._expansion_spec(node, seeds[expansion.root])
            staged.append((expansion, position, node, samples))
            bounds.append((len(requests), len(requests) + len(node_requests)))
            requests.extend(node_requests)
        successors = searches[0].server.search_steps(requests)
        frontier: list[_Expansion] = []
        for (expansion, position, node, samples), (left, right) in zip(
            staged, bounds, strict=True
        ):
            search = searches[expansion.root]
            opened = successors[left:right]
            if any(successor.divergence is not None for successor in opened):
                search._interior_divergences += 1
                continue
            search._interior_nodes += 1
            expansion.children[position] = node
            frontier.append(_Expansion(expansion.root, node, samples, opened))
        return frontier

    @classmethod
    def _settle(
        cls,
        searches: list[SimultaneousTreeSearch],
        levels: list[list[_Expansion]],
    ) -> dict[int, int]:
        """Price every leaf against its root, then fold the tree upwards.

        Leaves are gathered from every level at once -- a terminal two plies
        down and a depth-limited leaf are the same kind of thing to the batch --
        so the whole tree costs one pooled evaluation regardless of its shape.
        """
        leaves: list[tuple[_Expansion, int]] = []
        leaf_snapshots: dict[int, list[Snapshot]] = {}
        for level in levels:
            for expansion in level:
                for position, successor in enumerate(expansion.successors):
                    if expansion.children[position] is not None:
                        continue
                    leaves.append((expansion, position))
                    leaf_snapshots.setdefault(expansion.root, []).append(successor)
        if leaves:
            evaluated, _, _ = cls._pooled_successor_values(
                [
                    (root, searches[root], snapshots)
                    for root, snapshots in leaf_snapshots.items()
                ]
            )
            slots = dict.fromkeys(leaf_snapshots, 0)
            for expansion, position in leaves:
                slot = slots[expansion.root]
                slots[expansion.root] = slot + 1
                expansion.values[position] = evaluated[expansion.root][slot][0]
        transitions: dict[int, int] = {}
        for depth, level in reversed(list(enumerate(levels))):
            solved_level = []
            for expansion in level:
                search = searches[expansion.root]
                if search._interior_divergences:
                    continue
                for position, child in enumerate(expansion.children):
                    if child is not None:
                        expansion.values[position] = child.root_value
                if any(value is None for value in expansion.values):
                    raise RuntimeError("tree backup left a payoff cell unpriced")
                transitions[expansion.root] = transitions.get(
                    expansion.root, 0
                ) + search._install_expansion(
                    expansion.node,
                    expansion.samples,
                    cast(list[float], expansion.values),
                )
                if depth == 0:
                    continue
                solved_level.append((search, expansion.node, expansion.node.payoff))
            solutions = cls._solve_matrices(solved_level)
            for (_, node, _), (_, _, value, exploitability) in zip(
                solved_level, solutions, strict=True
            ):
                node.root_value = value
                node.exploitability = exploitability
        return transitions
