/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Full.Engine
import Battle.Full.Capture
import Battle.Full.CaptureProtocol
import Battle.Full.Evolution
import Battle.Full.TrainerController
import Battle.Full.Safari
import Battle.Full.OldMan
import Battle.RL.DynamicGenerator

/-!
# Full-party RL environment

Resets two independently sampled proof-carrying canonical parties and exposes the
full action/step protocol. Generator, battle, and policy entropy remain separate.
-/

namespace Battle.Full.Environment

open Battle.RL

structure State where
  engine : Engine.State
  playerReset : RL.DynamicGenerator.CanonicalTeam
  enemyReset : RL.DynamicGenerator.CanonicalTeam
  repairedReset : Bool
  playerHistory : RL.MoveHistory.TeamHistory
  enemyHistory : RL.MoveHistory.TeamHistory
  playerRemainingLedger : RL.MoveHistory.ResourceLedger
  enemyRemainingLedger : RL.MoveHistory.ResourceLedger
  playerHistoryReplays : RL.MoveHistory.replayTeam playerHistory =
    some (playerReset.1, playerRemainingLedger)
  enemyHistoryReplays : RL.MoveHistory.replayTeam enemyHistory =
    some (enemyReset.1, enemyRemainingLedger)
  box : Array MonState := #[]
  partyNames : Array CaptureProtocol.StoredName := #[]
  boxNames : Array CaptureProtocol.StoredName := #[]
  ownedSpecies : Array SpeciesId := #[]
  pendingCapture : Option CaptureProtocol.Pending := none
  safari : Option Safari.State := none
  oldManScratch : Option OldMan.State := none
  playerProgression : Array Progression.PersistentMon := #[]
  enemyProgression : Array Progression.PersistentMon := #[]
  canEvolveFlags : UInt8 := 0
  gainExpFlags : UInt8 := 1
  foughtFlags : UInt8 := 1
  hasExpAll : Bool := false
  trainerClass : UInt8 := 1
  trainerActionsLeft : Option UInt8 := none
  pendingLearning : List (Nat × MoveId) := []
  lastEpilogue : Option Money.EpilogueResult := none

structure Observation where
  playerSpecies : Array SpeciesId
  enemySpecies : Array SpeciesId
  playerHp : Array UInt16
  enemyHp : Array UInt16
  playerActive : Nat
  enemyActive : Nat
  playerMoves : Array MoveId
  enemyMoves : Array MoveId
  playerStatus : UInt8
  enemyStatus : UInt8
  turn : Nat
  forcedReplacement : Option Side
  terminalWitnessed : Bool
  done : Bool
  deriving Repr, DecidableEq, BEq

private def fallbackMon : MonState :=
  RL.MoveHistory.acquire
    { species := (entryOf 0).speciesId, level := 100
      atkDv := 15, defDv := 15, spdDv := 15, spcDv := 15 }

private def persistent (owner : UInt16) (mon : MonState) : Progression.PersistentMon :=
  let rate := Progression.GrowthRate.ofId
    (Data.Progression.growthRates.getD mon.species.toNat 0)
  { battle := mon
    otId := owner
    experience := Progression.experienceAtLevel rate mon.level
    statExp := { hp := 0, attack := 0, defense := 0, speed := 0, special := 0 } }

def beginOldManTutorial (state : State) (playerName grassAlias : List UInt8) : State :=
  { state with oldManScratch := some (OldMan.beginTutorial { playerName, grassAlias }) }

private def resetFromSamples (player enemy : RL.DynamicGenerator.Sample)
    (battleRng : Rng.LinkRng) (mode : BattleMode)
    (playerBag enemyBag : Items.Bag) (trainerClass : UInt8) : State :=
  let playerParty : Full.Party := { mons := player.team.1 }
  let enemyParty : Full.Party := { mons := enemy.team.1 }
  let playerSide := Full.SideState.fromParty playerParty fallbackMon
  let enemySide := Full.SideState.fromParty enemyParty fallbackMon
  let battle : Full.State :=
    { player := playerSide, enemy := enemySide, rng := battleRng, turn := 0,
      mode, phase := .battling }
  let safari : Option Safari.State := if mode == .safari then
    some (Safari.State.mk 30 enemySide.active.actualCatchRate
      enemySide.active.actualCatchRate 0 0)
    else none
  { engine := { battle, playerBag, enemyBag }
    playerReset := player.team
    enemyReset := enemy.team
    repairedReset := player.repaired || enemy.repaired
    playerHistory := player.history
    enemyHistory := enemy.history
    playerRemainingLedger := player.remainingLedger
    enemyRemainingLedger := enemy.remainingLedger
    playerHistoryReplays := player.historyReplays
    enemyHistoryReplays := enemy.historyReplays
    box := #[]
    partyNames := player.team.1.map (fun _ => .speciesDefault)
    playerProgression := player.team.1.map (persistent 0)
    enemyProgression := enemy.team.1.map (persistent 0xffff)
    hasExpAll := playerBag.contains 0x4b
    trainerClass := trainerClass
    safari := safari }

/-- Public profile-specific constructor used by the training-state invariant.
It accepts proof-carrying samples without inspecting their proof fields. -/
def linkResetFromSamples (player enemy : RL.DynamicGenerator.Sample)
    (battleRng : Rng.LinkRng) : State :=
  resetFromSamples player enemy battleRng .link [] [] 1

theorem linkResetFromSamples_profile_fields
    (player enemy : RL.DynamicGenerator.Sample) (battleRng : Rng.LinkRng) :
    let state := linkResetFromSamples player enemy battleRng
    state.engine.battle.mode = .link ∧
      state.engine.playerBag = [] ∧ state.engine.enemyBag = [] ∧
      state.pendingCapture = none ∧ state.safari = none ∧
      state.oldManScratch = none ∧ state.pendingLearning = [] ∧
      state.canEvolveFlags = 0 ∧ state.trainerActionsLeft = none := by
  have linkNotSafari : (BattleMode.link == BattleMode.safari) = false := by decide
  simp [linkResetFromSamples, resetFromSamples, linkNotSafari]

/-- Link reset begins with zeroed selected/loaded records and turn scratch on
both physical perspectives. These are cartridge-visible stale fields after the
first menu/turn and therefore are stated explicitly at entry. -/
@[simp] theorem linkResetFromSamples_playerSelection
    (player enemy : RL.DynamicGenerator.Sample) (battleRng : Rng.LinkRng) :
    (linkResetFromSamples player enemy battleRng).engine.playerSelection = {} := by
  rfl

@[simp] theorem linkResetFromSamples_enemySelection
    (player enemy : RL.DynamicGenerator.Sample) (battleRng : Rng.LinkRng) :
    (linkResetFromSamples player enemy battleRng).engine.enemySelection = {} := by
  rfl

@[simp] theorem linkResetFromSamples_playerLastMove
    (player enemy : RL.DynamicGenerator.Sample) (battleRng : Rng.LinkRng) :
    (linkResetFromSamples player enemy battleRng).engine.playerLastMove = 0 := by
  rfl

@[simp] theorem linkResetFromSamples_enemyLastMove
    (player enemy : RL.DynamicGenerator.Sample) (battleRng : Rng.LinkRng) :
    (linkResetFromSamples player enemy battleRng).engine.enemyLastMove = 0 := by
  rfl

