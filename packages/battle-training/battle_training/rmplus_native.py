"""Versioned ctypes bridge to deterministic native RM+/CFR+ kernels."""

from __future__ import annotations

import ctypes
import hashlib
import math
import os
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np

RUST_RMPLUS_BACKEND = "rust-rmplus-v1"
PYTHON_REFERENCE_BACKEND = "python-rmplus-reference-v1"

_STATUS = {
    1: "null pointer",
    2: "invalid matrix or legal-action shape",
    3: "iteration count must be positive",
    4: "legal action is outside the matrix",
    5: "anchor temperature must be finite and positive",
    255: "native solver panic",
}


class NativeRmplusError(RuntimeError):
    """A native solver load, ABI, or input failure."""


@dataclass(frozen=True)
class NativeWarmResult:
    player_policy: list[float]
    enemy_policy: list[float]
    value: float
    exploitability: float
    player_regrets: list[float]
    enemy_regrets: list[float]
    player_strategy_sum: list[float]
    enemy_strategy_sum: list[float]
    solve_count: int


def solver_identity(
    backend: str, cfr_plus: bool, anchor_temperature: float = 0.0
) -> str:
    if anchor_temperature > 0.0:
        # The anchored kernel ignores the CFR+ flag entirely -- it is a
        # different iteration, not a variant of regret matching.
        if backend == RUST_RMPLUS_BACKEND:
            return f"rust-anchored-f64-v1-t{anchor_temperature:g}"
        if backend == PYTHON_REFERENCE_BACKEND:
            return f"python-anchored-f64-reference-v1-t{anchor_temperature:g}"
        raise ValueError(f"unsupported RM+ backend: {backend!r}")
    if backend == RUST_RMPLUS_BACKEND:
        variant = "cfrplus" if cfr_plus else "uniform"
        return f"rust-{variant}-f64-v1"
    if backend == PYTHON_REFERENCE_BACKEND and not cfr_plus:
        return "python-uniform-f64-reference-v1"
    raise ValueError(f"unsupported RM+ backend/variant: {backend!r}/{cfr_plus!r}")


def _library_names() -> tuple[str, ...]:
    if sys.platform == "darwin":
        return ("libbattle_rmplus.dylib",)
    if os.name == "nt":
        return ("battle_rmplus.dll",)
    return ("libbattle_rmplus.so",)


def _library_candidates() -> list[Path]:
    candidates: list[Path] = []
    configured = os.environ.get("BATTLE_RMPLUS_LIB")
    if configured:
        path = Path(configured)
        candidates.extend(path / name for name in _library_names())
        candidates.append(path)
    package_root = Path(__file__).resolve().parents[2]
    for profile in ("release", "debug"):
        candidates.extend(
            package_root / "rmplus-rs" / "target" / profile / name
            for name in _library_names()
        )
    return candidates


def _load_library() -> tuple[ctypes.CDLL, Path]:
    errors = []
    for candidate in _library_candidates():
        if not candidate.is_file():
            continue
        try:
            library = ctypes.CDLL(str(candidate))
        except OSError as error:
            errors.append(f"{candidate}: {error}")
            continue
        required = (
            "battle_rmplus_solve_cold_v1",
            "battle_rmplus_solve_anchored_v1",
            "battle_rmplus_solve_warm_v1",
        )
        missing = [symbol for symbol in required if not hasattr(library, symbol)]
        if missing:
            errors.append(
                f"{candidate}: incompatible ABI, missing {', '.join(missing)}"
            )
            continue
        pointer = ctypes.c_void_p
        library.battle_rmplus_solve_cold_v1.argtypes = [
            ctypes.c_uint32,
            ctypes.c_uint32,
            ctypes.c_uint8,
            pointer,
            pointer,
            pointer,
            pointer,
            ctypes.c_uint32,
            pointer,
            ctypes.c_uint32,
            pointer,
            pointer,
            pointer,
            pointer,
        ]
        library.battle_rmplus_solve_cold_v1.restype = ctypes.c_int32
        library.battle_rmplus_solve_anchored_v1.argtypes = [
            ctypes.c_uint32,
            ctypes.c_uint32,
            ctypes.c_double,
            pointer,
            pointer,
            pointer,
            pointer,
            ctypes.c_uint32,
            pointer,
            ctypes.c_uint32,
            pointer,
            pointer,
            pointer,
            pointer,
        ]
        library.battle_rmplus_solve_anchored_v1.restype = ctypes.c_int32
        library.battle_rmplus_solve_warm_v1.argtypes = [
            ctypes.c_uint32,
            ctypes.c_uint32,
            ctypes.c_uint8,
            pointer,
            pointer,
            pointer,
            pointer,
            ctypes.c_uint32,
            pointer,
            ctypes.c_uint32,
            pointer,
            pointer,
            pointer,
            pointer,
            pointer,
            pointer,
            pointer,
            pointer,
            pointer,
        ]
        library.battle_rmplus_solve_warm_v1.restype = ctypes.c_int32
        return library, candidate.resolve()
    detail = "; ".join(errors) if errors else "no candidate library exists"
    raise NativeRmplusError(
        "battle-rmplus native library is unavailable; run inside `nix develop` "
        f"or build packages/rmplus-rs ({detail})"
    )


