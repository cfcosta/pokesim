/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Rom.SubstituteRoutine

/-!
# Decoded Leech Seed post-hit mechanics

The handler performs `MoveHitTest` through a banked call before this local
checkpoint. From the proved post-hit entry, all remaining gameplay mutation is
call-free: select the target side, reject either Grass type or an existing Seeded
bit, otherwise set exactly that bit before presentation.
-/

namespace Battle.Rom.LeechSeedRoutine

open Sm83 Battle.Rom.Closure

private def handlerEntry : UInt16 := 0x7EA9
private def entry : UInt16 := 0x7EB7
private def bytes : List Byte :=
  [0x21, 0x68, 0xD0, 0x11, 0xEA, 0xCF, 0xF0, 0xF3, 0xA7,
   0x28, 0x06, 0x21, 0x63, 0xD0, 0x11, 0x19, 0xD0, 0x1A,
   0xFE, 0x16, 0x28, 0x1A, 0x13, 0x1A, 0xFE, 0x16, 0x28,
   0x14, 0xCB, 0x7E, 0x20, 0x10, 0xCB, 0xFE]
private def successPc : Word := 0x7ED9
private def failurePc : Word := 0x7EE7
private def hWhoseTurn : Word := 0xFFF3
private def playerType1 : Word := 0xD019
private def enemyType1 : Word := 0xCFEA
private def playerStatus2 : Word := 0xD063
private def enemyStatus2 : Word := 0xD068
private def grass : UInt8 := 0x16

private def install : FlatMemory → Word → List Byte → FlatMemory
  | memory, _, [] => memory
  | memory, address, byte :: rest =>
      install (memory.write address byte) (Word.ofNat (address.toNat + 1)) rest

private def memory (enemyTurn seeded : Bool) (type1 type2 : UInt8) : FlatMemory :=
  let memory := install default (Word.ofNat entry.toNat) bytes
  let memory := memory.write successPc 0x21
  let memory := memory.write failurePc 0x0E
  let memory := memory.write hWhoseTurn (if enemyTurn then 1 else 0)
  let targetType := if enemyTurn then playerType1 else enemyType1
  let memory := memory.write targetType (Byte.ofNat type1.toNat)
  let memory := memory.write (Word.ofNat (targetType.toNat + 1)) (Byte.ofNat type2.toNat)
  let selected : Byte := if seeded then 0x80 else 0
  let playerStatus : Byte := if enemyTurn then selected else 0x35
  let enemyStatus : Byte := if enemyTurn then 0x35 else selected
  let memory := memory.write playerStatus2 playerStatus
  memory.write enemyStatus2 enemyStatus

private def before (enemyTurn seeded : Bool) (type1 type2 : UInt8) : FunctionalState :=
  { registers := { pc := Word.ofNat entry.toNat }
    memory := memory enemyTurn seeded type1 type2 }

private def stop (state : FunctionalState) : Bool :=
  state.registers.pc == successPc || state.registers.pc == failurePc

private def run (enemyTurn seeded : Bool) (type1 type2 : UInt8) : Program.RunResult :=
  Program.runUntil stop 18 (before enemyTurn seeded type1 type2) [] 0

private def traceOf : Program.RunResult → List BusEvent
  | .reached _ trace _ | .halted _ trace _ | .stopped _ trace _ |
      .locked _ trace _ | .fuelExhausted _ trace _ => trace

private def stepsOf : Program.RunResult → Nat
  | .reached _ _ count | .halted _ _ count | .stopped _ _ count |
      .locked _ _ count | .fuelExhausted _ _ count => count

