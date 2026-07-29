/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Rom.RoutineSummary
import Battle.Rom.Tables
import Battle.Full.Engine

/-!
# Canonical Struggle-selection and recoil witnesses

`AnyMoveToSelect` installs Struggle (`$A5`) before scanning packed PP. Without
Disable it ORs all four bytes and masks PP-Up bits. With Disable it skips the
encoded slot but, reproducing Red's bug, ORs the other complete packed bytes
without a PP mask. `RecoilEffect_` shifts the 16-bit damage word once, compares
the move with `$A5`, and shifts a second time only for non-Struggle recoil.

The retained windows are canonical ROM evidence. The arithmetic theorem below
checks every 16-bit damage word and connects the model's Struggle half-recoil
and ordinary quarter-recoil to those shift operations.
-/

namespace Battle.Rom.StruggleRoutine

open Sm83 Battle.Rom.Closure

private def selectionEntry : Word := 0x53F5
private def recoilArithmeticEntry : Word := 0x793D

/-- Complete `AnyMoveToSelect`, through its returning no-moves path. -/
private def selectionBytes : List Byte :=
  [0x3E, 0xA5, 0xEA, 0xDC, 0xCC, 0xFA, 0x6D, 0xD0, 0xA7,
   0x21, 0x2D, 0xD0, 0x20, 0x0B, 0x2A, 0xB6, 0x23, 0xB6,
   0x23, 0xB6, 0xE6, 0x3F, 0xC0, 0x18, 0x15, 0xCB, 0x37,
   0xE6, 0x0F, 0x47, 0x16, 0x05, 0xAF, 0x15, 0x28, 0x08,
   0x4E, 0x23, 0x05, 0x28, 0xF8, 0xB1, 0x18, 0xF5, 0xA7,
   0xC0, 0x21, 0x30, 0x54, 0xCD, 0x49, 0x3C, 0x0E, 0x3C,
   0xCD, 0x39, 0x37, 0xAF, 0xC9]

/-- Recoil arithmetic from `ld d,a` through the minimum-one `inc c`. -/
private def recoilArithmeticBytes : List Byte :=
  [0x57, 0xFA, 0xD7, 0xD0, 0x47, 0xFA, 0xD8, 0xD0, 0x4F,
   0xCB, 0x38, 0xCB, 0x19, 0x7A, 0xFE, 0xA5, 0x28, 0x04,
   0xCB, 0x38, 0xCB, 0x19, 0x78, 0xB1, 0x20, 0x01, 0x0C]

structure RequiredStruggleBytes (rom : Array Byte) : Prop where
  selection : Tables.tableBytes rom (romOffset 0x0F selectionEntry)
      selectionBytes.length = selectionBytes.map (fun byte => byte.toNat.toUInt8)
  recoil : Tables.tableBytes rom (romOffset 0x04 recoilArithmeticEntry)
      recoilArithmeticBytes.length =
        recoilArithmeticBytes.map (fun byte => byte.toNat.toUInt8)

structure CanonicalStruggleBytes (sha256 : Sha256) (rom : CanonicalRom) : Prop where
  identity : rom.Valid sha256
  struggle : RequiredStruggleBytes rom.bytes

/-- Decoding the retained control bytes establishes the actual instruction
families used by selection and recoil, independently of source comments. -/
theorem decoded_struggle_control :
    Decode.base (0x3E : Byte) = .legal (.ld8Imm (.reg .a)) ∧
    Decode.base (0xEA : Byte) = .legal .ldAbsA ∧
    Decode.base (0xFA : Byte) = .legal .ldAAbs ∧
    Decode.base (0xA7 : Byte) = .legal (.aluA .and (.reg .a)) ∧
    Decode.base (0x20 : Byte) = .legal (.jrCond .nz) ∧
    Decode.base (0x2A : Byte) = .legal (.ldAFromMem16 .atHLInc) ∧
    Decode.base (0xB6 : Byte) = .legal (.aluA .or .atHL) ∧
    Decode.base (0xE6 : Byte) = .legal (.aluAImm .and) ∧
    Decode.base (0xC0 : Byte) = .legal (.retCond .nz) ∧
    Decode.cb (0x38 : Byte) = .cbRotate .srl (.reg .b) ∧
    Decode.cb (0x19 : Byte) = .cbRotate .rr (.reg .c) ∧
    Decode.base (0xFE : Byte) = .legal (.aluAImm .cp) ∧
    Decode.base (0x28 : Byte) = .legal (.jrCond .z) := by
  native_decide

private def install : FlatMemory → Word → List Byte → FlatMemory
  | memory, _, [] => memory
  | memory, address, byte :: rest =>
      install (memory.write address byte) (Word.ofNat (address.toNat + 1)) rest

private def recoilInitial (move : MoveId) (damage : UInt16) : FunctionalState :=
  let memory := install default recoilArithmeticEntry recoilArithmeticBytes
  let memory := memory.write 0xD0D7 (Byte.ofNat (damage.toNat / 256))
  let memory := memory.write 0xD0D8 (Byte.ofNat (damage.toNat % 256))
  let state := Driver.setupCall memory (UInt16.ofNat recoilArithmeticEntry.toNat)
    0x8000 0xFFFE
  { state with registers := { state.registers with a := Byte.ofNat move.toNat } }

private def recoilMachineRun (move : MoveId) (damage : UInt16) : Program.RunResult :=
  Program.runUntil (fun state => state.registers.pc == (0x7958 : Word)) 20
    (recoilInitial move damage) [] 0

