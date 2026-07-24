/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

import Sm83.Functional

namespace Sm83
namespace Proofs.Functional

private def stateFor (bytes : List Nat) (registers : Registers := {}) : FunctionalState :=
  { registers, memory := FlatMemory.ofList (bytes.map Byte.ofNat) }

example :
    let result := Functional.step (stateFor [0x00])
    result.state.registers.pc = Word.ofNat 1 ∧ result.trace.length = 1 := by
  native_decide

example :
    let result := Functional.step (stateFor [0x01, 0x34, 0x12])
    result.state.registers.bc = Word.ofNat 0x1234 ∧
      result.state.registers.pc = Word.ofNat 3 ∧ result.trace.length = 3 := by
  native_decide

example :
    let registers : Registers := { b := Byte.ofNat 0x12, c := Byte.ofNat 0x34, sp := Word.ofNat 0xC002 }
    let result := Functional.step (stateFor [0xC5] registers)
    result.state.registers.sp = Word.ofNat 0xC000 ∧
      result.state.memory.read (Word.ofNat 0xC001) = Byte.ofNat 0x12 ∧
      result.state.memory.read (Word.ofNat 0xC000) = Byte.ofNat 0x34 ∧
      result.trace.length = 4 := by
  native_decide

example :
    let result := Functional.step (stateFor [0xD3])
    result.state.mode = .locked (Byte.ofNat 0xD3) ∧
      result.state.registers.pc = Word.ofNat 1 ∧ result.trace.length = 1 := by
  native_decide

example :
    let state := stateFor [0x76, 0x3E, 0x42]
    let halted := Functional.step state (Byte.ofNat 1)
    halted.state.haltBug = true ∧ halted.state.mode = .running := by
  native_decide

example :
    let registers : Registers := { h := Byte.ofNat 0x80, flags := { c := true } }
    let result := Functional.step (stateFor [0xCB, 0x7C] registers)
    result.state.registers.flags = { z := false, n := false, h := true, c := true } ∧
      result.trace.length = 2 := by
  native_decide

@[simp] theorem tcycles_are_four_per_trace (result : FunctionalResult) :
    (Functional.tcycles result).value = 4 * result.trace.length := rfl

end Proofs.Functional
end Sm83
