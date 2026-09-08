"""Time-budgeted battle decisions from completed simultaneous-action searches.

This is a production inference path. Training retains fixed search budgets so
its targets and replays do not depend on machine speed. The wall-time budget is
an admission target, not a hard deadline: native batches and CUDA work cannot
be interrupted safely, including the mandatory first complete search.
"""

from __future__ import annotations

import math
import random
import time
from collections.abc import Callable
from dataclasses import dataclass, replace

import torch
from torch import Tensor

from .joint_search import JointSearchConfig, SearchResult, SimultaneousTreeSearch
from .native import NativeRequestTimeout, SearchServer, Snapshot
from .network import _INFERENCE_BUCKETS, BattleTransformer
from .rmplus_native import RUST_RMPLUS_BACKEND


class DecisionSearchError(RuntimeError):
    """A safe search-assisted decision could not be returned."""


@dataclass(frozen=True)
class DecisionPass:
    depth: int
    chance_samples: int
    elapsed_seconds: float
    estimated_seconds: float | None
    nodes: int
    completed: bool
    solver: str | None
    failure: str | None


@dataclass(frozen=True)
class BattleDecision:
    """A sampled action and detached CPU tensors in the requested side's view.

    ``search_result`` retains physical player-relative matrix/value fields;
    only the requested controller's action is populated. ``policy`` and
    ``value`` are canonical to ``side``. Pass statistics include failed work.
    """

    side: str
    action: int
    policy: Tensor
    opponent_policy: Tensor
    value: Tensor
    search_result: SearchResult
    passes: tuple[DecisionPass, ...]
    selected_depth: int
    selected_chance_samples: int
    total_nodes: int
    native_rows_requested: int
    native_rows_deduplicated: int
    elapsed_seconds: float
    budget_seconds: float
    budget_overrun_seconds: float
    stop_reason: str
    next_pass_estimate_seconds: float | None


@dataclass(frozen=True)
class DecisionWarmup:
    elapsed_seconds: float
    bucket_sizes: tuple[int, ...]
    evaluation_kinds: tuple[str, ...]
    launches: int
    engine: str
    precision: str


def warm_decision_network(
    network: BattleTransformer,
    snapshot: Snapshot,
    *,
    search_config: JointSearchConfig | None = None,
    clock: Callable[[], float] = time.monotonic,
) -> DecisionWarmup:
    """Compile and settle every supported inference shape before serving turns.

    Run this once after loading and configuring a serving model, before the
    first timed decision. A few battle warmups may never visit the batch sizes
    reached by a later position. Both canonical feature orientations, all
    available single/joint/value inference paths, and every static batch bucket
    up to the configured maximum are exercised twice, including CUDA graph
    warmup. Deferred tickets are resolved before returning. This startup cost
    is separate from the per-turn budget; matrix-solver compilation is separate
    and may still occur on the first search using a new solver shape.
    """
    started = clock()
    maximum = (search_config or JointSearchConfig()).inference_batch_size
    if not 1 <= maximum <= _INFERENCE_BUCKETS[-1]:
        raise ValueError(
            f"complete inference warmup requires a batch size in 1..{_INFERENCE_BUCKETS[-1]}"
        )
    buckets = tuple(
        dict.fromkeys(
            BattleTransformer._inference_bucket(size) for size in range(1, maximum + 1)
        )
    )
    kinds = ["evaluate"]
    if network.config.joint_policy_heads:
        kinds.append("evaluate_joint")
    if network.config.distilled_leaf_evaluator:
        kinds.append("evaluate_leaf")
    if network.config.distilled_leaf_policy:
        kinds.append("evaluate_leaf_joint")
    network.eval()
    launches = 0
    for bucket in buckets:
        size = min(bucket, maximum)
        features = [
            snapshot.player_features if index % 2 == 0 else snapshot.enemy_features
            for index in range(size)
        ]
        own_masks = [
            snapshot.player_mask if index % 2 == 0 else snapshot.enemy_mask
            for index in range(size)
        ]
        opponent_masks = [
            snapshot.enemy_mask if index % 2 == 0 else snapshot.player_mask
            for index in range(size)
        ]
        for kind in kinds:
            arguments = (
                (features,)
                if kind == "evaluate_leaf"
                else (features, own_masks, opponent_masks)
                if kind.endswith("joint")
                else (features, own_masks)
            )
            for _ in range(2):
                getattr(network, f"begin_{kind}")(*arguments).result()
                launches += 1
    return DecisionWarmup(
        elapsed_seconds=clock() - started,
        bucket_sizes=buckets,
        evaluation_kinds=tuple(kinds),
        launches=launches,
        engine=network._inference_engine,
        precision=network.config.precision,
    )


