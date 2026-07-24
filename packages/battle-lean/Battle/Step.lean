/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/
import Battle.State
import Battle.Damage
import Battle.Critical

/-!
# One attacking turn — `resolveTurn`

The pure kernel for a fight-vs-fight turn, transcribed from `MainInBattleLoop`
and the damage-execution path in `engine/battle/core.asm`. Given both sides'
already-resolved moves it decides turn order, then resolves each side's attack in
order (accuracy → damage → HP subtract → faint), threading the link RNG and
emitting a semantic checkpoint log, and stops the moment a side faints.

## What it models, 1:1

* **Turn order** (`core.asm:370-412`). Quick Attack outranks a normal move, which
  outranks Counter; ties within a priority class (and two normal moves) fall to
  the faster Speed; a Speed tie is a `BattleRandom` coin — `cp (50 percent + 1)`
  i.e. `cp 128`, so `rand < 128` → player first (the non-inverted branch; the
  internal-clock cart takes `.invertOutcome` so both link carts agree — see
  `invertSpeedTie` note below). The tie is the *only* order-stage RNG draw.
* **The damaging-move pipeline** (`core.asm:3140-3150`, mirrored 5531-5543):
  `CriticalHitTest → … → CalculateDamage → AdjustDamageForMoveType →
  RandomizeDamage → MoveHitTest`. So per attack the RNG is drawn in this order:
  1. **crit** — `CriticalHitTest` always draws for a power>0 move
     (`core.asm:4534`); it rotates the byte left three times and crits iff
     `rotl3(rand) < threshold` (`core.asm:4535-4538`).
  2. **randomize** — `RandomizeDamage` draws *only* when the typed damage is
     `≥ 2` (`cp 2; ret c` guards the `BattleRandom`), scaling by `rand/255`.
  3. **accuracy** — `MoveHitTest` draws *unless* the move always hits
     (Swift / X Accuracy `ret` before the roll); it hits iff `rand < accuracy`
     (`cp b; jr nc, .moveMissed`, `core.asm:5325`), so the ceiling is 255/256 —
     the 1/256 miss bug. On a miss the ROM zeroes `wDamage` (`core.asm:5328`).

## Scope

This is the ordinary damaging-move exchange. `ResolvedMove` is *parameterised*
(a move-data decoder fills it — `COORDINATION.md` seam 3), and the crit threshold
+ effective (post-`CalcHitChance`) accuracy are supplied, since deriving them
needs the base-stat / stat-mod / high-crit tables (their own layer). Deferred:
non-fight actions (switch / run / item), status & multi-turn move effects,
residual damage (poison / burn / Leech Seed), stat-stage scaling of the attack /
defence stats and the crit reset to unmodified stats, party switching, and the
double-KO ordering. This kernel is what the request/response machine (SPEC §8.2)
wraps; `List TurnEvent` is the model-side checkpoint trace the `Refinement/`
layer serialises to the byte-level `Battle.Trace` (SPEC §8.3).
-/

namespace Battle.Step

/-! ## Resolved per-turn inputs -/

/-- A move's turn-order class. Gen 1 has no per-move priority field; order is
    decided by three named cases plus Speed (`core.asm:370-391`). -/
inductive Priority where
  /-- Quick Attack — acts before a normal move. -/
  | quickAttack
  /-- Any ordinary move. -/
  | normal
  /-- Counter — acts after a normal move. -/
  | counter
  deriving Repr, DecidableEq, BEq

/-- One side's resolved move for the turn — the `wMoveNum` scratch a move-data
    decoder fills, plus the two values the accuracy/crit sub-models produce.
    Parameterised, not read from a table here (`COORDINATION.md` seam 3). -/
