# V27 literature audit and capacity review

## Scope

This document does two things:

1. audits each finding of the
   [second promotion-drought investigation](v27-promotion-drought-second-investigation.md)
   against the locally indexed docbert paper corpus, marking every finding as
   confirmed, consistent, or not adjudicable from the available literature; and
2. answers the capacity question directly: should the next lineage increase
   model size (d_model, layers, feedforward), the distilled leaf evaluator,
   or search tree depth?

The audited run is the immutable V27 lineage at:

```text
/tmp/pokered-variable-party-shadow-v27-persistent-eval-4096x16-warm-policy003-20260803
```

All quantitative claims about V27 come from the prior two audits and their
extraction scripts; all literature claims cite a specific corpus document.

## Corpus coverage and its limits

The docbert corpus contains seven documents relevant to these findings:

| Corpus document | Used for |
| --- | --- |
| Mastering Chess and Shogi by Self-Play (AlphaZero, Silver et al. 2017) | gating design, LR schedule, Elo compression, MCTS error handling |
| Scaling Laws for Neural Language Models (Kaplan et al. 2020) | parameter-count scaling, shape insensitivity, sample efficiency |
| Training Compute-Optimal Large Language Models (Chinchilla, Hoffmann et al. 2022) | data-versus-parameter allocation |
| An Empirical Study of Catastrophic Forgetting in LLMs During Continual Fine-tuning (Luo et al. 2023) | continual-training degradation versus model scale |
| Self-Distillation Enables Continual Learning (Shenfeld et al. 2026) | on-policy distillation as churn mitigation |
| MCTS: A Review of Recent Modifications and Applications (Świechowski et al.) | simultaneous-move search, Pokémon ISMCTS precedent |
| Beyond Games: A Systematic Review of Neural MCTS Applications | background only; no sizing content |

The corpus does **not** contain: any SPRT/sequential-testing reference
(fishtest, Chess.com gating practice), the MuZero paper, AlphaStar or OpenAI
Five (league training, model surgery), the poker CFR line (DeepStack, Libratus,
ReBeL), the RL plasticity literature (Nikishin, Lyle, Sokar/ReDo), or Jones
2021 "Scaling Scaling Laws with Board Games" — the one published study that
directly measures the model-size-versus-search-compute trade-off in an
AlphaZero-style loop. Findings that depend on those bodies of work are marked
not adjudicable and rest on V27-internal evidence alone. See
[Corpus gaps worth filling](#corpus-gaps-worth-filling).

## Verdicts

| Finding | Verdict | Basis |
| --- | --- | --- |
| F1: strong search on both sides compresses the evaluation regime | Confirmed by direct analogue | AlphaZero footnote 3; MCTS error averaging |
| F2: per-update gate is underpowered relative to the learner's true rate | Consistent; field precedent agrees with the remedy | AlphaGo Zero 55%/400 gate versus AlphaZero's removal of gating |
| F3: post-promotion regression from leaf/value/budget head churn | Partially supported (mechanism class confirmed; locus is internal evidence) | Luo et al.; Shenfeld et al.; AlphaZero LR schedule |
| F4: iteration-4 promotion probably genuine | Not adjudicable from corpus; internal evidence stands | run-internal pooled z = +2.28 |
| F5: infrastructure non-finishes scored as candidate losses | Not adjudicable (no SPRT/fishtest literature indexed) | internal evidence only |
| F6: router false-negative regression masked by forced-sample floor | Not adjudicable (domain-specific instrumentation) | internal evidence only |

### F1 — evaluation-regime compression: confirmed by direct analogue

The investigation found 86.6% of promotion pairs split 1–1 once both sides run
depth-4 CFR+ search, compressing 26 iterations of learning into a ±1.5pp band.
AlphaZero documents the same mechanism in chess: footnote 3 states that "the
prevalence of draws in high-level chess tends to compress the Elo scale,
compared to shogi or Go." Split pairs play exactly the role of draws: they are
the modal outcome between near-peer agents whose search corrects most policy
differences before they reach the game result. The paper also explains why
search specifically produces this: MCTS-style search "averages over these
approximation errors," so residual network differences shrink further at the
decision level. Nothing in the corpus contradicts the compression finding, and
the V26-fresh control (candidate versus a weaker, differently-trained
incumbent produced decisive pair rates far above 13.4%) remains the direct
internal proof.

### F2 — the gate versus the learner's rate: consistent, and the field's own trajectory agrees

AlphaGo Zero gated deployment on winning "by a margin of 55%" over 400
evaluation games — a z ≈ 2 requirement with a minimum detectable effect around
5 percentage points. V27's gate (95% paired CI lower bound ≥ 0.5 on 1,024
pairs, MDE +1.12pp at 50% power) is *stricter in absolute terms* while the
learner's measured trend is +0.047pp per iteration — roughly 24× below the
gate's resolution, which is why the expected promotion count over iterations
5–30 was 0.10. One year later, AlphaZero **removed gating entirely**: "we
instead maintain a single neural network that is updated continually, rather
than waiting for an iteration to complete." That is the field's own answer to
per-update gates in regimes where individual updates are too small to certify
individually. The corpus therefore supports the investigation's remedy
direction — accumulate evidence across updates (group-sequential pooling) or
decouple deployment cadence from update cadence — and gives no support to
lowering the confidence bar, which neither AG0 nor AZ ever did.

