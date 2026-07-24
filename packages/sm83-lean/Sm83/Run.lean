/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

import Sm83.Pipeline

namespace Sm83

structure CoreOutput where
  state : CoreState
  intent : CycleIntent
  deriving Repr, DecidableEq

namespace Run

private def memAddress (registers : Registers) : Mem16 → Word
  | .atBC => registers.bc
  | .atDE => registers.de
  | .atHLInc | .atHLDec => registers.hl

private def targetValue (registers : Registers) (latch : Byte) : Target8 → Byte
  | .reg register => registers.get8 register
  | .atHL => latch

private def setTarget (registers : Registers) (target : Target8) (value : Byte) : Registers :=
  match target with
  | .reg register => registers.set8 register value
  | .atHL => registers

private def readAddress (state : CoreState) : Word :=
  match state.shape with
  | some (.ldMem16A memory) | some (.ldAFromMem16 memory) => memAddress state.registers memory
  | some .ldhImmA | some .ldhAImm => Word.ofNat (0xFF00 + state.latches.low.toNat)
  | some .ldhCA | some .ldhAC => Word.ofNat (0xFF00 + state.registers.c.toNat)
  | _ => state.wz

private def successorAddress (state : CoreState) : Word :=
  match state.shape with
  | some .jr => state.registers.pc.addSignedByte state.latches.low
  | some (.jrCond _) =>
      if state.latches.conditionTaken then state.registers.pc.addSignedByte state.latches.low
      else state.registers.pc
  | some .jp | some .call => state.wz
  | some (.jpCond _) | some (.callCond _) =>
      if state.latches.conditionTaken then state.wz else state.registers.pc
  | some .jpHL => state.registers.hl
  | some .ret | some .reti => state.wz
  | some (.retCond _) => if state.latches.conditionTaken then state.wz else state.registers.pc
  | some (.rst vector) => Word.ofNat (8 * vector.val)
  | _ => state.registers.pc

private def writeValue (state : CoreState) (operation : MicroOp) : Byte :=
  let registers := state.registers
  match operation, state.shape with
  | .writeHL, some (.ld8 _ source) => targetValue registers state.latches.data source
  | .writeHL, some (.ld8Imm _) => state.latches.low
  | .writeHL, some (.inc8 _) => (Alu.inc8 state.latches.data registers.flags).value
  | .writeHL, some (.dec8 _) => (Alu.dec8 state.latches.data registers.flags).value
  | .writeHL, some (.cbRotate rotate _) => (Alu.rotate rotate state.latches.data registers.flags.c).value
  | .writeHL, some (.res index _) => Alu.resetBit index state.latches.data
  | .writeHL, some (.set index _) => Alu.setBit index state.latches.data
  | .writeAddress, some (.ldMem16A _) => registers.a
  | .writeAddress, some .ldAbsSP => registers.sp.lowByte
  | .writeAddressNext, some .ldAbsSP => registers.sp.highByte
  | .writeAddress, some .ldhImmA | .writeAddress, some .ldhCA
  | .writeAddress, some .ldAbsA => registers.a
  | .stackWriteHigh, some (.push source) => (registers.getStack16 source).highByte
  | .stackWriteLow, some (.push source) => (registers.getStack16 source).lowByte
  | .stackWriteHigh, _ => registers.pc.highByte
  | .stackWriteLow, _ => registers.pc.lowByte
  | _, _ => state.latches.data

private def opAddress (state : CoreState) (operation : MicroOp) : Word :=
  match operation with
  | .opcodeFetch | .cbFetch | .immediate8 | .immediateLow | .immediateHigh => state.registers.pc
  | .readHL | .writeHL => state.registers.hl
  | .readAddress | .writeAddress => readAddress state
  | .writeAddressNext => Word.ofNat (state.wz.toNat + 1)
  | .stackInitialDecrement | .stackWriteHigh | .stackWriteLow
  | .stackReadLow | .stackReadHigh => state.registers.sp
  | .successorFetch => successorAddress state
  | .internal => state.registers.pc

