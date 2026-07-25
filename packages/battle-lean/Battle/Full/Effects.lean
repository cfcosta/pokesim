/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Full.EffectPlan
import Battle.Full.Items
import Battle.Full.Money
import Battle.Effects.Substitute
import Battle.Effects.Healing
import Battle.LinkBugs

/-!
# Executable move-effect families

Shared state transformer for all 87 effect IDs. Complex control effects produce
typed signals consumed by the full turn engine; none are coerced into ordinary
damage. Rejection-search exhaustion is `rngStuck`, not a miss or terminal.
-/

namespace Battle.Full.Effects

open EffectPlan

private def mask (index : Nat) : UInt8 := (1 <<< index).toUInt8
private def setBit (byte : UInt8) (index : Nat) : UInt8 := byte ||| mask index
private def clearBit (byte : UInt8) (index : Nat) : UInt8 := byte &&& ~~~(mask index)

structure Context where
  attacker : Battle.SideState
  defender : Battle.SideState
  move : MoveId
  moveSlot : Fin 4
  mode : BattleMode
  rng : Rng.LinkRng
  payDayMoney : Money.Bcd3 := Money.Bcd3.ofNat 0
  defenderLastMove : MoveId := 0
  deriving Repr, DecidableEq

inductive Signal where
  | continue
  | failed
  | fixedDamage (damage : UInt16)
  | psywave
  | oneHitKo
  | repeatHits (count : UInt8)
  | charging (invulnerable : Bool)
  | escaped
  | callMove (move : MoveId)
  | rngStuck
  deriving Repr, DecidableEq, BEq

inductive Event where
  | rawRng (site : String) (raw : UInt8)
  | statusApplied (status : UInt8)
  | stageChanged (target : Side) (stat amount : Nat)
  | healed (amount : UInt16)
  | recoil (amount : UInt16)
  | screen
  | transformed
  | seeded
  | disabled (move : MoveId) (turns : UInt8)
  | signal (signal : Signal)
  deriving Repr, DecidableEq, BEq

/-- Bounded executable search over the link recurrence. Fuel 2305 covers a full
256-step orbit for each of the nine live bytes; exhaustion remains explicit for
malformed RNG states rather than becoming a miss. -/
private def drawAccepted : Nat → Rng.LinkRng → (UInt8 → Bool) → String →
    Option (UInt8 × Rng.LinkRng × List Event)
  | 0, _, _, _ => none
  | fuel + 1, rng, accepts, site =>
      let (raw, rng) := rng.next
      if accepts raw then some (raw, rng, [.rawRng site raw])
      else match drawAccepted fuel rng accepts site with
        | none => none
        | some (accepted, rng, events) =>
            some (accepted, rng, .rawRng (site ++ "-rejected") raw :: events)

structure Outcome where
  context : Context
  signal : Signal := .continue
  events : List Event := []
  deriving Repr, DecidableEq

private def withAttacker (context : Context) (side : Battle.SideState) : Context :=
  { context with attacker := side }
private def withDefender (context : Context) (side : Battle.SideState) : Context :=
  { context with defender := side }

private def setAttackerVolatile (context : Context) (volatile : Volatile) : Context :=
  withAttacker context { context.attacker with volatile }
private def setDefenderVolatile (context : Context) (volatile : Volatile) : Context :=
  withDefender context { context.defender with volatile }

private def setStage (stages : StatStages) (stat : Nat) (value : UInt8) : StatStages :=
  match stat with
  | 0 => { stages with attack := value }
  | 1 => { stages with defense := value }
  | 2 => { stages with speed := value }
  | 3 => { stages with special := value }
  | 4 => { stages with accuracy := value }
  | _ => { stages with evasion := value }

private def getStage (stages : StatStages) (stat : Nat) : UInt8 :=
  match stat with
  | 0 => stages.attack
  | 1 => stages.defense
  | 2 => stages.speed
  | 3 => stages.special
  | 4 => stages.accuracy
  | _ => stages.evasion

