/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.State

/-!
# Legal teams — decidable legality predicates for the RL generator

The rules a generated party must satisfy before the simulator will fight it,
as executable `Bool` decision procedures (their `#guard`s are the spec). The RL
loop generates random teams (`Battle/RL/Generator.lean`) and this module is the
oracle those teams are checked against; the generator-safety proof
(`Battle/RL/GeneratorSafe.lean`, task #21) will show every generated mon passes.

## Legality is layered into modes

`battleValid` is the structural floor the battle engine assumes of *any* mon it
loads — array widths, level/stat ranges, a packed non-empty distinct moveset —
independent of whether the mon is obtainable. On top of it, `Legality` selects
how much *cartridge obtainability* to also demand:

* `rangeOnly` — just `battleValid`. Every glitchy-but-representable mon (a raw
  `battle_struct` the engine won't choke on) counts. Widest RL exploration space.
* `movesetOpen` — also a real (non-glitch) species, but any move on any mon.
* `canonical` — also every move learnable by that species. Cartridge-legal.

## Data is a seam, not a second copy of the ROM

Species validity and learnsets are ROM tables GPT decodes with a round-trip
certificate (`COORDINATION.md` seam 3), so the obtainability predicates are
*parameterised* over a `Dex`. `Dex.permissive` here is bounded-but-permissive
scaffolding for the `#guard`s (and clearly **not** the canonical 151-species /
per-species-learnset filter); point `Dex` at `Rom/Tables` when it lands and these
predicates sharpen with no code change. `MAX_LEVEL = 100`
(`constants/battle_constants.asm`); `NUM_MOVES`, `MAX_STAT_VALUE`, `PARTY_LENGTH`
from `Battle.Wram`.
-/

namespace Battle.RL

open Battle.Wram (numMoves maxStatValue partyLength)

/-- A party — 1 to `PARTY_LENGTH` mons, in the model's semantic `MonState` view. -/
abbrev Team := Array MonState

/-- `MAX_LEVEL` (`constants/battle_constants.asm`). -/
def maxLevel : Nat := 100

/-- Largest legal party (`PARTY_LENGTH`). -/
def maxPartySize : Nat := partyLength

/-- How strict an obtainability standard a team is held to. See the module doc. -/
inductive Legality where
  /-- Structural well-formedness only — any representable `battle_struct`. -/
  | rangeOnly
  /-- Real species, but any moveset. -/
  | movesetOpen
  /-- Fully cartridge-obtainable: real species and every move learnable by it. -/
  | canonical
  deriving Repr, DecidableEq, BEq

/-! ## The data seam (ROM-decoded; parameterised) -/

/-- The obtainability tables the legality check consults — a real instance is
    ROM-decoded (`COORDINATION.md` seam 3, GPT's `Rom/Tables`). -/
structure Dex where
  /-- Is this internal species index a real (non-glitch) Pokémon? -/
  validSpecies : SpeciesId → Bool
  /-- Can this species legally learn this move (level-up ∪ TM/HM)? -/
  canLearn : SpeciesId → MoveId → Bool

/-- PROVISIONAL scaffolding: accepts any species index / move in the ROM's
    representable ranges (Gen 1 has 190 internal mon slots, 165 moves). This is
    **not** the canonical filter — glitch slots pass — it only exercises the
    predicate shape until `Rom/Tables` supplies the real `Dex`. -/
def Dex.permissive : Dex :=
  { validSpecies := fun s => 1 ≤ s.toNat && s.toNat ≤ 190,
    canLearn := fun _ mv => 1 ≤ mv.toNat && mv.toNat ≤ 165 }

/-! ## Moveset structure -/

/-- The occupied (non-`$00`) move slots, in order. -/
def realMoves (m : MonState) : Array MoveId := m.moves.filter (· != 0)

/-- No move ID repeats — the game never stores a move twice in one set. -/
def noRepeats : List MoveId → Bool
  | [] => true
  | x :: xs => !(xs.contains x) && noRepeats xs

/-- The first slot holds a real move (a mon always knows ≥ 1 move). -/
def firstMoveReal (m : MonState) : Bool := (m.moves[0]?).getD 0 != 0

/-- Moves are packed: once an empty (`$00`) slot appears, all later slots are
    empty too (the ROM never leaves a gap before a known move). -/
def movesPacked (m : MonState) : Bool :=
  (m.moves.toList.dropWhile (· != 0)).all (· == 0)

/-- The moveset is distinct across its occupied slots. -/
def movesDistinct (m : MonState) : Bool := noRepeats (realMoves m).toList

/-! ## The predicates -/

/-- Structural validity the battle engine assumes: exactly `NUM_MOVES` move and
    PP slots, level in `1..MAX_LEVEL`, every stat ≤ `MAX_STAT_VALUE`, current HP
    ≤ max HP, and a packed, non-empty, duplicate-free moveset. -/
def battleValid (m : MonState) : Bool :=
  m.moves.size == numMoves && m.pp.size == numMoves &&
  1 ≤ m.level.toNat && m.level.toNat ≤ maxLevel &&
  m.hp ≤ m.maxHp &&
  m.maxHp.toNat ≤ maxStatValue && m.attack.toNat ≤ maxStatValue &&
  m.defense.toNat ≤ maxStatValue && m.speed.toNat ≤ maxStatValue &&
  m.special.toNat ≤ maxStatValue &&
  firstMoveReal m && movesPacked m && movesDistinct m

/-- The species is a real (non-glitch) Pokémon per the `Dex`. -/
def canonicalSpecies (dex : Dex) (m : MonState) : Bool := dex.validSpecies m.species

/-- Every occupied move is one the species can legally learn per the `Dex`. -/
def learnsetLegal (dex : Dex) (m : MonState) : Bool :=
  (realMoves m).all (fun mv => dex.canLearn m.species mv)

/-- A single mon is legal at `mode`: always structurally valid, plus the
    obtainability the mode demands. -/
def monLegal (dex : Dex) (mode : Legality) (m : MonState) : Bool :=
  battleValid m &&
  match mode with
  | .rangeOnly => true
  | .movesetOpen => canonicalSpecies dex m
  | .canonical => canonicalSpecies dex m && learnsetLegal dex m

/-- A team is legal: a party of `1..PARTY_LENGTH` mons, each legal at `mode`.
    (Gen 1 permits duplicate species in a party, so no uniqueness constraint.) -/
def teamLegal (dex : Dex) (mode : Legality) (t : Team) : Bool :=
  1 ≤ t.size && t.size ≤ maxPartySize && t.all (monLegal dex mode)

/-! ## Fidelity guards -/

/-- A structurally-valid, canonical L50 mon: species 6, two distinct packed
    moves (52, 33), stats in range, HP ≤ max HP. -/
private def legalMon : MonState :=
  { species := 6, hp := 100, boxLevel := 50, status := 0, type1 := 0x14, type2 := 0x02,
    catchRate := 45, moves := #[52, 33, 0, 0], dvs := 0xFFFF, level := 50,
    maxHp := 100, attack := 80, defense := 70, speed := 100, special := 90,
    pp := #[15, 10, 0, 0] }

/-- A test `Dex` (a fixture, **not** ROM data): only species 6, learning {52, 33}. -/
private def tinyDex : Dex :=
  { validSpecies := fun s => s == 6,
    canLearn := fun s mv => s == 6 && (mv == 52 || mv == 33) }

-- `battleValid` accepts the good mon and rejects each structural defect.
#guard battleValid legalMon
#guard battleValid { legalMon with level := 0 } == false            -- level < 1
#guard battleValid { legalMon with level := 101 } == false          -- level > MAX_LEVEL
#guard battleValid { legalMon with moves := #[0, 52, 0, 0] } == false   -- empty first slot
#guard battleValid { legalMon with moves := #[52, 0, 33, 0] } == false  -- gap before a move
#guard battleValid { legalMon with moves := #[52, 52, 0, 0] } == false  -- duplicate move
#guard battleValid { legalMon with moves := #[52, 33, 0] } == false     -- wrong slot count
#guard battleValid { legalMon with pp := #[15, 10, 0] } == false        -- wrong PP count
#guard battleValid { legalMon with hp := 200 } == false             -- HP > max HP
#guard battleValid { legalMon with attack := 1000 } == false        -- stat > MAX_STAT_VALUE
#guard battleValid { legalMon with special := 1000 } == false

-- Species canonicity via the `Dex` seam.
#guard canonicalSpecies tinyDex legalMon
#guard canonicalSpecies tinyDex { legalMon with species := 7 } == false
#guard canonicalSpecies Dex.permissive { legalMon with species := 6 }
#guard canonicalSpecies Dex.permissive { legalMon with species := 0 } == false

-- Learnset legality via the `Dex` seam.
private def unlearnableMon : MonState := { legalMon with moves := #[52, 99, 0, 0] }
#guard battleValid unlearnableMon                          -- structurally fine
#guard learnsetLegal tinyDex legalMon
#guard learnsetLegal tinyDex unlearnableMon == false       -- 99 not in {52, 33}
#guard learnsetLegal Dex.permissive unlearnableMon         -- but 99 ≤ 165, so permissive allows

-- Modes select how much obtainability to enforce, on top of `battleValid`.
#guard monLegal tinyDex .canonical legalMon
#guard monLegal tinyDex .movesetOpen unlearnableMon        -- ignores learnset → legal
#guard monLegal tinyDex .canonical unlearnableMon == false -- learnset checked → illegal
#guard monLegal tinyDex .rangeOnly { legalMon with species := 200 }        -- ignores species
#guard monLegal tinyDex .movesetOpen { legalMon with species := 200 } == false
#guard monLegal tinyDex .rangeOnly { legalMon with level := 0 } == false   -- floor still applies

-- Team size bounds and per-mon legality.
#guard teamLegal tinyDex .canonical #[legalMon]
#guard teamLegal tinyDex .canonical #[legalMon, legalMon]           -- duplicate species allowed
#guard teamLegal tinyDex .canonical #[] == false                    -- empty party
#guard teamLegal tinyDex .canonical (List.replicate 7 legalMon).toArray == false  -- over PARTY_LENGTH
#guard teamLegal tinyDex .canonical (List.replicate 6 legalMon).toArray           -- full party ok
#guard teamLegal tinyDex .canonical #[legalMon, unlearnableMon] == false  -- one illegal mon sinks it

end Battle.RL
