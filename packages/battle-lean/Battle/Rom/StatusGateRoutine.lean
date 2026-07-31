/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Rom.ChargeRoutine
import Battle.Full.Status
import Sm83.FlatAdapter

/-!
# Decoded pre-move status gate

This module retains the duplicated player/enemy status-gate windows from
English Pokémon Red and executes every gameplay-mutating kernel that precedes
presentation or damage calls. The executable matrices cover every raw byte for
sleep, flinch, recharge, Disable, confusion counters, full paralysis cleanup,
and selected-disabled charge cleanup on both acting sides.

Text, animation, `BattleRandom`, and self-confusion damage are synchronization
boundaries. Their call sites and post-return comparisons are retained exactly;
the high-level status theorem separately exhausts all 65,536 nonvolatile
status/RNG combinations. No presentation call is treated as gameplay.
-/

namespace Battle.Rom.StatusGateRoutine

open Sm83 Battle.Rom.Closure

private def hWhoseTurn : Word := 0xFFF3
private def playerMonStatus : Word := 0xD018
private def enemyMonStatus : Word := 0xCFE9
private def playerStatus1 : Word := 0xD062
private def enemyStatus1 : Word := 0xD067
private def playerStatus2 : Word := 0xD063
private def enemyStatus2 : Word := 0xD068
private def playerDisabled : Word := 0xD06D
private def enemyDisabled : Word := 0xD072
private def playerDisabledMove : Word := 0xCCEE
private def enemyDisabledMove : Word := 0xCCEF
private def playerConfusedCounter : Word := 0xD06B
private def enemyConfusedCounter : Word := 0xD070
private def playerSelectedMove : Word := 0xCCDC
private def enemySelectedMove : Word := 0xCCDD

private def pSleep : Word := 0x5854
private def eSleep : Word := 0x688F
private def pSleepEnd : Word := 0x5861
private def eSleepEnd : Word := 0x689C
private def pFlinch : Word := 0x58AC
private def eFlinch : Word := 0x68E7
private def pFlinchEnd : Word := 0x58B6
private def eFlinchEnd : Word := 0x68F1
private def pFlinchNext : Word := 0x58C2
private def eFlinchNext : Word := 0x68FD
private def pRecharge : Word := 0x58C2
private def eRecharge : Word := 0x68FD
private def pRechargeEnd : Word := 0x58CB
private def eRechargeEnd : Word := 0x6906
private def pRechargeNext : Word := 0x58D7
private def eRechargeNext : Word := 0x6912
private def pDisable : Word := 0x58D7
private def eDisable : Word := 0x6912
private def pDisableNext : Word := 0x58EE
private def eDisableNext : Word := 0x6929
private def pDisableExpired : Word := 0x58E8
private def eDisableExpired : Word := 0x6923
private def pConfusion : Word := 0x58EE
private def eConfusion : Word := 0x6929
private def pConfusionNext : Word := 0x5929
private def eConfusionNext : Word := 0x69AA
private def pConfusionActive : Word := 0x5907
private def eConfusionActive : Word := 0x6944
private def pConfusionExpired : Word := 0x58FF
private def eConfusionExpired : Word := 0x693B
private def pInterrupt : Word := 0x5952
private def eInterrupt : Word := 0x69D3
private def pInterruptEnd : Word := 0x5959
private def eInterruptEnd : Word := 0x69DA
private def disabledClear : Word := 0x5A88
private def disabledClearEnd : Word := 0x5A9B

private def pSleepBytes : List Byte :=
  [0x21, 0x18, 0xD0, 0x7E, 0xE6, 0x07, 0x28, 0x28,
   0x3D, 0xEA, 0x18, 0xD0, 0xA7]
private def eSleepBytes : List Byte :=
  [0x21, 0xE9, 0xCF, 0x7E, 0xE6, 0x07, 0x28, 0x28,
   0x3D, 0xEA, 0xE9, 0xCF, 0xA7]

private def pFreezeBytes : List Byte :=
  [0xCB, 0x6E, 0x28, 0x10, 0x21, 0x47, 0x5A, 0xCD, 0x49, 0x3C,
   0xAF, 0xEA, 0xF1, 0xCC, 0x21, 0x0A, 0x58, 0xC3, 0x37, 0x5A]
private def eFreezeBytes : List Byte :=
  [0xCB, 0x6E, 0x28, 0x10, 0x21, 0x47, 0x5A, 0xCD, 0x49, 0x3C,
   0xAF, 0xEA, 0xF2, 0xCC, 0x21, 0x8C, 0x68, 0xC3, 0xB8, 0x6A]
