#!/usr/bin/env python3
"""Paired fixed-position Python/Rust search benchmark, plus service replay.

Real trials include native simulation, neural evaluation and matrix solving.
Replay supplies recorded service results to isolate scheduling/adapter work.
Both modes verify complete results. Warmups, compaction, verification, telemetry
and report serialization are outside timed regions. Run under the training Nix
environment; no production code, run data, or processes are modified.
"""

from __future__ import annotations

import argparse
import functools
import gc
import hashlib
import json
import os
import random
import sys
import threading
import time
from collections import defaultdict
from contextlib import ExitStack
from dataclasses import asdict, replace
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "packages/battle-training"))

import torch
from battle_training.controller import search_controllers_many
from battle_training.joint_search import SimultaneousTreeSearch
from battle_training.native import SEARCH_SERVER, SearchServer
from battle_training.network import load_network
from battle_training.search_native import orchestration_metadata
from battle_training.transformer_pipeline import TransformerPipelineConfig, _new_search


def digest(value):
    return hashlib.sha256(repr(value).encode()).hexdigest()


def process_memory(pid, pss=False):
    try:
        if pss:
            lines = Path(f"/proc/{pid}/smaps_rollup").read_text().splitlines()
            return {
                name: int(
                    next(
                        line.split()[1] for line in lines if line.startswith(name + ":")
                    )
                )
                * 1024
                for name in ("Rss", "Pss")
            }
        return int(Path(f"/proc/{pid}/statm").read_text().split()[1]) * os.sysconf(
            "SC_PAGE_SIZE"
        )
    except (OSError, StopIteration):
        return {} if pss else 0


class MemorySampler:
    def __init__(self, native_pid):
        self.pids = [os.getpid(), native_pid]
        self.stop = threading.Event()
        self.peak = [0, 0]
        self.samples = 0
        self.combined_peak = 0
        self.thread = threading.Thread(target=self.sample, daemon=True)

    def sample(self):
        while not self.stop.is_set():
            current = [process_memory(pid) for pid in self.pids]
            self.peak = [
                max(old, value) for old, value in zip(self.peak, current, strict=True)
            ]
            self.combined_peak = max(self.combined_peak, sum(current))
            self.samples += 1
            self.stop.wait(0.05)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.stop.set()
        self.thread.join()


