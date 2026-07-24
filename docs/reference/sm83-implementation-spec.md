# SM83 implementation specification

<!-- mode: reference -->

## Status and purpose

This document turns the standalone-package architecture into an implementation contract. It specifies the normalized instruction representation, complete decoder, architectural effects, flag equations, M-cycle bus schedules, control states, metadata ingestion, and proof gates for `sm83-lean`.

It is grounded first in the pinned local `gbdev/gb-opcodes` clone and then in independent references where that catalogue is incomplete or display-oriented. It does **not** treat one JSON file as a formal hardware specification. Physical IR/prefetch overlap, pin/address/IDU behavior, clock gates, and profile ownership are specified separately in [SM83 microarchitecture and system-boundary contract](sm83-microarchitecture-contract.md).

## Pinned opcode catalogue

| Property | Value |
|---|---|
| Repository | `https://github.com/gbdev/gb-opcodes.git` |
| Local checkout | `../gb-opcodes` |
| Commit | `376f61c86fdac2048f7ce5fe838ae756b306017e` |
| Commit date | 2024-12-13 |
| License | CC0 1.0 Universal |
| `Opcodes.json` SHA-256 | `e7e3cd657d8e87b44570474eb3a6ed735501c9a00520f3d6937881203c823bc5` |
| `OpcodeDescriptions.json` SHA-256 | `ac0eeea25360ea93555ba8e53d8f49f25ee4bfb7ab052466053b18abe94ec079` |
| `collections/_optables/errata.md` SHA-256 | `e03a589cfe2dba5690c61fbdde4b0ea17d4948cef584c4d62f9410720a5b216c` |
| `LICENSE` SHA-256 | `36ffd9dc085d529a7e60e1276d73ae5a030b020313e6c5408593a6ae2af39673` |

Run the durable audit with:

```sh
python3 tools/audit-gb-opcodes.py
# Optional 500,000-case cycle-total cross-check:
python3 tools/audit-gb-opcodes.py --single-step-root ../sm83
```

The script rejects commit/hash/schema/key/family/length/cycle/flag drift. It independently classifies all byte values from their encoding fields and compares every JSON row's mnemonic, length, T-cycle totals, and flag policy. With the optional pinned SingleStep checkout, it checks all 500,000 case totals and confirms HALT/STOP are the only ordinary-total disagreements. The broader physical-source audit command and exact limitations are in the [microarchitecture contract](sm83-microarchitecture-contract.md).

## What the clone contains

`Opcodes.json` has two ordered objects:

- `unprefixed`: exactly keys `0x00` through `0xFF`;
- `cbprefixed`: exactly keys `0x00` through `0xFF`.

Every row has:

```text
mnemonic, bytes, cycles, operands, immediate, flags
```

Every flag object is ordered `Z N H C`. Cycle counts are **T-states/system clock ticks**, not 1 MHz M-cycles. Every listed duration is divisible by four.

### Exact distributions

| Catalogue set | Lengths | T-cycle rows |
|---|---|---|
| Base | 213 × 1 byte; 26 × 2 bytes; 17 × 3 bytes | 145 × 4; 60 × 8; 15 × 12; 18 × 16; 1 × 20; 1 × 24; four each of 12/8, 20/8, 16/12, 24/12 |
| CB | 256 × 2 bytes | 224 × 8; 8 × 12; 24 × 16 |

The 16 two-duration base rows are exactly four conditional JR, four RET, four JP, and four CALL forms. The first/larger value is the taken duration.

### Mnemonic counts

| Base mnemonic | Count | Base mnemonic | Count |
|---|---:|---|---:|
| `LD` | 88 | `LDH` | 4 |
| `ADD` | 14 | `ADC` | 9 |
| `SUB` / `SBC` / `AND` / `XOR` / `OR` / `CP` | 9 each | `INC` / `DEC` | 12 each |
| `JR` | 5 | `JP` | 6 |
| `CALL` / `RET` | 5 each | `RST` | 8 |
| `POP` / `PUSH` | 4 each | every remaining legal named singleton | 1 each |
| `PREFIX` | 1 | `ILLEGAL_xx` | 11 |

| CB family | Count |
|---|---:|
| RLC/RRC/RL/RR/SLA/SRA/SWAP/SRL | 8 each |
| BIT/RES/SET | 64 each |

## Catalogue limitations that affect implementation

The JSON is a checked reference input, not an executable semantic schema.

### No schema, generator, or test suite

The repository has no README at the pinned commit, no JSON Schema, no generator for `Opcodes.json`, and no catalogue tests. Git history shows direct table edits. `OpcodeDescriptions.json` describes only NOP and the four `LD r16,n16` rows—five base opcodes total—and has no `cbprefixed` object. It cannot supply instruction semantics.

Open catalogue issues relevant to ingestion:

