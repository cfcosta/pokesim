/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

import Sm83.Cycle

namespace Sm83
namespace Proofs.Cycle

/-- Every logical instruction schedule begins with its opcode fetch. -/
theorem logical_starts_with_fetch (shape : InstructionShape) (taken : Bool) :
    (Cycle.logicalSchedule shape taken).head? = some .opcodeFetch := by
  cases shape <;> simp [Cycle.logicalSchedule] <;> (try split) <;> simp_all <;>
    (try split) <;> simp_all

/-- Physical scheduling reassigns the logical opcode fetch to the predecessor. -/
theorem fetch_reassociation (shape : InstructionShape) (taken : Bool) :
    Cycle.physicalSchedule shape taken =
      (Cycle.logicalSchedule shape taken).drop 1 ++ [.successorFetch] := rfl

/-- Fetch reassociation preserves the exact number of M-cycles for every family. -/
theorem reassociation_preserves_length (shape : InstructionShape) (taken : Bool) :
    (Cycle.physicalSchedule shape taken).length =
      (Cycle.logicalSchedule shape taken).length := by
  cases shape <;> simp [Cycle.physicalSchedule, Cycle.logicalSchedule] <;>
    (try split) <;> simp_all <;> (try split) <;> simp_all

/-- Typed conversion prevents a normal M-cycle total from becoming a non-multiple of four. -/
theorem tcycles_multiple_of_four (shape : InstructionShape) (taken : Bool) :
    (Cycle.tcycles shape taken).value % 4 = 0 := by
  simp [Cycle.tcycles, Cycle.mcycles, MCycles.toT]

/-- Conditional branch timing deltas are fixed by family, not operand values. -/
theorem conditional_deltas (condition : Condition) :
    (Cycle.mcycles (.jrCond condition) true).value =
        (Cycle.mcycles (.jrCond condition) false).value + 1 ∧
    (Cycle.mcycles (.jpCond condition) true).value =
        (Cycle.mcycles (.jpCond condition) false).value + 1 ∧
    (Cycle.mcycles (.retCond condition) true).value =
        (Cycle.mcycles (.retCond condition) false).value + 3 ∧
    (Cycle.mcycles (.callCond condition) true).value =
        (Cycle.mcycles (.callCond condition) false).value + 3 := by
  simp [Cycle.mcycles, Cycle.logicalSchedule]

end Proofs.Cycle
end Sm83
