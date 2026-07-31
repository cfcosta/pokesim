/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Wram

/-!
# The RNG oracle: link-battle `BattleRandom`

`BattleRandom` (`engine/battle/core.asm:6543`) has two paths:

* **Hardware path** — when `wLinkState ≠ LINK_STATE_BATTLING`, it falls through to
  `Random`, which advances `hRandomAdd`/`hRandomSub` from the free-running divider
  register `rDIV` (`engine/math/random.asm`). Because `rDIV` is a timer, this path
  is **not a pure function of software state** and cannot be an oracle. It is
  modelled nowhere in Lean by design; when a fixture needs it, the L0 oracle
  (`sm83-lean` executing `Random_`) runs it against a supplied timer environment.

* **Link path** — when `wLinkState = LINK_STATE_BATTLING`, `BattleRandom` returns
  the next byte from a shared nine-element list and, once the list is exhausted,
  regenerates it by the pure recurrence `x ↦ 5x + 1 (mod 256)`. This path has **no
  `rDIV` dependency**: it is a total function of the list bytes and the read
  cursor. That is exactly why link-battle mode is the harness's canonical
  deterministic mode — the same seed drives the oracle and the abstract model to
  the same byte stream, so any divergence is an engine bug, never luck.

This module models the link path 1:1 and couples it to the WRAM state contract
(`wLinkBattleRandomNumberList`, `wLinkBattleRandomNumberListIndex`,
`wLinkState`). The transliterated routine, for reference:

```
BattleRandom:                        ; link path (wLinkState = LINK_STATE_BATTLING)
    ld a, [wLinkBattleRandomNumberListIndex]   ; a = index
    ld c, a
    ld b, 0
    ld hl, wLinkBattleRandomNumberList
    add hl, bc                                 ; hl = &list[index]
    inc a                                      ; a = index + 1
    ld [wLinkBattleRandomNumberListIndex], a   ; store index + 1
    cp SERIAL_RNS_LENGTH - 1                    ; carry := (index + 1) < 9
    ld a, [hl]                                  ; a = list[index]   (return value)
    ret c                                       ; if index + 1 < 9, return list[index]
    ; index + 1 == 9  (we just consumed list[8]) -> regenerate and wrap:
    xor a
    ld [wLinkBattleRandomNumberListIndex], a    ; index := 0
    ld hl, wLinkBattleRandomNumberList
    ld b, SERIAL_RNS_LENGTH - 1                 ; b = 9 entries
.loop
    ld a, [hl] : ld c, a : add a : add a : add c : inc a  ; a = 5*list[i] + 1
    ld [hli], a
    dec b : jr nz, .loop
    ret                                         ; still returns the old list[8]
```
-/

namespace Battle.Rng

open Battle.Wram

/-! ## The regeneration recurrence -/

/-- The list-regeneration recurrence `x ↦ 5x + 1`, in `UInt8` (mod 256).
    ASM: `add a` (2x), `add a` (4x), `add c` (5x), `inc a` (5x+1). -/
def regenStep (x : UInt8) : UInt8 := 5 * x + 1

-- 8-bit wraparound, matching the hardware `add`/`inc` chain.
#guard regenStep 52 == 5     -- 5*52 + 1 = 261 ≡ 5
#guard regenStep 255 == 252  -- 5*255 + 1 = 1276 ≡ 252

/-- Regenerate the shared list: apply `regenStep` to the nine consumed entries
    (indices `0 .. rnsConsumed-1`), leaving the vestigial tenth byte untouched,
    exactly as the `.loop` (`b = SERIAL_RNS_LENGTH - 1` iterations from
    `wLinkBattleRandomNumberList`) does. -/
def regenerate (list : Array UInt8) : Array UInt8 :=
  (List.range rnsConsumed).foldl (fun l i => l.modify i regenStep) list

/-- Regeneration preserves the list length. -/
theorem size_regenerate (list : Array UInt8) : (regenerate list).size = list.size := by
  unfold regenerate
  induction List.range rnsConsumed generalizing list with
  | nil => rfl
  | cons i is ih => rw [List.foldl_cons, ih, Array.size_modify]

/-! ## The link-battle RNG state and step -/

/-- The shared link-battle PRNG state: the ten-byte list (nine live entries plus
    one vestigial) and the read cursor `wLinkBattleRandomNumberListIndex`. -/
structure LinkRng where
  /-- `wLinkBattleRandomNumberList`, `SERIAL_RNS_LENGTH` bytes. -/
  list : Array UInt8
  /-- `wLinkBattleRandomNumberListIndex`. -/
  index : Nat
