/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Rom.OhkoRoutine

/-!
# Decoded Reflect and Light Screen mechanics prefixes

The two effects share one handler. This module executes its complete gameplay
prefix through the common presentation or failure boundary for every status-3
byte pair, both acting sides, and both effect IDs.
-/

namespace Battle.Rom.ScreenRoutine

open Sm83 Battle.Rom.Closure

private def entry : UInt16 := 0x7B97
private def bytes : List Byte :=
  [0x21, 0x64, 0xD0, 0x11, 0xD3, 0xCF, 0xF0, 0xF3, 0xA7,
   0x28, 0x06, 0x21, 0x69, 0xD0, 0x11, 0xCD, 0xCF, 0x1A,
   0xFE, 0x40, 0x20, 0x0B, 0xCB, 0x4E, 0x20, 0x1B, 0xCB,
   0xCE, 0x21, 0xD7, 0x7B, 0x18, 0x09, 0xCB, 0x56, 0x20,
   0x10, 0xCB, 0xD6, 0x21, 0xDC, 0x7B]
private def successPc : Word := Word.ofNat (entry.toNat + 42)
private def failurePc : Word := Word.ofNat (entry.toNat + 53)
private def hWhoseTurn : Word := 0xFFF3
private def playerStatus3 : Word := 0xD064
private def enemyStatus3 : Word := 0xD069
private def playerEffect : Word := 0xCFD3
private def enemyEffect : Word := 0xCFCD

private def install : FlatMemory → Word → List Byte → FlatMemory
  | memory, _, [] => memory
  | memory, address, byte :: rest =>
      install (memory.write address byte) (Word.ofNat (address.toNat + 1)) rest

private def memory (enemyTurn lightScreen : Bool)
    (playerStatus enemyStatus : UInt8) : FlatMemory :=
  let memory := install default (Word.ofNat entry.toNat) bytes
  let memory := memory.write successPc 0xE5
  let memory := memory.write failurePc 0x0E
  let memory := memory.write hWhoseTurn (if enemyTurn then 1 else 0)
  let effect : Byte := if lightScreen then 0x40 else 0x41
  let memory := memory.write playerEffect effect
  let memory := memory.write enemyEffect effect
  let memory := memory.write playerStatus3 (Byte.ofNat playerStatus.toNat)
  memory.write enemyStatus3 (Byte.ofNat enemyStatus.toNat)

private def before (enemyTurn lightScreen : Bool)
    (playerStatus enemyStatus : UInt8) : FunctionalState :=
  { registers := { pc := Word.ofNat entry.toNat }
    memory := memory enemyTurn lightScreen playerStatus enemyStatus }

private def stop (state : FunctionalState) : Bool :=
  state.registers.pc == successPc || state.registers.pc == failurePc

private def run (enemyTurn lightScreen : Bool)
    (playerStatus enemyStatus : UInt8) : Program.RunResult :=
  Program.runUntil stop 18 (before enemyTurn lightScreen playerStatus enemyStatus) [] 0

private def traceOf : Program.RunResult → List BusEvent
  | .reached _ trace _ | .halted _ trace _ | .stopped _ trace _ |
      .locked _ trace _ | .fuelExhausted _ trace _ => trace

private def stepsOf : Program.RunResult → Nat
  | .reached _ _ count | .halted _ _ count | .stopped _ _ count |
      .locked _ _ count | .fuelExhausted _ _ count => count

