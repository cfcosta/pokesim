/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.RL.SelfPlay

/-!
# Stable restricted-training protocol

This module is the native boundary used by the external actor–learner. It owns
versioned entropy expansion, side-canonical policy state, stable action IDs,
state fingerprints, and the small score-table policy used by the first complete
training smoke test. It does not expose future battle RNG bytes to policy code.
-/

namespace Battle.RL.Training

open Battle.RL

/-- Version carried by every shard emitted through this protocol. -/
def schemaVersion : String := "ordinary-link-1v1-state-v1"

/-- Counter-derived setup entropy used by production training workers. -/
def entropyVersion : String := "splitmix64-stock-link-v1"

/-! ## Stable action dictionary -/

/-- Dense policy IDs are stable even though the cartridge's link nybbles have a
three-value gap. -/
def actionId : Battle.Action → Nat
  | .fight slot => slot.val
  | .switch party => party.val + 4
  | .noAction => 10
  | .struggle => 11
  | .run => 12

def actionOfId : Nat → Option Battle.Action
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

@[simp] theorem action_dictionary_roundtrip (action : Battle.Action) :
    actionOfId (actionId action) = some action := by
  cases action with
  | fight slot =>
      rcases slot with ⟨value, bound⟩
      have cases : value = 0 ∨ value = 1 ∨ value = 2 ∨ value = 3 := by omega
      rcases cases with rfl | rfl | rfl | rfl <;> rfl
  | switch party =>
      rcases party with ⟨value, bound⟩
      have cases : value = 0 ∨ value = 1 ∨ value = 2 ∨ value = 3 ∨
          value = 4 ∨ value = 5 := by omega
      rcases cases with rfl | rfl | rfl | rfl | rfl | rfl <;> rfl
  | noAction | struggle | run => rfl

#guard (List.range 13).all fun id => (actionOfId id).isSome
#guard actionOfId 13 == none

/-! ## Production entropy -/

private def splitmix64 (input : UInt64) : UInt64 :=
  let z := input + 0x9e3779b97f4a7c15
  let z := (z ^^^ (z >>> 30)) * 0xbf58476d1ce4e5b9
  let z := (z ^^^ (z >>> 27)) * 0x94d049bb133111eb
  z ^^^ (z >>> 31)

private def entropyWord (root episode stream counter : UInt64) : UInt64 :=
  splitmix64 (root ^^^ splitmix64 episode ^^^
    splitmix64 (stream + 0x632be59bd9b4e019) ^^^ splitmix64 counter)

private def candidateByte (root episode stream : UInt64) (counter : Nat) : UInt8 :=
  (entropyWord root episode stream counter.toUInt64).toUInt8

/-- Stock cable setup accepts only bytes below the `$FD` preamble. We inspect a
large deterministic candidate window and pad only the unreachable-for-tested-
profiles shortage with legal zero bytes, keeping this total and replayable. -/
def setupBytes (root episode stream : UInt64) : Array UInt8 :=
  let accepted := (List.range 512).filterMap fun counter =>
    let candidate := candidateByte root episode stream counter
    if candidate < 0xfd then some candidate else none
  (accepted ++ List.replicate Wram.serialRnsLength 0).take Wram.serialRnsLength |>.toArray

/-- Construct a fresh cartridge-style link RNG block at cursor zero. -/
def linkRng (root episode stream : UInt64) : Rng.LinkRng :=
  { list := setupBytes root episode stream, index := 0 }

/-- Domains used for the four live episode streams. -/
def generatorStream : UInt64 := 1
def battleStream : UInt64 := 2
def playerPolicyStream : UInt64 := 3
def enemyPolicyStream : UInt64 := 4

#guard (setupBytes 1 2 3).size == Wram.serialRnsLength
#guard (setupBytes 1 2 3).all fun byte => byte < 0xfd
#guard (linkRng 1 2 3).list != (linkRng 1 2 4).list

/-! ## Side-canonical state and fingerprints -/

/-- Complete restricted mechanics state from one policy's perspective. The RNG
state is deliberately not a field: search and actors use a separately named
chance profile rather than seeing the episode's future stream. -/
structure PolicyState where
  own : SideState
  opponent : SideState
  mode : BattleMode
  turn : Nat
  terminalWitnessed : Bool
  done : Bool
  deriving Repr, DecidableEq, BEq

