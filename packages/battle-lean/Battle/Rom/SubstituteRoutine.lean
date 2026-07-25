/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Rom.HealRoutine
import Battle.Effects.Substitute

/-!
# Decoded Substitute HP arithmetic

The handler shifts the two max-HP bytes twice, retains only the low cost byte,
and subtracts that byte from current HP. This module proves that arithmetic
matches the independent Substitute model, including exact-payment zero HP and
malformed zero-cost states.
-/

namespace Battle.Rom.SubstituteRoutine

open Sm83 Battle.Rom.Closure

private def entry : UInt16 := 0x7DAD
private def mechanicsBytes : List Byte :=
  [0x0E, 0x32, 0xCD, 0x39, 0x37, 0x21, 0x23, 0xD0, 0x11,
   0xD7, 0xCC, 0x01, 0x63, 0xD0, 0xF0, 0xF3, 0xA7, 0x28,
   0x09, 0x21, 0xF4, 0xCF, 0x11, 0xD8, 0xCC, 0x01, 0x68,
   0xD0, 0x0A, 0xCB, 0x67, 0x20, 0x44, 0xC5, 0x2A, 0x46,
   0xCB, 0x3F, 0xCB, 0x18, 0xCB, 0x3F, 0xCB, 0x18, 0xD5,
   0x11, 0xF2, 0xFF, 0x19, 0xD1, 0x78, 0x12, 0x3A, 0x90,
   0x57, 0x7E, 0xDE, 0x00, 0xC1, 0x38, 0x2D]

/-- Low cost byte produced by `SRL A; RR B` twice. -/
def decodedCost (maximum : UInt16) : UInt8 :=
  let high1 := Alu.rotate .srl (Word.highByte maximum.toBitVec) false
  let low1 := Alu.rotate .rr (Word.lowByte maximum.toBitVec) high1.flags.c
  let high2 := Alu.rotate .srl high1.value low1.flags.c
  let low2 := Alu.rotate .rr low1.value high2.flags.c
  low2.value.toNat.toUInt8

private def costExhaustive : Bool :=
  (List.range 65536).all fun maximum =>
    decodedCost maximum.toUInt16 == Effects.Substitute.cost maximum.toUInt16

private theorem cost_exhaustive_checked : costExhaustive = true := by native_decide

/-- The decoded shifts retain exactly the model's `floor(maxHP/4) mod 256`. -/
theorem decoded_cost_exact (maximum : UInt16) :
    decodedCost maximum = Effects.Substitute.cost maximum := by
  have rows := List.all_eq_true.mp cost_exhaustive_checked
  have row := rows maximum.toNat (List.mem_range.mpr (UInt16.toNat_lt maximum))
  have round : maximum.toNat.toUInt16 = maximum := by
    apply UInt16.toNat.inj
    simp
  simpa [costExhaustive, round] using row

/-- Carry surviving the low-byte `SUB` and high-byte `SBC 0`. -/
def decodedAffordable (current maximum : UInt16) : Bool :=
  let cost := decodedCost maximum
  let low := Alu.sub8 (Word.lowByte current.toBitVec) cost.toBitVec
  !(Alu.sub8 (Word.highByte current.toBitVec) 0 low.flags.c).flags.c

private theorem hp_decompose (value : UInt16) :
    value.toNat = (Word.highByte value.toBitVec).toNat * 256 +
      (Word.lowByte value.toBitVec).toNat := by
  simp only [Word.highByte, Word.lowByte, BitVec.extractLsb_toNat,
    UInt16.toNat_toBitVec]
  simp only [Nat.reduceSub, Nat.reduceAdd, Nat.reducePow, Nat.shiftRight_zero]
  rw [Nat.shiftRight_eq_div_pow]
  simp only [Nat.reducePow]
  have bounded := UInt16.toNat_lt value
  omega

/-- The decoded carry accepts exactly current HP greater than or equal to the
retained cost. Equality therefore creates a zero-HP Substitute. -/
theorem decoded_affordability_exact (current maximum : UInt16) :
    decodedAffordable current maximum =
      decide (current.toNat ≥ (Effects.Substitute.cost maximum).toNat) := by
  have costExact := decoded_cost_exact maximum
  have costValue : (decodedCost maximum).toNat =
      (Effects.Substitute.cost maximum).toNat := congrArg UInt8.toNat costExact
  have currentValue := hp_decompose current
  have currentLowBound := BitVec.isLt (Word.lowByte current.toBitVec)
  have currentHighBound := BitVec.isLt (Word.highByte current.toBitVec)
  have costBound := UInt8.toNat_lt (decodedCost maximum)
  by_cases lowBorrow :
      (Word.lowByte current.toBitVec).toNat < (decodedCost maximum).toNat
  · simp only [decodedAffordable, Alu.sub8, Alu.carryNat]
    simp [lowBorrow]
    rw [Bool.eq_iff_iff]
    simp
    omega
  · simp only [decodedAffordable, Alu.sub8, Alu.carryNat]
    simp [lowBorrow]
    omega

/-- Decoded arithmetic derives the model's zero-HP equality bug. -/
theorem decoded_equality_leaves_zero (maximum : UInt16) :
    Effects.Substitute.use false
      (UInt16.ofNat (decodedCost maximum).toNat) maximum =
        .created 0 (decodedCost maximum) := by
  rw [decoded_cost_exact]
  exact Effects.Substitute.equality_leaves_zero maximum

structure RequiredSubstituteBytes (rom : Array Byte) : Prop where
  mechanicsWindow : Tables.tableBytes rom
      (romOffset 0x05 (Word.ofNat entry.toNat)) mechanicsBytes.length =
    mechanicsBytes.map (fun byte => byte.toNat.toUInt8)

structure CanonicalSubstituteBytes (sha256 : Sha256) (rom : CanonicalRom) : Prop where
  healing : HealRoutine.CanonicalHealBytes sha256 rom
  substitute : RequiredSubstituteBytes rom.bytes

/-- Conditional ROM window paired with universal decoded HP arithmetic. -/
theorem canonical_substitute_arithmetic_exact {sha256 : Sha256} {rom : CanonicalRom}
    (certificate : CanonicalSubstituteBytes sha256 rom) :
    Tables.tableBytes rom.bytes
        (romOffset 0x05 (Word.ofNat entry.toNat)) mechanicsBytes.length =
          mechanicsBytes.map (fun byte => byte.toNat.toUInt8) ∧
      (∀ maximum, decodedCost maximum = Effects.Substitute.cost maximum) ∧
      ∀ current maximum, decodedAffordable current maximum =
        decide (current.toNat ≥ (Effects.Substitute.cost maximum).toNat) :=
  ⟨certificate.substitute.mechanicsWindow, decoded_cost_exact,
    decoded_affordability_exact⟩

/-- Runtime fixture predicate only. -/
def windowAgrees (rom : Array Byte) : Bool :=
  decide (Tables.tableBytes rom
      (romOffset 0x05 (Word.ofNat entry.toNat)) mechanicsBytes.length =
    mechanicsBytes.map (fun byte => byte.toNat.toUInt8))

end Battle.Rom.SubstituteRoutine
