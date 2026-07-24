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

@[simp] private theorem advanceReload_divider (state : State) :
    (advanceReload state).divider = state.divider := by
  cases reload : state.timerReloadDelay with
  | none => simp [advanceReload, reload]
  | some delay => cases delay <;> simp [advanceReload, reload, requestInterrupt]

/-- Advance timer, divider, PPU, and serial by one system T-cycle. -/
def tickT (state : State) : State :=
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
      bitsRemaining := if value.toNat / 128 = 1 then 8 else state.serial.bitsRemaining } }
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

/-- Five maskable interrupt lines visible to the SM83. -/
@[inline] def pendingInterrupts (state : State) : Byte :=
  (state.interruptEnable &&& state.interruptFlags) &&& 0x1F

@[simp] theorem tickT_divider (state : State) :
    (tickT state).divider = (state.divider + 1) % 0x10000 := by
  simp only [tickT, advanceReload_divider]

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
