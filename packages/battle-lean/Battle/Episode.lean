/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

import Battle.Action
import Sm83.Behavior

namespace Battle.Episode

inductive Side where
  | player | enemy
  deriving Repr, DecidableEq

inductive Result where
  | win | loss | draw
  deriving Repr, DecidableEq

inductive TerminalCause where
  | enemyPartyExhausted
  | playerPartyExhausted
  | captured
  | escaped
  | enemyEscaped
  | linkForfeit (side : Side)
  | scripted
  deriving Repr, DecidableEq

/-- Terminal provenance retained before cartridge cleanup erases distinctions. -/
structure TerminalWitness where
  result : Result
  cause : TerminalCause
  turn : Nat
  playerActiveHP : UInt16
  enemyActiveHP : UInt16
  deriving Repr, DecidableEq

inductive Phase where
  | initializing
  | battling
  | ending (witness : TerminalWitness) (epilogueComplete : Bool)
  | returned (witness : TerminalWitness)
  deriving Repr, DecidableEq

structure State where
  phase : Phase := .initializing
  turn : Nat := 0
  /-- Physical M-cycles, distinct from retired architectural instructions. -/
  machineCycles : Nat := 0
  machineInstructions : Nat := 0
  deriving Repr, DecidableEq

/-- Projected semantic observations. Presentation is retained as a named class
but can be hidden by the RL projection. -/
inductive Observation where
  | rng (site : String) (value : UInt8)
  | input (channel : String) (value : UInt8)
  | link (sent received : UInt8)
  | action (side : Side) (choice : Action)
  | presentation (tag : String)
  | mechanic (tag : String)
  deriving Repr, DecidableEq

inductive Event where
  | enteredBattle
  | observed (observation : Observation)
  | turnAdvanced (turn : Nat)
  | terminal (witness : TerminalWitness)
  | epilogue (witness : TerminalWitness)
  | cleanup (witness : TerminalWitness)
  | outerReturn (witness : TerminalWitness)
  deriving Repr, DecidableEq

/-- Independent high-level episode protocol. Mechanics transitions occur only
while battling; terminal provenance is then carried through epilogue and return. -/
def active (state : State) : Prop :=
  ∀ witness, state.phase ≠ .returned witness

inductive Step : State → List Event → State → Prop where
  /-- One physical processor M-cycle. Its optional semantic observation is the
  only visible event; retirement and timing remain separate counters. -/
  | machineCycle {state} (retired : Bool) (observation : Option Observation)
      (active : active state) :
      Step state (observation.map Event.observed).toList
        { state with
          machineCycles := state.machineCycles + 1
          machineInstructions := state.machineInstructions + if retired then 1 else 0 }
  | initialize {state}
      (phase : state.phase = .initializing) :
      Step state [.enteredBattle] { state with phase := .battling }
  | instruction {state}
      (active : active state) :
      Step state [] { state with machineInstructions := state.machineInstructions + 1 }
  | observe {state observation}
      (active : active state) :
      Step state [.observed observation] state
  | nextTurn {state}
      (phase : state.phase = .battling) :
      Step state [.turnAdvanced (state.turn + 1)] { state with turn := state.turn + 1 }
  | finish {state witness}
      (phase : state.phase = .battling)
      (turn : witness.turn = state.turn) :
      Step state [.terminal witness] { state with phase := .ending witness false }
  | epilogue {state witness}
      (phase : state.phase = .ending witness false) :
      Step state [.epilogue witness] { state with phase := .ending witness true }
  | returnOuter {state witness}
      (phase : state.phase = .ending witness true) :
      Step state [.cleanup witness, .outerReturn witness]
        { state with phase := .returned witness }

/-- RL termination is deliberately later than terminal detection. -/
def done (state : State) : Bool :=
  match state.phase with
  | .returned _ => true
  | _ => false

@[simp] theorem ending_not_done (state : State) (witness : TerminalWitness) (complete : Bool)
    (phase : state.phase = .ending witness complete) : done state = false := by
  simp [done, phase]

@[simp] theorem returned_done (state : State) (witness : TerminalWitness)
    (phase : state.phase = .returned witness) : done state = true := by
  simp [done, phase]

/-- A single transition can enter `returned` only from a completed ending phase
and emits cleanup followed by outer return with the same witness. -/
theorem returned_step_witness {before after : State} {trace : List Event}
    {witness : TerminalWitness}
    (step : Step before trace after) (returned : after.phase = .returned witness) :
    before.phase = .ending witness true ∧
      trace = [.cleanup witness, .outerReturn witness] := by
  cases step with
  | machineCycle retired observation active => exact False.elim (active witness returned)
  | instruction active => exact False.elim (active witness returned)
  | observe active => exact False.elim (active witness returned)
  | «initialize» => simp_all
  | nextTurn => simp_all
  | finish => simp_all
  | epilogue => simp_all
  | returnOuter => simp_all

/-- Ending transitions cannot replace terminal provenance. -/
theorem ending_witness_preserved {before after : State} {trace : List Event}
    {witnessBefore witnessAfter : TerminalWitness} {completeBefore completeAfter : Bool}
    (phaseBefore : before.phase = .ending witnessBefore completeBefore)
    (step : Step before trace after)
    (phaseAfter : after.phase = .ending witnessAfter completeAfter) :
    witnessAfter = witnessBefore := by
  cases step <;> simp_all

/-- Returned states are genuine finite outcomes; fuel exhaustion has no route to
this predicate. -/
inductive Final : State → TerminalWitness → Prop where
  | returned {state witness} (phase : state.phase = .returned witness) : Final state witness

/-- Presentation observations are hidden from semantic/RL traces. -/
def projectObservation : Observation → Option Observation
  | .presentation _ => none
  | observation => some observation

end Battle.Episode
