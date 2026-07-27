/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Full.Environment
import Battle.RL.Training

/-!
# Full-party link training schema

This module projects the complete six-member full battle state into a stable
side-canonical integer tensor. Future RNG bytes are deliberately absent. The
profile admits moves, voluntary and forced switches, automatic no-action,
Struggle, and typed Mimic target requests; link forfeits are excluded from
training legality.
-/

namespace Battle.RL.FullTraining

open Battle Battle.Full


def profileVersion : String := "full-link-6v6-perfect-v1"
def schemaVersion : String := "full-link-6v6-state-v1"
def actionCount : Nat := 13

/-! ## Action dictionary -/

def actionId : Full.Action → Option Nat
  | .fight slot => some slot.val
  | .switch target => some (target.val + 4)
  | .noAction => some 10
  | .struggle => some 11
  | .run => some 12
  | .item _ => none

def actionOfId : Nat → Option Full.Action
  | 0 => some (.fight 0)
  | 1 => some (.fight 1)
  | 2 => some (.fight 2)
  | 3 => some (.fight 3)
  | 4 => some (.switch 0)
  | 5 => some (.switch 1)
  | 6 => some (.switch 2)
  | 7 => some (.switch 3)
  | 8 => some (.switch 4)
  | 9 => some (.switch 5)
  | 10 => some .noAction
  | 11 => some .struggle
  | 12 => some .run
  | _ => none

@[simp] theorem action_roundtrip (action : Full.Action) (id : Nat)
    (encoded : actionId action = some id) : actionOfId id = some action := by
  cases action with
  | fight slot =>
      rcases slot with ⟨value, bound⟩
      have cases : value = 0 ∨ value = 1 ∨ value = 2 ∨ value = 3 := by omega
      rcases cases with rfl | rfl | rfl | rfl <;>
        simp [actionId] at encoded <;> subst id <;> rfl
  | switch target =>
      rcases target with ⟨value, bound⟩
      have cases : value = 0 ∨ value = 1 ∨ value = 2 ∨ value = 3 ∨
          value = 4 ∨ value = 5 := by omega
      rcases cases with rfl | rfl | rfl | rfl | rfl | rfl <;>
        simp [actionId] at encoded <;> subst id <;> rfl
  | item request => simp [actionId] at encoded
  | struggle | noAction | run =>
      simp [actionId] at encoded <;> subst id <;> rfl

/-! ## Side-canonical full mechanics state -/

private def boolNat (value : Bool) : Nat := if value then 1 else 0

private def sideRelative (view value : Side) : Nat := if view == value then 1 else 2

private def optionSide (view : Side) : Option Side → Nat
  | none => 0
  | some value => sideRelative view value

private def modeId : BattleMode → Nat
  | .wild => 0
  | .trainer => 1
  | .safari => 2
  | .oldMan => 3
  | .link => 4

private def phaseId : Outcome.EpisodePhase → Nat
  | .battling => 0
  | .ending _ => 1
  | .returned _ => 2

private def verdictId : Outcome.EpisodePhase → Nat
  | .ending terminal | .returned ⟨terminal⟩ =>
      match terminal.verdict with
      | none => 0
      | some .win => 1
      | some .loss => 2
      | some .draw => 3
  | .battling => 0

private def monFeatures (mon : MonState) : List Nat :=
  [mon.species.toNat, mon.hp.toNat, mon.boxLevel.toNat, mon.status.toNat,
   mon.type1.toNat, mon.type2.toNat, mon.catchRate.toNat] ++
  (List.range Wram.numMoves).map (fun slot => (mon.moves.getD slot 0).toNat) ++
  [mon.dvs.toNat, mon.level.toNat, mon.maxHp.toNat, mon.attack.toNat,
   mon.defense.toNat, mon.speed.toNat, mon.special.toNat] ++
  (List.range Wram.numMoves).map (fun slot => (mon.pp.getD slot 0).toNat)

private def activeFeatures (side : Battle.SideState) : List Nat :=
  monFeatures side.active ++
  [side.unmodified.attack.toNat, side.unmodified.defense.toNat,
   side.unmodified.speed.toNat, side.unmodified.special.toNat,
   side.stages.attack.toNat, side.stages.defense.toNat, side.stages.speed.toNat,
   side.stages.special.toNat, side.stages.accuracy.toNat, side.stages.evasion.toNat,
   side.stages.padding0.toNat, side.stages.padding1.toNat,
   side.volatile.status1.toNat, side.volatile.status2.toNat,
   side.volatile.status3.toNat, side.volatile.numAttacksLeft.toNat,
   side.volatile.confusedCounter.toNat, side.volatile.toxicCounter.toNat,
   side.volatile.disabledMove.toNat, side.volatile.disabledMoveNumber.toNat,
   side.volatile.substituteHp.toNat, side.volatile.bideAccumulated.toNat,
   boolNat side.volatile.minimized, side.originalSpecies.toNat,
   side.partyPosition.toNat, side.actualCatchRate.toNat]

