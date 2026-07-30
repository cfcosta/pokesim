/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Rom.FlyRoutine
import Sm83.FlatAdapter

/-!
# Decoded Dig/Swift control flow

English Pokémon Red gives Swift an unconditional early return from
`MoveHitTest`. That return occurs before the target's Fly/Dig invulnerability
bit is inspected. Dig itself shares `CHARGE_EFFECT` with visible charge moves,
so `ChargeEffect` identifies it separately by move ID `$5b` and sets both
`CHARGING_UP` and `INVULNERABLE`.

This module executes both canonical byte windows through the functional and
physical SM83 semantics. Together they prove the cartridge behavior observed in
promotion game 2047: Dig enters its underground frame, then Swift still hits.
-/

namespace Battle.Rom.SwiftRoutine

open Sm83 Battle.Rom.Closure

private def hitTestEntry : UInt16 := 0x656B
private def hitTestBytes : List Byte :=
  [0x21, 0x67, 0xD0, 0x11, 0xD3, 0xCF, 0x01, 0xE9, 0xCF,
   0xF0, 0xF3, 0xA7, 0x28, 0x09, 0x21, 0x62, 0xD0, 0x11,
   0xCD, 0xCF, 0x01, 0x18, 0xD0, 0x1A, 0xFE, 0x08, 0x20,
   0x06, 0x0A, 0xE6, 0x07, 0xCA, 0x09, 0x66, 0x1A, 0xFE,
   0x11, 0xC8]

private def chargeEntry : UInt16 := 0x78A1
private def chargeBytes : List Byte :=
  [0xCB, 0xE6, 0x1A, 0x1B, 0xFE, 0x2B, 0x20, 0x04,
   0xCB, 0xF6, 0x06, 0x64, 0x1A, 0xFE, 0x5B, 0x20,
   0x04, 0xCB, 0xF6, 0x06, 0xC0]

private def chargeEnd : Word := 0x78B6
private def sentinel : UInt16 := 0x8000
private def stackTop : UInt16 := 0xFFFE
private def hWhoseTurn : Word := 0xFFF3
private def playerStatus1 : Word := 0xD062
private def enemyStatus1 : Word := 0xD067
private def playerMove : Word := 0xCFD2
private def playerEffect : Word := 0xCFD3
private def enemyMove : Word := 0xCFCC
private def enemyEffect : Word := 0xCFCD

private def install : FlatMemory → Word → List Byte → FlatMemory
  | memory, _, [] => memory
  | memory, address, byte :: rest =>
      install (memory.write address byte) (Word.ofNat (address.toNat + 1)) rest

private def targetStatus (enemyTurn : Bool) : Word :=
  if enemyTurn then playerStatus1 else enemyStatus1

private def actingStatus (enemyTurn : Bool) : Word :=
  if enemyTurn then enemyStatus1 else playerStatus1

private def actingMove (enemyTurn : Bool) : Word :=
  if enemyTurn then enemyMove else playerMove

private def actingEffect (enemyTurn : Bool) : Word :=
  if enemyTurn then enemyEffect else playerEffect

/-- The retained control opcodes decode as comparisons, Swift's conditional
return, and the two status-bit writes used by Dig. -/
theorem decoded_swift_dig_control :
    Decode.base (0xFE : Byte) = .legal (.aluAImm .cp) ∧
    Decode.base (0xC8 : Byte) = .legal (.retCond .z) ∧
    Decode.cb (0xE6 : Byte) = .set ⟨4, by omega⟩ .atHL ∧
    Decode.cb (0xF6 : Byte) = .set ⟨6, by omega⟩ .atHL := by
  native_decide

/-! ## Swift's early return -/

