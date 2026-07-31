/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0.
-/
import Battle.DriverInvariant
import Battle.Full.Link
import Battle.GameBoy.LinkAdapter
import Battle.Rom.FullStateProjection

/-!
# Paired link-state projection

This module is the first two-cartridge checkpoint relation for the training
profile.  It reads each endpoint through the mapped Game Boy memory interface
and relates the live active structs, link-mode selector, and complete ten-byte
`BattleRandom` state to that endpoint's independent `Full.Link.Perspective`.

It deliberately does not yet relate persistent party rows, volatile scratch,
serial transfer phase, or the fetched control location.  Those fields must be
added before this checkpoint can support a whole-turn simulation.
-/

namespace Battle.Rom.LinkStateProjection

open Sm83 Battle Battle.Full

abbrev Machine := GameBoy.Adapter.Machine

/-- Physical pair with cartridge clock ownership retained independently of the
high-level pair.  The roles are not inferred from a transient `$FF02` value. -/
abbrev MachinePair := GameBoy.LinkAdapter.Machine

def semanticRole : GameBoy.Devices.CableClockRole → Full.Link.ClockRole
  | .internal => .internal
  | .external => .external

/-- Canonical WRAM locations used by the link-only checkpoint. -/
def linkState : Word := 0xD12B
def randomList : Word := 0xD148
def randomIndex : Word := 0xCCDE

def playerPartyCount : Word := 0xD163
def playerPartyMons : Word := 0xD16B
def enemyPartyCount : Word := 0xD89C
def enemyPartyMons : Word := 0xD8A4
def playerActiveIndex : Word := 0xCC2F
def enemyActiveIndex : Word := 0xCFE8

structure RuntimeAddresses where
  unmodified : Word
  stages : Word
  status : Word
  attacksLeft : Word
  confused : Word
  toxic : Word
  disabled : Word
  disabledNumber : Word
  substituteHp : Word
  bideDamage : Word
  minimized : Word
  originalSpecies : Word

def playerRuntime : RuntimeAddresses :=
  { unmodified := 0xCD12, stages := 0xCD1A, status := 0xD062
    attacksLeft := 0xD06A, confused := 0xD06B, toxic := 0xD06C
    disabled := 0xD06D, disabledNumber := 0xCCEE
    substituteHp := 0xCCD7, bideDamage := 0xD074
    minimized := 0xCCF7, originalSpecies := 0xCFD9 }

def enemyRuntime : RuntimeAddresses :=
  { unmodified := 0xCD26, stages := 0xCD2E, status := 0xD067
    attacksLeft := 0xD06F, confused := 0xD070, toxic := 0xD071
    disabled := 0xD072, disabledNumber := 0xCCEF
    substituteHp := 0xCCD8, bideDamage := 0xCD05
    minimized := 0xCCF3, originalSpecies := 0xCFD8 }

@[inline] def readU8 (machine : Machine) (address : Word) : UInt8 :=
  (GameBoy.Memory.read machine.memory address).toNat.toUInt8

@[inline] def readOffset (machine : Machine) (base : Word) (offset : Nat) : UInt8 :=
  readU8 machine (Word.ofNat (base.toNat + offset))

@[inline] def readBeWord (machine : Machine) (base : Word) : UInt16 :=
  beWord (readOffset machine base 0) (readOffset machine base 1)

/-- Decode the four dedicated unmodified stat words. -/
def decodeUnmodified (machine : Machine) (addresses : RuntimeAddresses) : CombatStats :=
  { attack := readBeWord machine addresses.unmodified
    defense := readBeWord machine (Word.ofNat (addresses.unmodified.toNat + 2))
    speed := readBeWord machine (Word.ofNat (addresses.unmodified.toNat + 4))
    special := readBeWord machine (Word.ofNat (addresses.unmodified.toNat + 6)) }

/-- Decode all eight stage bytes, including the two nominal padding entries. -/
def decodeStages (machine : Machine) (addresses : RuntimeAddresses) : StatStages :=
  { attack := readOffset machine addresses.stages 0
    defense := readOffset machine addresses.stages 1
    speed := readOffset machine addresses.stages 2
    special := readOffset machine addresses.stages 3
    accuracy := readOffset machine addresses.stages 4
    evasion := readOffset machine addresses.stages 5
    padding0 := readOffset machine addresses.stages 6
    padding1 := readOffset machine addresses.stages 7 }

