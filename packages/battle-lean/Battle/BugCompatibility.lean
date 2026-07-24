/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Critical
import Battle.Accuracy
import Battle.Effects.Substitute
import Battle.Effects.Healing
import Battle.TrainerAI
import Battle.LinkBugs
import Battle.DamageStats

/-!
# External bug-compatibility certificate

A single project-owned theorem object covering every claim inventoried from the
unlicensed external formalization. This module imports no external code. Its
fields point to executable semantics used by the battle implementation, not
parallel “fixed” versions.
-/

namespace Battle.BugCompatibility

structure Certificate : Prop where
  b01_focusNeverImproves : ∀ base high,
    (Critical.thresholdFromSpeed base high true).toNat ≤
      (Critical.thresholdFromSpeed base high false).toNat
  b01_focusWitness :
    Critical.thresholdFromSpeed 4 false true = 0 ∧
    Critical.thresholdFromSpeed 4 false false = 2
  b02_accuracyBoundary : ∀ accuracy random,
    Accuracy.hits accuracy random ≠ Accuracy.hitsInclusive accuracy random ↔
      random = accuracy
  b03_criticalBoundary : ∀ threshold random,
    Critical.occurs threshold random ≠ Critical.occursInclusive threshold random ↔
      Critical.rotateRandom random = threshold
  b04_substituteEquality : ∀ maxHp,
    Effects.Substitute.use false
      (UInt16.ofNat (Effects.Substitute.cost maxHp).toNat) maxHp =
      .created 0 (Effects.Substitute.cost maxHp)
  b05_healFalseFailureGaps : ∀ currentHp maxHp,
    currentHp.toNat ≤ maxHp.toNat → maxHp.toNat ≤ 999 → currentHp ≠ maxHp →
    Effects.Healing.checkFails currentHp maxHp = true →
      maxHp.toNat - currentHp.toNat = 255 ∨
      maxHp.toNat - currentHp.toNat = 511 ∨
      maxHp.toNat - currentHp.toNat = 767
  b06_cooltrainerRandomDead : ∀ first second context,
    TrainerAI.cooltrainerF first context = TrainerAI.cooltrainerF second context
  b07_blaineAfterGate : ∀ random context,
    TrainerAI.passesGate random TrainerAI.twentyFivePercentThreshold = true →
      TrainerAI.blaine random context = .useItem .superPotion
  b08_psywaveDesync :
    ∃ seed playerFinal enemyFinal,
      LinkBugs.PsywaveResolves .playerAttack 75 seed 5 playerFinal [0, 5] ∧
      LinkBugs.PsywaveResolves .enemyAttack 75 seed 0 enemyFinal [0] ∧
      playerFinal.index = 2 ∧ enemyFinal.index = 1
  b09_bideDesync : ∀ damage,
    LinkBugs.clearAfterEnemyFaints damage ≠ LinkBugs.clearAfterPlayerFaints damage ↔
      damage.low ≠ 0
  b10_scaleExact : ∀ stat,
    (DamageStats.scaleToByte stat).toNat = stat.toNat / 4 % 256
  b10_screenFreeze :
    DamageStats.resolve 300 512 true =
      .divisionFreeze { attack := 75, defense := 0 }
  b11_lowDefenseFreeze :
    DamageStats.resolve 256 3 false =
      .divisionFreeze { attack := 64, defense := 0 }
  b12_equalStageProfile :
    Accuracy.equalStageProfile = #[255, 252, 255, 254, 252, 249, 255]
  b13_badgeScreen :
    DamageStats.badgeScreenPipeline 300 458 1 true =
      .ready { attack := 75, defense := 1 }

/-- All 13 externally enumerated bug families are supported by project-owned
executable primitives and Lean proofs. -/
theorem all_external_bugs_supported : Certificate := by
  refine
    { b01_focusNeverImproves := Critical.focus_never_improves
      b01_focusWitness := Critical.focus_energy_witness
      b02_accuracyBoundary := Accuracy.strict_boundary_iff
      b03_criticalBoundary := Critical.strict_boundary_iff
      b04_substituteEquality := Effects.Substitute.equality_leaves_zero
      b05_healFalseFailureGaps := ?_
      b06_cooltrainerRandomDead := TrainerAI.cooltrainerF_random_dead
      b07_blaineAfterGate := ?_
      b08_psywaveDesync := LinkBugs.psywave_link_desync_exists
      b09_bideDesync := LinkBugs.bide_desync_iff
      b10_scaleExact := DamageStats.scaleToByte_exact
      b10_screenFreeze := DamageStats.screen_512_freezes.1
      b11_lowDefenseFreeze := DamageStats.low_defense_freezes.2.2.1
      b12_equalStageProfile := Accuracy.equal_stage_profile_exact
      b13_badgeScreen := DamageStats.badge_screen_catastrophe.2 }
  · intro current maximum ordered bounded notFull fails
    exact Effects.Healing.false_failure_gaps current maximum ordered bounded notFull fails
  · intro random context passed
    exact TrainerAI.blaine_unconditional_after_gate random context passed

end Battle.BugCompatibility
