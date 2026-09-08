#!/usr/bin/env python3
"""Compare complete Python/Rust search results on the real Lean simulator.

Run in the training environment. Uses a saved checkpoint without modifying it,
and independent native servers. Compaction clears dedup outside timed search.
Cold compilation is reported separately; timings include concurrent host load.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import random
import sys
import time
from contextlib import ExitStack
from dataclasses import asdict, replace
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "packages/battle-training"))

import torch
from battle_training.controller import search_controllers_many
from battle_training.native import SEARCH_SERVER, SearchServer
from battle_training.network import load_network
from battle_training.search_native import orchestration_metadata
from battle_training.transformer_pipeline import TransformerPipelineConfig, _new_search


class TracedServer(SearchServer):
    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.trace = []

    def search_steps(self, requests):
        self.trace.append(list(requests))
        return super().search_steps(requests)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", type=Path, required=True)
    parser.add_argument("--checkpoint", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--batch", type=int, default=4)
    parser.add_argument("--trials", type=int, default=4)
    parser.add_argument("--depth", type=int)
    parser.add_argument("--chance-samples", type=int)
    parser.add_argument("--interior-chance-samples", type=int)
    parser.add_argument("--device", choices=("cpu", "cuda"), default="cuda")
    parser.add_argument(
        "--engine", choices=("eager", "compiled", "auto"), default="compiled"
    )
    parser.add_argument("--perturb-heads", action="store_true")
    parser.add_argument("--advance", action="store_true")
    args = parser.parse_args()
    if args.batch < 1 or args.trials < 1:
        parser.error("batch and trials must be positive")
    torch.set_num_threads(1)
    torch.set_num_interop_threads(1)
    cfg = TransformerPipelineConfig(
        **json.loads((args.run / "run.json").read_text())["config"]
    )
    if args.depth is not None:
        cfg = replace(cfg, search_depth=args.depth)
    if args.chance_samples is not None:
        cfg = replace(cfg, chance_samples_per_joint=args.chance_samples)
    if args.interior_chance_samples is not None:
        cfg = replace(cfg, interior_chance_samples=args.interior_chance_samples)
    checkpoint = args.checkpoint or args.run / "checkpoints/policy-000.pt"
    network = load_network(checkpoint, torch.device(args.device))
    network.configure_inference(args.engine)
    if args.perturb_heads:
        torch.manual_seed(90210)
        with torch.no_grad():
            for head in (network.policy, network.opponent_policy, network.value[-2]):
                head.weight.normal_(0, 0.02)
                head.bias.normal_(0, 0.01)
    report = {
        "checkpoint": str(checkpoint),
        "checkpoint_sha256": hashlib.sha256(checkpoint.read_bytes()).hexdigest(),
        "simulator_sha256": hashlib.sha256(SEARCH_SERVER.read_bytes()).hexdigest(),
        "orchestration": orchestration_metadata("rust"),
        "config": asdict(cfg),
        "network_config": asdict(network.config),
        "arguments": {
            k: str(v) if isinstance(v, Path) else v for k, v in vars(args).items()
        },
        "scope": "Exact complete ControllerDecision, request-order and RNG parity; two independent native servers; same network; cold compilation excluded from warm comparisons; wall time includes host contention.",
        "records": [],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with ExitStack() as stack:
        servers = [
            stack.enter_context(
                TracedServer(request_timeout=180, popular_gate=cfg.popular_gate)
            )
            for _ in range(2)
        ]
        roots = [
            [
                (server.reset if i == 0 else server.reset_append)(
                    772131, i, 6, 6, level100=True, balanced_final_species=True
                )
                for i in range(args.batch)
            ]
            for server in servers
        ]
        for trial in range(args.trials + 1):
            paired = []
            for variant in (0, 1) if trial % 2 == 0 else (1, 0):
                backend = ("python", "rust")[variant]
                server = servers[variant]
                roots[variant] = server.compact_many(roots[variant])
                server.trace.clear()
                templates = [
                    _new_search(
                        server,
                        network,
                        network,
                        replace(cfg, orchestration_backend=backend),
                        random.Random(1000 + i),
                        random.Random(2000 + i),
                    )
                    for i in range(len(roots[variant]))
                ]
                if args.device == "cuda":
                    torch.cuda.synchronize()
                before = time.perf_counter()
                results = search_controllers_many(
                    templates, roots[variant], sample_actions=True
                )
                if args.device == "cuda":
                    torch.cuda.synchronize()
                elapsed = time.perf_counter() - before
                record = {
                    "trial": trial,
                    "kind": "cold" if trial == 0 else "warm",
                    "backend": backend,
                    "seconds": elapsed,
                    "results": [asdict(r) for r in results],
                    "requested_rows": sum(map(len, server.trace)),
                    "trace_sha256": hashlib.sha256(
                        repr(server.trace).encode()
                    ).hexdigest(),
                }
                report["records"].append(record)
                paired.append(
                    (
                        record,
                        [t.selection_rng.getstate() for t in templates],
                        [t.chance_rng.getstate() for t in templates],
                    )
                )
            left, right = paired
            if (
                left[0]["results"] != right[0]["results"]
                or left[0]["trace_sha256"] != right[0]["trace_sha256"]
                or left[1:] != right[1:]
            ):
                report["parity"] = False
                args.output.write_text(json.dumps(report, indent=2) + "\n")
                raise RuntimeError(
                    f"search parity failed at trial {trial}; full results saved to {args.output}"
                )
            report["parity"] = True
            args.output.write_text(json.dumps(report, indent=2) + "\n")
            print(
                json.dumps(
                    {
                        "trial": trial,
                        "parity": True,
                        "seconds": {x[0]["backend"]: x[0]["seconds"] for x in paired},
                    }
                ),
                flush=True,
            )
            if args.advance:
                for variant, server in enumerate(servers):
                    decision = next(
                        x[0]["results"]
                        for x in paired
                        if x[0]["backend"] == ("python", "rust")[variant]
                    )
                    requests = [
                        (
                            root.handle,
                            r["player"]["player_action"],
                            r["enemy"]["enemy_action"],
                        )
                        for root, r in zip(roots[variant], decision, strict=True)
                        if not (r["player"]["failure"] or r["enemy"]["failure"])
                    ]
                    roots[variant] = [
                        s
                        for s in server.episode_steps(requests)
                        if not s.done and s.divergence is None
                    ]
                if not roots[0]:
                    break


if __name__ == "__main__":
    main()
