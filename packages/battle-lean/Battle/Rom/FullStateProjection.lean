/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0.
-/
import Battle.Codec
import Battle.Full.Environment
import Battle.GameBoy.Adapter

/-!
# Machine-to-model active battle-struct projection

This module gives the ROM side and the full model a shared, lossless checkpoint
relation for both live 29-byte battle structs. It is intentionally narrower than
a whole-turn refinement: party storage, volatile scratch, RNG observations, and
control location need their own relations before a complete battle step can use
this checkpoint.
-/

namespace Battle.Rom.FullStateProjection

open Sm83 Battle Battle.Full

abbrev Machine := GameBoy.Adapter.Machine

/-- Canonical WRAM bases from the retained Red map. -/
def playerBattleMon : Word := 0xD014
def enemyBattleMon : Word := 0xCFE5

/-- Read a fixed contiguous byte block through the actual Game Boy memory map. -/
def readBlock (memory : GameBoy.Memory.State) (base : Word) (length : Nat) : Bytes :=
  (Array.range length).map fun offset =>
    (GameBoy.Memory.read memory (Word.ofNat (base.toNat + offset))).toNat.toUInt8

@[simp] theorem readBlock_size (memory : GameBoy.Memory.State) (base : Word)
    (length : Nat) : (readBlock memory base length).size = length := by
  simp [readBlock]

/-- Numeric semantic view of the lossless byte-oriented active-mon codec. -/
def toMonState (raw : BattleMon) : MonState :=
  { species := raw.species
    hp := raw.hp
    boxLevel := raw.boxLevel
    status := raw.status
    type1 := raw.type1
    type2 := raw.type2
    catchRate := raw.catchRate
    moves := #[raw.move0, raw.move1, raw.move2, raw.move3]
    dvs := beWord raw.dv0 raw.dv1
    level := raw.level
    maxHp := raw.maxHp
    attack := raw.attack
    defense := raw.defense
    speed := raw.speed
    special := raw.special
    pp := #[raw.pp0, raw.pp1, raw.pp2, raw.pp3] }

@[simp] theorem toMonState_wf (raw : BattleMon) : (toMonState raw).wf = true := by
  simp [toMonState, MonState.wf, Wram.numMoves]

/-- Decode one live battle struct directly from mapped WRAM. -/
def decodeAt (machine : Machine) (base : Word) : Option BattleMon :=
  BattleMon.decode (readBlock machine.memory base Wram.battleStructLength)

/-- The machine and model agree on both live active battle structs. The relation
retains the byte-oriented codec witness instead of comparing only HP/species. -/
structure ActiveStructs (machine : Machine) (state : Full.Environment.State) where
  playerRaw : BattleMon
  enemyRaw : BattleMon
  playerDecoded : decodeAt machine playerBattleMon = some playerRaw
  enemyDecoded : decodeAt machine enemyBattleMon = some enemyRaw
  playerAgrees : toMonState playerRaw = state.engine.battle.player.active.active
  enemyAgrees : toMonState enemyRaw = state.engine.battle.enemy.active.active

/-- Proposition-valued relation used by later low-to-high simulations. The
certificate form above retains the two decoded raw witnesses for local proofs. -/
def Related (machine : Machine) (state : Full.Environment.State) : Prop :=
  Nonempty (ActiveStructs machine state)

/-- A successful mapped decode determines every one of the 29 source bytes. -/
theorem decoded_bytes_exact {machine : Machine} {base : Word} {raw : BattleMon}
    (decoded : decodeAt machine base = some raw) :
    raw.encode = readBlock machine.memory base Wram.battleStructLength := by
  exact BattleMon.encode_decode decoded

/-- The relation exposes exact byte equality for both active structs. -/
theorem ActiveStructs.exact_bytes {machine : Machine}
    {state : Full.Environment.State} (related : ActiveStructs machine state) :
    related.playerRaw.encode =
        readBlock machine.memory playerBattleMon Wram.battleStructLength ∧
      related.enemyRaw.encode =
        readBlock machine.memory enemyBattleMon Wram.battleStructLength :=
  ⟨decoded_bytes_exact related.playerDecoded,
    decoded_bytes_exact related.enemyDecoded⟩

/-- One decoded raw struct cannot represent two different semantic active mons. -/
theorem semantic_projection_unique {raw : BattleMon} {left right : MonState}
    (leftAgreement : toMonState raw = left)
    (rightAgreement : toMonState raw = right) : left = right := by
  rw [← leftAgreement, ← rightAgreement]

/-- The player HP relation reads both big-endian WRAM bytes, not a summarized
fixture value. -/
theorem ActiveStructs.player_hp {machine : Machine}
    {state : Full.Environment.State} (related : ActiveStructs machine state) :
    related.playerRaw.hp = state.engine.battle.player.active.active.hp := by
  simpa [toMonState] using congrArg MonState.hp related.playerAgrees

/-- The enemy HP relation has the same exact big-endian interpretation. -/
theorem ActiveStructs.enemy_hp {machine : Machine}
    {state : Full.Environment.State} (related : ActiveStructs machine state) :
    related.enemyRaw.hp = state.engine.battle.enemy.active.active.hp := by
  simpa [toMonState] using congrArg MonState.hp related.enemyAgrees

#guard playerBattleMon == 0xD014
#guard enemyBattleMon == 0xCFE5

end Battle.Rom.FullStateProjection