/-- Decode the complete side-specific volatile state, preserving raw status
bytes, stale counters, and malformed bit combinations. -/
def decodeVolatile (machine : Machine) (addresses : RuntimeAddresses) : Volatile :=
  { status1 := readOffset machine addresses.status 0
    status2 := readOffset machine addresses.status 1
    status3 := readOffset machine addresses.status 2
    numAttacksLeft := readU8 machine addresses.attacksLeft
    confusedCounter := readU8 machine addresses.confused
    toxicCounter := readU8 machine addresses.toxic
    disabledMove := readU8 machine addresses.disabled
    disabledMoveNumber := readU8 machine addresses.disabledNumber
    substituteHp := readU8 machine addresses.substituteHp
    bideAccumulated := readBeWord machine addresses.bideDamage
    minimized := readU8 machine addresses.minimized != 0 }

/-- Read the exact cartridge link RNG image: ten bytes, including the vestigial
last byte, plus the separately located cursor. -/
def decodeRng (machine : Machine) : Rng.LinkRng :=
  Rng.LinkRng.ofWram
    (FullStateProjection.readBlock machine.memory randomList Wram.serialRnsLength)
    (GameBoy.Memory.read machine.memory randomIndex).toNat.toUInt8

@[simp] theorem decodeRng_list (machine : Machine) :
    (decodeRng machine).list =
      FullStateProjection.readBlock machine.memory randomList Wram.serialRnsLength := by
  rfl

@[simp] theorem decodeRng_index (machine : Machine) :
    (decodeRng machine).index =
      (GameBoy.Memory.read machine.memory randomIndex).toNat := by
  simp [decodeRng, Rng.LinkRng.ofWram]

@[simp] theorem decodeRng_list_size (machine : Machine) :
    (decodeRng machine).list.size = Wram.serialRnsLength := by
  rw [decodeRng_list]
  exact FullStateProjection.readBlock_size _ _ _

/-- Semantic projection of the battle-relevant fields in one exact 44-byte
`party_struct`. Experience, stat experience, and OT bytes remain preserved in
the raw witness even though the link mechanics state does not interpret them. -/
def partyMonState (raw : PartyMonBlock) : MonState :=
  let byte := fun index => raw.bytes.getD index 0
  { species := byte 0
    hp := beWord (byte 1) (byte 2)
    boxLevel := byte 3
    status := byte 4
    type1 := byte 5
    type2 := byte 6
    catchRate := byte 7
    moves := #[byte 8, byte 9, byte 10, byte 11]
    dvs := beWord (byte 27) (byte 28)
    pp := #[byte 29, byte 30, byte 31, byte 32]
    level := byte 33
    maxHp := beWord (byte 34) (byte 35)
    attack := beWord (byte 36) (byte 37)
    defense := beWord (byte 38) (byte 39)
    speed := beWord (byte 40) (byte 41)
    special := beWord (byte 42) (byte 43) }

@[simp] theorem partyMonState_wf (raw : PartyMonBlock) :
    (partyMonState raw).wf = true := by
  simp [partyMonState, MonState.wf, Wram.numMoves]

/-- Decode one indexed persistent party row directly from mapped WRAM. -/
def decodePartyAt (machine : Machine) (base : Word) (index : Nat) :
    Option PartyMonBlock :=
  PartyMonBlock.decode (FullStateProjection.readBlock machine.memory
    (Word.ofNat (base.toNat + index * Wram.partyStructLength))
    Wram.partyStructLength)

/-- Exact persistent-party relation for one local or remote side. -/
structure PartyRows (machine : Machine) (countBase monsBase : Word)
    (side : Full.SideState) where
  countAgrees :
    (GameBoy.Memory.read machine.memory countBase).toNat.toUInt8 =
      side.party.mons.size.toUInt8
  nonempty : 1 ≤ side.party.mons.size
  bounded : side.party.mons.size ≤ Wram.partyLength
  raw : (index : Fin side.party.mons.size) → PartyMonBlock
  decoded : ∀ index,
    decodePartyAt machine monsBase index.val = some (raw index)
  agrees : ∀ index, partyMonState (raw index) = side.party.mons[index]

/-- Every related party row retains its exact 44 source bytes. -/
theorem PartyRows.row_bytes_exact {machine : Machine} {countBase monsBase : Word}
    {side : Full.SideState}
    (related : PartyRows machine countBase monsBase side)
    (index : Fin side.party.mons.size) :
    (related.raw index).encode = FullStateProjection.readBlock machine.memory
      (Word.ofNat (monsBase.toNat + index.val * Wram.partyStructLength))
      Wram.partyStructLength := by
  exact PartyMonBlock.encode_decode (related.decoded index)

