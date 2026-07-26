/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.State
import Battle.RL.LegalTeam
import Battle.DamageStats

/-!
# Full party battle state and switching

The active battle struct and persistent party row are represented separately,
matching WRAM. Switching first synchronizes the outgoing active HP/status/moves/
PP into its party row, then loads the selected row with neutral stages and
cleared volatile state.
-/

namespace Battle.Full

structure Party where
  mons : Array MonState
  deriving Repr, DecidableEq, BEq

/-- Canonical party shape. Glitch/raw profiles may deliberately violate it. -/
def Party.wf (party : Party) : Bool :=
  party.mons.size ≥ 1 && party.mons.size ≤ Wram.partyLength && party.mons.all MonState.wf

structure SideState where
  party : Party
  activeIndex : Nat
  active : Battle.SideState
  deriving Repr, DecidableEq, BEq

/-- Active index exists and active battle struct corresponds to that party row
at the last synchronization boundary. -/
def SideState.wf (side : SideState) : Bool :=
  side.party.wf && side.activeIndex < side.party.mons.size && side.active.active.wf

/-- Install only fields copied by the cartridge's outgoing-active routine.
Transformed species/types/DVs and mutable combat stats never leak into party
storage. -/
def SideState.syncOutgoing (side : SideState) : SideState :=
  let live := side.active.active
  let transformed := bitSet side.active.volatile.status3 Wram.BattleStatus3.transformed
  { side with party :=
      { mons := side.party.mons.modify side.activeIndex fun stored =>
          let stored := { stored with hp := live.hp }
          -- The contiguous HP/party-position/status copy aliases party position
          -- onto persistent `MON_BOX_LEVEL`.
          let stored := { stored with boxLevel := side.activeIndex.toUInt8 }
          let stored := { stored with status := live.status }
          let stored := { stored with moves := if transformed then stored.moves else live.moves }
          { stored with pp := if transformed then stored.pp else live.pp } } }

/-- Switch legality after outgoing synchronization. -/
def SideState.canSwitchTo (side : SideState) (target : Nat) : Bool :=
  target < side.party.mons.size && target != side.activeIndex &&
    !(side.party.mons.getD target side.active.active).fainted

theorem SideState.canSwitchTo_sound (side : SideState) (target : Nat)
    (legal : side.canSwitchTo target = true) :
    target < side.party.mons.size ∧ target ≠ side.activeIndex ∧
      ((side.party.mons[target]?).getD side.active.active).fainted = false := by
  simp [SideState.canSwitchTo] at legal
  exact ⟨legal.1.1, legal.1.2, legal.2⟩

inductive SwitchResult where
  | switched (side : SideState)
  | invalid (side : SideState)
  deriving Repr, DecidableEq

def Volatile.sendOutReset (prior : Volatile) : Volatile :=
  let prior := { prior with status1 := 0 }
  let prior := { prior with status2 := 0 }
  let prior := { prior with status3 := 0 }
  let prior := { prior with disabledMove := 0 }
  let prior := { prior with disabledMoveNumber := 0 }
  { prior with minimized := false }

def SideState.loadIncoming (prior : Battle.SideState) (incoming : MonState) : Battle.SideState :=
  { active := incoming.withBattleStatusPenalties
    unmodified := CombatStats.ofMon incoming
    stages := StatStages.neutral
    volatile := Volatile.sendOutReset prior.volatile
    originalSpecies := incoming.species
    partyPosition := prior.partyPosition
    actualCatchRate := incoming.catchRate }

def badgeBoostIf (badges : UInt8) (bit : Nat) (stat : UInt16) : UInt16 :=
  if bitSet badges bit then DamageStats.badgeBoost stat else stat

def applyPlayerSendOutBadges (mode : BattleMode) (badges : UInt8)
    (side : Battle.SideState) : Battle.SideState :=
  match mode with
  | .link => side
  | .wild | .trainer | .oldMan | .safari =>
      let mon := side.active
      let mon := { mon with attack := badgeBoostIf badges 0 mon.attack }
      let mon := { mon with defense := badgeBoostIf badges 2 mon.defense }
      let mon := { mon with speed := badgeBoostIf badges 4 mon.speed }
      let mon := { mon with special := badgeBoostIf badges 6 mon.special }
      { side with active := mon }

