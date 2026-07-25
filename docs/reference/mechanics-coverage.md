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
- [ ] battle transitive call graph generated through calls, bankswitches, predefs, pointer tables, and text callbacks
- [ ] trainer end-text/map callbacks classified as projected mutation, proved frame, or out of scope
- [ ] every in-scope ROM range classified
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
- [ ] ROM banking and far-call behavior
- [ ] WRAM/HRAM and aliases
- [ ] Game Boy `DIV`, timer, interrupt, VBlank, and device behavior needed by battle
- [ ] joypad/link/timer external-response semantics
- [ ] `rLY`, LCD/VBlank, HALT wakeup, and interrupt timing required by waits
- [ ] VRAM/OAM/DMA behavior, fixture/family-qualified monochrome active-access/IDU OAM relation, and HALT/DMA clock gating or proved summaries
- [ ] audio/VBlank progress required by sound-completion loops
- [ ] serial waits and externally/internally clocked role
- [ ] paired cartridge-perspective state and serial-exchange semantics
- [x] external-clock random-list leading-zero scan and post-setup list mismatch (`Battle.Full.Link.leading_zero_setup_mismatch`)
- [ ] `_Multiply` and `_Divide`
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

- [ ] bounds theorem
- [ ] typed decoder
- [ ] encode/decode theorem
- [ ] original-byte equality theorem
- [ ] table-length theorem
- [ ] source/ROM hash in generated manifest

## End-to-end driver closure

The complete gate list is [End-to-end verification closure](end-to-end-closure.md).

- [x] hermetic RGBDS 1.0.2 ROM build, `.sym`, `.map`, SHA-1/SHA-256
- [ ] explicit `InitOpponent` bank/stack/hardware entry and supplied-opponent `InitBattle` prefix theorem
- [ ] no-encounter `InitBattle` paths separated from battle-driver completion
- [ ] address-based transitive code/data graph through bankswitches, predefs, pointer tables, text callbacks, interrupts, and assets
- [ ] no unresolved reachable ROM range or indirect edge
- [ ] VRAM/OAM/MMIO/external-SRAM/audio/joypad/serial/LCD support or proved summaries
- [ ] mode setup refinement before `StartBattle`
- [ ] terminal witness enters `ending`; simultaneous active faint may remain nonterminal
- [ ] Pay Day/evolution/move-learning/cleanup refinement after terminal witness
- [ ] restored caller fields, bank/stack, carry, and returned `EpisodeResult`
- [ ] caller boundaries explicit for encounter triggering, blackout, trainer scripts, link auto-heal, and Old Man script cleanup
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

- [ ] party count/species terminator invariants
- [ ] 44-byte party member codec
- [ ] 29-byte active member codec
- [ ] names and OT IDs where mechanics-relevant
- [ ] base record lookup, including Mew and special fossil/ghost IDs
- [ ] wild DV generation
- [ ] fixed trainer DVs
- [ ] special trainer move patches and stale enemy-party PP bytes before active PP reload
- [ ] HP/stat calculation from base stat, DV, stat EXP, and level
- [ ] HP DV derivation
- [ ] 999 stat cap
- [ ] default/base moves
- [ ] level-up move derivation and four-slot shifting
- [ ] move PP and PP Up encoding
- [ ] `wBattleMonSpecies2`/`wEnemyMonSpecies2` identity versus Transform-mutable species
- [ ] active party-position byte versus authoritative player/enemy indexes
- [ ] active copied catch rate versus separate `wEnemyMonActualCatchRate`
- [ ] active data load from party
- [ ] burn/paralysis penalties on send-out
- [ ] badge boosts on send-out and explicit link-battle bypass
- [ ] initial stage values
- [ ] distinct gain-EXP/fought-current-enemy flags and [transition matrix](switch-faint-and-participation.md)
- [ ] named mode-specific reset images at explicit driver entry: prior/new-game cleanup fields, stack/bank/hardware, and caller inputs
- [ ] `InitBattleVariables` partial reset (`wMiscBattleData`) versus stale `wBattleStatusData` and caller-owned normal/Old Man `wBattleType`
- [ ] transition code's VRAM/OAM/MMIO/audio/external-SRAM sprite-scratch effects
- [ ] unconditional first-living-enemy scan, including wild/Safari/Old Man scratch precondition
- [ ] first living player member search
- [ ] ordinary enemy-load Pokédex seen-flag mutation and link-load omission
- [ ] invalid/no-living-member behavior, including zero-count 256-iteration `AnyPartyAlive`/`AnyEnemyPokemonAliveCheck`
- [ ] MissingNo./zero Pokédex-map base-record behavior under raw-state mode

## Action legality and turn consumption

