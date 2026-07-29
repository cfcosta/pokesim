<!-- mode: explanation -->
# Episode 606 Fly audit

## Finding

Self-play episode 606 exposed a mechanics defect in the high-level link model. Pidgeot's first Fly turn correctly set `CHARGING_UP | INVULNERABLE` (`$50`), but the next decision still admitted ordinary moves and switches. Repeated Fly selections restarted charge instead of forcing the retained attack turn.

The historical trace therefore diverged at decision 4. Its player legal mask was `1519`; the cartridge-compatible mask is `1024`, action 10 (`noAction`) only.

## Cartridge behavior

Canonical Red identifies four relevant windows in ROM bank `$0f`:

| Routine | CPU address | ROM offset | Relevant bytes | Meaning |
|---|---:|---:|---|---|
| `MainInBattleLoop` | `$425e` | `$03c25e` | `7e e6 12 20 43` | Test Thrash/charge and bypass the menu |
| `PlayerCanExecuteChargingMove` | `$56a9` | `$03d6a9` | `21 62 d0 cb a6 cb b6` | Select player status 1, clear bits 4 and 6 |
| `EnemyCanExecuteChargingMove` | `$670b` | `$03e70b` | `21 67 d0 cb a6 cb b6` | Clear the same enemy flags |
| `ChargeEffect.chargeEffect` | `$78a1` | `$03f8a1` | `cb e6 1a 1b fe 2b 20 04 cb f6 06 64` | Set charge; for Fly effect `$2b`, set invulnerability |

The bytes came from a temporary rebuild of pret/pokered commit `405b6246372d7e5a2cb029cbb65219b13286b8c9`. The rebuilt image matched canonical Red SHA-256 `5ca7ba01642a3b27b0cc0b5349b52792795b62d3ed977e98a09390659af96b7b`.

The control flow is asymmetric across the two turns:

1. Fly setup sets bits 4 and 6 and does not decrement PP.
2. The next loop bypasses move selection.
3. Status checks run against the retained move. A successful check clears both bits.
4. The retained Fly executes and decrements the retained slot's PP.

The existing Gen-I interruption bug remains intact: full paralysis, self-confusion, or a disabled selected move clears charging but can leave invulnerability set.

## Repair

The action layer now admits only `.noAction` while a full-menu-bypass bit is active. The engine interprets that command as an automatic move only when the cartridge would bypass or skip move selection. It reloads the retained move and slot, runs status checks, clears successful charge state, executes the retained move, and decrements PP on the attack turn.

An `action` event remains the selected protocol command. A separate `move-executed` event records the move that passed status gating. This matters for Fly: the corrected second turn records selected action 10 and executed move 19 (`Fly`), rather than claiming that Pidgeot waited.

The repair also stopped effect-context installation from restoring the pre-decrement PP array. That overwrite had hidden the charge-turn decrement even after automatic execution was restored.

## Proof and executable evidence

| Evidence | Claim |
|---|---|
| `Battle.Rom.FlyRoutine.RequiredFlyBytes` | Caller-supplied canonical ROM contains all four exact windows |
| `decoded_charge_control` | Bytes decode as the expected `AND`, conditional branch, `RES 4/6`, and `SET 4/6` instructions |
| `player_continuation_exact` | Three decoded SM83 instructions execute as the player charge-clear transformer |
| `player_continuation_result` | The transformer clears bits 4 and 6 at `$d062` and falls through at `$56b0` |
| `Battle.Full.charging_forces_no_action` | Charging state admits no fresh move or switch |
| `Battle.Full.Engine.charge_continuation_protocol` | Action 10 executes the retained charge move and enables its PP decrement |
| `Battle.Full.Status.successful_charge_clears_both` | Successful continuation clears charging and invulnerability for every status byte |
| `tools/check-episode-606-fly.py` | Original generated teams and actions replay the failure boundary deterministically |

The episode regression starts from reset seed `20270726`, episode `606`, party sizes `6v5`. After Pidgeot selects Fly, it observes status 1 `$50`, legal mask `1024`, and Fly PP 15. Action 10 then executes Fly, deals 125 HP to Machamp, changes Fly PP to 14, clears status 1 to zero, and restores the ordinary legal mask `495`.

This proves the repaired control slice and its correspondence to exact canonical instructions. It does not claim whole-ROM battle equivalence.