_LIBRARY: ctypes.CDLL | None = None
_LIBRARY_PATH: Path | None = None


def _library() -> ctypes.CDLL:
    global _LIBRARY, _LIBRARY_PATH
    if _LIBRARY is None:
        _LIBRARY, _LIBRARY_PATH = _load_library()
    return _LIBRARY


def native_metadata() -> dict[str, str]:
    _library()
    assert _LIBRARY_PATH is not None
    return {
        "backend": RUST_RMPLUS_BACKEND,
        "abi": "battle-rmplus-c-abi-v1",
        "library": _LIBRARY_PATH.name,
        "sha256": hashlib.sha256(_LIBRARY_PATH.read_bytes()).hexdigest(),
        "upstream": "cfcosta/mcts@afc6e5d4ca6f0ce560a52add625e2b1d883b5456",
    }


def native_available() -> bool:
    try:
        _library()
    except NativeRmplusError:
        return False
    return True


def _f64(values: Any, shape: tuple[int, ...]) -> np.ndarray[Any, np.dtype[np.float64]]:
    result = np.ascontiguousarray(values, dtype=np.float64)
    if result.shape != shape:
        raise ValueError(f"expected native RM+ shape {shape}, got {result.shape}")
    if not np.isfinite(result).all():
        raise ValueError("native RM+ arrays must be finite")
    return result


def _legal(
    values: list[int], action_count: int
) -> np.ndarray[Any, np.dtype[np.uint32]]:
    if not values:
        raise ValueError("each side needs at least one legal action")
    if len(set(values)) != len(values) or any(
        action < 0 or action >= action_count for action in values
    ):
        raise ValueError("legal actions must be unique and inside the action space")
    return np.ascontiguousarray(values, dtype=np.uint32)


def _pointer(array: np.ndarray[Any, Any]) -> ctypes.c_void_p:
    return array.ctypes.data_as(ctypes.c_void_p)


def _check(status: int, operation: str) -> None:
    if status:
        raise NativeRmplusError(
            f"native {operation} failed with status {status}: "
            f"{_STATUS.get(status, 'unknown native error')}"
        )


def solve_cold(
    payoff: list[list[float]],
    player_priors: list[float],
    enemy_priors: list[float],
    player_legal: list[int],
    enemy_legal: list[int],
    iterations: int,
    *,
    cfr_plus: bool,
) -> tuple[tuple[float, ...], tuple[float, ...], float, float]:
    action_count = len(payoff)
    if iterations < 1:
        raise ValueError("regret iterations must be positive")
    matrix = _f64(payoff, (action_count, action_count))
    player_prior = _f64(player_priors, (action_count,))
    enemy_prior = _f64(enemy_priors, (action_count,))
    player_actions = _legal(player_legal, action_count)
    enemy_actions = _legal(enemy_legal, action_count)
    player_policy = np.empty(action_count, dtype=np.float64)
    enemy_policy = np.empty(action_count, dtype=np.float64)
    value = ctypes.c_double()
    exploitability = ctypes.c_double()
    status = _library().battle_rmplus_solve_cold_v1(
        action_count,
        iterations,
        int(cfr_plus),
        _pointer(matrix),
        _pointer(player_prior),
        _pointer(enemy_prior),
        _pointer(player_actions),
        len(player_actions),
        _pointer(enemy_actions),
        len(enemy_actions),
        _pointer(player_policy),
        _pointer(enemy_policy),
        ctypes.byref(value),
        ctypes.byref(exploitability),
    )
    _check(status, "cold solve")
    return (
        tuple(float(item) for item in player_policy),
        tuple(float(item) for item in enemy_policy),
        value.value,
        exploitability.value,
    )