private def hitTestMemory (enemyTurn invulnerable : Bool) : FlatMemory :=
  let memory := install default (Word.ofNat hitTestEntry.toNat) hitTestBytes
  let memory := memory.write hWhoseTurn (if enemyTurn then 1 else 0)
  let memory := memory.write playerEffect 0x11
  let memory := memory.write enemyEffect 0x11
  let memory := memory.write playerStatus1
    (if enemyTurn && invulnerable then 0x40 else 0)
  memory.write enemyStatus1 (if !enemyTurn && invulnerable then 0x40 else 0)

private def hitTestInitial (enemyTurn invulnerable : Bool) : FunctionalState :=
  Driver.setupCall (hitTestMemory enemyTurn invulnerable)
    hitTestEntry sentinel stackTop

private def hitTestRun (enemyTurn invulnerable : Bool) : Program.RunResult :=
  Driver.runToReturn (hitTestInitial enemyTurn invulnerable) sentinel 24

private def traceOf : Program.RunResult → List BusEvent
  | .reached _ trace _ | .halted _ trace _ | .stopped _ trace _ |
      .locked _ trace _ | .fuelExhausted _ trace _ => trace

private def stepsOf : Program.RunResult → Nat
  | .reached _ _ count | .halted _ _ count | .stopped _ _ count |
      .locked _ _ count | .fuelExhausted _ _ count => count

private def hitTestTrace (enemyTurn : Bool) : List BusEvent :=
  let base := hitTestEntry.toNat
  let whose : Byte := if enemyTurn then 1 else 0
  let effect := actingEffect enemyTurn
  let initial : List BusEvent :=
    [ .read .opcode (Word.ofNat base) 0x21,
      .read .immediate (Word.ofNat (base + 1)) 0x67,
      .read .immediate (Word.ofNat (base + 2)) 0xD0,
      .read .opcode (Word.ofNat (base + 3)) 0x11,
      .read .immediate (Word.ofNat (base + 4)) 0xD3,
      .read .immediate (Word.ofNat (base + 5)) 0xCF,
      .read .opcode (Word.ofNat (base + 6)) 0x01,
      .read .immediate (Word.ofNat (base + 7)) 0xE9,
      .read .immediate (Word.ofNat (base + 8)) 0xCF,
      .read .opcode (Word.ofNat (base + 9)) 0xF0,
      .read .immediate (Word.ofNat (base + 10)) 0xF3,
      .read .data hWhoseTurn whose,
      .read .opcode (Word.ofNat (base + 11)) 0xA7,
      .read .opcode (Word.ofNat (base + 12)) 0x28,
      .read .immediate (Word.ofNat (base + 13)) 0x09 ]
  let side : List BusEvent := if enemyTurn then
    [ .read .opcode (Word.ofNat (base + 14)) 0x21,
      .read .immediate (Word.ofNat (base + 15)) 0x62,
      .read .immediate (Word.ofNat (base + 16)) 0xD0,
      .read .opcode (Word.ofNat (base + 17)) 0x11,
      .read .immediate (Word.ofNat (base + 18)) 0xCD,
      .read .immediate (Word.ofNat (base + 19)) 0xCF,
      .read .opcode (Word.ofNat (base + 20)) 0x01,
      .read .immediate (Word.ofNat (base + 21)) 0x18,
      .read .immediate (Word.ofNat (base + 22)) 0xD0 ]
  else [.idle (Word.ofNat (base + 14))]
  initial ++ side ++
    [ .read .opcode (Word.ofNat (base + 23)) 0x1A,
      .read .data effect 0x11,
      .read .opcode (Word.ofNat (base + 24)) 0xFE,
      .read .immediate (Word.ofNat (base + 25)) 0x08,
      .read .opcode (Word.ofNat (base + 26)) 0x20,
      .read .immediate (Word.ofNat (base + 27)) 0x06,
      .idle (Word.ofNat (base + 28)),
      .read .opcode (Word.ofNat (base + 34)) 0x1A,
      .read .data effect 0x11,
      .read .opcode (Word.ofNat (base + 35)) 0xFE,
      .read .immediate (Word.ofNat (base + 36)) 0x11,
      .read .opcode (Word.ofNat (base + 37)) 0xC8,
      .idle 0xFFFC,
      .read .stack 0xFFFC 0,
      .read .stack 0xFFFD 0x80,
      .idle (Word.ofNat sentinel.toNat) ]

