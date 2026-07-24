# End-to-end verification closure

<!-- mode: reference -->

**Baseline:** `pret/pokered` commit `405b6246372d7e5a2cb029cbb65219b13286b8c9`.

This page defines what “end-to-end” means for the battle project and lists every layer that must close before a 1:1/formally verified claim is made. A standalone processor package now exists under `packages/sm83-lean`, but there is still no built canonical ROM, symbol map, Game Boy adapter, Pokémon machine runner, battle refinement theorem, or benchmark. The processor artifact does not close any battle-level claim by itself.

## Three claim boundaries

Do not collapse these into one claim.

| Claim | Entry | Exit | Required behavior |
|---|---|---|---|
| Battle kernel | Initialized state immediately before `StartBattle` | Witnessed terminal edge returning from `StartBattle` | Menus/actions, turns, RNG, moves, items, AI, capture, faint/replacement, terminal provenance |
| Battle driver | Explicit pending battle at `InitOpponent`/the supplied-opponent branch of `InitBattle` | Return from `_InitBattleCommon` after `EndOfBattle`, restored caller fields, carry set | Mode setup, trainer/wild load, transition side effects, kernel, payout/evolution, cleanup, outer return |
| Gameplay caller integration | `NewBattle`, cable-club setup, or map script state | Caller-specific map/cable/blackout continuation | Encounter triggering, trainer flags/objects, post-link HealParty, blackout money/heal/warp, map scripts |

The verified simulator's primary theorem is the **battle driver** theorem. Kernel proofs are intermediate. Caller integration is a family of separate composition theorems and is not silently included in the battle result.

## Concrete driver timeline

For an explicit pending opponent, the source path is:

```text
caller / Bankswitch / Predef
  → InitBattle or InitOpponent
  → InitBattleCommon
      save wMapPalOffset and wLetterPrintingDelayFlags on stack
      InitBattleVariables
      PlayBattleMusic
      classify trainer versus wild
      trainer: GetTrainerInformation → ReadTrainer → trainer picture
      wild: LoadEnemyMonData → ghost/sprite handling
      DoBattleTransitionAndInitBattleVariables
  → _InitBattleCommon
      transition/HUD/sprite setup
      StartBattle
          initial scans/send-out
          MainInBattleLoop*
          witnessed terminal edge
      EndOfBattle
          link result or non-link Pay Day guard
          EvolutionAfterBattle and nested decisions where selected
          cleanup and handoff writes
      restore letter delay, map palette, tile animation
      set carry and return through bank/predef wrapper
```

A theorem that stops after the final turn is not an episode theorem. A theorem that starts after setup is not a driver theorem.

## Entry-point decision

`InitBattle` is also an encounter detector. When `wCurOpponent == 0`, it can return without a battle because of debug input, encounter cooldown, or `TryDoWildEncounter` failure. Map encounter selection is outside the supplied-battle reset API.

The standalone low-level battle harness therefore uses one of these equivalent explicit-battle entries:

1. enter `InitOpponent` with nonzero `wCurOpponent` and a valid bank/stack return frame; or
2. enter `InitBattle` with a precondition that takes its immediate nonzero-opponent branch and compose the short prefix to `InitOpponent`.

The second form best matches `NewBattle`; the first matches the link cable's `predef InitOpponent` call and is the common proof cut point. A separate theorem is required before claiming random overworld encounter triggering.

## Mode-specific entry predicates

Every reset constructor produces bytes plus a proof of one named predicate. A machine entry also supplies a fetched-pipeline witness: either execute the caller's transfer into `InitOpponent`, or prove IR contains the symbol's first byte with matching IR address, next PC, prefix state, and hidden-latch well-formedness. `PC = InitOpponent` alone is not a physical checkpoint.

