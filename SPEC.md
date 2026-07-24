# Formally Verified Pokémon Red Battle Simulator — Specification

- **Status:** Draft plan; no implementation or equivalence proof exists yet
- **Target source:** `pret/pokered` commit `405b6246372d7e5a2cb029cbb65219b13286b8c9`
- **Initial cartridge:** Pokémon Red (UE), SHA-1 `ea9bcae617fdf159b045185467ae58b2e4a48b9a`
- **Assembler version pinned by upstream:** RGBDS `1.0.2`

## 1. Objective

Build an executable Pokémon Red battle simulator in Lean 4 and prove that its battle-relevant behavior refines the machine-code behavior of the assembled Pokémon Red ROM.

The deliverable has two roles:

1. **Reference implementation:** preserve the cartridge's actual Generation I behavior, including integer widths, truncation, asymmetric player/enemy paths, RNG consumption, and known glitches.
2. **RL environment:** expose a fast, deterministic-when-given-a-random-transcript interface for generating legal teams, enumerating legal actions, stepping battles, snapshotting state, and running batches.

The proof target is the implementation, not an idealized rulebook. A cartridge bug is part of the specification unless a separate, explicitly named “fixed mechanics” ruleset is added later.

## 2. Meaning of “1:1”

“1:1” does **not** mean that handwritten Lean code looks similar to the assembly. It means there is a machine-checked refinement theorem connecting two independently defined semantics:

- **Low-level semantics:** decoded SM83 machine code from the pinned ROM. A separately verified and commit-pinned `sm83-lean` dependency supplies processor decode/clock semantics; this project supplies the Game Boy bus/devices, cartridge mapping, stack-visible memory, and modeled hardware inputs.
- **High-level semantics:** the executable Lean battle state machine used by clients and RL agents. Ordinary modes use one perspective; the full link model retains a pair of cartridge perspectives because their duplicated states and RNG cursors can desynchronize.

Let:

- `M` be a low-level machine state at a recognized battle checkpoint;
- `decodeBattle M = some S` project machine memory into high-level state `S`;
- `L` be a low-level environment trace containing divider, interrupt, serial, joypad, LCD, and presentation acknowledgements;
- `H` be a high-level response trace containing committed choices and mechanics-visible random results;
- `CoupledInputs M L S H` state that `H` is the semantic projection induced by executing `M` with `L`;
- both runners return an explicit checkpoint, request, witnessed terminal, divergence, or fuel-exhaustion outcome; a low-level terminal carries the recognized control-flow edge because final WRAM alone does not encode every cause.

The low- and high-level traces do **not** have the same alphabet. One high-level ordinary-random response corresponds to the value returned at a named gameplay `Random`/`BattleRandom` call, while the low-level execution may consume many `rDIV` reads in intervening VBlanks. The theorem compares projected semantic requests and a coupling relation on the remaining traces, not raw suffix equality.

A schematic normal-transition obligation is:

```lean
theorem battle_step_refines
    (hRom : ROM.sha1 = canonicalRedSha1)
    (hCheckpoint : AtBattleCheckpoint M)
    (hReachable : BattleReachable M)
    (hDecode : decodeBattle M = some S)
    (hCoupled : CoupledInputs M lowEnv S highEnv) :
    match runToCheckpoint ROM M lowEnv, Battle.resume S highEnv with
    | .checkpoint M' lowEnv' lowObs,
      .checkpoint S' highEnv' highObs =>
        decodeBattle M' = some S' ∧
        projectObservations lowObs = highObs ∧
        projectedSemanticRequests lowEnv lowEnv' =
          consumedResponses highEnv highEnv' ∧
        CoupledRemaining M' lowEnv' S' highEnv'
    | .diverged lowReason, .diverged highReason =>
        ProjectsDivergence lowReason highReason
    | _, _ => False
```

The actual Lean statement may split normal and divergent cases, but it must retain this information. This schematic statement is one-perspective; the link theorem quantifies over paired low/high perspective states and their serial exchange relation. The final episode theorem lifts transition refinement over finite terminating traces and separately preserves modeled cartridge divergence. Fuel exhaustion is an analysis result, never a cartridge result.

### 2.1 Observed behavior

The equivalence relation includes:

- active and party Pokémon battle data;
- HP, status, stats, stat stages, types, moves, PP, DVs, and relevant experience data;
- volatile statuses and counters;
- chosen actions and action legality;
- exact turn ordering;
- exact random-byte consumption at battle-relevant call sites;
- damage, side effects, switching, fainting, capture, experience, post-battle evolution, and witnessed terminal outcome;
- inventory order/quantities, move order, captured party/box records and nickname bytes, Pokédex seen/owned flags, trainer prize money, Pay Day money, trainer end-text flag/sprite handoff, Old Man name/wild-buffer alias writes, and other battle-exit writes caused inside the driver;
- mechanics-visible selection side effects, including stale selected-move writes that can alter Quick Attack/Counter order and Counter inputs, plus non-turn-consuming move/bag reordering;
- semantic events such as move use, miss, status application, faint, switch, capture, evolution, and battle end.

It excludes pixel, tile, palette, animation-frame, audio-waveform, and text-layout equivalence. Presentation routines may only be abstracted after their frame conditions on projected battle state are proved. Their effect on timing and therefore `rDIV`/RNG remains explicit through the external hardware trace.

### 2.2 RNG claim

For ordinary battles, the cartridge's `Random_` reads the hardware divider register and is also called once per VBlank. Consequently, a battle outcome is not a pure function of a small software seed. The low-level theorem is parameterized by a hardware trace. A trace-coupling theorem projects the values returned by mechanics-visible random calls into the byte responses consumed by the high-level model and proves equality of the semantic call-site trace.

A separate RL RNG provider may produce those high-level bytes from a reproducible seed. That gives reproducible, game-rule-correct stochastic battles, but it is not claimed to reproduce the physical console's timing distribution. Each link cartridge uses its own nine-value sequence and update rule after setup. The two sequences are normally equal and remain equal while draw histories agree, but asymmetric mechanics can desynchronize their cursors, and cable setup's leading-zero scan can even produce unequal post-setup lists. The verified link state therefore retains both cartridge perspectives; reset supplies each side's post-processed ten-byte memory block.

See [RNG and time](docs/explanation/rng-and-time.md).

## 3. Scope

### 3.1 In scope

The final verified model covers all battle modes and battle-relevant mutations reached by the pinned ROM. Overworld handoff bytes written inside the battle driver are either retained explicitly or assigned a reviewed projection disposition:

- normal wild battles from a supplied opponent species and level;
- trainer battles and trainer party construction;
- link battles, including choice exchange and paired, conditionally synchronized battle RNG states;
- Safari battles;
- the Old Man tutorial's battle behavior;
- battle initialization from party data;
- move selection, move legality, Struggle, PP, and Disable;
- trainer move selection and trainer-class AI actions;
- player actions: fight, switch, item, and run;
- traded-Pokémon obedience, badge thresholds, random replacement moves, naps, loafing, and self-damage;
- mechanics-visible battle-menu behavior: move browsing/reordering, bag reordering, failed item attempts, Mimic choice, shift-style response, wild-faint run-or-replace response using party-slot-1 Speed, and capture nickname input;
- priority, speed ties, action ordering, and actions that consume a turn;
- all 165 moves and all move-effect dispatch paths in the ROM;
- physical/special classification by type index;
- normal, fixed, OHKO, Counter, confusion, recoil, and multi-hit damage paths;
- accuracy, evasion, critical hits, STAB, type effectiveness, Reflect, Light Screen, burn, paralysis, and badge boosts;
- nonvolatile and volatile status conditions and all counters;
- switching with exact active/party codecs, send-out reset matrices, retained scratch, deterministic enemy destination, trapping, charging, recharge, Rage, Bide, Thrash/Petal Dance, Transform, Mimic, Mirror Move, and Metronome;
- fainting, status/volatile asymmetries, participation and Revive-to-EXP flags, replacement choice, victory, defeat, escape, and simultaneous-KO behavior;
- all 83 ordinary-item dispatch entries, their battle rejection/success paths, balls, capture, Safari bait/rock, Poke Doll, PP restorers, and trainer AI items;
- experience and stat-experience gain, level-up stat recalculation, and move-learning decisions reached during battle;
- the `EndOfBattle` evolution path when its source guard permits it, including cancel decisions, species/stat/move mutation, and the wild-battle stone-evolution bug;
- Pokédex seen/owned mutation, trainer prize money, Pay Day, and battle-result party mutations;
- relevant arithmetic helpers, memory layouts, banked calls, and RNG routines;
- known bugs and player/enemy asymmetries present in the pinned ROM.

### 3.2 Outside the battle model

The following are not simulated as game systems:

- walking, maps, collision, NPC scripts, and encounter triggering;
- map-specific wild encounter tables as an RL reset source;
- PC storage management except the minimum capture result needed to match battle exit behavior;
- trading UI and cable setup before the paired post-setup battle state has been established; a separate setup theorem is required for any full cable-session claim;
- overworld evolution triggers other than the `EvolutionAfterBattle` call made by `EndOfBattle`;
- Pokédex, graphics, audio, and animation rendering as presentation systems, while retaining seen/owned writes and any action/state consequences of entering such UI from battle item dispatch;
- post-return caller behavior: blackout warp/heal/money halving, trainer fought/object map scripts, link cable's immediate `HealParty`, and Old Man script cleanup;
- save files and persistence beyond returning the mutated party/inventory/result.

Assembly outside `pokered/engine/battle/` is still in proof scope when battle code calls it or it changes projected state. Examples include `pokered/engine/items/item_effects.asm`, `pokered/home/move_mon.asm`, `pokered/engine/pokemon/experience.asm`, and the math/RNG helpers.

### 3.3 Version policy

Pokémon Red (UE) is the first proof target. Pokémon Blue shares almost all battle code, but support is not declared verified until its ROM hash, relevant data slices, conditional assembly, and refinement proofs are checked. Virtual Console patches are a separate target because `BattleRandom` and link delays contain VC-specific branches.

### 3.4 Formal episode boundary

The proof must name concrete machine entry and exit checkpoints rather than use “battle” informally.

- The common supplied-battle machine entry is `InitOpponent` with a valid bank/stack return frame, nonzero explicit opponent, and a proved fetched-pipeline witness; equivalently, execute the caller transfer or compose the immediate nonzero-opponent prefix of `InitBattle`. `PC = InitOpponent` alone is not a physical checkpoint. The first semantic checkpoint may occur after mode-specific loading, but the driver theorem includes that loading.
- A supplied wild predicate establishes species/level and wild scan scratch; `TryDoWildEncounter` and map encounter tables are outside the reset theorem.
- A trainer predicate establishes class/1-based number and required trainer metadata/end-text/map state before the driver reaches `ReadTrainer`.
- A link predicate begins after cable setup has established exchanged parties, clock role, and each cartridge's post-processed ten-byte random block; the battle proof retains both blocks even though each `BattleRandom` cycles nine. Equality is a conditional initial invariant, not a type-level assumption.
- A completed episode includes mode setup, `StartBattle`, `EndOfBattle`, and the outer return that restores letter-delay/map-palette/tile-animation state and sets carry. Trainer payout/end-text state, Pay Day payout, `EvolutionAfterBattle`, cleanup, and those frame facts are inside the episode theorem.
- A loss episode returns the battle result and exact fainted party state, including player-faint nonvolatile-status clearing and pre-cleanup volatile bytes. The later overworld `ResetStatusAndHalveMoneyOnBlackout` transition is outside this boundary and must not be attributed to the battle core.

A witnessed terminal edge from `StartBattle` begins an `ending` phase; it is not RL completion. `done` is emitted only after all payout/evolution requests, cleanup, and outer return have completed. Simultaneous active faint is retained as ordering metadata and may be nonterminal when reserves exist.

M0 must turn these source-level descriptions into symbol-addressed checkpoint predicates and state exactly which caller-established fields are preconditions. In particular, `StartBattle` unconditionally scans enemy-party HP records even on wild/Safari/tutorial paths, so a supplied active opponent alone is not a sufficient low-level precondition.

`InitBattleVariables` is not a total reset from arbitrary WRAM. It clears `wMiscBattleData` and selected fields, sets Safari mode only for a map-range test, and relies on prior cleanup/caller state for other battle-status bytes and normal/Old Man `wBattleType`. The low-level reset theorem therefore starts from a named canonical reset image (new-game/post-`EndOfBattle` invariants plus explicit mode inputs), while raw-state routine theorems retain stale-byte behavior.

The exact closure and caller boundaries are in [End-to-end verification closure](docs/reference/end-to-end-closure.md). In particular, overworld blackout processing and the cable club's post-return `HealParty` are separate from the primary battle-driver result.

## 4. Grounded source facts

The pinned repository contains:

- 165 move records of 6 bytes each in `pokered/data/moves/moves.asm`;
- 151 base-stat files, with 150 in the main table and Mew assembled at a special placement;
- four move slots and parties of at most six;
- 47 trainer-class entries in the move-choice and action-AI tables, many sharing generic behavior;
- an internal species-index space with gaps and special fossil/ghost IDs, distinct from Pokédex order;
- a 44-byte party Pokémon structure and a 29-byte active battle structure;
- three bytes of persistent battle-status flags per active side, plus counters and shared scratch state;
- 49 assembly files under `pokered/engine/battle/` and `pokered/data/battle/`;
- battle logic split across many ROM banks under the `Battle Engine 1` through `Battle Engine 11` and `Battle Core` sections in `pokered/main.asm`.

`pokered/engine/battle/core.asm` is the main coordinator. Its important labels include `StartBattle`, `MainInBattleLoop`, `SelectEnemyMove`, `ExecutePlayerMove`, `ExecuteEnemyMove`, `CalculateDamage`, `CriticalHitTest`, `AdjustDamageForMoveType`, `MoveHitTest`, `RandomizeDamage`, `BattleRandom`, and `InitBattle`.

