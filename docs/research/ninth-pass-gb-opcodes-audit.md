# Ninth-pass gb-opcodes and SM83 implementation audit

<!-- research record; complete opcode-catalogue grounding -->

**Catalogue:** `gbdev/gb-opcodes` commit `376f61c86fdac2048f7ce5fe838ae756b306017e`.

**Local clone:** `../gb-opcodes`.

**Pokémon baseline:** `pret/pokered` commit `405b6246372d7e5a2cb029cbb65219b13286b8c9`.

This pass cloned the requested opcode repository, audited every one of its 512 rows and its rendering logic, identified fields that cannot be used semantically, and produced the decoder/ALU/logical-bus contract in [SM83 implementation specification](../reference/sm83-implementation-spec.md). The subsequent [tenth pass](tenth-pass-sm83-microarchitecture-audit.md) adds the physical fetched-IR pipeline, pin/IDU, and clock/profile contract that opcode metadata cannot supply.

## Clone and identity

| Artifact | Identity |
|---|---|
| Repository commit | `376f61c86fdac2048f7ce5fe838ae756b306017e` |
| Commit date | 2024-12-13 |
| License | CC0 1.0 Universal |
| `Opcodes.json` SHA-256 | `e7e3cd657d8e87b44570474eb3a6ed735501c9a00520f3d6937881203c823bc5` |
| `OpcodeDescriptions.json` SHA-256 | `ac0eeea25360ea93555ba8e53d8f49f25ee4bfb7ab052466053b18abe94ec079` |
| errata SHA-256 | `e03a589cfe2dba5690c61fbdde4b0ea17d4948cef584c4d62f9410720a5b216c` |
| license SHA-256 | `36ffd9dc085d529a7e60e1276d73ae5a030b020313e6c5408593a6ae2af39673` |

The worktree is clean at the pinned commit.

## Durable audit tool

Added `tools/audit-gb-opcodes.py`. It verifies:

- exact git revision and source hashes;
- exact `unprefixed`/`cbprefixed` objects and `0x00`–`0xFF` key order;
- row/operand schema and flag token domain;
- encoding-derived family classification for every byte;
- every row's mnemonic, byte length, T-cycle totals, and ZNHC metadata;
- exact invalid set and base/CB cardinalities;
- immediate-byte accounting and conditional ordering;
- known F8 rendering-hack shape;
- intentionally incomplete description data;
- optional all-500,000-case SingleStep cycle-total agreement, proving only HALT/STOP differ from ordinary gb-opcodes totals.

It explicitly reports that STOP/HALT/PREFIX/invalid timing and the JSON `immediate`/F8 `increment` fields are not semantic inputs.

## Exact catalogue results

### Base rows

- 256 entries total;
- 244 legal non-prefix opcode bytes, including HALT/STOP control entries;
- one CB prefix;
- 11 invalid/locking bytes:
  `D3 DB DD E3 E4 EB EC ED F4 FC FD`.

Lengths:

- 213 one-byte rows;
- 26 two-byte rows;
- 17 three-byte rows.

T-cycle metadata:

- 145 × 4;
- 60 × 8;
- 15 × 12;
- 18 × 16;
- one × 20;
- one × 24;
- four each of 12/8, 20/8, 16/12, and 24/12 conditional totals.

### CB rows

- 256 legal entries;
- all two bytes including prefix;
- 224 × 8 T-cycles;
- eight × 12 T-cycles (`BIT b,[HL]`);
- 24 × 16 T-cycles (three read-modify-write families × eight bit/operation rows at `[HL]`).

### Encoding partition

The independent x/y/z decoder derives the full catalogue:

```text
x = opcode >> 6
y = (opcode >> 3) & 7
z = opcode & 7
p = y >> 1
q = y & 1
```

Base blocks use finite maps for r8, r16, memory pairs, stack pairs, conditions, ALU operations, and exceptional block-3 rows. CB uses x for rotate/BIT/RES/SET, y for operation/bit, and z for target. No 512-row handwritten match is needed, and no wildcard maps a byte to NOP.

