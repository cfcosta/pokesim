/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

import Battle.GameBoy.Memory
import Sm83.HalfEdge
import Sm83.Run

namespace Battle.GameBoy.Adapter

open Sm83

structure Machine where
  core : CoreState
  memory : Memory.State
  halfEdgeCount : Nat := 0
  deriving Repr, DecidableEq

structure EdgeObservation where
  pin : PinIntent
  drive : Option Byte
  deriving Repr, DecidableEq

structure EdgeRun where
  memory : Memory.State
  drives : List (Option Byte)
  observations : List EdgeObservation
  deriving Repr, DecidableEq

@[inline] def isRising : HalfEdge → Bool
  | ⟨_, .rising⟩ => true
  | _ => false

@[inline] def isT3R : HalfEdge → Bool
  | ⟨.t3, .rising⟩ => true
  | _ => false

@[inline] def isT4R : HalfEdge → Bool
  | ⟨.t4, .rising⟩ => true
  | _ => false

private def edgeDrive (memory : Memory.State) (intent : CycleIntent)
    (pin : PinIntent) : Option Byte :=
  if intent.control = .read && pin.selected then
    pin.address.map (Memory.read memory)
  else none

/-- Advance one pin half-edge. Writes commit once at T3R; oscillator-owned
devices tick on each rising edge, giving four system T-cycles per normal
M-cycle. DMA advances once at T4R. -/
def stepEdge (memory : Memory.State) (intent : CycleIntent)
    (pin : PinIntent) : Memory.State × EdgeObservation :=
  let drive := edgeDrive memory intent pin
  let memory := if isT3R pin.halfEdge && intent.control = .write then
    match pin.address, pin.data with
    | some address, .driven value => Memory.write memory address value
    | _, _ => memory
  else memory
  let memory := if isRising pin.halfEdge && intent.clocks.oscillator then
    { memory with devices := Devices.tickT memory.devices }
  else memory
  let memory := if isT4R pin.halfEdge && intent.clocks.machine then
    Memory.stepDma memory
  else memory
  (memory, { pin, drive })

/-- Execute a list of typed pin edges and retain every sampled drive. -/
def runEdges (intent : CycleIntent) :
    List PinIntent → Memory.State → List (Option Byte) → List EdgeObservation → EdgeRun
  | [], memory, drives, observations => { memory, drives, observations }
  | pin :: rest, memory, drives, observations =>
      let result := stepEdge memory intent pin
      runEdges intent rest result.1 (drives ++ [result.2.drive]) (observations ++ [result.2])

/-- Turn the eight per-edge bus drives into the processor's temporal response. -/
def readResponse (drives : List (Option Byte)) : ReadResponse :=
  ⟨fun edge => drives[edge.val]?.join⟩

private def stableDrivePattern (value : Byte) : List (Option Byte) :=
  [none, some value, some value, some value, some value, some value,
    some value, none]

private theorem stableDrivePattern_fold : ∀ value : Byte,
    (readResponse (stableDrivePattern value)).fold = value := by
  native_decide

/-- Explicit temporal-window premise for a stable cartridge/device read. It is
separate from address/control probing because dynamic internal-bus reads are
allowed to fold changing low bits. -/
def StableReadWindow (machine : Machine) (wake : Bool) (value : Byte) : Prop :=
  let pending := Devices.pendingInterrupts machine.memory.devices
  let probeInput : CoreInput := { read := .stable 0xFF, pendingInterrupts := pending, wake }
  let probe := Run.stepMachineCycle machine.core probeInput
  let edgeRun := runEdges probe.intent (HalfEdge.expand probe.intent) machine.memory [] []
  edgeRun.drives = stableDrivePattern value

/-- CPU-visible output of one composed Game Boy machine cycle. -/
structure Output where
  machine : Machine
  probe : CoreOutput
  cpuInput : CoreInput
  cpuOutput : CoreOutput
  pins : List PinIntent
  edges : List EdgeObservation

