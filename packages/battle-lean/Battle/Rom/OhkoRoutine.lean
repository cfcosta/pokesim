/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Rom.ConversionRoutine

/-!
# Decoded one-hit-KO comparison

The canonical handler compares low Speed bytes with `SUB`, then high bytes with
`SBC`. This module proves universally that its surviving carry flag implements
unsigned 16-bit attacker-Speed greater-than-or-equal, including tie success.
The exact handler window is certified separately from the still-open continuous
call-site trace through damage randomization and accuracy.
-/

namespace Battle.Rom.OhkoRoutine

open Sm83 Battle.Rom.Closure

private def entry : UInt16 := 0x7F57
private def bytes : List Byte :=
  [0x21, 0xD7, 0xD0, 0xAF, 0x22, 0x77, 0x3D, 0xEA, 0x5E, 0xD0,
   0x21, 0x2A, 0xD0, 0x11, 0xFB, 0xCF, 0xF0, 0xF3, 0xA7,
   0x28, 0x06, 0x21, 0xFB, 0xCF, 0x11, 0x2A, 0xD0, 0x1A,
   0x1B, 0x47, 0x3A, 0x90, 0x1A, 0x47, 0x7E, 0x98, 0x38,
   0x0D, 0x21, 0xD7, 0xD0, 0x3E, 0xFF, 0x22, 0x77, 0x3E,
   0x02, 0xEA, 0x5E, 0xD0, 0xC9, 0x3E, 0x01, 0xEA, 0x5F,
   0xD0, 0xC9]

/-- Carry behavior of the handler's low-byte `SUB` and high-byte `SBC`. -/
def decodedSpeedEligible (attacker target : Word) : Bool :=
  let low := Alu.sub8 attacker.lowByte target.lowByte
  !(Alu.sub8 attacker.highByte target.highByte low.flags.c).flags.c

private theorem word_decompose (value : Word) :
    value.toNat = value.highByte.toNat * 256 + value.lowByte.toNat := by
  simp only [Word.highByte, Word.lowByte, BitVec.extractLsb_toNat]
  simp only [Nat.reduceSub, Nat.reduceAdd, Nat.reducePow, Nat.shiftRight_zero]
  rw [Nat.shiftRight_eq_div_pow]
  simp only [Nat.reducePow]
  have bounded := BitVec.isLt value
  omega

/-- The decoded two-byte subtraction accepts exactly attacker Speed ≥ target
Speed. In particular, equal current Speeds follow the success branch. -/
theorem decoded_speed_comparison_exact (attacker target : Word) :
    decodedSpeedEligible attacker target = decide (attacker.toNat ≥ target.toNat) := by
  have attackerValue := word_decompose attacker
  have targetValue := word_decompose target
  have attackerLowBound := BitVec.isLt attacker.lowByte
  have attackerHighBound := BitVec.isLt attacker.highByte
  have targetLowBound := BitVec.isLt target.lowByte
  have targetHighBound := BitVec.isLt target.highByte
  by_cases lowBorrow : attacker.lowByte.toNat < target.lowByte.toNat
  · simp only [decodedSpeedEligible, Alu.sub8, Alu.carryNat]
    simp [lowBorrow]
    rw [Bool.eq_iff_iff]
    simp
    omega
  · simp only [decodedSpeedEligible, Alu.sub8, Alu.carryNat]
    simp [lowBorrow]
    rw [Bool.eq_iff_iff]
    simp
    omega

/-- Explicit pin for the cartridge's source-comment mismatch. -/
theorem decoded_speed_tie_succeeds (speed : Word) :
    decodedSpeedEligible speed speed = true := by
  rw [decoded_speed_comparison_exact]
  simp

/-- Strictly slower attackers take the handler's failure branch. -/
theorem decoded_slower_fails (attacker target : Word)
    (slower : attacker.toNat < target.toNat) :
    decodedSpeedEligible attacker target = false := by
  rw [decoded_speed_comparison_exact]
  simp [Nat.not_le.mpr slower]

structure RequiredOhkoBytes (rom : Array Byte) : Prop where
  window : Tables.tableBytes rom (romOffset 0x0C (Word.ofNat entry.toNat)) bytes.length =
    bytes.map (fun byte => byte.toNat.toUInt8)

structure CanonicalOhkoBytes (sha256 : Sha256) (rom : CanonicalRom) : Prop where
  conversion : ConversionRoutine.CanonicalConversionBytes sha256 rom
  ohko : RequiredOhkoBytes rom.bytes

/-- Conditional byte certificate paired with the universal arithmetic summary. -/
theorem canonical_ohko_comparison_exact {sha256 : Sha256} {rom : CanonicalRom}
    (certificate : CanonicalOhkoBytes sha256 rom) :
    Tables.tableBytes rom.bytes (romOffset 0x0C (Word.ofNat entry.toNat)) bytes.length =
        bytes.map (fun byte => byte.toNat.toUInt8) ∧
      ∀ attacker target, decodedSpeedEligible attacker target =
        decide (attacker.toNat ≥ target.toNat) :=
  ⟨certificate.ohko.window, decoded_speed_comparison_exact⟩

/-- Runtime fixture predicate only. -/
def windowAgrees (rom : Array Byte) : Bool :=
  decide (Tables.tableBytes rom (romOffset 0x0C (Word.ofNat entry.toNat)) bytes.length =
    bytes.map (fun byte => byte.toNat.toUInt8))

end Battle.Rom.OhkoRoutine
