# Switch, faint, and participation flow

<!-- mode: reference -->

**Baseline:** `pret/pokered` commit `405b6246372d7e5a2cb029cbb65219b13286b8c9`.

Switching and fainting cross active records, party records, volatile bytes, participation flags, UI timing, and terminal-result writes. They are not representable as one generic “replace active member” operation.

## Player switch sequence

At the start of every `MainInBattleLoop`, `ReadPlayerMonCurHPAndStatus` copies four active bytes to the current party record:

1. current HP high;
2. current HP low;
3. `wBattleMonPartyPos`, into the party record's `MON_BOX_LEVEL` byte;
4. nonvolatile status.

A menu switch therefore starts from a party record whose HP/status has already been synchronized. `SwitchPlayerMon` then:

1. calls `RetreatMon` and waits/animates;
2. writes `wPlayerMonNumber := wWhichPokemon`;
3. sets the incoming member's gain-EXP and fought-current-enemy bits;
4. loads the incoming party record into active state;
5. applies burn/paralysis penalties, then non-link badge boosts;
6. resets the six meaningful stat stages to 7;
7. runs `SendOutMon`'s volatile/scratch reset and presentation.

An ordinary switch adds the incoming participation bits without clearing prior participants. A free Shift-style switch follows a different prelude described below.

## Retreat text is timing-relevant arithmetic

`RetreatMon` chooses the recall message from enemy HP lost since its last send-out. It computes, using cartridge-width arithmetic:

```text
delta   := (wLastSwitchInEnemyMonHP - wEnemyMonHP) mod 65536
divisor := low8(floor(wEnemyMonMaxHP / 4))
q        := low8(floor((delta * 25) / divisor))
```

The selected text is:

| `q` | Text class |
|---:|---|
| 0 | `EnoughText` |
| 1–29 | `ComeBackText` |
| 30–69 | `OKExclamationText` |
| 70–255 | `GoodText` |

Consequences:

- healing above the HP recorded at send-out underflows `delta`, producing a wrapped message class;
- only the quotient's low byte is classified;
- raw states with `divisor = 0` enter `_Divide` with zero and diverge;
- different text branches and lengths change presentation timing before the enemy executes the remainder of the turn.

The message is mostly presentation, but its timing belongs in the low-level hardware/RNG coupling. A high-level action adapter cannot silently replace the whole switch trace with a fixed-cycle operation.

## Player send-out reset

`LoadBattleMonFromParty` and `SendOutMon` together establish the following state:

| State | Incoming player behavior |
|---|---|
| HP/status/types/moves/DVs/level/stats | Loaded from the selected party record through the source's segmented codec |
| Unmodified level/stats | Copied before burn/paralysis and badges |
| Burn/paralysis | Applied to current Attack/Speed |
| Badge boosts | Applied after status penalties, except in link battle |
| Six stat stages | Set to 7 |
| Two stat-stage padding bytes | Not reset by the six-byte loop |
| `wPlayerBattleStatus1..3` | Cleared via the five-byte `wPlayerStatsToDouble` block |
| Multi-turn/confusion/Toxic counters | Left as stale bytes; cleared flags make them inactive |
| Disable packed byte and disabled move ID | Cleared |
| Minimize presentation byte | Cleared |
| `wBattleAndStartSavedMenuItem`, `wPlayerMoveListIndex` | Cleared |
| `wBoostExpByExpAll`, `wDamageMultipliers`, `wPlayerMoveNum` | Cleared; shared `wDamage` and the remaining loaded move-record bytes are not blanket-cleared |
| `wPlayerUsedMove`, `wEnemyUsedMove` | Both cleared |
| Opponent `USING_TRAPPING_MOVE` | Cleared, allowing the switch to break trapping |

`wPlayerSelectedMove` and shared `wDamage` are not cleared by this sequence, and clearing `wPlayerMoveNum` does not clear the adjacent loaded effect/power/type/accuracy/PP bytes. The action was already committed before order resolution, so retained selected-move and record scratch can still participate in the same turn's ordering and Counter logic even though `wPlayerMoveListIndex` and the loaded move number were cleared. If the player no-op is ordered first, the switched-in member's poison/burn residual runs before the enemy acts; if ordered second, the enemy attacks first. Stale Quick Attack/Counter selection can therefore decide whether a poisoned switched-in member faints before receiving the enemy action.

## Enemy send-out and destination

For non-link trainer battles, `EnemySendOut` scans party slots from index 0 upward, skips `wEnemyMonPartyPos`, and chooses the first other member with nonzero HP. This same deterministic lowest-index rule serves forced replacement and voluntary trainer-AI switching; there is no random destination draw.

The scan has no explicit party-count bound. A preceding `AnyEnemyPokemonAliveCheck` makes it safe for ordinary forced replacement, and `AISwitchIfEnoughMons` establishes at least two living members for an ordinary AI switch. Raw states that satisfy one check but provide no discoverable terminator/living target can scan beyond the enemy party.

In link battle, the received selection byte is reduced by 4 and used as `wWhichPokemon` without a local range check. Protocol validity and raw serial-byte behavior therefore require separate theorems.

Before a voluntary AI or received link switch, `SwitchEnemyMon` copies outgoing active HP, active party index, and nonvolatile status to the party record; the index overwrites `MON_BOX_LEVEL`. Moves, PP, transformed types/stats, and other active-only state are not copied.

Enemy send-out:

- clears both participation bytes, then marks the currently active player as the sole participant against the new enemy;
- clears five contiguous enemy stat/status bytes, Disable state, Minimize state, and both used-move bytes;
- clears the player's trapping-continuation flag;
- initializes incoming `wAICount` to `$FF`;
- loads the incoming enemy and resets its six stat stages;
- records incoming HP in `wLastSwitchInEnemyMonHP`.

