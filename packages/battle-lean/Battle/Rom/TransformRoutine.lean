/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Rom.LeechSeedRoutine

/-!
# Decoded Transform invulnerability prefix

The handler overwrites its initial target-status load with `hWhoseTurn`. Enemy
Transform therefore tests bit 6 of byte one and always passes; player Transform
reloads and tests the player's own status-1 byte rather than the target's. This
module proves that control prefix through the copy or failure boundary.
-/

namespace Battle.Rom.TransformRoutine

open Sm83 Battle.Rom.Closure

private def entry : UInt16 := 0x7AB1
private def bytes : List Byte :=
  [0x21, 0x14, 0xD0, 0x11, 0xE5, 0xCF, 0x01, 0x69, 0xD0,
   0xFA, 0x67, 0xD0, 0xF0, 0xF3, 0xA7, 0x20, 0x0F, 0x21,
   0xE5, 0xCF, 0x11, 0x14, 0xD0, 0x01, 0x64, 0xD0, 0xEA,
   0x2E, 0xCC, 0xFA, 0x62, 0xD0, 0xCB, 0x77, 0xC2, 0x8C,
   0x7B]
private def successPc : Word := 0x7AD6
private def failurePc : Word := 0x7B8C
private def hWhoseTurn : Word := 0xFFF3
private def playerStatus1 : Word := 0xD062
private def enemyStatus1 : Word := 0xD067
private def playerMoveListIndex : Word := 0xCC2E

private def install : FlatMemory → Word → List Byte → FlatMemory
  | memory, _, [] => memory
  | memory, address, byte :: rest =>
      install (memory.write address byte) (Word.ofNat (address.toNat + 1)) rest

private def memory (enemyTurn playerInvulnerable : Bool) : FlatMemory :=
  let memory := install default (Word.ofNat entry.toNat) bytes
  let memory := memory.write successPc 0xE5
  let memory := memory.write failurePc 0x0E
  let memory := memory.write hWhoseTurn (if enemyTurn then 1 else 0)
  let memory := memory.write enemyStatus1 0x40
  let memory := memory.write playerStatus1 (if playerInvulnerable then 0x40 else 0)
  memory.write playerMoveListIndex 0xA5

private def before (enemyTurn playerInvulnerable : Bool) : FunctionalState :=
  { registers := { pc := Word.ofNat entry.toNat }
    memory := memory enemyTurn playerInvulnerable }

private def stop (state : FunctionalState) : Bool :=
  state.registers.pc == successPc || state.registers.pc == failurePc

private def run (enemyTurn playerInvulnerable : Bool) : Program.RunResult :=
  Program.runUntil stop 16 (before enemyTurn playerInvulnerable) [] 0

private def traceOf : Program.RunResult → List BusEvent
  | .reached _ trace _ | .halted _ trace _ | .stopped _ trace _ |
      .locked _ trace _ | .fuelExhausted _ trace _ => trace

private def stepsOf : Program.RunResult → Nat
  | .reached _ _ count | .halted _ _ count | .stopped _ _ count |
      .locked _ _ count | .fuelExhausted _ _ count => count

private def expectedTrace (enemyTurn playerInvulnerable : Bool) : List BusEvent :=
  let base := entry.toNat
  let whose : Byte := if enemyTurn then 1 else 0
  let initial : List BusEvent :=
    [ .read .opcode (Word.ofNat base) 0x21,
      .read .immediate (Word.ofNat (base + 1)) 0x14,
      .read .immediate (Word.ofNat (base + 2)) 0xD0,
      .read .opcode (Word.ofNat (base + 3)) 0x11,
      .read .immediate (Word.ofNat (base + 4)) 0xE5,
      .read .immediate (Word.ofNat (base + 5)) 0xCF,
      .read .opcode (Word.ofNat (base + 6)) 0x01,
      .read .immediate (Word.ofNat (base + 7)) 0x69,
      .read .immediate (Word.ofNat (base + 8)) 0xD0,
      .read .opcode (Word.ofNat (base + 9)) 0xFA,
      .read .immediate (Word.ofNat (base + 10)) 0x67,
      .read .immediate (Word.ofNat (base + 11)) 0xD0,
      .read .data enemyStatus1 0x40,
      .read .opcode (Word.ofNat (base + 12)) 0xF0,
      .read .immediate (Word.ofNat (base + 13)) 0xF3,
      .read .data hWhoseTurn whose,
      .read .opcode (Word.ofNat (base + 14)) 0xA7,
      .read .opcode (Word.ofNat (base + 15)) 0x20,
      .read .immediate (Word.ofNat (base + 16)) 0x0F ]
  let side : List BusEvent := if enemyTurn then
    [.idle (Word.ofNat (base + 17))]
  else
    [ .read .opcode (Word.ofNat (base + 17)) 0x21,
      .read .immediate (Word.ofNat (base + 18)) 0xE5,
      .read .immediate (Word.ofNat (base + 19)) 0xCF,
      .read .opcode (Word.ofNat (base + 20)) 0x11,
      .read .immediate (Word.ofNat (base + 21)) 0x14,
      .read .immediate (Word.ofNat (base + 22)) 0xD0,
      .read .opcode (Word.ofNat (base + 23)) 0x01,
      .read .immediate (Word.ofNat (base + 24)) 0x64,
      .read .immediate (Word.ofNat (base + 25)) 0xD0,
      .read .opcode (Word.ofNat (base + 26)) 0xEA,
      .read .immediate (Word.ofNat (base + 27)) 0x2E,
      .read .immediate (Word.ofNat (base + 28)) 0xCC,
      .write playerMoveListIndex 0,
      .read .opcode (Word.ofNat (base + 29)) 0xFA,
      .read .immediate (Word.ofNat (base + 30)) 0x62,
      .read .immediate (Word.ofNat (base + 31)) 0xD0,
      .read .data playerStatus1 (if playerInvulnerable then 0x40 else 0) ]
  let test : List BusEvent :=
    [ .read .opcode (Word.ofNat (base + 32)) 0xCB,
      .read .cbOpcode (Word.ofNat (base + 33)) 0x77,
      .read .opcode (Word.ofNat (base + 34)) 0xC2,
      .read .immediate (Word.ofNat (base + 35)) 0x8C,
      .read .immediate (Word.ofNat (base + 36)) 0x7B ]
  let fails := !enemyTurn && playerInvulnerable
  initial ++ side ++ test ++ if fails then [.idle failurePc] else []

