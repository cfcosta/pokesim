/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Rom.EffectRoutines

/-!
# Decoded mechanics prefixes for presentation-tailed effects

Focus Energy and Mist commit their only mechanics mutation before entering
animation/text code. We execute each canonical prefix to one of two exact PCs:
the presentation call boundary after a new bit is set, or the already-active
failure presentation boundary.
-/

namespace Battle.Rom.EffectPrefixes

open Sm83 Battle.Rom.Closure

private def wPlayerBattleStatus2 : Word := 0xD063
private def wEnemyBattleStatus2 : Word := 0xD068
private def hWhoseTurn : Word := 0xFFF3

structure Prefix where
  entry : UInt16
  bytes : List Byte
  bitOpcode : Byte
  mask : UInt8
  successOpcode : Byte
  failureOpcode : Byte
  deriving Repr, DecidableEq

def focusEnergy : Prefix :=
  { entry := 0x7F86
    bytes := [0x21, 0x63, 0xD0, 0xF0, 0xF3, 0xA7, 0x28, 0x03,
      0x21, 0x68, 0xD0, 0xCB, 0x56, 0x20, 0x10, 0xCB, 0xD6]
    bitOpcode := 0x56
    mask := 0x04
    successOpcode := 0x21
    failureOpcode := 0x0E }

def mist : Prefix :=
  { entry := 0x7F2B
    bytes := [0x21, 0x63, 0xD0, 0xF0, 0xF3, 0xA7, 0x28, 0x03,
      0x21, 0x68, 0xD0, 0xCB, 0x4E, 0x20, 0x10, 0xCB, 0xCE]
    bitOpcode := 0x4E
    mask := 0x02
    successOpcode := 0x21
    failureOpcode := 0x21 }

private def installBytes : FlatMemory → Word → List Byte → FlatMemory
  | memory, _, [] => memory
  | memory, address, byte :: rest =>
      installBytes (memory.write address byte) (Word.ofNat (address.toNat + 1)) rest

private def initialMemory (spec : Prefix) (enemyTurn : Bool)
    (playerStatus enemyStatus : UInt8) : FlatMemory :=
  let memory := installBytes default (Word.ofNat spec.entry.toNat) spec.bytes
  let memory := memory.write (Word.ofNat (spec.entry.toNat + 17)) spec.successOpcode
  let memory := memory.write (Word.ofNat (spec.entry.toNat + 31)) spec.failureOpcode
  let memory := memory.write hWhoseTurn (if enemyTurn then 1 else 0)
  let memory := memory.write wPlayerBattleStatus2 (Byte.ofNat playerStatus.toNat)
  memory.write wEnemyBattleStatus2 (Byte.ofNat enemyStatus.toNat)

private def before (spec : Prefix) (enemyTurn : Bool)
    (playerStatus enemyStatus : UInt8) : FunctionalState :=
  { registers := { pc := Word.ofNat spec.entry.toNat }
    memory := initialMemory spec enemyTurn playerStatus enemyStatus }

private def stop (spec : Prefix) (state : FunctionalState) : Bool :=
  state.registers.pc == Word.ofNat (spec.entry.toNat + 17) ||
    state.registers.pc == Word.ofNat (spec.entry.toNat + 31)

private def run (spec : Prefix) (enemyTurn : Bool)
    (playerStatus enemyStatus : UInt8) : Program.RunResult :=
  Program.runUntil (stop spec) 10 (before spec enemyTurn playerStatus enemyStatus) [] 0

private def traceOf : Program.RunResult → List BusEvent
  | .reached _ trace _ | .halted _ trace _ | .stopped _ trace _ |
      .locked _ trace _ | .fuelExhausted _ trace _ => trace

private def stepsOf : Program.RunResult → Nat
  | .reached _ _ steps | .halted _ _ steps | .stopped _ _ steps |
      .locked _ _ steps | .fuelExhausted _ _ steps => steps

