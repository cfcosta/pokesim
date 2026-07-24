# Eighth-pass SM83 semantics audit

<!-- research record; processor/assembly boundary -->

**Pokémon baseline:** `pret/pokered` commit `405b6246372d7e5a2cb029cbb65219b13286b8c9`.

**Lean prior art:** `vicgalle/gameboy-pokered-verify` commit `aa9b95b87b82210464a24e849026722c425c7be2`.

This pass audited what it would mean to verify the processor and assembly execution independently of Pokémon mechanics. The subsequent [ninth pass](ninth-pass-gb-opcodes-audit.md) clones and audits all gb-opcodes rows and fixes the exact implementation contract. The result is a separate-package decision and a stricter distinction between instruction semantics, clocked CPU behavior, Game Boy hardware, and source assembly.

## Decision

Create a standalone `sm83-lean` repository/package and consume a pinned commit through Lake. The package owns complete SM83 byte decode, instruction/clock semantics, interrupt/HALT/STOP/lockup behavior, a generic bus protocol, flat-memory proofs, and processor conformance.

The Pokémon verifier owns the Game Boy SoC/cartridge realization and proves that it satisfies the processor bus/interrupt contract. It also owns ROM identity, symbols, battle state, and refinement.

See [Standalone SM83 semantics package](../reference/sm83-semantics-package.md).

## High-impact findings

| Finding | Evidence | Consequence |
|---|---|---|
| Existing Lean work is not an opcode interpreter | No fetch/decode/step module exists; helpers are called directly | Do not adopt its `CPUState` as the ROM execution layer. |
| Existing validation language overstates `#eval` | Arithmetic/logic files print Boolean tuples followed by expected comments | `#eval` does not fail the build when false; replace with theorems or a nonzero-exit fixture runner. |
| Memory cannot remain a pure function inside CPU state | Reviewed model uses `BitVec 16 → BitVec 8` | Canonical CPU uses an ordered timed bus protocol; flat memory is only an adapter. |
| Interrupt semantics are absent | `di` and `ei` return the input state; `halt` only sets a Bool | Model IME delay, DI cancellation, RETI, five-M-cycle entry, mid-dispatch IE-write cancellation/retargeting, wake, and HALT bug. |
| Final stack bytes are weaker than stack behavior | `pushStack` writes a little-endian word at `SP-2` | Need observable high-byte-then-low-byte push and low-byte-then-high-byte pop cycles. |
| Processor completeness cannot be “reachable operations only” | Red source uses 43 of 44 mnemonic families; only STOP is absent in the source scan | Verify the complete 244 legal base + 256 CB opcode entries and 11 invalid slots once in the dependency. |
| DAA and interrupts are battle-driver relevant | `AddBCD` uses DAA for Pay Day/payout; `DelayFrame` uses HALT and VBlank returns with RETI | These cannot be postponed as unrelated emulator features. |
| Assembly source and processor semantics are different proof layers | RGBDS macros/labels are absent from ROM execution | Execute canonical bytes; package generic fetched-byte `Runs`/Hoare logic, while symbols/source remain consumer artifact metadata. |
| M-cycle count alone is insufficient | `rDIV`, MMIO reads, stack writes, DMA, interrupt polling, and LCD restrictions are phase-sensitive | Canonical core exposes T-cycle-equivalent clocked execution plus a proved functional instruction view. |
| Hardware profile was implicit | Mooneye expectations vary across DMG/MGB/SGB/CGB/AGB and SoC revisions | First theorem must name a profile. This pass provisionally recommended DMG-CPU C; the eleventh evidence pass supersedes it with DMG-CPU B. |
| Public opcode fixtures have cleanly separable scope | SingleStep is flat-memory and says to ignore IE/IME; Mooneye exercises system hardware | Processor package runs flat-bus corpus; Game Boy adapter runs integration ROMs. |

## Existing Lean model audit

All nine `SM83/*.lean` files in the sibling project were read completely.

### State and flags

`CPUState` stores registers, SP, PC, a total memory function, and `halted`. There is no cycle count, instruction phase, IME, delayed enable, interrupt input, STOP, or invalid-lock state. `f` is an arbitrary byte; helper constructors generally clear its low nibble, but raw states and flag-preserving setters can retain impossible low bits.

A reusable model should encode flags as a constrained type and prove its byte codec. External test fixtures with arbitrary low flag bits need an explicit normalization adapter.

### Arithmetic and logic

The direct helpers capture useful equations for ADD/ADC/SUB/SBC/CP, INC/DEC, ADD HL, logic, shifts, and selected rotations. They are not fetched opcodes and do not account for operands, PC, cycles, or bus behavior. DAA, signed-SP operations, several rotate forms, and complete memory/register dispatch are missing.

The algebraic theorems are useful examples. They do not establish decoder completeness or hardware correspondence.

### Loads and memory

