/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

import Battle.GameBoy.Memory

namespace Battle.Rom.Closure

open Sm83

abbrev Sha256 := Array Byte → String

def canonicalRedSha1 : String := "ea9bcae617fdf159b045185467ae58b2e4a48b9a"
def canonicalRedSha256 : String :=
  "5ca7ba01642a3b27b0cc0b5349b52792795b62d3ed977e98a09390659af96b7b"

structure CanonicalRom where
  bytes : Array Byte
  deriving Repr, DecidableEq

/-- ROM identity is checked by a caller-supplied hash implementation; ROM bytes
are not vendored in the proof package. -/
def CanonicalRom.Valid (sha256 : Sha256) (rom : CanonicalRom) : Prop :=
  rom.bytes.size = 0x100000 ∧ sha256 rom.bytes = canonicalRedSha256

inductive CpuRegion where
  | fixedRomOrBoot | switchableRom | vram | externalRam | wram | wramEcho
  | oam | unusable | mmio | hram | interruptEnable
  deriving Repr, DecidableEq

/-- Total, non-overlapping CPU-bus classification from the retained manifest. -/
def classify (address : Word) : CpuRegion :=
  let value := address.toNat
  if value < 0x4000 then .fixedRomOrBoot
  else if value < 0x8000 then .switchableRom
  else if value < 0xA000 then .vram
  else if value < 0xC000 then .externalRam
  else if value < 0xE000 then .wram
  else if value < 0xFE00 then .wramEcho
  else if value < 0xFEA0 then .oam
  else if value < 0xFF00 then .unusable
  else if value < 0xFF80 then .mmio
  else if value < 0xFFFF then .hram
  else .interruptEnable

/-- Executable regions admitted by the conservative closure. The episode
invariant narrows WRAM/echo/HRAM targets and proves canonical ROM fetches. -/
def fetchable : CpuRegion → Bool
  | .fixedRomOrBoot | .switchableRom | .wram | .wramEcho | .hram => true
  | _ => false

private def inClassifiedRange (region : CpuRegion) (address : Nat) : Bool :=
  match region with
  | .fixedRomOrBoot => address < 0x4000
  | .switchableRom => 0x4000 ≤ address && address < 0x8000
  | .vram => 0x8000 ≤ address && address < 0xA000
  | .externalRam => 0xA000 ≤ address && address < 0xC000
  | .wram => 0xC000 ≤ address && address < 0xE000
  | .wramEcho => 0xE000 ≤ address && address < 0xFE00
  | .oam => 0xFE00 ≤ address && address < 0xFEA0
  | .unusable => 0xFEA0 ≤ address && address < 0xFF00
  | .mmio => 0xFF00 ≤ address && address < 0xFF80
  | .hram => 0xFF80 ≤ address && address < 0xFFFF
  | .interruptEnable => address = 0xFFFF

/-- All 65,536 CPU addresses belong to exactly the range selected by
`classify`; there is no omitted indirect/MMIO target. -/
theorem classify_sound : ∀ address : Word,
    inClassifiedRange (classify address) address.toNat := by
  native_decide

/-- Classification is functional, hence no address can belong to two selected
regions. -/
theorem classify_unique (address : Word) (first second : CpuRegion)
    (firstEq : classify address = first) (secondEq : classify address = second) :
    first = second := by
  exact firstEq.symm.trans secondEq

/-- Bank/address symbol retained from canonical `pokered.sym`. -/
structure Symbol where
  bank : Byte
  address : Word
  deriving Repr, DecidableEq

namespace Symbols

def initBattle : Symbol := ⟨0x0F, 0x6F12⟩
def initOpponent : Symbol := ⟨0x0F, 0x6F18⟩
def initBattleCommon : Symbol := ⟨0x0F, 0x6FEB⟩
def startBattle : Symbol := ⟨0x0F, 0x411E⟩
def endOfBattle : Symbol := ⟨0x04, 0x77AA⟩
def initBattleVariables : Symbol := ⟨0x14, 0x65AF⟩
def battleRandom : Symbol := ⟨0x0F, 0x6E9B⟩
def random : Symbol := ⟨0x04, 0x7A8F⟩
def delayFrame : Symbol := ⟨0x00, 0x20AF⟩
def vblank : Symbol := ⟨0x00, 0x2024⟩
def wBattleResult : Symbol := ⟨0x00, 0xCF0B⟩
def wIsInBattle : Symbol := ⟨0x00, 0xD057⟩

end Symbols

@[inline] def romOffset (bank : Nat) (address : Word) : Nat :=
  if address.toNat < 0x4000 then address.toNat
  else bank * 0x4000 + address.toNat - 0x4000

/-- Every selected in-image MBC3 ROM address has an offset in the retained
one-megabyte image. -/
theorem romOffset_in_image (bank : Nat) (address : Word)
    (bankRange : bank < 64) (window : address.toNat < 0x8000) :
    romOffset bank address < 0x100000 := by
  unfold romOffset
  split <;> omega

/-- Canonical execution must preserve this bank bound; out-of-image MBC3 reads
remain defined as open bus but are not silently treated as ROM data. -/
def RomBankInImage (state : GameBoy.Mbc3.State) : Prop :=
  GameBoy.Mbc3.selectedRomBank state < 64

@[simp] theorem initial_rom_bank_in_image (rom ram : Array Byte) :
    RomBankInImage { rom, ram } := by
  simp [RomBankInImage, GameBoy.Mbc3.selectedRomBank]

/-- The conservative manifest includes every physical ROM byte and external RAM
byte, while CPU-bus classification covers every possible direct or indirect
address. -/
structure CompleteClosure where
  romBanks : Nat := 64
  romBankSize : Nat := 0x4000
  externalRamBanks : Nat := 4
  externalRamBankSize : Nat := 0x2000
  romComplete : romBanks * romBankSize = 0x100000 := by decide
  ramComplete : externalRamBanks * externalRamBankSize = 0x8000 := by decide

@[simp] theorem complete_rom_bytes (closure : CompleteClosure) :
    closure.romBanks * closure.romBankSize = 0x100000 := closure.romComplete

end Battle.Rom.Closure
