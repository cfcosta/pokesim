# Eleventh-pass SM83 profile and evidence audit

## Scope

The tenth pass left five profile blockers:

1. first console/SoC revision;
2. exact T1–T4 read/write/interrupt phases;
3. reset and HALT/STOP clock gates;
4. invalid-lock and STOP evidence;
5. independent emulator and physical-hardware validation procedure.

This pass audited die-derived HDL, DMG-B bus measurements, a current independent emulator, and a real-hardware microtest corpus. The resulting contract is [DMG-CPU B console profile and evidence contract](../reference/dmg-cpu-b-profile.md).

## Sources pinned

| Source | Commit/hash | Finding |
|---|---|---|
| `Gekkio/gb-research` | `59088f486f579a69fd86bd86a55181b937e769e0` | SGB-CPU 01 core identified as DMG-CPU B equivalent; reset, clocks, ports, IRQ/NMI, phase octet |
| `LIJI32/SameBoy` | `213a12ce93d66b105a113debd9396306066a7cfc` | implemented DMG model is CPU B; CPU C is commented out; strong differential oracle with explicit TODOs |
| `aappleby/GBMicrotest` | `463eb6bc0fe31d61781ef63060ad6d74090c0255` | 513 source/prebuilt minimal tests checked on real hardware; exact CPU revision uncertain |
| IceBoy memory patterns | SHA-256 `8616eaf3c9f8eea6b165646c66132e3c21995893bb433744948a24ea8aee6716` | DMG-CPU B external bus and T1F–T4R sequence |
| IceBoy core connections | SHA-256 `e070435eecf2136ea1485ef81c61e27c08885369ff49902fd8cd2cb582ee94db` | core phases, clock gates, reset, unbonded NMI, dynamic-bus read fold |
| boot-ROM inventory | SHA-256 `ae9fe35ce9d20ac1b869095645c7c3f7bb3858e36ae2ee0aee14218e84dc62ab` | canonical common DMG boot SHA-256 |

License disposition:

- `gb-research` code is MIT or Apache-2.0; image/schematic assets are CC BY 4.0;
- SameBoy core is Expat/MIT;
- GBMicrotest is MIT;
- IceBoy web pages are cited by URL/hash only because no page license was inferred;
- no source implementation was copied into Lean.

## Finding 1: first profile changes from CPU C to CPU B

DMG-CPU C was provisional and had no matching detailed implementation evidence. The strongest mutually reinforcing evidence is CPU B:

- `gb-research` traces an SGB-CPU 01 core and explicitly identifies it as DMG-CPU B-equivalent;
- the IceBoy measurements are on DMG-CPU B;
- SameBoy only implements `GB_MODEL_DMG_B`; `GB_MODEL_DMG_C` is present only as a commented enum candidate.

The first theorem target is now `DmgCpuBCommonBoot`. CPU C becomes a later generalization rather than an undocumented assumption.

This is not merely renaming the profile. Revision-dependent OAM, PPU/MMIO collisions, boot timing, and clock behavior are theorem parameters.

## Finding 2: the four-T-cycle expansion needs eight half edges

“Sample during T3” is insufficient. The measured external sequence distinguishes:

```text
T1F T1R T2F T2R T3F T3R T4F T4R
```

Important transitions are split across those edges:

- address drive at T1F;
- external select at T1R;
- write assertion/data at T2R;
- read sample at T3R;
- write deassertion at T4F;
- select/address/data cleanup at T4R.

The processor still advances one M-cycle carrying four typed T-cycles. The adapter expansion is refined to eight half-edge phases. This does not turn the processor into an analog model; it gives the adapter enough ordering to express real bus behavior.

## Finding 3: reads can be temporal folds

The core data bus is precharged high and dynamically discharges. The die-derived description says a bit that is low at any time in the sample window is read low even if it returns high. A changing read can therefore be a bitwise AND over time.

This matters for:

- DIV/timer boundaries;
- IF and device collisions;
- open-bus and contention behavior;
- deliberately swept hardware tests.

