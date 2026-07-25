/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.RL.DynamicGenerator
import Battle.Ordinary
import Battle.Action

/-!
# Restricted self-play environment

This is the first native RL environment with an honest mechanics contract. Every
reset dynamically creates two proved-canonical one-mon teams whose moves all lie
inside `Battle.Ordinary.supportedMove`. Agents choose ordinary fight slots; no
unsupported Action constructor is reinterpreted.

The one-mon restriction is deliberate: fainting the active mon is genuinely
party exhaustion, so the ordinary kernel's terminal is cartridge-correct without
an unimplemented replacement policy. `settle` is a separate environment
transition from witnessed `.ending` to `.returned`; consequently `done` is never
true merely because HP reached zero.
-/

namespace Battle.RL.Environment

open Battle.RL

/-- A mon is suitable for this profile when it is canonical and has at least one
supported move with PP. -/
def playable (mon : MonState) : Bool :=
  monLegal genDex .canonical mon &&
    (Array.range Wram.numMoves).any fun index =>
      let id := mon.moves.getD index 0
      Ordinary.supportedMove id && Ordinary.currentPp (mon.pp.getD index 0) != 0

/-- Generator entries with at least one move in the ordinary profile. -/
def ordinaryEntries : Array SpeciesEntry :=
  pokedex.filter fun entry => entry.movePool.any Ordinary.supportedMove

#guard ordinaryEntries.size > 0
#guard ordinaryEntries.all fun entry => entry.movePool.any Ordinary.supportedMove

private def ordinaryEntryOf (index : Nat) : SpeciesEntry :=
  ordinaryEntries.getD (index % ordinaryEntries.size) default

private def supportedPool (entry : SpeciesEntry) : Array MoveId :=
  entry.movePool.filter Ordinary.supportedMove

/-- Reset-side evidence retained for auditing and snapshot construction. -/
structure ResetSide where
  team : DynamicGenerator.CanonicalTeam
  active : MonState
  first : team.1[0]? = some active
  playableActive : playable active = true

/-- Sample one level-100 ordinary-profile mon. Species, DVs, move count, and pool
rotation all consume the link RNG. -/
private def candidateMon (rng : Rng.LinkRng) : MonState × Rng.LinkRng :=
  let (speciesByte, rng) := rng.next
  let (atkByte, rng) := rng.next
  let (defByte, rng) := rng.next
  let (spdByte, rng) := rng.next
  let (spcByte, rng) := rng.next
  let (countByte, rng) := rng.next
  let (startByte, rng) := rng.next
  let entry := ordinaryEntryOf speciesByte.toNat
  let pool := DynamicGenerator.rotatePool (supportedPool entry) startByte.toNat
  let entry := { entry with movePool := pool }
  let moveCount := countByte.toNat % Wram.numMoves + 1
  (genMon entry 100 atkByte defByte spdByte spcByte moveCount, rng)

private def fallbackMon : MonState :=
  let entry := ordinaryEntryOf 0
  genMon { entry with movePool := supportedPool entry } 100 15 15 15 15 1

private theorem fallbackPlayable : playable fallbackMon = true := by native_decide
private theorem fallbackLegal :
    teamLegal genDex .canonical #[fallbackMon] = true := by native_decide

private def fallbackSide : ResetSide :=
  { team := ⟨#[fallbackMon], fallbackLegal⟩
    active := fallbackMon
    first := rfl
    playableActive := fallbackPlayable }

/-- Sample a coherent one-mon reset side. Both required predicates are checked
into proof fields; failure takes the explicit fallback path. -/
def sampleSide (rng : Rng.LinkRng) : ResetSide × Rng.LinkRng × Bool :=
  let (candidate, rng) := candidateMon rng
  if hp : playable candidate = true then
    if ht : teamLegal genDex .canonical #[candidate] = true then
      ({ team := ⟨#[candidate], ht⟩, active := candidate,
         first := rfl, playableActive := hp }, rng, false)
    else
      (fallbackSide, rng, true)
  else
    (fallbackSide, rng, true)

/-- RL state. Reset teams are retained with legality evidence; `battle` is the
live mutable active-state view used by the ordinary kernel. -/
structure State where
  playerReset : ResetSide
  enemyReset : ResetSide
  battle : BattleState
  repairedReset : Bool

/-- Compact policy observation for the one-mon profile. -/
structure Observation where
  playerSpecies : SpeciesId
  enemySpecies : SpeciesId
  playerHp : UInt16
  enemyHp : UInt16
  playerMoves : Array MoveId
  enemyMoves : Array MoveId
  playerPp : Array UInt8
  enemyPp : Array UInt8
  turn : Nat
  terminalWitnessed : Bool
  done : Bool
  deriving Repr, DecidableEq, BEq

/-- A policy action remains the shared battle action type. This profile's
`legalActions` returns only `.fight` constructors. -/
abbrev PolicyAction := Battle.Action

/-- Dynamically reset both sides from generator entropy while installing a
separate battle RNG. Team sampling can never perturb battle randomness. Both
reset teams carry canonical-legality proofs. -/
def reset (generatorRng battleRng : Rng.LinkRng) : State :=
  let (player, generatorRng, playerRepaired) := sampleSide generatorRng
  let (enemy, _, enemyRepaired) := sampleSide generatorRng
  { playerReset := player
    enemyReset := enemy
    battle := BattleState.start player.active enemy.active battleRng .link
    repairedReset := playerRepaired || enemyRepaired }

