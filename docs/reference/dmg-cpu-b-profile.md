# DMG-CPU B console profile and evidence contract

## Purpose

This document resolves the first hardware-profile choice and fixes the evidence boundary for the Game Boy adapter.

The first system theorem targets **DMG-CPU B**, not the previously provisional DMG-CPU C. This is an evidence decision:

- the reverse-engineered `gb-research` SM83 model is based on SGB-CPU 01 and states that its CPU core is equivalent to DMG-CPU B;
- the external-bus and core-connection measurements below were made on DMG-CPU B;
- SameBoy exposes DMG-CPU B as its implemented DMG model while DMG-CPU C remains commented out;
- no equally complete, revision-specific CPU-C timing source was found.

The profile is a family with explicit board/instance parameters, not a claim that every DMG-CPU B unit has identical analog or OAM-glitch behavior.

## Pinned evidence

| Source | Identity | License/use | Role |
|---|---|---|---|
| Gekkio `gb-research` | `59088f486f579a69fd86bd86a55181b937e769e0` | HDL MIT or Apache-2.0; assets CC BY 4.0 | die-derived CPU ports, reset, clock gates, interrupt latches, medium-level phase model |
| LIJI32 SameBoy | `213a12ce93d66b105a113debd9396306066a7cfc` | Expat/MIT | selected independent DMG-B differential oracle, with quarantined TODO paths |
| aappleby GBMicrotest | `463eb6bc0fe31d61781ef63060ad6d74090c0255` | MIT | 513 minimal real-hardware timing fixtures; README says DMG-CPU-08 “I believe”, so not CPU-B-specific evidence |
| [IceBoy memory patterns](http://iceboy.a-singer.de/doc/mem_patterns.html) | HTML SHA-256 `8616eaf3c9f8eea6b165646c66132e3c21995893bb433744948a24ea8aee6716`; Last-Modified 2024-09-17 | citation only; no repository license inferred | DMG-CPU B external bus measurement and eight half-edge sequence |
| [IceBoy core connections](https://iceboy.a-singer.de/doc/dmg_cpu_connections.html) | HTML SHA-256 `e070435eecf2136ea1485ef81c61e27c08885369ff49902fd8cd2cb582ee94db`; Last-Modified 2026-04-13 | citation only; no repository license inferred | die-derived core clocks, reset, NMI, read-fold, writeback, and wake descriptions |
| [GBDev boot-ROM inventory](https://gbdev.gg8.se/files/roms/bootroms/readme.txt) | text SHA-256 `ae9fe35ce9d20ac1b869095645c7c3f7bb3858e36ae2ee0aee14218e84dc62ab`; Last-Modified 2024-12-24 | identity citation only | canonical common DMG boot-ROM hash |

`gb-research` explicitly omits propagation delays and calls its HDL non-synthesizable. SameBoy explicitly marks STOP timing, some IF timing, and parts of OAM behavior unverified. GBMicrotest does not establish the CPU revision of its hardware fixture with confidence. These limits are theorem assumptions, not footnotes.

Audit command:

```sh
python3 tools/audit-sm83-profile-sources.py \
  --gb-research-root /path/to/gb-research \
  --sameboy-root /path/to/SameBoy \
  --microtest-root /path/to/GBMicrotest \
  --web-snapshot-root /path/to/profile-web-snapshots
```

The web snapshot directory contains `mem_patterns.html`, `dmg_cpu_connections.html`, and `bootroms-readme.txt` downloaded from those links with the hashes above. The script rejects dirty Git checkouts, commit/hash drift, missing phase/reset/clock anchors, model-scope changes, hidden SameBoy TODO removal, and fixture-count drift.

## Profile type

A system theorem names a complete value, not just `DMG`:

```lean
structure DmgCpuBProfile where
  socRevision          : SocRevision := .dmgCpuB
  boardRevision        : BoardRevision
  bootRomIdentity      : BootRomIdentity
  oscillatorClass      : OscillatorClass
  resetDelayClass      : ResetDelayClass
  oamInstanceClass     : OamInstanceClass
  externalRamParts     : ExternalRamProfile
  analogTolerance      : AnalogTolerance
```

The first software theorem may quantify over fields proved observationally irrelevant to the projected battle trace. It may not silently choose values for an unresolved field.

The initial concrete release profile is named `DmgCpuBCommonBoot`. It requires:

- DMG-CPU B SoC behavior;
- no CGB mode, KEY1, HDMA, or double-speed path;
- canonical common 256-byte DMG boot ROM with SHA-256 `cf053eccb4ccafff9e67339d4e78e98dce7d1ed59be819d2a1ba2232c6fce1c7` supplied externally;
- NMI physically unavailable;
- maskable interrupt inputs 5–7 inactive;
- explicit board/RAM and OAM-instance parameters.

The copyrighted boot bytes are not vendored. A build accepts caller-supplied bytes only after proving the hash.

## Eight-half-edge M-cycle protocol

A physical M-cycle contains four T-cycles and eight named half edges:

```text
T1F T1R T2F T2R T3F T3R T4F T4R
```

`F` and `R` preserve the measurement source's falling/rising-edge labels. They are distinct from instruction fetch `F` in the logical schedule.

### Measured external-bus sequence

| Half edge | DMG-CPU B external-bus obligation |
|---|---|
| T1F | Drive the new address for external/internal/internal-video accesses. For an external write, deassert external `/RD` and begin driving data; ordinary writes initially drive `$FF`, while measured CALL/RST stack writes may drive the PC byte immediately. Internal writes may show short hazards. |
| T1R | Assert the selected external chip-select signal: cartridge-ROM `A15` behavior or RAM `/CS`. |
| T2F | No required external transition. |
| T2R | For an external write, assert `/WR` and drive the actual write byte. |
| T3F | No required external transition. |
| T3R | Sample external read data. |
| T4F | Deassert external `/WR`. |
| T4R | Restore external `/RD` direction state after a write, deassert chip select, clear external address bits A8–A14 as measured, and release write data. Low address bits retain their last driven value until another access. |

The cartridge connector's active-low `/RD` is also a data-direction control and is not identical to the core's active-high `RD` intent. A theorem must not conflate them.

### Internal phase octet

The pinned `gb-research` test SoC uses the following relative octet:

```text
CLK          0 1 1 1 1 1 1 1
PHI          1 1 1 1 0 0 0 0
MCLK_PULSE   1 0 0 0 0 0 0 0
WRITEBACK    0 0 0 0 0 0 1 1
WRITEBACK_X  1 0 0 0 0 0 1 1
```

This is a medium-level die-derived model, not propagation-delay evidence. The adapter proves alignment between this relative octet and the measured T1F–T4R external sequence. It does not choose a phase origin merely because two signal names look similar.

### Read semantics

The core data bus is dynamic and precharged high. The measured core description says a low bit seen during the read sampling window remains low, so a changing input behaves like a bitwise AND over the window.

The physical response therefore is not only `readByte : UInt8`. It contains a phase-indexed contribution:

```lean
structure ReadResponse where
  driveAt : HalfEdge → ByteDrive
```

The CPU read latch starts at `$FF` after precharge and folds driven contributions over the declared sample window. Stable asynchronous memory reduces to one ordinary byte. A timer/MMIO value changing inside the window need not. External cartridge data is latched at the measured T3R point; internal-bus devices prove their own drive window.

This distinction is required for exact `rDIV`, IF, timer, and simultaneous-device behavior.

### Write semantics

A write request exposes:

```lean
structure WriteIntent where
  addressAt : HalfEdge → UInt16
  dataAt    : HalfEdge → ByteDrive
  coreWrAt  : HalfEdge → Bool
  extWrAt   : HalfEdge → Bool
  provenance : MicroOpProvenance
```

External memory observes the T2R–T4F write window. Core register/flag writeback occurs in the final quarter. Each MMIO register defines its collision point against device writes. There is no global “write happens at end of M-cycle” shortcut.

The existing IF, STAT, palette, LCDC, SCX, and timer collision obligations remain adapter theorems. SameBoy's conflict tables are differential evidence, not semantic input, and paths marked TODO are quarantined.

### Interrupt sample and acknowledgement

For DMG-CPU B:

- the effective IME storage updates on the documented execution-phase edge;
- interrupt latches are enabled during the data phase;
- priority resolution is dynamic during writeback;
- `INTA[0..4]` is asserted in the final writeback quarter;
- `INTA[5..7]` and their inputs are not connected/are inactive in the console;
- the CPU's IE register is internal at `$FFFF`;
- NMI exists in the core but its die pad is not bonded, so the console adapter proves `NMI = false`.

The processor protocol retains eight interrupt lines because the core does. The DMG adapter narrows them to the five console sources.

## Clock domains and gates

The die-derived evidence yields two separate enables:

```text
cpuclk_en  gates execution/data/writeback phases
sysclk_en  gates the machine-cycle/oscillator-derived progression
```

### Running

Both enables are active. CPU, divider/timer, serial, DMA, PPU, and APU advance according to their declared derived domains.

### Link serial completion

A paired transfer has one internal-clock owner. Each cable edge shifts both
active endpoints from their pre-edge output bits. On the eighth edge, both
transfer counters reach zero, SC bit 7 clears, SC bit 0 retains clock selection,
and both serial interrupts are requested. `Battle.GameBoy.LinkAdapter` proves
this for all 65,536 byte pairs; external serial input is never synthesized as an
independent response while a peer is attached.

### HALT

HALT disables most CPU execution/data/writeback clocks while the machine/system clock path continues. The interrupt latch/wake path remains live. Therefore:

- HALT is not repeated execution of an ordinary idle M-cycle;
- DIV/timers and independently clocked devices continue where their profile says they do;
- cartridge PHI is gated and does not necessarily continue merely because wall-clock time passes;
- a pending interrupt re-enables CPU clocks on the documented synchronization edge.

### STOP

On DMG-CPU B, STOP disables both CPU and system oscillator paths, asserts the halt gate, and resets DIV through the SoC path. WAKE re-enables the oscillator immediately, but CPU execution waits for the clock-ready/startup mechanism. The die-derived description gives roughly 32 ms, associated with DIV reaching its half-range; measured reset work reports approximately `2^17` T-cycles with unit-to-unit/run variation.

The first profile therefore represents restart delay as a constrained `ResetDelayClass`, not the CGB 2050-M-cycle constant. KEY1/speed switching is impossible in this profile.

The CGB conflict between approximately `$20000` T-cycles and 2050 M-cycles is removed from the first theorem rather than guessed. It remains a future CGB-profile obligation.

### Invalid-opcode lock

An invalid opcode enters the decoder's all-zero/no-fetch state. It is distinct from HALT and STOP:

- no successor opcode fetch occurs;
- no interrupt completes it;
- CPU/system clocks are not reclassified as HALT/STOP clocks merely to simplify the model;
- reset/power behavior and externally retained pin levels are profile transitions.

Exact locked address/data/control levels are not established by the pinned evidence. The DMG-B profile exposes a constrained relational `LockedPins` state: no `RD`, `WR`, `MREQ`, `M1`, or interrupt-ack transaction may be invented, while retained analog levels remain nondeterministic until measured. Canonical Red closure must prove that no reachable decoded instruction enters this state, so this relation cannot affect the battle theorem.

## Reset and boot

### Power-on reset

The evidence distinguishes two resets:

1. asynchronous power-on reset initializes clock-control outputs so the oscillator can start;
2. synchronous system reset sets PC and IE to zero and puts the sequencer into initial fetch.

Other programmer registers, including IR, are not reset by the core. During the initial fetch an arbitrary old IR may decode in parallel, but the reset sequencer state prevents its jump or memory actions. The formal state therefore uses:

```lean
structure PowerOnSeed where
  pc       : UInt16 := 0
  ie       : UInt8 := 0
  ir       : UInt8
  regs     : UnresetRegisters
  sequencer : ResetFetchWitness
  cpuGate  : GateState
  sysGate  : GateState
```

Unreset fields are universally quantified or supplied by a measured seed; they are not initialized to familiar emulator constants.

### Boot proof

The boot theorem:

1. verifies the externally supplied 256 bytes by SHA-256;
2. starts from `PowerOnSeed` plus profile startup timing;
3. executes the physical fetched-IR core and SoC adapter;
4. proves the cartridge handoff pipeline witness at `$0100`;
5. derives register/MMIO/VRAM state rather than assuming a folklore post-boot table.

WRAM/OAM power-up contents remain profile relations where the boot ROM does not overwrite them. A later canonical-game initialization theorem proves the stronger reset image needed by standalone battle entry.

The external-bus measurement reports 57,358 instruction-table machine cycles before the first visible external line transition because early boot execution accesses boot ROM and VRAM internally. This is a trace checkpoint, not the startup-delay measurement.

## OAM instance behavior

The simple read/write OAM equations remain valid baseline cases, but newer SameBoy source records additional tertiary/quaternary transforms, instance-specific row copies, and nondeterministic DMG cases. Consequently, `DMG-CPU B` alone is not a complete OAM corruption profile.

The adapter separates:

```lean
inductive OamInstanceClass
  | measuredDeterministic (fixture : FixtureId)
  | permittedDmgBFamily
```

A deterministic fixture imports a signed hardware-capture manifest. The family relation permits only reviewed DMG-B transforms. The battle refinement must prove either:

- exact OAM behavior for the selected fixture; or
- that variation is erased by the presentation projection and cannot affect controller sampling, timing, DMA, interrupts, or battle-visible memory.

The previously documented two-row equations are not claimed to cover every row/instance case.

## Independent oracle policy

SameBoy at the pinned Expat-licensed commit is the selected independent emulator oracle for DMG-B system traces. It is consumed as an external executable, not copied into Lean and not used to define semantics.

### Accepted oracle observations

- instruction/checkpoint PC, registers, flags, SP, IME;
- mapped memory and MMIO observations;
- cycle counts and projected interrupt events;
- PPU mode/LY, timer/divider, DMA, serial, joypad, and frame checkpoints;
- canonical-ROM semantic-response/RNG projections.

### Quarantined as authority

SameBoy may still produce traces for these paths, but they cannot discharge profile proof obligations:

- STOP byte timing and speed switching;
- exact IF triple-collision timing where its source says TODO;
- invalid-opcode locked pins;
- OAM cases marked untested, simplified, revision-specific, or nondeterministic;
- propagation-delay or analog-bus claims;
- DMG-CPU C behavior.

### Triangulation

The conformance stack is:

1. encoding-derived Lean semantics against gb-opcodes metadata;
2. de-overlapped runner against 500,000 SingleStep fixtures;
3. physical core against pinned `gb-research` HDL waveforms for supported digital paths;
4. SoC adapter against SameBoy projected traces outside quarantine;
5. ROM fixtures against Mooneye, GBMicrotest, and measured DMG-B hardware;
6. canonical Red checkpoints across all three executable systems.

Agreement between two software models is evidence, never proof of hardware truth.

## Physical-hardware validation procedure

Capture bundles use [`tools/hardware-capture-manifest.schema.json`](../../tools/hardware-capture-manifest.schema.json). Before import, run:

```sh
python3 tools/validate-hardware-capture.py capture/manifest.json \
  --artifact-root capture
```

The validator checks the exact profile/SoC/boot identity, complete external channel set, minimum digital sample rate, path containment, every retained file hash, unique run/claim references, two independent analysis hashes, repeated deterministic claims, and 256-run minimum for deterministic reset claims. A schema-valid manifest without matching retained artifacts is rejected.

### Fixture identity

Each capture manifest records:

- console serial number and photographs;
- SoC marking `DMG-CPU B` and package type;
- mainboard revision and RAM/VRAM/amplifier markings;
- cartridge/interposer revision and FPGA bitstream hash;
- boot-ROM identity method;
- power supply, temperature range, probe loading, analyzer model, sample rate, and calibration trace;
- ROM source hash, built ROM hash, assembler/tool hashes;
- raw capture hashes and analysis-script hash.

A board label such as DMG-CPU-08 does not substitute for reading the SoC revision.

### External bus rig

Use a cartridge interposer/FPGA that captures at least:

```text
PHI, /RD, /WR, /CS, A0..A15, D0..D7, RESET
```

and provides programmable ROM/RAM responses, hardware address breakpoints, external serial clock/data, and open-drain joypad lines. Digital capture should be at least 100 MS/s; sub-20-ns hazards require a calibrated mixed-signal capture faster than the digital pass.

### Test groups

1. **T1–T4 alignment**: loops over ROM read, cartridge-RAM read/write, WRAM, HRAM, MMIO, CALL/RST stack writes, and interrupt pushes. Recover all eight edges and compare against the phase protocol.
2. **Read fold**: drive controlled per-half-edge data patterns and verify bitwise-AND accumulation versus stable T3R sampling.
3. **Reset**: repeat cold power-on and external reset at least 256 times; measure oscillator start, reset release, first fetch, PC/IE behavior, startup-delay distribution, and retained pins.
4. **HALT**: trigger timer, VBlank, joypad, and externally clocked serial interrupts at swept half edges; record clock gates, wake latency, discarded fetch, and IME cases.
5. **STOP**: sweep JOYP selection/button state, IE/IF, IME, LCD mode, DMA, and externally clocked serial activity. Measure DIV reset, oscillator-off interval, wake, and startup delay. CGB speed tests use separate CGB profiles.
6. **Interrupt dispatch**: sweep IRQ changes and IE writes through all half edges, including SP `$0000`, `$0001`, and IF-stack-write collisions.
7. **Invalid lock**: execute each of 11 invalid bytes after controlled preceding addresses/data. Record no-fetch behavior, retained pins, device-clock continuation, RESET recovery, and power-cycle recovery.
8. **OAM/IDU**: sweep every relevant PPU row and PC/SP/HL old address for INC/DEC, HLI/HLD, POP/RET, PUSH/CALL/RST, and interrupt entry; repeat across multiple CPU-B units to classify nondeterminism.
9. **Canonical checkpoints**: run the exact Red ROM and capture boot handoff, `Random_`, `DelayFrame`, VBlank/RETI, BCD/DAA payout, and minimal `InitOpponent` episode checkpoints.

### Acceptance

A profile fact becomes deterministic only when:

- the raw capture and fixture manifest are retained by hash;
- at least two independent analysis paths agree;
- repeated measurements establish a stable value or an explicit distribution/relation;
- the test does not depend on an unverified flash-cart bus behavior;
- the fact is reproduced on two CPU-B units, or the theorem names the one measured fixture.

Contradictory or unstable results widen the relation; they are never averaged into one convenient constant.

## Proof obligations

| ID | Obligation |
|---|---|
| DB-PHASE | One physical M-cycle expands into the eight half edges and measured external sequence. |
| DB-READ | Stable reads reduce to the logical byte; changing bus values follow the read-fold relation. |
| DB-WRITE | External and internal writes occur only in their declared windows with register-specific collision rules. |
| DB-IRQ | IME, IRQ latch, priority, and INTA phases refine processor interrupt events. |
| DB-GATES | running, HALT, STOP, reset, and lock apply distinct CPU/system/device gates. |
| DB-RESET | power-on plus synchronous reset produces the reset-fetch relation without inventing register values. |
| DB-BOOT | hash-identified boot execution reaches a fetched cartridge `$0100` witness. |
| DB-NMI | unbonded NMI and unused IRQ inputs remain inactive. |
| DB-OAM | IDU/bus provenance maps to selected deterministic or relational OAM behavior. |
| DB-LOCK | invalid decode produces no fetch/ack transaction and canonical Red never reaches it. |
| DB-ORACLE | SameBoy comparisons exclude quarantined claims and compare only declared projections. |
| DB-CAPTURE | every deterministic hardware calibration imports a checked capture manifest. |

## Remaining profile work

The first profile decision, half-edge protocol, reset ownership, NMI tie-off, clock-gate split, boot identity, and independent emulator are now fixed.

Still requiring new measured artifacts:

- exact propagation/hazard bounds needed for analog-sensitive read-fold cases;
- locked-pin retained levels and RESET recovery on identified CPU-B units;
- CPU-B instance classification for advanced OAM transforms;
- a signed DMG-B capture corpus implementing the procedure above;
- exact CGB revision profiles and STOP speed-switch timing;
- DMG-CPU C support, which is explicitly no longer on the critical path for the first Red theorem.