private def fullSideFeatures (side : Full.SideState) : List Nat :=
  let fallback := side.active.active
  ((List.range Wram.partyLength).flatMap fun index =>
    monFeatures (side.party.mons.getD index fallback)) ++
  [side.activeIndex] ++ activeFeatures side.active

private def selectionFeatures (scratch : Full.Selection.MoveScratch) : List Nat :=
  [scratch.selectedMove.toNat, scratch.loadedMove.toNat,
   scratch.highlightedSlot.toNat, scratch.effect.toNat, scratch.power.toNat,
   scratch.type.toNat, scratch.accuracy.toNat, scratch.pp.toNat]

private def bcdFeatures (value : Full.Money.Bcd3) : List Nat :=
  [value.high.toNat, value.middle.toNat, value.low.toNat]

private def sideState (state : Full.Environment.State) : Side → Full.SideState
  | .player => state.engine.battle.player
  | .enemy => state.engine.battle.enemy

private def lastMove (state : Full.Environment.State) : Side → MoveId
  | .player => state.engine.playerLastMove
  | .enemy => state.engine.enemyLastMove

private def lockedDamage (state : Full.Environment.State) : Side → UInt16
  | .player => state.engine.playerLockedDamage
  | .enemy => state.engine.enemyLockedDamage

private def selection (state : Full.Environment.State) : Side → Full.Selection.MoveScratch
  | .player => state.engine.playerSelection
  | .enemy => state.engine.enemySelection

/-- `requestActor` is present only for a typed one-side Mimic target request.
`sourceSlot` records the slot whose move will be replaced. -/
def featureVector (state : Full.Environment.State) (view : Side)
    (requestActor : Option Side := none) (sourceSlot : Nat := 0) : Array Nat :=
  let own := sideState state view
  let opponent := sideState state view.other
  let battle := state.engine.battle
  let engine := state.engine
  let global :=
    [modeId battle.mode, battle.turn, phaseId battle.phase, verdictId battle.phase,
     optionSide view engine.forcedReplacement,
     optionSide view engine.queuedReplacement,
     (lastMove state view).toNat, (lastMove state view.other).toNat,
     engine.sharedDamage.toNat, (lockedDamage state view).toNat,
     (lockedDamage state view.other).toNat,
     engine.playerId.toNat, engine.badges.toNat, engine.runAttempts.toNat,
     optionSide view engine.canceledAction, engine.aiLayer2Encouragement.toNat,
     boolNat engine.trainerAiItem,
     optionSide view requestActor, sourceSlot,
     state.canEvolveFlags.toNat, state.gainExpFlags.toNat,
     state.foughtFlags.toNat, boolNat state.hasExpAll,
     state.pendingLearning.length]
  let otIds := (List.range Wram.partyLength).map fun index =>
    (engine.playerOtIds.getD index 0).toNat
  (fullSideFeatures own ++ fullSideFeatures opponent ++
    selectionFeatures (selection state view) ++
    selectionFeatures (selection state view.other) ++
    bcdFeatures engine.payDayMoney ++ bcdFeatures engine.playerMoney ++
    bcdFeatures engine.trainerPrize ++ otIds ++ global).toArray

private def fnvOffset : UInt64 := 0xcbf29ce484222325
private def fnvPrime : UInt64 := 0x100000001b3

private def hashNat (hash : UInt64) (value : Nat) : UInt64 :=
  (List.range 8).foldl (fun hash (shift : Nat) =>
    let byte := (value.toUInt64 >>> (shift * 8).toUInt64).toUInt8
    (hash ^^^ byte.toUInt64) * fnvPrime) hash

def fingerprint (state : Full.Environment.State) (view : Side)
    (requestActor : Option Side := none) (sourceSlot : Nat := 0) : UInt64 :=
  (featureVector state view requestActor sourceSlot).foldl hashNat fnvOffset

private def sampleState : Full.Environment.State :=
  Full.Environment.resetSized Wram.partyLength
    (Training.linkRng 1 1 Training.generatorStream)
    (Training.linkRng 1 1 Training.battleStream)

def featureCount : Nat := (featureVector sampleState .player).size

#guard sampleState.playerReset.1.size == Wram.partyLength
#guard sampleState.enemyReset.1.size == Wram.partyLength
#guard actionCount == 13
#guard featureCount == 417

end Battle.RL.FullTraining
