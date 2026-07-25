/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Rom.TransformRoutine
import Battle.Rom.RoutineSummary

/-!
# Compositional decoded Haze helpers

The eight-byte `ResetStats` loop defeated monolithic symbolic
`Driver.runToReturn` unfolding. This module replaces that approach with decoded
instruction contracts, exact-count block composition, and explicit call/return
summaries. It proves all three helpers, the 147-instruction common reset prefix,
all four turn/status gameplay paths through cleanup, and dispatch into the
presentation tail without enumerating symbolic stat or status vectors.

The complete gameplay and helper windows remain explicit canonical-ROM
obligations. `CallBankF` and the move animation are represented by a named exact
execution contract; once supplied, `haze_core_to_print_exact` composes the whole
handler to the canonical `PrintText` entry. This does not claim that the external
presentation routine has already been refined.
-/

namespace Battle.Rom.HazeRoutine

open Sm83 Battle.Rom.Closure

private def hazeEntry : UInt16 := 0x79DA
private def hazeBytes : List Byte :=
  [0x3E, 0x07, 0x21, 0x1A, 0xCD, 0xCD, 0x43, 0x7A,
   0x21, 0x2E, 0xCD, 0xCD, 0x43, 0x7A, 0x21, 0x12,
   0xCD, 0x11, 0x25, 0xD0, 0xCD, 0x4A, 0x7A, 0x21,
   0x26, 0xCD, 0x11, 0xF6, 0xCF, 0xCD, 0x4A, 0x7A,
   0x21, 0xE9, 0xCF, 0x11, 0xDD, 0xCC, 0xF0, 0xF3,
   0xA7, 0x28, 0x04, 0x21, 0x18, 0xD0, 0x1B, 0x7E,
   0x36, 0x00, 0xE6, 0x27, 0x28, 0x03, 0x3E, 0xFF,
   0x12, 0xAF, 0xEA, 0x6D, 0xD0, 0xEA, 0x72, 0xD0,
   0x21, 0xEE, 0xCC, 0x22, 0x77, 0x21, 0x62, 0xD0,
   0xCD, 0x37, 0x7A, 0x21, 0x67, 0xD0, 0xCD, 0x37,
   0x7A, 0x21, 0xA8, 0x7B, 0xCD, 0xD5, 0x79, 0x21,
   0x53, 0x7A, 0xC3, 0x49, 0x3C]

private def helpersEntry : UInt16 := 0x7A37
private def helperBytes : List Byte :=
  [0xCB, 0xBE, 0x23, 0x7E, 0xE6, 0x78, 0x22, 0x7E,
   0xE6, 0xF8, 0x77, 0xC9, 0x06, 0x08, 0x22, 0x05,
   0x20, 0xFC, 0xC9, 0x06, 0x08, 0x2A, 0x12, 0x13,
   0x05, 0x20, 0xFA, 0xC9]

private def resetStatsLoop : Word := 0x7A4C

private def BlockCodeAt (state : FunctionalState) : Prop :=
  state.memory.read 0x7A4C = 0x2A ∧ state.memory.read 0x7A4D = 0x12 ∧
  state.memory.read 0x7A4E = 0x13 ∧ state.memory.read 0x7A4F = 0x05 ∧
  state.memory.read 0x7A50 = 0x20

private def BlockCodeSafe (state : FunctionalState) : Prop :=
  state.registers.de ≠ 0x7A4E ∧ state.registers.de ≠ 0x7A4F ∧
  state.registers.de ≠ 0x7A50

/-- The semantic composition of the five decoded loop instructions. -/
def resetStatsBlock (state : FunctionalState) : FunctionalState :=
  RoutineSummary.jrNz (RoutineSummary.decB (RoutineSummary.incDe
    (RoutineSummary.ldAtDeA (RoutineSummary.ldAFromHlInc state))))

/-- One arbitrary loop iteration is exactly five architectural instructions.
No source-data enumeration occurs. -/
theorem resetStats_block_exact (state : FunctionalState)
    (quiet : RoutineSummary.Quiet state)
    (pc : state.registers.pc = resetStatsLoop)
    (code : BlockCodeAt state) (safe : BlockCodeSafe state) :
    (RoutineSummary.runSteps 5 state).state = resetStatsBlock state := by
  rcases quiet with ⟨running, noHaltBug, scheduled⟩
  rcases code with ⟨op2a, op12, op13, op05, op20⟩
  rcases safe with ⟨safe13, safe05, safe20⟩
  have first := RoutineSummary.step_ldAFromHlInc state running scheduled noHaltBug
    (by simpa [pc, resetStatsLoop] using op2a)
  let s1 := RoutineSummary.ldAFromHlInc state
  have running1 : s1.mode = .running := by
    simp [s1, RoutineSummary.ldAFromHlInc, running]
  have scheduled1 : s1.scheduledImeEnable = false := by
    simp [s1, RoutineSummary.ldAFromHlInc, scheduled]
  have halt1 : s1.haltBug = false := by simp [s1, RoutineSummary.ldAFromHlInc]
  have pc1 : s1.registers.pc = 0x7A4D := by
    simp [s1, RoutineSummary.ldAFromHlInc, RoutineSummary.advancePc,
      Registers.setHL, pc, resetStatsLoop]
    native_decide
  have second := RoutineSummary.step_ldAtDeA s1 running1 scheduled1 halt1
    (by simpa [pc1] using op12)
  let s2 := RoutineSummary.ldAtDeA s1
  have running2 : s2.mode = .running := by simp [s2, RoutineSummary.ldAtDeA, running1]
  have scheduled2 : s2.scheduledImeEnable = false := by
    simp [s2, RoutineSummary.ldAtDeA, scheduled1]
  have halt2 : s2.haltBug = false := by simp [s2, RoutineSummary.ldAtDeA]
  have pc2 : s2.registers.pc = 0x7A4E := by
    simp [s2, RoutineSummary.ldAtDeA, RoutineSummary.advancePc, pc1]
    native_decide
  have op13' : s2.memory.read s2.registers.pc = 0x13 := by
    rw [pc2]
    change (s1.memory.write s1.registers.de s1.registers.a).read 0x7A4E = 0x13
    rw [FlatMemory.read_write_other]
    · simpa [s1, RoutineSummary.ldAFromHlInc] using op13
    · simpa [s1, RoutineSummary.ldAFromHlInc] using Ne.symm safe13
  have third := RoutineSummary.step_incDe s2 running2 scheduled2 halt2 op13'
  let s3 := RoutineSummary.incDe s2
  have running3 : s3.mode = .running := by simp [s3, RoutineSummary.incDe, running2]
  have scheduled3 : s3.scheduledImeEnable = false := by
    simp [s3, RoutineSummary.incDe, scheduled2]
  have halt3 : s3.haltBug = false := by simp [s3, RoutineSummary.incDe]
  have pc3 : s3.registers.pc = 0x7A4F := by
    simp [s3, RoutineSummary.incDe, RoutineSummary.advancePc, Registers.setDE, pc2]
    native_decide
  have op05' : s3.memory.read s3.registers.pc = 0x05 := by
    rw [pc3]
    change (s1.memory.write s1.registers.de s1.registers.a).read 0x7A4F = 0x05
    rw [FlatMemory.read_write_other]
    · simpa [s1, RoutineSummary.ldAFromHlInc] using op05
    · simpa [s1, RoutineSummary.ldAFromHlInc] using Ne.symm safe05
  have fourth := RoutineSummary.step_decB s3 running3 scheduled3 halt3 op05'
  let s4 := RoutineSummary.decB s3
  have running4 : s4.mode = .running := by simp [s4, RoutineSummary.decB, running3]
  have scheduled4 : s4.scheduledImeEnable = false := by
    simp [s4, RoutineSummary.decB, scheduled3]
  have halt4 : s4.haltBug = false := by simp [s4, RoutineSummary.decB]
  have pc4 : s4.registers.pc = 0x7A50 := by
    simp [s4, RoutineSummary.decB, RoutineSummary.advancePc, Registers.set8, pc3]
    native_decide
  have op20' : s4.memory.read s4.registers.pc = 0x20 := by
    rw [pc4]
    change (s1.memory.write s1.registers.de s1.registers.a).read 0x7A50 = 0x20
    rw [FlatMemory.read_write_other]
    · simpa [s1, RoutineSummary.ldAFromHlInc] using op20
    · simpa [s1, RoutineSummary.ldAFromHlInc] using Ne.symm safe20
  have fifth := RoutineSummary.step_jrNz s4 running4 scheduled4 halt4 op20'
  simp only [RoutineSummary.runSteps]
  rw [first, second, third, fourth, fifth]
  rfl

private def beforeJr (state : FunctionalState) : FunctionalState :=
  RoutineSummary.decB (RoutineSummary.incDe
    (RoutineSummary.ldAtDeA (RoutineSummary.ldAFromHlInc state)))

private theorem beforeJr_exact (state : FunctionalState) :
    let out := beforeJr state
    out.memory = state.memory.write state.registers.de
      (state.memory.read state.registers.hl) ∧
    out.registers.hl = Word.ofNat (state.registers.hl.toNat + 1) ∧
    out.registers.de = Word.ofNat (state.registers.de.toNat + 1) ∧
    out.registers.b = (Alu.dec8 state.registers.b state.registers.flags).value := by
  simp [beforeJr, RoutineSummary.ldAFromHlInc, RoutineSummary.ldAtDeA,
    RoutineSummary.incDe, RoutineSummary.decB, RoutineSummary.advancePc,
    Registers.setHL, Registers.setDE, Registers.set8, Registers.hl, Registers.de]

private theorem jrNz_data (state : FunctionalState) :
    let out := RoutineSummary.jrNz state
    out.memory = state.memory ∧ out.registers.hl = state.registers.hl ∧
    out.registers.de = state.registers.de ∧ out.registers.b = state.registers.b := by
  simp only [RoutineSummary.jrNz]
  split <;> simp [Registers.hl, Registers.de]

private theorem dec_small_value (n : Nat) (bound : n < 8) (flags : Flags) :
    (Alu.dec8 (Byte.ofNat (n + 1)) flags).value = Byte.ofNat n := by
  have finite : n = 0 ∨ n = 1 ∨ n = 2 ∨ n = 3 ∨ n = 4 ∨ n = 5 ∨
      n = 6 ∨ n = 7 := by omega
  rcases finite with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;>
    simp [Alu.dec8] <;> native_decide

private theorem dec_small_zero (n : Nat) (bound : n < 8) (flags : Flags) :
    (Alu.dec8 (Byte.ofNat (n + 1)) flags).flags.z = decide (n = 0) := by
  have finite : n = 0 ∨ n = 1 ∨ n = 2 ∨ n = 3 ∨ n = 4 ∨ n = 5 ∨
      n = 6 ∨ n = 7 := by omega
  rcases finite with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;>
    simp [Alu.dec8] <;> native_decide

