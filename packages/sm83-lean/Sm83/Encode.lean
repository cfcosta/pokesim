/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

import Sm83.Decode

namespace Sm83
namespace Encode

private def reg8Code : Reg8 → Nat
  | .b => 0 | .c => 1 | .d => 2 | .e => 3 | .h => 4 | .l => 5 | .a => 7

private def target8Code : Target8 → Nat
  | .reg register => reg8Code register
  | .atHL => 6

private def reg16Code : Reg16 → Nat
  | .bc => 0 | .de => 1 | .hl => 2 | .sp => 3

private def stack16Code : Stack16 → Nat
  | .bc => 0 | .de => 1 | .hl => 2 | .af => 3

private def mem16Code : Mem16 → Nat
  | .atBC => 0 | .atDE => 1 | .atHLInc => 2 | .atHLDec => 3

private def conditionCode : Condition → Nat
  | .nz => 0 | .z => 1 | .nc => 2 | .c => 3

private def aluCode : AluOp → Nat
  | .add => 0 | .adc => 1 | .sub => 2 | .sbc => 3
  | .and => 4 | .xor => 5 | .or => 6 | .cp => 7

private def accRotateCode : AccRotate → Nat
  | .rlca => 0 | .rrca => 1 | .rla => 2 | .rra => 3

private def cbRotateCode : CbRotate → Nat
  | .rlc => 0 | .rrc => 1 | .rl => 2 | .rr => 3
  | .sla => 4 | .sra => 5 | .swap => 6 | .srl => 7

/-- Encode the opcode byte for an unprefixed normalized shape. -/
def base (shape : InstructionShape) : Option Byte :=
  let byte := fun value => some (Byte.ofNat value)
  match shape with
  | .nop => byte 0x00
  | .ld16Imm register => byte (0x01 + 0x10 * reg16Code register)
  | .ldMem16A memory => byte (0x02 + 0x10 * mem16Code memory)
  | .ldAFromMem16 memory => byte (0x0A + 0x10 * mem16Code memory)
  | .ldAbsSP => byte 0x08
  | .inc16 register => byte (0x03 + 0x10 * reg16Code register)
  | .dec16 register => byte (0x0B + 0x10 * reg16Code register)
  | .addHL register => byte (0x09 + 0x10 * reg16Code register)
  | .inc8 target => byte (0x04 + 8 * target8Code target)
  | .dec8 target => byte (0x05 + 8 * target8Code target)
  | .ld8Imm target => byte (0x06 + 8 * target8Code target)
  | .accRotate operation => byte (0x07 + 8 * accRotateCode operation)
  | .daa => byte 0x27
  | .cpl => byte 0x2F
  | .scf => byte 0x37
  | .ccf => byte 0x3F
  | .jr => byte 0x18
  | .jrCond condition => byte (0x20 + 8 * conditionCode condition)
  | .stop => byte 0x10
  | .ld8 .atHL .atHL => none
  | .ld8 destination source => byte (0x40 + 8 * target8Code destination + target8Code source)
  | .halt => byte 0x76
  | .aluA operation source => byte (0x80 + 8 * aluCode operation + target8Code source)
  | .retCond condition => byte (0xC0 + 8 * conditionCode condition)
  | .ret => byte 0xC9
  | .reti => byte 0xD9
  | .pop register => byte (0xC1 + 0x10 * stack16Code register)
  | .jpCond condition => byte (0xC2 + 8 * conditionCode condition)
  | .jp => byte 0xC3
  | .jpHL => byte 0xE9
  | .ldhImmA => byte 0xE0
  | .ldhAImm => byte 0xF0
  | .ldhCA => byte 0xE2
  | .ldhAC => byte 0xF2
  | .ldAbsA => byte 0xEA
  | .ldAAbs => byte 0xFA
  | .addSP => byte 0xE8
  | .ldHLFromSPPlus => byte 0xF8
  | .ldSPHL => byte 0xF9
  | .di => byte 0xF3
  | .ei => byte 0xFB
  | .callCond condition => byte (0xC4 + 8 * conditionCode condition)
  | .push register => byte (0xC5 + 0x10 * stack16Code register)
  | .call => byte 0xCD
  | .aluAImm operation => byte (0xC6 + 8 * aluCode operation)
  | .rst vector => byte (0xC7 + 8 * vector.val)
  | .cbRotate .. | .bit .. | .res .. | .set .. => none

/-- Encode the byte following a CB prefix. -/
def cb (shape : InstructionShape) : Option Byte :=
  let byte := fun value => some (Byte.ofNat value)
  match shape with
  | .cbRotate operation target => byte (8 * cbRotateCode operation + target8Code target)
  | .bit index target => byte (0x40 + 8 * index.val + target8Code target)
  | .res index target => byte (0x80 + 8 * index.val + target8Code target)
  | .set index target => byte (0xC0 + 8 * index.val + target8Code target)
  | _ => none

private def baseRoundTrips (opcode : Byte) : Bool :=
  match Decode.base opcode with
  | .legal shape => base shape == some opcode
  | .prefix | .locked _ => true

private def cbRoundTrips (opcode : Byte) : Bool := cb (Decode.cb opcode) == some opcode

/-- Every legal base byte re-encodes to exactly its original opcode. -/
theorem every_legal_base_round_trips : ∀ opcode : Byte, baseRoundTrips opcode := by
  native_decide

/-- Every CB byte re-encodes to exactly its original second byte. -/
theorem every_cb_round_trips : ∀ opcode : Byte, cbRoundTrips opcode := by
  native_decide

end Encode
end Sm83
