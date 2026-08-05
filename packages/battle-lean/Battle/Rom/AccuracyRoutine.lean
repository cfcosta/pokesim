/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Rom.EffectRoutines
import Battle.Accuracy
import Sm83.FlatAdapter

/-!
# Final move-accuracy comparison

`CalcHitChance` supplies the scaled byte in `B`; `BattleRandom` supplies the raw
byte in `A`. This module executes the exact call-free `cp b; jr nc` branch that
decides hit versus miss. It proves the strict boundary responsible for the
Generation-I 1/256 miss at effective accuracy `$ff`.
-/

namespace Battle.Rom.AccuracyRoutine

open Sm83 Battle.Rom.Closure

private def compareEntry : Word := 0x6605
private def hitReturn : Word := 0x6608
private def missEntry : Word := 0x6609

/-- Includes the hit-path `ret`; the branch proof stops immediately before the
selected hit or miss continuation executes. -/
private def compareBytes : List Byte := [0xB8, 0x30, 0x01, 0xC9]

private def install : FlatMemory → Word → List Byte → FlatMemory
  | memory, _, [] => memory
  | memory, address, byte :: rest =>
      install (memory.write address byte) (Word.ofNat (address.toNat + 1)) rest

private def initial (effectiveAccuracy random : UInt8) : FunctionalState :=
  { registers := {
      a := Byte.ofNat random.toNat
      b := Byte.ofNat effectiveAccuracy.toNat
      pc := compareEntry }
    memory := install ((default : FlatMemory).write missEntry 0xAF)
      compareEntry compareBytes }

private def stop (state : FunctionalState) : Bool :=
  state.registers.pc == hitReturn || state.registers.pc == missEntry

private def run (effectiveAccuracy random : UInt8) : Program.RunResult :=
  Program.runUntil stop 3 (initial effectiveAccuracy random) [] 0

private def traceOf : Program.RunResult → List BusEvent
  | .reached _ trace _ | .halted _ trace _ | .stopped _ trace _ |
      .locked _ trace _ | .fuelExhausted _ trace _ => trace

private def stepsOf : Program.RunResult → Nat
  | .reached _ _ steps | .halted _ _ steps | .stopped _ _ steps |
      .locked _ _ steps | .fuelExhausted _ _ steps => steps

private def reachedExpected (effectiveAccuracy random : UInt8) :
    Program.RunResult → Bool
  | .reached state _ _ =>
      state.registers.pc ==
        (if Accuracy.hits effectiveAccuracy random then hitReturn else missEntry)
  | _ => false

/-- Exact functional result for one effective-accuracy/random pair. -/
def comparatorSummaryHolds (effectiveAccuracy random : UInt8) : Bool :=
  let result := run effectiveAccuracy random
  let final := Driver.finalState result
  reachedExpected effectiveAccuracy random result &&
    stepsOf result == 2 &&
    Driver.toByte final.registers.a == random &&
    Driver.toByte final.registers.b == effectiveAccuracy

private def exhaustive : Bool :=
  (List.range 256).all fun accuracy =>
    (List.range 256).all fun random =>
      comparatorSummaryHolds accuracy.toUInt8 random.toUInt8

private theorem exhaustive_exact : exhaustive = true := by native_decide

/-- Universal strict-comparison agreement for all 65,536 byte pairs. -/
theorem comparator_exact (effectiveAccuracy random : UInt8) :
    comparatorSummaryHolds effectiveAccuracy random = true := by
  have accuracies := List.all_eq_true.mp exhaustive_exact
  have accuracy := accuracies effectiveAccuracy.toNat
    (List.mem_range.mpr (UInt8.toNat_lt effectiveAccuracy))
  have randoms := List.all_eq_true.mp accuracy
  have both := randoms random.toNat (List.mem_range.mpr (UInt8.toNat_lt random))
  have accuracyRound : effectiveAccuracy.toNat.toUInt8 = effectiveAccuracy := by
    apply UInt8.toNat.inj
    simp
  have randomRound : random.toNat.toUInt8 = random := by
    apply UInt8.toNat.inj
    simp
  simpa only [accuracyRound, randomRound] using both

