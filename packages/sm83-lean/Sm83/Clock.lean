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

structure ClockIntent where
  cpuExecution : Bool := true
  machine : Bool := true
  oscillator : Bool := true
  deriving Repr, DecidableEq, Inhabited

end Sm83
