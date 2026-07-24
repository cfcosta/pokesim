/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Wram
import Battle.Checkpoint
import Battle.Codec

/-!
# The differential comparator and divergence bisection

Stage-0's verdict step. Given one fixture (a seed + action script), the harness
produces two `Trace`s over the *same* checkpoints (`Battle.Wram`): the **ROM**
trace (the `sm83-lean` driver executing the assembled battle ROM) and the **SIM**
trace (the abstract Lean battle model). This module compares them and returns
either `PASS` or a **first-divergence report**.

## What "first divergence" means

The traces are ordered, so "first" is lexicographic in three nested keys:

1. the earliest **checkpoint** (turn/step) at which anything differs;
2. within it, the earliest **region** in capture order (`battleCheckpointRegions`);
3. within that, the earliest **byte** offset.

At the leaf, a `battle_struct` byte offset is resolved to its **field name**
(`Species`, `HP`, `Attack`, …) via `battleStructFields`, and the report cites the
defining ASM source. Both raw bytes (ROM vs SIM) are shown, because the contract
is byte-for-byte fidelity — the number a field "means" is secondary to the bytes.

Structural disagreements (different trace lengths, checkpoint labels, region
counts, or region byte-counts) are themselves divergences: they mean the oracle
and the model disagree on the *shape* of the state, which is a harness bug to
surface loudly rather than paper over.

## Two ways to locate it

* `compareTrace` scans left-to-right and returns the richest report in one pass.
  Use it when both traces are already in hand (the common case).
* `bisect` binary-searches the first failing checkpoint index using only a
  monotone "prefix-agrees" predicate — O(log n) probes. This is the tool for when
  the oracle trace is produced *lazily* (each probe re-runs the ROM to checkpoint
  k), where minimizing ROM replays matters. `firstDivergingCheckpoint` wires the
  comparator into it; on in-hand traces it agrees with `compareTrace`'s index.
-/

namespace Battle

open Battle.Wram

/-! ## The divergence type -/

/-- The first differing byte within one region, with everything needed to point a
    human (and a future auto-bisector) at the cause. -/
structure RegionDivergence where
  /-- The region's WRAM symbol. -/
  symbol : String
  /-- The region's human note (from its `RegionSpec`). -/
  note : String
  /-- Region-relative offset of the first differing byte. -/
  offset : Nat
  /-- The `battle_struct` field the offset lands in, if the region is one. -/
  field : Option String
  /-- ASM source hint for the region / field. -/
  source : String
  /-- The oracle (ROM) byte. -/
  romByte : UInt8
  /-- The model (SIM) byte. -/
  simByte : UInt8
deriving Repr, DecidableEq, BEq

/-- A first divergence between a ROM trace and a SIM trace. -/
inductive Divergence where
  /-- The traces have different lengths. -/
  | traceLength (romLen simLen : Nat)
  /-- Checkpoint `index` has different labels on the two sides. -/
  | checkpointLabel (index : Nat) (romLabel simLabel : String)
  /-- Checkpoint `index` has a structural mismatch (region count / symbol / size). -/
  | regionShape (index : Nat) (label : String) (detail : String)
  /-- Checkpoint `index` region `region` differs at a byte. -/
  | byte (index : Nat) (label : String) (region : RegionDivergence)
deriving Repr, DecidableEq, BEq

/-- The comparator's result: `none` is `PASS`, `some d` is the first divergence. -/
abbrev DiffOutcome := Option Divergence

/-! ## Offset → field resolution (`battleStructFields`) -/

/-- Whether a region is one of the two active-mon `battle_struct`s. -/
def isBattleStruct (symbol : String) : Bool :=
  symbol == "wBattleMon" || symbol == "wEnemyMon"

/-- The `battle_struct` field a struct-relative offset falls in, if any. -/
def fieldAtOffset (off : Nat) : Option String :=
  (battleStructFields.find? (fun f => decide (f.offset ≤ off ∧ off < f.offset + f.width))).map
    (·.name)

/-- ASM source hint for a region's bytes. `battle_struct` fields are defined by
    the layout macro; other symbols by the WRAM variable file. -/
def regionSource (symbol : String) : String :=
  if isBattleStruct symbol then "macros/ram.asm:39 (battle_struct)" else "ram/wram.asm"

-- Offset → field agrees with the contract's boundaries.
#guard fieldAtOffset 0 == some "Species"
#guard fieldAtOffset 1 == some "HP"
#guard fieldAtOffset 2 == some "HP"
#guard fieldAtOffset 4 == some "Status"
#guard fieldAtOffset 8 == some "Moves"
#guard fieldAtOffset 12 == some "DVs"
#guard fieldAtOffset 15 == some "MaxHP"
#guard fieldAtOffset 25 == some "PP"
#guard fieldAtOffset 28 == some "PP"
#guard fieldAtOffset 29 == none      -- past the 29-byte struct

/-! ## Byte / region / checkpoint / trace comparison -/