/-- One composed DMG-CPU B machine cycle. The probe discovers pin intent using
the same interrupt/wake inputs and a released read bus. The actual core step
then consumes the temporally folded device response. -/
def stepMachineCycle (machine : Machine) (wake : Bool := false) : Output :=
  let pending := Devices.pendingInterrupts machine.memory.devices
  let probeInput : CoreInput := { read := .stable 0xFF, pendingInterrupts := pending, wake }
  let probe := Run.stepMachineCycle machine.core probeInput
  let pins := HalfEdge.expand probe.intent
  let edgeRun := runEdges probe.intent pins machine.memory [] []
  let cpuInput : CoreInput := {
    read := readResponse edgeRun.drives
    pendingInterrupts := pending
    wake }
  let cpuOutput := Run.stepMachineCycle machine.core cpuInput
  { machine := {
      core := cpuOutput.state
      memory := edgeRun.memory
      halfEdgeCount := machine.halfEdgeCount + pins.length }
    probe
    cpuInput
    cpuOutput
    pins
    edges := edgeRun.observations }

/-- A proved stable temporal window is consumed as exactly that CPU byte. -/
theorem stableReadWindow_cpu_fold (machine : Machine) (wake : Bool) (value : Byte)
    (stable : StableReadWindow machine wake value) :
    (stepMachineCycle machine wake).cpuInput.read.fold = value := by
  unfold StableReadWindow at stable
  simp only [stepMachineCycle]
  rw [stable]
  exact stableDrivePattern_fold value

/-- Pin-relevant equality between the address/control cycle discovered by the
probe and the cycle executed with the temporal read response. -/
def PinCompatible (output : Output) : Prop :=
  HalfEdge.expand output.probe.intent = HalfEdge.expand output.cpuOutput.intent

/-- Execute a finite number of composed machine cycles. -/
def run : Nat → (Nat → Bool) → Machine → Machine
  | 0, _, machine => machine
  | cycles + 1, wakeAt, machine =>
      let next := (stepMachineCycle machine (wakeAt machine.halfEdgeCount)).machine
      run cycles wakeAt next

/-- The system-level transition relation leaves STOP/lock profile selection to
separate profile premises while fixing the common deterministic adapter step. -/
inductive Step : Machine → Bool → Output → Prop where
  | common {before wake after}
      (equation : stepMachineCycle before wake = after) : Step before wake after

/-- Edge execution preserves list cardinality. -/
theorem runEdges_length (intent : CycleIntent) (pins : List PinIntent)
    (memory : Memory.State) (drives : List (Option Byte))
    (observations : List EdgeObservation) :
    (runEdges intent pins memory drives observations).observations.length =
      observations.length + pins.length := by
  induction pins generalizing memory drives observations with
  | nil => simp [runEdges]
  | cons pin rest induction =>
      simp [runEdges, induction]
      omega

/-- No bus/device/DMA half-edge can mutate immutable cartridge ROM bytes;
MBC control writes only change mapping or external RAM. -/
@[simp] theorem stepEdge_preserves_rom (memory : Memory.State)
    (intent : CycleIntent) (pin : PinIntent) :
    (stepEdge memory intent pin).1.cartridge.rom = memory.cartridge.rom := by
  let written := if isT3R pin.halfEdge && intent.control = .write then
    match pin.address, pin.data with
    | some address, .driven value => Memory.write memory address value
    | _, _ => memory
    else memory
  have writtenRom : written.cartridge.rom = memory.cartridge.rom := by
    by_cases commit : isT3R pin.halfEdge && intent.control = .write
    · simp [written, commit]
      split <;> simp
    · simp [written, commit]
  let ticked := if isRising pin.halfEdge && intent.clocks.oscillator then
    { written with devices := Devices.tickT written.devices }
    else written
  have tickedRom : ticked.cartridge.rom = memory.cartridge.rom := by
    cases rising : isRising pin.halfEdge <;>
      cases oscillator : intent.clocks.oscillator <;>
      simp [ticked, rising, oscillator, writtenRom]
  let dmaed := if isT4R pin.halfEdge && intent.clocks.machine then
    Memory.stepDma ticked else ticked
  have dmaedRom : dmaed.cartridge.rom = memory.cartridge.rom := by
    cases t4 : isT4R pin.halfEdge <;>
      cases machineClock : intent.clocks.machine <;>
      simp [dmaed, t4, machineClock, tickedRom]
  simpa [stepEdge, written, ticked, dmaed] using dmaedRom

