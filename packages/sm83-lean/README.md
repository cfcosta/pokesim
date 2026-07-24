# sm83-lean

A standalone Lean 4 specification, executable model, and proof library for the
Sharp SM83 processor used by the Game Boy family.

The package is deliberately independent of Pokémon, cartridge controllers, and
Game Boy peripherals. It owns opcode decoding, architectural instruction
semantics, the fetched-instruction-register M-cycle core, interrupts, HALT,
STOP profile hooks, invalid-opcode lockup, and generic byte-program reasoning.
Consumers provide a bus and hardware-profile adapter.

## Semantic layers

- `Architectural` and `Relation` expose an independent Prop-valued instruction
  judgment; `Functional.step` soundness and completeness are proved separately.
- `Functional` executes de-overlapped instructions against `FlatMemory` and
  records ordered bus events.
- `Cycle`, `Pipeline`, and `Run` implement fetched-IR physical M-cycles,
  successor-fetch overlap, hidden boundary/latch state, HALT, and five-stage
  interrupt entry.
- `HalfEdge` expands each M-cycle into typed `T1F` through `T4R` pin intent.
- `FlatAdapter` drives the physical core from flat memory and projects its
  prefetched checkpoint back to the architectural view.
- `Retirement` exposes an RVFI-like boundary event and proves order, uniqueness,
  PC continuity, memory causality, and interrupt provenance invariants.
- `Behavior` and `Simulation` define finite/infinite observations, explicit
  terminal modes, progress-sensitive stuttering, and finite behavior lifting.
- `Program` and `Hoare` provide fuel-sensitive runs, return sentinels,
  composition, and frame predicates.
- `Profile` keeps STOP effects and invalid-lock retained pins relational where
  processor-only evidence cannot choose a deterministic system behavior.
- `Reset` distinguishes asynchronous assertion, held reset, and synchronous
  release without inventing one power-on register/IR image.
- `Catalogue` contains all 256 base and 256 CB projections with pinned metadata
  provenance; decoding itself remains encoding-derived.

The package contains no Pokémon data, cartridge controller, ROM, PPU, timer,
serial, joypad, or boot-ROM model. It models the Game Boy SM83 embedding, not
an arbitrary Sharp-core SoC: the optional die-core NMI pad is intentionally
omitted and must be proved unbonded/inactive by the Game Boy adapter.

The implementation contract is maintained in
[`../../docs/reference/sm83-implementation-spec.md`](../../docs/reference/sm83-implementation-spec.md).

## Build

From the repository root:

```sh
nix develop -c lake -d packages/sm83-lean build
```

The default build compiles both the proof library and a streaming conformance
runner. To validate the pinned SingleStep corpus without copying its fixture
data into this package:

```sh
python3 tools/check-sm83-release.py
python3 tools/check-sm83-daa.py /path/to/mooneye-test-suite
python3 tools/check-sm83-singlestep.py /path/to/sm83-tests
```

The release check rejects proof escapes, undeclared public dependencies, and a
missing license/module boundary. The DAA gate checks all 4,096 A/ZNHC rows
from pinned Mooneye source. The instruction corpus checks all 498,000 context-free
legal-instruction cases against both the
de-overlapped functional runner and the fetched-IR physical core. It compares
registers, flags, memory, IME, and ordered active bus transactions after
successor-fetch reassociation. HALT and STOP are excluded from ordinary
completion vectors and covered by profile/sequence proofs because their corpus
rows do not contain the required system context.

`Proofs.UniversalRefinement` proves state, memory, and projected-trace agreement
for all 242 ordinary legal base entries and all 256 CB entries. Decoder-closure
theorems establish the exact 498-entry count. These are universal local
instruction theorems, not finite fixture claims. HALT, STOP, interrupts, reset,
and invalid lock remain separate system/profile relations. The package is still
a candidate processor specification until the local simulation is lifted to the
complete infinite physical/system behavior stack and its hardware assumptions
are discharged by a consumer adapter.

## License

Apache-2.0. The implementation is clean-room code based on the cited factual
specifications and test corpora; no code from unlicensed prior art is copied.