- [ ] full-menu bypass only for Rage/recharge/Thrash/charge continuation
- [ ] Fight-without-slot behavior for sleep/freeze/Bide/trapping states
- [ ] switch/item/run remain selectable in those post-menu lock states
- [ ] ordinary Fight/move-slot availability
- [ ] selectable move has PP and is not disabled
- [ ] Struggle when no selectable move remains
- [ ] `AnyMoveToSelect` PP masking differences with/without Disable and PP Up bits
- [ ] potential move-menu trap when disabled handling sees raw PP-Up bits but slots have zero current PP
- [ ] player item legality
- [ ] item target legality
- [ ] switch target is living and not active
- [ ] run legality and trainer prohibition
- [ ] link action exchange values
- [ ] Safari actions
- [ ] successful item consumes action
- [ ] successful switch consumes action
- [ ] failed wild run consumes action
- [ ] canceled/failed menu operation does not consume action
- [ ] `CANNOT_MOVE` when trapped after top-level selection
- [ ] replacement choice after faint
- [ ] wild-faint choice to replace or attempt escape using `wPartyMon1Speed`
- [ ] shift-style stay/switch response before trainer send-out
- [ ] ordinary player Mimic target-move request
- [ ] item party/move target requests and cancellation
- [ ] move-learning nested learn/forget/HM rejection/cancel/abandon-confirmation requests
- [ ] capture nickname/default-name request for party and box destinations
- [ ] post-battle evolution cancel request

## Mechanics-visible selection layer

- [ ] choosing Fight resets `wNumRunAttempts`
- [ ] non-disabled highlighted move writes `wPlayerSelectedMove`
- [ ] non-disabled highlight reloads power/type/accuracy/PP scratch; disabled highlight does not
- [ ] canceling Fight preserves stale selected move/record and highlighted `wPlayerMoveListIndex`
- [ ] stale selected move influences Quick Attack/Counter order for item/switch turns
- [ ] stale loaded power/type influences enemy Counter
- [ ] player send-out clears selected-slot index/move number but retains selected move, shared damage, and adjacent loaded-record scratch
- [ ] ordinary move-menu SELECT swaps active move IDs and PP
- [ ] move swap updates party move IDs and PP, including transformed active/party mismatch
- [ ] move swap updates disabled-slot encoding
- [ ] battle-bag SELECT swaps ordered item/quantity entries
- [ ] move/bag reorder consumes no battle turn
- [ ] cartridge-ineffective selection attempt versus protocol-invalid response
- [ ] canonical RL `ActionCommit` trace refines one concrete menu path
- [ ] full selection trace covers browse/cancel/reorder paths

## Order and phase flow

- [ ] Quick Attack ordering
- [ ] Counter ordering
- [ ] stale selected moves retained by locked/forced player and enemy selection paths
- [ ] Speed comparison
- [ ] equal-Speed random comparison
- [ ] link clock-role inversion
- [ ] trainer AI action immediately before enemy execution
- [ ] trainer shift-style prompt conditions in `EnemySendOut`
- [ ] `wFirstMonsNotOutYet` suppression during first send-out and AI switch
- [ ] item/switch already committed before move-order resolution
- [ ] stale player move still participates in Quick Attack/Counter ordering
- [ ] stale priority orders the switch no-op; incoming poison/burn residual can run and KO before enemy action or after it
- [ ] escape checks after move execution
- [ ] faint check before residual/other actor where source does so
- [ ] acting-side poison/burn/Leech Seed
- [ ] second actor execution
- [ ] second residual
- [ ] poison/burn can reduce the actor to zero before Leech Seed still runs and heals
- [ ] Leech Seed overkill heals nominal computed damage rather than capped HP loss
- [ ] Toxic counter increments once for poison and again for Leech Seed on the same residual pass
- [ ] trapping counter cleanup
- [ ] loop back to selection
- [ ] simultaneous-active-faint paths as event/order metadata, including nonterminal reserve continuation
- [ ] terminal witness enters `ending`, not returned/done
- [ ] terminal trainer payout/end-text, raw-result-guarded Pay Day/evolution, cleanup, and outer return phases

## Status gate order

The proof must preserve this player/enemy control-flow order, including random consumption and counter updates:

- [x] sleep decrement, wake, and turn loss (`Battle.Full.Status.waking_consumes_turn`)
- [ ] freeze
- [ ] trapped by opponent
- [ ] flinch and reset, including main-loop reset bypass while Rage/recharge is already set
- [ ] Hyper Beam recharge and reset
- [ ] Disable counter decrement/expiration
- [ ] confusion counter, animation, and self-hit roll
- [ ] selected move disabled after selection
- [ ] paralysis roll
- [ ] Bide accumulation/release
- [ ] Thrash/Petal Dance continuation and confusion
- [ ] trapping continuation and reused damage
- [ ] Rage continuation
- [ ] ordinary move execution

## Traded-Pokémon disobedience

