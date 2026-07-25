/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Full.Action
import Battle.Full.Effects
import Battle.Full.Escape
import Battle.Full.Disobedience
import Battle.Full.Selection
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
  sharedDamage : UInt16 := 0
  playerLockedDamage : UInt16 := 0
  enemyLockedDamage : UInt16 := 0
  playerId : UInt16 := 0
  playerOtIds : Array UInt16 := #[]
  badges : UInt8 := 0xff
  playerSelection : Selection.MoveScratch := {}
  enemySelection : Selection.MoveScratch := {}
  runAttempts : UInt8 := 0
  canceledAction : Option Side := none
  aiLayer2Encouragement : UInt8 := 0
  trainerAiItem : Bool := false
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
  | disobedience (result : Disobedience.Result)
  deriving Repr, DecidableEq

inductive StepResult where
  | transitioned (state : State) (events : List Event)
  | invalidAction (state : State) (side : Side)
  | capturePending (state : State) (ball : UInt8) (events : List Event)
  | rngStuck (state : State) (events : List Event)
  | divisionFreeze (state : State) (events : List Event)
  | nestedMove (state : State) (side : Side) (move : MoveId) (events : List Event)
  | mimicPending (state : State) (side : Side) (sourceSlot : Fin 4)
      (nextAction : Option Full.Action) (events : List Event)
  | runPending (state : State) (side : Side) (opponentAction : Full.Action)
      (events : List Event)
  | disobediencePending (state : State) (machine : Disobedience.Machine)
      (nextEnemyAction : Option Full.Action) (events : List Event)
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

def generatedMoveIdentity (wrapper executed : MoveId) (generated : Bool) : MoveId :=
  if generated then wrapper else executed

@[simp] theorem generated_charge_reloads_wrapper (wrapper executed : MoveId) :
    generatedMoveIdentity wrapper executed true = wrapper := rfl

private def recordExecutedMove (state : State) (who : Side) (move : MoveId)
    (generated : Bool) : State :=
  setLastMove state who (generatedMoveIdentity (lastMove state who) move generated)

private def selection (state : State) : Side → Selection.MoveScratch
  | .player => state.playerSelection
  | .enemy => state.enemySelection

private def setSelection (state : State) : Side → Selection.MoveScratch → State
  | .player, scratch => { state with playerSelection := scratch }
  | .enemy, scratch => { state with enemySelection := scratch }

private def commitSelection (state : State) (who : Side) (action : Full.Action) : State :=
  match action with
  | .fight slot =>
      let selectionState : Selection.State :=
        { side := side state who, bag := bag state who, scratch := selection state who,
          runAttempts := state.runAttempts }
      let selectionState := if who == .player then (Selection.openFight selectionState).1
        else selectionState
      let selectionState := (Selection.highlight selectionState slot).1
      { (setSelection state who selectionState.scratch) with
        runAttempts := selectionState.runAttempts }
  | .struggle =>
      let data := Data.moveData 165
      let scratch := { selection state who with selectedMove := 165 }
      let scratch := { scratch with power := data.power }
      let scratch := { scratch with type := data.type }
      setSelection state who scratch
  | _ => state

private def lockedDamage (state : State) : Side → UInt16
  | .player => state.playerLockedDamage
  | .enemy => state.enemyLockedDamage

private def setLockedDamage (state : State) : Side → UInt16 → State
  | .player, damage => { state with playerLockedDamage := damage }
  | .enemy, damage => { state with enemyLockedDamage := damage }

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
  | .noAction =>
      let volatile := (side state who).active.volatile
      if volatile.chargingUp || volatile.trapping ||
          bitSet volatile.status1 Wram.BattleStatus1.storingEnergy ||
          bitSet volatile.status1 Wram.BattleStatus1.thrashingAbout ||
          bitSet volatile.status2 Wram.BattleStatus2.usingRage then
        some (lastMove state who, 0)
      else none
  | _ => none

def decrementMovePp (state : State) (who : Side) (slot : Fin 4)
    (isStruggle : Bool) : State :=
  if isStruggle || who == .enemy then state
  else
    let current := side state who
    let mon := current.active.active
    let mon := { mon with pp := mon.pp.modify slot.val decrementPp }
    setSide state who { current with active := { current.active with active := mon } }

@[simp] theorem enemy_pp_not_decremented (state : State) (slot : Fin 4)
    (isStruggle : Bool) :
    decrementMovePp state .enemy slot isStruggle = state := by
  have enemySelf : (Side.enemy == Side.enemy) = true := by native_decide
  simp [decrementMovePp, enemySelf]

private def effectiveSpeed (fullSide : Full.SideState) : UInt16 :=
  fullSide.active.active.speed

private def screenUp (defender : Battle.SideState) (special : Bool) : Bool :=
  bitSet defender.volatile.status3
    (if special then Wram.BattleStatus3.hasLightScreenUp else Wram.BattleStatus3.hasReflectUp)

