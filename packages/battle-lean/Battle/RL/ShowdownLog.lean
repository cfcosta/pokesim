/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0.
-/
import Battle.Full.SelfPlay
import Battle.RL.Showdown

/-!
# Pokémon Showdown simulator-protocol logs

Serializes a completed high-level self-play run as the newline-and-pipe-delimited
battle protocol documented by Pokémon Showdown. RNG-only implementation events
are omitted. Mechanics that have no lossless protocol event are retained as
`|-message|...` rather than fabricated as a different Showdown mechanic.
-/

namespace Battle.RL.ShowdownLog

open Battle.Full

structure TeamContext where
  player : Array MonState
  enemy : Array MonState

private def mons (context : TeamContext) : Side → Array MonState
  | .player => context.player
  | .enemy => context.enemy

private def playerCode : Side → String
  | .player => "p1"
  | .enemy => "p2"

private def playerName : Side → String
  | .player => "Player 1"
  | .enemy => "Player 2"

private def activeIndex (observation : Environment.Observation) : Side → Nat
  | .player => observation.playerActive
  | .enemy => observation.enemyActive

private def species (observation : Environment.Observation) (side : Side) (index : Nat) : SpeciesId :=
  match side with
  | .player => observation.playerSpecies.getD index 0
  | .enemy => observation.enemySpecies.getD index 0

private def activeSpecies (observation : Environment.Observation) (side : Side) : SpeciesId :=
  species observation side (activeIndex observation side)

private def activeMoves (observation : Environment.Observation) : Side → Array MoveId
  | .player => observation.playerMoves
  | .enemy => observation.enemyMoves

private def activeStatus (observation : Environment.Observation) : Side → UInt8
  | .player => observation.playerStatus
  | .enemy => observation.enemyStatus

private def identAt (observation : Environment.Observation) (side : Side) (index : Nat) : String :=
  s!"{playerCode side}a: {Showdown.speciesName (species observation side index)}"

private def ident (observation : Environment.Observation) (side : Side) : String :=
  identAt observation side (activeIndex observation side)

private def detailsAt (context : TeamContext) (observation : Environment.Observation)
    (side : Side) (index : Nat) : String :=
  let fallback := s!"{Showdown.speciesName (species observation side index)}"
  match (mons context side)[index]? with
  | none => fallback
  | some mon =>
      let name := Showdown.speciesName mon.species
      if mon.level == 100 then name else s!"{name}, L{mon.level.toNat}"

private def maxHpAt (context : TeamContext) (side : Side) (index : Nat) : Nat :=
  ((mons context side)[index]?).map (·.maxHp.toNat) |>.getD 1

private def statusName (status : UInt8) : String :=
  if status &&& 0x07 != 0 then "slp"
  else if bitSet status Wram.Status.psn then "psn"
  else if bitSet status Wram.Status.brn then "brn"
  else if bitSet status Wram.Status.frz then "frz"
  else if bitSet status Wram.Status.par then "par"
  else ""

private def condition (context : TeamContext) (side : Side) (index hp : Nat)
    (status : UInt8) : String :=
  if hp == 0 then "0 fnt"
  else
    let base := s!"{hp}/{maxHpAt context side index}"
    let status := statusName status
    if status.isEmpty then base else s!"{base} {status}"

private def cannotActReason : Status.CannotActReason → String
  | .fastAsleep | .wokeUp => "slp"
  | .frozen => "frz"
  | .trapped => "partiallytrapped"
  | .flinched => "flinch"
  | .recharge => "recharge"
  | .selectedMoveDisabled => "Disable"
  | .fullyParalyzed => "par"
  | .confusionSelfHit => "confusion"

structure RenderState where
  playerActive : Nat
  enemyActive : Nat
  playerStatus : UInt8
  enemyStatus : UInt8
  playerHp : Array UInt16
  enemyHp : Array UInt16
  actor : Option Side := none
  pendingAction : Option (Side × Full.Action) := none
  lines : List String := []

