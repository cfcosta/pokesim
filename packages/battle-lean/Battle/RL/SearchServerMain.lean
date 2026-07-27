/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.RL.Training

/-!
# Persistent native search server

The server owns immutable restricted-environment states. A line protocol lets an
external search process reset episodes and derive successor handles without
serializing Lean mechanics state.

Commands are pipe-separated and carry a request ID:

* `ping|id`
* `reset|id|root-seed|episode`
* `step|id|handle|player-action-id|enemy-action-id|episode|0`
* `step|id|handle|player-action-id|enemy-action-id|fresh|chance-seed`
* `batch|id|handle,player-action-id,enemy-action-id,chance-seed;...`
* `compact|id|handle`
* `quit|id`

`fresh` replaces only the hidden chance stream with the named `fresh-root-v1`
fork. It is the search operation: it cannot inspect or clone the episode's
future RNG. `episode` advances the real trajectory with its existing RNG.
Successors are appended as immutable handles, so search can branch from any
prior state.
-/

open Battle Battle.RL

private def naturalsJson (values : Array Nat) : String :=
  "[" ++ String.intercalate "," (values.toList.map toString) ++ "]"

private def legalMask (state : Environment.State) (side : Side) : Nat :=
  (Environment.legalActions state side).foldl (fun mask action =>
    match action with
    | .fight slot => mask + 2 ^ slot.val
    | _ => mask) 0

private def boolJson (value : Bool) : String := if value then "true" else "false"

private def snapshotFields (state : Environment.State) : String :=
  let observation := Environment.observe state
  let player := Training.policyState observation .player
  let enemy := Training.policyState observation .enemy
  let done := Environment.done state
  let terminal := state.battle.phase.isTerminal
  let result := if done then toString (SelfPlay.playerReturn state) else "null"
  s!"\"player_features\":{naturalsJson (Training.featureVector player)},\"enemy_features\":{naturalsJson (Training.featureVector enemy)},\"player_mask\":{legalMask state .player},\"enemy_mask\":{legalMask state .enemy},\"player_hash\":\"{Training.fingerprint player}\",\"enemy_hash\":\"{Training.fingerprint enemy}\",\"turn\":{state.battle.turn},\"terminal\":{boolJson terminal},\"done\":{boolJson done},\"return\":{result}"

private def snapshotJson (handle : Nat) (state : Environment.State) : String :=
  "{" ++ s!"\"handle\":{handle},{snapshotFields state}" ++ "}"

private def success (request : String) (handle : Nat) (state : Environment.State) : String :=
  "{" ++ s!"\"id\":\"{request}\",\"ok\":true,\"handle\":{handle},{snapshotFields state}" ++ "}"

private def simpleSuccess (request fields : String) : String :=
  "{" ++ s!"\"id\":\"{request}\",\"ok\":true{fields}" ++ "}"

private def failure (request reason : String) : String :=
  "{" ++ s!"\"id\":\"{request}\",\"ok\":false,\"error\":\"{reason}\"" ++ "}"

private def token (tokens : List String) (index : Nat) : Option String := tokens[index]?
private def tokenNat (tokens : List String) (index : Nat) : Option Nat :=
  (token tokens index).bind String.toNat?

private def actionAt (id : Nat) : Option Battle.Action :=
  match Training.actionOfId id with
  | some action@(.fight _) => some action
  | _ => none

private def installFreshChance (state : Environment.State) (seed : Nat) : Environment.State :=
  let chance := Training.linkRng (seed.toUInt64) (state.battle.turn.toUInt64)
    (0x66726573682d726f : UInt64)
  { state with battle := { state.battle with rng := chance } }

private inductive NativeStep where
  | transitioned (state : Environment.State)
  | failed (state : Environment.State) (reason : String)

private def stepNative (state : Environment.State) (player enemy : Battle.Action)
    (freshSeed : Option Nat) : NativeStep :=
  let state := match freshSeed with
    | none => state
    | some seed => installFreshChance state seed
  match Environment.step state player enemy with
  | .transitioned next _ => .transitioned (Environment.settle next)
  | .invalidAction next => .failed next "invalid-action"
  | .rngStuck next _ => .failed next "rng-stuck"
  | .divisionFreeze next _ => .failed next "division-freeze"
  | .inactive next => .failed next "inactive"

