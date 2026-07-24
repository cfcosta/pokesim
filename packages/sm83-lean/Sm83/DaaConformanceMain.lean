/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

import Sm83.Alu

namespace Sm83.DaaConformance

private def checkLine (line : String) : Bool :=
  let values := (line.splitOn " ").filterMap String.toNat? |>.toArray
  if values.size != 4 then false else
  let inputFlags := Flags.decode (Byte.ofNat (16 * values[1]!))
  let result := Alu.daa (Byte.ofNat values[0]!) inputFlags
  result.value = Byte.ofNat values[2]! && result.flags.encode.toNat / 16 = values[3]!

private def loop (lines : List String) (lineNumber failures checked : Nat) : IO (Nat × Nat) := do
  match lines with
  | [] => pure (failures, checked)
  | line :: rest =>
      if line.trimAscii.isEmpty then loop rest (lineNumber + 1) failures checked
      else if checkLine line then loop rest (lineNumber + 1) failures (checked + 1)
      else
        if failures < 20 then IO.eprintln s!"FAIL DAA fixture line {lineNumber}"
        loop rest (lineNumber + 1) (failures + 1) (checked + 1)

end Sm83.DaaConformance

open Sm83.DaaConformance

def main : IO UInt32 := do
  let input ← (← IO.getStdin).readToEnd
  let (failures, checked) ← loop (input.splitOn "\n") 1 0 0
  if checked != 4096 then
    IO.eprintln s!"FAIL expected 4096 DAA fixtures, received {checked}"
    pure 2
  else if failures = 0 then
    IO.println "PASS 4096 DAA fixtures"
    pure 0
  else
    IO.eprintln s!"FAIL {failures}/4096 DAA fixtures"
    pure 1
