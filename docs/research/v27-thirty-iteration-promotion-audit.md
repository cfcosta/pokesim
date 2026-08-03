# V27 thirty-iteration promotion audit

## Scope

This audit covers the immutable V27 run at:

```text
/tmp/pokered-variable-party-shadow-v27-persistent-eval-4096x16-warm-policy003-20260803
```

The run used seed `20260806`, 4,096 paired self-play battles per update, 16
collection actors, 12 persistent evaluation workers, and 2,048 promotion games
per update. The deployed and shadow models were initialized separately from the
recorded V26 incumbent and learner checkpoints. All conclusions below come from
the run's existing metrics, shards, checkpoints, and arena artifacts; no
post-hoc battle result was added to a promotion decision.

At the time of this audit, all 30 optimization iterations and their promotion,
probe, and campaign evaluations had completed. The service was still running
the final report arenas, so `summary.json` and the immutable manifest did not
yet exist.

## Promotion result

Only iteration 4 promoted:

| Iteration range | Promotion baseline | Mean robust score | Result |
| --- | --- | ---: | --- |
| 1–3 | warm-start incumbent | 0.5023 | no promotion |
| 4 | warm-start incumbent | 0.5137 | promoted; CI low 0.5022 |
| 5–10 | iteration-4 incumbent | 0.4885 | no promotion |
| 11–20 | iteration-4 incumbent | 0.4896 | no promotion |
| 21–30 | iteration-4 incumbent | 0.4963 | no promotion |

The promotion gate behaved as implemented. Of the 29 rejected candidates:

- every candidate failed the paired-confidence requirement;
- eight also failed a held-out skill probe, but none of those eight had passed
  paired confidence, so probes did not reduce the promotion count;
- iterations 29 and 30 also failed collection quality because the adaptive
  router's forced-sample false-negative rate exceeded 10%; and
- party-size, arena non-finish, and campaign gates did not block an otherwise
  statistically superior candidate.

Seven robust point estimates were at least 0.5, but only iteration 4 had a 95%
paired confidence lower bound at least 0.5. Lowering the confidence requirement
would therefore create more deployments, but would not establish that those
models are stronger.

Iteration 30 was close:

```text
wins / losses / non-finishes       1046 / 999 / 3
robust score                        0.5107421875
paired 95% confidence interval     [0.4995953481, 0.5218890269]
```

Its point estimate favors the final shadow learner by 1.07 percentage points,
but the existing evidence does not satisfy the deployment contract.

## The accepted update has weak independent confirmation

Iteration 4 won its selected promotion panel with robust score `0.513671875`
and paired CI `[0.5022124742, 0.5251312758]`. The independent final arena that
had completed by this audit compared the deployed iteration-4 model with the
original incumbent on a different panel:

```text
robust score                        0.5087890625
paired 95% confidence interval     [0.4926631080, 0.5249150170]
```

The independent point estimate is still positive, but it does not independently
reject parity. This is consistent both with a real sub-one-percent improvement
and with selection noise. A per-update two-sided 95% lower-bound test presents
about a 2.5% one-sided false-promotion opportunity under exact parity. Repeating
that opportunity 30 times gives approximately a 53% chance of at least one
crossing under an independence approximation. The tests are not actually
independent, so that number is diagnostic rather than a calibrated run-level
error rate, but it demonstrates why one crossing is not surprising by itself.

Future promotion design should account for repeated looks through a
pre-registered confirmation panel, alpha spending, or less frequent promotion
evaluations. It should not weaken the lower-confidence requirement.

## The shadow learner did learn the supervised objectives

The final checkpoint contains the unchanged iteration-4 deployed model and the
continued iteration-30 shadow learner. Tensor-state hashes confirm that the
main deployed state changed once and then remained fixed, while every embedded
shadow state changed:

```text
deployed state through iteration 3   59d75b5fb099
iteration-4 deployed state           820694f86cd1
iteration-30 deployed state          820694f86cd1
iteration-30 shadow state            4f11629fa306
```

The full checkpoint hashes are:

```text
policy-004.pt  8c6bed5fe62ea618f78af08c3191a5152a270c8cb0d33b7b5e7e5ef8945b5904
policy-030.pt  11fb637ca3efdd1d534c965bb175d58c393aeb91ae96df75d8afa6651ce9f4dd
```

On the fixed held-out partition from shards 29 and 30, the final shadow learner
outperformed the deployed incumbent on every main supervised diagnostic:

| Diagnostic | Deployed iteration 4 | Shadow iteration 30 |
| --- | ---: | ---: |
| Policy KL | 1.0302 | 0.9101 |
| Policy top-action agreement | 0.3854 | 0.4092 |
| Equal-battle value MSE | 0.4842 | 0.3649 |
| Distilled-leaf value MSE | 0.5045 | 0.4542 |
| Budget BCE | 0.7469 | 0.6315 |

