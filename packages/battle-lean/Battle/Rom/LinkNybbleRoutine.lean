/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0.
-/
import Battle.Driver
import Battle.Rom.LinkActionProtocol
import Battle.Rom.Closure
import Sm83.FlatAdapter
import Sm83.Program

/-!
# Decoded link-action nybble windows

Pokémon Red's fixed-bank `Serial_ExchangeNybble` frames a semantic action as
`$60 + action`. Its `.doExchange` receive window retains an invalid byte as
stale state, but for a `$6x` byte it clears `hSerialReceiveData`, strips the low
nybble, and stores that value in `wSerialExchangeNybbleReceiveData`.

This module executes those two gameplay-visible windows from decoded bytes.
The framing theorem covers all 16 admitted action nybbles through functional and
physical SM83 execution. The receive theorem covers all 65,536 combinations of
incoming and stale destination bytes functionally; physical execution is also
checked for every incoming byte with a fixed stale marker. The surrounding
call, interrupt wait, repeated synchronization, and frame-delay loops remain a
later paired-machine obligation.
-/

namespace Battle.Rom.LinkNybbleRoutine

open Sm83 Battle.Rom.Closure

private def frameEntry : Word := 0x22C6
private def frameEnd : Word := 0x22CD
private def receiveEntry : Word := 0x22D7
private def receiveReturn : Word := 0x4000
private def stack : Word := 0xF000

private def sendNybble : Word := 0xCC42
private def receiveTemp : Word := 0xCC3D
private def receiveNybble : Word := 0xCC3E
private def hSerialSendData : Word := 0xFFAC
private def hSerialReceiveData : Word := 0xFFAD

private def frameBytes : List Byte :=
  [0xFA, 0x42, 0xCC, 0xC6, 0x60, 0xE0, 0xAC]

private def receiveBytes : List Byte :=
  [0xF0, 0xAD, 0xEA, 0x3D, 0xCC, 0xE6, 0xF0, 0xFE, 0x60, 0xC0,
   0xAF, 0xE0, 0xAD, 0xFA, 0x3D, 0xCC, 0xE6, 0x0F, 0xEA, 0x3E,
   0xCC, 0xC9]

private def install : FlatMemory → Word → List Byte → FlatMemory
  | memory, _, [] => memory
  | memory, address, byte :: rest =>
      install (memory.write address byte) (Word.ofNat (address.toNat + 1)) rest

private def frameInitial (wire : UInt8) : FunctionalState :=
  let memory := install default frameEntry frameBytes
  let memory := memory.write sendNybble (Byte.ofNat wire.toNat)
  { registers := { (default : Registers) with pc := frameEntry }
    memory }

private def frameStop (state : FunctionalState) : Bool :=
  state.registers.pc == frameEnd

private def frameRun (wire : UInt8) : Program.RunResult :=
  Program.runUntil frameStop 5 (frameInitial wire) [] 0

private def receiveInitial (received stale : UInt8) : FunctionalState :=
  let memory := install default receiveEntry receiveBytes
  let memory := memory.write hSerialReceiveData (Byte.ofNat received.toNat)
  let memory := memory.write receiveNybble (Byte.ofNat stale.toNat)
  let memory := memory.write stack receiveReturn.lowByte
  let memory := memory.write (Word.ofNat (stack.toNat + 1)) receiveReturn.highByte
  { registers := { (default : Registers) with pc := receiveEntry, sp := stack }
    memory }

private def receiveStop (state : FunctionalState) : Bool :=
  state.registers.pc == receiveReturn

private def receiveRun (received stale : UInt8) : Program.RunResult :=
  Program.runUntil receiveStop 16 (receiveInitial received stale) [] 0

private def traceOf : Program.RunResult → List BusEvent
  | .reached _ trace _ | .halted _ trace _ | .stopped _ trace _ |
      .locked _ trace _ | .fuelExhausted _ trace _ => trace