/-- The same arbitrary iteration copies exactly one byte, increments both
pointers, decrements `B`, and either loops or falls through after the eighth
copy. -/
theorem resetStats_block_effect (state : FunctionalState) (n : Nat) (bound : n < 8)
    (pc : state.registers.pc = resetStatsLoop)
    (count : state.registers.b = Byte.ofNat (n + 1))
    (offset : state.memory.read 0x7A51 = 0xFA)
    (safeOffset : state.registers.de ≠ 0x7A51) :
    let out := resetStatsBlock state
    out.memory.read state.registers.de = state.memory.read state.registers.hl ∧
    out.registers.hl = Word.ofNat (state.registers.hl.toNat + 1) ∧
    out.registers.de = Word.ofNat (state.registers.de.toNat + 1) ∧
    out.registers.b = Byte.ofNat n ∧
    out.registers.pc = (if n = 0 then 0x7A52 else resetStatsLoop) := by
  let mid := beforeJr state
  have midFacts := beforeJr_exact state
  have dataFacts := jrNz_data mid
  have midPc : mid.registers.pc = 0x7A50 := by
    simp [mid, beforeJr, RoutineSummary.ldAFromHlInc, RoutineSummary.ldAtDeA,
      RoutineSummary.incDe, RoutineSummary.decB, RoutineSummary.advancePc,
      Registers.setHL, Registers.setDE, Registers.set8, pc, resetStatsLoop]
    native_decide
  have midZ : mid.registers.flags.z =
      (Alu.dec8 state.registers.b state.registers.flags).flags.z := by
    simp [mid, beforeJr, RoutineSummary.ldAFromHlInc, RoutineSummary.ldAtDeA,
      RoutineSummary.incDe, RoutineSummary.decB, RoutineSummary.advancePc,
      Registers.setHL, Registers.setDE, Registers.set8]
  have midImmediate : mid.memory.read 0x7A51 = 0xFA := by
    rw [midFacts.1, FlatMemory.read_write_other]
    · exact offset
    · exact Ne.symm safeOffset
  have memoryAtTarget : (resetStatsBlock state).memory.read state.registers.de =
      state.memory.read state.registers.hl := by
    rw [show (resetStatsBlock state).memory = mid.memory by
      simpa [resetStatsBlock, beforeJr, mid] using dataFacts.1]
    rw [midFacts.1, FlatMemory.read_write_same]
  have hl : (resetStatsBlock state).registers.hl =
      Word.ofNat (state.registers.hl.toNat + 1) := by
    rw [show (resetStatsBlock state).registers.hl = mid.registers.hl by
      simpa [resetStatsBlock, beforeJr, mid] using dataFacts.2.1]
    exact midFacts.2.1
  have de : (resetStatsBlock state).registers.de =
      Word.ofNat (state.registers.de.toNat + 1) := by
    rw [show (resetStatsBlock state).registers.de = mid.registers.de by
      simpa [resetStatsBlock, beforeJr, mid] using dataFacts.2.2.1]
    exact midFacts.2.2.1
  have b : (resetStatsBlock state).registers.b = Byte.ofNat n := by
    rw [show (resetStatsBlock state).registers.b = mid.registers.b by
      simpa [resetStatsBlock, beforeJr, mid] using dataFacts.2.2.2]
    rw [midFacts.2.2.2, count, dec_small_value n bound]
  have branchZ : (beforeJr state).registers.flags.z = decide (n = 0) := by
    calc
      (beforeJr state).registers.flags.z =
          (Alu.dec8 state.registers.b state.registers.flags).flags.z := by
        simpa [mid] using midZ
      _ = decide (n = 0) := by rw [count, dec_small_zero n bound]
  have control : (resetStatsBlock state).registers.pc =
      (if n = 0 then 0x7A52 else resetStatsLoop) := by
    rw [show resetStatsBlock state = RoutineSummary.jrNz mid by rfl]
    simp only [RoutineSummary.jrNz, midPc, Alu.conditionHolds]
    rw [branchZ]
    by_cases done : n = 0
    · subst n
      simp
      native_decide
    · simp [done]
      rw [show Word.ofNat 31313 = (0x7A51 : Word) by native_decide]
      rw [midImmediate]
      native_decide
  exact ⟨memoryAtTarget, hl, de, b, control⟩

/-- One semantic block writes exactly the byte read at `HL` to `DE`. -/
@[simp] theorem resetStatsBlock_memory (state : FunctionalState) :
    (resetStatsBlock state).memory =
      state.memory.write state.registers.de (state.memory.read state.registers.hl) := by
  let mid := beforeJr state
  have midFacts := beforeJr_exact state
  have dataFacts := jrNz_data mid
  rw [show (resetStatsBlock state).memory = mid.memory by
    simpa [resetStatsBlock, beforeJr, mid] using dataFacts.1]
  exact midFacts.1

@[simp] theorem resetStatsBlock_hl (state : FunctionalState) :
    (resetStatsBlock state).registers.hl = Word.ofNat (state.registers.hl.toNat + 1) := by
  let mid := beforeJr state
  have midFacts := beforeJr_exact state
  have dataFacts := jrNz_data mid
  rw [show (resetStatsBlock state).registers.hl = mid.registers.hl by
    simpa [resetStatsBlock, beforeJr, mid] using dataFacts.2.1]
  exact midFacts.2.1

@[simp] theorem resetStatsBlock_de (state : FunctionalState) :
    (resetStatsBlock state).registers.de = Word.ofNat (state.registers.de.toNat + 1) := by
  let mid := beforeJr state
  have midFacts := beforeJr_exact state
  have dataFacts := jrNz_data mid
  rw [show (resetStatsBlock state).registers.de = mid.registers.de by
    simpa [resetStatsBlock, beforeJr, mid] using dataFacts.2.2.1]
  exact midFacts.2.2.1

/-- Pure byte-copy fold matching the data path of repeated `ResetStats` blocks. -/
def copyBytes : Nat → FlatMemory → Word → Word → FlatMemory
  | 0, memory, _, _ => memory
  | count + 1, memory, source, destination =>
      copyBytes count (memory.write destination (memory.read source))
        (Word.ofNat (source.toNat + 1)) (Word.ofNat (destination.toNat + 1))

/-- Repeated semantic loop blocks in execution order. -/
def iterateResetStatsBlocks : Nat → FunctionalState → FunctionalState
  | 0, state => state
  | count + 1, state => iterateResetStatsBlocks count (resetStatsBlock state)

/-- The local assumptions needed at one loop head. They are explicit so whole-
routine callers must prove code-window stability and destination/code separation
rather than receiving them from fuel execution. -/
structure ResetStatsBlockContract (state : FunctionalState) : Prop where
  quiet : RoutineSummary.Quiet state
  pc : state.registers.pc = resetStatsLoop
  op2a : state.memory.read 0x7A4C = 0x2A
  op12 : state.memory.read 0x7A4D = 0x12
  op13 : state.memory.read 0x7A4E = 0x13
  op05 : state.memory.read 0x7A4F = 0x05
  op20 : state.memory.read 0x7A50 = 0x20
  safe13 : state.registers.de ≠ 0x7A4E
  safe05 : state.registers.de ≠ 0x7A4F
  safe20 : state.registers.de ≠ 0x7A50

/-- Repeated blocks have exactly the pure copy-fold memory result. -/
theorem iterateResetStatsBlocks_memory (count : Nat) (state : FunctionalState) :
    (iterateResetStatsBlocks count state).memory =
      copyBytes count state.memory state.registers.hl state.registers.de := by
  induction count generalizing state with
  | zero => rfl
  | succ count induction =>
      simp only [iterateResetStatsBlocks, copyBytes]
      rw [induction, resetStatsBlock_memory, resetStatsBlock_hl, resetStatsBlock_de]

/-- Every loop head up to `count` satisfies the local decoded block contract. -/
def ResetStatsContracts (count : Nat) (initial : FunctionalState) : Prop :=
  ∀ index, index < count → ResetStatsBlockContract (iterateResetStatsBlocks index initial)

/-- Any finite sequence of contracted blocks is exactly the corresponding
architectural execution. This is the scalable replacement for unfolding all 40
loop instructions in one evaluator term. -/
theorem resetStats_blocks_exact (count : Nat) (initial : FunctionalState)
    (contracts : ResetStatsContracts count initial) :
    (RoutineSummary.runSteps (5 * count) initial).state =
      iterateResetStatsBlocks count initial := by
  induction count generalizing initial with
  | zero => rfl
  | succ count induction =>
      have head := contracts 0 (by omega)
      have blockExact : (RoutineSummary.runSteps 5 initial).state = resetStatsBlock initial :=
        resetStats_block_exact initial head.quiet head.pc
          ⟨head.op2a, head.op12, head.op13, head.op05, head.op20⟩
          ⟨head.safe13, head.safe05, head.safe20⟩
      have tailContracts : ResetStatsContracts count (resetStatsBlock initial) := by
        intro index bounded
        simpa [iterateResetStatsBlocks] using contracts (index + 1) (by omega)
      have tail := induction (resetStatsBlock initial) tailContracts
      have composed := RoutineSummary.runSteps_add 5 (5 * count) initial
      have stateComposed := congrArg RoutineSummary.Execution.state composed
      rw [show 5 * (count + 1) = 5 + 5 * count by omega]
      rw [stateComposed]
      simp only
      rw [blockExact, tail]
      rfl

/-- Complete eight-iteration `ResetStats` loop: forty architectural
instructions produce exactly the eight-byte copy fold. The only assumptions are
the explicit per-head code/stability contracts; source bytes remain arbitrary. -/
theorem resetStats_eight_exact (initial : FunctionalState)
    (contracts : ResetStatsContracts 8 initial) :
    (RoutineSummary.runSteps 40 initial).state = iterateResetStatsBlocks 8 initial ∧
    (RoutineSummary.runSteps 40 initial).state.memory =
      copyBytes 8 initial.memory initial.registers.hl initial.registers.de := by
  set_option maxRecDepth 10000 in
    have states := resetStats_blocks_exact 8 initial contracts
    constructor
    · exact states
    · rw [states]
      exact iterateResetStatsBlocks_memory 8 initial

/-! ### Complete ResetStats helper -/

private theorem quiet_ldBImmediate (state : FunctionalState)
    (quiet : RoutineSummary.Quiet state) :
    RoutineSummary.Quiet (RoutineSummary.ldBImmediate state) := by
  rcases quiet with ⟨running, halt, scheduled⟩
  exact ⟨by simp [RoutineSummary.ldBImmediate, running],
    by simp [RoutineSummary.ldBImmediate],
    by simp [RoutineSummary.ldBImmediate, scheduled]⟩

private theorem quiet_resetStatsBlock (state : FunctionalState)
    (quiet : RoutineSummary.Quiet state) : RoutineSummary.Quiet (resetStatsBlock state) := by
  rcases quiet with ⟨running, halt, scheduled⟩
  exact ⟨by simp [resetStatsBlock, RoutineSummary.jrNz, RoutineSummary.decB,
      RoutineSummary.incDe, RoutineSummary.ldAtDeA, RoutineSummary.ldAFromHlInc,
      RoutineSummary.advancePc, running],
    by simp [resetStatsBlock, RoutineSummary.jrNz],
    by simp [resetStatsBlock, RoutineSummary.jrNz, RoutineSummary.decB,
      RoutineSummary.incDe, RoutineSummary.ldAtDeA, RoutineSummary.ldAFromHlInc,
      RoutineSummary.advancePc, scheduled]⟩

private theorem quiet_iterateResetStatsBlocks (count : Nat) (state : FunctionalState)
    (quiet : RoutineSummary.Quiet state) :
    RoutineSummary.Quiet (iterateResetStatsBlocks count state) := by
  induction count generalizing state with
  | zero => exact quiet
  | succ count induction =>
      exact induction (resetStatsBlock state) (quiet_resetStatsBlock state quiet)

structure ResetStatsRoutineContract (state : FunctionalState) : Prop where
  quiet : RoutineSummary.Quiet state
  op06 : state.memory.read state.registers.pc = 0x06
  count : state.memory.read (Word.ofNat (state.registers.pc.toNat + 1)) = 0x08
  blocks : ResetStatsContracts 8 (RoutineSummary.ldBImmediate state)
  retOpcode : (iterateResetStatsBlocks 8 (RoutineSummary.ldBImmediate state)).memory.read
    (iterateResetStatsBlocks 8 (RoutineSummary.ldBImmediate state)).registers.pc = 0xC9

