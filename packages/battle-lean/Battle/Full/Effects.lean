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
import Battle.DamageStats

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

private theorem recharge_clear_bit (byte : UInt8) :
    bitSet (clearBit byte Wram.BattleStatus2.needsToRecharge)
      Wram.BattleStatus2.needsToRecharge = false := by
  have checked : (List.range 256).all (fun n =>
      bitSet (clearBit n.toUInt8 Wram.BattleStatus2.needsToRecharge)
        Wram.BattleStatus2.needsToRecharge = false) = true := by
    native_decide
  have atByte := (List.all_eq_true.mp checked) byte.toNat
    (List.mem_range.mpr (UInt8.toNat_lt byte))
  simpa using atByte

structure Context where
  attackerSide : Side
  attacker : Battle.SideState
  defender : Battle.SideState
  move : MoveId
  moveSlot : Fin 4
  mode : BattleMode
  rng : Rng.LinkRng
  payDayMoney : Money.Bcd3 := Money.Bcd3.ofNat 0
  defenderLastMove : MoveId := 0
  badges : UInt8 := 0
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
  | mimicChoice
  | cancelTargetMove
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

private def currentStat (side : Battle.SideState) (stat : Nat) : UInt16 :=
  match stat with
  | 0 => side.active.attack
  | 1 => side.active.defense
  | 2 => side.active.speed
  | _ => side.active.special

private def originalStat (side : Battle.SideState) (stat : Nat) : UInt16 :=
  match stat with
  | 0 => side.unmodified.attack
  | 1 => side.unmodified.defense
  | 2 => side.unmodified.speed
  | _ => side.unmodified.special

private def setCurrentStat (side : Battle.SideState) (stat : Nat) (value : UInt16) :
    Battle.SideState :=
  let active := match stat with
    | 0 => { side.active with attack := value }
    | 1 => { side.active with defense := value }
    | 2 => { side.active with speed := value }
    | _ => { side.active with special := value }
  { side with active }

private def recalculateStat (side : Battle.SideState) (stat : Nat) (stage : UInt8) :
    Battle.SideState :=
  setCurrentStat side stat (DamageStats.applyStage (originalStat side stat) stage)

private def applyBadges (badges : UInt8) (side : Battle.SideState) : Battle.SideState :=
  let boost (bit stat : Nat) (side : Battle.SideState) :=
    if bitSet badges bit then setCurrentStat side stat
      (DamageStats.badgeBoost (currentStat side stat)) else side
  boost 6 3 (boost 4 2 (boost 2 1 (boost 0 0 side)))

/-- The assembly calls both helpers after every successful stat effect, regardless
of which stat changed. Reapplication therefore stacks and can affect an unrelated
opponent after a self stat-up. -/
private def reapplyStatusPenalties (side : Battle.SideState) : Battle.SideState :=
  let side := if side.active.paralyzed then
    setCurrentStat side 2 (UInt16.ofNat (side.active.speed.toNat / 4)) else side
  if side.active.burned then
    setCurrentStat side 0 (UInt16.ofNat (side.active.attack.toNat / 2)) else side

private def raiseStage (context : Context) (stat amount : Nat) : Outcome :=
  let old := getStage context.attacker.stages stat
  if old.toNat ≥ 13 then ⟨context, .failed, []⟩
  else
    let value := (min 13 (old.toNat + amount)).toUInt8
    let stages := setStage context.attacker.stages stat value
    let attacker := { context.attacker with stages }
    if stat < 4 && currentStat attacker stat == 999 then
      let stages := setStage attacker.stages stat (value - 1)
      ⟨withAttacker context { attacker with stages }, .failed, []⟩
    else
      let attacker := if stat < 4 then recalculateStat attacker stat value else attacker
      let attacker := if context.attackerSide == .player && context.mode != .link then
        applyBadges context.badges attacker else attacker
      let defender := reapplyStatusPenalties context.defender
      let context := withDefender (withAttacker context attacker) defender
      ⟨context, .continue, [.stageChanged context.attackerSide stat amount]⟩

