/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Rom.SwiftRoutine
import Sm83.FlatAdapter

/-!
# Complete decoded two-turn charge family

Pokémon Red has exactly six ordinary two-turn charge moves: Razor Wind, Fly,
SolarBeam, Dig, Skull Bash, and Sky Attack. All six enter `ChargeEffect`; Fly is
selected by effect `$2b`, while Dig is selected by move ID `$5b`. This module
executes the shared setup window for every move, both acting sides, and every
possible incoming battle-status-1 byte through both the functional and physical
SM83 models.

Presentation begins at `$78b6`. The theorem stops there, after all gameplay
writes and animation selection but before animation/text calls. Successful
continuation clearing is executed separately for both duplicated side-specific
cartridge windows.
-/

namespace Battle.Rom.ChargeRoutine

open Sm83 Battle.Rom.Closure

private def setupEntry : Word := 0x78A1
private def setupEnd : Word := 0x78B6
private def playerContinuationEntry : Word := 0x56A9
private def playerContinuationEnd : Word := 0x56B0
private def enemyContinuationEntry : Word := 0x670B
private def enemyContinuationEnd : Word := 0x6712

private def setupBytes : List Byte :=
  [0xCB, 0xE6, 0x1A, 0x1B, 0xFE, 0x2B, 0x20, 0x04,
   0xCB, 0xF6, 0x06, 0x64, 0x1A, 0xFE, 0x5B, 0x20,
   0x04, 0xCB, 0xF6, 0x06, 0xC0]

private def playerContinuationBytes : List Byte :=
  [0x21, 0x62, 0xD0, 0xCB, 0xA6, 0xCB, 0xB6]

private def enemyContinuationBytes : List Byte :=
  [0x21, 0x67, 0xD0, 0xCB, 0xA6, 0xCB, 0xB6]

private def hWhoseTurn : Word := 0xFFF3
private def playerStatus1 : Word := 0xD062
private def enemyStatus1 : Word := 0xD067
private def playerMove : Word := 0xCFD2
private def playerEffect : Word := 0xCFD3
private def enemyMove : Word := 0xCFCC
private def enemyEffect : Word := 0xCFCD

inductive CanonicalMove where
  | razorWind | fly | solarBeam | dig | skullBash | skyAttack
  deriving Repr, DecidableEq, BEq

namespace CanonicalMove

def move : CanonicalMove → UInt8
  | .razorWind => 13
  | .fly => 19
  | .solarBeam => 76
  | .dig => 91
  | .skullBash => 130
  | .skyAttack => 143

def effect : CanonicalMove → UInt8
  | .fly => 0x2B
  | _ => 0x27

def invulnerable : CanonicalMove → Bool
  | .fly | .dig => true
  | _ => false

end CanonicalMove

private def incomingAnimation (enemyTurn : Bool) : UInt8 :=
  if enemyTurn then 0xAF else 0xAE

private def selectedAnimation (case : CanonicalMove) (enemyTurn : Bool) : UInt8 :=
  if case == .fly then 0x64
  else if case == .dig then 0xC0
  else incomingAnimation enemyTurn

private def cases : List CanonicalMove :=
  [.razorWind, .fly, .solarBeam, .dig, .skullBash, .skyAttack]

private def install : FlatMemory → Word → List Byte → FlatMemory
  | memory, _, [] => memory
  | memory, address, byte :: rest =>
      install (memory.write address byte) (Word.ofNat (address.toNat + 1)) rest

private def actingStatus (enemyTurn : Bool) : Word :=
  if enemyTurn then enemyStatus1 else playerStatus1

private def otherStatus (enemyTurn : Bool) : Word :=
  if enemyTurn then playerStatus1 else enemyStatus1

private def actingMove (enemyTurn : Bool) : Word :=
  if enemyTurn then enemyMove else playerMove

private def actingEffect (enemyTurn : Bool) : Word :=
  if enemyTurn then enemyEffect else playerEffect