private def renderActive (state : RenderState) : Side → Nat
  | .player => state.playerActive
  | .enemy => state.enemyActive

private def setRenderActive (state : RenderState) (side : Side) (index : Nat) : RenderState :=
  match side with
  | .player => { state with playerActive := index }
  | .enemy => { state with enemyActive := index }

private def renderStatus (state : RenderState) : Side → UInt8
  | .player => state.playerStatus
  | .enemy => state.enemyStatus

private def setRenderStatus (state : RenderState) (side : Side) (status : UInt8) : RenderState :=
  match side with
  | .player => { state with playerStatus := status }
  | .enemy => { state with enemyStatus := status }

private def renderHp (state : RenderState) (side : Side) (index : Nat) : UInt16 :=
  match side with
  | .player => state.playerHp.getD index 0
  | .enemy => state.enemyHp.getD index 0

private def setRenderHp (state : RenderState) (side : Side) (index : Nat)
    (hp : UInt16) : RenderState :=
  match side with
  | .player => { state with playerHp := state.playerHp.setIfInBounds index hp }
  | .enemy => { state with enemyHp := state.enemyHp.setIfInBounds index hp }

private def addLine (state : RenderState) (line : String) : RenderState :=
  { state with lines := state.lines ++ [line] }

private def actionLine (observation : Environment.Observation)
    (state : RenderState) (side : Side) : Full.Action → Option String
  | .fight slot =>
      let move := (activeMoves observation side).getD slot.val 0
      some s!"|move|{identAt observation side (renderActive state side)}|{Showdown.moveName move}|{identAt observation side.other (renderActive state side.other)}"
  | .struggle =>
      some s!"|move|{identAt observation side (renderActive state side)}|Struggle|{identAt observation side.other (renderActive state side.other)}"
  | .run => some s!"|message|{playerName side} attempted to run."
  | .item _ => some s!"|message|{playerName side} used an item."
  | .switch _ | .noAction => none

private def flushAction (observation : Environment.Observation)
    (state : RenderState) : RenderState :=
  match state.pendingAction with
  | none => state
  | some (side, action) =>
      let state := { state with pendingAction := none }
      match actionLine observation state side action with
      | none => state
      | some line => addLine state line

private def renderAction (observation : Environment.Observation)
    (state : RenderState) (side : Side) (action : Full.Action) : RenderState :=
  let state := flushAction observation state
  match action with
  | .fight _ | .struggle | .noAction =>
      { state with actor := some side, pendingAction := none }
  | _ => { state with actor := some side, pendingAction := some (side, action) }

private def renderExecutedMove (observation : Environment.Observation)
    (state : RenderState) (side : Side) (move : MoveId) : RenderState :=
  let state := flushAction observation state
  let state := { state with actor := some side, pendingAction := none }
  addLine state s!"|move|{identAt observation side (renderActive state side)}|{Showdown.moveName move}|{identAt observation side.other (renderActive state side.other)}"

