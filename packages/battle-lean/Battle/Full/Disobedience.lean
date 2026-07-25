/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Full.State

/-!
# Traded-Pokémon disobedience

A byte-at-a-time state machine for `CheckForDisobedience`. Rejection loops are
represented by nonterminal phases rather than fuel. Consequently an infinite
provider can produce genuine reactive divergence without turning exhaustion
into a semantic result.
-/

namespace Battle.Full.Disobedience

inductive Text where
  | loafingAround | wontObey | turnedAway | ignoredOrders
  deriving Repr, DecidableEq, BEq

inductive Result where
  | obeyed (slot : UInt8) (move : MoveId)
  | alternate (slot : UInt8) (move : MoveId)
  | nap (status : UInt8)
  | selfDamage
  | idle (text : Text)
  deriving Repr, DecidableEq, BEq

structure Input where
  mode : BattleMode
  monOtId : UInt16
  playerId : UInt16
  badges : UInt8
  level : UInt8
  moves : Array MoveId
  pp : Array UInt8
  selectedSlot : UInt8
  selectedMove : MoveId
  /-- One past the largest selectable zero-based slot. -/
  moveCount : UInt8
  disabledMoveNumber : UInt8
  deriving Repr, DecidableEq

inductive Phase where
  | first (ceiling obedience : UInt8)
  | second (ceiling obedience : UInt8)
  | branch (obedience level : UInt8)
  | nap
  | idleText
  | chooseMove
  | done (result : Result)
  deriving Repr, DecidableEq

structure Machine where
  input : Input
  phase : Phase
  draws : List UInt8 := []
  deriving Repr, DecidableEq

private def swapNibbles (x : UInt8) : UInt8 := (x <<< 4) ||| (x >>> 4)

/-- Badge-dependent maximum obedient level. Earth uses the sentinel 101. -/
def obedienceLevel (badges : UInt8) : UInt8 :=
  if bitSet badges 7 then 101
  else if bitSet badges 5 then 70
  else if bitSet badges 3 then 50
  else if bitSet badges 1 then 30
  else 10

private def ceiling (level obedience : UInt8) : UInt8 :=
  let sum := level.toNat + obedience.toNat
  if sum > 255 then 255 else sum.toUInt8

private def selectedMove (input : Input) : MoveId :=
  input.moves.getD input.selectedSlot.toNat input.selectedMove

/-- Enter the routine. Link battles, locally owned Pokémon, and Pokémon at or
below the badge threshold return without consuming BattleRandom. -/
def start (input : Input) : Machine :=
  let obey := obedienceLevel input.badges
  let phase :=
    if input.mode == .link || input.monOtId == input.playerId || input.level ≤ obey then
      .done (.obeyed input.selectedSlot (selectedMove input))
    else .first (ceiling input.level obey) obey
  { input, phase }

private def ppTotal (pp : Array UInt8) : UInt8 :=
  (pp.getD 0 0 &&& 0x3f) + (pp.getD 1 0 &&& 0x3f) +
    (pp.getD 2 0 &&& 0x3f) + (pp.getD 3 0 &&& 0x3f)

def canChooseAlternate (input : Input) : Bool :=
  let selectedPp := input.pp.getD input.selectedSlot.toNat 0 &&& 0x3f
  input.moves.getD 1 0 != 0 && input.disabledMoveNumber == 0 &&
    input.selectedMove != 0xa5 && ppTotal input.pp != selectedPp

private def enterAlternate (machine : Machine) : Machine :=
  if canChooseAlternate machine.input then { machine with phase := .chooseMove }
  else { machine with phase := .idleText }