| Issue | Consequence |
|---|---|
| `gbdev/gb-opcodes#3` | PREFIX byte/cycle totals can be misunderstood as separate versus included |
| `#9` and `#10` | `immediate` field name/values are semantically ambiguous/inconsistent |
| `#31` | STOP byte count is disputed by actual fetch/stop behavior |
| `#39` | F8's SP `increment` field is ambiguous and must not mean SP mutation |

### `immediate` is display-oriented and ambiguous

There are two `immediate` fields: one on each row and one on each operand. The website uses operand `immediate == false` to add square brackets. It therefore means roughly “render as indirect” rather than “encoded immediate operand.”

Open issues document the ambiguity/inconsistency. The implementation must ignore both `immediate` fields when constructing semantic operands. Encoded immediate width comes from the decoder family, cross-checked against operand `bytes` only.

### Opcode `$F8` contains a rendering hack

The JSON represents `LD HL,SP+e8` with three operands and sets `increment: true` on SP. Open issue #39 notes that interpreting this literally would incorrectly mutate SP. The website special-cases `$F8` when rendering.

The normalized decoder emits exactly:

```text
ldHLFromSPPlus (offset : UInt8)
```

It never imports the JSON `increment` flag.

### Prefix timing is additive/display metadata

Base `$CB` is listed as `PREFIX`, one byte and four T-cycles. Every CB row is already listed as a complete two-byte instruction with totals of 8/12/16 T-cycles. The core fetches the prefix and subopcode, but a completed CB instruction uses the CB row total exactly once. `$CB` does not retire as an independent instruction.

### STOP metadata is disputed and profile-sensitive

The pinned JSON says `$10` is two bytes and four T-cycles. The rendered page says the second byte is ignored. The repository's errata page says STOP is one byte, while open issue #31 explains why it can appear one- or two-byte depending on whether STOP actually stops. Current Pan Docs describes several profile/input-sensitive outcomes.

Therefore:

- the JSON STOP length/duration is retained as catalogue metadata only;
- the decoder captures the byte following `$10` without assuming it is always discarded;
- execution dispatches through a total `StopProfile` transition;
- the Pokémon proof establishes STOP is unreachable from the battle-driver closure, so no unproved STOP profile enters that theorem;
- no package-wide “all hardware profiles verified” claim is made until STOP profiles are separately closed.

### HALT and invalid timing are not completion times

HALT is listed as four T-cycles, which describes entry, not the unbounded wait. The 11 invalid rows are listed as one byte/four T-cycles with preserved flags, but hardware enters lockup rather than retiring a normal four-cycle instruction. PREFIX likewise does not retire alone.

The runtime semantics handles HALT, PREFIX, and lockup as control states. Their JSON rows are never fed through the normal completed-instruction executor.

### Specialized flag rows

The catalogue simplifies four A-on-A operations:

| Opcode | Operation | Catalogue ZNHC | Reason |
|---|---|---|---|
| `$97` | `SUB A,A` | `1100` | Result and flags are statically known |
| `$9F` | `SBC A,A` | `Z1H-` | New H/C equal incoming carry; C is therefore preserved |
| `$AF` | `XOR A,A` | `1000` | Always zero |
| `$BF` | `CP A,A` | `1100` | Comparison is always equal |

The semantic executor still uses the generic ALU equations. Metadata-agreement theorems prove these specialized policies as corollaries.

## Grounding hierarchy

Every implementation claim gets one of these dispositions:

| Level | Evidence | Use |
|---|---|---|
| G0 | Pinned cloned bytes and hash | Exact catalogue identity |
| G1 | `gb-opcodes` plus Pan Docs/RGBDS agreement | Decoder shape, names, lengths, totals, public flag policy |
| G2 | SingleStep/Blargg/emulator differential traces | Architectural state and bus-order validation |
| G3 | Mooneye/GB CTR/physical hardware | Interrupt, HALT/STOP, timer/DMA, model-sensitive behavior |
| Internal proof | Lean declarative/executable equivalence | Ensures our implementation satisfies our stated semantics |

No external reference becomes a theorem premise merely by being cited. Disagreements are recorded and adjudicated; they are not resolved by silently choosing the fixture that makes CI green.

## Numeric and state types

Use distinct types instead of unlabelled `Nat` values:

```lean
abbrev Byte := BitVec 8
abbrev Word := BitVec 16
structure TCycles where value : Nat
structure MCycles where value : Nat
```

Prove `MCycles.toT m = 4 * m`. Catalogue import produces `TCycles`; microprogram length produces `MCycles`; row-agreement proves equality after conversion.

### Architectural registers

```lean
structure Flags where
  z : Bool
  n : Bool
  h : Bool
  c : Bool

structure Registers where
  a b c d e h l : Byte
  flags : Flags
  sp pc : Word
```