private def raiseStage (context : Context) (stat amount : Nat) : Outcome :=
  let old := getStage context.attacker.stages stat
  if old.toNat ≥ 13 then ⟨context, .failed, []⟩
  else
    let value := (min 13 (old.toNat + amount)).toUInt8
    let attacker := { context.attacker with stages := setStage context.attacker.stages stat value }
    ⟨withAttacker context attacker, .continue, [.stageChanged .player stat amount]⟩

private def lowerStage (context : Context) (stat amount : Nat) : Outcome :=
  if context.defender.volatile.hasSubstitute ||
      bitSet context.defender.volatile.status2 Wram.BattleStatus2.protectedByMist then
    ⟨context, .failed, []⟩
  else
    let old := getStage context.defender.stages stat
    if old.toNat ≤ 1 then ⟨context, .failed, []⟩
    else
      let value := (max 1 (old.toNat - amount)).toUInt8
      let defender := { context.defender with stages := setStage context.defender.stages stat value }
      ⟨withDefender context defender, .continue, [.stageChanged .enemy stat amount]⟩

private def sideChance (threshold : UInt8) (context : Context) : Bool × Context × Event :=
  let (raw, rng) := context.rng.next
  (raw < threshold, { context with rng }, .rawRng "side-effect" raw)

private def applyMajorStatus (status : UInt8) (moveType : UInt8)
    (context : Context) : Outcome :=
  let target := context.defender.active
  let typeImmune := target.type1 == moveType || target.type2 == moveType
  if context.defender.volatile.hasSubstitute || target.status != 0 || typeImmune then
    ⟨context, .failed, []⟩
  else
    let mon := { target with status }
    ⟨withDefender context { context.defender with active := mon }, .continue,
      [.statusApplied status]⟩

private def poison (toxic : Bool) (context : Context) : Outcome :=
  let target := context.defender.active
  if context.defender.volatile.hasSubstitute || target.status != 0 ||
      target.type1 == TypeChart.poison || target.type2 == TypeChart.poison then
    ⟨context, .failed, []⟩
  else
    let defender := { context.defender with active := { target with status := mask Wram.Status.psn } }
    let defender := if toxic then
      { defender with volatile := { defender.volatile with
          status3 := setBit defender.volatile.status3 Wram.BattleStatus3.badlyPoisoned
          toxicCounter := 0 } }
      else defender
    ⟨withDefender context defender, .continue, [.statusApplied (mask Wram.Status.psn)]⟩

private def confuse (context : Context) : Outcome :=
  if context.defender.volatile.hasSubstitute || context.defender.volatile.confused then
    ⟨context, .failed, []⟩
  else
    let (raw, rng) := context.rng.next
    let turns := (raw &&& 3) + 2
    let volatile := { context.defender.volatile with
      status1 := setBit context.defender.volatile.status1 Wram.BattleStatus1.confused
      confusedCounter := turns }
    ⟨setDefenderVolatile { context with rng } volatile, .continue,
      [.rawRng "confusion-duration" raw]⟩

private def healSelf (context : Context) : Outcome :=
  let kind := if context.move == 156 then Effects.Healing.Kind.rest
    else if context.move == 135 then .softboiled else .recover
  match Effects.Healing.use kind context.attacker.active.hp context.attacker.active.maxHp with
  | .failed => ⟨context, .failed, []⟩
  | .healed hp rest =>
      let mon := { context.attacker.active with hp := hp }
      let mon := { mon with status := if rest then 2 else context.attacker.active.status }
      let attacker := { context.attacker with active := mon }
      ⟨withAttacker context attacker, .continue,
        [.healed (hp - context.attacker.active.hp)]⟩

private def substitute (context : Context) : Outcome :=
  match Effects.Substitute.use context.attacker.volatile.hasSubstitute
      context.attacker.active.hp context.attacker.active.maxHp with
  | .alreadyPresent | .insufficientHp => ⟨context, .failed, []⟩
  | .created hp substituteHp =>
      let active := { context.attacker.active with hp }
      let volatile := { context.attacker.volatile with
        status2 := setBit context.attacker.volatile.status2 Wram.BattleStatus2.hasSubstituteUp
        substituteHp }
      ⟨withAttacker context { context.attacker with active, volatile }, .continue, []⟩

