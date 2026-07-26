# Mechanics coverage

<!-- mode: reference -->

This is the ASM-audited completeness checklist. Checked rows identify completed, machine-validated artifacts; unchecked rows remain requirements even when supporting definitions exist.

## Status vocabulary

| Status | Meaning |
|---|---|
| Discovered | Source and expected responsibility identified |
| Modeled | High-level Lean behavior exists |
| ROM-linked | Routine/table theorem connects behavior to canonical ROM bytes |
| Transition-verified | Covered by a checkpoint transition theorem |
| Episode-verified | Covered by the composed finite battle theorem |

The project has moved beyond discovery for the processor, canonical build, initial Game Boy adapter, and battle-state codec. Mechanics rows remain at their explicitly reported status.

## Artifact and machine layer

- [x] Red source commit and RGBDS version pinned
- [x] canonical Red ROM rebuilt and SHA-1 checked
- [x] ROM SHA-256, `.sym`, and `.map` recorded
- [x] address-based battle graph is regenerated from caller-supplied canonical bytes, with direct control flow, RGBDS far/home calls, predefs, interrupt roots, presentation summaries, and explicit conservative dynamic domains (`tools/generate-pokered-reachability.py`, `artifacts/pokered/reachability-manifest.json`)
- [x] trainer end-text/map callbacks have an explicit per-edge classification theorem boundary (`Battle.Rom.Reachability.trainer_callbacks_classified`)
- [x] all 64 physical ROM bank ranges, used linker sections, decoded reachable ranges, HRAM targets, and dynamic domains are classified and hash-bound (`tools/check-pokered-closure.py`, `Battle.Rom.Reachability.Certificate`)
- [x] separately licensed, immutable-revision [`sm83-lean` package](sm83-semantics-package.md)
- [x] exact-hash gb-opcodes plus [five-source microarchitecture audit](sm83-microarchitecture-contract.md)
- [x] exact 244-legal + CB-prefix + 11-lockup base partition and all 256 CB entries
- [x] decoder/encoder length, immediate, PC-wrap, and byte-round-trip theorems
- [x] arithmetic/flag semantics, including 2048-case DAA theorem, old-Z irrelevance, all 4096 Mooneye rows, and signed-SP rules
- [x] load/store/register-pair semantics and typed zero-low-nibble F codec
- [x] declarative, de-overlapped, and physical fetched-IR semantics with sequence-level fetch reassociation
- [x] 101-family address/data/IDU/commit/poll schedules and typed CPU-T/M-cycle accounting
- [x] staged EI/DI/RETI, prefetch-aware five-cycle interrupt entry and exact IE-push cancellation/retargeting
- [x] HALT wake/bug and one-byte/multibyte/CB/RST following-byte cases; seven STOP outcomes; invalid no-fetch lockup
- [x] full pinned flat-bus corpus, microarchitecture source audit, and theorem/axiom audit
- [x] proved `DmgCpuBCommonBoot` T1F–T4R bus/read-fold/interrupt/clock composition and checked profile manifest
- [x] ROM banking and far-call contracts preserve MBC selection/return-bank state rather than flat `$2000` writes (`Battle.GameBoy.Mbc3.read_switchable_rom`, `Battle.Rom.Reachability.far_calls_are_mbc_aware`)
- [x] WRAM/HRAM and echo aliases (`Battle.GameBoy.Memory.read_wram`, `read_echo`, `read_hram`, `write_hram`)
- [x] Game Boy `DIV`, timer, interrupt, and VBlank device state advances per T-cycle (`Battle.GameBoy.Devices.tickT`, `tickT_divider`, `pendingInterrupts_range`)
- [x] joypad/link/timer external responses are explicit and do not borrow battle RNG (`Battle.GameBoy.Devices.ExternalResponses`, `applyExternal`, `joypad_selected_groups`)
- [x] `rLY`, VBlank progress, HALT wake input, and interrupt projection required by waits are explicit (`Battle.GameBoy.Devices.ly_tracks_ppu_dot`, `Battle.GameBoy.Adapter.stepMachineCycle`, `pins_refine_actual`)
- [x] VRAM/OAM/DMA storage and one-byte-per-M-cycle DMA summaries are modeled (`Battle.GameBoy.Memory.stepDma`, `stepDma_preserves_cartridge`, `Battle.GameBoy.Adapter.step_edge_count`); silicon-family active-access uncertainty remains fixture-qualified
- [x] audio/VBlank progress for sound-completion loops is an explicit external response contract (`Battle.GameBoy.Devices.audio_wait_requires_explicit_progress`)
- [x] serial waits distinguish internal T-cycle clocks from supplied external edges (`Battle.GameBoy.Devices.tickSerialInternal`, `externalSerialEdge`, `serial_edge_decrements_eight_bit_transfer`)
- [x] paired cartridge state and bitwise serial exchange are separate perspectives (`Battle.Full.Link.Pair`, `Battle.GameBoy.Devices.exchangeSerialEdge`)
- [x] external-clock random-list leading-zero scan and post-setup list mismatch (`Battle.Full.Link.leading_zero_setup_mismatch`)
- [x] `_Multiply`/`_Divide` functional contracts include 24×8 multiplication, selected-width quotient/remainder, zero-divisor divergence, and exact entry-byte boundaries (`Battle.Rom.MathRoutines`)
- [x] `percent` macro's `$ff / 100` integer scaling at every probability threshold
- [x] divergence and fuel-exhaustion distinction

## Canonical data

| Data | Count/shape | Source | Status |
|---|---:|---|---|
| Move records | 165 × 6 bytes | `pokered/data/moves/moves.asm` | ROM-certified |
| Move IDs | 0 plus 165 moves | `pokered/constants/move_constants.asm` | Discovered |
| Move effects | IDs `$00`–`$56` with gaps | `pokered/constants/move_effect_constants.asm` | Discovered |
| Effect pointers | one per nonzero effect slot | `pokered/data/moves/effects_pointers.asm` | ROM-certified |
| Base species | 150 contiguous records + detached Mew | `pokered/data/pokemon/base_stats*`, `pokered/data/pokemon/mew.asm` | ROM-certified |
| Internal species map | IDs with gaps/special forms | `pokered/constants/pokemon_constants.asm` | Discovered |
| Pokédex IDs | 151 ordinary constants | `pokered/constants/pokedex_constants.asm` | Discovered |
| Type IDs | physical and special ranges with gaps | `pokered/constants/type_constants.asm` | Discovered |
| Type triples | ordered non-neutral interactions | `pokered/data/types/type_matchups.asm` | ROM-certified |
| Stage ratios | [13 exact decimal-style numerator/denominator pairs and update flow](stat-modifier-flow.md) | `pokered/data/battle/stat_modifiers.asm` | ROM-certified |
| Percent thresholds | [literal event expressions, 165 move-accuracy expansions, and boundaries](probability-thresholds.md) | moves/battle/effect/AI source | Machine-validated |
| Trainer classes | 47 | `pokered/constants/trainer_constants.asm` | Discovered |
| Trainer parties | class-indexed variable records | `pokered/data/trainers/parties.asm` | Discovered |
| Trainer move scoring | [47 class-indexed layer lists](trainer-ai-dispatch.md) | `pokered/data/trainers/move_choices.asm` | Discovered |
| Trainer action AI | [47 count + pointer rows](trainer-ai-dispatch.md) | `pokered/data/trainers/ai_pointers.asm` | Discovered |
| Special trainer moves | lone/team patches | `pokered/data/trainers/special_moves.asm` | Discovered |
| Learnsets/evolutions | 190 pointers + variable payloads | `pokered/data/pokemon/evos_moves.asm` | ROM-certified |
| Growth rates | 6 coefficient records | `pokered/data/growth_rates.asm` | ROM-certified |
| Battle item dispatch | [83 ordinary entries](item-dispatch.md) before TM/HM IDs | `pokered/engine/items/item_effects.asm` | Discovered |
| Evolution entries | level/item/trade records followed by moves | `pokered/data/pokemon/evos_moves.asm` | ROM-certified |
| Bag/current box layouts | ordered items and capture destination | WRAM structures and inventory/box helpers | Discovered |
| Internal-to-Pokédex map | 190 entries including zero/MissingNo. slots | `pokered/data/pokemon/dex_order.asm` | ROM-certified |

For each table:

- [x] bounds theorem for every inventory ID, conditional on explicit caller bytes (`Battle.Rom.AllTables.bounds_theorem`)
- [x] dependent typed decoder for every inventory ID (`Battle.Rom.AllTables.TypedCodec`, `typed_decoder_theorem`)
- [x] universal encode/decode theorem required per codec (`Battle.Rom.AllTables.encode_decode_theorem`)
- [x] original-byte equality required per canonical table (`Battle.Rom.AllTables.original_byte_equality_theorem`)
- [x] encoded table-length theorem required per codec (`Battle.Rom.AllTables.table_length_theorem`)
- [x] pinned source-manifest and canonical ROM hashes are retained in `artifacts/pokered/build-manifest.json` and checked by `tools/check-pokered-build.py`

## End-to-end driver closure

The complete gate list is [End-to-end verification closure](end-to-end-closure.md).

- [x] hermetic RGBDS 1.0.2 ROM build, `.sym`, `.map`, SHA-1/SHA-256
- [x] explicit `InitOpponent` bank/stack/hardware entry plus decoded supplied-opponent `InitBattle` prefix (`Battle.DriverInvariant.InitOpponentCallerEntry`, `caller_entry_exposes_bank_stack_hardware`, `Battle.Rom.InitBattleRoutine.supplied_opponent_reaches_initOpponent`, `canonical_prefix_exact`)
- [x] no-encounter `InitBattle` decision is separate from battle-driver completion (`Battle.Rom.InitBattleRoutine.InitBattleDecision`, `no_encounter_path_is_not_completion`)
- [x] transitive code/data closure records selected-bank context, physical ranges, MBC/far/predef edges, interrupt roots, assets, and callback summary sites (`artifacts/pokered/reachability-manifest.json`)
- [x] every direct target is classified; 73 genuinely indirect sites carry the sound all-retained-ROM conservative target domain, with zero omitted/unclassified edges (`tools/check-pokered-closure.py`, `Battle.Rom.Reachability.no_unresolved_reachable_edge`)
- [x] VRAM/OAM/MMIO/external-SRAM/audio/joypad/serial/LCD are represented by proved storage/device or explicit external-progress summaries (`Battle.GameBoy.Memory`, `Mbc3`, `Devices`, `Adapter`; continuous episode use remains below)
- [x] mode bytes, selected bank, fetched `StartBattle` IR, next PC, and CALL frame form the pre-kernel refinement checkpoint (`Battle.Rom.DriverClosure.ModeSetupCheckpoint`, `mode_setup_precedes_startBattle`)
- [x] terminal provenance is captured before cleanup and enters `ending`; simultaneous faint with reserves remains nonterminal (`Battle.Rom.DriverClosure.terminal_enters_ending_before_cleanup`, `Battle.Full.Engine.simultaneous_with_reserves_is_nonterminal`)
- [x] Pay Day/evolution/move-learning guards remain in `ending` until typed nested work completes, then cleanup preserves provenance (`Battle.Full.Environment.settle_after_nested_completion`, `settle_waits_for_learning`, `Battle.Rom.DriverClosure.epilogue_preserves_terminal_provenance`)
- [x] decoded outer shell restores caller bytes, tile animation, stack, carry and return PC; the composed result is typed (`Battle.Rom.OuterReturnRoutine`, `Battle.Rom.DriverClosure.returned_episode_exact`, `continuous_initOpponent_to_return`)
- [x] encounter triggering is explicitly before entry; blackout, trainer scripts, link auto-heal, and Old Man cleanup are after return (`Battle.Full.OuterFlow.callerBoundaryPosition`, `caller_boundaries_are_explicit`, `cable_heal_requires_return`)
- [ ] first supplied one-member wild fixture proved `InitOpponent`-to-return

## Battle modes

| Mode | Initialization | Controller/RNG distinctions | Status |
|---|---|---|---|
| Supplied wild | explicit `InitOpponent` entry → `InitWildBattle`, `LoadEnemyMonData` | random DVs, ordinary `BattleRandom`, capture/run | Discovered |
| Trainer | explicit `InitOpponent` entry → `ReadTrainer`, trainer/end-text setup | move-scoring AI plus direct-`Random` action AI | Discovered |
| Link | cable party/list setup, `LoadEnemyMonFromParty` | paired perspectives, exchanged choices, per-perspective nine-seed cycles, no items/AI/EXP | Discovered |
| Safari | normal wild initialization plus `BATTLE_TYPE_SAFARI` | Safari menu, direct `Random` escape, factors | Discovered |
| Old Man | caller-set `BATTLE_TYPE_OLD_MAN` through common driver | forced capture, player-name restoration, aliased wild-buffer overwrite | Discovered |
| Ghost/Marowak | map/opponent special checks | action/capture restrictions and ghost behavior | Discovered |

