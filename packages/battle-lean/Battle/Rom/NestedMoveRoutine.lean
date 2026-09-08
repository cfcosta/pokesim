/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0.
-/
import Battle.Rom.RoutineSummary
import Battle.Rom.Tables
import Battle.Full.Engine
import Sm83.FlatAdapter

/-!
# Nested move continuation follows the cartridge's existing turn-driver frame

These canonical windows establish the control-flow boundary repaired in the
full engine. Mirror Move and Metronome CALL their picker, then JP back into the
same actor's executor; they do not return to the turn driver or select another
opposing move. ExecuteMoveDone RET subsequently consumes the original actor
CALL frame. The turn driver continues with the other committed action, or
returns to MainInBattleLoop after the second action.

Picker implementations and generated move effects are separate routines. The
symbolic JP/RET theorems below apply to arbitrary memory at those return
boundaries. The outer-driver check summarizes presentation, residual, trainer-AI
and end-of-turn helpers explicitly as nonterminal returns preserving selection;
it proves the shell under that contract, not those callees or full-battle
bisimulation. Escape and first-action target faint are checked separately before
any such helper. The model turn counter counts driver reentries; it is not an
invented cartridge WRAM counter.
-/

namespace Battle.Rom.NestedMoveRoutine

open Sm83 Battle.Rom.Closure

structure Window where
  entry : Word
  code : List Byte
  deriving Repr, DecidableEq

private def dispatchWindow (enemy : Bool) : Window :=
  if enemy then
    ⟨0x67EF, [0xFA, 0xCD, 0xCF, 0xFE, 0x09, 0x20, 0x09,
      0xCD, 0xFD, 0x62, 0xCA, 0x8C, 0x68, 0xC3, 0xFC, 0x66,
      0xFE, 0x53, 0x20, 0x06, 0xCD, 0x48, 0x63, 0xC3, 0xFC, 0x66]⟩
  else
    ⟨0x5766, [0xFA, 0xD3, 0xCF, 0xFE, 0x09, 0x20, 0x0D,
      0xCD, 0xFD, 0x62, 0xCA, 0x0A, 0x58, 0xAF, 0xEA, 0xED,
      0xCC, 0xC3, 0x9A, 0x56, 0xFE, 0x53, 0x20, 0x06,
      0xCD, 0x48, 0x63, 0xC3, 0x9A, 0x56]⟩

private def doneWindow (enemy : Bool) : Window :=
  if enemy then ⟨0x688C, [0x06, 0x01, 0xC9]⟩
  else ⟨0x580A, [0xAF, 0xEA, 0x6A, 0xCD, 0x06, 0x01, 0xC9]⟩

/-- The physical pipeline fetches the first instruction after each local
window; certify those actual cartridge opcodes as well as the executed bytes. -/
private def boundaryWindows : List Window :=
  [⟨0x62FD, [0xF0]⟩, ⟨0x6348, [0xAF]⟩,
   ⟨0x569A, [0xFA]⟩, ⟨0x66FC, [0xFA]⟩]

private def driverWindow (enemyFirst : Bool) : Window :=
  if enemyFirst then
    ⟨0x433D, [0x3E, 0x01, 0xE0, 0xF3, 0x21, 0x2E, 0x65,
      0x06, 0x0E, 0xCD, 0xD6, 0x35, 0x38, 0x0D, 0xCD, 0xBC,
      0x66, 0xFA, 0x78, 0xD0, 0xA7, 0xC0, 0x78, 0xA7,
      0xCA, 0x00, 0x47, 0xCD, 0xBD, 0x43, 0xCA, 0x25, 0x45,
      0xCD, 0x5A, 0x4D, 0xCD, 0x5E, 0x56, 0xFA, 0x78, 0xD0,
      0xA7, 0xC0, 0x78, 0xA7, 0xCA, 0x25, 0x45, 0xCD, 0xBD,
      0x43, 0xCA, 0x00, 0x47, 0xCD, 0x5A, 0x4D, 0xCD, 0x0F,
      0x45, 0xC3, 0x33, 0x42]⟩
  else
    ⟨0x437D, [0xCD, 0x5E, 0x56, 0xFA, 0x78, 0xD0, 0xA7,
      0xC0, 0x78, 0xA7, 0xCA, 0x25, 0x45, 0xCD, 0xBD, 0x43,
      0xCA, 0x00, 0x47, 0xCD, 0x5A, 0x4D, 0x3E, 0x01,
      0xE0, 0xF3, 0x21, 0x2E, 0x65, 0x06, 0x0E, 0xCD, 0xD6,
      0x35, 0x38, 0x0D, 0xCD, 0xBC, 0x66, 0xFA, 0x78, 0xD0,
      0xA7, 0xC0, 0x78, 0xA7, 0xCA, 0x00, 0x47, 0xCD, 0xBD,
      0x43, 0xCA, 0x25, 0x45, 0xCD, 0x5A, 0x4D, 0xCD, 0x0F,
      0x45, 0xC3, 0x33, 0x42]⟩

