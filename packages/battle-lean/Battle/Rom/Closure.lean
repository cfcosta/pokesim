/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

import Battle.GameBoy.Memory
import Sm83.Decode

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
def initBattleSetup : Symbol := ⟨0x0F, 0x6F3D⟩
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

@[inline] def bytesAt (rom : Array Byte) (offset count : Nat) : List Byte :=
  (List.range count).map fun index => GameBoy.Mbc3.readArray rom (offset + index)

def initOpponentPrefix : List Byte :=
  [0xFA, 0x59, 0xD0, 0xEA, 0x91, 0xCF, 0xEA, 0xD8,
    0xCF, 0x18, 0x1A, 0xFA, 0x32, 0xD7, 0xCB, 0x4F]

def initBattleCommonPrefix : List Byte :=
  [0x06, 0x00, 0xCD, 0xEF, 0x3D, 0xCD, 0x4C, 0x40,
    0xAF, 0xE0, 0xBA, 0x21, 0x4A, 0x70, 0xCD, 0x49]

def startBattlePrefix : List Byte :=
  [0xAF, 0xEA, 0x58, 0xD0, 0xEA, 0xF5, 0xCC, 0xEA,
    0x6A, 0xCD, 0x3C, 0xEA, 0x1D, 0xD1, 0x21, 0xA5]

/-- Hash-checked callers additionally provide these retained local byte
witnesses. This avoids treating an uninterpreted hash function as a Lean proof
of individual ROM bytes. -/
structure RequiredEntryBytes (rom : Array Byte) : Prop where
  initOpponent : bytesAt rom
    (romOffset Symbols.initOpponent.bank.toNat Symbols.initOpponent.address) 16 =
      initOpponentPrefix
  initBattleCommon : bytesAt rom
    (romOffset Symbols.initBattleCommon.bank.toNat Symbols.initBattleCommon.address) 16 =
      initBattleCommonPrefix
  startBattle : bytesAt rom
    (romOffset Symbols.startBattle.bank.toNat Symbols.startBattle.address) 16 =
      startBattlePrefix

@[simp] theorem RequiredEntryBytes.initOpponent_opcode {rom : Array Byte}
    (witness : RequiredEntryBytes rom) :
    GameBoy.Mbc3.readArray rom
      (romOffset Symbols.initOpponent.bank.toNat Symbols.initOpponent.address) = 0xFA := by
  have first := congrArg (fun bytes => bytes[0]?) witness.initOpponent
  simpa [bytesAt, initOpponentPrefix] using first

@[simp] theorem RequiredEntryBytes.initOpponent_immediateLow {rom : Array Byte}
    (witness : RequiredEntryBytes rom) :
    GameBoy.Mbc3.readArray rom
      (romOffset Symbols.initOpponent.bank.toNat Symbols.initOpponent.address + 1) = 0x59 := by
  have second := congrArg (fun bytes => bytes[1]?) witness.initOpponent
  simpa [bytesAt, initOpponentPrefix] using second

@[simp] theorem RequiredEntryBytes.initOpponent_immediateHigh {rom : Array Byte}
    (witness : RequiredEntryBytes rom) :
    GameBoy.Mbc3.readArray rom
      (romOffset Symbols.initOpponent.bank.toNat Symbols.initOpponent.address + 2) = 0xD0 := by
  have third := congrArg (fun bytes => bytes[2]?) witness.initOpponent
  simpa [bytesAt, initOpponentPrefix] using third

@[simp] theorem RequiredEntryBytes.initOpponent_successor {rom : Array Byte}
    (witness : RequiredEntryBytes rom) :
    GameBoy.Mbc3.readArray rom
      (romOffset Symbols.initOpponent.bank.toNat Symbols.initOpponent.address + 3) = 0xEA := by
  have fourth := congrArg (fun bytes => bytes[3]?) witness.initOpponent
  simpa [bytesAt, initOpponentPrefix] using fourth

@[simp] theorem RequiredEntryBytes.initOpponent_storeLow {rom : Array Byte}
    (witness : RequiredEntryBytes rom) :
    GameBoy.Mbc3.readArray rom
      (romOffset Symbols.initOpponent.bank.toNat Symbols.initOpponent.address + 4) = 0x91 := by
  have byte := congrArg (fun bytes => bytes[4]?) witness.initOpponent
  simpa [bytesAt, initOpponentPrefix] using byte