@[simp] theorem runEdges_preserves_rom (intent : CycleIntent)
    (pins : List PinIntent) (memory : Memory.State)
    (drives : List (Option Byte)) (observations : List EdgeObservation) :
    (runEdges intent pins memory drives observations).memory.cartridge.rom =
      memory.cartridge.rom := by
  induction pins generalizing memory drives observations with
  | nil => rfl
  | cons pin pins induction =>
      simp only [runEdges]
      rw [induction]
      exact stepEdge_preserves_rom memory intent pin

@[simp] theorem stepMachineCycle_preserves_rom (machine : Machine) (wake : Bool) :
    (stepMachineCycle machine wake).machine.memory.cartridge.rom =
      machine.memory.cartridge.rom := by
  simp [stepMachineCycle]

/-- Read cycles cannot mutate cartridge banking/storage at any half-edge. -/
@[simp] theorem stepEdge_read_preserves_cartridge (memory : Memory.State)
    (intent : CycleIntent) (pin : PinIntent) (read : intent.control = .read) :
    (stepEdge memory intent pin).1.cartridge = memory.cartridge := by
  simp [stepEdge, read]
  split
  · rw [Memory.stepDma_preserves_cartridge]
    split <;> rfl
  · split <;> rfl

/-- Read cycles cannot remap the boot ROM at any half-edge. -/
@[simp] theorem stepEdge_read_preserves_bootMapped (memory : Memory.State)
    (intent : CycleIntent) (pin : PinIntent) (read : intent.control = .read) :
    (stepEdge memory intent pin).1.bootMapped = memory.bootMapped := by
  simp [stepEdge, read]
  split
  · rw [Memory.stepDma_preserves_bootMapped]
    split <;> rfl
  · split <;> rfl

/-- Read cycles cannot mutate WRAM at any half-edge. -/
@[simp] theorem stepEdge_read_preserves_wram (memory : Memory.State)
    (intent : CycleIntent) (pin : PinIntent) (read : intent.control = .read) :
    (stepEdge memory intent pin).1.wram = memory.wram := by
  simp [stepEdge, read]
  split
  · rw [Memory.stepDma_preserves_wram]
    split <;> rfl
  · split <;> rfl

/-- ROM reads remain stable across a read half-edge even while clocked devices
and DMA advance. -/
@[simp] theorem stepEdge_read_preserves_rom_read (memory : Memory.State)
    (intent : CycleIntent) (pin : PinIntent) (address : Word)
    (read : intent.control = .read) (unmapped : memory.bootMapped = false)
    (range : address.toNat < 0x8000) :
    Memory.read (stepEdge memory intent pin).1 address = Memory.read memory address := by
  have cartridge := stepEdge_read_preserves_cartridge memory intent pin read
  have boot := stepEdge_read_preserves_bootMapped memory intent pin read
  rw [Memory.read_rom_unmapped _ address (by simpa [boot] using unmapped) range]
  rw [Memory.read_rom_unmapped memory address unmapped range]
  rw [cartridge]

