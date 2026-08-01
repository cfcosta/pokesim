#!/usr/bin/env python3
"""Benchmark the full joint model against its distilled leaf evaluator."""

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
    parser.add_argument("--batch", type=int, default=256)
    parser.add_argument("--rounds", type=int, default=50)
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
                distilled_leaf_evaluator=True,
                leaf_hidden=64,
            )
        )
        .to(device)
        .eval()
    )
    network.configure_inference(arguments.engine)
    rng = np.random.default_rng(20260801)
    features = rng.integers(
        0, 65536, size=(arguments.batch, FULL_FEATURE_COUNT), dtype=np.uint16
    )
    masks = [0x1FFF] * arguments.batch

    network.evaluate_joint(features, masks, masks)
    network.evaluate_leaf(features)

    def full() -> None:
        network.evaluate_joint(features, masks, masks)

    def leaf() -> None:
        network.evaluate_leaf(features)

    full_times = _measure(full, arguments.rounds)
    leaf_times = _measure(leaf, arguments.rounds)
    full_median = statistics.median(full_times)
    leaf_median = statistics.median(leaf_times)
    print(
        json.dumps(
            {
                "schema": "distilled-leaf-benchmark-v1",
                "device": torch.cuda.get_device_name(device),
                "engine": arguments.engine,
                "batch": arguments.batch,
                "rounds": arguments.rounds,
                "full_joint_median_seconds": full_median,
                "leaf_median_seconds": leaf_median,
                "speedup": full_median / leaf_median,
                "leaf_rows_per_second": arguments.batch / leaf_median,
            },
            indent=2,
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
