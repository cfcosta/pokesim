/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Full.Progression

/-!
# BCD battle money

Three-byte packed BCD with `AddBCD` saturation. Pay Day and trainer prize
construction stay BCD-valued; cleanup uses the raw result guard rather than a
post-cleanup terminal guess.
-/

namespace Battle.Full.Money

structure Bcd3 where
  high : UInt8
  middle : UInt8
  low : UInt8
  deriving Repr, DecidableEq, BEq

private def digit (byte : UInt8) (high : Bool) : Nat :=
  (if high then byte >>> 4 else byte &&& 0x0f).toNat

/-- Decode packed digits. This is specified for canonical BCD values. -/
def Bcd3.toNat (value : Bcd3) : Nat :=
  digit value.high true * 100000 + digit value.high false * 10000 +
    digit value.middle true * 1000 + digit value.middle false * 100 +
    digit value.low true * 10 + digit value.low false

private def pair (tens ones : Nat) : UInt8 :=
  UInt8.ofNat ((tens % 10) * 16 + (ones % 10))

/-- Canonical packed representation, saturated at AddBCD's `$999999`. -/
def Bcd3.ofNat (input : Nat) : Bcd3 :=
  let value := min input 999999
  { high := pair (value / 100000) (value / 10000)
    middle := pair (value / 1000) (value / 100)
    low := pair (value / 10) value }

def Bcd3.valid (value : Bcd3) : Bool :=
  digit value.high true < 10 && digit value.high false < 10 &&
    digit value.middle true < 10 && digit value.middle false < 10 &&
    digit value.low true < 10 && digit value.low false < 10

/-- Valid-BCD observational summary of three-byte `AddBCD`, including saturation
on final carry. -/
def Bcd3.add (left right : Bcd3) : Bcd3 := ofNat (left.toNat + right.toNat)

/-- One Pay Day hit adds `2 × level`, represented as three BCD bytes. -/
def addPayDay (total : Bcd3) (level : UInt8) : Bcd3 :=
  total.add (Bcd3.ofNat (2 * level.toNat))

/-- Trainer prize setup repeatedly adds the two-byte class base money once per
final enemy level. -/
def trainerPrize (baseMoney : UInt16) (finalEnemyLevel : UInt8) : Bcd3 :=
  Bcd3.ofNat (baseMoney.toNat * finalEnemyLevel.toNat)

structure EpilogueInput where
  linkBattle : Bool
  rawBattleResult : UInt8
  playerMoney : Bcd3
  payDayMoney : Bcd3
  deriving Repr, DecidableEq, BEq

structure EpilogueResult where
  playerMoney : Bcd3
  runEvolution : Bool
  pickedUpPayDay : Bool
  deriving Repr, DecidableEq, BEq

/-- `EndOfBattle`: links enter evolution directly; non-link nonzero raw results
skip both Pay Day and evolution. -/
def epilogue (input : EpilogueInput) : EpilogueResult :=
  if input.linkBattle then
    { playerMoney := input.playerMoney, runEvolution := true, pickedUpPayDay := false }
  else if input.rawBattleResult != 0 then
    { playerMoney := input.playerMoney, runEvolution := false, pickedUpPayDay := false }
  else
    { playerMoney := input.playerMoney.add input.payDayMoney
      runEvolution := true
      pickedUpPayDay := input.payDayMoney.toNat != 0 }

/-- AddBCD overflow saturates all three bytes to `$99`. -/
example : Bcd3.add (Bcd3.ofNat 999990) (Bcd3.ofNat 20) =
    { high := 0x99, middle := 0x99, low := 0x99 } := by native_decide

/-- Pay Day accumulation remains decimal, not binary packed-byte arithmetic. -/
example : (addPayDay (Bcd3.ofNat 98) 1).toNat = 100 := by native_decide

end Battle.Full.Money