Provide total pair codecs for BC/DE/HL and constrained AF. `encodeFlags` always clears bits 0–3; `POP AF` decodes only bits 7–4.

### Core control state

```text
runMode : running | halted | stopped(profileState) | locked(opcode)
ime : Bool
scheduledImeEnable : explicit delayed-EI state
haltBug : whether next ordinary opcode fetch suppresses normal PC increment
phase : bootstrap-fetch | execute(fetched IR, microprogram index) | interrupt-entry
IR byte, IR source address, and valid bit
CB-prefix, W/Z-style immediate/address, data, condition, ALU-carry, and IDU latches
prefetch address and increment-suppression state
```

The public architectural projection hides only proved micro-latches. It never hides IME, delayed enable, run mode, PC/SP, or HALT-bug state.

## Normalized operand types

```text
Reg8      = B | C | D | E | H | L | A
Target8   = reg(Reg8) | atHL
Reg16     = BC | DE | HL | SP
Stack16   = BC | DE | HL | AF
Mem16     = atBC | atDE | atHLInc | atHLDec
Condition = NZ | Z | NC | C
AluOp     = ADD | ADC | SUB | SBC | AND | XOR | OR | CP
CbRotate  = RLC | RRC | RL | RR | SLA | SRA | SWAP | SRL
BitIndex  = Fin 8
RstVector = 0x00 | 0x08 | 0x10 | 0x18 | 0x20 | 0x28 | 0x30 | 0x38
```

Encoding maps are fixed:

| Code | r8/Target8 | r16 | Mem16 | Stack16 | Condition | ALU | CB rotate |
|---:|---|---|---|---|---|---|---|
| 0 | B | BC | BC | BC | NZ | ADD | RLC |
| 1 | C | DE | DE | DE | Z | ADC | RRC |
| 2 | D | HL | HL+ | HL | NC | SUB | RL |
| 3 | E | SP | HL− | AF | C | SBC | RR |
| 4 | H | — | — | — | — | AND | SLA |
| 5 | L | — | — | — | — | XOR | SRA |
| 6 | `[HL]` | — | — | — | — | OR | SWAP |
| 7 | A | — | — | — | — | CP | SRL |

## Normalized instruction constructors

The semantic AST uses legal-family constructors rather than arbitrary mnemonic/operand strings:

```text
nop
ld16Imm(Reg16, Word)
ldMem16A(Mem16) / ldAFromMem16(Mem16)
ldAbsSP(Word)
inc16(Reg16) / dec16(Reg16) / addHL(Reg16)
inc8(Target8) / dec8(Target8)
ld8Imm(Target8, Byte)
accRotate(RLCA | RRCA | RLA | RRA)
daa / cpl / scf / ccf
jr(Byte) / jrCond(Condition, Byte)
stop(Byte, StopContext)
ld8(Target8, Target8, proof not [HL]→[HL])
halt
aluA(AluOp, Target8) / aluAImm(AluOp, Byte)
retCond(Condition) / ret / reti
pop(Stack16) / push(Stack16)
jpCond(Condition, Word) / jp(Word) / jpHL
callCond(Condition, Word) / call(Word)
rst(RstVector)
ldhImmA(Byte) / ldhAImm(Byte)
ldhCA / ldhAC
ldAbsA(Word) / ldAAbs(Word)
addSP(Byte) / ldHLFromSPPlus(Byte) / ldSPHL
di / ei
cbRotate(CbRotate, Target8)
bit(BitIndex, Target8) / res(BitIndex, Target8) / set(BitIndex, Target8)
```

PREFIX and invalid bytes are `DecodeHead` results/control transitions, not legal `Instruction` constructors.

Immediates remain bytes/words in the AST. Relative/sign interpretation occurs only in JR and signed-SP semantics. This preserves original bytes and avoids losing the distinction between `$FF` and mathematical `-1`.

## Complete base decoder

For opcode byte `o`, define:

```text
x = o >> 6
y = (o >> 3) & 7
z = o & 7
p = y >> 1
q = y & 1
```

### `x = 0`

| `z` | Decode |
|---:|---|
| 0 | `y=0 NOP`; `1 LD [a16],SP`; `2 STOP`; `3 JR e8`; `4..7 JR cond[y-4],e8` |
| 1 | `q=0 LD r16[p],n16`; `q=1 ADD HL,r16[p]` |
| 2 | `q=0 LD [Mem16[p]],A`; `q=1 LD A,[Mem16[p]]` |
| 3 | `q=0 INC r16[p]`; `q=1 DEC r16[p]` |
| 4 | `INC Target8[y]` |
| 5 | `DEC Target8[y]` |
| 6 | `LD Target8[y],n8` |
| 7 | y-indexed `RLCA RRCA RLA RRA DAA CPL SCF CCF` |

