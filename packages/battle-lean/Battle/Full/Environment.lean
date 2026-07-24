/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Full.Engine
import Battle.Full.Capture
import Battle.Full.Evolution
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
  box : Array MonState := #[]
  playerProgression : Array Progression.PersistentMon := #[]
  enemyProgression : Array Progression.PersistentMon := #[]
  canEvolveFlags : UInt8 := 0
  gainExpFlags : UInt8 := 1
  foughtFlags : UInt8 := 1
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

private def fallbackMon : MonState := (RL.DynamicGenerator.sampleMon Rng.seed0).1

private def persistent (owner : UInt16) (mon : MonState) : Progression.PersistentMon :=
  let rate := Progression.GrowthRate.ofId
    (Data.Progression.growthRates.getD mon.species.toNat 0)
  { battle := mon
    otId := owner
    experience := Progression.experienceAtLevel rate mon.level
    statExp := { hp := 0, attack := 0, defense := 0, speed := 0, special := 0 } }

/-- Reset from independent generator and battle streams. -/
def reset (generatorRng battleRng : Rng.LinkRng)
    (mode : BattleMode := .link) (playerBag enemyBag : Items.Bag := []) : State :=
  let player := RL.DynamicGenerator.sample generatorRng
  let enemy := RL.DynamicGenerator.sample player.rng
  let playerParty : Full.Party := { mons := player.team.1 }
  let enemyParty : Full.Party := { mons := enemy.team.1 }
  let playerSide := Full.SideState.fromParty playerParty fallbackMon
  let enemySide := Full.SideState.fromParty enemyParty fallbackMon
  let battle : Full.State :=
    { player := playerSide, enemy := enemySide, rng := battleRng, turn := 0,
      mode, phase := .battling }
  { engine := { battle, playerBag, enemyBag }
    playerReset := player.team
    enemyReset := enemy.team
    repairedReset := player.repaired || enemy.repaired
    box := #[]
    playerProgression := player.team.1.map (persistent 0)
    enemyProgression := enemy.team.1.map (persistent 0xffff) }

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

private def installLearning (state : State) (index : Nat) (machine : Learning.Machine) : State :=
  let rows := state.playerProgression.modify index (fun _ => machine.mon)
  let mons := rows.map Progression.PersistentMon.battle
  let player := state.engine.battle.player
  let activeMon := mons.getD player.activeIndex player.active.active
  let player := { player with party := { mons }, active := { player.active with active := activeMon } }
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

private def installEvolution (state : State) (machine : Evolution.Machine) : State :=
  let mons := machine.party.map Progression.PersistentMon.battle
  let player := state.engine.battle.player
  let activeMon := mons.getD player.activeIndex player.active.active
  let player := { player with party := { mons }, active := { player.active with active := activeMon } }
  let battle := state.engine.battle.setSide .player player
  { state with
    engine := { state.engine with battle }
    playerProgression := machine.party
    canEvolveFlags := 0 }

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

inductive StepResult where
  | transitioned (state : State) (events : List Engine.Event)
  | invalidAction (state : State) (side : Side)
  | capturePending (state : State) (ball : UInt8) (events : List Engine.Event)
  | rngStuck (state : State) (events : List Engine.Event)
  | divisionFreeze (state : State) (events : List Engine.Event)
  | nestedMove (state : State) (side : Side) (move : MoveId) (events : List Engine.Event)
  | runPending (state : State) (side : Side) (opponentAction : Full.Action)
      (events : List Engine.Event)
  | inactive (state : State)

