/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Data.Species

/-!
# Generation-I critical-hit threshold

Clean-room transcription of `CriticalHitTest`. The initial base-Speed shift,
Focus Energy's wrong-direction shift, ordinary/high-critical move branches,
saturating shifts, three-bit RNG rotation, and strict comparison are all kept
separate so effect execution and compatibility proofs share one primitive.
-/

namespace Battle.Critical

/-- Gen-I's hardcoded high-critical move list. -/
def highCriticalMove (id : MoveId) : Bool :=
  id == 2 || id == 75 || id == 152 || id == 163

/-- `sla b` followed by `ld b,$ff` on carry. -/
def saturatingDouble (value : UInt8) : UInt8 :=
  if value.toNat ≥ 128 then 255 else value <<< 1

/-- Threshold after the initial `srl b` and the Focus Energy branch, before the
move-family branch. Focus Energy deliberately shifts right again. -/
def preMoveThreshold (baseSpeed : UInt8) (focusEnergy : Bool) : UInt8 :=
  let half := baseSpeed >>> 1
  if focusEnergy then half >>> 1 else saturatingDouble half

/-- Complete threshold. Ordinary moves halve once; high-critical moves perform
two saturating left shifts. -/
def thresholdFromSpeed (baseSpeed : UInt8) (highCritical focusEnergy : Bool) : UInt8 :=
  let rate := preMoveThreshold baseSpeed focusEnergy
  if highCritical then saturatingDouble (saturatingDouble rate) else rate >>> 1

/-- Species/move-facing threshold used by battle execution. -/
def threshold (species : SpeciesId) (move : MoveId) (focusEnergy : Bool := false) : UInt8 :=
  thresholdFromSpeed (Data.speciesData species).baseSpd (highCriticalMove move) focusEnergy

/-- Three `rlc a` instructions. -/
def rotateRandom (raw : UInt8) : UInt8 :=
  (raw <<< 3) ||| (raw >>> 5)

/-- Cartridge comparison: critical iff rotated random is strictly below `b`. -/
def occurs (threshold raw : UInt8) : Bool := rotateRandom raw < threshold

/-- An intended inclusive comparison differs from the cartridge exactly on the
rotated-byte boundary. -/
def occursInclusive (threshold raw : UInt8) : Bool := rotateRandom raw ≤ threshold

/-! ## Universal compatibility theorems -/

@[simp] theorem focus_branch_is_second_right_shift (baseSpeed : UInt8) :
    preMoveThreshold baseSpeed true = (baseSpeed >>> 1) >>> 1 := by
  simp [preMoveThreshold]

@[simp] theorem ordinary_branch_restores_even_speed (baseSpeed : UInt8) :
    preMoveThreshold baseSpeed false = (baseSpeed &&& 0xFE) := by
  have checked :
      (List.range 256).all (fun n =>
        preMoveThreshold n.toUInt8 false = (n.toUInt8 &&& 0xFE)) = true := by
    native_decide
  have atValue := (List.all_eq_true.mp checked) baseSpeed.toNat
    (List.mem_range.mpr (UInt8.toNat_lt baseSpeed))
  simpa using atValue

/-- Focus Energy never increases the resulting threshold, for either move
family and every byte-valued base Speed. -/
theorem focus_never_improves (baseSpeed : UInt8) (highCritical : Bool) :
    (thresholdFromSpeed baseSpeed highCritical true).toNat ≤
      (thresholdFromSpeed baseSpeed highCritical false).toNat := by
  have checked :
      (List.range 256).all (fun n =>
        [false, true].all (fun high =>
          (thresholdFromSpeed n.toUInt8 high true).toNat ≤
            (thresholdFromSpeed n.toUInt8 high false).toNat)) = true := by
    native_decide
  have atSpeed := (List.all_eq_true.mp checked) baseSpeed.toNat
    (List.mem_range.mpr (UInt8.toNat_lt baseSpeed))
  cases highCritical <;> simp_all

/-- Concrete canonical bug witness, independent of any fixture catalogue. -/
theorem focus_energy_witness :
    thresholdFromSpeed 4 false true = 0 ∧
    thresholdFromSpeed 4 false false = 2 := by
  native_decide

/-- The strict cartridge comparison and an inclusive intended comparison differ
iff the rotated random byte exactly equals the threshold. -/
theorem strict_boundary_iff (threshold raw : UInt8) :
    occurs threshold raw ≠ occursInclusive threshold raw ↔
      rotateRandom raw = threshold := by
  have checked :
      (List.range 256).all (fun t =>
        (List.range 256).all (fun r => decide
          (occurs t.toUInt8 r.toUInt8 ≠ occursInclusive t.toUInt8 r.toUInt8 ↔
            rotateRandom r.toUInt8 = t.toUInt8))) = true := by
    native_decide
  have atThreshold := (List.all_eq_true.mp checked) threshold.toNat
    (List.mem_range.mpr (UInt8.toNat_lt threshold))
  have atRaw := (List.all_eq_true.mp atThreshold) raw.toNat
    (List.mem_range.mpr (UInt8.toNat_lt raw))
  have round (value : UInt8) : value.toNat.toUInt8 = value := by
    apply UInt8.toNat.inj
    simp
  simpa only [round] using of_decide_eq_true atRaw

/-- Rotation is a byte permutation; applying the inverse five-bit rotation
recovers every raw byte. -/
theorem rotateRandom_inverse (raw : UInt8) :
    ((rotateRandom raw <<< 5) ||| (rotateRandom raw >>> 3)) = raw := by
  have checked := (by native_decide :
    (List.range 256).all (fun n =>
      ((rotateRandom n.toUInt8 <<< 5) ||| (rotateRandom n.toUInt8 >>> 3)) =
        n.toUInt8) = true)
  have atRaw := (List.all_eq_true.mp checked) raw.toNat
    (List.mem_range.mpr (UInt8.toNat_lt raw))
  simpa using atRaw

#guard threshold 153 33 false == 22
#guard threshold 153 75 false == 176
#guard threshold 84 163 false == 255
#guard threshold 153 33 true == 5

end Battle.Critical