private def expectedTrace (spec : Prefix) (enemyTurn : Bool)
    (playerStatus enemyStatus : UInt8) : List BusEvent :=
  let entry := spec.entry.toNat
  let whose : Byte := if enemyTurn then 1 else 0
  let selected := if enemyTurn then enemyStatus else playerStatus
  let target := if enemyTurn then wEnemyBattleStatus2 else wPlayerBattleStatus2
  let setAlready := selected &&& spec.mask != 0
  let initial : List BusEvent :=
    [ .read .opcode (Word.ofNat entry) 0x21,
      .read .immediate (Word.ofNat (entry + 1)) 0x63,
      .read .immediate (Word.ofNat (entry + 2)) 0xD0,
      .read .opcode (Word.ofNat (entry + 3)) 0xF0,
      .read .immediate (Word.ofNat (entry + 4)) 0xF3,
      .read .data hWhoseTurn whose,
      .read .opcode (Word.ofNat (entry + 5)) 0xA7,
      .read .opcode (Word.ofNat (entry + 6)) 0x28,
      .read .immediate (Word.ofNat (entry + 7)) 0x03 ]
  let sideBranch : List BusEvent := if enemyTurn then
    [ .read .opcode (Word.ofNat (entry + 8)) 0x21,
      .read .immediate (Word.ofNat (entry + 9)) 0x68,
      .read .immediate (Word.ofNat (entry + 10)) 0xD0 ]
    else [.idle (Word.ofNat (entry + 8))]
  let test : List BusEvent :=
    [ .read .opcode (Word.ofNat (entry + 11)) 0xCB,
      .read .cbOpcode (Word.ofNat (entry + 12)) spec.bitOpcode,
      .read .data target (Byte.ofNat selected.toNat),
      .read .opcode (Word.ofNat (entry + 13)) 0x20,
      .read .immediate (Word.ofNat (entry + 14)) 0x10 ]
  let finish : List BusEvent := if setAlready then
    [.idle (Word.ofNat (entry + 15))]
  else
    [ .read .opcode (Word.ofNat (entry + 15)) 0xCB,
      .read .cbOpcode (Word.ofNat (entry + 16)) (spec.bitOpcode ||| 0x80),
      .read .data target (Byte.ofNat selected.toNat),
      .write target (Byte.ofNat (selected.toNat ||| spec.mask.toNat)) ]
  initial ++ sideBranch ++ test ++ finish

private def summaryHolds (spec : Prefix) (enemyTurn : Bool)
    (playerStatus enemyStatus : UInt8) : Bool :=
  let result := run spec enemyTurn playerStatus enemyStatus
  let final := Driver.finalState result
  let selected := if enemyTurn then enemyStatus else playerStatus
  let already := selected &&& spec.mask != 0
  let expectedPlayer := if enemyTurn || already then playerStatus else playerStatus ||| spec.mask
  let expectedEnemy := if !enemyTurn || already then enemyStatus else enemyStatus ||| spec.mask
  Driver.reachedReturn result &&
    stepsOf result == (if already then (if enemyTurn then 7 else 6)
      else if enemyTurn then 8 else 7) &&
    traceOf result == expectedTrace spec enemyTurn playerStatus enemyStatus &&
    final.registers.pc == Word.ofNat (spec.entry.toNat + if already then 31 else 17) &&
    Driver.toByte (final.memory.read wPlayerBattleStatus2) == expectedPlayer &&
    Driver.toByte (final.memory.read wEnemyBattleStatus2) == expectedEnemy

/-! ## Continuous flat fetched-IR lifting -/

private def physicalInitial (state : FunctionalState) : FlatCoreState :=
  { core := {
      Pipeline.bootstrap state.registers with
      ime := state.ime
      scheduledImeEnable := state.scheduledImeEnable
      haltBug := state.haltBug }
    memory := state.memory }

