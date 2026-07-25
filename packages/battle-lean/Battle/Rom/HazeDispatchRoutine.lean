/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Rom.HazeRoutine

/-!
# Decoded Haze effect dispatch

This module decodes `_JumpMoveEffect` for effect ID `$19`. Player and enemy
selection differ by one `LD A,[a16]`; both paths compute zero-based slot `$18`,
scale it to byte offset `$30`, read the little-endian pointer, and jump to the
byte-certified Haze wrapper at `$7B1E`.

The later `Bankswitch` transition remains in the Game Boy adapter boundary,
because a flat architectural memory write to `$2000` is not itself an MBC bank
mapping theorem.
-/

namespace Battle.Rom.HazeDispatchRoutine

open Sm83 Battle.Rom.Closure

private def outerEntry : UInt16 := 0x7132
private def outerBytes : List Byte := [0xCD, 0x38, 0x71, 0x06, 0x01, 0xC9]
private def entry : UInt16 := 0x7138
private def dispatchBytes : List Byte :=
  [0xF0, 0xF3, 0xA7, 0xFA, 0xD3, 0xCF, 0x28, 0x03,
   0xFA, 0xCD, 0xCF, 0x3D, 0x87, 0x21, 0x50, 0x71,
   0x06, 0x00, 0x4F, 0x09, 0x2A, 0x66, 0x6F, 0xE9]

private theorem oneStep {state out : FunctionalState}
    (step : (Functional.step state).state = out) :
    (RoutineSummary.runSteps 1 state).state = out := by
  simpa [RoutineSummary.runSteps] using step

/-! ## Common pointer tail -/

def tail1 (s : FunctionalState) := RoutineSummary.decA s
def tail2 (s : FunctionalState) := RoutineSummary.addA (tail1 s)
def tail3 (s : FunctionalState) := RoutineSummary.ldHlImmediate (tail2 s)
def tail4 (s : FunctionalState) := RoutineSummary.ldBImmediate (tail3 s)
def tail5 (s : FunctionalState) := RoutineSummary.ldCFromA (tail4 s)
def tail6 (s : FunctionalState) := RoutineSummary.addHlBc (tail5 s)
def tail7 (s : FunctionalState) := RoutineSummary.ldAFromHlInc (tail6 s)
def tail8 (s : FunctionalState) := RoutineSummary.ldHAtHl (tail7 s)
def tail9 (s : FunctionalState) := RoutineSummary.ldLFromA (tail8 s)
def dispatchTarget (s : FunctionalState) := RoutineSummary.jpHl (tail9 s)

structure DispatchTailContract (state : FunctionalState) : Prop where
  effect19 : state.registers.a = 0x19
  q0 : RoutineSummary.Quiet state
  op3d : state.memory.read state.registers.pc = 0x3D
  q1 : RoutineSummary.Quiet (tail1 state)
  op87 : (tail1 state).memory.read (tail1 state).registers.pc = 0x87
  q2 : RoutineSummary.Quiet (tail2 state)
  op21 : (tail2 state).memory.read (tail2 state).registers.pc = 0x21
  q3 : RoutineSummary.Quiet (tail3 state)
  op06 : (tail3 state).memory.read (tail3 state).registers.pc = 0x06
  q4 : RoutineSummary.Quiet (tail4 state)
  op4f : (tail4 state).memory.read (tail4 state).registers.pc = 0x4F
  q5 : RoutineSummary.Quiet (tail5 state)
  op09 : (tail5 state).memory.read (tail5 state).registers.pc = 0x09
  q6 : RoutineSummary.Quiet (tail6 state)
  op2a : (tail6 state).memory.read (tail6 state).registers.pc = 0x2A
  q7 : RoutineSummary.Quiet (tail7 state)
  op66 : (tail7 state).memory.read (tail7 state).registers.pc = 0x66
  q8 : RoutineSummary.Quiet (tail8 state)
  op6f : (tail8 state).memory.read (tail8 state).registers.pc = 0x6F
  q9 : RoutineSummary.Quiet (tail9 state)
  opE9 : (tail9 state).memory.read (tail9 state).registers.pc = 0xE9
  tableLow : (tail2 state).memory.read
    (Word.ofNat ((tail2 state).registers.pc.toNat + 1)) = 0x50
  tableHigh : (tail2 state).memory.read
    (Word.ofNat ((tail2 state).registers.pc.toNat + 2)) = 0x71
  zeroB : (tail3 state).memory.read
    (Word.ofNat ((tail3 state).registers.pc.toNat + 1)) = 0x00
  pointerLow : (tail6 state).memory.read (tail6 state).registers.hl = 0x1E
  pointerHigh : (tail7 state).memory.read (tail7 state).registers.hl = 0x7B

