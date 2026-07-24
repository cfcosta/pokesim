/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

import Battle.GameBoy.Mbc3
import Battle.GameBoy.Devices

namespace Battle.GameBoy.Memory

open Sm83

/-- The canonical 256-byte DMG boot ROM remains caller-supplied. -/
structure BootRom where
  bytes : Array Byte
  deriving Repr, DecidableEq

abbrev Sha256 := Array Byte → String

def canonicalDmgBootSha256 : String :=
  "cf053eccb4ccafff9e67339d4e78e98dce7d1ed59be819d2a1ba2232c6fce1c7"

/-- A caller-supplied hash implementation identifies boot bytes without
vendoring them into this project. -/
def BootRom.Valid (sha256 : Sha256) (boot : BootRom) : Prop :=
  boot.bytes.size = 256 ∧ sha256 boot.bytes = canonicalDmgBootSha256

structure State where
  cartridge : Mbc3.State
  bootRom : BootRom
  bootMapped : Bool := true
  vram : Array Byte := Array.replicate 0x2000 0
  wram : Array Byte := Array.replicate 0x2000 0
  oam : Array Byte := Array.replicate 0xA0 0
  io : Array Byte := Array.replicate 0x80 0xFF
  hram : Array Byte := Array.replicate 0x7F 0
  devices : Devices.State := {}
  deriving Repr, DecidableEq

private def deviceOwned : Nat → Bool
  | 0xFF00 | 0xFF01 | 0xFF02 | 0xFF04 | 0xFF05 | 0xFF06 | 0xFF07
  | 0xFF0F | 0xFF40 | 0xFF44 | 0xFF46 | 0xFF50 | 0xFFFF => true
  | _ => false

/-- DMG CPU address-space read, including WRAM echo and unusable OAM space. -/
def read (state : State) (address : Word) : Byte :=
  let target := address.toNat
  if target < 0x8000 then
    if state.bootMapped && target < 0x100 then Mbc3.readArray state.bootRom.bytes target
    else Mbc3.read state.cartridge address
  else if target < 0xA000 then Mbc3.readArray state.vram (target - 0x8000)
  else if target < 0xC000 then Mbc3.read state.cartridge address
  else if target < 0xE000 then Mbc3.readArray state.wram (target - 0xC000)
  else if target < 0xFE00 then Mbc3.readArray state.wram (target - 0xE000)
  else if target < 0xFEA0 then Mbc3.readArray state.oam (target - 0xFE00)
  else if target < 0xFF00 then 0xFF
  else if target < 0xFF80 then
    if deviceOwned target then Devices.read state.devices address
    else Mbc3.readArray state.io (target - 0xFF00)
  else if target < 0xFFFF then Mbc3.readArray state.hram (target - 0xFF80)
  else Devices.read state.devices address

/-- DMG CPU address-space write. Boot ROM disable is one-way for the running
system; reset constructs a fresh mapped state. -/
def write (state : State) (address : Word) (value : Byte) : State :=
  let target := address.toNat
  if target < 0x8000 then
    { state with cartridge := Mbc3.write state.cartridge address value }
  else if target < 0xA000 then
    { state with vram := Mbc3.writeArray state.vram (target - 0x8000) value }
  else if target < 0xC000 then
    { state with cartridge := Mbc3.write state.cartridge address value }
  else if target < 0xE000 then
    { state with wram := Mbc3.writeArray state.wram (target - 0xC000) value }
  else if target < 0xFE00 then
    { state with wram := Mbc3.writeArray state.wram (target - 0xE000) value }
  else if target < 0xFEA0 then
    { state with oam := Mbc3.writeArray state.oam (target - 0xFE00) value }
  else if target < 0xFF00 then state
  else if target < 0xFF80 then
    if deviceOwned target then
      let devices := Devices.write state.devices address value
      { state with
        devices
        bootMapped := if target = 0xFF50 && value.toNat ≠ 0 then false else state.bootMapped }
    else { state with io := Mbc3.writeArray state.io (target - 0xFF00) value }
  else if target < 0xFFFF then
    { state with hram := Mbc3.writeArray state.hram (target - 0xFF80) value }
  else { state with devices := Devices.write state.devices address value }

