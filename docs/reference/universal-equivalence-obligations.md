# Universal ROM/model equivalence proof obligations

<!-- mode: reference -->

**Target ROM:** Pokémon Red, SHA-1
`ea9bcae617fdf159b045185467ae58b2e4a48b9a`, SHA-256
`5ca7ba01642a3b27b0cc0b5349b52792795b62d3ed977e98a09390659af96b7b`.

**Target machine profile:** DMG-CPU B plus an explicitly named board/device
profile. The ROM remains caller-supplied, so the final theorem is conditional on
`CanonicalRom.Valid` and exact byte witnesses rather than an in-tree ROM value.

This page records the obligations for a universal battle-driver equivalence
claim. “Universal” quantifies over every behavior admitted by a named entry
domain and environment schedule. It does not quantify over arbitrary corrupt
CPU states and it does not assume that a battle terminates.

## Required claim

The final result is an observational behavior equivalence, not raw trace
equality. Presentation instructions may stutter, but their timing, interrupts,
controller consumption, bank/stack effects, and writes outside a proved frame
remain on the low side.

For each mode and entry domain, the ROM-to-model direction has this shape:

```text
CanonicalRom.Valid sha rom
∧ Entry mode domain low₀
∧ Related mode phase.entry low₀ high₀
∧ LowBehavior low₀ externalSchedule lowBehavior
──────────────────────────────────────────────────
∃ highBehavior,
  HighBehavior high₀ (project externalSchedule) highBehavior
  ∧ BehaviorRefines projectEvents outcomeRel lowBehavior highBehavior
```

An equivalence claim also needs model realizability:

```text
Related mode phase.entry low₀ high₀
∧ HighBehavior high₀ semanticSchedule highBehavior
∧ Admissible semanticSchedule
──────────────────────────────────────────────────
∃ externalSchedule lowBehavior,
  projectsTo externalSchedule semanticSchedule
  ∧ LowBehavior low₀ externalSchedule lowBehavior
  ∧ BehaviorRefines projectEvents outcomeRel lowBehavior highBehavior
```

The second direction prevents the high-level engine from admitting actions,
random transcripts, or outcomes that no cartridge execution can produce.
Determinism alone does not discharge this obligation when the high model accepts
an unconstrained software RNG stream.

## Claim families

| Family | Low state | High state | Entry domain | Exit |
|---|---|---|---|---|
| Supplied wild | One DMG machine | `Full.Environment.State` | Explicit nonzero opponent and supplied-wild reset | Outer restored return, divergence, or reactive wait |
| Trainer | One DMG machine | `Full.Environment.State` | Trainer class/number, party, AI, caller text state | Outer restored return, divergence, or reactive wait |
| Safari | One DMG machine | `Full.Environment.State` | Safari battle type, factors, Ball count | Outer restored return, divergence, or reactive wait |
| Old Man | One DMG machine | `Full.Environment.State` | Tutorial caller/name/alias state | Outer restored return, divergence, or reactive wait |
| Link | Two DMG machines plus cable/clock state | `Full.Link.Pair` | Party/name exchange, clock roles, two RNG handshakes | Both driver returns, conditional desynchronization, or reactive wait |
| Raw/glitch | One or two DMG machines | A partial/raw high relation | Named byte predicate | Matching finite behavior or classified divergence |
| RL link profile | Two DMG machines plus cable/clock state | Synchronized quotient of a proved `Full.Link.Pair` | Encoded generated teams and deterministic link handshake | One request checkpoint, terminal return, or classified divergence |

Overworld encounter selection, blackout continuation, map-script trainer flags,
post-link `HealParty`, and post-tutorial script restoration are separate caller
integration theorem families. They are not part of the battle-driver theorem.

## Verified current boundary

