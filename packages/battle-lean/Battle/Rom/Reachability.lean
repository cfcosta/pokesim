/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0.
-/
import Battle.Rom.Closure

/-!
# Reachable battle graph certificate boundary

The graph is supplied alongside canonical ROM bytes. Edges distinguish direct
calls, MBC far calls, predefs, pointer tables, text callbacks, interrupts, and
assets. No source label or catalogue is treated as executable evidence.
-/

namespace Battle.Rom.Reachability

open Sm83 Battle.Rom.Closure

structure Range where
  bank : Byte
  start : Word
  stop : Word
  deriving Repr, DecidableEq, BEq

inductive EdgeKind where
  | directCall | directJump | farCall | predef | pointerTable | textCallback
  | interrupt | presentationAsset
  deriving Repr, DecidableEq, BEq

structure Edge where
  source : Range
  target : Range
  kind : EdgeKind
  deriving Repr, DecidableEq, BEq

inductive Disposition where
  | executed
  | projectedMutation
  | framed
  | outOfScope
  deriving Repr, DecidableEq, BEq

structure ClassifiedRange where
  range : Range
  disposition : Disposition
  deriving Repr, DecidableEq, BEq

inductive Reachable (roots : List Range) (edges : List Edge) : Range → Prop
  | root {range} : range ∈ roots → Reachable roots edges range
  | step {source target kind} : Reachable roots edges source →
      { source, target, kind } ∈ edges → Reachable roots edges target

structure FarCallContract where
  selectedBank : Byte
  target : Word
  returnBank : Byte
  stackReturn : Word
  deriving Repr, DecidableEq, BEq

/-- Exact far-call control requires bank selection, target/return address, and
restored bank; `$2000` is never flattened into ordinary memory. -/
def farCallWellFormed (contract : FarCallContract) : Bool :=
  contract.selectedBank != 0 && contract.target.toNat ≥ 0x4000 &&
    contract.target.toNat < 0x8000

structure Certificate (rom : CanonicalRom) where
  roots : List Range
  ranges : List ClassifiedRange
  edges : List Edge
  initOpponentRoot : ∃ range ∈ roots,
    range.bank = Symbols.initOpponent.bank ∧ range.start = Symbols.initOpponent.address
  everyReachableClassified : ∀ range,
    Reachable roots edges range → ∃ classified ∈ ranges, classified.range = range
  everyEdgeSourceClassified : ∀ edge ∈ edges, ∃ classified ∈ ranges,
    classified.range = edge.source
  everyEdgeTargetClassified : ∀ edge ∈ edges, ∃ classified ∈ ranges,
    classified.range = edge.target
  noUnresolvedExecutedEdge : ∀ edge ∈ edges,
    ∃ classified ∈ ranges, classified.range = edge.target ∧
      classified.disposition != .outOfScope
  rangeBounds : ∀ classified ∈ ranges,
    classified.range.start.toNat ≤ classified.range.stop.toNat ∧
      romOffset classified.range.bank.toNat classified.range.stop ≤ rom.bytes.size
  farCalls : ∀ edge ∈ edges, edge.kind = .farCall → ∃ contract : FarCallContract,
    farCallWellFormed contract = true
  trainerCallbacks : ∀ edge ∈ edges, edge.kind = .textCallback →
    ∃ classified ∈ ranges, classified.range = edge.target ∧
      (classified.disposition = .projectedMutation ∨
       classified.disposition = .framed ∨ classified.disposition = .outOfScope)


theorem reachable_ranges_are_classified {rom : CanonicalRom}
    (certificate : Certificate rom) {range : Range}
    (reachable : Reachable certificate.roots certificate.edges range) :
    ∃ classified ∈ certificate.ranges, classified.range = range :=
  certificate.everyReachableClassified range reachable


theorem no_unresolved_reachable_edge {rom : CanonicalRom}
    (certificate : Certificate rom) (edge : Edge) (member : edge ∈ certificate.edges) :
    ∃ classified ∈ certificate.ranges, classified.range = edge.target ∧
      classified.disposition != .outOfScope :=
  certificate.noUnresolvedExecutedEdge edge member


theorem far_calls_are_mbc_aware {rom : CanonicalRom}
    (certificate : Certificate rom) (edge : Edge) (member : edge ∈ certificate.edges)
    (far : edge.kind = .farCall) :
    ∃ contract : FarCallContract, farCallWellFormed contract = true :=
  certificate.farCalls edge member far


theorem trainer_callbacks_classified {rom : CanonicalRom}
    (certificate : Certificate rom) (edge : Edge) (member : edge ∈ certificate.edges)
    (callback : edge.kind = .textCallback) :
    ∃ classified ∈ certificate.ranges, classified.range = edge.target ∧
      (classified.disposition = .projectedMutation ∨
       classified.disposition = .framed ∨ classified.disposition = .outOfScope) :=
  certificate.trainerCallbacks edge member callback

end Battle.Rom.Reachability