private def summaryHolds (enemyTurn playerInvulnerable : Bool) : Bool :=
  let result := run enemyTurn playerInvulnerable
  let final := Driver.finalState result
  let fails := !enemyTurn && playerInvulnerable
  Driver.reachedReturn result &&
    stepsOf result == (if enemyTurn then 9 else 14) &&
    traceOf result == expectedTrace enemyTurn playerInvulnerable &&
    final.registers.pc == (if fails then failurePc else successPc) &&
    Driver.toByte (final.memory.read playerMoveListIndex) ==
      (if enemyTurn then 0xA5 else 0)

private def physicalInitial (state : FunctionalState) : FlatCoreState :=
  let core := { Pipeline.bootstrap state.registers with ime := state.ime }
  let core := { core with scheduledImeEnable := state.scheduledImeEnable }
  let core := { core with haltBug := state.haltBug }
  { core, memory := state.memory }

private def physicalSummaryHolds (enemyTurn playerInvulnerable : Bool) : Bool :=
  let functional := run enemyTurn playerInvulnerable
  let expected := expectedTrace enemyTurn playerInvulnerable
  let fails := !enemyTurn && playerInvulnerable
  let nextPc := if fails then failurePc else successPc
  let nextOpcode : Byte := if fails then 0x0E else 0xE5
  let physical := FlatAdapter.run (expected.length + 1)
    (physicalInitial (before enemyTurn playerInvulnerable)) (fun _ _ => 0)
  let projected := FlatAdapter.project physical
  physical.trace == expected ++ [.read .opcode nextPc nextOpcode] &&
    projected.registers == (Driver.finalState functional).registers &&
    projected.mode == .running && physical.core.boundaryPC.isSome

private theorem all_checked :
    ∀ enemyTurn playerInvulnerable,
      summaryHolds enemyTurn playerInvulnerable = true ∧
        physicalSummaryHolds enemyTurn playerInvulnerable = true := by
  decide

/-- Exact Transform bug control flow through the copy/failure boundary. -/
theorem transform_invulnerability_exact (enemyTurn playerInvulnerable : Bool) :
    summaryHolds enemyTurn playerInvulnerable = true ∧
      physicalSummaryHolds enemyTurn playerInvulnerable = true :=
  all_checked enemyTurn playerInvulnerable

structure RequiredTransformBytes (rom : Array Byte) : Prop where
  controlWindow : Tables.tableBytes rom
      (romOffset 0x0E (Word.ofNat entry.toNat)) bytes.length =
    bytes.map (fun byte => byte.toNat.toUInt8)

structure CanonicalTransformBytes (sha256 : Sha256) (rom : CanonicalRom) : Prop where
  leechSeed : LeechSeedRoutine.CanonicalLeechSeedBytes sha256 rom
  transform : RequiredTransformBytes rom.bytes

/-- Runtime fixture predicate only. -/
def windowAgrees (rom : Array Byte) : Bool :=
  decide (Tables.tableBytes rom (romOffset 0x0E (Word.ofNat entry.toNat)) bytes.length =
    bytes.map (fun byte => byte.toNat.toUInt8))

end Battle.Rom.TransformRoutine
