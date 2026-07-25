/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Rom.ScreenRoutine
import Battle.Effects.Healing

/-!
# Decoded healing failure comparison

Recover, Softboiled, and Rest share a buggy two-byte HP comparison. The high-byte
`CP` contributes only borrow to the low-byte `SBC`; the branch consults only the
final zero flag. This module proves that decoded arithmetic is exactly the
independent executable healing predicate for all 2^32 HP/max-HP pairs.
-/

namespace Battle.Rom.HealRoutine

open Sm83 Battle.Rom.Closure

private def entry : UInt16 := 0x79EC
private def comparisonBytes : List Byte :=
  [0xF0, 0xF3, 0xA7, 0x11, 0x15, 0xD0, 0x21, 0x23, 0xD0,
   0xFA, 0xD2, 0xCF, 0x28, 0x09, 0x11, 0xE6, 0xCF, 0x21,
   0xF4, 0xCF, 0xFA, 0xCC, 0xCF, 0x47, 0x1A, 0xBE, 0x13,
   0x23, 0x1A, 0x9E, 0xCA, 0x97, 0x7A]

/-- Zero flag produced by the handler's high-byte `CP` and low-byte `SBC`. -/
def decodedCheckFails (current maximum : UInt16) : Bool :=
  let high := Alu.sub8 (Word.highByte current.toBitVec)
    (Word.highByte maximum.toBitVec)
  (Alu.sub8 (Word.lowByte current.toBitVec) (Word.lowByte maximum.toBitVec)
    high.flags.c).flags.z

private theorem high_byte_toNat (value : UInt16) :
    (Word.highByte value.toBitVec).toNat = value.toNat / 256 := by
  simp only [Word.highByte, BitVec.extractLsb_toNat, UInt16.toNat_toBitVec]
  simp only [Nat.reduceSub, Nat.reduceAdd, Nat.reducePow]
  rw [Nat.shiftRight_eq_div_pow]
  simp only [Nat.reducePow]
  have bounded := UInt16.toNat_lt value
  omega

private theorem low_byte_toNat (value : UInt16) :
    (Word.lowByte value.toBitVec).toNat = value.toNat % 256 := by
  simp [Word.lowByte, BitVec.extractLsb_toNat, UInt16.toNat_toBitVec]

/-- Universal decoded-ROM arithmetic agreement with the independent healing
model, including the legitimate `256k-1` false-failure gaps. -/
theorem decoded_check_fails_exact (current maximum : UInt16) :
    decodedCheckFails current maximum =
      Effects.Healing.checkFails current maximum := by
  change decodedCheckFails current maximum =
    ((current.toNat % 256 + 256 - maximum.toNat % 256 -
      (if current.toNat / 256 < maximum.toNat / 256 then 1 else 0)) % 256 == 0)
  have currentHighBound := BitVec.isLt (Word.highByte current.toBitVec)
  have currentLowBound := BitVec.isLt (Word.lowByte current.toBitVec)
  have maximumHighBound := BitVec.isLt (Word.highByte maximum.toBitVec)
  have maximumLowBound := BitVec.isLt (Word.lowByte maximum.toBitVec)
  simp only [decodedCheckFails, Alu.sub8, Alu.carryNat,
    high_byte_toNat, low_byte_toNat]
  by_cases borrow : current.toNat / 256 < maximum.toNat / 256
  · simp [borrow]
    have currentLow := Nat.mod_lt current.toNat (by omega : 0 < 256)
    have maximumLow := Nat.mod_lt maximum.toNat (by omega : 0 < 256)
    have rearrange : current.toNat % 256 + 256 - maximum.toNat % 256 - 1 =
        current.toNat % 256 + 255 - maximum.toNat % 256 := by omega
    rw [rearrange]
    simp [Byte.ofNat]
    rw [Bool.eq_iff_iff]
    simp
  · simp [borrow, Byte.ofNat]
    rw [Bool.eq_iff_iff]
    simp

/-- The three reachable canonical-domain false failures are inherited directly
from the decoded comparison rather than merely copied into the model. -/
theorem decoded_false_failure_witnesses :
    decodedCheckFails 45 300 = true ∧
    decodedCheckFails 89 600 = true ∧
    decodedCheckFails 232 999 = true := by
  simp only [decoded_check_fails_exact]
  exact Effects.Healing.false_failure_witnesses

structure RequiredHealBytes (rom : Array Byte) : Prop where
  comparisonWindow : Tables.tableBytes rom
      (romOffset 0x0E (Word.ofNat entry.toNat)) comparisonBytes.length =
    comparisonBytes.map (fun byte => byte.toNat.toUInt8)

structure CanonicalHealBytes (sha256 : Sha256) (rom : CanonicalRom) : Prop where
  screens : ScreenRoutine.CanonicalScreenBytes sha256 rom
  healing : RequiredHealBytes rom.bytes

/-- Conditional byte certificate paired with the universal failure predicate. -/
theorem canonical_heal_comparison_exact {sha256 : Sha256} {rom : CanonicalRom}
    (certificate : CanonicalHealBytes sha256 rom) :
    Tables.tableBytes rom.bytes
        (romOffset 0x0E (Word.ofNat entry.toNat)) comparisonBytes.length =
          comparisonBytes.map (fun byte => byte.toNat.toUInt8) ∧
      ∀ current maximum, decodedCheckFails current maximum =
        Effects.Healing.checkFails current maximum :=
  ⟨certificate.healing.comparisonWindow, decoded_check_fails_exact⟩

/-- Runtime fixture predicate only. -/
def windowAgrees (rom : Array Byte) : Bool :=
  decide (Tables.tableBytes rom
      (romOffset 0x0E (Word.ofNat entry.toNat)) comparisonBytes.length =
    comparisonBytes.map (fun byte => byte.toNat.toUInt8))

end Battle.Rom.HealRoutine
