/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.RL.GeneratorSafe
import Battle.Data.Progression

/-!
# Progression-witnessed move and PP histories

This module is stricter than `RL.Legality.canonical`. That older predicate checks
individual learn-pool membership; it does not prove that the four slots can arise
in order. Here a mon starts from `WriteMonMoves`' deterministic acquisition
moves, then changes only through successful TM/HM teaching or PP Up use.

TM copies and PP Ups are consumed from a caller-supplied party-wide ledger. HMs
require ownership but are reusable. There is deliberately no delete event:
learning fills the first empty slot, or replaces one non-HM slot once all four
are occupied. Replaying a generated history is therefore its reachability
witness relative to the supplied acquisition and resource ledger.
-/

namespace Battle.RL.MoveHistory

open Battle.RL

abbrev MachineIndex := Fin 55

structure ResourceLedger where
  tmCopies : Array Nat
  hmOwned : Array Bool
  ppUps : Nat
  deriving Repr, DecidableEq, BEq

/-- One copy of each TM, every HM owned, and an explicit caller-selected PP Up
budget. This is an RL resource budget, not a claim about a fresh save file. -/
def ResourceLedger.oneEach (ppUps : Nat) : ResourceLedger :=
  { tmCopies := (List.replicate 50 1).toArray
    hmOwned := (List.replicate 5 true).toArray
    ppUps }

def ResourceLedger.wf (ledger : ResourceLedger) : Bool :=
  ledger.tmCopies.size == 50 && ledger.hmOwned.size == 5

@[simp] theorem oneEach_wf (ppUps : Nat) : (ResourceLedger.oneEach ppUps).wf := by
  simp [ResourceLedger.oneEach, ResourceLedger.wf]

/-- Machine IDs are zero-based here: `0..49 = TM01..TM50`,
`50..54 = HM01..HM05`. -/
def machineMove (machine : MachineIndex) : MoveId :=
  Data.Progression.tmhmMoves.getD machine.val 0

def isHmMachine (machine : MachineIndex) : Bool := machine.val ≥ 50

def isHmMove (move : MoveId) : Bool :=
  (Data.Progression.tmhmMoves.extract 50 55).contains move

def machineAvailable (ledger : ResourceLedger) (machine : MachineIndex) : Bool :=
  if machine.val < 50 then ledger.tmCopies.getD machine.val 0 > 0
  else ledger.hmOwned.getD (machine.val - 50) false

def consumeMachine (ledger : ResourceLedger) (machine : MachineIndex) : ResourceLedger :=
  if machine.val < 50 then
    { ledger with tmCopies := ledger.tmCopies.modify machine.val (fun copies => copies - 1) }
  else ledger

@[simp] theorem hm_is_reusable (ledger : ResourceLedger) (machine : MachineIndex)
    (hm : machine.val ≥ 50) : consumeMachine ledger machine = ledger := by
  simp [consumeMachine, show ¬machine.val < 50 by omega]

@[simp] theorem tm_consumes_one (ledger : ResourceLedger) (machine : MachineIndex)
    (tm : machine.val < 50) :
    consumeMachine ledger machine =
      { ledger with tmCopies := ledger.tmCopies.modify machine.val (fun copies => copies - 1) } := by
  simp [consumeMachine, tm]

/-- `WriteMonMoves` insertion: duplicates do nothing, an empty slot is filled,
and a full set shifts left before appending the newly available move. -/
def writeMove (moves : Array MoveId) (move : MoveId) : Array MoveId :=
  if moves.contains move then moves
  else if moves.getD 0 0 == 0 then moves.modify 0 (fun _ => move)
  else if moves.getD 1 0 == 0 then moves.modify 1 (fun _ => move)
  else if moves.getD 2 0 == 0 then moves.modify 2 (fun _ => move)
  else if moves.getD 3 0 == 0 then moves.modify 3 (fun _ => move)
  else #[moves.getD 1 0, moves.getD 2 0, moves.getD 3 0, move]

