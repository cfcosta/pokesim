/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

import Sm83.Architectural

namespace Sm83
namespace Architectural

open Functional

@[inline] def opcodeAt (state : FunctionalState) : Byte :=
  state.memory.read state.registers.pc

/-- State immediately after the base opcode fetch, including HALT-bug PC
suppression and the ordered opcode observation. -/
def opcodeContext (state : FunctionalState) : Context :=
  let address := state.registers.pc
  let opcode := state.memory.read address
  let nextPC := if state.haltBug then address else Word.ofNat (address.toNat + 1)
  { state := { state with registers := { state.registers with pc := nextPC }, haltBug := false }
    trace := [.read .opcode address opcode] }

@[inline] def prefixOpcode (state : FunctionalState) : Byte :=
  let context := opcodeContext state
  context.state.memory.read context.state.registers.pc

/-- State after fetching both bytes of a CB-prefixed instruction. -/
def prefixContext (state : FunctionalState) : Context :=
  let context := opcodeContext state
  let address := context.state.registers.pc
  let opcode := context.state.memory.read address
  { state := {
      context.state with
      registers := { context.state.registers with pc := Word.ofNat (address.toNat + 1) } }
    trace := context.trace ++ [.read .cbOpcode address opcode] }

@[inline] def fetchedImmediate (state : FunctionalState) (shape : InstructionShape) :
    List Byte × Context :=
  Functional.fetchImmediate shape.immediateBytes (opcodeContext state)

/-- Result of the architecturally defined invalid-opcode entry edge. -/
def lockedResult (state : FunctionalState) (opcode : Byte) : FunctionalResult :=
  let context := opcodeContext state
  { state := { context.state with mode := .locked opcode }, trace := context.trace }

end Architectural

/-- Declarative one-instruction judgment. Running constructors dispatch by
encoding class and require the independent family relation; no constructor calls
`Functional.step` or `Functional.executeShape`. -/
inductive InstructionStep : FunctionalState → Byte → List BusEvent → FunctionalState → Prop where
  | quiescent {before pending}
      (notRunning : before.mode ≠ .running) :
      InstructionStep before pending [] before
  | locked {before pending opcode payload}
      (running : before.mode = .running)
      (atPC : Architectural.opcodeAt before = opcode)
      (decoded : Decode.base opcode = .locked payload) :
      InstructionStep before pending
        (Architectural.lockedResult before opcode).trace
        (Architectural.lockedResult before opcode).state
  | cbPrefixed {before pending opcode after}
      (running : before.mode = .running)
      (atPC : Architectural.opcodeAt before = opcode)
      (decoded : Decode.base opcode = .prefix)
      (effect : Architectural.ShapeStep
        (Architectural.prefixContext before)
        (Decode.cb (Architectural.prefixOpcode before)) [] pending after) :
      InstructionStep before pending after.trace after.state
  | legal {before pending opcode shape after}
      (running : before.mode = .running)
      (atPC : Architectural.opcodeAt before = opcode)
      (decoded : Decode.base opcode = .legal shape)
      (effect : Architectural.ShapeStep
        (Architectural.fetchedImmediate before shape).2 shape
        (Architectural.fetchedImmediate before shape).1 pending after) :
      InstructionStep before pending after.trace after.state

namespace InstructionStep

