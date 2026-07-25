/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Rom.HazeRoutine

/-!
# Caller-supplied canonical ROM fixture

The canonical ROM remains outside the Apache-2.0 package. The root build tool
reconstructs it from the pristine `pokered/` source with pinned RGBDS, verifies
SHA-1/SHA-256, and may copy that verified temporary file to a caller-selected
path. This module is the battle-test side of that boundary: it loads the supplied
bytes and checks the Lean-visible size and retained entry windows before a ROM
decoder consumes them.

A successful runtime check is not promoted to a theorem. Proof modules continue
to accept explicit `CanonicalRom.Valid`, `RequiredEntryBytes`, and table-window
witnesses because Lean cannot derive array-element equalities from an
uninterpreted host hash function.
-/

namespace Battle.Rom.Fixture

open Battle.Rom.Closure

/-- Read a caller-supplied ROM without retaining it in the package. -/
def load (path : System.FilePath) : IO CanonicalRom := do
  let bytes ← IO.FS.readBinFile path
  pure { bytes := bytes.data.map fun byte => Sm83.Byte.ofNat byte.toNat }

/-- Lean-visible checks shared by fixture runners. Hash identity is established
by `tools/check-pokered-build.py` before this function is called. -/
def retainedLayoutMatches (rom : CanonicalRom) : Bool :=
  rom.bytes.size == 0x100000 &&
    decide (bytesAt rom.bytes Symbols.initOpponent.offset 16 = initOpponentPrefix) &&
    decide (bytesAt rom.bytes Symbols.initBattleCommon.offset 16 = initBattleCommonPrefix) &&
    decide (bytesAt rom.bytes Symbols.startBattle.offset 16 = startBattlePrefix) &&
    Tables.agreesWithAuthored rom.bytes &&
    Effects.agreesWithPlan rom.bytes &&
    CombatTables.agreesWithModel rom.bytes &&
    EffectRoutines.leafWindowsAgree rom.bytes &&
    EffectPrefixes.prefixWindowsAgree rom.bytes &&
    ExplodeRoutine.windowAgrees rom.bytes &&
    ConversionRoutine.windowAgrees rom.bytes &&
    OhkoRoutine.windowAgrees rom.bytes &&
    ScreenRoutine.windowAgrees rom.bytes &&
    HealRoutine.windowAgrees rom.bytes &&
    SubstituteRoutine.windowAgrees rom.bytes &&
    LeechSeedRoutine.windowAgrees rom.bytes &&
    TransformRoutine.windowAgrees rom.bytes &&
    HazeRoutine.windowAgrees rom.bytes

/-- Load and reject any fixture that does not satisfy the retained Lean-visible
layout contract. -/
def loadChecked (path : System.FilePath) : IO CanonicalRom := do
  let rom ← load path
  if retainedLayoutMatches rom then
    pure rom
  else
    throw <| IO.userError
      "ROM fixture failed retained windows or decoded data/effect-table agreement; verify it with tools/check-pokered-build.py"

end Battle.Rom.Fixture
