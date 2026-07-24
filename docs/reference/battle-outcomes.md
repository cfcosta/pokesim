# Battle outcomes and raw result fields

<!-- mode: reference -->

**Baseline:** `pret/pokered` commit `405b6246372d7e5a2cb029cbb65219b13286b8c9`.

A terminal outcome is not encoded by `wBattleResult` alone. The battle mode, `wEscapedFromBattle`, executed control path, and persistent mutations are required. `EndOfBattle` then clears several of those discriminators before `InitBattle` returns.

## Terminal paths before `EndOfBattle`

| Terminal cause | Source path | `wBattleResult` | `wEscapedFromBattle` | Notes |
|---|---|---:|---:|---|
| Wild opponent defeated | `FaintEnemyPokemon` | `0` | normally `0` | `FaintEnemyPokemon` explicitly writes zero before EXP. |
| Trainer's final opponent defeated | `FaintEnemyPokemon` → `TrainerBattleVictory` | normally `0` | `0` | Prize money is added in `TrainerBattleVictory`, independently of the later Pay Day/evolution guard. |
| Player party exhausted | `RemoveFaintedPlayerMon` → `HandlePlayerBlackOut` | `1` | `0` | Faint clears active/party nonvolatile status but leaves player volatile bytes until cleanup. Oak's Lab Rival 1 has a special no-blackout return. |
| Successful ordinary Run | `TryRunningFromBattle.canEscape` | `2` | `0` | The Run path writes the result byte directly; from the wild-faint prompt its player-Speed pointer is always party slot 1. |
| Successful capture | naming completes → `UseBagItem.returnAfterCapturingMon` | `2` | `0` | Party/box naming and insertion finish first; `wCapturedMonSpecies` is then cleared before `StartBattle` returns. |
| Poke Doll escape | `ItemUsePokeDoll` | unchanged, normally `0` | `1` | The item does not write `wBattleResult`. |
| Successful Teleport/Roar/Whirlwind escape | `SwitchAndTeleportEffect` | unchanged, normally `0` | `1` | The success path first calls `ReadPlayerMonCurHPAndStatus`, then sets only the escape flag. |
| Safari opponent runs | `StartBattle` → `EnemyRan` | unchanged, normally `0` | `0` | No dedicated result or escape flag is written. |
| Safari Balls exhausted | `StartBattle.outOfSafariBallsText` | unchanged, normally `0` | `0` | The terminal distinction exists only in the executed branch and transcript. |
| Old Man capture completes | ordinary capture return under `BATTLE_TYPE_OLD_MAN` | `2` | `0` | No party/box addition and no bag removal occur. |
| Link opponent runs while local side stays | `EnemyRan` link branch | `0` | unchanged | Interpreted as local win by the link result screen. |
| Link local side runs while opponent stays | `TryRunningFromBattle` | `1` | unchanged | Interpreted as local loss. |
| Both link sides run | `TryRunningFromBattle` | `2` | unchanged | Interpreted as draw. |
| Link party exhaustion | faint handlers | `0` win / `1` loss | normally `0` | Each cartridge retains its local perspective. |

“Unchanged, normally `0`” is intentional. `InitBattleVariables` initializes `wBattleResult` to zero, but raw-state executions may begin with other values unless the checkpoint precondition states otherwise.

## Simultaneous faint ordering

A simultaneous active faint is not inherently terminal: reserve members can continue the battle. It is retained as event/control-flow provenance and attached to a later terminal witness only where relevant.

`RemoveFaintedPlayerMon` writes result `1`; `FaintEnemyPokemon` writes result `0`. When both active Pokémon faint, the last executed faint routine determines the raw byte.

- If enemy faint handling runs first, `FaintEnemyPokemon` writes `0`, then its nested player-faint cleanup can overwrite it with `1`.
- If player faint handling runs first and a reserve party member exists, `RemoveFaintedPlayerMon` writes `1`, then enemy-faint handling can overwrite it with `0`.
- If the player has no reserve, blackout can occur before the enemy-faint path, retaining `1`.

The control path can therefore enter trainer victory and award prize money while leaving raw result `1`; `PrintEndBattleText` also selects the caller's **lose** text from that byte. The subsequent non-link Pay Day/evolution guard skips because it tests the byte, not the victory control path.

The recognized terminal edge enters an `ending` phase. It does not complete the episode until `EndOfBattle` and the outer restored return finish.

## `EndOfBattle` interpretation

For non-link battles:

```text
wBattleResult == 0  -> add Pay Day if nonzero, then call EvolutionAfterBattle
wBattleResult != 0  -> skip both
```

Consequently Poke Doll and move-based escape normally permit Pay Day pickup and the evolution scan, while ordinary Run and capture do not. Safari-run and out-of-balls paths also retain zero, though ordinary Safari state has no battle-earned Pay Day/evolution flags.

For link battles, the result screen uses:

```text
0 -> YOU WIN
1 -> YOU LOSE
other -> DRAW
```

The link branch reaches `EvolutionAfterBattle` without testing the result byte. Canonical link initialization cleared `wCanEvolveFlags`, and link battles grant no EXP, so the scan normally has no eligible member. Before the result screen, each cartridge copies active enemy status into its mirrored enemy party slot but does not copy active enemy HP; only that cartridge's local player party is authoritative persistent output.

## Cleanup and loss of evidence

`EndOfBattle` preserves `wBattleResult` but clears:

- `wEscapedFromBattle`;
- `wIsInBattle`;
- `wBattleType`;
- `wCurOpponent`;
- the volatile battle-status block and other cleanup fields.

The capture path already cleared `wCapturedMonSpecies`. At the final `InitBattle` return checkpoint, memory alone cannot distinguish every terminal cause. In particular, raw result zero can represent victory, Poke Doll escape, move escape, Safari escape, or Safari Balls exhaustion.

## Formal representation

The low-level runner must retain a terminal control-flow witness, for example the recognized terminal label/edge and relevant pre-cleanup bytes. A standalone final-memory decoder is insufficient.

A high-level terminal value contains at least:

- terminal cause;
- local cartridge perspective and mode;
- raw `wBattleResult`;
- pre-cleanup escape flag where applicable;
- optional win/loss/draw verdict derived for that mode;
- optional simultaneous-active-faint detected-first provenance;
- persistent final state and semantic event trace after the `ending` epilogue returns.

The epilogue theorem separately proves Pay Day/evolution selection and cleanup writes. The outer `_InitBattleCommon` return then restores `wLetterPrintingDelayFlags`, `wMapPalOffset`, and `hTileAnimations` and returns with carry set; those frame/return facts create the final `EpisodeResult` checkpoint. Post-return blackout processing, trainer map flags, link `HealParty`, and tutorial script cleanup require separate caller-integration theorems.
