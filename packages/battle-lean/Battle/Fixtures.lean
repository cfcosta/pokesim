/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.Wram
import Battle.Checkpoint
import Battle.Rng
import Battle.Action
import Battle.Codec
import Battle.Diff

/-!
# The end-to-end fixture matrix (Stage-0 closure)

A `Fixture` is one differential scenario: a battle mode, its required caller
state (battle type, link state, RNG seed), the per-turn action script, and the
two active mons the battle starts from. The matrix below covers the encounter
modes that the closure spec enumerates — wild, wild-capture, trainer, trainer
AI-switch, Safari, Old Man tutorial, link, faint/switch, mid-battle level-up,
and the raw/divergent glitch case.

## What runs today, and the two injection points it awaits

A full differential needs two trace producers:

* the **oracle** — `Battle.Driver.traceRoutine`, running the assembled pokered
  ROM over `sm83-lean` and reading WRAM back (needs the `.gb`/`.sym` the driver
  is written against, plus the bank-switching memory adapter for routines that
  leave one ROM bank);
* the **model** — the high-level Lean battle engine that steps a `Script` to the
  same checkpoints (not yet written).

Neither exists as a concrete `Script → Trace` here, so the fixtures inject them
as the pending seam. What *is* exercised end-to-end today is everything the
harness owns independently of those two producers:

* each fixture's **initial checkpoint** is built through the real codec
  (`BattleMon.toSnapshot`) and RNG seeding, and is well-formed;
* the **comparator** passes a trace against itself (`harnessSound`) and catches a
  one-byte perturbation with the correct first divergence (`sensitivityHeld`);
* every scripted **action round-trips** through the exchange-nybble codec;
* the **RNG seed** advances by exactly one draw per exchange point and keeps its
  cursor in range.

When the oracle and model land, each fixture's `initialTrace` becomes the
`t = 0` checkpoint both producers must agree on, and the same `compareTrace`
call generalizes from "trace vs itself / vs a perturbation" to "ROM vs model".
-/

namespace Battle

open Battle.Wram

/-! ## Starting mons

Legal-shaped level-10 mons; exact stats are immaterial to the harness plumbing,
but the two sides differ so a swapped-side capture would show up as a divergence.
`glitchMon` is the all-`$FF` block the codec's completeness theorem guarantees
decodes — the raw/divergent fixture's payload. -/

/-- The player's starting mon. -/
private def base : BattleMon :=
  { species := 1, hpHi := 0, hpLo := 20, boxLevel := 10, status := 0,
    type1 := 22, type2 := 3, catchRate := 45,
    move0 := 33, move1 := 45, move2 := 0, move3 := 0,
    dv0 := 0x98, dv1 := 0x88, level := 10,
    maxHpHi := 0, maxHpLo := 20,
    atkHi := 0, atkLo := 12, defHi := 0, defLo := 12,
    spdHi := 0, spdLo := 11, spcHi := 0, spcLo := 11,
    pp0 := 35, pp1 := 30, pp2 := 0, pp3 := 0 }

/-- The opponent's starting mon: a distinct species and stat line. -/
private def enemyBase : BattleMon :=
  { species := 16, hpHi := 0, hpLo := 22, boxLevel := 10, status := 0,
    type1 := 22, type2 := 3, catchRate := 45,
    move0 := 33, move1 := 0, move2 := 0, move3 := 0,
    dv0 := 0x98, dv1 := 0x88, level := 10,
    maxHpHi := 0, maxHpLo := 22,
    atkHi := 0, atkLo := 10, defHi := 0, defLo := 10,
    spdHi := 0, spdLo := 14, spcHi := 0, spcLo := 10,
    pp0 := 35, pp1 := 30, pp2 := 0, pp3 := 0 }

/-- An all-`$FF` glitch mon (raw/divergent fixture). Decoding a 29-byte block
    always succeeds, so the `getD` fallback is never taken. -/
private def glitchMon : BattleMon :=
  (BattleMon.decode (List.replicate battleStructLength (0xFF : UInt8)).toArray).getD base

/-! ## Fixture shape -/

/-- One differential scenario. `battleType`/`linkState`/`seed` are the caller
    state the mode requires; `script` drives the turns; `player`/`enemy` are the
    active mons at `t = 0`; `regions` is the capture set the initial checkpoint
    (and, later, both producers) reads. -/
structure Fixture where
  /-- Short kebab-case identifier. -/
  name : String
  /-- Encounter mode tag (`"wild"`, `"trainer"`, `"safari"`, …). -/
  mode : String
  /-- `wBattleType`: 0 normal, 1 Old Man, 2 Safari. -/
  battleType : Nat
  /-- `wLinkState`: `linkStateBattling` for link fixtures, else 0. -/
  linkState : UInt8
  /-- The synchronized link-RNG seed the battle draws from. -/
  seed : Rng.LinkRng
  /-- Per-turn player/enemy decisions. -/
  script : Script
  /-- The player's active mon. -/
  player : BattleMon
  /-- The opponent's active mon. -/
  enemy : BattleMon
  /-- The regions captured at each checkpoint. -/
  regions : List RegionSpec
  /-- Human note: what this scenario stresses. -/
  note : String