The memory function supports convenient extensional proofs but assumes reads are pure and instantaneous. That is invalid for ROM banking and MMIO. The stack helpers produce correct final bytes on flat memory, but collapse ordering and timing.

This distinction matters even when canonical SP remains in WRAM: call/interrupt timing affects devices, and arbitrary-state processor theorems may place SP anywhere.

### Control

Control helpers accept already-decoded targets. Their PC convention is caller-supplied because there is no fetch loop. `di`/`ei` are no-ops, HALT cannot wake, RETI is absent, and no interrupt can occur.

### Validation

The files include `#eval` expressions whose comments state expected output. Lean evaluates and prints them, but a false result is still a successful build. They are demonstrations, not assertions. The `Properties.lean` theorems are real checked propositions, but cover selected algebraic facts rather than processor execution.

## Pokémon instruction inventory

A source-level scan of all `.asm` files found 43 represented mnemonic families out of the reviewed 44-family list; STOP was the only absent mnemonic. Notable counts include:

| Mnemonic | Source occurrences | Relevance |
|---|---:|---|
| `daa` | 2 | BCD payout/Pay Day paths |
| `halt` | 1 | `DelayFrame` |
| `reti` | 4 | VBlank/serial/interrupt handlers |
| `di` / `ei` | 5 / 5 | initialization and interrupt sequencing |
| `rst` | 9 | vectors/lock behavior |
| `rl` / `rr` / `rlc` / `rrc` and shifts | represented | CB decoder coverage |
| `ldh` | 2,531 | HRAM/MMIO access |
| `call` / `jp` / `jr` / `ret` | heavily represented | exact PC/stack/conditional timing |

These are discovery counts, not a canonical-ROM reachability proof; macro definitions and unreachable source can be counted. M0 still needs the address-based decoded range graph. The inventory nevertheless shows why a small direct-operation library is the wrong abstraction.

## Complete decoder target

Pinned gbdev metadata and SingleStep fixtures agree on the structural domain:

- 256 base byte slots;
- 244 legal non-prefix base instructions;
- one `$CB` prefix;
- 11 invalid lockup bytes: `D3 DB DD E3 E4 EB EC ED F4 FC FD`;
- 256 legal CB-prefixed entries.

The separate package should prove this partition. “Unsupported opcode” is not a valid runtime fallback. Invalid bytes enter a hardware lock state; legal unimplemented bytes are a package build failure.

## Assembly/program conclusion

Reusable assembly reasoning should sit above fetch/decode as generic `Runs`, `RunsUntil`, return-sentinel, Hoare, and frame judgments over numeric byte addresses. It must continue fetching through the bus rather than assume a fixed predecoded list. A predecoded ROM optimization needs a fetch-equivalence theorem under immutable code and bank-selection premises.

RGBDS `farcall`, predef, and macro forms are not primitive SM83 operations. The Pokémon verifier proves their emitted byte sequences and owns symbols, bank metadata, routine preconditions, and projected frames. This keeps source tooling out of the processor trusted path while still making routine proofs reusable.

## Timing and bus conclusion

Three views must not be conflated:

1. pure ALU equations;
2. one-instruction architectural relation with ordered bus events;
3. clocked core composed with devices.

The battle proof runs view 3. Leaf routine proofs may use view 2 after a refinement theorem. View 1 supplies reusable arithmetic lemmas.

The bus boundary keeps the package reusable:

- core emits fetch/read/write/internal/interrupt events;
- adapter supplies read data and pending interrupts;
- adapter advances Game Boy devices and implements banking/access restrictions;
- flat-memory adapter supports opcode vectors.

## Interrupt/HALT closure

Pan Docs at pinned commit confirms:

- EI effect is delayed by one instruction;
- EI immediately followed by DI does not admit an interrupt between them;
- ordinary interrupt entry clears IME, resolves/acknowledges priority through a five-M-cycle sequence, and pushes PC;
- HALT wakes when `IE & IF` becomes nonzero;
- IME-zero HALT has separate no-pending and already-pending cases;
- the latter triggers the HALT bug and alters fetch/PC behavior.

Mooneye's hardware-verified `interrupts/ie_push` adds a subtle requirement beyond an atomic textbook transition: if the upper PC push writes `$FFFF` and changes IE, dispatch can cancel to `$0000` or retarget to another enabled interrupt; a lower-byte push write is too late. The processor and Game Boy adapter must exchange the current pending mask during dispatch rather than freeze it before both writes.

`pokered/home/vblank.asm` makes interrupt behavior directly relevant. `DelayFrame` loops on HALT until VBlank clears `hVBlankOccurred`; VBlank pushes registers, performs ROM/MMIO work and RNG, then returns through RETI. A summarized sleep operation would erase precisely the timing/RNG behavior the project intends to prove.

## DAA closure