def policyState (observation : Environment.Observation) (side : Side) : PolicyState :=
  match side with
  | .player =>
      { own := observation.playerState, opponent := observation.enemyState,
        mode := observation.mode, turn := observation.turn,
        terminalWitnessed := observation.terminalWitnessed, done := observation.done }
  | .enemy =>
      { own := observation.enemyState, opponent := observation.playerState,
        mode := observation.mode, turn := observation.turn,
        terminalWitnessed := observation.terminalWitnessed, done := observation.done }

private def boolNat (value : Bool) : Nat := if value then 1 else 0

private def modeId : BattleMode → Nat
  | .wild => 0
  | .trainer => 1
  | .safari => 2
  | .oldMan => 3
  | .link => 4

private def monFeatures (mon : MonState) : List Nat :=
  [mon.species.toNat, mon.hp.toNat, mon.boxLevel.toNat, mon.status.toNat,
   mon.type1.toNat, mon.type2.toNat, mon.catchRate.toNat] ++
  (List.range Wram.numMoves).map (fun slot => (mon.moves.getD slot 0).toNat) ++
  [mon.dvs.toNat, mon.level.toNat, mon.maxHp.toNat, mon.attack.toNat,
   mon.defense.toNat, mon.speed.toNat, mon.special.toNat] ++
  (List.range Wram.numMoves).map (fun slot => (mon.pp.getD slot 0).toNat)

private def sideFeatures (side : SideState) : List Nat :=
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

/-- Stable dense integer projection. The order is own side, opponent side, mode,
turn, terminal-witnessed, and returned. Each side contains the active battle
struct, unmodified stats, all stages, all volatile counters, and identity bytes.
The schema version changes if this order changes. -/
def featureVector (state : PolicyState) : Array Nat :=
  (sideFeatures state.own ++ sideFeatures state.opponent ++
    [modeId state.mode, state.turn, boolNat state.terminalWitnessed,
     boolNat state.done]).toArray

private def fnvOffset : UInt64 := 0xcbf29ce484222325
private def fnvPrime : UInt64 := 0x100000001b3

private def hashNat (hash : UInt64) (value : Nat) : UInt64 :=
  (List.range 8).foldl (fun hash (shift : Nat) =>
    let byte := (value.toUInt64 >>> (shift * 8).toUInt64).toUInt8
    (hash ^^^ byte.toUInt64) * fnvPrime) hash

/-- Deterministic schema-local fingerprint. Replay manifests use SHA-256 around
whole shards; this compact native value catches state-coordinate mismatches. -/
def fingerprint (state : PolicyState) : UInt64 :=
  (featureVector state).foldl hashNat fnvOffset

#guard (featureVector (policyState (Environment.observe
  (Environment.reset (linkRng 1 1 generatorStream) (linkRng 1 1 battleStream)))
  .player)).size == 100

/-! ## Bootstrap policy -/

/-- One nonnegative score per Generation-I move ID. `1000` is neutral; the
external learner maps terminal-return means from `[-1,1]` into `[0,2000]`. -/
abbrev MoveScores := Array Nat

def neutralScores : MoveScores := Array.replicate 166 1000

private def movesFor (observation : Environment.Observation) : Side → Array MoveId
  | .player => observation.playerMoves
  | .enemy => observation.enemyMoves

private def moveForAction (observation : Environment.Observation) (side : Side) :
    Battle.Action → MoveId
  | .fight slot => (movesFor observation side).getD slot.val 0
  | .struggle => 165
  | _ => 0

private def scoreAction (scores : MoveScores) (observation : Environment.Observation)
    (side : Side) (action : Battle.Action) : Nat :=
  scores.getD (moveForAction observation side action).toNat 1000

private def bestAction (scores : MoveScores) (observation : Environment.Observation)
    (side : Side) (legal : Array Battle.Action) : Option Battle.Action :=
  legal.foldl (fun best action =>
    match best with
    | none => some action
    | some incumbent =>
        if scoreAction scores observation side action >
            scoreAction scores observation side incumbent then some action
        else some incumbent) none

/-- Epsilon-greedy score-table policy. `epsilonByte` is the exact count of raw
byte values selecting exploration. Policy entropy remains separate from battle
entropy. -/
def scoredPolicy (scores : MoveScores) (epsilonByte : Nat) : SelfPlay.Policy where
  choose := fun observation side legal rng =>
    let (gate, rng) := rng.next
    if gate.toNat < min 256 epsilonByte then
      let (index, rng) := rng.next
      if legal.isEmpty then (none, rng) else (legal[index.toNat % legal.size]?, rng)
    else
      (bestAction scores observation side legal, rng)

end Battle.RL.Training