/-- Ten decoded instructions turn effect `$19` into pointer-table byte offset
`$30` and jump through the little-endian slot to `$7B1E`. -/
theorem dispatch_tail_exact (state : FunctionalState)
    (contract : DispatchTailContract state) :
    (RoutineSummary.runSteps 10 state).state = dispatchTarget state ∧
    (tail2 state).registers.a = 0x30 ∧
    (tail3 state).registers.hl = 0x7150 ∧
    (tail6 state).registers.hl = 0x7180 ∧
    (dispatchTarget state).registers.pc = 0x7B1E := by
  have a := oneStep (RoutineSummary.step_decA state contract.q0.1
    contract.q0.2.2 contract.q0.2.1 contract.op3d)
  have b := oneStep (RoutineSummary.step_addA (tail1 state) contract.q1.1
    contract.q1.2.2 contract.q1.2.1 contract.op87)
  have c := oneStep (RoutineSummary.step_ldHlImmediate (tail2 state) contract.q2.1
    contract.q2.2.2 contract.q2.2.1 contract.op21)
  have d := oneStep (RoutineSummary.step_ldBImmediate (tail3 state) contract.q3.1
    contract.q3.2.2 contract.q3.2.1 contract.op06)
  have e := oneStep (RoutineSummary.step_ldCFromA (tail4 state) contract.q4.1
    contract.q4.2.2 contract.q4.2.1 contract.op4f)
  have f := oneStep (RoutineSummary.step_addHlBc (tail5 state) contract.q5.1
    contract.q5.2.2 contract.q5.2.1 contract.op09)
  have g := oneStep (RoutineSummary.step_ldAFromHlInc (tail6 state) contract.q6.1
    contract.q6.2.2 contract.q6.2.1 contract.op2a)
  have h := oneStep (RoutineSummary.step_ldHAtHl (tail7 state) contract.q7.1
    contract.q7.2.2 contract.q7.2.1 contract.op66)
  have i := oneStep (RoutineSummary.step_ldLFromA (tail8 state) contract.q8.1
    contract.q8.2.2 contract.q8.2.1 contract.op6f)
  have j := oneStep (RoutineSummary.step_jpHl (tail9 state) contract.q9.1
    contract.q9.2.2 contract.q9.2.1 contract.opE9)
  have ab := RoutineSummary.runSteps_state_add 1 1 state (tail1 state) (tail2 state) a b
  have abc := RoutineSummary.runSteps_state_add 2 1 state (tail2 state) (tail3 state)
    (by simpa using ab) c
  have abcd := RoutineSummary.runSteps_state_add 3 1 state (tail3 state) (tail4 state)
    (by simpa using abc) d
  have abcde := RoutineSummary.runSteps_state_add 4 1 state (tail4 state) (tail5 state)
    (by simpa using abcd) e
  have abcdef := RoutineSummary.runSteps_state_add 5 1 state (tail5 state) (tail6 state)
    (by simpa using abcde) f
  have abcdefg := RoutineSummary.runSteps_state_add 6 1 state (tail6 state) (tail7 state)
    (by simpa using abcdef) g
  have abcdefgh := RoutineSummary.runSteps_state_add 7 1 state (tail7 state) (tail8 state)
    (by simpa using abcdefg) h
  have abcdefghi := RoutineSummary.runSteps_state_add 8 1 state (tail8 state) (tail9 state)
    (by simpa using abcdefgh) i
  have all := RoutineSummary.runSteps_state_add 9 1 state (tail9 state)
    (dispatchTarget state) (by simpa using abcdefghi) j
  have slotOffset : (tail2 state).registers.a = 0x30 := by
    simp [tail2, tail1, RoutineSummary.addA, RoutineSummary.decA,
      RoutineSummary.advancePc, Registers.set8, contract.effect19, Alu.apply,
      Alu.dec8, Alu.add8]
    native_decide
  have tableBase : (tail3 state).registers.hl = 0x7150 := by
    simp [tail3, RoutineSummary.ldHlImmediate, RoutineSummary.immediateWord,
      contract.tableLow, contract.tableHigh, RoutineSummary.increment_twice,
      Registers.setHL, Registers.hl]
    native_decide
  have bZero : (tail4 state).registers.b = 0x00 := by
    simp [tail4, RoutineSummary.ldBImmediate, contract.zeroB, Registers.set8]
  have aOffset : (tail4 state).registers.a = 0x30 := by
    simpa [tail4, RoutineSummary.ldBImmediate, Registers.set8] using slotOffset
  have bcOffset : (tail5 state).registers.bc = 0x0030 := by
    simp [tail5, RoutineSummary.ldCFromA, RoutineSummary.advancePc,
      Registers.set8, Registers.bc, bZero, aOffset]
    native_decide
  have hlBase : (tail5 state).registers.hl = 0x7150 := by
    simpa [tail5, tail4, RoutineSummary.ldCFromA, RoutineSummary.ldBImmediate,
      RoutineSummary.advancePc, Registers.set8, Registers.hl] using tableBase
  have slotAddress : (tail6 state).registers.hl = 0x7180 := by
    simp [tail6, RoutineSummary.addHlBc, RoutineSummary.advancePc,
      Registers.setHL, Registers.hl, bcOffset, Alu.addHL]
    change Word.ofNat ((tail5 state).registers.hl.toNat + 48) = 0x7180
    rw [hlBase]
    native_decide
  have lowByte : (tail6 state).memory.read
      (Word.ofBytes (tail6 state).registers.h (tail6 state).registers.l) = 0x1E := by
    simpa only [Registers.hl] using contract.pointerLow
  have highByte : (tail6 state).memory.read
      (Word.ofNat ((Word.ofBytes (tail6 state).registers.h
        (tail6 state).registers.l).toNat + 1)) = 0x7B := by
    simpa [tail7, RoutineSummary.ldAFromHlInc, RoutineSummary.advancePc,
      Registers.setHL, Registers.hl] using contract.pointerHigh
  have pointerTarget : (dispatchTarget state).registers.pc = 0x7B1E := by
    simp [dispatchTarget, tail9, tail8, tail7, RoutineSummary.jpHl,
      RoutineSummary.ldLFromA, RoutineSummary.ldHAtHl,
      RoutineSummary.ldAFromHlInc, RoutineSummary.advancePc, Registers.set8,
      Registers.setHL, Registers.hl]
    rw [lowByte, highByte]
    native_decide
  exact ⟨all, slotOffset, tableBase, slotAddress, pointerTarget⟩

