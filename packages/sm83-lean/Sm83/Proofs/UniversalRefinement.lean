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

private def cbBitReadCore (state : FunctionalState) (index : BitIndex)
    (value : Byte) : CoreState :=
  { cbFetchedCore state (.bit index .atHL) with
    remaining := [.successorFetch]
    latches := { data := value, conditionTaken := true } }

private def cbBitRead (state : FunctionalState) (index : BitIndex)
    (value : Byte) : FlatCoreState :=
  { core := cbBitReadCore state index value
    memory := state.memory
    trace := [.read .opcode state.registers.pc 0xCB,
      .read .cbOpcode (Word.ofNat (state.registers.pc.toNat + 1))
        (state.memory.read (Word.ofNat (state.registers.pc.toNat + 1))),
      .read .data state.registers.hl value] }

/-- The `(HL)` operand read advances the physical CB schedule and captures the
exact flat-memory byte. -/
private theorem step_cb_bit_read (before : FunctionalState) (index : BitIndex) :
    FlatAdapter.step (cbFetched before
      (before.memory.read (Word.ofNat (before.registers.pc.toNat + 1)))
      (.bit index .atHL)) =
    cbBitRead before index (before.memory.read before.registers.hl) := by
  simp [FlatAdapter.step, cbFetched, cbFetchedCore, cbBitRead, cbBitReadCore,
    Cycle.physicalSchedule, Cycle.logicalSchedule, Cycle.targetIsMemory,
    CoreState.currentOp?, Run.stepMachineCycle, Run.intent, Run.opFetch,
    Run.opCommit, Run.opPoll, Run.opControl, Run.opAddress, Run.opReadKind,
    Run.opIdu, Run.processNonFetch, Run.updatePointer, Registers.hl,
    FlatAdapter.event]

set_option maxHeartbeats 2000000 in
/-- Universal fetched-IR refinement for the eight `BIT n,(HL)` entries. -/
theorem cb_bit_hl_refines (before : FunctionalState) (subopcode : Byte)
    (index : BitIndex)
    (running : before.mode = .running)
    (noHaltBug : before.haltBug = false)
    (atPrefix : before.memory.read before.registers.pc = 0xCB)
    (atSubopcode : before.memory.read (Word.ofNat (before.registers.pc.toNat + 1)) = subopcode)
    (decoded : Decode.cb subopcode = .bit index .atHL) :
    let logical := Functional.step before 0
    let physical := FlatAdapter.run 4 (physicalInitial before) noInterrupts
    Retirement.Snapshot.atBoundary physical.core =
        Retirement.Snapshot.ofFunctional logical.state ∧
      physical.memory = logical.state.memory ∧
      physical.trace.dropLast = logical.trace := by
  rw [show FlatAdapter.run 4 (physicalInitial before) noInterrupts =
      FlatAdapter.step (FlatAdapter.step (FlatAdapter.step
        (FlatAdapter.step (physicalInitial before)))) by rfl]
  rw [fetch_prefix before atPrefix noHaltBug]
  rw [fetch_cb before subopcode (.bit index .atHL) atSubopcode decoded]
  rw [show cbFetched before subopcode (.bit index .atHL) =
      cbFetched before
        (before.memory.read (Word.ofNat (before.registers.pc.toNat + 1)))
        (.bit index .atHL) by rw [atSubopcode]]
  rw [step_cb_bit_read before index]
  simp [Functional.step, Decode.base, running, atPrefix, atSubopcode, decoded,
    noHaltBug, cbBitRead, cbBitReadCore, cbFetchedCore,
    Cycle.physicalSchedule, Cycle.logicalSchedule, Cycle.targetIsMemory, FlatAdapter.step,
    CoreState.currentOp?, Run.stepMachineCycle, Run.intent, Run.opFetch,
    Run.opCommit, Run.opPoll, Run.opControl, Run.opAddress,
    Run.successorAddress, Run.opReadKind, Run.opIdu, Run.finishSuccessor,
    Run.commitRegisters, Run.commitIme, Run.targetValue, Registers.hl,
    Functional.read, Functional.withRegisters, Functional.executeShape,
    Functional.readTarget, Functional.matureIme, Functional.setFlags,
    increment_twice, FlatAdapter.event]
  all_goals cases before.scheduledImeEnable <;>
    simp [Retirement.Snapshot.atBoundary, Retirement.Snapshot.ofFunctional]

/-- Memory-target CB read-modify-write families. -/
inductive CbModifyHL : InstructionShape → Prop where
  | rotate (operation : CbRotate) : CbModifyHL (.cbRotate operation .atHL)
  | res (index : BitIndex) : CbModifyHL (.res index .atHL)
  | set (index : BitIndex) : CbModifyHL (.set index .atHL)

private def cbModifiedValue (state : FunctionalState) (shape : InstructionShape)
    (value : Byte) : Byte :=
  match shape with
  | .cbRotate operation .atHL => (Alu.rotate operation value state.registers.flags.c).value
  | .res index .atHL => Alu.resetBit index value
  | .set index .atHL => Alu.setBit index value
  | _ => value

private def cbModifyReadCore (state : FunctionalState) (shape : InstructionShape)
    (value : Byte) : CoreState :=
  { cbFetchedCore state shape with
    remaining := [.writeHL, .successorFetch]
    latches := { data := value, conditionTaken := true } }

private def cbModifyRead (state : FunctionalState) (shape : InstructionShape)
    (value : Byte) : FlatCoreState :=
  { core := cbModifyReadCore state shape value
    memory := state.memory
    trace := [.read .opcode state.registers.pc 0xCB,
      .read .cbOpcode (Word.ofNat (state.registers.pc.toNat + 1))
        (state.memory.read (Word.ofNat (state.registers.pc.toNat + 1))),
      .read .data state.registers.hl value] }

private def cbModifyWriteCore (state : FunctionalState) (shape : InstructionShape)
    (value : Byte) : CoreState :=
  { cbModifyReadCore state shape value with remaining := [.successorFetch] }

private def cbModifyWritten (state : FunctionalState) (shape : InstructionShape)
    (value : Byte) : FlatCoreState :=
  let written := cbModifiedValue state shape value
  { core := cbModifyWriteCore state shape value
    memory := state.memory.write state.registers.hl written
    trace := [.read .opcode state.registers.pc 0xCB,
      .read .cbOpcode (Word.ofNat (state.registers.pc.toNat + 1))
        (state.memory.read (Word.ofNat (state.registers.pc.toNat + 1))),
      .read .data state.registers.hl value,
      .write state.registers.hl written] }

private theorem step_cb_modify_read (before : FunctionalState) (shape : InstructionShape)
    (family : CbModifyHL shape) :
    FlatAdapter.step (cbFetched before
      (before.memory.read (Word.ofNat (before.registers.pc.toNat + 1))) shape) =
    cbModifyRead before shape (before.memory.read before.registers.hl) := by
  cases family <;>
    simp [FlatAdapter.step, cbFetched, cbFetchedCore, cbModifyRead,
      cbModifyReadCore, Cycle.physicalSchedule, Cycle.logicalSchedule,
      Cycle.targetIsMemory, CoreState.currentOp?, Run.stepMachineCycle,
      Run.intent, Run.opFetch, Run.opCommit, Run.opPoll, Run.opControl,
      Run.opAddress, Run.opReadKind, Run.opIdu, Run.processNonFetch,
      Run.updatePointer, Registers.hl, FlatAdapter.event]

private theorem step_cb_modify_write (before : FunctionalState) (shape : InstructionShape)
    (family : CbModifyHL shape) :
    FlatAdapter.step (cbModifyRead before shape (before.memory.read before.registers.hl)) =
    cbModifyWritten before shape (before.memory.read before.registers.hl) := by
  cases family <;>
    simp [FlatAdapter.step, cbModifyRead, cbModifyReadCore, cbModifyWritten,
      cbModifyWriteCore, cbModifiedValue, cbFetchedCore,
      Cycle.physicalSchedule, Cycle.logicalSchedule, Cycle.targetIsMemory,
      CoreState.currentOp?,
      Run.stepMachineCycle, Run.intent, Run.opFetch, Run.opCommit, Run.opPoll,
      Run.opControl, Run.opAddress, Run.opReadKind, Run.opIdu,
      Run.processNonFetch, Run.writeValue, Registers.hl,
      FlatAdapter.event]

set_option maxHeartbeats 3000000 in
/-- Universal fetched-IR refinement for all 24 `(HL)` CB read-modify-write entries. -/
theorem cb_modify_hl_refines (before : FunctionalState) (subopcode : Byte)
    (shape : InstructionShape) (family : CbModifyHL shape)
    (running : before.mode = .running)
    (noHaltBug : before.haltBug = false)
    (atPrefix : before.memory.read before.registers.pc = 0xCB)
    (atSubopcode : before.memory.read (Word.ofNat (before.registers.pc.toNat + 1)) = subopcode)
    (decoded : Decode.cb subopcode = shape) :
    let logical := Functional.step before 0
    let physical := FlatAdapter.run 5 (physicalInitial before) noInterrupts
    Retirement.Snapshot.atBoundary physical.core =
        Retirement.Snapshot.ofFunctional logical.state ∧
      physical.memory = logical.state.memory ∧
      physical.trace.dropLast = logical.trace := by
  rw [show FlatAdapter.run 5 (physicalInitial before) noInterrupts =
      FlatAdapter.step (FlatAdapter.step (FlatAdapter.step (FlatAdapter.step
        (FlatAdapter.step (physicalInitial before))))) by rfl]
  rw [fetch_prefix before atPrefix noHaltBug]
  rw [fetch_cb before subopcode shape atSubopcode decoded]
  rw [show cbFetched before subopcode shape = cbFetched before
      (before.memory.read (Word.ofNat (before.registers.pc.toNat + 1))) shape by
    rw [atSubopcode]]
  rw [step_cb_modify_read before shape family]
  rw [step_cb_modify_write before shape family]
  cases family <;>
    simp [Functional.step, Decode.base, running, atPrefix, atSubopcode, decoded,
      noHaltBug, cbModifyWritten, cbModifyWriteCore, cbModifyReadCore,
      cbFetchedCore, cbModifiedValue, FlatAdapter.step, CoreState.currentOp?,
      Run.stepMachineCycle, Run.intent, Run.opFetch, Run.opCommit, Run.opPoll,
      Run.opControl, Run.opAddress, Run.successorAddress, Run.opReadKind,
      Run.opIdu, Run.finishSuccessor, Run.commitRegisters, Run.commitIme,
      Run.targetValue, Run.setTarget, Functional.read, Functional.write,
      Functional.withRegisters, Functional.executeShape, Functional.readTarget,
      Functional.writeTarget, Functional.matureIme, Functional.setFlags,
      Registers.hl, increment_twice, FlatAdapter.event]
  all_goals cases before.scheduledImeEnable <;>
    simp [Retirement.Snapshot.atBoundary, Retirement.Snapshot.ofFunctional]

/-- Register-target immediate-byte base families. -/
inductive ImmediateRegisterShape : InstructionShape → Prop where
  | ld8 (register : Reg8) : ImmediateRegisterShape (.ld8Imm (.reg register))
  | alu (operation : AluOp) : ImmediateRegisterShape (.aluAImm operation)