## Party and initialization

- [x] party count/species terminator invariants (`Battle.partySpeciesFrameValid`, `party_species_frame_exact`)
- [x] 44-byte party member codec (`Battle.PartyMonBlock.decode_encode`, `encode_decode`)
- [x] 29-byte active member codec (`Battle.BattleMon.decode_encode`, `encode_decode`)
- [x] names and OT IDs where mechanics-relevant (`Battle.Full.CaptureProtocol.finishName`, `Battle.Full.Evolution.acceptance_preserves_ownership_and_name`, `Battle.Full.Progression.PersistentMon.otId`)
- [x] base record lookup, including Mew and special fossil/ghost IDs (`Battle.Full.Initialization.headerPlan`, `header_special_cases`, `sprite_only_preserves_mechanics`)
- [x] wild DV generation (`Battle.Full.Initialization.wildDvs`, `dv_source_witnesses`)
- [x] fixed trainer DVs (`Battle.Full.Initialization.trainerDvs`, `dv_source_witnesses`)
- [x] special trainer move patches and stale enemy-party PP bytes before active PP reload (`Battle.Full.Initialization.trainer_patch_retains_stale_pp`, `active_pp_reload_matches_moves`)
- [x] HP/stat calculation from base stat, DV, stat EXP, and level (`Battle.Full.Progression.calculateStats`, `statFormula`)
- [x] HP DV derivation (`Battle.Full.Progression.hpDv`, `hp_dv_derivation_witness`)
- [x] 999 stat cap (`Battle.Full.Progression.non_hp_stat_capped`)
- [x] default/base moves (`Battle.Full.CaptureProtocol.initialMoves`, `initial_moves_have_four_slots`)
- [x] level-up move derivation and four-slot shifting (`Battle.Full.Progression.firstExactLevelMove`, `Battle.RL.MoveHistory.writeMove`, `naturalMoves`)
- [x] move PP and PP Up encoding (`Battle.RL.MoveHistory.first_pp_up_exact`)
- [x] `wBattleMonSpecies2`/`wEnemyMonSpecies2` identity versus Transform-mutable species (`Battle.SideState.originalSpecies`, `Battle.Full.Effects.transform_copy_boundaries`)
- [x] active party-position byte versus authoritative player/enemy indexes (`Battle.SideState.partyPosition`, `Battle.Full.SideState.switch_success_shape`)
- [x] active copied catch rate versus separate `wEnemyMonActualCatchRate` (`Battle.SideState.actualCatchRate`, `Battle.Full.Environment.resolveCapture`)
- [x] active data load from party (`Battle.Full.SideState.loadIncoming`, `switch_success_shape`)
- [x] burn/paralysis penalties on send-out (`Battle.MonState.withBattleStatusPenalties`, `Battle.Full.wild_send_out_applies_badge_after_status`)
- [x] badge boosts on send-out and explicit link-battle bypass (`Battle.Full.applyPlayerSendOutBadges`, `link_send_out_skips_badges`)
- [x] initial stage values (`Battle.StatStages.neutral_resets_all_eight_bytes`)
- [x] distinct gain-EXP/fought-current-enemy flags and [transition matrix](switch-faint-and-participation.md) (`Battle.Full.Environment.clearGainFlag`, `restoreGainFlag`, `resetParticipation`)
- [x] named mode-specific reset images at explicit driver entry: normal/Old-Man/Safari caller state plus stack/bank (`Battle.Full.Initialization.ResetImage`, `normal_oldman_and_safari_reset_images`, `init_partial_reset_exact`); hardware transition effects remain separately tracked below
- [x] `InitBattleVariables` partial reset (`wMiscBattleData`) versus stale `wBattleStatusData` and caller-owned normal/Old Man `wBattleType` (`Battle.Full.Initialization.init_partial_reset_exact`)
- [x] transition code's VRAM/OAM/MMIO/audio/external-SRAM sprite-scratch effects are explicitly excluded from mechanics state and retained as Game Boy adapter obligations (`Battle.Full.Initialization.transition_hardware_explicitly_excluded`)
- [x] unconditional first-living-enemy scan, including arbitrary caller-supplied scratch start (`Battle.Full.Initialization.firstLivingStep`; intentionally unbounded)
- [x] first living player member search (`Battle.Full.Initialization.firstLivingStep`)
- [x] ordinary enemy-load Pokédex seen-flag mutation and link-load omission (`Battle.Full.Initialization.seenDexAfterLoad`, `link_load_omits_seen`)
- [x] invalid/no-living-member behavior, including zero-count 256-iteration `AnyPartyAlive`/`AnyEnemyPokemonAliveCheck` (`Battle.Full.Initialization.aliveScanIterations`, `zero_count_alive_scan_wraps`)
- [x] MissingNo./zero Pokédex-map base-record behavior under raw-state mode (`Battle.Full.Initialization.HeaderPlan.rawOffset`, `header_special_cases`, caller-supplied raw row in `applyHeaderPlan`)

## Action legality and turn consumption

- [x] full-menu bypass only for Rage/recharge/Thrash/charge continuation (`Battle.Full.fullMenuBypass`, `automatic_and_post_fight_locks_are_separate`)
- [x] Fight-without-slot behavior for sleep/freeze/Bide/trapping states (`Battle.Full.fightSkipsMoveMenu`, represented by legal `.noAction` after Fight commit)
- [x] switch/item/run remain selectable in those post-menu lock states (`Battle.Full.trapped_switch_remains_protocol_selectable`, `ordinary_item_exact`, `trainer_run_selectable`)
- [x] ordinary Fight/move-slot availability (`Battle.Full.ordinary_fight_exact`)
- [x] selectable move has PP and is not disabled (`Battle.Full.usableMoveSlot`, `ordinary_fight_exact`)
- [x] Struggle when no selectable move remains (`Battle.Full.mustStruggle`, `legal_fight_not_exhausted`)
- [x] `AnyMoveToSelect` PP masking differences with/without Disable and PP Up bits (`Battle.Full.anyMovePpAvailable`)
- [x] potential move-menu trap when disabled handling sees raw PP-Up bits but slots have zero current PP (`Battle.Full.disabled_pp_up_struggle_anomaly`)
- [x] player item legality (`Battle.Full.ordinary_item_exact`, `itemSelectable`)
- [x] item target legality (`Battle.Full.Items.mapTarget`, `out_of_range_target_rejected`)
- [x] switch target is living and not active (`Battle.Full.SideState.canSwitchTo_sound`)
- [x] run legality and trainer prohibition (`Battle.Full.trainer_run_selectable`, `Battle.Full.Escape.trainer_prohibited`)
- [x] link action exchange values (`Battle.Full.Link.encodeAction`, `decodeAction`, `action_roundtrip`)
- [x] Safari actions (`Battle.Full.Safari.Action`, `act`, `Battle.Full.Environment.resolveSafari`)
- [x] successful item consumes action (`Battle.Full.Engine.step` item branch composes through `executePair`; `finish_turn_increments`)
- [x] successful switch consumes action (`Battle.Full.Engine.step` switch commit composes through `executePair`; `finish_turn_increments`)
- [x] failed wild run consumes action (`Battle.Full.Engine.failed_run_nonfight_finishes_turn`, `Battle.Full.Environment.resolveRun`)
- [x] canceled/failed menu operation does not consume action (`Battle.Full.Selection.cancelFight`, `Battle.Full.Engine.StepResult.ineffectiveAction`)
- [x] `CANNOT_MOVE` when trapped after top-level selection (`Battle.Full.Engine.executeCommitted` emits `Status.CannotActReason.trapped` before non-Fight action effect)
- [x] replacement choice after faint (`Battle.Full.Action.forced_switch_exact`, `Battle.Full.Engine.forcedReplacement`)
- [x] wild-faint choice to replace or attempt escape using `wPartyMon1Speed` (`Battle.Full.forced_wild_player_may_try_run`, `Battle.Full.Environment.wildFaintRunSpeed`, `resolveWildFaintRun`)
- [x] shift-style stay/switch response before trainer send-out (`Battle.Full.EndFlow.ShiftResponse`, `resolveShift`)
- [x] ordinary player Mimic target-move request (`Battle.Full.Engine.StepResult.mimicPending`, `resumeMimic`)
- [x] item party/move target requests and cancellation (`Battle.Full.Items.Request`, `mapTarget`, `Battle.Full.Engine.StepResult.ineffectiveAction`)
- [x] move-learning nested learn/forget/HM rejection/cancel/abandon-confirmation requests (`Battle.Full.Learning.Response`, `respond`, `hm_rejection_reprompts`, `abandon_decline_restarts`)
- [x] capture nickname/default-name request for party and box destinations (`Battle.Full.CaptureProtocol.Pending`, `NameResponse`, `finishName`)
- [x] post-battle evolution cancel request (`Battle.Full.Evolution.Response.cancel`, `cancellation_advances_to_next_flagged_member`)

## Mechanics-visible selection layer

- [x] choosing Fight resets `wNumRunAttempts` (`Battle.Full.Selection.openFight_resets_attempts`)
- [x] non-disabled highlighted move writes `wPlayerSelectedMove` (`Battle.Full.Selection.enabled_highlight_loads`)
- [x] non-disabled highlight reloads power/type/accuracy/PP scratch; disabled highlight does not (`enabled_highlight_loads`, `disabled_highlight_preserves_record`)
- [x] canceling Fight preserves stale selected move/record and highlighted `wPlayerMoveListIndex` (`Battle.Full.Selection.cancel_preserves`)
- [x] stale selected move influences Quick Attack/Counter order for item/switch turns (`Battle.Full.Engine.stale_counter_nonfight_priority`)
- [x] stale loaded power/type influences enemy Counter (`Battle.Full.Engine.stale_tackle_record_enables_counter`)
- [x] player send-out clears loaded move number but retains selected move, shared damage, and adjacent loaded-record scratch (`Battle.Full.Engine.send_out_clears_move_but_retains_record`, `send_out_retains_stale_priority`)
- [x] ordinary move-menu SELECT swaps active move IDs and PP (`Battle.Full.Selection.swapMoves_exact`)
- [x] move swap updates party move IDs and PP independently, including transformed active/party mismatch (`Battle.Full.Selection.swapActiveAndParty`, `swap_active_and_party_exact`)
- [x] move swap updates disabled-slot encoding (`Battle.Full.Selection.swapMoves_exact`)
- [x] battle-bag SELECT swaps ordered item/quantity entries (`Battle.Full.Selection.swapBag_exact`)
- [x] move/bag reorder consumes no battle turn (`Battle.Full.Selection.swapMoves`, `swapBag` are selection-only transitions)
- [x] cartridge-ineffective selection attempt versus protocol-invalid response (`Battle.Full.Engine.StepResult.ineffectiveAction` versus `.invalidAction`)
- [x] canonical RL `ActionCommit` trace refines one concrete menu path (`Battle.Full.Selection.action_commit_trace_refines_fight`)
- [x] full selection trace covers browse/cancel/reorder paths (`Battle.Full.Selection.Command`, `runTrace`, `browse_cancel_reorder_trace_is_explicit`)

## Order and phase flow

