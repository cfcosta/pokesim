# V27 promotion drought: second investigation

## Scope

This is an independent second investigation of why the V27 run at

```text
/tmp/pokered-variable-party-shadow-v27-persistent-eval-4096x16-warm-policy003-20260803
```

promoted only one of thirty candidates. It re-derives every number from the
run's raw artifacts: the 30 per-iteration metrics files (including all 61,440
per-battle promotion records), the 31 checkpoints, the warm-start tensors, the
completed final arena, and the V26 lineage runs on `/media`. It does not modify
any run artifact. The first audit is
`docs/research/v27-thirty-iteration-promotion-audit.md`; this document
confirms its integrity findings, sharpens its "plateau" conclusion into a
different shape, and adds four findings the first audit missed.

Verification of the first audit that this investigation reproduces
independently: the paired-CI arithmetic (recomputed from raw battle records,
matching all 30 reported intervals), the per-iteration promotion panels being
freshly seeded (`seed + 70,000,000 + iteration * 10,007`), complete 1,024/1,024
side-swapped pairs everywhere, zero mechanics timeouts, and the gate logic in
`transformer_pipeline.py:3038` requiring robust score >= 0.5 and paired CI low
>= 0.5 plus nine quality gates. No evaluator defect was found. The promotion
count is real, not clerical.

## The answer in one paragraph

Promotions were rare because three quantitative facts stack multiplicatively.
First, the evaluation regime compresses model quality into a ±1.5 percentage
point band: with both sides running converged CFR+ search at every decision,
86.6% of side-swapped pairs split (the reset decides, not the model), so even
a trained network beats a random one by roughly nothing. Second, inside that
compressed band the gate's minimum detectable effect is +1.12pp at 50% power
(+1.60pp at 80%), i.e. the gate only fires on readings near the top of the
achievable range. Third, the learner's true progress per update is roughly
+0.05pp trend with ±0.30pp of update-to-update churn, and the one promotion
reset the baseline to a churn peak, after which continued training genuinely
regressed before slowly recovering. Under the fitted dynamics the expected
number of post-promotion deployments in iterations 5-30 is 0.10; observing
zero is the central outcome, and the early promotion itself had roughly a 30%
prior probability. One promotion in thirty iterations is this system's
equilibrium cadence, not a malfunction.

## Finding 1: full-search evaluation compresses model differences ~40x

Across all 30 promotion panels (30,720 pairs):

```text
candidate sweeps both sides    1,862   (6.1%)
pair splits one game each     26,609  (86.6%)
incumbent sweeps both sides    2,249   (7.3%)
```

Only 13.4% of resets are model-sensitive at all; the other 86.6% are decided
by the matchup. The within-pair outcome correlation is -0.73, which makes the
side-swap pairing genuinely efficient (3.7x variance reduction over unpaired
play), and the resulting CI half-width of ~0.0112 is about as good as 2,048
games can be. The problem is not the estimator; it is the signal.

The V26 fresh run is the control experiment nobody ordered: a learner trained
from scratch, evaluated against its own random-initialized incumbent with the
same machinery, read 0.5010, 0.5039, 0.4946 over three iterations with the
same 85-86% split rate. Trained-versus-random is worth roughly 0pp in this
regime. V27's own extremes agree: the entire 30-iteration score range spans
0.4775-0.5137, i.e. about ±10 Elo, while the shadow's supervised diagnostics
improved by double-digit percentages. Search, holding 512-episode budgets and
near-zero exploitability solves at every decision, owns the outcome; the
network's leverage on win rate is confined to a ±1.5pp corridor.

Any promotion gate that demands +1.12pp from a single update is therefore
asking the network to express most of its total available leverage in one
step. That happened once (iteration 4) and nearly happened once more
(iteration 30).

## Finding 2: not a flat plateau — a real regression, then a real recovery

The first audit read iterations 5-30 as noise around parity. The pooled data
say otherwise:

```text
iterations 5-30 pooled          26,195 W / 26,838 L over 53,248 games
pooled robust score             0.4919   (t = -5.66 against 0.5)
iterations 5-9 pooled           0.4856   (z = -5.6)
OLS trend over 5-30             +0.047pp per iteration (t = 2.79)
trend value at iteration 30     ~0.498
```

Both the deficit and the recovery are statistically decisive. The shadow that
continued training after the promotion became genuinely weaker than its own
frozen iteration-4 snapshot — a direct head-to-head measurement on fresh
panels, so no winner's-curse artifact can explain readings below 0.5 — and
then spent 25 iterations climbing back at half a point per ten iterations,
ending at approximately true parity. The independent probe series (0.4949
pooled over 6,656 games) and campaign series (0.4997) corroborate. The
iteration-30 reading of 0.5107 sits ~2 sigma above its own trend value, the
same flavor of panel event as iteration 4.

Beyond-sampling variance decomposition: per-iteration readings carry 0.0057
sampling SE, but the between-iteration spread implies an additional ±0.30pp of
true strength churn per update. The learner's real motion each iteration is
mostly churn (±0.30pp) around a small drift (+0.047pp) — a per-update
signal-to-churn ratio of ~0.16, against a gate that needs +1.12pp.