/-- One physical cartridge agrees with one semantic cartridge perspective.
The raw witnesses retain both live active structs and all persistent party rows
instead of comparing only selected fields. -/
structure Endpoint (machine : Machine) (high : Full.Link.Perspective) where
  playerRaw : BattleMon
  enemyRaw : BattleMon
  playerDecoded :
    FullStateProjection.decodeAt machine FullStateProjection.playerBattleMon =
      some playerRaw
  enemyDecoded :
    FullStateProjection.decodeAt machine FullStateProjection.enemyBattleMon =
      some enemyRaw
  playerAgrees :
    FullStateProjection.toActiveMonState playerRaw
        high.engine.battle.player.active.active.boxLevel =
      high.engine.battle.player.active.active
  enemyAgrees :
    FullStateProjection.toActiveMonState enemyRaw
        high.engine.battle.enemy.active.active.boxLevel =
      high.engine.battle.enemy.active.active
  playerPartyPosition :
    playerRaw.boxLevel = high.engine.battle.player.active.partyPosition
  enemyPartyPosition :
    enemyRaw.boxLevel = high.engine.battle.enemy.active.partyPosition
  localParty : PartyRows machine playerPartyCount playerPartyMons
    high.engine.battle.player
  remoteParty : PartyRows machine enemyPartyCount enemyPartyMons
    high.engine.battle.enemy
  localIndex :
    (GameBoy.Memory.read machine.memory playerActiveIndex).toNat =
      high.engine.battle.player.activeIndex
  remoteIndex :
    (GameBoy.Memory.read machine.memory enemyActiveIndex).toNat =
      high.engine.battle.enemy.activeIndex
  playerPositionIndex :
    high.engine.battle.player.active.partyPosition.toNat =
      high.engine.battle.player.activeIndex
  enemyPositionIndex :
    high.engine.battle.enemy.active.partyPosition.toNat =
      high.engine.battle.enemy.activeIndex
  playerUnmodified :
    decodeUnmodified machine playerRuntime = high.engine.battle.player.active.unmodified
  enemyUnmodified :
    decodeUnmodified machine enemyRuntime = high.engine.battle.enemy.active.unmodified
  playerStages :
    decodeStages machine playerRuntime = high.engine.battle.player.active.stages
  enemyStages :
    decodeStages machine enemyRuntime = high.engine.battle.enemy.active.stages
  playerVolatile :
    decodeVolatile machine playerRuntime = high.engine.battle.player.active.volatile
  enemyVolatile :
    decodeVolatile machine enemyRuntime = high.engine.battle.enemy.active.volatile
  playerOriginalSpecies :
    readU8 machine playerRuntime.originalSpecies =
      high.engine.battle.player.active.originalSpecies
  enemyOriginalSpecies :
    readU8 machine enemyRuntime.originalSpecies =
      high.engine.battle.enemy.active.originalSpecies
  linkSelected :
    (GameBoy.Memory.read machine.memory linkState).toNat.toUInt8 = Rng.linkStateByte
  highMode : high.engine.battle.mode = .link
  rngAgrees : decodeRng machine = high.engine.battle.rng

/-- Exact source bytes remain available to every later local simulation. -/
theorem Endpoint.active_bytes_exact {machine : Machine}
    {high : Full.Link.Perspective} (related : Endpoint machine high) :
    related.playerRaw.encode =
        FullStateProjection.readBlock machine.memory
          FullStateProjection.playerBattleMon Wram.battleStructLength ∧
      related.enemyRaw.encode =
        FullStateProjection.readBlock machine.memory
          FullStateProjection.enemyBattleMon Wram.battleStructLength := by
  exact ⟨FullStateProjection.decoded_bytes_exact related.playerDecoded,
    FullStateProjection.decoded_bytes_exact related.enemyDecoded⟩

/-- The RNG projection exposes all ten bytes and the exact cursor rather than a
software seed standing in for cartridge state. -/
theorem Endpoint.rng_bytes_exact {machine : Machine}
    {high : Full.Link.Perspective} (related : Endpoint machine high) :
    high.engine.battle.rng.list =
        FullStateProjection.readBlock machine.memory randomList Wram.serialRnsLength ∧
      high.engine.battle.rng.index =
        (GameBoy.Memory.read machine.memory randomIndex).toNat := by
  rw [← related.rngAgrees]
  exact ⟨decodeRng_list machine, decodeRng_index machine⟩

