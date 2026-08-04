# V28 self-play distribution audit and data-generation plan

## Scope

The V28 tier-a run (`/tmp/pokered-variable-party-shadow-v28-tier-a-fresh-4096x16-20260803`,
seed 20260807, 4096 episodes × 16 actors, tier-a preset at 3,004,317 parameters) reproduces
the V27 promotion plateau almost exactly: promotions at iterations 1 and 4, then nothing
through iteration 19, with held-out value error bottoming mid-run and regressing afterwards.
V27's capacity hypothesis (E3 of the literature audit) predicted the 3.2× larger model would
move the plateau. It did not. This audit asks the follow-up question: is the self-play data
distribution the binding constraint, and what changes would generate better data?

Sources: per-iteration telemetry of the live run (`metrics/iteration-001..019.json`), the
collection and promotion code in this checkout (the runtime checkout mirrors the cited
paths), and the docbert corpus — AlphaZero (`#8ab258`), the MCTS survey (`#908358`),
Beyond Games (`#f5a7a3`). Claims that rest on papers outside the corpus are flagged as
such inline.

One correction to a verbally reported finding: root-only solves produce **under 1%** of
policy targets in this run, not ~31% as initially stated. E3 below carries the corrected
numbers and the revised conclusion they force.

## The run in brief

| it  | target entropy | held-out vMSE (eq) | leaf MSE | policy KL | quality pass | pooled FN rate (n) | accepted |
| --- | -------------- | ------------------ | -------- | --------- | ------------ | ------------------ | -------- |
| 1   | 0.577          | 0.641              | 0.641    | 0.841     | yes          | 0.000 (0)          | yes      |
| 2   | 0.108          | 0.506              | 0.653    | 0.933     | yes          | 0.469 (49)         | no       |
| 4   | 0.121          | 0.435              | 0.519    | 1.037     | yes          | 0.533 (60)         | yes      |
| 8   | 0.155          | 0.401              | 0.400    | 0.984     | yes          | 0.500 (22)         | no       |
| 12  | 0.167          | 0.298              | 0.434    | 0.973     | yes          | 0.096 (83)         | no       |
| 14  | 0.159          | 0.325              | 0.383    | 0.938     | yes          | 0.094 (170)        | no       |
| 15  | 0.154          | 0.337              | 0.408    | 0.923     | no           | 0.120 (191)        | no       |
| 17  | 0.144          | 0.349              | 0.441    | 0.920     | no           | 0.152 (263)        | no       |
| 19  | 0.156          | 0.352              | 0.418    | 0.934     | no           | 0.146 (267)        | no       |

Healthy vitals throughout: finish rate 99.3–99.6%, search exploitability ≈ 0, payoff
spread ~0.8, EMA leaf lag_l2 0.242, LR schedule stepping on time. The plant runs fine;
it is fed a stale diet.

## Evidence

### E1 — the opponent distribution froze at iteration 5

`opponent_counts` in the collection metrics shows exactly **three** model-opponent
identities (`a2c00b32…`, `b416cbd9…`, `c7a3df94…`) from iteration 5 through 19, at ~340
episodes each. The mechanism is structural: the historical pool is rebuilt each iteration
from **accepted** iterations only (`transformer_pipeline.py:3112`) and appended to only on
acceptance (`:3438`). With accepts at 1 and 4 only, the pool has been frozen at
{initial policy, iter-1, iter-4} for fifteen straight iterations.

The episode mix is equally rigid: `opponent_fraction = 0.5` (config default, `:109`) and
the deterministic share rotation in `_select_training_opponent` (`:281`) yield exactly
2048 mirror / 1024 model-opponent / 1024 heuristic episodes every iteration. Half of all
training data is the near-static learner playing itself; the "model opponents" are two
snapshots of essentially the same policy plus the random init.

This is a self-reinforcing loop: promotion stall ⇒ opponent pool stall ⇒ stationary data
⇒ nothing new to learn ⇒ promotion stall.

### E2 — play is near-deterministic and nothing injects exploration

Mean solve-target entropy collapsed from 0.577 (iteration 1) to 0.108 (iteration 2) and
has stayed in 0.10–0.17 since. Collection samples actions from the CFR+ solve mixture
(`sample_actions=True`, `transformer_pipeline.py:883`, `:2322`), but sampling from a
near-pure mixture is argmax. There is **no** Dirichlet noise, no temperature, no ε-greedy
anywhere in the collection path (verified by grep). The same openings and lines recur;
~112–119K examples per iteration heavily overlap with the previous iteration's.

