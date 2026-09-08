# battle-rmplus

Deterministic `f64` RM+ and CFR+ kernels used by the Pokémon Red simultaneous
matrix-tree search. The crate exports a versioned C ABI; Search topology and chance scheduling live in `battle-search` (Rust) or the
Python reference, selected by the orchestration backend. Python adapters provide
exact Lean transitions, pooled neural inference, and CPU/CUDA solver dispatch.

The update order and scratch-oriented design are adapted from the MIT-licensed
joint solver in `cfcosta/mcts` commit
`afc6e5d4ca6f0ce560a52add625e2b1d883b5456`. No action pruning, root noise,
search tree, RNG, or evaluator code is included.

```bash
cargo test --release
cargo build --release
```