@[simp] theorem linkResetFromSamples_sharedDamage
    (player enemy : RL.DynamicGenerator.Sample) (battleRng : Rng.LinkRng) :
    (linkResetFromSamples player enemy battleRng).engine.sharedDamage = 0 := by
  rfl

/-- A proof-carrying link reset installs the supplied parties exactly; it never
resamples or reconstructs either team. -/
@[simp] theorem linkResetFromSamples_parties
    (player enemy : RL.DynamicGenerator.Sample) (battleRng : Rng.LinkRng) :
    let state := linkResetFromSamples player enemy battleRng
    state.engine.battle.player.party.mons = player.team.1 ∧
      state.engine.battle.enemy.party.mons = enemy.team.1 := by
  simp [linkResetFromSamples, resetFromSamples, Full.SideState.fromParty]

/-- The reset installs the supplied cartridge link-RNG image and starts in the
battle phase without consuming a random byte. -/
@[simp] theorem linkResetFromSamples_rng_phase
    (player enemy : RL.DynamicGenerator.Sample) (battleRng : Rng.LinkRng) :
    let state := linkResetFromSamples player enemy battleRng
    state.engine.battle.rng = battleRng ∧
      state.engine.battle.phase = .battling := by
  simp [linkResetFromSamples, resetFromSamples, Full.SideState.fromParty]

/-- Swapping supplied parties constructs the opposite cartridge perspective:
both live active structs, RNG state, and phases are exact mirrors. -/
@[simp] theorem linkResetFromSamples_swapped_synchronized
    (player enemy : RL.DynamicGenerator.Sample) (battleRng : Rng.LinkRng) :
    let left := linkResetFromSamples player enemy battleRng
    let right := linkResetFromSamples enemy player battleRng
    left.engine.battle.player.active.active =
        right.engine.battle.enemy.active.active ∧
      left.engine.battle.enemy.active.active =
        right.engine.battle.player.active.active ∧
      left.engine.battle.rng = right.engine.battle.rng ∧
      left.engine.battle.phase = .battling ∧
      right.engine.battle.phase = .battling := by
  simp [linkResetFromSamples, resetFromSamples, Full.SideState.fromParty]

/-- Opposite reset perspectives begin with the same two active indexes. -/
@[simp] theorem linkResetFromSamples_swapped_indexes
    (player enemy : RL.DynamicGenerator.Sample) (battleRng : Rng.LinkRng) :
    let left := linkResetFromSamples player enemy battleRng
    let right := linkResetFromSamples enemy player battleRng
    left.engine.battle.player.activeIndex = right.engine.battle.enemy.activeIndex ∧
      left.engine.battle.enemy.activeIndex = right.engine.battle.player.activeIndex := by
  simp [linkResetFromSamples, resetFromSamples, Full.SideState.fromParty]

/-- Reset from independent generator and battle streams. -/
def reset (generatorRng battleRng : Rng.LinkRng)
    (mode : BattleMode := .link) (playerBag enemyBag : Items.Bag := [])
    (trainerClass : UInt8 := 1) : State :=
  let player := RL.DynamicGenerator.sample generatorRng
  let enemy := RL.DynamicGenerator.sample player.rng
  resetFromSamples player enemy battleRng mode playerBag enemyBag trainerClass

/-- Reset with independently sized progression-witnessed parties. Each size is
clamped to `1..6`; generator and battle entropy remain independent. -/
def resetSizedPair (playerRequested enemyRequested : Nat)
    (generatorRng battleRng : Rng.LinkRng)
    (mode : BattleMode := .link) (playerBag enemyBag : Items.Bag := [])
    (trainerClass : UInt8 := 1) : State :=
  let player := RL.DynamicGenerator.sampleSized playerRequested generatorRng
  let enemy := RL.DynamicGenerator.sampleSized enemyRequested player.rng
  resetFromSamples player enemy battleRng mode playerBag enemyBag trainerClass

/-- Reset with independently sized parties whose displayed final species use
the bounded near-uniform 151-species profile. -/
def resetSizedPairBalanced (playerRequested enemyRequested : Nat)
    (generatorRng battleRng : Rng.LinkRng)
    (mode : BattleMode := .link) (playerBag enemyBag : Items.Bag := [])
    (trainerClass : UInt8 := 1) : State :=
  let player := RL.DynamicGenerator.sampleSizedBalanced playerRequested generatorRng
  let enemy := RL.DynamicGenerator.sampleSizedBalanced enemyRequested player.rng
  resetFromSamples player enemy battleRng mode playerBag enemyBag trainerClass

/-- Reset a generated battle whose independently sampled parties are both
fully level 100. This is a distribution profile for competitive 6v6 strata;
the teams retain the ordinary ordered progression/resource witnesses. -/
def resetSizedPairLevel100 (playerRequested enemyRequested : Nat)
    (generatorRng battleRng : Rng.LinkRng)
    (mode : BattleMode := .link) (playerBag enemyBag : Items.Bag := [])
    (trainerClass : UInt8 := 1) : State :=
  let player := RL.DynamicGenerator.sampleSizedLevel100 playerRequested generatorRng
  let enemy := RL.DynamicGenerator.sampleSizedLevel100 enemyRequested player.rng
  resetFromSamples player enemy battleRng mode playerBag enemyBag trainerClass

/-- Balanced-final-species level-100 reset. -/
def resetSizedPairBalancedLevel100 (playerRequested enemyRequested : Nat)
    (generatorRng battleRng : Rng.LinkRng)
    (mode : BattleMode := .link) (playerBag enemyBag : Items.Bag := [])
    (trainerClass : UInt8 := 1) : State :=
  let player := RL.DynamicGenerator.sampleSizedBalancedLevel100 playerRequested generatorRng
  let enemy := RL.DynamicGenerator.sampleSizedBalancedLevel100 enemyRequested player.rng
  resetFromSamples player enemy battleRng mode playerBag enemyBag trainerClass

/-- Generate the same ordered pair as `resetSizedPair`, then install the second
sample on the player side and the first sample on the enemy side. This is the
second leg of paired mirror collection; generation and battle RNG inputs are
unchanged. -/
def resetSizedPairSwapped (playerRequested enemyRequested : Nat)
    (generatorRng battleRng : Rng.LinkRng) : State :=
  let player := RL.DynamicGenerator.sampleSized playerRequested generatorRng
  let enemy := RL.DynamicGenerator.sampleSized enemyRequested player.rng
  resetFromSamples enemy player battleRng .link [] [] 1

/-- Swapped counterpart of `resetSizedPairBalanced`. -/
def resetSizedPairBalancedSwapped (playerRequested enemyRequested : Nat)
    (generatorRng battleRng : Rng.LinkRng) : State :=
  let player := RL.DynamicGenerator.sampleSizedBalanced playerRequested generatorRng
  let enemy := RL.DynamicGenerator.sampleSizedBalanced enemyRequested player.rng
  resetFromSamples enemy player battleRng .link [] [] 1

/-- Level-100 counterpart of `resetSizedPairSwapped`. -/
def resetSizedPairLevel100Swapped (playerRequested enemyRequested : Nat)
    (generatorRng battleRng : Rng.LinkRng) : State :=
  let player := RL.DynamicGenerator.sampleSizedLevel100 playerRequested generatorRng
  let enemy := RL.DynamicGenerator.sampleSizedLevel100 enemyRequested player.rng
  resetFromSamples enemy player battleRng .link [] [] 1

