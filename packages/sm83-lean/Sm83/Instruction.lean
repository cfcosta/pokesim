/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

import Sm83.Byte

namespace Sm83

inductive Reg8 where
  | b | c | d | e | h | l | a
  deriving Repr, DecidableEq, Inhabited

inductive Target8 where
  | reg (register : Reg8)
  | atHL
  deriving Repr, DecidableEq, Inhabited

inductive Reg16 where
  | bc | de | hl | sp
  deriving Repr, DecidableEq, Inhabited

inductive Stack16 where
  | bc | de | hl | af
  deriving Repr, DecidableEq, Inhabited

inductive Mem16 where
  | atBC | atDE | atHLInc | atHLDec
  deriving Repr, DecidableEq, Inhabited

inductive Condition where
  | nz | z | nc | c
  deriving Repr, DecidableEq, Inhabited

inductive AluOp where
  | add | adc | sub | sbc | and | xor | or | cp
  deriving Repr, DecidableEq, Inhabited

inductive AccRotate where
  | rlca | rrca | rla | rra
  deriving Repr, DecidableEq, Inhabited

inductive CbRotate where
  | rlc | rrc | rl | rr | sla | sra | swap | srl
  deriving Repr, DecidableEq, Inhabited

abbrev BitIndex := Fin 8
abbrev RstVector := Fin 8

/-- A decoded instruction family before immediate bytes are supplied. -/
inductive InstructionShape where
  | nop
  | ld16Imm (destination : Reg16)
  | ldMem16A (destination : Mem16)
  | ldAFromMem16 (source : Mem16)
  | ldAbsSP
  | inc16 (target : Reg16)
  | dec16 (target : Reg16)
  | addHL (source : Reg16)
  | inc8 (target : Target8)
  | dec8 (target : Target8)
  | ld8Imm (target : Target8)
  | accRotate (operation : AccRotate)
  | daa | cpl | scf | ccf
  | jr
  | jrCond (condition : Condition)
  | stop
  | ld8 (destination source : Target8)
  | halt
  | aluA (operation : AluOp) (source : Target8)
  | retCond (condition : Condition)
  | ret | reti
  | pop (target : Stack16)
  | jpCond (condition : Condition)
  | jp | jpHL
  | ldhImmA | ldhAImm | ldhCA | ldhAC
  | ldAbsA | ldAAbs
  | addSP | ldHLFromSPPlus | ldSPHL
  | di | ei
  | callCond (condition : Condition)
  | push (source : Stack16)
  | call
  | aluAImm (operation : AluOp)
  | rst (vector : RstVector)
  | cbRotate (operation : CbRotate) (target : Target8)
  | bit (index : BitIndex) (target : Target8)
  | res (index : BitIndex) (target : Target8)
  | set (index : BitIndex) (target : Target8)
  deriving Repr, DecidableEq

inductive DecodeHead where
  | legal (shape : InstructionShape)
  | prefix
  | locked (opcode : Byte)
  deriving Repr, DecidableEq

/-- Number of bytes following the base opcode. CB instructions account for their prefix separately. -/
def InstructionShape.immediateBytes : InstructionShape → Nat
  | .ld16Imm _ | .ldAbsSP | .jpCond _ | .jp | .ldAbsA | .ldAAbs | .callCond _ | .call => 2
  | .ld8Imm _ | .jr | .jrCond _ | .stop | .ldhImmA | .ldhAImm | .addSP
  | .ldHLFromSPPlus | .aluAImm _ => 1
  | _ => 0

/-- Programmer-visible encoded length. -/
def InstructionShape.encodedLength (shape : InstructionShape) : Nat :=
  if shape matches .cbRotate .. | .bit .. | .res .. | .set .. then 2
  else 1 + shape.immediateBytes

/-- Fully fetched instruction bytes while preserving the original immediate encoding. -/
structure DecodedInstruction where
  shape : InstructionShape
  immediate : List Byte
  immediateLength : immediate.length = shape.immediateBytes

end Sm83
