# Training battle performance audit — 2026-09-08

There is substantial avoidable work, but this audit does **not** establish a 10×
increase in completed training battles. The strongest controlled search result
is a **1.22×** improvement from a semantics-preserving native lookup prototype.
The monitor also spends **700 ms publishing one actor update**, and the running
service was suffering avoidable memory-pressure throttling. These are concrete
priorities before changing the network or buying more GPU capacity.

All measurements and prototype sources are in
[the evidence directory](../../output/v33-performance-audit-20260908/).
[summary.json](../../output/v33-performance-audit-20260908/summary.json) records
hashes, paired results, disjoint stage totals, and memory-window calculations.

## Scope and measurement boundaries

The live run is `/media/pokemon-training/v33-bf16-20260908-154254/run`, source
`ae7ab24ff423901236f12f4568328d8afb990c83`. Hardware: Ryzen 7950X3D
(16 cores / 32 logical CPUs), RTX 3080 Ti (12 GB), CUDA BF16. Collection uses
8 actors × 16 battles; evaluation is configured for 4 actors. The model has
5,026,678 parameters, six 256-wide transformer layers, and 32 semantic tokens.
Search uses depth 2, four root chance samples, interior width 3, two interior
chance samples, the full leaf evaluator, compiled inference, and the automatic
CUDA RM+ solver with 2,048 root iterations.

A **completed battle** is an episode completion; a **decision/transition** is an
actual episode step. A **native row** is a speculative simulator transition.
A **neural row** is one feature evaluation. These denominators are not
interchangeable. Branches must not be reported as completed battles.

The clean live observation covers 178.009 seconds, 18:48:52–18:51:50 UTC, with
90 samples. It excludes the overlap with the first shadow benchmark. The
observer requested the dashboard every two seconds, matching the UI refresh
interval; this includes normal monitoring cost, not an observer-free ceiling.

Later shadow benchmarks ran in separate processes with an 8 GiB hard cap and
Nice=10 while training continued. Their wall times include machine contention.
Cold model compilation and a separate cProfile repetition are excluded from
warm medians. Repeated roots and chance seeds are fixed; compaction clears
native request deduplication **outside** search timing. Production collection
also has reset, compaction, reporting, and scheduling costs outside this search
boundary. Three or five warm repetitions characterize these cohorts, not a
confidence interval or a guaranteed maximum.

The run remained in collection during this audit. Learner backpropagation,
whole-iteration throughput, later trained checkpoints, and evaluation arena
throughput were **not measured**. Shared-code observations apply to evaluation
as hypotheses until that phase runs. Checkpoint zero has zero policy/value
heads; a second experiment uses seeded nonzero random heads as a workload
proxy, not as evidence about a trained policy's strength.

## Live throughput and memory stalls

The initial observation completed **77 battles / 3,704 decisions**:

| Quantity | Observed value |
| --- | ---: |
| Completed battles per second | 0.433 |
| Actual decisions per second | 20.81 |
| Mean active battles / configured capacity | 89.3 / 128 (69.8%) |
| Actor CPU core-equivalents | 5.78 |
| Native simulator CPU core-equivalents | 12.09 |
| Peak training cgroup RAM in this window | 39.96 GiB |

Later, RAM crossed the service's 40 GiB `MemoryHigh`. This is a throttling
threshold, not just an alert. Memory PSI showed sustained stalls, including
full-pressure moving averages around 30%, with over a million `high` events.
There were no OOM or hard-limit events.

At 19:06:17 UTC I raised **only the runtime soft threshold to 46 GiB**, retaining
`MemoryMax=48G`, no swap, and the disk guard. Training was not restarted. The
launch metadata and run notes record the adjustment.

| Successive observation windows | 40 GiB soft threshold | 46 GiB soft threshold |
| --- | ---: | ---: |
| Duration | 31.08 s | 31.41 s |
| Actual decisions/s | 10.68 | 18.30 |
| Completed battles/s | 0.386 | 0.605 |
| Full memory stall time / interval, from PSI total deltas | 13.56% | 0.00098% |

