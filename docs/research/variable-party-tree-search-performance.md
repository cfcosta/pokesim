# Variable-party tree-search performance

<!-- mode: research -->

## Result

The production 192–320-transition tree is the dominant self-play cost. On the
RTX 3080 Ti, a representative 36-battle variable-party collection completed at
2.62 real decisions/s with the production tree, compared with 37.92 decisions/s
for a complete-root depth-one teacher. The production tree was **14.5× slower
per real decision** and increased the extrapolated 500-battle collection time
from 4.65 to 48.82 minutes.

This is not primarily RM+ arithmetic. Deeper search is root-local and fragments
neural evaluation into hundreds of small GPU calls. In the production
microbenchmark, network evaluation consumed 66.8% of wall time, native mechanics
and protocol work consumed 24.7%, and Python—including RM+—consumed 8.5%.

## Setup

| Item | Value |
|---|---|
| GPU | NVIDIA GeForce RTX 3080 Ti, 12,288 MiB |
| Driver | 595.45.04 |
| PyTorch | 2.13.0+cu130 |
| Model | v4 BF16, 492 fields, 940,430 parameters |
| Checkpoint SHA-256 | `88d6fb2621e5542e6c6db0bd7cbf4edbc042905f6fbc5abac5f1f3451d7949f1` |
| Root sample | Eight roots: equal sizes 1–6 plus 1v6 and 6v1 |
| Collection sample | 36 battles covering every ordered 1-to-6 size pair |
| Actor group | Up to 16 live roots |
| Search | Complete root, two deeper rotations, RM+ 16 iterations/update, fresh chance 0.10 |
| Artifact | `/tmp/variable-party-tree-benchmark-36.json` |

Reproduction command:

```sh
nix develop -c python tools/benchmark-variable-party-tree.py \
  CHECKPOINT.pt \
  --output /tmp/variable-party-tree-benchmark.json \
  --roots 8 \
  --collection-episodes 36
```

The benchmark is a performance and target-stability probe, not a gameplay
quality result.

## Search-call profile

| Search tier | ms/root | Transitions/root | Tree nodes | Mean reached depth | Converged | Network | Native | Python |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Complete root | 32.49 | 42.38 | 1.00 | 0.00 | 0.0% | 53.5% | 43.5% | 3.0% |
| Depth 4, budget 96 | 132.25 | 96.00 | 6.00 | 1.75 | 0.0% | 67.2% | 25.1% | 7.7% |
| Depth 4, budget 192 | 292.62 | 192.00 | 14.63 | 2.50 | 12.5% | 67.2% | 22.1% | 10.7% |
| Depth 4, budget 320 | 411.20 | 294.88 | 22.38 | 2.63 | 25.0% | 66.8% | 24.7% | 8.5% |

Depth diagnostics number the root as zero, so configured depth four requires a
reported maximum depth of three. Even at budget 320, the mean reached depth was
2.63 and only two of eight roots met the adaptive convergence condition. The
adaptive 192–320 profile therefore usually spends close to its maximum budget.

A network-only side-swapped decision over 16 roots took 8.95 ms at batch 32, or
0.56 ms/root. Complete root coverage was about 58× slower than network-only
action selection; the production tree was about 734× slower. Complete root
coverage is mandatory for the current teacher, so 32.49 ms/root is the relevant
lower bound unless mechanics transitions or the protocol are changed.

## Fragmented inference

The production eight-root profile made 297 neural calls for 4,494 examples:

| Batch class | Calls | Examples | Network time |
|---|---:|---:|---:|
| Exactly 2 | 133 | 266 | 37.8% |
| At most 16 | 179 | 686 | 51.3% |
| All calls | 297 | 4,494 | 100% |

Calls of batch two processed only 5.9% of examples but consumed 37.8% of neural
wall time. Calls at or below batch 16 processed 15.3% of examples but consumed
51.3% of neural time. These are mostly deeper leaf and fresh-chance evaluations.
The complete root is already batched across live roots; deeper progressive
frontiers are not.

