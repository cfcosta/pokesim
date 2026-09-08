/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Rom.EffectRoutines
import Battle.Full.Effects
import Sm83.FlatAdapter

/-!
# Cartridge Mirror Move rejection

The canonical bank-$0f window at $62fd selects the opposing last-used move,
stores the acting selected move, and branches to failure exactly for $00/$77.
We execute those bytes for both acting sides and all 256 last-move bytes in
the functional and physical SM83 cores, including the actual prefetched
boundary opcodes $21/$ea. The failure tail XOR A / RET is checked
separately after PrintText returns. Text rendering and ReloadMoveData are
explicit routine boundaries; neither is replaced by a synthetic cartridge call.

The public certificate theorem consumes caller-supplied ROM byte equalities
and connects this decoded decision to Full.Effects.applyBefore.
-/

namespace Battle.Rom.MirrorMoveRoutine

open Sm83 Battle.Rom.Closure

private def entry : UInt16 := 0x62FD
private def failure : Word := 0x631C
private def reload : Word := 0x6329
private def failureTail : UInt16 := 0x6322
private def sentinel : UInt16 := 0x8000
private def stackTop : UInt16 := 0xFFFE
private def whoseTurn : Word := 0xFFF3
private def playerUsed : Word := 0xCCF1
private def enemyUsed : Word := 0xCCF2
private def playerSelected : Word := 0xCCDC
private def enemySelected : Word := 0xCCDD

private def branchBytes : List Byte :=
  [0xF0, 0xF3, 0xA7, 0xFA, 0xF2, 0xCC, 0x21, 0xDC,
   0xCC, 0x11, 0xD2, 0xCF, 0x28, 0x09, 0xFA, 0xF1,
   0xCC, 0x11, 0xCC, 0xCF, 0x21, 0xDD, 0xCC, 0x77,
   0xFE, 0x77, 0x28, 0x03, 0xA7, 0x20, 0x0D]

private def failureBytes : List Byte :=
  [0x21, 0x24, 0x63, 0xCD, 0x49, 0x3C, 0xAF, 0xC9]

private def install : FlatMemory → Word → List Byte → FlatMemory
  | memory, _, [] => memory
  | memory, address, byte :: rest =>
      install (memory.write address byte) (Word.ofNat (address.toNat + 1)) rest

private def selected (enemyTurn : Bool) : Word :=
  if enemyTurn then enemySelected else playerSelected

private def rejected (lastMove : UInt8) : Bool :=
  lastMove == 0 || lastMove == 119

def expectedSignal (lastMove : UInt8) : Full.Effects.Signal :=
  if rejected lastMove then .failed else .callMove lastMove

private def initialWith (code : List Byte) (enemyTurn : Bool)
    (lastMove : UInt8) (failureOpcode : Byte := 0x21)
    (reloadOpcode : Byte := 0xEA) : FunctionalState :=
  let memory := install default (Word.ofNat entry.toNat) code
  -- The physical core prefetches the boundary instruction before projection.
  -- Supply the real cartridge byte even though that instruction is not run.
  let memory := (memory.write failure failureOpcode).write reload reloadOpcode
  let memory := memory.write whoseTurn (if enemyTurn then 1 else 0)
  let memory := memory.write playerUsed
    (if enemyTurn then Byte.ofNat lastMove.toNat else 0xA5)
  let memory := memory.write enemyUsed
    (if enemyTurn then 0xA5 else Byte.ofNat lastMove.toNat)
  let memory := (memory.write playerSelected 0xFE).write enemySelected 0xFE
  Driver.setupCall memory entry sentinel stackTop

private def atBranchBoundary (state : FunctionalState) : Bool :=
  state.registers.pc == failure || state.registers.pc == reload

private def runWith (code : List Byte) (enemyTurn : Bool)
    (lastMove : UInt8) (failureOpcode : Byte := 0x21)
    (reloadOpcode : Byte := 0xEA) : Program.RunResult :=
  Program.runUntil atBranchBoundary 20
    (initialWith code enemyTurn lastMove failureOpcode reloadOpcode) [] 0

private def traceOf : Program.RunResult → List BusEvent
  | .reached _ trace _ | .halted _ trace _ | .stopped _ trace _ |
      .locked _ trace _ | .fuelExhausted _ trace _ => trace

