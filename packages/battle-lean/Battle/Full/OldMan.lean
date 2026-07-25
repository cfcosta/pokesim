/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Rom.Tables

/-!
# Old Man tutorial name/encounter alias

The tutorial saves eleven player-name bytes over `wGrassRate` and the beginning
of `wGrassMons`, then installs eleven bytes starting at the inline `"OLD MAN@"`
label. The source label contains only eight text bytes: the remaining three are
the following opcodes `$FA,$2D,$CC`. The Ball path restores the player name from
the alias but deliberately leaves those encounter bytes overwritten.
-/

namespace Battle.Full.OldMan

open Battle.Rom.Closure

abbrev NameBlock := List UInt8

private def nameLength : Nat := 11

/-- Fixed-width `CopyData` source view; malformed short names are padded with the
text terminator while long names are truncated. -/
def fixedName (bytes : List UInt8) : NameBlock :=
  bytes.take nameLength ++ List.replicate (nameLength - bytes.length) 0x50

/-- Exact eleven bytes copied from `DisplayBattleMenu.oldManName`. -/
def oldManNameBlock : NameBlock :=
  [0x8E, 0x8B, 0x83, 0x7F, 0x8C, 0x80, 0x8D, 0x50, 0xFA, 0x2D, 0xCC]

structure State where
  playerName : NameBlock
  /-- `wGrassRate` plus the first ten aliased wild-buffer bytes. -/
  grassAlias : NameBlock
  deriving Repr, DecidableEq

/-- `DisplayBattleMenu` saves the real name into the encounter alias and writes
`OLD MAN@` plus three following opcode bytes into the player-name block. -/
def beginTutorial (state : State) : State :=
  { playerName := oldManNameBlock
    grassAlias := fixedName state.playerName }

/-- The Ball path restores only the player name. -/
def captureRestore (state : State) : State :=
  { state with playerName := state.grassAlias }

@[simp] theorem begin_installs_exact_old_man_block (state : State) :
    (beginTutorial state).playerName = oldManNameBlock := rfl

@[simp] theorem capture_restores_name_but_retains_alias (state : State) :
    let begun := beginTutorial state
    let restored := captureRestore begun
    restored.playerName = fixedName state.playerName ∧
      restored.grassAlias = fixedName state.playerName := by
  simp [beginTutorial, captureRestore, fixedName, nameLength]

/-- Bytes after the text terminator are the next three canonical opcodes, not
zero padding. -/
theorem old_man_trailing_opcode_bytes : oldManNameBlock.drop 8 = [0xFA, 0x2D, 0xCC] := by
  native_decide

private def oldManNameEntry : UInt16 := 0x4F12
private def oldManNameRomBytes : List Sm83.Byte :=
  [0x8E, 0x8B, 0x83, 0x7F, 0x8C, 0x80, 0x8D, 0x50, 0xFA, 0x2D, 0xCC]

structure RequiredOldManBytes (rom : Array Sm83.Byte) : Prop where
  nameWindow : Battle.Rom.Tables.tableBytes rom
      (romOffset 0x0F (Sm83.Word.ofNat oldManNameEntry.toNat)) oldManNameRomBytes.length =
    oldManNameRomBytes.map (fun byte => byte.toNat.toUInt8)

/-- Runtime fixture predicate only. -/
def windowAgrees (rom : Array Sm83.Byte) : Bool :=
  decide (Battle.Rom.Tables.tableBytes rom
    (romOffset 0x0F (Sm83.Word.ofNat oldManNameEntry.toNat)) oldManNameRomBytes.length =
      oldManNameRomBytes.map (fun byte => byte.toNat.toUInt8))

end Battle.Full.OldMan
