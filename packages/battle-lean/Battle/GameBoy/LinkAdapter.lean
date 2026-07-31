/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0.
-/
import Battle.GameBoy.Adapter

/-!
# Interleaved two-console cable adapter

A link battle cannot be represented by running two standalone adapters: the
standalone internal-serial clock shifts an unconnected high bit.  This adapter
interleaves one machine cycle from either console while ticking a shared cable.
When the internal-clock endpoint reaches its divider edge, both serial devices
shift from their pre-edge output bits, even though only one console oscillator
is being advanced by that interleaving step.
-/

namespace Battle.GameBoy.LinkAdapter

open Sm83

inductive Endpoint where
  | left | right
  deriving Repr, DecidableEq, BEq, ReflBEq, LawfulBEq

structure Machine where
  left : Adapter.Machine
  right : Adapter.Machine
  leftRole : Devices.CableClockRole
  rightRole : Devices.CableClockRole
  deriving Repr, DecidableEq

/-- External presentation/controller responses for one interleaved console
cycle. Serial input is intentionally absent: it comes only from the peer. -/
structure Input where
  endpoint : Endpoint
  joypad : Devices.Joypad
  haltWake : Bool
  audioProgress : Bool
  deriving Repr, DecidableEq

structure EdgeObservation where
  pin : PinIntent
  drive : Option Byte
  deriving Repr, DecidableEq

structure EdgeRun where
  machine : Machine
  drives : List (Option Byte)
  observations : List EdgeObservation
  deriving Repr, DecidableEq

private def activeMachine (machine : Machine) : Endpoint → Adapter.Machine
  | .left => machine.left
  | .right => machine.right

private def setActiveMachine (machine : Machine) : Endpoint → Adapter.Machine → Machine
  | .left, active => { machine with left := active }
  | .right, active => { machine with right := active }

private def edgeDrive (memory : Memory.State) (intent : CycleIntent)
    (pin : PinIntent) : Option Byte :=
  if intent.control = .read && pin.selected then
    pin.address.map (Memory.read memory)
  else none

private def commitWrite (memory : Memory.State) (intent : CycleIntent)
    (pin : PinIntent) : Memory.State :=
  if Adapter.isT3R pin.halfEdge && intent.control = .write then
    match pin.address, pin.data with
    | some address, .driven value => Memory.write memory address value
    | _, _ => memory
  else memory

private def installDevices (machine : Machine)
    (devices : Devices.State × Devices.State) : Machine :=
  { machine with
    left := { machine.left with memory := { machine.left.memory with devices := devices.1 } }
    right := { machine.right with memory := { machine.right.memory with devices := devices.2 } } }

private def tickCable (machine : Machine) (endpoint : Endpoint)
    (intent : CycleIntent) (pin : PinIntent) : Machine :=
  if Adapter.isRising pin.halfEdge && intent.clocks.oscillator then
    let tickLeft := endpoint == .left
    let tickRight := endpoint == .right
    let devices := Devices.tickCableT machine.leftRole machine.rightRole
      tickLeft tickRight machine.left.memory.devices machine.right.memory.devices
    installDevices machine devices
  else machine

private def stepDma (machine : Machine) (endpoint : Endpoint)
    (intent : CycleIntent) (pin : PinIntent) : Machine :=
  if Adapter.isT4R pin.halfEdge && intent.clocks.machine then
    let active := activeMachine machine endpoint
    setActiveMachine machine endpoint
      { active with memory := Memory.stepDma active.memory }
  else machine

/-- Advance one physical half-edge for one console. Writes and DMA belong to the
active console; a cable edge may update both serial devices. -/
def stepEdge (machine : Machine) (endpoint : Endpoint) (intent : CycleIntent)
    (pin : PinIntent) : Machine × EdgeObservation :=
  let active := activeMachine machine endpoint
  let drive := edgeDrive active.memory intent pin
  let memory := commitWrite active.memory intent pin
  let machine := setActiveMachine machine endpoint { active with memory }
  let machine := tickCable machine endpoint intent pin
  let machine := stepDma machine endpoint intent pin
  (machine, { pin, drive })

@[simp] private theorem commitWrite_preserves_rom (memory : Memory.State)
    (intent : CycleIntent) (pin : PinIntent) :
    (commitWrite memory intent pin).cartridge.rom = memory.cartridge.rom := by
  simp only [commitWrite]
  split
  · split <;> simp
  · rfl

