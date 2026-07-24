/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

import Sm83.Run

namespace Sm83
namespace Proofs.Idu

private def input (value : Nat) : CoreInput := { read := .stable (Byte.ofNat value) }

/-- Sixteen-bit pair updates expose their old address and direction. -/
example :
    let initial := Pipeline.bootstrap { b := 0xFE, c := 0x10 }
    let fetched := (Run.stepMachineCycle initial (input 0x03)).state
    let update := Run.stepMachineCycle fetched (input 0)
    update.intent.control = .idle ∧ update.intent.address = 0xFE10 ∧
      update.intent.idu.source = .bc ∧ update.intent.idu.direction = .increment ∧
      update.intent.idu.destination = .bc := by
  native_decide

/-- HLI performs its active access at old HL with a same-cycle increment intent. -/
example :
    let initial := Pipeline.bootstrap { h := 0xFE, l := 0x20, a := 0x42 }
    let fetched := (Run.stepMachineCycle initial (input 0x22)).state
    let access := Run.stepMachineCycle fetched (input 0)
    access.intent.control = .write ∧ access.intent.address = 0xFE20 ∧
      access.intent.idu.source = .hl ∧ access.intent.idu.direction = .increment ∧
      access.intent.idu.destination = .hl := by
  native_decide

/-- The low SP write exposes the WZ increment used by the following high write. -/
example :
    let fetched := (Run.stepMachineCycle Pipeline.bootstrap (input 0x08)).state
    let low := (Run.stepMachineCycle fetched (input 0x00)).state
    let high := (Run.stepMachineCycle low (input 0xFE)).state
    let writeLow := Run.stepMachineCycle high (input 0)
    writeLow.intent.address = 0xFE00 ∧ writeLow.intent.idu.source = .wz ∧
      writeLow.intent.idu.direction = .increment ∧ writeLow.intent.idu.destination = .wz := by
  native_decide

/-- Taken JR exposes a relative PC adjustment before target fetch. -/
example :
    let initial := Pipeline.bootstrap { pc := 0x0100 }
    let fetched := (Run.stepMachineCycle initial (input 0x18)).state
    let offset := (Run.stepMachineCycle fetched (input 0xFE)).state
    let relative := Run.stepMachineCycle offset (input 0)
    relative.intent.idu.source = .pc ∧ relative.intent.idu.direction = .relative ∧
      relative.intent.idu.destination = .pc := by
  native_decide

/-- HALT's dummy following-byte read suppresses the ordinary fetch increment intent. -/
example :
    let fetched := (Run.stepMachineCycle Pipeline.bootstrap (input 0x76)).state
    let dummy := Run.stepMachineCycle fetched (input 0)
    dummy.intent.fetch = .haltDummy ∧ dummy.intent.idu.source = .pc ∧
      dummy.intent.idu.direction = .none := by
  native_decide

end Proofs.Idu
end Sm83
