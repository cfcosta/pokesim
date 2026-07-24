/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Rng

/-!
# Link-visible Psywave and Bide asymmetries

These are relational semantics, not fuelled approximations. `PsywaveResolves`
contains exactly finite accepting executions; an infinite rejection path has no
finite derivation and remains divergence. Raw draws are retained in the witness.
-/

namespace Battle.LinkBugs

inductive PsywavePerspective where
  | playerAttack
  | enemyAttack
  deriving Repr, DecidableEq, BEq

/-- Player rejects zero and `≥ bound`; enemy rejects only `≥ bound`. -/
def psywaveAccepts (perspective : PsywavePerspective) (bound raw : UInt8) : Bool :=
  raw < bound && match perspective with
    | .playerAttack => raw != 0
    | .enemyAttack => true

/-- Finite accepting executions of the canonical rejection loop. -/
inductive PsywaveResolves (perspective : PsywavePerspective) (bound : UInt8) :
    Rng.LinkRng → UInt8 → Rng.LinkRng → List UInt8 → Prop where
  | accept (rng : Rng.LinkRng)
      (accepted : psywaveAccepts perspective bound rng.next.1 = true) :
      PsywaveResolves perspective bound rng rng.next.1 rng.next.2 [rng.next.1]
  | reject (rng : Rng.LinkRng)
      (rejected : psywaveAccepts perspective bound rng.next.1 = false)
      {damage final trace}
      (tail : PsywaveResolves perspective bound rng.next.2 damage final trace) :
      PsywaveResolves perspective bound rng damage final (rng.next.1 :: trace)

/-- Player-side Psywave can never resolve to zero. -/
theorem player_damage_nonzero {bound rng damage final trace}
    (resolution : PsywaveResolves .playerAttack bound rng damage final trace) :
    damage ≠ 0 := by
  induction resolution with
  | accept rng accepted =>
      simp [psywaveAccepts] at accepted
      exact accepted.2
  | reject rng rejected tail ih => exact ih

private def psywaveDesyncSeed : Rng.LinkRng :=
  { list := #[0, 5, 42, 100, 7, 9, 11, 13, 15, 17], index := 0 }

private theorem playerPsywaveWitness :
    PsywaveResolves .playerAttack 75 psywaveDesyncSeed 5
      psywaveDesyncSeed.next.2.next.2 [0, 5] := by
  apply PsywaveResolves.reject
  · native_decide
  · apply PsywaveResolves.accept
    native_decide

private theorem enemyPsywaveWitness :
    PsywaveResolves .enemyAttack 75 psywaveDesyncSeed 0
      psywaveDesyncSeed.next.2 [0] := by
  apply PsywaveResolves.accept
  native_decide

/-- The same synchronized seed admits the canonical two-draw player result and
one-draw enemy result, establishing both damage and cursor divergence. -/
theorem psywave_link_desync :
    PsywaveResolves .playerAttack 75 psywaveDesyncSeed 5
        psywaveDesyncSeed.next.2.next.2 [0, 5] ∧
    PsywaveResolves .enemyAttack 75 psywaveDesyncSeed 0
        psywaveDesyncSeed.next.2 [0] ∧
    psywaveDesyncSeed.next.2.next.2.index = 2 ∧
    psywaveDesyncSeed.next.2.index = 1 := by
  exact ⟨playerPsywaveWitness, enemyPsywaveWitness, by native_decide, by native_decide⟩

/-- Public existential form of the relational desync, independent of the private
regression seed name. -/
theorem psywave_link_desync_exists :
    ∃ seed playerFinal enemyFinal,
      PsywaveResolves .playerAttack 75 seed 5 playerFinal [0, 5] ∧
      PsywaveResolves .enemyAttack 75 seed 0 enemyFinal [0] ∧
      playerFinal.index = 2 ∧ enemyFinal.index = 1 := by
  exact ⟨psywaveDesyncSeed, psywaveDesyncSeed.next.2.next.2,
    psywaveDesyncSeed.next.2, playerPsywaveWitness, enemyPsywaveWitness,
    by native_decide, by native_decide⟩

/-- A nonzero first byte below the bound resolves identically on both sides. -/
theorem psywave_sync_on_direct_nonzero :
    let seed : Rng.LinkRng :=
      { list := #[42, 5, 100, 7, 9, 11, 13, 15, 17, 19], index := 0 }
    PsywaveResolves .playerAttack 75 seed 42 seed.next.2 [42] ∧
    PsywaveResolves .enemyAttack 75 seed 42 seed.next.2 [42] := by
  constructor <;> apply PsywaveResolves.accept <;> native_decide

/-! ## Bide accumulated-damage clear -/

structure BideAccumulated where
  high : UInt8
  low : UInt8
  deriving Repr, DecidableEq, BEq

/-- `FaintEnemyPokemon`: only the high byte is cleared. -/
def clearAfterEnemyFaints (damage : BideAccumulated) : BideAccumulated :=
  { damage with high := 0 }

/-- `RemoveFaintedPlayerMon`: both bytes are cleared. -/
def clearAfterPlayerFaints (_damage : BideAccumulated) : BideAccumulated :=
  { high := 0, low := 0 }

/-- Link counterparts disagree exactly when the retained low byte is nonzero. -/
theorem bide_desync_iff (damage : BideAccumulated) :
    clearAfterEnemyFaints damage ≠ clearAfterPlayerFaints damage ↔ damage.low ≠ 0 := by
  cases damage
  simp [clearAfterEnemyFaints, clearAfterPlayerFaints]

/-- Numeric value after the buggy clear is exactly the old low byte. -/
def BideAccumulated.toNat (damage : BideAccumulated) : Nat :=
  damage.high.toNat * 256 + damage.low.toNat

theorem bide_buggy_clear_is_low_byte (damage : BideAccumulated) :
    (clearAfterEnemyFaints damage).toNat = damage.low.toNat := by
  simp [clearAfterEnemyFaints, BideAccumulated.toNat]

/-- Concrete canonical-width witness. -/
theorem bide_300_desync :
    let damage : BideAccumulated := { high := 1, low := 44 }
    (clearAfterEnemyFaints damage).toNat = 44 ∧
    (clearAfterPlayerFaints damage).toNat = 0 ∧
    clearAfterEnemyFaints damage ≠ clearAfterPlayerFaints damage := by
  native_decide

/-- Pair result used by full link faint handling. -/
def clearAcrossLink (damage : BideAccumulated) : BideAccumulated × BideAccumulated :=
  (clearAfterEnemyFaints damage, clearAfterPlayerFaints damage)

@[simp] theorem clearAcrossLink_fst (damage : BideAccumulated) :
    (clearAcrossLink damage).1 = clearAfterEnemyFaints damage := rfl

@[simp] theorem clearAcrossLink_snd (damage : BideAccumulated) :
    (clearAcrossLink damage).2 = clearAfterPlayerFaints damage := rfl

end Battle.LinkBugs
