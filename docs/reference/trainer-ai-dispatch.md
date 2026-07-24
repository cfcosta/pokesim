# Trainer AI dispatch

<!-- mode: reference -->

**Baseline:** `pret/pokered` commit `405b6246372d7e5a2cb029cbb65219b13286b8c9`.

The trainer controller has two independent tables. `TrainerClassMoveChoiceModifications` selects scoring layers before a move is chosen. `TrainerAIPointers` supplies a per-Pokémon successful-action count and an action routine called immediately before enemy execution.

## Move-choice layers

| Layer | Score mutation |
|---:|---|
| 1 | If the player already has a nonzero status byte, add 5 to zero-power moves with `EFFECT_01`, `SLEEP_EFFECT`, `POISON_EFFECT`, or `PARALYZE_EFFECT`. |
| 2 | Only while `wAILayer2Encouragement == 1`, subtract 1 for effect IDs `$0A`–`$19` or `$32`–`$41`. The test is by numeric interval, not semantic family. |
| 3 | Subtract 1 for the first-match type helper's super-effective result. For a not-effective result, add 1 only if the scan finds Super Fang, a special-damage effect, Fly, or a nonzero-power move of a different type. |

`ExecuteEnemyMove` increments `wAILayer2Encouragement` before status gates. It normally enables layer 2 on the second selection, but AI action substitution delays the increment, status-blocked execution still increments it, forced replacement clears it, and voluntary AI switching retains it.

All four scores start at 10. The disabled slot is overwritten with `$50`. The minimum-score filter writes move IDs into selected slots and zero into the rest.

The layer routines stop scanning at the first zero move ID. In malformed state, a zero first slot followed by a nonzero slot can make the minimum-score loop restart forever for a class with at least one scoring layer. Canonical generated move lists use a contiguous nonzero prefix.

After filtering, `SelectEnemyMove` uses one `BattleRandom` byte with these exact initial buckets:

| Slot | Accepted bytes | Count |
|---:|---|---:|
| 1 | `0..62` | 63 |
| 2 | `63..126` | 64 |
| 3 | `127..189` | 63 |
| 4 | `190..255` | 66 |

A blank or disabled selected slot retries with another `BattleRandom` call. The distribution is therefore not four exactly equal 25% buckets. See [Probability thresholds](probability-thresholds.md) for the shared macro expansion and other battle boundaries.

## Exact class table

| ID | Class | Move layers | Initial action count | Action routine |
|---:|---|---|---:|---|
| `$01` | `YOUNGSTER` | — | 3 | `GenericAI` |
| `$02` | `BUG_CATCHER` | 1 | 3 | `GenericAI` |
| `$03` | `LASS` | 1 | 3 | `GenericAI` |
| `$04` | `SAILOR` | 1, 3 | 3 | `GenericAI` |
| `$05` | `JR_TRAINER_M` | 1 | 3 | `GenericAI` |
| `$06` | `JR_TRAINER_F` | 1 | 3 | `GenericAI` |
| `$07` | `POKEMANIAC` | 1, 2, 3 | 3 | `GenericAI` |
| `$08` | `SUPER_NERD` | 1, 2 | 3 | `GenericAI` |
| `$09` | `HIKER` | 1 | 3 | `GenericAI` |
| `$0A` | `BIKER` | 1 | 3 | `GenericAI` |
| `$0B` | `BURGLAR` | 1, 3 | 3 | `GenericAI` |
| `$0C` | `ENGINEER` | 1 | 3 | `GenericAI` |
| `$0D` | `UNUSED_JUGGLER` | 1, 2 | 3 | `JugglerAI` |
| `$0E` | `FISHER` | 1, 3 | 3 | `GenericAI` |
| `$0F` | `SWIMMER` | 1, 3 | 3 | `GenericAI` |
| `$10` | `CUE_BALL` | — | 3 | `GenericAI` |
| `$11` | `GAMBLER` | 1 | 3 | `GenericAI` |
| `$12` | `BEAUTY` | 1, 3 | 3 | `GenericAI` |
| `$13` | `PSYCHIC_TR` | 1, 2 | 3 | `GenericAI` |
| `$14` | `ROCKER` | 1, 3 | 3 | `GenericAI` |
| `$15` | `JUGGLER` | 1 | 3 | `JugglerAI` |
| `$16` | `TAMER` | 1 | 3 | `GenericAI` |
| `$17` | `BIRD_KEEPER` | 1 | 3 | `GenericAI` |
| `$18` | `BLACKBELT` | 1 | 2 | `BlackbeltAI` |
| `$19` | `RIVAL1` | 1 | 3 | `GenericAI` |
| `$1A` | `PROF_OAK` | 1, 3 | 3 | `GenericAI` |
| `$1B` | `CHIEF` | 1, 2 | 1 | `GenericAI` |
| `$1C` | `SCIENTIST` | 1, 2 | 3 | `GenericAI` |
| `$1D` | `GIOVANNI` | 1, 3 | 1 | `GiovanniAI` |
| `$1E` | `ROCKET` | 1 | 3 | `GenericAI` |
| `$1F` | `COOLTRAINER_M` | 1, 3 | 2 | `CooltrainerMAI` |
| `$20` | `COOLTRAINER_F` | 1, 3 | 1 | `CooltrainerFAI` |
| `$21` | `BRUNO` | 1 | 2 | `BrunoAI` |
| `$22` | `BROCK` | 1 | 5 | `BrockAI` |
| `$23` | `MISTY` | 1, 3 | 1 | `MistyAI` |
| `$24` | `LT_SURGE` | 1, 3 | 1 | `LtSurgeAI` |
| `$25` | `ERIKA` | 1, 3 | 1 | `ErikaAI` |
| `$26` | `KOGA` | 1, 3 | 2 | `KogaAI` |
| `$27` | `BLAINE` | 1, 3 | 2 | `BlaineAI` |
| `$28` | `SABRINA` | 1, 3 | 1 | `SabrinaAI` |
| `$29` | `GENTLEMAN` | 1, 2 | 3 | `GenericAI` |
| `$2A` | `RIVAL2` | 1, 3 | 1 | `Rival2AI` |
| `$2B` | `RIVAL3` | 1, 3 | 1 | `Rival3AI` |
| `$2C` | `LORELEI` | 1, 2, 3 | 2 | `LoreleiAI` |
| `$2D` | `CHANNELER` | 1 | 3 | `GenericAI` |
| `$2E` | `AGATHA` | 1 | 2 | `AgathaAI` |
| `$2F` | `LANCE` | 1, 3 | 1 | `LanceAI` |

