/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.State

/-!
# Recover, Softboiled, and Rest HP core

`HealEffect_` compares high bytes only to establish borrow, subtracts low bytes
with that borrow, and branches solely on the final zero flag. This deliberately
retains false failures at `256k-1` HP gaps.
-/

namespace Battle.Effects.Healing

private def highByte (hp : UInt16) : Nat := hp.toNat / 256
private def lowByte (hp : UInt16) : Nat := hp.toNat % 256

/-- The routine's `cp high; sbc low; jp z` predicate. -/
def checkFails (currentHp maxHp : UInt16) : Bool :=
  let borrow := if highByte currentHp < highByte maxHp then 1 else 0
  let lowResult := (lowByte currentHp + 256 - lowByte maxHp - borrow) % 256
  lowResult == 0

inductive Kind where
  | recover
  | softboiled
  | rest
  deriving Repr, DecidableEq, BEq

inductive Result where
  | failed
  | healed (hp : UInt16) (clearStatusAndSleepTwo : Bool)
  deriving Repr, DecidableEq, BEq

private def healAmount (kind : Kind) (maxHp : UInt16) : Nat :=
  match kind with
  | .rest => maxHp.toNat
  | .recover | .softboiled => maxHp.toNat / 2

/-- HP-visible routine result. Rest additionally marks its status rewrite. -/
def use (kind : Kind) (currentHp maxHp : UInt16) : Result :=
  if checkFails currentHp maxHp then .failed
  else
    let hp := UInt16.ofNat (min (currentHp.toNat + healAmount kind maxHp) maxHp.toNat)
    .healed hp (kind == .rest)

/-! ## Compatibility theorems -/

/-- Full HP is always rejected. -/
theorem full_hp_fails (hp : UInt16) : checkFails hp hp = true := by
  simp [checkFails, highByte, lowByte]

/-- Rest fails at full HP before its caller can perform the fixed sleep/status
write. -/
theorem rest_full_hp_fails (hp : UInt16) : use .rest hp hp = .failed := by
  simp [use, full_hp_fails]

/-- Every accepted Rest request heals to max HP and requests the cartridge's
whole-status-byte sleep value of two. -/
theorem rest_success_exact (currentHp maxHp : UInt16)
    (accepted : checkFails currentHp maxHp = false) :
    use .rest currentHp maxHp = .healed maxHp true := by
  have restSelf : (Kind.rest == Kind.rest) = true := by native_decide
  simp [use, accepted, healAmount, restSelf]

/-- In the canonical ≤999 HP domain, every false failure has exactly one of the
three `256k-1` gaps. -/
theorem false_failure_gaps (currentHp maxHp : UInt16)
    (ordered : currentHp.toNat ≤ maxHp.toNat)
    (bounded : maxHp.toNat ≤ 999)
    (notFull : currentHp ≠ maxHp)
    (fails : checkFails currentHp maxHp = true) :
    maxHp.toNat - currentHp.toNat = 255 ∨
    maxHp.toNat - currentHp.toNat = 511 ∨
    maxHp.toNat - currentHp.toNat = 767 := by
  have checked := (by native_decide :
    ∀ current : Fin 1000, ∀ maximum : Fin 1000,
      current.val ≤ maximum.val → current.val ≠ maximum.val →
      checkFails (UInt16.ofNat current.val) (UInt16.ofNat maximum.val) = true →
      maximum.val - current.val = 255 ∨
      maximum.val - current.val = 511 ∨
      maximum.val - current.val = 767)
  have currentBound : currentHp.toNat < 1000 := by omega
  have maxBound : maxHp.toNat < 1000 := by omega
  have round (value : UInt16) : UInt16.ofNat value.toNat = value := by
    apply UInt16.toNat.inj
    simp
  have distinctNat : currentHp.toNat ≠ maxHp.toNat := by
    intro equal
    apply notFull
    exact UInt16.toNat.inj equal
  have fails' :
      checkFails (UInt16.ofNat currentHp.toNat) (UInt16.ofNat maxHp.toNat) = true := by
    simpa only [round] using fails
  exact checked ⟨currentHp.toNat, currentBound⟩
    ⟨maxHp.toNat, maxBound⟩ ordered distinctNat fails'

/-- Below 256 max HP, the predicate has no false failures. -/
theorem no_false_failure_below_256 (currentHp maxHp : UInt16)
    (ordered : currentHp.toNat ≤ maxHp.toNat)
    (bounded : maxHp.toNat < 256)
    (fails : checkFails currentHp maxHp = true) : currentHp = maxHp := by
  have currentBound : currentHp.toNat < 256 := by omega
  have checked := (by native_decide :
    ∀ current : Fin 256, ∀ maximum : Fin 256,
      current.val ≤ maximum.val →
      checkFails (UInt16.ofNat current.val) (UInt16.ofNat maximum.val) = true →
      current.val = maximum.val)
  have round (value : UInt16) : UInt16.ofNat value.toNat = value := by
    apply UInt16.toNat.inj
    simp
  have fails' :
      checkFails (UInt16.ofNat currentHp.toNat) (UInt16.ofNat maxHp.toNat) = true := by
    simpa only [round] using fails
  apply UInt16.toNat.inj
  exact checked ⟨currentHp.toNat, currentBound⟩ ⟨maxHp.toNat, bounded⟩ ordered fails'

/-- Three independent reachable witnesses. -/
theorem false_failure_witnesses :
    checkFails 45 300 = true ∧
    checkFails 89 600 = true ∧
    checkFails 232 999 = true := by
  native_decide

/-- The executable effect delegates failure exactly to the buggy predicate. -/
theorem use_fails_iff (kind : Kind) (currentHp maxHp : UInt16) :
    use kind currentHp maxHp = .failed ↔ checkFails currentHp maxHp = true := by
  simp [use]

#guard checkFails 45 300
#guard checkFails 89 600
#guard !checkFails 46 300
#guard use .recover 100 200 == .healed 200 false
#guard use .rest 1 200 == .healed 200 true

end Battle.Effects.Healing
