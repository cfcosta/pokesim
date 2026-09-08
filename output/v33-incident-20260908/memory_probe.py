import json
import os
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, "/home/cfcosta/Code/_tmp/pokemon/gpt/packages/battle-training")
from dataclasses import replace

import torch
from battle_training import arena
from battle_training.network import load_network
from battle_training.transformer_pipeline import (
    TransformerPipelineConfig,
    _arena_config,
)

RUN = Path("/media/pokemon-training/v33-bf16-20260908-021523/run")
size = int(sys.argv[1])
engine = sys.argv[2] if len(sys.argv) > 2 else "compiled"
result = {
    "batch_size": size,
    "games": 86,
    "engine": engine,
    "stage": "loading",
    "samples": [],
    "rounds": [],
    "search_seconds": 0.0,
}
stop = threading.Event()
native_pid = None
cgroup = Path("/sys/fs/cgroup") / Path("/proc/self/cgroup").read_text().strip().split(
    "::"
)[1].lstrip("/")
limit = (cgroup / "memory.max").read_text().strip()
if limit == "max" or int(limit) > 14 * 1024**3:
    raise RuntimeError("Run this probe in a systemd cgroup with MemoryMax=14G or less.")


def rss(pid):
    try:
        for l in Path(f"/proc/{pid}/status").read_text().splitlines():
            if l.startswith("VmRSS:"):
                return int(l.split()[1]) * 1024
    except OSError:
        pass
    return 0


def sample():
    while not stop.wait(0.1):
        row = {
            "stage": result["stage"],
            "time": time.monotonic(),
            "python_rss": rss(os.getpid()),
            "native_rss": rss(native_pid) if native_pid else 0,
            "cgroup_bytes": int((cgroup / "memory.current").read_text()),
        }
        result["samples"].append(row)


t = threading.Thread(target=sample, daemon=True)
t.start()
torch.set_num_threads(1)
config = TransformerPipelineConfig(
    **json.loads((RUN / "run.json").read_text())["config"]
)
candidate = load_network(RUN / "checkpoints/policy-000.pt", torch.device("cuda"))
baseline = load_network(RUN / "checkpoints/policy-000.pt", torch.device("cuda"))
for model in [candidate, baseline]:
    model.configure_inference(engine)
ac = _arena_config(
    config, 2048, config.seed + 70000000 + 10007, config.promotion_seed_count
)


class Finished(Exception):
    pass


orig = arena._rmplus_search_many


def measured(server, episodes, config):
    global native_pid
    native_pid = server.process.pid
    result["stage"] = "search"
    started = time.monotonic()
    results = orig(server, episodes, config)
    result["search_seconds"] += time.monotonic() - started
    result["rounds"].append(
        {
            "games": [e.game for e in episodes],
            "results": [
                {
                    "player_action": r.player_action,
                    "enemy_action": r.enemy_action,
                    "player_policy": r.player_policy,
                    "enemy_policy": r.enemy_policy,
                    "failure": r.failure,
                }
                for r in results
            ],
        }
    )
    result["native_search_rows"] = (
        server.search_rows_requested - server.search_rows_deduplicated
    )
    result["stage"] = "between_batches"
    return results


arena._rmplus_search_many = measured
try:
    episodes = arena._run_fast_arena_spans(
        candidate,
        baseline,
        replace(ac, budget=1),
        False,
        arena._arena_batch_spans(86, size),
        True,
    )
    result["results"] = len(episodes)
    result["stage"] = "done"
finally:
    stop.set()
    t.join()
    result["peak"] = {
        k: max((x[k] for x in result["samples"]), default=0)
        for k in ["python_rss", "native_rss", "cgroup_bytes"]
    }
    out = (
        Path("/home/cfcosta/Code/_tmp/pokemon/gpt/output/v33-incident-20260908")
        / f"memory-cohort86-batch{size}-{engine}.json"
    )
    out.write_text(json.dumps(result, indent=2) + "\n")
    print(
        json.dumps({k: v for k, v in result.items() if k not in ["samples", "rounds"]}),
        flush=True,
    )
