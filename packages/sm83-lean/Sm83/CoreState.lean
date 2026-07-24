/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

import Sm83.Cycle
import Sm83.Interrupt
import Sm83.Registers

namespace Sm83

inductive CoreMode where
  | running | halted | stopped (prefetched : Byte) | locked (opcode : Byte)
  deriving Repr, DecidableEq, Inhabited

inductive PipelinePhase where
  | bootstrap | execute | interrupt
  deriving Repr, DecidableEq, Inhabited

structure FetchedIR where
  byte : Byte
  address : Word
  deriving Repr, DecidableEq

structure CoreLatches where
  low : Byte := 0
  high : Byte := 0
  data : Byte := 0
  conditionTaken : Bool := true
  deriving Repr, DecidableEq, Inhabited

structure CoreState where
  registers : Registers := {}
  ime : Bool := false
  scheduledImeEnable : Bool := false
  haltBug : Bool := false
  mode : CoreMode := .running
  phase : PipelinePhase := .bootstrap
  ir : Option FetchedIR := none
  shape : Option InstructionShape := none
  remaining : List MicroOp := []
  latches : CoreLatches := {}
  interrupt : Option InterruptEntry := none
  /-- Architectural PC before the currently prefetched IR begins execution. -/
  boundaryPC : Option Word := none
  deriving Repr, DecidableEq

namespace CoreState

@[inline] def wz (state : CoreState) : Word := Word.ofBytes state.latches.high state.latches.low

@[inline] def currentOp? (state : CoreState) : Option MicroOp := state.remaining.head?

end CoreState
end Sm83