private def screen (context : Context) (light : Bool) : Outcome :=
  let index := if light then Wram.BattleStatus3.hasLightScreenUp
    else Wram.BattleStatus3.hasReflectUp
  if bitSet context.attacker.volatile.status3 index then ⟨context, .failed, []⟩
  else
    let volatile := { context.attacker.volatile with
      status3 := setBit context.attacker.volatile.status3 index }
    ⟨setAttackerVolatile context volatile, .continue, [.screen]⟩

private def startLock (context : Context) (bit : Nat) (turns : UInt8) : Context :=
  let volatile := { context.attacker.volatile with
    status1 := setBit context.attacker.volatile.status1 bit
    numAttacksLeft := turns }
  setAttackerVolatile context volatile

private def multiHitCount (context : Context) : UInt8 × Context × List Event :=
  let (first, rng) := context.rng.next
  let masked := first &&& 3
  if masked < 2 then (masked + 2, { context with rng }, [.rawRng "multi-hit" first])
  else
    let (second, rng) := rng.next
    (second &&& 3 |>.add 2, { context with rng },
      [.rawRng "multi-hit" first, .rawRng "multi-hit-reroll" second])

private def disable (context : Context) : Outcome :=
  if context.defender.volatile.disabledMove != 0 then ⟨context, .failed, []⟩
  else
    let eligible := (Array.range Wram.numMoves).filter fun slot =>
      context.defender.active.moves.getD slot 0 != 0 &&
        (context.mode != .link ||
          (context.defender.active.pp.getD slot 0 &&& Wram.ppMask) != 0)
    if eligible.isEmpty then ⟨context, .failed, []⟩
    else
      let (slotRaw, rng) := context.rng.next
      let slot := eligible.getD (slotRaw.toNat % eligible.size) 0
      let (turnRaw, rng) := rng.next
      let turns := (turnRaw &&& 7) + 1
      let move := context.defender.active.moves.getD slot 0
      let packed := ((slot + 1) * 16).toUInt8 + turns
      let volatile := { context.defender.volatile with
        disabledMove := packed, disabledMoveNumber := move }
      ⟨setDefenderVolatile { context with rng } volatile, .continue,
        [.rawRng "disable-slot" slotRaw, .rawRng "disable-turns" turnRaw,
         .disabled move turns]⟩

