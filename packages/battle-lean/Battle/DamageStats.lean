/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Basic

/-!
# Damage-stat selection, screen overflow, and badge stacking

Clean-room numeric core of both `GetDamageVars…Attack` routines and
`ApplyBadgeStatBoosts`. If either selected stat has a nonzero high byte, both
are shifted right twice and only their low bytes survive. Offensive zero is
bumped to one; defensive zero is preserved as explicit division freeze.
-/

namespace Battle.DamageStats

/-- Two 16-bit right shifts followed by retaining only the low byte. -/
def scaleToByte (stat : UInt16) : UInt8 := (stat.toNat / 4 % 256).toUInt8

structure ScaledPair where
  attack : UInt8
  defense : UInt8
  deriving Repr, DecidableEq, BEq

/-- Scale both stats iff either has a nonzero high byte. -/
def scalePair (attack defense : UInt16) : ScaledPair :=
  if attack.toNat ≤ 255 && defense.toNat ≤ 255 then
    { attack := attack.toNat.toUInt8, defense := defense.toNat.toUInt8 }
  else
    let scaledAttack := scaleToByte attack
    { attack := if scaledAttack == 0 then 1 else scaledAttack
      defense := scaleToByte defense }

inductive Result where
  | ready (stats : ScaledPair)
  | divisionFreeze (stats : ScaledPair)
  deriving Repr, DecidableEq, BEq

/-- Apply uncapped 16-bit Reflect/Light-Screen doubling before scaling. -/
def resolve (attack defense : UInt16) (screen : Bool) : Result :=
  let defense := if screen then defense <<< 1 else defense
  let stats := scalePair attack defense
  if stats.defense == 0 then .divisionFreeze stats else .ready stats

/-- One badge reapplication: 9/8 with integer truncation, capped at 999. -/
def badgeBoost (stat : UInt16) : UInt16 :=
  UInt16.ofNat (min (stat.toNat + stat.toNat / 8) 999)

/-- Repeated reapplication after unrelated stat changes. -/
def badgeBoostN : Nat → UInt16 → UInt16
  | 0, stat => stat
  | count + 1, stat => badgeBoostN count (badgeBoost stat)

/-- Badge reapplication followed by optional uncapped screen and damage scaling. -/
def badgeScreenPipeline (attack defense : UInt16) (applications : Nat)
    (screen : Bool) : Result :=
  resolve attack (badgeBoostN applications defense) screen

/-! ## Universal compatibility theorems -/

/-- Exact low-byte wrap characterization for every 16-bit input. -/
theorem scaleToByte_exact (stat : UInt16) :
    (scaleToByte stat).toNat = stat.toNat / 4 % 256 := by
  simp [scaleToByte]

/-- Offensive zero is repaired whenever the scaling branch is active. -/
theorem scaled_attack_nonzero (attack defense : UInt16)
    (scaling : ¬(attack.toNat ≤ 255 && defense.toNat ≤ 255)) :
    (scalePair attack defense).attack ≠ 0 := by
  simp [scalePair, scaling]
  split <;> simp_all

/-- Defensive values 1..3 become zero when another stat triggers scaling. -/
theorem low_defense_freezes :
    resolve 256 1 false = .divisionFreeze { attack := 64, defense := 0 } ∧
    resolve 256 2 false = .divisionFreeze { attack := 64, defense := 0 } ∧
    resolve 256 3 false = .divisionFreeze { attack := 64, defense := 0 } ∧
    resolve 256 4 false = .ready { attack := 64, defense := 1 } := by
  native_decide

/-- Reflect/Light Screen at defense 512 reaches divisor zero; without the screen
it remains 128. -/
theorem screen_512_freezes :
    resolve 300 512 true = .divisionFreeze { attack := 75, defense := 0 } ∧
    resolve 300 512 false = .ready { attack := 75, defense := 128 } := by
  native_decide

/-- Above the wrap boundary a screen can reduce, rather than increase, effective
defense. -/
theorem screen_hurts_696 :
    resolve 300 696 false = .ready { attack := 75, defense := 174 } ∧
    resolve 300 696 true = .ready { attack := 75, defense := 92 } := by
  native_decide

/-- Badge boost stacking progression from the externally highlighted canonical
arithmetic witness. -/
theorem badge_progression :
    badgeBoostN 0 458 = 458 ∧ badgeBoostN 1 458 = 515 ∧
    badgeBoostN 2 458 = 579 ∧ badgeBoostN 3 458 = 651 ∧
    badgeBoostN 4 458 = 732 ∧ badgeBoostN 5 458 = 823 ∧
    badgeBoostN 6 458 = 925 ∧ badgeBoostN 7 458 = 999 := by
  native_decide

/-- One reapplication plus Reflect wraps effective defense to one. -/
theorem badge_screen_catastrophe :
    badgeScreenPipeline 300 458 1 false =
      .ready { attack := 75, defense := 128 } ∧
    badgeScreenPipeline 300 458 1 true =
      .ready { attack := 75, defense := 1 } := by
  native_decide

/-- A nearby defense value reaches the explicit freeze result. -/
theorem badge_screen_freeze :
    badgeScreenPipeline 300 456 1 true =
      .divisionFreeze { attack := 75, defense := 0 } := by
  native_decide

#guard scaleToByte 1023 == 255
#guard scaleToByte 1024 == 0
#guard badgeBoost 458 == 515

end Battle.DamageStats