| Layer | Existing evidence | Universal status |
|---|---|---|
| ROM identity | Canonical hashes, reproducible source build, exact window/table predicates | Conditional identity boundary exists; no vendored theorem inhabitant |
| SM83 architectural semantics | Decoder partition and local refinement for 242 ordinary legal base entries and all 256 CB entries | Local instruction layer closed; continuous system lifting remains incomplete |
| Fetched physical core | Per-family fetched-IR proofs, retirement model, behavior-lifting framework | No complete canonical driver execution theorem |
| Game Boy adapter | Eight-half-edge M-cycle composition, temporal read folding, MBC3/memory/timer/basic PPU/joypad/serial/DMA, plus an interleaved two-console cable adapter | Device profile is insufficient for all reachable presentation and interrupt paths; the complete ROM serial protocol is not yet simulated |
| Canonical entry | `AtInitOpponentReady` and a proved finite prefix through the initial jump intent | Only the initial prefix is continuously discharged |
| Link-state projection | Two active structs, both persistent party images, active indexes, unmodified stats, stages, volatile bytes/counters, loaded species, link mode, complete ten-byte RNG images/cursors, and clock orientation for both endpoints | Selection/damage/order/replacement/terminal scratch, serial phase, and full control-location relations remain absent |
| High model | Executable full environment, nested requests, paired model, terminal provenance | No ROM-to-`Full.Environment` step simulation |
| Coarse episode protocol | `tracked_directSimulation`, `canonical_useFinite`, `runScript_refines` | Protocol shape only; numeric mechanics are not related |
| Driver closure | `DriverClosure.Certificate` packages actual adapter-cycle segments | Certificate supplies the missing execution; `OneMemberWildFixture` has no inhabitant |
| Reachability | 1,026 conservative reachable ranges, 11,944 retained control edges, 73 explicit indirect sites, zero unresolved generated edges | Classification is not a theorem-disposition proof for every range |
| RL adapter | Typed replay and local codec/action facts | No machine/model transition or observation equivalence |
| Link | `Full.Link.Pair`, wire codec, mirrored-state checks, named desync causes | No two-cartridge ROM simulation or quotient theorem |
| Whole behavior | Generic finite/divergent/reactive lifting in `Sm83.Simulation` | Missing concrete local simulation, final relation, and reaction-preservation proofs |

`Battle.Refinement.runScript_refines` and
`Battle.DriverInvariant.tracked_directSimulation` cannot close the universal
claim. Their high state records phase, turn, and counters but no party, PP,
damage, status, RNG, action, or nested-request state. Checkpoint predicates are
caller-supplied and therefore do not prove that ROM execution reaches the same
mechanics state as `Full.Environment`.

## Mandatory obligations