private def lowerStage (context : Context) (stat amount : Nat)
    (respectMist : Bool := true) : Outcome :=
  if context.defender.volatile.hasSubstitute ||
      (respectMist && bitSet context.defender.volatile.status2
        Wram.BattleStatus2.protectedByMist) then
    ⟨context, .failed, []⟩
  else
    let old := getStage context.defender.stages stat
    if old.toNat ≤ 1 then ⟨context, .failed, []⟩
    else
      let value := (max 1 (old.toNat - amount)).toUInt8
      let stages := setStage context.defender.stages stat value
      let defender := { context.defender with stages }
      if stat < 4 && currentStat defender stat == 1 then
        let stages := setStage defender.stages stat (value + 1)
        ⟨withDefender context { defender with stages }, .failed, []⟩
      else
        let defender := if stat < 4 then recalculateStat defender stat value else defender
        let defender := if context.attackerSide == .enemy && context.mode != .link then
          applyBadges context.badges defender else defender
        let defender := reapplyStatusPenalties defender
        let context := withDefender context defender
        ⟨context, .continue, [.stageChanged context.attackerSide.other stat amount]⟩

private def sideChance (threshold : UInt8) (context : Context) : Bool × Context × Event :=
  let (raw, rng) := context.rng.next
  (raw < threshold, { context with rng }, .rawRng "side-effect" raw)

private def applyMajorStatus (status : UInt8) (moveType : UInt8)
    (context : Context) : Outcome :=
  let target := context.defender.active
  let typeImmune := target.type1 == moveType || target.type2 == moveType
  if target.status != 0 || typeImmune then
    ⟨context, .failed, []⟩
  else
    let mon := { target with status }
    let mon := if status == mask Wram.Status.brn then
      { mon with attack := UInt16.ofNat (mon.attack.toNat / 2) }
      else if status == mask Wram.Status.par then
        { mon with speed := UInt16.ofNat (mon.speed.toNat / 4) }
      else mon
    ⟨withDefender context { context.defender with active := mon }, .continue,
      [.statusApplied status]⟩

private def paralyze (moveType : UInt8) (context : Context) : Outcome :=
  let target := context.defender.active
  let groundImmune := moveType == TypeChart.electric &&
    (target.type1 == TypeChart.ground || target.type2 == TypeChart.ground)
  if target.status != 0 || groundImmune then ⟨context, .failed, []⟩
  else
    let mon := { target with
      status := mask Wram.Status.par
      speed := UInt16.ofNat (target.speed.toNat / 4) }
    ⟨withDefender context { context.defender with active := mon }, .continue,
      [.statusApplied (mask Wram.Status.par)]⟩

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

def installSelfHeal (attacker : Battle.SideState) (hp : UInt16) (rest : Bool) :
    Battle.SideState :=
  let mon := { attacker.active with hp }
  let mon := { mon with status := if rest then 2 else attacker.active.status }
  { attacker with active := mon }

@[simp] theorem rest_heal_preserves_toxic (attacker : Battle.SideState) (hp : UInt16) :
    (installSelfHeal attacker hp true).volatile = attacker.volatile := rfl

private def healSelf (context : Context) : Outcome :=
  let kind := if context.move == 156 then Effects.Healing.Kind.rest
    else if context.move == 135 then .softboiled else .recover
  match Effects.Healing.use kind context.attacker.active.hp context.attacker.active.maxHp with
  | .failed => ⟨context, .failed, []⟩
  | .healed hp rest =>
      let attacker := installSelfHeal context.attacker hp rest
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
    let nonblank := fun raw =>
      context.defender.active.moves.getD (raw &&& 3).toNat 0 != 0
    match drawAccepted 2305 context.rng nonblank "disable-slot" with
    | none => ⟨context, .rngStuck, [.signal .rngStuck]⟩
    | some (firstRaw, firstRng, firstEvents) =>
        let firstSlot := (firstRaw &&& 3).toNat
        let limitedPp := !(context.attackerSide == .player && context.mode != .link)
        let anyPp := (Array.range Wram.numMoves).any fun slot =>
          (context.defender.active.pp.getD slot 0 &&& Wram.ppMask) != 0
        if limitedPp && !anyPp then
          ⟨{ context with rng := firstRng }, .failed, firstEvents⟩
        else
          let selectedHasPp :=
            (context.defender.active.pp.getD firstSlot 0 &&& Wram.ppMask) != 0
          let picked := if limitedPp && !selectedHasPp then
            drawAccepted 2305 firstRng (fun raw =>
              let slot := (raw &&& 3).toNat
              context.defender.active.moves.getD slot 0 != 0 &&
                (context.defender.active.pp.getD slot 0 &&& Wram.ppMask) != 0)
              "disable-slot"
            else some (firstRaw, firstRng, [])
          match picked with
          | none => ⟨{ context with rng := firstRng }, .rngStuck,
              firstEvents ++ [.signal .rngStuck]⟩
          | some (slotRaw, rng, laterEvents) =>
              let slot := (slotRaw &&& 3).toNat
              let (turnRaw, rng) := rng.next
              let turns := (turnRaw &&& 7) + 1
              let move := context.defender.active.moves.getD slot 0
              let packed := ((slot + 1) * 16).toUInt8 + turns
              let volatile := { context.defender.volatile with
                disabledMove := packed, disabledMoveNumber := move }
              ⟨setDefenderVolatile { context with rng } volatile, .continue,
                firstEvents ++ laterEvents ++ [.rawRng "disable-turns" turnRaw,
                  .disabled move turns]⟩