Stable memory reduces to the ordinary byte used by SingleStep. The physical port now supplies a half-edge-indexed drive, and the stable-read reduction is a theorem.

## Finding 4: writes have windows, not one commit instant

External write behavior spans T2R through T4F. Internal register/flag writeback occupies the final quarter. MMIO conflict timing is register-specific.

SameBoy has useful conflict maps, but also labels exact IF triple collisions and multiple display cases TODO or hacky. Therefore:

- SameBoy supplies differential observations;
- each Lean MMIO rule is independently specified;
- TODO-marked paths cannot discharge proof obligations;
- a future hardware capture chooses or widens the profile relation.

## Finding 5: reset does not initialize ordinary registers

The evidence separates asynchronous power reset from synchronous system reset:

- power reset establishes clock-control output state;
- synchronous reset sets PC and IE to zero and selects initial fetch;
- ordinary registers and IR are not reset.

An arbitrary old IR can decode in parallel with the first fetch, but reset sequencer state prevents a jump or additional memory access. Setting AF/BC/DE/HL/SP/IR to emulator folklore at reset is unsound.

The boot theorem starts from an unreset-register relation, verifies the externally supplied boot-ROM hash, and derives the cartridge `$0100` pipeline witness.

## Finding 6: NMI exists in the core but not the console

The reverse-engineered core includes NMI logic. The DMG die connection is an unbonded pad. The reusable processor protocol may retain NMI, while the Game Boy adapter proves it inactive.

Likewise, the core exposes eight IRQ lines; only five are console-connected.

This resolves the previous “model or omit NMI?” ambiguity without claiming arbitrary Sharp-SoC compatibility.

## Finding 7: HALT and STOP gate different clocks

The die-derived HDL exposes `cpuclk_en` and `sysclk_en`:

- HALT disables CPU execution/data/writeback phases while the system/machine clock path remains available for wake and devices;
- STOP also disables the system oscillator path;
- WAKE restarts the oscillator, followed by clock-ready delay.

Thus neither state is represented by repeatedly applying a universal idle transition.

For DMG-B, restart evidence is around 32 ms/`2^17` T-cycles with observed variation. The exact CGB speed-switch constants do not apply.

## Finding 8: CGB STOP no longer blocks the first theorem

The conflicting approximately `$20000`-T-cycle and 2050-M-cycle CGB claims remain real. SameBoy currently uses `0x20008` while its source says speed-switch timing needs far more tests.

Because the first profile is DMG-B:

- KEY1 and speed switching are unreachable;
- CGB STOP becomes a separate future profile;
- the processor still exposes generic STOP requests/outcomes;
- canonical Red contains no STOP opcode, so a ROM reachability theorem excludes it from the battle run.

The disagreement is quarantined rather than resolved by preference.

## Finding 9: locked pins remain relational but nonblocking

The all-zero decoder/no-fetch interpretation is supported. Exact retained address/data/control pin levels after invalid decode are not.

The profile now states only what evidence supports:

- no fetch, memory request, read, write, M1, or interrupt acknowledgement is invented;
- HALT/STOP clock gating is not applied;
- retained analog pin levels remain relational;
- reset and power cycle are explicit transitions.

Canonical Red must prove invalid bytes unreachable as opcodes. Therefore locked-pin nondeterminism cannot affect the target theorem while the processor package still covers all invalid slots.

## Finding 10: OAM behavior is more instance-specific than the baseline equations

SameBoy's current OAM implementation contains tertiary and quaternary equations, row-specific copies, model branches, and explicitly nondeterministic DMG observations. The earlier baseline two-row equations are not a complete universal DMG profile.

The profile now includes `OamInstanceClass`:

- deterministic measured fixture; or
- reviewed DMG-B family relation.

The battle theorem either chooses a fixture or proves the projected battle trace is invariant under permitted OAM variation.

## Finding 11: independent emulator selected with quarantine

SameBoy is selected because it is:

- independently implemented;
- Expat-licensed;
- explicitly DMG-B scoped;
- T-cycle-oriented at the SoC level;
- already tested against major public suites;
- candid about unresolved areas.

