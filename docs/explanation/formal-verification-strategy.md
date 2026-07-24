# Formal verification strategy

<!-- mode: explanation -->

The hard part of this project is not writing a battle simulator in Lean. The hard part is proving that the executable simulator represents the pinned ROM rather than a cleaned-up interpretation of Generation I mechanics.

## Why direct transcription is insufficient

A manually translated Lean function can be internally correct and still mistranslate assembly. Lean proves the theorem it is given; it does not prove that a handwritten definition came from `core.asm`.

The related `gameboy-pokered-verify` project demonstrates both the value and the limit of snippet proofs. Its isolated theorems reveal subtle arithmetic behavior, but most models are written directly from selected source lines. There is no decoder that fetches the pinned ROM, no complete hardware state, and no battle-step refinement theorem.

This project closes that gap by making actual ROM bytes one side of every final equivalence theorem.

## Two semantics, one artifact

### Standalone processor dependency

The SM83 byte decoder and processor semantics belong in a separate `sm83-lean` package, pinned by immutable Lake revision. This prevents battle definitions from silently becoming processor axioms and makes complete opcode/interrupt validation reusable outside Pokémon.

The package exposes three proved-related views:

- a declarative one-instruction relation with exact architectural results, logical bus operations, and duration;
- an independent de-overlapped executable runner for flat-memory fixtures and leaf proofs;
- a canonical fetched-IR M-cycle pipeline that overlaps successor fetch with current writeback and emits address/data/control, IDU, commit, interrupt-poll, and clock-gate intent.

The package also provides generic fetched-byte `Runs`/`RunsUntil`, return-sentinel, Hoare, and frame judgments with explicit pipeline checkpoints. It does not interpret RGBDS labels or macros. The Pokémon project implements MBC3, mapped memory, `IE`/`IF`, DIV/timers, LCD, DMA, OAM corruption, joypad, serial, audio, and clock domains around that port, then proves the composition contract. Its first adapter is `DmgCpuBCommonBoot` and expands every M-cycle through T1F–T4R; changing dynamic-bus reads are temporal folds rather than one timeless byte. A total pure memory function, cycle-count-only executor, or SingleStep-style de-overlapped core is insufficient because prefetch, idle IDU addresses, reads/writes, clock gates, and sample phases can change hardware state and later RNG.

The package covers all 244 legal non-prefix base entries, all 256 CB entries, the CB prefix, and 11 invalid lockup bytes. Semantics come from a proved encoding-derived x/y/z decoder, not gb-opcodes' ambiguous display fields. It proves all 101 normal physical families, fetch reassociation, staged EI/DI/RETI, prefetch-aware interrupt entry and IE-write cancellation/retargeting, HALT following-byte cases, seven STOP outcomes, stack/IDU order, and no-fetch lockup. See [Standalone SM83 semantics package](../reference/sm83-semantics-package.md), [SM83 implementation specification](../reference/sm83-implementation-spec.md), [SM83 microarchitecture contract](../reference/sm83-microarchitecture-contract.md), and [DMG-CPU B profile](../reference/dmg-cpu-b-profile.md).

### ROM machine semantics

The low-level side fetches and decodes bytes from the canonical Red ROM. Its state includes SM83 registers/flags, fetched IR and hidden pipeline latches, stack, typed clock domains, interrupts, fixed/switchable ROM, WRAM/HRAM, VRAM/OAM and corruption state, external SRAM banking, MMIO, and external controller/serial/LCD/audio responses.

This side should be literal and inconvenient. It preserves aliases, shared scratch bytes, asymmetric branches, and nontermination. Its purpose is to say what the implementation does. Every system theorem names a console/SoC profile; the first is DMG-CPU B with explicit board/OAM-instance parameters. DMG, MGB, SGB, and CGB-sensitive timing must not be collapsed into an unnamed “Game Boy.”

### Battle semantics

The high-level side uses typed records, phases, requests, and semantic events. It is the code compiled for RL use. Ordinary modes use one state; the complete link semantics retains two cartridge perspectives and their serial exchanges. Its purpose is to make battle state explicit, executable, and efficient.

The refinement relation explains how low-level bytes correspond to high-level values at named checkpoints. The two implementations should not share enough code that equivalence becomes true by construction for the wrong reason.

## Anchor the proof to the binary

The source repository builds byte-identical ROMs with known hashes. The first target is the Red ROM with SHA-1:

```text
ea9bcae617fdf159b045185467ae58b2e4a48b9a
```

The proof package records:

- pokered source commit;
- RGBDS version;
- ROM SHA-1 and SHA-256;
- `.sym` and `.map` hashes;
- every generated Lean table's source byte interval and hash.

