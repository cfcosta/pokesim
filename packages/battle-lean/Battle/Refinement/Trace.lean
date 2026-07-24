/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Step
import Battle.Refinement.Bridge

/-!
# Refinement trace — model `TurnEvent`s drive an `Episode.Step*` path

`Battle.Episode.Step` is a single-transition relation; a whole battle is a *path*
through it. This module adds the reflexive-transitive closure `Steps` (with trace
concatenation) — a derived notion in `Battle.Refinement`, editing nothing in
`Battle.Episode` — and shows the model's per-turn checkpoint stream can drive one.

## The translation

Every model `Step.TurnEvent` that is *not* the terminal marker becomes a coarse
`Episode.Observation.mechanic` tag (`mechanicTag`): the episode protocol is the
presentation-independent view, so the numeric payload (damage amount, HP) stays
in the model state — the trace records only *what mechanic fired, on which side*.
The terminal is not an observation; it drives the phase machine
(`finish → epilogue → returnOuter`), so `episodeTrace` appends the four-event
terminal block explicitly.

## The capstone

`episodeTrace_refines` is the reusable protocol fact: from **any** `.battling`
episode state whose turn counter matches the witness, **any** list of pre-terminal
mechanic events translates to a valid `Steps` path ending in `.returned`, and that
end state is `Episode.Final`. `Refinement/Simulation.lean` instantiates it with the
actual events `Battle.Step.resolveTurn` / `runScript` emit.
-/

namespace Battle.Refinement

/-! ## Reflexive-transitive closure of `Episode.Step` -/

/-- A multi-step path through `Episode.Step`, concatenating each transition's
    event trace. This is the "run the protocol for a while" relation the single
    `Episode.Step` constructors compose into. -/
inductive Steps : Episode.State → List Episode.Event → Episode.State → Prop where
  /-- The empty path: no events, no state change. -/
  | nil {s} : Steps s [] s
  /-- Prepend one transition, concatenating its trace. -/
  | cons {s₁ t₁ s₂ t₂ s₃} :
      Episode.Step s₁ t₁ s₂ → Steps s₂ t₂ s₃ → Steps s₁ (t₁ ++ t₂) s₃

/-- Paths compose, concatenating their traces. -/
theorem Steps.trans {s₁ t₁ s₂ t₂ s₃}
    (h₁ : Steps s₁ t₁ s₂) (h₂ : Steps s₂ t₂ s₃) : Steps s₁ (t₁ ++ t₂) s₃ := by
  induction h₁ with
  | nil => simpa using h₂
  | cons st _ ih => rw [List.append_assoc]; exact Steps.cons st (ih h₂)

/-! ## A battling state is `active` -/

/-- Every `.battling` state is `Episode.active` (its phase is not `.returned`). -/
theorem active_of_battling {s : Episode.State} (h : s.phase = .battling) :
    Episode.active s := by
  intro w hw; simp [h] at hw

/-! ## Model event → episode observation -/

/-- The coarse mechanic tag for a non-terminal turn event: what fired, on which
    side. Numeric detail (damage, HP) is intentionally dropped — it lives in the
    model state, not the protocol trace. The terminal marker is not an
    observation, so it maps to the neutral `"terminal"` tag and is never emitted
    as one (`episodeTrace` handles it via the phase machine instead). -/
def mechanicTag : Step.TurnEvent → String
  | .orderDecided .player _ => "order:player-first"
  | .orderDecided .enemy _  => "order:enemy-first"
  | .attackStart .player _  => "attack:player"
  | .attackStart .enemy _   => "attack:enemy"
  | .critical .player       => "crit:player"
  | .critical .enemy        => "crit:enemy"
  | .missed .player         => "miss:player"
  | .missed .enemy          => "miss:enemy"
  | .damageDealt .player _ _ => "damage:player"
  | .damageDealt .enemy _ _  => "damage:enemy"
  | .fainted .player        => "faint:player"
  | .fainted .enemy         => "faint:enemy"
  | .terminalReached _ _    => "terminal"

/-- Translate one non-terminal turn event to its episode observation event. -/
def translateEvent (e : Step.TurnEvent) : Episode.Event :=
  Episode.Event.observed (.mechanic (mechanicTag e))

/-- The full episode trace a terminal turn produces: every pre-terminal mechanic
    as an observation, then the four-event terminal block
    (`terminal → epilogue → cleanup → outerReturn`) driven by the witness. -/
def episodeTrace (mechanics : List Step.TurnEvent) (w : Episode.TerminalWitness) :
    List Episode.Event :=
  mechanics.map translateEvent ++
    [Episode.Event.terminal w, .epilogue w, .cleanup w, .outerReturn w]