/-- RL completion occurs only after the explicit settled-return phase. -/
def done (state : State) : Bool :=
  match state.battle.phase with
  | .returned _ => true
  | _ => false

/-- Project policy-visible state. RNG future bytes are intentionally absent. -/
def observe (state : State) : Observation :=
  { playerSpecies := (state.battle.active .player).species
    enemySpecies := (state.battle.active .enemy).species
    playerHp := (state.battle.active .player).hp
    enemyHp := (state.battle.active .enemy).hp
    playerMoves := (state.battle.active .player).moves
    enemyMoves := (state.battle.active .enemy).moves
    playerPp := (state.battle.active .player).pp
    enemyPp := (state.battle.active .enemy).pp
    turn := state.battle.turn
    terminalWitnessed := state.battle.phase.isTerminal
    done := done state }

/-- Enumerate exactly the currently legal actions for one side. -/
def legalActions (state : State) (side : Side) : Array PolicyAction :=
  match state.battle.phase with
  | .battling =>
      (Array.range Wram.numMoves).filterMap fun index =>
        if h : index < 4 then
          let slot : Fin 4 := ⟨index, h⟩
          if Ordinary.legalFightSlot state.battle side slot then
            some (.fight slot)
          else none
        else none
  | _ => #[]

private def fightSlot? : PolicyAction → Option (Fin 4)
  | .fight slot => some slot
  | _ => none

inductive StepResult where
  | transitioned (state : State) (events : List Ordinary.Event)
  | invalidAction (state : State)
  | rngStuck (state : State) (events : List Ordinary.Event)
  | divisionFreeze (state : State) (events : List Ordinary.Event)
  | inactive (state : State)

/-- Apply simultaneous self-play choices. Only actions returned by
`legalActions` can transition. -/
def step (state : State) (player enemy : PolicyAction) : StepResult :=
  match state.battle.phase with
  | .battling =>
      match fightSlot? player, fightSlot? enemy with
      | some playerSlot, some enemySlot =>
          match Ordinary.resolveTurn playerSlot enemySlot state.battle with
          | .complete battle events => .transitioned { state with battle } events
          | .invalidAction _ => .invalidAction state
          | .rngStuck battle events => .rngStuck { state with battle } events
          | .divisionFreeze battle events => .divisionFreeze { state with battle } events
      | _, _ => .invalidAction state
  | _ => .inactive state

/-- Every exposed restricted-profile action is a typed fight slot accepted by
the ordinary legality predicate. -/
theorem legalActions_sound (state : State) (side : Side) (action : PolicyAction)
    (member : action ∈ legalActions state side) :
    ∃ slot : Fin 4, action = .fight slot ∧
      Ordinary.legalFightSlot state.battle side slot = true := by
  unfold legalActions at member
  split at member <;> rename_i hPhase
  · simp only [Array.mem_filterMap] at member
    obtain ⟨index, indexMember, mapped⟩ := member
    simp only [Array.mem_range] at indexMember
    split at mapped <;> rename_i hIndex
    · split at mapped <;> rename_i hLegal
      · refine ⟨⟨index, hIndex⟩, ?_, ?_⟩
        · symm
          exact Option.some.inj mapped
        · simpa only using hLegal
      · simp_all
    · simp_all
  · simp at member

/-- Any typed non-fight request is rejected without mutating RL state. -/
theorem nonfight_invalid (state : State) (enemy action : PolicyAction)
    (phase : state.battle.phase = .battling)
    (nonfight : fightSlot? action = none) :
    step state action enemy = .invalidAction state := by
  simp [step, phase, nonfight]

/-- Complete the profile's no-op epilogue/cleanup after a terminal witness. This
is separate from `step`, preserving the `ending ≠ returned` distinction. -/
def settle (state : State) : State :=
  match state.battle.phase with
  | .ending terminal =>
      { state with battle := { state.battle with phase := .returned ⟨terminal⟩ } }
  | _ => state

@[simp] theorem reset_player_legal (generatorRng battleRng : Rng.LinkRng) :
    teamLegal genDex .canonical (reset generatorRng battleRng).playerReset.team.1 = true :=
  (reset generatorRng battleRng).playerReset.team.2

@[simp] theorem reset_enemy_legal (generatorRng battleRng : Rng.LinkRng) :
    teamLegal genDex .canonical (reset generatorRng battleRng).enemyReset.team.1 = true :=
  (reset generatorRng battleRng).enemyReset.team.2

/-- Settling an ending state is the only environment operation that establishes
`done`; the terminal witness is retained unchanged. -/
theorem settle_done {state : State} {terminal : Outcome.BattleTerminal}
    (phase : state.battle.phase = .ending terminal) :
    done (settle state) = true := by
  simp [settle, done, phase]

/-! ## Reset guards -/

private def reset0 : State := reset Rng.seed0 Rng.seed0

#guard !reset0.repairedReset
#guard teamLegal genDex .canonical reset0.playerReset.team.1
#guard teamLegal genDex .canonical reset0.enemyReset.team.1
#guard playable reset0.playerReset.active
#guard playable reset0.enemyReset.active
#guard (legalActions reset0 .player).size > 0
#guard (legalActions reset0 .enemy).size > 0
#guard !done reset0

end Battle.RL.Environment