Forced `ReplaceFaintedEnemyMon` additionally clears `wAILayer2Encouragement`. A voluntary AI switch does not, even though it reinitializes `wAICount` for the incoming member. Because the switch substitutes for enemy execution, the following enemy residual pass applies the incoming member's poison/burn state, not the withdrawn member's.

## Shift-style participation

Before showing the Shift prompt, `EnemySendOut` has already reset both participation bytes and marked the old player active as having fought the new enemy.

If the player accepts a Shift switch, the routine clears both bytes again before calling `SwitchPlayerMon`. The incoming player member therefore becomes the sole participant against the new enemy. If the player declines or cancels party selection, the existing active member remains the sole participant.

Shift is suppressed for initial send-out, link battle, Set mode, and a player party count exactly equal to one. The count check is equality-sensitive in raw state.

## Participation lifecycle

| Transition | `wPartyGainExpFlags` | `wPartyFoughtCurrentEnemyFlags` |
|---|---|---|
| Initial player send-out | Set active bit | Set active bit |
| Ordinary player switch | Add incoming bit | Add incoming bit |
| Player member faints | Clear fainted bit | Preserve fainted bit |
| Revive/Max Revive on a fainted member | Restore bit iff its fought bit is set | Preserve |
| New enemy send-out | Clear all, then set current active | Clear all, then set current active |
| Shift switch for new enemy | Clear all, then set incoming | Clear all, then set incoming |
| End of `GainExperience` | Clear all, then set current active | Clear all, then set current active |
| EXP All second pass | Set bits from party count before award | Unchanged until award completion |

Preserving the fought bit across fainting is mechanics-visible: reviving that member before the same enemy faints restores its gain-EXP bit, allowing it to receive a share. Without revival, the cleared gain bit excludes it.

`DivideExpDataByNumMonsGainingExp` counts all eight gain-flag bits before `GainExperience` skips fainted members and iterates only the recorded party count. EXP All can therefore count fainted party members as divisors even though they receive no award, in addition to the already-documented out-of-party raw flag bits.

## Player-versus-enemy faint asymmetry

| Behavior | `RemoveFaintedPlayerMon` | `FaintEnemyPokemon` |
|---|---|---|
| Party HP | Active HP is already zero and is synchronized | Trainer enemy party HP is explicitly zeroed |
| Party nonvolatile status | Active status is cleared, then copied to party | Enemy party status is retained |
| Own volatile status block | Retained until replacement or cleanup | Enemy five-byte stat/status block is cleared immediately |
| Opponent multi-hit flag | Enemy `ATTACKING_MULTIPLE_TIMES` cleared | Player `ATTACKING_MULTIPLE_TIMES` cleared |
| Opponent Bide accumulator | Both enemy bytes cleared | Only player's high byte cleared; low byte survives |
| Participation | Gain bit cleared; fought bit retained | No corresponding enemy EXP flags |
| Raw result write | Writes 1 | Later writes 0 only if some player party member remains alive and the faint/EXP path reaches that point |

If another player member is available, its send-out clears the retained player volatile flags. On blackout or another terminal edge, those bytes remain visible at the pre-cleanup checkpoint until `EndOfBattle` clears the battle region.

The enemy-faint path may call the player-faint routine during simultaneous faint handling. Result writes, EXP eligibility, messages, and trainer payout therefore depend on which control-flow edge discovered the simultaneous zero HP first, not only on final HP bytes.

## Wild-faint run response

After a player faint in a wild battle, choosing “No” at the use-next-member prompt attempts to run before mandatory replacement. The speed pointer passed to `TryRunningFromBattle` is always `wPartyMon1Speed`, not the fainted active slot, the first living member, or a subsequently selected replacement.

Thus slot 1's stored party Speed controls this escape attempt even when slot 1 is fainted or was never active. It is the party calculated stat, not an active Speed modified by paralysis, stages, or badges. The ordinary run-attempt counter and inclusive comparison still apply. A failed attempt proceeds to the non-cancelable replacement menu; a successful attempt terminates without choosing a member.

## Malformed-count behavior

Several loops rely on legal counts:

- `AnyPartyAlive` with party count zero performs 256 iterations because its 8-bit counter underflows;
- `AnyEnemyPokemonAliveCheck` behaves analogously for enemy count zero;
- the EXP All gain-flag loop with party count zero also performs 256 rotations and ends with all flag bits set;
- non-link enemy destination search has no count bound;
- link replacement accepts an unchecked received selection after subtracting 4;
- retreat-message division diverges when the low-byte divisor is zero.

Battle-valid APIs exclude these states. The byte-level machine semantics and raw-state theorems preserve them.

## Proof obligations

- Define separate player and enemy active/party synchronization lemmas for switch, faint, level-up, and battle exit.
- Prove the segmented party-to-active codecs and the `MON_BOX_LEVEL`/party-position alias write.
- Preserve send-out reset asymmetries, stale counters, untouched stat-stage padding, and retained `wPlayerSelectedMove`.
- Prove deterministic lowest-index enemy selection and its ordinary preconditions; classify unbounded raw scans separately.
- Track participation and gain flags as distinct bytes, including faint → revive → EXP and EXP All/fainted-divisor cases.
- Retain the player/enemy faint status, Bide, volatile, and result-write asymmetries.
- Include `wPartyMon1Speed` in wild-faint run-response tests.
- Couple recall-text selection and delay to low-level timing without making presentation text a high-level battle event.
