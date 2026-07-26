/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Full.State
import Battle.Data.Species
import Battle.Data.Progression

/-!
# Experience and stat progression

Pure byte/word-width summaries of the arithmetic in `GainExperience`,
`CalcExperience`, and `CalcStats`. Nested move learning and evolution are kept as
explicit requests rather than silently choosing a policy response.
-/

namespace Battle.Full.Progression

inductive GrowthRate where
  | mediumFast | slightlyFast | slightlySlow | mediumSlow | fast | slow
  deriving Repr, DecidableEq, BEq

def GrowthRate.ofId : UInt8 → GrowthRate
  | 0 => .mediumFast
  | 1 => .slightlyFast
  | 2 => .slightlySlow
  | 3 => .mediumSlow
  | 4 => .fast
  | _ => .slow

structure StatExp where
  hp : UInt16
  attack : UInt16
  defense : UInt16
  speed : UInt16
  special : UInt16
  deriving Repr, DecidableEq, BEq

structure PersistentMon where
  battle : MonState
  otId : UInt16
  experience : UInt32
  statExp : StatExp
  deriving Repr, DecidableEq, BEq

structure AwardSource where
  baseHp : UInt8
  baseAttack : UInt8
  baseDefense : UInt8
  baseSpeed : UInt8
  baseSpecial : UInt8
  catchRate : UInt8
  baseExp : UInt8
  level : UInt8
  deriving Repr, DecidableEq, BEq

structure AwardContext where
  playerId : UInt16
  trainerBattle : Bool
  recipients : UInt8
  deriving Repr, DecidableEq, BEq

inductive Request where
  | learnMove (partyIndex : Nat) (move : MoveId)
  | evolution (partyIndex : Nat) (species : SpeciesId)
  deriving Repr, DecidableEq, BEq

structure Result where
  mon : PersistentMon
  expGained : UInt16
  levelsGained : UInt8
  requests : List Request
  deriving Repr, DecidableEq

private def clamp24 (value : Nat) : UInt32 := UInt32.ofNat (min value 0xFFFFFF)

/-- The six four-byte growth rows. Arithmetic is mathematical at levels 1–100;
the final result is retained as the three-byte experience field. -/
def experienceAtLevel (rate : GrowthRate) (level : UInt8) : UInt32 :=
  let n := level.toNat
  let cube := n * n * n
  let square := n * n
  let value := match rate with
    | .mediumFast => cube
    | .slightlyFast => 3 * cube / 4 + 10 * square - 30
    | .slightlySlow => 3 * cube / 4 + 20 * square - 70
    | .mediumSlow => 6 * cube / 5 + 100 * n - (15 * square + 140)
    | .fast => 4 * cube / 5
    | .slow => 5 * cube / 4
  clamp24 value

/-- Highest level whose threshold is at most the supplied three-byte EXP,
capped at the cartridge maximum. -/
def levelFromExperience (rate : GrowthRate) (experience : UInt32) : UInt8 :=
  let levels := (List.range 100).map (fun i => UInt8.ofNat (i + 1))
  levels.foldl (fun current level =>
    if experienceAtLevel rate level ≤ experience then level else current) 1

private def saturatingAdd16 (a : UInt16) (b : UInt8) : UInt16 :=
  UInt16.ofNat (min 0xFFFF (a.toNat + b.toNat))

def divideByte (value recipients : UInt8) : UInt8 :=
  if recipients < 2 then value else UInt8.ofNat (value.toNat / recipients.toNat)

/-- `DivideExpDataByNumMonsGainingExp` destructively divides all five base stats
and base EXP before each recipient uses them. -/
def divideSource (source : AwardSource) (recipients : UInt8) : AwardSource :=
  { source with
    baseHp := divideByte source.baseHp recipients
    baseAttack := divideByte source.baseAttack recipients
    baseDefense := divideByte source.baseDefense recipients
    baseSpeed := divideByte source.baseSpeed recipients
    baseSpecial := divideByte source.baseSpecial recipients
    catchRate := divideByte source.catchRate recipients
    baseExp := divideByte source.baseExp recipients }

def boost (experience : Nat) : Nat := experience + experience / 2

/-- Per-recipient experience amount with traded and trainer boosts applied in
source order, preserving intermediate flooring. -/
def experienceAward (source : AwardSource) (context : AwardContext) (otId : UInt16) : UInt16 :=
  let source := divideSource source context.recipients
  let base := source.baseExp.toNat * source.level.toNat / 7
  let traded := if otId != context.playerId then boost base else base
  let trainer := if context.trainerBattle then boost traded else traded
  UInt16.ofNat trainer

private def floorSqrt (value : Nat) : Nat :=
  (List.range 256).foldl (fun root candidate =>
    if candidate * candidate ≤ value then candidate else root) 0

private def effortTerm (value : UInt16) : Nat := floorSqrt value.toNat / 4

