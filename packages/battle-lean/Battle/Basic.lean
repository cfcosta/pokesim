/-
Copyright 2026 Cainã Costa
Licensed under the Apache License, Version 2.0 (the "License").
-/

/-!
# battle-lean

A Lean 4 model, differential harness, and (eventually) proof library for the
Generation 1 (Pokémon Red/Blue) **battle engine**, built to be provably 1:1 with
the [`pret/pokered`](https://github.com/pret/pokered) disassembly — RNG, damage,
moves, status, stat stages, trainer AI, items, and catching, **including every
original bug**. The overworld is out of scope.

This package is deliberately scoped to the *game/battle* layer. It does not model
the SM83 processor, cartridge, or Game Boy peripherals: that is the companion
`sm83-lean` package's job. The Stage-0 differential harness treats `sm83-lean`
executing the assembled battle routines as its **oracle** (that oracle is the L0
layer of the refinement chain), and checks the abstract Lean battle model against
it, checkpoint by checkpoint.

## Planned architecture (Stage-0 differential harness)

- A **WRAM state contract** — the battle-relevant slice of Game Boy work RAM
  (`wBattleMon`, `wEnemyMon`, party structures, status bytes, RNG cursor, …) —
  serialized to a checkpoint trace.
- An **RNG oracle** modelling the deterministic link-battle `BattleRandom` byte
  stream, fed identically to both sides of the differential.
- An **action channel** encoding of the per-turn decisions (move / switch / item
  / run) that drive one battle step.
- A **battle-state codec** mapping the abstract Lean model to and from the raw
  WRAM byte image the oracle reads and writes.
- A **differential comparator** that steps the oracle and the model in lockstep,
  bisecting to the first divergent checkpoint on mismatch.

The battle-mechanics reference that this package implements lives in the
companion documentation set (14 chapters + SPEC); it is the byte-level
specification every definition here must match.
-/

namespace Battle

/-- The battle-lean package version, mirrored from `lakefile.toml`. -/
def version : String := "0.1.0"

end Battle
