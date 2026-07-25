/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Rom.EffectPrefixes

/-!
# Decoded Explosion/Selfdestruct mechanics tail

`ExplodeEffect` is a complete call-free handler. It zeros the acting Pokémon's
HP and status and clears only that side's seeded bit before returning.
-/

namespace Battle.Rom.ExplodeRoutine

open Sm83 Battle.Rom.Closure

private def entry : UInt16 := 0x72F1
private def bytes : List Byte :=
  [0x21, 0x15, 0xD0, 0x11, 0x63, 0xD0, 0xF0, 0xF3, 0xA7,
   0x28, 0x06, 0x21, 0xE6, 0xCF, 0x11, 0x68, 0xD0, 0xAF,
   0x22, 0x22, 0x23, 0x77, 0x1A, 0xCB, 0xBF, 0x12, 0xC9]
private def sentinel : UInt16 := 0x8000
private def stackTop : UInt16 := 0xFFFE
private def hWhoseTurn : Word := 0xFFF3
private def playerHp : Word := 0xD015
private def playerStatus : Word := 0xD018
private def playerStatus2 : Word := 0xD063
private def enemyHp : Word := 0xCFE6
private def enemyStatus : Word := 0xCFE9
private def enemyStatus2 : Word := 0xD068

private def install : FlatMemory → Word → List Byte → FlatMemory
  | memory, _, [] => memory
  | memory, address, byte :: rest =>
      install (memory.write address byte) (Word.ofNat (address.toNat + 1)) rest

private def memory (enemyTurn : Bool) (playerVolatile enemyVolatile : UInt8) : FlatMemory :=
  let memory := install default (Word.ofNat entry.toNat) bytes
  let memory := memory.write hWhoseTurn (if enemyTurn then 1 else 0)
  let memory := memory.write playerHp 0x12
  let memory := memory.write (Word.ofNat (playerHp.toNat + 1)) 0x34
  let memory := memory.write playerStatus 0x56
  let memory := memory.write enemyHp 0x78
  let memory := memory.write (Word.ofNat (enemyHp.toNat + 1)) 0x9A
  let memory := memory.write enemyStatus 0xBC
  let memory := memory.write playerStatus2 (Byte.ofNat playerVolatile.toNat)
  memory.write enemyStatus2 (Byte.ofNat enemyVolatile.toNat)

private def initial (enemyTurn : Bool) (playerVolatile enemyVolatile : UInt8) :
    FunctionalState :=
  Driver.setupCall (memory enemyTurn playerVolatile enemyVolatile)
    entry sentinel stackTop

private def run (enemyTurn : Bool) (playerVolatile enemyVolatile : UInt8) :
    Program.RunResult :=
  Driver.runToReturn (initial enemyTurn playerVolatile enemyVolatile) sentinel 20

private def traceOf : Program.RunResult → List BusEvent
  | .reached _ trace _ | .halted _ trace _ | .stopped _ trace _ |
      .locked _ trace _ | .fuelExhausted _ trace _ => trace

private def stepsOf : Program.RunResult → Nat
  | .reached _ _ count | .halted _ _ count | .stopped _ _ count |
      .locked _ _ count | .fuelExhausted _ _ count => count

