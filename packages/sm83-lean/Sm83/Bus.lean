/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

import Sm83.Clock
import Sm83.Instruction

namespace Sm83

inductive ReadKind where
  | opcode | cbOpcode | immediate | data | stack | vector
  deriving Repr, DecidableEq, Inhabited

inductive FetchProvenance where
  | none | generic | cbSubopcode | discardedInterrupt | haltDummy
  deriving Repr, DecidableEq, Inhabited

inductive BusEvent where
  | read (kind : ReadKind) (address : Word) (value : Byte)
  | write (address : Word) (value : Byte)
  | idle (drivenAddress : Word)
  deriving Repr, DecidableEq

inductive BusControl where
  | idle | read | write
  deriving Repr, DecidableEq, Inhabited

inductive DataDrive where
  | released | driven (value : Byte)
  deriving Repr, DecidableEq, Inhabited

inductive IduDirection where
  | none | increment | decrement | relative
  deriving Repr, DecidableEq, Inhabited

inductive IduSource where
  | none | pc | sp | hl | bc | de | wz
  deriving Repr, DecidableEq, Inhabited

inductive IduDestination where
  | none | pc | sp | hl | wz
  deriving Repr, DecidableEq, Inhabited

structure IduIntent where
  source : IduSource := .none
  direction : IduDirection := .none
  destination : IduDestination := .none
  oldAddress : Word := 0
  deriving Repr, DecidableEq, Inhabited

inductive InterruptPoll where
  | none | genericFetch | suppressForDI | dispatch
  deriving Repr, DecidableEq, Inhabited

structure CommitSet where
  registers : Bool := false
  flags : Bool := false
  pc : Bool := false
  sp : Bool := false
  ir : Bool := false
  ime : Bool := false
  deriving Repr, DecidableEq, Inhabited

/-- Processor intent for one physical M-cycle (exactly four CPU T-cycles). -/
structure CycleIntent where
  address : Word
  control : BusControl := .idle
  data : DataDrive := .released
  readKind : ReadKind := .data
  fetch : FetchProvenance := .none
  idu : IduIntent := {}
  commit : CommitSet := {}
  poll : InterruptPoll := .none
  clocks : ClockIntent := {}
  deriving Repr, DecidableEq

/-- A phase-indexed byte drive. `none` means released rather than `$FF`. -/
structure ReadResponse where
  driveAt : Fin 8 → Option Byte

namespace ReadResponse

/-- Dynamic precharged reads retain every observed low bit. -/
def fold (response : ReadResponse) : Byte :=
  (List.ofFn response.driveAt).foldl
    (fun value drive => match drive with | none => value | some byte => value &&& byte)
    (Byte.ofNat 0xFF)

/-- A stable asynchronous read drives one byte for the whole sample window. -/
def stable (value : Byte) : ReadResponse := ⟨fun _ => some value⟩

@[simp] theorem fold_stable : ∀ value : Byte, (stable value).fold = value := by
  native_decide

end ReadResponse

structure CoreInput where
  read : ReadResponse := .stable (Byte.ofNat 0xFF)
  pendingInterrupts : Byte := 0
  wake : Bool := false

end Sm83
