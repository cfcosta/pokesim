/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Rom.ExplodeRoutine

/-!
# Decoded Conversion mechanics prefix

`ConversionEffect_` has a presentation tail, but all gameplay mutation occurs
before the call boundary. This module executes that prefix for both acting sides,
both invulnerability outcomes, and every pair of target type bytes.
-/

namespace Battle.Rom.ConversionRoutine

open Sm83 Battle.Rom.Closure

private def entry : UInt16 := 0x79A3
private def bytes : List Byte :=
  [0x21, 0xEA, 0xCF, 0x11, 0x19, 0xD0, 0xF0, 0xF3, 0xA7,
   0xFA, 0x67, 0xD0, 0x28, 0x07, 0xE5, 0x62, 0x6B, 0xD1,
   0xFA, 0x62, 0xD0, 0xCB, 0x77, 0x20, 0x16, 0x2A, 0x12,
   0x13, 0x7E, 0x12]
private def successPc : Word := Word.ofNat (entry.toNat + 30)
private def failurePc : Word := Word.ofNat (entry.toNat + 47)
private def stackTop : Word := 0xFFFE
private def hWhoseTurn : Word := 0xFFF3
private def playerType1 : Word := 0xD019
private def enemyType1 : Word := 0xCFEA
private def playerStatus1 : Word := 0xD062
private def enemyStatus1 : Word := 0xD067

private def install : FlatMemory → Word → List Byte → FlatMemory
  | memory, _, [] => memory
  | memory, address, byte :: rest =>
      install (memory.write address byte) (Word.ofNat (address.toNat + 1)) rest

private def memory (enemyTurn invulnerable : Bool) (type1 type2 : UInt8) : FlatMemory :=
  let memory := install default (Word.ofNat entry.toNat) bytes
  let memory := memory.write successPc 0x21
  let memory := memory.write failurePc 0x21
  let memory := memory.write hWhoseTurn (if enemyTurn then 1 else 0)
  let player1 : Byte := if enemyTurn then Byte.ofNat type1.toNat else 0xA1
  let player2 : Byte := if enemyTurn then Byte.ofNat type2.toNat else 0xA2
  let enemy1 : Byte := if enemyTurn then 0xB1 else Byte.ofNat type1.toNat
  let enemy2 : Byte := if enemyTurn then 0xB2 else Byte.ofNat type2.toNat
  let memory := memory.write playerType1 player1
  let memory := memory.write (Word.ofNat (playerType1.toNat + 1)) player2
  let memory := memory.write enemyType1 enemy1
  let memory := memory.write (Word.ofNat (enemyType1.toNat + 1)) enemy2
  let memory := memory.write playerStatus1
    (if enemyTurn && invulnerable then 0x40 else 0)
  memory.write enemyStatus1 (if !enemyTurn && invulnerable then 0x40 else 0)

private def before (enemyTurn invulnerable : Bool) (type1 type2 : UInt8) :
    FunctionalState :=
  { registers := { pc := Word.ofNat entry.toNat, sp := stackTop }
    memory := memory enemyTurn invulnerable type1 type2 }

private def stop (state : FunctionalState) : Bool :=
  state.registers.pc == successPc || state.registers.pc == failurePc

private def run (enemyTurn invulnerable : Bool) (type1 type2 : UInt8) :
    Program.RunResult :=
  Program.runUntil stop 20 (before enemyTurn invulnerable type1 type2) [] 0

private def traceOf : Program.RunResult → List BusEvent
  | .reached _ trace _ | .halted _ trace _ | .stopped _ trace _ |
      .locked _ trace _ | .fuelExhausted _ trace _ => trace

private def stepsOf : Program.RunResult → Nat
  | .reached _ _ count | .halted _ _ count | .stopped _ _ count |
      .locked _ _ count | .fuelExhausted _ _ count => count

