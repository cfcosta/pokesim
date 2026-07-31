/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Full.Action
import Battle.Data.Moves

/-!
# Mechanics-visible menu selection scratch

Models the selected-move/loaded-record bytes separately from action commitment.
Browse, cancel, and reorder transitions therefore remain observable without
consuming a battle turn.
-/

namespace Battle.Full.Selection

structure MoveScratch where
  /-- `wPlayerSelectedMove`, consulted by priority and Counter. -/
  selectedMove : MoveId := 0
  /-- `wPlayerMoveNum`, adjacent loaded-record identity cleared on send-out. -/
  loadedMove : MoveId := 0
  highlightedSlot : UInt8 := 0
  effect : UInt8 := 0
  power : UInt8 := 0
  type : UInt8 := 0
  accuracy : UInt8 := 0
  pp : UInt8 := 0
  deriving Repr, DecidableEq, BEq, ReflBEq, LawfulBEq

structure State where
  side : Full.SideState
  bag : Items.Bag
  scratch : MoveScratch := {}
  runAttempts : UInt8 := 0
  deriving Repr, DecidableEq

inductive Event where
  | fightOpened
  | highlighted (slot : Fin 4) (loaded : Bool)
  | fightCancelled
  | movesSwapped (first second : Fin 4)
  | bagSwapped (first second : Nat)
  deriving Repr, DecidableEq

private def disabledSlot (side : Full.SideState) : Option Nat :=
  let encoded := side.active.volatile.disabledMove >>> 4
  if encoded == 0 then none else some (encoded.toNat - 1)

/-- Opening Fight resets run attempts before any move is committed. -/
def openFight (state : State) : State × Event :=
  ({ state with runAttempts := 0 }, .fightOpened)

/-- Highlight updates the selected move and loaded record unless that slot is
currently disabled. Disabled browse still updates the highlighted index while
retaining stale selected/power/type/accuracy/PP bytes. -/
def highlight (state : State) (slot : Fin 4) : State × Event :=
  let scratch := { state.scratch with highlightedSlot := slot.val.toUInt8 }
  if disabledSlot state.side == some slot.val then
    ({ state with scratch }, .highlighted slot false)
  else
    let move := state.side.active.active.moves.getD slot.val 0
    let data := Data.moveData move
    let scratch := { scratch with selectedMove := move }
    let scratch := { scratch with loadedMove := move }
    let scratch := { scratch with effect := data.effect }
    let scratch := { scratch with power := data.power }
    let scratch := { scratch with type := data.type }
    let scratch := { scratch with accuracy := data.accuracy }
    let scratch := { scratch with pp := data.pp }
    ({ state with scratch }, .highlighted slot true)

/-- Cancel has no scratch rollback. -/
def cancelFight (state : State) : State × Event := (state, .fightCancelled)

private def swapArray (array : Array α) (first second : Nat) : Array α :=
  let a := array[first]?
  let b := array[second]?
  match a, b with
  | some a, some b => (array.modify first (fun _ => b)).modify second (fun _ => a)
  | _, _ => array

private def remapDisabled (disabled : UInt8) (first second : Fin 4) : UInt8 :=
  let slot := disabled >>> 4
  let turns := disabled &&& 0x0f
  if slot == first.val.toUInt8 + 1 then ((second.val + 1) * 16).toUInt8 + turns
  else if slot == second.val.toUInt8 + 1 then ((first.val + 1) * 16).toUInt8 + turns
  else disabled

/-- SELECT swaps active move IDs and packed PP together and remaps the disabled
slot encoding. Party synchronization is performed by the caller so transformed
active rows can deliberately remain distinct. -/
def swapMoves (state : State) (first second : Fin 4) : State × Event :=
  let active := state.side.active
  let mon := { active.active with
    moves := swapArray active.active.moves first.val second.val
    pp := swapArray active.active.pp first.val second.val }
  let volatile := { active.volatile with
    disabledMove := remapDisabled active.volatile.disabledMove first second }
  ({ state with side := { state.side with active := { active with active := mon, volatile } } },
    .movesSwapped first second)

theorem swapMoves_exact (state : State) (first second : Fin 4) :
    let after := (swapMoves state first second).1
    after.side.active.active.moves =
        swapArray state.side.active.active.moves first.val second.val ∧
      after.side.active.active.pp =
        swapArray state.side.active.active.pp first.val second.val ∧
      after.side.active.volatile.disabledMove =
        remapDisabled state.side.active.volatile.disabledMove first second := by
  simp [swapMoves]

/-- Cartridge SELECT swaps the loaded active arrays and the persistent party
arrays independently. When transformed, this deliberately permutes two
different move sets rather than synchronizing either one into the other. -/
def swapActiveAndParty (side : Full.SideState) (first second : Fin 4) : Full.SideState :=
  let activeMon := side.active.active
  let activeMon := { activeMon with
    moves := swapArray activeMon.moves first.val second.val
    pp := swapArray activeMon.pp first.val second.val }
  let volatile := { side.active.volatile with
    disabledMove := remapDisabled side.active.volatile.disabledMove first second }
  let active := { side.active with active := activeMon }
  let active := { active with volatile := volatile }
  let party := { mons := side.party.mons.modify side.activeIndex fun mon =>
    let mon := { mon with moves := swapArray mon.moves first.val second.val }
    { mon with pp := swapArray mon.pp first.val second.val } }
  let side := { side with active := active }
  { side with party := party }

