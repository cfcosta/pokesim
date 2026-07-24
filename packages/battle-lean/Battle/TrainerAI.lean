/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.State

/-!
# Generation-I trainer item/switch decisions

Decision fragments are exact transcriptions of the per-class routines after the
shared AI random byte is available. In particular, CooltrainerF consumes but
ignores the intended 25% gate, while Blaine honors the gate but performs no HP
check before using a Super Potion.
-/

namespace Battle.TrainerAI

inductive Item where
  | potion
  | superPotion
  | hyperPotion
  | fullRestore
  | fullHeal
  | xAttack
  | xDefend
  | xSpeed
  | guardSpec
  deriving Repr, DecidableEq, BEq

inductive Decision where
  | normalMove
  | useItem (item : Item)
  | switch
  deriving Repr, DecidableEq, BEq

structure Context where
  currentHp : UInt16
  maxHp : UInt16
  hasSwitchReserve : Bool
  deriving Repr, DecidableEq, BEq

/-- `AICheckIfHPBelowFraction`: strict current-HP comparison. -/
def hpBelowFraction (context : Context) (divisor : Nat) : Bool :=
  divisor != 0 && context.currentHp.toNat < context.maxHp.toNat / divisor

/-- Intended random gates use `cp threshold; ret nc`, hence strict `<`. -/
def passesGate (random threshold : UInt8) : Bool := random < threshold

def twentyFivePercentThreshold : UInt8 := 64

/-- Canonical CooltrainerF behavior. `random` is deliberately ignored because
its `ret nc` is commented out. -/
def cooltrainerF (_random : UInt8) (context : Context) : Decision :=
  if hpBelowFraction context 10 then .useItem .hyperPotion
  else if hpBelowFraction context 5 then
    if context.hasSwitchReserve then .switch else .normalMove
  else .normalMove

/-- Blaine's full routine: 25% gate, then unconditional Super Potion. -/
def blaine (random : UInt8) (_context : Context) : Decision :=
  if passesGate random twentyFivePercentThreshold then .useItem .superPotion
  else .normalMove

/-- HP update shared by AI Potion/Super/Hyper Potion paths. -/
def recoverHp (amount : UInt8) (context : Context) : UInt16 :=
  UInt16.ofNat (min (context.currentHp.toNat + amount.toNat) context.maxHp.toNat)

/-! ## Universal compatibility theorems -/

/-- The missing return makes the CooltrainerF random comparison dead for every
pair of bytes and every context. -/
theorem cooltrainerF_random_dead (first second : UInt8) (context : Context) :
    cooltrainerF first context = cooltrainerF second context := by
  rfl

/-- Below one tenth HP, Hyper Potion is unconditional. -/
theorem cooltrainerF_low_hp (random : UInt8) (context : Context)
    (low : hpBelowFraction context 10 = true) :
    cooltrainerF random context = .useItem .hyperPotion := by
  simp [cooltrainerF, low]

/-- Between the two checks, a reserve makes the AI switch. -/
theorem cooltrainerF_switches_when_second_check (random : UInt8) (context : Context)
    (notLow : hpBelowFraction context 10 = false)
    (second : hpBelowFraction context 5 = true)
    (reserve : context.hasSwitchReserve = true) :
    cooltrainerF random context = .switch := by
  simp [cooltrainerF, notLow, second, reserve]

/-- The canonical routine does not literally always switch: healthy states can
return to normal move selection. -/
theorem cooltrainerF_can_attack :
    cooltrainerF 0 { currentHp := 100, maxHp := 100, hasSwitchReserve := true } =
      .normalMove := by
  native_decide

/-- Once Blaine's gate passes, HP and reserves are irrelevant. -/
theorem blaine_unconditional_after_gate (random : UInt8) (context : Context)
    (passed : passesGate random twentyFivePercentThreshold = true) :
    blaine random context = .useItem .superPotion := by
  simp [blaine, passed]

/-- Blaine therefore uses a Super Potion at full HP on every passing byte. -/
theorem blaine_full_hp_witness (hp : UInt16) :
    blaine 0 { currentHp := hp, maxHp := hp, hasSwitchReserve := false } =
      .useItem .superPotion := by
  rfl

/-- A capped AI heal gains nothing at full HP. -/
theorem recover_full_hp (amount : UInt8) (hp : UInt16) :
    recoverHp amount { currentHp := hp, maxHp := hp, hasSwitchReserve := false } = hp := by
  apply UInt16.toNat.inj
  simp [recoverHp]

/-- The 25% gate accepts exactly bytes 0 through 63. -/
theorem gate_exact (random : UInt8) :
    passesGate random twentyFivePercentThreshold = true ↔ random.toNat < 64 := by
  simpa [passesGate, twentyFivePercentThreshold] using
    (UInt8.lt_ofNat_iff (n := random) (m := 64) (by native_decide))

#guard cooltrainerF 255 { currentHp := 5, maxHp := 100, hasSwitchReserve := false } ==
  .useItem .hyperPotion
#guard cooltrainerF 0 { currentHp := 15, maxHp := 100, hasSwitchReserve := true } == .switch
#guard blaine 63 { currentHp := 100, maxHp := 100, hasSwitchReserve := false } ==
  .useItem .superPotion
#guard blaine 64 { currentHp := 1, maxHp := 100, hasSwitchReserve := false } == .normalMove

end Battle.TrainerAI
