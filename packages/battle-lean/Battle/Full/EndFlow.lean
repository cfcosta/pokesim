/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0.
-/
import Battle.Full.State
import Battle.Outcome

/-! # Trainer send-out prompts and battle-end control summaries -/

namespace Battle.Full.EndFlow

open Battle Battle.Wram

structure ShiftPromptContext where
  firstMonsNotOutYet : UInt8
  partyCount : UInt8
  link : Bool
  setStyle : Bool
  aiInitiatedSwitch : Bool
  deriving Repr, DecidableEq, BEq

/-- Shift prompt polarity follows the ROM: option bit clear means Shift; the
first send-out sentinel value is exactly one; one-member parties suppress it. -/
def shouldOfferShift (context : ShiftPromptContext) : Bool :=
  context.firstMonsNotOutYet != 1 && context.partyCount != 1 &&
    !context.link && !context.setStyle && !context.aiInitiatedSwitch

@[simp] theorem shift_prompt_boundaries :
    shouldOfferShift ⟨0, 2, false, false, false⟩ = true ∧
      shouldOfferShift ⟨1, 2, false, false, false⟩ = false ∧
      shouldOfferShift ⟨0, 1, false, false, false⟩ = false ∧
      shouldOfferShift ⟨0, 2, false, true, false⟩ = false ∧
      shouldOfferShift ⟨0, 2, false, false, true⟩ = false := by
  native_decide

inductive ShiftResponse where
  | stay
  | cancel
  | switch (target : Fin 6)
  deriving Repr, DecidableEq, BEq

inductive ShiftResolution where
  | stay
  | retry
  | switched (target : Fin 6)
  deriving Repr, DecidableEq, BEq

/-- The nested party menu rejects the active and fainted rows; cancellation
returns to send-out without inventing a switch. -/
def resolveShift (side : Full.SideState) : ShiftResponse → ShiftResolution
  | .stay | .cancel => .stay
  | .switch target =>
      if target.val == side.activeIndex then .retry
      else if (side.party.mons.getD target.val side.active.active).fainted then .retry
      else .switched target

@[simp] theorem active_shift_target_retries (side : Full.SideState)
    (activeBound : side.activeIndex < 6) :
    resolveShift side (.switch ⟨side.activeIndex, activeBound⟩) = .retry := by
  simp [resolveShift]

/-- After a natural enemy replacement, the current player active is the sole EXP
participant against the newly loaded enemy. -/
def resetParticipationForEnemy (activeIndex : Nat) : UInt8 × UInt8 :=
  let active := (1 <<< activeIndex).toUInt8
  (active, active)

@[simp] theorem shift_participation_is_active_only (activeIndex : Nat) :
    resetParticipationForEnemy activeIndex =
      ((1 <<< activeIndex).toUInt8, (1 <<< activeIndex).toUInt8) := by
  rfl

/-- Link send-out subtracts four from the received action byte without checking
the resulting party index. -/
def uncheckedRemoteSwitchIndex (wire : UInt8) : UInt8 := wire - 4

@[simp] theorem malformed_remote_switch_wraps : uncheckedRemoteSwitchIndex 3 = 0xFF := by
  native_decide

inductive EndTextChoice where
  | win
  | lose
  deriving Repr, DecidableEq, BEq

structure EndTextPlan where
  clearPrintFlag : Bool
  saveTrainerName : Bool
  useDynamicText : Bool
  restoreRomBank : Bool
  setTrainerSpriteStay : Bool
  waitForSound : Bool
  choice : EndTextChoice
  deriving Repr, DecidableEq, BEq

/-- Enabled `PrintEndBattleText` performs all visible callback/control writes;
any nonzero raw result selects the lose pointer, including simultaneous-faint
trainer victory with raw result one. -/
def endTextPlan (enabled : Bool) (rawResult : UInt8) : Option EndTextPlan :=
  if !enabled then none else some
    { clearPrintFlag := true
      saveTrainerName := true
      useDynamicText := true
      restoreRomBank := true
      setTrainerSpriteStay := true
      waitForSound := true
      choice := if rawResult == 0 then .win else .lose }

@[simp] theorem simultaneous_raw_loss_selects_lose_text :
    (endTextPlan true 1).map EndTextPlan.choice = some .lose := by
  native_decide

/-- Low-health alarm/audio state is deliberately a presentation/system field,
not part of the mechanics projection. -/
def lowHealthAlarmProjected : Bool := false

@[simp] theorem low_health_alarm_explicitly_excluded : lowHealthAlarmProjected = false := rfl

end Battle.Full.EndFlow
