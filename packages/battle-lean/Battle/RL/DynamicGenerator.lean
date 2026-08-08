/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.RL.MoveHistory
import Battle.RL.PopularTeams
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
normal Red acquisition use the explicit policy fallback level 5. The legacy
profile applies weighted evolution promotion: eligible level/item stages usually
evolve (8/10 roll residues), while trade stages usually retain the pre-trade
species (6/10). The balanced-final profile instead maps two fixed bytes directly
onto all 151 displayed species with 434-or-435-word fibers and skips that family
funnel. Both profiles consume the same entropy shape.

Every `Sample` carries two independent proofs:

* `team` proves the resulting battle rows satisfy canonical learnset legality;
* `historyReplays` proves ordered origins/events or an explicitly marked
  competitive preset reconstruct exactly that team and final resource ledger.

The defensive repair branch remains fail-closed. It returns a replayable natural
Rattata rather than an arbitrary learn-pool prefix; the species is chosen for its
floor-2 generation level, which fits inside any battle level band.
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
  popular : Bool := false
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

/-- An inclusive level interval shared by every mon in one generated battle.
`free` and `level100` recover the two policies that predate banding, so the band
is the single level policy rather than a third one bolted alongside. -/
structure LevelBand where
  /-- Lowest level the band admits, before a species floor lifts it. -/
  low : UInt8
  /-- Highest level the band admits. -/
  high : UInt8
deriving Repr, DecidableEq, BEq

namespace LevelBand

/-- The unbanded policy: each mon spans its own floor through 100. -/
def free : LevelBand := ⟨0, 100⟩

/-- The competitive policy: every mon is level 100. -/
def level100 : LevelBand := ⟨100, 100⟩

end LevelBand

/-- Map one entropy byte onto a band, lifting it past the species' generation
floor when the floor sits above the band. The lift keeps the function total for
bands a species cannot honour; `battleLevelBand` chooses bands no drawn species
needs lifting out of, which is what makes the spread bound exact. -/
def bandedLevel (band : LevelBand) (species : SpeciesId) (raw : UInt8) : UInt8 :=
  let floor := (Data.MinimumLevels.generationFloor species).toNat
  let low := min 100 (max floor band.low.toNat)
  let high := min 100 (max low (max floor band.high.toNat))
  (low + raw.toNat % (high + 1 - low)).toUInt8

/-- The free band reproduces the per-species interval exactly, so banding
generalizes the original level policy instead of replacing it. -/
theorem bandedLevel_free (species : SpeciesId) (raw : UInt8) :
    bandedLevel LevelBand.free species raw = sampledLevel species raw := by
  have checked : (List.range 256).all (fun speciesValue =>
      (List.range 256).all (fun rawValue =>
        bandedLevel LevelBand.free speciesValue.toUInt8 rawValue.toUInt8 ==
          sampledLevel speciesValue.toUInt8 rawValue.toUInt8)) = true := by
    native_decide
  have speciesItem := (List.all_eq_true.mp checked) species.toNat
    (List.mem_range.mpr species.toNat_lt)
  have rawItem := (List.all_eq_true.mp speciesItem) raw.toNat
    (List.mem_range.mpr raw.toNat_lt)
  have round (value : UInt8) : value.toNat.toUInt8 = value := by
    apply UInt8.toNat.inj
    simp
  simpa only [beq_iff_eq, round] using rawItem

/-- The level-100 band forces level 100 for every species and entropy byte. -/
theorem bandedLevel_level100 (species : SpeciesId) (raw : UInt8) :
    bandedLevel LevelBand.level100 species raw = 100 := by
  have checked : (List.range 256).all (fun speciesValue =>
      (List.range 256).all (fun rawValue =>
        bandedLevel LevelBand.level100 speciesValue.toUInt8 rawValue.toUInt8 == 100))
      = true := by
    native_decide
  have speciesItem := (List.all_eq_true.mp checked) species.toNat
    (List.mem_range.mpr species.toNat_lt)
  have rawItem := (List.all_eq_true.mp speciesItem) raw.toNat
    (List.mem_range.mpr raw.toNat_lt)
  have round (value : UInt8) : value.toNat.toUInt8 = value := by
    apply UInt8.toNat.inj
    simp
  simpa only [beq_iff_eq, round] using rawItem

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