private def physicalInitial (state : FunctionalState) : FlatCoreState :=
  let core := { Pipeline.bootstrap state.registers with ime := state.ime }
  let core := { core with scheduledImeEnable := state.scheduledImeEnable }
  let core := { core with haltBug := state.haltBug }
  { core, memory := state.memory }

private def framedByte (wire : UInt8) : UInt8 :=
  LinkActionProtocol.frame wire

private def accepted (received : UInt8) : Bool :=
  received &&& 0xF0 == 0x60

private def expectedReceive (received stale : UInt8) : UInt8 :=
  if accepted received then received &&& 0x0F else stale

private def expectedHReceive (received : UInt8) : UInt8 :=
  if accepted received then 0 else received

/-- Functional decoded execution writes the exact `$60 + action` frame. -/
def frameHolds (wire : UInt8) : Bool :=
  let result := frameRun wire
  let final := Driver.finalState result
  Driver.reachedReturn result && final.registers.pc == frameEnd &&
    Driver.toByte (final.memory.read hSerialSendData) == framedByte wire &&
    Driver.toByte (final.memory.read sendNybble) == wire

/-- Physical half-edge execution agrees with the functional framing window. -/
def framePhysicalHolds (wire : UInt8) : Bool :=
  let functional := frameRun wire
  let expected := traceOf functional
  let physical := FlatAdapter.run (expected.length + 1)
    (physicalInitial (frameInitial wire)) (fun _ _ => 0)
  let projected := FlatAdapter.project physical
  physical.trace == expected ++ [.read .opcode frameEnd 0] &&
    projected.registers == (Driver.finalState functional).registers &&
    projected.mode == .running && physical.core.boundaryPC.isSome

/-- Functional decoded receive filtering preserves malformed/stale behavior. -/
def receiveHolds (received stale : UInt8) : Bool :=
  let result := receiveRun received stale
  let final := Driver.finalState result
  Driver.reachedReturn result && final.registers.pc == receiveReturn &&
    Driver.toByte (final.memory.read receiveTemp) == received &&
    Driver.toByte (final.memory.read receiveNybble) ==
      expectedReceive received stale &&
    Driver.toByte (final.memory.read hSerialReceiveData) ==
      expectedHReceive received

/-- Physical receive execution agrees for every incoming byte. The stale marker
is fixed here because functional execution already quantifies over all 256 stale
values and the retained physical refinement is instruction-universal. -/
def receivePhysicalHolds (received : UInt8) : Bool :=
  let functional := receiveRun received 0xA5
  let expected := traceOf functional
  let physical := FlatAdapter.run (expected.length + 1)
    (physicalInitial (receiveInitial received 0xA5)) (fun _ _ => 0)
  let projected := FlatAdapter.project physical
  physical.trace == expected ++ [.read .opcode receiveReturn 0] &&
    projected.registers == (Driver.finalState functional).registers &&
    projected.mode == .running && physical.core.boundaryPC.isSome

private def frameMatrix : Bool :=
  (List.range 16).all fun wire =>
    frameHolds wire.toUInt8 && framePhysicalHolds wire.toUInt8

private def receiveMatrix : Bool :=
  (List.range 256).all fun received =>
    (List.range 256).all fun stale =>
      receiveHolds received.toUInt8 stale.toUInt8

private def receivePhysicalMatrix : Bool :=
  (List.range 256).all fun received => receivePhysicalHolds received.toUInt8

private def validReceiveMatrix : Bool :=
  (List.range 16).all fun wire =>
    (List.range 256).all fun stale =>
      expectedReceive (framedByte wire.toUInt8) stale.toUInt8 == wire.toUInt8 &&
        expectedHReceive (framedByte wire.toUInt8) == 0

private theorem frame_matrix_checked : frameMatrix = true := by
  native_decide

private theorem receive_matrix_checked : receiveMatrix = true := by
  native_decide