private def expectedTrace (enemyTurn lightScreen : Bool)
    (playerStatus enemyStatus : UInt8) : List BusEvent :=
  let base := entry.toNat
  let whose : Byte := if enemyTurn then 1 else 0
  let selected := if enemyTurn then enemyStatus else playerStatus
  let target := if enemyTurn then enemyStatus3 else playerStatus3
  let effectAddress := if enemyTurn then enemyEffect else playerEffect
  let effect : Byte := if lightScreen then 0x40 else 0x41
  let mask : UInt8 := if lightScreen then 0x02 else 0x04
  let already := selected &&& mask != 0
  let initial : List BusEvent :=
    [ .read .opcode (Word.ofNat base) 0x21,
      .read .immediate (Word.ofNat (base + 1)) 0x64,
      .read .immediate (Word.ofNat (base + 2)) 0xD0,
      .read .opcode (Word.ofNat (base + 3)) 0x11,
      .read .immediate (Word.ofNat (base + 4)) 0xD3,
      .read .immediate (Word.ofNat (base + 5)) 0xCF,
      .read .opcode (Word.ofNat (base + 6)) 0xF0,
      .read .immediate (Word.ofNat (base + 7)) 0xF3,
      .read .data hWhoseTurn whose,
      .read .opcode (Word.ofNat (base + 8)) 0xA7,
      .read .opcode (Word.ofNat (base + 9)) 0x28,
      .read .immediate (Word.ofNat (base + 10)) 0x06 ]
  let side : List BusEvent := if enemyTurn then
    [ .read .opcode (Word.ofNat (base + 11)) 0x21,
      .read .immediate (Word.ofNat (base + 12)) 0x69,
      .read .immediate (Word.ofNat (base + 13)) 0xD0,
      .read .opcode (Word.ofNat (base + 14)) 0x11,
      .read .immediate (Word.ofNat (base + 15)) 0xCD,
      .read .immediate (Word.ofNat (base + 16)) 0xCF ]
    else [.idle (Word.ofNat (base + 11))]
  let choose : List BusEvent :=
    [ .read .opcode (Word.ofNat (base + 17)) 0x1A,
      .read .data effectAddress effect,
      .read .opcode (Word.ofNat (base + 18)) 0xFE,
      .read .immediate (Word.ofNat (base + 19)) 0x40,
      .read .opcode (Word.ofNat (base + 20)) 0x20,
      .read .immediate (Word.ofNat (base + 21)) 0x0B ] ++
    (if lightScreen then [] else [.idle (Word.ofNat (base + 22))])
  let bitOffset := if lightScreen then 22 else 33
  let bitOpcode : Byte := if lightScreen then 0x4E else 0x56
  let setOpcode : Byte := if lightScreen then 0xCE else 0xD6
  let test : List BusEvent :=
    [ .read .opcode (Word.ofNat (base + bitOffset)) 0xCB,
      .read .cbOpcode (Word.ofNat (base + bitOffset + 1)) bitOpcode,
      .read .data target (Byte.ofNat selected.toNat),
      .read .opcode (Word.ofNat (base + bitOffset + 2)) 0x20,
      .read .immediate (Word.ofNat (base + bitOffset + 3))
        (if lightScreen then 0x1B else 0x10) ]
  let finish : List BusEvent := if already then
    [.idle (Word.ofNat (base + bitOffset + 4))]
  else
    [ .read .opcode (Word.ofNat (base + bitOffset + 4)) 0xCB,
      .read .cbOpcode (Word.ofNat (base + bitOffset + 5)) setOpcode,
      .read .data target (Byte.ofNat selected.toNat),
      .write target (Byte.ofNat (selected.toNat ||| mask.toNat)),
      .read .opcode (Word.ofNat (base + bitOffset + 6)) 0x21,
      .read .immediate (Word.ofNat (base + bitOffset + 7))
        (if lightScreen then 0xD7 else 0xDC),
      .read .immediate (Word.ofNat (base + bitOffset + 8)) 0x7B ] ++
      (if lightScreen then
        [ .read .opcode (Word.ofNat (base + 31)) 0x18,
          .read .immediate (Word.ofNat (base + 32)) 0x09,
          .idle (Word.ofNat (base + 33)) ]
       else [])
  initial ++ side ++ choose ++ test ++ finish

private def summaryHolds (enemyTurn lightScreen : Bool)
    (playerStatus enemyStatus : UInt8) : Bool :=
  let result := run enemyTurn lightScreen playerStatus enemyStatus
  let final := Driver.finalState result
  let selected := if enemyTurn then enemyStatus else playerStatus
  let mask : UInt8 := if lightScreen then 0x02 else 0x04
  let already := selected &&& mask != 0
  let expectedPlayer := if enemyTurn || already then playerStatus else playerStatus ||| mask
  let expectedEnemy := if !enemyTurn || already then enemyStatus else enemyStatus ||| mask
  Driver.reachedReturn result &&
    stepsOf result == (if already then (if enemyTurn then 12 else 10)
      else if lightScreen then (if enemyTurn then 15 else 13)
      else if enemyTurn then 14 else 12) &&
    traceOf result == expectedTrace enemyTurn lightScreen playerStatus enemyStatus &&
    final.registers.pc == (if already then failurePc else successPc) &&
    Driver.toByte (final.memory.read playerStatus3) == expectedPlayer &&
    Driver.toByte (final.memory.read enemyStatus3) == expectedEnemy

private def physicalInitial (state : FunctionalState) : FlatCoreState :=
  let core := { Pipeline.bootstrap state.registers with ime := state.ime }
  let core := { core with scheduledImeEnable := state.scheduledImeEnable }
  let core := { core with haltBug := state.haltBug }
  { core, memory := state.memory }

