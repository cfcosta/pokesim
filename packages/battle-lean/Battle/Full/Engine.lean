/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Full.Action
import Battle.Full.Effects
import Battle.Full.Escape
import Battle.Ordinary

/-!
# Full party turn engine

Composes full actions, status gating, effect phases, stat scaling, damage, items,
switching, residuals, fainting, forced replacement, and terminal provenance.
Processor execution is not used in this hot path.
-/

namespace Battle.Full.Engine

structure State where
  battle : Full.State
  playerBag : Items.Bag := []
  enemyBag : Items.Bag := []
  forcedReplacement : Option Side := none
  playerLastMove : MoveId := 0
  enemyLastMove : MoveId := 0
  payDayMoney : Money.Bcd3 := Money.Bcd3.ofNat 0
  playerMoney : Money.Bcd3 := Money.Bcd3.ofNat 0
  trainerPrize : Money.Bcd3 := Money.Bcd3.ofNat 0
  runAttempts : UInt8 := 0
  deriving Repr, DecidableEq

inductive Event where
  | action (side : Side) (action : Full.Action)
  | rng (site : String) (raw : UInt8)
  | effect (event : Effects.Event)
  | statusBlocked (side : Side) (reason : Status.CannotActReason)
  | damage (side : Side) (amount hpAfter : UInt16)
  | substituteDamage (side : Side) (amount remaining : UInt8)
  | fainted (side : Side)
  | forcedReplacement (side : Side)
  | switched (side : Side) (target : Nat)
  | item (side : Side) (events : List Items.Event)
  | terminal (terminal : Outcome.BattleTerminal)
  deriving Repr, DecidableEq

inductive StepResult where
  | transitioned (state : State) (events : List Event)
  | invalidAction (state : State) (side : Side)
  | capturePending (state : State) (ball : UInt8) (events : List Event)
  | rngStuck (state : State) (events : List Event)
  | divisionFreeze (state : State) (events : List Event)
  | nestedMove (state : State) (side : Side) (move : MoveId) (events : List Event)
  | runPending (state : State) (side : Side) (opponentAction : Full.Action)
      (events : List Event)
  | inactive (state : State)
  deriving Repr

private def side (state : State) (who : Side) : Full.SideState := state.battle.side who
private def bag (state : State) : Side → Items.Bag
  | .player => state.playerBag
  | .enemy => state.enemyBag

private def setBag (state : State) : Side → Items.Bag → State
  | .player, bag => { state with playerBag := bag }
  | .enemy, bag => { state with enemyBag := bag }

private def setSide (state : State) (who : Side) (newSide : Full.SideState) : State :=
  { state with battle := state.battle.setSide who newSide }

private def lastMove (state : State) : Side → MoveId
  | .player => state.playerLastMove
  | .enemy => state.enemyLastMove

private def setLastMove (state : State) : Side → MoveId → State
  | .player, move => { state with playerLastMove := move }
  | .enemy, move => { state with enemyLastMove := move }

private def actionContext (state : State) (who : Side) : Full.ActionContext :=
  { side := side state who, bag := bag state who, mode := state.battle.mode,
    forcedReplacement := state.forcedReplacement == some who }

private def currentPp (packed : UInt8) : UInt8 := packed &&& Wram.ppMask
private def decrementPp (packed : UInt8) : UInt8 :=
  let pp := currentPp packed
  if pp == 0 then packed else (packed &&& Wram.ppUpMask) ||| (pp - 1)

private def moveOfAction (state : State) (who : Side) : Full.Action → Option (MoveId × Fin 4)
  | .fight slot => some ((side state who).active.active.moves.getD slot.val 0, slot)
  | .struggle => some (165, 0)
  | _ => none

private def decrementMovePp (state : State) (who : Side) (slot : Fin 4)
    (isStruggle : Bool) : State :=
  if isStruggle then state
  else
    let current := side state who
    let mon := current.active.active
    let mon := { mon with pp := mon.pp.modify slot.val decrementPp }
    setSide state who { current with active := { current.active with active := mon } }