| ID | Obligation | Required theorem or artifact | Current blocker |
|---|---|---|---|
| UEE-01 | Domain-indexed statement | Definitions of `EntryDomain`, `LowBehavior`, `HighBehavior`, `Related`, `projectEvents`, and `outcomeRel` | `LinkEquivalence` now states the generated-team post-handshake claim and composes a conditional bidirectional certificate; concrete low/high transition relations still have to inhabit that contract |
| UEE-02 | Artifact binding | Canonical ROM validity plus exact table/range witnesses used by every machine summary | Runtime fixture evidence is not an unconditional Lean witness |
| UEE-03 | Complete low machine | Every reachable M-cycle executes under a sufficient DMG-B device model or proved summary | STAT/PPU access, presentation MMIO, audio waits, detailed OAM/DMA, and profile-qualified STOP/reset behavior remain incomplete |
| UEE-04 | Continuous processor/system refinement | Fetched-IR M-cycles compose through normal instructions, interrupts, HALT, waits, bank switches, and return | Existing continuous proof covers only the entry prefix; later cycles are certificate fields |
| UEE-05 | Proof-bearing reachability closure | Every reachable code/data/interrupt/presentation range has an exact theorem disposition and frame | Generated overapproximation has no theorem identifier and dependency proof per range |
| UEE-06 | Phase-indexed full state relation | Low WRAM/HRAM/control state relates all high mechanics fields at each checkpoint | The link relation now covers active structs, persistent parties, indexes, unmodified stats, stages, volatile state, loaded identity, mode, RNG, and orientation; selection/damage/order/replacement/terminal scratch, serial phase, and control remain |
| UEE-07 | High reactive semantics | A relational high step consumes typed actions, nested answers, ordinary/link randomness, and reactive waits while emitting source/site-labelled events | `Environment.step` is a function over actions and an internal `LinkRng`; ordinary hardware randomness is not an explicit response relation |
| UEE-08 | Reset/encoding relation | Every admitted high reset encodes to low bytes and establishes `Related`; decoding is unique on projected fields | Paired high resets now install the exact supplied generated parties and start mirrored, but no theorem encodes those resets into both post-handshake cartridge WRAM images |
| UEE-09 | RNG/input/link trace coupling | ROM `Random_`/`BattleRandom`, joypad commits, serial bytes, and nested menu choices project to the exact high request trace | Current projection observes raw `rDIV`, `rP1`, and `rSB` reads without proving semantic call sites or returned random bytes |
| UEE-10 | Checkpoint local simulations | Selection, order, status gate, move, damage, effect, residual, faint, replacement, progression, terminal, and cleanup each preserve `Related` and projected traces | The bounded player `ApplyDamageToEnemyPokemon` slice relates HP/actual-damage words. Decoded player/enemy status-gate kernels and all six charge setup/continuation windows now have local exhaustive theorems, but they are not yet lifted through the complete phase-indexed state relation or composed into one ordinary turn |
| UEE-11 | Presentation frames | Each hidden text/animation/audio/HUD summary proves writes, timing, interrupts, controller consumption, MMIO, bank, stack, and divergence | No presentation summary currently has this contract |
| UEE-12 | Terminal/final compatibility | Pre-cleanup cause/result, epilogue mutations, restored caller frame, carry, bank, stack, and final party agree | Driver checkpoints carry terminal bytes but do not relate complete high state |
| UEE-13 | Infinite behavior | Silent loops, division freezes, menu traps, HALT/audio/serial waits, and reactive behavior map without using fuel as semantics | Concrete reaction-preservation and high coinductive transitions are absent |
| UEE-14 | Paired link simulation | Two physical machines and cable schedule refine `Full.Link.Pair`; synchronized quotient is justified only while invariant holds | Interleaved cable clocking and full-duplex byte exchange are executable and ROM-preserving; PP ownership, complete serial scheduling/protocol execution, handshake asymmetry, quotient preservation, and known desync paths still lack composed ROM-level proofs |
| UEE-15 | Reverse realizability | Every admitted high action/chance/request behavior has a low controller/serial/hardware schedule or is excluded by `Admissible` | High software RNG and action-commit APIs admit schedules not yet shown cartridge-realizable |
| UEE-16 | RL boundary | Feature vectors, legal masks, handles, batch/compaction, terminal labels, and native serialization preserve the proved high state and transition | Local round trips exist; universal observation injectivity and transition-kernel preservation do not |
| UEE-17 | Final coverage gate | The episode theorem and theorem-disposition manifest jointly cover every in-scope range and mode | Neither artifact is complete |

## Required full-state relation

`Related mode phase low high` contains at least the following projections and
control facts:

- both active 29-byte structs and both unmodified stat blocks;
- six persistent party rows, counts, species lists, names, and active indexes;
- stages, status bytes, volatile flags, counters, substitute/Bide/trapping state;
- selected/highlighted/loaded moves, move effects, disabled records, shared damage,
  last-move fields, and order scratch;
- gain-EXP/fought-current-enemy participation bytes;
- inventory, money/Pay Day, Pokédex, capture/box, learning, and evolution state;
- trainer AI counters, class metadata, and controller state;
- battle mode, forced replacement, nested request, and terminal provenance;
- ordinary RNG source state or explicit response suffix;
- each link cartridge's ten-byte random block/index and serial perspective;
- selected ROM bank, stack/return frame, fetched IR, pipeline latches, IME,
  interrupt state, and checkpoint control location;
- device/presentation state retained by frame relations when absent from the high
  mechanics state.

The relation is phase-indexed because WRAM unions and stale scratch bytes have
different meanings at initialization, selection, move execution, residual,
replacement, ending, and returned checkpoints.

## Required checkpoint simulations