- [ ] disabled entirely in link battles
- [ ] two-byte OT ID comparison with player ID
- [ ] badge thresholds: 10/30/50/70/101
- [ ] level-at-or-below-threshold obedience
- [ ] first swapped-byte rejection/obedience loop
- [ ] second rejection loop selecting alternate behavior
- [ ] alternate usable move and retry conditions, including raw full-PP-byte nonzero check
- [ ] replacement move changes `wCurrentMenuItem` but PP decrement still uses the originally selected `wPlayerMoveListIndex`
- [ ] zero-current-PP replacement with PP Up bits can underflow/deform the full PP byte on decrement
- [ ] no alternate move with one move, Disable, Struggle, or only one PP-bearing move
- [ ] random nap duration and whole-status-byte overwrite of poison/burn/paralysis
- [ ] loaf/turn-away/ignore text branch state
- [ ] disobedient self-damage path
- [ ] exact `BattleRandom` consumption and move-record reload

## Damage and hit system

- [ ] physical/special selection by type index `$14`
- [ ] current Attack/Defense/Special selection
- [ ] Reflect and Light Screen doubling
- [ ] critical hit unmodified-calculated-stat substitution (player party stats versus enemy recalculation/link party stats)
- [ ] critical level doubling
- [ ] stat scaling by division by four
- [ ] low-byte truncation/wrap behavior
- [ ] zero-defense divergence
- [ ] Explosion defense halving with minimum divisor one
- [ ] neutral damage integer pipeline
- [ ] neutral minimum and 999 cap
- [ ] STAB `1.5×` with floor
- [ ] ordered dual-type application
- [ ] immunity and low-damage-to-zero miss behavior
- [ ] STAB/type arithmetic wrap and last-match `wDamageMultipliers` rather than net dual-type encoding
- [ ] `rrca` of each damage-random byte before rejection
- [ ] random factor rejection and accepted `217..255` multiplier
- [ ] accuracy/evasion two-pass flooring, per-pass minimum 1, final cap 255, and destructive loaded-accuracy write
- [ ] raw accuracy 0 hits on byte 0; threshold 255 misses on byte 255
- [ ] stage intermediate truncation
- [ ] Mist checks
- [ ] X Accuracy bypasses stage/final accuracy only after Dream Eater/Substitute/Fly-Dig/Mist gates
- [x] Swift returns before Substitute/Fly-Dig/Mist/X Accuracy behavior (`Battle.Full.Engine.swift_precedes_accuracy_gates`)
- [ ] Fly/Dig invulnerability ordering
- [ ] Dream Eater sleep check
- [ ] Substitute interaction
- [ ] final `random < accuracy` comparison
- [ ] critical threshold from base Speed
- [ ] high-critical move list: Karate Chop, Razor Leaf, Crabhammer, Slash
- [ ] Focus Energy right-shift bug
- [ ] critical random-byte rotations
- [ ] HP subtraction, overkill cap, and `wDamage` update
- [ ] Substitute damage path, damage-greater-than-255 break, and exact-damage zero-HP survival
- [ ] substitute break zeroes the attacker's loaded effect while nonbreaking hits retain it
- [ ] Rage-building response to damage
- [x] OHKO succeeds when user current Speed is equal to or greater than target Speed (`Battle.Rom.OhkoRoutine.decoded_speed_comparison_exact`)
- [ ] OHKO critical-test draw, speed-failure early exit, and successful type/random-damage/accuracy ordering
- [ ] Super Fang one-half current HP with minimum one
- [ ] fixed-damage/Super Fang bypass of ordinary STAB/type adjustment
- [ ] player/enemy fixed-damage and Psywave range asymmetry
- [ ] Counter's selected-move/type/power and shared-`wDamage` dependencies
- [ ] Counter doubles/caps shared damage, runs its own hit test, and skips ordinary damage/type/randomization
- [ ] Counter still performs the preceding critical test and can retain critical event/text state
- [ ] drain effects overwrite shared `wDamage` with `max(floor(damage/2), 1)`, affecting later Counter/Bide

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

