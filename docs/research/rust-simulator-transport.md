# Rust simulator batch transport — 2026-09-08

This report preserves the transport migration measurements made with the initial
ctypes bridge. The final implementation uses PyO3; see
[the PyO3 migration report](pyo3-search-bridge.md) for its contract and measurements.

The Rust backend now sends speculative search and episode-step batches to the
unchanged Lean simulator, parses its JSON responses, validates protocol metadata,
and decodes feature arrays. Python retains the evaluator-facing Snapshot objects,
lineage deduplication, process lifecycle and administrative commands. Selecting
Rust orchestration in training or arena selects this transport as well. Existing
saved Python runs retain their backend; the active run was not restarted.

## Implementation and behavior

The measured implementation was `packages/search-rs/src/transport.rs`, with a
checked ctypes adapter in `battle_training/simulator_transport.py`. That adapter
has since been replaced by PyO3. The underlying Lean protocol remains unchanged.
New serde, serde_json, base64 and libc dependencies are pinned in Cargo.lock and
included by the existing Nix build.

Rust receives a contiguous matrix of unsigned request fields and writes the exact
existing command format. Episode steps write zero chance seeds, preserving the
simulator's embedded episode RNG behavior. One I/O deadline covers pipe writes
and the full response, including partial-line stalls. Writes are at most PIPE_BUF
bytes after polling so a blocked consumer cannot create an unbounded write.
The GIL is released during the native call. Python serializes all pipe exchanges
with the same request lock, including interleaved control requests.

Typed decoding checks JSON structure, response ID, success/error, row count,
feature encoding and feature count. It preserves integer masks, handles, turns,
terminal values, hashes, request kinds, optional flags and divergence strings.
Both packed u16le-base64 and legacy signed int64 arrays are supported. Snapshot
features share an immutable Python bytes allocation copied once from the decoded
Rust batch; they remain valid after that batch is freed. Inside Rust, a custom
serde visitor borrows ordinary unescaped feature strings directly from the
response buffer. Escaped strings still decode into owned text, and legacy arrays
retain their original integer values. This avoids the temporary feature-string
allocation and clone introduced by serde's untagged enum path. A retained feature
view retains its batch buffer, which is a memory-lifetime tradeoff, not a claim of
zero-copy transfer. Native allocations are released on success or exception.

Timeouts retain NativeRequestTimeout and kill/reap the child and close streams.
Other transport/protocol errors also discard the process because a partly
consumed response cannot safely be followed by another request. Missing transport
symbols fail before process startup; there is no silent fallback from Rust.

No Lean source or simulator binary was changed. This preserves the existing
cartridge-backed implementation; it does not constitute a formal proof of Rust.
Behavioral parity is checked with real Lean transitions and the Python reference.

## Validation of the pre-PyO3 transport

- All 493 Python tests pass against the pre-PyO3 packaged library, including 16
  transport tests.
- 462 existing tests passed with both search and real-server transport forced
  through Rust; dedicated differential tests run separately against Python.
- All eight Rust unit tests pass, including borrowed-feature ownership checks.
  Clippy with warnings denied, Python lint/format and Nix packaging also pass.

The transport suite covers both feature encodings, large legacy values, Unicode
and empty divergence strings, optional fields, required fields, invalid JSON,
wrong IDs, row/feature count mismatches, malformed base64, response fragmentation,
unsigned seeds, episode ordering, EOF, blocked writes and partial-read timeouts.
It checks process cleanup on timeout and protocol failure, stale-library startup,
feature ownership/immutability, and real search/episode/inspect/compact interleaving.
A regression test patches Python JSON/base64 decoders to fail and verifies that
both Rust batch operations still complete. Real transitions preserve dedup counts
and duplicate-row object identity.

## Performance experiment with the pre-PyO3 bridge

`tools/benchmark-search-backends.py --compare transport` fixes orchestration to
Rust and alternates Python/Rust transport on the same states, model and native
server. Each complete search includes both neural controllers. Batch-four uses
eight warm pairs, batch-sixteen six; two warmups per backend are excluded.
The model uses compiled CUDA BF16 and seeded nonzero heads on checkpoint zero,
which is a workload proxy, not a trained policy. Native simulation and GPU model
execution remain real. Fresh transition counts, all controller results and RNG
states are checked exactly. Compaction, cache reset and telemetry are outside
timing; no service replay is used.