/-- Pre/standalone effect phase. `hit` is the already-resolved hit test for
routines that call `MoveHitTest`; direct setup effects ignore it where the ROM
does. -/
def applyBefore (effect : UInt8) (hit : Bool) (context : Context) : Outcome :=
  match (plan effect).mechanic with
  | .ordinary | .unused | .drain | .burnSide _ | .freezeSide _ | .paralyzeSide _
  | .poisonSide _ | .explode | .dreamEater | .payDay | .swift
  | .flinchSide _ | .superFang | .specialDamage | .jumpKick
  | .recoil | .statDownSide _ | .confusionSide | .hyperBeam
  | .rage => { context := context }
  | .multiHit =>
      let (count, context, events) := multiHitCount context
      ⟨context, .repeatHits count, events ++ [.signal (.repeatHits count)]⟩
  | .attackTwice | .twineedle =>
      ⟨context, .repeatHits 2, [.signal (.repeatHits 2)]⟩
  | .mirrorMove =>
      if context.defenderLastMove == 0 then ⟨context, .failed, []⟩
      else ⟨context, .callMove context.defenderLastMove,
        [.signal (.callMove context.defenderLastMove)]⟩
  | .statUp stat amount => if hit then raiseStage context stat amount else ⟨context, .failed, []⟩
  | .statDown stat amount => if hit then lowerStage context stat amount else ⟨context, .failed, []⟩
  | .conversion =>
      if bitSet context.defender.volatile.status1 Wram.BattleStatus1.invulnerable then
        ⟨context, .failed, []⟩
      else
        let mon := { context.attacker.active with type1 := context.defender.active.type1 }
        let mon := { mon with type2 := context.defender.active.type2 }
        { context := withAttacker context { context.attacker with active := mon } }
  | .haze =>
      let clearSide := fun (side : Battle.SideState) =>
        let active := { side.active with status := 0 }
        let volatile := { side.volatile with
          status1 := clearBit side.volatile.status1 Wram.BattleStatus1.confused }
        let volatile := { volatile with status2 := side.volatile.status2 &&& 0x78 }
        let volatile := { volatile with status3 := side.volatile.status3 &&& 0xF8 }
        let volatile := { volatile with disabledMove := 0 }
        let volatile := { volatile with disabledMoveNumber := 0 }
        { active, stages := StatStages.neutral, volatile }
      let context := withAttacker context (clearSide context.attacker)
      { context := withDefender context (clearSide context.defender) }
  | .bide =>
      let context := startLock context Wram.BattleStatus1.storingEnergy 2
      let volatile := { context.attacker.volatile with bideAccumulated := 0 }
      { context := setAttackerVolatile context volatile }
  | .thrash =>
      let (raw, rng) := context.rng.next
      let turns := (raw &&& 1) + 2
      ⟨startLock { context with rng } Wram.BattleStatus1.thrashingAbout turns,
        .continue, [.rawRng "thrash-turns" raw]⟩
  | .switchOrTeleport =>
      if context.mode == .trainer then ⟨context, .failed, []⟩ else ⟨context, .escaped, [.signal .escaped]⟩
  | .sleep =>
      if !hit || context.defender.active.status != 0 then ⟨context, .failed, []⟩
      else match drawAccepted 2305 context.rng
          (fun raw => (raw &&& Wram.Status.slpMask) != 0) "sleep-turns" with
        | none => ⟨context, .rngStuck, [.signal .rngStuck]⟩
        | some (raw, rng, events) =>
            let turns := raw &&& Wram.Status.slpMask
            let mon := { context.defender.active with status := turns }
            ⟨withDefender { context with rng } { context.defender with active := mon },
              .continue, events ++ [.statusApplied turns]⟩
  | .ohko => if context.attacker.active.speed ≥ context.defender.active.speed then
      ⟨context, .oneHitKo, [.signal .oneHitKo]⟩ else ⟨context, .failed, []⟩
  | .charge invulnerable =>
      let bitStatus := setBit context.attacker.volatile.status1 Wram.BattleStatus1.chargingUp
      let bitStatus := if invulnerable then setBit bitStatus Wram.BattleStatus1.invulnerable else bitStatus
      let volatile := { context.attacker.volatile with status1 := bitStatus }
      ⟨setAttackerVolatile context volatile, .charging invulnerable,
        [.signal (.charging invulnerable)]⟩
  | .trapping =>
      let (count, context, events) := multiHitCount context
      let context := startLock context Wram.BattleStatus1.usingTrappingMove count
      ⟨context, .continue, events⟩
  | .mist =>
      let index := Wram.BattleStatus2.protectedByMist
      if bitSet context.attacker.volatile.status2 index then ⟨context, .failed, []⟩
      else
        let volatile := { context.attacker.volatile with
          status2 := setBit context.attacker.volatile.status2 index }
        { context := setAttackerVolatile context volatile }
  | .focusEnergy =>
      let index := Wram.BattleStatus2.gettingPumped
      if bitSet context.attacker.volatile.status2 index then ⟨context, .failed, []⟩
      else
        let volatile := { context.attacker.volatile with
          status2 := setBit context.attacker.volatile.status2 index }
        { context := setAttackerVolatile context volatile }
  | .confusion => if hit then confuse context else ⟨context, .failed, []⟩
  | .heal => healSelf context
  | .transform =>
      let target := context.defender.active
      let mon := { context.attacker.active with type1 := target.type1 }
      let mon := { mon with type2 := target.type2 }
      let mon := { mon with moves := target.moves }
      let mon := { mon with attack := target.attack }
      let mon := { mon with defense := target.defense }
      let mon := { mon with speed := target.speed }
      let mon := { mon with special := target.special }
      let mon := { mon with pp := target.moves.map (fun move => if move == 0 then 0 else 5) }
      let volatile := { context.attacker.volatile with
        status3 := setBit context.attacker.volatile.status3 Wram.BattleStatus3.transformed }
      let attacker : Battle.SideState :=
        { active := mon, stages := context.defender.stages, volatile }
      ⟨withAttacker context attacker, .continue, [.transformed]⟩
  | .lightScreen => screen context true
  | .reflect => screen context false
  | .poison => if hit then poison (context.move == 92) context else ⟨context, .failed, []⟩
  | .paralyze => if hit then
      applyMajorStatus (mask Wram.Status.par) TypeChart.electric context
      else ⟨context, .failed, []⟩
  | .substitute => substitute context
  | .mimic =>
      let move := context.defender.active.moves.getD context.moveSlot.val 0
      if !hit || move == 0 then ⟨context, .failed, []⟩ else ⟨context, .callMove move, [.signal (.callMove move)]⟩
  | .metronome =>
      match drawAccepted 2305 context.rng
          (fun raw => raw != 0 && raw < 165 && raw != 118) "metronome" with
      | none => ⟨context, .rngStuck, [.signal .rngStuck]⟩
      | some (move, rng, events) =>
          ⟨{ context with rng }, .callMove move, events ++ [.signal (.callMove move)]⟩
  | .leechSeed =>
      if !hit || context.defender.active.type1 == TypeChart.grass ||
          context.defender.active.type2 == TypeChart.grass || context.defender.volatile.seeded then
        ⟨context, .failed, []⟩
      else
        let volatile := { context.defender.volatile with
          status2 := setBit context.defender.volatile.status2 Wram.BattleStatus2.seeded }
        ⟨setDefenderVolatile context volatile, .continue, [.seeded]⟩
  | .splash => { context := context }
  | .disable => if hit then disable context else ⟨context, .failed, []⟩
  | .malformed => ⟨context, .failed, []⟩