- [ ] stat stages 1–13
- [ ] exact stored decimal-style stage-ratio table and immediate flooring
- [ ] [badge boost stacking matrix](stat-modifier-flow.md) outside link on player stat-up and enemy-on-player stat-down, including accuracy/evasion
- [ ] stat-effect burn/paralysis reapplication: self stat-up penalizes opponent; stat-down penalizes target; unrelated-stat and AI X-item stacking
- [ ] equality-only current-stat rollback at `0/1/2` and `998/999/1000`; 999/1 two-stage effects leave a silent one-stage residue
- [ ] extra non-link enemy stat-down `< 64` failure before effect classification
- [ ] damaging enemy stat-down side effects use sequential `>= 64` then `< 85` draws, with one-versus-two-byte consumption
- [ ] confusion 2–5 turns and 50% self-hit comparison
- [ ] self-confusion 40-power typeless damage without crit/random/hit test
- [ ] self-confusion clears every battle-status-1 bit except `CONFUSED` before common multi-turn cleanup
- [ ] flinch rates and recharge clearing
- [ ] Mist/Guard Spec
- [ ] Focus Energy/Dire Hit
- [x] Substitute HP and zero-HP-user behavior (`Battle.Rom.SubstituteRoutine.decoded_affordability_exact`)
- [ ] Hyper Beam recharge and target-faint skip because effect is not always-happen
- [x] Leech Seed and Toxic-counter interaction (`Battle.Full.Status.toxic_leech_seed_ticks_twice`)
- [x] Reflect (`Battle.Rom.ScreenRoutine.screens_exact`)
- [x] Light Screen (`Battle.Rom.ScreenRoutine.screens_exact`)
- [x] Transform player/enemy invulnerability-check asymmetry (`Battle.Rom.TransformRoutine.transform_invulnerability_exact`)
- [ ] Transform species/types/catch/moves/DVs/current combat stats copy boundaries
- [ ] Transform preserves user HP/level/max HP and sets nonblank copied PP to 5
- [ ] Transform copies unmodified stats/stat stages and stores enemy original DVs
- [ ] Minimize state where it affects mechanics/presentation branch only
- [ ] elemental side-effect immunity when move type equals either target type, including Body Slam versus Normal
- [x] SleepEffect clears target recharge before accuracy/existing-status checks (`Battle.Full.Effects.sleep_always_clears_recharge`)
- [x] player freeze side effect clears enemy recharge; enemy freeze does not mirror it (`Battle.Full.Effects.freeze_recharge_asymmetry`)
- [ ] Haze preserves Transform and raw status-3 high bits while clearing Toxic/screens and selected volatile flags
- [ ] Haze copies unmodified stats without reapplying retained burn/paralysis or badge modifiers
- [ ] Rest leaves `BADLY_POISONED` and Toxic counter state intact while writing fixed sleep 2
- [ ] stale Toxic after Rest/damaged Full Restore can affect later normal poison and seeded sleep
- [ ] Conversion copies active target types through Substitute, skips ordinary hit testing, and fails on target invulnerability
- [ ] Explosion/Selfdestruct zero user HP/status and clear seeded state before later miss handling

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

- [ ] all move IDs 1 through 165 decode from ROM
- [ ] each move's effect ID maps to covered behavior
- [ ] each move's exceptional ID checks are covered
- [ ] all Metronome eligibility/rejections are covered
- [ ] all Mirror Move/Metronome move-record reloads and PP compensation are covered
- [ ] transformed player Mirror Move/Metronome increments original party PP but transformed decrement skips it
- [ ] enemy Mirror Move/Metronome PP increment despite ordinary enemy PP not decrementing
- [ ] ordinary player Mimic choice versus enemy/link random Mimic is covered
- [ ] Mimic replaces only active move ID and retains that slot's existing PP byte
- [ ] direct Confusion blocks Substitute while Confusion's damaging side effect can pass through a surviving Substitute
- [ ] Disable hit/occupied checks, slot and duration draws, link/player PP checks, and raw PP-Up-bit candidate bug
- [ ] move animation IDs are excluded or event-mapped with frame proof

Exceptional move-ID checks include at least Quick Attack, Counter, Metronome, Mirror Move, Struggle, Toxic, Fly, Dig, Teleport, Roar, Explosion, Selfdestruct, Minimize, Rest, Dream Eater, SonicBoom, Dragon Rage, Seismic Toss, Night Shade, Psywave, and Super Fang.

## Multi-turn and multi-hit behavior

- [ ] Bide 2/3 turn selection and repeated accumulation of shared/stale `wDamage`, including Substitute cases
- [ ] Bide release/miss when zero accumulated damage
- [ ] Bide initialization clears both loaded move-effect bytes
- [ ] Thrash/Petal Dance 2/3 turn selection
- [ ] post-Thrash confusion duration
- [ ] charge first/second turn and first-turn omission from last-used-move scratch
- [ ] Fly/Dig invulnerability
- [ ] directly selected charge-turn PP deferred until attack turn
- [ ] charge state is unbound: Mirror Move/Metronome/disobedience-generated charge continues with retained wrapper/original selected slot
- [ ] nested wrapper PP versus disobedient replacement PP ordering
- [ ] full-paralysis/self-confusion/selected-disabled charge cleanup clears charging but leaves Fly/Dig invulnerability until volatile reset
- [ ] trapping continuation count chosen before accuracy, target recharge cleared before hit, and total-hit interpretation
- [ ] trapping hit reuse without new damage/accuracy roll
- [ ] trapping miss cleanup
- [ ] two-to-five hit distribution with count draws before first-hit accuracy
- [ ] fixed two-hit and Twineedle conversion, with poison roll after the final hit
- [ ] first-hit-only damage/accuracy calculation
- [ ] target faint interruption
- [ ] hit count/event result

## Switching, fainting, and battle end

Exact transitions are catalogued in [Switch, faint, and participation flow](switch-faint-and-participation.md).

