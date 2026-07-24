# Standalone SM83 semantics package

<!-- mode: reference -->

## Decision

The processor model should be a separate Lean package and repository, provisionally named **`sm83-lean`** with public library namespace `Sm83`. The Pokémon Red verifier consumes an immutable commit of that package as a Lake dependency. Exact decoder equations, ALU rules, logical M-cycle schedules, metadata dispositions, and theorem gates are in [SM83 implementation specification](sm83-implementation-spec.md). Physical fetch overlap, IDU/address pins, clock gates, and profile ownership are in [SM83 microarchitecture and system-boundary contract](sm83-microarchitecture-contract.md).

The split is semantic, not merely organizational:

```text
sm83-lean
  registers, flags, decode, instruction semantics
  cycle/bus protocol, IME, interrupts, HALT/STOP/lockup
  flat-bus instruction runner and processor proofs
             │ pinned Lake dependency
             ▼
pokered battle verifier
  Game Boy SoC and cartridge bus realization
  MBC3, ROM/VRAM/SRAM/WRAM/OAM/HRAM/MMIO
  timer/DIV, PPU, DMA, joypad, serial, audio
  canonical ROM, symbols, battle projection/refinement
```

`sm83-lean` must not import Pokémon data, Game Boy cartridge controllers, battle definitions, or the canonical ROM. Conversely, the battle verifier must not redefine processor instructions.

A third reusable Game Boy-system package may be extracted later, but it is not required to establish this boundary. Initially the SoC/cartridge adapter belongs to the Pokémon verifier because its required hardware slice is driven by the battle closure manifest.

## What “processor semantics” means

The package verifies execution of **opcode bytes**, not RGBDS source text. RGBDS macros, labels, sections, and conditional assembly have already disappeared by the time the processor fetches the canonical ROM.

The trusted path is:

```text
ROM byte fetch → base/CB decode → cycle-level execution → bus observations
```

An optional disassembler/pretty-printer may render normalized instructions for diagnostics. It is not a source-assembly interpreter and is not used to claim that RGBDS assembled a source line correctly. The canonical ROM hash remains the source-to-binary anchor.

## Hardware target policy

The core SM83 instruction set is reusable, but a complete console claim must name a hardware profile. Model/revision differences affect startup state, STOP, timing, DMA/PPU behavior, and some test expectations.

- `sm83-lean` defines architectural processor behavior and explicit profile hooks where behavior is not uniform.
- The first Pokémon theorem selects `DmgCpuBCommonBoot`; the evidence and instance parameters are fixed in [DMG-CPU B console profile](dmg-cpu-b-profile.md). DMG-CPU C and CGB are later claims.
- MGB, SGB/SGB2, CGB, and AGB execution are separate conformance/episode claims.
- The Red ROM contains no `stop` mnemonic in the reviewed source, but reusable processor completeness still requires a specified STOP transition.
- System-clock devices such as `DIV`, TIMA, LCD, DMA, serial, and audio are not silently folded into the CPU. They live in the Game Boy adapter and advance against the processor clock protocol.

The theorem report must not say only “runs on a Game Boy”; it names the selected profile and initial clock/device relation.

## Three related processor semantics

A single monolithic `CPUState → CPUState` function is inadequate for proof decomposition, fixture execution, and hardware execution. The package exposes three levels and proves their relationships.

### Functional instruction semantics

This level describes register/flag/PC/SP results and an ordered list of abstract bus transactions for one decoded instruction. It is useful for arithmetic lemmas and routine summaries.

It must retain:

- exact immediate-byte and PC consumption;
- conditional taken/untaken behavior and duration;
- ordered reads/writes, not only final memory equality;
- wrapping 8- and 16-bit arithmetic;
- all flag preservation/overwrite rules;
- normal completion, HALT, STOP, and invalid-opcode lockup.

### De-overlapped executable instruction semantics

This executable view attributes the opcode fetch and final writeback to one programmer-visible instruction. It drives the flat-memory corpus and leaf routine proofs. It is independent from the declarative relation, but it is not the canonical SoC pipeline.

### Physical clocked core semantics