/-! ## Player and enemy selectors -/

def select1 (s : FunctionalState) := RoutineSummary.ldhAImmediate s
def select2 (s : FunctionalState) := RoutineSummary.andA (select1 s)
def select3 (s : FunctionalState) := RoutineSummary.ldAAbsolute (select2 s)
def select4 (s : FunctionalState) := RoutineSummary.jrZ (select3 s)
def selectEnemy (s : FunctionalState) := RoutineSummary.ldAAbsolute (select4 s)

structure DispatchSelectContract (state : FunctionalState) : Prop where
  q0 : RoutineSummary.Quiet state
  opF0 : state.memory.read state.registers.pc = 0xF0
  turnOffset : state.memory.read (Word.ofNat (state.registers.pc.toNat + 1)) = 0xF3
  q1 : RoutineSummary.Quiet (select1 state)
  opA7 : (select1 state).memory.read (select1 state).registers.pc = 0xA7
  q2 : RoutineSummary.Quiet (select2 state)
  opFa : (select2 state).memory.read (select2 state).registers.pc = 0xFA
  q3 : RoutineSummary.Quiet (select3 state)
  op28 : (select3 state).memory.read (select3 state).registers.pc = 0x28
  jumpOffset : (select3 state).memory.read
    (Word.ofNat ((select3 state).registers.pc.toNat + 1)) = 0x03

