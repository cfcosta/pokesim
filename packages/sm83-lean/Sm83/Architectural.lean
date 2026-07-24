/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

import Sm83.Functional

namespace Sm83
namespace Architectural

open Functional

/-- A separately defined architectural effect function. Its family equations are
copied from the reviewed ISA contract rather than delegated to the functional
runner, so later implementation changes must re-discharge `effect_eq_functional`. -/
def effect (context : Context) (shape : InstructionShape) (immediate : List Byte)
    (pendingInterrupts : Byte) : Context :=
  let registers := context.state.registers
  match shape with
  | .nop => matureIme context
  | .ld16Imm destination =>
      matureIme <| withRegisters context (registers.set16 destination (immediate16 immediate))
  | .ldMem16A destination => matureIme (writeMem16 context destination registers.a)
  | .ldAFromMem16 source =>
      let (value, context) := readMem16 context source
      matureIme <| withRegisters context { context.state.registers with a := value }
  | .ldAbsSP =>
      let address := immediate16 immediate
      let context := write context address registers.sp.lowByte
      let context := write context (Word.ofNat (address.toNat + 1)) registers.sp.highByte
      matureIme context
  | .inc16 target =>
      let context := idle context (registers.get16 target)
      matureIme <| withRegisters context (registers.set16 target (Word.ofNat (registers.get16 target).toNat.succ))
  | .dec16 target =>
      let context := idle context (registers.get16 target)
      matureIme <| withRegisters context (registers.set16 target (Word.ofNat ((registers.get16 target).toNat + 65535)))
  | .addHL source =>
      let result := Alu.addHL registers.hl (registers.get16 source) registers.flags
      let context := idle context registers.hl
      matureIme <| withRegisters context { registers.setHL result.value with flags := result.flags }
  | .inc8 target =>
      let (value, context) := readTarget context target
      let result := Alu.inc8 value context.state.registers.flags
      matureIme <| setFlags (writeTarget context target result.value) result.flags
  | .dec8 target =>
      let (value, context) := readTarget context target
      let result := Alu.dec8 value context.state.registers.flags
      matureIme <| setFlags (writeTarget context target result.value) result.flags
  | .ld8Imm target => matureIme <| writeTarget context target (immediate8 immediate)
  | .accRotate operation =>
      let result := Alu.accumulatorRotate operation registers.a registers.flags.c
      matureIme <| withRegisters context { registers with a := result.value, flags := result.flags }
  | .daa =>
      let result := Alu.daa registers.a registers.flags
      matureIme <| withRegisters context { registers with a := result.value, flags := result.flags }
  | .cpl =>
      matureIme <| withRegisters context {
        registers with a := ~~~registers.a, flags := { registers.flags with n := true, h := true } }
  | .scf =>
      matureIme <| setFlags context { registers.flags with n := false, h := false, c := true }
  | .ccf =>
      matureIme <| setFlags context { registers.flags with n := false, h := false, c := !registers.flags.c }
  | .jr =>
      let context := idle context registers.pc
      matureIme <| withRegisters context { registers with pc := registers.pc.addSignedByte (immediate8 immediate) }
  | .jrCond condition =>
      if Alu.conditionHolds condition registers.flags then
        let context := idle context registers.pc
        matureIme <| withRegisters context { registers with pc := registers.pc.addSignedByte (immediate8 immediate) }
      else matureIme context
  | .stop =>
      let context := matureIme context
      { context with state := { context.state with mode := .stopped (immediate8 immediate) } }
  | .ld8 destination source =>
      let (value, context) := readTarget context source
      matureIme <| writeTarget context destination value
  | .halt =>
      let effectiveIme := context.state.ime || context.state.scheduledImeEnable
      let context := matureIme context
      if !effectiveIme && (pendingInterrupts.toNat != 0) then
        { context with state := { context.state with haltBug := true, mode := .running } }
      else { context with state := { context.state with mode := .halted } }
  | .aluA operation source =>
      let (operand, context) := readTarget context source
      let result := Alu.apply operation context.state.registers.a operand context.state.registers.flags
      matureIme <| withRegisters context { context.state.registers with a := result.value, flags := result.flags }
  | .retCond condition =>
      let context := idle context registers.sp
      if Alu.conditionHolds condition registers.flags then
        let (target, context) := popWord context
        let context := idle context target
        matureIme <| withRegisters context { context.state.registers with pc := target }
      else matureIme context
  | .ret =>
      let (target, context) := popWord context
      let context := idle context target
      matureIme <| withRegisters context { context.state.registers with pc := target }
  | .reti =>
      let (target, context) := popWord context
      let context := idle context target
      let context := withRegisters context { context.state.registers with pc := target }
      { context with state := { context.state with ime := true, scheduledImeEnable := false } }
  | .pop target =>
      let (value, context) := popWord context
      matureIme <| withRegisters context (context.state.registers.setStack16 target value)
  | .jpCond condition =>
      if Alu.conditionHolds condition registers.flags then
        let target := immediate16 immediate
        let context := idle context target
        matureIme <| withRegisters context { registers with pc := target }
      else matureIme context
  | .jp =>
      let target := immediate16 immediate
      let context := idle context target
      matureIme <| withRegisters context { registers with pc := target }
  | .jpHL => matureIme <| withRegisters context { registers with pc := registers.hl }
  | .ldhImmA =>
      matureIme <| write context (Word.ofNat (0xFF00 + (immediate8 immediate).toNat)) registers.a
  | .ldhAImm =>
      let (value, context) := read context .data (Word.ofNat (0xFF00 + (immediate8 immediate).toNat))
      matureIme <| withRegisters context { context.state.registers with a := value }
  | .ldhCA => matureIme <| write context (Word.ofNat (0xFF00 + registers.c.toNat)) registers.a
  | .ldhAC =>
      let (value, context) := read context .data (Word.ofNat (0xFF00 + registers.c.toNat))
      matureIme <| withRegisters context { context.state.registers with a := value }
  | .ldAbsA => matureIme <| write context (immediate16 immediate) registers.a
  | .ldAAbs =>
      let (value, context) := read context .data (immediate16 immediate)
      matureIme <| withRegisters context { context.state.registers with a := value }
  | .addSP =>
      let result := Alu.addSignedSP registers.sp (immediate8 immediate)
      let context := idle (idle context registers.sp) result.value
      matureIme <| withRegisters context { registers with sp := result.value, flags := result.flags }
  | .ldHLFromSPPlus =>
      let result := Alu.addSignedSP registers.sp (immediate8 immediate)
      let context := idle context result.value
      matureIme <| withRegisters context { registers.setHL result.value with flags := result.flags }
  | .ldSPHL =>
      let context := idle context registers.hl
      matureIme <| withRegisters context { registers with sp := registers.hl }
  | .di =>
      { context with state := { context.state with ime := false, scheduledImeEnable := false } }
  | .ei =>
      { context with state := {
          context.state with
          ime := context.state.ime || context.state.scheduledImeEnable
          scheduledImeEnable := true } }
  | .callCond condition =>
      if Alu.conditionHolds condition registers.flags then
        let context := pushWord context registers.pc
        matureIme <| withRegisters context { context.state.registers with pc := immediate16 immediate }
      else matureIme context
  | .push source => matureIme <| pushWord context (registers.getStack16 source)
  | .call =>
      let context := pushWord context registers.pc
      matureIme <| withRegisters context { context.state.registers with pc := immediate16 immediate }
  | .aluAImm operation =>
      let result := Alu.apply operation registers.a (immediate8 immediate) registers.flags
      matureIme <| withRegisters context { registers with a := result.value, flags := result.flags }
  | .rst vector =>
      let context := pushWord context registers.pc
      matureIme <| withRegisters context { context.state.registers with pc := Word.ofNat (8 * vector.val) }
  | .cbRotate operation target =>
      let (value, context) := readTarget context target
      let result := Alu.rotate operation value context.state.registers.flags.c
      matureIme <| setFlags (writeTarget context target result.value) result.flags
  | .bit index target =>
      let (value, context) := readTarget context target
      matureIme <| setFlags context (Alu.testBit index value context.state.registers.flags)
  | .res index target =>
      let (value, context) := readTarget context target
      matureIme <| writeTarget context target (Alu.resetBit index value)
  | .set index target =>
      let (value, context) := readTarget context target
      matureIme <| writeTarget context target (Alu.setBit index value)

