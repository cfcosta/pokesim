# Sixth-pass ASM audit

<!-- research record; completed against the pinned source commit -->

**Baseline:** `pret/pokered` commit `405b6246372d7e5a2cb029cbb65219b13286b8c9`.

This pass reread player/AI/link switching, player and enemy send-out, active/party codecs, participation flags, Revive, EXP recipient division, faint handlers, wild-faint replacement/escape, and switch recall-text arithmetic. Driver-wide integration closure is recorded in the [seventh-pass audit](seventh-pass-end-to-end-audit.md).

## High-impact corrections

| Finding | ASM evidence | Documentation consequence |
|---|---|---|
| Player send-out is a partial scratch reset | `SendOutMon` clears `wPlayerMoveListIndex` and `wPlayerMoveNum`, but not `wPlayerSelectedMove` or the rest of the loaded move record | Added same-turn ordering/Counter and switched-in residual obligations; stale priority can put incoming poison/burn before or after the enemy action. |
| Enemy switch destination is deterministic | Non-link `EnemySendOut.next2` scans upward from slot 0, skips `wEnemyMonPartyPos`, and selects the first nonzero HP | Removed any implicit random destination; AI switch consumes only its action gate draw and then selects the lowest-index other living member. |
| Enemy destination search is unbounded | `.next2` has no party-count comparison | Added ordinary preconditions and raw scan-beyond-party/divergence behavior. |
| Faint and Revive use two participation bytes differently | `RemoveFaintedPlayerMon` clears only `wPartyGainExpFlags`; Revive tests `wPartyFoughtCurrentEnemyFlags` and restores gain eligibility | Added faint → revive → same-enemy EXP semantics instead of one participation set. |
| EXP All counts fainted recipients that receive nothing | The second pass sets all in-count gain bits; division counts all eight bits before `GainExperience` skips zero-HP records | Added reduced living shares from fainted divisor bits and raw out-of-party bits. |
| Player and enemy faint status cleanup differ | Player faint zeros active status then synchronizes party; enemy faint zeros trainer-party HP but not party status and clears its active volatile block | Added side-specific terminal/replacement projections. |
| Wild-faint escape uses party slot 1 | `DoUseNextMonDialogue.tryRunning` passes `wPartyMon1Speed`, not the active/selected member | Added an exact request transition and regression even when slot 1 is fainted or was never active. |
| Recall text performs mechanics-adjacent arithmetic | `RetreatMon` subtracts current enemy HP from send-in HP, multiplies by 25, divides by low byte of `maxHP/4`, and classifies only quotient low byte | Added healed-enemy underflow, raw divide-by-zero divergence, and presentation-timing coupling before enemy execution. |

## Active/party and player-switch findings

`MainInBattleLoop` begins with `ReadPlayerMonCurHPAndStatus`, so ordinary menu selection sees the current active player's HP/status synchronized to its party record. The four-byte copy also writes active `PartyPos`/`BoxLevel` alias data back to `MON_BOX_LEVEL`.

`SwitchPlayerMon` marks the incoming member in both participation bytes, then uses `LoadBattleMonFromParty`'s segmented codec:

1. copy the active-prefix fields through moves;
2. skip party OT ID, EXP, and stat EXP to copy DVs;
3. copy PP;
4. copy level and calculated stats;
5. copy nickname separately;
6. snapshot unmodified level/stats;
7. apply burn/paralysis penalties;
8. apply badges outside link;
9. write 7 to six meaningful stage bytes.

The two padding bytes following those six stages are not reset.

`SendOutMon` then clears:

- battle/start menu cursor and player move-list index;
- EXP-All boost scratch, damage multiplier, and loaded player move number;
- both used-move bytes;
- the five-byte player stats-to-double/halve plus three volatile-status block;
- player Disable packed byte/ID and Minimize presentation byte;
- enemy trapping-continuation flag.

It does not blanket-clear:

- `wPlayerSelectedMove` and shared `wDamage`;
- loaded player effect/power/type/accuracy/PP bytes adjacent to the cleared move number;
- multi-turn, confusion, or Toxic counters;
- stage padding bytes.

The flags/Disable reset makes the retained counters inactive in legal flow. The retained selection/record is still live during same-turn order and enemy Counter because action commitment and switching occurred before order resolution. If stale priority/order selects the player path first, `ExecutePlayerMove` no-ops but the switched-in member's poison/burn residual runs before the enemy action. If ordered second, the enemy attacks first. A poisoned incoming member can therefore faint before the enemy moves solely because outgoing/highlighted selection scratch won order.