This is the canonical executable processor model. IR already holds the executing opcode; the final microcycle normally fetches its successor while committing the current operation. Each M-cycle emits address drive, read/write/idle control, data direction, fetch provenance, IDU intent, register commit set, interrupt-poll kind, and clock intent with an exact four-CPU-T-cycle duration.

The Game Boy adapter supplies phase-indexed values and proves the corresponding `T1F`–`T4R` eight-half-edge/four-T-cycle expansion. Stable reads reduce to one byte; changing dynamic-bus reads use a temporal fold. Derived runners may stop at proved fetched-pipeline boundaries.

A cycle-count-only or de-overlapped instruction interpreter cannot be the final low-level theorem target. It loses prefetch/discard behavior, commit phase, idle address/IDU effects, stack/MMIO ordering, interrupt polling, DMA conflicts, and hardware-derived `rDIV` values.

### Required cross-level theorems

For a stable flat bus and legal instruction, the de-overlapped runner refines the declarative relation. For a well-formed fetched pipeline and a non-interrupting byte sequence, physical execution refines the de-overlapped program after reassociating overlapping fetches. DI/EI/RETI/HALT/STOP/lock and accepted interrupts use dedicated boundary relations.

This allows leaf proofs to use the functional view without disconnecting them from ROM execution. The three artifacts must be structurally independent enough that the theorems are not `rfl` over one shared executor.

## Core state

The processor-owned state includes at least:

```text
A B C D E H L
F as typed Z/N/H/C flags
SP, PC
IME and delayed-EI state
run mode: running | halted | stopped | locked
bootstrap/fetched-IR/decode/execute/interrupt microstate
IR byte, IR source address, valid bit, and CB-prefix latch
HALT-bug/prefetch-increment state
W/Z-style address/immediate, condition, ALU-carry, data, and IDU latches
M-cycle pin/commit/poll intent and unit-tagged CPU-T/M-cycle accounting
```

### Flags

Representing `F` as four booleans or a constrained nibble prevents arbitrary low bits from becoming architectural state. Provide proved codecs:

```text
encodeFlags : Flags → UInt8
decodeFlags : UInt8 → Flags
encodeFlags f &&& 0x0f = 0
```

`POP AF` masks the low nibble. Operations that preserve flags preserve the typed fields. Conformance adapters for external test vectors must account explicitly for fixtures that populate non-architectural low bits instead of weakening the invariant.

### Register pairs

`AF`, `BC`, `DE`, and `HL` use explicit high/low-byte codecs. Prove get-after-set, set-after-get, noninterference, and wrapping lemmas once. `AF` is not identical to an unconstrained 16-bit pair because of the flag nibble.

### No embedded total memory function

Memory is not a field `UInt16 → UInt8` in the canonical core state. Reads can be side-effecting and time-dependent; writes can change banking, DMA, serial, timers, or LCD state. The core instead communicates through a typed bus protocol.

A `FlatMemory` adapter remains useful for instruction proofs and public vectors. Its refinement theorem applies only under flat-memory assumptions.

## Bus and clock protocol

A minimal external protocol distinguishes:

```text
address drive even during idle
opcode/CB/operand/stack/vector/data read
write(address, value)
IDU increment/decrement source and destination
register/IR commit set
interrupt poll/acknowledgement phase
halt/stop clock-domain intent
```

Each M-cycle carries address, control, data direction/value, phase/duration, provenance, IDU intent, and poll/commit information. Responses have a shape compatible with the request. The physical transition is deterministic once the prior core state, valid response, and deterministic profile are fixed; unstable STOP profiles are explicitly relational.

The Game Boy adapter proves:

- fetched addresses select the correct fixed/switchable ROM byte;
- data accesses implement the mapped region and access restrictions;
- the processor pending-interrupt mask at each relevant microcycle corresponds to current `IE & IF`;
- interrupt acknowledgement/cancellation updates IF at the correct dispatch phase;
- devices advance by typed clock domains and speed/profile conversion in the declared ordering;
- HALT/STOP gate only the profile-appropriate domains rather than synthesizing ordinary idle cycles;
- DMA and LCD bus restrictions affect reads/writes at the correct phase;
- active access plus IDU/address intent suffices to derive profile-qualified OAM corruption.

