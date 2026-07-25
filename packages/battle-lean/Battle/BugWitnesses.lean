/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.BugCompatibility
import Battle.Rom.SubstituteRoutine

/-!
# Concrete Generation-I bug witnesses

`Battle.BugCompatibility` provides universal characterizations. This module
adds the complementary occurrence layer: an explicit machine-checked witness
for every audited bug family. Intended alternatives are local comparison
functions only; executable battle code continues to use cartridge behavior.

The external `../gameboy-pokered-verify` project was used only to enumerate
public claims. It has no detected license, so no definitions, proofs, CPU model,
or prose are imported or copied here.
-/

namespace Battle.BugWitnesses

/-- A repaired Substitute gate used only to state the mismatch. -/
def intendedSubstitute (current maximum : UInt16) : Effects.Substitute.Result :=
  let cost := Effects.Substitute.cost maximum
  if cost == 0 || current.toNat ≤ cost.toNat then .insufficientHp
  else .created (UInt16.ofNat (current.toNat - cost.toNat)) cost

/-- A repaired Cooltrainer-F gate used only to expose the dead comparison. -/
def intendedCooltrainerF (random : UInt8) (context : TrainerAI.Context) :
    TrainerAI.Decision :=
  if TrainerAI.passesGate random TrainerAI.twentyFivePercentThreshold then
    TrainerAI.cooltrainerF random context
  else .normalMove

/-- A repaired Blaine decision requires both the random gate and low HP. -/
def intendedBlaine (random : UInt8) (context : TrainerAI.Context) :
    TrainerAI.Decision :=
  if TrainerAI.passesGate random TrainerAI.twentyFivePercentThreshold &&
      TrainerAI.hpBelowFraction context 2 then .useItem .superPotion
  else .normalMove

/-- Focus Energy observably lowers the ordinary threshold at base Speed four. -/
theorem focus_energy_occurs :
    Critical.thresholdFromSpeed 4 false true ≠
      Critical.thresholdFromSpeed 4 false false := by
  native_decide

/-- The final accuracy comparison disagrees with the intended inclusive boundary. -/
theorem accuracy_boundary_occurs : Accuracy.hits 255 255 ≠
    Accuracy.hitsInclusive 255 255 := by
  native_decide

/-- The rotated critical byte has the same strict-boundary witness. -/
theorem critical_boundary_occurs : Critical.occurs 255 255 ≠
    Critical.occursInclusive 255 255 := by
  native_decide

/-- Paying exactly one quarter creates a Substitute while leaving user HP zero,
where the repaired gate rejects the action. -/
theorem substitute_zero_user_hp_occurs :
    Effects.Substitute.use false 25 100 = .created 0 25 ∧
    intendedSubstitute 25 100 = .insufficientHp := by
  native_decide

/-- The same Substitute occurrence follows from the certified decoded shifts and
subtraction, not only the independently stated model. -/
theorem decoded_substitute_zero_user_hp_occurs :
    Effects.Substitute.use false
      (UInt16.ofNat (Rom.SubstituteRoutine.decodedCost 100).toNat) 100 =
        .created 0 (Rom.SubstituteRoutine.decodedCost 100) := by
  exact Rom.SubstituteRoutine.decoded_equality_leaves_zero 100

/-- Recover/Rest's broken comparison rejects a non-full 45/300 HP state. -/
theorem healing_false_failure_occurs :
    Effects.Healing.checkFails 45 300 = true ∧ (45 : UInt16) ≠ 300 := by
  native_decide

/-- The false failure is also derived from the certified decoded `CP`/`SBC`. -/
theorem decoded_healing_false_failure_occurs :
    Rom.HealRoutine.decodedCheckFails 45 300 = true := by
  rw [Rom.HealRoutine.decoded_check_fails_exact]
  native_decide

/-- Cooltrainer F ignores the intended random rejection at low HP. -/
theorem cooltrainer_random_gate_bug_occurs :
    let context : TrainerAI.Context :=
      { currentHp := 5, maxHp := 100, hasSwitchReserve := false }
    TrainerAI.cooltrainerF 255 context = .useItem .hyperPotion ∧
      intendedCooltrainerF 255 context = .normalMove := by
  native_decide

/-- Blaine consumes a Super Potion at full HP after a passing byte. -/
theorem blaine_full_hp_bug_occurs :
    let context : TrainerAI.Context :=
      { currentHp := 100, maxHp := 100, hasSwitchReserve := false }
    TrainerAI.blaine 0 context = .useItem .superPotion ∧
      intendedBlaine 0 context = .normalMove ∧
      TrainerAI.recoverHp 50 context = 100 := by
  native_decide

/-- Psywave's two cartridge perspectives consume different synchronized suffixes. -/
theorem psywave_link_desync_occurs :
    ∃ seed playerFinal enemyFinal,
      LinkBugs.PsywaveResolves .playerAttack 75 seed 5 playerFinal [0, 5] ∧
      LinkBugs.PsywaveResolves .enemyAttack 75 seed 0 enemyFinal [0] ∧
      playerFinal.index = 2 ∧ enemyFinal.index = 1 :=
  LinkBugs.psywave_link_desync_exists

