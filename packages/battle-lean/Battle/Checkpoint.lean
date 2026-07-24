/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Wram

/-!
# Checkpoint traces

A **checkpoint trace** is the observable output of one battle run: at each
instrumented point in the engine (start of turn, post-damage, post-status, end
of turn, …) the driver captures the current bytes of every `RegionSpec` in the
WRAM state contract. Running the oracle (`sm83-lean` over the assembled ROM) and
the abstract Lean model each produce a `Trace`; the Stage-0 differential asserts
the two traces are equal, and on mismatch the comparator (built in a later step)
bisects to the first divergent checkpoint and region.

This module is only the data model and its well-formedness conditions — it does
not read memory or diff traces. Capturing is parameterised over a `read`
function so the same builder serves the oracle side (read from the emulated
`FlatMemory`) and the model side (serialize the abstract state).
-/

namespace Battle

open Battle.Wram

/-- Raw captured bytes. `Array UInt8` (not `ByteArray`) so `Snapshot` and
    `Checkpoint` can derive `DecidableEq` structurally. -/
abbrev Bytes := Array UInt8

/-- One region's captured bytes at a checkpoint. -/
structure Snapshot where
  /-- Which region these bytes came from. -/
  region : RegionSpec
  /-- The captured bytes; well-formed when `bytes.size = region.len`. -/
  bytes : Bytes
deriving Repr, DecidableEq

/-- A snapshot is well-formed when it captured exactly the region's length. -/
def Snapshot.wf (s : Snapshot) : Prop := s.bytes.size = s.region.len

/-- Decidable/boolean form of `Snapshot.wf`, for runtime checks in the driver. -/
def Snapshot.wfb (s : Snapshot) : Bool := s.bytes.size == s.region.len

theorem Snapshot.wfb_iff_wf (s : Snapshot) : s.wfb = true ↔ s.wf := by
  unfold Snapshot.wfb Snapshot.wf; exact beq_iff_eq

/-- All the region captures taken at one instrumented point in the engine. -/
structure Checkpoint where
  /-- Where in the pipeline this was taken, e.g. `"turn3:post-damage"`. -/
  label : String
  /-- One snapshot per captured region. -/
  snapshots : List Snapshot
deriving Repr, DecidableEq

/-- A checkpoint is well-formed when every snapshot is. -/
def Checkpoint.wf (c : Checkpoint) : Prop := ∀ s ∈ c.snapshots, s.wf

/-- Boolean form of `Checkpoint.wf`. -/
def Checkpoint.wfb (c : Checkpoint) : Bool := c.snapshots.all (·.wfb)

/-- Look up a captured region within a checkpoint by its pokered symbol. -/
def Checkpoint.find? (c : Checkpoint) (symbol : String) : Option Snapshot :=
  c.snapshots.find? (·.region.symbol == symbol)

/-- The output of a full battle run: checkpoints in engine order. -/
abbrev Trace := List Checkpoint

/-- A trace is well-formed when every checkpoint is. -/
def Trace.wf (t : Trace) : Prop := ∀ c ∈ t, c.wf

/-- Boolean form of `Trace.wf`. -/
def Trace.wfb (t : Trace) : Bool := t.all (·.wfb)

/-- Build a checkpoint by reading every region through `read`. The oracle side
    passes a reader backed by the emulated memory; the model side passes one
    backed by the abstract battle state's serialization. Capturing the identical
    `regions` on both sides is what makes the two traces comparable. -/
def Checkpoint.capture (label : String) (regions : List RegionSpec)
    (read : RegionSpec → Bytes) : Checkpoint :=
  { label, snapshots := regions.map (fun r => { region := r, bytes := read r }) }

/-- A capture over the full `battleCheckpointRegions` contract is well-formed
    exactly when the reader returns `region.len` bytes for every region. -/
theorem Checkpoint.capture_wfb (label : String) (regions : List RegionSpec)
    (read : RegionSpec → Bytes) (h : ∀ r ∈ regions, (read r).size = r.len) :
    (Checkpoint.capture label regions read).wfb = true := by
  unfold Checkpoint.capture Checkpoint.wfb Snapshot.wfb
  simp only [List.all_eq_true, List.mem_map, beq_iff_eq]
  rintro s ⟨r, hr, rfl⟩
  exact h r hr

end Battle