private def opControl : MicroOp → BusControl
  | .opcodeFetch | .cbFetch | .immediate8 | .immediateLow | .immediateHigh
  | .readHL | .readAddress | .stackReadLow | .stackReadHigh | .successorFetch => .read
  | .writeHL | .writeAddress | .writeAddressNext | .stackWriteHigh | .stackWriteLow => .write
  | .internal | .stackInitialDecrement => .idle

private def opReadKind : MicroOp → ReadKind
  | .opcodeFetch | .successorFetch => .opcode
  | .cbFetch => .cbOpcode
  | .immediate8 | .immediateLow | .immediateHigh => .immediate
  | .stackReadLow | .stackReadHigh => .stack
  | _ => .data

private def opIdu (state : CoreState) (operation : MicroOp) : IduIntent :=
  let address := opAddress state operation
  match operation with
  | .opcodeFetch | .cbFetch | .immediate8 | .immediateLow | .immediateHigh | .successorFetch =>
      { source := .pc, direction := .increment, destination := .pc, oldAddress := address }
  | .stackInitialDecrement | .stackWriteHigh =>
      { source := .sp, direction := .decrement, destination := .sp, oldAddress := address }
  | .stackReadLow | .stackReadHigh =>
      { source := .sp, direction := .increment, destination := .sp, oldAddress := address }
  | _ => { oldAddress := address }

private def intent (state : CoreState) (operation : MicroOp) : CycleIntent :=
  let control := opControl operation
  { address := opAddress state operation
    control
    data := if control = .write then .driven (writeValue state operation) else .released
    readKind := opReadKind operation
    fetch := match operation with
      | .successorFetch => if state.shape == some .halt then .haltDummy else .generic
      | .cbFetch => .cbSubopcode
      | _ => .none
    idu := opIdu state operation
    commit := if operation = .successorFetch then
      { registers := true, flags := true, pc := true, sp := true, ir := true, ime := true }
      else {}
    poll := match operation, state.shape with
      | .successorFetch, some .di => .suppressForDI
      | .successorFetch, _ => .genericFetch
      | _, _ => .none }

private def updatePointer (state : CoreState) : CoreState :=
  match state.shape with
  | some (.ldMem16A .atHLInc) | some (.ldAFromMem16 .atHLInc) =>
      { state with registers := state.registers.setHL (Word.ofNat (state.registers.hl.toNat + 1)) }
  | some (.ldMem16A .atHLDec) | some (.ldAFromMem16 .atHLDec) =>
      { state with registers := state.registers.setHL (Word.ofNat (state.registers.hl.toNat + 65535)) }
  | _ => state