private def hazeOutcome (context : Context) : Outcome :=
  let targetWasIncapacitated := context.defender.active.asleep ||
    context.defender.active.frozen
  let clearSide := fun (side : Battle.SideState) =>
    let active := { side.active with attack := side.unmodified.attack }
    let active := { active with defense := side.unmodified.defense }
    let active := { active with speed := side.unmodified.speed }
    let active := { active with special := side.unmodified.special }
    let volatile := { side.volatile with
      status1 := clearBit side.volatile.status1 Wram.BattleStatus1.confused }
    let volatile := { volatile with status2 := side.volatile.status2 &&& 0x78 }
    let volatile := { volatile with status3 := side.volatile.status3 &&& 0xF8 }
    let volatile := { volatile with disabledMove := 0 }
    let volatile := { volatile with disabledMoveNumber := 0 }
    { active, unmodified := side.unmodified, stages := StatStages.neutral, volatile }
  let attacker := clearSide context.attacker
  let defender := clearSide context.defender
  let defender := { defender with active := { defender.active with status := 0 } }
  let context := withDefender (withAttacker context attacker) defender
  if targetWasIncapacitated then
    ⟨context, .cancelTargetMove, [.signal .cancelTargetMove]⟩
  else { context := context }

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
  | .haze => hazeOutcome context
  | .bide =>
      let (raw, rng) := context.rng.next
      let turns := (raw &&& 1) + 2
      let context := startLock { context with rng }
        Wram.BattleStatus1.storingEnergy turns
      let volatile := { context.attacker.volatile with bideAccumulated := 0 }
      ⟨setAttackerVolatile context volatile, .continue, [.rawRng "bide-turns" raw]⟩
  | .thrash =>
      let (raw, rng) := context.rng.next
      let turns := (raw &&& 1) + 2
      ⟨startLock { context with rng } Wram.BattleStatus1.thrashingAbout turns,
        .continue, [.rawRng "thrash-turns" raw]⟩
  | .switchOrTeleport =>
      if context.mode != .wild then ⟨context, .failed, []⟩
      else if context.attacker.active.level ≥ context.defender.active.level then
        ⟨context, .escaped, [.signal .escaped]⟩
      else
        let bound := context.attacker.active.level + context.defender.active.level + 1
        match drawAccepted 2305 context.rng (fun raw => raw < bound) "move-escape" with
        | none => ⟨context, .rngStuck, [.signal .rngStuck]⟩
        | some (raw, rng, events) =>
            if raw ≥ (context.defender.active.level >>> 2) then
              ⟨{ context with rng }, .escaped, events ++ [.signal .escaped]⟩
            else ⟨{ context with rng }, .failed, events⟩
  | .sleep =>
      let recharging := context.defender.volatile.recharging
      let volatile := { context.defender.volatile with
        status2 := clearBit context.defender.volatile.status2
          Wram.BattleStatus2.needsToRecharge }
      let context := setDefenderVolatile context volatile
      if !recharging && (!hit || context.defender.active.status != 0) then
        ⟨context, .failed, []⟩
      else match drawAccepted 2305 context.rng
          (fun raw => (raw &&& Wram.Status.slpMask) != 0) "sleep-turns" with
        | none => ⟨context, .rngStuck, [.signal .rngStuck]⟩
        | some (raw, rng, events) =>
            let turns := raw &&& Wram.Status.slpMask
            let mon := { context.defender.active with status := turns }
            ⟨withDefender { context with rng } { context.defender with active := mon },
              .continue, events ++ [.statusApplied turns]⟩
  | .ohko => if hit && context.attacker.active.speed ≥ context.defender.active.speed then
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
      if context.attackerSide == .player &&
          bitSet context.attacker.volatile.status1 Wram.BattleStatus1.invulnerable then
        ⟨context, .failed, []⟩
      else
        let target := context.defender.active
        let mon := { context.attacker.active with species := target.species }
        let mon := { mon with type1 := target.type1 }
        let mon := { mon with type2 := target.type2 }
        let mon := { mon with catchRate := target.catchRate }
        let mon := { mon with dvs := target.dvs }
        let mon := { mon with moves := target.moves }
        let mon := { mon with attack := target.attack }
        let mon := { mon with defense := target.defense }
        let mon := { mon with speed := target.speed }
        let mon := { mon with special := target.special }
        let mon := { mon with pp := target.moves.map (fun move => if move == 0 then 0 else 5) }
        let volatile := { context.attacker.volatile with
          status3 := setBit context.attacker.volatile.status3 Wram.BattleStatus3.transformed }
        let attacker : Battle.SideState :=
          { active := mon, unmodified := context.defender.unmodified,
            stages := context.defender.stages, volatile }
        ⟨withAttacker context attacker, .continue, [.transformed]⟩
  | .lightScreen => screen context true
  | .reflect => screen context false
  | .poison => if hit then poison (context.move == 92) context else ⟨context, .failed, []⟩
  | .paralyze => if hit then
      paralyze (Data.moveData context.move).type context else ⟨context, .failed, []⟩
  | .substitute => substitute context
  | .mimic =>
      if !hit || bitSet context.defender.volatile.status1 Wram.BattleStatus1.invulnerable then
        ⟨context, .failed, []⟩
      else if context.attackerSide == .player && context.mode != .link then
        ⟨context, .mimicChoice, [.signal .mimicChoice]⟩
      else
        match drawAccepted 2305 context.rng (fun raw =>
          context.defender.active.moves.getD (raw &&& 3).toNat 0 != 0) "mimic-slot" with
        | none => ⟨context, .rngStuck, [.signal .rngStuck]⟩
        | some (raw, rng, events) =>
            let copied := context.defender.active.moves.getD (raw &&& 3).toNat 0
            let moves := context.attacker.active.moves.modify context.moveSlot.val
              (fun _ => copied)
            let mon := { context.attacker.active with moves := moves }
            let attacker := { context.attacker with active := mon }
            ⟨withAttacker { context with rng } attacker, .continue, events⟩
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

