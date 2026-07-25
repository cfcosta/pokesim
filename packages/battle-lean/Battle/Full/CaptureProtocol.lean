/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Full.Capture
import Battle.Full.Progression
import Battle.Data.Progression
import Battle.Data.Moves

/-!
# Capture naming and storage protocol

Separates the successful catch calculation from the nested nickname response and
parallel party/box insertion. Box captures insert at slot one and shift every
parallel array together.
-/

namespace Battle.Full.CaptureProtocol

inductive Destination where
  | partyAppend
  | boxSlotOne
  | malformedNoStorage (wrappedPartyCount : UInt8)
  | tutorialNoStorage
  deriving Repr, DecidableEq, BEq

inductive NameResponse where
  | decline
  | custom (name : String)
  deriving Repr, DecidableEq

inductive StoredName where
  | speciesDefault
  | custom (name : String)
  deriving Repr, DecidableEq

structure Pending where
  mon : Progression.PersistentMon
  destination : Destination
  species : SpeciesId
  deriving Repr, DecidableEq

structure Storage where
  party : Array Progression.PersistentMon
  partyNames : Array StoredName
  box : Array Progression.PersistentMon
  boxNames : Array StoredName
  owned : Array SpeciesId
  deriving Repr, DecidableEq

private def initialMoves (species : SpeciesId) : Array MoveId :=
  let moves := Data.Progression.initialMoves.getD species.toNat #[]
  #[moves.getD 0 0, moves.getD 1 0, moves.getD 2 0, moves.getD 3 0]

private def initialPp (moves : Array MoveId) : Array UInt8 :=
  moves.map fun move => if move == 0 then 0 else (Data.moveData move).pp

/-- Rebuild captured base identity/moves/stats while retaining wild DVs, HP,
status, and level. Transformed targets have already supplied Ditto as `species`. -/
def construct (wild : MonState) (species : SpeciesId) (playerId : UInt16) :
    Progression.PersistentMon :=
  let data := Data.speciesData species
  let moves := initialMoves species
  let base := { wild with species := species }
  let base := { base with type1 := data.type1 }
  let base := { base with type2 := data.type2 }
  let base := { base with catchRate := data.catchRate }
  let base := { base with moves := moves }
  let base := { base with pp := initialPp moves }
  let rate := Progression.GrowthRate.ofId (Data.Progression.growthRates.getD species.toNat 0)
  let statExp : Progression.StatExp := { hp := 0, attack := 0, defense := 0, speed := 0, special := 0 }
  let calculated := Progression.calculateStats data base statExp wild.level
  { battle := { calculated with hp := wild.hp, status := wild.status }
    otId := playerId
    experience := Progression.experienceAtLevel rate wild.level
    statExp }

/-- Choose destination using equality-only canonical capacity guards. -/
def begin (partyCount _boxCount : UInt8) (tutorial : Bool)
    (wild : MonState) (species : SpeciesId) (playerId : UInt16) : Pending :=
  let destination := if tutorial then .tutorialNoStorage
    else if partyCount.toNat < 6 then .partyAppend
    else if partyCount == 6 then .boxSlotOne
    else .malformedNoStorage (partyCount + 1)
  { mon := construct wild species playerId, destination, species }

private def resolvedName : NameResponse → StoredName
  | .decline => .speciesDefault
  | .custom name => if name.isEmpty then .speciesDefault else .custom name

/-- Pre-name mutation: owned flag and destination record/parallel placeholder
are installed before the nickname response. -/
def preStore (storage : Storage) (pending : Pending) : Storage :=
  let owned := if storage.owned.contains pending.species then storage.owned
    else storage.owned.push pending.species
  match pending.destination with
  | .partyAppend =>
      let storage := { storage with party := storage.party.push pending.mon }
      let storage := { storage with partyNames := storage.partyNames.push StoredName.speciesDefault }
      { storage with owned := owned }
  | .boxSlotOne =>
      let storage := { storage with box := #[pending.mon] ++ storage.box }
      let storage := { storage with boxNames := #[StoredName.speciesDefault] ++ storage.boxNames }
      { storage with owned := owned }
  | .malformedNoStorage _ => { storage with owned := owned }
  | .tutorialNoStorage => storage

/-- Finish only the nested name write against the already-mutated destination. -/
def finishName (storage : Storage) (pending : Pending) (response : NameResponse) : Storage :=
  let name := resolvedName response
  match pending.destination with
  | .partyAppend =>
      if storage.partyNames.isEmpty then storage
      else { storage with partyNames := storage.partyNames.modify (storage.partyNames.size - 1) (fun _ => name) }
  | .boxSlotOne => { storage with boxNames := storage.boxNames.modify 0 (fun _ => name) }
  | .malformedNoStorage _ | .tutorialNoStorage => storage

/-- Combined convenience transition. -/
def finish (storage : Storage) (pending : Pending) (response : NameResponse) : Storage :=
  finishName (preStore storage pending) pending response

@[simp] theorem tutorial_destination (partyCount boxCount : UInt8) (wild : MonState)
    (species : SpeciesId) (playerId : UInt16) :
    (begin partyCount boxCount true wild species playerId).destination = .tutorialNoStorage := by
  simp [begin]

@[simp] theorem tutorial_skips_storage_and_naming (storage : Storage)
    (partyCount boxCount : UInt8) (wild : MonState) (species : SpeciesId)
    (playerId : UInt16) (response : NameResponse) :
    finish storage (begin partyCount boxCount true wild species playerId) response = storage := by
  simp [finish, finishName, preStore, begin]

/-- Empty custom names take the default-name path. -/
example : resolvedName (.custom "") = .speciesDefault := by native_decide

private theorem modify_prepend_zero (head replacement : α) (tail : Array α) :
    (#[head] ++ tail).modify 0 (fun _ => replacement) = #[replacement] ++ tail := by
  apply Array.ext
  · simp
  · intro index leftBound rightBound
    cases index <;> simp [Array.getElem_modify]

/-- Box capture inserts the new record and resolved name at physical slot one;
the complete previous record and name arrays remain the exact suffixes. -/
theorem box_slot_one_exact (storage : Storage) (pending : Pending) (response : NameResponse)
    (box : pending.destination = .boxSlotOne) :
    (finish storage pending response).box = #[pending.mon] ++ storage.box ∧
      (finish storage pending response).boxNames =
        #[resolvedName response] ++ storage.boxNames := by
  cases destination : pending.destination <;>
    simp_all [finish, preStore, finishName, modify_prepend_zero]

/-- Box insertion shifts records and names in the same direction. -/
theorem box_parallel_sizes (storage : Storage) (pending : Pending) (response : NameResponse)
    (box : pending.destination = .boxSlotOne)
    (aligned : storage.box.size = storage.boxNames.size) :
    (finish storage pending response).box.size = (finish storage pending response).boxNames.size := by
  cases destination : pending.destination <;> simp_all [finish, preStore, finishName]

end Battle.Full.CaptureProtocol
