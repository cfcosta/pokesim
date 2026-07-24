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

end Proofs.UniversalRefinement
end Sm83