/-- Map two entropy bytes onto the 151 final species. Of the 65,536 input
words, every species receives either 434 or 435 preimages. This removes the
2:1 byte-modulo bias without introducing an unbounded rejection loop. -/
def balancedSpeciesIndex (high low : UInt8) : Nat :=
  (high.toNat * 256 + low.toNat) % pokedex.size

def balancedSpeciesCounts : Array Nat :=
  (Array.range 65536).foldl (fun counts word =>
    counts.modify (word % pokedex.size) (· + 1)) (Array.replicate pokedex.size 0)

def balancedSpeciesDistribution : Bool :=
  balancedSpeciesCounts.size == 151 &&
    balancedSpeciesCounts.all (fun count => count == 434 || count == 435) &&
    balancedSpeciesCounts.foldl (· + ·) 0 == 65536

/-- The bounded two-byte map has full, near-uniform support over all 151 final
species: its largest and smallest fibers differ by one. -/
@[simp] theorem balanced_species_distribution : balancedSpeciesDistribution = true := by
  native_decide

/-- Fourteen fixed draws select species, level, two evolution decisions/branches,
four DVs, machine count/order/replacement slots, and per-slot PP Up counts.
The balanced profile uses the first species/evolution-decision bytes as one
16-bit final-species draw and deliberately skips evolutionary promotion. Both
profiles consume the same fourteen bytes. Acquisition replays exact
`WriteMonMoves` for the selected final species at the sampled level before
machine teachings and PP Ups. -/
private def sampleMonWithLevel (band : LevelBand) (balancedFinal : Bool)
    (ledger : ResourceLedger) (rng : Rng.LinkRng) :
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
  let entry := if balancedFinal then
      entryOf (balancedSpeciesIndex speciesByte firstEvolutionDecision)
    else entryOf speciesByte.toNat
  let level := bandedLevel band entry.speciesId levelByte
  let species := if balancedFinal then entry.speciesId else
    promoteSpecies entry.speciesId level firstEvolutionDecision firstEvolutionBranch
      secondEvolutionDecision secondEvolutionBranch
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

/-- Ordinary level-distributed mon generation. -/
def sampleMon (ledger : ResourceLedger) (rng : Rng.LinkRng) :
    MonPlan × MonState × ResourceLedger × Rng.LinkRng :=
  sampleMonWithLevel LevelBand.free false ledger rng

