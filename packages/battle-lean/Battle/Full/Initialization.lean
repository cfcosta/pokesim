/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0.
-/
import Battle.Full.State
import Battle.Data.Species
import Battle.Data.Moves

/-!
# Battle initialization boundaries

Typed summaries for cartridge initialization details that are intentionally not
folded into ordinary turn execution: DV sources, partial reset ranges, trainer
move patches, header lookup special IDs, Pokédex mutation, and byte-counter
party scans.
-/

namespace Battle.Full.Initialization

open Battle Battle.Wram

/-- `LoadEnemyMonData` stores the second BattleRandom byte as Attack/Defense DVs
and the first as Speed/Special DVs. -/
def wildDvs (firstDraw secondDraw : UInt8) : UInt16 :=
  (secondDraw.toUInt16 <<< 8) ||| firstDraw.toUInt16

/-- Every ordinary trainer member uses `$98,$88`. -/
def trainerDvs : UInt16 := 0x9888

@[simp] theorem dv_source_witnesses :
    wildDvs 0x12 0x34 = 0x3412 ∧ trainerDvs = 0x9888 := by
  native_decide

/-- Special trainer patches write only a move byte in the persistent row; the
parallel packed PP byte remains stale until the member becomes active. -/
def patchTrainerMove (mon : MonState) (slot : Fin 4) (move : MoveId) : MonState :=
  { mon with moves := mon.moves.modify slot.val (fun _ => move) }

@[simp] theorem trainer_patch_retains_stale_pp (mon : MonState) (slot : Fin 4)
    (move : MoveId) : (patchTrainerMove mon slot move).pp = mon.pp := by
  rfl

/-- Active load subsequently rebuilds all four packed PP bytes from move data. -/
def reloadActivePp (mon : MonState) : MonState :=
  { mon with pp := mon.moves.map fun move =>
      if move == 0 then 0 else (Data.moveData move).pp }

@[simp] theorem active_pp_reload_matches_moves (mon : MonState) :
    (reloadActivePp mon).pp = mon.moves.map (fun move =>
      if move == 0 then 0 else (Data.moveData move).pp) := by
  rfl

inductive HeaderPlan where
  /-- Ordinary decoded base-stat row by national-dex number. -/
  | baseRow (dex : UInt8)
  /-- Mew's separately banked base-stat row. -/
  | mewRow
  /-- Fossil/Ghost IDs overwrite sprite dimensions/pointer only. -/
  | spriteOnly (species : SpeciesId)
  /-- MissingNo./zero maps through `dec 0` to a raw out-of-table row offset. -/
  | rawOffset (bytes : Nat)
  deriving Repr, DecidableEq

def headerPlan (species : SpeciesId) : HeaderPlan :=
  if species == 0xB6 || species == 0xB7 || species == 0xB8 then
    .spriteOnly species
  else if species == 0x15 then .mewRow
  else
    let dex := Data.internalToDex species
    if dex == 0 then .rawOffset (0xFF * 28) else .baseRow dex

@[simp] theorem header_special_cases :
    headerPlan 0x15 = .mewRow ∧
    headerPlan 0xB6 = .spriteOnly 0xB6 ∧
    headerPlan 0xB7 = .spriteOnly 0xB7 ∧
    headerPlan 0xB8 = .spriteOnly 0xB8 ∧
    headerPlan 0 = .rawOffset (0xFF * 28) := by
  native_decide

/-- Mechanics fields remain stale for fossil/Ghost sprite-only loads. -/
def applyHeaderPlan (prior rawRow : Data.SpeciesData)
    (plan : HeaderPlan) : Data.SpeciesData :=
  match plan with
  | .baseRow dex => Data.baseStatsOfDex dex
  | .mewRow => Data.baseStatsOfDex 151
  | .spriteOnly _ => prior
  | .rawOffset _ => rawRow

@[simp] theorem sprite_only_preserves_mechanics (prior rawRow : Data.SpeciesData)
    (species : SpeciesId) :
    applyHeaderPlan prior rawRow (.spriteOnly species) = prior := by
  rfl

/-- Ordinary loads mark a successfully mapped dex row seen; link loads jump to
`LoadEnemyMonFromParty` and omit the mutation. -/
def seenDexAfterLoad (link : Bool) (plan : HeaderPlan) : Option UInt8 :=
  if link then none else
    match plan with
    | .baseRow dex => some dex
    | .mewRow => some 151
    | .spriteOnly _ | .rawOffset _ => none

@[simp] theorem link_load_omits_seen (plan : HeaderPlan) :
    seenDexAfterLoad true plan = none := by
  cases plan <;> rfl

/-- Number of iterations of the raw byte-decrement HP scans. A zero count wraps
and therefore performs 256 iterations rather than zero. -/
def aliveScanIterations (count : UInt8) : Nat :=
  if count == 0 then 256 else count.toNat

@[simp] theorem zero_count_alive_scan_wraps : aliveScanIterations 0 = 256 := by
  rfl

/-- One unbounded first-living scan step. This is intentionally a reactive step,
not a fuel-bounded search. -/
inductive FirstLivingStep where
  | found (index : Nat)
  | next (index : Nat)
  deriving Repr, DecidableEq

def firstLivingStep (hp : Nat → UInt16) (index : Nat) : FirstLivingStep :=
  if hp index != 0 then .found index else .next (index + 1)

@[simp] theorem first_living_step_exact (hp : Nat → UInt16) (index : Nat) :
    firstLivingStep hp index =
      if hp index != 0 then .found index else .next (index + 1) := by
  rfl

structure ResetImage where
  actionResult : UInt8
  battleResult : UInt8
  escaped : UInt8
  playerIndex : UInt8
  gainFlags : UInt8
  miscBattleData : Array UInt8
  battleStatusData : Array UInt8
  battleType : UInt8
  stackPointer : UInt16
  romBank : UInt8
  deriving Repr, DecidableEq

/-- `InitBattleVariables` clears the named scalars and `wMiscBattleData`, but not
`wBattleStatusData`; normal/Old-Man callers retain their supplied battle type.
Stack and active ROM bank are caller/system state, not part of the clear range. -/
def initBattleVariables (prior : ResetImage) (safariMap : Bool) : ResetImage :=
  { actionResult := 0
    battleResult := 0
    escaped := 0
    playerIndex := 0
    gainFlags := 0
    miscBattleData := prior.miscBattleData.map (fun _ => 0)
    battleStatusData := prior.battleStatusData
    battleType := if safariMap then 2 else prior.battleType
    stackPointer := prior.stackPointer
    romBank := prior.romBank }

@[simp] theorem normal_oldman_and_safari_reset_images (prior : ResetImage) :
    (initBattleVariables { prior with battleType := 0 } false).battleType = 0 ∧
      (initBattleVariables { prior with battleType := 1 } false).battleType = 1 ∧
      (initBattleVariables prior true).battleType = 2 := by
  exact ⟨rfl, rfl, rfl⟩

@[simp] theorem init_partial_reset_exact (prior : ResetImage) :
    let next := initBattleVariables prior false
    next.actionResult = 0 ∧ next.battleResult = 0 ∧ next.escaped = 0 ∧
      next.playerIndex = 0 ∧ next.gainFlags = 0 ∧
      next.battleStatusData = prior.battleStatusData ∧
      next.battleType = prior.battleType ∧ next.stackPointer = prior.stackPointer ∧
      next.romBank = prior.romBank := by
  simp [initBattleVariables]

end Battle.Full.Initialization
