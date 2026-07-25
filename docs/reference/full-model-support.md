# Full-model support

<!-- mode: reference -->

## Executable modules

| Domain | Module | Machine-checked boundary |
|---|---|---|
| Party state and switching | `Battle.Full.State` | Separate active/party/unmodified combat rows, status-adjusted switch-in stats, field-exact outgoing synchronization that excludes Transform/combat scratch, living switch targets, forced replacement, exhaustion |
| Menu selection scratch | `Battle.Full.Selection` | Fight reset, disabled/stale highlights, cancel retention, move/PP/Disable and ordered-bag swaps |
| Status and residuals | `Battle.Full.Status` | Status-gate order, conditional RNG, poison/burn/seed residuals, Toxic counter interaction |
| Item dispatch | `Battle.Full.Items` | Explicit disposition for IDs `$01..$53`; executable battle-use handlers; Max Ether packed-byte bug |
| Effect dispatch | `Battle.Full.EffectPlan` | Typed plans for all effect IDs `$00..$56`; all 165 canonical move rows covered |
| Effect execution | `Battle.Full.Effects` | State transformers and explicit control signals for every effect family; exact stat-stage arithmetic; Haze/Transform stat rows; and cartridge-ordered Mimic replacement; Haze cancellation; status-stat mutation, recharge bypass, side-effect draw ordering, asymmetric freeze cleanup, and fire defrost |
| Trainer controller | `Battle.Full.TrainerController`, `Battle.Full.Environment` | All 47 class rows, scoring layers, action counts/routines, direct-Random actions, minimum-score slot rejection, executable plans |
| Capture | `Battle.Full.Capture`, `Battle.Full.CaptureProtocol` | Ball arithmetic, shake counts, rebuilt stored rows, nested naming/defaults, party append, box slot-one parallel shifts, malformed no-storage paths |
| Safari | `Battle.Full.Safari`, `Battle.Full.Environment` | Integrated ball/bait/rock/run protocol, rejection factors, catch mutation, last-ball ordering, post-action escape and terminal causes |
| Run | `Battle.Full.Escape` | Wild run arithmetic, attempt counter, trainer prohibition, inclusive comparison |
| Disobedience | `Battle.Full.Disobedience` | Reactive rejection loops, badge thresholds, alternate moves, status overwrite, PP-Up candidate bug |
| Progression data | `Battle.Data.Progression` | 191 internal-species growth, initial-move, exact evolution-method, and level/move rows; ROM-certified |
| Progression arithmetic | `Battle.Full.Progression` | Six growth curves, level inversion, divided awards, sequential boosts, stat EXP saturation, DV/stat formulas, learning/evolution requests |
| Move learning | `Battle.Full.Learning` | Duplicate/empty-slot paths, try/forget/abandon prompts, cancellation, HM deletion rejection, base PP installation |
| Money/epilogue | `Battle.Full.Money` | Three-byte BCD saturation, Pay Day, trainer prize, raw-result and link evolution guards |
| Evolution protocol | `Battle.Full.Evolution` | Flagged slot order, level/item/trade matching, wild item-alias input, cancellation, stat/HP update, nested learning |
| Turn composition | `Battle.Full.Engine` | Actions, ordering, status, damage/effects, items, residuals, faint/replacement, terminal witness |
| RL protocol | `Battle.Full.Environment` | Dynamic proof-carrying parties, participation flags, EXP awards, persistent progression rows, nested learning/evolution, observations and legal actions |
| Self-play | `Battle.Full.SelfPlay` | Independent policy RNGs, nested continuations, finite/open behavior distinction |
| Paired link execution | `Battle.Full.Link` | Action-nybble exchange, clock roles/equal-Speed inversion, dual cartridge engines, mirror/RNG checks, explicit known desynchronization causes |
| Domain certificate | `Battle.Full.Support.model_coverage` | Move/effect, item, trainer, ball, generator, and external-bug domain closure |

## External bug compatibility

`Battle.BugCompatibility.all_external_bugs_supported` certifies all 13 claims
inventoried in [the external compatibility audit](../research/external-bug-compatibility-audit.md).
The certificate is independent of the external source tree.

## Native smoke matrix

```text
episodes=100 finished=88 truncated=12 nested_open=0
blocked=0 invalid=0 rng_stuck=0 division_freeze=0 other=0
repaired=0 transitions=50820
```

The 12 horizon-open runs are not terminal outcomes; status-heavy generated
parties can produce legitimate long-running or nonterminating battles.

## Claim boundary

The modules above establish an executable high-level full-party model and total
canonical dispatch domains. They do **not** establish full cartridge-equivalence.
The following remain outside `ModelCoverage`:

- decoded-ROM transition refinement for the remaining effect-handler bodies
  (data rows, phase tables, pointer dispatch, and the Hyper Beam/Rage leaf tails
  are now byte-certified);
- decoded-ROM refinement of menu/presentation traces and their timing;
- continuous fetched-IR execution from battle entry through cleanup and return;
- full hardware assumptions for non-link `Random`, waits, audio, serial, and
  presentation timing.

Therefore the repository may claim **full high-level dispatch/model coverage**,
but not verified 1:1 support for arbitrary Pokémon Red battles.