/-- Family-indexed declarative instruction-effect relation. There is one
constructor for every `InstructionShape` constructor. -/
inductive ShapeStep : Context → InstructionShape → List Byte → Byte → Context → Prop where
  | nop (context immediate pending) : ShapeStep context .nop immediate pending (effect context .nop immediate pending)
  | ld16Imm (context destination immediate pending) : ShapeStep context (.ld16Imm destination) immediate pending (effect context (.ld16Imm destination) immediate pending)
  | ldMem16A (context destination immediate pending) : ShapeStep context (.ldMem16A destination) immediate pending (effect context (.ldMem16A destination) immediate pending)
  | ldAFromMem16 (context source immediate pending) : ShapeStep context (.ldAFromMem16 source) immediate pending (effect context (.ldAFromMem16 source) immediate pending)
  | ldAbsSP (context immediate pending) : ShapeStep context .ldAbsSP immediate pending (effect context .ldAbsSP immediate pending)
  | inc16 (context target immediate pending) : ShapeStep context (.inc16 target) immediate pending (effect context (.inc16 target) immediate pending)
  | dec16 (context target immediate pending) : ShapeStep context (.dec16 target) immediate pending (effect context (.dec16 target) immediate pending)
  | addHL (context source immediate pending) : ShapeStep context (.addHL source) immediate pending (effect context (.addHL source) immediate pending)
  | inc8 (context target immediate pending) : ShapeStep context (.inc8 target) immediate pending (effect context (.inc8 target) immediate pending)
  | dec8 (context target immediate pending) : ShapeStep context (.dec8 target) immediate pending (effect context (.dec8 target) immediate pending)
  | ld8Imm (context target immediate pending) : ShapeStep context (.ld8Imm target) immediate pending (effect context (.ld8Imm target) immediate pending)
  | accRotate (context operation immediate pending) : ShapeStep context (.accRotate operation) immediate pending (effect context (.accRotate operation) immediate pending)
  | daa (context immediate pending) : ShapeStep context .daa immediate pending (effect context .daa immediate pending)
  | cpl (context immediate pending) : ShapeStep context .cpl immediate pending (effect context .cpl immediate pending)
  | scf (context immediate pending) : ShapeStep context .scf immediate pending (effect context .scf immediate pending)
  | ccf (context immediate pending) : ShapeStep context .ccf immediate pending (effect context .ccf immediate pending)
  | jr (context immediate pending) : ShapeStep context .jr immediate pending (effect context .jr immediate pending)
  | jrCond (context condition immediate pending) : ShapeStep context (.jrCond condition) immediate pending (effect context (.jrCond condition) immediate pending)
  | stop (context immediate pending) : ShapeStep context .stop immediate pending (effect context .stop immediate pending)
  | ld8 (context destination source immediate pending) : ShapeStep context (.ld8 destination source) immediate pending (effect context (.ld8 destination source) immediate pending)
  | halt (context immediate pending) : ShapeStep context .halt immediate pending (effect context .halt immediate pending)
  | aluA (context operation source immediate pending) : ShapeStep context (.aluA operation source) immediate pending (effect context (.aluA operation source) immediate pending)
  | retCond (context condition immediate pending) : ShapeStep context (.retCond condition) immediate pending (effect context (.retCond condition) immediate pending)
  | ret (context immediate pending) : ShapeStep context .ret immediate pending (effect context .ret immediate pending)
  | reti (context immediate pending) : ShapeStep context .reti immediate pending (effect context .reti immediate pending)
  | pop (context target immediate pending) : ShapeStep context (.pop target) immediate pending (effect context (.pop target) immediate pending)
  | jpCond (context condition immediate pending) : ShapeStep context (.jpCond condition) immediate pending (effect context (.jpCond condition) immediate pending)
  | jp (context immediate pending) : ShapeStep context .jp immediate pending (effect context .jp immediate pending)
  | jpHL (context immediate pending) : ShapeStep context .jpHL immediate pending (effect context .jpHL immediate pending)
  | ldhImmA (context immediate pending) : ShapeStep context .ldhImmA immediate pending (effect context .ldhImmA immediate pending)
  | ldhAImm (context immediate pending) : ShapeStep context .ldhAImm immediate pending (effect context .ldhAImm immediate pending)
  | ldhCA (context immediate pending) : ShapeStep context .ldhCA immediate pending (effect context .ldhCA immediate pending)
  | ldhAC (context immediate pending) : ShapeStep context .ldhAC immediate pending (effect context .ldhAC immediate pending)
  | ldAbsA (context immediate pending) : ShapeStep context .ldAbsA immediate pending (effect context .ldAbsA immediate pending)
  | ldAAbs (context immediate pending) : ShapeStep context .ldAAbs immediate pending (effect context .ldAAbs immediate pending)
  | addSP (context immediate pending) : ShapeStep context .addSP immediate pending (effect context .addSP immediate pending)
  | ldHLFromSPPlus (context immediate pending) : ShapeStep context .ldHLFromSPPlus immediate pending (effect context .ldHLFromSPPlus immediate pending)
  | ldSPHL (context immediate pending) : ShapeStep context .ldSPHL immediate pending (effect context .ldSPHL immediate pending)
  | di (context immediate pending) : ShapeStep context .di immediate pending (effect context .di immediate pending)
  | ei (context immediate pending) : ShapeStep context .ei immediate pending (effect context .ei immediate pending)
  | callCond (context condition immediate pending) : ShapeStep context (.callCond condition) immediate pending (effect context (.callCond condition) immediate pending)
  | push (context source immediate pending) : ShapeStep context (.push source) immediate pending (effect context (.push source) immediate pending)
  | call (context immediate pending) : ShapeStep context .call immediate pending (effect context .call immediate pending)
  | aluAImm (context operation immediate pending) : ShapeStep context (.aluAImm operation) immediate pending (effect context (.aluAImm operation) immediate pending)
  | rst (context vector immediate pending) : ShapeStep context (.rst vector) immediate pending (effect context (.rst vector) immediate pending)
  | cbRotate (context operation target immediate pending) : ShapeStep context (.cbRotate operation target) immediate pending (effect context (.cbRotate operation target) immediate pending)
  | bit (context index target immediate pending) : ShapeStep context (.bit index target) immediate pending (effect context (.bit index target) immediate pending)
  | res (context index target immediate pending) : ShapeStep context (.res index target) immediate pending (effect context (.res index target) immediate pending)
  | set (context index target immediate pending) : ShapeStep context (.set index target) immediate pending (effect context (.set index target) immediate pending)

namespace ShapeStep

/-- The two independently maintained family definitions agree universally. -/
theorem effect_eq_functional (context : Context) (shape : InstructionShape)
    (immediate : List Byte) (pending : Byte) :
    effect context shape immediate pending =
      Functional.executeShape context shape immediate pending := by
  cases shape <;> rfl

/-- The family relation has exactly the functional dispatcher's graph. -/
theorem iff_functional {before after : Context} {shape : InstructionShape}
    {immediate : List Byte} {pending : Byte} :
    ShapeStep before shape immediate pending after ↔
      Functional.executeShape before shape immediate pending = after := by
  constructor
  · intro step
    cases step <;> exact (effect_eq_functional _ _ _ _).symm
  · intro equation
    rw [← effect_eq_functional] at equation
    rw [← equation]
    cases shape <;> constructor

end ShapeStep
end Architectural
end Sm83