- [x] Quick Attack ordering (`Battle.Step.quickAttack_precedes_normal`)
- [x] Counter ordering (`Battle.Step.counter_follows_normal`)
- [x] stale selected moves retained by locked/forced player and enemy selection paths (`Battle.Full.Engine.locked_and_forced_selection_stays_stale`)
- [x] Speed comparison (`Battle.Step.faster_side_first_player`, `faster_side_first_enemy`)
- [x] equal-Speed random comparison (`Battle.Step.equal_speed_consumes_one`)
- [x] link clock-role inversion (`Battle.Full.Link.equal_speed_roles_agree_on_physical_first`)
- [x] trainer AI action immediately before enemy execution (`Battle.Full.Environment.prepareTrainer`, `Battle.Full.Engine.beginEnemyExecution_increments`)
- [x] trainer shift-style prompt conditions in `EnemySendOut` (`Battle.Full.EndFlow.shouldOfferShift`, `shift_prompt_boundaries`)
- [x] `wFirstMonsNotOutYet` suppression during first send-out and AI switch (`Battle.Full.EndFlow.shouldOfferShift`; exact sentinel value one)
- [x] item/switch already committed before move-order resolution (`Battle.Full.Engine.step` applies `processNonFight`/`applyItem` before `executePair`)
- [x] stale player move still participates in Quick Attack/Counter ordering (`Battle.Full.Engine.stale_counter_nonfight_priority`)
- [x] stale priority orders the switch no-op; incoming poison/burn residual can run and KO before enemy action or after it (`Battle.Full.Engine.orderingMove`, `executePair`, `executeCommitted`)
- [x] escape checks after move execution (`Battle.Full.Engine.executeMove` `.escaped` signal branch)
- [x] faint check before residual/other actor where source does so (`Battle.Full.Engine.executeMove`, `recordFaint` precedes `applyResidual`/second actor)
- [x] acting-side poison/burn/Leech Seed (`Battle.Full.Status.applyResiduals`)
- [x] second actor execution (`Battle.Full.Engine.executePair`)
- [x] second residual (`Battle.Full.Engine.executeCommitted` applies acting-side residual for each actor)
- [x] poison/burn can reduce the actor to zero before Leech Seed still runs and heals (`Battle.Full.Status.leech_seed_runs_after_residual_ko`)
- [x] Leech Seed overkill heals nominal computed damage rather than capped HP loss (`leech_seed_runs_after_residual_ko`)
- [x] Toxic counter increments once for poison and again for Leech Seed on the same residual pass (`Battle.Full.Status.toxic_leech_seed_ticks_twice`)
- [x] trapping counter cleanup (`Battle.Full.Engine.clearTrappingLock`, `advanceMoveLock`)
- [x] loop back to selection (`Battle.Full.Engine.finish_turn_increments`; next `step` re-enters `.battling` choice)
- [x] simultaneous-active-faint paths as event/order metadata, including nonterminal reserve continuation (`Battle.Full.Engine.recordSimultaneousFaint`, `simultaneous_with_reserves_is_nonterminal`)
- [x] terminal witness enters `ending`, not returned/done (`simultaneous_player_exhausted_is_loss`, `simultaneous_enemy_exhausted_is_win`)
- [x] terminal trainer payout, raw-result-guarded Pay Day/evolution, cleanup, and outer return phases are typed (`Battle.Full.Engine.recordFaint`, `Battle.Full.Money.epilogue`, `Battle.Full.Environment.evolution?`, `settle`); exact end-text/system execution remains in the artifact checklist

## Status gate order

The proof must preserve this player/enemy control-flow order, including random consumption and counter updates:

- [x] sleep decrement, wake, and turn loss (`Battle.Full.Status.waking_consumes_turn`)
- [x] freeze (`Battle.Full.Status.frozen_blocks_turn`)
- [x] trapped by opponent (`Battle.Full.Status.opposing_trap_blocks_turn`)
- [x] flinch gate and destructive reset (`Battle.Full.Status.ordered_status_gate_witnesses`); main-loop reset bypass remains represented by forced-action selection
- [x] Hyper Beam recharge gate and reset (`Battle.Full.Status.ordered_status_gate_witnesses`)
- [x] Disable counter decrement/expiration (`Battle.Full.Status.tickDisable`, `disable_low_nibble_one_expires`)
- [x] confusion counter and self-hit roll (`Battle.Full.Status.ordered_status_gate_witnesses`); animation remains event/presentation scope
- [x] selected move disabled after selection (`Battle.Full.Status.ordered_status_gate_witnesses`)
- [x] paralysis roll with exact 63/256 boundary (`Battle.Full.Status.ordered_status_gate_witnesses`, `paralysis_threshold_exact`)
- [x] Bide accumulation/release (`Battle.Full.Engine.applyDamage`, `bide_release_doubles`, `bide_release_caps`)
- [x] Thrash/Petal Dance continuation and confusion (`Battle.Full.Engine.advanceMoveLock`, `Battle.Full.Effects.confusion_duration_boundaries`)
- [x] trapping continuation and reused damage (`Battle.Full.Engine.executeMove` continued-trap branch, `clearTrappingLock`)
- [x] Rage continuation (`Battle.Full.Engine.moveOfAction`, `Battle.Full.Effects.applyAfter` Rage branch)
- [x] ordinary move execution (`Battle.Full.Engine.executeMove`)

## Traded-Pokémon disobedience

- [x] disabled entirely in link battles (`Battle.Full.Disobedience.link_obeys_without_draws`)
- [x] two-byte OT ID comparison with player ID (`Battle.Full.Disobedience.owned_obeys_without_draws`)
- [x] badge thresholds: 10/30/50/70/101 (`Battle.Full.Disobedience.badge_obedience_thresholds`)
- [x] level-at-or-below-threshold obedience (`Battle.Full.Disobedience.level_at_threshold_obeys`)
- [x] first swapped-byte rejection/obedience loop (`Battle.Full.Disobedience.feed`)
- [x] second rejection loop selecting alternate behavior (`swapped_then_unswapped_alternate_witness`)
- [x] alternate usable move and retry conditions, including raw full-PP-byte nonzero check (`canChooseAlternate`, `pp_up_bits_make_zero_pp_selectable`)
- [x] replacement move changes identity but PP decrement still uses the originally selected `wPlayerMoveListIndex` (`Battle.Full.Engine.disobedience_charges_original_slot`)
- [x] zero-current-PP replacement with PP Up bits can underflow/deform the full PP byte on decrement (`Battle.Full.Engine.decrement_zero_pp_underflows`, `decrement_pp_up_only_deforms`)
- [x] no alternate move with one move, Disable, Struggle, or only one PP-bearing move (`Battle.Full.Disobedience.canChooseAlternate`)
- [x] random nap duration and whole-status-byte overwrite of poison/burn/paralysis (`Battle.Full.Disobedience.nap_whole_status_witness`)
- [x] loaf/turn-away/ignore text branch state (`Battle.Full.Disobedience.feed` `.idleText`)
- [x] disobedient self-damage path (`Battle.Full.Disobedience.self_damage_witness`)
- [x] exact `BattleRandom` phase consumption and move identity reload (`Battle.Full.Disobedience.Machine.draws`, `feed`, `Battle.Full.Engine.resumeDisobedience`)

## Damage and hit system

- [x] physical/special selection by type index `$14` (`Battle.TypeChart.isSpecial`, `Battle.Full.Engine.initialDamage`)
- [x] current Attack/Defense/Special selection (`Battle.Full.Engine.offensiveStat`, `defensiveStat`)
- [x] Reflect and Light Screen doubling (`Battle.DamageStats.resolve`, `screen_512_freezes`, `screen_hurts_696`)
- [x] critical hit unmodified-calculated-stat substitution (`Battle.Full.Engine.critical_uses_unmodified_stats`); party/enemy/link sources remain explicit in each `Battle.SideState.unmodified` row
- [x] critical level doubling (`Battle.Damage.calcBaseDamage`, `canonical_damage_witnesses`)
- [x] stat scaling by division by four (`Battle.DamageStats.scaleToByte_exact`)
- [x] low-byte truncation/wrap behavior (`Battle.DamageStats.scaleToByte_exact`)
- [x] zero-defense divergence (`Battle.DamageStats.low_defense_freezes`, `Battle.Damage.zero_divisor_iff`)
- [x] Explosion defense halving with minimum divisor one (`Battle.Full.Engine.initialDamage`)
- [x] neutral damage integer pipeline (`Battle.Damage.calcBaseDamage`, `canonical_damage_witnesses`)
- [x] neutral minimum and 999 cap (`Battle.Damage.calcBaseDamage`)
- [x] STAB `1.5×` with floor (`Battle.Damage.adjustDamageForType`, `canonical_damage_witnesses`)
- [x] ordered dual-type application (`Battle.Damage.adjustDamageForType`, `canonical_damage_witnesses`)
- [x] immunity and low-damage-to-zero miss behavior (`Battle.Damage.missesByType`, `canonical_damage_witnesses`)
- [x] STAB/type arithmetic wrap and last-match `wDamageMultipliers` rather than net dual-type encoding (`Battle.Damage.adjustDamageForTypeWithLast`, `type_adjustment_scratch_witnesses`)
- [x] `rrca` of each damage-random byte before rejection (`Battle.Ordinary.rotateRight`, `damageFactorAccepted`)
- [x] random factor rejection and accepted `217..255` multiplier (`Battle.Ordinary.regen_accepts_within`, `drawDamageFactor`, `Battle.Damage.randomizeDamage`)
- [x] accuracy/evasion two-pass flooring, per-pass minimum 1, and final cap 255 (`Battle.Accuracy.calcHitChance`, `neutral_stages_exact`, `order_observable`); destructive loaded-accuracy WRAM write remains a routine-level obligation
- [x] raw accuracy 0 hits on byte 0; threshold 255 misses on byte 255 (`Battle.Accuracy.zero_accuracy_hits_only_zero`, `one_in_256_witness`)
- [x] stage intermediate flooring/truncation (`Battle.Accuracy.applyRatio`, `equal_stage_profile_exact`)
- [x] Mist, Substitute, and Dream Eater pre-accuracy checks (`Battle.Full.Engine.substitute_mist_dream_gates`)
- [x] X Accuracy bypasses stage/final accuracy only after Fly/Dig invulnerability (`Battle.Full.Engine.invulnerability_precedes_x_accuracy`, `x_accuracy_bypasses_stages_and_random`); handler-specific Dream Eater/Substitute/Mist gates precede this call
- [x] Swift returns before Substitute/Fly-Dig/Mist/X Accuracy behavior (`Battle.Full.Engine.swift_precedes_accuracy_gates`)
- [x] Fly/Dig invulnerability ordering (`Battle.Full.Engine.invulnerability_precedes_x_accuracy`, `Battle.Full.Status.interrupted_charge_leaves_invulnerability`)
- [x] Dream Eater sleep check (`Battle.Full.Engine.substitute_mist_dream_gates`)
- [x] Substitute interaction before status/stat-down accuracy (`Battle.Full.Engine.substitute_mist_dream_gates`)
- [x] final `random < accuracy` comparison (`Battle.Accuracy.strict_boundary_iff`)
- [x] critical threshold from base Speed (`Battle.Critical.thresholdFromSpeed`)
- [x] high-critical move list: Karate Chop, Razor Leaf, Crabhammer, Slash (`Battle.Critical.highCriticalMove`, `Battle.Rom.CombatTables.RequiredCombatBytes.highCriticalExact`)
- [x] Focus Energy right-shift bug (`Battle.Critical.focus_branch_is_second_right_shift`, `focus_never_improves`, `focus_energy_witness`)
- [x] critical random-byte rotations (`Battle.Critical.rotateRandom_inverse`, `strict_boundary_iff`)
- [x] HP subtraction, overkill cap, and shared damage update (`Battle.Step.saturatingSub_overkill`, `saturatingSub_exact`, `Battle.Full.Engine.applyDamage`)
- [x] Substitute damage path, damage-greater-than-255 break, and exact-damage zero-HP survival (`Battle.Full.Engine.substitute_high_byte_breaks`, `substitute_exact_damage_survives`, `Battle.BugWitnesses.decoded_substitute_zero_user_hp_occurs`)
- [x] substitute break zeroes the attacker's loaded effect while nonbreaking hits retain it (`Battle.Full.Engine.clear_loaded_effect_is_side_local`; invoked only when `DamageApplied.effectNullified`)
- [x] Rage-building response to surviving direct or Substitute damage (`Battle.Full.Engine.buildRageAfterDamage`, `rage_builds_after_surviving_damage`)
- [x] OHKO succeeds when user current Speed is equal to or greater than target Speed (`Battle.Rom.OhkoRoutine.decoded_speed_comparison_exact`)
- [x] OHKO critical-test draw, speed gate, and successful ordinary accuracy ordering (`Battle.Full.Engine.executeMove`, `Battle.Full.Effects.ohko_speed_tie_hits`, `ohko_accuracy_miss_fails`, `Battle.Rom.OhkoRoutine.decoded_speed_comparison_exact`)
- [x] Super Fang one-half current HP with minimum one (`Battle.Full.Effects.fixed_damage_family_exact`)
- [x] fixed-damage/Super Fang bypass of ordinary STAB/type adjustment (`Battle.Full.Effects.specialDamage`, `fixed_damage_family_exact`, `Battle.Full.Engine.initialDamage`)
- [x] player/enemy fixed-damage and Psywave range asymmetry (`Battle.Full.Effects.fixed_damage_family_exact`, `Battle.LinkBugs.psywave_link_desync`)
- [x] Counter's selected-move/type/power and shared-`wDamage` dependencies (`Battle.Full.Engine.counterEligible`, `counterDamage`)
- [x] Counter doubles/caps shared damage, rejects before its own hit test when ineligible, and skips ordinary damage/type/randomization (`counter_valid_exact`, `counter_caps_shared_damage`, `counter_rejection_skips_accuracy`, `counter_protocol_gates`)
- [x] Counter still performs the preceding critical test and can retain critical event/text state (`Battle.Full.Engine.counter_protocol_gates`, critical-event prefix in `executeMove`)
- [x] drain effects overwrite shared `wDamage` with `max(floor(damage/2), 1)`, affecting later Counter/Bide (`Battle.Full.Effects.drain_halves_shared_damage`, `Battle.Full.Engine.counterDamage`)

