/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Wram
import Battle.Checkpoint

/-!
# The battle-state codec

The oracle emits raw `battle_struct` bytes (`wBattleMon` / `wEnemyMon`, 29 bytes);
the abstract model reasons over a typed `BattleMon`. This module is the bijection
between them — the codec proof-obligation named in GPT's battle-state-model. Its
whole reason to exist is that Lean sim traces must compare **byte-for-byte** with
ROM traces, so the typed view has to be provably lossless: nothing the ROM can
put in those 29 bytes may be dropped, reordered, or merged on the way in or out.

## Design: store bytes, view numbers

The `battle_struct` holds six **big-endian** 16-bit fields (HP and the five
computed stats; `macros/ram.asm`). Rather than store each as a `UInt16` — which
would make the round-trip hinge on a bitvector split/join identity
(`join (hi v) (lo v) = v`) that needs `bv_decide`/a SAT solver — `BattleMon`
stores each 16-bit field as its **two bytes in memory order** (`hpHi`, `hpLo`, …).

Consequences:

* `encode`/`decode` are a pure byte *permutation*: both round-trips reduce by
  `rfl`/`simp` with no arithmetic (`decode_encode`, `encode_decode` below).
* The endianness lives in the *numeric views* (`BattleMon.hp`, `.attack`, …),
  which reassemble the bytes big-endian. Those are validated by concrete
  `#guard`s (`beWord 0x01 0x2C = 300`), not a universal theorem — the codec's
  losslessness never depends on them.

Every byte is stored raw, so glitch/illegal states the ROM can reach — a status
byte with sleep-counter *and* a status flag set, an out-of-range species — round
-trip unchanged, honouring the "the ROM's behaviour is the spec" contract.

Byte arrays (`Moves`, `PP`) and the packed `DVs` are stored as raw bytes too;
move IDs are **decimal**, matching the doc convention, and need no transform.
Semantic unpackers (`ppCurrent`, `attackDV`, sleep counter, status flags) are
provided as views and pinned to the WRAM contract by `#guard`.
-/

namespace Battle

open Battle.Wram

/-! ## The typed active-mon record

One field per byte of `battleStructFields`, in address order. The six 16-bit
fields appear as `<name>Hi` / `<name>Lo` byte pairs (big-endian: `Hi` is the
lower address). -/

/-- The active-mon `battle_struct`, one Lean field per stored byte. -/
structure BattleMon where
  /-- `Species` @0. -/
  species : UInt8
  /-- `HP` high byte @1 (big-endian). -/
  hpHi : UInt8
  /-- `HP` low byte @2. -/
  hpLo : UInt8
  /-- `BoxLevel` / `PartyPos` @3. -/
  boxLevel : UInt8
  /-- `Status` @4 (raw; sleep counter and flags coexist). -/
  status : UInt8
  /-- `Type1` @5. -/
  type1 : UInt8
  /-- `Type2` @6. -/
  type2 : UInt8
  /-- `CatchRate` @7 (dead copy; live rate is `wEnemyMonActualCatchRate`). -/
  catchRate : UInt8
  /-- `Moves[0]` @8 (decimal move ID). -/
  move0 : UInt8
  /-- `Moves[1]` @9. -/
  move1 : UInt8
  /-- `Moves[2]` @10. -/
  move2 : UInt8
  /-- `Moves[3]` @11. -/
  move3 : UInt8
  /-- `DVs` byte 0 @12: Attack DV (hi nibble) / Defense DV (lo nibble). -/
  dv0 : UInt8
  /-- `DVs` byte 1 @13: Speed DV (hi nibble) / Special DV (lo nibble). -/
  dv1 : UInt8
  /-- `Level` @14. -/
  level : UInt8
  /-- `MaxHP` high byte @15 (big-endian). -/
  maxHpHi : UInt8
  /-- `MaxHP` low byte @16. -/
  maxHpLo : UInt8
  /-- `Attack` high byte @17 (big-endian). -/
  atkHi : UInt8
  /-- `Attack` low byte @18. -/
  atkLo : UInt8
  /-- `Defense` high byte @19 (big-endian). -/
  defHi : UInt8
  /-- `Defense` low byte @20. -/
  defLo : UInt8
  /-- `Speed` high byte @21 (big-endian). -/
  spdHi : UInt8
  /-- `Speed` low byte @22. -/
  spdLo : UInt8
  /-- `Special` high byte @23 (big-endian). -/
  spcHi : UInt8
  /-- `Special` low byte @24. -/
  spcLo : UInt8
  /-- `PP[0]` @25 (bits 0-5 current PP, bits 6-7 PP Ups). -/
  pp0 : UInt8
  /-- `PP[1]` @26. -/
  pp1 : UInt8
  /-- `PP[2]` @27. -/
  pp2 : UInt8
  /-- `PP[3]` @28. -/
  pp3 : UInt8