/-- Complete `ResetStats`: load the exact count eight, copy eight bytes, and
return to the stack-provided caller in forty-two architectural instructions. -/
theorem resetStats_routine_exact (state : FunctionalState)
    (contract : ResetStatsRoutineContract state) :
    (RoutineSummary.runSteps 42 state).state =
      RoutineSummary.ret (iterateResetStatsBlocks 8 (RoutineSummary.ldBImmediate state)) ∧
    (RoutineSummary.runSteps 42 state).state.memory =
      copyBytes 8 state.memory (RoutineSummary.ldBImmediate state).registers.hl
        (RoutineSummary.ldBImmediate state).registers.de := by
  let loopInitial := RoutineSummary.ldBImmediate state
  let loopFinal := iterateResetStatsBlocks 8 loopInitial
  have first := RoutineSummary.step_ldBImmediate state contract.quiet.1
    contract.quiet.2.2 contract.quiet.2.1 contract.op06
  have loops := (resetStats_eight_exact loopInitial contract.blocks).1
  have qLoop := quiet_ldBImmediate state contract.quiet
  have qFinal := quiet_iterateResetStatsBlocks 8 loopInitial qLoop
  have returns := RoutineSummary.step_ret loopFinal qFinal.1 qFinal.2.2 qFinal.2.1
    contract.retOpcode
  have composeLoops := RoutineSummary.runSteps_add 1 40 state
  have composed41 : RoutineSummary.runSteps 41 state =
      (let firstRun := RoutineSummary.runSteps 1 state
       let secondRun := RoutineSummary.runSteps 40 firstRun.state
       { state := secondRun.state, trace := firstRun.trace ++ secondRun.trace }) := by
    simpa using composeLoops
  have run41 : (RoutineSummary.runSteps 41 state).state = loopFinal := by
    rw [composed41]
    simp only
    rw [show (RoutineSummary.runSteps 1 state).state = loopInitial by
      simpa [RoutineSummary.runSteps, loopInitial] using first]
    simpa [loopFinal] using loops
  have composeReturn := RoutineSummary.runSteps_add 41 1 state
  have composed42 : RoutineSummary.runSteps 42 state =
      (let firstRun := RoutineSummary.runSteps 41 state
       let secondRun := RoutineSummary.runSteps 1 firstRun.state
       { state := secondRun.state, trace := firstRun.trace ++ secondRun.trace }) := by
    simpa using composeReturn
  have finalState : (RoutineSummary.runSteps 42 state).state = RoutineSummary.ret loopFinal := by
    rw [composed42]
    simp only
    rw [run41]
    simpa [RoutineSummary.runSteps] using returns
  constructor
  · simpa [loopFinal, loopInitial] using finalState
  · rw [finalState]
    change loopFinal.memory = _
    simpa [loopFinal, loopInitial] using iterateResetStatsBlocks_memory 8 loopInitial

/-! ## CureVolatileStatuses -/

/-- Successive symbolic states of the eight-instruction call-free body. -/
def cureS1 (state : FunctionalState) := RoutineSummary.res7AtHl state
def cureS2 (state : FunctionalState) := RoutineSummary.incHl (cureS1 state)
def cureS3 (state : FunctionalState) := RoutineSummary.ldAAtHl (cureS2 state)
def cureS4 (state : FunctionalState) := RoutineSummary.andImmediate (cureS3 state)
def cureS5 (state : FunctionalState) := RoutineSummary.ldAtHlIncA (cureS4 state)
def cureS6 (state : FunctionalState) := RoutineSummary.ldAAtHl (cureS5 state)
def cureS7 (state : FunctionalState) := RoutineSummary.andImmediate (cureS6 state)
def cureVolatileBlock (state : FunctionalState) := RoutineSummary.ldAtHlA (cureS7 state)

/-- Dynamic decode/stability contract at every instruction boundary. Keeping the
observations on transformed states makes overlapping code writes impossible by
construction without hiding them behind a global non-aliasing assumption. -/
structure CureVolatileContract (state : FunctionalState) : Prop where
  quiet : RoutineSummary.Quiet state
  prefixByte : state.memory.read state.registers.pc = 0xCB
  subopcode : state.memory.read (Word.ofNat (state.registers.pc.toNat + 1)) = 0xBE
  op23 : (cureS1 state).memory.read (cureS1 state).registers.pc = 0x23
  op7eFirst : (cureS2 state).memory.read (cureS2 state).registers.pc = 0x7E
  opE6First : (cureS3 state).memory.read (cureS3 state).registers.pc = 0xE6
  firstMask : (cureS3 state).memory.read
    (Word.ofNat ((cureS3 state).registers.pc.toNat + 1)) = 0x78
  op22 : (cureS4 state).memory.read (cureS4 state).registers.pc = 0x22
  op7eSecond : (cureS5 state).memory.read (cureS5 state).registers.pc = 0x7E
  opE6Second : (cureS6 state).memory.read (cureS6 state).registers.pc = 0xE6
  secondMask : (cureS6 state).memory.read
    (Word.ofNat ((cureS6 state).registers.pc.toNat + 1)) = 0xF8
  op77 : (cureS7 state).memory.read (cureS7 state).registers.pc = 0x77

private theorem cureQuiet1 (state : FunctionalState) (quiet : RoutineSummary.Quiet state) :
    RoutineSummary.Quiet (cureS1 state) := by
  rcases quiet with ⟨running, halt, scheduled⟩
  exact ⟨by simp [cureS1, RoutineSummary.res7AtHl, running],
    by simp [cureS1, RoutineSummary.res7AtHl],
    by simp [cureS1, RoutineSummary.res7AtHl, scheduled]⟩

private theorem cureQuiet2 (state : FunctionalState) (quiet : RoutineSummary.Quiet (cureS1 state)) :
    RoutineSummary.Quiet (cureS2 state) := by
  rcases quiet with ⟨running, halt, scheduled⟩
  exact ⟨by simp [cureS2, RoutineSummary.incHl, running],
    by simp [cureS2, RoutineSummary.incHl],
    by simp [cureS2, RoutineSummary.incHl, scheduled]⟩

private theorem cureQuiet3 (state : FunctionalState) (quiet : RoutineSummary.Quiet (cureS2 state)) :
    RoutineSummary.Quiet (cureS3 state) := by
  rcases quiet with ⟨running, halt, scheduled⟩
  exact ⟨by simp [cureS3, RoutineSummary.ldAAtHl, running],
    by simp [cureS3, RoutineSummary.ldAAtHl],
    by simp [cureS3, RoutineSummary.ldAAtHl, scheduled]⟩

private theorem cureQuiet4 (state : FunctionalState) (quiet : RoutineSummary.Quiet (cureS3 state)) :
    RoutineSummary.Quiet (cureS4 state) := by
  rcases quiet with ⟨running, halt, scheduled⟩
  exact ⟨by simp [cureS4, RoutineSummary.andImmediate, running],
    by simp [cureS4, RoutineSummary.andImmediate],
    by simp [cureS4, RoutineSummary.andImmediate, scheduled]⟩

private theorem cureQuiet5 (state : FunctionalState) (quiet : RoutineSummary.Quiet (cureS4 state)) :
    RoutineSummary.Quiet (cureS5 state) := by
  rcases quiet with ⟨running, halt, scheduled⟩
  exact ⟨by simp [cureS5, RoutineSummary.ldAtHlIncA, running],
    by simp [cureS5, RoutineSummary.ldAtHlIncA],
    by simp [cureS5, RoutineSummary.ldAtHlIncA, scheduled]⟩

private theorem cureQuiet6 (state : FunctionalState) (quiet : RoutineSummary.Quiet (cureS5 state)) :
    RoutineSummary.Quiet (cureS6 state) := by
  rcases quiet with ⟨running, halt, scheduled⟩
  exact ⟨by simp [cureS6, RoutineSummary.ldAAtHl, running],
    by simp [cureS6, RoutineSummary.ldAAtHl],
    by simp [cureS6, RoutineSummary.ldAAtHl, scheduled]⟩

private theorem cureQuiet7 (state : FunctionalState) (quiet : RoutineSummary.Quiet (cureS6 state)) :
    RoutineSummary.Quiet (cureS7 state) := by
  rcases quiet with ⟨running, halt, scheduled⟩
  exact ⟨by simp [cureS7, RoutineSummary.andImmediate, running],
    by simp [cureS7, RoutineSummary.andImmediate],
    by simp [cureS7, RoutineSummary.andImmediate, scheduled]⟩

/-- Exact decoded execution of `CureVolatileStatuses`, stopping before `RET`. -/
theorem cureVolatile_block_exact (state : FunctionalState)
    (contract : CureVolatileContract state) :
    (RoutineSummary.runSteps 8 state).state = cureVolatileBlock state := by
  have q1 := cureQuiet1 state contract.quiet
  have q2 := cureQuiet2 state q1
  have q3 := cureQuiet3 state q2
  have q4 := cureQuiet4 state q3
  have q5 := cureQuiet5 state q4
  have q6 := cureQuiet6 state q5
  have q7 := cureQuiet7 state q6
  have one := RoutineSummary.step_res7AtHl state contract.quiet.1
    contract.quiet.2.2 contract.quiet.2.1 contract.prefixByte contract.subopcode
  have two := RoutineSummary.step_incHl (cureS1 state) q1.1 q1.2.2 q1.2.1 contract.op23
  have three := RoutineSummary.step_ldAAtHl (cureS2 state) q2.1 q2.2.2 q2.2.1
    contract.op7eFirst
  have four := RoutineSummary.step_andImmediate (cureS3 state) q3.1 q3.2.2 q3.2.1
    contract.opE6First
  have five := RoutineSummary.step_ldAtHlIncA (cureS4 state) q4.1 q4.2.2 q4.2.1
    contract.op22
  have six := RoutineSummary.step_ldAAtHl (cureS5 state) q5.1 q5.2.2 q5.2.1
    contract.op7eSecond
  have seven := RoutineSummary.step_andImmediate (cureS6 state) q6.1 q6.2.2 q6.2.1
    contract.opE6Second
  have eight := RoutineSummary.step_ldAtHlA (cureS7 state) q7.1 q7.2.2 q7.2.1
    contract.op77
  have one' : (Functional.step state).state = cureS1 state := by
    simpa [cureS1] using one
  have two' : (Functional.step (cureS1 state)).state = cureS2 state := by
    simpa [cureS2] using two
  have three' : (Functional.step (cureS2 state)).state = cureS3 state := by
    simpa [cureS3] using three
  have four' : (Functional.step (cureS3 state)).state = cureS4 state := by
    simpa [cureS4] using four
  have five' : (Functional.step (cureS4 state)).state = cureS5 state := by
    simpa [cureS5] using five
  have six' : (Functional.step (cureS5 state)).state = cureS6 state := by
    simpa [cureS6] using six
  have seven' : (Functional.step (cureS6 state)).state = cureS7 state := by
    simpa [cureS7] using seven
  have eight' : (Functional.step (cureS7 state)).state = cureVolatileBlock state := by
    simpa [cureVolatileBlock] using eight
  simp only [RoutineSummary.runSteps]
  rw [one', two', three', four', five', six', seven', eight']

private theorem cureQuiet8 (state : FunctionalState)
    (quiet : RoutineSummary.Quiet (cureS7 state)) :
    RoutineSummary.Quiet (cureVolatileBlock state) := by
  rcases quiet with ⟨running, halt, scheduled⟩
  exact ⟨by simp [cureVolatileBlock, RoutineSummary.ldAtHlA, running],
    by simp [cureVolatileBlock, RoutineSummary.ldAtHlA],
    by simp [cureVolatileBlock, RoutineSummary.ldAtHlA, scheduled]⟩

