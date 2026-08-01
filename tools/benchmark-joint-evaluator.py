#!/usr/bin/env python3
"""Benchmark two side-canonical forwards against one joint physical-state forward."""

from __future__ import annotations

import argparse
import json
import statistics
import sys
import time
from pathlib import Path

import numpy as np
import torch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "packages" / "battle-training"))

from battle_training import FULL_ACTION_COUNT, FULL_FEATURE_COUNT
from battle_training.network import (
    BattleTransformer,
    TransformerConfig,
    configure_determinism,
)


def _measure(function: object, rounds: int) -> list[float]:
    samples = []
    for _ in range(rounds):
        torch.cuda.synchronize()
        started = time.perf_counter()
        function()  # type: ignore[operator]
        torch.cuda.synchronize()
        samples.append(time.perf_counter() - started)
    return samples


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--batch", type=int, default=96)
    parser.add_argument("--rounds", type=int, default=20)
    parser.add_argument("--engine", choices=("eager", "compiled"), default="compiled")
    arguments = parser.parse_args()
    if not torch.cuda.is_available():
        raise SystemExit("CUDA is required")

    configure_determinism(20260801)
    device = torch.device("cuda")
    network = (
        BattleTransformer(
            TransformerConfig(
                feature_count=FULL_FEATURE_COUNT,
                action_count=FULL_ACTION_COUNT,
                d_model=128,
                heads=8,
                layers=4,
                feedforward=512,
                precision="bf16",
                token_layout="semantic-entity-v1",
                joint_policy_heads=True,
            )
        )
        .to(device)
        .eval()
    )
    network.configure_inference(arguments.engine)
    rng = np.random.default_rng(20260801)
    player = rng.integers(
        0, 65536, size=(arguments.batch, FULL_FEATURE_COUNT), dtype=np.uint16
    )
    enemy = rng.integers(
        0, 65536, size=(arguments.batch, FULL_FEATURE_COUNT), dtype=np.uint16
    )
    masks = [0x1FFF] * arguments.batch

    network.evaluate(player, masks)
    network.evaluate(enemy, masks)
    network.evaluate_joint(player, masks, masks)

    def side_canonical() -> None:
        network.evaluate(player, masks)
        network.evaluate(enemy, masks)

    def joint() -> None:
        network.evaluate_joint(player, masks, masks)

    side_times = _measure(side_canonical, arguments.rounds)
    joint_times = _measure(joint, arguments.rounds)
    side_median = statistics.median(side_times)
    joint_median = statistics.median(joint_times)
    print(
        json.dumps(
            {
                "schema": "joint-physical-evaluator-benchmark-v1",
                "device": torch.cuda.get_device_name(device),
                "engine": arguments.engine,
                "batch": arguments.batch,
                "rounds": arguments.rounds,
                "side_canonical_median_seconds": side_median,
                "joint_median_seconds": joint_median,
                "speedup": side_median / joint_median,
                "joint_states_per_second": arguments.batch / joint_median,
            },
            indent=2,
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
