/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Rom.Mechanics
import Battle.Driver

/-!
# Decoded leaf effect-routine executions

Hyper Beam and Rage end in small, call-free routines. This module executes their
canonical instruction bytes through the verified de-overlapped SM83 functional
core and checks the complete ordered M-cycle bus trace for both acting sides and
all 65,536 pairs of input status bytes.

This is a leaf-routine result, not yet a proof that the physical fetched-IR Game
Boy adapter reaches the entry checkpoint during a whole battle.
-/

namespace Battle.Rom.EffectRoutines

open Sm83 Battle.Rom.Closure

private def wPlayerBattleStatus2 : Word := 0xD063
private def wEnemyBattleStatus2 : Word := 0xD068
private def hWhoseTurn : Word := 0xFFF3
private def sentinel : Word := 0x8000
private def stackTop : UInt16 := 0xFFFE

structure Leaf where
  entry : UInt16
  bytes : List Byte
  setOpcode : Byte
  mask : UInt8
  deriving Repr, DecidableEq

def hyperBeam : Leaf :=
  { entry := 0x79C1
    bytes := [0x21, 0x63, 0xD0, 0xF0, 0xF3, 0xA7, 0x28, 0x03,
      0x21, 0x68, 0xD0, 0xCB, 0xEE, 0xC9]
    setOpcode := 0xEE
    mask := 0x20 }

def rage : Leaf :=
  { entry := 0x79DF
    bytes := [0x21, 0x63, 0xD0, 0xF0, 0xF3, 0xA7, 0x28, 0x03,
      0x21, 0x68, 0xD0, 0xCB, 0xF6, 0xC9]
    setOpcode := 0xF6
    mask := 0x40 }

private def installBytes : FlatMemory → Word → List Byte → FlatMemory
  | memory, _, [] => memory
  | memory, address, byte :: rest =>
      installBytes (memory.write address byte)
        (Word.ofNat (address.toNat + 1)) rest

private def initialMemoryWith (leaf : Leaf) (code : List Byte) (enemyTurn : Bool)
    (playerStatus enemyStatus : UInt8) : FlatMemory :=
  let memory := installBytes default (Word.ofNat leaf.entry.toNat) code
  let memory := memory.write hWhoseTurn (if enemyTurn then 1 else 0)
  let memory := memory.write wPlayerBattleStatus2 (Byte.ofNat playerStatus.toNat)
  memory.write wEnemyBattleStatus2 (Byte.ofNat enemyStatus.toNat)

private def runWith (leaf : Leaf) (code : List Byte) (enemyTurn : Bool)
    (playerStatus enemyStatus : UInt8) : Program.RunResult :=
  Driver.runToReturn
    (Driver.setupCall (initialMemoryWith leaf code enemyTurn playerStatus enemyStatus)
      leaf.entry sentinel.toNat.toUInt16 stackTop)
    sentinel.toNat.toUInt16 8

private def traceOf : Program.RunResult → List BusEvent
  | .reached _ trace _ | .halted _ trace _ | .stopped _ trace _ |
      .locked _ trace _ | .fuelExhausted _ trace _ => trace

private def stepsOf : Program.RunResult → Nat
  | .reached _ _ steps | .halted _ _ steps | .stopped _ _ steps |
      .locked _ _ steps | .fuelExhausted _ _ steps => steps

private def opcodeAddress (leaf : Leaf) (delta : Nat) : Word :=
  Word.ofNat (leaf.entry.toNat + delta)

