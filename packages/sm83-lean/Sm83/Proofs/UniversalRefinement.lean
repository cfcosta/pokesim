/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

import Sm83.FlatAdapter
import Sm83.Relation
import Sm83.Retirement

namespace Sm83
namespace Proofs.UniversalRefinement

private def noInterrupts : Nat → FlatCoreState → Byte := fun _ _ => 0

private def physicalInitial (state : FunctionalState) : FlatCoreState :=
  { core := {
      Pipeline.bootstrap state.registers with
      ime := state.ime
      scheduledImeEnable := state.scheduledImeEnable
      haltBug := state.haltBug }
    memory := state.memory }

private def nopFetchedCore (state : FunctionalState) : CoreState :=
  { registers := { state.registers with
      pc := Word.ofNat (state.registers.pc.toNat + 1) }
    ime := state.ime
    scheduledImeEnable := state.scheduledImeEnable
    haltBug := false
    phase := .execute
    ir := some { byte := 0, address := state.registers.pc }
    shape := some .nop
    remaining := [.successorFetch]
    latches := { conditionTaken := true } }

private def nopFetched (state : FunctionalState) : FlatCoreState :=
  { core := nopFetchedCore state
    memory := state.memory
    trace := [.read .opcode state.registers.pc 0] }

/-- The bootstrap fetch installs the exact NOP execution checkpoint. -/
private theorem fetch_nop (before : FunctionalState)
    (opcode : before.memory.read before.registers.pc = 0x00)
    (noHaltBug : before.haltBug = false) :
    FlatAdapter.step (physicalInitial before) = nopFetched before := by
  simp [FlatAdapter.step, physicalInitial, nopFetched, nopFetchedCore,
    Pipeline.bootstrap, Pipeline.install, opcode, noHaltBug,
    Run.stepMachineCycle, FlatAdapter.event]
  all_goals simp [Decode.base, Pipeline.taken, Cycle.physicalSchedule,
    Cycle.logicalSchedule]

set_option maxHeartbeats 1000000 in
/-- Universal NOP base case. The comparison uses the retirement snapshot rather
than the already-decoded successor's mode, so an invalid successor remains a
separate lock edge. -/
theorem nop_refines (before : FunctionalState)
    (running : before.mode = .running)
    (noHaltBug : before.haltBug = false)
    (opcode : before.memory.read before.registers.pc = 0x00) :
    let logical := Functional.step before 0
    let physical := FlatAdapter.run 2 (physicalInitial before) noInterrupts
    Retirement.Snapshot.atBoundary physical.core =
        Retirement.Snapshot.ofFunctional logical.state ∧
      physical.memory = logical.state.memory ∧
      physical.trace.dropLast = logical.trace := by
  rw [show FlatAdapter.run 2 (physicalInitial before) noInterrupts =
      FlatAdapter.step (FlatAdapter.step (physicalInitial before)) by rfl]
  rw [fetch_nop before opcode noHaltBug]
  simp [Functional.step, running, opcode, noHaltBug, nopFetched,
    nopFetchedCore, FlatAdapter.step, CoreState.currentOp?, Run.stepMachineCycle,
    Run.intent, Run.opFetch, Run.opCommit, Run.opPoll, Run.opControl,
    Run.opAddress, Run.successorAddress, Run.opReadKind, Run.opIdu,
    Run.finishSuccessor, Run.commitRegisters, Run.commitIme, FlatAdapter.event]
  all_goals simp [Decode.base, InstructionShape.immediateBytes,
    Functional.fetchImmediate, Functional.executeShape, Functional.matureIme,
    Retirement.Snapshot.atBoundary, Retirement.Snapshot.ofFunctional]
  all_goals cases before.scheduledImeEnable <;> simp

/-- Base instruction families whose complete physical schedule is the successor
fetch and whose operands are register-only. -/
inductive RegisterSingleCycle : InstructionShape → Prop where
  | nop : RegisterSingleCycle .nop
  | inc8 (register : Reg8) : RegisterSingleCycle (.inc8 (.reg register))
  | dec8 (register : Reg8) : RegisterSingleCycle (.dec8 (.reg register))
  | accRotate (operation : AccRotate) : RegisterSingleCycle (.accRotate operation)
  | daa : RegisterSingleCycle .daa
  | cpl : RegisterSingleCycle .cpl
  | scf : RegisterSingleCycle .scf
  | ccf : RegisterSingleCycle .ccf
  | ld8 (destination source : Reg8) :
      RegisterSingleCycle (.ld8 (.reg destination) (.reg source))
  | aluA (operation : AluOp) (source : Reg8) :
      RegisterSingleCycle (.aluA operation (.reg source))
  | jpHL : RegisterSingleCycle .jpHL
  | di : RegisterSingleCycle .di
  | ei : RegisterSingleCycle .ei

