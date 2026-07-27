# Full-link training-state audit

<!-- mode: research -->

This audit compares `Battle.RL.FullTraining.featureVector` with the state read by
`Battle.Full.Environment.step`, `Battle.Full.Engine.step`, and the typed request
normalizer in `Battle.RL.FullSearchServerMain`. Its scope is
`full-link-6v6-perfect-v1`. It does not cover trainer, wild, Safari, capture,
learning, evolution, or player-information policies.

## Result

The v2 tensor was not Markov at a Mimic request. `SearchState.mimic` retained the
opposing action that must resume after the target slot is chosen, but
`featureVector` encoded only the actor and source slot. Two requests could
therefore have identical 477 fields and legal masks while resuming different
actions.

Schema `full-link-6v6-state-v3` adds one collision-free continuation field:

- `0`: no pending continuation;
- `1..13`: stable link action ID plus one;
- `14`: an item continuation, reserved outside this profile.

The tensor now has 478 fields. A Lean guard constructs the same mechanics state
and Mimic request with `none` and `some noAction` continuations and checks that
the two vectors differ. Search fingerprints include the new field. Checkpoints
for v2 are intentionally incompatible with v3.

No second concrete alias was found in the current link request surface. CI runs
`tools/audit-full-training-state.py`, which rejects any new `Engine.State` or
`Environment.State` field until it is classified as encoded, latent chance,
profile-inert, or proof-only. This is a source-shape drift gate, not a universal
injectivity or transition-kernel theorem; the proof gaps are listed below.

## Field accounting

| Region | Width | Mechanics represented |
|---|---:|---|
| Own persistent party plus active state | 181 | Six 22-field party rows, active index, live mon, unmodified stats, all eight stage bytes, volatile bytes/counters, Transform identity, party position, live catch rate |
| Opponent persistent party plus active state | 181 | Same fields in side-canonical order |
| Active move descriptors | 48 | Effect, power, type, accuracy, live type effectiveness, and static score for four moves on each side |
| Switch matchup descriptors | 12 | Best outgoing and incoming static score for each own party slot |
| Selection scratch | 16 | Selected/loaded move, highlighted slot, effect, power, type, accuracy, and PP for both sides |
| Money scratch | 9 | Pay Day, player money, and trainer prize BCD bytes |
| Player OT IDs | 6 | One word-valued scalar per party slot |
| Global and request state | 25 | Mode, turn, phase, verdict, replacement queue, last moves, damage words, IDs/badges/run state, canceled action, trainer scratch, Mimic actor/source/continuation, progression flags, pending-learning length |
| Total | 478 | `full-link-6v6-state-v3` |

The move and switch descriptors are deterministic functions of already encoded
mechanics state and canonical tables. They help the network but do not repair an
otherwise missing state field.

## Included mutable mechanics

The audit traced every direct read of the following `Engine.State` fields:

- `battle.player`, `battle.enemy`, active indexes, turn, mode, and phase;
- selected and loaded move scratch;
- last moves, shared damage, and both locked-damage words;
- forced and queued replacement sides;
- player ID and OT IDs used by disobedience;
- badges and trainer/item scratch;
- run attempts and canceled action;
- money and prize bytes used at faint and settlement boundaries.

All are encoded, or are ruled inert by the named profile below.

## Deliberately omitted fields

| Omitted state | Why it is omitted in this profile | Required condition |
|---|---|---|
| `battle.rng` list and cursor | Future chance must not be visible to policy or search | Transitions use the named `fresh-root-v1` chance kernel; episode replay retains its private cursor |
| Player/enemy bags | Link items have no wire action and are absent from legal masks | Both bags remain empty |
| Capture, box, names, owned species, Safari, Old Man state | No link action enters these protocols | Pending capture and mode-specific states remain absent |
| Progression rows and move histories | Link faint handling skips experience and progression awards | No pending learning/evolution request is reachable |
| Generator witnesses and resource ledgers | Proof and replay metadata; `step` does not read them | They remain immutable |
| Trainer class/action counter | Trainer controller is not entered in link mode | Trainer request state remains absent |
| Terminal cause details | Returned states are not searched and policy value uses the retained verdict | `done` stops the actor immediately |
| Prior event list | Events are output history and do not feed the synchronized mechanics transition | Player-information profiles must encode observable history separately |

`FullTraining.profileInvariant` records the inventory, mode, capture, and nested
request restrictions. `sampled_link_reset_satisfies_profile` proves the link
constructor satisfies it for arbitrary proof-carrying team samples, without
using a concrete generator fixture.

## Open proof obligations

1. Prove `profileInvariant` is preserved by every normalized link action,
   automatic generated move, disobedience response, forced replacement, and
   Mimic response.
2. Define a structured 478-field decoder on canonical six-member states and
   prove `decode (featureVector state view request)` recovers every field in the
   link mechanics projection.
3. Prove equal decoded projections and equal legal actions induce equal
   distributions of the next decoded projection under `fresh-root-v1`.
4. Keep latent chance separate from state equality. Equality of policy tensors
   must never imply equality of private episode RNG suffixes.
5. Repeat this audit from scratch for `full-link-paired-player-v1`; the current
   perfect-information tensor exposes the opponent party and cannot be reused.

Until obligations 1-3 close, the accurate statement is: v3 fixes the known Mimic
alias and covers all direct mutable reads found by the audit, but complete Markov
sufficiency is not yet a theorem.