/-! ## The two building-block paths -/

/-- A run of pre-terminal mechanic events translates to a `Steps` loop on a fixed
    `active` state — each is an `Episode.Step.observe` that leaves the state put. -/
theorem Steps.mechanicsChain {s : Episode.State} (h : Episode.active s)
    (evs : List Step.TurnEvent) : Steps s (evs.map translateEvent) s := by
  induction evs with
  | nil => exact .nil
  | cons e es ih =>
      have step : Episode.Step s [translateEvent e] s := by
        rw [translateEvent]; exact Episode.Step.observe h
      simpa using Steps.cons step ih

/-- From a `.battling` state whose turn matches the witness, the terminal block is
    a valid `Steps` path to `.returned` — `finish` then `epilogue` then
    `returnOuter`, exactly the episode phase machine's exit. -/
theorem Steps.finishToReturned {s : Episode.State} {w : Episode.TerminalWitness}
    (hb : s.phase = .battling) (ht : w.turn = s.turn) :
    Steps s [Episode.Event.terminal w, .epilogue w, .cleanup w, .outerReturn w]
      { s with phase := .returned w } := by
  have h1 : Episode.Step s [Episode.Event.terminal w] { s with phase := .ending w false } :=
    Episode.Step.finish hb ht
  have h2 : Episode.Step { s with phase := .ending w false } [Episode.Event.epilogue w]
      { s with phase := .ending w true } := Episode.Step.epilogue rfl
  have h3 : Episode.Step { s with phase := .ending w true }
      [Episode.Event.cleanup w, Episode.Event.outerReturn w]
      { s with phase := .returned w } := Episode.Step.returnOuter rfl
  simpa using Steps.cons h1 (Steps.cons h2 (Steps.cons h3 Steps.nil))

/-! ## The capstone: the model's turn trace refines the episode protocol -/

/-- **Protocol refinement.** From any `.battling` episode state whose turn counter
    matches the witness, any list of pre-terminal mechanic events translates to a
    valid `Steps` path ending in `.returned`, and that end state is
    `Episode.Final` with the witness. The model does not need to appear here — this
    is the shape *any* terminating turn stream refines to; `Simulation.lean` feeds
    it the real `resolveTurn` / `runScript` events. -/
theorem episodeTrace_refines {s : Episode.State} {w : Episode.TerminalWitness}
    (hb : s.phase = .battling) (ht : w.turn = s.turn) (mechanics : List Step.TurnEvent) :
    Steps s (episodeTrace mechanics w) { s with phase := .returned w } ∧
      Episode.Final { s with phase := .returned w } w := by
  refine ⟨?_, Episode.Final.returned rfl⟩
  have hobs : Steps s (mechanics.map translateEvent) s :=
    Steps.mechanicsChain (active_of_battling hb) mechanics
  have hfin := Steps.finishToReturned (s := s) (w := w) hb ht
  simpa [episodeTrace] using Steps.trans hobs hfin

/-! ## Fidelity guards -/

-- The mechanic tags name the firing side and kind.
#guard decide (mechanicTag (.orderDecided .player false) = "order:player-first")
#guard decide (mechanicTag (.damageDealt .enemy 12 3) = "damage:enemy")
#guard decide (mechanicTag (.fainted .enemy) = "faint:enemy")
#guard decide (mechanicTag (.critical .player) = "crit:player")
#guard decide (translateEvent (.missed .player) = Episode.Event.observed (.mechanic "miss:player"))

-- The episode trace is the mechanic observations followed by the four-event
-- terminal block.
private def w0 : Episode.TerminalWitness :=
  { result := .win, cause := .enemyPartyExhausted, turn := 0, playerActiveHP := 100, enemyActiveHP := 0 }

#guard decide (episodeTrace [] w0 =
  [Episode.Event.terminal w0, .epilogue w0, .cleanup w0, .outerReturn w0])
#guard decide (episodeTrace [Step.TurnEvent.orderDecided .player false, .fainted .enemy] w0 =
  [Episode.Event.observed (.mechanic "order:player-first"),
   Episode.Event.observed (.mechanic "faint:enemy"),
   Episode.Event.terminal w0, .epilogue w0, .cleanup w0, .outerReturn w0])

-- The capstone instantiates end-to-end on a concrete battling state.
example : Steps { phase := .battling } (episodeTrace [Step.TurnEvent.fainted .enemy] w0)
    { phase := .returned w0 } ∧ Episode.Final ({ phase := .returned w0 } : Episode.State) w0 :=
  episodeTrace_refines rfl rfl _

end Battle.Refinement