The source is invaluable for labels and explanation, but the formal execution target is the binary. This avoids trusting a separate assembly parser to reproduce macro expansion, bank placement, and conditional assembly.

RGBDS remains in the reproducibility chain, but matching the canonical output hash prevents an unnoticed assembler difference from changing the proof target. Nix is available in the current environment, but nixpkgs exposes RGBDS 1.0.1 rather than the required 1.0.2; M0 needs a custom pinned `v1.0.2+hotfix` derivation and a locked Lean toolchain.

The symbol-driven transitive closure follows direct branches, bank wrappers, predefs, text callbacks, pointer tables, interrupt vectors, and every ROM data range read before return. A grep-derived call list is not evidence of closure. The required range schema and theorem stack are in [End-to-end verification closure](../reference/end-to-end-closure.md).

## Decode data rather than copy it

Move and species data should not be manually rewritten as Lean constants. The preferred pattern is:

1. embed or otherwise cryptographically bind the canonical ROM;
2. derive symbol-addressed byte slices;
3. decode them into typed values;
4. prove encoding those values returns the original slice;
5. use decoded values in the high-level simulator.

For example, a move decoder reads six bytes and proves:

```lean
encodeMove (decodeMove rom addr hBounds) = rom.extract addr 6
```

A table theorem covers all 165 records and table length. Similar codecs cover type triples, stage ratios, trainer parties, base stats, growth data, AI pointers, and effect lists.

A Python generator may emit repetitive declarations, but generated output is not trusted merely because it was generated. Lean checks its byte certificate.

## Lift machine code into tractable units

Proving an entire battle as one instruction trace is not practical. The low-level semantics therefore supports symbol-addressed routines and checkpoints.

### Leaf routines

Start with routines that have small state footprints:

- `_Multiply` and `_Divide`;
- `CalcStat`;
- `BattleRandom` link update;
- `CalcHitChance`;
- `CriticalHitTest`;
- `CalculateDamage`;
- `RandomizeDamage`;
- simple effect handlers.

For each routine, prove a Hoare-style summary:

```lean
{ precondition ∧ projection M = x }
  execute ROM entry return M
{ projection M' = highLevelFn x ∧ frameCondition M M' }
```

The frame condition is as important as the returned value. It records preserved registers, unchanged projected memory, random responses consumed, and allowed scratch writes.

### Internal calls

A caller proof can use a proved callee summary instead of expanding every instruction. This is proof decomposition, not an unverified stub. The final theorem dependency graph must contain a proved summary or direct execution theorem for every semantic cut point.

### Presentation calls

Animation, text, audio, and HUD calls may be summarized to semantic events. A safe summary proves:

- no projected battle/caller field changes except a declared set;
- control returns normally under the modeled input acknowledgements;
- hardware-time/random observations and interrupts are threaded explicitly;
- bank/stack/register/flag return facts hold;
- VRAM/OAM/MMIO/external-SRAM effects needed later are retained;
- scratch aliases are restored or excluded from the checkpoint projection.

Until this theorem exists, a presentation function is an assumption and prevents an unqualified 1:1 claim.

## Checkpoint refinement instead of lockstep records

Machine instructions do not align one-to-one with high-level functions. The correct relation is stuttering refinement:

- the machine may take many instructions and presentation calls;
- the high-level model may take one phase transition;
- both stop at a checkpoint with related state and coupled remaining traces.

Suggested checkpoints are explicit `InitOpponent` entry, completed mode-specific loading, action selection, fixed actions, actor execution, completed move, completed residual, replacement, a witnessed `StartBattle` terminal edge, post-`EndOfBattle` cleanup, and the outer restored return.

The terminal edge includes its control-flow witness and moves the high-level machine into an `ending` phase. It is not final `done`: Pay Day, evolution cancellation/move learning, cleanup, restored caller fields, and bank/stack/carry return remain. `EndOfBattle` clears `wEscapedFromBattle`, mode, and opponent fields, while several terminal paths share raw result zero, so no final-WRAM-only decoder can recover every cause. Simultaneous active faint is ordering metadata and may be nonterminal when reserves exist. The epilogue is proved as a separate composition from the witnessed checkpoint.

The relation includes the current battle phase. This prevents a byte with two WRAM-union meanings from being decoded under the wrong interpretation.

## Prove trace coupling

State equality alone is too weak. Consider two simulators that produce the same current damage but one performs an extra mechanics-visible random call. Their next turn can diverge.

Raw suffix equality is not the right theorem: the ROM consumes divider/LCD/interrupt/joypad observations, while the high-level core consumes semantic actions and returned random bytes. In particular, presentation VBlanks execute extra `Random_` calls that intentionally have no one-for-one high-level request.

Define a coupling relation with two views:

1. the low-level hardware trace drives the ROM;
2. an instrumentation/projection records `(RandomSource, RandomSite, returnedByte)` when execution returns from a mechanics-visible `Random` or `BattleRandom` call and records committed semantic choices at action, naming, move-learning, and other menu cut points;
3. the high-level core consumes the projected ordinary responses and reproduces each cartridge perspective's deterministic link observations from its own link RNG state.

Every transition theorem proves equality of consumed **projected** requests and preservation of the coupling relation on the remaining low/high traces. It must also prove the sequence of source/site labels, not just returned values.

This catches:

- rejection-sampling shortcuts;
- accidental duplicated side-effect rolls;
- player/enemy asymmetries;
- link RNG desynchronization;
- menu, disobedience, or AI paths that consume a different random source;
- presentation branches such as HP-dependent recall text that shift the next hardware-derived result.

A separate hardware theorem proves that the recorded ordinary byte is the value computed by actual `Random_` execution from CPU flags, two `rDIV` reads, intervening VBlanks, and banked-call behavior. This prevents the instrumentation from becoming an unproved random oracle.

## Preserve undefined, malformed, and divergent behavior

There are three useful domains:

1. **Reachable canonical play:** states produced by the unmodified game under ordinary inputs.
2. **Battle-valid raw states:** states accepted by the battle engine, including glitch-oriented values.
3. **Arbitrary machine states:** needed by low-level instruction theorems but not all episode claims.

Theorems must state which domain they cover. Do not prove a convenient invariant for reachable play and then market it as an arbitrary-state equivalence result.

The episode reset domain also needs a named byte image. `InitBattleVariables` does not clear all volatile battle bytes and does not write normal/Old Man `wBattleType`; canonical calls rely on new-game or prior `EndOfBattle` cleanup plus caller writes. An RL reset harness must establish those bytes explicitly and prove that its image matches the chosen cartridge precondition.

The ROM can diverge in reachable or near-reachable edge cases, including a zero divisor in damage scaling and raw switch-recall state with `low8(maxHP / 4) = 0`. The semantics distinguishes:

- normal checkpoint;
- explicit witnessed terminal battle outcome;
- invalid external response;
- stuck/invalid machine state;
- observed cartridge divergence;
- proof-runner fuel exhaustion.

Fuel exhaustion is only an analysis limit. It is not evidence of cartridge divergence.

## Proof decomposition by subsystem

### Data fidelity

- move records and effect IDs;
- species/base stats and internal-to-Pokédex mapping;
- type table;
- trainer parties, exact class move-layer/action-AI tables, special moves, and source-expanded probability thresholds;
- growth and move learnsets;
- all 83 ordinary-item dispatch entries plus HM/TM and malformed-gap behavior.

### Arithmetic fidelity

- bit-vector operations and flags;
- big-endian multiplication/division scratch layout;
- stat and stage formulas;
- damage formula and caps;
- HP mutation and overkill;
- experience and BCD money paths.

### State-machine fidelity

- mechanics-visible action selection and action commit;
- move-menu cursor scratch, move reordering, and bag reordering;
- action legality, ineffective attempts, and turn consumption;
- order resolution;
- status-gate ordering;
- effect-dispatch ordering, unbound generated-charge identity plus PP/invulnerability state, and stat-modifier cross-stat flow;
- residual ordering;
- segmented switch codecs, partial send-out resets, deterministic enemy destination, faint/replacement, Shift-style behavior, and wild-faint slot-1-Speed escape;
- experience, nested move learning, capture naming/ordered box insertion, payout, and post-battle evolution;
- terminal control-path witness, `ending` requests, raw result fields, cleanup, and outer return.

### Relational fidelity

- phase-specific active/party synchronization plus distinct gain-EXP/fought-current-enemy participation bytes;
- player/enemy asymmetries;
- paired machine/link perspectives, conditional synchronization invariants, and per-perspective RNG lists/cursors;
- snapshot encode/decode and RL adapter behavior;
- explicit battle-driver versus overworld/cable/tutorial caller-integration boundaries.

## A useful first vertical theorem

The first end-to-end slice should avoid choosing a trivial theorem that does not test the architecture. A good target is:

- normal trainer or supplied wild battle;
- one living Pokémon per side;
- one ordinary damaging move each;
- no initial status or volatile flags;
- explicit random transcript;
- speed order, critical test, damage, STAB/type, accuracy, random factor, HP, residual checkpoint, and a witnessed faint terminal edge;
- no Pay Day/evolution eligibility, followed by cleanup, restored caller fields, carry, and outer return.

