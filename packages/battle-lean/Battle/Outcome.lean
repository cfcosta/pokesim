/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Types

/-!
# Battle outcomes — terminal cause, verdict, and episode phase

The vocabulary a finished (or finishing) battle produces, transcribed from
`SPEC.md` §8.2 so the pure core and the `Refinement/` layer share one set of
names. A battle episode runs as a request/response machine (SPEC §8.2); this
module is the *terminal* half of that protocol — everything the machine emits
when a battle ends, plus the phase it moves through on the way out. The *request*
half (`BattleRequest`: `chooseAction`, `ordinaryRandomByte`, …) belongs with the
interaction machine that will wrap `Battle.Step`'s `resolveTurn` kernel, and is
intentionally not defined here.

`Battle.Episode` (GPT's) carries a thinner `TerminalWitness`/`Phase`; this is the
richer model-side vocabulary that the refinement maps onto it (see
`COORDINATION.md`, seam 2). It is deliberately *not* an edit to that module.

## ROM anchors

* `wBattleResult` (`ram/wram.asm`): `$00` win, `$01` lose, `$02` draw — from the
  **player's** perspective. `verdictOfRaw` below is that table, and `EndOfBattle`
  (`engine/battle/end_of_battle.asm:14-27`) reads it exactly this way
  (`cp $1`: `c` → win, `z` → lose, else draw).
* `wEscapedFromBattle` is snapshotted into `preCleanupEscaped` because
  `EndOfBattle`'s `.resetVariables` zeroes it during cleanup; the terminal
  retains the pre-cleanup value.
-/

namespace Battle.Outcome

/-! ## Verdict (`wBattleResult`) -/

/-- The battle's result from the player's perspective — the meaning of the three
    `wBattleResult` byte values. -/
inductive BattleVerdict where
  | win
  | loss
  | draw
  deriving Repr, DecidableEq, BEq

/-- `wBattleResult`'s byte encoding (`ram/wram.asm`): `$00` win, `$01` lose,
    `$02` draw. Any other byte is not a defined result, so `none`. -/
def verdictOfRaw (raw : UInt8) : Option BattleVerdict :=
  if raw == 0 then some .win
  else if raw == 1 then some .loss
  else if raw == 2 then some .draw
  else none

/-- Encode a verdict back to its `wBattleResult` byte. -/
def BattleVerdict.toRaw : BattleVerdict → UInt8
  | .win => 0
  | .loss => 1
  | .draw => 2

/-! ## Terminal cause

Why the battle loop exited. Each constructor names a distinct exit path in the
ROM; the parameterised ones carry the datum the ROM needs to reconstruct the
outcome (which side ran out of Pokémon, which move an escape used, …). -/

inductive TerminalCause where
  /-- `side` has no unfainted Pokémon left (a win if `enemy`, a loss / white-out
      if `player`). -/
  | partyExhausted (side : Side)
  /-- The player ran from a wild battle (`TryRunningFromBattle` succeeded). -/
  | ordinaryRun
  /-- An escape *move* ended the battle — Teleport / Roar / Whirlwind (`move`),
      run by `side`. -/
  | moveEscape (side : Side) (move : MoveId)
  /-- A POKé DOLL was used to escape a wild battle. -/
  | pokeDollEscape
  /-- The wild mon was caught. -/
  | capture
  /-- Safari: the wild Pokémon ran away. -/
  | safariEnemyRan
  /-- Safari: the player used the last Safari Ball. -/
  | safariBallsExhausted
  /-- A link battle ended because `side` chose RUN (a forfeit). -/
  | linkRun (side : Side)
  /-- The catching tutorial's scripted capture (Old-Man battle). -/
  | tutorialCapture
  deriving Repr, DecidableEq, BEq

/-! ## Terminal record

The full provenance of a finished battle, retained before the ROM's post-battle
cleanup erases the distinctions. -/

structure BattleTerminal where
  /-- Which exit path fired. -/
  cause : TerminalCause
  /-- The mode the battle ran in (selects which causes are legal). -/
  mode : BattleMode
  /-- Whose perspective `verdict` / `rawResult` are stated from — always the
      local player outside link battles. -/
  perspective : Side
  /-- The raw `wBattleResult` byte as written at exit. -/
  rawResult : UInt8
  /-- `wEscapedFromBattle` snapshotted before `EndOfBattle` cleanup zeroes it. -/
  preCleanupEscaped : UInt8
  /-- The decoded verdict, present when `rawResult` is a defined value. -/
  verdict : Option BattleVerdict
  /-- In a double-KO, which side the ROM detected as fainting *first* (order
      decides the result). `none` when the faint was not simultaneous. -/
  simultaneousDetectedFirst : Option Side
  deriving Repr, DecidableEq

/-- Assemble a terminal, decoding the verdict from the raw byte so the two can
    never disagree. -/
def BattleTerminal.mk' (cause : TerminalCause) (mode : BattleMode)
    (perspective : Side) (rawResult : UInt8) (preCleanupEscaped : UInt8 := 0)
    (simultaneousDetectedFirst : Option Side := none) : BattleTerminal :=
  { cause, mode, perspective, rawResult, preCleanupEscaped,
    verdict := verdictOfRaw rawResult, simultaneousDetectedFirst }

/-! ## Episode result and phase -/

/-- What the outer episode returns: the terminal record (a nominal wrapper, kept
    distinct so the refinement can attach presentation-layer data later). -/
structure EpisodeResult where
  terminal : BattleTerminal
  deriving Repr, DecidableEq

/-- The episode's coarse phase. `battling` until a terminal is witnessed;
    `ending` carries that witness through the ROM's epilogue (evolutions, EXP,
    versus text); `returned` is the settled result handed back to the caller.
    (`Battle.Episode.Phase` additionally has `initializing` and an
    `epilogueComplete` flag; the refinement bridges the two.) -/
