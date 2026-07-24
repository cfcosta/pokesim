/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

/-!
# WRAM state contract

The battle-relevant slice of Game Boy work RAM, transcribed from the
`pret/pokered` disassembly at commit `405b6246372d7e5a2cb029cbb65219b13286b8c9`.
This module is the **shared vocabulary** of the Stage-0 differential harness: it
fixes the field offsets, widths, endianness, and named memory regions that both
the oracle (`sm83-lean` executing the assembled battle ROM) and the abstract
Lean battle model must agree on, byte for byte.

Nothing here executes or interprets — it only *describes* the layout. The
ROM-trace driver binds each `RegionSpec.symbol` to a concrete address using the
assembled `.sym` map; the battle-state codec interprets the bytes; the
comparator diffs region by region.

Sources: `constants/battle_constants.asm`, `constants/pokemon_data_constants.asm`,
`constants/serial_constants.asm`, `macros/ram.asm` (the `battle_struct` layout
macro), and `ram/wram.asm` (the variable definitions). The companion chapter
`docs/02-battle-state.md` is the prose inventory this module encodes.
-/

namespace Battle.Wram

/-! ## Core cardinalities (`constants/*.asm`) -/

/-- `NUM_MOVES` — move slots per mon (`battle_constants.asm`). -/
def numMoves : Nat := 4
/-- `NUM_STATS` — HP/Atk/Def/Spd/Spc (`battle_constants.asm`). -/
def numStats : Nat := 5
/-- `NUM_STAT_MODS` — the six live stat-mod stages plus two `const_skip` pads. -/
def numStatMods : Nat := 8
/-- `PARTY_LENGTH` — mons per party (`pokemon_data_constants.asm`). -/
def partyLength : Nat := 6
/-- `NAME_LENGTH` — nickname bytes (`text_constants.asm`). -/
def nameLength : Nat := 11
/-- `BASE_STAT_LEVEL` — the neutral stat-mod stage (index 7 of 1..13). -/
def baseStatLevel : Nat := 7
/-- `MAX_STAT_LEVEL` — the top stat-mod stage. -/
def maxStatLevel : Nat := 13
/-- `MAX_STAT_VALUE` — the computed-stat cap. -/
def maxStatValue : Nat := 999

/-! ## Struct lengths (`pokemon_data_constants.asm`, `macros/ram.asm`) -/

/-- `battle_struct` length: the active-mon record, `$1D`. -/
def battleStructLength : Nat := 29
/-- `BOXMON_STRUCT_LENGTH`, `$21`. -/
def boxStructLength : Nat := 33
/-- `PARTYMON_STRUCT_LENGTH`, `$2C`. -/
def partyStructLength : Nat := 44

/-! ## PP packing (`pokemon_data_constants.asm:100-102`) -/

/-- `PP_MASK` — current PP in bits 0-5. -/
def ppMask : UInt8 := 0x3F
/-- `PP_UP_MASK` — PP Ups applied in bits 6-7. -/
def ppUpMask : UInt8 := 0xC0

/-! ## Non-volatile status byte (`battle_constants.asm:61-67`)

Layout of `battle_struct` `+4` (and party `MON_STATUS`). Sleep is a *counter*
in bits 0-2, disjoint from the burn/poison/freeze/paralysis flag bits, so the
byte must be modelled raw (multi-bit glitch states are reachable). -/

namespace Status
/-- `SLP_MASK` — sleep turn counter, bits 0-2 (`%111`). -/
def slpMask : UInt8 := 0x07
/-- `PSN` bit index. -/
def psn : Nat := 3
/-- `BRN` bit index. -/
def brn : Nat := 4
/-- `FRZ` bit index. -/
def frz : Nat := 5
/-- `PAR` bit index. -/
def par : Nat := 6
end Status

/-! ## Volatile battle-status bit indices (`battle_constants.asm:79-107`)

Three bytes per side (`wPlayerBattleStatus1/2/3`, `wEnemyBattleStatus1/2/3`),
identical layout on both sides. -/

namespace BattleStatus1
def storingEnergy : Nat := 0            -- Bide
def thrashingAbout : Nat := 1           -- Thrash / Petal Dance
def attackingMultipleTimes : Nat := 2   -- Double Kick, Fury Attack, …
def flinched : Nat := 3
def chargingUp : Nat := 4               -- Solar Beam, Sky Attack, Fly, Dig
def usingTrappingMove : Nat := 5        -- Wrap / Bind / Fire Spin / Clamp
def invulnerable : Nat := 6             -- semi-invulnerable frame of Fly / Dig
def confused : Nat := 7
end BattleStatus1

