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
  queuedReplacement : Option Side := none
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
  | moveExecuted (side : Side) (move : MoveId)
  | missed (side : Side)
  | ineffective (side : Side)
  | rng (site : String) (raw : UInt8)
  | effect (event : Effects.Event)
  | statusBlocked (side : Side) (reason : Status.CannotActReason)
  | damage (side : Side) (amount hpAfter : UInt16)
  | residualDamage (side : Side) (amount hpAfter : UInt16)
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
  | ineffectiveAction (state : State) (side : Side)
  | capturePending (state : State) (ball : UInt8) (events : List Event)
  | rngStuck (state : State) (events : List Event)
  | divisionFreeze (state : State) (events : List Event)
  | nestedMove (state : State) (side : Side) (move : MoveId) (events : List Event)
  | mimicPending (state : State) (side : Side) (sourceSlot : Fin 4)
      (nextAction : Option Full.Action) (events : List Event)
  | runPending (state : State) (side : Side) (opponentAction : Full.Action)
      (events : List Event)
  | wildFaintRunPending (state : State) (events : List Event)
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
  let wrapper := match who with
    | .player => state.playerSelection.selectedMove
    | .enemy => state.enemySelection.selectedMove
  setLastMove state who (generatedMoveIdentity wrapper move generated)

private def selection (state : State) : Side → Selection.MoveScratch
  | .player => state.playerSelection
  | .enemy => state.enemySelection

private def setSelection (state : State) : Side → Selection.MoveScratch → State
  | .player, scratch => { state with playerSelection := scratch }
  | .enemy, scratch => { state with enemySelection := scratch }

def clearLoadedEffect (state : State) (who : Side) : State :=
  let scratch := { selection state who with effect := 0 }
  setSelection state who scratch

@[simp] theorem clear_loaded_effect_is_side_local (state : State) (who : Side) :
    (selection (clearLoadedEffect state who) who).effect = 0 ∧
      (selection (clearLoadedEffect state who) who.other).effect =
        (selection state who.other).effect := by
  cases who <;> exact ⟨rfl, rfl⟩

def clearBothLoadedEffects (state : State) : State :=
  let playerSelection := { state.playerSelection with effect := 0 }
  let enemySelection := { state.enemySelection with effect := 0 }
  { state with playerSelection := playerSelection, enemySelection := enemySelection }

@[simp] theorem bide_clears_both_loaded_effects (state : State) :
    (clearBothLoadedEffects state).playerSelection.effect = 0 ∧
      (clearBothLoadedEffects state).enemySelection.effect = 0 := by
  exact ⟨rfl, rfl⟩

def commitSelection (state : State) (who : Side) (action : Full.Action) : State :=
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
      let scratch := { scratch with loadedMove := 165 }
      let scratch := { scratch with effect := data.effect }
      let scratch := { scratch with power := data.power }
      let scratch := { scratch with type := data.type }
      setSelection state who scratch
  | _ => state

/-- Cartridge Struggle preselection installs move `$A5` and its canonical
recoil row without reading a party move slot. -/
@[simp] theorem struggle_loads_canonical_move (state : State) (who : Side) :
    (selection (commitSelection state who .struggle) who).selectedMove = 165 ∧
      (selection (commitSelection state who .struggle) who).loadedMove = 165 := by
  cases who <;> exact ⟨rfl, rfl⟩

@[simp] theorem locked_and_forced_selection_stays_stale (state : State) (who : Side)
    (target : Fin 6) (request : Items.Request) :
    selection (commitSelection state who .noAction) who = selection state who ∧
      selection (commitSelection state who (.switch target)) who = selection state who ∧
      selection (commitSelection state who (.item request)) who = selection state who ∧
      selection (commitSelection state who .run) who = selection state who := by
  exact ⟨rfl, rfl, rfl, rfl⟩

private def lockedDamage (state : State) : Side → UInt16
  | .player => state.playerLockedDamage
  | .enemy => state.enemyLockedDamage

private def setLockedDamage (state : State) : Side → UInt16 → State
  | .player, damage => { state with playerLockedDamage := damage }
  | .enemy, damage => { state with enemyLockedDamage := damage }

private def actionContext (state : State) (who : Side) : Full.ActionContext :=
  { side := side state who, bag := bag state who, mode := state.battle.mode,
    owner := who, forcedReplacement := state.forcedReplacement == some who,
    opponentTrapping := (side state who.other).active.volatile.trapping }

private def currentPp (packed : UInt8) : UInt8 := packed &&& Wram.ppMask
/-- Cartridge `dec [hl]` mutates the complete packed PP byte. Malformed
zero-current-PP values can therefore borrow through or destroy PP-Up bits. -/
def decrementPp (packed : UInt8) : UInt8 := packed - 1

@[simp] theorem decrement_zero_pp_underflows : decrementPp 0 = 0xff := by native_decide
@[simp] theorem decrement_pp_up_only_deforms : decrementPp 0x40 = 0x3f := by native_decide

def moveOfAction (state : State) (who : Side) : Full.Action → Option (MoveId × Fin 4)
  | .fight slot => some ((side state who).active.active.moves.getD slot.val 0, slot)
  | .struggle => some (165, 0)
  | .noAction =>
      let value := (selection state who).highlightedSlot.toNat % 4
      some ((selection state who).loadedMove, ⟨value, Nat.mod_lt _ (by omega)⟩)
  | _ => none

/-- A menu-bypass command reloads the move and slot retained by the cartridge's
selection scratch; it never chooses a fresh move. -/
@[simp] theorem no_action_uses_retained_move (state : State) (who : Side) :
    (moveOfAction state who .noAction).map Prod.fst =
      some (selection state who).loadedMove := by
  simp [moveOfAction]

def decrementMovePp (state : State) (who : Side) (slot : Fin 4)
    (isStruggle : Bool) : State :=
  if isStruggle || (who == .enemy && state.battle.mode != .link) then state
  else
    let current := side state who
    let mon := current.active.active
    let mon := { mon with pp := mon.pp.modify slot.val decrementPp }
    setSide state who { current with active := { current.active with active := mon } }

@[simp] theorem struggle_never_decrements_pp (state : State) (who : Side)
    (slot : Fin 4) :
    decrementMovePp state who slot true = state := by
  simp [decrementMovePp]

/-- Player-owned PP is decremented at the retained slot. Charge moves invoke
this on their automatic continuation rather than on the setup turn. -/
theorem player_pp_decrements (state : State) (slot : Fin 4)
    (inBounds : slot.val < (side state .player).active.active.pp.size) :
    let before := (side state .player).active.active.pp.getD slot.val 0
    ((side (decrementMovePp state .player slot false) .player).active.active.pp.getD
      slot.val 0) = decrementPp before := by
  have playerNotEnemy : (Side.player == Side.enemy) = false := by native_decide
  change slot.val < state.battle.player.active.active.pp.size at inBounds
  simp [decrementMovePp, playerNotEnemy, side, setSide, Full.State.side,
    Full.State.setSide, Array.getD, inBounds, Array.getElem_modify_self]

@[simp] theorem nonlink_enemy_pp_not_decremented (state : State) (slot : Fin 4)
    (isStruggle : Bool) (nonlink : state.battle.mode ≠ .link) :
    decrementMovePp state .enemy slot isStruggle = state := by
  have enemySelf : (Side.enemy == Side.enemy) = true := by native_decide
  have modeBool : (state.battle.mode != BattleMode.link) = true := by
    cases mode : state.battle.mode <;> try native_decide
    exact (nonlink mode).elim
  simp [decrementMovePp, enemySelf, modeBool]

