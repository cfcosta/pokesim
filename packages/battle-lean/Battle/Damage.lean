/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.TypeChart
import Battle.DamageStats

/-!
# Damage calculation

The Gen-1 damage pipeline, transcribed 1:1 from `pret/pokered` at commit
`405b6246372d7e5a2cb029cbb65219b13286b8c9`, `engine/battle/core.asm`. The main
attack flow runs, in order:

```
CriticalHitTest                 ; sets wCriticalHitOrOHKO
GetDamageVarsFor{Player,Enemy}Attack  ; picks/scales stats, doubles level if crit
CalculateDamage                 ; the base-damage formula          (asm 4299)
AdjustDamageForMoveType         ; STAB, then the type-effect fold   (asm 5075)
RandomizeDamage                 ; ×[217,255]/255, if damage ≥ 2     (asm 5410)
```

This module models the **numeric pipeline** given *resolved* inputs. Stat
selection (physical vs special via `SPECIAL`), stat-stage modifiers, the crit
reset to unmodified stats, Reflect/Light-Screen doubling, and the `/4`
overflow-scaling all happen in `GetDamageVars` and depend on battle state;
`Battle.DamageStats` implements the exact screen/scaling/freeze boundary and the
turn layer feeds its resolved bytes here. What `crit` controls *here* is only the
level-doubling inside the formula.

Out of scope for this module (effect-gated branches inside `CalculateDamage`,
deferred to the effects layer): `EXPLODE_EFFECT` halving the defender's defence,
`OHKO_EFFECT`, and the multi-hit / `EFFECT_1E` zero-power skip. This is the
ordinary damaging-move path.

## Numeric fidelity (SPEC §8.1)

* Two **separate** floored divisions — `/Defense` then `/50` — never one
  `/(Defense·50)`; the ROM floors after each.
* `UInt16` carries the running damage through STAB, type, and randomisation
  because the ROM stores it in a 16-bit slot (`wDamage`) and its ops wrap/
  truncate to 16 bits there. Wide products are formed in `Nat` (the ROM's 32-bit
  math buffer) and truncated back with `UInt16.ofNat`, matching "store the low
  two bytes of the quotient".
* The base value is capped at `MAX_NEUTRAL_DAMAGE - MIN_NEUTRAL_DAMAGE = 997`
  before `+2`, so it lands in `[2, 999]`.
* `defense = 0` is the ROM's division-by-zero **freeze** (reachable via the `/4`
  scaling bug). `divisorFreezes` flags it; `calcBaseDamage` otherwise follows
  Lean's `n / 0 = 0` convention, which is *not* what the hardware does — callers
  must treat a freeze as its own outcome.

## Provenance

Formula transcribed from the named ASM. The `TypeEffects` data it folds over is
`Battle.TypeChart`'s (hand-transcribed pending GPT's ROM-decoded `Rom/Tables`;
see `COORDINATION.md` seam 3).
-/

namespace Battle.Damage

/-! ## Constants (`constants/battle_constants.asm:47-48`) -/

/-- `MIN_NEUTRAL_DAMAGE` — the `+2` floor every damaging hit gets. -/
def minNeutralDamage : Nat := 2
/-- `MAX_NEUTRAL_DAMAGE` — the 999 cap on base damage. -/
def maxNeutralDamage : Nat := 999

/-- `defense = 0` makes `CalculateDamage` divide by zero and hang the hardware.
    Real (reachable via the `/4` scaling bug); model it as its own outcome. -/
def divisorFreezes (defense : UInt16) : Bool := defense == 0

/-! ## `CalculateDamage` (`engine/battle/core.asm:4299`) -/

