"""Batched KL-proximal extragradient on CUDA, with a native f64 fallback.

Each Triton program keeps one small matrix and its policies on chip for every
iteration. The mathematical update and the 1e-9 prior floor match the Rust
anchored solver. This module solves positive-temperature anchored games only;
it never substitutes a different algorithm for unregularized RM+/CFR+.

The public boundary is host arrays, as used by the simulator. Its timing must
include both transfers. CUDA is optional and imported only when requested.
The default CUDA fp32 mode has a deliberately bounded validation domain; fp64
uses double precision including transcendental functions and kernel constants.
"""

from __future__ import annotations

import functools
import math
from dataclasses import dataclass
from typing import Any

import numpy as np

from .cuda_runtime import configure_triton_runtime
from .rmplus_native import solve_anchored

CUDA_ANCHORED_BACKEND = "triton-anchored-f64-v1"
NATIVE_ANCHORED_BACKEND = "rust-anchored-f64-v1"
# Conservative host-to-host crossover; see tools/benchmark-cuda-solver.py.
CUDA_MIN_BATCH = 64
CUDA_MAX_ACTIONS = 13
CUDA_F32_MIN_BATCH = 16


@dataclass(frozen=True)
class BatchSolveResult:
    player_policy: np.ndarray
    enemy_policy: np.ndarray
    value: np.ndarray
    exploitability: np.ndarray
    backend: str
    fallback_reason: str | None = None

    def row(
        self, index: int
    ) -> tuple[tuple[float, ...], tuple[float, ...], float, float]:
        """The same result shape as ``rmplus_native.solve_anchored``."""
        return (
            tuple(float(item) for item in self.player_policy[index]),
            tuple(float(item) for item in self.enemy_policy[index]),
            float(self.value[index]),
            float(self.exploitability[index]),
        )


def cuda_solver_available() -> bool:
    configure_triton_runtime()
    try:
        import torch
        import triton

        if not torch.cuda.is_available():
            return False
        # Importability alone misses missing libcuda/compiler tooling (notably
        # ldconfig on NixOS). This initializes the driver once, not a kernel.
        triton.runtime.driver.active.get_current_device()
    except (ImportError, OSError, RuntimeError):
        return False
    return True


def _compact(
    arrays: tuple[np.ndarray, ...],
) -> tuple[tuple[np.ndarray, ...], np.ndarray, np.ndarray]:
    """Pack legal actions so a width-three interior node uses a 4x4 block."""
    matrix, player, enemy, player_mask, enemy_mask = arrays
    width = int(max(player_mask.sum(axis=1).max(), enemy_mask.sum(axis=1).max()))
    player_order = np.argsort(~player_mask, axis=1, stable=True)[:, :width]
    enemy_order = np.argsort(~enemy_mask, axis=1, stable=True)[:, :width]
    compact_matrix = np.take_along_axis(matrix, player_order[:, :, None], axis=1)
    compact_matrix = np.take_along_axis(compact_matrix, enemy_order[:, None, :], axis=2)
    return (
        tuple(
            np.ascontiguousarray(array)
            for array in (
                compact_matrix,
                np.take_along_axis(player, player_order, axis=1),
                np.take_along_axis(enemy, enemy_order, axis=1),
                np.take_along_axis(player_mask, player_order, axis=1),
                np.take_along_axis(enemy_mask, enemy_order, axis=1),
            )
        ),
        player_order,
        enemy_order,
    )