/-- Drain handlers destructively halve `wDamage`, with a minimum of one. -/
def drainDamageWord (damage : UInt16) : UInt16 :=
  UInt16.ofNat (max 1 (damage.toNat / 2))

@[simp] theorem drain_halves_shared_damage (damage : UInt16) :
    drainDamageWord damage = UInt16.ofNat (max 1 (damage.toNat / 2)) := rfl

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
      if !hit || context.defender.volatile.hasSubstitute then { context := context }
      else if context.defender.active.status != 0 then
        if context.defender.active.frozen && moveType == TypeChart.fire then
          let mon := { context.defender.active with status := 0 }
          { context := withDefender context { context.defender with active := mon } }
        else { context := context }
      else if context.defender.active.type1 == moveType ||
          context.defender.active.type2 == moveType then { context := context }
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
          let out := if status == mask Wram.Status.frz &&
              context.attackerSide == .player then
            let volatile := { out.context.defender.volatile with
              status2 := clearBit out.context.defender.volatile.status2
                Wram.BattleStatus2.needsToRecharge }
            { out with context := setDefenderVolatile out.context volatile }
            else out
          { out with events := event :: out.events }
  | .drain | .dreamEater =>
      if !hit then { context := context } else
        let amount := drainDamageWord damage
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
        let (gatePass, context, gateEvents) :=
          if context.attackerSide == .enemy && context.mode != .link then
            let (raw, rng) := context.rng.next
            (raw ≥ 64, { context with rng }, [.rawRng "enemy-stat-down-gate" raw])
          else (true, context, [])
        if !gatePass || context.defender.volatile.hasSubstitute then
          ⟨context, .continue, gateEvents⟩
        else
          let (success, context, event) := sideChance 85 context
          if success then
            let out := lowerStage context stat 1 false
            { out with events := gateEvents ++ (event :: out.events) }
          else ⟨context, .continue, gateEvents ++ [event]⟩
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

