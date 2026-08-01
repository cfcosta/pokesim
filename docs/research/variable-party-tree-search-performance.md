# Variable-party tree-search performance

<!-- mode: research -->

## Result

The production 192–320-transition tree is the dominant self-play cost. On the
RTX 3080 Ti, a representative 36-battle variable-party collection completed at
2.62 real decisions/s with the production tree, compared with 37.92 decisions/s
for a complete-root depth-one teacher. The production tree was **14.5× slower
per real decision** and increased the extrapolated 500-battle collection time
from 4.65 to 48.82 minutes.

In the measured baseline this was not primarily RM+ arithmetic. Deeper search was root-local and fragmented
neural evaluation into hundreds of small GPU calls. In the production
microbenchmark, network evaluation consumed 66.8% of wall time, native mechanics
and protocol work consumed 24.7%, and Python—including RM+—consumed 8.5%.

## Setup

| Item | Value |
|---|---|
| GPU | NVIDIA GeForce RTX 3080 Ti, 12,288 MiB |
| Driver | 595.45.04 |
| PyTorch | 2.13.0+cu130 |
| Model | v4 BF16, 492 fields, 940,430 parameters |
| Checkpoint SHA-256 | `88d6fb2621e5542e6c6db0bd7cbf4edbc042905f6fbc5abac5f1f3451d7949f1` |
| Root sample | Eight roots: equal sizes 1–6 plus 1v6 and 6v1 |
| Collection sample | 36 battles covering every ordered 1-to-6 size pair |
| Actor group | Up to 16 live roots |
| Search | Complete root, two deeper rotations, RM+ 16 iterations/update, fresh chance 0.10 |
| Artifact | `/tmp/variable-party-tree-benchmark-36.json` |

Reproduction command:

```sh
nix develop -c python tools/benchmark-variable-party-tree.py \
  CHECKPOINT.pt \
  --output /tmp/variable-party-tree-benchmark.json \
  --roots 8 \
  --collection-episodes 36
```

The benchmark is a performance and target-stability probe, not a gameplay
quality result.

## Search-call profile

| Search tier | ms/root | Transitions/root | Tree nodes | Mean reached depth | Converged | Network | Native | Python |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Complete root | 32.49 | 42.38 | 1.00 | 0.00 | 0.0% | 53.5% | 43.5% | 3.0% |
| Depth 4, budget 96 | 132.25 | 96.00 | 6.00 | 1.75 | 0.0% | 67.2% | 25.1% | 7.7% |
| Depth 4, budget 192 | 292.62 | 192.00 | 14.63 | 2.50 | 12.5% | 67.2% | 22.1% | 10.7% |
| Depth 4, budget 320 | 411.20 | 294.88 | 22.38 | 2.63 | 25.0% | 66.8% | 24.7% | 8.5% |

Depth diagnostics number the root as zero, so configured depth four requires a
reported maximum depth of three. Even at budget 320, the mean reached depth was
2.63 and only two of eight roots met the adaptive convergence condition. The
adaptive 192–320 profile therefore usually spends close to its maximum budget.

A network-only side-swapped decision over 16 roots took 8.95 ms at batch 32, or
0.56 ms/root. Complete root coverage was about 58× slower than network-only
action selection; the production tree was about 734× slower. Complete root
coverage is mandatory for the current teacher, so 32.49 ms/root is the relevant
lower bound unless mechanics transitions or the protocol are changed.

## Fragmented inference

The production eight-root profile made 297 neural calls for 4,494 examples:

| Batch class | Calls | Examples | Network time |
|---|---:|---:|---:|
| Exactly 2 | 133 | 266 | 37.8% |
| At most 16 | 179 | 686 | 51.3% |
| All calls | 297 | 4,494 | 100% |

Calls of batch two processed only 5.9% of examples but consumed 37.8% of neural
wall time. Calls at or below batch 16 processed 15.3% of examples but consumed
51.3% of neural time. These are mostly deeper leaf and fresh-chance evaluations.
The complete root is already batched across live roots; deeper progressive
frontiers are not.

