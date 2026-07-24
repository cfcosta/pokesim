# Fourth-pass ASM audit

<!-- research record; completed against the pinned source commit -->

**Baseline:** `pret/pokered` commit `405b6246372d7e5a2cb029cbb65219b13286b8c9`.

This pass reread initialization/cleanup, every trainer class's two AI tables, enemy move sampling, residual HP flow, drain/heal/Conversion/Explosion handlers, terminal paths, simultaneous faint ordering, and transformed capture. Later refinements are recorded in the [fifth-pass ASM audit](fifth-pass-asm-audit.md).

## High-impact corrections

| Finding | ASM evidence | Documentation consequence |
|---|---|---|
| Final WRAM does not uniquely encode terminal cause | Poke Doll and move escape set `wEscapedFromBattle` but normally leave result zero; Safari run/out-of-balls write neither discriminator; `EndOfBattle` then clears escape, mode, and opponent fields | Replaced the clean result-only contract with a pre-cleanup terminal control-flow witness plus raw fields and a separately composed epilogue theorem. Added [Battle outcomes](../reference/battle-outcomes.md). |
| `InitBattleVariables` is not a whole-state reset | It clears `wMiscBattleData`, while `wBattleStatusData` is chiefly cleared by the prior `EndOfBattle`; it writes Safari `wBattleType` only for a map range and does not initialize normal/Old Man mode | Added a named canonical reset-byte image and explicit caller/prior-cleanup preconditions. Raw-state theorems retain stale-byte behavior. |
| Enemy move slots are not sampled as equal quarters | `SelectEnemyMove` compares against `25 percent`, `50 percent`, and `75 percent - 1` | Recorded exact initial bucket sizes 63/64/63/66 and retry consumption for blank/disabled slots. |
| Trainer AI needs an exact 47-row artifact | Move layers are variable zero-terminated byte streams; action rows contain a count and pointer; direct `Random` is consumed before dispatch | Added [Trainer AI dispatch](../reference/trainer-ai-dispatch.md), including all class rows, exact thresholds, Cooltrainer F, Generic draw behavior, and malformed move-list behavior. |
| Residual fainting is delayed until after Leech Seed | `HandlePoisonBurnLeechSeed` applies poison/burn, then Seed, and tests HP only after both | Added poison-KO-then-Seed behavior, double Toxic increments, and nominal overkill healing obligations. |
| Drain mutates shared combat scratch | `DrainHPEffect_` divides `wDamage` by two in place, with minimum one, before healing | Counter and Bide must observe the reduced scratch value when they run later; drain cannot be modeled as HP healing alone. |
| Rest does not clear Toxic volatile state | `HealEffect_` writes active status `2` but does not clear `BADLY_POISONED` or the Toxic counter | Added stale-Toxic behavior after Rest, including Seed observing Toxic while the member sleeps and later normal poison inheriting the flag. |
| Simultaneous faint paths can conflict with raw result and payout | `RemoveFaintedPlayerMon` writes result 1; `FaintEnemyPokemon` writes 0; `TrainerBattleVictory` pays independently | Added write-order cases, including trainer prize payout with raw result 1 while Pay Day/evolution is skipped. |

## Exact terminal findings

Before cleanup:

- wild/trainer enemy-faint handling writes result `0`;
- player-faint cleanup writes result `1`;
- ordinary Run and capture write result `2`;
- Poke Doll and successful Teleport/Roar/Whirlwind set only `wEscapedFromBattle`, normally retaining result `0`;
- the successful move-escape path first calls `ReadPlayerMonCurHPAndStatus`, preserving current active HP/status in the party;
- Safari enemy escape and Safari Balls exhaustion normally retain result `0` and escape `0`;
- link result 0/1/other renders as win/loss/draw from the local perspective;
- link `EndOfBattle` copies active enemy status, but not HP, into the disposable mirrored enemy party slot.

For non-link result zero, `EndOfBattle` adds Pay Day and calls `EvolutionAfterBattle`. Poke Doll and move escape therefore reach those paths; ordinary Run/capture do not. At final return, `wEscapedFromBattle`, `wBattleType`, `wCurOpponent`, and `wIsInBattle` have been cleared, while `wBattleResult` remains. A final-memory decoder cannot recover the missing control cause.

After `EndOfBattle`, `_InitBattleCommon` restores `wLetterPrintingDelayFlags`, `wMapPalOffset`, and `hTileAnimations`, then returns with carry set. These are frame/return obligations even though their visual effects are outside semantic observations.

## Initialization and malformed-state findings