private theorem runEdges_read_rom_drives (intent : CycleIntent)
    (reference : Memory.State) (pins : List PinIntent) (memory : Memory.State)
    (drives : List (Option Byte)) (observations : List EdgeObservation)
    (read : intent.control = .read) (unmapped : memory.bootMapped = false)
    (range : intent.address.toNat < 0x8000)
    (same : Memory.read memory intent.address = Memory.read reference intent.address)
    (valid : ∀ pin ∈ pins, pin.selected = true → pin.address = some intent.address) :
    (runEdges intent pins memory drives observations).drives =
      drives ++ pins.map (fun pin =>
        if pin.selected then some (Memory.read reference intent.address) else none) := by
  induction pins generalizing memory drives observations with
  | nil => simp [runEdges]
  | cons pin rest induction =>
      have headAddress : pin.selected = true → pin.address = some intent.address := by
        intro selected
        exact valid pin (by simp) selected
      have drive : (stepEdge memory intent pin).2.drive =
          if pin.selected then some (Memory.read reference intent.address) else none := by
        by_cases selected : pin.selected = true
        · simp [stepEdge, edgeDrive, read, selected, headAddress selected, same]
        · have selectedFalse : pin.selected = false := by
            cases equation : pin.selected <;> simp_all
          simp [stepEdge, edgeDrive, read, selectedFalse]
      have nextUnmapped : (stepEdge memory intent pin).1.bootMapped = false := by
        rw [stepEdge_read_preserves_bootMapped memory intent pin read]
        exact unmapped
      have nextSame : Memory.read (stepEdge memory intent pin).1 intent.address =
          Memory.read reference intent.address := by
        rw [stepEdge_read_preserves_rom_read memory intent pin intent.address read unmapped range]
        exact same
      have restValid : ∀ next ∈ rest, next.selected = true →
          next.address = some intent.address := by
        intro next member selected
        exact valid next (by simp [member]) selected
      rw [runEdges]
      rw [induction (stepEdge memory intent pin).1
        (drives ++ [(stepEdge memory intent pin).2.drive])
        (observations ++ [(stepEdge memory intent pin).2]) nextUnmapped nextSame restValid]
      simp [drive, List.append_assoc]

/-- Stable ROM storage discharges the temporal read-window premise. -/
theorem stableReadWindow_rom (machine : Machine) (wake : Bool)
    (read : (stepMachineCycle machine wake).probe.intent.control = .read)
    (unmapped : machine.memory.bootMapped = false)
    (range : (stepMachineCycle machine wake).probe.intent.address.toNat < 0x8000) :
    StableReadWindow machine wake
      (Memory.read machine.memory (stepMachineCycle machine wake).probe.intent.address) := by
  let intent := (stepMachineCycle machine wake).probe.intent
  change (runEdges intent (HalfEdge.expand intent) machine.memory [] []).drives =
    stableDrivePattern (Memory.read machine.memory intent.address)
  change intent.control = .read at read
  change intent.address.toNat < 0x8000 at range
  have drives := runEdges_read_rom_drives intent machine.memory
    (HalfEdge.expand intent) machine.memory [] [] read unmapped range rfl
    (fun _ member selected => HalfEdge.selected_address member selected)
  rw [HalfEdge.map_selected_read intent (Memory.read machine.memory intent.address) read] at drives
  simpa [stableDrivePattern] using drives

/-- WRAM reads remain stable across read half-edges. -/
@[simp] theorem stepEdge_read_preserves_wram_read (memory : Memory.State)
    (intent : CycleIntent) (pin : PinIntent) (address : Word)
    (read : intent.control = .read) (low : 0xC000 ≤ address.toNat)
    (high : address.toNat < 0xE000) :
    Memory.read (stepEdge memory intent pin).1 address = Memory.read memory address := by
  rw [Memory.read_wram _ address low high, Memory.read_wram memory address low high]
  rw [stepEdge_read_preserves_wram memory intent pin read]

