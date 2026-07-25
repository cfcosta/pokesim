# Move-effect dispatch

<!-- mode: reference -->

**Baseline:** `pret/pokered` commit `405b6246372d7e5a2cb029cbb65219b13286b8c9`.

A move's effect byte is not one callback phase. `ExecutePlayerMove` and `ExecuteEnemyMove` test several ROM tables and also special-case move/effect IDs directly. This page records the exact table memberships and pointer targets found in the pinned ASM.

## Execution phases

For the ordinary player path, the relevant order is:

1. `ResidualEffects1`: call the pointer and finish before ordinary damage/hit handling.
2. `SpecialEffectsCont`: call the pointer before damage, then continue.
3. `SetDamageEffects`: skip ordinary damage calculation; the apply routine computes special damage later.
4. `CalculateDamage`: directly invokes the OHKO handler for `OHKO_EFFECT`.
5. `MoveHitTest` and explicit Mirror Move/Metronome handling.
6. `ResidualEffects2`: call the pointer and finish before applying ordinary damage.
7. Apply damage.
8. `AlwaysHappenSideEffects`: call the pointer before checking target HP.
9. If the target survived, continue multi-hit handling.
10. If the current effect is nonzero and absent from `SpecialEffects`, call its pointer as the remaining effect.

The enemy path mirrors this shape with separate labels and state. A theorem must establish equivalence rather than assume textual symmetry.

`SpecialEffectsCont` is an interior label in `SpecialEffects`; therefore Thrash/Petal Dance and trapping are members of both the small pre-damage continuation suffix and the full final-skip table.

## Exact classification arrays

### `ResidualEffects1`

```text
CONVERSION_EFFECT
HAZE_EFFECT
SWITCH_AND_TELEPORT_EFFECT
MIST_EFFECT
FOCUS_ENERGY_EFFECT
CONFUSION_EFFECT
HEAL_EFFECT
TRANSFORM_EFFECT
LIGHT_SCREEN_EFFECT
REFLECT_EFFECT
POISON_EFFECT
PARALYZE_EFFECT
SUBSTITUTE_EFFECT
MIMIC_EFFECT
LEECH_SEED_EFFECT
SPLASH_EFFECT
```

### `SpecialEffectsCont`

```text
THRASH_PETAL_DANCE_EFFECT
TRAPPING_EFFECT
```

### `SetDamageEffects`

```text
SUPER_FANG_EFFECT
SPECIAL_DAMAGE_EFFECT
```

### `ResidualEffects2`

```text
EFFECT_01
ATTACK_UP1_EFFECT
DEFENSE_UP1_EFFECT
SPEED_UP1_EFFECT
SPECIAL_UP1_EFFECT
ACCURACY_UP1_EFFECT
EVASION_UP1_EFFECT
ATTACK_DOWN1_EFFECT
DEFENSE_DOWN1_EFFECT
SPEED_DOWN1_EFFECT
SPECIAL_DOWN1_EFFECT
ACCURACY_DOWN1_EFFECT
EVASION_DOWN1_EFFECT
BIDE_EFFECT
SLEEP_EFFECT
ATTACK_UP2_EFFECT
DEFENSE_UP2_EFFECT
SPEED_UP2_EFFECT
SPECIAL_UP2_EFFECT
ACCURACY_UP2_EFFECT
EVASION_UP2_EFFECT
ATTACK_DOWN2_EFFECT
DEFENSE_DOWN2_EFFECT
SPEED_DOWN2_EFFECT
SPECIAL_DOWN2_EFFECT
ACCURACY_DOWN2_EFFECT
EVASION_DOWN2_EFFECT
```

### `AlwaysHappenSideEffects`

```text
DRAIN_HP_EFFECT
EXPLODE_EFFECT
DREAM_EATER_EFFECT
PAY_DAY_EFFECT
TWO_TO_FIVE_ATTACKS_EFFECT
EFFECT_1E
ATTACK_TWICE_EFFECT
RECOIL_EFFECT
TWINEEDLE_EFFECT
RAGE_EFFECT
```

### `SpecialEffects`

This table includes the `SpecialEffectsCont` suffix.

```text
DRAIN_HP_EFFECT
EXPLODE_EFFECT
DREAM_EATER_EFFECT
PAY_DAY_EFFECT
SWIFT_EFFECT
TWO_TO_FIVE_ATTACKS_EFFECT
EFFECT_1E
CHARGE_EFFECT
SUPER_FANG_EFFECT
SPECIAL_DAMAGE_EFFECT
FLY_EFFECT
ATTACK_TWICE_EFFECT
JUMP_KICK_EFFECT
RECOIL_EFFECT
THRASH_PETAL_DANCE_EFFECT
TRAPPING_EFFECT
```

## Complete effect index

Abbreviations in the final column:

- `R1`: `ResidualEffects1`
- `Cont`: `SpecialEffectsCont`
- `Set`: `SetDamageEffects`
- `R2`: `ResidualEffects2`
- `Always`: `AlwaysHappenSideEffects`
- `Special`: the full `SpecialEffects` table, including its `Cont` suffix

| ID | Constant | Pointer | Phase-table membership |
|---:|---|---|---|
| `$00` | `NO_ADDITIONAL_EFFECT` | — | — |
| `$01` | `EFFECT_01` | `SleepEffect` | R2 |
| `$02` | `POISON_SIDE_EFFECT1` | `PoisonEffect` | — |
| `$03` | `DRAIN_HP_EFFECT` | `DrainHPEffect` | Always, Special |
| `$04` | `BURN_SIDE_EFFECT1` | `FreezeBurnParalyzeEffect` | — |
| `$05` | `FREEZE_SIDE_EFFECT1` | `FreezeBurnParalyzeEffect` | — |
| `$06` | `PARALYZE_SIDE_EFFECT1` | `FreezeBurnParalyzeEffect` | — |
| `$07` | `EXPLODE_EFFECT` | `ExplodeEffect` | Always, Special |
| `$08` | `DREAM_EATER_EFFECT` | `DrainHPEffect` | Always, Special |
| `$09` | `MIRROR_MOVE_EFFECT` | `NULL` | — |
| `$0A` | `ATTACK_UP1_EFFECT` | `StatModifierUpEffect` | R2 |
| `$0B` | `DEFENSE_UP1_EFFECT` | `StatModifierUpEffect` | R2 |
| `$0C` | `SPEED_UP1_EFFECT` | `StatModifierUpEffect` | R2 |
| `$0D` | `SPECIAL_UP1_EFFECT` | `StatModifierUpEffect` | R2 |
| `$0E` | `ACCURACY_UP1_EFFECT` | `StatModifierUpEffect` | R2 |
| `$0F` | `EVASION_UP1_EFFECT` | `StatModifierUpEffect` | R2 |
| `$10` | `PAY_DAY_EFFECT` | `PayDayEffect` | Always, Special |
| `$11` | `SWIFT_EFFECT` | `NULL` | Special |
| `$12` | `ATTACK_DOWN1_EFFECT` | `StatModifierDownEffect` | R2 |
| `$13` | `DEFENSE_DOWN1_EFFECT` | `StatModifierDownEffect` | R2 |
| `$14` | `SPEED_DOWN1_EFFECT` | `StatModifierDownEffect` | R2 |
| `$15` | `SPECIAL_DOWN1_EFFECT` | `StatModifierDownEffect` | R2 |
| `$16` | `ACCURACY_DOWN1_EFFECT` | `StatModifierDownEffect` | R2 |
| `$17` | `EVASION_DOWN1_EFFECT` | `StatModifierDownEffect` | R2 |
| `$18` | `CONVERSION_EFFECT` | `ConversionEffect` | R1 |
| `$19` | `HAZE_EFFECT` | `HazeEffect` | R1 |
| `$1A` | `BIDE_EFFECT` | `BideEffect` | R2 |
| `$1B` | `THRASH_PETAL_DANCE_EFFECT` | `ThrashPetalDanceEffect` | Cont, Special |
| `$1C` | `SWITCH_AND_TELEPORT_EFFECT` | `SwitchAndTeleportEffect` | R1 |
| `$1D` | `TWO_TO_FIVE_ATTACKS_EFFECT` | `TwoToFiveAttacksEffect` | Always, Special |
| `$1E` | `EFFECT_1E` | `TwoToFiveAttacksEffect` | Always, Special |
| `$1F` | `FLINCH_SIDE_EFFECT1` | `FlinchSideEffect` | — |
| `$20` | `SLEEP_EFFECT` | `SleepEffect` | R2 |
| `$21` | `POISON_SIDE_EFFECT2` | `PoisonEffect` | — |
| `$22` | `BURN_SIDE_EFFECT2` | `FreezeBurnParalyzeEffect` | — |
| `$23` | `FREEZE_SIDE_EFFECT2` | `FreezeBurnParalyzeEffect` | — |
| `$24` | `PARALYZE_SIDE_EFFECT2` | `FreezeBurnParalyzeEffect` | — |
| `$25` | `FLINCH_SIDE_EFFECT2` | `FlinchSideEffect` | — |
| `$26` | `OHKO_EFFECT` | `OneHitKOEffect` | — |
| `$27` | `CHARGE_EFFECT` | `ChargeEffect` | Special |
| `$28` | `SUPER_FANG_EFFECT` | `NULL` | Set, Special |
| `$29` | `SPECIAL_DAMAGE_EFFECT` | `NULL` | Set, Special |
| `$2A` | `TRAPPING_EFFECT` | `TrappingEffect` | Cont, Special |
| `$2B` | `FLY_EFFECT` | `ChargeEffect` | Special |
| `$2C` | `ATTACK_TWICE_EFFECT` | `TwoToFiveAttacksEffect` | Always, Special |
| `$2D` | `JUMP_KICK_EFFECT` | `NULL` | Special |
| `$2E` | `MIST_EFFECT` | `MistEffect` | R1 |
| `$2F` | `FOCUS_ENERGY_EFFECT` | `FocusEnergyEffect` | R1 |
| `$30` | `RECOIL_EFFECT` | `RecoilEffect` | Always, Special |
| `$31` | `CONFUSION_EFFECT` | `ConfusionEffect` | R1 |
| `$32` | `ATTACK_UP2_EFFECT` | `StatModifierUpEffect` | R2 |
| `$33` | `DEFENSE_UP2_EFFECT` | `StatModifierUpEffect` | R2 |
| `$34` | `SPEED_UP2_EFFECT` | `StatModifierUpEffect` | R2 |
| `$35` | `SPECIAL_UP2_EFFECT` | `StatModifierUpEffect` | R2 |
| `$36` | `ACCURACY_UP2_EFFECT` | `StatModifierUpEffect` | R2 |
| `$37` | `EVASION_UP2_EFFECT` | `StatModifierUpEffect` | R2 |
| `$38` | `HEAL_EFFECT` | `HealEffect` | R1 |
| `$39` | `TRANSFORM_EFFECT` | `TransformEffect` | R1 |
| `$3A` | `ATTACK_DOWN2_EFFECT` | `StatModifierDownEffect` | R2 |
| `$3B` | `DEFENSE_DOWN2_EFFECT` | `StatModifierDownEffect` | R2 |
| `$3C` | `SPEED_DOWN2_EFFECT` | `StatModifierDownEffect` | R2 |
| `$3D` | `SPECIAL_DOWN2_EFFECT` | `StatModifierDownEffect` | R2 |
| `$3E` | `ACCURACY_DOWN2_EFFECT` | `StatModifierDownEffect` | R2 |
| `$3F` | `EVASION_DOWN2_EFFECT` | `StatModifierDownEffect` | R2 |
| `$40` | `LIGHT_SCREEN_EFFECT` | `ReflectLightScreenEffect` | R1 |
| `$41` | `REFLECT_EFFECT` | `ReflectLightScreenEffect` | R1 |
| `$42` | `POISON_EFFECT` | `PoisonEffect` | R1 |
| `$43` | `PARALYZE_EFFECT` | `ParalyzeEffect` | R1 |
| `$44` | `ATTACK_DOWN_SIDE_EFFECT` | `StatModifierDownEffect` | — |
| `$45` | `DEFENSE_DOWN_SIDE_EFFECT` | `StatModifierDownEffect` | — |
| `$46` | `SPEED_DOWN_SIDE_EFFECT` | `StatModifierDownEffect` | — |
| `$47` | `SPECIAL_DOWN_SIDE_EFFECT` | `StatModifierDownEffect` | — |
| `$48` | unused | `StatModifierDownEffect` | — |
| `$49` | unused | `StatModifierDownEffect` | — |
| `$4A` | unused | `StatModifierDownEffect` | — |
| `$4B` | unused | `StatModifierDownEffect` | — |
| `$4C` | `CONFUSION_SIDE_EFFECT` | `ConfusionSideEffect` | — |
| `$4D` | `TWINEEDLE_EFFECT` | `TwoToFiveAttacksEffect` | Always |
| `$4E` | unused | `NULL` | — |
| `$4F` | `SUBSTITUTE_EFFECT` | `SubstituteEffect` | R1 |
| `$50` | `HYPER_BEAM_EFFECT` | `HyperBeamEffect` | — |
| `$51` | `RAGE_EFFECT` | `RageEffect` | Always |
| `$52` | `MIMIC_EFFECT` | `MimicEffect` | R1 |
| `$53` | `METRONOME_EFFECT` | `NULL` | — |
| `$54` | `LEECH_SEED_EFFECT` | `LeechSeedEffect` | R1 |
| `$55` | `SPLASH_EFFECT` | `SplashEffect` | R1 |
| `$56` | `DISABLE_EFFECT` | `DisableEffect` | — |