- [ ] voluntary player switch
- [ ] enemy trainer switch
- [ ] link remote switch
- [ ] outgoing active-to-party HP/status copy
- [ ] contiguous HP/party-position/status copy overwrites party `MON_BOX_LEVEL`, especially enemy AI switch
- [ ] segmented incoming party-to-active codec
- [ ] burn/paralysis before non-link badges on player send-out
- [ ] six stages reset to 7 while two padding bytes remain stale
- [ ] exact partial send-out reset: volatile flags/Disable cleared, counters stale, selected/loaded scratch split
- [ ] trapping and switch restrictions
- [ ] player faint clears active/party nonvolatile status but retains own volatile block until replacement/cleanup
- [ ] enemy faint clears enemy volatile block and party HP but retains enemy party nonvolatile status
- [ ] Bide accumulator asymmetric clear
- [ ] faint clears gain bit but preserves fought bit; Revive/Max Revive conditionally restores gain eligibility
- [ ] forced replacement
- [ ] trainer next Pokémon uses deterministic lowest-index other living slot with no destination draw
- [ ] non-link enemy send-out scan has no explicit count bound; link received index is unchecked after subtracting 4
- [ ] Shift/Set option polarity and party-count-exactly-1 suppression
- [ ] Shift participation reset makes incoming member sole participant against new enemy
- [ ] shift response rejects active/fainted targets and can switch before send-out
- [ ] AI switch suppresses the player's shift prompt and applies the subsequent enemy residual to the incoming member
- [ ] wild battle victory
- [ ] trainer victory
- [ ] player blackout/loss
- [ ] link win/loss/run result
- [ ] [terminal control-path witness](battle-outcomes.md) before cleanup; no final-memory-only outcome decoder
- [ ] `EndOfBattle` erasure of escape/mode/opponent fields while preserving raw result
- [ ] recoil/simultaneous-KO ordering
- [ ] trainer BCD prize payout
- [ ] `PrintEndBattleText` flag/name/dynamic-text/sprite writes and raw-result lose-text selection during simultaneous-faint victory
- [ ] Pay Day payout guarded exactly by `wBattleResult == 0`
- [ ] post-battle evolution before cleanup while phase remains `ending`
- [ ] low-health alarm state excluded or event-mapped
- [ ] HP-derived recall-text arithmetic/timing, healed-enemy underflow, quotient low byte, and raw zero-divisor divergence

## Run and escape

- [ ] Ghost and Safari unconditional escape cases
- [ ] link run exchange
- [ ] trainer “no running” behavior
- [ ] player Speed greater than or equal to enemy Speed succeeds
- [ ] speed formula and enemy-speed division/truncation
- [ ] attempt count and byte-loop `30 × (attempts - 1)` increments, including raw counter wrap
- [ ] Fight selection resets attempt count, including canceled Fight
- [ ] inclusive escape comparison (`random <= quotientWithBonuses`)
- [ ] failed wild attempt consumes turn
- [ ] prohibited trainer attempt returns to selection without consuming turn
- [ ] divisor is `(enemySpeed / 4) mod 256`; zero succeeds immediately
- [ ] quotient high byte/carry success paths
- [ ] move-based wild escape by Teleport/Roar/Whirlwind
- [ ] automatic success at user level ≥ target level; otherwise level-sum rejection loop and target-level/4 comparison
- [ ] trainer-battle Teleport failure versus Roar/Whirlwind unaffected text/control paths
- [ ] Poke Doll/move escape `wEscapedFromBattle` versus run/link `wBattleResult` writes
- [ ] raw result-code implications for EndOfBattle Pay Day/evolution guard
- [ ] successful move escape synchronizes active player HP/status to party before setting escape
- [ ] Poke Doll/move escape leave result zero and reach non-link Pay Day/evolution, unlike ordinary Run
- [ ] level-based rejection sampling
- [ ] post-faint run response always uses stored party slot 1 Speed, excluding active paralysis/stage/badge changes

## Battle items

The exact 83-entry source disposition is in [Item dispatch](item-dispatch.md); proof coverage must retain every row and malformed index domain.

- [ ] Master/Ultra/Great/Poké/Safari Ball
- [ ] status-specific cures
- [ ] Full Heal
- [ ] Full Restore
- [ ] Max/Hyper/Super/Potion
- [ ] Fresh Water/Soda Pop/Lemonade
- [ ] Revive/Max Revive
- [ ] X Accuracy
- [ ] Guard Spec
- [ ] Dire Hit
- [ ] X Attack/Defend/Speed/Special
- [ ] Poke Doll
- [ ] Poke Flute
- [ ] Ether/Max Ether/Elixer/Max Elixer are battle-reachable, including party/move targeting
- [ ] Max Ether/Max Elixer PP-Up-bit no-effect detection bug
- [ ] PP Up is rejected during battle
- [ ] invalid/key/overworld-only item behavior while in battle
- [ ] inventory quantity removal and ordered bag representation
- [ ] trainer-ball rejection removes the ball and consumes the action
- [ ] party count exactly 6 plus box count exactly 20 rejects a ball without removal/turn consumption
- [ ] raw party counts 7–254 successful-capture-without-storage path and 255 wrap
- [ ] raw box counts 21–255 oversized/wrapped slot-shift behavior
- [ ] unidentified Ghost/Marowak rejection occurs after throw and consumes the ball
- [ ] Poke Flute six-fixed-slot player/enemy scans, active wake scope, and no-effect turn consumption
- [ ] Poke Flute `wWereAnyMonsAsleep` derives from party scans, including sleeping-wild-active message mismatch
- [ ] repeated X Accuracy/Guard Spec/Dire Hit and capped X-stat behavior
- [ ] Revive participation-to-EXP-flag side effect
- [ ] active/party synchronization after item
- [ ] active status cure copies party max HP/all combat stats without reapplying stages, badges, burn, or paralysis, then calls normally-inert `DoubleOrHalveSelectedStats`
- [ ] trainer AI status cures clear status/Toxic bytes without restoring burn/paralysis-reduced combat stats
- [ ] Full Restore damaged-active path versus full-HP status-cure path, including Toxic flag handling
- [ ] item use during trapping and counter decrement behavior
- [ ] items forbidden by the link battle menu before dispatch
- [ ] raw-bag `POKEDEX` action-success/UI path and unobtainable `SURFBOARD`/badge-alias behavior
- [ ] vitamins, Rare Candy, evolution stones, PP Up, and TM/HM battle rejection
- [ ] IDs `$54`–`$C3` index beyond `ItemUsePtrTable`; canonical bag validation versus raw control flow