/-- The first index (from `start`) at which two equal-length byte lists differ. -/
def firstMismatch : Nat → List UInt8 → List UInt8 → Option (Nat × UInt8 × UInt8)
  | _, [], [] => none
  | i, x :: xs, y :: ys => if x == y then firstMismatch (i + 1) xs ys else some (i, x, y)
  | _, _, _ => none

/-- Compare two snapshots that should describe the same region. -/
def compareSnapshot (idx : Nat) (label : String) (rom sim : Snapshot) : DiffOutcome :=
  if rom.region.symbol != sim.region.symbol then
    some (.regionShape idx label
      s!"region symbol mismatch: {rom.region.symbol} vs {sim.region.symbol}")
  else if rom.bytes.size != sim.bytes.size then
    some (.regionShape idx label
      s!"{rom.region.symbol}: byte-count {rom.bytes.size} vs {sim.bytes.size}")
  else
    match firstMismatch 0 rom.bytes.toList sim.bytes.toList with
    | none => none
    | some (off, rb, sb) =>
      some (.byte idx label
        { symbol := rom.region.symbol, note := rom.region.note, offset := off,
          field := if isBattleStruct rom.region.symbol then fieldAtOffset off else none,
          source := regionSource rom.region.symbol, romByte := rb, simByte := sb })

/-- Compare two checkpoints' snapshot lists, returning the first region that
    differs (in capture order). -/
def compareSnapshots (idx : Nat) (label : String) : List Snapshot → List Snapshot → DiffOutcome
  | [], [] => none
  | r :: rs, s :: ss =>
    match compareSnapshot idx label r s with
    | some d => some d
    | none => compareSnapshots idx label rs ss
  | _, _ => some (.regionShape idx label "checkpoint region-count mismatch")

/-- Compare two equal-length traces from checkpoint `i` onward. -/
def compareFrom : Nat → Trace → Trace → DiffOutcome
  | _, [], [] => none
  | i, c :: cs, d :: ds =>
    if c.label != d.label then some (.checkpointLabel i c.label d.label)
    else match compareSnapshots i c.label c.snapshots d.snapshots with
      | some div => some div
      | none => compareFrom (i + 1) cs ds
  | _, _, _ => none

/-- Compare a ROM (oracle) trace against a SIM (model) trace. `none` is `PASS`;
    `some d` is the first divergence, lexicographic in checkpoint → region → byte. -/
def compareTrace (rom sim : Trace) : DiffOutcome :=
  if rom.length != sim.length then some (.traceLength rom.length sim.length)
  else compareFrom 0 rom sim

/-- Did the two traces agree at every checkpoint? -/
def passed (o : DiffOutcome) : Bool := o.isNone

/-! ## Divergence bisection

`bisect` finds the least index a monotone predicate rejects, in O(log n) probes.
When the oracle is re-run per probe, this is the difference between one ROM replay
and n of them. -/

/-- Least `k ∈ [lo, hi)` with `fails k = true`, assuming `fails` is monotone
    (once true, stays true). `none` if none in range. O(log (hi−lo)) probes. -/
def bisect (fails : Nat → Bool) (lo hi : Nat) : Option Nat :=
  if h : lo < hi then
    if fails ((lo + hi) / 2) then
      match bisect fails lo ((lo + hi) / 2) with
      | some k => some k
      | none => some ((lo + hi) / 2)
    else
      bisect fails ((lo + hi) / 2 + 1) hi
  else
    none
termination_by hi - lo
decreasing_by all_goals omega

/-- The first diverging checkpoint index via binary search over prefix agreement.
    Agrees with `compareTrace`'s reported index; use when oracle replays are the
    cost that dominates. -/
def firstDivergingCheckpoint (rom sim : Trace) : Option Nat :=
  (bisect (fun k => (compareTrace (rom.take k) (sim.take k)).isSome) 1
    (max rom.length sim.length + 1)).map (· - 1)

-- bisect locates the monotone step exactly.
#guard bisect (fun k => decide (k ≥ 3)) 0 10 == some 3
#guard bisect (fun k => decide (k ≥ 0)) 0 10 == some 0
#guard bisect (fun k => decide (k ≥ 9)) 0 10 == some 9
#guard bisect (fun _ => false) 0 10 == none

/-! ## Rendering the report -/

private def hexDigit (n : Nat) : Char := "0123456789ABCDEF".toList.getD n '0'

/-- A byte as two uppercase hex digits. -/
def toHex2 (b : UInt8) : String := String.ofList [hexDigit (b.toNat / 16), hexDigit (b.toNat % 16)]

#guard toHex2 0x00 == "00"
#guard toHex2 0x0A == "0A"
#guard toHex2 0x2C == "2C"
#guard toHex2 0xFF == "FF"

/-- Render one region divergence. -/
def RegionDivergence.render (r : RegionDivergence) : String :=
  let fld := match r.field with | some f => s!" field {f}" | none => ""
  s!"region {r.symbol} (+{r.offset}){fld}: ROM=0x{toHex2 r.romByte} SIM=0x{toHex2 r.simByte}\n" ++
  s!"    note: {r.note}\n    source: {r.source}"

