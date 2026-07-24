# SM83 microarchitecture and system-boundary contract

<!-- mode: reference -->

## Purpose

The opcode-level specification is necessary but not sufficient for canonical Game Boy execution. This document closes the remaining implementation dimensions between “an instruction produced the right final registers” and “the SM83 core generated the right cycle-by-cycle interaction with a named Game Boy SoC.”

It specifies the canonical pipeline state, fetch/execute overlap, internal latches, address/IDU observables, interrupt polling order, HALT/STOP/lock behavior, clock domains, system ownership, and the refinement boundary to de-overlapped instruction semantics.

The complete opcode equations remain in [SM83 implementation specification](sm83-implementation-spec.md). The package boundary remains in [Standalone SM83 semantics package](sm83-semantics-package.md).

## Exhaustiveness criterion

The processor implementation space is partitioned across these dimensions:

| Dimension | Required disposition |
|---|---|
| Decode | Every base and CB byte has exactly one legal, prefix, STOP/HALT, or lock result |
| Architectural state | Every register, flag, PC/SP, IME state, run mode, and wraparound is represented |
| Internal state | IR, W/Z-style latches, condition latch, decode state, prefix latch, and IDU state are represented when they affect later cycles |
| Data path | Every ALU, rotate, shift, bit, pair, stack, immediate, and writeback operation has exact equations and commit phase |
| External bus | Address drive, read/write/idle control, write data, read sample, and opcode-fetch provenance are explicit each M-cycle |
| Pipeline | Bootstrap, generic prefetch, fetch/execute overlap, discarded prefetch, CB continuity, and instruction-boundary projection are explicit |
| Interrupts | IME latch delay, DI suppression, RETI, polling, priority, acknowledgement, five-cycle entry, cancellation, and retargeting are explicit |
| Power/control | HALT entry/wake/bug, STOP outcome, invalid-opcode lock, and clock gating are explicit |
| Time | CPU T-cycles, M-cycles, system dots, speed mode, and gated clock domains are distinct |
| SoC effects | IE/IF, OAM corruption, DMA contention, timers, LCD, joypad, serial, and cartridge response have named owners |
| Initialization | Reset/IR seed, bootstrap fetch, and any supplied mid-pipeline checkpoint have explicit preconditions |
| External core pins | Reset, WAKE, maskable interrupt, optional NMI, and bus-grant/contention inputs have a modeled or tied-off disposition |
| Validation | Each claim is a theorem, exact-hash source fact, executable fixture check, profile assumption, or documented unknown |
| Divergence | HALT wait, STOP wait, lockup, invalid bus response, timeout, and analysis fuel are distinct |

A release cannot call itself “complete SM83 semantics” while silently collapsing any row to an ordinary instruction step.

## Pinned microarchitecture evidence

Run the finite source audit with:

```sh
python3 tools/audit-sm83-sources.py \
  --pandocs-root /tmp/pandocs \
  --gb-ctr-root /tmp/gb-ctr \
  --single-step-root /tmp/sm83-tests \
  --mooneye-root /tmp/mooneye-test-suite \
  --cpu-internals-root /tmp/gameboy-cpu-internals
```

| Source | Commit | Checked role | License/reuse disposition |
|---|---|---|---|
| Pan Docs | `fe246067b695b5404a4a6a47efb4fd6d921ececb` | decode, interrupts, HALT, STOP decision tree, OAM corruption | CC0 |
| GB Complete Technical Reference | `d164e64678841d2e4d768850810a89d0b9964187` | 256+256 category map, 101 normal-family microtimings, fetch overlap, clock edges | CC BY-SA 4.0; cite facts, do not copy implementation text into a differently licensed package |
| SingleStepTests/sm83 | `f9c30210245dd691661db39f5ace022c465ecc2f` | de-overlapped flat-memory state and active bus transactions | MIT; generated from Ares and not authoritative for IE/IME or HALT/STOP |
| Mooneye | `31510e12eea6286d36eea060a6adde755e1067aa` | hardware-observed DAA, interrupt, EI/DI, HALT, stack, timer, DMA, and PPU behavior | MIT |
| Game Boy CPU internals gist | `8efa6645473411e78dd917169141c16c0d306ce1` | decode-ROM-derived IR pipeline, IDU, ISR, HALT, STOP, and family microstates | no explicit license observed; factual citation only, no code/text copying |

