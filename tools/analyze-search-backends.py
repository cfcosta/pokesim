#!/usr/bin/env python3
"""Summarize paired fixed-position search benchmarks without mixing warmups."""

import argparse
import gzip
import json
import math
import random
import statistics
from pathlib import Path


def paired_summary(records, mode):
    rows = [r for r in records if r["mode"] == mode and r["kind"] == "warm"]
    by = {
        b: {r["trial"]: r for r in rows if r["backend"] == b}
        for b in ("python", "rust")
    }
    trials = sorted(by["python"].keys() & by["rust"].keys())
    if not trials:
        return None
    ratios = [by["python"][i]["seconds"] / by["rust"][i]["seconds"] for i in trials]
    logs = [math.log(x) for x in ratios]
    rng = random.Random(880301)
    bootstrap = (
        sorted(
            math.exp(statistics.mean(rng.choices(logs, k=len(logs))))
            for _ in range(10000)
        )
        if len(trials) >= 3
        else None
    )
    result = {
        "pairs": len(trials),
        "paired_geometric_speedup": math.exp(statistics.mean(logs)),
        "paired_bootstrap_95_interval": (
            [bootstrap[249], bootstrap[9749]] if bootstrap else None
        ),
        "rust_faster_pairs": sum(r > 1 for r in ratios),
        "backends": {},
    }
    for backend, data in by.items():
        rs = [data[i] for i in trials]
        wall = [r["seconds"] for r in rs]
        result["backends"][backend] = {
            "median_seconds": statistics.median(wall),
            "mean_seconds": statistics.mean(wall),
            "observed_p95_seconds": sorted(wall)[math.ceil(len(wall) * 0.95) - 1],
            "mean_actor_cpu_seconds": statistics.mean(
                r["actor_cpu_seconds"] for r in rs
            ),
            "median_orchestration_seconds": statistics.median(
                r["orchestration_seconds"] for r in rs
            ),
            "mean_orchestration_seconds": statistics.mean(
                r["orchestration_seconds"] for r in rs
            ),
            "mean_services_seconds": {
                name: statistics.mean(r["services_seconds"].get(name, 0) for r in rs)
                for name in ("simulator", "evaluation", "solver")
            },
            "gc_seconds_total": sum(r["gc_seconds"] for r in rs),
            "gc_generations": {
                str(g): sum(gen == g for r in rs for gen, _ in r["gc_events"])
                for g in range(3)
            },
            "native_rows": sorted({r["fresh_native_rows"] for r in rs}),
        }
    result["ratio_of_medians"] = (
        result["backends"]["python"]["median_seconds"]
        / result["backends"]["rust"]["median_seconds"]
    )
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    summary = {
        "scope": "Only complete files and warm trials. Paired bootstrap resamples same-position trial pairs; it describes this contended experiment, not independent positions or a guaranteed speedup. P95 is observed nearest-rank over small samples. Replay supplies cached service results and is not battle throughput.",
        "workloads": {},
        "memory": {},
    }
    conditions = args.directory / "runtime-conditions.json"
    if conditions.exists():
        summary["runtime_conditions"] = json.loads(conditions.read_text())
    paths = sorted(args.directory.glob("*.json")) + sorted(
        args.directory.glob("*.json.gz")
    )
    for path in paths:
        name = path.name.removesuffix(".gz").removesuffix(".json")
        if path.suffix == ".gz":
            with gzip.open(path, "rt") as source:
                d = json.load(source)
        else:
            d = json.loads(path.read_text())
        if not d.get("complete") or name.startswith(("check", "profile")):
            continue
        if "arguments" not in d:
            continue
        rows = d["records"]
        if d["arguments"]["backend"] != "paired":
            warm = [r for r in rows if r["kind"] == "warm"]
            summary["memory"][name] = {
                "backend": d["arguments"]["backend"],
                "batch": d["arguments"]["batch"],
                "within_process_repeatable": len(
                    {r["results_and_rng_sha256"] for r in warm}
                )
                == 1,
                "results_and_rng_sha256": warm[0]["results_and_rng_sha256"],
                "fresh_native_rows": sorted({r["fresh_native_rows"] for r in warm}),
                "actor_pss_median_bytes": statistics.median(
                    r["pss_after"][0]["Pss"] for r in warm
                ),
                "native_pss_median_bytes": statistics.median(
                    r["pss_after"][1]["Pss"] for r in warm
                ),
                "combined_pss_median_bytes": statistics.median(
                    sum(p["Pss"] for p in r["pss_after"]) for r in warm
                ),
                "actor_rss_peak_bytes": max(r["rss_peak_bytes"][0] for r in warm),
                "native_rss_peak_bytes": max(r["rss_peak_bytes"][1] for r in warm),
                "combined_sampled_rss_peak_bytes": max(
                    r["combined_rss_peak_bytes"] for r in warm
                ),
            }
            continue
        summary["workloads"][name] = {
            "batch": d["arguments"]["batch"],
            "perturbed_heads": d["arguments"]["perturb_heads"],
            "gc_mode": d["arguments"]["gc_mode"],
            "exact_parity": all(r["exact_parity"] for r in rows),
            "real": paired_summary(rows, "real"),
            "replay": paired_summary(rows, "replay"),
        }
    (args.directory / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    for name, data in summary["workloads"].items():
        for mode in ("real", "replay"):
            v = data[mode]
            if v:
                print(
                    name,
                    mode,
                    "median_s",
                    *[
                        round(v["backends"][b]["median_seconds"], 4)
                        for b in ("python", "rust")
                    ],
                    "paired_speedup",
                    round(v["paired_geometric_speedup"], 3),
                    "interval",
                    [round(x, 3) for x in v["paired_bootstrap_95_interval"]]
                    if v["paired_bootstrap_95_interval"]
                    else None,
                )
    for name, data in summary["memory"].items():
        print(
            name,
            {k: round(v / 1024**2, 1) for k, v in data.items() if k.endswith("bytes")},
        )


if __name__ == "__main__":
    main()