@[simp] theorem wild_send_out_applies_badge_after_status (prior : Battle.SideState)
    (incoming : MonState) (badges : UInt8) :
    (applyPlayerSendOutBadges .wild badges
      (SideState.loadIncoming prior incoming)).active.attack =
        badgeBoostIf badges 0 incoming.withBattleStatusPenalties.attack ∧
    (applyPlayerSendOutBadges .wild badges
      (SideState.loadIncoming prior incoming)).active.speed =
        badgeBoostIf badges 4 incoming.withBattleStatusPenalties.speed := by
  exact ⟨rfl, rfl⟩

@[simp] theorem link_send_out_skips_badges (badges : UInt8) (side : Battle.SideState) :
    applyPlayerSendOutBadges .link badges side = side := by
  rfl

@[simp] theorem send_out_reset_preserves_stale_counters (prior : Volatile) :
    let reset := Volatile.sendOutReset prior
    reset.status1 = 0 ∧ reset.status2 = 0 ∧ reset.status3 = 0 ∧
    reset.disabledMove = 0 ∧ reset.disabledMoveNumber = 0 ∧ reset.minimized = false ∧
    reset.numAttacksLeft = prior.numAttacksLeft ∧
    reset.confusedCounter = prior.confusedCounter ∧
    reset.toxicCounter = prior.toxicCounter ∧
    reset.substituteHp = prior.substituteHp ∧
    reset.bideAccumulated = prior.bideAccumulated := by
  simp [Volatile.sendOutReset]

/-- Voluntary or forced switch. Incoming segmented fields are loaded from the
party row; stages reset while inactive volatile counters remain stale. -/
def SideState.switchTo (side : SideState) (target : Nat) : SwitchResult :=
  let synced := side.syncOutgoing
  if synced.canSwitchTo target then
    let incoming := synced.party.mons.getD target synced.active.active
    let loaded := loadIncoming synced.active incoming
    let loaded := { loaded with partyPosition := target.toUInt8 }
    .switched { synced with activeIndex := target, active := loaded }
  else .invalid synced

/-- Living reserve indices, excluding the current active slot. -/
def SideState.legalSwitches (side : SideState) : Array (Fin Wram.partyLength) :=
  (Array.range Wram.partyLength).filterMap fun target =>
    if h : target < Wram.partyLength then
      if side.canSwitchTo target then some ⟨target, h⟩ else none
    else none

/-- Deterministic cartridge-order scan for the first switchable slot. `fuel` is
only the bounded full-party wrapper here; malformed raw-memory scans are modeled
separately by their one-step relation. -/
def SideState.firstSwitchFrom (side : SideState) (start : Nat) : Nat → Option Nat
  | 0 => none
  | fuel + 1 =>
      if side.canSwitchTo start then some start
      else firstSwitchFrom side (start + 1) fuel

def SideState.firstLegalSwitch (side : SideState) : Option Nat :=
  side.firstSwitchFrom 0 Wram.partyLength

theorem SideState.firstSwitchFrom_sound (side : SideState) (start fuel target : Nat)
    (found : side.firstSwitchFrom start fuel = some target) :
    side.canSwitchTo target = true := by
  induction fuel generalizing start with
  | zero => simp [SideState.firstSwitchFrom] at found
  | succ fuel induction =>
      simp only [SideState.firstSwitchFrom] at found
      split at found
      · cases found
        assumption
      · exact induction (start + 1) found

theorem SideState.firstSwitchFrom_bounds (side : SideState) (start fuel target : Nat)
    (found : side.firstSwitchFrom start fuel = some target) :
    start ≤ target ∧ target < start + fuel := by
  induction fuel generalizing start with
  | zero => simp [SideState.firstSwitchFrom] at found
  | succ fuel induction =>
      simp only [SideState.firstSwitchFrom] at found
      split at found
      · cases found
        omega
      · have bounds := induction (start + 1) found
        omega

theorem SideState.firstSwitchFrom_lowest (side : SideState) (start fuel target : Nat)
    (found : side.firstSwitchFrom start fuel = some target) :
    ∀ candidate, start ≤ candidate → candidate < target →
      side.canSwitchTo candidate = false := by
  induction fuel generalizing start with
  | zero => simp [SideState.firstSwitchFrom] at found
  | succ fuel induction =>
      simp only [SideState.firstSwitchFrom] at found
      split at found
      · cases found
        intro candidate lower upper
        omega
      · rename_i rejected
        intro candidate lower upper
        by_cases atStart : candidate = start
        · subst candidate
          cases value : side.canSwitchTo start <;> simp_all
        · exact induction (start + 1) found candidate (by omega) upper

