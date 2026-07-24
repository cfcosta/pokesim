/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Full.State
import Battle.Step

/-!
# Full status gating and residuals

Models the canonical pre-move order: sleep, freeze, trapping, flinch, recharge,
Disable countdown, confusion, selected-disabled move, paralysis, then action.
Waking consumes the turn. Frozen state has no thaw roll. Confusion and paralysis
consume link RNG only at their exact checks.

Post-action residuals preserve the Toxic/Leech Seed interaction: the Toxic
counter is incremented by every call to the shared HP-decrease routine, even
when the damage source is Leech Seed rather than poison.
-/

namespace Battle.Full.Status

private def bitMask (index : Nat) : UInt8 := (1 <<< index).toUInt8
private def setBit (byte : UInt8) (index : Nat) : UInt8 := byte ||| bitMask index
private def clearBit (byte : UInt8) (index : Nat) : UInt8 := byte &&& ~~~(bitMask index)

inductive CannotActReason where
  | fastAsleep
  | wokeUp
  | frozen
  | trapped
  | flinched
  | recharge
  | selectedMoveDisabled
  | fullyParalyzed
  | confusionSelfHit
  deriving Repr, DecidableEq, BEq

inductive CheckResult where
  | canAct (side : Battle.SideState) (rng : Rng.LinkRng)
  | cannotAct (reason : CannotActReason) (side : Battle.SideState) (rng : Rng.LinkRng)
  | confusionHit (side : Battle.SideState) (rng : Rng.LinkRng) (raw : UInt8)
  deriving Repr, DecidableEq

private def replaceMon (side : Battle.SideState) (mon : MonState) : Battle.SideState :=
  { side with active := mon }

private def replaceVolatile (side : Battle.SideState) (volatile : Volatile) : Battle.SideState :=
  { side with volatile }

/-- Clear forced-move modes after self-confusion or full paralysis. -/
def clearInterruptedLocks (volatile : Volatile) : Volatile :=
  let mask := bitMask Wram.BattleStatus1.storingEnergy |||
    bitMask Wram.BattleStatus1.thrashingAbout |||
    bitMask Wram.BattleStatus1.chargingUp |||
    bitMask Wram.BattleStatus1.usingTrappingMove
  { volatile with status1 := volatile.status1 &&& ~~~mask }

/-- Exact pre-move status machine. `targetTrapping` is the opponent's trapping
bit, which prevents this side from moving. -/
def checkCanAct (side : Battle.SideState) (targetTrapping : Bool)
    (selectedMove : MoveId) (rng : Rng.LinkRng) : CheckResult :=
  let sleep := side.active.status &&& Wram.Status.slpMask
  if sleep != 0 then
    let remaining := sleep - 1
    -- The assembly writes the decremented masked value back as the whole status byte.
    let side := replaceMon side { side.active with status := remaining }
    if remaining == 0 then .cannotAct .wokeUp side rng
    else .cannotAct .fastAsleep side rng
  else if side.active.frozen then
    .cannotAct .frozen side rng
  else if targetTrapping then
    .cannotAct .trapped side rng
  else if side.volatile.flinched then
    let volatile := { side.volatile with
      status1 := clearBit side.volatile.status1 Wram.BattleStatus1.flinched }
    .cannotAct .flinched (replaceVolatile side volatile) rng
  else if side.volatile.recharging then
    let volatile := { side.volatile with
      status2 := clearBit side.volatile.status2 Wram.BattleStatus2.needsToRecharge }
    .cannotAct .recharge (replaceVolatile side volatile) rng
  else
    let disabled := side.volatile.disabledMove
    let volatile :=
      if disabled == 0 then side.volatile
      else
        let decremented := disabled - 1
        if (decremented &&& 0x0F) == 0 then
          { side.volatile with disabledMove := 0, disabledMoveNumber := 0 }
        else { side.volatile with disabledMove := decremented }
    let side := replaceVolatile side volatile
    if side.volatile.confused then
      let remaining := side.volatile.confusedCounter - 1
      if remaining == 0 then
        let volatile := { side.volatile with
          confusedCounter := 0
          status1 := clearBit side.volatile.status1 Wram.BattleStatus1.confused }
        checkDisabledAndParalysis (replaceVolatile side volatile) selectedMove rng
      else
        let side := replaceVolatile side { side.volatile with confusedCounter := remaining }
        let (raw, rng) := rng.next
        if raw < Step.speedTieThreshold then
          checkDisabledAndParalysis side selectedMove rng
        else
          let onlyConfused := side.volatile.status1 &&& bitMask Wram.BattleStatus1.confused
          let volatile := clearInterruptedLocks { side.volatile with status1 := onlyConfused }
          .confusionHit (replaceVolatile side volatile) rng raw
    else checkDisabledAndParalysis side selectedMove rng
