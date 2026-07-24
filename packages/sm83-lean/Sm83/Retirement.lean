/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

import Sm83.Functional
import Sm83.Run

namespace Sm83
namespace Retirement

/-- Programmer-visible processor state at an instruction boundary. -/
structure Snapshot where
  registers : Registers
  ime : Bool
  scheduledImeEnable : Bool
  haltBug : Bool
  deriving Repr, DecidableEq

@[inline] def Snapshot.ofCore (state : CoreState) : Snapshot :=
  { registers := state.registers
    ime := state.ime
    scheduledImeEnable := state.scheduledImeEnable
    haltBug := state.haltBug }

@[inline] def Snapshot.ofFunctional (state : FunctionalState) : Snapshot :=
  { registers := state.registers
    ime := state.ime
    scheduledImeEnable := state.scheduledImeEnable
    haltBug := state.haltBug }

/-- Project a fetched-IR physical post-state back to its de-overlapped
architectural PC. -/
def Snapshot.atBoundary (state : CoreState) : Snapshot :=
  let pc := state.boundaryPC.getD state.registers.pc
  { registers := { state.registers with pc }
    ime := state.ime
    scheduledImeEnable := state.scheduledImeEnable
    haltBug := state.haltBug }

/-- Installing a prefetched successor cannot change the architectural boundary
snapshot, even when that successor is an invalid opcode. -/
@[simp] theorem Snapshot.atBoundary_install (state : CoreState) (address : Word) (opcode : Byte) :
    Snapshot.atBoundary (Pipeline.install state address opcode) = Snapshot.atBoundary state := by
  cases decoded : Decode.base opcode <;> simp [Snapshot.atBoundary, Pipeline.install, decoded]

/-- One physical M-cycle paired with the environment response sampled by it. -/
structure ObservedCycle where
  operation : Option MicroOp
  intent : CycleIntent
  read : ReadResponse
  pendingInterrupts : Byte
  wake : Bool

@[inline] def observe (state : CoreState) (input : CoreInput) (output : CoreOutput) : ObservedCycle :=
  { operation := if state.phase = .execute then state.currentOp? else none
    intent := output.intent
    read := input.read
    pendingInterrupts := input.pendingInterrupts
    wake := input.wake }

/-- Convert a non-overlapped observed cycle to the architectural bus alphabet.
The successor fetch is represented as the next instruction's synthetic opcode
head and is therefore hidden from the retiring instruction. -/
def ObservedCycle.toBusEvent : ObservedCycle → Option BusEvent
  | cycle =>
      if cycle.operation = some .successorFetch then none
      else match cycle.intent.control with
        | .read => some (.read cycle.intent.readKind cycle.intent.address cycle.read.fold)
        | .write => match cycle.intent.data with
          | .driven value => some (.write cycle.intent.address value)
          | .released => none
        | .idle => some (.idle cycle.intent.address)

private def firstCB : List ObservedCycle → Option Byte
  | [] => none
  | cycle :: rest =>
      if cycle.operation = some .cbFetch then some cycle.read.fold else firstCB rest

/-- An RVFI-like instruction-retirement record. Physical M-cycles remain
available because Game Boy effects depend on their exact order. -/
structure Event where
  order : Nat
  fetched : FetchedIR
  cbOpcode : Option Byte
  shape : InstructionShape
  before : Snapshot
  after : Snapshot
  physicalCycles : List ObservedCycle

/-- Ordered architectural bus observations after fetch reassociation. -/
def Event.busTrace (event : Event) : List BusEvent :=
  .read .opcode event.fetched.address event.fetched.byte ::
    event.physicalCycles.filterMap ObservedCycle.toBusEvent

/-- Monitor state is proof instrumentation; it does not alter the physical
processor. `start` is the architectural snapshot captured when IR was fetched. -/
structure Monitor where
  core : CoreState
  start : Option Snapshot := none
  currentCycles : List ObservedCycle := []
  nextOrder : Nat := 0

structure Output where
  monitor : Monitor
  cycle : ObservedCycle
  retired : Option Event

/-- A normal instruction retires only on its successor-fetch cycle. STOP enters
its explicit mode on the padding read and invalid opcodes enter lock on fetch. -/
def atRetirement (state : CoreState) : Bool :=
  state.mode = .running && state.phase = .execute &&
    state.shape.isSome && state.currentOp? = some .successorFetch