private theorem receive_physical_matrix_checked : receivePhysicalMatrix = true := by
  native_decide

private theorem valid_receive_matrix_checked : validReceiveMatrix = true := by
  native_decide

/-- Every admitted action nybble executes the exact decoded framing window in
both functional and physical SM83 models. -/
theorem frame_exact (wire : UInt8) (range : wire.toNat < 16) :
    frameHolds wire = true ∧ framePhysicalHolds wire = true := by
  have row := (List.all_eq_true.mp frame_matrix_checked) wire.toNat
    (List.mem_range.mpr range)
  have round : wire.toNat.toUInt8 = wire := by
    apply UInt8.toNat.inj
    simp
  simpa only [Bool.and_eq_true, round] using row

/-- All incoming bytes and all stale output bytes execute Red's exact malformed
receive behavior. -/
theorem receive_exact (received stale : UInt8) :
    receiveHolds received stale = true := by
  have rows := List.all_eq_true.mp receive_matrix_checked
  have row := rows received.toNat (List.mem_range.mpr received.toNat_lt)
  have item := (List.all_eq_true.mp row) stale.toNat
    (List.mem_range.mpr stale.toNat_lt)
  have receivedRound : received.toNat.toUInt8 = received := by
    apply UInt8.toNat.inj
    simp
  have staleRound : stale.toNat.toUInt8 = stale := by
    apply UInt8.toNat.inj
    simp
  simpa only [receivedRound, staleRound] using item

/-- Every incoming byte also has a retained physical execution witness. -/
theorem receive_physical_exact (received : UInt8) :
    receivePhysicalHolds received = true := by
  have item := (List.all_eq_true.mp receive_physical_matrix_checked)
    received.toNat (List.mem_range.mpr received.toNat_lt)
  have round : received.toNat.toUInt8 = received := by
    apply UInt8.toNat.inj
    simp
  simpa only [round] using item

/-- The decoded valid receive path agrees with the high nybble unframer. -/
theorem receive_valid_refines_protocol (wire stale : UInt8)
    (range : wire.toNat < 16) :
    let received := framedByte wire
    expectedReceive received stale = wire ∧
      expectedHReceive received = 0 ∧
      LinkActionProtocol.unframe received = some wire := by
  have unframed := LinkActionProtocol.unframe_frame range
  have wireRound : wire.toNat.toUInt8 = wire := by
    apply UInt8.toNat.inj
    simp
  have rows := List.all_eq_true.mp valid_receive_matrix_checked
  have row := rows wire.toNat (List.mem_range.mpr range)
  have item := (List.all_eq_true.mp row) stale.toNat
    (List.mem_range.mpr stale.toNat_lt)
  have staleRound : stale.toNat.toUInt8 = stale := by
    apply UInt8.toNat.inj
    simp
  rw [wireRound, staleRound] at item
  simp only [Bool.and_eq_true, beq_iff_eq] at item
  exact ⟨item.1, item.2, unframed⟩

structure RequiredNybbleBytes (rom : Array Byte) : Prop where
  frame : bytesAt rom frameEntry.toNat frameBytes.length = frameBytes
  receive : bytesAt rom receiveEntry.toNat receiveBytes.length = receiveBytes

structure CanonicalNybbleBytes (sha256 : Sha256) (rom : CanonicalRom) : Prop where
  valid : rom.Valid sha256
  required : RequiredNybbleBytes rom.bytes

/-- Runtime canonical-ROM boundary check for both decoded windows. -/
def windowAgrees (rom : Array Byte) : Bool :=
  decide (bytesAt rom frameEntry.toNat frameBytes.length = frameBytes) &&
    decide (bytesAt rom receiveEntry.toNat receiveBytes.length = receiveBytes)

#guard frameEntry == 0x22C6
#guard receiveEntry == 0x22D7
#guard frameBytes.length == 7
#guard receiveBytes.length == 22

end Battle.Rom.LinkNybbleRoutine
