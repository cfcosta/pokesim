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

/-- A block-level simulation in which each low transition corresponds to exactly
one high transition. Physical instruction blocks use this after finite M-cycle
stuttering has been discharged locally. -/
def DirectSimulation {LowState HighState LowEvent HighEvent : Type}
    (LowStep : LowState → List LowEvent → LowState → Prop)
    (HighStep : HighState → List HighEvent → HighState → Prop)
    (Related : LowState → HighState → Prop)
    (project : LowEvent → Option HighEvent) : Prop :=
  ∀ {lowBefore lowAfter highBefore lowTrace},
    Related lowBefore highBefore → LowStep lowBefore lowTrace lowAfter →
    ∃ highAfter, HighStep highBefore (projectTrace project lowTrace) highAfter ∧
      Related lowAfter highAfter

namespace DirectSimulation

/-- Direct simulations compose over arbitrary finite executions while retaining
exact projected traces. -/
theorem liftSteps
    {LowState HighState LowEvent HighEvent : Type}
    {LowStep : LowState → List LowEvent → LowState → Prop}
    {HighStep : HighState → List HighEvent → HighState → Prop}
    {Related : LowState → HighState → Prop}
    {project : LowEvent → Option HighEvent}
    (simulation : DirectSimulation LowStep HighStep Related project)
    {lowBefore lowAfter : LowState} {highBefore : HighState} {lowTrace : List LowEvent}
    (related : Related lowBefore highBefore)
    (execution : TraceSteps LowStep lowBefore lowTrace lowAfter) :
    ∃ highAfter,
      TraceSteps HighStep highBefore (projectTrace project lowTrace) highAfter ∧
      Related lowAfter highAfter := by
  induction execution generalizing highBefore with
  | refl => exact ⟨highBefore, .refl highBefore, related⟩
  | tail before step induction =>
      obtain ⟨highMiddle, highBefore, relatedMiddle⟩ := induction related
      obtain ⟨highAfter, highStep, relatedAfter⟩ := simulation relatedMiddle step
      exact ⟨highAfter,
        by simpa using TraceSteps.trans highBefore (TraceSteps.one highStep),
        relatedAfter⟩