/-! ## Construction helpers -/

/-- The capture set every fixture reads at `t = 0`: both active mons plus the
    link-RNG state. This is the subset the harness can populate today from the
    fixture alone; the full driver additionally captures enemy base stats and
    the per-turn residual scratch. -/
def demoRegions : List RegionSpec :=
  [ { symbol := "wBattleMon", len := battleStructLength, note := "player active mon" },
    { symbol := "wEnemyMon", len := battleStructLength, note := "enemy active mon" },
    { symbol := "wLinkBattleRandomNumberList", len := serialRnsLength, note := "link RNG list" },
    { symbol := "wLinkBattleRandomNumberListIndex", len := 1, note := "link RNG cursor" } ]

/-- One turn of the script. -/
private def turn (p e : Action) : TurnInput := { player := p, enemy := e }

/-- Assemble a fixture with the shared `demoRegions` capture set. -/
private def fx (name mode : String) (bt : Nat) (ls : UInt8) (seed : Rng.LinkRng)
    (script : Script) (player enemy : BattleMon) (note : String) : Fixture :=
  { name, mode, battleType := bt, linkState := ls, seed, script, player, enemy,
    regions := demoRegions, note }

/-- A link-battle seed distinct from `seed0`, so a link fixture that accidentally
    reused the wild seed would diverge. -/
