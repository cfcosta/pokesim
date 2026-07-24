/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

import Sm83.Byte

namespace Battle.GameBoy.Mbc3

open Sm83

@[inline] def readArray (bytes : Array Byte) (index : Nat) : Byte :=
  bytes[index]?.getD 0xFF

@[inline] def writeArray (bytes : Array Byte) (index : Nat) (value : Byte) : Array Byte :=
  if valid : index < bytes.size then bytes.set index value valid else bytes

/-- MBC3 state for Red's no-RTC `MBC3+RAM+BATTERY` cartridge. -/
structure State where
  rom : Array Byte
  ram : Array Byte := Array.replicate 0x8000 0
  ramEnabled : Bool := false
  romBank : Byte := 1
  ramBank : Byte := 0
  deriving Repr, DecidableEq

@[inline] def selectedRomBank (state : State) : Nat :=
  let bank := state.romBank.toNat % 128
  if bank = 0 then 1 else bank

@[inline] def selectedRamBank (state : State) : Nat := state.ramBank.toNat % 4

/-- Read one cartridge-bus address. The caller only supplies `$0000-$7FFF` or
`$A000-$BFFF`; other addresses are open bus. -/
def read (state : State) (address : Word) : Byte :=
  let value := address.toNat
  if value < 0x4000 then readArray state.rom value
  else if value < 0x8000 then
    readArray state.rom (selectedRomBank state * 0x4000 + value - 0x4000)
  else if 0xA000 ≤ value && value < 0xC000 then
    if state.ramEnabled then
      readArray state.ram (selectedRamBank state * 0x2000 + value - 0xA000)
    else 0xFF
  else 0xFF

/-- Apply one cartridge control/RAM write. ROM bytes are immutable. -/
def write (state : State) (address : Word) (value : Byte) : State :=
  let target := address.toNat
  if target < 0x2000 then
    { state with ramEnabled := value.toNat % 16 = 0xA }
  else if target < 0x4000 then
    { state with romBank := value &&& 0x7F }
  else if target < 0x6000 then
    { state with ramBank := value &&& 0x03 }
  else if target < 0x8000 then
    state -- RTC latch is absent on Red's cartridge type.
  else if 0xA000 ≤ target && target < 0xC000 && state.ramEnabled then
    let ram := writeArray state.ram
      (selectedRamBank state * 0x2000 + target - 0xA000) value
    { state with ram }
  else state

@[simp] theorem selectedRomBank_zero (state : State) (zero : state.romBank.toNat % 128 = 0) :
    selectedRomBank state = 1 := by
  simp [selectedRomBank, zero]

@[simp] theorem read_disabled_ram (state : State) (address : Word)
    (range : 0xA000 ≤ address.toNat ∧ address.toNat < 0xC000)
    (disabled : state.ramEnabled = false) :
    read state address = 0xFF := by
  have notLow : ¬address.toNat < 0x4000 := by omega
  have notRom : ¬address.toNat < 0x8000 := by omega
  simp [read, notLow, notRom, range.1, range.2, disabled]

/-- Cartridge writes never alter immutable ROM storage. -/
@[simp] theorem write_preserves_rom (state : State) (address : Word) (value : Byte) :
    (write state address value).rom = state.rom := by
  simp only [write]
  grind

/-- Disabled external-RAM writes leave the full cartridge state unchanged. -/
theorem disabled_ram_write_stutters (state : State) (address : Word) (value : Byte)
    (range : 0xA000 ≤ address.toNat ∧ address.toNat < 0xC000)
    (disabled : state.ramEnabled = false) :
    write state address value = state := by
  have not0 : ¬address.toNat < 0x2000 := by omega
  have not1 : ¬address.toNat < 0x4000 := by omega
  have not2 : ¬address.toNat < 0x6000 := by omega
  have not3 : ¬address.toNat < 0x8000 := by omega
  simp [write, not0, not1, not2, not3, range.1, range.2, disabled]

end Battle.GameBoy.Mbc3
