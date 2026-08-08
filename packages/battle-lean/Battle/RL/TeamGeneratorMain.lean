/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0.
-/
import Battle.RL.SelfPlay
import Battle.RL.Showdown

/-!
# Showdown team generator executable

Usage: `battleGenerateTeams [seed] [party-size]`. Standard output is directly
importable as two Pokémon Showdown team-list sections; diagnostics use stderr.
The two teams come from one banded pair, which is exactly what training
generates, so the preview cannot show a matchup the corpus never contains.
-/

open Battle Battle.RL

private def argumentNat (arguments : List String) (index fallback : Nat) : Nat :=
  (arguments[index]?).bind String.toNat? |>.getD fallback


def main (arguments : List String) : IO UInt32 := do
  let seed := argumentNat arguments 0 1
  let requestedSize := argumentNat arguments 1 6
  let size := max 1 (min Wram.partyLength requestedSize)
  let (player, enemy) := DynamicGenerator.sampleBandedPair size size (SelfPlay.seedFrom seed)
  IO.eprintln s!"generated two progression-witnessed Generation-I teams; seed={seed} size={size} repaired={player.repaired || enemy.repaired}"
  IO.println (Showdown.formatTeam "Generated Team 1" player.team.1)
  IO.println ""
  IO.println (Showdown.formatTeam "Generated Team 2" enemy.team.1)
  pure 0