## Nonvolatile status mechanics

| Mechanic | Required behavior | Status |
|---|---|---|
| Sleep | 1–7 rejection-sampled counter, existing-status rules, wake loses turn, recharge-clearing bypass | Discovered |
| Poison | type/status immunity, normal and side-effect rates | Discovered |
| Toxic | badly-poisoned flag and increasing counter | Discovered |
| Burn | type/status rules, Attack halving, residual | Discovered |
| Freeze | type/status rules, no ordinary thaw, Fire side-effect defrost paths and recharge asymmetry | Discovered |
| Paralysis | type/status rules, Speed quartering, `random < percent(25)` action failure (63/256) | Discovered |
| Item cures | branch-specific party/active synchronization, active stat-copy reset, and Toxic cleanup/persistence | Discovered |
| Haze cure/reset | both stages/stats, target nonvolatile status, selected-move cancellation, and exact volatile masks | Discovered |

## Volatile mechanics

- [x] stat stages 1–13 (`Battle.StatStages.wf`, `Battle.Full.Effects.raise_attack_999_two_stage_residue`, `lower_attack_1_two_stage_residue`)
- [x] exact stored decimal-style stage-ratio table and immediate flooring (`Battle.Rom.CombatTables.RequiredCombatBytes.statRatios`, `Battle.DamageStats.applyStage`)
- [x] [badge boost stacking matrix](stat-modifier-flow.md) outside link on player stat-up and enemy-on-player stat-down (`Battle.DamageStats.badge_progression`, `badge_screen_catastrophe`, `Battle.Full.Environment.level_up_reapplication_order_witness`)
- [x] stat-effect burn/paralysis reapplication: self stat-up penalizes opponent; stat-down penalizes target; unrelated-stat and badge stacking (`Battle.Full.Effects.reapplyStatusPenalties`, `applyBadges`, `raiseStage`, `lowerStage`)
- [x] equality-only current-stat rollback and 999/1 two-stage silent residue (`Battle.Full.Effects.raise_attack_999_two_stage_residue`, `lower_attack_1_two_stage_residue`)
- [x] extra non-link enemy direct stat-down `< 64` failure before accuracy/effect execution (`Battle.Full.Engine.executeMove` handler gate)
- [x] damaging enemy stat-down side effects use sequential `>= 64` then `< 85` draws, with one-versus-two-byte consumption (`Battle.Full.Effects.enemyStatDownSideDraws`, `enemy_stat_down_side_draw_boundaries`, `applyAfter`)
- [x] confusion 2–5 turns and 50% self-hit comparison (`Battle.Full.Effects.confusion_duration_boundaries`, `Battle.Full.Status.ordered_status_gate_witnesses`)
- [x] self-confusion 40-power typeless damage without crit/random/hit test (`Battle.Full.Engine.confusion_self_hit_is_typeless_fixed_protocol`, confusion branch of `attack`)
- [x] self-confusion clears every battle-status-1 bit except `CONFUSED` before common multi-turn cleanup (`Battle.Full.Status.confusion_self_hit_keeps_only_confused_status1`)
- [x] flinch rates and recharge clearing (`Battle.Full.Effects.flinch_thresholds_exact`, `applyAfter` flinch branch)
- [x] Mist/Guard Spec (`Battle.Full.Effects.applyBefore`, `Battle.Full.Items.canonical_item_effect_witnesses`)
- [x] Focus Energy/Dire Hit (`Battle.Critical.focus_energy_witness`, `Battle.Full.Items.canonical_item_effect_witnesses`)
- [x] Substitute HP and zero-HP-user behavior (`Battle.Rom.SubstituteRoutine.decoded_affordability_exact`)
- [x] Hyper Beam recharge and target-faint skip because effect is not always-happen (`Battle.Full.Effects.hyperBeam_faint_skips_recharge`)
- [x] Leech Seed and Toxic-counter interaction (`Battle.Full.Status.toxic_leech_seed_ticks_twice`)
- [x] Reflect (`Battle.Rom.ScreenRoutine.screens_exact`)
- [x] Light Screen (`Battle.Rom.ScreenRoutine.screens_exact`)
- [x] Transform player/enemy invulnerability-check asymmetry (`Battle.Rom.TransformRoutine.transform_invulnerability_exact`)
- [x] Transform species/types/catch/moves/DVs/current combat stats copy boundaries (`Battle.Full.Effects.transform_copy_boundaries`)
- [x] Transform preserves user HP/level/max HP and sets nonblank copied PP to 5 (`Battle.Full.Effects.transform_copy_boundaries`)
- [x] Transform copies unmodified stats/stat stages and target DVs (`Battle.Full.Effects.transform_copy_boundaries`)
- [x] Minimize state is a separate presentation-branch byte (`Battle.Volatile.minimized`, `Battle.Full.Effects.minimize_sets_only_separate_flag`)
- [x] elemental side-effect immunity when move type equals either target type, including Body Slam versus Normal (`Battle.Full.Effects.elementalSideEffectImmune`, `body_slam_normal_type_immunity`)
- [x] SleepEffect clears target recharge before accuracy/existing-status checks (`Battle.Full.Effects.sleep_always_clears_recharge`)
- [x] player freeze side effect clears enemy recharge; enemy freeze does not mirror it (`Battle.Full.Effects.freeze_recharge_asymmetry`)
- [x] Haze preserves Transform and raw status-3 high bits while clearing Toxic/screens and selected volatile flags (`Battle.Rom.HazeRoutine.cureVolatile_block_effect`, `Battle.Full.Effects.haze_status_target_only`)
- [x] Haze copies unmodified stats without reapplying retained burn/paralysis or badge modifiers (`Battle.Rom.HazeRoutine.resetStats_eight_exact`, `Battle.Rom.HazeRoutine.haze_reset_prefix_exact`)
- [x] Rest leaves `BADLY_POISONED` and Toxic counter state intact while writing fixed sleep 2 (`Battle.Full.Effects.rest_heal_preserves_toxic`)
- [x] stale Toxic after Rest/damaged Full Restore can affect later normal poison and seeded residual processing (`Battle.Full.Effects.rest_heal_preserves_toxic`, `Battle.Full.Items.damaged_full_restore_preserves_status3`, `Battle.Full.Status.toxic_leech_seed_ticks_twice`)
- [x] Conversion copies active target types through Substitute, skips ordinary hit testing, and fails on target invulnerability (`Battle.Full.Effects.conversion_copies_types`, `applyBefore`)
- [x] Explosion/Selfdestruct zero user HP/status and clear seeded state before later miss handling (`Battle.Full.Effects.explode_clears_user_before_miss_aftermath`)

## Move-effect dispatch coverage

Every effect ID, including unused slots, needs a table/data theorem. Every used effect needs routine and transition coverage. The exact phase memberships and pointer targets are recorded in [Effect dispatch](effect-dispatch.md).

| Effect family | Constants/moves | Status |
|---|---|---|
| No additional effect | `NO_ADDITIONAL_EFFECT` | Discovered |
| Poison side effects | `POISON_SIDE_EFFECT1`, `POISON_SIDE_EFFECT2`, `TWINEEDLE_EFFECT` | Discovered |
| Drain and Dream Eater | `DRAIN_HP_EFFECT`, `DREAM_EATER_EFFECT` | Discovered |
| Burn/freeze/paralysis side effects | regular and “2” variants | Discovered |
| Explosion/self-destruct | `EXPLODE_EFFECT` | Discovered |
| Mirror Move | `MIRROR_MOVE_EFFECT` | Discovered |
| Stat up 1 | Attack/Defense/Speed/Special/Accuracy/Evasion | Discovered |
| Stat up 2 | Attack/Defense/Speed/Special/Accuracy/Evasion | Discovered |
| Stat down 1 | Attack/Defense/Speed/Special/Accuracy/Evasion | Discovered |
| Stat down 2 | Attack/Defense/Speed/Special/Accuracy/Evasion | Discovered |
| Stat-down side effects | Attack/Defense/Speed/Special | Discovered |
| Pay Day | `PAY_DAY_EFFECT` | Discovered |
| Swift | `SWIFT_EFFECT` | Discovered |
| Conversion | `CONVERSION_EFFECT` | Discovered |
| Haze | `HAZE_EFFECT` | Discovered |
| Bide | `BIDE_EFFECT` | Discovered |
| Thrash/Petal Dance | `THRASH_PETAL_DANCE_EFFECT` | Discovered |
| Roar/Whirlwind/Teleport | `SWITCH_AND_TELEPORT_EFFECT` | Discovered |
| Two-to-five hits | `TWO_TO_FIVE_ATTACKS_EFFECT`, unused `$1E` | Discovered |
| Flinch | `FLINCH_SIDE_EFFECT1`, `FLINCH_SIDE_EFFECT2` | Discovered |
| Sleep | `SLEEP_EFFECT`, unused `$01` pointer behavior | Discovered |
| OHKO | `OHKO_EFFECT` | Discovered |
| Charge | `CHARGE_EFFECT`, `FLY_EFFECT` | Discovered |
| Super Fang | `SUPER_FANG_EFFECT` | Discovered |
| Fixed/special damage | Seismic Toss, Night Shade, SonicBoom, Dragon Rage, Psywave | Discovered |
| Trapping | `TRAPPING_EFFECT` | Discovered |
| Always twice | `ATTACK_TWICE_EFFECT` | Discovered |
| Jump Kick crash | `JUMP_KICK_EFFECT` | Discovered |
| Mist | `MIST_EFFECT` | Discovered |
| Focus Energy | `FOCUS_ENERGY_EFFECT` | Discovered |
| Recoil/Struggle | `RECOIL_EFFECT` | Discovered |
| Confusion | `CONFUSION_EFFECT`, `CONFUSION_SIDE_EFFECT` | Discovered |
| Heal/Rest | `HEAL_EFFECT` | Discovered |
| Transform | `TRANSFORM_EFFECT` | Discovered |
| Light Screen/Reflect | corresponding effect IDs | Discovered |
| Guaranteed poison/paralysis | `POISON_EFFECT`, `PARALYZE_EFFECT` | Discovered |
| Substitute | `SUBSTITUTE_EFFECT` | Discovered |
| Hyper Beam | `HYPER_BEAM_EFFECT` | Discovered |
| Rage | `RAGE_EFFECT` | Discovered |
| Mimic | `MIMIC_EFFECT` | Discovered |
| Metronome | `METRONOME_EFFECT` | Discovered |
| Leech Seed | `LEECH_SEED_EFFECT` | Discovered |
| Splash | `SPLASH_EFFECT` | Discovered |
| Disable | `DISABLE_EFFECT` | Discovered |
| Unused `$48`–`$4B`, `$4E` and other gaps | pointer/layout behavior | Discovered |

### Per-move requirement