structure RequiredNestedMoveBytes (rom : Array Byte) : Prop where
  dispatch : ∀ enemy, bytesAt rom (romOffset 0x0F (dispatchWindow enemy).entry)
    (dispatchWindow enemy).code.length = (dispatchWindow enemy).code
  done : ∀ enemy, bytesAt rom (romOffset 0x0F (doneWindow enemy).entry)
    (doneWindow enemy).code.length = (doneWindow enemy).code
  driver : ∀ enemyFirst, bytesAt rom (romOffset 0x0F (driverWindow enemyFirst).entry)
    (driverWindow enemyFirst).code.length = (driverWindow enemyFirst).code
  boundaries : ∀ window ∈ boundaryWindows,
    bytesAt rom (romOffset 0x0F window.entry) window.code.length = window.code

structure CanonicalNestedMoveBytes (sha256 : Sha256) (rom : CanonicalRom) : Prop where
  identity : rom.Valid sha256
  windows : RequiredNestedMoveBytes rom.bytes

private def install : FlatMemory → Word → List Byte → FlatMemory
  | memory, _, [] => memory
  | memory, address, byte :: rest =>
      install (memory.write address byte) (Word.ofNat (address.toNat + 1)) rest

private def originalReturn (enemy first : Bool) : Word :=
  if enemy then (if first then 0x434E else 0x43A4)
  else (if first then 0x4380 else 0x4364)

private def picker (mirror : Bool) : Word := if mirror then 0x62FD else 0x6348
private def damageEntry (enemy : Bool) : Word := if enemy then 0x66FC else 0x569A
private def pickerReturn (enemy mirror : Bool) : Word :=
  if enemy then (if mirror then 0x67F9 else 0x6806)
  else (if mirror then 0x5770 else 0x5781)

private def opponentSelected (enemy : Bool) : Word := if enemy then 0xCCDC else 0xCCDD

private def baseMemory (enemy : Bool) (opponentMove : Byte) : FlatMemory :=
  let window := dispatchWindow enemy
  let memory := install default window.entry window.code
  let done := doneWindow enemy
  let memory := install memory done.entry done.code
  let memory := boundaryWindows.foldl (fun memory window =>
    install memory window.entry window.code) memory
  memory.write (opponentSelected enemy) opponentMove

private def beforeDispatch (enemy mirror first : Bool) (opponentMove : Byte)
    (memory : FlatMemory := baseMemory enemy opponentMove) : FunctionalState :=
  let window := dispatchWindow enemy
  let memory := memory.write
    (if enemy then 0xCFCD else 0xCFD3) (if mirror then 0x09 else 0x53)
  Driver.setupCall memory window.entry.toNat.toUInt16
    (originalReturn enemy first).toNat.toUInt16 0xFFFE

private def dispatchRun (enemy mirror first : Bool) (opponentMove : Byte)
    (memory : FlatMemory := baseMemory enemy opponentMove) : Program.RunResult :=
  Program.runUntil (fun state => state.registers.pc == picker mirror) 8
    (beforeDispatch enemy mirror first opponentMove memory) [] 0

private def afterPicker (enemy mirror first : Bool) (opponentMove : Byte)
    (memory : FlatMemory := baseMemory enemy opponentMove) : FunctionalState :=
  let initial := Driver.setupCall memory
    (pickerReturn enemy mirror).toNat.toUInt16 (originalReturn enemy first).toNat.toUInt16 0xFFFE
  { initial with registers := { initial.registers with flags := { initial.registers.flags with z := false } } }