private def offensiveStat (attacker : Battle.SideState) (special critical : Bool) : UInt16 :=
  if critical then
    if special then attacker.unmodified.special else attacker.unmodified.attack
  else if special then attacker.active.special else attacker.active.attack

private def defensiveStat (defender : Battle.SideState) (special critical : Bool) : UInt16 :=
  if critical then
    if special then defender.unmodified.special else defender.unmodified.defense
  else if special then defender.active.special else defender.active.defense

private def requiresAccuracy (mechanic : EffectPlan.Mechanic) (power : UInt8) : Bool :=
  if power != 0 then true else
    match mechanic with
    | .sleep | .confusion | .poison | .paralyze | .statDown _ _
    | .mimic | .leechSeed | .disable => true
    | _ => false

private def bypassesAccuracy (mechanic : EffectPlan.Mechanic)
    (attacker : Battle.SideState) : Bool :=
  mechanic == .swift || bitSet attacker.volatile.status2 Wram.BattleStatus2.usingXAccuracy

/-- Eligibility gates executed by ResidualEffects1 handlers before their own
`MoveHitTest` call. Rejection here consumes no accuracy byte. -/
private def rejectsBeforeAccuracy (mechanic : EffectPlan.Mechanic)
    (move : Step.ResolvedMove) (defender : Battle.SideState) : Bool :=
  match mechanic with
  | .sleep => !defender.volatile.recharging && defender.active.status != 0
  | .poison => defender.volatile.hasSubstitute || defender.active.status != 0 ||
      defender.active.type1 == TypeChart.poison || defender.active.type2 == TypeChart.poison
  | .paralyze => defender.active.status != 0 ||
      (move.type == TypeChart.electric &&
        (defender.active.type1 == TypeChart.ground ||
          defender.active.type2 == TypeChart.ground))
  | .confusion => defender.volatile.hasSubstitute
  | .dreamEater => !defender.active.asleep
  | .statDown _ _ => defender.volatile.hasSubstitute ||
      bitSet defender.volatile.status2 Wram.BattleStatus2.protectedByMist
  | _ => false

def resolveAccuracy (mechanic : EffectPlan.Mechanic) (move : Step.ResolvedMove)
    (attacker defender : Battle.SideState) (rng : Rng.LinkRng) : Bool × Rng.LinkRng × List Event :=
  if mechanic == .swift then (true, rng, [])
  else if bitSet defender.volatile.status1 Wram.BattleStatus1.invulnerable then (false, rng, [])
  else if bypassesAccuracy mechanic attacker then (true, rng, [])
  else
    let effective := Accuracy.calcHitChance move.accuracy attacker.stages.accuracy defender.stages.evasion
    let (raw, rng) := rng.next
    (Accuracy.hits effective raw, rng, [.rng "accuracy" raw])

/-- Swift returns before invulnerability, Substitute/Mist policy, X Accuracy, and
the final random draw. -/
theorem swift_precedes_accuracy_gates (move : Step.ResolvedMove)
    (attacker defender : Battle.SideState) (rng : Rng.LinkRng) :
    resolveAccuracy .swift move attacker defender rng = (true, rng, []) := by
  rfl

private def drawPsywave : Nat → Side → UInt8 → Rng.LinkRng →
    Option (UInt8 × Rng.LinkRng × List Event)
  | 0, _, _, _ => none
  | fuel + 1, who, bound, rng =>
      let (raw, rng) := rng.next
      let perspective := if who == .player then LinkBugs.PsywavePerspective.playerAttack
        else .enemyAttack
      if LinkBugs.psywaveAccepts perspective bound raw then
        some (raw, rng, [.rng "psywave" raw])
      else match drawPsywave fuel who bound rng with
        | none => none
        | some (accepted, rng, events) =>
            some (accepted, rng, .rng "psywave-rejected" raw :: events)

private def initialDamage (mechanic : EffectPlan.Mechanic) (moveId : MoveId) (who : Side)
    (move : Step.ResolvedMove) (attacker defender : Battle.SideState) (critical : Bool)
    (rng : Rng.LinkRng) :
    Except (DamageStats.Result × List Event)
      (UInt16 × Rng.LinkRng × List Event × Bool) :=
  match Effects.specialDamage mechanic moveId attacker.active defender.active with
  | .fixedDamage damage => .ok (damage, rng, [], false)
  | .oneHitKo =>
      let typed := Damage.adjustDamageForType move.type attacker.active.type1
        attacker.active.type2 defender.active.type1 defender.active.type2 0xFFFF
      if typed < 2 then .ok (typed, rng, [], typed == 0)
      else
        match Ordinary.drawDamageFactor rng with
        | none => .ok (0, rng, [], false)
        | some (factor, rng, ordinaryEvents) =>
            let events := ordinaryEvents.map fun event => match event with
              | .rng site raw => Event.rng site raw
              | _ => Event.rng "damage-factor" factor
            .ok (Damage.randomizeDamage factor typed, rng, events, false)
  | .failed => .ok (0, rng, [], false)
  | .psywave =>
      let bound := UInt8.ofNat (attacker.active.level.toNat + attacker.active.level.toNat / 2)
      match drawPsywave 2305 who bound rng with
      | none => .ok (0, rng, [], false)
      | some (damage, rng, events) =>
          .ok (UInt16.ofNat damage.toNat, rng, events, false)
  | _ =>
      if move.power == 0 then .ok (0, rng, [], false)
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
            if typed < 2 then .ok (typed, rng, [], typed == 0)
            else
              match Ordinary.drawDamageFactor rng with
              | none => .ok (0, rng, [], false)
              | some (factor, rng, ordinaryEvents) =>
                  let events := ordinaryEvents.map fun event => match event with
                    | .rng site raw => Event.rng site raw
                    | _ => Event.rng "damage-factor" factor
                  .ok (Damage.randomizeDamage factor typed, rng, events, false)

