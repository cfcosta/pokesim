# Current battle engine

<!-- mode: explanation -->

This page explains how the pinned `pret/pokered` battle implementation is assembled and why a faithful simulator cannot be designed as a simple move-damage function.

## The engine is distributed

The battle coordinator is `pokered/engine/battle/core.asm`, but battle semantics cross many files and ROM banks. `pokered/main.asm` places code into `Battle Engine 1` through `Battle Engine 11`, `Battle Core`, and several adjacent sections. Important dependencies include:

- `pokered/engine/battle/effects.asm` and `pokered/engine/battle/move_effects/*.asm` for move effects;
- `pokered/engine/battle/trainer_ai.asm` for move scoring and trainer actions;
- `pokered/engine/items/item_effects.asm` for battle items and capture;
- `pokered/home/move_mon.asm` for stat calculation;
- `pokered/engine/math/multiply_divide.asm` and `pokered/home/math.asm` for byte-accurate arithmetic;
- `pokered/home/random.asm`, `pokered/engine/math/random.asm`, and `pokered/home/vblank.asm` for ordinary RNG;
- `pokered/engine/pokemon/add_mon.asm`, `pokered/engine/pokemon/evos_moves.asm`, and `pokered/engine/pokemon/experience.asm` for party construction, moves, and progression;
- ROM tables under `pokered/data/moves`, `pokered/data/battle`, `pokered/data/types`, `pokered/data/trainers`, and `pokered/data/pokemon`.

This distribution matters to verification. A proof that only covers the `pokered/engine/battle` directory would omit capture, items, stats, RNG, experience, and party construction.

## Lifecycle

### Initialization