namespace BattleStatus2
def usingXAccuracy : Nat := 0
def protectedByMist : Nat := 1
def gettingPumped : Nat := 2            -- Focus Energy
-- bit 3 is `const_skip` (unused)
def hasSubstituteUp : Nat := 4
def needsToRecharge : Nat := 5          -- Hyper Beam
def usingRage : Nat := 6
def seeded : Nat := 7                   -- Leech Seed
end BattleStatus2

namespace BattleStatus3
def badlyPoisoned : Nat := 0            -- Toxic ramp
def hasLightScreenUp : Nat := 1
def hasReflectUp : Nat := 2
def transformed : Nat := 3
-- bits 4-7 unused
end BattleStatus3

/-! ## Damage-multiplier byte and effectiveness scale (`battle_constants.asm:54-77`) -/

/-- `BIT_STAB_DAMAGE` — STAB flag in `wDamageMultipliers` bit 7. -/
def bitStabDamage : Nat := 7
/-- `EFFECTIVENESS_MASK` — bits 0-6 hold effectiveness ×10. -/
def effectivenessMask : UInt8 := 0x7F
def superEffective : Nat := 20
def moreEffective : Nat := 15
def effective : Nat := 10
def notVeryEffective : Nat := 5
def noEffect : Nat := 0

/-! ## Battle mode and link (`battle_constants.asm`, `serial_constants.asm`) -/

def battleTypeNormal : Nat := 0
def battleTypeOldMan : Nat := 1
def battleTypeSafari : Nat := 2

/-- Trainer-owned mons carry fixed DVs `$98`/`$88`. -/
def atkDefDvTrainer : UInt8 := 0x98
def spdSpcDvTrainer : UInt8 := 0x88

/-- `SERIAL_RNS_LENGTH` — declared size of the link RNG list. -/
def serialRnsLength : Nat := 10
/-- Values actually consumed before a reseed (`SERIAL_RNS_LENGTH - 1`). -/
def rnsConsumed : Nat := 9
/-- `LINK_STATE_BATTLING` — the `wLinkState` value selecting the shared PRNG. -/
def linkStateBattling : UInt8 := 0x04

/-! ## The `battle_struct` field layout (`macros/ram.asm:39-59`)

29 bytes, instantiated as `wBattleMon` (player) and `wEnemyMon` (enemy).
Multi-byte HP/stat fields are **big-endian**. `Moves`, `PP`, and `DVs` are byte
arrays / packed nibbles, not big-endian integers, so `bigEndianWord := false`. -/

/-- A single `battle_struct` field: its struct-relative offset and byte width. -/
structure Field where
  /-- Field name (the `battle_struct` macro label without the side prefix). -/
  name : String
  /-- Struct-relative offset in bytes. -/
  offset : Nat
  /-- Byte width. -/
  width : Nat
  /-- `true` iff the `width` bytes form one big-endian integer (the HP and stat
      words). Byte arrays (`Moves`, `PP`) and the packed `DVs` are `false`. -/
  bigEndianWord : Bool := false
deriving Repr, DecidableEq

/-- The 16 `battle_struct` fields, in address order. -/
def battleStructFields : List Field :=
  [ { name := "Species",   offset := 0,  width := 1 },
    { name := "HP",        offset := 1,  width := 2, bigEndianWord := true },
    { name := "BoxLevel",  offset := 3,  width := 1 },  -- aka PartyPos; round-trips MON_BOX_LEVEL
    { name := "Status",    offset := 4,  width := 1 },
    { name := "Type1",     offset := 5,  width := 1 },
    { name := "Type2",     offset := 6,  width := 1 },
    { name := "CatchRate", offset := 7,  width := 1 },  -- dead copy; live rate is wEnemyMonActualCatchRate
    { name := "Moves",     offset := 8,  width := 4 },
    { name := "DVs",       offset := 12, width := 2 },  -- packed nibbles Atk/Def/Spd/Spc
    { name := "Level",     offset := 14, width := 1 },
    { name := "MaxHP",     offset := 15, width := 2, bigEndianWord := true },
    { name := "Attack",    offset := 17, width := 2, bigEndianWord := true },
    { name := "Defense",   offset := 19, width := 2, bigEndianWord := true },
    { name := "Speed",     offset := 21, width := 2, bigEndianWord := true },
    { name := "Special",   offset := 23, width := 2, bigEndianWord := true },
    { name := "PP",        offset := 25, width := 4 } ]