private def baseFetchedCore (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) : CoreState :=
  let taken := Pipeline.taken shape state.registers.flags
  { registers := { state.registers with
      pc := Word.ofNat (state.registers.pc.toNat + 1) }
    ime := state.ime
    scheduledImeEnable := state.scheduledImeEnable
    haltBug := false
    phase := .execute
    ir := some { byte := opcode, address := state.registers.pc }
    shape := some shape
    remaining := Cycle.physicalSchedule shape taken
    latches := { conditionTaken := taken } }

private def baseFetched (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) : FlatCoreState :=
  { core := baseFetchedCore state opcode shape
    memory := state.memory
    trace := [.read .opcode state.registers.pc opcode] }

private theorem fetch_legal (before : FunctionalState) (opcode : Byte)
    (shape : InstructionShape)
    (atPC : before.memory.read before.registers.pc = opcode)
    (noHaltBug : before.haltBug = false)
    (decoded : Decode.base opcode = .legal shape) :
    FlatAdapter.step (physicalInitial before) = baseFetched before opcode shape := by
  simp [FlatAdapter.step, physicalInitial, baseFetched, baseFetchedCore,
    Pipeline.bootstrap, Pipeline.install, atPC, noHaltBug, decoded,
    Run.stepMachineCycle, FlatAdapter.event]