### `x = 1`

- `y=6,z=6`: HALT.
- Otherwise `LD Target8[y],Target8[z]`.
- The excluded pair is exactly the otherwise-illegal `[HL]←[HL]` encoding.

### `x = 2`

`ALU[y] A,Target8[z]`.

### `x = 3`

| `z` | Decode |
|---:|---|
| 0 | `y<4 RET cond[y]`; then `LDH [a8],A`, `ADD SP,e8`, `LDH A,[a8]`, `LD HL,SP+e8` |
| 1 | `q=0 POP Stack16[p]`; `q=1`: `RET`, `RETI`, `JP HL`, `LD SP,HL` by p |
| 2 | `y<4 JP cond[y],a16`; then `LDH [C],A`, `LD [a16],A`, `LDH A,[C]`, `LD A,[a16]` |
| 3 | by y: `JP a16`, PREFIX, invalid D3, invalid DB, invalid E3, invalid EB, DI, EI |
| 4 | `y<4 CALL cond[y],a16`; otherwise invalid E4/EC/F4/FC |
| 5 | `q=0 PUSH Stack16[p]`; `q=1,p=0 CALL a16`; otherwise invalid DD/ED/FD |
| 6 | `ALU[y] A,n8` |
| 7 | `RST (8*y)` |

This derives exactly the invalid set:

```text
D3 DB DD E3 E4 EB EC ED F4 FC FD
```

## Complete CB decoder

For the second byte use the same `x/y/z` fields:

| `x` | Decode |
|---:|---|
| 0 | `CbRotate[y] Target8[z]` |
| 1 | `BIT y,Target8[z]` |
| 2 | `RES y,Target8[z]` |
| 3 | `SET y,Target8[z]` |

All 256 second-byte values are legal. `$CB` first fetch changes decode phase; it does not emit an independent completed step.

## Decoder theorem contract

```text
decodeBase : Byte → DecodeHead
decodeCB : Byte → InstructionShape
decodeFetched : fetched bytes → DecodedInstruction
```

Required theorems:

- exact 256/256 totality and determinism;
- base partition `244 legal + prefix + 11 locked`;
- CB partition `256 legal`;
- constructor counts equal the family audit;
- legal length is 1–3 bytes;
- little-endian immediate reconstruction;
- normalized encode/decode round trip;
- no legal encoding reaches a catch-all constructor;
- no invalid encoding becomes NOP;
- metadata projection agrees with every pinned JSON row after applying documented STOP/PREFIX/HALT/invalid and display-field dispositions.

## Architectural arithmetic semantics

All arithmetic is performed with explicit widened naturals followed by truncation to the destination width.

### 8-bit addition

For `carryIn ∈ {0,1}`:

```text
wide = nat(a) + nat(b) + carryIn
result = low8(wide)
Z = result == 0
N = 0
H = nat(a & 0x0f) + nat(b & 0x0f) + carryIn > 0x0f
C = wide > 0xff
```

ADD uses carryIn 0; ADC uses old C.

### 8-bit subtraction/comparison

```text
subtrahend = nat(b) + carryIn
result = low8(nat(a) - subtrahend mod 256)
Z = result == 0
N = 1
H = nat(a & 0x0f) < nat(b & 0x0f) + carryIn
C = nat(a) < subtrahend
```

SUB/CP use carryIn 0; SBC uses old C. CP discards result. These equations also prove the four specialized A-on-A catalogue policies.

### INC and DEC

```text
INC: result=v+1; Z=result==0; N=0; H=(v&0x0f)==0x0f; C preserved
DEC: result=v-1; Z=result==0; N=1; H=(v&0x0f)==0x00; C preserved
```

16-bit INC/DEC affect no flags.

### `ADD HL,r16`

```text
wide = nat(HL)+nat(rhs)
HL = low16(wide)
Z preserved; N=0
H = nat(HL_old & 0x0fff)+nat(rhs & 0x0fff)>0x0fff
C = wide>0xffff
```

### Signed-SP forms

Let `u=nat(offsetByte)` and `signed=signExtend8to16(offsetByte)`:

```text
result = SP + signed mod 65536
Z=0; N=0
H = nat(SP & 0x000f)+nat(u & 0x0f)>0x0f
C = nat(SP & 0x00ff)+u>0xff
```

`ADD SP,e8` writes SP. `LD HL,SP+e8` writes HL and leaves SP unchanged.

### Logic

| Operation | Result | ZNHC |
|---|---|---|
| AND | `A & rhs` | `Z010` |
| XOR | `A xor rhs` | `Z000` |
| OR | bitwise OR of `A` and `rhs` | `Z000` |
| CPL | `~A` | Z preserved, `11`, C preserved |
| SCF | A unchanged | Z preserved, `001` |
| CCF | A unchanged | Z preserved, `00`, C complemented |

