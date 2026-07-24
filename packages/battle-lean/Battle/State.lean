/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Types
import Battle.Outcome
import Battle.Rng
import Battle.Wram

/-!
# Battle state

A structured, model-side view of the battle-relevant WRAM that `Battle.Wram`
lays out byte-for-byte. Where `Battle.Wram` fixes offsets/widths/regions for the
differential codec, this module gives the *interpreted* state the pure turn
resolver (`Battle.Step`) reads and writes: the two active `battle_struct`s, their
stat-mod stages and volatile-status bytes, the link RNG cursor, a turn counter,
the `BattleMode`, and the `EpisodePhase`.

Everything here is a faithful re-view of named WRAM:

* `BattleMon` mirrors the 29-byte `battle_struct` (`macros/ram.asm:39-59`, and
  `Battle.Wram.battleStructFields`). HP/stat words are the big-endian integers
  the ROM stores; `moves`/`pp` are 4-byte arrays; `status` is the **raw**
  non-volatile status byte (sleep is a counter in bits 0-2 disjoint from the
  PSN/BRN/FRZ/PAR flag bits, so glitch combinations stay representable).
* `StatStages` is the six `…AttackMod` stages (`wPlayerMonAttackMod`, 6 bytes),
  each in `1..13` with `7` neutral (`Battle.Wram.baseStatLevel`).
* `Volatile` is the three `…BattleStatus1/2/3` bytes plus the per-side volatile
  counters (`wPlayerNumAttacksLeft`, `…ConfusedCounter`, `…ToxicCounter`,
  `…DisabledMove(Number)`, `…SubstituteHP`, `…BideAccumulatedDamage`).

Party lists / switching are not modelled here yet: `BattleState` carries each
side's *active* mon, which is what a single attacking turn resolves against. The
`Refinement/` layer maps this state onto GPT's `Battle.Episode.State`.
-/

namespace Battle

open Battle.Wram (numMoves baseStatLevel maxStatLevel)

/-! ## Bit helper -/

/-- Bit `i` of a status byte, via `Nat.testBit` on the underlying value. -/
def bitSet (b : UInt8) (i : Nat) : Bool := b.toNat.testBit i

/-! ## The active mon (`battle_struct`) -/

/-- The active-mon in-battle record — a structured view of the 29-byte
    `battle_struct` (`Battle.Wram.battleStructFields`). HP/stat fields are the
    integers the ROM stores big-endian; `moves`/`pp` are 4-entry byte arrays;
    `status` is the raw non-volatile status byte. -/
structure BattleMon where
  /-- `Species` — internal Pokédex index. -/
  species : SpeciesId
  /-- `HP` — current hit points (big-endian word). -/
  hp : UInt16
  /-- `BoxLevel` / `PartyPos` — round-trips `MON_BOX_LEVEL`. -/
  boxLevel : UInt8
  /-- `Status` — raw non-volatile status byte (sleep counter + PSN/BRN/FRZ/PAR). -/
  status : UInt8
  /-- `Type1`. -/
  type1 : UInt8
  /-- `Type2` (equals `Type1` for single-typed mons). -/
  type2 : UInt8
  /-- `CatchRate` — the dead copy in the struct (live rate is elsewhere). -/
  catchRate : UInt8
  /-- `Moves` — four move IDs (`$00` = empty slot). -/
  moves : Array MoveId
  /-- `DVs` — packed Atk/Def/Spd/Spc nibbles. -/
  dvs : UInt16
  /-- `Level` — the current, in-battle level. -/
  level : UInt8
  /-- `MaxHP` (big-endian word). -/
  maxHp : UInt16
  /-- `Attack` (big-endian word). -/
  attack : UInt16
  /-- `Defense` (big-endian word). -/
  defense : UInt16
  /-- `Speed` (big-endian word). -/
  speed : UInt16
  /-- `Special` (big-endian word). -/
  special : UInt16
  /-- `PP` — current PP for the four slots (bits 0-5; PP Ups in bits 6-7). -/
  pp : Array UInt8
  deriving Repr, DecidableEq, BEq

/-- Well-formed: the move and PP arrays each hold exactly `NUM_MOVES` entries. -/
def BattleMon.wf (m : BattleMon) : Bool :=
  m.moves.size == numMoves && m.pp.size == numMoves

/-- A mon is fainted exactly when its HP is zero. -/
def BattleMon.fainted (m : BattleMon) : Bool := m.hp == 0

/-! ### Non-volatile status accessors (`Battle.Wram.Status`) -/

/-- Asleep — the sleep counter (bits 0-2) is nonzero. -/
def BattleMon.asleep (m : BattleMon) : Bool := (m.status &&& Wram.Status.slpMask) != 0
/-- Poisoned (`PSN`, bit 3). -/
def BattleMon.poisoned (m : BattleMon) : Bool := bitSet m.status Wram.Status.psn
/-- Burned (`BRN`, bit 4). -/
def BattleMon.burned (m : BattleMon) : Bool := bitSet m.status Wram.Status.brn
/-- Frozen (`FRZ`, bit 5). -/
def BattleMon.frozen (m : BattleMon) : Bool := bitSet m.status Wram.Status.frz
/-- Paralysed (`PAR`, bit 6). -/
def BattleMon.paralyzed (m : BattleMon) : Bool := bitSet m.status Wram.Status.par