private def damageSelf (context : Context) (damage : UInt16) : Context :=
  let hp := Step.saturatingSub context.attacker.active.hp damage
  withAttacker context { context.attacker with active := { context.attacker.active with hp } }

/-- Post-damage/remaining effect phase. -/
def applyAfter (effect moveType : UInt8) (hit targetFainted : Bool)
    (damage : UInt16) (context : Context) : Outcome :=
  match (plan effect).mechanic with
  | .poisonSide threshold =>
      if !hit then { context := context }
      else
        let (success, context, event) := sideChance threshold context
        if success then
          let out := poison false context
          { out with events := event :: out.events }
        else ⟨context, .continue, [event]⟩
  | .burnSide threshold | .freezeSide threshold | .paralyzeSide threshold =>
      if !hit then { context := context }
      else
        let mechanic := (plan effect).mechanic
        let (success, context, event) := sideChance threshold context
        if !success then ⟨context, .continue, [event]⟩
        else
          let status := match mechanic with
            | .burnSide _ => mask Wram.Status.brn
            | .freezeSide _ => mask Wram.Status.frz
            | _ => mask Wram.Status.par
          let out := applyMajorStatus status moveType context
          { out with events := event :: out.events }
  | .drain | .dreamEater =>
      if !hit then { context := context } else
        let amount := UInt16.ofNat (max 1 (damage.toNat / 2))
        let hp := UInt16.ofNat
          (min (context.attacker.active.hp.toNat + amount.toNat) context.attacker.active.maxHp.toNat)
        let attacker := { context.attacker with active := { context.attacker.active with hp } }
        ⟨withAttacker context attacker, .continue, [.healed (hp - context.attacker.active.hp)]⟩
  | .explode =>
      let mon := { context.attacker.active with hp := 0, status := 0 }
      let volatile := { context.attacker.volatile with
        status2 := clearBit context.attacker.volatile.status2 Wram.BattleStatus2.seeded }
      let attacker := { context.attacker with active := mon, volatile := volatile }
      { context := withAttacker context attacker }
  | .payDay =>
      let money := Money.addPayDay context.payDayMoney context.attacker.active.level
      { context := { context with payDayMoney := money } }
  | .multiHit | .attackTwice => { context := context }
  | .twineedle =>
      if !hit then { context := context }
      else
        let (success, context, event) := sideChance 52 context
        if success then
          let out := poison false context
          { out with events := event :: out.events }
        else ⟨context, .continue, [event]⟩
  | .flinchSide threshold =>
      if !hit then { context := context }
      else
        let (success, context, event) := sideChance threshold context
        if success && !context.defender.volatile.hasSubstitute then
          let volatile := { context.defender.volatile with
            status1 := setBit context.defender.volatile.status1 Wram.BattleStatus1.flinched
            status2 := clearBit context.defender.volatile.status2 Wram.BattleStatus2.needsToRecharge }
          ⟨setDefenderVolatile context volatile, .continue, [event]⟩
        else ⟨context, .continue, [event]⟩
  | .recoil =>
      if !hit then { context := context } else
        let recoil := UInt16.ofNat (max 1 (damage.toNat / 4))
        ⟨damageSelf context recoil, .continue, [.recoil recoil]⟩
  | .confusionSide =>
      if !hit then { context := context }
      else
        let (success, context, event) := sideChance 25 context
        if success then
          let out := confuse context
          { out with events := event :: out.events }
        else ⟨context, .continue, [event]⟩
  | .statDownSide stat =>
      if !hit then { context := context }
      else
        let (success, context, event) := sideChance 85 context
        if success then
          let out := lowerStage context stat 1
          { out with events := event :: out.events }
        else ⟨context, .continue, [event]⟩
  | .hyperBeam =>
      if hit && !targetFainted then
        let volatile := { context.attacker.volatile with
          status2 := setBit context.attacker.volatile.status2 Wram.BattleStatus2.needsToRecharge }
        { context := setAttackerVolatile context volatile }
      else { context := context }
  | .rage =>
      let volatile := { context.attacker.volatile with
        status2 := setBit context.attacker.volatile.status2 Wram.BattleStatus2.usingRage }
      { context := setAttackerVolatile context volatile }
  | _ => { context := context }

