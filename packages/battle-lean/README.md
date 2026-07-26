# battle-lean

A Lean 4 model, differential harness, and proof library for the Generation 1
(Pokémon Red/Blue) **battle engine**, built to be provably 1:1 with the
[`pret/pokered`](https://github.com/pret/pokered) disassembly.

The package owns the *game/battle* layer: the RNG stream, the damage pipeline,
move effects, status conditions, stat stages and badge boosts, trainer AI, item
and ball effects, and catching. Cartridge bugs inside the declared profile are
preserved rather than repaired; `Battle.BugCompatibility` gives universal
characterizations for thirteen independently audited families, while
`Battle.BugWitnesses.all_gen1_bug_occurrences` proves a concrete occurrence for
each one. The overworld is out of scope.

The high-level battle model is deliberately independent of processor semantics.
ROM decoding, Pokémon-owned device composition, and refinement modules live in
this package but import the standalone companion `sm83-lean` candidate. Runtime
fixtures remain supporting checks; theorem modules require caller-supplied hash
and byte witnesses and never treat processor execution as an unproved oracle.

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

## Current executable self-play profile

`Battle.RL.Environment` is intentionally narrower than the final engine. It
runs dynamically generated, proof-carrying one-mon teams using only ordinary
nonzero-power moves with no additional effect. Inside that boundary it preserves
link RNG consumption, priority/Speed ties, PP, critical hits, damage rejection,
accuracy, HP, witnessed terminal state, and separate cleanup/return. Unsupported
moves and actions are rejected rather than approximated.

`Battle.RL.SelfPlay` supplies policy isolation, legal masks, observations,
external horizons, replay transitions, and model-against-itself execution. A
100-episode native smoke matrix is available with:

```sh
nix develop -c lake -d packages/battle-lean exe battleSelfPlay
```

This profile is suitable for restricted RL experiments. It is not yet a claim
of whole-cartridge equivalence.

## Generate Pokémon Showdown teams

Generate two progression-witnessed teams as directly importable Showdown export
sections. The optional arguments are the deterministic seed and party size
(`1..6`):

```sh
nix develop -c lake -d packages/battle-lean exe battleGenerateTeams 1037 6 > teams.txt
```

Diagnostics go to stderr, leaving stdout as team-list text. Species, levels,
Generation-I DVs (encoded as Showdown IVs), and moves are preserved. Showdown
has no team-text field for packed current PP or PP-Up counts, so those are not
exported.

Run one deterministic model match and emit Pokémon Showdown's newline-and-pipe
simulator protocol. Arguments select the episode seed index and decision budget:

```sh
nix develop -c lake -d packages/battle-lean exe battleSelfPlayLog 9 4096 > battle.log
```

The log contains team preview, switches, ordered moves, HP/status changes,
Transform, recoil, fainting, and the winner. Internal RNG observations are not
Showdown protocol events and are omitted; effects without a lossless protocol
mapping are retained as `|-message|` records.

## Build

From the repository root:

```sh
nix develop -c lake -d packages/battle-lean build
```

The Lean toolchain and `lake` are provided by the repository's Nix flake; do not
rely on a system Lean install.
