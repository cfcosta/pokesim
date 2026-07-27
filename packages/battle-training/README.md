# battle-training

`battle-training` is the external actor–learner and evaluation project for the
verified Lean battle model. Lean owns team generation and mechanics. This
project owns immutable replay shards, policy checkpoints, learning, evaluation,
and reproducibility checks.

The first executable profile is `ordinary-link-1v1-perfect-v1`: a restricted
one-Pokémon link battle used to prove the pipeline works end to end before
full-party search and neural inference are introduced.

## End-to-end smoke training

From the repository root:

```sh
nix develop -c python -m unittest discover -s packages/battle-training/tests
nix develop -c python packages/battle-training/train.py smoke \
  --output artifacts/training/smoke
nix develop -c python packages/battle-training/train.py verify \
  artifacts/training/smoke
```

The smoke command:

1. builds the native Lean worker;
2. evaluates an untrained checkpoint;
3. collects deterministic player- and enemy-side replay shards;
4. updates a terminal-return move-value policy;
5. evaluates each immutable checkpoint;
6. writes SHA-256 manifests; and
7. regenerates one shard and requires byte-for-byte replay equality.

This is deliberately a small learner, not the final Pokémon agent. Its purpose
is to exercise the real mechanics-to-checkpoint-to-evaluation loop without
introducing a second battle simulator.

## Boundaries

- The worker executes `Battle.RL.Environment`; Python never resolves a turn.
- Future episode RNG bytes are absent from transition records and policy input.
- Generator, battle, player-policy, and enemy-policy entropy use separate,
  versioned counter-derived streams.
- Only `finished` episodes produce terminal learning labels.
- `truncated`, blocked, invalid, RNG-stuck, and division-freeze episodes remain
  explicit and are excluded from updates.
- A checkpoint is deployable only for the exact profile and schema recorded in
  its manifest.
- This restricted synchronized profile is not yet the paired-cartridge emulator
  deployment profile and is not a claim of ROM equivalence.

See [`CHECKLIST.md`](CHECKLIST.md) for the path from this smoke loop to the full
actor–learner system.