structure ResolvedMove where
  /-- The move's ID (for the checkpoint log). -/
  id : MoveId
  /-- Base power; `0` is a status move (out of this kernel's scope). -/
  power : UInt8
  /-- The move's elemental type (STAB / effectiveness fold). -/
  type : UInt8
  /-- Effective accuracy *after* `CalcHitChance` stage-scaling; hit iff the roll
      is strictly below it. -/
  accuracy : UInt8
  /-- Swift / X Accuracy: skip the accuracy roll entirely (no RNG drawn). -/
  alwaysHits : Bool := false
  /-- `CriticalHitTest`'s threshold `b`; crit iff `rotl3(roll) < critThreshold`.
      `0` never crits. -/
  critThreshold : UInt8 := 0
  /-- The move's turn-order class. -/
  priority : Priority := .normal
  deriving Repr, DecidableEq, BEq

/-! ## Checkpoint log -/

/-- One semantic checkpoint emitted while resolving a turn. These correspond to
    the SPEC §8.3 checkpoints a full battle loop instruments (order fixed, before
    each acting side, after damage, before/after faint, witnessed terminal); the
    authoritative `BattleTerminal` on a terminal turn is carried in the returned
    state's `phase` (`.ending witness`). -/
inductive TurnEvent where
  /-- Order resolved: `first` acts first; `viaSpeedTie` iff a `BattleRandom` coin
      broke a Speed tie. -/
  | orderDecided (first : Side) (viaSpeedTie : Bool)
  /-- `attacker` begins its move. -/
  | attackStart (attacker : Side) (move : MoveId)
  /-- `attacker`'s hit was a critical hit. -/
  | critical (attacker : Side)
  /-- `attacker`'s move missed (accuracy roll or a type-immunity zero). -/
  | missed (attacker : Side)
  /-- `attacker` dealt `amount`, leaving the defender at `defenderHpAfter`. -/
  | damageDealt (attacker : Side) (amount : UInt16) (defenderHpAfter : UInt16)
  /-- `side`'s active mon fainted. -/
  | fainted (side : Side)
  /-- The battle reached a terminal with this cause / verdict. -/
  | terminalReached (cause : Outcome.TerminalCause) (verdict : Option Outcome.BattleVerdict)
  deriving Repr, DecidableEq, BEq

/-! ## Primitive mechanics -/

/-- `50 percent + 1` = `50 * $ff / 100 + 1` = `127 + 1`. The Speed-tie coin
    compares `BattleRandom` against this: `rand < 128` → player first. -/
def speedTieThreshold : UInt8 := 128

/-- Compatibility alias for the shared exact critical comparison. -/
def critHits (threshold rand : UInt8) : Bool := Critical.occurs threshold rand

/-- 16-bit HP subtraction clamped at 0, matching `ApplyDamage`'s underflow guard
    (the ROM sets HP to 0 rather than wrapping). -/
def saturatingSub (hp dmg : UInt16) : UInt16 :=
  if hp ≤ dmg then 0 else hp - dmg

/-! ## Turn order (`core.asm:370-412`) -/

/-- Speed comparison and its `BattleRandom` tie-break. Returns the first mover,
    whether a tie coin was flipped, and the advanced RNG (drawn only on a tie). -/
def speedFirst (pSpeed eSpeed : UInt16) (rng : Rng.LinkRng) : Side × Bool × Rng.LinkRng :=
  if pSpeed > eSpeed then (.player, false, rng)
  else if eSpeed > pSpeed then (.enemy, false, rng)
  else
    let (b, rng') := rng.next
    (if b < speedTieThreshold then .player else .enemy, true, rng')

/-- Resolve turn order: Quick Attack ≻ normal ≻ Counter, else Speed, else the
    coin. Matches the nested `core.asm:370-412` branch structure exactly. -/
def turnOrder (pPrio ePrio : Priority) (pSpeed eSpeed : UInt16) (rng : Rng.LinkRng) :
    Side × Bool × Rng.LinkRng :=
  match pPrio, ePrio with
  | .quickAttack, .quickAttack => speedFirst pSpeed eSpeed rng   -- both QA → speed
  | .quickAttack, _            => (.player, false, rng)          -- player QA only
  | _, .quickAttack            => (.enemy, false, rng)           -- enemy QA only
  | .counter, .counter         => speedFirst pSpeed eSpeed rng   -- both Counter → speed
  | .counter, _                => (.enemy, false, rng)           -- player Counter → enemy first
  | _, .counter                => (.player, false, rng)          -- enemy Counter → player first
  | _, _                       => speedFirst pSpeed eSpeed rng   -- two normal moves → speed

/-! ## One attack -/

/-- Resolve `attacker`'s move against the defender: draw crit, compute base+type
    damage, draw randomisation (if ≥ 2), draw accuracy (unless always-hit),
    subtract HP (clamped), and report a faint as a terminal. Returns the updated
    state (RNG advanced, defender HP set), the emitted events, and the terminal
    if the defender fainted.

    Faint ⇒ terminal here because switching is not modelled yet: a downed active
    mon ends the battle as `partyExhausted defender` (single-mon-party
    assumption). The verdict is the player's: enemy down → win (`rawResult 0`),
    player down → loss (`rawResult 1`). -/
def resolveAttack (s : BattleState) (attacker : Side) (move : ResolvedMove) :
    BattleState × List TurnEvent × Option Outcome.BattleTerminal :=
  let defender := attacker.other
  let atkMon := s.active attacker
  let defSide := s.side defender
  let defMon := defSide.active
  -- (1) CriticalHitTest — always draws for a power>0 move (core.asm:4534).
  let (critByte, rng1) := s.rng.next
  let crit := critHits move.critThreshold critByte
  -- CalculateDamage + AdjustDamageForMoveType (no RNG).
  let base := Damage.calcBaseDamage atkMon.level crit move.power atkMon.attack defMon.defense
  let typed := Damage.adjustDamageForType move.type atkMon.type1 atkMon.type2
                 defMon.type1 defMon.type2 base
  -- (2) RandomizeDamage — draws only when typed damage ≥ 2 (cp 2; ret c).
  let (final, rng2) :=
    if typed < 2 then (typed, rng1)
    else
      let (b, r) := rng1.next
      (Damage.randomizeDamage b typed, r)
  -- (3) MoveHitTest — draws unless always-hit; hit iff rand < accuracy.
  let (hit, rng3) :=
    if move.alwaysHits then (true, rng2)
    else
      let (b, r) := rng2.next
      (decide (b < move.accuracy), r)
  let dealt : UInt16 := if hit then final else 0
  let newHp := saturatingSub defMon.hp dealt
  let s := ({ s with rng := rng3 }).setSide defender { defSide with active := { defMon with hp := newHp } }
  let fainted := newHp == 0
  let events : List TurnEvent :=
    TurnEvent.attackStart attacker move.id ::
    (if !hit then [TurnEvent.missed attacker]
     else (if crit then [TurnEvent.critical attacker] else []) ++
          [TurnEvent.damageDealt attacker dealt newHp]) ++
    (if fainted then [TurnEvent.fainted defender] else [])
  let terminal : Option Outcome.BattleTerminal :=
    if fainted then
      some (Outcome.BattleTerminal.mk' (.partyExhausted defender) s.mode .player
              (if defender == .enemy then 0 else 1))
    else none
  (s, events, terminal)

/-! ## The turn -/

/-- Resolve a full fight-vs-fight turn: order the two sides, resolve the first
    attacker, and — unless it ended the battle — the second, incrementing the
    completed-turn counter once both have acted. On a terminal the returned state
    enters `phase := .ending witness`. This is the `BattleState → (resolved
    action) → (resolved action) → BattleState × trace` kernel of SPEC §8.2. -/
def resolveTurn (pMove eMove : ResolvedMove) (s : BattleState) : BattleState × List TurnEvent :=
  let (first, viaTie, rng') := turnOrder pMove.priority eMove.priority
      (s.active .player).speed (s.active .enemy).speed s.rng
  let s := { s with rng := rng' }
  let moveOf : Side → ResolvedMove := fun side => match side with
    | .player => pMove
    | .enemy => eMove
  let ev0 := [TurnEvent.orderDecided first viaTie]
  let (s1, ev1, term1) := resolveAttack s first (moveOf first)
  match term1 with
  | some t => ({ s1 with phase := .ending t },
               ev0 ++ ev1 ++ [TurnEvent.terminalReached t.cause t.verdict])
  | none =>
    let second := first.other
    let (s2, ev2, term2) := resolveAttack s1 second (moveOf second)
    let s2 := { s2 with turn := s2.turn + 1 }
    match term2 with
    | some t => ({ s2 with phase := .ending t },
                 ev0 ++ ev1 ++ ev2 ++ [TurnEvent.terminalReached t.cause t.verdict])
    | none => (s2, ev0 ++ ev1 ++ ev2)

/-! ## Scripted play

A thin driver that folds `resolveTurn` across a fixed list of per-turn move pairs
— the deterministic backbone a scripted battle (and the `#guard` fixtures) runs
on. Once a terminal is reached the fold no-ops every remaining turn, so the RNG
is never advanced past the faint and a script longer than the battle yields the
same state as one cut to length. -/

/-- Resolve one scripted turn, or leave a finished battle untouched. -/
def stepTurn (moves : ResolvedMove × ResolvedMove) (s : BattleState) : BattleState × List TurnEvent :=
  if s.phase.isTerminal then (s, [])
  else resolveTurn moves.1 moves.2 s

/-- Play a fixed script of `(playerMove, enemyMove)` turns, threading the state
    and concatenating each turn's event log, stopping at the first terminal. -/
def runScript (script : List (ResolvedMove × ResolvedMove)) (s : BattleState) :
    BattleState × List TurnEvent :=
  script.foldl
    (fun (acc : BattleState × List TurnEvent) mv =>
      let (s', ev) := stepTurn mv acc.1
      (s', acc.2 ++ ev))
    (s, [])

/-! ## Fidelity guards -/

-- Primitive mechanics.
#guard saturatingSub 20 22 == 0
#guard saturatingSub 100 30 == 70
#guard saturatingSub 5 5 == 0
#guard critHits 0 200 == false          -- threshold 0 never crits
#guard critHits 255 0 == true           -- rotl3(0)=0 < 255
#guard critHits 128 0 == true
#guard speedTieThreshold.toNat == 50 * 255 / 100 + 1

-- Turn order: priority, speed, and the tie coin.
#guard (turnOrder .normal .normal 100 50 Rng.seed0).1 == .player        -- player faster
#guard (turnOrder .normal .normal 100 50 Rng.seed0).2.1 == false        -- no tie coin
#guard (turnOrder .normal .normal 50 100 Rng.seed0).1 == .enemy         -- enemy faster
#guard (turnOrder .normal .normal 50 50 Rng.seed0).1 == .player         -- tie, seed byte 0 < 128
#guard (turnOrder .normal .normal 50 50 Rng.seed0).2.1 == true          -- tie coin flipped
#guard (turnOrder .quickAttack .normal 1 100 Rng.seed0).1 == .player    -- QA beats speed
#guard (turnOrder .normal .quickAttack 100 1 Rng.seed0).1 == .enemy     -- enemy QA beats speed
#guard (turnOrder .counter .normal 100 1 Rng.seed0).1 == .enemy         -- player Counter goes last
#guard (turnOrder .normal .counter 100 1 Rng.seed0).1 == .player        -- enemy Counter goes last
#guard (turnOrder .quickAttack .counter 1 1 Rng.seed0).1 == .player     -- QA vs Counter → QA

/-- A representative active mon: L50 Fire/Flying, one 40-BP move slot. -/
private def mkMon (hp speed : UInt16) : MonState :=
  { species := 6, hp, boxLevel := 50, status := 0, type1 := 0x14, type2 := 0x02,
    catchRate := 45, moves := #[52, 0, 0, 0], dvs := 0xFFFF, level := 50,
    maxHp := 100, attack := 80, defense := 70, speed, special := 90, pp := #[15, 0, 0, 0] }

/-- A 40-BP Normal move that always hits and never crits (deterministic). -/
private def normalHit : ResolvedMove :=
  { id := 33, power := 40, type := 0x00, accuracy := 255, alwaysHits := true }

-- Base damage L50/40-BP/80-atk/70-def, no crit: floor(2·50/5)+2 = 22; 22·40·80/70/50 = 20; +2 = 22.
#guard Damage.calcBaseDamage 50 false 40 80 70 == 22

/-! ### Scenario A — player faster, full randomisation, enemy faints -/

private def seedHi : Rng.LinkRng := { list := #[0, 255, 0, 255, 0, 255, 0, 255, 0, 255], index := 0 }
private def battleFaint : BattleState :=
  BattleState.start (mkMon 100 100) (mkMon 20 50) seedHi
private def afterFaint : BattleState × List TurnEvent := resolveTurn normalHit normalHit battleFaint

-- Player acts first (100 > 50); crit byte 0 (no crit), randomise byte 255 (×255/255 = full 22),
-- always-hits (no accuracy draw). Enemy 20 HP − 22 → 0: faints before it can act.
#guard afterFaint.1.phase.isTerminal == true
#guard (afterFaint.1.active .enemy).hp == 0
#guard (afterFaint.1.active .enemy).fainted == true
#guard (afterFaint.1.active .player).hp == 100        -- enemy never got to attack
#guard afterFaint.2.contains (TurnEvent.orderDecided .player false)
#guard afterFaint.2.contains (TurnEvent.damageDealt .player 22 0)
#guard afterFaint.2.contains (TurnEvent.fainted .enemy)
#guard afterFaint.2.contains (TurnEvent.terminalReached (.partyExhausted .enemy) (some .win))

/-! ### Scenario B — both survive a near-zero roll, the turn counter advances -/

private def seedLo : Rng.LinkRng := { list := #[0, 1, 0, 1, 0, 1, 0, 1, 0, 1], index := 0 }
private def battleNoFaint : BattleState :=
  BattleState.start (mkMon 100 100) (mkMon 100 50) seedLo
private def afterNoFaint : BattleState × List TurnEvent := resolveTurn normalHit normalHit battleNoFaint

-- Randomise byte 1 makes each hit floor(22·1/255) = 0, so nobody faints and the turn completes.
#guard afterNoFaint.1.phase.isTerminal == false
#guard afterNoFaint.1.turn == 1
#guard (afterNoFaint.1.active .player).hp == 100
#guard (afterNoFaint.1.active .enemy).hp == 100
#guard afterNoFaint.2.contains (TurnEvent.damageDealt .player 0 100)
#guard afterNoFaint.2.contains (TurnEvent.damageDealt .enemy 0 100)

end Battle.Step
