# Third-pass ASM audit

<!-- research record; completed against the pinned source commit -->

**Baseline:** `pret/pokered` commit `405b6246372d7e5a2cb029cbb65219b13286b8c9`.

This pass reread link setup, item dispatch, move selection/PP, status and special-damage paths, EXP All, switching, and battle exit. Later refinements are recorded in the [fourth-pass ASM audit](fourth-pass-asm-audit.md). It also checked the documentation for contradictions introduced by treating duplicated link or active/party state as one clean record.

## High-impact corrections

| Finding | ASM evidence | Documentation consequence |
|---|---|---|
| A complete link battle needs two cartridge perspectives | Each machine owns `wLinkBattleRandomNumberList`, its index, local party state, and a mirrored enemy copy; Psywave and Bide paths can desynchronize them | Replaced the permanent “one shared link state/RNG” assumption with paired perspective state plus conditional synchronization invariants. |
| Link setup can produce unequal lists before battle | `CableClub_DoBattleOrTradeAgain` permits generated zero bytes, while the external-clock `.findStartOfRandomNumberListLoop` skips leading `0` as well as `$FD/$FE` before copying | Link reset now accepts each side's post-processed ten-byte block. Equality is a precondition to prove when true, not a type-level fact. |
| Item scope is table-driven, not category-driven | `ItemUsePtrTable` has 83 entries; link blocks the bag before dispatch; Safari/Old Man synthesize items; `POKEDEX`, `SURFBOARD`, and badge aliases have raw-only nonstandard paths | Added [Item dispatch](../reference/item-dispatch.md), covering every entry, HM/TM rejection, and malformed IDs `$54`–`$C3`. |
| Player and trainer status cures are not symmetric | Active player status cures copy party max HP and all four combat stats and do not reapply stages/badges/status penalties; AI cures clear status/Toxic but leave current Attack/Speed untouched; damaged-HP Full Restore takes a third path | Expanded active/party state and item coverage; removed generic “status cure synchronization” wording. |
| Disobedient replacement moves charge the original slot | `CheckForDisobedience` changes `wCurrentMenuItem`/move record, but `DecrementPP` indexes `wPlayerMoveListIndex` | Added slot-index state to selection semantics and a dedicated PP regression. |
| EXP All can divide source data twice | `FaintEnemyPokemon` halves enemy data; the first `GainExperience` may divide it in place by participant count; the second call divides the already-mutated bytes by all gain flags | Documented destructive double division and the eight-bit flag count versus party-count recipient loop. |
| Counter/OHKO still traverse surprising random phases | `CriticalHitTest` precedes `HandleCounterMove`; successful OHKO returns to type adjustment, damage randomization, then `MoveHitTest`, while speed failure exits earlier | Added exact call-order/random-consumption obligations rather than treating them as atomic fixed-damage effects. |
| Substitute has two distinct exact-zero cases | `SubstituteEffect_` accepts a user HP result of zero; `AttackSubstitute` breaks only on borrow, so equal damage leaves a zero-HP substitute flagged up | Added both cases and effect-zeroing-on-break behavior to coverage. |
| Battle exit writes overworld handoff state | `HandlePlayerBlackOut` clears `BIT_ALWAYS_ON_BIKE` on most losses; `EndOfBattle` sets encounter cooldown and writes `$FF` to `wDestinationWarpID` | Added `BattleExitHandoff`; these writes cannot be hidden behind an unchanged-memory frame claim. |

## Additional source findings

### Selection, PP, and last-move state

- A disabled highlighted move takes `PrintMenuItem`'s early display path and does not reload selected-move data. Non-disabled highlights do.
- Canceling the ordinary move menu stores the highlighted zero-based slot in `wPlayerMoveListIndex`.
- Disobedient alternate selection's final PP check uses the full PP byte. PP Up bits can admit a zero-current-PP slot, after which the original slot's full byte is decremented.
- `IncrementMovePP` always updates party PP. For a transformed player using Mirror Move or Metronome, the recursive decrement skips party PP, leaving a permanent party increment.
- A charge move's first turn jumps to `ChargeEffect` before `DisplayUsedMoveText`; last-used-move scratch is updated on the attack turn, not the charge turn.

### Move and status flow