| Mode | Required caller-established state |
|---|---|
| Supplied wild | Nonzero internal species in `wCurOpponent`, level, valid player party, canonical prior-cleanup bytes, wild enemy-scan scratch witness, mode/map/ghost fields |
| Trainer | Valid opponent class and 1-based trainer number, trainer metadata/end-text pointers and bank, player party, badges/options/inventory, map/script fields used by trainer text |
| Safari | Supplied wild state plus Safari map range or an explicitly proved equivalent caller state, Safari Ball count/factors |
| Old Man | `BATTLE_TYPE_OLD_MAN`, Weedle/level/script inputs, player name and aliased `wGrassRate`/link-name buffer state, tutorial controller path |
| Link | Two cartridge states after cable setup: exchanged parties/names, clock roles, valid receive protocol, `LINK_STATE_BATTLING`, separate post-processed ten-byte random blocks, bank/stack/hardware state |
| Raw/glitch | Explicit byte predicate and partial-machine theorem; no legal-party or termination assumption is smuggled in |

`InitBattleVariables` is not the reset predicate. It leaves normal/Old Man mode and battle-status dependencies to caller/prior cleanup and performs only selected clears.

## Initial low/high relation

The first semantic checkpoint after driver setup relates:

- ordered player/enemy party bytes and active indexes;
- active structures, unmodified stats, stage blocks, status/counters, loaded records, and scratch aliases;
- trainer AI count/layer state and participation bytes;
- ordered bag, money, Pokédex, box, evolution flags, options/badges, names, and mode fields;
- ordinary hardware state/coupling and both link perspectives where applicable;
- pending controller/serial/random responses;
- bank, stack, fetched IR/pipeline latches, interrupt phase, typed clock domains, LCD, DMA/OAM-corruption, audio, and presentation state needed to continue decoded execution.

A high-level `BattleState` is not related directly to arbitrary WRAM. The relation is phase-indexed and mode-indexed.

## Terminal witness is not episode completion

A recognized `StartBattle` edge produces a `BattleTerminal` witness. It does **not** set RL `done` yet.

After the witness, the driver can still:

- show link result state;
- add Pay Day money;
- enter `EvolutionAfterBattle`;
- request evolution cancellation;
- enter move learning from evolution;
- mutate species, stats, types, nickname, Pokédex, moves, and PP;
- clear battle state and write cooldown/destination handoff bytes;
- restore caller fields and return through banked wrappers.

The high-level phase model therefore needs at least:

```text
battling
ending(terminalWitness)   -- StartBattle returned; epilogue still runs
returned(episodeResult)   -- payout/evolution/cleanup/outer return complete
```

Simultaneous active faint is an event/control-flow ordering fact, not necessarily a terminal cause: reserves can keep the battle running. Store optional detected-first metadata on the eventual terminal witness instead of representing every simultaneous faint as terminal.

## Driver outputs

The post-return projection includes every mechanics or caller-visible mutation made inside the driver:

- final party/active-derived persistent HP, status, PP, moves, levels, EXP/stat EXP, evolution changes;
- ordered inventory and quantities;
- current-box capture insertion, OT names, nicknames, records;
- Pokédex seen/owned;
- trainer prize and Pay Day money;
- raw battle result plus retained terminal witness;
- encounter cooldown and destination warp ID;
- loss-path always-on-bike clear where performed in the battle flow;
- restored `wLetterPrintingDelayFlags`, `wMapPalOffset`, and `hTileAnimations`;
- trainer end-text flag/name/sprite movement writes reached by `PrintEndBattleText`;
- Old Man player-name restoration and aliased `wGrassRate`/wild-buffer mutation;
- carry and bank/stack return facts.

Pixel/tile/audio equivalence is excluded, but presentation code's writes outside excluded buffers, controller consumption, timing, interrupts, bank restoration, and divergence are not excluded.

## Caller integration after driver return

| Caller | Behavior after battle-driver return | Primary theorem disposition |
|---|---|---|
| Overworld `NewBattle` | Uses carry, clears battle-engagement flags, marks map reload, checks party, enters map | Separate integration theorem |
| Ordinary loss | Overworld later writes `wIsInBattle := $FF`, runs map script, halves money, heals party, and prepares blackout warp | Explicitly outside primary battle result |
| Trainer map script | Later flags trainer fought and may hide the map object | Outside driver; compose per map-script family if claimed |
| Link cable club | Calls `HealParty` immediately after `predef InitOpponent` returns, restoring party HP/PP/status before room return | Outside primary driver result; mandatory for a full cable-session theorem |
| Old Man script | Restores sprite/script/UI state after tutorial | Outside driver; name/wild-buffer mutation performed during battle remains driver output |
| Random wild encounter | `NewBattle`/`TryDoWildEncounter` chooses whether/species/level before explicit battle setup | Separate encounter theorem |