GB CTR's HALT and STOP sections are TODOs and some internal signed-SP annotations are tentative, so its 101 normal timing lanes are cross-check evidence rather than generated semantics. The CPU-internals note likewise identifies HALT/STOP/interrupt power-state nuances as difficult. Neither source is silently promoted to a theorem premise. The subsequent [DMG-CPU B profile contract](dmg-cpu-b-profile.md) pins die-derived HDL, measured bus pages, SameBoy, GBMicrotest, and the first console profile.

The audit pins 22 source hashes. Notable identities include:

| Artifact | SHA-256 |
|---|---|
| `gb-ctr/opcodes.toml` | `c6fdbf62efdceb083adffe61dd22f762a1baba5f3f3a239da930537379f19d86` |
| `gb-ctr/chapter/cpu/instruction-set.typ` | `31c419f149b594ca47d53f6fb301310f54fa5ee7a035d0632b057a4f98c38e6d` |
| `gb-ctr/chapter/cpu/timing.typ` | `0a1914e9fd34961b2666809b75a25bdfee187f03537edee17d00efd5d4d1321f` |
| `pandocs/src/OAM_Corruption_Bug.md` | `342423fad4fcc868f614a9b2b25aa1e0067cd50e8a2aa6fd3c55a0973b44a09b` |
| Pan Docs STOP decision source | `a0ab07ee43351863ffc1aefd1e386673930e436e7e63deb338d47caa6e66b562` |
| Mooneye exhaustive DAA source | `37341fe47cd19b36a2b8f0b041dd6213dc1d7952fc89f70399bc59112426508a` |
| Mooneye `interrupts/ie_push` | `2f33ed6af272f0e5945277d654882b5c48df7d336e95f3cefdd6ad49a46025d3` |
| CPU internals `DMGCPU.MD` | `4cb192b351ee77707103c754accd8b71460eac19ce845caaa543d4c521357d26` |

## Ownership boundary

The split is behavioral, not merely a module naming convention.

| Concern | Processor package | Game Boy adapter |
|---|---|---|
| IR/decode state and CPU registers | owns | observes through projection |
| Address, data, read/write, fetch, and IDU intent | emits | consumes |
| Read value | folds phase-indexed drive into its dynamic read latch | resolves mapped device/bus contention at T1F–T4R half edges and proves stable-read reduction |
| IE/IF storage and software writes | accesses through port | owns mapped latches and collision rules |
| IME and EI delay | owns | cannot patch |
| Interrupt priority/entry sequencing | owns resampling and CPU control | supplies pending mask and commits IF acknowledgement |
| OAM corruption trigger | emits active access plus IDU intent/provenance | owns fixture- or instance-family-qualified corruption relation and PPU row |
| DMA/PPU/cartridge bus conflicts | no device knowledge | owns |
| HALT/STOP clock request | emits run/clock intent | advances only the profile-appropriate clock domains |
| CGB speed state and dots-per-M-cycle | parameter/port input only | owns |
| Reset/IR seed and optional NMI pin | exposes generic/profile hook | owns console reset image and proves unwired inputs tied inactive |
| Boot ROM and post-boot register image | generic reset hook only | owns console profile and boot proof |
| Pokémon ROM/data/banks | forbidden | owns |

The Pokémon project must not infer an omitted CPU event. The processor package must not import OAM, MBC3, Pokémon, or a specific memory map.

## Two timing views

### Canonical physical pipeline

The canonical executable core models fetch/execute overlap. The instruction register already contains the instruction being executed; its final microcycle normally fetches the following opcode. PC therefore ordinarily identifies the next fetch address rather than the byte currently in IR.

Minimum pipeline state:

```text
irValid and irByte
irAddress
cbPrefixLatched
decodeState or microPC
W and Z temporary bytes
conditionLatch
aluCarryLatch and temporary data
iduInput, iduDirection, iduDestination
prefetchAddress and whether its increment is suppressed
ime and eiLatchPipeline
runMode
```

A generic fetch:

1. drives the fetch address through the IDU/address path;
2. performs a bus read marked as opcode fetch;
3. normally increments the selected PC source;
4. samples interrupt eligibility at the specified phase;
5. either latches the fetched byte into IR or discards it for interrupt dispatch.

The exact internal names need not mimic die labels, but the state cannot be removed if it changes an address, value, interrupt decision, OAM trigger, or future control transition.

### De-overlapped instruction projection

Programmer tables and SingleStep attribute the current opcode fetch to the current instruction and move its register writeback to that instruction's end. This projection is useful for ALU theorems and flat-memory tests, but it is not the canonical SoC execution relation.

The refinement theorem must account for a one-fetch pipeline shift:

- a physical bootstrap fetch fills IR before useful execution;
- the final fetch of instruction `i` overlaps its final writeback and obtains instruction `i+1`;
- an interrupted fetch is discarded and its address becomes the return PC;
- DI, EI, RETI, HALT, STOP, JP HL, and lockup have explicit exceptional rules;
- a finite one-instruction SingleStep trace cannot establish physical writeback phase or prefetch behavior.

For an ordinary logical schedule

```text
[F_current, e1, ..., eN]
```

the physical execution from `IR = current` has the same programmer duration and the bus-control sequence

```text
[e1, ..., eN, F_successor]
```

with current writeback assigned to its specified physical cycle, often the final successor fetch. CB follows the same shift: logical `[F_prefix, CB_subopcode, tail...]` becomes physical `[CB_subopcode, tail..., F_successor]`. Control flow determines the successor-fetch address; JP HL is the one-cycle case whose physical cycle fetches at old HL and leaves pipeline PC at old HL plus one. DI may suppress polling on that fetch, and interrupt acceptance may discard it.

The theorem compares whole instruction sequences with a boundary relation, not one isolated fixture by `rfl`.

## Initialization and checkpoints

The package exposes two entry forms:

1. **cold/reset entry** with profile-provided PC/register/IR seed; a synthetic invalid-IR bootstrap is allowed only through a theorem relating it to the hardware's initial dummy/NOP fetch behavior;
2. **fetched boundary entry** with valid IR, its source address, next PC, prefix state, and all hidden latches satisfying `PipelineWellFormed`.

The package's default claim is the Game Boy SM83 embedding. If a generic Sharp-core NMI pin is represented, the Game Boy adapter proves it permanently inactive; if it is omitted, the release must not claim arbitrary SM83 SoC compatibility. Reset assertion during running/HALT/STOP/lock similarly belongs to a profile transition rather than an ad hoc state overwrite.

A ROM routine theorem beginning at a symbol cannot supply only `PC = symbol`. It must either:

- begin before the caller's transfer and naturally fetch the callee opcode; or
- use a proved checkpoint that includes IR/prefetch state and relates it to the symbol.

Return-sentinel reasoning similarly distinguishes “sentinel address is the next fetch” from “sentinel opcode is already in IR.”

## M-cycle and pin protocol

One CPU M-cycle contains four CPU T-cycles. The executable output is richer than `read`, `write`, or `idle`:

```text
CycleIntent:
  addressDrive
  busControl = read | write | idle
  writeData or highImpedance
  readSampleRequired
  fetchKind = none | opcode | cbOpcode | operand | stack | data | vector
  iduIntent = none | increment(source,destination) | decrement(source,destination)
  registerCommitSet
  interruptPollKind
  clockIntent
```

Even an idle cycle may drive an address and perform an IDU operation. SingleStep's `---` token means no read/write request; its retained address/data values are convenience values and do not validate real idle pins.

The system response supplies:

```text
readData when requested
pendingMask sample
acknowledgement result
clock/profile inputs
bus validity or contention disposition
```

A response must match the request shape. There is no generic arbitrary-latency WAIT state unless a selected SM83 embedding proves one exists.

### Four-T-cycle expansion

The Game Boy adapter refines each M-cycle through named edges:

```text
T1R T1F T2R T2F T3R T3F T4R T4F
```

The adapter contract fixes, per bus operation and profile:

- address/control launch and stability;
- data-drive window for writes;
- read sample edge;
- MMIO write commit edge;
- interrupt-line sample edge;
- register/IR/IME commit edge;
- device progression before and after those edges.