private def pTrapBytes : List Byte :=
  [0xFA, 0x67, 0xD0, 0xCB, 0x6F, 0xCA, 0xAC, 0x58, 0x21, 0x83,
   0x5A, 0xCD, 0x49, 0x3C, 0x21, 0x0A, 0x58, 0xC3, 0x37, 0x5A]
private def eTrapBytes : List Byte :=
  [0xFA, 0x62, 0xD0, 0xCB, 0x6F, 0xCA, 0xE7, 0x68, 0x21, 0x83,
   0x5A, 0xCD, 0x49, 0x3C, 0x21, 0x8C, 0x68, 0xC3, 0xB8, 0x6A]

private def pFlinchBytes : List Byte :=
  [0x21, 0x62, 0xD0, 0xCB, 0x5E, 0xCA, 0xC2, 0x58, 0xCB, 0x9E]
private def eFlinchBytes : List Byte :=
  [0x21, 0x67, 0xD0, 0xCB, 0x5E, 0xCA, 0xFD, 0x68, 0xCB, 0x9E]
private def pRechargeBytes : List Byte :=
  [0x21, 0x63, 0xD0, 0xCB, 0x6E, 0x28, 0x0E, 0xCB, 0xAE]
private def eRechargeBytes : List Byte :=
  [0x21, 0x68, 0xD0, 0xCB, 0x6E, 0x28, 0x0E, 0xCB, 0xAE]

private def pDisableBytes : List Byte :=
  [0x21, 0x6D, 0xD0, 0x7E, 0xA7, 0x28, 0x10, 0x3D, 0x77, 0xE6,
   0x0F, 0x20, 0x0A, 0x77, 0xEA, 0xEE, 0xCC, 0x21, 0x5B, 0x5A,
   0xCD, 0x49, 0x3C]
private def eDisableBytes : List Byte :=
  [0x21, 0x72, 0xD0, 0x7E, 0xA7, 0x28, 0x10, 0x3D, 0x77, 0xE6,
   0x0F, 0x20, 0x0A, 0x77, 0xEA, 0xEF, 0xCC, 0x21, 0x5B, 0x5A,
   0xCD, 0x49, 0x3C]

private def pConfusionBytes : List Byte :=
  [0xFA, 0x62, 0xD0, 0x87, 0x30, 0x35, 0x21, 0x6B, 0xD0, 0x35,
   0x20, 0x0D, 0x21, 0x62, 0xD0, 0xCB, 0xBE, 0x21, 0x6A, 0x5A,
   0xCD, 0x49, 0x3C, 0x18, 0x22]
private def eConfusionBytes : List Byte :=
  [0xFA, 0x67, 0xD0, 0x87, 0xD2, 0xAA, 0x69, 0x21, 0x70, 0xD0,
   0x35, 0x20, 0x0E, 0x21, 0x67, 0xD0, 0xCB, 0xBE, 0x21, 0x6A,
   0x5A, 0xCD, 0x49, 0x3C, 0xC3, 0xAA, 0x69]
private def pConfusionRandomBytes : List Byte :=
  [0xCD, 0x9B, 0x6E, 0xFE, 0x80, 0x38, 0x0C, 0x21, 0x62, 0xD0,
   0x7E, 0xE6, 0x80, 0x77]
private def eConfusionRandomBytes : List Byte :=
  [0xCD, 0x9B, 0x6E, 0xFE, 0x80, 0x38, 0x50, 0x21, 0x67, 0xD0,
   0x7E, 0xE6, 0x80, 0x77]

private def pDisabledCheckBytes : List Byte :=
  [0xFA, 0xEE, 0xCC, 0xA7, 0x28, 0x0F, 0x21, 0xDC, 0xCC, 0xBE,
   0x20, 0x09, 0xCD, 0x88, 0x5A, 0x21, 0x0A, 0x58, 0xC3, 0x37, 0x5A]
private def eDisabledCheckBytes : List Byte :=
  [0xFA, 0xEF, 0xCC, 0xA7, 0x28, 0x0F, 0x21, 0xDD, 0xCC, 0xBE,
   0x20, 0x09, 0xCD, 0x88, 0x5A, 0x21, 0x8C, 0x68, 0xC3, 0xB8, 0x6A]
private def pParalysisBytes : List Byte :=
  [0x21, 0x18, 0xD0, 0xCB, 0x76, 0x28, 0x30, 0xCD, 0x9B, 0x6E,
   0xFE, 0x3F, 0x30, 0x29, 0x21, 0x4C, 0x5A, 0xCD, 0x49, 0x3C]