## Capture

- [ ] battle/trainer/box-capacity preconditions
- [ ] eligible Master Ball unconditional success after still consuming the first `Random` result
- [ ] Ghost/Marowak restrictions
- [ ] ball-specific inclusive first-byte rejection ranges (255/200/150)
- [ ] status subtraction and immediate success
- [ ] `MaxHP × 255` arithmetic
- [ ] ball factors
- [ ] current HP divided by four with minimum one
- [ ] inclusive catch-rate comparison (`Rand1 - Status <= CatchRate`)
- [ ] inclusive second comparison (`Rand2 <= X`)
- [ ] failure shake-count arithmetic
- [ ] status shake bonus
- [ ] transformed capture forces Ditto, including non-Ditto wild Transform acquired through Mirror Move
- [ ] preserve DVs/HP/status while rebuilding base types/catch rate/moves
- [ ] captured OT ID, experience, zero stat EXP, level, and calculated stats
- [ ] capture naming request before action return: decline/custom/empty-name default and timing
- [ ] party capture appends; box capture inserts at slot 1 and shifts species/records/OT/nickname arrays
- [ ] pre-name Pokédex/partial party-or-box state, deferred ordinary-ball removal versus prior Safari decrement, and post-name record construction order
- [ ] Pokédex seen/owned flags
- [ ] exact party append versus current-box slot-1 insertion with parallel-array ordering
- [ ] ordinary/Safari/Old Man ball removal and capture-naming distinctions (Old Man skips naming/storage)
- [ ] Old Man menu saves player name into aliased `wGrassRate`/wild buffer, writes `OLD MAN`, and ball path restores only player name
- [ ] battle result mutation

## Trainer AI

### Move choice

- [ ] initialize four scores
- [ ] discourage disabled move
- [ ] layer 1 redundant-status scoring
- [ ] layer 2 exact numeric effect intervals and `== 1` gate lifecycle across execution, status locks, AI actions, forced replacement, and voluntary switch
- [ ] all layer scans stop at first zero move ID
- [x] layer 3 type-effectiveness scoring, including first matching defender type only (`ai_first_matching_defender_type`, `ScoreInput.fromBattle`)
- [x] AI effectiveness `$10` initialization bug (`Battle.Full.TrainerController.ai_neutral_constant_mismatch`)
- [ ] minimum-score filtering algorithm and malformed leading-zero divergence
- [ ] exact 63/64/63/66 byte slot buckets and rejection among nonzero candidate slots
- [ ] blank and disabled retry
- [x] unlimited enemy PP behavior (`Battle.Full.Engine.enemy_pp_not_decremented`)

### Action AI

- [ ] per-Pokémon action count initialization and successful-action decrement/reset behavior
- [ ] direct `Random` consumed before Generic/no-op and failed-threshold routines while count is nonzero
- [ ] generic no-op leaves count unchanged and therefore continues drawing on later actions
- [ ] Juggler switch
- [ ] Blackbelt/Cooltrainer/Koga X Attack
- [ ] Giovanni Guard Spec
- [ ] Misty/Bruno X Defend
- [ ] Lt. Surge X Speed
- [ ] Brock Full Heal
- [ ] Erika/Lorelei Super Potion thresholds
- [ ] Blaine unconditional selected Super Potion bug
- [ ] Sabrina/Lance Hyper Potion thresholds
- [ ] Rival Potion/Full Restore thresholds
- [ ] Agatha switch/heal branches
- [ ] Cooltrainer F missing-return behavior
- [ ] strict current-HP-below-`floor(maxHP / divisor)` threshold
- [ ] heal cap and HP-bar scratch writes
- [ ] status/Toxic cleanup without recalculating burn/paralysis-reduced enemy combat stats
- [ ] enemy switch living-count rule and deterministic lowest-index other-living send-out scan, with no destination RNG and raw unbounded search
- [ ] all [47 class dispatch rows](trainer-ai-dispatch.md), direct `Random` source, and exact `percent`-macro thresholds
- [ ] `wAICount = $ff` lazy class-count initialization per send-out

