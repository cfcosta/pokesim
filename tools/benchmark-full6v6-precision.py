#!/usr/bin/env python3
"""Compare strict FP32 and BF16-autocast full-party transformer execution."""

from __future__ import annotations

import argparse
import json
import statistics
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

import torch
from battle_training import FULL_ACTION_COUNT, FULL_FEATURE_COUNT
from battle_training.network import BattleTransformer, TransformerConfig
from torch.nn import functional as F


def model_config(precision: str) -> TransformerConfig:
    return TransformerConfig(
        feature_count=FULL_FEATURE_COUNT,
        action_count=FULL_ACTION_COUNT,
        d_model=128,
        heads=8,
        layers=4,
        feedforward=512,
        precision=precision,
    )


def initialize(precision: str, seed: int) -> BattleTransformer:
    torch.manual_seed(seed)
    torch.cuda.manual_seed_all(seed)
    network = BattleTransformer(model_config(precision)).cuda()
    with torch.no_grad():
        torch.nn.init.xavier_uniform_(network.policy.weight)
        torch.nn.init.normal_(network.policy.bias, std=0.02)
        torch.nn.init.xavier_uniform_(network.value[-2].weight)
        torch.nn.init.normal_(network.value[-2].bias, std=0.02)
    return network


def worker(arguments: argparse.Namespace) -> dict[str, Any]:
    if not torch.cuda.is_available():
        raise RuntimeError("precision benchmark requires CUDA")
    if arguments.precision == "bf16" and not torch.cuda.is_bf16_supported():
        raise RuntimeError("CUDA device does not support BF16")
    torch.use_deterministic_algorithms(True)
    network = initialize(arguments.precision, arguments.seed)
    reference = initialize("fp32", arguments.seed).eval()
    optimizer = torch.optim.AdamW(network.parameters(), lr=2e-4)
    features = torch.randint(
        0,
        65536,
        (arguments.batch_size, FULL_FEATURE_COUNT),
        device="cuda",
        dtype=torch.long,
    )
    target_policy = torch.softmax(
        torch.randn(arguments.batch_size, FULL_ACTION_COUNT, device="cuda"), dim=-1
    )
    target_value = torch.empty(arguments.batch_size, device="cuda").uniform_(-1, 1)

    with torch.inference_mode():
        reference_logits, reference_values = reference(features[:32])
        test_logits, test_values = network.eval()(features[:32])
        reference_policy = torch.softmax(reference_logits, dim=-1)
        test_policy = torch.softmax(test_logits, dim=-1)
        drift = {
            "logit_max_abs": float((reference_logits - test_logits).abs().max()),
            "value_max_abs": float((reference_values - test_values).abs().max()),
            "policy_kl_mean": float(
                (reference_policy * (reference_policy.log() - test_policy.log()))
                .sum(dim=-1)
                .mean()
            ),
            "argmax_disagreement": float(
                (reference_logits.argmax(-1) != test_logits.argmax(-1)).float().mean()
            ),
        }
    del reference
    network.train()

    def train_step() -> torch.Tensor:
        logits, values = network(features)
        policy_loss = (
            -(target_policy * torch.log_softmax(logits, dim=-1)).sum(dim=-1).mean()
        )
        value_loss = F.mse_loss(values, target_value)
        loss = policy_loss + value_loss
        optimizer.zero_grad(set_to_none=True)
        loss.backward()
        torch.nn.utils.clip_grad_norm_(network.parameters(), 1.0)
        optimizer.step()
        return loss

    for _ in range(arguments.warmup):
        train_step()
    torch.cuda.synchronize()
    torch.cuda.reset_peak_memory_stats()
    started = time.perf_counter()
    for _ in range(arguments.steps):
        loss = train_step()
    torch.cuda.synchronize()
    elapsed = time.perf_counter() - started
    peak = torch.cuda.max_memory_allocated()

    network.eval()
    inference: dict[str, dict[str, float]] = {}
    for batch, repetitions in ((1, 100), (8, 100), (32, 60), (96, 40), (128, 40)):
        batch_features = features[:batch]
        with torch.inference_mode():
            for _ in range(10):
                network(batch_features)
            torch.cuda.synchronize()
            started = time.perf_counter()
            for _ in range(repetitions):
                network(batch_features)
            torch.cuda.synchronize()
        duration = time.perf_counter() - started
        inference[str(batch)] = {
            "milliseconds": 1000 * duration / repetitions,
            "states_per_second": batch * repetitions / duration,
        }
    return {
        "precision": arguments.precision,
        "batch_size": arguments.batch_size,
        "steps": arguments.steps,
        "elapsed_seconds": elapsed,
        "examples_per_second": arguments.batch_size * arguments.steps / elapsed,
        "peak_allocated_gib": peak / 2**30,
        "final_loss": float(loss.detach()),
        "inference": inference,
        "drift_vs_fp32": drift,
        "torch": torch.__version__,
        "device": torch.cuda.get_device_name(),
    }


def median_report(rows: list[dict[str, Any]]) -> dict[str, Any]:
    grouped = {
        precision: [row for row in rows if row["precision"] == precision]
        for precision in ("fp32", "bf16")
    }
    fp32_rate = statistics.median(row["examples_per_second"] for row in grouped["fp32"])
    summary: dict[str, Any] = {}
    for precision, values in grouped.items():
        rate = statistics.median(row["examples_per_second"] for row in values)
        summary[precision] = {
            "examples_per_second": rate,
            "training_speedup": rate / fp32_rate,
            "peak_allocated_gib": statistics.median(
                row["peak_allocated_gib"] for row in values
            ),
            "inference_speedup": {
                batch: statistics.median(
                    row["inference"][batch]["states_per_second"] for row in values
                )
                / statistics.median(
                    row["inference"][batch]["states_per_second"]
                    for row in grouped["fp32"]
                )
                for batch in ("1", "8", "32", "96", "128")
            },
            "drift_vs_fp32": values[0]["drift_vs_fp32"],
        }
    return {"runs": rows, "median": summary}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--batch-size", type=int, default=128)
    parser.add_argument("--steps", type=int, default=40)
    parser.add_argument("--warmup", type=int, default=10)
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument("--seed", type=int, default=1234)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--worker", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--precision", choices=("fp32", "bf16"), help=argparse.SUPPRESS)
    arguments = parser.parse_args()
    if arguments.worker:
        print(json.dumps(worker(arguments), sort_keys=True))
        return 0

    rows = []
    for _ in range(arguments.repetitions):
        for precision in ("fp32", "bf16"):
            command = [
                sys.executable,
                __file__,
                "--worker",
                "--precision",
                precision,
                "--batch-size",
                str(arguments.batch_size),
                "--steps",
                str(arguments.steps),
                "--warmup",
                str(arguments.warmup),
                "--seed",
                str(arguments.seed),
            ]
            rows.append(json.loads(subprocess.check_output(command, text=True)))
    report = median_report(rows)
    payload = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if arguments.output:
        arguments.output.write_text(payload)
    print(payload, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
