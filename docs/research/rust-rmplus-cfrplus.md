# Native Rust RM+ and CFR+ integration

Date: 2026-08-02

## Decision

Move only the dense simultaneous zero-sum solver arithmetic into Rust and enable
CFR+ acceleration in a new immutable controller lineage. Python retains the
cross-root frontier scheduler, exact Lean transition batches, pooled CUDA
inference, caches, chance streams, complete legal root, and fail-closed result
construction.

The implementation is adapted from the MIT-licensed joint solver at
`cfcosta/mcts@afc6e5d4ca6f0ce560a52add625e2b1d883b5456`. It is built as
`libbattle_rmplus` under `packages/rmplus-rs` and called through a versioned C
ABI from `battle_training/rmplus_native.py`. Nix builds and tests the library,
and every run records the library SHA-256 and upstream commit.

## Compatibility boundary

V26 changes floating-point reduction order and regret dynamics. It therefore
uses incompatible identifiers:

```text
transformer-variable-party-bf16-rmplus-v26-rust-cfrplus
simultaneous-matrix-tree-rust-cfrplus-pooled-node-v4
simultaneous-matrix-tree-rust-cfrplus-every-decision-v4
rust-cfrplus-f64-v1
```

It cannot resume a V24 run. Within V26, the same native library and inputs are
byte deterministic. Semantic divergence still returns no action, policy target,
or fabricated payoff matrix.

The following `mcts-rs` extensions remain disabled or absent:

- prior-mass action pruning;
- Dirichlet root noise;
- early equilibrium tolerance;
- replacement of the Python frontier scheduler;
- synchronous Rust callbacks into Lean or the neural evaluator.

Thus every legal root action remains present, `fresh-root-v1` chance is
unchanged, and V24's pooled full-node inference cannot regress to batch-one
callbacks.

## Solver benchmark

The benchmark used 128 deterministic random 13×13 zero-sum matrices on the
production CPU. All variants used the same matrices and uniform priors.

| Solver | Iterations | ms/matrix | Mean exploitability |
|---|---:|---:|---:|
| Python/NumPy uniform RM+ | 2,048 | 14.994 | 0.00833447 |
| Rust uniform RM+ | 2,048 | 0.259 | 0.00833447 |
| Rust CFR+ | 64 | 0.036 | 0.00650006 |
| Rust CFR+ | 128 | 0.045 | 0.00239674 |
| Rust CFR+ | 256 | 0.062 | 0.00102085 |
| Rust CFR+ | 2,048 | 0.304 | 0.00012673 |

Rust uniform RM+ was 57.84× faster through the actual ctypes boundary. Its
maximum policy L1 difference from the Python reference was `4.36e-15`, and
repeated native results were byte identical. V26 deliberately retains 2,048
CFR+ root iterations: solver time is already negligible, while mean random-
matrix exploitability falls a further 65.8× relative to the former production
solver.

A 16-iteration warm-node microbenchmark measured:

| Solver | µs/solve |
|---|---:|
| Python/NumPy uniform RM+ | 152.38 |
| Rust uniform RM+ through ctypes | 47.13 |
| Rust CFR+ through ctypes | 45.84 |

The remaining warm-call cost is predominantly Python array marshalling. A
future stateful or batched ABI may remove it, but it is not mixed into V26.

Raw report:

```text
/tmp/v26-rust-cfrplus-quality.json
```

## Exact production-search benchmark

A 64-root mirror search used depth 4, complete roots, budget 320, 2,048 cold
iterations, compiled joint inference, exact Lean transitions, and checkpoint
`policy-009.pt` from the stopped V24 run.

| Backend | ms/root | roots/s | Mean final exploitability |
|---|---:|---:|---:|
| Python uniform RM+ | 225.28 | 4.44 | 0.00012418 |
| Rust uniform RM+ | 31.92 | 31.33 | 0.00012029 |
| Rust CFR+ | 34.07 | 29.35 | 0.000000740 |

Native uniform search was 7.06× faster and changed no final greedy joint action
on the 64-root panel. Tiny reduction-order differences altered some deeper
sampling trajectories, so payoff matrices were not byte-identical and the new
lineage is mandatory. CFR+ was 6.61× faster than the Python controller and
changed 34 of 64 greedy joint actions; this is algorithmic evidence, not a
playing-strength result. Same-reset side-swapped promotion, probes, strata, and
campaign gates remain authoritative.

Reproduce with `tools/benchmark-rust-cfrplus-search.py`; the measured report is:

```text
/tmp/v26-search-solver-benchmark.json
```

## Validation

- Rust unit tests cover equilibrium anchors, CFR+ convergence, and split warm
  state continuity.
- Python characterization compares native uniform RM+ with the retained Python
  reference to 12 decimal places and pins repeated native determinism.
- Search tests exercise native CFR+ through a complete deeper tree and assert
  the solver provenance.
- CPU smoke training, deterministic replay, artifact verification, and native
  library hashing cover the full pipeline.
