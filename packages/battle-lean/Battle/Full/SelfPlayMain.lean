/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Full.SelfPlay
import Battle.RL.SelfPlay

open Battle

structure Stats where
  finished : Nat := 0
  truncated : Nat := 0
  nestedOpen : Nat := 0
  blocked : Nat := 0
  invalid : Nat := 0
  rngStuck : Nat := 0
  divisionFreeze : Nat := 0
  other : Nat := 0
  repaired : Nat := 0
  transitions : Nat := 0

private def runOne (episode : Nat) : Full.SelfPlay.Run :=
  Full.SelfPlay.runEpisode 4096 128 Full.SelfPlay.damagingPolicy Full.SelfPlay.damagingPolicy
    (RL.SelfPlay.seedFrom (episode * 4 + 1001))
    (RL.SelfPlay.seedFrom (episode * 4 + 1002))
    (RL.SelfPlay.seedFrom (episode * 4 + 1003))
    (RL.SelfPlay.seedFrom (episode * 4 + 1004))

private def tally (stats : Stats) (run : Full.SelfPlay.Run) : Stats :=
  let stats := { stats with
    repaired := stats.repaired + if run.finalState.repairedReset then 1 else 0
    transitions := stats.transitions + run.transitions.length }
  match run.stop with
  | .finished => { stats with finished := stats.finished + 1 }
  | .truncated => { stats with truncated := stats.truncated + 1 }
  | .nestedOpen => { stats with nestedOpen := stats.nestedOpen + 1 }
  | .blocked _ => { stats with blocked := stats.blocked + 1 }
  | .invalidAction _ => { stats with invalid := stats.invalid + 1 }
  | .rngStuck => { stats with rngStuck := stats.rngStuck + 1 }
  | .divisionFreeze => { stats with divisionFreeze := stats.divisionFreeze + 1 }
  | _ => { stats with other := stats.other + 1 }

private def stats : Stats :=
  (List.range 100).foldl (fun stats episode => tally stats (runOne episode)) {}

def main : IO UInt32 := do
  IO.println s!"episodes=100 finished={stats.finished} truncated={stats.truncated} nested_open={stats.nestedOpen}"
  IO.println s!"blocked={stats.blocked} invalid={stats.invalid} rng_stuck={stats.rngStuck} division_freeze={stats.divisionFreeze} other={stats.other}"
  IO.println s!"repaired={stats.repaired} transitions={stats.transitions}"
  if stats.finished + stats.truncated == 100 && stats.nestedOpen == 0 &&
      stats.blocked == 0 && stats.invalid == 0 && stats.rngStuck == 0 &&
      stats.divisionFreeze == 0 && stats.other == 0 && stats.repaired == 0 then
    IO.println s!"PASS 100/100 full-party episodes accounted ({stats.finished} finite, {stats.truncated} horizon-open)"
    pure 0
  else
    IO.eprintln "FAIL full-party self-play smoke matrix"
    pure 1