### F3 — head churn and regression-then-recovery: mechanism class confirmed; specific locus is ours to own

Three corpus results bear on the churn finding:

1. **Continual-training degradation is real and does not vanish with scale.**
   Luo et al. observe catastrophic forgetting across continual fine-tuning of
   1b–7b models and find that "as the model scale increases, the severity of
   forgetting intensifies" in that range. Growing the V27 trunk is therefore
   *not* a churn fix by itself; mitigation has to be explicit regardless of
   model size.
2. **On-policy distillation is the mitigation with the strongest evidence.**
   Shenfeld et al.: "when models learn from data generated by their current
   policy, they exhibit substantially reduced catastrophic forgetting compared
   to off-policy alternatives," and their self-distillation scheme lets "a
   single model accumulate multiple skills over time without performance
   regression." V27's loop is already partially on-policy (fresh search
   targets each iteration), but the leaf/value/budget heads are trained by
   pure supervised regression against a two-shard replay window — the exact
   off-policy pattern the paper identifies. A lagged/EMA leaf evaluator or a
   self-distillation anchor on the value and leaf heads is the corpus-backed
   version of the investigation's recommendation 4.
3. **The LR schedule is an outlier versus precedent.** AlphaZero trained with
   a stepped decay (0.2 → 0.02 → 0.002 → 0.0002 over 700k batches); V27 ran
   47,486 AdamW steps at a constant 2e-4 — and doubled steps per iteration
   when self-play volume doubled, without rescaling. The audit's update-size
   experiment (halve LR or cap steps) is squarely supported.

What the corpus cannot adjudicate is the *locus* claim — that drift
concentrated in the leaf head (105.4% of its norm over iterations 4→30 versus
16% for the trunk) and that the deficit sits in the party-5to6 stratum
(0.4853, z ≈ −8). Those remain V27-internal measurements, and they are the
strongest evidence in this entire analysis, because they point at a 36K-param
module rather than at the 938K-param model.

### F4–F6 — not adjudicable from this corpus

F4 (the iteration-4 promotion is probably genuine) is a statistical statement
about this run; the corpus only confirms that the gate's form (z ≈ 2, one
look) matches AG0 convention. F5 (248 non-finishes scored as candidate losses,
worth −0.20pp per panel, flipping iteration 30's neutral-scored CI-low to
0.5003) matches chess-engine testing practice where crashes and losses are
distinguished, but no SPRT/fishtest document is indexed to cite. F6 (router
false negatives rising from iteration 23 under a forced-sample floor of 128)
is domain-specific instrumentation with no literature analogue in the corpus.
All three stand on the internal evidence presented in the second
investigation; nothing in the corpus weakens them.

## Capacity review: model size, layers, leaf evaluator, tree depth

