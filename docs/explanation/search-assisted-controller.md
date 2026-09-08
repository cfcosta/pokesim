# Search-assisted battle controller

<!-- mode: explanation -->

V33 uses search in self-play and deployment. A learned policy prior and
terminal-outcome value guide simulation at each decision. The full declared
party state is known to the policy; future chance draws remain hidden.

## Independent controllers

Each neural controller owns a search evaluated entirely by its own checkpoint
in its own canonical view. It does not borrow the other checkpoint's policy or
value estimates. Heuristic opponents choose their own actions directly.

The scheduler shares immutable native transitions and batches neural calls.
That shares computation, not decisions. Each controller's random streams remain
isolated from the opponent's implementation. Executed actions are composed
after both controllers finish; their composition does not pretend to be a joint
equilibrium of one shared payoff matrix.

A canonical network produces its policy, an opponent policy estimate, and its
value. Enemy-canonical values are negated when placed in the physical
player-relative matrix. Both training policy heads come from the same
controller's solve.

## Objective and approximation

Every root covers all legal joint actions with equal chance sample counts and
common random numbers across pairs. Terminal cells receive the witnessed
outcome; other leaves receive the controller's terminal-outcome estimate.
Tactical HP/status/PP potential differences are not added to that estimate.

Defaults use depth two, four root chance worlds, three highest-prior legal
actions per side at interior nodes, and two interior chance worlds. Full
transformer evaluation is the default at interior nodes and leaves.
Distilled evaluation is an explicit approximation.

The default positive-temperature solver computes

```text
max_p min_q pᵀ Q q - τ KL(p || p₀) + τ KL(q || q₀)
```

with τ = 0.02 and normalized legal priors. Its persistent extragradient updates
differ from unregularized regret matching. The zero-temperature Rust/Python
regret solvers remain explicit ablations. A small regularized gap does not
imply zero unregularized exploitability.

The target is the solution of the mean payoff matrix. Split-half solutions
measure chance sensitivity; their policies are never averaged into the teacher.
Reliability weighting remains separate and explicit.

These sampled, finite-horizon simultaneous matrix trees retain interior
pruning, chance error, value error, and regularization bias. Root coverage does
not establish optimal battle play. Ordinary alternating-player PUCT would not
preserve the simultaneous decision semantics.

## CUDA and precision

BF16 autocast is the neural training and inference default. Parameters,
optimizer moments, gradients, policy normalization, losses, and reductions
remain FP32. Explicit FP32 neural evaluation also respects its precision in
compiled mode and disables surrounding autocast.

Compatible matrix jobs at the same tree depth are batched. A fused Triton
kernel compacts legal actions and retains iterative solver state on the GPU
through all updates. FP32 is the practical CUDA default. Rust FP64 is the
differential reference and the fallback below measured crossover. An explicit
FP64 CUDA mode supports numerical comparisons.

Automatic dispatch considers batch size, legal width, iteration count, device,
and supported numerical domain. Unsupported explicit CUDA requests fail
visibly. Diagnostics record actual solver backends and precision, as well as
requested and effective leaf evaluators.

Bit-identical replay requires the saved software, hardware/arithmetic choices,
and batching configuration. CUDA FP32 versus Rust FP64, or automatic dispatch
across different batch sizes, is compared with tolerances. Solver wall times
are excluded from deterministic training shards.

## Three-second serving

The timed controller starts with a complete depth-one, one-world matrix. It
first seeks two chance worlds, then more depth and samples up to configured
limits. Admission uses measured previous-pass time, the ratio of tree sizes,
and a 1.25 margin. It stops early when no complete refinement is predicted to
fit; it need not consume all three seconds.

An ordinary failed refinement preserves the previous complete decision.
Failure of the first pass raises an error. Native timeouts invalidate the
supplied server and require recreation/restoration. Decisions never use a
partial root matrix. Mixed-strategy sampling happens once, after refinement.

Decision time includes native simulation, neural inference, solving, CPU
result transfer, action sampling, and tensor packing. Server startup,
checkpoint loading, and compilation warmup are separate. Native requests and
CUDA launches cannot be safely preempted, so admission is not a hard deadline
guarantee. Results report overruns and failures.

Before compiled serving, call
`warm_decision_network(network, snapshot, search_config=config)`. It visits
every supported static batch bucket and available inference path twice,
including CUDA graph setup. Ordinary battle warmups can miss shapes.
Matrix-kernel startup is separate and measured by a cold decision. Eager
serving avoids neural compilation startup.

Training and promotion retain fixed search work so that machine speed cannot
change targets or candidate comparisons.

## Learning evidence

Only completed episodes receive terminal-value targets. Dataset partitions
follow originating resets through swapped legs, frontier restarts, and team
replay. Descendants cannot cross the training/held-out boundary. Missing or
contradictory ancestry is rejected.

The continuing learner and deployed incumbent are separate checkpoint states.
Evaluation selects deployed or learner explicitly and records the checkpoint
hash. Production promotion requires the current candidate's search-assisted
paired lower confidence bound to exceed 0.5, plus applicable quality and probe
gates. Policy-only and historical pooled scores are diagnostics. An all-draw
panel with interval [0.5, 0.5] cannot promote an update.

These contracts repair reproducible objective, isolation, and measurement
defects. Demonstrating stronger play still requires a trained checkpoint,
fixed-budget comparisons against its incumbent and fixed opponents, and
independent held-out battles.

See [commands](../../packages/battle-training/README.md) and
[validation](../research/v33-search-validation.md).
