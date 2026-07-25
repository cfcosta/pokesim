/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Rom.TransformRoutine
import Battle.Rom.RoutineSummary

/-!
# Compositional decoded Haze helpers

The eight-byte `ResetStats` loop defeated monolithic symbolic
`Driver.runToReturn` unfolding. This module instead proves one arbitrary symbolic
iteration from five decoded instruction equations. The result preserves the
source byte, destination write, both pointer increments, exact counter decrement,
and taken/fallthrough PC. Repeated applications therefore scale without
enumerating the 2^64 possible stat-byte vectors.

The complete Haze gameplay and helper windows are retained as explicit canonical
ROM obligations. Presentation calls after the gameplay prefix remain a separate
reachability/composition boundary.
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