/-- Executable summary: Swift returns successfully without reading or changing
the target's invulnerability byte. -/
def swiftReturnsBeforeInvulnerability (enemyTurn invulnerable : Bool) : Bool :=
  let result := hitTestRun enemyTurn invulnerable
  let final := Driver.finalState result
  Driver.reachedReturn result &&
    stepsOf result == (if enemyTurn then 15 else 12) &&
    traceOf result == hitTestTrace enemyTurn &&
    final.registers.pc == Word.ofNat sentinel.toNat &&
    Driver.toByte (final.memory.read (targetStatus enemyTurn)) ==
      (if invulnerable then 0x40 else 0)

private def physicalInitial (state : FunctionalState) : FlatCoreState :=
  let core := { Pipeline.bootstrap state.registers with ime := state.ime }
  let core := { core with scheduledImeEnable := state.scheduledImeEnable }
  let core := { core with haltBug := state.haltBug }
  { core, memory := state.memory }

private def swiftPhysicalHolds (enemyTurn invulnerable : Bool) : Bool :=
  let functional := hitTestRun enemyTurn invulnerable
  let expected := hitTestTrace enemyTurn
  let physical := FlatAdapter.run (expected.length + 1)
    (physicalInitial (hitTestInitial enemyTurn invulnerable)) (fun _ _ => 0)
  let projected := FlatAdapter.project physical
  physical.trace == expected ++ [.read .opcode (Word.ofNat sentinel.toNat) 0] &&
    projected.registers == (Driver.finalState functional).registers &&
    projected.mode == .running && physical.core.boundaryPC.isSome

private theorem swift_checked :
    ∀ enemyTurn invulnerable,
      swiftReturnsBeforeInvulnerability enemyTurn invulnerable = true ∧
        swiftPhysicalHolds enemyTurn invulnerable = true := by
  decide

/-- Both acting sides and both target-invulnerability states follow the same
Swift early return in the architectural and physical SM83 models. -/
theorem swift_invulnerability_exact (enemyTurn invulnerable : Bool) :
    swiftReturnsBeforeInvulnerability enemyTurn invulnerable = true ∧
      swiftPhysicalHolds enemyTurn invulnerable = true :=
  swift_checked enemyTurn invulnerable

/-! ## Dig's move-ID-selected invulnerability -/

private def charged (status : UInt8) : UInt8 := status ||| 0x10
private def underground (status : UInt8) : UInt8 := charged status ||| 0x40

private def chargeMemory (enemyTurn : Bool) (status : UInt8) : FlatMemory :=
  let memory := install default (Word.ofNat chargeEntry.toNat) chargeBytes
  let memory := memory.write (actingStatus enemyTurn) (Byte.ofNat status.toNat)
  let memory := memory.write (actingMove enemyTurn) 0x5B
  memory.write (actingEffect enemyTurn) 0x27

private def chargeInitial (enemyTurn : Bool) (status : UInt8) : FunctionalState :=
  let registers := ((default : Registers).setHL (actingStatus enemyTurn)).setDE
    (actingEffect enemyTurn)
  { registers := { registers with pc := Word.ofNat chargeEntry.toNat }
    memory := chargeMemory enemyTurn status }

private def chargeStop (state : FunctionalState) : Bool :=
  state.registers.pc == chargeEnd

private def chargeRun (enemyTurn : Bool) (status : UInt8) : Program.RunResult :=
  Program.runUntil chargeStop 16 (chargeInitial enemyTurn status) [] 0