private def immediateReadCore (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (value : Byte) : CoreState :=
  { baseFetchedCore state opcode shape with
    registers := { state.registers with pc := Word.ofNat (state.registers.pc.toNat + 2) }
    remaining := [.successorFetch]
    latches := { low := value, conditionTaken := true } }

private def immediateRead (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (value : Byte) : FlatCoreState :=
  { core := immediateReadCore state opcode shape value
    memory := state.memory
    trace := [.read .opcode state.registers.pc opcode,
      .read .immediate (Word.ofNat (state.registers.pc.toNat + 1)) value] }

private theorem step_immediate_register (before : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (family : ImmediateRegisterShape shape) :
    FlatAdapter.step (baseFetched before opcode shape) =
      immediateRead before opcode shape
        (before.memory.read (Word.ofNat (before.registers.pc.toNat + 1))) := by
  cases family <;>
    simp [FlatAdapter.step, baseFetched, baseFetchedCore, immediateRead,
      immediateReadCore, Pipeline.taken, Cycle.physicalSchedule,
      Cycle.logicalSchedule, Cycle.targetIsMemory, CoreState.currentOp?,
      Run.stepMachineCycle, Run.intent, Run.opFetch, Run.opCommit, Run.opPoll,
      Run.opControl, Run.opAddress, Run.opReadKind, Run.opIdu,
      Run.processNonFetch, increment_twice, FlatAdapter.event]

set_option maxHeartbeats 3000000 in
/-- Universal refinement for seven `LD r,n` and eight immediate ALU entries. -/
theorem immediate_register_refines (before : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (family : ImmediateRegisterShape shape)
    (running : before.mode = .running)
    (noHaltBug : before.haltBug = false)
    (atPC : before.memory.read before.registers.pc = opcode)
    (decoded : Decode.base opcode = .legal shape) :
    let logical := Functional.step before 0
    let physical := FlatAdapter.run 3 (physicalInitial before) noInterrupts
    Retirement.Snapshot.atBoundary physical.core =
        Retirement.Snapshot.ofFunctional logical.state ∧
      physical.memory = logical.state.memory ∧
      physical.trace.dropLast = logical.trace := by
  rw [show FlatAdapter.run 3 (physicalInitial before) noInterrupts =
      FlatAdapter.step (FlatAdapter.step (FlatAdapter.step (physicalInitial before))) by rfl]
  rw [fetch_legal before opcode shape atPC noHaltBug decoded]
  rw [step_immediate_register before opcode shape family]
  cases family <;>
    simp [Functional.step, running, atPC, decoded, noHaltBug, immediateRead,
      immediateReadCore, baseFetchedCore, Pipeline.taken, FlatAdapter.step,
      CoreState.currentOp?, Run.stepMachineCycle, Run.intent, Run.opFetch,
      Run.opCommit, Run.opPoll, Run.opControl, Run.opAddress,
      Run.successorAddress, Run.opReadKind, Run.opIdu, Run.finishSuccessor,
      Run.commitRegisters, Run.commitIme, Run.setTarget,
      Functional.fetchImmediate, Functional.read, Functional.immediate8,
      InstructionShape.immediateBytes, Functional.executeShape,
      Functional.writeTarget, Functional.matureIme, Functional.withRegisters,
      increment_twice, FlatAdapter.event]
  all_goals cases before.scheduledImeEnable <;>
    simp [Retirement.Snapshot.atBoundary, Retirement.Snapshot.ofFunctional]
  all_goals try { cases ‹Reg8› <;> simp [Registers.set8] }

private def immediateLowCore (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (low : Byte) : CoreState :=
  { baseFetchedCore state opcode shape with
    registers := { state.registers with pc := Word.ofNat (state.registers.pc.toNat + 2) }
    remaining := [.immediateHigh, .successorFetch]
    latches := { low, conditionTaken := true } }

private def immediateLowState (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (low : Byte) : FlatCoreState :=
  { core := immediateLowCore state opcode shape low
    memory := state.memory
    trace := [.read .opcode state.registers.pc opcode,
      .read .immediate (Word.ofNat (state.registers.pc.toNat + 1)) low] }

private def immediateHighCore (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (low high : Byte) : CoreState :=
  { immediateLowCore state opcode shape low with
    registers := { state.registers with pc := Word.ofNat (state.registers.pc.toNat + 3) }
    remaining := [.successorFetch]
    latches := { low, high, conditionTaken := true } }

private def immediateHighState (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (low high : Byte) : FlatCoreState :=
  { core := immediateHighCore state opcode shape low high
    memory := state.memory
    trace := [.read .opcode state.registers.pc opcode,
      .read .immediate (Word.ofNat (state.registers.pc.toNat + 1)) low,
      .read .immediate (Word.ofNat (state.registers.pc.toNat + 2)) high] }

private theorem increment_thrice : ∀ pc : Word,
    Word.ofNat ((Word.ofNat (pc.toNat + 2)).toNat + 1) = Word.ofNat (pc.toNat + 3) := by
  native_decide

private theorem step_ld16_low (before : FunctionalState) (opcode : Byte) (target : Reg16) :
    FlatAdapter.step (baseFetched before opcode (.ld16Imm target)) =
      immediateLowState before opcode (.ld16Imm target)
        (before.memory.read (Word.ofNat (before.registers.pc.toNat + 1))) := by
  simp [FlatAdapter.step, baseFetched, baseFetchedCore, immediateLowState,
    immediateLowCore, Pipeline.taken, Cycle.physicalSchedule,
    Cycle.logicalSchedule, CoreState.currentOp?, Run.stepMachineCycle,
    Run.intent, Run.opFetch, Run.opCommit, Run.opPoll, Run.opControl,
    Run.opAddress, Run.opReadKind, Run.opIdu, Run.processNonFetch,
    increment_twice, FlatAdapter.event]

private theorem step_ld16_high (before : FunctionalState) (opcode : Byte) (target : Reg16) :
    let low := before.memory.read (Word.ofNat (before.registers.pc.toNat + 1))
    FlatAdapter.step (immediateLowState before opcode (.ld16Imm target) low) =
      immediateHighState before opcode (.ld16Imm target) low
        (before.memory.read (Word.ofNat (before.registers.pc.toNat + 2))) := by
  simp [FlatAdapter.step, immediateLowState, immediateLowCore,
    immediateHighState, immediateHighCore, baseFetchedCore, Pipeline.taken,
    Cycle.physicalSchedule, Cycle.logicalSchedule, CoreState.currentOp?,
    Run.stepMachineCycle, Run.intent, Run.opFetch, Run.opCommit, Run.opPoll,
    Run.opControl, Run.opAddress, Run.opReadKind, Run.opIdu,
    Run.processNonFetch, increment_thrice, FlatAdapter.event]

set_option maxHeartbeats 3000000 in
/-- Universal refinement for all four `LD rr,nn` entries. -/
theorem ld16_immediate_refines (before : FunctionalState) (opcode : Byte)
    (target : Reg16) (running : before.mode = .running)
    (noHaltBug : before.haltBug = false)
    (atPC : before.memory.read before.registers.pc = opcode)
    (decoded : Decode.base opcode = .legal (.ld16Imm target)) :
    let logical := Functional.step before 0
    let physical := FlatAdapter.run 4 (physicalInitial before) noInterrupts
    Retirement.Snapshot.atBoundary physical.core =
        Retirement.Snapshot.ofFunctional logical.state ∧
      physical.memory = logical.state.memory ∧
      physical.trace.dropLast = logical.trace := by
  rw [show FlatAdapter.run 4 (physicalInitial before) noInterrupts =
      FlatAdapter.step (FlatAdapter.step (FlatAdapter.step
        (FlatAdapter.step (physicalInitial before)))) by rfl]
  rw [fetch_legal before opcode (.ld16Imm target) atPC noHaltBug decoded]
  rw [step_ld16_low before opcode target]
  rw [step_ld16_high before opcode target]
  simp [Functional.step, running, atPC, decoded, noHaltBug,
    immediateHighState, immediateHighCore, immediateLowCore, baseFetchedCore,
    Pipeline.taken, Cycle.physicalSchedule, Cycle.logicalSchedule,
    FlatAdapter.step, CoreState.currentOp?, Run.stepMachineCycle, Run.intent,
    Run.opFetch, Run.opCommit, Run.opPoll, Run.opControl, Run.opAddress,
    Run.successorAddress, Run.opReadKind, Run.opIdu, Run.finishSuccessor,
    Run.commitRegisters, Run.commitIme, Functional.fetchImmediate,
    Functional.read, Functional.immediate16, InstructionShape.immediateBytes,
    Functional.executeShape, Functional.matureIme, Functional.withRegisters,
    CoreState.wz, increment_twice, increment_thrice, FlatAdapter.event]
  all_goals cases before.scheduledImeEnable <;>
    simp [Retirement.Snapshot.atBoundary, Retirement.Snapshot.ofFunctional]
  all_goals cases target <;> simp [Registers.set16, Registers.setBC,
    Registers.setDE, Registers.setHL]

/-- One-internal-cycle 16-bit base families. -/
inductive Internal16Shape : InstructionShape → Prop where
  | inc (target : Reg16) : Internal16Shape (.inc16 target)
  | dec (target : Reg16) : Internal16Shape (.dec16 target)
  | addHL (source : Reg16) : Internal16Shape (.addHL source)
  | ldSPHL : Internal16Shape .ldSPHL

private def internalReadyCore (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) : CoreState :=
  { baseFetchedCore state opcode shape with remaining := [.successorFetch] }

private def internalReady (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) : FlatCoreState :=
  let core := baseFetchedCore state opcode shape
  { core := internalReadyCore state opcode shape
    memory := state.memory
    trace := [.read .opcode state.registers.pc opcode,
      .idle (Run.internalAddress core)] }

private theorem step_internal16 (before : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (family : Internal16Shape shape) :
    FlatAdapter.step (baseFetched before opcode shape) =
      internalReady before opcode shape := by
  cases family <;>
    simp [FlatAdapter.step, baseFetched, baseFetchedCore, internalReady,
      internalReadyCore, Pipeline.taken, Cycle.physicalSchedule,
      Cycle.logicalSchedule, CoreState.currentOp?, Run.stepMachineCycle,
      Run.intent, Run.opFetch, Run.opCommit, Run.opPoll, Run.opControl,
      Run.opAddress, Run.opReadKind, Run.opIdu, Run.processNonFetch,
      Run.internalAddress, FlatAdapter.event]

set_option maxHeartbeats 3000000 in
/-- Universal refinement for INC/DEC rr, ADD HL,rr, and LD SP,HL. -/
theorem internal16_refines (before : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (family : Internal16Shape shape)
    (running : before.mode = .running)
    (noHaltBug : before.haltBug = false)
    (atPC : before.memory.read before.registers.pc = opcode)
    (decoded : Decode.base opcode = .legal shape) :
    let logical := Functional.step before 0
    let physical := FlatAdapter.run 3 (physicalInitial before) noInterrupts
    Retirement.Snapshot.atBoundary physical.core =
        Retirement.Snapshot.ofFunctional logical.state ∧
      physical.memory = logical.state.memory ∧
      physical.trace.dropLast = logical.trace := by
  rw [show FlatAdapter.run 3 (physicalInitial before) noInterrupts =
      FlatAdapter.step (FlatAdapter.step (FlatAdapter.step (physicalInitial before))) by rfl]
  rw [fetch_legal before opcode shape atPC noHaltBug decoded]
  rw [step_internal16 before opcode shape family]
  cases family <;>
    simp [Functional.step, running, atPC, decoded, noHaltBug, internalReady,
      internalReadyCore, baseFetchedCore, Pipeline.taken,
      Cycle.physicalSchedule, Cycle.logicalSchedule, FlatAdapter.step,
      CoreState.currentOp?, Run.stepMachineCycle, Run.intent, Run.opFetch,
      Run.opCommit, Run.opPoll, Run.opControl, Run.opAddress,
      Run.successorAddress, Run.opReadKind, Run.opIdu, Run.internalAddress,
      Run.finishSuccessor, Run.commitRegisters, Run.commitIme,
      Functional.fetchImmediate, InstructionShape.immediateBytes,
      Functional.executeShape, Functional.idle, Functional.matureIme,
      Functional.withRegisters, Registers.get16, Registers.set16,
      Registers.bc, Registers.de, Registers.hl, FlatAdapter.event]
  all_goals cases before.scheduledImeEnable <;>
    simp [Retirement.Snapshot.atBoundary, Retirement.Snapshot.ofFunctional]
  all_goals try { cases ‹Reg16› <;> simp [Registers.setBC, Registers.setDE,
    Registers.setHL] }

/-- Base families that read `(HL)` and commit into registers or the ALU. -/
inductive BaseHLReadShape : InstructionShape → Prop where
  | ld8 (target : Reg8) : BaseHLReadShape (.ld8 (.reg target) .atHL)
  | alu (operation : AluOp) : BaseHLReadShape (.aluA operation .atHL)

private def baseHLReadCore (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (value : Byte) : CoreState :=
  { baseFetchedCore state opcode shape with
    remaining := [.successorFetch]
    latches := { data := value, conditionTaken := true } }

private def baseHLRead (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (value : Byte) : FlatCoreState :=
  { core := baseHLReadCore state opcode shape value
    memory := state.memory
    trace := [.read .opcode state.registers.pc opcode,
      .read .data state.registers.hl value] }

private theorem step_base_hl_read (before : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (family : BaseHLReadShape shape) :
    FlatAdapter.step (baseFetched before opcode shape) =
      baseHLRead before opcode shape (before.memory.read before.registers.hl) := by
  cases family <;>
    simp [FlatAdapter.step, baseFetched, baseFetchedCore, baseHLRead,
      baseHLReadCore, Pipeline.taken, Cycle.physicalSchedule,
      Cycle.logicalSchedule, Cycle.targetIsMemory, CoreState.currentOp?,
      Run.stepMachineCycle, Run.intent, Run.opFetch, Run.opCommit, Run.opPoll,
      Run.opControl, Run.opAddress, Run.opReadKind, Run.opIdu,
      Run.processNonFetch, Run.updatePointer, Registers.hl, FlatAdapter.event]

set_option maxHeartbeats 3000000 in
/-- Universal refinement for seven `LD r,(HL)` and eight `ALU A,(HL)` entries. -/
theorem base_hl_read_refines (before : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (family : BaseHLReadShape shape)
    (running : before.mode = .running)
    (noHaltBug : before.haltBug = false)
    (atPC : before.memory.read before.registers.pc = opcode)
    (decoded : Decode.base opcode = .legal shape) :
    let logical := Functional.step before 0
    let physical := FlatAdapter.run 3 (physicalInitial before) noInterrupts
    Retirement.Snapshot.atBoundary physical.core =
        Retirement.Snapshot.ofFunctional logical.state ∧
      physical.memory = logical.state.memory ∧
      physical.trace.dropLast = logical.trace := by
  rw [show FlatAdapter.run 3 (physicalInitial before) noInterrupts =
      FlatAdapter.step (FlatAdapter.step (FlatAdapter.step (physicalInitial before))) by rfl]
  rw [fetch_legal before opcode shape atPC noHaltBug decoded]
  rw [step_base_hl_read before opcode shape family]
  cases family <;>
    simp [Functional.step, running, atPC, decoded, noHaltBug, baseHLRead,
      baseHLReadCore, baseFetchedCore, Pipeline.taken,
      Cycle.physicalSchedule, Cycle.logicalSchedule, Cycle.targetIsMemory,
      FlatAdapter.step, CoreState.currentOp?, Run.stepMachineCycle, Run.intent,
      Run.opFetch, Run.opCommit, Run.opPoll, Run.opControl, Run.opAddress,
      Run.successorAddress, Run.opReadKind, Run.opIdu, Run.finishSuccessor,
      Run.commitRegisters, Run.commitIme, Run.targetValue, Run.setTarget,
      Functional.fetchImmediate, InstructionShape.immediateBytes,
      Functional.executeShape, Functional.readTarget, Functional.read,
      Functional.writeTarget, Functional.matureIme, Functional.withRegisters,
      Registers.hl, FlatAdapter.event]
  all_goals cases before.scheduledImeEnable <;>
    simp [Retirement.Snapshot.atBoundary, Retirement.Snapshot.ofFunctional]
  all_goals try { cases ‹Reg8› <;> simp [Registers.set8] }

private def baseHLWriteCore (state : FunctionalState) (opcode : Byte)
    (source : Reg8) : CoreState :=
  { baseFetchedCore state opcode (.ld8 .atHL (.reg source)) with
    remaining := [.successorFetch] }

private def baseHLWritten (state : FunctionalState) (opcode : Byte)
    (source : Reg8) : FlatCoreState :=
  let value := state.registers.get8 source
  { core := baseHLWriteCore state opcode source
    memory := state.memory.write state.registers.hl value
    trace := [.read .opcode state.registers.pc opcode,
      .write state.registers.hl value] }

private theorem step_base_hl_write (before : FunctionalState) (opcode : Byte)
    (source : Reg8) :
    FlatAdapter.step (baseFetched before opcode (.ld8 .atHL (.reg source))) =
      baseHLWritten before opcode source := by
  cases source <;>
    simp [FlatAdapter.step, baseFetched, baseFetchedCore, baseHLWritten,
      baseHLWriteCore, Pipeline.taken, Cycle.physicalSchedule,
      Cycle.logicalSchedule, Cycle.targetIsMemory, CoreState.currentOp?,
      Run.stepMachineCycle, Run.intent, Run.opFetch, Run.opCommit, Run.opPoll,
      Run.opControl, Run.opAddress, Run.opReadKind, Run.opIdu,
      Run.processNonFetch, Run.writeValue, Run.targetValue, Registers.get8,
      Registers.hl, FlatAdapter.event]

set_option maxHeartbeats 3000000 in
/-- Universal refinement for all seven `LD (HL),r` entries. -/
theorem base_hl_write_refines (before : FunctionalState) (opcode : Byte)
    (source : Reg8) (running : before.mode = .running)
    (noHaltBug : before.haltBug = false)
    (atPC : before.memory.read before.registers.pc = opcode)
    (decoded : Decode.base opcode = .legal (.ld8 .atHL (.reg source))) :
    let logical := Functional.step before 0
    let physical := FlatAdapter.run 3 (physicalInitial before) noInterrupts
    Retirement.Snapshot.atBoundary physical.core =
        Retirement.Snapshot.ofFunctional logical.state ∧
      physical.memory = logical.state.memory ∧
      physical.trace.dropLast = logical.trace := by
  rw [show FlatAdapter.run 3 (physicalInitial before) noInterrupts =
      FlatAdapter.step (FlatAdapter.step (FlatAdapter.step (physicalInitial before))) by rfl]
  rw [fetch_legal before opcode (.ld8 .atHL (.reg source)) atPC noHaltBug decoded]
  rw [step_base_hl_write before opcode source]
  cases source <;>
    simp [Functional.step, running, atPC, decoded, noHaltBug, baseHLWritten,
      baseHLWriteCore, baseFetchedCore, Pipeline.taken,
      Cycle.physicalSchedule, Cycle.logicalSchedule, Cycle.targetIsMemory,
      FlatAdapter.step, CoreState.currentOp?, Run.stepMachineCycle, Run.intent,
      Run.opFetch, Run.opCommit, Run.opPoll, Run.opControl, Run.opAddress,
      Run.successorAddress, Run.opReadKind, Run.opIdu, Run.finishSuccessor,
      Run.commitRegisters, Run.commitIme, Run.setTarget,
      Functional.fetchImmediate, InstructionShape.immediateBytes,
      Functional.executeShape, Functional.readTarget, Functional.write,
      Functional.writeTarget, Functional.matureIme, Registers.get8,
      Registers.hl, FlatAdapter.event]
  all_goals cases before.scheduledImeEnable <;>
    simp [Retirement.Snapshot.atBoundary, Retirement.Snapshot.ofFunctional]

/-- The two base `(HL)` read-modify-write arithmetic families. -/
inductive BaseHLModifyShape : InstructionShape → Prop where
  | inc : BaseHLModifyShape (.inc8 .atHL)
  | dec : BaseHLModifyShape (.dec8 .atHL)

private def baseHLModifyValue (state : FunctionalState) (shape : InstructionShape)
    (value : Byte) : Byte :=
  match shape with
  | .inc8 .atHL => (Alu.inc8 value state.registers.flags).value
  | .dec8 .atHL => (Alu.dec8 value state.registers.flags).value
  | _ => value

private def baseHLModifyReadCore (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (value : Byte) : CoreState :=
  { baseFetchedCore state opcode shape with
    remaining := [.writeHL, .successorFetch]
    latches := { data := value, conditionTaken := true } }

private def baseHLModifyRead (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (value : Byte) : FlatCoreState :=
  { core := baseHLModifyReadCore state opcode shape value
    memory := state.memory
    trace := [.read .opcode state.registers.pc opcode,
      .read .data state.registers.hl value] }

private def baseHLModifyWriteCore (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (value : Byte) : CoreState :=
  { baseHLModifyReadCore state opcode shape value with remaining := [.successorFetch] }

private def baseHLModifyWritten (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (value : Byte) : FlatCoreState :=
  let written := baseHLModifyValue state shape value
  { core := baseHLModifyWriteCore state opcode shape value
    memory := state.memory.write state.registers.hl written
    trace := [.read .opcode state.registers.pc opcode,
      .read .data state.registers.hl value,
      .write state.registers.hl written] }

private theorem step_base_hl_modify_read (before : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (family : BaseHLModifyShape shape) :
    FlatAdapter.step (baseFetched before opcode shape) =
      baseHLModifyRead before opcode shape (before.memory.read before.registers.hl) := by
  cases family <;>
    simp [FlatAdapter.step, baseFetched, baseFetchedCore, baseHLModifyRead,
      baseHLModifyReadCore, Pipeline.taken, Cycle.physicalSchedule,
      Cycle.logicalSchedule, Cycle.targetIsMemory, CoreState.currentOp?,
      Run.stepMachineCycle, Run.intent, Run.opFetch, Run.opCommit, Run.opPoll,
      Run.opControl, Run.opAddress, Run.opReadKind, Run.opIdu,
      Run.processNonFetch, Run.updatePointer, Registers.hl, FlatAdapter.event]

private theorem step_base_hl_modify_write (before : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (family : BaseHLModifyShape shape) :
    let value := before.memory.read before.registers.hl
    FlatAdapter.step (baseHLModifyRead before opcode shape value) =
      baseHLModifyWritten before opcode shape value := by
  cases family <;>
    simp [FlatAdapter.step, baseHLModifyRead, baseHLModifyReadCore,
      baseHLModifyWritten, baseHLModifyWriteCore, baseHLModifyValue,
      baseFetchedCore, Pipeline.taken, Cycle.physicalSchedule,
      Cycle.logicalSchedule, Cycle.targetIsMemory, CoreState.currentOp?,
      Run.stepMachineCycle, Run.intent, Run.opFetch, Run.opCommit, Run.opPoll,
      Run.opControl, Run.opAddress, Run.opReadKind, Run.opIdu,
      Run.processNonFetch, Run.writeValue, Registers.hl, FlatAdapter.event]

set_option maxHeartbeats 3000000 in
/-- Universal refinement for `INC (HL)` and `DEC (HL)`. -/
theorem base_hl_modify_refines (before : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (family : BaseHLModifyShape shape)
    (running : before.mode = .running)
    (noHaltBug : before.haltBug = false)
    (atPC : before.memory.read before.registers.pc = opcode)
    (decoded : Decode.base opcode = .legal shape) :
    let logical := Functional.step before 0
    let physical := FlatAdapter.run 4 (physicalInitial before) noInterrupts
    Retirement.Snapshot.atBoundary physical.core =
        Retirement.Snapshot.ofFunctional logical.state ∧
      physical.memory = logical.state.memory ∧
      physical.trace.dropLast = logical.trace := by
  rw [show FlatAdapter.run 4 (physicalInitial before) noInterrupts =
      FlatAdapter.step (FlatAdapter.step (FlatAdapter.step
        (FlatAdapter.step (physicalInitial before)))) by rfl]
  rw [fetch_legal before opcode shape atPC noHaltBug decoded]
  rw [step_base_hl_modify_read before opcode shape family]
  rw [step_base_hl_modify_write before opcode shape family]
  cases family <;>
    simp [Functional.step, running, atPC, decoded, noHaltBug,
      baseHLModifyWritten, baseHLModifyWriteCore, baseHLModifyReadCore,
      baseHLModifyValue, baseFetchedCore, Pipeline.taken,
      Cycle.physicalSchedule, Cycle.logicalSchedule, Cycle.targetIsMemory,
      FlatAdapter.step, CoreState.currentOp?, Run.stepMachineCycle, Run.intent,
      Run.opFetch, Run.opCommit, Run.opPoll, Run.opControl, Run.opAddress,
      Run.successorAddress, Run.opReadKind, Run.opIdu, Run.finishSuccessor,
      Run.commitRegisters, Run.commitIme, Run.targetValue, Run.setTarget,
      Functional.fetchImmediate, InstructionShape.immediateBytes,
      Functional.executeShape, Functional.readTarget, Functional.read,
      Functional.write, Functional.writeTarget, Functional.matureIme,
      Functional.withRegisters, Functional.setFlags, Registers.hl,
      FlatAdapter.event]
  all_goals cases before.scheduledImeEnable <;>
    simp [Retirement.Snapshot.atBoundary, Retirement.Snapshot.ofFunctional]

private def hlImmediateCore (state : FunctionalState) (opcode value : Byte) : CoreState :=
  { baseFetchedCore state opcode (.ld8Imm .atHL) with
    registers := { state.registers with pc := Word.ofNat (state.registers.pc.toNat + 2) }
    remaining := [.writeHL, .successorFetch]
    latches := { low := value, conditionTaken := true } }

private def hlImmediateState (state : FunctionalState) (opcode value : Byte) : FlatCoreState :=
  { core := hlImmediateCore state opcode value
    memory := state.memory
    trace := [.read .opcode state.registers.pc opcode,
      .read .immediate (Word.ofNat (state.registers.pc.toNat + 1)) value] }

private def hlImmediateWrittenCore (state : FunctionalState) (opcode value : Byte) : CoreState :=
  { hlImmediateCore state opcode value with remaining := [.successorFetch] }

private def hlImmediateWritten (state : FunctionalState) (opcode value : Byte) : FlatCoreState :=
  { core := hlImmediateWrittenCore state opcode value
    memory := state.memory.write state.registers.hl value
    trace := [.read .opcode state.registers.pc opcode,
      .read .immediate (Word.ofNat (state.registers.pc.toNat + 1)) value,
      .write state.registers.hl value] }

private theorem step_hl_immediate (before : FunctionalState) (opcode : Byte) :
    FlatAdapter.step (baseFetched before opcode (.ld8Imm .atHL)) =
      hlImmediateState before opcode
        (before.memory.read (Word.ofNat (before.registers.pc.toNat + 1))) := by
  simp [FlatAdapter.step, baseFetched, baseFetchedCore, hlImmediateState,
    hlImmediateCore, Pipeline.taken, Cycle.physicalSchedule,
    Cycle.logicalSchedule, Cycle.targetIsMemory, CoreState.currentOp?,
    Run.stepMachineCycle, Run.intent, Run.opFetch, Run.opCommit, Run.opPoll,
    Run.opControl, Run.opAddress, Run.opReadKind, Run.opIdu,
    Run.processNonFetch, increment_twice, FlatAdapter.event]

private theorem step_hl_immediate_write (before : FunctionalState) (opcode : Byte) :
    let value := before.memory.read (Word.ofNat (before.registers.pc.toNat + 1))
    FlatAdapter.step (hlImmediateState before opcode value) =
      hlImmediateWritten before opcode value := by
  simp [FlatAdapter.step, hlImmediateState, hlImmediateCore,
    hlImmediateWritten, hlImmediateWrittenCore, baseFetchedCore,
    Pipeline.taken, Cycle.physicalSchedule, Cycle.logicalSchedule,
    Cycle.targetIsMemory, CoreState.currentOp?, Run.stepMachineCycle,
    Run.intent, Run.opFetch, Run.opCommit, Run.opPoll, Run.opControl,
    Run.opAddress, Run.opReadKind, Run.opIdu, Run.processNonFetch,
    Run.writeValue, Registers.hl, FlatAdapter.event]

set_option maxHeartbeats 3000000 in
/-- Universal refinement for `LD (HL),n`. -/
theorem hl_immediate_refines (before : FunctionalState) (opcode : Byte)
    (running : before.mode = .running) (noHaltBug : before.haltBug = false)
    (atPC : before.memory.read before.registers.pc = opcode)
    (decoded : Decode.base opcode = .legal (.ld8Imm .atHL)) :
    let logical := Functional.step before 0
    let physical := FlatAdapter.run 4 (physicalInitial before) noInterrupts
    Retirement.Snapshot.atBoundary physical.core =
        Retirement.Snapshot.ofFunctional logical.state ∧
      physical.memory = logical.state.memory ∧
      physical.trace.dropLast = logical.trace := by
  rw [show FlatAdapter.run 4 (physicalInitial before) noInterrupts =
      FlatAdapter.step (FlatAdapter.step (FlatAdapter.step
        (FlatAdapter.step (physicalInitial before)))) by rfl]
  rw [fetch_legal before opcode (.ld8Imm .atHL) atPC noHaltBug decoded]
  rw [step_hl_immediate before opcode]
  rw [step_hl_immediate_write before opcode]
  simp [Functional.step, running, atPC, decoded, noHaltBug,
    hlImmediateWritten, hlImmediateWrittenCore, hlImmediateCore,
    baseFetchedCore, Pipeline.taken, Cycle.physicalSchedule,
    Cycle.logicalSchedule, Cycle.targetIsMemory, FlatAdapter.step,
    CoreState.currentOp?, Run.stepMachineCycle, Run.intent, Run.opFetch,
    Run.opCommit, Run.opPoll, Run.opControl, Run.opAddress,
    Run.successorAddress, Run.opReadKind, Run.opIdu, Run.finishSuccessor,
    Run.commitRegisters, Run.commitIme, Run.setTarget,
    Functional.fetchImmediate, Functional.read, Functional.immediate8,
    InstructionShape.immediateBytes, Functional.executeShape,
    Functional.write, Functional.writeTarget, Functional.withRegisters,
    Functional.matureIme,
    Registers.hl, increment_twice, FlatAdapter.event]
  all_goals cases before.scheduledImeEnable <;>
    simp [Retirement.Snapshot.atBoundary, Retirement.Snapshot.ofFunctional]

private def mem16WriteCore (state : FunctionalState) (opcode : Byte)
    (destination : Mem16) : CoreState :=
  let core := baseFetchedCore state opcode (.ldMem16A destination)
  { Run.updatePointer core with remaining := [.successorFetch] }

private def mem16Written (state : FunctionalState) (opcode : Byte)
    (destination : Mem16) : FlatCoreState :=
  let address := Run.memAddress state.registers destination
  { core := mem16WriteCore state opcode destination
    memory := state.memory.write address state.registers.a
    trace := [.read .opcode state.registers.pc opcode,
      .write address state.registers.a] }

private theorem step_mem16_write (before : FunctionalState) (opcode : Byte)
    (destination : Mem16) :
    FlatAdapter.step (baseFetched before opcode (.ldMem16A destination)) =
      mem16Written before opcode destination := by
  cases destination <;>
    simp [FlatAdapter.step, baseFetched, baseFetchedCore, mem16Written,
      mem16WriteCore, Pipeline.taken, Cycle.physicalSchedule,
      Cycle.logicalSchedule, CoreState.currentOp?, Run.stepMachineCycle,
      Run.intent, Run.opFetch, Run.opCommit, Run.opPoll, Run.opControl,
      Run.opAddress, Run.readAddress, Run.memAddress, Run.opReadKind,
      Run.opIdu, Run.processNonFetch, Run.updatePointer, Run.writeValue,
      Registers.bc, Registers.de, Registers.hl, Registers.setHL,
      FlatAdapter.event]

set_option maxHeartbeats 3000000 in
/-- Universal refinement for `LD (BC/DE/HL+/HL-),A`. -/
theorem mem16_write_refines (before : FunctionalState) (opcode : Byte)
    (destination : Mem16) (running : before.mode = .running)
    (noHaltBug : before.haltBug = false)
    (atPC : before.memory.read before.registers.pc = opcode)
    (decoded : Decode.base opcode = .legal (.ldMem16A destination)) :
    let logical := Functional.step before 0
    let physical := FlatAdapter.run 3 (physicalInitial before) noInterrupts
    Retirement.Snapshot.atBoundary physical.core =
        Retirement.Snapshot.ofFunctional logical.state ∧
      physical.memory = logical.state.memory ∧
      physical.trace.dropLast = logical.trace := by
  rw [show FlatAdapter.run 3 (physicalInitial before) noInterrupts =
      FlatAdapter.step (FlatAdapter.step (FlatAdapter.step (physicalInitial before))) by rfl]
  rw [fetch_legal before opcode (.ldMem16A destination) atPC noHaltBug decoded]
  rw [step_mem16_write before opcode destination]
  cases destination <;>
    simp [Functional.step, running, atPC, decoded, noHaltBug, mem16Written,
      mem16WriteCore, baseFetchedCore, Pipeline.taken,
      Cycle.physicalSchedule, Cycle.logicalSchedule, FlatAdapter.step,
      CoreState.currentOp?, Run.stepMachineCycle, Run.intent, Run.opFetch,
      Run.opCommit, Run.opPoll, Run.opControl, Run.opAddress,
      Run.successorAddress, Run.memAddress, Run.opReadKind,
      Run.opIdu, Run.finishSuccessor, Run.commitRegisters, Run.commitIme,
      Run.updatePointer, Functional.fetchImmediate,
      InstructionShape.immediateBytes, Functional.executeShape,
      Functional.writeMem16, Functional.memoryAddress,
      Functional.updateMemoryPointer, Functional.write,
      Functional.withRegisters, Functional.matureIme, Registers.bc,
      Registers.de, Registers.hl,
      Registers.setHL, FlatAdapter.event]
  all_goals cases before.scheduledImeEnable <;>
    simp [Retirement.Snapshot.atBoundary, Retirement.Snapshot.ofFunctional]

private def mem16ReadCore (state : FunctionalState) (opcode : Byte)
    (source : Mem16) (value : Byte) : CoreState :=
  let core := baseFetchedCore state opcode (.ldAFromMem16 source)
  { Run.updatePointer { core with latches := { data := value } } with
    remaining := [.successorFetch] }

private def mem16Read (state : FunctionalState) (opcode : Byte)
    (source : Mem16) (value : Byte) : FlatCoreState :=
  let address := Run.memAddress state.registers source
  { core := mem16ReadCore state opcode source value
    memory := state.memory
    trace := [.read .opcode state.registers.pc opcode,
      .read .data address value] }

private theorem step_mem16_read (before : FunctionalState) (opcode : Byte)
    (source : Mem16) :
    FlatAdapter.step (baseFetched before opcode (.ldAFromMem16 source)) =
      mem16Read before opcode source
        (before.memory.read (Run.memAddress before.registers source)) := by
  cases source <;>
    simp [FlatAdapter.step, baseFetched, baseFetchedCore, mem16Read,
      mem16ReadCore, Pipeline.taken, Cycle.physicalSchedule,
      Cycle.logicalSchedule, CoreState.currentOp?, Run.stepMachineCycle,
      Run.intent, Run.opFetch, Run.opCommit, Run.opPoll, Run.opControl,
      Run.opAddress, Run.readAddress, Run.memAddress, Run.opReadKind,
      Run.opIdu, Run.processNonFetch, Run.updatePointer, Registers.bc,
      Registers.de, Registers.hl, Registers.setHL, FlatAdapter.event]

set_option maxHeartbeats 3000000 in
/-- Universal refinement for `LD A,(BC/DE/HL+/HL-)`. -/
theorem mem16_read_refines (before : FunctionalState) (opcode : Byte)
    (source : Mem16) (running : before.mode = .running)
    (noHaltBug : before.haltBug = false)
    (atPC : before.memory.read before.registers.pc = opcode)
    (decoded : Decode.base opcode = .legal (.ldAFromMem16 source)) :
    let logical := Functional.step before 0
    let physical := FlatAdapter.run 3 (physicalInitial before) noInterrupts
    Retirement.Snapshot.atBoundary physical.core =
        Retirement.Snapshot.ofFunctional logical.state ∧
      physical.memory = logical.state.memory ∧
      physical.trace.dropLast = logical.trace := by
  rw [show FlatAdapter.run 3 (physicalInitial before) noInterrupts =
      FlatAdapter.step (FlatAdapter.step (FlatAdapter.step (physicalInitial before))) by rfl]
  rw [fetch_legal before opcode (.ldAFromMem16 source) atPC noHaltBug decoded]
  rw [step_mem16_read before opcode source]
  cases source <;>
    simp [Functional.step, running, atPC, decoded, noHaltBug, mem16Read,
      mem16ReadCore, baseFetchedCore, Pipeline.taken,
      Cycle.physicalSchedule, Cycle.logicalSchedule, FlatAdapter.step,
      CoreState.currentOp?, Run.stepMachineCycle, Run.intent, Run.opFetch,
      Run.opCommit, Run.opPoll, Run.opControl, Run.opAddress,
      Run.successorAddress, Run.memAddress, Run.opReadKind,
      Run.opIdu, Run.finishSuccessor, Run.commitRegisters, Run.commitIme,
      Run.updatePointer, Functional.fetchImmediate,
      InstructionShape.immediateBytes, Functional.executeShape,
      Functional.readMem16, Functional.memoryAddress,
      Functional.updateMemoryPointer, Functional.read,
      Functional.withRegisters, Functional.matureIme, Registers.bc,
      Registers.de, Registers.hl,
      Registers.setHL, FlatAdapter.event]
  all_goals cases before.scheduledImeEnable <;>
    simp [Retirement.Snapshot.atBoundary, Retirement.Snapshot.ofFunctional]

private def ldhCAddress (state : FunctionalState) : Word :=
  Word.ofNat (0xFF00 + state.registers.c.toNat)

private def ldhCWriteCore (state : FunctionalState) (opcode : Byte) : CoreState :=
  { baseFetchedCore state opcode .ldhCA with remaining := [.successorFetch] }

private def ldhCWritten (state : FunctionalState) (opcode : Byte) : FlatCoreState :=
  { core := ldhCWriteCore state opcode
    memory := state.memory.write (ldhCAddress state) state.registers.a
    trace := [.read .opcode state.registers.pc opcode,
      .write (ldhCAddress state) state.registers.a] }

private theorem step_ldh_c_write (before : FunctionalState) (opcode : Byte) :
    FlatAdapter.step (baseFetched before opcode .ldhCA) = ldhCWritten before opcode := by
  simp [FlatAdapter.step, baseFetched, baseFetchedCore, ldhCWritten,
    ldhCWriteCore, ldhCAddress, Pipeline.taken, Cycle.physicalSchedule,
    Cycle.logicalSchedule, CoreState.currentOp?, Run.stepMachineCycle,
    Run.intent, Run.opFetch, Run.opCommit, Run.opPoll, Run.opControl,
    Run.opAddress, Run.readAddress, Run.opReadKind, Run.opIdu,
    Run.processNonFetch, Run.updatePointer, Run.writeValue, FlatAdapter.event]

set_option maxHeartbeats 3000000 in
/-- Universal refinement for `LDH (C),A`. -/
theorem ldh_c_write_refines (before : FunctionalState) (opcode : Byte)
    (running : before.mode = .running) (noHaltBug : before.haltBug = false)
    (atPC : before.memory.read before.registers.pc = opcode)
    (decoded : Decode.base opcode = .legal .ldhCA) :
    let logical := Functional.step before 0
    let physical := FlatAdapter.run 3 (physicalInitial before) noInterrupts
    Retirement.Snapshot.atBoundary physical.core =
        Retirement.Snapshot.ofFunctional logical.state ∧
      physical.memory = logical.state.memory ∧
      physical.trace.dropLast = logical.trace := by
  rw [show FlatAdapter.run 3 (physicalInitial before) noInterrupts =
      FlatAdapter.step (FlatAdapter.step (FlatAdapter.step (physicalInitial before))) by rfl]
  rw [fetch_legal before opcode .ldhCA atPC noHaltBug decoded]
  rw [step_ldh_c_write before opcode]
  simp [Functional.step, running, atPC, decoded, noHaltBug, ldhCWritten,
    ldhCWriteCore, ldhCAddress, baseFetchedCore, Pipeline.taken,
    Cycle.physicalSchedule, Cycle.logicalSchedule, FlatAdapter.step,
    CoreState.currentOp?, Run.stepMachineCycle, Run.intent, Run.opFetch,
    Run.opCommit, Run.opPoll, Run.opControl, Run.opAddress,
    Run.successorAddress, Run.opReadKind, Run.opIdu,
    Run.finishSuccessor, Run.commitRegisters, Run.commitIme,
    Functional.fetchImmediate, InstructionShape.immediateBytes,
    Functional.executeShape, Functional.write, Functional.matureIme,
    FlatAdapter.event]
  all_goals cases before.scheduledImeEnable <;>
    simp [Retirement.Snapshot.atBoundary, Retirement.Snapshot.ofFunctional]

private def ldhCReadCore (state : FunctionalState) (opcode value : Byte) : CoreState :=
  { baseFetchedCore state opcode .ldhAC with
    remaining := [.successorFetch]
    latches := { data := value } }

private def ldhCRead (state : FunctionalState) (opcode value : Byte) : FlatCoreState :=
  { core := ldhCReadCore state opcode value
    memory := state.memory
    trace := [.read .opcode state.registers.pc opcode,
      .read .data (ldhCAddress state) value] }

private theorem step_ldh_c_read (before : FunctionalState) (opcode : Byte) :
    FlatAdapter.step (baseFetched before opcode .ldhAC) =
      ldhCRead before opcode (before.memory.read (ldhCAddress before)) := by
  simp [FlatAdapter.step, baseFetched, baseFetchedCore, ldhCRead,
    ldhCReadCore, ldhCAddress, Pipeline.taken, Cycle.physicalSchedule,
    Cycle.logicalSchedule, CoreState.currentOp?, Run.stepMachineCycle,
    Run.intent, Run.opFetch, Run.opCommit, Run.opPoll, Run.opControl,
    Run.opAddress, Run.readAddress, Run.opReadKind, Run.opIdu,
    Run.processNonFetch, Run.updatePointer, FlatAdapter.event]

set_option maxHeartbeats 3000000 in
/-- Universal refinement for `LDH A,(C)`. -/
theorem ldh_c_read_refines (before : FunctionalState) (opcode : Byte)
    (running : before.mode = .running) (noHaltBug : before.haltBug = false)
    (atPC : before.memory.read before.registers.pc = opcode)
    (decoded : Decode.base opcode = .legal .ldhAC) :
    let logical := Functional.step before 0
    let physical := FlatAdapter.run 3 (physicalInitial before) noInterrupts
    Retirement.Snapshot.atBoundary physical.core =
        Retirement.Snapshot.ofFunctional logical.state ∧
      physical.memory = logical.state.memory ∧
      physical.trace.dropLast = logical.trace := by
  rw [show FlatAdapter.run 3 (physicalInitial before) noInterrupts =
      FlatAdapter.step (FlatAdapter.step (FlatAdapter.step (physicalInitial before))) by rfl]
  rw [fetch_legal before opcode .ldhAC atPC noHaltBug decoded]
  rw [step_ldh_c_read before opcode]
  simp [Functional.step, running, atPC, decoded, noHaltBug, ldhCRead,
    ldhCReadCore, ldhCAddress, baseFetchedCore, Pipeline.taken,
    Cycle.physicalSchedule, Cycle.logicalSchedule, FlatAdapter.step,
    CoreState.currentOp?, Run.stepMachineCycle, Run.intent, Run.opFetch,
    Run.opCommit, Run.opPoll, Run.opControl, Run.opAddress,
    Run.successorAddress, Run.opReadKind, Run.opIdu,
    Run.finishSuccessor, Run.commitRegisters, Run.commitIme,
    Functional.fetchImmediate, InstructionShape.immediateBytes,
    Functional.executeShape, Functional.read, Functional.withRegisters,
    Functional.matureIme,
    FlatAdapter.event]
  all_goals cases before.scheduledImeEnable <;>
    simp [Retirement.Snapshot.atBoundary, Retirement.Snapshot.ofFunctional]

/-- Immediate-high-page load directions. -/
inductive LdhImmediateShape : InstructionShape → Prop where
  | writeA : LdhImmediateShape .ldhImmA
  | readA : LdhImmediateShape .ldhAImm

private def ldhImmediateAddress (value : Byte) : Word :=
  Word.ofNat (0xFF00 + value.toNat)

private def ldhImmediateCore (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (value : Byte) : CoreState :=
  { baseFetchedCore state opcode shape with
    registers := { state.registers with pc := Word.ofNat (state.registers.pc.toNat + 2) }
    remaining := match shape with
      | .ldhImmA => [.writeAddress, .successorFetch]
      | .ldhAImm => [.readAddress, .successorFetch]
      | _ => [.successorFetch]
    latches := { low := value, conditionTaken := true } }

private def ldhImmediate (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (value : Byte) : FlatCoreState :=
  { core := ldhImmediateCore state opcode shape value
    memory := state.memory
    trace := [.read .opcode state.registers.pc opcode,
      .read .immediate (Word.ofNat (state.registers.pc.toNat + 1)) value] }

private def ldhAccessedCore (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (value : Byte) : CoreState :=
  let data : Byte := if shape == .ldhAImm then
    state.memory.read (ldhImmediateAddress value) else 0
  { ldhImmediateCore state opcode shape value with
    remaining := [.successorFetch]
    latches := { low := value, data := data } }

private def ldhAccessed (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (value : Byte) : FlatCoreState :=
  let address := ldhImmediateAddress value
  if shape == .ldhImmA then
    { core := ldhAccessedCore state opcode shape value
      memory := state.memory.write address state.registers.a
      trace := [.read .opcode state.registers.pc opcode,
        .read .immediate (Word.ofNat (state.registers.pc.toNat + 1)) value,
        .write address state.registers.a] }
  else
    let loaded := state.memory.read address
    { core := ldhAccessedCore state opcode shape value
      memory := state.memory
      trace := [.read .opcode state.registers.pc opcode,
        .read .immediate (Word.ofNat (state.registers.pc.toNat + 1)) value,
        .read .data address loaded] }

private theorem step_ldh_immediate (before : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (family : LdhImmediateShape shape) :
    FlatAdapter.step (baseFetched before opcode shape) =
      ldhImmediate before opcode shape
        (before.memory.read (Word.ofNat (before.registers.pc.toNat + 1))) := by
  cases family <;>
    simp [FlatAdapter.step, baseFetched, baseFetchedCore, ldhImmediate,
      ldhImmediateCore, Pipeline.taken, Cycle.physicalSchedule,
      Cycle.logicalSchedule, CoreState.currentOp?, Run.stepMachineCycle,
      Run.intent, Run.opFetch, Run.opCommit, Run.opPoll, Run.opControl,
      Run.opAddress, Run.opReadKind, Run.opIdu, Run.processNonFetch,
      increment_twice, FlatAdapter.event]

private theorem step_ldh_access (before : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (family : LdhImmediateShape shape) :
    let value := before.memory.read (Word.ofNat (before.registers.pc.toNat + 1))
    FlatAdapter.step (ldhImmediate before opcode shape value) =
      ldhAccessed before opcode shape value := by
  cases family <;>
    simp [FlatAdapter.step, ldhImmediate, ldhImmediateCore, ldhAccessed,
      ldhAccessedCore, ldhImmediateAddress, baseFetchedCore,
      Pipeline.taken, Cycle.physicalSchedule, Cycle.logicalSchedule,
      CoreState.currentOp?, Run.stepMachineCycle, Run.intent, Run.opFetch,
      Run.opCommit, Run.opPoll, Run.opControl, Run.opAddress,
      Run.readAddress, Run.opReadKind, Run.opIdu, Run.processNonFetch,
      Run.updatePointer, Run.writeValue, FlatAdapter.event]

set_option maxHeartbeats 3000000 in
/-- Universal refinement for both immediate LDH directions. -/
theorem ldh_immediate_refines (before : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (family : LdhImmediateShape shape)
    (running : before.mode = .running) (noHaltBug : before.haltBug = false)
    (atPC : before.memory.read before.registers.pc = opcode)
    (decoded : Decode.base opcode = .legal shape) :
    let logical := Functional.step before 0
    let physical := FlatAdapter.run 4 (physicalInitial before) noInterrupts
    Retirement.Snapshot.atBoundary physical.core =
        Retirement.Snapshot.ofFunctional logical.state ∧
      physical.memory = logical.state.memory ∧
      physical.trace.dropLast = logical.trace := by
  rw [show FlatAdapter.run 4 (physicalInitial before) noInterrupts =
      FlatAdapter.step (FlatAdapter.step (FlatAdapter.step
        (FlatAdapter.step (physicalInitial before)))) by rfl]
  rw [fetch_legal before opcode shape atPC noHaltBug decoded]
  rw [step_ldh_immediate before opcode shape family]
  rw [step_ldh_access before opcode shape family]
  cases family <;>
    simp [Functional.step, running, atPC, decoded, noHaltBug, ldhAccessed,
      ldhAccessedCore, ldhImmediateCore, ldhImmediateAddress,
      baseFetchedCore, Pipeline.taken, Cycle.physicalSchedule,
      Cycle.logicalSchedule, FlatAdapter.step, CoreState.currentOp?,
      Run.stepMachineCycle, Run.intent, Run.opFetch, Run.opCommit,
      Run.opPoll, Run.opControl, Run.opAddress, Run.successorAddress,
      Run.opReadKind, Run.opIdu, Run.finishSuccessor,
      Run.commitRegisters, Run.commitIme, Functional.fetchImmediate,
      Functional.read, Functional.immediate8, InstructionShape.immediateBytes,
      Functional.executeShape, Functional.write, Functional.withRegisters,
      Functional.matureIme, increment_twice, FlatAdapter.event]
  all_goals cases before.scheduledImeEnable <;>
    simp [Retirement.Snapshot.atBoundary, Retirement.Snapshot.ofFunctional]

/-- Absolute-address accumulator load directions. -/
inductive AbsoluteAShape : InstructionShape → Prop where
  | writeA : AbsoluteAShape .ldAbsA
  | readA : AbsoluteAShape .ldAAbs

private def absoluteLowCore (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (low : Byte) : CoreState :=
  { baseFetchedCore state opcode shape with
    registers := { state.registers with pc := Word.ofNat (state.registers.pc.toNat + 2) }
    remaining := [.immediateHigh,
      if shape == .ldAbsA then .writeAddress else .readAddress,
      .successorFetch]
    latches := { low, conditionTaken := true } }

private def absoluteLow (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (low : Byte) : FlatCoreState :=
  { core := absoluteLowCore state opcode shape low
    memory := state.memory
    trace := [.read .opcode state.registers.pc opcode,
      .read .immediate (Word.ofNat (state.registers.pc.toNat + 1)) low] }

private def absoluteHighCore (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (low high : Byte) : CoreState :=
  { absoluteLowCore state opcode shape low with
    registers := { state.registers with pc := Word.ofNat (state.registers.pc.toNat + 3) }
    remaining := [if shape == .ldAbsA then .writeAddress else .readAddress,
      .successorFetch]
    latches := { low, high, conditionTaken := true } }

private def absoluteHigh (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (low high : Byte) : FlatCoreState :=
  { core := absoluteHighCore state opcode shape low high
    memory := state.memory
    trace := [.read .opcode state.registers.pc opcode,
      .read .immediate (Word.ofNat (state.registers.pc.toNat + 1)) low,
      .read .immediate (Word.ofNat (state.registers.pc.toNat + 2)) high] }

private def absoluteAccessedCore (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (low high : Byte) : CoreState :=
  let address := Word.ofBytes high low
  let data : Byte := if shape == .ldAAbs then state.memory.read address else 0
  { absoluteHighCore state opcode shape low high with
    remaining := [.successorFetch]
    latches := { low, high, data := data } }

private def absoluteAccessed (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (low high : Byte) : FlatCoreState :=
  let address := Word.ofBytes high low
  if shape == .ldAbsA then
    { core := absoluteAccessedCore state opcode shape low high
      memory := state.memory.write address state.registers.a
      trace := [.read .opcode state.registers.pc opcode,
        .read .immediate (Word.ofNat (state.registers.pc.toNat + 1)) low,
        .read .immediate (Word.ofNat (state.registers.pc.toNat + 2)) high,
        .write address state.registers.a] }
  else
    let value := state.memory.read address
    { core := absoluteAccessedCore state opcode shape low high
      memory := state.memory
      trace := [.read .opcode state.registers.pc opcode,
        .read .immediate (Word.ofNat (state.registers.pc.toNat + 1)) low,
        .read .immediate (Word.ofNat (state.registers.pc.toNat + 2)) high,
        .read .data address value] }

private theorem step_absolute_low (before : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (family : AbsoluteAShape shape) :
    FlatAdapter.step (baseFetched before opcode shape) =
      absoluteLow before opcode shape
        (before.memory.read (Word.ofNat (before.registers.pc.toNat + 1))) := by
  cases family <;>
    simp [FlatAdapter.step, baseFetched, baseFetchedCore, absoluteLow,
      absoluteLowCore, Pipeline.taken, Cycle.physicalSchedule,
      Cycle.logicalSchedule, CoreState.currentOp?, Run.stepMachineCycle,
      Run.intent, Run.opFetch, Run.opCommit, Run.opPoll, Run.opControl,
      Run.opAddress, Run.opReadKind, Run.opIdu, Run.processNonFetch,
      increment_twice, FlatAdapter.event]

private theorem step_absolute_high (before : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (family : AbsoluteAShape shape) :
    let low := before.memory.read (Word.ofNat (before.registers.pc.toNat + 1))
    FlatAdapter.step (absoluteLow before opcode shape low) =
      absoluteHigh before opcode shape low
        (before.memory.read (Word.ofNat (before.registers.pc.toNat + 2))) := by
  cases family <;>
    simp [FlatAdapter.step, absoluteLow, absoluteLowCore, absoluteHigh,
      absoluteHighCore, baseFetchedCore, Pipeline.taken,
      Cycle.physicalSchedule, Cycle.logicalSchedule, CoreState.currentOp?,
      Run.stepMachineCycle, Run.intent, Run.opFetch, Run.opCommit,
      Run.opPoll, Run.opControl, Run.opAddress, Run.opReadKind, Run.opIdu,
      Run.processNonFetch, increment_thrice, FlatAdapter.event]

private theorem step_absolute_access (before : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (family : AbsoluteAShape shape) :
    let low := before.memory.read (Word.ofNat (before.registers.pc.toNat + 1))
    let high := before.memory.read (Word.ofNat (before.registers.pc.toNat + 2))
    FlatAdapter.step (absoluteHigh before opcode shape low high) =
      absoluteAccessed before opcode shape low high := by
  cases family <;>
    simp [FlatAdapter.step, absoluteHigh, absoluteHighCore, absoluteLowCore,
      absoluteAccessed, absoluteAccessedCore, baseFetchedCore,
      Pipeline.taken, Cycle.physicalSchedule, Cycle.logicalSchedule,
      CoreState.currentOp?, Run.stepMachineCycle, Run.intent, Run.opFetch,
      Run.opCommit, Run.opPoll, Run.opControl, Run.opAddress,
      Run.readAddress, Run.opReadKind, Run.opIdu, Run.processNonFetch,
      Run.updatePointer, Run.writeValue, CoreState.wz, FlatAdapter.event]

set_option maxHeartbeats 3000000 in
/-- Universal refinement for `LD (nn),A` and `LD A,(nn)`. -/
theorem absolute_a_refines (before : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (family : AbsoluteAShape shape)
    (running : before.mode = .running) (noHaltBug : before.haltBug = false)
    (atPC : before.memory.read before.registers.pc = opcode)
    (decoded : Decode.base opcode = .legal shape) :
    let logical := Functional.step before 0
    let physical := FlatAdapter.run 5 (physicalInitial before) noInterrupts
    Retirement.Snapshot.atBoundary physical.core =
        Retirement.Snapshot.ofFunctional logical.state ∧
      physical.memory = logical.state.memory ∧
      physical.trace.dropLast = logical.trace := by
  rw [show FlatAdapter.run 5 (physicalInitial before) noInterrupts =
      FlatAdapter.step (FlatAdapter.step (FlatAdapter.step (FlatAdapter.step
        (FlatAdapter.step (physicalInitial before))))) by rfl]
  rw [fetch_legal before opcode shape atPC noHaltBug decoded]
  rw [step_absolute_low before opcode shape family]
  rw [step_absolute_high before opcode shape family]
  rw [step_absolute_access before opcode shape family]
  cases family <;>
    simp [Functional.step, running, atPC, decoded, noHaltBug,
      absoluteAccessed, absoluteAccessedCore, absoluteHighCore,
      absoluteLowCore, baseFetchedCore, Pipeline.taken,
      Cycle.physicalSchedule, Cycle.logicalSchedule, FlatAdapter.step,
      CoreState.currentOp?, Run.stepMachineCycle, Run.intent, Run.opFetch,
      Run.opCommit, Run.opPoll, Run.opControl, Run.opAddress,
      Run.successorAddress, Run.opReadKind, Run.opIdu, Run.finishSuccessor,
      Run.commitRegisters, Run.commitIme, Functional.fetchImmediate,
      Functional.read, Functional.immediate16, InstructionShape.immediateBytes,
      Functional.executeShape, Functional.write, Functional.withRegisters,
      Functional.matureIme, increment_twice, increment_thrice,
      FlatAdapter.event]
  all_goals cases before.scheduledImeEnable <;>
    simp [Retirement.Snapshot.atBoundary, Retirement.Snapshot.ofFunctional]

private def popLowCore (state : FunctionalState) (opcode : Byte)
    (target : Stack16) (low : Byte) : CoreState :=
  { baseFetchedCore state opcode (.pop target) with
    registers := { (baseFetchedCore state opcode (.pop target)).registers with
      sp := Word.ofNat (state.registers.sp.toNat + 1) }
    remaining := [.stackReadHigh, .successorFetch]
    latches := { low, conditionTaken := true } }

private def popLow (state : FunctionalState) (opcode : Byte)
    (target : Stack16) (low : Byte) : FlatCoreState :=
  { core := popLowCore state opcode target low
    memory := state.memory
    trace := [.read .opcode state.registers.pc opcode,
      .read .stack state.registers.sp low] }

private def popHighCore (state : FunctionalState) (opcode : Byte)
    (target : Stack16) (low high : Byte) : CoreState :=
  { popLowCore state opcode target low with
    registers := { (popLowCore state opcode target low).registers with
      sp := Word.ofNat (state.registers.sp.toNat + 2) }
    remaining := [.successorFetch]
    latches := { low, high, conditionTaken := true } }

private def popHigh (state : FunctionalState) (opcode : Byte)
    (target : Stack16) (low high : Byte) : FlatCoreState :=
  { core := popHighCore state opcode target low high
    memory := state.memory
    trace := [.read .opcode state.registers.pc opcode,
      .read .stack state.registers.sp low,
      .read .stack (Word.ofNat (state.registers.sp.toNat + 1)) high] }

private theorem step_pop_low (before : FunctionalState) (opcode : Byte)
    (target : Stack16) :
    FlatAdapter.step (baseFetched before opcode (.pop target)) =
      popLow before opcode target (before.memory.read before.registers.sp) := by
  cases target <;>
    simp [FlatAdapter.step, baseFetched, baseFetchedCore, popLow, popLowCore,
      Pipeline.taken, Cycle.physicalSchedule, Cycle.logicalSchedule,
      CoreState.currentOp?, Run.stepMachineCycle, Run.intent, Run.opFetch,
      Run.opCommit, Run.opPoll, Run.opControl, Run.opAddress, Run.opReadKind,
      Run.opIdu, Run.processNonFetch, FlatAdapter.event]

private theorem step_pop_high (before : FunctionalState) (opcode : Byte)
    (target : Stack16) :
    let low := before.memory.read before.registers.sp
    FlatAdapter.step (popLow before opcode target low) =
      popHigh before opcode target low
        (before.memory.read (Word.ofNat (before.registers.sp.toNat + 1))) := by
  cases target <;>
    simp [FlatAdapter.step, popLow, popLowCore, popHigh, popHighCore,
      baseFetchedCore, Pipeline.taken, Cycle.physicalSchedule,
      Cycle.logicalSchedule, CoreState.currentOp?, Run.stepMachineCycle,
      Run.intent, Run.opFetch, Run.opCommit, Run.opPoll, Run.opControl,
      Run.opAddress, Run.opReadKind, Run.opIdu, Run.processNonFetch,
      increment_twice, FlatAdapter.event]

set_option maxHeartbeats 3000000 in
/-- Universal refinement for all four `POP rr` entries. -/
theorem pop_refines (before : FunctionalState) (opcode : Byte)
    (target : Stack16) (running : before.mode = .running)
    (noHaltBug : before.haltBug = false)
    (atPC : before.memory.read before.registers.pc = opcode)
    (decoded : Decode.base opcode = .legal (.pop target)) :
    let logical := Functional.step before 0
    let physical := FlatAdapter.run 4 (physicalInitial before) noInterrupts
    Retirement.Snapshot.atBoundary physical.core =
        Retirement.Snapshot.ofFunctional logical.state ∧
      physical.memory = logical.state.memory ∧
      physical.trace.dropLast = logical.trace := by
  rw [show FlatAdapter.run 4 (physicalInitial before) noInterrupts =
      FlatAdapter.step (FlatAdapter.step (FlatAdapter.step
        (FlatAdapter.step (physicalInitial before)))) by rfl]
  rw [fetch_legal before opcode (.pop target) atPC noHaltBug decoded]
  rw [step_pop_low before opcode target]
  rw [step_pop_high before opcode target]
  cases target <;>
    simp [Functional.step, running, atPC, decoded, noHaltBug, popHigh,
      popHighCore, popLowCore, baseFetchedCore, Pipeline.taken,
      Cycle.physicalSchedule, Cycle.logicalSchedule, FlatAdapter.step,
      CoreState.currentOp?, Run.stepMachineCycle, Run.intent, Run.opFetch,
      Run.opCommit, Run.opPoll, Run.opControl, Run.opAddress,
      Run.successorAddress, Run.opReadKind, Run.opIdu, Run.finishSuccessor,
      Run.commitRegisters, Run.commitIme, Functional.fetchImmediate,
      InstructionShape.immediateBytes, Functional.executeShape,
      Functional.popWord, Functional.incrementSP, Functional.read,
      Functional.withRegisters, Functional.matureIme, Registers.setStack16,
      Registers.setBC, Registers.setDE, Registers.setHL, Registers.setAF,
      CoreState.wz, increment_twice,
      FlatAdapter.event]
  all_goals cases before.scheduledImeEnable <;>
    simp [Retirement.Snapshot.atBoundary, Retirement.Snapshot.ofFunctional]

/-- Base families with the three-cycle stack-write suffix. -/
inductive StackStoreShape : InstructionShape → Prop where
  | push (source : Stack16) : StackStoreShape (.push source)
  | rst (vector : RstVector) : StackStoreShape (.rst vector)

private def stackStoreValue (state : FunctionalState) (shape : InstructionShape) : Word :=
  match shape with
  | .push source => state.registers.getStack16 source
  | .rst _ => Word.ofNat (state.registers.pc.toNat + 1)
  | _ => 0

private def stackInitialCore (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) : CoreState :=
  let core := baseFetchedCore state opcode shape
  { core with
    registers := { core.registers with sp := Word.ofNat (state.registers.sp.toNat + 65535) }
    remaining := [.stackWriteHigh, .stackWriteLow, .successorFetch] }

private def stackInitial (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) : FlatCoreState :=
  { core := stackInitialCore state opcode shape
    memory := state.memory
    trace := [.read .opcode state.registers.pc opcode, .idle state.registers.sp] }

private def stackHighCore (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) : CoreState :=
  let core := stackInitialCore state opcode shape
  { core with
    registers := { core.registers with sp := Word.ofNat (state.registers.sp.toNat + 65534) }
    remaining := [.stackWriteLow, .successorFetch] }

private def stackHigh (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) : FlatCoreState :=
  let value := stackStoreValue state shape
  let address := Word.ofNat (state.registers.sp.toNat + 65535)
  { core := stackHighCore state opcode shape
    memory := state.memory.write address value.highByte
    trace := [.read .opcode state.registers.pc opcode, .idle state.registers.sp,
      .write address value.highByte] }

private def stackLowCore (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) : CoreState :=
  { stackHighCore state opcode shape with remaining := [.successorFetch] }

private def stackLow (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) : FlatCoreState :=
  let value := stackStoreValue state shape
  let highAddress := Word.ofNat (state.registers.sp.toNat + 65535)
  let lowAddress := Word.ofNat (state.registers.sp.toNat + 65534)
  { core := stackLowCore state opcode shape
    memory := (state.memory.write highAddress value.highByte).write lowAddress value.lowByte
    trace := [.read .opcode state.registers.pc opcode, .idle state.registers.sp,
      .write highAddress value.highByte, .write lowAddress value.lowByte] }

private theorem decrement_twice : ∀ sp : Word,
    Word.ofNat ((Word.ofNat (sp.toNat + 65535)).toNat + 65535) =
      Word.ofNat (sp.toNat + 65534) := by
  native_decide

private theorem step_stack_initial (before : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (family : StackStoreShape shape) :
    FlatAdapter.step (baseFetched before opcode shape) =
      stackInitial before opcode shape := by
  cases family <;>
    simp [FlatAdapter.step, baseFetched, baseFetchedCore, stackInitial,
      stackInitialCore, Pipeline.taken, Cycle.physicalSchedule,
      Cycle.logicalSchedule, CoreState.currentOp?, Run.stepMachineCycle,
      Run.intent, Run.opFetch, Run.opCommit, Run.opPoll, Run.opControl,
      Run.opAddress, Run.opReadKind, Run.opIdu,
      Run.processNonFetch, FlatAdapter.event]

private theorem step_stack_high (before : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (family : StackStoreShape shape) :
    FlatAdapter.step (stackInitial before opcode shape) =
      stackHigh before opcode shape := by
  cases family <;>
    simp [FlatAdapter.step, stackInitial, stackInitialCore, stackHigh,
      stackHighCore, stackStoreValue, baseFetchedCore, Pipeline.taken,
      Cycle.physicalSchedule, Cycle.logicalSchedule, CoreState.currentOp?,
      Run.stepMachineCycle, Run.intent, Run.opFetch, Run.opCommit,
      Run.opPoll, Run.opControl, Run.opAddress, Run.opReadKind, Run.opIdu,
      Run.processNonFetch, Run.writeValue, Registers.getStack16,
      Registers.bc, Registers.de, Registers.hl, Registers.af,
      decrement_twice, FlatAdapter.event]

private theorem step_stack_low (before : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (family : StackStoreShape shape) :
    FlatAdapter.step (stackHigh before opcode shape) =
      stackLow before opcode shape := by
  cases family <;>
    simp [FlatAdapter.step, stackHigh, stackHighCore, stackLow, stackLowCore,
      stackInitialCore, stackStoreValue, baseFetchedCore, Pipeline.taken,
      Cycle.physicalSchedule, Cycle.logicalSchedule, CoreState.currentOp?,
      Run.stepMachineCycle, Run.intent, Run.opFetch, Run.opCommit,
      Run.opPoll, Run.opControl, Run.opAddress, Run.opReadKind, Run.opIdu,
      Run.processNonFetch, Run.writeValue, Registers.getStack16,
      Registers.bc, Registers.de, Registers.hl, Registers.af,
      FlatAdapter.event]

set_option maxHeartbeats 3000000 in
/-- Universal refinement for all four PUSH and eight RST entries. -/
theorem stack_store_refines (before : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (family : StackStoreShape shape)
    (running : before.mode = .running) (noHaltBug : before.haltBug = false)
    (atPC : before.memory.read before.registers.pc = opcode)
    (decoded : Decode.base opcode = .legal shape) :
    let logical := Functional.step before 0
    let physical := FlatAdapter.run 5 (physicalInitial before) noInterrupts
    Retirement.Snapshot.atBoundary physical.core =
        Retirement.Snapshot.ofFunctional logical.state ∧
      physical.memory = logical.state.memory ∧
      physical.trace.dropLast = logical.trace := by
  rw [show FlatAdapter.run 5 (physicalInitial before) noInterrupts =
      FlatAdapter.step (FlatAdapter.step (FlatAdapter.step (FlatAdapter.step
        (FlatAdapter.step (physicalInitial before))))) by rfl]
  rw [fetch_legal before opcode shape atPC noHaltBug decoded]
  rw [step_stack_initial before opcode shape family]
  rw [step_stack_high before opcode shape family]
  rw [step_stack_low before opcode shape family]
  cases family <;>
    simp [Functional.step, running, atPC, decoded, noHaltBug, stackLow,
      stackLowCore, stackHighCore, stackInitialCore, stackStoreValue,
      baseFetchedCore, Pipeline.taken, Cycle.physicalSchedule,
      Cycle.logicalSchedule, FlatAdapter.step, CoreState.currentOp?,
      Run.stepMachineCycle, Run.intent, Run.opFetch, Run.opCommit,
      Run.opPoll, Run.opControl, Run.opAddress, Run.successorAddress,
      Run.opReadKind, Run.opIdu, Run.finishSuccessor, Run.commitRegisters,
      Run.commitIme, Functional.fetchImmediate, InstructionShape.immediateBytes,
      Functional.executeShape, Functional.pushWord, Functional.idle,
      Functional.write, Functional.withRegisters, Functional.decrementSP,
      Functional.matureIme, Registers.getStack16, Registers.bc,
      Registers.de, Registers.hl, Registers.af, decrement_twice,
      FlatAdapter.event]
  all_goals cases before.scheduledImeEnable <;>
    simp [Retirement.Snapshot.atBoundary, Retirement.Snapshot.ofFunctional]
  all_goals try { cases ‹Stack16› <;> simp [Registers.getStack16,
    Registers.bc, Registers.de, Registers.hl, Registers.af] }

private def signedImmediateCore (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (value : Byte) : CoreState :=
  { baseFetchedCore state opcode shape with
    registers := { state.registers with pc := Word.ofNat (state.registers.pc.toNat + 2) }
    remaining := if shape == .addSP then
      [.internal, .internal, .successorFetch] else [.internal, .successorFetch]
    latches := { low := value, conditionTaken := true } }

private def signedImmediate (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (value : Byte) : FlatCoreState :=
  { core := signedImmediateCore state opcode shape value
    memory := state.memory
    trace := [.read .opcode state.registers.pc opcode,
      .read .immediate (Word.ofNat (state.registers.pc.toNat + 1)) value] }

private def signedFirstCore (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (value : Byte) : CoreState :=
  { signedImmediateCore state opcode shape value with
    remaining := if shape == .addSP then [.internal, .successorFetch]
      else [.successorFetch] }

private def signedFirst (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (value : Byte) : FlatCoreState :=
  let result := (Alu.addSignedSP state.registers.sp value).value
  let address := if shape == .addSP then state.registers.sp else result
  { core := signedFirstCore state opcode shape value
    memory := state.memory
    trace := [.read .opcode state.registers.pc opcode,
      .read .immediate (Word.ofNat (state.registers.pc.toNat + 1)) value,
      .idle address] }

private theorem step_signed_immediate (before : FunctionalState) (opcode : Byte)
    (shape : InstructionShape)
    (family : shape = .addSP ∨ shape = .ldHLFromSPPlus) :
    FlatAdapter.step (baseFetched before opcode shape) =
      signedImmediate before opcode shape
        (before.memory.read (Word.ofNat (before.registers.pc.toNat + 1))) := by
  rcases family with rfl | rfl <;>
    simp [FlatAdapter.step, baseFetched, baseFetchedCore, signedImmediate,
      signedImmediateCore, Pipeline.taken, Cycle.physicalSchedule,
      Cycle.logicalSchedule, CoreState.currentOp?, Run.stepMachineCycle,
      Run.intent, Run.opFetch, Run.opCommit, Run.opPoll, Run.opControl,
      Run.opAddress, Run.opReadKind, Run.opIdu, Run.processNonFetch,
      increment_twice, FlatAdapter.event]

private theorem step_signed_first (before : FunctionalState) (opcode : Byte)
    (shape : InstructionShape)
    (family : shape = .addSP ∨ shape = .ldHLFromSPPlus) :
    let value := before.memory.read (Word.ofNat (before.registers.pc.toNat + 1))
    FlatAdapter.step (signedImmediate before opcode shape value) =
      signedFirst before opcode shape value := by
  rcases family with rfl | rfl <;>
    simp [FlatAdapter.step, signedImmediate, signedImmediateCore, signedFirst,
      signedFirstCore, baseFetchedCore, Pipeline.taken,
      Cycle.physicalSchedule, Cycle.logicalSchedule, CoreState.currentOp?,
      Run.stepMachineCycle, Run.intent, Run.opFetch, Run.opCommit,
      Run.opPoll, Run.opControl, Run.opAddress, Run.internalAddress,
      Run.opReadKind, Run.opIdu, Run.processNonFetch, FlatAdapter.event]

set_option maxHeartbeats 3000000 in
/-- Universal refinement for `LD HL,SP+e`. -/
theorem ld_hl_sp_plus_refines (before : FunctionalState) (opcode : Byte)
    (running : before.mode = .running) (noHaltBug : before.haltBug = false)
    (atPC : before.memory.read before.registers.pc = opcode)
    (decoded : Decode.base opcode = .legal .ldHLFromSPPlus) :
    let logical := Functional.step before 0
    let physical := FlatAdapter.run 4 (physicalInitial before) noInterrupts
    Retirement.Snapshot.atBoundary physical.core =
        Retirement.Snapshot.ofFunctional logical.state ∧
      physical.memory = logical.state.memory ∧
      physical.trace.dropLast = logical.trace := by
  rw [show FlatAdapter.run 4 (physicalInitial before) noInterrupts =
      FlatAdapter.step (FlatAdapter.step (FlatAdapter.step
        (FlatAdapter.step (physicalInitial before)))) by rfl]
  rw [fetch_legal before opcode .ldHLFromSPPlus atPC noHaltBug decoded]
  rw [step_signed_immediate before opcode .ldHLFromSPPlus (Or.inr rfl)]
  rw [step_signed_first before opcode .ldHLFromSPPlus (Or.inr rfl)]
  simp [Functional.step, running, atPC, decoded, noHaltBug, signedFirst,
    signedFirstCore, signedImmediateCore, baseFetchedCore, Pipeline.taken,
    Cycle.physicalSchedule, Cycle.logicalSchedule, FlatAdapter.step,
    CoreState.currentOp?, Run.stepMachineCycle, Run.intent, Run.opFetch,
    Run.opCommit, Run.opPoll, Run.opControl, Run.opAddress,
    Run.successorAddress, Run.opReadKind, Run.opIdu, Run.finishSuccessor,
    Run.commitRegisters, Run.commitIme, Functional.fetchImmediate,
    Functional.read, Functional.immediate8, InstructionShape.immediateBytes,
    Functional.executeShape, Functional.idle, Functional.withRegisters,
    Functional.matureIme, Registers.setHL, increment_twice,
    FlatAdapter.event]
  all_goals cases before.scheduledImeEnable <;>
    simp [Retirement.Snapshot.atBoundary, Retirement.Snapshot.ofFunctional]

private def addSPSecondCore (state : FunctionalState) (opcode value : Byte) : CoreState :=
  { signedFirstCore state opcode .addSP value with remaining := [.successorFetch] }

private def addSPSecond (state : FunctionalState) (opcode value : Byte) : FlatCoreState :=
  let result := (Alu.addSignedSP state.registers.sp value).value
  { core := addSPSecondCore state opcode value
    memory := state.memory
    trace := [.read .opcode state.registers.pc opcode,
      .read .immediate (Word.ofNat (state.registers.pc.toNat + 1)) value,
      .idle state.registers.sp, .idle result] }

private theorem step_add_sp_second (before : FunctionalState) (opcode : Byte) :
    let value := before.memory.read (Word.ofNat (before.registers.pc.toNat + 1))
    FlatAdapter.step (signedFirst before opcode .addSP value) =
      addSPSecond before opcode value := by
  simp [FlatAdapter.step, signedFirst, signedFirstCore, signedImmediateCore,
    addSPSecond, addSPSecondCore, baseFetchedCore, Pipeline.taken,
    Cycle.physicalSchedule, Cycle.logicalSchedule, CoreState.currentOp?,
    Run.stepMachineCycle, Run.intent, Run.opFetch, Run.opCommit,
    Run.opPoll, Run.opControl, Run.opAddress, Run.internalAddress,
    Run.opReadKind, Run.opIdu, Run.processNonFetch, FlatAdapter.event]

set_option maxHeartbeats 3000000 in
/-- Universal refinement for `ADD SP,e`. -/
theorem add_sp_refines (before : FunctionalState) (opcode : Byte)
    (running : before.mode = .running) (noHaltBug : before.haltBug = false)
    (atPC : before.memory.read before.registers.pc = opcode)
    (decoded : Decode.base opcode = .legal .addSP) :
    let logical := Functional.step before 0
    let physical := FlatAdapter.run 5 (physicalInitial before) noInterrupts
    Retirement.Snapshot.atBoundary physical.core =
        Retirement.Snapshot.ofFunctional logical.state ∧
      physical.memory = logical.state.memory ∧
      physical.trace.dropLast = logical.trace := by
  rw [show FlatAdapter.run 5 (physicalInitial before) noInterrupts =
      FlatAdapter.step (FlatAdapter.step (FlatAdapter.step (FlatAdapter.step
        (FlatAdapter.step (physicalInitial before))))) by rfl]
  rw [fetch_legal before opcode .addSP atPC noHaltBug decoded]
  rw [step_signed_immediate before opcode .addSP (Or.inl rfl)]
  rw [step_signed_first before opcode .addSP (Or.inl rfl)]
  rw [step_add_sp_second before opcode]
  simp [Functional.step, running, atPC, decoded, noHaltBug, addSPSecond,
    addSPSecondCore, signedFirstCore, signedImmediateCore, baseFetchedCore,
    Pipeline.taken, Cycle.physicalSchedule, Cycle.logicalSchedule,
    FlatAdapter.step, CoreState.currentOp?, Run.stepMachineCycle, Run.intent,
    Run.opFetch, Run.opCommit, Run.opPoll, Run.opControl, Run.opAddress,
    Run.successorAddress, Run.opReadKind, Run.opIdu, Run.finishSuccessor,
    Run.commitRegisters, Run.commitIme, Functional.fetchImmediate,
    Functional.read, Functional.immediate8, InstructionShape.immediateBytes,
    Functional.executeShape, Functional.idle, Functional.withRegisters,
    Functional.matureIme, increment_twice, FlatAdapter.event]
  all_goals cases before.scheduledImeEnable <;>
    simp [Retirement.Snapshot.atBoundary, Retirement.Snapshot.ofFunctional]

private def jrImmediateCore (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (value : Byte) (taken : Bool) : CoreState :=
  let core := baseFetchedCore state opcode shape
  { core with
    registers := { state.registers with pc := Word.ofNat (state.registers.pc.toNat + 2) }
    remaining := if taken then [.internal, .successorFetch] else [.successorFetch]
    latches := { core.latches with low := value, conditionTaken := taken } }

private def jrImmediate (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (value : Byte) (taken : Bool) : FlatCoreState :=
  { core := jrImmediateCore state opcode shape value taken
    memory := state.memory
    trace := [.read .opcode state.registers.pc opcode,
      .read .immediate (Word.ofNat (state.registers.pc.toNat + 1)) value] }

private def jrInternalCore (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (value : Byte) : CoreState :=
  { jrImmediateCore state opcode shape value true with remaining := [.successorFetch] }

private def jrInternal (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (value : Byte) : FlatCoreState :=
  { core := jrInternalCore state opcode shape value
    memory := state.memory
    trace := [.read .opcode state.registers.pc opcode,
      .read .immediate (Word.ofNat (state.registers.pc.toNat + 1)) value,
      .idle (Word.ofNat (state.registers.pc.toNat + 2))] }

private theorem step_jr_immediate (before : FunctionalState) (opcode : Byte) :
    FlatAdapter.step (baseFetched before opcode .jr) =
      jrImmediate before opcode .jr
        (before.memory.read (Word.ofNat (before.registers.pc.toNat + 1))) true := by
  simp [FlatAdapter.step, baseFetched, baseFetchedCore, jrImmediate,
    jrImmediateCore, Pipeline.taken, Cycle.physicalSchedule,
    Cycle.logicalSchedule, CoreState.currentOp?, Run.stepMachineCycle,
    Run.intent, Run.opFetch, Run.opCommit, Run.opPoll, Run.opControl,
    Run.opAddress, Run.opReadKind, Run.opIdu, Run.processNonFetch,
    increment_twice, FlatAdapter.event]

private theorem step_jr_cond_immediate (before : FunctionalState) (opcode : Byte)
    (condition : Condition) (taken : Bool)
    (h : Alu.conditionHolds condition before.registers.flags = taken) :
    FlatAdapter.step (baseFetched before opcode (.jrCond condition)) =
      jrImmediate before opcode (.jrCond condition)
        (before.memory.read (Word.ofNat (before.registers.pc.toNat + 1))) taken := by
  cases condition <;> cases taken <;>
    simp_all [FlatAdapter.step, baseFetched, baseFetchedCore, jrImmediate,
      jrImmediateCore, Pipeline.taken, Cycle.physicalSchedule,
      Cycle.logicalSchedule, CoreState.currentOp?, Run.stepMachineCycle,
      Run.intent, Run.opFetch, Run.opCommit, Run.opPoll, Run.opControl,
      Run.opAddress, Run.opReadKind, Run.opIdu, Run.processNonFetch,
      Alu.conditionHolds, increment_twice, FlatAdapter.event]

private theorem step_jr_internal (before : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (isJr : shape = .jr ∨ ∃ condition, shape = .jrCond condition) :
    let value := before.memory.read (Word.ofNat (before.registers.pc.toNat + 1))
    FlatAdapter.step (jrImmediate before opcode shape value true) =
      jrInternal before opcode shape value := by
  rcases isJr with rfl | ⟨condition, rfl⟩ <;>
    simp [FlatAdapter.step, jrImmediate, jrImmediateCore, jrInternal,
      jrInternalCore, baseFetchedCore, Pipeline.taken,
      Cycle.physicalSchedule, Cycle.logicalSchedule, CoreState.currentOp?,
      Run.stepMachineCycle, Run.intent, Run.opFetch, Run.opCommit,
      Run.opPoll, Run.opControl, Run.opAddress, Run.internalAddress,
      Run.opReadKind, Run.opIdu, Run.processNonFetch, FlatAdapter.event]

set_option maxHeartbeats 3000000 in
/-- Universal refinement for unconditional JR. -/
theorem jr_refines (before : FunctionalState) (opcode : Byte)
    (running : before.mode = .running) (noHaltBug : before.haltBug = false)
    (atPC : before.memory.read before.registers.pc = opcode)
    (decoded : Decode.base opcode = .legal .jr) :
    let logical := Functional.step before 0
    let physical := FlatAdapter.run 4 (physicalInitial before) noInterrupts
    Retirement.Snapshot.atBoundary physical.core =
        Retirement.Snapshot.ofFunctional logical.state ∧
      physical.memory = logical.state.memory ∧
      physical.trace.dropLast = logical.trace := by
  rw [show FlatAdapter.run 4 (physicalInitial before) noInterrupts =
      FlatAdapter.step (FlatAdapter.step (FlatAdapter.step
        (FlatAdapter.step (physicalInitial before)))) by rfl]
  rw [fetch_legal before opcode .jr atPC noHaltBug decoded]
  rw [step_jr_immediate before opcode]
  rw [step_jr_internal before opcode .jr (Or.inl rfl)]
  simp [Functional.step, running, atPC, decoded, noHaltBug, jrInternal,
    jrInternalCore, jrImmediateCore, baseFetchedCore, Pipeline.taken,
    Cycle.physicalSchedule, Cycle.logicalSchedule, FlatAdapter.step,
    CoreState.currentOp?, Run.stepMachineCycle, Run.intent, Run.opFetch,
    Run.opCommit, Run.opPoll, Run.opControl, Run.opAddress,
    Run.successorAddress, Run.opReadKind, Run.opIdu, Run.finishSuccessor,
    Run.commitRegisters, Run.commitIme, Functional.fetchImmediate,
    Functional.read, Functional.immediate8, InstructionShape.immediateBytes,
    Functional.executeShape, Functional.idle, Functional.withRegisters,
    Functional.matureIme, increment_twice, FlatAdapter.event]
  all_goals cases before.scheduledImeEnable <;>
    simp [Retirement.Snapshot.atBoundary, Retirement.Snapshot.ofFunctional]

set_option maxHeartbeats 3000000 in
/-- Universal refinement for every taken conditional JR. -/
theorem jr_cond_taken_refines (before : FunctionalState) (opcode : Byte)
    (condition : Condition) (running : before.mode = .running)
    (noHaltBug : before.haltBug = false)
    (atPC : before.memory.read before.registers.pc = opcode)
    (decoded : Decode.base opcode = .legal (.jrCond condition))
    (taken : Alu.conditionHolds condition before.registers.flags = true) :
    let logical := Functional.step before 0
    let physical := FlatAdapter.run 4 (physicalInitial before) noInterrupts
    Retirement.Snapshot.atBoundary physical.core =
        Retirement.Snapshot.ofFunctional logical.state ∧
      physical.memory = logical.state.memory ∧
      physical.trace.dropLast = logical.trace := by
  rw [show FlatAdapter.run 4 (physicalInitial before) noInterrupts =
      FlatAdapter.step (FlatAdapter.step (FlatAdapter.step
        (FlatAdapter.step (physicalInitial before)))) by rfl]
  rw [fetch_legal before opcode (.jrCond condition) atPC noHaltBug decoded]
  rw [step_jr_cond_immediate before opcode condition true taken]
  rw [step_jr_internal before opcode (.jrCond condition) (Or.inr ⟨condition, rfl⟩)]
  cases condition <;>
    simp_all [Functional.step, jrInternal,
      jrInternalCore, jrImmediateCore, baseFetchedCore, Pipeline.taken,
      Cycle.physicalSchedule, Cycle.logicalSchedule, FlatAdapter.step,
      CoreState.currentOp?, Run.stepMachineCycle, Run.intent, Run.opFetch,
      Run.opCommit, Run.opPoll, Run.opControl, Run.opAddress,
      Run.successorAddress, Run.opReadKind, Run.opIdu, Run.finishSuccessor,
      Run.commitRegisters, Run.commitIme, Functional.fetchImmediate,
      Functional.read, Functional.immediate8, InstructionShape.immediateBytes,
      Functional.executeShape, Functional.idle, Functional.withRegisters,
      Functional.matureIme, Alu.conditionHolds, increment_twice,
      FlatAdapter.event]
  all_goals cases before.scheduledImeEnable <;>
    simp [Retirement.Snapshot.atBoundary, Retirement.Snapshot.ofFunctional]

set_option maxHeartbeats 3000000 in
/-- Universal refinement for every untaken conditional JR. -/
theorem jr_cond_untaken_refines (before : FunctionalState) (opcode : Byte)
    (condition : Condition) (running : before.mode = .running)
    (noHaltBug : before.haltBug = false)
    (atPC : before.memory.read before.registers.pc = opcode)
    (decoded : Decode.base opcode = .legal (.jrCond condition))
    (untaken : Alu.conditionHolds condition before.registers.flags = false) :
    let logical := Functional.step before 0
    let physical := FlatAdapter.run 3 (physicalInitial before) noInterrupts
    Retirement.Snapshot.atBoundary physical.core =
        Retirement.Snapshot.ofFunctional logical.state ∧
      physical.memory = logical.state.memory ∧
      physical.trace.dropLast = logical.trace := by
  rw [show FlatAdapter.run 3 (physicalInitial before) noInterrupts =
      FlatAdapter.step (FlatAdapter.step (FlatAdapter.step (physicalInitial before))) by rfl]
  rw [fetch_legal before opcode (.jrCond condition) atPC noHaltBug decoded]
  rw [step_jr_cond_immediate before opcode condition false untaken]
  cases condition <;>
    simp_all [Functional.step, jrImmediate,
      jrImmediateCore, baseFetchedCore, Pipeline.taken,
      Cycle.physicalSchedule, Cycle.logicalSchedule, FlatAdapter.step,
      CoreState.currentOp?, Run.stepMachineCycle, Run.intent, Run.opFetch,
      Run.opCommit, Run.opPoll, Run.opControl, Run.opAddress,
      Run.successorAddress, Run.opReadKind, Run.opIdu, Run.finishSuccessor,
      Run.commitRegisters, Run.commitIme, Functional.fetchImmediate,
      Functional.read, InstructionShape.immediateBytes,
      Functional.executeShape, Functional.withRegisters,
      Functional.matureIme, Alu.conditionHolds, increment_twice,
      FlatAdapter.event]
  all_goals cases before.scheduledImeEnable <;>
    simp [Retirement.Snapshot.atBoundary, Retirement.Snapshot.ofFunctional]

/-- JP and CALL families sharing a two-byte immediate prefix. -/
inductive Control16Shape : InstructionShape → Prop where
  | jp : Control16Shape .jp
  | jpCond (condition : Condition) : Control16Shape (.jpCond condition)
  | call : Control16Shape .call
  | callCond (condition : Condition) : Control16Shape (.callCond condition)

private def controlTail (shape : InstructionShape) (taken : Bool) : List MicroOp :=
  if !taken then [.successorFetch]
  else match shape with
    | .jp | .jpCond _ => [.internal, .successorFetch]
    | .call | .callCond _ =>
        [.stackInitialDecrement, .stackWriteHigh, .stackWriteLow, .successorFetch]
    | _ => [.successorFetch]

private def controlLowCore (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (low : Byte) (taken : Bool) : CoreState :=
  let core := baseFetchedCore state opcode shape
  { core with
    registers := { state.registers with pc := Word.ofNat (state.registers.pc.toNat + 2) }
    remaining := .immediateHigh :: controlTail shape taken
    latches := { core.latches with low := low, conditionTaken := taken } }

private def controlLow (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (low : Byte) (taken : Bool) : FlatCoreState :=
  { core := controlLowCore state opcode shape low taken
    memory := state.memory
    trace := [.read .opcode state.registers.pc opcode,
      .read .immediate (Word.ofNat (state.registers.pc.toNat + 1)) low] }

private def controlHighCore (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (low high : Byte) (taken : Bool) : CoreState :=
  { controlLowCore state opcode shape low taken with
    registers := { state.registers with pc := Word.ofNat (state.registers.pc.toNat + 3) }
    remaining := controlTail shape taken
    latches := { low, high, conditionTaken := taken } }

private def controlHigh (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (low high : Byte) (taken : Bool) : FlatCoreState :=
  { core := controlHighCore state opcode shape low high taken
    memory := state.memory
    trace := [.read .opcode state.registers.pc opcode,
      .read .immediate (Word.ofNat (state.registers.pc.toNat + 1)) low,
      .read .immediate (Word.ofNat (state.registers.pc.toNat + 2)) high] }

private theorem step_control_low (before : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (family : Control16Shape shape) (taken : Bool)
    (h : Pipeline.taken shape before.registers.flags = taken) :
    FlatAdapter.step (baseFetched before opcode shape) =
      controlLow before opcode shape
        (before.memory.read (Word.ofNat (before.registers.pc.toNat + 1))) taken := by
  cases family <;> cases taken <;>
    simp_all [FlatAdapter.step, baseFetched, baseFetchedCore, controlLow,
      controlLowCore, controlTail, Pipeline.taken, Cycle.physicalSchedule,
      Cycle.logicalSchedule, CoreState.currentOp?, Run.stepMachineCycle,
      Run.intent, Run.opFetch, Run.opCommit, Run.opPoll, Run.opControl,
      Run.opAddress, Run.opReadKind, Run.opIdu, Run.processNonFetch,
      Alu.conditionHolds, increment_twice, FlatAdapter.event]

private theorem step_control_high (before : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (family : Control16Shape shape) (taken : Bool) :
    let low := before.memory.read (Word.ofNat (before.registers.pc.toNat + 1))
    FlatAdapter.step (controlLow before opcode shape low taken) =
      controlHigh before opcode shape low
        (before.memory.read (Word.ofNat (before.registers.pc.toNat + 2))) taken := by
  cases family <;> cases taken <;>
    simp [FlatAdapter.step, controlLow, controlLowCore, controlHigh,
      controlHighCore, controlTail, baseFetchedCore, Pipeline.taken,
      Cycle.physicalSchedule, Cycle.logicalSchedule, CoreState.currentOp?,
      Run.stepMachineCycle, Run.intent, Run.opFetch, Run.opCommit,
      Run.opPoll, Run.opControl, Run.opAddress, Run.opReadKind, Run.opIdu,
      Run.processNonFetch, increment_thrice, FlatAdapter.event]

private def jpInternalCore (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (low high : Byte) : CoreState :=
  { controlHighCore state opcode shape low high true with
    remaining := [.successorFetch] }

private def jpInternal (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (low high : Byte) : FlatCoreState :=
  { core := jpInternalCore state opcode shape low high
    memory := state.memory
    trace := [.read .opcode state.registers.pc opcode,
      .read .immediate (Word.ofNat (state.registers.pc.toNat + 1)) low,
      .read .immediate (Word.ofNat (state.registers.pc.toNat + 2)) high,
      .idle (Word.ofBytes high low)] }

private theorem step_jp_internal (before : FunctionalState) (opcode : Byte)
    (shape : InstructionShape)
    (isJp : shape = .jp ∨ ∃ condition, shape = .jpCond condition) :
    let low := before.memory.read (Word.ofNat (before.registers.pc.toNat + 1))
    let high := before.memory.read (Word.ofNat (before.registers.pc.toNat + 2))
    FlatAdapter.step (controlHigh before opcode shape low high true) =
      jpInternal before opcode shape low high := by
  rcases isJp with rfl | ⟨condition, rfl⟩ <;>
    simp [FlatAdapter.step, controlHigh, controlHighCore, controlLowCore,
      controlTail, jpInternal, jpInternalCore, baseFetchedCore,
      Pipeline.taken, Cycle.physicalSchedule, Cycle.logicalSchedule,
      CoreState.currentOp?, Run.stepMachineCycle, Run.intent, Run.opFetch,
      Run.opCommit, Run.opPoll, Run.opControl, Run.opAddress,
      Run.internalAddress, Run.opReadKind, Run.opIdu, Run.processNonFetch,
      CoreState.wz, FlatAdapter.event]

set_option maxHeartbeats 3000000 in
/-- Universal refinement for unconditional JP. -/
theorem jp_refines (before : FunctionalState) (opcode : Byte)
    (running : before.mode = .running) (noHaltBug : before.haltBug = false)
    (atPC : before.memory.read before.registers.pc = opcode)
    (decoded : Decode.base opcode = .legal .jp) :
    let logical := Functional.step before 0
    let physical := FlatAdapter.run 5 (physicalInitial before) noInterrupts
    Retirement.Snapshot.atBoundary physical.core =
        Retirement.Snapshot.ofFunctional logical.state ∧
      physical.memory = logical.state.memory ∧
      physical.trace.dropLast = logical.trace := by
  rw [show FlatAdapter.run 5 (physicalInitial before) noInterrupts =
      FlatAdapter.step (FlatAdapter.step (FlatAdapter.step (FlatAdapter.step
        (FlatAdapter.step (physicalInitial before))))) by rfl]
  rw [fetch_legal before opcode .jp atPC noHaltBug decoded]
  rw [step_control_low before opcode .jp .jp true rfl]
  rw [step_control_high before opcode .jp .jp true]
  rw [step_jp_internal before opcode .jp (Or.inl rfl)]
  simp [Functional.step, running, atPC, decoded, noHaltBug, jpInternal,
    jpInternalCore, controlHighCore, controlLowCore, controlTail,
    baseFetchedCore, Pipeline.taken, Cycle.physicalSchedule,
    Cycle.logicalSchedule, FlatAdapter.step, CoreState.currentOp?,
    Run.stepMachineCycle, Run.intent, Run.opFetch, Run.opCommit,
    Run.opPoll, Run.opControl, Run.opAddress, Run.successorAddress,
    Run.opReadKind, Run.opIdu, Run.finishSuccessor, Run.commitRegisters,
    Run.commitIme, Functional.fetchImmediate, Functional.read,
    Functional.immediate16, InstructionShape.immediateBytes,
    Functional.executeShape, Functional.idle, Functional.withRegisters,
    Functional.matureIme, CoreState.wz, increment_twice, increment_thrice,
    FlatAdapter.event]
  all_goals cases before.scheduledImeEnable <;>
    simp [Retirement.Snapshot.atBoundary, Retirement.Snapshot.ofFunctional]

set_option maxHeartbeats 3000000 in
/-- Universal refinement for every taken conditional JP. -/
theorem jp_cond_taken_refines (before : FunctionalState) (opcode : Byte)
    (condition : Condition) (running : before.mode = .running)
    (noHaltBug : before.haltBug = false)
    (atPC : before.memory.read before.registers.pc = opcode)
    (decoded : Decode.base opcode = .legal (.jpCond condition))
    (taken : Alu.conditionHolds condition before.registers.flags = true) :
    let logical := Functional.step before 0
    let physical := FlatAdapter.run 5 (physicalInitial before) noInterrupts
    Retirement.Snapshot.atBoundary physical.core =
        Retirement.Snapshot.ofFunctional logical.state ∧
      physical.memory = logical.state.memory ∧
      physical.trace.dropLast = logical.trace := by
  rw [show FlatAdapter.run 5 (physicalInitial before) noInterrupts =
      FlatAdapter.step (FlatAdapter.step (FlatAdapter.step (FlatAdapter.step
        (FlatAdapter.step (physicalInitial before))))) by rfl]
  rw [fetch_legal before opcode (.jpCond condition) atPC noHaltBug decoded]
  have physicalTaken : Pipeline.taken (.jpCond condition) before.registers.flags = true := by
    simpa [Pipeline.taken] using taken
  rw [step_control_low before opcode (.jpCond condition) (.jpCond condition) true physicalTaken]
  rw [step_control_high before opcode (.jpCond condition) (.jpCond condition) true]
  rw [step_jp_internal before opcode (.jpCond condition) (Or.inr ⟨condition, rfl⟩)]
  cases condition <;>
    simp_all [Functional.step, jpInternal, jpInternalCore, controlHighCore,
      controlLowCore, controlTail, baseFetchedCore, Pipeline.taken,
      Cycle.physicalSchedule, Cycle.logicalSchedule, FlatAdapter.step,
      CoreState.currentOp?, Run.stepMachineCycle, Run.intent, Run.opFetch,
      Run.opCommit, Run.opPoll, Run.opControl, Run.opAddress,
      Run.successorAddress, Run.opReadKind, Run.opIdu, Run.finishSuccessor,
      Run.commitRegisters, Run.commitIme, Functional.fetchImmediate,
      Functional.read, Functional.immediate16, InstructionShape.immediateBytes,
      Functional.executeShape, Functional.idle, Functional.withRegisters,
      Functional.matureIme, Alu.conditionHolds, CoreState.wz,
      increment_twice, increment_thrice, FlatAdapter.event]
  all_goals cases before.scheduledImeEnable <;>
    simp [Retirement.Snapshot.atBoundary, Retirement.Snapshot.ofFunctional]

set_option maxHeartbeats 3000000 in
/-- Universal refinement for every untaken conditional JP. -/
theorem jp_cond_untaken_refines (before : FunctionalState) (opcode : Byte)
    (condition : Condition) (running : before.mode = .running)
    (noHaltBug : before.haltBug = false)
    (atPC : before.memory.read before.registers.pc = opcode)
    (decoded : Decode.base opcode = .legal (.jpCond condition))
    (untaken : Alu.conditionHolds condition before.registers.flags = false) :
    let logical := Functional.step before 0
    let physical := FlatAdapter.run 4 (physicalInitial before) noInterrupts
    Retirement.Snapshot.atBoundary physical.core =
        Retirement.Snapshot.ofFunctional logical.state ∧
      physical.memory = logical.state.memory ∧
      physical.trace.dropLast = logical.trace := by
  rw [show FlatAdapter.run 4 (physicalInitial before) noInterrupts =
      FlatAdapter.step (FlatAdapter.step (FlatAdapter.step
        (FlatAdapter.step (physicalInitial before)))) by rfl]
  rw [fetch_legal before opcode (.jpCond condition) atPC noHaltBug decoded]
  have physicalUntaken : Pipeline.taken (.jpCond condition) before.registers.flags = false := by
    simpa [Pipeline.taken] using untaken
  rw [step_control_low before opcode (.jpCond condition) (.jpCond condition) false physicalUntaken]
  rw [step_control_high before opcode (.jpCond condition) (.jpCond condition) false]
  cases condition <;>
    simp_all [Functional.step, controlHigh, controlHighCore, controlLowCore,
      controlTail, baseFetchedCore, Pipeline.taken, Cycle.physicalSchedule,
      Cycle.logicalSchedule, FlatAdapter.step, CoreState.currentOp?,
      Run.stepMachineCycle, Run.intent, Run.opFetch, Run.opCommit,
      Run.opPoll, Run.opControl, Run.opAddress, Run.successorAddress,
      Run.opReadKind, Run.opIdu, Run.finishSuccessor, Run.commitRegisters,
      Run.commitIme, Functional.fetchImmediate, Functional.read,
      InstructionShape.immediateBytes, Functional.executeShape,
      Functional.withRegisters, Functional.matureIme, Alu.conditionHolds,
      increment_twice, increment_thrice,
      FlatAdapter.event]
  all_goals cases before.scheduledImeEnable <;>
    simp [Retirement.Snapshot.atBoundary, Retirement.Snapshot.ofFunctional]

private def callStackInitialCore (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (low high : Byte) : CoreState :=
  let core := controlHighCore state opcode shape low high true
  { core with
    registers := { core.registers with sp := Word.ofNat (state.registers.sp.toNat + 65535) }
    remaining := [.stackWriteHigh, .stackWriteLow, .successorFetch] }

private def callStackInitial (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (low high : Byte) : FlatCoreState :=
  { core := callStackInitialCore state opcode shape low high
    memory := state.memory
    trace := [.read .opcode state.registers.pc opcode,
      .read .immediate (Word.ofNat (state.registers.pc.toNat + 1)) low,
      .read .immediate (Word.ofNat (state.registers.pc.toNat + 2)) high,
      .idle state.registers.sp] }

private def callStackHighCore (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (low high : Byte) : CoreState :=
  let core := callStackInitialCore state opcode shape low high
  { core with
    registers := { core.registers with sp := Word.ofNat (state.registers.sp.toNat + 65534) }
    remaining := [.stackWriteLow, .successorFetch] }

private def callStackHigh (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (low high : Byte) : FlatCoreState :=
  let returnPC := Word.ofNat (state.registers.pc.toNat + 3)
  let address := Word.ofNat (state.registers.sp.toNat + 65535)
  { core := callStackHighCore state opcode shape low high
    memory := state.memory.write address returnPC.highByte
    trace := [.read .opcode state.registers.pc opcode,
      .read .immediate (Word.ofNat (state.registers.pc.toNat + 1)) low,
      .read .immediate (Word.ofNat (state.registers.pc.toNat + 2)) high,
      .idle state.registers.sp, .write address returnPC.highByte] }

private def callStackLowCore (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (low high : Byte) : CoreState :=
  { callStackHighCore state opcode shape low high with remaining := [.successorFetch] }

private def callStackLow (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (low high : Byte) : FlatCoreState :=
  let returnPC := Word.ofNat (state.registers.pc.toNat + 3)
  let highAddress := Word.ofNat (state.registers.sp.toNat + 65535)
  let lowAddress := Word.ofNat (state.registers.sp.toNat + 65534)
  { core := callStackLowCore state opcode shape low high
    memory := (state.memory.write highAddress returnPC.highByte).write
      lowAddress returnPC.lowByte
    trace := [.read .opcode state.registers.pc opcode,
      .read .immediate (Word.ofNat (state.registers.pc.toNat + 1)) low,
      .read .immediate (Word.ofNat (state.registers.pc.toNat + 2)) high,
      .idle state.registers.sp, .write highAddress returnPC.highByte,
      .write lowAddress returnPC.lowByte] }

private theorem step_call_stack_initial (before : FunctionalState) (opcode : Byte)
    (shape : InstructionShape)
    (isCall : shape = .call ∨ ∃ condition, shape = .callCond condition) :
    let low := before.memory.read (Word.ofNat (before.registers.pc.toNat + 1))
    let high := before.memory.read (Word.ofNat (before.registers.pc.toNat + 2))
    FlatAdapter.step (controlHigh before opcode shape low high true) =
      callStackInitial before opcode shape low high := by
  rcases isCall with rfl | ⟨condition, rfl⟩ <;>
    simp [FlatAdapter.step, controlHigh, controlHighCore, controlLowCore,
      controlTail, callStackInitial, callStackInitialCore, baseFetchedCore,
      Pipeline.taken, Cycle.physicalSchedule, Cycle.logicalSchedule,
      CoreState.currentOp?, Run.stepMachineCycle, Run.intent, Run.opFetch,
      Run.opCommit, Run.opPoll, Run.opControl, Run.opAddress,
      Run.opReadKind, Run.opIdu, Run.processNonFetch, FlatAdapter.event]

private theorem step_call_stack_high (before : FunctionalState) (opcode : Byte)
    (shape : InstructionShape)
    (isCall : shape = .call ∨ ∃ condition, shape = .callCond condition) :
    let low := before.memory.read (Word.ofNat (before.registers.pc.toNat + 1))
    let high := before.memory.read (Word.ofNat (before.registers.pc.toNat + 2))
    FlatAdapter.step (callStackInitial before opcode shape low high) =
      callStackHigh before opcode shape low high := by
  rcases isCall with rfl | ⟨condition, rfl⟩ <;>
    simp [FlatAdapter.step, callStackInitial, callStackInitialCore,
      callStackHigh, callStackHighCore, controlHighCore, controlLowCore,
      controlTail, baseFetchedCore, Pipeline.taken, Cycle.physicalSchedule,
      Cycle.logicalSchedule, CoreState.currentOp?, Run.stepMachineCycle,
      Run.intent, Run.opFetch, Run.opCommit, Run.opPoll, Run.opControl,
      Run.opAddress, Run.opReadKind, Run.opIdu, Run.processNonFetch,
      Run.writeValue, decrement_twice, FlatAdapter.event]

private theorem step_call_stack_low (before : FunctionalState) (opcode : Byte)
    (shape : InstructionShape)
    (isCall : shape = .call ∨ ∃ condition, shape = .callCond condition) :
    let low := before.memory.read (Word.ofNat (before.registers.pc.toNat + 1))
    let high := before.memory.read (Word.ofNat (before.registers.pc.toNat + 2))
    FlatAdapter.step (callStackHigh before opcode shape low high) =
      callStackLow before opcode shape low high := by
  rcases isCall with rfl | ⟨condition, rfl⟩ <;>
    simp [FlatAdapter.step, callStackHigh, callStackHighCore,
      callStackLow, callStackLowCore, callStackInitialCore,
      controlHighCore, controlLowCore, controlTail, baseFetchedCore,
      Pipeline.taken, Cycle.physicalSchedule, Cycle.logicalSchedule,
      CoreState.currentOp?, Run.stepMachineCycle, Run.intent, Run.opFetch,
      Run.opCommit, Run.opPoll, Run.opControl, Run.opAddress,
      Run.opReadKind, Run.opIdu, Run.processNonFetch, Run.writeValue,
      FlatAdapter.event]

set_option maxHeartbeats 3000000 in
/-- Universal refinement for unconditional CALL. -/
theorem call_refines (before : FunctionalState) (opcode : Byte)
    (running : before.mode = .running) (noHaltBug : before.haltBug = false)
    (atPC : before.memory.read before.registers.pc = opcode)
    (decoded : Decode.base opcode = .legal .call) :
    let logical := Functional.step before 0
    let physical := FlatAdapter.run 7 (physicalInitial before) noInterrupts
    Retirement.Snapshot.atBoundary physical.core =
        Retirement.Snapshot.ofFunctional logical.state ∧
      physical.memory = logical.state.memory ∧
      physical.trace.dropLast = logical.trace := by
  rw [show FlatAdapter.run 7 (physicalInitial before) noInterrupts =
      FlatAdapter.step (FlatAdapter.step (FlatAdapter.step (FlatAdapter.step
        (FlatAdapter.step (FlatAdapter.step
          (FlatAdapter.step (physicalInitial before))))))) by rfl]
  rw [fetch_legal before opcode .call atPC noHaltBug decoded]
  rw [step_control_low before opcode .call .call true rfl]
  rw [step_control_high before opcode .call .call true]
  rw [step_call_stack_initial before opcode .call (Or.inl rfl)]
  rw [step_call_stack_high before opcode .call (Or.inl rfl)]
  rw [step_call_stack_low before opcode .call (Or.inl rfl)]
  simp [Functional.step, running, atPC, decoded, noHaltBug, callStackLow,
    callStackLowCore, callStackHighCore, callStackInitialCore,
    controlHighCore, controlLowCore, controlTail, baseFetchedCore,
    Pipeline.taken, Cycle.physicalSchedule, Cycle.logicalSchedule,
    FlatAdapter.step, CoreState.currentOp?, Run.stepMachineCycle, Run.intent,
    Run.opFetch, Run.opCommit, Run.opPoll, Run.opControl, Run.opAddress,
    Run.successorAddress, Run.opReadKind, Run.opIdu, Run.finishSuccessor,
    Run.commitRegisters, Run.commitIme, Functional.fetchImmediate,
    Functional.read, Functional.immediate16, InstructionShape.immediateBytes,
    Functional.executeShape, Functional.pushWord, Functional.idle,
    Functional.write, Functional.withRegisters, Functional.decrementSP,
    Functional.matureIme, CoreState.wz, decrement_twice, increment_twice,
    increment_thrice, FlatAdapter.event]
  all_goals cases before.scheduledImeEnable <;>
    simp [Retirement.Snapshot.atBoundary, Retirement.Snapshot.ofFunctional]

set_option maxHeartbeats 3000000 in
/-- Universal refinement for every taken conditional CALL. -/
theorem call_cond_taken_refines (before : FunctionalState) (opcode : Byte)
    (condition : Condition) (running : before.mode = .running)
    (noHaltBug : before.haltBug = false)
    (atPC : before.memory.read before.registers.pc = opcode)
    (decoded : Decode.base opcode = .legal (.callCond condition))
    (taken : Alu.conditionHolds condition before.registers.flags = true) :
    let logical := Functional.step before 0
    let physical := FlatAdapter.run 7 (physicalInitial before) noInterrupts
    Retirement.Snapshot.atBoundary physical.core =
        Retirement.Snapshot.ofFunctional logical.state ∧
      physical.memory = logical.state.memory ∧
      physical.trace.dropLast = logical.trace := by
  rw [show FlatAdapter.run 7 (physicalInitial before) noInterrupts =
      FlatAdapter.step (FlatAdapter.step (FlatAdapter.step (FlatAdapter.step
        (FlatAdapter.step (FlatAdapter.step
          (FlatAdapter.step (physicalInitial before))))))) by rfl]
  rw [fetch_legal before opcode (.callCond condition) atPC noHaltBug decoded]
  have physicalTaken : Pipeline.taken (.callCond condition) before.registers.flags = true := by
    simpa [Pipeline.taken] using taken
  rw [step_control_low before opcode (.callCond condition) (.callCond condition) true physicalTaken]
  rw [step_control_high before opcode (.callCond condition) (.callCond condition) true]
  rw [step_call_stack_initial before opcode (.callCond condition) (Or.inr ⟨condition, rfl⟩)]
  rw [step_call_stack_high before opcode (.callCond condition) (Or.inr ⟨condition, rfl⟩)]
  rw [step_call_stack_low before opcode (.callCond condition) (Or.inr ⟨condition, rfl⟩)]
  cases condition <;>
    simp_all [Functional.step, callStackLow, callStackLowCore,
      callStackHighCore, callStackInitialCore, controlHighCore,
      controlLowCore, controlTail, baseFetchedCore, Pipeline.taken,
      Cycle.physicalSchedule, Cycle.logicalSchedule, FlatAdapter.step,
      CoreState.currentOp?, Run.stepMachineCycle, Run.intent, Run.opFetch,
      Run.opCommit, Run.opPoll, Run.opControl, Run.opAddress,
      Run.successorAddress, Run.opReadKind, Run.opIdu, Run.finishSuccessor,
      Run.commitRegisters, Run.commitIme, Functional.fetchImmediate,
      Functional.read, Functional.immediate16, InstructionShape.immediateBytes,
      Functional.executeShape, Functional.pushWord, Functional.idle,
      Functional.write, Functional.withRegisters, Functional.decrementSP,
      Functional.matureIme, Alu.conditionHolds, CoreState.wz,
      decrement_twice, increment_twice, increment_thrice, FlatAdapter.event]
  all_goals cases before.scheduledImeEnable <;>
    simp [Retirement.Snapshot.atBoundary, Retirement.Snapshot.ofFunctional]

set_option maxHeartbeats 3000000 in
/-- Universal refinement for every untaken conditional CALL. -/
theorem call_cond_untaken_refines (before : FunctionalState) (opcode : Byte)
    (condition : Condition) (running : before.mode = .running)
    (noHaltBug : before.haltBug = false)
    (atPC : before.memory.read before.registers.pc = opcode)
    (decoded : Decode.base opcode = .legal (.callCond condition))
    (untaken : Alu.conditionHolds condition before.registers.flags = false) :
    let logical := Functional.step before 0
    let physical := FlatAdapter.run 4 (physicalInitial before) noInterrupts
    Retirement.Snapshot.atBoundary physical.core =
        Retirement.Snapshot.ofFunctional logical.state ∧
      physical.memory = logical.state.memory ∧
      physical.trace.dropLast = logical.trace := by
  rw [show FlatAdapter.run 4 (physicalInitial before) noInterrupts =
      FlatAdapter.step (FlatAdapter.step (FlatAdapter.step
        (FlatAdapter.step (physicalInitial before)))) by rfl]
  rw [fetch_legal before opcode (.callCond condition) atPC noHaltBug decoded]
  have physicalUntaken : Pipeline.taken (.callCond condition) before.registers.flags = false := by
    simpa [Pipeline.taken] using untaken
  rw [step_control_low before opcode (.callCond condition) (.callCond condition) false physicalUntaken]
  rw [step_control_high before opcode (.callCond condition) (.callCond condition) false]
  cases condition <;>
    simp_all [Functional.step, controlHigh, controlHighCore, controlLowCore,
      controlTail, baseFetchedCore, Pipeline.taken, Cycle.physicalSchedule,
      Cycle.logicalSchedule, FlatAdapter.step, CoreState.currentOp?,
      Run.stepMachineCycle, Run.intent, Run.opFetch, Run.opCommit,
      Run.opPoll, Run.opControl, Run.opAddress, Run.successorAddress,
      Run.opReadKind, Run.opIdu, Run.finishSuccessor, Run.commitRegisters,
      Run.commitIme, Functional.fetchImmediate, Functional.read,
      InstructionShape.immediateBytes, Functional.executeShape,
      Functional.withRegisters, Functional.matureIme, Alu.conditionHolds,
      increment_twice, increment_thrice, FlatAdapter.event]
  all_goals cases before.scheduledImeEnable <;>
    simp [Retirement.Snapshot.atBoundary, Retirement.Snapshot.ofFunctional]

inductive ReturnShape : InstructionShape → Prop where
  | ret : ReturnShape .ret
  | reti : ReturnShape .reti

private def returnLowCore (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (low : Byte) : CoreState :=
  { baseFetchedCore state opcode shape with
    registers := { (baseFetchedCore state opcode shape).registers with
      sp := Word.ofNat (state.registers.sp.toNat + 1) }
    remaining := [.stackReadHigh, .internal, .successorFetch]
    latches := { low, conditionTaken := true } }

private def returnLow (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (low : Byte) : FlatCoreState :=
  { core := returnLowCore state opcode shape low
    memory := state.memory
    trace := [.read .opcode state.registers.pc opcode,
      .read .stack state.registers.sp low] }

private def returnHighCore (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (low high : Byte) : CoreState :=
  { returnLowCore state opcode shape low with
    registers := { (returnLowCore state opcode shape low).registers with
      sp := Word.ofNat (state.registers.sp.toNat + 2) }
    remaining := [.internal, .successorFetch]
    latches := { low, high, conditionTaken := true } }

private def returnHigh (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (low high : Byte) : FlatCoreState :=
  { core := returnHighCore state opcode shape low high
    memory := state.memory
    trace := [.read .opcode state.registers.pc opcode,
      .read .stack state.registers.sp low,
      .read .stack (Word.ofNat (state.registers.sp.toNat + 1)) high] }

private def returnInternalCore (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (low high : Byte) : CoreState :=
  { returnHighCore state opcode shape low high with remaining := [.successorFetch] }

private def returnInternal (state : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (low high : Byte) : FlatCoreState :=
  { core := returnInternalCore state opcode shape low high
    memory := state.memory
    trace := [.read .opcode state.registers.pc opcode,
      .read .stack state.registers.sp low,
      .read .stack (Word.ofNat (state.registers.sp.toNat + 1)) high,
      .idle (Word.ofBytes high low)] }

private theorem step_return_low (before : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (family : ReturnShape shape) :
    FlatAdapter.step (baseFetched before opcode shape) =
      returnLow before opcode shape (before.memory.read before.registers.sp) := by
  cases family <;>
    simp [FlatAdapter.step, baseFetched, baseFetchedCore, returnLow,
      returnLowCore, Pipeline.taken, Cycle.physicalSchedule,
      Cycle.logicalSchedule, CoreState.currentOp?, Run.stepMachineCycle,
      Run.intent, Run.opFetch, Run.opCommit, Run.opPoll, Run.opControl,
      Run.opAddress, Run.opReadKind, Run.opIdu, Run.processNonFetch,
      FlatAdapter.event]

private theorem step_return_high (before : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (family : ReturnShape shape) :
    let low := before.memory.read before.registers.sp
    FlatAdapter.step (returnLow before opcode shape low) =
      returnHigh before opcode shape low
        (before.memory.read (Word.ofNat (before.registers.sp.toNat + 1))) := by
  cases family <;>
    simp [FlatAdapter.step, returnLow, returnLowCore, returnHigh,
      returnHighCore, baseFetchedCore, Pipeline.taken,
      Cycle.physicalSchedule, Cycle.logicalSchedule, CoreState.currentOp?,
      Run.stepMachineCycle, Run.intent, Run.opFetch, Run.opCommit,
      Run.opPoll, Run.opControl, Run.opAddress, Run.opReadKind, Run.opIdu,
      Run.processNonFetch, increment_twice, FlatAdapter.event]

private theorem step_return_internal (before : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (family : ReturnShape shape) :
    let low := before.memory.read before.registers.sp
    let high := before.memory.read (Word.ofNat (before.registers.sp.toNat + 1))
    FlatAdapter.step (returnHigh before opcode shape low high) =
      returnInternal before opcode shape low high := by
  cases family <;>
    simp [FlatAdapter.step, returnHigh, returnHighCore, returnLowCore,
      returnInternal, returnInternalCore, baseFetchedCore, Pipeline.taken,
      Cycle.physicalSchedule, Cycle.logicalSchedule, CoreState.currentOp?,
      Run.stepMachineCycle, Run.intent, Run.opFetch, Run.opCommit,
      Run.opPoll, Run.opControl, Run.opAddress, Run.internalAddress,
      Run.opReadKind, Run.opIdu, Run.processNonFetch, CoreState.wz,
      FlatAdapter.event]

set_option maxHeartbeats 3000000 in
/-- Universal refinement for RET and RETI. -/
theorem return_refines (before : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (family : ReturnShape shape)
    (running : before.mode = .running) (noHaltBug : before.haltBug = false)
    (atPC : before.memory.read before.registers.pc = opcode)
    (decoded : Decode.base opcode = .legal shape) :
    let logical := Functional.step before 0
    let physical := FlatAdapter.run 5 (physicalInitial before) noInterrupts
    Retirement.Snapshot.atBoundary physical.core =
        Retirement.Snapshot.ofFunctional logical.state ∧
      physical.memory = logical.state.memory ∧
      physical.trace.dropLast = logical.trace := by
  rw [show FlatAdapter.run 5 (physicalInitial before) noInterrupts =
      FlatAdapter.step (FlatAdapter.step (FlatAdapter.step (FlatAdapter.step
        (FlatAdapter.step (physicalInitial before))))) by rfl]
  rw [fetch_legal before opcode shape atPC noHaltBug decoded]
  rw [step_return_low before opcode shape family]
  rw [step_return_high before opcode shape family]
  rw [step_return_internal before opcode shape family]
  cases family <;>
    simp [Functional.step, running, atPC, decoded, noHaltBug,
      returnInternal, returnInternalCore, returnHighCore, returnLowCore,
      baseFetchedCore, Pipeline.taken, Cycle.physicalSchedule,
      Cycle.logicalSchedule, FlatAdapter.step, CoreState.currentOp?,
      Run.stepMachineCycle, Run.intent, Run.opFetch, Run.opCommit,
      Run.opPoll, Run.opControl, Run.opAddress, Run.successorAddress,
      Run.opReadKind, Run.opIdu, Run.finishSuccessor, Run.commitRegisters,
      Run.commitIme, Functional.fetchImmediate, InstructionShape.immediateBytes,
      Functional.executeShape, Functional.popWord, Functional.incrementSP,
      Functional.read, Functional.idle, Functional.withRegisters,
      Functional.matureIme, CoreState.wz, increment_twice,
      FlatAdapter.event]
  all_goals cases before.scheduledImeEnable <;>
    simp [Retirement.Snapshot.atBoundary, Retirement.Snapshot.ofFunctional]

private def retCondStartedCore (state : FunctionalState) (opcode : Byte)
    (condition : Condition) (taken : Bool) : CoreState :=
  { baseFetchedCore state opcode (.retCond condition) with
    remaining := if taken then
      [.stackReadLow, .stackReadHigh, .internal, .successorFetch]
      else [.successorFetch]
    latches := { conditionTaken := taken } }

private def retCondStarted (state : FunctionalState) (opcode : Byte)
    (condition : Condition) (taken : Bool) : FlatCoreState :=
  { core := retCondStartedCore state opcode condition taken
    memory := state.memory
    trace := [.read .opcode state.registers.pc opcode, .idle state.registers.sp] }

private theorem step_ret_cond_start (before : FunctionalState) (opcode : Byte)
    (condition : Condition) (taken : Bool)
    (h : Alu.conditionHolds condition before.registers.flags = taken) :
    FlatAdapter.step (baseFetched before opcode (.retCond condition)) =
      retCondStarted before opcode condition taken := by
  cases condition <;> cases taken <;>
    simp_all [FlatAdapter.step, baseFetched, baseFetchedCore, retCondStarted,
      retCondStartedCore, Pipeline.taken, Cycle.physicalSchedule,
      Cycle.logicalSchedule, CoreState.currentOp?, Run.stepMachineCycle,
      Run.intent, Run.opFetch, Run.opCommit, Run.opPoll, Run.opControl,
      Run.opAddress, Run.internalAddress, Run.opReadKind, Run.opIdu,
      Run.processNonFetch, Alu.conditionHolds, FlatAdapter.event]

private def retCondLowCore (state : FunctionalState) (opcode : Byte)
    (condition : Condition) (low : Byte) : CoreState :=
  { retCondStartedCore state opcode condition true with
    registers := { state.registers with
      sp := Word.ofNat (state.registers.sp.toNat + 1),
      pc := Word.ofNat (state.registers.pc.toNat + 1) }
    remaining := [.stackReadHigh, .internal, .successorFetch]
    latches := { low, conditionTaken := true } }

private def retCondLow (state : FunctionalState) (opcode : Byte)
    (condition : Condition) (low : Byte) : FlatCoreState :=
  { core := retCondLowCore state opcode condition low
    memory := state.memory
    trace := [.read .opcode state.registers.pc opcode, .idle state.registers.sp,
      .read .stack state.registers.sp low] }

private def retCondHighCore (state : FunctionalState) (opcode : Byte)
    (condition : Condition) (low high : Byte) : CoreState :=
  { retCondLowCore state opcode condition low with
    registers := { state.registers with
      sp := Word.ofNat (state.registers.sp.toNat + 2),
      pc := Word.ofNat (state.registers.pc.toNat + 1) }
    remaining := [.internal, .successorFetch]
    latches := { low, high, conditionTaken := true } }

private def retCondHigh (state : FunctionalState) (opcode : Byte)
    (condition : Condition) (low high : Byte) : FlatCoreState :=
  { core := retCondHighCore state opcode condition low high
    memory := state.memory
    trace := [.read .opcode state.registers.pc opcode, .idle state.registers.sp,
      .read .stack state.registers.sp low,
      .read .stack (Word.ofNat (state.registers.sp.toNat + 1)) high] }

private def retCondInternalCore (state : FunctionalState) (opcode : Byte)
    (condition : Condition) (low high : Byte) : CoreState :=
  { retCondHighCore state opcode condition low high with remaining := [.successorFetch] }

private def retCondInternal (state : FunctionalState) (opcode : Byte)
    (condition : Condition) (low high : Byte) : FlatCoreState :=
  { core := retCondInternalCore state opcode condition low high
    memory := state.memory
    trace := [.read .opcode state.registers.pc opcode, .idle state.registers.sp,
      .read .stack state.registers.sp low,
      .read .stack (Word.ofNat (state.registers.sp.toNat + 1)) high,
      .idle (Word.ofBytes high low)] }

private theorem step_ret_cond_low (before : FunctionalState) (opcode : Byte)
    (condition : Condition) :
    FlatAdapter.step (retCondStarted before opcode condition true) =
      retCondLow before opcode condition (before.memory.read before.registers.sp) := by
  cases condition <;>
    simp [FlatAdapter.step, retCondStarted, retCondStartedCore, retCondLow,
      retCondLowCore, baseFetchedCore, Pipeline.taken,
      Cycle.physicalSchedule, Cycle.logicalSchedule, CoreState.currentOp?,
      Run.stepMachineCycle, Run.intent, Run.opFetch, Run.opCommit,
      Run.opPoll, Run.opControl, Run.opAddress, Run.opReadKind, Run.opIdu,
      Run.processNonFetch, FlatAdapter.event]

private theorem step_ret_cond_high (before : FunctionalState) (opcode : Byte)
    (condition : Condition) :
    let low := before.memory.read before.registers.sp
    FlatAdapter.step (retCondLow before opcode condition low) =
      retCondHigh before opcode condition low
        (before.memory.read (Word.ofNat (before.registers.sp.toNat + 1))) := by
  cases condition <;>
    simp [FlatAdapter.step, retCondLow, retCondLowCore, retCondHigh,
      retCondHighCore, retCondStartedCore, baseFetchedCore, Pipeline.taken,
      Cycle.physicalSchedule, Cycle.logicalSchedule, CoreState.currentOp?,
      Run.stepMachineCycle, Run.intent, Run.opFetch, Run.opCommit,
      Run.opPoll, Run.opControl, Run.opAddress, Run.opReadKind, Run.opIdu,
      Run.processNonFetch, increment_twice, FlatAdapter.event]

private theorem step_ret_cond_internal (before : FunctionalState) (opcode : Byte)
    (condition : Condition) :
    let low := before.memory.read before.registers.sp
    let high := before.memory.read (Word.ofNat (before.registers.sp.toNat + 1))
    FlatAdapter.step (retCondHigh before opcode condition low high) =
      retCondInternal before opcode condition low high := by
  cases condition <;>
    simp [FlatAdapter.step, retCondHigh, retCondHighCore, retCondLowCore,
      retCondStartedCore, retCondInternal, retCondInternalCore,
      baseFetchedCore, Pipeline.taken, Cycle.physicalSchedule,
      Cycle.logicalSchedule, CoreState.currentOp?, Run.stepMachineCycle,
      Run.intent, Run.opFetch, Run.opCommit, Run.opPoll, Run.opControl,
      Run.opAddress, Run.internalAddress, Run.opReadKind, Run.opIdu,
      Run.processNonFetch, CoreState.wz, FlatAdapter.event]

set_option maxHeartbeats 3000000 in
/-- Universal refinement for every taken conditional RET. -/
theorem ret_cond_taken_refines (before : FunctionalState) (opcode : Byte)
    (condition : Condition) (running : before.mode = .running)
    (noHaltBug : before.haltBug = false)
    (atPC : before.memory.read before.registers.pc = opcode)
    (decoded : Decode.base opcode = .legal (.retCond condition))
    (taken : Alu.conditionHolds condition before.registers.flags = true) :
    let logical := Functional.step before 0
    let physical := FlatAdapter.run 6 (physicalInitial before) noInterrupts
    Retirement.Snapshot.atBoundary physical.core =
        Retirement.Snapshot.ofFunctional logical.state ∧
      physical.memory = logical.state.memory ∧
      physical.trace.dropLast = logical.trace := by
  rw [show FlatAdapter.run 6 (physicalInitial before) noInterrupts =
      FlatAdapter.step (FlatAdapter.step (FlatAdapter.step (FlatAdapter.step
        (FlatAdapter.step (FlatAdapter.step (physicalInitial before)))))) by rfl]
  rw [fetch_legal before opcode (.retCond condition) atPC noHaltBug decoded]
  rw [step_ret_cond_start before opcode condition true taken]
  rw [step_ret_cond_low before opcode condition]
  rw [step_ret_cond_high before opcode condition]
  rw [step_ret_cond_internal before opcode condition]
  cases condition <;>
    simp_all [Functional.step, retCondInternal, retCondInternalCore,
      retCondHighCore, retCondLowCore, retCondStartedCore, baseFetchedCore,
      Pipeline.taken, Cycle.physicalSchedule, Cycle.logicalSchedule,
      FlatAdapter.step, CoreState.currentOp?, Run.stepMachineCycle,
      Run.intent, Run.opFetch, Run.opCommit, Run.opPoll, Run.opControl,
      Run.opAddress, Run.successorAddress, Run.opReadKind, Run.opIdu,
      Run.finishSuccessor, Run.commitRegisters, Run.commitIme,
      Functional.fetchImmediate, InstructionShape.immediateBytes,
      Functional.executeShape, Functional.popWord, Functional.incrementSP,
      Functional.read, Functional.idle, Functional.withRegisters,
      Functional.matureIme, Alu.conditionHolds, CoreState.wz,
      increment_twice, FlatAdapter.event]
  all_goals cases before.scheduledImeEnable <;>
    simp [Retirement.Snapshot.atBoundary, Retirement.Snapshot.ofFunctional]

set_option maxHeartbeats 3000000 in
/-- Universal refinement for every untaken conditional RET. -/
theorem ret_cond_untaken_refines (before : FunctionalState) (opcode : Byte)
    (condition : Condition) (running : before.mode = .running)
    (noHaltBug : before.haltBug = false)
    (atPC : before.memory.read before.registers.pc = opcode)
    (decoded : Decode.base opcode = .legal (.retCond condition))
    (untaken : Alu.conditionHolds condition before.registers.flags = false) :
    let logical := Functional.step before 0
    let physical := FlatAdapter.run 3 (physicalInitial before) noInterrupts
    Retirement.Snapshot.atBoundary physical.core =
        Retirement.Snapshot.ofFunctional logical.state ∧
      physical.memory = logical.state.memory ∧
      physical.trace.dropLast = logical.trace := by
  rw [show FlatAdapter.run 3 (physicalInitial before) noInterrupts =
      FlatAdapter.step (FlatAdapter.step (FlatAdapter.step (physicalInitial before))) by rfl]
  rw [fetch_legal before opcode (.retCond condition) atPC noHaltBug decoded]
  rw [step_ret_cond_start before opcode condition false untaken]
  cases condition <;>
    simp_all [Functional.step, retCondStarted, retCondStartedCore,
      baseFetchedCore, Pipeline.taken, Cycle.physicalSchedule,
      Cycle.logicalSchedule, FlatAdapter.step, CoreState.currentOp?,
      Run.stepMachineCycle, Run.intent, Run.opFetch, Run.opCommit,
      Run.opPoll, Run.opControl, Run.opAddress, Run.successorAddress,
      Run.opReadKind, Run.opIdu, Run.finishSuccessor, Run.commitRegisters,
      Run.commitIme, Functional.fetchImmediate,
      InstructionShape.immediateBytes, Functional.executeShape,
      Functional.idle, Functional.matureIme, Alu.conditionHolds,
      FlatAdapter.event]
  all_goals cases before.scheduledImeEnable <;>
    simp [Retirement.Snapshot.atBoundary, Retirement.Snapshot.ofFunctional]

private def absSPLowCore (state : FunctionalState) (opcode low : Byte) : CoreState :=
  { baseFetchedCore state opcode .ldAbsSP with
    registers := { state.registers with pc := Word.ofNat (state.registers.pc.toNat + 2) }
    remaining := [.immediateHigh, .writeAddress, .writeAddressNext, .successorFetch]
    latches := { low, conditionTaken := true } }

private def absSPLow (state : FunctionalState) (opcode low : Byte) : FlatCoreState :=
  { core := absSPLowCore state opcode low
    memory := state.memory
    trace := [.read .opcode state.registers.pc opcode,
      .read .immediate (Word.ofNat (state.registers.pc.toNat + 1)) low] }

private def absSPHighCore (state : FunctionalState) (opcode low high : Byte) : CoreState :=
  { absSPLowCore state opcode low with
    registers := { state.registers with pc := Word.ofNat (state.registers.pc.toNat + 3) }
    remaining := [.writeAddress, .writeAddressNext, .successorFetch]
    latches := { low, high, conditionTaken := true } }

private def absSPHigh (state : FunctionalState) (opcode low high : Byte) : FlatCoreState :=
  { core := absSPHighCore state opcode low high
    memory := state.memory
    trace := [.read .opcode state.registers.pc opcode,
      .read .immediate (Word.ofNat (state.registers.pc.toNat + 1)) low,
      .read .immediate (Word.ofNat (state.registers.pc.toNat + 2)) high] }

private def absSPLowWrittenCore (state : FunctionalState) (opcode low high : Byte) : CoreState :=
  { absSPHighCore state opcode low high with
    remaining := [.writeAddressNext, .successorFetch] }

private def absSPLowWritten (state : FunctionalState) (opcode low high : Byte) : FlatCoreState :=
  let address := Word.ofBytes high low
  { core := absSPLowWrittenCore state opcode low high
    memory := state.memory.write address state.registers.sp.lowByte
    trace := [.read .opcode state.registers.pc opcode,
      .read .immediate (Word.ofNat (state.registers.pc.toNat + 1)) low,
      .read .immediate (Word.ofNat (state.registers.pc.toNat + 2)) high,
      .write address state.registers.sp.lowByte] }

private def absSPHighWrittenCore (state : FunctionalState) (opcode low high : Byte) : CoreState :=
  { absSPLowWrittenCore state opcode low high with remaining := [.successorFetch] }

private def absSPHighWritten (state : FunctionalState) (opcode low high : Byte) : FlatCoreState :=
  let address := Word.ofBytes high low
  let next := Word.ofNat (address.toNat + 1)
  { core := absSPHighWrittenCore state opcode low high
    memory := (state.memory.write address state.registers.sp.lowByte).write
      next state.registers.sp.highByte
    trace := [.read .opcode state.registers.pc opcode,
      .read .immediate (Word.ofNat (state.registers.pc.toNat + 1)) low,
      .read .immediate (Word.ofNat (state.registers.pc.toNat + 2)) high,
      .write address state.registers.sp.lowByte,
      .write next state.registers.sp.highByte] }

private theorem step_abs_sp_low (before : FunctionalState) (opcode : Byte) :
    FlatAdapter.step (baseFetched before opcode .ldAbsSP) =
      absSPLow before opcode
        (before.memory.read (Word.ofNat (before.registers.pc.toNat + 1))) := by
  simp [FlatAdapter.step, baseFetched, baseFetchedCore, absSPLow,
    absSPLowCore, Pipeline.taken, Cycle.physicalSchedule,
    Cycle.logicalSchedule, CoreState.currentOp?, Run.stepMachineCycle,
    Run.intent, Run.opFetch, Run.opCommit, Run.opPoll, Run.opControl,
    Run.opAddress, Run.opReadKind, Run.opIdu, Run.processNonFetch,
    increment_twice, FlatAdapter.event]

private theorem step_abs_sp_high (before : FunctionalState) (opcode : Byte) :
    let low := before.memory.read (Word.ofNat (before.registers.pc.toNat + 1))
    FlatAdapter.step (absSPLow before opcode low) =
      absSPHigh before opcode low
        (before.memory.read (Word.ofNat (before.registers.pc.toNat + 2))) := by
  simp [FlatAdapter.step, absSPLow, absSPLowCore, absSPHigh,
    absSPHighCore, baseFetchedCore, Pipeline.taken,
    Cycle.physicalSchedule, Cycle.logicalSchedule, CoreState.currentOp?,
    Run.stepMachineCycle, Run.intent, Run.opFetch, Run.opCommit,
    Run.opPoll, Run.opControl, Run.opAddress, Run.opReadKind, Run.opIdu,
    Run.processNonFetch, increment_thrice, FlatAdapter.event]

private theorem step_abs_sp_write_low (before : FunctionalState) (opcode : Byte) :
    let low := before.memory.read (Word.ofNat (before.registers.pc.toNat + 1))
    let high := before.memory.read (Word.ofNat (before.registers.pc.toNat + 2))
    FlatAdapter.step (absSPHigh before opcode low high) =
      absSPLowWritten before opcode low high := by
  simp [FlatAdapter.step, absSPHigh, absSPHighCore, absSPLowCore,
    absSPLowWritten, absSPLowWrittenCore, baseFetchedCore,
    Pipeline.taken, Cycle.physicalSchedule, Cycle.logicalSchedule,
    CoreState.currentOp?, Run.stepMachineCycle, Run.intent, Run.opFetch,
    Run.opCommit, Run.opPoll, Run.opControl, Run.opAddress,
    Run.readAddress, Run.opReadKind, Run.opIdu, Run.processNonFetch,
    Run.updatePointer, Run.writeValue, CoreState.wz, FlatAdapter.event]

private theorem step_abs_sp_write_high (before : FunctionalState) (opcode : Byte) :
    let low := before.memory.read (Word.ofNat (before.registers.pc.toNat + 1))
    let high := before.memory.read (Word.ofNat (before.registers.pc.toNat + 2))
    FlatAdapter.step (absSPLowWritten before opcode low high) =
      absSPHighWritten before opcode low high := by
  simp [FlatAdapter.step, absSPLowWritten, absSPLowWrittenCore,
    absSPHighWritten, absSPHighWrittenCore, absSPHighCore, absSPLowCore,
    baseFetchedCore, Pipeline.taken, Cycle.physicalSchedule,
    Cycle.logicalSchedule, CoreState.currentOp?, Run.stepMachineCycle,
    Run.intent, Run.opFetch, Run.opCommit, Run.opPoll, Run.opControl,
    Run.opAddress, Run.opReadKind, Run.opIdu, Run.processNonFetch,
    Run.writeValue, CoreState.wz, FlatAdapter.event]

set_option maxHeartbeats 3000000 in
/-- Universal refinement for `LD (nn),SP`. -/
theorem ld_abs_sp_refines (before : FunctionalState) (opcode : Byte)
    (running : before.mode = .running) (noHaltBug : before.haltBug = false)
    (atPC : before.memory.read before.registers.pc = opcode)
    (decoded : Decode.base opcode = .legal .ldAbsSP) :
    let logical := Functional.step before 0
    let physical := FlatAdapter.run 6 (physicalInitial before) noInterrupts
    Retirement.Snapshot.atBoundary physical.core =
        Retirement.Snapshot.ofFunctional logical.state ∧
      physical.memory = logical.state.memory ∧
      physical.trace.dropLast = logical.trace := by
  rw [show FlatAdapter.run 6 (physicalInitial before) noInterrupts =
      FlatAdapter.step (FlatAdapter.step (FlatAdapter.step (FlatAdapter.step
        (FlatAdapter.step (FlatAdapter.step (physicalInitial before)))))) by rfl]
  rw [fetch_legal before opcode .ldAbsSP atPC noHaltBug decoded]
  rw [step_abs_sp_low before opcode]
  rw [step_abs_sp_high before opcode]
  rw [step_abs_sp_write_low before opcode]
  rw [step_abs_sp_write_high before opcode]
  simp [Functional.step, running, atPC, decoded, noHaltBug,
    absSPHighWritten, absSPHighWrittenCore, absSPLowWrittenCore,
    absSPHighCore, absSPLowCore, baseFetchedCore, Pipeline.taken,
    Cycle.physicalSchedule, Cycle.logicalSchedule, FlatAdapter.step,
    CoreState.currentOp?, Run.stepMachineCycle, Run.intent, Run.opFetch,
    Run.opCommit, Run.opPoll, Run.opControl, Run.opAddress,
    Run.successorAddress, Run.opReadKind, Run.opIdu, Run.finishSuccessor,
    Run.commitRegisters, Run.commitIme, Functional.fetchImmediate,
    Functional.read, Functional.immediate16, InstructionShape.immediateBytes,
    Functional.executeShape, Functional.write, Functional.withRegisters,
    Functional.matureIme, increment_twice, increment_thrice,
    FlatAdapter.event]
  all_goals cases before.scheduledImeEnable <;>
    simp [Retirement.Snapshot.atBoundary, Retirement.Snapshot.ofFunctional]

/-- Exact syntactic domain covered by the normal base refinement theorems above. -/
def ordinaryBaseRefined : InstructionShape → Bool
  | .halt | .stop => false
  | .ld8 .atHL .atHL => false
  | .cbRotate _ _ | .bit _ _ | .res _ _ | .set _ _ => false
  | _ => true

/-- Exact syntactic domain covered by the CB refinement theorems above. -/
def cbRefined : InstructionShape → Bool
  | .cbRotate _ _ | .bit _ _ | .res _ _ | .set _ _ => true
  | _ => false

/-- Every decoded base byte is normal-refined, system-owned, prefixed, or locked. -/
def baseCoverageValid (opcode : Byte) : Bool :=
  match Decode.base opcode with
  | .legal .halt | .legal .stop => true
  | .legal shape => ordinaryBaseRefined shape
  | .prefix | .locked _ => true

/-- Exhaustive finite decoder closure for the universal base theorem families. -/
theorem every_base_byte_covered : ∀ opcode : Byte, baseCoverageValid opcode := by
  native_decide

/-- Every CB decoder result belongs to one of the three universal CB theorem families. -/
theorem every_cb_byte_covered : ∀ opcode : Byte, cbRefined (Decode.cb opcode) := by
  native_decide

private def ordinaryBaseCount : Nat :=
  ((List.range 256).filter fun value =>
    match Decode.base (Byte.ofNat value) with
    | .legal shape => ordinaryBaseRefined shape
    | _ => false).length

private def cbRefinedCount : Nat :=
  ((List.range 256).filter fun value => cbRefined (Decode.cb (Byte.ofNat value))).length

/-- All 242 non-HALT/non-STOP legal base entries have universal refinement theorems. -/
theorem ordinary_base_refinement_count : ordinaryBaseCount = 242 := by
  native_decide

/-- All 256 CB entries have universal refinement theorems. -/
theorem cb_refinement_count : cbRefinedCount = 256 := by
  native_decide

/-- The context-free normal refinement matrix contains exactly 498 instruction entries. -/
theorem normal_refinement_entry_count : ordinaryBaseCount + cbRefinedCount = 498 := by
  native_decide

/-- A proof-relevant classification tying every normal base shape to the local
universal theorem that implements it. -/
inductive NormalBaseFamily : InstructionShape → Prop where
  | register {shape} (family : RegisterSingleCycle shape) : NormalBaseFamily shape
  | immediateRegister {shape} (family : ImmediateRegisterShape shape) : NormalBaseFamily shape
  | ld16 (target : Reg16) : NormalBaseFamily (.ld16Imm target)
  | internal16 {shape} (family : Internal16Shape shape) : NormalBaseFamily shape
  | hlRead {shape} (family : BaseHLReadShape shape) : NormalBaseFamily shape
  | hlWrite (source : Reg8) : NormalBaseFamily (.ld8 .atHL (.reg source))
  | hlModify {shape} (family : BaseHLModifyShape shape) : NormalBaseFamily shape
  | hlImmediate : NormalBaseFamily (.ld8Imm .atHL)
  | mem16Write (destination : Mem16) : NormalBaseFamily (.ldMem16A destination)
  | mem16Read (source : Mem16) : NormalBaseFamily (.ldAFromMem16 source)
  | ldhCWrite : NormalBaseFamily .ldhCA
  | ldhCRead : NormalBaseFamily .ldhAC
  | ldhImmediate {shape} (family : LdhImmediateShape shape) : NormalBaseFamily shape
  | absoluteA {shape} (family : AbsoluteAShape shape) : NormalBaseFamily shape
  | pop (target : Stack16) : NormalBaseFamily (.pop target)
  | stackStore {shape} (family : StackStoreShape shape) : NormalBaseFamily shape
  | ldHLSP : NormalBaseFamily .ldHLFromSPPlus
  | addSP : NormalBaseFamily .addSP
  | jr : NormalBaseFamily .jr
  | jrCond (condition : Condition) : NormalBaseFamily (.jrCond condition)
  | jp : NormalBaseFamily .jp
  | jpCond (condition : Condition) : NormalBaseFamily (.jpCond condition)
  | call : NormalBaseFamily .call
  | callCond (condition : Condition) : NormalBaseFamily (.callCond condition)
  | returns {shape} (family : ReturnShape shape) : NormalBaseFamily shape
  | retCond (condition : Condition) : NormalBaseFamily (.retCond condition)
  | ldAbsSP : NormalBaseFamily .ldAbsSP

/-- The common conclusion of every normal base family, abstracting over its
shape-dependent physical M-cycle count. -/
def NormalRefinesIn (before : FunctionalState) (cycles : Nat) : Prop :=
  let logical := Functional.step before 0
  let physical := FlatAdapter.run cycles (physicalInitial before) noInterrupts
  Retirement.Snapshot.atBoundary physical.core =
      Retirement.Snapshot.ofFunctional logical.state ∧
    physical.memory = logical.state.memory ∧
    physical.trace.dropLast = logical.trace

/-- Proof-relevant coverage is complete for the exact syntactic normal domain. -/
theorem ordinaryBaseRefined_has_family {shape : InstructionShape}
    (covered : ordinaryBaseRefined shape = true) : Nonempty (NormalBaseFamily shape) := by
  cases shape with
  | nop => exact ⟨.register .nop⟩
  | ld16Imm target => exact ⟨.ld16 target⟩
  | ldMem16A destination => exact ⟨.mem16Write destination⟩
  | ldAFromMem16 source => exact ⟨.mem16Read source⟩
  | ldAbsSP => exact ⟨.ldAbsSP⟩
  | inc16 target => exact ⟨.internal16 (.inc target)⟩
  | dec16 target => exact ⟨.internal16 (.dec target)⟩
  | addHL source => exact ⟨.internal16 (.addHL source)⟩
  | inc8 target =>
      cases target with
      | reg register => exact ⟨.register (.inc8 register)⟩
      | atHL => exact ⟨.hlModify .inc⟩
  | dec8 target =>
      cases target with
      | reg register => exact ⟨.register (.dec8 register)⟩
      | atHL => exact ⟨.hlModify .dec⟩
  | ld8Imm target =>
      cases target with
      | reg register => exact ⟨.immediateRegister (.ld8 register)⟩
      | atHL => exact ⟨.hlImmediate⟩
  | accRotate operation => exact ⟨.register (.accRotate operation)⟩
  | daa => exact ⟨.register .daa⟩
  | cpl => exact ⟨.register .cpl⟩
  | scf => exact ⟨.register .scf⟩
  | ccf => exact ⟨.register .ccf⟩
  | jr => exact ⟨.jr⟩
  | jrCond condition => exact ⟨.jrCond condition⟩
  | stop => simp [ordinaryBaseRefined] at covered
  | ld8 destination source =>
      cases destination with
      | reg destination =>
          cases source with
          | reg source => exact ⟨.register (.ld8 destination source)⟩
          | atHL => exact ⟨.hlRead (.ld8 destination)⟩
      | atHL =>
          cases source with
          | reg source => exact ⟨.hlWrite source⟩
          | atHL => simp [ordinaryBaseRefined] at covered
  | halt => simp [ordinaryBaseRefined] at covered
  | aluA operation source =>
      cases source with
      | reg register => exact ⟨.register (.aluA operation register)⟩
      | atHL => exact ⟨.hlRead (.alu operation)⟩
  | retCond condition => exact ⟨.retCond condition⟩
  | ret => exact ⟨.returns .ret⟩
  | reti => exact ⟨.returns .reti⟩
  | pop target => exact ⟨.pop target⟩
  | jpCond condition => exact ⟨.jpCond condition⟩
  | jp => exact ⟨.jp⟩
  | jpHL => exact ⟨.register .jpHL⟩
  | ldhImmA => exact ⟨.ldhImmediate .writeA⟩
  | ldhAImm => exact ⟨.ldhImmediate .readA⟩
  | ldhCA => exact ⟨.ldhCWrite⟩
  | ldhAC => exact ⟨.ldhCRead⟩
  | ldAbsA => exact ⟨.absoluteA .writeA⟩
  | ldAAbs => exact ⟨.absoluteA .readA⟩
  | addSP => exact ⟨.addSP⟩
  | ldHLFromSPPlus => exact ⟨.ldHLSP⟩
  | ldSPHL => exact ⟨.internal16 .ldSPHL⟩
  | di => exact ⟨.register .di⟩
  | ei => exact ⟨.register .ei⟩
  | callCond condition => exact ⟨.callCond condition⟩
  | push source => exact ⟨.stackStore (.push source)⟩
  | call => exact ⟨.call⟩
  | aluAImm operation => exact ⟨.immediateRegister (.alu operation)⟩
  | rst vector => exact ⟨.stackStore (.rst vector)⟩
  | cbRotate operation target => simp [ordinaryBaseRefined] at covered
  | bit index target => simp [ordinaryBaseRefined] at covered
  | res index target => simp [ordinaryBaseRefined] at covered
  | set index target => simp [ordinaryBaseRefined] at covered

/-- One quantified theorem dispatches to every ordinary base local simulation;
conditional families select their exact taken or untaken duration. -/
theorem normal_base_refines (before : FunctionalState) (opcode : Byte)
    (shape : InstructionShape) (family : NormalBaseFamily shape)
    (running : before.mode = .running) (noHaltBug : before.haltBug = false)
    (atPC : before.memory.read before.registers.pc = opcode)
    (decoded : Decode.base opcode = .legal shape) :
    ∃ cycles, NormalRefinesIn before cycles := by
  cases family with
  | register proof => exact ⟨2, register_single_cycle_refines before opcode _ proof running noHaltBug atPC decoded⟩
  | immediateRegister proof => exact ⟨3, immediate_register_refines before opcode _ proof running noHaltBug atPC decoded⟩
  | ld16 target => exact ⟨4, ld16_immediate_refines before opcode target running noHaltBug atPC decoded⟩
  | internal16 proof => exact ⟨3, internal16_refines before opcode _ proof running noHaltBug atPC decoded⟩
  | hlRead proof => exact ⟨3, base_hl_read_refines before opcode _ proof running noHaltBug atPC decoded⟩
  | hlWrite source => exact ⟨3, base_hl_write_refines before opcode source running noHaltBug atPC decoded⟩
  | hlModify proof => exact ⟨4, base_hl_modify_refines before opcode _ proof running noHaltBug atPC decoded⟩
  | hlImmediate => exact ⟨4, hl_immediate_refines before opcode running noHaltBug atPC decoded⟩
  | mem16Write destination => exact ⟨3, mem16_write_refines before opcode destination running noHaltBug atPC decoded⟩
  | mem16Read source => exact ⟨3, mem16_read_refines before opcode source running noHaltBug atPC decoded⟩
  | ldhCWrite => exact ⟨3, ldh_c_write_refines before opcode running noHaltBug atPC decoded⟩
  | ldhCRead => exact ⟨3, ldh_c_read_refines before opcode running noHaltBug atPC decoded⟩
  | ldhImmediate proof => exact ⟨4, ldh_immediate_refines before opcode _ proof running noHaltBug atPC decoded⟩
  | absoluteA proof => exact ⟨5, absolute_a_refines before opcode _ proof running noHaltBug atPC decoded⟩
  | pop target => exact ⟨4, pop_refines before opcode target running noHaltBug atPC decoded⟩
  | stackStore proof => exact ⟨5, stack_store_refines before opcode _ proof running noHaltBug atPC decoded⟩
  | ldHLSP => exact ⟨4, ld_hl_sp_plus_refines before opcode running noHaltBug atPC decoded⟩
  | addSP => exact ⟨5, add_sp_refines before opcode running noHaltBug atPC decoded⟩
  | jr => exact ⟨4, jr_refines before opcode running noHaltBug atPC decoded⟩
  | jrCond condition =>
      cases held : Alu.conditionHolds condition before.registers.flags with
      | false => exact ⟨3, jr_cond_untaken_refines before opcode condition running noHaltBug atPC decoded held⟩
      | true => exact ⟨4, jr_cond_taken_refines before opcode condition running noHaltBug atPC decoded held⟩
  | jp => exact ⟨5, jp_refines before opcode running noHaltBug atPC decoded⟩
  | jpCond condition =>
      cases held : Alu.conditionHolds condition before.registers.flags with
      | false => exact ⟨4, jp_cond_untaken_refines before opcode condition running noHaltBug atPC decoded held⟩
      | true => exact ⟨5, jp_cond_taken_refines before opcode condition running noHaltBug atPC decoded held⟩
  | call => exact ⟨7, call_refines before opcode running noHaltBug atPC decoded⟩
  | callCond condition =>
      cases held : Alu.conditionHolds condition before.registers.flags with
      | false => exact ⟨4, call_cond_untaken_refines before opcode condition running noHaltBug atPC decoded held⟩
      | true => exact ⟨7, call_cond_taken_refines before opcode condition running noHaltBug atPC decoded held⟩
  | returns proof => exact ⟨5, return_refines before opcode _ proof running noHaltBug atPC decoded⟩
  | retCond condition =>
      cases held : Alu.conditionHolds condition before.registers.flags with
      | false => exact ⟨3, ret_cond_untaken_refines before opcode condition running noHaltBug atPC decoded held⟩
      | true => exact ⟨6, ret_cond_taken_refines before opcode condition running noHaltBug atPC decoded held⟩
  | ldAbsSP => exact ⟨6, ld_abs_sp_refines before opcode running noHaltBug atPC decoded⟩

/-- Decoder-level closure produces a proof-relevant family witness for every
ordinary legal base byte. -/
theorem decoded_normal_base_has_family (opcode : Byte) (shape : InstructionShape)
    (decoded : Decode.base opcode = .legal shape)
    (normal : shape ≠ .halt ∧ shape ≠ .stop) : Nonempty (NormalBaseFamily shape) := by
  apply ordinaryBaseRefined_has_family
  have covered := every_base_byte_covered opcode
  cases shape <;> simp_all [baseCoverageValid, ordinaryBaseRefined]

/-- Proof-relevant classification for all CB decoder results. -/
inductive NormalCbFamily : InstructionShape → Prop where
  | register {shape} (family : CbRegisterShape shape) : NormalCbFamily shape
  | bitHL (index : BitIndex) : NormalCbFamily (.bit index .atHL)
  | modifyHL {shape} (family : CbModifyHL shape) : NormalCbFamily shape

/-- Boolean CB closure yields a proof-relevant family witness. -/
theorem cbRefined_has_family {shape : InstructionShape}
    (covered : cbRefined shape = true) : Nonempty (NormalCbFamily shape) := by
  cases shape with
  | cbRotate operation target =>
      cases target with
      | reg register => exact ⟨.register (.rotate operation register)⟩
      | atHL => exact ⟨.modifyHL (.rotate operation)⟩
  | bit index target =>
      cases target with
      | reg register => exact ⟨.register (.bit index register)⟩
      | atHL => exact ⟨.bitHL index⟩
  | res index target =>
      cases target with
      | reg register => exact ⟨.register (.res index register)⟩
      | atHL => exact ⟨.modifyHL (.res index)⟩
  | set index target =>
      cases target with
      | reg register => exact ⟨.register (.set index register)⟩
      | atHL => exact ⟨.modifyHL (.set index)⟩
  | _ => simp [cbRefined] at covered

/-- One quantified theorem dispatches to every CB local simulation. -/
theorem normal_cb_refines (before : FunctionalState) (subopcode : Byte)
    (shape : InstructionShape) (family : NormalCbFamily shape)
    (running : before.mode = .running) (noHaltBug : before.haltBug = false)
    (atPrefix : before.memory.read before.registers.pc = 0xCB)
    (atSubopcode : before.memory.read (Word.ofNat (before.registers.pc.toNat + 1)) = subopcode)
    (decoded : Decode.cb subopcode = shape) :
    ∃ cycles, NormalRefinesIn before cycles := by
  cases family with
  | register proof => exact ⟨3, cb_register_refines before subopcode _ proof running noHaltBug atPrefix atSubopcode decoded⟩
  | bitHL index => exact ⟨4, cb_bit_hl_refines before subopcode index running noHaltBug atPrefix atSubopcode decoded⟩
  | modifyHL proof => exact ⟨5, cb_modify_hl_refines before subopcode _ proof running noHaltBug atPrefix atSubopcode decoded⟩

/-- Every decoded CB byte has a proof-relevant family witness. -/
theorem decoded_cb_has_family (opcode : Byte) :
    Nonempty (NormalCbFamily (Decode.cb opcode)) :=
  cbRefined_has_family (every_cb_byte_covered opcode)

end Proofs.UniversalRefinement
end Sm83