Until those edges are selected and validated, an M-cycle implementation can claim instruction-level and M-boundary correctness, but not pin-level or dot-exact SoC correctness.

## Clock domains

Do not use one undifferentiated `cycles : Nat`.

| Unit/domain | Meaning |
|---|---|
| CPU T-cycle | one CPU system-clock period |
| CPU M-cycle | exactly four CPU T-cycles |
| PPU dot | display-domain progression unit |
| oscillator/master edge | profile clock source edge |
| serial external edge | independent cable clock input when externally clocked |
| cartridge RTC edge | independent cartridge oscillator input |

For Game Boy normal speed there are four dots per CPU M-cycle; CGB double speed has two dots per CPU M-cycle. That conversion belongs to the SoC adapter, not the instruction catalogue.

HALT and STOP are clock-gating states, not merely repeated idle instructions:

- HALT leaves enough system activity to create a wake request, but not every CPU-clocked subsystem is equivalent to normal idle execution;
- Mooneye's MGB HALT/OAM-DMA test observes a DMA access held rather than progressing while the PPU continues;
- STOP can reset/freeze DIV and stop or change different domains depending on outcome/profile;
- the adapter exposes a clock-domain mask for each transition.

Therefore the old shortcut “halted cycles advance all devices” is forbidden.

## Micro-operation obligations

The logical bus schedules in the opcode specification are retained as an architectural projection. The physical microprogram additionally proves, for every one of the 101 detailed normal families:

- exact IR/decode state path;
- active bus address and data source;
- W/Z and condition-latch updates;
- IDU source, direction, destination, and address drive;
- ALU inputs, carry path, and flag commit;
- architectural register commit cycle;
- generic-fetch target and PC result;
- whether interrupt polling is enabled on that fetch.

The 105 GB CTR categories comprise 101 detailed normal families plus CB-prefix control, HALT, STOP, and undefined control. The latter four require dedicated state machines rather than ordinary family timing.

### Normalized physical templates

The source audit assigns each of the 101 detailed normal categories to exactly one of 33 normalized templates, with no duplicate or uncovered category. These templates are read from a state where the current opcode is already in IR. `GF(x)` means generic successor fetch at address `x`, including the normal IDU update and interrupt poll. `commit` names architectural writeback in that cycle.

| Logical family | Physical cycles from fetched IR |
|---|---|
| one-cycle register/ALU/flag/NOP | `GF(PC)` plus current operation commit |
| DI | `GF(PC)` plus DI commit, with poll suppressed |
| EI | `GF(PC)` plus staged EI-latch transition |
| register load from `[HL]` or ALU `[HL]` | read old HL; `GF(PC)` plus destination/ALU commit |
| register store to `[HL]` | write old HL; `GF(PC)` |
| INC/DEC `[HL]` | read old HL and compute; write same HL; `GF(PC)` plus flags commit |
| 8-bit immediate register/ALU | read PC with PC increment; `GF(PC)` plus destination/ALU commit |
| immediate store `[HL]` | read PC with PC increment; write old HL; `GF(PC)` |
| 16-bit immediate load | read low at PC+; read high at PC+; `GF(PC)` plus pair commit |
| BC/DE memory load/store | active read/write at old pair; `GF(PC)` plus load commit if applicable |
| HLI/HLD load/store | active access at old HL plus same-cycle HL IDU update; `GF(PC)` plus load commit |
| INC/DEC 16-bit pair | idle with pair IDU update/address drive; `GF(PC)` |
| ADD HL,pair | idle low-half ALU; `GF(PC)` plus high-half/HL/flags commit |
| LD SP,HL | idle SP commit/address drive; `GF(PC)` |
| LD `[a16]`,SP | low immediate PC+; high immediate PC+; low-SP write plus WZ increment; high-SP write; `GF(PC)` |
| absolute A load/store | low immediate PC+; high immediate PC+; active WZ access; `GF(PC)` plus load commit |
| LDH immediate load/store | immediate PC+; active `$FF00 + imm` access; `GF(PC)` plus load commit |
| LDH C load/store | active `$FF00 + C` access; `GF(PC)` plus load commit |
| LD HL,SP+e8 | offset PC+; low-half internal ALU; `GF(PC)` plus high-half/HL/flags commit |
| ADD SP,e8 | offset PC+; low-half internal ALU; high-half/internal transfer; `GF(PC)` plus SP/flags commit |
| JR taken | offset PC+; relative low/high adjustment with IDU intent; `GF(target)` |
| JR untaken | offset PC+; `GF(PC)` |
| JP taken/unconditional | low PC+; high PC+; internal target transfer; `GF(target)` |
| JP untaken | low PC+; high PC+; `GF(PC)` |
| JP HL | `GF(old HL)` and pipeline PC becomes old HL plus one |
| PUSH | initial SP IDU decrement; high write at SP plus second decrement; low write; `GF(PC)` |
| CALL taken | low PC+; high PC+; initial SP decrement; high return write plus second decrement; low return write plus target transfer; `GF(target)` |
| CALL untaken | low PC+; high PC+; `GF(PC)` |
| RST | initial SP decrement; high return write plus second decrement; low return write plus fixed-vector transfer; `GF(vector)` |
| POP | low read at SP plus increment; high read at SP plus increment; `GF(PC)` plus pair commit |
| RET/RETI | low stack read plus SP increment; high read plus SP increment; internal PC transfer and RETI enable if applicable; `GF(target)` |
| conditional RET untaken | condition-only idle cycle; `GF(PC)` |
| conditional RET taken | condition-only idle; low/high stack reads with increments; internal PC transfer; `GF(target)` |
| CB register operation | fetch/latch CB subopcode without ordinary poll; `GF(PC)` plus operation commit |
| CB BIT `[HL]` | fetch CB subopcode; read old HL; `GF(PC)` plus flag commit |
| CB memory RMW | fetch CB subopcode; read old HL/compute; write same HL; `GF(PC)` plus flags where applicable |

