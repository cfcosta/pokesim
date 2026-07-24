/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

import Sm83.Run

namespace Sm83
namespace Proofs.Lock

private def invalidEntryValid (opcode : Byte) : Bool :=
  match Decode.base opcode with
  | .locked _ =>
      let output := Run.stepMachineCycle Pipeline.bootstrap { read := .stable opcode }
      output.state.mode == .locked opcode && output.state.remaining == [] &&
        output.state.registers.pc == 1 && output.intent.control == .read
  | _ => true

/-- Every one of the eleven invalid bytes enters no-fetch lock on opcode fetch. -/
theorem every_invalid_enters_lock : ∀ opcode : Byte, invalidEntryValid opcode := by
  native_decide

/-- The deterministic diagnostic representative cannot retire or advance a locked core. -/
theorem locked_representative_stutters (state : CoreState) (input : CoreInput) (opcode : Byte)
    (locked : state.mode = .locked opcode) :
    (Run.stepMachineCycle state input).state = state ∧
      (Run.stepMachineCycle state input).intent.fetch = .none ∧
      (Run.stepMachineCycle state input).intent.poll = .none := by
  simp [Run.stepMachineCycle, locked]

/-- The public lock profile admits multiple retained external addresses. -/
theorem retained_addresses_relational (opcode : Byte) :
    InvalidLockProfile.retainedLevels.permits opcode { address := 0x0000 } ∧
      InvalidLockProfile.retainedLevels.permits opcode { address := 0xFFFF } := by
  simp [InvalidLockProfile.retainedLevels]

end Proofs.Lock
end Sm83
