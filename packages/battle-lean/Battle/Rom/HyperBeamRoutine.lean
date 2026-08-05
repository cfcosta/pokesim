/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Rom.EffectRoutines
import Sm83.FlatAdapter

/-!
# Hyper Beam post-damage faint guard

Generation I does not encode "skip recharge on KO" inside `HyperBeamEffect`.
The effect is absent from `AlwaysHappenSideEffects`; after those effects run,
the player and enemy attack paths read the target's two-byte HP and return
immediately when it is zero. Only a surviving target reaches the later
remaining-effect dispatch that can call `HyperBeamEffect`.

This module executes both exact HP-check/conditional-return windows. Together
with the decoded phase table and the existing exact `HyperBeamEffect` leaf, it
proves the cartridge control-flow reason for the KO exception rather than
postulating an unrelated Hyper Beam special case.
-/

namespace Battle.Rom.HyperBeamRoutine

open Sm83 Battle.Rom.Closure

private def wPlayerBattleStatus2 : Word := 0xD063
private def wEnemyBattleStatus2 : Word := 0xD068
private def sentinel : Word := 0x8000
private def stackTop : UInt16 := 0xFFFE

structure FaintGuard where
  entry : UInt16
  targetHp : UInt16
  bytes : List Byte
  deriving Repr, DecidableEq

/-- `MirrorMoveCheck.notDone` after always-happen effects, player attacking. -/
def playerGuard : FaintGuard :=
  { entry := 0x57C8
    targetHp := 0xCFE6
    bytes := [0x21, 0xE6, 0xCF, 0x2A, 0x46, 0xB0, 0xC8] }

/-- `EnemyCheckIfMirrorMoveEffect.handleExplosionMiss`, enemy attacking. -/
def enemyGuard : FaintGuard :=
  { entry := 0x684D
    targetHp := 0xD015
    bytes := [0x21, 0x15, 0xD0, 0x2A, 0x46, 0xB0, 0xC8] }

private def guard (enemyTurn : Bool) : FaintGuard :=
  if enemyTurn then enemyGuard else playerGuard

private def installBytes : FlatMemory → Word → List Byte → FlatMemory
  | memory, _, [] => memory
  | memory, address, byte :: rest =>
      installBytes (memory.write address byte)
        (Word.ofNat (address.toNat + 1)) rest

private def initialMemoryWith (spec : FaintGuard) (code : List Byte)
    (playerStatus enemyStatus : UInt8) : FlatMemory :=
  let memory := installBytes default (Word.ofNat spec.entry.toNat) code
  let memory := memory.write (Word.ofNat spec.targetHp.toNat) 0
  let memory := memory.write (Word.ofNat (spec.targetHp.toNat + 1)) 0
  let memory := memory.write wPlayerBattleStatus2 (Byte.ofNat playerStatus.toNat)
  memory.write wEnemyBattleStatus2 (Byte.ofNat enemyStatus.toNat)

private def runWith (spec : FaintGuard) (code : List Byte)
    (playerStatus enemyStatus : UInt8) : Program.RunResult :=
  Driver.runToReturn
    (Driver.setupCall (initialMemoryWith spec code playerStatus enemyStatus)
      spec.entry sentinel.toNat.toUInt16 stackTop)
    sentinel.toNat.toUInt16 6

private def traceOf : Program.RunResult → List BusEvent
  | .reached _ trace _ | .halted _ trace _ | .stopped _ trace _ |
      .locked _ trace _ | .fuelExhausted _ trace _ => trace

private def stepsOf : Program.RunResult → Nat
  | .reached _ _ steps | .halted _ _ steps | .stopped _ _ steps |
      .locked _ _ steps | .fuelExhausted _ _ steps => steps

/-- Exact trace of the zero-HP path. In particular, it contains no write to
battle status, and the conditional return occurs before remaining effects. -/
def expectedFaintTrace (spec : FaintGuard) : List BusEvent :=
  let entry := spec.entry.toNat
  let hp := Word.ofNat spec.targetHp.toNat
  [ .read .opcode (Word.ofNat entry) 0x21,
    .read .immediate (Word.ofNat (entry + 1)) hp.lowByte,
    .read .immediate (Word.ofNat (entry + 2)) hp.highByte,
    .read .opcode (Word.ofNat (entry + 3)) 0x2A,
    .read .data hp 0,
    .read .opcode (Word.ofNat (entry + 4)) 0x46,
    .read .data (Word.ofNat (spec.targetHp.toNat + 1)) 0,
    .read .opcode (Word.ofNat (entry + 5)) 0xB0,
    .read .opcode (Word.ofNat (entry + 6)) 0xC8,
    .idle 0xFFFC,
    .read .stack 0xFFFC 0,
    .read .stack 0xFFFD 0x80,
    .idle sentinel ]