/-- Swapped counterpart of the balanced level-100 reset. -/
def resetSizedPairBalancedLevel100Swapped (playerRequested enemyRequested : Nat)
    (generatorRng battleRng : Rng.LinkRng) : State :=
  let player := RL.DynamicGenerator.sampleSizedBalancedLevel100 playerRequested generatorRng
  let enemy := RL.DynamicGenerator.sampleSizedBalancedLevel100 enemyRequested player.rng
  resetFromSamples enemy player battleRng .link [] [] 1

/-- Swapped and ordinary constructors use the same two generated samples in
opposite physical positions. -/
theorem resetSizedPair_swaps_exact_samples (playerRequested enemyRequested : Nat)
    (generatorRng battleRng : Rng.LinkRng) :
    let ordinary := resetSizedPair playerRequested enemyRequested generatorRng battleRng
    let swapped := resetSizedPairSwapped playerRequested enemyRequested generatorRng battleRng
    swapped.playerReset = ordinary.enemyReset ∧
      swapped.enemyReset = ordinary.playerReset := by
  simp [resetSizedPair, resetSizedPairSwapped, resetFromSamples]

@[simp] theorem resetSizedPairLevel100_swaps_exact_samples
    (playerRequested enemyRequested : Nat) (generatorRng battleRng : Rng.LinkRng) :
    let ordinary := resetSizedPairLevel100 playerRequested enemyRequested
      generatorRng battleRng
    let swapped := resetSizedPairLevel100Swapped playerRequested enemyRequested
      generatorRng battleRng
    swapped.playerReset = ordinary.enemyReset ∧
      swapped.enemyReset = ordinary.playerReset := by
  simp [resetSizedPairLevel100, resetSizedPairLevel100Swapped, resetFromSamples]

@[simp] theorem resetSizedPairBalanced_swaps_exact_samples
    (playerRequested enemyRequested : Nat) (generatorRng battleRng : Rng.LinkRng) :
    let ordinary := resetSizedPairBalanced playerRequested enemyRequested
      generatorRng battleRng
    let swapped := resetSizedPairBalancedSwapped playerRequested enemyRequested
      generatorRng battleRng
    swapped.playerReset = ordinary.enemyReset ∧
      swapped.enemyReset = ordinary.playerReset := by
  simp [resetSizedPairBalanced, resetSizedPairBalancedSwapped, resetFromSamples]

@[simp] theorem resetSizedPairBalancedLevel100_swaps_exact_samples
    (playerRequested enemyRequested : Nat) (generatorRng battleRng : Rng.LinkRng) :
    let ordinary := resetSizedPairBalancedLevel100 playerRequested enemyRequested
      generatorRng battleRng
    let swapped := resetSizedPairBalancedLevel100Swapped playerRequested enemyRequested
      generatorRng battleRng
    swapped.playerReset = ordinary.enemyReset ∧
      swapped.enemyReset = ordinary.playerReset := by
  simp [resetSizedPairBalancedLevel100, resetSizedPairBalancedLevel100Swapped,
    resetFromSamples]

/-- Equal-size compatibility wrapper around `resetSizedPair`. -/
def resetSized (requested : Nat) (generatorRng battleRng : Rng.LinkRng)
    (mode : BattleMode := .link) (playerBag enemyBag : Items.Bag := [])
    (trainerClass : UInt8 := 1) : State :=
  resetSizedPair requested requested generatorRng battleRng mode playerBag enemyBag
    trainerClass

/-- Done only after explicit cleanup settlement. -/
def done (state : State) : Bool :=
  match state.engine.battle.phase with
  | .returned _ => true
  | _ => false

/-- Apply the money/evolution guard and explicit cleanup boundary. Generated
resets have no progression flags; callers with flagged recipients must resolve
those evolution requests before invoking this boundary. -/
def settle (state : State) : State :=
  match state.engine.battle.phase with
  | .ending terminal =>
      let result := Money.epilogue
        { linkBattle := state.engine.battle.mode == .link
          rawBattleResult := terminal.rawResult
          playerMoney := state.engine.playerMoney
          payDayMoney := state.engine.payDayMoney }
      if !state.pendingLearning.isEmpty || (result.runEvolution && state.canEvolveFlags != 0) then state
      else
        let engine := { state.engine with playerMoney := result.playerMoney, battle :=
          { state.engine.battle with phase := .returned ⟨terminal⟩ } }
        { state with engine, lastEpilogue := some result }
  | _ => state

@[simp] theorem settle_after_nested_completion (state : State)
    (terminal : Outcome.BattleTerminal)
    (phase : state.engine.battle.phase = .ending terminal)
    (learningDone : state.pendingLearning = [])
    (evolutionDone : state.canEvolveFlags = 0) :
    (settle state).engine.battle.phase = .returned ⟨terminal⟩ := by
  simp [settle, phase, learningDone, evolutionDone]

@[simp] theorem settle_waits_for_learning (state : State)
    (terminal : Outcome.BattleTerminal)
    (phase : state.engine.battle.phase = .ending terminal)
    (head : Nat × MoveId) (tail : List (Nat × MoveId))
    (pending : state.pendingLearning = head :: tail) :
    settle state = state := by
  simp [settle, phase, pending]

private def currentParty (state : State) (who : Side) : Array MonState :=
  (state.engine.battle.side who).syncOutgoing.party.mons

private def syncProgressionRows (rows : Array Progression.PersistentMon)
    (mons : Array MonState) : Array Progression.PersistentMon :=
  rows.mapIdx fun index row => { row with battle := mons.getD index row.battle }

/-- Construct the post-battle evolution machine after synchronizing active rows
into persistent progression storage. Nonzero raw non-link exits have no
EvolutionAfterBattle request. -/
def evolution? (state : State) (aliasedItem : Option UInt8 := none) :
    Option Evolution.Machine :=
  match state.engine.battle.phase with
  | .ending terminal =>
      if !state.pendingLearning.isEmpty then none
      else
      let guard := Money.epilogue
        { linkBattle := state.engine.battle.mode == .link
          rawBattleResult := terminal.rawResult
          playerMoney := state.engine.playerMoney
          payDayMoney := state.engine.payDayMoney }
      if !guard.runEvolution then none
      else
        let rows := syncProgressionRows state.playerProgression (currentParty state .player)
        some (Evolution.start rows state.canEvolveFlags state.engine.battle.mode aliasedItem)
  | _ => none

inductive LearningResult where
  | pending (state : State) (index : Nat) (machine : Learning.Machine)
  | completed (state : State)
  | invalid (state : State) (index : Nat) (machine : Learning.Machine)

/-- Start the first queued exact-level learning request. -/
def learning? (state : State) : Option (Nat × Learning.Machine) :=
  match state.pendingLearning with
  | [] => none
  | (index, move) :: _ =>
      (state.playerProgression[index]?).map fun mon => (index, Learning.start mon move)

def installLearnedMoves (active : Battle.SideState) (partyMon : MonState) : Battle.SideState :=
  let mon := { active.active with moves := partyMon.moves }
  let mon := { mon with pp := partyMon.pp }
  { active with active := mon }

@[simp] theorem transformed_learning_preserves_active_identity
    (active : Battle.SideState) (partyMon : MonState) :
    let installed := installLearnedMoves active partyMon
    installed.active.moves = partyMon.moves ∧ installed.active.pp = partyMon.pp ∧
    installed.active.species = active.active.species ∧
    installed.active.type1 = active.active.type1 ∧ installed.active.type2 = active.active.type2 ∧
    installed.active.status = active.active.status ∧ installed.volatile = active.volatile := by
  simp [installLearnedMoves]