/-- A paired half-edge cannot mutate either immutable cartridge ROM. -/
@[simp] theorem stepEdge_preserves_rom (machine : Machine) (endpoint : Endpoint)
    (intent : CycleIntent) (pin : PinIntent) :
    let after := (stepEdge machine endpoint intent pin).1
    after.left.memory.cartridge.rom = machine.left.memory.cartridge.rom ∧
      after.right.memory.cartridge.rom = machine.right.memory.cartridge.rom := by
  cases endpoint <;>
    simp only [stepEdge, activeMachine, setActiveMachine, tickCable, stepDma,
      installDevices]
  all_goals
    split <;> split <;>
      simp [Memory.stepDma_preserves_cartridge]

/-- Execute the eight pin half-edges of one console's machine cycle while the
peer remains CPU-stationary but cable-reactive. -/
def runEdges (endpoint : Endpoint) (intent : CycleIntent) :
    List PinIntent → Machine → List (Option Byte) → List EdgeObservation → EdgeRun
  | [], machine, drives, observations => { machine, drives, observations }
  | pin :: rest, machine, drives, observations =>
      let result := stepEdge machine endpoint intent pin
      runEdges endpoint intent rest result.1
        (drives ++ [result.2.drive]) (observations ++ [result.2])

structure Output where
  machine : Machine
  endpoint : Endpoint
  probe : CoreOutput
  cpuInput : CoreInput
  cpuOutput : CoreOutput
  pins : List PinIntent
  edges : List EdgeObservation

private def applyExternal (machine : Machine) (input : Input) : Machine :=
  let active := activeMachine machine input.endpoint
  let devices := { active.memory.devices with joypad := input.joypad }
  let active := { active with memory := { active.memory with devices } }
  setActiveMachine machine input.endpoint active

/-- One interleaved machine cycle. The active CPU receives its temporally folded
bus response; the peer CPU does not advance. Serial shifts are produced only by
`Devices.tickCableT`, never by standalone `tickSerialInternal`. -/
def stepMachineCycle (machine : Machine) (input : Input) : Output :=
  let machine := applyExternal machine input
  let active := activeMachine machine input.endpoint
  let pending := Devices.pendingInterrupts active.memory.devices
  let probeInput : CoreInput :=
    { read := .stable 0xFF, pendingInterrupts := pending, wake := input.haltWake }
  let probe := Run.stepMachineCycle active.core probeInput
  let pins := HalfEdge.expand probe.intent
  let edgeRun := runEdges input.endpoint probe.intent pins machine [] []
  let afterEdges := activeMachine edgeRun.machine input.endpoint
  let cpuInput : CoreInput :=
    { read := Adapter.readResponse edgeRun.drives
      pendingInterrupts := pending
      wake := input.haltWake }
  let cpuOutput := Run.stepMachineCycle active.core cpuInput
  let active := { afterEdges with
    core := cpuOutput.state
    halfEdgeCount := active.halfEdgeCount + pins.length }
  let machine := setActiveMachine edgeRun.machine input.endpoint active
  { machine, endpoint := input.endpoint, probe, cpuInput, cpuOutput,
    pins, edges := edgeRun.observations }

inductive Step : Machine → Input → Output → Prop where
  | exact {before input after}
      (equation : stepMachineCycle before input = after) : Step before input after

/-- Execute an explicit finite interleaving schedule. -/
def run : List Input → Machine → Machine
  | [], machine => machine
  | input :: inputs, machine => run inputs (stepMachineCycle machine input).machine

/-- Proof-bearing finite paired execution. Each list element advances exactly
one endpoint machine cycle while retaining cable effects on its peer. -/
inductive MachineCycles : Machine → List Input → Machine → Prop where
  | nil (machine) : MachineCycles machine [] machine
  | cons {before middle after input inputs}
      (equation : (stepMachineCycle before input).machine = middle)
      (rest : MachineCycles middle inputs after) :
      MachineCycles before (input :: inputs) after

@[simp] theorem run_sound (inputs : List Input) (machine : Machine) :
    MachineCycles machine inputs (run inputs machine) := by
  induction inputs generalizing machine with
  | nil => exact .nil machine
  | cons input inputs induction =>
      exact .cons rfl (induction (stepMachineCycle machine input).machine)

