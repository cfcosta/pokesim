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

@[simp] theorem ghost_escapes (mode : BattleMode) (player enemy : UInt16)
    (attempts random : UInt8) :
    attempt mode true player enemy attempts random = .escaped attempts := by
  simp [attempt]

@[simp] theorem safari_escapes (player enemy : UInt16) (attempts random : UInt8) :
    attempt .safari false player enemy attempts random = .escaped attempts := rfl

@[simp] theorem link_escapes (player enemy : UInt16) (attempts random : UInt8) :
    attempt .link false player enemy attempts random = .escaped attempts := rfl

/-- Equal Speed succeeds before any random comparison. -/
theorem equal_speed_escapes (speed : UInt16) (attempts random : UInt8) :
    attempt .wild false speed speed attempts random = .escaped (attempts + 1) := by
  have safari : (BattleMode.wild == BattleMode.safari) = false := by native_decide
  have link : (BattleMode.wild == BattleMode.link) = false := by native_decide
  have trainer : (BattleMode.wild == BattleMode.trainer) = false := by native_decide
  simp [attempt, safari, link, trainer]

theorem player_not_slower_escapes (player enemy : UInt16) (attempts random : UInt8)
    (notSlower : player ≥ enemy) :
    attempt .wild false player enemy attempts random = .escaped (attempts + 1) := by
  have safari : (BattleMode.wild == BattleMode.safari) = false := by native_decide
  have link : (BattleMode.wild == BattleMode.link) = false := by native_decide
  have trainer : (BattleMode.wild == BattleMode.trainer) = false := by native_decide
  simp [attempt, safari, link, trainer, notSlower]

/-- Trainer prohibition preserves the attempt counter implicitly by returning no
counter payload. -/
theorem trainer_prohibited (player enemy : UInt16) (attempts random : UInt8) :
    attempt .trainer false player enemy attempts random = .prohibitedTrainer := by
  rfl

/-- A failed attempt increments the wrapping byte and consumes the turn at the
engine boundary. -/
theorem failed_attempt_witness : attempt .wild false 1 100 0 255 = .failed 1 := by
  native_decide

/-- The truncated zero divisor succeeds immediately, including nonzero enemy
Speed values whose quarter has low byte zero. -/
theorem zero_divisor_witness : attempt .wild false 1 1024 7 255 = .escaped 8 := by
  native_decide

/-- Attempt count wraps before the byte-loop bonus is formed. -/
theorem attempt_counter_wrap_witness : attempt .wild false 1 100 255 255 = .failed 0 := by
  native_decide

/-- Final comparison is inclusive. -/
theorem inclusive_witness :
    attempt .wild false 10 100 0 12 = .escaped 1 := by
  native_decide

end Battle.Full.Escape