private def installLearning (state : State) (index : Nat) (machine : Learning.Machine) : State :=
  let rows := state.playerProgression.modify index (fun _ => machine.mon)
  let mons := rows.map Progression.PersistentMon.battle
  let player := state.engine.battle.player
  let activeMon := mons.getD player.activeIndex player.active.active
  let player := { player with party := { mons } }
  let player := { player with active := installLearnedMoves player.active activeMon }
  let battle := state.engine.battle.setSide .player player
  { state with
    engine := { state.engine with battle }
    playerProgression := rows
    pendingLearning := state.pendingLearning.drop 1 }

/-- Complete an automatic/finished learning request. -/
def completeLearning (state : State) (index : Nat) (machine : Learning.Machine) : LearningResult :=
  match machine.phase with
  | .completed _ => .completed (installLearning state index machine)
  | _ => .pending state index machine

/-- Resume one nested level-up learning response. -/
def resumeLearning (state : State) (index : Nat) (machine : Learning.Machine)
    (response : Learning.Response) : LearningResult :=
  match Learning.respond machine response with
  | none => .invalid state index machine
  | some machine => completeLearning state index machine

inductive EvolutionResult where
  | pending (state : State) (machine : Evolution.Machine)
  | completed (state : State)
  | invalid (state : State) (machine : Evolution.Machine)

def installEvolutionOwned (owned : Array SpeciesId) (events : List Evolution.Event) :
    Array SpeciesId :=
  events.foldl (fun owned event => match event with
    | .evolved _ _ target => if owned.contains target then owned else owned.push target
    | _ => owned) owned

def installEvolution (state : State) (machine : Evolution.Machine) : State :=
  let mons := machine.party.map Progression.PersistentMon.battle
  let player := state.engine.battle.player
  let activeMon := mons.getD player.activeIndex player.active.active
  let player := { player with party := { mons }, active := { player.active with active := activeMon } }
  let battle := state.engine.battle.setSide .player player
  { state with
    engine := { state.engine with battle }
    playerProgression := machine.party
    ownedSpecies := installEvolutionOwned state.ownedSpecies machine.events
    canEvolveFlags := 0 }

@[simp] theorem evolution_install_preserves_names (state : State)
    (machine : Evolution.Machine) :
    (installEvolution state machine).partyNames = state.partyNames := by
  rfl

@[simp] theorem evolution_owned_witness :
    installEvolutionOwned #[] [.evolved 0 1 2] = #[2] := by
  native_decide

/-- Complete an already exhausted evolution scan. -/
def completeEvolution (state : State) (machine : Evolution.Machine) : EvolutionResult :=
  match machine.phase with
  | .completed => .completed (settle (installEvolution state machine))
  | _ => .pending state machine

/-- Compose one nested evolution/learning response back into the battle
settlement state. -/
def resumeEvolution (state : State) (machine : Evolution.Machine)
    (response : Evolution.Response) : EvolutionResult :=
  match Evolution.respond machine response with
  | none => .invalid state machine
  | some machine => completeEvolution state machine

def observe (state : State) : Observation :=
  let player := currentParty state .player
  let enemy := currentParty state .enemy
  { playerSpecies := player.map MonState.species
    enemySpecies := enemy.map MonState.species
    playerHp := player.map MonState.hp
    enemyHp := enemy.map MonState.hp
    playerActive := state.engine.battle.player.activeIndex
    enemyActive := state.engine.battle.enemy.activeIndex
    playerMoves := state.engine.battle.player.active.active.moves
    enemyMoves := state.engine.battle.enemy.active.active.moves
    playerStatus := state.engine.battle.player.active.active.status
    enemyStatus := state.engine.battle.enemy.active.active.status
    turn := state.engine.battle.turn
    forcedReplacement := state.engine.forcedReplacement
    terminalWitnessed := state.engine.battle.phase.isTerminal
    done := done state }

def legalActions (state : State) (who : Side) : Array Full.Action :=
  Engine.legalActions state.engine who

inductive TrainerPlan where
  | choosingMove (state : State) (machine : TrainerController.MoveMachine)
  | fight (state : State) (slot : Fin 4)
  | item (state : State) (item : TrainerAI.Item)
  | switch (state : State) (target : Fin 6)
  | invalidClass (state : State)

private def trainerContext (state : State) : TrainerAI.Context :=
  let enemy := state.engine.battle.enemy
  { currentHp := enemy.active.active.hp
    maxHp := enemy.active.active.maxHp
    hasSwitchReserve := !enemy.legalSwitches.isEmpty }

private def trainerScoreInput (state : State) : TrainerController.ScoreInput :=
  let enemy := state.engine.battle.enemy.active.active
  let target := state.engine.battle.player.active.active
  TrainerController.ScoreInput.fromBattle enemy.moves target.status
    state.engine.aiLayer2Encouragement target.type1 target.type2
    (if state.engine.battle.enemy.active.volatile.disabledMoveNumber == 0 then none
     else
       let slot := (state.engine.battle.enemy.active.volatile.disabledMove.toNat / 16 - 1) % 4
       some ⟨slot, by omega⟩)

/-- Consume the trainer action-AI direct-Random byte, then either commit an
item/switch routine or enter minimum-score BattleRandom move selection. Layer-3
observations are derived internally from the active target and canonical table. -/
def prepareTrainer (state : State) (directRandom : UInt8) : TrainerPlan :=
  match TrainerController.classRow? state.trainerClass with
  | none => .invalidClass state
  | some row =>
      let scoreInput := trainerScoreInput state
      let remaining := state.trainerActionsLeft.getD row.initialActions
      let decision := if remaining == 0 then TrainerController.ActionDecision.normal
        else TrainerController.decideAction row.routine directRandom (trainerContext state)
          (state.engine.battle.enemy.active.active.status != 0)
      let nextRemaining := (TrainerController.commitDecision { remaining } decision).remaining
      let state := { state with trainerActionsLeft := some nextRemaining }
      match decision with
      | .item item => .item state item
      | .switch =>
          match found : state.engine.battle.enemy.firstLegalSwitch with
          | some target =>
              have bounded : target < Wram.partyLength := by
                have bounds := Full.SideState.firstSwitchFrom_bounds
                  state.engine.battle.enemy 0 Wram.partyLength target
                  (by simpa [Full.SideState.firstLegalSwitch] using found)
                omega
              .switch state ⟨target, by simpa [Wram.partyLength] using bounded⟩
          | none =>
              let input := { scoreInput with moves := state.engine.battle.enemy.active.active.moves }
              let scores := TrainerController.scoreMoves row input
              let machine : TrainerController.MoveMachine :=
                { moves := input.moves
                  disabled := state.engine.battle.enemy.active.volatile.disabledMoveNumber
                  scores := scores
                  rng := state.engine.battle.rng }
              .choosingMove state machine
      | .normal =>
          let input := { scoreInput with moves := state.engine.battle.enemy.active.active.moves }
          let scores := TrainerController.scoreMoves row input
          let machine : TrainerController.MoveMachine :=
            { moves := input.moves
              disabled := state.engine.battle.enemy.active.volatile.disabledMoveNumber
              scores := scores
              rng := state.engine.battle.rng }
          .choosingMove state machine