structure CureVolatileRoutineContract (state : FunctionalState) extends
    CureVolatileContract state where
  retOpcode : (cureVolatileBlock state).memory.read
    (cureVolatileBlock state).registers.pc = 0xC9

/-- Complete `CureVolatileStatuses`, including the stack return. -/
theorem cureVolatile_routine_exact (state : FunctionalState)
    (contract : CureVolatileRoutineContract state) :
    (RoutineSummary.runSteps 9 state).state =
      RoutineSummary.ret (cureVolatileBlock state) := by
  have body := cureVolatile_block_exact state contract.toCureVolatileContract
  have q1 := cureQuiet1 state contract.quiet
  have q2 := cureQuiet2 state q1
  have q3 := cureQuiet3 state q2
  have q4 := cureQuiet4 state q3
  have q5 := cureQuiet5 state q4
  have q6 := cureQuiet6 state q5
  have q7 := cureQuiet7 state q6
  have q8 := cureQuiet8 state q7
  have returns := RoutineSummary.step_ret (cureVolatileBlock state)
    q8.1 q8.2.2 q8.2.1 contract.retOpcode
  have composed := RoutineSummary.runSteps_add 8 1 state
  have composed9 : RoutineSummary.runSteps 9 state =
      (let firstRun := RoutineSummary.runSteps 8 state
       let secondRun := RoutineSummary.runSteps 1 firstRun.state
       { state := secondRun.state, trace := firstRun.trace ++ secondRun.trace }) := by
    simpa using composed
  rw [composed9]
  simp only
  rw [body]
  simpa [RoutineSummary.runSteps] using returns

/-- Semantic effect of the decoded volatile-status body. It clears confusion
bit 7 in the first byte, retains only bits 3--6 in the second, and retains only
bits 3--7 in the third. All three source bytes remain symbolic. -/
theorem cureVolatile_block_effect (state : FunctionalState)
    (contract : CureVolatileContract state) :
    let first := state.registers.hl
    let second := Word.ofNat (first.toNat + 1)
    let third := Word.ofNat (first.toNat + 2)
    let out := cureVolatileBlock state
    out.memory.read first = Alu.resetBit ⟨7, by omega⟩ (state.memory.read first) ∧
    out.memory.read second = (Alu.and8 (state.memory.read second) 0x78).value ∧
    out.memory.read third = (Alu.and8 (state.memory.read third) 0xF8).value ∧
    out.registers.hl = third := by
  have firstMask := contract.firstMask
  have secondMask := contract.secondMask
  simp only [cureS1, cureS2, cureS3, cureS4, cureS5, cureS6, cureS7,
    cureVolatileBlock, RoutineSummary.res7AtHl, RoutineSummary.incHl,
    RoutineSummary.ldAAtHl, RoutineSummary.andImmediate,
    RoutineSummary.ldAtHlIncA, RoutineSummary.ldAtHlA,
    RoutineSummary.advancePc, Registers.setHL, Registers.hl,
    RoutineSummary.increment_twice, RoutineSummary.increment_after_two,
    RoutineSummary.increment_after_three, RoutineSummary.increment_after_four,
    RoutineSummary.increment_after_five, RoutineSummary.increment_after_six,
    RoutineSummary.increment_after_seven, RoutineSummary.ofBytes_high_low] at firstMask secondMask ⊢
  have firstNext : Word.ofBytes state.registers.h state.registers.l ≠
      Word.ofNat ((Word.ofBytes state.registers.h state.registers.l).toNat + 1) := by
    simpa only [Registers.hl] using RoutineSummary.address_ne_next state.registers.hl
  have firstThird : Word.ofBytes state.registers.h state.registers.l ≠
      Word.ofNat ((Word.ofBytes state.registers.h state.registers.l).toNat + 2) := by
    simpa only [Registers.hl] using RoutineSummary.address_ne_next_two state.registers.hl
  have secondThird : Word.ofNat ((Word.ofBytes state.registers.h state.registers.l).toNat + 1) ≠
      Word.ofNat ((Word.ofBytes state.registers.h state.registers.l).toNat + 2) := by
    simpa only [Registers.hl] using RoutineSummary.next_ne_next_two state.registers.hl
  constructor
  · rw [firstMask]
    rw [FlatMemory.read_write_other _ _ _ _
      firstThird]
    rw [FlatMemory.read_write_other _ _ _ _
      firstNext]
    exact FlatMemory.read_write_same _ _ _
  · constructor
    · rw [firstMask]
      rw [FlatMemory.read_write_other _ _ _ _ secondThird]
      rw [FlatMemory.read_write_same]
      rw [FlatMemory.read_write_other _ _ _ _ (Ne.symm firstNext)]
    · rw [secondMask]
      rw [FlatMemory.read_write_same]
      rw [FlatMemory.read_write_other _ _ _ _ (Ne.symm secondThird)]
      rw [FlatMemory.read_write_other _ _ _ _ (Ne.symm firstThird)]
      exact ⟨rfl, trivial⟩

/-! ## ResetStatMods -/

private def resetModsLoop : Word := 0x7A45

/-- One three-instruction stat-modifier fill iteration. -/
def resetModsBlock (state : FunctionalState) : FunctionalState :=
  RoutineSummary.jrNz (RoutineSummary.decB (RoutineSummary.ldAtHlIncA state))

structure ResetModsBlockContract (state : FunctionalState) : Prop where
  quiet : RoutineSummary.Quiet state
  pc : state.registers.pc = resetModsLoop
  op22 : state.memory.read 0x7A45 = 0x22
  op05 : state.memory.read 0x7A46 = 0x05
  op20 : state.memory.read 0x7A47 = 0x20
  safe05 : state.registers.hl ≠ 0x7A46
  safe20 : state.registers.hl ≠ 0x7A47

/-- One `ResetStatMods` loop iteration follows the three decoded opcodes. -/
theorem resetMods_block_exact (state : FunctionalState)
    (contract : ResetModsBlockContract state) :
    (RoutineSummary.runSteps 3 state).state = resetModsBlock state := by
  have first := RoutineSummary.step_ldAtHlIncA state contract.quiet.1
    contract.quiet.2.2 contract.quiet.2.1 (by simpa [contract.pc, resetModsLoop] using contract.op22)
  let s1 := RoutineSummary.ldAtHlIncA state
  have running1 : s1.mode = .running := by
    simp [s1, RoutineSummary.ldAtHlIncA, contract.quiet.1]
  have scheduled1 : s1.scheduledImeEnable = false := by
    simp [s1, RoutineSummary.ldAtHlIncA, contract.quiet.2.2]
  have halt1 : s1.haltBug = false := by simp [s1, RoutineSummary.ldAtHlIncA]
  have pc1 : s1.registers.pc = 0x7A46 := by
    simp [s1, RoutineSummary.ldAtHlIncA, RoutineSummary.advancePc, Registers.setHL,
      contract.pc, resetModsLoop]
    native_decide
  have op05' : s1.memory.read s1.registers.pc = 0x05 := by
    rw [pc1]
    change (state.memory.write state.registers.hl state.registers.a).read 0x7A46 = 0x05
    rw [FlatMemory.read_write_other]
    · exact contract.op05
    · exact Ne.symm contract.safe05
  have second := RoutineSummary.step_decB s1 running1 scheduled1 halt1 op05'
  let s2 := RoutineSummary.decB s1
  have running2 : s2.mode = .running := by simp [s2, RoutineSummary.decB, running1]
  have scheduled2 : s2.scheduledImeEnable = false := by
    simp [s2, RoutineSummary.decB, scheduled1]
  have halt2 : s2.haltBug = false := by simp [s2, RoutineSummary.decB]
  have pc2 : s2.registers.pc = 0x7A47 := by
    simp [s2, RoutineSummary.decB, RoutineSummary.advancePc, Registers.set8, pc1]
    native_decide
  have op20' : s2.memory.read s2.registers.pc = 0x20 := by
    rw [pc2]
    change (state.memory.write state.registers.hl state.registers.a).read 0x7A47 = 0x20
    rw [FlatMemory.read_write_other]
    · exact contract.op20
    · exact Ne.symm contract.safe20
  have third := RoutineSummary.step_jrNz s2 running2 scheduled2 halt2 op20'
  simp only [RoutineSummary.runSteps]
  rw [first, second, third]
  rfl

@[simp] theorem resetModsBlock_memory (state : FunctionalState) :
    (resetModsBlock state).memory =
      state.memory.write state.registers.hl state.registers.a := by
  let mid := RoutineSummary.decB (RoutineSummary.ldAtHlIncA state)
  have data := jrNz_data mid
  rw [show (resetModsBlock state).memory = mid.memory by
    simpa [resetModsBlock, mid] using data.1]
  simp [mid, RoutineSummary.decB, RoutineSummary.ldAtHlIncA]

@[simp] theorem resetModsBlock_hl (state : FunctionalState) :
    (resetModsBlock state).registers.hl = Word.ofNat (state.registers.hl.toNat + 1) := by
  let mid := RoutineSummary.decB (RoutineSummary.ldAtHlIncA state)
  have data := jrNz_data mid
  rw [show (resetModsBlock state).registers.hl = mid.registers.hl by
    simpa [resetModsBlock, mid] using data.2.1]
  simp [mid, RoutineSummary.decB, RoutineSummary.ldAtHlIncA,
    RoutineSummary.advancePc, Registers.setHL, Registers.set8, Registers.hl]

@[simp] theorem resetModsBlock_a (state : FunctionalState) :
    (resetModsBlock state).registers.a = state.registers.a := by
  simp only [resetModsBlock, RoutineSummary.jrNz]
  split <;> simp [RoutineSummary.decB, RoutineSummary.ldAtHlIncA,
    RoutineSummary.advancePc, Registers.set8, Registers.setHL]

/-- Pure repeated-byte fill matching `ResetStatMods`. -/
def fillBytes : Nat → FlatMemory → Word → Byte → FlatMemory
  | 0, memory, _, _ => memory
  | count + 1, memory, destination, value =>
      fillBytes count (memory.write destination value)
        (Word.ofNat (destination.toNat + 1)) value

def iterateResetModsBlocks : Nat → FunctionalState → FunctionalState
  | 0, state => state
  | count + 1, state => iterateResetModsBlocks count (resetModsBlock state)

theorem iterateResetModsBlocks_memory (count : Nat) (state : FunctionalState) :
    (iterateResetModsBlocks count state).memory =
      fillBytes count state.memory state.registers.hl state.registers.a := by
  induction count generalizing state with
  | zero => rfl
  | succ count induction =>
      simp only [iterateResetModsBlocks, fillBytes]
      rw [induction, resetModsBlock_memory, resetModsBlock_hl, resetModsBlock_a]

def ResetModsContracts (count : Nat) (initial : FunctionalState) : Prop :=
  ∀ index, index < count → ResetModsBlockContract (iterateResetModsBlocks index initial)