private def renderEffect (context : TeamContext) (observation : Environment.Observation)
    (state : RenderState) : Effects.Event → RenderState
  | .rawRng _ _ => state
  | .statusApplied status => match state.actor with
      | none => state
      | some actor =>
          let target := actor.other
          let state := setRenderStatus state target status
          addLine state s!"|-status|{identAt observation target (renderActive state target)}|{statusName status}"
  | .stageChanged target stat amount =>
      addLine state s!"|-message|{playerName target}'s stat {stat} changed by {amount}."
  | .healed amount => match state.actor with
      | none => state
      | some side =>
          let index := renderActive state side
          let hp := min (maxHpAt context side index)
            ((renderHp state side index |>.toNat) + amount.toNat)
          let state := setRenderHp state side index (UInt16.ofNat hp)
          addLine state s!"|-heal|{identAt observation side index}|{condition context side index hp (renderStatus state side)}"
  | .recoil amount => match state.actor with
      | none => state
      | some side =>
          let index := renderActive state side
          let hp := renderHp state side index |>.toNat
          let hpAfter := hp - min hp amount.toNat
          let state := setRenderHp state side index (UInt16.ofNat hpAfter)
          addLine state s!"|-damage|{identAt observation side index}|{condition context side index hpAfter (renderStatus state side)}|[from] Recoil"
  | .screen => addLine state "|-message|A protective screen was raised."
  | .transformed => match state.actor with
      | none => state
      | some side =>
          let target := Showdown.speciesName (species observation side.other (renderActive state side.other))
          addLine state s!"|-transform|{identAt observation side (renderActive state side)}|{target}"
  | .seeded => match state.actor with
      | none => state
      | some side => addLine state s!"|-start|{identAt observation side.other (renderActive state side.other)}|move: Leech Seed"
  | .disabled move _ => match state.actor with
      | none => state
      | some side => addLine state s!"|-start|{identAt observation side.other (renderActive state side.other)}|Disable|{Showdown.moveName move}"
  | .signal _ => state

private def renderEvent (context : TeamContext) (observation after : Environment.Observation)
    (state : RenderState) : Engine.Event → RenderState
  | .action side action => renderAction observation state side action
  | .moveExecuted side move => renderExecutedMove observation state side move
  | .missed side =>
      let state := flushAction observation state
      addLine state s!"|-miss|{identAt observation side.other (renderActive state side.other)}"
  | .ineffective side =>
      let state := flushAction observation state
      addLine state s!"|-immune|{identAt observation side.other (renderActive state side.other)}"
  | .criticalHit side =>
      let state := flushAction observation state
      addLine state s!"|-crit|{identAt observation side.other (renderActive state side.other)}"
  | .superEffective side =>
      let state := flushAction observation state
      addLine state s!"|-supereffective|{identAt observation side.other (renderActive state side.other)}"
  | .rng _ _ => flushAction observation state
  | .effect event => renderEffect context observation (flushAction observation state) event
  | .statusBlocked side reason =>
      let state := { state with pendingAction := none }
      addLine state s!"|cant|{identAt observation side (renderActive state side)}|{cannotActReason reason}"
  | .damage side amount hpAfter =>
      let state := flushAction observation state
      let index := renderActive state side
      let state := setRenderHp state side index hpAfter
      if amount == 0 then state
      else addLine state s!"|-damage|{identAt observation side index}|{condition context side index hpAfter.toNat (renderStatus state side)}"
  | .residualDamage side _ hpAfter =>
      let state := flushAction observation state
      let index := renderActive state side
      let state := setRenderHp state side index hpAfter
      addLine state s!"|-damage|{identAt observation side index}|{condition context side index hpAfter.toNat (renderStatus state side)}"
  | .substituteDamage side _ remaining =>
      let state := flushAction observation state
      addLine state s!"|-message|{playerName side}'s substitute has {remaining.toNat} HP remaining."
  | .fainted side =>
      let state := flushAction observation state
      addLine state s!"|faint|{identAt observation side (renderActive state side)}"
  | .forcedReplacement _ => flushAction observation state
  | .switched side target =>
      let state := flushAction observation state
      let state := setRenderActive state side target
      let state := setRenderStatus state side (activeStatus after side)
      let hp := match side with
        | .player => after.playerHp.getD target 0 |>.toNat
        | .enemy => after.enemyHp.getD target 0 |>.toNat
      addLine state s!"|switch|{identAt after side target}|{detailsAt context after side target}|{condition context side target hp (renderStatus state side)}"
  | .item side _ =>
      let state := flushAction observation state
      addLine state s!"|message|{playerName side} used an item."
  | .terminal _ => flushAction observation state
  | .disobedience _ =>
      let state := flushAction observation state
      addLine state "|-message|The Pokémon ignored its orders."

