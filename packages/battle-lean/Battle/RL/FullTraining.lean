/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Full.Environment
import Battle.RL.Training

/-!
# Full-party link training schema

This module projects a one-to-six-member full battle state into a stable
side-canonical integer tensor. Future RNG bytes are deliberately absent. The
profile admits moves, voluntary and forced switches, automatic no-action,
Struggle, and typed Mimic target requests; link forfeits are excluded from
training legality.
-/

namespace Battle.RL.FullTraining

open Battle Battle.Full


def profileVersion : String := "full-link-party-1to6-perfect-v2"
def schemaVersion : String := "full-link-party-state-v4"
def actionCount : Nat := 13

/-- State restrictions under which omitted inventory, capture, trainer, and
progression fields are mechanics-inert for the full-link training profile. The
future link RNG is intentionally treated as latent chance rather than policy
input. -/
def profileInvariant (state : Full.Environment.State) : Bool :=
  state.engine.battle.mode == .link &&
    state.engine.playerBag.isEmpty && state.engine.enemyBag.isEmpty &&
    state.pendingCapture.isNone && state.safari.isNone && state.oldManScratch.isNone &&
    state.pendingLearning.isEmpty && state.canEvolveFlags == 0 &&
    state.trainerActionsLeft.isNone

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

/-- Collision-free encoding for the pending continuation retained by typed
nested requests. Zero means no continuation; encodable link actions use their
stable action ID plus one. Item continuations are outside this profile. -/
def continuationId : Option Full.Action → Nat
  | none => 0
  | some action => (actionId action).map (· + 1) |>.getD 14

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

private def zeroMonFeatures : List Nat := List.replicate 22 0

private def effectiveness (moveType target1 target2 : UInt8) : Nat :=
  let first := TypeChart.matchup moveType target1 |>.toNat
  let second := if target1 == target2 then 10
    else TypeChart.matchup moveType target2 |>.toNat
  first * second

private def tacticalScore (move : MoveId) (target : MonState) : Nat :=
  let data := Data.moveData move
  data.power.toNat * effectiveness data.type target.type1 target.type2 *
    data.accuracy.toNat / 1000

private def bestTacticalScore (attacker target : MonState) : Nat := Id.run do
  let mut best := 0
  for slot in [:Wram.numMoves] do
    best := max best (tacticalScore (attacker.moves.getD slot 0) target)
  return best

private def appendMonFeatures (output : Array Nat) (mon : MonState) : Array Nat := Id.run do
  let mut output := output
  output := output.push mon.species.toNat
  output := output.push mon.hp.toNat
  output := output.push mon.boxLevel.toNat
  output := output.push mon.status.toNat
  output := output.push mon.type1.toNat
  output := output.push mon.type2.toNat
  output := output.push mon.catchRate.toNat
  output := output.push (mon.moves.getD 0 0).toNat
  output := output.push (mon.moves.getD 1 0).toNat
  output := output.push (mon.moves.getD 2 0).toNat
  output := output.push (mon.moves.getD 3 0).toNat
  output := output.push mon.dvs.toNat
  output := output.push mon.level.toNat
  output := output.push mon.maxHp.toNat
  output := output.push mon.attack.toNat
  output := output.push mon.defense.toNat
  output := output.push mon.speed.toNat
  output := output.push mon.special.toNat
  output := output.push (mon.pp.getD 0 0).toNat
  output := output.push (mon.pp.getD 1 0).toNat
  output := output.push (mon.pp.getD 2 0).toNat
  return output.push (mon.pp.getD 3 0).toNat

private def appendZeroMonFeatures (output : Array Nat) : Array Nat := Id.run do
  let mut output := output
  for _ in [:22] do
    output := output.push 0
  return output

private def appendActiveFeatures (output : Array Nat) (side : Battle.SideState) : Array Nat :=
    Id.run do
  let mut output := appendMonFeatures output side.active
  output := output.push side.unmodified.attack.toNat
  output := output.push side.unmodified.defense.toNat
  output := output.push side.unmodified.speed.toNat
  output := output.push side.unmodified.special.toNat
  output := output.push side.stages.attack.toNat
  output := output.push side.stages.defense.toNat
  output := output.push side.stages.speed.toNat
  output := output.push side.stages.special.toNat
  output := output.push side.stages.accuracy.toNat
  output := output.push side.stages.evasion.toNat
  output := output.push side.stages.padding0.toNat
  output := output.push side.stages.padding1.toNat
  output := output.push side.volatile.status1.toNat
  output := output.push side.volatile.status2.toNat
  output := output.push side.volatile.status3.toNat
  output := output.push side.volatile.numAttacksLeft.toNat
  output := output.push side.volatile.confusedCounter.toNat
  output := output.push side.volatile.toxicCounter.toNat
  output := output.push side.volatile.disabledMove.toNat
  output := output.push side.volatile.disabledMoveNumber.toNat
  output := output.push side.volatile.substituteHp.toNat
  output := output.push side.volatile.bideAccumulated.toNat
  output := output.push (boolNat side.volatile.minimized)
  output := output.push side.originalSpecies.toNat
  output := output.push side.partyPosition.toNat
  return output.push side.actualCatchRate.toNat

