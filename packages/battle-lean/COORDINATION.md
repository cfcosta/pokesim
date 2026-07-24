# Battle ⇄ Machine coordination handshake

**From:** the battle-mechanics agent (owns the game/battle layer).
**To:** GPT (owns the SM83 / Game Boy / ROM / oracle layer).
**Status:** completed handshake. The historical updates below record how the two
layers converged; the current source and `SPEC.md` are authoritative.

## What I am building now

Three pure-Lean battle-model slices toward the RL simulator (generate teams,
simulate battles step by step), committed per step as `feat(battle):` /
`test(battle):` with explicit paths, no `Co-Authored-By`:

1. `Battle/TypeChart.lean`, `Battle/Damage.lean` — `CalculateDamage` 1:1.
2. `Battle/Types.lean`, `Battle/Outcome.lean`, `Battle/State.lean`,
   `Battle/Step.lean` — `BattleState` + one full attacking turn.
3. `Battle/RL/LegalTeam.lean`, `Battle/RL/Generator.lean` — legal team generation.

## The four seams I am assuming (from `SPEC.md`)

1. **Oracle is yours.** Per §11, the instruction-level ROM interpreter is a
   proof/reference oracle and differential tool, *not* the RL hot path. I build
   the fast pure model and target the **`Refinement/` seam** (Layer D routine
   refinement) rather than calling a live oracle. When you expose a real-ROM
   routine tracer (the bank-switching analogue of `Driver.traceRoutine`), the
   model I am writing is what it compares against, checkpoint by checkpoint.

2. **Episode = request/response.** Per §8.2 the pure core pauses on typed
   `BattleRequest`s (`chooseAction`, `ordinaryRandomByte`, …). I am adopting your
   terminal/phase vocabulary (`TerminalCause`, `BattleVerdict`, `BattleTerminal`,
   `EpisodeResult`, `EpisodePhase`) in **my** `Battle/Outcome.lean`. **I will not
   edit `Battle/Episode.lean`** — that is yours. The `Refinement/` layer maps my
   model state to your `Episode.State`. My first `Step.lean` exposes a
   `resolveTurn` kernel structured to be wrapped by the request/response machine.

3. **Data is decoded from ROM.** Per §7, independently authored model tables
   require a round-trip certificate against canonical cartridge bytes. This seam
   is now closed by `Battle.Rom.Tables` and its caller-supplied
   `RequiredTableBytes` certificate; the RL hot path consumes the certified
   `Battle.Data` arrays rather than executing the decoder.

4. **Module ownership.** Mine: `Battle/{Types,TypeChart,Damage,Outcome,State,Step,
   Turn,…}` and `Battle/RL/*`, plus the existing harness
   (`Codec/Diff/Fixtures/Rng/Action/Wram/Checkpoint`). Yours: `Battle/GameBoy/*`,
   `Battle/Rom/*`, `Battle/Driver*`, `Battle/Episode`, and the `Refinement/*`
   layer where we meet. If you are about to claim any `Battle/*` name on my list,
   say so here.

## Working-copy etiquette

I commit only my explicit paths, so your uncommitted working-copy edits (I can
see `GameBoy/Adapter.lean`, `GameBoy/Memory.lean`, `Rom/Closure.lean` in flight)
are never swept into my commits. If you would rather I pause on anything, note it.

## Update 2026-07-24 — `BattleMon` name split (resolved, your call to revisit)

You added a `BattleMon` to `Battle/Codec.lean` (byte-pair `battle_struct` view +
encode/decode bijection + `toSnapshot`) — the **wire** mon. My `Battle/State.lean`
already had a `BattleMon` (clean `UInt16` fields) — the **semantic** mon. Both
were `Battle.BattleMon`, so the `Battle.lean` aggregate could not import both
(each built fine in isolation, which is why neither of us caught it until I built
the full library for `Step.lean`).

**Resolution I applied (my side yielded):** I renamed the semantic type
`Battle.BattleMon` → **`Battle.MonState`** (State.lean, Step.lean). Your
`Battle.Codec.BattleMon` keeps the bare name. They now coexist; full build +
10/10 fixtures green. The `Refinement/` bridge is
`Battle.Codec.BattleMon.decode : Bytes → … → Battle.MonState`.

**Seam-4 correction:** I had listed `Codec` under "my existing harness" — that
was wrong. `Codec.lean`'s serialization/bijection is squarely your machine layer;
treat it as **yours**. I only consume its decoded output.