/-- Functional-core summary of one exact zero-HP guard execution. Both recharge
status bytes are universally preserved. -/
def faintGuardSummaryHoldsWith (spec : FaintGuard) (code : List Byte)
    (playerStatus enemyStatus : UInt8) : Bool :=
  let result := runWith spec code playerStatus enemyStatus
  let final := Driver.finalState result
  Driver.reachedReturn result &&
    stepsOf result == 5 &&
    traceOf result == expectedFaintTrace spec &&
    final.registers.pc == sentinel && final.registers.sp == Word.ofNat stackTop.toNat &&
    Driver.toByte (final.memory.read wPlayerBattleStatus2) == playerStatus &&
    Driver.toByte (final.memory.read wEnemyBattleStatus2) == enemyStatus

/-- Summary instantiated with the independently stated canonical bytes. -/
def faintGuardSummaryHolds (enemyTurn : Bool)
    (playerStatus enemyStatus : UInt8) : Bool :=
  let spec := guard enemyTurn
  faintGuardSummaryHoldsWith spec spec.bytes playerStatus enemyStatus

private def decodedBytes (rom : Array Byte) (spec : FaintGuard) : List Byte :=
  (Tables.tableBytes rom (romOffset 0x0F (Word.ofNat spec.entry.toNat))
    spec.bytes.length).map fun byte => Byte.ofNat byte.toNat

/-- The same summary with instructions decoded from caller-supplied ROM bytes. -/
def decodedFaintGuardSummaryHolds (rom : Array Byte) (enemyTurn : Bool)
    (playerStatus enemyStatus : UInt8) : Bool :=
  let spec := guard enemyTurn
  faintGuardSummaryHoldsWith spec (decodedBytes rom spec) playerStatus enemyStatus

private def physicalInitial (state : FunctionalState) : FlatCoreState :=
  { core := {
      Pipeline.bootstrap state.registers with
      ime := state.ime
      scheduledImeEnable := state.scheduledImeEnable
      haltBug := state.haltBug }
    memory := state.memory }

/-- Continuous fetched-IR version, including one successor fetch after return. -/
def physicalFaintGuardSummaryHolds (enemyTurn : Bool)
    (playerStatus enemyStatus : UInt8) : Bool :=
  let spec := guard enemyTurn
  let functional := runWith spec spec.bytes playerStatus enemyStatus
  let before := Driver.setupCall
    (initialMemoryWith spec spec.bytes playerStatus enemyStatus)
    spec.entry sentinel.toNat.toUInt16 stackTop
  let expected := expectedFaintTrace spec
  let physical := FlatAdapter.run (expected.length + 1) (physicalInitial before)
    (fun _ _ => 0)
  let projected := FlatAdapter.project physical
  Driver.reachedReturn functional &&
    physical.trace == expected ++ [.read .opcode sentinel 0] &&
    projected.registers == (Driver.finalState functional).registers &&
    projected.mode == .running && physical.core.boundaryPC.isSome &&
    Driver.toByte (physical.memory.read wPlayerBattleStatus2) == playerStatus &&
    Driver.toByte (physical.memory.read wEnemyBattleStatus2) == enemyStatus

private def exhaustive : Bool :=
  (List.range 256).all fun player =>
    (List.range 256).all fun enemy =>
      faintGuardSummaryHolds false player.toUInt8 enemy.toUInt8 &&
        faintGuardSummaryHolds true player.toUInt8 enemy.toUInt8

private theorem exhaustive_exact : exhaustive = true := by native_decide

private def physicalExhaustive : Bool :=
  (List.range 256).all fun player =>
    (List.range 256).all fun enemy =>
      physicalFaintGuardSummaryHolds false player.toUInt8 enemy.toUInt8 &&
        physicalFaintGuardSummaryHolds true player.toUInt8 enemy.toUInt8

private theorem physical_exhaustive_exact : physicalExhaustive = true := by
  native_decide

private theorem of_exhaustive (enemyTurn : Bool)
    (playerStatus enemyStatus : UInt8) :
    faintGuardSummaryHolds enemyTurn playerStatus enemyStatus = true := by
  have players := List.all_eq_true.mp exhaustive_exact
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

private theorem physical_of_exhaustive (enemyTurn : Bool)
    (playerStatus enemyStatus : UInt8) :
    physicalFaintGuardSummaryHolds enemyTurn playerStatus enemyStatus = true := by
  have players := List.all_eq_true.mp physical_exhaustive_exact
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