/-- Render a divergence as a first-divergence report. -/
def Divergence.render : Divergence → String
  | .traceLength a b => s!"DIVERGENCE: trace length {a} (ROM) vs {b} (SIM)"
  | .checkpointLabel i a b => s!"DIVERGENCE at checkpoint #{i}: label {a} (ROM) vs {b} (SIM)"
  | .regionShape i l d => s!"DIVERGENCE at checkpoint #{i} ({l}): {d}"
  | .byte i l r => s!"DIVERGENCE at checkpoint #{i} ({l})\n  {r.render}"

/-- The comparator verdict as text: `"PASS"` or the first-divergence report. -/
def report (o : DiffOutcome) : String :=
  match o with
  | none => "PASS"
  | some d => d.render

/-! ## Tests

Fixtures built through the codec, exercising equality, byte divergence with field
resolution, the three orderings (checkpoint, region, byte), RNG-region divergence,
and each structural mismatch. -/

/-- A codec fixture mon. -/
private def mon : BattleMon :=
  { species := 1, hpHi := 0x01, hpLo := 0x2C, boxLevel := 5, status := 0,
    type1 := 22, type2 := 3, catchRate := 45,
    move0 := 33, move1 := 45, move2 := 0, move3 := 0, dv0 := 0x98, dv1 := 0x88,
    level := 5, maxHpHi := 0x01, maxHpLo := 0x41, atkHi := 0x00, atkLo := 0x32,
    defHi := 0x00, defLo := 0x31, spdHi := 0x00, spdLo := 0x2D,
    spcHi := 0x00, spcLo := 0x41, pp0 := 0x9F, pp1 := 30, pp2 := 0, pp3 := 0 }

/-- The same mon with a perturbed HP low byte (offset 2 of `battle_struct`). -/
private def monHurt : BattleMon := { mon with hpLo := 0xFF }

/-- A one-region checkpoint capturing the player mon. -/
private def cp (label : String) (m : BattleMon) : Checkpoint :=
  { label, snapshots := [m.toSnapshot "wBattleMon"] }

/-- A two-region checkpoint capturing both mons. -/
private def cp2 (label : String) (p e : BattleMon) : Checkpoint :=
  { label, snapshots := [p.toSnapshot "wBattleMon", e.toSnapshot "wEnemyMon"] }

/-- A checkpoint capturing a raw single-byte region (e.g. the RNG cursor). -/
private def rngCp (label symbol : String) (b : UInt8) : Checkpoint :=
  { label, snapshots := [{ region := { symbol, len := 1 }, bytes := #[b] }] }

-- Equal traces PASS.
#guard passed (compareTrace [cp "t0" mon] [cp "t0" mon])
#guard report (compareTrace [cp "t0" mon] [cp "t0" mon]) == "PASS"

-- A single differing byte is resolved to checkpoint 0, region wBattleMon, field HP.
#guard !passed (compareTrace [cp "t0" mon] [cp "t0" monHurt])
#guard
  match compareTrace [cp "t0" mon] [cp "t0" monHurt] with
  | some (.byte 0 "t0" r) =>
    r.symbol == "wBattleMon" && r.offset == 2 && r.field == some "HP"
      && r.romByte == 0x2C && r.simByte == 0xFF
  | _ => false

-- Checkpoint ordering: 0 agrees, 1 diverges → report index 1.
#guard
  match compareTrace [cp "t0" mon, cp "t1" mon] [cp "t0" mon, cp "t1" monHurt] with
  | some (.byte 1 "t1" r) => r.offset == 2 && r.field == some "HP"
  | _ => false

-- Region ordering: wBattleMon agrees, wEnemyMon diverges → report the enemy region.
#guard
  match compareTrace [cp2 "t" mon mon] [cp2 "t" mon monHurt] with
  | some (.byte 0 "t" r) => r.symbol == "wEnemyMon" && r.offset == 2 && r.field == some "HP"
  | _ => false

-- A non-`battle_struct` (RNG cursor) divergence: no field, WRAM source.
#guard
  match compareTrace [rngCp "r" "wLinkBattleRandomNumberListIndex" 3]
                     [rngCp "r" "wLinkBattleRandomNumberListIndex" 4] with
  | some (.byte 0 "r" r) =>
    r.symbol == "wLinkBattleRandomNumberListIndex" && r.field == none
      && r.romByte == 3 && r.simByte == 4
  | _ => false

-- Structural mismatches surface distinctly.
#guard match compareTrace [cp "a" mon] [cp "b" mon] with
       | some (.checkpointLabel 0 "a" "b") => true | _ => false
#guard match compareTrace [cp "a" mon] [cp "a" mon, cp "b" mon] with
       | some (.traceLength 1 2) => true | _ => false
#guard match compareTrace [cp "t" mon] [cp2 "t" mon mon] with
       | some (.regionShape 0 "t" _) => true | _ => false

-- Binary-search bisection agrees with the linear scan's checkpoint index.
#guard firstDivergingCheckpoint [cp "t0" mon, cp "t1" mon] [cp "t0" mon, cp "t1" monHurt] == some 1
#guard firstDivergingCheckpoint [cp "t0" mon] [cp "t0" mon] == none

end Battle