The post-change window follows ten seconds of settling. Its final RAM was
40.98 GiB; high events stopped increasing. The stall removal is directly
observed. The throughput ratio is **observational**, since battle mix and batch
occupancy changed between windows. Raising a threshold does not fix memory
allocation or establish long-run stability near the 48 GiB hard cap.

A separate PSS snapshot attributed approximately 16.6 GiB to Python actors,
19.5 GiB to native servers, 1.0 GiB to the trainer, and 4.1 GiB to other helpers.
PSS avoids summing shared-library RSS repeatedly; cgroup usage also includes
other accounting. This snapshot does not distinguish a leak from retained
allocator/state-pool high-water memory. Eight independent CUDA processes also
replicate context/compiler overhead despite the network's small parameter
count. Memory and throughput should be measured together in any worker sweep.

## Where search time goes

For four fixed 6v6 roots, both independently controlled sides produced
42,096 requested speculative rows, of which 21,048 were deduplicated:
**21,048 actual native transitions**, **18,284 neural rows**, 73 inference calls,
and 2,400 solved matrices per search batch.

Warm batch times were 3.435, 2.933, and 3.191 seconds. The table partitions the
mean wall duration using exclusive nested timers; inclusive stage times must
not be added together.

| Work | Mean seconds per four-root batch | Wall share |
| --- | ---: | ---: |
| Native request/wait/wire exchange | 1.007 | 31.6% |
| Snapshot decoding | 0.331 | 10.4% |
| Native request construction | 0.033 | 1.0% |
| Search request caching/dedup orchestration | 0.074 | 2.3% |
| Neural evaluation including transfers/synchronization | 0.442 | 13.9% |
| Python feature/cache/prior orchestration | 0.749 | 23.5% |
| Opening subgames outside nested work | 0.302 | 9.5% |
| Settling outside nested work | 0.144 | 4.5% |
| Matrix solving | 0.068 | 2.1% |
| Other search orchestration | 0.038 | 1.2% |

The separately profiled repetition made approximately 3.72 million Python
calls. Redundant-action prior shaping ran 36,568 times (348 ms cumulative);
node creation took 279 ms. Snapshot decoding included 42,096 base64 decodes
(155 ms cumulative). These profiler durations overlap and incur instrumentation
overhead; they are explanatory evidence, not extra additive percentages.

Final successor evaluation in `joint_search.py::_pooled_successor_values`
consumes values while `_pooled_evaluate` also shapes action policies. Interior
nodes allocate dense 13×13 payoff/count arrays and split-half arrays although
interior searches use 3×3 actions and split-half diagnostics are root-only.
The isolated Python candidate skips unused final-leaf prior shaping and
interior split-half storage. It does not yet implement a dedicated value-only
network/data path.

## Native simulator: proven lookup prototype

A 30-second CPU profile sampled all eight **live** native servers at 99 Hz:
33,078 samples, no lost samples. Explicit `List.find?` and type-match predicate
symbols account for about **33% of self CPU samples**. Generic `lean_apply_1`
accounts for another 22.9%; that entire generic dispatch cost cannot safely be
attributed to type lookup. String building and base64 encoding also appear.

`Battle/TypeChart.lean::matchup` scans an 82-entry ordered list. Feature
projection repeatedly asks for move/switch effectiveness. The isolated
prototype derives a 65,536-entry table from that exact scan, then indexes it.
It preserves raw UInt8 inputs, including unused/glitch type IDs. It does not
change the order-sensitive damage fold or its integer rounding.

Validation:

- `matchup_equals_ordered_scan` proves equality for **every UInt8 pair**, using a
  finite `native_decide` matrix and a universal wrapper. The axiom report is
  retained; this uses Lean's native-decision trust mechanism, with no `sorry`.
- The reference still uses the unchanged cartridge-backed `typeEffects` list.
  This is refinement of that existing cartridge-backed behavior, not a new
  proof of arbitrary cartridge execution.
- The isolated search server built successfully (135 build targets).
- Twelve games, party sizes 1–6, 301 actual steps and additional counterfactual
  branches produced **1,818 identical snapshot comparisons**. All snapshot
  fields except process-local handles were compared, including hashes/features.
- The recorded native charge regression passed on the candidate.

Five alternating warm trials on identical four-root inputs:

| Boundary | Baseline median | Lookup candidate median | Ratio |
| --- | ---: | ---: | ---: |
| Whole search batch | 3.156 s | 2.586 s | **1.22×** |
| Native request stage | 1.144 s | 0.473 s | 2.42× |

Policies and selected actions were exactly equal. The nonzero-head workload
with both the lookup and Python candidate measured **3.081 → 2.684 s (1.15×)**,
also with identical policies/actions. That is a different workload: it performs
38,436 actual native rows rather than 21,048. These experiments do not isolate
the incremental Python benefit, and their ratios must not be multiplied.

The production Lean source and running executable were **not replaced**.
The applyable patch, proof axiom report, differential results, and binary hashes
are retained in the evidence directory.

## The previous native benchmark measured cache hits

`tools/benchmark-native-search.py` previously warmed and repeatedly timed the
same requests. Native deduplication satisfied those requests without running
new simulations. It therefore could not support simulator-throughput claims.

The corrected benchmark clears dedup outside every timed sample and asserts
exactly the requested number of fresh native rows. It reports cache hits and
compaction separately. Examples on the original binary:

| Request batch | Fresh median | Cache-hit median |
| --- | ---: | ---: |
| 1 | 289 µs | 3 µs |
| 16 | 1,160 µs | 15 µs |
| 96 | 6,604 µs | 143 µs |

The lookup candidate's fresh medians were 98, 524, and 3,049 µs respectively.
These microbenchmarks ran in separate contended windows, so the alternating
whole-search comparison above is stronger evidence of improvement. Neither
cache-hit rate nor native branches/s is completed training battles/s. The final
tool uses nearest-rank p95; the earlier retained native measurement files use
the previous floor-rank calculation. Only medians from those files are used here.

## Monitoring is expensive enough to affect collection

`transformer_pipeline.py::publish_progress` republishes recent battle timelines
after every actor decision. `monitor.py::atomic_monitor_json` pretty-prints,
sorts, flushes, fsyncs, and atomically replaces the entire payload. At capture,
eight actor files totaled roughly 211 MB. One frozen actor file contained
47 recent battles / 2,135 timeline entries and occupied 29.46 MB.

Five writes per variant on the **same training filesystem**, retaining fsync:

| Same captured actor | Bytes | Median publication |
| --- | ---: | ---: |
| Current complete, indented payload | 29,462,284 | **700.8 ms** |
| Complete payload, compact JSON | 13,489,708 | 108.4 ms |
| Progress counters only | 7,687 | 0.887 ms |

Compact formatting round-trips to exactly the same JSON data and makes this
publication 6.47× faster. Progress-only publication requires storing completed
replays separately; it must not remove battle visibility. The UI also parses
changed full actor histories before dropping them from portions of its
response. Parsing this single captured full file took 113.7 ms versus 47 µs
for counters alone.

A separate 30-second, already memory-throttled live window measured 16.6 MiB/s
of actor disk writes and 22.7 MiB/s of native wire output. It is not the initial
baseline window and cannot be combined with that baseline's CPU percentages.
The publication benchmark also must not be advertised as a 6× or 790× whole
training gain. Its impact varies with active batch size and history length.

The recommended design is a small current-progress record plus completed
replays written once and loaded on demand. Keep real-time battle visibility;
stop repeatedly serializing immutable history in the collection hot path.

## CUDA is active; search structure dominates expansion

The CUDA trace confirms BF16 Tensor Core GEMMs, FlashAttention, and generated
Triton kernels. Warm batch-256 neural evaluation took 4.12–4.36 ms compiled
versus 6.09 ms eager (20 repetitions per configuration). Three profiled compiled
evaluations launched 615 actual CUDA kernels with 9.463 ms summed kernel
duration and 47.4 µs summed memcpy duration. Compiled-region annotations overlap
kernel events; adding the profiler's entire aggregate table would double-count.

The search solver diagnostics confirm the Triton anchored FP32 solver. Its
roughly 2% share makes a solver rewrite a low priority for this measured
cohort. Even eliminating all measured neural-evaluation time would bound the
four-root search improvement around 1.16× if the remaining work stayed fixed.
This bound is cohort-specific, not a claim about future learner workloads.