### DAA

Let initial state be `a,n,h,c`.

- If N=1: correction is `(H ? 0x06 : 0) + (C ? 0x60 : 0)`; subtract it; C is preserved.
- If N=0: include `0x06` when H=1 or low nibble of A exceeds 9; include `0x60` and set C when old C=1 or A exceeds `0x99`; add the correction.
- Set Z from adjusted A, preserve N, clear H, and use the C rule above.

Prove the executable DAA function against this relation for all 2048 relevant A/N/H/C inputs, prove independence from old Z, and check all 4096 old-A/ZNHC rows in the pinned Mooneye hardware table—not only valid BCD histories.

## Rotate, shift, and bit semantics

For CB forms, Z reflects the result; N=0 and H=0. Accumulator-only RLCA/RRCA/RLA/RRA force Z=0.

| Operation | Result | C |
|---|---|---|
| RLC | `(v<<1)` OR `bit7(v)` | old bit 7 |
| RRC | `(v>>1)` OR `(bit0(v)<<7)` | old bit 0 |
| RL | `(v<<1)` OR `oldC` | old bit 7 |
| RR | `(v>>1)` OR `(oldC<<7)` | old bit 0 |
| SLA | `v<<1` | old bit 7 |
| SRA | `(v>>1)` OR `(v&0x80)` | old bit 0 |
| SWAP | `(v<<4)` OR `(v>>4)` | 0 |
| SRL | `v>>1` | old bit 0 |

`BIT i,v` leaves v unchanged and sets `Z=!bit_i(v), N=0, H=1, C=oldC`. RES/SET alter only the selected bit and preserve every flag.

## Load and address semantics

- All immediate 16-bit values are fetched low byte then high byte.
- HLI/HLD use original HL for the bus access, then increment/decrement HL modulo 65536.
- `LD [a16],SP` writes low SP at `a16`, then high SP at `a16+1 mod 65536`.
- `LDH [a8],A` and `LDH A,[a8]` use `$FF00 | a8`.
- `LDH [C],A` and `LDH A,[C]` use `$FF00 | C`.
- Register-to-register self-loads are architectural no-ops but still fetch/retire normally.
- `POP AF` reads low byte first, masks its low nibble, then reads A; PUSH AF always emits a low flag nibble of zero.
- `[HL]` values are read at their specified bus cycle, never snapshotted at decode time.

## Control-flow semantics

- Conditions read current flags: NZ=`!Z`, Z=`Z`, NC=`!C`, C=`C`.
- JR adds signed e8 to PC **after** the offset byte fetch.
- JP writes the fetched 16-bit target.
- CALL pushes the PC after both immediate bytes: initial IDU decrement, high write with second decrement, low write, then target transfer/fetch.
- RST uses the same two-decrement high/low stack sequence and jumps to its fixed vector.
- POP/RET read stack low byte then high byte while incrementing SP after each read.
- RETI performs RET and enables IME with RETI's immediate behavior.
- Every address and PC/SP update wraps modulo 65536.

## M-cycle bus vocabulary

The processor package steps one physical, fetched-IR M-cycle at a time. Every M-cycle carries exactly four CPU T-cycles. Its output includes address drive, read/write/idle control, data direction/value, fetch provenance, IDU intent, commit set, interrupt-poll kind, and clock intent. The selected Game Boy adapter expands it through `T1F T1R T2F T2R T3F T3R T4F T4R`, supplies phase-indexed read/pending values, and proves the four-T-cycle device expansion and stable-read reduction; see [DMG-CPU B profile](dmg-cpu-b-profile.md).

The abbreviations below describe the **de-overlapped architectural projection** used by programmer timing and SingleStep:

```text
F      opcode fetch at PC
CB     CB second-byte fetch at PC
L/H    little-endian immediate low/high fetch
E      immediate e8/n8/a8 fetch
R(x)   data read
W(x,v) data write
I      family-specific internal cycle with no read/write request; address/IDU/commit intent remains explicit
SH     write stack high at current SP, then post-decrement SP
SL     write stack low at current SP without a third decrement
PL/PH  stack read low/high at current SP, then post-increment SP
```

F/CB/L/H/E increment PC unless the explicitly modeled HALT-bug/fetch behavior says otherwise. In every PUSH/CALL/RST schedule, the `I` before `SH` performs the first SP decrement; `SH` performs the second after its high write; `SL` writes at the resulting SP. There are exactly two decrements. Internal cycles apply the profile's clock-domain intent rather than blindly advancing every device.

## Complete normal-instruction logical bus schedules