/-- Sum of all field widths. -/
def totalWidth (fs : List Field) : Nat := fs.foldl (fun acc f => acc + f.width) 0

/-- Fields tile `[start, …)` with no gaps or overlaps, in order. -/
def fieldsContiguous (start : Nat) : List Field → Bool
  | [] => true
  | f :: fs => (f.offset == start) && fieldsContiguous (start + f.width) fs

-- The layout is self-consistent: these fail the build if any offset/width drifts.
#guard totalWidth battleStructFields == battleStructLength
#guard fieldsContiguous 0 battleStructFields
#guard battleStructLength == 0x1D

/-! ## Named memory regions

A `RegionSpec` names a contiguous byte region by its pokered WRAM/HRAM symbol.
Absolute addresses are assigned by the linker and are *not* in the source, so
the contract stays symbolic: the ROM-trace driver resolves `symbol` → address
from the assembled `.sym` map, then reads `len` bytes. -/

/-- A named, fixed-length region of the battle state. -/
structure RegionSpec where
  /-- The pokered WRAM/HRAM label, resolved to an address by the driver. -/
  symbol : String
  /-- Number of bytes captured for this region. -/
  len : Nat
  /-- What the region carries (for humans and divergence reports). -/
  note : String := ""
deriving Repr, DecidableEq

/-- The two active-mon `battle_struct`s plus the enemy-only trailing block
    (`wEnemyMonBaseStats`, `wEnemyMonActualCatchRate`, `wEnemyMonBaseExp`), which
    has no player counterpart (player base stats come from `wMonHeader`). -/
def activeMonRegions : List RegionSpec :=
  [ { symbol := "wBattleMon", len := battleStructLength, note := "player active mon" },
    { symbol := "wEnemyMon",  len := battleStructLength, note := "enemy active mon" },
    { symbol := "wEnemyMonBaseStats",       len := numStats, note := "enemy-only: base HP/Atk/Def/Spd/Spc" },
    { symbol := "wEnemyMonActualCatchRate", len := 1, note := "enemy-only: live catch rate" },
    { symbol := "wEnemyMonBaseExp",         len := 1, note := "enemy-only: base exp" } ]

/-- Party lists and stored party mons for both sides (needed for switching). -/
def partyRegions : List RegionSpec :=
  [ { symbol := "wPartyCount",        len := 1 },
    { symbol := "wPartySpecies",      len := partyLength + 1, note := "$FF-terminated species list" },
    { symbol := "wPartyMon1",         len := partyLength * partyStructLength, note := "6 × party_struct" },
    { symbol := "wEnemyPartyCount",   len := 1 },
    { symbol := "wEnemyPartySpecies", len := partyLength + 1, note := "$FF-terminated species list" },
    { symbol := "wEnemyMon1",         len := partyLength * partyStructLength, note := "6 × party_struct" },
    { symbol := "wPlayerMonNumber",   len := 1, note := "player's active party index" } ]

/-- The six volatile battle-status bytes and the per-side volatile counters. -/
def volatileRegions : List RegionSpec :=
  [ { symbol := "wPlayerBattleStatus1", len := 1 },
    { symbol := "wPlayerBattleStatus2", len := 1 },
    { symbol := "wPlayerBattleStatus3", len := 1 },
    { symbol := "wEnemyBattleStatus1",  len := 1 },
    { symbol := "wEnemyBattleStatus2",  len := 1 },
    { symbol := "wEnemyBattleStatus3",  len := 1 },
    { symbol := "wPlayerNumAttacksLeft",     len := 1 },
    { symbol := "wPlayerConfusedCounter",    len := 1 },
    { symbol := "wPlayerToxicCounter",       len := 1 },
    { symbol := "wPlayerDisabledMove",       len := 1, note := "hi nibble = slot, lo = turns left" },
    { symbol := "wPlayerDisabledMoveNumber", len := 1 },
    { symbol := "wEnemyNumAttacksLeft",      len := 1 },
    { symbol := "wEnemyConfusedCounter",     len := 1 },
    { symbol := "wEnemyToxicCounter",        len := 1 },
    { symbol := "wEnemyDisabledMove",        len := 1 },
    { symbol := "wEnemyDisabledMoveNumber",  len := 1 },
    { symbol := "wPlayerSubstituteHP", len := 1 },
    { symbol := "wEnemySubstituteHP",  len := 1 },
    { symbol := "wPlayerBideAccumulatedDamage", len := 2, note := "big-endian; unions with NumHits" },
    { symbol := "wEnemyBideAccumulatedDamage",  len := 2, note := "big-endian; unions with NumHits" } ]

