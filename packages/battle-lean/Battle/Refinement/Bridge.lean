/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.State
import Battle.Episode

/-!
# Refinement bridge — model vocabulary → `Battle.Episode`

The `Refinement/` seam (`COORDINATION.md`, seam 2) is where my pure battle model
meets GPT's `Battle.Episode` protocol. `Episode.State` carries *no* mon data — it
is phase / turn / machine-cycle counters over a relational `Step` `Prop`, with its
**own** `TerminalCause` / `Result` / `TerminalWitness` vocabulary, distinct from
`Battle.Outcome`'s richer model-side names. So the bridge is *protocol-level*: it
translates the finished-battle provenance my model produces into the thinner
witness the episode spec speaks, and (in `Refinement/Trace.lean`) the model's
`TurnEvent` stream into an `Episode.Step*` path.

This module is the **vocabulary half**: three total maps and a witness builder.
Nothing here edits `Battle.Episode` — every definition lands in `Battle.Refinement`.

## The maps

* `toEpisodeSide` — `Battle.Side → Episode.Side` (identity on the two tags).
* `toEpisodeResult` / `resultOfVerdict` — `BattleVerdict → Episode.Result`. The
  optional form recovers **ROM** fidelity for an undefined `wBattleResult`: after
  `cp $1` (`engine/battle/end_of_battle.asm:14-27`) any byte `≥ 2` is a draw, so a
  `verdictOfRaw = none` (raw `≥ 3`) still projects to `.draw`, exactly as the
  cartridge would classify it.
* `toEpisodeCause` — `Battle.Outcome.TerminalCause → Episode.TerminalCause`. The
  model distinguishes exit paths the episode spec collapses (Teleport vs POKé DOLL
  vs ordinary run all read as `escaped`; Safari enemy-ran and an enemy Teleport
  both as `enemyEscaped`); the tutorial's scripted auto-capture maps to `scripted`,
  not `captured`, to keep it separable from a real ball capture.

## The witness

`toEpisodeWitness` reads a *terminal* `BattleState` — one whose `phase` is
`.ending` or `.returned` — and assembles the `Episode.TerminalWitness`: result and
cause from the retained `BattleTerminal`, `turn` from the state counter, and both
sides' active HP. A still-`battling` state has no terminal provenance yet, so it
maps to `none`.
-/

namespace Battle.Refinement

/-! ## Side -/

/-- `Battle.Side → Episode.Side` — the two protocols name the sides identically. -/
def toEpisodeSide : Side → Episode.Side
  | .player => .player
  | .enemy => .enemy

/-! ## Result / verdict -/

/-- `BattleVerdict → Episode.Result` — a defined `wBattleResult` byte. -/
def toEpisodeResult : Outcome.BattleVerdict → Episode.Result
  | .win => .win
  | .loss => .loss
  | .draw => .draw

/-- Project the model's optional verdict to an episode result. `none` (an
    undefined `wBattleResult`, i.e. raw `≥ 3`) becomes `.draw`, matching
    `EndOfBattle`'s `cp $1` fallthrough where every byte `≥ 2` is a draw. -/
def resultOfVerdict : Option Outcome.BattleVerdict → Episode.Result
  | some v => toEpisodeResult v
  | none => .draw

/-! ## Terminal cause -/

/-- `Battle.Outcome.TerminalCause → Episode.TerminalCause`. Several model exit
    paths intentionally collapse onto one episode cause — the episode spec is the
    coarser, presentation-independent view (`COORDINATION.md` seam 2). -/
def toEpisodeCause : Outcome.TerminalCause → Episode.TerminalCause
  | .partyExhausted .enemy => .enemyPartyExhausted
  | .partyExhausted .player => .playerPartyExhausted
  | .ordinaryRun => .escaped
  | .moveEscape .player _ => .escaped
  | .moveEscape .enemy _ => .enemyEscaped
  | .pokeDollEscape => .escaped
  | .capture => .captured
  | .safariEnemyRan => .enemyEscaped
  | .safariBallsExhausted => .escaped
  | .linkRun side => .linkForfeit (toEpisodeSide side)
  | .tutorialCapture => .scripted

