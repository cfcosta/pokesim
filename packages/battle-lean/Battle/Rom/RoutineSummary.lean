/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Driver
import Sm83.Hoare

/-!
# Compositional decoded-routine execution

`Driver.runToReturn` is useful for closed executable checks, but unfolding a
whole routine is a poor proof principle for loops over symbolic memory. This
module exposes exact-count execution and a decoded-one-step equation that can be
composed instruction by instruction. Fuel remains outside these summaries: a
`runSteps n` value means exactly `n` architectural instructions executed.
-/

namespace Battle.Rom.RoutineSummary

open Sm83

structure Execution where
  state : FunctionalState
  trace : List BusEvent

/-- Execute exactly `count` programmer-visible instructions, retaining the full
ordered M-cycle trace. A non-running state is stable because `Functional.step`
has that behavior; routine contracts normally assume `.running`. -/
def runSteps : Nat → FunctionalState → Execution
  | 0, state => { state, trace := [] }
  | count + 1, state =>
      let first := Functional.step state
      let rest := runSteps count first.state
      { state := rest.state, trace := first.trace ++ rest.trace }

@[simp] theorem runSteps_zero (state : FunctionalState) :
    runSteps 0 state = { state, trace := [] } := rfl

/-- Replace the first architectural step while composing a routine body. -/
theorem runSteps_after_first (count : Nat) (initial after : FunctionalState)
    (first : (Functional.step initial).state = after) :
    (runSteps (count + 1) initial).state = (runSteps count after).state := by
  simp only [runSteps]
  rw [first]

/-- Exact-count executions compose without exposing or re-evaluating either
sub-block. -/
theorem runSteps_add (left right : Nat) (state : FunctionalState) :
    runSteps (left + right) state =
      let firstRun := runSteps left state
      let secondRun := runSteps right firstRun.state
      { state := secondRun.state, trace := firstRun.trace ++ secondRun.trace } := by
  induction left generalizing state with
  | zero => simp [runSteps]
  | succ left induction =>
      simp only [Nat.succ_add, runSteps]
      rw [induction]
      simp [List.append_assoc]

/-- State-only corollary used to compose independently proved routine blocks. -/
theorem runSteps_state_add (left right : Nat) (initial middle final : FunctionalState)
    (first : (runSteps left initial).state = middle)
    (second : (runSteps right middle).state = final) :
    (runSteps (left + right) initial).state = final := by
  have composed := congrArg Execution.state (runSteps_add left right initial)
  rw [composed]
  simp only
  rw [first]
  exact second

/-- The common precondition for local battle routines that do not schedule IME
changes or enter HALT/STOP/lock. -/
def Quiet (state : FunctionalState) : Prop :=
  state.mode = .running ∧ state.haltBug = false ∧ state.scheduledImeEnable = false