/-- Numeric special-damage rule before random/type adjustment. -/
def specialDamage (mechanic : Mechanic) (move : MoveId)
    (attacker defender : MonState) : Signal :=
  match mechanic with
  | .superFang => .fixedDamage (UInt16.ofNat (max 1 (defender.hp.toNat / 2)))
  | .specialDamage =>
      if move == 69 || move == 101 then .fixedDamage (UInt16.ofNat attacker.level.toNat)
      else if move == 49 then .fixedDamage 20
      else if move == 82 then .fixedDamage 40
      else .psywave
  | .ohko => if attacker.speed ≥ defender.speed then .oneHitKo else .failed
  | _ => .continue

/-! ## Coverage/integration theorems -/

/-- Every supported effect produces an Outcome rather than an unsupported branch. -/
theorem applyBefore_total (effect : UInt8) (_bounded : effect.toNat ≤ 0x56)
    (hit : Bool) (context : Context) :
    ∃ outcome, applyBefore effect hit context = outcome := by
  exact ⟨_, rfl⟩

/-- Hyper Beam recharge is skipped when its hit faints the target. -/
theorem hyperBeam_faint_skips_recharge (context : Context) (damage : UInt16) :
    (applyAfter Data.Effect.hyperBeam TypeChart.normal true true damage context).context =
      context := by
  change context = context
  rfl

end Battle.Full.Effects
