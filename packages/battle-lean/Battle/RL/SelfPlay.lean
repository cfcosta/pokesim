/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.RL.Environment

/-!
# Model-against-itself runner

Policies consume only observations and legal-action arrays. Generator entropy,
battle RNG, and each policy's exploration RNG are four independent streams. A
run horizon is an external training budget: reaching it yields `.truncated`,
never a battle terminal. Likewise blocked policies, invalid choices, and a stuck
battle RNG remain distinct stop reasons.
-/

namespace Battle.RL.SelfPlay

open Battle.RL

/-- A policy may decline to act. Its private RNG is threaded separately from the
battle mechanics RNG. -/
structure Policy where
  choose : Environment.Observation → Side → Array Environment.PolicyAction →
    Rng.LinkRng → Option Environment.PolicyAction × Rng.LinkRng

/-- Uniform-by-byte-index exploration over the legal action vector. Modulo bias
is distribution policy, not mechanics semantics. -/
def randomPolicy : Policy where
  choose := fun _ _ legal rng =>
    let (raw, rng) := rng.next
    if legal.isEmpty then (none, rng)
    else (legal[raw.toNat % legal.size]?, rng)

/-- Deterministic baseline: always choose the first legal slot. -/
def firstPolicy : Policy where
  choose := fun _ _ legal rng => (legal[0]?, rng)

/-- One policy-facing transition retained for replay. -/
structure Transition where
  before : Environment.Observation
  playerAction : Environment.PolicyAction
  enemyAction : Environment.PolicyAction
  events : List Ordinary.Event
  after : Environment.Observation
  deriving Repr

/-- Stop reasons are indexed by final state. Only `.finished` can carry `done`,
so truncation or execution failure cannot masquerade as episode completion. -/
inductive StopReason : Environment.State → Type where
  | finished {state} (done : Environment.done state = true) : StopReason state
  | truncated {state} : StopReason state
  | blocked {state} (side : Side) : StopReason state
  | invalidPolicy {state} : StopReason state
  | rngStuck {state} : StopReason state
  | divisionFreeze {state} : StopReason state

structure Run where
  finalState : Environment.State
  transitions : List Transition
  playerPolicyRng : Rng.LinkRng
  enemyPolicyRng : Rng.LinkRng
  stop : StopReason finalState

/-- Settled result from the player's perspective. Non-finished runs have zero
training return and must be classified by `stop`. -/
def playerReturn (state : Environment.State) : Int :=
  match state.battle.phase with
  | .returned result =>
      match result.terminal.verdict with
      | some .win => 1
      | some .loss => -1
      | some .draw | none => 0
  | _ => 0

/-- Execute at most `budget` agent decisions. Settling an already-witnessed
terminal consumes no budget. -/
def runFor : Nat → Policy → Policy → Environment.State →
    Rng.LinkRng → Rng.LinkRng → Run
  | budget, playerPolicy, enemyPolicy, state, playerRng, enemyRng =>
      let settled := Environment.settle state
      if finished : Environment.done settled = true then
        { finalState := settled, transitions := [],
          playerPolicyRng := playerRng, enemyPolicyRng := enemyRng,
          stop := .finished finished }
      else
        match budget with
        | 0 =>
            { finalState := state, transitions := [],
              playerPolicyRng := playerRng, enemyPolicyRng := enemyRng,
              stop := .truncated }
        | remaining + 1 =>
            let observation := Environment.observe state
            let playerLegal := Environment.legalActions state .player
            let enemyLegal := Environment.legalActions state .enemy
            if playerLegal.isEmpty then
              { finalState := state, transitions := [],
                playerPolicyRng := playerRng, enemyPolicyRng := enemyRng,
                stop := .blocked .player }
            else if enemyLegal.isEmpty then
              { finalState := state, transitions := [],
                playerPolicyRng := playerRng, enemyPolicyRng := enemyRng,
                stop := .blocked .enemy }
            else
              let (playerChoice, playerRng) :=
                playerPolicy.choose observation .player playerLegal playerRng
              let (enemyChoice, enemyRng) :=
                enemyPolicy.choose observation .enemy enemyLegal enemyRng
              match playerChoice, enemyChoice with
              | some playerAction, some enemyAction =>
                  match Environment.step state playerAction enemyAction with
                  | .transitioned next events =>
                      let transition : Transition :=
                        { before := observation, playerAction, enemyAction, events,
                          after := Environment.observe next }
                      let rest := runFor remaining playerPolicy enemyPolicy next
                        playerRng enemyRng
                      { rest with transitions := transition :: rest.transitions }
                  | .invalidAction _ | .inactive _ =>
                      { finalState := state, transitions := [],
                        playerPolicyRng := playerRng, enemyPolicyRng := enemyRng,
                        stop := .invalidPolicy }
                  | .rngStuck next _ =>
                      { finalState := next, transitions := [],
                        playerPolicyRng := playerRng, enemyPolicyRng := enemyRng,
                        stop := .rngStuck }
                  | .divisionFreeze next _ =>
                      { finalState := next, transitions := [],
                        playerPolicyRng := playerRng, enemyPolicyRng := enemyRng,
                        stop := .divisionFreeze }
              | _, _ =>
                  { finalState := state, transitions := [],
                    playerPolicyRng := playerRng, enemyPolicyRng := enemyRng,
                    stop := .invalidPolicy }

/-- Generate a fresh proved-legal matchup and run both policies. -/
def runEpisode (budget : Nat) (playerPolicy enemyPolicy : Policy)
    (generatorRng battleRng playerPolicyRng enemyPolicyRng : Rng.LinkRng) : Run :=
  runFor budget playerPolicy enemyPolicy
    (Environment.reset generatorRng battleRng) playerPolicyRng enemyPolicyRng

/-- A deterministic ten-byte seed constructor for independent episode streams. -/
def seedFrom (seed : Nat) : Rng.LinkRng :=
  { list := (List.range Wram.serialRnsLength).map
      (fun index => (seed * 73 + index * 41 + 17).toUInt8) |>.toArray
    index := 0 }

@[simp] theorem seedFrom_wf (seed : Nat) : (seedFrom seed).wf := by
  simp [seedFrom, Rng.LinkRng.wf, Wram.serialRnsLength]

/-- A `.finished` stop reason carries proof that its indexed final state is
genuinely returned. Other reasons make no completion claim. -/
theorem finished_reason_done {state : Environment.State} (reason : StopReason state) :
    match reason with
    | .finished _ => Environment.done state = true
    | _ => True := by
  cases reason with
  | finished proof => exact proof
  | truncated => trivial
  | blocked => trivial
  | invalidPolicy => trivial
  | rngStuck => trivial
  | divisionFreeze => trivial

/-! ## Self-play guards -/

private def duel : Run :=
  runEpisode 128 randomPolicy randomPolicy
    (seedFrom 1) (seedFrom 2) (seedFrom 3) (seedFrom 4)

private def duelSane : Bool :=
  duel.transitions.length ≤ 128 &&
    teamLegal genDex .canonical duel.finalState.playerReset.team.1 &&
    teamLegal genDex .canonical duel.finalState.enemyReset.team.1

#guard duelSane

/-- Horizon exhaustion is not completion. -/
private def zeroBudget : Run :=
  runEpisode 0 firstPolicy firstPolicy
    (seedFrom 5) (seedFrom 6) (seedFrom 7) (seedFrom 8)

#guard !Environment.done zeroBudget.finalState

end Battle.RL.SelfPlay
