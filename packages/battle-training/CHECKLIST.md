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
- [x] Add held-out generated-team type/status probes plus switch and setup diagnostics.
- [x] Add 1,024-game paired-seed complete side-swapped confidence intervals.
- [x] Reserve one third of generated collection and arena pairs for 6v6.
- [x] Report trunk-gradient conflict and whole-battle held-out diagnostics.
- [x] Separate the persistent shadow learner from quality-gated deployment.
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
- [x] Schedule deeper progressive frontier expansion across independent roots.
- [x] Validate RM+ and deeper backups on exact matrices and a stochastic toy game.
- [x] Move dense RM+/CFR+ arithmetic to a hashed Rust C ABI while retaining complete-root coverage and batched Lean/CUDA frontiers.
- [ ] Keep opponent-sampled PUCT only as a named best-response baseline.
- [x] Implement `fresh-root-v1` without access to episode future RNG.
- [x] Report root exploitability and tree coverage diagnostics.

## M3 — batched policy/value learning

- [x] Freeze the variable-party v4 492-field side-canonical tensor and 13-action mask.
- [x] Train a byte/position-embedding transformer outside Lean.
- [x] Batch bounded leaf inference within each exhaustive root search.
- [x] Batch root-leaf and network-policy inference across compatible roots.
- [x] Pool deeper native/inference frontiers by network identity across live roots.
- [x] Run deterministic multi-process actors with one timed Lean server per process.
- [x] Train policy and terminal value heads from MCTS/terminal targets.
- [x] Use BF16 autocast with FP32 parameters, optimizer state, outputs, and losses.
- [x] Batch promotion, campaign, and traced-probe arenas across live games.
- [x] Serve a read-only live dashboard for model, battle, actor, and promotion state.
- [x] Open self-play and promotion rows into on-demand recorded match panes.
- [x] Show complete move slots, PP/status, sprites, named choices, switches, and events.
- [x] Make one third of scheduled generated 6v6 pairs fully level 100.
- [x] Audit horizon stops and raise production/arena decision limits to 512.
- [x] Add quality-gated grouped-token and tiered-deep-search profiles.
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
- [x] Gate promotion on type/status probes and expanded completion/data quality; keep switching observational.
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

## M7 — patched campaign trainer deployment

The target and its information, ROM, and training boundaries are recorded in
[Campaign trainer battles controlled by the learned link policy](../../docs/explanation/campaign-trainer-link-ai.md).
This is a synchronized patched-ROM profile, distinct from the stock paired-ROM
profile in M6.

- [ ] Enter the AI-link wrapper only for campaign trainer encounters; leave wild,
      Safari, Old Man, and stock link controllers unchanged.
- [ ] Build and hash a BPS patch against the canonical Red ROM and retain its
      generated `.sym`, `.map`, and profile manifest.
- [ ] Initialize the stock link random list and record the virtual clock role for
      every trainer battle.
- [ ] Emit the model request before accepting the player's action and prove that
      later menu selection cannot change that request.
- [ ] Replace serial remote-action receipt with one cached, mask-validated backend
      action while retaining stock link action decoding.
- [ ] Bridge voluntary switching, forced replacement, no-action, Struggle, and
      every reachable typed nested request.
- [ ] Keep player and trainer items plus voluntary forfeits unavailable in the
      patched battle profile.
- [ ] Translate link terminal results into campaign trainer-script progression,
      save-state invariants, and the selected loss policy.
- [ ] Implement the ROM-to-v4 observation adapter and compare all 492 fields with
      `FullTraining.featureVector` fixtures.
- [x] Build the pinned SameBoy browser/WASM wrapper, local canonical-ROM hash
      gate, worker framebuffer, joypad controls, and save-state/memory bridge.
- [x] Reconstruct selected recorded battles through Lean, stage their complete
      parties/link RNG in Red, inject both action streams, and synchronize/report
      WRAM checkpoints throughout browser playback.
- [ ] Add the versioned WebSocket inference service and patched battle request
      protocol.
- [ ] Replay patched-ROM turns through the synchronized Lean model and retain
      every mismatch, nonfinish, and paired-cartridge discrepancy.
- [ ] Gate deployment on stratified campaign-team arenas and decide roster/level
      scaling independently from the battle-control policy.

