/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Rom.Fixture

/-!
# Canonical ROM fixture runner

Usage: `lake exe battleRomFixture /path/to/verified/pokered.gbc`.
The root integrity workflow obtains the path from a temporary hash-checked
rebuild, so no copyrighted ROM image enters the source tree or Lake artifact.
-/

open Battle.Rom

private def usage : String :=
  "usage: lake exe battleRomFixture /path/to/verified/pokered.gbc"

def main (args : List String) : IO UInt32 := do
  match args with
  | [path] =>
      try
        let rom ← Fixture.loadChecked path
        IO.println s!"PASS canonical ROM fixture: {rom.bytes.size} bytes, retained windows and battle tables agree"
        pure 0
      catch error =>
        IO.eprintln s!"FAIL canonical ROM fixture: {error}"
        pure 1
  | _ =>
      IO.eprintln usage
      pure 2