private def commitRegisters (state : CoreState) : Registers :=
  let registers := state.registers
  let low := state.latches.low
  let operand := state.latches.data
  match state.shape with
  | none => registers
  | some .nop | some .stop | some .halt | some .di | some .ei => registers
  | some (.ld16Imm destination) => registers.set16 destination state.wz
  | some (.ldAFromMem16 _) | some .ldhAImm | some .ldhAC | some .ldAAbs =>
      { registers with a := operand }
  | some (.ldMem16A _) | some .ldAbsSP | some .ldhImmA | some .ldhCA | some .ldAbsA => registers
  | some (.inc16 target) => registers.set16 target (Word.ofNat ((registers.get16 target).toNat + 1))
  | some (.dec16 target) => registers.set16 target (Word.ofNat ((registers.get16 target).toNat + 65535))
  | some (.addHL source) =>
      let result := Alu.addHL registers.hl (registers.get16 source) registers.flags
      { registers.setHL result.value with flags := result.flags }
  | some (.inc8 target) =>
      let value := targetValue registers operand target
      let result := Alu.inc8 value registers.flags
      { setTarget registers target result.value with flags := result.flags }
  | some (.dec8 target) =>
      let value := targetValue registers operand target
      let result := Alu.dec8 value registers.flags
      { setTarget registers target result.value with flags := result.flags }
  | some (.ld8Imm target) => setTarget registers target low
  | some (.accRotate operation) =>
      let result := Alu.accumulatorRotate operation registers.a registers.flags.c
      { registers with a := result.value, flags := result.flags }
  | some .daa =>
      let result := Alu.daa registers.a registers.flags
      { registers with a := result.value, flags := result.flags }
  | some .cpl => { registers with a := ~~~registers.a, flags := { registers.flags with n := true, h := true } }
  | some .scf => { registers with flags := { registers.flags with n := false, h := false, c := true } }
  | some .ccf => { registers with flags := { registers.flags with n := false, h := false, c := !registers.flags.c } }
  | some .jr | some (.jrCond _) | some (.retCond _) | some .ret | some .reti
  | some (.jpCond _) | some .jp | some .jpHL | some (.callCond _) | some .call | some (.rst _) => registers
  | some (.ld8 destination source) => setTarget registers destination (targetValue registers operand source)
  | some (.aluA operation source) =>
      let result := Alu.apply operation registers.a (targetValue registers operand source) registers.flags
      { registers with a := result.value, flags := result.flags }
  | some (.pop target) => registers.setStack16 target state.wz
  | some (.push _) => registers
  | some .addSP =>
      let result := Alu.addSignedSP registers.sp low
      { registers with sp := result.value, flags := result.flags }
  | some .ldHLFromSPPlus =>
      let result := Alu.addSignedSP registers.sp low
      { registers.setHL result.value with flags := result.flags }
  | some .ldSPHL => { registers with sp := registers.hl }
  | some (.aluAImm operation) =>
      let result := Alu.apply operation registers.a low registers.flags
      { registers with a := result.value, flags := result.flags }
  | some (.cbRotate operation target) =>
      let result := Alu.rotate operation (targetValue registers operand target) registers.flags.c
      { setTarget registers target result.value with flags := result.flags }
  | some (.bit index target) =>
      { registers with flags := Alu.testBit index (targetValue registers operand target) registers.flags }
  | some (.res index target) => setTarget registers target (Alu.resetBit index (targetValue registers operand target))
  | some (.set index target) => setTarget registers target (Alu.setBit index (targetValue registers operand target))

private def commitIme (state : CoreState) : Bool × Bool :=
  match state.shape with
  | some .di => (false, false)
  | some .ei => (state.ime || state.scheduledImeEnable, true)
  | some .reti => (true, false)
  | _ => if state.scheduledImeEnable then (true, false) else (state.ime, false)

private def processNonFetch (state : CoreState) (operation : MicroOp) (input : CoreInput) : CoreState :=
  let state := { state with remaining := state.remaining.drop 1 }
  match operation with
  | .cbFetch =>
      let address := state.registers.pc
      let state := { state with registers := { state.registers with pc := Word.ofNat (address.toNat + 1) } }
      Pipeline.installCB state input.read.fold
  | .immediate8 | .immediateLow =>
      let address := state.registers.pc
      let state := {
        state with
        registers := { state.registers with pc := Word.ofNat (address.toNat + 1) }
        latches := { state.latches with low := input.read.fold } }
      if state.shape == some .stop then
        { state with mode := .stopped input.read.fold, remaining := [] }
      else state
  | .immediateHigh =>
      let address := state.registers.pc
      { state with
        registers := { state.registers with pc := Word.ofNat (address.toNat + 1) }
        latches := { state.latches with high := input.read.fold } }
  | .readHL | .readAddress =>
      updatePointer { state with latches := { state.latches with data := input.read.fold } }
  | .writeAddress => updatePointer state
  | .stackInitialDecrement =>
      { state with registers := { state.registers with sp := Word.ofNat (state.registers.sp.toNat + 65535) } }
  | .stackWriteHigh =>
      { state with registers := { state.registers with sp := Word.ofNat (state.registers.sp.toNat + 65535) } }
  | .stackReadLow =>
      { state with
        registers := { state.registers with sp := Word.ofNat (state.registers.sp.toNat + 1) }
        latches := { state.latches with low := input.read.fold } }
  | .stackReadHigh =>
      { state with
        registers := { state.registers with sp := Word.ofNat (state.registers.sp.toNat + 1) }
        latches := { state.latches with high := input.read.fold } }
  | _ => state

