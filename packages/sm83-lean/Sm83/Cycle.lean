/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

import Sm83.Decode
import Sm83.Bus

namespace Sm83

inductive MicroOp where
  | opcodeFetch
  | cbFetch
  | immediate8
  | immediateLow
  | immediateHigh
  | readHL
  | writeHL
  | readAddress
  | writeAddress
  | writeAddressNext
  | internal
  | stackInitialDecrement
  | stackWriteHigh
  | stackWriteLow
  | stackReadLow
  | stackReadHigh
  | successorFetch
  deriving Repr, DecidableEq, Inhabited

namespace Cycle

def targetIsMemory : Target8 → Bool
  | .atHL => true
  | .reg _ => false

/-- De-overlapped programmer-visible M-cycle schedule for every legal shape. -/
def logicalSchedule (shape : InstructionShape) (taken : Bool := true) : List MicroOp :=
  let op := [.opcodeFetch]
  match shape with
  | .nop | .accRotate _ | .daa | .cpl | .scf | .ccf | .jpHL | .di | .ei => op
  | .ld8 destination source =>
      if targetIsMemory source then op ++ [.readHL]
      else if targetIsMemory destination then op ++ [.writeHL]
      else op
  | .inc8 target | .dec8 target =>
      if targetIsMemory target then op ++ [.readHL, .writeHL] else op
  | .aluA _ source => if targetIsMemory source then op ++ [.readHL] else op
  | .ld8Imm target =>
      if targetIsMemory target then op ++ [.immediate8, .writeHL] else op ++ [.immediate8]
  | .ld16Imm _ => op ++ [.immediateLow, .immediateHigh]
  | .ldMem16A _ => op ++ [.writeAddress]
  | .ldAFromMem16 _ => op ++ [.readAddress]
  | .ldAbsSP => op ++ [.immediateLow, .immediateHigh, .writeAddress, .writeAddressNext]
  | .inc16 _ | .dec16 _ | .addHL _ | .ldSPHL => op ++ [.internal]
  | .jr => op ++ [.immediate8, .internal]
  | .jrCond _ => if taken then op ++ [.immediate8, .internal] else op ++ [.immediate8]
  | .stop => op ++ [.immediate8]
  | .halt => op
  | .retCond _ =>
      if taken then op ++ [.internal, .stackReadLow, .stackReadHigh, .internal]
      else op ++ [.internal]
  | .ret | .reti => op ++ [.stackReadLow, .stackReadHigh, .internal]
  | .pop _ => op ++ [.stackReadLow, .stackReadHigh]
  | .jpCond _ =>
      if taken then op ++ [.immediateLow, .immediateHigh, .internal]
      else op ++ [.immediateLow, .immediateHigh]
  | .jp => op ++ [.immediateLow, .immediateHigh, .internal]
  | .ldhImmA => op ++ [.immediate8, .writeAddress]
  | .ldhAImm => op ++ [.immediate8, .readAddress]
  | .ldhCA => op ++ [.writeAddress]
  | .ldhAC => op ++ [.readAddress]
  | .ldAbsA => op ++ [.immediateLow, .immediateHigh, .writeAddress]
  | .ldAAbs => op ++ [.immediateLow, .immediateHigh, .readAddress]
  | .addSP => op ++ [.immediate8, .internal, .internal]
  | .ldHLFromSPPlus => op ++ [.immediate8, .internal]
  | .callCond _ =>
      if taken then op ++ [.immediateLow, .immediateHigh, .stackInitialDecrement,
        .stackWriteHigh, .stackWriteLow]
      else op ++ [.immediateLow, .immediateHigh]
  | .push _ | .rst _ => op ++ [.stackInitialDecrement, .stackWriteHigh, .stackWriteLow]
  | .call => op ++ [.immediateLow, .immediateHigh, .stackInitialDecrement,
      .stackWriteHigh, .stackWriteLow]
  | .aluAImm _ => op ++ [.immediate8]
  | .cbRotate _ target | .res _ target | .set _ target =>
      if targetIsMemory target then op ++ [.cbFetch, .readHL, .writeHL]
      else op ++ [.cbFetch]
  | .bit _ target =>
      if targetIsMemory target then op ++ [.cbFetch, .readHL]
      else op ++ [.cbFetch]

/-- Physical execution begins with the current opcode in IR and ends by fetching its successor. -/
def physicalSchedule (shape : InstructionShape) (taken : Bool := true) : List MicroOp :=
  (logicalSchedule shape taken).drop 1 ++ [.successorFetch]

@[inline] def mcycles (shape : InstructionShape) (taken : Bool := true) : MCycles :=
  ⟨(logicalSchedule shape taken).length⟩

@[inline] def tcycles (shape : InstructionShape) (taken : Bool := true) : TCycles :=
  (mcycles shape taken).toT

def baseLengthValid (opcode : Byte) (taken : Bool) : Bool :=
  match Decode.base opcode with
  | .legal .halt | .legal .stop => true
  | .legal shape =>
      let count := (logicalSchedule shape taken).length
      1 <= count && count <= 6 && (physicalSchedule shape taken).length = count
  | .prefix | .locked _ => true

/-- Every normal decoded base family has 1–6 M-cycles and fetch reassociation preserves duration. -/
theorem every_base_schedule_valid : ∀ (opcode : Byte) (taken : Bool),
    baseLengthValid opcode taken := by
  native_decide

/-- Every CB byte has 2, 3, or 4 M-cycles with equal physical duration. -/
theorem every_cb_schedule_valid : ∀ opcode : Byte,
    let shape := Decode.cb opcode
    let count := (logicalSchedule shape).length
    (count = 2 || count = 3 || count = 4) && (physicalSchedule shape).length = count := by
  native_decide

end Cycle
end Sm83
