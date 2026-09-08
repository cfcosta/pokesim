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
- Batched simulator request encoding, pipe I/O, JSON validation and feature decoding
  through the PyO3 `battle_search` extension.

The Python adapter in `battle_training/search_native.py` provides the existing
Lean `SearchServer`, full/distilled/deferred neural evaluation and its caches,
CPU/CUDA matrix solvers, Python RNG streams, and `SearchResult` publication.
Root noise, action sampling, metrics and diagnostics retain their existing
implementations and arithmetic. Rust never calls the Python tree-construction,
expansion, installation or backup methods.

## Build and select

```sh
cargo test --release --manifest-path packages/search-rs/Cargo.toml
cargo build --release --features extension-module --manifest-path packages/search-rs/Cargo.toml
# Or use the dependency-complete Nix package:
nix build .#battle-search
# Or build/install a Python wheel (requires a Rust toolchain):
python -m pip install ./packages/search-rs
```

`nix develop` supplies `BATTLE_SEARCH_LIB`. Outside the development shell the
adapter first imports an installed `battle_search` wheel, then looks for `packages/search-rs/target/{release,debug}/libbattle_search.*`.
An explicit `BATTLE_SEARCH_LIB` is authoritative; import/API failures never silently
select Python. PyO3 targets Python 3.12+ through the stable ABI. No shell or build
process is invoked at runtime. The transport uses serde/serde_json, base64 and libc, pinned by
`Cargo.lock` and included in the Nix package.

New training and arena CLI invocations default to `--orchestration-backend rust`.
Training and arena use the matching Rust batch transport when Rust orchestration
is selected. Use `--orchestration-backend python` for the reference. Programmatic
configuration and old saved configurations default to Python for compatibility.
Resuming a run preserves its saved backend. One cross-root batch must use a
single backend; individual search depths, widths, sampling and solver/evaluator
configurations can differ. Training metadata records the native library SHA-256.

## Python extension contract

`src/python.rs` exposes an owned PyO3 `Engine` with checked Python arguments.
It yields five phases: simulator steps, interior evaluations, leaf values,
matrix solves, or finished. The adapter services each phase and supplies results.
It does not choose nodes or tree depth. Engine mutation, construction, explicit
close, simulator I/O and decoding release the GIL through `Python::detach`.
The PyO3 borrow guard prevents overlapping mutation of an engine.

Python sees owned lists, tuples, dictionaries and immutable feature bytes.
No raw handles, borrowed pointers, ctypes declarations or manual frees are used
by the search or transport adapters. Shape/phase failures poison an engine;
panics are caught at mutation boundaries. Context-manager cleanup releases the
tree if a Python service raises; PyO3 also owns cleanup when an object is dropped.
Closed engines reject further access. Invalid/nonfinite numeric inputs are
rejected. The battle schema uses 13 actions; the engine supports up to 63 mask bits.
`API_VERSION` and `TRANSPORT_API_VERSION` are checked before use; metadata hashes
the actual extension binary, including when loaded from a Maturin wheel.

The previous v1 C exports remain for compatibility and Rust contract tests;
the Python search and transport implementations do not call them. The separate
CPU RM+ solver adapter is outside this search/transport bridge migration.

`search` and `search_many` preserve results, failure behavior, simulator request
ordering, RNG consumption, mean/half matrices and diagnostics for supported
finite evaluator/solver inputs. The shared Python numerical services remain the
reference for rounding-sensitive equilibrium diagnostics. The native backup
preserves `(current * count + value) / (count + 1)` and original sample order.
It never averages policies from different chance worlds to produce a target.

## Simulator transport

`src/transport.rs` exchanges the existing Lean `batch` and `batch-episode` text
protocol over borrowed POSIX pipe descriptors. It preserves request IDs, row
order, unsigned chance seeds, terminal returns, optional divergence/popularity
fields, and both legacy integer arrays and packed u16 little-endian base64.
Python's request lock serializes administrative and Rust batch exchanges. A
single I/O deadline covers request writes and the complete newline-terminated
response, including stalls after initial readability. I/O/protocol failures
fail closed; timeouts keep the public `NativeRequestTimeout` exception and reap
the child. The library never owns or independently closes Python's descriptors.

`battle_training/simulator_transport.py` copies the feature payload once into
immutable Python bytes, then creates NumPy views with a retained owner. Rust
batches are dropped automatically, including when conversion raises. Keeping any feature view retains
its batch's feature buffer; ordinary search compaction drops speculative batches.
Rust borrows ordinary base64 strings from the response while decoding, avoiding
per-row encoded-string allocations. This removes Python JSON dictionaries and
per-row base64 decoding from the hot path, while retaining the evaluator's
existing `Snapshot` API.

Process startup/shutdown, reset/inspect/compact control commands, lineage dedup,
and Snapshot object construction remain in Python. The evaluator and battle
rules are unchanged. Direct callers can set `transport_backend="rust"` on `SearchServer`; the default
direct/programmatic reference remains Python. Selection is
explicit and a stale library fails before a simulator process is spawned.

## Verification

Inside the training environment:

```sh
python -m unittest discover -s packages/battle-training/tests -p test_rust_search.py
python -m unittest discover -s packages/battle-training/tests -p test_simulator_transport.py
python -m unittest discover -s packages/battle-training/tests -p test_pyo3_search.py
python tools/test-rust-search-contract.py
python tools/check-search-parity.py --run /path/to/run \
  --batch 4 --trials 3 --perturb-heads --advance --output /tmp/search-parity.json
```

The differential suites compare unmodified Python with Rust, including results,
requests, decoding and RNG states. The contract runner routes existing tests
through Rust search and transport. The parity tool uses actual Lean simulation
and neural inference; it writes complete paired results and checks exact equality. Random
nonzero heads are a workload proxy, not a trained policy or strength evaluation.

No Lean semantics are changed. Cartridge-backed simulator proofs remain the
existing simulator's responsibility; this migration is validated by behavioral
differential tests and does not claim a formal proof of the Rust scheduler.