private def eParalysisBytes : List Byte :=
  [0x21, 0xE9, 0xCF, 0xCB, 0x76, 0x28, 0x30, 0xCD, 0x9B, 0x6E,
   0xFE, 0x3F, 0x30, 0x29, 0x21, 0x4C, 0x5A, 0xCD, 0x49, 0x3C]

private def pInterruptBytes : List Byte :=
  [0x21, 0x62, 0xD0, 0x7E, 0xE6, 0xCC, 0x77]
private def eInterruptBytes : List Byte :=
  [0x21, 0x67, 0xD0, 0x7E, 0xE6, 0xCC, 0x77]
private def disabledClearBytes : List Byte :=
  [0x21, 0xDC, 0xCC, 0x11, 0x62, 0xD0, 0xF0, 0xF3, 0xA7, 0x28,
   0x04, 0x23, 0x11, 0x67, 0xD0, 0x1A, 0xCB, 0xA7, 0x12]

private def install : FlatMemory → Word → List Byte → FlatMemory
  | memory, _, [] => memory
  | memory, address, byte :: rest =>
      install (memory.write address byte) (Word.ofNat (address.toNat + 1)) rest

private def sideAddress (enemyTurn : Bool) (player enemy : Word) : Word :=
  if enemyTurn then enemy else player

private def traceOf : Program.RunResult → List BusEvent
  | .reached _ trace _ | .halted _ trace _ | .stopped _ trace _ |
      .locked _ trace _ | .fuelExhausted _ trace _ => trace

private def physicalInitial (state : FunctionalState) : FlatCoreState :=
  let core := { Pipeline.bootstrap state.registers with ime := state.ime }
  let core := { core with scheduledImeEnable := state.scheduledImeEnable }
  let core := { core with haltBug := state.haltBug }
  { core, memory := state.memory }

private def physicalAgrees (initial : FunctionalState) (result : Program.RunResult)
    (endPc : Word) : Bool :=
  let expected := traceOf result
  let physical := FlatAdapter.run (expected.length + 1)
    (physicalInitial initial) (fun _ _ => 0)
  let projected := FlatAdapter.project physical
  physical.trace == expected ++
      [.read .opcode endPc ((Driver.finalState result).memory.read endPc)] &&
    projected.registers == (Driver.finalState result).registers &&
    projected.mode == .running && physical.core.boundaryPC.isSome

/-! ## Sleep counter -/

private def sleepInitial (enemyTurn : Bool) (status : UInt8) : FunctionalState :=
  let entry := sideAddress enemyTurn pSleep eSleep
  let bytes := if enemyTurn then eSleepBytes else pSleepBytes
  let address := sideAddress enemyTurn playerMonStatus enemyMonStatus
  { registers := { (default : Registers) with pc := entry }
    memory := (install default entry bytes).write address (Byte.ofNat status.toNat) }

private def sleepEnd (enemyTurn : Bool) : Word :=
  sideAddress enemyTurn pSleepEnd eSleepEnd

def sleepHolds (enemyTurn : Bool) (status : UInt8) : Bool :=
  let initial := sleepInitial enemyTurn status
  let result := Program.runUntil (fun state => state.registers.pc == sleepEnd enemyTurn)
    10 initial [] 0
  let final := Driver.finalState result
  let address := sideAddress enemyTurn playerMonStatus enemyMonStatus
  let expected := (status &&& 7) - 1
  Driver.reachedReturn result && final.registers.pc == sleepEnd enemyTurn &&
    Driver.toByte (final.memory.read address) == expected &&
    physicalAgrees initial result (sleepEnd enemyTurn)

private theorem sleep_matrix :
    (List.range 256).all (fun raw =>
      if (raw.toUInt8 &&& 7) != 0 then
        sleepHolds false raw.toUInt8 && sleepHolds true raw.toUInt8
      else true) = true := by
  native_decide

/-- Every nonzero 1–7 sleep counter is masked, decremented, and written back as
the complete status byte on both sides, destroying malformed high status bits. -/
theorem sleep_counter_exact (enemyTurn : Bool) (status : UInt8)
    (sleeping : status &&& 7 != 0) : sleepHolds enemyTurn status = true := by
  have rows := List.all_eq_true.mp sleep_matrix status.toNat
    (List.mem_range.mpr status.toNat_lt)
  have round : status.toNat.toUInt8 = status := by
    apply UInt8.toNat.inj
    simp
  rw [round] at rows
  simp [sleeping] at rows
  cases enemyTurn <;> simp_all