def statFormula (base dv : Nat) (effort : UInt16) (level : UInt8)
    (hp : Bool) : UInt16 :=
  let scaled := ((2 * (base + dv) + effortTerm effort) * level.toNat) / 100
  let value := if hp then scaled + level.toNat + 10 else scaled + 5
  UInt16.ofNat (if hp then value else min value 999)

private def atkDv (dvs : UInt16) : Nat := ((dvs >>> 12).toUInt8 &&& 0x0f).toNat
private def defDv (dvs : UInt16) : Nat := ((dvs >>> 8).toUInt8 &&& 0x0f).toNat
private def spdDv (dvs : UInt16) : Nat := ((dvs >>> 4).toUInt8 &&& 0x0f).toNat
private def spcDv (dvs : UInt16) : Nat := (dvs.toUInt8 &&& 0x0f).toNat
def hpDv (dvs : UInt16) : Nat :=
  ((atkDv dvs &&& 1) <<< 3) ||| ((defDv dvs &&& 1) <<< 2) |||
    ((spdDv dvs &&& 1) <<< 1) ||| (spcDv dvs &&& 1)

@[simp] theorem hp_dv_derivation_witness :
    hpDv 0x1234 = 10 ∧ hpDv 0xFFFF = 15 ∧ hpDv 0 = 0 := by
  native_decide

theorem non_hp_stat_capped (base dv : Nat) (effort : UInt16) (level : UInt8) :
    (statFormula base dv effort level false).toNat ≤ 999 := by
  simp [statFormula]
  omega

/-- Recalculate the five party stats, including HP-DV derivation, effort square
roots, and the 999 non-HP cap. Existing current HP is increased by the Max-HP
delta by `award`. -/
def calculateStats (data : Data.SpeciesData) (mon : MonState) (statExp : StatExp)
    (level : UInt8) : MonState :=
  { mon with
    level
    maxHp := statFormula data.baseHp.toNat (hpDv mon.dvs) statExp.hp level true
    attack := statFormula data.baseAtk.toNat (atkDv mon.dvs) statExp.attack level false
    defense := statFormula data.baseDef.toNat (defDv mon.dvs) statExp.defense level false
    speed := statFormula data.baseSpd.toNat (spdDv mon.dvs) statExp.speed level false
    special := statFormula data.baseSpc.toNat (spcDv mon.dvs) statExp.special level false }

def firstExactLevelMove (moves : Array Data.Progression.LevelMove) (level : UInt8) :
    Option Data.Progression.LevelMove :=
  moves.find? fun entry => entry.level == level

