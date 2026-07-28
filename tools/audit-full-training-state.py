#!/usr/bin/env python3
"""Fail when full battle state gains an unaudited field.

This is a source-shape audit, not a Markov proof. Its job is to force every new
Engine.State or Environment.State field into an explicit encoded, latent-chance,
profile-inert, or proof-only bucket before CI accepts it.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

ENGINE = ROOT / "packages/battle-lean/Battle/Full/Engine.lean"
ENVIRONMENT = ROOT / "packages/battle-lean/Battle/Full/Environment.lean"
TRAINING = ROOT / "packages/battle-lean/Battle/RL/FullTraining.lean"
PYTHON_SCHEMA = ROOT / "packages/battle-training/battle_training/__init__.py"

ENGINE_FIELDS = {
    "encoded": {
        "forcedReplacement",
        "queuedReplacement",
        "playerLastMove",
        "enemyLastMove",
        "payDayMoney",
        "playerMoney",
        "trainerPrize",
        "sharedDamage",
        "playerLockedDamage",
        "enemyLockedDamage",
        "playerId",
        "playerOtIds",
        "badges",
        "playerSelection",
        "enemySelection",
        "runAttempts",
        "canceledAction",
        "aiLayer2Encouragement",
        "trainerAiItem",
    },
    "encoded-except-latent-rng": {"battle"},
    "profile-inert": {"playerBag", "enemyBag"},
}

ENVIRONMENT_FIELDS = {
    "encoded": {
        "engine",
        "canEvolveFlags",
        "gainExpFlags",
        "foughtFlags",
        "hasExpAll",
    },
    "profile-inert": {
        "box",
        "partyNames",
        "boxNames",
        "ownedSpecies",
        "pendingCapture",
        "safari",
        "oldManScratch",
        "playerProgression",
        "enemyProgression",
        "trainerClass",
        "trainerActionsLeft",
        "pendingLearning",
        "lastEpilogue",
    },
    "proof-or-generation": {
        "playerReset",
        "enemyReset",
        "repairedReset",
        "playerHistory",
        "enemyHistory",
        "playerRemainingLedger",
        "enemyRemainingLedger",
        "playerHistoryReplays",
        "enemyHistoryReplays",
    },
}


def structure_fields(path: Path, next_marker: str) -> set[str]:
    source = path.read_text()
    start = source.index("structure State where")
    stop = source.index(next_marker, start)
    body = source[start:stop]
    return set(re.findall(r"^  ([A-Za-z][A-Za-z0-9_]*)\s*:", body, re.MULTILINE))


def classified(groups: dict[str, set[str]]) -> set[str]:
    result: set[str] = set()
    for name, fields in groups.items():
        overlap = result & fields
        if overlap:
            raise SystemExit(
                f"duplicate {name} audit classification: {sorted(overlap)}"
            )
        result |= fields
    return result


def require_exact(label: str, actual: set[str], groups: dict[str, set[str]]) -> None:
    expected = classified(groups)
    missing = actual - expected
    stale = expected - actual
    if missing or stale:
        raise SystemExit(
            f"{label} state audit drift: unclassified={sorted(missing)}, "
            f"stale={sorted(stale)}"
        )


def main() -> int:
    engine = structure_fields(ENGINE, "inductive Event where")
    environment = structure_fields(ENVIRONMENT, "structure Observation where")
    require_exact("Engine.State", engine, ENGINE_FIELDS)
    require_exact("Environment.State", environment, ENVIRONMENT_FIELDS)

    training = TRAINING.read_text()
    python_schema = PYTHON_SCHEMA.read_text()
    required_fragments = [
        'def profileVersion : String := "full-link-party-1to6-perfect-v2"',
        'def schemaVersion : String := "full-link-party-state-v4"',
        "#guard featureCount == 492",
        "continuationId continuation",
        "partyShapeFeatures own opponent",
        "partyMonFeatures side index",
        "sampled_link_reset_satisfies_profile",
    ]
    for fragment in required_fragments:
        if fragment not in training:
            raise SystemExit(f"missing Lean schema audit guard: {fragment}")
    if 'FULL_PROFILE = "full-link-party-1to6-perfect-v2"' not in python_schema:
        raise SystemExit("Python full profile does not match Lean variable-party profile")
    if 'FULL_SCHEMA = "full-link-party-state-v4"' not in python_schema:
        raise SystemExit("Python full schema does not match Lean v4")
    if "FULL_FEATURE_COUNT = 492" not in python_schema:
        raise SystemExit("Python full feature count does not match Lean")

    report = {
        "profile": "full-link-party-1to6-perfect-v2",
        "schema": "full-link-party-state-v4",
        "feature_count": 492,
        "engine_fields": len(engine),
        "environment_fields": len(environment),
        "known_alias_fixed": "mimic-pending-continuation; absent-party-slot-fallback",
        "formal_status": "reset-invariant-proved; preservation-and-injectivity-open",
    }
    print(json.dumps(report, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
