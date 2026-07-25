/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Full.Action
import Battle.TrainerAI
import Battle.TypeChart

/-!
# Complete trainer controller

All 47 class rows, move-scoring layer sets, action counts, action routines, exact
move-slot buckets, and rejection semantics. Action AI consumes caller-supplied
hardware `Random`; move selection consumes `BattleRandom` through a relation.
-/

namespace Battle.Full.TrainerController

inductive Routine where
  | generic | juggler | blackbelt | giovanni | cooltrainerM | cooltrainerF
  | bruno | brock | misty | surge | erika | koga | blaine | sabrina
  | rival2 | rival3 | lorelei | agatha | lance
  deriving Repr, DecidableEq, BEq

structure ClassRow where
  layers : List Nat
  initialActions : UInt8
  routine : Routine
  deriving Repr, DecidableEq, BEq

private def row (layers : List Nat) (count : Nat) (routine : Routine := .generic) : ClassRow :=
  { layers, initialActions := count.toUInt8, routine }

/-- Class IDs `$01..$2F`, in order. -/
def classRows : Array ClassRow := #[
  row [] 3, row [1] 3, row [1] 3, row [1,3] 3, row [1] 3, row [1] 3,
  row [1,2,3] 3, row [1,2] 3, row [1] 3, row [1] 3, row [1,3] 3,
  row [1] 3, row [1,2] 3 .juggler, row [1,3] 3, row [1,3] 3,
  row [] 3, row [1] 3, row [1,3] 3, row [1,2] 3, row [1,3] 3,
  row [1] 3 .juggler, row [1] 3, row [1] 3, row [1] 2 .blackbelt,
  row [1] 3, row [1,3] 3, row [1,2] 1, row [1,2] 3,
  row [1,3] 1 .giovanni, row [1] 3, row [1,3] 2 .cooltrainerM,
  row [1,3] 1 .cooltrainerF, row [1] 2 .bruno, row [1] 5 .brock,
  row [1,3] 1 .misty, row [1,3] 1 .surge, row [1,3] 1 .erika,
  row [1,3] 2 .koga, row [1,3] 2 .blaine, row [1,3] 1 .sabrina,
  row [1,2] 3, row [1,3] 1 .rival2, row [1,3] 1 .rival3,
  row [1,2,3] 2 .lorelei, row [1] 3, row [1] 2 .agatha,
  row [1,3] 1 .lance
]

#guard classRows.size == 47

/-- Canonical class lookup; out-of-domain remains explicit. -/
def classRow? (classId : UInt8) : Option ClassRow :=
  if classId.toNat ≥ 1 && classId.toNat ≤ classRows.size then
    classRows[classId.toNat - 1]?
  else none

/-- Exact initial slot buckets: 63,64,63,66 bytes. -/
def slotBucket (raw : UInt8) : Fin 4 :=
  if h : raw.toNat < 63 then ⟨0, by omega⟩
  else if h : raw.toNat < 127 then ⟨1, by omega⟩
  else if h : raw.toNat < 190 then ⟨2, by omega⟩
  else ⟨3, by omega⟩

/-- All 256 bytes partition into the cartridge's biased 63/64/63/66 slots. -/
theorem slot_bucket_cardinalities :
    ((List.range 256).filter fun raw => (slotBucket raw.toUInt8).val == 0).length = 63 ∧
    ((List.range 256).filter fun raw => (slotBucket raw.toUInt8).val == 1).length = 64 ∧
    ((List.range 256).filter fun raw => (slotBucket raw.toUInt8).val == 2).length = 63 ∧
    ((List.range 256).filter fun raw => (slotBucket raw.toUInt8).val == 3).length = 66 := by
  native_decide

/-- Finite successful move-selection traces. Blank/disabled buckets reject and
consume another `BattleRandom`; malformed all-reject states may diverge. -/
inductive SelectsMove (moves : Array MoveId) (disabled : MoveId) :
    Rng.LinkRng → Fin 4 → Rng.LinkRng → List UInt8 → Prop where
  | accept (rng : Rng.LinkRng)
      (nonempty : moves.getD (slotBucket rng.next.1).val 0 ≠ 0)
      (enabled : moves.getD (slotBucket rng.next.1).val 0 ≠ disabled) :
      SelectsMove moves disabled rng (slotBucket rng.next.1) rng.next.2 [rng.next.1]
  | reject (rng : Rng.LinkRng)
      (bad : moves.getD (slotBucket rng.next.1).val 0 = 0 ∨
        moves.getD (slotBucket rng.next.1).val 0 = disabled)
      {slot final trace}
      (tail : SelectsMove moves disabled rng.next.2 slot final trace) :
      SelectsMove moves disabled rng slot final (rng.next.1 :: trace)

