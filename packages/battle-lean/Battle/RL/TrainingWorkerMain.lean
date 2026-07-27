/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.RL.Training

/-!
# Native restricted-training worker

Usage:

`battleTrainingWorker [episodes] [seed] [budget] [epsilon-byte] [weights|-] [player|enemy] [emit-transitions]`

Standard output is deterministic JSONL. Diagnostics use standard error. A
weights file contains exactly 166 newline-separated nonnegative integers.
-/

open Battle Battle.RL

private def argumentNat (arguments : List String) (index fallback : Nat) : Nat :=
  (arguments[index]?).bind String.toNat? |>.getD fallback

private def argumentString (arguments : List String) (index : Nat) (fallback : String) : String :=
  arguments[index]?.getD fallback

private def parseScores (content : String) : Option Training.MoveScores := do
  let lines := (content.splitOn "\n").filter fun line => !line.isEmpty
  let values ← lines.mapM String.toNat?
  if values.length == 166 then some values.toArray else none

private def loadScores (path : String) : IO (Option Training.MoveScores) := do
  if path == "-" then pure (some Training.neutralScores)
  else parseScores (← IO.FS.readFile path) |> pure

private def parseSide (raw : String) : Option Side :=
  if raw == "player" then some .player
  else if raw == "enemy" then some .enemy
  else none

private def sideName : Side → String
  | .player => "player"
  | .enemy => "enemy"

private def stopName {state : Environment.State} : SelfPlay.StopReason state → String
  | .finished _ => "finished"
  | .truncated => "truncated"
  | .blocked .player => "blocked-player"
  | .blocked .enemy => "blocked-enemy"
  | .invalidPolicy => "invalid-policy"
  | .rngStuck => "rng-stuck"
  | .divisionFreeze => "division-freeze"

private def finished {state : Environment.State} : SelfPlay.StopReason state → Bool
  | .finished _ => true
  | _ => false

private def controlledReturn (side : Side) (run : SelfPlay.Run) : Int :=
  let result := SelfPlay.playerReturn run.finalState
  match side with
  | .player => result
  | .enemy => -result

private def naturalsJson (values : Array Nat) : String :=
  "[" ++ String.intercalate "," (values.toList.map toString) ++ "]"

private def bytesJson (values : Array UInt8) : String :=
  naturalsJson (values.map UInt8.toNat)

private def sideMoves (observation : Environment.Observation) : Side → Array MoveId
  | .player => observation.playerMoves
  | .enemy => observation.enemyMoves

private def sidePp (observation : Environment.Observation) : Side → Array UInt8
  | .player => observation.playerPp
  | .enemy => observation.enemyPp

private def actionFor (transition : SelfPlay.Transition) : Side → Battle.Action
  | .player => transition.playerAction
  | .enemy => transition.enemyAction

private def selectedMove (observation : Environment.Observation) (side : Side)
    (action : Battle.Action) : MoveId :=
  match action with
  | .fight slot => (sideMoves observation side).getD slot.val 0
  | .struggle => 165
  | _ => 0

private def legalMask (observation : Environment.Observation) (side : Side) : Nat :=
  let moves := sideMoves observation side
  let pp := sidePp observation side
  (List.range Wram.numMoves).foldl (fun mask slot =>
    if Ordinary.supportedMove (moves.getD slot 0) &&
        Ordinary.currentPp (pp.getD slot 0) != 0 then
      mask + 2 ^ slot
    else mask) 0

private def transitionJson (episode step : Nat) (side : Side) (labeled : Bool)
    (reward : Int) (transition : SelfPlay.Transition) : String :=
  let state := Training.policyState transition.before side
  let action := actionFor transition side
  let rewardJson := if labeled then toString reward else "null"
  "{" ++ s!"\"type\":\"transition\",\"episode\":{episode},\"step\":{step},\"side\":\"{sideName side}\",\"state_hash\":\"{Training.fingerprint state}\",\"features\":{naturalsJson (Training.featureVector state)},\"legal_mask\":{legalMask transition.before side},\"action_id\":{Training.actionId action},\"move_id\":{(selectedMove transition.before side action).toNat},\"return\":{rewardJson}" ++ "}"