## Finding 3: the churn is head churn, and the regression lives in big parties

Checkpoint tensor analysis (learner state across policy-000..030):

```text
per-iteration step L2           6.3-7.9, successive-step cosine +0.20..+0.35
net displacement from iter 4    44.79 L2 (16.5% of parameter norm) in a
                                stable direction (cos 0.99 by iteration 29)
module drift, iter 4 -> 30      leaf head 105.4% of its norm
                                budget head 68.0%
                                value head 63.7%
                                policy head 17.7%
                                trunk 16.0%
module drift, iter 4 -> 9       leaf 40.1%, value 25.6%, budget 33.4%,
                                policy 8.0%, trunk 6.7%
```

There is no oscillation — updates point in a consistent, slowly turning
direction. What moves is almost entirely the value/leaf/budget heads,
re-fitting continuously to non-stationary targets (search targets softened all
run: mean target entropy rose 0.107 → 0.166; equal-battle value MSE fell to
0.28 by iteration 24 and rose back to 0.37-0.40 as the distribution shifted).
The trunk gradient is also value-dominated: raw value/policy trunk-gradient
norm ratio ran 3.0-5.6 (about 1.0 after loss weighting), with near-zero cosine
between the two gradient fields.

The strength consequence is exactly where leaf evaluation matters most —
long games that outrun the depth-4 horizon:

```text
pooled stratum scores, iterations 5-30 vs the iteration-4 snapshot
  party-1to2      0.4988   (n=2,080 pairs, parity)
  party-3to4      0.4936   (n=2,028)
  party-5to6      0.4853   (n=10,374, z ~ -8)
  unequal-party   0.4964   (n=15,184)
```

Iteration 4 was promoted on big-party strength (party-5to6 0.5213, its best
stratum); the post-promotion regression is a big-party regression. The
mechanism reads as: promotion snapshotted a leaf/value-head configuration that
searched well in long games; the next few thousand optimizer steps re-fitted
those heads to the shifted post-promotion data distribution (new deployed
opponent, softer search targets), transiently degrading exactly that strength;
the trunk and policy head — the priors that persist — barely moved. Per-update
supervised gains meanwhile decayed 135x (held-out policy-KL improvement per
iteration: -0.054 at iteration 1, -0.0004 at iteration 30).

## Finding 4: the promotion cadence observed is the cadence this system predicts

Model: true edge e_t = 0.4919 + 0.00047·(t-17.5) with ±0.30pp true churn,
±0.57pp panel sampling noise, promotion at reading >= 0.5112 (the mean CI
half-width above 0.5).

```text
expected promotions, iterations 5-30       0.10
promotion probability, iterations 1-4      ~8.4%/iteration (true edge ~+0.23pp)
P(at least one promotion in 1-4)           ~30%   -> it happened, at 4
50% cumulative chance of next promotion    ~iteration 42, if the trend holds
```

In Elo terms: the gate demands ~8 Elo from one update; the learner delivers
~0.3 Elo of trend per update plus ~2 Elo of churn. One promotion per 30-40
iterations is the equilibrium rate. The first audit's "53% chance of at least
one false crossing in 30" framed iteration 4 as plausibly spurious; the
correct frame is the opposite — given a small true early edge, one early
promotion was likely, and zero later promotions was near-certain.

On iteration 4 itself, the first audit understated the independent evidence by
citing only the final arena (0.5088, n=1,024). Adding the iteration-4 probe
panel — a disjoint, non-selecting panel against the same incumbent (0.5469,
140W/116L over 256) — the selection-free pooled estimate is 0.5164 over 1,280
games, z = +2.28, one-sided p ~ 0.011. The one promotion the run made was very
probably a real improvement of roughly +1pp against the warm-start incumbent.

## Finding 5 (new): infra events are scored as candidate losses, and that cost iteration 30 its statistical pass

`run_paired_arena` scores every non-finished game 0.0 for the candidate
(arena.py:1225-1242). Across the 30 panels there were 248 such games — 241
`search-semantic-divergence` and 7 `decision-horizon-512` truncations — all
infrastructure events, side-balanced (123 candidate-as-player vs 125
candidate-as-enemy), and therefore model-independent. Scoring them as
candidate losses is a systematic anti-candidate bias averaging -0.20pp of
robust score per panel (worst panel: -0.37pp at 15 divergences) — 18% of the
gate's minimum detectable effect spent on noise that has nothing to do with
either model.

Rescoring non-finishes as neutral 0.5 flips exactly one decision in the run:

```text
iteration 30, robust scoring    mean 0.5107   CI low 0.4996   -> rejected
iteration 30, neutral scoring   mean 0.5115   CI low 0.5003   -> passes
```

Iteration 30 missed statistical superiority by 0.0004 — less than the penalty
it absorbed from 2 semantic divergences and 1 truncation. It would still not
have deployed (the router gate below failed independently), but the final
candidate of the run lost its statistical pass to an infra artifact, at a gate
whose entire detection budget is 1.12pp. Non-finished pairs should be excluded
from the paired CI (or scored 0.5); "robust" scoring of infra events buys
conservatism the gate cannot afford. Separately, driving the ~0.4% semantic
divergence rate toward zero is worth doing for its own sake.