private def effectsContext (state : State) (who : Side) (move : MoveId) (slot : Fin 4)
    (attacker defender : Battle.SideState) (rng : Rng.LinkRng) : Effects.Context :=
  { attackerSide := who, attacker, defender, move, moveSlot := slot,
    mode := state.battle.mode, rng, payDayMoney := state.payDayMoney,
    defenderLastMove := lastMove state who.other, badges := state.badges }

private def installEffectsContext (state : State) (who : Side)
    (context : Effects.Context) : State :=
  let state := setSide state who { side state who with active := context.attacker }
  let state := setSide state who.other { side state who.other with active := context.defender }
  { state with battle := { state.battle with rng := context.rng }, payDayMoney := context.payDayMoney }

private structure DamageApplied where
  state : State
  actualDamage : UInt16
  targetFainted : Bool
  effectNullified : Bool := false
  events : List Event

/-- `AttackSubstitute` returns without breaking on exact low-byte subtraction;
any nonzero damage high byte breaks immediately. -/
def substituteBreaks (substituteHp : UInt8) (damage : UInt16) : Bool :=
  damage.toNat > 255 || substituteHp.toNat < damage.toNat

@[simp] theorem substitute_exact_damage_survives (hp : UInt8) :
    substituteBreaks hp (UInt16.ofNat hp.toNat) = false := by
  have bounded := UInt8.toNat_lt hp
  simp [substituteBreaks]
  omega

private def applyDamage (state : State) (who : Side) (damage : UInt16) : DamageApplied :=
  let targetWho := who.other
  let target := side state targetWho
  if target.active.volatile.hasSubstitute then
    let old := target.active.volatile.substituteHp
    let actual := min old damage.toUInt8
    let breaks := substituteBreaks old damage
    let remaining := if breaks then 0 else old - damage.toUInt8
    let volatile := { target.active.volatile with substituteHp := remaining }
    let volatile := { volatile with status2 := if breaks then target.active.volatile.status2 &&&
      ~~~((1 <<< Wram.BattleStatus2.hasSubstituteUp).toUInt8)
      else target.active.volatile.status2 }
    let actualDamage := UInt16.ofNat actual.toNat
    let volatile := if bitSet volatile.status1 Wram.BattleStatus1.storingEnergy then
      { volatile with bideAccumulated := volatile.bideAccumulated + actualDamage }
      else volatile
    { state := { (setSide state targetWho { target with active := { target.active with volatile } }) with
        sharedDamage := damage },
      actualDamage, targetFainted := false, effectNullified := breaks,
      events := [.substituteDamage targetWho actual remaining] }
  else
    let hp := Step.saturatingSub target.active.active.hp damage
    let actual := target.active.active.hp - hp
    let mon := { target.active.active with hp }
    let volatile := if bitSet target.active.volatile.status1 Wram.BattleStatus1.storingEnergy then
      { target.active.volatile with
        bideAccumulated := target.active.volatile.bideAccumulated + actual }
      else target.active.volatile
    let target := { target with active := { target.active with active := mon, volatile := volatile } }
    { state := { (setSide state targetWho target) with sharedDamage := actual },
      actualDamage := actual, targetFainted := hp == 0,
      events := [.damage who actual hp] }

/-- Three right shifts of zeroed miss damage, followed by the minimum-one
fallback in `PrintMoveFailureText`. -/
def jumpKickCrashDamage (damage : UInt16) : UInt16 :=
  let shifted := damage >>> 3
  if shifted == 0 then 1 else shifted

@[simp] theorem jumpKick_zeroed_damage_recoil : jumpKickCrashDamage 0 = 1 := by
  native_decide

def turnFlippedSubstituteOwner (who : Side) : Side := who.other

@[simp] theorem turn_flipped_self_damage_selects_opponent (who : Side) :
    turnFlippedSubstituteOwner who = who.other := rfl

private structure CrashApplied where
  state : State
  userFainted : Bool
  events : List Event

