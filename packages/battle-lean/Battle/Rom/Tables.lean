/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Rom.Closure
import Battle.Data.Moves
import Battle.Data.Species
import Battle.Data.Learnsets

/-!
# Canonical ROM battle-data decoders

This module decodes the fixed `Moves`, `BaseStats`, `PokedexOrder`, and
`EvosMovesPointerTable` ranges retained in `Rom.Closure.Symbols`. It also follows
the 190 evolution/learnset pointers, combines level-one moves and TM/HM flags
from base data, and closes move pools over pre-evolution edges.

The ROM itself remains caller-supplied. `RequiredTableBytes` is the proof
boundary: a hash-checking caller supplies exact byte-window/decoded-agreement
witnesses, just as `Rom.Closure.RequiredEntryBytes` does for executable entry
points. The executable fixture checks the same decoder against a temporary
canonical rebuild; no IO result is promoted into a theorem.
-/

namespace Battle.Rom.Tables

open Battle.Rom.Closure

/-! ## Raw byte access -/

@[inline] def byteAt (rom : Array Sm83.Byte) (offset : Nat) : UInt8 :=
  (GameBoy.Mbc3.readArray rom offset).toNat.toUInt8

@[inline] def tableBytes (rom : Array Sm83.Byte) (offset count : Nat) : List UInt8 :=
  (List.range count).map fun index => byteAt rom (offset + index)

/-! ## Move rows -/

/-- The complete six-byte ROM row. `id` is the animation/move id byte; `data`
is the five-byte model payload. -/
structure MoveRow where
  id : UInt8
  data : Data.MoveData
  deriving Repr, DecidableEq, BEq

def MoveRow.encodeList (row : MoveRow) : List UInt8 :=
  [row.id, row.data.effect, row.data.power, row.data.type, row.data.accuracy, row.data.pp]

def MoveRow.decodeList : List UInt8 → Option MoveRow
  | [id, effect, power, type, accuracy, pp] =>
      some { id, data := { effect, power, type, accuracy, pp } }
  | _ => none

@[simp] theorem MoveRow.decodeList_encodeList (row : MoveRow) :
    MoveRow.decodeList row.encodeList = some row := by
  cases row
  rfl

theorem MoveRow.encodeList_decodeList {bytes : List UInt8} {row : MoveRow}
    (decoded : MoveRow.decodeList bytes = some row) : row.encodeList = bytes := by
  unfold MoveRow.decodeList at decoded
  split at decoded
  · injection decoded with equality
    subst equality
    rfl
  · simp at decoded

/-- Decode one canonical move row by physical table index. -/
def decodeMoveRow (rom : Array Sm83.Byte) (index : Nat) : MoveRow :=
  let offset := Symbols.moves.offset + index * TableLayout.moveEntrySize
  { id := byteAt rom offset
    data :=
      { effect := byteAt rom (offset + 1)
        power := byteAt rom (offset + 2)
        type := byteAt rom (offset + 3)
        accuracy := byteAt rom (offset + 4)
        pp := byteAt rom (offset + 5) } }

def decodeMoveRows (rom : Array Sm83.Byte) : Array MoveRow :=
  (List.range TableLayout.moveCount).map (decodeMoveRow rom) |>.toArray

def decodeMoves (rom : Array Sm83.Byte) : Array Data.MoveData :=
  (decodeMoveRows rom).map (·.data)

/-- Every canonical move row carries its one-based table id. -/
def moveIdsSequential (rom : Array Sm83.Byte) : Bool :=
  (decodeMoveRows rom).toList.zipIdx.all fun indexed =>
    indexed.1.id == (indexed.2 + 1).toUInt8

/-! ## Base-stat rows -/

/-- One complete 28-byte `BASE_DATA_SIZE` row. Fields not interpreted by the
battle model are retained individually so the row codec remains lossless. -/
structure BaseStatsRow where
  data : Data.SpeciesData
  spriteSize : UInt8
  frontLo : UInt8
  frontHi : UInt8
  backLo : UInt8
  backHi : UInt8
  move0 : UInt8
  move1 : UInt8
  move2 : UInt8
  move3 : UInt8
  growthRate : UInt8
  tmhm0 : UInt8
  tmhm1 : UInt8
  tmhm2 : UInt8
  tmhm3 : UInt8
  tmhm4 : UInt8
  tmhm5 : UInt8
  tmhm6 : UInt8
  padding : UInt8
  deriving Repr, DecidableEq, BEq