## M8 — random level-100 6v6 web exhibition

The browser-first target is specified in
[Browser exhibition with random level-100 teams](../../docs/explanation/web-random-6v6-exhibition.md).
It reuses M7's action, adapter, inference, and link-RNG work but has a separate
boot patch and no campaign state.

- [x] Accept a user-supplied canonical Red ROM or ZIP entirely in-browser,
      hash-gate it, and boot it through the pinned SameBoy worker without
      redistributing ROM bytes.
- [ ] Add a progression-witnessed generator fixed to six level-100 Pokémon and
      prove deterministic replay and canonical legality.
- [ ] Split root entropy into recorded human-team, model-team, battle-RNG, and
      clock-role streams.
- [ ] Define and validate the versioned party/RNG staging manifest consumed by
      the patched ROM.
- [ ] Build and hash `web-random-6v6-link-ai-v1` as a separate BPS profile that
      bypasses intro, main menu, save loading, and overworld entry.
- [ ] Hold on a minimal preparation screen until teams and inference are ready;
      fail closed instead of falling back to cartridge AI.
- [ ] Construct two full six-member party representations with every member at
      level 100, full HP/PP, and clear status.
- [ ] Enter patched synchronized link battle with slot zero as each side's lead,
      no items, and no voluntary forfeit.
- [ ] Reuse the pre-player-action cached backend bridge for every normal, forced,
      and nested request.
- [ ] Append every semantic decision and result to the server-authoritative M9
      trace without blocking emulator input or rendering.
- [ ] End at a win/loss screen and make rematch generate a clean match with a new
      seed without reading or writing campaign save data.
- [ ] Add a held-out `web-random-l100-6v6` promotion arena and human-play latency,
      completion, and difficulty gates.
- [ ] Differential-test generated party bytes and turn traces against the Lean
      manifest and synchronized model.

## M9 — human battle trace ingestion

The collection and offline-learning boundary is specified in
[Learning from browser battle traces](../../docs/explanation/human-battle-trace-training.md).

- [ ] Publish a short collection notice and bind a consent-policy version before
      issuing a match ID.
- [ ] Freeze a logical trace schema for version/hash identities, exact parties,
      typed decisions, masks, actions, events, RNG transitions, and provenance.
- [ ] Record the model request, policy/value output, and cached action on the
      backend before accepting the later human commitment.
- [ ] Sequence human actions with server nonces and reject duplicate, stale,
      illegal, impossible, or out-of-order records.
- [ ] Retain disconnects and bridge failures as partial traces without terminal
      value labels.
- [ ] Content-address immutable traces while excluding ROMs, patches, save RAM,
      raw keypresses, video/audio, IP addresses, and browser fingerprints.
- [ ] Deterministically replay every candidate through Lean and quarantine the
      first state, event, RNG, legality, or ROM-projection mismatch.
- [ ] Search-relabel eligible human-encountered states with independent entropy;
      do not use raw human choices as perfect-information targets by default.
- [ ] Split by match and rotating player identity before extracting positions;
      keep held-out users and seeds outside optimization.
- [ ] Add source caps, content/state deduplication, rate limits, anomaly checks,
      and a versioned maximum human-replay mixture weight.
- [ ] Require self-play-only versus human-state-relabel ablations and all existing
      nonhuman promotion gates before accepting a human-data checkpoint.
- [ ] Define trace/shard retention, account export/deletion, tombstones, and a
      separate consent/license decision before any public dataset release.

## Completion rule

“End-to-end training works” currently means the full-party transformer can
collect Lean-owned regret-search targets and network rollouts from random asymmetric 1-to-6-member
teams, train policy/value heads on GPU or CPU, emit traced side-swapped arenas,
and reproduce its first search shard.
A deployable stock paired-cartridge agent requires all relevant M0–M6 rows and
quality gates for `full-link-paired-player-v1`. A deployable campaign trainer
agent requires the relevant M0–M5 rows plus M7 for
`campaign-trainer-link-ai-v1`. The first browser exhibition requires the shared
M7 battle bridge and all M8 rows for `web-random-6v6-link-ai-v1`; it does not
require campaign encounter or progression work. A checkpoint claimed to learn
from user battles additionally requires all M9 rows and reports its human-state
mixture separately.
