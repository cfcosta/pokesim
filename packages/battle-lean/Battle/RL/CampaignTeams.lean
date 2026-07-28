/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.RL.DynamicGenerator

/-!
# Fixed campaign-shaped promotion teams

These progression-witnessed teams patch canonical Red gym-leader and late-game
rosters into the stock-link evaluation profile. They retain generated natural
moves and neutral fixed DVs; they do not claim to reproduce trainer AI, items,
or non-link badge behavior. Their purpose is a stable deployment-shaped
promotion slice rather than training distribution.
-/

namespace Battle.RL.CampaignTeams

open Battle.RL Battle.RL.MoveHistory

structure Template where
  name : String
  team : DynamicGenerator.CanonicalTeam
  history : TeamHistory
  remainingLedger : ResourceLedger
  historyReplays : replayTeam history = some (team.1, remainingLedger)

private def origin (species level : Nat) : Origin :=
  { species := species.toUInt8, level := level.toUInt8
    atkDv := 9, defDv := 9, spdDv := 9, spcDv := 9 }

private def plan (value : Origin) : MonPlan := { origin := value, events := [] }
private def historyOf (origins : Array Origin) : TeamHistory :=
  { initialLedger := DynamicGenerator.defaultLedger, plans := origins.map plan }
private def teamOf (origins : Array Origin) : Team := origins.map acquire

private def brockOrigins : Array Origin :=
  #[origin 0xa9 12, origin 0x22 14] -- Geodude, Onix
private def mistyOrigins : Array Origin :=
  #[origin 0x1b 18, origin 0x98 21] -- Staryu, Starmie
private def surgeOrigins : Array Origin :=
  #[origin 0x06 21, origin 0x54 18, origin 0x55 24] -- Voltorb, Pikachu, Raichu
private def erikaOrigins : Array Origin :=
  #[origin 0xbe 29, origin 0x1e 24, origin 0xbb 29] -- Victreebel, Tangela, Vileplume
private def kogaOrigins : Array Origin :=
  #[origin 0x37 37, origin 0x88 39, origin 0x37 37, origin 0x8f 43]
private def sabrinaOrigins : Array Origin :=
  #[origin 0x26 38, origin 0x2a 37, origin 0x77 38, origin 0x95 43]
private def blaineOrigins : Array Origin :=
  #[origin 0x21 42, origin 0xa3 40, origin 0xa4 42, origin 0x14 47]
private def giovanniOrigins : Array Origin :=
  #[origin 0x12 45, origin 0x76 42, origin 0x10 44, origin 0x07 45, origin 0x01 50]
private def lanceOrigins : Array Origin :=
  #[origin 0x16 58, origin 0x59 56, origin 0x59 56, origin 0xab 60, origin 0x42 62]

private theorem brockLegal :
    teamLegal genDex .canonical (teamOf brockOrigins) = true := by native_decide
private theorem mistyLegal :
    teamLegal genDex .canonical (teamOf mistyOrigins) = true := by native_decide
private theorem surgeLegal :
    teamLegal genDex .canonical (teamOf surgeOrigins) = true := by native_decide
private theorem erikaLegal :
    teamLegal genDex .canonical (teamOf erikaOrigins) = true := by native_decide
private theorem kogaLegal :
    teamLegal genDex .canonical (teamOf kogaOrigins) = true := by native_decide
private theorem sabrinaLegal :
    teamLegal genDex .canonical (teamOf sabrinaOrigins) = true := by native_decide
private theorem blaineLegal :
    teamLegal genDex .canonical (teamOf blaineOrigins) = true := by native_decide
private theorem giovanniLegal :
    teamLegal genDex .canonical (teamOf giovanniOrigins) = true := by native_decide
private theorem lanceLegal :
    teamLegal genDex .canonical (teamOf lanceOrigins) = true := by native_decide

private theorem brockReplay : replayTeam (historyOf brockOrigins) =
    some (teamOf brockOrigins, DynamicGenerator.defaultLedger) := by native_decide
private theorem mistyReplay : replayTeam (historyOf mistyOrigins) =
    some (teamOf mistyOrigins, DynamicGenerator.defaultLedger) := by native_decide
private theorem surgeReplay : replayTeam (historyOf surgeOrigins) =
    some (teamOf surgeOrigins, DynamicGenerator.defaultLedger) := by native_decide
private theorem erikaReplay : replayTeam (historyOf erikaOrigins) =
    some (teamOf erikaOrigins, DynamicGenerator.defaultLedger) := by native_decide
private theorem kogaReplay : replayTeam (historyOf kogaOrigins) =
    some (teamOf kogaOrigins, DynamicGenerator.defaultLedger) := by native_decide
private theorem sabrinaReplay : replayTeam (historyOf sabrinaOrigins) =
    some (teamOf sabrinaOrigins, DynamicGenerator.defaultLedger) := by native_decide
private theorem blaineReplay : replayTeam (historyOf blaineOrigins) =
    some (teamOf blaineOrigins, DynamicGenerator.defaultLedger) := by native_decide
private theorem giovanniReplay : replayTeam (historyOf giovanniOrigins) =
    some (teamOf giovanniOrigins, DynamicGenerator.defaultLedger) := by native_decide
private theorem lanceReplay : replayTeam (historyOf lanceOrigins) =
    some (teamOf lanceOrigins, DynamicGenerator.defaultLedger) := by native_decide

private def template (name : String) (origins : Array Origin)
    (legal : teamLegal genDex .canonical (teamOf origins) = true)
    (replays : replayTeam (historyOf origins) =
      some (teamOf origins, DynamicGenerator.defaultLedger)) : Template :=
  { name
    team := ⟨teamOf origins, legal⟩
    history := historyOf origins
    remainingLedger := DynamicGenerator.defaultLedger
    historyReplays := replays }

def templates : Array Template := #[
  template "Brock" brockOrigins brockLegal brockReplay,
  template "Misty" mistyOrigins mistyLegal mistyReplay,
  template "Lt. Surge" surgeOrigins surgeLegal surgeReplay,
  template "Erika" erikaOrigins erikaLegal erikaReplay,
  template "Koga" kogaOrigins kogaLegal kogaReplay,
  template "Sabrina" sabrinaOrigins sabrinaLegal sabrinaReplay,
  template "Blaine" blaineOrigins blaineLegal blaineReplay,
  template "Giovanni" giovanniOrigins giovanniLegal giovanniReplay,
  template "Lance" lanceOrigins lanceLegal lanceReplay]

def count : Nat := templates.size

def name (index : Nat) : String :=
  (templates[index % count]?).map (·.name) |>.getD "campaign"

def sample (index : Nat) (rng : Rng.LinkRng) : DynamicGenerator.Sample :=
  let selected := templates.getD (index % count)
    (template "Brock" brockOrigins brockLegal brockReplay)
  { team := selected.team
    rng
    repaired := false
    history := selected.history
    remainingLedger := selected.remainingLedger
    historyReplays := selected.historyReplays }

#guard count == 9
#guard (sample 0 Rng.seed0).team.1.size == 2
#guard (sample 8 Rng.seed0).team.1.size == 5

end Battle.RL.CampaignTeams