### Where the 937,949 parameters actually are

Per-module counts from `policy-004.pt`:

| Module | Params | Share | Role |
| --- | ---: | ---: | --- |
| trunk encoder (4 layers, d=128, FFN 512) | 793,088 | 84.6% | shared representation |
| trunk embeddings/projections | 88,960 | 9.5% | semantic-entity tokens |
| distilled leaf head (492→64→64→1 MLP) | 35,777 | 3.8% | **every beyond-horizon value in search** |
| value head | 16,641 | 1.8% | root/tree value targets |
| policy heads | 3,354 | 0.4% | search priors |
| budget head | 129 | 0.0% | adaptive router |

The load-bearing fact: native CFR+ search evaluates all beyond-horizon leaves
through the 36K-parameter raw-feature MLP (`joint_search.py`,
`_pooled_leaf_values`), not through the transformer. The module carrying the
most decision-relevant signal per parameter is the smallest trainable unit in
the system, it is where post-promotion drift concentrated (105.4% of norm),
and its weakness is where the strength deficit is measured (party-5to6, the
longest-horizon stratum, 0.4853).

### The underfitting evidence

Three signals say the current network is capacity- or optimization-limited on
its own targets, not data-limited:

- **Policy KL floor.** Held-out KL after training plateaued at 0.9312 (mean of
  iterations 26–30) against a mean search-target entropy of 0.1369. The
  network's cross-entropy sits ~6.8× above the targets' intrinsic entropy
  floor, and 25 iterations of continued training recovered only 0.10 nats
  (1.0324 → 0.9312). Top-action agreement moved 0.3932 → 0.4055 over the same
  span. The model cannot represent the search's mixed strategies much better
  than it did at iteration 5.
- **Gradient interference in a shared trunk.** Policy/value trunk gradients
  are near-orthogonal (mean cosine 0.0096; raw value/policy norm ratio 3–5.6,
  ~1.00 after loss weighting). Five objectives (policy, value, leaf, leaf
  distillation, budget) time-share 793K trunk parameters with essentially
  uncorrelated update directions.
- **Returns per step collapsed.** Per-iteration held-out KL improvement
  decayed 135× from the first post-promotion iterations to the last five.

Kaplan et al. describe exactly this regime: when loss stops improving with
more steps at fixed N, "performance depends strongly on scale, weakly on model
shape," and larger models are more sample-efficient — they reach a given loss
in fewer optimizer steps and on fewer examples. Chinchilla adjusts the
allocation (parameters and data should scale in equal proportion) but not the
direction. Both are offline single-epoch language-model results, so they
transfer directionally, not numerically; the direction is: at a plateau like
this, add parameters, and widen the data window as you do.

### The throughput headroom

From the [GPU root-cause analysis](gpu-utilization-root-cause.md): neural
inference is **11.7%** of search wall time (Python RM+/frontier coordination
52.6%, native mechanics 35.7%); production SM utilization is 9.8–25%; a
standalone batch-256 run of the full joint model reaches only 56–61% SM at
~139,000 rows/s; VRAM sits at 4.0 of 12.3 GiB. Direct quote: "A
937,949-parameter, 32-token transformer does not contain enough arithmetic per
launch to sustain 80% on this GPU with one stream." The V26 Rust CFR+ work has
since shrunk the Python share, which raises inference's *relative* share — but
the absolute headroom stands: the GPU can absorb a several-fold larger model
at far less than proportional wall-clock cost.

Rough bounds, treating the current inference share as 12–20% of wall and GPU
throughput headroom as ~2× at production batch sizes:

| Trunk change | Params | FLOPs ×current | Est. wall-clock cost |
| --- | ---: | ---: | --- |
| Tier A: d_model 192, 6 layers, FFN 768 | ≈2.9M (3.1×) | ≈3.1× | +7% to +20% |
| Tier B: d_model 256, 6 layers, FFN 1024 | ≈5.1M (5.5×) | ≈5.5× | +25% to +45% |