The effect interpreter is not a single switch. `ExecutePlayerMove` and its enemy counterpart classify effects through `ResidualEffects1`, `SpecialEffectsCont`, `SetDamageEffects`, `ResidualEffects2`, `AlwaysHappenSideEffects`, and `SpecialEffects`, invoking the pointer table in `pokered/data/moves/effects_pointers.asm` at different points in execution. The high-level model must preserve that ordering rather than merely attach one callback to each move.

See [Current battle engine](docs/explanation/current-battle-engine.md), [Battle source map](docs/reference/battle-source-map.md), [Effect dispatch](docs/reference/effect-dispatch.md), [Item dispatch](docs/reference/item-dispatch.md), [Stat modifier flow](docs/reference/stat-modifier-flow.md), [Probability thresholds](docs/reference/probability-thresholds.md), [Switch/faint/participation flow](docs/reference/switch-faint-and-participation.md), the [sixth-pass ASM audit](docs/research/sixth-pass-asm-audit.md), [seventh-pass end-to-end audit](docs/research/seventh-pass-end-to-end-audit.md), [eighth-pass SM83 audit](docs/research/eighth-pass-sm83-semantics-audit.md), [ninth-pass gb-opcodes audit](docs/research/ninth-pass-gb-opcodes-audit.md), [tenth-pass microarchitecture audit](docs/research/tenth-pass-sm83-microarchitecture-audit.md), and [eleventh-pass DMG-B profile audit](docs/research/eleventh-pass-sm83-profile-evidence-audit.md).

## 5. Architecture

```text
standalone sm83-lean package                pret/pokered source at pinned commit
complete decode + clock/bus proofs                     │ RGBDS 1.0.2
              │ pinned Lake revision                   ▼
              └──────────────────────────► canonical ROM + .sym + .map + SHA manifest
                                                   │
                                  ┌────────────────┴───────────────┐
                                  ▼                                ▼
                      Game Boy bus/device adapter       verified ROM-table decoders
                                  │                                │
                                  ▼                                ▼
                       low-level battle runner              typed battle data
                         │ decodeBattle / observations
                         ▼
               high-level Battle.step
                         │
              refinement and trace proofs
                         │
                         ▼
             native/batched RL adapter
```

### 5.1 Proposed project layout

```text
sm83-lean/                         # separate repository and Lake package
├── lakefile.toml
├── lean-toolchain
├── LICENSE
├── Sm83.lean
├── Sm83/                         # decode, three semantic layers, pipeline/IDU/bus/clock, proofs
└── Tests/                        # flat-bus opcode and interrupt/HALT conformance

pokered-verify/
├── lakefile.toml                 # immutable sm83-lean git revision
├── lean-toolchain
├── PokeRed/
│   ├── Artifact.lean             # pinned hashes and source manifest
│   ├── System/
│   │   ├── State.lean            # Game Boy SoC state around imported Sm83 core
│   │   ├── Bus.lean              # ROM/VRAM/WRAM/HRAM/OAM/external SRAM mapping
│   │   ├── Cartridge.lean        # MBC3 ROM/RAM enable and banking
│   │   ├── Hardware.lean         # MMIO, LCD, timers, joypad, serial, audio, DMA
│   │   └── Composition.lean      # adapter satisfies Sm83 bus/interrupt contract
│   ├── ROM/
│   │   ├── Image.lean
│   │   ├── Symbols.lean
│   │   ├── Coverage.lean         # address-based code/data/edge manifest
│   │   └── Tables.lean
│   ├── Battle/
│   │   ├── Types.lean
│   │   ├── State.lean
│   │   ├── Invariant.lean
│   │   ├── Request.lean          # actions, naming, learning, evolution
│   │   ├── Outcome.lean          # terminal witness and raw fields
│   │   ├── Damage.lean
│   │   ├── Effects.lean          # staged effects and stat modifier flow
│   │   ├── Turn.lean
│   │   ├── Items.lean
│   │   ├── Capture.lean
│   │   ├── AI.lean
│   │   ├── Experience.lean
│   │   ├── Epilogue.lean         # ending requests, payout, evolution, cleanup
│   │   ├── Driver.lean           # mode setup through returned episode
│   │   ├── Link.lean             # paired cartridge-perspective semantics
│   │   └── Step.lean
│   ├── Refinement/
│   │   ├── Projection.lean
│   │   ├── Checkpoints.lean
│   │   ├── RoutineSummaries.lean
│   │   ├── Step.lean
│   │   ├── Driver.lean
│   │   └── Episode.lean
│   └── RL/
│       ├── LegalTeam.lean
│       ├── Generator.lean
│       ├── Observation.lean
│       └── Protocol.lean
├── Main.lean
└── Tests/                        # Game Boy integration, ROM, battle, RL

tools/
├── build-canonical-rom.sh
├── extract-symbols.py
├── emit-rom-manifest.py
└── compare-traces.py
```

The processor package boundary is specified in [Standalone SM83 semantics package](docs/reference/sm83-semantics-package.md). The complete x/y/z decoder, ALU equations, logical M-cycle schedules, pinned gb-opcodes dispositions, and per-row theorem matrix are in [SM83 implementation specification](docs/reference/sm83-implementation-spec.md). The physical fetched-IR pipeline, pin/IDU intent, clock domains, HALT/STOP matrix, and Game Boy ownership boundary are in [SM83 microarchitecture and system-boundary contract](docs/reference/sm83-microarchitecture-contract.md). The selected first SoC, eight-half-edge protocol, reset/boot relation, oracle quarantine, and capture procedure are in [DMG-CPU B console profile](docs/reference/dmg-cpu-b-profile.md).

Generated files must identify their source commit, ROM SHA-1/SHA-256, RGBDS version, generator version, and source slice. Generated data is accepted only with a Lean-checkable round-trip theorem or byte-equality certificate against the embedded canonical ROM.

## 6. Low-level machine model

### 6.1 Standalone processor dependency

The SM83 model is a separate, explicitly licensed Lean package. The battle project pins an immutable package commit and checks the resolved revision in CI. Processor theorem modules have no Pokémon or Game Boy-cartridge imports.

The package owns:

- typed registers and `Z N H C` flags with a proved zero-low-nibble byte codec;
- complete normalized instruction syntax;
- all 256 base-byte classifications: 244 legal instructions, one CB prefix, and 11 hardware-lock opcodes;
- all 256 legal CB-prefixed instructions;
- decoder/encoder, lengths, immediates, PC/SP behavior, ALU and control semantics;
- ordered stack/data bus transactions and exact taken/untaken timing;
- IME, delayed EI, DI, RETI, interrupt priority/entry including mid-dispatch IE-write cancellation/retargeting, HALT/wake/HALT bug, STOP profile hooks, and invalid lockup;
- independent declarative instruction, de-overlapped executable, and physical fetched-IR M-cycle semantics;
- address/control/data, IDU, commit, interrupt-poll, and clock-gate intent for every physical family cycle;
- flat-memory adapter plus generic fetched-byte `Runs`/`RunsUntil`/Hoare/frame logic with proved pipeline checkpoints;
- processor-only conformance runners and public theorem/axiom audits.