private def chargeTrace (enemyTurn : Bool) (status : UInt8) : List BusEvent :=
  let base := chargeEntry.toNat
  let statusAddress := actingStatus enemyTurn
  let move := actingMove enemyTurn
  let effect := actingEffect enemyTurn
  let initial : Byte := Byte.ofNat status.toNat
  let charging : Byte := Byte.ofNat (charged status).toNat
  let buried : Byte := Byte.ofNat (underground status).toNat
  [ .read .opcode (Word.ofNat base) 0xCB,
    .read .cbOpcode (Word.ofNat (base + 1)) 0xE6,
    .read .data statusAddress initial,
    .write statusAddress charging,
    .read .opcode (Word.ofNat (base + 2)) 0x1A,
    .read .data effect 0x27,
    .read .opcode (Word.ofNat (base + 3)) 0x1B,
    .idle effect,
    .read .opcode (Word.ofNat (base + 4)) 0xFE,
    .read .immediate (Word.ofNat (base + 5)) 0x2B,
    .read .opcode (Word.ofNat (base + 6)) 0x20,
    .read .immediate (Word.ofNat (base + 7)) 0x04,
    .idle (Word.ofNat (base + 8)),
    .read .opcode (Word.ofNat (base + 12)) 0x1A,
    .read .data move 0x5B,
    .read .opcode (Word.ofNat (base + 13)) 0xFE,
    .read .immediate (Word.ofNat (base + 14)) 0x5B,
    .read .opcode (Word.ofNat (base + 15)) 0x20,
    .read .immediate (Word.ofNat (base + 16)) 0x04,
    .read .opcode (Word.ofNat (base + 17)) 0xCB,
    .read .cbOpcode (Word.ofNat (base + 18)) 0xF6,
    .read .data statusAddress charging,
    .write statusAddress buried,
    .read .opcode (Word.ofNat (base + 19)) 0x06,
    .read .immediate (Word.ofNat (base + 20)) 0xC0 ]

/-- Executable summary of the Dig branch, for every incoming status byte. -/
def digSetsInvulnerable (enemyTurn : Bool) (status : UInt8) : Bool :=
  let result := chargeRun enemyTurn status
  let final := Driver.finalState result
  Driver.reachedReturn result &&
    stepsOf result == 10 &&
    traceOf result == chargeTrace enemyTurn status &&
    final.registers.pc == chargeEnd &&
    Driver.toByte (final.memory.read (actingStatus enemyTurn)) == underground status &&
    Driver.toByte final.registers.b == 0xC0

private def digPhysicalHolds (enemyTurn : Bool) (status : UInt8) : Bool :=
  let functional := chargeRun enemyTurn status
  let expected := chargeTrace enemyTurn status
  let physical := FlatAdapter.run (expected.length + 1)
    (physicalInitial (chargeInitial enemyTurn status)) (fun _ _ => 0)
  let projected := FlatAdapter.project physical
  physical.trace == expected ++ [.read .opcode chargeEnd 0] &&
    projected.registers == (Driver.finalState functional).registers &&
    projected.mode == .running && physical.core.boundaryPC.isSome

private def digExhaustive : Bool :=
  (List.range 256).all fun raw =>
    digSetsInvulnerable false raw.toUInt8 &&
      digSetsInvulnerable true raw.toUInt8 &&
      digPhysicalHolds false raw.toUInt8 &&
      digPhysicalHolds true raw.toUInt8

private theorem dig_exhaustive_checked : digExhaustive = true := by
  native_decide

private theorem dig_checked (enemyTurn : Bool) (status : UInt8) :
    digSetsInvulnerable enemyTurn status = true ∧
      digPhysicalHolds enemyTurn status = true := by
  have rows := List.all_eq_true.mp dig_exhaustive_checked
  have row := rows status.toNat (List.mem_range.mpr status.toNat_lt)
  have round : status.toNat.toUInt8 = status := by
    apply UInt8.toNat.inj
    simp
  simp only [round] at row
  cases enemyTurn <;> simp_all

