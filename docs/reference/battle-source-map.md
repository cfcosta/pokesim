# Battle source map

<!-- mode: reference -->

**Baseline:** `pret/pokered` commit `405b6246372d7e5a2cb029cbb65219b13286b8c9`.

This is the ASM-audited source inventory for the Lean implementation and coverage manifest. Line numbers refer to the pinned commit.

## Primary control flow

| Source | Important labels/data | Verification role |
|---|---|---|
| `pokered/engine/battle/core.asm` | `StartBattle:132`, `EnemyRan:254`, `MainInBattleLoop:280`, `HandlePoisonBurnLeechSeed:470`, `FaintEnemyPokemon:732`, `TrainerBattleVictory:915`, `RemoveFaintedPlayerMon:1003`, `EnemySendOut:1276`, `TryRunningFromBattle:1496`, `SendOutMon:1723`, `ReadPlayerMonCurHPAndStatus:1800`, `SwitchPlayerMon:2419`, `SelectEnemyMove:2915`, `ExecutePlayerMove:3073`, `CheckPlayerStatusConditions:3328`, `CheckForDisobedience:3830`, `CalculateDamage:4299`, `CriticalHitTest:4478`, `ApplyDamageToEnemyPokemon:4678`, `MoveHitTest:5228`, `ExecuteEnemyMove:5457`, `LoadEnemyMonData:5992`, `BattleRandom:6543`, `InitBattle:6642` | Main state machine, [switch/faint/participation](switch-faint-and-participation.md), damage, RNG, initialization; `$0f:$6142`–`$617b` has a bounded decoded-machine/model checkpoint theorem in `Battle.Rom.DamageApplyRoutine` |
| `pokered/engine/battle/init_battle_variables.asm` | `InitBattleVariables` | Partial reset/frame invariant; `wMiscBattleData` clearing is not a whole-battle reset |
| `pokered/engine/battle/end_of_battle.asm` | `EndOfBattle` | `ending`-phase raw-result guard, Pay Day, evolution requests, discriminator erasure, cleanup; see [Battle outcomes](battle-outcomes.md) |
| `pokered/engine/battle/decrement_pp.asm` | `DecrementPP` | Player PP and transformed-state behavior |
| `pokered/engine/battle/common_text.asm` | `RetreatMon` and text continuations | HP-derived recall-message arithmetic/timing and embedded state behavior |
| `pokered/engine/battle/used_move_text.asm` | move-use text | Presentation plus `wPlayerUsedMove`/`wEnemyUsedMove` semantics |
| `pokered/engine/battle/misc.asm` | `FormatMovesString`, `InitList`, `GetMonSpecies` | Mostly presentation; species helper remains relevant |
| `pokered/home/list_menu.asm`, `pokered/engine/menus/swap_items.asm` | `DisplayListMenuID`, `HandleItemListSwapping` | Battle-bag selection and persistent bag ordering |
| `pokered/home/pokemon.asm`, `pokered/engine/menus/party_menu.asm` | `DisplayPartyMenu`, `HandlePartyMenuInput` | Switch/item/Mimic target selection and party metadata writes |
| `pokered/engine/menus/naming_screen.asm` | `AskName` | Capture nickname input, persistent party/box nickname bytes, and timing |
| `pokered/home/overworld.asm` | `NewBattle`, post-return `.battleOccurred` | Supplied-opponent `InitBattle` prefix and separate overworld/blackout caller boundary |
| `pokered/engine/link/cable_club.asm` | `predef InitOpponent`, following `predef HealParty` | Paired post-setup entry and post-driver auto-heal boundary |
| `pokered/scripts/ViridianCity.asm` | Old Man setup/end scripts | Caller-set tutorial mode and post-return script boundary |
| `pokered/home/predef.asm`, `pokered/engine/predefs.asm`, `pokered/data/predef_pointers.asm` | `Predef`, `GetPredefPointer`, `PredefPointers` | Indirect bank/address closure for battle-called predefs |
| `pokered/home/bankswitch.asm`, `pokered/macros/farcall.asm` | `Bankswitch`, far call/jump macros | Bank/stack/flag-preserving call and outer return semantics |

## Move-effect engine