The package exposes a timed pin/IDU/interrupt/clock protocol rather than storing memory as a pure function inside CPU state. Its canonical executable transition advances one fetched-IR M-cycle carrying exactly four CPU T-cycles; the final microcycle normally fetches the successor while committing the current operation. The Game Boy adapter expands that cycle through `T1F T1R T2F T2R T3F T3R T4F T4R`, supplies phase-indexed bus values, and proves device/domain expansion. Stable reads reduce to one byte; changing internal-bus reads use the profile's temporal read-fold relation.

A declarative instruction relation and an independent de-overlapped executable runner record programmer-visible results and logical accesses. Leaf proofs use them only through de-overlapped/declarative and physical/de-overlapped sequence-refinement theorems with explicit fetch reassociation. DI/EI/RETI/HALT/STOP/lock and accepted interrupts use dedicated boundary relations.

### 6.2 Game Boy system adapter

This project owns the composed machine around the imported processor:

- 64 KiB address-space behavior with fixed/switchable ROM, VRAM, external SRAM, WRAM/echo, OAM, unusable region, MMIO, HRAM, and stack accesses;
- MBC3 ROM selection plus external-RAM enable/bank behavior used by transition sprite scratch;
- `IE`/`IF` latches and proof that the processor pending mask/acknowledgement corresponds to them; console reset/IR seed and any optional NMI input are profile-defined/tied off;
- divider/timer progression and reads of `rDIV`;
- joypad and controller schedule;
- serial registers/interrupts and paired cable scheduling;
- LCDC/STAT/LY/VBlank, VRAM/OAM access restrictions, DMA-sensitive behavior, and monochrome active-access/IDU OAM corruption parameterized by a measured fixture or reviewed instance-family relation;
- audio/VBlank state sufficient for sound waits;
- SGB/palette paths or proved summaries;
- CPU-T/M-cycle, PPU-dot, oscillator, serial, and cartridge-RTC domain conversion plus HALT/STOP clock gating;
- an executable fuel-bounded system runner and semantic checkpoints that include fetched IR/pipeline state.

The first console theorem names a hardware profile/revision; “Game Boy” without a profile is not precise enough for model-sensitive timing tests. The selected first profile is `DmgCpuBCommonBoot`, with canonical DMG boot-ROM identity, unbonded NMI, unused IRQ tie-offs, and explicit board/OAM-instance parameters. DMG-CPU C and CGB profiles are later generalizations.

The composed semantics distinguishes invalid bus response/assumption, processor lockup, HALT, STOP, observed cartridge divergence, system timeout, and analysis fuel exhaustion. None is a cartridge battle result.

### 6.3 Required processor theorems

Before use as a proof dependency, `sm83-lean` proves:

1. total deterministic decode and exact `244 + 1 + 11`/256 partition;
2. legal decode/normalized encode byte round trips and instruction-length/PC consumption;
3. ALU and flag equations, including exhaustive DAA and signed-SP cases;
4. register/frame noninterference and AF masking;
5. exact read/write/stack order and conditional timing;
6. executable physical transition determinism for valid responses, with unstable STOP behavior explicitly relational;
7. bootstrap/fetched-pipeline well-formedness and complete 101-family address/data/IDU/commit/poll coverage;
8. de-overlapped/declarative refinement plus physical/de-overlapped sequence refinement with fetch reassociation and sound generic program/run-until/return/frame composition;
9. staged EI/DI/RETI sequences, five-M-cycle prefetch-aware interrupt entry/priority plus exact IE-write cancellation/retargeting, HALT wake/bug/following-byte cases, seven STOP outcomes, and invalid-opcode no-fetch lockup;
10. clock-domain intent, OAM-trigger trace sufficiency, state preservation, and public theorem axiom audit.

### 6.4 Validation before use

Validation is layered:

1. Lean theorems for decoder, flags, arithmetic, timing, and control invariants;
2. all 500,000 pinned SingleStep fixtures through the de-overlapped flat-bus runner, with non-authoritative IE/IME and idle pins rejected and HALT/STOP quarantined;
3. every row compared against the exact-hash local `gbdev/gb-opcodes` clone through `tools/audit-gb-opcodes.py`;
4. five pinned microarchitecture sources checked through `tools/audit-sm83-sources.py`, including 101 physical families, 75 Mooneye sources, 4096 DAA rows, seven STOP outcomes, and corpus schemas;
5. DMG-B profile evidence checked through `tools/audit-sm83-profile-sources.py`, including eight half edges, reset/gates/NMI, SameBoy quarantine, and 513 GBMicrotest fixtures;
6. physical/de-overlapped sequence, interrupt/EI/HALT/following-byte/invalid-lock processor proofs;
7. Blargg/Mooneye CPU, interrupt, timer, OAM/DMA, and PPU ROMs through the Game Boy adapter with profile-qualified expectations;
8. differential traces against pinned SameBoy's DMG-B model outside its STOP/IF/OAM quarantine, die-derived `gb-research` HDL waveforms, and fixture-qualified physical-hardware captures.

A printed `#eval` Boolean is not a test: false output still compiles. Executable fixture runners fail with a nonzero status, while universal correctness obligations are theorems.

Tests and reference documents challenge the model but do not establish the Pokémon refinement theorem or become theorem premises. Exact pinned references and package gates are in [Standalone SM83 semantics package](docs/reference/sm83-semantics-package.md).

## 7. ROM and source ingestion

1. Build Red with the exact RGBDS version in a hermetic environment.
2. Require the output SHA-1 to equal the hash in `pokered/roms.sha1`.
3. Produce `.sym` and `.map` files and normalize them into a checked-in manifest.
4. Compute SHA-256 for the ROM and every battle-relevant source file.
5. Discover the transitive driver graph from `InitOpponent` through outer return, including bank wrappers, pointer/predef/text/animation/audio tables, interrupts, indirect jumps, and every read code/data/asset range. A direct-`call` scan is not complete.
6. Decode tables from ROM bytes, not from a second manual copy of the assembly.
7. Emit the address-based coverage manifest specified in [end-to-end closure](docs/reference/end-to-end-closure.md), mapping every reachable code/data/interrupt/presentation range to one of:
   - executed directly by the machine model;
   - replaced by a proved routine summary;
   - presentation-only with a proved frame condition;
   - caller-integration boundary with an explicit non-claim or separate theorem.
8. Fail CI if the source commit, binary hash, symbols, generated data, or coverage manifest drift.

RGBDS is not formally verified. The exact output hash anchors the proof to the canonical binary. Any claim about a modified source tree requires rebuilding and proving against the new binary.

## 8. High-level battle model

### 8.1 Numeric fidelity

Use `BitVec 8`, `BitVec 16`, and explicit multi-byte helpers wherever the ROM wraps, shifts, truncates, or compares bytes. Use `Nat` only after proving a bounded conversion theorem. Do not “clean up” arithmetic into unbounded mathematical formulas unless equivalence to the byte-level algorithm is proved.

The model preserves:

- integer flooring after each intermediate division;
- caps such as 999 where the ROM applies them, and lack of caps where it does not;
- the ROM's big-endian in-memory battle values;
- status-bit packing and counters;
- PP Up bits in the high two PP bits;
- internal species IDs rather than assuming Pokédex IDs;
- player/enemy asymmetries, including separate code paths;
- source-expanded `percent = × $ff / 100` thresholds, call-site offsets/polarities, rejection sampling, and exact number of random draws.

### 8.2 Requests and responses

The pure core is an interaction state machine. It pauses on typed requests rather than reading a controller or global RNG:

```lean
inductive BattleRequest
  | chooseAction (side : Side) (legal : Finset Action)
  | chooseItemTarget (item : ItemId) (legal : Finset ItemTarget)
  | chooseMimicMove (legal : Finset MoveSlot)
  | chooseReplacement (side : Side) (legal : Finset PartyIndex)
  | chooseWildFaintResponse (legal : Finset WildFaintResponse)
  | chooseShiftResponse (incoming : SpeciesId) (legal : Finset ShiftResponse)
  | chooseMoveToLearn (mon : PartyIndex) (newMove : MoveId)
  | chooseCaptureNickname (species : SpeciesId) (destination : CaptureDestination)
  | chooseEvolution (mon : PartyIndex) (target : SpeciesId)
  | selectionResponse (legal : Finset SelectionResponse)
  | ordinaryRandomByte (site : RandomSite)
  | linkChoice (payload : LinkPayload)

inductive TerminalCause
  | partyExhausted (side : Side)
  | ordinaryRun
  | moveEscape (side : Side) (move : MoveId)
  | pokeDollEscape
  | capture
  | safariEnemyRan
  | safariBallsExhausted
  | linkRun (side : Side)
  | tutorialCapture

inductive BattleVerdict | win | loss | draw

structure BattleTerminal where
  cause : TerminalCause
  mode : BattleMode
  perspective : Side
  rawResult : UInt8
  preCleanupEscaped : UInt8
  verdict : Option BattleVerdict
  simultaneousDetectedFirst : Option Side

structure EpisodeResult where
  terminal : BattleTerminal
  -- final projected state/events are returned alongside this record

inductive EpisodePhase
  | battling
  | ending (witness : BattleTerminal)
  | returned (result : EpisodeResult)
```

The cause is justified by a low-level terminal control-flow witness, not guessed from the final result byte. `wBattleResult` values overlap across capture, Run, link draw, loss, and several zero-valued escape/victory paths; `EndOfBattle` also clears `wEscapedFromBattle`. Simultaneous active faint is optional provenance because it can be nonterminal when reserves remain. The terminal witness moves the machine to `ending`; only the post-epilogue outer return constructs `EpisodeResult`. See [Battle outcomes](docs/reference/battle-outcomes.md) and [end-to-end closure](docs/reference/end-to-end-closure.md).

Cartridge divergence is an outcome of the partial runner, not an `EpisodeResult`; it remains distinct from terminal game outcomes and adapter fuel exhaustion.

For a full link episode, `linkChoice` is scheduled across the paired cartridge perspectives and the serial exchange updates both local receive bytes; it is not two independent opponent-policy callbacks.

Each response is validated against the request. An out-of-range protocol response is different from a cartridge-valid but ineffective attempt: the former is a no-mutation API error, while the latter executes the ROM's failure branch and may return to selection without consuming the turn.

Capture naming and full-moveset learning are also nested controller protocols. `AskName` occurs after the Pokédex write and party count/species/OT or box species/name-array changes, but before the new party record/shifted box records and ordinary bag-ball removal; Safari count was already decremented. The request state therefore carries a pending capture-construction phase rather than pretending all storage mutation is atomic. Learning can loop through HM rejection, slot cancellation, and abandonment confirmation. Atomic RL responses for these decisions require concrete trace-refinement theorems.

Switch traces also cross presentation and mechanics. `RetreatMon` selects variable recall text from wrapped enemy-HP arithmetic before the enemy finishes the turn; that branch changes low-level timing, while `SendOutMon` clears only selected scratch fields and leaves `wPlayerSelectedMove` plus adjacent loaded-record bytes available to ordering/Counter logic. The semantic adapter preserves the exact retained fields, including stale priority deciding whether switched-in poison/burn residual runs before the enemy action, and couples the text branch at the hardware layer.

The selection layer cannot be erased completely. For a non-disabled highlighted move, `PrintMenuItem` writes `wPlayerSelectedMove` and reloads its move record; canceling also leaves the highlighted slot in `wPlayerMoveListIndex`. Disabled highlights take a different path and do not reload that scratch. The retained values affect Quick Attack/Counter order, Counter's power/type inputs, and later slot-indexed behavior if the player cancels Fight and switches or uses an item. SELECT can also reorder moves during battle and bag entries inside the battle bag. The high-level model therefore has a small mechanics-visible selection automaton or an equivalent proved `ActionCommit` abstraction. The RL adapter may emit a canonical direct commit, but the unqualified cartridge theorem must cover arbitrary valid selection traces.

### 8.3 Checkpoints

Initial checkpoints should be narrow and then composed:

1. explicit `InitOpponent` driver entry and mode-specific reset relation;
2. after trainer/wild/link loading and before `StartBattle`;
3. before action selection;
4. after both actions are fixed;
5. before each acting side executes;
6. after move damage/effect completion;
7. after residual damage;
8. before and after faint/replacement handling;
9. a witnessed `StartBattle` terminal edge entering `ending`;
10. after `EndOfBattle` payout/evolution/cleanup;
11. outer return with restored fields, bank/stack frame, carry, and final `EpisodeResult`.

Fine-grained checkpoints keep individual refinement proofs tractable and expose exact RNG consumption. The pre-cleanup terminal witness is mandatory: at final return, memory alone cannot distinguish result-zero victory, Poke Doll/move escape, Safari escape, and Safari Balls exhaustion.

### 8.4 Divergence

Some ROM states can freeze, such as division by zero in damage scaling. Rejection loops can also fail to terminate under an adversarial infinite random stream. The semantics therefore use a small-step relation or a partial/coinductive computation, not an unjustified total function. The RL adapter may enforce an operational step budget, but it reports timeout separately from a game result.

## 9. Proof plan

### Layer A — artifact identity

- Prove embedded manifest values equal checked artifacts.
- Check canonical ROM hash in CI.
- Prove generated ROM tables round-trip to their byte ranges.

### Layer B — standalone SM83 and system composition

- In `sm83-lean`, prove complete base/CB decode, all three semantic layers, fetched-pipeline/IDU/clock properties, ALU/flag/frame/timing properties, interrupts, HALT/STOP, and lockup behavior.
- Pin the audited package commit and prove the Pokémon Game Boy bus/device adapter satisfies its read/write/clock/interrupt contract.
- Validate every legal opcode independently of battle reachability; use the decoded battle graph only to prove system-range closure and prioritize integration traces.

### Layer C — state projection

- Define `decodePartyMon`, `decodeBattleMon`, and volatile-state projection.
- Prove bounds, non-overlap where applicable, and duplication invariants at checkpoints.
- Prove loading/switching routines establish phase-specific codecs, send-out reset matrices, participation flags, and stale-counter/scratch invariants.

