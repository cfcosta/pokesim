# Twelfth-pass RISC-V and CompCert proof audit

<!-- mode: explanation -->

This pass asks a narrower question than the earlier SM83 evidence audits:

> What must be machine-checked before this project may say that its processor,
> ROM execution, and battle model are formally verified?

The short answer is that the current `sm83-lean` package is a strong executable
and validation artifact, but not yet a semantic-preservation development in the
CompCert or Bedrock2/Kami sense. The missing center is a universal simulation
stack. Finite corpus agreement, generated catalogue consistency, and concrete
refinement examples do not replace those simulations.

## Sources consulted

The web review used primary project documentation and source at these revisions:

| Project | Revision consulted | Relevant contract |
|---|---:|---|
| [official Sail RISC-V model](https://github.com/riscv/sail-riscv) | `a513afa4d2288b84254fc9417c4c2fd797c736b9` | one typed ISA source generates emulators, documentation, and theorem-prover definitions; platform operations and configuration remain explicit |
| [MIT PLV RISC-V semantics](https://github.com/mit-plv/riscv-semantics) | `a2c4e87ed69b451d793667ef7fa0ad7b20f4a009` | decoder/executor separated from a pluggable machine interface so the same ISA contract can face software and hardware proofs |
| [riscv-coq](https://github.com/mit-plv/riscv-coq) | `99c0ba6bd907f98aa22ba96f4e9a10362808747d` | theorem-prover form of the ISA contract used by compiler and processor developments |
| [riscv-formal](https://github.com/YosysHQ/riscv-formal) | `c992aa61fdfe0846c5ed90324c596202a1c69b76` | RVFI retirement interface plus instruction, PC, register, causality, liveness, uniqueness, fault, cover, and bus checks |
| [Bedrock2/Kami end-to-end development](https://github.com/mit-plv/bedrock2) | `75b2b7319da0ca2252259711af162f4c6fd3db98` | machine-checked composition from program logic through compiler and RISC-V ISA to a pipelined processor and MMIO trace property |
| [CompCert compiler proof](https://compcert.org/doc/) | official documentation; repository HEAD `a354849f0e5f52bdb9c1064b78f468369e0bf6a3` | pass-local simulations compose into whole-program behavior preservation |

The most relevant exact source statements are:

- Sail's [`ReadingGuide.md`](https://github.com/riscv/sail-riscv/blob/master/doc/ReadingGuide.md), especially the explicit split among instruction definitions, platform memory primitives, fetch/decode/execute, interrupts, configuration, and reset;
- the [RVFI specification](https://github.com/YosysHQ/riscv-formal/blob/main/docs/rvfi.md) and [verification procedure](https://riscv-formal.readthedocs.io/en/latest/procedure.html);
- Bedrock2's `processor.KamiRiscvStep.kamiStep_sound`, where one hardware step either stutters or realizes an ISA step, `processor.KamiRiscv.riscv_to_kamiImplProcessor`, and `end2end.End2EndPipeline.end2end`;
- CompCert's [`Compiler`](https://compcert.org/doc/html/compcert.driver.Compiler.html), [`Behaviors`](https://compcert.org/doc/html/compcert.common.Behaviors.html), and [`Complements`](https://compcert.org/doc/html/compcert.driver.Complements.html) modules.

## What the RISC-V projects establish

### A formal ISA model is a contract, not a proof of hardware

The official Sail model makes encoding, decoding, instruction execution,
exceptions, interrupts, reset, configuration, physical memory, and platform
hooks precise in one typed source. Sail can generate executable emulators and
Lean/Rocq/Isabelle definitions from that source. Passing architectural tests or
booting an OS validates the model; it does not prove that a processor implements
it.

This distinction applies directly to `sm83-lean`. Our decoder, ALU equations,
and executable runners define candidate semantics. External fixtures raise
confidence in those definitions. A theorem relating two definitions can then be
machine-checked, but no theorem can derive the factual behavior of silicon from
the definitions alone. Hardware evidence and the selected DMG profile remain an
explicit trust/evidence boundary.

### A shared ISA contract must be parametric over the environment

The MIT PLV semantics separates instruction definitions from machine operations
such as register, PC, memory, exception, and external-event access. That permits
the same instruction semantics to be instantiated by an interpreter, compiler
proof, or processor proof.

Our corresponding boundary is:

- `sm83-lean`: processor state, decoding, instruction effects, maskable
  interrupts, fetched-IR timing, and processor-visible bus intent;
- Game Boy adapter: MBC3, memory map, MMIO, dynamic reads, timer/PPU/APU/serial,
  boot ROM, DMA, clock gates, and profile-selected reset/STOP/lock relations;
- Pokémon proof: canonical ROM identity, code/data closure, driver invariants,
  battle observations, and high-level model.

A theorem that silently fixes flat memory, omits interrupts, or supplies constant
bus responses cannot serve as the shared contract for the latter two layers.

### RVFI is a retirement contract, not just an instruction checker

RVFI exposes a monotonically ordered retirement record: instruction bits,
pre/post PC, source register values, destination writes, memory masks/data,
trap/interrupt/halt provenance, and mode. The standard verification suite then
checks more than isolated instruction arithmetic:

- every supported instruction transition;
- adjacent-PC consistency in both retirement directions;
- register read-after-write consistency;
- register, memory, and I/O causality;
- no duplicate retirement order and no unexplained gaps;
- liveness under explicit fairness assumptions;
- instruction/data bus provenance and fault handling;
- reachability bounds and witness traces.

The SM83 analogue must retain M-cycle detail because OAM corruption, RNG, and
interrupt timing depend on it, but it should still define an instruction-retire
projection. `CycleIntent` alone is not yet that contract.

### The Bedrock2/Kami proof has the shape we need

`kamiStep_sound` proves that each pipelined hardware step is either:

1. an internal stutter that leaves the related RISC-V state unchanged; or
2. a corresponding RISC-V step producing a related trace and post-state.

`riscv_to_kamiImplProcessor` lifts that local theorem to whole processor traces.
It requires three program-supplied obligations:

1. establish an invariant from the concrete initialized machine;
2. preserve the invariant through every ISA step;
3. use the invariant to show the trace property.

The generic `end2end` theorem then adds explicit assumptions for program-logic
correctness, successful compilation, stack/code bounds, valid instructions, code
bytes loaded into instruction memory, and processor behavior. Its conclusion is
not raw trace equality. Every hardware trace maps to an MMIO trace that is a
prefix of a trace satisfying the program specification.

This matches our earlier decision to use projected observations and stuttering
refinement rather than low/high raw suffix equality.

## What CompCert adds

### Semantics must cover whole behaviors

CompCert uses labeled small-step semantics and distinguishes:

- termination with a finite observable trace and result;
- silent divergence after a finite trace;
- reactive divergence with an infinite observable trace;
- going wrong after a finite trace.

A fuel-bounded runner is an analysis tool, not one of these semantic outcomes.
Fuel exhaustion says nothing about whether the modeled machine terminates,
waits, reacts forever, deadlocks, or diverges silently.

For this project, the behavior type must distinguish at least:

- outer return with terminal witness and final state;
- infinite reactive execution with input/RNG/link/MMIO events;
- silent internal divergence;
- HALT wait, STOP, and invalid lock, with profile-appropriate device progress;
- malformed-state stuck behavior, but only where the cartridge really gets
  stuck rather than loops;
- analysis timeout/fuel exhaustion outside the semantic behavior type.

### Each boundary needs a simulation relation

CompCert gives every compiler pass a `match_prog` relation and a semantic
simulation. These compose into a whole-compiler simulation. Forward simulation
is converted to backward simulation only under stated receptiveness and target
determinacy hypotheses.

The project therefore needs one proved relation at every arrow, not a direct
jump from selected physical fixtures to the battle model:

```text
DMG half-edge system
  -> fetched-IR SM83 M-cycles
  -> architectural SM83 instruction relation
  -> canonical ROM driver semantics
  -> high-level battle semantics
  -> RL episode semantics
```

The direction of the final safety theorem is low to high: every behavior of the
concrete implementation must be matched by an allowed behavior of the
specification.

### Observable events and undefined behavior must be explicit

CompCert's basic preservation theorem allows generated code to replace a source
`Goes_wrong` behavior with a more defined behavior. Its stronger refinement
corollary requires the source program to be free of undefined behavior.

We must not use a similar loophole for cartridge glitches or malformed battle
states. Those are part of the intended source semantics. Overflow, stale
scratch, wraparound, unbounded scans, HALT/interrupt races, and terminal
asymmetries remain defined relations or explicit divergence. Uncertainty is
confined to named hardware-profile relations.

CompCert's verified boundary also starts after parsing/type elaboration and ends
before assembling/linking. Our desired lower boundary is stronger: it consumes
hash-identified ROM bytes. RGBDS correctness is therefore not a theorem premise;
source and symbols are navigation evidence, while decoded ROM bytes are what the
machine theorem executes.

## Required theorem stack for this repository

The following gates are cumulative. A later gate cannot replace an earlier one.

### P0. Trusted-boundary and behavior definitions

Define, in Lean:

- architectural, physical-M-cycle, and DMG-system states;
- finite and infinite observable traces;
- termination, silent divergence, reactive divergence, wait/lock, and stuck
  outcomes;
- trace projections for processor retirement, semantic memory/MMIO, battle
  RNG/input/link observations, and terminal provenance;
- initial-state relations and named profile assumptions;
- a documented list of axioms, generated code, external binaries, hashes, and
  hardware facts outside the kernel proof.

No theorem below should use `fuelExhausted` as a machine behavior.

### P1. Independent architectural instruction relation

Define a declarative relation whose constructors state instruction behavior
without calling `Functional.step`.

Required properties:

```lean
Functional.step s pending = r -> InstructionRel s pending r.trace r.state
InstructionRel s pending trace s' -> Functional.step s pending = { state := s', trace }
```

The second theorem is appropriate only for the deterministic flat-bus
instantiation. Relational STOP, lock pins, temporal reads, and system wake must
retain set-valued semantics.

Also prove, universally rather than by corpus sampling:

- legal/CB/invalid decoder partition and encode/decode round trips;
- one semantic family per legal byte;
- register, flag, PC/SP, memory, and ordered active-bus effects per family;
- branch outcomes and exact normal cycle totals;
- EI/DI/RETI, interrupt, HALT, STOP, and invalid-lock sequence relations;
- no undeclared instruction fallback.

### P2. Retirement projection and invariants

Define an SM83 retirement event containing at least:

- contiguous retirement order;
- IR address, base byte, optional CB byte, and fetch provenance;
- architectural PC before/after;
- register/flag reads and writes;
- ordered memory accesses;
- interrupt acknowledgement and mode transition;
- the constituent M-cycle interval.

Prove:

- one retirement for every completed normal instruction, including exactly one
  for a CB pair;
- no retirement for discarded prefetch, wait cycles, or invalid lock;
- unique, gap-free order;
- adjacent-PC consistency modulo explicit interrupt/HALT/STOP edges;
- read-after-write and memory causality;
- retirement data equals the architectural pre/post projection;
- every active bus event belongs to exactly one retirement or named system edge.

### P3. Universal fetched-IR refinement

Define a boundary relation containing IR address/byte, next PC, prefix state,
hidden latches, IME phase, and prefetched-boundary witness.

Prove a local simulation:

```lean
PhysicalMCycle low input low' event ->
BoundaryRel low high ->
  (BoundaryRel low' high ∧ Invisible event ∧ rank low' < rank low)
  ∨ ∃ high' obs,
      ArchitecturalStep high obs high' ∧
      BoundaryRel low' high' ∧
      RetireProjects event obs
```

The well-founded rank is needed to prevent an implementation from satisfying
refinement by stuttering forever. HALT, STOP, and lock do not use fake invisible
stutter; they have explicit high-level wait/lock transitions and device-domain
observations.

Lift the local result to finite and infinite traces. Prove both state and trace
parts. A schedule-length equality theorem is not this refinement theorem.

### P4. DMG-CPU B adapter refinement

For `DmgCpuBCommonBoot`, prove:

- eight half-edge transitions implement one selected physical M-cycle intent;
- address/select/read/write/data timing and temporal read folding;
- CPU/system/oscillator clock-domain progression;
- maskable interrupt inputs and permanently inactive unbonded NMI;
- asynchronous assertion, synchronous reset release, caller-supplied boot ROM
  identity, and cartridge `$0100` fetched checkpoint;
- MBC3 banking and every relevant MMIO/device transition;
- DMA/bus contention and OAM-trigger inputs;
- profile-qualified STOP and lock behavior, with unresolved outcomes remaining
  relational.

Then prove every finite or infinite DMG-system behavior maps to an allowed
physical-core behavior. SameBoy and hardware captures validate this theorem's
premises; they are not proof rules.

### P5. Canonical-ROM loading and closure

Prove:

- supplied ROM bytes have the canonical hash;
- normalized symbol/map addresses correspond to those bytes;
- instruction fetches decode the bytes at the selected bank/address;
- the transitive code/data/predef/text/interrupt/asset range manifest covers
  every reachable access in the theorem;
- executable RAM/SRAM and indirect targets are handled rather than assumed
  absent;
- invalid opcodes and STOP are unreachable for the selected canonical episode,
  if the episode theorem relies on that simplification.

The source tree and RGBDS build are reproducibility evidence. The theorem runs
the resulting bytes.

### P6. Driver invariant: establish, preserve, use

Following Bedrock2, define one low-level driver invariant and prove:

1. **Establish** it at the fetched `InitOpponent` entry checkpoint, including
   bank, stack, interrupt phase, reset image, party/WRAM predicates, devices,
   and input/RNG/link streams.
2. **Preserve** it through every architectural step, interrupt edge, and allowed
   environment transition until outer return or an explicit divergent/waiting
   behavior.
3. **Use** it to show that the projected low-level trace is a valid prefix of a
   high-level battle behavior.

Routine Hoare lemmas, frame conditions, and return sentinels support this
invariant; they do not replace it.

### P7. ROM-driver to battle-model behavior refinement

For every low-level behavior from the established entry relation, prove the
existence of a high-level behavior with related observations and states:

```lean
LowInitial low high ->
MachineBehavior low lowBehavior ->
∃ highBehavior,
  BattleBehavior high highBehavior ∧
  BehaviorRefines project lowBehavior highBehavior
```

`BehaviorRefines` preserves terminal return, divergence class, and projected
RNG/input/link order while allowing presentation/internal stuttering. It retains
the ending witness before `EndOfBattle` erases provenance.

Liveness is conditional. An uncooperative input stream can keep a menu open
forever. A finite supplied episode can separately prove eventual outer return.

### P8. High-level battle specification and RL theorem

Prove the high-level transition system itself satisfies the mechanics contract,
including all documented malformed/divergent cases. Then prove:

- atomic action APIs refine full menu/input protocols;
- observation projection is sufficient for the claimed RL interface;
- `done` occurs only after ending witness, epilogue, cleanup, and outer return;
- optimized/batched execution refines the proved high-level transition;
- replay includes every nondeterministic observation needed to reproduce the
  semantic trace.

## Assessment of the current code

| Current artifact | What it establishes | Why it is not the required theorem |
|---|---|---|
| `Sm83/Relation.lean` | a `Prop`-valued graph of `Functional.step` | `InstructionStep.running` contains the equation to `Functional.step`; `iff_functional` is therefore not an independent relation/executor proof |
| `Sm83/Proofs/Refinement.lean` | four concrete NOP/load/stack/CB examples | no universal state relation, no all-family theorem, no interrupts/HALT/STOP, and no finite/infinite trace lifting |
| 498,000 SingleStep and 4,096 DAA gates | strong differential validation of normal execution | tests are finite external evidence, not quantified Lean theorems; HALT/STOP are intentionally excluded |
| `Cycle` schedule theorems | lengths, fetch reassociation shape, and conditional deltas | equal schedule lengths do not prove state, bus, or trace simulation |
| `CycleIntent` and `HalfEdge.expand` | detailed candidate physical observations | no retirement projection, order/causality theorem, or proof against a composed Game Boy adapter |
| `Program.runUntil` | executable fuel-bounded analysis | fuel exhaustion is not termination, divergence, reaction, wait, lock, or stuck semantics |
| `Program.Runs` / `Hoare.Triple` | composition over repeated flat `Functional.step` | no pending-interrupt/device environment, no observable trace theorem, and no canonical ROM invariant |
| `ResetProfile.relational` | explicitly avoids inventing reset values | the relation permits everything; no DMG-B reset/boot theorem selects a useful subset |
| `StopProfile` / invalid-lock profile | preserves uncertainty as relations | coverage/existence proofs do not show a DMG system transition implements one selected profile outcome |
| decoder/catalogue/ALU theorems | substantial finite internal consistency | catalogue rows are generated from our definitions; external metadata audits remain validation, not an independent semantic proof |

Consequently, the defensible current claim is:

> `sm83-lean` is a clean-room candidate specification and two-layer executable
> implementation with extensive finite conformance evidence and several local
> proofs.

The currently indefensible claim is:

> the declarative, executable, and physical semantics have been universally
> proved equivalent, or that the physical core has been proved to implement the
> canonical SM83/DMG-CPU B behavior.

## Implementation order implied by the audit

1. Add whole-behavior and trace-projection definitions before proving more
   isolated examples.
2. Replace the graph-defined `InstructionStep` with an independent declarative
   relation.
3. Prove functional soundness/completeness against that relation.
4. Define retirement events and prove order, PC, register, memory, and causality
   invariants.
5. Prove one universal fetched-IR stuttering simulation and lift it to whole
   behaviors.
6. Build and prove the DMG-B adapter, reset/boot checkpoint, and device
   composition.
7. Generate canonical ROM range closure and establish the driver invariant.
8. Prove the minimal `InitOpponent`-to-return behavior refinement.
9. Only then promote local package wording from “candidate specification” to
   “formally verified implementation.”

This order follows the strongest common lesson from RISC-V and CompCert: define
observable behaviors and composable simulation boundaries first, then make every
implementation pass discharge one local relation. Testing remains mandatory,
but it is corroborating evidence rather than the proof spine.