/-! ## Flinch and recharge destructive clears -/

private def flagInitial (enemyTurn recharge : Bool) (status : UInt8) : FunctionalState :=
  let entry := if recharge then sideAddress enemyTurn pRecharge eRecharge
    else sideAddress enemyTurn pFlinch eFlinch
  let bytes := if recharge then (if enemyTurn then eRechargeBytes else pRechargeBytes)
    else (if enemyTurn then eFlinchBytes else pFlinchBytes)
  let address := if recharge then sideAddress enemyTurn playerStatus2 enemyStatus2
    else sideAddress enemyTurn playerStatus1 enemyStatus1
  { registers := { (default : Registers) with pc := entry }
    memory := (install default entry bytes).write address (Byte.ofNat status.toNat) }

private def flagEnd (enemyTurn recharge set : Bool) : Word :=
  if recharge then
    if set then sideAddress enemyTurn pRechargeEnd eRechargeEnd
    else sideAddress enemyTurn pRechargeNext eRechargeNext
  else if set then sideAddress enemyTurn pFlinchEnd eFlinchEnd
    else sideAddress enemyTurn pFlinchNext eFlinchNext

def flagHolds (enemyTurn recharge : Bool) (status : UInt8) : Bool :=
  let mask : UInt8 := if recharge then 0x20 else 0x08
  let set := (status &&& mask) != 0
  let endPc := flagEnd enemyTurn recharge set
  let initial := flagInitial enemyTurn recharge status
  let result := Program.runUntil (fun state => state.registers.pc == endPc) 8 initial [] 0
  let final := Driver.finalState result
  let address := if recharge then sideAddress enemyTurn playerStatus2 enemyStatus2
    else sideAddress enemyTurn playerStatus1 enemyStatus1
  let expected := if set then status &&& ~~~mask else status
  Driver.reachedReturn result && final.registers.pc == endPc &&
    Driver.toByte (final.memory.read address) == expected &&
    physicalAgrees initial result endPc

private theorem flag_matrix :
    (List.range 256).all (fun raw =>
      flagHolds false false raw.toUInt8 && flagHolds true false raw.toUInt8 &&
        flagHolds false true raw.toUInt8 && flagHolds true true raw.toUInt8) = true := by
  native_decide

/-- Flinch clears only status-1 bit 3; recharge clears only status-2 bit 5.
Absent flags branch to the next gate without any write. -/
theorem flinch_recharge_exact (enemyTurn recharge : Bool) (status : UInt8) :
    flagHolds enemyTurn recharge status = true := by
  have rows := List.all_eq_true.mp flag_matrix status.toNat
    (List.mem_range.mpr status.toNat_lt)
  have round : status.toNat.toUInt8 = status := by
    apply UInt8.toNat.inj
    simp
  rw [round] at rows
  cases enemyTurn <;> cases recharge <;> simp_all

/-! ## Disable countdown -/

private def disableInitial (enemyTurn : Bool) (packed move : UInt8) : FunctionalState :=
  let entry := sideAddress enemyTurn pDisable eDisable
  let bytes := if enemyTurn then eDisableBytes else pDisableBytes
  let packedAddress := sideAddress enemyTurn playerDisabled enemyDisabled
  let moveAddress := sideAddress enemyTurn playerDisabledMove enemyDisabledMove
  let memory := (install default entry bytes).write packedAddress (Byte.ofNat packed.toNat)
  { registers := { (default : Registers) with pc := entry }
    memory := memory.write moveAddress (Byte.ofNat move.toNat) }

private def disableExpected (packed move : UInt8) : UInt8 × UInt8 × Bool :=
  if packed == 0 then (packed, move, false)
  else
    let decremented := packed - 1
    if (decremented &&& 0x0F) == 0 then (0, 0, true)
    else (decremented, move, false)

def disableHolds (enemyTurn : Bool) (packed move : UInt8) : Bool :=
  let expected := disableExpected packed move
  let endPc := if expected.2.2 then sideAddress enemyTurn pDisableExpired eDisableExpired
    else sideAddress enemyTurn pDisableNext eDisableNext
  let initial := disableInitial enemyTurn packed move
  let result := Program.runUntil (fun state => state.registers.pc == endPc) 16 initial [] 0
  let final := Driver.finalState result
  let packedAddress := sideAddress enemyTurn playerDisabled enemyDisabled
  let moveAddress := sideAddress enemyTurn playerDisabledMove enemyDisabledMove
  Driver.reachedReturn result && final.registers.pc == endPc &&
    Driver.toByte (final.memory.read packedAddress) == expected.1 &&
    Driver.toByte (final.memory.read moveAddress) == expected.2.1 &&
    physicalAgrees initial result endPc

