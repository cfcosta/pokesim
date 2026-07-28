/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.RL.FullTraining
import Battle.RL.Showdown

/-!
# Persistent six-member full-party search server

The server owns immutable `Full.Environment.State` values and typed Mimic menu
requests. Ordinary simultaneous decisions expose all legal moves and switches;
forced replacement and Mimic expose one real actor plus a no-action waiting
side. Link forfeits are intentionally absent from the training profile.
-/

open Battle Battle.RL Battle.Full

private inductive SearchState where
  | battle (state : Full.Environment.State) (events : List Full.Engine.Event)
  | mimic (state : Full.Environment.State) (actor : Side) (sourceSlot : Fin 4)
      (nextAction : Option Full.Action) (events : List Full.Engine.Event)
  | diverged (state : Full.Environment.State) (reason : String)
      (events : List Full.Engine.Event)

private def SearchState.base : SearchState → Full.Environment.State
  | .battle state _ | .mimic state _ _ _ _ | .diverged state _ _ => state

private def SearchState.events : SearchState → List Full.Engine.Event
  | .battle _ events | .mimic _ _ _ _ events | .diverged _ _ events => events

private def SearchState.requestActor : SearchState → Option Side
  | .battle _ _ | .diverged _ _ _ => none
  | .mimic _ actor _ _ _ => some actor

private def SearchState.sourceSlot : SearchState → Nat
  | .battle _ _ | .diverged _ _ _ => 0
  | .mimic _ _ source _ _ => source.val

private def SearchState.continuation : SearchState → Option Full.Action
  | .battle _ _ | .diverged _ _ _ => none
  | .mimic _ _ _ next _ => next

private def SearchState.divergence : SearchState → Option String
  | .diverged _ reason _ => some reason
  | _ => none

private def SearchState.requestName : SearchState → String
  | .battle state _ =>
      match state.engine.forcedReplacement with
      | none => "battle"
      | some .player => "forced-player"
      | some .enemy => "forced-enemy"
  | .mimic _ .player _ _ _ => "mimic-player"
  | .mimic _ .enemy _ _ _ => "mimic-enemy"
  | .diverged _ _ _ => "silent-divergence"

private def naturalsJson (values : Array Nat) : String :=
  "[" ++ String.intercalate "," (values.toList.map toString) ++ "]"

private def boolJson (value : Bool) : String := if value then "true" else "false"

private def actionMask (actions : Array Full.Action) : Nat :=
  actions.foldl (fun mask action =>
    match FullTraining.actionId action with
    | some id => if id == 12 then mask else mask + 2 ^ id
    | none => mask) 0

private def mimicMask (state : Full.Environment.State) (actor : Side) : Nat :=
  let moves := state.engine.battle.side actor.other |>.active.active.moves
  (List.range 4).foldl (fun mask slot =>
    if moves.getD slot 0 == 0 then mask else mask + 2 ^ slot) 0

private def legalMask : SearchState → Side → Nat
  | .battle state _, side =>
      match state.engine.forcedReplacement with
      | some forced =>
          if forced == side then actionMask (Full.Environment.legalActions state side)
          else 2 ^ 10
      | none => actionMask (Full.Environment.legalActions state side)
  | .mimic state actor _ _ _, side =>
      if actor == side then mimicMask state actor else 2 ^ 10
  | .diverged _ _ _, _ => 2 ^ 10

private def playerReturn (state : Full.Environment.State) : Int :=
  match state.engine.battle.phase with
  | .returned result =>
      match result.terminal.verdict with
      | some .win => 1
      | some .loss => -1
      | some .draw | none => 0
  | _ => 0

private def snapshotFields (search : SearchState) : String :=
  let state := search.base
  let player := FullTraining.featureVector state .player search.requestActor search.sourceSlot
    search.continuation
  let enemy := FullTraining.featureVector state .enemy search.requestActor search.sourceSlot
    search.continuation
  let done := Full.Environment.done state
  let terminal := state.engine.battle.phase.isTerminal
  let result := if done then toString (playerReturn state) else "null"
  let divergence := match search.divergence with
    | none => "null"
    | some reason => s!"\"{reason}\""
  s!"\"player_features\":{naturalsJson player},\"enemy_features\":{naturalsJson enemy},\"player_mask\":{legalMask search .player},\"enemy_mask\":{legalMask search .enemy},\"player_hash\":\"{FullTraining.fingerprint state .player search.requestActor search.sourceSlot search.continuation}\",\"enemy_hash\":\"{FullTraining.fingerprint state .enemy search.requestActor search.sourceSlot search.continuation}\",\"turn\":{state.engine.battle.turn},\"request\":\"{search.requestName}\",\"divergence\":{divergence},\"terminal\":{boolJson terminal},\"done\":{boolJson done},\"return\":{result}"

