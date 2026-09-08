# Python versus Rust search benchmark — 2026-09-08

This compares the two backends from `6380aed8ed7f`. The primary complete-search
cohorts ran alongside the existing Python training run; a later disk-guard pause
affected the follow-up cohorts as detailed below. Production search code and training configuration were
not changed. The benchmark uses the packaged Rust library and the same Lean
simulator, model, solver, positions and RNG seeds for both backends.

## Measurement boundaries

- **Complete search:** one decision for every battle in the batch, including
  both independent neural controllers, native simulation and decoding,
  neural evaluation, matrix solving, action selection and result construction.
  These are decisions, not completed battle episodes.
- **Service replay:** repeat the same tree workload with recorded simulator,
  evaluator and solver outputs. This isolates tree scheduling, data conversion,
  adapters and result diagnostics. It is not a simulator throughput benchmark.
- **Orchestration residual:** complete-search wall time minus nonoverlapping
  simulator, evaluator and solver service time. Evaluation service time includes
  Python feature/cache/prior work as well as CUDA. GC and scheduling pauses are
  charged to whichever stage they interrupt.
- **Memory:** separate fresh processes for Python and Rust, each with one native
  server and the same batch-16 workload. PSS is read before/after trials; RSS is
  sampled every 50 ms. Sampled peaks can miss short spikes. Actor/native RSS
  cannot be added as a claim about unique physical memory; PSS accounts for
  shared pages. Paired timing trials share allocator history and are not used
  as the clean backend memory comparison.

Reset/compaction, dedup clearing, model loading, warmup, result verification,
telemetry and report writes are outside the search timer. A single shared model
and native server serve both backends, with Python/Rust order reversed on each
pair. Two warmup trials per backend are discarded, including cold compilation.
Every real trial must simulate the same number of fresh native rows; replay
simulates zero. Complete controller results and post-search RNG states are
checked exactly outside timing against the first trial in that process. The
paired cohorts are the Python-versus-Rust parity check; single-backend memory
cohorts only check repeatability within their own process.

Hardware is a Ryzen 7950X3D and RTX 3080 Ti 12 GB. The saved configuration uses
BF16 compiled inference, depth two, four root chance samples, interior width
three and two interior chance samples. Solver arithmetic remains the same
Triton FP32 path. The primary cohort uses seeded nonzero random heads on
checkpoint zero; these are a workload proxy, not a trained checkpoint. A separate
cohort retains the actual zero startup heads. All positions are fixed initial
level-100 6v6 states, with no root noise and deterministic final action selection.
Actual training also includes smaller parties and heuristic opponents.

One benchmark worker runs at a time, at Nice=10 with a 12 GiB cgroup hard cap
and no swap. The primary batch-1/4/16 complete-search comparisons ran with training active.
At 19:48:50 UTC the disk guard froze training because root free space fell below
8 GiB; the training volume itself still had about 74 GiB free. Batch-16 replay,
startup-head, memory, GC-disabled and profile cohorts ran with training frozen.
Batch-1/4 normal-GC replay ran before that pause. A separate normal-GC batch-four
replay was added during the pause to match the GC-disabled cohort's conditions.
These are paired measurements on fixed workloads, not machine-capacity numbers.
Raw scope strings reflect the original intent to keep training active;
`runtime-conditions.json` and this report correct that description using the
watchdog and systemd freeze record.
The GC-disabled replay is an explicit benchmark-only ablation; production GC
is unchanged. It forces collection before, outside, each timed call.

## Results

Rust gives a modest end-to-end improvement on these fixed workloads. It does
not establish a large battle-throughput gain. The batch-one medians are tied;
normal-GC batch-four and batch-sixteen medians improve by 7.1% and 5.2% in latency.

| Simultaneous battles | Warm pairs | Python median | Rust median | Python / Rust median | Fresh native transitions per call |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 | 12 | 1.235 s | 1.237 s | 1.00× | 11,204 |
| 4 | 12 | 4.706 s | 4.371 s | 1.08× | 38,436 |
| 16 | 8 | 17.332 s | 16.437 s | 1.05× | 155,686 |

These times cover the entire batch and both controllers. Dividing by batch size
gives amortized cost, not a battle's response latency. Batch one was below the
three-second target in every warm trial (observed maxima 1.561 s Python and
1.378 s Rust), but fixed initial positions cannot establish a response-time
bound for arbitrary battle states.

