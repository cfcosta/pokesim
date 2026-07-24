/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

import Sm83.Bus

namespace Sm83

inductive InterruptStage where
  | correctPC | decrementSP | writeHigh | writeLow | fetchVector
  deriving Repr, DecidableEq, Inhabited

structure InterruptEntry where
  stage : InterruptStage := .correctPC
  returnPC : Word
  vector : Word := 0
  acknowledge : Byte := 0
  deriving Repr, DecidableEq

namespace Interrupt

/-- Select the lowest-numbered enabled request. Zero means cancellation. -/
def priorityMask (pending : Byte) : Byte :=
  let n := pending.toNat
  if n &&& 0x01 != 0 then Byte.ofNat 0x01
  else if n &&& 0x02 != 0 then Byte.ofNat 0x02
  else if n &&& 0x04 != 0 then Byte.ofNat 0x04
  else if n &&& 0x08 != 0 then Byte.ofNat 0x08
  else if n &&& 0x10 != 0 then Byte.ofNat 0x10
  else 0

/-- Game Boy-connected vector for a selected priority mask; cancellation targets zero. -/
def vector (mask : Byte) : Word :=
  match mask.toNat with
  | 0x01 => Word.ofNat 0x40
  | 0x02 => Word.ofNat 0x48
  | 0x04 => Word.ofNat 0x50
  | 0x08 => Word.ofNat 0x58
  | 0x10 => Word.ofNat 0x60
  | _ => 0

private def pendingBytes : List Byte := (List.range 256).map Byte.ofNat

/-- Priority selection returns zero or exactly one of the five connected lines. -/
theorem priorityMask_range : ∀ pending : Byte,
    [0, 1, 2, 4, 8, 16].contains (priorityMask pending).toNat := by
  native_decide

/-- Selection always chooses a bit present in the supplied pending mask. -/
theorem priorityMask_subset : ∀ pending : Byte,
    (priorityMask pending).toNat &&& pending.toNat = (priorityMask pending).toNat := by
  native_decide

end Interrupt
end Sm83