private theorem select_common_exact (state : FunctionalState)
    (contract : DispatchSelectContract state) :
    (RoutineSummary.runSteps 4 state).state = select4 state := by
  have a := oneStep (RoutineSummary.step_ldhAImmediate state contract.q0.1
    contract.q0.2.2 contract.q0.2.1 contract.opF0)
  have b := oneStep (RoutineSummary.step_andA (select1 state) contract.q1.1
    contract.q1.2.2 contract.q1.2.1 contract.opA7)
  have c := oneStep (RoutineSummary.step_ldAAbsolute (select2 state) contract.q2.1
    contract.q2.2.2 contract.q2.2.1 contract.opFa)
  have d := oneStep (RoutineSummary.step_jrZ (select3 state) contract.q3.1
    contract.q3.2.2 contract.q3.2.1 contract.op28)
  have ab := RoutineSummary.runSteps_state_add 1 1 state (select1 state) (select2 state) a b
  have abc := RoutineSummary.runSteps_state_add 2 1 state (select2 state) (select3 state)
    (by simpa using ab) c
  exact RoutineSummary.runSteps_state_add 3 1 state (select3 state) (select4 state)
    (by simpa using abc) d

structure PlayerDispatchContract (state : FunctionalState) extends
    DispatchSelectContract state where
  playerTurn : Alu.conditionHolds .z (select3 state).registers.flags = true
  tail : DispatchTailContract (select4 state)

/-- Player effect `$19` takes fourteen decoded instructions from
`_JumpMoveEffect` to the Haze wrapper. -/
theorem player_haze_dispatch_exact (state : FunctionalState)
    (contract : PlayerDispatchContract state) :
    (RoutineSummary.runSteps 14 state).state = dispatchTarget (select4 state) ∧
    (dispatchTarget (select4 state)).registers.pc = 0x7B1E := by
  have selectedPrefix := select_common_exact state contract.toDispatchSelectContract
  have tail := (dispatch_tail_exact (select4 state) contract.tail).1
  exact ⟨RoutineSummary.runSteps_state_add 4 10 state (select4 state)
    (dispatchTarget (select4 state)) selectedPrefix tail,
    (dispatch_tail_exact (select4 state) contract.tail).2.2.2.2⟩

structure EnemyDispatchContract (state : FunctionalState) extends
    DispatchSelectContract state where
  enemyTurn : Alu.conditionHolds .z (select3 state).registers.flags = false
  q4 : RoutineSummary.Quiet (select4 state)
  opFaEnemy : (select4 state).memory.read (select4 state).registers.pc = 0xFA
  tail : DispatchTailContract (selectEnemy state)

/-- Enemy effect `$19` executes its extra effect-byte load and reaches the same
wrapper in fifteen decoded instructions. -/
theorem enemy_haze_dispatch_exact (state : FunctionalState)
    (contract : EnemyDispatchContract state) :
    (RoutineSummary.runSteps 15 state).state = dispatchTarget (selectEnemy state) ∧
    (dispatchTarget (selectEnemy state)).registers.pc = 0x7B1E := by
  have selectedPrefix := select_common_exact state contract.toDispatchSelectContract
  have enemyLoad := oneStep (RoutineSummary.step_ldAAbsolute (select4 state) contract.q4.1
    contract.q4.2.2 contract.q4.2.1 contract.opFaEnemy)
  have selected := RoutineSummary.runSteps_state_add 4 1 state (select4 state)
    (selectEnemy state) selectedPrefix enemyLoad
  have tail := (dispatch_tail_exact (selectEnemy state) contract.tail).1
  exact ⟨RoutineSummary.runSteps_state_add 5 10 state (selectEnemy state)
    (dispatchTarget (selectEnemy state)) (by simpa using selected) tail,
    (dispatch_tail_exact (selectEnemy state) contract.tail).2.2.2.2⟩

/-! ## JumpMoveEffect return shell -/

def jumpEffectCall (s : FunctionalState) := RoutineSummary.callAbsolute s
def jumpEffectFlag (s : FunctionalState) := RoutineSummary.ldBImmediate s
def jumpEffectReturn (s : FunctionalState) := RoutineSummary.ret (jumpEffectFlag s)

