/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

import Sm83.Instruction

namespace Sm83
namespace Decode

private def target8 (code : Nat) : Target8 :=
  match code % 8 with
  | 0 => .reg .b
  | 1 => .reg .c
  | 2 => .reg .d
  | 3 => .reg .e
  | 4 => .reg .h
  | 5 => .reg .l
  | 6 => .atHL
  | _ => .reg .a

private def reg16 (code : Nat) : Reg16 :=
  match code % 4 with
  | 0 => .bc
  | 1 => .de
  | 2 => .hl
  | _ => .sp

private def stack16 (code : Nat) : Stack16 :=
  match code % 4 with
  | 0 => .bc
  | 1 => .de
  | 2 => .hl
  | _ => .af

private def mem16 (code : Nat) : Mem16 :=
  match code % 4 with
  | 0 => .atBC
  | 1 => .atDE
  | 2 => .atHLInc
  | _ => .atHLDec

private def condition (code : Nat) : Condition :=
  match code % 4 with
  | 0 => .nz
  | 1 => .z
  | 2 => .nc
  | _ => .c

private def alu (code : Nat) : AluOp :=
  match code % 8 with
  | 0 => .add
  | 1 => .adc
  | 2 => .sub
  | 3 => .sbc
  | 4 => .and
  | 5 => .xor
  | 6 => .or
  | _ => .cp

private def accRotate (code : Nat) : AccRotate :=
  match code % 4 with
  | 0 => .rlca
  | 1 => .rrca
  | 2 => .rla
  | _ => .rra

private def cbRotate (code : Nat) : CbRotate :=
  match code % 8 with
  | 0 => .rlc
  | 1 => .rrc
  | 2 => .rl
  | 3 => .rr
  | 4 => .sla
  | 5 => .sra
  | 6 => .swap
  | _ => .srl

/-- Complete encoding-derived decoder for unprefixed opcode bytes. -/
def base (opcode : Byte) : DecodeHead :=
  let value := opcode.toNat
  let x := value / 64
  let y := value / 8 % 8
  let z := value % 8
  let p := y / 2
  let q := y % 2
  match x with
  | 0 =>
      match z with
      | 0 =>
          match y with
          | 0 => .legal .nop
          | 1 => .legal .ldAbsSP
          | 2 => .legal .stop
          | 3 => .legal .jr
          | _ => .legal (.jrCond (condition (y - 4)))
      | 1 => if q = 0 then .legal (.ld16Imm (reg16 p)) else .legal (.addHL (reg16 p))
      | 2 => if q = 0 then .legal (.ldMem16A (mem16 p)) else .legal (.ldAFromMem16 (mem16 p))
      | 3 => if q = 0 then .legal (.inc16 (reg16 p)) else .legal (.dec16 (reg16 p))
      | 4 => .legal (.inc8 (target8 y))
      | 5 => .legal (.dec8 (target8 y))
      | 6 => .legal (.ld8Imm (target8 y))
      | _ =>
          match y with
          | 0 | 1 | 2 | 3 => .legal (.accRotate (accRotate y))
          | 4 => .legal .daa
          | 5 => .legal .cpl
          | 6 => .legal .scf
          | _ => .legal .ccf
  | 1 =>
      if y = 6 && z = 6 then .legal .halt
      else .legal (.ld8 (target8 y) (target8 z))
  | 2 => .legal (.aluA (alu y) (target8 z))
  | _ =>
      match z with
      | 0 =>
          if y < 4 then .legal (.retCond (condition y))
          else match y with
            | 4 => .legal .ldhImmA
            | 5 => .legal .addSP
            | 6 => .legal .ldhAImm
            | _ => .legal .ldHLFromSPPlus
      | 1 =>
          if q = 0 then .legal (.pop (stack16 p))
          else match p with
            | 0 => .legal .ret
            | 1 => .legal .reti
            | 2 => .legal .jpHL
            | _ => .legal .ldSPHL
      | 2 =>
          if y < 4 then .legal (.jpCond (condition y))
          else match y with
            | 4 => .legal .ldhCA
            | 5 => .legal .ldAbsA
            | 6 => .legal .ldhAC
            | _ => .legal .ldAAbs
      | 3 =>
          match y with
          | 0 => .legal .jp
          | 1 => .prefix
          | 6 => .legal .di
          | 7 => .legal .ei
          | _ => .locked opcode
      | 4 => if y < 4 then .legal (.callCond (condition y)) else .locked opcode
      | 5 =>
          if q = 0 then .legal (.push (stack16 p))
          else if p = 0 then .legal .call else .locked opcode
      | 6 => .legal (.aluAImm (alu y))
      | _ => .legal (.rst (Fin.ofNat 8 y))

/-- Complete decoder for the byte following a CB prefix. -/
def cb (opcode : Byte) : InstructionShape :=
  let value := opcode.toNat
  let x := value / 64
  let y := value / 8 % 8
  let z := value % 8
  match x with
  | 0 => .cbRotate (cbRotate y) (target8 z)
  | 1 => .bit (Fin.ofNat 8 y) (target8 z)
  | 2 => .res (Fin.ofNat 8 y) (target8 z)
  | _ => .set (Fin.ofNat 8 y) (target8 z)

@[inline] def isLegal : DecodeHead → Bool
  | .legal _ => true
  | _ => false

@[inline] def isPrefix : DecodeHead → Bool
  | .prefix => true
  | _ => false

@[inline] def isLocked : DecodeHead → Bool
  | .locked _ => true
  | _ => false

private def baseBytes : List Byte := (List.range 256).map Byte.ofNat

/-- Executable cardinalities, proved below rather than assumed by consumers. -/
def legalBaseCount : Nat := baseBytes.countP (fun opcode => isLegal (base opcode))
def prefixBaseCount : Nat := baseBytes.countP (fun opcode => isPrefix (base opcode))
def lockedBaseCount : Nat := baseBytes.countP (fun opcode => isLocked (base opcode))

@[simp] theorem legalBaseCount_eq : legalBaseCount = 244 := by native_decide
@[simp] theorem prefixBaseCount_eq : prefixBaseCount = 1 := by native_decide
@[simp] theorem lockedBaseCount_eq : lockedBaseCount = 11 := by native_decide

private def invalidValues : List Nat :=
  [0xD3, 0xDB, 0xDD, 0xE3, 0xE4, 0xEB, 0xEC, 0xED, 0xF4, 0xFC, 0xFD]

/-- The encoding classifier derives exactly the reviewed invalid-opcode set. -/
theorem locked_iff_reviewed : ∀ opcode : Byte,
    isLocked (base opcode) = invalidValues.contains opcode.toNat := by
  native_decide

private def legalLengthValid (opcode : Byte) : Bool :=
  match base opcode with
  | .legal shape => 1 <= shape.encodedLength && shape.encodedLength <= 3
  | .prefix | .locked _ => true

/-- Every legal base instruction has a one-, two-, or three-byte encoding. -/
theorem every_legal_length_valid : ∀ opcode : Byte, legalLengthValid opcode := by
  native_decide

/-- CB decoding is total by construction and every result has encoded length two. -/
theorem every_cb_length_two : ∀ opcode : Byte, (cb opcode).encodedLength = 2 := by
  native_decide

end Decode
end Sm83