The training-side signature matches: held-out `value_mse_equal_battle` bottoms at
iteration 12 (0.298) and climbs back to 0.352 by 19; the leaf distillation MSE bottoms at
14 (0.383) and climbs to 0.418; held-out policy KL has been flat at 0.91–0.97 since
iteration 2. That is overfitting to a stationary distribution, and it survived a 3.2×
capacity increase — strong evidence against the capacity hypothesis and for a data
hypothesis.

### E3 — correction: root-only targets are rare; the router FN gate is the real problem

Corrected numbers, per iteration: `root_only_decisions` is 0–573 against ~78–96K deep
decisions — **0.0–0.7%**, never more. Two consequences:

1. The originally proposed "deep-only policy targets" intervention is a near-no-op for
   this run. At ≤0.7% exposure, masking root-only policy targets changes nothing about
   the gradient. (The KataGo-style volume/quality split — cheap searches for data volume,
   full searches for policy targets; not in the corpus, general knowledge — becomes
   relevant only if we deliberately raise root-only share for throughput later.)
2. At `--adaptive-deep-threshold 0.50` the router sends ≥99.3% of decisions deep, so the
   adaptive budget head is currently saving no compute — while its calibration gate is
   failing the run. The pooled forced-calibration false-negative rate (window 6) breached
   the 0.10 limit at iteration 15 and has stayed at 0.120–0.152 on 191–267 pooled samples.
   `collection_quality["pass"]` has been false since, and it sits in the promotion
   conjunct (`transformer_pipeline.py:3358-3369`): any future statistically-superior
   candidate would be vetoed by a gate that guards <1% of decisions.

Per-iteration forced-calibration samples are tiny (0–80) and the raw rates bounce between
0.00 and 0.82, so pooling (the F6 fix) was right — but the gate has no notion of
*exposure*. A 15% FN rate on a mechanism that decides 0.5% of the time is a fourth-decimal
effect on data quality, yet it hard-blocks promotion, which is precisely what keeps E1's
opponent pool frozen.

### E4 — known-bad decision classes never improve

`ohko_into_faster_rate` has oscillated between 0.37 and 0.50 for nineteen iterations with
no trend; `capped_stat_setup_rate` likewise (0.29–0.43). The pipeline measures these
mistakes every iteration and then applies zero extra data pressure to the states that
produce them. Nothing in collection revisits states where the network was measurably
wrong; every episode starts from a fresh team preset and runs the same near-deterministic
lines (E2).

For completeness, the promotion side of the plateau is real, not just gate-vetoed: pooled
paired-score moments over iterations 5–18 give z = −1.15 (losses-policy pairing, 14,336
pairs, mean 0.4983) and z = +0.31 (exclude-pairs, 14,246 pairs, mean 0.5005). The learner
genuinely is not beating the incumbent — on data this stationary, that is the expected
outcome, not a contradiction.

## Literature grounding

AlphaZero (corpus `#8ab258`) uses both levers this plan proposes, and only during
training games:

> "Moves are selected in proportion to the root visit count. Dirichlet noise Dir(α) was
> added to the prior probabilities in the root node; this was scaled in proportion to the
> typical number of legal moves: α = {0.3, 0.15, 0.03} for chess, shogi and Go."

Evaluation/match play is greedy. The α-scaling rule (larger α for smaller branching
factors) puts our ≤13-action game in the α ≈ 0.5–1.0 range. Our CFR+-on-priors analogue:
noise the root priors that seed the collection-time solve, keep promotion/eval solves
pure.

Not corpus-backed (flagged, general knowledge): KataGo's playout-cap randomization (the
volume/quality split referenced in E3) and AlphaStar's league/PFSP opponent-sampling. The
league-lite recommendation below does not depend on the PFSP citation — the internal
evidence (E1) motivates it on its own; PFSP-style weighting is listed only as a possible
refinement. The MCTS survey (`#908358`) covers tree-level exploration-exploitation, not
self-play data generation, and contributes nothing directly here.

## Recommendations