/-- Both cartridge attack paths universally return on zero target HP while
preserving both sides' status-2 bytes. -/
theorem faint_guard_exact (enemyTurn : Bool)
    (playerStatus enemyStatus : UInt8) :
    faintGuardSummaryHolds enemyTurn playerStatus enemyStatus = true :=
  of_exhaustive enemyTurn playerStatus enemyStatus

/-- The same result through continuous physical fetched-IR execution. -/
theorem faint_guard_physical_exact (enemyTurn : Bool)
    (playerStatus enemyStatus : UInt8) :
    physicalFaintGuardSummaryHolds enemyTurn playerStatus enemyStatus = true :=
  physical_of_exhaustive enemyTurn playerStatus enemyStatus

structure RequiredFaintGuardBytes (rom : Array Byte) : Prop where
  playerWindow : Tables.tableBytes rom
    (romOffset 0x0F (Word.ofNat playerGuard.entry.toNat)) playerGuard.bytes.length =
      playerGuard.bytes.map (fun byte => byte.toNat.toUInt8)
  enemyWindow : Tables.tableBytes rom
    (romOffset 0x0F (Word.ofNat enemyGuard.entry.toNat)) enemyGuard.bytes.length =
      enemyGuard.bytes.map (fun byte => byte.toNat.toUInt8)

structure CanonicalHyperBeamBytes (sha256 : Sha256) (rom : CanonicalRom) : Prop where
  leaves : EffectRoutines.CanonicalLeafEffectsBytes sha256 rom
  guards : RequiredFaintGuardBytes rom.bytes

/-- Hash identity, phase-table membership, both HP guards, and the effect leaf
jointly prove the ROM's Hyper Beam rule: the zero-HP path returns before the
remaining-effect tail, while that tail sets recharge whenever it is reached. -/
theorem canonical_hyperBeam_faint_skip_exact {sha256 : Sha256} {rom : CanonicalRom}
    (certificate : CanonicalHyperBeamBytes sha256 rom) :
    Effects.decodePhase rom.bytes Symbols.alwaysHappenSideEffects =
        some (Effects.expectedPhase .always) ∧
      (Effects.expectedPhase .always).contains Data.Effect.hyperBeam = false ∧
      (∀ enemyTurn playerStatus enemyStatus,
        decodedFaintGuardSummaryHolds rom.bytes enemyTurn playerStatus enemyStatus = true) ∧
      (∀ enemyTurn playerStatus enemyStatus,
        physicalFaintGuardSummaryHolds enemyTurn playerStatus enemyStatus = true) ∧
      ∀ enemyTurn playerStatus enemyStatus,
        EffectRoutines.decodedSummaryHolds rom.bytes EffectRoutines.hyperBeam
          enemyTurn playerStatus enemyStatus = true := by
  have phases := Mechanics.phase_tables_exact certificate.leaves.mechanics
  have leaves := EffectRoutines.canonical_leaf_effects_exact certificate.leaves
  have playerBytes : decodedBytes rom.bytes playerGuard = playerGuard.bytes := by
    simp only [decodedBytes, certificate.guards.playerWindow, List.map_map]
    native_decide
  have enemyBytes : decodedBytes rom.bytes enemyGuard = enemyGuard.bytes := by
    simp only [decodedBytes, certificate.guards.enemyWindow, List.map_map]
    native_decide
  refine ⟨phases.2.2.2.1, by native_decide, ?_, faint_guard_physical_exact,
    leaves.2.2.2.1⟩
  intro enemyTurn playerStatus enemyStatus
  cases enemyTurn
  · simpa [decodedFaintGuardSummaryHolds, guard, playerBytes] using
      faint_guard_exact false playerStatus enemyStatus
  · simpa [decodedFaintGuardSummaryHolds, guard, enemyBytes] using
      faint_guard_exact true playerStatus enemyStatus

/-- Runtime fixture predicate; theorem callers still supply exact byte witnesses. -/
def windowAgrees (rom : Array Byte) : Bool :=
  decide (Tables.tableBytes rom
      (romOffset 0x0F (Word.ofNat playerGuard.entry.toNat)) playerGuard.bytes.length =
        playerGuard.bytes.map (fun byte => byte.toNat.toUInt8)) &&
    decide (Tables.tableBytes rom
      (romOffset 0x0F (Word.ofNat enemyGuard.entry.toNat)) enemyGuard.bytes.length =
        enemyGuard.bytes.map (fun byte => byte.toNat.toUInt8))

end Battle.Rom.HyperBeamRoutine