theorem swap_active_and_party_exact (side : Full.SideState) (first second : Fin 4)
    (inBounds : side.activeIndex < side.party.mons.size) :
    let after := swapActiveAndParty side first second
    after.active.active.moves = swapArray side.active.active.moves first.val second.val ∧
      after.active.active.pp = swapArray side.active.active.pp first.val second.val ∧
      (after.party.mons.getD side.activeIndex side.active.active).moves =
        swapArray (side.party.mons.getD side.activeIndex side.active.active).moves
          first.val second.val ∧
      (after.party.mons.getD side.activeIndex side.active.active).pp =
        swapArray (side.party.mons.getD side.activeIndex side.active.active).pp
          first.val second.val := by
  simp [swapActiveAndParty, Array.getD, inBounds, Array.getElem_modify_self]

/-- SELECT swaps complete ordered bag stack entries without consuming a turn. -/
def swapBag (state : State) (first second : Nat) : State × Event :=
  ({ state with bag := swapArray state.bag.toArray first second |>.toList },
    .bagSwapped first second)

inductive Command where
  | openFight
  | highlight (slot : Fin 4)
  | cancelFight
  | swapMoves (first second : Fin 4)
  | swapBag (first second : Nat)
  | commit (action : Full.Action)
  deriving Repr, DecidableEq

structure TraceState where
  selection : State
  committed : Option Full.Action := none
  deriving Repr, DecidableEq

/-- A full-selection interpreter exposes browse/cancel/reorder separately from
the final canonical ActionCommit. -/
def runCommand (trace : TraceState) : Command → TraceState
  | .openFight => { trace with selection := (openFight trace.selection).1 }
  | .highlight slot => { trace with selection := (highlight trace.selection slot).1 }
  | .cancelFight => { trace with selection := (cancelFight trace.selection).1 }
  | .swapMoves first second => { trace with selection := (Selection.swapMoves trace.selection first second).1 }
  | .swapBag first second => { trace with selection := (Selection.swapBag trace.selection first second).1 }
  | .commit action => { trace with committed := some action }

def runTrace (initial : TraceState) (commands : List Command) : TraceState :=
  commands.foldl runCommand initial

@[simp] theorem action_commit_trace_refines_fight (state : State) (slot : Fin 4) :
    (runTrace { selection := state }
      [.openFight, .highlight slot, .commit (.fight slot)]).committed =
        some (.fight slot) := by
  rfl

@[simp] theorem browse_cancel_reorder_trace_is_explicit (state : State)
    (first second : Fin 4) :
    (runTrace { selection := state }
      [.openFight, .highlight first, .cancelFight, .swapMoves first second]).committed = none := by
  rfl

@[simp] theorem openFight_resets_attempts (state : State) :
    (openFight state).1.runAttempts = 0 := rfl

/-- A non-disabled highlight writes the selected move and all cartridge-loaded
move-record fields. -/
theorem enabled_highlight_loads (state : State) (slot : Fin 4)
    (enabled : disabledSlot state.side != some slot.val) :
    let after := (highlight state slot).1
    let move := state.side.active.active.moves.getD slot.val 0
    after.scratch.selectedMove = move ∧
    after.scratch.loadedMove = move ∧
    after.scratch.effect = (Data.moveData move).effect ∧
    after.scratch.power = (Data.moveData move).power ∧
    after.scratch.type = (Data.moveData move).type ∧
    after.scratch.accuracy = (Data.moveData move).accuracy ∧
    after.scratch.pp = (Data.moveData move).pp := by
  have ne : disabledSlot state.side ≠ some slot.val := by
    intro equal
    simp [equal] at enabled
  simp [highlight, ne]

@[simp] theorem swapBag_exact (state : State) (first second : Nat) :
    (swapBag state first second).1.bag =
      (swapArray state.bag.toArray first second).toList := rfl

/-- Disabled highlighting retains every stale loaded field except the cursor. -/
theorem disabled_highlight_preserves_selected (state : State) (slot : Fin 4)
    (disabled : disabledSlot state.side = some slot.val) :
    (highlight state slot).1.scratch.selectedMove = state.scratch.selectedMove := by
  simp [highlight, disabled]

/-- Power/type/accuracy/PP are stale on the disabled browse path as well. -/
theorem disabled_highlight_preserves_record (state : State) (slot : Fin 4)
    (disabled : disabledSlot state.side = some slot.val) :
    let after := (highlight state slot).1.scratch
    after.selectedMove = state.scratch.selectedMove ∧
    after.loadedMove = state.scratch.loadedMove ∧
    after.effect = state.scratch.effect ∧
    after.power = state.scratch.power ∧ after.type = state.scratch.type ∧
    after.accuracy = state.scratch.accuracy ∧ after.pp = state.scratch.pp := by
  simp [highlight, disabled]

@[simp] theorem cancel_preserves (state : State) : (cancelFight state).1 = state := rfl

end Battle.Full.Selection