/-- Shared self-damage enters an apply-damage routine after a temporary turn
flip. Its Substitute test observes the user, while `AttackSubstitute` selects
the opponent's scratch from the restored turn byte. -/
private def applyTurnFlippedSelfDamage (state : State) (who : Side)
    (damage : UInt16) : CrashApplied :=
  let user := side state who
  if user.active.volatile.hasSubstitute then
    let targetWho := turnFlippedSubstituteOwner who
    let target := side state targetWho
    let old := target.active.volatile.substituteHp
    let breaks := substituteBreaks old damage
    let remaining := if breaks then 0 else old - damage.toUInt8
    let volatile := { target.active.volatile with substituteHp := remaining }
    let volatile := { volatile with status2 := if breaks then volatile.status2 &&&
      ~~~((1 <<< Wram.BattleStatus2.hasSubstituteUp).toUInt8) else volatile.status2 }
    let state := setSide { state with sharedDamage := damage } targetWho
      { target with active := { target.active with volatile } }
    { state, userFainted := false,
      events := [.substituteDamage targetWho damage.toUInt8 remaining] }
  else
    let hp := Step.saturatingSub user.active.active.hp damage
    let actual := user.active.active.hp - hp
    let active := { user.active with active := { user.active.active with hp } }
    { state := setSide { state with sharedDamage := actual } who { user with active }
      userFainted := hp == 0
      events := [.damage who actual hp] }

/-- Missed Jump Kick/Hi Jump Kick feeds minimum-one zeroed damage into the
turn-flipped self-damage path. -/
def applyJumpKickCrash (state : State) (who : Side) : CrashApplied :=
  applyTurnFlippedSelfDamage state who (jumpKickCrashDamage 0)

private structure RepeatedDamage where
  state : State
  lastActual : UInt16
  targetFainted : Bool
  effectNullified : Bool := false
  events : List Event

private def applyExtraHits : Nat → State → Side → UInt16 → RepeatedDamage
  | 0, state, _, _ => { state, lastActual := 0, targetFainted := false, events := [] }
  | count + 1, state, who, damage =>
      let applied := applyDamage state who damage
      if applied.targetFainted then
        { state := applied.state, lastActual := applied.actualDamage,
          targetFainted := true, effectNullified := applied.effectNullified,
          events := applied.events }
      else
        let tail := applyExtraHits count applied.state who damage
        { state := tail.state
          lastActual := if count == 0 then applied.actualDamage else tail.lastActual
          targetFainted := tail.targetFainted
          effectNullified := applied.effectNullified || tail.effectNullified
          events := applied.events ++ tail.events }

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

private def clearTrappingLock (state : State) (who : Side) : State :=
  let current := side state who
  let volatile := { current.active.volatile with
    status1 := current.active.volatile.status1 &&&
      ~~~((1 <<< Wram.BattleStatus1.usingTrappingMove).toUInt8)
    numAttacksLeft := 0 }
  setSide (setLockedDamage state who 0) who
    { current with active := { current.active with volatile } }

/-- Consume the current execution from Bide/Thrash/trapping counters. Thrash
completion samples its confusion duration at the lock-release boundary. -/
private def advanceMoveLock (state : State) (who : Side) : State × List Event :=
  let current := side state who
  let volatile := current.active.volatile
  let lockMask := (1 <<< Wram.BattleStatus1.storingEnergy).toUInt8 |||
    (1 <<< Wram.BattleStatus1.thrashingAbout).toUInt8 |||
    (1 <<< Wram.BattleStatus1.usingTrappingMove).toUInt8
  if volatile.status1 &&& lockMask == 0 || volatile.numAttacksLeft == 0 then (state, [])
  else
    let remaining := volatile.numAttacksLeft - 1
    if remaining != 0 then
      let volatile := { volatile with numAttacksLeft := remaining }
      (setSide state who { current with active := { current.active with volatile } }, [])
    else
      let wasThrashing := bitSet volatile.status1 Wram.BattleStatus1.thrashingAbout
      let wasTrapping := bitSet volatile.status1 Wram.BattleStatus1.usingTrappingMove
      let state := if wasTrapping then setLockedDamage state who 0 else state
      let volatile := { volatile with numAttacksLeft := 0 }
      let volatile := { volatile with status1 := volatile.status1 &&& ~~~lockMask }
      if wasThrashing then
        let (raw, rng) := state.battle.rng.next
        let turns := (raw &&& 3) + 2
        let volatile := { volatile with
          status1 := volatile.status1 ||| (1 <<< Wram.BattleStatus1.confused).toUInt8 }
        let volatile := { volatile with confusedCounter := turns }
        let state := setSide { state with battle := { state.battle with rng } } who
          { current with active := { current.active with volatile } }
        (state, [.rng "thrash-confusion" raw])
      else
        (setSide state who { current with active := { current.active with volatile } }, [])

