/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.RL.MoveHistory

/-!
# Total progression-witnessed legal-team generator

The sampler no longer chooses an unordered subset of a species' unioned learn
pool. Each mon starts with the exact moves `WriteMonMoves` gives it at level 100,
then replays compatible machine teachings and PP Ups. One shared caller-supplied
ledger enforces one-use TM copies across the party, reusable owned HMs, and a
finite PP Up budget.

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

/-- Ten draws select species, four DVs, machine count/order/replacement slots,
and per-slot PP Up counts. Level is constructively fixed at 100 so all ordered
level-up offers have occurred; unlike the old sampler, declining/replacement is
represented by the actual final history rather than an unordered pool slice. -/
def sampleMon (ledger : ResourceLedger) (rng : Rng.LinkRng) :
    MonPlan × MonState × ResourceLedger × Rng.LinkRng :=
  let (speciesByte, rng) := draw rng
  let (_, rng) := draw rng
  let (atkByte, rng) := draw rng
  let (defByte, rng) := draw rng
  let (spdByte, rng) := draw rng
  let (spcByte, rng) := draw rng
  let (machineCountByte, rng) := draw rng
  let (machineStartByte, rng) := draw rng
  let (replacementBits, rng) := draw rng
  let (ppPattern, rng) := draw rng
  let entry := entryOf speciesByte.toNat
  let origin : Origin :=
    { species := entry.speciesId, level := 100
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