/-- Exact bus events for the six-instruction player path or seven-instruction
enemy path. Opcode, immediate, data, write, branch-idle, stack, and return-idle
cycles remain distinguished and ordered. -/
def expectedTrace (leaf : Leaf) (enemyTurn : Bool)
    (playerStatus enemyStatus : UInt8) : List BusEvent :=
  let entry := leaf.entry.toNat
  let whose : Byte := if enemyTurn then 1 else 0
  let selected := if enemyTurn then enemyStatus else playerStatus
  let target := if enemyTurn then wEnemyBattleStatus2 else wPlayerBattleStatus2
  let initialEvents : List BusEvent :=
    [ .read .opcode (Word.ofNat entry) 0x21,
      .read .immediate (Word.ofNat (entry + 1)) 0x63,
      .read .immediate (Word.ofNat (entry + 2)) 0xD0,
      .read .opcode (Word.ofNat (entry + 3)) 0xF0,
      .read .immediate (Word.ofNat (entry + 4)) 0xF3,
      .read .data hWhoseTurn whose,
      .read .opcode (Word.ofNat (entry + 5)) 0xA7,
      .read .opcode (Word.ofNat (entry + 6)) 0x28,
      .read .immediate (Word.ofNat (entry + 7)) 0x03 ]
  let branch : List BusEvent := if enemyTurn then
    [ .read .opcode (Word.ofNat (entry + 8)) 0x21,
      .read .immediate (Word.ofNat (entry + 9)) 0x68,
      .read .immediate (Word.ofNat (entry + 10)) 0xD0 ]
    else [.idle (Word.ofNat (entry + 8))]
  initialEvents ++ branch ++
    [ .read .opcode (Word.ofNat (entry + 11)) 0xCB,
      .read .cbOpcode (Word.ofNat (entry + 12)) leaf.setOpcode,
      .read .data target (Byte.ofNat selected.toNat),
      .write target (Byte.ofNat (selected.toNat ||| leaf.mask.toNat)),
      .read .opcode (Word.ofNat (entry + 13)) 0xC9,
      .read .stack 0xFFFC 0x00,
      .read .stack 0xFFFD 0x80,
      .idle sentinel ]

/-- Executable summary over one complete pair of input status bytes. -/
def summaryHoldsWith (leaf : Leaf) (code : List Byte) (enemyTurn : Bool)
    (playerStatus enemyStatus : UInt8) : Bool :=
  let result := runWith leaf code enemyTurn playerStatus enemyStatus
  let final := Driver.finalState result
  let expectedPlayer := if enemyTurn then playerStatus else playerStatus ||| leaf.mask
  let expectedEnemy := if enemyTurn then enemyStatus ||| leaf.mask else enemyStatus
  Driver.reachedReturn result &&
    stepsOf result == (if enemyTurn then 7 else 6) &&
    traceOf result == expectedTrace leaf enemyTurn playerStatus enemyStatus &&
    final.registers.pc == sentinel && final.registers.sp == Word.ofNat stackTop.toNat &&
    Driver.toByte (final.memory.read wPlayerBattleStatus2) == expectedPlayer &&
    Driver.toByte (final.memory.read wEnemyBattleStatus2) == expectedEnemy

/-- Summary instantiated with the independently stated canonical byte window. -/
def summaryHolds (leaf : Leaf) (enemyTurn : Bool)
    (playerStatus enemyStatus : UInt8) : Bool :=
  summaryHoldsWith leaf leaf.bytes enemyTurn playerStatus enemyStatus

private def decodedBytes (rom : Array Byte) (leaf : Leaf) : List Byte :=
  (Tables.tableBytes rom (romOffset 0x0F (Word.ofNat leaf.entry.toNat))
    leaf.bytes.length).map fun byte => Byte.ofNat byte.toNat

/-- The same summary, but the executed instruction list is decoded from the
caller-supplied ROM window. -/
def decodedSummaryHolds (rom : Array Byte) (leaf : Leaf) (enemyTurn : Bool)
    (playerStatus enemyStatus : UInt8) : Bool :=
  summaryHoldsWith leaf (decodedBytes rom leaf) enemyTurn playerStatus enemyStatus

private def exhaustive (leaf : Leaf) : Bool :=
  (List.range 256).all fun player =>
    (List.range 256).all fun enemy =>
      summaryHolds leaf false player.toUInt8 enemy.toUInt8 &&
        summaryHolds leaf true player.toUInt8 enemy.toUInt8

private theorem exhaustive_hyperBeam : exhaustive hyperBeam = true := by
  native_decide

private theorem exhaustive_rage : exhaustive rage = true := by
  native_decide

private theorem of_exhaustive {leaf : Leaf} (checked : exhaustive leaf = true)
    (enemyTurn : Bool) (playerStatus enemyStatus : UInt8) :
    summaryHolds leaf enemyTurn playerStatus enemyStatus = true := by
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

