# Codebase memory

<!-- research record; factual notes from the initial review -->

This file preserves durable findings from ten review passes. The focused audit records linked below cover mechanics corrections, end-to-end driver closure, and the standalone SM83 processor boundary. Detailed explanations and coverage tables live in the linked documents.

## Repositories reviewed

### `pret/pokered`

- Remote: `https://github.com/pret/pokered/`
- Local root: this repository
- Branch: `master`
- Reviewed commit: `405b6246372d7e5a2cb029cbb65219b13286b8c9`
- Purpose: disassembly that builds byte-identical Pokémon Red/Blue ROMs
- Pinned RGBDS version: `1.0.2`
- Canonical Red SHA-1: `ea9bcae617fdf159b045185467ae58b2e4a48b9a`
- Canonical Blue SHA-1: `d7037c83e1ae5b39bde3c30787637ba1d4c48ce2`
- No obvious root `LICENSE*` or `COPYING*` file was found.

### `pret/pokered.wiki`

- Remote: `https://github.com/pret/pokered.wiki.git`
- Local sibling: `../pokered.wiki`
- Reviewed commit: `38739b79b2bd0e7f00bd434f252a6d48f649b4a0`
- Purpose: modification tutorials and project guidance
- Important limitation: most battle pages describe patches to base behavior. They are evidence and navigation aids, not the source of truth.

### `vicgalle/gameboy-pokered-verify`

- Remote: `https://github.com/vicgalle/gameboy-pokered-verify`
- Local sibling: `../gameboy-pokered-verify`
- Reviewed commit: `aa9b95b87b82210464a24e849026722c425c7be2`
- Purpose: Lean 4 SM83 helpers and isolated Pokémon Red bug proofs
- No obvious root license file was found.
- It is useful prior art but does not execute the assembled ROM or prove a battle transition equivalent.

### `gbdev/gb-opcodes`

- Remote: `https://github.com/gbdev/gb-opcodes.git`
- Local sibling: `../gb-opcodes`
- Reviewed commit: `376f61c86fdac2048f7ce5fe838ae756b306017e`
- License: CC0 1.0 Universal
- Purpose: 256 base + 256 CB opcode catalogue with display metadata
- Important limitations: no schema/generator/tests/README at this commit; incomplete descriptions; ambiguous display-oriented `immediate`; F8 SP `increment` hack; disputed STOP and additive PREFIX rows.
- Complete audit: [Ninth-pass gb-opcodes audit](ninth-pass-gb-opcodes-audit.md) and [SM83 implementation specification](../reference/sm83-implementation-spec.md).

### Processor reference/test inputs pinned across the eighth through eleventh passes

- `gbdev/pandocs`: `fe246067b695b5404a4a6a47efb4fd6d921ececb` (CC0)
- `gbdev/gb-opcodes`: `376f61c86fdac2048f7ce5fe838ae756b306017e` (CC0)
- `SingleStepTests/sm83`: `f9c30210245dd691661db39f5ace022c465ecc2f` (MIT; 244 base + 256 CB JSON files, 1000 fixtures each)
- `Gekkio/mooneye-test-suite`: `31510e12eea6286d36eea060a6adde755e1067aa` (MIT)
- `Gekkio/gb-ctr`: `d164e64678841d2e4d768850810a89d0b9964187` (CC BY-SA 4.0; reference rather than copied source)
- Game Boy CPU internals gist: `8efa6645473411e78dd917169141c16c0d306ce1` (no explicit license observed; factual citation only)
- `Gekkio/gb-research`: `59088f486f579a69fd86bd86a55181b937e769e0` (MIT or Apache-2.0 HDL; CC BY 4.0 assets)
- `LIJI32/SameBoy`: `213a12ce93d66b105a113debd9396306066a7cfc` (Expat; selected DMG-B oracle with quarantine)
- `aappleby/GBMicrotest`: `463eb6bc0fe31d61781ef63060ad6d74090c0255` (MIT; 513 source/prebuilt fixtures)
- IceBoy DMG-B bus/core pages: SHA-256 `8616eaf…` and `e070435…` (factual citation only)

These inputs validate/challenge a processor specification; they are not theorem premises or substitutes for a ROM-linked refinement proof.

Pinned local catalogue artifacts:

| File | SHA-256 |
|---|---|
| `../gb-opcodes/Opcodes.json` | `e7e3cd657d8e87b44570474eb3a6ed735501c9a00520f3d6937881203c823bc5` |
| `../gb-opcodes/OpcodeDescriptions.json` | `ac0eeea25360ea93555ba8e53d8f49f25ee4bfb7ab052466053b18abe94ec079` |
| `../gb-opcodes/collections/_optables/errata.md` | `e03a589cfe2dba5690c61fbdde4b0ea17d4948cef584c4d62f9410720a5b216c` |
| `../gb-opcodes/LICENSE` | `36ffd9dc085d529a7e60e1276d73ae5a030b020313e6c5408593a6ae2af39673` |

## Local tool state during review

The checkout was cloned successfully. The local environment did not expose `make`, RGBDS binaries, `lean`, or `lake` on `PATH`, so the canonical ROM and the related Lean project were not rebuilt during these documentation passes. Nix is available; current nixpkgs reports RGBDS 1.0.1 (the source requires 1.0.2) and Lean 4.30.0, while the related project pins Lean 4.28.0. M0 must lock Lean and provide a custom pinned RGBDS `v1.0.2+hotfix` derivation rather than using the mismatched package.

The available document-search index did not include this new checkout. Findings were grounded by direct repository reads, source searches, the wiki clone, and the related Lean repository. During the eleventh pass, Nix shells successfully built SameBoy's tester and ran the sole exposed `gb-research` VUnit decoder test; neither smoke check is treated as hardware conformance.

## Repository shape

Top-level build aggregators:

- `includes.asm` loads constants and macros globally.
- `home.asm` assembles fixed-bank routines, including `home/random.asm`, `home/math.asm`, `home/move_mon.asm`, and `home/pokemon.asm`.
- `main.asm` distributes engine/data code across switchable banks.
- `ram.asm`/`ram/wram.asm`/`ram/hram.asm` define concrete state.
- `layout.link` controls placement.
- `Makefile` emits `.gbc`, `.sym`, and `.map` files and checks canonical hashes.

`main.asm` contains sections named `Battle Engine 1` through `Battle Engine 11` plus `Battle Core`. Battle code is intentionally spread among banks; file adjacency does not imply one address range.

Initial inventory:

- 49 `.asm` files under `engine/battle` and `data/battle`;
- `engine/battle/core.asm`: 6,913 lines;
- `engine/battle/effects.asm`: 1,501 lines;
- `engine/battle/trainer_ai.asm`: 742 lines;
- 165 move records;
- 151 base-stat files;
- 744 lines of trainer party data;
- 54 direct `Random`/`BattleRandom` call sites in the reviewed battle and adjacent source set.

## Key file hashes at the reviewed commit

These hashes are investigation aids. M0 should generate a complete manifest.

| File | SHA-256 |
|---|---|
| `engine/battle/core.asm` | `928a66d1ac444fc913c7c658d9f7739eb6351e797b3276da64a5de9682a57a5f` |
| `engine/battle/effects.asm` | `6e7650408de33069aae9521473f62a1078697f7b539a3978daa49a0e6df825d3` |
| `engine/battle/common_text.asm` | `3b77739b798d4203b98ea26a565657a44d28363069892a268fb635aad148bde3` |
| `engine/battle/experience.asm` | `a78649d30822cf9735a1669f29c82115099d450810796a6716b30a9a699259af` |
| `data/battle/stat_modifiers.asm` | `04a58805090f240c9b107b49706dceeb9dc33dcf1e9c56e27d6dc88d6991c286` |
| `engine/battle/trainer_ai.asm` | `12f090abd33e3f227cdc4f24d165ad35b6abaf694ea3f5f1a526f9d7505e140d` |
| `data/trainers/move_choices.asm` | `373e15f037f161dd4d8cd04f6cce2df539caacf5bb01092339ec2cf032ae863f` |
| `data/trainers/ai_pointers.asm` | `92544c1465c87ae8e59adc40171c583815c795d0d513dda8d66b6ace9a3b8fa3` |
| `engine/battle/init_battle_variables.asm` | `c6c762c6bb712ce5bc0365830060e9d33694d1e394060a6ea80a51388bd8539f` |
| `engine/battle/end_of_battle.asm` | `ee5a197237db928ddc983366beebbd54f7e1d986f10f9fc553fbed371cba11cb` |
| `engine/battle/move_effects/drain_hp.asm` | `b4a3fa194f0260b2f4ffb271fd0ad455b5b122eae23e69841691b52e2d5b5498` |
| `engine/battle/move_effects/heal.asm` | `dc3f6c255c657d43904e427c6ef9e8c10176641d451a26896e9cf4d66f97e87b` |
| `engine/pokemon/add_mon.asm` | `4a0c02fbbfdd6dc1e9357069be2b4b94342777de94efb2a67bd4e25ca62bddfe` |
| `engine/pokemon/learn_move.asm` | `f4e7973a87e6c0e74a2ce819eb6096121aca5ce7de7d4c040e8a5049cd31d8b6` |
| `data/pokemon/evos_moves.asm` | `1a4c475c47134440a4a4e54265314638d8c6953da558d7d6a7b7f7bc206c2f30` |
| `engine/menus/naming_screen.asm` | `e235a1c56a5d7c73f110c79ebd8cc794b04f41dd6389bb2e24aa297443a29bca` |
| `macros/data.asm` | `2b5b9e8c9f1e7b5ca7ceaf9c8e63fd5a53edc02c76695fb8ae1bf4fa55ca0582` |
| `engine/items/item_effects.asm` | `76b570b5216bbbcf6d9528c4704d931744a3740cce88afdc4f4f8f700449dda1` |
| `data/moves/moves.asm` | `a2cf3e1ec6bf4b5caaeeec974967691c9eb47923d1e7432fb0267ba7d3a5931f` |
| `data/types/type_matchups.asm` | `f7f2286029d4fe64c80ed6cc5f5c75ec1f1b8903a9eabd171deab49e23228d39` |
| `home/overworld.asm` | `2d84db7376753b9d98b1d1546c29bc050b3fe4f2b580b8aa7f6699ffef415b69` |
| `home/trainers.asm` | `5bf4068dd99a370f0aff48e7030e2b1ab48ef6538746572c8e868e8c64d11b27` |
| `home/trainers2.asm` | `034131a486fd7750052dbfae7061325ce196ec0fe992cd55089a71481516746a` |
| `engine/battle/save_trainer_name.asm` | `fe583504e507f5ac3d2310085ae622cc688370412ad8197a5454e704f1873b2b` |
| `engine/overworld/auto_movement.asm` | `51132df663914861ac176733a764788e1db1d96f27d830952279338cc7633379` |
| `engine/link/cable_club.asm` | `2d2148185a0548d9e3b2f994afc55d47a47739cdb5e7e49427ae625beac4e5af` |
| `engine/events/heal_party.asm` | `f7641cc9708f9da5b8ae4e678a63f61ebb9b51bcf7abaea4a594c4cf2276cd35` |
| `data/predef_pointers.asm` | `73595c2ee1de5dfbe8be838a8680b3a42762cd3f38906b67c8449606cc059dee` |
| `home/predef.asm` | `f18bca5a3c64e16d5ffb60582d8b52f24cfacd2f4426418265a0a3ad8280ad2d` |
| `audio/play_battle_music.asm` | `eb17f5d24409f8b9c719b66caf6d763fb2d30e986446036910d0c107c3765eb9` |
| `main.asm` | `4f9a67697d0fb175610aefccffee3866ccd9728aff70647070c6f219c2b2bef9` |
| `scripts/ViridianCity.asm` | `7cf10cb0a38cdb340f09f5637710cb405753a250a7bbe044ef6b66f9f8865142` |
| `ram/wram.asm` | `00683cd430a9ef30794d2aeaee51f3a5440e4bb14dca13e9f9cb5fa88f130e34` |

