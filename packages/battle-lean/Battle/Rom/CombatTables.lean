/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Rom.Effects
import Battle.Critical
import Battle.Accuracy
import Battle.TypeChart

/-!
# Canonical combat lookup tables

Decoders for the high-critical move list, ordered type-effect triples, and the
13 stat-stage ratios. Their exact bytes are compared with independently stated
battle functions, including every `$FF` terminator.
-/

namespace Battle.Rom.CombatTables

open Battle.Rom.Closure

private def decodeTerminated (rom : Array Sm83.Byte) : Nat → Nat →
    Option (List UInt8)
  | _, 0 => none
  | offset, fuel + 1 =>
      let byte := Tables.byteAt rom offset
      if byte == 0xFF then some []
      else match decodeTerminated rom (offset + 1) fuel with
        | some tail => some (byte :: tail)
        | none => none

/-- Independent finite characterization of `Critical.highCriticalMove`. -/
def expectedHighCritical : List UInt8 :=
  (List.range 256).filterMap fun id =>
    if Critical.highCriticalMove id.toUInt8 then some id.toUInt8 else none

def decodeHighCritical (rom : Array Sm83.Byte) : Option (List UInt8) :=
  decodeTerminated rom Symbols.highCriticalMoves.offset 256

/-- Lossless byte order of the independent type-effect triples. -/
def expectedTypeEffectBytes : List UInt8 :=
  TypeChart.typeEffects.flatMap fun entry => [entry.1, entry.2.1, entry.2.2]

def decodeTypeEffectBytes (rom : Array Sm83.Byte) : List UInt8 :=
  Tables.tableBytes rom Symbols.typeEffects.offset expectedTypeEffectBytes.length

/-- Exact numerator/denominator order used by stage indices 1 through 13. -/
def expectedStatRatioBytes : List UInt8 :=
  Accuracy.stageRatios.toList.flatMap fun ratio =>
    [ratio.numerator.toUInt8, ratio.denominator.toUInt8]

def decodeStatRatioBytes (rom : Array Sm83.Byte) : List UInt8 :=
  Tables.tableBytes rom Symbols.statModifierRatios.offset expectedStatRatioBytes.length

structure RequiredCombatBytes (rom : Array Sm83.Byte) : Prop where
  highCriticalWindow : Tables.tableBytes rom Symbols.highCriticalMoves.offset
    (expectedHighCritical.length + 1) = expectedHighCritical ++ [0xFF]
  highCritical : decodeHighCritical rom = some expectedHighCritical
  typeEffectsWindow : Tables.tableBytes rom Symbols.typeEffects.offset
    (expectedTypeEffectBytes.length + 1) = expectedTypeEffectBytes ++ [0xFF]
  typeEffects : decodeTypeEffectBytes rom = expectedTypeEffectBytes
  statRatiosWindow : Tables.tableBytes rom Symbols.statModifierRatios.offset
    expectedStatRatioBytes.length = expectedStatRatioBytes
  statRatios : decodeStatRatioBytes rom = expectedStatRatioBytes

/-- Exact combat-table conjunction used by move execution refinement. -/
theorem certified_combat_tables {rom : Array Sm83.Byte}
    (certificate : RequiredCombatBytes rom) :
    decodeHighCritical rom = some expectedHighCritical ∧
      decodeTypeEffectBytes rom = expectedTypeEffectBytes ∧
      decodeStatRatioBytes rom = expectedStatRatioBytes :=
  ⟨certificate.highCritical, certificate.typeEffects, certificate.statRatios⟩

/-- Runtime predicate for a temporary hash-checked canonical ROM. -/
def agreesWithModel (rom : Array Sm83.Byte) : Bool :=
  decide (decodeHighCritical rom = some expectedHighCritical) &&
    decide (decodeTypeEffectBytes rom = expectedTypeEffectBytes) &&
    decide (Tables.byteAt rom
      (Symbols.typeEffects.offset + expectedTypeEffectBytes.length) = 0xFF) &&
    decide (decodeStatRatioBytes rom = expectedStatRatioBytes)

#guard expectedHighCritical == [2, 75, 152, 163]
#guard expectedTypeEffectBytes.length == 82 * 3
#guard expectedStatRatioBytes.length == 13 * 2

end Battle.Rom.CombatTables