inductive EpisodePhase where
  | battling
  | ending (witness : BattleTerminal)
  | returned (result : EpisodeResult)
  deriving Repr, DecidableEq

/-- True once a terminal has been witnessed (the battle loop has exited). -/
def EpisodePhase.isTerminal : EpisodePhase → Bool
  | .battling => false
  | .ending _ => true
  | .returned _ => true

/-! ## Fidelity guards -/

-- The `wBattleResult` byte table (`ram/wram.asm`), both directions.
#guard verdictOfRaw 0 == some .win
#guard verdictOfRaw 1 == some .loss
#guard verdictOfRaw 2 == some .draw
#guard verdictOfRaw 3 == none
#guard verdictOfRaw 255 == none
#guard BattleVerdict.win.toRaw == 0
#guard BattleVerdict.loss.toRaw == 1
#guard BattleVerdict.draw.toRaw == 2
-- Round-trip on the three defined bytes / three verdicts.
#guard [0, 1, 2].all (fun n => (verdictOfRaw n).map BattleVerdict.toRaw == some n)
#guard [BattleVerdict.win, .loss, .draw].all (fun v => verdictOfRaw v.toRaw == some v)

-- The smart constructor decodes the verdict from the raw byte and defaults the
-- escape snapshot to 0.
#guard (BattleTerminal.mk' (.partyExhausted .enemy) .wild .player 0).verdict == some .win
#guard (BattleTerminal.mk' (.partyExhausted .player) .wild .player 1).verdict == some .loss
#guard (BattleTerminal.mk' .capture .wild .player 2).verdict == some .draw
#guard (BattleTerminal.mk' .ordinaryRun .wild .player 7).verdict == none
#guard (BattleTerminal.mk' .capture .wild .player 0).preCleanupEscaped == 0
#guard (BattleTerminal.mk' .pokeDollEscape .wild .player 0 1).preCleanupEscaped == 1

-- Phase terminality.
#guard EpisodePhase.battling.isTerminal == false
#guard (EpisodePhase.ending (BattleTerminal.mk' .ordinaryRun .wild .player 0)).isTerminal == true
#guard (EpisodePhase.returned ⟨BattleTerminal.mk' .capture .wild .player 0⟩).isTerminal == true

end Battle.Outcome