## Finding 6 (new): the router integrity regression began around iteration 23, hidden by a sample floor

The collection-quality gate only evaluates the forced-sample false-negative
rate once `forced_router_samples >= 128` (transformer_pipeline.py:2274-2280).
Shallow routing was nearly nonexistent until mid-run, then grew as the budget
head drifted (68% of its norm post-promotion):

```text
iter    forced samples    false negatives    rate
 22           15                 -              -
 23           17                 4            0.235
 24           21                 7            0.333
 25           29                12            0.414
 26           28                 1            0.036
 27           42                 5            0.119
 28          101                12            0.119
 29          137                22            0.161   <- first gate failure
 30          133                15            0.113
```

Pooled over iterations 23-28 the rate was 41/238 = 17.2%, well above the 10%
limit, while the gate stayed green for lack of samples. The first audit's
"collection quality passed through iteration 28" is a statement about the
gate, not about the router: the router was miscalibrated at the production
threshold for the final quarter of the run, and the training shards from
iterations 23-30 were collected under it (low volume — hundreds of shallow
decisions out of ~80,000 — but the trend, not the volume, is what matters for
the integrity contract). A pooled multi-iteration false-negative monitor with
a confidence bound would have flagged this six iterations earlier. The first
audit's threshold-alignment recommendation stands, with this earlier onset as
additional urgency.

## What the first audit got right, and what changes

Right: gate integrity, evaluator integrity, per-iteration panel freshness, the
refusal to lower the confidence bar, the router operating-point mismatch, and
the observation that supervised gains did not convert to strength. Its four
proposed experiments remain reasonable.

Revised: "plateau" is the wrong shape. The run is promotion → genuine
regression (head churn on a shifted distribution) → genuine slow recovery to
parity. "Noisy overshoot", which the audit listed as the alternative, is
closer, but the overshoot is localized in the leaf/value/budget heads, not in
oscillating optimization (step cosines are positive; there is no bouncing).
The audit's diagnosis that constant-rate updates "do not produce a stable
increase in paired game strength" is confirmed with the sharper statement:
they first produce a measurable decrease, then a +0.3 Elo/iteration climb.

Corrected: the router regression onset (iteration ~23, not 29), and the
strength of independent evidence for the iteration-4 promotion (p ~ 0.011, not
merely "does not reject parity").

New: the pair-split compression measurement (86.6%), the V26 trained-vs-random
control, the gate power arithmetic (MDE +1.12pp / +1.60pp), the cadence model
(0.10 expected promotions in 5-30), the infra-event scoring bias and the
iteration-30 flip, and the big-party localization of the regression.

## What would actually change the promotion rate

In descending order of leverage:

1. **Make the evaluation sensitive to the thing being trained.** The
   deployment panel can stay full-search, but the learning signal should be
   read where the network has dynamic range: reduced-search arenas (root-only
   or minimum-budget solves) between shadow and incumbent would widen the
   ±1.5pp corridor and expose the +0.3 Elo/iteration trend within a few
   iterations. Today the run flies blind between promotions because the only
   strength gauge saturates at exactly the operating point being trained.
2. **Accumulate evidence across panels instead of demanding it per panel.**
   At +0.5pp true edge, one-shot 80% power needs ~10,500 pairs (~21,000
   games). A group-sequential test pooling consecutive promotion panels (with
   alpha spending, since the candidate moves between panels) reaches the same
   power for the same total games spread over the iterations the run already
   plays. This is the audit's experiment 3, quantified: without it, panels of
   1,024 pairs structurally cannot see 0.3 Elo/iteration progress.
3. **Stop paying the infra tax at the gate.** Exclude non-finished pairs from
   the paired CI (they are side-balanced infra events), and separately drive
   semantic divergences to zero. This is worth +0.20pp of gate budget on
   average and already flipped one statistical decision (iteration 30).
4. **Damp post-promotion head churn.** The regression mechanism is rapid
   leaf/value/budget re-fitting to the post-promotion distribution. Candidate
   options: EMA weights for the arena candidate (audit experiment 4), a
   reduced learning rate on the leaf/value/budget heads relative to the trunk,
   or a lagged leaf evaluator for search while the training head moves. The
   update-size experiment (audit experiment 2) tests the aggregate version of
   this; the module-level data say the heads, not the trunk, are where the
   churn lives.
5. **Pool the router audit across iterations.** Keep the 128-sample floor for
   single-iteration verdicts, but add a pooled false-negative estimate with a
   95% lower bound over a sliding window; iterations 23-25 (12/67 pooled)
   would have failed it in real time. Threshold-consistent diagnostics (audit
   experiment 1) remain necessary.

The dominant constraint is unchanged from the first audit — strength gained
per optimizer step — but the operative bottleneck for *observing* that
strength is evaluation dynamic range and per-panel power, and the operative
bottleneck for *keeping* it is head stability across the promotion boundary.