The first concrete fixture should be a supplied one-member wild battle that ends in one action and executes from `InitOpponent` to return. A generalized theorem can then quantify over bounded move/species data satisfying a “no additional effect” precondition. This exercises setup, ROM decoding, CPU/hardware routines, state projection, transcript consumption, terminal provenance, and epilogue composition in one slice instead of proving only a turn.

## Coverage is a proof artifact

A source inventory is not enough. The project needs a generated coverage report keyed by ROM ranges and symbols.

Each entry records:

```text
bank/start/end and symbol/source
kind: code | data | interrupt | presentation asset
reachable battle modes and predecessor edge
classification: direct | proved summary | proved presentation frame | caller boundary
high-level counterpart
theorem name
source hash
ROM hash
review status
```

CI rejects:

- an uncovered in-scope range;
- a theorem that references a stale source hash;
- a new reachable call outside the manifest;
- a “presentation-only” range that writes a projected field without updating its proof;
- a drop in move/effect/branch coverage.

The final “all battle mechanics” claim is the conjunction of the episode theorem and complete coverage manifest. The manifest must follow indirect edges through effect pointers, trainer AI tables, predefs, text-command callbacks, and banked jump helpers; a direct-call graph alone is unsound.

## Trusted computing base

The proof report must name, not hide, its trusted base.

Expected trusted components:

- Lean kernel and declared axioms used by the commit-pinned `sm83-lean` and other dependencies;
- the bytes of the canonical ROM identified by hash;
- selected console/SoC profile and hardware assumptions explicitly stated in the processor bus and Game Boy adapter;
- host file loading only insofar as artifact hashes are checked.

Not automatically trusted:

- Python extractors;
- informal assembly comments;
- the pokered wiki;
- an emulator used for differential tests;
- the native code generator or `#eval` output for theorem validity;
- RL serialization/FFI code unless covered by a Lean round-trip theorem.

The assembler is part of reproducing the binary from source, not part of the theorem once the exact ROM bytes are bound. Any source-level claim stronger than binary equivalence inherits RGBDS as a trust assumption.

## Testing around the proof

Formal proof and tests detect different mistakes.

Use tests for:

- bad hardware assumptions in the formal model;
- errors in extraction scripts;
- incorrect checkpoint discovery;
- performance regressions;
- FFI and serialization defects;
- comparison with real emulator traces.

Use proofs for:

- all-input arithmetic identities and bounds;
- codec round trips;
- routine summaries;
- state projection;
- transcript-preserving step refinement;
- generator legality;
- episode composition.

Required independent references include pinned gbdev opcode metadata/Pan Docs, all flat-bus SingleStep SM83 fixtures, profile-qualified Mooneye/Blargg ROMs, an accurate independently implemented emulator, and selected hardware evidence. They provide adversarial validation, not axioms. A `#eval` expression that prints `false` still builds, so demonstration output is never counted as a conformance gate.

## Auditing related Lean work

The sibling research checkout `gameboy-pokered-verify` contains valuable regression cases, but adoption requires this checklist:

| Question | Current observation |
|---|---|
| Is code reuse licensed? | No obvious root license file was present in the reviewed commit |
| Does it fetch/decode ROM instructions? | No; operations are called directly and there is no base/CB decoder or PC/cycle loop |
| Does `CPUState` include IME/interrupts/cycles/banking? | No; it has registers, pure memory, PC/SP, and a halt Boolean |
| Do `di` and `ei` change machine interrupt state? | They are explicit no-ops in the reviewed model |
| Does HALT wake or reproduce the HALT bug? | No; it only sets `halted := true` |
| Is memory bank-aware or timed? | No; memory is a pure total 16-bit-address function with region constants |
| Is stack bus ordering represented? | No; helpers produce final little-endian flat-memory state |
| Are DAA, RETI, signed-SP forms, STOP, and invalid lockup complete? | No |
| Do `#eval` examples enforce expected output? | No; they print Booleans and still compile if false |
| Are bug proofs connected to source bytes? | Mostly handwritten abstract functions; some compose direct operation helpers |
| Is there a battle transition theorem? | No |
| Are its results still useful? | Yes, as proof ideas and regression fixtures after clean-room/licensing review |

The project should retain source citations to those results if used, while independently proving the cartridge link required here.

## Claim discipline

Use the following labels in project reports:

- **Modeled:** a Lean function exists.
- **Tested:** selected traces agree with a reference.
- **Locally proved:** a theorem establishes a subsystem property.
- **ROM-linked:** a theorem connects a high-level function to decoded canonical machine code.
- **Transition verified:** a checkpoint step refines the ROM.
- **Episode verified:** finite terminating battle traces refine the ROM.
- **Coverage complete:** every in-scope range has a proved disposition.

Only the last two together with complete coverage justify the phrase “formally verified 1:1 battle simulator.”