| Family | M-cycle sequence | T-cycles |
|---|---|---:|
| NOP; register INC/DEC/ALU/logic; accumulator rotate; DAA/CPL/SCF/CCF; DI/EI; JP HL | `F` | 4 |
| `LD r8,r8` register→register | `F` | 4 |
| `LD r8,[HL]`; ALU A,[HL] | `F R(HL)` | 8 |
| `LD [HL],r8` | `F W(HL)` | 8 |
| `INC/DEC [HL]` | `F R(HL) W(HL,result)` | 12 |
| `LD r8,n8` | `F E` | 8 |
| `LD [HL],n8` | `F E W(HL)` | 12 |
| `LD r16,n16` | `F L H` | 12 |
| `LD [BC/DE/HLI/HLD],A` | `F W(address)` | 8 |
| `LD A,[BC/DE/HLI/HLD]` | `F R(address)` | 8 |
| `INC/DEC r16`; `ADD HL,r16`; `LD SP,HL` | `F I` | 8 |
| `LD [a16],SP` | `F L H W(addr,loSP) W(addr+1,hiSP)` | 20 |
| `LD [a16],A`; `LD A,[a16]` | `F L H W/R(addr)` | 16 |
| `LDH [a8],A`; `LDH A,[a8]` | `F E W/R(FF00+E)` | 12 |
| `LDH [C],A`; `LDH A,[C]` | `F W/R(FF00+C)` | 8 |
| `ADD/ADC/SUB/SBC/AND/XOR/OR/CP A,n8` | `F E` | 8 |
| `ADD SP,e8` | `F E I I` | 16 |
| `LD HL,SP+e8` | `F E I` | 12 |
| JR e8 | `F E I` | 12 |
| JR cc,e8 | untaken `F E`; taken `F E I` | 8/12 |
| JP a16 | `F L H I` | 16 |
| JP cc,a16 | untaken `F L H`; taken `F L H I` | 12/16 |
| CALL a16 | `F L H I SH SL` | 24 |
| CALL cc,a16 | untaken `F L H`; taken `F L H I SH SL` | 12/24 |
| PUSH rr | `F I SH SL` | 16 |
| POP rr | `F PL PH` | 12 |
| RET | `F PL PH I` | 16 |
| RET cc | untaken `F I`; taken `F I PL PH I` | 8/20 |
| RETI | `F PL PH I` plus immediate IME enable | 16 |
| RST vec | `F I SH SL` | 16 |
| CB rotate/shift/RES/SET register | `F CB` | 8 |
| CB BIT register | `F CB` | 8 |
| CB BIT `[HL]` | `F CB R(HL)` | 12 |
| CB rotate/shift/RES/SET `[HL]` | `F CB R(HL) W(HL,result)` | 16 |

The table's sequence length times four is proved equal to every normal legal `gb-opcodes` duration, choosing the proper conditional branch. SingleStep validates this de-overlapped active-bus view. The canonical physical core already holds the executing byte in IR and normally fetches its successor during the final microcycle; a separate sequence-level theorem reassociates those overlapping fetches. SingleStep does not validate physical writeback phase, idle address pins, IDU intent, or discarded prefetches.

## Non-normal control schedules

### PREFIX

When IR contains `$CB`, the decode-ROM/prefix latch selects the CB bank and fetches the subopcode without an interruptible generic-fetch boundary. Only the combined instruction retires. The de-overlapped trace remains `F CB ...`.

### Invalid opcode

When IR contains one of the 11 invalid bytes, decode reaches a state with no generic fetch. The fetch-side PC update has already occurred; there is no normal retirement, subsequent fetch, or interrupt wake. Pin/address and clock behavior while indefinitely locked is profile-qualified. Fuel exhaustion remains distinct from lockup.

### HALT

HALT performs a dummy/non-incrementing pipeline fetch. Let `pending = IE & IF & 0x1f` supplied by the system adapter at the required phase:

- IME=1: enter halted mode; when pending appears, wake and service before the next ordinary instruction.
- IME=0 and pending=0: enter halted mode; wake when pending becomes nonzero but do not service it.
- IME=0 and pending≠0 at execution: do not remain halted; arm the HALT-bug fetch behavior.

HALT emits a clock-gate/wake state rather than ordinary idle instructions. The adapter advances only profile-appropriate domains; PPU/timer wake behavior and CPU-clocked DMA need not be identical. Four T-cycles is catalogue entry metadata, not total elapsed time. Following one-byte, multibyte, CB, RST, consecutive-HALT, and EI/HALT sequences have dedicated theorems listed in the microarchitecture contract.

### STOP

STOP transitions through `StopProfile.step(context, prefetchedByte, systemInputs)`. The context includes hardware model/revision, P1/button/WAKE lines, KEY1/speed state where applicable, DIV/LCD/clock state, interrupt/IME phase, and current fetch phase. The profile covers all seven Pan Docs outcome classes, including one-/two-byte appearance, STOP/HALT/continue modes, DIV reset, speed change, and an explicit relation for unstable behavior. Every deterministic selected profile supplies separate conformance evidence; canonical Red proves STOP unreachable.