/-- Unmodified-stat shadows (Level..Special, 11 bytes) and the six stat-mod
    stages (Atk/Def/Spd/Spc/Acc/Eva, range 1..13 with 7 neutral) per side. -/
def statStageRegions : List RegionSpec :=
  [ { symbol := "wPlayerMonUnmodifiedLevel", len := 11, note := "Level(1)+MaxHP/Atk/Def/Spd/Spc(2 each), BE" },
    { symbol := "wPlayerMonAttackMod",       len := 6,  note := "Atk/Def/Spd/Spc/Acc/Eva stages" },
    { symbol := "wEnemyMonUnmodifiedLevel",  len := 11 },
    { symbol := "wEnemyMonAttackMod",        len := 6 } ]

/-- The per-turn move-scratch sets (refilled from move data each turn) and the
    selected / used / list-index move cells. -/
def moveScratchRegions : List RegionSpec :=
  [ { symbol := "wPlayerMoveNum", len := 6, note := "Num/Effect/Power/Type/Accuracy/MaxPP" },
    { symbol := "wEnemyMoveNum",  len := 6 },
    { symbol := "wPlayerSelectedMove",  len := 1 },
    { symbol := "wEnemySelectedMove",   len := 1 },
    { symbol := "wPlayerUsedMove",      len := 1 },
    { symbol := "wEnemyUsedMove",       len := 1 },
    { symbol := "wPlayerMoveListIndex", len := 1 },
    { symbol := "wEnemyMoveListIndex",  len := 1 } ]

/-- Shared damage/result scratch. `wDamage` is one big-endian cell read back by
    both sides (the Counter interaction depends on this). -/
def damageResultRegions : List RegionSpec :=
  [ { symbol := "wDamage",            len := 2, note := "big-endian; single shared cell" },
    { symbol := "wDamageMultipliers", len := 1, note := "bits 0-6 effectiveness ×10, bit 7 STAB" },
    { symbol := "wCriticalHitOrOHKO", len := 1, note := "$00/$01/$02/$FF" },
    { symbol := "wMoveMissed",        len := 1 },
    { symbol := "wMoveDidntMiss",     len := 1 } ]

/-- Battle mode, opponent, and result vars. -/
def battleModeRegions : List RegionSpec :=
  [ { symbol := "wIsInBattle",  len := 1, note := "$FF lost / $00 none / $01 wild / $02 trainer" },
    { symbol := "wBattleType",  len := 1, note := "0 normal / 1 old-man / 2 safari" },
    { symbol := "wBattleResult", len := 1, note := "0 win / 1 lose / 2 draw" },
    { symbol := "wCurOpponent",  len := 1 },
    { symbol := "wCurEnemyLevel", len := 1 },
    { symbol := "wTrainerClass",  len := 1 },
    { symbol := "wNumRunAttempts", len := 1 },
    { symbol := "wEscapedFromBattle", len := 1 },
    { symbol := "wActionResultOrTookBattleTurn", len := 1 },
    { symbol := "wAICount", len := 1, note := "remaining enemy-AI item/action budget" } ]

/-- RNG state: the shared link list + cursor (link battles) and the HRAM
    primary/secondary bytes (non-link), plus the master turn selector. -/
def rngRegions : List RegionSpec :=
  [ { symbol := "wLinkBattleRandomNumberList",      len := serialRnsLength, note := "shared link PRNG list" },
    { symbol := "wLinkBattleRandomNumberListIndex", len := 1, note := "read cursor" },
    { symbol := "hRandomAdd", len := 1, note := "HRAM: non-link primary RNG byte" },
    { symbol := "hRandomSub", len := 1, note := "HRAM: non-link secondary RNG byte" },
    { symbol := "hWhoseTurn", len := 1, note := "HRAM: 0 player / 1 enemy (master turn selector)" } ]

/-- The full battle-relevant WRAM/HRAM slice captured at each checkpoint.
    Fixtures may capture a subset; this is the maximal default. -/
def battleCheckpointRegions : List RegionSpec :=
  activeMonRegions ++ partyRegions ++ volatileRegions ++ statStageRegions ++
    moveScratchRegions ++ damageResultRegions ++ battleModeRegions ++ rngRegions

/-- Every region captures at least one byte. -/
def regionsWellFormed (rs : List RegionSpec) : Bool := rs.all (fun r => r.len != 0)

#guard regionsWellFormed battleCheckpointRegions

end Battle.Wram
