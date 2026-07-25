/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Basic

/-!
# Generation-I hit chance

Clean-room transcription of `CalcHitChance` and the final `MoveHitTest`
comparison. Ratios are applied accuracy first and inverted evasion second, with
an integer division and minimum-one correction after each pass, then a 255 cap.
-/

namespace Battle.Accuracy

structure StageRatio where
  numerator : Nat
  denominator : Nat
  deriving Repr, DecidableEq, BEq

/-- `StatModifierRatios`, stages -6 through +6. -/
def stageRatios : Array StageRatio := #[
  ⟨25, 100⟩, ⟨28, 100⟩, ⟨33, 100⟩, ⟨40, 100⟩,
  ⟨50, 100⟩, ⟨66, 100⟩, ⟨1, 1⟩, ⟨15, 10⟩,
  ⟨2, 1⟩, ⟨25, 10⟩, ⟨3, 1⟩, ⟨35, 10⟩, ⟨4, 1⟩
]

/-- RAM stage values are valid exactly in `[1,13]`, with 7 neutral. -/
def ValidStage (stage : UInt8) : Prop := 1 ≤ stage.toNat ∧ stage.toNat ≤ 13

private def ratioAtStage (stage : UInt8) : StageRatio :=
  stageRatios.getD (stage.toNat - 1) ⟨1, 1⟩

/-- One ROM multiply/divide pass, including its minimum-one correction. -/
def applyRatio (chance : Nat) (ratio : StageRatio) : Nat :=
  let result := chance * ratio.numerator / ratio.denominator
  if result == 0 then 1 else result

/-- Effective accuracy. Evasion is reflected around neutral by `14-stage`. -/
def calcHitChance (moveAccuracy accuracyStage evasionStage : UInt8) : UInt8 :=
  let accuracyRatio := ratioAtStage accuracyStage
  let invertedEvasion := (14 - evasionStage.toNat).toUInt8
  let evasionRatio := ratioAtStage invertedEvasion
  let afterAccuracy := applyRatio moveAccuracy.toNat accuracyRatio
  let afterEvasion := applyRatio afterAccuracy evasionRatio
  (min afterEvasion 255).toUInt8

/-- Final `cp b; jr nc`: strictly less than effective accuracy. -/
def hits (effectiveAccuracy random : UInt8) : Bool := random < effectiveAccuracy

/-- Inclusive comparison used only to characterize the boundary bug. -/
def hitsInclusive (effectiveAccuracy random : UInt8) : Bool := random ≤ effectiveAccuracy

/-! ## Universal compatibility theorems -/

/-- The strict/inclusive models differ exactly at equality, for every pair of
bytes, not only `$ff`. -/
theorem strict_boundary_iff (effectiveAccuracy random : UInt8) :
    hits effectiveAccuracy random ≠ hitsInclusive effectiveAccuracy random ↔
      random = effectiveAccuracy := by
  have checked :
      (List.range 256).all (fun a =>
        (List.range 256).all (fun r => decide
          (hits a.toUInt8 r.toUInt8 ≠ hitsInclusive a.toUInt8 r.toUInt8 ↔
            r.toUInt8 = a.toUInt8))) = true := by
    native_decide
  have atAccuracy := (List.all_eq_true.mp checked) effectiveAccuracy.toNat
    (List.mem_range.mpr (UInt8.toNat_lt effectiveAccuracy))
  have atRandom := (List.all_eq_true.mp atAccuracy) random.toNat
    (List.mem_range.mpr (UInt8.toNat_lt random))
  have round (value : UInt8) : value.toNat.toUInt8 = value := by
    apply UInt8.toNat.inj
    simp
  simpa only [round] using of_decide_eq_true atRandom

/-- Neutral stages are the identity except that the ROM's per-pass minimum
raises a malformed zero accuracy to one. -/
theorem neutral_stages_exact (moveAccuracy : UInt8) :
    calcHitChance moveAccuracy 7 7 = if moveAccuracy == 0 then 1 else moveAccuracy := by
  have checked :
      (List.range 256).all (fun n => decide
        (calcHitChance n.toUInt8 7 7 =
          if n.toUInt8 == 0 then 1 else n.toUInt8)) = true := by
    native_decide
  have atAccuracy := (List.all_eq_true.mp checked) moveAccuracy.toNat
    (List.mem_range.mpr (UInt8.toNat_lt moveAccuracy))
  have round : moveAccuracy.toNat.toUInt8 = moveAccuracy := by
    apply UInt8.toNat.inj
    simp
  simpa only [round] using of_decide_eq_true atAccuracy

/-- Neutral raw accuracy zero is raised to one by the two minimum-one passes,
so exactly random byte zero hits. -/
theorem zero_accuracy_hits_only_zero (random : UInt8) :
    hits (calcHitChance 0 7 7) random = (random == 0) := by
  have exhaustive : (List.range 256).all (fun value =>
      hits (calcHitChance 0 7 7) value.toUInt8 == (value.toUInt8 == 0)) = true := by
    native_decide
  have item := (List.all_eq_true.mp exhaustive) random.toNat
    (List.mem_range.mpr (UInt8.toNat_lt random))
  have round : random.toNat.toUInt8 = random := by
    apply UInt8.toNat.inj
    simp
  apply LawfulBEq.eq_of_beq
  simpa only [round] using item

/-- `$ff` effective accuracy still misses on raw `$ff`. -/
theorem one_in_256_witness :
    hits 255 255 = false ∧ hitsInclusive 255 255 = true := by
  native_decide

/-- The complete equal-stage profile for a 255-accuracy move. The array order is
stage 0 through +6 (`RAM 7` through `RAM 13`). -/
def equalStageProfile : Array UInt8 :=
  (Array.range 7).map fun offset =>
    let stage := (offset + 7).toUInt8
    calcHitChance 255 stage stage

theorem equal_stage_profile_exact :
    equalStageProfile = #[255, 252, 255, 254, 252, 249, 255] := by
  native_decide

/-- Equal stages fail to cancel at +1, +3, +4, and +5. This is an exact
classification over all seven canonical nonnegative equal-stage cases. -/
theorem equal_stage_noncancellation_exact :
    (Array.range 7).filter (fun offset =>
      calcHitChance 255 (offset + 7).toUInt8 (offset + 7).toUInt8 != 255) =
      #[1, 3, 4, 5] := by
  native_decide

/-- Accuracy-first and evasion-first application are observably different. -/
def calcHitChanceReversed (moveAccuracy accuracyStage evasionStage : UInt8) : UInt8 :=
  let accuracyRatio := ratioAtStage accuracyStage
  let invertedEvasion := (14 - evasionStage.toNat).toUInt8
  let evasionRatio := ratioAtStage invertedEvasion
  let afterEvasion := applyRatio moveAccuracy.toNat evasionRatio
  let afterAccuracy := applyRatio afterEvasion accuracyRatio
  (min afterAccuracy 255).toUInt8

theorem order_is_observable :
    calcHitChance 255 12 12 = 249 ∧
    calcHitChanceReversed 255 12 12 = 248 := by
  native_decide

#guard stageRatios.size == 13
#guard calcHitChance 255 7 7 == 255
#guard calcHitChance 255 8 8 == 252
#guard calcHitChance 242 12 12 == 237

end Battle.Accuracy