Ordering is by leverage per unit of implementation cost. Every new behavior is flag-gated
and defaults to the exact legacy behavior, per the standing compatibility mandate: a run
launched with none of the new flags must be bit-identical to today.

### R1 — league-lite opponent pool: admit recent shadow checkpoints

Every iteration's shadow checkpoint is already saved (`checkpoints/policy-0NN.pt`); only
the accept path feeds the opponent pool. Add `--shadow-opponent-window N` (default 0 =
legacy): when N > 0, the opponent pool becomes the legacy accepted lineage **plus** the
last N shadow checkpoints regardless of acceptance, deduplicated, rotated through the
existing deterministic share machinery. Successive shadows differ by exactly the training
deltas, so games against them concentrate data where the learner has been changing —
directly attacking E1's stationarity without touching promotion semantics.

Cost: small (pool assembly in `_run_iteration` around `:3107-3132`, plus config/CLI).
Validation: `opponent_counts` shows >3 identities; held-out vMSE regression (E2) flattens.
Refinement later, if needed: PFSP-style weighting by win-rate instead of uniform rotation.

### R2 — rebalance the episode mix (config-only, no code)

With R1 in place, mirror games at 50% are the least informative half of the data. Raising
`--opponent-fraction` from 0.5 to ~0.67 cuts mirror share to ~33% and gives the enlarged
pool the extra slots. Zero code; revert by flag. Keep `model_opponent_share` at 0.5 so
heuristics retain their share (they anchor against forgetting basic play).

### R3 — collection-time ε-exploration on sampled actions

`--collection-epsilon E` (default 0.0 = legacy) and `--collection-epsilon-turns T`
(default 0 = all turns): with probability E per decision (optionally only in the first T
turns of each battle), sample the executed action from
(1−E)·σ + E·uniform(legal) instead of σ, **collection games only** — promotion arenas,
probes, and eval paths untouched. Policy targets stay the pure solve mixture σ; only the
trajectory branches. This is the cheap half of the AlphaZero rider: it restores line
diversity that entropy-0.11 play cannot produce, without touching the native solver.

Cost: small (actor decision loop around `:860-960`). Risk: value targets become slightly
off-policy; bound it with E ≤ 0.05 and the turn cap. Validation: unique-state coverage
and semantic-divergence counts rise; finish rate stays ≥99%; held-out vMSE trend.

### R4 — Dirichlet noise on collection-solve root priors

`--collection-dirichlet-alpha A` (default 0.0 = off) and
`--collection-dirichlet-weight W` (default 0.25, inert while A = 0): before the
collection-time root solve, mix each side's root priors with Dir(A) noise at weight W,
AlphaZero-style. Unlike R3 this changes what the solve itself explores, so the *targets*
also diversify — the full rider. Start at A ≈ 0.6, W = 0.25 per the α-scaling rule.

Cost: moderate — the injection point is where root priors feed the native CFR+ solve, and
needs a small design pass (Python-side prior shaping vs. Rust-side). Sequence after
R3 proves exploration helps at all. Validation: mean_target_entropy off the 0.10–0.17
floor; solve exploitability stays ≈ 0; held-out policy KL finally moves.

### R5 — exposure-aware router FN gate

`--router-fn-exposure-floor F` (default 0.0 = legacy): when the pooled root-only share
(`root_only_decisions / (root_only + deep_search_decisions)` over the same pooled window)
is below F, a pooled-FN breach downgrades from a gate failure to a logged reason —
`quality["reasons"]` still records it, `pass` stays true. At F = 0.02, this run's gate
(guarding 0.5% exposure with a 15% FN rate) stops vetoing promotion, while a run that
actually leans on root-only solves keeps the hard gate.

This is the immediate unblocking fix for E3 and it composes with, not replaces, the
pooling from F6. Companion for later (explicitly deferred after the E3 correction): a
`--root-policy-target-weight` mask only becomes worth building if we deliberately raise
root-only share for throughput, at which point the volume/quality split applies.

Cost: tiny (`_collection_quality`, `:2412-2434`, plus config/CLI). Validation: quality
gate passes on this run's telemetry replayed with F = 0.02; unit tests for both sides of
the floor.

### R6 — policy-target smoothing floor