deriving Repr, DecidableEq, BEq

/-! ## The list codec

Encode/decode over `List UInt8` first: the decoder pattern-matches on exactly 29
elements, so both round-trips reduce structurally. The `Bytes` (array) codec is a
thin `toList`/`toArray` wrapper over these. -/

/-- Serialize a mon to its 29 `battle_struct` bytes, in address order. -/
def BattleMon.encodeList (m : BattleMon) : List UInt8 :=
  [ m.species, m.hpHi, m.hpLo, m.boxLevel, m.status, m.type1, m.type2, m.catchRate,
    m.move0, m.move1, m.move2, m.move3, m.dv0, m.dv1, m.level,
    m.maxHpHi, m.maxHpLo, m.atkHi, m.atkLo, m.defHi, m.defLo,
    m.spdHi, m.spdLo, m.spcHi, m.spcLo, m.pp0, m.pp1, m.pp2, m.pp3 ]

/-- Parse exactly 29 `battle_struct` bytes into a mon; any other length is `none`.
    The pattern reconstructs `encodeList` position-for-position, so the codec is a
    pure permutation. -/
def BattleMon.decodeList : List UInt8 → Option BattleMon
  | [ species, hpHi, hpLo, boxLevel, status, type1, type2, catchRate,
      move0, move1, move2, move3, dv0, dv1, level,
      maxHpHi, maxHpLo, atkHi, atkLo, defHi, defLo,
      spdHi, spdLo, spcHi, spcLo, pp0, pp1, pp2, pp3 ] =>
      some { species, hpHi, hpLo, boxLevel, status, type1, type2, catchRate,
             move0, move1, move2, move3, dv0, dv1, level,
             maxHpHi, maxHpLo, atkHi, atkLo, defHi, defLo,
             spdHi, spdLo, spcHi, spcLo, pp0, pp1, pp2, pp3 }
  | _ => none

/-- Decoding a freshly-encoded mon is the identity (encode is injective). -/
@[simp] theorem BattleMon.decodeList_encodeList (m : BattleMon) :
    BattleMon.decodeList m.encodeList = some m := by
  cases m; rfl

/-- Every list that decodes re-encodes to itself (decode is lossless). -/
theorem BattleMon.encodeList_decodeList {l : List UInt8} {m : BattleMon}
    (h : BattleMon.decodeList l = some m) : m.encodeList = l := by
  unfold BattleMon.decodeList at h
  split at h
  · injection h with h; subst h; rfl
  · simp at h

/-! ## The byte-array codec

`Bytes := Array UInt8` (from `Checkpoint`) is what the driver captures and the
comparator diffs, so the mon-facing entry points speak `Bytes`. -/

/-- Serialize a mon to its 29 `battle_struct` bytes. -/
def BattleMon.encode (m : BattleMon) : Bytes := m.encodeList.toArray

/-- Parse a 29-byte `battle_struct` capture; any other length is `none`. -/
def BattleMon.decode (b : Bytes) : Option BattleMon := BattleMon.decodeList b.toList

/-- `encode` always produces a `battle_struct`-length block. -/
@[simp] theorem BattleMon.encode_size (m : BattleMon) :
    m.encode.size = battleStructLength := by
  simp [BattleMon.encode, BattleMon.encodeList, battleStructLength]

/-- Round-trip in: decoding an encoded mon returns it (encode injective). -/
@[simp] theorem BattleMon.decode_encode (m : BattleMon) :
    BattleMon.decode m.encode = some m := by
  simp [BattleMon.decode, BattleMon.encode]

/-- Round-trip out: any block that decodes re-encodes to the exact same bytes
    (decode lossless — no ROM byte state is misread). -/
theorem BattleMon.encode_decode {b : Bytes} {m : BattleMon}
    (h : BattleMon.decode b = some m) : m.encode = b := by
  have hl : m.encodeList = b.toList := BattleMon.encodeList_decodeList h
  simp [BattleMon.encode, hl]

/-! ## Bridge to the checkpoint trace

