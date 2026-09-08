#!/usr/bin/env python3
"""Measure cold/warm training search stages in an isolated CUDA process.

Use --run for a saved run and --compare-binary for paired native comparisons.
--python-optimizations enables experimental value-only leaf prior elision and
root-only split-half storage in the candidate process. It never edits training
code or running workers. --perturb-heads avoids the zero-head startup special
case; its seeded random heads are a workload proxy, not a trained policy.

Stage inclusive times overlap; exclusive times subtract nested timed stages.
Profiler repetitions are separate from ordinary cold/warm wall measurements.
"""

import argparse
import cProfile
import functools
import json
import pstats
import random
import resource
import sys
import time
from collections import defaultdict
from contextlib import ExitStack
from dataclasses import replace
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "packages/battle-training"))
import torch
from battle_training import joint_search as joint_module
from battle_training import native
from battle_training.controller import search_controllers_many
from battle_training.joint_search import SimultaneousTreeSearch
from battle_training.native import SearchServer
from battle_training.network import BattleTransformer, load_network
from battle_training.transformer_pipeline import TransformerPipelineConfig, _new_search


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--run", type=Path, required=True)
    p.add_argument("--batch", type=int, default=4)
    p.add_argument("--repeats", type=int, default=3)
    p.add_argument("--engine", default="compiled")
    p.add_argument("--leaf", default="full")
    p.add_argument("--solver", default="auto")
    p.add_argument("--depth", type=int, default=2)
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--profile", action="store_true")
    p.add_argument("--binary", type=Path)
    p.add_argument("--compare-binary", type=Path)
    p.add_argument("--python-optimizations", action="store_true")
    p.add_argument("--perturb-heads", action="store_true")
    a = p.parse_args()
    if a.batch < 1 or a.repeats < 1:
        p.error("batch and repeats must be positive")
    a.output.parent.mkdir(parents=True, exist_ok=True)
    if a.binary:
        native.SEARCH_SERVER = a.binary.resolve()
    run = a.run.resolve()
    cfg = TransformerPipelineConfig(
        **json.loads((run / "run.json").read_text())["config"]
    )
    cfg = replace(
        cfg, leaf_evaluator=a.leaf, solver_backend=a.solver, search_depth=a.depth
    )
    torch.set_num_threads(1)
    torch.set_num_interop_threads(1)
    load_start = time.perf_counter()
    network = load_network(run / "checkpoints/policy-000.pt", torch.device("cuda"))
    network.configure_inference(a.engine)
    if a.perturb_heads:
        torch.manual_seed(90210)
        with torch.no_grad():
            for head in [network.policy, network.opponent_policy, network.value[-2]]:
                head.weight.normal_(0, 0.02)
                head.bias.normal_(0, 0.01)

    report = {
        "arguments": vars(a)
        | {
            "output": str(a.output),
            "run": str(a.run),
            "binary": str(a.binary) if a.binary else None,
            "compare_binary": str(a.compare_binary) if a.compare_binary else None,
        },
        "started_at": time.time(),
        "checkpoint": str(run / "checkpoints/policy-000.pt"),
        "load_seconds": time.perf_counter() - load_start,
        "records": [],
        "scope": "One isolated CUDA actor while training continues; two independent neural controllers per 6v6 root. Same roots/chance seeds each repetition; compact clears native dedup. Wall time includes contention; profiler repetition excluded from warm timing.",
    }
    stack = []
    stats = defaultdict(
        lambda: {
            "calls": 0,
            "inclusive_seconds": 0.0,
            "exclusive_seconds": 0.0,
            "rows": 0,
        }
    )
    batches = []
    recording = False

    def wrap(cls, name, rows=None):
        descriptor = cls.__dict__.get(name)
        cm = isinstance(descriptor, classmethod)
        original = descriptor.__func__ if cm else getattr(cls, name)

        @functools.wraps(original)
        def measured(*args, **kwargs):
            if not recording:
                return original(*args, **kwargs)
            label = cls.__name__ + "." + name
            start = time.perf_counter()
            frame = [label, 0.0]
            stack.append(frame)
            try:
                return original(*args, **kwargs)
            finally:
                elapsed = time.perf_counter() - start
                stack.pop()
                s = stats[label]
                s["calls"] += 1
                s["inclusive_seconds"] += elapsed
                s["exclusive_seconds"] += elapsed - frame[1]
                if rows is not None:
                    count = len(args[rows])
                    s["rows"] += count
                    if cls is BattleTransformer:
                        batches.append(
                            {"method": name, "rows": count, "seconds": elapsed}
                        )
                if stack:
                    stack[-1][1] += elapsed

        setattr(cls, name, classmethod(measured) if cm else measured)

    for method in ["search_steps", "_search_steps_native", "_snapshot", "compact_many"]:
        wrap(
            SearchServer,
            method,
            1 if method in ["search_steps", "_search_steps_native"] else None,
        )
    wrap(SearchServer, "_request_unlocked")
    for method in [
        "evaluate",
        "evaluate_joint",
        "evaluate_leaf",
        "evaluate_leaf_joint",
    ]:
        wrap(BattleTransformer, method, 1)
    for method in [
        "_pooled_evaluate",
        "_pooled_leaf_joint",
        "_pooled_leaf_values",
        "_open_subgames",
        "_settle",
        "_solve_matrices",
    ]:
        if hasattr(SimultaneousTreeSearch, method):
            wrap(
                SimultaneousTreeSearch,
                method,
                1 if method == "_solve_matrices" else None,
            )
    # Isolated candidate only: deepest leaves consume values, never their priors;
    # split-half solutions are requested only for roots. Keep runtime untouched.

    optimize = False
    values_only = False
    original_shape = joint_module.shape_redundant_action_priors
    original_values = SimultaneousTreeSearch._pooled_successor_values.__func__
    original_make = SimultaneousTreeSearch._make_node

    def audit_shape(policy, *args, **kwargs):
        if optimize and values_only:
            return policy
        return original_shape(policy, *args, **kwargs)

    def audit_values(cls, *args, **kwargs):
        nonlocal values_only
        previous = values_only
        values_only = True
        try:
            return original_values(cls, *args, **kwargs)
        finally:
            values_only = previous

    def audit_make(self, snapshot, evaluation=None, width=None):
        previous = self.config
        if optimize and width is not None:
            cached = getattr(self, "_audit_interior_config", None)
            if cached is None:
                cached = replace(previous, split_half_reliability=False)
                self._audit_interior_config = cached
            self.config = cached
        try:
            return original_make(self, snapshot, evaluation, width)
        finally:
            self.config = previous

    joint_module.shape_redundant_action_priors = audit_shape
    SimultaneousTreeSearch._pooled_successor_values = classmethod(audit_values)
    SimultaneousTreeSearch._make_node = audit_make

    with ExitStack() as lifetime:
        binary_paths = [native.SEARCH_SERVER] + (
            [a.compare_binary.resolve()] if a.compare_binary else []
        )
        pairs = []
        for binary in binary_paths:
            native.SEARCH_SERVER = binary
            server = lifetime.enter_context(
                SearchServer(request_timeout=180, popular_gate=cfg.popular_gate)
            )
            roots = [
                (server.reset if i == 0 else server.reset_append)(
                    772131, i, 6, 6, level100=True, balanced_final_species=True
                )
                for i in range(a.batch)
            ]
            pairs.append([server, roots])
        report["roots"] = [
            {
                "player_hash": r.player_hash,
                "enemy_hash": r.enemy_hash,
                "legal_joint_actions": r.player_mask.bit_count()
                * r.enemy_mask.bit_count(),
            }
            for r in pairs[0][1]
        ]
        for repeat in range((a.repeats + 1 + int(a.profile)) * len(pairs)):
            variant = repeat % len(pairs)
            trial = repeat // len(pairs)
            optimize = a.python_optimizations and (variant == 1 or len(pairs) == 1)
            server, roots = pairs[variant]
            roots = server.compact_many(roots)
            pairs[variant][1] = roots
            stats.clear()
            batches.clear()
            rq = server.search_rows_requested
            dd = server.search_rows_deduplicated
            templates = [
                _new_search(
                    server,
                    network,
                    network,
                    cfg,
                    random.Random(1000 + i),
                    random.Random(2000 + i),
                )
                for i in range(a.batch)
            ]
            profiled = a.profile and trial == a.repeats + 1
            profiler = cProfile.Profile() if profiled else None
            torch.cuda.synchronize()
            before = time.perf_counter()
            cpu = time.process_time()
            recording = True
            if profiler:
                profiler.enable()
            try:
                results = search_controllers_many(
                    templates, roots, sample_actions=False
                )
            finally:
                if profiler:
                    profiler.disable()
                recording = False
            torch.cuda.synchronize()
            elapsed = time.perf_counter() - before
            record = {
                "python_optimizations": optimize,
                "repeat": repeat,
                "trial": trial,
                "binary": str(binary_paths[variant]),
                "kind": "profiled" if profiled else "cold" if trial == 0 else "warm",
                "seconds": elapsed,
                "python_cpu_seconds": time.process_time() - cpu,
                "native_rows_requested": server.search_rows_requested - rq,
                "native_rows_deduplicated": server.search_rows_deduplicated - dd,
                "stages": dict(stats),
                "inference_batches": list(batches),
                "results": [
                    {
                        "player_action": r.player.player_action,
                        "enemy_action": r.enemy.enemy_action,
                        "player_policy": r.player.player_policy,
                        "enemy_policy": r.enemy.enemy_policy,
                        "failure": r.failure,
                        "player_diagnostics": r.player.diagnostics,
                        "enemy_diagnostics": r.enemy.diagnostics,
                    }
                    for r in results
                ],
                "python_peak_rss_kib": resource.getrusage(
                    resource.RUSAGE_SELF
                ).ru_maxrss,
                "cuda_allocated": torch.cuda.memory_allocated(),
                "cuda_reserved": torch.cuda.memory_reserved(),
            }
            report["records"].append(record)
            a.output.write_text(json.dumps(report, indent=2) + "\n")
            print(
                json.dumps(
                    {
                        "repeat": repeat,
                        "kind": record["kind"],
                        "seconds": elapsed,
                        "fresh_native_rows": record["native_rows_requested"]
                        - record["native_rows_deduplicated"],
                        "inference_rows": sum(
                            v["rows"]
                            for k, v in stats.items()
                            if k.startswith("BattleTransformer.")
                        ),
                        "failures": sum(r.failure is not None for r in results),
                    }
                ),
                flush=True,
            )
            if profiler:
                profiler.dump_stats(str(a.output.with_suffix(".pstats")))
                with a.output.with_suffix(".profile.txt").open("w") as f:
                    pstats.Stats(profiler, stream=f).strip_dirs().sort_stats(
                        "cumulative"
                    ).print_stats(65)
                    pstats.Stats(profiler, stream=f).strip_dirs().sort_stats(
                        "tottime"
                    ).print_stats(50)
    report["ended_at"] = time.time()
    a.output.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