/-- One DMA byte is copied per machine cycle after `$FF46` starts a transfer. -/
def stepDma (state : State) : State :=
  match state.devices.dmaIndex with
  | none => state
  | some index =>
      if index < 160 then
        let source := Word.ofNat (state.devices.dmaSource.toNat * 0x100 + index)
        let value := read state source
        let oam := Mbc3.writeArray state.oam index value
        let nextIndex := if index + 1 = 160 then none else some (index + 1)
        { state with oam, devices := { state.devices with dmaIndex := nextIndex } }
      else { state with devices := { state.devices with dmaIndex := none } }

@[simp] theorem read_rom_unmapped (state : State) (address : Word)
    (unmapped : state.bootMapped = false) (range : address.toNat < 0x8000) :
    read state address = Mbc3.read state.cartridge address := by
  simp [read, range, unmapped]

@[simp] theorem stepDma_preserves_cartridge (state : State) :
    (stepDma state).cartridge = state.cartridge := by
  simp only [stepDma]
  split <;> rename_i equation
  · rfl
  · split <;> rfl

@[simp] theorem stepDma_preserves_wram (state : State) :
    (stepDma state).wram = state.wram := by
  simp only [stepDma]
  split <;> rename_i equation
  · rfl
  · split <;> rfl

@[simp] theorem stepDma_preserves_bootMapped (state : State) :
    (stepDma state).bootMapped = state.bootMapped := by
  simp only [stepDma]
  split <;> rename_i equation
  · rfl
  · split <;> rfl

@[simp] theorem read_wram (state : State) (address : Word)
    (low : 0xC000 ≤ address.toNat) (high : address.toNat < 0xE000) :
    read state address = Mbc3.readArray state.wram (address.toNat - 0xC000) := by
  have notRom0 : ¬address.toNat < 0x8000 := by omega
  have notVram : ¬address.toNat < 0xA000 := by omega
  have notCart : ¬address.toNat < 0xC000 := by omega
  simp [read, notRom0, notVram, notCart, high]

@[simp] theorem read_boot_mapped (state : State) (address : Word)
    (mapped : state.bootMapped = true) (range : address.toNat < 0x100) :
    read state address = Mbc3.readArray state.bootRom.bytes address.toNat := by
  have low : address.toNat < 0x8000 := by omega
  simp [read, low, mapped, range]

/-- The echo range aliases the same WRAM backing bytes. -/
theorem read_echo (state : State) (address : Word)
    (range : 0xC000 ≤ address.toNat ∧ address.toNat < 0xDE00) :
    read state (Word.ofNat (address.toNat + 0x2000)) = read state address := by
  have sumLt : address.toNat + 0x2000 < 0x10000 := by omega
  have indexEq : address.toNat + 0x2000 - 0xE000 = address.toNat - 0xC000 := by omega
  have right0 : ¬address.toNat < 0x8000 := by omega
  have right1 : ¬address.toNat < 0xA000 := by omega
  have right2 : ¬address.toNat < 0xC000 := by omega
  have right3 : address.toNat < 0xE000 := by omega
  have left0 : ¬address.toNat + 0x2000 < 0x8000 := by omega
  have left1 : ¬address.toNat + 0x2000 < 0xA000 := by omega
  have left2 : ¬address.toNat + 0x2000 < 0xC000 := by omega
  have left3 : ¬address.toNat + 0x2000 < 0xE000 := by omega
  have left4 : address.toNat + 0x2000 < 0xFE00 := by omega
  simp [read, Word.ofNat, Nat.mod_eq_of_lt sumLt, indexEq,
    right0, right1, right2, right3, left0, left1, left2, left3, left4]

/-- Any nonzero `$FF50` write permanently unmaps boot ROM in this running state. -/
theorem disable_boot (state : State) (value : Byte) (nonzero : value.toNat ≠ 0) :
    (write state 0xFF50 value).bootMapped = false := by
  simp [write, deviceOwned, nonzero]

/-- System writes preserve immutable cartridge ROM bytes. -/
@[simp] theorem write_preserves_rom (state : State) (address : Word) (value : Byte) :
    (write state address value).cartridge.rom = state.cartridge.rom := by
  unfold write
  grind [Mbc3.write_preserves_rom]

end Battle.GameBoy.Memory
