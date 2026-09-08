# battle-search

Native orchestration for the existing exhaustive simultaneous matrix-tree
search. This is a port of the Python search algorithm, **not a change to
selective MCTS or pruning**.

Rust owns:

- Tree nodes, dense payoff/count matrices, and split-half matrices.
- Stable prior-ranked legal action selection and exhaustive joint pairs.
- Request ordering and reuse of each root's chance draws across a level.
- Batched frontier discovery, terminal cutoffs, and mixed search depths.
- Leaf placement, reverse-depth value backup, root and split-half solve jobs.
- Per-root failure propagation, shared-owner counters, and transition accounting.

The Python adapter in `battle_training/search_native.py` provides the existing
Lean `SearchServer`, full/distilled/deferred neural evaluation and its caches,
CPU/CUDA matrix solvers, Python RNG streams, and `SearchResult` publication.
Root noise, action sampling, metrics and diagnostics retain their existing
implementations and arithmetic. Rust never calls the Python tree-construction,
expansion, installation or backup methods.

## Build and select

```sh
cargo test --release --manifest-path packages/search-rs/Cargo.toml
cargo build --release --manifest-path packages/search-rs/Cargo.toml
# Or use the dependency-complete Nix package:
nix build .#battle-search
```

`nix develop` supplies `BATTLE_SEARCH_LIB`. Outside the development shell the
adapter also finds `packages/search-rs/target/{release,debug}/libbattle_search.*`.
An explicit `BATTLE_SEARCH_LIB` is authoritative; load/ABI failures never silently
select Python. The implementation has no third-party Rust dependencies.

New training and arena CLI invocations default to `--orchestration-backend rust`.
Use `--orchestration-backend python` for the reference. Programmatic configuration
and old saved configurations default to Python for backward compatibility.
Resuming a run preserves its saved backend. One cross-root batch must use a
single backend; individual search depths, widths, sampling and solver/evaluator
configurations can differ. Training metadata records the native library SHA-256.

## Contract and ABI

The v1 C ABI is declared by `#[repr(C)]` structs and exported `battle_search_*_v1`
functions in `src/lib.rs`, mirrored by ctypes in `search_native.py`. The native
engine yields one of five phases: simulator steps, interior evaluations, leaf
values, matrix solves, or finished. The adapter services that phase and supplies
results; it does not choose nodes or tree depth.

Each handle has a single owner, is used serially, and must be freed exactly once.
Views borrow native buffers until the next mutation/free; the Python adapter
copies them before returning to services. Inputs must point to initialized,
properly aligned buffers of their declared lengths. Shape/phase failures poison
the handle; panics are caught at mutation boundaries. Python exceptions always
release a constructed tree. Invalid/nonfinite numeric inputs are rejected.
The battle schema uses 13 actions; the ABI supports up to 63 mask bits.

`search` and `search_many` preserve results, failure behavior, simulator request
ordering, RNG consumption, mean/half matrices and diagnostics for supported
finite evaluator/solver inputs. The shared Python numerical services remain the
reference for rounding-sensitive equilibrium diagnostics. The native backup
preserves `(current * count + value) / (count + 1)` and original sample order.
It never averages policies from different chance worlds to produce a target.

## Verification

Inside the training environment:

```sh
python -m unittest discover -s packages/battle-training/tests -p test_rust_search.py
python tools/test-rust-search-contract.py
python tools/check-search-parity.py --run /path/to/run \
  --batch 4 --trials 3 --perturb-heads --advance --output /tmp/search-parity.json
```

The first suite compares unmodified Python with Rust, including full results,
requests and post-search RNG states. The second routes existing tests' public
search calls through Rust. The third uses actual Lean simulation and neural
inference; it writes complete paired results and checks exact equality. Random
nonzero heads are a workload proxy, not a trained policy or strength evaluation.

No Lean semantics are changed. Cartridge-backed simulator proofs remain the
existing simulator's responsibility; this migration is validated by behavioral
differential tests and does not claim a formal proof of the Rust scheduler.