## Experience, payout, and post-battle progression

- [ ] no EXP in links
- [ ] participation recipient count, fainted gain-bit clearing, fought-bit retention, Revive restoration, and fainted-recipient skip
- [ ] per-recipient division of base stats/catch/base EXP
- [ ] stat EXP addition and saturation
- [ ] base EXP × level / 7
- [ ] traded 1.5× boost
- [ ] trainer-battle 1.5× boost and sequential intermediate flooring with traded boost
- [ ] EXP addition and level-100 cap
- [ ] level calculation from growth formula
- [ ] multi-level gain behavior and exact-level-only move scan
- [ ] stat recalculation and current-HP increase
- [ ] active member update
- [ ] stage/status/badge reapplication
- [ ] level-up nested move-learning request, automatic empty slot, HM deletion rejection, and abandon-confirmation loop
- [ ] only first exact-level learnset row is considered; skipped intermediate levels and raw duplicate-level rows are ignored
- [ ] active transformed learner receives all party moves/PP while transformed flag/other copied state remain
- [ ] `wCanEvolveFlags` set for leveled recipients
- [ ] EXP All halves source data; participant award may divide it in place before all-party award divides the already-mutated bytes again
- [ ] EXP divisor counts all eight gain-flag bits while recipient iteration uses party count and skips fainted members; EXP All in-count fainted bits reduce living shares
- [ ] trainer prize is base-money BCD added once per final enemy level
- [ ] Pay Day per-use `2 × userLevel` BCD accumulation
- [ ] Pay Day payout only when `wBattleResult == 0`, including Poke Doll/move/Safari zero-result exits
- [ ] `EndOfBattle` evolution guard (`wBattleResult == 0` for non-link; link branch reaches it directly)
- [ ] `EvolutionAfterBattle` runs before clearing battle state
- [ ] evolution eligibility by flag and level/item/trade record scan
- [ ] evolution cancel response and continuation to next party member
- [ ] evolution species, nickname, Pokédex, stats, HP delta, types, and learned move
- [ ] wild-battle item-evolution bug through aliased `wCurItem`/species state
- [ ] link/no-EXP evolution behavior
- [ ] witnessed pre-cleanup terminal checkpoint and separately composed battle cleanup/return checkpoint
- [ ] inside-driver exit handoff: encounter-cooldown set, destination warp `$FF`, and loss-path always-on-bike clear
- [ ] outer return restores letter-delay flags, map-palette offset, and tile-animation state, restores bank/stack frame, sets carry, then creates returned outcome
- [ ] post-return blackout, trainer-map flags, cable `HealParty`, and tutorial script cleanup excluded or separately composed
- [ ] blackout money halving/heal explicitly excluded as later overworld transition

## Safari

- [ ] Safari Ball count and out-of-balls check before duration text/escape roll after each successful action
- [ ] bait halves catch rate
- [ ] rock doubles catch rate/caps as implemented
- [ ] bait/rock rejection-sampled 1–5 factor increments with saturation
- [ ] each action zeros the opposite factor
- [ ] duration decrement order
- [ ] bait expiry does not restore catch rate
- [ ] rock/escape-factor expiry restores species base catch rate
- [ ] repeated bait/rock compounding of current actual catch rate
- [ ] speed-low-byte doubling and pre-factor carry escape
- [ ] speed-derived escape threshold
- [ ] bait divides threshold by four
- [ ] rock doubles threshold and caps
- [ ] direct ordinary random comparison with strict boundary
- [ ] out-of-balls result

## Link battle

- [ ] party exchange representation
- [ ] link action values for move/switch/no-action/Struggle/run
- [ ] internally/external-clock role
- [ ] equal-Speed inversion
- [ ] two post-setup ten-byte blocks plus each perspective's first-nine active seeds and index
- [ ] internal-clock alias versus external-clock scan/copy and legitimate-leading-zero mismatch
- [ ] per-perspective `seed := 5 × seed + 1` update
- [ ] conditional equal-list/equal-index invariant and explicit paired-state desynchronization
- [ ] no trainer AI
- [ ] no item use and no link move-menu cancel/reordering
- [ ] no EXP
- [ ] remote switch behavior
- [ ] link Mimic random target selection
- [ ] win/loss/draw result-code interpretation
- [ ] paired cartridge-perspective code-path relational proof
- [ ] link `EndOfBattle` copies mirrored active-enemy status to party but not HP; authoritative local party versus disposable remote mirror
- [ ] battle-driver return precedes cable club's unconditional `HealParty`; full cable-session theorem composes it separately
- [ ] known Psywave desync
- [ ] known Bide-clear desync
- [ ] Mirror Move/Metronome trapping desync warning
- [ ] paired terminal-cause/raw-field agreement when no desync occurs
- [ ] explicit divergence relation when cartridge sides desynchronize

## Known behavior regressions