private def physicalSummaryHolds (spec : Prefix) (enemyTurn : Bool)
    (playerStatus enemyStatus : UInt8) : Bool :=
  let functional := run spec enemyTurn playerStatus enemyStatus
  let initial := before spec enemyTurn playerStatus enemyStatus
  let expected := expectedTrace spec enemyTurn playerStatus enemyStatus
  let final := Driver.finalState functional
  let successor := if final.registers.pc == Word.ofNat (spec.entry.toNat + 17) then
    spec.successOpcode else spec.failureOpcode
  let physical := FlatAdapter.run (expected.length + 1) (physicalInitial initial)
    (fun _ _ => 0)
  let projected := FlatAdapter.project physical
  Driver.reachedReturn functional &&
    physical.trace == expected ++ [.read .opcode final.registers.pc successor] &&
    projected.registers == final.registers && projected.mode == .running &&
    physical.core.boundaryPC.isSome &&
    Driver.toByte (physical.memory.read wPlayerBattleStatus2) ==
      Driver.toByte (final.memory.read wPlayerBattleStatus2) &&
    Driver.toByte (physical.memory.read wEnemyBattleStatus2) ==
      Driver.toByte (final.memory.read wEnemyBattleStatus2)

private def exhaustive (spec : Prefix) : Bool :=
  (List.range 256).all fun player =>
    (List.range 256).all fun enemy =>
      summaryHolds spec false player.toUInt8 enemy.toUInt8 &&
        summaryHolds spec true player.toUInt8 enemy.toUInt8

private theorem exhaustive_focus : exhaustive focusEnergy = true := by native_decide
private theorem exhaustive_mist : exhaustive mist = true := by native_decide

private def physicalExhaustive (spec : Prefix) : Bool :=
  (List.range 256).all fun player =>
    (List.range 256).all fun enemy =>
      physicalSummaryHolds spec false player.toUInt8 enemy.toUInt8 &&
        physicalSummaryHolds spec true player.toUInt8 enemy.toUInt8

private theorem physical_exhaustive_focus : physicalExhaustive focusEnergy = true := by
  native_decide
private theorem physical_exhaustive_mist : physicalExhaustive mist = true := by
  native_decide

private theorem of_exhaustive {spec : Prefix} (checked : exhaustive spec = true)
    (enemyTurn : Bool) (playerStatus enemyStatus : UInt8) :
    summaryHolds spec enemyTurn playerStatus enemyStatus = true := by
  have players := List.all_eq_true.mp checked
  have player := players playerStatus.toNat
    (List.mem_range.mpr (UInt8.toNat_lt playerStatus))
  have enemies := List.all_eq_true.mp player
  have both := enemies enemyStatus.toNat
    (List.mem_range.mpr (UInt8.toNat_lt enemyStatus))
  have playerRound : playerStatus.toNat.toUInt8 = playerStatus := by
    apply UInt8.toNat.inj
    simp
  have enemyRound : enemyStatus.toNat.toUInt8 = enemyStatus := by
    apply UInt8.toNat.inj
    simp
  simp only [playerRound, enemyRound] at both
  cases enemyTurn <;> simp_all

private theorem physical_of_exhaustive {spec : Prefix}
    (checked : physicalExhaustive spec = true) (enemyTurn : Bool)
    (playerStatus enemyStatus : UInt8) :
    physicalSummaryHolds spec enemyTurn playerStatus enemyStatus = true := by
  have players := List.all_eq_true.mp checked
  have player := players playerStatus.toNat
    (List.mem_range.mpr (UInt8.toNat_lt playerStatus))
  have enemies := List.all_eq_true.mp player
  have both := enemies enemyStatus.toNat
    (List.mem_range.mpr (UInt8.toNat_lt enemyStatus))
  have playerRound : playerStatus.toNat.toUInt8 = playerStatus := by
    apply UInt8.toNat.inj
    simp
  have enemyRound : enemyStatus.toNat.toUInt8 = enemyStatus := by
    apply UInt8.toNat.inj
    simp
  simp only [playerRound, enemyRound] at both
  cases enemyTurn <;> simp_all

/-- Universal decoded Focus Energy mechanics prefix. -/
theorem focusEnergy_exact (enemyTurn : Bool) (playerStatus enemyStatus : UInt8) :
    summaryHolds focusEnergy enemyTurn playerStatus enemyStatus = true :=
  of_exhaustive exhaustive_focus enemyTurn playerStatus enemyStatus

