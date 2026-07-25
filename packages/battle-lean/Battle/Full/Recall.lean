/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Rom.Tables

/-!
# Player recall-text arithmetic

`PlayerMon2Text` subtracts current enemy HP from the HP saved at the previous
switch with 16-bit wrap, multiplies a three-byte multiplicand by 25, quarters
max HP, truncates that divisor to its low byte, and inspects only the quotient's
low byte. A zero truncated divisor does not return from `_Divide`.
-/

namespace Battle.Full.Recall

open Battle.Rom.Closure

inductive Text where
  | enough
  | comeBack
  | ok
  | good
  deriving Repr, DecidableEq, BEq

inductive Result where
  | selected (text : Text) (quotientLow : UInt8)
  | divergesZeroDivisor
  deriving Repr, DecidableEq, BEq

/-- Exact 16-bit wrapped HP subtraction used when the enemy healed. -/
def wrappedDelta (lastHp currentHp : UInt16) : Nat :=
  (lastHp.toNat + 0x10000 - currentHp.toNat) % 0x10000

/-- The caller does not rewrite `hMultiplicand`; retain that high byte rather
than silently assuming it is zero. -/
def product (staleHigh : UInt8) (lastHp currentHp : UInt16) : Nat :=
  ((staleHigh.toNat * 0x10000 + wrappedDelta lastHp currentHp) * 25) % 0x100000000

/-- Two 16-bit shifts followed by `ld a,b` and an eight-bit divisor store. -/
def divisor (maxHp : UInt16) : UInt8 := ((maxHp.toNat / 4) % 0x100).toUInt8

def classify (quotient : UInt8) : Text :=
  if quotient == 0 then .enough
  else if quotient < 30 then .comeBack
  else if quotient < 70 then .ok
  else .good

def select (staleHigh : UInt8) (lastHp currentHp maxHp : UInt16) : Result :=
  let d := divisor maxHp
  if d == 0 then .divergesZeroDivisor
  else
    let low := ((product staleHigh lastHp currentHp) / d.toNat % 0x100).toUInt8
    .selected (classify low) low

@[simp] theorem zero_divisor_diverges (stale : UInt8) (last current maxHp : UInt16)
    (zero : divisor maxHp = 0) :
    select stale last current maxHp = .divergesZeroDivisor := by
  simp [select, zero]

/-- A healed enemy underflows the subtraction and can select the strongest
recall text even with a zero stale high byte. -/
theorem healed_enemy_good_text : select 0 10 20 100 = .selected .good 246 := by
  native_decide

/-- The low-byte divisor can be zero for nonzero max HP. -/
theorem nonzero_max_hp_can_diverge : select 0 100 50 1024 = .divergesZeroDivisor := by
  native_decide

/-- Quotient classification observes only the low byte. -/
theorem quotient_low_byte_wraps : select 0 300 0 100 = .selected .ok 44 := by
  native_decide

private def routineEntry : UInt16 := 0x4ED7
private def routineBytes : List Sm83.Byte :=
  [0x17, 0xF6, 0x5C, 0x22, 0x08, 0xD5, 0xC5, 0x21, 0xE7, 0xCF,
   0x11, 0xE4, 0xCC, 0x46, 0x2B, 0x1A, 0x90, 0xE0, 0x98, 0x1B,
   0x46, 0x1A, 0x98, 0xE0, 0x97, 0x3E, 0x19, 0xE0, 0x99, 0xCD,
   0xAC, 0x38, 0x21, 0xF4, 0xCF, 0x2A, 0x46, 0xCB, 0x3F, 0xCB,
   0x18, 0xCB, 0x3F, 0xCB, 0x18, 0x78, 0x06, 0x04, 0xE0, 0x99,
   0xCD, 0xB9, 0x38, 0xC1, 0xD1, 0xF0, 0x98, 0x21, 0x25, 0x4F,
   0xA7, 0xC8, 0x21, 0x3E, 0x4F, 0xFE, 0x1E, 0xD8, 0x21, 0x2C,
   0x4F, 0xFE, 0x46, 0xD8, 0x21, 0x33, 0x4F, 0xC9]

structure RequiredRecallBytes (rom : Array Sm83.Byte) : Prop where
  routineWindow : Battle.Rom.Tables.tableBytes rom
      (romOffset 0x16 (Sm83.Word.ofNat routineEntry.toNat)) routineBytes.length =
    routineBytes.map (fun byte => byte.toNat.toUInt8)

/-- Runtime fixture predicate only. -/
def windowAgrees (rom : Array Sm83.Byte) : Bool :=
  decide (Battle.Rom.Tables.tableBytes rom
    (romOffset 0x16 (Sm83.Word.ofNat routineEntry.toNat)) routineBytes.length =
      routineBytes.map (fun byte => byte.toNat.toUInt8))

end Battle.Full.Recall