private def expectedTrace (enemyTurn : Bool)
    (playerVolatile enemyVolatile : UInt8) : List BusEvent :=
  let base := entry.toNat
  let whose : Byte := if enemyTurn then 1 else 0
  let hp := if enemyTurn then enemyHp else playerHp
  let status := if enemyTurn then enemyStatus else playerStatus
  let status2 := if enemyTurn then enemyStatus2 else playerStatus2
  let volatile := if enemyTurn then enemyVolatile else playerVolatile
  let first : List BusEvent :=
    [ .read .opcode (Word.ofNat base) 0x21,
      .read .immediate (Word.ofNat (base + 1)) 0x15,
      .read .immediate (Word.ofNat (base + 2)) 0xD0,
      .read .opcode (Word.ofNat (base + 3)) 0x11,
      .read .immediate (Word.ofNat (base + 4)) 0x63,
      .read .immediate (Word.ofNat (base + 5)) 0xD0,
      .read .opcode (Word.ofNat (base + 6)) 0xF0,
      .read .immediate (Word.ofNat (base + 7)) 0xF3,
      .read .data hWhoseTurn whose,
      .read .opcode (Word.ofNat (base + 8)) 0xA7,
      .read .opcode (Word.ofNat (base + 9)) 0x28,
      .read .immediate (Word.ofNat (base + 10)) 0x06 ]
  let branch : List BusEvent := if enemyTurn then
    [ .read .opcode (Word.ofNat (base + 11)) 0x21,
      .read .immediate (Word.ofNat (base + 12)) 0xE6,
      .read .immediate (Word.ofNat (base + 13)) 0xCF,
      .read .opcode (Word.ofNat (base + 14)) 0x11,
      .read .immediate (Word.ofNat (base + 15)) 0x68,
      .read .immediate (Word.ofNat (base + 16)) 0xD0 ]
    else [.idle (Word.ofNat (base + 11))]
  first ++ branch ++
    [ .read .opcode (Word.ofNat (base + 17)) 0xAF,
      .read .opcode (Word.ofNat (base + 18)) 0x22,
      .write hp 0,
      .read .opcode (Word.ofNat (base + 19)) 0x22,
      .write (Word.ofNat (hp.toNat + 1)) 0,
      .read .opcode (Word.ofNat (base + 20)) 0x23,
      .idle (Word.ofNat (hp.toNat + 2)),
      .read .opcode (Word.ofNat (base + 21)) 0x77,
      .write status 0,
      .read .opcode (Word.ofNat (base + 22)) 0x1A,
      .read .data status2 (Byte.ofNat volatile.toNat),
      .read .opcode (Word.ofNat (base + 23)) 0xCB,
      .read .cbOpcode (Word.ofNat (base + 24)) 0xBF,
      .read .opcode (Word.ofNat (base + 25)) 0x12,
      .write status2 (Byte.ofNat (volatile.toNat &&& 0x7F)),
      .read .opcode (Word.ofNat (base + 26)) 0xC9,
      .read .stack 0xFFFC 0,
      .read .stack 0xFFFD 0x80,
      .idle (Word.ofNat sentinel.toNat) ]

private def summaryHolds (enemyTurn : Bool)
    (playerVolatile enemyVolatile : UInt8) : Bool :=
  let result := run enemyTurn playerVolatile enemyVolatile
  let final := Driver.finalState result
  let actorHp := if enemyTurn then enemyHp else playerHp
  let actorStatus := if enemyTurn then enemyStatus else playerStatus
  let actorStatus2 := if enemyTurn then enemyStatus2 else playerStatus2
  let actorVolatile := if enemyTurn then enemyVolatile else playerVolatile
  let otherHp := if enemyTurn then playerHp else enemyHp
  let otherStatus := if enemyTurn then playerStatus else enemyStatus
  Driver.reachedReturn result &&
    stepsOf result == (if enemyTurn then 16 else 14) &&
    traceOf result == expectedTrace enemyTurn playerVolatile enemyVolatile &&
    Driver.toByte (final.memory.read actorHp) == 0 &&
    Driver.toByte (final.memory.read (Word.ofNat (actorHp.toNat + 1))) == 0 &&
    Driver.toByte (final.memory.read actorStatus) == 0 &&
    Driver.toByte (final.memory.read actorStatus2) == (actorVolatile &&& 0x7F) &&
    Driver.toByte (final.memory.read otherHp) == (if enemyTurn then 0x12 else 0x78) &&
    Driver.toByte (final.memory.read otherStatus) == (if enemyTurn then 0x56 else 0xBC)

private def physicalInitial (state : FunctionalState) : FlatCoreState :=
  let core := { Pipeline.bootstrap state.registers with ime := state.ime }
  let core := { core with scheduledImeEnable := state.scheduledImeEnable }
  let core := { core with haltBug := state.haltBug }
  { core, memory := state.memory }

