/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

import Sm83.Clock
import Sm83.Byte

namespace Battle.GameBoy.Devices

open Sm83

structure Joypad where
  /-- Active-low d-pad nibble: Right, Left, Up, Down. -/
  directions : Byte := 0x0F
  /-- Active-low button nibble: A, B, Select, Start. -/
  buttons : Byte := 0x0F
  /-- CPU-written selection bits P14/P15 in bits 4/5. -/
  select : Byte := 0x30
  deriving Repr, DecidableEq

structure Serial where
  data : Byte := 0
  control : Byte := 0
  bitsRemaining : Nat := 0
  clockDivider : Nat := 0
  deriving Repr, DecidableEq

structure State where
  /-- Internal 16-bit divider counter; `$FF04` exposes its high byte. -/
  divider : Nat := 0
  tima : Byte := 0
  tma : Byte := 0
  tac : Byte := 0
  timerReloadDelay : Option Nat := none
  interruptFlags : Byte := 0xE1
  interruptEnable : Byte := 0
  ppuDot : Nat := 0
  lcdc : Byte := 0x91
  joypad : Joypad := {}
  serial : Serial := {}
  dmaSource : Byte := 0
  dmaIndex : Option Nat := none
  bootDisable : Byte := 0
  deriving Repr, DecidableEq

@[inline] def requestInterrupt (state : State) (bit : Nat) : State :=
  { state with interruptFlags := state.interruptFlags ||| Byte.ofNat (1 <<< bit) }

@[inline] def timerBit (tac : Byte) : Nat :=
  match tac.toNat % 4 with
  | 0 => 9
  | 1 => 3
  | 2 => 5
  | _ => 7

@[inline] def timerSignal (state : State) : Bool :=
  let enabled := (state.tac.toNat / 4) % 2 = 1
  let high := (state.divider / (2 ^ timerBit state.tac)) % 2 = 1
  enabled && high

private def advanceReload (state : State) : State :=
  match state.timerReloadDelay with
  | none => state
  | some 0 =>
      requestInterrupt { state with tima := state.tma, timerReloadDelay := none } 2
  | some (delay + 1) => { state with timerReloadDelay := some delay }

private def incrementTimer (state : State) : State :=
  if state.tima = 0xFF then
    { state with tima := 0, timerReloadDelay := some 4 }
  else { state with tima := Byte.ofNat (state.tima.toNat + 1) }

def serialClockEdge (state : State) (incoming : Bool) : State :=
  if state.serial.bitsRemaining = 0 then state
  else
    let data := (state.serial.data <<< 1) ||| if incoming then 1 else 0
    let remaining := state.serial.bitsRemaining - 1
    let serial := { state.serial with data := data }
    let serial := { serial with bitsRemaining := remaining }
    let serial := { serial with clockDivider := 0 }
    let state := { state with serial := serial }
    if remaining = 0 then requestInterrupt state 3 else state

def tickSerialInternal (state : State) : State :=
  if state.serial.bitsRemaining = 0 || state.serial.control &&& 1 = 0 then state
  else if state.serial.clockDivider = 511 then serialClockEdge state true
  else { state with serial := { state.serial with
    clockDivider := state.serial.clockDivider + 1 } }

/-- One externally supplied serial clock edge. Externally clocked transfers never
advance merely from `tickT`; the caller supplies each edge and input bit. -/
def externalSerialEdge (state : State) (incoming : Bool) : State :=
  if state.serial.control &&& 1 != 0 then state else serialClockEdge state incoming

@[simp] private theorem advanceReload_divider (state : State) :
    (advanceReload state).divider = state.divider := by
  cases reload : state.timerReloadDelay with
  | none => simp [advanceReload, reload]
  | some delay => cases delay <;> simp [advanceReload, reload, requestInterrupt]

/-- Advance every oscillator-owned device except serial by one system T-cycle.
The ordinary single-console adapter applies `tickSerialInternal` afterwards;
the paired link adapter instead clocks both serial endpoints from one cable edge. -/
def tickTBase (state : State) : State :=
  let state := advanceReload state
  let oldSignal := timerSignal state
  let divider := (state.divider + 1) % 0x10000
  let next := { state with divider }
  let next := if oldSignal && !timerSignal next then incrementTimer next else next
  let oldDot := state.ppuDot
  let ppuDot := (oldDot + 1) % 70224
  let next := { next with ppuDot }
  let next := if oldDot = 144 * 456 - 1 then requestInterrupt next 0 else next
  { next with divider }

