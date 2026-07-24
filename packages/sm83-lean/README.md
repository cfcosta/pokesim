# sm83-lean

A standalone Lean 4 specification, executable model, and proof library for the
Sharp SM83 processor used by the Game Boy family.

The package is deliberately independent of Pokémon, cartridge controllers, and
Game Boy peripherals. It owns opcode decoding, architectural instruction
semantics, the fetched-instruction-register M-cycle core, interrupts, HALT,
STOP profile hooks, invalid-opcode lockup, and generic byte-program reasoning.
Consumers provide a bus and hardware-profile adapter.

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
python3 tools/check-sm83-singlestep.py /path/to/sm83-tests
```

This checks all 498,000 context-free legal-instruction cases. HALT and STOP are
excluded from ordinary completion vectors and covered by profile/sequence
proofs because their corpus rows do not contain the required system context.

## License

Apache-2.0. The implementation is clean-room code based on the cited factual
specifications and test corpora; no code from unlicensed prior art is copied.
