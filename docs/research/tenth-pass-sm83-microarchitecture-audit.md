# Tenth-pass SM83 microarchitecture closure audit

<!-- research record; pipeline, pins, clocks, and profile closure -->

**Pokémon baseline:** `pret/pokered` commit `405b6246372d7e5a2cb029cbb65219b13286b8c9`.

**Result:** the prior opcode specification was complete at the programmer-visible instruction level but not at the physical pipeline/system boundary. This pass audited fetch overlap, internal microstates, clock gates, IDU address effects, OAM corruption, interrupt phase ordering, HALT/STOP, and fixture limitations. The corrected contract is [SM83 microarchitecture and system-boundary contract](../reference/sm83-microarchitecture-contract.md).

**Superseding profile note:** the [eleventh pass](eleventh-pass-sm83-profile-evidence-audit.md) selects DMG-CPU B, resolves the bus protocol to eight half edges, and shows that the baseline OAM equations below are not complete for every DMG instance/row.

## Sources inspected

| Source | Pinned commit | Audit result |
|---|---|---|
| Pan Docs | `fe246067b695b5404a4a6a47efb4fd6d921ececb` | invalid set, five-cycle interrupt, HALT, seven STOP outcomes, OAM/IDU corruption |
| GB Complete Technical Reference | `d164e64678841d2e4d768850810a89d0b9964187` | 256+256 opcode map, 105 categories, 101 detailed normal-family timings, overlap and clock edges |
| SingleStepTests/sm83 | `f9c30210245dd691661db39f5ace022c465ecc2f` | all 500,000 cases and all bus-shape/schema distributions re-audited |
| Mooneye | `31510e12eea6286d36eea060a6adde755e1067aa` | all 75 acceptance sources inventoried; relevant CPU/interrupt/HALT/DAA sources inspected |
| Game Boy CPU internals gist | `8efa6645473411e78dd917169141c16c0d306ce1` | decode-ROM-based IR/IDU/fetch/ISR/control account; factual citation only due absent license |

Added `tools/audit-sm83-sources.py`. It rejects dirty checkouts and checks five exact commits, 22 hashes, GB CTR category/detail coverage and one-to-one assignment of all 101 normal families to 33 templates, all SingleStep schemas/signals, the 4096-row Mooneye DAA table, interrupt-source patterns, the invalid set, and all seven STOP outcomes.

All 256 base and 256 CB GB CTR category assignments match a second encoding-derived x/y/z classifier. The 101 detailed normal timing blocks partition as 23 one-M, 44 two-M, 10 three-M, 18 four-M, one five-M, one six-M, plus four conditional pairs: JP 4/3, JR 3/2, CALL 6/3, and RET 5/2. Every block contains memory, address, data, IDU, ALU, and miscellaneous lanes.

## Main correction: opcode fetch is pipelined

The earlier schedule table used the conventional view in which an instruction begins with its opcode fetch and commits at the end of the same slice. That is appropriate for programmer timing and SingleStep, but not sufficient as the canonical SoC core.

The physical core overlaps execution with the following opcode fetch:

- IR already holds the executing opcode;
- the final microcycle normally fetches the successor;
- PC is ordinarily ahead of IR;
- an accepted interrupt discards the prefetched byte and corrects the return PC;
- DI/EI/RETI and HALT depend on the ordering inside that fetch cycle;
- STOP's apparent one-/two-byte behavior is inseparable from prefetch/clock gating;
- JP HL fetches directly from its target in its one-cycle path.

Decision: retain the previous bus schedules as a de-overlapped architectural projection, but make a fetched-IR M-cycle pipeline the canonical executable core. Prove trace reassociation rather than identifying the two by definition.

## Hidden state is semantically relevant

A correct core needs more than architectural registers:

- IR and IR source address;
- CB-prefix latch;
- decode/microstate index;
- W/Z-like immediate and address latches;
- condition result latch;
- ALU carry/temp latches where a 16-bit operation spans cycles;
- IDU source/direction/destination;
- prefetch address and increment suppression;
- staged IME/EI state;
- run/clock mode.

These values may be hidden from ordinary state projections only after proving they do not affect the future observation under that projection.

## Internal cycles are not bus-nothing

The prior `I = internal cycle, no memory request` notation remains true only for read/write control. It is false if interpreted as “no externally relevant address behavior.”