class Services:
    """Nonoverlapping service timers; optional deterministic record/replay."""

    def __init__(self):
        self.depth = 0
        self.mode = "real"
        self.tape = []
        self.cursor = 0
        self.times = defaultdict(float)
        self.calls = defaultdict(int)
        self.restore = []

    def reset(self, mode):
        self.mode, self.cursor = mode, 0
        self.times.clear()
        self.calls.clear()
        if mode == "record":
            self.tape.clear()

    def wrap(self, cls, method, category):
        descriptor = cls.__dict__[method]
        cm = isinstance(descriptor, classmethod)
        original = descriptor.__func__ if cm else descriptor
        self.restore.append((cls, method, descriptor))

        @functools.wraps(original)
        def measured(*args, **kwargs):
            # Python emits an empty solve at the root backup boundary; Rust
            # omits that no-op. It has no service output/state to replay.
            if category == "solver" and not args[1]:
                return original(*args, **kwargs)
            if self.depth:
                return original(*args, **kwargs)
            self.depth += 1
            start = time.perf_counter()
            try:
                if self.mode == "replay":
                    event = self.tape[self.cursor]
                    self.cursor += 1
                    if event["method"] != method:
                        raise RuntimeError("service replay order differs")
                    rows = args[1]
                    if len(rows) != event["count"]:
                        raise RuntimeError("service replay batch shape differs")
                    if category != "simulator":
                        for position, state in event["effects"]:
                            search = rows[position][0 if category == "solver" else 1]
                            for name, value in state.items():
                                setattr(
                                    search,
                                    name,
                                    value.copy() if isinstance(value, dict) else value,
                                )
                        if category == "solver":
                            for (_, node, _), backend in zip(
                                rows, event["backends"], strict=True
                            ):
                                node.solve_backend = backend
                    return event["output"]
                result = original(*args, **kwargs)
                if self.mode == "record":
                    event = {
                        "method": method,
                        "count": len(args[1]),
                        "output": result,
                        "effects": [],
                    }
                    if category != "simulator":
                        seen = set()
                        for position, row in enumerate(args[1]):
                            search = row[0 if category == "solver" else 1]
                            if id(search) in seen:
                                continue
                            seen.add(id(search))
                            state = {
                                name: getattr(search, name).copy()
                                if isinstance(getattr(search, name), dict)
                                else getattr(search, name)
                                for name in (
                                    "_inference_cache_stats",
                                    "_solver_backends",
                                    "_solver_seconds",
                                )
                            }
                            event["effects"].append((position, state))
                        if category == "solver":
                            event["backends"] = [
                                node.solve_backend for _, node, _ in args[1]
                            ]
                    self.tape.append(event)
                return result
            finally:
                self.times[category] += time.perf_counter() - start
                self.calls[category] += 1
                self.depth -= 1

        setattr(cls, method, classmethod(measured) if cm else measured)

    def __enter__(self):
        self.wrap(SearchServer, "search_steps", "simulator")
        for method in (
            "_pooled_evaluate",
            "_pooled_leaf_evaluate",
            "_pooled_successor_values",
        ):
            self.wrap(SimultaneousTreeSearch, method, "evaluation")
        self.wrap(SimultaneousTreeSearch, "_solve_matrices", "solver")
        return self

    def __exit__(self, *_):
        for cls, method, descriptor in reversed(self.restore):
            setattr(cls, method, descriptor)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--run", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--batch", type=int, default=4)
    p.add_argument("--repeats", type=int, default=12)
    p.add_argument("--warmups", type=int, default=2)
    p.add_argument("--replay-repeats", type=int, default=12)
    p.add_argument("--perturb-heads", action="store_true")
    p.add_argument("--gc-mode", choices=("normal", "disabled"), default="normal")
    p.add_argument("--backend", choices=("paired", "python", "rust"), default="paired")
    p.add_argument("--training-cgroup", type=Path)
    a = p.parse_args()
    if min(a.batch, a.repeats, a.warmups) < 1 or a.replay_repeats < 0:
        p.error(
            "batch, repeats and warmups must be positive; replay repeats nonnegative"
        )
    torch.set_num_threads(1)
    torch.set_num_interop_threads(1)
    cfg = TransformerPipelineConfig(
        **json.loads((a.run / "run.json").read_text())["config"]
    )
    checkpoint = a.run / "checkpoints/policy-000.pt"
    net = load_network(checkpoint, torch.device("cuda"))
    net.configure_inference("compiled")
    if a.perturb_heads:
        torch.manual_seed(90210)
        with torch.no_grad():
            for head in (net.policy, net.opponent_policy, net.value[-2]):
                head.weight.normal_(0, 0.02)
                head.bias.normal_(0, 0.01)
    report = {
        "arguments": {
            k: str(v) if isinstance(v, Path) else v for k, v in vars(a).items()
        },
        "started_at": time.time(),
        "complete": False,
        "checkpoint_sha256": hashlib.sha256(checkpoint.read_bytes()).hexdigest(),
        "simulator_sha256": hashlib.sha256(SEARCH_SERVER.read_bytes()).hexdigest(),
        "rust": orchestration_metadata("rust"),
        "config": asdict(cfg),
        "network_config": asdict(net.config),
        "records": [],
        "scope": "Fixed initial level100 6v6 roots, both controllers, no root noise, deterministic actions. One shared warmed network and one native server; fresh request dedup per trial. Paired order alternates. Training continues. Sampled RSS at 50ms; PSS only at boundaries; memory between paired variants shares allocator history. Replay removes recorded simulator/evaluation/solver work, retaining host adapters and diagnostics. All result fields and RNG states checked outside timing.",
    }
    a.output.parent.mkdir(parents=True, exist_ok=True)

    def save():
        a.output.write_text(json.dumps(report, indent=2) + "\n")

    def telemetry():
        result = {}
        if a.training_cgroup:
            for name in (
                "memory.current",
                "memory.events",
                "memory.pressure",
                "cpu.pressure",
            ):
                try:
                    result[name] = (a.training_cgroup / name).read_text().strip()
                except OSError:
                    pass
        health = a.run.parent / "health-latest.json"
        if health.exists():
            h = json.loads(health.read_text())
            result["training"] = {
                "time": h["time"],
                "stage": h["status"]["stage"],
                "completed": h.get("collection", {}).get("completed"),
            }
        return result

    with ExitStack() as stack:
        server = stack.enter_context(
            SearchServer(request_timeout=180, popular_gate=cfg.popular_gate)
        )
        services = stack.enter_context(Services())
        roots = [
            (server.reset if i == 0 else server.reset_append)(
                772131, i, 6, 6, level100=True, balanced_final_species=True
            )
            for i in range(a.batch)
        ]
        report["roots"] = [
            {
                "player_hash": r.player_hash,
                "enemy_hash": r.enemy_hash,
                "joint_actions": r.player_mask.bit_count() * r.enemy_mask.bit_count(),
            }
            for r in roots
        ]
        expected = None
        gc_active = False
        gc_started, gc_events = {}, []

        def on_gc(phase, info):
            generation = info["generation"]
            if phase == "start" and gc_active:
                gc_started[generation] = time.perf_counter()
            elif phase == "stop" and generation in gc_started:
                gc_events.append(
                    (generation, time.perf_counter() - gc_started.pop(generation))
                )

        gc.callbacks.append(on_gc)
        stack.callback(gc.callbacks.remove, on_gc)

        def trial(backend, mode, index, kind):
            nonlocal expected, roots, gc_active
            if mode != "replay":
                roots = server.compact_many(roots)
            templates = [
                _new_search(
                    server,
                    net,
                    net,
                    replace(cfg, orchestration_backend=backend),
                    random.Random(1000 + i),
                    random.Random(2000 + i),
                )
                for i in range(a.batch)
            ]
            services.reset(mode)
            before_telemetry = telemetry()
            pss_before = [
                process_memory(pid, True) for pid in (os.getpid(), server.process.pid)
            ]
            requested, dedup = (
                server.search_rows_requested,
                server.search_rows_deduplicated,
            )
            torch.cuda.synchronize()
            was_enabled = gc.isenabled()
            if a.gc_mode == "disabled":
                gc.collect()
                gc.disable()
            gc_events.clear()
            gc_active = True
            with MemorySampler(server.process.pid) as memory:
                started, cpu = time.perf_counter(), time.process_time()
                results = search_controllers_many(
                    templates, roots, sample_actions=False
                )
                torch.cuda.synchronize()
                elapsed, cpu_time = (
                    time.perf_counter() - started,
                    time.process_time() - cpu,
                )
            gc_active = False
            if was_enabled and a.gc_mode == "disabled":
                gc.enable()
            service_seconds = dict(services.times)
            value = (
                [asdict(r) for r in results],
                [t.selection_rng.getstate() for t in templates],
                [t.chance_rng.getstate() for t in templates],
            )
            if expected is None:
                expected = value
                report["expected_results"] = value[0]
            if expected != value:
                report["mismatch"] = value[0]
                save()
                raise RuntimeError(
                    f"full result/RNG mismatch: {backend}/{mode}/{index}"
                )
            if mode == "replay" and services.cursor != len(services.tape):
                raise RuntimeError("incomplete replay")
            record = {
                "backend": backend,
                "mode": mode,
                "trial": index,
                "kind": kind,
                "seconds": elapsed,
                "actor_cpu_seconds": cpu_time,
                "services_seconds": service_seconds,
                "orchestration_seconds": elapsed - sum(service_seconds.values()),
                "service_calls": dict(services.calls),
                "fresh_native_rows": server.search_rows_requested
                - requested
                - (server.search_rows_deduplicated - dedup),
                "results_and_rng_sha256": digest(value),
                "exact_parity": True,
                "rss_peak_bytes": memory.peak,
                "rss_samples": memory.samples,
                "combined_rss_peak_bytes": memory.combined_peak,
                "gc_events": list(gc_events),
                "gc_seconds": sum(duration for _, duration in gc_events),
                "pss_before": pss_before,
                "pss_after": [
                    process_memory(pid, True)
                    for pid in (os.getpid(), server.process.pid)
                ],
                "telemetry_before": before_telemetry,
                "telemetry_after": telemetry(),
            }
            report["records"].append(record)
            save()
            print(
                json.dumps(
                    {
                        k: record[k]
                        for k in (
                            "backend",
                            "mode",
                            "trial",
                            "kind",
                            "seconds",
                            "orchestration_seconds",
                            "exact_parity",
                        )
                    }
                ),
                flush=True,
            )

        for i in range(a.warmups + a.repeats):
            order = ("python", "rust") if i % 2 == 0 else ("rust", "python")
            if a.backend != "paired":
                order = (a.backend,)
            for backend in order:
                trial(backend, "real", i, "warmup" if i < a.warmups else "warm")
        if a.replay_repeats:
            trial("python", "record", 0, "capture")
            for i in range(a.replay_repeats + 1):
                for backend in ("python", "rust") if i % 2 == 0 else ("rust", "python"):
                    trial(backend, "replay", i, "warmup" if i == 0 else "warm")
        report["complete"] = True
        report["ended_at"] = time.time()
        save()


if __name__ == "__main__":
    main()
