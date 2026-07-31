# Status-gate and two-turn equivalence audit

**Canonical target:** English Pokémon Red, `pret/pokered` commit
`405b6246372d7e5a2cb029cbb65219b13286b8c9`, ROM SHA-256
`5ca7ba01642a3b27b0cc0b5349b52792795b62d3ed977e98a09390659af96b7b`.

## Scope

This audit covers the complete pre-move status gate that decides whether a
selected move executes, plus every ordinary two-turn charge move. It preserves
raw malformed status bytes and side-specific cartridge duplication. Status
infliction handlers, residual poison/burn/Toxic/Leech Seed arithmetic, Haze,
Rest, and item cures remain covered by their existing mechanics and local
routine theorems; this audit does not relabel those separate obligations as a
whole-battle ROM simulation.

## Complete status-gate order

The player routine starts at bank `$0F:$5854`; the enemy duplicate starts at
`$0F:$688F`. The retained decoded windows establish this order:

1. sleep counter (`status & $07`), with decrement written back as the entire
   status byte;
2. freeze;
3. opponent trapping;
4. flinch, clearing status-1 bit 3;
5. Hyper Beam recharge, clearing status-2 bit 5;
6. packed Disable countdown and low-nibble expiration;
7. confusion counter, expiration, and the `$80` self-hit comparison;
8. selected move becoming disabled;
9. paralysis and the exact `$3F` (`63/256`) full-paralysis threshold;
10. the later Bide/Thrash/trapping/Rage continuation states.

Burn and poison do not block action. Sleep takes priority over malformed
freeze/paralysis combinations; freeze takes priority over paralysis. Lean
checks all 256 status bytes against all 256 possible paralysis RNG bytes in
`Battle.Full.Status.all_nonvolatile_status_bytes_exact`.

`Battle.Rom.StatusGateRoutine` executes the gameplay-mutating status kernels
through both the functional and physical SM83 models. Its finite theorems cover
both sides and every raw byte for sleep, flinch, recharge, Disable, full
paralysis cleanup, and selected-disabled cleanup. Confusion covers every raw
status byte at absence, underflow, expiration, and active-decrement boundaries;
the post-`BattleRandom` `$80` comparison bytes are retained separately.
Presentation and self-confusion damage calls are synchronization boundaries, not
silently replaced with handwritten effects.

## Interruption correction

The audit corrected an over-broad high-level cleanup helper.
`PrintMoveIsDisabledText` executes `RES 4,A` and writes the result back. It does
not clear Bide, Thrash, or trapping. The model now has three distinct exact
transformers:

| Interruption | Cartridge mask | Consequence for Fly/Dig |
|---|---:|---|
| Full paralysis | `$cc` | Clears Bide/Thrash/charge/trapping; preserves invulnerability |
| Selected Disable | `$ef` | Clears charge only; preserves invulnerability and all other bits |
| Self-confusion | `$80`, then common cleanup | Keeps only `CONFUSED`; clears invulnerability |

Thus full paralysis and selected Disable can strand Fly/Dig invulnerability,
but self-confusion cannot. All interruption paths return before continuation PP
decrement.

## Complete ordinary two-turn family

The canonical move table contains exactly six charge-handler moves:

| ID | Move | Effect | First-turn status | Setup animation selector |
|---:|---|---:|---|---:|
| `$0D` | Razor Wind | `$27` | `CHARGING_UP` | player `$AE`, enemy `$AF` |
| `$13` | Fly | `$2B` | `CHARGING_UP` and `INVULNERABLE` | `$64` |
| `$4C` | SolarBeam | `$27` | `CHARGING_UP` | player `$AE`, enemy `$AF` |
| `$5B` | Dig | `$27` | `CHARGING_UP` and `INVULNERABLE` | `$C0` |
| `$82` | Skull Bash | `$27` | `CHARGING_UP` | player `$AE`, enemy `$AF` |
| `$8F` | Sky Attack | `$27` | `CHARGING_UP` | player `$AE`, enemy `$AF` |

`Battle.Full.EffectPlan.canonical_two_turn_moves_complete` proves, for every
canonical move ID `$01..$A5`, that charge-handler membership is equivalent to
membership in this six-move set.

`Battle.Rom.ChargeRoutine.all_charge_setups_exact` executes bank `$0F:$78A1–$78B5`
for all six moves, both sides, and all 256 incoming status-1 bytes in the
functional and physical CPUs. It proves the exact acting-side write, opposite-
side preservation witness, effect/move retention, and side-correct animation
selector.

`Battle.Rom.ChargeRoutine.all_charge_continuations_exact` executes both duplicated
continuation windows:

- player `$0F:$56A9–$56AF`;
- enemy `$0F:$670B–$6711`.

For every input byte they clear exactly bits 4 and 6 (`status & $AF`) and preserve
every other bit. The high-level theorem `all_two_turn_setups_exact` proves the
same first-turn status transformers, while `charge_continuation_protocol`
proves retained-move execution and continuation-only PP decrement.

## Claim boundary

These are universal local refinement theorems for the status gate and ordinary
charge family, linked to exact canonical byte windows. They are stronger than
fixtures or sampled traces, but they are not a proof that the complete battle
driver is observationally equivalent to the ROM. Presentation calls, complete
status-infliction handlers, residual processing, link scheduling, and the
whole-turn phase relation remain independent obligations under the universal
equivalence program.