This keeps MBC3 and MMIO out of the processor package while retaining enough timing to compose them soundly.

## Decoder domain

The decoder covers the entire byte space, not only opcodes currently seen in battle:

- 256 unprefixed byte values partition into 244 legal instructions, one `$CB` prefix, and 11 invalid lockup opcodes;
- all 256 `$CB xx` instructions are legal;
- legal instructions consume one, two, or three bytes as specified;
- immediates are little-endian where applicable;
- signed offsets are sign-extended only at their specified use sites.

The 11 invalid base opcodes are:

```text
D3 DB DD E3 E4 EB EC ED F4 FC FD
```

They are not generic “decode errors”. On the modeled hardware they enter a distinct locked state that does not wake like HALT.

Required decoder theorems include:

1. totality over every base byte and every CB second byte;
2. determinism;
3. the exact `244 + 1 + 11` base partition and 256-entry CB coverage;
4. instruction length bounds;
5. normalized `encode ∘ decode` byte round trip for legal instructions;
6. no wildcard fallback that maps an unknown byte to NOP;
7. fetched PC/byte consumption, including 16-bit wrapping;
8. agreement between pattern decoder and an independently represented frozen opcode catalogue.

If code generation is used, generated Lean is checked by these theorems and a pinned input hash. The generator is not trusted.

## Program and assembly-level semantics

The package also supplies a generic byte-program layer above single instructions:

```text
AtInstructionBoundary
StepInstruction
Runs / RunsFor / RunsUntil
ReturnsTo(returnPC)
Hoare-style pre/post/frame judgment
bus and control-flow trace projection
```

This layer still fetches bytes through the bus. It does not replace memory with a predecoded instruction list, because code can in principle execute from RAM, observe bank changes, wrap PC, or self-modify. A faster predecoded-ROM runner is admissible only with a theorem that the fetched code bytes are immutable and selected by the same bus mapping for the covered interval.

Addresses are numeric. Pokémon symbols, RGBDS labels, sections, macros, and bank conventions remain in the consumer. For example, `farcall` is proved by executing its emitted LD/CALL/Bankswitch byte sequence; it is not a primitive processor instruction.

Generic routine-summary infrastructure belongs in `sm83-lean`, while each Pokémon routine's precondition, return sentinel, projected memory frame, bank assumptions, and high-level function belong in the battle verifier. Dynamic `JP HL`, stack continuations, interrupt interleaving, and divergence remain explicit in the program relation.

## Instruction families and semantic edge cases

All 500 legal opcode entries require semantics, including memory operands and conditional timing. At minimum, review these failure-prone rules explicitly:

- `DAA` after both addition and subtraction, with N preserved, H cleared, and C conditionally set/preserved;
- `ADD SP,e8` and `LD HL,SP+e8` signed result but low-byte half-carry/carry rules;
- `ADD HL,r16` preserves Z while replacing N/H/C;
- `INC`/`DEC` preserve C;
- `BIT` preserves C, sets H, and clears N;
- accumulator rotates force Z to zero, unlike CB-prefixed rotate operations;
- `[HL]` CB operations have ordered read-modify-write cycles;
- `POP AF` masks flag low bits;
- pushes use an initial SP decrement, high-byte write plus second decrement, then low-byte write—exactly two decrements;
- pops read low byte before high byte while incrementing SP;
- `CALL`, `RST`, interrupt entry, `RET`, and `RETI` use exact return PC and stack order;
- conditional `JR`/`JP`/`CALL`/`RET` have distinct taken/untaken cycles;
- `LD [a16],SP` writes low then high bytes;
- `LDH` forms address `$FF00 + offset/C`;
- HLI/HLD use the original HL for the access, then wrap increment/decrement;
- every arithmetic/logic memory operand is read at execution time;
- PC/SP/address arithmetic wraps modulo 65536.

Pokémon Red reaches `DAA` through BCD money routines used by trainer payout and Pay Day. It also reaches `HALT`/`RETI` through `DelayFrame`/VBlank and serial handlers. These are not optional presentation details.