private def linkSeed : Rng.LinkRng := { list := #[9, 8, 7, 6, 5, 4, 3, 2, 1, 0], index := 0 }

/-! ## The scenarios -/

/-- Supplied wild encounter; one attacking turn on each side. -/
def wildSingleTurn : Fixture :=
  fx "wild-single-turn" "wild" battleTypeNormal 0 Rng.seed0
    [turn (.fight 0) (.fight 0)] base enemyBase
    "supplied wild encounter; one attacking turn on each side"

/-- Wild capture: weaken then throw a ball. The ball throw is an item action,
    outside the exchange-nybble domain, so it appears here only as the note. -/
def wildCapture : Fixture :=
  fx "wild-capture" "wild" battleTypeNormal 0 Rng.seed0
    [turn (.fight 1) .noAction] base enemyBase
    "wild capture: weaken then throw a ball (the ball turn is an item action, outside the nybble domain)"

/-- Trainer battle fought to victory; no capture, no run. -/
def trainerVictory : Fixture :=
  fx "trainer-victory" "trainer" battleTypeNormal 0 Rng.seed0
    [turn (.fight 0) (.fight 0), turn (.fight 0) (.fight 1)] base enemyBase
    "trainer battle fought to victory; no capture, no run"

/-- Trainer AI switches its active mon mid-battle. -/
def trainerAiSwitch : Fixture :=
  fx "trainer-ai-switch" "trainer" battleTypeNormal 0 Rng.seed0
    [turn (.fight 0) (.switch 1)] base enemyBase
    "trainer AI switches its active mon mid-battle"

/-- Safari Zone: the player cannot attack (bait/rock/ball are item turns), so the
    menu is skipped and then the player runs. -/
def safariBaitRun : Fixture :=
  fx "safari-bait-run" "safari" battleTypeSafari 0 Rng.seed0
    [turn .noAction (.fight 0), turn .run (.fight 0)] base enemyBase
    "Safari Zone: player cannot attack (bait/rock/ball are item turns); menu skipped then run"

/-- Old Man catching tutorial: a fully scripted forced capture. -/
def oldManTutorial : Fixture :=
  fx "oldman-tutorial" "oldman" battleTypeOldMan 0 Rng.seed0
    [turn .noAction .noAction] base enemyBase
    "Old Man catching tutorial: fully scripted forced capture"

/-- Link battle: both sides attack; the RNG list is the synchronized shared seed. -/
def linkMutualAttack : Fixture :=
  fx "link-mutual-attack" "link" battleTypeNormal linkStateBattling linkSeed
    [turn (.fight 0) (.fight 2)] base enemyBase
    "link battle: both sides attack; the RNG list is the synchronized shared seed"

/-- The player's active mon faints and is replaced by a party switch. -/
def faintSwitch : Fixture :=
  fx "faint-switch" "faint" battleTypeNormal 0 Rng.seed0
    [turn (.fight 0) (.fight 0), turn (.switch 1) (.fight 0)] base enemyBase
    "player's active mon faints and is replaced by a party switch"

/-- Mid-battle level-up: EXP gain after the KO crosses a level boundary. -/
def levelUp : Fixture :=
  fx "level-up" "levelup" battleTypeNormal 0 Rng.seed0
    [turn (.fight 0) .noAction] base enemyBase
    "mid-battle level-up: EXP gain after the KO crosses a level boundary"

/-- Raw/divergent: all-`$FF` glitch mons, exercising codec completeness over
    arbitrary bytes. -/
def rawGlitch : Fixture :=
  fx "raw-glitch" "raw" battleTypeNormal 0 Rng.seed0
    [turn .noAction .noAction] glitchMon glitchMon
    "raw/divergent: all-0xFF glitch mons; exercises codec completeness over arbitrary bytes"

/-- The full Stage-0 fixture matrix. -/
def matrix : List Fixture :=
  [wildSingleTurn, wildCapture, trainerVictory, trainerAiSwitch, safariBaitRun,
   oldManTutorial, linkMutualAttack, faintSwitch, levelUp, rawGlitch]

/-! ## The initial checkpoint

The `t = 0` capture, built through the real codec and RNG seeding. When the
oracle and model land, this is the checkpoint both must reproduce. -/

/-- The two link-RNG regions, seeded from the fixture. -/
def Fixture.rngSnapshots (f : Fixture) : List Snapshot :=
  [ { region := { symbol := "wLinkBattleRandomNumberList", len := serialRnsLength },
      bytes := f.seed.listBytes },
    { region := { symbol := "wLinkBattleRandomNumberListIndex", len := 1 },
      bytes := #[f.seed.indexByte] } ]

/-- The initial checkpoint trace: both active mons (via the codec) plus the RNG
    state, under this fixture's `:init` label. -/
def Fixture.initialTrace (f : Fixture) : Trace :=
  [ { label := s!"{f.name}:init",
      snapshots :=
        BattleMon.toSnapshot "wBattleMon" f.player
          :: BattleMon.toSnapshot "wEnemyMon" f.enemy
          :: f.rngSnapshots } ]

/-- Flip the first byte of the first snapshot of the first checkpoint — a minimal
    perturbation the comparator must catch. `Array.modify` on a present index is
    a guaranteed change (`b ≠ b + 1` for every `UInt8`). -/
def perturbFirst (t : Trace) : Trace :=
  match t with
  | { label := lbl, snapshots := s :: rest } :: cps =>
      { label := lbl, snapshots := { s with bytes := s.bytes.modify 0 (· + 1) } :: rest } :: cps
  | _ => t

/-! ## Per-fixture checks

Everything the harness can assert today without the oracle or model. -/

/-- The comparator passes a trace against itself. -/
def Fixture.harnessSound (f : Fixture) : Bool :=
  passed (compareTrace f.initialTrace f.initialTrace)

/-- A one-byte perturbation is caught (some divergence, not `PASS`). -/
def Fixture.sensitivityHeld (f : Fixture) : Bool :=
  (compareTrace f.initialTrace (perturbFirst f.initialTrace)).isSome

/-- Every scripted action round-trips through the exchange-nybble codec. -/
def Fixture.actionsRoundTrip (f : Fixture) : Bool :=
  f.script.all fun t =>
    Action.ofNybble t.player.toNybble == some t.player &&
    Action.ofNybble t.enemy.toNybble == some t.enemy

/-- The seed advances by exactly one draw per exchange point and keeps its cursor
    in range — the state threading the turn engine will rely on. -/
def Fixture.rngAdvance (f : Fixture) : Bool :=
  let n := f.script.length
  let (drawn, r') := f.seed.take n
  drawn.size == n && decide (r'.index < serialRnsLength)

/-- The initial trace is well-formed and the capture set has no empty regions. -/
def Fixture.wellFormed (f : Fixture) : Bool :=
  Trace.wfb f.initialTrace && regionsWellFormed f.regions

/-- A fixture passes when every harness-owned property holds. -/
def Fixture.check (f : Fixture) : Bool :=
  f.harnessSound && f.sensitivityHeld && f.actionsRoundTrip &&
  f.rngAdvance && f.wellFormed

/-! ## Matrix aggregates -/

/-- Each fixture's encounter-mode tag. -/
def matrixModes : List String := matrix.map (·.mode)

/-- Per-fixture pass/fail, for the test runner's report. -/
def runMatrix : List (String × Bool) := matrix.map fun f => (f.name, f.check)

/-- The whole matrix passes. -/
def matrixAllPass : Bool := matrix.all Fixture.check

/-- The encounter modes the closure spec requires the matrix to cover. -/
def requiredModes : List String := ["wild", "trainer", "safari", "oldman", "link", "raw"]

/-- Every required mode appears in the matrix. -/
def coversRequiredModes : Bool := requiredModes.all matrixModes.contains

/-! ## Guards: the green matrix -/

-- The matrix is the full set of scenarios and covers every required mode.
#guard matrix.length == 10
#guard coversRequiredModes
-- Every fixture passes every harness-owned check.
#guard matrixAllPass
#guard runMatrix.all (·.2)
-- Well-formedness is explicit, not merely folded into `check`.
#guard matrix.all fun f => Trace.wfb f.initialTrace
-- The sensitivity check lands on the exact field, not merely "somewhere": a
-- flipped species byte is reported as byte 0 of `wBattleMon`, field `Species`.
#guard
  (match compareTrace wildSingleTurn.initialTrace (perturbFirst wildSingleTurn.initialTrace) with
   | some (.byte 0 _ rd) => rd.symbol == "wBattleMon" && rd.offset == 0 && rd.field == some "Species"
   | _ => false)

end Battle
