/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0.
-/
import Battle.RL.ShowdownLog
import Battle.RL.SelfPlay

/-!
# One-match Pokémon Showdown protocol runner

Usage: `battleSelfPlayLog [episode] [decision-budget] [party-size]`. Standard
output is the Showdown simulator protocol; diagnostics are written to stderr.
Party size `0` retains dynamic 1–6 generation; any other value is clamped to
1–6 for both sides.
-/

open Battle

private def argumentNat (arguments : List String) (index fallback : Nat) : Nat :=
  (arguments[index]?).bind String.toNat? |>.getD fallback


def main (arguments : List String) : IO UInt32 := do
  let episode := argumentNat arguments 0 0
  let decisions := argumentNat arguments 1 4096
  let requestedSize := argumentNat arguments 2 0
  let generatorSeed := episode * 4 + 1001
  let battleSeed := episode * 4 + 1002
  let playerSeed := episode * 4 + 1003
  let enemySeed := episode * 4 + 1004
  let initial :=
    if requestedSize == 0 then Full.Environment.reset
      (RL.SelfPlay.seedFrom generatorSeed) (RL.SelfPlay.seedFrom battleSeed)
    else Full.Environment.resetSized requestedSize
      (RL.SelfPlay.seedFrom generatorSeed) (RL.SelfPlay.seedFrom battleSeed)
  let run := Full.SelfPlay.runFor decisions 128
    Full.SelfPlay.damagingPolicy Full.SelfPlay.damagingPolicy initial
    (RL.SelfPlay.seedFrom playerSeed) (RL.SelfPlay.seedFrom enemySeed)
  IO.eprintln s!"episode={episode} party_size={initial.playerReset.1.size}v{initial.enemyReset.1.size} transitions={run.transitions.length} stop={reprStr run.stop} repaired={run.finalState.repairedReset}"
  IO.println (RL.ShowdownLog.format initial run)
  pure 0
