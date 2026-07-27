/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0.
-/
import Battle.Full.Engine
import Battle.RL.Generator

/-!
# Compact Gen-I 1v1 replay reconstructions

Three public Pokémon Showdown replay projections are reconstructed without
vendoring their logs. The source records expose species, selected moves,
percentage HP, order, side effects, and winner, but not exact DVs/stat experience,
full sets, or simulator RNG. These fixtures therefore use an explicit max-DV,
max-stat-experience profile and searched link-RNG witnesses. They prove concrete
model executions, not equivalence to Pokémon Showdown or to the source records.
-/

namespace Battle.RL.ReplayExamples

open Battle.Full

/-- Level-100 competitive profile selected for replay reconstruction. Hidden
Showdown team stats are unavailable in the source dataset. -/
def competitiveMon (species : SpeciesId) (moves : Array MoveId) : MonState :=
  let entry := speciesEntry species
  let base := genMon entry 100 15 15 15 15 4
  let stat := fun value => calcStat value 15 100 65535 false
  let hp := calcStat entry.baseHp 15 100 65535 true
  { base with
    hp := hp
    maxHp := hp
    attack := stat entry.baseAtk
    defense := stat entry.baseDef
    speed := stat entry.baseSpd
    special := stat entry.baseSpc
    moves := padTo Wram.numMoves 0 moves
    pp := padTo Wram.numMoves 0 (moves.map movePP) }

/-- A deterministic ten-byte search family. It is an explicit fixture witness,
not a claim about Pokémon Showdown's PRNG. -/
def probeRng (seed : Nat) : Rng.LinkRng :=
  { list := (List.range Wram.serialRnsLength).map (fun index =>
      let low := seed % 256
      let high := seed / 256
      (low * 73 + high * (index * 29 + 1) + index * 41 + 17).toUInt8) |>.toArray
    index := 0 }

