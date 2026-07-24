/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Refinement.Trace

/-!
# Refinement simulation — the model drives the episode protocol

`Refinement/Trace.lean` proved the *shape* fact (`episodeTrace_refines`): any
pre-terminal mechanic stream plus a witness refines to a valid `Episode.Step*`
path ending in `Final`. This module supplies the **model** and closes the loop:
the witness is the one `toEpisodeWitness` reads off the *actual* terminal
`BattleState`, and the mechanic stream is the one `Battle.Step.resolveTurn` /
`runScript` *actually emit* (with the terminal marker filtered out — it drives the
phase machine, not an observation).

`runScript_refines` is the headline: run a scripted battle to termination, and its
final state's episode witness together with its emitted trace form a valid episode
path ending in `Episode.Final`. That is the simulation/refinement statement — the
pure model refines GPT's `Battle.Episode` spec.
-/

namespace Battle.Refinement

/-! ## Terminal witness is total on terminal states -/

/-- Any terminal `BattleState` (phase `.ending`/`.returned`) yields a witness. -/
theorem toEpisodeWitness_isSome {s : BattleState} (h : s.phase.isTerminal = true) :
    (toEpisodeWitness s).isSome = true := by
  unfold toEpisodeWitness
  split <;> simp_all [Outcome.EpisodePhase.isTerminal]

/-- The witness always reports the state's own turn counter. -/
theorem toEpisodeWitness_turn {s : BattleState} {w : Episode.TerminalWitness}
    (hw : toEpisodeWitness s = some w) : w.turn = s.turn := by
  unfold toEpisodeWitness at hw
  split at hw <;>
    first
      | (injection hw with hw; subst hw; rfl)
      | simp at hw

/-! ## Model event stream → episode mechanics -/

/-- Is this the terminal marker (as opposed to a mechanic checkpoint)? -/
def isTerminalEvent : Step.TurnEvent → Bool
  | .terminalReached _ _ => true
  | _ => false

/-- The pre-terminal mechanic events of a model turn stream: everything except
    the terminal marker, which drives the phase machine rather than becoming an
    observation. -/
def mechanicsOf (evs : List Step.TurnEvent) : List Step.TurnEvent :=
  evs.filter (fun e => !isTerminalEvent e)

/-! ## The refinement theorem -/

/-- **Simulation, on any terminal state.** For a terminal `BattleState sf` and any
    mechanic stream, the witness `toEpisodeWitness` reads off `sf` drives a valid
    `Steps` path from the matching `.battling` episode state to `.returned`, ending
    in `Episode.Final`. This is `episodeTrace_refines` fed the model's real
    witness, so the abstraction is no longer a free parameter. -/
theorem terminalState_refines (sf : BattleState) (mechanics : List Step.TurnEvent)
    (hterm : sf.phase.isTerminal = true) :
    ∃ w, toEpisodeWitness sf = some w ∧
      Steps { phase := .battling, turn := sf.turn }
            (episodeTrace mechanics w)
            { phase := .returned w, turn := sf.turn } ∧
      Episode.Final ({ phase := .returned w, turn := sf.turn } : Episode.State) w := by
  have hsome := toEpisodeWitness_isSome hterm
  cases h : toEpisodeWitness sf with
  | none => simp [h] at hsome
  | some w =>
      refine ⟨w, rfl, ?_, Episode.Final.returned rfl⟩
      exact (episodeTrace_refines (s := { phase := .battling, turn := sf.turn })
        rfl (toEpisodeWitness_turn h) mechanics).1

/-- **Simulation, on the scripted driver.** Run a fixed script to termination; its
    final state's episode witness and its emitted (mechanic-filtered) trace form a
    valid `Episode.Step*` path ending in `Episode.Final`. The pure model refines
    the `Battle.Episode` protocol. -/
theorem runScript_refines (script : List (Step.ResolvedMove × Step.ResolvedMove))
    (s : BattleState) (hterm : (Step.runScript script s).1.phase.isTerminal = true) :
    ∃ w, toEpisodeWitness (Step.runScript script s).1 = some w ∧
      Steps { phase := .battling, turn := (Step.runScript script s).1.turn }
            (episodeTrace (mechanicsOf (Step.runScript script s).2) w)
            { phase := .returned w, turn := (Step.runScript script s).1.turn } ∧
      Episode.Final
        ({ phase := .returned w, turn := (Step.runScript script s).1.turn } : Episode.State) w :=
  terminalState_refines (Step.runScript script s).1 (mechanicsOf (Step.runScript script s).2) hterm

/-! ## Fidelity guards -/

-- `mechanicsOf` drops the terminal marker and keeps the checkpoints.
#guard decide (mechanicsOf
  [Step.TurnEvent.orderDecided .player false, .fainted .enemy,
   .terminalReached (.partyExhausted .enemy) (some .win)]
  = [Step.TurnEvent.orderDecided .player false, .fainted .enemy])
#guard isTerminalEvent (.terminalReached (.partyExhausted .enemy) (some .win))
#guard !isTerminalEvent (.fainted .enemy)

-- A concrete deterministic battle that ends in one turn, exercised end-to-end
-- through `runScript_refines` (player wins the speed-tie coin, one-shots a 20-HP
-- enemy with an always-hit 40-BP move).
private def exMon (hp speed : UInt16) : MonState :=
  { species := 6, hp, boxLevel := 50, status := 0, type1 := 0x14, type2 := 0x02,
    catchRate := 45, moves := #[52, 0, 0, 0], dvs := 0xFFFF, level := 50,
    maxHp := 100, attack := 80, defense := 70, speed, special := 90, pp := #[15, 0, 0, 0] }

private def exHit : Step.ResolvedMove :=
  { id := 33, power := 40, type := 0x00, accuracy := 255, alwaysHits := true }

private def exSeed : Rng.LinkRng :=
  { list := #[0, 255, 0, 255, 0, 255, 0, 255, 0, 255], index := 0 }

private def exBattle : BattleState := BattleState.start (exMon 100 100) (exMon 20 50) exSeed

-- The scripted turn really terminates, so the theorem's hypothesis is discharged.
#guard (Step.runScript [(exHit, exHit)] exBattle).1.phase.isTerminal

-- The refinement applies to this concrete run (compile-time check of the chain).
example : True := by
  have _refines := runScript_refines [(exHit, exHit)] exBattle (by decide)
  trivial

end Battle.Refinement