private theorem disable_matrix :
    (List.range 256).all (fun packed =>
      disableHolds false packed.toUInt8 0xA5 &&
        disableHolds true packed.toUInt8 0xA5) = true := by
  native_decide

/-- The full packed Disable byte domain is exact on both sides, including
underflow avoidance, low-nibble expiration, and stale move-number preservation
when the packed byte is already zero. -/
theorem disable_countdown_exact (enemyTurn : Bool) (packed : UInt8) :
    disableHolds enemyTurn packed 0xA5 = true := by
  have rows := List.all_eq_true.mp disable_matrix packed.toNat
    (List.mem_range.mpr packed.toNat_lt)
  have round : packed.toNat.toUInt8 = packed := by
    apply UInt8.toNat.inj
    simp
  rw [round] at rows
  cases enemyTurn <;> simp_all

/-! ## Confusion counter -/

private def confusionInitial (enemyTurn : Bool) (status counter : UInt8) : FunctionalState :=
  let entry := sideAddress enemyTurn pConfusion eConfusion
  let bytes := if enemyTurn then eConfusionBytes else pConfusionBytes
  let statusAddress := sideAddress enemyTurn playerStatus1 enemyStatus1
  let counterAddress := sideAddress enemyTurn playerConfusedCounter enemyConfusedCounter
  let memory := (install default entry bytes).write statusAddress (Byte.ofNat status.toNat)
  { registers := { (default : Registers) with pc := entry }
    memory := memory.write counterAddress (Byte.ofNat counter.toNat) }

private def confusionExpected (status counter : UInt8) : UInt8 × UInt8 × Nat :=
  if (status &&& 0x80) == 0 then (status, counter, 0)
  else
    let decremented := counter - 1
    if decremented == 0 then (status &&& 0x7F, 0, 2)
    else (status, decremented, 1)

private def confusionEnd (enemyTurn : Bool) (kind : Nat) : Word :=
  match kind with
  | 0 => sideAddress enemyTurn pConfusionNext eConfusionNext
  | 1 => sideAddress enemyTurn pConfusionActive eConfusionActive
  | _ => sideAddress enemyTurn pConfusionExpired eConfusionExpired

def confusionHolds (enemyTurn : Bool) (status counter : UInt8) : Bool :=
  let expected := confusionExpected status counter
  let endPc := confusionEnd enemyTurn expected.2.2
  let initial := confusionInitial enemyTurn status counter
  let result := Program.runUntil (fun state => state.registers.pc == endPc) 16 initial [] 0
  let final := Driver.finalState result
  let statusAddress := sideAddress enemyTurn playerStatus1 enemyStatus1
  let counterAddress := sideAddress enemyTurn playerConfusedCounter enemyConfusedCounter
  Driver.reachedReturn result && final.registers.pc == endPc &&
    Driver.toByte (final.memory.read statusAddress) == expected.1 &&
    Driver.toByte (final.memory.read counterAddress) == expected.2.1 &&
    physicalAgrees initial result endPc

private theorem confusion_matrix :
    (List.range 256).all (fun status =>
      confusionHolds false status.toUInt8 0 &&
      confusionHolds true status.toUInt8 0 &&
      confusionHolds false status.toUInt8 1 &&
      confusionHolds true status.toUInt8 1 &&
      confusionHolds false status.toUInt8 2 &&
      confusionHolds true status.toUInt8 2) = true := by
  native_decide

private theorem confusion_all_counters_matrix :
    (List.range 256).all (fun counter =>
      confusionHolds false 0x80 counter.toUInt8 &&
      confusionHolds true 0x80 counter.toUInt8 &&
      confusionHolds false 0xFF counter.toUInt8 &&
      confusionHolds true 0xFF counter.toUInt8) = true := by
  native_decide

/-- Confusion absence, zero-counter underflow, one-counter expiration, and the
active decrement path are exact for every raw status-1 byte. -/
theorem confusion_counter_boundaries_exact (enemyTurn : Bool) (status : UInt8) :
    confusionHolds enemyTurn status 0 = true ∧
      confusionHolds enemyTurn status 1 = true ∧
      confusionHolds enemyTurn status 2 = true := by
  have rows := List.all_eq_true.mp confusion_matrix status.toNat
    (List.mem_range.mpr status.toNat_lt)
  have round : status.toNat.toUInt8 = status := by
    apply UInt8.toNat.inj
    simp
  rw [round] at rows
  cases enemyTurn <;> simp_all