private def expectedTrace (enemyTurn invulnerable : Bool)
    (type1 type2 : UInt8) : List BusEvent :=
  let base := entry.toNat
  let whose : Byte := if enemyTurn then 1 else 0
  let firstStatus : Byte := if !enemyTurn && invulnerable then 0x40 else 0
  let target := if enemyTurn then playerType1 else enemyType1
  let destination := if enemyTurn then enemyType1 else playerType1
  let initial : List BusEvent :=
    [ .read .opcode (Word.ofNat base) 0x21,
      .read .immediate (Word.ofNat (base + 1)) 0xEA,
      .read .immediate (Word.ofNat (base + 2)) 0xCF,
      .read .opcode (Word.ofNat (base + 3)) 0x11,
      .read .immediate (Word.ofNat (base + 4)) 0x19,
      .read .immediate (Word.ofNat (base + 5)) 0xD0,
      .read .opcode (Word.ofNat (base + 6)) 0xF0,
      .read .immediate (Word.ofNat (base + 7)) 0xF3,
      .read .data hWhoseTurn whose,
      .read .opcode (Word.ofNat (base + 8)) 0xA7,
      .read .opcode (Word.ofNat (base + 9)) 0xFA,
      .read .immediate (Word.ofNat (base + 10)) 0x67,
      .read .immediate (Word.ofNat (base + 11)) 0xD0,
      .read .data enemyStatus1 firstStatus,
      .read .opcode (Word.ofNat (base + 12)) 0x28,
      .read .immediate (Word.ofNat (base + 13)) 0x07 ]
  let side : List BusEvent := if enemyTurn then
    [ .read .opcode (Word.ofNat (base + 14)) 0xE5,
      .idle stackTop,
      .write 0xFFFD 0xCF,
      .write 0xFFFC 0xEA,
      .read .opcode (Word.ofNat (base + 15)) 0x62,
      .read .opcode (Word.ofNat (base + 16)) 0x6B,
      .read .opcode (Word.ofNat (base + 17)) 0xD1,
      .read .stack 0xFFFC 0xEA,
      .read .stack 0xFFFD 0xCF,
      .read .opcode (Word.ofNat (base + 18)) 0xFA,
      .read .immediate (Word.ofNat (base + 19)) 0x62,
      .read .immediate (Word.ofNat (base + 20)) 0xD0,
      .read .data playerStatus1 (if invulnerable then 0x40 else 0) ]
    else [.idle (Word.ofNat (base + 14))]
  let test : List BusEvent :=
    [ .read .opcode (Word.ofNat (base + 21)) 0xCB,
      .read .cbOpcode (Word.ofNat (base + 22)) 0x77,
      .read .opcode (Word.ofNat (base + 23)) 0x20,
      .read .immediate (Word.ofNat (base + 24)) 0x16 ]
  let finish : List BusEvent := if invulnerable then
    [.idle (Word.ofNat (base + 25))]
  else
    [ .read .opcode (Word.ofNat (base + 25)) 0x2A,
      .read .data target (Byte.ofNat type1.toNat),
      .read .opcode (Word.ofNat (base + 26)) 0x12,
      .write destination (Byte.ofNat type1.toNat),
      .read .opcode (Word.ofNat (base + 27)) 0x13,
      .idle destination,
      .read .opcode (Word.ofNat (base + 28)) 0x7E,
      .read .data (Word.ofNat (target.toNat + 1)) (Byte.ofNat type2.toNat),
      .read .opcode (Word.ofNat (base + 29)) 0x12,
      .write (Word.ofNat (destination.toNat + 1)) (Byte.ofNat type2.toNat) ]
  initial ++ side ++ test ++ finish

private def summaryHolds (enemyTurn invulnerable : Bool)
    (type1 type2 : UInt8) : Bool :=
  let result := run enemyTurn invulnerable type1 type2
  let final := Driver.finalState result
  let destination := if enemyTurn then enemyType1 else playerType1
  let target := if enemyTurn then playerType1 else enemyType1
  Driver.reachedReturn result &&
    stepsOf result == (if invulnerable then (if enemyTurn then 13 else 8)
      else if enemyTurn then 18 else 13) &&
    traceOf result == expectedTrace enemyTurn invulnerable type1 type2 &&
    final.registers.pc == (if invulnerable then failurePc else successPc) &&
    final.registers.sp == stackTop &&
    Driver.toByte (final.memory.read destination) ==
      (if invulnerable then (if enemyTurn then 0xB1 else 0xA1) else type1) &&
    Driver.toByte (final.memory.read (Word.ofNat (destination.toNat + 1))) ==
      (if invulnerable then (if enemyTurn then 0xB2 else 0xA2) else type2) &&
    Driver.toByte (final.memory.read target) == type1 &&
    Driver.toByte (final.memory.read (Word.ofNat (target.toNat + 1))) == type2

private def physicalInitial (state : FunctionalState) : FlatCoreState :=
  let core := { Pipeline.bootstrap state.registers with ime := state.ime }
  let core := { core with scheduledImeEnable := state.scheduledImeEnable }
  let core := { core with haltBug := state.haltBug }
  { core, memory := state.memory }