/-- Advance timer, divider, PPU, and internally clocked serial by one standalone
system T-cycle. -/
def tickT (state : State) : State :=
  tickSerialInternal (tickTBase state)

/-- Clock ownership retained by the physical paired adapter. -/
inductive CableClockRole where
  | internal | external
  deriving Repr, DecidableEq, BEq

def serialOutputBit (state : State) : Bool := state.serial.data &&& 0x80 != 0

/-- One cable edge shifts both cartridge perspectives from the pre-edge output
bits. Clock-role policy decides when this function is called. -/
def exchangeSerialEdge (left right : State) : State × State :=
  let leftBit := serialOutputBit left
  let rightBit := serialOutputBit right
  (serialClockEdge left rightBit, serialClockEdge right leftBit)

private def tickLeftCableOwner (left right : State) : State × State :=
  if left.serial.bitsRemaining = 0 || left.serial.control &&& 1 = 0 then (left, right)
  else if left.serial.clockDivider = 511 then exchangeSerialEdge left right
  else ({ left with serial := { left.serial with
    clockDivider := left.serial.clockDivider + 1 } }, right)

private def tickRightCableOwner (left right : State) : State × State :=
  if right.serial.bitsRemaining = 0 || right.serial.control &&& 1 = 0 then (left, right)
  else if right.serial.clockDivider = 511 then exchangeSerialEdge left right
  else (left, { right with serial := { right.serial with
    clockDivider := right.serial.clockDivider + 1 } })

/-- Advance selected console oscillators at one interleaved physical T-cycle,
then drive one shared cable edge if the selected internal-clock endpoint reaches
its 512-T divider boundary. The external endpoint shifts from that edge even
when its own oscillator is not selected. Equal roles are an inadmissible link
entry and intentionally produce no invented clock owner. -/
def tickCableT (leftRole rightRole : CableClockRole)
    (tickLeft tickRight : Bool) (left right : State) : State × State :=
  let left := if tickLeft then tickTBase left else left
  let right := if tickRight then tickTBase right else right
  match leftRole, rightRole with
  | .internal, .external => if tickLeft then tickLeftCableOwner left right else (left, right)
  | .external, .internal => if tickRight then tickRightCableOwner left right else (left, right)
  | _, _ => (left, right)

@[inline] def ly (state : State) : Byte := Byte.ofNat (state.ppuDot / 456)

/-- Joypad register with inactive upper bits and active-low selected groups. -/
def readJoypad (joypad : Joypad) : Byte :=
  let select := joypad.select &&& 0x30
  let low := if select.toNat = 0x20 then joypad.directions
    else if select.toNat = 0x10 then joypad.buttons
    else if select.toNat = 0 then joypad.directions &&& joypad.buttons
    else 0x0F
  0xC0 ||| select ||| (low &&& 0x0F)

/-- Device-owned MMIO read. Unimplemented presentation registers are open bus;
they remain outside the deterministic common-boot profile until needed. -/
def read (state : State) (address : Word) : Byte :=
  match address.toNat with
  | 0xFF00 => readJoypad state.joypad
  | 0xFF01 => state.serial.data
  | 0xFF02 => state.serial.control ||| 0x7E
  | 0xFF04 => Byte.ofNat (state.divider / 256)
  | 0xFF05 => state.tima
  | 0xFF06 => state.tma
  | 0xFF07 => state.tac ||| 0xF8
  | 0xFF0F => state.interruptFlags ||| 0xE0
  | 0xFF40 => state.lcdc
  | 0xFF44 => ly state
  | 0xFF46 => state.dmaSource
  | 0xFF50 => state.bootDisable
  | 0xFFFF => state.interruptEnable
  | _ => 0xFF

