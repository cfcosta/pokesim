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