/-- Consume exactly one `BattleRandom` result. Every rejection remains in its
source phase. Candidate PP deliberately tests the full PP/PP-Up byte. -/
def feed (machine : Machine) (raw : UInt8) : Machine :=
  let machine := { machine with draws := machine.draws ++ [raw] }
  match machine.phase with
  | .done result => { machine with phase := .done result }
  | .first cap obey =>
      let sample := swapNibbles raw
      if sample ≥ cap then { machine with phase := .first cap obey }
      else if sample < obey then
        { machine with phase := .done (.obeyed machine.input.selectedSlot (selectedMove machine.input)) }
      else { machine with phase := .second cap obey }
  | .second cap obey =>
      if raw ≥ cap then { machine with phase := .second cap obey }
      else if raw < obey then enterAlternate machine
      else { machine with phase := .branch obey machine.input.level }
  | .branch obey level =>
      let delta := level - obey
      let sample := swapNibbles raw
      if sample < delta then { machine with phase := .nap }
      else if sample - delta ≥ delta then { machine with phase := .idleText }
      else { machine with phase := .done .selfDamage }
  | .nap =>
      let status := swapNibbles (raw + raw) &&& 0x07
      if status == 0 then { machine with phase := .nap }
      else { machine with phase := .done (.nap status) }
  | .idleText =>
      let text := match raw &&& 0x03 with
        | 0 => Text.loafingAround
        | 1 => .wontObey
        | 2 => .turnedAway
        | _ => .ignoredOrders
      { machine with phase := .done (.idle text) }
  | .chooseMove =>
      let slot := raw &&& 0x03
      let pp := machine.input.pp.getD slot.toNat 0
      if slot ≥ machine.input.moveCount || slot == machine.input.selectedSlot || pp == 0 then
        { machine with phase := .chooseMove }
      else
        let move := machine.input.moves.getD slot.toNat 0
        { machine with phase := .done (.alternate slot move) }

/-- Feed a finite observation prefix. A nonterminal result requests another
byte; it is not a manufactured failure. -/
def feedAll (machine : Machine) (bytes : List UInt8) : Machine :=
  bytes.foldl feed machine

theorem badge_obedience_thresholds :
    obedienceLevel 0 = 10 ∧ obedienceLevel 0x02 = 30 ∧
    obedienceLevel 0x08 = 50 ∧ obedienceLevel 0x20 = 70 ∧
    obedienceLevel 0x80 = 101 := by
  native_decide

@[simp] theorem level_at_threshold_obeys (input : Input)
    (level : input.level ≤ obedienceLevel input.badges) :
    ∃ result, (start input).phase = .done result := by
  refine ⟨.obeyed input.selectedSlot (selectedMove input), ?_⟩
  simp [start, level]

@[simp] theorem link_obeys_without_draws (input : Input) (h : input.mode = .link) :
    (start input).draws = [] ∧ ∃ result, (start input).phase = .done result := by
  have linkEq : (BattleMode.link == BattleMode.link) = true := by native_decide
  simp [start, h, linkEq]

@[simp] theorem owned_obeys_without_draws (input : Input) (h : input.monOtId = input.playerId) :
    (start input).draws = [] ∧ ∃ result, (start input).phase = .done result := by
  simp [start, h]

/-- Once terminal, further supplied bytes cannot alter the result. -/
theorem done_absorbing (input : Input) (result : Result) (draws : List UInt8) (raw : UInt8) :
    (feed { input, phase := .done result, draws } raw).phase = .done result := by
  rfl

private def testInput : Input :=
  { mode := .wild, monOtId := 0x1234, playerId := 0x5678, badges := 0,
    level := 20, moves := #[1, 2, 3, 0], pp := #[10, 10, 1, 0],
    selectedSlot := 0, selectedMove := 1, moveCount := 4, disabledMoveNumber := 0 }

/-- The first and second loops use swapped and unswapped bytes respectively;
then alternate-slot rejection uses `random & 3`. -/
theorem swapped_then_unswapped_alternate_witness :
    (feedAll (start testInput) [0xa0, 0x00, 0x01]).phase =
    .done (.alternate 1 2) := by native_decide

/-- Nap overwrites the whole status byte with the nonzero generated counter. -/
theorem nap_whole_status_witness :
    (feedAll (start testInput) [0xa0, 0x0a, 0x00, 0x08]).phase =
    .done (.nap 1) := by native_decide

/-- The middle branch of the swapped-byte subtraction inflicts self-damage. -/
theorem self_damage_witness :
    (feedAll (start testInput) [0xa0, 0x0a, 0xf0]).phase =
    .done .selfDamage := by native_decide

/-- Candidate selection checks the full PP byte: PP-Up bits make a zero-current-
PP alternate selectable when another slot keeps the total-PP guard open. -/
theorem pp_up_bits_make_zero_pp_selectable :
    let input := { testInput with pp := #[10, 0x40, 1, 0] }
    (feedAll (start input) [0xa0, 0x00, 0x01]).phase =
      .done (.alternate 1 2) := by native_decide

end Battle.Full.Disobedience
