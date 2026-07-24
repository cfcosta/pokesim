/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

import Sm83.Program

namespace Sm83
namespace Hoare

/-- Generic Hoare judgment over fetched byte-program execution. -/
def Triple (pre : FunctionalState → Prop) (program : List Byte)
    (post : FunctionalState → Prop) : Prop :=
  ∀ before after, pre before → Program.Runs before program after → post after

@[simp] theorem skip (predicate : FunctionalState → Prop) : Triple predicate [] predicate := by
  intro before after holds runs
  cases runs
  exact holds

/-- Sequential composition follows by splitting the relational byte trace. -/
theorem sequence {pre middle post : FunctionalState → Prop} {left right : List Byte}
    (first : Triple pre left middle) (second : Triple middle right post) :
    Triple pre (left ++ right) post := by
  intro before after preBefore run
  obtain ⟨pivot, leftRun, rightRun⟩ := Program.Runs.split run
  exact second pivot after (first before pivot preBefore leftRun) rightRun

/-- Explicit-state composition used when the intermediate run witness is already known. -/
theorem sequenceAt {pre middle post : FunctionalState → Prop} {left right : List Byte}
    (first : Triple pre left middle) (second : Triple middle right post)
    {before pivot after : FunctionalState}
    (preBefore : pre before) (leftRun : Program.Runs before left pivot)
    (rightRun : Program.Runs pivot right after) : post after :=
  second pivot after (first before pivot preBefore leftRun) rightRun

/-- Memory outside `addresses` is unchanged. -/
def Frames (addresses : Word → Prop) (before after : FunctionalState) : Prop :=
  ∀ address, ¬addresses address → after.memory.read address = before.memory.read address

@[simp] theorem Frames.refl (addresses : Word → Prop) (state : FunctionalState) :
    Frames addresses state state := by
  intro address _
  rfl

end Hoare
end Sm83