- `InitBattleVariables` zeroes `wMiscBattleData`, but that range does not contain the whole `wBattleStatusData` block.
- `DoBattleTransitionAndInitBattleVariables` clears five contiguous player stat/status bytes plus player Disable, not every player counter.
- Enemy send-out clears selected enemy volatile fields, while other counters still rely on prior cleanup.
- Normal battle mode depends on an already-zero `wBattleType`; Old Man mode is caller-established; only Safari map detection writes mode 2 inside initialization.
- `StartBattle`'s first-living-enemy scan remains unbounded and precedes mode dispatch.
- Trainer class zero/out-of-range and trainer number zero are outside canonical table domains and can scan unrelated ROM data.
- Move-scoring layers stop at the first zero move. With a zero first move and a later nonzero move, a class with at least one scoring layer can restart the minimum loop indefinitely. Canonical generated move lists require a contiguous nonzero prefix.
- `ReadTrainer`'s BCD payout loop assumes nonzero final enemy level; malformed level zero takes the wrapped byte loop rather than zero iterations.

## Trainer AI findings

The exact scoring layers are:

1. add 5 to selected zero-power status effects when the player already has a status;
2. subtract 1 for numeric effect ranges `$0A..$19` and `$32..$41` only when `wAILayer2Encouragement == 1`;
3. use the first-match type helper and its hexadecimal `$10` neutral value, with the source's narrow “better move” scan.

Action AI initializes `wAICount` lazily from `$FF`, consumes direct hardware `Random`, and calls the class routine. Only successful item actions decrement the count. Failed tests and Generic leave it unchanged; a successful switch initializes the incoming member to `$FF`.

Notable exact thresholds include:

- Juggler/Giovanni/Cooltrainer M/Misty/Surge/Koga/Blaine/Bruno: `random < 64`;
- Blackbelt/Rival 2/Rival 3: `random < 32` before later conditions;
- Erika/Lorelei/Lance and the relevant Sabrina branch family: source-specific `< 128` or `< 64` gates plus strict HP fractions;
- Agatha: `< 20` switch, `20..127` heal consideration, otherwise no action;
- Cooltrainer F: the random comparison's intended return is commented out, so only strict one-tenth/one-fifth HP checks matter;
- Brock: the random byte is consumed but ignored before the status check.

## Move/status and capture findings

- Drain replaces shared `wDamage` with `max(floor(wDamage / 2), 1)` and uses that value for healing.
- Residual overkill does not reduce the `bc` amount later given to the Leech Seed beneficiary.
- If Toxic poison and Seed are both active, the counter increments once for poison and again for Seed on one residual pass.
- Rest leaves Toxic flag/counter state; direct status clearing and volatile Toxic clearing are separate operations.
- Conversion copies the target's active types through Substitute, performs no ordinary hit test, and fails only on the target's invulnerability gate before copying.
- Explosion/Selfdestruct zero the user's active HP/status and clear its seeded flag in the effect phase even if later attack processing misses.
- Capture treats every Transform-flagged target as Ditto. A non-Ditto wild Pokémon that acquired Transform through Mirror Move is therefore captured as Ditto.

## Architectural decisions changed by this pass

1. Terminal semantics are `TerminalCause` plus raw pre-cleanup fields and an optional mode-specific verdict, not one enum inferred from `wBattleResult`.
2. The low runner records a recognized terminal control-flow edge before `EndOfBattle`.
3. Episode refinement composes a terminal theorem with a separate Pay Day/evolution/cleanup/outer-return epilogue theorem.
4. Standalone reset uses a proved canonical byte image; `InitBattleVariables` alone is not the reset contract.
5. Trainer AI class rows and move-layer byte streams are decoded ROM data, not manually selected policy categories.
6. Shared `wDamage` remains phase-sensitive state across damage, drain, Counter, and Bide.
7. A link episode's persistent party outputs are the two local player parties; post-cleanup mirrored enemy copies retain source asymmetries and are not silently synchronized.

## Validation performed

Source/document checks cover:

- all 47 trainer IDs against move-layer streams and action count/pointer rows;
- all documented trainer action routine thresholds against `trainer_ai.asm`;
- all 83 item ID/pointer rows;
- all 87 effect IDs, 86 pointer rows, and six phase arrays;
- move/species/trainer/item/effect/Pokédex cardinalities;
- all recorded source SHA-256 values;
- all local Markdown links and whitespace.

These are source consistency checks. RGBDS/Lean builds and ROM-addressed execution remain blocked by the missing toolchain.

## Remaining implementation-time checks

1. Derive symbol-addressed terminal edges and prove the witness cannot be forged by the high-level runner.
2. Determine the minimal canonical pre-`InitBattleVariables` byte predicate from boot/new-game and post-`EndOfBattle` callers.
3. Differentially trace Poke Doll/move escape Pay Day/evolution, Safari out-of-balls, and both simultaneous-faint detection orders.
4. Trace drain followed by Counter, Bide versus drain, poison KO plus Seed, and Rest plus Toxic/Seed in an independent emulator.
5. Generate ROM decoders and byte-equality theorems for both trainer AI tables.
6. Differentially verify slot boundary bytes `62/63/126/127/189/190` and retry traces.
7. Rebuild the canonical ROM, produce `.sym`/`.map`, generate the transitive call graph, and resolve licensing/oracle selection.