private def effectiveSpeed (fullSide : Full.SideState) : UInt16 :=
  let staged := DamageStats.applyStage fullSide.active.active.speed fullSide.active.stages.speed
  if fullSide.active.active.paralyzed then staged >>> 2 else staged

private def screenUp (defender : Battle.SideState) (special : Bool) : Bool :=
  bitSet defender.volatile.status3
    (if special then Wram.BattleStatus3.hasLightScreenUp else Wram.BattleStatus3.hasReflectUp)

private def offensiveStat (attacker : Battle.SideState) (special critical : Bool) : UInt16 :=
  let base := if special then attacker.active.special else attacker.active.attack
  if critical then base
  else
    let stage := if special then attacker.stages.special else attacker.stages.attack
    let modified := DamageStats.applyStage base stage
    if !special && attacker.active.burned then modified >>> 1 else modified

private def defensiveStat (defender : Battle.SideState) (special critical : Bool) : UInt16 :=
  let base := if special then defender.active.special else defender.active.defense
  if critical then base
  else
    let stage := if special then defender.stages.special else defender.stages.defense
    DamageStats.applyStage base stage

private def requiresAccuracy (mechanic : EffectPlan.Mechanic) (power : UInt8) : Bool :=
  if power != 0 then true else
    match mechanic with
    | .sleep | .confusion | .poison | .paralyze | .statUp _ _ | .statDown _ _
    | .mimic | .leechSeed | .disable => true
    | _ => false

private def bypassesAccuracy (mechanic : EffectPlan.Mechanic)
    (attacker : Battle.SideState) : Bool :=
  mechanic == .swift || bitSet attacker.volatile.status2 Wram.BattleStatus2.usingXAccuracy

private def resolveAccuracy (mechanic : EffectPlan.Mechanic) (move : Step.ResolvedMove)
    (attacker defender : Battle.SideState) (rng : Rng.LinkRng) : Bool × Rng.LinkRng × List Event :=
  if mechanic == .swift then (true, rng, [])
  else if bitSet defender.volatile.status1 Wram.BattleStatus1.invulnerable then (false, rng, [])
  else if bypassesAccuracy mechanic attacker then (true, rng, [])
  else
    let effective := Accuracy.calcHitChance move.accuracy attacker.stages.accuracy defender.stages.evasion
    let (raw, rng) := rng.next
    (Accuracy.hits effective raw, rng, [.rng "accuracy" raw])

private def initialDamage (mechanic : EffectPlan.Mechanic) (moveId : MoveId)
    (move : Step.ResolvedMove) (attacker defender : Battle.SideState) (critical : Bool)
    (rng : Rng.LinkRng) :
    Except (DamageStats.Result × List Event) (UInt16 × Rng.LinkRng × List Event) :=
  match Effects.specialDamage mechanic moveId attacker.active defender.active with
  | .fixedDamage damage => .ok (damage, rng, [])
  | .oneHitKo => .ok (0xFFFF, rng, [])
  | .failed => .ok (0, rng, [])
  | .psywave =>
      let (raw, rng) := rng.next
      let bound := UInt8.ofNat (attacker.active.level.toNat + attacker.active.level.toNat / 2)
      if raw < bound then .ok (UInt16.ofNat raw.toNat, rng, [.rng "psywave" raw])
      else .ok (0, rng, [.rng "psywave-rejected" raw])
  | _ =>
      if move.power == 0 then .ok (0, rng, [])
      else
        let special := TypeChart.isSpecial move.type
        let attack := offensiveStat attacker special critical
        let defense := defensiveStat defender special critical
        match DamageStats.resolve attack defense (screenUp defender special && !critical) with
        | .divisionFreeze stats => .error (.divisionFreeze stats, [])
        | .ready stats =>
            let defense := if mechanic == .explode then
              let halved := stats.defense >>> 1
              if halved == 0 then 1 else halved
              else stats.defense
            let base := Damage.calcBaseDamage attacker.active.level critical move.power
              (UInt16.ofNat stats.attack.toNat) (UInt16.ofNat defense.toNat)
            let typed := Damage.adjustDamageForType move.type attacker.active.type1 attacker.active.type2
              defender.active.type1 defender.active.type2 base
            if typed < 2 then .ok (typed, rng, [])
            else
              match Ordinary.drawDamageFactor rng with
              | none => .ok (0, rng, [])
              | some (factor, rng, ordinaryEvents) =>
                  let events := ordinaryEvents.map fun event => match event with
                    | .rng site raw => Event.rng site raw
                    | _ => Event.rng "damage-factor" factor
                  .ok (Damage.randomizeDamage factor typed, rng, events)

