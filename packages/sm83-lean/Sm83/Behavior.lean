/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

import Sm83.Byte

namespace Sm83

/-- Reflexive, transitive closure of a trace-labelled small-step relation. -/
inductive TraceSteps {State Event : Type}
    (Step : State → List Event → State → Prop) : State → List Event → State → Prop where
  | refl (state) : TraceSteps Step state [] state
  | tail {first middle last traceBefore traceAfter}
      (before : TraceSteps Step first traceBefore middle)
      (step : Step middle traceAfter last) :
      TraceSteps Step first (traceBefore ++ traceAfter) last

namespace TraceSteps

@[simp] theorem one {State Event : Type} {Step : State → List Event → State → Prop}
    {before after : State} {trace : List Event} (step : Step before trace after) :
    TraceSteps Step before trace after := by
  simpa using TraceSteps.tail (TraceSteps.refl before) step

/-- Finite executions compose without imposing determinism. -/
theorem trans {State Event : Type} {Step : State → List Event → State → Prop}
    {first middle last : State} {left right : List Event}
    (before : TraceSteps Step first left middle)
    (after : TraceSteps Step middle right last) :
    TraceSteps Step first (left ++ right) last := by
  induction after with
  | refl => simpa using before
  | tail _ step induction =>
      simpa [List.append_assoc] using TraceSteps.tail induction step

end TraceSteps

/-- A witness of an actually infinite execution. Unlike fuel exhaustion, this
contains a transition proof for every natural-numbered step. -/
structure InfiniteExecution {State Event : Type}
    (Step : State → List Event → State → Prop) (initial : State) where
  stateAt : Nat → State
  labelAt : Nat → List Event
  starts : stateAt 0 = initial
  advances : ∀ index, Step (stateAt index) (labelAt index) (stateAt (index + 1))

namespace InfiniteExecution

/-- An infinite execution is silent when every transition has an empty label. -/
def Silent {State Event : Type} {Step : State → List Event → State → Prop} {initial : State}
    (run : InfiniteExecution Step initial) : Prop :=
  ∀ index, run.labelAt index = []

/-- An infinite execution is reactive when observable transitions continue to
occur arbitrarily late. This excludes an infinite suffix of silent stuttering. -/
def Reactive {State Event : Type} {Step : State → List Event → State → Prop} {initial : State}
    (run : InfiniteExecution Step initial) : Prop :=
  ∀ lowerBound, ∃ index, lowerBound ≤ index ∧ run.labelAt index ≠ []

end InfiniteExecution

/-- Whole-machine behaviors. `Final` classifies genuine finite semantic
outcomes; analysis timeout and fuel exhaustion deliberately have no constructor. -/
inductive MachineBehavior {State Event Outcome : Type}
    (Step : State → List Event → State → Prop)
    (Final : State → Outcome → Prop) (initial : State) where
  | finite {state trace outcome}
      (execution : TraceSteps Step initial trace state)
      (final : Final state outcome) : MachineBehavior Step Final initial
  | diverges {state traceBefore}
      (execution : TraceSteps Step initial traceBefore state)
      (forever : InfiniteExecution Step state)
      (silent : forever.Silent) : MachineBehavior Step Final initial
  | reacts {state traceBefore}
      (execution : TraceSteps Step initial traceBefore state)
      (forever : InfiniteExecution Step state)
      (reactive : forever.Reactive) : MachineBehavior Step Final initial

/-- Project a low-level trace while allowing unobservable events to stutter. -/
def projectTrace {LowEvent HighEvent : Type}
    (project : LowEvent → Option HighEvent) (trace : List LowEvent) : List HighEvent :=
  trace.filterMap project

@[simp] theorem projectTrace_nil {LowEvent HighEvent : Type}
    (project : LowEvent → Option HighEvent) : projectTrace project [] = [] := rfl

@[simp] theorem projectTrace_append {LowEvent HighEvent : Type}
    (project : LowEvent → Option HighEvent) (left right : List LowEvent) :
    projectTrace project (left ++ right) = projectTrace project left ++ projectTrace project right := by
  simp [projectTrace]

/-- The trace-labelled transition obtained by hiding or translating low events. -/
def ProjectedStep {State LowEvent HighEvent : Type}
    (Step : State → List LowEvent → State → Prop)
    (project : LowEvent → Option HighEvent) : State → List HighEvent → State → Prop :=
  fun before trace after =>
    ∃ lowTrace, Step before lowTrace after ∧ trace = projectTrace project lowTrace

/-- Every finite low-level execution induces a finite projected execution. -/
theorem TraceSteps.project {State LowEvent HighEvent : Type}
    {Step : State → List LowEvent → State → Prop}
    (project : LowEvent → Option HighEvent)
    {before after : State} {trace : List LowEvent}
    (execution : TraceSteps Step before trace after) :
    TraceSteps (ProjectedStep Step project) before (projectTrace project trace) after := by
  induction execution with
  | refl => exact .refl _
  | tail _ step induction =>
      rw [projectTrace_append]
      exact .tail induction ⟨_, step, rfl⟩

/-- Semantic finite outcomes used by the processor and system layers. Waiting,
STOP, and lock are explicit; none is confused with an analysis timeout. -/
inductive MachineOutcome (ReturnWitness StuckReason : Type) where
  | returned (witness : ReturnWitness)
  | halted
  | stopped
  | locked (opcode : Byte)
  | stuck (reason : StuckReason)
  deriving Repr

end Sm83
