/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Full.State
import Std.Tactic.BVDecide
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

/-- Every possible status-1 byte loses charging when an interrupted move is
cleared, while its Fly/Dig invulnerability bit is preserved exactly. -/
def interruptedChargeExhaustive : Bool :=
  (List.range 256).all fun value =>
    let volatile := { Volatile.clear with status1 := value.toUInt8 }
    (clearInterruptedLocks volatile).chargingUp == false &&
      (bitSet (clearInterruptedLocks volatile).status1 Wram.BattleStatus1.invulnerable ==
        bitSet volatile.status1 Wram.BattleStatus1.invulnerable)

theorem interrupted_charge_leaves_invulnerability :
    interruptedChargeExhaustive = true := by
  native_decide

/-- A successful second charge turn clears both charging and invulnerability.
Interrupted charge turns use `clearInterruptedLocks` and deliberately leave the
invulnerability bit behind. -/
private def clearSuccessfulCharge (side : Battle.SideState) : Battle.SideState :=
  if side.volatile.chargingUp then
    let mask := bitMask Wram.BattleStatus1.chargingUp |||
      bitMask Wram.BattleStatus1.invulnerable
    replaceVolatile side { side.volatile with status1 := side.volatile.status1 &&& ~~~mask }
  else side

def tickDisable (volatile : Volatile) : Volatile :=
  if volatile.disabledMove == 0 then volatile
  else
    let decremented := volatile.disabledMove - 1
    if (decremented &&& 0x0F) == 0 then
      { volatile with disabledMove := 0, disabledMoveNumber := 0 }
    else { volatile with disabledMove := decremented }

@[simp] theorem disable_low_nibble_one_expires (volatile : Volatile)
    (active : volatile.disabledMove != 0)
    (last : ((volatile.disabledMove - 1) &&& 0x0F) = 0) :
    (tickDisable volatile).disabledMove = 0 ∧
      (tickDisable volatile).disabledMoveNumber = 0 := by
  have ne : volatile.disabledMove ≠ 0 := by
    intro equal
    simp [equal] at active
  simp [tickDisable, ne, last]

def prepareConfusionSelfHit (volatile : Battle.Volatile) : Battle.Volatile :=
  let onlyConfused := volatile.status1 &&& bitMask Wram.BattleStatus1.confused
  clearInterruptedLocks { volatile with status1 := onlyConfused }

@[simp] theorem confusion_self_hit_keeps_only_confused_status1
    (volatile : Battle.Volatile) :
    (prepareConfusionSelfHit volatile).status1 =
      volatile.status1 &&& bitMask Wram.BattleStatus1.confused := by
  simp only [prepareConfusionSelfHit, clearInterruptedLocks]
  simp [bitMask, Wram.BattleStatus1.confused, Wram.BattleStatus1.storingEnergy,
    Wram.BattleStatus1.thrashingAbout, Wram.BattleStatus1.chargingUp,
    Wram.BattleStatus1.usingTrappingMove]
  bv_decide

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
    let side := replaceVolatile side (tickDisable side.volatile)
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
          let volatile := prepareConfusionSelfHit side.volatile
          .confusionHit (replaceVolatile side volatile) rng raw
    else checkDisabledAndParalysis side selectedMove rng
where
  checkDisabledAndParalysis (side : Battle.SideState) (selectedMove : MoveId)
      (rng : Rng.LinkRng) : CheckResult :=
    if side.volatile.disabledMoveNumber != 0 &&
        side.volatile.disabledMoveNumber == selectedMove then
      .cannotAct .selectedMoveDisabled
        (replaceVolatile side (clearInterruptedLocks side.volatile)) rng
    else if side.active.paralyzed then
      let (raw, rng) := rng.next
      if raw < (63 : UInt8) then
        .cannotAct .fullyParalyzed
          (replaceVolatile side (clearInterruptedLocks side.volatile)) rng
      else .canAct (clearSuccessfulCharge side) rng
    else .canAct (clearSuccessfulCharge side) rng

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

def CheckResult.reason? : CheckResult → Option CannotActReason
  | .cannotAct reason _ _ => some reason
  | .confusionHit .. => some .confusionSelfHit
  | .canAct .. => none

def CheckResult.side : CheckResult → Battle.SideState
  | .canAct side _ | .cannotAct _ side _ | .confusionHit side _ _ => side