/-- Advance one move-slot rejection draw and install the accepted RNG cursor. -/
def resumeTrainerMove (state : State) (machine : TrainerController.MoveMachine) : TrainerPlan :=
  let machine := TrainerController.feedMove machine
  match machine.phase with
  | .choosing => .choosingMove state machine
  | .selected slot =>
      let engine := { state.engine with battle := { state.engine.battle with rng := machine.rng } }
      .fight { state with engine } slot

inductive StepResult where
  | transitioned (state : State) (events : List Engine.Event)
  | invalidAction (state : State) (side : Side)
  | ineffectiveAction (state : State) (side : Side)
  | capturePending (state : State) (ball : UInt8) (events : List Engine.Event)
  | rngStuck (state : State) (events : List Engine.Event)
  | divisionFreeze (state : State) (events : List Engine.Event)
  | nestedMove (state : State) (side : Side) (move : MoveId) (events : List Engine.Event)
  | mimicPending (state : State) (side : Side) (sourceSlot : Fin 4)
      (nextAction : Option Full.Action) (events : List Engine.Event)
  | runPending (state : State) (side : Side) (opponentAction : Full.Action)
      (events : List Engine.Event)
  | wildFaintRunPending (state : State) (events : List Engine.Event)
  | disobediencePending (state : State) (machine : Disobedience.Machine)
      (nextEnemyAction : Option Full.Action) (events : List Engine.Event)
  | inactive (state : State)

def countFlags (flags : UInt8) : UInt8 :=
  (List.range 8).foldl (fun count bit => if flags.toNat.testBit bit then count + 1 else count) 0

def expRecipientEligible (flags : UInt8) (index : Nat) (fainted : Bool) : Bool :=
  flags.toNat.testBit index && !fainted

@[simp] theorem fainted_recipient_skipped (flags : UInt8) (index : Nat) :
    expRecipientEligible flags index true = false := by
  simp [expRecipientEligible]

def copyLevelUpFields (active partyMon : MonState) : MonState :=
  let active := { active with hp := partyMon.hp }
  let active := { active with level := partyMon.level }
  let active := { active with maxHp := partyMon.maxHp }
  let active := { active with attack := partyMon.attack }
  let active := { active with defense := partyMon.defense }
  let active := { active with speed := partyMon.speed }
  { active with special := partyMon.special }

def levelUpBadgeBoostsEnabled : BattleMode → Bool
  | .link => false
  | _ => true

private def setCombatStat (mon : MonState) (stat : Nat) (value : UInt16) : MonState :=
  match stat with
  | 0 => { mon with attack := value }
  | 1 => { mon with defense := value }
  | 2 => { mon with speed := value }
  | _ => { mon with special := value }

private def stageAt (stages : StatStages) : Nat → UInt8
  | 0 => stages.attack
  | 1 => stages.defense
  | 2 => stages.speed
  | _ => stages.special

private def unmodifiedAt (stats : CombatStats) : Nat → UInt16
  | 0 => stats.attack
  | 1 => stats.defense
  | 2 => stats.speed
  | _ => stats.special

private def reapplyStages (mon : MonState) (unmodified : CombatStats)
    (stages : StatStages) : MonState :=
  (List.range 4).foldl (fun mon stat =>
    setCombatStat mon stat (DamageStats.applyStage (unmodifiedAt unmodified stat)
      (stageAt stages stat))) mon

private def reapplyLevelStatus (mon : MonState) : MonState :=
  let mon := if mon.paralyzed then { mon with speed := UInt16.ofNat (mon.speed.toNat / 4) }
    else mon
  if mon.burned then { mon with attack := UInt16.ofNat (mon.attack.toNat / 2) } else mon

private def reapplyLevelBadges (badges : UInt8) (mon : MonState) : MonState :=
  let boost (bit stat : Nat) (mon : MonState) :=
    if bitSet badges bit then setCombatStat mon stat
      (DamageStats.badgeBoost (match stat with
        | 0 => mon.attack | 1 => mon.defense | 2 => mon.speed | _ => mon.special))
    else mon
  boost 6 3 (boost 4 2 (boost 2 1 (boost 0 0 mon)))

/-- Active level-up synchronization copies only HP/level/stats, then recomputes
stages, burn/paralysis, and non-link badge boosts. Transform retains copied
identity, moves/PP, status, volatile bytes, and the prior unmodified stat row. -/
def reapplyLevelUpActive (mode : BattleMode) (badges : UInt8)
    (before : Battle.SideState) (partyMon : MonState) : Battle.SideState :=
  let transformed := bitSet before.volatile.status3 Wram.BattleStatus3.transformed
  let unmodified := if transformed then before.unmodified else CombatStats.ofMon partyMon
  let copied := copyLevelUpFields before.active partyMon
  let calculated := reapplyStages copied unmodified before.stages
  let calculated := reapplyLevelStatus calculated
  let calculated := if levelUpBadgeBoostsEnabled mode then
    reapplyLevelBadges badges calculated else calculated
  let active := { before.active with hp := partyMon.hp }
  let active := { active with level := partyMon.level }
  let active := { active with maxHp := partyMon.maxHp }
  let active := { active with attack := calculated.attack }
  let active := { active with defense := calculated.defense }
  let active := { active with speed := calculated.speed }
  let active := { active with special := calculated.special }
  { before with active, unmodified }

@[simp] theorem level_up_preserves_copied_identity (mode : BattleMode) (badges : UInt8)
    (before : Battle.SideState) (partyMon : MonState) :
    let after := reapplyLevelUpActive mode badges before partyMon
    after.active.species = before.active.species ∧
    after.active.moves = before.active.moves ∧ after.active.pp = before.active.pp ∧
    after.active.status = before.active.status ∧ after.volatile = before.volatile ∧
    after.active.hp = partyMon.hp ∧ after.active.maxHp = partyMon.maxHp ∧
    after.active.level = partyMon.level := by
  simp [reapplyLevelUpActive]