- [x] all move IDs 1 through 165 decode from ROM (`Battle.Rom.Mechanics.data_exact`, `move_effects_indexed`, `move_routes_exact`)
- [x] each move's effect ID maps to covered high-level behavior (`Battle.Full.EffectPlan.canonical_moves_supported`, `Battle.Full.Effects.applyBefore_total`)
- [x] each listed exceptional move ID routes to a non-malformed dedicated mechanic (`Battle.Full.EffectPlan.exceptional_move_ids_supported`)
- [x] all Metronome eligibility/rejections are covered (`Battle.Full.Effects.metronomeAccepts`, `metronome_eligibility_boundaries`)
- [x] Mirror Move/Metronome move-record reloads and PP compensation are explicit (`Battle.Full.Engine.installGeneratedLoadedMove`, `incrementNestedPp`, `generated_move_retains_wrapper`)
- [x] transformed player Mirror Move/Metronome increments original party PP but transformed decrement skips it (`Battle.Full.Engine.transformed_nested_party_pp_increment`, `incrementNestedPp`)
- [x] enemy Mirror Move/Metronome PP increment despite ordinary enemy PP not decrementing (`Battle.Full.Engine.incrementNestedPp`, `enemy_pp_not_decremented`)
- [x] ordinary player Mimic choice versus enemy/link random Mimic is covered (`Battle.Full.Effects.applyBefore`, `Battle.Full.Engine.resumeMimic`)
- [x] Mimic replaces only active move ID and retains that slot's existing PP byte (`Battle.Full.Effects.mimic_replace_preserves_pp`)
- [x] direct Confusion blocks Substitute while Confusion's damaging side effect can pass through a surviving Substitute (`Battle.Full.Engine.substitute_mist_dream_gates`, `Battle.Full.Effects.applyAfter` confusion-side branch)
- [x] Disable hit/occupied checks, slot and duration draws, link/player PP checks, and raw PP-Up-bit candidate bug (`Battle.Full.Effects.disable`, `disable_pp_up_only_candidate`)
- [x] move animation IDs/tile timing are explicitly excluded from the high-level mechanics projection and remain machine-layer obligations (`Battle.Full.EffectPlan.animation_explicitly_excluded`)

Exceptional move-ID checks include at least Quick Attack, Counter, Metronome, Mirror Move, Struggle, Toxic, Fly, Dig, Teleport, Roar, Explosion, Selfdestruct, Minimize, Rest, Dream Eater, SonicBoom, Dragon Rage, Seismic Toss, Night Shade, Psywave, and Super Fang.

## Multi-turn and multi-hit behavior

- [x] Bide 2/3 turn selection and repeated accumulation of actual/shared damage, including Substitute cases (`Battle.Full.Effects.bide_thrash_lock_witnesses`, `Battle.Full.Engine.applyDamage`)
- [x] Bide release doubles/caps accumulated damage and misses when zero (`Battle.Full.Engine.bide_zero_misses`, `bide_release_doubles`, `bide_release_caps`)
- [x] Bide initialization clears both loaded move-effect bytes (`Battle.Full.Engine.bide_clears_both_loaded_effects`)
- [x] Thrash/Petal Dance 2/3 turn selection (`Battle.Full.Effects.bide_thrash_lock_witnesses`)
- [x] post-Thrash confusion duration 2–5 (`Battle.Full.Effects.confusion_duration_boundaries`, `Battle.Full.Engine.advanceMoveLock`)
- [x] charge first/second turn and first-turn omission from last-used-move scratch (`Battle.Full.Effects.charge_invulnerability_witnesses`, `Battle.Full.Engine.executeMove` charging branch preserves last-used scratch)
- [x] Fly/Dig invulnerability (`Battle.Full.Effects.charge_invulnerability_witnesses`)
- [x] directly selected charge-turn PP deferred until attack turn (`Battle.Full.Engine.charge_pp_is_deferred`)
- [x] charge state is unbound: Mirror Move/Metronome-generated charge continues with retained wrapper, generated loaded move, and original selected slot (`Battle.Full.Engine.generated_move_retains_wrapper`, `installGeneratedLoadedMove`)
- [x] nested wrapper PP versus disobedient replacement PP ordering (`Battle.Full.Engine.incrementNestedPp`, `transformed_nested_party_pp_increment`, `disobedience_charges_original_slot`)
- [x] full-paralysis/self-confusion/selected-disabled charge cleanup clears charging but leaves Fly/Dig invulnerability until volatile reset (`Battle.Full.Status.interrupted_charge_leaves_invulnerability`)
- [x] trapping continuation count chosen before accuracy, target recharge cleared before hit, and total-hit interpretation (`Battle.Full.Effects.multiHitCount`, `clear_target_recharge_exact`, `Battle.Full.Engine.advanceMoveLock`)
- [x] trapping hit reuse without new damage/accuracy roll (`Battle.Full.Engine.executeMove` continued-trap branch and locked damage)
- [x] trapping miss cleanup (`Battle.Full.Engine.clearTrappingLock`)
- [x] two-to-five hit distribution with one/two count draws before first-hit accuracy (`Battle.Full.Effects.multi_hit_count_witnesses`, `multi_hit_distribution_exact`)
- [x] fixed two-hit and Twineedle conversion, with poison roll after the final hit (`Battle.Full.Effects.applyBefore`, `applyAfter`)
- [x] first-hit-only damage/accuracy calculation (`Battle.Full.Engine.applyExtraHits` reuses resolved damage)
- [x] target faint interruption (`Battle.Full.Engine.applyExtraHits`)
- [x] hit count/event result (`Battle.Full.Effects.multiHitCount`, `Battle.Full.Engine.applyExtraHits`)

## Switching, fainting, and battle end

Exact transitions are catalogued in [Switch, faint, and participation flow](switch-faint-and-participation.md).

- [x] voluntary player switch (`Battle.Full.Engine.applySwitch`, `Battle.Full.SideState.switch_success_shape`)
- [x] enemy trainer switch (`Battle.Full.Engine.applySwitch`, `forced_enemy_switch_resets_ai_layer`)
- [x] link remote switch (`Battle.Full.Link.decodeAction`, `Battle.Full.Engine.executeCommitted`)
- [x] outgoing active-to-party HP/status copy (`Battle.Full.syncOutgoing_reads_active`)
- [x] contiguous HP/party-position/status copy overwrites party `MON_BOX_LEVEL`, especially enemy AI switch (`Battle.Full.syncOutgoing_reads_active`)
- [x] segmented incoming party-to-active codec (`Battle.Full.SideState.loadIncoming`, `switch_success_shape`)
- [x] burn/paralysis before non-link badges on player send-out (`Battle.Full.wild_send_out_applies_badge_after_status`, `Battle.Full.Engine.applySwitch`)
- [x] all eight `NUM_STAT_MODS` bytes reset to 7, including the two skipped/padding bytes (correcting the earlier stale-padding assumption; `Battle.StatStages.neutral_resets_all_eight_bytes`)
- [x] exact partial send-out reset: volatile flags/Disable cleared, counters stale, selected/loaded scratch split (`Battle.Full.send_out_reset_preserves_stale_counters`, `Battle.Full.Engine.send_out_clears_move_but_retains_record`)
- [x] trapping and switch restrictions (`Battle.Full.Action.legal` post-menu branch, `forced_switch_exact`)
- [x] player faint clears active/party nonvolatile status but retains own volatile block until replacement/cleanup (`Battle.Full.Engine.clearPlayerFaintStatus`, `player_faint_clears_party_status`)
- [x] enemy faint clears enemy volatile flags and party HP but retains enemy party nonvolatile status (`Battle.Full.Engine.recordEnemyFaintSide`, `enemy_faint_retains_party_status`)
- [x] Bide accumulator asymmetric clear (`Battle.Full.Engine.bide_faint_clear_is_asymmetric`)
- [x] faint clears gain bit but preserves fought bit; Revive/Max Revive conditionally restores gain eligibility (`Battle.Full.Environment.faint_preserves_fought_flags`, `revive_restores_fought_recipient`)
- [x] forced replacement (`Battle.Full.Action.forced_switch_exact`, `Battle.Full.Engine.applySwitch`)
- [x] trainer next Pokémon uses deterministic lowest-index other living slot with no destination draw (`Battle.Full.SideState.firstSwitch_lowest`, `firstSwitch_sound`)
- [x] non-link enemy send-out scan has no explicit count bound; link received index is unchecked after subtracting 4 (`Battle.Full.Initialization.firstLivingStep`, `Battle.Full.EndFlow.uncheckedRemoteSwitchIndex`, `malformed_remote_switch_wraps`)
- [x] Shift/Set option polarity and party-count-exactly-1 suppression (`Battle.Full.EndFlow.shouldOfferShift`, `shift_prompt_boundaries`)
- [x] Shift participation reset makes incoming member sole participant against new enemy (`Battle.Full.EndFlow.resetParticipationForEnemy`, `shift_participation_is_active_only`)
- [x] shift response rejects active/fainted targets and can switch before send-out (`Battle.Full.EndFlow.resolveShift`, `active_shift_target_retries`)
- [x] AI switch suppresses the player's shift prompt and applies the subsequent enemy residual to the incoming member (`Battle.Full.EndFlow.shift_prompt_boundaries`, switch-before-`executePair` ordering in `Battle.Full.Engine.step`)
- [x] wild battle victory (`Battle.Full.Engine.faint_terminal_channels`, with mode retained by `terminalFor`)
- [x] trainer victory (`Battle.Full.Engine.faint_terminal_channels`, trainer payout branch in `recordFaint`)
- [x] player blackout/loss (`Battle.Full.Engine.faint_terminal_channels`)
- [x] link win/loss/run result (`Battle.Full.Engine.faint_terminal_channels`, link-run branches of `step`)
- [x] [terminal control-path witness](battle-outcomes.md) before cleanup; no final-memory-only outcome decoder (`Battle.Outcome.EpisodePhase.ending`, `Battle.Full.Engine.Event.terminal`)
- [x] `EndOfBattle` erasure of escape/mode/opponent fields while preserving raw result (`Battle.Outcome.cleanup_preserves_result_and_erases_context`)
- [x] recoil/simultaneous-KO ordering (`Battle.Full.Engine.recordSimultaneousFaint`; defender is recorded first and the second replacement is queued)
- [x] trainer BCD prize payout (`Battle.Full.Money.trainerPrize`, `trainer_prize_witness`, `Battle.Full.Engine.recordFaint`)
- [x] `PrintEndBattleText` flag/name/dynamic-text/sprite control and raw-result lose-text selection during simultaneous-faint victory (`Battle.Full.EndFlow.endTextPlan`, `simultaneous_raw_loss_selects_lose_text`)
- [x] Pay Day payout guarded exactly by `wBattleResult == 0` (`Battle.Full.Money.nonzero_result_skips_epilogue`, `zero_result_adds_pay_day`)
- [x] post-battle evolution before cleanup while phase remains `ending` (`Battle.Full.Environment.evolution?`, `settleEnding`)
- [x] low-health alarm/audio state is explicitly excluded from the high-level mechanics projection (`Battle.Full.EndFlow.low_health_alarm_explicitly_excluded`)
- [x] HP-derived recall-text arithmetic, healed-enemy underflow, quotient low byte, and raw zero-divisor divergence (`Battle.Full.Recall.select`; presentation timing remains in the system checklist)

## Run and escape

- [x] Ghost and Safari unconditional escape cases (`Battle.Full.Escape.ghost_escapes`, `safari_escapes`)
- [x] link run exchange (`Battle.Full.Link.encodeAction`/`decodeAction`, link-run branches of `Battle.Full.Engine.step`)
- [x] trainer “no running” behavior (`Battle.Full.Escape.trainer_prohibited`)
- [x] player Speed greater than or equal to enemy Speed succeeds (`Battle.Full.Escape.player_not_slower_escapes`)
- [x] speed formula and enemy-speed division/truncation (`Battle.Full.Escape.attempt`)
- [x] attempt count and byte-loop `30 × (attempts - 1)` increments, including raw counter wrap (`Battle.Full.Escape.attempt_counter_wrap_witness`)
- [x] Fight selection resets attempt count, including canceled Fight (`Battle.Full.Selection.openFight_resets_attempts`, `cancel_preserves`)
- [x] inclusive escape comparison (`random <= quotientWithBonuses`) (`Battle.Full.Escape.inclusive_witness`)
- [x] failed wild attempt consumes turn (`Battle.Full.Escape.failed_attempt_witness`, `Battle.Full.Environment.resolveRun`)
- [x] prohibited trainer attempt returns to selection without consuming turn (`Battle.Full.Environment.resolveRun`)
- [x] divisor is `(enemySpeed / 4) mod 256`; zero succeeds immediately (`Battle.Full.Escape.zero_divisor_witness`)
- [x] quotient high byte/carry success paths (`Battle.Full.Escape.attempt`)
- [x] move-based wild escape by Teleport/Roar/Whirlwind (`Battle.Full.Effects.applyBefore` `.switchOrTeleport`, `Battle.Full.Engine` move-escape terminal)
- [x] automatic success at user level ≥ target level; otherwise level-sum rejection loop and target-level/4 comparison (`Battle.Full.Effects.escapeLevelBound`, `escapeLevelSucceeds`, `escape_level_boundaries`)
- [x] trainer-battle Teleport failure versus Roar/Whirlwind unaffected text/control paths (`Battle.Full.Effects.escapeFailureText`, `teleport_roar_failure_texts`)
- [x] Poke Doll/move escape `wEscapedFromBattle` versus ordinary-run `wBattleResult` writes (`Battle.Outcome.escape_byte_channels_exact`)
- [x] raw result-code implications for EndOfBattle Pay Day/evolution guard (`Battle.Outcome.escape_byte_channels_exact`, `Battle.Full.Money.zero_result_adds_pay_day`, `nonzero_result_skips_epilogue`)
- [x] successful move escape synchronizes active player HP/status to party before setting escape (`Battle.Full.Engine` escaped-signal branch calls `Full.SideState.syncOutgoing` before terminal construction)
- [x] Poke Doll/move escape leave result zero unlike ordinary Run (`Battle.Outcome.escape_byte_channels_exact`); Pay Day/evolution control-flow composition remains open
- [x] level-based rejection sampling preserves every rejected byte (`Battle.Full.Effects.drawAccepted`, `.switchOrTeleport` branch, `escapeLevelBound`)
- [x] post-faint run response always uses stored party slot 1 Speed, excluding active paralysis/stage/badge changes (`Battle.Full.Environment.wildFaintRunSpeed`)

