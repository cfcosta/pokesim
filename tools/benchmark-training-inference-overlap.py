#!/usr/bin/env python3
"""Benchmark serialized versus deferred multi-network CUDA inference."""

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
    parser.add_argument("--rounds", type=int, default=20)
    parser.add_argument("--engine", choices=("eager", "compiled"), default="eager")
    parser.add_argument(
        "--token-layout",
        choices=("scalar-v1", "semantic-entity-v1"),
        default="scalar-v1",
    )
    arguments = parser.parse_args()
    if not torch.cuda.is_available():
        raise SystemExit("CUDA is required")

    configure_determinism(20260801)
    device = torch.device("cuda")
    config = TransformerConfig(
        feature_count=FULL_FEATURE_COUNT,
        action_count=FULL_ACTION_COUNT,
        d_model=128,
        heads=8,
        layers=4,
        feedforward=512,
        precision="bf16",
        token_layout=arguments.token_layout,
    )
    first = BattleTransformer(config).to(device).eval()
    second = first.detached_copy(device)
    first.configure_inference(arguments.engine)
    second.configure_inference(arguments.engine)
    rng = np.random.default_rng(20260801)
    features = rng.integers(
        0, 65536, size=(arguments.batch, FULL_FEATURE_COUNT), dtype=np.uint16
    )
    masks = [0x1FFF] * arguments.batch

    # Warm every static model/shape before timing compilation-independent latency.
    first.evaluate(features, masks)
    second.evaluate(features, masks)

    def sequential() -> None:
        first.evaluate(features, masks)
        second.evaluate(features, masks)

    def deferred() -> None:
        left = first.begin_evaluate(features, masks)
        right = second.begin_evaluate(features, masks)
        left.result()
        right.result()

    sequential_times = _measure(sequential, arguments.rounds)
    deferred_times = _measure(deferred, arguments.rounds)
    sequential_median = statistics.median(sequential_times)
    deferred_median = statistics.median(deferred_times)
    print(
        json.dumps(
            {
                "schema": "training-inference-overlap-benchmark-v1",
                "device": torch.cuda.get_device_name(device),
                "engine": arguments.engine,
                "token_layout": arguments.token_layout,
                "batch_per_network": arguments.batch,
                "networks": 2,
                "rounds": arguments.rounds,
                "sequential_median_seconds": sequential_median,
                "deferred_median_seconds": deferred_median,
                "speedup": sequential_median / deferred_median,
                "deferred_rows_per_second": (2 * arguments.batch / deferred_median),
            },
            indent=2,
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
