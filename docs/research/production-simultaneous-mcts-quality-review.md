# Production simultaneous-tree-search quality review

Date: 2026-08-01

## Scope

This is the second DocBERT review of the training search. The first review was
primarily about throughput. This pass asks which changes improve the quality of
the complete-root simultaneous teacher without replacing it with an
alternating-player UCT/PUCT search, pruning legal actions, exposing hidden RNG,
or allowing a network policy to select a semantic action directly.

The literature calls the broad family MCTS. The implementation here is more
specific: a stochastic simultaneous-move matrix tree whose local policies are
computed by regret matching+. That distinction rules out several otherwise
standard recommendations.

## Evidence reviewed

DocBERT returned two useful reviews:

- *Monte Carlo Tree Search: A Review of Recent Modifications and Applications*
  (`resources/ai-ml/Monte Carlo Tree Search - A Review of Recent Modifications
  and Applications.md`). Its selection survey describes UCB variants,
  progressive bias that decays learned or heuristic guidance with visits,
  Thompson/Bayesian selection, and implicit-minimax backup. Its simulation
  survey emphasizes domain-guided but still stochastic playouts, while its
  backpropagation survey documents exact terminal reward locks and solver-style
  propagation.
- *Beyond Games: A Systematic Review of Neural Monte Carlo Tree Search
  Applications* (`resources/ai-ml/Beyond Games - A Systematic Review of Neural
  Monte Carlo Tree Search Applications.md`). Lines 63–91 separate selection,
  expansion, evaluation, and backup; lines 104–118 describe neural priors and
  values as search guidance and search output as the training target. Lines
  161–166 require empirical validation rather than treating a search design as
  correct by construction.

The transferable lessons are to preserve uncertainty while evidence is sparse,
use priors as decaying guidance rather than authority, keep exact terminals
exact, and validate controller changes against the actual task. The UCB/PUCT
formula itself does not transfer to a simultaneous zero-sum matrix node.

## Code audit findings

### 1. The final root policy used stale non-stationary averages

The tree updated cumulative regrets and strategy sums while the empirical payoff
matrix was changing. The final policy was the average over all those historical
matrices. `regret_iterations=256` was used by the old root search but was not
used for the production tree's final root policy; the tree only performed 16
online updates after each changed estimate.

This is useful for path selection, but it is not a clean equilibrium solve of
the matrix that exists when the budget ends. V23 therefore retains online RM+
inside the tree and performs a fresh deterministic RM+ solve of the completed
current root matrix for both the root-only target and the final deep target.
The production solve budget is 2,048 iterations and is recorded in every search
diagnostic.

### 2. A post-solver switch cap changed the game being solved

The former 10–30% voluntary-switch cap modified both players' RM+ strategies.
A strategically dominant switch could therefore receive only 30% probability
even when the empirical zero-sum matrix required it. This was neither a prior
nor an exploration mechanism; it was a direct semantic policy override.

V23 removes the cap from both tree and compatibility search. All moves and
switches are still legal-masked and represented in the complete root matrix.
RM+ alone determines their final mass.

### 3. Chance was under-sampled after the first observation

A fixed 10% re-sample probability let a joint action repeatedly reuse one chance
outcome. V23 uses `max(0.10, 1/sqrt(n))`, where `n` is the number of independent
outcomes already attached to that joint pair. The second observation is always
fresh; sampling then decays toward the configured floor. Initial complete-root
expansion still uses common random numbers across all legal joint actions and
every sample retains the `fresh-root-v1` marginal.

### 4. Deeper exploration discarded the learned prior

The finite-budget tree mixed RM+ with uniform exploration. The neural prior was
used only when all positive regrets were zero. V23 uses the normalized neural
prior for the decaying exploration component. This is the simultaneous-matrix
analogue of progressive bias: priors focus finite deeper work but decay with
visits, while all legal actions retain support and the complete root is never
pruned.

### 5. Pooled production inference skipped redundant-action prior shaping

