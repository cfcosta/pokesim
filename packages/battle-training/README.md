# battle-training

`battle-training` is the external actor–learner and evaluation project for the
verified Lean battle model. Lean owns team generation, immutable search states,
chance forks, and mechanics. Python owns the transformer, simultaneous MCTS,
replay shards, optimization, checkpoints, and evaluation.

The first executable profile is `ordinary-link-1v1-perfect-v1`: a restricted
one-Pokémon link battle used to validate the full AlphaZero-style loop before
normalizing every full-party decision protocol.

## Transformer + MCTS smoke training

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
3. runs stochastic simultaneous-move MCTS with Exp3 node selection;
4. forks hidden search chance through `fresh-root-v1` without reading the
   episode RNG suffix;
5. records MCTS visit distributions and witnessed terminal values;
6. optimizes policy cross-entropy plus value MSE with AdamW;
7. publishes model and optimizer checkpoints;
8. runs a side-swapped final-versus-initial arena;
9. writes SHA-256 manifests; and
10. regenerates the first MCTS shard byte for byte from checkpoint zero.

Default smoke settings use a small two-layer transformer and twelve simulations
per decision. `transformer-train` defaults to a four-layer, 128-wide model and a
larger search budget:

```sh
nix develop -c python packages/battle-training/train.py transformer-train \
  --output artifacts/training/run-001 \
  --iterations 20 --episodes 256 --simulations 96 --search-depth 8
```

Use `--device cpu`, `--device cuda`, or `--device auto`. The uv2nix development
environment is generated from `uv.lock`; on supported Linux hosts it includes
the CUDA PyTorch wheel and the NixOS runtime-library fixes required to use the
GPU.

A run can mix mirror self-play with a hash-recorded fixed checkpoint. For a
50/50 mixture, the candidate alternates cartridge sides in the fixed-opponent
battles, and only the candidate side contributes examples from those battles:

```sh
nix develop -c python packages/battle-training/train.py transformer-train \
  --output artifacts/training/fixed-opponent-run \
  --opponent-checkpoint artifacts/training/baseline.pt \
  --opponent-fraction 0.5
```

The pipeline copies the fixed checkpoint into the immutable run, records its
SHA-256 identity in every shard, evaluates the final candidate against both its
scratch initialization and the fixed opponent, and includes the opponent in
deterministic shard regeneration. AdamW state now persists across collection
iterations instead of being reset after every shard.

## Model

Each mechanics scalar is encoded as low- and high-byte embeddings plus a learned
field-position embedding. A learned CLS token attends over all 100
side-canonical state fields. Two heads predict:

- logits for the four restricted link move-slot actions; and
- a bounded terminal value in `[-1, 1]`.

MCTS masks illegal actions before inference. Search maintains independent Exp3
weights for both simultaneous players and samples semantic outcomes through the
native Lean server. Search-selection entropy, search-chance entropy, real battle
entropy, and team-generation entropy remain separate.

## Native boundary

`battleSearchServer` stores immutable `Battle.RL.Environment.State` values behind
integer handles. `step ... fresh ...` installs a named search chance fork;
`step ... episode ...` advances the real trajectory with its existing hidden
RNG. Python cannot mutate or resolve battle state itself.

The earlier terminal-return move table remains available as `tabular-smoke` and
`tabular-train`. It is a protocol baseline, not the intended learning system.

## Boundaries

- Only `finished` episodes produce value targets.
- Truncation and mechanics failures never receive fabricated terminal labels.
- The synchronized restricted profile is not yet the paired-cartridge emulator
  deployment profile.
- Exp3 MCTS is implemented, but inference is currently synchronous rather than a
  multi-worker batched service.
- Full parties remain blocked on normalized forced-switch and nested requests.
- This training pipeline is theorem-backed model execution, not a proof of
  behavioral equivalence to the Pokémon Red battle ROM.

See [`CHECKLIST.md`](CHECKLIST.md) for the remaining path to full-party paired
link deployment.