private def appendFullSideFeatures (output : Array Nat) (side : Full.SideState) : Array Nat :=
    Id.run do
  let mut output := output
  for index in [:Wram.partyLength] do
    output := match side.party.mons[index]? with
      | some mon => appendMonFeatures output mon
      | none => appendZeroMonFeatures output
  output := output.push side.activeIndex
  return appendActiveFeatures output side.active

/-- Static canonical move descriptors make type and effect relationships
learnable without asking a sub-million-parameter network to rediscover the ROM
move table from sparse terminal labels. These are deterministic projections of
state move IDs and the current target, not additional mechanics state. -/
private def appendMovePolicyFeatures (output : Array Nat) (attacker target : MonState) :
    Array Nat := Id.run do
  let mut output := output
  for slot in [:Wram.numMoves] do
    let move := attacker.moves.getD slot 0
    let data := Data.moveData move
    output := output.push data.effect.toNat
    output := output.push data.power.toNat
    output := output.push data.type.toNat
    output := output.push data.accuracy.toNat
    output := output.push (effectiveness data.type target.type1 target.type2)
    output := output.push (tacticalScore move target)
  return output

/-- For every legal party slot, expose both its best outgoing static matchup and
the opposing active mon's best incoming matchup. All six switches remain legal
and search-visible; these fields only remove an avoidable representation
learning bottleneck. -/
private def appendSwitchPolicyFeatures (output : Array Nat) (side opponent : Full.SideState) :
    Array Nat := Id.run do
  let mut output := output
  let attacker := opponent.active.active
  for index in [:Wram.partyLength] do
    match side.party.mons[index]? with
    | none =>
        output := output.push 0
        output := output.push 0
    | some candidate =>
        output := output.push (bestTacticalScore candidate attacker)
        output := output.push (bestTacticalScore attacker candidate)
  return output

private def appendSelectionFeatures (output : Array Nat)
    (scratch : Full.Selection.MoveScratch) : Array Nat :=
  output.push scratch.selectedMove.toNat |>.push scratch.loadedMove.toNat
    |>.push scratch.highlightedSlot.toNat |>.push scratch.effect.toNat
    |>.push scratch.power.toNat |>.push scratch.type.toNat
    |>.push scratch.accuracy.toNat |>.push scratch.pp.toNat

private def appendBcdFeatures (output : Array Nat) (value : Full.Money.Bcd3) : Array Nat :=
  output.push value.high.toNat |>.push value.middle.toNat |>.push value.low.toNat

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
`sourceSlot` records the slot whose move will be replaced and `continuation`
records the already-committed opposing action resumed after the menu response. -/
def featureVector (state : Full.Environment.State) (view : Side)
    (requestActor : Option Side := none) (sourceSlot : Nat := 0)
    (continuation : Option Full.Action := none) : Array Nat :=
  let own := sideState state view
  let opponent := sideState state view.other
  let battle := state.engine.battle
  let engine := state.engine
  Id.run do
    let mut output := Array.mkEmpty 492
    output := appendFullSideFeatures output own
    output := appendFullSideFeatures output opponent
    output := appendMovePolicyFeatures output own.active.active opponent.active.active
    output := appendMovePolicyFeatures output opponent.active.active own.active.active
    output := appendSwitchPolicyFeatures output own opponent
    output := appendSelectionFeatures output (selection state view)
    output := appendSelectionFeatures output (selection state view.other)
    output := appendBcdFeatures output engine.payDayMoney
    output := appendBcdFeatures output engine.playerMoney
    output := appendBcdFeatures output engine.trainerPrize
    for index in [:Wram.partyLength] do
      output := output.push (engine.playerOtIds.getD index 0).toNat
    output := output.push (modeId battle.mode)
    output := output.push battle.turn
    output := output.push (phaseId battle.phase)
    output := output.push (verdictId battle.phase)
    output := output.push (optionSide view engine.forcedReplacement)
    output := output.push (optionSide view engine.queuedReplacement)
    output := output.push (lastMove state view).toNat
    output := output.push (lastMove state view.other).toNat
    output := output.push engine.sharedDamage.toNat
    output := output.push (lockedDamage state view).toNat
    output := output.push (lockedDamage state view.other).toNat
    output := output.push engine.playerId.toNat
    output := output.push engine.badges.toNat
    output := output.push engine.runAttempts.toNat
    output := output.push (optionSide view engine.canceledAction)
    output := output.push engine.aiLayer2Encouragement.toNat
    output := output.push (boolNat engine.trainerAiItem)
    output := output.push (optionSide view requestActor)
    output := output.push sourceSlot
    output := output.push (continuationId continuation)
    output := output.push state.canEvolveFlags.toNat
    output := output.push state.gainExpFlags.toNat
    output := output.push state.foughtFlags.toNat
    output := output.push (boolNat state.hasExpAll)
    output := output.push state.pendingLearning.length
    output := output.push own.party.mons.size
    output := output.push opponent.party.mons.size
    for index in [:Wram.partyLength] do
      output := output.push (boolNat (decide (index < own.party.mons.size)))
    for index in [:Wram.partyLength] do
      output := output.push (boolNat (decide (index < opponent.party.mons.size)))
    return output

