/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0.
-/
import Battle.Rom.LinkStateProjection
import Sm83.Simulation

/-!
# Link-only whole-battle equivalence contract

This module fixes the exact scope of the cartridge-equivalence theorem used by
training.  The domain starts with two proof-carrying generated parties at the
post-handshake `InitOpponent` checkpoint.  It excludes cable-room negotiation
and post-return Cable Club healing, while retaining both cartridge perspectives,
clock roles, link RNG state, waits, divergence, and desynchronization.

The final certificate is intentionally an obligation bundle, not an axiom and
not a claim that the obligations are already discharged.  `wholeBattle` composes
only proofs present in a certificate.
-/

namespace Battle.Rom.LinkEquivalence

open Sm83 Battle Battle.Full

/-- Exact training-domain reset.  The parties carry canonical legality and
ordered acquisition/resource witnesses through `DynamicGenerator.Sample`.
The mechanics RNG is required to be a valid ten-byte cartridge image. -/
structure EntryDomain where
  left : RL.DynamicGenerator.Sample
  right : RL.DynamicGenerator.Sample
  battleRng : Rng.LinkRng
  rngWellFormed : battleRng.wf

/-- Left cartridge's semantic view. -/
def leftEnvironment (domain : EntryDomain) : Full.Environment.State :=
  Full.Environment.linkResetFromSamples domain.left domain.right domain.battleRng

/-- Right cartridge's semantic view, with physical ownership reversed. -/
def rightEnvironment (domain : EntryDomain) : Full.Environment.State :=
  Full.Environment.linkResetFromSamples domain.right domain.left domain.battleRng

/-- The independent high-level cartridge pair at the named entry boundary. -/
def highPair (domain : EntryDomain) : Full.Link.Pair :=
  { left := { engine := (leftEnvironment domain).engine, role := .internal }
    right := { engine := (rightEnvironment domain).engine, role := .external } }

@[simp] theorem highPair_roles (domain : EntryDomain) :
    (highPair domain).left.role = .internal ∧
      (highPair domain).right.role = .external := by
  exact ⟨rfl, rfl⟩

/-- Generated link resets install the two exact sampled parties in opposite
physical perspectives without resampling. -/
theorem highPair_parties (domain : EntryDomain) :
    (highPair domain).left.engine.battle.player.party.mons = domain.left.team.1 ∧
      (highPair domain).left.engine.battle.enemy.party.mons = domain.right.team.1 ∧
      (highPair domain).right.engine.battle.player.party.mons = domain.right.team.1 ∧
      (highPair domain).right.engine.battle.enemy.party.mons = domain.left.team.1 := by
  simp [highPair, leftEnvironment, rightEnvironment]

private theorem party_eq_of_mons_eq (left right : Full.Party)
    (mons : left.mons = right.mons) : left = right := by
  cases left
  cases right
  simpa using mons

/-- The semantic pair begins synchronized by construction.  This theorem is
about the independent high model only; the machine relation is established by
`LinkStateProjection.AtInitOpponent`. -/
theorem highPair_starts_synchronized (domain : EntryDomain) :
    Full.Link.mirroredActive (highPair domain) = true ∧
      Full.Link.mirroredParties (highPair domain) = true ∧
      Full.Link.mirroredActiveIndexes (highPair domain) = true ∧
      Full.Link.mirroredRng (highPair domain) = true ∧
      Full.Link.phasesAgree (highPair domain) = true := by
  have synchronized := Full.Environment.linkResetFromSamples_swapped_synchronized
    domain.left domain.right domain.battleRng
  have parties := highPair_parties domain
  have indexes := Full.Environment.linkResetFromSamples_swapped_indexes
    domain.left domain.right domain.battleRng
  refine ⟨?_, ?_, ?_, ?_, ?_⟩
  · simp only [Full.Link.mirroredActive, highPair, leftEnvironment,
      rightEnvironment, Bool.and_eq_true]
    exact ⟨beq_iff_eq.mpr synchronized.1,
      beq_iff_eq.mpr synchronized.2.1⟩
  · simp only [Full.Link.mirroredParties, Bool.and_eq_true]
    constructor
    · apply beq_iff_eq.mpr
      exact party_eq_of_mons_eq _ _ (parties.1.trans parties.2.2.2.symm)
    · apply beq_iff_eq.mpr
      exact party_eq_of_mons_eq _ _ (parties.2.1.trans parties.2.2.1.symm)
  · simp only [Full.Link.mirroredActiveIndexes, highPair, leftEnvironment,
      rightEnvironment, Bool.and_eq_true]
    exact ⟨beq_iff_eq.mpr indexes.1, beq_iff_eq.mpr indexes.2⟩
  · simp only [Full.Link.mirroredRng, highPair, leftEnvironment, rightEnvironment]
    exact beq_iff_eq.mpr synchronized.2.2.1
  · simp only [Full.Link.phasesAgree, highPair, leftEnvironment, rightEnvironment]
    rw [synchronized.2.2.2.1, synchronized.2.2.2.2]

/-- Semantic inputs admitted by the action-commit training adapter.  Items are
absent because no link wire value encodes them. -/
inductive Response where
  | actions (left right : Full.Action)
  | generatedMove (side : Side) (move : MoveId)
  | mimicTarget (side : Side) (source target : Fin 4)
  | settle
  deriving Repr

/-- Every ordinary joint response must use cartridge-encodable action bytes.
Nested responses are committed at their explicit ROM menu/checkpoint sites. -/
def AdmissibleResponse : Response → Prop
  | .actions left right =>
      (Full.Link.encodeAction left).isSome = true ∧
        (Full.Link.encodeAction right).isSome = true
  | .generatedMove _ move => move != 0
  | .mimicTarget _ _ _ => True
  | .settle => True