private def statusTestMon (status : UInt8 := 0) : MonState :=
  { species := 1, hp := 100, boxLevel := 50, status,
    type1 := 0, type2 := 0, catchRate := 45, moves := #[1, 2, 3, 4], dvs := 0,
    level := 50, maxHp := 100, attack := 100, defense := 100, speed := 100,
    special := 100, pp := #[1, 1, 1, 1] }

private def statusTestSide (status : UInt8 := 0) : Battle.SideState :=
  Battle.SideState.fresh (statusTestMon status)

private def highRng : Rng.LinkRng :=
  { list := #[255, 0, 0, 0, 0, 0, 0, 0, 0, 0], index := 0 }

/-- Exact witnesses expose the post-sleep status order, destructive flag resets,
confusion comparison, selected Disable check, and the 63/256 paralysis gate. -/
theorem ordered_status_gate_witnesses :
    let flinched := { (statusTestSide).volatile with
      status1 := (1 <<< Wram.BattleStatus1.flinched).toUInt8 }
    let flinchSide := { statusTestSide with volatile := flinched }
    let recharge := { (statusTestSide).volatile with
      status2 := (1 <<< Wram.BattleStatus2.needsToRecharge).toUInt8 }
    let rechargeSide := { statusTestSide with volatile := recharge }
    let confused := { (statusTestSide).volatile with
      status1 := (1 <<< Wram.BattleStatus1.confused).toUInt8 }
    let confused := { confused with confusedCounter := 2 }
    let confusedSide := { statusTestSide with volatile := confused }
    let disabled := { (statusTestSide).volatile with disabledMove := 0x12 }
    let disabled := { disabled with disabledMoveNumber := 2 }
    let disabledSide := { statusTestSide with volatile := disabled }
    (checkCanAct flinchSide false 1 Rng.seed0).reason? = some .flinched ∧
    (checkCanAct flinchSide false 1 Rng.seed0).side.volatile.flinched = false ∧
    (checkCanAct rechargeSide false 1 Rng.seed0).reason? = some .recharge ∧
    (checkCanAct rechargeSide false 1 Rng.seed0).side.volatile.recharging = false ∧
    (checkCanAct confusedSide false 1 highRng).reason? = some .confusionSelfHit ∧
    (checkCanAct confusedSide false 1 highRng).side.volatile.confusedCounter = 1 ∧
    (checkCanAct disabledSide false 2 Rng.seed0).reason? = some .selectedMoveDisabled ∧
    (checkCanAct (statusTestSide 0x40) false 1 Rng.seed0).reason? = some .fullyParalyzed := by
  native_decide

/-! ## Status compatibility theorems -/

theorem frozen_blocks_turn (side : Battle.SideState) (trapped : Bool)
    (selected : MoveId) (rng : Rng.LinkRng)
    (awake : side.active.status &&& Wram.Status.slpMask = 0)
    (frozen : side.active.frozen = true) :
    checkCanAct side trapped selected rng = .cannotAct .frozen side rng := by
  simp [checkCanAct, awake, frozen]

theorem opposing_trap_blocks_turn (side : Battle.SideState) (selected : MoveId)
    (rng : Rng.LinkRng)
    (awake : side.active.status &&& Wram.Status.slpMask = 0)
    (notFrozen : side.active.frozen = false) :
    checkCanAct side true selected rng = .cannotAct .trapped side rng := by
  simp [checkCanAct, awake, notFrozen]

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

/-- Integrated poison/burn plus Leech Seed processing invokes the Toxic-aware
HP routine twice and therefore advances the counter twice in one residual pass. -/
theorem toxic_leech_seed_ticks_twice (actor opponent : Battle.SideState)
    (poisonOrBurn : (actor.active.poisoned || actor.active.burned) = true)
    (toxic : actor.volatile.badlyPoisoned = true)
    (seeded : actor.volatile.seeded = true) :
    (applyResiduals actor opponent).actor.volatile.toxicCounter =
      actor.volatile.toxicCounter + 2 := by
  have seededAfterFirst : (decreaseResidualHp actor).side.volatile.seeded = true := by
    simp only [decreaseResidualHp, toxic, if_pos]
    simpa [Volatile.seeded] using seeded
  simp [applyResiduals, poisonOrBurn, seededAfterFirst]
  exact toxic_two_calls_tick actor toxic

/-- Even if the poison/burn subtraction has already produced zero HP, the
same residual pass still calls the seeded subtraction and heals from its
requested (not capped actual) damage word. -/
theorem leech_seed_runs_after_residual_ko (actor opponent : Battle.SideState)
    (poisonOrBurn : (actor.active.poisoned || actor.active.burned) = true)
    (seeded : actor.volatile.seeded = true)
    (ko : (decreaseResidualHp actor).side.active.hp = 0) :
    (applyResiduals actor opponent).leechSeedHealing =
        (decreaseResidualHp (decreaseResidualHp actor).side).requestedDamage ∧
      (decreaseResidualHp actor).side.active.hp = 0 := by
  have seededAfterFirst : (decreaseResidualHp actor).side.volatile.seeded = true := by
    simp only [decreaseResidualHp]
    split
    · simpa [Volatile.seeded] using seeded
    · simpa [Volatile.seeded] using seeded
  constructor
  · simp [applyResiduals, poisonOrBurn, seededAfterFirst]
  · exact ko

#guard baseResidualDamage 1 == 1
#guard baseResidualDamage 160 == 10

end Battle.Full.Status
