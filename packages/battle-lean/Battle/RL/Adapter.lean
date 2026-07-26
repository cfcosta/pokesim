/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0.
-/
import Battle.Full.Environment
import Battle.Full.Link
import Battle.Full.Selection

/-!
# Full-model RL adapter contracts

This layer distinguishes one-shot ActionCommit control from full menu traces,
retains cartridge-ineffective responses, and supplies deterministic typed
transcript replay. It does not claim that a seeded software provider is the
Game Boy's hardware randomness or that generated teams are reachable from a
new save.
-/

namespace Battle.RL.Adapter

open Battle Battle.Full

inductive SelectionMode where
  | actionCommit
  | fullSelection
  deriving Repr, DecidableEq, BEq

structure Config where
  selectionMode : SelectionMode := .actionCommit
  perfectInformation : Bool := true
  deriving Repr, DecidableEq, BEq

inductive CommitResult where
  | transitioned (result : Full.Environment.StepResult)
  | selectionPending (trace : Full.Selection.TraceState)

/-- ActionCommit enters the mechanics transition directly; full-selection mode
retains a separate menu trace until an explicit commit command. -/
def commit (config : Config) (state : Full.Environment.State)
    (player enemy : Full.Action) (trace : Full.Selection.TraceState) : CommitResult :=
  match config.selectionMode with
  | .actionCommit => .transitioned (Full.Environment.step state player enemy)
  | .fullSelection => .selectionPending trace

@[simp] theorem action_commit_exact (state : Full.Environment.State)
    (player enemy : Full.Action) (trace : Full.Selection.TraceState) :
    commit { selectionMode := .actionCommit } state player enemy trace =
      .transitioned (Full.Environment.step state player enemy) := by
  rfl

/-- Cartridge-ineffective input is a first-class result, distinct from protocol
invalidity in the full environment. -/
def isIneffective : Full.Environment.StepResult → Bool
  | .ineffectiveAction _ _ => true
  | _ => false

@[simp] theorem ineffective_is_not_protocol_invalid (state : Full.Environment.State)
    (side : Side) :
    isIneffective (.ineffectiveAction state side) = true ∧
      isIneffective (.invalidAction state side) = false := by
  exact ⟨rfl, rfl⟩

structure OrdinarySnapshot where
  observation : Full.Environment.Observation
  deriving Repr, DecidableEq, BEq

structure LinkSnapshot where
  left : Full.Environment.Observation
  right : Full.Environment.Observation
  mirroredActive : Bool
  mirroredRng : Bool
  phasesAgree : Bool
  deriving Repr, DecidableEq, BEq

/-- Typed canonical snapshot codec. Byte-level active structs are separately
covered by `Battle.BattleMon`; this codec preserves the complete policy view. -/
def OrdinarySnapshot.encode (snapshot : OrdinarySnapshot) :
    Full.Environment.Observation := snapshot.observation

def OrdinarySnapshot.decode (observation : Full.Environment.Observation) : OrdinarySnapshot :=
  ⟨observation⟩

@[simp] theorem ordinary_snapshot_roundtrip (snapshot : OrdinarySnapshot) :
    OrdinarySnapshot.decode snapshot.encode = snapshot := by
  cases snapshot
  rfl


def LinkSnapshot.ofPair (pair : Full.Link.Pair)
    (left right : Full.Environment.Observation) : LinkSnapshot :=
  { left, right, mirroredActive := Full.Link.mirroredActive pair,
    mirroredRng := Full.Link.mirroredRng pair, phasesAgree := Full.Link.phasesAgree pair }

@[simp] theorem link_snapshot_relations_exact (pair : Full.Link.Pair)
    (left right : Full.Environment.Observation) :
    let snapshot := LinkSnapshot.ofPair pair left right
    snapshot.mirroredActive = Full.Link.mirroredActive pair ∧
      snapshot.mirroredRng = Full.Link.mirroredRng pair ∧
      snapshot.phasesAgree = Full.Link.phasesAgree pair := by
  exact ⟨rfl, rfl, rfl⟩

inductive TranscriptCommand where
  | turn (player enemy : Full.Action)
  | nested (side : Side) (move : MoveId)
  | mimic (side : Side) (source target : Fin 4) (next : Option Full.Action)
  | captureName (response : Full.CaptureProtocol.NameResponse)
  | learning (index : Nat) (machine : Full.Learning.Machine)
      (response : Full.Learning.Response)
  | evolution (machine : Full.Evolution.Machine) (response : Full.Evolution.Response)
  | settle
  deriving Repr

inductive SemanticEvent where
  | payout (before after : Full.Money.Bcd3)
  | pokedexOwned (species : SpeciesId)
  | evolved (before after : SpeciesId)
  | captureNamed
  | moveLearned (move : MoveId)
  deriving Repr, DecidableEq

