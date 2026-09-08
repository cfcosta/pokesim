# V33 search and training validation

<!-- mode: research -->

Validation date: 2026-09-08. This report distinguishes numerical correctness,
controller behavior, simulator regressions, hardware throughput, and evidence
of learned playing strength. The implementation is described in the
[controller design](../explanation/search-assisted-controller.md).
The [validation record](../../output/v33-validation.json) preserves commands,
log hashes, proof source hashes, and links to the measured reports.

## Corrected learning contract

The pre-v33 [audit](learning-signal-investigation.md) reproduced a win-value
ranking reversal from tactical potential shaping, evaluator contamination
between opponents, and incorrect agreement metrics. V33 removes the potential
bonus, evaluates each controller with its own checkpoint and canonical view,
and publishes the mean-matrix solution without averaging split-half policies.

Partitioning follows originating resets across both paired legs, frontier
restarts, and team replay. Agreement uses numeric two-head counts and correct
fractional-weight denominators. Checkpoint loading explicitly selects deployed
or learner state. Production promotion needs evidence from the current
candidate's search-assisted arena; raw-policy and historical pooled results
cannot substitute.

Regression tests exercise these failures directly. Eager and compiled
inference honor the requested precision. BF16 training retains FP32 loss,
gradients, parameters, and optimizer moments. Deterministic shard diagnostics
record actual matrix backends without wall-clock timings.

## Simulator corrections discovered by real search

A native decision benchmark on seed 772131, episode 2 reached a Mirror Move
path that the old simulator classified as a semantic cycle. The cartridge
explicitly rejects copying Mirror Move itself; the Lean effect recursively
invoked it instead. The corrected effect follows the cartridge failure rule.

Following a successful copy exposed a second defect: nested moves lost the
pending opposing action and turn completion. The typed nested-move result now
carries that continuation through the engine, environment, self-play, and
native adapters. Regressions cover the concrete observed failure and successful
copies in both action-order positions.

The canonical ROM was rebuilt with pinned RGBDS and verified against SHA-256
`5ca7ba01642a3b27b0cc0b5349b52792795b62d3ed977e98a09390659af96b7b`.
Two proof modules consume explicit canonical byte-window certificates:

- [MirrorMoveRoutine](../../packages/battle-lean/Battle/Rom/MirrorMoveRoutine.lean)
  executes the selector and rejection branch for both sides and all 256 history
  bytes through architectural and physical SM83 semantics. Its decoded physical
  result includes the real cartridge boundary opcodes. It also proves the
  failure-return tail for every accumulator value, and connects the rejection
  decision to the high-level effect. Rendering and successful data reloading
  are explicit routine boundaries.
- [NestedMoveRoutine](../../packages/battle-lean/Battle/Rom/NestedMoveRoutine.lean)
  executes the cartridge CALL/JP/RET control windows for both wrappers, sides,
  and action-order positions. Architectural checks cover every opposing
  selected-move byte; physical checks cover the dispatch/reentry paths.
  Symbolic theorems prove that JP preserves arbitrary memory and stack, and
  RET consumes one frame. The outer-driver theorem explicitly assumes
  nonterminal helper returns preserving selection; it does not prove those
  helper bodies. Four Engine lemmas establish continuation preservation,
  exactly-once completion, and interruption behavior under the corresponding
  high-level action-result hypotheses.

Both modules are registered in the full library and canonical-ROM fixture
checker. A mutation of the certified reload opcode is rejected. These are
cartridge-backed local behavior proofs, not a new full-battle bisimulation.

Final validation passed the complete 277-job Battle/server/fixture build,
all 10 model fixtures, and the rebuilt canonical-ROM fixture's retained
windows and battle-table checks. The final Python suite passed all 459 tests,
including real CUDA tests, with zero skips. Ruff and whitespace checks passed.

## CUDA matrix solver

Hardware: NVIDIA GeForce RTX 3080 Ti, 12 GiB; PyTorch 2.13.0+cu130 and Triton
3.7.1 in the local Nix development environment. Measurements use a live desktop
GPU. Reports preserve input/configuration and implementation identities.

The solver runs legal-action-compacted, positive-temperature anchored games.
Host-to-host time includes preparation, transfers, launches, and returning
CPU results; kernel-only CUDA-event time is recorded separately. Startup
compilation and warmup are excluded from steady samples. Rust and CUDA solve
identical input matrices and iteration counts.

At 2,048 iterations, seven timing repetitions produced:

| Matrices | Legal actions | FP32 CUDA total | Speedup over Rust FP64 |
| ---: | ---: | ---: | ---: |
| 16 | 3 | 1.38 ms | 4.17× |
| 16 | 9 | 1.94 ms | 6.87× |
| 16 | 13 | 2.02 ms | 9.73× |
| 256 | 3 | 1.61 ms | 56× |
| 256 | 9 | 2.42 ms | 89× |
| 256 | 13 | 3.18 ms | 98× |

The maximum measured FP32 policy/value/raw-exploitability discrepancy was
2.76e-6; the test tolerance is 2e-5. FP64 CUDA discrepancy stayed below
5.22e-15. The measured maximum regularized gap was 1.01e-7. Tests include
analytical games, random games, sparse legal masks, extreme priors, and 8,192
iterations. Small matrices stay on Rust when CUDA overhead dominates.

