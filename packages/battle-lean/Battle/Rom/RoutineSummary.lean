/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Driver
import Sm83.Hoare

/-!
# Compositional decoded-routine execution

`Driver.runToReturn` is useful for closed executable checks, but unfolding a
whole routine is a poor proof principle for loops over symbolic memory. This
module exposes exact-count execution and a decoded-one-step equation that can be
composed instruction by instruction. Fuel remains outside these summaries: a
`runSteps n` value means exactly `n` architectural instructions executed.
-/

namespace Battle.Rom.RoutineSummary

open Sm83

structure Execution where
  state : FunctionalState
  trace : List BusEvent

/-- Execute exactly `count` programmer-visible instructions, retaining the full
ordered M-cycle trace. A non-running state is stable because `Functional.step`
has that behavior; routine contracts normally assume `.running`. -/
def runSteps : Nat → FunctionalState → Execution
  | 0, state => { state, trace := [] }
  | count + 1, state =>
      let first := Functional.step state
      let rest := runSteps count first.state
      { state := rest.state, trace := first.trace ++ rest.trace }

@[simp] theorem runSteps_zero (state : FunctionalState) :
    runSteps 0 state = { state, trace := [] } := rfl

/-- Exact-count executions compose without exposing or re-evaluating either
sub-block. -/
theorem runSteps_add (left right : Nat) (state : FunctionalState) :
    runSteps (left + right) state =
      let firstRun := runSteps left state
      let secondRun := runSteps right firstRun.state
      { state := secondRun.state, trace := firstRun.trace ++ secondRun.trace } := by
  induction left generalizing state with
  | zero => simp [runSteps]
  | succ left induction =>
      simp only [Nat.succ_add, runSteps]
      rw [induction]
      simp [List.append_assoc]

/-- The common precondition for local battle routines that do not schedule IME
changes or enter HALT/STOP/lock. -/
def Quiet (state : FunctionalState) : Prop :=
  state.mode = .running ∧ state.haltBug = false ∧ state.scheduledImeEnable = false

