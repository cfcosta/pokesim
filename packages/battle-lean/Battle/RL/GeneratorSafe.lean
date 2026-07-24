/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.RL.Generator

/-!
# Generator safety — every generated mon is legal

The guarantee behind `Battle/RL/Generator.lean`: `genMon` cannot emit a mon the
battle engine would reject. It splits along the two natures of `battleValid`:

## Numeric / structural floor — a proved theorem, unconditional

The array widths, level range, per-stat `MAX_STAT_VALUE` clamp, and `hp ≤ maxHp`
hold for **every** species entry and **every** entropy input, with no hypotheses —
they follow structurally from `padTo` (always `NUM_MOVES` wide), `clampLevel`
(pinned to `1..MAX_LEVEL`), and `calcStat` (clamped to `MAX_STAT_VALUE`). This is
the half a `CalcStat` regression would break, so it is where a symbolic proof
earns its keep: the input domain is infinite (`UInt8³ × UInt16 × Nat`), so no
finite check could stand in for it. `genMon_numeric_valid` bundles all ten facts.

## Moveset structure — exhaustive over the reachable space

`firstMoveReal`, `movesPacked`, `movesDistinct` (and thus full `monLegal`) depend
only on the chosen `SpeciesEntry` and the clamped move count `k = max 1 (min (min
moveCount NUM_MOVES) pool.size)`. `k` saturates at `min NUM_MOVES pool.size ≤ 4`,
so ranging `moveCount` over `0..5` realises **every** moveset any call can
produce, for each of the **151 real** `pokedex` entries — the guards below are
therefore exhaustive over the entire reachable moveset space, not a sample. (A
fully symbolic version would need custom induction over `noRepeats`/`dropWhile`
for an *arbitrary* well-formed entry; with the real table finite, enumeration is
the honest, complete tool. `Battle.Rom.Tables` certifies `Battle/Data/*` against
the canonical ROM, so these same guards cover the certified table.)

`maxLevel`/`numMoves`/`maxStatValue` are the `Battle.RL` / `Battle.Wram` mirrors
of `MAX_LEVEL`, `NUM_MOVES`, `MAX_STAT_VALUE`.
-/

namespace Battle.RL

open Battle.Wram (numMoves maxStatValue)

/-! ## `Nat → UIntN → Nat` roundtrips (no wraparound below the width) -/

/-- `n.toUInt8` reads back as `n` when `n` fits in a byte. -/
theorem toUInt8_rt {n : Nat} (h : n < 256) : n.toUInt8.toNat = n :=
  UInt8.toNat_ofNat_of_lt' h

/-- `n.toUInt16` reads back as `n` when `n` fits in a 16-bit word. -/
theorem toUInt16_rt {n : Nat} (h : n < 65536) : n.toUInt16.toNat = n := by
  simp [Nat.toUInt16]; omega

/-! ## `calcStat` / `clampLevel` / `padTo` bounds -/

/-- The `MAX_STAT_VALUE` clamp really bounds the result: `min raw 999` never
    exceeds `999` after the `toUInt16` round-trip. -/
theorem min_clamp_le (raw : Nat) : (min raw maxStatValue).toUInt16.toNat ≤ maxStatValue := by
  have hmax : maxStatValue = 999 := rfl
  rw [toUInt16_rt (by omega)]; omega

/-- Every stat `calcStat` produces is `≤ MAX_STAT_VALUE` (the `.overflow` cap,
    `home/move_mon.asm:214-227`), for any base/DV/level/stat-exp. -/
theorem calcStat_le (base dv level : UInt8) (se : UInt16) (isHP : Bool) :
    (calcStat base dv level se isHP).toNat ≤ maxStatValue := by
  simp only [calcStat]; exact min_clamp_le _

/-- `clampLevel` never underflows `1`. -/
theorem clampLevel_ge (l : UInt8) : 1 ≤ (clampLevel l).toNat := by
  have hml : maxLevel = 100 := rfl
  have e : (clampLevel l).toNat = max 1 (min maxLevel l.toNat) := by
    simp only [clampLevel]; rw [toUInt8_rt (by omega)]
  omega

/-- `clampLevel` never exceeds `MAX_LEVEL`. -/
theorem clampLevel_le (l : UInt8) : (clampLevel l).toNat ≤ maxLevel := by
  have hml : maxLevel = 100 := rfl
  have e : (clampLevel l).toNat = max 1 (min maxLevel l.toNat) := by
    simp only [clampLevel]; rw [toUInt8_rt (by omega)]
  omega

/-- `padTo n` yields exactly `n` entries — truncating or right-padding as needed. -/
theorem padTo_size {α} (n : Nat) (f : α) (xs : Array α) : (padTo n f xs).size = n := by
  simp [padTo, Array.size_append, Array.size_extract]; omega

/-! ## `genMon` numeric safety (unconditional — any entry, any entropy) -/

variable (e : SpeciesEntry) (level a d s c : UInt8) (mc : Nat)

theorem genMon_moves_size : (genMon e level a d s c mc).moves.size = numMoves := by
  simp only [genMon]; exact padTo_size numMoves 0 _

theorem genMon_pp_size : (genMon e level a d s c mc).pp.size = numMoves := by
  simp only [genMon]; exact padTo_size numMoves 0 _

theorem genMon_level_ge : 1 ≤ (genMon e level a d s c mc).level.toNat := by
  simp only [genMon]; exact clampLevel_ge level

theorem genMon_level_le : (genMon e level a d s c mc).level.toNat ≤ maxLevel := by
  simp only [genMon]; exact clampLevel_le level