private def levelUpTestMon : MonState :=
  { species := 1, hp := 50, boxLevel := 50, status := 0x10,
    type1 := 0, type2 := 0, catchRate := 45, moves := #[1, 2, 3, 4], dvs := 0,
    level := 50, maxHp := 100, attack := 100, defense := 100, speed := 100,
    special := 100, pp := #[1, 1, 1, 1] }

private def levelUpTestSide : Battle.SideState :=
  let side := Battle.SideState.fresh levelUpTestMon
  { side with stages := { side.stages with attack := 8 } }

/-- Modified stages run first, burn/paralysis second, and badges last; link mode
bypasses badge application. -/
theorem level_up_reapplication_order_witness :
    (reapplyLevelUpActive .wild 1 levelUpTestSide levelUpTestMon).active.attack = 84 ∧
    (reapplyLevelUpActive .link 1 levelUpTestSide levelUpTestMon).active.attack = 75 ∧
    (reapplyLevelUpActive .wild 1 levelUpTestSide levelUpTestMon).unmodified.attack = 100 := by
  native_decide

def markCanEvolve (flags : UInt8) (index : Nat) (levelsGained : UInt8) : UInt8 :=
  if levelsGained != 0 then flags ||| (1 <<< index).toUInt8 else flags

@[simp] theorem gained_level_sets_evolution_flag (flags : UInt8) (index : Nat)
    (levelsGained : UInt8) (gained : levelsGained != 0) :
    markCanEvolve flags index levelsGained = flags ||| (1 <<< index).toUInt8 := by
  simp [markCanEvolve, gained]

private def awardGroup (state : State) (source : Progression.AwardSource)
    (awardFlags : UInt8) : State :=
  let recipients := countFlags awardFlags
  if recipients == 0 then state
  else
    let context : Progression.AwardContext :=
      { playerId := state.engine.playerId
        trainerBattle := state.engine.battle.mode == .trainer
        recipients }
    let synced := syncProgressionRows state.playerProgression (currentParty state .player)
    let initial := (synced, state.canEvolveFlags, state.pendingLearning)
    let awarded := (List.range synced.size).foldl (fun accumulator index =>
      let row := accumulator.1
      let flags := accumulator.2.1
      let requests := accumulator.2.2
      let mon := row.getD index (synced.getD index (persistent 0 fallbackMon))
      if expRecipientEligible awardFlags index mon.battle.fainted then
        let rate := Progression.GrowthRate.ofId
          (Data.Progression.growthRates.getD mon.battle.species.toNat 0)
        let result := Progression.award rate (Data.speciesData mon.battle.species)
          source context mon index
        let flags := markCanEvolve flags index result.levelsGained
        let requests := requests ++ result.requests.filterMap (fun request => match request with
          | .learnMove index move => some (index, move)
          | _ => none)
        (row.modify index (fun _ => result.mon), flags, requests)
      else (row, flags, requests)) initial
    let rows := awarded.1
    let mons := rows.map Progression.PersistentMon.battle
    let player := state.engine.battle.player
    let oldActiveMon := synced.getD player.activeIndex (persistent 0 player.active.active)
    let activeMon := mons.getD player.activeIndex player.active.active
    let activeLeveled := activeMon.level != oldActiveMon.battle.level
    let active := if activeLeveled then
      reapplyLevelUpActive state.engine.battle.mode state.engine.badges player.active activeMon
      else player.active
    let player := { player with party := { mons }, active }
    let battle := state.engine.battle.setSide .player player
    { state with
      engine := { state.engine with battle }
      playerProgression := rows
      canEvolveFlags := awarded.2.1
      pendingLearning := awarded.2.2 }

private def halveSource (source : Progression.AwardSource) : Progression.AwardSource :=
  { source with
    baseHp := source.baseHp >>> 1
    baseAttack := source.baseAttack >>> 1
    baseDefense := source.baseDefense >>> 1
    baseSpeed := source.baseSpeed >>> 1
    baseSpecial := source.baseSpecial >>> 1
    catchRate := source.catchRate >>> 1
    baseExp := source.baseExp >>> 1 }

def expAllEffectiveSource (source : Progression.AwardSource)
    (participants partyMembers : UInt8) : Progression.AwardSource :=
  Progression.divideSource (Progression.divideSource (halveSource source) participants)
    partyMembers

/-- The second pass observes the source already destructively divided by the
first participant count, then divides it again by full party membership. -/
theorem exp_all_destructive_double_division :
    let source : Progression.AwardSource :=
      { baseHp := 100, baseAttack := 100, baseDefense := 100,
        baseSpeed := 100, baseSpecial := 100, catchRate := 100,
        baseExp := 100, level := 50 }
    let effective := expAllEffectiveSource source 2 5
    effective.baseHp = 5 ∧ effective.baseAttack = 5 ∧
      effective.baseDefense = 5 ∧ effective.baseSpeed = 5 ∧
      effective.baseSpecial = 5 ∧ effective.catchRate = 5 ∧
      effective.baseExp = 5 := by
  native_decide

private def partyFlags (count : Nat) : UInt8 :=
  (List.range count).foldl (fun flags index => flags ||| (1 <<< index).toUInt8) 0

def expAllDivisor (partySize : Nat) : UInt8 :=
  countFlags (partyFlags partySize)

def expAllDivisorExhaustive : Bool :=
  (List.range 7).all fun size => expAllDivisor size == size.toUInt8

/-- Every in-party row contributes to the second-pass divisor for legal party
sizes, independent of later fainted-recipient rejection. -/
theorem exp_all_counts_full_party : expAllDivisorExhaustive = true := by
  native_decide

@[simp] theorem all_eight_gain_bits_count : countFlags 0xff = 8 := by
  native_decide

private def awardEnemy (state : State) : State :=
  if state.engine.battle.mode == .link then state
  else
    let enemy := state.engine.battle.enemy.active.active
    let data := Data.speciesData enemy.species
    let source : Progression.AwardSource :=
      { baseHp := data.baseHp
        baseAttack := data.baseAtk
        baseDefense := data.baseDef
        baseSpeed := data.baseSpd
        baseSpecial := data.baseSpc
        catchRate := data.catchRate
        baseExp := data.baseExp
        level := enemy.level }
    let state := if state.hasExpAll then
      let halved := halveSource source
      let participants := countFlags state.gainExpFlags
      let state := awardGroup state halved state.gainExpFlags
      -- GainExperience divided the same WRAM source in place during phase one.
      let destructivelyDivided := Progression.divideSource halved participants
      awardGroup state destructivelyDivided (partyFlags state.playerProgression.size)
    else awardGroup state source state.gainExpFlags
    let activeFlag := (1 <<< state.engine.battle.player.activeIndex).toUInt8
    { state with gainExpFlags := activeFlag, foughtFlags := activeFlag }

def clearGainFlag (flags : UInt8) (target : Nat) : UInt8 :=
  flags &&& ~~~((1 <<< target).toUInt8)

def restoreGainFlag (gain fought : UInt8) (target : Nat) : UInt8 :=
  if bitSet fought target then gain ||| (1 <<< target).toUInt8 else gain

@[simp] theorem faint_preserves_fought_flags (gain fought : UInt8) (target : Nat) :
    (clearGainFlag gain target, fought).2 = fought := rfl

@[simp] theorem revive_restores_fought_recipient (gain fought : UInt8) (target : Nat)
    (participated : bitSet fought target = true) :
    restoreGainFlag gain fought target = gain ||| (1 <<< target).toUInt8 := by
  simp [restoreGainFlag, participated]

private def applyProgressionEvents (state : State) (events : List Engine.Event) : State :=
  let state := events.foldl (fun state event => match event with
    | .switched .player target =>
        { state with
          gainExpFlags := state.gainExpFlags ||| (1 <<< target).toUInt8,
          foughtFlags := state.foughtFlags ||| (1 <<< target).toUInt8 }
    | .fainted .player =>
        { state with gainExpFlags := (clearGainFlag state.gainExpFlags
            state.engine.battle.player.activeIndex) }
    | .item .player itemEvents =>
        itemEvents.foldl (fun state event => match event with
          | .revived target => { state with gainExpFlags :=
              (restoreGainFlag state.gainExpFlags state.foughtFlags target) }
          | _ => state) state
    | _ => state) state
  if events.any (fun event => match event with | .fainted .enemy => true | _ => false) then
    awardEnemy state
  else state

private def lift (outer : State) : Engine.StepResult → StepResult
  | .transitioned engine events =>
      .transitioned (applyProgressionEvents { outer with engine } events) events
  | .invalidAction engine side => .invalidAction { outer with engine } side
  | .ineffectiveAction engine side => .ineffectiveAction { outer with engine } side
  | .capturePending engine ball events => .capturePending { outer with engine } ball events
  | .rngStuck engine events => .rngStuck { outer with engine } events
  | .divisionFreeze engine events => .divisionFreeze { outer with engine } events
  | .nestedMove engine side move events => .nestedMove { outer with engine } side move events
  | .mimicPending engine side slot next events =>
      .mimicPending { outer with engine } side slot next events
  | .runPending engine side action events => .runPending { outer with engine } side action events
  | .wildFaintRunPending engine events => .wildFaintRunPending { outer with engine } events
  | .disobediencePending engine machine next events =>
      .disobediencePending { outer with engine } machine next events
  | .inactive engine => .inactive { outer with engine }

def captureCapacityChecked : BattleMode → Bool
  | .oldMan => false
  | _ => true

def captureCapacityRejects (state : State) (action : Full.Action) : Bool :=
  match action with
  | .item request =>
      Items.disposition request.item == .capture &&
        captureCapacityChecked state.engine.battle.mode &&
        state.engine.battle.player.syncOutgoing.party.mons.size.toUInt8 == 6 &&
        state.box.size.toUInt8 == 20
  | _ => false

/-- The party-six/box-twenty check occurs before ball removal or action commit. -/
def step (state : State) (player enemy : Full.Action) : StepResult :=
  if captureCapacityRejects state player then .invalidAction state .player
  else lift state (Engine.step state.engine player enemy)

@[simp] theorem full_storage_ball_is_precommit_rejection (state : State)
    (request : Items.Request)
    (ball : Items.disposition request.item = .capture)
    (ordinary : state.engine.battle.mode ≠ .oldMan)
    (partyFull : state.engine.battle.player.syncOutgoing.party.mons.size.toUInt8 = 6)
    (boxFull : state.box.size.toUInt8 = 20) (enemy : Full.Action) :
    step state (.item request) enemy = .invalidAction state .player := by
  have ballBool : (Items.disposition request.item == Items.Disposition.capture) = true := by
    rw [ball]
    native_decide
  cases mode : state.engine.battle.mode <;>
    simp_all [step, captureCapacityRejects, captureCapacityChecked]

private def trainerItemId : TrainerAI.Item → UInt8
  | .potion => 0x14
  | .superPotion => 0x13
  | .hyperPotion => 0x12
  | .fullRestore => 0x10
  | .fullHeal => 0x34
  | .xAttack => 0x41
  | .xDefend => 0x42
  | .xSpeed => 0x43
  | .guardSpec => 0x37

/-- Execute a committed trainer-controller result against the player's already
selected action. AI inventory is synthetic and not player-bag state. -/
def executeTrainerPlan (player : Full.Action) : TrainerPlan → Option StepResult
  | .fight state slot => some (step state player (.fight slot))
  | .switch state target => some (step state player (.switch target))
  | .item state item =>
      let itemId := trainerItemId item
      let engine := { state.engine with
        enemyBag := [{ item := itemId, count := 1 }]
        trainerAiItem := true }
      let target := engine.battle.enemy.activeIndex
      some (step { state with engine } player (.item { item := itemId, partyTarget := target }))
  | .choosingMove _ _ | .invalidClass _ => none

def resumeNested (state : State) (who : Side) (move : MoveId) : StepResult :=
  lift state (Engine.resumeNested state.engine who move)

/-- Typed ordinary-player Mimic menu response. -/
def resumeMimic (state : State) (who : Side) (sourceSlot targetSlot : Fin 4)
    (nextAction : Option Full.Action) : StepResult :=
  lift state (Engine.resumeMimic state.engine who sourceSlot targetSlot nextAction)

/-- Supply one BattleRandom byte for integrated traded-Pokémon disobedience. -/
def resolveDisobedience (state : State) (machine : Disobedience.Machine)
    (nextEnemyAction : Option Full.Action) (raw : UInt8) : StepResult :=
  lift state (Engine.resumeDisobedience state.engine machine nextEnemyAction raw)

/-- Supply the non-link BattleRandom byte for a pending run attempt. A failed
attempt consumes the turn and resumes the opponent's already selected action. -/
def resolveRun (state : State) (runner : Side) (opponentAction : Full.Action)
    (random : UInt8) (ghost : Bool := false) : StepResult :=
  let playerSpeed := state.engine.battle.player.active.active.speed
  let enemySpeed := state.engine.battle.enemy.active.active.speed
  let result := Escape.attempt state.engine.battle.mode ghost playerSpeed enemySpeed
    state.engine.runAttempts random
  match result with
  | .prohibitedTrainer => .transitioned state []
  | .escaped attempts =>
      let engine := { state.engine with runAttempts := attempts }
      let terminal := Outcome.BattleTerminal.mk' .ordinaryRun engine.battle.mode .player 2
      let engine := { engine with battle := { engine.battle with phase := .ending terminal } }
      .transitioned { state with engine } [.terminal terminal]
  | .failed attempts =>
      let engine := { state.engine with runAttempts := attempts }
      lift { state with engine } (Engine.resumeFailedRun engine runner opponentAction)

/-- The post-faint run prompt reads party slot one Speed, not the active or
chosen replacement. Failure consumes an attempt but keeps the replacement
boundary open; no enemy action executes. -/
def wildFaintRunSpeed (state : State) : UInt16 :=
  let player := state.engine.battle.player
  (player.party.mons.getD 0 player.active.active).speed

@[simp] theorem wild_faint_speed_uses_slot_one (state : State) :
    wildFaintRunSpeed state =
      ((state.engine.battle.player.party.mons.getD 0
        state.engine.battle.player.active.active).speed) := rfl

def resolveWildFaintRun (state : State) (random : UInt8) : StepResult :=
  let playerSpeed := wildFaintRunSpeed state
  let enemySpeed := state.engine.battle.enemy.active.active.speed
  match Escape.attempt .wild false playerSpeed enemySpeed state.engine.runAttempts random with
  | .escaped attempts =>
      let engine := { state.engine with runAttempts := attempts }
      let terminal := Outcome.BattleTerminal.mk' .ordinaryRun .wild .player 2
      let engine := { engine with battle := { engine.battle with phase := .ending terminal } }
      .transitioned { state with engine } [.terminal terminal]
  | .failed attempts =>
      .transitioned { state with engine := { state.engine with runAttempts := attempts } } []
  | .prohibitedTrainer => .wildFaintRunPending state []

theorem failed_wild_faint_run_keeps_replacement (state : State) (random attempts : UInt8)
    (failed : Escape.attempt .wild false (wildFaintRunSpeed state)
      state.engine.battle.enemy.active.active.speed state.engine.runAttempts random =
        .failed attempts) :
    resolveWildFaintRun state random = .transitioned
      { state with engine := { state.engine with runAttempts := attempts } } [] := by
  unfold resolveWildFaintRun
  simp only
  rw [failed]

inductive SafariResult where
  | transitioned (state : State)
  | needsFactorRandom (state : State) (action : Safari.Action)
  | capturePending (state : State)
  | inactive (state : State)

private def safariTerminal (state : State) (cause : Outcome.TerminalCause) : State :=
  let terminal := Outcome.BattleTerminal.mk' cause .safari .player 0
  { state with engine := { state.engine with battle :=
    { state.engine.battle with phase := .ending terminal } } }

/-- Resolve bait/rock/run or enter the Safari Ball capture calculation. -/
def resolveSafari (state : State) (action : Safari.Action)
    (factorRaw escapeRaw : UInt8) : SafariResult :=
  match state.safari with
  | none => .inactive state
  | some safari =>
      let speed := state.engine.battle.enemy.active.active.speed
      match Safari.act safari action factorRaw escapeRaw speed with
      | .needsFactorRandom safari action =>
          .needsFactorRandom { state with safari := some safari } action
      | .capturePending safari => .capturePending { state with safari := some safari }
      | .enemyRan safari => .transitioned (safariTerminal { state with safari := some safari }
          .safariEnemyRan)
      | .ballsExhausted safari => .transitioned (safariTerminal { state with safari := some safari }
          .safariBallsExhausted)
      | .playerRan safari => .transitioned (safariTerminal { state with safari := some safari }
          .ordinaryRun)
      | .continue safari => .transitioned { state with safari := some safari }
      | .needsEscapeRandom safari => .transitioned { state with safari := some safari }

/-- Supply the hardware-Random bytes for a pending non-link ball throw. Rejected
Rand1 remains a request for another byte; successful capture enters the nested
pre-name storage phase. -/
def resolveCapture (state : State) (ball : Capture.Ball) (rand1 rand2 : UInt8)
    (ghost : Bool := false) : Capture.Result × State :=
  let enemy := state.engine.battle.enemy.active.active
  let playerParty := state.engine.battle.player.syncOutgoing.party.mons
  let input : Capture.Input :=
    { ball
      currentHp := enemy.hp
      maxHp := enemy.maxHp
      status := enemy.status
      catchRate := state.engine.battle.enemy.active.actualCatchRate
      species := enemy.species
      transformed := bitSet state.engine.battle.enemy.active.volatile.status3
        Wram.BattleStatus3.transformed
      trainerBattle := state.engine.battle.mode == .trainer || state.engine.battle.mode == .link
      ghostBattle := ghost
      oldManTutorial := state.engine.battle.mode == .oldMan
      partyCount := playerParty.size.toUInt8
      boxCount := state.box.size.toUInt8
      rand1
      rand2 }
  let result := Capture.attempt input
  match result with
  | .caught stored _ =>
      let pending := CaptureProtocol.begin playerParty.size.toUInt8 state.box.size.toUInt8
        (state.engine.battle.mode == .oldMan) enemy stored state.engine.playerId
      let state := { state with pendingCapture := some pending }
      if state.engine.battle.mode == .oldMan then
        let oldManScratch := state.oldManScratch.map OldMan.captureRestore
        let storage : CaptureProtocol.Storage :=
          { party := state.playerProgression
            partyNames := state.partyNames
            box := state.box.map (persistent state.engine.playerId)
            boxNames := state.boxNames
            owned := state.ownedSpecies }
        let storage := CaptureProtocol.finish storage pending .decline
        let terminal := Outcome.BattleTerminal.mk' .tutorialCapture state.engine.battle.mode .player 2
        let engine := { state.engine with battle := { state.engine.battle with phase := .ending terminal } }
        let state := { state with engine }
        let state := { state with pendingCapture := none }
        let state := { state with ownedSpecies := storage.owned }
        (result, { state with oldManScratch })
      else
        let storage : CaptureProtocol.Storage :=
          { party := state.playerProgression
            partyNames := state.partyNames
            box := state.box.map (persistent state.engine.playerId)
            boxNames := state.boxNames
            owned := state.ownedSpecies }
        let storage := CaptureProtocol.preStore storage pending
        let mons := storage.party.map Progression.PersistentMon.battle
        let player := state.engine.battle.player
        let activeMon := mons.getD player.activeIndex player.active.active
        let player := { player with party := { mons }, active := { player.active with active := activeMon } }
        let engine := { state.engine with battle := state.engine.battle.setSide .player player }
        let state := { state with engine := engine }
        let state := { state with playerProgression := storage.party }
        let state := { state with partyNames := storage.partyNames }
        let state := { state with box := storage.box.map Progression.PersistentMon.battle }
        let state := { state with boxNames := storage.boxNames }
        (result, { state with ownedSpecies := storage.owned })
  | _ => (result, state)

/-- Resolve a pending Safari Ball, then perform the post-action ball/escape
check only after a failed throw. -/
def resolveSafariCapture (state : State) (rand1 rand2 escapeRaw : UInt8) :
    Capture.Result × State :=
  match state.safari with
  | none => (.rejectedCapacity, state)
  | some safari =>
      let enemySide := state.engine.battle.enemy
      let active := { enemySide.active with actualCatchRate := safari.catchRate }
      let enemySide := { enemySide with active := active }
      let enemyMon := enemySide.active.active
      let engine := { state.engine with battle := state.engine.battle.setSide .enemy enemySide }
      let (result, state) := resolveCapture { state with engine } .safari rand1 rand2
      match result with
      | .caught _ _ => (result, state)
      | .needsRand1 => (result, state)
      | _ =>
          match Safari.afterCapture safari false escapeRaw enemyMon.speed with
          | .ballsExhausted safari =>
              (result, safariTerminal { state with safari := some safari } .safariBallsExhausted)
          | .enemyRan safari =>
              (result, safariTerminal { state with safari := some safari } .safariEnemyRan)
          | .continue safari => (result, { state with safari := some safari })
          | _ => (result, state)

/-- Resolve the mandatory ordinary-capture naming response, then atomically
install all party/box parallel arrays and witness the capture terminal. -/
def resolveCaptureName (state : State) (response : CaptureProtocol.NameResponse) : Option State :=
  match state.pendingCapture with
  | none => none
  | some pending =>
      let storage : CaptureProtocol.Storage :=
        { party := state.playerProgression
          partyNames := state.partyNames
          box := state.box.map (persistent state.engine.playerId)
          boxNames := state.boxNames
          owned := state.ownedSpecies }
      let storage := CaptureProtocol.finishName storage pending response
      let mons := storage.party.map Progression.PersistentMon.battle
      let player := state.engine.battle.player
      let activeMon := mons.getD player.activeIndex player.active.active
      let player := { player with party := { mons }, active := { player.active with active := activeMon } }
      let battle := state.engine.battle.setSide .player player
      let terminal := Outcome.BattleTerminal.mk' .capture battle.mode .player 2
      let engine := { state.engine with battle := { battle with phase := .ending terminal } }
      some { state with
        engine
        playerProgression := storage.party
        partyNames := storage.partyNames
        box := storage.box.map Progression.PersistentMon.battle
        boxNames := storage.boxNames
        ownedSpecies := storage.owned
        pendingCapture := none }

theorem resolve_capture_name_sets_result (state next : State)
    (response : CaptureProtocol.NameResponse)
    (resolved : resolveCaptureName state response = some next) :
    ∃ terminal, next.engine.battle.phase = .ending terminal ∧
      terminal.cause = .capture ∧ terminal.rawResult = 2 := by
  unfold resolveCaptureName at resolved
  split at resolved
  · contradiction
  · rename_i pending available
    simp only [Option.some.injEq] at resolved
    subst next
    refine ⟨Outcome.BattleTerminal.mk' .capture
      state.engine.battle.mode .player 2, rfl, rfl, rfl⟩

@[simp] theorem player_reset_legal (state : State) :
    teamLegal genDex .canonical state.playerReset.1 = true := state.playerReset.2

@[simp] theorem enemy_reset_legal (state : State) :
    teamLegal genDex .canonical state.enemyReset.1 = true := state.enemyReset.2

end Battle.Full.Environment