private def effectsContext (state : State) (who : Side) (move : MoveId) (slot : Fin 4)
    (attacker defender : Battle.SideState) (rng : Rng.LinkRng) : Effects.Context :=
  { attacker, defender, move, moveSlot := slot, mode := state.battle.mode, rng,
    payDayMoney := state.payDayMoney, defenderLastMove := lastMove state who.other }

private def installEffectsContext (state : State) (who : Side)
    (context : Effects.Context) : State :=
  let state := setSide state who { side state who with active := context.attacker }
  let state := setSide state who.other { side state who.other with active := context.defender }
  { state with battle := { state.battle with rng := context.rng }, payDayMoney := context.payDayMoney }

private structure DamageApplied where
  state : State
  actualDamage : UInt16
  targetFainted : Bool
  events : List Event

private def applyDamage (state : State) (who : Side) (damage : UInt16) : DamageApplied :=
  let targetWho := who.other
  let target := side state targetWho
  if target.active.volatile.hasSubstitute then
    let old := target.active.volatile.substituteHp
    let actual := min old damage.toUInt8
    let breaks := old.toNat ≤ damage.toNat
    let remaining := if breaks then 0 else old - damage.toUInt8
    let volatile := { target.active.volatile with substituteHp := remaining }
    let volatile := { volatile with status2 := if breaks then target.active.volatile.status2 &&&
      ~~~((1 <<< Wram.BattleStatus2.hasSubstituteUp).toUInt8)
      else target.active.volatile.status2 }
    { state := setSide state targetWho { target with active := { target.active with volatile } },
      actualDamage := UInt16.ofNat actual.toNat, targetFainted := false,
      events := [.substituteDamage targetWho actual remaining] }
  else
    let hp := Step.saturatingSub target.active.active.hp damage
    let actual := target.active.active.hp - hp
    let mon := { target.active.active with hp }
    { state := setSide state targetWho { target with active := { target.active with active := mon } },
      actualDamage := actual, targetFainted := hp == 0,
      events := [.damage who actual hp] }

private def terminalFor (state : State) (fainted : Side) : Outcome.BattleTerminal :=
  Outcome.BattleTerminal.mk' (.partyExhausted fainted) state.battle.mode .player
    (if fainted == .enemy then 0 else 1)

private def recordFaint (state : State) (fainted : Side) : State × List Event :=
  let fullSide := side state fainted
  if fullSide.partyExhausted then
    let terminal := terminalFor state fainted
    let state := { state with battle := { state.battle with phase := .ending terminal } }
    let state := if fainted == .enemy && state.battle.mode == .trainer then
      { state with playerMoney := state.playerMoney.add state.trainerPrize }
      else state
    ({ state with forcedReplacement := none }, [.fainted fainted, .terminal terminal])
  else
    ({ state with forcedReplacement := some fainted },
      [.fainted fainted, .forcedReplacement fainted])

private def applyResidual (state : State) (who : Side) : State × List Event :=
  let result := Status.applyResiduals (side state who).active (side state who.other).active
  let state := setSide state who { side state who with active := result.actor }
  let state := setSide state who.other { side state who.other with active := result.opponent }
  if result.actor.active.fainted then recordFaint state who else (state, [])

