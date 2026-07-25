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

/-- Strong reset condition for the restricted kernel: all four slots are
ordinary moves with positive PP, preventing unsupported leftovers from becoming
a policy dead end after the first usable slot is exhausted. -/
def profileReady (mon : MonState) : Bool :=
  monLegal genDex .canonical mon &&
    (Array.range Wram.numMoves).all fun index =>
      let id := mon.moves.getD index 0
      Ordinary.supportedMove id && Ordinary.currentPp (mon.pp.getD index 0) != 0

/-- Compatible machines whose move bodies are inside the restricted ordinary
kernel. -/
private def ordinaryMachines (species : SpeciesId) : Array MoveHistory.MachineIndex :=
  (Array.range 55).filterMap fun index =>
    if bounded : index < 55 then
      let machine : MoveHistory.MachineIndex := ⟨index, bounded⟩
      if Data.Progression.machineCompatible species index &&
          Ordinary.supportedMove (MoveHistory.machineMove machine) then some machine else none
    else none

private def ordinaryEntries : Array SpeciesEntry :=
  pokedex.filter fun entry => (ordinaryMachines entry.speciesId).size ≥ 4

#guard ordinaryEntries.size > 0

private def ordinaryEntryOf (index : Nat) : SpeciesEntry :=
  ordinaryEntries.getD (index % ordinaryEntries.size) default

private def firstUnsupportedSlot (mon : MonState) : Fin 4 :=
  if !Ordinary.supportedMove (mon.moves.getD 0 0) then 0
  else if !Ordinary.supportedMove (mon.moves.getD 1 0) then 1
  else if !Ordinary.supportedMove (mon.moves.getD 2 0) then 2
  else 3

private def applyOrdinaryMachines : List MoveHistory.MachineIndex →
    MonState × MoveHistory.ResourceLedger × List MoveHistory.Event →
    MonState × MoveHistory.ResourceLedger × List MoveHistory.Event
  | [], state => state
  | machine :: tail, state =>
      if profileReady state.1 then state
      else
        let slot := firstUnsupportedSlot state.1
        match MoveHistory.teach state.1 state.2.1 machine slot with
        | none => applyOrdinaryMachines tail state
        | some (mon, ledger) =>
            applyOrdinaryMachines tail (mon, ledger, state.2.2 ++ [.teach machine slot])

private structure CandidateSide where
  mon : MonState
  plan : MoveHistory.MonPlan
  initialLedger : MoveHistory.ResourceLedger
  remainingLedger : MoveHistory.ResourceLedger
  rng : Rng.LinkRng

private def candidateSide (rng : Rng.LinkRng) : CandidateSide :=
  let (speciesByte, rng) := rng.next
  let (atkByte, rng) := rng.next
  let (defByte, rng) := rng.next
  let (spdByte, rng) := rng.next
  let (spcByte, rng) := rng.next
  let (startByte, rng) := rng.next
  let entry := ordinaryEntryOf speciesByte.toNat
  let origin : MoveHistory.Origin :=
    { species := entry.speciesId, level := 100
      atkDv := atkByte, defDv := defByte, spdDv := spdByte, spcDv := spcByte }
  let initialLedger := MoveHistory.ResourceLedger.oneEach 0
  let mon := MoveHistory.acquire origin
  let machines := DynamicGenerator.rotatePool (ordinaryMachines origin.species) startByte.toNat
  let state := applyOrdinaryMachines machines.toList (mon, initialLedger, [])
  { mon := state.1, plan := { origin, events := state.2.2 }
    initialLedger, remainingLedger := state.2.1, rng }