## Catalogue is not a semantics file

### Missing formal provenance

The repository contains no README, JSON Schema, generator, or test suite at the pinned commit. Git history edits the data directly. It is a strong review/cross-check artifact, not a formally generated authority.

### Descriptions are effectively incomplete

`OpcodeDescriptions.json` has only an `unprefixed` object with two groups:

- NOP;
- the four `LD r16,n16` rows.

It describes five base opcodes total and no CB opcodes. The implementation cannot derive effects from it.

### `immediate` does not mean immediate

The website uses `operand.immediate == false` to render square brackets. The field is therefore an indirect-display marker. Open issues document its semantic ambiguity and inconsistency. The top-level `immediate` is the conjunction of the operand display values in the pinned data, but adds no usable semantics.

Our decoder ignores both fields. Immediate consumption comes from encoding families and is cross-checked only against operand `bytes`.

### F8 would mutate SP if imported literally

`$F8` has operands HL, SP, e8 and sets `increment: true` on SP. The renderer special-cases it to print `LD HL,SP+e8`; open issue #39 calls out the ambiguity. The normalized constructor `ldHLFromSPPlus offset` leaves SP unchanged.

### Prefix totals can be double-counted

Base `$CB` says one byte/four T-cycles, while every CB row already includes two bytes and the total 8/12/16 T-cycles. The microcore fetches both bytes, but the completed instruction uses the CB total once. PREFIX never retires alone.

## STOP contradiction

The pinned sources disagree internally:

- `Opcodes.json`: two bytes, four T-cycles;
- rendered description: second byte ignored;
- repository errata: STOP is one byte;
- open issue #31: it behaves as one-byte execution internally but may fetch/discard the next byte when it actually stops;
- current Pan Docs: STOP can stop, halt, act as NOP, switch speed, execute the following byte, or exhibit model/input-sensitive behavior.

SingleStep adds another incompatible view: its STOP fixtures use three M-cycle placeholders, increment PC by one, and do not provide a complete system context.

Decision:

- retain gb-opcodes STOP data as metadata;
- decode the following byte without asserting unconditional consumption;
- use a total model/revision-specific `StopProfile` transition;
- prove STOP unreachable for the Pokémon battle-driver theorem;
- withhold any universal STOP correctness claim.

This is stronger than choosing either “one byte” or “two bytes” globally.

## HALT and invalid rows

The four-T-cycle HALT row is entry cost, not wait duration. HALT is a control mode with IME/pending-dependent wake and HALT-bug behavior.

Invalid rows carry one-byte/four-cycle/preserved-flag display metadata, but hardware lockup does not retire normally. The implementation enters `locked(opcode)` after fetch; interrupts do not wake it.

SingleStep HALT fixtures also use three placeholder M-cycles and lack complete IF/IE wake context. HALT/STOP are excluded from ordinary flat-memory cycle-total conformance.

## Specialized flag metadata

The full-row audit found four deliberate A-on-A specializations:

| Opcode | Metadata | Generic theorem consequence |
|---|---|---|
| SUB A,A `$97` | `1100` | always zero/no borrow |
| SBC A,A `$9F` | `Z1H-` | H and new C follow old C, so C is preserved |
| XOR A,A `$AF` | `1000` | always zero |
| CP A,A `$BF` | `1100` | always equal |

The executor remains generic. Lean proves its generic equations imply these catalogue policies.

## Timing-unit decision

The website explicitly uses T-states; RGBDS instruction docs often display one-quarter-sized 1 MHz M-cycle counts. The implementation introduces distinct `TCycles` and `MCycles` types with a proved ×4 conversion.

The processor package's executable microstep is one M-cycle with four CPU T-cycles. The subsequent microarchitecture audit strengthens “ordered bus request” to physical fetched-IR address/data/control, IDU, commit, poll, and clock intent; the Game Boy adapter supplies values at T1–T4 phases. This retains exact device timing without making untyped cycle totals interchangeable.

## Complete bus schedule

Every normal family now has an explicit de-overlapped logical M-cycle sequence. The tenth pass adds the physical fetched-IR/IDU/commit schedules. Examples:

- `LD [a16],SP`: opcode, low immediate, high immediate, low-SP write, high-SP write;
- CALL: opcode, low/high target, internal, stack high, stack low;
- conditional RET: untaken opcode+internal; taken adds low/high stack reads and final internal;
- CB `[HL]` RMW: prefix, subopcode, read, write;
- CB `BIT [HL]`: prefix, subopcode, read only;
- `ADD SP,e8`: opcode, offset, two internals;
- `LD HL,SP+e8`: opcode, offset, one internal.

Sequence length ×4 is required to equal every normal row's catalogue total. Ordered address/data events are validated against SingleStep independently.

## Fully normalized semantic contract

The new specification fixes:

- constrained flags rather than arbitrary F;
- finite register/target/condition/ALU/bit/vector types;
- constructor-based legal AST;
- bytes retained for relative offsets;
- exact add/sub/half-carry/borrow formulas;
- exact signed-SP low-byte flag rules;
- DAA over all 2048 A/N/H/C inputs;
- accumulator versus CB rotate Z behavior;
- BIT/RES/SET flag behavior;
- HLI/HLD access-before-update;
- low/high order for immediates, LD SP, stack, CALL/RET/RST;
- condition and wrapping behavior;
- delayed EI, DI cancellation, RETI, HALT, interrupt entry/IE-push behavior;
- explicit STOP profile and invalid lock state.

## Functional/executable independence

The package will define independent declarative `InstrRel` and executable semantics. The tenth pass refines the executable side into a de-overlapped instruction runner and a physical fetched-IR M-cycle core. Theorems relate all three; they may share primitive bit-vector lemmas but not one executor whose “equivalence” is definitional reflexivity.

## Metadata-generation policy

A generator may emit a frozen 512-row Lean catalogue for testing/provenance, but:

- semantic constructors come from the x/y/z decoder;
- display operand fields never construct semantics;
- every generated row records commit and JSON hash;
- STOP/HALT/PREFIX/invalid rows carry non-normal dispositions;
- Lean proves decoder projections agree with the frozen metadata;
- the Python audit runs before generation.

This gives useful drift detection without trusting Python or JSON for theorem validity.

## Conformance split

| Input | Responsibility |
|---|---|
| gb-opcodes | Names, normalized lengths, normal total T-cycles, public flag policy |
| SingleStep 500k | Normal legal flat-memory pre/post and M-cycle bus events; not HALT/STOP/system interrupts |
| Mooneye/Blargg | Interrupt/HALT/timer/DMA/PPU integration, profile-qualified |
| independent emulator | Randomized instruction/system differential traces |
| physical hardware | Disputed/profile-sensitive behavior, especially STOP |
| Lean proofs | Internal decoder/equation/microprogram/refinement correctness |

## Documentation/specification changes

1. Added the local pinned clone and artifact hashes.
2. Added the complete implementation reference.
3. Added a durable full-row audit tool.
4. Rejected JSON display fields as semantics.
5. Added exact x/y/z base/CB decoder tables.
6. Added all arithmetic/flag equations and M-cycle family schedules.
7. Resolved timing units with distinct types.
8. Made STOP profile-sensitive and HALT/invalid non-normal.
9. Added generated-catalogue provenance and theorem matrix.
10. Split normal flat-memory versus system/hardware conformance.

## Remaining blockers

- no `sm83-lean` repository/package exists yet;
- package license and Lean toolchain are not selected;
- no Lean decoder, executor, proofs, or generated catalogue exists;
- the Game Boy bus's four-T-cycle sample/commit relation is not encoded;
- first hardware profile and independent emulator remained unselected in this pass; the eleventh pass selects DMG-CPU B and SameBoy;
- STOP profiles remain intentionally open outside the Pokémon-unreachable theorem;
- no canonical Red ROM/symbol artifacts exist.

No Lean processor implementation was added in this pass. The implementation contract is now explicit enough to begin without importing ambiguous JSON fields or silently inventing missing hardware behavior.