private def attack (state : State) (who : Side) (action : Full.Action)
    (overrideMove : Option MoveId := none) (skipStatus : Bool := false) : StepResult :=
  let selected := match overrideMove with
    | some move => some (move, (0 : Fin 4))
    | none => moveOfAction state who action
  match selected with
  | none => .transitioned state []
  | some (moveId, slot) =>
      let state := decrementMovePp state who slot (action == .struggle || overrideMove.isSome)
      let attackerFull := side state who
      let defenderFull := side state who.other
      let statusResult := if skipStatus then
        Status.CheckResult.canAct attackerFull.active state.battle.rng
        else Status.checkCanAct attackerFull.active defenderFull.active.volatile.trapping
          moveId state.battle.rng
      match statusResult with
      | .cannotAct reason attacker rng =>
          let state := setSide { state with battle := { state.battle with rng } } who
            { attackerFull with active := attacker }
          let (state, residualEvents) := applyResidual state who
          .transitioned state (.statusBlocked who reason :: residualEvents)
      | .confusionHit attacker rng raw =>
          let selfStats := DamageStats.resolve attacker.active.attack attacker.active.defense false
          match selfStats with
          | .divisionFreeze _ => .divisionFreeze state [.rng "confusion" raw]
          | .ready stats =>
              let damage := Damage.calcBaseDamage attacker.active.level false 40
                (UInt16.ofNat stats.attack.toNat) (UInt16.ofNat stats.defense.toNat)
              let hp := Step.saturatingSub attacker.active.hp damage
              let attacker := { attacker with active := { attacker.active with hp } }
              let state := setSide { state with battle := { state.battle with rng } } who
                { attackerFull with active := attacker }
              if hp == 0 then
                let (state, events) := recordFaint state who
                .transitioned state (.rng "confusion" raw :: events)
              else
                let (state, events) := applyResidual state who
                .transitioned state (.rng "confusion" raw :: events)
      | .canAct attacker rng =>
          let state := setSide { state with battle := { state.battle with rng } } who
            { attackerFull with active := attacker }
          let move := resolveMove moveId
          let effect := (Data.moveData moveId).effect
          let mechanic := (EffectPlan.plan effect).mechanic
          let (rng, critical, critEvents) :=
            if move.power == 0 then (state.battle.rng, false, [])
            else
              let (raw, rng) := state.battle.rng.next
              let focus := bitSet attacker.volatile.status2 Wram.BattleStatus2.gettingPumped
              let critical := Critical.occurs (Critical.threshold attacker.active.species moveId focus) raw
              (rng, critical, [.rng "critical" raw])
          match initialDamage mechanic moveId move attacker defenderFull.active critical rng with
          | .error _ => .divisionFreeze state critEvents
          | .ok (damage, rng, damageEvents) =>
              let (hit, rng, accuracyEvents) :=
                if requiresAccuracy mechanic move.power then
                  resolveAccuracy mechanic move attacker defenderFull.active rng
                else (true, rng, [])
              let context := effectsContext state who moveId slot attacker defenderFull.active rng
              let before := Effects.applyBefore effect hit context
              let state := installEffectsContext state who before.context
              match before.signal with
              | .rngStuck => .rngStuck state (critEvents ++ damageEvents ++ accuracyEvents ++
                  before.events.map .effect)
              | .charging _ => .transitioned (setLastMove state who moveId)
                  (critEvents ++ before.events.map .effect)
              | .escaped =>
                  let terminal := Outcome.BattleTerminal.mk' (.moveEscape who moveId)
                    state.battle.mode .player (if who == .player then 0 else 1) 1
                  .transitioned { state with battle := { state.battle with phase := .ending terminal } }
                    (before.events.map .effect ++ [.terminal terminal])
              | .callMove nested => .nestedMove state who nested (before.events.map .effect)
              | .failed =>
                  let state := setLastMove state who moveId
                  let (state, events) := applyResidual state who
                  .transitioned state (critEvents ++ accuracyEvents ++ before.events.map .effect ++ events)
              | _ =>
                  let damage := if hit then damage else 0
                  let applied := applyDamage state who damage
                  let context := effectsContext applied.state who moveId slot
                    (side applied.state who).active (side applied.state who.other).active applied.state.battle.rng
                  let after := Effects.applyAfter effect move.type hit applied.targetFainted
                    applied.actualDamage context
                  let state := setLastMove (installEffectsContext applied.state who after.context) who moveId
                  let events := critEvents ++ damageEvents ++ accuracyEvents ++ before.events.map .effect ++
                    applied.events ++ after.events.map .effect
                  if applied.targetFainted then
                    let (state, faintEvents) := recordFaint state who.other
                    .transitioned state (events ++ faintEvents)
                  else
                    let (state, residualEvents) := applyResidual state who
                    .transitioned state (events ++ residualEvents)

