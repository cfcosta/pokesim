/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

import Sm83.Flags

namespace Sm83

structure Registers where
  a : Byte := 0
  b : Byte := 0
  c : Byte := 0
  d : Byte := 0
  e : Byte := 0
  h : Byte := 0
  l : Byte := 0
  flags : Flags := {}
  sp : Word := 0
  pc : Word := 0
  deriving Repr, DecidableEq, Inhabited

namespace Registers

@[inline] def af (registers : Registers) : Word :=
  Word.ofBytes registers.a registers.flags.encode

@[inline] def bc (registers : Registers) : Word :=
  Word.ofBytes registers.b registers.c

@[inline] def de (registers : Registers) : Word :=
  Word.ofBytes registers.d registers.e

@[inline] def hl (registers : Registers) : Word :=
  Word.ofBytes registers.h registers.l

@[inline] def setAF (registers : Registers) (value : Word) : Registers :=
  { registers with a := value.highByte, flags := Flags.decode value.lowByte }

@[inline] def setBC (registers : Registers) (value : Word) : Registers :=
  { registers with b := value.highByte, c := value.lowByte }

@[inline] def setDE (registers : Registers) (value : Word) : Registers :=
  { registers with d := value.highByte, e := value.lowByte }

@[inline] def setHL (registers : Registers) (value : Word) : Registers :=
  { registers with h := value.highByte, l := value.lowByte }

@[simp] theorem af_setAF (registers : Registers) (value : Word) :
    (registers.setAF value).af = Word.ofBytes value.highByte (value.lowByte &&& Byte.ofNat 0xF0) := by
  simp [setAF, af, Flags.encode_decode]

@[simp] theorem bc_setBC (registers : Registers) (value : Word) :
    (registers.setBC value).bc = value := by
  simp [setBC, bc]

@[simp] theorem de_setDE (registers : Registers) (value : Word) :
    (registers.setDE value).de = value := by
  simp [setDE, de]

@[simp] theorem hl_setHL (registers : Registers) (value : Word) :
    (registers.setHL value).hl = value := by
  simp [setHL, hl]

@[simp] theorem setBC_preservesAF (registers : Registers) (value : Word) :
    (registers.setBC value).af = registers.af := rfl

@[simp] theorem setHL_preservesSP (registers : Registers) (value : Word) :
    (registers.setHL value).sp = registers.sp := rfl

end Registers

end Sm83
