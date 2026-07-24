/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Step
import Battle.Data.Moves

/-!
# Move resolution — decode a move ID into the engine's per-turn input

The glue between the pure move-data table (`Battle/Data/Moves.lean`) and the
turn kernel's `Battle.Step.ResolvedMove` (`COORDINATION.md` seam 3 — the point
where "a move-data decoder fills it"). `resolveMove` reads the ROM move row and
fills the fields that *are* move data:

* `id`, `power`, `type` — verbatim from the `Moves` table byte row;
* `accuracy` — the move's **base** accuracy byte (`percent`-encoded like the ROM),
  *before* `CalcHitChance` stage-scaling;
* `alwaysHits` — Swift's `SWIFT_EFFECT` ($11), the effect that skips the accuracy
  roll (`MoveData.alwaysHits`);
* `priority` — Quick Attack / Counter, which Gen 1 decides by a hardcoded
  move-ID branch in the turn-order code (`core.asm`), *not* a data field, so it
  is a pure function of the ID here.

Two `ResolvedMove` fields are deliberately **not** filled from move data, because
they are not move data:

* `critThreshold` — `CriticalHitTest`'s `b` is derived from the user's *base
  Speed* (and the high-crit move flag), so it belongs to the crit layer; left `0`.
* the stage-scaled *effective* accuracy — `CalcHitChance` folds in the attacker's
  accuracy / target's evasion stages; `accuracy` here is the pre-scale base, which
  the accuracy layer adjusts. With no active stages the two coincide.

So `resolveMove` is the faithful **data** half of move resolution; the crit and
stat-stage layers refine `critThreshold` / `accuracy` on top.
-/

namespace Battle

open Battle.Data (moveData)

/-- A move's turn-order class as a pure function of its ID. Gen 1 has no priority
    data field: the turn-order code special-cases Quick Attack (acts first) and
    Counter (acts last) by move ID (`core.asm:370-391`); everything else is
    `.normal`. Quick Attack = `$62` (98), Counter = `$44` (68). -/
def movePriority (id : MoveId) : Step.Priority :=
  if id == 98 then .quickAttack
  else if id == 68 then .counter
  else .normal

/-- Decode a move ID into the engine's `ResolvedMove` turn input, from the
    `Battle.Data.Moves` table. Fills the data-derived fields (id/power/type/base
    accuracy/alwaysHits/priority); `critThreshold` stays `0` and `accuracy` is the
    pre-`CalcHitChance` base — the crit / stat-stage layers supply those. -/
def resolveMove (id : MoveId) : Step.ResolvedMove :=
  let d := moveData id
  { id, power := d.power, type := d.type, accuracy := d.accuracy,
    alwaysHits := d.alwaysHits, critThreshold := 0, priority := movePriority id }

/-! ## Fidelity guards -/

-- Data-derived fields, vs `data/moves/moves.asm` (accuracy is `percent`-encoded:
-- 95 % → 242, 100 % → 255).
#guard resolveMove 33 ==                              -- TACKLE: 35 pw, Normal, 95 %
  { id := 33, power := 35, type := 0x00, accuracy := 242, priority := .normal }
#guard resolveMove 52 ==                              -- EMBER: 40 pw, Fire, 100 %
  { id := 52, power := 40, type := 0x14, accuracy := 255, priority := .normal }
#guard resolveMove 68 ==                              -- COUNTER: 1 pw, Fighting, acts last
  { id := 68, power := 1, type := 0x01, accuracy := 255, priority := .counter }
#guard resolveMove 98 ==                              -- QUICK_ATTACK: 40 pw, Normal, acts first
  { id := 98, power := 40, type := 0x00, accuracy := 255, priority := .quickAttack }

-- Swift is the one move that skips the accuracy roll (`SWIFT_EFFECT`).
#guard (resolveMove 129).alwaysHits == true           -- SWIFT
#guard (resolveMove 129).power == 60 && (resolveMove 129).type == 0x00
#guard (resolveMove 33).alwaysHits == false           -- ordinary move rolls to hit

-- Priority is a pure function of the ID; only the two special moves deviate.
#guard movePriority 98 == .quickAttack
#guard movePriority 68 == .counter
#guard movePriority 33 == .normal
#guard movePriority 0 == .normal

-- The empty / no-move slot decodes to the zero row (power 0 = status/no-op here).
#guard (resolveMove 0).power == 0 && (resolveMove 0).accuracy == 0

-- `critThreshold` is not move data — always 0 out of the base decoder.
#guard (resolveMove 98).critThreshold == 0

end Battle