## Constants and data facts

- Maximum level is 100.
- Each Pokémon has four move slots.
- Each party has up to six members.
- There are 165 move IDs; Struggle is `$A5` and must remain the last ordinary move for Metronome's range logic.
- Move records contain animation, effect, power, type, accuracy, and PP.
- The `percent` macro scales by `$FF / 100`; all 165 move accuracies are floored into ROM bytes, while call-site `+1`/`-1` and branch polarity produce the exact counts in [Probability thresholds](../reference/probability-thresholds.md).
- Effect IDs run through `$56`, with several unused slots.
- The 13 stat-stage rows use exact stored decimal-style ratios such as `28/100`, `33/100`, and `66/100`, not recomputed symbolic fractions.
- Internal species IDs are not Pokédex order and contain gaps used by MissingNo. behavior.
- Opponent IDs 200 and above denote trainers (`OPP_ID_OFFSET = 200`).
- The type index boundary `SPECIAL = $14` determines physical versus special damage.
- Generation I has one Special stat.
- The type table stores only non-neutral interactions and is scanned in order. Distinct matching defender-type triples apply sequentially; a duplicated type does not apply one table row twice.
- Stat stages are stored as values 1–13; 7 is neutral.
- Stage ratios are integer numerator/denominator approximations, not exact fractions.
- Calculated stats are normally capped at 999, but Reflect/Light Screen doubling bypasses that cap before damage scaling.
- Trainer DVs are fixed at `$98/$88`; wild DVs are two battle-random bytes.
- Party data uses 44-byte member records; active battle data uses 29-byte records.
- Persistent, active, and volatile state are stored separately and synchronized at selected routines.
- PP bytes use high two bits for PP Up count and low six bits for current PP.

## Battle control-flow memory

Primary sequence:

```text
InitBattle
  → trainer ReadTrainer or wild LoadEnemyMonData
  → DoBattleTransitionAndInitBattleVariables
  → StartBattle
  → MainInBattleLoop
      → player action selection if allowed
      → SelectEnemyMove
      → resolve Quick Attack / Counter / Speed / tie
      → actor move or trainer AI action
      → actor poison/burn/Leech Seed
      → other actor move or trainer AI action
      → other actor poison/burn/Leech Seed
      → faint/replacement/termination
  → EndOfBattle
      → trainer/Pay Day payout as applicable
      → EvolutionAfterBattle on the source-selected end path
      → battle-state cleanup and overworld handoff bytes
```

`InitBattleVariables` is only a partial reset: it clears `wMiscBattleData`, while canonical calls rely on earlier `EndOfBattle`/new-game state for other battle-status bytes and on caller/prior state for normal or Old Man `wBattleType`. A standalone reset harness must establish a named sanitized byte image.

`StartBattle` performs an unbounded first-living-enemy-party scan before mode dispatch, including wild, Safari, and Old Man paths; reset preconditions must cover that memory even when an active wild opponent is already loaded.

For supplied battles, the common concrete driver entry is `InitOpponent` with nonzero explicit opponent and a valid bank/stack frame. `InitBattle` additionally performs encounter detection and can return without battle when `wCurOpponent == 0`; that prefix needs a separate encounter/no-battle theorem. The first semantic checkpoint can follow mode loading, but the driver theorem includes initialization and transition execution.

A `StartBattle` terminal edge enters an `ending` phase rather than completing the RL episode. Pay Day, evolution/move-learning requests, cleanup, restored letter/map/tile fields, bank/stack return, and carry remain. Simultaneous active faint can be nonterminal when reserves exist and is provenance, not a terminal cause by itself.

Post-return callers are separate: overworld loss later halves money/heals/warps, trainer scripts set fought/object state, and the cable club calls `HealParty` immediately after `InitOpponent` returns. See [End-to-end closure](../reference/end-to-end-closure.md).

Important labels are catalogued in [Battle source map](../reference/battle-source-map.md).

### Action-selection and order findings

- Fight selection resets the run-attempt counter, even when the move menu is later canceled.
- Highlighting a non-disabled move reloads selected-move/power/type scratch; disabled highlights do not. Canceling leaves the highlighted slot in `wPlayerMoveListIndex`, so stale move, record, and slot state survive into later action handling.
- Moves and bag entries can be reordered during battle without consuming a turn.
- Quick Attack is special-cased.
- Counter is special-cased to move after ordinary moves.
- There is no generic priority table.
- Equal Speed consumes `BattleRandom`.
- Link internal/external clock role inverts the tie result.
- Trainer action AI runs when the enemy is about to act and may replace the move with an item or switch.

### Residual finding

Poison, burn, and Leech Seed are processed after each acting side, not once at a generic round end. Toxic increments a side's Toxic counter inside the shared HP-decrease helper. Leech Seed uses the same helper, so Toxic's counter scales Leech Seed damage. There is no intermediate faint check: poison/burn may set HP to zero, after which Leech Seed still subtracts, can increment Toxic again, and heals the opponent by nominal computed damage even when overkill was capped.

### Active/party duplication

`LoadBattleMonFromParty` and `LoadEnemyMonFromParty` copy party values into active structures. `ReadPlayerMonCurHPAndStatus` copies player HP/status back. Enemy switching has its own copy. Level-up, items, Transform, fainting, and capture each have special synchronization paths. Any typed model must use phase-specific invariants.

### Switch, faint, and participation findings

Player send-out clears all three volatile flag bytes, Disable state, the move-list index, and loaded move number, but leaves counters/shared `wDamage` stale and retains `wPlayerSelectedMove` plus adjacent loaded effect/power/type/accuracy/PP scratch. That outgoing scratch can still affect same-turn order and enemy Counter after the incoming member is already active; it can place the incoming member's poison/burn residual before the enemy action and KO it first. Only the six meaningful stat stages are reset; the two padding bytes remain stale.

