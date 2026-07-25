/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Full.Capture

/-!
# Safari battle protocol

Bait/rock catch-rate mutation, factor rejection draws, factor countdown order,
ball exhaustion, and escape threshold are explicit. Hardware `Random` bytes are
caller-supplied and rejected samples request another byte.
-/

namespace Battle.Full.Safari

structure State where
  balls : UInt8
  baseCatchRate : UInt8
  catchRate : UInt8
  baitFactor : UInt8 := 0
  escapeFactor : UInt8 := 0
  deriving Repr, DecidableEq, BEq

inductive Action where
  | ball
  | bait
  | rock
  | run
  deriving Repr, DecidableEq, BEq

inductive Result where
  | continue (state : State)
  | needsFactorRandom (state : State) (action : Action)
  | needsEscapeRandom (state : State)
  | capturePending (state : State)
  | enemyRan (state : State)
  | ballsExhausted (state : State)
  | playerRan (state : State)
  deriving Repr, DecidableEq, BEq

private def addSaturating (value amount : UInt8) : UInt8 :=
  if value.toNat + amount.toNat > 255 then 255 else value + amount

/-- Factor draw accepts `(raw & 7) < 5`, then adds 1..5. -/
def factorAmount (raw : UInt8) : Option UInt8 :=
  let masked := raw &&& 7
  if masked < 5 then some (masked + 1) else none

private def applyBaitRock (state : State) (action : Action) (raw : UInt8) : Result :=
  match factorAmount raw with
  | none => .needsFactorRandom state action
  | some amount => match action with
    | .bait =>
        let state := { state with catchRate := state.catchRate >>> 1 }
        let state := { state with baitFactor := addSaturating state.baitFactor amount }
        .continue { state with escapeFactor := 0 }
    | .rock =>
        let state := { state with catchRate := addSaturating state.catchRate state.catchRate }
        let state := { state with escapeFactor := addSaturating state.escapeFactor amount }
        .continue { state with baitFactor := 0 }
    | _ => .continue state

/-- Text/countdown phase after a committed Safari action. Bait decrements first;
only when bait is zero does escape decrement. Expiring escape restores base catch
rate. -/
def tickFactors (state : State) : State :=
  if state.baitFactor != 0 then { state with baitFactor := state.baitFactor - 1 }
  else if state.escapeFactor != 0 then
    let escape := state.escapeFactor - 1
    let state := { state with escapeFactor := escape }
    { state with catchRate := if escape == 0 then state.baseCatchRate else state.catchRate }
  else state

/-- Escape threshold from the low Speed byte, with carry-immediate escape,
bait `/4`, rock `*2` saturation. -/
def escapeThreshold (speed : UInt16) (state : State) : Option UInt8 :=
  let low := speed.toUInt8
  if low.toNat > 127 then none
  else
    let doubled := low <<< 1
    let baited := if state.baitFactor != 0 then doubled >>> 2 else doubled
    let angered : UInt8 := if state.escapeFactor != 0 then
      if baited.toNat ≥ 128 then 255 else baited <<< 1
      else baited
    some angered

/-- Resolve one Safari menu action. For ball, capture calculation follows through
`Capture`; this function owns only ball count and post-action escape. -/
def act (state : State) (action : Action) (factorRaw escapeRaw : UInt8)
    (speed : UInt16) : Result :=
  match action with
  | .run => .playerRan state
  | .bait | .rock =>
      match applyBaitRock state action factorRaw with
      | .needsFactorRandom state action => .needsFactorRandom state action
      | .continue state =>
          if state.balls == 0 then .ballsExhausted state
          else
            let state := tickFactors state
            match escapeThreshold speed state with
            | none => .enemyRan state
            | some threshold => if escapeRaw < threshold then .enemyRan state else .continue state
      | result => result
  | .ball =>
      let state := { state with balls := state.balls - 1 }
      .capturePending state

/-- Post-ball continuation. The last Safari Ball is still thrown; out-of-balls
is checked only after an unsuccessful capture action returns. -/
def afterCapture (state : State) (caught : Bool) (escapeRaw : UInt8)
    (speed : UInt16) : Result :=
  if caught then .continue state
  else if state.balls == 0 then .ballsExhausted state
  else
    let state := tickFactors state
    match escapeThreshold speed state with
    | none => .enemyRan state
    | some threshold => if escapeRaw < threshold then .enemyRan state else .continue state

/-! ## Safari theorems -/

/-- Speed low bytes above 127 trigger the carry escape before a random draw. -/
theorem high_speed_runs (speed : UInt16) (state : State)
    (high : speed.toUInt8.toNat > 127) : escapeThreshold speed state = none := by
  unfold escapeThreshold
  rw [if_pos high]

private def baitStart : State := { balls := 30, baseCatchRate := 100, catchRate := 100 }
private def baitEnd : State :=
  { balls := 30, baseCatchRate := 100, catchRate := 50, baitFactor := 1, escapeFactor := 0 }
private def rockStart : State := { balls := 30, baseCatchRate := 200, catchRate := 200 }
private def rockEnd : State :=
  { balls := 30, baseCatchRate := 200, catchRate := 255, baitFactor := 0, escapeFactor := 1 }

/-- Bait halves catch rate; rock doubles with saturation. -/
theorem bait_rock_catch_witness :
    applyBaitRock baitStart .bait 0 = .continue baitEnd ∧
    applyBaitRock rockStart .rock 0 = .continue rockEnd := by
  native_decide

/-- Factor rejection is exact at masked values 5,6,7. -/
theorem factor_acceptance_exact (raw : UInt8) :
    (factorAmount raw).isSome = true ↔ (raw &&& 7).toNat < 5 := by
  have byteIff := UInt8.lt_ofNat_iff (n := raw &&& 7) (m := 5) (by native_decide)
  simpa [factorAmount] using byteIff

#guard factorAmount 0 == some 1
#guard factorAmount 4 == some 5
#guard factorAmount 5 == none

end Battle.Full.Safari
