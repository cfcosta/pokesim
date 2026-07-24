/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

import Sm83.Run

namespace Sm83
namespace Proofs.Interrupt

private def input (value : Nat) (pending : Nat := 0) : CoreInput :=
  { read := .stable (Byte.ofNat value), pendingInterrupts := Byte.ofNat pending }

private def entryState (sp : Nat) : CoreState :=
  { registers := { sp := Word.ofNat sp, pc := Word.ofNat 0x1234 }
    ime := false
    phase := .interrupt
    ir := some { byte := Byte.ofNat 0, address := Word.ofNat 0x1233 }
    interrupt := some { returnPC := Word.ofNat 0x1234 } }

/-- Five dispatch cycles perform correction, decrement, high, low/ack, and vector fetch. -/
example :
    let s0 := entryState 0x0000
    let o1 := Run.stepMachineCycle s0 (input 0)
    let o2 := Run.stepMachineCycle o1.state (input 0)
    let o3 := Run.stepMachineCycle o2.state (input 0)
    let o4 := Run.stepMachineCycle o3.state (input 0 0x04)
    let o5 := Run.stepMachineCycle o4.state (input 0x00 0x04)
    o1.intent.control = .idle ∧
      o2.state.registers.sp = Word.ofNat 0xFFFF ∧
      o3.intent.control = .write ∧ o3.intent.address = Word.ofNat 0xFFFF ∧
      o3.intent.data = .driven (Byte.ofNat 0x12) ∧
      o4.intent.control = .write ∧ o4.intent.address = Word.ofNat 0xFFFE ∧
      o4.intent.data = .driven (Byte.ofNat 0x34) ∧ o4.intent.acknowledge = Byte.ofNat 0x04 ∧
      o5.intent.address = Word.ofNat 0x50 ∧
      o5.state.ir = some { byte := Byte.ofNat 0, address := Word.ofNat 0x50 } ∧
      o5.state.registers.pc = Word.ofNat 0x51 := by
  native_decide

/-- If the upper push changed IE, a zero pending mask cancels to address zero. -/
example :
    let s0 := entryState 0x0000
    let o1 := Run.stepMachineCycle s0 (input 0)
    let o2 := Run.stepMachineCycle o1.state (input 0)
    let o3 := Run.stepMachineCycle o2.state (input 0)
    let o4 := Run.stepMachineCycle o3.state (input 0 0)
    let o5 := Run.stepMachineCycle o4.state (input 0x00 0)
    o4.intent.acknowledge = 0 ∧ o5.intent.address = 0 ∧ o5.state.ime = false := by
  native_decide

/-- With initial SP=$0001, the low-byte write reaches IE only after selection. -/
example :
    let s0 := entryState 0x0001
    let o1 := Run.stepMachineCycle s0 (input 0)
    let o2 := Run.stepMachineCycle o1.state (input 0)
    let o3 := Run.stepMachineCycle o2.state (input 0)
    let o4 := Run.stepMachineCycle o3.state (input 0 0x01)
    o3.intent.address = Word.ofNat 0x0000 ∧
      o4.intent.address = Word.ofNat 0xFFFF ∧
      o4.intent.acknowledge = Byte.ofNat 0x01 := by
  native_decide

/-- EI matures after the following NOP and accepts before opcode 2 executes. -/
example :
    let ei := (Run.stepMachineCycle Pipeline.bootstrap (input 0xFB)).state
    let nop := (Run.stepMachineCycle ei (input 0x00)).state
    let accepted := (Run.stepMachineCycle nop (input 0x00 1)).state
    nop.ime = false ∧ nop.scheduledImeEnable = true ∧
      accepted.phase = .interrupt ∧ accepted.interrupt.map (·.returnPC) = some (Word.ofNat 2) := by
  native_decide

/-- DI immediately cancels EI's pending enable and suppresses acceptance. -/
example :
    let ei := (Run.stepMachineCycle Pipeline.bootstrap (input 0xFB)).state
    let di := (Run.stepMachineCycle ei (input 0xF3)).state
    let afterDi := (Run.stepMachineCycle di (input 0x00 1)).state
    afterDi.phase = .execute ∧ afterDi.ime = false ∧
      afterDi.scheduledImeEnable = false ∧ afterDi.ir.map (·.byte) = some (Byte.ofNat 0) := by
  native_decide

end Proofs.Interrupt
end Sm83