/-! ## Stat-mod stages -/

/-- The six stat-mod stages (`wPlayerMonAttackMod`, 6 bytes), each `1..13` with
    `7` neutral. Accuracy/Evasion share the same range and mechanics. -/
structure StatStages where
  attack : UInt8
  defense : UInt8
  speed : UInt8
  special : UInt8
  accuracy : UInt8
  evasion : UInt8
  deriving Repr, DecidableEq, BEq

/-- The neutral stages every mon starts a battle (and every switch-in) with:
    all six at `BASE_STAT_LEVEL = 7`. -/
def StatStages.neutral : StatStages :=
  { attack := 7, defense := 7, speed := 7, special := 7, accuracy := 7, evasion := 7 }

/-- Well-formed: every stage is within `1..MAX_STAT_LEVEL`. -/
def StatStages.wf (s : StatStages) : Bool :=
  let inRange (x : UInt8) : Bool := 1 ≤ x.toNat && x.toNat ≤ maxStatLevel
  inRange s.attack && inRange s.defense && inRange s.speed &&
    inRange s.special && inRange s.accuracy && inRange s.evasion

/-! ## Volatile battle status -/

/-- The volatile per-side state: the three `…BattleStatus` bit-bytes plus the
    volatile counters. `status1/2/3` are raw so multi-bit combinations stay
    representable; the accessors below name the bits used most by the resolver. -/
structure Volatile where
  /-- `wPlayerBattleStatus1`. -/
  status1 : UInt8
  /-- `wPlayerBattleStatus2`. -/
  status2 : UInt8
  /-- `wPlayerBattleStatus3`. -/
  status3 : UInt8
  /-- `wPlayerNumAttacksLeft` — remaining hits of a multi-turn/​multi-hit move. -/
  numAttacksLeft : UInt8
  /-- `wPlayerConfusedCounter`. -/
  confusedCounter : UInt8
  /-- `wPlayerToxicCounter`. -/
  toxicCounter : UInt8
  /-- `wPlayerDisabledMove` — hi nibble slot, lo nibble turns left. -/
  disabledMove : UInt8
  /-- `wPlayerDisabledMoveNumber`. -/
  disabledMoveNumber : UInt8
  /-- `wPlayerSubstituteHP`. -/
  substituteHp : UInt8
  /-- `wPlayerBideAccumulatedDamage` (big-endian; unions with NumHits). -/
  bideAccumulated : UInt16
  deriving Repr, DecidableEq, BEq

/-- Switch-in state: every volatile byte and counter cleared. -/
def Volatile.clear : Volatile :=
  { status1 := 0, status2 := 0, status3 := 0, numAttacksLeft := 0,
    confusedCounter := 0, toxicCounter := 0, disabledMove := 0,
    disabledMoveNumber := 0, substituteHp := 0, bideAccumulated := 0 }

/-- Confused (`BattleStatus1` bit 7). -/
def Volatile.confused (v : Volatile) : Bool := bitSet v.status1 Wram.BattleStatus1.confused
/-- Flinched this turn (`BattleStatus1` bit 3). -/
def Volatile.flinched (v : Volatile) : Bool := bitSet v.status1 Wram.BattleStatus1.flinched
/-- Charging a two-turn move (`BattleStatus1` bit 4: Solar Beam / Fly / Dig / …). -/
def Volatile.chargingUp (v : Volatile) : Bool := bitSet v.status1 Wram.BattleStatus1.chargingUp
/-- Locked in a trapping move (`BattleStatus1` bit 5: Wrap / Bind / …). -/
def Volatile.trapping (v : Volatile) : Bool := bitSet v.status1 Wram.BattleStatus1.usingTrappingMove
/-- Has a Substitute up (`BattleStatus2` bit 4). -/
def Volatile.hasSubstitute (v : Volatile) : Bool := bitSet v.status2 Wram.BattleStatus2.hasSubstituteUp
/-- Must recharge (`BattleStatus2` bit 5: Hyper Beam). -/
def Volatile.recharging (v : Volatile) : Bool := bitSet v.status2 Wram.BattleStatus2.needsToRecharge
/-- Seeded (`BattleStatus2` bit 7: Leech Seed). -/
def Volatile.seeded (v : Volatile) : Bool := bitSet v.status2 Wram.BattleStatus2.seeded
/-- Badly poisoned / Toxic ramp (`BattleStatus3` bit 0). -/
def Volatile.badlyPoisoned (v : Volatile) : Bool := bitSet v.status3 Wram.BattleStatus3.badlyPoisoned

/-! ## Per-side and whole-battle state -/

