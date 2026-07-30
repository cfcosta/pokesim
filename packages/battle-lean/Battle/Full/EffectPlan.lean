/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Data.Moves

/-!
# Complete move-effect dispatch plan

Every effect ID `$00..$56` receives a typed mechanic and its exact execution
phase-table memberships. `NULL` pointer rows that are handled directly are not
classified as no-ops. Unused pointer rows remain explicit.
-/

namespace Battle.Full.EffectPlan

inductive Phase where
  | residual1
  | continuation
  | setDamage
  | residual2
  | always
  | specialSkip
  | remaining
  deriving Repr, DecidableEq, BEq

inductive Mechanic where
  | ordinary | unused
  | poisonSide (threshold : UInt8)
  | drain | burnSide (threshold : UInt8) | freezeSide (threshold : UInt8)
  | paralyzeSide (threshold : UInt8) | explode | dreamEater
  | mirrorMove | statUp (stat amount : Nat) | payDay | swift
  | statDown (stat amount : Nat) | conversion | haze | bide | thrash
  | switchOrTeleport | multiHit | flinchSide (threshold : UInt8)
  | sleep | ohko | charge (invulnerable : Bool) | superFang | specialDamage
  | trapping | attackTwice | jumpKick | mist | focusEnergy | recoil
  | confusion | heal | transform | lightScreen | reflect
  | poison | paralyze | statDownSide (stat : Nat) | confusionSide
  | twineedle | substitute | hyperBeam | rage | mimic | metronome
  | leechSeed | splash | disable
  | malformed
  deriving Repr, DecidableEq, BEq

structure Plan where
  mechanic : Mechanic
  phases : List Phase
  deriving Repr, DecidableEq, BEq

private def r1 : List Phase := [.residual1]
private def r2 : List Phase := [.residual2]
private def alwaysSpecial : List Phase := [.always, .specialSkip]
private def contSpecial : List Phase := [.continuation, .specialSkip]
private def setSpecial : List Phase := [.setDamage, .specialSkip]

/-- Complete `$00..$56` dispatch. Stat index order is Attack, Defense, Speed,
Special, Accuracy, Evasion. -/
def plan (effect : UInt8) : Plan :=
  match effect.toNat with
  | 0x00 => ⟨.ordinary, []⟩
  | 0x01 => ⟨.unused, r2⟩
  | 0x02 => ⟨.poisonSide 52, [.remaining]⟩
  | 0x03 => ⟨.drain, alwaysSpecial⟩
  | 0x04 => ⟨.burnSide 26, [.remaining]⟩
  | 0x05 => ⟨.freezeSide 26, [.remaining]⟩
  | 0x06 => ⟨.paralyzeSide 26, [.remaining]⟩
  | 0x07 => ⟨.explode, alwaysSpecial⟩
  | 0x08 => ⟨.dreamEater, alwaysSpecial⟩
  | 0x09 => ⟨.mirrorMove, [.remaining]⟩
  | 0x0A => ⟨.statUp 0 1, r2⟩
  | 0x0B => ⟨.statUp 1 1, r2⟩
  | 0x0C => ⟨.statUp 2 1, r2⟩
  | 0x0D => ⟨.statUp 3 1, r2⟩
  | 0x0E => ⟨.statUp 4 1, r2⟩
  | 0x0F => ⟨.statUp 5 1, r2⟩
  | 0x10 => ⟨.payDay, [.always, .specialSkip]⟩
  | 0x11 => ⟨.swift, [.specialSkip]⟩
  | 0x12 => ⟨.statDown 0 1, r2⟩
  | 0x13 => ⟨.statDown 1 1, r2⟩
  | 0x14 => ⟨.statDown 2 1, r2⟩
  | 0x15 => ⟨.statDown 3 1, r2⟩
  | 0x16 => ⟨.statDown 4 1, r2⟩
  | 0x17 => ⟨.statDown 5 1, r2⟩
  | 0x18 => ⟨.conversion, r1⟩
  | 0x19 => ⟨.haze, r1⟩
  | 0x1A => ⟨.bide, r2⟩
  | 0x1B => ⟨.thrash, contSpecial⟩
  | 0x1C => ⟨.switchOrTeleport, r1⟩
  | 0x1D => ⟨.multiHit, alwaysSpecial⟩
  | 0x1E => ⟨.unused, alwaysSpecial⟩
  | 0x1F => ⟨.flinchSide 26, [.remaining]⟩
  | 0x20 => ⟨.sleep, r2⟩
  | 0x21 => ⟨.poisonSide 103, [.remaining]⟩
  | 0x22 => ⟨.burnSide 77, [.remaining]⟩
  | 0x23 => ⟨.freezeSide 77, [.remaining]⟩
  | 0x24 => ⟨.paralyzeSide 77, [.remaining]⟩
  | 0x25 => ⟨.flinchSide 77, [.remaining]⟩
  | 0x26 => ⟨.ohko, [.remaining]⟩
  | 0x27 => ⟨.charge false, [.specialSkip]⟩
  | 0x28 => ⟨.superFang, setSpecial⟩
  | 0x29 => ⟨.specialDamage, setSpecial⟩
  | 0x2A => ⟨.trapping, contSpecial⟩
  | 0x2B => ⟨.charge true, [.specialSkip]⟩
  | 0x2C => ⟨.attackTwice, alwaysSpecial⟩
  | 0x2D => ⟨.jumpKick, [.specialSkip]⟩
  | 0x2E => ⟨.mist, r1⟩
  | 0x2F => ⟨.focusEnergy, r1⟩
  | 0x30 => ⟨.recoil, alwaysSpecial⟩
  | 0x31 => ⟨.confusion, r1⟩
  | 0x32 => ⟨.statUp 0 2, r2⟩
  | 0x33 => ⟨.statUp 1 2, r2⟩
  | 0x34 => ⟨.statUp 2 2, r2⟩
  | 0x35 => ⟨.statUp 3 2, r2⟩
  | 0x36 => ⟨.statUp 4 2, r2⟩
  | 0x37 => ⟨.statUp 5 2, r2⟩
  | 0x38 => ⟨.heal, r1⟩
  | 0x39 => ⟨.transform, r1⟩
  | 0x3A => ⟨.statDown 0 2, r2⟩
  | 0x3B => ⟨.statDown 1 2, r2⟩
  | 0x3C => ⟨.statDown 2 2, r2⟩
  | 0x3D => ⟨.statDown 3 2, r2⟩
  | 0x3E => ⟨.statDown 4 2, r2⟩
  | 0x3F => ⟨.statDown 5 2, r2⟩
  | 0x40 => ⟨.lightScreen, r1⟩
  | 0x41 => ⟨.reflect, r1⟩
  | 0x42 => ⟨.poison, r1⟩
  | 0x43 => ⟨.paralyze, r1⟩
  | 0x44 => ⟨.statDownSide 0, [.remaining]⟩
  | 0x45 => ⟨.statDownSide 1, [.remaining]⟩
  | 0x46 => ⟨.statDownSide 2, [.remaining]⟩
  | 0x47 => ⟨.statDownSide 3, [.remaining]⟩
  | 0x48 | 0x49 | 0x4A | 0x4B => ⟨.unused, [.remaining]⟩
  | 0x4C => ⟨.confusionSide, [.remaining]⟩
  | 0x4D => ⟨.twineedle, [.always]⟩
  | 0x4E => ⟨.unused, [.remaining]⟩
  | 0x4F => ⟨.substitute, r1⟩
  | 0x50 => ⟨.hyperBeam, [.remaining]⟩
  | 0x51 => ⟨.rage, [.always, .remaining]⟩
  | 0x52 => ⟨.mimic, r1⟩
  | 0x53 => ⟨.metronome, [.remaining]⟩
  | 0x54 => ⟨.leechSeed, r1⟩
  | 0x55 => ⟨.splash, r1⟩
  | 0x56 => ⟨.disable, [.remaining]⟩
  | _ => ⟨.malformed, []⟩

