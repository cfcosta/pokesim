# Full training-pipeline checklist

This checklist is an implementation ledger, not a statement of cartridge
parity. Checked rows have executable artifacts in this repository. Unchecked
rows remain required before the corresponding profile can be called complete.

## M0 — deterministic full-party link environment

- [x] Keep mechanics and team generation inside the native Lean worker.
- [x] Use a versioned production entropy expander instead of `seedFrom`.
- [x] Isolate generator, battle, player-policy, and enemy-policy streams.
- [x] Expose stable link action IDs for all emitted full-party actions.
- [x] Emit side-canonical policy records without future RNG bytes.
- [x] Preserve exact stop labels; train only from witnessed `finished` results.
- [x] Emit deterministic native state fingerprints and transcript coordinates.
- [x] Support policy control from either cartridge side.
- [x] Reproduce a shard byte for byte from its seed and checkpoint.
- [ ] Normalize every full-engine one-side and nested decision request.
- [x] Define the audited 492-field variable-party perfect-information and tactical schema.
- [x] Add immutable pause/branch handles for the full-party native search server.
- [x] Batch independent fresh-chance branches in one native request.
- [ ] Execute the synchronized full-party profile through `Full.Link.Pair`.
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
- [x] Add held-out generated-team type/status/switch probes.
- [x] Add 1,024-game paired-seed side-swapped confidence intervals.
- [x] Add multi-checkpoint fixed baselines and pairwise arena reports.
- [x] Emit readable Showdown-style arena projections and policy-skill metrics.
- [ ] Add historical-checkpoint payoff matrices and Nash-mixture estimates.
- [ ] Add a versioned binary shard format after JSONL stabilizes.

## M2 — simultaneous search

- [ ] Add native state-branch benchmarks independent of episode throughput.
- [x] Evaluate every legal joint action at shallow roots.
- [x] Solve sampled root payoff matrices with regret matching+.
- [x] Store regrets, average strategies, and joint-action returns at every tree node.
- [x] Add regret matching at every expanded simultaneous MCTS node.
- [x] Represent sampled chance outcomes as explicit edges with independent search keys.
- [x] Guarantee exploration support for every legal move and switch without top-k pruning.
- [x] Add native `reset-append` and `compact-many` multi-root state retention.
- [x] Batch complete root matrices across independent live episodes.
- [ ] Schedule deeper progressive frontier expansion across independent roots.
- [x] Validate RM+ and deeper backups on exact matrices and a stochastic toy game.
- [ ] Keep opponent-sampled PUCT only as a named best-response baseline.
- [x] Implement `fresh-root-v1` without access to episode future RNG.
- [x] Report root exploitability and tree coverage diagnostics.

## M3 — batched policy/value learning

- [x] Freeze the variable-party v4 492-field side-canonical tensor and 13-action mask.
- [x] Train a byte/position-embedding transformer outside Lean.
- [x] Batch bounded leaf inference within each exhaustive root search.
- [x] Batch root-leaf and network-policy inference across compatible roots.
- [ ] Run a multi-worker service for deeper frontier inference.
- [ ] Add bounded worker queues and inference timeouts.
- [x] Train policy and terminal value heads from MCTS/terminal targets.
- [x] Use BF16 autocast with FP32 parameters, optimizer state, outputs, and losses.
- [x] Preserve pre-v5 checkpoint execution as FP32.
- [x] Publish immutable model, optimizer, schema, and SHA-256 checkpoints.
- [ ] Resume bit-for-bit from a checkpoint and replay ledger.
- [ ] Compare network-only, PUCT, and deeper regret-MCTS policies.

## M4 — full-party link battles

- [x] Normalize forced replacement as a one-side request.
- [x] Normalize Mimic target selection as a one-side request.
- [ ] Normalize learning, evolution, and other profile-widening nested protocols.
- [ ] Support every legal move/switch/no-action/Struggle/run wire action.
- [x] Keep items and voluntary link forfeits unavailable in the training profile.
- [x] Promote only episodes with complete terminal provenance.
- [ ] Audit synchronized rollouts against both `Full.Link.Pair` perspectives.
- [ ] Classify and retain known desynchronizations.

## M5 — population and evaluation

- [x] Mix mirror self-play with hash-identified fixed-checkpoint opponents.
- [x] Round-robin multiple fixed baselines with balanced candidate sides.
- [ ] Sample latest, historical, and exploiter opponents.
- [ ] Retain held-out teams and seeds outside actor sampling.
- [ ] Produce checkpoint payoff matrices and Nash-mixture estimates.
- [x] Keep the incumbent unless score and paired confidence both clear 50%.
- [x] Gate promotion on type/status/switch probes and expanded data quality.
- [ ] Gate final deployment promotion on paired-cartridge evaluation.
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

“End-to-end training works” currently means the full-party transformer can
collect Lean-owned regret-search targets and network rollouts from random asymmetric 1-to-6-member
teams, train policy/value heads on GPU or CPU, emit traced side-swapped arenas,
and reproduce its first search shard.
“Deployable Pokémon agent” still means all relevant M0–M6 rows for
`full-link-paired-player-v1` are checked and their quality gates pass.