@functools.lru_cache(maxsize=1)
def _kernel() -> Any:
    import triton
    import triton.language as tl
    from triton.language.extra.cuda import libdevice

    @triton.jit
    def soft_normalize(logits, legal):
        logits = tl.where(legal, logits, -float("inf"))
        centered = logits - tl.max(logits, 0)
        result = libdevice.exp(centered)
        total = tl.sum(result, 0)
        return result / total, centered - libdevice.log(total)

    @triton.jit
    def prox(log_current, log_anchor, gradient, legal, step, temperature):
        logits = (
            step * gradient
            + step * temperature * log_anchor
            + tl.maximum(
                log_current, tl.full((), -708.3964185322641, log_current.dtype)
            )
        ) / (1.0 + step * temperature)
        return soft_normalize(logits, legal)

    @triton.jit
    def normalize_prior(prior, legal):
        prior = tl.where(legal, prior, 0.0)
        total = tl.sum(prior, 0)
        normalized = tl.where(
            total > 0, prior / total, 1.0 / tl.sum(legal.to(prior.dtype), 0)
        )
        normalized = tl.where(
            legal, tl.maximum(normalized, tl.full((), 1e-9, prior.dtype)), 0.0
        )
        return normalized / tl.sum(normalized, 0)

    @triton.jit
    def anchored_kernel(
        matrices,
        player_priors,
        enemy_priors,
        player_masks,
        enemy_masks,
        output,
        iterations,
        TEMPERATURE: tl.constexpr,
        ACTIONS: tl.constexpr,
        BLOCK: tl.constexpr,
    ):
        batch = tl.program_id(0)
        actions = tl.arange(0, BLOCK)
        inside = actions < ACTIONS
        player_legal = tl.load(
            player_masks + batch * ACTIONS + actions, inside, other=0
        ).to(tl.int1)
        enemy_legal = tl.load(
            enemy_masks + batch * ACTIONS + actions, inside, other=0
        ).to(tl.int1)
        legal_matrix = player_legal[:, None] & enemy_legal[None, :]
        offsets = (
            batch * ACTIONS * ACTIONS + actions[:, None] * ACTIONS + actions[None, :]
        )
        matrix = tl.load(matrices + offsets, legal_matrix, other=0.0)
        temperature = tl.full((), TEMPERATURE, matrix.dtype)
        player = normalize_prior(
            tl.load(player_priors + batch * ACTIONS + actions, inside, other=0.0),
            player_legal,
        )
        enemy = normalize_prior(
            tl.load(enemy_priors + batch * ACTIONS + actions, inside, other=0.0),
            enemy_legal,
        )
        log_player = libdevice.log(tl.where(player_legal, player, 1.0))
        log_enemy = libdevice.log(tl.where(enemy_legal, enemy, 1.0))
        current_log_player = log_player
        current_log_enemy = log_enemy
        magnitude = tl.max(tl.max(tl.abs(matrix), 0), 0)
        step = 1.0 / tl.maximum(1.0, magnitude)
        for _ in range(iterations):
            row_values = tl.sum(matrix * enemy[None, :], 1)
            column_values = tl.sum(player[:, None] * matrix, 0)
            half_player, _ = prox(
                current_log_player,
                log_player,
                row_values,
                player_legal,
                step,
                temperature,
            )
            half_enemy, _ = prox(
                current_log_enemy,
                log_enemy,
                -column_values,
                enemy_legal,
                step,
                temperature,
            )
            row_values = tl.sum(matrix * half_enemy[None, :], 1)
            column_values = tl.sum(half_player[:, None] * matrix, 0)
            player, current_log_player = prox(
                current_log_player,
                log_player,
                row_values,
                player_legal,
                step,
                temperature,
            )
            enemy, current_log_enemy = prox(
                current_log_enemy,
                log_enemy,
                -column_values,
                enemy_legal,
                step,
                temperature,
            )
        row_values = tl.sum(matrix * enemy[None, :], 1)
        column_values = tl.sum(player[:, None] * matrix, 0)
        value = tl.sum(player * row_values, 0)
        gap = tl.max(tl.where(player_legal, row_values, -float("inf")), 0) - tl.min(
            tl.where(enemy_legal, column_values, float("inf")), 0
        )
        result = output + batch * (2 * ACTIONS + 2)
        tl.store(result + actions, player, inside)
        tl.store(result + ACTIONS + actions, enemy, inside)
        tl.store(result + 2 * ACTIONS, value)
        tl.store(result + 2 * ACTIONS + 1, gap)

    return anchored_kernel


def _validate(
    payoffs: Any,
    player_priors: Any,
    enemy_priors: Any,
    player_masks: Any,
    enemy_masks: Any,
    iterations: int,
    temperature: float,
) -> tuple[np.ndarray, ...]:
    if not isinstance(iterations, int) or not 1 <= iterations <= 0x7FFFFFFF:
        raise ValueError("iterations must be a positive int32")
    if not math.isfinite(temperature) or temperature <= 0:
        raise ValueError("anchor temperature must be finite and positive")
    matrix = np.ascontiguousarray(payoffs, dtype=np.float64)
    if (
        matrix.ndim != 3
        or matrix.shape[0] < 1
        or matrix.shape[1] < 1
        or matrix.shape[1] != matrix.shape[2]
    ):
        raise ValueError(
            "payoffs must have shape [batch, actions, actions] with positive sizes"
        )
    shape = matrix.shape[:2]
    arrays = [matrix]
    for values in (player_priors, enemy_priors):
        prior = np.ascontiguousarray(values, dtype=np.float64)
        if prior.shape != shape or not np.isfinite(prior).all() or (prior < 0).any():
            raise ValueError(
                "priors must be finite nonnegative arrays of shape [batch, actions]"
            )
        if not np.isfinite(prior.sum(axis=1)).all():
            raise ValueError("prior sums must be finite")
        arrays.append(prior)
    if not np.isfinite(matrix).all():
        raise ValueError("payoffs must be finite")
    for values in (player_masks, enemy_masks):
        mask = np.asarray(values)
        if mask.shape != shape or mask.dtype != np.bool_:
            raise ValueError(
                "legal masks must be boolean arrays of shape [batch, actions]"
            )
        if not mask.any(axis=1).all():
            raise ValueError("each side needs at least one legal action per matrix")
        arrays.append(np.ascontiguousarray(mask))
    return tuple(arrays)