/-- Complete eight-iteration stage reset: twenty-four instructions fill all
modifier bytes with the caller's `A` value. -/
theorem resetMods_eight_exact (initial : FunctionalState)
    (contracts : ResetModsContracts 8 initial) :
    (RoutineSummary.runSteps 24 initial).state = iterateResetModsBlocks 8 initial ∧
    (RoutineSummary.runSteps 24 initial).state.memory =
      fillBytes 8 initial.memory initial.registers.hl initial.registers.a := by
  have blocks : ∀ count initial, ResetModsContracts count initial →
      (RoutineSummary.runSteps (3 * count) initial).state =
        iterateResetModsBlocks count initial := by
    intro count
    induction count with
    | zero => intro initial _; rfl
    | succ count induction =>
        intro initial allContracts
        have head := allContracts 0 (by omega)
        have first := resetMods_block_exact initial head
        have tailContracts : ResetModsContracts count (resetModsBlock initial) := by
          intro index bounded
          simpa [iterateResetModsBlocks] using allContracts (index + 1) (by omega)
        have tail := induction (resetModsBlock initial) tailContracts
        have composed := RoutineSummary.runSteps_add 3 (3 * count) initial
        have stateComposed := congrArg RoutineSummary.Execution.state composed
        rw [show 3 * (count + 1) = 3 + 3 * count by omega]
        rw [stateComposed]
        simp only
        rw [first, tail]
        rfl
  have states := blocks 8 initial contracts
  constructor
  · rw [show 24 = 3 * 8 by omega]
    exact states
  · rw [show 24 = 3 * 8 by omega, states]
    exact iterateResetModsBlocks_memory 8 initial

/-! ### Complete ResetStatMods helper -/

private theorem quiet_resetModsBlock (state : FunctionalState)
    (quiet : RoutineSummary.Quiet state) : RoutineSummary.Quiet (resetModsBlock state) := by
  rcases quiet with ⟨running, halt, scheduled⟩
  exact ⟨by simp [resetModsBlock, RoutineSummary.jrNz, RoutineSummary.decB,
      RoutineSummary.ldAtHlIncA, RoutineSummary.advancePc, running],
    by simp [resetModsBlock, RoutineSummary.jrNz],
    by simp [resetModsBlock, RoutineSummary.jrNz, RoutineSummary.decB,
      RoutineSummary.ldAtHlIncA, RoutineSummary.advancePc, scheduled]⟩

private theorem quiet_iterateResetModsBlocks (count : Nat) (state : FunctionalState)
    (quiet : RoutineSummary.Quiet state) :
    RoutineSummary.Quiet (iterateResetModsBlocks count state) := by
  induction count generalizing state with
  | zero => exact quiet
  | succ count induction =>
      exact induction (resetModsBlock state) (quiet_resetModsBlock state quiet)

structure ResetModsRoutineContract (state : FunctionalState) : Prop where
  quiet : RoutineSummary.Quiet state
  op06 : state.memory.read state.registers.pc = 0x06
  count : state.memory.read (Word.ofNat (state.registers.pc.toNat + 1)) = 0x08
  blocks : ResetModsContracts 8 (RoutineSummary.ldBImmediate state)
  retOpcode : (iterateResetModsBlocks 8 (RoutineSummary.ldBImmediate state)).memory.read
    (iterateResetModsBlocks 8 (RoutineSummary.ldBImmediate state)).registers.pc = 0xC9

/-- Complete `ResetStatMods`, including count load and return. -/
theorem resetMods_routine_exact (state : FunctionalState)
    (contract : ResetModsRoutineContract state) :
    (RoutineSummary.runSteps 26 state).state =
      RoutineSummary.ret (iterateResetModsBlocks 8 (RoutineSummary.ldBImmediate state)) ∧
    (RoutineSummary.runSteps 26 state).state.memory =
      fillBytes 8 state.memory state.registers.hl state.registers.a := by
  let loopInitial := RoutineSummary.ldBImmediate state
  let loopFinal := iterateResetModsBlocks 8 loopInitial
  have first := RoutineSummary.step_ldBImmediate state contract.quiet.1
    contract.quiet.2.2 contract.quiet.2.1 contract.op06
  have loops := (resetMods_eight_exact loopInitial contract.blocks).1
  have qLoop := quiet_ldBImmediate state contract.quiet
  have qFinal := quiet_iterateResetModsBlocks 8 loopInitial qLoop
  have returns := RoutineSummary.step_ret loopFinal qFinal.1 qFinal.2.2 qFinal.2.1
    contract.retOpcode
  have composeLoops := RoutineSummary.runSteps_add 1 24 state
  have composed25 : RoutineSummary.runSteps 25 state =
      (let firstRun := RoutineSummary.runSteps 1 state
       let secondRun := RoutineSummary.runSteps 24 firstRun.state
       { state := secondRun.state, trace := firstRun.trace ++ secondRun.trace }) := by
    simpa using composeLoops
  have run25 : (RoutineSummary.runSteps 25 state).state = loopFinal := by
    rw [composed25]
    simp only
    rw [show (RoutineSummary.runSteps 1 state).state = loopInitial by
      simpa [RoutineSummary.runSteps, loopInitial] using first]
    simpa [loopFinal] using loops
  have composeReturn := RoutineSummary.runSteps_add 25 1 state
  have composed26 : RoutineSummary.runSteps 26 state =
      (let firstRun := RoutineSummary.runSteps 25 state
       let secondRun := RoutineSummary.runSteps 1 firstRun.state
       { state := secondRun.state, trace := firstRun.trace ++ secondRun.trace }) := by
    simpa using composeReturn
  have finalState : (RoutineSummary.runSteps 26 state).state = RoutineSummary.ret loopFinal := by
    rw [composed26]
    simp only
    rw [run25]
    simpa [RoutineSummary.runSteps] using returns
  constructor
  · simpa [loopFinal, loopInitial] using finalState
  · rw [finalState]
    change loopFinal.memory = _
    simpa [loopFinal, loopInitial, RoutineSummary.ldBImmediate] using
      iterateResetModsBlocks_memory 8 loopInitial

/-! ## Haze reset prefix through four helper returns -/

def hazeP1 (s : FunctionalState) := RoutineSummary.ldAImmediate s
def hazeP2 (s : FunctionalState) := RoutineSummary.ldHlImmediate (hazeP1 s)
def hazeP3 (s : FunctionalState) := RoutineSummary.callAbsolute (hazeP2 s)
def hazeP4 (s : FunctionalState) :=
  RoutineSummary.ret (iterateResetModsBlocks 8 (RoutineSummary.ldBImmediate (hazeP3 s)))
def hazeP5 (s : FunctionalState) := RoutineSummary.ldHlImmediate (hazeP4 s)
def hazeP6 (s : FunctionalState) := RoutineSummary.callAbsolute (hazeP5 s)
def hazeP7 (s : FunctionalState) :=
  RoutineSummary.ret (iterateResetModsBlocks 8 (RoutineSummary.ldBImmediate (hazeP6 s)))
def hazeP8 (s : FunctionalState) := RoutineSummary.ldHlImmediate (hazeP7 s)
def hazeP9 (s : FunctionalState) := RoutineSummary.ldDeImmediate (hazeP8 s)
def hazeP10 (s : FunctionalState) := RoutineSummary.callAbsolute (hazeP9 s)
def hazeP11 (s : FunctionalState) :=
  RoutineSummary.ret (iterateResetStatsBlocks 8 (RoutineSummary.ldBImmediate (hazeP10 s)))
def hazeP12 (s : FunctionalState) := RoutineSummary.ldHlImmediate (hazeP11 s)
def hazeP13 (s : FunctionalState) := RoutineSummary.ldDeImmediate (hazeP12 s)
def hazeP14 (s : FunctionalState) := RoutineSummary.callAbsolute (hazeP13 s)
def hazeResetPrefix (s : FunctionalState) :=
  RoutineSummary.ret (iterateResetStatsBlocks 8 (RoutineSummary.ldBImmediate (hazeP14 s)))

structure HazeResetPrefixContract (state : FunctionalState) : Prop where
  q0 : RoutineSummary.Quiet state
  op3e : state.memory.read state.registers.pc = 0x3E
  q1 : RoutineSummary.Quiet (hazeP1 state)
  op21a : (hazeP1 state).memory.read (hazeP1 state).registers.pc = 0x21
  q2 : RoutineSummary.Quiet (hazeP2 state)
  call1 : (hazeP2 state).memory.read (hazeP2 state).registers.pc = 0xCD
  mods1 : ResetModsRoutineContract (hazeP3 state)
  q4 : RoutineSummary.Quiet (hazeP4 state)
  op21b : (hazeP4 state).memory.read (hazeP4 state).registers.pc = 0x21
  q5 : RoutineSummary.Quiet (hazeP5 state)
  call2 : (hazeP5 state).memory.read (hazeP5 state).registers.pc = 0xCD
  mods2 : ResetModsRoutineContract (hazeP6 state)
  q7 : RoutineSummary.Quiet (hazeP7 state)
  op21c : (hazeP7 state).memory.read (hazeP7 state).registers.pc = 0x21
  q8 : RoutineSummary.Quiet (hazeP8 state)
  op11a : (hazeP8 state).memory.read (hazeP8 state).registers.pc = 0x11
  q9 : RoutineSummary.Quiet (hazeP9 state)
  call3 : (hazeP9 state).memory.read (hazeP9 state).registers.pc = 0xCD
  stats1 : ResetStatsRoutineContract (hazeP10 state)
  q11 : RoutineSummary.Quiet (hazeP11 state)
  op21d : (hazeP11 state).memory.read (hazeP11 state).registers.pc = 0x21
  q12 : RoutineSummary.Quiet (hazeP12 state)
  op11b : (hazeP12 state).memory.read (hazeP12 state).registers.pc = 0x11
  q13 : RoutineSummary.Quiet (hazeP13 state)
  call4 : (hazeP13 state).memory.read (hazeP13 state).registers.pc = 0xCD
  stats2 : ResetStatsRoutineContract (hazeP14 state)

private theorem oneStep {state out : FunctionalState}
    (step : (Functional.step state).state = out) :
    (RoutineSummary.runSteps 1 state).state = out := by
  simpa [RoutineSummary.runSteps] using step