This rules out a frozen learner or failed checkpoint-persistence path. It also
shows that lower imitation and value error did not translate one-for-one into
playing strength. Search, rather than raw policy selection, owns every action;
network improvements affect finite-search priors and leaves and can therefore
have a smaller effect on game outcomes than their supervised losses suggest.
Across the 30 non-stationary held-out panels, promotion score had little linear
association with policy KL, value MSE, leaf MSE, or target entropy.

## Optimization dynamics indicate a strength plateau

The run processed 122,880 self-play battles and made 47,486 AdamW updates at a
constant learning rate of `0.0002`. After the first iteration, each update used
about 1,600 optimizer batches because the replay window contained two 4,096-game
shards. Doubling self-play volume from 2,048 to 4,096 therefore also roughly
doubled optimizer steps per training iteration; the learning rate and epoch
count were not rescaled.

The shadow model moved materially after its only promotion. Its L2 distance from
the iteration-4 state reached 44.79 by iteration 30, or 16.5% of the
iteration-4 parameter norm. Each iteration moved about 6.3–6.8 L2 units, yet
playing strength against the deployed incumbent remained near parity. The first
post-promotion candidate immediately scored `0.4873`; the worst candidate,
iteration 17, scored `0.4775`; and the final candidate recovered to `0.5107`.
Scores against the mixed checkpoint/heuristic collection population were also
flat: the first five iterations averaged `0.5544`, and the last five averaged
`0.5522`.

The evidence supports a plateau or noisy overshoot more strongly than a broken
evaluator. Constant-rate updates continue to improve the current supervised
objective while moving far from the deployed model, but they do not produce a
stable increase in paired game strength.

## Adaptive-router integrity regression

Collection quality passed through iteration 28 and failed on iterations 29 and
30:

| Iteration | Forced samples | False negatives | Rate | Limit |
| --- | ---: | ---: | ---: | ---: |
| 29 | 137 | 22 | 0.1606 | 0.10 |
| 30 | 133 | 15 | 0.1128 | 0.10 |

Held-out router diagnostics classify at probability `0.5`, while production
routes deep at `0.55`. The final shadow's held-out recall was 99.26% at `0.5`,
which masks the production operating-point miss. Production still selected deep
search for 98.5% of iteration-30 decisions, so the router saved little work
while making the final collection inadmissible.

A future lineage should report router precision and recall at the configured
production threshold and benchmark a conservative `0.5` threshold or a model
trained/calibrated explicitly for the `0.55` operating point. Simply raising the
allowed false-negative rate would weaken the integrity contract and is not an
acceptable fix.

## Evaluator integrity

The persistent evaluator did not explain the low promotion count:

- all promotion panels contained the configured 2,048 games and 1,024 complete
  side-swapped pairs;
- candidate player/enemy assignments were balanced 1,024/1,024;
- mechanics timeouts were zero;
- semantic divergence and truncation stayed below arena quality limits;
- the V27 pre-deployment parity benchmark reproduced separate-pool scores and
  finish counts exactly at equal worker count; and
- no candidate passed paired confidence and was then rejected only because of
  persistent-pool orchestration.

The remaining final report path was a separate performance issue. It evaluated
the deployed incumbent sequentially against the initial model and 49 heuristic
opponents, 1,024 games each. At audit time it had completed the initial arena
and nine heuristic arenas after about two hours. This did not affect any of the
30 promotion decisions.

The follow-up final-report pool loads the deployed candidate once per worker and
assigns each independent report as a whole job. It does not repartition games
within a report, so report summaries and replays remain byte-identical to the
sequential path. Completed-arena counts now reach the monitor, and a fully
optimized run can resume finalization after its last committed iteration.

## Conclusions and next experiment

The one-promotion result is primarily a real strength plateau under a strict
per-update confidence gate, not a missing promotion or persistent-evaluator
bug. The final shadow is measurably better at fitting search/value targets and
has a promising but unconfirmed +1.07-point paired result. It must remain a
shadow because it missed confidence and collection-integrity gates.

The next training lineage should isolate changes rather than combine them:

1. **Router integrity experiment:** align diagnostics with the production
   threshold and compare `0.50` versus `0.55`, preserving complete search and
   requiring the existing false-negative limit.
2. **Update-size experiment:** compare the current 1,600-step constant-rate
   update with either `0.0001` learning rate or a deterministic approximately
   800-step cap. This tests the doubled-data/unchanged-rate overshoot hypothesis.
3. **Promotion-power experiment:** evaluate less frequently and use a larger,
   pre-registered paired panel with run-level error control. This detects
   cumulative sub-one-percent gains without lowering confidence.
4. **Candidate-stability experiment:** predeclare a single EMA or trust-region
   candidate and compare it with the raw shadow under equal compute. Do not
   select the best of several candidates on the same panel.

The dominant constraint is now strength gained per optimizer step, not GPU
occupancy or promotion throughput.