The same production profile issued 338 native requests. Of these, 181 were
single-transition requests caused by fresh chance outcomes. Scalar native calls
accounted for only 0.077 seconds in this sample, so batching neural frontiers is
the larger immediate opportunity. Native execution and JSON feature transport
imposed a roughly 25% floor in this baseline.

## Native follow-up

The server was already a release build. A verbose Lake replay showed every Lean
generated C module compiled with `gcc -O3 -DNDEBUG`; an accidental debug build
was not responsible for native time.

Profiling the response path found that every speculative search leaf built each
492-field side-canonical vector twice: once for JSON and again inside its FNV
fingerprint. The fingerprint is needed for committed replay rows, but
speculative branches never become rows. The optimized protocol now hashes the
already-materialized vectors for full snapshots and emits empty hash values for
speculative `batch` responses. Reset, episode, and compaction responses retain
exactly the previous fingerprints.

A 60-repeat native-only benchmark measured:

| Batch | Baseline µs/transition | Optimized µs/transition | Speedup |
|---:|---:|---:|---:|
| 1 | 305.21 | 200.09 | 1.53× |
| 8 | 316.67 | 192.74 | 1.64× |
| 32 | 303.10 | 193.06 | 1.57× |
| 96 | 303.47 | 192.23 | 1.58× |

A staged measurement attributed most of the improvement to hashing the existing
vectors rather than constructing them again; suppressing the speculative FNV
calculation supplied the remaining 7–10%.

On four interleaved production-tree A/B runs over identical roots, models, and
search seeds, median native wall time fell from 0.724 to 0.497 seconds per eight
roots (**1.46×**). Holding the separately measured neural and Python time
constant, this removes about 11–13% of whole-search wall time. Full and
speculative responses were compared field-for-field. Full snapshots were
identical, while speculative snapshots differed only by their intentionally
empty hash values.

Compiler and runtime experiments were smaller or neutral:

- `-march=x86-64-v3 -mtune=znver4` did not improve throughput;
- GCC LTO improved the native microbenchmark by roughly 3–8%, but made each
  executable link serially for about 17 seconds and would recover only around
  1–2% of whole-search time, so it was not retained;
- jemalloc and pinning the process to either Ryzen 7950X3D CCD did not improve
  the representative batch-96 workload;
- retaining one epoll selector per server instead of creating it per request
  changed throughput by less than 2% and was not retained.

Reproduce the current native microbenchmark with:

```sh
nix develop -c python tools/benchmark-native-search.py \
  --output /tmp/native-search.json
```

The remaining native cost includes mechanics execution, two feature
projections, JSON construction and transport, and Python decoding. Its maximum
whole-search benefit remains smaller than cross-root neural frontier batching.

## Native optimization sequence

Four follow-up changes were measured and committed independently:

1. **Packed observations.** Each 492-field vector is transported as
   little-endian UInt16 data in a Base64 JSON field, with a lossless Nat-array
   fallback. A mutation-friendly Lean encoder reduced a 96-transition response
   from about 318 KiB to 276 KiB and improved native throughput by roughly 5%.
2. **Direct array projection.** The encoder now fills a preallocated 492-element
   array in schema order instead of constructing and flattening intermediate
   lists. All 36 ordered party-size roots and 108 reset/branch/episode snapshots
   matched the prior implementation. Batch-96 throughput improved by 1.23×.
3. **Parallel immutable batches.** Independent transitions and packed snapshot
   rendering run in deterministic eight-way chunks for batches of at least 16.
   Smaller and dependent-handle batches retain sequential semantics. Batches
   from 16 through 96 improved by 3.1–3.3×, while a production tree's native
   phase improved by about 1.44× because most deeper requests remain small.
4. **Handle-only compaction.** Python reuses the observations returned by the
   real episode transition while Lean returns only deterministic replacement
   handles. Sixteen-root compaction fell from about 2.71 ms to 48 µs, roughly
   56×, while the old full-snapshot command remains available for compatibility.