private def physicalSummaryHolds (enemyTurn : Bool)
    (playerVolatile enemyVolatile : UInt8) : Bool :=
  let functional := run enemyTurn playerVolatile enemyVolatile
  let expected := expectedTrace enemyTurn playerVolatile enemyVolatile
  let physical := FlatAdapter.run (expected.length + 1)
    (physicalInitial (initial enemyTurn playerVolatile enemyVolatile)) (fun _ _ => 0)
  let projected := FlatAdapter.project physical
  physical.trace == expected ++ [.read .opcode (Word.ofNat sentinel.toNat) 0] &&
    projected.registers == (Driver.finalState functional).registers &&
    projected.mode == .running && physical.core.boundaryPC.isSome

private def exhaustive : Bool :=
  (List.range 256).all fun player =>
    (List.range 256).all fun enemy =>
      summaryHolds false player.toUInt8 enemy.toUInt8 &&
        summaryHolds true player.toUInt8 enemy.toUInt8

private theorem exhaustive_checked : exhaustive = true := by native_decide

private def physicalExhaustive : Bool :=
  (List.range 256).all fun player =>
    (List.range 256).all fun enemy =>
      physicalSummaryHolds false player.toUInt8 enemy.toUInt8 &&
        physicalSummaryHolds true player.toUInt8 enemy.toUInt8

private theorem physical_exhaustive_checked : physicalExhaustive = true := by native_decide

private theorem checked (enemyTurn : Bool) (playerVolatile enemyVolatile : UInt8) :
    summaryHolds enemyTurn playerVolatile enemyVolatile = true ∧
      physicalSummaryHolds enemyTurn playerVolatile enemyVolatile = true := by
  have players := List.all_eq_true.mp exhaustive_checked
  have player := players playerVolatile.toNat
    (List.mem_range.mpr (UInt8.toNat_lt playerVolatile))
  have enemies := List.all_eq_true.mp player
  have all := enemies enemyVolatile.toNat
    (List.mem_range.mpr (UInt8.toNat_lt enemyVolatile))
  have playerRound : playerVolatile.toNat.toUInt8 = playerVolatile := by
    apply UInt8.toNat.inj; simp
  have enemyRound : enemyVolatile.toNat.toUInt8 = enemyVolatile := by
    apply UInt8.toNat.inj; simp
  have physicalPlayers := List.all_eq_true.mp physical_exhaustive_checked
  have physicalPlayer := physicalPlayers playerVolatile.toNat
    (List.mem_range.mpr (UInt8.toNat_lt playerVolatile))
  have physicalEnemies := List.all_eq_true.mp physicalPlayer
  have physicalAll := physicalEnemies enemyVolatile.toNat
    (List.mem_range.mpr (UInt8.toNat_lt enemyVolatile))
  simp only [playerRound, enemyRound] at all physicalAll
  cases enemyTurn <;> simp_all

/-- Universal call-free functional and continuous fetched-IR summaries. -/
theorem explode_exact (enemyTurn : Bool) (playerVolatile enemyVolatile : UInt8) :
    summaryHolds enemyTurn playerVolatile enemyVolatile = true ∧
      physicalSummaryHolds enemyTurn playerVolatile enemyVolatile = true :=
  checked enemyTurn playerVolatile enemyVolatile

structure RequiredExplodeBytes (rom : Array Byte) : Prop where
  window : Tables.tableBytes rom (romOffset 0x0F (Word.ofNat entry.toNat)) bytes.length =
    bytes.map (fun byte => byte.toNat.toUInt8)

structure CanonicalExplodeBytes (sha256 : Sha256) (rom : CanonicalRom) : Prop where
  prefixes : EffectPrefixes.CanonicalEffectPrefixBytes sha256 rom
  explode : RequiredExplodeBytes rom.bytes

/-- Runtime fixture predicate only. -/
def windowAgrees (rom : Array Byte) : Bool :=
  decide (Tables.tableBytes rom (romOffset 0x0F (Word.ofNat entry.toNat)) bytes.length =
    bytes.map (fun byte => byte.toNat.toUInt8))

end Battle.Rom.ExplodeRoutine
