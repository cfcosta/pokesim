# Fifth-pass ASM audit

<!-- research record; completed against the pinned source commit -->

**Baseline:** `pret/pokered` commit `405b6246372d7e5a2cb029cbb65219b13286b8c9`.

This pass reread capture construction/naming, level-up move learning, charge/PP interruption, stat-stage handlers, accuracy-gate order, trainer layer-2 lifecycle, every literal battle `percent` expression, and all 165 move-record accuracy expansions. Later switch/faint refinements are recorded in the [sixth-pass ASM audit](sixth-pass-asm-audit.md).

## High-impact corrections

| Finding | ASM evidence | Documentation consequence |
|---|---|---|
| Capture includes a nested persistent naming decision | Both `_AddPartyMon` and `SendNewMonToBox` call `AskName` before the ball action returns | Added capture-nickname requests/traces and nickname bytes to the episode contract. Capture is not terminal immediately when the catch formula succeeds. |
| Current-box capture inserts rather than appends | `SendNewMonToBox` increments count and shifts species, OT names, nicknames, and 33-byte records down before writing slot 1 | Replaced generic “box mutation” wording with exact ordered slot-1 insertion and parallel-array shifts. |
| Capacity checks use equality, not bounded comparison | `ItemUseBall` branches on party count exactly 6 and rejects box count exactly 20; `_AddPartyMon` and box loops have separate malformed-count behavior | Split legal capture from raw count states: party count 7–254 can report capture without storage/naming, while oversized/wrapped box counts can shift out of bounds. |
| Fly/Dig can retain invulnerability after some charge cancellations | A directly selected first-turn `ChargeEffect` precedes `DecrementPP`; full paralysis applies `$cc`, and selected-disabled handling clears only `CHARGING_UP`, so both preserve `INVULNERABLE`. Self-confusion is different: its preceding `$80` mask keeps only `CONFUSED` and therefore clears invulnerability. | Added interruption-specific state transformers, direct-versus-nested PP distinctions, and stranded invulnerability only on the full-paralysis/Disable paths. |
| Charge state is not bound to the generating move | Continuation calls `GetCurrentMove`, then branches on the charge bit without confirming the loaded effect | Added Mirror Move/Metronome/disobedience-generated charge continuing as the retained wrapper/original selected slot rather than the generated move. |
| Two-stage stat failure can still mutate the stage | Up/down handlers write the stage, detect current stat exactly 999/1, then rollback with only one `dec`/`inc` | Added silent one-stage residue despite “nothing happened,” separately from ordinary stage caps. |
| Stat changes mutate unrelated stats/sides | Outside link, player stat-up and enemy-on-player stat-down reapply all badge boosts; common burn/paralysis helpers target the opponent for self-up and target for down | Added the exact side matrix, including accuracy/evasion, X items, badge stacking, and repeated unrelated status penalties. |
| Enemy damaging stat-down side effects have two gates | Outside link, the handler's enemy-only `< 64` failure test runs before side-effect classification; a later fresh byte must be `< 85` | Added sequential 192/256 × 85/256 pair semantics and one-versus-two-byte consumption. |
| Source percentages are byte expressions, not probabilities | `percent` expands to `* $ff / 100`; move records floor their nominal accuracy, while call sites add/subtract and choose `<`/`>=` branches | Added [Probability thresholds](../reference/probability-thresholds.md) with every unique literal expression, all 165 move-accuracy expansions, and exact accepted-byte counts. |
| Move learning is a nested protocol | Full movesets enter learn confirmation, forget selection, HM rejection, cancel, and abandon-confirmation loops | Replaced flat forget/decline assumptions with canonical-action refinements plus full selection traces. |
| Learning while transformed can restore original moves | After an active party member learns, `LearnMove` copies all four party moves and PP into `wBattleMon` without clearing `TRANSFORMED` | Added the mixed transformed-state regression and phase-specific active/party requirements. |

## Capture and naming findings

The ball path sets the owned Pokédex flag and, for a first catch, completes `ShowPokedexData` before storage construction reaches `AskName`. For ordinary bag balls, inventory removal is deferred until after naming and record construction; Safari Balls were decremented before the throw. `AskName` then asks whether to nickname the captured member. Accepting enters the naming screen; declining or returning an empty name copies the default species name. The choice affects persistent party/box nickname bytes and presentation timing/VBlank activity.

Party capture:

- increments count, appends species/terminator, and writes the new OT entry;
- invokes `AskName`, which writes the nickname while the new record is not yet built;
- then builds the 44-byte record;
- copies captured HP/status/DVs and active calculated stats;
- writes player OT ID, level-derived experience, zero stat EXP, and move PP.

For well-formed counts, current-box capture:

- is admitted only when party count is 6 and current-box count is below 20;
- increments box count;
- inserts species at index 0 and shifts the species terminator/list;
- shifts every existing OT name and nickname by one fixed-length entry;
- invokes `AskName` for slot 1 while box records are still in their old positions;
- only after naming, shifts every existing 33-byte box record by one slot;
- builds slot 1 from captured active data, player OT ID, level-derived EXP, zero stat EXP, original DVs, and active PP.

Old Man capture bypasses player party/box addition and naming.

Capacity checks are equality-sensitive. The ball path treats only party count 6 as full and only box count 20 as a blocking full box. For raw party counts 7–254, it chooses `_AddPartyMon`, whose incremented-count `ret nc` returns without adding or naming; the outer successful-capture path still continues. Party count 255 wraps inside `_AddPartyMon` and follows malformed indexing. With party count exactly 6 but box count above 20 (or wrapping from 255), `SendNewMonToBox` proceeds with oversized shift counts and terminator-dependent writes beyond the legal arrays. These states are excluded by legal APIs but retained by raw-state machine semantics.

## Charge, PP, and invulnerability findings

When directly selected, the first turn of Razor Wind, SolarBeam, Skull Bash, Sky Attack, Fly, or Dig jumps to `ChargeEffect` before move-use text and `DecrementPP`. The second turn normally clears charging/invulnerability, prints the move, and decrements PP.

The volatile charge state does not retain a generated move identity. A continuation reloads the retained selected slot through `GetCurrentMove` and, solely because `CHARGING_UP` is set, executes that loaded record as an attack turn. Therefore:

- Metronome-generated charge spends Metronome PP before establishing charge, then reloads and executes Metronome on continuation;
- Mirror Move-generated charge spends Mirror Move PP, then reloads Mirror Move and copies again on continuation;
- a disobedient replacement charge establishes charge before PP decrement, then continuation reloads and executes the originally selected slot while skipping another disobedience check;
- Fly/Dig generation still supplies invulnerability during the interval even when the generated move is not the continuation record.

On the attack turn:

- full paralysis applies `$cc`, clearing Bide/Thrash/charge/trapping while leaving `INVULNERABLE` untouched;
- self-confusion first applies `$80`, keeping only `CONFUSED`, and therefore clears `INVULNERABLE` before entering the common `$cc` tail;
- `PrintMoveIsDisabledText` applies `$ef`, clearing charging only and preserving every other raw status-1 bit;
- all three interruption paths return before the continuation's `DecrementPP`;
- full paralysis or selected Disable can therefore make Fly/Dig selectable again while the member remains invulnerable, whereas self-confusion does not strand invulnerability;
- a directly selected charge spent no PP, whereas a nested Mirror Move/Metronome wrapper already spent its own PP on the generation turn.

Sleep, freeze, trapping, flinch, and recharge return earlier without clearing charge, so they delay rather than strand the charge state. Switching or another exact volatile reset removes the retained invulnerability.

## Stat modifier findings

The complete flow is in [Stat modifier flow](../reference/stat-modifier-flow.md). Key source consequences are:

- the 13 stage rows use exact stored ratios `25/100`, `28/100`, `33/100`, `40/100`, `50/100`, `66/100`, `1/1`, `15/10`, `2/1`, `25/10`, `3/1`, `35/10`, `4/1`, with immediate integer flooring;
- stage values are updated before combat-stat exact-cap checks;
- a two-stage effect at current 999/1 may retain one stage while current stat and failure text imply no change;
- outside link, player accuracy/evasion-up moves still reapply all player badge boosts; their status helpers also reapply opponent penalties;
- outside link, enemy accuracy/evasion-down moves still reapply all player badge boosts; their status helpers also reapply player penalties;
- player self-up affects enemy burn/paralysis penalties, not the player's own;
- enemy self-up and AI X items affect player burn/paralysis penalties;
- unrelated stat changes can repeatedly halve current Attack or quarter current Speed because those helpers mutate in place;
- capped AI X-stat attempts still consume the item action count.

## Accuracy and probability findings

`MoveHitTest` gate order is:

1. Dream Eater target sleep;
2. Swift early return;
3. Substitute and the broken drain check;
4. Fly/Dig invulnerability;
5. Mist for selected stat-down effect ranges;
6. acting-side X Accuracy;
7. accuracy/evasion scaling;
8. final `BattleRandom` comparison.

X Accuracy therefore bypasses only stages/final comparison after earlier gates. Swift returns before Substitute and Fly/Dig.

`CalcHitChance` applies the accuracy ratio and reflected evasion ratio as two separate multiply/divide steps, flooring and enforcing a minimum of one after each. It caps only the final value at 255 and stores that scaled value back into the loaded move-accuracy field. Consequently raw accuracy zero still accepts random byte zero, while accuracy 255 still rejects random byte 255.

The 165 move records use only nominal accuracies 30/55/60/65/70/75/80/85/90/95/100, stored as 76/140/153/165/178/191/204/216/229/242/255. Exact notable runtime probabilities include:

- full paralysis: 63/256;
- confusion self-hit: 128/256;
- confusion side effect: 25/256;
- regular/“2” elemental or flinch side effects: 26/256 and 77/256;
- poison side effects: 52/256 and 103/256;
- player damaging stat-down side effect: 85/256;
- non-link enemy damaging stat-down side effect with no Substitute: sequential `>= 64` then `< 85`, or 16,320/65,536 accepted byte pairs;
- extra non-link enemy stat-down failure: 64/256;
- enemy move initial slot buckets: 63/64/63/66;
- accepted rotated damage factor per draw: 39/256 before rejection repeats.

These are transcript rules; replacing them with nominal decimal percentages changes boundaries or draw counts.

## Trainer layer-2 lifecycle

`wAILayer2Encouragement` is not simply a per-Pokémon turn number:

- battle initialization/forced replacement sets it to zero;
- `ExecuteEnemyMove` increments it before enemy status gates;
- move scoring layer 2 runs only when the byte is exactly one;
- an AI item/switch substitutes for execution and therefore does not increment it;
- status-blocked `ExecuteEnemyMove` does increment it;
- voluntary `SwitchEnemyMon` does not reset it;
- forced `ReplaceFaintedEnemyMon` resets it after send-out;
- byte wrap can make raw long-running state reach one again.

The common case is layer 2 on the second selection, but it can be delayed, repeated after AI substitution, skipped by status timing, or inherited across voluntary switches.

## Move-learning findings

`LearnMoveFromLevelUp` scans sorted learnset rows and stops after the first row whose level exactly equals `wCurEnemyLevel`. It does not process intermediate levels skipped by a multi-level gain and does not continue to a second row at the same level, including when the first matching move is already known. The stock learnsets contain no duplicate-level rows, but raw/modified-table semantics still has this early stop.

For a full moveset:

1. the game asks whether to learn;
2. accepted learning opens move selection;
3. selecting an HM prints rejection and loops;
4. B/cancel returns to abandonment confirmation;
5. declining abandonment loops back to learning;
6. confirming abandonment exits without learning.

After a successful active-member learn, all four party moves and PP are copied into active state. There is no Transform guard, so a transformed active learner can regain original-party moves/PP while retaining transformed species/type/stat/flag state. This is reachable, for example, when transformed Mew reaches one of its exact learnset levels in a multi-opponent battle.

## Architectural decisions changed by this pass

1. Capture naming is a typed mechanics request with a canonical trace refinement and a full controller-trace theorem; its pending phase includes the already-written Pokédex flag, the not-yet-removed ordinary bag ball (or already-decremented Safari count), and partially mutated storage arrays.
2. Captured nickname/OT arrays are projected persistent state when exact party/current-box mutation is claimed.
3. Current-box output is ordered slot-1 insertion, not an abstract storage append.
4. Move learning is a nested request state machine; atomic RL responses are proved adapters only.
5. Stat modifier summaries include post-update badge/status side effects and exact-cap rollback, not only stage arithmetic.
6. Charge state is an unbound continuation bit; the model tracks retained selection, PP commitment, and invulnerability independently.
7. Probability specifications use source-expanded byte thresholds and comparison polarity.

## Validation performed

Source/document checks cover:

- every unique literal `percent` expression in battle core/effects/trainer AI against the numeric reference table;
- all 165 move rows against the nominal-accuracy/expanded-byte counts;
- all 13 stat-stage numerator/denominator rows;
- all 47 trainer class layer/count/pointer rows and action threshold expressions;
- all 83 item ID/pointer rows;
- all 87 effect IDs, 86 pointer rows, and six phase arrays;
- move/species/trainer/item/effect/Pokédex cardinalities;
- all recorded source SHA-256 values;
- all local Markdown links and whitespace.

These remain source consistency checks, not ROM-linked Lean proofs.

## Remaining implementation-time checks

1. Trace party and box captures through nickname decline, custom name, and empty-name fallback; compare Pokédex/resource timing, every parallel array, and raw capacity boundaries `5/6/7/254/255` and `19/20/21/255`.
2. Derive a bounded nickname-byte type and prove a canonical response's naming-screen trace.
3. Differentially trace direct, Mirror Move/Metronome-generated, and disobedience-generated charge, then attack-turn full paralysis, self-confusion, and Disable, including PP and later switch reset.
4. Test exact-stat 999/1 with one- and two-stage moves/items for both sides and accuracy/evasion variants.
5. Trace badge/status stacking and the enemy-side-effect two-gate sequence for player stat-up, enemy stat-down, and AI X-item paths.
6. Verify all probability boundaries and rejection counts through the ROM runner.
7. Exercise layer-2 timing through sleep, AI item, voluntary switch, forced replacement, and byte wrap.
8. Trace same-level duplicate learnset rows, HM rejection loops, and transformed active learning.
9. Rebuild the canonical ROM and generate symbol/range proofs once RGBDS and Lean are available.