Non-link `EnemySendOut` deterministically picks the lowest-index living slot other than the outgoing member, with no destination RNG and no explicit scan bound. It resets participation for the new enemy. A Shift switch clears those just-created flags again so the incoming player member is the sole participant. Forced enemy replacement clears layer-2 encouragement; voluntary AI switch retains it.

Player faint clears active/party nonvolatile status and the gain-EXP bit but preserves the fought-current-enemy bit. Revive/Max Revive uses that preserved bit to restore gain eligibility before the same enemy faints. Enemy faint instead retains enemy-party status while clearing its active volatile block. EXP All counts fainted in-party gain bits in the divisor but `GainExperience` skips their awards.

The wild-faint “No” response passes stored `wPartyMon1Speed` to `TryRunningFromBattle` regardless of which member fainted, ignoring active paralysis/stage/badge Speed. `RetreatMon` also selects variable recall text from wrapped enemy-HP arithmetic; healing can underflow the class, the quotient is truncated to its low byte, and a raw zero divisor makes `_Divide` diverge. See [Switch, faint, and participation flow](../reference/switch-faint-and-participation.md).

## Move execution memory

The move effect byte is interpreted at multiple phases, using:

- `ResidualEffects1`;
- `SpecialEffectsCont`;
- `SetDamageEffects`;
- `ResidualEffects2`;
- `AlwaysHappenSideEffects`;
- `SpecialEffects`;
- `MoveEffectPointerTable`.

Consequences:

- some effects execute before and skip ordinary damage/accuracy;
- trapping and Thrash effects initialize state before damage;
- fixed-damage effects skip normal damage calculation;
- multi-hit attacks choose count before accuracy and reuse first-hit damage/accuracy;
- trapping chooses its continuation count and clears target recharge before its first hit test;
- Explosion's self-KO effect still runs on a miss;
- some side effects are skipped when the target faints;
- Mirror Move and Metronome reload a new move record and re-enter execution;
- Mimic changes active moves;
- non-link enemy PP is not decremented;
- ordinary player Mimic asks the player which target move to copy, while enemy/link Mimic uses `BattleRandom`;
- player execution includes a separate traded-Pokémon disobedience state machine before ordinary move execution; replacement moves retain the originally selected PP slot.
- Bide repeatedly accumulates shared `wDamage`, including stale/Substitute values.
- transformed player Mirror Move/Metronome PP compensation can increment original party PP without a matching party decrement;
- directly selected charge/Fly first turns precede PP decrement; charge is not bound to a move, so nested/disobedient generation reloads the retained selected slot on continuation, with different PP timing; an interrupted attack turn can leave Fly/Dig invulnerability after charging clears;
- drain effects halve `wDamage` in place with minimum one, changing later Counter/Bide input;
- Conversion skips ordinary hit/Substitute checks, copies active target types, and fails on target invulnerability;
- Explosion/Selfdestruct clear user HP/status and seeded state before later miss handling.

## Damage memory

`CalculateDamage` performs staged integer arithmetic:

```text
floor(floor(floor((2 × level) / 5 + 2)
                  × power × attack / defense)
            / 50)
+ 2
```

That summary is only explanatory. The actual implementation uses four-byte scratch multiplication/division, intermediate caps, and byte scaling. Proofs must follow the exact routine.

Order after neutral damage:

1. cap neutral damage at 999;
2. add STAB as `damage + floor(damage/2)`;
3. apply type triples sequentially;
4. rotate each `BattleRandom` byte right once, reject rotated values below 217, and divide the accepted 217–255 multiplication by 255;
5. subtract from HP and replace `wDamage` with actual non-overkill HP loss.

Critical hits replace current modified stats with unmodified calculated party/enemy stats and double level. Reflect/Light Screen are bypassed by the critical base-stat path. If either attack or defense needs more than one byte, both are divided by four and then low-byte values are used. Defense can become zero, making `_Divide` fail to terminate.

## Status memory

Status-gate order is semantically important:

1. sleep;
2. freeze;
3. opponent trapping;
4. flinch;
5. recharge;
6. Disable expiration;
7. confusion;
8. selected move disabled;
9. paralysis;
10. Bide;
11. Thrash/Petal Dance;
12. trapping continuation;
13. Rage;
14. ordinary move.

Sleep counter zero wakes the Pokémon but still consumes its turn. Freeze has no ordinary thaw chance. Confusion is checked before paralysis. Self-confusion and full paralysis clear several multi-turn states. On a Fly/Dig attack turn they clear charging without clearing invulnerability. Rest writes sleep 2 but leaves `BADLY_POISONED` and the Toxic counter intact; seeded residuals can still observe that stale Toxic state while the member sleeps.

Stat updates have a side-dependent cross-stat matrix: outside link, player stat-up and enemy-on-player stat-down reapply every player badge boost, while the common burn/paralysis helpers target the opponent for self stat-ups and the target for stat-downs. Two-stage effects at exact current stat 999/1 can print failure but retain one stage. Outside link, enemy damaging stat-down side effects pass an extra `>= 64` draw before their independent `< 85` draw. See [Stat modifier flow](../reference/stat-modifier-flow.md).

## RNG memory

### Ordinary generator

`Random_`:

- reads `rDIV` twice;
- adds first divider byte to `hRandomAdd` using incoming carry;
- subtracts second divider byte from `hRandomSub` using carry produced by the addition;
- returns `hRandomAdd` through `Random`;
- is invoked once by every VBlank.

Therefore battle randomness depends on CPU flags, instruction timing, interrupts, animation/text/menu delays, and controller timing. A software seed alone cannot reproduce console traces.

### Link generator