private def snapshotJson (handle : Nat) (state : SearchState) : String :=
  "{" ++ s!"\"handle\":{handle},{snapshotFields state}" ++ "}"

private def success (request : String) (handle : Nat) (state : SearchState) : String :=
  "{" ++ s!"\"id\":\"{request}\",\"ok\":true,\"handle\":{handle},{snapshotFields state}" ++ "}"

private def simpleSuccess (request fields : String) : String :=
  "{" ++ s!"\"id\":\"{request}\",\"ok\":true{fields}" ++ "}"

private def failure (request reason : String) : String :=
  "{" ++ s!"\"id\":\"{request}\",\"ok\":false,\"error\":\"{reason}\"" ++ "}"

private def token (tokens : List String) (index : Nat) : Option String := tokens[index]?
private def tokenNat (tokens : List String) (index : Nat) : Option Nat :=
  (token tokens index).bind String.toNat?

private def setBattleRng (state : Full.Environment.State) (rng : Rng.LinkRng) :
    Full.Environment.State :=
  { state with engine := { state.engine with battle := { state.engine.battle with rng } } }

private def installFreshChance (search : SearchState) (seed : Nat) : SearchState :=
  let state := search.base
  let chance := Training.linkRng seed.toUInt64 state.engine.battle.turn.toUInt64
    (0x66756c6c2d726f6f : UInt64)
  let state := setBattleRng state chance
  match search with
  | .battle _ events => .battle state events
  | .mimic _ actor source next events => .mimic state actor source next events
  | .diverged _ reason events => .diverged state reason events

private inductive NativeStep where
  | transitioned (state : SearchState)
  | failed (reason : String)
  deriving Nonempty

private def sideName : Side → String
  | .player => "player"
  | .enemy => "enemy"

private def defenderLastMove (state : Full.Environment.State) : Side → MoveId
  | .player => state.engine.enemyLastMove
  | .enemy => state.engine.playerLastMove

/-- Generated Mirror Move against a recorded Mirror Move recurs without
consuming chance or returning to the turn driver. Classify that concrete cycle
as silent divergence instead of using the native call stack as fuel. -/
private def nestedMirrorCycle (state : Full.Environment.State) (actor : Side)
    (move : MoveId) : Bool :=
  move == 119 && defenderLastMove state actor == 119

private def nestedCycleProbe : Full.Environment.State :=
  let state := Full.Environment.resetSized Wram.partyLength
    (Training.linkRng 1 1 Training.generatorStream)
    (Training.linkRng 1 1 Training.battleStream)
  { state with engine := { state.engine with playerLastMove := 119 } }

#guard nestedMirrorCycle nestedCycleProbe .enemy 119
#guard !nestedMirrorCycle nestedCycleProbe .enemy 118

private partial def normalizeResult (prior : List Full.Engine.Event) :
    Full.Environment.StepResult → NativeStep
  | .transitioned state events =>
      .transitioned (.battle (Full.Environment.settle state) (prior ++ events))
  | .nestedMove state actor move events =>
      if nestedMirrorCycle state actor move then
        .transitioned (.diverged state "nested-mirror-move-cycle" (prior ++ events))
      else
        normalizeResult (prior ++ events) (Full.Environment.resumeNested state actor move)
  | .mimicPending state actor source next events =>
      .transitioned (.mimic state actor source next (prior ++ events))
  | .disobediencePending state machine next events =>
      let (raw, rng) := state.engine.battle.rng.next
      normalizeResult (prior ++ events) (Full.Environment.resolveDisobedience
        (setBattleRng state rng) machine next raw)
  | .invalidAction _ side => .failed s!"invalid-action-{sideName side}"
  | .ineffectiveAction _ side => .failed s!"ineffective-action-{sideName side}"
  | .capturePending _ _ _ => .failed "capture-pending-in-link"
  | .rngStuck state events =>
      .transitioned (.diverged state "rng-stuck" (prior ++ events))
  | .divisionFreeze state events =>
      .transitioned (.diverged state "division-freeze" (prior ++ events))
  | .runPending _ _ _ _ => .failed "run-pending-in-link"
  | .wildFaintRunPending _ _ => .failed "wild-run-pending-in-link"
  | .inactive _ => .failed "inactive"