private def expectedStatus (case : CanonicalMove) (status : UInt8) : UInt8 :=
  let charged := status ||| 0x10
  if case.invulnerable then charged ||| 0x40 else charged

private def setupMemory (case : CanonicalMove) (enemyTurn : Bool)
    (status other : UInt8) : FlatMemory :=
  let memory := install default setupEntry setupBytes
  let memory := memory.write (actingStatus enemyTurn) (Byte.ofNat status.toNat)
  let memory := memory.write (otherStatus enemyTurn) (Byte.ofNat other.toNat)
  let memory := memory.write (actingMove enemyTurn) (Byte.ofNat case.move.toNat)
  memory.write (actingEffect enemyTurn) (Byte.ofNat case.effect.toNat)

private def setupInitial (case : CanonicalMove) (enemyTurn : Bool)
    (status other : UInt8) : FunctionalState :=
  let registers := ((default : Registers).setHL (actingStatus enemyTurn)).setDE
    (actingEffect enemyTurn)
  let registers := registers.set8 .b
    (Byte.ofNat (incomingAnimation enemyTurn).toNat)
  { registers := { registers with pc := setupEntry }
    memory := setupMemory case enemyTurn status other }

private def setupStop (state : FunctionalState) : Bool :=
  state.registers.pc == setupEnd

private def setupRun (case : CanonicalMove) (enemyTurn : Bool)
    (status other : UInt8) : Program.RunResult :=
  Program.runUntil setupStop 16 (setupInitial case enemyTurn status other) [] 0

private def traceOf : Program.RunResult → List BusEvent
  | .reached _ trace _ | .halted _ trace _ | .stopped _ trace _ |
      .locked _ trace _ | .fuelExhausted _ trace _ => trace

private def physicalInitial (state : FunctionalState) : FlatCoreState :=
  let core := { Pipeline.bootstrap state.registers with ime := state.ime }
  let core := { core with scheduledImeEnable := state.scheduledImeEnable }
  let core := { core with haltBug := state.haltBug }
  { core, memory := state.memory }

/-- Functional decoded execution has exactly the charge-family gameplay result:
the acting status byte gains charge and, only for Fly/Dig, invulnerability. The
other side is untouched and the animation selector follows the cartridge case. -/
def setupHolds (case : CanonicalMove) (enemyTurn : Bool)
    (status other : UInt8) : Bool :=
  let result := setupRun case enemyTurn status other
  let final := Driver.finalState result
  Driver.reachedReturn result &&
    final.registers.pc == setupEnd &&
    Driver.toByte (final.memory.read (actingStatus enemyTurn)) ==
      expectedStatus case status &&
    Driver.toByte (final.memory.read (otherStatus enemyTurn)) == other &&
    Driver.toByte final.registers.b == selectedAnimation case enemyTurn &&
    Driver.toByte (final.memory.read (actingMove enemyTurn)) == case.move &&
    Driver.toByte (final.memory.read (actingEffect enemyTurn)) == case.effect

/-- The physical half-edge CPU executes the same fetched instructions and
projects to the same architectural registers as the functional run. -/
def setupPhysicalHolds (case : CanonicalMove) (enemyTurn : Bool)
    (status other : UInt8) : Bool :=
  let functional := setupRun case enemyTurn status other
  let expected := traceOf functional
  let physical := FlatAdapter.run (expected.length + 1)
    (physicalInitial (setupInitial case enemyTurn status other)) (fun _ _ => 0)
  let projected := FlatAdapter.project physical
  physical.trace == expected ++ [.read .opcode setupEnd 0] &&
    projected.registers == (Driver.finalState functional).registers &&
    projected.mode == .running && physical.core.boundaryPC.isSome

private def setupMatrix : Bool :=
  cases.all fun case =>
    (List.range 256).all fun raw =>
      setupHolds case false raw.toUInt8 0xA5 &&
        setupHolds case true raw.toUInt8 0xA5 &&
        setupPhysicalHolds case false raw.toUInt8 0xA5 &&
        setupPhysicalHolds case true raw.toUInt8 0xA5

