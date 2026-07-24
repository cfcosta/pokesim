# Second-pass ASM audit

<!-- research record; completed against the pinned source commit -->

**Baseline:** `pret/pokered` commit `405b6246372d7e5a2cb029cbb65219b13286b8c9`.

This pass rechecked the specification and documentation against the assembly rather than relying on the first-pass conceptual summary. Later refinements are recorded in the [third-pass ASM audit](third-pass-asm-audit.md). It followed control-flow labels, WRAM aliases, effect tables, item failure paths, menu writes, progression calls, and direct/random call distinctions.

## High-impact corrections

| Finding | ASM evidence | Documentation consequence |
|---|---|---|
| Post-battle evolution is inside the battle driver | `_InitBattleCommon` calls `StartBattle` and then `EndOfBattle`; the selected `EndOfBattle` path calls `EvolutionAfterBattle` before `InitBattle` returns | Evolution mechanics, cancellation, species/stat/type/move writes, Pokédex writes, and the wild item-evolution bug are in scope. Only rendering is excluded. |
| Low/high external traces have different alphabets | `Random_` consumes two `rDIV` reads; `VBlank` also calls `Random`; the high core consumes mechanics-result bytes | Replaced raw transcript-suffix equality with a coupling between the low hardware trace and a projected `(source, site, returned byte)` semantic trace. |
| Battle menus are not pure presentation | `PrintMenuItem` writes highlighted move/record state; `SwapMovesInMenu` mutates active and party moves/PP; the item list calls `HandleItemListSwapping` | Added a mechanics-visible selection/action-commit layer and full versus canonical RL selection modes. |
| Several apparent “forced turns” still show the top-level menu | `MainInBattleLoop` calls `DisplayBattleMenu` before checking sleep, freeze, Bide, trapping continuation, or opponent trapping | Switch/item/run remain selectable; Fight commits without a move-slot choice. Only Rage/recharge/Thrash/charge bypass the menu entirely. |
| Priority and Counter can observe a canceled menu highlight | `PrintMenuItem` updates `wPlayerSelectedMove`; order checks read it even for item/switch turns, and `HandleCounterMove` reads selected move, loaded power/type, and shared `wDamage` | An atomic action alone is not enough for arbitrary cartridge input traces. |
| Traded-Pokémon disobedience was omitted | `CheckForDisobedience` reads OT/player IDs, badges, level, PP/menu state, and repeatedly calls `BattleRandom` | Added a dedicated mechanics/proof checklist and request/state coverage. |
| Safari catch-rate reset was overstated | `ItemUseBait` halves actual catch rate; `PrintSafariZoneBattleText` restores catch rate only as the rock/escape factor reaches zero | Bait expiry does not restore catch rate; repeated bait/rock changes compound. |
| Safari high-Speed escape occurs before factors | `StartBattle` doubles the enemy Speed low byte and jumps to `EnemyRan` on carry before checking bait/rock | Added the pre-factor carry branch to coverage. |
| Active catch rate and party position were conflated | `battle_struct` has a copied catch-rate field, but capture uses separate `wEnemyMonActualCatchRate`; player index is `wPlayerMonNumber`, not the aliased party-position/box-level byte | Corrected the state model and codec obligations. |
| Item actions need nested targets and failure semantics | PP restorers can choose party and move; PP Up rejects in battle; trainer/ghost/full-box ball paths consume different resources/turns | Expanded requests and distinguished protocol-invalid responses from cartridge-ineffective attempts. |
| Battle code mutates more persistent state than party HP | enemy load sets Pokédex seen; capture sets seen/owned and party/box; trainer victory adds BCD prize; EndOfBattle pays Pay Day | Added Pokédex, current box, ordered inventory, trainer payout, and evolution state to the projection. |
| Run behavior had boundary omissions | `TryRunningFromBattle` succeeds at equal Speed, uses `(enemySpeed / 4) mod 256`, adds 30 only after the first attempt, and trainer prohibition does not consume the turn | Corrected run coverage and Fight-driven attempt reset. |
| The low-level runner needs more than CPU+DIV | battle/presentation code polls `rLY`, HALTs for VBlank, waits on audio state, writes VRAM/OAM, and waits on serial state | Expanded machine/MMIO obligations or required proved summaries for those paths. |

The pass also corrected the recorded SHA-256 for `data/types/type_matchups.asm` to `f7f2286029d4fe64c80ed6cc5f5c75ec1f1b8903a9eabd171deab49e23228d39`; the first-pass value had omitted characters.

## Confirmed first-pass conclusions

The second pass confirmed, including scripted cardinality checks:

- 165 move records of six bytes and effect IDs `$00`–`$56` with 86 nonzero-ID pointer entries;
- 151 base-stat files: 150 included in the main table and Mew placed separately in ROM;
- a 190-entry internal-to-Pokédex map, including zero/MissingNo. entries;
- 47 trainer-class table entries after the `NOBODY` sentinel;
- 83 ordinary-item dispatch entries before HM/TM IDs;
- 44-byte party and 29-byte active structures;
- fixed trainer DVs `$98/$88` and two `BattleRandom` bytes for ordinary wild DVs;
- hard-coded Quick Attack/Counter order before Speed and a `BattleRandom` tie;
- per-actor poison/burn/Leech Seed processing rather than one generic round-end phase;
- staged move-effect dispatch through six classification views plus explicit ID checks;
- player/enemy status and move-execution asymmetry;
- ordinary `Random_` dependence on incoming carry, two divider reads, timing, and VBlank;
- the link generator's ten-byte memory block and nine-byte battle cycle (the third pass refines the setup/equality claim to paired post-setup blocks);
- separate trainer move scoring and direct-`Random` action AI;
- non-link enemy PP not decrementing;
- byte-exact damage staging, critical base-stat paths, type-table ordering, and possible zero-divisor freeze;
- capture's direct-`Random` algorithm and transformed-target Ditto assumption;
- experience/stat EXP, active stat recalculation, and exact-level move-learning behavior.

## Exact effect-table pass

The following ASM tables were reread as one control-flow unit:

- `data/battle/residual_effects_1.asm`;
- `data/battle/special_effects.asm` and its interior `SpecialEffectsCont` label;
- `data/battle/set_damage_effects.asm`;
- `data/battle/residual_effects_2.asm`;
- `data/battle/always_happen_effects.asm`;
- `data/moves/effects_pointers.asm`.

The resulting exact index is in [Effect dispatch](../reference/effect-dispatch.md). Notable consequences include:

- `NULL` pointers for Mirror Move, Swift, Super Fang, special damage, Jump Kick, and Metronome are safe only because other control flow handles them;
- OHKO enters its handler from `CalculateDamage`;
- Twineedle changes its effect to poison while initializing exactly two hits;
- Hyper Beam is not in `AlwaysHappenSideEffects`, so a target-faint path skips setting recharge;
- Bide initialization clears both loaded move-effect bytes;
- Mirror Move/Metronome PP compensation also increments enemy active/party PP even though ordinary enemy execution never decrements PP;
- Rage's handler is reached in the always-happen phase and again in remaining-effect control flow.

## Additional mechanics added to coverage

- Sleep clears target recharge before accuracy/existing-status checks.
- Player-inflicted freeze clears enemy recharge; the enemy branch does not mirror it.
- Haze resets both sides' stages/stats, cures only the target's nonvolatile status, can cancel its selected move, clears selected volatile flags, and preserves Transform.
- OHKO succeeds at equal current Speed.
- Damage randomization rotates each random byte with `rrca` before accepting 217–255.
- Poke Flute wakes both active structures, the full player party, and the enemy party in trainer battles; a no-effect use still consumes the action. Its “any asleep” flag comes from party scans, so a sleeping wild active target alone can be woken while the no-effect message path is selected.
- Player Full Restore takes different status-cure paths at full versus damaged HP; the damaged-active path clears the status bytes without clearing `BADLY_POISONED` in battle status 3.
- Max Ether/Max Elixer compare the full PP byte when detecting no effect, including PP Up bits.
- `AnyMoveToSelect` and disobedient alternate-move selection contain raw-versus-masked PP-byte differences; PP Up bits can affect zero-current-PP control flow when Disable is active.
- A trainer-ball throw removes the ball and consumes the turn; a full-party/full-box rejection does neither. Master Ball still consumes the first ordinary random result before its unconditional-success branch.
- Shift-style switching is implemented inside `EnemySendOut` and suppressed on first send-out, one-member parties, link battles, Set mode, and AI-triggered switching.
- `TrainerAI` consumes direct `Random` before class dispatch whenever its count is nonzero, including Generic/no-op and failed-threshold paths; unsuccessful consideration does not decrement the count.
- `ReadTrainer` applies Lone/Team/Champion move patches after party construction without rewriting the corresponding enemy-party PP byte; active PP is later regenerated from the patched move.
- Trainer prize money is based on trainer base BCD money and the final enemy level loaded by `ReadTrainer`.
- Pay Day and non-link evolution are guarded by the raw `wBattleResult == 0` check, which must not be generalized to a semantic result without proof; Poke Doll/move escape and ordinary Run write different result fields.
- The later blackout money-halving/heal routine is outside `InitBattle` and remains explicitly out of scope.

## Remaining implementation-time checks

These cannot be closed from source text alone and remain M0/M1 work:

1. Build the exact ROM and derive authoritative addresses from `.sym`/`.map`.
2. Generate the indirect transitive graph through predefs, effect/AI pointers, text callbacks, and banked jumps.
3. Determine all mechanics-projected writes made by routines currently classified as presentation.
4. Select exact entry/exit PCs for supplied wild, trainer, link, Safari, tutorial, action-commit, and post-evolution return checkpoints.
5. Decide whether exact current-box capture is modeled internally or refined to a storage request.
6. Audit opcode/MMIO reachability, especially LCD scanline waits, HALT/VBlank, audio completion, and serial loops.
7. Differentially verify source comments and line-based deductions against traces from the rebuilt canonical ROM.

## Documents revised by this pass

- `SPEC.md`
- `docs/explanation/current-battle-engine.md`
- `docs/explanation/formal-verification-strategy.md`
- `docs/explanation/rng-and-time.md`
- `docs/explanation/rl-environment.md`
- `docs/reference/battle-source-map.md`
- `docs/reference/battle-state-model.md`
- `docs/reference/mechanics-coverage.md`
- `docs/reference/effect-dispatch.md` (new)
- `docs/research/codebase-memory.md`
