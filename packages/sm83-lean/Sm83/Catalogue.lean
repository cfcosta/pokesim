/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

import Sm83.Cycle

namespace Sm83

inductive FlagAction where
  | preserve | clear | set | compute
  deriving Repr, DecidableEq, Inhabited

structure FlagPolicy where
  z : FlagAction := .preserve
  n : FlagAction := .preserve
  h : FlagAction := .preserve
  c : FlagAction := .preserve
  deriving Repr, DecidableEq, Inhabited

inductive CatalogueDisposition where
  | legal | prefix | locked
  deriving Repr, DecidableEq, Inhabited

structure CatalogueRow where
  opcode : Byte
  cbPrefixed : Bool
  disposition : CatalogueDisposition
  shape : Option InstructionShape
  length : Nat
  untakenTCycles : Nat
  takenTCycles : Nat
  flags : FlagPolicy
  deriving Repr, DecidableEq

namespace Catalogue

/-- Exact identity of the metadata evidence; it is never imported as semantics. -/
def gbOpcodesCommit : String := "376f61c86fdac2048f7ce5fe838ae756b306017e"
def gbOpcodesSha256 : String := "e7e3cd657d8e87b44570474eb3a6ed735501c9a00520f3d6937881203c823bc5"

private def aluPolicy : AluOp → FlagPolicy
  | .add | .adc => { z := .compute, n := .clear, h := .compute, c := .compute }
  | .sub | .sbc | .cp => { z := .compute, n := .set, h := .compute, c := .compute }
  | .and => { z := .compute, n := .clear, h := .set, c := .clear }
  | .xor | .or => { z := .compute, n := .clear, h := .clear, c := .clear }

/-- Public flag-write projection for one normalized semantic family. -/
def flagPolicy : InstructionShape → FlagPolicy
  | .inc8 _ => { z := .compute, n := .clear, h := .compute }
  | .dec8 _ => { z := .compute, n := .set, h := .compute }
  | .addHL _ => { n := .clear, h := .compute, c := .compute }
  | .accRotate _ => { z := .clear, n := .clear, h := .clear, c := .compute }
  | .daa => { z := .compute, h := .clear, c := .compute }
  | .cpl => { n := .set, h := .set }
  | .scf => { n := .clear, h := .clear, c := .set }
  | .ccf => { n := .clear, h := .clear, c := .compute }
  | .aluA operation _ | .aluAImm operation => aluPolicy operation
  | .addSP | .ldHLFromSPPlus => { z := .clear, n := .clear, h := .compute, c := .compute }
  | .cbRotate _ _ => { z := .compute, n := .clear, h := .clear, c := .compute }
  | .bit _ _ => { z := .compute, n := .clear, h := .set }
  | _ => {}

private def legalRow (opcode : Byte) (cbPrefixed : Bool) (shape : InstructionShape) : CatalogueRow :=
  { opcode
    cbPrefixed
    disposition := .legal
    shape := some shape
    length := shape.encodedLength
    untakenTCycles := (Cycle.tcycles shape false).value
    takenTCycles := (Cycle.tcycles shape true).value
    flags := flagPolicy shape }

/-- Encoding-derived base row. PREFIX and invalid lock bytes have explicit dispositions. -/
def baseRow (opcode : Byte) : CatalogueRow :=
  match Decode.base opcode with
  | .legal .stop =>
      let row := legalRow opcode false .stop
      { row with untakenTCycles := 4, takenTCycles := 4 }
  | .legal shape => legalRow opcode false shape
  | .prefix => {
      opcode
      cbPrefixed := false
      disposition := .prefix
      shape := none
      length := 1
      untakenTCycles := 4
      takenTCycles := 4
      flags := {} }
  | .locked _ => {
      opcode
      cbPrefixed := false
      disposition := .locked
      shape := none
      length := 1
      untakenTCycles := 4
      takenTCycles := 4
      flags := {} }

/-- Encoding-derived CB row. -/
def cbRow (opcode : Byte) : CatalogueRow := legalRow opcode true (Decode.cb opcode)

def baseRows : List CatalogueRow := List.ofFn fun opcode : Fin 256 => baseRow (Byte.ofNat opcode)
def cbRows : List CatalogueRow := List.ofFn fun opcode : Fin 256 => cbRow (Byte.ofNat opcode)

@[simp] theorem baseRows_length : baseRows.length = 256 := by
  unfold baseRows
  exact List.length_ofFn

@[simp] theorem cbRows_length : cbRows.length = 256 := by
  unfold cbRows
  exact List.length_ofFn

/-- Frozen projection is definitionally tied to the x/y/z decoder, never to display metadata. -/
theorem baseRow_shape (opcode : Byte) :
    (baseRow opcode).shape = match Decode.base opcode with
      | .legal shape => some shape
      | .prefix | .locked _ => none := by
  cases decoded : Decode.base opcode
  · rename_i shape
    cases shape <;> simp [baseRow, decoded, legalRow]
  · simp [baseRow, decoded]
  · simp [baseRow, decoded]

@[simp] theorem cbRow_shape (opcode : Byte) : (cbRow opcode).shape = some (Decode.cb opcode) := rfl

/-- STOP's pinned four-T-cycle entry metadata is not a completion-duration claim. -/
example : (baseRow 0x10).takenTCycles = 4 ∧
    (Cycle.tcycles .stop).value = 8 := by native_decide

/-- All 512 generated rows are present. -/
theorem complete_row_count : (baseRows ++ cbRows).length = 512 := by
  rw [List.length_append, baseRows_length, cbRows_length]

end Catalogue
end Sm83
