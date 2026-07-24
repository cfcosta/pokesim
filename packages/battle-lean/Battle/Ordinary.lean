/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Step
import Battle.Resolve
import Battle.Data.Species

/-!
# Faithful ordinary damaging-turn kernel

This is the executable kernel used by the first honest self-play profile. Its
scope is explicit: fresh active mons, neutral stages, and moves with nonzero
power plus `NO_ADDITIONAL_EFFECT`. Within that scope it follows the cartridge's
observable order exactly:

1. Quick Attack / Counter / Speed / Speed-tie `BattleRandom` order;
2. PP decrement when an actor actually starts its move;
3. critical draw using base Speed and the high-critical table;
4. base damage, STAB, and ordered dual-type adjustment;
5. repeated `BattleRandom`, `rrca`, reject `< 217`, then `/255` damage scaling;
6. the 1/256-capable accuracy draw;
7. HP subtraction and immediate faint interruption.

Unsupported effects and empty/zero-PP slots are rejected rather than silently
approximated. The bounded damage-roll search has an explicit `rngStuck` result;
it is not interpreted as a miss or as normal termination. `regen_accepts_within`
proves the per-byte recurrence reaches the accepted set within 24 appearances,
and 210 draws cover 24 appearances of every one of the nine live link-RNG bytes.
-/

namespace Battle.Ordinary

/-! ## Scope predicate and critical threshold -/

/-- The first self-play profile admits exactly ordinary nonzero-power rows. -/
def supportedMove (id : MoveId) : Bool :=
  let data := Data.moveData id
  id != 0 && data.power != 0 && data.effect == Data.Effect.noAdditional

/-- Gen-1's hardcoded high-critical move list. -/
def highCriticalMove (id : MoveId) : Bool :=
  id == 2 || id == 75 || id == 152 || id == 163

/-- Fresh-state critical threshold from base Speed. Regular moves use
`floor(baseSpeed/2)`; high-critical moves multiply that by eight and cap at 255. -/
def criticalThreshold (species : SpeciesId) (move : MoveId) : UInt8 :=
  let half := (Data.speciesData species).baseSpd.toNat / 2
  (if highCriticalMove move then min 255 (half * 8) else half).toUInt8

#guard criticalThreshold 153 33 == 22  -- Bulbasaur base Speed 45, Tackle
#guard criticalThreshold 153 75 == 176 -- Razor Leaf: floor(45/2) × 8
#guard criticalThreshold 84 163 == 255 -- capped high-critical Slash

/-! ## Exact damage randomisation -/

/-- The `rrca` performed on every raw damage-random byte. -/
def rotateRight (value : UInt8) : UInt8 :=
  (value >>> 1) ||| (value <<< 7)

/-- Accepted random-damage factor after rotation. -/
def damageFactorAccepted (raw : UInt8) : Bool := 217 ≤ (rotateRight raw).toNat

/-- Iterate the list-regeneration recurrence on one byte. -/
def iterateRegen : Nat → UInt8 → UInt8
  | 0, value => value
  | count + 1, value => iterateRegen count (Rng.regenStep value)

/-- Every possible list byte reaches the accepted damage-factor set within 24
appearances. This is universal over all 256 byte values, not a seed fixture. -/
theorem regen_accepts_within (value : UInt8) :
    (List.range 24).any (fun count =>
      damageFactorAccepted (iterateRegen count value)) = true := by
  have checked :
      (List.range 256).all (fun raw =>
        (List.range 24).any (fun count =>
          damageFactorAccepted (iterateRegen count raw.toUInt8))) = true := by
    native_decide
  have atValue := (List.all_eq_true.mp checked) value.toNat
    (List.mem_range.mpr (UInt8.toNat_lt value))
  simpa using atValue

/-- Nine live bytes, each requiring at most 24 appearances; one extra draw covers
an initial cursor at the vestigial slot admitted by `LinkRng.wf`. -/
def damageDrawBound : Nat := 24 * Wram.rnsConsumed + 1

