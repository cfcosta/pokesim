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

end Proofs.UniversalRefinement
end Sm83