private def physicalSummaryHolds (enemyTurn lightScreen : Bool)
    (playerStatus enemyStatus : UInt8) : Bool :=
  let functional := run enemyTurn lightScreen playerStatus enemyStatus
  let expected := expectedTrace enemyTurn lightScreen playerStatus enemyStatus
  let already := (if enemyTurn then enemyStatus else playerStatus) &&&
    (if lightScreen then 0x02 else 0x04) != 0
  let nextPc := if already then failurePc else successPc
  let nextOpcode : Byte := if already then 0x0E else 0xE5
  let physical := FlatAdapter.run (expected.length + 1)
    (physicalInitial (before enemyTurn lightScreen playerStatus enemyStatus)) (fun _ _ => 0)
  let projected := FlatAdapter.project physical
  physical.trace == expected ++ [.read .opcode nextPc nextOpcode] &&
    projected.registers == (Driver.finalState functional).registers &&
    projected.mode == .running && physical.core.boundaryPC.isSome

private def exhaustive : Bool :=
  (List.range 256).all fun player =>
    (List.range 256).all fun enemy =>
      summaryHolds false false player.toUInt8 enemy.toUInt8 &&
        summaryHolds false true player.toUInt8 enemy.toUInt8 &&
        summaryHolds true false player.toUInt8 enemy.toUInt8 &&
        summaryHolds true true player.toUInt8 enemy.toUInt8

private theorem exhaustive_checked : exhaustive = true := by native_decide

private def physicalExhaustive : Bool :=
  (List.range 256).all fun player =>
    (List.range 256).all fun enemy =>
      physicalSummaryHolds false false player.toUInt8 enemy.toUInt8 &&
        physicalSummaryHolds false true player.toUInt8 enemy.toUInt8 &&
        physicalSummaryHolds true false player.toUInt8 enemy.toUInt8 &&
        physicalSummaryHolds true true player.toUInt8 enemy.toUInt8

private theorem physical_exhaustive_checked : physicalExhaustive = true := by
  native_decide

private theorem checked (enemyTurn lightScreen : Bool)
    (playerStatus enemyStatus : UInt8) :
    summaryHolds enemyTurn lightScreen playerStatus enemyStatus = true ∧
      physicalSummaryHolds enemyTurn lightScreen playerStatus enemyStatus = true := by
  have rows := List.all_eq_true.mp exhaustive_checked
  have row := rows playerStatus.toNat (List.mem_range.mpr (UInt8.toNat_lt playerStatus))
  have columns := List.all_eq_true.mp row
  have all := columns enemyStatus.toNat (List.mem_range.mpr (UInt8.toNat_lt enemyStatus))
  have physicalRows := List.all_eq_true.mp physical_exhaustive_checked
  have physicalRow := physicalRows playerStatus.toNat
    (List.mem_range.mpr (UInt8.toNat_lt playerStatus))
  have physicalColumns := List.all_eq_true.mp physicalRow
  have physicalAll := physicalColumns enemyStatus.toNat
    (List.mem_range.mpr (UInt8.toNat_lt enemyStatus))
  have playerRound : playerStatus.toNat.toUInt8 = playerStatus := by
    apply UInt8.toNat.inj; simp
  have enemyRound : enemyStatus.toNat.toUInt8 = enemyStatus := by
    apply UInt8.toNat.inj; simp
  simp only [playerRound, enemyRound] at all physicalAll
  cases enemyTurn <;> cases lightScreen <;> simp_all

/-- Exact Reflect/Light Screen gameplay prefixes and continuous fetched-IR
executions for all status bytes and both acting sides. -/
theorem screens_exact (enemyTurn lightScreen : Bool)
    (playerStatus enemyStatus : UInt8) :
    summaryHolds enemyTurn lightScreen playerStatus enemyStatus = true ∧
      physicalSummaryHolds enemyTurn lightScreen playerStatus enemyStatus = true :=
  checked enemyTurn lightScreen playerStatus enemyStatus

structure RequiredScreenBytes (rom : Array Byte) : Prop where
  window : Tables.tableBytes rom (romOffset 0x0E (Word.ofNat entry.toNat)) bytes.length =
    bytes.map (fun byte => byte.toNat.toUInt8)

structure CanonicalScreenBytes (sha256 : Sha256) (rom : CanonicalRom) : Prop where
  ohko : OhkoRoutine.CanonicalOhkoBytes sha256 rom
  screens : RequiredScreenBytes rom.bytes

/-- Runtime fixture predicate only. -/
def windowAgrees (rom : Array Byte) : Bool :=
  decide (Tables.tableBytes rom (romOffset 0x0E (Word.ofNat entry.toNat)) bytes.length =
    bytes.map (fun byte => byte.toNat.toUInt8))

end Battle.Rom.ScreenRoutine
