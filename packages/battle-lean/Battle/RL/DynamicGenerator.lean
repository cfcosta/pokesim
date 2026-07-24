/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.RL.GeneratorSafe

/-!
# Total dynamic legal-team generator

`Battle.RL.Generator` is the deterministic constructor: it turns explicit
species/level/DV/move-count choices into model state. This module supplies the
sampling layer used by self-play. It consumes the same total link-RNG machine as
the battle model and returns a subtype whose payload is *proved* to satisfy
`teamLegal Dex.gen1 .canonical`.

The candidate path samples party size (1–6), species, four DVs, move count, and
a cyclic starting point in the ROM-certified learn pool. Generated mons are
level 100: the current data seam records the level-agnostic set of moves a
species can ever know, so level 100 is the constructive point at which every
level-up member of that set is available. The final
legality decision is not merely a test: its successful branch carries the proof.
The defensive branch returns a fixed proved-legal team and records `repaired :=
true`; malformed external RNG states or future generator regressions therefore
cannot leak an invalid team into an RL episode.
-/

namespace Battle.RL.DynamicGenerator

open Battle.RL

/-- A team accepted by the canonical Gen-1 legality predicate. -/
abbrev CanonicalTeam := { team : Team // teamLegal genDex .canonical team = true }

/-- Sampling output, including the advanced entropy state and whether the
fail-closed repair branch was needed. -/
structure Sample where
  team : CanonicalTeam
  rng : Rng.LinkRng
  repaired : Bool

/-- Rotate a nonempty pool by `start`; modulo indexing preserves every entry and
lets `genMon` choose a dynamic packed prefix without introducing illegal moves. -/
def rotatePool (pool : Array MoveId) (start : Nat) : Array MoveId :=
  if pool.isEmpty then pool
  else
    (Array.range pool.size).map fun index => pool.getD ((start + index) % pool.size) 0

/-- Draw one byte and thread the link RNG. -/
@[inline] def draw (rng : Rng.LinkRng) : UInt8 × Rng.LinkRng := rng.next

/-- Sample one canonical candidate. Eight draws choose species, four DVs, move
count, and learn-pool rotation. One reserved draw keeps the transcript shape
stable for a future level-aware learnset table; the current constructive sampler
uses level 100 so every level-up move in the certified pool is available. -/
def sampleMon (rng : Rng.LinkRng) : MonState × Rng.LinkRng :=
  let (speciesByte, rng) := draw rng
  let (_, rng) := draw rng
  let (atkByte, rng) := draw rng
  let (defByte, rng) := draw rng
  let (spdByte, rng) := draw rng
  let (spcByte, rng) := draw rng
  let (countByte, rng) := draw rng
  let (startByte, rng) := draw rng
  let entry := entryOf speciesByte.toNat
  let rotated := { entry with movePool := rotatePool entry.movePool startByte.toNat }
  let moveCount := countByte.toNat % Wram.numMoves + 1
  (genMon rotated 100 atkByte defByte spdByte spcByte moveCount, rng)

private def sampleMons : Nat → Rng.LinkRng → Team × Rng.LinkRng
  | 0, rng => (#[], rng)
  | count + 1, rng =>
      let (mon, rng) := sampleMon rng
      let (tail, rng) := sampleMons count rng
      (#[mon] ++ tail, rng)

/-- A fixed proof-carrying recovery value. It is used only if the sampled
candidate fails canonical legality, making invalid output unrepresentable. -/
private def fallbackMon : MonState :=
  genMon (entryOf 0) 50 15 15 15 15 4

private theorem fallbackTeam_legal :
    teamLegal genDex .canonical #[fallbackMon] = true := by
  native_decide

/-- Sample a party of caller-requested size, clamped into the cartridge range
`1..PARTY_LENGTH`, and return a proof that it is canonical. -/
def sampleSized (requested : Nat) (rng : Rng.LinkRng) : Sample :=
  let count := max 1 (min maxPartySize requested)
  let (candidate, rng) := sampleMons count rng
  if legal : teamLegal genDex .canonical candidate = true then
    { team := ⟨candidate, legal⟩, rng, repaired := false }
  else
    { team := ⟨#[fallbackMon], fallbackTeam_legal⟩, rng, repaired := true }

/-- Fully dynamic party generation: the first byte chooses size 1–6 and the
remaining draws choose every mon. -/
def sample (rng : Rng.LinkRng) : Sample :=
  let (sizeByte, rng) := draw rng
  sampleSized (sizeByte.toNat % maxPartySize + 1) rng

/-- Soundness is structural: every returned value carries the canonical legality
proof, independently of entropy and independently of whether repair occurred. -/
theorem sample_sound (rng : Rng.LinkRng) :
    teamLegal genDex .canonical (sample rng).team.1 = true :=
  (sample rng).team.2

/-- Requested-size generation has the same unconditional guarantee. -/
theorem sampleSized_sound (requested : Nat) (rng : Rng.LinkRng) :
    teamLegal genDex .canonical (sampleSized requested rng).team.1 = true :=
  (sampleSized requested rng).team.2

/-! ## Deterministic sampling guards -/

private def sample0 : Sample := sample Rng.seed0

#guard sample0.team.1.size == 1
#guard sample0.repaired == false
#guard teamLegal genDex .canonical sample0.team.1
#guard (sampleSized 0 Rng.seed0).team.1.size == 1
#guard (sampleSized 99 Rng.seed0).team.1.size == maxPartySize
#guard !(sampleSized 6 Rng.seed0).repaired
#guard (sampleSized 6 Rng.seed0).team.1.all (monLegal genDex .canonical)

end Battle.RL.DynamicGenerator
