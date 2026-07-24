/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

import Sm83.Functional
import Sm83.Run

namespace Sm83

structure FlatCoreState where
  core : CoreState
  memory : FlatMemory := default
  trace : List BusEvent := []

namespace FlatAdapter

private def event (intent : CycleIntent) (readValue : Byte) : BusEvent :=
  match intent.control with
  | .read => .read intent.readKind intent.address readValue
  | .write => match intent.data with
      | .driven value => .write intent.address value
      | .released => .idle intent.address
  | .idle => .idle intent.address

/-- Drive the physical core from side-effect-free memory for one M-cycle. -/
def step (state : FlatCoreState) (pendingInterrupts : Byte := 0) (wake : Bool := false) : FlatCoreState :=
  let probe := Run.stepMachineCycle state.core {
    read := .stable 0xFF
    pendingInterrupts
    wake }
  let readValue := state.memory.read probe.intent.address
  let output := Run.stepMachineCycle state.core {
    read := .stable readValue
    pendingInterrupts
    wake }
  let memory := match output.intent.control, output.intent.data with
    | .write, .driven value => state.memory.write output.intent.address value
    | _, _ => state.memory
  { core := output.state
    memory
    trace := state.trace ++ [event output.intent readValue] }

/-- Reassociate the prefetched IR boundary with a de-overlapped architectural PC. -/
def project (state : FlatCoreState) : FunctionalState :=
  let pc := match state.core.boundaryPC with
    | some address => address
    | none => match state.core.mode, state.core.phase, state.core.ir with
      | .running, .execute, some fetched => fetched.address
      | _, _, _ => state.core.registers.pc
  { registers := { state.core.registers with pc }
    memory := state.memory
    ime := state.core.ime
    scheduledImeEnable := state.core.scheduledImeEnable
    haltBug := state.core.haltBug
    mode := match state.core.mode with
      | .running => .running
      | .halted => .halted
      | .stopped byte => .stopped byte
      | .locked opcode => .locked opcode }

/-- Execute an exact number of physical M-cycles against flat memory. -/
def run : Nat → FlatCoreState → (Nat → FlatCoreState → Byte) → FlatCoreState
  | 0, state, _ => state
  | fuel + 1, state, pendingAt =>
      let next := step state (pendingAt 0 state)
      run fuel next (fun cycle => pendingAt (cycle + 1))

end FlatAdapter
end Sm83