The worker runs at Nice=10 with a 12 GiB memory cap, one worker at a time.
Initial allocating-decoder cohorts ran while training was active. The legacy
Python training run failed at 20:23:05 UTC, during the final batch-four warmup,
after a simulator request exceeded 60 seconds. All retained final batch-four and
batch-sixteen timing samples ran after that failure. Training's missing cgroup
files reflect the failed service, not an active job. The partial run is preserved;
the timeout's root cause was not isolated. Per-sample telemetry and
`runtime-conditions.json` document this change in conditions.
Hardware: Ryzen 7950X3D, RTX 3080 Ti 12 GB. Timings compare fixed-position batch
decisions, not completed battle episodes or guaranteed turn latency.

| Simultaneous battles | Warm pairs | Python transport median | Rust transport median | Ratio of medians |
| --- | ---: | ---: | ---: | ---: |
| 4 | 8 | 2.824 s | 2.697 s | 1.047× |
| 16 | 6 | 11.574 s | 10.960 s | 1.056× |

Median latency falls by 4.5% and 5.3%, respectively. Within-pair geometric mean
speedups are 1.052× [1.045, 1.059] and 1.057× [1.045, 1.071], with 10,000-resample
paired bootstrap 95% intervals. These describe timing repeatability on fixed
positions, not independent battle samples or guarantees. Earlier allocating-decoder
cohorts are retained as `initial-*`; do not compare their absolute latency with
these final cohorts because training contention changed.

The mean simulator service time (including unchanged Lean compute, lineage dedup,
transport and Snapshot construction) falls from 1.610 to 1.479 s at batch four,
and 6.476 to 5.867 s at batch sixteen. The latter is 9.4% less simulator-stage time.
At batch sixteen, evaluation averages 3.559 versus 3.566 s, matrix solving 0.241 s
for both, and actor CPU time falls from 7.547 to 6.974 s. GC averages 2.149 versus
2.154 s, so this improvement is not explained by fewer collection pauses.

Each batch-four call executes 38,436 fresh native transitions, and batch-sixteen
155,670. Complete decisions, diagnostics and post-search RNG states match exactly
within every comparison. The search algorithm, neural arithmetic and simulated
workload are unchanged.

### Memory observation

The initial allocating decoder left roughly 263 MiB more actor PSS after batch-16
Rust trials in its shared-process cohort. The final borrowed decoder has comparable
post-search PSS: Python transport median 2,414.7 MiB and Rust 2,395.2 MiB. These
trials share allocator history; they establish no independent-process memory
reduction. The final sampled actor-plus-native RSS peaks are 8,228.2 MiB for Python
and 8,500.6 MiB for Rust. Rust still has about 272 MiB higher sampled transient RSS,
consistent with the decoded native feature buffer overlapping its immutable
Python copy. This is an explicit ownership tradeoff; no zero-copy or lower-peak
memory claim is made. Sampling every 50 ms can miss shorter peaks.

## Evidence and reproduction

Raw observations, fingerprints, stage times, GC and memory telemetry, library
and simulator hashes are saved in
[`output/simulator-transport-20260908`](../../output/simulator-transport-20260908/).
Raw completed reports are compressed losslessly as JSON.gz; the analyzer accepts
both compressed and plain JSON. Validation records source/binary hashes and
within-cohort parity. The saved training-failure traceback is evidence of the
legacy run's timeout, not a diagnosis of its underlying cause.

```sh
nix build .#battle-search
# In the matching training environment, with BATTLE_SEARCH_LIB pointing at it:
python -m unittest discover -s packages/battle-training/tests -p test_simulator_transport.py
python tools/test-rust-search-contract.py
python tools/benchmark-search-backends.py --run /path/to/run --compare transport \
  --batch 4 --warmups 2 --repeats 8 --replay-repeats 0 --perturb-heads \
  --output /tmp/transport-b4.json
python tools/analyze-search-backends.py /path/to/evidence-directory
```