## Battle items

The exact 83-entry source disposition is in [Item dispatch](item-dispatch.md); proof coverage must retain every row and malformed index domain.

- [x] Master/Ultra/Great/Poké/Safari Ball (`Battle.Full.Items.canonical_ball_dispatch_witnesses`, `Battle.Full.Capture.canonical_ball_ids`)
- [x] status-specific cures (`Battle.Full.Items.medicine_family_witnesses`)
- [x] Full Heal (`Battle.Full.Items.canonical_item_effect_witnesses`)
- [x] Full Restore (`Battle.Full.Items.canonical_item_effect_witnesses`, `damaged_full_restore_preserves_status3`, `full_hp_full_restore_clears_toxic`)
- [x] Max/Hyper/Super/Potion (`Battle.Full.Items.medicine_family_witnesses`)
- [x] Fresh Water/Soda Pop/Lemonade (`Battle.Full.Items.medicine_family_witnesses`)
- [x] Revive/Max Revive (`Battle.Full.Items.canonical_item_effect_witnesses`)
- [x] X Accuracy (`Battle.Full.Items.canonical_item_effect_witnesses`, `repeated_flags_and_x_stat_cap`)
- [x] Guard Spec (`Battle.Full.Items.canonical_item_effect_witnesses`)
- [x] Dire Hit (`Battle.Full.Items.canonical_item_effect_witnesses`)
- [x] X Attack/Defend/Speed/Special (`Battle.Full.Items.x_stat_family_witnesses`, `repeated_flags_and_x_stat_cap`)
- [x] Poke Doll (`Battle.Full.Items.canonical_item_effect_witnesses`, `Battle.Outcome.escape_byte_channels_exact`)
- [x] Poke Flute (`Battle.Full.Items.flute_preserves_bag`, `flute_always_wakes_active`)
- [x] Ether/Max Ether/Elixer/Max Elixer are battle-reachable, including party/move targeting (`Battle.Full.Items.pp_restore_family_witnesses`)
- [x] Max Ether/Max Elixer PP-Up-bit no-effect detection bug (`Battle.Full.Items.max_restore_packed_comparison_bug`)
- [x] PP Up is rejected during battle (`Battle.Full.Items.pp_up_rejected_in_battle`)
- [x] invalid/key/overworld-only item behavior while in battle (`Battle.Full.Items.disposition`, `ordinary_table_total`)
- [x] inventory quantity removal and ordered bag representation (`Battle.Full.Items.ordered_bag_removal_witness`)
- [x] trainer-ball rejection occurs after ball removal/action commit (`Battle.Full.Items.canonical_ball_dispatch_witnesses`, `Battle.Full.Capture.trainer_rejected_before_capture`)
- [x] party count exactly 6 plus box count exactly 20 rejects a ball before removal/turn commitment (`Battle.Full.Environment.full_storage_ball_is_precommit_rejection`)
- [x] raw party counts 7–254 successful-capture-without-storage path and 255 wrap (`Battle.Full.Capture.capacity_guard_exact`, `Battle.Full.CaptureProtocol.malformed_party_count_destinations`)
- [x] raw box counts 21–255 oversized/wrapped slot-shift behavior (`Battle.Full.CaptureProtocol.raw_box_count_destinations`, `box_slot_one_exact`)
- [x] unidentified Ghost/Marowak rejection occurs after throw and consumes the ball (`Battle.Full.Capture.ghost_rejected_after_throw`, `Battle.Full.Items.canonical_ball_dispatch_witnesses`)
- [x] Poke Flute legal-party player/trainer-party scans, both active wake scope, no consumption, and committed turn (`Battle.Full.Items.wakeSideForFlute`, `wakeOpponentForFlute`, `flute_preserves_bag`, `flute_always_wakes_active`)
- [x] Poke Flute raw six-fixed-slot malformed scans beyond represented party arrays (`Battle.Full.Items.fluteRawSixSlotScan`, `flute_raw_scan_observes_sixth_slot`)
- [x] Poke Flute `wWereAnyMonsAsleep` derives only from party scans, including sleeping-wild-active message mismatch (`Battle.Full.Items.wild_flute_report_ignores_enemy`, `trainer_flute_report_scans_both`, `wild_flute_wakes_opponent_active_only`)
- [x] repeated X Accuracy/Guard Spec/Dire Hit and capped X-stat behavior (`Battle.Full.Items.repeated_flags_and_x_stat_cap`)
- [x] Revive participation-to-EXP-flag side effect (`Battle.Full.Environment.revive_restores_fought_recipient`, `applyProgressionEvents`)
- [x] active/party synchronization after item (`Battle.Full.Items.active_cure_reloads_party_stats_witness`)
- [x] active status cure copies party max HP/all combat stats without reapplying stages, badges, burn, or paralysis (`Battle.Full.Items.active_cure_reloads_party_stats_witness`); the normally inert helper call remains a ROM-routine obligation
- [x] trainer AI status cures clear status/Toxic bytes without restoring burn/paralysis-reduced combat stats (`Battle.Full.Items.trainer_cure_retains_combat_stats`, `trainer_full_restore_clears_toxic`)
- [x] Full Restore damaged-active path versus full-HP status-cure path, including Toxic flag handling (`Battle.Full.Items.damaged_full_restore_preserves_status3`, `full_hp_full_restore_clears_toxic`)
- [x] item use during trapping is selectable but blocked before item mutation; trapping continuation advances on its actor (`Battle.Full.Engine.step`, `executeCommitted`, `advanceMoveLock`)
- [x] items forbidden by the link battle menu before dispatch (`Battle.Full.Items.link_bag_rejected`, `Battle.Full.Link.items_have_no_link_encoding`)
- [x] raw-bag `POKEDEX` action-success path and unobtainable `SURFBOARD`/badge-alias classification (`Battle.Full.Items.rawDispatch`, `raw_dispatch_special_paths`); UI/device execution remains open
- [x] vitamins, Rare Candy, evolution stones, PP Up, and TM/HM battle rejection (`Battle.Full.Items.progression_items_rejected_in_battle`)
- [x] IDs `$54`–`$C3` classify beyond `ItemUsePtrTable` (`Battle.Full.Items.out_of_range_54`); canonical-bag validation versus raw CPU control flow remains a system obligation

## Capture

- [x] battle/trainer/box-capacity preconditions (`Battle.Full.Capture.attempt`, `capacity_guard_exact`)
- [x] eligible Master Ball unconditional success after still consuming the first `Random` result (`Battle.Full.Capture.master_consumes_rand1`)
- [x] Ghost/Marowak restrictions (`Battle.Full.Capture.ghost_rejected_after_throw`)
- [x] ball-specific inclusive first-byte rejection ranges (255/200/150) (`Battle.Full.Capture.rand1_boundaries`)
- [x] status subtraction and immediate success (`Battle.Full.Capture.capture_inclusive_comparison_witnesses`)
- [x] `MaxHP × 255` arithmetic (`Battle.Full.Capture.catchWindow`, `capture_arithmetic_witnesses`)
- [x] ball factors (`Battle.Full.Capture.ballFactor`, `ballFactor2`, `capture_arithmetic_witnesses`)
- [x] current HP divided by four with minimum one (`Battle.Full.Capture.hpQuarterDivisor`, `capture_arithmetic_witnesses`)
- [x] inclusive catch-rate comparison (`Rand1 - Status <= CatchRate`) (`Battle.Full.Capture.capture_inclusive_comparison_witnesses`)
- [x] inclusive second comparison (`Rand2 <= X`) (`Battle.Full.Capture.capture_inclusive_comparison_witnesses`)
- [x] failure shake-count arithmetic (`Battle.Full.Capture.shakeCount`, `capture_arithmetic_witnesses`)
- [x] status shake bonus (`Battle.Full.Capture.statusBonus2`, `capture_arithmetic_witnesses`)
- [x] transformed capture forces Ditto, including non-Ditto wild Transform acquired through Mirror Move (`Battle.Full.Capture.transformed_stores_ditto`)
- [x] preserve DVs/HP/status while rebuilding base types/catch rate/moves (`Battle.Full.CaptureProtocol.construct_preserves_wild_identity`)
- [x] captured OT ID, experience, zero stat EXP, level, and calculated stats (`Battle.Full.CaptureProtocol.construct`, `construct_preserves_wild_identity`)
- [x] capture naming request before action return: decline/custom/empty-name default and timing (`Battle.Full.CaptureProtocol.Pending`, `NameResponse`, `preStore`, `finishName`)
- [x] party capture appends; box capture inserts at slot 1 and shifts species/records/OT/nickname arrays (`Battle.Full.CaptureProtocol.box_slot_one_exact`, `box_parallel_sizes`)
- [x] pre-name owned/partial party-or-box state and post-name record construction order (`Battle.Full.CaptureProtocol.pre_name_partial_storage_exact`, `preStore`, `finishName`); ordinary/Safari resource timing is covered at their separate action boundaries
- [x] captured-species owned flag before naming (`Battle.Full.CaptureProtocol.pre_name_partial_storage_exact`); ordinary encounter seen-flag mutation remains an initialization obligation
- [x] exact party append versus current-box slot-1 insertion with parallel-array ordering (`Battle.Full.CaptureProtocol.box_slot_one_exact`, `box_parallel_sizes`)
- [x] ordinary/Safari/Old Man ball removal and capture-naming distinctions (Old Man skips naming/storage) (`Battle.Full.CaptureProtocol.tutorial_skips_storage_and_naming`)
- [x] Old Man menu saves player name into aliased `wGrassRate`/wild buffer, writes `OLD MAN`, and ball path restores only player name (`Battle.Full.OldMan.capture_restores_name_but_retains_alias`)
- [x] capture battle-result mutation (`Battle.Full.Environment.resolve_capture_name_sets_result`)

## Trainer AI

### Move choice

- [x] initialize four scores (`Battle.Full.TrainerController.score_initialization_exact`)
- [x] discourage disabled move (`Battle.Full.TrainerController.layer_scoring_witnesses`)
- [x] layer 1 redundant-status scoring (`Battle.Full.TrainerController.layer_scoring_witnesses`)
- [x] layer 2 exact numeric effect intervals and `== 1` gate lifecycle across execution, status locks, AI actions, forced replacement, and voluntary switch (`Battle.Full.TrainerController.layer_scoring_witnesses`, `Battle.Full.Engine.beginEnemyExecution_increments`, `forced_enemy_switch_resets_ai_layer`, `voluntary_enemy_switch_retains_ai_layer`)
- [x] all layer scans stop at first zero move ID (`Battle.Full.TrainerController.score_scan_stops_at_first_zero`)
- [x] layer 3 type-effectiveness scoring, including first matching defender type only (`ai_first_matching_defender_type`, `ScoreInput.fromBattle`)
- [x] AI effectiveness `$10` initialization bug (`Battle.Full.TrainerController.ai_neutral_constant_mismatch`)
- [x] minimum-score filtering algorithm and malformed leading-zero divergence (`Battle.Full.TrainerController.feedMove`, `minimumCandidateScore`, `all_blank_move_selection_diverges`)
- [x] exact 63/64/63/66 byte slot buckets and rejection among nonzero candidate slots (`slot_bucket_cardinalities`, `SelectsMove`)
- [x] blank and disabled retry (`Battle.Full.TrainerController.SelectsMove.reject`, `feedMove`)
- [x] unlimited enemy PP behavior (`Battle.Full.Engine.enemy_pp_not_decremented`)