The geometric means of within-pair speed ratios are 1.031× [0.984, 1.078],
1.055× [1.004, 1.108], and 1.093× [1.047, 1.144], respectively; brackets are
paired bootstrap 95% intervals. These differ from ratios of medians because
Python's larger-batch timings have occasional longer pauses.

### Where the time goes

Mean seconds per complete batch-16 call, with nonoverlapping service boundaries:

| Stage | Python | Rust |
| --- | ---: | ---: |
| Native simulation, IPC and response decoding | 9.460 | 9.421 |
| Evaluation, including Python features/cache/priors and CUDA | 5.216 | 4.994 |
| Matrix solver service | 0.301 | 0.367 |
| Remaining orchestration and adapters | 2.913 | 1.554 |
| Total | 17.891 | 16.335 |

About 88% of the Rust call remains inside the unchanged simulation and evaluation
services. These stage timings cannot isolate Lean compute from decoding or GPU
compute from feature processing; another profile is required to divide those
costs. The same service implementations run for both backends, so differences
also include GC placement and concurrent-training scheduling.

### Service replay and garbage collection

With the services replaced by recorded outputs, median orchestration times are:

| Batch | Warm pairs | Python | Rust | Paired geometric speedup [95% interval] |
| --- | ---: | ---: | ---: | ---: |
| 1 | 12 | 0.232 s | 0.050 s | 1.878× [0.840, 3.922] |
| 4 | 16 | 0.632 s | 0.369 s | 1.679× [1.514, 1.854] |
| 16 | 8 | 2.086 s | 1.246 s | 1.639× [1.572, 1.703] |

Batch-one replay is bimodal because occasional generation-two collections cost
roughly 0.2 seconds. Its ratio of medians would exaggerate the evidence for a
consistent speedup. At batch four, mean replay GC time falls from 0.459 s to
0.204 s. At batch sixteen, GC across the complete search averages 4.387 s for
Python and 2.821 s for Rust. GC is already included in wall/stage times; it must
not be added to them. GC callback boundaries include sampler setup/teardown just
outside the wall timer, so GC totals are diagnostic approximations.

### GC-disabled replay

Across 24 warm batch-four replay pairs with GC disabled during search, median
time is 0.1116 s for Python versus 0.1029 s for Rust. Paired geometric speedup
is 1.088× [1.077, 1.099]. A matching normal-GC cohort with training frozen
has medians 0.4744 s versus 0.2699 s over 24 pairs, with geometric speedup
1.680× [1.564, 1.788]. The large normal-GC advantage therefore persists with
training frozen, while disabling GC narrows it substantially.
This supports reduced collection cost as a major contributor to the normal-GC
advantage. These are separate replay cohorts with training frozen, not
an exact decomposition of the primary timing difference. The ablation's single
warm real pair is retained in the raw data but is insufficient for a separate
end-to-end claim; its bootstrap interval is intentionally omitted.

### Remaining work identified by the profile

The separate batch-four GC-disabled replay profile records 497,850 calls for
Python and 328,092 for Rust. Rust still reconstructs 2,392 Python node views,
performs 12,024 ctypes-to-NumPy conversions, and converts more than 42,000
snapshot metadata rows. Its node-view conversion costs 0.048 s cumulatively and
metadata conversion 0.028 s, out of a 0.145 s profiled search. These are diagnostic
profile timings, not substitutes for the unprofiled table. The profile wrapper
disables the RSS sampler, whose thread contaminated the first profile; profile
cohort RSS fields are therefore zero and are excluded from memory conclusions.

The next implementation target within orchestration is the adapter boundary:
pass contiguous metadata and matrix buffers in bulk, and avoid rebuilding Python
lists for every native node before calling the existing solver. For a larger
whole-search gain, profile and reduce simulator/decoding and evaluation/feature
work, or reduce the 155,686 speculative transitions generated by this dense
batch-16 search. This experiment does not establish which pruning policy would
preserve playing strength, nor does it measure completed battles per second.

All paired cohorts pass exact full-result and RNG parity. No backend was
switched in the live training job. After measurements, generated perf artifacts
and the TorchInductor cache were relocated to the training volume with symlinks
preserving their old paths. Root free space rose to 8.52 GiB. The service was
thawed and dashboard progress advanced to 1,467 completed battles, confirming
that collection resumed.

### Actual startup checkpoint