/-- Dig sets both bits through decoded canonical instructions for either acting
side and every possible incoming status byte. -/
theorem dig_invulnerability_exact (enemyTurn : Bool) (status : UInt8) :
    digSetsInvulnerable enemyTurn status = true ∧
      digPhysicalHolds enemyTurn status = true :=
  dig_checked enemyTurn status

/-- The corrected high-level model rejects an ordinary move while Dig's
move-ID-selected invulnerability is active. -/
theorem model_ordinary_misses_dig (context : Full.Effects.Context)
    (move : Step.ResolvedMove) (attacker : Battle.SideState)
    (rng : Rng.LinkRng) :
    let dig := Full.Effects.applyBefore Data.Effect.charge true
      { context with move := 91 }
    bitSet dig.context.attacker.volatile.status1
        Wram.BattleStatus1.invulnerable = true ∧
      Full.Engine.resolveAccuracy .ordinary move attacker
        dig.context.attacker rng = (false, rng, []) := by
  have charge := Full.Effects.charge_invulnerability_witnesses context
  dsimp
  constructor
  · exact charge.2.2.2.2.2.1
  · exact Full.Engine.invulnerability_precedes_x_accuracy move attacker
      (Full.Effects.applyBefore Data.Effect.charge true { context with move := 91 }).context.attacker
      rng charge.2.2.2.2.2.1

/-- The corrected high-level model agrees with the two decoded control facts:
Dig is underground, while Swift succeeds without consuming accuracy RNG. -/
theorem model_swift_hits_dig (context : Full.Effects.Context)
    (swiftMove : Step.ResolvedMove) (swiftAttacker : Battle.SideState)
    (rng : Rng.LinkRng) :
    let dig := Full.Effects.applyBefore Data.Effect.charge true
      { context with move := 91 }
    bitSet dig.context.attacker.volatile.status1
        Wram.BattleStatus1.invulnerable = true ∧
      Full.Engine.resolveAccuracy .swift swiftMove swiftAttacker
        dig.context.attacker rng = (true, rng, []) := by
  have charge := Full.Effects.charge_invulnerability_witnesses context
  dsimp
  constructor
  · exact charge.2.2.2.2.2.1
  · exact Full.Engine.swift_precedes_accuracy_gates swiftMove swiftAttacker
      (Full.Effects.applyBefore Data.Effect.charge true { context with move := 91 }).context.attacker
      rng

structure RequiredSwiftDigBytes (rom : Array Byte) : Prop where
  hitTest : Tables.tableBytes rom
      (romOffset 0x0F (Word.ofNat hitTestEntry.toNat)) hitTestBytes.length =
    hitTestBytes.map (fun byte => byte.toNat.toUInt8)
  charge : Tables.tableBytes rom
      (romOffset 0x0F (Word.ofNat chargeEntry.toNat)) chargeBytes.length =
    chargeBytes.map (fun byte => byte.toNat.toUInt8)

structure CanonicalSwiftDigBytes (sha256 : Sha256) (rom : CanonicalRom) : Prop where
  identity : rom.Valid sha256
  swiftDig : RequiredSwiftDigBytes rom.bytes

/-- Runtime fixture predicate only; theorem consumers use
`RequiredSwiftDigBytes`. -/
def windowAgrees (rom : Array Byte) : Bool :=
  decide (Tables.tableBytes rom
      (romOffset 0x0F (Word.ofNat hitTestEntry.toNat)) hitTestBytes.length =
    hitTestBytes.map (fun byte => byte.toNat.toUInt8)) &&
  decide (Tables.tableBytes rom
      (romOffset 0x0F (Word.ofNat chargeEntry.toNat)) chargeBytes.length =
    chargeBytes.map (fun byte => byte.toNat.toUInt8))

end Battle.Rom.SwiftRoutine