/-- The legal branch of `Functional.step`, factored so a caller can rewrite one
known opcode without unfolding the complete 256-way decoder. -/
def legalResult (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (pendingInterrupts : Byte := 0) : FunctionalResult :=
  let opcodeAddress := state.registers.pc
  let nextPc := if state.haltBug then opcodeAddress else Word.ofNat (opcodeAddress.toNat + 1)
  let context : Functional.Context :=
    { state := { state with registers := { state.registers with pc := nextPc }, haltBug := false }
      trace := [.read .opcode opcodeAddress opcode] }
  let (immediate, context) := Functional.fetchImmediate shape.immediateBytes context
  let context := Functional.executeShape context shape immediate pendingInterrupts
  { state := context.state, trace := context.trace }

/-- A memory byte and decoder equality select exactly one legal instruction
shape. This is the reusable bridge from caller-supplied canonical bytes to a
small symbolic state transformer. -/
theorem step_legal (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape)
    (running : state.mode = .running)
    (opcodeAtPc : state.memory.read state.registers.pc = opcode)
    (decoded : Decode.base opcode = .legal shape) :
    Functional.step state = legalResult state opcode shape := by
  simp [Functional.step, legalResult, running, opcodeAtPc, decoded]

/-- State-only projection of `step_legal`. -/
theorem step_legal_state (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape)
    (running : state.mode = .running)
    (opcodeAtPc : state.memory.read state.registers.pc = opcode)
    (decoded : Decode.base opcode = .legal shape) :
    (Functional.step state).state = (legalResult state opcode shape).state := by
  rw [step_legal state opcode shape running opcodeAtPc decoded]

/-- Trace-only projection of `step_legal`. -/
theorem step_legal_trace (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape)
    (running : state.mode = .running)
    (opcodeAtPc : state.memory.read state.registers.pc = opcode)
    (decoded : Decode.base opcode = .legal shape) :
    (Functional.step state).trace = (legalResult state opcode shape).trace := by
  rw [step_legal state opcode shape running opcodeAtPc decoded]

private theorem increment_bounded : ∀ address : Word, ∀ offset : Fin 8,
    Word.ofNat ((Word.ofNat (address.toNat + offset.val)).toNat + 1) =
      Word.ofNat (address.toNat + offset.val + 1) := by
  native_decide

@[simp] theorem increment_twice (address : Word) :
    Word.ofNat ((Word.ofNat (address.toNat + 1)).toNat + 1) =
      Word.ofNat (address.toNat + 2) := increment_bounded address ⟨1, by omega⟩

@[simp] theorem increment_after_two (address : Word) :
    Word.ofNat ((Word.ofNat (address.toNat + 2)).toNat + 1) =
      Word.ofNat (address.toNat + 3) := increment_bounded address ⟨2, by omega⟩

@[simp] theorem increment_after_three (address : Word) :
    Word.ofNat ((Word.ofNat (address.toNat + 3)).toNat + 1) =
      Word.ofNat (address.toNat + 4) := increment_bounded address ⟨3, by omega⟩

@[simp] theorem increment_after_four (address : Word) :
    Word.ofNat ((Word.ofNat (address.toNat + 4)).toNat + 1) =
      Word.ofNat (address.toNat + 5) := increment_bounded address ⟨4, by omega⟩

@[simp] theorem increment_after_five (address : Word) :
    Word.ofNat ((Word.ofNat (address.toNat + 5)).toNat + 1) =
      Word.ofNat (address.toNat + 6) := increment_bounded address ⟨5, by omega⟩

@[simp] theorem increment_after_six (address : Word) :
    Word.ofNat ((Word.ofNat (address.toNat + 6)).toNat + 1) =
      Word.ofNat (address.toNat + 7) := increment_bounded address ⟨6, by omega⟩

@[simp] theorem increment_after_seven (address : Word) :
    Word.ofNat ((Word.ofNat (address.toNat + 7)).toNat + 1) =
      Word.ofNat (address.toNat + 8) := increment_bounded address ⟨7, by omega⟩

def advancePc (state : FunctionalState) : Registers :=
  { state.registers with pc := Word.ofNat (state.registers.pc.toNat + 1) }

/-- State transformer for `LD A,[HL+]`. -/
def ldAFromHlInc (s : FunctionalState) : FunctionalState :=
  let registers := (advancePc s).setHL (Word.ofNat (s.registers.hl.toNat + 1))
  let registers := { registers with a := s.memory.read s.registers.hl }
  let s := { s with registers }
  { s with haltBug := false }

/-- State transformer for `LD [DE],A`. -/
def ldAtDeA (s : FunctionalState) : FunctionalState :=
  let memory := s.memory.write s.registers.de s.registers.a
  let s := { s with registers := advancePc s }
  let s := { s with memory }
  { s with haltBug := false }

/-- State transformer for `INC DE`. -/
def incDe (s : FunctionalState) : FunctionalState :=
  let registers := (advancePc s).setDE (Word.ofNat (s.registers.de.toNat + 1))
  let s := { s with registers }
  { s with haltBug := false }

/-- State transformer for `DEC B`, including exact flags. -/
def decB (s : FunctionalState) : FunctionalState :=
  let registers := advancePc s
  let result := Alu.dec8 registers.b registers.flags
  let registers := registers.set8 .b result.value
  let registers := { registers with flags := result.flags }
  let s := { s with registers }
  { s with haltBug := false }

/-- State transformer for `JR NZ,e8`. -/
def jrNz (state : FunctionalState) : FunctionalState :=
  let afterOpcode := Word.ofNat (state.registers.pc.toNat + 1)
  let afterImmediate := Word.ofNat (afterOpcode.toNat + 1)
  let registers := { state.registers with pc := afterImmediate }
  let registers := if Alu.conditionHolds .nz registers.flags then
    { registers with pc := (registers.pc.addSignedByte
      (state.memory.read (Word.ofNat (state.registers.pc.toNat + 1)))) }
    else registers
  { state with registers, haltBug := false }

macro "routine_instruction_simp" : tactic => `(tactic|
  simp [legalResult, InstructionShape.immediateBytes, Functional.fetchImmediate,
    Functional.executeShape, Functional.readMem16, Functional.writeMem16,
    Functional.read, Functional.write, Functional.idle, Functional.withRegisters,
    Functional.updateMemoryPointer, Functional.memoryAddress, Functional.readTarget,
    Functional.writeTarget, Functional.matureIme, Functional.setFlags,
    Registers.setHL, Registers.setDE, Registers.hl, Registers.de, Registers.set8,
    Registers.set16, Registers.get16, Registers.get8, Functional.immediate8,
    Word.highByte, Word.lowByte, advancePc, ldAFromHlInc, ldAtDeA, incDe, decB,
    jrNz, *])

/-- Exact decoded `LD A,[HL+]` state equation. -/
theorem step_ldAFromHlInc (state : FunctionalState)
    (running : state.mode = .running) (scheduled : state.scheduledImeEnable = false)
    (noHaltBug : state.haltBug = false)
    (opcode : state.memory.read state.registers.pc = 0x2A) :
    (Functional.step state).state = ldAFromHlInc state := by
  have decoded : Decode.base (0x2A : Byte) = .legal (.ldAFromMem16 .atHLInc) := by
    native_decide
  rw [step_legal_state state 0x2A _ running opcode decoded]
  routine_instruction_simp

/-- Exact decoded `LD [DE],A` state equation. -/
theorem step_ldAtDeA (state : FunctionalState)
    (running : state.mode = .running) (scheduled : state.scheduledImeEnable = false)
    (noHaltBug : state.haltBug = false)
    (opcode : state.memory.read state.registers.pc = 0x12) :
    (Functional.step state).state = ldAtDeA state := by
  have decoded : Decode.base (0x12 : Byte) = .legal (.ldMem16A .atDE) := by
    native_decide
  rw [step_legal_state state 0x12 _ running opcode decoded]
  routine_instruction_simp

/-- Exact decoded `INC DE` state equation. -/
theorem step_incDe (state : FunctionalState)
    (running : state.mode = .running) (scheduled : state.scheduledImeEnable = false)
    (noHaltBug : state.haltBug = false)
    (opcode : state.memory.read state.registers.pc = 0x13) :
    (Functional.step state).state = incDe state := by
  have decoded : Decode.base (0x13 : Byte) = .legal (.inc16 .de) := by native_decide
  rw [step_legal_state state 0x13 _ running opcode decoded]
  routine_instruction_simp

/-- Exact decoded `DEC B` state equation. -/
theorem step_decB (state : FunctionalState)
    (running : state.mode = .running) (scheduled : state.scheduledImeEnable = false)
    (noHaltBug : state.haltBug = false)
    (opcode : state.memory.read state.registers.pc = 0x05) :
    (Functional.step state).state = decB state := by
  have decoded : Decode.base (0x05 : Byte) = .legal (.dec8 (.reg .b)) := by native_decide
  rw [step_legal_state state 0x05 _ running opcode decoded]
  routine_instruction_simp

/-- Exact decoded `JR NZ,e8` state equation. -/
theorem step_jrNz (state : FunctionalState)
    (running : state.mode = .running) (scheduled : state.scheduledImeEnable = false)
    (noHaltBug : state.haltBug = false)
    (opcode : state.memory.read state.registers.pc = 0x20) :
    (Functional.step state).state = jrNz state := by
  have decoded : Decode.base (0x20 : Byte) = .legal (.jrCond .nz) := by native_decide
  rw [step_legal_state state 0x20 _ running opcode decoded]
  routine_instruction_simp
  split <;> rfl

/-- A write-set frame composes through an explicit intermediate state. -/
theorem frames_trans {first middle last : FunctionalState}
    {leftWrites rightWrites : Word → Prop}
    (left : Hoare.Frames leftWrites first middle)
    (right : Hoare.Frames rightWrites middle last) :
    Hoare.Frames (fun address => leftWrites address ∨ rightWrites address) first last := by
  intro address outside
  have outsideLeft : ¬leftWrites address := fun inside => outside (Or.inl inside)
  have outsideRight : ¬rightWrites address := fun inside => outside (Or.inr inside)
  rw [right address outsideRight, left address outsideLeft]

end Battle.Rom.RoutineSummary