/-- Exact stored order from `pokemon_data_constants.asm`. -/
def BaseStatsRow.encodeList (row : BaseStatsRow) : List UInt8 :=
  [ row.data.dexNum, row.data.baseHp, row.data.baseAtk, row.data.baseDef,
    row.data.baseSpd, row.data.baseSpc, row.data.type1, row.data.type2,
    row.data.catchRate, row.data.baseExp, row.spriteSize,
    row.frontLo, row.frontHi, row.backLo, row.backHi,
    row.move0, row.move1, row.move2, row.move3, row.growthRate,
    row.tmhm0, row.tmhm1, row.tmhm2, row.tmhm3, row.tmhm4, row.tmhm5,
    row.tmhm6, row.padding ]

def BaseStatsRow.decodeList : List UInt8 → Option BaseStatsRow
  | [ dexNum, baseHp, baseAtk, baseDef, baseSpd, baseSpc, type1, type2,
      catchRate, baseExp, spriteSize, frontLo, frontHi, backLo, backHi,
      move0, move1, move2, move3, growthRate,
      tmhm0, tmhm1, tmhm2, tmhm3, tmhm4, tmhm5, tmhm6, padding ] =>
      some {
        data := {
          dexNum := dexNum
          baseHp := baseHp
          baseAtk := baseAtk
          baseDef := baseDef
          baseSpd := baseSpd
          baseSpc := baseSpc
          type1 := type1
          type2 := type2
          catchRate := catchRate
          baseExp := baseExp }
        spriteSize := spriteSize
        frontLo := frontLo
        frontHi := frontHi
        backLo := backLo
        backHi := backHi
        move0 := move0
        move1 := move1
        move2 := move2
        move3 := move3
        growthRate := growthRate
        tmhm0 := tmhm0
        tmhm1 := tmhm1
        tmhm2 := tmhm2
        tmhm3 := tmhm3
        tmhm4 := tmhm4
        tmhm5 := tmhm5
        tmhm6 := tmhm6
        padding := padding }
  | _ => none

@[simp] theorem BaseStatsRow.decodeList_encodeList (row : BaseStatsRow) :
    BaseStatsRow.decodeList row.encodeList = some row := by
  cases row
  case mk data => cases data; rfl

theorem BaseStatsRow.encodeList_decodeList {bytes : List UInt8} {row : BaseStatsRow}
    (decoded : BaseStatsRow.decodeList bytes = some row) : row.encodeList = bytes := by
  unfold BaseStatsRow.decodeList at decoded
  split at decoded
  · injection decoded with equality
    subst equality
    rfl
  · simp at decoded

/-- Decode a complete base-data row at a physical offset. -/
def decodeBaseStatsRowAt (rom : Array Sm83.Byte) (offset : Nat) : BaseStatsRow :=
  { data :=
      { dexNum := byteAt rom offset
        baseHp := byteAt rom (offset + 1)
        baseAtk := byteAt rom (offset + 2)
        baseDef := byteAt rom (offset + 3)
        baseSpd := byteAt rom (offset + 4)
        baseSpc := byteAt rom (offset + 5)
        type1 := byteAt rom (offset + 6)
        type2 := byteAt rom (offset + 7)
        catchRate := byteAt rom (offset + 8)
        baseExp := byteAt rom (offset + 9) }
    spriteSize := byteAt rom (offset + 10)
    frontLo := byteAt rom (offset + 11)
    frontHi := byteAt rom (offset + 12)
    backLo := byteAt rom (offset + 13)
    backHi := byteAt rom (offset + 14)
    move0 := byteAt rom (offset + 15)
    move1 := byteAt rom (offset + 16)
    move2 := byteAt rom (offset + 17)
    move3 := byteAt rom (offset + 18)
    growthRate := byteAt rom (offset + 19)
    tmhm0 := byteAt rom (offset + 20)
    tmhm1 := byteAt rom (offset + 21)
    tmhm2 := byteAt rom (offset + 22)
    tmhm3 := byteAt rom (offset + 23)
    tmhm4 := byteAt rom (offset + 24)
    tmhm5 := byteAt rom (offset + 25)
    tmhm6 := byteAt rom (offset + 26)
    padding := byteAt rom (offset + 27) }