private def nativeDivergenceReason : NativeStep → Option String
  | .transitioned (.diverged _ reason _) => some reason
  | _ => none

#guard nativeDivergenceReason
  (normalizeResult [] (.rngStuck nestedCycleProbe [])) == some "rng-stuck"
#guard nativeDivergenceReason
  (normalizeResult [] (.divisionFreeze nestedCycleProbe [])) == some "division-freeze"

private def firstOrdinaryAction (state : Full.Environment.State) (side : Side) :
    Option Full.Action :=
  (Full.Environment.legalActions state side).find? fun action =>
    FullTraining.actionId action != some 12

private def battleStep (state : Full.Environment.State) (playerId enemyId : Nat) : NativeStep :=
  match state.engine.forcedReplacement with
  | some forced =>
      let forcedId := if forced == .player then playerId else enemyId
      let waitingId := if forced == .player then enemyId else playerId
      if waitingId != 10 then .failed "waiting-side-must-no-action"
      else
        match FullTraining.actionOfId forcedId, firstOrdinaryAction state forced.other with
        | some forcedAction, some waitingAction =>
            let player := if forced == .player then forcedAction else waitingAction
            let enemy := if forced == .enemy then forcedAction else waitingAction
            normalizeResult [] (Full.Environment.step state player enemy)
        | _, _ => .failed "invalid-forced-action"
  | none =>
      match FullTraining.actionOfId playerId, FullTraining.actionOfId enemyId with
      | some player, some enemy =>
          if playerId == 12 || enemyId == 12 then .failed "link-forfeit-disabled"
          else normalizeResult [] (Full.Environment.step state player enemy)
      | _, _ => .failed "invalid-action-id"

private def mimicStep (state : Full.Environment.State) (actor : Side) (source : Fin 4)
    (next : Option Full.Action) (prior : List Full.Engine.Event)
    (playerId enemyId : Nat) : NativeStep :=
  let actorId := if actor == .player then playerId else enemyId
  let waitingId := if actor == .player then enemyId else playerId
  if waitingId != 10 then .failed "waiting-side-must-no-action"
  else if bounded : actorId < 4 then
    normalizeResult prior
      (Full.Environment.resumeMimic state actor source ⟨actorId, bounded⟩ next)
  else .failed "invalid-mimic-target"

private def stepNative (search : SearchState) (playerId enemyId : Nat)
    (freshSeed : Option Nat) : NativeStep :=
  let search := match freshSeed with
    | none => search
    | some seed => installFreshChance search seed
  match search with
  | .battle state _ => battleStep state playerId enemyId
  | .mimic state actor source next events =>
      mimicStep state actor source next events playerId enemyId
  | .diverged state reason events =>
      .transitioned (.diverged state reason events)

private def parseBatchSpec (raw : String) : Option (Nat × Nat × Nat × Nat) :=
  let fields := raw.splitOn ","
  match tokenNat fields 0, tokenNat fields 1, tokenNat fields 2, tokenNat fields 3 with
  | some handle, some player, some enemy, some seed => some (handle, player, enemy, seed)
  | _, _, _, _ => none

private def runBatch (freshChance : Bool) : List String → Array SearchState →
    Array (Nat × SearchState) → Except String (Array SearchState × Array (Nat × SearchState))
  | [], states, results => .ok (states, results)
  | raw :: rest, states, results =>
      match parseBatchSpec raw with
      | none => .error "invalid-batch-step"
      | some (handle, playerId, enemyId, chanceSeed) =>
          match states[handle]? with
          | none => .error "invalid-handle"
          | some state =>
              let chance := if freshChance then some chanceSeed else none
              match stepNative state playerId enemyId chance with
              | .failed reason => .error reason
              | .transitioned next =>
                  let nextHandle := states.size
                  runBatch freshChance rest (states.push next) (results.push (nextHandle, next))

private def compactStates (handles : List Nat) (states : Array SearchState) :
    Option (Array SearchState) :=
  handles.foldlM (fun compact handle => states[handle]?.map compact.push) #[]

private def sideCode : Side → Nat
  | .player => 0
  | .enemy => 1

private def jsonObject (fields : String) : String := "{" ++ fields ++ "}"

private def actionJson (side : Side) (action : Full.Action) : String :=
  let id := (FullTraining.actionId action).getD 255
  jsonObject s!"\"kind\":\"action\",\"side\":{sideCode side},\"action\":{id}"