/-- Base damage: `((floor(2·L/5) + 2) · Power · Attack) / Defense / 50`, floored
    after each division, capped at 997, then `+ 2` — landing in `[2, 999]`.

    `level` is the attacker's level; `crit` doubles it first (`sla e`, an 8-bit
    shift, so it wraps past 128 exactly as the hardware does). `attack`/`defense`
    are the already-resolved offensive/defensive stats — for a crit the caller
    passes the *unmodified* stats, since crits ignore stat stages and screens.

    Intermediates are exact in `Nat`: for legal inputs the product never exceeds
    the ROM's 32-bit math buffer, so no wrap occurs before the caps.

    Zero power returns 0 — `CalculateDamage`'s early `ret z` leaves `wDamage` at
    its zeroed value and never runs the formula (so no `+2` floor applies). -/
def calcBaseDamage (level : UInt8) (crit : Bool) (power : UInt8)
    (attack defense : UInt16) : UInt16 :=
  if power == 0 then
    0
  else
    let e : Nat := (if crit then level <<< 1 else level).toNat  -- sla e (8-bit)
    let lvlTerm : Nat := 2 * e / 5 + 2                          -- floor(2L/5)+2
    let numer : Nat := lvlTerm * power.toNat * attack.toNat
    let afterDef : Nat := numer / defense.toNat                 -- floor(/Defense)
    let afterFifty : Nat := afterDef / 50                       -- floor(/50)
    let capped : Nat := min afterFifty (maxNeutralDamage - minNeutralDamage)
    UInt16.ofNat (min (capped + minNeutralDamage) maxNeutralDamage)

/-! ## `AdjustDamageForMoveType` (`engine/battle/core.asm:5075`) -/