def decodeOrdinaryBaseStatsRows (rom : Array Sm83.Byte) : Array BaseStatsRow :=
  ((List.range TableLayout.ordinaryBaseStatsCount).map fun index =>
    decodeBaseStatsRowAt rom
      (Symbols.baseStats.offset + index * TableLayout.baseStatsEntrySize)).toArray

def decodeMewBaseStatsRow (rom : Array Sm83.Byte) : BaseStatsRow :=
  decodeBaseStatsRowAt rom Symbols.mewBaseStats.offset

/-- National-dex order: the contiguous 150 rows followed by detached Mew. -/
def decodeBaseStatsRows (rom : Array Sm83.Byte) : Array BaseStatsRow :=
  (decodeOrdinaryBaseStatsRows rom).push (decodeMewBaseStatsRow rom)

def decodeBaseStats (rom : Array Sm83.Byte) : Array Data.SpeciesData :=
  (decodeBaseStatsRows rom).map (·.data)

def BaseStatsRow.initialMoves (row : BaseStatsRow) : List UInt8 :=
  [row.move0, row.move1, row.move2, row.move3].filter (· != 0)

def BaseStatsRow.tmhmBytes (row : BaseStatsRow) : Array UInt8 :=
  #[row.tmhm0, row.tmhm1, row.tmhm2, row.tmhm3, row.tmhm4, row.tmhm5, row.tmhm6]

/-! ## Internal-index order and evolution pointers -/

def decodePokedexOrder (rom : Array Sm83.Byte) : Array UInt8 :=
  ((List.range TableLayout.pokedexOrderSize).map fun index =>
    byteAt rom (Symbols.pokedexOrder.offset + index)).toArray

/-- A raw little-endian pointer into bank `$0E`. Storing both bytes makes the
pointer codec lossless even for malformed addresses. -/
structure EvosMovesPointer where
  low : UInt8
  high : UInt8
  deriving Repr, DecidableEq, BEq

def EvosMovesPointer.address (pointer : EvosMovesPointer) : UInt16 :=
  pointer.low.toUInt16 ||| (pointer.high.toUInt16 <<< 8)

def EvosMovesPointer.encodeList (pointer : EvosMovesPointer) : List UInt8 :=
  [pointer.low, pointer.high]

def EvosMovesPointer.decodeList : List UInt8 → Option EvosMovesPointer
  | [low, high] => some { low, high }
  | _ => none

@[simp] theorem EvosMovesPointer.decodeList_encodeList (pointer : EvosMovesPointer) :
    EvosMovesPointer.decodeList pointer.encodeList = some pointer := by
  cases pointer
  rfl

theorem EvosMovesPointer.encodeList_decodeList {bytes : List UInt8}
    {pointer : EvosMovesPointer}
    (decoded : EvosMovesPointer.decodeList bytes = some pointer) :
    pointer.encodeList = bytes := by
  unfold EvosMovesPointer.decodeList at decoded
  split at decoded
  · injection decoded with equality
    subst equality
    rfl
  · simp at decoded

def decodeEvosMovesPointers (rom : Array Sm83.Byte) : Array EvosMovesPointer :=
  ((List.range TableLayout.speciesIndexCount).map fun index =>
    let offset := Symbols.evosMovesPointerTable.offset + index * 2
    ({ low := byteAt rom offset, high := byteAt rom (offset + 1) } :
      EvosMovesPointer)).toArray

def evosMovesPointersInRange (rom : Array Sm83.Byte) : Bool :=
  (decodeEvosMovesPointers rom).all fun pointer =>
    Symbols.evosMovesData.address.toNat ≤ pointer.address.toNat &&
      pointer.address.toNat < 0x79EC

/-! ## Evolution/level-up payloads -/

structure Evolution where
  target : UInt8
  deriving Repr, DecidableEq, BEq

structure EvosMoves where
  evolutions : List Evolution
  levelMoves : List UInt8
  deriving Repr, DecidableEq, BEq