/-- Observable semantic events. Presentation bus traffic remains in the low
trace and is hidden only by proved frame summaries. -/
inductive Event where
  | response (response : Response)
  | mechanics (left right : List Full.Engine.Event)
  | desynchronized (cause : Full.Link.DesyncCause)
  | terminal (left right : Outcome.BattleTerminal)
  | returned (left right : Outcome.EpisodeResult)
  deriving Repr

/-- Named nontermination/desynchronization outcomes.  Analysis timeout and the
training decision horizon intentionally have no constructor. -/
inductive Nonreturn where
  | serialWait
  | menuWait
  | audioWait
  | cartridgeLoop
  | linkDesync (cause : Full.Link.DesyncCause)
  | invalidExternalResponse
  deriving Repr, DecidableEq

inductive Outcome where
  | returned (left right : Outcome.EpisodeResult)
  | nonreturn (reason : Nonreturn)
  deriving Repr

/-- Low behavior state is always the two physical machines plus retained cable
orientation. -/
abbrev LowState := LinkStateProjection.MachinePair

/-- The high behavior retains both semantic cartridge perspectives. -/
abbrev HighState := Full.Link.Pair

/-- Final low/high agreement is deliberately relational because each cartridge
stores its own local result and return frame. -/
def OutcomeRelated : Outcome → Outcome → Prop
  | .returned leftLow rightLow, .returned leftHigh rightHigh =>
      leftLow = leftHigh ∧ rightLow = rightHigh
  | .nonreturn low, .nonreturn high => low = high
  | _, _ => False

/-- Required proof decomposition for the link-only whole-battle theorem.  No
field can be inhabited by a replay fixture alone: each transition proof starts
from the paired decoded-machine relation. -/
structure Obligations where
  LowEvent : Type
  LowStep : LowState → List LowEvent → LowState → Prop
  LowFinal : LowState → Outcome → Prop
  HighStep : HighState → List Event → HighState → Prop
  HighFinal : HighState → Outcome → Prop
  projectEvent : LowEvent → Option Event
  realizeEvent : Event → Option LowEvent
  related : LowState → HighState → Prop

  /-- The concrete relation refines the paired active/RNG/link checkpoint. -/
  relationStrengthens : ∀ {low high}, related low high →
    Nonempty (LinkStateProjection.Synchronized low high)

  /-- Each low transition is a proof-bearing checkpoint block containing its
  decoded machine-cycle execution; it is matched by one semantic transition. -/
  forwardSimulation :
    DirectSimulation LowStep HighStep related projectEvent

  /-- Returned and nonreturn outcomes agree from related final states. -/
  finalRefinement :
    FinalRefinement related LowFinal HighFinal OutcomeRelated

  /-- Reactive serial/menu behavior cannot disappear under event projection. -/
  reactions : PreservesReaction LowStep HighStep related projectEvent
    forwardSimulation

  /-- Reverse realizability excludes high action/chance traces unavailable to
  two cartridges under an admissible controller/cable schedule. -/
  reverseRealizable : ∀ {lowInitial highInitial}, related lowInitial highInitial →
    ∀ highBehavior : MachineBehavior HighStep HighFinal highInitial,
      ∃ lowBehavior : MachineBehavior LowStep LowFinal lowInitial,
        BehaviorRefines realizeEvent
          (fun highOutcome lowOutcome => OutcomeRelated lowOutcome highOutcome)
          highBehavior lowBehavior

/-- Local simulations supplied by the certificate lift to every finite,
silent-divergent, and reactive low behavior. -/
theorem wholeBattle (proofs : Obligations)
    {lowInitial : LowState} {highInitial : HighState}
    (initial : proofs.related lowInitial highInitial)
    (lowBehavior : MachineBehavior proofs.LowStep proofs.LowFinal lowInitial) :
    ∃ highBehavior : MachineBehavior proofs.HighStep proofs.HighFinal highInitial,
      BehaviorRefines proofs.projectEvent OutcomeRelated lowBehavior highBehavior := by
  exact DirectSimulation.liftBehavior
    (LowStep := proofs.LowStep) (HighStep := proofs.HighStep)
    (Related := proofs.related) (LowFinal := proofs.LowFinal)
    (HighFinal := proofs.HighFinal) (outcomeRel := OutcomeRelated)
    proofs.projectEvent proofs.forwardSimulation proofs.finalRefinement
    proofs.reactions initial lowBehavior

/-- A completed certificate yields both ROM-to-model whole behavior refinement
and model-to-ROM realizability for the same named relation. -/
theorem wholeBattle_equivalence (proofs : Obligations)
    {lowInitial : LowState} {highInitial : HighState}
    (initial : proofs.related lowInitial highInitial) :
    (∀ lowBehavior : MachineBehavior proofs.LowStep proofs.LowFinal lowInitial,
      ∃ highBehavior : MachineBehavior proofs.HighStep proofs.HighFinal highInitial,
        BehaviorRefines proofs.projectEvent OutcomeRelated lowBehavior highBehavior) ∧
    (∀ highBehavior : MachineBehavior proofs.HighStep proofs.HighFinal highInitial,
      ∃ lowBehavior : MachineBehavior proofs.LowStep proofs.LowFinal lowInitial,
        BehaviorRefines proofs.realizeEvent
          (fun highOutcome lowOutcome => OutcomeRelated lowOutcome highOutcome)
          highBehavior lowBehavior) := by
  exact ⟨fun low => wholeBattle proofs initial low,
    proofs.reverseRealizable initial⟩

end Battle.Rom.LinkEquivalence