private def reentryRun (enemy mirror first : Bool) (opponentMove : Byte)
    (memory : FlatMemory := baseMemory enemy opponentMove) : Program.RunResult :=
  Program.runUntil (fun state => state.registers.pc == damageEntry enemy) 5
    (afterPicker enemy mirror first opponentMove memory) [] 0

private def doneRun (enemy first : Bool) (opponentMove : Byte)
    (memory : FlatMemory := baseMemory enemy opponentMove) : Program.RunResult :=
  Driver.runToReturn
    (Driver.setupCall memory (doneWindow enemy).entry.toNat.toUInt16
      (originalReturn enemy first).toNat.toUInt16 0xFFFE)
    (originalReturn enemy first).toNat.toUInt16 5

/-- Three separate machine frontiers, with the picker/effect body outside this
local theorem. Every opposing selected-move byte survives each frontier. -/
def nestedControlHolds (enemy mirror first : Bool) (opponentMove : Byte)
    (memory : FlatMemory := baseMemory enemy opponentMove) : Bool :=
  let called := dispatchRun enemy mirror first opponentMove memory
  let entered := Driver.finalState called
  let resumed := reentryRun enemy mirror first opponentMove memory
  let continuing := Driver.finalState resumed
  let done := doneRun enemy first opponentMove memory
  let completed := Driver.finalState done
  Driver.reachedReturn called && Driver.reachedReturn resumed && Driver.reachedReturn done &&
    entered.registers.pc == picker mirror && entered.registers.sp == (0xFFFA : Word) &&
    Word.ofBytes (entered.memory.read 0xFFFB) (entered.memory.read 0xFFFA) == pickerReturn enemy mirror &&
    Word.ofBytes (entered.memory.read 0xFFFD) (entered.memory.read 0xFFFC) == originalReturn enemy first &&
    continuing.registers.pc == damageEntry enemy && continuing.registers.sp == (0xFFFC : Word) &&
    Word.ofBytes (continuing.memory.read 0xFFFD) (continuing.memory.read 0xFFFC) == originalReturn enemy first &&
    completed.registers.pc == originalReturn enemy first && completed.registers.sp == (0xFFFE : Word) &&
    entered.memory.read (opponentSelected enemy) == opponentMove &&
    continuing.memory.read (opponentSelected enemy) == opponentMove &&
    completed.memory.read (opponentSelected enemy) == opponentMove

/-- All 256 selected-move bytes, both sides, both wrappers, and first/second
turn positions execute the actual decoded control windows exactly. -/
theorem nested_control_exact : ∀ enemy mirror first opponentMove,
    nestedControlHolds enemy mirror first opponentMove = true := by
  native_decide

/-- A successful nested tail jump preserves arbitrary memory and the existing
stack frame, not only the concrete witness bytes used above. -/
theorem nested_jump_preserves_memory_and_stack (state : FunctionalState)
    (quiet : RoutineSummary.Quiet state)
    (opcode : state.memory.read state.registers.pc = 0xC3) :
    let out := (Functional.step state).state
    out.memory = state.memory ∧ out.registers.sp = state.registers.sp ∧
      out.registers.pc = RoutineSummary.immediateWord state := by
  rw [RoutineSummary.step_jpAbsolute state quiet.1 quiet.2.2 quiet.2.1 opcode]
  exact ⟨rfl, rfl, rfl⟩

/-- The actor's decoded RET consumes exactly the current frame. The caller may
be either turn-driver continuation, including arbitrary pending action state. -/
theorem actor_return_consumes_one_frame (state : FunctionalState)
    (quiet : RoutineSummary.Quiet state)
    (opcode : state.memory.read state.registers.pc = 0xC9) :
    let out := (Functional.step state).state
    out.memory = state.memory ∧
      out.registers.pc = Word.ofBytes
        (state.memory.read (Word.ofNat (state.registers.sp.toNat + 1)))
        (state.memory.read state.registers.sp) ∧
      out.registers.sp = Word.ofNat (state.registers.sp.toNat + 2) := by
  rw [RoutineSummary.step_ret state quiet.1 quiet.2.2 quiet.2.1 opcode]
  simp only [RoutineSummary.ret, RoutineSummary.increment_twice, and_self]