private def executeMove (state : State) (who : Side) (action : Full.Action)
    (moveId : MoveId) (slot : Fin 4) (attacker : Battle.SideState)
    (attackerFull defenderFull : Full.SideState) (rng : Rng.LinkRng)
    (generated : Bool := false) : StepResult :=
let state := setSide { state with battle := { state.battle with rng } } who
  { attackerFull with active := attacker }
let state := decrementMovePp state who slot
  (action == .struggle || generated || action == .noAction)
let move := resolveMove moveId
let effect := (Data.moveData moveId).effect
let mechanic := (EffectPlan.plan effect).mechanic
let continuedTrap := action == .noAction && mechanic == .trapping
let (rng, critical, critEvents) :=
  if move.power == 0 || continuedTrap then (state.battle.rng, false, [])
  else
    let (raw, rng) := state.battle.rng.next
    let focus := bitSet attacker.volatile.status2 Wram.BattleStatus2.gettingPumped
    let critical := Critical.occurs (Critical.threshold attacker.active.species moveId focus) raw
    (rng, critical, [.rng "critical" raw])
let continuedBide := action == .noAction && mechanic == .bide
let damageResult := if continuedBide then
    .ok (UInt16.ofNat (min 0xffff (attacker.volatile.bideAccumulated.toNat * 2)),
      rng, [], false)
  else if continuedTrap then .ok (lockedDamage state who, rng, [], false)
  else if moveId == 68 then
    let previous := selection state who.other
    let validType := previous.type == TypeChart.normal || previous.type == TypeChart.fighting
    let counter := if previous.power != 0 && validType then
      UInt16.ofNat (min 0xffff (state.sharedDamage.toNat * 2)) else 0
    .ok (counter, rng, [], false)
  else initialDamage mechanic moveId who move attacker defenderFull.active critical rng
match damageResult with
| .error _ => .divisionFreeze state critEvents
| .ok (damage, rng, damageEvents, typeMiss) =>
    let (handlerGateHit, rng, handlerGateEvents) :=
      if who == .enemy && state.battle.mode != .link then
        match mechanic with
        | .statDown _ _ =>
            let (raw, rng) := rng.next
            (raw ≥ 64, rng, [.rng "enemy-stat-down-gate" raw])
        | _ => (true, rng, [])
      else (true, rng, [])
    let (accuracyHit, rng, accuracyEvents) :=
      if !handlerGateHit || rejectsBeforeAccuracy mechanic move defenderFull.active then
        (false, rng, [])
      else if continuedTrap || (mechanic == .sleep && defenderFull.active.volatile.recharging) then
        (true, rng, [])
      else if requiresAccuracy mechanic move.power then
        resolveAccuracy mechanic move attacker defenderFull.active rng
      else (true, rng, [])
    let hit := accuracyHit && !typeMiss
    let context := effectsContext state who moveId slot attacker defenderFull.active rng
    let before := if action == .noAction then
      match mechanic with
      | .bide | .thrash | .charge _ | .trapping => { context := context }
      | _ => Effects.applyBefore effect hit context
      else Effects.applyBefore effect hit context
    let state := installEffectsContext state who before.context
    let state := if before.signal == .cancelTargetMove then
      { state with canceledAction := some who.other } else state
    match before.signal with
    | .rngStuck => .rngStuck state (critEvents ++ damageEvents ++ handlerGateEvents ++
        accuracyEvents ++ before.events.map .effect)
    | .charging _ => .transitioned (recordExecutedMove state who moveId generated)
        (critEvents ++ before.events.map .effect)
    | .escaped =>
        let terminal := Outcome.BattleTerminal.mk' (.moveEscape who moveId)
          state.battle.mode .player (if who == .player then 0 else 1) 1
        .transitioned { state with battle := { state.battle with phase := .ending terminal } }
          (before.events.map .effect ++ [.terminal terminal])
    | .callMove nested => .nestedMove (recordExecutedMove state who moveId generated) who nested
        (before.events.map .effect)
    | .mimicChoice => .mimicPending state who slot none (before.events.map .effect)
    | .failed =>
        let state := recordExecutedMove state who moveId generated
        let (state, events) := applyResidual state who
        .transitioned state (critEvents ++ damageEvents ++ handlerGateEvents ++
          accuracyEvents ++ before.events.map .effect ++ events)
    | _ =>
        if mechanic == .jumpKick && !hit then
          let crash := applyJumpKickCrash state who
          let state := recordExecutedMove crash.state who moveId generated
          let events := critEvents ++ damageEvents ++ handlerGateEvents ++ accuracyEvents ++
            before.events.map .effect ++ crash.events
          if crash.userFainted then
            let (state, faintEvents) := recordFaint state who
            .transitioned state (events ++ faintEvents)
          else
            let (state, residualEvents) := applyResidual state who
            .transitioned state (events ++ residualEvents)
        else
          let damage := if hit then damage else 0
          let totalHits := if !hit then 1 else match before.signal with
            | .repeatHits count => count.toNat
            | _ => 1
          let applied := applyDamage state who damage
          let extra := if applied.targetFainted then
            { state := applied.state, lastActual := applied.actualDamage,
              targetFainted := true, events := [] }
            else applyExtraHits (totalHits - 1) applied.state who damage
          let finalState := if mechanic == .trapping && action != .noAction then
            if hit then setLockedDamage extra.state who damage
            else clearTrappingLock extra.state who
            else extra.state
          let targetFainted := applied.targetFainted || extra.targetFainted
          let lastActual := if totalHits ≤ 1 then applied.actualDamage else extra.lastActual
          let context := effectsContext finalState who moveId slot
            (side finalState who).active (side finalState who.other).active finalState.battle.rng
          let effectNullified := applied.effectNullified || extra.effectNullified
          let after := if effectNullified then ({ context := context } : Effects.Outcome)
            else Effects.applyAfter effect move.type hit targetFainted lastActual context
          let state := installEffectsContext finalState who after.context
          let state := if !effectNullified && hit &&
              (mechanic == .drain || mechanic == .dreamEater) then
            { state with sharedDamage := Effects.drainDamageWord state.sharedDamage }
            else state
          let state := recordExecutedMove state who moveId generated
          let (state, lockEvents) := advanceMoveLock state who
          let events := critEvents ++ damageEvents ++ handlerGateEvents ++ accuracyEvents ++
            before.events.map .effect ++
            applied.events ++ extra.events ++ after.events.map .effect ++ lockEvents
          if targetFainted then
            let (state, faintEvents) := recordFaint state who.other
            .transitioned state (events ++ faintEvents)
          else
            let (state, residualEvents) := applyResidual state who
            .transitioned state (events ++ residualEvents)