/-- The legal branch of `Functional.step`, factored so a caller can rewrite one
known opcode without unfolding the complete 256-way decoder. -/
def legalResult (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (pendingInterrupts : Byte := 0) : FunctionalResult :=
  let opcodeAddress := state.registers.pc
  let nextPc := if state.haltBug then opcodeAddress else Word.ofNat (opcodeAddress.toNat + 1)
  let context : Functional.Context :=
    { state := { state with registers := { state.registers with pc := nextPc }, haltBug := false }
      trace := [.read .opcode opcodeAddress opcode] }
  let (immediate, context) := Functional.fetchImmediate shape.immediateBytes context
  let context := Functional.executeShape context shape immediate pendingInterrupts
  { state := context.state, trace := context.trace }

/-- A memory byte and decoder equality select exactly one legal instruction
shape. This is the reusable bridge from caller-supplied canonical bytes to a
small symbolic state transformer. -/
theorem step_legal (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape)
    (running : state.mode = .running)
    (opcodeAtPc : state.memory.read state.registers.pc = opcode)
    (decoded : Decode.base opcode = .legal shape) :
    Functional.step state = legalResult state opcode shape := by
  simp [Functional.step, legalResult, running, opcodeAtPc, decoded]

/-- State-only projection of `step_legal`. -/
theorem step_legal_state (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape)
    (running : state.mode = .running)
    (opcodeAtPc : state.memory.read state.registers.pc = opcode)
    (decoded : Decode.base opcode = .legal shape) :
    (Functional.step state).state = (legalResult state opcode shape).state := by
  rw [step_legal state opcode shape running opcodeAtPc decoded]

/-- Trace-only projection of `step_legal`. -/
theorem step_legal_trace (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape)
    (running : state.mode = .running)
    (opcodeAtPc : state.memory.read state.registers.pc = opcode)
    (decoded : Decode.base opcode = .legal shape) :
    (Functional.step state).trace = (legalResult state opcode shape).trace := by
  rw [step_legal state opcode shape running opcodeAtPc decoded]

@[simp] theorem ofBytes_high_low : ∀ address : Word,
    Word.ofBytes address.highByte address.lowByte = address := by
  native_decide

private theorem increment_bounded : ∀ address : Word, ∀ offset : Fin 8,
    Word.ofNat ((Word.ofNat (address.toNat + offset.val)).toNat + 1) =
      Word.ofNat (address.toNat + offset.val + 1) := by
  native_decide

@[simp] theorem increment_twice (address : Word) :
    Word.ofNat ((Word.ofNat (address.toNat + 1)).toNat + 1) =
      Word.ofNat (address.toNat + 2) := increment_bounded address ⟨1, by omega⟩

@[simp] theorem increment_after_two (address : Word) :
    Word.ofNat ((Word.ofNat (address.toNat + 2)).toNat + 1) =
      Word.ofNat (address.toNat + 3) := increment_bounded address ⟨2, by omega⟩

@[simp] theorem increment_after_three (address : Word) :
    Word.ofNat ((Word.ofNat (address.toNat + 3)).toNat + 1) =
      Word.ofNat (address.toNat + 4) := increment_bounded address ⟨3, by omega⟩

@[simp] theorem increment_after_four (address : Word) :
    Word.ofNat ((Word.ofNat (address.toNat + 4)).toNat + 1) =
      Word.ofNat (address.toNat + 5) := increment_bounded address ⟨4, by omega⟩

@[simp] theorem increment_after_five (address : Word) :
    Word.ofNat ((Word.ofNat (address.toNat + 5)).toNat + 1) =
      Word.ofNat (address.toNat + 6) := increment_bounded address ⟨5, by omega⟩

@[simp] theorem increment_after_six (address : Word) :
    Word.ofNat ((Word.ofNat (address.toNat + 6)).toNat + 1) =
      Word.ofNat (address.toNat + 7) := increment_bounded address ⟨6, by omega⟩

@[simp] theorem increment_after_seven (address : Word) :
    Word.ofNat ((Word.ofNat (address.toNat + 7)).toNat + 1) =
      Word.ofNat (address.toNat + 8) := increment_bounded address ⟨7, by omega⟩

private theorem first_three_distinct : ∀ address : Word,
    address ≠ Word.ofNat (address.toNat + 1) ∧
    address ≠ Word.ofNat (address.toNat + 2) ∧
    Word.ofNat (address.toNat + 1) ≠ Word.ofNat (address.toNat + 2) := by
  native_decide

theorem address_ne_next (address : Word) :
    address ≠ Word.ofNat (address.toNat + 1) := (first_three_distinct address).1

theorem address_ne_next_two (address : Word) :
    address ≠ Word.ofNat (address.toNat + 2) := (first_three_distinct address).2.1

theorem next_ne_next_two (address : Word) :
    Word.ofNat (address.toNat + 1) ≠ Word.ofNat (address.toNat + 2) :=
  (first_three_distinct address).2.2

def advancePc (state : FunctionalState) : Registers :=
  { state.registers with pc := Word.ofNat (state.registers.pc.toNat + 1) }

/-- State transformer for `LD A,[HL+]`. -/
def ldAFromHlInc (s : FunctionalState) : FunctionalState :=
  let registers := (advancePc s).setHL (Word.ofNat (s.registers.hl.toNat + 1))
  let registers := { registers with a := s.memory.read s.registers.hl }
  let s := { s with registers }
  { s with haltBug := false }

/-- State transformer for `LD [DE],A`. -/
def ldAtDeA (s : FunctionalState) : FunctionalState :=
  let memory := s.memory.write s.registers.de s.registers.a
  let s := { s with registers := advancePc s }
  let s := { s with memory }
  { s with haltBug := false }

/-- State transformer for `LD [HL+],A`. -/
def ldAtHlIncA (s : FunctionalState) : FunctionalState :=
  let memory := s.memory.write s.registers.hl s.registers.a
  let registers := (advancePc s).setHL (Word.ofNat (s.registers.hl.toNat + 1))
  let s := { s with registers }
  let s := { s with memory }
  { s with haltBug := false }

/-- Common two-byte immediate fetch result. -/
def immediateWord (s : FunctionalState) : Word :=
  let lowAddress := Word.ofNat (s.registers.pc.toNat + 1)
  let highAddress := Word.ofNat (lowAddress.toNat + 1)
  Word.ofBytes (s.memory.read highAddress) (s.memory.read lowAddress)

/-- State transformer for `LD A,d8`. -/
def ldAImmediate (s : FunctionalState) : FunctionalState :=
  let immediateAddress := Word.ofNat (s.registers.pc.toNat + 1)
  let registers := { s.registers with a := s.memory.read immediateAddress }
  let registers := { registers with pc := Word.ofNat (immediateAddress.toNat + 1) }
  { s with registers, haltBug := false }

/-- State transformer for `LD HL,d16`. -/
def ldHlImmediate (s : FunctionalState) : FunctionalState :=
  let registers := (s.registers.setHL (immediateWord s))
  let registers := { registers with pc := Word.ofNat (s.registers.pc.toNat + 3) }
  { s with registers, haltBug := false }

/-- State transformer for `LD DE,d16`. -/
def ldDeImmediate (s : FunctionalState) : FunctionalState :=
  let registers := (s.registers.setDE (immediateWord s))
  let registers := { registers with pc := Word.ofNat (s.registers.pc.toNat + 3) }
  { s with registers, haltBug := false }

/-- State transformer for `LDH A,[a8]`. -/
def ldhAImmediate (s : FunctionalState) : FunctionalState :=
  let immediateAddress := Word.ofNat (s.registers.pc.toNat + 1)
  let dataAddress := Word.ofNat (0xFF00 + (s.memory.read immediateAddress).toNat)
  let registers := { s.registers with a := s.memory.read dataAddress }
  let registers := { registers with pc := Word.ofNat (immediateAddress.toNat + 1) }
  { s with registers, haltBug := false }

/-- State transformer for `AND A`. -/
def andA (s : FunctionalState) : FunctionalState :=
  let result := Alu.apply .and s.registers.a s.registers.a s.registers.flags
  let registers := { advancePc s with a := result.value, flags := result.flags }
  { s with registers, haltBug := false }

/-- State transformer for `XOR A`. -/
def xorA (s : FunctionalState) : FunctionalState :=
  let result := Alu.apply .xor s.registers.a s.registers.a s.registers.flags
  let registers := { advancePc s with a := result.value, flags := result.flags }
  { s with registers, haltBug := false }

/-- State transformer for `JR Z,e8`. -/
def jrZ (state : FunctionalState) : FunctionalState :=
  let afterOpcode := Word.ofNat (state.registers.pc.toNat + 1)
  let afterImmediate := Word.ofNat (afterOpcode.toNat + 1)
  let registers := { state.registers with pc := afterImmediate }
  let registers := if Alu.conditionHolds .z registers.flags then
    { registers with pc := (registers.pc.addSignedByte
      (state.memory.read (Word.ofNat (state.registers.pc.toNat + 1)))) }
    else registers
  { state with registers, haltBug := false }

/-- State transformer for `DEC DE`. -/
def decDe (s : FunctionalState) : FunctionalState :=
  let registers := (advancePc s).setDE (Word.ofNat (s.registers.de.toNat + 65535))
  { s with registers, haltBug := false }

/-- State transformer for `LD [HL],d8`. -/
def ldAtHlImmediate (s : FunctionalState) : FunctionalState :=
  let immediateAddress := Word.ofNat (s.registers.pc.toNat + 1)
  let memory := s.memory.write s.registers.hl (s.memory.read immediateAddress)
  let registers := { s.registers with pc := Word.ofNat (immediateAddress.toNat + 1) }
  { s with registers, memory, haltBug := false }

/-- State transformer for `LD [a16],A`. -/
def ldAbsoluteA (s : FunctionalState) : FunctionalState :=
  let memory := s.memory.write (immediateWord s) s.registers.a
  let registers := { s.registers with pc := Word.ofNat (s.registers.pc.toNat + 3) }
  { s with registers, memory, haltBug := false }

/-- State transformer for `JP a16`. -/
def jpAbsolute (s : FunctionalState) : FunctionalState :=
  { s with registers := { s.registers with pc := immediateWord s }, haltBug := false }

/-- State transformer for `LD B,d8`. -/
def ldBImmediate (s : FunctionalState) : FunctionalState :=
  let immediateAddress := Word.ofNat (s.registers.pc.toNat + 1)
  let value := s.memory.read immediateAddress
  let registers := (s.registers.set8 .b value)
  let registers := { registers with pc := Word.ofNat (immediateAddress.toNat + 1) }
  let s := { s with registers }
  { s with haltBug := false }

/-- State transformer for unconditional `CALL a16`. -/
def callAbsolute (s : FunctionalState) : FunctionalState :=
  let lowAddress := Word.ofNat (s.registers.pc.toNat + 1)
  let highAddress := Word.ofNat (lowAddress.toNat + 1)
  let returnAddress := Word.ofNat (highAddress.toNat + 1)
  let target := Word.ofBytes (s.memory.read highAddress) (s.memory.read lowAddress)
  let highStack := Word.ofNat (s.registers.sp.toNat + 65535)
  let lowStack := Word.ofNat (highStack.toNat + 65535)
  let memory := (s.memory.write highStack returnAddress.highByte).write
    lowStack returnAddress.lowByte
  let registers := { s.registers with sp := lowStack, pc := target }
  let s := { s with registers }
  let s := { s with memory }
  { s with haltBug := false }

/-- State transformer for unconditional `RET`. -/
def ret (s : FunctionalState) : FunctionalState :=
  let low := s.memory.read s.registers.sp
  let second := Word.ofNat (s.registers.sp.toNat + 1)
  let high := s.memory.read second
  let target := Word.ofBytes high low
  let registers := { s.registers with
    sp := Word.ofNat (second.toNat + 1), pc := target }
  let s := { s with registers }
  { s with haltBug := false }

/-- State transformer for `INC HL`. -/
def incHl (s : FunctionalState) : FunctionalState :=
  let registers := (advancePc s).setHL (Word.ofNat (s.registers.hl.toNat + 1))
  let s := { s with registers }
  { s with haltBug := false }

/-- State transformer for `LD A,[HL]`. -/
def ldAAtHl (s : FunctionalState) : FunctionalState :=
  let registers := { advancePc s with a := s.memory.read s.registers.hl }
  let s := { s with registers }
  { s with haltBug := false }

/-- State transformer for `LD [HL],A`. -/
def ldAtHlA (s : FunctionalState) : FunctionalState :=
  let memory := s.memory.write s.registers.hl s.registers.a
  let s := { s with registers := advancePc s }
  let s := { s with memory }
  { s with haltBug := false }

/-- State transformer for `AND d8`. -/
def andImmediate (s : FunctionalState) : FunctionalState :=
  let immediateAddress := Word.ofNat (s.registers.pc.toNat + 1)
  let operand := s.memory.read immediateAddress
  let result := Alu.and8 s.registers.a operand
  let registers := { s.registers with pc := Word.ofNat (immediateAddress.toNat + 1) }
  let registers := { registers with a := result.value }
  let registers := { registers with flags := result.flags }
  let s := { s with registers }
  { s with haltBug := false }

/-- State transformer for `RES 7,[HL]`, including the two-byte CB fetch. -/
def res7AtHl (s : FunctionalState) : FunctionalState :=
  let value := Alu.resetBit ⟨7, by omega⟩ (s.memory.read s.registers.hl)
  let memory := s.memory.write s.registers.hl value
  let afterPrefix := Word.ofNat (s.registers.pc.toNat + 1)
  let registers := { s.registers with pc := Word.ofNat (afterPrefix.toNat + 1) }
  let s := { s with registers }
  let s := { s with memory }
  { s with haltBug := false }

/-- State transformer for `INC DE`. -/
def incDe (s : FunctionalState) : FunctionalState :=
  let registers := (advancePc s).setDE (Word.ofNat (s.registers.de.toNat + 1))
  let s := { s with registers }
  { s with haltBug := false }

/-- State transformer for `DEC B`, including exact flags. -/
def decB (s : FunctionalState) : FunctionalState :=
  let registers := advancePc s
  let result := Alu.dec8 registers.b registers.flags
  let registers := registers.set8 .b result.value
  let registers := { registers with flags := result.flags }
  let s := { s with registers }
  { s with haltBug := false }

/-- State transformer for `JR NZ,e8`. -/
def jrNz (state : FunctionalState) : FunctionalState :=
  let afterOpcode := Word.ofNat (state.registers.pc.toNat + 1)
  let afterImmediate := Word.ofNat (afterOpcode.toNat + 1)
  let registers := { state.registers with pc := afterImmediate }
  let registers := if Alu.conditionHolds .nz registers.flags then
    { registers with pc := (registers.pc.addSignedByte
      (state.memory.read (Word.ofNat (state.registers.pc.toNat + 1)))) }
    else registers
  { state with registers, haltBug := false }

macro "routine_instruction_simp" : tactic => `(tactic|
  simp [legalResult, InstructionShape.immediateBytes, Functional.fetchImmediate,
    Functional.executeShape, Functional.readMem16, Functional.writeMem16,
    Functional.popWord, Functional.incrementSP, Functional.pushWord,
    Functional.decrementSP,
    Functional.read, Functional.write, Functional.idle, Functional.withRegisters,
    Functional.updateMemoryPointer, Functional.memoryAddress, Functional.readTarget,
    Functional.writeTarget, Functional.matureIme, Functional.setFlags,
    Registers.setHL, Registers.setDE, Registers.hl, Registers.de, Registers.set8,
    Registers.set16, Registers.get16, Registers.get8, Functional.immediate8,
    Functional.immediate16,
    Word.highByte, Word.lowByte, advancePc, ldAFromHlInc, ldAtDeA, ldAtHlIncA,
    immediateWord, ldAImmediate, ldHlImmediate, ldDeImmediate, ldhAImmediate,
    andA, xorA, jrZ, decDe, ldAtHlImmediate, ldAbsoluteA, jpAbsolute,
    ldBImmediate, callAbsolute, ret, incHl, ldAAtHl, ldAtHlA, andImmediate,
    res7AtHl, incDe,
    decB, Alu.apply,
    jrNz, *])

/-- Exact decoded `LD A,[HL+]` state equation. -/
theorem step_ldAFromHlInc (state : FunctionalState)
    (running : state.mode = .running) (scheduled : state.scheduledImeEnable = false)
    (noHaltBug : state.haltBug = false)
    (opcode : state.memory.read state.registers.pc = 0x2A) :
    (Functional.step state).state = ldAFromHlInc state := by
  have decoded : Decode.base (0x2A : Byte) = .legal (.ldAFromMem16 .atHLInc) := by
    native_decide
  rw [step_legal_state state 0x2A _ running opcode decoded]
  routine_instruction_simp

/-- Exact decoded `LD [DE],A` state equation. -/
theorem step_ldAtDeA (state : FunctionalState)
    (running : state.mode = .running) (scheduled : state.scheduledImeEnable = false)
    (noHaltBug : state.haltBug = false)
    (opcode : state.memory.read state.registers.pc = 0x12) :
    (Functional.step state).state = ldAtDeA state := by
  have decoded : Decode.base (0x12 : Byte) = .legal (.ldMem16A .atDE) := by
    native_decide
  rw [step_legal_state state 0x12 _ running opcode decoded]
  routine_instruction_simp

/-- Exact decoded `LD [HL+],A` state equation. -/
theorem step_ldAtHlIncA (state : FunctionalState)
    (running : state.mode = .running) (scheduled : state.scheduledImeEnable = false)
    (noHaltBug : state.haltBug = false)
    (opcode : state.memory.read state.registers.pc = 0x22) :
    (Functional.step state).state = ldAtHlIncA state := by
  have decoded : Decode.base (0x22 : Byte) = .legal (.ldMem16A .atHLInc) := by
    native_decide
  rw [step_legal_state state 0x22 _ running opcode decoded]
  routine_instruction_simp

/-- Exact decoded `LD A,d8` state equation. -/
theorem step_ldAImmediate (state : FunctionalState)
    (running : state.mode = .running) (scheduled : state.scheduledImeEnable = false)
    (noHaltBug : state.haltBug = false)
    (opcode : state.memory.read state.registers.pc = 0x3E) :
    (Functional.step state).state = ldAImmediate state := by
  have decoded : Decode.base (0x3E : Byte) = .legal (.ld8Imm (.reg .a)) := by native_decide
  rw [step_legal_state state 0x3E _ running opcode decoded]
  routine_instruction_simp

/-- Exact decoded `LD HL,d16` state equation. -/
theorem step_ldHlImmediate (state : FunctionalState)
    (running : state.mode = .running) (scheduled : state.scheduledImeEnable = false)
    (noHaltBug : state.haltBug = false)
    (opcode : state.memory.read state.registers.pc = 0x21) :
    (Functional.step state).state = ldHlImmediate state := by
  have decoded : Decode.base (0x21 : Byte) = .legal (.ld16Imm .hl) := by native_decide
  rw [step_legal_state state 0x21 _ running opcode decoded]
  routine_instruction_simp

/-- Exact decoded `LD DE,d16` state equation. -/
theorem step_ldDeImmediate (state : FunctionalState)
    (running : state.mode = .running) (scheduled : state.scheduledImeEnable = false)
    (noHaltBug : state.haltBug = false)
    (opcode : state.memory.read state.registers.pc = 0x11) :
    (Functional.step state).state = ldDeImmediate state := by
  have decoded : Decode.base (0x11 : Byte) = .legal (.ld16Imm .de) := by native_decide
  rw [step_legal_state state 0x11 _ running opcode decoded]
  routine_instruction_simp

/-- Exact decoded `LDH A,[a8]` state equation. -/
theorem step_ldhAImmediate (state : FunctionalState)
    (running : state.mode = .running) (scheduled : state.scheduledImeEnable = false)
    (noHaltBug : state.haltBug = false)
    (opcode : state.memory.read state.registers.pc = 0xF0) :
    (Functional.step state).state = ldhAImmediate state := by
  have decoded : Decode.base (0xF0 : Byte) = .legal .ldhAImm := by native_decide
  rw [step_legal_state state 0xF0 _ running opcode decoded]
  routine_instruction_simp

/-- Exact decoded `AND A` state equation. -/
theorem step_andA (state : FunctionalState)
    (running : state.mode = .running) (scheduled : state.scheduledImeEnable = false)
    (noHaltBug : state.haltBug = false)
    (opcode : state.memory.read state.registers.pc = 0xA7) :
    (Functional.step state).state = andA state := by
  have decoded : Decode.base (0xA7 : Byte) = .legal (.aluA .and (.reg .a)) := by native_decide
  rw [step_legal_state state 0xA7 _ running opcode decoded]
  routine_instruction_simp

/-- Exact decoded `XOR A` state equation. -/
theorem step_xorA (state : FunctionalState)
    (running : state.mode = .running) (scheduled : state.scheduledImeEnable = false)
    (noHaltBug : state.haltBug = false)
    (opcode : state.memory.read state.registers.pc = 0xAF) :
    (Functional.step state).state = xorA state := by
  have decoded : Decode.base (0xAF : Byte) = .legal (.aluA .xor (.reg .a)) := by native_decide
  rw [step_legal_state state 0xAF _ running opcode decoded]
  routine_instruction_simp

/-- Exact decoded `JR Z,e8` state equation. -/
theorem step_jrZ (state : FunctionalState)
    (running : state.mode = .running) (scheduled : state.scheduledImeEnable = false)
    (noHaltBug : state.haltBug = false)
    (opcode : state.memory.read state.registers.pc = 0x28) :
    (Functional.step state).state = jrZ state := by
  have decoded : Decode.base (0x28 : Byte) = .legal (.jrCond .z) := by native_decide
  rw [step_legal_state state 0x28 _ running opcode decoded]
  routine_instruction_simp
  split <;> simp_all

/-- Exact decoded `DEC DE` state equation. -/
theorem step_decDe (state : FunctionalState)
    (running : state.mode = .running) (scheduled : state.scheduledImeEnable = false)
    (noHaltBug : state.haltBug = false)
    (opcode : state.memory.read state.registers.pc = 0x1B) :
    (Functional.step state).state = decDe state := by
  have decoded : Decode.base (0x1B : Byte) = .legal (.dec16 .de) := by native_decide
  rw [step_legal_state state 0x1B _ running opcode decoded]
  routine_instruction_simp

/-- Exact decoded `LD [HL],d8` state equation. -/
theorem step_ldAtHlImmediate (state : FunctionalState)
    (running : state.mode = .running) (scheduled : state.scheduledImeEnable = false)
    (noHaltBug : state.haltBug = false)
    (opcode : state.memory.read state.registers.pc = 0x36) :
    (Functional.step state).state = ldAtHlImmediate state := by
  have decoded : Decode.base (0x36 : Byte) = .legal (.ld8Imm .atHL) := by native_decide
  rw [step_legal_state state 0x36 _ running opcode decoded]
  routine_instruction_simp

/-- Exact decoded `LD [a16],A` state equation. -/
theorem step_ldAbsoluteA (state : FunctionalState)
    (running : state.mode = .running) (scheduled : state.scheduledImeEnable = false)
    (noHaltBug : state.haltBug = false)
    (opcode : state.memory.read state.registers.pc = 0xEA) :
    (Functional.step state).state = ldAbsoluteA state := by
  have decoded : Decode.base (0xEA : Byte) = .legal .ldAbsA := by native_decide
  rw [step_legal_state state 0xEA _ running opcode decoded]
  routine_instruction_simp

/-- Exact decoded `JP a16` state equation. -/
theorem step_jpAbsolute (state : FunctionalState)
    (running : state.mode = .running) (scheduled : state.scheduledImeEnable = false)
    (noHaltBug : state.haltBug = false)
    (opcode : state.memory.read state.registers.pc = 0xC3) :
    (Functional.step state).state = jpAbsolute state := by
  have decoded : Decode.base (0xC3 : Byte) = .legal .jp := by native_decide
  rw [step_legal_state state 0xC3 _ running opcode decoded]
  routine_instruction_simp

/-- Exact decoded `LD B,d8` state equation. -/
theorem step_ldBImmediate (state : FunctionalState)
    (running : state.mode = .running) (scheduled : state.scheduledImeEnable = false)
    (noHaltBug : state.haltBug = false)
    (opcode : state.memory.read state.registers.pc = 0x06) :
    (Functional.step state).state = ldBImmediate state := by
  have decoded : Decode.base (0x06 : Byte) = .legal (.ld8Imm (.reg .b)) := by
    native_decide
  rw [step_legal_state state 0x06 _ running opcode decoded]
  routine_instruction_simp

/-- Exact decoded unconditional `CALL a16` state equation. -/
theorem step_callAbsolute (state : FunctionalState)
    (running : state.mode = .running) (scheduled : state.scheduledImeEnable = false)
    (noHaltBug : state.haltBug = false)
    (opcode : state.memory.read state.registers.pc = 0xCD) :
    (Functional.step state).state = callAbsolute state := by
  have decoded : Decode.base (0xCD : Byte) = .legal .call := by native_decide
  rw [step_legal_state state 0xCD _ running opcode decoded]
  routine_instruction_simp

/-- Exact decoded unconditional `RET` state equation. -/
theorem step_ret (state : FunctionalState)
    (running : state.mode = .running) (scheduled : state.scheduledImeEnable = false)
    (noHaltBug : state.haltBug = false)
    (opcode : state.memory.read state.registers.pc = 0xC9) :
    (Functional.step state).state = ret state := by
  have decoded : Decode.base (0xC9 : Byte) = .legal .ret := by native_decide
  rw [step_legal_state state 0xC9 _ running opcode decoded]
  routine_instruction_simp

/-- Exact decoded `INC HL` state equation. -/
theorem step_incHl (state : FunctionalState)
    (running : state.mode = .running) (scheduled : state.scheduledImeEnable = false)
    (noHaltBug : state.haltBug = false)
    (opcode : state.memory.read state.registers.pc = 0x23) :
    (Functional.step state).state = incHl state := by
  have decoded : Decode.base (0x23 : Byte) = .legal (.inc16 .hl) := by native_decide
  rw [step_legal_state state 0x23 _ running opcode decoded]
  routine_instruction_simp

/-- Exact decoded `LD A,[HL]` state equation. -/
theorem step_ldAAtHl (state : FunctionalState)
    (running : state.mode = .running) (scheduled : state.scheduledImeEnable = false)
    (noHaltBug : state.haltBug = false)
    (opcode : state.memory.read state.registers.pc = 0x7E) :
    (Functional.step state).state = ldAAtHl state := by
  have decoded : Decode.base (0x7E : Byte) = .legal (.ld8 (.reg .a) .atHL) := by
    native_decide
  rw [step_legal_state state 0x7E _ running opcode decoded]
  routine_instruction_simp

/-- Exact decoded `LD [HL],A` state equation. -/
theorem step_ldAtHlA (state : FunctionalState)
    (running : state.mode = .running) (scheduled : state.scheduledImeEnable = false)
    (noHaltBug : state.haltBug = false)
    (opcode : state.memory.read state.registers.pc = 0x77) :
    (Functional.step state).state = ldAtHlA state := by
  have decoded : Decode.base (0x77 : Byte) = .legal (.ld8 .atHL (.reg .a)) := by
    native_decide
  rw [step_legal_state state 0x77 _ running opcode decoded]
  routine_instruction_simp

/-- Exact decoded `AND d8` state equation. -/
theorem step_andImmediate (state : FunctionalState)
    (running : state.mode = .running) (scheduled : state.scheduledImeEnable = false)
    (noHaltBug : state.haltBug = false)
    (opcode : state.memory.read state.registers.pc = 0xE6) :
    (Functional.step state).state = andImmediate state := by
  have decoded : Decode.base (0xE6 : Byte) = .legal (.aluAImm .and) := by native_decide
  rw [step_legal_state state 0xE6 _ running opcode decoded]
  routine_instruction_simp

/-- Exact decoded `RES 7,[HL]` state equation. -/
theorem step_res7AtHl (state : FunctionalState)
    (running : state.mode = .running) (scheduled : state.scheduledImeEnable = false)
    (noHaltBug : state.haltBug = false)
    (prefixAtPc : state.memory.read state.registers.pc = 0xCB)
    (subopcode : state.memory.read (Word.ofNat (state.registers.pc.toNat + 1)) = 0xBE) :
    (Functional.step state).state = res7AtHl state := by
  have baseDecoded : Decode.base (0xCB : Byte) = .prefix := by native_decide
  have cbDecoded : Decode.cb (0xBE : Byte) = .res ⟨7, by omega⟩ .atHL := by native_decide
  unfold Functional.step
  simp only [running]
  rw [prefixAtPc]
  simp only [noHaltBug, Bool.false_eq_true, if_false, baseDecoded]
  simp only [Functional.read]
  rw [subopcode, cbDecoded]
  simp [res7AtHl, Functional.executeShape, Functional.readTarget,
    Functional.writeTarget, Functional.read, Functional.write,
    Functional.withRegisters, Functional.matureIme, Registers.hl, scheduled, running]

/-- Exact decoded `INC DE` state equation. -/
theorem step_incDe (state : FunctionalState)
    (running : state.mode = .running) (scheduled : state.scheduledImeEnable = false)
    (noHaltBug : state.haltBug = false)
    (opcode : state.memory.read state.registers.pc = 0x13) :
    (Functional.step state).state = incDe state := by
  have decoded : Decode.base (0x13 : Byte) = .legal (.inc16 .de) := by native_decide
  rw [step_legal_state state 0x13 _ running opcode decoded]
  routine_instruction_simp

/-- Exact decoded `DEC B` state equation. -/
theorem step_decB (state : FunctionalState)
    (running : state.mode = .running) (scheduled : state.scheduledImeEnable = false)
    (noHaltBug : state.haltBug = false)
    (opcode : state.memory.read state.registers.pc = 0x05) :
    (Functional.step state).state = decB state := by
  have decoded : Decode.base (0x05 : Byte) = .legal (.dec8 (.reg .b)) := by native_decide
  rw [step_legal_state state 0x05 _ running opcode decoded]
  routine_instruction_simp

/-- Exact decoded `JR NZ,e8` state equation. -/
theorem step_jrNz (state : FunctionalState)
    (running : state.mode = .running) (scheduled : state.scheduledImeEnable = false)
    (noHaltBug : state.haltBug = false)
    (opcode : state.memory.read state.registers.pc = 0x20) :
    (Functional.step state).state = jrNz state := by
  have decoded : Decode.base (0x20 : Byte) = .legal (.jrCond .nz) := by native_decide
  rw [step_legal_state state 0x20 _ running opcode decoded]
  routine_instruction_simp
  split <;> rfl

/-- A write-set frame composes through an explicit intermediate state. -/
theorem frames_trans {first middle last : FunctionalState}
    {leftWrites rightWrites : Word → Prop}
    (left : Hoare.Frames leftWrites first middle)
    (right : Hoare.Frames rightWrites middle last) :
    Hoare.Frames (fun address => leftWrites address ∨ rightWrites address) first last := by
  intro address outside
  have outsideLeft : ¬leftWrites address := fun inside => outside (Or.inl inside)
  have outsideRight : ¬rightWrites address := fun inside => outside (Or.inr inside)
  rw [right address outsideRight, left address outsideLeft]

end Battle.Rom.RoutineSummary