This boundary explains why “final cartridge party after a link session” differs from “party at battle-driver return.”

## Trainer end-text closure

Trainer victory calls `PrintEndBattleText` before payout and before `StartBattle` returns. Depending on caller flags it can:

- clear `BIT_PRINT_END_BATTLE_TEXT`;
- bank to caller-provided win/lose text;
- save the trainer name;
- run the text command processor;
- mutate trainer sprite movement state unless the map/rival exceptions apply;
- wait for sound.

The chosen text pointer tests raw `wBattleResult`. A simultaneous-faint path can enter trainer victory, print the **loss** text because raw result is 1, then still award prize money. Text is presentation, but branch timing and state writes are part of low-level closure.

A complete manifest must follow reachable `text_asm` callbacks and dynamic text pointers; direct call scanning is insufficient.

## Old Man closure

The tutorial menu copies the player's name into `wLinkEnemyTrainerName`, which aliases `wGrassRate` and the wild-mon buffer, then writes `OLD MAN` into `wPlayerName`. The Old Man ball path copies the aliased buffer back to `wPlayerName` before its forced capture. The player name is restored, while the wild-encounter buffer remains overwritten—the source of the Cinnabar/Route 21 MissingNo. setup.

These are persistent driver mutations. A tutorial theorem that models only the synthetic Poké Ball action is incomplete.

## Transitive code closure

M0 generates a symbol/range graph from the ROM and source metadata. Roots include:

- `InitBattle`, `InitOpponent`, `InitBattleCommon`, `_InitBattleCommon`;
- `StartBattle`, `MainInBattleLoop`, every terminal edge;
- `EndOfBattle` and return wrappers;
- paired link setup cut points where the link theorem begins.

Edges include:

- direct `call`/`jp`/`jr` and return continuations;
- `farcall`, `callfar`, `farjp`, `jpfar`, `Bankswitch`, and `BankswitchHome`;
- predef IDs through `PredefPointers`;
- move-effect, item, trainer-AI, trainer-party, animation, audio, and other pointer tables;
- text commands, `text_asm`, map trainer end-text pointers, and naming/menu callbacks;
- interrupt vectors and VBlank/serial/timer handlers reachable while the driver runs;
- indirect `jp hl`/stack continuations;
- ROM data ranges read by decoded execution.

A source-level grep is only a discovery aid. The final graph is address-based against the canonical `.sym`, `.map`, and ROM bytes.

## Coverage-manifest schema

Each reachable range records at least:

```text
bank, start, end, symbol/source, kind(code|data), modes,
predecessor edge, disposition, Lean theorem/summary, artifact hash
```

Allowed dispositions:

1. executed by proved machine semantics;
2. replaced by a proved functional/routine summary;
3. presentation summary with memory frame, controller/timing/interrupt coupling, bank/stack restoration, and divergence conditions;
4. caller integration outside the primary theorem, with an explicit boundary theorem or non-claim.

CI fails on an uncovered reachable range, unresolved indirect edge, overlapping incompatible disposition, changed ROM bytes, or missing proof identifier.

## ROM data closure

Typed decoders are required for mechanics-selected data:

- moves/effects and six phase tables;
- species/base stats, internal-to-Pokédex map, names, cries, learnsets/growth;
- type matchups;
- trainer parties, special moves, AI layer/action tables, base money, names, picture pointers;
- item dispatch/data, inventory, capture constants;
- predef pointer table and relevant text/pointer tables;
- party/box/battle codecs and WRAM/HRAM symbols.

Presentation assets (pictures, tile graphics, animation scripts, music, text bytes) may remain raw ROM ranges when executed by the machine, but they still need range coverage and bounds/frame proofs for any summary.