private def traceOf : Program.RunResult → List BusEvent
  | .reached _ trace _ | .halted _ trace _ | .stopped _ trace _ |
      .locked _ trace _ | .fuelExhausted _ trace _ => trace

private def physicalInitial (state : FunctionalState) : FlatCoreState :=
  { core := {
      Pipeline.bootstrap state.registers with
      ime := state.ime
      scheduledImeEnable := state.scheduledImeEnable
      haltBug := state.haltBug }
    memory := state.memory }

private def physicalAgrees (initial : FunctionalState) (functional : Program.RunResult) : Bool :=
  let trace := traceOf functional
  let physical := FlatAdapter.run (trace.length + 1) (physicalInitial initial) (fun _ _ => 0)
  let final := Driver.finalState functional
  physical.trace == trace ++ [.read .opcode final.registers.pc (final.memory.read final.registers.pc)] &&
    (FlatAdapter.project physical).registers == final.registers &&
    physical.core.boundaryPC.isSome

/-- Each nested dispatch and reentry also agrees with continuous physical
fetched-instruction execution (including its successor fetch). -/
theorem nested_control_physical_exact : ∀ enemy mirror first,
    physicalAgrees (beforeDispatch enemy mirror first 97) (dispatchRun enemy mirror first 97) = true ∧
    physicalAgrees (afterPicker enemy mirror first 97) (reentryRun enemy mirror first 97) = true := by
  native_decide

/-- Explicit outer-shell contract: these helpers return without escape, faint,
or trainer intervention and preserve selected actions. Their internal effects
are not replaced by new cartridge claims in this local control-flow theorem. -/
private def nonterminalHelper (state : FunctionalState) : Option FunctionalState :=
  if [0x43BD, 0x4D5A, 0x450F, 0x35D6].contains state.registers.pc then
    let returned := RoutineSummary.ret state
    some { returned with registers := { returned.registers with
      flags := { returned.registers.flags with z := false, c := false } } }
  else none

private def outerStop (state : FunctionalState) : Bool :=
  [0x565E, 0x66BC, 0x4233, 0x4525, 0x4700, 0x8000].contains state.registers.pc

private def runOuter : Nat → FunctionalState → FunctionalState
  | 0, state => state
  | fuel + 1, state =>
      if outerStop state then state
      else match nonterminalHelper state with
        | some returned => runOuter fuel returned
        | none => runOuter fuel (Functional.step state).state

private def outerInitial (enemy first escaped fainted : Bool) (opponentMove : Byte)
    (romCode : List Byte) : FunctionalState :=
  let window := driverWindow (enemy == first)
  let memory := install default window.entry romCode
  let memory := memory.write (opponentSelected enemy) opponentMove
  let memory := memory.write 0xD078 (if escaped then 1 else 0)
  let initial := Driver.setupCall memory (originalReturn enemy first).toNat.toUInt16 0x8000 0xFFFE
  { initial with registers := { initial.registers with b := if fainted then 0 else 1 } }

private def outerHoldsWith (enemy first escaped fainted : Bool) (opponentMove : Byte)
    (code : List Byte) : Bool :=
  let final := runOuter 40 (outerInitial enemy first escaped fainted opponentMove code)
  let expected : Word := if escaped then 0x8000 else if fainted then
      (if enemy then 0x4700 else 0x4525)
    else if first then (if enemy then 0x565E else 0x66BC) else 0x4233
  final.registers.pc == expected && final.memory.read (opponentSelected enemy) == opponentMove

/-- Under the stated helper contract the first actor resumes the opponent,
and the second resumes MainInBattleLoop. Escape and target faint branch away
before either continuation, for both actor orientations and all selected moves. -/
theorem outer_driver_continuation_exact : ∀ enemy first escaped fainted opponentMove,
    outerHoldsWith enemy first escaped fainted opponentMove
      (driverWindow (enemy == first)).code = true := by
  native_decide

/-- The outer-shell theorem is about the actual caller-supplied canonical ROM
windows, conditional on the independently checked identity/window certificate. -/
theorem canonical_outer_driver_exact {sha256 : Sha256} {rom : CanonicalRom}
    (certificate : CanonicalNestedMoveBytes sha256 rom) :
    ∀ enemy first escaped fainted opponentMove,
      outerHoldsWith enemy first escaped fainted opponentMove
        (bytesAt rom.bytes (romOffset 0x0F (driverWindow (enemy == first)).entry)
          (driverWindow (enemy == first)).code.length) = true := by
  intro enemy first escaped fainted opponentMove
  rw [certificate.windows.driver]
  exact outer_driver_continuation_exact enemy first escaped fainted opponentMove