The same production profile issued 338 native requests. Of these, 181 were
single-transition requests caused by fresh chance outcomes. Scalar native calls
accounted for only 0.077 seconds in this sample, so batching neural frontiers is
the larger immediate opportunity. Native execution and JSON feature transport
still impose a roughly 25% floor.

## End-to-end collection

| Search tier | Battles/s | Decisions/s | Mean decisions | Mean chance outcomes | Converged | Estimated 500 battles |
|---|---:|---:|---:|---:|---:|---:|
| Complete root | 1.794 | 37.92 | 21.14 | 29.48 | 0.0% | 4.65 min |
| Budget 96 | 0.349 | 7.34 | 21.00 | 95.96 | 2.6% | 23.86 min |
| Budget 192 | 0.174 | 4.04 | 23.31 | 191.99 | 10.6% | 48.02 min |
| Budget 320 | 0.171 | 2.62 | 15.33 | 300.84 | 21.1% | 48.82 min |

The 36-battle samples recorded one nonfinish for complete-root, two for budgets
96 and 192, and one for budget 320. Nonfinishes remained unlabeled. Battle-rate
comparisons are affected by policy-dependent battle length: budget 320 was
substantially slower per decision than budget 192 but chose shorter battles in
this sample. Decision throughput is the cleaner mechanics/search measurement.

At the measured production rate, 30 iterations require about 24.4 hours of
collection alone. Training, 1,024-game promotion, probes, the campaign suite,
and final evaluation are additional. This estimate is indicative; team draws,
model changes, and search policies alter battle length. The earlier all-6v6 v3
iteration took about 76 minutes to collect 500 battles, consistent with larger
parties increasing the same bottleneck.

## Target stability

Lower budgets are not drop-in performance substitutions. Against budget 320 on
eight identical roots and search seeds:

| Teacher | Mean two-side policy L1 | Argmax disagreement |
|---|---:|---:|
| Complete root | 1.152 | 50.0% |
| Budget 96 | 0.654 | 31.3% |
| Budget 192 | 0.451 | 25.0% |
| Budget 320 | 0 | 0% |

Budget 320's measured exploitability proxy was 0.0595, versus 0.0508 at budget
192 and 0.0497 at budget 96. This is not evidence that smaller budgets are
better: each tier estimates a different partially sampled payoff tree, so the
proxies are noisy and not directly ordered. It does show that extra budget did
not produce a monotonic improvement in this diagnostic. Teacher quality still
requires equal-budget gameplay and held-out tests.

## Conclusions

1. **The concern is confirmed.** Searching every move is not itself the main
   problem; spending nearly 320 transitions in a root-local depth-four tree at
   every move is. It cuts decision throughput by about 14.5× relative to a
   complete-root target.
2. **The GPU is launch-bound at depth.** Cross-root batching works for complete
   root matrices, but deeper search produces hundreds of batches too small to
   use the accelerator efficiently.
3. **Adaptive stopping rarely saves enough.** Most roots approach the maximum
   transition budget, and the average tree does not fully reach configured
   depth four.
4. **RM+ is not the leading optimization target.** Removing all Python overhead
   could save less than 10% in this profile.
5. **Reducing budget changes the teacher.** Budget 192 still disagreed with the
   budget-320 argmax on 25% of side decisions. A speed change needs strength and
   calibration evidence, not only throughput.

## Recommended order

1. Implement a cross-root deeper-frontier scheduler and bounded shared inference
   queue. Batch leaf evaluations before changing search semantics. Track queue
   latency, effective batch size, transitions/s, and policy agreement.
2. Evaluate tiered all-move search: retain a complete root at every decision,
   while assigning the full 320-transition tree to a randomized fraction of
   roots. Keep exploratory behavior separate from cleaned policy targets.
3. Compare 96, 192, 320, and tiered teachers at equal wall-clock and transition
   budgets against raw policy, zero-value search, and learned-value search.
4. Do not return to every-tenth policy supervision. If throughput must be
   recovered before frontier batching lands, prefer a complete-root target on
   every move plus randomized deep-search allocation.
5. After frontier batching, profile a compact binary or leaf-only native
   response. It cannot recover the 67% neural share, but it can reduce the
   remaining native/JSON floor.
