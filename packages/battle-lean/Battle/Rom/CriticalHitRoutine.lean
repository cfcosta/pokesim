/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Rom.EffectRoutines
import Battle.Critical
import Sm83.FlatAdapter

/-!
# Critical-hit ROM arithmetic

The full `CriticalHitTest` wrapper loads species data and obtains randomness
through external routines. The two call-free mechanics kernels are retained and
executed here: threshold construction from the already-loaded base Speed, move,
and Focus Energy flag; and the post-`BattleRandom` rotate/compare/store tail.
Together they cover the wrong-direction Focus Energy shift, the high-critical
move table, saturating doubles, three-bit random rotation, and strict boundary.
-/

namespace Battle.Rom.CriticalHitRoutine

open Sm83 Battle.Rom.Closure

private def thresholdEntry : Word := 0x604F
private def randomTailEntry : Word := 0x6080
private def randomCall : Word := 0x607D
private def highCriticalTable : Word := 0x608E
private def moveNumber : Word := 0xCFD2
private def movePower : Word := 0xCFD4
private def status2 : Word := 0xD063
private def criticalFlag : Word := 0xD05E
private def sentinel : Word := 0x8000
private def stackTop : UInt16 := 0xFFFE

/-- From `.calcCriticalHitProbability` up to the `BattleRandom` call boundary. -/
private def thresholdBytes : List Byte :=
  [0x3A, 0xA7, 0xC8, 0x2B, 0x4E, 0x1A, 0xCB, 0x57,
   0x20, 0x08, 0xCB, 0x20, 0x30, 0x06, 0x06, 0xFF,
   0x18, 0x02, 0xCB, 0x38, 0x21, 0x8E, 0x60, 0x2A,
   0xB9, 0x28, 0x07, 0x3C, 0x20, 0xF9, 0xCB, 0x38,
   0x18, 0x0C, 0xCB, 0x20, 0x30, 0x02, 0x06, 0xFF,
   0xCB, 0x20, 0x30, 0x02, 0x06, 0xFF]

private def highCriticalBytes : List Byte := [0x02, 0x4B, 0x98, 0xA3, 0xFF]

/-- Instructions immediately after `BattleRandom` returns. -/
private def randomTailBytes : List Byte :=
  [0xCB, 0x07, 0xCB, 0x07, 0xCB, 0x07, 0xB8, 0xD0,
   0x3E, 0x01, 0xEA, 0x5E, 0xD0, 0xC9]

private def install : FlatMemory → Word → List Byte → FlatMemory
  | memory, _, [] => memory
  | memory, address, byte :: rest =>
      install (memory.write address byte) (Word.ofNat (address.toNat + 1)) rest

private def reachedAt (target : Word) : Program.RunResult → Bool
  | .reached state _ _ => state.registers.pc == target
  | _ => false

private def traceOf : Program.RunResult → List BusEvent
  | .reached _ trace _ | .halted _ trace _ | .stopped _ trace _ |
      .locked _ trace _ | .fuelExhausted _ trace _ => trace

private def thresholdInitial (baseSpeed move : UInt8)
    (focusEnergy : Bool) : FunctionalState :=
  let memory := install default thresholdEntry thresholdBytes
  let memory := install memory highCriticalTable highCriticalBytes
  let memory := memory.write movePower 1
  let memory := memory.write moveNumber (Byte.ofNat move.toNat)
  let memory := memory.write status2 (if focusEnergy then 0x04 else 0)
  let state := Driver.setupCall memory thresholdEntry.toNat.toUInt16
    sentinel.toNat.toUInt16 stackTop
  let registers := (state.registers.setHL movePower).setDE status2
  { state with registers := { registers with
      b := Byte.ofNat ((baseSpeed >>> 1).toNat) } }

private def thresholdRun (baseSpeed move : UInt8)
    (focusEnergy : Bool) : Program.RunResult :=
  Program.runUntil (fun state => state.registers.pc == randomCall) 40
    (thresholdInitial baseSpeed move focusEnergy) [] 0

/-- Exact threshold-kernel agreement for one base-Speed/move/focus tuple. -/
def thresholdSummaryHolds (baseSpeed move : UInt8) (focusEnergy : Bool) : Bool :=
  let result := thresholdRun baseSpeed move focusEnergy
  let final := Driver.finalState result
  reachedAt randomCall result &&
    Driver.toByte final.registers.b ==
      Critical.thresholdFromSpeed baseSpeed (Critical.highCriticalLookupMatch move) focusEnergy &&
    Driver.toByte (final.memory.read moveNumber) == move &&
    Driver.toByte (final.memory.read movePower) == 1 &&
    Driver.toByte (final.memory.read status2) == (if focusEnergy then 0x04 else 0)

