/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Full.Environment

/-!
# Full-party model-against-itself runner

Decision and nested-continuation budgets are external training limits. Exhausting
either yields a distinct open/truncated result and never manufactures a battle
terminal.
-/

namespace Battle.Full.SelfPlay

structure Policy where
  choose : Environment.Observation → Side → Array Full.Action → Rng.LinkRng →
    Option Full.Action × Rng.LinkRng

/-- Prefer damaging moves, then any legal action. Forced switches remain legal
and are selected when no fight exists. -/
def damagingPolicy : Policy where
  choose := fun observation side legal rng =>
    let moves := if side == .player then observation.playerMoves else observation.enemyMoves
    let damaging := legal.find? fun action => match action with
      | .fight slot => (Data.moveData (moves.getD slot.val 0)).power != 0
      | .struggle => true
      | _ => false
    (damaging.orElse (fun _ => legal[0]?), rng)

/-- Random legal baseline with private entropy. -/
def randomPolicy : Policy where
  choose := fun _ _ legal rng =>
    let (raw, rng) := rng.next
    if legal.isEmpty then (none, rng)
    else (legal[raw.toNat % legal.size]?, rng)

structure Transition where
  before : Environment.Observation
  playerAction : Full.Action
  enemyAction : Full.Action
  events : List Engine.Event
  after : Environment.Observation
  deriving Repr

inductive StopReason where
  | finished
  | truncated
  | nestedOpen
  | blocked (side : Side)
  | invalidAction (side : Side)
  | ineffectiveAction (side : Side)
  | capturePending
  | rngStuck
  | divisionFreeze
  | externalRandomRequired
  | inactive
  deriving Repr, DecidableEq, BEq

structure Run where
  finalState : Environment.State
  transitions : List Transition
  playerPolicyRng : Rng.LinkRng
  enemyPolicyRng : Rng.LinkRng
  stop : StopReason

private def returned (state : Environment.State) : Bool := Environment.done state

private def handleResult : Nat → Environment.StepResult →
    Environment.State × List Engine.Event × StopReason
  | _, .transitioned state events =>
      let settled := Environment.settle state
      (settled, events, if returned settled then .finished else .inactive)
  | _, .invalidAction state side => (state, [], .invalidAction side)
  | _, .ineffectiveAction state side => (state, [], .ineffectiveAction side)
  | _, .capturePending state _ events => (state, events, .capturePending)
  | _, .rngStuck state events => (state, events, .rngStuck)
  | _, .divisionFreeze state events => (state, events, .divisionFreeze)
  | 0, .nestedMove state _ _ events => (state, events, .nestedOpen)
  | remaining + 1, .nestedMove state side move events =>
      let (state, more, reason) := handleResult remaining (Environment.resumeNested state side move)
      (state, events ++ more, reason)
  | _, .mimicPending state _ _ _ events => (state, events, .nestedOpen)
  | _, .runPending state _ _ events => (state, events, .externalRandomRequired)
  | _, .wildFaintRunPending state events => (state, events, .externalRandomRequired)
  | _, .disobediencePending state _ _ events => (state, events, .externalRandomRequired)
  | _, .inactive state => (state, [], .inactive)

/-- Run at most `decisions` policy turns and `nestedBudget` same-action nested
requests per turn. -/
def runFor : Nat → Nat → Policy → Policy → Environment.State →
    Rng.LinkRng → Rng.LinkRng → Run
  | 0, _, _, _, state, playerRng, enemyRng =>
      let settled := Environment.settle state
      { finalState := settled, transitions := [], playerPolicyRng := playerRng,
        enemyPolicyRng := enemyRng,
        stop := if returned settled then .finished else .truncated }
  | decisions + 1, nestedBudget, playerPolicy, enemyPolicy, state, playerRng, enemyRng =>
      let settled := Environment.settle state
      if returned settled then
        { finalState := settled, transitions := [], playerPolicyRng := playerRng,
          enemyPolicyRng := enemyRng, stop := .finished }
      else
        let observation := Environment.observe state
        let playerLegal := Environment.legalActions state .player
        let enemyLegal := Environment.legalActions state .enemy
        if playerLegal.isEmpty then
          { finalState := state, transitions := [], playerPolicyRng := playerRng,
            enemyPolicyRng := enemyRng, stop := .blocked .player }
        else if enemyLegal.isEmpty then
          { finalState := state, transitions := [], playerPolicyRng := playerRng,
            enemyPolicyRng := enemyRng, stop := .blocked .enemy }
        else
          let (playerChoice, playerRng) :=
            playerPolicy.choose observation .player playerLegal playerRng
          let (enemyChoice, enemyRng) :=
            enemyPolicy.choose observation .enemy enemyLegal enemyRng
          match playerChoice, enemyChoice with
          | some playerAction, some enemyAction =>
              let (next, events, reason) := handleResult nestedBudget
                (Environment.step state playerAction enemyAction)
              let transition : Transition :=
                { before := observation, playerAction, enemyAction, events,
                  after := Environment.observe next }
              if reason == .inactive then
                let rest := runFor decisions nestedBudget playerPolicy enemyPolicy next
                  playerRng enemyRng
                { rest with transitions := transition :: rest.transitions }
              else
                { finalState := next, transitions := [transition],
                  playerPolicyRng := playerRng, enemyPolicyRng := enemyRng, stop := reason }
          | _, _ =>
              { finalState := state, transitions := [], playerPolicyRng := playerRng,
                enemyPolicyRng := enemyRng, stop := .invalidAction .player }

/-- Dynamically sample two arbitrary canonical parties and run mirror policies. -/
def runEpisode (decisions nestedBudget : Nat) (playerPolicy enemyPolicy : Policy)
    (generatorRng battleRng playerRng enemyRng : Rng.LinkRng) : Run :=
  runFor decisions nestedBudget playerPolicy enemyPolicy
    (Environment.reset generatorRng battleRng) playerRng enemyRng

end Battle.Full.SelfPlay
