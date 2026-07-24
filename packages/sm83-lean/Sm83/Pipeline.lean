/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

import Sm83.CoreState
import Sm83.Alu

namespace Sm83
namespace Pipeline

private def taken (shape : InstructionShape) (flags : Flags) : Bool :=
  match shape with
  | .jrCond condition | .retCond condition | .jpCond condition | .callCond condition =>
      Alu.conditionHolds condition flags
  | _ => true

/-- Install a fetched base opcode into IR and derive its physical schedule. -/
def install (state : CoreState) (address : Word) (opcode : Byte) : CoreState :=
  let state := {
    state with
    phase := .execute
    ir := some { byte := opcode, address }
    shape := none
    remaining := []
    latches := {} }
  match Decode.base opcode with
  | .locked _ => { state with mode := .locked opcode }
  | .prefix => { state with remaining := [.cbFetch] }
  | .legal shape =>
      let branchTaken := taken shape state.registers.flags
      { state with
        shape := some shape
        remaining := Cycle.physicalSchedule shape branchTaken
        latches := { conditionTaken := branchTaken } }

/-- Finish a CB fetch and replace the temporary prefix schedule with the selected family. -/
def installCB (state : CoreState) (opcode : Byte) : CoreState :=
  let shape := Decode.cb opcode
  { state with
    shape := some shape
    remaining := (Cycle.physicalSchedule shape).drop 1
    latches := { state.latches with conditionTaken := true } }

/-- Reset/bootstrap state. Only PC is constrained by this processor-level constructor. -/
def bootstrap (registers : Registers := {}) : CoreState :=
  { registers, phase := .bootstrap, ir := none, remaining := [] }

/-- Structural pipeline invariant used by machine-cycle runners. -/
def WellFormed (state : CoreState) : Prop :=
  match state.phase with
  | .bootstrap => state.ir = none ∧ state.shape = none ∧ state.remaining = []
  | .execute => state.ir.isSome

@[simp] theorem bootstrap_wellFormed (registers : Registers) : WellFormed (bootstrap registers) := by
  simp [WellFormed, bootstrap]

@[simp] theorem install_wellFormed (state : CoreState) (address : Word) (opcode : Byte) :
    WellFormed (install state address opcode) := by
  cases decoded : Decode.base opcode <;> simp [WellFormed, install, decoded]

@[simp] theorem installCB_wellFormed (state : CoreState) (opcode : Byte)
    (executing : state.phase = .execute) (wellFormed : WellFormed state) :
    WellFormed (installCB state opcode) := by
  simp_all [WellFormed, installCB]

end Pipeline
end Sm83