private def parseEvolutions (rom : Array Sm83.Byte) : Nat → Nat →
    Option (List Evolution × Nat)
  | _, 0 => none
  | offset, fuel + 1 =>
      let tag := byteAt rom offset
      if tag == 0 then
        some ([], offset + 1)
      else if tag == 1 then
        match parseEvolutions rom (offset + 3) fuel with
        | some (tail, next) => some ({ target := byteAt rom (offset + 2) } :: tail, next)
        | none => none
      else if tag == 2 then
        match parseEvolutions rom (offset + 4) fuel with
        | some (tail, next) => some ({ target := byteAt rom (offset + 3) } :: tail, next)
        | none => none
      else if tag == 3 then
        match parseEvolutions rom (offset + 3) fuel with
        | some (tail, next) => some ({ target := byteAt rom (offset + 2) } :: tail, next)
        | none => none
      else
        none

private def parseLevelMoves (rom : Array Sm83.Byte) : Nat → Nat → Option (List UInt8)
  | _, 0 => none
  | offset, fuel + 1 =>
      if byteAt rom offset == 0 then
        some []
      else
        match parseLevelMoves rom (offset + 2) fuel with
        | some tail => some (byteAt rom (offset + 1) :: tail)
        | none => none

def decodeEvosMovesAt (rom : Array Sm83.Byte) (pointer : EvosMovesPointer) :
    Option EvosMoves := do
  guard (Symbols.evosMovesData.address.toNat ≤ pointer.address.toNat)
  guard (pointer.address.toNat < 0x79EC)
  let offset := romOffset Symbols.evosMovesPointerTable.bank.toNat
    (Sm83.Word.ofNat pointer.address.toNat)
  let (evolutions, movesOffset) ← parseEvolutions rom offset 16
  let levelMoves ← parseLevelMoves rom movesOffset 64
  pure { evolutions, levelMoves }

def decodeEvosMoves (rom : Array Sm83.Byte) : Array (Option EvosMoves) :=
  (decodeEvosMovesPointers rom).map (decodeEvosMovesAt rom)

/-! ## Derived legal move pools -/

/-- `TM01..TM50` followed by `HM01..HM05`, in base-data flag order. -/
def tmhmMoves : Array UInt8 := #[
  5, 13, 14, 18, 25, 92, 32, 34, 36, 38,
  61, 55, 58, 59, 63, 6, 66, 68, 69, 99,
  72, 76, 82, 85, 87, 89, 90, 91, 94, 100,
  102, 104, 115, 117, 118, 120, 121, 126, 129, 130,
  135, 138, 143, 156, 86, 149, 153, 157, 161, 164,
  15, 19, 57, 70, 148 ]

@[simp] theorem tmhmMoves_size : tmhmMoves.size = 55 := by native_decide

def BaseStatsRow.tmhmMoves (row : BaseStatsRow) : List UInt8 :=
  (List.range Battle.Rom.Tables.tmhmMoves.size).filterMap fun index =>
    let flags := row.tmhmBytes.getD (index / 8) 0
    if flags.toNat.testBit (index % 8) then
      some (Battle.Rom.Tables.tmhmMoves.getD index 0)
    else none

/-- Sorted, duplicate-free, nonzero move IDs. Enumerating the finite byte range
avoids assigning an order law to malformed input values. -/
def normalizeMoves (moves : List UInt8) : List UInt8 :=
  (List.range 256).filterMap fun value =>
    let move := value.toUInt8
    if value != 0 && moves.contains move then some move else none

private def rowForInternal (rows : Array BaseStatsRow) (order : Array UInt8)
    (internal : Nat) : Option BaseStatsRow :=
  if internal == 0 then none
  else
    let dex := order.getD (internal - 1) 0
    if dex == 0 then none else rows[dex.toNat - 1]?

private def directMovePools (rom : Array Sm83.Byte) : Array (List UInt8) :=
  let rows := decodeBaseStatsRows rom
  let order := decodePokedexOrder rom
  let evos := decodeEvosMoves rom
  ((List.range (TableLayout.speciesIndexCount + 1)).map fun internal =>
    match rowForInternal rows order internal with
    | none => []
    | some row =>
        let levelMoves :=
          if internal == 0 then []
          else match evos[internal - 1]? with
            | some (some entry) => entry.levelMoves
            | _ => []
        normalizeMoves (row.initialMoves ++ levelMoves ++ row.tmhmMoves)).toArray