theorem SideState.firstLegalSwitch_exact (side : SideState) (target : Nat)
    (found : side.firstLegalSwitch = some target) :
    side.canSwitchTo target = true ∧ target < Wram.partyLength ∧
      ∀ candidate, candidate < target → side.canSwitchTo candidate = false := by
  have raw : side.firstSwitchFrom 0 Wram.partyLength = some target := by
    simpa [SideState.firstLegalSwitch] using found
  exact ⟨SideState.firstSwitchFrom_sound side 0 Wram.partyLength target raw,
    (SideState.firstSwitchFrom_bounds side 0 Wram.partyLength target raw).2,
    fun candidate lower => SideState.firstSwitchFrom_lowest side 0 Wram.partyLength target raw
      candidate (by omega) lower⟩

/-- One raw scan step. Repeated `.next` steps may diverge; no fuel-exhaustion
case is introduced as cartridge behavior. -/
inductive ReplacementScanStep where
  | found (index : Nat)
  | next (index : Nat)
  deriving Repr, DecidableEq

def replacementScanStep (living : Nat → Bool) (index : Nat) : ReplacementScanStep :=
  if living index then .found index else .next (index + 1)

@[simp] theorem replacement_scan_deterministic (living : Nat → Bool) (index : Nat) :
    replacementScanStep living index =
      if living index then .found index else .next (index + 1) := rfl

/-- All persistent members plus the active row are fainted after synchronization. -/
def SideState.partyExhausted (side : SideState) : Bool :=
  side.syncOutgoing.party.mons.all MonState.fainted

structure State where
  player : SideState
  enemy : SideState
  rng : Rng.LinkRng
  turn : Nat
  mode : BattleMode
  phase : Outcome.EpisodePhase
  deriving Repr, DecidableEq

/-- Build a side from a nonempty party. Caller supplies the fallback only for
raw malformed empty arrays; canonical reset proves nonemptiness separately. -/
def SideState.fromParty (party : Party) (fallback : MonState) : SideState :=
  let first := party.mons.getD 0 fallback
  { party, activeIndex := 0, active := Battle.SideState.fresh first }

def State.side : State → Side → SideState
  | state, .player => state.player
  | state, .enemy => state.enemy

def State.setSide : State → Side → SideState → State
  | state, .player, side => { state with player := side }
  | state, .enemy, side => { state with enemy := side }

/-- Apply a switch to one side without touching battle RNG. -/
def State.switchTo (state : State) (who : Side) (target : Nat) : Option State :=
  match (state.side who).switchTo target with
  | .invalid _ => none
  | .switched side => some (state.setSide who side)

/-! ## Switching theorems -/

@[simp] theorem syncOutgoing_active (side : SideState) :
    side.syncOutgoing.active = side.active := rfl

@[simp] theorem syncOutgoing_index (side : SideState) :
    side.syncOutgoing.activeIndex = side.activeIndex := rfl

/-- Every successful switch has exactly the requested index, neutral stages, and
cleared volatile state. -/
theorem switch_success_shape (side : SideState) (target : Nat)
    (legal : side.syncOutgoing.canSwitchTo target = true) :
    side.switchTo target = .switched
      { side.syncOutgoing with
        activeIndex := target
        active := { SideState.loadIncoming side.syncOutgoing.active
          (side.syncOutgoing.party.mons.getD target side.syncOutgoing.active.active) with
            partyPosition := target.toUInt8 } } := by
  simp [SideState.switchTo, legal]

/-- Synchronization always copies HP/status. Move/PP copies are suppressed
while transformed, retaining the original party row. -/
theorem syncOutgoing_reads_active (side : SideState)
    (oldInBounds : side.activeIndex < side.party.mons.size) :
    let before := side.party.mons.getD side.activeIndex side.active.active
    let stored := side.syncOutgoing.party.mons.getD side.activeIndex side.active.active
    let transformed := bitSet side.active.volatile.status3 Wram.BattleStatus3.transformed
    stored.hp = side.active.active.hp ∧
      stored.boxLevel = side.activeIndex.toUInt8 ∧
      stored.status = side.active.active.status ∧
      stored.moves = (if transformed then before.moves else side.active.active.moves) ∧
      stored.pp = (if transformed then before.pp else side.active.active.pp) := by
  simp only [SideState.syncOutgoing, Array.getD, Array.size_modify, oldInBounds,
    ↓reduceDIte]
  simp [Array.getElem_modify_self]

end Battle.Full