A captured `Snapshot` of `wBattleMon`/`wEnemyMon` is exactly a serialized mon, so
the codec plugs straight into the differential trace. -/

/-- Serialize a mon into a `Snapshot` under the given side's region symbol. -/
def BattleMon.toSnapshot (symbol : String) (m : BattleMon) : Snapshot :=
  { region := { symbol, len := battleStructLength }, bytes := m.encode }

/-- A serialized mon is always a well-formed snapshot. -/
theorem BattleMon.toSnapshot_wf (symbol : String) (m : BattleMon) :
    (BattleMon.toSnapshot symbol m).wf := by
  unfold BattleMon.toSnapshot Snapshot.wf
  exact m.encode_size

/-! ## Numeric views (big-endian 16-bit fields)

Endianness lives here, not in the codec. `beWord` reassembles a stored `Hi`/`Lo`
pair big-endian; the codec's correctness never depends on these, so they are
pinned by concrete `#guard`s rather than a universal bitvector theorem. -/

/-- Reassemble a big-endian 16-bit value from its high and low bytes. -/
def beWord (hi lo : UInt8) : UInt16 := (hi.toUInt16 <<< 8) ||| lo.toUInt16

/-- The high (first, lower-address) byte of a big-endian 16-bit value. -/
def hiByte (w : UInt16) : UInt8 := (w >>> 8).toUInt8

/-- The low (second) byte of a big-endian 16-bit value. -/
def loByte (w : UInt16) : UInt8 := w.toUInt8

/-- Current HP. -/
def BattleMon.hp (m : BattleMon) : UInt16 := beWord m.hpHi m.hpLo
/-- Maximum HP. -/
def BattleMon.maxHp (m : BattleMon) : UInt16 := beWord m.maxHpHi m.maxHpLo
/-- Attack stat. -/
def BattleMon.attack (m : BattleMon) : UInt16 := beWord m.atkHi m.atkLo
/-- Defense stat. -/
def BattleMon.defense (m : BattleMon) : UInt16 := beWord m.defHi m.defLo
/-- Speed stat. -/
def BattleMon.speed (m : BattleMon) : UInt16 := beWord m.spdHi m.spdLo
/-- Special stat. -/
def BattleMon.special (m : BattleMon) : UInt16 := beWord m.spcHi m.spcLo

/-- The four move IDs (decimal), in slot order. -/
def BattleMon.moves (m : BattleMon) : List UInt8 := [m.move0, m.move1, m.move2, m.move3]

-- Big-endian reassembly and its inverse, on concrete values (300 = $012C).
#guard beWord 0x01 0x2C == 300
#guard beWord 0x00 0x01 == 1
#guard beWord 0xFF 0xFF == 65535
#guard hiByte 300 == 0x01
#guard loByte 300 == 0x2C
#guard hiByte 0xABCD == 0xAB
#guard loByte 0xABCD == 0xCD
#guard beWord (hiByte 0xABCD) (loByte 0xABCD) == 0xABCD

/-! ## Packed-field views (`pokemon_data_constants.asm`)

PP packs current PP and PP-Ups into one byte; DVs pack four 4-bit values into two
bytes. These unpackers reproduce the exact Gen-1 bit layout. -/

/-- Current PP from a packed PP byte (bits 0-5). -/
def ppCurrent (ppByte : UInt8) : UInt8 := ppByte &&& ppMask
/-- Applied PP Ups from a packed PP byte (bits 6-7). -/
def ppUps (ppByte : UInt8) : UInt8 := (ppByte &&& ppUpMask) >>> 6

/-- High nibble of a byte. -/
def hiNibble (b : UInt8) : UInt8 := b >>> 4
/-- Low nibble of a byte. -/
def loNibble (b : UInt8) : UInt8 := b &&& 0x0F

/-- Attack DV (high nibble of `dv0`). -/
def BattleMon.attackDV (m : BattleMon) : UInt8 := hiNibble m.dv0
/-- Defense DV (low nibble of `dv0`). -/
def BattleMon.defenseDV (m : BattleMon) : UInt8 := loNibble m.dv0
/-- Speed DV (high nibble of `dv1`). -/
def BattleMon.speedDV (m : BattleMon) : UInt8 := hiNibble m.dv1
/-- Special DV (low nibble of `dv1`). -/
def BattleMon.specialDV (m : BattleMon) : UInt8 := loNibble m.dv1

