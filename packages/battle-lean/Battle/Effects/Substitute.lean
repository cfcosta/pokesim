/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.State

/-!
# Substitute

Exact HP/carry core of `SubstituteEffect_`. The quarter-max-HP cost is computed
as a 16-bit value but only its low byte is retained. The affordability branch
checks subtraction carry only, so exact payment succeeds and leaves zero HP.
-/

namespace Battle.Effects.Substitute

/-- Low byte retained after two 16-bit right shifts. -/
def costNat (maxHp : UInt16) : Nat := maxHp.toNat / 4 % 256

def cost (maxHp : UInt16) : UInt8 := costNat maxHp |>.toUInt8

inductive Result where
  | alreadyPresent
  | insufficientHp
  | created (remainingHp : UInt16) (substituteHp : UInt8)
  deriving Repr, DecidableEq, BEq

/-- Execute the HP-visible part. Exact subtraction is accepted because no zero
flag check follows the carry check. -/
def use (alreadyPresent : Bool) (currentHp maxHp : UInt16) : Result :=
  if alreadyPresent then .alreadyPresent
  else
    let subHp := cost maxHp
    if currentHp.toNat < subHp.toNat then .insufficientHp
    else .created (UInt16.ofNat (currentHp.toNat - subHp.toNat)) subHp

/-! ## Universal compatibility theorems -/

/-- Under the routine's documented `maxHp ≤ 1023` precondition, the retained
byte is exactly mathematical quarter HP. -/
theorem cost_toNat_of_bounded (maxHp : UInt16) (bounded : maxHp.toNat ≤ 1023) :
    (cost maxHp).toNat = maxHp.toNat / 4 := by
  simp [cost, costNat]
  omega

/-- In the canonical HP range, zero-cost Substitute occurs exactly below four
maximum HP. -/
theorem zero_cost_iff (maxHp : UInt16) (bounded : maxHp.toNat ≤ 1023) :
    cost maxHp = 0 ↔ maxHp.toNat < 4 := by
  rw [← UInt8.toNat_inj]
  simp only [UInt8.toNat_zero]
  rw [cost_toNat_of_bounded maxHp bounded]
  omega

/-- Paying exactly the cost creates the Substitute and leaves the user at zero,
provided no Substitute was already active. -/
theorem equality_leaves_zero (maxHp : UInt16) :
    use false (UInt16.ofNat (cost maxHp).toNat) maxHp =
      .created 0 (cost maxHp) := by
  simp [use]

/-- A zero-cost malformed state creates a zero-HP Substitute without changing
positive current HP. -/
theorem zero_cost_is_free (currentHp maxHp : UInt16)
    (zero : cost maxHp = 0) :
    use false currentHp maxHp = .created currentHp 0 := by
  simp [use, zero]

/-- Carry rejection is exact: it occurs iff current HP is strictly below the
retained cost. -/
theorem insufficient_iff (currentHp maxHp : UInt16) :
    use false currentHp maxHp = .insufficientHp ↔
      currentHp.toNat < (cost maxHp).toNat := by
  simp [use]

#guard cost 100 == 25
#guard cost 3 == 0
#guard use false 25 100 == .created 0 25

end Battle.Effects.Substitute
