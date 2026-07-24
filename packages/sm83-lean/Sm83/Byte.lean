/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

import Std.Tactic.BVDecide

namespace Sm83

abbrev Byte := BitVec 8
abbrev Word := BitVec 16

namespace Byte

@[inline] def ofNat (value : Nat) : Byte := BitVec.ofNat 8 value

@[inline] def lowNibble (value : Byte) : Nat := value.toNat % 16

@[inline] def bit (value : Byte) (index : Nat) : Bool := value.getLsbD index

/-- Interpret an encoded byte as a signed mathematical integer. -/
def toSigned (value : Byte) : Int :=
  if value.toNat < 128 then value.toNat else (value.toNat : Int) - 256

end Byte

namespace Word

@[inline] def ofNat (value : Nat) : Word := BitVec.ofNat 16 value

@[inline] def lowByte (value : Word) : Byte := value.extractLsb 7 0

@[inline] def highByte (value : Word) : Byte := value.extractLsb 15 8

@[inline] def ofBytes (high low : Byte) : Word := high.append low

/-- Add a signed encoded byte, wrapping modulo 65536. -/
def addSignedByte (value : Word) (offset : Byte) : Word :=
  Word.ofNat (Int.emod (value.toNat + offset.toSigned) 65536).toNat

end Word

@[simp] theorem Word.lowByte_ofBytes (high low : Byte) :
    (Word.ofBytes high low).lowByte = low := by
  simp only [Word.ofBytes, Word.lowByte]
  bv_decide

@[simp] theorem Word.highByte_ofBytes (high low : Byte) :
    (Word.ofBytes high low).highByte = high := by
  simp only [Word.ofBytes, Word.highByte]
  bv_decide

@[simp] theorem Word.ofBytes_high_low (value : Word) :
    Word.ofBytes value.highByte value.lowByte = value := by
  simp only [Word.ofBytes, Word.highByte, Word.lowByte]
  bv_decide

end Sm83