private def decodedMemory (rom : Array Byte) (enemy : Bool) (opponentMove : Byte) : FlatMemory :=
  let window := dispatchWindow enemy
  let memory := install default window.entry
    (bytesAt rom (romOffset 0x0F window.entry) window.code.length)
  let done := doneWindow enemy
  let memory := install memory done.entry
    (bytesAt rom (romOffset 0x0F done.entry) done.code.length)
  let memory := boundaryWindows.foldl (fun memory window =>
    install memory window.entry (bytesAt rom (romOffset 0x0F window.entry) window.code.length)) memory
  memory.write (opponentSelected enemy) opponentMove

private theorem decoded_memory_exact {rom : Array Byte}
    (certificate : RequiredNestedMoveBytes rom) (enemy : Bool) (opponentMove : Byte) :
    decodedMemory rom enemy opponentMove = baseMemory enemy opponentMove := by
  have first := certificate.boundaries ⟨0x62FD, [0xF0]⟩ (by simp [boundaryWindows])
  have second := certificate.boundaries ⟨0x6348, [0xAF]⟩ (by simp [boundaryWindows])
  have third := certificate.boundaries ⟨0x569A, [0xFA]⟩ (by simp [boundaryWindows])
  have fourth := certificate.boundaries ⟨0x66FC, [0xFA]⟩ (by simp [boundaryWindows])
  simp only [decodedMemory, baseMemory, certificate.dispatch, certificate.done,
    boundaryWindows, List.foldl_cons, List.foldl_nil]
  simp only at first second third fourth
  rw [first, second, third, fourth]

/-- The certified ROM's loaded bytes, including the actual next fetched
opcode, execute all three nested frontiers with the same frame and opposing
selection guarantees as the decoded witnesses. -/
theorem canonical_nested_control_exact {sha256 : Sha256} {rom : CanonicalRom}
    (certificate : CanonicalNestedMoveBytes sha256 rom) :
    ∀ enemy mirror first opponentMove,
      nestedControlHolds enemy mirror first opponentMove
        (decodedMemory rom.bytes enemy opponentMove) = true := by
  intro enemy mirror first opponentMove
  rw [decoded_memory_exact certificate.windows]
  exact nested_control_exact enemy mirror first opponentMove

/-- Physical fetched-instruction execution uses the certified ROM bytes as
well; successor opcodes at real cartridge boundaries are not stubbed zeros. -/
theorem canonical_nested_physical_exact {sha256 : Sha256} {rom : CanonicalRom}
    (certificate : CanonicalNestedMoveBytes sha256 rom) :
    ∀ enemy mirror first,
      let memory := decodedMemory rom.bytes enemy 97
      physicalAgrees (beforeDispatch enemy mirror first 97 memory)
        (dispatchRun enemy mirror first 97 memory) = true ∧
      physicalAgrees (afterPicker enemy mirror first 97 memory)
        (reentryRun enemy mirror first 97 memory) = true := by
  intro enemy mirror first
  dsimp only
  rw [decoded_memory_exact certificate.windows]
  exact nested_control_physical_exact enemy mirror first

/-- Runtime predicate only; proof consumers retain explicit byte equalities. -/
def windowAgrees (rom : Array Byte) : Bool :=
  ([false, true].all fun enemy =>
    decide (bytesAt rom (romOffset 0x0F (dispatchWindow enemy).entry)
      (dispatchWindow enemy).code.length = (dispatchWindow enemy).code) &&
    decide (bytesAt rom (romOffset 0x0F (doneWindow enemy).entry)
      (doneWindow enemy).code.length = (doneWindow enemy).code) &&
    decide (bytesAt rom (romOffset 0x0F (driverWindow enemy).entry)
      (driverWindow enemy).code.length = (driverWindow enemy).code)) &&
  boundaryWindows.all fun window => decide
    (bytesAt rom (romOffset 0x0F window.entry) window.code.length = window.code)

end Battle.Rom.NestedMoveRoutine