private theorem setup_matrix_checked : setupMatrix = true := by
  native_decide

private theorem setup_case_checked (case : CanonicalMove) (member : case ∈ cases)
    (enemyTurn : Bool) (status : UInt8) :
    setupHolds case enemyTurn status 0xA5 = true ∧
      setupPhysicalHolds case enemyTurn status 0xA5 = true := by
  have caseRows := List.all_eq_true.mp setup_matrix_checked case member
  have row := List.all_eq_true.mp caseRows status.toNat
    (List.mem_range.mpr status.toNat_lt)
  have round : status.toNat.toUInt8 = status := by
    apply UInt8.toNat.inj
    simp
  rw [round] at row
  cases enemyTurn <;> simp_all

/-- Every canonical Red two-turn move, on both sides and from every possible
incoming status byte, follows the decoded shared setup exactly. -/
theorem charge_setup_exact (case : CanonicalMove) (enemyTurn : Bool)
    (status : UInt8) :
    setupHolds case enemyTurn status 0xA5 = true ∧
      setupPhysicalHolds case enemyTurn status 0xA5 = true := by
  apply setup_case_checked case
  cases case <;> simp [cases]

/-- Named complete-family form used by coverage certificates. -/
theorem all_charge_setups_exact (enemyTurn : Bool) (status : UInt8) :
    setupHolds .razorWind enemyTurn status 0xA5 = true ∧
    setupHolds .fly enemyTurn status 0xA5 = true ∧
    setupHolds .solarBeam enemyTurn status 0xA5 = true ∧
    setupHolds .dig enemyTurn status 0xA5 = true ∧
    setupHolds .skullBash enemyTurn status 0xA5 = true ∧
    setupHolds .skyAttack enemyTurn status 0xA5 = true := by
  exact ⟨(charge_setup_exact .razorWind enemyTurn status).1,
    (charge_setup_exact .fly enemyTurn status).1,
    (charge_setup_exact .solarBeam enemyTurn status).1,
    (charge_setup_exact .dig enemyTurn status).1,
    (charge_setup_exact .skullBash enemyTurn status).1,
    (charge_setup_exact .skyAttack enemyTurn status).1⟩

private def continuationMemory (enemyTurn : Bool) (status other : UInt8) : FlatMemory :=
  let entry := if enemyTurn then enemyContinuationEntry else playerContinuationEntry
  let bytes := if enemyTurn then enemyContinuationBytes else playerContinuationBytes
  let memory := install default entry bytes
  let memory := memory.write (actingStatus enemyTurn) (Byte.ofNat status.toNat)
  memory.write (otherStatus enemyTurn) (Byte.ofNat other.toNat)

private def continuationInitial (enemyTurn : Bool) (status other : UInt8) : FunctionalState :=
  let entry := if enemyTurn then enemyContinuationEntry else playerContinuationEntry
  { registers := { (default : Registers) with pc := entry }
    memory := continuationMemory enemyTurn status other }

private def continuationEnd (enemyTurn : Bool) : Word :=
  if enemyTurn then enemyContinuationEnd else playerContinuationEnd

private def continuationStop (enemyTurn : Bool) (state : FunctionalState) : Bool :=
  state.registers.pc == continuationEnd enemyTurn

private def continuationRun (enemyTurn : Bool) (status other : UInt8) : Program.RunResult :=
  Program.runUntil (continuationStop enemyTurn) 8
    (continuationInitial enemyTurn status other) [] 0

private def clearedCharge (status : UInt8) : UInt8 := status &&& 0xAF

def continuationHolds (enemyTurn : Bool) (status other : UInt8) : Bool :=
  let result := continuationRun enemyTurn status other
  let final := Driver.finalState result
  Driver.reachedReturn result &&
    final.registers.pc == continuationEnd enemyTurn &&
    Driver.toByte (final.memory.read (actingStatus enemyTurn)) == clearedCharge status &&
    Driver.toByte (final.memory.read (otherStatus enemyTurn)) == other