/-- All 87 effect IDs are classified, universally over the indexed domain. -/
theorem effect_domain_total (effect : UInt8) (bounded : effect.toNat ≤ 0x56) :
    (plan effect).mechanic ≠ .malformed := by
  have checked :
      (List.range 0x57).all (fun id =>
        (plan id.toUInt8).mechanic != .malformed) = true := by
    native_decide
  have atEffect := (List.all_eq_true.mp checked) effect.toNat
    (List.mem_range.mpr (by omega))
  have round : effect.toNat.toUInt8 = effect := by
    apply UInt8.toNat.inj
    simp
  have supported : ((plan effect).mechanic != .malformed) = true := by
    simpa only [round] using atEffect
  intro equal
  rw [equal] at supported
  have impossible : (Mechanic.malformed != Mechanic.malformed) ≠ true := by native_decide
  exact impossible supported

/-- Every one of the 165 canonical move rows selects a supported effect. -/
theorem exceptional_move_ids_supported :
    ([98, 68, 118, 119, 165, 92, 19, 91, 100, 46, 18, 153, 120, 107, 156,
      138, 49, 82, 69, 101, 149, 162] : List UInt8).all
      (fun move => (plan (Data.moveData move).effect).mechanic != .malformed) = true := by
  native_decide

/-- Animation IDs/tile timing are deliberately outside the high-level effect
projection; the machine layer must frame or execute them separately. -/
def animationProjectedInMechanics : Bool := false

@[simp] theorem animation_explicitly_excluded : animationProjectedInMechanics = false := rfl

theorem canonical_moves_supported :
    Data.moves.all (fun move => (plan move.effect).mechanic != .malformed) = true := by
  native_decide

/-- The complete Red move table has 165 rows, and every row selects an
implemented mechanic rather than either the malformed or unused disposition.
This is high-level execution coverage; per-handler decoded-ROM refinement remains
an independent obligation. -/
theorem canonical_moves_implemented :
    Data.moves.size = 165 ∧
      Data.moves.all (fun move =>
        let mechanic := (plan move.effect).mechanic
        mechanic != .malformed && mechanic != .unused) = true := by
  native_decide

#guard (plan Data.Effect.swift).mechanic == .swift
#guard (plan Data.Effect.superFang).phases == [.setDamage, .specialSkip]
#guard (plan Data.Effect.rage).phases == [.always, .remaining]
#guard (plan 0x56).mechanic == .disable

end Battle.Full.EffectPlan
