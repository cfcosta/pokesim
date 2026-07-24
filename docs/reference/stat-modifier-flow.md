# Stat modifier flow

<!-- mode: reference -->

**Baseline:** `pret/pokered` commit `405b6246372d7e5a2cb029cbb65219b13286b8c9`.

`StatModifierUpEffect` and `StatModifierDownEffect` update stage bytes and, for Attack/Defense/Speed/Special, recalculate one current stat from the unmodified stat block. Accuracy and evasion update only their stage bytes. Their successful stage-update paths then run cross-cutting badge/status code whose target depends on `hWhoseTurn`.

## Stage updates

Stages use values 1–13, with 7 neutral. The ROM table stores decimal-style byte ratios rather than one symbolic Gen-I formula:

| Stage | Numerator | Denominator |
|---:|---:|---:|
| 1 | 25 | 100 |
| 2 | 28 | 100 |
| 3 | 33 | 100 |
| 4 | 40 | 100 |
| 5 | 50 | 100 |
| 6 | 66 | 100 |
| 7 | 1 | 1 |
| 8 | 15 | 10 |
| 9 | 2 | 1 |
| 10 | 25 | 10 |
| 11 | 3 | 1 |
| 12 | 35 | 10 |
| 13 | 4 | 1 |

| Effect | Stage operation |
|---|---|
| `*_UP1` | Add 1, failing before write at 13. |
| `*_UP2` | Add 2, capped at 13. |
| `*_DOWN1` | Subtract 1, failing before write at 1. |
| `*_DOWN2` | Subtract 2, capped at 1. |
| Damaging stat-down side effect | Subtract 1 only. |

For combat stats, the routine multiplies the unmodified stat by the selected ratio and divides immediately. Stat-up results cap at 999; stat-down results have a minimum of one. This recalculation does not itself include burn, paralysis, or badge modifiers.

## Exact-cap rollback anomaly

The routines write the new stage before checking whether the current combat stat is already exactly 999 for an increase or exactly one for a decrease. These are equality tests: raw current values above 999 or zero do not take this rollback branch and are instead recalculated/capped or raised to the minimum by the later arithmetic.

On that exact-current-stat path, the shared rollback changes the stage by only one step:

- a one-stage effect is fully restored;
- a two-stage effect that actually moved two stages retains a silent one-stage change;
- the current combat stat remains 999 or one;
- the routine prints “nothing happened.”

A two-stage effect already clipped to one available stage at the stage boundary is restored to its original stage.

## Post-update target matrix

After a successful stage write, the routines call badge and status helpers as follows:

| Acting side and effect | Badge reapplication | Burn/paralysis helper target |
|---|---|---|
| Player uses any stat-up move/item | Outside link, reapply every obtained player badge boost to all four player combat stats | Enemy active member |
| Enemy uses any stat-up move/item | None | Player active member |
| Player lowers enemy stat | None | Enemy active member |
| Enemy lowers player stat | Outside link, reapply every obtained player badge boost to all four player combat stats | Player active member |

These calls occur for Attack/Defense/Speed/Special and for accuracy/evasion stage changes. They are not limited to the stat named by the move.

Consequences:

- outside link, player stat-up moves and X items can stack every badge-boosted player stat;
- outside link, enemy stat-down moves can stack every player badge boost;
- a self stat-up move reapplies burn/paralysis penalties to the opponent rather than the user;
- an unrelated stat change can halve an already-burned target's current Attack again or quarter an already-paralyzed target's current Speed again;
- enemy X-stat items can repeatedly penalize a burned/paralyzed player even though the item targets the enemy.

The affected combat stat is first rebuilt without badge/status modifiers, so its post-call value may differ from unrelated stats that are modified in place again.

## Failure and random gates

Outside link battles, every enemy stat-down handler entry—including damaging side effects—first consumes an extra `BattleRandom` byte and returns on bytes below 64. This occurs before the Substitute check, effect classification, and any ordinary hit test.

Direct stat-down moves that pass that gate call `MoveHitTest`; Mist and accuracy/invulnerability behavior are therefore observed through that later path.

Damaging stat-down side effects that pass the enemy-only gate:

- fail against Substitute;
- consume their separate side-effect draw and succeed for bytes below 85;
- do not call `MoveHitTest` again;
- return silently if the target stage is already minimal.

For a player side effect, the probability gate is one `< 85` draw. For a non-link enemy side effect with no Substitute, it is a sequential `>= 64` draw followed by a fresh `< 85` draw: 192 × 85 accepted byte pairs out of 65,536, with one or two bytes consumed depending on the first result. The handler is reached only after the target-survival phase permits the remaining effect.

Direct failed stage changes print the failure text. Side-effect failures generally return without that direct-move message.

## Loaded-record and item behavior

AI X-stat items temporarily replace the enemy loaded animation/effect bytes, call `StatModifierUpEffect`, then restore those bytes. The stage/stat/badge/status mutations remain. A capped stage still consumes the AI item/action count because `AIIncreaseStat` decrements after the effect routine returns.

Minimize uses the ordinary evasion-up path and additionally records its presentation state. Substitute hide/show animation branches do not change the stage arithmetic.

## Proof obligations

- Preserve all six meaningful stage bytes plus two padding bytes in each modifier block.
- Prove ratio lookup and immediate flooring for each stage value.
- Cover current-stat boundaries `0/1/2` and `998/999/1000` separately from stage boundaries 1 and 13.
- Preserve the silent one-stage residue of failed two-stage effects at exact stat caps.
- Model the post-update matrix by acting side; do not attach badge/status updates only to the named stat.
- Distinguish direct stat-down accuracy failure, the extra enemy-only failure draw, and damaging side-effect probability.
- Include AI X-item paths and accuracy/evasion moves in badge/status-stacking regressions.