def _work_units(config: JointSearchConfig) -> int:
    branching = config.interior_actions_per_side**2 * config.interior_chance_samples
    return config.chance_samples_per_joint * sum(
        branching**depth for depth in range(config.max_depth)
    )


def _refinements(
    current: JointSearchConfig, limits: JointSearchConfig
) -> list[JointSearchConfig]:
    candidates = []
    if current.max_depth < limits.max_depth:
        candidates.append(replace(current, max_depth=current.max_depth + 1))
    if current.chance_samples_per_joint < limits.chance_samples_per_joint:
        chance = replace(
            current,
            chance_samples_per_joint=min(
                2 * current.chance_samples_per_joint, limits.chance_samples_per_joint
            ),
        )
        # Establish two chance worlds before spending the next pass on depth.
        candidates.insert(
            0 if current.chance_samples_per_joint == 1 else len(candidates), chance
        )
    return candidates


def _search_failure(
    result: SearchResult, snapshot: Snapshot, actions: int
) -> str | None:
    if result.failure:
        return result.failure
    if result.payoff_matrix is None:
        return "missing-complete-root-matrix"
    if len(result.payoff_matrix) != actions or any(
        len(row) != actions for row in result.payoff_matrix
    ):
        return "invalid-root-matrix-shape"
    if not math.isfinite(result.root_value) or not all(
        math.isfinite(value) for row in result.payoff_matrix for value in row
    ):
        return "nonfinite-search-output"
    if (result.diagnostics or {}).get("tree_interior_divergences", 0):
        return "search-interior-semantic-divergence"
    for policy, mask in (
        (result.player_policy, snapshot.player_mask),
        (result.enemy_policy, snapshot.enemy_mask),
    ):
        if len(policy) != actions or not all(
            math.isfinite(weight) and weight >= 0.0 for weight in policy
        ):
            return "invalid-search-policy"
        if not math.isclose(sum(policy), 1.0, abs_tol=1e-5):
            return "unnormalized-search-policy"
        if any(
            weight > 0.0 and not mask & (1 << action)
            for action, weight in enumerate(policy)
        ):
            return "illegal-search-policy-mass"
    return None