@[simp] theorem RequiredEntryBytes.initOpponent_storeHigh {rom : Array Byte}
    (witness : RequiredEntryBytes rom) :
    GameBoy.Mbc3.readArray rom
      (romOffset Symbols.initOpponent.bank.toNat Symbols.initOpponent.address + 5) = 0xCF := by
  have byte := congrArg (fun bytes => bytes[5]?) witness.initOpponent
  simpa [bytesAt, initOpponentPrefix] using byte

@[simp] theorem RequiredEntryBytes.initOpponent_storeSuccessor {rom : Array Byte}
    (witness : RequiredEntryBytes rom) :
    GameBoy.Mbc3.readArray rom
      (romOffset Symbols.initOpponent.bank.toNat Symbols.initOpponent.address + 6) = 0xEA := by
  have byte := congrArg (fun bytes => bytes[6]?) witness.initOpponent
  simpa [bytesAt, initOpponentPrefix] using byte

@[simp] theorem RequiredEntryBytes.initOpponent_secondStoreLow {rom : Array Byte}
    (witness : RequiredEntryBytes rom) :
    GameBoy.Mbc3.readArray rom
      (romOffset Symbols.initOpponent.bank.toNat Symbols.initOpponent.address + 7) = 0xD8 := by
  have byte := congrArg (fun bytes => bytes[7]?) witness.initOpponent
  simpa [bytesAt, initOpponentPrefix] using byte

@[simp] theorem RequiredEntryBytes.initOpponent_secondStoreHigh {rom : Array Byte}
    (witness : RequiredEntryBytes rom) :
    GameBoy.Mbc3.readArray rom
      (romOffset Symbols.initOpponent.bank.toNat Symbols.initOpponent.address + 8) = 0xCF := by
  have byte := congrArg (fun bytes => bytes[8]?) witness.initOpponent
  simpa [bytesAt, initOpponentPrefix] using byte

@[simp] theorem RequiredEntryBytes.initOpponent_jumpOpcode {rom : Array Byte}
    (witness : RequiredEntryBytes rom) :
    GameBoy.Mbc3.readArray rom
      (romOffset Symbols.initOpponent.bank.toNat Symbols.initOpponent.address + 9) = 0x18 := by
  have byte := congrArg (fun bytes => bytes[9]?) witness.initOpponent
  simpa [bytesAt, initOpponentPrefix] using byte

@[simp] theorem RequiredEntryBytes.initOpponent_jumpOffset {rom : Array Byte}
    (witness : RequiredEntryBytes rom) :
    GameBoy.Mbc3.readArray rom
      (romOffset Symbols.initOpponent.bank.toNat Symbols.initOpponent.address + 10) = 0x1A := by
  have byte := congrArg (fun bytes => bytes[10]?) witness.initOpponent
  simpa [bytesAt, initOpponentPrefix] using byte

/-- The retained first entry byte decodes as canonical `LD A,(a16)`. -/
@[simp] theorem initOpponent_opcode_decode :
    Decode.base 0xFA = .legal .ldAAbs := by
  decide

/-- The cartridge mapping selects a symbol's physical bank. Fixed-bank
symbols require bank zero; switchable symbols require the live MBC3 bank. -/
def Symbol.Selected (cartridge : GameBoy.Mbc3.State) (symbol : Symbol) : Prop :=
  if symbol.address.toNat < 0x4000 then symbol.bank.toNat = 0
  else GameBoy.Mbc3.selectedRomBank cartridge = symbol.bank.toNat

/-- A selected, boot-unmapped ROM symbol reads the exact canonical physical
array offset rather than a label-derived translation. -/
theorem read_selected_symbol (memory : GameBoy.Memory.State) (symbol : Symbol)
    (unmapped : memory.bootMapped = false)
    (window : symbol.address.toNat < 0x8000)
    (selected : symbol.Selected memory.cartridge) :
    GameBoy.Memory.read memory symbol.address =
      GameBoy.Mbc3.readArray memory.cartridge.rom
        (romOffset symbol.bank.toNat symbol.address) := by
  rw [GameBoy.Memory.read_rom_unmapped memory symbol.address unmapped window]
  unfold Symbol.Selected at selected
  by_cases fixed : symbol.address.toNat < 0x4000
  · rw [GameBoy.Mbc3.read_fixed_rom memory.cartridge symbol.address fixed]
    simp [romOffset, fixed]
  · have low : 0x4000 ≤ symbol.address.toNat := by omega
    rw [GameBoy.Mbc3.read_switchable_rom memory.cartridge symbol.address low window]
    simp [fixed] at selected
    simp [romOffset, fixed, selected]

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