`--policy-target-smoothing S` (default 0.0 = legacy): emit policy targets as
(1−S)·σ + S·uniform(legal) at shard-write time. At S = 0.02–0.05 this stops near-one-hot
targets from saturating the KL and keeps a gradient flowing through non-argmax actions.
Cheap, orthogonal, and reversible; complements rather than substitutes for real
exploration (R3/R4). Validation: held-out policy KL and top-action agreement.

### R7 — frontier snapshot capture

`--frontier-buffer-size N` (default 0 = off): during collection, tag each decision with
the local surprise already computable at solve time — |leaf/network value − final
outcome| and KL(solve σ, network prior) — and persist the top-N `native.Snapshot` states
(`native.py:81`) per iteration into a frontier buffer alongside the shards. Capture only;
no behavior change to episodes. This is the instrumentation half of E4's fix.

Cost: moderate (snapshot serialization, buffer file format, scoring). Validation: buffer
fills with states skewed toward the E4 mistake classes (inspectable offline).

### R8 — frontier restarts

`--frontier-restart-fraction F` (default 0.0 = off): start fraction F of collection
episodes from states sampled out of the previous iterations' frontier buffer (fresh
chance seeds, both controllers live) instead of fresh team presets. This finally applies
data pressure exactly where the network was measurably wrong, and breaks opening-line
correlation as a side effect. Depends on R7.

Cost: the largest of the eight (restart plumbing through episode setup). Risk: value
targets from mid-battle starts are conditioned on non-opening states — cap F ≤ 0.25.
Validation: the E4 rates (`ohko_into_faster_rate`, `capped_stat_setup_rate`) finally
trend down; per-class before/after comparison on frontier-sourced states.

## Recommended experiment order

1. **Wave 1 — unfreeze (R1 + R2 + R5).** Next run: `--shadow-opponent-window 6
   --opponent-fraction 0.67 --router-fn-exposure-floor 0.02`. These attack the two
   mechanically proven pathologies (frozen pool, exposure-blind gate) and cost one small
   feature plus one tiny one. Success: >3 opponent identities in `opponent_counts`,
   quality gate green, held-out vMSE stops regressing.
2. **Wave 2 — explore (R3 + R6).** Add `--collection-epsilon 0.05
   --collection-epsilon-turns 8 --policy-target-smoothing 0.02`. Success: target entropy
   off the floor, policy KL moves below 0.9, finish rate holds.
3. **Wave 3 — full rider (R4).** Swap or stack Dirichlet root noise
   (`--collection-dirichlet-alpha 0.6`), compare against Wave 2 on the same seeds.
4. **Wave 4 — frontier (R7 then R8).** Only after Waves 1–2 validate; R8 is the only
   intervention aimed squarely at E4.

Also available as pure dials on any wave: `--chance-samples-per-joint 2` (halves
chance-outcome variance in value targets at solve-time cost) — worth a probe run once
GPU headroom is understood.

## Conclusions

1. The V28 plateau is a **data** problem, not a capacity problem: the opponent
   distribution froze at iteration 5 (E1) and play is near-deterministic with no
   exploration mechanism anywhere in the collection path (E2). The 3.2× model made no
   difference, as the held-out regression shows.
2. The earlier "~31% root-only policy targets" claim was wrong — true share is <1%. The
   router's pooled FN gate is still a real problem, but as an exposure-blind promotion
   veto (E3), not as a data-quality issue.
3. Highest-leverage sequence: league-lite shadow opponents + mirror-share cut +
   exposure-aware gate first; ε-exploration and target smoothing second; Dirichlet root
   noise third; frontier capture/restarts last.
4. Every recommendation is flag-gated with legacy defaults; a run without the new flags
   remains bit-identical to current behavior.

## Task mapping

| Task | Rec | Flags                                                    | Size   |
| ---- | --- | -------------------------------------------------------- | ------ |
| 1    | R1  | `--shadow-opponent-window`                               | S      |
| 2    | R5  | `--router-fn-exposure-floor`                             | XS     |
| 3    | R3  | `--collection-epsilon`, `--collection-epsilon-turns`     | S      |
| 4    | R6  | `--policy-target-smoothing`                              | XS     |
| 5    | R4  | `--collection-dirichlet-alpha`, `--collection-dirichlet-weight` | M |
| 6    | R7  | `--frontier-buffer-size`                                 | M      |
| 7    | R8  | `--frontier-restart-fraction`                            | L      |

R2 and the `--chance-samples-per-joint` dial are run-configuration changes with no code
task.