The non-pooled evaluator applied the observational 0.25 multiplier for redundant
status, capped setup, and slower-OHKO choices. The pooled frontier evaluator,
which production uses, cached the raw policy instead. V23 applies the same
shaping to ordinary and dual-policy pooled outputs before caching. It remains a
prior only; exact joint payoffs and RM+ are authoritative.

### 6. Forced router samples did not isolate false negatives

The 10% forced-deep check ran before uncertainty guards. Some recorded
"calibration" roots would have gone deep anyway and were not samples of the
otherwise-skipped population. V23 evaluates learned and deterministic guards
first, then forces 10% of only the remaining stable roots. Collection reports
forced samples, witnessed false negatives, and their rate. Once at least 128
samples exist, a rate above 10% fails collection quality instead of silently
training on an under-searching controller.

## Benchmarks

### Solver convergence

`tools/benchmark-rmplus-quality.py` solved 128 deterministic random 13×13
zero-sum matrices on the production CPU path:

| Root solve | Mean exploitability | p95 | Time/matrix |
|---|---:|---:|---:|
| 256 RM+ updates | 0.03659 | 0.05469 | 1.99 ms |
| 2,048 RM+ updates | 0.00858 | 0.01249 | 16.21 ms |

Mean exploitability fell 4.26×. Repeated result tuples were identical.

### Exact Pokémon root matrices

`tools/benchmark-root-search-quality.py` used the fresh V22 checkpoint and 16
complete exact roots on an RTX 3080 Ti with compiled inference. Both solve
budgets received identical payoff matrices, averaging 41.19 legal joint
actions:

| Root solve | Mean exploitability | Maximum | Time/root |
|---|---:|---:|---:|
| 256 RM+ updates | 0.000849 | 0.003168 | 99.09 ms |
| 2,048 RM+ updates | 0.000106 | 0.000396 | 116.78 ms |

The fresh model's greedy joint actions did not change in this small root sample.
That is not a strength claim. It establishes an 8× reduction in matrix-solver
error for 17.70 ms/root while holding exact mechanics, chance seeds, network,
and payoff matrices fixed. Paired promotion remains authoritative.

Raw reports are `/tmp/v23-rmplus-quality.json` and
`/tmp/v23-root-search-quality.json` on the benchmark host.

## Rejected or deferred recommendations

- **Alternating-player UCT/PUCT:** incompatible with simultaneous matrix nodes
  and can converge to the wrong response semantics.
- **Gumbel sequential halving or root top-k:** useful in large sequential action
  spaces, but it removes legal root joint actions here and weakens the complete
  RM+ teacher contract.
- **Dirichlet root action replacement:** an equilibrium mixed strategy is not a
  single-player exploration temperature. Diversity remains outside the solver
  through paired reset generation and sampled RM+ actions.
- **Direct policy or value action selection:** priors and values guide search;
  they do not bypass RM+.
- **Mechanics transpositions:** still blocked until the identity includes every
  future-relevant mechanics and RNG component with a collision-resistant
  contract.
- **Subtree reuse across real decisions:** deferred with transpositions and
  native handle-lifetime proof work. Reusing a merely similar observation would
  be unsound.
- **Learned dynamics/MuZero:** exact Lean mechanics are available and remain the
  transition authority.
- **Blindly increasing depth or completing every deeper matrix:** both consume
  the same constrained transition budget. They need paired equal-wall-clock
  strength evidence before becoming a production default.

## Production lineage

These changes define incompatible controller lineage
`transformer-variable-party-bf16-rmplus-v23-quality-search`, solver
`simultaneous-matrix-tree-rmplus-fresh-root-v2`, and selector
`simultaneous-matrix-tree-rmplus-every-decision-v2`. The active V22 process is
not modified. V23 must start as a separate run and pass collection integrity,
router calibration, paired promotion, probes, party strata, and campaign gates.
V24 subsequently supersedes this not-yet-started lineage with pooled expanded-node
inference; see the [GPU utilization root-cause review](gpu-utilization-root-cause.md).
V26 then moves the solver kernel to Rust and enables CFR+ without pruning the
complete root; see the [native solver review](rust-rmplus-cfrplus.md).