One VRAM caveat: the persistent evaluation pool peaked at 9,167 MiB with 12
workers on the current model. Weights are negligible but activations scale
with d_model; the 12-worker configuration must be revalidated at Tier B and
may need to drop to 10.

### What a bigger model will and will not do

It should be said plainly: **capacity growth attacks the learning plateau, not
the promotion drought.** V27 already proved that better target-fitting does
not automatically convert to paired wins — the iteration-30 shadow beat the
deployed model on all five supervised diagnostics and still scored ~0.51. The
gate is power-limited (F2) and the regime is compressed (F1); those are fixed
by evaluation design, not parameters. The capacity case is about raising the
learner's per-iteration strength gain (+0.047pp/iter today) so there is more
signal for any gate to find. Luo et al. add the second caution: continual
churn gets *worse*, not better, with scale in their range, so churn mitigation
(EMA/lagged leaf, self-distillation anchor) must ship with any scale-up.

### Tree depth: do not increase it

The corpus and the repo's own measurements agree here:

- At the production budget (depth 4, tree_expansion_budget 320), the
  [tree-search performance study](variable-party-tree-search-performance.md)
  measured **mean reached depth 2.63** and only 25% of roots converged. The
  tree does not exhaust its current depth allowance; raising the cap to 5 or 6
  changes nothing except spreading the same 320 transitions thinner.
- The [production search-quality review](production-simultaneous-mcts-quality-review.md)
  explicitly rejects this move: "Blindly increasing depth or completing every
  deeper matrix: both consume the same constrained transition budget. They
  need paired equal-wall-clock strength evidence before becoming a production
  default."
- Budget, not depth, is the sensitive control: budget 192 disagreed with the
  budget-320 argmax on 25% of side decisions ("reducing budget changes the
  teacher"). Post-V26, native CFR+ solves cost 0.259–0.304 ms/matrix (57.8×
  faster), so a *budget* increase (tree_expansion_budget 320 → 448/512) is now
  cheap on the solver side and is the correct experiment if search investment
  is desired — measured by converged-root rate and mean reached depth, gated
  on paired strength.
- The highest-leverage "deeper search" is not a deeper tree at all: it is
  better values at the existing horizon. Every leaf beyond depth 4 is priced
  by the 36K-param MLP, AlphaZero's argument that MCTS "averages over
  approximation errors" cuts both ways — averaging bad leaf values still
  yields bad backups — and the measured deficit (party-5to6) is precisely the
  stratum with the most game beyond the horizon.

### Recommended configuration changes

In priority order:

1. **Grow the distilled leaf evaluator first.** 492→256→128→1 (≈159K params,
   4.5× current) or add a second hidden block. Cheapest change in the system,
   targeted at the measured deficit (party-5to6) and the measured churn locus
   (leaf head), and it leaves the native-search cost model intact — 159K
   params is still a trivially small MLP. Pair with a lagged/EMA copy for
   search while the live head trains (F3 mitigation, Shenfeld-supported).