private noncomputable def liftPoint
    {LowState HighState LowEvent HighEvent : Type}
    {LowStep : LowState → List LowEvent → LowState → Prop}
    {HighStep : HighState → List HighEvent → HighState → Prop}
    {Related : LowState → HighState → Prop}
    {project : LowEvent → Option HighEvent}
    (simulation : DirectSimulation LowStep HighStep Related project)
    {lowInitial : LowState} (run : InfiniteExecution LowStep lowInitial)
    {highInitial : HighState} (initial : Related lowInitial highInitial) :
    (index : Nat) → { high // Related (run.stateAt index) high }
  | 0 => ⟨highInitial, by simpa [run.starts] using initial⟩
  | index + 1 =>
      let previous := liftPoint simulation run initial index
      let matched := simulation previous.property (run.advances index)
      ⟨Classical.choose matched, (Classical.choose_spec matched).2⟩

/-- Pointwise direct simulation of an actually infinite low execution. -/
noncomputable def liftInfinite
    {LowState HighState LowEvent HighEvent : Type}
    {LowStep : LowState → List LowEvent → LowState → Prop}
    {HighStep : HighState → List HighEvent → HighState → Prop}
    {Related : LowState → HighState → Prop}
    {project : LowEvent → Option HighEvent}
    (simulation : DirectSimulation LowStep HighStep Related project)
    {lowInitial : LowState} (run : InfiniteExecution LowStep lowInitial)
    {highInitial : HighState} (initial : Related lowInitial highInitial) :
    InfiniteExecution HighStep highInitial where
  stateAt index := (liftPoint simulation run initial index).1
  labelAt index := projectTrace project (run.labelAt index)
  starts := rfl
  advances index := by
    let previous := liftPoint simulation run initial index
    let matched := simulation previous.property (run.advances index)
    exact (Classical.choose_spec matched).1

@[simp] theorem liftInfinite_labelAt
    {LowState HighState LowEvent HighEvent : Type}
    {LowStep : LowState → List LowEvent → LowState → Prop}
    {HighStep : HighState → List HighEvent → HighState → Prop}
    {Related : LowState → HighState → Prop}
    {project : LowEvent → Option HighEvent}
    (simulation : DirectSimulation LowStep HighStep Related project)
    {lowInitial : LowState} (run : InfiniteExecution LowStep lowInitial)
    {highInitial : HighState} (initial : Related lowInitial highInitial) (index : Nat) :
    (liftInfinite simulation run initial).labelAt index =
      projectTrace project (run.labelAt index) := rfl

end DirectSimulation

/-- Pointwise alignment of low and high infinite observations. -/
def InfiniteRefines {LowState HighState LowEvent HighEvent : Type}
    {LowStep : LowState → List LowEvent → LowState → Prop}
    {HighStep : HighState → List HighEvent → HighState → Prop}
    {lowInitial : LowState} {highInitial : HighState}
    (project : LowEvent → Option HighEvent)
    (low : InfiniteExecution LowStep lowInitial)
    (high : InfiniteExecution HighStep highInitial) : Prop :=
  ∀ index, high.labelAt index = projectTrace project (low.labelAt index)

/-- Explicit whole-behavior refinement. Reactive low behaviors require a
reactive projected high execution; adapters must state that environmental
assumption rather than silently dropping all future observations. -/
inductive BehaviorRefines
    {LowState HighState LowEvent HighEvent LowOutcome HighOutcome : Type}
    {LowStep : LowState → List LowEvent → LowState → Prop}
    {HighStep : HighState → List HighEvent → HighState → Prop}
    {LowFinal : LowState → LowOutcome → Prop}
    {HighFinal : HighState → HighOutcome → Prop}
    {lowInitial : LowState} {highInitial : HighState}
    (project : LowEvent → Option HighEvent)
    (outcomeRel : LowOutcome → HighOutcome → Prop) :
    MachineBehavior LowStep LowFinal lowInitial →
      MachineBehavior HighStep HighFinal highInitial → Prop where
  | finite {lowState highState lowTrace lowOutcome highOutcome}
      (lowExecution : TraceSteps LowStep lowInitial lowTrace lowState)
      (lowFinal : LowFinal lowState lowOutcome)
      (highExecution : TraceSteps HighStep highInitial
        (projectTrace project lowTrace) highState)
      (highFinal : HighFinal highState highOutcome)
      (outcome : outcomeRel lowOutcome highOutcome) :
      BehaviorRefines project outcomeRel
        (.finite lowExecution lowFinal) (.finite highExecution highFinal)
  | diverges {lowState highState lowTrace}
      (lowExecution : TraceSteps LowStep lowInitial lowTrace lowState)
      (highExecution : TraceSteps HighStep highInitial
        (projectTrace project lowTrace) highState)
      (lowForever : InfiniteExecution LowStep lowState)
      (highForever : InfiniteExecution HighStep highState)
      (lowSilent : lowForever.Silent)
      (highSilent : highForever.Silent)
      (infinite : InfiniteRefines project lowForever highForever) :
      BehaviorRefines project outcomeRel
        (.diverges lowExecution lowForever lowSilent)
        (.diverges highExecution highForever highSilent)
  | reacts {lowState highState lowTrace}
      (lowExecution : TraceSteps LowStep lowInitial lowTrace lowState)
      (highExecution : TraceSteps HighStep highInitial
        (projectTrace project lowTrace) highState)
      (lowForever : InfiniteExecution LowStep lowState)
      (highForever : InfiniteExecution HighStep highState)
      (lowReactive : lowForever.Reactive)
      (highReactive : highForever.Reactive)
      (infinite : InfiniteRefines project lowForever highForever) :
      BehaviorRefines project outcomeRel
        (.reacts lowExecution lowForever lowReactive)
        (.reacts highExecution highForever highReactive)

/-- The explicit adapter assumption required when a low reactive execution must
remain reactive after observation projection. -/
def PreservesReaction
    {LowState HighState LowEvent HighEvent : Type}
    (LowStep : LowState → List LowEvent → LowState → Prop)
    (HighStep : HighState → List HighEvent → HighState → Prop)
    (Related : LowState → HighState → Prop)
    (project : LowEvent → Option HighEvent)
    (simulation : DirectSimulation LowStep HighStep Related project) : Prop :=
  ∀ {lowInitial highInitial} (initial : Related lowInitial highInitial)
      (run : InfiniteExecution LowStep lowInitial),
    run.Reactive → (DirectSimulation.liftInfinite simulation run initial).Reactive

/-- Direct block simulations lift to finite, silent-divergent, and reactive
whole behaviors. Reaction preservation remains an explicit adapter obligation. -/
theorem DirectSimulation.liftBehavior
    {LowState HighState LowEvent HighEvent LowOutcome HighOutcome : Type}
    {LowStep : LowState → List LowEvent → LowState → Prop}
    {HighStep : HighState → List HighEvent → HighState → Prop}
    {Related : LowState → HighState → Prop}
    {LowFinal : LowState → LowOutcome → Prop}
    {HighFinal : HighState → HighOutcome → Prop}
    {outcomeRel : LowOutcome → HighOutcome → Prop}
    (project : LowEvent → Option HighEvent)
    (simulation : DirectSimulation LowStep HighStep Related project)
    (finals : FinalRefinement Related LowFinal HighFinal outcomeRel)
    (reactions : PreservesReaction LowStep HighStep Related project simulation)
    {lowInitial : LowState} {highInitial : HighState}
    (initial : Related lowInitial highInitial)
    (lowBehavior : MachineBehavior LowStep LowFinal lowInitial) :
    ∃ highBehavior : MachineBehavior HighStep HighFinal highInitial,
      BehaviorRefines project outcomeRel lowBehavior highBehavior := by
  cases lowBehavior with
  | finite lowExecution lowFinal =>
      obtain ⟨highState, highExecution, related⟩ := simulation.liftSteps initial lowExecution
      obtain ⟨highOutcome, highFinal, outcome⟩ := finals related lowFinal
      let highBehavior : MachineBehavior HighStep HighFinal highInitial :=
        .finite highExecution highFinal
      exact ⟨highBehavior, .finite lowExecution lowFinal highExecution highFinal outcome⟩
  | diverges lowExecution lowForever lowSilent =>
      obtain ⟨highState, highExecution, related⟩ := simulation.liftSteps initial lowExecution
      let highForever := DirectSimulation.liftInfinite simulation lowForever related
      have highSilent : highForever.Silent := by
        intro index
        simp [highForever, lowSilent index]
      let highBehavior : MachineBehavior HighStep HighFinal highInitial :=
        .diverges highExecution highForever highSilent
      exact ⟨highBehavior, .diverges lowExecution highExecution lowForever highForever
        lowSilent highSilent (by intro index; rfl)⟩
  | reacts lowExecution lowForever lowReactive =>
      obtain ⟨highState, highExecution, related⟩ := simulation.liftSteps initial lowExecution
      let highForever := DirectSimulation.liftInfinite simulation lowForever related
      have highReactive : highForever.Reactive := reactions related lowForever lowReactive
      let highBehavior : MachineBehavior HighStep HighFinal highInitial :=
        .reacts highExecution highForever highReactive
      exact ⟨highBehavior, .reacts lowExecution highExecution lowForever highForever
        lowReactive highReactive (by intro index; rfl)⟩

end Sm83
