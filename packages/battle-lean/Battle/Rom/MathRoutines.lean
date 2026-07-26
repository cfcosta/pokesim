/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0.
-/
import Battle.Rom.Closure

/-! # `_Multiply` and `_Divide` functional contracts -/

namespace Battle.Rom.MathRoutines

open Sm83 Battle.Rom.Closure

/-- `_Multiply` consumes a 24-bit multiplicand and one-byte multiplier and
produces the four-byte product. -/
def multiply (multiplicand : UInt32) (multiplier : UInt8) : UInt32 :=
  UInt32.ofNat ((multiplicand.toNat % 0x1000000) * multiplier.toNat)

inductive DivideResult where
  | finite (quotient : UInt32) (remainder : UInt8)
  | divergentZeroDivisor
  deriving Repr, DecidableEq, BEq

/-- `_Divide` operates on the selected high-order byte count. A zero divisor is
an explicit divergent routine behavior, never a fuel-exhaustion result. -/
def divide (dividend : UInt32) (divisor bytes : UInt8) : DivideResult :=
  if divisor == 0 then .divergentZeroDivisor
  else
    let width := min 4 bytes.toNat
    let modulus := 256 ^ width
    let value := dividend.toNat % modulus
    .finite (UInt32.ofNat (value / divisor.toNat))
      (UInt8.ofNat (value % divisor.toNat))

@[simp] theorem multiply_boundaries :
    multiply 0xFFFFFF 0xFF = 0xFEFFFF01 ∧ multiply 0 0xFF = 0 := by
  native_decide

@[simp] theorem divide_zero_diverges (dividend : UInt32) (bytes : UInt8) :
    divide dividend 0 bytes = .divergentZeroDivisor := by
  simp [divide]

@[simp] theorem divide_witnesses :
    divide 1000 10 4 = .finite 100 0 ∧
      divide 1001 10 4 = .finite 100 1 := by
  native_decide

structure RequiredMathBytes (rom : Array Byte) : Prop where
  multiplyEntry : bytesAt rom (romOffset 0x0D 0x7D41) 4 =
    [0x3E, 0x08, 0x47, 0xAF]
  divideEntry : bytesAt rom (romOffset 0x0D 0x7DA5) 1 = [0xAF]

/-- Exact entry bytes plus the independent total/divergent arithmetic contracts
are the theorem boundary; decoded body refinement remains part of graph closure. -/
theorem math_contracts_visible {rom : Array Byte} (required : RequiredMathBytes rom) :
    bytesAt rom (romOffset 0x0D 0x7D41) 4 = [0x3E, 0x08, 0x47, 0xAF] ∧
      bytesAt rom (romOffset 0x0D 0x7DA5) 1 = [0xAF] :=
  ⟨required.multiplyEntry, required.divideEntry⟩

end Battle.Rom.MathRoutines