### Layer D — routine refinement

Prove low-level-to-high-level equivalence for leaf kernels first:

- multiply/divide;
- stat calculation and stage ratios;
- RNG and link RNG;
- move-table decoding;
- accuracy and critical-hit tests;
- neutral damage, type adjustment, and random damage;
- HP application and residual damage;
- individual move effects;
- AI scoring and action routines;
- item and capture kernels.

### Layer E — turn refinement

Compose routine theorems across action ordering, status gates, move execution, residuals, and faint handling. Require equality of the projected semantic request trace and preservation of `CoupledRemaining`, so a proof cannot hide extra or missing random draws even though the low-level hardware trace has a different alphabet.

### Layer F — episode refinement

Compose mode-specific `InitOpponent` setup, then induct over checkpoint traces until a witnessed terminal edge, conditional on termination. Continue through the `ending` phase: prove Pay Day/evolution requests, cleanup, restored fields, return bank/stack/carry, final party/inventory state, and projected events agree. Optional caller theorems separately compose overworld, cable auto-heal, tutorial, or encounter behavior.

### Layer G — team generator

Define explicit predicates and prove every generated team satisfies its selected legality mode. This is a generator-safety theorem, not a claim that every legal team is generated with equal probability.

## 10. Team legality and reset modes

“Game-correct random team” is ambiguous, so the API exposes named modes:

1. **Battle-valid:** byte-level values accepted by the battle engine and all required invariants. Useful for fuzzing glitches.
2. **Canonical species:** only the 151 ordinary species, level 1–100, valid moves/PP/stats, and no MissingNo./fossil/ghost IDs.
3. **Learnset-legal:** moves are justified by base moves, level-up, TM/HM compatibility, or a supplied evolution history; PP and stats are derived from DVs/stat experience.
4. **Progression-witnessed:** a constructive history from a supplied initial roster and resource ledger witnesses experience, evolution, move-learning/forgetting, and TM/HM consumption. One-use TM constraints apply across that ledger.
5. **Trainer-defined:** exactly a party generated by the ROM's trainer data and special-move patches.

A claim that a team is reachable from a new game save would additionally require formalizing captures, gifts, trades, item acquisition, and overworld resource availability. Those systems are outside this battle project, so `ProgressionWitnessed` must not be renamed or advertised as unconditional cartridge/save reachability.

The default RL mode should be `LearnsetLegal`, with configurable level range, team size, species distribution, DV/stat-exp distribution, item inventory, badges, and battle kind. Distribution policy is configuration, not part of battle correctness.

## 11. RL interface

The verified pure core exposes:

```text
reset(config, rngProvider) -> handle, observation, legalActions
step(handle, action)       -> handle, observation, legalActions, events, result
snapshot(handle)           -> canonical bytes
restore(bytes)             -> handle | validation error
stepBatch(handles, actions)-> batch result
```

Requirements:

- deterministic replay from initial snapshot plus response transcript, including Mimic/item-target/shift/evolution and selection browse/cancel/reorder responses;
- paired perspective state, per-side RNG cursor/list, and serial-choice events for full link battles;
- canonical serialization with a proved encode/decode round trip;
- stable action IDs and legal-action masks;
- perfect-information and player-view observations as separate schemas;
- explicit side-to-act and pending forced choices;
- event stream separate from reward shaping;
- no reward function in the verified mechanics core;
- batch execution and profiling before choosing Python FFI, C ABI, or subprocess transport;
- differential tests proving adapter serialization does not alter core inputs/outputs.

Native speed comes from the high-level Lean model. The instruction-level ROM interpreter is a proof/reference oracle and differential-testing tool, not the RL hot path.

See [RL environment design](docs/explanation/rl-environment.md).

## 12. Existing Lean work

A related repository, `vicgalle/gameboy-pokered-verify` at commit `aa9b95b87b82210464a24e849026722c425c7be2`, contains direct Lean helpers for selected arithmetic, logic, load, stack, and control operations plus proofs about 13 isolated Pokémon Red bugs or arithmetic phenomena. Its Focus Energy, 1/256 comparison, Psywave/Bide, stat scaling, Substitute, and trainer-AI examples remain useful regression ideas.

All nine reviewed `SM83/*.lean` modules confirm it is research input, not a processor dependency:

- there is no opcode fetch/base-CB decode/step loop, instruction-length proof, invalid-byte classification, or integrated PC/cycle behavior;
- `CPUState` stores a pure total memory function and permits arbitrary low bits in F;
- stack helpers capture final flat-memory bytes but not observable bus order;
- `di` and `ei` are no-ops, HALT only sets a Boolean, and IME delay/interrupt entry/RETI/HALT bug/STOP/lockup are absent;
- DAA, signed-SP forms, and complete operand/opcode dispatch are absent;
- `#eval` examples print expected-looking Booleans but do not fail compilation when false;
- most bug models are handwritten abstractions rather than executions of canonical bytes;
- it proves no battle transition or episode refinement;
- no obvious root license file exists at the reviewed commit, so source reuse requires permission or a licensing decision.

The standalone package should be implemented cleanly unless reuse is explicitly licensed. The module-by-module audit and external corpus pins are in [Eighth-pass SM83 semantics audit](docs/research/eighth-pass-sm83-semantics-audit.md).

## 13. Milestones

### M0 — Reproducible baseline

Deliver:

- hermetic RGBDS `1.0.2` build from an explicitly pinned source derivation (nixpkgs' current 1.0.1 package is insufficient);
- canonical Red ROM hash check;
- `.sym`/`.map` manifest;
- address-based transitive call/range inventory covering bank switches, predefs, text callbacks, pointer tables, interrupts, and read data/assets;
- initial coverage manifest using the schema in [end-to-end closure](docs/reference/end-to-end-closure.md);
- symbol-addressed canonical reset-byte predicate distinguishing caller inputs from prior-cleanup invariants;
- pinned Lean version, checked `DmgCpuBCommonBoot` profile manifest, and immutable dependency policy for the separately licensed `sm83-lean` package.

Exit criterion: CI rebuilds the ROM and fails on any artifact drift.

### M1 — Standalone SM83 package and first system composition

Deliver in the separate `sm83-lean` package:

- constrained registers/flags, normalized instruction AST, encoding-derived x/y/z decoder, all 256 base classifications and all 256 CB decodes;
- all 500 legal opcode semantics and all 11 invalid lockup transitions;
- independent declarative relation, de-overlapped runner, and physical fetched-IR bus/IDU/clock core with proved sequence refinements;
- exact logical cycles plus 101-family physical address/commit schedules, 4096-row DAA closure, signed-SP forms, staged IME/EI/DI/RETI, interrupt entry, HALT following-byte behavior, seven STOP outcomes, and run outcomes;
- bootstrap/fetched checkpoint and return-sentinel proofs, exact-hash gb-opcodes/five-source projections, axiom audit, license, release manifest, and complete normal-instruction flat-bus conformance corpus.

Deliver in the Pokémon verifier:

- immutable Lake dependency pin;
- banked ROM/WRAM/HRAM plus VRAM/OAM/external-SRAM/MMIO Game Boy adapter;
- profile-qualified T1F–T4R half-edge reads/writes, temporal read fold, clock domains, DMA contention, and fixture/family-qualified monochrome OAM-corruption behavior;
- proof that bus, `IE`/`IF`, acknowledgement collision, and clock behavior satisfy the processor contract;
- trace runner and fetched-IR/pipeline checkpoints;
- profile-qualified system conformance tests.

Vertical slice: execute an arithmetic helper and a leaf battle routine directly from canonical ROM bytes through the dependency and Game Boy adapter.

Exit criterion: the standalone package passes its complete gates, independent traces agree, adapter composition is proved for the slice, and a Lean theorem connects one decoded ROM routine to a high-level function.

### M2 — ROM data and party construction

Deliver:

- verified decoders for move, effect-pointer, ordinary-item-pointer, species, type, trainer party, all 47 trainer move-layer/action-AI rows, growth, and learnset data;
- party/battle structure codecs;
- stat and move derivation plus source-expanded battle probability thresholds;
- legality predicates and first random-team generator.

Exit criterion: all 165 moves and 151 ordinary species round-trip to canonical ROM bytes, and generated teams carry legality proofs.

### M3 — First complete ordinary episode

Deliver:

- action request/response and action-commit model;
- mechanics-visible move browsing/reordering, bag reordering, failed attempts, and Fight-driven run-counter reset;
- priority and speed ties;
- status-free, no-additional-effect damage path;
- HP application and basic faint handling;
- one-turn refinement plus a witnessed terminal transition;
- no-Pay-Day/no-evolution `EndOfBattle` cleanup and outer restore/carry theorem;
- first `InitOpponent`-to-return episode refinement theorem.

Vertical slice: supplied one-Pokémon wild fixture whose ordinary damaging move ends the battle, with exact projected mechanics-random call-site trace consumption and final driver-state equality.

Exit criterion: one decoded-ROM execution and the independent high-level model refine from explicit driver entry through epilogue and outer return with no unproved mechanics summary.

### M4 — Damage and statuses

Deliver:

- accuracy/evasion, critical hits, STAB, type table, damage randomization;
- stat stages, exact-cap rollback, badge/status cross-stat matrix, burn, paralysis, sleep, freeze, poison, Toxic, confusion;
- Reflect/Light Screen and badge effects;
- residual ordering, poison-KO-then-Seed/nominal overkill healing, Rest-retained Toxic state, and cartridge overflow behavior.

Exit criterion: routine and turn proofs cover all damage/status branches in the manifest.

### M5 — All moves and turn flow

Deliver:

- all effect-dispatch categories and 165 move records;
- multi-hit/multi-turn, unbound generated charge identity, direct/nested PP, stranded invulnerability, trapping, Bide, Rage, Counter;
- Transform, Mimic, Mirror Move, Metronome, Substitute, recoil, drain's shared-damage mutation, OHKO, fixed damage;
- switching, deterministic enemy replacement, participation/Revive flow, wild-faint slot-1-Speed escape, simultaneous faint, terminal control-flow witnesses, and raw win/loss/escape fields.

Exit criterion: every move ID has a proved dispatch/data path and no in-scope effect label is uncovered.

### M6 — Items, capture, AI, and progression

Deliver:

- all 83 ordinary-item dispatch entries, battle action legality, targeting, failure, and effects;
- balls and capture, equality-only raw capacity gates, nickname request, Safari bait/rock, Poke Doll, Pokédex flags, and exact append-versus-front-insert box/party result;
- trainer move scoring and action AI;
- experience/stat experience, level-up, nested move-learning/HM rejection/abandonment requests, and traded-Pokémon disobedience;
- trainer payout, Pay Day, post-battle evolution/cancel requests, and the separately composed terminal epilogue/cleanup mutation.

Exit criterion: normal wild and trainer battles refine end-to-end.

### M7 — Link, Safari, and tutorial modes

Deliver:

- link choice exchange across paired cartridge perspectives and per-perspective RNG updates;
- conditional synchronization invariants, cable-setup list asymmetry inputs, known in-battle desync behavior, and authoritative local-party versus status-only-updated mirrored exit state;
- Safari loop and escape factors;
- Old Man capture plus player-name restoration and aliased wild-buffer mutation.

Exit criterion: all final in-scope battle modes have transition and episode theorems.

### M8 — Proof closure and audit

Deliver:

- complete address-based code/data/interrupt/presentation coverage manifest with no unresolved indirect edges;
- no unproved routine summaries in the theorem dependency graph;
- mode-indexed battle-driver episode theorem from explicit entry through returned `EpisodeResult`;
- explicit non-claims or separate composition theorems for overworld encounter/blackout, trainer scripts, link auto-heal, and tutorial caller cleanup;
- axiom and `sorry` audit;
- reproducible proof report tied to source and ROM hashes.

Exit criterion: the project may use “formally verified 1:1 battle mechanics” without qualification, subject to the observation boundary in §2.

### M9 — RL release

Deliver:

- ordinary and paired-link snapshot protocol, action schema, observations, events, and batching, with `ending` snapshots and `done` only at returned `EpisodeResult`;
- seeded random provider and replay transcripts;
- Python or C-facing adapter selected from benchmarks;
- throughput/memory benchmark suite;
- long differential campaigns against the ROM reference runner.

Exit criterion: RL clients can train without invoking the machine interpreter, while sampled episodes replay identically through the verified reference boundary.

## 14. Verification and CI gates

Every merge must satisfy applicable gates:

- `lake build` with one compatible pinned Lean toolchain across the battle project and immutable `sm83-lean` dependency;
- processor dependency revision/license/release-manifest and public theorem axiom audit;
- no `sorry`, `admit`, unsafe proof shortcuts, or undeclared axioms in the verified dependency graph;
- canonical ROM and generated-file hash checks under pinned RGBDS 1.0.2;
- generated-table byte equality;
- address-range coverage has no new gap or unresolved indirect/predef/text/interrupt edge;
- complete processor decoder/three-layer/pipeline/IDU gates and pinned 500,000-case flat-bus corpus, plus 4096 DAA rows and interrupt/HALT/following-byte/lockup sequences;
- profile-qualified Game Boy CPU/timer/interrupt/DMA/PPU integration ROMs and `validate-hardware-capture.py` for every imported deterministic DMG-B capture bundle;
- high-level property tests and curated cartridge-glitch regressions;
- the minimal `InitOpponent`-to-return episode theorem remains green;
- differential traces against the low-level ROM runner;
- deterministic transcript replay;
- serialization round-trip tests;
- benchmark reporting for the high-level and batch APIs.

A test failure blocks correctness claims. A test success never substitutes for a theorem required by the coverage manifest.

## 15. Principal risks

| Risk | Consequence | Mitigation |
|---|---|---|
| `Random_` depends on `rDIV`, flags, VBlank, and timing | A seed-only model falsely claims console RNG equivalence | Prove transcript-parametric equivalence; model exact hardware timing separately |
| Presentation routines are interleaved with mechanics | Stubbing may hide memory or RNG effects | Prove frame conditions and preserve the low-level hardware trace/semantic random projection |
| Menu code leaks into mechanics | Action-only APIs miss Counter scratch, capture names, nested learning, and persistent move/bag/box ordering | Verify mechanics-visible request state machines and let RL use only proved canonical adapters |
| WRAM unions and duplicated active/party data | A clean record model misses aliasing or synchronization bugs | Project only at proved checkpoints; preserve byte model in low-level semantics |
| Treating `InitBattleVariables` as a whole reset | Standalone resets silently depend on stale status/mode bytes | Define and prove a canonical reset image plus raw-state variants |
| Decoding terminal cause from final WRAM | Cleanup erases escape/mode evidence and raw result values overlap | Record a pre-cleanup witness, enter `ending`, and emit `done` only after the proved epilogue/return |
| Treating link battle as one shared state | Setup or asymmetric draws can desynchronize cursors and duplicated party views | Model paired cartridge perspectives; prove synchronization only while its premises hold |
| Player and enemy routines are asymmetric | A symmetric simulator “fixes” real behavior | Keep separate paths until equivalence permits factoring |
| Division/rejection loops may not terminate | Total Lean function erases cartridge freezes | Model partiality/divergence and use explicit operational budgets only in adapters |
| Manual ASM/data transcription drifts | Lean proves the wrong program | Decode machine code and ROM tables; hash every artifact |
| CPU embeds pure memory or uses cycle totals only | MMIO side effects, stack order, interrupts, DMA, and `rDIV` sample timing disappear | Separate physical pin/IDU core from the DMG-B T1F–T4R adapter, model changing reads as temporal folds, and prove all semantic-layer refinements |
| De-overlapped fixtures are treated as the physical pipeline | Prefetch discard, PC correction, DI/EI/RETI phase order, JP HL, HALT, and STOP become wrong | Keep declarative, de-overlapped, and fetched-IR semantics distinct; prove sequence trace reassociation |
| Internal cycles drop address/IDU behavior | Monochrome OAM corruption and stack/PC/HL update effects disappear | Emit address drive and IDU intent every M-cycle; prove the selected fixture or reviewed instance-family corruption relation |
| HALT/STOP are repeated normal idle cycles | DMA, DIV, PPU, wake, and speed-switch clocks advance in the wrong domains | Use typed clock-domain gate intent and profile-qualified system tests |
| Partial opcode library is treated as a processor | Unimplemented bytes, DAA, EI/HALT, or invalid lockups are silently bypassed | Complete all 256 base classifications and 256 CB semantics in standalone package before dependency release |
| gb-opcodes display fields are imported as semantics | F8 increments SP, `immediate` is misread, PREFIX cycles double, or STOP is falsely fixed at one interpretation | Derive semantics from x/y/z encoding; use exact-hash catalogue only for reviewed metadata projection with explicit non-normal dispositions |
| Processor dependency follows a moving branch | Previously proved battle theorem resolves against different semantics | Pin immutable commit/toolchain and audit resolved Lake manifest in CI |
| Console model/revision is unnamed | Hardware-sensitive tests and timing claims have no unique meaning | Select and report a hardware profile for every system/episode theorem |
| `#eval` output is called a test | False Boolean output still compiles | Use theorems or nonzero-exit executable fixture checkers |
| Full instruction interpretation is too slow for RL | Correct reference is unusable for training | Use verified high-level core for hot path; machine model only for proof/reference |
| Existing repositories lack clear license files | Reuse may be legally blocked | Resolve licensing before copying; otherwise clean-room implementation |
| The battle call graph crosses subsystem boundaries and indirect tables | Direct-call or `pokered/engine/battle` coverage omits predefs, text callbacks, interrupts, assets, SRAM, and caller writes | Maintain address-based code/data range closure with reviewed dispositions |
| Caller behavior is confused with driver output | Link auto-heal/blackout/trainer flags are wrongly included or omitted | Publish separate kernel, driver, and caller-integration theorem boundaries |
| Proof scope grows too broad before a theorem exists | Long project with no validated architecture | Require a minimal complete driver episode at M3, then expand coverage |

## 16. Decisions required before implementation

These do not block this documentation phase, but M0/M1 must settle them:

1. Final `sm83-lean` repository/package name, explicit root license, and whether licensed prior-art code can be reused or the processor is cleanly reimplemented.
2. The pinned Lean version shared by dependency/consumer and custom Nix derivation for RGBDS `v1.0.2+hotfix` (nixpkgs currently provides 1.0.1).
3. Which identified DMG-CPU B fixtures populate the first signed capture corpus, including exact locked-pin/reset-recovery and OAM-instance classifications. Until then those fields remain explicit relations and are proved unreachable/irrelevant to Red.
4. Whether exact VBlank/timer/presentation execution is required in the first low-level runner or introduced through temporary instrumentation that cannot enter the final theorem graph.
5. Whether to extract the Game Boy SoC adapter as a third reusable package after first composition proof.
6. The bounded nickname-byte/API encoding and canonical naming-screen trace used while preserving exact party/current-box mutation.
7. Whether action/naming/learning theorems execute menu code directly or use separately proved canonical response refinements.
8. Default RL team distribution within the proved `LearnsetLegal` predicate.
9. RL observation schema and whether opponents receive hidden-information views.
10. Performance budget and target integration language, to be set from M3 benchmarks rather than guessed now.

## 17. Definition of done

The project is complete when:

- the source and ROM target are cryptographically pinned and reproducible;
- the separately licensed, commit-pinned processor dependency has complete base/CB decode, three semantic layers, fetched pipeline/IDU/clock, interrupt/HALT/STOP/lockup proofs, and conformance gates;
- the Game Boy adapter is proved to satisfy that processor's bus/clock/interrupt contract for the named hardware profile;
- the low-level semantics execute the actual in-scope machine-code ranges;
- every reachable code/data/interrupt/presentation range from explicit driver entry to outer return has a coverage disposition with no unresolved indirect edge or unproved semantic stub;
- every move, species data record, ordinary-item dispatch entry, trainer-AI row, battle mode, selection leak, progression mutation, and witnessed terminal outcome is covered;
- the high-level Lean simulator is executable and preserves cartridge bugs, including paired-perspective link desynchronization;
- the canonical standalone reset image is proved against its cartridge caller/cleanup preconditions;
- setup, step, terminal-witness, ending/epilogue, outer-return, and finite battle-driver refinement theorems compile without unreviewed axioms;
- RL `done` occurs only at returned `EpisodeResult`, not at a possibly nonterminal simultaneous faint or pre-evolution terminal witness;
- caller integration behavior is either separately proved or explicitly excluded as listed in the end-to-end closure;
- exact projected semantic-response/RNG call-site consumption and low/high trace coupling are part of the theorem;
- legal-team generators are proved safe;
- the RL adapter supports replay, action masks, capture naming, nested move-learning decisions, snapshots, events, and batching;
- CI can reproduce all artifacts, proofs, tests, coverage reports, and benchmarks.