private def expectedTrace (enemyTurn seeded : Bool)
    (type1 type2 : UInt8) : List BusEvent :=
  let base := entry.toNat
  let whose : Byte := if enemyTurn then 1 else 0
  let targetType := if enemyTurn then playerType1 else enemyType1
  let targetStatus := if enemyTurn then playerStatus2 else enemyStatus2
  let selected : Byte := if seeded then 0x80 else 0
  let initial : List BusEvent :=
    [ .read .opcode (Word.ofNat base) 0x21,
      .read .immediate (Word.ofNat (base + 1)) 0x68,
      .read .immediate (Word.ofNat (base + 2)) 0xD0,
      .read .opcode (Word.ofNat (base + 3)) 0x11,
      .read .immediate (Word.ofNat (base + 4)) 0xEA,
      .read .immediate (Word.ofNat (base + 5)) 0xCF,
      .read .opcode (Word.ofNat (base + 6)) 0xF0,
      .read .immediate (Word.ofNat (base + 7)) 0xF3,
      .read .data hWhoseTurn whose,
      .read .opcode (Word.ofNat (base + 8)) 0xA7,
      .read .opcode (Word.ofNat (base + 9)) 0x28,
      .read .immediate (Word.ofNat (base + 10)) 0x06 ]
  let side : List BusEvent := if enemyTurn then
    [ .read .opcode (Word.ofNat (base + 11)) 0x21,
      .read .immediate (Word.ofNat (base + 12)) 0x63,
      .read .immediate (Word.ofNat (base + 13)) 0xD0,
      .read .opcode (Word.ofNat (base + 14)) 0x11,
      .read .immediate (Word.ofNat (base + 15)) 0x19,
      .read .immediate (Word.ofNat (base + 16)) 0xD0 ]
    else [.idle (Word.ofNat (base + 11))]
  let first : List BusEvent :=
    [ .read .opcode (Word.ofNat (base + 17)) 0x1A,
      .read .data targetType (Byte.ofNat type1.toNat),
      .read .opcode (Word.ofNat (base + 18)) 0xFE,
      .read .immediate (Word.ofNat (base + 19)) 0x16,
      .read .opcode (Word.ofNat (base + 20)) 0x28,
      .read .immediate (Word.ofNat (base + 21)) 0x1A ]
  if type1 == grass then initial ++ side ++ first ++
    [.idle (Word.ofNat (base + 22))]
  else
    let second : List BusEvent :=
      [ .read .opcode (Word.ofNat (base + 22)) 0x13,
        .idle targetType,
        .read .opcode (Word.ofNat (base + 23)) 0x1A,
        .read .data (Word.ofNat (targetType.toNat + 1)) (Byte.ofNat type2.toNat),
        .read .opcode (Word.ofNat (base + 24)) 0xFE,
        .read .immediate (Word.ofNat (base + 25)) 0x16,
        .read .opcode (Word.ofNat (base + 26)) 0x28,
        .read .immediate (Word.ofNat (base + 27)) 0x14 ]
    if type2 == grass then initial ++ side ++ first ++ second ++
      [.idle (Word.ofNat (base + 28))]
    else
      let test : List BusEvent :=
        [ .read .opcode (Word.ofNat (base + 28)) 0xCB,
          .read .cbOpcode (Word.ofNat (base + 29)) 0x7E,
          .read .data targetStatus selected,
          .read .opcode (Word.ofNat (base + 30)) 0x20,
          .read .immediate (Word.ofNat (base + 31)) 0x10 ]
      if seeded then initial ++ side ++ first ++ second ++ test ++
        [.idle (Word.ofNat (base + 32))]
      else initial ++ side ++ first ++ second ++ test ++
        [ .read .opcode (Word.ofNat (base + 32)) 0xCB,
          .read .cbOpcode (Word.ofNat (base + 33)) 0xFE,
          .read .data targetStatus 0,
          .write targetStatus 0x80 ]

private def summaryHolds (enemyTurn seeded : Bool) (type1 type2 : UInt8) : Bool :=
  let result := run enemyTurn seeded type1 type2
  let final := Driver.finalState result
  let rejected := type1 == grass || type2 == grass || seeded
  let selectedAddress := if enemyTurn then playerStatus2 else enemyStatus2
  let otherAddress := if enemyTurn then enemyStatus2 else playerStatus2
  Driver.reachedReturn result &&
    stepsOf result == (if type1 == grass then (if enemyTurn then 10 else 8)
      else if type2 == grass then (if enemyTurn then 14 else 12)
      else if seeded then (if enemyTurn then 16 else 14)
      else if enemyTurn then 17 else 15) &&
    traceOf result == expectedTrace enemyTurn seeded type1 type2 &&
    final.registers.pc == (if rejected then failurePc else successPc) &&
    Driver.toByte (final.memory.read selectedAddress) == (if rejected then
      (if seeded then 0x80 else 0) else 0x80) &&
    Driver.toByte (final.memory.read otherAddress) == 0x35