/-- Synchronized decision/entry checkpoint for two physical cartridges.  It
retains orientation and requires the semantic pair's synchronization predicates
explicitly; known link desynchronizations therefore cannot inhabit it. -/
structure Synchronized (low : MachinePair) (high : Full.Link.Pair) where
  leftRole : semanticRole low.leftRole = high.left.role
  rightRole : semanticRole low.rightRole = high.right.role
  complementaryRoles :
    (low.leftRole = .internal ∧ low.rightRole = .external) ∨
      (low.leftRole = .external ∧ low.rightRole = .internal)
  left : Endpoint low.left high.left
  right : Endpoint low.right high.right
  activeMirrored : Full.Link.mirroredActive high = true
  partiesMirrored : Full.Link.mirroredParties high = true
  indexesMirrored : Full.Link.mirroredActiveIndexes high = true
  rngMirrored : Full.Link.mirroredRng high = true
  phasesAgree : Full.Link.phasesAgree high = true

/-- The pair relation exposes both link-mode selectors, both complete RNG
images, orientation, and all three semantic synchronization invariants. -/
theorem Synchronized.exposes_pair {low : MachinePair} {high : Full.Link.Pair}
    (related : Synchronized low high) :
    (GameBoy.Memory.read low.left.memory linkState).toNat.toUInt8 = Rng.linkStateByte ∧
      (GameBoy.Memory.read low.right.memory linkState).toNat.toUInt8 = Rng.linkStateByte ∧
      decodeRng low.left = high.left.engine.battle.rng ∧
      decodeRng low.right = high.right.engine.battle.rng ∧
      Full.Link.mirroredActive high = true ∧
      Full.Link.mirroredParties high = true ∧
      Full.Link.mirroredActiveIndexes high = true ∧
      Full.Link.mirroredRng high = true ∧
      Full.Link.phasesAgree high = true := by
  exact ⟨related.left.linkSelected, related.right.linkSelected,
    related.left.rngAgrees, related.right.rngAgrees,
    related.activeMirrored, related.partiesMirrored, related.indexesMirrored,
    related.rngMirrored, related.phasesAgree⟩

/-- Named post-handshake whole-battle entry: both processors have fetched the
canonical `InitOpponent` instruction and the paired mechanics state is related.
This starts after cable-room negotiation but before battle-driver setup. -/
structure AtInitOpponent
    (low : MachinePair) (high : Full.Link.Pair)
    (leftBytes : Rom.Closure.RequiredEntryBytes low.left.memory.cartridge.rom)
    (rightBytes : Rom.Closure.RequiredEntryBytes low.right.memory.cartridge.rom) where
  synchronized : Synchronized low high
  leftReady : DriverInvariant.AtInitOpponentReady low.left leftBytes
  rightReady : DriverInvariant.AtInitOpponentReady low.right rightBytes

/-- Entry is non-vacuously tied to fetched canonical bytes on both cartridges. -/
theorem AtInitOpponent.canonical_opcodes
    {low : MachinePair} {high : Full.Link.Pair}
    {leftBytes : Rom.Closure.RequiredEntryBytes low.left.memory.cartridge.rom}
    {rightBytes : Rom.Closure.RequiredEntryBytes low.right.memory.cartridge.rom}
    (entry : AtInitOpponent low high leftBytes rightBytes) :
    low.left.core.ir = some {
        address := Rom.Closure.Symbols.initOpponent.address, byte := 0xFA } ∧
      low.right.core.ir = some {
        address := Rom.Closure.Symbols.initOpponent.address, byte := 0xFA } := by
  exact ⟨entry.leftReady.ir, entry.rightReady.ir⟩

#guard linkState == 0xD12B
#guard randomList == 0xD148
#guard randomIndex == 0xCCDE
#guard playerPartyCount == 0xD163
#guard playerPartyMons == 0xD16B
#guard enemyPartyCount == 0xD89C
#guard enemyPartyMons == 0xD8A4
#guard playerActiveIndex == 0xCC2F
#guard enemyActiveIndex == 0xCFE8
#guard playerRuntime.unmodified == 0xCD12
#guard playerRuntime.stages == 0xCD1A
#guard playerRuntime.status == 0xD062
#guard playerRuntime.bideDamage == 0xD074
#guard enemyRuntime.unmodified == 0xCD26
#guard enemyRuntime.stages == 0xCD2E
#guard enemyRuntime.status == 0xD067
#guard enemyRuntime.bideDamage == 0xCD05

end Battle.Rom.LinkStateProjection
