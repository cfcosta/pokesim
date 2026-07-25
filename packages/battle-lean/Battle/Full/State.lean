/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.State
import Battle.RL.LegalTeam

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
          let stored := { stored with status := live.status }
          let stored := { stored with moves := if transformed then stored.moves else live.moves }
          { stored with pp := if transformed then stored.pp else live.pp } } }

/-- Switch legality after outgoing synchronization. -/
def SideState.canSwitchTo (side : SideState) (target : Nat) : Bool :=
  target < side.party.mons.size && target != side.activeIndex &&
    !(side.party.mons.getD target side.active.active).fainted

inductive SwitchResult where
  | switched (side : SideState)
  | invalid (side : SideState)
  deriving Repr, DecidableEq

/-- Voluntary or forced switch. Loading uses `SideState.fresh`, so all six stages
and every switch-cleared volatile field reset together. -/
def SideState.switchTo (side : SideState) (target : Nat) : SwitchResult :=
  let synced := side.syncOutgoing
  if synced.canSwitchTo target then
    let incoming := synced.party.mons.getD target synced.active.active
    .switched { synced with activeIndex := target, active := Battle.SideState.fresh incoming }
  else .invalid synced

/-- Living reserve indices, excluding the current active slot. -/
def SideState.legalSwitches (side : SideState) : Array (Fin Wram.partyLength) :=
  (Array.range Wram.partyLength).filterMap fun target =>
    if h : target < Wram.partyLength then
      if side.canSwitchTo target then some ⟨target, h⟩ else none
    else none

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
        active := Battle.SideState.fresh
          (side.syncOutgoing.party.mons.getD target side.syncOutgoing.active.active) } := by
  simp [SideState.switchTo, legal]

/-- Synchronization always copies HP/status. Move/PP copies are suppressed
while transformed, retaining the original party row. -/
theorem syncOutgoing_reads_active (side : SideState)
    (oldInBounds : side.activeIndex < side.party.mons.size) :
    let before := side.party.mons.getD side.activeIndex side.active.active
    let stored := side.syncOutgoing.party.mons.getD side.activeIndex side.active.active
    let transformed := bitSet side.active.volatile.status3 Wram.BattleStatus3.transformed
    stored.hp = side.active.active.hp ∧ stored.status = side.active.active.status ∧
      stored.moves = (if transformed then before.moves else side.active.active.moves) ∧
      stored.pp = (if transformed then before.pp else side.active.active.pp) := by
  simp only [SideState.syncOutgoing, Array.getD, Array.size_modify, oldInBounds,
    ↓reduceDIte]
  simp [Array.getElem_modify_self]

end Battle.Full
