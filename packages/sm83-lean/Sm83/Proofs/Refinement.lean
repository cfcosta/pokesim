/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

import Sm83.FlatAdapter

namespace Sm83
namespace Proofs.Refinement

private def noInterrupts : Nat → FlatCoreState → Byte := fun _ _ => 0

private def initial (bytes : List Byte) (registers : Registers := {}) : FunctionalState :=
  { registers, memory := FlatMemory.ofList bytes }

private def physicalInitial (state : FunctionalState) : FlatCoreState :=
  { core := Pipeline.bootstrap state.registers, memory := state.memory }

/-- NOP differs only by the physical successor prefetch. -/
example :
    let before := initial [0x00, 0x00]
    let logical := Functional.step before
    let physical := FlatAdapter.run 2 (physicalInitial before) noInterrupts
    (FlatAdapter.project physical).registers = logical.state.registers ∧
      physical.trace.dropLast = logical.trace := by
  native_decide

/-- Immediate loads refine after fetch reassociation. -/
example :
    let before := initial [0x06, 0x42, 0x00]
    let logical := Functional.step before
    let physical := FlatAdapter.run 3 (physicalInitial before) noInterrupts
    (FlatAdapter.project physical).registers = logical.state.registers ∧
      physical.trace.dropLast = logical.trace := by
  native_decide

/-- Stack writes preserve high-then-low ordering and the final SP. -/
example :
    let registers : Registers := { b := 0x12, c := 0x34, sp := 0x0000 }
    let before := initial [0xC5, 0x00] registers
    let logical := Functional.step before
    let physical := FlatAdapter.run 5 (physicalInitial before) noInterrupts
    (FlatAdapter.project physical).registers = logical.state.registers ∧
      physical.memory.read 0xFFFF = logical.state.memory.read 0xFFFF ∧
      physical.memory.read 0xFFFE = logical.state.memory.read 0xFFFE ∧
      physical.trace.dropLast = logical.trace := by
  native_decide

/-- A CB read-modify-write through (HL) refines the flat executable view. -/
example :
    let registers : Registers := { h := 0xC0, l := 0x00 }
    let memory := (FlatMemory.ofList [0xCB, 0x06, 0x00]).write 0xC000 0x80
    let before : FunctionalState := { registers, memory }
    let logical := Functional.step before
    let physical := FlatAdapter.run 5 (physicalInitial before) noInterrupts
    (FlatAdapter.project physical).registers = logical.state.registers ∧
      physical.memory.read 0xC000 = logical.state.memory.read 0xC000 ∧
      physical.trace.dropLast = logical.trace := by
  native_decide

end Proofs.Refinement
end Sm83