def decide_battle(
    server: SearchServer,
    network: BattleTransformer,
    snapshot: Snapshot,
    *,
    side: str = "player",
    search_config: JointSearchConfig | None = None,
    budget_seconds: float = 3.0,
    seed: int = 0,
    sample_action: bool = True,
    admission_margin: float = 1.25,
    clock: Callable[[], float] = time.monotonic,
) -> BattleDecision:
    """Refine complete matrices while measured cost predicts they will fit.

    ``search_config`` supplies upper limits on depth and root chance samples.
    Every pass covers every legal root action. The first depth-one/sample-one
    pass always runs; later passes are admitted using the previous pass's wall
    time, the ratio of maximum tree sizes, and ``admission_margin``. Returned
    elapsed time covers search, CPU result transfer, and action/tensor packing;
    server startup, checkpoint loading, and caller serialization are excluded.

    Refinements share their chance RNG seed, allowing native transition cache
    reuse, and never replace the last valid result with a partial matrix or a
    network-only policy. Mixed-policy sampling happens once after refinement.
    Use a fresh seed per real decision; fixed seeds reproduce the chance draw
    and sampling for a given admitted pass sequence, not wall-clock scheduling.
    """
    started = clock()
    if not math.isfinite(budget_seconds) or budget_seconds <= 0.0:
        raise ValueError("budget_seconds must be finite and positive")
    if not math.isfinite(admission_margin) or admission_margin < 1.0:
        raise ValueError("admission_margin must be finite and at least one")
    if side not in {"player", "enemy"}:
        raise ValueError("side must be player or enemy")
    if snapshot.done:
        raise ValueError("cannot decide a terminal battle state")
    if snapshot.divergence is not None:
        raise DecisionSearchError("cannot search a divergent battle state")
    limits = search_config or JointSearchConfig(
        max_depth=2,
        chance_samples_per_joint=4,
        interior_chance_samples=2,
        redundant_action_prior_scale=0.25,
        rmplus_backend=RUST_RMPLUS_BACKEND,
        leaf_evaluator="full",
        solver_backend="auto",
    )
    if limits.max_depth < 1 or limits.chance_samples_per_joint < 1:
        raise ValueError("search depth and chance sample limits must be positive")
    actions = network.config.action_count
    masks = (snapshot.player_mask, snapshot.enemy_mask)
    if any(mask <= 0 or mask >> actions for mask in masks):
        raise ValueError("root legal masks must contain valid actions for both sides")
    if limits.max_actions_per_side < max(mask.bit_count() for mask in masks):
        raise ValueError("decision search must cover every legal root action")
    initial_requested = server.search_rows_requested
    initial_deduplicated = server.search_rows_deduplicated
    current = replace(limits, max_depth=1, chance_samples_per_joint=1)
    selected: SearchResult | None = None
    selected_config = current
    passes = []
    estimate = None
    next_estimate = None
    stop_reason = "search-limits-reached"
    while True:
        pass_started = clock()
        search = SimultaneousTreeSearch(
            server,
            network,
            network,
            current,
            random.Random(seed ^ 0x53454C454354),
            random.Random(seed ^ 0x4348414E4345),
            evaluation_side=side,
        )
        result = None
        try:
            result = search.search(snapshot, sample_actions=False)
            failure = _search_failure(result, snapshot, actions)
        except NativeRequestTimeout as error:
            raise DecisionSearchError(
                "native search timed out; recreate the server and replay the battle "
                "before another request because a response may still be pending"
            ) from error
        pass_elapsed = clock() - pass_started
        passes.append(
            DecisionPass(
                depth=current.max_depth,
                chance_samples=current.chance_samples_per_joint,
                elapsed_seconds=pass_elapsed,
                estimated_seconds=estimate,
                nodes=result.nodes if result is not None else 0,
                completed=failure is None,
                solver=result.solver if result is not None else None,
                failure=failure,
            )
        )
        if failure is not None:
            if selected is None:
                raise DecisionSearchError(
                    f"no complete search produced a decision: {failure}"
                )
            stop_reason = "refinement-failed"
            break
        selected = result
        selected_config = current
        remaining = budget_seconds - (clock() - started)
        if remaining <= 0.0:
            stop_reason = "budget-exhausted"
            break
        candidates = _refinements(current, limits)
        if not candidates:
            break
        # This is an estimate, not a worst-case execution-time guarantee.
        estimates = [
            max(pass_elapsed, 1e-6)
            * _work_units(candidate)
            / _work_units(current)
            * admission_margin
            for candidate in candidates
        ]
        eligible = next(
            (index for index, seconds in enumerate(estimates) if seconds <= remaining),
            None,
        )
        if eligible is None:
            next_estimate = min(estimates)
            stop_reason = "next-pass-would-exceed-budget"
            break
        current = candidates[eligible]
        estimate = estimates[eligible]
    if selected is None:
        raise DecisionSearchError("no complete search produced a decision")
    own_policy, other_policy = (
        (selected.player_policy, selected.enemy_policy)
        if side == "player"
        else (selected.enemy_policy, selected.player_policy)
    )
    legal = [
        action for action in range(actions) if masks[side == "enemy"] & (1 << action)
    ]
    action = (
        random.Random(seed ^ 0x414354494F4E).choices(
            legal, weights=[own_policy[i] for i in legal]
        )[0]
        if sample_action
        else max(legal, key=lambda index: own_policy[index])
    )
    policy = torch.tensor(own_policy, dtype=torch.float32, device="cpu")
    opponent_policy = torch.tensor(other_policy, dtype=torch.float32, device="cpu")
    value = torch.tensor(
        selected.root_value * (1.0 if side == "player" else -1.0),
        dtype=torch.float32,
        device="cpu",
    )
    published = replace(
        selected,
        player_action=action if side == "player" else None,
        enemy_action=action if side == "enemy" else None,
    )
    elapsed = clock() - started
    return BattleDecision(
        side=side,
        action=action,
        policy=policy,
        opponent_policy=opponent_policy,
        value=value,
        search_result=published,
        passes=tuple(passes),
        selected_depth=selected_config.max_depth,
        selected_chance_samples=selected_config.chance_samples_per_joint,
        total_nodes=sum(item.nodes for item in passes),
        native_rows_requested=server.search_rows_requested - initial_requested,
        native_rows_deduplicated=server.search_rows_deduplicated - initial_deduplicated,
        elapsed_seconds=elapsed,
        budget_seconds=budget_seconds,
        budget_overrun_seconds=max(0.0, elapsed - budget_seconds),
        stop_reason=stop_reason,
        next_pass_estimate_seconds=next_estimate,
    )
