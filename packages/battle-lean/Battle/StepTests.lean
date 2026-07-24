/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Step

/-!
# Scripted-battle battery — multi-turn `runScript` fixtures

Deterministic full battles driven by `Battle.Step.runScript`, each outcome
derived by hand from the transcribed turn pipeline. Where `Battle.Step`'s own
guards check one turn, these thread state and the link RNG across several,
exercising: the turn counter advancing on completed turns, damage accumulating
to a faint, the win / loss verdict (both `defender == .enemy` and `.player`
branches), the enemy-first speed ordering, and — the point of `stepTurn`'s
terminal short-circuit — a script longer than the battle producing byte-identical
final state (RNG cursor included) as one cut to length.

## The seed

`seed255` is ten `$ff` bytes; `Rng.LinkRng` only regenerates after nine draws, so
every draw in these ≤ 6-draw battles is `$ff`. With `critThreshold 0` the crit
roll never fires (`rotl3($ff)=$ff < 0` is false) and, `alwaysHits` skipping the
accuracy roll, the sole effect of each `$ff` is the randomisation byte:
`randomizeDamage $ff d = d`, i.e. every hit lands its full typed damage.

## The number

`mkMon` is L50 / 40-BP / Atk 80 vs Def 70, so each hit's base (and, Normal vs
Fire/Flying being neutral with no STAB, typed) damage is
`calcBaseDamage 50 false 40 80 70 = 22` — see `Battle.Step`'s matching guard.

A failing `#guard` fails the build; this module is the executable proof that
sequencing `resolveTurn` reproduces a whole ROM battle's turn-by-turn arithmetic.
-/

namespace Battle.StepTests

open Battle.Step

/-- A representative combatant: L50 Fire/Flying, Atk 80 / Def 70, one move slot. -/
private def mkMon (hp speed : UInt16) : MonState :=
  { species := 6, hp, boxLevel := 50, status := 0, type1 := 0x14, type2 := 0x02,
    catchRate := 45, moves := #[52, 0, 0, 0], dvs := 0xFFFF, level := 50,
    maxHp := 100, attack := 80, defense := 70, speed, special := 90, pp := #[15, 0, 0, 0] }

/-- A 40-BP Normal move that always hits and never crits. -/
private def atk : ResolvedMove :=
  { id := 33, power := 40, type := 0x00, accuracy := 255, alwaysHits := true }

/-- Ten `$ff` bytes — every draw in a ≤ 6-draw battle is `$ff` (no regen). -/
private def seed255 : Rng.LinkRng :=
  { list := #[255, 255, 255, 255, 255, 255, 255, 255, 255, 255], index := 0 }

/-! ## Player wins on turn 2

Player (100 HP, Spd 100) outspeeds enemy (30 HP, Spd 50). T1: player 30→8, enemy
100→78, both live, turn→1. T2: player 8→0, enemy faints before acting; the turn
ends without completing so the counter stays at 1. -/

private def battleWin : BattleState := BattleState.start (mkMon 100 100) (mkMon 30 50) seed255
private def outWin : BattleState × List TurnEvent := runScript [(atk, atk), (atk, atk)] battleWin

#guard outWin.1.phase.isTerminal == true
#guard (outWin.1.active .enemy).hp == 0
#guard (outWin.1.active .enemy).fainted == true
#guard (outWin.1.active .player).hp == 78          -- took one hit on turn 1 only
#guard outWin.1.turn == 1                           -- one completed turn; T2 ended mid-turn
#guard outWin.2.contains (TurnEvent.orderDecided .player false)
#guard outWin.2.contains (TurnEvent.damageDealt .player 22 8)    -- T1 enemy 30→8
#guard outWin.2.contains (TurnEvent.damageDealt .enemy 22 78)    -- T1 player 100→78
#guard outWin.2.contains (TurnEvent.damageDealt .player 22 0)    -- T2 enemy 8→0
#guard outWin.2.contains (TurnEvent.fainted .enemy)
#guard outWin.2.contains (TurnEvent.terminalReached (.partyExhausted .enemy) (some .win))
-- The phase carries the matching terminal witness.
#guard (match outWin.1.phase with
        | .ending t => t.cause == Outcome.TerminalCause.partyExhausted .enemy && t.verdict == some .win
        | _ => false)

/-! ## Intermediate states along the same battle -/

-- Empty script leaves the opening state untouched.
#guard (runScript [] battleWin).1.turn == 0
#guard (runScript [] battleWin).1.phase.isTerminal == false

-- One turn: both act, nobody faints, the counter reaches 1.
private def outT1 : BattleState × List TurnEvent := runScript [(atk, atk)] battleWin
#guard outT1.1.phase.isTerminal == false
#guard outT1.1.turn == 1
#guard (outT1.1.active .enemy).hp == 8
#guard (outT1.1.active .player).hp == 78

/-! ## Terminal short-circuit: a longer script gives the identical result -/

private def outWin5 : BattleState × List TurnEvent := runScript (List.replicate 5 (atk, atk)) battleWin
#guard (outWin5.1.active .enemy).hp == 0
#guard (outWin5.1.active .player).hp == 78
#guard outWin5.1.turn == 1
#guard outWin5.1.phase.isTerminal == true
-- No RNG is drawn past the faint: the cursor matches the exactly-2-turn run.
#guard outWin5.1.rng == outWin.1.rng

/-! ## Player loses — enemy faster, `defender == .player` verdict branch

Enemy (100 HP, Spd 100) outspeeds player (30 HP, Spd 50) and downs it on turn 2,
producing `partyExhausted .player` / `wBattleResult 1` / loss. -/

private def battleLose : BattleState := BattleState.start (mkMon 30 50) (mkMon 100 100) seed255
private def outLose : BattleState × List TurnEvent := runScript [(atk, atk), (atk, atk)] battleLose

#guard (outLose.1.active .player).hp == 0
#guard (outLose.1.active .enemy).hp == 78
#guard outLose.1.phase.isTerminal == true
#guard outLose.2.contains (TurnEvent.orderDecided .enemy false)   -- enemy outspeeds → acts first
#guard outLose.2.contains (TurnEvent.fainted .player)
#guard outLose.2.contains (TurnEvent.terminalReached (.partyExhausted .player) (some .loss))
#guard (match outLose.1.phase with
        | .ending t => t.rawResult == 1 && t.verdict == some .loss
        | _ => false)

end Battle.StepTests