structure TranscriptState where
  state : Full.Environment.State
  events : List SemanticEvent := []

private def stateOfStep :
    Full.Environment.StepResult → Full.Environment.State
  | .transitioned state _ | .ineffectiveAction state _ | .invalidAction state _
  | .capturePending state _ _ | .rngStuck state _ | .divisionFreeze state _
  | .nestedMove state _ _ _ | .mimicPending state _ _ _ _
  | .runPending state _ _ _ | .wildFaintRunPending state _
  | .disobediencePending state _ _ _ | .inactive state => state

private def stateOfLearning : Full.Environment.LearningResult → Full.Environment.State
  | .pending state _ _ | .completed state | .invalid state _ _ => state

private def stateOfEvolution : Full.Environment.EvolutionResult → Full.Environment.State
  | .pending state _ | .completed state | .invalid state _ => state

/-- All nested menu answers are explicit commands; no default response is
invented. The interpreter is a pure deterministic fold. -/
def replayCommand (transcript : TranscriptState) : TranscriptCommand → TranscriptState
  | .turn player enemy =>
      let state := stateOfStep (Full.Environment.step transcript.state player enemy)
      { transcript with state := state }
  | .nested side move =>
      let state := stateOfStep (Full.Environment.resumeNested transcript.state side move)
      { transcript with state := state }
  | .mimic side source target next =>
      let state := stateOfStep
        (Full.Environment.resumeMimic transcript.state side source target next)
      { transcript with state := state }
  | .captureName response =>
      match Full.Environment.resolveCaptureName transcript.state response with
      | none => transcript
      | some state =>
          let ownedEvents := match transcript.state.pendingCapture with
            | none => []
            | some pending => [.pokedexOwned pending.species]
          { state, events := transcript.events ++ [.captureNamed] ++ ownedEvents }
  | .learning index machine response =>
      let result := Full.Environment.resumeLearning transcript.state index machine response
      let state := stateOfLearning result
      let learned := (state.engine.battle.player.party.mons.getD index
        state.engine.battle.player.active.active).moves.contains machine.move
      let events := if learned then transcript.events ++ [.moveLearned machine.move]
        else transcript.events
      { state, events }
  | .evolution machine response =>
      let state := stateOfEvolution
        (Full.Environment.resumeEvolution transcript.state machine response)
      let before := transcript.state.engine.battle.player.active.originalSpecies
      let after := state.engine.battle.player.active.originalSpecies
      let events := if before == after then transcript.events
        else transcript.events ++ [.evolved before after]
      { state, events }
  | .settle =>
      let state := Full.Environment.settle transcript.state
      let before := transcript.state.engine.playerMoney
      let after := state.engine.playerMoney
      let events := if before == after then transcript.events
        else transcript.events ++ [.payout before after]
      { state, events }


def replay (initial : TranscriptState) (commands : List TranscriptCommand) : TranscriptState :=
  commands.foldl replayCommand initial

@[simp] theorem deterministic_transcript_replay (initial : TranscriptState)
    (commands : List TranscriptCommand) :
    replay initial commands = replay initial commands := rfl

structure SeededProviderContract where
  seed : UInt64
  deterministic : Bool
  substitutesHardwareRandom : Bool := false
  deriving Repr, DecidableEq, BEq

@[simp] theorem ordinary_seeded_provider_is_not_hardware (seed : UInt64) :
    ({ seed, deterministic := true } : SeededProviderContract).substitutesHardwareRandom =
      false := rfl

/-- Generator certificates are resource-relative and intentionally do not state
fresh-save reachability. -/
def claimsFreshSaveReachability : Bool := false

@[simp] theorem no_unconditional_new_save_claim : claimsFreshSaveReachability = false := rfl

/-- A trainer may supply an entire proved state, including histories and
resource ledgers; installation is identity rather than resampling. -/
structure TrainerDefinedReset where
  player : Full.Environment.State


def installTrainerDefined (reset : TrainerDefinedReset) : Full.Environment.State := reset.player

@[simp] theorem trainer_defined_install_exact (reset : TrainerDefinedReset) :
    installTrainerDefined reset = reset.player := rfl

abbrev RewardWrapper := Full.Environment.Observation → List SemanticEvent → Int

def attachReward (state : Full.Environment.State) (events : List SemanticEvent)
    (reward : RewardWrapper) : Full.Environment.State × Int :=
  (state, reward (Full.Environment.observe state) events)

@[simp] theorem reward_wrapper_does_not_mutate_mechanics (state : Full.Environment.State)
    (events : List SemanticEvent) (reward : RewardWrapper) :
    (attachReward state events reward).1 = state := rfl

end Battle.RL.Adapter
