# ROM-to-battle-model equivalence audit

<!-- mode: research -->

This audit asks whether the current repository proves that
`Battle.Full.Environment` has the same battle behavior as the canonical Pokémon
Red ROM. It does not. Several strong components exist, but they do not yet
compose into a whole-turn simulation or a whole-battle behavior theorem.

## Current theorem boundary

| Boundary | Current result | What is still missing |
|---|---|---|
| SM83 declarative to functional execution | Universal local refinement for every legal base and CB opcode | Continuous system execution through all battle interrupts, HALT waits, and device interactions |
| Functional to fetched-IR execution | Local sequence and retirement theorems, including successor-fetch overlap | Continuous composition across the complete driver |
| Game Boy adapter | Eight-half-edge machine-cycle composition and concrete `InitOpponent` prefix | Full device-qualified execution through presentation and serial waits |
| Canonical ROM identity | Caller-supplied hash and exact byte/table windows | An in-tree proof witness is impossible while the ROM remains unvendored |
| Data and dispatch | Move/species/progression tables, effect phase tables, and handler pointers | Handler-pointer equality does not prove handler bodies |
| Selected handler bodies | Decoded functional and fetched-IR summaries for several leaf handlers | Most transitive callees, turn orchestration, menus, and presentation paths |
| Driver closure | `DriverClosure.Certificate` permits only actual adapter cycles and proves conditional `InitOpponent`-to-return composition | No concrete `OneMemberWildFixture` inhabits the certificate |
| High-level model to `Battle.Episode` | Terminal model traces refine the coarse episode protocol | `Battle.Episode` is not the ROM; this theorem drops numeric mechanics details |
| High-level transcript to driver | Both can be required by one proof-carrying fixture | No per-request or per-turn state simulation relates them |

The most important negative finding is that
`Battle.Refinement.runScript_refines` is a protocol-shape theorem. It proves that
a terminal model trace can drive `Battle.Episode` to `returned`; it does not
prove that the ROM produced the same attacks, damage, RNG calls, state updates,
or terminal result.

## Concrete link relation

`Battle.Rom.FullStateProjection` reads both live 29-byte battle structs through
`GameBoy.Memory.read` and retains lossless `BattleMon` witnesses.
`Battle.Rom.LinkStateProjection` now lifts that boundary to two cartridge
perspectives and additionally relates:

- both persistent party counts and every admitted 44-byte party row;
- local and remote active indexes;
- unmodified combat stats and all eight stage bytes;
- raw volatile status bytes and their counters;
- loaded species identity;
- link mode, all ten RNG bytes, and both cursors;
- complementary clock orientation and synchronized pair predicates;
- fetched canonical `InitOpponent` on both processors.

Every active and party witness re-encodes to the exact mapped WRAM bytes. The
live struct's aliased byte three is related to `partyPosition`; persistent
`boxLevel` is retained from the party row rather than conflated with that byte.
The relation still omits selected/loaded move records, shared damage/order scratch,
replacement and terminal bytes, serial transfer phase, and later control
locations. It therefore remains a checkpoint component rather than a whole-turn
simulation.

## Minimum theorem that would justify the training engine

For the synchronized full-link profile, the required theorem has this shape:

```text
related lowBefore highBefore
machine behavior lowBefore input/link/chance trace lowAfter
high-level normalized request highBefore typed responses highAfter
-----------------------------------------------------------------
related lowAfter highAfter
and projected observations/RNG/input/link events agree
```

The theorem must cover finite transitions and silent/reactive divergence. A
fuel-exhausted machine run cannot be mapped to a high-level result. The relation
must include:

1. both active battle structs;
2. six persistent party rows and active indexes;
3. unmodified stats, stages, volatile flags, and counters;
4. selected/loaded move records and shared damage scratch;
5. link RNG block/index and the projected random call sequence;
6. replacement and nested-request control location;
7. terminal provenance before cleanup;
8. stack, bank, carry, and return state after cleanup.

## Shortest honest route

1. Complete `LinkStateProjection` with move/order/damage/replacement/terminal
   scratch, serial phase, and phase-indexed control locations.
2. Prove every generated reset encodes to two related post-handshake machines.
3. Replace the abstract transitions in `LinkEquivalence.Obligations` with the
   concrete interleaved `LinkAdapter` block relation and typed high requests.
4. Prove one canonical action-selection trace reaches a `StartBattle` request
   checkpoint related to one high-level action pair.
5. Prove one complete ordinary damaging turn, including all link RNG reads and
   the no-faint path.
6. Add miss, critical, status block, faint, forced replacement, and switch paths.
7. Compose selected leaf-handler refinements into effect dispatch.
8. Prove both link epilogues and outer returns.
9. Prove reverse realizability, synchronized-quotient preservation, and the RL
   feature/mask/serialization boundary.

Whole-ROM equivalence cannot be obtained by adding a theorem whose premises
simply assume the high-level replay result. Each transition needs a low-to-high
simulation from decoded ROM execution. Until those steps close, the training
model remains theorem-backed but not proved behaviorally equivalent to Pokémon
Red.
