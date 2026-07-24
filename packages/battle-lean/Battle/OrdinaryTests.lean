/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Ordinary

/-!
# Ordinary-kernel regression fixtures

These fixtures exercise the exact RNG order for the restricted profile. They
are supplementary executable checks; universal byte-recurrence and codec facts
remain theorem-level in `Battle.Ordinary`.
-/

namespace Battle.OrdinaryTests

private def mon (hp speed : UInt16) : MonState :=
  { species := 1, hp, boxLevel := 100, status := 0,
    type1 := TypeChart.normal, type2 := TypeChart.normal, catchRate := 45,
    moves := #[33, 0, 0, 0], dvs := 0xFFFF, level := 100,
    maxHp := 300, attack := 200, defense := 150, speed, special := 100,
    pp := #[35, 0, 0, 0] }

/-- No Speed tie. Player draws: crit `$FF` (not critical), damage raw `$B3`
(`rrca = 217`, accepted), accuracy `$00` (hit). -/
private def rng : Rng.LinkRng :=
  { list := #[0xFF, 0xB3, 0x00, 0xFF, 0xB3, 0x00, 1, 2, 3, 4], index := 0 }

private def battle : BattleState := BattleState.start (mon 300 100) (mon 10 50) rng

private def playerWins : Bool :=
  match Ordinary.resolveTurn 0 0 battle with
  | .complete state events =>
      state.phase.isTerminal &&
        (state.active .enemy).hp == 0 &&
        (state.active .player).pp[0]? == some 34 &&
        state.rng.index == 3 &&
        events.contains (.rng "critical" 0xFF) &&
        events.contains (.damageFactor 217) &&
        events.contains (.rng "accuracy" 0)
  | _ => false

#guard playerWins

/-- Rejection is observable: `$00` rotates to zero and is rejected; `$B3` is the
next accepted raw byte. -/
private def rejectionVisible : Bool :=
  match Ordinary.drawDamageFactor
      ({ list := #[0x00, 0xB3, 1, 2, 3, 4, 5, 6, 7, 8], index := 0 } : Rng.LinkRng) with
  | some (factor, next, events) =>
      factor == 217 && next.index == 2 &&
        events == [.rng "damage" 0, .rng "damage" 0xB3, .damageFactor 217]
  | none => false

#guard rejectionVisible

end Battle.OrdinaryTests