/-- Exact acquisition moves produced from the species header and every ordered
level-up row at or below the acquisition level. -/
def naturalMoves (species : SpeciesId) (level : UInt8) : Array MoveId :=
  let initial := padTo Wram.numMoves 0
    (Data.Progression.initialMoves.getD species.toNat #[])
  let row := Data.Progression.rows.getD species.toNat
    { evolutions := #[], levelMoves := #[] }
  row.levelMoves.foldl (fun moves entry =>
    if entry.level ≤ level then writeMove moves entry.move else moves) initial

structure Origin where
  species : SpeciesId
  level : UInt8
  atkDv : UInt8
  defDv : UInt8
  spdDv : UInt8
  spcDv : UInt8
  deriving Repr, DecidableEq, BEq

/-- A freshly acquired mon: stats come from `CalcStat`; move order comes from
`WriteMonMoves`, not from an unordered learn-pool subset. -/
def acquire (origin : Origin) : MonState :=
  let entry := speciesEntry origin.species
  let generated := genMon entry origin.level origin.atkDv origin.defDv origin.spdDv origin.spcDv 4
  let moves := naturalMoves origin.species (clampLevel origin.level)
  { generated with moves, pp := moves.map movePP }

inductive Event where
  | teach (machine : MachineIndex) (replace : Fin 4)
  | ppUp (slot : Fin 4)
  deriving Repr, DecidableEq

private def firstEmpty? (moves : Array MoveId) : Option (Fin 4) :=
  if moves.getD 0 0 == 0 then some 0
  else if moves.getD 1 0 == 0 then some 1
  else if moves.getD 2 0 == 0 then some 2
  else if moves.getD 3 0 == 0 then some 3
  else none

/-- Apply a compatible machine. TM copies are consumed only on success; HMs are
reusable. Full sets may not replace an HM move, matching Gen-I's learning menu. -/
def teach (mon : MonState) (ledger : ResourceLedger) (machine : MachineIndex)
    (requested : Fin 4) : Option (MonState × ResourceLedger) :=
  let move := machineMove machine
  if !machineAvailable ledger machine ||
      !Data.Progression.machineCompatible mon.species machine.val ||
      move == 0 || mon.moves.contains move then none
  else
    let slot? := match firstEmpty? mon.moves with
      | some empty => some empty
      | none => if isHmMove (mon.moves.getD requested.val 0) then none else some requested
    match slot? with
    | none => none
    | some slot =>
        let mon := { mon with
          moves := mon.moves.modify slot.val (fun _ => move)
          pp := mon.pp.modify slot.val (fun _ => movePP move) }
        some (mon, consumeMachine ledger machine)

/-- One PP Up adds one fifth of base PP, capped at seven, exactly as
`RestoreBonusPP`; count bits remain in bits 6–7 of the packed PP byte. -/
def ppUpBonus (move : MoveId) : UInt8 :=
  (min ((movePP move).toNat / 5) 7).toUInt8

def usePpUp (mon : MonState) (ledger : ResourceLedger) (slot : Fin 4) :
    Option (MonState × ResourceLedger) :=
  let move := mon.moves.getD slot.val 0
  let packed := mon.pp.getD slot.val 0
  let ups := (packed &&& Wram.ppUpMask) >>> 6
  if ledger.ppUps == 0 || move == 0 || ups ≥ 3 then none
  else
    let current := packed &&& Wram.ppMask
    let nextUps := ups + 1
    let next := (nextUps <<< 6) ||| (current + ppUpBonus move)
    let mon := { mon with pp := mon.pp.modify slot.val (fun _ => next) }
    some (mon, { ledger with ppUps := ledger.ppUps - 1 })

def applyEvent (state : MonState × ResourceLedger) : Event → Option (MonState × ResourceLedger)
  | .teach machine slot => teach state.1 state.2 machine slot
  | .ppUp slot => usePpUp state.1 state.2 slot

structure MonPlan where
  origin : Origin
  events : List Event
  deriving Repr, DecidableEq

def replayMon (plan : MonPlan) (ledger : ResourceLedger) :
    Option (MonState × ResourceLedger) :=
  plan.events.foldlM applyEvent (acquire plan.origin, ledger)

private def replayPlans : List MonPlan → ResourceLedger →
    Option (List MonState × ResourceLedger)
  | [], ledger => some ([], ledger)
  | plan :: plans, ledger => do
      let (mon, ledger) ← replayMon plan ledger
      let (mons, ledger) ← replayPlans plans ledger
      pure (mon :: mons, ledger)

structure TeamHistory where
  initialLedger : ResourceLedger
  plans : Array MonPlan
  deriving Repr, DecidableEq

def replayTeam (history : TeamHistory) : Option (Team × ResourceLedger) := do
  let (mons, ledger) ← replayPlans history.plans.toList history.initialLedger
  pure (mons.toArray, ledger)

/-- Teaching has no deletion branch: every success writes the nonzero machine
move into exactly one slot and leaves all other move slots intact. -/
theorem teach_success_shape (mon next : MonState) (ledger nextLedger : ResourceLedger)
    (machine : MachineIndex) (requested : Fin 4)
    (success : teach mon ledger machine requested = some (next, nextLedger)) :
    ∃ slot : Fin 4,
      machineMove machine ≠ 0 ∧
      next.moves = mon.moves.modify slot.val (fun _ => machineMove machine) ∧
      nextLedger = consumeMachine ledger machine := by
  simp only [teach] at success
  split at success
  · contradiction
  · split at success
    · contradiction
    · rename_i slot slotEq
      have nonzero : machineMove machine ≠ 0 := by simp_all
      injection success with pairEq
      injection pairEq with monEq ledgerEq
      subst next
      subst nextLedger
      exact ⟨slot, nonzero, rfl, rfl⟩

/-! ## Exact local regression witnesses -/

#guard naturalMoves 153 100 == #[75, 74, 79, 76] -- Bulbasaur's last four ordered level moves
#guard naturalMoves 76 100 == #[144, 0, 0, 0]   -- Ditto never invents extra moves
#guard machineMove ⟨50, by omega⟩ == 15          -- HM01 Cut
#guard machineMove ⟨52, by omega⟩ == 57          -- HM03 Surf
#guard ppUpBonus 33 == 7                         -- Tackle: floor(35/5)
#guard ppUpBonus 45 == 7                         -- Growl: floor(40/5)=8, capped at 7

/-- PP Up application preserves the move and records one consumed item and one
packed count bit. -/
theorem first_pp_up_exact (mon : MonState) (ledger : ResourceLedger) (slot : Fin 4)
    (available : ledger.ppUps > 0)
    (movePresent : mon.moves[slot.val]?.getD 0 ≠ 0)
    (fresh : mon.pp[slot.val]?.getD 0 &&& Wram.ppUpMask = 0) :
    usePpUp mon ledger slot = some
      ({ mon with pp := mon.pp.modify slot.val (fun _ =>
          ((1 : UInt8) <<< 6) ||| ((mon.pp.getD slot.val 0 &&& Wram.ppMask) +
            ppUpBonus (mon.moves.getD slot.val 0))) },
       { ledger with ppUps := ledger.ppUps - 1 }) := by
  simp [usePpUp, Nat.ne_of_gt available, movePresent, fresh]

/-- A fourth PP Up is rejected and therefore cannot consume the party ledger. -/
theorem fourth_pp_up_rejected (mon : MonState) (ledger : ResourceLedger) (slot : Fin 4)
    (maxed : ((mon.pp[slot.val]?.getD 0 &&& Wram.ppUpMask) >>> 6) = 3) :
    usePpUp mon ledger slot = none := by
  simp [usePpUp, maxed]

end Battle.RL.MoveHistory
