/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Wram

/-!
# The action channel

Per turn, each side commits to one decision. In link-battle mode — the harness's
canonical deterministic mode — that decision is exchanged as a single **nybble**
by `LinkBattleExchangeData` (`engine/battle/core.asm:3008`). This module models
that nybble exactly and treats it as the harness's action channel: the driver
writes a side's chosen nybble to `wSerialExchangeNybbleSendData` and reads the
opponent's from `wSerialExchangeNybbleReceiveData`, so both the L0 oracle and the
abstract model consume identical per-turn inputs.

The wire encoding, read straight off `LinkBattleExchangeData`:

| nybble  | meaning                    | ASM source                                  |
| ------- | -------------------------- | ------------------------------------------- |
| `0..3`  | fight with move slot `n`   | `wPlayerMoveListIndex`                       |
| `4..9`  | switch to party index `n-4`| `wWhichPokemon + 4`                          |
| `$D`    | no action (locked/forced)  | `LINKBATTLE_NO_ACTION`, sel. move `$FF`      |
| `$E`    | struggle                   | `LINKBATTLE_STRUGGLE`, sel. move `STRUGGLE`  |
| `$F`    | run / forfeit              | `LINKBATTLE_RUN`, `wPlayerMoveListIndex`     |
| `$A..$C`| (unused)                   | —                                           |
| `$FF`   | "no data yet" sentinel     | `wSerialExchangeNybbleReceiveData` init      |

Link battles disable the bag, so there is deliberately **no item action**: the
exchange has no encoding for one. Items (and the trainer AI that would pick enemy
actions in single-player) are outside the Stage-0 differential, which drives both
sides externally in link mode.
-/

namespace Battle

open Battle.Wram

/-! ## Wire constants (`constants/serial_constants.asm:29-31`) -/

/-- `LINKBATTLE_NO_ACTION` — the mon is locked into a forced move / cannot act. -/
def linkbattleNoAction : UInt8 := 0x0D
/-- `LINKBATTLE_STRUGGLE` — all PP exhausted, Struggle substituted. -/
def linkbattleStruggle : UInt8 := 0x0E
/-- `LINKBATTLE_RUN` — the RUN menu option (a forfeit in a link battle). -/
def linkbattleRun : UInt8 := 0x0F

/-! ## The action type -/

/-- One side's per-turn decision. Move slots and party indices carry their legal
    range in the type (`Fin 4`, `Fin 6`), so illegal actions are unrepresentable.
    The literal ranges are tied to the WRAM contract by the guards below. -/
inductive Action where
  /-- Fight using move slot `slot` (0-3). -/
  | fight (slot : Fin 4)
  /-- Switch to the party member at index `party` (0-5). -/
  | switch (party : Fin 6)
  /-- No action: the mon is locked into a forced move and skips the menu. -/
  | noAction
  /-- Struggle (all PP exhausted). -/
  | struggle
  /-- Run / forfeit. -/
  | run
deriving Repr, DecidableEq, BEq

-- The `Fin` ranges match the WRAM cardinalities they stand in for.
#guard numMoves == 4
#guard partyLength == 6

/-- Encode an action to its exchange nybble, matching `LinkBattleExchangeData`. -/
def Action.toNybble : Action → UInt8
  | .fight slot => slot.val.toUInt8            -- move slot 0..3
  | .switch party => (party.val + 4).toUInt8   -- wWhichPokemon + 4  →  4..9
  | .noAction => linkbattleNoAction
  | .struggle => linkbattleStruggle
  | .run => linkbattleRun

/-- Decode an exchange nybble back to an action, or `none` for the unused codes
    (`$A..$C`), out-of-range bytes, and the `$FF` receive sentinel. -/
def Action.ofNybble (n : UInt8) : Option Action :=
  let v := n.toNat
  if h : v < 4 then some (.fight ⟨v, h⟩)
  else if h10 : v < 10 then some (.switch ⟨v - 4, by omega⟩)
  else if n = linkbattleNoAction then some .noAction
  else if n = linkbattleStruggle then some .struggle
  else if n = linkbattleRun then some .run
  else none

/-- Every legal action, enumerated (the finite action domain). -/
def Action.all : List Action :=
  [.fight 0, .fight 1, .fight 2, .fight 3,
   .switch 0, .switch 1, .switch 2, .switch 3, .switch 4, .switch 5,
   .noAction, .struggle, .run]

#guard Action.all.length == 13

/-! ### Codec verification

`#guard`s over the whole finite domain (they fail the build on any mismatch). -/

-- Encode ∘ decode = identity for every legal action.
#guard Action.all.all (fun a => Action.ofNybble (Action.toNybble a) == some a)
-- Decode ∘ encode = identity for every canonical valid nybble.
#guard [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0x0D, 0x0E, 0x0F].all
  (fun n => (Action.ofNybble n).map Action.toNybble == some n)
-- The unused codes, an out-of-nybble byte, and the receive sentinel are rejected.
#guard [0x0A, 0x0B, 0x0C, 0x10, 0xFF].all (fun n => Action.ofNybble n == none)

-- Spot checks pinning the boundary values.
#guard Action.toNybble (.fight 0) == 0
#guard Action.toNybble (.fight 3) == 3
#guard Action.toNybble (.switch 0) == 4
#guard Action.toNybble (.switch 5) == 9
#guard Action.toNybble .noAction == 0x0D
#guard Action.toNybble .run == 0x0F
#guard Action.ofNybble 4 == some (.switch 0)
#guard Action.ofNybble 9 == some (.switch 5)

/-! ## Per-turn input

A turn of the differential is parameterised by both sides' decisions (link mode
supplies both externally); a `Script` is a whole battle's worth. -/

/-- Both sides' decisions for one turn. -/
structure TurnInput where
  /-- The player's decision. -/
  player : Action
  /-- The opponent's decision (delivered over the link in a real battle). -/
  enemy : Action
deriving Repr, DecidableEq

/-- A full battle's per-turn decisions, in order — one fixture's action input. -/
abbrev Script := List TurnInput

end Battle