/-- The body reached through `_JumpMoveEffect` includes bank switching,
`HazeEffect_`, animation, and text. It remains an explicit exact-count execution
summary at this boundary. -/
structure JumpMoveEffectReturnContract (state returned : FunctionalState) (count : Nat) : Prop where
  q0 : RoutineSummary.Quiet state
  opCall : state.memory.read state.registers.pc = 0xCD
  bodyExecution : (RoutineSummary.runSteps count (jumpEffectCall state)).state = returned
  returnedQuiet : RoutineSummary.Quiet returned
  op06 : returned.memory.read returned.registers.pc = 0x06
  flagValue : returned.memory.read (Word.ofNat (returned.registers.pc.toNat + 1)) = 0x01
  qFlag : RoutineSummary.Quiet (jumpEffectFlag returned)
  opC9 : (jumpEffectFlag returned).memory.read (jumpEffectFlag returned).registers.pc = 0xC9

/-- Once the explicit Haze body returns, the two decoded outer instructions set
`B = 1` and return to `ExecutePlayerMove`/`ExecuteEnemyMove`. -/
theorem jumpMoveEffect_returns (state returned : FunctionalState) (count : Nat)
    (contract : JumpMoveEffectReturnContract state returned count) :
    (RoutineSummary.runSteps (count + 3) state).state = jumpEffectReturn returned ∧
    (jumpEffectReturn returned).registers.b = 0x01 := by
  have call := oneStep (RoutineSummary.step_callAbsolute state contract.q0.1
    contract.q0.2.2 contract.q0.2.1 contract.opCall)
  have entered := RoutineSummary.runSteps_state_add 1 count state (jumpEffectCall state)
    returned call contract.bodyExecution
  have flag := oneStep (RoutineSummary.step_ldBImmediate returned contract.returnedQuiet.1
    contract.returnedQuiet.2.2 contract.returnedQuiet.2.1 contract.op06)
  have returns := oneStep (RoutineSummary.step_ret (jumpEffectFlag returned) contract.qFlag.1
    contract.qFlag.2.2 contract.qFlag.2.1 contract.opC9)
  have shell := RoutineSummary.runSteps_state_add 1 1 returned (jumpEffectFlag returned)
    (jumpEffectReturn returned) flag returns
  constructor
  · have all := RoutineSummary.runSteps_state_add (1 + count) 2 state returned
      (jumpEffectReturn returned) entered (by simpa using shell)
    simpa [Nat.add_assoc, Nat.add_comm, Nat.add_left_comm] using all
  · simp [jumpEffectReturn, jumpEffectFlag, RoutineSummary.ret,
      RoutineSummary.ldBImmediate, contract.flagValue, Registers.set8]

structure RequiredHazeDispatchBytes (rom : Array Byte) : Prop where
  outerWindow : Tables.tableBytes rom
      (romOffset 0x0F (Word.ofNat outerEntry.toNat)) outerBytes.length =
    outerBytes.map (fun byte => byte.toNat.toUInt8)
  dispatchWindow : Tables.tableBytes rom
      (romOffset 0x0F (Word.ofNat entry.toNat)) dispatchBytes.length =
    dispatchBytes.map (fun byte => byte.toNat.toUInt8)

structure CanonicalHazeDispatchBytes (sha256 : Sha256) (rom : CanonicalRom) : Prop where
  haze : HazeRoutine.CanonicalHazeBytes sha256 rom
  dispatch : RequiredHazeDispatchBytes rom.bytes

/-- Runtime fixture predicate only. -/
def windowAgrees (rom : Array Byte) : Bool :=
  decide (Tables.tableBytes rom (romOffset 0x0F (Word.ofNat outerEntry.toNat))
    outerBytes.length = outerBytes.map (fun byte => byte.toNat.toUInt8)) &&
  decide (Tables.tableBytes rom (romOffset 0x0F (Word.ofNat entry.toNat))
    dispatchBytes.length = dispatchBytes.map (fun byte => byte.toNat.toUInt8))

end Battle.Rom.HazeDispatchRoutine