/-- Faint-side Bide cleanup disagrees at accumulated damage 300. -/
theorem bide_link_desync_occurs :
    let damage : LinkBugs.BideAccumulated := { high := 1, low := 44 }
    LinkBugs.clearAfterEnemyFaints damage ≠
      LinkBugs.clearAfterPlayerFaints damage := by
  native_decide

/-- Reflect at defense 512 introduces a division freeze that is absent without it. -/
theorem screen_overflow_occurs :
    DamageStats.resolve 300 512 true =
        .divisionFreeze { attack := 75, defense := 0 } ∧
      DamageStats.resolve 300 512 false =
        .ready { attack := 75, defense := 128 } :=
  DamageStats.screen_512_freezes

/-- A low nonzero defense becomes the zero divisor when the other stat activates
scaling. -/
theorem low_defense_freeze_occurs :
    DamageStats.resolve 256 3 false =
      .divisionFreeze { attack := 64, defense := 0 } :=
  DamageStats.low_defense_freezes.2.2.1

/-- Equal +1 accuracy/evasion stages reduce a nominal 255 chance to 252. -/
theorem equal_stages_fail_to_cancel_occurs :
    Accuracy.calcHitChance 255 8 8 = 252 ∧
      Accuracy.calcHitChance 255 7 7 = 255 := by
  native_decide

/-- One badge reapplication makes Reflect reduce effective defense from 128 to
one instead of improving it. -/
theorem badge_screen_catastrophe_occurs :
    DamageStats.badgeScreenPipeline 300 458 1 false =
        .ready { attack := 75, defense := 128 } ∧
      DamageStats.badgeScreenPipeline 300 458 1 true =
        .ready { attack := 75, defense := 1 } :=
  DamageStats.badge_screen_catastrophe

/-- One proof object requiring a concrete occurrence for all thirteen audited
families. Universal characterizations remain in `BugCompatibility.Certificate`. -/
structure OccurrenceCertificate : Prop where
  focusEnergy : Critical.thresholdFromSpeed 4 false true ≠
    Critical.thresholdFromSpeed 4 false false
  accuracyBoundary : Accuracy.hits 255 255 ≠ Accuracy.hitsInclusive 255 255
  criticalBoundary : Critical.occurs 255 255 ≠ Critical.occursInclusive 255 255
  substitute : Effects.Substitute.use false 25 100 = .created 0 25 ∧
    intendedSubstitute 25 100 = .insufficientHp
  healing : Effects.Healing.checkFails 45 300 = true ∧ (45 : UInt16) ≠ 300
  cooltrainer :
    let context : TrainerAI.Context :=
      { currentHp := 5, maxHp := 100, hasSwitchReserve := false }
    TrainerAI.cooltrainerF 255 context = .useItem .hyperPotion ∧
      intendedCooltrainerF 255 context = .normalMove
  blaine :
    let context : TrainerAI.Context :=
      { currentHp := 100, maxHp := 100, hasSwitchReserve := false }
    TrainerAI.blaine 0 context = .useItem .superPotion ∧
      intendedBlaine 0 context = .normalMove
  psywave : ∃ seed playerFinal enemyFinal,
    LinkBugs.PsywaveResolves .playerAttack 75 seed 5 playerFinal [0, 5] ∧
    LinkBugs.PsywaveResolves .enemyAttack 75 seed 0 enemyFinal [0] ∧
    playerFinal.index = 2 ∧ enemyFinal.index = 1
  bide :
    let damage : LinkBugs.BideAccumulated := { high := 1, low := 44 }
    LinkBugs.clearAfterEnemyFaints damage ≠ LinkBugs.clearAfterPlayerFaints damage
  screen : DamageStats.resolve 300 512 true =
    .divisionFreeze { attack := 75, defense := 0 }
  lowDefense : DamageStats.resolve 256 3 false =
    .divisionFreeze { attack := 64, defense := 0 }
  equalStages : Accuracy.calcHitChance 255 8 8 = 252
  badgeScreen : DamageStats.badgeScreenPipeline 300 458 1 true =
    .ready { attack := 75, defense := 1 }

/-- Every externally enumerated bug family has an explicit project-owned witness. -/
theorem all_gen1_bug_occurrences : OccurrenceCertificate :=
  { focusEnergy := focus_energy_occurs
    accuracyBoundary := accuracy_boundary_occurs
    criticalBoundary := critical_boundary_occurs
    substitute := substitute_zero_user_hp_occurs
    healing := healing_false_failure_occurs
    cooltrainer := cooltrainer_random_gate_bug_occurs
    blaine := by native_decide
    psywave := psywave_link_desync_occurs
    bide := bide_link_desync_occurs
    screen := screen_overflow_occurs.1
    lowDefense := low_defense_freeze_occurs
    equalStages := equal_stages_fail_to_cancel_occurs.1
    badgeScreen := badge_screen_catastrophe_occurs.2 }

end Battle.BugWitnesses