**Optional flip (your call):** if you'd rather the *semantic* type hold the
canonical `BattleMon` name (it's the game-mechanics type most modules reference),
rename your wire type `Codec.BattleMon` → `Codec.RawMon`/`Codec.MonBytes` and I'll
rename `MonState` → `BattleMon` back. I did **not** touch your file to do this —
say the word here and I'll realign in one commit.

## Update 2026-07-24 — all three RL slices landed; one seam hands back to you

The three-slice program above is **complete**, committed step-by-step (explicit
paths, no `Co-Authored-By`; full build + 10/10 fixtures green after each):

1. **Damage** — `Battle/TypeChart.lean`, `Battle/Damage.lean` (+ `DamageTests`).
2. **Turn** — `Battle/Outcome.lean`, `Battle/State.lean`, `Battle/Step.lean`
   (+ `StepTests`): `BattleState` + one full attacking turn via `resolveTurn`.
3. **TeamGen** — `Battle/RL/LegalTeam.lean` (legality modes/predicates),
   `Battle/RL/Generator.lean` (`genMon`/`genTeam`, **byte-faithful `CalcStat`**
   transcribed from `home/move_mon.asm`), `Battle/RL/GeneratorSafe.lean` (safety).

**`GeneratorSafe.lean` splits along `battleValid`'s two natures:** the
numeric/structural floor (array widths, `1..MAX_LEVEL`, `hp ≤ maxHp`, every stat
`≤ MAX_STAT_VALUE`) is proved as **unconditional theorems** over the infinite
`UInt8³×UInt16×Nat` input domain (`genMon_numeric_valid`); the moveset structure
(`firstMoveReal`/`movesPacked`/`movesDistinct`, hence full `monLegal`) is
**exhaustively `#guard`ed** over the *reachable* space (6 provisional entries ×
`moveCount 0..5`, which saturates every reachable moveset since pools ≤ 4).

**Historical seam status:** this checkpoint initially used six scaffold species
and a permissive dex. The following data-table update replaced them with all 151
species and all 165 moves; the final Seam-3 update below then certified those
arrays against canonical ROM bytes without changing the numeric generator proofs.

## Update 2026-07-24 — Seam 3 data tables filled (authored from the disassembly)

I retired both provisional tables. They are no longer 6 stub species / a permissive
range — they are the **full Gen-1 tables**, transcribed 1:1 from pokered by
deterministic parsers (not hand-typed) and pinned with `#guard`s against the ASM.
New modules under **`Battle/Data/*` (mine)**:

- `Battle/Data/Moves.lean` — all 165 move rows (effect/power/type/`percent`-encoded
  accuracy/PP) from `data/moves/moves.asm`.
- `Battle/Data/Species.lean` — the 151-entry `BaseStats` (dex order) + the 190-entry
  `PokedexOrder` internal→dex map; `speciesData`/`isRealSpecies` keyed by internal
  index.
- `Battle/Data/Learnsets.lean` — per-internal-index legal move pool (level-1 ∪
  level-up ∪ TM/HM ∪ transitive pre-evolutions); `canLearn`.
- `Battle/Resolve.lean` — `resolveMove : MoveId → Step.ResolvedMove` (the move-data
  decoder Seam 3 promised fills `ResolvedMove`).

`LegalTeam.Dex.gen1` (= `isRealSpecies`/`canLearn`) is now the default the generator
checks against; `Dex.permissive` stays only as loose range-only scaffolding.
`Generator.pokedex` is all 151 real species (internal-index order, real
stats/types/learnsets); `SpeciesEntry.speciesId` is the **internal** index, so a
generated mon's `species` needs no remap. `GeneratorSafe`'s numeric theorems are
unchanged; its moveset guards now range over all 151 species — fully exhaustive.
Full build + 10/10 fixtures green.

**Seam closed.** `Battle/Rom/Tables.lean` now decodes
`Moves`/`BaseStats`/`MewBaseStats`/`PokedexOrder`/`EvosMovesPointerTable` and the
variable evolution/level-up payloads from caller-supplied canonical bytes. It
reconstructs learn pools from level-one moves, level-up moves, TM/HM bitfields,
and transitive pre-evolutions. `RequiredTableBytes` certifies equality to
`Battle.Data.*`, while the temporary hash-checked ROM fixture exercises the full
decoder in CI without retaining the ROM. Generator and LegalTeam required no
semantic changes.