/-- Universal decoded Mist mechanics prefix. -/
theorem mist_exact (enemyTurn : Bool) (playerStatus enemyStatus : UInt8) :
    summaryHolds mist enemyTurn playerStatus enemyStatus = true :=
  of_exhaustive exhaustive_mist enemyTurn playerStatus enemyStatus

/-- Continuous fetched-IR Focus Energy prefix with one successor overlap. -/
theorem focusEnergy_physical_exact (enemyTurn : Bool)
    (playerStatus enemyStatus : UInt8) :
    physicalSummaryHolds focusEnergy enemyTurn playerStatus enemyStatus = true :=
  physical_of_exhaustive physical_exhaustive_focus enemyTurn playerStatus enemyStatus

/-- Continuous fetched-IR Mist prefix with one successor overlap. -/
theorem mist_physical_exact (enemyTurn : Bool) (playerStatus enemyStatus : UInt8) :
    physicalSummaryHolds mist enemyTurn playerStatus enemyStatus = true :=
  physical_of_exhaustive physical_exhaustive_mist enemyTurn playerStatus enemyStatus

structure RequiredPrefixBytes (rom : Array Byte) : Prop where
  focusWindow : Tables.tableBytes rom
    (romOffset 0x09 (Word.ofNat focusEnergy.entry.toNat)) focusEnergy.bytes.length =
      focusEnergy.bytes.map (fun byte => byte.toNat.toUInt8)
  mistWindow : Tables.tableBytes rom
    (romOffset 0x0C (Word.ofNat mist.entry.toNat)) mist.bytes.length =
      mist.bytes.map (fun byte => byte.toNat.toUInt8)

structure CanonicalEffectPrefixBytes (sha256 : Sha256) (rom : CanonicalRom) : Prop where
  leaves : EffectRoutines.CanonicalLeafEffectsBytes sha256 rom
  prefixes : RequiredPrefixBytes rom.bytes

/-- Hash identity, exact windows, and universal mechanics-prefix summaries. -/
theorem canonical_effect_prefixes_exact {sha256 : Sha256} {rom : CanonicalRom}
    (certificate : CanonicalEffectPrefixBytes sha256 rom) :
    Tables.tableBytes rom.bytes
        (romOffset 0x09 (Word.ofNat focusEnergy.entry.toNat)) focusEnergy.bytes.length =
          focusEnergy.bytes.map (fun byte => byte.toNat.toUInt8) ∧
      Tables.tableBytes rom.bytes
        (romOffset 0x0C (Word.ofNat mist.entry.toNat)) mist.bytes.length =
          mist.bytes.map (fun byte => byte.toNat.toUInt8) ∧
      (∀ enemyTurn playerStatus enemyStatus,
        summaryHolds focusEnergy enemyTurn playerStatus enemyStatus = true) ∧
      (∀ enemyTurn playerStatus enemyStatus,
        summaryHolds mist enemyTurn playerStatus enemyStatus = true) ∧
      (∀ enemyTurn playerStatus enemyStatus,
        physicalSummaryHolds focusEnergy enemyTurn playerStatus enemyStatus = true) ∧
      ∀ enemyTurn playerStatus enemyStatus,
        physicalSummaryHolds mist enemyTurn playerStatus enemyStatus = true :=
  ⟨certificate.prefixes.focusWindow, certificate.prefixes.mistWindow,
    focusEnergy_exact, mist_exact, focusEnergy_physical_exact, mist_physical_exact⟩

/-- Runtime fixture predicate only. -/
def prefixWindowsAgree (rom : Array Byte) : Bool :=
  decide (Tables.tableBytes rom
      (romOffset 0x09 (Word.ofNat focusEnergy.entry.toNat)) focusEnergy.bytes.length =
        focusEnergy.bytes.map (fun byte => byte.toNat.toUInt8)) &&
    decide (Tables.tableBytes rom
      (romOffset 0x0C (Word.ofNat mist.entry.toNat)) mist.bytes.length =
        mist.bytes.map (fun byte => byte.toNat.toUInt8))

end Battle.Rom.EffectPrefixes