/-- The complete common Haze reset prefix: 147 decoded instructions include
both modifier fills, both stat copies, all four calls, and all four returns. -/
theorem haze_reset_prefix_exact (state : FunctionalState)
    (contract : HazeResetPrefixContract state) :
    (RoutineSummary.runSteps 147 state).state = hazeResetPrefix state := by
  have s01 := oneStep (RoutineSummary.step_ldAImmediate state contract.q0.1
    contract.q0.2.2 contract.q0.2.1 contract.op3e)
  have s12 := oneStep (RoutineSummary.step_ldHlImmediate (hazeP1 state) contract.q1.1
    contract.q1.2.2 contract.q1.2.1 contract.op21a)
  have firstTwo := RoutineSummary.runSteps_state_add 1 1 state (hazeP1 state)
    (hazeP2 state) s01 s12
  have call1Step := RoutineSummary.step_callAbsolute (hazeP2 state) contract.q2.1
    contract.q2.2.2 contract.q2.2.1 contract.call1
  have call1Head := RoutineSummary.runSteps_after_first 26 (hazeP2 state)
    (hazeP3 state) call1Step
  have mods1 := (resetMods_routine_exact (hazeP3 state) contract.mods1).1
  have call1Body : (RoutineSummary.runSteps 27 (hazeP2 state)).state = hazeP4 state := by
    rw [call1Head]
    simpa [hazeP4] using mods1
  have part1 := RoutineSummary.runSteps_state_add 2 27 state (hazeP2 state)
    (hazeP4 state) firstTwo call1Body

  have s45 := oneStep (RoutineSummary.step_ldHlImmediate (hazeP4 state) contract.q4.1
    contract.q4.2.2 contract.q4.2.1 contract.op21b)
  have call2Step := RoutineSummary.step_callAbsolute (hazeP5 state) contract.q5.1
    contract.q5.2.2 contract.q5.2.1 contract.call2
  have call2Head := RoutineSummary.runSteps_after_first 26 (hazeP5 state)
    (hazeP6 state) call2Step
  have mods2 := (resetMods_routine_exact (hazeP6 state) contract.mods2).1
  have call2Body : (RoutineSummary.runSteps 27 (hazeP5 state)).state = hazeP7 state := by
    rw [call2Head]
    simpa [hazeP7] using mods2
  have part2 := RoutineSummary.runSteps_state_add 1 27 (hazeP4 state) (hazeP5 state)
    (hazeP7 state) s45 call2Body

  have s78 := oneStep (RoutineSummary.step_ldHlImmediate (hazeP7 state) contract.q7.1
    contract.q7.2.2 contract.q7.2.1 contract.op21c)
  have s89 := oneStep (RoutineSummary.step_ldDeImmediate (hazeP8 state) contract.q8.1
    contract.q8.2.2 contract.q8.2.1 contract.op11a)
  have setup3 := RoutineSummary.runSteps_state_add 1 1 (hazeP7 state) (hazeP8 state)
    (hazeP9 state) s78 s89
  have call3Step := RoutineSummary.step_callAbsolute (hazeP9 state) contract.q9.1
    contract.q9.2.2 contract.q9.2.1 contract.call3
  have call3Head := RoutineSummary.runSteps_after_first 42 (hazeP9 state)
    (hazeP10 state) call3Step
  have stats1 := (resetStats_routine_exact (hazeP10 state) contract.stats1).1
  have call3Body : (RoutineSummary.runSteps 43 (hazeP9 state)).state = hazeP11 state := by
    rw [call3Head]
    simpa [hazeP11] using stats1
  have part3 := RoutineSummary.runSteps_state_add 2 43 (hazeP7 state) (hazeP9 state)
    (hazeP11 state) setup3 call3Body

  have s1112 := oneStep (RoutineSummary.step_ldHlImmediate (hazeP11 state) contract.q11.1
    contract.q11.2.2 contract.q11.2.1 contract.op21d)
  have s1213 := oneStep (RoutineSummary.step_ldDeImmediate (hazeP12 state) contract.q12.1
    contract.q12.2.2 contract.q12.2.1 contract.op11b)
  have setup4 := RoutineSummary.runSteps_state_add 1 1 (hazeP11 state) (hazeP12 state)
    (hazeP13 state) s1112 s1213
  have call4Step := RoutineSummary.step_callAbsolute (hazeP13 state) contract.q13.1
    contract.q13.2.2 contract.q13.2.1 contract.call4
  have call4Head := RoutineSummary.runSteps_after_first 42 (hazeP13 state)
    (hazeP14 state) call4Step
  have stats2 := (resetStats_routine_exact (hazeP14 state) contract.stats2).1
  have call4Body : (RoutineSummary.runSteps 43 (hazeP13 state)).state =
      hazeResetPrefix state := by
    rw [call4Head]
    simpa [hazeResetPrefix] using stats2
  have part4 := RoutineSummary.runSteps_state_add 2 43 (hazeP11 state) (hazeP13 state)
    (hazeResetPrefix state) setup4 call4Body

  have firstHalf := RoutineSummary.runSteps_state_add 29 28 state (hazeP4 state)
    (hazeP7 state) (by simpa using part1) (by simpa using part2)
  have third := RoutineSummary.runSteps_state_add 57 45 state (hazeP7 state)
    (hazeP11 state) (by simpa using firstHalf) (by simpa using part3)
  have fourth := RoutineSummary.runSteps_state_add 102 45 state (hazeP11 state)
    (hazeResetPrefix state) (by simpa using third) (by simpa using part4)
  simpa using fourth

/-! ## Turn-dependent target selection -/

def hazeT1 (s : FunctionalState) := RoutineSummary.ldHlImmediate s
def hazeT2 (s : FunctionalState) := RoutineSummary.ldDeImmediate (hazeT1 s)
def hazeT3 (s : FunctionalState) := RoutineSummary.ldhAImmediate (hazeT2 s)
def hazeT4 (s : FunctionalState) := RoutineSummary.andA (hazeT3 s)
def hazeT5 (s : FunctionalState) := RoutineSummary.jrZ (hazeT4 s)
def hazeT6 (s : FunctionalState) := RoutineSummary.ldHlImmediate (hazeT5 s)
def hazePlayerTarget (s : FunctionalState) := RoutineSummary.decDe (hazeT6 s)

structure HazeTargetCommonContract (state : FunctionalState) : Prop where
  q0 : RoutineSummary.Quiet state
  op21 : state.memory.read state.registers.pc = 0x21
  q1 : RoutineSummary.Quiet (hazeT1 state)
  op11 : (hazeT1 state).memory.read (hazeT1 state).registers.pc = 0x11
  q2 : RoutineSummary.Quiet (hazeT2 state)
  opF0 : (hazeT2 state).memory.read (hazeT2 state).registers.pc = 0xF0
  turnOffset : (hazeT2 state).memory.read
    (Word.ofNat ((hazeT2 state).registers.pc.toNat + 1)) = 0xF3
  q3 : RoutineSummary.Quiet (hazeT3 state)
  opA7 : (hazeT3 state).memory.read (hazeT3 state).registers.pc = 0xA7
  q4 : RoutineSummary.Quiet (hazeT4 state)
  op28 : (hazeT4 state).memory.read (hazeT4 state).registers.pc = 0x28
  jumpOffset : (hazeT4 state).memory.read
    (Word.ofNat ((hazeT4 state).registers.pc.toNat + 1)) = 0x04

private theorem haze_target_common_exact (state : FunctionalState)
    (contract : HazeTargetCommonContract state) :
    (RoutineSummary.runSteps 5 state).state = hazeT5 state := by
  have a := oneStep (RoutineSummary.step_ldHlImmediate state contract.q0.1
    contract.q0.2.2 contract.q0.2.1 contract.op21)
  have b := oneStep (RoutineSummary.step_ldDeImmediate (hazeT1 state) contract.q1.1
    contract.q1.2.2 contract.q1.2.1 contract.op11)
  have c := oneStep (RoutineSummary.step_ldhAImmediate (hazeT2 state) contract.q2.1
    contract.q2.2.2 contract.q2.2.1 contract.opF0)
  have d := oneStep (RoutineSummary.step_andA (hazeT3 state) contract.q3.1
    contract.q3.2.2 contract.q3.2.1 contract.opA7)
  have e := oneStep (RoutineSummary.step_jrZ (hazeT4 state) contract.q4.1
    contract.q4.2.2 contract.q4.2.1 contract.op28)
  have ab := RoutineSummary.runSteps_state_add 1 1 state (hazeT1 state) (hazeT2 state) a b
  have abc := RoutineSummary.runSteps_state_add 2 1 state (hazeT2 state) (hazeT3 state)
    (by simpa using ab) c
  have abcd := RoutineSummary.runSteps_state_add 3 1 state (hazeT3 state) (hazeT4 state)
    (by simpa using abc) d
  exact RoutineSummary.runSteps_state_add 4 1 state (hazeT4 state) (hazeT5 state)
    (by simpa using abcd) e

structure HazeEnemyTargetContract (state : FunctionalState) extends
    HazeTargetCommonContract state where
  zero : Alu.conditionHolds .z (hazeT4 state).registers.flags = true

/-- `hWhoseTurn = 0` takes the four-byte jump directly to enemy status. -/
theorem haze_enemy_target_exact (state : FunctionalState)
    (contract : HazeEnemyTargetContract state) :
    (RoutineSummary.runSteps 5 state).state = hazeT5 state ∧
    (hazeT5 state).registers.pc = Word.ofNat ((hazeT4 state).registers.pc.toNat + 6) := by
  constructor
  · exact haze_target_common_exact state contract.toHazeTargetCommonContract
  · simp [hazeT5, RoutineSummary.jrZ, contract.zero, contract.jumpOffset]
    exact RoutineSummary.relative_four (hazeT4 state).registers.pc

structure HazePlayerTargetContract (state : FunctionalState) extends
    HazeTargetCommonContract state where
  nonzero : Alu.conditionHolds .z (hazeT4 state).registers.flags = false
  q5 : RoutineSummary.Quiet (hazeT5 state)
  op21Player : (hazeT5 state).memory.read (hazeT5 state).registers.pc = 0x21
  q6 : RoutineSummary.Quiet (hazeT6 state)
  op1b : (hazeT6 state).memory.read (hazeT6 state).registers.pc = 0x1B

/-- Nonzero `hWhoseTurn` executes the player-target pointer adjustment. -/
theorem haze_player_target_exact (state : FunctionalState)
    (contract : HazePlayerTargetContract state) :
    (RoutineSummary.runSteps 7 state).state = hazePlayerTarget state := by
  have common := haze_target_common_exact state contract.toHazeTargetCommonContract
  have f := oneStep (RoutineSummary.step_ldHlImmediate (hazeT5 state) contract.q5.1
    contract.q5.2.2 contract.q5.2.1 contract.op21Player)
  have g := oneStep (RoutineSummary.step_decDe (hazeT6 state) contract.q6.1
    contract.q6.2.2 contract.q6.2.1 contract.op1b)
  have tail := RoutineSummary.runSteps_state_add 1 1 (hazeT5 state) (hazeT6 state)
    (hazePlayerTarget state) f g
  exact RoutineSummary.runSteps_state_add 5 2 state (hazeT5 state)
    (hazePlayerTarget state) common (by simpa using tail)

/-! ## Nonvolatile-status branch -/

def hazeU1 (s : FunctionalState) := RoutineSummary.ldAAtHl s
def hazeU2 (s : FunctionalState) := RoutineSummary.ldAtHlImmediate (hazeU1 s)
def hazeU3 (s : FunctionalState) := RoutineSummary.andImmediate (hazeU2 s)
def hazeU4 (s : FunctionalState) := RoutineSummary.jrZ (hazeU3 s)
def hazeU5 (s : FunctionalState) := RoutineSummary.ldAImmediate (hazeU4 s)
def hazeStatusBlocked (s : FunctionalState) := RoutineSummary.ldAtDeA (hazeU5 s)

structure HazeStatusCommonContract (state : FunctionalState) : Prop where
  q0 : RoutineSummary.Quiet state
  op7e : state.memory.read state.registers.pc = 0x7E
  q1 : RoutineSummary.Quiet (hazeU1 state)
  op36 : (hazeU1 state).memory.read (hazeU1 state).registers.pc = 0x36
  clearValue : (hazeU1 state).memory.read
    (Word.ofNat ((hazeU1 state).registers.pc.toNat + 1)) = 0x00
  q2 : RoutineSummary.Quiet (hazeU2 state)
  opE6 : (hazeU2 state).memory.read (hazeU2 state).registers.pc = 0xE6
  statusMask : (hazeU2 state).memory.read
    (Word.ofNat ((hazeU2 state).registers.pc.toNat + 1)) = 0x27
  q3 : RoutineSummary.Quiet (hazeU3 state)
  op28 : (hazeU3 state).memory.read (hazeU3 state).registers.pc = 0x28
  jumpOffset : (hazeU3 state).memory.read
    (Word.ofNat ((hazeU3 state).registers.pc.toNat + 1)) = 0x03

private theorem haze_status_common_exact (state : FunctionalState)
    (contract : HazeStatusCommonContract state) :
    (RoutineSummary.runSteps 4 state).state = hazeU4 state := by
  have a := oneStep (RoutineSummary.step_ldAAtHl state contract.q0.1
    contract.q0.2.2 contract.q0.2.1 contract.op7e)
  have b := oneStep (RoutineSummary.step_ldAtHlImmediate (hazeU1 state) contract.q1.1
    contract.q1.2.2 contract.q1.2.1 contract.op36)
  have c := oneStep (RoutineSummary.step_andImmediate (hazeU2 state) contract.q2.1
    contract.q2.2.2 contract.q2.2.1 contract.opE6)
  have d := oneStep (RoutineSummary.step_jrZ (hazeU3 state) contract.q3.1
    contract.q3.2.2 contract.q3.2.1 contract.op28)
  have ab := RoutineSummary.runSteps_state_add 1 1 state (hazeU1 state) (hazeU2 state) a b
  have abc := RoutineSummary.runSteps_state_add 2 1 state (hazeU2 state) (hazeU3 state)
    (by simpa using ab) c
  exact RoutineSummary.runSteps_state_add 3 1 state (hazeU3 state) (hazeU4 state)
    (by simpa using abc) d