| Source | Labels | Verification role |
|---|---|---|
| `pokered/engine/battle/effects.asm` | `JumpMoveEffect`, `SleepEffect`, `PoisonEffect`, `FreezeBurnParalyzeEffect`, `StatModifierUpEffect`, `StatModifierDownEffect`, `BideEffect`, `ThrashPetalDanceEffect`, `SwitchAndTeleportEffect`, `TwoToFiveAttacksEffect`, `FlinchSideEffect`, `ChargeEffect`, `TrappingEffect`, `ConfusionEffect`, `HyperBeamEffect`, `RageEffect`, `MimicEffect`, `DisableEffect`, `CheckTargetSubstitute` | Effect dispatch and most shared handlers; see [Stat modifier flow](stat-modifier-flow.md) |
| `pokered/engine/battle/move_effects/conversion.asm` | `ConversionEffect_` | Conversion |
| `pokered/engine/battle/move_effects/drain_hp.asm` | `DrainHPEffect_` | Absorb/Mega Drain/Dream Eater healing |
| `pokered/engine/battle/move_effects/focus_energy.asm` | `FocusEnergyEffect_` | Focus Energy flag |
| `pokered/engine/battle/move_effects/haze.asm` | `HazeEffect_`, `CureVolatileStatuses`, `ResetStatMods`, `ResetStats` | Haze and resets |
| `pokered/engine/battle/move_effects/heal.asm` | `HealEffect_` | Recover, Softboiled, Rest |
| `pokered/engine/battle/move_effects/leech_seed.asm` | `LeechSeedEffect_` | Seeding and immunity |
| `pokered/engine/battle/move_effects/mist.asm` | `MistEffect_` | Mist |
| `pokered/engine/battle/move_effects/one_hit_ko.asm` | `OneHitKOEffect_` | Speed-gated OHKO result |
| `pokered/engine/battle/move_effects/paralyze.asm` | `ParalyzeEffect_` | Guaranteed paralysis moves |
| `pokered/engine/battle/move_effects/pay_day.asm` | `PayDayEffect_` | Per-use and total money |
| `pokered/engine/battle/move_effects/recoil.asm` | `RecoilEffect_` | Recoil and Struggle |
| `pokered/engine/battle/move_effects/reflect_light_screen.asm` | `ReflectLightScreenEffect_` | Screen flags |
| `pokered/engine/battle/move_effects/substitute.asm` | `SubstituteEffect_` | HP cost and Substitute state |
| `pokered/engine/battle/move_effects/transform.asm` | `TransformEffect_` | Active-data copy, DVs, PP, transformed flags |

## Effect classification data

| Source | Contents |
|---|---|
| `pokered/constants/move_effect_constants.asm` | Effect IDs `$00` through `$56`, including unused gaps |
| `pokered/data/moves/effects_pointers.asm` | Effect ID to handler pointer table |
| `pokered/data/battle/residual_effects_1.asm` | Effects that execute before and skip the normal damage/hit path |
| `pokered/data/battle/special_effects.asm` | `SpecialEffects` and interior `SpecialEffectsCont` groups |
| `pokered/data/battle/set_damage_effects.asm` | Fixed/special damage effects that skip normal damage calculation |
| `pokered/data/battle/residual_effects_2.asm` | Stat, sleep, and Bide effects executed in the later residual phase |
| `pokered/data/battle/always_happen_effects.asm` | Effects still handled around target fainting |
| `pokered/data/battle/critical_hit_moves.asm` | High-critical-hit move list |
| `pokered/data/battle/unused_critical_hit_moves.asm` | Unused list still present in ROM layout |
| `pokered/data/battle/stat_modifiers.asm` | Thirteen numerator/denominator stage ratios |
| `pokered/data/battle/stat_mod_names.asm` | Stat-stage display names; presentation mapping |
| `pokered/data/battle/stat_names.asm` | Item/stat display names; presentation mapping |

See [Effect dispatch](effect-dispatch.md) for the exact table memberships and pointer/null targets.

## Move, species, and type data

