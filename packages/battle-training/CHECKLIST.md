# Full training-pipeline checklist

This checklist is an implementation ledger, not a statement of cartridge
parity. Checked rows have executable artifacts in this repository. Unchecked
rows remain required before the corresponding profile can be called complete.

## M0 — deterministic restricted link environment

- [x] Keep mechanics and team generation inside the native Lean worker.
- [x] Use a versioned production entropy expander instead of `seedFrom`.
- [x] Isolate generator, battle, player-policy, and enemy-policy streams.
- [x] Expose stable link action IDs for all emitted restricted actions.
- [x] Emit side-canonical policy records without future RNG bytes.
- [x] Preserve exact stop labels; train only from witnessed `finished` results.
- [x] Emit deterministic native state fingerprints and transcript coordinates.
- [x] Support policy control from either cartridge side.
- [x] Reproduce a shard byte for byte from its seed and checkpoint.
- [ ] Normalize every full-engine one-side and nested decision request.
- [ ] Define a mechanics-complete full-party tensor schema.
- [x] Add immutable pause/branch handles for the restricted native search server.
- [ ] Execute the restricted synchronized profile through `Full.Link.Pair`.
- [ ] Reproduce stock setup rejection, clock roles, and leading-zero mismatch in
      paired episodes.

## M1 — immutable data and deterministic baseline arena

- [x] Write immutable JSONL replay shards.
- [x] Hash each shard and checkpoint with SHA-256.
- [x] Record profile, schema, entropy, seed, budget, side, and policy identity.
- [x] Train and evaluate an external checkpoint end to end.
- [x] Evaluate the policy from both player and enemy perspectives.
- [x] Retain nonterminal stop counts instead of fabricating labels.
- [x] Verify generated artifacts and deterministic shard replay.
- [ ] Add held-out generated-team suites shared across checkpoints.
- [ ] Add paired-seed side-swapped confidence intervals.
- [ ] Add historical-checkpoint payoff matrices and fixed baselines.
- [ ] Add a versioned binary shard format after JSONL stabilizes.

## M2 — simultaneous search

- [ ] Add native state-branch benchmarks independent of episode throughput.
- [ ] Evaluate every legal joint action at shallow roots.
- [ ] Add regret-matching simultaneous MCTS.
- [x] Add sampled stochastic Exp3 simultaneous MCTS for the restricted profile.
- [ ] Keep opponent-sampled PUCT only as a named best-response baseline.
- [x] Implement `fresh-root-v1` without access to episode future RNG.
- [ ] Report exploitability/regret proxies on small exact games.

## M3 — batched policy/value learning

- [x] Freeze the restricted 100-field side-canonical tensor and action mask.
- [x] Train a byte/position-embedding transformer outside Lean.
- [ ] Run a multi-worker batched inference service outside Lean.
- [ ] Add bounded worker queues and inference timeouts.
- [x] Train policy and terminal value heads from MCTS/terminal targets.
- [x] Publish immutable model, optimizer, schema, and SHA-256 checkpoints.
- [ ] Resume bit-for-bit from a checkpoint and replay ledger.
- [ ] Compare network-only, PUCT, regret-MCTS, and Exp3-MCTS policies.

## M4 — full-party link battles

- [ ] Normalize forced replacement as a one-side request.
- [ ] Normalize Mimic, learning, evolution, and other nested protocols.
- [ ] Support every legal move/switch/no-action/Struggle/run wire action.
- [ ] Keep items unavailable in the stock link profile.
- [ ] Promote only episodes with complete terminal provenance.
- [ ] Audit synchronized rollouts against both `Full.Link.Pair` perspectives.
- [ ] Classify and retain known desynchronizations.

## M5 — population and evaluation

- [x] Mix mirror self-play with a hash-identified fixed-checkpoint opponent.
- [ ] Sample latest, historical, exploiter, and multi-baseline opponents.
- [ ] Retain held-out teams and seeds outside actor sampling.
- [ ] Produce checkpoint payoff matrices and Nash-mixture estimates.
- [ ] Gate promotion on paired evaluation with confidence intervals.
- [ ] Detect policy cycling and catastrophic forgetting.
- [ ] Keep team generation outside battle-control policy training.

## M6 — emulator deployment

- [ ] Define `full-link-paired-player-v1` observable histories.
- [ ] Add hidden-team priors, recurrent state, and leakage tests.
- [ ] Implement the stock serial party/RNG/action exchange peer.
- [ ] Randomize and record internal/external clock roles.
- [ ] Drive a stock-ROM emulator without changing `wLinkState`.
- [ ] Replay emulator traces through the paired Lean model.
- [ ] Hash-gate the canonical or explicitly patched ROM profile.
- [ ] Keep ROM/processor differential execution out of the training hot path.

## Completion rule

“End-to-end training works” currently means the restricted transformer can
collect Lean-owned MCTS trajectories, train policy/value heads on GPU or CPU,
evaluate a side-swapped checkpoint, and reproduce its first search shard.
“Deployable Pokémon agent” still means all relevant M0–M6 rows for
`full-link-paired-player-v1` are checked and their quality gates pass.