private theorem runEdges_read_wram_drives (intent : CycleIntent)
    (reference : Memory.State) (pins : List PinIntent) (memory : Memory.State)
    (drives : List (Option Byte)) (observations : List EdgeObservation)
    (read : intent.control = .read) (low : 0xC000 ≤ intent.address.toNat)
    (high : intent.address.toNat < 0xE000)
    (same : Memory.read memory intent.address = Memory.read reference intent.address)
    (valid : ∀ pin ∈ pins, pin.selected = true → pin.address = some intent.address) :
    (runEdges intent pins memory drives observations).drives =
      drives ++ pins.map (fun pin =>
        if pin.selected then some (Memory.read reference intent.address) else none) := by
  induction pins generalizing memory drives observations with
  | nil => simp [runEdges]
  | cons pin rest induction =>
      have headAddress : pin.selected = true → pin.address = some intent.address := by
        intro selected
        exact valid pin (by simp) selected
      have drive : (stepEdge memory intent pin).2.drive =
          if pin.selected then some (Memory.read reference intent.address) else none := by
        by_cases selected : pin.selected = true
        · simp [stepEdge, edgeDrive, read, selected, headAddress selected, same]
        · have selectedFalse : pin.selected = false := by
            cases equation : pin.selected <;> simp_all
          simp [stepEdge, edgeDrive, read, selectedFalse]
      have nextSame : Memory.read (stepEdge memory intent pin).1 intent.address =
          Memory.read reference intent.address := by
        rw [stepEdge_read_preserves_wram_read memory intent pin intent.address read low high]
        exact same
      have restValid : ∀ next ∈ rest, next.selected = true →
          next.address = some intent.address := by
        intro next member selected
        exact valid next (by simp [member]) selected
      rw [runEdges]
      rw [induction (stepEdge memory intent pin).1
        (drives ++ [(stepEdge memory intent pin).2.drive])
        (observations ++ [(stepEdge memory intent pin).2]) nextSame restValid]
      simp [drive, List.append_assoc]

/-- Stable WRAM storage discharges a temporal read-window premise. -/
theorem stableReadWindow_wram (machine : Machine) (wake : Bool)
    (read : (stepMachineCycle machine wake).probe.intent.control = .read)
    (low : 0xC000 ≤ (stepMachineCycle machine wake).probe.intent.address.toNat)
    (high : (stepMachineCycle machine wake).probe.intent.address.toNat < 0xE000) :
    StableReadWindow machine wake
      (Memory.read machine.memory (stepMachineCycle machine wake).probe.intent.address) := by
  let intent := (stepMachineCycle machine wake).probe.intent
  change (runEdges intent (HalfEdge.expand intent) machine.memory [] []).drives =
    stableDrivePattern (Memory.read machine.memory intent.address)
  change intent.control = .read at read
  change 0xC000 ≤ intent.address.toNat at low
  change intent.address.toNat < 0xE000 at high
  have drives := runEdges_read_wram_drives intent machine.memory
    (HalfEdge.expand intent) machine.memory [] [] read low high rfl
    (fun _ member selected => HalfEdge.selected_address member selected)
  rw [HalfEdge.map_selected_read intent (Memory.read machine.memory intent.address) read] at drives
  simpa [stableDrivePattern] using drives

/-- A complete edge list preserves cartridge state throughout a read cycle. -/
theorem runEdges_read_preserves_cartridge (intent : CycleIntent)
    (pins : List PinIntent) (memory : Memory.State)
    (drives : List (Option Byte)) (observations : List EdgeObservation)
    (read : intent.control = .read) :
    (runEdges intent pins memory drives observations).memory.cartridge =
      memory.cartridge := by
  induction pins generalizing memory drives observations with
  | nil => rfl
  | cons pin rest induction =>
      simp only [runEdges]
      rw [induction]
      exact stepEdge_read_preserves_cartridge memory intent pin read

