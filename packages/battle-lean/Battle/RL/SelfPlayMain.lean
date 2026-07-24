/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.RL.SelfPlay

/-!
# Native restricted self-play smoke runner

Runs 100 independently seeded random-policy mirrors. Any repaired reset, invalid
policy transition, blocked state, RNG-stuck state, or horizon truncation fails
the executable; this is a wiring/replay smoke test, not a statistical claim.
-/

open Battle
open Battle.RL

structure BatchStats where
  finished : Nat := 0
  truncated : Nat := 0
  blocked : Nat := 0
  invalid : Nat := 0
  rngStuck : Nat := 0
  repaired : Nat := 0
  playerWins : Nat := 0
  enemyWins : Nat := 0
  draws : Nat := 0
  transitions : Nat := 0

private def classify (stats : BatchStats) (run : SelfPlay.Run) : BatchStats :=
  let stats := { stats with
    transitions := stats.transitions + run.transitions.length
    repaired := stats.repaired + if run.finalState.repairedReset then 1 else 0 }
  match run.stop with
  | .finished _ =>
      let reward := SelfPlay.playerReturn run.finalState
      { stats with
        finished := stats.finished + 1
        playerWins := stats.playerWins + if reward > 0 then 1 else 0
        enemyWins := stats.enemyWins + if reward < 0 then 1 else 0
        draws := stats.draws + if reward == 0 then 1 else 0 }
  | .truncated => { stats with truncated := stats.truncated + 1 }
  | .blocked _ => { stats with blocked := stats.blocked + 1 }
  | .invalidPolicy => { stats with invalid := stats.invalid + 1 }
  | .rngStuck => { stats with rngStuck := stats.rngStuck + 1 }

private def runOne (episode : Nat) : SelfPlay.Run :=
  SelfPlay.runEpisode 256 SelfPlay.randomPolicy SelfPlay.randomPolicy
    (SelfPlay.seedFrom (episode * 4 + 1))
    (SelfPlay.seedFrom (episode * 4 + 2))
    (SelfPlay.seedFrom (episode * 4 + 3))
    (SelfPlay.seedFrom (episode * 4 + 4))

private def stats : BatchStats :=
  (List.range 100).foldl (fun acc episode => classify acc (runOne episode)) {}

def main : IO UInt32 := do
  IO.println s!"episodes=100 finished={stats.finished} truncated={stats.truncated} blocked={stats.blocked}"
  IO.println s!"wins={stats.playerWins} losses={stats.enemyWins} draws={stats.draws} transitions={stats.transitions}"
  IO.println s!"repaired={stats.repaired} invalid={stats.invalid} rng_stuck={stats.rngStuck}"
  if stats.finished == 100 && stats.truncated == 0 && stats.blocked == 0 &&
      stats.invalid == 0 && stats.rngStuck == 0 && stats.repaired == 0 then
    IO.println "PASS 100/100 restricted self-play episodes"
    pure 0
  else
    IO.eprintln "FAIL restricted self-play smoke matrix"
    pure 1
