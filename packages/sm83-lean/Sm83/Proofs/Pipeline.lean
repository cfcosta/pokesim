/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

import Sm83.Run

namespace Sm83
namespace Proofs.Pipeline

private def input (value : Nat) : CoreInput :=
  { read := .stable (Byte.ofNat value) }

example :
    let initial := Pipeline.bootstrap
    let fetched := (Run.stepMachineCycle initial (input 0x00)).state
    fetched.phase = .execute ∧
      fetched.ir = some { byte := Byte.ofNat 0x00, address := Word.ofNat 0 } ∧
      fetched.registers.pc = Word.ofNat 1 ∧
      fetched.remaining = [.successorFetch] := by
  native_decide

/-- NOP commits while its successor is fetched; PC is therefore ahead of IR. -/
example :
    let fetched := (Run.stepMachineCycle Pipeline.bootstrap (input 0x00)).state
    let successor := Run.stepMachineCycle fetched (input 0x3E)
    successor.state.ir = some { byte := Byte.ofNat 0x3E, address := Word.ofNat 1 } ∧
      successor.state.registers.pc = Word.ofNat 2 ∧
      successor.intent.fetch = .generic := by
  native_decide

example :
    let fetched := (Run.stepMachineCycle Pipeline.bootstrap (input 0xD3)).state
    fetched.mode = .locked (Byte.ofNat 0xD3) ∧ fetched.remaining = [] := by
  native_decide

example :
    let halted : CoreState := { mode := .halted }
    let output := Run.stepMachineCycle halted (input 0xFF)
    output.intent.clocks.cpuExecution = false ∧
      output.intent.clocks.machine = true ∧ output.intent.clocks.oscillator = true := by
  native_decide

example :
    let stopped : CoreState := { mode := .stopped 0 }
    let output := Run.stepMachineCycle stopped (input 0xFF)
    output.intent.clocks.cpuExecution = false ∧
      output.intent.clocks.machine = false ∧ output.intent.clocks.oscillator = false := by
  native_decide

end Proofs.Pipeline
end Sm83