private def parseBatchSpec (raw : String) : Option (Nat × Nat × Nat × Nat) :=
  let fields := raw.splitOn ","
  match tokenNat fields 0, tokenNat fields 1, tokenNat fields 2, tokenNat fields 3 with
  | some handle, some player, some enemy, some seed => some (handle, player, enemy, seed)
  | _, _, _, _ => none

private def runBatch : List String → Array Environment.State →
    Array (Nat × Environment.State) →
    Except String (Array Environment.State × Array (Nat × Environment.State))
  | [], states, results => .ok (states, results)
  | raw :: rest, states, results =>
      match parseBatchSpec raw with
      | none => .error "invalid-batch-step"
      | some (handle, playerId, enemyId, chanceSeed) =>
          match states[handle]?, actionAt playerId, actionAt enemyId with
          | some state, some player, some enemy =>
              match stepNative state player enemy (some chanceSeed) with
              | .transitioned next =>
                  let nextHandle := states.size
                  runBatch rest (states.push next) (results.push (nextHandle, next))
              | .failed _ reason => .error reason
          | _, _, _ => .error "invalid-handle-or-action"

private def emit (output : IO.FS.Stream) (line : String) : IO Unit := do
  output.putStr (line ++ "\n")
  output.flush

partial def serve (input output : IO.FS.Stream) (states : Array Environment.State) : IO Unit := do
  let raw ← input.getLine
  if raw.isEmpty then pure ()
  else
    let tokens := raw.trimAscii.toString.splitOn "|"
    let request := (token tokens 1).getD "missing"
    match token tokens 0 with
    | some "ping" =>
        emit output (simpleSuccess request
          s!",\"schema\":\"{Training.schemaVersion}\",\"chance\":\"fresh-root-v1\"")
        serve input output states
    | some "reset" =>
        match tokenNat tokens 2, tokenNat tokens 3 with
        | some root, some episode =>
            let state := Environment.reset
              (Training.linkRng root.toUInt64 episode.toUInt64 Training.generatorStream)
              (Training.linkRng root.toUInt64 episode.toUInt64 Training.battleStream)
            emit output (success request 0 state)
            serve input output #[state]
        | _, _ =>
            emit output (failure request "invalid-reset")
            serve input output states
    | some "step" =>
        match tokenNat tokens 2, tokenNat tokens 3, tokenNat tokens 4,
            token tokens 5, tokenNat tokens 6 with
        | some handle, some playerId, some enemyId, some mode, some chanceSeed =>
            match states[handle]?, actionAt playerId, actionAt enemyId with
            | some state, some player, some enemy =>
                let freshSeed := if mode == "fresh" then some chanceSeed else none
                if mode != "fresh" && mode != "episode" then
                  emit output (failure request "invalid-step-mode")
                  serve input output states
                else
                  match stepNative state player enemy freshSeed with
                  | .transitioned next =>
                      let nextHandle := states.size
                      emit output (success request nextHandle next)
                      serve input output (states.push next)
                  | .failed _ reason =>
                      emit output (failure request reason)
                      serve input output states
            | _, _, _ =>
                emit output (failure request "invalid-handle-or-action")
                serve input output states
        | _, _, _, _, _ =>
            emit output (failure request "invalid-step")
            serve input output states
    | some "batch" =>
        match token tokens 2 with
        | some rawBatch =>
            let specs := rawBatch.splitOn ";"
            if specs.isEmpty then
              emit output (failure request "empty-batch")
              serve input output states
            else
              match runBatch specs states #[] with
              | .error reason =>
                  emit output (failure request reason)
                  serve input output states
              | .ok (nextStates, results) =>
                  let snapshots := results.toList.map fun result =>
                    snapshotJson result.1 result.2
                  emit output (simpleSuccess request
                    s!",\"snapshots\":[{String.intercalate "," snapshots}]")
                  serve input output nextStates
        | none =>
            emit output (failure request "invalid-batch")
            serve input output states
    | some "compact" =>
        match tokenNat tokens 2 with
        | some handle =>
            match states[handle]? with
            | some state =>
                emit output (success request 0 state)
                serve input output #[state]
            | none =>
                emit output (failure request "invalid-handle")
                serve input output states
        | none =>
            emit output (failure request "invalid-compact")
            serve input output states
    | some "quit" => emit output (simpleSuccess request ",\"stopped\":true")
    | _ =>
        emit output (failure request "unknown-command")
        serve input output states

def main (_ : List String) : IO UInt32 := do
  serve (← IO.getStdin) (← IO.getStdout) #[]
  pure 0