private def attack (state : State) (who : Side) (action : Full.Action)
    (overrideMove : Option MoveId := none) (skipStatus : Bool := false) : StepResult :=
  let selected := match overrideMove with
    | some move => some (move, (0 : Fin 4))
    | none => moveOfAction state who action
  match selected with
  | none => .transitioned state []
  | some (moveId, slot) =>
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
              let state := setSide { state with battle := { state.battle with rng } } who
                { attackerFull with active := attacker }
              let applied := applyTurnFlippedSelfDamage state who damage
              if applied.userFainted then
                let (state, events) := recordFaint applied.state who
                .transitioned state (.rng "confusion" raw :: applied.events ++ events)
              else
                let (state, events) := applyResidual applied.state who
                .transitioned state (.rng "confusion" raw :: applied.events ++ events)
      | .canAct attacker rng =>
          let installed := setSide { state with battle := { state.battle with rng } } who
            { attackerFull with active := attacker }
          if who == .player && !overrideMove.isSome && !attackerFull.active.volatile.chargingUp then
            let input : Disobedience.Input :=
              { mode := state.battle.mode
                monOtId := state.playerOtIds.getD state.battle.player.activeIndex state.playerId
                playerId := state.playerId
                badges := state.badges
                level := attacker.active.level
                moves := attacker.active.moves
                pp := attacker.active.pp
                selectedSlot := slot.val.toUInt8
                selectedMove := moveId
                moveCount := 4
                disabledMoveNumber := attacker.volatile.disabledMoveNumber }
            let machine := Disobedience.start input
            match machine.phase with
            | .done _ => executeMove state who action moveId slot attacker attackerFull defenderFull rng false
            | _ => .disobediencePending installed machine none []
          else executeMove state who action moveId slot attacker attackerFull defenderFull rng
            overrideMove.isSome


def switchAiLayer (current : UInt8) (who : Side) (forced : Bool) : UInt8 :=
  if who == .enemy && forced then 0 else current

@[simp] theorem forced_enemy_switch_resets_ai_layer (current : UInt8) :
    switchAiLayer current .enemy true = 0 := by
  have enemySelf : (Side.enemy == Side.enemy) = true := by native_decide
  simp [switchAiLayer, enemySelf]

@[simp] theorem voluntary_enemy_switch_retains_ai_layer (current : UInt8) :
    switchAiLayer current .enemy false = current := by
  simp [switchAiLayer]

private def applySwitch (state : State) (who : Side) (target : Fin 6)
    (forced : Bool := false) : Option State :=
  match state.battle.switchTo who target.val with
  | none => none
  | some battle =>
      let state := { state with battle := battle }
      some { state with
        forcedReplacement := if state.forcedReplacement == some who then none
          else state.forcedReplacement
        aiLayer2Encouragement := switchAiLayer state.aiLayer2Encouragement who forced }

private def applyItem (state : State) (who : Side) (request : Items.Request) : StepResult :=
  let trainerOwned := state.trainerAiItem && who == .enemy
  let state := if trainerOwned then { state with trainerAiItem := false } else state
  let user : Items.UserState := { side := side state who, bag := bag state who }
  let result := if trainerOwned then Items.aiUse state.battle.mode user request
    else Items.use state.battle.mode user request
  match result with
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

