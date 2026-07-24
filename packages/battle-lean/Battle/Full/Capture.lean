/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Full.State

/-!
# Generation-I capture calculation

Exact integer pipeline after caller-supplied `Random` bytes. Rejected Rand1 is a
request for another hardware-random sample, not a failed throw. Master Ball still
observes Rand1 before unconditional capture. Equality-only party/box capacity,
status bonuses, transformed-as-Ditto storage, and shake messages are retained.
-/

namespace Battle.Full.Capture

inductive Ball where
  | master | ultra | great | poke | safari
  deriving Repr, DecidableEq, BEq

/-- Decode ordinary ball IDs. Safari Ball is `$08`. -/
def Ball.ofItem (item : UInt8) : Option Ball :=
  match item.toNat with
  | 1 => some .master
  | 2 => some .ultra
  | 3 => some .great
  | 4 => some .poke
  | 8 => some .safari
  | _ => none

private def rand1Limit : Ball → Nat
  | .master | .poke => 255
  | .great => 200
  | .ultra | .safari => 150

/-- Rand1 acceptance is inclusive at 200/150. -/
def rand1Accepted (ball : Ball) (raw : UInt8) : Bool := raw.toNat ≤ rand1Limit ball

private def statusBonus1 (status : UInt8) : Nat :=
  if status == 0 then 0
  else if status &&& ((1 <<< Wram.Status.frz).toUInt8 ||| Wram.Status.slpMask) != 0
    then 25 else 12

private def statusBonus2 (status : UInt8) : Nat :=
  if status == 0 then 0
  else if status &&& ((1 <<< Wram.Status.frz).toUInt8 ||| Wram.Status.slpMask) != 0
    then 10 else 5

private def ballFactor : Ball → Nat
  | .great => 8
  | _ => 12

private def ballFactor2 : Ball → Nat
  | .poke | .master => 255
  | .great => 200
  | .ultra | .safari => 150

structure Input where
  ball : Ball
  currentHp : UInt16
  maxHp : UInt16
  status : UInt8
  catchRate : UInt8
  species : SpeciesId
  transformed : Bool := false
  trainerBattle : Bool := false
  ghostBattle : Bool := false
  oldManTutorial : Bool := false
  partyCount : UInt8 := 1
  boxCount : UInt8 := 0
  rand1 : UInt8
  rand2 : UInt8
  deriving Repr, DecidableEq, BEq

inductive Result where
  | rejectedTrainer
  | rejectedGhost
  | rejectedCapacity
  | needsRand1
  | caught (storedSpecies : SpeciesId) (randomDraws : Nat)
  | failed (shakes : Nat) (randomDraws : Nat)
  deriving Repr, DecidableEq, BEq

private def shakeCount (x : Nat) (input : Input) : Nat :=
  let y := input.catchRate.toNat * 100 / ballFactor2 input.ball
  let z := x * y / 255 + statusBonus2 input.status
  if z < 10 then 0 else if z < 30 then 1 else if z < 70 then 2 else 3

/-- Execute one accepted/rejected Rand1 attempt and optional Rand2. -/
def attempt (input : Input) : Result :=
  if input.trainerBattle then .rejectedTrainer
  else if input.partyCount == 6 && input.boxCount == 20 && !input.oldManTutorial then
    .rejectedCapacity
  else if input.ghostBattle then .rejectedGhost
  else if input.oldManTutorial then .caught input.species 0
  else if !rand1Accepted input.ball input.rand1 then .needsRand1
  else
    let stored := if input.transformed then (76 : SpeciesId) else input.species
    if input.ball == .master then .caught stored 1
    else
      let bonus := statusBonus1 input.status
      if input.rand1.toNat < bonus then .caught stored 1
      else
        let adjusted := input.rand1.toNat - bonus
        let hpDiv4 := max 1 (input.currentHp.toNat / 4)
        let w := (input.maxHp.toNat * 255 / ballFactor input.ball) / hpDiv4
        let x := min w 255
        if adjusted ≤ input.catchRate.toNat && (w > 255 || input.rand2.toNat ≤ x) then
          .caught stored (if w > 255 then 1 else 2)
        else .failed (shakeCount x input) (if adjusted > input.catchRate.toNat || w > 255 then 1 else 2)

/-! ## Capture theorems -/

/-- Master Ball still requires one Rand1 observation before success. -/
theorem master_consumes_rand1 (input : Input)
    (master : input.ball = .master)
    (eligibleTrainer : input.trainerBattle = false)
    (eligibleGhost : input.ghostBattle = false)
    (partyNotFull : input.partyCount ≠ 6)
    (notTutorial : input.oldManTutorial = false) :
    attempt input = .caught (if input.transformed then 76 else input.species) 1 := by
  have rawBound : input.rand1.toNat ≤ 255 := by
    have := UInt8.toNat_lt input.rand1
    omega
  have masterEq : (Ball.master == Ball.master) = true := by native_decide
  simp [attempt, master, eligibleTrainer, eligibleGhost, partyNotFull, notTutorial,
    rand1Accepted, rand1Limit, rawBound, masterEq]

/-- Capacity rejection is equality-only; malformed counts above the maxima do
not take this guard. -/
theorem capacity_guard_exact (input : Input)
    (trainer : input.trainerBattle = false)
    (partyFull : input.partyCount = 6)
    (boxFull : input.boxCount = 20)
    (notTutorial : input.oldManTutorial = false) :
    attempt input = .rejectedCapacity := by
  simp [attempt, trainer, partyFull, boxFull, notTutorial]

/-- Capturing a transformed wild target stores Ditto. -/
private def transformedWitness : Input :=
  { ball := .master
    currentHp := 1
    maxHp := 100
    status := 0
    catchRate := 45
    species := 153
    transformed := true
    rand1 := 255
    rand2 := 255 }

theorem transformed_stores_ditto :
    attempt transformedWitness = .caught 76 1 := by
  native_decide

#guard rand1Accepted .great 200
#guard !rand1Accepted .great 201
#guard rand1Accepted .ultra 150
#guard !rand1Accepted .ultra 151

end Battle.Full.Capture