private def thresholdExhaustive : Bool :=
  (List.range 256).all fun speed =>
    (List.range 256).all fun move =>
      thresholdSummaryHolds speed.toUInt8 move.toUInt8 false &&
        thresholdSummaryHolds speed.toUInt8 move.toUInt8 true

private theorem threshold_exhaustive_exact : thresholdExhaustive = true := by
  native_decide

/-- Universal ROM-kernel threshold agreement, including the Focus Energy bug. -/
theorem threshold_exact (baseSpeed move : UInt8) (focusEnergy : Bool) :
    thresholdSummaryHolds baseSpeed move focusEnergy = true := by
  have speeds := List.all_eq_true.mp threshold_exhaustive_exact
  have speed := speeds baseSpeed.toNat
    (List.mem_range.mpr (UInt8.toNat_lt baseSpeed))
  have moves := List.all_eq_true.mp speed
  have both := moves move.toNat (List.mem_range.mpr (UInt8.toNat_lt move))
  have speedRound : baseSpeed.toNat.toUInt8 = baseSpeed := by
    apply UInt8.toNat.inj
    simp
  have moveRound : move.toNat.toUInt8 = move := by
    apply UInt8.toNat.inj
    simp
  simp only [speedRound, moveRound] at both
  cases focusEnergy <;> simp_all

private def randomTailInitial (threshold raw initialFlag : UInt8) : FunctionalState :=
  let memory := install default randomTailEntry randomTailBytes
  let memory := memory.write criticalFlag (Byte.ofNat initialFlag.toNat)
  let state := Driver.setupCall memory randomTailEntry.toNat.toUInt16
    sentinel.toNat.toUInt16 stackTop
  { state with registers := { state.registers with
      a := Byte.ofNat raw.toNat
      b := Byte.ofNat threshold.toNat } }

private def randomTailRun (threshold raw initialFlag : UInt8) : Program.RunResult :=
  Driver.runToReturn (randomTailInitial threshold raw initialFlag)
    sentinel.toNat.toUInt16 10

/-- Exact post-random tail: strict rotated-byte comparison and acting flag write. -/
def randomTailSummaryHolds (threshold raw initialFlag : UInt8) : Bool :=
  let result := randomTailRun threshold raw initialFlag
  let final := Driver.finalState result
  let expected := if Critical.occurs threshold raw then 1 else initialFlag
  Driver.reachedReturn result &&
    Driver.toByte (final.memory.read criticalFlag) == expected &&
    final.registers.pc == sentinel && final.registers.sp == Word.ofNat stackTop.toNat

private def randomTailExhaustive : Bool :=
  (List.range 256).all fun threshold =>
    (List.range 256).all fun raw =>
      randomTailSummaryHolds threshold.toUInt8 raw.toUInt8 0

private theorem random_tail_exhaustive_exact : randomTailExhaustive = true := by
  native_decide

/-- Universal strict critical comparison. Equality is a non-critical result. -/
theorem random_tail_exact (threshold raw : UInt8) :
    randomTailSummaryHolds threshold raw 0 = true := by
  have thresholds := List.all_eq_true.mp random_tail_exhaustive_exact
  have atThreshold := thresholds threshold.toNat
    (List.mem_range.mpr (UInt8.toNat_lt threshold))
  have raws := List.all_eq_true.mp atThreshold
  have atRaw := raws raw.toNat (List.mem_range.mpr (UInt8.toNat_lt raw))
  have thresholdRound : threshold.toNat.toUInt8 = threshold := by
    apply UInt8.toNat.inj
    simp
  have rawRound : raw.toNat.toUInt8 = raw := by
    apply UInt8.toNat.inj
    simp
  simpa only [thresholdRound, rawRound] using atRaw

private def physicalInitial (state : FunctionalState) : FlatCoreState :=
  { core := {
      Pipeline.bootstrap state.registers with
      ime := state.ime
      scheduledImeEnable := state.scheduledImeEnable
      haltBug := state.haltBug }
    memory := state.memory }

/-- Continuous fetched-IR lifting of the post-random tail. -/
def physicalRandomTailSummaryHolds (threshold raw : UInt8) : Bool :=
  let functional := randomTailRun threshold raw 0
  let before := randomTailInitial threshold raw 0
  let expected := traceOf functional
  let physical := FlatAdapter.run (expected.length + 1) (physicalInitial before)
    (fun _ _ => 0)
  let projected := FlatAdapter.project physical
  Driver.reachedReturn functional &&
    physical.trace == expected ++ [.read .opcode sentinel 0] &&
    projected.registers == (Driver.finalState functional).registers &&
    projected.mode == .running && physical.core.boundaryPC.isSome &&
    Driver.toByte (physical.memory.read criticalFlag) ==
      Driver.toByte ((Driver.finalState functional).memory.read criticalFlag)