private def sampleMonsWithLevel (band : LevelBand) (balancedFinal : Bool) :
    Nat → ResourceLedger → Rng.LinkRng →
      Array MonPlan × Team × ResourceLedger × Rng.LinkRng
  | 0, ledger, rng => (#[], #[], ledger, rng)
  | count + 1, ledger, rng =>
      let (plan, mon, ledger, rng) := sampleMonWithLevel band balancedFinal ledger rng
      let (plans, mons, ledger, rng) :=
        sampleMonsWithLevel band balancedFinal count ledger rng
      (#[plan] ++ plans, #[mon] ++ mons, ledger, rng)

private def sampleMons : Nat → ResourceLedger → Rng.LinkRng →
    Array MonPlan × Team × ResourceLedger × Rng.LinkRng :=
  sampleMonsWithLevel LevelBand.free false

/-- The repair species, fixed so a band can account for its generation floor
before any team is drawn. Rattata's floor-2 generation level fits inside every
band; the natural Rhydon this branch used to return has a floor of 42, which
would have put a level-42 sub-floor under every banded battle. -/
def fallbackSpecies : SpeciesId := 0xa5

/-- The repair branch honours the battle's band too. A level-100 repair inside a
level-30 battle would be a rare but real breach of the spread bound, so the
level rides the band exactly as a sampled mon's does. -/
private def fallbackOrigin (level : UInt8) : Origin :=
  { species := fallbackSpecies, level
    atkDv := 15, defDv := 15, spdDv := 15, spcDv := 15 }

private def fallbackPlan (level : UInt8) : MonPlan :=
  { origin := fallbackOrigin level, events := [] }

private def fallbackTeam (level : UInt8) : Team := #[acquire (fallbackOrigin level)]

private theorem fallbackTeam_legal (level : UInt8) :
    teamLegal genDex .canonical (fallbackTeam level) = true := by
  have checked : (List.range 256).all (fun value =>
      teamLegal genDex .canonical (fallbackTeam value.toUInt8)) = true := by
    native_decide
  have item := (List.all_eq_true.mp checked) level.toNat
    (List.mem_range.mpr level.toNat_lt)
  have round (value : UInt8) : value.toNat.toUInt8 = value := by
    apply UInt8.toNat.inj
    simp
  simpa only [decide_eq_true_eq, round] using item

private theorem fallback_replays (level : UInt8) (ledger : ResourceLedger) :
    replayTeam { initialLedger := ledger, plans := #[fallbackPlan level] } =
      some (fallbackTeam level, ledger) := by
  rfl

private def fallbackSample (band : LevelBand) (ledger : ResourceLedger)
    (rng : Rng.LinkRng) : Sample :=
  let level := bandedLevel band fallbackSpecies 0
  { team := ⟨fallbackTeam level, fallbackTeam_legal level⟩
    rng
    repaired := true
    history := { initialLedger := ledger, plans := #[fallbackPlan level] }
    remainingLedger := ledger
    historyReplays := fallback_replays level ledger }

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
    else fallbackSample LevelBand.free ledger rng
  else fallbackSample LevelBand.free ledger rng

/-- Default RL budget: one copy of each TM, all five HMs, and eighteen PP Ups.
This is explicit distribution policy, not a new-game inventory claim. -/
def defaultLedger : ResourceLedger := ResourceLedger.oneEach 18

def sampleSized (requested : Nat) (rng : Rng.LinkRng) : Sample :=
  sampleSizedWithLedger requested defaultLedger rng

/-- Shared fixed-size constructor for the weighted and balanced-final-species
profiles. The balance choice changes only final-species selection; resource,
move-history, PP-Up, level, and entropy-consumption contracts remain shared. -/
private def sampleSizedProfile (requested : Nat) (band : LevelBand)
    (balancedFinal : Bool) (rng : Rng.LinkRng) : Sample :=
  let count := max 1 (min maxPartySize requested)
  let (plans, candidate, remaining, rng) :=
    sampleMonsWithLevel band balancedFinal count defaultLedger rng
  let history : TeamHistory := { initialLedger := defaultLedger, plans }
  if replayed : replayTeam history = some (candidate, remaining) then
    if legal : teamLegal genDex .canonical candidate = true then
      { team := ⟨candidate, legal⟩, rng, repaired := false, history
        remainingLedger := remaining, historyReplays := replayed }
    else fallbackSample band defaultLedger rng
  else fallbackSample band defaultLedger rng

/-- Generate a requested-size progression-witnessed party whose members are all
level 100. The ordinary level byte is still consumed, preserving stream shape;
only the level-selection policy changes. -/
def sampleSizedLevel100 (requested : Nat) (rng : Rng.LinkRng) : Sample :=
  sampleSizedProfile requested LevelBand.level100 false rng

/-- Generate a requested-size party with near-uniform final-species support.
Unlike the weighted profile, evolutionary families do not funnel several source
rows into the same final form. -/
def sampleSizedBalanced (requested : Nat) (rng : Rng.LinkRng) : Sample :=
  sampleSizedProfile requested LevelBand.free true rng

/-! ## Battle-wide level band

Sampling each mon's level independently across `[generationFloor, 100]` produced
battles that were decided before the first turn: a level-27 side against a
level-94 side teaches the value head to read levels rather than positions. One
band per battle removes that gradient without touching which species appear.

The band's floor has to clear the generation floor of every species the battle
will draw, which is only knowable before generation because the balanced profile
picks its final species from two fixed bytes and never consults the level. The
peek below reads exactly those bytes and is checked against the real sampler. -/

/-- Widest level gap admitted between any two mons in one generated battle. -/
def maxLevelSpread : Nat := 10

/-- Highest level a spread-capped band may start at. -/
def maxBandFloor : Nat := 100 - maxLevelSpread

/-- Entropy bytes `sampleMonWithLevel` consumes per mon. The peek skips exactly
this many to stay aligned with it. -/
def bytesPerMon : Nat := 14

private def skipBytes : Nat → Rng.LinkRng → Rng.LinkRng
  | 0, rng => rng
  | count + 1, rng => skipBytes count (draw rng).2

/-- Read the final species a balanced-profile party will draw without building
it. Only the species and first evolution-decision bytes matter; the rest of the
block is skipped so the returned stream is exactly where the real sampler would
leave it. -/
private def peekBalancedSpecies : Nat → Rng.LinkRng → Array SpeciesId × Rng.LinkRng
  | 0, rng => (#[], rng)
  | count + 1, rng =>
      let (speciesByte, rng) := draw rng
      let (_levelByte, rng) := draw rng
      let (firstEvolutionDecision, rng) := draw rng
      let rng := skipBytes (bytesPerMon - 3) rng
      let entry := entryOf (balancedSpeciesIndex speciesByte firstEvolutionDecision)
      let (rest, rng) := peekBalancedSpecies count rng
      (#[entry.speciesId] ++ rest, rng)

/-- Place a `maxLevelSpread`-wide band above every floor it has to honour. The
anchor is drawn across the whole range first and only then pushed up, so a
battle whose species all start low keeps its low band instead of being dragged
to the middle of whatever room the floor left. -/
def bandOfAnchor (floor : Nat) (anchor : UInt8) : LevelBand :=
  let low := max (min maxBandFloor floor) (anchor.toNat % (maxBandFloor + 1))
  ⟨low.toUInt8, (low + maxLevelSpread).toUInt8⟩

/-- Draw the band one generated battle runs under, consuming a single anchor
byte and then peeking both rosters without consuming anything further. The
repair species is folded in so the fail-closed branch also lands inside the
band. -/
def battleLevelBand (playerRequested enemyRequested : Nat) (rng : Rng.LinkRng) :
    LevelBand × Rng.LinkRng :=
  let (anchor, rng) := draw rng
  let playerCount := max 1 (min maxPartySize playerRequested)
  let enemyCount := max 1 (min maxPartySize enemyRequested)
  let (playerSpecies, peeked) := peekBalancedSpecies playerCount rng
  let (enemySpecies, _) := peekBalancedSpecies enemyCount peeked
  let floor := (playerSpecies ++ enemySpecies ++ #[fallbackSpecies]).foldl
    (fun highest species =>
      max highest (Data.MinimumLevels.generationFloor species).toNat) 0
  (bandOfAnchor floor anchor, rng)

/-- Generate a balanced-profile party inside an explicit level band. -/
def sampleSizedBanded (requested : Nat) (band : LevelBand) (rng : Rng.LinkRng) : Sample :=
  sampleSizedProfile requested band true rng

/-- Generate both sides of one battle under a single shared level band. -/
def sampleBandedPair (playerRequested enemyRequested : Nat) (rng : Rng.LinkRng) :
    Sample × Sample :=
  let (band, rng) := battleLevelBand playerRequested enemyRequested rng
  let player := sampleSizedBanded playerRequested band rng
  let enemy := sampleSizedBanded enemyRequested band player.rng
  (player, enemy)

/-- Widest level gap present across both sides of a generated battle. -/
def pairLevelSpread (pair : Sample × Sample) : Nat :=
  let levels := (pair.1.team.1 ++ pair.2.team.1).map (fun mon => mon.level.toNat)
  levels.foldl max 0 - levels.foldl min 100

def popularTeamIndex (high low : UInt8) : Nat :=
  (high.toNat * 256 + low.toNat) % 200

def popularTeamIndexCounts : Array Nat :=
  (Array.range 65536).foldl (fun counts word =>
    counts.modify (word % 200) (· + 1)) (Array.replicate 200 0)

def popularTeamIndexDistribution : Bool :=
  popularTeamIndexCounts.size == 200 &&
    popularTeamIndexCounts.all (fun count => count == 327 || count == 328) &&
    popularTeamIndexCounts.foldl (· + ·) 0 == 65536

@[simp] theorem popular_team_index_distribution :
    popularTeamIndexDistribution = true := by
  native_decide

private def popularPp (move : MoveId) : UInt8 :=
  ((3 : UInt8) <<< 6) ||| (movePP move + 3 * ppUpBonus move)

private def popularMon (set : PopularTeams.Set) : MonState :=
  let generated := genMon (speciesEntry set.species) 100 15 15 15 15 4
  { generated with moves := set.moves, pp := set.moves.map popularPp }

set_option maxRecDepth 4096 in
/-- Uniformly select one top-200 composition, rotate its otherwise-unrecoverable
party order, and install the inferred level-100 competitive movesets. -/
def samplePopularLevel100 (rng : Rng.LinkRng) : Sample :=
  let (high, rng) := draw rng
  let (low, rng) := draw rng
  let (rotation, rng) := draw rng
  let index := popularTeamIndex high low
  let fallback : PopularTeams.Entry := { usage := 0, sets := #[] }
  let entry := PopularTeams.teams.getD index fallback
  let candidate := (rotatePool entry.sets rotation.toNat).map popularMon
  let history : TeamHistory :=
    { initialLedger := defaultLedger, plans := #[], competitivePreset := some candidate }
  if replayed : replayTeam history = some (candidate, defaultLedger) then
    if legal : teamLegal genDex .canonical candidate = true then
      { team := ⟨candidate, legal⟩, rng, repaired := false, popular := true, history
        remainingLedger := defaultLedger, historyReplays := replayed }
    else fallbackSample LevelBand.level100 defaultLedger rng
  else fallbackSample LevelBand.level100 defaultLedger rng

/-- Number of byte residues that pass a popular-team gate threshold. -/
def popularGateCountAt (gate : Nat) : Nat :=
  (List.range 256).countP fun value => value < gate

def popularGateCount : Nat := popularGateCountAt 26

@[simp] theorem popular_gate_count : popularGateCount = 26 := by
  native_decide

/-- Every threshold up to 256 admits exactly `gate` of the 256 byte residues,
so a server-supplied gate yields a popular-team share of exactly `gate/256`
(saturating at certainty for larger thresholds). -/
theorem popular_gate_count_at_saturates :
    ((List.range 257).all fun gate =>
      popularGateCountAt gate == min gate 256) = true := by
  native_decide

/-- A byte gate uses residues `0..gate-1`, yielding a `gate/256` popular-team
share. The byte is drawn for every full party regardless of threshold, so the
downstream entropy stream is identical across gate settings; only full
level-100 balanced parties consult the gate at all. -/
def sampleSizedBalancedLevel100Gated (gate : Nat) (requested : Nat)
    (rng : Rng.LinkRng) : Sample :=
  let count := max 1 (min maxPartySize requested)
  if count == maxPartySize then
    let (popularGate, rng) := draw rng
    if popularGate.toNat < gate then samplePopularLevel100 rng
    else sampleSizedProfile requested LevelBand.level100 true rng
  else sampleSizedProfile requested LevelBand.level100 true rng

/-- The legacy 26/256 sampler is the gated sampler at threshold 26, so
existing replay recordings and seed streams are preserved byte-for-byte. -/
def sampleSizedBalancedLevel100 (requested : Nat) (rng : Rng.LinkRng) : Sample :=
  sampleSizedBalancedLevel100Gated 26 requested rng

/-- The gated sampler remains learnset-legal for every threshold and seed. -/
theorem sampleSizedBalancedLevel100Gated_sound (gate requested : Nat)
    (rng : Rng.LinkRng) :
    teamLegal genDex .canonical
      (sampleSizedBalancedLevel100Gated gate requested rng).team.1 = true :=
  (sampleSizedBalancedLevel100Gated gate requested rng).team.2

/-- The gated sampler retains the exact reconstruction witness for every
threshold, including when it selects a canonical competitive preset. -/
theorem sampleSizedBalancedLevel100Gated_progression_witnessed
    (gate requested : Nat) (rng : Rng.LinkRng) :
    replayTeam (sampleSizedBalancedLevel100Gated gate requested rng).history =
      some ((sampleSizedBalancedLevel100Gated gate requested rng).team.1,
        (sampleSizedBalancedLevel100Gated gate requested rng).remainingLedger) :=
  (sampleSizedBalancedLevel100Gated gate requested rng).historyReplays

/-- Level-100 generation retains canonical learnset legality for every seed. -/
theorem sampleSizedLevel100_sound (requested : Nat) (rng : Rng.LinkRng) :
    teamLegal genDex .canonical (sampleSizedLevel100 requested rng).team.1 = true :=
  (sampleSizedLevel100 requested rng).team.2

/-- Balanced-final-species generation remains legal for every seed. -/
theorem sampleSizedBalanced_sound (requested : Nat) (rng : Rng.LinkRng) :
    teamLegal genDex .canonical (sampleSizedBalanced requested rng).team.1 = true :=
  (sampleSizedBalanced requested rng).team.2

/-- Balanced level-100 generation remains legal for every seed. -/
theorem sampleSizedBalancedLevel100_sound (requested : Nat) (rng : Rng.LinkRng) :
    teamLegal genDex .canonical (sampleSizedBalancedLevel100 requested rng).team.1 = true :=
  (sampleSizedBalancedLevel100 requested rng).team.2

/-- Level-100 generation retains the stronger ordered resource replay witness. -/
theorem sampleSizedLevel100_progression_witnessed (requested : Nat)
    (rng : Rng.LinkRng) :
    replayTeam (sampleSizedLevel100 requested rng).history =
      some ((sampleSizedLevel100 requested rng).team.1,
        (sampleSizedLevel100 requested rng).remainingLedger) :=
  (sampleSizedLevel100 requested rng).historyReplays

/-- Balanced-final-species generation retains the ordered resource witness. -/
theorem sampleSizedBalanced_progression_witnessed (requested : Nat)
    (rng : Rng.LinkRng) :
    replayTeam (sampleSizedBalanced requested rng).history =
      some ((sampleSizedBalanced requested rng).team.1,
        (sampleSizedBalanced requested rng).remainingLedger) :=
  (sampleSizedBalanced requested rng).historyReplays

/-- Balanced level-100 generation retains an exact reconstruction witness,
including when it selects a canonical competitive preset. -/
theorem sampleSizedBalancedLevel100_progression_witnessed (requested : Nat)
    (rng : Rng.LinkRng) :
    replayTeam (sampleSizedBalancedLevel100 requested rng).history =
      some ((sampleSizedBalancedLevel100 requested rng).team.1,
        (sampleSizedBalancedLevel100 requested rng).remainingLedger) :=
  (sampleSizedBalancedLevel100 requested rng).historyReplays

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

/-- Distinct well-formed generator seeds for the executable batch checks. -/
private def guardSeed (index : Nat) : Rng.LinkRng :=
  { list := (Array.range Wram.serialRnsLength).map fun offset =>
      (13 * offset + 37 * index + 3).toUInt8
    index := 0 }

/-- The species peek reads the same roster the sampler goes on to build and
leaves the entropy stream exactly where the sampler leaves it, so lifting the
band above the drawn floors cannot drift out of step with generation. -/
theorem peekBalancedSpecies_matches_sampler :
    ((List.range 24).all fun seed =>
      (List.range 6).all fun size =>
        let requested := size + 1
        let peeked := peekBalancedSpecies requested (guardSeed seed)
        let sampled := sampleSizedBalanced requested (guardSeed seed)
        peeked.1 == sampled.team.1.map (fun mon => mon.species) &&
          peeked.2 == sampled.rng) = true := by
  native_decide

/-- No generated battle opens with one side outlevelling the other: every mon on
both sides sits inside a single `maxLevelSpread`-wide band. -/
theorem banded_pair_stays_within_spread :
    ((List.range 24).all fun seed =>
      (List.range 6).all fun size =>
        (List.range 6).all fun other =>
          pairLevelSpread
              (sampleBandedPair (size + 1) (other + 1) (guardSeed seed)) ≤
            maxLevelSpread) = true := by
  native_decide

/-- Executable support check: banding narrows each battle without narrowing the
corpus. Some battle uses the full spread, some opens near the bottom of the
range, and some opens near the top. -/
def bandedPairsSpanTheLevelRange : Bool :=
  let levels (player enemy seed : Nat) : Array Nat :=
    let pair := sampleBandedPair player enemy (guardSeed seed)
    (pair.1.team.1 ++ pair.2.team.1).map fun mon => mon.level.toNat
  ((List.range 96).any fun seed =>
      pairLevelSpread (sampleBandedPair 6 6 (guardSeed seed)) == maxLevelSpread) &&
    ((List.range 96).any fun seed => (levels 1 1 seed).all (· ≤ 20)) &&
    ((List.range 96).any fun seed => (levels 6 6 seed).all (90 ≤ ·))


/-- Banding still admits the whole level range across battles. -/
theorem banded_pairs_span_the_level_range : bandedPairsSpanTheLevelRange = true := by
  native_decide

-- The repair species must fit under any band the generator can draw.
#guard Data.MinimumLevels.generationFloor fallbackSpecies == 2
#guard Data.internalToDex fallbackSpecies == 19

private def sample0 : Sample := sample Rng.seed0

#guard sample0.team.1.size == 1
#guard sample0.repaired == false
#guard teamLegal genDex .canonical sample0.team.1
#guard (sampleSized 0 Rng.seed0).team.1.size == 1
#guard (sampleSized 99 Rng.seed0).team.1.size == maxPartySize
#guard !(sampleSized 6 Rng.seed0).repaired
#guard (sampleSized 6 Rng.seed0).team.1.all (monLegal genDex .canonical)
#guard (sampleSized 6 Rng.seed0).history.plans.size == 6
#guard (sampleSizedLevel100 6 Rng.seed0).team.1.size == 6
#guard (sampleSizedLevel100 6 Rng.seed0).team.1.all (fun mon => mon.level == 100)
#guard !(sampleSizedLevel100 6 Rng.seed0).repaired
#guard (sampleSizedBalanced 6 Rng.seed0).team.1.size == 6
#guard (sampleSizedBalanced 6 Rng.seed0).team.1.all (monLegal genDex .canonical)
#guard !(sampleSizedBalanced 6 Rng.seed0).repaired
#guard (sampleSizedBalancedLevel100 6 Rng.seed0).team.1.all (fun mon => mon.level == 100)
#guard !(sampleSizedBalancedLevel100 6 Rng.seed0).repaired
#guard (samplePopularLevel100 Rng.seed0).popular
#guard (samplePopularLevel100 Rng.seed0).team.1.size == 6
#guard (samplePopularLevel100 Rng.seed0).team.1.all (fun mon => mon.level == 100)
#guard !(sampleSizedBalancedLevel100 5 Rng.seed0).popular
#guard popularGateCountAt 64 == 64
#guard popularGateCountAt 300 == 256
#guard !(sampleSizedBalancedLevel100Gated 0 6 Rng.seed0).popular
#guard (sampleSizedBalancedLevel100Gated 256 6 Rng.seed0).popular
#guard !(sampleSizedBalancedLevel100Gated 256 5 Rng.seed0).popular
#guard (sampleSizedBalancedLevel100Gated 0 6 Rng.seed0).team.1.all
  (fun mon => mon.level == 100)
#guard (sampleSizedBalancedLevel100Gated 256 6 Rng.seed0).team.1.all
  (fun mon => mon.level == 100)

end Battle.RL.DynamicGenerator