On monochrome hardware, the IDU drives the address path. OAM corruption can be triggered by:

- PC fetch increments;
- INC/DEC 16-bit registers;
- HLI/HLD updates;
- stack updates;
- POP/RET and PUSH/CALL/RST/interrupt sequences with asymmetric trigger counts;
- code execution or multi-byte reads crossing into OAM.

The processor package must emit address drive, IDU intent, and micro-op provenance even on idle cycles. The Game Boy adapter owns the PPU-mode/profile-specific OAM corruption transformation. The tenth-pass contract recorded baseline 16-bit write/read equations, row-copy behavior, the read-plus-IDU three-row transform, protected/excluded rows, and POP/RET versus PUSH/CALL/RST asymmetries. The eleventh pass found additional revision/instance-specific transforms and replaced universal determinism with a fixture/family relation.

## Clock model correction

The statement “halted cycles advance system devices” was too broad.

Required clock domains now include CPU T-cycles, CPU M-cycles, PPU dots, oscillator edges, external serial edges, and cartridge RTC edges. Normal speed has four dots per M-cycle and CGB double speed two. HALT and STOP provide clock-gate intent rather than synthetic normal idle cycles.

Mooneye's MGB OAM-DMA/HALT source demonstrates that a DMA access can remain held while the PPU continues. System progression must therefore be selected by domain and hardware profile.

## Fetch phases affect routine theorem boundaries

A theorem beginning with only `PC = InitOpponent` is not a complete physical checkpoint. At steady state the first callee opcode may already be in IR due to the caller's transfer/fetch cycle.

The machine proof must either:

- execute the caller transfer into the callee; or
- establish a `PipelineWellFormed` checkpoint containing IR, its address, next PC, prefix state, and hidden latches.

The same issue applies to return sentinels: fetched, in-IR, and not-yet-fetched are different states. Reset must also state the initial IR/dummy-NOP convention. Optional Sharp-core NMI/reset pins are either modeled or proved tied inactive by the Game Boy profile; otherwise the package claim is explicitly limited to the Game Boy embedding.

## Exact EI/DI/RETI obligations

A delayed-enable Boolean without phase order is insufficient. Required sequence results include:

- `EI;DI`: no interrupt and pending enable cancelled;
- `EI;NOP`: service after NOP;
- `EI;EI`: the first EI matures and the interrupt occurs after the second; Mooneye's placed test observes return address `$01A2`;
- `EI;HALT`: tested IME-enabled behavior under pipeline ordering;
- RETI with another pending request: the returned opcode does not execute first;
- rapid EI/DI alternation: no transient service.

DI suppresses the poll associated with its overlapping fetch immediately; this is not equivalent to setting IME only at a later high-level boundary.

## Interrupt-entry closure

The five-cycle entry now includes physical pipeline effects:

1. correct the ahead PC after discarded prefetch;
2. initial SP decrement/internal phase;
3. high-byte stack write and next SP update;
4. low-byte stack write plus vector/ack resolution;
5. vector or cancellation-target fetch.

`interrupts/ie_push` gives exact externally visible dispositions:

- high-byte write to IE with initial SP `$0000` can cancel to `$0000`;
- cancellation leaves IME zero and does not clear the original IF request;
- the same write can retarget to another enabled pending interrupt;
- low-byte write to IE with initial SP `$0001` is too late to cancel;
- normal selected IF acknowledgement still occurs in the latter case.

The processor therefore resamples through a timed adapter port rather than freezing one vector at the boundary.

## HALT expansion

HALT is now specified as dummy/non-incrementing fetch plus run-mode transition. The HALT-bug proof must be parametric over following bytes, covering:

- repeated one-byte opcode;
- opcode reused as a multi-byte operand;
- `$CB` serving as both prefix and subopcode;
- RST pushing an address pointing back to itself;
- consecutive HALTs;
- EI/HALT/RST ordering.

Waiting is a system transition with clock-domain and wake behavior, distinct from ordinary retirement or fuel exhaustion.

## STOP expansion

The Pan Docs decision artifact contains seven outcome classes spanning:

- one- versus two-byte appearance;
- continue, HALT-like, STOP, and unstable modes;
- DIV preserved versus reset;
- speed unchanged versus switched;
- selected-button, pending-interrupt, IME, and speed-request conditions.

