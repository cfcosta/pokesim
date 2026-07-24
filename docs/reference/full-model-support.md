# Full-model support

<!-- mode: reference -->

## Executable modules

| Domain | Module | Machine-checked boundary |
|---|---|---|
| Party state and switching | `Battle.Full.State` | Separate active/party rows, outgoing synchronization, living switch targets, forced replacement, exhaustion |
| Status and residuals | `Battle.Full.Status` | Status-gate order, conditional RNG, poison/burn/seed residuals, Toxic counter interaction |
| Item dispatch | `Battle.Full.Items` | Explicit disposition for IDs `$01..$53`; executable battle-use handlers; Max Ether packed-byte bug |
| Effect dispatch | `Battle.Full.EffectPlan` | Typed plans for all effect IDs `$00..$56`; all 165 canonical move rows covered |
| Effect execution | `Battle.Full.Effects` | State transformers and explicit control signals for every effect family |
| Trainer controller | `Battle.Full.TrainerController` | All 47 class rows, scoring layers, action counts/routines, slot rejection relation |
| Capture | `Battle.Full.Capture` | Ball rejection, integer capture pipeline, shake counts, storage species, capacity checks |
| Safari | `Battle.Full.Safari` | Ball/bait/rock/run protocol, factors, catch mutation, escape threshold |
| Run | `Battle.Full.Escape` | Wild run arithmetic, attempt counter, trainer prohibition, inclusive comparison |
| Disobedience | `Battle.Full.Disobedience` | Reactive rejection loops, badge thresholds, alternate moves, status overwrite, PP-Up candidate bug |
| Progression data | `Battle.Data.Progression` | 191 internal-species growth, initial-move, exact evolution-method, and level/move rows; ROM-certified |
| Progression arithmetic | `Battle.Full.Progression` | Six growth curves, level inversion, divided awards, sequential boosts, stat EXP saturation, DV/stat formulas, learning/evolution requests |
| Turn composition | `Battle.Full.Engine` | Actions, ordering, status, damage/effects, items, residuals, faint/replacement, terminal witness |
| RL protocol | `Battle.Full.Environment` | Dynamic proof-carrying parties, observations, legal actions, external-random requests |
| Self-play | `Battle.Full.SelfPlay` | Independent policy RNGs, nested continuations, finite/open behavior distinction |
| Domain certificate | `Battle.Full.Support.model_coverage` | Move/effect, item, trainer, ball, generator, and external-bug domain closure |

## External bug compatibility

`Battle.BugCompatibility.all_external_bugs_supported` certifies all 13 claims
inventoried in [the external compatibility audit](../research/external-bug-compatibility-audit.md).
The certificate is independent of the external source tree.

## Native smoke matrix

```text
episodes=100 finished=98 truncated=2 nested_open=0
blocked=0 invalid=0 rng_stuck=0 division_freeze=0 other=0
repaired=0 transitions=11349
```

The two horizon-open runs are not terminal outcomes.

## Claim boundary

The modules above establish an executable high-level full-party model and total
canonical dispatch domains. They do **not** establish full cartridge-equivalence.
The following remain outside `ModelCoverage`:

- decoded-ROM refinement for battle routines and effect handlers;
- integration of the modeled traded-Pokémon disobedience state machine into turn composition;
- integration of modeled EXP/stat progression plus participation, exact-level
  move-learning, evolution, payout, and post-battle epilogue semantics;
- exact presentation/menu traces and selection-scratch behavior;
- continuous fetched-IR execution from battle entry through cleanup and return;
- full hardware assumptions for non-link `Random`, waits, audio, serial, and
  presentation timing.

Therefore the repository may claim **full high-level dispatch/model coverage**,
but not verified 1:1 support for arbitrary Pokémon Red battles.