2. **Trunk Tier A** (d_model 192, 6 layers, FFN 768, heads 8; ≈2.9M total)
   with two mandatory riders: a stepped or cosine LR decay (AlphaZero
   precedent; V27's constant 2e-4 is the outlier) and a replay window widened
   from 2 to 3–4 shards (Chinchilla direction: scale data with parameters;
   also lowers churn by averaging over more collection policies). Kaplan's
   shape-insensitivity means the exact split between depth and width is not
   worth agonizing over; 6 layers at d=192 keeps token count and head
   dimension sane.
3. **Trunk Tier B** (d_model 256, 6 layers, FFN 1024; ≈5.1M) only if Tier A
   moves the per-iteration strength trend and inference share stays under
   ~35% of wall time.
4. **Search budget probe, not depth**: tree_expansion_budget 320 → 448 at
   fixed depth 4, gated on paired strength at equal wall-clock.
5. **Do not change**: search depth (4), episode budget structure, the
   confidence gate's bar. Evaluation-power fixes from the second investigation
   (pooled/group-sequential evidence, neutral scoring of non-finishes,
   reduced-search arena tier) remain the path to reopening promotions and are
   orthogonal to all of the above.

A note on expectations from the scaling literature: Kaplan's α_N ≈ 0.076
implies a 3× parameter increase buys roughly an 8% reduction in achievable
loss — meaningful but not transformative on supervised metrics. The bet is not
that Tier A slashes KL; it is that (a) a 4.5× leaf evaluator materially
improves beyond-horizon values where the strength deficit actually lives, and
(b) relieving five-way gradient contention over 793K shared parameters raises
the +0.047pp/iter strength slope. Both are cheap to test and each has a
pre-registered kill criterion below.

## Recommended experiment order

| # | Experiment | Change | Success measure | Abort criterion |
| --- | --- | --- | --- | --- |
| E1 | Leaf capacity + stability | leaf MLP 36K→159K, EMA/lagged copy for search | party-5to6 stratum ≥ 0.50; post-promotion dip < 1pp | leaf MSE or party-5to6 worse after 6 iterations |
| E2 | Evaluation power (from second investigation) | pooled group-sequential evidence, neutral non-finish scoring, reduced-search arena | promotion cadence matches pooled-trend prediction | — (measurement change, no strength risk) |
| E3 | Trunk Tier A + LR decay + wider replay | d192/6L/FFN768, stepped LR, 3–4 shard window | strength slope > +0.10pp/iter over 10 iterations | wall-clock/iteration +>25% or slope unchanged |
| E4 | Search budget probe | tree_expansion_budget 320→448, depth fixed at 4 | paired strength gain at equal wall-clock | converged-rate gain without strength gain |

E1 and E2 are independent and can run in the same lineage; E3 depends on
neither but should follow E1 so leaf and trunk effects are attributable; E4 is
opportunistic after the V26 solver speedups.

## Corpus gaps worth filling

Adding these to docbert would let a future audit adjudicate what this one
could not:

1. **Jones 2021, "Scaling Scaling Laws with Board Games"** — the single most
   relevant missing paper: measures the compute trade-off between bigger
   models and more MCTS simulations in an AlphaZero loop on Hex; would turn
   the Tier A/B versus budget-probe decision from judgment into arithmetic.
2. **SPRT / sequential testing** (Wald; fishtest methodology) — would ground
   F5 scoring policy and the E2 group-sequential design.
3. **RL plasticity line** (Nikishin primacy bias; Lyle capacity loss;
   Sokar/ReDo dormant neurons) — would adjudicate whether the KL floor is
   capacity or lost plasticity; the distinction changes whether E3 helps.
4. **MuZero** — reanalyze/fresh-target machinery relevant to replay-window
   design.
5. **AlphaStar / OpenAI Five** — league training and model surgery: the
   established alternatives to single-incumbent gating at scale.

## Conclusions

1. The literature confirms the two load-bearing findings: evaluation
   compression under mutual strong search (F1; AlphaZero's draw-compression
   footnote is the same mechanism) and the underpowered-gate diagnosis (F2;
   AlphaGo Zero's own gate had a ~5pp MDE, and AlphaZero abandoned per-update
   gating rather than weaken it). Nothing in the corpus refutes any finding;
   F4–F6 simply cannot be adjudicated from this corpus and stand on internal
   evidence.
2. Model capacity should grow, in a specific order: the 36K-param distilled
   leaf evaluator first (it prices every beyond-horizon leaf, it is where
   churn concentrated, and its stratum carries the measured deficit), then the
   trunk to ≈2.9M params with LR decay and a wider replay window. The GPU has
   the headroom: inference is ~12% of wall time at 10–25% SM.
3. Tree depth should not increase: the tree already fails to exhaust depth 4
   (mean reached depth 2.63, 25% converged), and the repo's own quality review
   rejects blind depth increases. If search gets more resources, they go to
   transition budget, and the case is weaker than the leaf-evaluator case.
4. No amount of capacity reopens promotions by itself: the drought is an
   evaluation-power problem. E2 (pooled evidence, neutral scoring) remains the
   gating fix; capacity raises the slope that pooled evidence then detects.