/-- Award one living flagged recipient. Callers perform gain-flag/fainted
filtering and supply the species growth row. -/
def award (rate : GrowthRate) (species : Data.SpeciesData) (source : AwardSource)
    (context : AwardContext) (mon : PersistentMon) (partyIndex : Nat := 0) : Result :=
  let divided := divideSource source context.recipients
  let statExp : StatExp :=
    { hp := saturatingAdd16 mon.statExp.hp divided.baseHp
      attack := saturatingAdd16 mon.statExp.attack divided.baseAttack
      defense := saturatingAdd16 mon.statExp.defense divided.baseDefense
      speed := saturatingAdd16 mon.statExp.speed divided.baseSpeed
      special := saturatingAdd16 mon.statExp.special divided.baseSpecial }
  let gained := experienceAward source context mon.otId
  let cap := experienceAtLevel rate 100
  let experience := min cap (mon.experience + UInt32.ofNat gained.toNat)
  let oldLevel := mon.battle.level
  let newLevel := if oldLevel == 100 then 100 else levelFromExperience rate experience
  let recalculated := calculateStats species mon.battle statExp newLevel
  let hpDelta := recalculated.maxHp - mon.battle.maxHp
  let battle := { recalculated with hp := mon.battle.hp + hpDelta }
  let row := Data.Progression.rows.getD mon.battle.species.toNat { evolutions := #[], levelMoves := #[] }
  let learned := firstExactLevelMove row.levelMoves newLevel
  { mon := { mon with battle, experience, statExp }
    expGained := gained
    levelsGained := newLevel - oldLevel
    requests := if newLevel != oldLevel then
      learned.map (fun entry => [.learnMove partyIndex entry.move]) |>.getD []
      else [] }

theorem divide_source_all_fields (source : AwardSource) (recipients : UInt8) :
    divideSource source recipients =
      { source with
        baseHp := divideByte source.baseHp recipients
        baseAttack := divideByte source.baseAttack recipients
        baseDefense := divideByte source.baseDefense recipients
        baseSpeed := divideByte source.baseSpeed recipients
        baseSpecial := divideByte source.baseSpecial recipients
        catchRate := divideByte source.catchRate recipients
        baseExp := divideByte source.baseExp recipients } := by
  rfl

/-- Experience is capped at the exact level-100 threshold. -/
theorem award_experience_capped (rate : GrowthRate) (species : Data.SpeciesData)
    (source : AwardSource) (context : AwardContext) (mon : PersistentMon)
    (partyIndex : Nat) :
    (award rate species source context mon partyIndex).mon.experience ≤
      experienceAtLevel rate 100 := by
  simp only [award]
  unfold Min.min instMinUInt32 minOfLe
  change (if experienceAtLevel rate 100 ≤
      mon.experience + UInt32.ofNat (experienceAward source context mon.otId).toNat then
    experienceAtLevel rate 100
  else mon.experience + UInt32.ofNat (experienceAward source context mon.otId).toNat) ≤
    experienceAtLevel rate 100
  split
  · rw [UInt32.le_iff_toNat_le]
    omega
  · rename_i notLe
    rw [UInt32.le_iff_toNat_le] at notLe ⊢
    omega

/-- Current HP receives exactly the recalculated Max-HP delta. -/
theorem award_hp_delta (rate : GrowthRate) (species : Data.SpeciesData)
    (source : AwardSource) (context : AwardContext) (mon : PersistentMon)
    (partyIndex : Nat) :
    let result := award rate species source context mon partyIndex
    result.mon.battle.hp = mon.battle.hp +
      (result.mon.battle.maxHp - mon.battle.maxHp) := by
  rfl

/-- Exact-level lookup takes the first physical row and never scans skipped
levels as substitute offers. -/
theorem first_exact_level_move_witness :
    let rows : Array Data.Progression.LevelMove :=
      #[{ level := 5, move := 1 }, { level := 5, move := 2 }, { level := 7, move := 3 }]
    firstExactLevelMove rows 5 = some { level := 5, move := 1 } ∧
    firstExactLevelMove rows 6 = none := by
  native_decide

/-- Each growth curve decodes its own level-100 threshold back to level 100. -/
theorem growth_level_100_roundtrip (rate : GrowthRate) :
    levelFromExperience rate (experienceAtLevel rate 100) = 100 := by
  cases rate <;> native_decide

inductive EvolutionTrigger where
  | afterBattle (aliasedItem : Option UInt8 := none)
  | item (item : UInt8)
  | trade
  deriving Repr, DecidableEq, BEq

private def methodMatches (level : UInt8) (trigger : EvolutionTrigger) :
    Data.Progression.EvolutionMethod → Bool
  | .level required => (match trigger with | .afterBattle _ => true | _ => false) && level ≥ required
  | .item item minimum => (match trigger with
      | .item used => used == item
      | .afterBattle (some used) => used == item
      | _ => false) && level ≥ minimum
  | .trade minimum => trigger == .trade && level ≥ minimum

/-- First matching evolution row, preserving source order. `canEvolve` is the
post-battle participation/level-up flag maintained by the caller. -/
def evolutionTarget? (mon : PersistentMon) (trigger : EvolutionTrigger)
    (canEvolve : Bool := true) : Option SpeciesId :=
  if !canEvolve then none
  else
    let row := Data.Progression.rows.getD mon.battle.species.toNat
      { evolutions := #[], levelMoves := #[] }
    (row.evolutions.find? fun evolution => methodMatches mon.battle.level trigger evolution.method).map
      Data.Progression.Evolution.target

/-- Apply accepted evolution: identity, base types/catch rate and calculated
stats change; current HP receives the Max-HP delta and moves remain intact. -/
def evolve (mon : PersistentMon) (target : SpeciesId) : PersistentMon :=
  let data := Data.speciesData target
  let oldMax := mon.battle.maxHp
  let changed := { mon.battle with
    species := target
    type1 := data.type1
    type2 := data.type2
    catchRate := data.catchRate }
  let battle := calculateStats data changed mon.statExp mon.battle.level
  let battle := { battle with hp := mon.battle.hp + (battle.maxHp - oldMax) }
  { mon with battle }

theorem evolve_preserves_identity_and_moves (mon : PersistentMon) (target : SpeciesId) :
    (evolve mon target).battle.species = target ∧
    (evolve mon target).battle.moves = mon.battle.moves ∧
    (evolve mon target).battle.dvs = mon.battle.dvs ∧
    (evolve mon target).otId = mon.otId ∧
    (evolve mon target).experience = mon.experience ∧
    (evolve mon target).statExp = mon.statExp := by
  simp [evolve, calculateStats]

/-- Medium-fast level 100 is exactly one million EXP. -/
theorem medium_fast_level_100 : experienceAtLevel .mediumFast 100 = 1000000 := by
  native_decide

/-- Sequential 1.5× boosts floor after each stage (`10 → 15 → 22`). -/
theorem sequential_traded_trainer_boosts :
    experienceAward
      ({ baseHp := 1
         baseAttack := 1
         baseDefense := 1
         baseSpeed := 1
         baseSpecial := 1
         catchRate := 45
         baseExp := 70
         level := 1 } : AwardSource)
      ({ playerId := 1
         trainerBattle := true
         recipients := 1 } : AwardContext) 2 = 22 := by
  native_decide

/-- Stat EXP saturates rather than wrapping. -/
theorem stat_exp_saturates : saturatingAdd16 0xffff 1 = 0xffff := by native_decide

end Battle.Full.Progression