The unstable IME-enabled speed-switch/pending case cannot honestly be a deterministic function without stronger profile evidence. It is modeled as an explicit profile relation. Even the clean speed-switch timing needs adjudication: the decision artifact says about `$20000` T-cycles for one HALT-like path, while Pan Docs' CGB register page says 2050 M-cycles/8200 T-cycles and leaves interrupt consequences unresolved.

Canonical Red has no STOP mnemonic in the reviewed source scan. Its system theorem should prove STOP unreachable, while the package release clearly marks profile coverage rather than claiming all-hardware STOP correctness.

## Lockup expansion

Invalid opcodes do not merely “take four cycles.” Decode reaches no generic fetch state. Lockup:

- does not retire;
- does not fetch or accept ordinary interrupts;
- remains distinct from HALT/STOP;
- retains profile-qualified pin/clock behavior if anyone observes it;
- may be excluded from the Pokémon theorem only through reachability proof.

## SingleStep exhaustive findings

The new audit streamed all 500 files and 500,000 cases.

| Fact | Exact result |
|---|---|
| Signal tokens | only `r-m`, `-wm`, `---` |
| Aggregate signals | 887,060 reads; 72,854 writes; 48,942 idle samples |
| Cycle lengths | 131,000 × 1; 287,950 × 2; 31,128 × 3; 43,965 × 4; 3,030 × 5; 2,927 × 6 |
| Distinct signal sequences | 16 |
| Null address/data entries | zero |
| Duplicate RAM addresses within a state | zero |
| Low F nibble | zero in every initial and final state |
| Initial schema | includes non-authoritative `ime` and `ie` |
| EI final schema | uniquely uses `ei`; another reason not to trust sequence state |
| HALT/STOP | three-cycle placeholders, not physical completion models |

The README says idle address/data may simply retain convenient prior values. SingleStep can validate active reads/writes and de-overlapped results; it cannot establish idle address drive, IDU behavior, prefetch commit phase, interrupts, or clock gating.

## DAA closure

Mooneye's DAA source contains 4096 rows, not 2048: all 256 A values times all 16 old ZNHC nibbles. The equation audit passed every row.

The Lean proof plan is now:

1. prove output independence from old Z;
2. prove the equation over 2048 relevant A/N/H/C combinations;
3. execute/check all 4096 pinned hardware-observed rows;
4. retain symbolic correctness lemmas for composition.

## Refined semantic layers

The processor package now needs three distinct layers:

1. declarative architectural instruction relation;
2. de-overlapped executable instruction runner for SingleStep and leaf reasoning;
3. physical fetched-IR M-cycle core for Game Boy composition.

Theorems relate physical sequence execution to the de-overlapped byte-program runner under a pipeline-boundary relation, then relate that runner to the declarative relation. Exceptional control families receive dedicated theorems.

## Remaining blockers after exhausting the categories

At the end of this pass, these profile facts still required evidence:

- exact T1–T4 read/write/interrupt/register commit edges;
- exact `DMG-CPU C` reset and clock-gate behavior;
- pin behavior during indefinite invalid lock;
- deterministic portions of the DMG STOP matrix if STOP is not merely unreachable;
- a complete OAM corruption adapter theorem;
- independent emulator and physical-hardware trace procedures;
- proved IR/pipeline checkpoints for mid-program theorem entries.

The eleventh pass resolves the first profile to DMG-CPU B, fixes T1F–T4R/reset/gates/NMI/boot/oracle/procedure, and leaves locked retained levels plus advanced OAM instance classification as capture-backed relations.

## Validation

The pass finishes with:

```text
PASS five pinned SM83 reference commits and 22 exact source hashes
PASS gb-ctr: 256+256 rows, 105 categories, 101 timings mapped once into 33 templates
PASS SingleStep: 500 files, 500000 cases, exact schemas/signals/cycle distributions
PASS Mooneye: 75 acceptance sources and all 4096 DAA A/ZNHC states
PASS Pan Docs: invalid set, interrupt/HALT/OAM facts, and seven STOP outcomes
```

No Lean implementation was added. The implementation space is now exhaustively partitioned into proved code obligations, Game Boy adapter obligations, profile assumptions, unreachable branches, and unresolved hardware evidence.
