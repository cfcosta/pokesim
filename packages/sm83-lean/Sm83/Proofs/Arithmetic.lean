/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

import Sm83.Alu

namespace Sm83
namespace Proofs.Arithmetic

/-- SUB A,A has the catalogue's specialized 1100 flag result. -/
theorem sub_self : ∀ value : Byte,
    Alu.sub8 value value =
      { value := Byte.ofNat 0, flags := { z := true, n := true, h := false, c := false } } := by
  native_decide

/-- XOR A,A always clears A and produces Z000. -/
theorem xor_self : ∀ value : Byte,
    Alu.xor8 value value =
      { value := Byte.ofNat 0, flags := { z := true, n := false, h := false, c := false } } := by
  native_decide

/-- CP A,A preserves A through `apply` and produces subtraction/equality flags. -/
theorem cp_self (value : Byte) (flags : Flags) :
    Alu.apply .cp value value flags =
      { value, flags := { z := true, n := true, h := false, c := false } } := by
  simp only [Alu.apply, sub_self]

example : Alu.daa (Byte.ofNat 0x9A) {} =
    { value := Byte.ofNat 0x00, flags := { z := true, n := false, h := false, c := true } } := by
  native_decide

example : Alu.daa (Byte.ofNat 0x13) { n := true, h := true } =
    { value := Byte.ofNat 0x0D, flags := { z := false, n := true, h := false, c := false } } := by
  native_decide

/-- BIT never mutates carry. -/
theorem bit_preserves_carry (index : BitIndex) (value : Byte) (flags : Flags) :
    (Alu.testBit index value flags).c = flags.c := rfl

/-- Every reset/set operation is idempotent for all finite inputs. -/
theorem resetBit_idempotent : ∀ (index : BitIndex) (value : Byte),
    Alu.resetBit index (Alu.resetBit index value) = Alu.resetBit index value := by
  native_decide

theorem setBit_idempotent : ∀ (index : BitIndex) (value : Byte),
    Alu.setBit index (Alu.setBit index value) = Alu.setBit index value := by
  native_decide

end Proofs.Arithmetic
end Sm83
