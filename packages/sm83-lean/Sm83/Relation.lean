/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

import Sm83.Functional

namespace Sm83

/-- Declarative one-instruction judgment over architectural state and bus observations. -/
inductive InstructionStep : FunctionalState → Byte → List BusEvent → FunctionalState → Prop where
  | running {before after trace pending}
      (isRunning : before.mode = .running)
      (equation : Functional.step before pending = { state := after, trace }) :
      InstructionStep before pending trace after
  | quiescent {before pending}
      (notRunning : before.mode ≠ .running) :
      InstructionStep before pending [] before

namespace InstructionStep

/-- The declarative judgment has exactly the executable runner's graph. -/
theorem iff_functional {before after : FunctionalState} {pending : Byte} {trace : List BusEvent} :
    InstructionStep before pending trace after ↔
      Functional.step before pending = { state := after, trace } := by
  constructor
  · intro relation
    cases relation with
    | running _ equation => exact equation
    | quiescent notRunning =>
        simp [Functional.step, notRunning]
  · intro equation
    by_cases running : before.mode = .running
    · exact .running running equation
    · have unchanged : Functional.step before pending = { state := before, trace := [] } := by
        simp [Functional.step, running]
      rw [unchanged] at equation
      cases equation
      exact .quiescent running

/-- A valid bus response gives a unique architectural state and observation trace. -/
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