/-- A complete edge list preserves boot-ROM mapping throughout a read cycle. -/
theorem runEdges_read_preserves_bootMapped (intent : CycleIntent)
    (pins : List PinIntent) (memory : Memory.State)
    (drives : List (Option Byte)) (observations : List EdgeObservation)
    (read : intent.control = .read) :
    (runEdges intent pins memory drives observations).memory.bootMapped =
      memory.bootMapped := by
  induction pins generalizing memory drives observations with
  | nil => rfl
  | cons pin rest induction =>
      simp only [runEdges]
      rw [induction]
      exact stepEdge_read_preserves_bootMapped memory intent pin read

/-- A complete edge list preserves WRAM throughout a read cycle. -/
theorem runEdges_read_preserves_wram (intent : CycleIntent)
    (pins : List PinIntent) (memory : Memory.State)
    (drives : List (Option Byte)) (observations : List EdgeObservation)
    (read : intent.control = .read) :
    (runEdges intent pins memory drives observations).memory.wram = memory.wram := by
  induction pins generalizing memory drives observations with
  | nil => rfl
  | cons pin rest induction =>
      simp only [runEdges]
      rw [induction]
      exact stepEdge_read_preserves_wram memory intent pin read

/-- Every machine cycle contains exactly four rising T-edges. -/
theorem four_tcycles (intent : CycleIntent) :
    ((HalfEdge.expand intent).filter (fun pin => isRising pin.halfEdge)).length = 4 := by
  simp [HalfEdge.expand, machineHalfEdges, isRising]

/-- T3R, the write-commit and read-sample edge, occurs exactly once. -/
theorem one_t3r (intent : CycleIntent) :
    ((HalfEdge.expand intent).filter (fun pin => isT3R pin.halfEdge)).length = 1 := by
  simp [HalfEdge.expand, machineHalfEdges, isT3R]

/-- Every composed physical step expands to exactly eight typed half-edges. -/
@[simp] theorem step_pin_count (machine : Machine) (wake : Bool) :
    (stepMachineCycle machine wake).pins.length = 8 := by
  simp [stepMachineCycle]

/-- The edge trace has one observation for every typed pin edge. -/
@[simp] theorem step_edge_count (machine : Machine) (wake : Bool) :
    (stepMachineCycle machine wake).edges.length = 8 := by
  simp [stepMachineCycle, runEdges_length]

/-- A composed read cycle preserves cartridge mapping and immutable storage. -/
theorem read_cycle_preserves_cartridge (machine : Machine) (wake : Bool)
    (read : (stepMachineCycle machine wake).probe.intent.control = .read) :
    (stepMachineCycle machine wake).machine.memory.cartridge =
      machine.memory.cartridge := by
  simpa [stepMachineCycle] using runEdges_read_preserves_cartridge
    (stepMachineCycle machine wake).probe.intent
    (HalfEdge.expand (stepMachineCycle machine wake).probe.intent)
    machine.memory [] [] read

/-- A composed read cycle cannot remap the boot ROM. -/
theorem read_cycle_preserves_bootMapped (machine : Machine) (wake : Bool)
    (read : (stepMachineCycle machine wake).probe.intent.control = .read) :
    (stepMachineCycle machine wake).machine.memory.bootMapped =
      machine.memory.bootMapped := by
  simpa [stepMachineCycle] using runEdges_read_preserves_bootMapped
    (stepMachineCycle machine wake).probe.intent
    (HalfEdge.expand (stepMachineCycle machine wake).probe.intent)
    machine.memory [] [] read

/-- A composed read cycle preserves WRAM. -/
theorem read_cycle_preserves_wram (machine : Machine) (wake : Bool)
    (read : (stepMachineCycle machine wake).probe.intent.control = .read) :
    (stepMachineCycle machine wake).machine.memory.wram = machine.memory.wram := by
  simpa [stepMachineCycle] using runEdges_read_preserves_wram
    (stepMachineCycle machine wake).probe.intent
    (HalfEdge.expand (stepMachineCycle machine wake).probe.intent)
    machine.memory [] [] read