Every decoder theorem proves original-byte equality against the embedded canonical ROM, not only agreement with source constants.

## Machine/hardware closure

The low runner composes the pinned standalone processor package with a Game Boy adapter and must support all behavior reached before return:

- complete encoding-derived x/y/z classification/semantics for all 256 base slots and 256 CB slots, not merely the currently reachable subset;
- typed flags, exact PC/SP/IR and ordered stack/data/IDU cycles, DAA/signed-SP rules, staged EI/DI/RETI, prefetch-aware interrupt entry with mid-dispatch IE-write cancellation/retargeting, HALT wake/bug/following-byte behavior, seven STOP outcomes, and invalid no-fetch lockup;
- proved declarative/de-overlapped and physical fetched-pipeline/de-overlapped sequence relations;
- fixed/switchable ROM banking and external SRAM enable/bank behavior;
- WRAM, HRAM, VRAM, OAM, echo/unusable regions as reached;
- joypad register and controller schedule;
- serial registers/interrupts and paired cable scheduling;
- `DIV`/timer behavior;
- LCDC/STAT/LY/LYC, VBlank, VRAM/OAM access timing, palettes, scrolling/window registers;
- OAM DMA, fixture/family-qualified monochrome OAM corruption from active access plus IDU address drive, and HALT/DMA clock gating;
- audio registers/channel state sufficient for sound waits and interrupts/timing;
- SGB/palette command paths or proved summaries;
- deterministic stop conditions at semantic checkpoints, divergence, and the outer return sentinel.

Battle transition code uses VRAM/OAM and also enables/banks external SRAM as sprite scratch. A WRAM-only machine cannot execute the driver end-to-end. The first system theorem names `DmgCpuBCommonBoot` and proves that its T1F–T4R bus/read-fold plus `IE`/`IF` adapter satisfies the processor package contract; flat-memory opcode conformance alone is insufficient.

The package split is in [Standalone SM83 semantics package](sm83-semantics-package.md); decoder/equation/logical schedule gates are in [SM83 implementation specification](sm83-implementation-spec.md), physical pipeline/IDU/clock obligations are in [SM83 microarchitecture and system-boundary contract](sm83-microarchitecture-contract.md), and the selected profile/evidence boundary is in [DMG-CPU B console profile](dmg-cpu-b-profile.md).

## Presentation-summary contract

A summary for text, animation, HUD, sprite, palette, or audio code is admissible only if it proves:

- exact projected-memory frame and all non-frame writes;
- controller bytes/acknowledgements consumed;
- bank, stack, registers, and flags required by the caller;
- elapsed-cycle/interrupt/VBlank relation sufficient to preserve later ordinary RNG observations;
- MMIO/VRAM/OAM/SRAM effects required by subsequent code;
- termination/divergence preconditions;
- equivalence for every mode/call site using the summary.

Until such a theorem exists, the low machine executes the decoded routine.

## High-level semantic closure

The independent high-level model needs modules for:

- mode-specific initialization and trainer/wild/link data load;
- action/selection request protocol and exact automatic transitions;
- damage/status/effects/PP/switch/faint/participation;
- items/capture/naming/box mutation;
- trainer AI and enemy selection;
- experience/level/move learning/evolution;
- terminal provenance and epilogue;
- cleanup/driver-return projection;
- paired link perspectives and serial choice exchange.

Low-level presentation acknowledgements remain in the hardware/controller environment. Mechanics decisions remain typed high-level requests. Canonical adapters map typed responses to concrete controller traces and require their own refinement theorems.

## Theorem stack

End-to-end closure requires all of these compositions:

1. artifact/hash and ROM-range identity;
2. pinned standalone processor proofs plus proved Game Boy bus/clock/interrupt composition for the named hardware profile;
3. mode-specific reset relation;
4. ROM data decoder equality;
5. leaf arithmetic/RNG/codecs;
6. move/effect/item/AI routine summaries;
7. action-selection and one-turn refinement;
8. switch/faint/participation refinement;
9. `StartBattle` finite-trace refinement to a non-forgeable terminal witness;
10. `EndOfBattle` Pay Day/evolution/cleanup refinement;
11. outer restore/carry/bank/stack return refinement;
12. paired link theorem with conditional synchronization/divergence;
13. optional caller-integration theorem for overworld, cable auto-heal, tutorial, or encounter triggering;
14. RL adapter serialization/action-mask/snapshot/batch correctness.

No test, differential trace, or source audit substitutes for a missing theorem in this stack.

## Required end-to-end fixture matrix

At minimum, CI needs bounded low/high traces for:

- supplied wild: victory, loss, Run success/failure, Poke Doll, move escape, capture to party, capture to box;
- trainer: victory/payout/end text, loss, multiple enemy replacements, Shift/Set, AI item, AI switch;
- terminal edge orders: recoil/simultaneous faint with and without reserves;
- progression: participant EXP, Revive eligibility, EXP All, level-up/move learning, evolution allow/cancel, Pay Day;
- Safari: capture, enemy escape, Balls exhausted, bait/rock duration paths;
- Old Man: forced capture, name restoration, wild-buffer overwrite;
- link pair: ordinary win/loss, both/local run, switch, status exit sync, RNG cursor desynchronization, leading-zero setup variant where separately proved;
- raw/divergent: zero divisors, malformed counts/lists, unbounded scans, adversarial rejection streams.

Each fixture asserts terminal provenance, projected random call-site sequence, final driver state, consumed semantic/controller responses, and return-frame facts.

## Delivery order that exposes integration risk early

1. Hermetic RGBDS/Lean toolchain; canonical ROM, symbols, maps, hashes.
2. Generated range/call/predef/text-pointer closure manifest.
3. Release and immutably pin the local `sm83-lean` candidate, then build the Game Boy memory/banking/device adapter and its processor-composition proof.
4. Execute one supplied one-member wild fixture from `InitOpponent` to outer return, initially with instrumented presentation cut points.
5. Independently define the minimal high-level model for that fixture and prove its complete episode, not only one turn.
6. Replace every instrumentation assumption with machine execution or a proved summary.
7. Expand mechanics and modes while CI keeps the first episode theorem green.
8. Add paired link and optional caller-integration theorems.
9. Optimize only the proved high-level model for RL and batching.

## Remaining gaps

- Canonical Red now rebuilds under the pinned RGBDS derivation; deterministic `.sym`/`.map` files and exact ROM hashes are retained. The ROM itself is not checked in.
- A conservative whole-machine range manifest covers every CPU address, ROM bank, and external RAM bank. A narrowed transitive call/predef/text/data graph for the first episode is still absent.
- `packages/battle-lean` now supplies the WRAM contract, active-mon codec, differential comparator, ROM closure, and initial DMG-CPU B adapter. No complete battle transition or episode refinement theorem exists.
- `packages/sm83-lean` provides the standalone processor candidate, independent architectural dispatch, executable architectural/physical layers, retirement monitor, simulation framework, profile relations, and conformance gates. It is not yet a separately released immutable dependency; universal physical refinement currently has only the first NOP base case.
- The Pokémon adapter proves eight-edge processor composition and models MBC3, mapped memory, divider/timer, basic PPU/VBlank, joypad, serial, and DMA. Detailed OAM, presentation, audio, and full device-timing refinements remain.
- No low/high trace runner or SameBoy/`gb-research` trace adapter exists; the oracle revisions and distrust boundary are selected.
- No presentation summary has a frame/timing theorem.
- No mode-specific reset predicate has been encoded.
- No end-to-end fixture executes.
- Nix, Lean 4.30.0, and the source-hashed RGBDS `v1.0.2+hotfix` derivation are now locked and checked in CI.
- The processor package is Apache-2.0 clean-room code. License status for reusing `gameboy-pokered-verify` remains unresolved.

Fixture-qualified DMG-B locked-pin and advanced OAM captures also remain absent; their behavior stays relational and must be proved unreachable or projection-irrelevant. These are implementation/evidence blockers, not silent profile defaults.