Each item needs at least one source-linked test; mechanics-affecting items need a theorem or fall out of a broader refinement theorem.

- [x] Focus Energy right shift (`Battle.BugWitnesses.focus_energy_occurs`)
- [x] [exact percent-macro thresholds](probability-thresholds.md), comparison polarities, and boundary bytes
- [ ] Fly/Dig attack-turn self-confusion/full paralysis/Disable clears charging but leaves invulnerability
- [ ] generated charge reloads selected wrapper/original move rather than retaining generated move identity
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
- [ ] Counter shared/stale state behavior, including highlighted-then-cancelled move
- [ ] stale Quick Attack/Counter ordering for non-move player actions and across player send-out's partial loaded-record clear
- [x] Jump Kick miss recoil based on zeroed damage (`Battle.Full.Engine.jumpKick_zeroed_damage_recoil`)
- [x] Substitute self-damage turn-flip interaction (`Battle.Full.Engine.turn_flipped_self_damage_selects_opponent`)
- [x] enemy PP not decremented (`Battle.Full.Engine.enemy_pp_not_decremented`)
- [ ] disabled-move/PP-Up-bit Struggle-selection anomaly
- [x] sleep wake consumes turn (`Battle.Full.Status.waking_consumes_turn`)
- [x] frozen target Fire defrost before side-effect RNG (`Battle.Full.Effects.fire_defrost_precedes_side_rng`)
- [ ] Hyper Beam/status interactions, including Sleep bypass and freeze asymmetry
- [x] healing move high-byte comparison overflow cases (`Battle.BugWitnesses.decoded_healing_false_failure_occurs`)
- [x] Rest full-HP failure before status cure and fixed two-turn sleep request (`rest_full_hp_fails`, `rest_success_exact`)
- [ ] Max Ether/Max Elixer PP-Up-bit comparison
- [x] player Full Restore damaged-active Toxic flag persistence (`Battle.Full.Items.full_restore_preserves_active_status3`)
- [x] Rest retains Toxic flag/counter and seeded residual can still use it during sleep (`rest_heal_preserves_toxic`, `toxic_leech_seed_ticks_twice`)
- [ ] poison/burn KO does not stop same-pass Leech Seed or its overkill healing
- [ ] drain halves shared damage scratch before Counter/Bide can consume it
- [ ] trainer/wild move slot selection's 63/64/63/66 initial bucket bias
- [ ] final WRAM cannot distinguish all zero-result terminal causes after cleanup
- [ ] simultaneous faint write order can produce trainer lose text and payout with raw result 1
- [ ] simultaneous active faint can be nonterminal when reserves remain
- [ ] two-stage stat effect at current stat 999/1 silently retains one stage despite failure text
- [ ] capture naming and current-box slot-1 insertion/whole-array shift
- [ ] Old Man player-name restoration leaves aliased wild encounter bytes overwritten
- [ ] layer-2 AI gate carries across voluntary AI switch but resets on forced replacement
- [ ] enemy switch destination is deterministic lowest-index other living slot, with unbounded raw scan
- [ ] player faint clears party status but preserves fought flag; Revive can restore gain-EXP eligibility
- [ ] EXP All counts fainted in-party members in the divisor but skips their awards
- [ ] wild-faint run prompt uses party slot 1 Speed regardless of active/replacement
- [ ] healed-enemy recall-message underflow and zero-divisor raw divergence affect switch timing
- [ ] transformed non-Ditto capture becomes Ditto
- [ ] active status-cure whole-stat reset versus AI cure's retained penalized stats
- [ ] disobedient replacement move charging the originally selected PP slot
- [ ] transformed Mirror Move/Metronome original-party PP increment
- [ ] EXP All destructive double-division path
- [ ] link setup leading-zero list mismatch
- [ ] Safari bait expiry catch-rate persistence
- [ ] wild-battle post-victory item-evolution bug
- [ ] simultaneous faint victory-sound/control behavior, with sound itself excluded

## RL adapter

- [ ] typed action protocol
- [ ] legal action theorem
- [ ] protocol-invalid action no-op/error behavior
- [ ] cartridge-ineffective attempt behavior
- [ ] canonical action-commit and full-selection modes
- [ ] perfect-information observation
- [ ] player-view observation
- [ ] canonical ordinary snapshot and paired-perspective link snapshot codecs/theorems
- [ ] deterministic transcript replay including capture naming and nested move-learning traces
- [ ] ordinary seeded provider disclaimer/contract
- [ ] separate team-generation and battle RNG
- [ ] battle-valid generator theorem
- [ ] canonical-species generator theorem
- [ ] learnset-legal generator theorem
- [ ] progression-witnessed history relative to supplied roster/resource ledger
- [ ] no unconditional new-save reachability claim without overworld proof
- [ ] trainer-defined generator equivalence
- [ ] single/batch result equality
- [ ] semantic events including payout/Pokédex/evolution
- [ ] reward wrappers outside mechanics
- [ ] native throughput and memory benchmarks
- [ ] sampled replay through ROM-linked reference
