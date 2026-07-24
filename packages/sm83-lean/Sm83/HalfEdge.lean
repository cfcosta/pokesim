/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

import Sm83.Bus

namespace Sm83

structure PinIntent where
  halfEdge : HalfEdge
  address : Option Word := none
  selected : Bool := false
  writeAsserted : Bool := false
  data : DataDrive := .released
  sampleRead : Bool := false
  deriving Repr, DecidableEq

namespace HalfEdge

private def isT4R : Sm83.HalfEdge → Bool
  | ⟨.t4, .rising⟩ => true
  | _ => false

private def afterSelect : Sm83.HalfEdge → Bool
  | ⟨.t1, .falling⟩ => false
  | ⟨.t4, .rising⟩ => false
  | _ => true

private def writeWindow : Sm83.HalfEdge → Bool
  | ⟨.t2, .rising⟩ | ⟨.t3, .falling⟩ | ⟨.t3, .rising⟩ => true
  | _ => false

private def readSample : Sm83.HalfEdge → Bool
  | ⟨.t3, .rising⟩ => true
  | _ => false

/-- Expand one generic processor M-cycle into T1F through T4R pin intent. -/
def expand (intent : CycleIntent) : List PinIntent := machineHalfEdges.map fun edge =>
  let active := intent.control != .idle
  { halfEdge := edge
    address := if isT4R edge then none else some intent.address
    selected := active && afterSelect edge
    writeAsserted := intent.control == .write && writeWindow edge
    data := if intent.control == .write && writeWindow edge then intent.data else .released
    sampleRead := intent.control == .read && readSample edge }

@[simp] theorem expand_length (intent : CycleIntent) : (expand intent).length = 8 := by
  simp [expand]

/-- Reads are sampled exactly at T3R. -/
example (intent : CycleIntent) (control : intent.control = .read) :
    ((expand intent).filter (·.sampleRead)).map (·.halfEdge) = [⟨.t3, .rising⟩] := by
  simp [expand, machineHalfEdges, readSample, afterSelect, isT4R, writeWindow, control]

end HalfEdge
end Sm83
