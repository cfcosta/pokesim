import json
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, "/home/cfcosta/Code/_tmp/pokemon/gpt/packages/battle-training")
from dataclasses import replace

import torch
from battle_training.arena import ArenaEvaluationPool, _run_fast_arena_games
from battle_training.network import load_network
from battle_training.transformer_pipeline import (
    TransformerPipelineConfig,
    _arena_config,
)


def main():
    cgroup = Path("/sys/fs/cgroup") / Path(
        "/proc/self/cgroup"
    ).read_text().strip().split("::")[1].lstrip("/")
    limit = (cgroup / "memory.max").read_text().strip()
    if limit == "max" or int(limit) > 32 * 1024**3:
        raise RuntimeError("Probe requires MemoryMax=32G or less.")
    result = {
        "processes": 4,
        "games": 64,
        "decision_budget": 1,
        "precision": "bf16",
        "engine": "compiled",
        "samples": [],
    }
    stop = threading.Event()

    def sample():
        while not stop.wait(0.1):
            result["samples"].append(
                {
                    "time": time.monotonic(),
                    "memory_bytes": int((cgroup / "memory.current").read_text()),
                }
            )

    t = threading.Thread(target=sample, daemon=True)
    t.start()
    torch.set_num_threads(1)
    root = Path("/media/pokemon-training/v33-bf16-20260908-021523/run")
    config = TransformerPipelineConfig(
        **json.loads((root / "run.json").read_text())["config"]
    )
    candidate = load_network(root / "checkpoints/policy-000.pt", torch.device("cuda"))
    baseline = load_network(root / "checkpoints/policy-000.pt", torch.device("cuda"))
    for model in [candidate, baseline]:
        model.configure_inference("compiled")
    ac = replace(_arena_config(config, 64, config.seed + 70000000 + 10007, 8), budget=1)
    start = time.monotonic()
    with ArenaEvaluationPool(candidate, baseline, 4) as pool:
        episodes = _run_fast_arena_games(
            candidate, baseline, ac, False, pool=pool, capture_details=True
        )
    result["seconds"] = time.monotonic() - start
    result["episodes"] = len(episodes)
    result["semantic_divergences"] = sum(
        e.stop == "semantic-divergence" for e in episodes
    )
    stop.set()
    t.join()
    result["peak_bytes"] = int((cgroup / "memory.peak").read_text())
    out = Path(
        "/home/cfcosta/Code/_tmp/pokemon/gpt/output/v33-incident-20260908/pool-four-workers.json"
    )
    out.write_text(json.dumps(result, separators=(",", ":")) + "\n")
    print(json.dumps({k: v for k, v in result.items() if k != "samples"}), flush=True)


if __name__ == "__main__":
    main()
