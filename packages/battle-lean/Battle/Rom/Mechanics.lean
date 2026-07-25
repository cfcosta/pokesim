/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Rom.CombatTables

/-!
# Hash-identified canonical battle mechanics certificate

This is the proof-facing entry point for claims about Pokémon, moves, and move
effect dispatch. Runtime fixture success is deliberately insufficient: callers
must provide whole-ROM hash identity plus exact data-table and effect-table byte
witnesses.
-/

namespace Battle.Rom.Mechanics

open Battle.Rom.Closure

/-- The three independent obligations needed to call a ROM canonical for this
slice: whole-image identity, battle-data bytes, and effect-dispatch bytes. -/
structure CanonicalMechanicsBytes (sha256 : Sha256) (rom : CanonicalRom) : Prop where
  identity : rom.Valid sha256
  tables : Tables.RequiredTableBytes rom.bytes
  effects : Effects.RequiredEffectBytes rom.bytes
  combat : CombatTables.RequiredCombatBytes rom.bytes

/-- Exact decoded battle-relevant Pokémon, move, learnset, and progression data
for a hash-identified canonical ROM. -/
theorem data_exact {sha256 : Sha256} {rom : CanonicalRom}
    (certificate : CanonicalMechanicsBytes sha256 rom) :
    Tables.decodeMoves rom.bytes = Data.moves ∧
      Tables.decodeBaseStats rom.bytes = Data.baseStats ∧
      Tables.decodePokedexOrder rom.bytes = Data.pokedexOrder ∧
      Tables.decodeLearnPools rom.bytes = Data.learnPools ∧
      Tables.decodeGrowthRates rom.bytes = Data.Progression.growthRates ∧
      Tables.decodeInitialMoves rom.bytes = Data.Progression.initialMoves ∧
      Tables.decodeProgressionRows rom.bytes = Data.Progression.rows :=
  Tables.certified_tables certificate.tables

/-- All six decoded ROM phase tables equal the independent execution plan,
including `SpecialEffectsCont`'s physical fallthrough ordering. -/
theorem phase_tables_exact {sha256 : Sha256} {rom : CanonicalRom}
    (certificate : CanonicalMechanicsBytes sha256 rom) :
    Effects.decodePhase rom.bytes Symbols.residualEffects1 =
        some (Effects.expectedPhase .residual1) ∧
      Effects.decodePhase rom.bytes Symbols.setDamageEffects =
        some (Effects.expectedPhase .setDamage) ∧
      Effects.decodePhase rom.bytes Symbols.residualEffects2 =
        some (Effects.expectedPhase .residual2) ∧
      Effects.decodePhase rom.bytes Symbols.alwaysHappenSideEffects =
        some (Effects.expectedPhase .always) ∧
      Effects.decodePhase rom.bytes Symbols.specialEffects =
        some (Effects.expectedPhase .specialSkip) ∧
      Effects.decodePhase rom.bytes Symbols.specialEffectsCont =
        some (Effects.expectedPhase .continuation) := by
  have agreement := certificate.effects.phases
  simp [Effects.phaseTablesAgree] at agreement
  rcases agreement with ⟨⟨⟨⟨⟨residual1, setDamage⟩, residual2⟩, always⟩,
    special⟩, continuation⟩
  exact ⟨residual1, setDamage, residual2, always, special, continuation⟩

/-- Every one of the 86 decoded ROM pointer words classifies as exactly the
handler required by the independent model plan. Unknown addresses cannot satisfy
this equality because `handlerAt` returns `none`. -/
theorem handler_table_exact {sha256 : Sha256} {rom : CanonicalRom}
    (certificate : CanonicalMechanicsBytes sha256 rom) :
    (Effects.decodePointers rom.bytes).map Effects.handlerAt =
      Effects.expectedHandlers.map some := by
  have agreement := certificate.effects.handlers
  simpa [Effects.pointerHandlersAgree] using agreement

/-- Every ROM-decoded move routes through its ROM-decoded effect pointer to the
handler class required by the independent plan. Effect zero is the deliberate
no-pointer ordinary-damage case. -/
def moveRoutesAgree (rom : Array Sm83.Byte) : Bool :=
  let handlers := (Effects.decodePointers rom).map Effects.handlerAt
  (Tables.decodeMoves rom).all fun move =>
    if move.effect == 0 then (Full.EffectPlan.plan move.effect).mechanic == .ordinary
    else handlers.getD (move.effect.toNat - 1) none ==
      some (Effects.expectedHandler move.effect)

/-- Every decoded canonical move selects an indexed effect ID. This connects the
ROM move rows to the complete 86-word handler table rather than merely proving
that the independently authored move array is internally bounded. -/
theorem move_effects_indexed {sha256 : Sha256} {rom : CanonicalRom}
    (certificate : CanonicalMechanicsBytes sha256 rom) :
    (Tables.decodeMoves rom.bytes).all (fun move =>
      1 ≤ move.effect.toNat && move.effect.toNat ≤ 0x56 || move.effect == 0) = true := by
  rw [certificate.tables.moves]
  native_decide

/-- Critical-move, type-effect, and stat-stage data are also exact ROM bytes. -/
theorem combat_tables_exact {sha256 : Sha256} {rom : CanonicalRom}
    (certificate : CanonicalMechanicsBytes sha256 rom) :
    CombatTables.decodeHighCritical rom.bytes =
        some CombatTables.expectedHighCritical ∧
      CombatTables.decodeTypeEffectBytes rom.bytes =
        CombatTables.expectedTypeEffectBytes ∧
      CombatTables.decodeStatRatioBytes rom.bytes =
        CombatTables.expectedStatRatioBytes :=
  CombatTables.certified_combat_tables certificate.combat

/-- All 165 canonical move rows route to the exact decoded handler class. -/
theorem move_routes_exact {sha256 : Sha256} {rom : CanonicalRom}
    (certificate : CanonicalMechanicsBytes sha256 rom) :
    moveRoutesAgree rom.bytes = true := by
  have handlers := handler_table_exact certificate
  simp only [moveRoutesAgree, certificate.tables.moves, handlers]
  native_decide

/-- Compact conjunction used by downstream battle-routine refinement. -/
theorem canonical_mechanics_exact {sha256 : Sha256} {rom : CanonicalRom}
    (certificate : CanonicalMechanicsBytes sha256 rom) :
    Tables.decodeMoves rom.bytes = Data.moves ∧
      Tables.decodeBaseStats rom.bytes = Data.baseStats ∧
      (Effects.decodePointers rom.bytes).map Effects.handlerAt =
        Effects.expectedHandlers.map some ∧
      (Tables.decodeMoves rom.bytes).all (fun move =>
        1 ≤ move.effect.toNat && move.effect.toNat ≤ 0x56 || move.effect == 0) = true ∧
      CombatTables.decodeTypeEffectBytes rom.bytes =
        CombatTables.expectedTypeEffectBytes ∧
      CombatTables.decodeStatRatioBytes rom.bytes =
        CombatTables.expectedStatRatioBytes ∧
      moveRoutesAgree rom.bytes = true := by
  exact ⟨certificate.tables.moves, certificate.tables.baseStats,
    handler_table_exact certificate, move_effects_indexed certificate,
    certificate.combat.typeEffects, certificate.combat.statRatios,
    move_routes_exact certificate⟩

end Battle.Rom.Mechanics