private def recoilMachineDamage (result : Program.RunResult) : UInt16 :=
  let final := Driver.finalState result
  UInt16.ofNat (Word.ofBytes final.registers.b final.registers.c).toNat

private def reachedRecoilExit : Program.RunResult → Bool
  | .reached state _ _ => state.registers.pc == (0x7958 : Word)
  | _ => false

private def shiftDamageRight (damage : UInt16) : UInt16 :=
  UInt16.ofNat (damage.toNat >>> 1)

/-- Bit-level arithmetic performed by the canonical `SRL B; RR C` sequence. -/
def cartridgeRecoilDamage (move : MoveId) (damage : UInt16) : UInt16 :=
  let half := shiftDamageRight damage
  let raw := if move == 165 then half else shiftDamageRight half
  if raw == 0 then 1 else raw

private def recoilArithmeticAgrees : Bool :=
  (List.range UInt16.size).all fun raw =>
    let damage := raw.toUInt16
    Full.Effects.recoilDamageWord 165 damage == cartridgeRecoilDamage 165 damage &&
      Full.Effects.recoilDamageWord 164 damage == cartridgeRecoilDamage 164 damage

private theorem recoil_arithmetic_checked : recoilArithmeticAgrees = true := by
  native_decide

private def machineStruggleRecoilAgrees : Bool :=
  (List.range UInt16.size).all fun raw =>
    let damage := raw.toUInt16
    let result := recoilMachineRun 165 damage
    reachedRecoilExit result &&
      recoilMachineDamage result == Full.Effects.recoilDamageWord 165 damage

private theorem machine_struggle_recoil_checked :
    machineStruggleRecoilAgrees = true := by
  native_decide

private theorem recoil_checked (damage : UInt16) :
    Full.Effects.recoilDamageWord 165 damage = cartridgeRecoilDamage 165 damage ∧
      Full.Effects.recoilDamageWord 164 damage = cartridgeRecoilDamage 164 damage := by
  have item := (List.all_eq_true.mp recoil_arithmetic_checked) damage.toNat
    (List.mem_range.mpr damage.toNat_lt)
  have parts := Bool.and_eq_true_iff.mp item
  have first := beq_iff_eq.mp parts.1
  have second := beq_iff_eq.mp parts.2
  have round : damage.toNat.toUInt16 = damage := by
    apply UInt16.toNat.inj
    simp
  simpa [round] using And.intro first second

/-- Executing the retained recoil window through the proved SM83 functional
semantics reaches `$7958` with `BC` equal to the model's Struggle recoil for
every 16-bit damage word. -/
theorem machine_struggle_recoil_exact (damage : UInt16) :
    let result := recoilMachineRun 165 damage
    reachedRecoilExit result = true ∧
      recoilMachineDamage result = Full.Effects.recoilDamageWord 165 damage := by
  have item := (List.all_eq_true.mp machine_struggle_recoil_checked) damage.toNat
    (List.mem_range.mpr damage.toNat_lt)
  have parts := Bool.and_eq_true_iff.mp item
  have amount := beq_iff_eq.mp parts.2
  have round : damage.toNat.toUInt16 = damage := by
    apply UInt16.toNat.inj
    simp
  simpa [round] using And.intro parts.1 amount

/-- For every move ID and every 16-bit damage word, the high-level recoil
amount equals the canonical shift/check/minimum-one arithmetic. -/
theorem recoil_arithmetic_exact (move : MoveId) (damage : UInt16) :
    Full.Effects.recoilDamageWord move damage = cartridgeRecoilDamage move damage := by
  by_cases struggle : move = 165
  · subst move
    exact (recoil_checked damage).1
  · have ordinary := (recoil_checked damage).2
    simpa [Full.Effects.recoilDamageWord, cartridgeRecoilDamage, struggle] using ordinary

/-- The model follows `AnyMoveToSelect`: a false availability scan is exactly
Struggle preselection. -/
theorem model_struggle_preselection (side : Full.SideState)
    (unavailable : Full.anyMovePpAvailable side.active.volatile.disabledMove
      side.active.active.pp = false) :
    Full.mustStruggle side = true := by
  simp [Full.mustStruggle, unavailable]

/-- The high-level execution path installs move `$A5`, spends no move-slot PP,
and computes recoil with the exact canonical shift arithmetic. -/
theorem model_struggle_execution (state : Full.Engine.State) (who : Side)
    (slot : Fin 4) (damage : UInt16) :
    Full.Engine.decrementMovePp state who slot true = state ∧
      Full.Effects.recoilDamageWord 165 damage = cartridgeRecoilDamage 165 damage := by
  exact ⟨Full.Engine.struggle_never_decrements_pp state who slot,
    recoil_arithmetic_exact 165 damage⟩

/-- Runtime fixture predicate only; theorem consumers require
`RequiredStruggleBytes` instead. -/
def windowAgrees (rom : Array Byte) : Bool :=
  decide (Tables.tableBytes rom (romOffset 0x0F selectionEntry)
      selectionBytes.length = selectionBytes.map (fun byte => byte.toNat.toUInt8)) &&
  decide (Tables.tableBytes rom (romOffset 0x04 recoilArithmeticEntry)
      recoilArithmeticBytes.length =
        recoilArithmeticBytes.map (fun byte => byte.toNat.toUInt8))

end Battle.Rom.StruggleRoutine
