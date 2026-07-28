# battle-training

`battle-training` is the external actor–learner and evaluation project for the
verified Lean battle model. Lean owns team generation, immutable search states,
chance forks, and mechanics. Python owns the transformer, simultaneous search,
replay shards, optimization, checkpoints, and evaluation.

The primary executable profile is `full-link-6v6-perfect-v1`. Every reset uses
two independently generated, progression-witnessed parties of exactly six.
Policies choose from the complete 13-action link dictionary: four moves, six
switch slots, typed no-action, Struggle, and the profile-disabled run slot.
Forced replacement and Mimic are normalized as one-side requests.

## Transformer + simultaneous-search smoke training

From the repository root:

```sh
nix develop -c python packages/battle-training/train.py transformer-smoke \
  --output artifacts/training/transformer-smoke

nix develop -c python packages/battle-training/train.py verify \
  artifacts/training/transformer-smoke
```

The smoke command performs the complete loop:

1. builds and starts the persistent Lean search server;
2. initializes a side-canonical transformer policy/value network;
3. periodically builds a persistent simultaneous tree with complete root coverage;
4. couples independent `fresh-root-v1` chance samples across joint actions for
   lower-variance payoff comparisons without reading the episode RNG suffix;
5. runs persistent regret matching+ at every expanded typed request and records
   average-strategy targets alongside witnessed terminal values;
6. optimizes policy cross-entropy plus value MSE with AdamW;
7. publishes model and optimizer checkpoints;
8. runs a side-swapped final-versus-initial arena;
9. writes SHA-256 manifests; and
10. regenerates the first search shard byte for byte from checkpoint zero.

Default training searches every real decision with an adaptive
192–320-transition matrix-valued simultaneous tree. It may stop after eight
stable average-strategy updates once the full depth has been reached. The root
evaluates every legal joint action; deeper nodes begin with two cyclic
joint-action rotations that cover every legal move and switch, then sample
additional pairs and fresh chance outcomes under persistent regret matching+.
Except for typed search fallbacks, every completed training decision therefore
carries an RM+ average-strategy policy target. `--search-every` remains available
for explicit sparse-search experiments, but it is not the production default.
This preserves complete action consideration without top-k pruning.
`transformer-train` is the production profile:
30 iterations of 500 training battles, or 15,000 independently reset random
6v6 battles. It uses depth-four simultaneous trees, the 938,638-parameter
four-layer, 128-wide model, BF16 autocast, two epochs per iteration, a
CUDA-safe batch size of 128, and a 1,024-game final arena. Parameters, gradients,
AdamW state, policy normalization, losses, and reductions remain FP32. The tree
uses up to 320 native transitions per searched root and was 1.31× slower than
disposable depth-four rollouts in a 24-root benchmark. The former every-tenth
profile had an approximately nine-hour strict-FP32 estimate and completed a
15-iteration BF16 run in under five hours. Searching every move creates roughly
ten times as many search roots; a complete all-move production run has not yet
established its wall-clock time:

```sh
nix develop -c python packages/battle-training/train.py transformer-train \
  --output artifacts/training/run-001
```

Strict-FP32 batch size 512 exceeded the card's 11.63 GiB capacity. Under BF16,
batch 128 peaked at 1.26 GiB and delivered 3.77× the strict-FP32 training
throughput. BF16 batch 512 fit at 4.76 GiB but was only 10.5% faster than BF16
batch 128, so 128 remains the production default.

Use `--device cpu`, `--device cuda`, or `--device auto`. BF16 is the default;
`--precision fp32` remains available for differential checks and older
checkpoints without precision metadata retain their original FP32 contract. The uv2nix development
environment is generated from `uv.lock`; on supported Linux hosts it includes
the CUDA PyTorch wheel and the NixOS runtime-library fixes required to use the
GPU.

A run can mix mirror self-play with one or more hash-recorded fixed checkpoints.
For a 50/50 mixture, fixed opponents are round-robined, the candidate alternates
cartridge sides, and only the candidate side contributes policy examples from
those battles:

```sh
nix develop -c python packages/battle-training/train.py transformer-train \
  --output artifacts/training/fixed-opponent-run \
  --opponent-checkpoint artifacts/training/baseline-a.pt \
  --opponent-checkpoint artifacts/training/baseline-b.pt \
  --opponent-fraction 0.5
```

