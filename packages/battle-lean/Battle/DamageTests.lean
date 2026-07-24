/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Damage

/-!
# Damage battery — hand-traced pokered scenarios

End-to-end `Battle.Damage.computeDamage` cases, each expected value derived by
hand from `engine/battle/core.asm` (see the derivation comment on every guard).
Together they exercise every branch of the pipeline: the base formula and its two
independent floors, the `+2` min and the base-only 997/999 caps, crit level-
doubling, STAB, super-effective / not-very / no-effect factors, dual-type ×4 and ×¼, the
¼×-rounds-to-zero miss, and the `[217,255]` roll (including a roll that drops a
2-damage hit to 1).

A failing `#guard` fails the build; this module is the executable proof that the
transcription in `Battle.Damage` reproduces the ROM's numbers.
-/

namespace Battle.DamageTests

open Battle.Damage Battle.TypeChart

/-- Terser `Attack` builder for the table below. Positional:
    `level power attack defense crit  moveType atk1 atk2  def1 def2`. -/
private def atk (level : UInt8) (power : UInt8) (attack defense : UInt16) (crit : Bool)
    (moveType a1 a2 d1 d2 : UInt8) : Attack :=
  { level, power, attack, defense, crit, moveType,
    atkType1 := a1, atkType2 := a2, defType1 := d1, defType2 := d2 }

/-! ## Neutral physical, STAB, crit -/

-- A: L50, 40 BP Normal (STAB), Atk 100, Def 80, neutral target, max roll.
--   base 22·40·100/80/50 = 22 → +2 = 24; STAB → 36; neutral; ×255/255 → 36.
#guard computeDamage (atk 50 40 100 80 false  normal normal normal  normal normal) 255 == 36
-- B: same, minimum roll 217:  floor(36·217/255) = 30.
#guard computeDamage (atk 50 40 100 80 false  normal normal normal  normal normal) 217 == 30
-- C: same as A but a critical hit doubles the level:
--   base floor(4·50/5)+2 = 42·40·100/80/50 = 42 → +2 = 44; STAB → 66; → 66.
#guard computeDamage (atk 50 40 100 80 true   normal normal normal  normal normal) 255 == 66

/-! ## Type effectiveness -/

-- D: L50 Water mon, 95 BP Water (STAB, special), off-stat 120 vs def-stat 70,
--    Fire target, max roll.
--   base 22·95·120 = 250800; /70 = 3582; /50 = 71; +2 = 73; STAB → 109; ×2 → 218.
#guard computeDamage (atk 50 95 120 70 false  water water water  fire fire) 255 == 218
-- E: L50 Rock mon, 75 BP Rock (STAB), Atk 100, Def 80, Fire/Flying target (×4).
--   base 22·75·100 = 165000; /80 = 2062; /50 = 41; +2 = 43; STAB → 64;
--   ×2 (fire) → 128; ×2 (flying) → 256.
#guard computeDamage (atk 50 75 100 80 false  rock rock rock  fire flying) 255 == 256
-- Immunity: Ground → Flying is ×0, so the move deals nothing and misses.
--   base 22·100·100/100/50 = 44 → +2 = 46; ×0 → 0.
#guard computeDamage (atk 50 100 100 100 false  ground ground ground  flying flying) 255 == 0
#guard missesByType ground ground ground flying flying
        (calcBaseDamage 50 false 100 100 100) == true

/-! ## Quarter-effective rounding to zero (a real miss) -/

-- F: a 2-damage Grass hit into a Grass/Poison target (×¼) floors to 0 → miss.
--   base floor(2·10/5)+2 = 6·10·20/200/50 = 0 → +2 = 2; ×½ → 1; ×½ → 0.
#guard computeDamage (atk 10 10 20 200 false  grass normal normal  grass poison) 255 == 0
#guard missesByType grass normal normal grass poison
        (calcBaseDamage 10 false 10 20 200) == true

/-! ## Caps and floors -/

-- G: the 997/999 cap is on the *base* only — STAB and type push the final higher.
--   crit base floor(4·100/5)+2 = 82·250·999/1/50 = 409590 → capped 997 → +2 = 999;
--   STAB → 1498; ×2 → 2996.
#guard computeDamage (atk 100 250 999 1 true  water water water  fire fire) 255 == 2996
-- Min floor: a hit that computes to 0 base still deals 2 before the roll…
--   (Fire attacker + Normal move ⇒ no STAB.) base 4·10·10/100/50 = 0 → +2 = 2; neutral → 2.
#guard computeDamage (atk 5 10 10 100 false  normal fire fire  water water) 255 == 2
-- …but the roll can still drop that 2 to 1: floor(2·217/255) = 1.
#guard computeDamage (atk 5 10 10 100 false  normal fire fire  water water) 217 == 1

/-! ## Zero-power short-circuit -/

-- A status/0-BP move never reaches the formula: 0 regardless of stats or roll.
#guard computeDamage (atk 50 0 250 1 true  water water water  fire fire) 255 == 0

end Battle.DamageTests