Cable setup generates ten bytes under `$FD`, but the external-clock copy scans past leading zeroes as well as preamble/no-data bytes. Legitimate leading zero seeds can therefore make the two post-setup blocks differ. Standard `BattleRandom` cycles the first nine bytes of each cartridge's own block; after returning the ninth value, it maps those nine seeds to `5 × seed + 1 mod 256` and resets that cartridge's index.

Exact draw consumption matters because many mechanics reject values. Player Psywave rejects zero while enemy Psywave accepts it, causing per-cartridge RNG cursor desynchronization. Full link semantics must retain both perspectives rather than one permanently shared state. At link exit, each local player party is authoritative; `EndOfBattle` copies only active enemy status, not HP, into that cartridge's disposable mirrored party.

See [RNG and time](../explanation/rng-and-time.md).

## Trainer AI memory

There are two layers.

### Move scoring

`AIEnemyTrainerChooseMoves` initializes four scores to 10, discourages the disabled slot, applies class-selected modifications, decrements until a minimum is found, and keeps only minimum-score moves. Final sampling's initial slot buckets contain 63/64/63/66 bytes, followed by blank/disabled retries; they are not equal quarters. Layer scans stop at the first zero move, and a malformed leading-zero list can make the minimum loop diverge for a class with scoring layers.

Scoring modifications:

1. discourage redundant zero-power status moves;
2. encourage selected stat/effect ranges when `wAILayer2Encouragement == 1`;
3. encourage type-effective moves and discourage weaker damaging options.

`AIGetTypeEffectiveness` initializes neutral effectiveness to hexadecimal `$10` rather than decimal `EFFECTIVE = 10`, which affects scoring. Layer 2 is enabled only when `wAILayer2Encouragement == 1`; execution increments the byte, forced replacement clears it, and voluntary AI switch retains it.

### Action AI

`TrainerAI` uses direct `Random` and a per-Pokémon successful-action count. Generic/no-op paths never decrement it and therefore continue drawing each action. Class routines can heal, cure, boost, Guard Spec, or switch; a successful switch deterministically sends the lowest-index other living member without another draw. Known source behavior includes Blaine using Super Potion without an HP threshold once his random branch is selected and Cooltrainer F's intended random early return being commented out. All 47 layer/count/pointer rows and action thresholds are in [Trainer AI dispatch](../reference/trainer-ai-dispatch.md).

Trainer victory can execute caller-provided end text before payout. `PrintEndBattleText` clears its flag, banks through a dynamic text pointer, saves trainer name, may set sprite movement bytes, and selects win/lose text from raw `wBattleResult`. A simultaneous-faint victory retaining result 1 can therefore print lose text and still pay prize money.

## Items and capture memory

`UseItem_` sets the action result to success before dispatch and individual routines may clear it. Battle menu code uses that byte to decide whether the turn was consumed.

Battle-relevant branches include:

- all 83 ordinary dispatch entries, including explicit rejects and raw-only Pokédex/Surfboard/badge-alias paths;
- medicines and revives, with Revive restoring gain-EXP eligibility only from preserved fought-current-enemy participation;
- status cures;
- X items, Guard Spec, Dire Hit;
- Poke Flute and Poke Doll;
- PP restoration where base code permits it, while PP Up, vitamins, Rare Candy, stones, and TM/HM use reject during battle;
- balls and capture;
- Safari bait and rock.

A successful active status cure copies party max HP and all four combat stats into active state without reapplying stat stages, badges, burn, or paralysis; AI cures instead leave already-penalized active stats unchanged. Full Restore's damaged-HP path differs again and leaves `BADLY_POISONED` set.

Capture uses direct `Random`, not `BattleRandom`. It includes ball-specific rejection sampling, status subtraction, HP/catch formulas, a second random test, shake-count calculation, transformed-target handling, naming input, and party/storage mutation. Any target with the Transform flag is forced to Ditto on capture, including a non-Ditto that obtained Transform through Mirror Move. Party capture appends; `SendNewMonToBox` inserts into current-box slot 1. `AskName` occurs after the Pokédex write and party count/species/OT or box species/name-array mutation but before party/box record construction and ordinary bag-ball removal; Safari count was already decremented. Request checkpoints therefore observe partial storage and resource state.

Old Man menu automation copies `wPlayerName` into `wLinkEnemyTrainerName`/`wGrassRate`, writes `OLD MAN` as the player name, and the forced ball path copies the aliased buffer back. The player name is restored but the wild-encounter bytes remain overwritten.

Safari escape also uses direct `Random`. Bait and rock alter catch rate and escape factors for random durations. Bait expiration does not restore catch rate; only expiration of the rock/escape factor reloads the species catch rate. A carry from doubling the enemy Speed low byte causes immediate escape before bait/rock adjustment.

Battle initialization marks loaded enemy species as seen. Successful capture sets seen/owned flags and either adds exact party data or mutates the current box. Trainer victory mutates BCD money, and ordinary trainer-ball rejection consumes both ball and action.

## Experience memory

`GainExperience` is skipped in link battles. For participants it:

- divides enemy base data by recipient count;
- adds stat experience with saturation;
- computes base experience from yield and enemy level divided by 7;
- boosts traded and trainer-battle experience by 1.5 each;
- caps experience at the level-100 threshold;
- recalculates level/stats and current HP;
- updates an active recipient;
- can invoke move learning;
- flags later evolution.

With EXP All, the first award can divide the already-halved source bytes in place by participant count; the all-party award then divides those mutated bytes again. The divisor counts all eight gain-flag bits even though recipient iteration uses party count and skips fainted members, so fainted in-party bits reduce living shares without receiving an award.

`LearnMoveFromLevelUp` considers only the first learnset row at the exact resulting level. Full movesets enter a nested learn/forget/HM-rejection/abandon-confirmation loop. If an active transformed member learns, the party's full move/PP arrays are copied back into active state without clearing the Transform flag.