deriving Repr, DecidableEq, BEq, ReflBEq, LawfulBEq

/-- Well-formed state: the list is exactly `serialRnsLength` bytes and the cursor
    is in range. Fixtures always seed a well-formed state; `next` preserves it. -/
def LinkRng.wf (r : LinkRng) : Prop :=
  r.list.size = serialRnsLength ∧ r.index < serialRnsLength

/-- One `BattleRandom` link-path draw: return `list[index]`, advance the cursor,
    and regenerate + wrap once the ninth entry has been consumed
    (`index + 1 = SERIAL_RNS_LENGTH - 1`). The returned byte is the pre-regen
    `list[index]`, matching the ASM (the value is loaded before `.loop`). -/
def LinkRng.next (r : LinkRng) : UInt8 × LinkRng :=
  let value := r.list.getD r.index 0
  if r.index + 1 < rnsConsumed then
    (value, { r with index := r.index + 1 })
  else
    (value, { list := regenerate r.list, index := 0 })

/-- `next` preserves well-formedness (and in fact re-establishes the tighter
    `index < rnsConsumed`, but `wf` is what downstream steps consume). -/
theorem LinkRng.next_wf {r : LinkRng} (h : r.wf) : r.next.2.wf := by
  unfold LinkRng.next LinkRng.wf rnsConsumed serialRnsLength at *
  split
  · dsimp only
    exact ⟨h.1, by omega⟩
  · dsimp only
    refine ⟨?_, by omega⟩
    rw [size_regenerate]; exact h.1

/-- Draw `n` consecutive values, threading the state. First value drawn is first
    in the result. -/
def LinkRng.take : Nat → LinkRng → Array UInt8 × LinkRng
  | 0, r => (#[], r)
  | k + 1, r =>
    let (v, r') := r.next
    let (vs, r'') := LinkRng.take k r'
    (#[v] ++ vs, r'')

/-! ### Test vectors

Locking the full nine-value epoch, the regeneration transform, and the wrap
boundary against a hand-computed sequence. Seed `[0,1,…,9]` at cursor 0:
draws `0..8`, then entries `0..8` become `5x+1` (`0→1, 1→6, 2→11, …, 8→41`), the
tenth byte `9` is untouched, and the cursor wraps to 0, so the tenth draw is the
new `list[0] = 1`. -/

/-- A concrete seed used by the guards below. -/
def seed0 : LinkRng := { list := #[0, 1, 2, 3, 4, 5, 6, 7, 8, 9], index := 0 }

-- One full epoch returns the nine live entries in order.
#guard (seed0.take 9).1 == #[0, 1, 2, 3, 4, 5, 6, 7, 8]
-- After the epoch the list is regenerated (tenth byte preserved) and the cursor wraps.
#guard (seed0.take 9).2.list == #[1, 6, 11, 16, 21, 26, 31, 36, 41, 9]
#guard (seed0.take 9).2.index == 0
-- Crossing the boundary: the tenth draw reads the regenerated list[0].
#guard (seed0.take 10).1 == #[0, 1, 2, 3, 4, 5, 6, 7, 8, 1]

/-! ## Coupling to the WRAM state contract

The driver writes `linkStateByte` to `wLinkState`, `listBytes` to
`wLinkBattleRandomNumberList`, and `indexByte` to
`wLinkBattleRandomNumberListIndex` before running the oracle; the abstract model
steps its own `LinkRng` with `next`. Since the link path is pure, both consume
the identical stream. -/

/-- Bytes for the `wLinkBattleRandomNumberList` region. -/
def LinkRng.listBytes (r : LinkRng) : Array UInt8 := r.list

/-- Byte for the `wLinkBattleRandomNumberListIndex` region. -/
def LinkRng.indexByte (r : LinkRng) : UInt8 := r.index.toUInt8

/-- Reconstruct from the two captured WRAM regions. -/
def LinkRng.ofWram (listBytes : Array UInt8) (indexByte : UInt8) : LinkRng :=
  { list := listBytes, index := indexByte.toNat }

/-- The `wLinkState` value that selects the shared-list path in `BattleRandom`. -/
def linkStateByte : UInt8 := linkStateBattling

-- Serialization round-trips for well-formed cursors (index < 256).
#guard LinkRng.ofWram seed0.listBytes seed0.indexByte == seed0
#guard
  let r : LinkRng := { list := #[10, 20, 30, 40, 50, 60, 70, 80, 90, 100], index := 5 }
  LinkRng.ofWram r.listBytes r.indexByte == r
#guard linkStateByte == 0x04

end Battle.Rng
