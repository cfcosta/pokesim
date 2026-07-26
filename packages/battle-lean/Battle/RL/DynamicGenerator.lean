/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.RL.MoveHistory
import Battle.Data.MinimumLevels

/-!
# Total progression-witnessed legal-team generator

The sampler no longer chooses an unordered subset of a species' unioned learn
pool. Each mon starts with the exact moves `WriteMonMoves` gives it at level 100,
then replays compatible machine teachings and PP Ups. One shared caller-supplied
ledger enforces one-use TM copies across the party, reusable owned HMs, and a
finite PP Up budget.

Species are sampled across all 151 real entries. Each level is sampled from the
ROM-derived minimum obtainable level through 100. Species unavailable through
normal Red acquisition use the explicit policy fallback level 5. Eligible
level/item stages usually evolve (8/10 roll residues); trade stages usually
retain the pre-trade species (6/10), preserving Kadabra over Alakazam more often.

Every `Sample` carries two independent proofs:

* `team` proves the resulting battle rows satisfy canonical learnset legality;
* `historyReplays` proves the ordered origins/events reconstruct exactly that
  team and final resource ledger.

The defensive repair branch remains fail-closed. It now returns a replayable
natural Rhydon rather than an arbitrary learn-pool prefix.
-/

namespace Battle.RL.DynamicGenerator

open Battle.RL
open Battle.RL.MoveHistory