`EndOfBattle` calls `EvolutionAfterBattle` on its source-selected path (`wBattleResult == 0` for non-link battles; direct fallthrough for link) before `InitBattle` returns and before clearing `wIsInBattle`. Poke Doll and move escape normally retain raw result zero and therefore reach this path; Run/capture write 2 and do not. A complete episode therefore includes eligible evolution/cancel behavior, evolved species/stat/type/move/Pokédex mutation, and the source-annotated wild-battle item-evolution bug. Only the rendering portion is presentation-only.

Final WRAM cannot uniquely identify the terminal cause. `EndOfBattle` clears `wEscapedFromBattle`, battle type, and opponent state, while result zero is shared by victory and several escape/exhaustion paths. The low runner must preserve a pre-cleanup terminal control-flow witness and compose a separate epilogue theorem. See [Battle outcomes](../reference/battle-outcomes.md).

## Wiki findings

### `Add-a-new-move.md`

- Confirms the move data tables must remain in ID order.
- Notes Struggle must remain last because Metronome assumes that range.
- Identifies move name, data, animation, sound, base move, and learnset tables.

### `Adding-a-New-Pokemon.md`

- Explains internal index versus Pokédex ID.
- Notes trainer IDs occupy 200 and above.
- Documents base stats, types, catch rate, base EXP, base moves, growth rate, and TM/HM bits.
- Highlights Mew's special ROM placement.

### `Add-a-new-type.md`

- Confirms type index below/above `$14` selects physical/special.
- Describes the ordered matchup triples.

### `Enemy-Pokémon-Use-PP.md`

- Confirms base enemy Pokémon have PP fields but do not decrement/check them normally.
- Shows that adding enemy PP touches move execution, party reload, Struggle selection, AI scoring, Disable, capture, and special trainer moves. This demonstrates battle subsystem coupling.

### `Attack-after-waking-up-from-sleep.md`

- Confirms stock Red/Blue skip move selection while asleep and consume the wake-up turn.
- Shows both player and enemy selection/execution paths need coordinated changes.

### `Check-base-power-before-skipping-damage-calculation.md`

- Explains why `ResidualEffects2` prevents a damaging move with a guaranteed stat effect from behaving like later-generation moves.
- Exposes several effect-order and duplicate-accuracy/animation interactions.

### `Remove-25%-chance-for-enemy-stat-down-moves-to-miss.md`

- Confirms an extra direct battle roll exists for enemy stat-down moves outside links.

### `Swift-will-not-hit-through-fly-or-dig.md`

- Confirms stock Swift returns before the invulnerability check.
- Also points to the broken drain-on-Substitute test caused by `CheckTargetSubstitute` overwriting `a`.

## Related Lean project findings

All nine `SM83/*.lean` files were read completely:

- `SM83/State.lean`: registers, `SP`, `PC`, arbitrary-byte F, total memory function, halt flag.
- `SM83/Arithmetic.lean`, `Logic.lean`, `Load.lean`, `Control.lean`: direct operation helpers, not fetched opcodes.
- `SM83/Memory.lean`: region constants, functional writes, final-state stack helpers.
- `SM83/Properties.lean`: selected algebraic theorems.
- `PokeredBugs/Proofs/*`: isolated models and theorems.
- Lean toolchain listed as 4.28.0.

Important limitations for this project:

- no machine-code fetch/base-CB decode/step loop, length/PC proof, or invalid-opcode classification;
- no complete instruction set: DAA, RETI, signed-SP forms, STOP/lockup, and full operand dispatch are absent;
- no interrupt/cycle/timer/banking model; `di`/`ei` are no-ops and HALT only sets a Boolean;
- pure memory cannot express time-dependent/side-effecting MMIO or bus order;
- stack helpers prove only final flat-memory layout, not high-byte/low-byte cycle order;
- raw F can contain impossible low bits outside normalizing helpers;
- `#eval` expected-output demonstrations do not fail the build if they print false;
- bug routines are mostly manually modeled;
- no active/party state projection, battle state machine, or step/episode refinement theorem.

The processor should therefore be a separate, commit-pinned `sm83-lean` package with complete byte decode, independent declarative/de-overlapped/physical fetched-IR semantics, IDU/address/clock intent, interrupts/HALT/STOP/lockup, flat-bus conformance, and no Pokémon imports. The Pokémon verifier supplies and proves the T1F–T4R Game Boy MBC/MMIO/device/clock/OAM adapter. See [Standalone SM83 semantics package](../reference/sm83-semantics-package.md), [SM83 implementation specification](../reference/sm83-implementation-spec.md), [SM83 microarchitecture contract](../reference/sm83-microarchitecture-contract.md), [DMG-CPU B profile](../reference/dmg-cpu-b-profile.md), and the [eleventh-pass audit](eleventh-pass-sm83-profile-evidence-audit.md).

## Tenth-pass processor closure findings

- Physical SM83 execution is a fetched-IR pipeline: successor fetch overlaps current writeback, so programmer/SingleStep instruction slices are a derived projection.
- A mid-program theorem checkpoint needs IR address/byte, next PC, prefix state, and hidden-latch well-formedness; PC alone is insufficient.
- The pinned GB CTR map has 105 categories: 101 detailed normal-family microtimings plus CB-prefix, HALT, STOP, and undefined control.
- Idle read/write control does not imply irrelevant pins. IDU address drive is required for monochrome OAM corruption.
- HALT/STOP gate typed clock domains; they cannot be represented as repeated ordinary idle M-cycles.
- Interrupt entry corrects the ahead PC after a discarded prefetch, then performs stack/vector work over five M-cycles.
- Mooneye `ie_push` fixes cancellation IF behavior, retargeting, and the initial-SP `$0000` versus `$0001` distinction.
- Pan Docs exposes seven STOP outcomes; the unstable IME-enabled speed-switch/pending case remains an explicit relation unless a profile resolves it.
- SingleStep has 16 bus-signal shapes and validates de-overlapped active transactions, not idle pins, physical commit phase, IE/IME, HALT, or STOP.
- Mooneye's DAA source has 4096 A/ZNHC rows; the equation audit passes all rows. Lean additionally proves old-Z irrelevance and the 2048 relevant A/N/H/C cases.
- Invalid bytes already in IR reach no generic fetch state; lockup pin behavior remains profile-qualified.

