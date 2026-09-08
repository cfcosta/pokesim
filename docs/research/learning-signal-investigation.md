# Why lower training loss has not reliably produced stronger play

<!-- mode: research -->

Investigation date: 2026-09-08. This is the pre-v33 audit, preserved with its
original source hashes and measurements. Its descriptions of executable
behavior refer to that snapshot. The subsequent fixes and new measurements are
documented in [v33 validation](v33-search-validation.md) and the
[current controller design](../explanation/search-assisted-controller.md).

The strongest current concern is the policy-improvement target: the learner
imitates a search controller whose objective and evaluator differ from the
terminal-win value it learns. There are also two reproducible diagnostic bugs.
These findings justify controlled ablations before another full training run;
they do not establish which mechanism dominated the latest missing runs.

## Evidence available

The training artifact folders in this checkout are empty. The run directories
named in the V27 and V28 audits are no longer present under `/tmp`. The adjacent
`v32-4k60-fresh-r2-training-runtime` checkout has the same
`transformer_pipeline.py` as this checkout, but no run metrics were found there.
The location of the latest checkpoints and metrics was requested during this
investigation. No trained checkpoint was evaluated or training service restarted.

New measurements use the actual Python functions and the existing Lean search
binary. Reproduce them from the development environment with:

```sh
python tools/audit-learning-signal.py \
  --output output/local-learning-signal-audit.json --native-roots 8
```

Running this program on v33 measures the corrected functions; it does not
recreate the old findings. Preserve the original JSON when comparing revisions.

The [audit program](../../tools/audit-learning-signal.py) writes input/source
hashes, synthetic reproductions, and native sampling results to
[the JSON report](../../output/learning-signal-audit.json). Synthetic examples
isolate mechanisms; they are not observations of trained Pokémon policies.

## 1. Search can prefer a worse action even with a correct win-value estimate

`transformer_pipeline.py` assigns each completed episode's terminal return to
every pending value example (around line 2144). `_train_network` fits both the
main value and distilled leaf to that return; the distilled value also fits the
detached main value. Neither learns a potential-subtracted residual.

But `joint_search.py::_shaped_leaf_value` (around line 1878) scores a nonterminal
leaf as:

```text
clip(V(leaf) + tactical_potential(leaf) - tactical_potential(root), -1, 1)
```

The potential includes HP, living members, status, PP, and stat stages. There is
no configurable shaping weight or decay to zero in this path. Terminal leaves
instead return their raw outcome, without the root subtraction.

The executable reproduction supplies correct continuation values:

| Action | True continuation value | Potential change | Search score |
| --- | ---: | ---: | ---: |
| Better long-term outcome | 0.60 | -0.20 | 0.40 |
| Worse long-term outcome | 0.40 | +0.20 | 0.60 |

Search reverses the ranking, and the policy learns to imitate that reversed
preference. Better value prediction alone cannot eliminate this bias. Clipping
can additionally erase distinctions near the endpoints.