private def orderingMove (state : State) (who : Side) (action : Full.Action) : Step.ResolvedMove :=
  if isFight action then
    (moveOfAction state who action).map (fun pair => resolveMove pair.1) |>.getD (resolveMove 165)
  else resolveMove (selection state who).selectedMove

/-- `ExecuteEnemyMove` increments layer-2 encouragement before status gates. -/
def beginEnemyExecution (state : State) : State :=
  { state with aiLayer2Encouragement := state.aiLayer2Encouragement + 1 }

@[simp] theorem beginEnemyExecution_increments (state : State) :
    (beginEnemyExecution state).aiLayer2Encouragement =
      state.aiLayer2Encouragement + 1 := rfl

private def executeCommitted (state : State) (who : Side) (action : Full.Action) : StepResult :=
  let state := if who == .enemy && isFight action then beginEnemyExecution state else state
  if state.canceledAction == some who then
    .transitioned { state with canceledAction := none } []
  else if isFight action then attack state who action
  else
    let (state, events) := applyResidual state who
    .transitioned state events

private def prependEvents (prior : List Event) : StepResult → StepResult
  | .transitioned state events => .transitioned state (prior ++ events)
  | .capturePending state ball events => .capturePending state ball (prior ++ events)
  | .rngStuck state events => .rngStuck state (prior ++ events)
  | .divisionFreeze state events => .divisionFreeze state (prior ++ events)
  | .nestedMove state side move events => .nestedMove state side move (prior ++ events)
  | .mimicPending state side slot next events =>
      .mimicPending state side slot next (prior ++ events)
  | .runPending state side action events => .runPending state side action (prior ++ events)
  | .disobediencePending state machine next events =>
      .disobediencePending state machine next (prior ++ events)
  | .invalidAction state side => .invalidAction state side
  | .inactive state => .inactive state

private def executePair (state : State) (playerAction enemyAction : Full.Action)
    (prior : List Event := []) : StepResult :=
  let playerMove := orderingMove state .player playerAction
  let enemyMove := orderingMove state .enemy enemyAction
  let (first, _, rng) := Step.turnOrder playerMove.priority enemyMove.priority
    (effectiveSpeed (side state .player)) (effectiveSpeed (side state .enemy)) state.battle.rng
  let state := { state with battle := { state.battle with rng } }
  let firstAction := if first == .player then playerAction else enemyAction
  match executeCommitted state first firstAction with
  | .transitioned state events =>
      let events := prior ++ events
      if state.forcedReplacement.isSome || state.battle.phase.isTerminal then
        .transitioned state events
      else
        let second := first.other
        let secondAction := if second == .player then playerAction else enemyAction
        match executeCommitted state second secondAction with
        | .transitioned state more =>
            .transitioned { state with battle :=
              { state.battle with turn := state.battle.turn + 1 } } (events ++ more)
        | result => prependEvents events result
  | .disobediencePending state machine _ events =>
      let next := if first == .player then some enemyAction else none
      .disobediencePending state machine next (prior ++ events)
  | .mimicPending state side slot _ events =>
      let next := if first == .player then some enemyAction else some playerAction
      .mimicPending state side slot next (prior ++ events)
  | result => prependEvents prior result

/-- Resolve one policy turn. Forced replacement is a separate boundary; ordinary
switch/item actions commit before attacks, so attacks target the loaded mon. -/
def step (state : State) (playerAction enemyAction : Full.Action) : StepResult :=
  match state.battle.phase with
  | .battling =>
      if !Full.legal (actionContext state .player) playerAction then .invalidAction state .player
      else if !Full.legal (actionContext state .enemy) enemyAction then .invalidAction state .enemy
      else
        let state := commitSelection (commitSelection state .player playerAction) .enemy enemyAction
        if state.forcedReplacement.isSome then
          let forced := state.forcedReplacement.getD .player
          let action := if forced == .player then playerAction else enemyAction
          match action with
          | .switch target =>
              match applySwitch state forced target true with
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
                        match applyItem state .enemy enemyRequest with
                        | .transitioned state enemyEvents =>
                            executePair state playerAction enemyAction (playerEvents ++ enemyEvents)
                        | result => prependEvents playerEvents result
                    | result => result
                | .item request, enemyAction =>
                    match applyItem state .player request with
                    | .transitioned state itemEvents =>
                        executePair state playerAction enemyAction itemEvents
                    | result => result
                | playerAction, .item request =>
                    match applyItem state .enemy request with
                    | .transitioned state itemEvents =>
                        executePair state playerAction enemyAction itemEvents
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
                | _, _ => executePair state playerAction enemyAction
  | _ => .inactive state

private def selectedFin (slot : UInt8) : Fin 4 :=
  ⟨slot.toNat % 4, Nat.mod_lt _ (by omega)⟩