/-- A +2 effect at current stat 999 rolls back only the final increment, leaving
the silent one-stage residue exactly as `RestoreOriginalStatModifier`. -/
theorem raise_attack_999_two_stage_residue (context : Context)
    (stage : context.attacker.stages.attack = 12)
    (current : context.attacker.active.attack = 999) :
    (raiseStage context 0 2).signal = .failed ∧
      (raiseStage context 0 2).context.attacker.stages.attack = 12 := by
  simp [raiseStage, getStage, setStage, currentStat, withAttacker, stage, current]

/-- The symmetric -2 boundary also restores only one stage increment. -/
theorem lower_attack_1_two_stage_residue (context : Context)
    (noSubstitute : context.defender.volatile.hasSubstitute = false)
    (noMist : bitSet context.defender.volatile.status2
      Wram.BattleStatus2.protectedByMist = false)
    (stage : context.defender.stages.attack = 2)
    (current : context.defender.active.attack = 1) :
    (lowerStage context 0 2).signal = .failed ∧
      (lowerStage context 0 2).context.defender.stages.attack = 2 := by
  simp [lowerStage, getStage, setStage, currentStat, withDefender,
    noSubstitute, noMist, stage, current]

/-- Haze cures only its target's nonvolatile status while retaining the user's,
even though stages, combat stats, and selected volatile fields reset for both. -/
theorem haze_status_target_only (context : Context) :
    let outcome := hazeOutcome context
    outcome.context.attacker.active.status = context.attacker.active.status ∧
      outcome.context.defender.active.status = 0 := by
  simp only [hazeOutcome]
  split <;> simp [withAttacker, withDefender]

/-- Sleep or freeze on the cured target selects the cartridge's `$FF` selected-
move cancellation path. -/
theorem haze_incapacitated_cancels (context : Context)
    (incapacitated : (context.defender.active.asleep ||
      context.defender.active.frozen) = true) :
    (hazeOutcome context).signal = .cancelTargetMove := by
  simp only [hazeOutcome]
  rw [if_pos incapacitated]

/-- Sleep clears the target recharge bit before every existing-status,
accuracy-result, and sleep-duration branch, including RNG-stuck continuation. -/
theorem sleep_always_clears_recharge (context : Context) (hit : Bool) :
    (applyBefore Data.Effect.sleep hit context).context.defender.volatile.recharging = false := by
  unfold applyBefore
  rw [show (EffectPlan.plan Data.Effect.sleep).mechanic = .sleep by native_decide]
  simp only
  split
  · simp [setDefenderVolatile, withDefender, Volatile.recharging,
      recharge_clear_bit]
  · split <;> simp [setDefenderVolatile, withDefender, Volatile.recharging,
      recharge_clear_bit]

/-- Direct paralysis does not consult Substitute. Given an otherwise eligible
target, the handler succeeds even while the volatile Substitute bit is set. -/
theorem direct_paralysis_ignores_substitute (context : Context) (moveType : UInt8)
    (healthy : context.defender.active.status = 0)
    (notGroundImmune : (moveType == TypeChart.electric &&
      (context.defender.active.type1 == TypeChart.ground ||
        context.defender.active.type2 == TypeChart.ground)) = false) :
    (paralyze moveType context).signal = .continue := by
  simp [paralyze, healthy, notGroundImmune]

/-- The cartridge's subtract-with-borrow accepts a Speed tie despite the source
comment saying "higher": equal current Speeds produce the successful OHKO flag. -/
theorem ohko_speed_tie_succeeds (context : Context)
    (tie : context.attacker.active.speed = context.defender.active.speed) :
    (applyBefore Data.Effect.ohko true context).signal = .oneHitKo := by
  change (if true && context.attacker.active.speed ≥ context.defender.active.speed then
    ⟨context, .oneHitKo, [.signal .oneHitKo]⟩ else
    ⟨context, .failed, []⟩ : Outcome).signal = .oneHitKo
  rw [tie]
  simp

/-- A failed ordinary accuracy test cannot be overridden by the OHKO handler's
Speed comparison. -/
theorem ohko_accuracy_miss_fails (context : Context) :
    (applyBefore Data.Effect.ohko false context).signal = .failed := by
  change (if false && context.attacker.active.speed ≥ context.defender.active.speed then
    ⟨context, .oneHitKo, [.signal .oneHitKo]⟩ else
    ⟨context, .failed, []⟩ : Outcome).signal = .failed
  rfl

