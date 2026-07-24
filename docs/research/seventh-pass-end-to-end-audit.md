# Seventh-pass end-to-end audit

<!-- research record; completed against the pinned source commit -->

**Baseline:** `pret/pokered` commit `405b6246372d7e5a2cb029cbb65219b13286b8c9`.

This pass stopped looking for one more isolated mechanic and audited what must exist for a real `InitOpponent`-to-return theorem and usable RL episode. The processor layer beneath that closure is audited separately in the [eighth pass](eighth-pass-sm83-semantics-audit.md). It reread driver entry/exit, encounter/caller wrappers, trainer end text, Old Man scripts, cable post-return behavior, predef/bankswitch dispatch, transition hardware, and milestone/CI closure.

## High-impact corrections

| Finding | ASM evidence | Architecture consequence |
|---|---|---|
| Previous reset language mixed semantic and machine entry | `InitBattle` can perform encounter detection/no-battle return; `InitOpponent` is the common explicit-opponent label and a predef target | Primary driver theorem now enters `InitOpponent` (or composes `InitBattle`'s nonzero prefix); mode loading remains in theorem. |
| Terminal witness was too close to API completion | `_InitBattleCommon` calls `StartBattle`, then `EndOfBattle`, then restores three caller fields and sets carry | Added `battling → ending(witness) → returned(result)`; RL `done` occurs only after payout/evolution/cleanup/outer return. |
| Simultaneous faint was incorrectly shaped as always terminal | Faint handlers can choose reserves and continue after both active HP values reach zero | Removed it as a standalone terminal cause; retain event/detected-first provenance on a later terminal witness. |
| Battle-driver and caller outputs differ | Overworld later blackouts/heals/halves money; cable club immediately calls `HealParty`; trainer/Old Man map scripts continue after return | Split kernel, driver, and caller-integration theorem claims. |
| Trainer victory reaches dynamic caller text/state | `PrintEndBattleText` uses caller bank/pointers, clears a flag, saves trainer name, runs text commands, mutates sprite movement | Added text/predef/map callback closure and projected handoff writes. Raw result 1 can select lose text before victory payout. |
| Old Man has persistent alias output | Menu stores player name in `wLinkEnemyTrainerName == wGrassRate`, overwrites `wPlayerName`, ball path restores name only | Added exact player-name restoration and persistent wild-buffer overwrite to driver output. |
| Driver setup is not WRAM-only | Battle transition/HUD/sprite code uses VRAM/OAM/MMIO/audio; `LoadPlayerBackPic` enables and banks external SRAM as sprite scratch | Expanded machine boundary to external SRAM, LCD, OAM DMA, audio, interrupts, and presentation timing. |
| Direct-call inventory cannot establish coverage | Battle execution dispatches via bankswitch helpers, predefs, move/item/AI tables, text commands, dynamic pointers, and interrupts | Defined an address-based code/data/interrupt/asset range manifest with predecessor edges and proof dispositions. |
| Existing milestone order delayed integration proof | M3 ended at one turn | M3 now requires a minimal supplied one-member wild episode from `InitOpponent` through outer return. |
| Toolchain blocker is more specific than “not on PATH” | Nix exists; nixpkgs reports RGBDS 1.0.1, source requires 1.0.2; related Lean project pins 4.28 while nixpkgs reports 4.30 | M0 needs a custom pinned `v1.0.2+hotfix` derivation and an explicit Lean lock. |

## Exact battle-driver boundary

### Entry

`NewBattle` performs overworld eligibility checks, then tail-calls `InitBattle`. `InitBattle` has two qualitatively different paths:

- nonzero `wCurOpponent`: copy the explicit opponent and enter `InitBattleCommon`;
- zero `wCurOpponent`: debug/cooldown/`TryDoWildEncounter` logic can return without a battle or select one.

The supplied-battle API should not formalize map encounter triggering accidentally. Its common machine cut point is `InitOpponent`, which is also the cable club's predef target. The theorem requires a valid current bank, stack return frame, interrupts/hardware state, and mode-specific caller bytes. A short wrapper theorem connects explicit-opponent `InitBattle` to this cut point.

### Setup included in theorem

From `InitOpponent`, the driver:

- pushes map palette and letter delay state;
- executes partial `InitBattleVariables` and battle music;
- classifies trainer/wild;
- obtains trainer name/picture/base money and constructs trainer party, or loads wild active data/DVs/moves;
- performs ghost handling;
- executes battle transition, HUD, sprite, palette, and tile setup;
- enters `StartBattle`.

A semantic reset may expose a state after those operations, but the low driver theorem cannot pretend they happened outside the ROM.

### Exit

After a recognized `StartBattle` terminal edge:

1. `EndOfBattle` handles link result or the non-link raw-result guard;
2. Pay Day may be added;
3. `EvolutionAfterBattle` can request cancellation and move learning;
4. cleanup clears battle/mode/escape/status fields and writes cooldown/destination;
5. sound/palette completion runs;
6. `_InitBattleCommon` restores `wLetterPrintingDelayFlags`, `wMapPalOffset`, and `hTileAnimations`;
7. carry is set and execution returns through the predef/bankswitch frame.

That final return, not the terminal edge, creates the RL episode result.

## Terminal versus ending

The old `running | terminal` sketch was insufficient for end-to-end operation. Capture naming happens before its terminal edge, but evolution/move-learning can happen after another terminal edge. A runner that sets `done` immediately would either skip cartridge mutations or request decisions after advertising completion.

The corrected phase shape is:

```text
battling
ending(TerminalWitness)
returned(EpisodeResult)
```

The witness retains raw result, pre-cleanup escape byte, mode/perspective, recognized edge, verdict, and optional simultaneous-detected-first metadata. Cleanup may erase source fields, but the runner retains the witness through return.

Simultaneous active faint is emitted as a semantic event. If reserves remain, replacement continues. If it contributes to eventual terminal order, the terminal witness carries the metadata.

## Caller-integration audit

### Overworld

After carry returns from `NewBattle`, overworld code clears engagement flags, marks map reload state, checks party, and enters the map. On party exhaustion it later writes `wIsInBattle := $FF`, runs map script, calls blackout processing, halves money, heals party, and prepares warp state. These transitions remain outside the primary driver result.

### Trainer scripts

The battle driver itself can execute `PrintEndBattleText`. Later map script code marks the trainer fought and may hide the object. The former is inside; the latter is caller integration.

`PrintEndBattleText` selects the caller's win/lose pointer from raw `wBattleResult`. A simultaneous-faint path can reach trainer victory with result 1, print lose text, then award prize money. The text branch is presentation but affects timing and can run dynamic text commands; flag/name/sprite writes are caller-visible.

### Link cable

After party/random setup, cable code sets `LINK_STATE_BATTLING`, sets `OPP_RIVAL1`, calls `predef InitOpponent`, then unconditionally calls `predef HealParty`. The authoritative party at driver return is therefore not the final party returned to the cable room: the wrapper restores HP/PP/status afterward.

The primary paired battle theorem begins after setup and ends before HealParty. A full cable-session claim needs setup and post-heal composition theorems.

### Old Man

Viridian script sets Old Man mode, Weedle, and level before the battle. Inside the battle menu:

1. player name is copied to `wLinkEnemyTrainerName`, aliased to `wGrassRate`/wild data;
2. `wPlayerName` becomes `OLD MAN`;
3. the forced Poké Ball path copies the aliased bytes back to `wPlayerName`;
4. no party/box capture or bag removal occurs.

The later map script restores sprite/script state. The battle driver has already restored the player name but intentionally leaves wild bytes overwritten.

## Transitive closure audit

An end-to-end graph starts from driver roots and must traverse:

- direct branches/calls;
- all far-call/jump macro expansions and `Bankswitch` continuations;
- predef ID lookup through ROM bank/address triples;
- effect/item/trainer-AI pointer tables;
- trainer party/special move/base money/name/picture pointers;
- text processors, `text_asm`, map end-text pointers, naming and menu callbacks;
- move animation and audio dispatch;
- interrupt vectors and VBlank/serial/timer edges;
- every raw ROM data/asset range read along those paths.

The manifest records bank/start/end, code/data kind, source symbol, mode, predecessor edge, disposition, theorem name, and hashes. “Presentation” is not a gap-closing label without a frame/timing/controller/bank/divergence theorem.

## Machine closure audit

The driver needs more than the related project's isolated SM83 helpers:

- instruction fetch/decode/execute and exact flags/cycles;
- ROM banking and bank-preserving wrappers;
- external SRAM enable/bank semantics;
- WRAM/HRAM, VRAM, OAM, echo/unusable behavior where reached;
- stack and return-sentinel control;
- IME, HALT, interrupt vectors/entry/return;
- divider/timer;
- joypad and controller schedule;
- serial and paired cable scheduling;
- LCD mode/LY/VBlank, palettes/window/scroll, VRAM/OAM restrictions;
- OAM DMA;
- audio channel/register state sufficient for sound waits;
- SGB/palette commands or proved summaries.

`LoadPlayerBackPic` explicitly writes `rRAMG`/`rRAMB` and uses SRAM sprite storage. This closes a previously omitted memory-system requirement.

## Presentation closure audit

Text, animations, sprites, HUD, palettes, and audio can be omitted from the fast high-level model. For the ROM theorem each call is either executed or summarized with proof of:

- all projected and caller-visible writes;
- memory frame outside declared graphics/audio scratch;
- controller acknowledgements consumed;
- exact bank/stack/register/flag return contract;
- cycles/interrupt/VBlank relation preserving later hardware-derived RNG;
- MMIO/VRAM/OAM/SRAM state needed by later code;
- termination and divergence preconditions.

Trainer end text and Old Man naming demonstrate why a blanket “text is presentation” stub is unsound.

## High-level completion audit

The independent Lean model needs complete paths for:

1. mode setup and party/active derivation;
2. first send-out;
3. every request/automatic transition;
4. terminal edge provenance;
5. ending-phase payout/evolution/move-learning;
6. cleanup and return projection;
7. paired link state;
8. exact snapshots/replay through `ending`;
9. returned outcome only after epilogue.

Presentation acknowledgements stay in the low controller environment. Mechanics decisions remain typed requests with canonical controller-trace refinement adapters.

## First vertical episode

The previous plan could have produced many correct leaf/turn theorems without proving integration. M3 now requires:

- explicit supplied-wild `InitOpponent` entry;
- one player and one enemy;
- an ordinary damaging move that faints the enemy in one action;
- exact random call-site projection;
- terminal witness;
- no Pay Day/evolution eligibility;
- `EndOfBattle` cleanup;
- restored fields, bank/stack, carry, and returned result.

Temporary instrumentation may accelerate bring-up, but no unproved presentation or hardware stub may remain in the final theorem dependency graph.

## End-to-end CI matrix

The required fixture families now include:

- wild victory/loss/run/capture/move escape/Poke Doll;
- trainer payout/end text/loss/replacement/Shift/AI item/AI switch;
- simultaneous faint with and without reserves;
- Revive/EXP All/level-up/move-learning/evolution/Pay Day;
- Safari capture/run/exhaustion/factors;
- Old Man name and wild-buffer result;
- paired link win/loss/run/switch/status/RNG divergence;
- raw malformed/divergent loops and zero divisors.

Each trace checks entry predicate, semantic/controller response consumption, RNG sites, terminal provenance, ending decisions, final driver state, and return-frame facts.

## Toolchain and artifact status

Observed locally:

- `make`, RGBDS tools, `lean`, and `lake` are absent from `PATH`;
- Nix and nix-shell are installed;
- `nixpkgs#rgbds.version` reports `1.0.1`;
- pokered requires `1.0.2`;
- upstream exposes tag `v1.0.2+hotfix` at `3b1606c63c1671fd6675747507fe95d7f72da2d9`;
- `nixpkgs#lean4.version` reports `4.30.0`;
- the related proof project pins Lean `4.28.0`;
- no `.gb`, `.sym`, or `.map` exists in the worktree.

M0 must select/pin source hashes, create the derivation, build, and verify the canonical SHA before any address-level conclusion.

## Architectural decisions changed by this pass

1. Primary claim is battle-driver refinement, with kernel and caller integration named separately.
2. Explicit common entry is `InitOpponent`; random encounter triggering is a separate theorem.
3. Terminal is an `ending` phase, not `done`.
4. Simultaneous faint is event/provenance, not inherently terminal.
5. Driver output includes trainer end-text/sprite and Old Man alias writes.
6. Link auto-heal and blackout processing are post-return caller transitions.
7. Coverage is address-based code/data/interrupt/asset closure, not source-file or direct-call coverage.
8. External SRAM and full presentation/hardware return contracts are required.
9. M3 proves one complete minimal episode before broad mechanics expansion.

## Validation performed

Source/document checks cover:

- all local Markdown links and table shapes;
- all recorded source SHA-256 values, including caller/predef/cable/audio/script files added this pass;
- source patterns for explicit driver/outer return, post-link HealParty, Old Man name alias/restore, trainer dynamic end text, and external SRAM use;
- canonical cardinalities, probability/move-accuracy tables, stat ratios, trainer/item/effect dispatch, and effect phase arrays;
- whitespace via `git diff --check`.

These remain source-level consistency checks. The core blockers are now concrete: no pinned toolchain derivation, ROM/symbol artifacts, address closure, Lean machine/high model, or theorem.

## Next implementation actions

1. Add a Nix flake/lock with custom RGBDS `v1.0.2+hotfix` and chosen Lean toolchain.
2. Build Red, verify SHA-1/SHA-256, and retain normalized `.sym`/`.map` hashes.
3. Generate the address-based root/edge/range manifest, including predefs/text/interrupts/assets.
4. Encode mode-specific `InitOpponent` reset predicates and the outer return sentinel.
5. Depend on the complete standalone SM83 package, then implement/prove banking, external SRAM, interrupts/IF-IE adapter, divider, and minimal LCD/joypad/audio/serial system skeleton.
6. Execute the one-member supplied-wild driver fixture to return and compare against an independent emulator.
7. Define the independent high-level `battling/ending/returned` model and prove the first complete episode.
8. Expand mechanics/modes while preventing any uncovered range or unproved summary from entering the theorem graph.
9. Resolve licensing before reusing upstream Lean definitions.