## Enemy send-out findings

For a non-link trainer battle, `EnemySendOut` starts with candidate index 0, skips the outgoing active index, and selects the first party record with nonzero HP. Forced replacement and voluntary AI switch use this same destination rule. The AI's direct `Random` byte decides whether a switch routine is attempted; there is no second draw for destination.

Ordinary safety comes from surrounding checks:

- forced replacement previously found some living enemy member within `wEnemyPartyCount`;
- `AISwitchIfEnoughMons` counted at least two living members.

The actual destination loop does not consult the count. Raw inconsistent state can therefore scan beyond the six records until arbitrary nonzero bytes appear or execution otherwise leaves the intended region.

For link battle, `wSerialExchangeNybbleReceiveData - 4` is used as `wWhichPokemon` without a local bound check. The protocol-valid theorem proves values 4–9; arbitrary serial-byte behavior stays in the machine theorem.

Before voluntary AI or received link switching, `SwitchEnemyMon` copies only outgoing active HP, party index, and nonvolatile status into the party record, overwriting `MON_BOX_LEVEL` with the index. Active-only transformed moves/types/stats are discarded rather than synchronized.

Enemy send-out also:

- clears both player participation bytes and marks the currently active player as sole participant against the new enemy;
- clears enemy volatile flags, Disable, Minimize, and both used-move bytes;
- clears player trapping continuation;
- initializes the incoming action-AI count to `$FF`;
- records incoming HP for later player-recall text.

Forced replacement clears `wAILayer2Encouragement` after send-out. Voluntary AI switch retains it. Since that switch substitutes for `ExecuteEnemyMove`, the immediately following enemy residual phase applies the incoming member's poison/burn state.

## Shift-style findings

The new enemy is loaded before the Shift prompt. `EnemySendOut` has already reset participation and marked the old player active against that enemy.

If Shift is accepted and a valid replacement is chosen, both participation bytes are cleared again immediately before `SwitchPlayerMon`; the incoming member becomes sole participant. Canceling the party menu or declining Shift leaves the existing active as sole participant.

The prompt is suppressed by:

- initial send-out;
- player party count exactly one;
- link battle;
- Set battle style;
- AI switching's temporary `wFirstMonsNotOutYet = 1`.

The one-member test is equality-sensitive for raw party counts.

## Participation, faint, Revive, and EXP

The two participation bytes have distinct roles:

- `wPartyFoughtCurrentEnemyFlags` records that a member fought the current enemy;
- `wPartyGainExpFlags` records current eligibility for an award.

When a player member faints, only its gain bit is cleared. Its fought bit survives. Revive and Max Revive test that bit and restore the gain bit if set. A revived prior participant can therefore receive EXP when the same enemy later faints; a revived member that never fought cannot.

A new enemy send-out clears both bytes and marks the current active. `GainExperience` also ends by clearing both and marking the current active, establishing the next current-enemy baseline.

EXP All's second award builds gain flags from party count without filtering HP. `DivideExpDataByNumMonsGainingExp` counts all eight bits. `GainExperience` then skips zero-HP records and iterates only party count. A fainted party member therefore contributes to the divisor but receives no stat EXP or EXP. Bits beyond party count can do the same in raw state.

## Faint-handler asymmetry

`RemoveFaintedPlayerMon`:

- clears the fainted member's gain bit but preserves its fought bit;
- clears enemy `ATTACKING_MULTIPLE_TIMES`;
- clears both enemy Bide accumulator bytes;
- writes zero to active player nonvolatile status and synchronizes HP/alias/status to party;
- writes raw battle result 1;
- does not clear the player's own volatile block before replacement/cleanup.

`FaintEnemyPokemon`:

- synchronizes active player HP/status first;
- for trainer battles, zeros enemy party HP only and retains party status;
- clears player `ATTACKING_MULTIPLE_TIMES`;
- clears only the high byte of the player Bide accumulator;
- clears the enemy five-byte stat/volatile block, Disable, Minimize, and used-move bytes;
- writes raw result 0 only after verifying at least one player party member remains and reaching the later faint/EXP path.

These differences survive long enough to affect link synchronization, replacement, terminal witnesses, and result order. If another player member is selected, send-out clears retained player volatile flags. If the party is exhausted, those bytes remain until battle cleanup.

## Wild-faint run-or-replace findings

