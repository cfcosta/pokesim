"""Build and invoke the deterministic native Lean actor."""

from __future__ import annotations

import json
import os
import subprocess
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

from . import ENTROPY, FEATURE_COUNT, PROFILE, SCHEMA
from .artifacts import sha256, write_json

REPO_ROOT = Path(__file__).resolve().parents[3]
LEAN_PACKAGE = REPO_ROOT / "packages" / "battle-lean"
WORKER = LEAN_PACKAGE / ".lake" / "build" / "bin" / "battleTrainingWorker"


@dataclass(frozen=True)
class WorkerRequest:
    episodes: int
    seed: int
    budget: int
    epsilon_byte: int
    weights: Path
    controlled_side: str
    emit_transitions: bool = True

    def command(self) -> list[str]:
        return [
            str(WORKER),
            str(self.episodes),
            str(self.seed),
            str(self.budget),
            str(self.epsilon_byte),
            str(self.weights.resolve()),
            self.controlled_side,
            "1" if self.emit_transitions else "0",
        ]

    def manifest(self, root: Path) -> dict[str, Any]:
        value = asdict(self)
        value["weights"] = self.weights.resolve().relative_to(root.resolve()).as_posix()
        return value


def build_worker() -> None:
    command = ["lake", "-d", str(LEAN_PACKAGE), "build", "battleTrainingWorker"]
    result = subprocess.run(command, cwd=REPO_ROOT, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(
            f"native worker build failed\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
    if not WORKER.is_file():
        raise RuntimeError(f"native worker missing after build: {WORKER}")


def validate_shard(path: Path, request: WorkerRequest) -> dict[str, Any]:
    counts: dict[str, int] = {}
    episode_ids: set[int] = set()
    transition_count = 0
    meta = None
    with path.open() as source:
        for line_number, line in enumerate(source, 1):
            try:
                row = json.loads(line)
            except json.JSONDecodeError as error:
                raise ValueError(f"invalid JSON at {path}:{line_number}: {error}") from error
            row_type = row.get("type")
            if row_type == "meta":
                if meta is not None or line_number != 1:
                    raise ValueError("shard must contain exactly one leading meta row")
                meta = row
            elif row_type == "episode":
                episode_ids.add(row["episode"])
                counts[row["stop"]] = counts.get(row["stop"], 0) + 1
                if row["stop"] == "finished" and row["return"] not in (-1, 0, 1):
                    raise ValueError("finished episode has invalid terminal return")
                if row["stop"] != "finished" and row["return"] is not None:
                    raise ValueError("non-finished episode has a fabricated return")
            elif row_type == "transition":
                transition_count += 1
                if row["side"] != request.controlled_side:
                    raise ValueError("transition side differs from worker request")
                if len(row["features"]) != FEATURE_COUNT:
                    raise ValueError("transition feature count differs from schema")
                int(row["state_hash"])
            else:
                raise ValueError(f"unknown row type at line {line_number}: {row_type}")
    expected_ids = set(range(request.episodes))
    if episode_ids != expected_ids:
        raise ValueError(f"episode IDs differ: {episode_ids ^ expected_ids}")
    expected_meta = {
        "profile": PROFILE,
        "schema": SCHEMA,
        "entropy": ENTROPY,
        "feature_count": FEATURE_COUNT,
        "controlled_side": request.controlled_side,
        "episodes": request.episodes,
        "seed": request.seed,
        "budget": request.budget,
        "epsilon_byte": min(request.epsilon_byte, 256),
    }
    for key, expected in expected_meta.items():
        if meta is None or meta.get(key) != expected:
            raise ValueError(f"meta mismatch for {key}: {None if meta is None else meta.get(key)}")
    return {
        "episodes": request.episodes,
        "transitions": transition_count,
        "stops": counts,
        "sha256": sha256(path),
        "bytes": path.stat().st_size,
    }


def run_worker(path: Path, request: WorkerRequest) -> dict[str, Any]:
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        with path.open("xb") as output:
            result = subprocess.run(
                request.command(),
                cwd=REPO_ROOT,
                stdout=output,
                stderr=subprocess.PIPE,
                text=True,
                env={**os.environ, "LC_ALL": "C"},
            )
        if result.returncode:
            raise RuntimeError(
                f"native worker failed ({result.returncode}): {' '.join(request.command())}\n"
                f"stderr:\n{result.stderr}"
            )
        summary = validate_shard(path, request)
        summary["stderr"] = result.stderr.strip()
        return summary
    except Exception:
        path.unlink(missing_ok=True)
        raise


def write_request(path: Path, root: Path, request: WorkerRequest, summary: dict[str, Any]) -> None:
    write_json(
        path,
        {
            "worker_protocol": "battle-training-worker-v1",
            "request": request.manifest(root),
            "summary": summary,
        },
    )