The pipeline copies fixed checkpoints into the immutable run, anchors half of
default collection against the scratch initialization and a rolling historical
window, records opponent SHA-256 identities in every shard, and includes the
initial population in deterministic shard regeneration. Each production update
receives at least 1,024 held-out games against its incumbent, grouped into 512
same-reset pairs with model sides swapped across eight root seeds. Truncations
and semantic cycles score zero. Promotion requires a point score of at least 50%,
a paired 95% confidence lower bound of at least 50%, and passing separate
held-out type, status, and switch probes; inconclusive updates restore both model
and AdamW state. AdamW state otherwise persists across collection iterations.

## Model

Each mechanics scalar is encoded as low- and high-byte embeddings plus a learned
field-position embedding. A learned CLS token attends over all 478
side-canonical full-party fields. The v3 schema retains the move descriptors,
current type-effectiveness values, and offensive/incoming matchup scores from v2
and adds the pending Mimic continuation action; this
keeps small networks from having to rediscover static ROM tables from terminal
labels. Two heads predict:

- logits for all 13 stable link action IDs; and
- a bounded terminal value in `[-1, 1]`.

Encoder and head matrix operations run under BF16 autocast. Both head outputs
are immediately promoted to FP32 before masks, softmax, RM+ search, losses, or
reductions, and all trainable parameters and optimizer state stay FP32.

Search and policy loss mask illegal actions. Every expanded node retains an
empirical joint payoff matrix, cumulative RM+ regrets, average strategies,
explicit chance outcomes, and immutable child handles. The root matrix is
complete; progressive deeper matrices represent unvisited pairs with the neural
leaf prior while mandatory exploration gives every legal action initial support.
A dense,
antisymmetric HP/faint/status delta stabilizes one-step leaf estimates, and an
adaptive 10–30% aggregate switch cap applies only to voluntary-switch targets;
all six switch actions remain evaluated and retain nonzero support. Common
random numbers couple sampled chance seeds across actions only inside the estimator;
each action retains the required `fresh-root-v1` marginal distribution. The old
sequential Exp3 path and its replay compatibility have been removed.
Search-selection entropy, search-chance entropy, real battle entropy, and
team-generation entropy remain separate.

## Native boundary

`battleSearchServer` stores immutable `Battle.Full.Environment.State` values and
typed Mimic continuations behind integer handles. `step ... fresh ...` installs
a named search chance fork;
`batch` derives many such successors in one native request; `reset-append` and
`compact-many` retain and remap several live episode roots; `batch-episode`
advances several real trajectories with their existing hidden RNG. Python cannot
mutate or resolve battle state itself. Actors run in groups of 16. Root matrices,
root leaf inference, network-only decisions, and real episode transitions are
batched across compatible independent roots; deeper progressive simulations
remain root-local.

Arena directories contain Showdown-style `.log` replays plus aggregate metrics
for damage-move effectiveness relative to the best legal damaging move, status
success/block/waste counts, and voluntary-switch rate/completion/matchup
improvement. Production promotion rejects statistically inconclusive updates and
probe regressions. The expanded gate also rejects collection with more than 1%
horizon truncation or semantic divergence, below 98% completion, above 20%
voluntary switching, or mean length above 96 decisions; evaluation nonfinishes
are capped at 2%. These remain versioned diagnostics, not claims of strategic
optimality.

The earlier terminal-return move table remains available as `tabular-smoke` and
`tabular-train`. It is a restricted protocol baseline, not the intended learner.

## Boundaries

- Only `finished` episodes produce value targets.
- Horizon truncation, classified silent divergence, and mechanics timeouts never
  receive fabricated terminal labels.
- Every native request has a 15-second process-level timeout. Arena episodes
  restart with a fresh server after timeout and report `mechanics_timeouts`;
  collection timeouts kill the worker, write a failed iteration metric, and
  reject the run.
- Generated Mirror Move against a recorded Mirror Move is classified as
  `nested-mirror-move-cycle` silent divergence rather than consuming host CPU
  indefinitely.
- The synchronized full-party profile is still a hot-path quotient, not the
  paired-cartridge emulator deployment profile.
- Cross-root batching currently combines complete root matrices and unsearched
  policy decisions. Deeper progressive frontier expansion still runs one root at
  a time; batching that frontier is the remaining accelerator bottleneck.
- Deeper matrices use progressive joint sampling rather than exhaustive pair
  coverage. Artifacts report sampled-joint coverage separately from mandatory
  legal-action coverage.
- Forced replacement and Mimic are normalized; other profile-excluded nested
  protocols remain blocked before widening beyond stock link battle control.
- This training pipeline is theorem-backed model execution, not a proof of
  behavioral equivalence to the Pokémon Red battle ROM.

See [`CHECKLIST.md`](CHECKLIST.md) for the remaining path to full-party paired
link deployment.
