/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Full.Learning

/-!
# Post-battle evolution protocol

Processes flagged party members in slot order. Cancellation advances to the next
member; acceptance updates species/stats and then composes the exact-level move
learning protocol. Wild post-battle item evolution aliasing is explicit.
-/

namespace Battle.Full.Evolution

inductive Event where
  | offered (index : Nat) (oldSpecies newSpecies : SpeciesId)
  | cancelled (index : Nat)
  | evolved (index : Nat) (oldSpecies newSpecies : SpeciesId)
  | learning (index : Nat) (events : List Learning.Event)
  deriving Repr, DecidableEq

inductive Phase where
  | offered (index : Nat) (target : SpeciesId)
  | learning (index : Nat) (machine : Learning.Machine)
  | completed
  deriving Repr, DecidableEq

structure Machine where
  party : Array Progression.PersistentMon
  flags : UInt8
  mode : BattleMode
  aliasedItem : Option UInt8
  cursor : Nat
  phase : Phase
  events : List Event := []
  deriving Repr, DecidableEq

inductive Response where
  | accept | cancel | learning (response : Learning.Response)
  deriving Repr, DecidableEq

private def flagged (flags : UInt8) (index : Nat) : Bool := flags.toNat.testBit index

private def clearFlag (flags : UInt8) (index : Nat) : UInt8 :=
  flags &&& ~~~((1 <<< index).toUInt8)

private def trigger (mode : BattleMode) (aliasedItem : Option UInt8) :
    Progression.EvolutionTrigger :=
  .afterBattle (if mode == .wild then aliasedItem else none)

private def targetAt? (party : Array Progression.PersistentMon) (flags : UInt8)
    (mode : BattleMode) (aliasedItem : Option UInt8) (index : Nat) : Option SpeciesId :=
  if !flagged flags index then none
  else (party[index]?).bind fun mon =>
    Progression.evolutionTarget? mon (trigger mode aliasedItem) true

private def nextOffer? (party : Array Progression.PersistentMon) (flags : UInt8)
    (mode : BattleMode) (aliasedItem : Option UInt8) (cursor : Nat) : Option (Nat × SpeciesId) :=
  (List.range party.size).drop cursor |>.findSome? fun index =>
    (targetAt? party flags mode aliasedItem index).map fun target => (index, target)

private def advance (machine : Machine) : Machine :=
  match nextOffer? machine.party machine.flags machine.mode machine.aliasedItem machine.cursor with
  | none => { machine with phase := .completed }
  | some (index, target) =>
      let oldSpecies := (machine.party[index]?).map (fun mon => mon.battle.species) |>.getD 0
      { machine with
        phase := .offered index target,
        events := machine.events ++ [.offered index oldSpecies target] }

/-- Begin the ordered scan. -/
def start (party : Array Progression.PersistentMon) (flags : UInt8)
    (mode : BattleMode) (aliasedItem : Option UInt8 := none) : Machine :=
  advance { party, flags, mode, aliasedItem, cursor := 0, phase := .completed }

/-- A stale item byte supplied after a wild victory is interpreted exactly as an
item evolution trigger for a flagged party member. -/
theorem wild_item_alias_offers (mon : Progression.PersistentMon) (item : UInt8)
    (target : SpeciesId)
    (eligible : Progression.evolutionTarget? mon (.afterBattle (some item)) true = some target) :
    (start #[mon] 1 .wild (some item)).phase = .offered 0 target := by
  have wildSelf : (BattleMode.wild == BattleMode.wild) = true := by native_decide
  simp [start, advance, nextOffer?, targetAt?, flagged, trigger, wildSelf, eligible]

private def aliasedEvolutionWitness : Progression.PersistentMon :=
  { battle :=
      { species := 4, hp := 1, boxLevel := 1, status := 0, type1 := 0, type2 := 0,
        catchRate := 0, moves := #[0, 0, 0, 0], dvs := 0, level := 1, maxHp := 1,
        attack := 1, defense := 1, speed := 1, special := 1, pp := #[0, 0, 0, 0] }
    otId := 0
    experience := 0
    statExp := { hp := 0, attack := 0, defense := 0, speed := 0, special := 0 } }

/-- Concrete item `$0A` alias: flagged internal species `$04` is offered target
`$8E` after a wild battle even though no evolution item was intentionally used. -/
theorem wild_item_evolution_bug_occurs :
    (start #[aliasedEvolutionWitness] 1 .wild (some 10)).phase = .offered 0 142 := by
  native_decide

private def exactLevelMove? (species : SpeciesId) (level : UInt8) : Option MoveId :=
  let row := Data.Progression.rows.getD species.toNat { evolutions := #[], levelMoves := #[] }
  (row.levelMoves.find? fun entry => entry.level == level).map Data.Progression.LevelMove.move

private def finishAccepted (machine : Machine) (index : Nat)
    (evolved : Progression.PersistentMon) : Machine :=
  match exactLevelMove? evolved.battle.species evolved.battle.level with
  | none =>
      let updatedParty := machine.party.modify index (fun _ => evolved)
      advance { machine with
        party := updatedParty,
        flags := clearFlag machine.flags index,
        cursor := index + 1 }
  | some move =>
      let learning := Learning.start evolved move
      match learning.phase with
      | .completed _ =>
          let updatedParty := machine.party.modify index (fun _ => learning.mon)
          advance { machine with
            party := updatedParty,
            flags := clearFlag machine.flags index,
            cursor := index + 1,
            events := machine.events ++ [Event.learning index learning.events] }
      | _ => { machine with phase := .learning index learning }

/-- Consume an evolution or nested learning response. -/
def respond (machine : Machine) (response : Response) : Option Machine :=
  match machine.phase, response with
  | .completed, _ => none
  | .offered index _, .cancel =>
      some <| advance { machine with
        flags := clearFlag machine.flags index,
        cursor := index + 1,
        events := machine.events ++ [.cancelled index] }
  | .offered index target, .accept =>
      match machine.party[index]? with
      | none => none
      | some mon =>
          let evolved := Progression.evolve mon target
          let machine := { machine with events := machine.events ++
            [.evolved index mon.battle.species target] }
          some (finishAccepted machine index evolved)
  | .learning index learning, .learning response =>
      match Learning.respond learning response with
      | none => none
      | some learning =>
          let machine := { machine with events := machine.events ++
            [Event.learning index learning.events] }
          match learning.phase with
          | .completed _ =>
              let updatedParty := machine.party.modify index (fun _ => learning.mon)
              some <| advance { machine with
                party := updatedParty,
                flags := clearFlag machine.flags index,
                cursor := index + 1 }
          | _ => some { machine with phase := .learning index learning }
  | _, _ => none

end Battle.Full.Evolution