See [matrix benchmark](../../output/cuda-solver-benchmark.json) and
[large-batch extension](../../output/cuda-solver-large-batch-benchmark.json).
The latter observed 2,048-matrix batches at 5.88 ms (three legal actions) and
17.43 ms (nine); it is supplementary and may include modest test contention.

## Complete search throughput

The [fixed-work benchmark](../../output/fixed-search-benchmark.json) compares
Rust and automatic CUDA solving inside the same eight-root search batch.
Both use the same 256-wide, six-layer BF16 compiled network with deterministic
nonzero synthetic heads, depth two, four root chance worlds, three interior
actions per side, and two interior chance worlds. The report records its
unscaled-prior ablation explicitly; it is not a trained checkpoint.

Three alternating repetitions, after separate shape/search warmups, gave:

| Measurement | Rust matrices | Automatic CUDA matrices |
| --- | ---: | ---: |
| Median complete eight-root search | 3.773 s | 2.963 s |
| Median matrix-solving portion | 0.858 s | 0.044 s |

This is **1.27× end-to-end acceleration**, not the standalone solver's larger
speedup. Each run executes the same 43,332 native transitions and 2,456 solves;
automatic dispatch places 2,448 interior matrices on CUDA and eight roots on
Rust. Maximum policy discrepancy is 3.14e-7 and matrix discrepancy 5.84e-8.
Timing includes simulation, orchestration, full neural inference and transfers,
solving, and search diagnostics, with synchronization at both boundaries.
Model loading, root reset, and warmups are excluded. Final samples did not
overlap compiler jobs. The earlier report named `with-proof-load` preserves a
preliminary run with explicit CPU contention.

## Three-second decisions

The final [eager](../../output/battle-decision-final-eager.json) and
[warmed compiled](../../output/battle-decision-final-compiled.json) benchmarks
use the same eight level-100 6v6 roots, a 4,989,211-parameter BF16 scratch model,
and the serving defaults: depth two, four root chance worlds, three interior
actions, two interior worlds, and redundant-action prior scale 0.25. The
model matches production encoder dimensions; optional unused distilled heads
are absent. Scratch heads establish timing, not trained strategy quality.

| Engine | Median decision | Observed maximum | Budget overruns |
| --- | ---: | ---: | ---: |
| Eager | 0.601 s | 0.652 s | 0/8 |
| Compiled, completely warmed | 0.623 s | 0.771 s | 0/8 |

Each engine completed 32 passes with zero failures; every root reached depth
two and four chance worlds. Policies agreed for this scratch model. Both
reports record identical root identities, source/native hashes, and search
configuration. These are observed samples, not a worst-case deadline bound.

Timing covers the complete decision, including every admitted pass and result
packing. Compiled shape warmup took 9.680 s with an existing compiler disk
cache and is reported separately. Earlier cold compilation exceeded the
three-second target, which motivated explicit full-bucket warmup. Eager is the
recommended serving default from this sample; compiled mode did not improve
single-turn latency here. GPU memory figures in the JSON measure the PyTorch
allocator, excluding CUDA context and driver memory.

Reports with `priors1` or earlier filenames preserve preliminary configurations
and startup investigations. The two linked final reports use the current
serving prior scale and corrected simulator.

## BF16 training and replay

The [complete CUDA smoke](../../output/v33-training-smoke.json) ran one
iteration with a small 32-wide one-layer model, four battles, depth one, two
root chance worlds, a 256-decision horizon, and explicit CUDA solving.
Explicit CUDA exercises the kernel even when these small batches fall below
automatic dispatch crossover; automatic dispatch was tested above.

All four battles finished with zero truncations or semantic divergences,
producing 436 examples: 94 training rows and 342 held-out rows from the other
complete reset pair. Every example's diagnostics records CUDA solving.
All 46 learner tensors changed (L2 delta 0.05965988); parameters and 138
optimizer-state tensors stayed finite FP32 under BF16 compute. Training losses
were finite. Final report arenas completed, 225 manifest files verified, and
external verification reproduced the training shard byte for byte with SHA-256
`51338ad13e1afeed810fae7cac57399617c9612bbf36f28da0aaab13666af94c`.

The run lives at `/tmp/pokemon-v33-cuda-smoke-20260908-r3`; the repository keeps
the compact report and hashes. Its smoke-only promotion threshold accepted one
update, while `model_quality_pass` remained false. This is integration evidence,
not demonstrated battle strength. Earlier 64-decision smoke collection
truncated both held-out legs and correctly rejected the empty partition. The
smoke default is now 256; production remains 512.

## Reproduction

Package commands are in the [README](../../packages/battle-training/README.md).
Focused tools:

```sh
python tools/benchmark-cuda-solver.py --help
python tools/benchmark-fixed-search.py --help
python tools/benchmark-battle-decision.py --help
python -m unittest discover -s packages/battle-training/tests
```

Cartridge validation rebuilds the pristine source and supplies the verified
temporary image to the Lean fixture runner:

```sh
python tools/check-pokered-build.py --rebuild --output-rom /tmp/pokemon-v33-canonical.gbc
```

From `packages/battle-lean`:

```sh
lake build Battle battleRomFixture battleFixtures battleSearchServer
.lake/build/bin/battleFixtures
.lake/build/bin/battleRomFixture /tmp/pokemon-v33-canonical.gbc
```

The numerical evidence applies to the tested domain, GPU, and configurations.
Solver acceleration alone is not a claim about end-to-end search speed or
playing strength. A complete production training run and trained-checkpoint
strength comparison are separate evidence requirements.