/-- One-member link duel. No processor or cartridge execution occurs here. -/
def duel (player enemy : MonState) (rng : Rng.LinkRng) : Engine.State :=
  let playerSide := Full.SideState.fromParty { mons := #[player] } player
  let enemySide := Full.SideState.fromParty { mons := #[enemy] } enemy
  let battle : Full.State :=
    { player := playerSide, enemy := enemySide, rng := rng, turn := 0
      mode := .link, phase := .battling }
  { battle := battle }

private def firstActor : List Engine.Event → Option Side
  | .action side _ :: _ => some side
  | _ :: tail => firstActor tail
  | [] => none

private def criticalRaws : List Engine.Event → List UInt8
  | .rng "critical" raw :: tail => raw :: criticalRaws tail
  | _ :: tail => criticalRaws tail
  | [] => []

private def hasSecondary : List Engine.Event → Bool
  | .effect (.statusApplied _) :: _ => true
  | .effect (.stageChanged _ _ _) :: _ => true
  | _ :: tail => hasSecondary tail
  | [] => false

structure TurnProjection where
  playerHp : UInt16
  enemyHp : UInt16
  playerStatus : UInt8
  enemyStatus : UInt8
  firstActor : Option Side
  criticalRaws : List UInt8
  secondary : Bool
  terminal : Bool
  deriving Repr, DecidableEq, BEq

structure TwoTurnProjection where
  first : TurnProjection
  second : TurnProjection
  deriving Repr, DecidableEq, BEq

private def project (state : Engine.State) (events : List Engine.Event) : TurnProjection :=
  { playerHp := state.battle.player.active.active.hp
    enemyHp := state.battle.enemy.active.active.hp
    playerStatus := state.battle.player.active.active.status
    enemyStatus := state.battle.enemy.active.active.status
    firstActor := firstActor events
    criticalRaws := criticalRaws events
    secondary := hasSecondary events
    terminal := state.battle.phase.isTerminal }

/-- Execute exactly two selected action pairs and retain the observable mechanics
projection used by the reconstruction report. -/
def runTwo (state : Engine.State)
    (player1 enemy1 player2 enemy2 : Full.Action) : Option TwoTurnProjection := do
  let (after1, events1) ← match Engine.step state player1 enemy1 with
    | .transitioned state events => some (state, events)
    | _ => none
  let (after2, events2) ← match Engine.step after1 player2 enemy2 with
    | .transitioned state events => some (state, events)
    | _ => none
  pure { first := project after1 events1, second := project after2 events2 }

/-- `gen11v1-2115019340`: Starmie mirror, Thunderbolt/Thunderbolt followed by
Thunderbolt into the already weakened enemy. -/
def starmieMirror : Option TwoTurnProjection :=
  let starmie := competitiveMon 0x98 #[85]
  runTwo (duel starmie starmie (probeRng 44737))
    (.fight 0) (.fight 0) (.fight 0) (.fight 0)

@[simp] theorem starmie_mirror_exact : starmieMirror = some
    { first :=
        { playerHp := 171, enemyHp := 48, playerStatus := 0, enemyStatus := 0
          firstActor := some .enemy, criticalRaws := [167, 68]
          secondary := false, terminal := false }
      second :=
        { playerHp := 171, enemyHp := 0, playerStatus := 0, enemyStatus := 0
          firstActor := some .player, criticalRaws := [227]
          secondary := false, terminal := true } } := by
  native_decide

@[simp] theorem starmie_critical_pattern_exact :
    !Critical.occurs (Critical.threshold 0x98 85) 167 ∧
      Critical.occurs (Critical.threshold 0x98 85) 68 ∧
      Critical.occurs (Critical.threshold 0x98 85) 227 := by
  native_decide

/-- `gen11v1-2134948894`: Tauros uses Body Slam before Slowbro's Surf; on turn
two a second Body Slam is returned by Counter for the knockout. -/
def slowbroTaurosCounter : Option TwoTurnProjection :=
  let slowbro := competitiveMon 0x08 #[57, 68]
  let tauros := competitiveMon 0x3c #[34]
  runTwo (duel slowbro tauros (probeRng 340))
    (.fight 0) (.fight 0) (.fight 1) (.fight 0)

@[simp] theorem slowbro_tauros_counter_exact : slowbroTaurosCounter = some
    { first :=
        { playerHp := 209, enemyHp := 237, playerStatus := 0, enemyStatus := 0
          firstActor := some .enemy, criticalRaws := [6, 245]
          secondary := false, terminal := false }
      second :=
        { playerHp := 32, enemyHp := 0, playerStatus := 0, enemyStatus := 0
          firstActor := some .enemy, criticalRaws := [33, 67]
          secondary := false, terminal := true } } := by
  native_decide

@[simp] theorem slowbro_tauros_critical_pattern_exact :
    Critical.occurs (Critical.threshold 0x3c 34) 6 ∧
      !Critical.occurs (Critical.threshold 0x08 57) 245 ∧
      Critical.occurs (Critical.threshold 0x3c 34) 33 := by
  native_decide

/-- `gen11v1-2134954677`: Alakazam's Psychic nearly defeats Machamp, Earthquake
lands in reply, and the second Psychic ends the duel. -/
def machampAlakazam : Option TwoTurnProjection :=
  let machamp := competitiveMon 0x7e #[89]
  let alakazam := competitiveMon 0x95 #[94]
  runTwo (duel machamp alakazam (probeRng 288))
    (.fight 0) (.fight 0) (.fight 0) (.fight 0)

@[simp] theorem machamp_alakazam_exact : machampAlakazam = some
    { first :=
        { playerHp := 14, enemyHp := 167, playerStatus := 0, enemyStatus := 0
          firstActor := some .enemy, criticalRaws := [50, 21]
          secondary := false, terminal := false }
      second :=
        { playerHp := 0, enemyHp := 167, playerStatus := 0, enemyStatus := 0
          firstActor := some .enemy, criticalRaws := [141]
          secondary := false, terminal := true } } := by
  native_decide

@[simp] theorem machamp_alakazam_critical_pattern_exact :
    !Critical.occurs (Critical.threshold 0x95 94) 50 ∧
      !Critical.occurs (Critical.threshold 0x7e 89) 21 ∧
      !Critical.occurs (Critical.threshold 0x95 94) 141 := by
  native_decide

/-- All three compact reconstructions execute two turns, avoid unobserved
secondary statuses/stat changes, and reach the same winning side as their source
projections. -/
@[simp] theorem compact_replay_examples_complete :
    starmieMirror.isSome = true ∧ slowbroTaurosCounter.isSome = true ∧
      machampAlakazam.isSome = true := by
  simp

end Battle.RL.ReplayExamples