private def writes (trace : List BusEvent) : List (Word × Byte) :=
  trace.filterMap fun event => match event with
    | .write address value => some (address, value)
    | _ => none

/-- Exact selector, branch, register and write footprint of the cartridge
window. No stack write or chance access is substituted for either branch. -/
def branchSummaryWith (code : List Byte) (enemyTurn : Bool)
    (lastMove : UInt8) : Bool :=
  let result := runWith code enemyTurn lastMove
  let final := Driver.finalState result
  Driver.reachedReturn result &&
    final.registers.pc == (if rejected lastMove then failure else reload) &&
    final.registers.flags.z == rejected lastMove &&
    Driver.toByte final.registers.a == lastMove &&
    final.registers.hl == selected enemyTurn &&
    final.registers.de == (if enemyTurn then 0xCFCC else 0xCFD2) &&
    final.registers.sp == 0xFFFC &&
    Driver.toByte (final.memory.read (selected enemyTurn)) == lastMove &&
    Driver.toByte (final.memory.read (selected (!enemyTurn))) == 0xFE &&
    writes (traceOf result) == [(selected enemyTurn, Byte.ofNat lastMove.toNat)]

def branchSummary (enemyTurn : Bool) (lastMove : UInt8) : Bool :=
  branchSummaryWith branchBytes enemyTurn lastMove

private def physicalInitial (state : FunctionalState) : FlatCoreState :=
  { core := {
      Pipeline.bootstrap state.registers with
      ime := state.ime
      scheduledImeEnable := state.scheduledImeEnable
      haltBug := state.haltBug }
    memory := state.memory }

/-- Independent fetched-IR execution of the supplied code and boundary bytes
matches the architectural trace and registers, plus the real boundary fetch. -/
def physicalBranchSummaryWith (code : List Byte) (failureOpcode reloadOpcode : Byte)
    (enemyTurn : Bool) (lastMove : UInt8) : Bool :=
  let before := initialWith code enemyTurn lastMove failureOpcode reloadOpcode
  let functional := runWith code enemyTurn lastMove failureOpcode reloadOpcode
  let trace := traceOf functional
  let final := Driver.finalState functional
  let physical := FlatAdapter.run (trace.length + 1) (physicalInitial before)
    (fun _ _ => 0)
  let projected := FlatAdapter.project physical
  physical.trace == trace ++ [.read .opcode final.registers.pc
    (if rejected lastMove then failureOpcode else reloadOpcode)] &&
    projected.registers == final.registers &&
    projected.mode == .running && physical.core.boundaryPC.isSome &&
    writes physical.trace == [(selected enemyTurn, Byte.ofNat lastMove.toNat)]

def physicalBranchSummary (enemyTurn : Bool) (lastMove : UInt8) : Bool :=
  physicalBranchSummaryWith branchBytes 0x21 0xEA enemyTurn lastMove

private def exhaustive : Bool :=
  (List.range 256).all fun raw =>
    branchSummary false raw.toUInt8 && branchSummary true raw.toUInt8 &&
      physicalBranchSummary false raw.toUInt8 &&
      physicalBranchSummary true raw.toUInt8

private theorem exhaustive_checked : exhaustive = true := by native_decide

/-- Every possible last-move byte, both sides, through both SM83 semantics.
In particular, $77 is rejected and ordinary copying remains supported. -/
theorem branch_exact (enemyTurn : Bool) (lastMove : UInt8) :
    branchSummary enemyTurn lastMove = true ∧
      physicalBranchSummary enemyTurn lastMove = true := by
  have rows := List.all_eq_true.mp exhaustive_checked
  have row := rows lastMove.toNat (List.mem_range.mpr lastMove.toNat_lt)
  have round : lastMove.toNat.toUInt8 = lastMove := by
    apply UInt8.toNat.inj
    simp
  simp only [round] at row
  cases enemyTurn <;> simp_all