/-- Hyper Beam universally sets only the acting side's recharge bit and follows
the exact 18/20-M-cycle player/enemy trace. -/
theorem hyperBeam_exact (enemyTurn : Bool) (playerStatus enemyStatus : UInt8) :
    summaryHolds hyperBeam enemyTurn playerStatus enemyStatus = true :=
  of_exhaustive exhaustive_hyperBeam enemyTurn playerStatus enemyStatus

/-- Rage universally sets only the acting side's Rage bit and follows the exact
18/20-M-cycle player/enemy trace. -/
theorem rage_exact (enemyTurn : Bool) (playerStatus enemyStatus : UInt8) :
    summaryHolds rage enemyTurn playerStatus enemyStatus = true :=
  of_exhaustive exhaustive_rage enemyTurn playerStatus enemyStatus

/-- Caller-supplied canonical byte windows connect the executable routines to
the hash-identified ROM rather than to handwritten assembly. -/
structure RequiredLeafBytes (rom : Array Byte) : Prop where
  hyperBeamWindow : Tables.tableBytes rom
    (romOffset 0x0F (Word.ofNat hyperBeam.entry.toNat)) hyperBeam.bytes.length =
      hyperBeam.bytes.map (fun byte => byte.toNat.toUInt8)
  rageWindow : Tables.tableBytes rom
    (romOffset 0x0F (Word.ofNat rage.entry.toNat)) rage.bytes.length =
      rage.bytes.map (fun byte => byte.toNat.toUInt8)

structure CanonicalLeafEffectsBytes (sha256 : Sha256) (rom : CanonicalRom) : Prop where
  mechanics : Mechanics.CanonicalMechanicsBytes sha256 rom
  leaves : RequiredLeafBytes rom.bytes

/-- Hash identity and exact routine windows are carried together with both
universal cycle-trace summaries. -/
theorem canonical_leaf_effects_exact {sha256 : Sha256} {rom : CanonicalRom}
    (certificate : CanonicalLeafEffectsBytes sha256 rom) :
    Tables.tableBytes rom.bytes
        (romOffset 0x0F (Word.ofNat hyperBeam.entry.toNat)) hyperBeam.bytes.length =
          hyperBeam.bytes.map (fun byte => byte.toNat.toUInt8) ∧
      Tables.tableBytes rom.bytes
        (romOffset 0x0F (Word.ofNat rage.entry.toNat)) rage.bytes.length =
          rage.bytes.map (fun byte => byte.toNat.toUInt8) ∧
      (∀ enemyTurn playerStatus enemyStatus,
        decodedSummaryHolds rom.bytes hyperBeam enemyTurn playerStatus enemyStatus = true) ∧
      ∀ enemyTurn playerStatus enemyStatus,
        decodedSummaryHolds rom.bytes rage enemyTurn playerStatus enemyStatus = true := by
  have hyperBytes : decodedBytes rom.bytes hyperBeam = hyperBeam.bytes := by
    simp only [decodedBytes, certificate.leaves.hyperBeamWindow, List.map_map]
    native_decide
  have rageBytes : decodedBytes rom.bytes rage = rage.bytes := by
    simp only [decodedBytes, certificate.leaves.rageWindow, List.map_map]
    native_decide
  refine ⟨certificate.leaves.hyperBeamWindow, certificate.leaves.rageWindow, ?_, ?_⟩
  · intro enemyTurn playerStatus enemyStatus
    simpa [decodedSummaryHolds, hyperBytes, summaryHolds] using
      hyperBeam_exact enemyTurn playerStatus enemyStatus
  · intro enemyTurn playerStatus enemyStatus
    simpa [decodedSummaryHolds, rageBytes, summaryHolds] using
      rage_exact enemyTurn playerStatus enemyStatus

/-- Runtime equivalent used by the temporary canonical-ROM fixture only. -/
def leafWindowsAgree (rom : Array Byte) : Bool :=
  decide (Tables.tableBytes rom
      (romOffset 0x0F (Word.ofNat hyperBeam.entry.toNat)) hyperBeam.bytes.length =
        hyperBeam.bytes.map (fun byte => byte.toNat.toUInt8)) &&
    decide (Tables.tableBytes rom
      (romOffset 0x0F (Word.ofNat rage.entry.toNat)) rage.bytes.length =
        rage.bytes.map (fun byte => byte.toNat.toUInt8))

end Battle.Rom.EffectRoutines