Together, relative to the already fingerprint-optimized server, the four
changes improve native transitions by about 1.15× for scalar and eight-way
requests and 3.9× for batches of 32–96. On the eight-root production-tree probe,
native wall time fell from 0.547 to 0.299 seconds (**1.83×**) and total search
wall time fell from 2.958 to 2.750 seconds (**1.08×**). Neural time was unchanged
and now dominates more strongly.

The next native-specific pass should profile the post-optimization server before
adding complexity. True binary framing could remove Base64 and the remaining
JSON arrays, but the higher-impact system change is still cross-root scheduling
of deeper neural frontiers.

## End-to-end collection

| Search tier | Battles/s | Decisions/s | Mean decisions | Mean chance outcomes | Converged | Estimated 500 battles |
|---|---:|---:|---:|---:|---:|---:|
| Complete root | 1.794 | 37.92 | 21.14 | 29.48 | 0.0% | 4.65 min |
| Budget 96 | 0.349 | 7.34 | 21.00 | 95.96 | 2.6% | 23.86 min |
| Budget 192 | 0.174 | 4.04 | 23.31 | 191.99 | 10.6% | 48.02 min |
| Budget 320 | 0.171 | 2.62 | 15.33 | 300.84 | 21.1% | 48.82 min |

The 36-battle samples recorded one nonfinish for complete-root, two for budgets
96 and 192, and one for budget 320. Nonfinishes remained unlabeled. Battle-rate
comparisons are affected by policy-dependent battle length: budget 320 was
substantially slower per decision than budget 192 but chose shorter battles in
this sample. Decision throughput is the cleaner mechanics/search measurement.

At the measured production rate, 30 iterations require about 24.4 hours of
collection alone. Training, 1,024-game promotion, probes, the campaign suite,
and final evaluation are additional. This estimate is indicative; team draws,
model changes, and search policies alter battle length. The earlier all-6v6 v3
iteration took about 76 minutes to collect 500 battles, consistent with larger
parties increasing the same bottleneck.

## Target stability

Lower budgets are not drop-in performance substitutions. Against budget 320 on
eight identical roots and search seeds:

| Teacher | Mean two-side policy L1 | Argmax disagreement |
|---|---:|---:|
| Complete root | 1.152 | 50.0% |
| Budget 96 | 0.654 | 31.3% |
| Budget 192 | 0.451 | 25.0% |
| Budget 320 | 0 | 0% |

Budget 320's measured exploitability proxy was 0.0595, versus 0.0508 at budget
192 and 0.0497 at budget 96. This is not evidence that smaller budgets are
better: each tier estimates a different partially sampled payoff tree, so the
proxies are noisy and not directly ordered. It does show that extra budget did
not produce a monotonic improvement in this diagnostic. Teacher quality still
requires equal-budget gameplay and held-out tests.

## Neural inference follow-up

The implemented follow-up separates teacher-preserving runtime work from
quality-gated teacher/model alternatives:

1. **Staged eager inference.** Native UInt16 observations use reusable pinned
   buffers, asynchronous CUDA transfer, a device legal-mask lookup, and direct
   position-weight access. The path was bit-identical to the previous eager
   implementation and improved batch-96 latency from 10.85 to 9.10 ms (1.19×).
2. **Bucketed compilation.** The v8 CUDA path uses static 2–256-row buckets with
   `torch.compile(mode="reduce-overhead")`. Matched outputs were bit-identical;
   steady-state gains ranged from 1.29× at batch 8 to 1.38× at batch 96 and 1.78×
   at batch 2. Initial graph compilation remains an explicit startup cost.
3. **Exact output memoization.** Policy/value outputs are cached only by model
   identity, the complete 492-field tuple, and legal mask. Budget-320 roots had
   a 2.3% hit rate and about a 4% median whole-search gain. This is function
   memoization, not mechanics transposition merging.
4. **Complete frontier scheduling.** Recursive simulations now yield resumable
   native and inference frontiers. Sixteen roots raised mean neural batch size
   from 61.6 to 84.2, pooled native waves across the Lean parallel threshold,
   and improved wall time by 1.26× with exact target/action agreement.