/-! ## Witness builder -/

/-- Build the episode's `TerminalWitness` from a terminal `BattleState`. Reads the
    retained `BattleTerminal` (from `.ending`/`.returned`) for result + cause, the
    turn counter, and both active mons' HP. A `.battling` state has no terminal
    yet, hence `none`. -/
def toEpisodeWitness (s : BattleState) : Option Episode.TerminalWitness :=
  match s.phase with
  | .ending bt =>
      some { result := resultOfVerdict bt.verdict,
             cause := toEpisodeCause bt.cause,
             turn := s.turn,
             playerActiveHP := (s.active .player).hp,
             enemyActiveHP := (s.active .enemy).hp }
  | .returned res =>
      some { result := resultOfVerdict res.terminal.verdict,
             cause := toEpisodeCause res.terminal.cause,
             turn := s.turn,
             playerActiveHP := (s.active .player).hp,
             enemyActiveHP := (s.active .enemy).hp }
  | .battling => none

/-! ## Fidelity guards -/

-- Side is the identity map on tags.
#guard decide (toEpisodeSide .player = Episode.Side.player)
#guard decide (toEpisodeSide .enemy = Episode.Side.enemy)

-- Verdict → result, and the ROM-faithful `none → draw` fallthrough.
#guard decide (toEpisodeResult .win = Episode.Result.win)
#guard decide (toEpisodeResult .loss = Episode.Result.loss)
#guard decide (toEpisodeResult .draw = Episode.Result.draw)
#guard decide (resultOfVerdict (some .win) = Episode.Result.win)
#guard decide (resultOfVerdict none = Episode.Result.draw)

-- Every terminal cause, including the collapsing ones.
#guard decide (toEpisodeCause (.partyExhausted .enemy) = Episode.TerminalCause.enemyPartyExhausted)
#guard decide (toEpisodeCause (.partyExhausted .player) = Episode.TerminalCause.playerPartyExhausted)
#guard decide (toEpisodeCause .ordinaryRun = Episode.TerminalCause.escaped)
#guard decide (toEpisodeCause (.moveEscape .player 100) = Episode.TerminalCause.escaped)
#guard decide (toEpisodeCause (.moveEscape .enemy 100) = Episode.TerminalCause.enemyEscaped)
#guard decide (toEpisodeCause .pokeDollEscape = Episode.TerminalCause.escaped)
#guard decide (toEpisodeCause .capture = Episode.TerminalCause.captured)
#guard decide (toEpisodeCause .safariEnemyRan = Episode.TerminalCause.enemyEscaped)
#guard decide (toEpisodeCause .safariBallsExhausted = Episode.TerminalCause.escaped)
#guard decide (toEpisodeCause (.linkRun .player) = Episode.TerminalCause.linkForfeit .player)
#guard decide (toEpisodeCause (.linkRun .enemy) = Episode.TerminalCause.linkForfeit .enemy)
#guard decide (toEpisodeCause .tutorialCapture = Episode.TerminalCause.scripted)

-- Witness builder over a concrete terminal state (enemy fainted → player win).
private def m0 : MonState :=
  { species := 6, hp := 100, boxLevel := 50, status := 0, type1 := 0x14, type2 := 0x02,
    catchRate := 45, moves := #[52, 0, 0, 0], dvs := 0xFFFF, level := 50,
    maxHp := 100, attack := 80, defense := 70, speed := 100, special := 90, pp := #[15, 0, 0, 0] }

private def winTerminal : Outcome.BattleTerminal :=
  Outcome.BattleTerminal.mk' (.partyExhausted .enemy) .wild .player 0

private def termState : BattleState :=
  { BattleState.start m0 { m0 with hp := 0 } Rng.seed0 with
      phase := .ending winTerminal, turn := 3 }

#guard decide (toEpisodeWitness termState =
  some { result := .win, cause := .enemyPartyExhausted, turn := 3,
         playerActiveHP := 100, enemyActiveHP := 0 })
-- A still-battling state carries no terminal provenance.
#guard decide (toEpisodeWitness (BattleState.start m0 m0 Rng.seed0) = none)

end Battle.Refinement