`pokered/engine/math/bcd.asm` uses `adc`/`sbc` followed by `daa`. Battle payout and Pay Day call `AddBCDPredef`. Therefore DAA needs exact addition/subtraction semantics and exhaustive validation before the minimal complete episode can claim trainer or Pay Day coverage.

The first one-hit wild M3 fixture can avoid money mutation, but the processor dependency itself should not publish as complete with DAA omitted.

## External references pinned during this pass

| Repository | Commit | License observed | Role |
|---|---|---|---|
| `gbdev/pandocs` | `fe246067b695b5404a4a6a47efb4fd6d921ececb` | CC0 | behavior reference |
| `gbdev/gb-opcodes` | `376f61c86fdac2048f7ce5fe838ae756b306017e` | CC0 | opcode metadata cross-check |
| `SingleStepTests/sm83` | `f9c30210245dd691661db39f5ace022c465ecc2f` | MIT | flat-bus per-opcode fixtures |
| `Gekkio/mooneye-test-suite` | `31510e12eea6286d36eea060a6adde755e1067aa` | MIT | hardware/system acceptance ROMs |
| `Gekkio/gb-ctr` | `d164e64678841d2e4d768850810a89d0b9964187` | CC BY-SA 4.0 | detailed cross-reference |

The SingleStep tree has 500 opcode JSON files and 1000 cases per file: 244 base legal instructions plus 256 CB instructions, totaling 500,000 fixtures. It does not cover the prefix as an independent instruction or the 11 lockup bytes. Its README says IE/IME fields should be ignored and warns the emulator-generated vectors may contain errors, so separate interrupt tests and disagreement adjudication remain mandatory.

Cycle references use different units: RGBDS presents 1 MHz machine-cycle counts, while gb-opcodes metadata records 4 MHz clock counts. The Lean API and fixture importers need unit-tagged `TCycles`/`MCycles`, not interchangeable `Nat` values.

Mooneye currently has 75 acceptance source tests, including named DAA, EI/DI, interrupt timing, HALT, stack/control-flow timing, timer, DMA, and PPU tests. Model/revision suffixes must be respected.

## Package dependency rule

The Pokémon project should use an immutable Lake git revision and verify the resolved commit. It must not:

- follow the processor repository's moving branch;
- copy processor definitions into `PokeRed/`;
- import test-only JSON parsers into theorem roots;
- patch processor semantics locally to make one ROM trace pass;
- bypass the processor with handwritten opcode summaries.

A routine summary ultimately depends on a processor theorem from the pinned package and a Game Boy adapter theorem from the Pokémon project.

## Licensing conclusion

The external test/reference repositories have explicit licenses as listed above. The sibling Lean prior-art project still has no root license file at the reviewed commit. Its README says the Lean work is original but does not grant a standard reuse license. Clean implementation or explicit permission remains required.

The new processor package must have an explicit root license before publication. GB Complete Technical Reference is cited rather than copied unless its ShareAlike implications are intentionally accepted.

## Specification changes from this pass

1. SM83 moves from an internal `PokeRed/SM83` folder to a separate dependency.
2. Complete opcode coverage replaces first-slice reachable-opcode coverage as the package gate.
3. CPU memory is replaced by a timed bus protocol; flat memory becomes an adapter.
4. Functional and clocked semantics are both required, with a refinement theorem.
5. IME/EI/DI/RETI, interrupt entry, HALT bug, STOP, and invalid lockup become explicit states/transitions.
6. Game Boy MBC/MMIO/DIV/PPU/DMA/serial/audio stay in the Pokémon system adapter.
7. A hardware profile becomes a named theorem parameter/selection.
8. `#eval` output is explicitly rejected as validation.
9. SingleStep and Mooneye ownership is split between processor and system CI.
10. Processor release/axiom/license/dependency pins become correctness gates.

## Remaining decisions

- final package/repository name and root license;
- pinned Lean version shared by dependency and consumer;
- first claimed hardware profile and revision;
- exact T-cycle API versus an M-cycle microstate with proved T-cycle expansion;
- independent emulator and physical-hardware trace procedure;
- whether a reusable `gameboy-system-lean` package is extracted after the first adapter proof.

## Immediate implementation order

1. Create licensed standalone package with pinned Lean toolchain.
2. Define constrained flags/registers, normalized instruction AST, and complete decoder classification.
3. Define declarative functional instruction relation and prove ALU/decoder properties.
4. Define clocked bus core, interrupt sequencing, HALT/STOP/lock states.
5. Prove functional/clocked flat-bus refinement.
6. Run all pinned SingleStep fixtures and dedicated invalid/interrupt/HALT sequences.
7. Add the pinned dependency to the Pokémon project.
8. Implement Game Boy bus/devices and run Mooneye/independent-emulator traces.
9. Execute and prove one canonical ROM leaf routine, then the complete minimal battle episode.

No processor implementation was added in this pass; the repository remains documentation-only.
