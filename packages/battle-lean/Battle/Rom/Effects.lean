/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Rom.Tables
import Battle.Full.EffectPlan

/-!
# Canonical ROM move-effect dispatch

This module decodes the six terminated phase tables and all 86 little-endian
handler pointers directly from canonical ROM bytes. The decoded tables are
compared with the independently stated `Battle.Full.EffectPlan`; source labels
and assembler declarations are not theorem premises.
-/

namespace Battle.Rom.Effects

open Battle.Rom.Closure
open Battle.Full.EffectPlan

inductive Handler where
  | null | sleep | poison | drainHp | freezeBurnParalyze | explode
  | statUp | payDay | statDown | conversion | haze | bide | thrash
  | switchAndTeleport | multiHit | flinch | oneHitKo | charge | trapping
  | mist | focusEnergy | recoil | confusionSide | confusion | paralyze
  | substitute | hyperBeam | rage | mimic | leechSeed | splash | disable
  | heal | transform | reflectLightScreen
  deriving Repr, DecidableEq, BEq

/-- Classify a canonical bank-$0F` handler address. Unknown/malformed pointers
remain `none`; they are never treated as `NULL`. -/
def handlerAt (address : UInt16) : Option Handler :=
  match address.toNat with
  | 0x0000 => some .null
  | 0x71FC => some .sleep
  | 0x724F => some .poison
  | 0x72E9 => some .drainHp
  | 0x72F1 => some .explode
  | 0x730C => some .freezeBurnParalyze
  | 0x7428 => some .statUp
  | 0x754C => some .statDown
  | 0x76E5 => some .bide
  | 0x7717 => some .thrash
  | 0x7739 => some .switchAndTeleport
  | 0x7811 => some .multiHit
  | 0x785B => some .flinch
  | 0x7884 => some .oneHitKo
  | 0x788C => some .charge
  | 0x7917 => some .trapping
  | 0x7941 => some .mist
  | 0x7949 => some .focusEnergy
  | 0x7951 => some .recoil
  | 0x7959 => some .confusionSide
  | 0x7961 => some .confusion
  | 0x79B1 => some .paralyze
  | 0x79B9 => some .substitute
  | 0x79C1 => some .hyperBeam
  | 0x79DF => some .rage
  | 0x79ED => some .mimic
  | 0x7A7C => some .leechSeed
  | 0x7A84 => some .splash
  | 0x7A8A => some .disable
  | 0x7B0E => some .payDay
  | 0x7B16 => some .conversion
  | 0x7B1E => some .haze
  | 0x7B26 => some .heal
  | 0x7B2E => some .transform
  | 0x7B36 => some .reflectLightScreen
  | _ => none

/-- Handler expected by the independent effect mechanic. The few unused and
explicitly direct-handled IDs are separated by effect ID. -/
def expectedHandler (effect : UInt8) : Handler :=
  match effect.toNat with
  | 0x01 => .sleep
  | 0x1E => .multiHit
  | 0x48 | 0x49 | 0x4A | 0x4B => .statDown
  | 0x4E => .null
  | _ =>
    match (plan effect).mechanic with
    | .ordinary | .malformed => .null
    | .unused => .null
    | .poisonSide _ | .poison => .poison
    | .drain | .dreamEater => .drainHp
    | .burnSide _ | .freezeSide _ | .paralyzeSide _ => .freezeBurnParalyze
    | .explode => .explode
    | .mirrorMove | .swift | .superFang | .specialDamage | .jumpKick |
        .metronome => .null
    | .statUp _ _ => .statUp
    | .payDay => .payDay
    | .statDown _ _ | .statDownSide _ => .statDown
    | .conversion => .conversion
    | .haze => .haze
    | .bide => .bide
    | .thrash => .thrash
    | .switchOrTeleport => .switchAndTeleport
    | .multiHit | .attackTwice | .twineedle => .multiHit
    | .flinchSide _ => .flinch
    | .sleep => .sleep
    | .ohko => .oneHitKo
    | .charge _ => .charge
    | .trapping => .trapping
    | .mist => .mist
    | .focusEnergy => .focusEnergy
    | .recoil => .recoil
    | .confusionSide => .confusionSide
    | .confusion => .confusion
    | .paralyze => .paralyze
    | .substitute => .substitute
    | .hyperBeam => .hyperBeam
    | .rage => .rage
    | .mimic => .mimic
    | .leechSeed => .leechSeed
    | .splash => .splash
    | .disable => .disable
    | .heal => .heal
    | .transform => .transform
    | .lightScreen | .reflect => .reflectLightScreen

@[inline] def decodePointer (rom : Array Sm83.Byte) (index : Nat) : UInt16 :=
  let offset := Symbols.moveEffectPointerTable.offset + index * 2
  (Tables.byteAt rom offset).toUInt16 |||
    ((Tables.byteAt rom (offset + 1)).toUInt16 <<< 8)

def decodePointers (rom : Array Sm83.Byte) : Array UInt16 :=
  ((List.range TableLayout.moveEffectCount).map (decodePointer rom)).toArray

def expectedHandlers : Array Handler :=
  ((List.range TableLayout.moveEffectCount).map fun index =>
    expectedHandler (index + 1).toUInt8).toArray

def pointerHandlersAgree (rom : Array Sm83.Byte) : Bool :=
  decide ((decodePointers rom).map handlerAt = expectedHandlers.map some)

private def decodeTerminated (rom : Array Sm83.Byte) : Nat → Nat →
    Option (List UInt8)
  | _, 0 => none
  | offset, fuel + 1 =>
      let byte := Tables.byteAt rom offset
      if byte == 0xFF then some []
      else match decodeTerminated rom (offset + 1) fuel with
        | some tail => some (byte :: tail)
        | none => none

/-- Effect IDs in the independent plan that occupy a phase table, in ROM's
ascending effect-ID order. -/
def expectedPhase (phase : Phase) : List UInt8 :=
  if phase == .specialSkip then
    -- `SpecialEffectsCont` is a physical suffix reached by fallthrough, so its
    -- two entries follow Recoil rather than appearing in numeric-ID order.
    [0x03, 0x07, 0x08, 0x10, 0x11, 0x1d, 0x1e, 0x27,
     0x28, 0x29, 0x2b, 0x2c, 0x2d, 0x30, 0x1b, 0x2a]
  else
    (List.range 0x57).filterMap fun id =>
      let effect := id.toUInt8
      if (plan effect).phases.contains phase then some effect else none

def decodePhase (rom : Array Sm83.Byte) (symbol : Symbol) : Option (List UInt8) :=
  decodeTerminated rom symbol.offset 0x57

def phaseTablesAgree (rom : Array Sm83.Byte) : Bool :=
  decodePhase rom Symbols.residualEffects1 == some (expectedPhase .residual1) &&
    decodePhase rom Symbols.setDamageEffects == some (expectedPhase .setDamage) &&
    decodePhase rom Symbols.residualEffects2 == some (expectedPhase .residual2) &&
    decodePhase rom Symbols.alwaysHappenSideEffects == some (expectedPhase .always) &&
    decodePhase rom Symbols.specialEffects == some (expectedPhase .specialSkip) &&
    decodePhase rom Symbols.specialEffectsCont == some (expectedPhase .continuation)

/-- Explicit proof boundary for the effect-dispatch bytes. Besides decoded
agreement, each window equality retains the terminating `$FF` and every raw
little-endian pointer byte. -/
structure RequiredEffectBytes (rom : Array Sm83.Byte) : Prop where
  residual1Window : Tables.tableBytes rom Symbols.residualEffects1.offset
    ((expectedPhase .residual1).length + 1) = expectedPhase .residual1 ++ [0xFF]
  setDamageWindow : Tables.tableBytes rom Symbols.setDamageEffects.offset
    ((expectedPhase .setDamage).length + 1) = expectedPhase .setDamage ++ [0xFF]
  residual2Window : Tables.tableBytes rom Symbols.residualEffects2.offset
    ((expectedPhase .residual2).length + 1) = expectedPhase .residual2 ++ [0xFF]
  alwaysWindow : Tables.tableBytes rom Symbols.alwaysHappenSideEffects.offset
    ((expectedPhase .always).length + 1) = expectedPhase .always ++ [0xFF]
  specialWindow : Tables.tableBytes rom Symbols.specialEffects.offset
    ((expectedPhase .specialSkip).length + 1) = expectedPhase .specialSkip ++ [0xFF]
  continuationWindow : Tables.tableBytes rom Symbols.specialEffectsCont.offset
    ((expectedPhase .continuation).length + 1) = expectedPhase .continuation ++ [0xFF]
  pointerWindow : Tables.tableBytes rom Symbols.moveEffectPointerTable.offset
    TableLayout.moveEffectPointerSize =
      (decodePointers rom).toList.flatMap fun (pointer : UInt16) =>
        [pointer.toUInt8, (pointer >>> 8).toUInt8]
  phases : phaseTablesAgree rom = true
  handlers : pointerHandlersAgree rom = true

/-- A supplied byte certificate proves that canonical ROM dispatch selects the
same phase memberships and typed handler classes as the model. -/
theorem certified_dispatch {rom : Array Sm83.Byte}
    (certificate : RequiredEffectBytes rom) :
    phaseTablesAgree rom = true ∧ pointerHandlersAgree rom = true :=
  ⟨certificate.phases, certificate.handlers⟩

/-- Runtime fixture predicate. This is evidence for a temporary hash-checked ROM,
not a replacement for `RequiredEffectBytes` in proof modules. -/
def agreesWithPlan (rom : Array Sm83.Byte) : Bool :=
  phaseTablesAgree rom && pointerHandlersAgree rom

@[simp] theorem expected_handlers_size : expectedHandlers.size = 0x56 := by
  native_decide

#guard expectedPhase .residual1 ==
  [0x18, 0x19, 0x1c, 0x2e, 0x2f, 0x31, 0x38, 0x39,
   0x40, 0x41, 0x42, 0x43, 0x4f, 0x52, 0x54, 0x55]
#guard expectedPhase .continuation == [0x1b, 0x2a]
#guard expectedHandler 0x53 == .null

end Battle.Rom.Effects