It is not an authority for STOP, locked pins, analog behavior, uncertain OAM cases, or TODO-marked IF timing. Those exclusions are part of the oracle contract.

The die-derived `gb-research` HDL is a second CPU-level executable reference. Its lack of propagation delays prevents analog claims.

## Finding 12: physical evidence requires fixture-qualified captures

A hardware procedure is now specified for:

- eight-edge bus alignment;
- temporal read folding;
- power/external reset distributions;
- HALT and STOP gates/wake;
- interrupt half-edge sweeps and IE/IF stack collisions;
- all 11 invalid opcodes;
- OAM/IDU sweeps;
- canonical Red checkpoints.

A deterministic fact requires hashed raw captures, fixture identity, calibration, repeated measurements, and either reproduction on two CPU-B units or a theorem naming one unit.

## New audit tool

Added `tools/audit-sm83-profile-sources.py`.

It verifies:

- three clean pinned Git checkouts;
- 24 exact file/web hashes;
- CPU-B source scope and license anchors;
- processor/SoC port inventory;
- five die-derived phase vectors;
- CPU versus system clock-gate equations;
- reset, NMI, IRQ, IME, and INTA anchors;
- all eight measured bus half edges;
- SameBoy's CPU-B model selection and unresolved-path markers;
- 513 GBMicrotest source/prebuilt fixtures;
- canonical DMG boot-ROM SHA-256 identity.

Passing output:

```text
PASS three clean commits and 24 exact profile-source hashes
PASS DMG-CPU B reset, clock gates, IRQ/NMI, and eight half-edge bus anchors
PASS gb-research five phase vectors and processor/SoC port inventory
PASS SameBoy selected as DMG-B differential oracle with STOP/IF/OAM TODO quarantine
PASS GBMicrotest inventory: 513 test sources, 513 prebuilt real-hardware fixtures
PASS canonical DMG boot ROM SHA-256 identity anchor
NOTE DMG-CPU C is no longer the first profile; CGB STOP and lock-pin levels remain measured-evidence work
```

## Capture import gate

Added `tools/hardware-capture-manifest.schema.json` and `tools/validate-hardware-capture.py`. The gate verifies profile/SoC/boot identity, all external address/data/control channels, at least 100 MS/s digital capture, artifact path containment and hashes, run/claim references, independent analysis identities, repetitions, and the 256-run reset minimum. A synthetic two-run phase bundle passed both the custom artifact validator and JSON Schema validation with `check-jsonschema`; no real hardware bundle exists yet.

## Executable source checks

The pinned SameBoy tester built successfully in a Nix shell with Clang, GNU Make, and nixpkgs RGBDS 1.0.1. Four GBMicrotest ROMs loaded and ran, but SameBoy's tester does not interpret GBMicrotest's `$FF80`–`$FF82` result protocol, so this is a build/integration smoke check—not a conformance pass.

The pinned `gb-research` VUnit suite compiled with GHDL 6.0.0 and Python 3.12 after two environment-only compatibility steps: VUnit 4.7.0 needed `setuptools<81`, and its backend detector needed the new `mcode JIT code generator` version string normalized to the older recognized wording. The one exposed test, `sm83.decoder_tb.all`, passed. Source files remained clean. This validates the pinned HDL's buildable decoder test only; it does not validate propagation delays or the absent full mock SoC.

## Closure status

Resolved for the first implementation:

- first SoC revision: DMG-CPU B;
- canonical boot identity;
- half-edge protocol shape and external transitions;
- CPU/system clock-gate separation;
- reset ownership and unreset-register relation;
- NMI/unused IRQ tie-off;
- independent emulator selection and distrust boundary;
- physical validation procedure.

Still awaiting captured evidence:

- analog propagation bounds;
- exact locked retained pins/reset recovery;
- advanced CPU-B OAM instance class;
- signed hardware trace corpus.

These remaining facts are represented as explicit relations or proved unreachable. None is silently filled with emulator behavior.