/-- A complete edge list preserves both immutable ROM images. -/
@[simp] theorem runEdges_preserves_rom (endpoint : Endpoint) (intent : CycleIntent)
    (pins : List PinIntent) (machine : Machine) (drives : List (Option Byte))
    (observations : List EdgeObservation) :
    let after := (runEdges endpoint intent pins machine drives observations).machine
    after.left.memory.cartridge.rom = machine.left.memory.cartridge.rom ∧
      after.right.memory.cartridge.rom = machine.right.memory.cartridge.rom := by
  induction pins generalizing machine drives observations with
  | nil => exact ⟨rfl, rfl⟩
  | cons pin pins induction =>
      simp only [runEdges]
      have edge := stepEdge_preserves_rom machine endpoint intent pin
      have rest := induction (stepEdge machine endpoint intent pin).1
        (drives ++ [(stepEdge machine endpoint intent pin).2.drive])
        (observations ++ [(stepEdge machine endpoint intent pin).2])
      exact ⟨rest.1.trans edge.1, rest.2.trans edge.2⟩

/-- One interleaved machine cycle preserves both immutable ROM images. -/
@[simp] theorem stepMachineCycle_preserves_rom (machine : Machine) (input : Input) :
    let after := (stepMachineCycle machine input).machine
    after.left.memory.cartridge.rom = machine.left.memory.cartridge.rom ∧
      after.right.memory.cartridge.rom = machine.right.memory.cartridge.rom := by
  cases input with
  | mk endpoint joypad haltWake audioProgress =>
      cases endpoint <;>
        simp [stepMachineCycle, applyExternal, activeMachine, setActiveMachine]

/-- Every finite interleaving preserves both immutable ROM images. -/
theorem MachineCycles.preserves_rom {first final : Machine} {inputs : List Input}
    (execution : MachineCycles first inputs final) :
    final.left.memory.cartridge.rom = first.left.memory.cartridge.rom ∧
      final.right.memory.cartridge.rom = first.right.memory.cartridge.rom := by
  induction execution with
  | nil => exact ⟨rfl, rfl⟩
  | @cons before middle after input inputs equation rest induction =>
      have cycle := stepMachineCycle_preserves_rom before input
      rw [equation] at cycle
      exact ⟨induction.1.trans cycle.1, induction.2.trans cycle.2⟩

@[simp] theorem run_preserves_rom (inputs : List Input) (machine : Machine) :
    let after := run inputs machine
    after.left.memory.cartridge.rom = machine.left.memory.cartridge.rom ∧
      after.right.memory.cartridge.rom = machine.right.memory.cartridge.rom :=
  (run_sound inputs machine).preserves_rom

@[simp] theorem runEdges_length (endpoint : Endpoint) (intent : CycleIntent)
    (pins : List PinIntent) (machine : Machine) (drives : List (Option Byte))
    (observations : List EdgeObservation) :
    (runEdges endpoint intent pins machine drives observations).observations.length =
      observations.length + pins.length := by
  induction pins generalizing machine drives observations with
  | nil => simp [runEdges]
  | cons pin pins induction =>
      simp [runEdges, induction]
      omega

@[simp] theorem stepEdge_left_preserves_right_cpu (machine : Machine)
    (intent : CycleIntent) (pin : PinIntent) :
    let after := (stepEdge machine .left intent pin).1
    after.right.core = machine.right.core ∧
      after.right.halfEdgeCount = machine.right.halfEdgeCount := by
  simp only [stepEdge, activeMachine, setActiveMachine, tickCable, stepDma,
    installDevices]
  split <;> split <;> constructor <;> rfl

@[simp] theorem stepEdge_right_preserves_left_cpu (machine : Machine)
    (intent : CycleIntent) (pin : PinIntent) :
    let after := (stepEdge machine .right intent pin).1
    after.left.core = machine.left.core ∧
      after.left.halfEdgeCount = machine.left.halfEdgeCount := by
  simp only [stepEdge, activeMachine, setActiveMachine, tickCable, stepDma,
    installDevices]
  split <;> split <;> constructor <;> rfl

private theorem runEdges_left_preserves_right_cpu (intent : CycleIntent)
    (pins : List PinIntent) (machine : Machine) (drives : List (Option Byte))
    (observations : List EdgeObservation) :
    let after := (runEdges .left intent pins machine drives observations).machine
    after.right.core = machine.right.core ∧
      after.right.halfEdgeCount = machine.right.halfEdgeCount := by
  induction pins generalizing machine drives observations with
  | nil => exact ⟨rfl, rfl⟩
  | cons pin pins induction =>
      simp only [runEdges]
      have edge := stepEdge_left_preserves_right_cpu machine intent pin
      have rest := induction (stepEdge machine .left intent pin).1
        (drives ++ [(stepEdge machine .left intent pin).2.drive])
        (observations ++ [(stepEdge machine .left intent pin).2])
      exact ⟨rest.1.trans edge.1, rest.2.trans edge.2⟩