## Interrupt semantics

The package owns processor-side IME and interrupt-entry behavior. The system adapter supplies the pending mask and handles request latches.

Required behavior:

- `DI` disables IME and cancels a not-yet-effective enable as specified;
- `EI` uses a staged hardware latch/poll order rather than an immediate architectural write;
- `EI;DI`, `EI;NOP`, `EI;EI`, `EI;HALT`, rapid EI/DI, and RETI-with-pending have explicit physical sequence theorems;
- `RETI` restores PC and enables interrupts with its immediate semantics;
- servicing clears IME and normally chooses bit priority VBlank→LCD→Timer→Serial→Joypad;
- after discarding an accepted prefetch, interrupt entry consumes five M-cycles: ahead-PC correction, SP phase, high push, low push/vector resolution, and target fetch;
- request selection/acknowledgement is not one atomic event before both pushes: if the upper PC stack write targets `$FFFF` and changes IE, dispatch can be cancelled to `$0000` or retargeted to another priority; an IE write by the lower-byte push is too late to cancel the selected vector;
- cancellation leaves IME disabled and the original IF request set; retarget and lower-push cases acknowledge the selected request exactly as specified;
- nested interrupts occur only after an explicit re-enable;
- PC and stack behavior agree at 16-bit wrap boundaries.

An `ime : Bool` plus `ei : Bool` field is acceptable only if its transition relation proves these sequence properties. Naming a field does not establish the delay semantics.

## HALT, STOP, and lockup

These are three different states.

### HALT

- with IME enabled, the CPU waits and services a pending enabled interrupt before the next ordinary instruction;
- with IME disabled and no pending enabled interrupt, it waits, then wakes without servicing when one becomes pending;
- with IME disabled and an already pending enabled interrupt, the HALT bug suppresses the next normal PC increment/fetch behavior;
- HALT emits clock-gate/wake intent; the adapter progresses PPU/timer/wake domains while honoring profile-specific CPU-clocked DMA behavior;
- one-byte, multibyte, CB, RST, consecutive-HALT, and EI/HALT following-byte cases are theorem-indexed.

`DelayFrame` depends on HALT wake and VBlank `RETI`, so a boolean `halted` that never interacts with interrupts cannot execute the battle driver.

### STOP

STOP's prefetch/byte appearance, clock behavior, wake conditions, DIV reset, unstable interrupt case, and CGB speed switching are profile-sensitive. The package exposes all seven reviewed outcome classes through an explicit profile relation. The first DMG Pokémon driver closure proves STOP unreachable while the reusable release manifest labels profile coverage.

### Invalid lockup

An invalid opcode already in IR reaches no generic fetch state. Interrupts do not wake it. PC's prior fetch-side update and profile-qualified locked pin/clock behavior remain explicit. This outcome is distinct from an external-response error, HALT, STOP, cartridge-level loop divergence, and runner fuel exhaustion.

## Proposed package layout

```text
sm83-lean/
├── lakefile.toml
├── lean-toolchain
├── LICENSE
├── Sm83.lean
├── Sm83/
│   ├── Byte.lean
│   ├── Flags.lean
│   ├── Registers.lean
│   ├── Instruction.lean
│   ├── Decode.lean
│   ├── Encode.lean
│   ├── Alu.lean
│   ├── Functional.lean
│   ├── InstructionRunner.lean
│   ├── Bus.lean
│   ├── IDU.lean
│   ├── Clock.lean
│   ├── CoreState.lean
│   ├── Pipeline.lean
│   ├── Cycle.lean
│   ├── Interrupt.lean
│   ├── Run.lean
│   ├── Program.lean
│   ├── Hoare.lean
│   ├── FlatMemory.lean
│   ├── Profile.lean
│   ├── Proofs/
│   │   ├── Decode.lean
│   │   ├── Flags.lean
│   │   ├── Arithmetic.lean
│   │   ├── Frames.lean
│   │   ├── Interrupt.lean
│   │   ├── Pipeline.lean
│   │   └── SemanticLayers.lean
│   └── Testing/                  # not imported by the proof-facing root
│       ├── OpcodeVectors.lean
│       └── TraceFormat.lean
├── Tests/
└── tools/
```