`InitBattle` begins at `pokered/engine/battle/core.asm:6642`. It either uses an already selected opponent or asks the overworld encounter code to select one, and may return without a battle. The supplied-battle machine theorem enters at `InitOpponent` (or composes `InitBattle`'s immediate nonzero-opponent prefix) with a valid bank/stack frame. Random encounter triggering remains a separate caller theorem; mode-specific loading still belongs to the battle-driver theorem.

`InitBattleCommon` distinguishes wild from trainer opponents using the internal opponent ID boundary. Trainer setup calls `ReadTrainer`; wild setup calls `LoadEnemyMonData`. `InitBattleVariables` clears `wMiscBattleData` and selected standalone fields, but it is not a full arbitrary-WRAM reset. Volatile bytes in `wBattleStatusData` rely partly on the prior `EndOfBattle` cleanup, and normal/Old Man `wBattleType` is caller/prior-state data because initialization only writes Safari mode when the current map is in the Safari range. A supplied reset needs a named sanitized byte image rather than an assumption that this routine clears everything. Transition/setup execution also touches VRAM, OAM, MMIO, audio state, and externally banked SRAM used as sprite scratch; a WRAM-only runner cannot reach `StartBattle` faithfully.

Important initialization behavior includes:

- wild Pokémon receive two random DV bytes in `LoadEnemyMonData`;
- trainer Pokémon use fixed DV bytes `$98` and `$88`;
- wild moves are derived from base moves plus level-up data;
- trainer moves come from generated enemy party structures and may receive special patches;
- active stat modifiers start at stage value 7;
- current active stats are copied separately from party data and then modified for burn, paralysis, and badges.

### First send-out

`StartBattle` (`core.asm:132`) scans for a living enemy record, checks whether any player party member is alive, and only on the ordinary battle path finds/loads the first living player member and initializes participation flags.

The first living enemy scan is unconditional, even for wild, Safari, and Old Man paths that already have an active opponent. It reads enemy-party HP records until finding a nonzero value and has no explicit bound. Supplied resets therefore need an exact caller-state precondition for this scratch/party region; “wild active HP is nonzero” alone is insufficient.

### Main loop

`MainInBattleLoop` (`core.asm:280`) starts by checking both active HP values. It then decides how much selection is available.

The top-level battle menu is bypassed only when the player is already in Rage, must recharge, is thrashing, or is on the continuation turn of a charge move. Sleep, freeze, Bide, the player's trapping continuation, and being trapped by the opponent are checked **after** `DisplayBattleMenu`. In those states the player can still choose a switch, item, or run attempt; choosing Fight skips ordinary move-slot selection and lets the status/lock path determine the turn.

A successful item, switch, or failed wild escape attempt records that the player has already consumed the turn. A prohibited trainer-battle run attempt does not consume the turn; the player must choose again. Move selection is therefore only one possible player action source, and “forced turn” must not be modeled so broadly that it removes cartridge-available item/switch/run choices.

`SelectEnemyMove` chooses a move before order resolution. In link battles it receives the remote selection. In ordinary wild battles it samples move slots. In trainer battles it first asks `AIEnemyTrainerChooseMoves` to score/filter candidates, then samples among eligible slots. Slot sampling uses buckets of 63, 64, 63, and 66 bytes for slots 1–4, then retries blank or disabled slots; it should not be replaced by a uniform `choose` over a filtered vector without a transcript proof.

### Selection UI leaks into mechanics

The battle menu cannot be discarded as pure presentation:

- choosing Fight resets `wNumRunAttempts`, even if the player later cancels the move menu;
- `PrintMenuItem` writes a non-disabled highlighted move to `wPlayerSelectedMove` and loads its record; disabled highlights skip that reload, while canceling leaves the highlighted zero-based slot in `wPlayerMoveListIndex`;
- the resulting stale move, record, and slot can alter Quick Attack/Counter order, Counter inputs, and later slot-indexed PP behavior;
- SELECT in the ordinary move menu swaps move IDs and PP in both active and party data and updates the disabled-slot encoding without consuming a turn;
- SELECT in the battle bag can reorder item/quantity pairs without consuming a turn;
- cartridge-valid but ineffective item attempts return to the bag or action menu rather than becoming API errors;
- ordinary player Mimic opens a target-move choice, while enemy and link Mimic select a nonblank target slot with `BattleRandom`.

A semantic RL action can bypass rendering, but the verified core still needs an action-commit/selection layer that represents these mechanics-visible writes.

### Action order

Order resolution is hard-coded rather than represented by a general priority number:

1. Quick Attack precedes non-Quick Attack.
2. Counter follows non-Counter.
3. Otherwise current Speed is compared.
4. Equal Speed consumes `BattleRandom`; link clock role inverts which side wins the same draw.

There is no general move-priority table in the original implementation. Selection paths that return early can leave prior selected-move bytes in place, and item/switch actions are already committed before these order checks. A high-level priority abstraction is acceptable only if proved equivalent to these branches and stale-state cases.

Immediately before the enemy would execute, `TrainerAI` may instead use an item or switch. Its carry result tells the main loop that the AI action consumed the enemy's action.

A full link battle cannot be represented permanently as one shared state. Each cartridge executes a local player path and a mirrored enemy path, retains its own party copy and `BattleRandom` cursor/list, and exchanges compact choices. The two perspectives are related while synchronized, but source-reachable asymmetric draw paths can break that relation. At link `EndOfBattle`, the local cartridge copies only active enemy status back to its mirrored enemy party slot, not active enemy HP; the final authoritative persistent party is each cartridge's local player party, not the other side's disposable mirror.

### Switch and send-out flow

`MainInBattleLoop` copies active player HP, party-position alias, and status back to the party before menu selection. A player switch then marks the incoming member as a participant, loads its segmented party record, applies burn/paralysis before non-link badge boosts, resets six stages to 7, clears volatile flags/Disable, and leaves several counters stale but inactive.

The reset is partial. Player send-out clears the selected-slot index and loaded move number but retains shared `wDamage`, `wPlayerSelectedMove`, and adjacent loaded effect/power/type/accuracy/PP bytes. Since switching was committed before order resolution, outgoing/highlighted scratch can still affect same-turn ordering and Counter against the incoming member. Ordering is not cosmetic: a player-first switch no-op runs the incoming member's poison/burn residual before the enemy action, whereas enemy-first ordering attacks first. Stale Quick Attack/Counter bytes can decide whether a poisoned switch-in faints before the enemy moves.

Non-link enemy send-out deterministically chooses the lowest-index living slot other than the outgoing member; AI switching has no destination draw. The search itself has no count bound. Forced replacement resets `wAILayer2Encouragement`, while voluntary AI switch retains it. A successful AI switch substitutes for enemy execution, so the ensuing enemy poison/burn residual belongs to the incoming member.

Recall text is timing-relevant. `RetreatMon` computes a low-byte quotient from wrapped `(last enemy HP - current enemy HP)`, `25`, and `low8(maxHP / 4)`. Enemy healing can underflow the message class, and a raw zero divisor diverges. Even when the text is dropped from semantic events, its branch/delay remains in hardware/RNG coupling. See [Switch, faint, and participation flow](../reference/switch-faint-and-participation.md).

### Per-action residuals

After each side acts, `HandlePoisonBurnLeechSeed` applies that acting side's burn/poison and Leech Seed effects. Residuals are therefore associated with each action, not one shared “end of round” phase.

The routine computes `maxHP / 16` with a minimum of one. If Toxic is active, it increments and multiplies by the Toxic counter. The same counter also multiplies Leech Seed damage, preserving the known Toxic/Leech Seed interaction noted in `core.asm:547`.

There is no faint check between poison/burn and Leech Seed. If poison already reduced the acting member to zero, Leech Seed still subtracts from zero, increments Toxic again when flagged, and heals the opponent. The healing amount remains the nominal computed `bc` even when damage was capped as overkill rather than the HP actually lost.

Faint checks occur between actions, but only after that acting side's combined poison/burn/seed routine finishes. This affects whether the second side acts, whether side effects happen after a KO, and how simultaneous KOs are resolved.

### Fainting and termination

`HandleEnemyMonFainted` and `HandlePlayerMonFainted` are separate paths. They update party structures, clear volatile state, award experience, request replacements, or conclude the battle.

The separation contains observable asymmetries. Player faint clears nonvolatile status in active and party state, clears only the gain-EXP bit, preserves the fought-current-enemy bit for a possible Revive, and leaves its own volatile block until replacement/cleanup. Enemy faint zeros trainer-party HP but retains its party status, clears enemy volatile state immediately, and clears only the high byte of the player's Bide accumulator. The player-faint counterpart clears both enemy Bide bytes. In a link battle, that difference can desynchronize the two machines.

Revive or Max Revive restores a fainted member's gain-EXP bit iff its preserved fought bit is set. EXP All's second pass sets every in-count party bit before division, so fainted members reduce living shares even though `GainExperience` later skips them. After a wild player faint, the run-or-replace prompt always passes stored `wPartyMon1Speed` to the run formula, regardless of which member fainted or remains alive and without active paralysis/stage/badge Speed changes.

Trainer victory adds prize money before `StartBattle` returns. It can also call caller-provided trainer end text, clear its flag, save a trainer name, and alter trainer sprite movement. That text chooses win/lose pointer from raw `wBattleResult`; a simultaneous-faint victory with raw result 1 can print the loss text and still award prize money.

The `StartBattle` terminal edge is not episode completion. `EndOfBattle` can add Pay Day, request/cancel evolution, invoke move learning, mutate party/Pokédex state, then clean battle bytes and write cooldown/destination handoff. `_InitBattleCommon` finally restores letter delay, map palette, and tile animation, sets carry, and returns through bank/predef wrappers. Only that return is RL `done`.

Caller behavior after that return is separate: the overworld may perform blackout money/heal/warp, trainer scripts later set fought/object flags, and the cable club immediately calls `HealParty`. The Old Man battle itself restores `wPlayerName` but leaves the aliased `wGrassRate`/wild buffer overwritten. See [End-to-end closure](../reference/end-to-end-closure.md).

## Active state is duplicated

A party member is not used directly in battle. The engine copies it into an active structure:

- player party entry: `wPartyMonN*`;
- player active entry: `wBattleMon*`;
- enemy party entry: `wEnemyMonN*`;
- enemy active entry: `wEnemyMon*`.

The active structure contains current battle types, stats, moves, and PP. Separate blocks retain “unmodified” stats and stage modifiers. Volatile flags and counters live elsewhere in WRAM.

Copies occur at send-out, switch, item use, level-up, capture, and fainting. Some mutations update both copies immediately; others intentionally do not. Transform, for example, changes active data while preserving original party PP rules. Verification must prove synchronization only at named checkpoints, not assume the two representations are always equal.

See [Battle state model](../reference/battle-state-model.md).

## Move execution is a staged interpreter

The move record has six bytes:

```text
animation | effect | power | type | accuracy | PP
```

The `effect` byte does not map to one uniform post-damage callback. `ExecutePlayerMove` (`core.asm:3073`) and `ExecuteEnemyMove` use several classification tables that place effects at different phases.

A simplified player path is:

```text
status/lock checks
  → load selected move record
  → charge/disobedience checks
  → decrement player PP
  → ResidualEffects1? execute effect and skip ordinary damage/hit path
  → SpecialEffectsCont? execute effect before damage, then continue
  → SetDamageEffects? skip normal damage calculation
  → critical-hit test
  → Counter handling
  → normal damage calculation
  → STAB and type adjustment
  → damage randomization
  → accuracy/hit test
  → animation/failure handling
  → Mirror Move or Metronome recursion
  → ResidualEffects2? execute effect and finish
  → apply damage
  → print critical/effectiveness state
  → AlwaysHappenSideEffects? execute even around faint handling
  → multi-hit continuation
  → remaining side effect
```

The exact tables are:

- `pokered/data/battle/residual_effects_1.asm`;
- `pokered/data/battle/special_effects.asm` (`SpecialEffectsCont` is an interior label);
- `pokered/data/battle/set_damage_effects.asm`;
- `pokered/data/battle/residual_effects_2.asm`;
- `pokered/data/battle/always_happen_effects.asm`;
- `pokered/data/battle/special_effects.asm`.

Effect handlers are reached through `MoveEffectPointerTable` in `pokered/data/moves/effects_pointers.asm`. The complete memberships and all 86 pointer entries are listed in [Effect dispatch](../reference/effect-dispatch.md).

This ordering explains otherwise surprising mechanics. Zero-power moves in `ResidualEffects1` skip ordinary accuracy and damage and call accuracy from the effect when needed. Multi-hit moves choose their count before the hit test, calculate damage/accuracy only for the first hit, and reuse that damage. Trapping similarly chooses its continuation count and clears target recharge before knowing whether the first hit lands. Explosion still executes its self-KO effect after a miss. Side effects may be skipped when the target faints unless listed in `AlwaysHappenSideEffects`.

A directly selected charge/Fly effect sets charging state before `DisplayUsedMoveText` and `DecrementPP`; its PP is charged only on the second, attacking turn. Charging is only a volatile bit, not a bound move. On continuation, `GetCurrentMove` reloads the retained selected slot and treats that record as the attack turn without checking that it is the move that established charge. Consequently, Mirror Move/Metronome- or disobedience-generated charge can continue as the original wrapper/selected move; nested generation already spent the wrapper's PP before setting charge, while a disobedient replacement did not.

If self-confusion, full paralysis, or a newly disabled selected move interrupts a directly selected attack turn, charging is cleared without clearing Fly/Dig invulnerability, leaving the active member invulnerable until a later volatile reset such as switching. The direct charge move spent no PP on either turn; a nested wrapper may already have spent PP on its generation turn.

Bide's continuation adds the shared `wDamage` value each time it is checked, rather than recording a clean stream of HP loss events, so stale or Substitute-related damage remains observable. Drain effects also replace `wDamage` in place with `max(floor(damage / 2), 1)` while healing; a later Counter or Bide check therefore observes the reduced scratch value. Mirror Move and Metronome compensate recursive PP decrement by incrementing the current slot first; for a transformed player that increment still reaches original party PP while the later decrement does not.

Conversion has no ordinary hit test or Substitute check. It copies the target's current active types into the user, but fails when the target's `INVULNERABLE` bit is set. Explosion/Selfdestruct zero the user's active HP/status and clear its seeded flag in their effect phase even when the attack later misses.

A simulator that models every move as `damage` followed by `optional effect` will be wrong.

## Damage pipeline

`GetDamageVarsForPlayerAttack` and `GetDamageVarsForEnemyAttack` select offensive and defensive stats. Type indexes below `SPECIAL` are physical; indexes at or above it are special. Generation I has one Special stat.

The pipeline is:

1. choose current stats, including Reflect/Light Screen;
2. for a critical hit, replace current modified stats with unmodified calculated party/enemy stats and double level;
3. if either stat needs more than one byte, divide both by four and retain low-byte values;
4. evaluate the staged integer formula in `CalculateDamage`;
5. cap neutral damage at 999;
6. add STAB by `damage + floor(damage / 2)`;
7. apply each matching defender type entry sequentially from `TypeEffects`;
8. call `BattleRandom`, rotate the returned byte right once with `rrca`, reject the rotated value below 217, then multiply by the accepted 217–255 value and divide by 255;
9. apply damage, capped to current HP.

Intermediate flooring and byte extraction are semantic. Replacing the assembly with one rational formula and rounding at the end changes outcomes.

The scaling path can produce a zero defensive divisor. The original machine can freeze there. The model must preserve this as divergence rather than clamp defense to one.

Counter still runs `CriticalHitTest` before its own handling, so it consumes that draw and may retain the critical flag/text even though its damage comes from doubled shared `wDamage`. A speed-eligible OHKO likewise reaches ordinary type adjustment, damage randomization, and then accuracy in source order; speed failure exits earlier. These paths need call-site traces rather than simplified “special damage” formulas.

## Accuracy and critical hits

`MoveHitTest` checks Dream Eater sleep, then Swift, Substitute, Fly/Dig invulnerability, Mist, X Accuracy, stage scaling, and the final random comparison in that order. Swift returns before Substitute/invulnerability; X Accuracy returns only after those earlier gates and Mist, so it bypasses accuracy/evasion and the final draw, not every reason a move can fail. `CalcHitChance` floors after the accuracy ratio and again after the reflected evasion ratio, enforces a minimum of one after each division, caps the final value at 255, and destructively replaces the loaded move-accuracy byte. Thus raw accuracy zero still hits for random byte zero, while scaled 255 still misses for byte 255.

Accuracy stages are applied in two multiply/divide passes through the approximate `StatModifierRatios` table. Intermediate truncation is observable. The final test misses when `random >= scaledAccuracy`, so even a stored accuracy of 255 misses for random byte 255.

`CriticalHitTest` derives its threshold from base Speed and a high-critical-move list. The Focus Energy branch shifts right instead of left, reducing critical chance. It rotates the sampled random byte three times before comparison. These are implementation rules, not corrections to make.

## Status representation and ordering

Nonvolatile status is one byte:

- low three bits: sleep counter;
- bit 3: poison;
- bit 4: burn;
- bit 5: freeze;
- bit 6: paralysis.

Volatile state uses three additional flag bytes per side plus dedicated counters. Status gates are checked in an explicit order: sleep, freeze, trapping, flinch, recharge, Disable expiration, confusion, selected-disabled-move, paralysis, Bide, Thrash, trapping continuation, and Rage. This order determines which counters decrement and which random calls occur.

For example, waking from sleep consumes the turn in Red/Blue. Confusion is checked before paralysis. Self-confusion first reduces battle-status byte 1 to the `CONFUSED` bit alone, and self-confusion/full paralysis then clear selected multi-turn states. Freeze has no natural thaw roll; qualifying Fire-type side-effect moves can defrost a target through `CheckDefrost`.

Rest writes a fixed sleep value of 2 into active status but does not clear `BADLY_POISONED` or the Toxic counter. After Rest or the damaged-HP Full Restore path, a later ordinary poison can inherit stale Toxic state; Leech Seed can use that Toxic state even while Rest's sleep status is active. Stat modification has additional cross-stat behavior. Outside link, any player stat-up, including accuracy/evasion and X items, reapplies all obtained badge boosts to all four player combat stats; any enemy stat-down against the player does the same. The common burn/paralysis helpers act on the opponent for self stat-ups and on the target for stat-downs, so unrelated changes can repeatedly halve/quarter already penalized current stats. At an exact current stat of 999 or one, a failed two-stage effect can silently leave a one-stage change while printing “nothing happened.” Outside link, the enemy-only `< 64` stat-down failure draw also precedes effect classification, so damaging enemy stat-down side effects require that gate and a later independent `< 85` draw. See [Stat modifier flow](../reference/stat-modifier-flow.md).

`SleepEffect` also clears the target's Hyper Beam recharge flag before checking existing status or accuracy. If recharge was set, it skips those checks and proceeds directly to choosing a sleep counter. The freeze side-effect path clears enemy recharge when the player freezes the enemy, but the mirrored enemy-attacker branch does not clear player recharge. These asymmetries belong in the model.

### Traded-Pokémon disobedience

After loading the chosen move and before ordinary execution, the player path calls `CheckForDisobedience`. Link battles and Pokémon whose OT ID matches the player always obey. Otherwise badge-dependent level thresholds and several rejection loops can cause the Pokémon to:

- use the selected move;
- replace it with another usable move;
- nap by setting a sampled sleep counter;
- loaf, turn away, or ignore orders;
- hurt itself through the self-confusion damage path.

This logic consumes `BattleRandom`, reads menu cursor/PP state, and can reload a different move record. The replacement branch changes `wCurrentMenuItem` but not `wPlayerMoveListIndex`, so later `DecrementPP` charges the originally selected slot. Its final candidate check also tests the full PP byte, allowing PP Up bits to make zero-current-PP data look usable. It is battle mechanics, not trainer AI.

## Trainer logic has two layers

Trainer behavior has two distinct mechanisms:

1. **Move scoring** in `AIEnemyTrainerChooseMoves` adjusts four scores and keeps only minimum-score moves. Trainer classes opt into up to three modifications: avoid redundant status, encourage selected effects, and consider type effectiveness.
2. **Action AI** in `TrainerAI` may replace the move with an item or switch immediately before execution. Each trainer class supplies a per-Pokémon count that successful item actions decrement; no-op paths can leave it unchanged indefinitely.

Move scoring uses `BattleRandom` for final slot selection. Its type helper stops at the first matching defender type and initializes neutral to hexadecimal `$10`, not the damage system's decimal 10. `TrainerAI` calls ordinary `Random` before dispatching the class routine whenever its count is nonzero, including Generic AI and threshold branches that perform no action. Successful item actions decrement the count; Generic/no-op consideration does not, so Generic trainers continue drawing on later actions. AI status cures clear status/Toxic bytes without rebuilding Attack or Speed, while the player medicine path has different stat-copy behavior. The final move-slot buckets are 63/64/63/66 bytes before blank/disabled retries, not four equal quarters. `wAILayer2Encouragement` starts at zero and increments when `ExecuteEnemyMove` begins; because layer 2 runs only at exactly one, it normally affects the second move selection, while skipped execution, status locks, or AI substitutions alter that timing. Forced replacement clears it, but a voluntary AI switch does not, so the value can carry to the switched-in member. Malformed leading-zero move lists can also diverge in the minimum-score loop for classes with scoring layers. These calls are hardware/timing dependent and must remain distinct from move-scoring `BattleRandom`. The complete class rows and routine thresholds are in [Trainer AI dispatch](../reference/trainer-ai-dispatch.md).

Non-link enemy Pokémon do not decrement PP in the original game. `DecrementPP` is player-specific. Enemy move selection mostly ignores PP and only handles the special case where a sole move is disabled. The wiki's “Enemy Pokémon Use PP” page is a modification tutorial, not a description of the base implementation.

## Items and capture are battle semantics

The battle menu delegates to `UseItem`, whose dispatch table is in `pokered/engine/items/item_effects.asm`. In-scope item behavior includes medicines, X items, Guard Spec, Dire Hit, Poke Flute, Poke Doll, PP items if permitted by the base routine, and balls.

Capture is a substantial byte-level algorithm. It performs ball-specific rejection sampling, status adjustments, HP divisions, two ordinary random tests, and a separate shake-count calculation. A trainer's ball is consumed and consumes the action even though capture is rejected; party count exactly 6 plus box count exactly 20 rejects the attempt without consuming the ball or turn. Unidentified Ghost and restless Marowak rejection occurs after the throw and consumes the ball. Successful capture preserves the target HP/status/DVs, rebuilds species data and moves, sets Pokédex flags, and mutates either the party or current box. If the target's Transform flag is set, capture first forces `wEnemyMonSpecies2` to Ditto; this also affects a non-Ditto wild Pokémon that acquired Transform through Mirror Move.

Capture also enters `AskName` before returning, after the owned Pokédex write/optional data display and partway through storage mutation. An ordinary bag ball is not removed until naming and record construction finish; the Safari Ball counter was decremented before the throw. Party count/species/OT are appended before naming and the 44-byte record is built afterward. Box count/species/OT/nickname arrays are inserted or shifted before naming, while 33-byte records are shifted and slot 1 built afterward. The nickname response, partial request-phase layouts, and final ordered box mutation are therefore episode semantics, not post-battle storage work. Capacity tests use equality rather than `>=`: raw party counts 7–254 can reach successful capture without storage/naming, while oversized or wrapped box counts can drive out-of-bounds shift loops.

PP Up, vitamins, Rare Candy, and evolution stones explicitly reject in-battle use, but Ether, Max Ether, Elixer, and Max Elixer can require both a party target and a move target. Poke Flute scans six fixed party slots on each applicable side, not each recorded party count, and then clears both active sleep fields; it still consumes the action when no Pokémon was reported asleep. A successful player status cure on the active member copies party max HP and all four combat stats back into active state without reapplying stages, badges, burn, or paralysis. Full Restore's damaged-HP branch does not take that copy path and also leaves `BADLY_POISONED` set. The exact 83-entry disposition is recorded in [Item dispatch](../reference/item-dispatch.md).

Safari bait and rock alter both catch and escape factors. Bait halves the current actual catch rate and rock doubles it with saturation; repeated uses compound. Each use zeroes the opposite duration and adds a rejection-sampled 1–5 to its own duration. `PrintSafariZoneBattleText` restores the species catch rate only when the rock/escape factor reaches zero, not when bait expires. The Safari escape check doubles the low byte of enemy Speed and immediately flees on carry before applying bait or rock; otherwise bait quarters and rock doubles the threshold before direct `Random` comparison.

## Experience remains part of battle

`GainExperience` runs when an enemy faints outside link battles. It:

- divides base stats, catch rate, and base experience among participating recipients;
- adds stat experience;
- computes base experience from enemy level and species yield;
- applies traded and trainer-battle 1.5× boosts;
- caps total experience at level 100's threshold;
- recalculates levels and stats;
- updates an active recipient and reapplies stages, status penalties, and badge boosts;
- may enter the nested move-learning/forget/HM-rejection/abandon-confirmation protocol.

With EXP All, the source first halves the enemy data, then the first `GainExperience` call may destructively divide it by the number of participants; the all-party call divides those already-mutated bytes again. Recipient counting inspects all eight flag bits even though the party loop uses the recorded party count. `LearnMoveFromLevelUp` stops after the first move at the exact resulting level, so intermediate skipped levels and additional same-level rows are ignored. If an active transformed Pokémon does learn a move, `LearnMove` copies all four party moves and PP back into active state while leaving the transformed flag and other copied state set.

A level gain sets `wCanEvolveFlags`. For non-link battles, `EndOfBattle` calls `EvolutionAfterBattle` only when `wBattleResult == 0`; the link branch reaches the call directly. This occurs before clearing `wIsInBattle` and before `InitBattle` returns, so these evolution mechanics are inside a full battle episode. The model must include cancellation, species/stat/type/move mutation, and the source-annotated bug that can satisfy an item-evolution check after a wild battle without consuming a stone. Evolution rendering remains presentation-only.

Trainer victory also adds `wAmountMoneyWon` to player money before returning. Non-link `EndOfBattle` adds accumulated Pay Day money when `wBattleResult == 0`; the proof must use that byte guard rather than silently equate it with every semantic notion of victory. Poke Doll and move-based escape set `wEscapedFromBattle` but normally leave result zero, so they can still reach Pay Day/evolution; ordinary Run and capture write result 2 and skip both. Simultaneous faint order can make player-faint cleanup overwrite zero with one even on a control path that later awards trainer prize money.

`EndOfBattle` clears `wEscapedFromBattle`, battle mode, opponent, and volatile state while preserving the raw result byte. Final WRAM therefore cannot distinguish every outcome: victory, Poke Doll/move escape, Safari escape, and Safari Balls exhaustion can all end with result zero. Refinement needs a terminal control-flow witness captured before cleanup, followed by a separate epilogue theorem. After `EndOfBattle`, the outer wrapper also restores `wLetterPrintingDelayFlags`, `wMapPalOffset`, and `hTileAnimations`, then returns with carry set. Exact paths are listed in [Battle outcomes](../reference/battle-outcomes.md). The later overworld blackout routine that halves money and heals the party is outside `InitBattle` and should be a separately named boundary. However, the battle driver itself clears the always-on-bike flag on most loss paths, and `EndOfBattle` sets the wild-encounter cooldown and destination warp ID; those handoff writes require an explicit projection rather than an unchanged-memory frame claim.

## Bugs are part of the target

The disassembly itself annotates many mechanics-affecting bugs. Initial examples include:

- Focus Energy reducing critical chance (`core.asm:4507`);
- 255 accuracy still missing on random 255 (`core.asm:5322`);
- Toxic's counter scaling Leech Seed, including poison-KO-then-Seed and nominal overkill healing (`core.asm:547`);
- asymmetric Psywave range (`core.asm:4663` and `4782`);
- asymmetric Bide accumulator clearing (`core.asm:747`);
- Substitute allowing its user to reach exactly zero HP, and a substitute surviving when incoming damage equals its remaining substitute HP (`move_effects/substitute.asm` and `AttackSubstitute`);
- Transform's invulnerability checks using overloaded/wrong state (`move_effects/transform.asm:5`);
- Swift bypassing Fly/Dig because its return occurs first (`core.asm:5245` vicinity);
- enemy stat-down moves receiving an extra 25% failure check outside links (`effects.asm:552`);
- AI effectiveness starting at `$10` instead of decimal 10 (`core.asm:5200`);
- Reflect/Light Screen bypassing the 999 cap before stat scaling;
- player and enemy Psywave consuming their per-cartridge link RNG states differently;
- menu cursor state feeding Counter after Fight is canceled;
- `SleepEffect` clearing recharge before hit/status checks;
- player/enemy freeze side-effect recharge asymmetry;
- Safari bait expiration not restoring catch rate;
- post-battle item-evolution checks reusing aliased state after wild battles;
- EXP All's second award dividing source bytes already divided by the participant award;
- active status medicine replacing combat stats with party stats without reapplying stages/status/badges;
- link setup's external-clock scan skipping leading zero seed bytes;
- Rest retaining Toxic volatile state;
- drain replacing shared damage scratch before Counter/Bide;
- transformed non-Ditto capture becoming Ditto;
- 63/64/63/66 enemy move-slot buckets;
- cleanup erasing terminal-cause evidence and simultaneous faint order conflicting with the raw result byte;
- Fly/Dig interruption clearing charge but not invulnerability, before a direct move's PP decrement;
- generated charge reloading the retained wrapper/original selected move rather than binding the generated move;
- failed two-stage stat changes at exact current 999/1 silently retaining one stage;
- capture naming and slot-1 current-box insertion;
- transformed active move learning restoring party moves/PP without clearing Transform;
- player send-out retaining selected/loaded move scratch after clearing only slot index/move number;
- deterministic unbounded enemy replacement scan;
- fainted fought-participant revival restoring EXP eligibility and EXP All counting fainted divisors;
- wild-faint escape using party slot 1 Speed;
- recall-text healing underflow and raw zero-divisor divergence before same-turn enemy execution;
- simultaneous-faint trainer victory selecting lose text from raw result before awarding prize;
- Old Man name restoration leaving the aliased wild-encounter buffer overwritten;
- caller-specific post-return link auto-heal/blackout behavior differing from battle-driver output.

The high-level core should encode these with source-linked regression theorems. A later corrected ruleset must be a separate module and must never be confused with the cartridge-equivalent model.