/-- One side's live state: its active mon, that mon's stat-mod stages, and its
    volatile status. -/
structure SideState where
  active : BattleMon
  stages : StatStages
  volatile : Volatile
  deriving Repr, DecidableEq, BEq

/-- Fresh switch-in: the given mon with neutral stages and cleared volatiles. -/
def SideState.fresh (m : BattleMon) : SideState :=
  { active := m, stages := StatStages.neutral, volatile := Volatile.clear }

/-- The whole battle: both sides, the RNG cursor, the turn counter, the mode, and
    the episode phase. -/
structure BattleState where
  player : SideState
  enemy : SideState
  /-- The shared link-battle PRNG cursor (`Battle.Rng.LinkRng`). -/
  rng : Rng.LinkRng
  /-- Completed-turn counter (`Battle.Episode.State.turn`). -/
  turn : Nat
  mode : BattleMode
  phase : Outcome.EpisodePhase
  deriving Repr, DecidableEq

/-- The named side's state. -/
def BattleState.side : BattleState → Side → SideState
  | s, .player => s.player
  | s, .enemy => s.enemy

/-- Replace the named side's state. -/
def BattleState.setSide : BattleState → Side → SideState → BattleState
  | s, .player, ss => { s with player := ss }
  | s, .enemy, ss => { s with enemy := ss }

/-- The named side's active mon. -/
def BattleState.active (s : BattleState) (side : Side) : BattleMon := (s.side side).active

/-- Open a battle: both sides fresh, RNG seeded, turn 0, `battling`. -/
def BattleState.start (player enemy : BattleMon) (rng : Rng.LinkRng)
    (mode : BattleMode := .link) : BattleState :=
  { player := SideState.fresh player, enemy := SideState.fresh enemy,
    rng, turn := 0, mode, phase := .battling }

/-! ## Fidelity guards -/

/-- A representative active mon (Charizard-ish: Fire/Flying, one move with PP). -/
private def sampleMon : BattleMon :=
  { species := 6, hp := 100, boxLevel := 50, status := 0,
    type1 := 0x14, type2 := 0x02, catchRate := 45,
    moves := #[52, 0, 0, 0], dvs := 0xFFFF, level := 50,
    maxHp := 100, attack := 80, defense := 70, speed := 100, special := 90,
    pp := #[15, 0, 0, 0] }

-- Well-formedness and fainting.
#guard sampleMon.wf
#guard sampleMon.fainted == false
#guard { sampleMon with hp := 0 }.fainted == true
#guard { sampleMon with moves := #[52, 0, 0] }.wf == false   -- wrong array length

-- Non-volatile status decoding: sleep is a counter, the rest are flag bits.
#guard sampleMon.asleep == false
#guard { sampleMon with status := 0x02 }.asleep == true      -- sleep counter = 2
#guard { sampleMon with status := 0x02 }.poisoned == false
#guard { sampleMon with status := 0x08 }.poisoned == true    -- PSN, bit 3
#guard { sampleMon with status := 0x10 }.burned == true      -- BRN, bit 4
#guard { sampleMon with status := 0x20 }.frozen == true      -- FRZ, bit 5
#guard { sampleMon with status := 0x40 }.paralyzed == true   -- PAR, bit 6

-- Stat stages start neutral at 7 and are in range.
#guard StatStages.neutral.attack == 7
#guard StatStages.neutral.evasion == 7
#guard StatStages.neutral.wf
#guard { StatStages.neutral with attack := 13 }.wf
#guard { StatStages.neutral with attack := 0 }.wf == false   -- below 1
#guard { StatStages.neutral with speed := 14 }.wf == false   -- above 13

-- Volatile clears to all-zero and the bit accessors name the right bits.
#guard Volatile.clear.status1 == 0
#guard Volatile.clear.confused == false
#guard { Volatile.clear with status1 := 0x80 }.confused == true       -- bit 7
#guard { Volatile.clear with status1 := 0x08 }.flinched == true       -- bit 3
#guard { Volatile.clear with status2 := 0x10 }.hasSubstitute == true  -- bit 4
#guard { Volatile.clear with status2 := 0x20 }.recharging == true     -- bit 5
#guard { Volatile.clear with status2 := 0x80 }.seeded == true         -- bit 7
#guard { Volatile.clear with status3 := 0x01 }.badlyPoisoned == true  -- bit 0

-- Whole-battle assembly and side get/set.
private def sampleState : BattleState := BattleState.start sampleMon sampleMon Rng.seed0

#guard sampleState.turn == 0
#guard sampleState.phase.isTerminal == false
#guard (sampleState.active .player).hp == 100
#guard (sampleState.side .enemy).stages.attack == 7
#guard (sampleState.side .player).volatile.confused == false
-- setSide replaces only the named side.
#guard ((sampleState.setSide .player (SideState.fresh { sampleMon with hp := 7 })).active .player).hp == 7
#guard ((sampleState.setSide .player (SideState.fresh { sampleMon with hp := 7 })).active .enemy).hp == 100

end Battle