This is not the policy-invariance guarantee of ordinary potential-based reward
shaping. In the undiscounted case, consistently shaped rewards require the
continuation value to be transformed as `V'(s) = V(s) - Phi(s)`. Then the leaf
potential cancels. Adding it to an untransformed continuation estimate leaves
an action-dependent term. See [Ng, Harada, and Russell's original
paper](https://ai.stanford.edu/~ang/papers/shaping-icml99.pdf).

**Confirmed:** the objective mismatch and rank reversal. **Not measured:** its
frequency or effect on win rate in the latest trained checkpoint. A short-term
heuristic may help bootstrap a poor value network; that does not validate keeping
its full weight after the network improves.

## 2. Changing opponent type changes the candidate's search evaluator

`_pooled_leaf_values` averages the candidate's value with the negated opponent's
value. `_HeuristicNetwork.evaluate_leaf` always returns zero. The same candidate
leaf output of `0.8` therefore becomes:

| Opponent | Value supplied to search |
| --- | ---: |
| Same network in mirror self-play | 0.80 |
| Fixed heuristic | 0.40 |

The audit calls the real pooled evaluator to reproduce this. Tactical shaping
is not halved, so its influence relative to learned value doubles against
heuristics. At default opponent scheduling, approximately 33.5% of collection
episodes are heuristic games.

There is another change: `_open_subgames` uses distilled policy priors only if
both controllers support them. The heuristic advertises no distilled policy,
so those games use the candidate's full encoder for interior priors. Model versus
model games use the small distilled policy instead. Search then replaces the
heuristic's executed action with its actual heuristic policy, while the saved
policy targets remain the joint solver's strategies.

**Confirmed:** teacher and evaluator behavior depend on opponent type.
**Hypothesis:** this inconsistency weakens transfer from collection losses to
deployment. Opponent diversity is useful, but that does not require blending an
uninformed zero estimate into the candidate's own value.

## 3. The expensive solve is operating on very little chance evidence

Current production CLI defaults, read through the parser:

- Two chance samples per root joint action.
- One chance sample per interior joint action.
- Depth two, with only the top three prior-ranked actions per side below root.
- A 2,048-iteration matrix solve.
- Split-half diagnostics enabled, with policy reliability floor `1.0`.

The solver iterations refine strategies against the sampled payoff matrix;
they do not add Pokémon chance samples. A low solver exploitability cannot by
itself establish that this matrix estimates the real game accurately. A floor
of `1.0` gives a fully disagreeing target the same training weight as an agreeing
target.

Moreover, `_root_equilibrium` does not use split halves just for diagnostics.
It averages the mean-matrix policy with each half's policy. With two root
samples, each half represents one chance world. A reproduction at the default
anchor temperature shows:

| Quantity | Mean-matrix solve | Published target |
| --- | ---: | ---: |
| Probability on the better mean-payoff action | 99.33% | 66.44% |
| Expected payoff on the mean matrix | 0.19933 | 0.16644 |

This is a deliberate bagging heuristic in the code, not a solver arithmetic
failure. It may reduce variance on some distributions, but its playing-strength
benefit needs evidence; it can move away from the solution to the available
expected-payoff estimate.

Native check: eight level-100 6v6 opening states, four independent two-world
searches each, compared with a separately sampled 64-world reference. Frozen
aggressive priors and zero learned value isolate chance and tactical shaping;
depth one keeps this check bounded. Mean policy total-variation distance was
`0.07139`; the top action differed in **2 of 32** comparisons. Mean split-half
distance was `0.10044`. Thus this sample does **not** support claiming chance
noise makes every target unusable. It also does not measure trained-model
strength, depth-two error, or a ground-truth payoff matrix.

## 4. The reported learning diagnostics contain two bugs

**The held-out split separates paired legs.** `_load_partitioned_examples`
selects held-out rows by episode modulo ten. Adjacent episodes are the two legs
of one reset pair. Every held-out episode therefore has its sibling assigned to
training under the paired schedule. In the reproduction, both held-out pair IDs
also appear in training. Same teams, reset, opponent, and often highly related
states cross the boundary. This does not imply every row is identical, but the
metric is not a test on unseen reset pairs. Frontier/hard-team replay also needs
provenance grouping if stronger independence is claimed.

**Perfect policy agreement reports 50%.** `_heldout_diagnostics` adds two boolean
match tensors before summing. PyTorch boolean addition remains boolean, so two
correct heads contribute one hit while the denominator counts two. A perfect
two-head policy reports `0.5`. The numerator also uses boolean weights while the
denominator uses real weights: with weights `0.25`, perfect agreement reports
`2.0`, or 200%. Both outputs were reproduced through the production function.

These bugs affect interpretation, not the optimizer's cross-entropy calculation
or the separate paired battle arena. They cannot alone explain a real win-rate
plateau, and they make historical agreement numbers unsuitable as literal
per-head accuracy.

## 5. The newest checkpoint can still deploy the old bot

`save_network` writes the incumbent into `model` and the continuing learner into
`learner_model`. `load_network` loads `model`. Rejected updates preserve learner
and optimizer state but leave ordinary loading pointed at the previous incumbent.
This is intentional deployment gating. Checkpoint filenames and whole-file hashes
can change without the deployed tensor state changing.

The [V27 audit](v27-thirty-iteration-promotion-audit.md) previously recorded that
iteration 30 still deployed iteration 4. Its historical comparison reported
policy KL improving from `1.0302` to `0.9101` and equal-battle value MSE from
`0.4842` to `0.3649`, without dependable strength improvement. The [follow-up
audit](v27-promotion-drought-second-investigation.md) reported a pooled score
of `0.4919` over iterations 5–30 against that incumbent, indicating regression
followed by recovery. These are preserved historical reports, not freshly
recomputed checkpoint measurements.

The [V28 distribution audit](v28-self-play-distribution-audit.md) reported that
a larger model also stalled. Its frozen-opponent and absent-exploration findings
must not be copied onto today's code: current defaults include six shadow
opponents, epsilon exploration, and Dirichlet noise. Their presence does not
prove they were enabled in a particular saved run configuration.

## What to do before another long run

1. Correct the diagnostic arithmetic and split by reset-pair provenance. Keep
   an independent fixed evaluation panel outside replay/frontier selection.
2. Recover the latest saved config, metrics, and both checkpoint tensor states.
   Plot actual incumbent and shadow strength separately, including network-only
   and search-assisted play. Determine which bot was actually tested by hand.
3. On the same checkpoint and frozen evaluation states, ablate search shaping
   at weights zero and one; separately compare full and distilled leaf
   evaluators, and candidate-owned versus opponent-averaged values. Measure
   win rate and action-value ranking, not just loss or throughput.
4. Compare mean-matrix-only targets against the current split-half mixture, and
   increase chance samples on a bounded panel. Keep solver iterations fixed so
   this measures the payoff estimate rather than arithmetic convergence.
5. Only after an improvement operator passes those checks, run a small training
   experiment that changes one mechanism. Confirm gains on a separate seed
   panel before paying for another long lineage.

The full transformer may improve while the small leaf network used at most
search nodes remains the limiting evaluator. The code establishes that path;
only checkpoint ablations can establish it as the bottleneck. There is no
current evidence here that another capacity increase, lower promotion threshold,
or larger epoch count will solve the problem.