/-- Every possible counter byte, including zero underflow and malformed values,
executes the same decoded active-confusion transition on both duplicated sides.
`$80` and `$ff` jointly witness unrelated-bit preservation and expiration
masking; `confusion_counter_boundaries_exact` quantifies the raw status byte. -/
theorem confusion_all_counter_values_exact (enemyTurn : Bool) (counter : UInt8) :
    confusionHolds enemyTurn 0x80 counter = true ∧
      confusionHolds enemyTurn 0xFF counter = true := by
  have rows := List.all_eq_true.mp confusion_all_counters_matrix counter.toNat
    (List.mem_range.mpr counter.toNat_lt)
  have round : counter.toNat.toUInt8 = counter := by
    apply UInt8.toNat.inj
    simp
  rw [round] at rows
  cases enemyTurn <;> simp_all

/-! ## Full-paralysis and selected-disabled cleanup -/

private def interruptInitial (enemyTurn : Bool) (status other : UInt8) : FunctionalState :=
  let entry := sideAddress enemyTurn pInterrupt eInterrupt
  let bytes := if enemyTurn then eInterruptBytes else pInterruptBytes
  let acting := sideAddress enemyTurn playerStatus1 enemyStatus1
  let untouched := sideAddress enemyTurn enemyStatus1 playerStatus1
  let memory := (install default entry bytes).write acting (Byte.ofNat status.toNat)
  { registers := { (default : Registers) with pc := entry }
    memory := memory.write untouched (Byte.ofNat other.toNat) }

private def interruptEnd (enemyTurn : Bool) : Word :=
  sideAddress enemyTurn pInterruptEnd eInterruptEnd

def interruptHolds (enemyTurn : Bool) (status other : UInt8) : Bool :=
  let initial := interruptInitial enemyTurn status other
  let endPc := interruptEnd enemyTurn
  let result := Program.runUntil (fun state => state.registers.pc == endPc) 8 initial [] 0
  let final := Driver.finalState result
  let acting := sideAddress enemyTurn playerStatus1 enemyStatus1
  let untouched := sideAddress enemyTurn enemyStatus1 playerStatus1
  Driver.reachedReturn result && final.registers.pc == endPc &&
    Driver.toByte (final.memory.read acting) == (status &&& 0xCC) &&
    Driver.toByte (final.memory.read untouched) == other &&
    physicalAgrees initial result endPc

private def disabledClearInitial (enemyTurn : Bool)
    (status other : UInt8) : FunctionalState :=
  let memory := install default disabledClear disabledClearBytes
  let memory := memory.write hWhoseTurn (if enemyTurn then 1 else 0)
  let memory := memory.write playerStatus1
    (Byte.ofNat (if enemyTurn then other else status).toNat)
  let memory := memory.write enemyStatus1
    (Byte.ofNat (if enemyTurn then status else other).toNat)
  { registers := { (default : Registers) with pc := disabledClear }, memory }

def disabledClearHolds (enemyTurn : Bool) (status other : UInt8) : Bool :=
  let initial := disabledClearInitial enemyTurn status other
  let result := Program.runUntil (fun state => state.registers.pc == disabledClearEnd)
    12 initial [] 0
  let final := Driver.finalState result
  let acting := sideAddress enemyTurn playerStatus1 enemyStatus1
  let untouched := sideAddress enemyTurn enemyStatus1 playerStatus1
  Driver.reachedReturn result && final.registers.pc == disabledClearEnd &&
    Driver.toByte (final.memory.read acting) == (status &&& 0xEF) &&
    Driver.toByte (final.memory.read untouched) == other &&
    physicalAgrees initial result disabledClearEnd

private theorem cleanup_matrix :
    (List.range 256).all (fun raw =>
      interruptHolds false raw.toUInt8 0xA5 &&
      interruptHolds true raw.toUInt8 0xA5 &&
      disabledClearHolds false raw.toUInt8 0xA5 &&
      disabledClearHolds true raw.toUInt8 0xA5) = true := by
  native_decide