structure HazeStatusClearContract (state : FunctionalState) extends
    HazeStatusCommonContract state where
  noSleepOrFreeze : Alu.conditionHolds .z (hazeU3 state).registers.flags = true

/-- A target without sleep/freeze skips the selected-move blocking store. -/
theorem haze_status_clear_exact (state : FunctionalState)
    (contract : HazeStatusClearContract state) :
    (RoutineSummary.runSteps 4 state).state = hazeU4 state ∧
    (hazeU4 state).registers.pc = Word.ofNat ((hazeU3 state).registers.pc.toNat + 5) := by
  constructor
  · exact haze_status_common_exact state contract.toHazeStatusCommonContract
  · simp [hazeU4, RoutineSummary.jrZ, contract.noSleepOrFreeze, contract.jumpOffset]
    exact RoutineSummary.relative_three (hazeU3 state).registers.pc

structure HazeStatusBlockedContract (state : FunctionalState) extends
    HazeStatusCommonContract state where
  sleepOrFreeze : Alu.conditionHolds .z (hazeU3 state).registers.flags = false
  q4 : RoutineSummary.Quiet (hazeU4 state)
  op3e : (hazeU4 state).memory.read (hazeU4 state).registers.pc = 0x3E
  blockedValue : (hazeU4 state).memory.read
    (Word.ofNat ((hazeU4 state).registers.pc.toNat + 1)) = 0xFF
  q5 : RoutineSummary.Quiet (hazeU5 state)
  op12 : (hazeU5 state).memory.read (hazeU5 state).registers.pc = 0x12

/-- Sleep or freeze clears status and writes `$FF` to the target selected-move
slot, preserving the cartridge's move-prevention behavior. -/
theorem haze_status_blocked_exact (state : FunctionalState)
    (contract : HazeStatusBlockedContract state) :
    (RoutineSummary.runSteps 6 state).state = hazeStatusBlocked state := by
  have common := haze_status_common_exact state contract.toHazeStatusCommonContract
  have e := oneStep (RoutineSummary.step_ldAImmediate (hazeU4 state) contract.q4.1
    contract.q4.2.2 contract.q4.2.1 contract.op3e)
  have f := oneStep (RoutineSummary.step_ldAtDeA (hazeU5 state) contract.q5.1
    contract.q5.2.2 contract.q5.2.1 contract.op12)
  have tail := RoutineSummary.runSteps_state_add 1 1 (hazeU4 state) (hazeU5 state)
    (hazeStatusBlocked state) e f
  exact RoutineSummary.runSteps_state_add 4 2 state (hazeU4 state)
    (hazeStatusBlocked state) common (by simpa using tail)

/-! ## Common cleanup through both volatile-status helper returns -/

def hazeV1 (s : FunctionalState) := RoutineSummary.xorA s
def hazeV2 (s : FunctionalState) := RoutineSummary.ldAbsoluteA (hazeV1 s)
def hazeV3 (s : FunctionalState) := RoutineSummary.ldAbsoluteA (hazeV2 s)
def hazeV4 (s : FunctionalState) := RoutineSummary.ldHlImmediate (hazeV3 s)
def hazeV5 (s : FunctionalState) := RoutineSummary.ldAtHlIncA (hazeV4 s)
def hazeV6 (s : FunctionalState) := RoutineSummary.ldAtHlA (hazeV5 s)
def hazeV7 (s : FunctionalState) := RoutineSummary.ldHlImmediate (hazeV6 s)
def hazeV8 (s : FunctionalState) := RoutineSummary.callAbsolute (hazeV7 s)
def hazeV9 (s : FunctionalState) := RoutineSummary.ret (cureVolatileBlock (hazeV8 s))
def hazeV10 (s : FunctionalState) := RoutineSummary.ldHlImmediate (hazeV9 s)
def hazeV11 (s : FunctionalState) := RoutineSummary.callAbsolute (hazeV10 s)
def hazeCleanup (s : FunctionalState) := RoutineSummary.ret (cureVolatileBlock (hazeV11 s))

structure HazeCleanupContract (state : FunctionalState) : Prop where
  q0 : RoutineSummary.Quiet state
  opAf : state.memory.read state.registers.pc = 0xAF
  q1 : RoutineSummary.Quiet (hazeV1 state)
  opEa1 : (hazeV1 state).memory.read (hazeV1 state).registers.pc = 0xEA
  q2 : RoutineSummary.Quiet (hazeV2 state)
  opEa2 : (hazeV2 state).memory.read (hazeV2 state).registers.pc = 0xEA
  q3 : RoutineSummary.Quiet (hazeV3 state)
  op21a : (hazeV3 state).memory.read (hazeV3 state).registers.pc = 0x21
  q4 : RoutineSummary.Quiet (hazeV4 state)
  op22 : (hazeV4 state).memory.read (hazeV4 state).registers.pc = 0x22
  q5 : RoutineSummary.Quiet (hazeV5 state)
  op77 : (hazeV5 state).memory.read (hazeV5 state).registers.pc = 0x77
  q6 : RoutineSummary.Quiet (hazeV6 state)
  op21b : (hazeV6 state).memory.read (hazeV6 state).registers.pc = 0x21
  q7 : RoutineSummary.Quiet (hazeV7 state)
  call1 : (hazeV7 state).memory.read (hazeV7 state).registers.pc = 0xCD
  cure1 : CureVolatileRoutineContract (hazeV8 state)
  q9 : RoutineSummary.Quiet (hazeV9 state)
  op21c : (hazeV9 state).memory.read (hazeV9 state).registers.pc = 0x21
  q10 : RoutineSummary.Quiet (hazeV10 state)
  call2 : (hazeV10 state).memory.read (hazeV10 state).registers.pc = 0xCD
  cure2 : CureVolatileRoutineContract (hazeV11 state)

/-- Twenty-eight decoded instructions perform common Haze cleanup and return
from both player and enemy `CureVolatileStatuses` calls. -/
theorem haze_cleanup_exact (state : FunctionalState)
    (contract : HazeCleanupContract state) :
    (RoutineSummary.runSteps 28 state).state = hazeCleanup state := by
  have a := oneStep (RoutineSummary.step_xorA state contract.q0.1
    contract.q0.2.2 contract.q0.2.1 contract.opAf)
  have b := oneStep (RoutineSummary.step_ldAbsoluteA (hazeV1 state) contract.q1.1
    contract.q1.2.2 contract.q1.2.1 contract.opEa1)
  have c := oneStep (RoutineSummary.step_ldAbsoluteA (hazeV2 state) contract.q2.1
    contract.q2.2.2 contract.q2.2.1 contract.opEa2)
  have d := oneStep (RoutineSummary.step_ldHlImmediate (hazeV3 state) contract.q3.1
    contract.q3.2.2 contract.q3.2.1 contract.op21a)
  have e := oneStep (RoutineSummary.step_ldAtHlIncA (hazeV4 state) contract.q4.1
    contract.q4.2.2 contract.q4.2.1 contract.op22)
  have f := oneStep (RoutineSummary.step_ldAtHlA (hazeV5 state) contract.q5.1
    contract.q5.2.2 contract.q5.2.1 contract.op77)
  have g := oneStep (RoutineSummary.step_ldHlImmediate (hazeV6 state) contract.q6.1
    contract.q6.2.2 contract.q6.2.1 contract.op21b)
  have ab := RoutineSummary.runSteps_state_add 1 1 state (hazeV1 state) (hazeV2 state) a b
  have abc := RoutineSummary.runSteps_state_add 2 1 state (hazeV2 state) (hazeV3 state)
    (by simpa using ab) c
  have abcd := RoutineSummary.runSteps_state_add 3 1 state (hazeV3 state) (hazeV4 state)
    (by simpa using abc) d
  have abcde := RoutineSummary.runSteps_state_add 4 1 state (hazeV4 state) (hazeV5 state)
    (by simpa using abcd) e
  have abcdef := RoutineSummary.runSteps_state_add 5 1 state (hazeV5 state) (hazeV6 state)
    (by simpa using abcde) f
  have firstSeven := RoutineSummary.runSteps_state_add 6 1 state (hazeV6 state)
    (hazeV7 state) (by simpa using abcdef) g

  have call1Step := RoutineSummary.step_callAbsolute (hazeV7 state) contract.q7.1
    contract.q7.2.2 contract.q7.2.1 contract.call1
  have call1Head := RoutineSummary.runSteps_after_first 9 (hazeV7 state) (hazeV8 state)
    call1Step
  have cure1 := cureVolatile_routine_exact (hazeV8 state) contract.cure1
  have call1Body : (RoutineSummary.runSteps 10 (hazeV7 state)).state = hazeV9 state := by
    rw [call1Head]
    simpa [hazeV9] using cure1
  have throughFirst := RoutineSummary.runSteps_state_add 7 10 state (hazeV7 state)
    (hazeV9 state) (by simpa using firstSeven) call1Body

  have h := oneStep (RoutineSummary.step_ldHlImmediate (hazeV9 state) contract.q9.1
    contract.q9.2.2 contract.q9.2.1 contract.op21c)
  have call2Step := RoutineSummary.step_callAbsolute (hazeV10 state) contract.q10.1
    contract.q10.2.2 contract.q10.2.1 contract.call2
  have call2Head := RoutineSummary.runSteps_after_first 9 (hazeV10 state) (hazeV11 state)
    call2Step
  have cure2 := cureVolatile_routine_exact (hazeV11 state) contract.cure2
  have call2Body : (RoutineSummary.runSteps 10 (hazeV10 state)).state = hazeCleanup state := by
    rw [call2Head]
    simpa [hazeCleanup] using cure2
  have second := RoutineSummary.runSteps_state_add 1 10 (hazeV9 state) (hazeV10 state)
    (hazeCleanup state) h call2Body
  exact RoutineSummary.runSteps_state_add 17 11 state (hazeV9 state) (hazeCleanup state)
    (by simpa using throughFirst) (by simpa using second)

/-! ## Complete gameplay-state paths through cleanup -/

structure HazeEnemyClearContract (state : FunctionalState) : Prop where
  reset : HazeResetPrefixContract state
  target : HazeEnemyTargetContract (hazeResetPrefix state)
  status : HazeStatusClearContract (hazeT5 (hazeResetPrefix state))
  cleanup : HazeCleanupContract (hazeU4 (hazeT5 (hazeResetPrefix state)))

structure HazeEnemyBlockedContract (state : FunctionalState) : Prop where
  reset : HazeResetPrefixContract state
  target : HazeEnemyTargetContract (hazeResetPrefix state)
  status : HazeStatusBlockedContract (hazeT5 (hazeResetPrefix state))
  cleanup : HazeCleanupContract (hazeStatusBlocked (hazeT5 (hazeResetPrefix state)))

structure HazePlayerClearContract (state : FunctionalState) : Prop where
  reset : HazeResetPrefixContract state
  target : HazePlayerTargetContract (hazeResetPrefix state)
  status : HazeStatusClearContract (hazePlayerTarget (hazeResetPrefix state))
  cleanup : HazeCleanupContract (hazeU4 (hazePlayerTarget (hazeResetPrefix state)))