| Checkpoint transition | Minimum visible agreement |
|---|---|
| Entry → mode setup | Parties, mode, trainer/wild/link load, active rows, RNG setup |
| Menu → action commit | Every legal move/switch, ineffective attempts, automatic turns, wire/controller bytes |
| Commit → order | Priority, speed tie, link clock-role inversion, RNG site sequence |
| Order → status gate | Sleep/freeze/paralysis/confusion/flinch/recharge and retained move provenance |
| Status gate → damage | Accuracy, critical, stats/stages, STAB/type, random factor, substitute, shared scratch |
| Damage → effect | Exact dispatch target, handler body, PP ownership, generated/nested move recurrence |
| Effect → residual | Poison/burn/Leech Seed/Toxic counter ordering and faint checks |
| Faint → replacement | Active/party synchronization, simultaneous faint order, forced/queued replacement |
| Turn end → next request | Cleared/stale volatile fields, disable counters, legal mask, RNG suffix |
| Terminal → ending | Non-forgeable cause/result witness before cleanup erasure |
| Ending → returned | Payout, EXP/learning/evolution, cleanup, caller restoration, carry/bank/stack |

Each row requires a low machine execution or a transitive set of proved routine
summaries. A replay fixture, decoded window, handler-pointer equality, or
high-level theorem alone is not a transition simulation.

`Battle.Rom.DamageApplyRoutine.canonical_player_damage_transition_refines` is
the first bounded checkpoint slice satisfying both sides in one theorem. Given
caller-supplied canonical identity/window witnesses, no Substitute, nonzero
damage, and HP/damage words below 1000, it executes `$0f:$6142` to `$617b`
through the decoded SM83 semantics and proves equality with
`Battle.Full.Engine.applyDamage` for target HP and actual `wDamage`. It does not
establish G1, G2, or G3: the relation omits the rest of WRAM/control state and
the slice starts after action, RNG, hit, and damage calculation.

## Dependency gates

| Gate | Closure condition | Unlocks |
|---|---|---|
| G0 — theorem contract | Replace `LinkEquivalence.Obligations`' abstract transition fields with concrete paired low/high behavior definitions and retain the compiled bidirectional theorem | Stable meaning of “equivalent” |
| G1 — one checkpoint relation | UEE-06 for one-member supplied wild entry/action/terminal fields | Non-vacuous low/high statements |
| G2 — semantic response trace | UEE-07 and UEE-09 for one ordinary damaging turn | RNG/action-sensitive refinement |
| G3 — first vertical turn | Entry-to-next-request or entry-to-terminal simulation for one-member wild | First transition-verified mechanics slice |
| G4 — first physical episode | Inhabited canonical one-member fixture with no supplied battle-cycle segment | First episode-verified slice |
| G5 — kernel closure | All ordinary turn, switch/faint, nested, item, capture, and terminal paths | Battle-kernel theorem |
| G6 — driver closure | Initialization, progression, cleanup, presentation frames, outer return | Single-cartridge driver theorem |
| G7 — link closure | UEE-14 plus synchronized-quotient theorem and named desync behaviors | Training-profile ROM equivalence |
| G8 — model realizability | UEE-15 for the claimed domain | Observational equivalence rather than one-way soundness |
| G9 — RL closure | UEE-16 and complete theorem-disposition manifest | Formally justified native training environment |

## Acceptable exclusions

The battle-driver equivalence may hide pixel values, tile contents, animation
frames, audio waveforms, and text glyphs only behind proved presentation frames.
It may not hide:

- writes to mechanics/caller-visible memory;
- elapsed timing that changes interrupts or later RNG;
- joypad or serial bytes consumed;
- bank, stack, register, or flag facts required by callers;
- MMIO, VRAM, OAM, DMA, or SRAM effects read later;
- termination, blocking, or divergence behavior.

Fuel exhaustion, horizon truncation, blocked requests, nested-open menus,
RNG-stuck states, division freezes, and semantic cycles never imply a terminal
result.

## Claim threshold

A “formally verified 1:1 battle simulator” claim requires all of the following:

1. ROM-to-model whole-behavior refinement for every claimed mode/domain;
2. model realizability for every admitted semantic schedule;
3. finite, silent-divergent, and reactive behavior coverage;
4. paired-cartridge refinement for the RL link profile;
5. complete theorem-disposition closure for reachable ROM ranges;
6. RL adapter transition and label preservation if the training environment is
   included in the claim.

Until those conditions hold, the accurate statement remains: the model is
extensively theorem-backed and ROM-linked at selected routines, but it is not
universally behaviorally equivalent to Pokémon Red's battle driver.