Useful verified examples and regression ideas include:

- Focus Energy shift behavior;
- threshold equality in accuracy/critical checks;
- Psywave link RNG desync;
- Bide accumulator clear asymmetry;
- stat scaling and zero defense;
- Reflect/Light Screen overflow;
- badge stacking plus Reflect;
- accuracy/evasion integer non-cancellation;
- Substitute zero-HP behavior;
- heal comparison overflow cases;
- Blaine and Cooltrainer F AI behavior.

## Eleventh-pass profile closure findings

- The first theorem target is `DmgCpuBCommonBoot`; DMG-CPU C was dropped because the detailed mutually reinforcing evidence is CPU B.
- One four-T-cycle M-cycle expands into eight measured half edges, `T1F` through `T4R`.
- Dynamic internal-bus reads can fold low bits over a sample window; a single sampled byte is only the stable-read reduction.
- External write assertion/data and internal register commit occupy distinct windows, so MMIO collision timing is register-specific.
- Power reset and synchronous reset differ. PC and IE reset; ordinary registers and IR do not.
- The core NMI pad is unbonded in the console, and IRQ inputs 5–7 are inactive.
- HALT gates CPU phases while the system clock path remains; STOP also gates the oscillator/system path.
- The canonical common DMG boot ROM is an external hash-identified input, not vendored bytes or a folklore register table.
- SameBoy is pinned as the independent DMG-B oracle, but STOP, TODO-marked IF timing, lock pins, uncertain OAM, and analog claims are quarantined.
- Advanced OAM corruption is revision/instance-specific; deterministic claims name a measured fixture, otherwise the adapter uses a reviewed family relation.
- Exact locked retained pins and advanced OAM fixture classes await hashed hardware captures, but canonical Red proves invalid decode unreachable and projection independence where required.
- Capture bundles have a checked JSON schema and validator enforcing DMG-B identity, complete channels, artifact hashes, independent analyses, and repetition minima.

## Source-annotated mechanics hazards

The initial source scan found these comments or branches worth preserving:

- missing Mirror Move check around a link switch/trapping path may desync;
- Toxic ticks apply through the shared Leech Seed helper, with no faint check between poison and Seed and nominal overkill healing;
- enemy-faint Bide clear writes one byte only;
- wild victory sound can occur before simultaneous-faint resolution;
- Counter depends on shared/stale move and damage fields;
- Jump Kick miss recoil uses zeroed `wDamage` and becomes one;
- self-confusion/Jump Kick recoil can target the other side's Substitute through turn flipping;
- Focus Energy shifts the wrong direction;
- player and enemy Psywave ranges differ;
- AI effectiveness uses `$10` neutral;
- “100%” accuracy is 255/256 because comparison is strict;
- Transform's Fly/Dig check uses overloaded or wrong status data;
- Substitute allows current HP equal to cost, and `AttackSubstitute` leaves a substitute up at zero HP when damage equals remaining substitute HP;
- transformed capture assumes Ditto, even for a non-Ditto that copied Transform;
- capture invokes naming mid-mutation before return, and box storage inserts at slot 1 by shifting parallel arrays in separate pre-/post-name phases;
- drain halves shared `wDamage` before later Counter/Bide use;
- Rest leaves Toxic flag/counter state intact;
- enemy move-slot random buckets are 63/64/63/66, not equal quarters;
- `percent` expressions have source-specific off-by-one boundaries and comparison polarities;
- hit chance floors twice with a minimum of one, so raw accuracy zero can hit while 255 can still miss;
- two-stage stat effects at exact current stat 999/1 can silently leave one stage after failure;
- self stat-up and unrelated stat-down paths can stack opponent burn/paralysis penalties;
- interrupted directly selected Fly/Dig attack turns can clear charging without clearing invulnerability or spending PP;
- Mirror Move/Metronome/disobedience-generated charge can continue as a different retained selected record;
- move-scoring can diverge on a malformed leading-zero move list;
- enemy replacement/AI switch scans deterministically for the lowest-index other living slot without a count bound;
- player send-out clears the selected-slot index and move number but retains selected move and loaded record scratch;
- player faint clears party status but preserves fought participation so Revive can restore gain-EXP eligibility;
- EXP All counts fainted party members in its divisor and then skips their awards;
- the wild-faint run response uses party slot 1 Speed regardless of the fainted active;
- recall-message arithmetic wraps after enemy healing, truncates the quotient, and can divide by zero in raw state;
- PP restore code has an upper-bit masking bug noted in item code;
- `SleepEffect` clears target recharge before accuracy and existing-status checks;
- only the player-attacker freeze side-effect branch clears target Hyper Beam recharge;
- a trainer-ball rejection removes the ball and consumes the action, while party count exactly 6 plus box count exactly 20 does neither;
- capture capacity checks use equality: raw party counts 7–254 can succeed without storage/naming, while oversized/wrapped box counts can shift beyond legal arrays;
- Poke Flute can consume a turn even when it reports no effect;
- post-battle evolution is inside `EndOfBattle`, including the wild item-evolution bug;
- animations contain presentation bugs, which are out of mechanics scope unless they alter timing/state;
- cable setup can shift the external-clock random list when a legitimate leading seed is zero;
- `EndOfBattle` writes encounter cooldown/destination handoff state, and most loss paths clear the always-on-bike flag before the later blackout routine;
- cleanup erases fields needed to distinguish several result-zero terminal causes;
- simultaneous faint write order can combine trainer lose text and payout with raw result 1, and simultaneous active faint can be nonterminal with reserves;
- move learning can loop through HM rejection and abandonment confirmation, and transformed active learning restores party moves/PP without clearing Transform;
- terminal witness precedes Pay Day/evolution/cleanup and must not set RL `done`;
- Old Man restores the player name but intentionally leaves aliased wild-encounter data overwritten;
- link cable code heals party immediately after battle-driver return, while blackout/trainer script effects happen in other callers;
- battle transition reaches VRAM/OAM/MMIO/audio and externally banked SRAM, so WRAM-only execution is not end-to-end.

