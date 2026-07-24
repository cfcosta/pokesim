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

end StopProfile
end Sm83