/-- Device-owned MMIO write. -/
def write (state : State) (address : Word) (value : Byte) : State :=
  match address.toNat with
  | 0xFF00 => { state with joypad := { state.joypad with select := value &&& 0x30 } }
  | 0xFF01 => { state with serial := { state.serial with data := value } }
  | 0xFF02 => { state with serial := {
      state.serial with
      control := value &&& 0x81
      bitsRemaining := if value.toNat / 128 = 1 then 8 else state.serial.bitsRemaining
      clockDivider := 0 } }
  | 0xFF04 => { state with divider := 0 }
  | 0xFF05 => { state with tima := value, timerReloadDelay := none }
  | 0xFF06 => { state with tma := value }
  | 0xFF07 => { state with tac := value &&& 0x07 }
  | 0xFF0F => { state with interruptFlags := value &&& 0x1F }
  | 0xFF40 => { state with lcdc := value }
  | 0xFF44 => state
  | 0xFF46 => { state with dmaSource := value, dmaIndex := some 0 }
  | 0xFF50 => { state with bootDisable := value }
  | 0xFFFF => { state with interruptEnable := value }
  | _ => state

@[simp] theorem serial_edge_decrements_eight_bit_transfer (state : State)
    (active : state.serial.bitsRemaining = 8) (incoming : Bool) :
    (serialClockEdge state incoming).serial.bitsRemaining = 7 := by
  simp [serialClockEdge, active]

inductive AudioWaitStep where
  | waiting
  | completed
  deriving Repr, DecidableEq, BEq

def audioWaitStep (response : Bool) : AudioWaitStep :=
  if response then .completed else .waiting

@[simp] theorem audio_wait_requires_explicit_progress :
    audioWaitStep false = .waiting ∧ audioWaitStep true = .completed := by
  native_decide

structure ExternalResponses where
  joypad : Joypad
  serialBit : Option Bool
  haltWake : Bool
  audioProgress : Bool
  deriving Repr, DecidableEq

/-- External inputs are explicit state updates, not values synthesized from the
battle RNG. -/
def applyExternal (state : State) (response : ExternalResponses) : State :=
  let state := { state with joypad := response.joypad }
  match response.serialBit with
  | none => state
  | some bit => externalSerialEdge state bit

@[simp] theorem no_external_serial_edge_stutters_clocked_input (state : State)
    (response : ExternalResponses) (none : response.serialBit = none) :
    (applyExternal state response).serial.bitsRemaining = state.serial.bitsRemaining := by
  simp [applyExternal, none]

/-- Five maskable interrupt lines visible to the SM83. -/
@[inline] def pendingInterrupts (state : State) : Byte :=
  (state.interruptEnable &&& state.interruptFlags) &&& 0x1F

@[simp] theorem joypad_selected_groups (directions buttons : Byte) :
    readJoypad { directions, buttons, select := 0 } =
      0xC0 ||| (directions &&& buttons &&& 0x0F) := by
  simp [readJoypad]

@[simp] theorem ly_tracks_ppu_dot (state : State) :
    (ly state).toNat = (state.ppuDot / 456) % 256 := by
  simp [ly, Byte.ofNat]

@[simp] theorem tickSerialInternal_divider (state : State) :
    (tickSerialInternal state).divider = state.divider := by
  unfold tickSerialInternal
  split
  · rfl
  · split
    · simp only [serialClockEdge]
      split
      · rfl
      · split <;> rfl
    · rfl

@[simp] theorem tickTBase_divider (state : State) :
    (tickTBase state).divider = (state.divider + 1) % 0x10000 := by
  simp [tickTBase, advanceReload_divider]

@[simp] theorem tickT_divider (state : State) :
    (tickT state).divider = (state.divider + 1) % 0x10000 := by
  simp [tickT]

private theorem lowFive_lt : ∀ value : Byte, (value &&& 0x1F).toNat < 32 := by
  native_decide

@[simp] theorem pendingInterrupts_range (state : State) :
    (pendingInterrupts state).toNat < 32 := by
  exact lowFive_lt _

/-- The only bonded interrupt sources on the Game Boy CPU package. NMI is absent
from this exhaustive type rather than tied to an invented level. -/
inductive BondedInterruptLine where
  | vblank | lcdStat | timer | serial | joypad
  deriving Repr, DecidableEq

@[simp] theorem bonded_interrupt_line_count :
    [BondedInterruptLine.vblank, .lcdStat, .timer, .serial, .joypad].length = 5 := rfl

end Battle.GameBoy.Devices
