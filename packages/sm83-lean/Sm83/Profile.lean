/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

import Sm83.Bus

namespace Sm83

structure StopContext where
  buttonSelected : Bool
  speedSwitchRequested : Bool
  interruptPending : Bool
  ime : Bool
  speedMode : Bool := false
  hardwareRevision : Nat := 0
  deriving Repr, DecidableEq, Inhabited

inductive StopDisposition where
  | continueRunning | haltLike | stopped | unstable
  deriving Repr, DecidableEq, Inhabited

structure StopEffect where
  bytesConsumed : Nat
  disposition : StopDisposition
  resetDivider : Bool
  toggleSpeed : Bool
  pauseMCycles : Option Nat := none
  deriving Repr, DecidableEq, Inhabited

inductive StopOutcome where
  | oneByteContinue
  | oneByteStop
  | twoByteStop
  | twoByteHalt
  | twoByteSpeedSwitchHalt
  | oneByteSpeedSwitchContinue
  | unstableSpeedSwitch
  deriving Repr, DecidableEq, Inhabited

/-- A reusable processor profile exposes permitted STOP outcomes as a relation. -/
structure StopProfile where
  permits : StopContext → Byte → StopOutcome → Prop
  decidablePermits : ∀ context byte outcome, Decidable (permits context byte outcome)

attribute [instance] StopProfile.decidablePermits

structure InvalidLockProfile where
  permits : Byte → CycleIntent → Prop
  decidablePermits : ∀ opcode intent, Decidable (permits opcode intent)

attribute [instance] InvalidLockProfile.decidablePermits

namespace InvalidLockProfile

/-- Digital semantics leave retained address/data/control levels relational after lock. -/
def retainedLevels : InvalidLockProfile where
  permits _ intent := intent.fetch = .none ∧ intent.commit = {} ∧
    intent.poll = .none ∧ intent.acknowledge = 0
  decidablePermits := by intros; infer_instance

end InvalidLockProfile

namespace StopProfile

/-- System-visible effects associated with an outcome; unstable effects stay unconstrained. -/
def effectPermits (outcome : StopOutcome) (effect : StopEffect) : Prop :=
  match outcome with
  | .oneByteContinue => effect = {
      bytesConsumed := 1
      disposition := .continueRunning
      resetDivider := false
      toggleSpeed := false }
  | .oneByteStop => effect = {
      bytesConsumed := 1
      disposition := .stopped
      resetDivider := true
      toggleSpeed := false }
  | .twoByteStop => effect = {
      bytesConsumed := 2
      disposition := .stopped
      resetDivider := true
      toggleSpeed := false }
  | .twoByteHalt => effect = {
      bytesConsumed := 2
      disposition := .haltLike
      resetDivider := false
      toggleSpeed := false }
  | .twoByteSpeedSwitchHalt => effect.bytesConsumed = 2 ∧ effect.disposition = .haltLike ∧
      effect.resetDivider = true ∧ effect.toggleSpeed = true
  | .oneByteSpeedSwitchContinue => effect = {
      bytesConsumed := 1
      disposition := .continueRunning
      resetDivider := true
      toggleSpeed := true }
  | .unstableSpeedSwitch => effect.disposition = .unstable

/-- Combined profile step keeps unresolved pauses and glitch effects relational. -/
def step (profile : StopProfile) (context : StopContext) (byte : Byte)
    (outcome : StopOutcome) (effect : StopEffect) : Prop :=
  profile.permits context byte outcome ∧ effectPermits outcome effect

/-- The reviewed seven-way decision relation; unstable silicon behavior remains relational. -/
def reviewed : StopProfile where
  permits context _ outcome :=
    if context.buttonSelected then
      if context.interruptPending then outcome = .oneByteContinue else outcome = .twoByteHalt
    else if context.speedSwitchRequested then
      if context.interruptPending then
        if context.ime then outcome = .unstableSpeedSwitch else outcome = .oneByteSpeedSwitchContinue
      else outcome = .twoByteSpeedSwitchHalt
    else if context.interruptPending then outcome = .oneByteStop
    else outcome = .twoByteStop
  decidablePermits := by intros; infer_instance

/-- Every outcome has at least one system-effect witness. -/
theorem effect_covers (outcome : StopOutcome) : ∃ effect, effectPermits outcome effect := by
  cases outcome
  · exact ⟨{
      bytesConsumed := 1
      disposition := .continueRunning
      resetDivider := false
      toggleSpeed := false }, rfl⟩
  · exact ⟨{
      bytesConsumed := 1
      disposition := .stopped
      resetDivider := true
      toggleSpeed := false }, rfl⟩
  · exact ⟨{
      bytesConsumed := 2
      disposition := .stopped
      resetDivider := true
      toggleSpeed := false }, rfl⟩
  · exact ⟨{
      bytesConsumed := 2
      disposition := .haltLike
      resetDivider := false
      toggleSpeed := false }, rfl⟩
  · exact ⟨{
      bytesConsumed := 2
      disposition := .haltLike
      resetDivider := true
      toggleSpeed := true }, by simp [effectPermits]⟩
  · exact ⟨{
      bytesConsumed := 1
      disposition := .continueRunning
      resetDivider := true
      toggleSpeed := true }, rfl⟩
  · exact ⟨{
      bytesConsumed := 0
      disposition := .unstable
      resetDivider := false
      toggleSpeed := false }, rfl⟩

/-- All seven constructors are reachable under some reviewed context. -/
theorem reviewed_covers (outcome : StopOutcome) :
    ∃ context byte, reviewed.permits context byte outcome := by
  cases outcome <;>
    first
    | exact ⟨{ buttonSelected := true, speedSwitchRequested := false, interruptPending := true, ime := false }, 0, rfl⟩
    | exact ⟨{ buttonSelected := false, speedSwitchRequested := false, interruptPending := true, ime := false }, 0, rfl⟩
    | exact ⟨{ buttonSelected := false, speedSwitchRequested := false, interruptPending := false, ime := false }, 0, rfl⟩
    | exact ⟨{ buttonSelected := true, speedSwitchRequested := false, interruptPending := false, ime := false }, 0, rfl⟩
    | exact ⟨{ buttonSelected := false, speedSwitchRequested := true, interruptPending := false, ime := false }, 0, rfl⟩
    | exact ⟨{ buttonSelected := false, speedSwitchRequested := true, interruptPending := true, ime := false }, 0, rfl⟩
    | exact ⟨{ buttonSelected := false, speedSwitchRequested := true, interruptPending := true, ime := true }, 0, rfl⟩

/-- Every reviewed outcome has a complete profile-step witness. -/
theorem reviewed_step_covers (outcome : StopOutcome) :
    ∃ context byte effect, step reviewed context byte outcome effect := by
  obtain ⟨context, byte, outcomeAllowed⟩ := reviewed_covers outcome
  obtain ⟨effect, effectAllowed⟩ := effect_covers outcome
  exact ⟨context, byte, effect, outcomeAllowed, effectAllowed⟩

end StopProfile
end Sm83