def continuationPhysicalHolds (enemyTurn : Bool)
    (status other : UInt8) : Bool :=
  let functional := continuationRun enemyTurn status other
  let expected := traceOf functional
  let physical := FlatAdapter.run (expected.length + 1)
    (physicalInitial (continuationInitial enemyTurn status other)) (fun _ _ => 0)
  let projected := FlatAdapter.project physical
  physical.trace == expected ++ [.read .opcode (continuationEnd enemyTurn) 0] &&
    projected.registers == (Driver.finalState functional).registers &&
    projected.mode == .running && physical.core.boundaryPC.isSome

private def continuationMatrix : Bool :=
  (List.range 256).all fun raw =>
    continuationHolds false raw.toUInt8 0xA5 &&
      continuationHolds true raw.toUInt8 0xA5 &&
      continuationPhysicalHolds false raw.toUInt8 0xA5 &&
      continuationPhysicalHolds true raw.toUInt8 0xA5

private theorem continuation_matrix_checked : continuationMatrix = true := by
  native_decide

/-- Both duplicated continuation windows clear exactly bits 4 and 6 for every
incoming byte, preserving every other raw status bit and the opposite side. -/
theorem all_charge_continuations_exact (enemyTurn : Bool) (status : UInt8) :
    continuationHolds enemyTurn status 0xA5 = true ∧
      continuationPhysicalHolds enemyTurn status 0xA5 = true := by
  have rows := List.all_eq_true.mp continuation_matrix_checked
  have row := rows status.toNat (List.mem_range.mpr status.toNat_lt)
  have round : status.toNat.toUInt8 = status := by
    apply UInt8.toNat.inj
    simp
  rw [round] at row
  cases enemyTurn <;> simp_all

/-- The retained opcodes are decoded operations, including the exact status bits
used by setup and continuation. -/
theorem decoded_charge_family_control :
    Decode.cb (0xE6 : Byte) = .set ⟨4, by omega⟩ .atHL ∧
    Decode.cb (0xF6 : Byte) = .set ⟨6, by omega⟩ .atHL ∧
    Decode.cb (0xA6 : Byte) = .res ⟨4, by omega⟩ .atHL ∧
    Decode.cb (0xB6 : Byte) = .res ⟨6, by omega⟩ .atHL ∧
    Decode.base (0xFE : Byte) = .legal (.aluAImm .cp) ∧
    Decode.base (0x20 : Byte) = .legal (.jrCond .nz) := by
  native_decide

structure RequiredChargeBytes (rom : Array Byte) : Prop where
  setup : Tables.tableBytes rom (romOffset 0x0F setupEntry) setupBytes.length =
    setupBytes.map (fun byte => byte.toNat.toUInt8)
  playerContinuation : Tables.tableBytes rom
      (romOffset 0x0F playerContinuationEntry) playerContinuationBytes.length =
    playerContinuationBytes.map (fun byte => byte.toNat.toUInt8)
  enemyContinuation : Tables.tableBytes rom
      (romOffset 0x0F enemyContinuationEntry) enemyContinuationBytes.length =
    enemyContinuationBytes.map (fun byte => byte.toNat.toUInt8)

structure CanonicalChargeBytes (sha256 : Sha256) (rom : CanonicalRom) : Prop where
  identity : rom.Valid sha256
  charge : RequiredChargeBytes rom.bytes

def windowAgrees (rom : Array Byte) : Bool :=
  decide (Tables.tableBytes rom (romOffset 0x0F setupEntry) setupBytes.length =
    setupBytes.map (fun byte => byte.toNat.toUInt8)) &&
  decide (Tables.tableBytes rom (romOffset 0x0F playerContinuationEntry)
      playerContinuationBytes.length =
    playerContinuationBytes.map (fun byte => byte.toNat.toUInt8)) &&
  decide (Tables.tableBytes rom (romOffset 0x0F enemyContinuationEntry)
      enemyContinuationBytes.length =
    enemyContinuationBytes.map (fun byte => byte.toNat.toUInt8))

end Battle.Rom.ChargeRoutine