private def applySwitch (state : State) (who : Side) (target : Fin 6) : Option State :=
  match state.battle.switchTo who target.val with
  | none => none
  | some battle =>
      let state := { state with battle := battle }
      some { state with forcedReplacement :=
        if state.forcedReplacement == some who then none else state.forcedReplacement }

private def applyItem (state : State) (who : Side) (request : Items.Request) : StepResult :=
  let user : Items.UserState := { side := side state who, bag := bag state who }
  match Items.use state.battle.mode user request with
  | .rejected _ => .invalidAction state who
  | .capturePending user ball =>
      let state := setBag (setSide state who user.side) who user.bag
      .capturePending state ball [.item who [.captureRequested ball]]
  | .escaped user =>
      let state := setBag (setSide state who user.side) who user.bag
      let terminal := Outcome.BattleTerminal.mk' .pokeDollEscape state.battle.mode .player 0 1
      .transitioned { state with battle := { state.battle with phase := .ending terminal } }
        [.item who [.escapedByDoll], .terminal terminal]
  | .committed user itemEvents =>
      let state := setBag (setSide state who user.side) who user.bag
      .transitioned state [.item who itemEvents]

private def isFight : Full.Action → Bool
  | .fight _ | .struggle => true
  | _ => false

private def prependEvents (prior : List Event) : StepResult → StepResult
  | .transitioned state events => .transitioned state (prior ++ events)
  | .capturePending state ball events => .capturePending state ball (prior ++ events)
  | .rngStuck state events => .rngStuck state (prior ++ events)
  | .divisionFreeze state events => .divisionFreeze state (prior ++ events)
  | .nestedMove state side move events => .nestedMove state side move (prior ++ events)
  | .runPending state side action events => .runPending state side action (prior ++ events)
  | .invalidAction state side => .invalidAction state side
  | .inactive state => .inactive state