structure HazePlayerBlockedContract (state : FunctionalState) : Prop where
  reset : HazeResetPrefixContract state
  target : HazePlayerTargetContract (hazeResetPrefix state)
  status : HazeStatusBlockedContract (hazePlayerTarget (hazeResetPrefix state))
  cleanup : HazeCleanupContract (hazeStatusBlocked (hazePlayerTarget (hazeResetPrefix state)))

/-- Enemy target, with no sleep/freeze selected-move block. -/
theorem haze_enemy_clear_exact (state : FunctionalState)
    (contract : HazeEnemyClearContract state) :
    (RoutineSummary.runSteps 184 state).state =
      hazeCleanup (hazeU4 (hazeT5 (hazeResetPrefix state))) := by
  have reset := haze_reset_prefix_exact state contract.reset
  have target := (haze_enemy_target_exact (hazeResetPrefix state) contract.target).1
  have status := (haze_status_clear_exact (hazeT5 (hazeResetPrefix state)) contract.status).1
  have cleanup := haze_cleanup_exact (hazeU4 (hazeT5 (hazeResetPrefix state))) contract.cleanup
  have a := RoutineSummary.runSteps_state_add 147 5 state (hazeResetPrefix state)
    (hazeT5 (hazeResetPrefix state)) reset target
  have b := RoutineSummary.runSteps_state_add 152 4 state
    (hazeT5 (hazeResetPrefix state)) (hazeU4 (hazeT5 (hazeResetPrefix state)))
    (by simpa using a) status
  exact RoutineSummary.runSteps_state_add 156 28 state
    (hazeU4 (hazeT5 (hazeResetPrefix state)))
    (hazeCleanup (hazeU4 (hazeT5 (hazeResetPrefix state)))) (by simpa using b) cleanup

/-- Enemy target, with sleep/freeze selected-move blocking. -/
theorem haze_enemy_blocked_exact (state : FunctionalState)
    (contract : HazeEnemyBlockedContract state) :
    (RoutineSummary.runSteps 186 state).state =
      hazeCleanup (hazeStatusBlocked (hazeT5 (hazeResetPrefix state))) := by
  have reset := haze_reset_prefix_exact state contract.reset
  have target := (haze_enemy_target_exact (hazeResetPrefix state) contract.target).1
  have status := haze_status_blocked_exact (hazeT5 (hazeResetPrefix state)) contract.status
  have cleanup := haze_cleanup_exact
    (hazeStatusBlocked (hazeT5 (hazeResetPrefix state))) contract.cleanup
  have a := RoutineSummary.runSteps_state_add 147 5 state (hazeResetPrefix state)
    (hazeT5 (hazeResetPrefix state)) reset target
  have b := RoutineSummary.runSteps_state_add 152 6 state
    (hazeT5 (hazeResetPrefix state)) (hazeStatusBlocked (hazeT5 (hazeResetPrefix state)))
    (by simpa using a) status
  exact RoutineSummary.runSteps_state_add 158 28 state
    (hazeStatusBlocked (hazeT5 (hazeResetPrefix state)))
    (hazeCleanup (hazeStatusBlocked (hazeT5 (hazeResetPrefix state)))) (by simpa using b) cleanup

/-- Player target, with no sleep/freeze selected-move block. -/
theorem haze_player_clear_exact (state : FunctionalState)
    (contract : HazePlayerClearContract state) :
    (RoutineSummary.runSteps 186 state).state =
      hazeCleanup (hazeU4 (hazePlayerTarget (hazeResetPrefix state))) := by
  have reset := haze_reset_prefix_exact state contract.reset
  have target := haze_player_target_exact (hazeResetPrefix state) contract.target
  have status := (haze_status_clear_exact
    (hazePlayerTarget (hazeResetPrefix state)) contract.status).1
  have cleanup := haze_cleanup_exact
    (hazeU4 (hazePlayerTarget (hazeResetPrefix state))) contract.cleanup
  have a := RoutineSummary.runSteps_state_add 147 7 state (hazeResetPrefix state)
    (hazePlayerTarget (hazeResetPrefix state)) reset target
  have b := RoutineSummary.runSteps_state_add 154 4 state
    (hazePlayerTarget (hazeResetPrefix state))
    (hazeU4 (hazePlayerTarget (hazeResetPrefix state))) (by simpa using a) status
  exact RoutineSummary.runSteps_state_add 158 28 state
    (hazeU4 (hazePlayerTarget (hazeResetPrefix state)))
    (hazeCleanup (hazeU4 (hazePlayerTarget (hazeResetPrefix state)))) (by simpa using b) cleanup

/-- Player target, with sleep/freeze selected-move blocking. -/
theorem haze_player_blocked_exact (state : FunctionalState)
    (contract : HazePlayerBlockedContract state) :
    (RoutineSummary.runSteps 188 state).state =
      hazeCleanup (hazeStatusBlocked (hazePlayerTarget (hazeResetPrefix state))) := by
  have reset := haze_reset_prefix_exact state contract.reset
  have target := haze_player_target_exact (hazeResetPrefix state) contract.target
  have status := haze_status_blocked_exact
    (hazePlayerTarget (hazeResetPrefix state)) contract.status
  have cleanup := haze_cleanup_exact
    (hazeStatusBlocked (hazePlayerTarget (hazeResetPrefix state))) contract.cleanup
  have a := RoutineSummary.runSteps_state_add 147 7 state (hazeResetPrefix state)
    (hazePlayerTarget (hazeResetPrefix state)) reset target
  have b := RoutineSummary.runSteps_state_add 154 6 state
    (hazePlayerTarget (hazeResetPrefix state))
    (hazeStatusBlocked (hazePlayerTarget (hazeResetPrefix state))) (by simpa using a) status
  exact RoutineSummary.runSteps_state_add 160 28 state
    (hazeStatusBlocked (hazePlayerTarget (hazeResetPrefix state)))
    (hazeCleanup (hazeStatusBlocked (hazePlayerTarget (hazeResetPrefix state))))
    (by simpa using b) cleanup

/-! ## Presentation tail and external continuation boundary -/

def hazeAnimationPointer (s : FunctionalState) := RoutineSummary.ldHlImmediate s
def hazeCallBankF (s : FunctionalState) := RoutineSummary.callAbsolute (hazeAnimationPointer s)
def hazeTextPointer (s : FunctionalState) := RoutineSummary.ldHlImmediate s
def hazePrintText (s : FunctionalState) := RoutineSummary.jpAbsolute (hazeTextPointer s)

/-- The remaining nonlocal obligation is isolated to `CallBankF` and the move
animation it invokes. The contract records an exact architectural count rather
than treating fuel exhaustion or an oracle result as semantics. -/
structure HazePresentationContract (state returned : FunctionalState) (count : Nat) : Prop where
  q0 : RoutineSummary.Quiet state
  op21Animation : state.memory.read state.registers.pc = 0x21
  q1 : RoutineSummary.Quiet (hazeAnimationPointer state)
  opCallBankF : (hazeAnimationPointer state).memory.read
    (hazeAnimationPointer state).registers.pc = 0xCD
  callTarget : (hazeCallBankF state).registers.pc = 0x79D5
  externalExecution : (RoutineSummary.runSteps count (hazeCallBankF state)).state = returned
  returnedQuiet : RoutineSummary.Quiet returned
  op21Text : returned.memory.read returned.registers.pc = 0x21
  textQuiet : RoutineSummary.Quiet (hazeTextPointer returned)
  opPrintText : (hazeTextPointer returned).memory.read
    (hazeTextPointer returned).registers.pc = 0xC3
  printTarget : (hazePrintText returned).registers.pc = 0x3C49

/-- Conditional full tail refinement: enter canonical `CallBankF`, compose its
explicit execution summary, and decode the final tail jump to `PrintText`. -/
theorem haze_presentation_tail_exact (state returned : FunctionalState) (count : Nat)
    (contract : HazePresentationContract state returned count) :
    (RoutineSummary.runSteps (count + 4) state).state = hazePrintText returned ∧
    (hazePrintText returned).registers.pc = 0x3C49 := by
  have a := oneStep (RoutineSummary.step_ldHlImmediate state contract.q0.1
    contract.q0.2.2 contract.q0.2.1 contract.op21Animation)
  have b := oneStep (RoutineSummary.step_callAbsolute (hazeAnimationPointer state)
    contract.q1.1 contract.q1.2.2 contract.q1.2.1 contract.opCallBankF)
  have setup := RoutineSummary.runSteps_state_add 1 1 state (hazeAnimationPointer state)
    (hazeCallBankF state) a b
  have throughExternal := RoutineSummary.runSteps_state_add 2 count state
    (hazeCallBankF state) returned (by simpa using setup) contract.externalExecution
  have c := oneStep (RoutineSummary.step_ldHlImmediate returned contract.returnedQuiet.1
    contract.returnedQuiet.2.2 contract.returnedQuiet.2.1 contract.op21Text)
  have d := oneStep (RoutineSummary.step_jpAbsolute (hazeTextPointer returned)
    contract.textQuiet.1 contract.textQuiet.2.2 contract.textQuiet.2.1 contract.opPrintText)
  have finish := RoutineSummary.runSteps_state_add 1 1 returned (hazeTextPointer returned)
    (hazePrintText returned) c d
  constructor
  · have all := RoutineSummary.runSteps_state_add (2 + count) 2 state returned
      (hazePrintText returned) throughExternal (by simpa using finish)
    simpa [Nat.add_assoc, Nat.add_comm, Nat.add_left_comm] using all
  · exact contract.printTarget

/-- Generic composition of any proved gameplay core with the presentation
continuation. Instantiating `coreSteps` with 184, 186, or 188 yields the four
turn/status paths above. -/
theorem haze_core_to_print_exact (initial core returned : FunctionalState)
    (coreSteps externalSteps : Nat)
    (coreExecution : (RoutineSummary.runSteps coreSteps initial).state = core)
    (presentation : HazePresentationContract core returned externalSteps) :
    (RoutineSummary.runSteps (coreSteps + externalSteps + 4) initial).state =
      hazePrintText returned := by
  have tail := (haze_presentation_tail_exact core returned externalSteps presentation).1
  have composed := RoutineSummary.runSteps_state_add coreSteps (externalSteps + 4)
    initial core (hazePrintText returned) coreExecution tail
  simpa [Nat.add_assoc] using composed

structure RequiredHazeBytes (rom : Array Byte) : Prop where
  gameplayWindow : Tables.tableBytes rom
      (romOffset 0x04 (Word.ofNat hazeEntry.toNat)) hazeBytes.length =
    hazeBytes.map (fun byte => byte.toNat.toUInt8)
  helperWindow : Tables.tableBytes rom
      (romOffset 0x04 (Word.ofNat helpersEntry.toNat)) helperBytes.length =
    helperBytes.map (fun byte => byte.toNat.toUInt8)

structure CanonicalHazeBytes (sha256 : Sha256) (rom : CanonicalRom) : Prop where
  transform : TransformRoutine.CanonicalTransformBytes sha256 rom
  haze : RequiredHazeBytes rom.bytes

/-- Runtime fixture predicate only. -/
def windowAgrees (rom : Array Byte) : Bool :=
  decide (Tables.tableBytes rom (romOffset 0x04 (Word.ofNat hazeEntry.toNat))
      hazeBytes.length = hazeBytes.map (fun byte => byte.toNat.toUInt8)) &&
  decide (Tables.tableBytes rom (romOffset 0x04 (Word.ofNat helpersEntry.toNat))
      helperBytes.length = helperBytes.map (fun byte => byte.toNat.toUInt8))

end Battle.Rom.HazeRoutine