With the checkpoint's unmodified zero heads, batch-four medians are 2.488 s for
Python and 2.202 s for Rust: 11.5% lower latency, or a 1.13× ratio of medians.
The eight within-pair ratios have geometric mean 1.106× [1.076, 1.133]. Each call
simulates 21,048 fresh transitions, versus 38,436 with the nonzero-head proxy.
The startup cohort also ran after training froze, so its lower latency cannot
be attributed to head values alone. Its lower transition count demonstrates a
cheaper workload; startup timing should not stand in for later performance.

### Memory

Separate process measurements with training frozen, after two warmups and with
three retained trials:

| Batch-16 footprint | Python | Rust |
| --- | ---: | ---: |
| Actor median PSS | 2,308.5 MiB | 2,267.4 MiB |
| Native simulator median PSS | 5,218.5 MiB | 5,253.2 MiB |
| Median combined PSS | 7,526.5 MiB | 7,520.6 MiB |
| Sampled simultaneous combined RSS peak | 8,251.6 MiB | 8,246.5 MiB |

There is no meaningful demonstrated total-memory reduction. The native simulator
accounts for roughly 70% of proportional resident memory. These are host process
measurements, not VRAM or the entire training cgroup. Their sum is not an estimate
for the live mixed-workload eight-actor training job.

The fresh processes are **not bit-identical across processes**: Python produces
155,670 fresh transitions per call and Rust 155,686, with small policy/payoff
and cache-count differences. Both are individually repeatable; all paired
Python/Rust timing cohorts are exact within their shared process. The source of
this cross-process numerical variation was not isolated, so the memory table
is an approximate footprint comparison under the same configuration and seeds,
not a strict parity-controlled attribution of the tiny memory delta. The raw
results retain the differences for follow-up.

## Evidence and reproduction

Raw observations, configuration, result fingerprints, stage times, GC events,
memory and live-training pressure telemetry are retained in
[`output/search-backend-benchmark-20260908`](../../output/search-backend-benchmark-20260908/).
`provenance.json` pins the benchmark source, hardware and native-library setup.
`summary.json` contains all derived statistics. Raw trial reports are losslessly
compressed as `.json.gz`; the analyzer accepts both compressed and plain JSON.
The profiling wrapper and text call profiles are saved beside the reports.
`validation.json` records archive hashes and checks over 319 trials, including
warmups, capture and smoke/profile runs. Every file completed, every within-file
result/RNG fingerprint was stable, fresh transition counts were constant within
each real cohort, and replay generated no native transitions. Automatic-GC
ablation warm samples recorded no collections; its cold compilation warmup did
trigger explicit collections. The live training cgroup's OOM-kill and memory-high
event counters did not increase during the recorded trials.

The main tables use ratios of median wall times. The summary also reports the
geometric mean of within-pair speed ratios and a paired bootstrap interval
(10,000 resamples). Those intervals describe repeat timing variation on the
fixed positions under contention; they are not independent battle samples or
guarantees. Reported p95 is the observed nearest-rank statistic over only 8–12
warm samples per backend; it is not a worst-case response-time bound.

Inside the training environment:

```sh
python tools/benchmark-search-backends.py --run /path/to/run \
  --batch 4 --warmups 2 --repeats 12 --replay-repeats 16 \
  --perturb-heads --output /tmp/backends-b4.json

python tools/benchmark-search-backends.py --run /path/to/run \
  --batch 16 --backend python --warmups 2 --repeats 3 \
  --replay-repeats 0 --perturb-heads --output /tmp/memory-python.json
# Repeat in a fresh process with --backend rust.

python tools/benchmark-search-backends.py --run /path/to/run \
  --batch 4 --warmups 2 --repeats 1 --replay-repeats 24 \
  --gc-mode disabled --perturb-heads --output /tmp/backends-no-gc.json

python output/search-backend-benchmark-20260908/profile-replay.py \
  --run /path/to/run --batch 4 --warmups 1 --repeats 1 \
  --replay-repeats 1 --gc-mode disabled --perturb-heads \
  --output /tmp/profile.json

python tools/analyze-search-backends.py /path/to/evidence-directory
```

Simulator/solver/evaluator services keep their original implementations. The
replay shim restores their recorded counter/backend side effects as well as
outputs so result diagnostics remain comparable. Python's extra empty solver
call is a no-op and is omitted from the replay tape. Capture and profiler runs
are kept separate from the primary warm comparisons.