private def countFlags (flags : UInt8) : UInt8 :=
  (List.range 8).foldl (fun count bit => if flags.toNat.testBit bit then count + 1 else count) 0

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
        baseExp := data.baseExp
        level := enemy.level }
    let recipients := countFlags state.gainExpFlags
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
        if state.gainExpFlags.toNat.testBit index && !mon.battle.fainted then
          let rate := Progression.GrowthRate.ofId
            (Data.Progression.growthRates.getD mon.battle.species.toNat 0)
          let result := Progression.award rate (Data.speciesData mon.battle.species)
            source context mon index
          let flags := if result.levelsGained != 0 then flags ||| (1 <<< index).toUInt8 else flags
          let requests := requests ++ result.requests.filterMap (fun request => match request with
            | .learnMove index move => some (index, move)
            | _ => none)
          (row.modify index (fun _ => result.mon), flags, requests)
        else (row, flags, requests)) initial
      let rows := awarded.1
      let mons := rows.map Progression.PersistentMon.battle
      let player := state.engine.battle.player
      let activeMon := mons.getD player.activeIndex player.active.active
      let player := { player with party := { mons }, active := { player.active with active := activeMon } }
      let battle := state.engine.battle.setSide .player player
      { state with
        engine := { state.engine with battle }
        playerProgression := rows
        canEvolveFlags := awarded.2.1
        pendingLearning := awarded.2.2 }

private def applyProgressionEvents (state : State) (events : List Engine.Event) : State :=
  let state := events.foldl (fun state event => match event with
    | .switched .player target =>
        { state with
          gainExpFlags := state.gainExpFlags ||| (1 <<< target).toUInt8,
          foughtFlags := state.foughtFlags ||| (1 <<< target).toUInt8 }
    | _ => state) state
  if events.any (fun event => match event with | .fainted .enemy => true | _ => false) then
    awardEnemy state
  else state

private def lift (outer : State) : Engine.StepResult → StepResult
  | .transitioned engine events =>
      .transitioned (applyProgressionEvents { outer with engine } events) events
  | .invalidAction engine side => .invalidAction { outer with engine } side
  | .capturePending engine ball events => .capturePending { outer with engine } ball events
  | .rngStuck engine events => .rngStuck { outer with engine } events
  | .divisionFreeze engine events => .divisionFreeze { outer with engine } events
  | .nestedMove engine side move events => .nestedMove { outer with engine } side move events
  | .runPending engine side action events => .runPending { outer with engine } side action events
  | .inactive engine => .inactive { outer with engine }

def step (state : State) (player enemy : Full.Action) : StepResult :=
  lift state (Engine.step state.engine player enemy)

def resumeNested (state : State) (who : Side) (move : MoveId) : StepResult :=
  lift state (Engine.resumeNested state.engine who move)

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

/-- Supply the hardware-Random bytes for a pending non-link ball throw. Rejected
Rand1 remains a request for another byte; successful capture appends to party or
box and enters the witnessed ending phase. -/
def resolveCapture (state : State) (ball : Capture.Ball) (rand1 rand2 : UInt8)
    (ghost : Bool := false) : Capture.Result × State :=
  let enemy := state.engine.battle.enemy.active.active
  let playerParty := state.engine.battle.player.syncOutgoing.party.mons
  let input : Capture.Input :=
    { ball
      currentHp := enemy.hp
      maxHp := enemy.maxHp
      status := enemy.status
      catchRate := enemy.catchRate
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
      let captured := { enemy with species := stored }
      let (engine, box) :=
        if state.engine.battle.mode == .oldMan then (state.engine, state.box)
        else if playerParty.size < Wram.partyLength then
          let player := state.engine.battle.player.syncOutgoing
          let player := { player with party := { mons := player.party.mons.push captured } }
          ({ state.engine with battle := state.engine.battle.setSide .player player }, state.box)
        else (state.engine, state.box.push captured)
      let cause := if state.engine.battle.mode == .oldMan then
        Outcome.TerminalCause.tutorialCapture else .capture
      let terminal := Outcome.BattleTerminal.mk' cause engine.battle.mode .player 2
      let engine := { engine with battle := { engine.battle with phase := .ending terminal } }
      (result, { state with engine, box })
  | _ => (result, state)

@[simp] theorem player_reset_legal (state : State) :
    teamLegal genDex .canonical state.playerReset.1 = true := state.playerReset.2

@[simp] theorem enemy_reset_legal (state : State) :
    teamLegal genDex .canonical state.enemyReset.1 = true := state.enemyReset.2

end Battle.Full.Environment