/-- STAB then the type-effectiveness fold, on the 16-bit running damage.

    STAB (`moveType` is one of the attacker's types) multiplies by `3/2` first,
    as `damage + damage>>1` in 16-bit arithmetic. Then each `TypeEffects` entry
    whose attacker type is `moveType` and whose defender type is *either* of the
    defender's types multiplies damage by `factor/10`, **in table order**, with
    the product formed wide and the quotient truncated to 16 bits. A dual-type
    defender that matches two rows is multiplied twice (the 4× / ¼× cases).

    When the result reaches 0 (a `NO_EFFECT` row, or a `¼×` rounding a 2–3 damage
    hit down to nothing) the ROM makes the move miss; see `missesByType`. -/
def adjustDamageForType (moveType atkType1 atkType2 defType1 defType2 : UInt8)
    (damage : UInt16) : UInt16 :=
  let stabbed : UInt16 :=
    if moveType == atkType1 || moveType == atkType2 then
      damage + (damage >>> 1)
    else
      damage
  TypeChart.typeEffects.foldl
    (fun d entry =>
      let (atk, defTy, factor) := entry
      if moveType == atk && (defTy == defType1 || defTy == defType2) then
        UInt16.ofNat (d.toNat * factor.toNat / 10)
      else
        d)
    stabbed

/-- True when the type interaction zeroes a would-be-nonzero hit — i.e. the move
    misses by immunity or by a `¼×` roll-to-zero. -/
def missesByType (moveType atkType1 atkType2 defType1 defType2 : UInt8)
    (base : UInt16) : Bool :=
  base != 0 && adjustDamageForType moveType atkType1 atkType2 defType1 defType2 base == 0

/-! ## `RandomizeDamage` (`engine/battle/core.asm:5410`) -/

/-- Multiply by the accepted roll `rand ∈ [217, 255]` and divide by 255 (floored,
    16-bit). Damage of 0 or 1 is returned unchanged (`cp 2; ret c`). Deriving
    `rand` from `BattleRandom` (rotate-right then reject `< 217`) — and the RNG
    draws it costs — belongs to the RNG/turn layer. -/
def randomizeDamage (rand : UInt8) (damage : UInt16) : UInt16 :=
  if damage < 2 then
    damage
  else
    UInt16.ofNat (damage.toNat * rand.toNat / 255)

/-! ## End-to-end -/

/-- The resolved inputs to one damaging hit: stats already selected/scaled, types
    for STAB and the effectiveness fold. -/
structure Attack where
  level    : UInt8
  power    : UInt8
  attack   : UInt16
  defense  : UInt16
  crit     : Bool
  moveType : UInt8
  atkType1 : UInt8
  atkType2 : UInt8
  defType1 : UInt8
  defType2 : UInt8
  deriving Repr, DecidableEq

/-- Run the whole pipeline for one hit and return the inflicted damage. A
    zero-power move deals 0 and skips type/randomisation (`CalculateDamage`'s
    early `ret z`). A result of 0 from a nonzero-power move means the move missed
    by type (`missesByType`). -/
def computeDamage (a : Attack) (rand : UInt8) : UInt16 :=
  if a.power == 0 then
    0
  else
    let base := calcBaseDamage a.level a.crit a.power a.attack a.defense
    let typed := adjustDamageForType a.moveType a.atkType1 a.atkType2 a.defType1 a.defType2 base
    randomizeDamage rand typed

/-! ## Fidelity guards

Base-formula spot checks (all hand-derived; `rand = 255` and neutral, no-STAB
types make `computeDamage` collapse to the base value). -/

-- L50, 40 BP, 100 atk / 100 def, no crit:  floor(2·50/5)+2 = 22; 22·40·100/100/50 = 17; +2 = 19.
#guard calcBaseDamage 50 false 40 100 100 == 19
-- Same, crit doubles the level: floor(4·50/5)+2 = 42; 42·40·100/100/50 = 33; +2 = 35.
#guard calcBaseDamage 50 true 40 100 100 == 35
-- Zero power hits CalculateDamage's early return (wDamage stays 0).
#guard calcBaseDamage 50 false 0 100 100 == 0
-- Higher level / power, showing the two independent floors:
--   42·80·200 = 672000; /150 = 4480; /50 = 89; +2 = 91.
#guard calcBaseDamage 100 false 80 200 150 == 91

-- STAB is +50%, floored, 16-bit.
#guard adjustDamageForType TypeChart.normal TypeChart.normal TypeChart.normal
        TypeChart.water TypeChart.water 19 == 28            -- 19 + 9
-- Super-effective doubles; not-very halves (floored); immunity zeroes.
#guard adjustDamageForType TypeChart.water TypeChart.water TypeChart.water
        TypeChart.fire TypeChart.fire 19 == 56              -- Water STAB (19→28), ×2 → 56
#guard adjustDamageForType TypeChart.fire TypeChart.fire TypeChart.fire
        TypeChart.water TypeChart.water 100 == 75           -- STAB 150, ×0.5 → 75
#guard adjustDamageForType TypeChart.normal TypeChart.fighting TypeChart.fighting
        TypeChart.ghost TypeChart.ghost 50 == 0             -- Normal→Ghost immunity
-- Dual weakness stacks to 4× (two matching rows, in table order).
#guard adjustDamageForType TypeChart.rock TypeChart.rock TypeChart.rock
        TypeChart.fire TypeChart.flying 20 == 120           -- STAB 30, ×2 (fire) ×2 (flying)

-- Randomisation: max roll is a no-op of the /255; 0/1 pass through.
#guard randomizeDamage 255 100 == 100
#guard randomizeDamage 217 100 == 85                        -- floor(100·217/255)
#guard randomizeDamage 230 1 == 1

-- Miss-by-type predicate.
#guard missesByType TypeChart.normal TypeChart.fighting TypeChart.fighting
        TypeChart.ghost TypeChart.ghost 50 == true
#guard missesByType TypeChart.water TypeChart.water TypeChart.water
        TypeChart.fire TypeChart.fire 19 == false

-- End-to-end: zero power deals nothing.
#guard computeDamage
  { level := 50, power := 0, attack := 100, defense := 100, crit := false,
    moveType := TypeChart.normal, atkType1 := TypeChart.normal, atkType2 := TypeChart.normal,
    defType1 := TypeChart.water, defType2 := TypeChart.water } 255 == 0

end Battle.Damage
