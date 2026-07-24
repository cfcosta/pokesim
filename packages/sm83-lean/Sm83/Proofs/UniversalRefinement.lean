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

end Proofs.UniversalRefinement
end Sm83