private def physicalInitial (state : FunctionalState) : FlatCoreState :=
  let core := { Pipeline.bootstrap state.registers with ime := state.ime }
  let core := { core with scheduledImeEnable := state.scheduledImeEnable }
  let core := { core with haltBug := state.haltBug }
  { core, memory := state.memory }

private def physicalSummaryHolds (enemyTurn seeded : Bool)
    (type1 type2 : UInt8) : Bool :=
  let functional := run enemyTurn seeded type1 type2
  let expected := expectedTrace enemyTurn seeded type1 type2
  let rejected := type1 == grass || type2 == grass || seeded
  let nextPc := if rejected then failurePc else successPc
  let nextOpcode : Byte := if rejected then 0x0E else 0x21
  let physical := FlatAdapter.run (expected.length + 1)
    (physicalInitial (before enemyTurn seeded type1 type2)) (fun _ _ => 0)
  let projected := FlatAdapter.project physical
  physical.trace == expected ++ [.read .opcode nextPc nextOpcode] &&
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

private theorem physical_exhaustive_checked : physicalExhaustive = true := by native_decide

private theorem checked (enemyTurn seeded : Bool) (type1 type2 : UInt8) :
    summaryHolds enemyTurn seeded type1 type2 = true ∧
      physicalSummaryHolds enemyTurn seeded type1 type2 = true := by
  have rows := List.all_eq_true.mp exhaustive_checked
  have row := rows type1.toNat (List.mem_range.mpr (UInt8.toNat_lt type1))
  have columns := List.all_eq_true.mp row
  have all := columns type2.toNat (List.mem_range.mpr (UInt8.toNat_lt type2))
  have physicalRows := List.all_eq_true.mp physical_exhaustive_checked
  have physicalRow := physicalRows type1.toNat (List.mem_range.mpr (UInt8.toNat_lt type1))
  have physicalColumns := List.all_eq_true.mp physicalRow
  have physicalAll := physicalColumns type2.toNat
    (List.mem_range.mpr (UInt8.toNat_lt type2))
  have firstRound : type1.toNat.toUInt8 = type1 := by apply UInt8.toNat.inj; simp
  have secondRound : type2.toNat.toUInt8 = type2 := by apply UInt8.toNat.inj; simp
  simp only [firstRound, secondRound] at all physicalAll
  cases enemyTurn <;> cases seeded <;> simp_all

/-- Exact post-hit Leech Seed gameplay and continuous fetched-IR summaries for
both sides, both Seeded states, and all target type-byte pairs. -/
theorem leechSeed_postHit_exact (enemyTurn seeded : Bool) (type1 type2 : UInt8) :
    summaryHolds enemyTurn seeded type1 type2 = true ∧
      physicalSummaryHolds enemyTurn seeded type1 type2 = true :=
  checked enemyTurn seeded type1 type2

structure RequiredLeechSeedBytes (rom : Array Byte) : Prop where
  mechanicsWindow : Tables.tableBytes rom
      (romOffset 0x0A (Word.ofNat entry.toNat)) bytes.length =
    bytes.map (fun byte => byte.toNat.toUInt8)

structure CanonicalLeechSeedBytes (sha256 : Sha256) (rom : CanonicalRom) : Prop where
  substitute : SubstituteRoutine.CanonicalSubstituteBytes sha256 rom
  leechSeed : RequiredLeechSeedBytes rom.bytes

/-- Runtime fixture predicate only. -/
def windowAgrees (rom : Array Byte) : Bool :=
  decide (Tables.tableBytes rom (romOffset 0x0A (Word.ofNat entry.toNat)) bytes.length =
    bytes.map (fun byte => byte.toNat.toUInt8))

end Battle.Rom.LeechSeedRoutine
