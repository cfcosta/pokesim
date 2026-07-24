/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Full.SelfPlay
import Battle.Full.Capture
import Battle.Full.Safari
import Battle.Full.TrainerController
import Battle.Full.Progression
import Battle.BugCompatibility

/-!
# Full-model coverage certificate

This certifies dispatch/domain coverage of the executable high-level model. It
does not assert decoded-ROM routine refinement; that remains a separate theorem
boundary.
-/

namespace Battle.Full.Support

structure ModelCoverage : Prop where
  canonicalMoves :
    Data.moves.all (fun move =>
      (EffectPlan.plan move.effect).mechanic != .malformed) = true
  ordinaryItems : ∀ item : UInt8, 1 ≤ item.toNat → item.toNat ≤ 0x53 →
    Items.disposition item ≠ .outOfRange
  trainerClasses : ∀ classId : UInt8, 1 ≤ classId.toNat → classId.toNat ≤ 47 →
    (TrainerController.classRow? classId).isSome = true
  externalBugs : BugCompatibility.Certificate
  generatedPlayerLegal : ∀ state : Environment.State,
    RL.teamLegal RL.genDex .canonical state.playerReset.1 = true
  generatedEnemyLegal : ∀ state : Environment.State,
    RL.teamLegal RL.genDex .canonical state.enemyReset.1 = true
  captureBallDomain :
    [1, 2, 3, 4, 8].all (fun item => (Capture.Ball.ofItem item).isSome) = true
  progressionDomains : Data.Progression.growthRates.size = 191 ∧
    Data.Progression.initialMoves.size = 191 ∧ Data.Progression.rows.size = 191

/-- Dispatch, generator, and externally audited bug closure for the full model. -/
theorem model_coverage : ModelCoverage :=
  { canonicalMoves := EffectPlan.canonical_moves_supported
    ordinaryItems := Items.ordinary_table_total
    trainerClasses := TrainerController.class_table_total
    externalBugs := BugCompatibility.all_external_bugs_supported
    generatedPlayerLegal := Environment.player_reset_legal
    generatedEnemyLegal := Environment.enemy_reset_legal
    captureBallDomain := by native_decide
    progressionDomains := ⟨Data.Progression.growthRates_size,
      Data.Progression.initialMoves_size, Data.Progression.rows_size⟩ }

end Battle.Full.Support