| Source | Contents | Key constraints |
|---|---|---|
| `pokered/constants/move_constants.asm` | Internal move IDs | `NO_MOVE = 0`, 165 moves, `STRUGGLE = $A5`, `CANNOT_MOVE = $FF` |
| `pokered/constants/battle_constants.asm` | Move structure, statuses, volatile flags, damage constants | four moves, level cap 100, base stage 7, max stage 13, stat cap 999 |
| `pokered/macros/data.asm`, `pokered/data/moves/moves.asm`, and battle call sites | `percent` textual arithmetic, move accuracy bytes, and comparisons | exact expanded boundaries; see [Probability thresholds](probability-thresholds.md) |
| `pokered/data/moves/moves.asm` | 165 six-byte move records | animation/effect/power/type/`percent`-scaled accuracy/PP |
| `pokered/data/moves/names.asm` | Move names | presentation and event naming |
| `pokered/constants/pokemon_constants.asm` | Internal species index | gaps, special fossil/ghost IDs, not Pokédex order |
| `pokered/constants/pokedex_constants.asm` | Pokédex IDs | 151 ordinary Pokémon |
| `pokered/data/pokemon/dex_order.asm` | 190-byte internal-index-to-Pokédex map | zero entries drive MissingNo./invalid base-record behavior |
| `pokered/constants/pokemon_data_constants.asm` | Base/party structure offsets | party length 6, party structure 44 bytes, box structure 33 bytes |
| `pokered/data/pokemon/base_stats.asm` | Ordered includes for 150 ordinary records | Mew is stored separately by the original layout |
| `pokered/data/pokemon/base_stats/*.asm` | Base stats/types/catch/base EXP/base moves/growth/TM-HM bits | 151 files in checkout |
| `pokered/data/pokemon/mew.asm` | Mew data and pictures | special `GetMonHeader` branch |
| `pokered/data/pokemon/evos_moves.asm` | Evolution and level-up move data | used to derive wild/trainer/default moves and legality |
| `pokered/data/growth_rates.asm` | Six growth formulas | two rates unused by stock species but valid data |
| `pokered/constants/type_constants.asm` | Type indexes and `SPECIAL = $14` boundary | physical/special is type-index based |
| `pokered/data/types/type_matchups.asm` | Ordered non-neutral matchup triples | matching entries apply sequentially for dual types |
| `pokered/data/types/names.asm` | Type names | presentation/reference |

## Party and stat construction

| Source | Labels | Verification role |
|---|---|---|
| `pokered/macros/ram.asm` | `box_struct`, `party_struct`, `battle_struct` | Byte layout definitions |
| `pokered/ram/wram.asm` | all `wBattle*`, active/party, counters, link RNG | Concrete projection addresses and aliases |
| `pokered/ram/hram.asm` | `hRandomAdd`, `hRandomSub`, `hWhoseTurn`, math scratch | Concrete projection and hardware scratch |
| `pokered/home/move_mon.asm` | `CalcStats`, `CalcStat` | DV/stat-exp formulas and 999 cap |
| `pokered/home/pokemon.asm` | `GetMonHeader`, party helpers | Base-record lookup, special IDs, Mew handling |
| `pokered/engine/pokemon/add_mon.asm` | `_AddPartyMon`, `LoadMovePPs` | Party construction, capture append/naming, PP derivation |
| `pokered/engine/pokemon/load_mon_data.asm` | `LoadMonData_` | Party/box/enemy decoding |
| `pokered/engine/pokemon/evos_moves.asm` | `LearnMoveFromLevelUp`, `WriteMonMoves`, `EvolutionAfterBattle` | Move derivation, evolution dispatch, and post-battle progression |
| `pokered/engine/pokemon/learn_move.asm` | `LearnMove`, `TryingToLearn`, `AbandonLearning` | Nested learn/forget/HM rejection/cancel/confirmation flow and active move/PP copy |
| `pokered/engine/events/evolve_trade.asm`, `pokered/engine/pokemon/set_types.asm` | `EvolveMon`, type update helpers | Evolution species/stat/type/move mutation; animation is separately abstractable |
| `pokered/engine/pokemon/experience.asm` | `CalcLevelFromExperience`, `CalcExperience` | Growth formulas |
| `pokered/engine/menus/pokedex.asm` | `IndexToPokedex` | Internal-index mapping used by enemy-seen and capture-owned writes |
| `pokered/engine/battle/experience.asm` | `GainExperience`, `DivideExpDataByNumMonsGainingExp` | Participation, fainted divisors, EXP/stat EXP, active level-up mutation |

## Trainer battles

