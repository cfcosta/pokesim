/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0.
-/
import Battle.RL.ShowdownLog
import Battle.RL.SelfPlay

/-!
# One-match Pokémon Showdown protocol runner

Usage: `battleSelfPlayLog [episode] [decision-budget]`. Standard output is the
Showdown simulator protocol; diagnostics are written to stderr.
-/

open Battle

private def argumentNat (arguments : List String) (index fallback : Nat) : Nat :=
  (arguments[index]?).bind String.toNat? |>.getD fallback


def main (arguments : List String) : IO UInt32 := do
  let episode := argumentNat arguments 0 0
  let decisions := argumentNat arguments 1 4096
  let generatorSeed := episode * 4 + 1001
  let battleSeed := episode * 4 + 1002
  let playerSeed := episode * 4 + 1003
  let enemySeed := episode * 4 + 1004
  let initial := Full.Environment.reset
    (RL.SelfPlay.seedFrom generatorSeed) (RL.SelfPlay.seedFrom battleSeed)
  let run := Full.SelfPlay.runFor decisions 128
    Full.SelfPlay.damagingPolicy Full.SelfPlay.damagingPolicy initial
    (RL.SelfPlay.seedFrom playerSeed) (RL.SelfPlay.seedFrom enemySeed)
  IO.eprintln s!"episode={episode} transitions={run.transitions.length} stop={reprStr run.stop} repaired={run.finalState.repairedReset}"
  IO.println (RL.ShowdownLog.format initial run)
  pure 0
