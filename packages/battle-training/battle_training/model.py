"""A minimal terminal-return learner used to prove the pipeline end to end."""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from . import ENTROPY, MOVE_COUNT, PROFILE, SCHEMA
from .artifacts import sha256, write_json, write_new


@dataclass
class MoveValueModel:
    """Monte-Carlo move values mapped to the native worker's integer scores."""

    returns: list[float] = field(default_factory=lambda: [0.0] * MOVE_COUNT)
    counts: list[int] = field(default_factory=lambda: [0] * MOVE_COUNT)

    @property
    def scores(self) -> list[int]:
        result = []
        for total, count in zip(self.returns, self.counts, strict=True):
            mean = total / count if count else 0.0
            mean = max(-1.0, min(1.0, mean))
            result.append(round((mean + 1.0) * 1000.0))
        return result

    def update_shard(self, path: Path, discount: float = 0.97) -> dict[str, int]:
        episode_lengths: dict[int, int] = {}
        rows: list[dict[str, Any]] = []
        with path.open() as source:
            for line in source:
                row = json.loads(line)
                if row["type"] == "episode":
                    episode_lengths[row["episode"]] = row["transitions"]
                elif row["type"] == "transition":
                    rows.append(row)

        updates = 0
        skipped = 0
        for row in rows:
            terminal_return = row["return"]
            if terminal_return is None:
                skipped += 1
                continue
            move = row["move_id"]
            action = row["action_id"]
            if not 0 <= move < MOVE_COUNT:
                raise ValueError(f"move ID outside schema: {move}")
            if not 0 <= action < 4 or not (row["legal_mask"] & (1 << action)):
                raise ValueError(f"illegal recorded action: {row}")
            remaining = episode_lengths[row["episode"]] - row["step"] - 1
            target = float(terminal_return) * (discount**remaining)
            self.returns[move] += target
            self.counts[move] += 1
            updates += 1
        return {"updates": updates, "skipped_unlabeled": skipped}

    def checkpoint(
        self, directory: Path, index: int, provenance: dict[str, Any]
    ) -> dict[str, Any]:
        stem = f"policy-{index:03d}"
        weights_path = directory / f"{stem}.weights"
        checkpoint_path = directory / f"{stem}.json"
        write_new(weights_path, ("\n".join(map(str, self.scores)) + "\n").encode())
        payload = {
            "checkpoint_schema": "move-value-monte-carlo-v1",
            "profile": PROFILE,
            "state_schema": SCHEMA,
            "entropy": ENTROPY,
            "index": index,
            "scores": self.scores,
            "returns": self.returns,
            "counts": self.counts,
            "provenance": provenance,
            "weights_sha256": sha256(weights_path),
        }
        write_json(checkpoint_path, payload)
        return {
            "checkpoint": checkpoint_path,
            "weights": weights_path,
            "weights_sha256": payload["weights_sha256"],
        }

    @classmethod
    def from_checkpoint(cls, path: Path) -> MoveValueModel:
        payload = json.loads(path.read_text())
        if payload["profile"] != PROFILE or payload["state_schema"] != SCHEMA:
            raise ValueError("checkpoint profile/schema mismatch")
        model = cls(returns=list(payload["returns"]), counts=list(payload["counts"]))
        if model.scores != payload["scores"]:
            raise ValueError("checkpoint score derivation mismatch")
        return model