| Source | Labels/data | Verification role |
|---|---|---|
| `pokered/engine/battle/read_trainer_party.asm` | `ReadTrainer` | Build enemy party, special move patches, payout |
| `pokered/engine/battle/trainer_ai.asm` | `AIEnemyTrainerChooseMoves`, `TrainerAI`, class routines, item/switch helpers | Move scoring and action substitution; see [Trainer AI dispatch](trainer-ai-dispatch.md) |
| `pokered/data/trainers/parties.asm` | `TrainerDataPointers` and class party lists | Trainer party source |
| `pokered/data/trainers/move_choices.asm` | per-class scoring-layer selection | Trainer move policy |
| `pokered/data/trainers/ai_pointers.asm` | per-class action count and routine | Trainer item/switch policy |
| `pokered/data/trainers/special_moves.asm` | `LoneMoves`, `TeamMoves` | Gym/Elite Four/champion patches |
| `pokered/data/trainers/pic_pointers_money.asm` | trainer picture and payout bases | Payout relevant; picture presentation-only |
| `pokered/engine/math/bcd.asm` | BCD add/divide helpers | Trainer and Pay Day money mutation |
| `pokered/home/trainers.asm`, `pokered/home/trainers2.asm` | `PrintEndBattleText`, `GetSavedEndBattleTextPointer`, metadata | In-driver raw-result-selected dynamic text, flag clearing, and caller-established pointers |
| `pokered/engine/battle/save_trainer_name.asm`, `pokered/engine/overworld/auto_movement.asm` | `SaveTrainerName`, `SetEnemyTrainerToStayAndFaceAnyDirection` | Trainer-name buffer and sprite movement writes reached before driver return |
| `pokered/data/trainers/names.asm`, `pokered/data/trainers/name_pointers.asm` | names | presentation/event identity |
| `pokered/constants/trainer_constants.asm` | trainer IDs and `OPP_ID_OFFSET = 200` | Opponent classification |

## Items, capture, and Safari

| Source | Labels | Verification role |
|---|---|---|
| `pokered/engine/items/item_effects.asm` | `UseItem_`, `ItemUsePtrTable`, `ItemUseBall`, medicine/cure handlers, raw-only Pokédex/Surfboard paths, bait/rock, X items, Poke Doll/Flute, PP restore handlers | All ordinary-item battle rejection/success paths and state mutation; see [Item dispatch](item-dispatch.md) |
| `pokered/engine/items/inventory.asm` | add/remove inventory routines | Quantity mutation |
| `pokered/engine/items/get_bag_item_quantity.asm` | quantity lookup | Action legality |
| `pokered/engine/items/item_effects.asm` plus current-box helpers | `SendNewMonToBox` path | Successful capture naming and slot-1 insertion/shifts when the party is full |
| `pokered/constants/item_constants.asm` | item IDs | 83 ordinary items plus TM/HM range |
| `pokered/engine/battle/safari_zone.asm` | `PrintSafariZoneBattleText` | Bait/rock duration and catch-rate reset |

Battle-menu reachability is narrower than “handler succeeds when `wIsInBattle != 0`”: link blocks the bag before dispatch, Safari and Old Man use synthetic menus, and some unobtainable/raw item IDs nevertheless reach non-rejecting handlers if injected. The exact table is in [Item dispatch](item-dispatch.md). Overworld-only branches still receive explicit coverage dispositions rather than being translated wholesale.

## RNG, timing, link, and arithmetic

| Source | Labels | Verification role |
|---|---|---|
| `pokered/home/random.asm` | `Random` | Bank-preserving wrapper returning `hRandomAdd` |
| `pokered/engine/math/random.asm` | `Random_` | Two `rDIV` reads and `hRandomAdd`/`hRandomSub` update |
| `pokered/home/vblank.asm` | `VBlank`, `DelayFrame` | Calls `Random` once per frame, advances audio, and polls input |
| `pokered/engine/battle/core.asm` | `BattleRandom` | Ordinary RNG delegate or this cartridge perspective's link sequence |
| `pokered/engine/link/cable_club.asm` | random-list generation/exchange, external-clock leading-zero scan, and party exchange | Per-cartridge post-setup link state and conditional synchronization precondition |
| `pokered/constants/serial_constants.asm` | list lengths and link action values | Link protocol constants |
| `pokered/home/math.asm` | `Multiply`, `Divide` wrappers | Register preservation and banked calls |
| `pokered/engine/math/multiply_divide.asm` | `_Multiply`, `_Divide` | Exact big-endian arithmetic algorithms |

