/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

import Sm83.Byte

namespace Sm83

structure Flags where
  z : Bool := false
  n : Bool := false
  h : Bool := false
  c : Bool := false
  deriving Repr, DecidableEq, Inhabited

namespace Flags

@[inline] def encode (flags : Flags) : Byte :=
  BitVec.cons flags.z <| BitVec.cons flags.n <| BitVec.cons flags.h <|
    BitVec.cons flags.c (BitVec.ofNat 4 0)

@[inline] def decode (value : Byte) : Flags where
  z := value.bit 7
  n := value.bit 6
  h := value.bit 5
  c := value.bit 4

@[simp] theorem decode_encode (flags : Flags) : decode flags.encode = flags := by
  rcases flags with ⟨z, n, h, c⟩
  cases z <;> cases n <;> cases h <;> cases c <;> native_decide

@[simp] theorem encode_decode : ∀ value : Byte,
    (decode value).encode = value &&& Byte.ofNat 0xF0 := by
  native_decide

@[simp] theorem encode_low_nibble (flags : Flags) :
    flags.encode &&& Byte.ofNat 0x0F = Byte.ofNat 0 := by
  rcases flags with ⟨z, n, h, c⟩
  cases z <;> cases n <;> cases h <;> cases c <;> native_decide

end Flags

end Sm83