/-- Full paralysis/self-confusion's common tail applies `$cc`; selected Disable
applies `$ef` in `PrintMoveIsDisabledText`. Both duplicated sides and every raw
status byte execute identically in the functional and physical CPU models. -/
theorem interrupted_status_cleanup_exact (enemyTurn : Bool) (status : UInt8) :
    interruptHolds enemyTurn status 0xA5 = true ∧
      disabledClearHolds enemyTurn status 0xA5 = true := by
  have rows := List.all_eq_true.mp cleanup_matrix status.toNat
    (List.mem_range.mpr status.toNat_lt)
  have round : status.toNat.toUInt8 = status := by
    apply UInt8.toNat.inj
    simp
  rw [round] at rows
  cases enemyTurn <;> simp_all

/-- The machine masks and the independent high-level status transformers agree
exactly. Self-confusion's preceding `$80` mask is deliberately separate: it
clears invulnerability, unlike full paralysis and selected Disable. -/
theorem model_cleanup_matches_cartridge (volatile : Battle.Volatile) :
    (Full.Status.clearInterruptedLocks volatile).status1 = volatile.status1 &&& 0xCC ∧
      (Full.Status.clearDisabledCharge volatile).status1 = volatile.status1 &&& 0xEF ∧
      (Full.Status.prepareConfusionSelfHit volatile).status1 =
        volatile.status1 &&& 0x80 := by
  exact ⟨Full.Status.full_paralysis_status1_exact volatile,
    Full.Status.selected_disabled_status1_exact volatile,
    Full.Status.self_confusion_status1_exact volatile⟩

/-- Exact decoded operation and threshold constants for status control. -/
theorem decoded_status_gate_control :
    Decode.base (0xE6 : Byte) = .legal (.aluAImm .and) ∧
    Decode.base (0xFE : Byte) = .legal (.aluAImm .cp) ∧
    Decode.base (0x28 : Byte) = .legal (.jrCond .z) ∧
    Decode.base (0x30 : Byte) = .legal (.jrCond .nc) ∧
    Decode.cb (0x6E : Byte) = .bit ⟨5, by omega⟩ .atHL ∧
    Decode.cb (0x76 : Byte) = .bit ⟨6, by omega⟩ .atHL ∧
    Decode.cb (0x9E : Byte) = .res ⟨3, by omega⟩ .atHL ∧
    Decode.cb (0xAE : Byte) = .res ⟨5, by omega⟩ .atHL ∧
    Decode.cb (0xBE : Byte) = .res ⟨7, by omega⟩ .atHL ∧
    (0x3F : Byte).toNat = 63 ∧ (0x80 : Byte).toNat = 128 := by
  native_decide