inductive MovePhase where
  | choosing
  | selected (slot : Fin 4)
  deriving Repr, DecidableEq

structure MoveMachine where
  moves : Array MoveId
  disabled : MoveId
  scores : Array Nat
  rng : Rng.LinkRng
  phase : MovePhase := .choosing
  draws : List UInt8 := []
  deriving Repr, DecidableEq

private def minimumCandidateScore (machine : MoveMachine) : Nat :=
  (Array.range 4).foldl (fun minimum slot =>
    let move := machine.moves.getD slot 0
    if move == 0 || move == machine.disabled then minimum
    else min minimum (machine.scores.getD slot 0x50)) 0x50

/-- One BattleRandom draw in the minimum-score rejection loop. -/
def feedMove (machine : MoveMachine) : MoveMachine :=
  match machine.phase with
  | .selected _ => machine
  | .choosing =>
      let (raw, rng) := machine.rng.next
      let slot := slotBucket raw
      let move := machine.moves.getD slot.val 0
      let accepted := move != 0 && move != machine.disabled &&
        machine.scores.getD slot.val 0x50 == minimumCandidateScore machine
      let machine := { machine with rng := rng }
      let machine := { machine with draws := machine.draws ++ [raw] }
      { machine with phase := if accepted then .selected slot else .choosing }

/-- `AIGetTypeEffectiveness`: first table row matching either defender type,
with the cartridge's hexadecimal `$10` neutral initializer. -/
def aiTypeEffectiveness (moveType targetType1 targetType2 : UInt8) : UInt8 :=
  match TypeChart.typeEffects.find? (fun entry =>
    entry.1 == moveType &&
      (entry.2.1 == targetType1 || entry.2.1 == targetType2)) with
  | some entry => entry.2.2
  | none => 0x10

private def hasBetterAlternative (moves : List MoveId) (currentType : UInt8) : Bool :=
  match moves with
  | [] => false
  | move :: rest =>
      if move == 0 then false
      else
        let data := Data.moveData move
        data.effect == Data.Effect.superFang ||
          data.effect == Data.Effect.specialDamage ||
          data.effect == Data.Effect.fly ||
          (data.type != currentType && data.power != 0) ||
          hasBetterAlternative rest currentType

structure ScoreInput where
  moves : Array MoveId
  targetStatus : UInt8
  layer2Encouragement : UInt8
  superEffective : Array Bool
  notEffective : Array Bool
  disabledSlot : Option (Fin 4) := none
  deriving Repr, DecidableEq, BEq

/-- Build exact layer-3 observations from active target types and the contiguous
move prefix. -/
def ScoreInput.fromBattle (moves : Array MoveId) (targetStatus : UInt8)
    (layer2Encouragement : UInt8) (targetType1 targetType2 : UInt8)
    (disabledSlot : Option (Fin 4) := none) : ScoreInput :=
  let effectiveness := moves.map fun move =>
    aiTypeEffectiveness (Data.moveData move).type targetType1 targetType2
  { moves, targetStatus, layer2Encouragement
    superEffective := effectiveness.map fun value => value > 0x10
    notEffective := moves.mapIdx fun slot move =>
      effectiveness.getD slot 0x10 < 0x10 &&
        hasBetterAlternative moves.toList (Data.moveData move).type
    disabledSlot }

private def layer1 (input : ScoreInput) (slot score : Nat) : Nat :=
  let move := Data.moveData (input.moves.getD slot 0)
  let statusEffect := [0x01, 0x20, 0x42, 0x43].contains move.effect.toNat
  if input.targetStatus != 0 && move.power == 0 && statusEffect then score + 5 else score

private def layer2 (input : ScoreInput) (slot score : Nat) : Nat :=
  let effect := (Data.moveData (input.moves.getD slot 0)).effect.toNat
  if input.layer2Encouragement == 1 &&
      ((0x0A ≤ effect && effect ≤ 0x19) || (0x32 ≤ effect && effect ≤ 0x41)) then
    score - 1 else score

private def layer3 (input : ScoreInput) (slot score : Nat) : Nat :=
  if input.superEffective.getD slot false then score - 1
  else if input.notEffective.getD slot false then score + 1 else score

/-- Apply a class's layers in table order. Disabled score is overwritten with
`$50` after all layers. -/
def scoreMoves (trainerClass : ClassRow) (input : ScoreInput) : Array Nat :=
  let initial := #[10, 10, 10, 10]
  let scored := trainerClass.layers.foldl (fun scores layer =>
    (Array.range 4).foldl (fun scores slot => scores.modify slot fun score =>
      match layer with
      | 1 => layer1 input slot score
      | 2 => layer2 input slot score
      | _ => layer3 input slot score) scores) initial
  match input.disabledSlot with
  | none => scored
  | some slot => scored.modify slot.val (fun _ => 0x50)