5. **Native/GPU double buffering.** Deterministic root cohorts overlap a trailing
   Lean request with leading GPU inference. Median improvement over the frontier
   scheduler was 1.29×; 215 waves overlapped in the representative 16-root run.
6. **Batched evaluation.** Promotion arenas improved 5.62×, campaign arenas
   3.05×, and traced probes 3.17× while retaining reports and replay bytes.
7. **Multi-process actors.** Two spawned Lean/GPU actors merge temporary shards
   by episode index. A 32-episode CUDA probe improved only 1.09×; startup can make
   shorter runs slower, so this is versioned and smoke defaults to one process.
8. **Semantic entity encoder.** The v19 model binds fields through typed local
   projections and categorical species/move embeddings, then attends over 31
   entity tokens plus CLS. At two batch-96 forwards, eager latency fell from
   18.17 to 4.37 ms (4.16×) and compiled latency from 11.49 to 2.25 ms
   (5.11×). Parameter count fell from 940,430 to 900,366. This creates an
   incompatible lineage; latency alone is not gameplay-strength evidence.
9. **Joint physical-state evaluation.** V20 predicts both simultaneous policies
   from one semantic encoding and uses one scalar with exact opposing negation.
   At batch 96, one joint evaluation replaced two side-canonical forwards and
   improved eager latency from 4.78 to 2.26 ms (2.12×) and compiled latency
   from 2.30 to 1.30 ms (1.78×). Distinct models retain separate canonical
   evaluations, so candidate/incumbent semantics do not collapse.
10. **Tiered deep search (quality-gated).** Every move retains a complete root;
   only a configured fraction receives the full tree. A 25% probe improved a
   short collection workload 4.84×, but trajectories changed, so the production
   default remains 100% deep pending equal-budget promotion evidence.
11. **Deferred multi-model CUDA inference.** Pooled search launches all CUDA
    networks before awaiting any result and overlaps CPU heuristic evaluation
    with those launches. Ticket-owned pinned buffers prevent in-flight transfers
    from aliasing same-shaped requests. Two eager 96-row forwards on the RTX
    3080 Ti improved from an 18.17 ms serialized median to 17.23 ms deferred
    (1.055×, ten rounds); batch 32 improved 1.033×. Compiled batch 96 instead
    measured 11.49 ms serialized and 11.70 ms deferred (0.982×), so the pooled
    scheduler deliberately keeps static compiled graphs serialized. This
    preserves outputs and avoids a measured production regression while showing
    that streams alone are not a substitute for a shorter encoder or cheaper
    leaf evaluation.

## Conclusions

1. **The concern is confirmed.** Searching every move is not itself the main
   problem; spending nearly 320 transitions in a root-local depth-four tree at
   every move is. It cuts decision throughput by about 14.5× relative to a
   complete-root target.
2. **The baseline GPU path was launch-bound at depth.** Complete-frontier
   scheduling and double buffering now address that measured fragmentation.
3. **Adaptive stopping rarely saves enough.** Most roots approach the maximum
   transition budget, and the average tree does not fully reach configured
   depth four.
4. **RM+ is not the leading optimization target.** Removing all Python overhead
   could save less than 10% in this profile.
5. **Reducing budget changes the teacher.** Budget 192 still disagreed with the
   budget-320 argmax on 25% of side decisions. A speed change needs strength and
   calibration evidence, not only throughput.

## Recommended order

1. Run the full 36-matchup v8 benchmark with eager and compiled engines, recording
   compilation and process startup separately from steady state.
2. Compare group-one and grouped-token models over multiple training seeds. Do
   not promote grouping from its latency result alone.
3. Compare 96, 192, 320, and tiered teachers at equal wall-clock and transition
   budgets against raw policy, zero-value search, and learned-value search.
4. Tune one through four actor processes on the production workload; the measured
   two-process gain is modest and must not be extrapolated from launch-bound
   assumptions.
5. Keep complete-root supervision on every move and retain the existing paired,
   probe, party-stratum, campaign, and data-quality gates for every Tier-2 change.