where
  checkDisabledAndParalysis (side : Battle.SideState) (selectedMove : MoveId)
      (rng : Rng.LinkRng) : CheckResult :=
    if side.volatile.disabledMoveNumber != 0 &&
        side.volatile.disabledMoveNumber == selectedMove then
      .cannotAct .selectedMoveDisabled side rng
    else if side.active.paralyzed then
      let (raw, rng) := rng.next
      if raw < (63 : UInt8) then
        .cannotAct .fullyParalyzed
          (replaceVolatile side (clearInterruptedLocks side.volatile)) rng
      else .canAct side rng
    else .canAct side rng

/-! ## Residual HP -/

/-- Base poison/burn/seed damage, `max(1,floor(maxHP/16))`. -/
def baseResidualDamage (maxHp : UInt16) : UInt16 :=
  UInt16.ofNat (max 1 (maxHp.toNat / 16))

structure ResidualHit where
  side : Battle.SideState
  requestedDamage : UInt16
  actualDamage : UInt16
  deriving Repr, DecidableEq

/-- Shared HP-decrease routine. If badly poisoned, increment the Toxic counter
and multiply this call's damage by it regardless of damage source. -/
def decreaseResidualHp (side : Battle.SideState) : ResidualHit :=
  let base := baseResidualDamage side.active.maxHp
  let (volatile, requested) :=
    if side.volatile.badlyPoisoned then
      let ticks := side.volatile.toxicCounter + 1
      ({ side.volatile with toxicCounter := ticks },
        UInt16.ofNat (base.toNat * ticks.toNat))
    else (side.volatile, base)
  let actual := if side.active.hp ≤ requested then side.active.hp else requested
  let mon := { side.active with hp := Step.saturatingSub side.active.hp requested }
  { side := { side with active := mon, volatile },
    requestedDamage := requested, actualDamage := actual }

structure ResidualResult where
  actor : Battle.SideState
  opponent : Battle.SideState
  poisonOrBurnDamage : UInt16
  leechSeedDamage : UInt16
  leechSeedHealing : UInt16
  deriving Repr, DecidableEq

private def healBy (side : Battle.SideState) (amount : UInt16) : Battle.SideState :=
  let hp := UInt16.ofNat
    (min (side.active.hp.toNat + amount.toNat) side.active.maxHp.toNat)
  { side with active := { side.active with hp := hp } }

/-- Poison/burn first, then Leech Seed. Leech healing uses the requested damage
word, matching the stale `bc` behavior when subtraction overkills. -/
def applyResiduals (actor opponent : Battle.SideState) : ResidualResult :=
  let poisonOrBurn := actor.active.poisoned || actor.active.burned
  let first := if poisonOrBurn then decreaseResidualHp actor else
    { side := actor, requestedDamage := 0, actualDamage := 0 }
  if first.side.volatile.seeded then
    let seeded := decreaseResidualHp first.side
    let opponent := healBy opponent seeded.requestedDamage
    { actor := seeded.side, opponent,
      poisonOrBurnDamage := first.actualDamage,
      leechSeedDamage := seeded.actualDamage,
      leechSeedHealing := seeded.requestedDamage }
  else
    { actor := first.side, opponent,
      poisonOrBurnDamage := first.actualDamage,
      leechSeedDamage := 0, leechSeedHealing := 0 }

/-! ## Status compatibility theorems -/

/-- A sleep counter of one wakes but still cannot act this turn. -/
theorem waking_consumes_turn (side : Battle.SideState) (selected : MoveId) (rng : Rng.LinkRng)
    (sleepOne : side.active.status &&& Wram.Status.slpMask = 1) :
    ∃ updated, checkCanAct side false selected rng = .cannotAct .wokeUp updated rng := by
  refine ⟨replaceMon side { side.active with status := 0 }, ?_⟩
  simp [checkCanAct, sleepOne]

/-- Full paralysis accepts exactly raw bytes 0..62 as unable to act. -/
theorem paralysis_threshold_exact (raw : UInt8) :
    (raw < (63 : UInt8)) ↔ raw.toNat < 63 := by
  simpa using (UInt8.lt_ofNat_iff (n := raw) (m := 63) (by native_decide))

/-- Two calls to the shared residual routine increment the Toxic counter twice.
The second call is exactly what seeded residual processing performs. -/
theorem toxic_two_calls_tick (side : Battle.SideState)
    (toxic : side.volatile.badlyPoisoned = true) :
    (decreaseResidualHp (decreaseResidualHp side).side).side.volatile.toxicCounter =
      side.volatile.toxicCounter + 2 := by
  have preserved :
      ({ side.volatile with toxicCounter := side.volatile.toxicCounter + 1 } :
        Volatile).badlyPoisoned = true := by
    simpa [Volatile.badlyPoisoned] using toxic
  simp [decreaseResidualHp, toxic, preserved, UInt8.add_assoc]

#guard baseResidualDamage 1 == 1
#guard baseResidualDamage 160 == 10

end Battle.Full.Status