def solve_anchored_batch(
    payoffs: Any,
    player_priors: Any,
    enemy_priors: Any,
    player_masks: Any,
    enemy_masks: Any,
    iterations: int,
    temperature: float,
    *,
    backend: str = "auto",
    device: str | None = None,
    precision: str = "fp32",
) -> BatchSolveResult:
    """Solve independent anchored games, preserving masks and Rust diagnostics.

    ``auto`` selects CUDA only for supported batches above the measured host
    transfer crossover. Other workloads use Rust and report why. An explicit
    ``cuda`` request fails clearly if unsupported; compilation or kernel errors
    always propagate instead of concealing a broken accelerator. ``device``
    chooses a CUDA device for the kernel; inputs and outputs stay host arrays.
    ``precision="fp32"`` is an explicit faster approximation, validated against
    the native f64 solver on search payoffs [-1, 1], temperatures [0.005, 1],
    and at most 8192 iterations. Its backend identity records that precision.
    """
    if backend not in {"auto", "cuda", "rust"}:
        raise ValueError(f"unsupported anchored backend: {backend!r}")
    if precision not in {"fp64", "fp32"}:
        raise ValueError(f"unsupported anchored precision: {precision!r}")
    matrix, player, enemy, player_mask, enemy_mask = _validate(
        payoffs,
        player_priors,
        enemy_priors,
        player_masks,
        enemy_masks,
        iterations,
        temperature,
    )
    batch, actions = player.shape
    width = int(max(player_mask.sum(axis=1).max(), enemy_mask.sum(axis=1).max()))
    average_width = float((player_mask.sum() + enemy_mask.sum()) / (2 * batch))
    minimum_batch = (
        CUDA_F32_MIN_BATCH
        if precision == "fp32"
        else (
            128 if average_width <= 4 else 96 if average_width <= 8 else CUDA_MIN_BATCH
        )
    )
    reason = None
    if backend != "rust":
        if not cuda_solver_available():
            reason = "CUDA or Triton unavailable"
        elif actions > CUDA_MAX_ACTIONS:
            reason = f"CUDA supports at most {CUDA_MAX_ACTIONS} actions"
        elif precision == "fp32" and (
            not 0.005 <= temperature <= 1.0
            or iterations > 8192
            or np.abs(matrix).max() > 1.0
        ):
            reason = "f32 CUDA requires payoffs in [-1, 1], temperature in [0.005, 1], and at most 8192 iterations"
        elif backend == "auto" and (
            batch < minimum_batch or batch * iterations * width < 16384
        ):
            reason = f"batch below CUDA host-transfer crossover (minimum {minimum_batch} matrices and 16384 action-iterations)"
        if reason and backend == "cuda":
            raise RuntimeError(reason)
    if backend == "rust" or reason:
        packed = np.empty((batch, 2 * actions + 2), dtype=np.float64)
        for index in range(batch):
            p, q, value, gap = solve_anchored(
                matrix[index],
                player[index],
                enemy[index],
                np.flatnonzero(player_mask[index]).tolist(),
                np.flatnonzero(enemy_mask[index]).tolist(),
                iterations,
                temperature=temperature,
            )
            packed[index, :actions] = p
            packed[index, actions : 2 * actions] = q
            packed[index, -2:] = value, gap
        selected = NATIVE_ANCHORED_BACKEND
    else:
        import torch
        import triton

        target = torch.device(device or "cuda")
        if target.type != "cuda":
            raise ValueError("CUDA solver device must be a CUDA device")
        compact, player_order, enemy_order = _compact(
            (matrix, player, enemy, player_mask, enemy_mask)
        )
        width = compact[1].shape[1]
        dtype = torch.float64 if precision == "fp64" else torch.float32
        if precision == "fp32":
            # Normalize in f64 before narrowing to avoid overflow from large,
            # valid unnormalized priors. The kernel still applies its floor.
            compact = list(compact)
            for index in (1, 2):
                values = np.where(compact[index + 2], compact[index], 0.0)
                totals = values.sum(axis=1, keepdims=True)
                compact[index] = np.divide(
                    values, totals, out=np.zeros_like(values), where=totals > 0
                )
        with torch.cuda.device(target):
            inputs = [
                torch.from_numpy(array).to(
                    target, dtype=dtype if array.dtype != np.bool_ else torch.bool
                )
                for array in compact
            ]
            output = torch.empty((batch, 2 * width + 2), device=target, dtype=dtype)
            _kernel()[(batch,)](
                *inputs,
                output,
                iterations,
                temperature,
                ACTIONS=width,
                BLOCK=triton.next_power_of_2(width),
                num_warps=1,
                enable_fp_fusion=False,
            )
            compact_output = output.cpu().numpy()
        packed = np.zeros((batch, 2 * actions + 2), dtype=np.float64)
        np.put_along_axis(
            packed[:, :actions], player_order, compact_output[:, :width], axis=1
        )
        np.put_along_axis(
            packed[:, actions : 2 * actions],
            enemy_order,
            compact_output[:, width : 2 * width],
            axis=1,
        )
        packed[:, -2:] = compact_output[:, -2:]
        selected = (
            CUDA_ANCHORED_BACKEND if precision == "fp64" else "triton-anchored-f32-v1"
        )
    return BatchSolveResult(
        packed[:, :actions],
        packed[:, actions : 2 * actions],
        packed[:, -2],
        packed[:, -1],
        selected,
        reason,
    )
