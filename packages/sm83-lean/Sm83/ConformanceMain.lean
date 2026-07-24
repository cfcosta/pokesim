/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

import Sm83.FlatAdapter

namespace Sm83.Conformance

private def byte (value : Nat) : Byte := Byte.ofNat value
private def word (value : Nat) : Word := Word.ofNat value

private def writePairs (values : Array Nat) (start count : Nat) (memory : FlatMemory) : FlatMemory :=
  (List.range count).foldl (fun current index =>
    current.write (word (values.getD (start + 2 * index) 0))
      (byte (values.getD (start + 2 * index + 1) 0))) memory

private def checkRam (values : Array Nat) (start count : Nat) (memory : FlatMemory) : Bool :=
  (List.range count).all fun index =>
    memory.read (word (values.getD (start + 2 * index) 0)) =
      byte (values.getD (start + 2 * index + 1) 0)

private def activeTrace (trace : List BusEvent) : List (Nat × Nat × Nat) :=
  trace.filterMap fun event => match event with
    | .read _ address value => some (0, address.toNat, value.toNat)
    | .write address value => some (1, address.toNat, value.toNat)
    | .idle _ => none

private def expectedTrace (values : Array Nat) (start count : Nat) : List (Nat × Nat × Nat) :=
  (List.range count).map fun index =>
    (values.getD (start + 3 * index) 0,
     values.getD (start + 3 * index + 1) 0,
     values.getD (start + 3 * index + 2) 0)

/-- Check one whitespace-delimited SingleStep fixture without importing fixture data. -/
def checkLine (line : String) : Bool :=
  let values := (line.splitOn " ").filterMap String.toNat? |>.toArray
  if values.size < 25 then false else
  let initialRamCount := values.getD 11 0
  let initialRamStart := 12
  let finalStart := initialRamStart + 2 * initialRamCount
  let finalRamCount := values.getD (finalStart + 11) 0
  let finalRamStart := finalStart + 12
  let traceCountAt := finalRamStart + 2 * finalRamCount
  let traceCount := values.getD traceCountAt 0
  let traceStart := traceCountAt + 1
  if values.size != traceStart + 3 * traceCount then false else
  let memory := writePairs values initialRamStart initialRamCount default
  let registers : Registers := {
    a := byte (values.getD 2 0)
    b := byte (values.getD 3 0)
    c := byte (values.getD 4 0)
    d := byte (values.getD 5 0)
    e := byte (values.getD 6 0)
    flags := Flags.decode (byte (values.getD 7 0))
    h := byte (values.getD 8 0)
    l := byte (values.getD 9 0)
    sp := word (values.getD 1 0)
    pc := word (values.getD 0 0) }
  let before : FunctionalState := {
    registers
    memory
    ime := values.getD 10 0 != 0 }
  let result := Functional.step before
  let core := { Pipeline.bootstrap registers with ime := before.ime }
  let physical := FlatAdapter.run (result.trace.length + 1)
    { core, memory }
    (fun _ _ => 0)
  let projected := FlatAdapter.project physical
  let final := result.state.registers
  final.a = byte (values.getD finalStart 0) &&
    final.b = byte (values.getD (finalStart + 1) 0) &&
    final.c = byte (values.getD (finalStart + 2) 0) &&
    final.d = byte (values.getD (finalStart + 3) 0) &&
    final.e = byte (values.getD (finalStart + 4) 0) &&
    final.flags.encode = byte (values.getD (finalStart + 5) 0) &&
    final.h = byte (values.getD (finalStart + 6) 0) &&
    final.l = byte (values.getD (finalStart + 7) 0) &&
    final.pc = word (values.getD (finalStart + 8) 0) &&
    final.sp = word (values.getD (finalStart + 9) 0) &&
    result.state.ime = (values.getD (finalStart + 10) 0 != 0) &&
    checkRam values finalRamStart finalRamCount result.state.memory &&
    activeTrace result.trace = expectedTrace values traceStart traceCount &&
    projected.registers = result.state.registers &&
    projected.ime = result.state.ime &&
    projected.scheduledImeEnable = result.state.scheduledImeEnable &&
    checkRam values finalRamStart finalRamCount physical.memory &&
    activeTrace physical.trace.dropLast = expectedTrace values traceStart traceCount

private def loop (lines : List String) (lineNumber failures checked : Nat) : IO (Nat × Nat) := do
  match lines with
  | [] => pure (failures, checked)
  | line :: rest =>
      if line.trimAscii.isEmpty then loop rest (lineNumber + 1) failures checked
      else if checkLine line then loop rest (lineNumber + 1) failures (checked + 1)
      else
        if failures < 20 then IO.eprintln s!"FAIL fixture line {lineNumber}"
        loop rest (lineNumber + 1) (failures + 1) (checked + 1)

end Sm83.Conformance

open Sm83.Conformance

/-- Streaming conformance gate: malformed or mismatching input exits nonzero. -/
def main : IO UInt32 := do
  let input ← (← IO.getStdin).readToEnd
  let (failures, checked) ← loop (input.splitOn "\n") 1 0 0
  if checked = 0 then
    IO.eprintln "FAIL no fixtures"
    pure 2
  else if failures = 0 then
    IO.println s!"PASS {checked} fixtures"
    pure 0
  else
    IO.eprintln s!"FAIL {failures}/{checked} fixtures"
    pure 1