def solve_anchored(
    payoff: list[list[float]],
    player_priors: list[float],
    enemy_priors: list[float],
    player_legal: list[int],
    enemy_legal: list[int],
    iterations: int,
    *,
    temperature: float,
) -> tuple[tuple[float, ...], tuple[float, ...], float, float]:
    action_count = len(payoff)
    if iterations < 1:
        raise ValueError("regret iterations must be positive")
    if not math.isfinite(temperature) or temperature <= 0.0:
        raise ValueError("anchor temperature must be finite and positive")
    matrix = _f64(payoff, (action_count, action_count))
    player_prior = _f64(player_priors, (action_count,))
    enemy_prior = _f64(enemy_priors, (action_count,))
    player_actions = _legal(player_legal, action_count)
    enemy_actions = _legal(enemy_legal, action_count)
    player_policy = np.empty(action_count, dtype=np.float64)
    enemy_policy = np.empty(action_count, dtype=np.float64)
    value = ctypes.c_double()
    exploitability = ctypes.c_double()
    status = _library().battle_rmplus_solve_anchored_v1(
        action_count,
        iterations,
        temperature,
        _pointer(matrix),
        _pointer(player_prior),
        _pointer(enemy_prior),
        _pointer(player_actions),
        len(player_actions),
        _pointer(enemy_actions),
        len(enemy_actions),
        _pointer(player_policy),
        _pointer(enemy_policy),
        ctypes.byref(value),
        ctypes.byref(exploitability),
    )
    _check(status, "anchored solve")
    return (
        tuple(float(item) for item in player_policy),
        tuple(float(item) for item in enemy_policy),
        value.value,
        exploitability.value,
    )


def solve_warm(
    payoff: list[list[float]],
    player_priors: list[float],
    enemy_priors: list[float],
    player_legal: list[int],
    enemy_legal: list[int],
    player_regrets: list[float],
    enemy_regrets: list[float],
    player_strategy_sum: list[float],
    enemy_strategy_sum: list[float],
    solve_count: int,
    iterations: int,
    *,
    cfr_plus: bool,
) -> NativeWarmResult:
    action_count = len(payoff)
    if iterations < 1:
        raise ValueError("regret iterations must be positive")
    if solve_count < 0 or solve_count > 0xFFFF_FFFF:
        raise ValueError("native solve count must fit u32")
    matrix = _f64(payoff, (action_count, action_count))
    player_prior = _f64(player_priors, (action_count,))
    enemy_prior = _f64(enemy_priors, (action_count,))
    player_actions = _legal(player_legal, action_count)
    enemy_actions = _legal(enemy_legal, action_count)
    player_regret = _f64(player_regrets, (action_count,)).copy()
    enemy_regret = _f64(enemy_regrets, (action_count,)).copy()
    player_sum = _f64(player_strategy_sum, (action_count,)).copy()
    enemy_sum = _f64(enemy_strategy_sum, (action_count,)).copy()
    count = ctypes.c_uint32(solve_count)
    player_policy = np.empty(action_count, dtype=np.float64)
    enemy_policy = np.empty(action_count, dtype=np.float64)
    value = ctypes.c_double()
    exploitability = ctypes.c_double()
    status = _library().battle_rmplus_solve_warm_v1(
        action_count,
        iterations,
        int(cfr_plus),
        _pointer(matrix),
        _pointer(player_prior),
        _pointer(enemy_prior),
        _pointer(player_actions),
        len(player_actions),
        _pointer(enemy_actions),
        len(enemy_actions),
        _pointer(player_regret),
        _pointer(enemy_regret),
        _pointer(player_sum),
        _pointer(enemy_sum),
        ctypes.byref(count),
        _pointer(player_policy),
        _pointer(enemy_policy),
        ctypes.byref(value),
        ctypes.byref(exploitability),
    )
    _check(status, "warm solve")
    return NativeWarmResult(
        player_policy=[float(item) for item in player_policy],
        enemy_policy=[float(item) for item in enemy_policy],
        value=value.value,
        exploitability=exploitability.value,
        player_regrets=[float(item) for item in player_regret],
        enemy_regrets=[float(item) for item in enemy_regret],
        player_strategy_sum=[float(item) for item in player_sum],
        enemy_strategy_sum=[float(item) for item in enemy_sum],
        solve_count=count.value,
    )
