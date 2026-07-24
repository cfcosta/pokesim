/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Full.State

/-!
# Ordinary run calculation

Exact byte-width `TryRunningFromBattle` arithmetic. Failed wild attempts consume
a turn and increment the wrapping attempt counter; trainer rejection does
neither. Final comparison is inclusive.
-/

namespace Battle.Full.Escape

inductive Result where
  | escaped (attempts : UInt8)
  | failed (attempts : UInt8)
  | prohibitedTrainer
  deriving Repr, DecidableEq, BEq

/-- Resolve a run request. `random` is `BattleRandom`, used only on the final
comparison path. -/
def attempt (mode : BattleMode) (ghost : Bool) (playerSpeed enemySpeed : UInt16)
    (previousAttempts : UInt8) (random : UInt8) : Result :=
  if ghost || mode == .safari || mode == .link then .escaped previousAttempts
  else if mode == .trainer then .prohibitedTrainer
  else
    let attempts := previousAttempts + 1
    if playerSpeed ≥ enemySpeed then .escaped attempts
    else
      let divisor := (enemySpeed >>> 2).toUInt8
      if divisor == 0 then .escaped attempts
      else
        let quotient := playerSpeed.toNat * 32 / divisor.toNat
        if quotient ≥ 256 then .escaped attempts
        else
          let bonus := (30 * (attempts.toNat - 1)).toUInt8
          let threshold := quotient.toUInt8 + bonus
          if random ≤ threshold then .escaped attempts else .failed attempts

/-- Equal Speed succeeds before any random comparison. -/
theorem equal_speed_escapes (speed : UInt16) (attempts random : UInt8) :
    attempt .wild false speed speed attempts random = .escaped (attempts + 1) := by
  have safari : (BattleMode.wild == BattleMode.safari) = false := by native_decide
  have link : (BattleMode.wild == BattleMode.link) = false := by native_decide
  have trainer : (BattleMode.wild == BattleMode.trainer) = false := by native_decide
  simp [attempt, safari, link, trainer]

/-- Trainer prohibition preserves the attempt counter implicitly by returning no
counter payload. -/
theorem trainer_prohibited (player enemy : UInt16) (attempts random : UInt8) :
    attempt .trainer false player enemy attempts random = .prohibitedTrainer := by
  rfl

/-- Final comparison is inclusive. -/
theorem inclusive_witness :
    attempt .wild false 10 100 0 12 = .escaped 1 := by
  native_decide

end Battle.Full.Escape