private def installedIR (before after : CoreState) : Bool :=
  before.phase != .execute && after.phase = .execute && after.ir.isSome

private def nextStart (before after : CoreState) (retired : Option Event)
    (old : Option Snapshot) : Option Snapshot :=
  match retired with
  | some event =>
      if after.mode = .running && after.phase = .execute && after.ir.isSome then some event.after
      else none
  | none =>
      if installedIR before after then
        match after.ir with
        | some fetched =>
            some { (Snapshot.ofCore after) with
              registers := { after.registers with pc := fetched.address } }
        | none => none
      else old

/-- Construct a retirement record from a well-formed successor boundary. -/
def eventFor (monitor : Monitor) (coreOutput : CoreOutput)
    (cycles : List ObservedCycle) : Option Event :=
  if atRetirement monitor.core then
    match monitor.start, monitor.core.ir, monitor.core.shape with
    | some before, some fetched, some shape => some {
        order := monitor.nextOrder
        fetched
        cbOpcode := firstCB cycles
        shape
        before
        after := Snapshot.atBoundary coreOutput.state
        physicalCycles := cycles }
    | _, _, _ => none
  else none

/-- Observe one executable physical M-cycle and emit at most one retirement. -/
def step (monitor : Monitor) (input : CoreInput) : Output :=
  let coreOutput := Run.stepMachineCycle monitor.core input
  let cycle := observe monitor.core input coreOutput
  let cycles := monitor.currentCycles ++ [cycle]
  let retired := eventFor monitor coreOutput cycles
  let monitor := {
    core := coreOutput.state
    start := nextStart monitor.core coreOutput.state retired monitor.start
    currentCycles := if retired.isSome || installedIR monitor.core coreOutput.state then [] else cycles
    nextOrder := monitor.nextOrder + if retired.isSome then 1 else 0 }
  { monitor, cycle, retired }

/-- Monitor invariant needed for a total retirement record at every normal
successor boundary. -/
def WellFormed (monitor : Monitor) : Prop :=
  atRetirement monitor.core →
    monitor.start.isSome ∧ monitor.core.ir.isSome ∧ monitor.core.shape.isSome

@[simp] theorem initialized_wellFormed (state : CoreState)
    (bootstrap : state.phase = .bootstrap) :
    WellFormed { core := state } := by
  simp [WellFormed, atRetirement, bootstrap]

/-- Every constructed event carries the monitor's next sequence number. -/
theorem eventFor_order {monitor : Monitor} {coreOutput : CoreOutput}
    {cycles : List ObservedCycle} {event : Event}
    (emitted : eventFor monitor coreOutput cycles = some event) :
    event.order = monitor.nextOrder := by
  unfold eventFor at emitted
  split at emitted
  · cases startEq : monitor.start <;>
      cases irEq : monitor.core.ir <;>
      cases shapeEq : monitor.core.shape <;> simp_all
    cases emitted
    rfl
  · simp at emitted

/-- Retirement records emitted by `step` carry the exact next sequence number. -/
theorem emitted_order {monitor : Monitor} {input : CoreInput} {event : Event}
    (emitted : (step monitor input).retired = some event) :
    event.order = monitor.nextOrder := by
  apply eventFor_order
  simpa [step] using emitted

/-- One physical cycle emits no more than one retirement and advances the order
exactly when it emits that record. -/
theorem nextOrder_exact (monitor : Monitor) (input : CoreInput) :
    (step monitor input).monitor.nextOrder =
      monitor.nextOrder + if (step monitor input).retired.isSome then 1 else 0 := by
  simp [step]

private theorem eventFor_isSome_iff {monitor : Monitor} (wellFormed : WellFormed monitor)
    (coreOutput : CoreOutput) (cycles : List ObservedCycle) :
    (eventFor monitor coreOutput cycles).isSome ↔ atRetirement monitor.core := by
  unfold eventFor
  by_cases boundary : atRetirement monitor.core
  · have witnesses := wellFormed boundary
    cases startEq : monitor.start <;>
      cases irEq : monitor.core.ir <;>
      cases shapeEq : monitor.core.shape <;> simp_all
  · simp [boundary]