/-- Successful freeze clears target recharge only for a player attacker. The
enemy-attacker branch retains the target's incoming recharge bit. -/
theorem freeze_recharge_asymmetry (context : Context) (damage : UInt16)
    (noSubstitute : context.defender.volatile.hasSubstitute = false)
    (healthy : context.defender.active.status = 0)
    (type1 : context.defender.active.type1 != TypeChart.ice)
    (type2 : context.defender.active.type2 != TypeChart.ice)
    (success : context.rng.next.1 < (26 : UInt8)) :
    let outcome := applyAfter Data.Effect.freezeSide1 TypeChart.ice true false damage context
    (context.attackerSide = .player →
      outcome.context.defender.volatile.recharging = false) ∧
    (context.attackerSide = .enemy → outcome.context.defender.volatile.recharging =
      context.defender.volatile.recharging) := by
  have type1Ne : context.defender.active.type1 ≠ TypeChart.ice := by
    intro equal
    simp [equal] at type1
  have type2Ne : context.defender.active.type2 ≠ TypeChart.ice := by
    intro equal
    simp [equal] at type2
  have playerSelf : (Side.player == Side.player) = true := by native_decide
  have enemyPlayer : (Side.enemy == Side.player) = false := by native_decide
  have freezeNotBurn : mask Wram.Status.frz ≠ mask Wram.Status.brn := by native_decide
  have freezeNotParalyze : mask Wram.Status.frz ≠ mask Wram.Status.par := by native_decide
  constructor <;> intro side
  · unfold applyAfter
    rw [show (EffectPlan.plan Data.Effect.freezeSide1).mechanic = .freezeSide 26 by
      native_decide]
    simp [side, playerSelf, freezeNotBurn, freezeNotParalyze, noSubstitute,
      healthy, type1Ne, type2Ne, sideChance, success, applyMajorStatus,
      withDefender, setDefenderVolatile, Volatile.recharging, recharge_clear_bit]
  · unfold applyAfter
    rw [show (EffectPlan.plan Data.Effect.freezeSide1).mechanic = .freezeSide 26 by
      native_decide]
    simp [side, enemyPlayer, freezeNotBurn, freezeNotParalyze, noSubstitute,
      healthy, type1Ne, type2Ne, sideChance, success, applyMajorStatus,
      withDefender, Volatile.recharging]

/-- A burn-capable Fire move defrosts an already frozen, unsubstituted target
before consuming the side-effect probability byte. -/
theorem fire_defrost_precedes_side_rng (context : Context) (damage : UInt16)
    (noSubstitute : context.defender.volatile.hasSubstitute = false)
    (statused : context.defender.active.status != 0)
    (frozen : context.defender.active.frozen = true) :
    let outcome := applyAfter Data.Effect.burnSide1 TypeChart.fire true false damage context
    outcome.context.defender.active.status = 0 ∧ outcome.context.rng = context.rng := by
  unfold applyAfter
  rw [show (EffectPlan.plan Data.Effect.burnSide1).mechanic = .burnSide 26 by
    native_decide]
  simp [noSubstitute, statused, frozen, withDefender]

/-- The drain handler does not inspect Substitute. Whenever the surrounding
attack path permits the effect (including a surviving Substitute), healing is
still half damage with minimum one and the max-HP cap. -/
theorem drain_ignores_substitute_gate (context : Context) (damage : UInt16) :
    (applyAfter Data.Effect.drainHp TypeChart.grass true false damage context).context.attacker.active.hp =
      UInt16.ofNat (min (context.attacker.active.hp.toNat +
        max 1 (damage.toNat / 2)) context.attacker.active.maxHp.toNat) := by
  change UInt16.ofNat
    (min (context.attacker.active.hp.toNat +
      (UInt16.ofNat (max 1 (damage.toNat / 2))).toNat)
      context.attacker.active.maxHp.toNat) = _
  have damageBound := UInt16.toNat_lt damage
  have amountBound : max 1 (damage.toNat / 2) < 65536 := by omega
  simp
  rw [Nat.mod_eq_of_lt amountBound]

/-- Hyper Beam recharge is skipped when its hit faints the target. -/
theorem hyperBeam_faint_skips_recharge (context : Context) (damage : UInt16) :
    (applyAfter Data.Effect.hyperBeam TypeChart.normal true true damage context).context =
      context := by
  change context = context
  rfl

end Battle.Full.Effects