Every PC+, SP+, SP−, HL+/HL−, and WZ+ occurrence emits IDU/address intent plus micro-op provenance. Emission does not imply that all apparently similar updates produce the same SoC corruption pulse: the adapter uses the exact phase/provenance, including the observed POP/RET second-read exception. A template is instantiated by finite register/condition/ALU/bit indices; no opcode can fall through to a generic “other” path.

### Ordering cases requiring named theorems

| Case | Required property |
|---|---|
| `LD H,[HL]` and `LD L,[HL]` | address uses old HL; destination commits only after read |
| HLI/HLD | memory access and IDU update share the documented cycle and use pre-update HL |
| `LD [a16],SP` | low write first; address-latch increment is visible to IDU/system logic |
| `ADD HL,HL` | both source halves are old HL; low carry feeds high operation |
| `ADD SP,e8` | low and high internal operations plus final SP transfer are distinct |
| `LD HL,SP+e8` | writes H/L, never SP; shorter final transfer than ADD SP |
| POP/RET | low then high reads; SP post-increments and destination/PC commits afterward |
| PUSH/CALL/RST | initial SP decrement cycle, high write, second decrement/low write, then target fetch |
| conditional RET | condition-only cycle exists even when not taken |
| conditional JP/CALL/JR | immediate bytes are fetched before the taken path diverges |
| JP HL | next opcode is fetched from old HL through the fetch/IDU path; PC becomes HL plus one in pipeline representation |
| CB memory RMW | read result is latched, transformed, and written to the original HL address |
| BIT `[HL]` | reads but never writes |
| DI/EI/RETI | IME phase order is stated separately from final architectural value |

## Address drive, IDU, and OAM corruption

An `idle` cycle cannot erase address-bus behavior. On affected monochrome SoCs, the 16-bit IDU is tied to the address path. When its old value lies in `$FE00`–`$FEFF` during PPU mode 2—including the unusable `$FEA0`–`$FEFF` range—even an operation without asserted read/write can trigger OAM corruption.

The core must emit IDU intent for at least:

- ordinary PC post-increment fetches;
- suppressed HALT fetch increment;
- `INC/DEC BC,DE,HL,SP`;
- HLI/HLD;
- stack pre-decrement and post-increment;
- immediate-address/WZ increments such as the second `LD [a16],SP` write;
- relative/control-flow PC adjustment where the physical IDU is used;
- interrupt's PC correction and stack updates.

The Game Boy adapter combines, for each M-cycle:

```text
active read/write kind
IDU operation and micro-op provenance
old driven address
PPU mode-2 row
hardware profile
```

and applies the profile's OAM corruption relation. It distinguishes read, write, double-write, and read-plus-IDU patterns. POP/RET produce only three observed triggers—the second read lacks the extra glitched write—while PUSH/CALL/RST/interrupt have their own effective three-write pattern despite two architectural writes and two stack decrements. CGB/AGB profiles disable the monochrome corruption behavior.

For the monochrome baseline, OAM is 20 rows of four 16-bit words and the PPU selects one row per M-cycle in mode 2. The accessed CPU address/value do not select the corruption row. Rows containing the first two objects are protected as described by the profile. Newer DMG-B oracle evidence contains tertiary/quaternary, row-, revision-, and instance-specific cases; the equations below are required baseline cases, not a universal deterministic algorithm.

Let `a` be the current row's first word, `b` the preceding row's first word, and `c` the preceding row's third word.

```text
write first word = ((a XOR c) AND (b XOR c)) XOR c
read first word  = b OR (a AND c)
```

For ordinary read or write corruption, the last three current-row words are copied from the preceding row; write corruption uses the first equation and read corruption the second. A simultaneous IDU update plus write behaves like one write corruption.

For a read plus IDU update, when the PPU row is neither among the first four nor the last, let `a2` be the first word two rows before, `b1` the preceding first word, `c0` the current first word, and `d1` the preceding third word:

```text
preceding first word =
  (b1 AND (a2 OR c0 OR d1)) OR (a2 AND c0 AND d1)
```

After that update, copy the preceding row to the current row and to the row two before, then apply ordinary read corruption. Outside that row range, skip the preliminary three-row transformation but still apply ordinary read corruption. The implementation uses 16-bit word operations and explicit row bounds.

A deterministic `OamInstanceClass` must come from a fixture-qualified capture. Otherwise the DMG-B family relation includes only reviewed baseline and advanced transforms, and the Pokémon projection proves variation irrelevant. This behavior is not part of flat-memory refinement, but the processor trace must contain enough information to prove the SoC theorem.

## Interrupt state machine

### Polling

`pending = IE AND IF AND 0x1F`; lower bit number has higher ordinary priority. Pending is supplied by the adapter at explicit phases.

Interrupt polling occurs on eligible generic fetches. It does not split the CB prefix/subopcode pair, and invalid lockup never reaches another fetch. An accepted interrupt discards the prefetched byte and preserves its address as the software-visible return PC through the physical PC-correction sequence.

### EI/DI/RETI phase behavior

A single `ime : Bool` plus “enable after next instruction” prose is insufficient. Use a staged latch whose transition order proves:

| Sequence with pending request | Required result |
|---|---|
| `EI; DI` | no interrupt; DI immediately suppresses the relevant poll and cancels delayed enable |
| `EI; NOP` | interrupt accepted after NOP, before the subsequent instruction executes |
| `EI; EI` | the first EI matures; interrupt is accepted after the second EI; Mooneye observes return address `$01A2` in its placed sequence |
| `EI; HALT` | HALT follows the hardware IME/prefetch ordering and services the request as the tested IME-enabled case |
| RETI with another pending request | returned-to opcode does not execute before the next interrupt; the same return address can be pushed again |
| rapid EI/DI | no transient service in the tested alternating sequences |

The theorem states old-latch, current-opcode override, poll, and new-latch order. DI's special poll suppression is not modeled merely by setting IME at a later instruction boundary.

### Five-M-cycle entry

The physical interrupt microprogram has five M-cycles:

1. correct the already-ahead PC for the discarded prefetch;
2. perform the initial SP-decrement/internal phase;
3. write return-PC high while applying the next SP decrement;
4. write return-PC low and resolve vector/acknowledgement state;
5. fetch from the resulting vector or `$0000` cancellation target.

The exact event names are implementation-facing; theorems prove five elapsed M-cycles, high-before-low stack order, return address, final fetch, and OAM/IDU intent.

### Mid-dispatch IE writes

When stack writes alias `$FFFF`:

- initial SP `$0000` makes the high-byte push write IE soon enough to change dispatch;
- if no enabled request remains, PC becomes `$0000`, IME stays disabled, and the original IF request remains set;
- if another enabled request remains, the highest newly enabled pending request supplies the vector; the chosen request is acknowledged while higher-priority-but-now-disabled IF bits remain;
- initial SP `$0001` makes the low-byte push hit IE too late to cancel the already selected vector; normal acknowledgement occurs.

The pending mask is therefore not frozen at instruction boundary. IF acknowledgement is an adapter transaction with an explicit collision rule against simultaneous device/software IF updates.

## HALT state machine

HALT performs a non-incrementing/dummy fetch through the pipeline. Its state transition depends on the effective IME phase and pending mask, not only final architectural IME.

Required cases:

| Entry condition | CPU result |
|---|---|
| IME enabled, no pending | enter halted mode; wake and service when pending appears |
| IME disabled, no pending | enter halted mode; wake without service when pending appears |
| IME disabled, pending | do not stay halted; arm one-fetch PC-increment suppression (HALT bug) |
| EI/HALT overlap | use staged EI/HALT ordering, not a generic retirement rule |

The HALT-bug theorem is generic over the following bytes:

- one-byte opcode can be fetched/executed twice;
- multi-byte opcode can consume its opcode byte as an operand;
- following `$CB` can make `$CB` serve as both prefix and subopcode;
- following RST pushes a return address pointing at the RST itself;
- consecutive HALTs and EI/HALT/RST combinations follow explicit sequence fixtures.

Halted waiting is a coinductive/system transition with a wake event, not a completed instruction with a large duration. HALT wait and analysis fuel exhaustion remain different outcomes.

## STOP profile matrix

STOP cannot be reduced to a globally fixed one- or two-byte instruction. The profile input includes selected button/WAKE state, pending mask, IME phase, speed-switch request, speed mode, DIV/clock state, and hardware revision.

The pinned Pan Docs decision source exposes seven outcome classes:

| Outcome | Byte/fetch effect | Run mode | DIV/speed effect |
|---|---|---|---|
| selected button, pending | one-byte appearance | continue | DIV not reset |
| selected button, no pending | two-byte appearance | HALT-like | DIV not reset |
| no button/speed request, no pending | two-byte appearance | STOP | DIV reset |
| no button/speed request, pending | one-byte appearance | STOP/zombie profile | DIV reset |
| speed request, no pending | two-byte appearance | temporary HALT-like speed-switch state | DIV reset; speed changes; profile timeout/wake |
| speed request, pending, IME disabled | one-byte appearance | continue | DIV reset; speed changes |
| speed request, pending, IME enabled | unstable/glitch class | nondeterministic profile relation | may corrupt control/stack |

A deterministic profile implements only outcomes established for its named console/revision and input assumptions. The pinned Pan Docs materials themselves expose a timing conflict: the STOP decision artifact annotates one speed-switch HALT-like exit at about `$20000` T-cycles, while `CGB_Registers.md` gives a 2050-M-cycle/8200-T-cycle CPU pause for the recommended switch and notes unresolved interrupt consequences. No global constant is imported; a named CGB revision plus adjudicating test/hardware evidence selects the timing. The unstable class is a relation/set of permitted transitions until evidence narrows it and must not be hidden as an arbitrary deterministic choice.

For the canonical Red theorem, prove STOP unreachable from the decoded execution closure. That removes STOP behavior from the theorem assumptions without falsely claiming universal STOP verification.

## Invalid-opcode lock

The 11 invalid base bytes enter a decode state with no subsequent generic fetch. Required properties:

- no instruction retirement;
- no PC progress after the opcode's fetch-side increment already represented by the pipeline;
- no interrupt or NMI recovery through ordinary fetch-time dispatch;
- stable locked opcode/provenance in diagnostic projection;
- profile-defined pin/address/clock behavior while the surrounding SoC continues whichever domains are not gated;
- lockup distinct from HALT, STOP, ROM divergence, timeout, and fuel exhaustion.

The external pin behavior during indefinite lock must be profile-qualified if it is observable; “four cycles then NOP” is forbidden.

## Functional and system refinements

The package proves three non-identical layers:

1. **Architectural instruction relation**: final registers/flags, logical accesses, and programmer cycle total.
2. **De-overlapped executable runner**: suitable for all normal SingleStep fixtures and leaf Hoare proofs.
3. **Physical pipelined M-cycle core**: IR/prefetch, IDU/address drive, interrupt polling, clock intent, and control states.

Required theorems:

```text
physical sequence execution
  refines de-overlapped byte-program execution
  under a pipeline-boundary relation and non-interrupting flat bus

de-overlapped instruction execution
  refines the declarative architectural relation

physical core composed with named Game Boy adapter
  refines the profile-qualified system transition
```

The first theorem uses trace reassociation for overlapping fetches and explicitly excludes or separately proves DI/EI/RETI/HALT/STOP/lock and accepted-interrupt boundaries.

## Program logic implications

Generic `Runs` and Hoare rules require more than immutable byte lookup:

- the next opcode was potentially prefetched before the checkpoint;
- MBC writes can affect the next fetch only according to their bus commit phase;
- interrupts require an invariant for handler stack/bank effects or an explicit disabled-interrupt precondition;
- HALT establishes a liveness obligation on an enabled wake source and clock-domain progression;
- return rules state whether the caller opcode is fetched, in IR, or not yet sampled;
- self-modifying writes and MMIO reads are sequential bus effects, not a pure final-memory lookup;
- routine summaries preserve hidden pipeline state or discharge it at a proved synchronization boundary.

## Conformance matrix

| Claim | Required evidence |
|---|---|
| 512-row decode/length/flag metadata | Lean theorem plus exact gb-opcodes audit |
| Normal final state and active bus sequence | Lean refinement plus 500,000 SingleStep cases |
| Idle address and IDU micro-operations | physical-core theorem reviewed against pinned microarchitecture sources; targeted OAM tests |
| DAA | equation theorem over 2048 relevant A/N/H/C combinations, old-Z irrelevance theorem, and all 4096 Mooneye A/ZNHC rows |
| EI/DI/RETI | sequence theorems plus Mooneye `ei_sequence`, `rapid_di_ei`, `halt_ime0_ei`, and `reti_intr_timing` |
| Interrupt entry | five-cycle theorem, exact stack trace, `intr_timing`, and `interrupts/ie_push` |
| HALT | transition/bug sequence theorems plus profile-qualified Mooneye/SameSuite traces |
| STOP | profile relation and selected hardware evidence; unreachable proof for canonical Red |
| OAM corruption | core IDU trace sufficiency theorem plus adapter corruption theorem and profile tests |
| Clock conversion/gating | typed-unit theorems and profile-qualified timer/DMA/PPU tests |
| Pipeline start/checkpoint | reset/bootstrap theorem or caller-to-symbol fetched-boundary theorem |
| Lockup | no-fetch/no-interrupt coinductive theorem plus differential trace where measurable |

SingleStep facts found by exhaustive audit:

- 500 files and 500,000 cases;
- exactly 16 read/write/idle signal-sequence shapes;
- only `r-m`, `-wm`, and `---` signals;
- lower F nibble is zero in every initial/final state;
- no null bus values or duplicate RAM addresses in the pinned vectors;
- IE/IME fields remain non-authoritative, and EI uses a distinct final `ei` field;
- HALT/STOP each use three-cycle placeholders;
- idle address/data values are not physical pin evidence.

## Claim discipline and remaining profile work

This contract exhausts the categories that an implementation must cover. It does not convert unresolved silicon behavior into certainty.

The first system profile is now `DmgCpuBCommonBoot`. Its evidence contract fixes T1F–T4R ordering, reset ownership, CPU/system clock gates, NMI tie-off, SameBoy quarantine, and the hardware procedure. Before a fixture can claim end-to-end dot-exact correctness, it still needs:

1. captured propagation bounds for analog-sensitive read-fold cases;
2. fixture-specific locked retained pins/reset recovery if those observations are claimed;
3. measured advanced OAM instance classification or a proof that the permitted relation is projection-irrelevant;
4. signed, hashed DMG-B captures produced by the specified procedure;
5. a caller-derived IR/pipeline checkpoint for any theorem that starts mid-execution.

These are explicit implementation/proof obligations, not omitted features. The canonical Pokémon theorem can discharge unreachable branches, but the standalone package release manifest must label any profile hook not universally closed.