/-- Sleep turn counter from a status byte (bits 0-2). -/
def statusSleepCounter (st : UInt8) : UInt8 := st &&& Status.slpMask
/-- Whether a status byte has the given flag bit set. -/
def statusHasBit (st : UInt8) (bit : Nat) : Bool := ((st >>> bit.toUInt8) &&& 1) == 1

-- PP unpacking: $9F = 31 PP with 2 PP Ups; $C0 = 0 PP with 3 PP Ups.
#guard ppCurrent 0x9F == 31
#guard ppUps 0x9F == 2
#guard ppCurrent 0xC0 == 0
#guard ppUps 0xC0 == 3
#guard ppCurrent 0x25 == 0x25   -- no PP Ups: byte is the PP
#guard ppUps 0x25 == 0

-- DV unpacking on the fixed trainer DVs ($98/$88 → Atk 9 / Def 8 / Spd 8 / Spc 8).
#guard hiNibble atkDefDvTrainer == 9
#guard loNibble atkDefDvTrainer == 8
#guard hiNibble spdSpcDvTrainer == 8
#guard loNibble spdSpcDvTrainer == 8

-- Status: a clean sleep-3, and a reachable glitch byte carrying sleep-3 AND poison.
#guard statusSleepCounter 0x03 == 3
#guard statusHasBit 0x08 Status.psn == true
#guard statusSleepCounter 0x0B == 3
#guard statusHasBit 0x0B Status.psn == true
#guard statusHasBit 0x03 Status.psn == false

/-! ## End-to-end codec fixtures

A representative mon pins the field offsets to `battleStructFields` and exercises
the full round-trip; an all-`$FF` block exercises the lossless (reverse)
direction on an adversarial glitch state; wrong-length blocks decode to `none`. -/

/-- A codec fixture (values chosen to exercise every field, not to be legal). -/
private def sample : BattleMon :=
  { species := 1, hpHi := 0x01, hpLo := 0x2C, boxLevel := 5, status := 0,
    type1 := 22, type2 := 3, catchRate := 45,
    move0 := 33, move1 := 45, move2 := 0, move3 := 0, dv0 := 0x98, dv1 := 0x88,
    level := 5, maxHpHi := 0x01, maxHpLo := 0x41, atkHi := 0x00, atkLo := 0x32,
    defHi := 0x00, defLo := 0x31, spdHi := 0x00, spdLo := 0x2D,
    spcHi := 0x00, spcLo := 0x41, pp0 := 0x9F, pp1 := 30, pp2 := 0, pp3 := 0 }

-- The serialized block matches the WRAM contract's length and key offsets.
#guard sample.encode.size == battleStructLength
#guard sample.encodeList.length == battleStructLength
#guard totalWidth battleStructFields == sample.encode.size
#guard sample.encode.getD 0 0 == 1        -- Species @0
#guard sample.encode.getD 1 0 == 0x01     -- HP hi @1 (big-endian)
#guard sample.encode.getD 2 0 == 0x2C     -- HP lo @2
#guard sample.encode.getD 8 0 == 33       -- Moves[0] @8
#guard sample.encode.getD 12 0 == 0x98    -- DVs @12
#guard sample.encode.getD 15 0 == 0x01    -- MaxHP hi @15
#guard sample.encode.getD 25 0 == 0x9F    -- PP[0] @25

-- Full round-trip and the numeric/packed views on the fixture.
#guard BattleMon.decode sample.encode == some sample
#guard (BattleMon.decode sample.encode).map BattleMon.encode == some sample.encode
#guard sample.hp == 300
#guard sample.maxHp == 321
#guard sample.attack == 50
#guard sample.special == 65
#guard sample.moves == [33, 45, 0, 0]
#guard sample.attackDV == 9
#guard sample.defenseDV == 8
#guard sample.speedDV == 8
#guard sample.specialDV == 8
#guard ppCurrent sample.pp0 == 31
#guard ppUps sample.pp0 == 2

-- A full glitch block ($FF × 29) round-trips out losslessly.
#guard
  let raw := (List.replicate battleStructLength (0xFF : UInt8)).toArray
  (BattleMon.decode raw).map BattleMon.encode == some raw

-- Wrong-length captures are rejected, not silently truncated or padded.
#guard BattleMon.decode #[] == none
#guard BattleMon.decode (List.replicate 28 (0 : UInt8)).toArray == none
#guard BattleMon.decode (List.replicate 30 (0 : UInt8)).toArray == none

end Battle
