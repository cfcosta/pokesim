import Battle.Full.Environment
import Battle.RL.Training

open Battle
open Battle.Full

/-- Controlled mechanics states: Metronome is faster than ordinary enemy Agility.
Uniform RNG bytes choose the requested generated move without speed ties. -/
private def fixture (draw : UInt8) (mode : BattleMode := .link)
    (wrapper : MoveId := 118) : Engine.State :=
  let outer := Environment.resetSized 2
    (RL.Training.linkRng 1 1 RL.Training.generatorStream)
    (RL.Training.linkRng 1 1 RL.Training.battleStream) mode
  let player := { outer.engine.battle.player.active.active with
    moves := #[wrapper, 0, 0, 0], pp := #[20, 0, 0, 0]
    hp := 200, maxHp := 200, speed := 200, status := 0 }
  let enemy := { outer.engine.battle.enemy.active.active with
    moves := #[97, 0, 0, 0], pp := #[20, 0, 0, 0]
    hp := 200, maxHp := 200, speed := 100, status := 0 }
  let playerSide := { outer.engine.battle.player with
    active := Battle.SideState.fresh player
    party := { mons := #[player, player] }, activeIndex := 0 }
  let enemySide := { outer.engine.battle.enemy with
    active := Battle.SideState.fresh enemy
    party := { mons := #[enemy, enemy] }, activeIndex := 0 }
  { outer.engine with battle := { outer.engine.battle with
      player := playerSide, enemy := enemySide, turn := 5
      rng := { list := Array.replicate 10 draw, index := 0 } } }

private def completeAgility (result : Engine.StepResult) : Bool :=
  match result with
  | .transitioned state events =>
      state.battle.turn == 6 &&
      state.battle.player.active.stages.speed == 9 &&
      state.battle.enemy.active.stages.speed == 9 &&
      state.battle.player.active.active.pp[0]! == 19 &&
      state.battle.enemy.active.active.pp[0]! == 19 &&
      (events.filter (· == .action .enemy (.fight 0))).length == 1
  | _ => false

-- Metronome completes its generated Agility, then the already committed enemy
-- Agility, and increments the outer turn exactly once.
#guard match Engine.step (fixture 97) (.fight 0) (.fight 0) with
  | .nestedMove state .player move next _ =>
      move == 97 && next == some (.fight 0) &&
      completeAgility (Engine.resumeNested state .player move next)
  | _ => false

-- Mirror Move copies the enemy's previous Metronome, which generates Agility.
-- Both nested boundaries must retain the same unexecuted enemy action.
#guard match Engine.step { fixture 97 .link 119 with enemyLastMove := 118 }
    (.fight 0) (.fight 0) with
  | .nestedMove state .player move next _ =>
      move == 118 && next == some (.fight 0) &&
      match Engine.resumeNested state .player move next with
      | .nestedMove state .player generated next _ =>
          generated == 97 && next == some (.fight 0) &&
          completeAgility (Engine.resumeNested state .player generated next)
      | _ => false
  | _ => false

-- Outside link battles, generated Mimic opens an explicit menu. The opponent
-- waits until the chosen target is supplied, then acts once and finishes turn6.
#guard match Engine.step (fixture 102 .trainer) (.fight 0) (.fight 0) with
  | .nestedMove state .player move next _ =>
      move == 102 && next == some (.fight 0) &&
      match Engine.resumeNested state .player move next with
      | .mimicPending state .player source next _ =>
          source == 0 && next == some (.fight 0) && state.battle.turn == 5 &&
          state.battle.enemy.active.active.pp[0]! == 20 &&
          match Engine.resumeMimic state .player source 0 next with
          | .transitioned state events =>
              state.battle.turn == 6 &&
              state.battle.player.active.active.moves[0]! == 97 &&
              state.battle.player.active.active.pp[0]! == 19 &&
              -- Cartridge nonlink opponents do not consume PP.
              state.battle.enemy.active.active.pp[0]! == 20 &&
              state.battle.enemy.active.stages.speed == 9 &&
              (events.filter (· == .action .enemy (.fight 0))).length == 1
          | _ => false
      | _ => false
  | _ => false

-- A generated self-KO interrupts the pending opponent action at the same faint
-- boundary as an ordinary first action; it must remain a forced replacement.
#guard match Engine.step (fixture 153) (.fight 0) (.fight 0) with
  | .nestedMove state .player move next _ =>
      move == 153 && next == some (.fight 0) &&
      match Engine.resumeNested state .player move next with
      | .transitioned state events =>
          state.forcedReplacement.isSome && state.battle.turn == 5 &&
          state.battle.enemy.active.active.pp[0]! == 20 &&
          (events.filter (· == .action .enemy (.fight 0))).isEmpty
      | _ => false
  | _ => false
