/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

import Sm83.Registers
import Sm83.Instruction

namespace Sm83
namespace Alu

structure Result8 where
  value : Byte
  flags : Flags
  deriving Repr, DecidableEq

structure Result16 where
  value : Word
  flags : Flags
  deriving Repr, DecidableEq

@[inline] def carryNat (carry : Bool) : Nat := if carry then 1 else 0

/-- Shared ADD/ADC equation. -/
def add8 (left right : Byte) (carry : Bool := false) : Result8 :=
  let carryIn := carryNat carry
  let wide := left.toNat + right.toNat + carryIn
  let value := Byte.ofNat wide
  { value
    flags := {
      z := value.toNat = 0
      n := false
      h := left.toNat % 16 + right.toNat % 16 + carryIn > 15
      c := wide > 255
    } }

/-- Shared SUB/SBC/CP equation. -/
def sub8 (left right : Byte) (carry : Bool := false) : Result8 :=
  let carryIn := carryNat carry
  let subtrahend := right.toNat + carryIn
  let value := Byte.ofNat (left.toNat + 256 - subtrahend)
  { value
    flags := {
      z := value.toNat = 0
      n := true
      h := left.toNat % 16 < right.toNat % 16 + carryIn
      c := left.toNat < subtrahend
    } }

def inc8 (value : Byte) (old : Flags) : Result8 :=
  let result := Byte.ofNat (value.toNat + 1)
  { value := result
    flags := { z := result.toNat = 0, n := false, h := value.toNat % 16 = 15, c := old.c } }

def dec8 (value : Byte) (old : Flags) : Result8 :=
  let result := Byte.ofNat (value.toNat + 255)
  { value := result
    flags := { z := result.toNat = 0, n := true, h := value.toNat % 16 = 0, c := old.c } }

def addHL (left right : Word) (old : Flags) : Result16 :=
  let wide := left.toNat + right.toNat
  { value := Word.ofNat wide
    flags := {
      z := old.z
      n := false
      h := left.toNat % 4096 + right.toNat % 4096 > 4095
      c := wide > 65535
    } }

/-- Common result and flags for ADD SP,e8 and LD HL,SP+e8. -/
def addSignedSP (sp : Word) (offset : Byte) : Result16 :=
  { value := sp.addSignedByte offset
    flags := {
      z := false
      n := false
      h := sp.toNat % 16 + offset.toNat % 16 > 15
      c := sp.toNat % 256 + offset.toNat > 255
    } }

def and8 (left right : Byte) : Result8 :=
  let value := left &&& right
  { value, flags := { z := value.toNat = 0, n := false, h := true, c := false } }

def xor8 (left right : Byte) : Result8 :=
  let value := left ^^^ right
  { value, flags := { z := value.toNat = 0 } }

def or8 (left right : Byte) : Result8 :=
  let value := left ||| right
  { value, flags := { z := value.toNat = 0 } }

/-- Execute an A-register ALU operation. CP returns A as the value while setting subtraction flags. -/
def apply (operation : AluOp) (a operand : Byte) (old : Flags) : Result8 :=
  match operation with
  | .add => add8 a operand
  | .adc => add8 a operand old.c
  | .sub => sub8 a operand
  | .sbc => sub8 a operand old.c
  | .and => and8 a operand
  | .xor => xor8 a operand
  | .or => or8 a operand
  | .cp => { sub8 a operand with value := a }

/-- Decimal adjust after an addition or subtraction. -/
def daa (a : Byte) (flags : Flags) : Result8 :=
  let lowCorrection := flags.h || (!flags.n && a.toNat % 16 > 9)
  let highCorrection := flags.c || (!flags.n && a.toNat > 0x99)
  let correction := (if lowCorrection then 0x06 else 0) + (if highCorrection then 0x60 else 0)
  let adjusted := if flags.n then a.toNat + 256 - correction else a.toNat + correction
  let value := Byte.ofNat adjusted
  { value
    flags := {
      z := value.toNat = 0
      n := flags.n
      h := false
      c := if flags.n then flags.c else highCorrection
    } }

private def bitNat (value : Byte) (index : Nat) : Nat :=
  if value.bit index then 1 else 0

/-- Rotate or shift one byte. `forceZeroClear` implements accumulator-only rotate Z behavior. -/
def rotate (operation : CbRotate) (value : Byte) (oldCarry : Bool)
    (forceZeroClear := false) : Result8 :=
  let n := value.toNat
  let pair : Nat × Bool :=
    match operation with
    | .rlc => ((n * 2 + bitNat value 7) % 256, value.bit 7)
    | .rrc => (n / 2 + bitNat value 0 * 128, value.bit 0)
    | .rl => ((n * 2 + carryNat oldCarry) % 256, value.bit 7)
    | .rr => (n / 2 + carryNat oldCarry * 128, value.bit 0)
    | .sla => ((n * 2) % 256, value.bit 7)
    | .sra => (n / 2 + bitNat value 7 * 128, value.bit 0)
    | .swap => ((n % 16) * 16 + n / 16, false)
    | .srl => (n / 2, value.bit 0)
  let result := Byte.ofNat pair.1
  { value := result
    flags := { z := !forceZeroClear && result.toNat = 0, n := false, h := false, c := pair.2 } }

def accumulatorRotate (operation : AccRotate) (value : Byte) (oldCarry : Bool) : Result8 :=
  match operation with
  | .rlca => rotate .rlc value oldCarry true
  | .rrca => rotate .rrc value oldCarry true
  | .rla => rotate .rl value oldCarry true
  | .rra => rotate .rr value oldCarry true

/-- BIT preserves carry and does not modify its operand. -/
def testBit (index : BitIndex) (value : Byte) (old : Flags) : Flags :=
  { z := !value.bit index.val, n := false, h := true, c := old.c }

def resetBit (index : BitIndex) (value : Byte) : Byte :=
  Byte.ofNat (value.toNat &&& (0xFF - 2 ^ index.val))

def setBit (index : BitIndex) (value : Byte) : Byte :=
  Byte.ofNat (value.toNat ||| 2 ^ index.val)

@[inline] def conditionHolds (condition : Condition) (flags : Flags) : Bool :=
  match condition with
  | .nz => !flags.z
  | .z => flags.z
  | .nc => !flags.c
  | .c => flags.c

@[simp] theorem inc_preserves_carry (value : Byte) (flags : Flags) :
    (inc8 value flags).flags.c = flags.c := rfl

@[simp] theorem dec_preserves_carry (value : Byte) (flags : Flags) :
    (dec8 value flags).flags.c = flags.c := rfl

@[simp] theorem addHL_preserves_zero (left right : Word) (flags : Flags) :
    (addHL left right flags).flags.z = flags.z := rfl

@[simp] theorem daa_clears_halfCarry (a : Byte) (flags : Flags) :
    (daa a flags).flags.h = false := rfl

@[simp] theorem daa_preserves_subtract (a : Byte) (flags : Flags) :
    (daa a flags).flags.n = flags.n := rfl

/-- DAA is independent of the incoming Z flag over every byte and N/H/C state. -/
theorem daa_old_zero_irrelevant : ∀ (a : Byte) (n h c : Bool),
    daa a { z := false, n, h, c } = daa a { z := true, n, h, c } := by
  native_decide

/-- The signed-SP forms always clear Z and N. -/
theorem signedSP_clears_zn : ∀ (sp : Word) (offset : Byte),
    let result := addSignedSP sp offset
    result.flags.z = false ∧ result.flags.n = false := by
  native_decide

end Alu
end Sm83