theorem genMon_maxHp_le : (genMon e level a d s c mc).maxHp.toNat ≤ maxStatValue := by
  simp only [genMon]; exact calcStat_le _ _ _ _ _

theorem genMon_attack_le : (genMon e level a d s c mc).attack.toNat ≤ maxStatValue := by
  simp only [genMon]; exact calcStat_le _ _ _ _ _

theorem genMon_defense_le : (genMon e level a d s c mc).defense.toNat ≤ maxStatValue := by
  simp only [genMon]; exact calcStat_le _ _ _ _ _

theorem genMon_speed_le : (genMon e level a d s c mc).speed.toNat ≤ maxStatValue := by
  simp only [genMon]; exact calcStat_le _ _ _ _ _

theorem genMon_special_le : (genMon e level a d s c mc).special.toNat ≤ maxStatValue := by
  simp only [genMon]; exact calcStat_le _ _ _ _ _

/-- Current HP starts at max HP, so `hp ≤ maxHp` holds trivially. -/
theorem genMon_hp_le_maxHp :
    (genMon e level a d s c mc).hp.toNat ≤ (genMon e level a d s c mc).maxHp.toNat := by
  simp only [genMon]; omega

/-- **Numeric safety.** For any species entry and any entropy, a generated mon
    satisfies every non-moveset conjunct of `battleValid`: both arrays are
    `NUM_MOVES` wide, its level is in `1..MAX_LEVEL`, current HP does not exceed
    max HP, and every stat is `≤ MAX_STAT_VALUE`. The generator can never emit a
    mon the engine rejects on numeric or structural-width grounds. -/
theorem genMon_numeric_valid :
    (genMon e level a d s c mc).moves.size = numMoves ∧
    (genMon e level a d s c mc).pp.size = numMoves ∧
    1 ≤ (genMon e level a d s c mc).level.toNat ∧
    (genMon e level a d s c mc).level.toNat ≤ maxLevel ∧
    (genMon e level a d s c mc).hp.toNat ≤ (genMon e level a d s c mc).maxHp.toNat ∧
    (genMon e level a d s c mc).maxHp.toNat ≤ maxStatValue ∧
    (genMon e level a d s c mc).attack.toNat ≤ maxStatValue ∧
    (genMon e level a d s c mc).defense.toNat ≤ maxStatValue ∧
    (genMon e level a d s c mc).speed.toNat ≤ maxStatValue ∧
    (genMon e level a d s c mc).special.toNat ≤ maxStatValue :=
  ⟨genMon_moves_size e level a d s c mc, genMon_pp_size e level a d s c mc,
   genMon_level_ge e level a d s c mc, genMon_level_le e level a d s c mc,
   genMon_hp_le_maxHp e level a d s c mc, genMon_maxHp_le e level a d s c mc,
   genMon_attack_le e level a d s c mc, genMon_defense_le e level a d s c mc,
   genMon_speed_le e level a d s c mc, genMon_special_le e level a d s c mc⟩

/-! ## Moveset structure + full legality — exhaustive over the reachable space

`moveCounts` ranges over every value that yields a distinct clamped `k` (0 and 1
both give `k = 1`; anything `≥ pool.size` saturates), so these guards realise
every reachable moveset for every one of the 151 real species, at the level/DV
corners that also stress `calcStat`. A failing `#guard` fails the build. -/

/-- `0..5` — covers every clamp outcome of `k` for a pool of any size `≥ 1`
    (`k` caps at `min NUM_MOVES pool.size ≤ 4`, so `moveCount ≥ 5` adds nothing). -/
private def moveCounts : List Nat := [0, 1, 2, 3, 4, 5]

/-- The three moveset-structure predicates hold for every generated mon. -/
private def movesetOk (m : MonState) : Bool :=
  firstMoveReal m && movesPacked m && movesDistinct m

-- Full `battleValid` (numeric conjuncts proved above; moveset conjuncts here) on
-- every reachable moveset, at max and min level/DV corners.
#guard pokedex.all (fun e => moveCounts.all (fun mc => battleValid (genMon e 100 15 15 15 15 mc)))
#guard pokedex.all (fun e => moveCounts.all (fun mc => battleValid (genMon e 1 0 0 0 0 mc)))

-- The moveset structure specifically (packed, distinct, non-empty first slot).
#guard pokedex.all (fun e => moveCounts.all (fun mc => movesetOk (genMon e 50 7 7 7 7 mc)))

-- Full obtainability legality at all three modes, over the reachable space.
#guard pokedex.all (fun e => moveCounts.all (fun mc => monLegal genDex .canonical (genMon e 100 15 15 15 15 mc)))
#guard pokedex.all (fun e => moveCounts.all (fun mc => monLegal genDex .canonical (genMon e 1 0 0 0 0 mc)))
#guard pokedex.all (fun e => moveCounts.all (fun mc => monLegal genDex .movesetOpen (genMon e 73 3 11 15 4 mc)))
#guard pokedex.all (fun e => moveCounts.all (fun mc => monLegal genDex .rangeOnly (genMon e 50 9 9 9 9 mc)))

-- A generated party (drawn across the dex) is a legal team at every mode.
private def probeTeam : Team :=
  genTeam ((List.range pokedex.size).toArray.map (fun i =>
    ({ entry := entryOf i, level := 40, atkDV := 12, defDV := 3, spdDV := 15, spcDV := 0,
       moveCount := i } : GenChoice))) |>.extract 0 maxPartySize

#guard probeTeam.size == maxPartySize
#guard teamLegal genDex .rangeOnly probeTeam
#guard teamLegal genDex .movesetOpen probeTeam
#guard teamLegal genDex .canonical probeTeam

end Battle.RL