## IME and interrupt sequencing

IME state must support these machine-checked sequence properties:

- DI immediately suppresses its overlapping poll, sets IME=0, and cancels staged EI enable.
- EI's latch becomes usable only at the later hardware poll phase; it is not a high-level immediate write.
- `EI;DI` services no interrupt.
- with a pending request, `EI;NOP` services after NOP and `EI;EI` services after the second EI; the latter preserves the first EI's maturation rather than postponing forever.
- `EI;HALT`, EI followed by taken control flow, and EI/HALT/RST use explicit pipeline sequence theorems.
- RETI enables before its target generic fetch so another pending request can preempt the returned-to opcode.

Normal interrupt dispatch begins after an eligible generic prefetch detects a request. The fetched byte is discarded; because PC is already ahead, entry consists of five M-cycles:

1. correct PC to the discarded prefetch address;
2. perform the initial SP-decrement/internal phase;
3. write return-PC high and apply the next stack update;
4. write return-PC low, resolve vector/acknowledgement state, and transfer PC;
5. fetch from the selected vector or cancellation target.

IME is cleared on acceptance. The pending mask is resampled at the required microphase. Mooneye `interrupts/ie_push` requires non-atomic behavior when a stack write hits `$FFFF`:

- with initial SP `$0000`, the upper-byte IE write can cancel dispatch to `$0000` or retarget to a newly highest enabled request;
- cancellation leaves IME disabled and preserves the original IF request;
- retargeting acknowledges the newly selected request while disabled higher-priority IF bits remain;
- with initial SP `$0001`, the lower-byte IE write is too late to cancel selection and normal acknowledgement occurs.

The processor port therefore exposes phase-tagged pending-mask/ack interactions during dispatch rather than accepting one frozen vector at instruction boundary. Concurrent software/device IF changes use a profile-defined adapter collision rule.

## Declarative, de-overlapped, and physical semantics

Define three independent artifacts:

```text
InstrRel : architectural state → decoded instruction → logical bus trace → architectural state → Prop
instrStep : de-overlapped state → flat-bus response → de-overlapped state
microStep : fetched-IR CoreState → phase-tagged CoreInput → CoreState × CycleIntent
```

`InstrRel` directly states the equations and ordered logical accesses. `instrStep` is the executable view used by SingleStep and leaf proofs. `microStep` executes the physical IR/prefetch pipeline, IDU/address intent, commit phases, interrupts, and clock control.

The central theorems prove:

- `instrStep` refines `InstrRel` for every legal family;
- physical sequence execution refines the de-overlapped byte-program runner under `PipelineWellFormed`, with fetch-overlap trace reassociation;
- architectural state/read-write projection and CPU T-cycle totals agree;
- exceptional DI/EI/RETI/HALT/STOP/lock/interrupt boundaries satisfy dedicated relations rather than a false ordinary-instruction equation.

Definitions may share low-level bit-vector lemmas, but not one common instruction executor that makes equivalence true by reduction.

## Catalogue ingestion design

The production Lean decoder does not parse JSON at runtime. A generator may emit a frozen `CatalogueRow[512]` test artifact containing:

```text
set, opcode, normalized mnemonic, length, taken/untaken TCycles,
flag write policy, source commit, source JSON hash
```

Rules:

- semantic constructors/operands come from the encoding decoder, not JSON strings;
- JSON operand `immediate`, `increment`, and `decrement` are excluded;
- STOP/HALT/PREFIX/invalid rows carry explicit non-normal dispositions;
- the four specialized A-on-A flag rows are preserved in catalogue projection;
- generated rows include source commit/hash and are reproducible;
- Lean proves decoder metadata projection equals the frozen rows;
- `tools/audit-gb-opcodes.py` fails before generation on source drift.

## Proof inventory by module

| Module | Required definitions/proofs |
|---|---|
| `Byte` | truncation, sign extension, high/low combine/split |
| `Flags` | codec, low nibble zero, preservation/update algebra |
| `Registers` | pair get/set, AF masking, noninterference |
| `Instruction` | normalized constructors and finite operand codes |
| `Decode` | x/y/z decoder, complete partition/counts, lengths |
| `Encode` | legal normalized encoding and round trips |
| `Alu` | all equations above, exhaustive finite checks as theorems |
| `Bus` | address/data/control pins, active and idle events, fetch provenance, phase-tagged responses |
| `IDU` | source/direction/destination intent and address-drive projection |
| `Cycle` | every family microprogram, commit set, and catalogue duration equality |
| `Pipeline` | IR/bootstrap/prefetch overlap, W/Z latches, boundary well-formedness, trace reassociation |
| `Interrupt` | staged EI, DI poll suppression, RETI, priority, five-cycle dispatch, IE-push behavior |
| `Clock` | CPU T/M units and generic clock-gate intent; no Game Boy device imports |
| `Profile` | HALT/common behavior and explicit seven-outcome STOP profile interface |
| `Functional` | declarative relation and independent de-overlapped executable runner |
| `Run` | physical M-cycle, projected instruction, and sequence runners plus result taxonomy |
| `Program/Hoare` | fetched-byte runs, return sentinels, frame composition |
| `FlatMemory` | side-effect-free adapter and functional/microcycle theorem |
| `Catalogue` | pinned 512-row metadata projection and provenance |

