# battle-lean

A Lean 4 model, differential harness, and proof library for the Generation 1
(Pokémon Red/Blue) **battle engine**, built to be provably 1:1 with the
[`pret/pokered`](https://github.com/pret/pokered) disassembly.

The package owns the *game/battle* layer: the RNG stream, the damage pipeline,
move effects, status conditions, stat stages and badge boosts, trainer AI, item
and ball effects, and catching — **including every original bug**, because the
ROM's behaviour is the specification. The overworld is out of scope.

It is deliberately independent of the processor. It does not decode SM83
opcodes, model the cartridge, or drive Game Boy peripherals: that is the
companion `sm83-lean` package. Instead, the Stage-0 differential harness runs
`sm83-lean` over the assembled battle routines as its **oracle** and checks the
abstract battle model against it.

## Semantic layers

- **Oracle (L0).** `sm83-lean` executing the real, assembled battle ROM bytes
  from a loaded WRAM image until a return sentinel — the ground truth every
  layer above must refine.
- **WRAM state contract.** The battle-relevant slice of Game Boy work RAM
  serialized to a checkpoint trace: the two active mons, party structures, the
  three per-side battle-status bytes, stat stages, the RNG cursor, and the
  turn/effect bookkeeping the engine reads and writes.
- **RNG oracle.** The deterministic link-battle `BattleRandom` byte stream,
  fed identically to both sides of the differential so divergences are engine
  divergences, not luck.
- **Action channel.** The per-turn decision encoding (move / switch / item /
  run) that advances one battle step.
- **Battle-state codec.** The mapping between the abstract Lean battle model and
  the raw WRAM byte image the oracle reads and writes.
- **Differential comparator.** Steps oracle and model in lockstep and bisects to
  the first divergent checkpoint on mismatch.

The byte-level specification this package implements is the companion
battle-mechanics reference (14 chapters + SPEC).

## Build

From the repository root:

```sh
nix develop -c lake -d packages/battle-lean build
```

The Lean toolchain and `lake` are provided by the repository's Nix flake; do not
rely on a system Lean install.