`DoUseNextMonDialogue` exists only for wild battle. Choosing “No” calls:

```asm
ld hl, wPartyMon1Speed
ld de, wEnemyMonSpeed
jp TryRunningFromBattle
```

It does not use `wPlayerMonNumber`, the fainted member's slot, the first living slot, or the member the user might choose next. Party slot 1's stored calculated Speed controls the fast-path comparison and escape quotient even when that member is fainted. Because this is the party field, active paralysis, stat-stage, and badge modifications are not represented.

The existing run-attempt counter is incremented by `TryRunningFromBattle`; it is not reset by entering this prompt. Success terminates. Failure consumes the attempt and proceeds to `ChooseNextMon`, whose party menu cannot be canceled and rejects fainted targets.

## Recall-text arithmetic and timing

`RetreatMon` computes:

```text
delta   = (lastSwitchInEnemyHP - currentEnemyHP) mod 65536
divisor = low8(floor(enemyMaxHP / 4))
q       = low8(floor((delta * 25) / divisor))
```

It chooses `Enough` for 0, `Come Back` below 30, `OK!` below 70, and `Good!` otherwise.

This has three proof-relevant consequences:

1. If the enemy healed above its send-in HP, unsigned subtraction wraps and can select any low-byte class.
2. A quotient above 255 is truncated rather than saturated for text selection.
3. `_Divide` does not handle divisor zero; raw max-HP values producing `low8(maxHP/4) = 0` diverge in the subtraction loop.

The selected phrase is presentation, but it occurs before the switched-in player member receives the enemy's action. Text/animation frames mutate hardware RNG through VBlank and divider timing. The semantic trace can omit the phrase while the low-level refinement preserves the selected timing path.

## Malformed-count findings

Additional byte-width loops found in this pass:

- `AnyPartyAlive` with count zero underflows and inspects 256 records/strides;
- `AnyEnemyPokemonAliveCheck` with count zero does the same;
- the EXP All gain-flag loop with party count zero rotates 256 times and ends with all bits set;
- enemy destination search has no count bound;
- Shift prompt's one-member suppression tests equality only;
- link replacement subtracts 4 from an unchecked received byte.

Battle-valid constructors exclude these states. Raw machine semantics preserves their exact reads, writes, wrap, and possible divergence.

## Architectural decisions changed by this pass

1. Switch is a proved multi-phase transition, not `active := party[i]`.
2. Send-out summaries expose a reset matrix with retained counters, stage padding, selected move, and loaded-record tail.
3. Participation uses two bytes with an explicit faint/Revive/new-enemy/award transition system.
4. Enemy switch destination is deterministic and scan-based; no high-level RNG request is emitted for it.
5. Wild-faint run response derives mechanics input from party slot 1.
6. Recall text is projected from semantic events but retained in hardware/timing refinement.
7. Player and enemy faint codecs/results remain separate until a theorem proves any common factorization.

## Validation performed

Source/document checks cover:

- all local Markdown links and table column shapes;
- all recorded source SHA-256 values;
- canonical move/species/trainer/item/effect/Pokédex cardinalities;
- every literal battle `percent` expression and all 165 move-accuracy expansions;
- all 13 stat-stage ratio rows;
- all 47 trainer class layer/count/pointer rows;
- all 83 ordinary-item ID/pointer rows;
- all 87 effect IDs, 86 pointer rows, and six phase arrays;
- exact switch/faint labels and WRAM adjacency used by the reset matrices;
- whitespace via `git diff --check`.

These are source consistency checks, not ROM-linked Lean proofs.

## Remaining implementation-time checks

1. Trace ordinary switch, Shift switch, AI switch, forced replacement, and link replacement byte-for-byte.
2. Differentially test outgoing stale Quick Attack/Counter scratch after switch, including poison/burn KO before-versus-after the enemy action.
3. Exercise faint → Revive → same-enemy KO with and without prior participation.
4. Compare EXP All awards with living/fainted party subsets and raw high flag bits.
5. Trace player versus enemy faint status/volatile/party bytes through replacement and terminal cleanup.
6. Test wild-faint escape with slot 1 fainted and active members in slots 2–6.
7. Trace recall text for HP-loss boundaries 0/1/29/30/69/70, healing underflow, quotient wrap, and zero divisor.
8. Exercise enemy destination scans over every legal party arrangement and malformed count/index states.
9. Rebuild the canonical ROM and replace source-only label checks with symbol-addressed ROM range/refinement proofs.