private def statusBlockedJson (side : Side) : String :=
  jsonObject s!"\"kind\":\"status-blocked\",\"side\":{sideCode side}"

private def effectJson : Full.Effects.Event → Option String
  | .statusApplied status =>
      some (jsonObject s!"\"kind\":\"status-applied\",\"value\":{status}")
  | .stageChanged target _ _ =>
      some (jsonObject s!"\"kind\":\"stage-changed\",\"side\":{sideCode target}")
  | .healed amount =>
      some (jsonObject s!"\"kind\":\"healed\",\"amount\":{amount}")
  | .screen => some (jsonObject "\"kind\":\"screen\"")
  | .transformed => some (jsonObject "\"kind\":\"transformed\"")
  | .seeded => some (jsonObject "\"kind\":\"seeded\"")
  | .disabled _ _ => some (jsonObject "\"kind\":\"disabled\"")
  | .rawRng _ _ | .recoil _ | .signal _ => none

private def eventJson : Full.Engine.Event → Option String
  | .action side action => some (actionJson side action)
  | .effect event => effectJson event
  | .statusBlocked side _ => some (statusBlockedJson side)
  | .damage side amount hp =>
      some (jsonObject s!"\"kind\":\"damage\",\"side\":{sideCode side},\"amount\":{amount},\"hp\":{hp}")
  | .substituteDamage side amount remaining =>
      some (jsonObject s!"\"kind\":\"substitute-damage\",\"side\":{sideCode side},\"amount\":{amount},\"hp\":{remaining}")
  | .fainted side =>
      some (jsonObject s!"\"kind\":\"faint\",\"side\":{sideCode side}")
  | .forcedReplacement side =>
      some (jsonObject s!"\"kind\":\"forced-replacement\",\"side\":{sideCode side}")
  | .switched side target =>
      some (jsonObject s!"\"kind\":\"switch\",\"side\":{sideCode side},\"target\":{target}")
  | .terminal _ => some (jsonObject "\"kind\":\"terminal\"")
  | .disobedience _ => some (jsonObject "\"kind\":\"disobedience\"")
  | .rng _ _ | .item _ _ => none

private def effectiveness (moveType target1 target2 : UInt8) : Nat :=
  let first := TypeChart.matchup moveType target1 |>.toNat
  let second := if target1 == target2 then 10 else TypeChart.matchup moveType target2 |>.toNat
  first * second

private def moveJson (move : MoveId) (target : MonState) : String :=
  let data := Data.moveData move
  jsonObject s!"\"id\":{move},\"name\":\"{Showdown.moveName move}\",\"power\":{data.power},\"type\":{data.type},\"effect\":{data.effect},\"accuracy\":{data.accuracy},\"effectiveness\":{effectiveness data.type target.type1 target.type2}"

private def monJson (mon : MonState) : String :=
  jsonObject s!"\"species\":{mon.species},\"name\":\"{Showdown.speciesName mon.species}\",\"level\":{mon.level},\"hp\":{mon.hp},\"max_hp\":{mon.maxHp},\"status\":{mon.status},\"type1\":{mon.type1},\"type2\":{mon.type2}"

private def sideInspection (state : Full.Environment.State) (side : Side) : String :=
  let full := state.engine.battle.side side
  let synced := full.syncOutgoing
  let party := synced.party.mons.toList.map monJson
  let target := state.engine.battle.side side.other |>.active.active
  let moves := full.active.active.moves.toList.map fun move => moveJson move target
  let stages := full.active.stages
  let volatile := full.active.volatile
  jsonObject s!"\"active\":{full.activeIndex},\"party\":[{String.intercalate "," party}],\"moves\":[{String.intercalate "," moves}],\"stages\":[{stages.attack},{stages.defense},{stages.speed},{stages.special},{stages.accuracy},{stages.evasion}],\"volatile\":[{volatile.status1},{volatile.status2},{volatile.status3},{volatile.disabledMove},{volatile.disabledMoveNumber},{volatile.substituteHp},{volatile.bideAccumulated}]"

private def inspectionFields (search : SearchState) : String :=
  let state := search.base
  let events := search.events.filterMap eventJson
  s!",\"request\":\"{search.requestName}\",\"player\":{sideInspection state .player},\"enemy\":{sideInspection state .enemy},\"events\":[{String.intercalate "," events}]"

private def emit (output : IO.FS.Stream) (line : String) : IO Unit := do
  output.putStr (line ++ "\n")
  output.flush