/-- The alternate move identity is reloaded, but `DecrementPP` still receives the
original menu-selected slot from the pending input. -/
def disobedienceChargedSlot (input : Disobedience.Input) : Fin 4 :=
  selectedFin input.selectedSlot

@[simp] theorem disobedience_charges_original_slot (input : Disobedience.Input) :
    (disobedienceChargedSlot input).val = input.selectedSlot.toNat % 4 := rfl

private def afterDisobedience (result : StepResult) (nextEnemyAction : Option Full.Action)
    (prior : List Event) : StepResult :=
  match prependEvents prior result with
  | .transitioned state events =>
      if state.forcedReplacement.isSome || state.battle.phase.isTerminal then
        .transitioned state events
      else match nextEnemyAction with
        | none => .transitioned state events
        | some action => prependEvents events (executeCommitted state .enemy action)
  | result => result

/-- Supply one `BattleRandom` byte to a pending disobedience routine. Rejection
phases remain pending; terminal branches resume the already ordered enemy action. -/
def resumeDisobedience (state : State) (machine : Disobedience.Machine)
    (nextEnemyAction : Option Full.Action) (raw : UInt8) : StepResult :=
  let machine := Disobedience.feed machine raw
  let drawEvent := Event.rng "disobedience" raw
  match machine.phase with
  | .done result =>
      let resultEvent := Event.disobedience result
      let player := side state .player
      let defender := side state .enemy
      let slot := disobedienceChargedSlot machine.input
      let action := if machine.input.selectedMove == 165 then Full.Action.struggle
        else .fight slot
      let completed := match result with
        | .obeyed _ move =>
            executeMove state .player action move slot player.active player defender
              state.battle.rng false
        | .alternate _ move =>
            executeMove state .player action move slot player.active player defender
              state.battle.rng false
        | .nap status =>
            let mon := { player.active.active with status }
            let state := setSide state .player { player with active := { player.active with active := mon } }
            let (state, residual) := applyResidual state .player
            .transitioned state residual
        | .idle _ =>
            let (state, residual) := applyResidual state .player
            .transitioned state residual
        | .selfDamage =>
            match DamageStats.resolve player.active.active.attack player.active.active.defense false with
            | .divisionFreeze _ => .divisionFreeze state []
            | .ready stats =>
                let damage := Damage.calcBaseDamage player.active.active.level false 40
                  (UInt16.ofNat stats.attack.toNat) (UInt16.ofNat stats.defense.toNat)
                let hp := Step.saturatingSub player.active.active.hp damage
                let mon := { player.active.active with hp }
                let state := setSide state .player { player with active := { player.active with active := mon } }
                if hp == 0 then
                  let (state, events) := recordFaint state .player
                  .transitioned state events
                else
                  let (state, events) := applyResidual state .player
                  .transitioned state events
      afterDisobedience completed nextEnemyAction [drawEvent, resultEvent]
  | _ => .disobediencePending state machine nextEnemyAction [drawEvent]

/-- Continue after a failed wild run; the opponent executes the action already
selected for that turn. -/
def resumeFailedRun (state : State) (runner : Side) (opponentAction : Full.Action) : StepResult :=
  if isFight opponentAction then attack state runner.other opponentAction
  else .transitioned state []

/-- Complete the ordinary-player Mimic menu. The copied move replaces Mimic's
selected slot without changing that slot's PP byte. Invalid/blank target slots
remain explicit invalid input rather than silently choosing another move. -/
def resumeMimic (state : State) (who : Side) (sourceSlot targetSlot : Fin 4)
    (nextAction : Option Full.Action) : StepResult :=
  let copied := (side state who.other).active.active.moves.getD targetSlot.val 0
  if copied == 0 then .invalidAction state who
  else
    let actor := side state who
    let moves := actor.active.active.moves.modify sourceSlot.val (fun _ => copied)
    let mon := { actor.active.active with moves := moves }
    let actor := { actor with active := { actor.active with active := mon } }
    let state := setLastMove (setSide state who actor) who 102
    let (state, residualEvents) := applyResidual state who
    if state.battle.phase.isTerminal then .transitioned state residualEvents
    else match nextAction with
      | none => .transitioned { state with battle :=
          { state.battle with turn := state.battle.turn + 1 } } residualEvents
      | some action =>
          match executeCommitted state who.other action with
          | .transitioned state events => .transitioned { state with battle :=
              { state.battle with turn := state.battle.turn + 1 } }
              (residualEvents ++ events)
          | result => prependEvents residualEvents result

/-- Continue a Mirror Move or Metronome request in the same action.
Status gating and PP decrement are not repeated; another nested signal remains an
explicit continuation, so recursive Metronome behavior is not fuel-bounded. -/
def resumeNested (state : State) (who : Side) (move : MoveId) : StepResult :=
  attack state who (.fight 0) (some move) true

/-- Legal actions are exposed directly from the engine state. -/
def legalActions (state : State) (who : Side) : Array Full.Action :=
  Full.legalActions (actionContext state who)

end Battle.Full.Engine
