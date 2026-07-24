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

/-- IME=0 with a pending request duplicates the following byte through the HALT bug. -/
example :
    let halt := (Run.stepMachineCycle Pipeline.bootstrap (input 0x76)).state
    let duplicated := (Run.stepMachineCycle halt {
      read := .stable 0x3E, pendingInterrupts := 1 }).state
    let immediate := (Run.stepMachineCycle duplicated (input 0x3E)).state
    duplicated.haltBug = true ∧ duplicated.registers.pc = 1 ∧
      duplicated.ir.map (·.address) = some 1 ∧ immediate.latches.low = 0x3E := by
  native_decide

/-- An IME=0 halted core wakes without dispatch when a request appears. -/
example :
    let halted : CoreState := { mode := .halted, registers := { pc := 0x1234 } }
    let output := Run.stepMachineCycle halted { read := .stable 0, pendingInterrupts := 1 }
    output.state.mode = .running ∧ output.state.phase = .bootstrap ∧
      output.state.registers.pc = 0x1234 := by
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