private def physicalSummaryHolds (enemyTurn invulnerable : Bool)
    (type1 type2 : UInt8) : Bool :=
  let functional := run enemyTurn invulnerable type1 type2
  let expected := expectedTrace enemyTurn invulnerable type1 type2
  let physical := FlatAdapter.run (expected.length + 1)
    (physicalInitial (before enemyTurn invulnerable type1 type2)) (fun _ _ => 0)
  let projected := FlatAdapter.project physical
  physical.trace == expected ++
      [.read .opcode (if invulnerable then failurePc else successPc) 0x21] &&
    projected.registers == (Driver.finalState functional).registers &&
    projected.mode == .running && physical.core.boundaryPC.isSome

private def exhaustive : Bool :=
  (List.range 256).all fun first =>
    (List.range 256).all fun second =>
      summaryHolds false false first.toUInt8 second.toUInt8 &&
        summaryHolds false true first.toUInt8 second.toUInt8 &&
        summaryHolds true false first.toUInt8 second.toUInt8 &&
        summaryHolds true true first.toUInt8 second.toUInt8

private theorem exhaustive_checked : exhaustive = true := by native_decide

private def physicalExhaustive : Bool :=
  (List.range 256).all fun first =>
    (List.range 256).all fun second =>
      physicalSummaryHolds false false first.toUInt8 second.toUInt8 &&
        physicalSummaryHolds false true first.toUInt8 second.toUInt8 &&
        physicalSummaryHolds true false first.toUInt8 second.toUInt8 &&
        physicalSummaryHolds true true first.toUInt8 second.toUInt8

private theorem physical_exhaustive_checked : physicalExhaustive = true := by
  native_decide

private theorem checked (enemyTurn invulnerable : Bool) (type1 type2 : UInt8) :
    summaryHolds enemyTurn invulnerable type1 type2 = true ∧
      physicalSummaryHolds enemyTurn invulnerable type1 type2 = true := by
  have rows := List.all_eq_true.mp exhaustive_checked
  have row := rows type1.toNat (List.mem_range.mpr (UInt8.toNat_lt type1))
  have columns := List.all_eq_true.mp row
  have all := columns type2.toNat (List.mem_range.mpr (UInt8.toNat_lt type2))
  have physicalRows := List.all_eq_true.mp physical_exhaustive_checked
  have physicalRow := physicalRows type1.toNat
    (List.mem_range.mpr (UInt8.toNat_lt type1))
  have physicalColumns := List.all_eq_true.mp physicalRow
  have physicalAll := physicalColumns type2.toNat
    (List.mem_range.mpr (UInt8.toNat_lt type2))
  have firstRound : type1.toNat.toUInt8 = type1 := by
    apply UInt8.toNat.inj; simp
  have secondRound : type2.toNat.toUInt8 = type2 := by
    apply UInt8.toNat.inj; simp
  simp only [firstRound, secondRound] at all physicalAll
  cases enemyTurn <;> cases invulnerable <;> simp_all

/-- Exact gameplay prefix for both sides, both invulnerability outcomes, and all
65,536 target type-byte pairs. The normalized status byte is exactly the
independent model's observable invulnerability projection. -/
theorem conversion_exact (enemyTurn invulnerable : Bool) (type1 type2 : UInt8) :
    summaryHolds enemyTurn invulnerable type1 type2 = true ∧
      physicalSummaryHolds enemyTurn invulnerable type1 type2 = true :=
  checked enemyTurn invulnerable type1 type2

structure RequiredConversionBytes (rom : Array Byte) : Prop where
  window : Tables.tableBytes rom (romOffset 0x04 (Word.ofNat entry.toNat)) bytes.length =
    bytes.map (fun byte => byte.toNat.toUInt8)

structure CanonicalConversionBytes (sha256 : Sha256) (rom : CanonicalRom) : Prop where
  explode : ExplodeRoutine.CanonicalExplodeBytes sha256 rom
  conversion : RequiredConversionBytes rom.bytes

/-- Runtime fixture predicate only. -/
def windowAgrees (rom : Array Byte) : Bool :=
  decide (Tables.tableBytes rom (romOffset 0x04 (Word.ofNat entry.toNat)) bytes.length =
    bytes.map (fun byte => byte.toNat.toUInt8))

end Battle.Rom.ConversionRoutine