/-- Direct machine witness for the famous maximum-accuracy `$ff` roll miss. -/
theorem one_in_256_machine_witness :
    comparatorSummaryHolds 0xFF 0xFF = true ∧ Accuracy.hits 0xFF 0xFF = false := by
  native_decide

private def physicalInitial (state : FunctionalState) : FlatCoreState :=
  { core := {
      Pipeline.bootstrap state.registers with
      ime := state.ime
      scheduledImeEnable := state.scheduledImeEnable
      haltBug := state.haltBug }
    memory := state.memory }

/-- Continuous fetched-IR execution through one successor-fetch overlap. -/
def physicalComparatorSummaryHolds (effectiveAccuracy random : UInt8) : Bool :=
  let functional := run effectiveAccuracy random
  let before := initial effectiveAccuracy random
  let expected := traceOf functional
  let final := Driver.finalState functional
  let successor : Byte := if final.registers.pc == hitReturn then 0xC9 else 0xAF
  let physical := FlatAdapter.run (expected.length + 1) (physicalInitial before)
    (fun _ _ => 0)
  let projected := FlatAdapter.project physical
  comparatorSummaryHolds effectiveAccuracy random &&
    physical.trace == expected ++ [.read .opcode final.registers.pc successor] &&
    projected.registers == final.registers && projected.mode == .running &&
    physical.core.boundaryPC.isSome

private def physicalExhaustive : Bool :=
  (List.range 256).all fun accuracy =>
    (List.range 256).all fun random =>
      physicalComparatorSummaryHolds accuracy.toUInt8 random.toUInt8

private theorem physical_exhaustive_exact : physicalExhaustive = true := by
  native_decide

/-- Universal physical fetched-IR agreement for the branch. -/
theorem comparator_physical_exact (effectiveAccuracy random : UInt8) :
    physicalComparatorSummaryHolds effectiveAccuracy random = true := by
  have accuracies := List.all_eq_true.mp physical_exhaustive_exact
  have accuracy := accuracies effectiveAccuracy.toNat
    (List.mem_range.mpr (UInt8.toNat_lt effectiveAccuracy))
  have randoms := List.all_eq_true.mp accuracy
  have both := randoms random.toNat (List.mem_range.mpr (UInt8.toNat_lt random))
  have accuracyRound : effectiveAccuracy.toNat.toUInt8 = effectiveAccuracy := by
    apply UInt8.toNat.inj
    simp
  have randomRound : random.toNat.toUInt8 = random := by
    apply UInt8.toNat.inj
    simp
  simpa only [accuracyRound, randomRound] using both

structure RequiredAccuracyBytes (rom : Array Byte) : Prop where
  compareWindow : Tables.tableBytes rom (romOffset 0x0F compareEntry)
      compareBytes.length = compareBytes.map (fun byte => byte.toNat.toUInt8)

structure CanonicalAccuracyBytes (sha256 : Sha256) (rom : CanonicalRom) : Prop where
  mechanics : Mechanics.CanonicalMechanicsBytes sha256 rom
  accuracy : RequiredAccuracyBytes rom.bytes

/-- Hash-bound exact branch bytes plus functional and physical universal
agreement with `Battle.Accuracy.hits`. -/
theorem canonical_accuracy_comparator_exact {sha256 : Sha256} {rom : CanonicalRom}
    (certificate : CanonicalAccuracyBytes sha256 rom) :
    Tables.tableBytes rom.bytes (romOffset 0x0F compareEntry)
        compareBytes.length = compareBytes.map (fun byte => byte.toNat.toUInt8) ∧
      (∀ effectiveAccuracy random,
        comparatorSummaryHolds effectiveAccuracy random = true) ∧
      ∀ effectiveAccuracy random,
        physicalComparatorSummaryHolds effectiveAccuracy random = true :=
  ⟨certificate.accuracy.compareWindow, comparator_exact, comparator_physical_exact⟩

/-- Runtime fixture predicate; theorem callers still provide exact byte witnesses. -/
def windowAgrees (rom : Array Byte) : Bool :=
  decide (Tables.tableBytes rom (romOffset 0x0F compareEntry)
    compareBytes.length = compareBytes.map (fun byte => byte.toNat.toUInt8))

end Battle.Rom.AccuracyRoutine
