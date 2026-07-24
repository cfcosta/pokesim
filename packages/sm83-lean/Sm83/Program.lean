/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

import Sm83.Functional
import Sm83.Run

namespace Sm83
namespace Program

inductive RunResult where
  | reached (state : FunctionalState) (trace : List BusEvent) (steps : Nat)
  | halted (state : FunctionalState) (trace : List BusEvent) (steps : Nat)
  | stopped (state : FunctionalState) (trace : List BusEvent) (steps : Nat)
  | locked (state : FunctionalState) (trace : List BusEvent) (steps : Nat)
  | fuelExhausted (state : FunctionalState) (trace : List BusEvent) (steps : Nat)

/-- Fuel-bounded instruction runner with semantic outcomes separate from exhaustion. -/
def runUntil (stop : FunctionalState → Bool) : Nat → FunctionalState → List BusEvent → Nat → RunResult
  | 0, state, trace, steps =>
      if stop state then .reached state trace steps else .fuelExhausted state trace steps
  | fuel + 1, state, trace, steps =>
      if stop state then .reached state trace steps
      else match state.mode with
        | .halted => .halted state trace steps
        | .stopped _ => .stopped state trace steps
        | .locked _ => .locked state trace steps
        | .running =>
            let result := Functional.step state
            runUntil stop fuel result.state (trace ++ result.trace) (steps + 1)

inductive Runs : FunctionalState → List Byte → FunctionalState → Prop where
  | nil (state) : Runs state [] state
  | cons {before middle after opcode rest}
      (opcodeAtPC : before.memory.read before.registers.pc = opcode)
      (step : (Functional.step before).state = middle)
      (tail : Runs middle rest after) : Runs before (opcode :: rest) after

@[simp] theorem Runs.refl (state : FunctionalState) : Runs state [] state := .nil state

/-- Any run over concatenated bytes has an explicit intermediate state. -/
theorem Runs.split {before after : FunctionalState} {left right : List Byte}
    (run : Runs before (left ++ right) after) :
    ∃ middle, Runs before left middle ∧ Runs middle right after := by
  induction left generalizing before with
  | nil => exact ⟨before, .nil before, by simpa using run⟩
  | cons opcode rest induction =>
      cases run with
      | cons opcodeAtPC step tail =>
          obtain ⟨middle, leftPart, rightPart⟩ := induction tail
          exact ⟨middle, .cons opcodeAtPC step leftPart, rightPart⟩

/-- Relational byte-program execution composes transitively. -/
theorem Runs.trans {first middle last : FunctionalState} {left right : List Byte}
    (leftRun : Runs first left middle) (rightRun : Runs middle right last) :
    Runs first (left ++ right) last := by
  induction leftRun with
  | nil => simpa using rightRun
  | cons opcodeAtPC step tail induction =>
      exact .cons opcodeAtPC step (induction rightRun)

inductive ReturnSentinel (address : Word) : CoreState → Prop where
  | notFetched (state) (pc : state.registers.pc = address) (ir : state.ir = none) :
      ReturnSentinel address state
  | prefetched (state) (fetched : state.ir.map (·.address) = some address) :
      ReturnSentinel address state
  | inIR (state) (fetched : FetchedIR) (ir : state.ir = some fetched)
      (atAddress : fetched.address = address) : ReturnSentinel address state

/-- A de-overlapped return uses architectural PC equality. -/
def ReturnsTo (address : Word) (state : FunctionalState) : Prop := state.registers.pc = address

end Program
end Sm83