### Action AI

- [x] per-Pokémon action count initialization and successful-action decrement/reset behavior (`Battle.Full.TrainerController.stepAction`, `lazy_action_count_initializes_and_decrements`)
- [x] direct `Random` consumed before Generic/no-op and failed-threshold routines while count is nonzero (`Battle.Full.TrainerController.stepAction`, `generic_consumes_random_without_decrement`, `action_routine_witnesses`)
- [x] generic no-op leaves count unchanged and therefore continues drawing on later actions (`Battle.Full.TrainerController.generic_consumes_random_without_decrement`)
- [x] Juggler switch (`Battle.Full.TrainerController.action_routine_witnesses`)
- [x] Blackbelt/Cooltrainer/Koga X Attack (`Battle.Full.TrainerController.action_routine_witnesses`)
- [x] Giovanni Guard Spec (`Battle.Full.TrainerController.action_routine_witnesses`)
- [x] Misty/Bruno X Defend (`Battle.Full.TrainerController.action_routine_witnesses`)
- [x] Lt. Surge X Speed (`Battle.Full.TrainerController.action_routine_witnesses`)
- [x] Brock Full Heal (`Battle.Full.TrainerController.action_routine_witnesses`)
- [x] Erika/Lorelei Super Potion thresholds (`Battle.Full.TrainerController.action_routine_witnesses`)
- [x] Blaine unconditional selected Super Potion bug (`Battle.BugWitnesses.blaine_full_hp_bug_occurs`)
- [x] Sabrina/Lance Hyper Potion thresholds (`Battle.Full.TrainerController.action_routine_witnesses`)
- [x] Rival Potion/Full Restore thresholds (`Battle.Full.TrainerController.action_routine_witnesses`)
- [x] Agatha switch/heal branches (`Battle.Full.TrainerController.action_routine_witnesses`)
- [x] Cooltrainer F missing-return behavior (`cooltrainerF_random_dead`, `cooltrainer_random_gate_bug_occurs`)
- [x] strict current-HP-below-`floor(maxHP / divisor)` threshold (`Battle.TrainerAI.hpBelowFraction`, `Battle.Full.TrainerController.action_routine_witnesses`)
- [x] heal cap (`Battle.TrainerAI.recover_full_hp`); HP-bar presentation scratch writes remain a system obligation
- [x] status/Toxic cleanup without recalculating burn/paralysis-reduced enemy combat stats (`trainer_cure_retains_combat_stats`, `trainer_full_restore_clears_toxic`)
- [x] enemy switch living-count rule and deterministic lowest-index other-living send-out scan, with no destination RNG and raw unbounded search (`Battle.Full.SideState.firstLegalSwitch_exact`, `replacementScanStep`, `replacement_scan_deterministic`)
- [x] all [47 class dispatch rows](trainer-ai-dispatch.md), direct `Random` source, and exact `percent`-macro thresholds (`Battle.Full.TrainerController.class_table_total`, `action_routine_witnesses`, `stepAction`)
- [x] `wAICount = $ff` lazy class-count initialization per send-out (`Battle.Full.TrainerController.lazy_action_count_initializes_and_decrements`)

## Experience, payout, and post-battle progression

- [x] no EXP in links (`Battle.Full.Environment.finishBattle` link branch)
- [x] participation recipient count, fainted gain-bit clearing, fought-bit retention, Revive restoration, and fainted-recipient skip (`Battle.Full.Engine.player_faint_clears_party_status`, `faint_preserves_fought_flags`, `Battle.Full.Items.revive_restores_fought_recipient`, `Battle.Full.Environment.fainted_recipient_skipped`)
- [x] per-recipient division of base stats/catch/base EXP (`Battle.Full.Progression.divide_source_all_fields`)
- [x] stat EXP addition and saturation (`Battle.Full.Progression.award`, `stat_exp_saturates`)
- [x] base EXP × level / 7 (`Battle.Full.Progression.experienceAward`)
- [x] traded 1.5× boost (`Battle.Full.Progression.experienceAward`, `sequential_traded_trainer_boosts`)
- [x] trainer-battle 1.5× boost and sequential intermediate flooring with traded boost (`Battle.Full.Progression.sequential_traded_trainer_boosts`)
- [x] EXP addition and level-100 cap (`Battle.Full.Progression.award_experience_capped`)
- [x] level calculation from growth formula (`Battle.Full.Progression.levelFromExperience`, `growth_level_100_roundtrip`)
- [x] multi-level gain behavior and exact-level-only move scan (`Battle.Full.Progression.award`, `first_exact_level_move_witness`)
- [x] stat recalculation and current-HP increase (`Battle.Full.Progression.calculateStats`, `award_hp_delta`)
- [x] active member update (`Battle.Full.Environment.reapplyLevelUpActive`, `level_up_preserves_copied_identity`)
- [x] stage/status/badge reapplication in source order with link bypass (`Battle.Full.Environment.level_up_reapplication_order_witness`)
- [x] level-up nested move-learning request, automatic empty slot, HM deletion rejection, and abandon-confirmation loop (`Battle.Full.Learning.empty_slot_learns_immediately`, `hm_rejection_reprompts`, `abandon_decline_restarts`)
- [x] only first exact-level learnset row is considered; skipped intermediate levels and raw duplicate-level rows are ignored (`Battle.Full.Progression.first_exact_level_move_witness`)
- [x] active transformed learner receives party moves/PP while transformed identity/volatile state remain (`Battle.Full.Environment.transformed_learning_preserves_active_identity`)
- [x] `wCanEvolveFlags` set for leveled recipients (`Battle.Full.Environment.gained_level_sets_evolution_flag`)
- [x] EXP All halves all seven source bytes; participant award may divide it in place before all-party award divides the already-mutated bytes again (`Battle.Full.Environment.exp_all_destructive_double_division`)
- [x] EXP divisor counts all eight gain-flag bits while recipient iteration uses party count and skips fainted members; EXP All in-count fainted bits reduce living shares (`Battle.Full.Environment.all_eight_gain_bits_count`, `exp_all_counts_full_party`, `fainted_recipient_skipped`)
- [x] trainer prize is base-money BCD multiplied once by final enemy level (`Battle.Full.Money.trainerPrize`, `trainer_prize_witness`)
- [x] Pay Day per-use `2 × userLevel` BCD accumulation (`Battle.Full.Money.payday_accumulates_twice_level`)
- [x] Pay Day payout only when `wBattleResult == 0`, including Poke Doll/move/Safari zero-result exits (`Battle.Full.Money.zero_result_adds_payday_and_runs_evolution`, `nonzero_result_skips_payday_and_evolution`, `Battle.Outcome.escape_byte_channels_exact`)
- [x] `EndOfBattle` evolution guard (`wBattleResult == 0` for non-link; link branch reaches it directly) (`Battle.Full.Money.link_epilogue_runs_evolution`, `zero_result_adds_payday_and_runs_evolution`, `nonzero_result_skips_payday_and_evolution`)
- [x] `EvolutionAfterBattle` is constructed before `settle` clears battle state (`Battle.Full.Environment.evolution?`, `settle`)
- [x] evolution eligibility by flag and level/item/trade record scan (`Battle.Full.Progression.evolutionTarget?`, `Battle.Full.Evolution.start`)
- [x] evolution cancel response and continuation to next party member (`Battle.Full.Evolution.cancellation_advances_to_next_flagged_member`)
- [x] evolution species, retained nickname, owned flag, stats, HP delta, types, and exact-level learned move (`Battle.Full.Progression.evolve`, `evolve_preserves_identity_and_moves`, `Battle.Full.Evolution.acceptance_commits_target`, `Battle.Full.Environment.evolution_install_preserves_names`, `evolution_owned_witness`)
- [x] wild-battle item-evolution bug through aliased `wCurItem`/species state (`Battle.Full.Evolution.wild_item_alias_offers`, `wild_item_evolution_bug_occurs`)
- [x] link/no-EXP evolution behavior (`Battle.Full.Evolution.start`, `Battle.Full.Environment.finishBattle`)
- [x] witnessed pre-cleanup terminal checkpoint and separately composed battle cleanup/return checkpoint (`Battle.Full.OuterFlow.terminal_cleanup_return_are_separate`; ROM execution remains an end-to-end obligation)
- [x] inside-driver exit handoff: encounter-cooldown set, destination warp `$FF`, and loss-path always-on-bike clear (`Battle.Full.OuterFlow.cleanupCheckpoint`)
- [x] outer return restores letter-delay flags, map-palette offset, tile-animation state, bank/stack frame, and carry before creating returned outcome (`Battle.Full.OuterFlow.outer_return_restores_frame`)
- [x] post-return blackout, trainer-map flags, cable `HealParty`, and tutorial cleanup are separately typed caller continuations (`Battle.Full.OuterFlow.caller_continuations_are_post_return`)
- [x] blackout money halving/heal explicitly excluded as later overworld transition (`Battle.Full.OuterFlow.blackout_is_later_overworld_transition`)

## Safari

- [x] Safari Ball count and out-of-balls check before duration text/escape roll after each successful action (`Battle.Full.Safari.last_ball_reaches_capture`, `failed_last_ball_exhausts`)
- [x] bait halves catch rate (`Battle.Full.Safari.bait_rock_catch_witness`)
- [x] rock doubles catch rate/caps as implemented (`Battle.Full.Safari.bait_rock_catch_witness`)
- [x] bait/rock rejection-sampled 1–5 factor increments with saturation (`Battle.Full.Safari.factor_acceptance_exact`, `applyBaitRock`)
- [x] each action zeros the opposite factor (`Battle.Full.Safari.applyBaitRock`)
- [x] duration decrement order (`Battle.Full.Safari.tickFactors`)
- [x] bait expiry does not restore catch rate (`Battle.Full.Safari.bait_expiry_retains_catch_rate`)
- [x] rock/escape-factor expiry restores species base catch rate (`Battle.Full.Safari.rock_expiry_restores_catch_rate`)
- [x] repeated bait/rock compounding of current actual catch rate (`Battle.Full.Safari.applyBaitRock`)
- [x] speed-low-byte doubling and pre-factor carry escape (`Battle.Full.Safari.escapeThreshold`, `high_speed_runs`)
- [x] speed-derived escape threshold (`Battle.Full.Safari.escape_threshold_witnesses`)
- [x] bait divides threshold by four (`Battle.Full.Safari.escape_threshold_witnesses`)
- [x] rock doubles threshold and caps (`Battle.Full.Safari.escape_threshold_witnesses`)
- [x] direct ordinary random comparison with strict boundary (`Battle.Full.Safari.escape_threshold_witnesses`)
- [x] out-of-balls result (`Battle.Full.Safari.failed_last_ball_exhausts`)

## Link battle

- [x] party exchange representation keeps authoritative local and disposable remote payloads separate (`Battle.Full.Link.PartyExchange`)
- [x] link action values for move/switch/no-action/Struggle/run (`Battle.Full.Link.encodeAction`, `decodeAction`, `action_roundtrip`)
- [x] internally/external-clock role (`Battle.Full.Link.ClockRole`)
- [x] equal-Speed inversion (`Battle.Full.Link.equal_speed_roles_agree_on_physical_first`)
- [x] two post-setup ten-byte blocks plus each perspective's first-nine active seeds and index (`Battle.Full.Link.RngHandshake`, `handshake_uses_first_nine_and_index`)
- [x] internal-clock alias versus external-clock scan/copy and legitimate-leading-zero mismatch (`Battle.Full.Link.internalSetupList`, `externalSetupList`, `leading_zero_setup_mismatch`)
- [x] per-perspective `seed := 5 × seed + 1` update (`Battle.Rng.regenStep`, `regenerate`)
- [x] conditional equal-list/equal-index invariant and explicit paired-state desynchronization (`Battle.Full.Link.mirroredRng`, `StepResult`)
- [x] no trainer AI (`Battle.Full.Engine.step` link action pairing bypasses `TrainerController`)
- [x] no item use and no link move-menu cancel/reordering (`Battle.Full.Link.items_have_no_link_encoding`, `action_roundtrip`)
- [x] no EXP (`Battle.Full.Environment.finishBattle` link branch)
- [x] remote switch behavior (`Battle.Full.Link.encodeAction`, `step`)
- [x] link Mimic uses random target selection rather than the ordinary-player menu (`Battle.Full.Effects.applyBefore` Mimic branch)
- [x] win/loss/draw result-code interpretation (`Battle.Outcome.raw_result_interpretation_exact`)
- [x] paired cartridge-perspective code-path relation is enforced before synchronized classification (`Battle.Full.Link.classifyPairedResult`, `synchronized_preserves_relations`)
- [x] link `EndOfBattle` copies mirrored active-enemy status to party but not HP; authoritative local party remains separate (`Battle.Full.Link.copyRemoteStatusOnly`, `remote_cleanup_preserves_party_hp`)
- [x] battle-driver return precedes cable club's unconditional `HealParty` (`Battle.Full.OuterFlow.cable_heal_requires_return`)
- [x] known Psywave desync (`Battle.LinkBugs.psywave_link_desync`, `psywave_link_desync_exists`)
- [x] known Bide-clear desync (`Battle.LinkBugs.bide_desync_iff`, `bide_300_desync`)
- [x] Mirror Move/Metronome trapping desync warning (`Battle.Full.Link.DesyncCause.generatedTrappingWrapper`, `knownCause`)
- [x] paired terminal-cause/verdict agreement when no desync occurs (`Battle.Full.Link.terminalsAgree`, `phasesAgree`, `synchronized_preserves_relations`)
- [x] explicit divergence relation when cartridge sides desynchronize (`Battle.Full.Link.StepResult.desynchronized`)