structure RequiredStatusGateBytes (rom : Array Byte) : Prop where
  pSleep : Tables.tableBytes rom (romOffset 0x0F StatusGateRoutine.pSleep)
      pSleepBytes.length = pSleepBytes.map (fun byte => byte.toNat.toUInt8)
  eSleep : Tables.tableBytes rom (romOffset 0x0F StatusGateRoutine.eSleep)
      eSleepBytes.length = eSleepBytes.map (fun byte => byte.toNat.toUInt8)
  pFreeze : Tables.tableBytes rom (romOffset 0x0F 0x5884) pFreezeBytes.length =
      pFreezeBytes.map (fun byte => byte.toNat.toUInt8)
  eFreeze : Tables.tableBytes rom (romOffset 0x0F 0x68BF) eFreezeBytes.length =
      eFreezeBytes.map (fun byte => byte.toNat.toUInt8)
  pTrap : Tables.tableBytes rom (romOffset 0x0F 0x5898) pTrapBytes.length =
      pTrapBytes.map (fun byte => byte.toNat.toUInt8)
  eTrap : Tables.tableBytes rom (romOffset 0x0F 0x68D3) eTrapBytes.length =
      eTrapBytes.map (fun byte => byte.toNat.toUInt8)
  pFlinch : Tables.tableBytes rom (romOffset 0x0F StatusGateRoutine.pFlinch)
      pFlinchBytes.length = pFlinchBytes.map (fun byte => byte.toNat.toUInt8)
  eFlinch : Tables.tableBytes rom (romOffset 0x0F StatusGateRoutine.eFlinch)
      eFlinchBytes.length = eFlinchBytes.map (fun byte => byte.toNat.toUInt8)
  pRecharge : Tables.tableBytes rom (romOffset 0x0F StatusGateRoutine.pRecharge)
      pRechargeBytes.length = pRechargeBytes.map (fun byte => byte.toNat.toUInt8)
  eRecharge : Tables.tableBytes rom (romOffset 0x0F StatusGateRoutine.eRecharge)
      eRechargeBytes.length = eRechargeBytes.map (fun byte => byte.toNat.toUInt8)
  pDisable : Tables.tableBytes rom (romOffset 0x0F StatusGateRoutine.pDisable)
      pDisableBytes.length = pDisableBytes.map (fun byte => byte.toNat.toUInt8)
  eDisable : Tables.tableBytes rom (romOffset 0x0F StatusGateRoutine.eDisable)
      eDisableBytes.length = eDisableBytes.map (fun byte => byte.toNat.toUInt8)
  pConfusion : Tables.tableBytes rom (romOffset 0x0F StatusGateRoutine.pConfusion)
      pConfusionBytes.length = pConfusionBytes.map (fun byte => byte.toNat.toUInt8)
  eConfusion : Tables.tableBytes rom (romOffset 0x0F StatusGateRoutine.eConfusion)
      eConfusionBytes.length = eConfusionBytes.map (fun byte => byte.toNat.toUInt8)
  pConfusionRandom : Tables.tableBytes rom (romOffset 0x0F 0x5916)
      pConfusionRandomBytes.length = pConfusionRandomBytes.map (fun byte => byte.toNat.toUInt8)
  eConfusionRandom : Tables.tableBytes rom (romOffset 0x0F 0x6953)
      eConfusionRandomBytes.length = eConfusionRandomBytes.map (fun byte => byte.toNat.toUInt8)
  pDisabledCheck : Tables.tableBytes rom (romOffset 0x0F 0x5929)
      pDisabledCheckBytes.length = pDisabledCheckBytes.map (fun byte => byte.toNat.toUInt8)
  eDisabledCheck : Tables.tableBytes rom (romOffset 0x0F 0x69AA)
      eDisabledCheckBytes.length = eDisabledCheckBytes.map (fun byte => byte.toNat.toUInt8)
  pParalysis : Tables.tableBytes rom (romOffset 0x0F 0x593E)
      pParalysisBytes.length = pParalysisBytes.map (fun byte => byte.toNat.toUInt8)
  eParalysis : Tables.tableBytes rom (romOffset 0x0F 0x69BF)
      eParalysisBytes.length = eParalysisBytes.map (fun byte => byte.toNat.toUInt8)
  pInterrupt : Tables.tableBytes rom (romOffset 0x0F StatusGateRoutine.pInterrupt)
      pInterruptBytes.length = pInterruptBytes.map (fun byte => byte.toNat.toUInt8)
  eInterrupt : Tables.tableBytes rom (romOffset 0x0F StatusGateRoutine.eInterrupt)
      eInterruptBytes.length = eInterruptBytes.map (fun byte => byte.toNat.toUInt8)
  disabledClear : Tables.tableBytes rom (romOffset 0x0F StatusGateRoutine.disabledClear)
      disabledClearBytes.length = disabledClearBytes.map (fun byte => byte.toNat.toUInt8)

structure CanonicalStatusGateBytes (sha256 : Sha256) (rom : CanonicalRom) : Prop where
  identity : rom.Valid sha256
  statusGate : RequiredStatusGateBytes rom.bytes

private def agrees (rom : Array Byte) (entry : Word) (bytes : List Byte) : Bool :=
  decide (Tables.tableBytes rom (romOffset 0x0F entry) bytes.length =
    bytes.map (fun byte => byte.toNat.toUInt8))

def windowAgrees (rom : Array Byte) : Bool :=
  agrees rom pSleep pSleepBytes && agrees rom eSleep eSleepBytes &&
  agrees rom 0x5884 pFreezeBytes && agrees rom 0x68BF eFreezeBytes &&
  agrees rom 0x5898 pTrapBytes && agrees rom 0x68D3 eTrapBytes &&
  agrees rom pFlinch pFlinchBytes && agrees rom eFlinch eFlinchBytes &&
  agrees rom pRecharge pRechargeBytes && agrees rom eRecharge eRechargeBytes &&
  agrees rom pDisable pDisableBytes && agrees rom eDisable eDisableBytes &&
  agrees rom pConfusion pConfusionBytes && agrees rom eConfusion eConfusionBytes &&
  agrees rom 0x5916 pConfusionRandomBytes && agrees rom 0x6953 eConfusionRandomBytes &&
  agrees rom 0x5929 pDisabledCheckBytes && agrees rom 0x69AA eDisabledCheckBytes &&
  agrees rom 0x593E pParalysisBytes && agrees rom 0x69BF eParalysisBytes &&
  agrees rom pInterrupt pInterruptBytes && agrees rom eInterrupt eInterruptBytes &&
  agrees rom disabledClear disabledClearBytes

end Battle.Rom.StatusGateRoutine
