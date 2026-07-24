/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

import Sm83.Behavior

namespace Sm83

/-- One low-level transition is matched by zero or more high-level transitions.
If it is an observational and semantic stutter, the low-level rank must strictly
decrease. This is the CompCert/Kami-style local obligation. -/
def StepMatch {LowState HighState LowEvent HighEvent : Type}
    (HighStep : HighState → List HighEvent → HighState → Prop)
    (Related : LowState → HighState → Prop)
    (project : LowEvent → Option HighEvent)
    (rank : LowState → Nat)
    (lowBefore : LowState) (highBefore : HighState)
    (lowTrace : List LowEvent) (lowAfter : LowState) : Prop :=
  ∃ highAfter,
    TraceSteps HighStep highBefore (projectTrace project lowTrace) highAfter ∧
    Related lowAfter highAfter ∧
    (projectTrace project lowTrace = [] → highAfter = highBefore →
      rank lowAfter < rank lowBefore)

/-- A local stuttering simulation relates every concrete step from every
related state. -/
def LocalSimulation {LowState HighState LowEvent HighEvent : Type}
    (LowStep : LowState → List LowEvent → LowState → Prop)
    (HighStep : HighState → List HighEvent → HighState → Prop)
    (Related : LowState → HighState → Prop)
    (project : LowEvent → Option HighEvent)
    (rank : LowState → Nat) : Prop :=
  ∀ {lowBefore lowAfter highBefore lowTrace},
    Related lowBefore highBefore →
    LowStep lowBefore lowTrace lowAfter →
    StepMatch HighStep Related project rank
      lowBefore highBefore lowTrace lowAfter

/-- Local stuttering simulations compose over every finite execution. -/
theorem LocalSimulation.liftSteps
    {LowState HighState LowEvent HighEvent : Type}
    {LowStep : LowState → List LowEvent → LowState → Prop}
    {HighStep : HighState → List HighEvent → HighState → Prop}
    {Related : LowState → HighState → Prop}
    {project : LowEvent → Option HighEvent}
    {rank : LowState → Nat}
    (simulation : LocalSimulation LowStep HighStep Related project rank)
    {lowBefore lowAfter : LowState} {highBefore : HighState} {lowTrace : List LowEvent}
    (related : Related lowBefore highBefore)
    (execution : TraceSteps LowStep lowBefore lowTrace lowAfter) :
    ∃ highAfter,
      TraceSteps HighStep highBefore (projectTrace project lowTrace) highAfter ∧
      Related lowAfter highAfter := by
  induction execution generalizing highBefore with
  | refl => exact ⟨highBefore, .refl highBefore, related⟩
  | tail before step ih =>
      obtain ⟨highMiddle, highBefore, relatedMiddle⟩ := ih related
      obtain ⟨highAfter, highStep, relatedAfter, _⟩ := simulation relatedMiddle step
      exact ⟨highAfter,
        by simpa using TraceSteps.trans highBefore highStep,
        relatedAfter⟩

/-- Final-state compatibility needed to lift a finite concrete behavior. -/
def FinalRefinement {LowState HighState LowOutcome HighOutcome : Type}
    (Related : LowState → HighState → Prop)
    (LowFinal : LowState → LowOutcome → Prop)
    (HighFinal : HighState → HighOutcome → Prop)
    (outcomeRel : LowOutcome → HighOutcome → Prop) : Prop :=
  ∀ {low high lowOutcome}, Related low high → LowFinal low lowOutcome →
    ∃ highOutcome, HighFinal high highOutcome ∧ outcomeRel lowOutcome highOutcome

/-- Every finite implementation behavior maps to a finite specification
behavior once local simulation and final-state compatibility are supplied. -/
theorem LocalSimulation.liftFiniteBehavior
    {LowState HighState LowEvent HighEvent LowOutcome HighOutcome : Type}
    {LowStep : LowState → List LowEvent → LowState → Prop}
    {HighStep : HighState → List HighEvent → HighState → Prop}
    {Related : LowState → HighState → Prop}
    {project : LowEvent → Option HighEvent}
    {rank : LowState → Nat}
    {LowFinal : LowState → LowOutcome → Prop}
    {HighFinal : HighState → HighOutcome → Prop}
    {outcomeRel : LowOutcome → HighOutcome → Prop}
    (simulation : LocalSimulation LowStep HighStep Related project rank)
    (finals : FinalRefinement Related LowFinal HighFinal outcomeRel)
    {lowInitial : LowState} {highInitial : HighState}
    (initial : Related lowInitial highInitial)
    {lowState : LowState} {lowTrace : List LowEvent} {lowOutcome : LowOutcome}
    (execution : TraceSteps LowStep lowInitial lowTrace lowState)
    (final : LowFinal lowState lowOutcome) :
    ∃ highState highOutcome,
      TraceSteps HighStep highInitial (projectTrace project lowTrace) highState ∧
      HighFinal highState highOutcome ∧ outcomeRel lowOutcome highOutcome := by
  obtain ⟨highState, highExecution, related⟩ := simulation.liftSteps initial execution
  obtain ⟨highOutcome, highFinal, outcome⟩ := finals related final
  exact ⟨highState, highOutcome, highExecution, highFinal, outcome⟩

end Sm83