Exact filenames may change, but dependency direction may not: proof-facing modules cannot import Pokémon or test-only parsers.

## Public API contract

The package should stabilize these concepts rather than expose internal microcode constructors:

```text
decodeBase / decodeCB
decodeAt over a read-only byte source
declarative InstrRel and de-overlapped instrStep
CoreState, CycleIntent, CoreInput, CoreOutput, PipelineWellFormed
stepMachineCycle
runMachineCycles / runProjectedInstruction / runUntilFetchedBoundary
Runs/ReturnsTo and generic Hoare/frame judgments over fetched byte programs
FlatMemory adapter
architectural projection
physical-pin, IDU, active-bus, and de-overlapped trace projections
legal/locked result classification
```

The Pokémon adapter imports only this API plus proved lemmas. Internal cycle-state representation can evolve without forcing battle-proof rewrites.

## Processor proof obligations

### Representation

- flag low nibble always encodes as zero;
- register-pair codecs and AF masking;
- architectural projection hides only proved internal latches;
- every transition preserves core well-formedness.

### ALU

- exact result and Z/N/H/C equations for every arithmetic/logic family;
- exhaustive `DAA` characterization over 2048 relevant A/N/H/C inputs, old-Z irrelevance, and all 4096 pinned A/ZNHC rows;
- signed-SP instruction flags;
- rotate/shift and bit-index bounds;
- no unaffected register/flag mutation.

### Decode and control

- complete byte partition and round trips;
- exact PC and instruction length;
- exact taken/untaken control flow;
- stack byte order and frame properties;
- invalid-opcode lockup.

### Pipeline and clocked execution

- deterministic valid-response transition except explicitly relational unstable STOP outcomes;
- bootstrap and fetched-boundary `PipelineWellFormed` preservation;
- exact T/M-cycle counts, address/control/data, IDU, commit, and poll intent for all 101 normal families;
- declarative/de-overlapped refinement and physical/de-overlapped sequence refinement with fetch reassociation;
- interrupt priority/five-cycle entry, mid-dispatch IE-write cancellation/retargeting, staged EI, DI suppression, RETI, HALT bug, wake, and following-byte theorems;
- clock-gate intent separates CPU M-cycles from Game Boy dots/device domains;
- run-until result separates fetched boundary, halt/stop/lock, invalid response, and fuel exhaustion.

### Program logic

- fetched-boundary and projected-instruction composition and transitivity of `Runs`;
- soundness of executable `runUntil` relative to the relational semantics;
- return-sentinel/call-stack lemmas distinguishing not-fetched, prefetched, and in-IR sentinel states;
- frame-rule composition for generic bus regions;
- predecoded immutable-code optimization only through a fetch-equivalence theorem;
- fuel exhaustion distinct from semantic nontermination and processor lockup.

### Reuse safety

- no Pokémon constants in theorem assumptions;
- no theorem depends on test-only modules;
- `#print axioms`/equivalent audit for public theorem roots;
- no `sorry`, `admit`, or unreviewed axioms;
- deterministic serialization for processor fixtures if snapshots are exposed.

## Validation corpus

Tests challenge the specification but do not prove that the specification matches silicon.

