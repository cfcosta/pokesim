# PyO3 search and simulator bridge — 2026-09-08

Search orchestration and simulator transport now enter Rust through the
`battle_search` PyO3 extension. The previous runtime bridge used ctypes; shell
commands were build tooling. No shell, compiler or subprocess connects Python
to the Rust extension at runtime. Lean remains a separate simulator process;
Rust sends and decodes its existing pipe protocol.

## Implementation

`packages/search-rs/src/python.rs` exposes an owned `Engine`. Python supplies
configuration, snapshots, RNG draws and numerical service results as checked
arguments. Rust returns owned event payloads and node data. Construction,
mutation and explicit close detach from the interpreter; PyO3 borrow checking
prevents overlapping mutable access. Failed mutations poison the engine, panics
are converted to exceptions, and closing is idempotent. Views remain valid after
mutation or deletion because they own their storage. The Python context manager
also closes the tree when an evaluator or simulator raises.

`src/transport.rs` exposes `batch` and `decode`. Its shared request implementation
handles the entire write/read deadline, parses and validates JSON, and decodes
features while detached from Python. The returned immutable Python bytes own the
feature payload; NumPy views retain that owner. This still copies the decoded
feature blob once. It does not expose raw pointers or require Python to free a
Rust allocation. Optional fields, signed legacy arrays, packed u16 features,
unsigned seeds, request ordering, deduplication and public timeout behavior are
preserved. Python retains child lifecycle, administrative commands, lineage
tracking and Snapshot construction.

The PyO3 dependency is pinned to 0.28.3 in Cargo.lock, targeting Python 3.12+
through abi3. `packages/search-rs/pyproject.toml` builds a Maturin wheel. Nix builds
the extension with `extension-module`, runs Rust tests and imports the installed
binary as an installation check. The adapter supports installed wheels, an
explicit `BATTLE_SEARCH_LIB`, and local Cargo builds. An explicit invalid or stale
library fails without fallback or an attempted runtime build. Provenance hashes
the extension itself, including inside a wheel's re-exporting Python package.

The existing C exports remain for compatibility and Rust contract tests. Search
and transport Python code no longer calls them. The separate CPU RM+ solver
adapter is outside this migration. PyTorch/CUDA neural inference and numerical
solver behavior are unchanged. No Lean source or cartridge behavior changes were
made, and this migration does not claim a new formal proof.

## Validation

The differential tests retain the Python reference and compare complete results,
request sequences, RNG state, split-half backups, errors and counters. Transport
tests cover real Lean search/episode/control interleaving, immutable feature
lifetimes, malformed responses, fragmented reads, EOF, write stalls, deadlines,
process cleanup and decoder independence. PyO3 tests additionally cover copied
node lifetime, closed/poisoned engines, invalid Python arguments, nonfinite
numbers, missing libraries and installed-package binary provenance.

All 499 Python tests pass, as do 468 tests with search and transport forced
through Rust. The Nix package passes all eight Rust tests and its import check;
Clippy, Python lint/format and Nix formatting pass.

Validation counts and binary/source fingerprints are recorded in
[`output/pyo3-bridge-20260908`](../../output/pyo3-bridge-20260908/).
The wheel was built and imported from an extracted installation on CPython 3.12;
other Python versions and operating systems were not runtime-tested.

## Measurement method

`tools/benchmark-search-backends.py --compare bridge` loads explicitly supplied
previous adapters and their previous library. It alternates those with the PyO3
adapters in one process, holding Rust orchestration, Rust simulator transport,
Lean, model weights, states, RNG and solver configuration fixed. The raw report's
legacy backend labels `python` and `rust` mean **ctypes reference** and **PyO3**;
`variant_names` records this mapping. Both sides perform real simulation and
compiled CUDA BF16 inference. Each batch decision includes both controllers.

Batch four has six warm pairs; batch sixteen has four. Two warmups per variant
are excluded. Models use seeded nonzero heads on checkpoint zero, a workload
proxy rather than a trained policy. Compaction, cache resets, result verification
and boundary telemetry are outside timing. All complete results and RNG states
must match exactly. The worker runs at Nice=10 with a 12 GiB memory cap; workers
run sequentially. Hardware is Ryzen 7950X3D / RTX 3080 Ti 12 GB.

The earlier training process had already failed at 1,979/2,048 collection games
from a 60-second simulator timeout. It was not restarted and its partial data is
preserved. Some validation/build work overlapped this benchmark, so these are
paired measurements on a shared host. Bootstrap intervals resample repeated
pairs of fixed positions, not independent battle episodes. RSS is sampled every
50 ms and can miss short peaks; paired variants share allocator history, so
memory comparisons do not establish independent-process retention or leak bounds.

## Results

| Concurrent battles | Warm pairs | ctypes median | PyO3 median | Median latency reduction |
| --- | ---: | ---: | ---: | ---: |
| 4 | 6 | 2.859 s | 2.485 s | 13.1% |
| 16 | 4 | 11.254 s | 10.539 s | 6.4% |

Within-pair geometric speedups are 1.119× [1.067, 1.164] and 1.063×
[1.044, 1.077], with paired bootstrap 95% intervals. All trials match exactly:
38,436 fresh Lean transitions per batch-four call and 155,670 per batch-sixteen
call. These are complete batch decisions including both controllers, not battle
completion throughput or a guarantee of the three-second inference budget.

The median measured orchestration/adapter portion falls from 301 to 99 ms at
batch four and 1,259 to 604 ms at batch sixteen. Actor CPU means fall from 1.779
to 1.502 seconds and 7.130 to 6.475 seconds. The simulator-stage mean falls from
1.550 to 1.450 seconds and 6.134 to 6.043 seconds. This isolates the largest gain
to the orchestration/adapter portion, which also includes GC; it is not a claim
that Lean battle computation became faster.

Observed batch-sixteen actor PSS medians differ by only 0.4 MiB (about 2,141 MiB
for both), and sampled combined actor/simulator RSS peaks differ by 5.6 MiB
(8,012.6 versus 8,018.2 MiB). No independent-process memory reduction is claimed.

## Reproduction

```sh
nix build .#battle-search
python -m unittest discover -s packages/battle-training/tests -q
python tools/test-rust-search-contract.py
# The saved reference adapters are compressed under the evidence directory.
python tools/benchmark-search-backends.py --run /path/to/run --compare bridge \
  --reference-adapters /path/to/extracted/reference-adapters \
  --reference-library /path/to/previous/libbattle_search.so \
  --batch 4 --warmups 2 --repeats 6 --replay-repeats 0 --perturb-heads \
  --output /tmp/pyo3-b4.json
python tools/analyze-search-backends.py /path/to/evidence-directory
```

The earlier transport-only comparison is preserved separately in
[the Rust transport report](rust-simulator-transport.md). Its ctypes-era numbers
must not be presented as measurements of the final PyO3 implementation.