## Required theorem matrix

For each of the 500 legal opcode entries, generated theorem indexing must establish:

```text
decode bytes = constructor
encoded length = catalogue length
normal completion cycles = catalogue branch total
flag write policy refines catalogue policy
functional relation agrees with executable flat-bus run
bus event shape belongs to the specified family schedule
```

For PREFIX, HALT, STOP, and 11 invalid rows, establish the corresponding non-normal control theorem instead of a normal completion theorem.

Global theorems include:

- decoder base/CB totality and disjointness;
- 244/1/11 and 256 cardinality;
- every legal row has exactly one semantic family;
- every family schedule has expected read/write count;
- normal T-cycles are multiples of four;
- conditional taken duration exceeds untaken duration by the expected M-cycles;
- typed flags remain well-formed;
- deterministic transition for valid bus response, except explicitly relational unstable STOP profiles;
- bootstrap/fetched-boundary well-formedness and physical/de-overlapped sequence refinement;
- complete 101-family physical microstate, address-drive, IDU, commit, and interrupt-poll coverage;
- HALT clock-gate and following-byte sequence properties; seven-outcome STOP disposition;
- enough IDU trace information for the Game Boy adapter's OAM-corruption theorem;
- no test/parser module occurs in public proof dependencies;
- public roots contain no `sorry`, `admit`, or undeclared axioms.

## Conformance policy

### gb-opcodes

Checks identity, decode presentation, lengths, total T-cycles, and public flag policy. It does not validate ALU equations, microcycle addresses/data, interrupts, or stop/lock behavior.

### SingleStepTests

Run all 500,000 flat-memory cases for normal legal instructions. Compare pre/post registers, architectural flags, PC/SP, touched memory, and the de-overlapped active-bus sequence. Quarantine HALT and STOP from ordinary cycle-total comparison: the pinned corpus emits three M-cycle placeholders for each, conflicting with the gb-opcodes four-T-state entry metadata and lacking system wake context. Ignore IE/IME sequence claims. `---` addresses/data are convenience values, not physical idle-pin evidence. DI/EI vectors are useful only for local state; sequence tests remain mandatory.

### Mooneye/Blargg/system tests

Run through the Game Boy adapter for all 4096 DAA A/ZNHC rows, EI/DI, interrupt timing and IE-push cancellation, HALT, stack/control timing, timer/DIV, OAM DMA, OAM corruption, and PPU restrictions. Respect model suffixes and clock domains.

### Independent emulator/hardware

Differentially trace all 500 legal entries plus interrupt/HALT sequences at boundary values and random states. Physical hardware evidence resolves disputed profile behavior such as STOP. Neither oracle is a theorem premise.

## Implementation order

1. Check in package license/toolchain and catalogue provenance constants.
2. Implement finite operand types and x/y/z decoder.
3. Prove exact partition, constructor counts, lengths, and encode/decode.
4. Implement flags/register codecs and pure ALU relation with exhaustive theorems.
5. Implement the independent declarative and de-overlapped instruction views; stream normal SingleStep vectors.
6. Implement typed pin/IDU/clock intents, IR bootstrap/prefetch state, and all 101 normal physical family microprograms.
7. Prove schedule totals, commit/address/IDU coverage, and physical/de-overlapped sequence refinement.
8. Implement staged IME, five-cycle interrupts, HALT, invalid lock, and seven-outcome STOP profile interface.
9. Compose the profile-qualified Game Boy adapter and run DAA/interrupt/HALT/OAM/timer/PPU integration ROMs.
10. Prove checkpoint/return/program logic and release/pin `sm83-lean` only after axiom, provenance, and conformance reports pass.

## Completion criterion

The SM83 implementation is fully specified when every byte pair has one decoder disposition, every legal constructor has equations plus logical and physical microprograms, every internal cycle has address/IDU/commit/poll intent, every non-normal byte has an explicit control/clock transition, pipeline initialization/checkpoints are proved, all metadata claims are tied to pinned source bytes with documented exceptions, and all three semantic layers plus profile-qualified conformance gates compile. “Matches `Opcodes.json`” alone is not sufficient.