private def statusDelta (rendered : RenderState) (after : Environment.Observation)
    (side : Side) : List String :=
  let index := activeIndex after side
  let hp := match side with
    | .player => after.playerHp.getD index 0
    | .enemy => after.enemyHp.getD index 0
  if hp == 0 then []
  else
    let oldStatus := renderStatus rendered side
    let newStatus := activeStatus after side
    if oldStatus == newStatus then []
    else if newStatus == 0 then
      [s!"|-curestatus|{ident after side}|{statusName oldStatus}"]
    else [s!"|-status|{ident after side}|{statusName newStatus}"]

private def previewLines (context : TeamContext) : List String :=
  let sideLines := fun (side : Side) => (mons context side).toList.map fun mon =>
    s!"|poke|{playerCode side}|{Showdown.speciesName mon.species}|"
  ["|player|p1|Player 1", "|player|p2|Player 2",
    s!"|teamsize|p1|{context.player.size}", s!"|teamsize|p2|{context.enemy.size}",
    "|gametype|singles", "|gen|1", "|tier|[Gen 1] Custom Game", "|clearpoke"] ++
    sideLines .player ++ sideLines .enemy ++ ["|teampreview", "", "|start"]

private def initialSwitchLines (context : TeamContext) (observation : Environment.Observation) : List String :=
  [.player, .enemy].map fun side =>
    let index := activeIndex observation side
    let hp := match side with
      | .player => observation.playerHp.getD index 0 |>.toNat
      | .enemy => observation.enemyHp.getD index 0 |>.toNat
    s!"|switch|{ident observation side}|{detailsAt context observation side index}|{condition context side index hp (activeStatus observation side)}"

private def winnerLine (run : SelfPlay.Run) : String :=
  match run.finalState.engine.battle.phase with
  | .returned result =>
      if result.terminal.rawResult == 0 then "|win|Player 1"
      else if result.terminal.rawResult == 1 then "|win|Player 2"
      else "|tie"
  | _ => s!"|message|Battle stopped without a result: {reprStr run.stop}"

/-- Serialize one self-play run. The initial state must be the state supplied to
`SelfPlay.runFor`, so team indexes and max HP remain exact across switches. -/
def format (initial : Environment.State) (run : SelfPlay.Run) : String :=
  let context : TeamContext :=
    { player := initial.engine.battle.player.party.mons
      enemy := initial.engine.battle.enemy.party.mons }
  let firstObservation := Environment.observe initial
  let initialLines := previewLines context ++ initialSwitchLines context firstObservation
  let (_, lines) := run.transitions.foldl (fun (cursor, lines) transition =>
    let active := cursor.1
    let displayTurn := cursor.2
    let start : RenderState :=
      { playerActive := active.1, enemyActive := active.2
        playerStatus := transition.before.playerStatus
        enemyStatus := transition.before.enemyStatus
        playerHp := transition.before.playerHp
        enemyHp := transition.before.enemyHp }
    let rendered := transition.events.foldl
      (renderEvent context transition.before transition.after) start |>
      flushAction transition.before
    let hasAction := transition.events.any fun event => match event with
      | .action _ _ => true
      | _ => false
    let upkeep := if hasAction && !transition.after.terminalWitnessed then ["|upkeep"] else []
    let heading := if hasAction then [s!"|turn|{displayTurn}"] else []
    let turnLines := heading ++ rendered.lines ++
      statusDelta rendered transition.after .player ++
      statusDelta rendered transition.after .enemy ++ upkeep
    let nextTurn := if hasAction then displayTurn + 1 else displayTurn
    (((transition.after.playerActive, transition.after.enemyActive), nextTurn), lines ++ turnLines))
    (((firstObservation.playerActive, firstObservation.enemyActive), 1), initialLines)
  String.intercalate "\n" (lines ++ [winnerLine run])

end Battle.RL.ShowdownLog
