/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Full.Engine
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
    repairedReset := player.repaired || enemy.repaired }

/-- Done only after explicit cleanup settlement. -/
def done (state : State) : Bool :=
  match state.engine.battle.phase with
  | .returned _ => true
  | _ => false

/-- No-op full-profile epilogue boundary. -/
def settle (state : State) : State :=
  match state.engine.battle.phase with
  | .ending terminal =>
      { state with engine := { state.engine with battle :=
        { state.engine.battle with phase := .returned ⟨terminal⟩ } } }
  | _ => state

private def currentParty (state : State) (who : Side) : Array MonState :=
  (state.engine.battle.side who).syncOutgoing.party.mons

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
  | inactive (state : State)

private def lift (outer : State) : Engine.StepResult → StepResult
  | .transitioned engine events => .transitioned { outer with engine } events
  | .invalidAction engine side => .invalidAction { outer with engine } side
  | .capturePending engine ball events => .capturePending { outer with engine } ball events
  | .rngStuck engine events => .rngStuck { outer with engine } events
  | .divisionFreeze engine events => .divisionFreeze { outer with engine } events
  | .nestedMove engine side move events => .nestedMove { outer with engine } side move events
  | .inactive engine => .inactive { outer with engine }

def step (state : State) (player enemy : Full.Action) : StepResult :=
  lift state (Engine.step state.engine player enemy)

def resumeNested (state : State) (who : Side) (move : MoveId) : StepResult :=
  lift state (Engine.resumeNested state.engine who move)

@[simp] theorem player_reset_legal (state : State) :
    teamLegal genDex .canonical state.playerReset.1 = true := state.playerReset.2

@[simp] theorem enemy_reset_legal (state : State) :
    teamLegal genDex .canonical state.enemyReset.1 = true := state.enemyReset.2

end Battle.Full.Environment