/-- Projecting one edge to WRAM erases device clocks and DMA; only the T3R
CPU write can change that backing array. -/
@[simp] theorem stepEdge_wram (memory : Memory.State) (intent : CycleIntent)
    (pin : PinIntent) :
    (stepEdge memory intent pin).1.wram =
      (if isT3R pin.halfEdge && intent.control = .write then
        match pin.address, pin.data with
        | some address, .driven value => Memory.write memory address value
        | _, _ => memory
      else memory).wram := by
  simp only [stepEdge]
  split
  · rw [Memory.stepDma_preserves_wram]
    split <;> rfl
  · split <;> rfl

private def expandedWritePins (intent : CycleIntent) (value : Byte) : List PinIntent :=
  [ { halfEdge := ⟨.t1, .falling⟩, address := some intent.address }
  , { halfEdge := ⟨.t1, .rising⟩, address := some intent.address, selected := true }
  , { halfEdge := ⟨.t2, .falling⟩, address := some intent.address, selected := true }
  , { halfEdge := ⟨.t2, .rising⟩, address := some intent.address, selected := true,
      writeAsserted := true, data := .driven value }
  , { halfEdge := ⟨.t3, .falling⟩, address := some intent.address, selected := true,
      writeAsserted := true, data := .driven value }
  , { halfEdge := ⟨.t3, .rising⟩, address := some intent.address, selected := true,
      writeAsserted := true, data := .driven value }
  , { halfEdge := ⟨.t4, .falling⟩, address := some intent.address, selected := true }
  , { halfEdge := ⟨.t4, .rising⟩ } ]

private theorem expand_write (intent : CycleIntent) (value : Byte)
    (write : intent.control = .write) (driven : intent.data = .driven value) :
    HalfEdge.expand intent = expandedWritePins intent value := by
  unfold HalfEdge.expand machineHalfEdges expandedWritePins
  rw [write, driven]
  rfl

@[simp] theorem stepEdge_cartridge (memory : Memory.State) (intent : CycleIntent)
    (pin : PinIntent) :
    (stepEdge memory intent pin).1.cartridge =
      (if isT3R pin.halfEdge && intent.control = .write then
        match pin.address, pin.data with
        | some address, .driven value => Memory.write memory address value
        | _, _ => memory
      else memory).cartridge := by
  simp only [stepEdge]
  split
  · rw [Memory.stepDma_preserves_cartridge]
    split <;> rfl
  · split <;> rfl

@[simp] theorem stepEdge_bootMapped (memory : Memory.State) (intent : CycleIntent)
    (pin : PinIntent) :
    (stepEdge memory intent pin).1.bootMapped =
      (if isT3R pin.halfEdge && intent.control = .write then
        match pin.address, pin.data with
        | some address, .driven value => Memory.write memory address value
        | _, _ => memory
      else memory).bootMapped := by
  simp only [stepEdge]
  split
  · rw [Memory.stepDma_preserves_bootMapped]
    split <;> rfl
  · split <;> rfl

/-- A composed write cycle commits its driven byte to WRAM exactly once at
T3R. Device clocks and DMA cannot mutate the WRAM backing array. -/
theorem write_cycle_wram (machine : Machine) (wake : Bool) (value : Byte)
    (write : (stepMachineCycle machine wake).probe.intent.control = .write)
    (driven : (stepMachineCycle machine wake).probe.intent.data = .driven value)
    (low : 0xC000 ≤ (stepMachineCycle machine wake).probe.intent.address.toNat)
    (high : (stepMachineCycle machine wake).probe.intent.address.toNat < 0xE000) :
    (stepMachineCycle machine wake).machine.memory.wram =
      (Memory.write machine.memory
        (stepMachineCycle machine wake).probe.intent.address value).wram := by
  let intent := (stepMachineCycle machine wake).probe.intent
  change intent.control = .write at write
  change intent.data = .driven value at driven
  change 0xC000 ≤ intent.address.toNat at low
  change intent.address.toNat < 0xE000 at high
  change (runEdges intent (HalfEdge.expand intent) machine.memory [] []).memory.wram =
    (Memory.write machine.memory intent.address value).wram
  rw [expand_write intent value write driven]
  simp only [expandedWritePins, runEdges]
  repeat rw [stepEdge_wram]
  simp [isT3R, write, Memory.write_wram, low, high, stepEdge_wram]