partial def serve (input output : IO.FS.Stream) (states : Array SearchState) : IO Unit := do
  let raw ← input.getLine
  if raw.isEmpty then pure ()
  else
    let tokens := raw.trimAscii.toString.splitOn "|"
    let request := (token tokens 1).getD "missing"
    match token tokens 0 with
    | some "ping" =>
        emit output (simpleSuccess request
          s!",\"profile\":\"{FullTraining.profileVersion}\",\"schema\":\"{FullTraining.schemaVersion}\",\"chance\":\"fresh-root-v1\",\"feature_count\":{FullTraining.featureCount},\"action_count\":{FullTraining.actionCount},\"party_size\":{Wram.partyLength}")
        serve input output states
    | some "reset" =>
        match tokenNat tokens 2, tokenNat tokens 3 with
        | some root, some episode =>
            let state := Full.Environment.resetSized Wram.partyLength
              (Training.linkRng root.toUInt64 episode.toUInt64 Training.generatorStream)
              (Training.linkRng root.toUInt64 episode.toUInt64 Training.battleStream)
            let state := SearchState.battle state []
            emit output (success request 0 state)
            serve input output #[state]
        | _, _ =>
            emit output (failure request "invalid-reset")
            serve input output states
    | some "reset-append" =>
        match tokenNat tokens 2, tokenNat tokens 3 with
        | some root, some episode =>
            let state := Full.Environment.resetSized Wram.partyLength
              (Training.linkRng root.toUInt64 episode.toUInt64 Training.generatorStream)
              (Training.linkRng root.toUInt64 episode.toUInt64 Training.battleStream)
            let state := SearchState.battle state []
            let handle := states.size
            emit output (success request handle state)
            serve input output (states.push state)
        | _, _ =>
            emit output (failure request "invalid-reset-append")
            serve input output states
    | some "step" =>
        match tokenNat tokens 2, tokenNat tokens 3, tokenNat tokens 4,
            token tokens 5, tokenNat tokens 6 with
        | some handle, some playerId, some enemyId, some mode, some chanceSeed =>
            match states[handle]? with
            | none =>
                emit output (failure request "invalid-handle")
                serve input output states
            | some state =>
                let freshSeed := if mode == "fresh" then some chanceSeed else none
                if mode != "fresh" && mode != "episode" then
                  emit output (failure request "invalid-step-mode")
                  serve input output states
                else
                  match stepNative state playerId enemyId freshSeed with
                  | .failed reason =>
                      emit output (failure request reason)
                      serve input output states
                  | .transitioned next =>
                      let nextHandle := states.size
                      emit output (success request nextHandle next)
                      serve input output (states.push next)
        | _, _, _, _, _ =>
            emit output (failure request "invalid-step")
            serve input output states
    | some "batch" =>
        match token tokens 2 with
        | some rawBatch =>
            match runBatch true (rawBatch.splitOn ";") states #[] with
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
    | some "batch-episode" =>
        match token tokens 2 with
        | some rawBatch =>
            match runBatch false (rawBatch.splitOn ";") states #[] with
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
            emit output (failure request "invalid-batch-episode")
            serve input output states
    | some "inspect" =>
        match tokenNat tokens 2 with
        | some handle =>
            match states[handle]? with
            | some state =>
                emit output (simpleSuccess request (inspectionFields state))
                serve input output states
            | none =>
                emit output (failure request "invalid-handle")
                serve input output states
        | none =>
            emit output (failure request "invalid-inspect")
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
    | some "compact-many" =>
        match token tokens 2 with
        | some rawHandles =>
            let handles := rawHandles.splitOn "," |>.mapM String.toNat?
            match handles.bind (compactStates · states) with
            | some compact =>
                let snapshots := compact.toList.zipIdx.map fun result =>
                  snapshotJson result.2 result.1
                emit output (simpleSuccess request
                  s!",\"snapshots\":[{String.intercalate "," snapshots}]")
                serve input output compact
            | none =>
                emit output (failure request "invalid-compact-many-handle")
                serve input output states
        | none =>
            emit output (failure request "invalid-compact-many")
            serve input output states
    | some "quit" => emit output (simpleSuccess request ",\"stopped\":true")
    | _ =>
        emit output (failure request "unknown-command")
        serve input output states

def main (_ : List String) : IO UInt32 := do
  serve (← IO.getStdin) (← IO.getStdout) #[]
  pure 0