private def failureTailInitial (code : List Byte) (incomingA : UInt8) : FunctionalState :=
  -- The caller-return sentinel and its zero opcode are a test-harness boundary,
  -- not a substituted cartridge instruction within MirrorMoveCopyMove.
  let memory := install default (Word.ofNat failureTail.toNat) code
  let state := Driver.setupCall memory failureTail sentinel stackTop
  { state with registers := { state.registers with a := Byte.ofNat incomingA.toNat } }

def failureTailSummaryWith (code : List Byte) (incomingA : UInt8) : Bool :=
  let before := failureTailInitial code incomingA
  let result := Driver.runToReturn before sentinel 2
  let final := Driver.finalState result
  let trace := traceOf result
  let physical := FlatAdapter.run (trace.length + 1) (physicalInitial before)
    (fun _ _ => 0)
  Driver.reachedReturn result &&
    final.registers.pc == Word.ofNat sentinel.toNat &&
    final.registers.sp == Word.ofNat stackTop.toNat &&
    final.registers.a == 0 &&
    final.registers.flags == { z := true, n := false, h := false, c := false } &&
    writes trace == [] &&
    physical.trace == trace ++ [.read .opcode (Word.ofNat sentinel.toNat) 0] &&
    (FlatAdapter.project physical).registers == final.registers

def failureTailSummary (incomingA : UInt8) : Bool :=
  failureTailSummaryWith [0xAF, 0xC9] incomingA

private theorem failure_tail_exhaustive :
    (List.range 256).all (fun raw => failureTailSummary raw.toUInt8) = true := by
  native_decide

/-- Once the real PrintText call returns, failure clears A/sets Z and returns
to the original caller for any accumulator value left by rendering. -/
theorem failure_tail_exact (incomingA : UInt8) :
    failureTailSummary incomingA = true := by
  have row := List.all_eq_true.mp failure_tail_exhaustive incomingA.toNat
    (List.mem_range.mpr incomingA.toNat_lt)
  have round : incomingA.toNat.toUInt8 = incomingA := by
    apply UInt8.toNat.inj
    simp
  simpa only [round] using row

/-- The model keeps the context unchanged and makes the same failure/call
decision as the decoded branch; it consumes no new chance for this effect. -/
theorem model_decision (context : Full.Effects.Context) (hit : Bool) :
    (Full.Effects.applyBefore 0x09 hit context).signal =
        expectedSignal context.defenderLastMove ∧
      (Full.Effects.applyBefore 0x09 hit context).context = context := by
  constructor
  · change (if rejected context.defenderLastMove then
      (⟨context, .failed, []⟩ : Full.Effects.Outcome) else
      ⟨context, .callMove context.defenderLastMove,
        [.signal (.callMove context.defenderLastMove)]⟩).signal =
      expectedSignal context.defenderLastMove
    unfold expectedSignal
    split <;> rfl
  · change (if rejected context.defenderLastMove then
      (⟨context, .failed, []⟩ : Full.Effects.Outcome) else
      ⟨context, .callMove context.defenderLastMove,
        [.signal (.callMove context.defenderLastMove)]⟩).context = context
    split <;> rfl

structure RequiredMirrorMoveBytes (rom : Array Byte) : Prop where
  branch : Tables.tableBytes rom (romOffset 0x0F (Word.ofNat entry.toNat))
      branchBytes.length = branchBytes.map (fun byte => byte.toNat.toUInt8)
  failure : Tables.tableBytes rom (romOffset 0x0F failure)
      failureBytes.length = failureBytes.map (fun byte => byte.toNat.toUInt8)
  reload : Tables.tableBytes rom (romOffset 0x0F reload) 1 = [0xEA]

structure CanonicalMirrorMoveBytes (sha256 : Sha256) (rom : CanonicalRom) : Prop where
  identity : rom.Valid sha256
  windows : RequiredMirrorMoveBytes rom.bytes

private def decodedBranch (rom : Array Byte) : List Byte :=
  (Tables.tableBytes rom (romOffset 0x0F (Word.ofNat entry.toNat))
    branchBytes.length).map fun byte => Byte.ofNat byte.toNat

def decodedBranchSummary (rom : Array Byte) (enemyTurn : Bool)
    (lastMove : UInt8) : Bool :=
  branchSummaryWith (decodedBranch rom) enemyTurn lastMove