private def physicalRandomTailExhaustive : Bool :=
  (List.range 256).all fun threshold =>
    (List.range 256).all fun raw =>
      physicalRandomTailSummaryHolds threshold.toUInt8 raw.toUInt8

private theorem physical_random_tail_exhaustive :
    physicalRandomTailExhaustive = true := by
  native_decide

/-- Physical fetched-IR execution agrees for every threshold/random pair. -/
theorem random_tail_physical_exact (threshold raw : UInt8) :
    physicalRandomTailSummaryHolds threshold raw = true := by
  have thresholds := List.all_eq_true.mp physical_random_tail_exhaustive
  have atThreshold := thresholds threshold.toNat
    (List.mem_range.mpr (UInt8.toNat_lt threshold))
  have raws := List.all_eq_true.mp atThreshold
  have atRaw := raws raw.toNat (List.mem_range.mpr (UInt8.toNat_lt raw))
  have thresholdRound : threshold.toNat.toUInt8 = threshold := by
    apply UInt8.toNat.inj
    simp
  have rawRound : raw.toNat.toUInt8 = raw := by
    apply UInt8.toNat.inj
    simp
  simpa only [thresholdRound, rawRound] using atRaw

structure RequiredCriticalHitBytes (rom : Array Byte) : Prop where
  thresholdWindow : Tables.tableBytes rom (romOffset 0x0F thresholdEntry)
      thresholdBytes.length = thresholdBytes.map (fun byte => byte.toNat.toUInt8)
  highCriticalWindow : Tables.tableBytes rom (romOffset 0x0F highCriticalTable)
      highCriticalBytes.length = highCriticalBytes.map (fun byte => byte.toNat.toUInt8)
  randomTailWindow : Tables.tableBytes rom (romOffset 0x0F randomTailEntry)
      randomTailBytes.length = randomTailBytes.map (fun byte => byte.toNat.toUInt8)

structure CanonicalCriticalHitBytes (sha256 : Sha256) (rom : CanonicalRom) : Prop where
  mechanics : Mechanics.CanonicalMechanicsBytes sha256 rom
  critical : RequiredCriticalHitBytes rom.bytes

/-- Hash-bound ROM windows and universal model agreement for both call-free
critical-hit kernels. -/
theorem canonical_critical_hit_exact {sha256 : Sha256} {rom : CanonicalRom}
    (certificate : CanonicalCriticalHitBytes sha256 rom) :
    Tables.tableBytes rom.bytes (romOffset 0x0F thresholdEntry)
        thresholdBytes.length = thresholdBytes.map (fun byte => byte.toNat.toUInt8) ∧
      Tables.tableBytes rom.bytes (romOffset 0x0F highCriticalTable)
        highCriticalBytes.length = highCriticalBytes.map (fun byte => byte.toNat.toUInt8) ∧
      Tables.tableBytes rom.bytes (romOffset 0x0F randomTailEntry)
        randomTailBytes.length = randomTailBytes.map (fun byte => byte.toNat.toUInt8) ∧
      (∀ baseSpeed move focusEnergy,
        thresholdSummaryHolds baseSpeed move focusEnergy = true) ∧
      (∀ threshold raw, randomTailSummaryHolds threshold raw 0 = true) ∧
      ∀ threshold raw, physicalRandomTailSummaryHolds threshold raw = true :=
  ⟨certificate.critical.thresholdWindow, certificate.critical.highCriticalWindow,
    certificate.critical.randomTailWindow, threshold_exact, random_tail_exact,
    random_tail_physical_exact⟩

/-- Runtime fixture predicate; theorem callers still provide byte witnesses. -/
def windowAgrees (rom : Array Byte) : Bool :=
  decide (Tables.tableBytes rom (romOffset 0x0F thresholdEntry)
      thresholdBytes.length = thresholdBytes.map (fun byte => byte.toNat.toUInt8)) &&
    decide (Tables.tableBytes rom (romOffset 0x0F highCriticalTable)
      highCriticalBytes.length = highCriticalBytes.map (fun byte => byte.toNat.toUInt8)) &&
    decide (Tables.tableBytes rom (romOffset 0x0F randomTailEntry)
      randomTailBytes.length = randomTailBytes.map (fun byte => byte.toNat.toUInt8))

end Battle.Rom.CriticalHitRoutine
