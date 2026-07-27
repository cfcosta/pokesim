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

## New concrete relation

`Battle.Rom.FullStateProjection` now reads both live 29-byte battle structs
through `GameBoy.Memory.read` at `$D014` and `$CFE5`, decodes them with the
lossless `BattleMon` codec, and relates every field to the corresponding active
`MonState` in `Full.Environment.State`.

The module proves:

- any successful mapped decode re-encodes to the exact 29 bytes read from WRAM;
- both active structs expose those exact byte equalities through the relation;
- the semantic projection is unique;
- player and enemy HP use the exact big-endian byte interpretation;
- every projected active mon has exactly four move and PP entries.

This closes only the active-struct codec boundary. It deliberately does not
claim party, volatile, scratch, RNG, control-location, or transition agreement.

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

1. Extend `FullStateProjection` to volatile, stages, move scratch, shared damage,
   parties, and link RNG.
2. Prove one canonical action-selection trace reaches a `StartBattle` request
   checkpoint related to one high-level action pair.
3. Prove one complete ordinary damaging turn, including all random reads and the
   no-faint path.
4. Add miss, critical, status block, faint, forced replacement, and switch paths.
5. Compose selected leaf-handler refinements into effect dispatch.
6. Inhabit `OneMemberWildFixture` with caller-supplied canonical ROM witnesses
   and actual adapter cycles.
7. Generalize the one-member episode to six-member paired link behavior and
   classify known desynchronizations.

Whole-ROM equivalence cannot be obtained by adding a theorem whose premises
simply assume the high-level replay result. Each transition needs a low-to-high
simulation from decoded ROM execution. Until those steps close, the training
model remains theorem-backed but not proved behaviorally equivalent to Pokémon
Red.
