/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

/-!
# Shared battle-model scalar types

The small, self-contained vocabulary the pure battle model is built from: which
`Side` is acting, the single-byte identifiers the ROM uses for moves and species,
and the `BattleMode` that selects how a battle initialises and how its result
byte is read.

These are the model's own types. GPT's `Battle.Episode` has a parallel `Side`;
the `Refinement/` layer maps between the two (see `COORDINATION.md`, seam 2). This
module deliberately keeps the machine layer out — no imports — so every later
battle module can share these names cheaply.
-/

namespace Battle

/-! ## Sides -/

/-- The two combatants. `player` is the local trainer; `enemy` is the opponent
    (wild mon, trainer, or the linked player). Mirrors `Battle.Episode.Side`. -/
inductive Side where
  | player
  | enemy
  deriving Repr, DecidableEq, BEq

/-- The opposing side. An involution: `other (other s) = s`. -/
def Side.other : Side → Side
  | .player => .enemy
  | .enemy => .player

#guard Side.other .player == .enemy
#guard Side.other .enemy == .player
#guard Side.other (Side.other .player) == .player
#guard Side.other (Side.other .enemy) == .enemy

/-! ## Identifiers

Gen-1 indexes moves and species by a single byte. Modelling them as `UInt8`
keeps the model byte-faithful to the ROM's tables and lets identifiers ride the
same 8-bit wrap the hardware uses. -/

/-- A move's internal index (`MOVE` constant, 1-165; `$00` = no move). -/
abbrev MoveId := UInt8

/-- A species' internal index (the ROM's internal Pokédex number, not the
    National-Dex order shown to the player). -/
abbrev SpeciesId := UInt8

/-! ## Battle mode

The initialisation/cleanup context a battle runs in. The ROM spreads this across
several flags — `wBattleType` (`$00` normal, `$01` old-man tutorial, `$02`
Safari), `wIsInBattle` (`$01` wild vs `$02` trainer), and `wLinkState`
(`LINK_STATE_BATTLING`). This one enum is the model's join of those, because each
mode changes which `TerminalCause`s are reachable and how `wBattleResult` is
produced. -/
inductive BattleMode where
  /-- An ordinary wild encounter (`wIsInBattle = $01`, `wBattleType = $00`). -/
  | wild
  /-- A trainer battle (`wIsInBattle = $02`). -/
  | trainer
  /-- A Safari Zone encounter (`wBattleType = $02`): no damage, ball/rock/bait. -/
  | safari
  /-- The Prof-Oak catching tutorial (`wBattleType = $01`, `OLD_MAN_BATTLE`). -/
  | oldMan
  /-- A link (player-vs-player) battle (`wLinkState = LINK_STATE_BATTLING`). -/
  | link
  deriving Repr, DecidableEq, BEq

end Battle