Class ID zero and IDs beyond `$2F` are outside the canonical table domain.

## Action routines

`TrainerAI` returns before drawing for wild or link battles and when `wAICount == 0`. Otherwise it lazily replaces `$FF` with the table count, calls ordinary hardware-coupled `Random`, and jumps to the routine. A failed threshold, failed HP test, failed switch, or `GenericAI` does not decrement the count.

| Routine | Condition and action |
|---|---|
| `GenericAI` | No action; clears carry. The initialized count remains unchanged, so another direct `Random` is consumed on every later eligible action. |
| `JugglerAI` | `random < 64`; switch if at least two enemy party members are living, then choose the lowest-index living slot other than the active member without another draw. |
| `BlackbeltAI` | `random < 32`; X Attack. |
| `GiovanniAI` | `random < 64`; Guard Spec. |
| `CooltrainerMAI` | `random < 64`; X Attack. |
| `CooltrainerFAI` | The commented-out return makes the random comparison ineffective. Hyper Potion below `floor(maxHP/10)`; otherwise switch below `floor(maxHP/5)`. |
| `BrunoAI` | `random < 64`; X Defend. |
| `BrockAI` | Ignore the random value; Full Heal whenever status is nonzero. |
| `MistyAI` | `random < 64`; X Defend. |
| `LtSurgeAI` | `random < 64`; X Speed. |
| `ErikaAI` | `random < 128` and HP below `floor(maxHP/10)`; Super Potion. |
| `KogaAI` | `random < 64`; X Attack. |
| `BlaineAI` | `random < 64`; Super Potion without an HP threshold. |
| `SabrinaAI` | `random < 64` and HP below `floor(maxHP/10)`; Hyper Potion. |
| `Rival2AI` | `random < 32` and HP below `floor(maxHP/5)`; Potion. |
| `Rival3AI` | `random < 32` and HP below `floor(maxHP/5)`; Full Restore. |
| `LoreleiAI` | `random < 128` and HP below `floor(maxHP/5)`; Super Potion. |
| `AgathaAI` | `random < 20`: switch. For `20..127`, Super Potion below `floor(maxHP/4)`. Otherwise no action. |
| `LanceAI` | `random < 128` and HP below `floor(maxHP/5)`; Hyper Potion. |

HP threshold comparisons are strict. Successful items decrement `wAICount`; a switch initializes the incoming member's count to `$FF` rather than decrementing the outgoing count. All successful AI switch routines share `EnemySendOut`'s deterministic lowest-index-other-living destination. Its search has no explicit party-count bound, and voluntary switching retains `wAILayer2Encouragement`.

## State and proof obligations

- Move-choice `BattleRandom` and action-AI direct `Random` are distinct sources and sites.
- AI item stat effects preserve the loaded enemy move-record bytes around `StatModifierUpEffect`.
- AI status cures clear party/active status and `BADLY_POISONED` but do not rebuild burn/paralysis-reduced active stats.
- AI switching copies HP, active party-position, and status into the outgoing party record, overwriting `MON_BOX_LEVEL` with the party index; it then resets participation for the new enemy and deterministically selects the lowest-index other living slot.
- Move lists with malformed gaps retain their exact early-return, retry, or divergence behavior.
- The class table, layer byte streams, counts, and pointers require ROM-byte decoder and original-byte equality theorems.