The pointer table has 86 entries for IDs `$01`–`$56`; ID `$00` is deliberately not indexed because `_JumpMoveEffect` subtracts one before lookup.

## Directly handled and mutable-effect cases

A `NULL` pointer does not mean “no mechanics.” These IDs are handled elsewhere:

- Mirror Move and Metronome have explicit branches after animation/hit handling and reload a selected move record.
- Swift is recognized by `MoveHitTest` and returns before ordinary checks.
- Super Fang and special-damage moves are applied in `ApplyAttackTo*Pokemon`.
- Jump Kick crash behavior is in miss handling.
- OHKO calls its handler from `CalculateDamage`.

Two handlers mutate the loaded effect byte:

- Twineedle initializes exactly two hits by replacing its current effect with `POISON_SIDE_EFFECT1`; after multi-hit completion the poison handler is reached as the remaining effect.
- Rage appears in `AlwaysHappenSideEffects` and is then reached again as a remaining effect; the second set is behaviorally redundant but part of control flow.

Hyper Beam is not in `AlwaysHappenSideEffects`. Because target HP is checked before the remaining-effect call, a Hyper Beam that faints its target does not set recharge. This must emerge from the phase proof rather than be encoded as an unrelated exception.

## Decoded leaf-routine proofs

`Battle.Rom.EffectRoutines` now proves the call-free tails of `HyperBeamEffect`,
`RageEffect`, and shared `ClearHyperBeam` from hash-certified ROM windows. For
both player and enemy paths and all 65,536 pairs of incoming status bytes, the
functional SM83 execution:

- returns to the staged caller with the stack restored;
- sets bit 5 (recharge) or bit 6 (Rage) only on the acting side;
- follows the exact ordered opcode/immediate/HRAM/WRAM/write/stack/idle bus trace;
- takes 18 M-cycles on the player path and 20 M-cycles on the enemy path for
  Hyper Beam/Rage; `ClearHyperBeam` takes 25/27 M-cycles and also proves HL
  restoration.

These bodies are also run continuously through the flat fetched-IR adapter. The
physical traces equal the functional traces plus exactly one overlapped successor
fetch, with equal projected registers and affected WRAM.

`Battle.Rom.EffectPrefixes` additionally proves the mechanics prefixes of the
banked `FocusEnergyEffect_` and `MistEffect_` implementations. Both side branches
and every pair of incoming status bytes reach the exact success-presentation or
already-active-failure PC; successful paths set only the acting side's bit and
failed paths preserve both bytes. Both complete prefixes also run continuously
through fetched IR with exactly one successor overlap and equal projected state.
`Battle.Rom.ExplodeRoutine` proves the complete call-free `ExplodeEffect` body.
Both sides and all status-2 bytes follow exact functional and continuous
fetched-IR traces, zero only the acting HP/status row, clear only its Seeded bit,
restore the caller stack, and retain the other side.

`Battle.Rom.ConversionRoutine` proves `ConversionEffect_` through its presentation
boundary for both sides, both invulnerability outcomes, and all 65,536 target
type-byte pairs. The success path copies exactly two target type bytes to the
user; the Fly/Dig path reaches the failure tail without either write. Both paths
have exact functional bus traces and continuous fetched-IR lifts.

`Battle.Rom.OhkoRoutine` retains the complete `OneHitKOEffect_` byte window and
proves its two-byte `SUB`/`SBC` comparison universally: the success predicate is
exactly unsigned current attacker Speed greater than or equal to current target
Speed. This closes the tie case and slower branch arithmetic, but not yet the
handler's full bus trace or the surrounding random-damage/accuracy call order.

`Battle.Rom.ScreenRoutine` proves the shared `ReflectLightScreenEffect_`
gameplay prefix for both acting sides, both move IDs, and every pair of status-3
bytes. Exact traces distinguish the already-active failure path from the single
bit-setting success path and continue through one overlapped fetch at the common
presentation boundaries.

The remaining animation/text tails still need frame/timing summaries.
Whole-battle reachability and full Game Boy device lifting remain separate.

## Proof obligations

- [x] Decode all 87 effect IDs and all 86 pointer words from canonical ROM bytes (`Battle.Rom.Effects`).
- [x] Prove every table terminator, byte order, and membership against its ROM slice (`RequiredEffectBytes`).
- [x] Prove all move-record effect bytes are in the decoded range (`Battle.Rom.Mechanics.move_effects_indexed`).
- [x] Classify unused IDs even though no canonical move record selects them.
- [ ] Prove each direct special-case routine before treating a `NULL` pointer as behaviorally summarized.
- Preserve effect-byte/control-flow changes across Twineedle, Bide, Rage, Mirror Move, and Metronome paths.
- Preserve drain's in-place halving of shared `wDamage`, not only the HP heal.
- Preserve Rest's active status write without clearing Toxic flag/counter state.
- Preserve Conversion's invulnerability-only failure gate and lack of ordinary hit/Substitute checks.
- Preserve Explosion/Selfdestruct self-KO/status/seed writes before later hit failure.
- Preserve directly selected charge/Fly first-turn execution before PP decrement, unbound generated-charge continuation through the retained selected slot, and attack-turn interruption that can strand invulnerability.
- Preserve [stat modifier](stat-modifier-flow.md) exact-cap rollback, badge/status target matrix, and side-effect failure branches.
- Cover player and enemy control paths independently before factoring common high-level code.
