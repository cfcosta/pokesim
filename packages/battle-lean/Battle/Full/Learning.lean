/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Full.Progression
import Battle.Data.Moves

/-!
# Nested move-learning protocol

The menu interaction is an explicit state machine. Full move sets require the
try/forget/abandon dialogue; HM deletion rejection and cancellation cannot be
collapsed into a policy default.
-/

namespace Battle.Full.Learning

inductive Prompt where
  | tryToLearn
  | chooseMoveToForget
  | confirmAbandon
  deriving Repr, DecidableEq, BEq

inductive Response where
  | yes | no | select (slot : Fin 4) | cancel
  deriving Repr, DecidableEq

inductive Event where
  | alreadyKnown
  | learned (move : MoveId) (slot : Fin 4)
  | hmCannotDelete (move : MoveId)
  | abandoned (move : MoveId)
  deriving Repr, DecidableEq

inductive Phase where
  | awaiting (prompt : Prompt)
  | completed (learned : Bool)
  deriving Repr, DecidableEq

structure Machine where
  mon : Progression.PersistentMon
  move : MoveId
  phase : Phase
  events : List Event := []
  deriving Repr, DecidableEq

/-- Gen-I HMs cannot be deleted by the learning menu. -/
def isHm (move : MoveId) : Bool := [15, 19, 57, 70, 148].contains move

private def basePp (move : MoveId) : UInt8 := (Data.moveData move).pp

private def replace (machine : Machine) (slot : Fin 4) : Machine :=
  let battle := machine.mon.battle
  let battle := { battle with
    moves := battle.moves.modify slot.val (fun _ => machine.move)
    pp := battle.pp.modify slot.val (fun _ => basePp machine.move) }
  { machine with
    mon := { machine.mon with battle := battle },
    phase := .completed true,
    events := machine.events ++ [.learned machine.move slot] }

private def emptySlot? (moves : Array MoveId) : Option (Fin 4) :=
  if moves.getD 0 0 == 0 then some 0
  else if moves.getD 1 0 == 0 then some 1
  else if moves.getD 2 0 == 0 then some 2
  else if moves.getD 3 0 == 0 then some 3
  else none

/-- Begin `LearnMove`. Duplicate moves are ignored; an empty slot is filled
without a policy request. -/
def start (mon : Progression.PersistentMon) (move : MoveId) : Machine :=
  if mon.battle.moves.contains move then
    { mon, move, phase := .completed false, events := [.alreadyKnown] }
  else
    let machine : Machine := { mon, move, phase := .awaiting .tryToLearn }
    match emptySlot? mon.battle.moves with
    | some slot => replace machine slot
    | none => machine

/-- Consume one matching nested response. `none` is protocol-invalid and leaves
no invented cartridge transition. -/
def respond (machine : Machine) (response : Response) : Option Machine :=
  match machine.phase with
  | .completed _ => none
  | .awaiting .tryToLearn =>
      match response with
      | .yes => some { machine with phase := .awaiting .chooseMoveToForget }
      | .no | .cancel => some { machine with phase := .awaiting .confirmAbandon }
      | .select _ => none
  | .awaiting .chooseMoveToForget =>
      match response with
      | .select slot =>
          let oldMove := machine.mon.battle.moves.getD slot.val 0
          if isHm oldMove then
            some { machine with events := machine.events ++ [.hmCannotDelete oldMove] }
          else some (replace machine slot)
      | .cancel => some { machine with phase := .awaiting .confirmAbandon }
      | _ => none
  | .awaiting .confirmAbandon =>
      match response with
      | .yes => some { machine with
          phase := .completed false,
          events := machine.events ++ [.abandoned machine.move] }
      | .no | .cancel => some { machine with phase := .awaiting .tryToLearn }
      | .select _ => none

private def testBattleMon : MonState :=
  { species := 6, hp := 100, boxLevel := 50, status := 0
    type1 := 0x14, type2 := 0x02, catchRate := 45
    moves := #[52, 0, 0, 0], dvs := 0xffff, level := 50
    maxHp := 100, attack := 80, defense := 70, speed := 100, special := 90
    pp := #[15, 0, 0, 0] }

private def testMon : Progression.PersistentMon :=
  { battle := testBattleMon
    otId := 1
    experience := 0
    statExp := { hp := 0, attack := 0, defense := 0, speed := 0, special := 0 } }

/-- Empty slots learn immediately with base PP. -/
theorem empty_slot_learns_immediately : (start testMon 33).phase = .completed true := by native_decide

/-- HM rejection stays at the forget prompt. -/
theorem hm_rejection_reprompts :
    let full := { testMon with battle := { testMon.battle with
      moves := #[15, 33, 34, 35], pp := #[30, 35, 15, 15] } }
    let machine? := respond (start full 36) .yes
    machine?.bind (fun machine => (respond machine (.select 0)).map Machine.phase) =
      some (.awaiting .chooseMoveToForget) := by native_decide

/-- Declining abandonment restarts the original dialogue. -/
theorem abandon_decline_restarts :
    let full := { testMon with battle := { testMon.battle with
      moves := #[1, 2, 3, 4], pp := #[1, 1, 1, 1] } }
    let confirm? := respond (start full 36) .no
    confirm?.bind (fun confirm => (respond confirm .no).map Machine.phase) =
      some (.awaiting .tryToLearn) := by native_decide

end Battle.Full.Learning