/-- On an actual cartridge `DecrementPP` mutates only the local player. The
synchronized training quotient represents each cable endpoint's local party,
so its enemy-authoritative row receives the decrement that occurs on the other
cartridge. -/
theorem link_enemy_pp_decrements (state : State) (slot : Fin 4)
    (link : state.battle.mode = .link)
    (inBounds : slot.val < (side state .enemy).active.active.pp.size) :
    let before := (side state .enemy).active.active.pp.getD slot.val 0
    ((side (decrementMovePp state .enemy slot false) .enemy).active.active.pp.getD
      slot.val 0) = decrementPp before := by
  have enemySelf : (Side.enemy == Side.enemy) = true := by native_decide
  have linkSelf : (BattleMode.link != BattleMode.link) = false := by native_decide
  change slot.val < state.battle.enemy.active.active.pp.size at inBounds
  simp [decrementMovePp, enemySelf, link, linkSelf, side, setSide,
    Full.State.side, Full.State.setSide, Array.getD, inBounds,
    Array.getElem_modify_self]

private def effectiveSpeed (fullSide : Full.SideState) : UInt16 :=
  fullSide.active.active.speed

def screenUp (defender : Battle.SideState) (special : Bool) : Bool :=
  bitSet defender.volatile.status3
    (if special then Wram.BattleStatus3.hasLightScreenUp else Wram.BattleStatus3.hasReflectUp)

def offensiveStat (attacker : Battle.SideState) (special critical : Bool) : UInt16 :=
  if critical then
    if special then attacker.unmodified.special else attacker.unmodified.attack
  else if special then attacker.active.special else attacker.active.attack

def defensiveStat (defender : Battle.SideState) (special critical : Bool) : UInt16 :=
  if critical then
    if special then defender.unmodified.special else defender.unmodified.defense
  else if special then defender.active.special else defender.active.defense

def requiresAccuracy (mechanic : EffectPlan.Mechanic) (power : UInt8) : Bool :=
  if power != 0 then true else
    match mechanic with
    | .sleep | .confusion | .poison | .paralyze | .statDown _ _
    | .mimic | .leechSeed | .disable => true
    | _ => false

def bypassesAccuracy (mechanic : EffectPlan.Mechanic)
    (attacker : Battle.SideState) : Bool :=
  mechanic == .swift || bitSet attacker.volatile.status2 Wram.BattleStatus2.usingXAccuracy

/-- Eligibility gates executed by ResidualEffects1 handlers before their own
`MoveHitTest` call. Rejection here consumes no accuracy byte. -/
def rejectsBeforeAccuracy (mechanic : EffectPlan.Mechanic)
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

@[simp] theorem critical_uses_unmodified_stats (side : Battle.SideState) :
    offensiveStat side false true = side.unmodified.attack ∧
    offensiveStat side true true = side.unmodified.special ∧
    defensiveStat side false true = side.unmodified.defense ∧
    defensiveStat side true true = side.unmodified.special := by
  simp [offensiveStat, defensiveStat]

@[simp] theorem substitute_mist_dream_gates (move : Step.ResolvedMove)
    (defender : Battle.SideState)
    (substitute : defender.volatile.hasSubstitute = true)
    (mist : bitSet defender.volatile.status2 Wram.BattleStatus2.protectedByMist = true)
    (awake : defender.active.asleep = false) :
    rejectsBeforeAccuracy .confusion move defender = true ∧
    rejectsBeforeAccuracy (.statDown 0 1) move defender = true ∧
    rejectsBeforeAccuracy .dreamEater move defender = true := by
  simp [rejectsBeforeAccuracy, substitute, mist, awake]

def resolveAccuracy (mechanic : EffectPlan.Mechanic) (move : Step.ResolvedMove)
    (attacker defender : Battle.SideState) (rng : Rng.LinkRng) : Bool × Rng.LinkRng × List Event :=
  if mechanic == .swift then (true, rng, [])
  else if bitSet defender.volatile.status1 Wram.BattleStatus1.invulnerable then (false, rng, [])
  else if bypassesAccuracy mechanic attacker then (true, rng, [])
  else
    let effective := Accuracy.calcHitChance move.accuracy attacker.stages.accuracy defender.stages.evasion
    let (raw, rng) := rng.next
    (Accuracy.hits effective raw, rng, [.rng "accuracy" raw])

theorem invulnerability_precedes_x_accuracy (move : Step.ResolvedMove)
    (attacker defender : Battle.SideState) (rng : Rng.LinkRng)
    (invulnerable : bitSet defender.volatile.status1
      Wram.BattleStatus1.invulnerable = true) :
    resolveAccuracy .ordinary move attacker defender rng = (false, rng, []) := by
  have ordinary : (EffectPlan.Mechanic.ordinary == EffectPlan.Mechanic.swift) = false := by
    native_decide
  simp [resolveAccuracy, ordinary, invulnerable]

theorem x_accuracy_bypasses_stages_and_random (move : Step.ResolvedMove)
    (attacker defender : Battle.SideState) (rng : Rng.LinkRng)
    (visible : bitSet defender.volatile.status1 Wram.BattleStatus1.invulnerable = false)
    (xAccuracy : bitSet attacker.volatile.status2 Wram.BattleStatus2.usingXAccuracy = true) :
    resolveAccuracy .ordinary move attacker defender rng = (true, rng, []) := by
  have ordinary : (EffectPlan.Mechanic.ordinary == EffectPlan.Mechanic.swift) = false := by
    native_decide
  have bypass : bypassesAccuracy .ordinary attacker = true := by
    simp [bypassesAccuracy, xAccuracy]
  simp [resolveAccuracy, ordinary, visible, bypass]

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

def buildRageAfterDamage (state : State) (attacker : Side) : State :=
  let targetSide := attacker.other
  let target := side state targetSide
  if !bitSet target.active.volatile.status2 Wram.BattleStatus2.usingRage ||
      target.active.active.fainted then state
  else
    let context := effectsContext state targetSide 0 0 target.active
      (side state attacker).active state.battle.rng
    let outcome := Effects.raiseStage context 0 1
    installEffectsContext state targetSide outcome.context

@[simp] theorem buildRageAfterDamage_target_hp (state : State) (attacker : Side) :
    (side (buildRageAfterDamage state attacker) attacker.other).active.active.hp =
      (side state attacker.other).active.active.hp := by
  cases attacker <;>
    simp [buildRageAfterDamage, effectsContext, installEffectsContext, side,
      setSide, Side.other, Full.State.side, Full.State.setSide]
  all_goals split <;> simp

@[simp] theorem buildRageAfterDamage_sharedDamage (state : State) (attacker : Side) :
    (buildRageAfterDamage state attacker).sharedDamage = state.sharedDamage := by
  cases attacker <;>
    simp [buildRageAfterDamage, effectsContext, installEffectsContext, side,
      setSide, Side.other, Full.State.side, Full.State.setSide]
  all_goals split <;> simp

theorem rage_builds_after_surviving_damage (state : State) (attacker : Side)
    (rage : bitSet (side state attacker.other).active.volatile.status2
      Wram.BattleStatus2.usingRage = true)
    (living : (side state attacker.other).active.active.fainted = false) :
    buildRageAfterDamage state attacker =
      let target := side state attacker.other
      let context := effectsContext state attacker.other 0 0 target.active
        (side state attacker).active state.battle.rng
      installEffectsContext state attacker.other (Effects.raiseStage context 0 1).context := by
  simp [buildRageAfterDamage, rage, living]