The tree currently expands a dense simultaneous lookahead, rather than
selectively allocating UCT visits. A typical root has 9×9 joint actions:

`81 × 4 = 324 root successors; 324 × (1 + 3×3×2) = 6,156 speculative steps`

That is per controller per actual decision, before terminal filtering and
cross-controller deduplication. Two controllers can share identical branches,
but the nonzero-head experiment shows substantially less overlap.

Sixteen-root warm searches took median 12.661 s, or 0.791 s/root, versus
0.798 s/root at batch four. Larger batches did not materially improve per-root
throughput in this cohort. They increase request size and memory. The actual
batch-64 startup already exceeded the native 60-second request timeout.
Amortized seconds/root also do not establish a three-second interactive
response bound: batch completion latency and queueing need separate tests.

Collection fills a batch and waits for its remaining battles before refilling.
The observed 69.8% occupancy suggests scheduling headroom, but the naive
`1 / occupancy ≈ 1.43` is **not** a measured speedup: remaining battles may be
more expensive. Native parallelism can also multiply eight actors by eight
native tasks. Initial CPU pressure was modest; oversubscription has not been
shown to be the primary bottleneck.

## Priority order and acceptance criteria

1. **Decouple progress from replay storage.** Verify that the UI still shows
   live and completed battles; compare serialization CPU, bytes written,
   decisions/s and completed battles/s on the same episode seeds.
2. **Integrate the proven lookup.** Keep the universal refinement proof and
   existing cartridge table provenance; rerun native differential and ROM
   regression gates before deploying a new training executable.
3. **Remove unused leaf-policy and interior-array work.** Validate complete
   policies, values, targets and diagnostics on nonzero and trained networks,
   then measure allocation, PSS and whole-decision time.
4. **Refill battle slots continuously and sweep concurrency.** Compare actors,
   native thread count and batch sizes with equal total episode workloads,
   reporting throughput, latency, RAM, PSI, GPU utilization and divergences.
5. **Reduce snapshot/object/wire overhead.** Evaluate packed batched feature
   transport and fewer Python objects after the first changes alter the profile.
6. **Consider selective search for order-of-magnitude savings.** Reducing dense
   expansion can remove far more work than kernel tuning, but changes targets
   and potentially playing strength. Compare search quality, held-out arena
   results, calibration and the three-second inference budget at equal compute.

Do not multiply local speedup ratios. An actual 10× claim needs a fixed episode
cohort, unchanged correctness/target gates where applicable, controlled hardware
load, and a complete collection/evaluation/learning iteration comparison.

## Reproduction and retained artifacts

Use the project's training Nix environment and the recorded run configuration.
To avoid rebuilding the active executable, explicitly provide `--binary` to the
native benchmark. For example, from the repository root:

```sh
PYTHONPATH=packages/battle-training python tools/benchmark-native-search.py \
  --binary packages/battle-lean/.lake/build/bin/battleSearchServer \
  --repeats 20 --output /tmp/native-fresh.json

python tools/benchmark-training-search-stages.py \
  --run /media/pokemon-training/v33-bf16-20260908-154254/run \
  --batch 4 --repeats 5 --output /tmp/search-stages.json
```

For a paired candidate, build the saved patch in a separate Lean checkout and
pass `--compare-binary /path/to/candidate/battleSearchServer`. Add
`--python-optimizations --perturb-heads` to reproduce the second workload.
The tool uses checkpoint zero explicitly; use a separately controlled experiment
for later policies. `--profile` produces an additional profiled repetition,
excluded from ordinary warm timing.

`live-observation.jsonl` contains raw sampled evidence. `native-cpu-profile.txt`
and `native-cpu-callers.txt` retain perf reports; raw 267 MB perf data remains at
`/tmp/pokemon-native-live.perf.data`. The CUDA trace remains at
`/tmp/pokemon-inference-trace.json`; its kernel summary is committed. These `/tmp`
files are ephemeral. The evidence directory also retains the one-off observation,
monitor, inference and differential scripts with their original paths/configuration;
inspect those paths before reuse. They are audit reproductions, not production
entry points. Native benchmark counters, paired output equality, isolated Lean
build/proof, and the differential/charge regression were checked. No production
training-code changes were made during this audit.
