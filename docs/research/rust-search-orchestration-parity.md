# Rust search orchestration parity

The exhaustive simultaneous matrix-tree scheduler now has a Rust backend in
`packages/search-rs`, with a checked ctypes adapter in
`packages/battle-training/battle_training/search_native.py`. New training and
arena CLI invocations select Rust by default. Existing saved runs and
programmatic configurations retain Python unless explicitly configured otherwise.
The active `v33-bf16-20260908-154254` training process was not restarted or switched.

This migration changes where orchestration executes, not the search algorithm.
It preserves the exhaustive root, prior-ranked interior action limits, shared
chance worlds, balanced cell estimates, root mean solution, and training targets.
No Lean simulator semantics or native solver arithmetic were changed.

## Ownership and service boundary

| Responsibility | Owner after migration |
| --- | --- |
| Tree nodes and matrix/count storage | Rust |
| Stable legal-action ordering, width restriction, joint pairs | Rust |
| Expansion order, depth limits, root offsets, chance-seed placement | Rust |
| Frontier discovery, leaf placement, reverse-depth backup | Rust |
| Root and interior divergence propagation | Rust |
| Mean and split-half matrix construction, coverage checks, solve scheduling | Rust |
| Node/transition/coverage counters | Rust |
| Simulator transitions | Existing native Lean server, through the Python adapter |
| Full, distilled and deferred neural evaluation, feature caches | Existing Python/PyTorch/CUDA services |
| Equilibrium arithmetic | Existing Rust CPU / Python reference / Triton CUDA solvers |
| RNG draws and root Dirichlet noise | Existing Python random streams, requested in the original order |
| Final sampling, result schema, metrics and diagnostics | Existing Python publication functions |

The Rust engine yields batches of work to the adapter. The adapter does not
choose branches, construct the tree, or perform payoff backups. Solver inputs
are copied into Python views at the numerical service boundary; this is not yet
a fully native transport or inference process. Tests prohibit calls to the
Python `_make_node`, `_open_subgames`, `_settle`, and `_install_expansion` methods
when exercising the native public search path.

## Preserved contract

The public `search`, `search_many`, controller, collection and arena paths retain:

- Complete policies, selected actions, root values, payoff matrices, payoff
  spread, exploitability, solver identities, and diagnostics.
- Exact simulator request order and seeds, including common random numbers
  across all matrices belonging to one root at one depth.
- Root noise and action-sampling RNG consumption, including the streams' state
  after the search.
- Full/distilled evaluator selection, fallback when distilled heads are absent,
  deferred evaluation, independent controller perspectives and shared caches.
- Mixed depths, widths and chance counts within a batch, terminal cutoffs,
  repeated search objects, and reuse across calls.
- Split-half reliability and prior-regret diagnostics; actions still come from
  the mean matrix solution, never an average of chance-specific policies.
- Fail-closed root/interior divergence handling and propagation of simulator,
  evaluator and solver exceptions.

The backup keeps the Python arithmetic order:
`(current * count + value) / (count + 1)`. Replacing that with a different mean
formula or a parallel reduction would change rounding. Rust preserves input
sample order and the modulo-two split-half assignment.

The ABI accepts the supported finite numerical service inputs and up to 63
actions represented by masks; production uses 13. Invalid shapes, phases and
nonfinite numeric inputs are rejected. Invalid-input exception text and private
Python node object identities are not compatibility guarantees. One batch must
select a single orchestration backend.

## Verification performed

| Check | Result |
| --- | --- |
| Rust unit tests, optimized build | 6 passed |
| Full Python test suite, including new differential tests | 477 passed |
| Existing tests with public search calls forced through Rust | 462 passed |
| Dedicated Python/Rust differential suite | 15 passed, including configuration subcases and a 20-case seeded sweep |
| Same differential suite using the Nix-built shared library | 15 passed |
| Real Lean + CUDA/BF16, depth 2, four advancing roots | 4 paired batches / 32 controller results exactly equal |
| Real Lean + CUDA/BF16, depth 3, one advancing root | 3 paired batches / 6 controller results exactly equal |
| Rust Clippy with warnings denied | Passed |
| Rustfmt, Ruff, Nix formatting and whitespace checks | Passed |
| Nix native-library package build and checks | Passed |

The real-simulator comparisons use checkpoint zero with deterministically
perturbed nonzero policy/value heads; the checkpoint on disk is unchanged.
This avoids the all-zero startup-head special case, but it is a workload proxy,
not a trained policy. The depth-three check uses one chance sample at each level.
Both comparisons use compiled BF16 neural inference and the actual CUDA solver.
Every field of both `ControllerDecision` results is compared exactly, together
with request-trace hashes and the parent RNG states. Across both cohorts this
covers **38 controller results and 185,142 requested speculative rows per
backend**, before simulator deduplication. These are not completed battles.

Evidence is retained in
[`output/rust-search-parity-20260908`](../../output/rust-search-parity-20260908/).
The depth-three report includes the tested library path/ABI/SHA-256. The initial
depth-two report predates addition of that metadata field. Summary evidence
records source hashes and validation commands.

This is differential and integration evidence, not a formal proof of the Rust
scheduler. Existing cartridge-backed Lean behavior remains unchanged.

## Timing scope

The tests ran while training continued. They primarily validate parity; each
trial advances the battle, so these timings span different workloads and host
contention. Cold compilation is reported separately. No overall training
speedup is claimed from this migration.

| Warm paired batch | Python | Rust |
| --- | ---: | ---: |
| Depth 2, trial 1 | 4.225 s | 5.686 s |
| Depth 2, trial 2 | 4.015 s | 2.794 s |
| Depth 2, trial 3 | 3.175 s | 2.906 s |
| Depth 3, trial 1 | 1.308 s | 2.451 s |
| Depth 3, trial 2 | 3.344 s | 2.204 s |

These results do not establish a consistent speedup. The next performance
experiment should use fixed positions, repeated alternating warm trials and
separate stage/memory measurements. Python feature/cache handling and transport
remain optimization opportunities. Selective expansion would be a separate
algorithm change with a playing-strength gate.

## Deployment and reproduction

`nix develop` supplies the packaged native library through `BATTLE_SEARCH_LIB`.
A local `cargo build --release --manifest-path packages/search-rs/Cargo.toml`
is also supported. The loader validates ABI v1 and all required symbols; an
explicit path is authoritative. Selecting Rust with a missing/incompatible
library raises an error before inference/RNG consumption rather than silently
falling back to Python.

New CLI runs default to `--orchestration-backend rust`. The Python reference is
available through `--orchestration-backend python`. Collection passes this
configuration through independent controllers; evaluation carries it into
`ArenaConfig` and `JointSearchConfig`. Resuming old metadata defaults the missing
field to Python. New training metadata records the chosen implementation and,
for Rust, the library SHA-256.

```sh
nix build .#battle-search
cargo test --release --manifest-path packages/search-rs/Cargo.toml
python -m unittest discover -s packages/battle-training/tests
python tools/test-rust-search-contract.py
python tools/check-search-parity.py --run /path/to/run \
  --batch 4 --trials 3 --perturb-heads --advance \
  --output /tmp/search-parity.json
python tools/check-search-parity.py --run /path/to/run \
  --batch 1 --depth 3 --chance-samples 1 --interior-chance-samples 1 \
  --trials 2 --perturb-heads --advance --output /tmp/depth3-parity.json
```

The active training job continues with its existing Python implementation; this
change does not hot-swap its tree engine or rewrite its saved backend.