/-- A WRAM write cannot alter cartridge banking or boot-overlay selection. -/
theorem write_cycle_preserves_mapping (machine : Machine) (wake : Bool) (value : Byte)
    (write : (stepMachineCycle machine wake).probe.intent.control = .write)
    (driven : (stepMachineCycle machine wake).probe.intent.data = .driven value)
    (low : 0xC000 ≤ (stepMachineCycle machine wake).probe.intent.address.toNat)
    (high : (stepMachineCycle machine wake).probe.intent.address.toNat < 0xE000) :
    (stepMachineCycle machine wake).machine.memory.cartridge = machine.memory.cartridge ∧
      (stepMachineCycle machine wake).machine.memory.bootMapped = machine.memory.bootMapped := by
  let intent := (stepMachineCycle machine wake).probe.intent
  change intent.control = .write at write
  change intent.data = .driven value at driven
  change 0xC000 ≤ intent.address.toNat at low
  change intent.address.toNat < 0xE000 at high
  constructor
  · change (runEdges intent (HalfEdge.expand intent) machine.memory [] []).memory.cartridge =
      machine.memory.cartridge
    rw [expand_write intent value write driven]
    simp only [expandedWritePins, runEdges]
    repeat rw [stepEdge_cartridge]
    simp [isT3R, write, low, high, stepEdge_cartridge]
  · change (runEdges intent (HalfEdge.expand intent) machine.memory [] []).memory.bootMapped =
      machine.memory.bootMapped
    rw [expand_write intent value write driven]
    simp only [expandedWritePins, runEdges]
    repeat rw [stepEdge_bootMapped]
    simp [isT3R, write, low, high, stepEdge_bootMapped]

/-- The probe and actual CPU step have identical complete cycle intent because
read data cannot influence the current cycle's pins. -/
theorem probe_compatible (machine : Machine) (wake : Bool) :
    PinCompatible (stepMachineCycle machine wake) := by
  unfold PinCompatible stepMachineCycle
  exact congrArg HalfEdge.expand (Run.intent_read_independent machine.core _ _ _ _)

/-- Pins executed by the adapter are exactly the pins of the actual CPU
transition, not merely a speculative probe. -/
theorem pins_refine_actual (machine : Machine) (wake : Bool) :
    (stepMachineCycle machine wake).pins =
      HalfEdge.expand (stepMachineCycle machine wake).cpuOutput.intent := by
  exact probe_compatible machine wake

/-- The composed transition invokes the immutable processor exactly once with
the temporal response and interrupt input recorded in its output. -/
theorem processor_composition (machine : Machine) (wake : Bool) :
    (stepMachineCycle machine wake).cpuOutput =
      Run.stepMachineCycle machine.core (stepMachineCycle machine wake).cpuInput := by
  rfl

/-- The machine's core post-state is exactly the composed processor post-state. -/
@[simp] theorem core_projection (machine : Machine) (wake : Bool) :
    (stepMachineCycle machine wake).machine.core =
      (stepMachineCycle machine wake).cpuOutput.state := by
  rfl

/-- Half-edge accounting is exact and type-distinct from T/M-cycle counts. -/
@[simp] theorem halfEdge_count (machine : Machine) (wake : Bool) :
    (stepMachineCycle machine wake).machine.halfEdgeCount = machine.halfEdgeCount + 8 := by
  simp [stepMachineCycle]

end Battle.GameBoy.Adapter