private theorem runEdges_right_preserves_left_cpu (intent : CycleIntent)
    (pins : List PinIntent) (machine : Machine) (drives : List (Option Byte))
    (observations : List EdgeObservation) :
    let after := (runEdges .right intent pins machine drives observations).machine
    after.left.core = machine.left.core ∧
      after.left.halfEdgeCount = machine.left.halfEdgeCount := by
  induction pins generalizing machine drives observations with
  | nil => exact ⟨rfl, rfl⟩
  | cons pin pins induction =>
      simp only [runEdges]
      have edge := stepEdge_right_preserves_left_cpu machine intent pin
      have rest := induction (stepEdge machine .right intent pin).1
        (drives ++ [(stepEdge machine .right intent pin).2.drive])
        (observations ++ [(stepEdge machine .right intent pin).2])
      exact ⟨rest.1.trans edge.1, rest.2.trans edge.2⟩

/-- Interleaving a left cycle never advances the right CPU or its cycle count.
The right serial device may still shift from a shared cable edge. -/
@[simp] theorem left_cycle_preserves_right_core (machine : Machine) (input : Input)
    (left : input.endpoint = .left) :
    let output := stepMachineCycle machine input
    output.machine.right.core = machine.right.core ∧
      output.machine.right.halfEdgeCount = machine.right.halfEdgeCount := by
  cases input with
  | mk endpoint joypad haltWake audioProgress =>
      cases endpoint
      · simp only [stepMachineCycle, applyExternal, activeMachine, setActiveMachine]
        exact runEdges_left_preserves_right_cpu _ _ _ _ _
      · contradiction

/-- Symmetric CPU-stationarity for a right interleaving step. -/
@[simp] theorem right_cycle_preserves_left_core (machine : Machine) (input : Input)
    (right : input.endpoint = .right) :
    let output := stepMachineCycle machine input
    output.machine.left.core = machine.left.core ∧
      output.machine.left.halfEdgeCount = machine.left.halfEdgeCount := by
  cases input with
  | mk endpoint joypad haltWake audioProgress =>
      cases endpoint
      · contradiction
      · simp only [stepMachineCycle, applyExternal, activeMachine, setActiveMachine]
        exact runEdges_right_preserves_left_cpu _ _ _ _ _

/-- A concrete full-duplex cable transfer demonstrates that neither endpoint
receives the standalone adapter's fabricated all-one input byte. -/
def exchangeEight : Nat → Devices.State → Devices.State → Devices.State × Devices.State
  | 0, left, right => (left, right)
  | count + 1, left, right =>
      let next := Devices.exchangeSerialEdge left right
      exchangeEight count next.1 next.2

private def serialFixture (data control : Byte) : Devices.State :=
  { serial := { data, control, bitsRemaining := 8, clockDivider := 0 } }

/-- Complete one byte transfer with the left endpoint owning the clock. -/
def exchangeByte (leftData rightData : Byte) : Devices.State × Devices.State :=
  exchangeEight 8 (serialFixture leftData 0x81) (serialFixture rightData 0x80)

/-- Every possible byte pair is exchanged exactly. Both transfer-start bits are
cleared, clock ownership is retained, and both serial interrupts are raised. -/
theorem full_duplex_byte_exact :
    ∀ leftData rightData : Byte,
      let result := exchangeByte leftData rightData
      result.1.serial.data = rightData ∧
        result.2.serial.data = leftData ∧
        result.1.serial.bitsRemaining = 0 ∧
        result.2.serial.bitsRemaining = 0 ∧
        result.1.serial.control = 0x01 ∧
        result.2.serial.control = 0x00 ∧
        result.1.interruptFlags &&& 0x08 ≠ 0 ∧
        result.2.interruptFlags &&& 0x08 ≠ 0 := by
  native_decide

@[simp] theorem full_duplex_byte_witness :
    let left := serialFixture 0xA5 0x81
    let right := serialFixture 0x3C 0x80
    let result := exchangeEight 8 left right
    result.1.serial.data = 0x3C ∧ result.2.serial.data = 0xA5 ∧
      result.1.serial.bitsRemaining = 0 ∧ result.2.serial.bitsRemaining = 0 := by
  native_decide

end Battle.GameBoy.LinkAdapter