/-- Trace event for the restricted kernel. Raw RNG observations remain visible so
replay can compare consumption rather than only final damage. -/
inductive Event where
  | checkpoint (event : Step.TurnEvent)
  | rng (site : String) (raw : UInt8)
  | damageFactor (factor : UInt8)
  deriving Repr, DecidableEq, BEq

private def drawDamageFactorAux : Nat → Rng.LinkRng →
    Option (UInt8 × Rng.LinkRng × List Event)
  | 0, _ => none
  | remaining + 1, rng =>
      let (raw, rng') := rng.next
      let observed := Event.rng "damage" raw
      let factor := rotateRight raw
      if 217 ≤ factor.toNat then
        some (factor, rng', [observed, .damageFactor factor])
      else
        match drawDamageFactorAux remaining rng' with
        | none => none
        | some (factor, rng'', events) => some (factor, rng'', observed :: events)

/-- Draw the cartridge's accepted `[217,255]` factor or expose a stuck RNG
profile outcome. Rejected bytes are retained in the event list. -/
def drawDamageFactor (rng : Rng.LinkRng) :
    Option (UInt8 × Rng.LinkRng × List Event) :=
  drawDamageFactorAux damageDrawBound rng

/-! ## Active-state helpers -/

private def moveAt (mon : MonState) (slot : Fin 4) : MoveId :=
  mon.moves.getD slot.val 0

private def ppAt (mon : MonState) (slot : Fin 4) : UInt8 :=
  mon.pp.getD slot.val 0

/-- Current PP ignores the two PP-Up bits. -/
def currentPp (packed : UInt8) : UInt8 := packed &&& Wram.ppMask

/-- Decrement current PP while preserving PP-Up bits. -/
def decrementPackedPp (packed : UInt8) : UInt8 :=
  let current := currentPp packed
  if current == 0 then packed
  else (packed &&& Wram.ppUpMask) ||| (current - 1)

private def decrementSlot (mon : MonState) (slot : Fin 4) : MonState :=
  { mon with pp := mon.pp.modify slot.val decrementPackedPp }

private def replaceActive (state : BattleState) (side : Side) (mon : MonState) : BattleState :=
  let old := state.side side
  state.setSide side { old with active := mon }

private def decrementActivePp (state : BattleState) (side : Side) (slot : Fin 4) : BattleState :=
  replaceActive state side (decrementSlot (state.active side) slot)

/-- A fight slot is legal in the restricted profile exactly when it contains a
supported move with nonzero current PP. -/
def legalFightSlot (state : BattleState) (side : Side) (slot : Fin 4) : Bool :=
  let mon := state.active side
  supportedMove (moveAt mon slot) && currentPp (ppAt mon slot) != 0

/-! ## One attack and one turn -/

inductive AttackResult where
  | complete (state : BattleState) (events : List Event)
      (terminal : Option Outcome.BattleTerminal)
  | rngStuck (state : BattleState) (events : List Event)
  deriving Repr

inductive TurnResult where
  | complete (state : BattleState) (events : List Event)
  | invalidAction (state : BattleState)
  | rngStuck (state : BattleState) (events : List Event)
  deriving Repr

private def resolveAttack (state : BattleState) (attacker : Side) (slot : Fin 4) :
    AttackResult :=
  let defender := attacker.other
  let state := decrementActivePp state attacker slot
  let attackerMon := state.active attacker
  let defenderSide := state.side defender
  let defenderMon := defenderSide.active
  let moveId := moveAt attackerMon slot
  let move := resolveMove moveId
  let (critRaw, rngAfterCrit) := state.rng.next
  let threshold := criticalThreshold attackerMon.species moveId
  let critical := Step.critHits threshold critRaw
  let base := Damage.calcBaseDamage attackerMon.level critical move.power
    attackerMon.attack defenderMon.defense
  let typed := Damage.adjustDamageForType move.type attackerMon.type1 attackerMon.type2
    defenderMon.type1 defenderMon.type2 base
  let initialEvents :=
    [.checkpoint (.attackStart attacker moveId), .rng "critical" critRaw] ++
      if critical then [.checkpoint (.critical attacker)] else []
  let randomized :=
    if typed < 2 then some (typed, rngAfterCrit, [])
    else match drawDamageFactor rngAfterCrit with
      | none => none
      | some (factor, rng, events) => some (Damage.randomizeDamage factor typed, rng, events)
  match randomized with
  | none => .rngStuck { state with rng := rngAfterCrit } initialEvents
  | some (damage, rngAfterDamage, damageEvents) =>
      let (accuracyRaw, rngAfterAccuracy) := rngAfterDamage.next
      let hitByAccuracy := accuracyRaw < move.accuracy
      let hit := hitByAccuracy && damage != 0
      let dealt := if hit then damage else 0
      let hpAfter := Step.saturatingSub defenderMon.hp dealt
      let updatedDefender := { defenderMon with hp := hpAfter }
      let state := replaceActive { state with rng := rngAfterAccuracy }
        defender updatedDefender
      let fainted := hpAfter == 0
      let events := initialEvents ++ damageEvents ++ [.rng "accuracy" accuracyRaw] ++
        (if hit then [.checkpoint (.damageDealt attacker dealt hpAfter)]
         else [.checkpoint (.missed attacker)]) ++
        (if fainted then [.checkpoint (.fainted defender)] else [])
      let terminal :=
        if fainted then
          some (Outcome.BattleTerminal.mk' (.partyExhausted defender) state.mode .player
            (if defender == .enemy then 0 else 1))
        else none
      .complete state events terminal

/-- Resolve one restricted fight-vs-fight turn. No unsupported action is coerced
into another move, and an exhausted damage RNG remains distinguishable. -/
def resolveTurn (playerSlot enemySlot : Fin 4) (state : BattleState) : TurnResult :=
  if !legalFightSlot state .player playerSlot || !legalFightSlot state .enemy enemySlot then
    .invalidAction state
  else
    let playerMove := resolveMove (moveAt (state.active .player) playerSlot)
    let enemyMove := resolveMove (moveAt (state.active .enemy) enemySlot)
    let (first, viaTie, rng) := Step.turnOrder playerMove.priority enemyMove.priority
      (state.active .player).speed (state.active .enemy).speed state.rng
    let orderEvents :=
      (if viaTie then [.rng "speed-tie" state.rng.next.1] else []) ++
        [.checkpoint (.orderDecided first viaTie)]
    let state := { state with rng }
    let slotOf := fun side => if side == .player then playerSlot else enemySlot
    match resolveAttack state first (slotOf first) with
    | .rngStuck state events => .rngStuck state (orderEvents ++ events)
    | .complete state events (some terminal) =>
        .complete { state with phase := .ending terminal }
          (orderEvents ++ events ++ [.checkpoint (.terminalReached terminal.cause terminal.verdict)])
    | .complete state firstEvents none =>
        let second := first.other
        match resolveAttack state second (slotOf second) with
        | .rngStuck state events => .rngStuck state (orderEvents ++ firstEvents ++ events)
        | .complete state events terminal =>
            let state := { state with turn := state.turn + 1 }
            match terminal with
            | none => .complete state (orderEvents ++ firstEvents ++ events)
            | some terminal =>
                .complete { state with phase := .ending terminal }
                  (orderEvents ++ firstEvents ++ events ++
                    [.checkpoint (.terminalReached terminal.cause terminal.verdict)])

/-! ## Fidelity guards -/

#guard supportedMove 33                    -- Tackle
#guard supportedMove 98                    -- Quick Attack
#guard !supportedMove 52                   -- Ember has a burn side effect
#guard !supportedMove 0
#guard rotateRight 0xB3 == 0xD9            -- 179 → 217, first accepted raw byte
#guard damageFactorAccepted 0xB3
#guard !damageFactorAccepted 0xB1
#guard decrementPackedPp 0x9F == 0x9E      -- preserve two PP Ups, 31 → 30
#guard decrementPackedPp 0x80 == 0x80      -- zero current PP does not underflow

end Battle.Ordinary