| Source | Pinned commit observed in this audit | Use | Limitation |
|---|---|---|---|
| Pan Docs | `fe246067b695b5404a4a6a47efb4fd6d921ececb` | Instruction organization, interrupts, HALT/STOP and OAM/IDU behavior | Informal reference, CC0 |
| `gbdev/gb-opcodes` | `376f61c86fdac2048f7ce5fe838ae756b306017e` | Locally cloned 256+256 opcode metadata cross-check; audited by `tools/audit-gb-opcodes.py` | Display-oriented `immediate`/F8 fields and disputed STOP/PREFIX control rows are not semantics, CC0 |
| `SingleStepTests/sm83` | `f9c30210245dd691661db39f5ace022c465ecc2f` | 244 base + 256 CB JSON files, 1000 fixtures each, de-overlapped active-bus/pre-post comparison | Flat RAM; idle pins and IE/IME are non-authoritative; HALT/STOP are placeholders; MIT |
| `Gekkio/mooneye-test-suite` | `31510e12eea6286d36eea060a6adde755e1067aa` | Hardware-run interrupt/HALT/timing/DAA/DMA/timer integration ROMs | Primarily system-adapter validation, model/revision-specific; MIT |
| `Gekkio/gb-ctr` | `d164e64678841d2e4d768850810a89d0b9964187` | 105 categories, 101 normal microtimings, fetch overlap and clock edges | Documentation reference; CC BY-SA 4.0, so cite rather than copy |
| Game Boy CPU internals gist | `8efa6645473411e78dd917169141c16c0d306ce1` | Decode-ROM-derived IR/IDU/fetch/ISR cross-check | No explicit license observed; factual citation only |
| SameBoy | `213a12ce93d66b105a113debd9396306066a7cfc` | DMG-B differential instruction/system traces | STOP/IF/OAM TODO paths quarantined; testing oracle, not theorem premise; Expat |
| `Gekkio/gb-research` | `59088f486f579a69fd86bd86a55181b937e769e0` | Die-derived DMG-B-equivalent HDL waveform oracle | Medium abstraction, no propagation delays; MIT or Apache-2.0 code |
| GBMicrotest | `463eb6bc0fe31d61781ef63060ad6d74090c0255` | 513 minimal real-hardware fixtures | README's exact hardware revision is uncertain; MIT |
| physical hardware traces | procedure fixed; fixture corpus pending | Resolve disputed/model/instance-specific behavior | Every deterministic claim requires hashed fixture-qualified captures |

The SingleStep corpus currently contains 500 JSON files: 244 legal non-CB base opcodes and 256 CB opcodes. The absent base slots are the CB prefix itself and the 11 invalid opcodes. This gives 500,000 generated instruction cases at 1000 cases per file. CI should stream or shard them rather than elaborate half a million theorem declarations. Its README describes the vectors as M-state-oriented and emulator-generated. The exhaustive audit finds 16 signal shapes, non-authoritative IE/IME schema, convenience idle pin values, and three-cycle HALT/STOP placeholders. Disagreements require adjudication rather than changing the theorem automatically.

Cycle units must be normalized explicitly: RGBDS documentation commonly reports 1 MHz machine cycles, while gb-opcodes metadata uses 4 MHz clock counts such as 4 for a one-M-cycle NOP. A checker that compares the integers without a unit type can be consistently wrong.

Mooneye tests belong mostly in the Game Boy adapter's CI because they exercise IF/IE, timers, DMA, PPU, and model-specific hardware. Processor-only tests use the flat-bus runner and dedicated interrupt-port fixtures.

Recommended validation layers:

1. Lean unit theorems for edge cases and exhaustive finite ALU properties;
2. executable check of all pinned SingleStep normal-instruction fixtures through the de-overlapped runner, with HALT/STOP quarantined;
3. decoder metadata comparison against pinned gb-opcodes plus the microarchitecture and DMG-B profile-source audits;
4. physical/de-overlapped sequence-refinement and 101-family IDU/address/commit coverage reports;
5. Blargg/mooneye/GBMicrotest ROM execution in the Game Boy adapter, including all 4096 DAA rows, `interrupts/ie_push`, HALT, OAM/DMA, and clock-domain tests;
6. differential traces against pinned SameBoy outside its quarantine and `gb-research` HDL on supported digital paths;
7. fixture-qualified hardware captures for ambiguous profile behavior.

A printed `#eval` result is not a CI assertion. A false Boolean printed by `#eval` still allows the module to compile. Executable fixture checkers must exit nonzero on mismatch, and universal properties intended as proof obligations must be theorems.

## Audit of existing Lean prior art

At `vicgalle/gameboy-pokered-verify` commit `aa9b95b87b82210464a24e849026722c425c7be2`, the `SM83` directory is useful proof-oriented prior art but not a reusable processor implementation for this project.