structure ActionState where
  remaining : UInt8
  deriving Repr, DecidableEq, BEq

inductive ActionDecision where
  | normal
  | item (item : TrainerAI.Item)
  | switch
  deriving Repr, DecidableEq, BEq

private def below (context : TrainerAI.Context) (divisor : Nat) : Bool :=
  TrainerAI.hpBelowFraction context divisor

/-- Exact per-class action routine after the direct Random byte. -/
def decideAction (routine : Routine) (random : UInt8)
    (context : TrainerAI.Context) (statused : Bool) : ActionDecision :=
  let gate (threshold : UInt8) := random < threshold
  match routine with
  | .generic => .normal
  | .juggler => if gate 64 && context.hasSwitchReserve then .switch else .normal
  | .blackbelt => if gate 32 then .item .xAttack else .normal
  | .giovanni => if gate 64 then .item .guardSpec else .normal
  | .cooltrainerM | .koga => if gate 64 then .item .xAttack else .normal
  | .cooltrainerF =>
      if below context 10 then .item .hyperPotion
      else if below context 5 && context.hasSwitchReserve then .switch else .normal
  | .bruno | .misty => if gate 64 then .item .xDefend else .normal
  | .brock => if statused then .item .fullHeal else .normal
  | .surge => if gate 64 then .item .xSpeed else .normal
  | .erika => if gate 128 && below context 10 then .item .superPotion else .normal
  | .blaine => if gate 64 then .item .superPotion else .normal
  | .sabrina => if gate 64 && below context 10 then .item .hyperPotion else .normal
  | .rival2 => if gate 32 && below context 5 then .item .potion else .normal
  | .rival3 => if gate 32 && below context 5 then .item .fullRestore else .normal
  | .lorelei => if gate 128 && below context 5 then .item .superPotion else .normal
  | .agatha =>
      if gate 20 && context.hasSwitchReserve then .switch
      else if gate 128 && below context 4 then .item .superPotion else .normal
  | .lance => if gate 128 && below context 5 then .item .hyperPotion else .normal

/-- Successful item/switch actions decrement the action count; normal/failure
leaves it unchanged. -/
def commitDecision (state : ActionState) (decision : ActionDecision) : ActionState :=
  match decision with
  | .normal => state
  | _ => { remaining := state.remaining - 1 }

/-! ## Controller theorems -/

/-- All class IDs 1..47 decode. -/
theorem class_table_total (classId : UInt8)
    (low : 1 ≤ classId.toNat) (high : classId.toNat ≤ 47) :
    (classRow? classId).isSome = true := by
  have checked : (List.range 47).all (fun offset =>
      (classRow? (offset + 1).toUInt8).isSome) = true := by native_decide
  have atClass := (List.all_eq_true.mp checked) (classId.toNat - 1)
    (List.mem_range.mpr (by omega))
  have round : (classId.toNat - 1 + 1).toUInt8 = classId := by
    apply UInt8.toNat.inj
    simp
    omega
  simpa only [round] using atClass

/-- An unlisted neutral pair retains hexadecimal 16 rather than the damage
system's decimal 10 neutral constant. -/
theorem ai_neutral_constant_mismatch :
    aiTypeEffectiveness TypeChart.normal TypeChart.normal TypeChart.normal = 0x10 ∧
      aiTypeEffectiveness TypeChart.normal TypeChart.normal TypeChart.normal ≠
        TypeChart.effective := by
  native_decide

/-- The scan stops at the first matching row across either defender type. Poison
against Bug/Poison therefore sees the earlier Poison resistance before the later
Bug weakness. -/
theorem ai_first_matching_defender_type :
    aiTypeEffectiveness TypeChart.poison TypeChart.bug TypeChart.poison =
      TypeChart.notVeryEffective := by
  native_decide

/-- CooltrainerF action decision is independent of its consumed random byte. -/
theorem cooltrainerF_random_dead (first second : UInt8)
    (context : TrainerAI.Context) (statused : Bool) :
    decideAction .cooltrainerF first context statused =
      decideAction .cooltrainerF second context statused := by
  rfl

#guard slotBucket 62 == 0
#guard slotBucket 63 == 1
#guard slotBucket 126 == 1
#guard slotBucket 127 == 2
#guard slotBucket 190 == 3

end Battle.Full.TrainerController