private def fnvOffset : UInt64 := 0xcbf29ce484222325
private def fnvPrime : UInt64 := 0x100000001b3

private def hashNat (hash : UInt64) (value : Nat) : UInt64 :=
  (List.range 8).foldl (fun hash (shift : Nat) =>
    let byte := (value.toUInt64 >>> (shift * 8).toUInt64).toUInt8
    (hash ^^^ byte.toUInt64) * fnvPrime) hash

def fingerprintFeatures (features : Array Nat) : UInt64 :=
  features.foldl hashNat fnvOffset

def fingerprint (state : Full.Environment.State) (view : Side)
    (requestActor : Option Side := none) (sourceSlot : Nat := 0)
    (continuation : Option Full.Action := none) : UInt64 :=
  fingerprintFeatures (featureVector state view requestActor sourceSlot continuation)

private def sampleState : Full.Environment.State :=
  Full.Environment.resetSized Wram.partyLength
    (Training.linkRng 1 1 Training.generatorStream)
    (Training.linkRng 1 1 Training.battleStream)

private def asymmetricSampleState : Full.Environment.State :=
  Full.Environment.resetSizedPair 1 2
    (Training.linkRng 2 1 Training.generatorStream)
    (Training.linkRng 2 1 Training.battleStream)

private def faintedReserveSampleState : Full.Environment.State :=
  let state := Full.Environment.resetSizedPair 2 2
    (Training.linkRng 3 1 Training.generatorStream)
    (Training.linkRng 3 1 Training.battleStream)
  let player := state.engine.battle.player
  let mons := player.party.mons.modify 1 fun mon => { mon with hp := 0 }
  { state with engine := { state.engine with battle :=
      { state.engine.battle with player := { player with party := { mons } } } } }

def featureCount : Nat := (featureVector sampleState .player).size

@[simp] theorem sampled_link_reset_satisfies_profile
    (player enemy : RL.DynamicGenerator.Sample) (battleRng : Rng.LinkRng) :
    profileInvariant
      (Full.Environment.linkResetFromSamples player enemy battleRng) = true := by
  have fields := Full.Environment.linkResetFromSamples_profile_fields
    player enemy battleRng
  have linkSelf : (BattleMode.link == BattleMode.link) = true := by decide
  simp [profileInvariant, fields, linkSelf]

#guard sampleState.playerReset.1.size == Wram.partyLength
#guard sampleState.enemyReset.1.size == Wram.partyLength
#guard actionCount == 13
#guard continuationId none == 0
#guard continuationId (some (.fight 0)) == 1
#guard continuationId (some .noAction) == 11
#guard featureVector sampleState .player (some .player) 0 none !=
  featureVector sampleState .player (some .player) 0 (some .noAction)
#guard zeroMonFeatures.length == 22
#guard (featureVector asymmetricSampleState .player).toList.extract 22 44 ==
  List.replicate 22 0
#guard (featureVector asymmetricSampleState .player).toList.drop 478 ==
  [1, 2, 1, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0]
#guard (featureVector faintedReserveSampleState .player).toList.extract 22 44 !=
  List.replicate 22 0
#guard ((featureVector faintedReserveSampleState .player).toList.drop 478).getD 3 0 == 1
#guard featureCount == 492

end Battle.RL.FullTraining
