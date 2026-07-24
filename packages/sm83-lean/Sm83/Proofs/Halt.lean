/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

import Sm83.Run

namespace Sm83
namespace Proofs.Halt

private def input (value : Nat) (pending : Nat := 0) : CoreInput :=
  { read := .stable (Byte.ofNat value), pendingInterrupts := Byte.ofNat pending }

private def haltBugWith (nextOpcode : Nat) : CoreState :=
  let halt := (Run.stepMachineCycle Pipeline.bootstrap (input 0x76)).state
  (Run.stepMachineCycle halt (input nextOpcode 1)).state

/-- A one-byte successor is fetched twice when HALT suppresses PC increment. -/
example :
    let first := haltBugWith 0x00
    let second := (Run.stepMachineCycle first (input 0x00 1)).state
    first.ir.map (·.address) = some 1 ∧ first.registers.pc = 1 ∧
      second.ir.map (·.address) = some 1 ∧ second.registers.pc = 2 := by
  native_decide

/-- A multibyte successor consumes its own opcode again as immediate data. -/
example :
    let load := haltBugWith 0x06
    let immediate := (Run.stepMachineCycle load (input 0x06 1)).state
    let completed := (Run.stepMachineCycle immediate (input 0x42 1)).state
    completed.registers.b = 0x06 ∧ completed.ir.map (·.address) = some 2 := by
  native_decide

/-- A following CB prefix is duplicated into the CB subopcode fetch. -/
example :
    let prefixed := haltBugWith 0xCB
    let subopcode := (Run.stepMachineCycle prefixed (input 0xCB 1)).state
    let completed := (Run.stepMachineCycle subopcode (input 0x00 1)).state
    subopcode.shape = some (.set ⟨1, by omega⟩ (.reg .e)) ∧ completed.registers.e = 0x02 := by
  native_decide

/-- Consecutive HALTs can repeatedly suppress the same following-byte increment. -/
example :
    let first := haltBugWith 0x76
    let second := (Run.stepMachineCycle first (input 0x76 1)).state
    first.haltBug = true ∧ second.haltBug = true ∧
      second.ir.map (·.address) = some 1 ∧ second.registers.pc = 1 := by
  native_decide

/-- EI followed by HALT accepts a pending request with return PC after HALT. -/
example :
    let ei := (Run.stepMachineCycle Pipeline.bootstrap (input 0xFB)).state
    let halt := (Run.stepMachineCycle ei (input 0x76)).state
    let accepted := (Run.stepMachineCycle halt (input 0x00 1)).state
    halt.ime = false ∧ halt.scheduledImeEnable = true ∧
      accepted.phase = .interrupt ∧ accepted.interrupt.map (·.returnPC) = some 2 := by
  native_decide

end Proofs.Halt
end Sm83