/-- The independent architectural judgment is sound and complete for the
functional runner over every state and pending-interrupt input. -/
theorem iff_functional {before after : FunctionalState} {pending : Byte} {trace : List BusEvent} :
    InstructionStep before pending trace after ↔
      Functional.step before pending = { state := after, trace } := by
  constructor
  · intro relation
    cases relation with
    | quiescent notRunning =>
        simp [Functional.step, notRunning]
    | locked running atPC decoded =>
        simp [Architectural.opcodeAt] at atPC
        simp [Functional.step, running, atPC, decoded, Architectural.lockedResult,
          Architectural.opcodeContext]
    | cbPrefixed running atPC decoded effect =>
        rw [Architectural.ShapeStep.iff_functional] at effect
        cases effect
        simp [Architectural.opcodeAt] at atPC
        simp [Functional.step, running, atPC, decoded, Architectural.prefixContext,
          Architectural.prefixOpcode, Architectural.opcodeContext, Functional.read,
          Functional.withRegisters]
    | legal running atPC decoded effect =>
        rw [Architectural.ShapeStep.iff_functional] at effect
        cases effect
        simp [Architectural.opcodeAt] at atPC
        simp [Functional.step, running, atPC, decoded, Architectural.fetchedImmediate,
          Architectural.opcodeContext]
  · intro equation
    by_cases running : before.mode = .running
    · let opcode := Architectural.opcodeAt before
      have atPC : Architectural.opcodeAt before = opcode := rfl
      cases decoded : Decode.base opcode with
      | locked payload =>
          change Decode.base (before.memory.read before.registers.pc) = .locked payload at decoded
          have relation : InstructionStep before pending
              (Architectural.lockedResult before opcode).trace
              (Architectural.lockedResult before opcode).state :=
            .locked running atPC decoded
          have computed : Functional.step before pending =
              Architectural.lockedResult before opcode := by
            simp [Functional.step, running, opcode, Architectural.opcodeAt, decoded,
              Architectural.lockedResult, Architectural.opcodeContext]
          rw [computed] at equation
          cases equation
          exact relation
      | «prefix» =>
          change Decode.base (before.memory.read before.registers.pc) = .prefix at decoded
          have effect : Architectural.ShapeStep
              (Architectural.prefixContext before)
              (Decode.cb (Architectural.prefixOpcode before)) [] pending
              (Architectural.effect (Architectural.prefixContext before)
                (Decode.cb (Architectural.prefixOpcode before)) [] pending) := by
            cases Decode.cb (Architectural.prefixOpcode before) <;> constructor
          have relation : InstructionStep before pending
              (Architectural.effect (Architectural.prefixContext before)
                (Decode.cb (Architectural.prefixOpcode before)) [] pending).trace
              (Architectural.effect (Architectural.prefixContext before)
                (Decode.cb (Architectural.prefixOpcode before)) [] pending).state :=
            .cbPrefixed running atPC decoded effect
          have computed : Functional.step before pending =
              { state := (Architectural.effect (Architectural.prefixContext before)
                  (Decode.cb (Architectural.prefixOpcode before)) [] pending).state
                trace := (Architectural.effect (Architectural.prefixContext before)
                  (Decode.cb (Architectural.prefixOpcode before)) [] pending).trace } := by
            simp [Functional.step, running, decoded,
              Architectural.prefixContext, Architectural.prefixOpcode,
              Architectural.opcodeContext, Functional.read, Functional.withRegisters,
              Architectural.ShapeStep.effect_eq_functional]
          rw [computed] at equation
          cases equation
          exact relation
      | legal shape =>
          change Decode.base (before.memory.read before.registers.pc) = .legal shape at decoded
          have effect : Architectural.ShapeStep
              (Architectural.fetchedImmediate before shape).2 shape
              (Architectural.fetchedImmediate before shape).1 pending
              (Architectural.effect (Architectural.fetchedImmediate before shape).2 shape
                (Architectural.fetchedImmediate before shape).1 pending) := by
            cases shape <;> constructor
          have relation : InstructionStep before pending
              (Architectural.effect (Architectural.fetchedImmediate before shape).2 shape
                (Architectural.fetchedImmediate before shape).1 pending).trace
              (Architectural.effect (Architectural.fetchedImmediate before shape).2 shape
                (Architectural.fetchedImmediate before shape).1 pending).state :=
            .legal running atPC decoded effect
          have computed : Functional.step before pending =
              { state := (Architectural.effect (Architectural.fetchedImmediate before shape).2
                  shape (Architectural.fetchedImmediate before shape).1 pending).state
                trace := (Architectural.effect (Architectural.fetchedImmediate before shape).2
                  shape (Architectural.fetchedImmediate before shape).1 pending).trace } := by
            simp [Functional.step, running, decoded,
              Architectural.fetchedImmediate, Architectural.opcodeContext,
              Architectural.ShapeStep.effect_eq_functional]
          rw [computed] at equation
          cases equation
          exact relation
    · have unchanged : Functional.step before pending = { state := before, trace := [] } := by
        simp [Functional.step, running]
      rw [unchanged] at equation
      cases equation
      exact .quiescent running

/-- A valid flat-bus response gives a unique architectural state and trace. -/
theorem deterministic {before first second : FunctionalState} {pending : Byte}
    {firstTrace secondTrace : List BusEvent}
    (left : InstructionStep before pending firstTrace first)
    (right : InstructionStep before pending secondTrace second) :
    first = second ∧ firstTrace = secondTrace := by
  rw [iff_functional] at left right
  rw [left] at right
  cases right
  exact ⟨rfl, rfl⟩

/-- Invalid opcodes enter the explicit lock mode after their fetch observation. -/
theorem invalid_locks {before after : FunctionalState} {pending opcode : Byte} {trace : List BusEvent}
    (running : before.mode = .running)
    (atPC : before.memory.read before.registers.pc = opcode)
    (invalid : Decode.base opcode = .locked opcode)
    (step : InstructionStep before pending trace after) : after.mode = .locked opcode := by
  rw [iff_functional] at step
  simp [Functional.step, running, atPC, invalid] at step
  exact step.1.symm ▸ rfl

end InstructionStep
end Sm83
