/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

import Sm83.Alu
import Sm83.Decode
import Sm83.FlatMemory

namespace Sm83

inductive RunMode where
  | running | halted | stopped (prefetched : Byte) | locked (opcode : Byte)
  deriving Repr, DecidableEq, Inhabited

structure FunctionalState where
  registers : Registers := {}
  memory : FlatMemory := default
  ime : Bool := false
  scheduledImeEnable : Bool := false
  haltBug : Bool := false
  mode : RunMode := .running

structure FunctionalResult where
  state : FunctionalState
  trace : List BusEvent

namespace Functional

structure Context where
  state : FunctionalState
  trace : List BusEvent := []

def read (context : Context) (kind : ReadKind) (address : Word) : Byte × Context :=
  let value := context.state.memory.read address
  (value, { context with trace := context.trace ++ [.read kind address value] })

def write (context : Context) (address : Word) (value : Byte) : Context :=
  { state := { context.state with memory := context.state.memory.write address value }
    trace := context.trace ++ [.write address value] }

def idle (context : Context) (address : Word) : Context :=
  { context with trace := context.trace ++ [.idle address] }

def withRegisters (context : Context) (registers : Registers) : Context :=
  { context with state := { context.state with registers } }

def fetchImmediate : (count : Nat) → Context → List Byte × Context
  | 0, context => ([], context)
  | count + 1, context =>
      let address := context.state.registers.pc
      let (value, context) := read context .immediate address
      let context := withRegisters context { context.state.registers with pc := Word.ofNat (address.toNat + 1) }
      let (rest, context) := fetchImmediate count context
      (value :: rest, context)

def immediate8 (bytes : List Byte) : Byte := bytes.getD 0 0

def immediate16 (bytes : List Byte) : Word :=
  Word.ofBytes (bytes.getD 1 0) (bytes.getD 0 0)

def readTarget (context : Context) : Target8 → Byte × Context
  | .reg register => (context.state.registers.get8 register, context)
  | .atHL => read context .data context.state.registers.hl

def writeTarget (context : Context) (target : Target8) (value : Byte) : Context :=
  match target with
  | .reg register => withRegisters context (context.state.registers.set8 register value)
  | .atHL => write context context.state.registers.hl value

def memoryAddress (registers : Registers) : Mem16 → Word
  | .atBC => registers.bc
  | .atDE => registers.de
  | .atHLInc | .atHLDec => registers.hl

def updateMemoryPointer (registers : Registers) : Mem16 → Registers
  | .atHLInc => registers.setHL (Word.ofNat (registers.hl.toNat + 1))
  | .atHLDec => registers.setHL (Word.ofNat (registers.hl.toNat + 65535))
  | .atBC | .atDE => registers

def readMem16 (context : Context) (source : Mem16) : Byte × Context :=
  let address := memoryAddress context.state.registers source
  let (value, context) := read context .data address
  (value, withRegisters context (updateMemoryPointer context.state.registers source))

def writeMem16 (context : Context) (destination : Mem16) (value : Byte) : Context :=
  let address := memoryAddress context.state.registers destination
  let context := write context address value
  withRegisters context (updateMemoryPointer context.state.registers destination)

def decrementSP (registers : Registers) : Registers :=
  { registers with sp := Word.ofNat (registers.sp.toNat + 65535) }

def incrementSP (registers : Registers) : Registers :=
  { registers with sp := Word.ofNat (registers.sp.toNat + 1) }

/-- Initial idle/decrement, high write/decrement, then low write: exactly two decrements. -/
def pushWord (context : Context) (value : Word) : Context :=
  let context := idle context context.state.registers.sp
  let context := withRegisters context (decrementSP context.state.registers)
  let context := write context context.state.registers.sp value.highByte
  let context := withRegisters context (decrementSP context.state.registers)
  write context context.state.registers.sp value.lowByte

def popWord (context : Context) : Word × Context :=
  let (low, context) := read context .stack context.state.registers.sp
  let context := withRegisters context (incrementSP context.state.registers)
  let (high, context) := read context .stack context.state.registers.sp
  let context := withRegisters context (incrementSP context.state.registers)
  (Word.ofBytes high low, context)

def matureIme (context : Context) : Context :=
  if context.state.scheduledImeEnable then
    { context with state := { context.state with ime := true, scheduledImeEnable := false } }
  else context

def setFlags (context : Context) (flags : Flags) : Context :=
  withRegisters context { context.state.registers with flags }

def executeShape (context : Context) (shape : InstructionShape) (immediate : List Byte)
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

/-- Execute one programmer-visible instruction through a side-effect-free flat bus. -/
def step (state : FunctionalState) (pendingInterrupts : Byte := 0) : FunctionalResult :=
  if state.mode != .running then { state, trace := [] }
  else
    let opcodeAddress := state.registers.pc
    let opcode := state.memory.read opcodeAddress
    let nextPc := if state.haltBug then opcodeAddress else Word.ofNat (opcodeAddress.toNat + 1)
    let context : Context := {
      state := { state with registers := { state.registers with pc := nextPc }, haltBug := false }
      trace := [.read .opcode opcodeAddress opcode] }
    match Decode.base opcode with
    | .locked _ =>
        { state := { context.state with mode := .locked opcode }, trace := context.trace }
    | .prefix =>
        let address := context.state.registers.pc
        let (cbOpcode, context) := read context .cbOpcode address
        let context := withRegisters context {
          context.state.registers with pc := Word.ofNat (address.toNat + 1) }
        let context := executeShape context (Decode.cb cbOpcode) [] pendingInterrupts
        { state := context.state, trace := context.trace }
    | .legal shape =>
        let (immediate, context) := fetchImmediate shape.immediateBytes context
        let context := executeShape context shape immediate pendingInterrupts
        { state := context.state, trace := context.trace }

@[inline] def mcycles (result : FunctionalResult) : MCycles :=
  ⟨result.trace.length⟩

@[inline] def tcycles (result : FunctionalResult) : TCycles := (mcycles result).toT

end Functional
end Sm83