/-- Resolve one policy turn. Forced replacement is a separate boundary; ordinary
switch/item actions commit before attacks, so attacks target the loaded mon. -/
def step (state : State) (playerAction enemyAction : Full.Action) : StepResult :=
  match state.battle.phase with
  | .battling =>
      if !Full.legal (actionContext state .player) playerAction then .invalidAction state .player
      else if !Full.legal (actionContext state .enemy) enemyAction then .invalidAction state .enemy
      else if state.forcedReplacement.isSome then
        let forced := state.forcedReplacement.getD .player
        let action := if forced == .player then playerAction else enemyAction
        match action with
        | .switch target =>
            match applySwitch state forced target with
            | some state => .transitioned state [.switched forced target.val]
            | none => .invalidAction state forced
        | .run =>
            let terminal := Outcome.BattleTerminal.mk' (.linkRun forced) state.battle.mode .player
              (if forced == .player then 1 else 0)
            .transitioned { state with battle := { state.battle with phase := .ending terminal } }
              [.terminal terminal]
        | _ => .invalidAction state forced
      else
        let processNonFight := fun (state : State) (who : Side) (action : Full.Action) =>
          match action with
          | .switch target => applySwitch state who target
          | _ => some state
        match processNonFight state .player playerAction with
        | none => .invalidAction state .player
        | some state => match processNonFight state .enemy enemyAction with
          | none => .invalidAction state .enemy
          | some state =>
              match playerAction, enemyAction with
              | .item playerRequest, .item enemyRequest =>
                  match applyItem state .player playerRequest with
                  | .transitioned state playerEvents =>
                      prependEvents playerEvents (applyItem state .enemy enemyRequest)
                  | result => result
              | .item request, enemyAction =>
                  match applyItem state .player request with
                  | .transitioned state itemEvents =>
                      if isFight enemyAction then
                        prependEvents itemEvents (attack state .enemy enemyAction)
                      else .transitioned state itemEvents
                  | result => result
              | playerAction, .item request =>
                  match applyItem state .enemy request with
                  | .transitioned state itemEvents =>
                      if isFight playerAction then
                        prependEvents itemEvents (attack state .player playerAction)
                      else .transitioned state itemEvents
                  | result => result
              | .run, _ =>
                  if state.battle.mode == .link then
                    let terminal := Outcome.BattleTerminal.mk' (.linkRun .player)
                      state.battle.mode .player 1
                    .transitioned { state with battle := { state.battle with phase := .ending terminal } }
                      [.terminal terminal]
                  else if state.battle.mode == .trainer then .transitioned state []
                  else .runPending state .player enemyAction []
              | _, .run =>
                  if state.battle.mode == .link then
                    let terminal := Outcome.BattleTerminal.mk' (.linkRun .enemy)
                      state.battle.mode .player 0
                    .transitioned { state with battle := { state.battle with phase := .ending terminal } }
                      [.terminal terminal]
                  else .runPending state .enemy playerAction []
              | _, _ =>
                  if !isFight playerAction && !isFight enemyAction then
                    .transitioned { state with battle := { state.battle with turn := state.battle.turn + 1 } } []
                  else if isFight playerAction && !isFight enemyAction then attack state .player playerAction
                  else if !isFight playerAction && isFight enemyAction then attack state .enemy enemyAction
                  else
                    let playerMove := (moveOfAction state .player playerAction).map
                      (fun pair => resolveMove pair.1) |>.getD (resolveMove 165)
                    let enemyMove := (moveOfAction state .enemy enemyAction).map
                      (fun pair => resolveMove pair.1) |>.getD (resolveMove 165)
                    let (first, _, rng) := Step.turnOrder playerMove.priority enemyMove.priority
                      (effectiveSpeed (side state .player)) (effectiveSpeed (side state .enemy)) state.battle.rng
                    let state := { state with battle := { state.battle with rng } }
                    let firstAction := if first == .player then playerAction else enemyAction
                    match attack state first firstAction with
                    | .transitioned state events =>
                        if state.forcedReplacement.isSome || state.battle.phase.isTerminal then
                          .transitioned state events
                        else
                          let second := first.other
                          let secondAction := if second == .player then playerAction else enemyAction
                          match attack state second secondAction with
                          | .transitioned state more =>
                              .transitioned { state with battle :=
                                { state.battle with turn := state.battle.turn + 1 } } (events ++ more)
                          | result => result
                    | result => result
  | _ => .inactive state

/-- Continue after a failed wild run; the opponent executes the action already
selected for that turn. -/
def resumeFailedRun (state : State) (runner : Side) (opponentAction : Full.Action) : StepResult :=
  if isFight opponentAction then attack state runner.other opponentAction
  else .transitioned state []

/-- Continue a Mirror Move, Metronome, or Mimic request in the same action.
Status gating and PP decrement are not repeated; another nested signal remains an
explicit continuation, so recursive Metronome behavior is not fuel-bounded. -/
def resumeNested (state : State) (who : Side) (move : MoveId) : StepResult :=
  attack state who (.fight 0) (some move) true

/-- Legal actions are exposed directly from the engine state. -/
def legalActions (state : State) (who : Side) : Array Full.Action :=
  Full.legalActions (actionContext state who)

end Battle.Full.Engine
