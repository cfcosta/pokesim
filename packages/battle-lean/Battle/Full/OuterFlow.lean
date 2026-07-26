/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0.
-/
import Battle.Full.State
import Battle.Outcome

/-!
# Battle-driver exit and caller composition

This is the typed high-level composition boundary. It separates the terminal
checkpoint, `EndOfBattle` cleanup, `_InitBattleCommon` return, and later caller
scripts. It is not a claim that the ROM instructions implementing those phases
have yet been composed continuously.
-/

namespace Battle.Full.OuterFlow

open Battle

structure CallerFrame where
  letterDelayFlags : UInt8
  mapPaletteOffset : UInt8
  tileAnimations : UInt8
  romBank : UInt8
  stackPointer : UInt16
  deriving Repr, DecidableEq, BEq

structure ExitState where
  phase : Outcome.EpisodePhase
  encounterCooldown : Bool
  destinationWarp : UInt8
  alwaysOnBike : Bool
  letterDelayFlags : UInt8
  mapPaletteOffset : UInt8
  tileAnimations : UInt8
  romBank : UInt8
  stackPointer : UInt16
  carry : Bool
  deriving Repr, DecidableEq

/-- Named pre-cleanup checkpoint carrying terminal provenance. -/
def terminalCheckpoint (terminal : Outcome.BattleTerminal)
    (frame : CallerFrame) : ExitState :=
  { phase := .ending terminal
    encounterCooldown := false
    destinationWarp := 0
    alwaysOnBike := true
    letterDelayFlags := frame.letterDelayFlags
    mapPaletteOffset := frame.mapPaletteOffset
    tileAnimations := frame.tileAnimations
    romBank := frame.romBank
    stackPointer := frame.stackPointer
    carry := false }

/-- `EndOfBattle` handoff sets encounter cooldown and destination `$FF`; loss
clears the always-on-bike state. Rich terminal provenance remains in `ending`. -/
def cleanupCheckpoint (state : ExitState) : ExitState :=
  match state.phase with
  | .ending terminal =>
      let state := { state with encounterCooldown := true }
      let state := { state with destinationWarp := 0xFF }
      { state with alwaysOnBike := terminal.rawResult == 0 }
  | _ => state

/-- `_InitBattleCommon` restores caller-owned fields/frame and sets carry before
creating the returned episode result. -/
def outerReturn (state : ExitState) (saved : CallerFrame) : ExitState :=
  match state.phase with
  | .ending terminal =>
      let state := { state with phase := .returned ⟨terminal⟩ }
      let state := { state with letterDelayFlags := saved.letterDelayFlags }
      let state := { state with mapPaletteOffset := saved.mapPaletteOffset }
      let state := { state with tileAnimations := saved.tileAnimations }
      let state := { state with romBank := saved.romBank }
      let state := { state with stackPointer := saved.stackPointer }
      { state with carry := true }
  | _ => state

@[simp] theorem terminal_cleanup_return_are_separate (terminal : Outcome.BattleTerminal)
    (frame : CallerFrame) :
    let terminalState := terminalCheckpoint terminal frame
    let cleaned := cleanupCheckpoint terminalState
    let returned := outerReturn cleaned frame
    terminalState.phase = .ending terminal ∧
      cleaned.phase = .ending terminal ∧ cleaned.encounterCooldown = true ∧
      cleaned.destinationWarp = 0xFF ∧
      returned.phase = .returned ⟨terminal⟩ ∧ returned.carry = true := by
  simp [terminalCheckpoint, cleanupCheckpoint, outerReturn]

@[simp] theorem outer_return_restores_frame (terminal : Outcome.BattleTerminal)
    (current saved : CallerFrame) :
    let returned := outerReturn (cleanupCheckpoint (terminalCheckpoint terminal current)) saved
    returned.letterDelayFlags = saved.letterDelayFlags ∧
      returned.mapPaletteOffset = saved.mapPaletteOffset ∧
      returned.tileAnimations = saved.tileAnimations ∧
      returned.romBank = saved.romBank ∧ returned.stackPointer = saved.stackPointer ∧
      returned.carry = true := by
  simp [terminalCheckpoint, cleanupCheckpoint, outerReturn]

inductive CallerContinuation where
  | blackoutMoneyAndHeal
  | trainerMapFlags
  | cableHealParty
  | oldManScriptCleanup
  deriving Repr, DecidableEq, BEq

/-- These transitions occur only after the battle driver has returned. -/
def postReturnOnly (_continuation : CallerContinuation) : Bool := true

@[simp] theorem caller_continuations_are_post_return :
    [CallerContinuation.blackoutMoneyAndHeal, .trainerMapFlags, .cableHealParty,
      .oldManScriptCleanup].all postReturnOnly = true := by
  native_decide

/-- Cable Club's unconditional `HealParty` is a caller transition: it restores
persistent HP/status only after a returned battle result exists. -/
def healPartyAfterCableReturn (phase : Outcome.EpisodePhase)
    (party : Full.Party) : Option Full.Party :=
  match phase with
  | .returned _ => some { mons := party.mons.map fun mon =>
      { mon with hp := mon.maxHp, status := 0 } }
  | _ => none

@[simp] theorem cable_heal_requires_return (terminal : Outcome.BattleTerminal)
    (party : Full.Party) :
    healPartyAfterCableReturn (.ending terminal) party = none ∧
      healPartyAfterCableReturn (.returned ⟨terminal⟩) party = some
        { mons := party.mons.map fun mon => { mon with hp := mon.maxHp, status := 0 } } := by
  exact ⟨rfl, rfl⟩

/-- Blackout money halving/healing is not folded into battle cleanup. -/
def blackoutTransitionIncludedInBattle : Bool := false

@[simp] theorem blackout_is_later_overworld_transition :
    blackoutTransitionIncludedInBattle = false := rfl

end Battle.Full.OuterFlow
