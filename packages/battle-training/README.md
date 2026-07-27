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
3. periodically evaluates every legal root joint action with batched policy rollouts;
4. couples independent `fresh-root-v1` chance samples across joint actions for
   lower-variance payoff comparisons without reading the episode RNG suffix;
5. solves the sampled zero-sum payoff matrix with regret matching+ and records
   its mixed strategies alongside witnessed terminal values;
6. optimizes policy cross-entropy plus value MSE with AdamW;
7. publishes model and optimizer checkpoints;
8. runs a side-swapped final-versus-initial arena;
9. writes SHA-256 manifests; and
10. regenerates the first search shard byte for byte from checkpoint zero.

Default training searches every tenth real decision, uses one chance sample per
legal joint action at depth one, and lets network-policy rollouts choose from all
legal actions between searched decisions. This keeps six-member runs practical
without silently pruning switches. `transformer-train` defaults to a four-layer,
128-wide model under one million parameters:

```sh
nix develop -c python packages/battle-training/train.py transformer-train \
  --output artifacts/training/run-001 \
  --iterations 20 --episodes 500 --budget 256 \
  --chance-samples-per-joint 1 --search-depth 1 --search-every 10
```

Use `--device cpu`, `--device cuda`, or `--device auto`. The uv2nix development
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
field-position embedding. A learned CLS token attends over all 477
side-canonical full-party fields. The v2 tail adds canonical move descriptors,
current type-effectiveness values, and offensive/incoming matchup scores; this
keeps small networks from having to rediscover static ROM tables from terminal
labels. Two heads predict:

- logits for all 13 stable link action IDs; and
- a bounded terminal value in `[-1, 1]`.

Search and policy loss mask illegal actions. The search batches native
transitions and neural inference, estimates every legal root joint payoff, and
uses regret matching+ to produce one mixed target per side. A dense,
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
`batch` derives many such successors in one native request; `step ... episode
...` advances the real trajectory with its existing hidden RNG. Python cannot
mutate or resolve battle state itself. Neural leaves are evaluated in bounded
GPU batches within each root search.

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
- Root search now batches native stepping and inference, but there is not yet a
  multi-worker inference service that combines leaves from independent roots.
- Regret matching currently solves the exhaustively sampled root matrix; deeper
  actions are policy rollouts rather than regret-matched tree nodes.
- Forced replacement and Mimic are normalized; other profile-excluded nested
  protocols remain blocked before widening beyond stock link battle control.
- This training pipeline is theorem-backed model execution, not a proof of
  behavioral equivalence to the Pokémon Red battle ROM.

See [`CHECKLIST.md`](CHECKLIST.md) for the remaining path to full-party paired
link deployment.