The related proof repository documents additional consequences, but only source/ROM-linked theorems in this project can close coverage.

## Architecture conclusions

1. Use the assembled ROM as the formal low-level artifact.
2. Decode ROM tables; do not hand-copy them.
3. Put complete byte decode and processor semantics in a separately licensed, immutable-revision `sm83-lean` dependency.
4. Give that package independent declarative, de-overlapped, and physical fetched-IR semantics, all base/CB entries, interrupts/EI/HALT/STOP/lockup, and complete processor gates.
5. Emit physical address/data/control, IDU, commit, interrupt-poll, and clock-gate intent for all 101 normal families and exceptional controls.
6. Derive semantic operands from the proved x/y/z decoder; use pinned gb-opcodes only for normalized metadata cross-checks and reject its ambiguous display fields.
7. Keep MBC3, mapped memory, DIV/timers, LCD/DMA/OAM corruption, joypad, serial, audio, and typed clock domains in a proved T1F–T4R `DmgCpuBCommonBoot` adapter with explicit instance parameters.
8. Use symbol-level fetched-pipeline checkpoints and proved routine summaries.
9. Make random/input/link responses explicit.
10. Relate the low hardware trace to a projected high-level semantic trace; raw suffix equality is invalid because their alphabets and VBlank random calls differ.
11. Preserve bugs, width, floor, and asymmetry.
12. Keep the instruction model out of the RL hot path.
13. Prove mechanics-visible action, switch/recall, capture-naming, and nested move-learning adapters against full ROM controller traces.
14. Use explicit `InitOpponent` driver entry and prove through `EndOfBattle` plus outer bank/stack/carry return.
15. Preserve a terminal control-flow witness through an `ending` phase; final WRAM is not a complete outcome encoding and terminal is not yet `done`.
16. Track every reachable code/data/interrupt/presentation range and indirect/predef/text edge in an address-based coverage manifest.
17. Keep battle-driver output separate from overworld, trainer-script, link auto-heal, tutorial, and encounter caller integration.
18. Make the first integration theorem a minimal complete episode, not only one turn.
19. Prove team generators against named legality predicates.
20. Resolve licensing before copying from unlicensed upstream work.

## Open questions

- Which Lean version should be locked, and what hash/source should the custom RGBDS `v1.0.2+hotfix` Nix derivation use?
- Which identified DMG-CPU B units and board/RAM parts should populate the signed hardware capture corpus for locked pins and advanced OAM instance classes?
- What root license/package name should `sm83-lean` use, and should a Game Boy SoC package be extracted later?
- Which non-CPU device paths can be delayed beyond M1 without weakening the minimal complete-episode theorem, and which need proved presentation summaries immediately?
- Which presentation routines write battle-projected scratch through WRAM unions?
- Which raw-only item UI/overworld handlers need direct execution versus a proved action-result/scratch/timing summary?
- What bounded nickname-byte/API encoding and canonical naming-screen trace should the capture request use?
- What supplied roster/resource ledger should define the strongest progression-witnessed team mode?
- How should one-use TMs and evolution histories be sampled efficiently?
- What hidden-information observation should the default RL API expose?
- What throughput target is realistic for compiled Lean after M3?
- Can the existing bug-proof code be licensed for reuse?
- Which synchronized-link quotient, if any, is worth adding as an optimization over the canonical paired-perspective state?

## Documentation map

- [Specification](../../SPEC.md)
- [Current battle engine](../explanation/current-battle-engine.md)
- [Formal verification strategy](../explanation/formal-verification-strategy.md)
- [RNG and time](../explanation/rng-and-time.md)
- [RL environment](../explanation/rl-environment.md)
- [Battle source map](../reference/battle-source-map.md)
- [Battle state model](../reference/battle-state-model.md)
- [Mechanics coverage](../reference/mechanics-coverage.md)
- [Effect dispatch](../reference/effect-dispatch.md)
- [Item dispatch](../reference/item-dispatch.md)
- [Trainer AI dispatch](../reference/trainer-ai-dispatch.md)
- [Battle outcomes](../reference/battle-outcomes.md)
- [Probability thresholds](../reference/probability-thresholds.md)
- [Stat modifier flow](../reference/stat-modifier-flow.md)
- [Switch, faint, and participation flow](../reference/switch-faint-and-participation.md)
- [End-to-end verification closure](../reference/end-to-end-closure.md)
- [Standalone SM83 semantics package](../reference/sm83-semantics-package.md)
- [SM83 implementation specification](../reference/sm83-implementation-spec.md)
- [SM83 microarchitecture and system-boundary contract](../reference/sm83-microarchitecture-contract.md)
- [DMG-CPU B console profile and evidence contract](../reference/dmg-cpu-b-profile.md)
- [Second-pass ASM audit](second-pass-asm-audit.md)
- [Third-pass ASM audit](third-pass-asm-audit.md)
- [Fourth-pass ASM audit](fourth-pass-asm-audit.md)
- [Fifth-pass ASM audit](fifth-pass-asm-audit.md)
- [Sixth-pass ASM audit](sixth-pass-asm-audit.md)
- [Seventh-pass end-to-end audit](seventh-pass-end-to-end-audit.md)
- [Eighth-pass SM83 semantics audit](eighth-pass-sm83-semantics-audit.md)
- [Ninth-pass gb-opcodes audit](ninth-pass-gb-opcodes-audit.md)
- [Tenth-pass SM83 microarchitecture audit](tenth-pass-sm83-microarchitecture-audit.md)
- [Eleventh-pass SM83 profile evidence audit](eleventh-pass-sm83-profile-evidence-audit.md)