The initial text scan found 54 direct `Random`/`BattleRandom` call instructions across the selected battle and adjacent source set. This is not yet a transitive-call count: M0 must generate a symbol/range inventory that includes pointer/predef/text-script/interrupt edges and classifies every reachable code and read-data range by source and mode.

## Driver hardware and caller closure

Processor decode/equations/logical schedules come from the pinned package specified in [Standalone SM83 semantics package](sm83-semantics-package.md) and [SM83 implementation specification](sm83-implementation-spec.md). Its physical fetched-IR pipeline, IDU/address intent, clock gates, interrupt phases, and HALT/STOP/lock behavior follow the [SM83 microarchitecture contract](sm83-microarchitecture-contract.md). The sources below drive the Game Boy adapter and reachable-range proof.

| Source | Verification role |
|---|---|
| `pokered/engine/battle/battle_transitions.asm`, sprite decompress/copy routines | VRAM/OAM/LCD timing and transition execution |
| `LoadPlayerBackPic` in `core.asm` | External SRAM enable/bank and sprite-scratch copy before battle |
| `pokered/home/vblank.asm`, interrupt vectors | VBlank RNG/audio/input, HALT wake, RETI/prefetch, and interrupt scheduling |
| audio engine plus `pokered/audio/play_battle_music.asm` | Music state and sound-wait termination/timing |
| joypad/text/menu engines | Presentation acknowledgements versus mechanics decisions |
| `pokered/engine/events/black_out.asm` | Post-return loss integration, not primary driver output |
| `pokered/engine/events/heal_party.asm` | Post-link auto-heal and blackout integration |

The complete root/edge/range schema is in [End-to-end verification closure](end-to-end-closure.md).

## Presentation-only candidates requiring proof

These files are candidates for abstraction, not automatically safe stubs:

| Source | Candidate abstraction |
|---|---|
| `pokered/engine/battle/animations.asm` | semantic animation event plus hardware-time transcript |
| `pokered/data/moves/animations.asm` | animation data omitted from high-level state |
| `pokered/data/battle_anims/*` | animation data omitted |
| `pokered/engine/battle/battle_transitions.asm` | battle-entry presentation |
| `pokered/engine/battle/draw_hud_pokeball_gfx.asm` | HUD update event |
| `pokered/engine/battle/display_effectiveness.asm` | semantic effectiveness event, no text layout |
| `pokered/engine/battle/print_type.asm` | type-display event |
| `pokered/engine/battle/scale_sprites.asm` | presentation only |
| `pokered/engine/battle/scroll_draw_trainer_pic.asm` | presentation only |
| `pokered/engine/battle/ghost_marowak_anim.asm` | presentation only after ghost-state decision |
| `pokered/engine/battle/link_battle_versus_text.asm` | link intro presentation |
| `pokered/engine/menus/pokedex.asm` | raw-bag Pokédex UI entered from `ItemUsePokedex`; requires an action-result/scratch/timing frame rather than blanket exclusion |

A frame-condition theorem must show that skipping one of these routines cannot alter the projected mechanics state. Because delays trigger VBlank and VBlank mutates ordinary RNG state, the abstraction must also preserve the external timer/random transcript boundary.

## Canonical build inputs

| Artifact | Value |
|---|---|
| pokered commit | `405b6246372d7e5a2cb029cbb65219b13286b8c9` |
| wiki commit reviewed | `38739b79b2bd0e7f00bd434f252a6d48f649b4a0` |
| RGBDS version | `1.0.2`; custom pinned `v1.0.2+hotfix` derivation required because current nixpkgs reports 1.0.1 |
| gb-opcodes commit / JSON SHA-256 | `376f61c86fdac2048f7ce5fe838ae756b306017e` / `e7e3cd657d8e87b44570474eb3a6ed735501c9a00520f3d6937881203c823bc5` |
| Pan Docs / GB CTR / Mooneye commits | `fe246067…` / `d164e646…` / `31510e12…`; exact hashes in microarchitecture contract |
| `sm83-lean` revision | local `packages/sm83-lean` candidate; external immutable release pin pending |
| Red ROM SHA-1 | `ea9bcae617fdf159b045185467ae58b2e4a48b9a` |
| Blue ROM SHA-1 | `d7037c83e1ae5b39bde3c30787637ba1d4c48ce2` |
| Debug Blue SHA-1 | `5b1456177671b79b263c614ea0e7cc9ac542e9c4` |