structure DamageApplied where
  state : State
  actualDamage : UInt16
  targetFainted : Bool
  effectNullified : Bool := false
  events : List Event

/-- `AttackSubstitute` returns without breaking on exact low-byte subtraction;
any nonzero damage high byte breaks immediately. -/
def substituteBreaks (substituteHp : UInt8) (damage : UInt16) : Bool :=
  damage.toNat > 255 || substituteHp.toNat < damage.toNat

@[simp] theorem substitute_high_byte_breaks (hp : UInt8) :
    substituteBreaks hp 0x0100 = true := by
  simp [substituteBreaks]

@[simp] theorem substitute_exact_damage_survives (hp : UInt8) :
    substituteBreaks hp (UInt16.ofNat hp.toNat) = false := by
  have bounded := UInt8.toNat_lt hp
  simp [substituteBreaks]
  omega

def applyDamage (state : State) (who : Side) (damage : UInt16) : DamageApplied :=
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
    let state := { (setSide state targetWho { target with active :=
      { target.active with volatile := volatile } }) with sharedDamage := damage }
    { state := buildRageAfterDamage state who,
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
    let active := { target.active with active := mon }
    let target := { target with active := { active with volatile := volatile } }
    let state := { (setSide state targetWho target) with sharedDamage := actual }
    { state := buildRageAfterDamage state who,
      actualDamage := actual, targetFainted := hp == 0,
      events := [.damage targetWho actual hp] }

/-- On the ordinary no-Substitute path, HP uses saturating subtraction and the
shared damage word records exactly the HP actually removed. -/
theorem apply_damage_no_substitute_words (state : State) (who : Side)
    (damage : UInt16)
    (noSubstitute : (side state who.other).active.volatile.hasSubstitute = false) :
    let target := side state who.other
    let applied := applyDamage state who damage
    applied.actualDamage = target.active.active.hp -
        Step.saturatingSub target.active.active.hp damage ∧
      (side applied.state who.other).active.active.hp =
        Step.saturatingSub target.active.active.hp damage ∧
      applied.state.sharedDamage = target.active.active.hp -
        Step.saturatingSub target.active.active.hp damage := by
  simp only [applyDamage, noSubstitute, Bool.false_eq_true, ↓reduceIte]
  constructor
  · trivial
  · constructor
    · rw [buildRageAfterDamage_target_hp]
      cases who <;> simp [side, setSide, Side.other, Full.State.side, Full.State.setSide]
    · rw [buildRageAfterDamage_sharedDamage]

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

/-- Player faint writes zero major status to both loaded and party records,
without touching participation metadata owned by the environment. -/
def clearPlayerFaintStatus (fullSide : Full.SideState) : Full.SideState :=
  let synced := fullSide.syncOutgoing
  let mon := { synced.active.active with status := 0 }
  let party := { mons := synced.party.mons.modify synced.activeIndex fun stored =>
    { stored with status := 0 } }
  { synced with party, active := { synced.active with active := mon } }

@[simp] theorem player_faint_clears_active_status (fullSide : Full.SideState) :
    (clearPlayerFaintStatus fullSide).active.active.status = 0 := rfl

/-- The corresponding persistent active-party row receives the same zero. -/
theorem player_faint_clears_party_status (fullSide : Full.SideState)
    (inBounds : fullSide.activeIndex < fullSide.party.mons.size) :
    ((clearPlayerFaintStatus fullSide).party.mons.getD fullSide.activeIndex
      fullSide.active.active).status = 0 := by
  simp only [clearPlayerFaintStatus, Full.SideState.syncOutgoing]
  simp [Array.getD, inBounds, Array.getElem_modify_self]

def clearBideAfterEnemyFaint (accumulated : UInt16) : UInt16 :=
  accumulated &&& 0x00FF

def clearBideAfterPlayerFaint (_accumulated : UInt16) : UInt16 := 0

@[simp] theorem bide_faint_clear_is_asymmetric :
    clearBideAfterEnemyFaint 0x1234 = 0x0034 ∧
      clearBideAfterPlayerFaint 0x1234 = 0 := by
  native_decide

def recordEnemyFaintSide (fullSide : Full.SideState) : Full.SideState :=
  let party := { mons := fullSide.party.mons.modify fullSide.activeIndex fun stored =>
    { stored with hp := 0 } }
  let active := { fullSide.active with
    volatile := Full.Volatile.sendOutReset fullSide.active.volatile }
  { fullSide with party, active }

@[simp] theorem enemy_faint_retains_party_status (fullSide : Full.SideState)
    (inBounds : fullSide.activeIndex < fullSide.party.mons.size) :
    ((recordEnemyFaintSide fullSide).party.mons.getD fullSide.activeIndex
      fullSide.active.active).status =
        (fullSide.party.mons.getD fullSide.activeIndex fullSide.active.active).status := by
  simp [recordEnemyFaintSide, Array.getD, inBounds, Array.getElem_modify_self]

private def applyFaintAsymmetry (state : State) (fainted : Side) : State :=
  match fainted with
  | .enemy =>
      let player := side state .player
      let bide := clearBideAfterEnemyFaint player.active.volatile.bideAccumulated
      let volatile := { player.active.volatile with bideAccumulated := bide }
      let player := { player with active := { player.active with volatile := volatile } }
      setSide (setSide state .enemy (recordEnemyFaintSide (side state .enemy))) .player player
  | .player =>
      let enemy := side state .enemy
      let bide := clearBideAfterPlayerFaint enemy.active.volatile.bideAccumulated
      let volatile := { enemy.active.volatile with bideAccumulated := bide }
      let enemy := { enemy with active := { enemy.active with volatile := volatile } }
      setSide (setSide state .player (clearPlayerFaintStatus (side state .player))) .enemy enemy

def terminalFor (state : State) (fainted : Side) : Outcome.BattleTerminal :=
  Outcome.BattleTerminal.mk' (.partyExhausted fainted) state.battle.mode .player
    (if fainted == .enemy then 0 else 1)

@[simp] theorem faint_terminal_channels (state : State) :
    (terminalFor state .enemy).cause = .partyExhausted .enemy ∧
      (terminalFor state .enemy).rawResult = 0 ∧
      (terminalFor state .player).cause = .partyExhausted .player ∧
      (terminalFor state .player).rawResult = 1 := by
  have enemy : (Side.enemy == Side.enemy) = true := by native_decide
  have player : (Side.player == Side.enemy) = false := by native_decide
  simp [terminalFor, Outcome.BattleTerminal.mk', enemy, player]

def recordFaint (state : State) (fainted : Side) : State × List Event :=
  let state := applyFaintAsymmetry state fainted
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

/-- Resolve a simultaneous active faint in cartridge handler order. Terminal
provenance records the side detected first. With reserves on both sides, player
replacement is requested first and enemy replacement is queued rather than
manufacturing a terminal result. -/
def prepareSimultaneousFaint (state : State) : State :=
  applyFaintAsymmetry (applyFaintAsymmetry state .player) .enemy

def resolveSimultaneousPrepared (state : State) (detectedFirst : Side) : State × List Event :=
  let playerOut := (side state .player).partyExhausted
  let enemyOut := (side state .enemy).partyExhausted
  let detectedSecond := detectedFirst.other
  let faintEvents := [.fainted detectedFirst, .fainted detectedSecond]
  if playerOut then
    let terminal := Outcome.BattleTerminal.mk' (.partyExhausted .player)
      state.battle.mode .player 1 0 (some detectedFirst)
    let state := { state with battle := { state.battle with phase := .ending terminal } }
    let state := { state with forcedReplacement := none }
    ({ state with queuedReplacement := none }, faintEvents ++ [.terminal terminal])
  else if enemyOut then
    -- Enemy-first recoil handling removes the simultaneously fainted player
    -- after `FaintEnemyPokemon` has written zero, leaving raw result one while
    -- still taking TrainerBattleVictory and paying out. Player-first handling
    -- later rewrites the result to zero in `FaintEnemyPokemon`.
    let rawResult : UInt8 := if detectedFirst == .enemy then 1 else 0
    let terminal := Outcome.BattleTerminal.mk' (.partyExhausted .enemy)
      state.battle.mode .player rawResult 0 (some detectedFirst)
    let state := if state.battle.mode == .trainer then
      { state with playerMoney := state.playerMoney.add state.trainerPrize }
      else state
    let state := { state with battle := { state.battle with phase := .ending terminal } }
    let state := { state with forcedReplacement := none }
    ({ state with queuedReplacement := none }, faintEvents ++ [.terminal terminal])
  else
    let state := { state with forcedReplacement := some .player }
    ({ state with queuedReplacement := some .enemy },
      faintEvents ++ [.forcedReplacement .player])

def recordSimultaneousFaint (state : State) (detectedFirst : Side) : State × List Event :=
  resolveSimultaneousPrepared (prepareSimultaneousFaint state) detectedFirst

@[simp] theorem simultaneous_with_reserves_is_nonterminal (state : State)
    (playerReserve : (side state .player).partyExhausted = false)
    (enemyReserve : (side state .enemy).partyExhausted = false)
    (first : Side) :
    ((resolveSimultaneousPrepared state first).1.battle.phase = state.battle.phase ∧
      (resolveSimultaneousPrepared state first).1.forcedReplacement = some .player ∧
      (resolveSimultaneousPrepared state first).1.queuedReplacement = some .enemy) := by
  simp [resolveSimultaneousPrepared, playerReserve, enemyReserve]

theorem simultaneous_player_exhausted_is_loss (state : State) (first : Side)
    (playerOut : (side state .player).partyExhausted = true) :
    (resolveSimultaneousPrepared state first).1.battle.phase = .ending
      (Outcome.BattleTerminal.mk' (.partyExhausted .player) state.battle.mode
        .player 1 0 (some first)) := by
  simp [resolveSimultaneousPrepared, playerOut]

theorem simultaneous_enemy_exhausted_is_win (state : State) (first : Side)
    (playerLives : (side state .player).partyExhausted = false)
    (enemyOut : (side state .enemy).partyExhausted = true) :
    (resolveSimultaneousPrepared state first).1.battle.phase = .ending
      (Outcome.BattleTerminal.mk' (.partyExhausted .enemy) state.battle.mode
        .player (if first == .enemy then 1 else 0) 0 (some first)) := by
  simp [resolveSimultaneousPrepared, playerLives, enemyOut]

/-- Enemy-first simultaneous fainting can display trainer victory and pay out
while retaining raw `wBattleResult = 1` from the player-faint removal. -/
theorem enemy_first_simultaneous_trainer_win_keeps_loss_byte (state : State)
    (trainer : state.battle.mode = .trainer)
    (playerLives : (side state .player).partyExhausted = false)
    (enemyOut : (side state .enemy).partyExhausted = true) :
    let after := (resolveSimultaneousPrepared state .enemy).1
    (∃ terminal, after.battle.phase = .ending terminal ∧
      terminal.cause = .partyExhausted .enemy ∧ terminal.rawResult = 1) ∧
      after.playerMoney = state.playerMoney.add state.trainerPrize := by
  have enemySelf : (Side.enemy == Side.enemy) = true := by native_decide
  have trainerSelf : (BattleMode.trainer == BattleMode.trainer) = true := by native_decide
  simp [resolveSimultaneousPrepared, playerLives, enemyOut, trainer,
    enemySelf, trainerSelf, Outcome.BattleTerminal.mk']

private def applyResidual (state : State) (who : Side) : State × List Event :=
  let result := Status.applyResiduals (side state who).active (side state who.other).active
  let state := setSide state who { side state who with active := result.actor }
  let state := setSide state who.other { side state who.other with active := result.opponent }
  let residualDamage := result.poisonOrBurnDamage + result.leechSeedDamage
  let residualEvents := if residualDamage == 0 then [] else
    [.residualDamage who residualDamage result.actor.active.hp]
  if result.actor.active.fainted then
    let (state, faintEvents) := recordFaint state who
    (state, residualEvents ++ faintEvents)
  else (state, residualEvents)

def clearTrappingLock (state : State) (who : Side) : State :=
  let current := side state who
  let volatile := { current.active.volatile with
    status1 := current.active.volatile.status1 &&&
      ~~~((1 <<< Wram.BattleStatus1.usingTrappingMove).toUInt8)
    numAttacksLeft := 0 }
  setSide (setLockedDamage state who 0) who
    { current with active := { current.active with volatile } }

/-- Consume the current execution from Bide/Thrash/trapping counters. Thrash
completion samples its confusion duration at the lock-release boundary. -/
def advanceMoveLock (state : State) (who : Side) : State × List Event :=
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
        let turns := Effects.confusionDuration raw
        let volatile := { volatile with
          status1 := volatile.status1 ||| (1 <<< Wram.BattleStatus1.confused).toUInt8 }
        let volatile := { volatile with confusedCounter := turns }
        let state := setSide { state with battle := { state.battle with rng } } who
          { current with active := { current.active with volatile } }
        (state, [.rng "thrash-confusion" raw])
      else
        (setSide state who { current with active := { current.active with volatile } }, [])

/-- Gen-I Counter reads the opponent's retained selected-move/record scratch
and the single shared `wDamage` word. Rejections return before `MoveHitTest`. -/
def counterEligible (previous : Selection.MoveScratch) (sharedDamage : UInt16) : Bool :=
  previous.selectedMove != 68 && previous.power != 0 &&
    (previous.type == TypeChart.normal || previous.type == TypeChart.fighting) &&
    sharedDamage != 0

def counterRejected (moveId : MoveId) (previous : Selection.MoveScratch)
    (sharedDamage : UInt16) : Bool :=
  moveId == 68 && !counterEligible previous sharedDamage

/-- Eligible Counter doubles the shared word and caps carry at `$FFFF`. -/
def counterDamage (previous : Selection.MoveScratch) (sharedDamage : UInt16) : UInt16 :=
  if counterEligible previous sharedDamage then
    UInt16.ofNat (min 0xffff (sharedDamage.toNat * 2))
  else 0

@[simp] theorem counter_rejects_previous_counter (previous : Selection.MoveScratch)
    (wasCounter : previous.selectedMove = 68) (sharedDamage : UInt16) :
    counterEligible previous sharedDamage = false := by
  simp [counterEligible, wasCounter]

@[simp] theorem counter_rejects_zero_damage (previous : Selection.MoveScratch) :
    counterEligible previous 0 = false := by
  simp [counterEligible]

@[simp] theorem counter_rejection_skips_accuracy (previous : Selection.MoveScratch)
    (sharedDamage : UInt16) (rejected : counterEligible previous sharedDamage = false) :
    counterRejected 68 previous sharedDamage = true := by
  simp [counterRejected, rejected]

@[simp] theorem counter_zero_power_fails (previous : Selection.MoveScratch)
    (zeroPower : previous.power = 0) (sharedDamage : UInt16) :
    counterDamage previous sharedDamage = 0 := by
  simp [counterDamage, counterEligible, zeroPower]

theorem counter_valid_exact (previous : Selection.MoveScratch) (sharedDamage : UInt16)
    (notCounter : previous.selectedMove != 68) (power : previous.power != 0)
    (validType : previous.type == TypeChart.normal || previous.type == TypeChart.fighting)
    (damaged : sharedDamage != 0) :
    counterDamage previous sharedDamage =
      UInt16.ofNat (min 0xffff (sharedDamage.toNat * 2)) := by
  simp [counterDamage, counterEligible, notCounter, power, validType, damaged]

/-- A canceled menu leaves enough stale loaded data for enemy Counter to
return damage even when the committed player action is a switch/item/run. -/
theorem stale_tackle_record_enables_counter :
    counterDamage { selectedMove := 33, power := 35, type := TypeChart.normal } 20 = 40 := by
  native_decide

@[simp] theorem counter_caps_shared_damage :
    counterDamage { selectedMove := 33, power := 1, type := TypeChart.normal }
      0xffff = 0xffff := by
  native_decide

/-- The canonical Counter record still runs the preceding critical test and its
own accuracy test even though the damage branch bypasses ordinary calculation,
type adjustment, and randomization. -/
@[simp] theorem counter_protocol_gates :
    (resolveMove 68).power != 0 ∧
    requiresAccuracy (EffectPlan.plan (Data.moveData 68).effect).mechanic
      (resolveMove 68).power = true := by
  native_decide

def bideReleaseDamage (accumulated : UInt16) : Option UInt16 :=
  if accumulated == 0 then none
  else some (UInt16.ofNat (min 0xffff (accumulated.toNat * 2)))

@[simp] theorem bide_zero_misses : bideReleaseDamage 0 = none := by native_decide
@[simp] theorem bide_release_doubles : bideReleaseDamage 100 = some 200 := by native_decide
@[simp] theorem bide_release_caps : bideReleaseDamage 0x9000 = some 0xffff := by native_decide

def decrementsPpNow (mechanic : EffectPlan.Mechanic) (action : Full.Action) : Bool :=
  if action == .struggle then false
  else match mechanic with
  | .charge _ => action == .noAction
  | _ => action != .noAction

@[simp] theorem charge_pp_is_deferred :
    decrementsPpNow (.charge true) (.fight 0) = false ∧
      decrementsPpNow (.charge true) .noAction = true := by
  native_decide

private def prependMoveExecuted (who : Side) (move : MoveId) : StepResult → StepResult
  | .transitioned state events => .transitioned state (.moveExecuted who move :: events)
  | .capturePending state ball events =>
      .capturePending state ball (.moveExecuted who move :: events)
  | .rngStuck state events => .rngStuck state (.moveExecuted who move :: events)
  | .divisionFreeze state events => .divisionFreeze state (.moveExecuted who move :: events)
  | .nestedMove state side nested events =>
      .nestedMove state side nested (.moveExecuted who move :: events)
  | .mimicPending state side slot next events =>
      .mimicPending state side slot next (.moveExecuted who move :: events)
  | .runPending state side next events =>
      .runPending state side next (.moveExecuted who move :: events)
  | .wildFaintRunPending state events =>
      .wildFaintRunPending state (.moveExecuted who move :: events)
  | .disobediencePending state machine next events =>
      .disobediencePending state machine next (.moveExecuted who move :: events)
  | .invalidAction state side => .invalidAction state side
  | .ineffectiveAction state side => .ineffectiveAction state side
  | .inactive state => .inactive state

private def executeMove (state : State) (who : Side) (action : Full.Action)
    (moveId : MoveId) (slot : Fin 4) (attacker : Battle.SideState)
    (attackerFull defenderFull : Full.SideState) (rng : Rng.LinkRng)
    (generated : Bool := false) : StepResult :=
let state := setSide { state with battle := { state.battle with rng } } who
  { attackerFull with active := attacker }
let move := resolveMove moveId
let effect := (Data.moveData moveId).effect
let mechanic := (EffectPlan.plan effect).mechanic
let state := if mechanic == .bide && action != .noAction then
  clearBothLoadedEffects state else state
let state := if decrementsPpNow mechanic action then
  decrementMovePp state who slot false else state
let continuedTrap := action == .noAction && mechanic == .trapping
let (rng, critical, critEvents) :=
  if move.power == 0 || continuedTrap then (state.battle.rng, false, [])
  else
    let (raw, rng) := state.battle.rng.next
    let focus := bitSet attacker.volatile.status2 Wram.BattleStatus2.gettingPumped
    let critical := Critical.occurs (Critical.threshold attacker.active.species moveId focus) raw
    (rng, critical, [.rng "critical" raw])
let continuedBide := action == .noAction && mechanic == .bide
let counterRejected := counterRejected moveId (selection state who.other) state.sharedDamage
let emptyBide := continuedBide && (bideReleaseDamage attacker.volatile.bideAccumulated).isNone
let damageResult := if continuedBide then
    .ok ((bideReleaseDamage attacker.volatile.bideAccumulated).getD 0, rng, [], false)
  else if continuedTrap then .ok (lockedDamage state who, rng, [], false)
  else if moveId == 68 then
    .ok (counterDamage (selection state who.other) state.sharedDamage, rng, [], false)
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
      if counterRejected || emptyBide || !handlerGateHit ||
          rejectsBeforeAccuracy mechanic move defenderFull.active then
        (false, rng, [])
      else if continuedTrap || (mechanic == .sleep && defenderFull.active.volatile.recharging) then
        (true, rng, [])
      else if requiresAccuracy mechanic move.power then
        resolveAccuracy mechanic move attacker defenderFull.active rng
      else (true, rng, [])
    let hit := accuracyHit && !typeMiss
    let hitEvents := if !accuracyHit then [.missed who]
      else if typeMiss then [.ineffective who] else []
    let context := effectsContext state who moveId slot
      (side state who).active (side state who.other).active rng
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
        accuracyEvents ++ hitEvents ++ before.events.map .effect)
    | .charging _ => .transitioned state
        (critEvents ++ before.events.map .effect)
    | .escaped =>
        let state := setSide state who (side state who).syncOutgoing
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
          accuracyEvents ++ hitEvents ++ before.events.map .effect ++ events)
    | _ =>
        if mechanic == .jumpKick && !hit then
          let crash := applyJumpKickCrash state who
          let state := recordExecutedMove crash.state who moveId generated
          let events := critEvents ++ damageEvents ++ handlerGateEvents ++ accuracyEvents ++
            hitEvents ++ before.events.map .effect ++ crash.events
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
          let effectNullified := applied.effectNullified || extra.effectNullified
          let finalState := if effectNullified then clearLoadedEffect finalState who else finalState
          let context := effectsContext finalState who moveId slot
            (side finalState who).active (side finalState who.other).active finalState.battle.rng
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
            hitEvents ++ before.events.map .effect ++
            applied.events ++ extra.events ++ after.events.map .effect ++ lockEvents
          let userFainted := (side state who).active.active.fainted
          if targetFainted && userFainted then
            let (state, faintEvents) := recordSimultaneousFaint state who.other
            .transitioned state (events ++ faintEvents)
          else if targetFainted then
            let (state, faintEvents) := recordFaint state who.other
            .transitioned state (events ++ faintEvents)
          else
            let (state, residualEvents) := applyResidual state who
            .transitioned state (events ++ residualEvents)

def confusionSelfHitPower : UInt8 := 40

@[simp] theorem confusion_self_hit_is_typeless_fixed_protocol :
    confusionSelfHitPower = 40 := by
  rfl

private def attack (state : State) (who : Side) (action : Full.Action)
    (overrideMove : Option MoveId := none) (skipStatus : Bool := false) : StepResult :=
  let selected : Option (MoveId × Fin 4) := match overrideMove with
    | some move =>
        let slot := (selection state who).highlightedSlot.toNat % 4
        some (move, ⟨slot, Nat.mod_lt _ (by omega)⟩)
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
              let damage := Damage.calcBaseDamage attacker.active.level false confusionSelfHitPower
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
            | .done _ => prependMoveExecuted who moveId
                (executeMove state who action moveId slot attacker attackerFull defenderFull rng false)
            | _ => .disobediencePending installed machine none []
          else
            let generatedContinuation := action == .noAction &&
              (selection state who).loadedMove != (selection state who).selectedMove
            prependMoveExecuted who moveId
              (executeMove state who action moveId slot attacker attackerFull defenderFull rng
                (overrideMove.isSome || generatedContinuation))


def switchAiLayer (current : UInt8) (who : Side) (forced : Bool) : UInt8 :=
  if who == .enemy && forced then 0 else current

@[simp] theorem forced_enemy_switch_resets_ai_layer (current : UInt8) :
    switchAiLayer current .enemy true = 0 := by
  have enemySelf : (Side.enemy == Side.enemy) = true := by native_decide
  simp [switchAiLayer, enemySelf]

@[simp] theorem voluntary_enemy_switch_retains_ai_layer (current : UInt8) :
    switchAiLayer current .enemy false = current := by
  simp [switchAiLayer]

def advanceReplacementQueue (current queued : Option Side) (who : Side) :
    Option Side × Option Side :=
  if current == some who then (queued, none) else (current, queued)

@[simp] theorem simultaneous_player_replacement_advances_enemy :
    advanceReplacementQueue (some .player) (some .enemy) .player = (some .enemy, none) := by
  native_decide

@[simp] theorem enemy_replacement_drains_queue :
    advanceReplacementQueue (some .enemy) none .enemy = (none, none) := by
  native_decide

/-- `SendOutMon` clears only `wPlayerMoveNum`; `wPlayerSelectedMove` and the
loaded power/type/etc. record remain stale. -/
def clearPlayerMoveOnSendOut (scratch : Selection.MoveScratch) : Selection.MoveScratch :=
  { scratch with loadedMove := 0 }

def clearPlayerSelectionOnSendOut (state : State) : State :=
  { state with playerSelection := clearPlayerMoveOnSendOut state.playerSelection }

@[simp] theorem send_out_clears_move_but_retains_record (scratch : Selection.MoveScratch) :
    (clearPlayerMoveOnSendOut scratch).loadedMove = 0 ∧
    (clearPlayerMoveOnSendOut scratch).selectedMove = scratch.selectedMove ∧
    (clearPlayerMoveOnSendOut scratch).effect = scratch.effect ∧
    (clearPlayerMoveOnSendOut scratch).power = scratch.power ∧
    (clearPlayerMoveOnSendOut scratch).type = scratch.type ∧
    (clearPlayerMoveOnSendOut scratch).accuracy = scratch.accuracy ∧
    (clearPlayerMoveOnSendOut scratch).pp = scratch.pp := by
  simp [clearPlayerMoveOnSendOut]

private def applySwitch (state : State) (who : Side) (target : Fin 6)
    (forced : Bool := false) : Option State :=
  match state.battle.switchTo who target.val with
  | none => none
  | some battle =>
      let battle := if who == .player then
        let active := Full.applyPlayerSendOutBadges battle.mode state.badges
          battle.player.active
        battle.setSide .player { battle.player with active }
        else battle
      let state := { state with battle := battle }
      let state := if who == .player then clearPlayerSelectionOnSendOut state else state
      let replacements := advanceReplacementQueue state.forcedReplacement
        state.queuedReplacement who
      some { state with
        forcedReplacement := replacements.1
        queuedReplacement := replacements.2
        aiLayer2Encouragement := switchAiLayer state.aiLayer2Encouragement who forced }

private def applyItem (state : State) (who : Side) (request : Items.Request) : StepResult :=
  let trainerOwned := state.trainerAiItem && who == .enemy
  let state := if trainerOwned then { state with trainerAiItem := false } else state
  let user : Items.UserState := { side := side state who, bag := bag state who }
  let result := if trainerOwned then Items.aiUse state.battle.mode user request
    else Items.use state.battle.mode user request
  match result with
  | .rejected _ => .ineffectiveAction state who
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
      let state := if request.item == 0x49 then
        let opponent := Items.wakeOpponentForFlute state.battle.mode (side state who.other)
        setSide state who.other opponent
        else state
      .transitioned state [.item who itemEvents]

private def isFight : Full.Action → Bool
  | .fight _ | .struggle => true
  | _ => false

/-- Automatic cartridge turns enter the retained move/status pipeline even
though no menu action is transmitted. Fly/Dig, Bide, Thrash, trapping, and Rage
can execute the retained move; recharge, sleep/freeze, or trapping may instead
stop at their cartridge status gate. -/
def executesMove (state : State) (who : Side) (action : Full.Action) : Bool :=
  isFight action || (action == .noAction && state.battle.mode != .oldMan &&
    (Full.fullMenuBypass (side state who) ||
      Full.fightSkipsMoveMenu (side state who)
        (side state who.other).active.volatile.trapping))

@[simp] theorem charging_no_action_executes (state : State) (who : Side)
    (ordinary : state.battle.mode ≠ .oldMan)
    (charging : (side state who).active.volatile.chargingUp = true) :
    executesMove state who .noAction = true := by
  have modeBool : (state.battle.mode != BattleMode.oldMan) = true := by
    cases mode : state.battle.mode <;> try native_decide
    exact (ordinary mode).elim
  have actionSelf : (Full.Action.noAction == Full.Action.noAction) = true := by
    native_decide
  simp [executesMove, modeBool, actionSelf, Full.fullMenuBypass, charging]

/-- The second turn of a charge mechanic is an executed, retained-move command
whose PP-decrement gate is enabled. Together with
`Status.successful_charge_clears_both`, this is the automatic continuation
protocol used by Fly in episode 606. -/
theorem charge_continuation_protocol (state : State) (who : Side)
    (ordinary : state.battle.mode ≠ .oldMan)
    (charging : (side state who).active.volatile.chargingUp = true)
    (invulnerable : Bool)
    (charge : (EffectPlan.plan
      (Data.moveData (selection state who).loadedMove).effect).mechanic =
        .charge invulnerable) :
    executesMove state who .noAction = true ∧
      (moveOfAction state who .noAction).map Prod.fst =
        some (selection state who).loadedMove ∧
      decrementsPpNow
        (EffectPlan.plan
          (Data.moveData (selection state who).loadedMove).effect).mechanic
        .noAction = true := by
  refine ⟨charging_no_action_executes state who ordinary charging,
    no_action_uses_retained_move state who, ?_⟩
  rw [charge]
  rfl

def orderingMove (state : State) (who : Side) (action : Full.Action) : Step.ResolvedMove :=
  if executesMove state who action then
    (moveOfAction state who action).map (fun pair => resolveMove pair.1) |>.getD (resolveMove 165)
  else resolveMove (selection state who).selectedMove

@[simp] theorem send_out_retains_stale_priority (state : State) (target : Fin 6) :
    orderingMove (clearPlayerSelectionOnSendOut state) .player (.switch target) =
      resolveMove state.playerSelection.selectedMove := by
  rfl

@[simp] theorem commitSelection_switch (state : State) (who : Side) (target : Fin 6) :
    commitSelection state who (.switch target) = state := rfl

@[simp] theorem commitSelection_item (state : State) (who : Side) (request : Items.Request) :
    commitSelection state who (.item request) = state := rfl

@[simp] theorem commitSelection_run (state : State) (who : Side) :
    commitSelection state who .run = state := rfl

@[simp] theorem orderingMove_player_switch (state : State) (target : Fin 6) :
    orderingMove state .player (.switch target) =
      resolveMove state.playerSelection.selectedMove := rfl

@[simp] theorem orderingMove_player_item (state : State) (request : Items.Request) :
    orderingMove state .player (.item request) =
      resolveMove state.playerSelection.selectedMove := rfl

@[simp] theorem orderingMove_player_run (state : State) :
    orderingMove state .player .run = resolveMove state.playerSelection.selectedMove := rfl

/-- A stale Counter selection therefore keeps its last-place priority while a
switch, item, or run action is already committed. -/
theorem stale_counter_nonfight_priority (state : State)
    (stale : state.playerSelection.selectedMove = 68) (target : Fin 6)
    (request : Items.Request) :
    (orderingMove state .player (.switch target)).priority = .counter ∧
    (orderingMove state .player (.item request)).priority = .counter ∧
    (orderingMove state .player .run).priority = .counter := by
  simp [stale, resolveMove, movePriority]

/-- `ExecuteEnemyMove` increments layer-2 encouragement before status gates. -/
def beginEnemyExecution (state : State) : State :=
  { state with aiLayer2Encouragement := state.aiLayer2Encouragement + 1 }

@[simp] theorem beginEnemyExecution_increments (state : State) :
    (beginEnemyExecution state).aiLayer2Encouragement =
      state.aiLayer2Encouragement + 1 := rfl

private def prependAction (who : Side) (action : Full.Action) : StepResult → StepResult
  | .transitioned state events => .transitioned state (.action who action :: events)
  | .capturePending state ball events => .capturePending state ball (.action who action :: events)
  | .rngStuck state events => .rngStuck state (.action who action :: events)
  | .divisionFreeze state events => .divisionFreeze state (.action who action :: events)
  | .nestedMove state side move events => .nestedMove state side move (.action who action :: events)
  | .mimicPending state side slot next events =>
      .mimicPending state side slot next (.action who action :: events)
  | .runPending state side next events => .runPending state side next (.action who action :: events)
  | .wildFaintRunPending state events => .wildFaintRunPending state (.action who action :: events)
  | .disobediencePending state machine next events =>
      .disobediencePending state machine next (.action who action :: events)
  | .invalidAction state side => .invalidAction state side
  | .ineffectiveAction state side => .ineffectiveAction state side
  | .inactive state => .inactive state

private def executeCommitted (state : State) (who : Side) (action : Full.Action) : StepResult :=
  let state := if who == .enemy && executesMove state who action then
    beginEnemyExecution state else state
  if state.canceledAction == some who then
    .transitioned { state with canceledAction := none } []
  else if executesMove state who action then
    prependAction who action (attack state who action)
  else
    let (state, events) := applyResidual state who
    if (side state who.other).active.volatile.trapping then
      .transitioned state (.statusBlocked who .trapped :: events)
    else .transitioned state events

private def prependEvents (prior : List Event) : StepResult → StepResult
  | .transitioned state events => .transitioned state (prior ++ events)
  | .capturePending state ball events => .capturePending state ball (prior ++ events)
  | .rngStuck state events => .rngStuck state (prior ++ events)
  | .divisionFreeze state events => .divisionFreeze state (prior ++ events)
  | .nestedMove state side move events => .nestedMove state side move (prior ++ events)
  | .mimicPending state side slot next events =>
      .mimicPending state side slot next (prior ++ events)
  | .runPending state side action events => .runPending state side action (prior ++ events)
  | .wildFaintRunPending state events => .wildFaintRunPending state (prior ++ events)
  | .disobediencePending state machine next events =>
      .disobediencePending state machine next (prior ++ events)
  | .invalidAction state side => .invalidAction state side
  | .ineffectiveAction state side => .ineffectiveAction state side
  | .inactive state => .inactive state

def finishTurn (state : State) : State :=
  { state with battle := { state.battle with turn := state.battle.turn + 1 } }

private def clearDecisionFlinch (side : Full.SideState) : Full.SideState :=
  let mask := ~~~((1 <<< Wram.BattleStatus1.flinched).toUInt8)
  { side with active := { side.active with volatile :=
      { side.active.volatile with status1 := side.active.volatile.status1 &&& mask } } }

private theorem clear_flinch_byte (value : UInt8) :
    bitSet (value &&& ~~~((1 <<< Wram.BattleStatus1.flinched).toUInt8))
      Wram.BattleStatus1.flinched = false := by
  have checked : (List.range 256).all (fun raw =>
      bitSet (raw.toUInt8 &&&
        ~~~((1 <<< Wram.BattleStatus1.flinched).toUInt8))
          Wram.BattleStatus1.flinched == false) = true := by
    native_decide
  have item := (List.all_eq_true.mp checked) value.toNat
    (List.mem_range.mpr value.toNat_lt)
  have itemEq := beq_iff_eq.mp item
  have round : value.toNat.toUInt8 = value := by
    apply UInt8.toNat.inj
    simp
  rw [round] at itemEq
  exact itemEq

@[simp] private theorem clear_decision_flinch_clears (side : Full.SideState) :
    (clearDecisionFlinch side).active.volatile.flinched = false := by
  exact clear_flinch_byte side.active.volatile.status1

/-- `MainInBattleLoop` clears both flinch bits before ordinary move selection,
except when the local player is already committed to Rage or recharge. Forced
replacement remains before that loop boundary. In the synchronized link
quotient, `.player` is the local cartridge owner and both mirrored flinch bits
are normalized at this same observable boundary. -/
def prepareDecision (state : State) : State :=
  let playerVolatile := (side state .player).active.volatile
  if state.forcedReplacement.isSome || playerVolatile.recharging ||
      bitSet playerVolatile.status2 Wram.BattleStatus2.usingRage then state
  else
    setSide (setSide state .player (clearDecisionFlinch (side state .player)))
      .enemy (clearDecisionFlinch (side state .enemy))

@[simp] theorem prepare_decision_preserves_forced_replacement (state : State)
    (forced : state.forcedReplacement.isSome = true) :
    prepareDecision state = state := by
  simp [prepareDecision, forced]

@[simp] theorem prepare_decision_preserves_rage_or_recharge (state : State)
    (committed : ((side state .player).active.volatile.recharging ||
      bitSet (side state .player).active.volatile.status2
        Wram.BattleStatus2.usingRage) = true) :
    prepareDecision state = state := by
  by_cases forced : state.forcedReplacement.isSome
  · simp [prepareDecision, forced]
  · simp [prepareDecision, forced, committed]

/-- A late flinch set after the target has already acted cannot leak into the
next ordinary cartridge turn. This is the exact consequence of the two `res
FLINCHED` instructions in `MainInBattleLoop`. -/
theorem prepare_decision_clears_both_flinches (state : State)
    (ordinary : state.forcedReplacement.isSome = false)
    (notRecharge : (side state .player).active.volatile.recharging = false)
    (notRage : bitSet (side state .player).active.volatile.status2
      Wram.BattleStatus2.usingRage = false) :
    (side (prepareDecision state) .player).active.volatile.flinched = false ∧
      (side (prepareDecision state) .enemy).active.volatile.flinched = false := by
  unfold prepareDecision
  rw [ordinary]
  simp only [Bool.false_or]
  rw [notRecharge, notRage]
  simp [side, setSide, Full.State.side, Full.State.setSide]

@[simp] theorem finish_turn_increments (state : State) :
    (finishTurn state).battle.turn = state.battle.turn + 1 := by
  rfl

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
            .transitioned (finishTurn state) (events ++ more)
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
      let state := prepareDecision state
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
              if state.battle.mode == .link then
                let terminal := Outcome.BattleTerminal.mk' (.linkRun forced) state.battle.mode .player
                  (if forced == .player then 1 else 0)
                .transitioned { state with battle := { state.battle with phase := .ending terminal } }
                  [.terminal terminal]
              else if forced == .player && state.battle.mode == .wild then
                .wildFaintRunPending state []
              else .invalidAction state forced
          | _ => .invalidAction state forced
        else
          let processNonFight := fun (state : State) (who : Side) (action : Full.Action) =>
            match action with
            | .switch target =>
                if (side state who.other).active.volatile.trapping then some state
                else applySwitch state who target
            | _ => some state
          match processNonFight state .player playerAction with
          | none => .invalidAction state .player
          | some state => match processNonFight state .enemy enemyAction with
            | none => .invalidAction state .enemy
            | some state =>
                match playerAction, enemyAction with
                | .item playerRequest, .item enemyRequest =>
                    let playerResult :=
                      if (side state .enemy).active.volatile.trapping then
                        StepResult.transitioned state []
                      else applyItem state .player playerRequest
                    match playerResult with
                    | .transitioned state playerEvents =>
                        let enemyResult :=
                          if (side state .player).active.volatile.trapping then
                            StepResult.transitioned state []
                          else applyItem state .enemy enemyRequest
                        match enemyResult with
                        | .transitioned state enemyEvents =>
                            executePair state playerAction enemyAction (playerEvents ++ enemyEvents)
                        | result => prependEvents playerEvents result
                    | result => result
                | .item request, enemyAction =>
                    let itemResult :=
                      if (side state .enemy).active.volatile.trapping then
                        StepResult.transitioned state []
                      else applyItem state .player request
                    match itemResult with
                    | .transitioned state itemEvents =>
                        executePair state playerAction enemyAction itemEvents
                    | result => result
                | playerAction, .item request =>
                    let itemResult :=
                      if (side state .player).active.volatile.trapping then
                        StepResult.transitioned state []
                      else applyItem state .enemy request
                    match itemResult with
                    | .transitioned state itemEvents =>
                        executePair state playerAction enemyAction itemEvents
                    | result => result
                | .run, _ =>
                    if (side state .enemy).active.volatile.trapping then
                      executePair state playerAction enemyAction
                    else if state.battle.mode == .link then
                      let terminal := Outcome.BattleTerminal.mk' (.linkRun .player)
                        state.battle.mode .player 1
                      .transitioned { state with battle := { state.battle with phase := .ending terminal } }
                        [.terminal terminal]
                    else if state.battle.mode == .trainer then .transitioned state []
                    else .runPending state .player enemyAction []
                | _, .run =>
                    if (side state .player).active.volatile.trapping then
                      executePair state playerAction enemyAction
                    else if state.battle.mode == .link then
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
            prependMoveExecuted .player move
              (executeMove state .player action move slot player.active player defender
                state.battle.rng false)
        | .alternate _ move =>
            prependMoveExecuted .player move
              (executeMove state .player action move slot player.active player defender
                state.battle.rng false)
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
  let result := if executesMove state runner.other opponentAction then
    attack state runner.other opponentAction
    else .transitioned state []
  match result with
  | .transitioned state events => .transitioned (finishTurn state) events
  | result => result

@[simp] theorem failed_run_nonmove_finishes_turn (state : State) (runner : Side)
    (notMove : executesMove state runner.other .noAction = false) :
    resumeFailedRun state runner .noAction = .transitioned (finishTurn state) [] := by
  simp [resumeFailedRun, notMove]

/-- Complete the ordinary-player Mimic menu. The copied move replaces Mimic's
selected slot without changing that slot's PP byte. Invalid/blank target slots
remain explicit invalid input rather than silently choosing another move. -/
def resumeMimic (state : State) (who : Side) (sourceSlot targetSlot : Fin 4)
    (nextAction : Option Full.Action) : StepResult :=
  let copied := (side state who.other).active.active.moves.getD targetSlot.val 0
  if copied == 0 then .invalidAction state who
  else
    let actor := side state who
    let mon := Effects.mimicReplace actor.active.active sourceSlot copied
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

def nestedPartyPp (packed : UInt8) : UInt8 := packed + 1

/-- `IncrementMovePP` offsets the wrapper's first decrement in loaded state
and increments the original party slot unconditionally, even while transformed. -/
def incrementNestedPp (state : State) (who : Side) : State :=
  let current := side state who
  let slot := (selection state who).highlightedSlot.toNat % 4
  let activePp := current.active.active.pp.modify slot fun packed => packed + 1
  let activeMon := { current.active.active with pp := activePp }
  let party := { mons := current.party.mons.modify current.activeIndex fun mon =>
    { mon with pp := mon.pp.modify slot nestedPartyPp } }
  setSide state who { current with party, active := { current.active with active := activeMon } }

/-- A transformed nested wrapper increments its untouched original-party byte;
the generated move's later decrement applies only to loaded copied PP. -/
theorem transformed_nested_party_pp_increment (packed : UInt8) :
    nestedPartyPp packed = packed + 1 := rfl

def installGeneratedLoadedMove (state : State) (who : Side) (move : MoveId) : State :=
  let scratch := { selection state who with loadedMove := move }
  setSelection state who scratch

@[simp] theorem generated_move_retains_wrapper (state : State) (who : Side)
    (move : MoveId) :
    (selection (installGeneratedLoadedMove state who move) who).selectedMove =
        (selection state who).selectedMove ∧
      (selection (installGeneratedLoadedMove state who move) who).loadedMove = move := by
  cases who <;> simp [installGeneratedLoadedMove, selection, setSelection]

/-- Continue a Mirror Move or Metronome request in the same action. Status gating
is not repeated. The wrapper increment and generated decrement remain separate;
another nested signal is an explicit continuation, so recursive Metronome is not
fuel-bounded. -/
def resumeNested (state : State) (who : Side) (move : MoveId) : StepResult :=
  let state := installGeneratedLoadedMove (incrementNestedPp state who) who move
  attack state who (.fight 0) (some move) true

/-- Legal actions are exposed directly from the engine state. -/
def legalActions (state : State) (who : Side) : Array Full.Action :=
  Full.legalActions (actionContext state who)

end Battle.Full.Engine