/-- A team accepted by the canonical Gen-1 learnset predicate. Stronger ordered
reachability is carried separately by `Sample.historyReplays`. -/
abbrev CanonicalTeam := { team : Team // teamLegal genDex .canonical team = true }

structure Sample where
  team : CanonicalTeam
  rng : Rng.LinkRng
  repaired : Bool
  history : TeamHistory
  remainingLedger : ResourceLedger
  historyReplays : replayTeam history = some (team.1, remainingLedger)

/-- Rotate a nonempty array by `start`. Retained as a distribution helper for
the restricted ordinary profile; legality must come from a replayed history. -/
def rotatePool {α : Type} [Inhabited α] (pool : Array α) (start : Nat) : Array α :=
  if pool.isEmpty then pool
  else (Array.range pool.size).map fun index =>
    pool.getD ((start + index) % pool.size) default

/-- Draw one byte and thread the link RNG. -/
@[inline] def draw (rng : Rng.LinkRng) : UInt8 × Rng.LinkRng := rng.next

private def machineCandidates (species : SpeciesId) (ledger : ResourceLedger) :
    Array MachineIndex :=
  (Array.range 55).filterMap fun index =>
    if bounded : index < 55 then
      let machine : MachineIndex := ⟨index, bounded⟩
      if Data.Progression.machineCompatible species index &&
          machineAvailable ledger machine then some machine else none
    else none

private def rotatedCandidates (species : SpeciesId) (ledger : ResourceLedger)
    (start : Nat) : Array MachineIndex :=
  let candidates := machineCandidates species ledger
  if candidates.isEmpty then #[]
  else (Array.range candidates.size).map fun index =>
    candidates.getD ((start + index) % candidates.size) ⟨0, by omega⟩

private def applyMachineCandidates (remaining : Nat) (replacementBits : UInt8)
    (candidates : List MachineIndex) (state : MonState × ResourceLedger × List Event) :
    MonState × ResourceLedger × List Event :=
  match remaining, candidates with
  | 0, _ | _, [] => state
  | count + 1, machine :: tail =>
      let used := state.2.2.length
      let slotValue := (replacementBits.toNat >>> (2 * (used % 4))) % 4
      let slot : Fin 4 := ⟨slotValue, by omega⟩
      match teach state.1 state.2.1 machine slot with
      | none => applyMachineCandidates (count + 1) replacementBits tail state
      | some (mon, ledger) =>
          applyMachineCandidates count replacementBits tail
            (mon, ledger, state.2.2 ++ [.teach machine slot])

private def applyPpUps : Nat → Fin 4 →
    MonState × ResourceLedger × List Event → MonState × ResourceLedger × List Event
  | 0, _, state => state
  | count + 1, slot, state =>
      match usePpUp state.1 state.2.1 slot with
      | none => state
      | some (mon, ledger) =>
          applyPpUps count slot (mon, ledger, state.2.2 ++ [.ppUp slot])

private def applyPpPattern (pattern : UInt8)
    (state : MonState × ResourceLedger × List Event) :
    MonState × ResourceLedger × List Event :=
  (List.range 4).foldl (fun state index =>
    if bounded : index < 4 then
      let slot : Fin 4 := ⟨index, bounded⟩
      let count := (pattern.toNat >>> (2 * index)) &&& 3
      applyPpUps count slot state
    else state) state

/-- Map one entropy byte onto the inclusive generation interval
`[generationFloor species, 100]`. Modulo reduction retains the explicit bias
when the interval width does not divide 256. -/
def sampledLevel (species : SpeciesId) (raw : UInt8) : UInt8 :=
  let floor := Data.MinimumLevels.generationFloor species
  let width := 101 - floor.toNat
  (floor.toNat + raw.toNat % width).toUInt8

/-- Every sampled level respects the species floor and never exceeds 100. -/
theorem sampledLevel_bounds (species : SpeciesId) (raw : UInt8) :
    (Data.MinimumLevels.generationFloor species).toNat ≤ (sampledLevel species raw).toNat ∧
      (sampledLevel species raw).toNat ≤ 100 := by
  have checked : (List.range 256).all (fun speciesValue =>
      (List.range 256).all (fun rawValue =>
        (Data.MinimumLevels.generationFloor speciesValue.toUInt8).toNat ≤
            (sampledLevel speciesValue.toUInt8 rawValue.toUInt8).toNat &&
          (sampledLevel speciesValue.toUInt8 rawValue.toUInt8).toNat ≤ 100)) = true := by
    native_decide
  have speciesItem := (List.all_eq_true.mp checked) species.toNat
    (List.mem_range.mpr species.toNat_lt)
  have rawItem := (List.all_eq_true.mp speciesItem) raw.toNat
    (List.mem_range.mpr raw.toNat_lt)
  have round (value : UInt8) : value.toNat.toUInt8 = value := by
    apply UInt8.toNat.inj
    simp
  simpa only [Bool.and_eq_true, decide_eq_true_eq, round] using rawItem

/-- Executable support check: for every internal species byte, every level from
its generation floor through 100 is produced by at least one entropy byte. -/
def everyAdmissibleLevelSampled : Bool :=
  (List.range 256).all fun speciesValue =>
    let species := speciesValue.toUInt8
    let floor := Data.MinimumLevels.generationFloor species
    (List.range (101 - floor.toNat)).all fun delta =>
      (List.range 256).any fun rawValue =>
        sampledLevel species rawValue.toUInt8 == (floor.toNat + delta).toUInt8

/-- The one-byte level map has full support over every declared interval. -/
theorem every_admissible_level_sampled : everyAdmissibleLevelSampled = true := by
  native_decide

/-- An evolution is available only when its encoded minimum level has been
reached. Item and trade records retain their cartridge minimum-level fields. -/
def evolutionEligible (level : UInt8) (evolution : Data.Progression.Evolution) : Bool :=
  match evolution.method with
  | .level required => required ≤ level
  | .item _ minimum => minimum ≤ level
  | .trade minimum => minimum ≤ level

/-- Canonical eligible outgoing edges for one species and sampled level. -/
def eligibleEvolutions (species : SpeciesId) (level : UInt8) :
    Array Data.Progression.Evolution :=
  let row := Data.Progression.rows.getD species.toNat
    { evolutions := #[], levelMoves := #[] }
  row.evolutions.filter (evolutionEligible level)

/-- Ordinary level/item evolution accepts residues `0..7` (8 in 10). Trade
 evolution accepts `0..3`, so residues `4..9` retain the pre-trade species
(6 in 10), making Kadabra more likely than Alakazam after Abra evolves. -/
def evolutionRollAccepts (method : Data.Progression.EvolutionMethod) (roll : UInt8) : Bool :=
  match method with
  | .trade _ => roll.toNat % 10 < 4
  | _ => roll.toNat % 10 < 8

/-- Choose one eligible branch, then apply the method-specific evolution roll. -/
def evolveOnce (species : SpeciesId) (level decision branch : UInt8) : Option SpeciesId :=
  let eligible := eligibleEvolutions species level
  match eligible[branch.toNat % eligible.size]? with
  | none => none
  | some evolution =>
      if evolutionRollAccepts evolution.method decision then some evolution.target else none

/-- Gen-I has at most two successive evolution edges. A failed edge stops rather
than receiving another roll; a successful first edge receives an independent
second-stage decision and branch byte. -/
def promoteSpecies (species : SpeciesId) (level : UInt8)
    (firstDecision firstBranch secondDecision secondBranch : UInt8) : SpeciesId :=
  match evolveOnce species level firstDecision firstBranch with
  | none => species
  | some first => (evolveOnce first level secondDecision secondBranch).getD first

/-- Closed graph check that no canonical Gen-I evolution path needs a third
edge, justifying the two explicit stages in `promoteSpecies`. -/
def evolutionDepthAtMostTwo : Bool :=
  Data.Progression.rows.all fun row =>
    row.evolutions.all fun first =>
      let firstRow := Data.Progression.rows.getD first.target.toNat
        { evolutions := #[], levelMoves := #[] }
      firstRow.evolutions.all fun second =>
        let secondRow := Data.Progression.rows.getD second.target.toNat
          { evolutions := #[], levelMoves := #[] }
        secondRow.evolutions.isEmpty

@[simp] theorem evolution_depth_at_most_two : evolutionDepthAtMostTwo = true := by
  native_decide

/-- Every eligible canonical edge preserves the generation-floor invariant:
once the source floor has been reached, an accepted target is also valid at that
same level. -/
def evolutionEdgesRespectFloors : Bool :=
  (List.range 256).all fun speciesValue =>
    let species := speciesValue.toUInt8
    let row := Data.Progression.rows.getD species.toNat
      { evolutions := #[], levelMoves := #[] }
    row.evolutions.all fun evolution =>
      (List.range 101).all fun levelValue =>
        let level := levelValue.toUInt8
        !(Data.MinimumLevels.generationFloor species ≤ level &&
            evolutionEligible level evolution) ||
          Data.MinimumLevels.generationFloor evolution.target ≤ level

@[simp] theorem evolution_edges_respect_floors : evolutionEdgesRespectFloors = true := by
  native_decide

/-- Byte-level weighting retains modulo bias explicitly: ordinary methods evolve
for 206/256 byte values; trade methods evolve for 104/256 and retain for 152/256. -/
def ordinaryEvolutionAcceptCount : Nat :=
  (List.range 256).countP fun value => evolutionRollAccepts (.level 1) value.toUInt8

def tradeEvolutionAcceptCount : Nat :=
  (List.range 256).countP fun value => evolutionRollAccepts (.trade 1) value.toUInt8

@[simp] theorem evolution_roll_cardinalities :
    ordinaryEvolutionAcceptCount = 206 ∧ tradeEvolutionAcceptCount = 104 ∧
      256 - tradeEvolutionAcceptCount = 152 := by
  native_decide

/-- At level 100, an Abra roll can remain Abra, stop at Kadabra after rejecting
trade evolution, or reach Alakazam. Below level 16 it cannot become Kadabra. -/
@[simp] theorem abra_evolution_weighting_examples :
    promoteSpecies 0x94 100 8 0 0 0 = 0x94 ∧
    promoteSpecies 0x94 100 0 0 6 0 = 0x26 ∧
    promoteSpecies 0x94 100 0 0 0 0 = 0x95 ∧
    evolveOnce 0x94 15 0 0 = none := by
  native_decide

/-- Fourteen fixed draws select species, level, two evolution decisions/branches,
four DVs, machine count/order/replacement slots, and per-slot PP Up counts.
Acquisition replays exact `WriteMonMoves` for the promoted species at the sampled
level before machine teachings and PP Ups. -/
def sampleMon (ledger : ResourceLedger) (rng : Rng.LinkRng) :
    MonPlan × MonState × ResourceLedger × Rng.LinkRng :=
  let (speciesByte, rng) := draw rng
  let (levelByte, rng) := draw rng
  let (firstEvolutionDecision, rng) := draw rng
  let (firstEvolutionBranch, rng) := draw rng
  let (secondEvolutionDecision, rng) := draw rng
  let (secondEvolutionBranch, rng) := draw rng
  let (atkByte, rng) := draw rng
  let (defByte, rng) := draw rng
  let (spdByte, rng) := draw rng
  let (spcByte, rng) := draw rng
  let (machineCountByte, rng) := draw rng
  let (machineStartByte, rng) := draw rng
  let (replacementBits, rng) := draw rng
  let (ppPattern, rng) := draw rng
  let entry := entryOf speciesByte.toNat
  let level := sampledLevel entry.speciesId levelByte
  let species := promoteSpecies entry.speciesId level
    firstEvolutionDecision firstEvolutionBranch secondEvolutionDecision secondEvolutionBranch
  let origin : Origin :=
    { species, level
      atkDv := atkByte, defDv := defByte, spdDv := spdByte, spcDv := spcByte }
  let mon := acquire origin
  let candidates := rotatedCandidates origin.species ledger machineStartByte.toNat
  let machineCount := machineCountByte.toNat % (Wram.numMoves + 1)
  let state := applyMachineCandidates machineCount replacementBits candidates.toList
    (mon, ledger, [])
  let state := applyPpPattern ppPattern state
  ({ origin, events := state.2.2 }, state.1, state.2.1, rng)

private def sampleMons : Nat → ResourceLedger → Rng.LinkRng →
    Array MonPlan × Team × ResourceLedger × Rng.LinkRng
  | 0, ledger, rng => (#[], #[], ledger, rng)
  | count + 1, ledger, rng =>
      let (plan, mon, ledger, rng) := sampleMon ledger rng
      let (plans, mons, ledger, rng) := sampleMons count ledger rng
      (#[plan] ++ plans, #[mon] ++ mons, ledger, rng)

private def fallbackOrigin : Origin :=
  { species := (entryOf 0).speciesId, level := 100
    atkDv := 15, defDv := 15, spdDv := 15, spcDv := 15 }

private def fallbackPlan : MonPlan := { origin := fallbackOrigin, events := [] }
private def fallbackTeam : Team := #[acquire fallbackOrigin]

private theorem fallbackTeam_legal :
    teamLegal genDex .canonical fallbackTeam = true := by
  native_decide

private theorem fallback_replays (ledger : ResourceLedger) :
    replayTeam { initialLedger := ledger, plans := #[fallbackPlan] } =
      some (fallbackTeam, ledger) := by
  rfl

private def fallbackSample (ledger : ResourceLedger) (rng : Rng.LinkRng) : Sample :=
  { team := ⟨fallbackTeam, fallbackTeam_legal⟩
    rng
    repaired := true
    history := { initialLedger := ledger, plans := #[fallbackPlan] }
    remainingLedger := ledger
    historyReplays := fallback_replays ledger }

/-- Generate a requested-size party under an explicit shared resource budget.
The size is clamped to `1..PARTY_LENGTH`. -/
def sampleSizedWithLedger (requested : Nat) (ledger : ResourceLedger)
    (rng : Rng.LinkRng) : Sample :=
  let count := max 1 (min maxPartySize requested)
  let (plans, candidate, remaining, rng) := sampleMons count ledger rng
  let history : TeamHistory := { initialLedger := ledger, plans }
  if replayed : replayTeam history = some (candidate, remaining) then
    if legal : teamLegal genDex .canonical candidate = true then
      { team := ⟨candidate, legal⟩, rng, repaired := false, history
        remainingLedger := remaining, historyReplays := replayed }
    else fallbackSample ledger rng
  else fallbackSample ledger rng

/-- Default RL budget: one copy of each TM, all five HMs, and eighteen PP Ups.
This is explicit distribution policy, not a new-game inventory claim. -/
def defaultLedger : ResourceLedger := ResourceLedger.oneEach 18

def sampleSized (requested : Nat) (rng : Rng.LinkRng) : Sample :=
  sampleSizedWithLedger requested defaultLedger rng

/-- Fully dynamic party generation: the first byte chooses size 1–6 and the
remaining cursor chooses the progression-witnessed team. -/
def sample (rng : Rng.LinkRng) : Sample :=
  let (sizeByte, rng) := draw rng
  sampleSized (sizeByte.toNat % maxPartySize + 1) rng

/-- Every result remains learnset-legal, independently of entropy and repair. -/
theorem sample_sound (rng : Rng.LinkRng) :
    teamLegal genDex .canonical (sample rng).team.1 = true :=
  (sample rng).team.2

theorem sampleSized_sound (requested : Nat) (rng : Rng.LinkRng) :
    teamLegal genDex .canonical (sampleSized requested rng).team.1 = true :=
  (sampleSized requested rng).team.2

/-- Stronger constructive certificate: replaying all origins and ordered events
under the supplied party-wide ledger yields exactly the sampled team and final
resource state. -/
theorem sampleSized_progression_witnessed (requested : Nat) (ledger : ResourceLedger)
    (rng : Rng.LinkRng) :
    replayTeam (sampleSizedWithLedger requested ledger rng).history =
      some ((sampleSizedWithLedger requested ledger rng).team.1,
        (sampleSizedWithLedger requested ledger rng).remainingLedger) :=
  (sampleSizedWithLedger requested ledger rng).historyReplays

/-! ## Deterministic sampling guards -/

private def sample0 : Sample := sample Rng.seed0

#guard sample0.team.1.size == 1
#guard sample0.repaired == false
#guard teamLegal genDex .canonical sample0.team.1
#guard (sampleSized 0 Rng.seed0).team.1.size == 1
#guard (sampleSized 99 Rng.seed0).team.1.size == maxPartySize
#guard !(sampleSized 6 Rng.seed0).repaired
#guard (sampleSized 6 Rng.seed0).team.1.all (monLegal genDex .canonical)
#guard (sampleSized 6 Rng.seed0).history.plans.size == 6

end Battle.RL.DynamicGenerator
