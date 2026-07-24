/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Wram

/-!
# Type identifiers and the effectiveness chart

The Gen-1 elemental type IDs and the `TypeEffects` matchup table, transcribed
from the `pret/pokered` disassembly at commit
`405b6246372d7e5a2cb029cbb65219b13286b8c9`:

* `constants/type_constants.asm` — the type numbering. Physical types occupy
  `$00`–`$08`; a deliberate gap (`$09`–`$13`, `UNUSED_TYPES`) precedes the
  special types `$14`–`$1A`. The gap is why `SPECIAL = $14` doubles as the
  physical/special boundary: `GetDamageVarsFor{Player,Enemy}Attack` decides which
  offensive stat to read with `cp SPECIAL; jr c, .physical`.
* `data/types/type_matchups.asm` — the ordered attacker→defender table, factors
  scaled ×10 (`constants/battle_constants.asm:54-59`).

**Order is load-bearing.** `AdjustDamageForMoveType` scans `TypeEffects`
top-to-bottom and multiplies damage by `factor / 10` *with integer flooring after
each hit*, so a dual-type defender's two multiplications occur in table order,
not type1-then-type2 order. This module therefore preserves the ASM row order
exactly; `Damage.lean` folds the whole list (see Task #13). `matchup` below is
the per-pair view used for `#guard`s and by that fold.

**Provenance.** These bytes are hand-transcribed from the named ASM. GPT owns the
single source of truth: when `Battle/Rom/Tables` decodes `TypeEffects` straight
from the ROM image, replace this transcription with a byte-equality certificate
against it (see `COORDINATION.md`, seam 3). Until then this is the reference copy.
-/

namespace Battle.TypeChart

/-! ## Type identifiers (`constants/type_constants.asm`) -/

-- Physical types, `$00`–`$08`.
def normal   : UInt8 := 0x00
def fighting : UInt8 := 0x01
def flying   : UInt8 := 0x02
def poison   : UInt8 := 0x03
def ground   : UInt8 := 0x04
def rock     : UInt8 := 0x05
def bird     : UInt8 := 0x06  -- `BIRD`; no move or species uses it in battle
def bug      : UInt8 := 0x07
def ghost    : UInt8 := 0x08

/-- `SPECIAL = $14`. The first special type ID and, because `$09`–`$13` are
    unused, the physical/special split point for choosing the offensive stat. -/
def special : UInt8 := 0x14

-- Special types, `$14`–`$1A`.
def fire     : UInt8 := 0x14
def water    : UInt8 := 0x15
def grass    : UInt8 := 0x16
def electric : UInt8 := 0x17
def psychic  : UInt8 := 0x18  -- `PSYCHIC_TYPE`
def ice      : UInt8 := 0x19
def dragon   : UInt8 := 0x1A

/-- `NUM_TYPES = $1B` (counts the `$09`–`$13` gap; it is the table dimension the
    ROM uses, not the count of types that exist). -/
def numTypes : Nat := 0x1B

/-- A move's type is *special* — uses the Special stat on attack and defence —
    iff its ID is at least `SPECIAL`. Mirrors `cp SPECIAL; jr c, .physical`. -/
def isSpecial (t : UInt8) : Bool := t ≥ special

/-! ## Effectiveness factors (`constants/battle_constants.asm:54-59`)

Scaled ×10. `EFFECTIVE` (10, i.e. ×1) is the implicit default for any pair the
table does not list. These mirror the `Nat` copies in `Battle.Wram`; the drift
`#guard`s below keep the two in lockstep. -/

def superEffective   : UInt8 := 20
def effective        : UInt8 := 10
def notVeryEffective : UInt8 := 5
def noEffect         : UInt8 := 0

/-! ## `TypeEffects` (`data/types/type_matchups.asm`)

Transcribed entry-for-entry, `(attacker, defender, factor×10)`, in ASM order. -/

def typeEffects : List (UInt8 × UInt8 × UInt8) :=
  [ (water,    fire,     superEffective)
  , (fire,     grass,    superEffective)
  , (fire,     ice,      superEffective)
  , (grass,    water,    superEffective)
  , (electric, water,    superEffective)
  , (water,    rock,     superEffective)
  , (ground,   flying,   noEffect)
  , (water,    water,    notVeryEffective)
  , (fire,     fire,     notVeryEffective)
  , (electric, electric, notVeryEffective)
  , (ice,      ice,      notVeryEffective)
  , (grass,    grass,    notVeryEffective)
  , (psychic,  psychic,  notVeryEffective)
  , (fire,     water,    notVeryEffective)
  , (grass,    fire,     notVeryEffective)
  , (water,    grass,    notVeryEffective)
  , (electric, grass,    notVeryEffective)
  , (normal,   rock,     notVeryEffective)
  , (normal,   ghost,    noEffect)
  , (ghost,    ghost,    superEffective)
  , (fire,     bug,      superEffective)
  , (fire,     rock,     notVeryEffective)
  , (water,    ground,   superEffective)
  , (electric, ground,   noEffect)
  , (electric, flying,   superEffective)
  , (grass,    ground,   superEffective)
  , (grass,    bug,      notVeryEffective)
  , (grass,    poison,   notVeryEffective)
  , (grass,    rock,     superEffective)
  , (grass,    flying,   notVeryEffective)
  , (ice,      water,    notVeryEffective)
  , (ice,      grass,    superEffective)
  , (ice,      ground,   superEffective)
  , (ice,      flying,   superEffective)
  , (fighting, normal,   superEffective)
  , (fighting, poison,   notVeryEffective)
  , (fighting, flying,   notVeryEffective)
  , (fighting, psychic,  notVeryEffective)
  , (fighting, bug,      notVeryEffective)
  , (fighting, rock,     superEffective)
  , (fighting, ice,      superEffective)
  , (fighting, ghost,    noEffect)
  , (poison,   grass,    superEffective)
  , (poison,   poison,   notVeryEffective)
  , (poison,   ground,   notVeryEffective)
  , (poison,   bug,      superEffective)
  , (poison,   rock,     notVeryEffective)
  , (poison,   ghost,    notVeryEffective)
  , (ground,   fire,     superEffective)
  , (ground,   electric, superEffective)
  , (ground,   grass,    notVeryEffective)
  , (ground,   bug,      notVeryEffective)
  , (ground,   rock,     superEffective)
  , (ground,   poison,   superEffective)
  , (flying,   electric, notVeryEffective)
  , (flying,   fighting, superEffective)
  , (flying,   bug,      superEffective)
  , (flying,   grass,    superEffective)
  , (flying,   rock,     notVeryEffective)
  , (psychic,  fighting, superEffective)
  , (psychic,  poison,   superEffective)
  , (bug,      fire,     notVeryEffective)
  , (bug,      grass,    superEffective)
  , (bug,      fighting, notVeryEffective)
  , (bug,      flying,   notVeryEffective)
  , (bug,      psychic,  superEffective)
  , (bug,      ghost,    notVeryEffective)
  , (bug,      poison,   superEffective)
  , (rock,     fire,     superEffective)
  , (rock,     fighting, notVeryEffective)
  , (rock,     ground,   notVeryEffective)
  , (rock,     flying,   superEffective)
  , (rock,     bug,      superEffective)
  , (rock,     ice,      superEffective)
  , (ghost,    normal,   noEffect)
  , (ghost,    psychic,  noEffect)
  , (fire,     dragon,   notVeryEffective)
  , (water,    dragon,   notVeryEffective)
  , (electric, dragon,   notVeryEffective)
  , (grass,    dragon,   notVeryEffective)
  , (ice,      dragon,   superEffective)
  , (dragon,   dragon,   superEffective) ]

/-- Effectiveness (×10) of one ordered `(attacker, defender)` type pair. Returns
    `EFFECTIVE` (10, i.e. ×1) when the pair is absent — the ROM's default when
    the `TypeEffects` scan finds no match. Every ordered pair occurs at most once
    in the table, so first-match is exact. -/
def matchup (attacker defender : UInt8) : UInt8 :=
  match typeEffects.find? (fun e => e.1 == attacker && e.2.1 == defender) with
  | some e => e.2.2
  | none   => effective

/-! ## Fidelity guards -/

-- Type-ID anchors against `constants/type_constants.asm`.
#guard normal.toNat == 0x00
#guard ghost.toNat == 0x08
#guard fire.toNat == 0x14
#guard dragon.toNat == 0x1A
#guard numTypes == 0x1B

-- The physical/special split.
#guard special == fire
#guard isSpecial fire
#guard isSpecial water
#guard isSpecial dragon
#guard !isSpecial normal
#guard !isSpecial ghost
#guard !isSpecial ground
#guard !isSpecial bird  -- $06 < $14

-- Effectiveness factors stay pinned to the `Battle.Wram` copies.
#guard superEffective.toNat == Battle.Wram.superEffective
#guard effective.toNat == Battle.Wram.effective
#guard notVeryEffective.toNat == Battle.Wram.notVeryEffective
#guard noEffect.toNat == Battle.Wram.noEffect

-- Table shape.
#guard typeEffects.length == 82

-- Super-effective spot checks.
#guard matchup water fire == superEffective
#guard matchup fire grass == superEffective
#guard matchup electric water == superEffective
#guard matchup grass water == superEffective
#guard matchup ice dragon == superEffective
#guard matchup dragon dragon == superEffective
#guard matchup fighting normal == superEffective

-- No-effect / immunity spot checks.
#guard matchup ground flying == noEffect
#guard matchup electric ground == noEffect
#guard matchup normal ghost == noEffect
#guard matchup ghost normal == noEffect
#guard matchup fighting ghost == noEffect

-- Not-very-effective spot checks, including the Gen-1 mirror-type resistances.
#guard matchup fire water == notVeryEffective
#guard matchup water water == notVeryEffective
#guard matchup fire fire == notVeryEffective
#guard matchup psychic psychic == notVeryEffective
#guard matchup normal rock == notVeryEffective

-- Gen-1 quirks worth locking down.
#guard matchup poison bug == superEffective       -- Poison is SE vs Bug in Gen 1
#guard matchup bug poison == superEffective       -- and Bug is SE vs Poison
#guard matchup bug ghost == notVeryEffective      -- Bug resists-hitting Ghost
#guard matchup psychic poison == superEffective   -- Psychic SE vs Poison

-- Unlisted pairs fall through to ×1.
#guard matchup normal normal == effective
#guard matchup fire electric == effective
#guard matchup dragon normal == effective

end Battle.TypeChart