| Area | Reviewed behavior | Gap |
|---|---|---|
| State | A/F/B/C/D/E/H/L, SP, PC, total memory function, `halted` Bool | No IME/delayed EI, interrupt state, cycles, fetch/decode microstate, STOP/lockup |
| Decode | None | No opcode fetch, base/CB decoder, length, invalid classification, or PC discipline |
| Arithmetic/logic | Direct helper functions for a subset of operation families | Not integrated into all operand/opcode forms; DAA and several families absent |
| Memory | Pure total map and final-state stack helpers | No side-effecting/timed reads, bank/MMIO behavior, or observable stack bus order |
| Control | Helpers assume caller supplies target/current PC convention | `di`/`ei` are explicit no-ops; no RETI/interrupt entry/HALT bug |
| Timing | None | Cannot drive DIV, VBlank, serial, DMA, or conditional cycles |
| Validation | `#eval` demonstrations plus algebraic theorems | `#eval` expected comments do not fail when false; no decoder/corpus/system conformance |
| ROM linkage | Bug snippets translated manually | No execution of canonical ROM bytes |

Specific semantic concerns:

- `CPUState` permits arbitrary low bits in F; only selected constructors and `POP AF` normalize them.
- `pushStack` writes the final little-endian pair in one functional update. Its final flat-memory state matches a push, but it cannot express high-byte-then-low-byte bus order.
- arithmetic/control helpers generally do not consume opcode/immediate bytes or update PC/cycles.
- `halt` only sets a Boolean; no wake, interrupt service, or HALT bug follows.
- memory reads cannot produce MMIO side effects or time-dependent values.

The package should therefore be implemented cleanly after licensing is settled, using the old theorems as regression ideas rather than importing its state wholesale.

## Dependency and release policy

The Pokémon repository pins an immutable `sm83-lean` commit in Lake configuration and checks the resolved revision in CI. It must not follow `main`.

Each processor release records:

- Lean toolchain version;
- package commit/tag;
- opcode catalogue and test-corpus commits/hashes;
- supported hardware profiles;
- theorem/axiom audit;
- decoder and 101-family physical microstate/IDU/commit coverage reports;
- semantic-layer refinement, conformance totals, profile hooks, and known deviations;
- public API compatibility notes.

The processor package gets its own CI. Pokémon CI then runs a smaller dependency smoke test plus Game Boy integration/ROM proofs. A processor change cannot be accepted solely because battle tests still pass.

The new package needs an explicit root license before code is published. Existing `gameboy-pokered-verify` and the reviewed CPU-internals gist have no obvious license at their pinned commits, so no source should be copied without permission. Pan Docs/gb-opcodes are CC0; SingleStep, Mooneye, and GBMicrotest are MIT; `gb-research` HDL is MIT or Apache-2.0; SameBoy is Expat; GB Complete Technical Reference is CC BY-SA 4.0 and should initially be cited rather than copied. IceBoy web measurements are factual citations only because no page license was inferred.

## Completion gates

The standalone processor package is ready to serve as a proof dependency only when:

- all 256 base bytes and 256 CB bytes have explicit classification;
- all 500 legal opcode entries execute through declarative, de-overlapped, and physical semantics with explicit exceptional control relations;
- all 11 invalid opcodes enter proved lockup behavior;
- decoder, flags, stack, pipeline/bootstrap, timing, IDU/address, interrupt, EI/DI/RETI, HALT/STOP/lock, and cross-level theorems compile;
- full pinned flat-bus corpus is processed with documented HALT/STOP dispositions, and all normal-instruction comparisons pass;
- all required interrupt/HALT following-byte sequences and 4096 DAA rows pass;
- profile manifests label T1F–T4R, read-fold/write windows, clock gates, STOP, locked pins, and fixture/family-qualified OAM coverage rather than silently assuming it;
- public theorem roots pass the axiom/sorry audit;
- its API has no Pokémon/Game Boy-cartridge dependency;
- the Pokémon Game Boy adapter proves its bus/interrupt composition obligations;
- a decoded canonical ROM leaf routine executes through the dependency and refines its high-level summary.

Passing processor tests alone does not verify Pokémon Red. Conversely, no battle theorem may bypass the package with handwritten instruction semantics.