- Bide adds shared `wDamage` on each continuation check rather than accumulating a clean HP-loss event stream. Stale and Substitute-related damage can therefore contribute.
- Trapping chooses continuation count and clears target Hyper Beam recharge before the first accuracy test. A miss still consumed the duration draws and cleared recharge.
- Two-to-five-hit count draws occur before first-hit accuracy. Twineedle mutates its effect and performs one poison-side-effect roll after its final fixed second hit.
- Direct Confusion checks Substitute; the damaging confusion side effect lacks that check and can affect a target behind a surviving Substitute.
- Disable's PP candidate check uses raw bytes in player/link-target paths, exposing another PP Up/zero-current-PP distinction.
- Self-confusion first retains only `CONFUSED` in battle-status byte 1, then the common cleanup clears selected multi-turn flags.
- Haze's status-3 mask preserves Transform and undefined high bits while clearing Toxic/screens.
- `CalcHitChance` writes the scaled value back into the loaded move-record accuracy byte.
- `wDamageMultipliers` records STAB plus the latest matching type-table multiplier; it is not a canonical encoding of net dual-type effectiveness.

### Party, AI, items, and progression

- `StartBattle` performs its first-living-enemy scan before mode dispatch, including wild, Safari, and Old Man battles. A supplied reset needs a precondition for the scanned enemy-party region.
- Player/enemy HP synchronization copies four contiguous bytes, including the active party-position/box-level alias. Enemy AI switching writes its party index into party `MON_BOX_LEVEL`.
- Generic trainer AI leaves `wAICount` unchanged and therefore consumes direct `Random` on every later eligible action.
- Poke Flute scans six fixed party slots rather than `wPartyCount` and likewise scans six enemy slots in trainer battles.
- Rare Candy, vitamins, stones, PP Up, and TM/HM items reject in battle. Ether/Max Ether/Elixer/Max Elixer remain battle-usable.
- The raw `POKEDEX` dispatch never clears the initialized success result; if injected into a bag, entering/exiting its UI consumes the battle action and needs a proved scratch/timing frame.
- In Safari, the out-of-balls check runs immediately after every successful action and before duration text or the escape roll.
- Non-link Pay Day/evolution uses `wBattleResult == 0`; the link branch reaches evolution directly. The result byte alone remains insufficient to classify semantic outcomes across modes.

## Architectural decisions changed by this pass

1. `LinkBattleState` is canonically a pair of cartridge-perspective battle states plus serial exchange state.
2. A synchronized quotient is only a future optimization with a proof that it expands to the pair.
3. Cartridge divergence and runner fuel exhaustion are separate from game outcomes. The fourth pass further replaces a clean result enum with a witnessed terminal cause plus raw fields, because cleanup erases discriminators.
4. Link reset consumes post-setup per-side blocks; cable electrical/setup execution remains outside the reset theorem, but its possible output asymmetry is representable.
5. The high-level state includes or explicitly projects battle-exit handoff bytes written before return.
6. Canonical bag validation excludes the out-of-table `$54`–`$C3` item-ID gap; raw machine semantics still executes its malformed pointer lookup.

## Validation performed

Source scripts checked:

- 165 move records;
- 151 base-stat files, with 150 main-table includes;
- 190 internal-to-Pokédex entries;
- 47 trainer AI entries;
- 86 nonzero-effect pointer entries;
- 83 ordinary-item pointer entries;
- exact item ID-to-pointer row equality for [Item dispatch](../reference/item-dispatch.md);
- exact effect ID/pointer and six phase-array equality for [Effect dispatch](../reference/effect-dispatch.md);
- all recorded source SHA-256 values;
- all local Markdown links and whitespace.

These are source/document consistency checks, not ROM or Lean verification.

## Remaining implementation-time checks

1. Rebuild the ROM with RGBDS 1.0.2 and derive authoritative symbol addresses/ranges.
2. Trace the leading-zero link setup case in an independent emulator and record both post-setup WRAM blocks.
3. Prove or refute projected-state frame conditions for raw-bag Pokédex and Surfboard paths.
4. Generate the transitive call graph through predefs, text callbacks, pointer tables, and banked jumps.
5. Choose exact reset/checkpoint preconditions for the unconditional enemy-party scan in supplied wild/Safari/tutorial battles.
6. Differentially trace status-cure stat resets, disobedient PP slot selection, Counter critical state, OHKO random order, Substitute equality, and EXP All double division.
7. Resolve licensing and select the independent emulator oracle.