private def finishSuccessor (state : CoreState) (input : CoreInput) : CoreState :=
  let target := successorAddress state
  let registers := commitRegisters state
  let imeUpdate := commitIme state
  match state.shape with
  | some .halt =>
      let effectiveIme := state.ime || state.scheduledImeEnable
      if !effectiveIme && input.pendingInterrupts.toNat != 0 then
        let registers := { registers with pc := target }
        let state := { state with registers := registers }
        let state := { state with ime := imeUpdate.1 }
        let state := { state with scheduledImeEnable := imeUpdate.2 }
        let state := { state with haltBug := true }
        Pipeline.install state target input.read.fold
      else
        let state := { state with registers := { registers with pc := target } }
        let state := { state with ime := imeUpdate.1 }
        let state := { state with scheduledImeEnable := imeUpdate.2 }
        let state := { state with mode := .halted }
        { state with remaining := [] }
  | _ =>
      let registers := { registers with pc := Word.ofNat (target.toNat + 1) }
      let state := { state with registers := registers }
      let state := { state with ime := imeUpdate.1 }
      let state := { state with scheduledImeEnable := imeUpdate.2 }
      Pipeline.install state target input.read.fold

/-- Advance one physical fetched-IR M-cycle carrying exactly four CPU T-cycles. -/
def stepMachineCycle (state : CoreState) (input : CoreInput) : CoreOutput :=
  match state.mode with
  | .locked _ =>
      let heldIntent : CycleIntent := {
        address := (state.ir.map (fun fetched => fetched.address)).getD state.registers.pc
        clocks := { cpuExecution := true, machine := true, oscillator := true } }
      { state := state, intent := heldIntent }
  | .halted =>
      let haltedIntent : CycleIntent := {
        address := state.registers.pc
        clocks := { cpuExecution := false, machine := true, oscillator := true } }
      { state := state, intent := haltedIntent }
  | .stopped _ =>
      let stoppedIntent : CycleIntent := {
        address := state.registers.pc
        clocks := { cpuExecution := false, machine := false, oscillator := false } }
      { state := state, intent := stoppedIntent }
  | .running =>
      match state.phase with
      | .bootstrap =>
          let address := state.registers.pc
          let next := Pipeline.install
            { state with registers := { state.registers with pc := Word.ofNat (address.toNat + 1) } }
            address input.read.fold
          let fetchIntent : CycleIntent := {
            address := address
            control := .read
            readKind := .opcode
            fetch := .generic
            idu := { source := .pc, direction := .increment, destination := .pc, oldAddress := address }
            commit := { pc := true, ir := true }
            poll := .genericFetch }
          { state := next, intent := fetchIntent }
      | .execute =>
          match state.currentOp? with
          | none =>
              let emptyIntent : CycleIntent := { address := state.registers.pc }
              { state := state, intent := emptyIntent }
          | some operation =>
              let cycleIntent := intent state operation
              let next := if operation = .successorFetch then finishSuccessor state input
                else processNonFetch state operation input
              { state := next, intent := cycleIntent }

/-- Fuel-bounded physical runner. Fuel exhaustion is represented by returning the current state. -/
def runMachineCycles : Nat → CoreState → (CoreState → CoreInput) → CoreState
  | 0, state, _ => state
  | fuel + 1, state, respond =>
      let output := stepMachineCycle state (respond state)
      runMachineCycles fuel output.state respond

end Run
end Sm83