## Known behavior regressions

Each item needs at least one source-linked test; mechanics-affecting items need a theorem or fall out of a broader refinement theorem.

- [x] Focus Energy right shift (`Battle.BugWitnesses.focus_energy_occurs`)
- [x] [exact percent-macro thresholds](probability-thresholds.md), comparison polarities, and boundary bytes
- [x] Fly/Dig attack-turn self-confusion/full paralysis/Disable clears charging but leaves invulnerability (`Battle.Full.Status.interrupted_charge_leaves_invulnerability`)
- [x] generated charge reloads selected wrapper/original move rather than retaining generated move identity (`Battle.Full.Engine.generated_charge_reloads_wrapper`)
- [x] threshold equality failure in accuracy/critical checks (`accuracy_boundary_occurs`, `critical_boundary_occurs`)
- [x] Toxic + Leech Seed counter interaction (`Battle.Full.Status.toxic_leech_seed_ticks_twice`)
- [x] player/enemy Psywave zero asymmetry (`Battle.BugWitnesses.psywave_link_desync_occurs`)
- [x] Bide high-byte-only clear (`Battle.BugWitnesses.bide_link_desync_occurs`)
- [x] Substitute can leave user at zero HP (`Battle.BugWitnesses.decoded_substitute_zero_user_hp_occurs`)
- [x] a Substitute survives incoming damage exactly equal to its remaining HP (`Battle.BugWitnesses.substitute_exact_damage_survival_occurs`)
- [x] Transform invulnerability-check bugs (`Battle.Rom.TransformRoutine.transform_invulnerability_exact`)
- [x] Swift before invulnerability check (`Battle.Full.Engine.swift_precedes_accuracy_gates`)
- [x] drain-on-Substitute broken check (`Battle.Full.Effects.drain_ignores_substitute_gate`)
- [x] extra enemy stat-down failure gate also reducing damaging side effects through a second independent draw
- [x] AI effectiveness neutral constant mismatch (`Battle.Full.TrainerController.ai_neutral_constant_mismatch`)
- [x] Reflect/Light Screen overflow and zero divisor (`Battle.BugWitnesses.screen_overflow_occurs`)
- [x] badge boost stacking with screen catastrophe (`Battle.BugWitnesses.badge_screen_catastrophe_occurs`)
- [x] Counter shared/stale state behavior, including highlighted-then-cancelled move (`Battle.Full.Selection.cancel_preserves`, `Battle.Full.Engine.stale_tackle_record_enables_counter`)
- [x] stale Quick Attack/Counter ordering for non-move player actions (`Battle.Full.Engine.stale_counter_nonfight_priority`)
- [x] stale Quick Attack/Counter ordering survives player send-out because only loaded `wPlayerMoveNum`, not `wPlayerSelectedMove`, is cleared (`Battle.Full.Engine.send_out_clears_move_but_retains_record`, `send_out_retains_stale_priority`)
- [x] Jump Kick miss recoil based on zeroed damage (`Battle.Full.Engine.jumpKick_zeroed_damage_recoil`)
- [x] Substitute self-damage turn-flip interaction (`Battle.Full.Engine.turn_flipped_self_damage_selects_opponent`)
- [x] enemy PP not decremented (`Battle.Full.Engine.enemy_pp_not_decremented`)
- [x] disabled-move/PP-Up-bit Struggle-selection anomaly (`Battle.Full.disabled_pp_up_struggle_anomaly`)
- [x] sleep wake consumes turn (`Battle.Full.Status.waking_consumes_turn`)
- [x] frozen target Fire defrost before side-effect RNG (`Battle.Full.Effects.fire_defrost_precedes_side_rng`)
- [x] Hyper Beam/status interactions, including Sleep bypass and freeze asymmetry (`sleep_always_clears_recharge`, `freeze_recharge_asymmetry`)
- [x] healing move high-byte comparison overflow cases (`Battle.BugWitnesses.decoded_healing_false_failure_occurs`)
- [x] Rest full-HP failure before status cure and fixed two-turn sleep request (`rest_full_hp_fails`, `rest_success_exact`)
- [x] Max Ether/Max Elixer PP-Up-bit comparison (`Battle.Full.Items.max_restore_packed_comparison_bug`)
- [x] player Full Restore damaged-active Toxic flag persistence (`Battle.Full.Items.damaged_full_restore_preserves_status3`)
- [x] Rest retains Toxic flag/counter and seeded residual can still use it during sleep (`rest_heal_preserves_toxic`, `toxic_leech_seed_ticks_twice`)
- [x] poison/burn KO does not stop same-pass Leech Seed or its overkill healing (`Battle.Full.Status.leech_seed_runs_after_residual_ko`)
- [x] drain halves shared damage scratch before Counter/Bide can consume it (`Battle.Full.Effects.drain_halves_shared_damage`)
- [x] trainer/wild move slot selection's 63/64/63/66 initial bucket bias (`Battle.Full.TrainerController.slot_bucket_cardinalities`)
- [x] final WRAM cannot distinguish all zero-result terminal causes after cleanup (`Battle.Outcome.cleanup_erases_terminal_distinctions`)
- [x] enemy-first simultaneous faint write order can produce trainer-victory handling and payout with raw result 1 (`Battle.Full.Engine.enemy_first_simultaneous_trainer_win_keeps_loss_byte`)
- [x] simultaneous active faint can be nonterminal when reserves remain (`Battle.Full.Engine.simultaneous_with_reserves_is_nonterminal`)
- [x] two-stage stat effect at current stat 999/1 silently retains one stage despite failure text (`raise_attack_999_two_stage_residue`, `lower_attack_1_two_stage_residue`)
- [x] capture naming and current-box slot-1 insertion/whole-array shift (`Battle.Full.CaptureProtocol.box_slot_one_exact`)
- [x] Old Man player-name restoration leaves aliased wild encounter bytes overwritten (`Battle.Full.OldMan.capture_restores_name_but_retains_alias`; canonical trailing opcode bytes are separately certified)
- [x] layer-2 AI gate carries across voluntary AI switch but resets on forced replacement (`forced_enemy_switch_resets_ai_layer`, `voluntary_enemy_switch_retains_ai_layer`)
- [x] enemy switch destination is deterministic lowest-index other living slot, with an explicit potentially unbounded raw scan step (`Battle.Full.SideState.firstLegalSwitch_exact`, `replacementScanStep`)
- [x] player faint clears party status but preserves fought flag; Revive can restore gain-EXP eligibility (`player_faint_clears_party_status`, `faint_preserves_fought_flags`, `revive_restores_fought_recipient`)
- [x] EXP All counts fainted in-party members in the divisor but skips their awards (`exp_all_counts_full_party`, `fainted_recipient_skipped`)
- [x] wild-faint run prompt uses party slot 1 Speed regardless of active/replacement (`Battle.Full.Environment.wild_faint_speed_uses_slot_one`)
- [x] healed-enemy recall-message underflow and zero-divisor raw divergence (`Battle.Full.Recall.healed_enemy_good_text`, `nonzero_max_hp_can_diverge`); device-level switch timing remains separate
- [x] transformed non-Ditto capture becomes Ditto (`Battle.Full.Capture.transformed_stores_ditto`)
- [x] active status-cure whole-stat reset versus AI cure's retained penalized stats (`Battle.Full.Items.trainer_cure_retains_combat_stats`)
- [x] disobedient replacement move charging the originally selected PP slot (`Battle.Full.Engine.disobedience_charges_original_slot`)
- [x] transformed Mirror Move/Metronome original-party PP increment (`transformed_nested_party_pp_increment`, `syncOutgoing_reads_active`)
- [x] EXP All destructive double-division path (`Battle.Full.Environment.exp_all_destructive_double_division`)
- [x] link setup leading-zero list mismatch (`Battle.Full.Link.leading_zero_setup_mismatch`)
- [x] Safari bait expiry catch-rate persistence (`Battle.Full.Safari.bait_expiry_retains_catch_rate`)
- [x] wild-battle post-victory item-evolution bug (`Battle.Full.Evolution.wild_item_evolution_bug_occurs`)
- [x] simultaneous faint trainer-victory control is based on enemy exhaustion even when later raw result is loss; sound waveform remains excluded (`Battle.Outcome.simultaneous_victory_control_ignores_later_result`, `Battle.Full.Engine.enemy_first_simultaneous_trainer_win_keeps_loss_byte`)

## RL adapter

- [x] typed action protocol (`Battle.RL.Environment.PolicyAction`)
- [x] legal action theorem (`Battle.RL.Environment.legalActions_sound`)
- [x] protocol-invalid action no-op/error behavior (`Battle.RL.Environment.nonfight_invalid`)
- [x] cartridge-ineffective attempt behavior (`Battle.RL.Adapter.ineffective_is_not_protocol_invalid`)
- [x] canonical action-commit and full-selection modes (`Battle.RL.Adapter.SelectionMode`, `action_commit_exact`, `Battle.Full.Selection.runTrace`)
- [x] perfect-information observation (`Battle.RL.Environment.perfect_observation_exact`)
- [x] player-view observation (`Battle.RL.Environment.player_observation_exact`)
- [x] canonical ordinary snapshot and paired-perspective link snapshot codecs/theorems (`Battle.RL.Adapter.ordinary_snapshot_roundtrip`, `link_snapshot_relations_exact`)
- [x] deterministic typed transcript replay including capture naming and nested move-learning/evolution responses (`Battle.RL.Adapter.TranscriptCommand`, `deterministic_transcript_replay`)
- [x] ordinary seeded provider disclaimer/contract (`Battle.RL.Adapter.ordinary_seeded_provider_is_not_hardware`)
- [x] separate team-generation and battle RNG (`Battle.RL.Environment.installReset_uses_supplied_battle_rng`)
- [x] battle-valid generator theorem (`Battle.RL.DynamicGenerator.sample_sound`)
- [x] canonical-species generator theorem (`Battle.RL.DynamicGenerator.sample_sound` via canonical `teamLegal`)
- [x] learnset-legal generator theorem (`Battle.RL.DynamicGenerator.sample_sound` via canonical `teamLegal`)
- [x] progression-witnessed history relative to supplied roster/resource ledger (`Battle.RL.DynamicGenerator.sampleSized_progression_witnessed`)
- [x] no unconditional new-save reachability claim without overworld proof (`Battle.RL.Adapter.no_unconditional_new_save_claim`)
- [x] trainer-defined proved-state installation is exact and bypasses resampling (`Battle.RL.Adapter.trainer_defined_install_exact`)
- [x] single/batch result equality (`Battle.RL.SelfPlay.single_batch_result_equality`)
- [x] semantic transcript events include payout, Pokédex ownership, evolution, naming, and move learning (`Battle.RL.Adapter.SemanticEvent`, `replayCommand`)
- [x] reward wrappers remain outside mechanics (`Battle.RL.Adapter.reward_wrapper_does_not_mutate_mechanics`)
- [x] native throughput and memory benchmark harness (`tools/benchmark-battle-rl.py`); latest 5-run check: 100 episodes/run, 34,717 transitions/run, 0.178 s median, 17,192 KiB max RSS
- [ ] sampled replay through ROM-linked reference