private def decodedFailureOpcode (rom : Array Byte) : Byte :=
  Byte.ofNat ((Tables.tableBytes rom (romOffset 0x0F failure)
    failureBytes.length).headD 0).toNat

private def decodedReloadOpcode (rom : Array Byte) : Byte :=
  Byte.ofNat ((Tables.tableBytes rom (romOffset 0x0F reload) 1).headD 0).toNat

/-- Physical execution uses both the certified branch and the actual ROM
opcodes fetched at its failure/reload boundaries. -/
def decodedPhysicalBranchSummary (rom : Array Byte) (enemyTurn : Bool)
    (lastMove : UInt8) : Bool :=
  physicalBranchSummaryWith (decodedBranch rom) (decodedFailureOpcode rom)
    (decodedReloadOpcode rom) enemyTurn lastMove

private def decodedFailureTail (rom : Array Byte) : List Byte :=
  ((Tables.tableBytes rom (romOffset 0x0F failure)
    failureBytes.length).drop 6).map fun byte => Byte.ofNat byte.toNat

def decodedFailureTailSummary (rom : Array Byte) (incomingA : UInt8) : Bool :=
  failureTailSummaryWith (decodedFailureTail rom) incomingA

/-- The failure-return theorem also executes bytes supplied by the certified
ROM, after the rendering call has restored its caller's stack frame. -/
theorem canonical_failure_tail_exact {sha256 : Sha256} {rom : CanonicalRom}
    (certificate : CanonicalMirrorMoveBytes sha256 rom) (incomingA : UInt8) :
    decodedFailureTailSummary rom.bytes incomingA = true := by
  have bytes : decodedFailureTail rom.bytes = [0xAF, 0xC9] := by
    simp only [decodedFailureTail, certificate.windows.failure]
    native_decide
  simpa [decodedFailureTailSummary, bytes, failureTailSummary] using
    failure_tail_exact incomingA

/-- Caller-supplied canonical ROM instructions, physical-core agreement and
the high-level effect share the exact rejection predicate. The proof boundary
excludes rendering and the successful reload helper. -/
theorem canonical_mirror_move_model_exact {sha256 : Sha256} {rom : CanonicalRom}
    (certificate : CanonicalMirrorMoveBytes sha256 rom)
    (context : Full.Effects.Context) (hit enemyTurn : Bool) :
    decodedBranchSummary rom.bytes enemyTurn context.defenderLastMove = true ∧
      decodedPhysicalBranchSummary rom.bytes enemyTurn context.defenderLastMove = true ∧
      (Full.Effects.applyBefore 0x09 hit context).signal =
        expectedSignal context.defenderLastMove ∧
      (Full.Effects.applyBefore 0x09 hit context).context = context := by
  have bytes : decodedBranch rom.bytes = branchBytes := by
    simp only [decodedBranch, certificate.windows.branch, List.map_map]
    native_decide
  have failureOpcode : decodedFailureOpcode rom.bytes = 0x21 := by
    simp only [decodedFailureOpcode, certificate.windows.failure]
    native_decide
  have reloadOpcode : decodedReloadOpcode rom.bytes = 0xEA := by
    simp only [decodedReloadOpcode, certificate.windows.reload]
    native_decide
  have branch := branch_exact enemyTurn context.defenderLastMove
  refine ⟨?_, ?_, model_decision context hit⟩
  · simpa [decodedBranchSummary, bytes, branchSummary] using branch.1
  · simpa [decodedPhysicalBranchSummary, bytes, failureOpcode, reloadOpcode,
      physicalBranchSummary] using branch.2

/-- Runtime fixture check; theorem callers still provide exact byte witnesses. -/
def windowAgrees (rom : Array Byte) : Bool :=
  decide (Tables.tableBytes rom (romOffset 0x0F (Word.ofNat entry.toNat))
    branchBytes.length = branchBytes.map (fun byte => byte.toNat.toUInt8)) &&
  decide (Tables.tableBytes rom (romOffset 0x0F failure)
    failureBytes.length = failureBytes.map (fun byte => byte.toNat.toUInt8)) &&
  decide (Tables.tableBytes rom (romOffset 0x0F reload) 1 = [0xEA])

end Battle.Rom.MirrorMoveRoutine
