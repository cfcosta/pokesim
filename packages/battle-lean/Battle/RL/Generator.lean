/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.RL.LegalTeam
import Battle.Data.Moves

/-!
# Team generator — byte-faithful `CalcStat` and legal mon/team synthesis

Builds the random-but-game-legal parties the RL loop fights. A generated mon is
`Battle.RL.monLegal` **by construction**; the safety proof
(`Battle/RL/GeneratorSafe.lean`, task #21) discharges that as a theorem. This
module is deterministic-from-parameters — every random choice (species, level,
DVs, how many moves) is an explicit argument, exactly how the rest of the model
threads entropy — so an RNG wrapper sits *above* it, never inside.

## `calcStat` is a 1:1 transcription of `CalcStat` (`home/move_mon.asm:54`)

The Gen-1 stat, for base value `Base`, DV `DV` (0-15), `Level`, and stat
experience `statExp`:

```
core   = floor( ((Base + DV) * 2 + floor(ceilSqrt(statExp) / 4)) * Level / 100 )
non-HP = min(core + 5, MAX_STAT_VALUE)
HP     = min(core + Level + 10, MAX_STAT_VALUE)
```

* `ceilSqrt(statExp)` is the ROM's `.statExpLoop`: the smallest `b ≥ 1` with
  `b² ≥ statExp`, **saturating at 255** (the loop exits the instant `b` would hit
  `$ff`). `srl b; srl b` is the `/4`. See `ceilSqrt255` / `statExpBonus`.
* The HP DV is not stored — it is `(AtkDV&1)<<3 | (DefDV&1)<<2 | (SpdDV&1)<<1 |
  (SpcDV&1)`, the `.calcStatFromIV`-preceding block that assembles it from the
  four real DVs' low bits (`home/move_mon.asm:109-134`). See `hpDV`.
* The `+5` / `+Level`/`+10` split is `.notHPStat` vs the HP branch
  (`move_mon.asm:189-212`); the 999 clamp is `.overflow` (`:214-227`,
  `MAX_STAT_VALUE`).

Every value in the whole `UInt8³ × UInt16` domain keeps the ROM's 3-byte
`Multiply`/`Divide` inside 24 bits (max multiplicand `((255+15)*2+63) = 603`,
`× 255 = 153765 < 2²⁴`), so plain `Nat` arithmetic reproduces the hardware
exactly and only the final `min … MAX_STAT_VALUE` can bite.

## Data comes from the transcribed tables (`Battle/Data/*`)

`pokedex` is now the **full 151-species** table: `speciesEntry` reads each real
species' base stats / types / catch rate from `Battle.Data.speciesData` and its
move pool from `Battle.Data.learnset`, and `movePP` reads `Battle.Data.moveData`.
`SpeciesEntry.speciesId` is the ROM **internal** index the party structs store
(the model's `SpeciesId`), so a generated mon's `species` needs no remapping. The
tables are independently authored from the disassembly and certified against
the canonical ROM by `Battle.Rom.Tables`; this hot-path generator inherits that
certificate without executing the ROM decoder.

Move *identity* selection is still the sorted-pool prefix (a `moveCount`-length
slice of `learnset`); which specific moves — beyond count — is a future entropy
knob. Every drawn move is in the species' learnset, so a generated mon is
`monLegal Dex.gen1 .canonical` by construction.
-/

namespace Battle.RL

open Battle.Wram (numMoves maxStatValue)

/-! ## Byte-faithful stat computation (`home/move_mon.asm:54` `CalcStat`) -/

/-- `CalcStat`'s `.statExpLoop`: the smallest `b ≥ 1` with `b² ≥ n`, saturating at
    255 (the ROM increments `b` from 1 and bails the moment it reaches `$ff`, so
    only `b ∈ 1..254` are ever tested; anything larger reads back as 255). -/
def ceilSqrt255 (n : Nat) : Nat :=
  (((List.range 254).map (· + 1)).find? (fun b => n ≤ b * b)).getD 255

/-- The stat-experience contribution to the pre-scale sum: `ceilSqrt(statExp) / 4`
    (`srl b; srl b`). Zero for a freshly generated mon; maxes at `255 / 4 = 63`. -/
def statExpBonus (statExp : UInt16) : Nat := ceilSqrt255 statExp.toNat / 4

/-- `CalcStat` for a single stat: base value `base`, DV `dv` (0-15), `level`, stat
    experience `statExp`, and whether this is the HP stat (adds `Level + 10`
    instead of `5`). Clamps to `MAX_STAT_VALUE`. Byte-faithful to
    `home/move_mon.asm:54-231` across the entire input domain (see module doc). -/
def calcStat (base dv level : UInt8) (statExp : UInt16) (isHP : Bool) : UInt16 :=
  let core := ((base.toNat + dv.toNat) * 2 + statExpBonus statExp) * level.toNat / 100
  let raw := if isHP then core + level.toNat + 10 else core + 5
  (min raw maxStatValue).toUInt16

/-! ## DV (IV) helpers -/

/-- The HP DV: the low bit of each of the four stored DVs, packed high-to-low as
    Atk, Def, Spd, Spc (`home/move_mon.asm:109-134`). -/
def hpDV (atkDV defDV spdDV spcDV : UInt8) : UInt8 :=
  ((atkDV &&& 1) <<< 3) ||| ((defDV &&& 1) <<< 2) ||| ((spdDV &&& 1) <<< 1) ||| (spcDV &&& 1)

/-- Pack four DV nibbles into the stored `DVs` word: `Atk:Def` in the high byte,
    `Spd:Spc` in the low byte (the `MON_DVS` big-endian layout `CalcStat` reads).
    Each argument is masked to a nibble. -/
def packDVs (atkDV defDV spdDV spcDV : UInt16) : UInt16 :=
  ((atkDV &&& 0xF) <<< 12) ||| ((defDV &&& 0xF) <<< 8) |||
    ((spdDV &&& 0xF) <<< 4) ||| (spcDV &&& 0xF)

/-! ## Small array utility -/

/-- Fit `xs` to exactly `n` entries: truncate if longer, right-pad with `fill` if
    shorter. Used to normalise the move/PP arrays to `NUM_MOVES`. -/
def padTo {α : Type} (n : Nat) (fill : α) (xs : Array α) : Array α :=
  xs.extract 0 n ++ (List.replicate (n - xs.size) fill).toArray

/-! ## The ROM-certified data seam (`Battle/Data/*`) -/

/-- Per-species generator data, read from `Battle/Data/*`: real ROM base
    stats/types/catch rate and the species' full learnable move pool. -/
structure SpeciesEntry where
  /-- Internal species index stamped into the generated mon's `species` (the ROM
      byte the party/box/battle structs store, the model's `SpeciesId`). -/
  speciesId : SpeciesId
  baseHp : UInt8
  baseAtk : UInt8
  baseDef : UInt8
  baseSpd : UInt8
  baseSpc : UInt8
  type1 : UInt8
  type2 : UInt8
  catchRate : UInt8
  /-- The moves this species may be generated with — its full learnset pool
      (level-up ∪ TM/HM ∪ pre-evolutions): distinct, non-zero, and the sorted
      prefix is what a `k`-move mon gets. -/
  movePool : Array MoveId
  deriving Repr, DecidableEq, BEq, Inhabited

/-- Base PP by move ID, from the `Battle.Data.Moves` table (`data/moves/moves.asm`).
    `moveData 0` is the zero row, so `movePP 0 = 0`. -/
def movePP (id : MoveId) : UInt8 := (Battle.Data.moveData id).pp

/-- The generator data for an internal species index, drawn from the transcribed
    tables: base header from `Battle.Data.speciesData`, move pool from
    `Battle.Data.learnset`. -/
def speciesEntry (i : SpeciesId) : SpeciesEntry :=
  let d := Battle.Data.speciesData i
  { speciesId := i, baseHp := d.baseHp, baseAtk := d.baseAtk, baseDef := d.baseDef,
    baseSpd := d.baseSpd, baseSpc := d.baseSpc, type1 := d.type1, type2 := d.type2,
    catchRate := d.catchRate, movePool := Battle.Data.learnset i }

/-- Every real (non-glitch) internal species index, ascending — the 151 species
    the generator can draw. -/
def realSpeciesIds : Array SpeciesId :=
  (Array.range 191).filterMap (fun i =>
    if Battle.Data.isRealSpecies i.toUInt8 then some i.toUInt8 else none)

/-- The full Gen-1 Pokédex as generator entries — all 151 real species, in
    internal-index order, with ROM base stats/types/catch rates and full learnsets. -/
def pokedex : Array SpeciesEntry := realSpeciesIds.map speciesEntry

/-- The `pokedex` entry for an index, wrapping modulo its size (`pokedex` is
    non-empty, so this is total and never returns the `default`). -/
def entryOf (idx : Nat) : SpeciesEntry := pokedex.getD (idx % pokedex.size) default

/-! ## Generation -/

/-- Clamp a raw level byte into `1..MAX_LEVEL`. -/
def clampLevel (l : UInt8) : UInt8 := (max 1 (min maxLevel l.toNat)).toUInt8

/-- Generate one mon: species `e`, `level` (clamped `1..MAX_LEVEL`), the four DVs
    (masked to nibbles), and `moveCount` (clamped to `1..min NUM_MOVES pool.size`).
    Stats come from byte-faithful `calcStat` at zero stat experience (a freshly
    generated mon); HP starts full. Legal by construction for any well-formed
    `SpeciesEntry` (`entryWf`). -/
def genMon (e : SpeciesEntry) (level atkDV defDV spdDV spcDV : UInt8)
    (moveCount : Nat) : MonState :=
  let lvl := clampLevel level
  let a := atkDV &&& 0x0F
  let d := defDV &&& 0x0F
  let s := spdDV &&& 0x0F
  let c := spcDV &&& 0x0F
  let hpIV := hpDV a d s c
  let mhp := calcStat e.baseHp hpIV lvl 0 true
  let k := max 1 (min (min moveCount numMoves) e.movePool.size)
  let chosen := e.movePool.extract 0 k
  { species := e.speciesId, hp := mhp, boxLevel := lvl, status := 0,
    type1 := e.type1, type2 := e.type2, catchRate := e.catchRate,
    moves := padTo numMoves 0 chosen,
    dvs := packDVs a.toUInt16 d.toUInt16 s.toUInt16 c.toUInt16,
    level := lvl, maxHp := mhp,
    attack := calcStat e.baseAtk a lvl 0 false,
    defense := calcStat e.baseDef d lvl 0 false,
    speed := calcStat e.baseSpd s lvl 0 false,
    special := calcStat e.baseSpc c lvl 0 false,
    pp := padTo numMoves 0 (chosen.map movePP) }

/-- A single generation request: which species, and the entropy `genMon` consumes. -/
structure GenChoice where
  entry : SpeciesEntry
  level : UInt8
  atkDV : UInt8
  defDV : UInt8
  spdDV : UInt8
  spcDV : UInt8
  moveCount : Nat
  deriving Repr, Inhabited

/-- `genMon` applied to a bundled `GenChoice`. -/
def genMonOf (ch : GenChoice) : MonState :=
  genMon ch.entry ch.level ch.atkDV ch.defDV ch.spdDV ch.spcDV ch.moveCount

/-- Generate a party from a list of choices (one mon each, order preserved). Legal
    at any `mode` when every choice's `entry` is well-formed and the party size is
    `1..PARTY_LENGTH` — see the guards and `Battle/RL/GeneratorSafe.lean`. -/
def genTeam (choices : Array GenChoice) : Team := choices.map genMonOf

/-! ## Fidelity guards -/

/-- A `SpeciesEntry` the generator can safely draw from: a non-empty, distinct,
    non-zero move pool (`genMon` takes a `≤ NUM_MOVES` prefix, so any such prefix
    is itself packed, distinct, non-empty — the pool may hold more than
    `NUM_MOVES` moves, as real learnsets do). -/
def entryWf (e : SpeciesEntry) : Bool :=
  1 ≤ e.movePool.size && e.movePool.all (· != 0) && noRepeats e.movePool.toList

/-- The canonical Gen-1 `Dex` (`Battle.Data`-backed) the generated mons are checked
    against — every drawn move is in the species' learnset, so a generated mon is
    `monLegal genDex .canonical` by construction. -/
def genDex : Dex := Dex.gen1

-- Every real species is a well-formed generator source (non-empty, distinct,
-- non-zero learn pool) — the full 151-entry table.
#guard pokedex.all entryWf
#guard pokedex.size == 151

-- `ceilSqrt255` is the saturating "smallest b with b² ≥ n".
#guard ceilSqrt255 0 == 1
#guard ceilSqrt255 1 == 1
#guard ceilSqrt255 2 == 2
#guard ceilSqrt255 25281 == 159      -- 159² exactly
#guard ceilSqrt255 25600 == 160      -- 160² exactly
#guard ceilSqrt255 64516 == 254      -- 254², the last un-saturated value
#guard ceilSqrt255 64517 == 255      -- saturates
#guard ceilSqrt255 65535 == 255

-- The `/4` stat-exp bonus: 0 fresh, 63 at cap.
#guard statExpBonus 0 == 0
#guard statExpBonus 25600 == 40      -- 160 / 4
#guard statExpBonus 65535 == 63      -- 255 / 4

-- `calcStat` vs hand-computed ROM values (Bulbasaur 45/49/49/45/65, Mew 100s).
#guard calcStat 45 15 100 0 true == 230      -- HP, L100, DV15
#guard calcStat 49 15 100 0 false == 133     -- Atk, +5
#guard calcStat 65 15 100 0 false == 165     -- Spc
#guard calcStat 45 15 50 0 true == 120       -- HP, L50
#guard calcStat 49 15 50 0 false == 69       -- Atk, L50
#guard calcStat 45 0 5 0 true == 19          -- HP, L5, DV0 (floor bites)
#guard calcStat 65 15 100 65535 false == 228 -- Spc with max stat exp (+63 term)
#guard calcStat 100 15 100 0 true == 340     -- Mew HP
#guard calcStat 255 15 255 65535 true == 999 -- overflow clamp

-- HP DV assembly from the four real DVs' low bits.
#guard hpDV 15 15 15 15 == 15    -- all odd → 0b1111
#guard hpDV 0 0 0 0 == 0
#guard hpDV 1 0 0 0 == 8         -- Atk LSB → bit 3
#guard hpDV 0 1 0 0 == 4         -- Def LSB → bit 2
#guard hpDV 0 0 1 0 == 2         -- Spd LSB → bit 1
#guard hpDV 0 0 0 1 == 1         -- Spc LSB → bit 0
#guard hpDV 14 14 14 14 == 0     -- all even → 0

-- DV word packing (Atk:Def high byte, Spd:Spc low byte), nibble-masked.
#guard packDVs 15 15 15 15 == 0xFFFF
#guard packDVs 0 0 0 0 == 0
#guard packDVs 15 0 0 0 == 0xF000
#guard packDVs 0 15 0 0 == 0x0F00
#guard packDVs 0 0 15 0 == 0x00F0
#guard packDVs 0 0 0 15 == 0x000F
#guard packDVs 0x1F 0 0 0 == 0xF000  -- masks to a nibble

-- `padTo` truncates, pads, and is a no-op at the exact size.
#guard padTo 4 (0 : UInt8) #[1, 2] == #[1, 2, 0, 0]
#guard padTo 4 (0 : UInt8) #[1, 2, 3, 4, 5] == #[1, 2, 3, 4]
#guard padTo 4 (0 : UInt8) #[1, 2, 3, 4] == #[1, 2, 3, 4]

-- `speciesEntry` reads the real ROM header + learnset for an internal index.
#guard (speciesEntry 153).speciesId == 153                          -- BULBASAUR
#guard (speciesEntry 153).baseHp == 45 && (speciesEntry 153).baseSpc == 65
#guard (speciesEntry 153).type1 == 0x16 && (speciesEntry 153).type2 == 0x03  -- Grass/Poison
#guard (speciesEntry 1).speciesId == 1                              -- RHYDON
#guard (speciesEntry 1).type1 == 0x04 && (speciesEntry 1).type2 == 0x05      -- Ground/Rock

-- `genMon` produces the expected Bulbasaur (internal 153) at L100, perfect DVs, 3
-- moves. Base stats match the ROM `CalcStat`; moves are the sorted learnset prefix.
private def bulba100 : MonState := genMon (speciesEntry 153) 100 15 15 15 15 3
#guard bulba100.species == 153
#guard bulba100.level == 100
#guard bulba100.maxHp == 230
#guard bulba100.hp == 230                      -- starts full
#guard bulba100.attack == 133
#guard bulba100.defense == 133
#guard bulba100.speed == 125
#guard bulba100.special == 165
#guard bulba100.moves == #[14, 15, 22, 0]      -- packed, distinct (learnset prefix)
#guard bulba100.pp == #[30, 30, 10, 0]         -- real base PP, padded
#guard bulba100.dvs == 0xFFFF
#guard bulba100.type1 == 0x16 && bulba100.type2 == 0x03
#guard battleValid bulba100
#guard monLegal genDex .canonical bulba100

-- Mew (internal 21): all-100 base stats; its huge (57-move) pool fills all 4 slots.
private def mew100 : MonState := genMon (speciesEntry 21) 100 15 15 15 15 4
#guard mew100.species == 21
#guard mew100.maxHp == 340
#guard mew100.attack == 235
#guard mew100.moves == #[1, 5, 6, 13]
#guard mew100.pp == #[35, 20, 20, 10]
#guard monLegal genDex .canonical mew100

-- Magikarp (internal 133): a 2-move pool clamps `k` even when 4 are requested.
private def karp100 : MonState := genMon (speciesEntry 133) 100 15 15 15 15 4
#guard karp100.species == 133
#guard karp100.moves == #[33, 150, 0, 0]       -- Tackle, Splash — pool exhausted at 2
#guard karp100.pp == #[35, 40, 0, 0]
#guard monLegal genDex .canonical karp100

-- Level clamping: over/under-range levels pin to MAX_LEVEL / 1.
#guard (genMon (speciesEntry 153) 200 0 0 0 0 1).level == 100
#guard (genMon (speciesEntry 153) 0 0 0 0 0 1).level == 1

-- Every real species, across parameter extremes, is legal by construction (151).
#guard pokedex.all (fun e => monLegal genDex .canonical (genMon e 73 3 11 15 4 3))
#guard pokedex.all (fun e => battleValid (genMon e 1 0 0 0 0 4))
#guard pokedex.all (fun e => battleValid (genMon e 100 15 15 15 15 1))

-- `genTeam` assembles a legal party; each mode and the size bounds hold.
private def sampleTeam : Team := genTeam #[
  { entry := speciesEntry 153, level := 50, atkDV := 9, defDV := 8, spdDV := 7, spcDV := 6, moveCount := 2 },
  { entry := speciesEntry 1, level := 100, atkDV := 15, defDV := 15, spdDV := 15, spcDV := 15, moveCount := 4 },
  { entry := speciesEntry 133, level := 5, atkDV := 0, defDV := 0, spdDV := 0, spcDV := 0, moveCount := 1 }]

#guard sampleTeam.size == 3
#guard teamLegal genDex .rangeOnly sampleTeam
#guard teamLegal genDex .movesetOpen sampleTeam
#guard teamLegal genDex .canonical sampleTeam
#guard sampleTeam[0]?.map (·.moves) == some #[14, 15, 0, 0]   -- Bulbasaur, first 2 of pool
#guard sampleTeam[1]?.map (·.moves) == some #[5, 6, 23, 25]   -- Rhydon, first 4 of pool

end Battle.RL