/-- A well-formed normal successor boundary always emits a record. -/
theorem emits_iff {monitor : Monitor} (wellFormed : WellFormed monitor) (input : CoreInput) :
    (step monitor input).retired.isSome ↔ atRetirement monitor.core := by
  simpa [step] using eventFor_isSome_iff wellFormed
    (Run.stepMachineCycle monitor.core input)
    (monitor.currentCycles ++ [observe monitor.core input (Run.stepMachineCycle monitor.core input)])

/-- HALT wait, STOP, and invalid lock cycles never retire instructions. -/
theorem quiescent_does_not_retire (monitor : Monitor) (input : CoreInput)
    (quiescent : monitor.core.mode ≠ .running) :
    (step monitor input).retired = none := by
  simp [step, eventFor, atRetirement, quiescent]

private theorem eventFor_identity {monitor : Monitor} {coreOutput : CoreOutput}
    {cycles : List ObservedCycle} {event : Event}
    (emitted : eventFor monitor coreOutput cycles = some event) :
    monitor.core.ir = some event.fetched ∧ monitor.core.shape = some event.shape := by
  unfold eventFor at emitted
  split at emitted
  · cases startEq : monitor.start <;>
      cases irEq : monitor.core.ir <;>
      cases shapeEq : monitor.core.shape <;> simp_all
    cases emitted
    exact ⟨rfl, rfl⟩
  · simp at emitted

/-- The retirement event identifies the exact fetched IR and decoded shape. -/
theorem emitted_identity {monitor : Monitor} {input : CoreInput} {event : Event}
    (emitted : (step monitor input).retired = some event) :
    monitor.core.ir = some event.fetched ∧ monitor.core.shape = some event.shape := by
  apply eventFor_identity
  simpa [step] using emitted

/-- The physical successor cycle is the last constituent cycle of every emitted
record. -/
theorem emitted_last_is_successor {monitor : Monitor} {input : CoreInput} {event : Event}
    (emitted : (step monitor input).retired = some event) :
    event.physicalCycles.getLast?.map (fun cycle => cycle.operation) =
      some (some .successorFetch) := by
  have eventEq : eventFor monitor (Run.stepMachineCycle monitor.core input)
      (monitor.currentCycles ++ [observe monitor.core input
        (Run.stepMachineCycle monitor.core input)]) = some event := by
    simpa [step] using emitted
  unfold eventFor at eventEq
  split at eventEq
  · rename_i boundary
    cases startEq : monitor.start <;>
      cases irEq : monitor.core.ir <;>
      cases shapeEq : monitor.core.shape <;> simp_all [atRetirement, observe]
    cases eventEq
    simp
  · simp at eventEq

/-- Architectural traces always begin with the retired IR's opcode fetch. -/
@[simp] theorem busTrace_head (event : Event) :
    event.busTrace.head? = some (.read .opcode event.fetched.address event.fetched.byte) := by
  simp [Event.busTrace]

/-- When successor prefetch installs the next instruction, its stored boundary
snapshot is exactly the previous retirement's architectural post-state. -/
theorem adjacent_boundary {monitor : Monitor} {input : CoreInput} {event : Event}
    (emitted : (step monitor input).retired = some event)
    (nextRunning : (step monitor input).monitor.core.mode = .running)
    (nextExecuting : (step monitor input).monitor.core.phase = .execute)
    (hasIR : (step monitor input).monitor.core.ir.isSome) :
    (step monitor input).monitor.start = some event.after := by
  have retiredEq : eventFor monitor (Run.stepMachineCycle monitor.core input)
      (monitor.currentCycles ++ [observe monitor.core input
        (Run.stepMachineCycle monitor.core input)]) = some event := by
    simpa [step] using emitted
  have runningEq : (Run.stepMachineCycle monitor.core input).state.mode = .running := by
    simpa [step] using nextRunning
  have executingEq : (Run.stepMachineCycle monitor.core input).state.phase = .execute := by
    simpa [step] using nextExecuting
  have irEq : (Run.stepMachineCycle monitor.core input).state.ir.isSome := by
    simpa [step] using hasIR
  simp [step, retiredEq, nextStart, runningEq, executingEq, irEq]

end Retirement
end Sm83