private structure Counts where
  finished : Nat := 0
  truncated : Nat := 0
  other : Nat := 0
  transitions : Nat := 0

private def runOne (scores : Training.MoveScores) (epsilon budget : Nat)
    (root : UInt64) (episode : Nat) (controlled : Side) : SelfPlay.Run :=
  let model := Training.scoredPolicy scores epsilon
  let playerPolicy := match controlled with | .player => model | .enemy => SelfPlay.randomPolicy
  let enemyPolicy := match controlled with | .player => SelfPlay.randomPolicy | .enemy => model
  SelfPlay.runEpisode budget playerPolicy enemyPolicy
    (Training.linkRng root episode.toUInt64 Training.generatorStream)
    (Training.linkRng root episode.toUInt64 Training.battleStream)
    (Training.linkRng root episode.toUInt64 Training.playerPolicyStream)
    (Training.linkRng root episode.toUInt64 Training.enemyPolicyStream)

private def emitEpisode (episode : Nat) (side : Side) (emitTransitions : Bool)
    (run : SelfPlay.Run) : IO Counts := do
  let isFinished := finished run.stop
  let reward := controlledReturn side run
  let finalObservation := Environment.observe run.finalState
  let finalState := Training.policyState finalObservation side
  let rewardJson := if isFinished then toString reward else "null"
  IO.println ("{" ++ s!"\"type\":\"episode\",\"episode\":{episode},\"stop\":\"{stopName run.stop}\",\"return\":{rewardJson},\"transitions\":{run.transitions.length},\"final_state_hash\":\"{Training.fingerprint finalState}\"" ++ "}")
  if emitTransitions then
    for indexed in run.transitions.zipIdx do
      IO.println (transitionJson episode indexed.2 side isFinished reward indexed.1)
  pure {
    finished := if isFinished then 1 else 0
    truncated := if stopName run.stop == "truncated" then 1 else 0
    other := if isFinished || stopName run.stop == "truncated" then 0 else 1
    transitions := run.transitions.length }

private def addCounts (left right : Counts) : Counts :=
  { finished := left.finished + right.finished
    truncated := left.truncated + right.truncated
    other := left.other + right.other
    transitions := left.transitions + right.transitions }

def main (arguments : List String) : IO UInt32 := do
  let episodes := argumentNat arguments 0 100
  let seed := argumentNat arguments 1 1
  let budget := argumentNat arguments 2 128
  let epsilon := argumentNat arguments 3 32
  let weightsPath := argumentString arguments 4 "-"
  let sideRaw := argumentString arguments 5 "player"
  let emitTransitions := argumentNat arguments 6 1 != 0
  let some scores ← loadScores weightsPath
    | IO.eprintln "weights must contain exactly 166 newline-separated natural numbers"
      return 2
  let some side := parseSide sideRaw
    | IO.eprintln "controlled side must be player or enemy"
      return 2
  IO.println ("{" ++ s!"\"type\":\"meta\",\"schema\":\"{Training.schemaVersion}\",\"entropy\":\"{Training.entropyVersion}\",\"profile\":\"ordinary-link-1v1-perfect-v1\",\"episodes\":{episodes},\"seed\":{seed},\"budget\":{budget},\"epsilon_byte\":{min epsilon 256},\"controlled_side\":\"{sideRaw}\",\"feature_count\":100" ++ "}")
  let mut counts : Counts := {}
  for episode in List.range episodes do
    let run := runOne scores epsilon budget seed.toUInt64 episode side
    counts := addCounts counts (← emitEpisode episode side emitTransitions run)
  IO.eprintln s!"episodes={episodes} finished={counts.finished} truncated={counts.truncated} other={counts.other} transitions={counts.transitions} side={sideRaw}"
  pure 0
