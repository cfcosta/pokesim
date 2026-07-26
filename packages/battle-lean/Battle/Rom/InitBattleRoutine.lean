/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0.
-/
import Battle.Rom.RoutineSummary
import Battle.Rom.Closure

/-! # Supplied-opponent `InitBattle` prefix -/

namespace Battle.Rom.InitBattleRoutine

open Sm83 Battle.Rom.Closure

private def entry : Word := Symbols.initBattle.address
private def suppliedEntry : Word := Symbols.initOpponent.address
private def opponentAddress : Word := 0xD059
private def sentinel : Word := 0x8000
private def stackTop : Word := 0xFFFE

private def code : List Byte := [0xFA, 0x59, 0xD0, 0xA7, 0x28, 0x0B]

private def memory (opponent : Byte) : FlatMemory :=
  let memory := (List.range code.length).foldl (fun memory index =>
    memory.write (Word.ofNat (entry.toNat + index)) (code.getD index 0)) (default : FlatMemory)
  memory.write opponentAddress opponent

private def initial (opponent : Byte) : FunctionalState :=
  Driver.setupCall (memory opponent) (UInt16.ofNat entry.toNat)
    (UInt16.ofNat sentinel.toNat) (UInt16.ofNat stackTop.toNat)

private def run (opponent : Byte) : RoutineSummary.Execution :=
  RoutineSummary.runSteps 3 (initial opponent)

/-- Nonzero supplied opponents take the not-zero branch and arrive exactly at
`InitOpponent` after LD/AND/JR, retaining the opponent byte in A. -/
theorem supplied_opponent_reaches_initOpponent : ∀ opponent : Byte,
    opponent ≠ 0 →
    (run opponent).state.registers.pc = suppliedEntry ∧
      (run opponent).state.registers.a = opponent ∧
      (run opponent).state.mode = .running := by
  native_decide

inductive InitBattleDecision where
  | suppliedOpponent
  | determineWildOpponent
  deriving Repr, DecidableEq, BEq

def decision (opponent : Byte) : InitBattleDecision :=
  if opponent == 0 then .determineWildOpponent else .suppliedOpponent

@[simp] theorem no_encounter_path_is_not_completion :
    decision 0 = .determineWildOpponent ∧ decision 1 = .suppliedOpponent := by
  native_decide

structure RequiredInitBattleBytes (rom : Array Byte) : Prop where
  entryBytes : bytesAt rom Symbols.initBattle.offset code.length = code


theorem canonical_prefix_exact {rom : Array Byte}
    (required : RequiredInitBattleBytes rom) :
    bytesAt rom Symbols.initBattle.offset 6 = [0xFA, 0x59, 0xD0, 0xA7, 0x28, 0x0B] :=
  required.entryBytes

end Battle.Rom.InitBattleRoutine