private def evolutionEdges (rom : Array Sm83.Byte) : List (Nat × Nat) :=
  (decodeEvosMoves rom).toList.zipIdx.flatMap fun indexed =>
    match indexed.1 with
    | none => []
    | some entry => entry.evolutions.map fun evolution =>
        (indexed.2 + 1, evolution.target.toNat)

private def inheritedPool (direct : Array (List UInt8)) (edges : List (Nat × Nat))
    (internal : Nat) : Nat → List UInt8
  | 0 => direct.getD internal []
  | fuel + 1 =>
      let parents := edges.filter (fun edge => edge.2 == internal)
      normalizeMoves <| direct.getD internal [] ++
        parents.flatMap fun edge => inheritedPool direct edges edge.1 fuel

/-- Reconstruct `Battle.Data.learnPools`: direct level-one/level-up/TM-HM moves,
closed transitively over all pre-evolution edges. Entry zero is `NO_MON`; entries
1..190 are internal species indices, including empty glitch slots. -/
def decodeLearnPools (rom : Array Sm83.Byte) : Array (Array UInt8) :=
  let direct := directMovePools rom
  let edges := evolutionEdges rom
  ((List.range (TableLayout.speciesIndexCount + 1)).map fun internal =>
    (inheritedPool direct edges internal TableLayout.speciesIndexCount).toArray).toArray

/-! ## Caller-supplied proof certificate -/

/-- Exact canonical table witnesses. The byte equalities retain uninterpreted
fields, while the agreement fields state that the executable decoders recover
the independently authored model tables. A caller constructs this only after
hash-checking the complete ROM and checking these finite windows. -/
structure RequiredTableBytes (rom : Array Sm83.Byte) : Prop where
  movesWindow : tableBytes rom Symbols.moves.offset TableLayout.movesSize =
    (decodeMoveRows rom).toList.flatMap MoveRow.encodeList
  moveIds : moveIdsSequential rom = true
  moves : decodeMoves rom = Data.moves
  ordinaryBaseStatsWindow :
    tableBytes rom Symbols.baseStats.offset TableLayout.ordinaryBaseStatsSize =
      (decodeOrdinaryBaseStatsRows rom).toList.flatMap BaseStatsRow.encodeList
  mewBaseStatsWindow :
    tableBytes rom Symbols.mewBaseStats.offset TableLayout.baseStatsEntrySize =
      (decodeMewBaseStatsRow rom).encodeList
  baseStats : decodeBaseStats rom = Data.baseStats
  pokedexOrderWindow :
    tableBytes rom Symbols.pokedexOrder.offset TableLayout.pokedexOrderSize =
      (decodePokedexOrder rom).toList
  pokedexOrder : decodePokedexOrder rom = Data.pokedexOrder
  evosMovesPointerWindow :
    tableBytes rom Symbols.evosMovesPointerTable.offset TableLayout.evosMovesPointerSize =
      (decodeEvosMovesPointers rom).toList.flatMap EvosMovesPointer.encodeList
  evosMovesPointers : evosMovesPointersInRange rom = true
  learnPools : decodeLearnPools rom = Data.learnPools

/-- The single certificate exposes ROM agreement to all model consumers. -/
theorem certified_tables {rom : Array Sm83.Byte} (certificate : RequiredTableBytes rom) :
    decodeMoves rom = Data.moves ∧
      decodeBaseStats rom = Data.baseStats ∧
      decodePokedexOrder rom = Data.pokedexOrder ∧
      decodeLearnPools rom = Data.learnPools :=
  ⟨certificate.moves, certificate.baseStats, certificate.pokedexOrder,
    certificate.learnPools⟩

/-- Runtime version used only by the temporary-ROM integration fixture. -/
def agreesWithAuthored (rom : Array Sm83.Byte) : Bool :=
  moveIdsSequential rom &&
    decodeMoves rom == Data.moves &&
    decodeBaseStats rom == Data.baseStats &&
    decodePokedexOrder rom == Data.pokedexOrder &&
    evosMovesPointersInRange rom &&
    decodeLearnPools rom == Data.learnPools

end Battle.Rom.Tables