/-- Reset-side evidence retained for auditing and snapshot construction. -/
structure ResetSide where
  active : MonState
  legal : teamLegal genDex .canonical #[active] = true
  playableActive : playable active = true
  history : MoveHistory.TeamHistory
  remainingLedger : MoveHistory.ResourceLedger
  historyReplays : MoveHistory.replayTeam history = some (#[active], remainingLedger)

def ResetSide.team (side : ResetSide) : DynamicGenerator.CanonicalTeam :=
  ⟨#[side.active], side.legal⟩

private def fallbackOrigin : MoveHistory.Origin :=
  { species := 21, level := 100 -- Mew: one natural move, then three compatible TMs
    atkDv := 15, defDv := 15, spdDv := 15, spcDv := 15 }

private def fallbackMachine1 : MoveHistory.MachineIndex := ⟨4, by omega⟩  -- TM05 Mega Kick
private def fallbackMachine2 : MoveHistory.MachineIndex := ⟨11, by omega⟩ -- TM12 Water Gun
private def fallbackMachine3 : MoveHistory.MachineIndex := ⟨17, by omega⟩ -- TM18 Counter
private def fallbackMachine4 : MoveHistory.MachineIndex := ⟨25, by omega⟩ -- TM26 Earthquake
private def fallbackPlan : MoveHistory.MonPlan :=
  { origin := fallbackOrigin
    events := [.teach fallbackMachine1 0, .teach fallbackMachine2 1,
      .teach fallbackMachine3 2, .teach fallbackMachine4 3] }
private def fallbackLedger : MoveHistory.ResourceLedger := MoveHistory.ResourceLedger.oneEach 0
private def fallbackRemaining : MoveHistory.ResourceLedger :=
  { fallbackLedger with tmCopies :=
      ((((fallbackLedger.tmCopies.modify 4 (fun copies => copies - 1)).modify 11
        (fun copies => copies - 1)).modify 17 (fun copies => copies - 1)).modify 25
        (fun copies => copies - 1)) }
private def fallbackMon : MonState :=
  let mon := MoveHistory.acquire fallbackOrigin
  let move1 := MoveHistory.machineMove fallbackMachine1
  let move2 := MoveHistory.machineMove fallbackMachine2
  let move3 := MoveHistory.machineMove fallbackMachine3
  let move4 := MoveHistory.machineMove fallbackMachine4
  { mon with
    moves := (((mon.moves.modify 0 (fun _ => move1)).modify 1 (fun _ => move2)).modify 2
      (fun _ => move3)).modify 3 (fun _ => move4)
    pp := (((mon.pp.modify 0 (fun _ => movePP move1)).modify 1 (fun _ => movePP move2)).modify 2
      (fun _ => movePP move3)).modify 3 (fun _ => movePP move4) }
private def fallbackHistory : MoveHistory.TeamHistory :=
  { initialLedger := fallbackLedger, plans := #[fallbackPlan] }

private theorem fallbackPlayable : playable fallbackMon = true := by native_decide
private theorem fallbackProfileReady : profileReady fallbackMon = true := by native_decide
private theorem fallbackLegal :
    teamLegal genDex .canonical #[fallbackMon] = true := by native_decide
private theorem fallbackReplays :
    MoveHistory.replayTeam fallbackHistory = some (#[fallbackMon], fallbackRemaining) := by
  native_decide

private def fallbackSide : ResetSide :=
  { active := fallbackMon
    legal := fallbackLegal
    playableActive := fallbackPlayable
    history := fallbackHistory
    remainingLedger := fallbackRemaining
    historyReplays := fallbackReplays }

/- Rejection-sample a progression-witnessed one-mon team until the restricted
ordinary profile has a usable move. Exhausting the finite generator budget takes
the explicit replayable fallback; it never fabricates a move subset. -/
set_option maxHeartbeats 1000000 in
def sampleSideAttempts : Nat → Rng.LinkRng → ResetSide × Rng.LinkRng × Bool
  | 0, rng => (fallbackSide, rng, true)
  | attempts + 1, rng =>
      let candidate := candidateSide rng
      let team := #[candidate.mon]
      let history : MoveHistory.TeamHistory :=
        { initialLedger := candidate.initialLedger, plans := #[candidate.plan] }
      if profileReady candidate.mon then
        if hp : playable candidate.mon = true then
          if legal : teamLegal genDex .canonical team = true then
            if replayed : MoveHistory.replayTeam history =
                some (team, candidate.remainingLedger) then
              ({ active := candidate.mon, legal, playableActive := hp, history
                 remainingLedger := candidate.remainingLedger
                 historyReplays := replayed }, candidate.rng, false)
            else sampleSideAttempts attempts candidate.rng
          else sampleSideAttempts attempts candidate.rng
        else sampleSideAttempts attempts candidate.rng
      else sampleSideAttempts attempts candidate.rng

def sampleSide (rng : Rng.LinkRng) : ResetSide × Rng.LinkRng × Bool :=
  sampleSideAttempts 8 rng

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

structure PlayerObservation where
  ownSpecies : SpeciesId
  opponentSpecies : SpeciesId
  ownHp : UInt16
  opponentHp : UInt16
  ownMoves : Array MoveId
  ownPp : Array UInt8
  turn : Nat
  terminalWitnessed : Bool
  done : Bool
  deriving Repr, DecidableEq, BEq

/-- A policy action remains the shared battle action type. This profile's
`legalActions` returns only `.fight` constructors. -/
abbrev PolicyAction := Battle.Action

def installReset (player enemy : ResetSide) (repaired : Bool)
    (battleRng : Rng.LinkRng) : State :=
  { playerReset := player
    enemyReset := enemy
    battle := BattleState.start player.active enemy.active battleRng .link
    repairedReset := repaired }

@[simp] theorem installReset_uses_supplied_battle_rng (player enemy : ResetSide)
    (repaired : Bool) (battleRng : Rng.LinkRng) :
    (installReset player enemy repaired battleRng).battle.rng = battleRng := rfl

/-- Dynamically reset both sides from generator entropy while installing a
separate battle RNG. Team sampling can never perturb battle randomness. Both
reset teams carry canonical-legality proofs. -/
def reset (generatorRng battleRng : Rng.LinkRng) : State :=
  let (player, generatorRng, playerRepaired) := sampleSide generatorRng
  let (enemy, _, enemyRepaired) := sampleSide generatorRng
  installReset player enemy (playerRepaired || enemyRepaired) battleRng

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

/-- Player-view projection omits the opponent's moves and PP while retaining
information visible on the battle screen. -/
def observePlayer (state : State) (viewer : Side) : PlayerObservation :=
  let opponent := viewer.other
  { ownSpecies := (state.battle.active viewer).species
    opponentSpecies := (state.battle.active opponent).species
    ownHp := (state.battle.active viewer).hp
    opponentHp := (state.battle.active opponent).hp
    ownMoves := (state.battle.active viewer).moves
    ownPp := (state.battle.active viewer).pp
    turn := state.battle.turn
    terminalWitnessed := state.battle.phase.isTerminal
    done := done state }

@[simp] theorem perfect_observation_exact (state : State) :
    (observe state).playerMoves = state.battle.player.active.moves ∧
      (observe state).enemyMoves = state.battle.enemy.active.moves ∧
      (observe state).playerPp = state.battle.player.active.pp ∧
      (observe state).enemyPp = state.battle.enemy.active.pp := by
  exact ⟨rfl, rfl, rfl, rfl⟩

@[simp] theorem player_observation_exact (state : State) (viewer : Side) :
    let observed := observePlayer state viewer
    observed.ownMoves = (state.battle.active viewer).moves ∧
      observed.ownPp = (state.battle.active viewer).pp := by
  cases viewer <;> exact ⟨rfl, rfl⟩

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

@[simp] theorem reset_player_history_replays (generatorRng battleRng : Rng.LinkRng) :
    let side := (reset generatorRng battleRng).playerReset
    MoveHistory.replayTeam side.history = some (side.team.1, side.remainingLedger) :=
  (reset generatorRng battleRng).playerReset.historyReplays

@[simp] theorem reset_enemy_history_replays (generatorRng battleRng : Rng.LinkRng) :
    let side := (reset generatorRng battleRng).enemyReset
    MoveHistory.replayTeam side.history = some (side.team.1, side.remainingLedger) :=
  (reset generatorRng battleRng).enemyReset.historyReplays

/-- Settling an ending state is the only environment operation that establishes
`done`; the terminal witness is retained unchanged. -/
theorem settle_done {state : State} {terminal : Outcome.BattleTerminal}
    (phase : state.battle.phase = .ending terminal) :
    done (settle state) = true := by
  simp [settle, done, phase]

/-! ## Reset guards -/

private def reset0 : State := reset Rng.seed0 Rng.seed0

#guard teamLegal genDex .canonical reset0.playerReset.team.1
#guard teamLegal genDex .canonical reset0.enemyReset.team.1
#guard playable reset0.playerReset.active
#guard playable reset0.enemyReset.active
#guard (legalActions reset0 .player).size > 0
#guard (legalActions reset0 .enemy).size > 0
#guard !done reset0

end Battle.RL.Environment
