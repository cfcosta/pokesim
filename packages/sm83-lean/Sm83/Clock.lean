/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

namespace Sm83

structure TCycles where
  value : Nat
  deriving Repr, DecidableEq, Inhabited

structure MCycles where
  value : Nat
  deriving Repr, DecidableEq, Inhabited

namespace MCycles

@[inline] def toT (cycles : MCycles) : TCycles := ⟨4 * cycles.value⟩

@[simp] theorem toT_value (cycles : MCycles) : cycles.toT.value = 4 * cycles.value := rfl

end MCycles

inductive ClockDomain where
  | cpuExecution
  | machine
  | oscillator
  | externalSerial
  | cartridgeRtc
  deriving Repr, DecidableEq, Inhabited

inductive TPhase where
  | t1 | t2 | t3 | t4
  deriving Repr, DecidableEq, Inhabited

inductive ClockEdge where
  | falling | rising
  deriving Repr, DecidableEq, Inhabited

structure HalfEdge where
  phase : TPhase
  edge : ClockEdge
  deriving Repr, DecidableEq, Inhabited

/-- Canonical adapter order for the eight half edges of one processor M-cycle. -/
def machineHalfEdges : List HalfEdge :=
  [⟨.t1, .falling⟩, ⟨.t1, .rising⟩,
   ⟨.t2, .falling⟩, ⟨.t2, .rising⟩,
   ⟨.t3, .falling⟩, ⟨.t3, .rising⟩,
   ⟨.t4, .falling⟩, ⟨.t4, .rising⟩]

@[simp] theorem machineHalfEdges_length : machineHalfEdges.length = 8 := rfl

structure ClockIntent where
  cpuExecution : Bool := true
  machine : Bool := true
  oscillator : Bool := true
  deriving Repr, DecidableEq, Inhabited

end Sm83