set_option maxHeartbeats 4000000 in
/-- Universal refinement for every register-only one-M-cycle base family. -/
theorem register_single_cycle_refines (before : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (family : RegisterSingleCycle shape)
    (running : before.mode = .running)
    (noHaltBug : before.haltBug = false)
    (atPC : before.memory.read before.registers.pc = opcode)
    (decoded : Decode.base opcode = .legal shape) :
    let logical := Functional.step before 0
    let physical := FlatAdapter.run 2 (physicalInitial before) noInterrupts
    Retirement.Snapshot.atBoundary physical.core =
        Retirement.Snapshot.ofFunctional logical.state ∧
      physical.memory = logical.state.memory ∧
      physical.trace.dropLast = logical.trace := by
  rw [show FlatAdapter.run 2 (physicalInitial before) noInterrupts =
      FlatAdapter.step (FlatAdapter.step (physicalInitial before)) by rfl]
  rw [fetch_legal before opcode shape atPC noHaltBug decoded]
  cases family <;>
    simp [Functional.step, running, atPC, decoded, noHaltBug, baseFetched,
      baseFetchedCore, Pipeline.taken, Cycle.physicalSchedule,
      Cycle.logicalSchedule, Cycle.targetIsMemory, FlatAdapter.step, CoreState.currentOp?,
      Run.stepMachineCycle, Run.intent, Run.opFetch, Run.opCommit, Run.opPoll,
      Run.opControl, Run.opAddress, Run.successorAddress, Run.opReadKind,
      Run.opIdu, Run.finishSuccessor, Run.commitRegisters, Run.commitIme,
      Run.targetValue, Run.setTarget, Functional.fetchImmediate,
      InstructionShape.immediateBytes, Functional.executeShape,
      Functional.readTarget, Functional.writeTarget, Functional.matureIme,
      Functional.withRegisters, Functional.setFlags, FlatAdapter.event]
  all_goals cases before.scheduledImeEnable <;>
    simp [Retirement.Snapshot.atBoundary, Retirement.Snapshot.ofFunctional]
  all_goals cases ‹Reg8› <;> cases ‹Reg8› <;> rfl

/-- All CB families whose target is one of the seven byte registers. -/
inductive CbRegisterShape : InstructionShape → Prop where
  | rotate (operation : CbRotate) (register : Reg8) :
      CbRegisterShape (.cbRotate operation (.reg register))
  | bit (index : BitIndex) (register : Reg8) :
      CbRegisterShape (.bit index (.reg register))
  | res (index : BitIndex) (register : Reg8) :
      CbRegisterShape (.res index (.reg register))
  | set (index : BitIndex) (register : Reg8) :
      CbRegisterShape (.set index (.reg register))

private def prefixFetchedCore (state : FunctionalState) : CoreState :=
  { registers := { state.registers with
      pc := Word.ofNat (state.registers.pc.toNat + 1) }
    ime := state.ime
    scheduledImeEnable := state.scheduledImeEnable
    haltBug := false
    phase := .execute
    ir := some { byte := 0xCB, address := state.registers.pc }
    remaining := [.cbFetch] }

private def prefixFetched (state : FunctionalState) : FlatCoreState :=
  { core := prefixFetchedCore state
    memory := state.memory
    trace := [.read .opcode state.registers.pc 0xCB] }

private def cbFetchedCore (state : FunctionalState) (shape : InstructionShape) : CoreState :=
  { registers := { state.registers with
      pc := Word.ofNat (state.registers.pc.toNat + 2) }
    ime := state.ime
    scheduledImeEnable := state.scheduledImeEnable
    haltBug := false
    phase := .execute
    ir := some { byte := 0xCB, address := state.registers.pc }
    shape := some shape
    remaining := (Cycle.physicalSchedule shape).drop 1
    latches := { conditionTaken := true } }

private def cbFetched (state : FunctionalState) (subopcode : Byte)
    (shape : InstructionShape) : FlatCoreState :=
  { core := cbFetchedCore state shape
    memory := state.memory
    trace := [.read .opcode state.registers.pc 0xCB,
      .read .cbOpcode (Word.ofNat (state.registers.pc.toNat + 1)) subopcode] }

private theorem fetch_prefix (before : FunctionalState)
    (atPC : before.memory.read before.registers.pc = 0xCB)
    (noHaltBug : before.haltBug = false) :
    FlatAdapter.step (physicalInitial before) = prefixFetched before := by
  simp [FlatAdapter.step, physicalInitial, prefixFetched, prefixFetchedCore,
    Pipeline.bootstrap, Pipeline.install, Decode.base, atPC, noHaltBug,
    Run.stepMachineCycle, FlatAdapter.event]

private theorem increment_twice : ∀ pc : Word,
    Word.ofNat ((Word.ofNat (pc.toNat + 1)).toNat + 1) = Word.ofNat (pc.toNat + 2) := by
  native_decide

private theorem fetch_cb (before : FunctionalState) (subopcode : Byte)
    (shape : InstructionShape)
    (atSubopcode : before.memory.read (Word.ofNat (before.registers.pc.toNat + 1)) = subopcode)
    (decoded : Decode.cb subopcode = shape) :
    FlatAdapter.step (prefixFetched before) = cbFetched before subopcode shape := by
  simp [FlatAdapter.step, prefixFetched, prefixFetchedCore, cbFetched,
    cbFetchedCore, CoreState.currentOp?, Run.stepMachineCycle, Run.intent,
    Run.opFetch, Run.opCommit, Run.opPoll, Run.opControl, Run.opAddress,
    Run.opReadKind, Run.opIdu, Run.processNonFetch, Pipeline.installCB,
    atSubopcode, decoded, increment_twice, FlatAdapter.event]

set_option maxHeartbeats 4000000 in
/-- Universal fetched-IR refinement for all 224 register-targeted CB bytes. -/
theorem cb_register_refines (before : FunctionalState) (subopcode : Byte)
    (shape : InstructionShape) (family : CbRegisterShape shape)
    (running : before.mode = .running)
    (noHaltBug : before.haltBug = false)
    (atPrefix : before.memory.read before.registers.pc = 0xCB)
    (atSubopcode : before.memory.read (Word.ofNat (before.registers.pc.toNat + 1)) = subopcode)
    (decoded : Decode.cb subopcode = shape) :
    let logical := Functional.step before 0
    let physical := FlatAdapter.run 3 (physicalInitial before) noInterrupts
    Retirement.Snapshot.atBoundary physical.core =
        Retirement.Snapshot.ofFunctional logical.state ∧
      physical.memory = logical.state.memory ∧
      physical.trace.dropLast = logical.trace := by
  rw [show FlatAdapter.run 3 (physicalInitial before) noInterrupts =
      FlatAdapter.step (FlatAdapter.step (FlatAdapter.step (physicalInitial before))) by rfl]
  rw [fetch_prefix before atPrefix noHaltBug]
  rw [fetch_cb before subopcode shape atSubopcode decoded]
  cases family <;>
    simp [Functional.step, Decode.base, running, atPrefix, atSubopcode, decoded, noHaltBug,
      cbFetched, cbFetchedCore, Cycle.physicalSchedule, Cycle.logicalSchedule,
      Cycle.targetIsMemory, FlatAdapter.step, CoreState.currentOp?,
      Run.stepMachineCycle, Run.intent, Run.opFetch, Run.opCommit, Run.opPoll,
      Run.opControl, Run.opAddress, Run.successorAddress, Run.opReadKind,
      Run.opIdu, Run.finishSuccessor, Run.commitRegisters, Run.commitIme,
      Run.targetValue, Run.setTarget, Functional.read, Functional.withRegisters,
      Functional.executeShape, Functional.readTarget, Functional.writeTarget,
      Functional.matureIme, Functional.setFlags, increment_twice, FlatAdapter.event]
  all_goals cases before.scheduledImeEnable <;>
    simp [Retirement.Snapshot.atBoundary, Retirement.Snapshot.ofFunctional]
  all_goals cases ‹Reg8› <;> simp [Registers.set8, Registers.get8]

end Proofs.UniversalRefinement
end Sm83
