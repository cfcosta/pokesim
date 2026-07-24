# Item dispatch

<!-- mode: reference -->

**Baseline:** `pret/pokered` commit `405b6246372d7e5a2cb029cbb65219b13286b8c9`.

`UseItem_` initializes `wActionResultOrTookBattleTurn` to 1, then dispatches item IDs `$01`–`$53` through `ItemUsePtrTable`. A handler that rejects or is canceled normally clears the byte to 0. The battle menu blocks the bag entirely in link battles; Safari and Old Man modes use synthetic item menus.

## Disposition vocabulary

| Disposition | Meaning |
|---|---|
| Capture | Reaches `ItemUseBall`; exact result depends on mode, trainer/ghost/box checks, capture arithmetic, and resource removal. |
| Battle use | Canonical bag item can perform a battle mutation and normally commits the action on success. |
| Battle reject | Handler reaches `ItemUseNotTime`, `ItemUseNotYoursToUse`, `UnusableItem`, or another failure path and returns action result 0. |
| Safari pseudo-action | ID aliases a badge but the Safari menu writes it directly to `wCurItem`; the routine does not itself require Safari mode. |
| Raw-only path | Not a canonical bag action, but an injected structurally indexed ID can enter a non-rejecting handler. |
| Contextual | Handler has both rejecting and action-committing battle branches. |

## Exact ordinary-item table

| ID | Constant | Pointer | Battle disposition |
|---:|---|---|---|
| `$01` | `MASTER_BALL` | `ItemUseBall` | Capture; after eligible prechecks it still draws Rand1 before unconditional success. |
| `$02` | `ULTRA_BALL` | `ItemUseBall` | Capture. |
| `$03` | `GREAT_BALL` | `ItemUseBall` | Capture. |
| `$04` | `POKE_BALL` | `ItemUseBall` | Capture; also the Old Man synthetic item. |
| `$05` | `TOWN_MAP` | `ItemUseTownMap` | Battle reject. |
| `$06` | `BICYCLE` | `ItemUseBicycle` | Battle reject. |
| `$07` | `SURFBOARD` | `ItemUseSurfboard` | Raw-only path; no battle guard, so injected state can run overworld movement checks/mutations or fail contextually. |
| `$08` | `SAFARI_BALL` | `ItemUseBall` | Capture; Safari menu decrements `wNumSafariBalls`, while an injected normal-bag entry uses ordinary bag removal. |
| `$09` | `POKEDEX` | `ItemUsePokedex` | Raw-only action-success path; opens Pokédex UI, does not remove an item, and never clears the initialized action result. |
| `$0A` | `MOON_STONE` | `ItemUseEvoStone` | Battle reject. |
| `$0B` | `ANTIDOTE` | `ItemUseMedicine` | Battle use if the target has matching status. |
| `$0C` | `BURN_HEAL` | `ItemUseMedicine` | Battle use if the target has matching status. |
| `$0D` | `ICE_HEAL` | `ItemUseMedicine` | Battle use if the target has matching status. |
| `$0E` | `AWAKENING` | `ItemUseMedicine` | Battle use if the target has matching status. |
| `$0F` | `PARLYZ_HEAL` | `ItemUseMedicine` | Battle use if the target has matching status. |
| `$10` | `FULL_RESTORE` | `ItemUseMedicine` | Contextual battle use; full-HP status cure and damaged-HP branches have different active-stat/Toxic behavior. |
| `$11` | `MAX_POTION` | `ItemUseMedicine` | Battle use on a living, non-full-HP target. |
| `$12` | `HYPER_POTION` | `ItemUseMedicine` | Battle use on a living, non-full-HP target. |
| `$13` | `SUPER_POTION` | `ItemUseMedicine` | Battle use on a living, non-full-HP target. |
| `$14` | `POTION` | `ItemUseMedicine` | Battle use on a living, non-full-HP target. |
| `$15` | `BOULDERBADGE` / `SAFARI_BAIT` | `ItemUseBait` | Safari pseudo-action; raw injected normal-bag use also changes catch/factor state and does not remove inventory. |
| `$16` | `CASCADEBADGE` / `SAFARI_ROCK` | `ItemUseRock` | Safari pseudo-action; raw injected normal-bag use also changes catch/factor state and does not remove inventory. |
| `$17` | `THUNDERBADGE` | `UnusableItem` | Battle reject. |
| `$18` | `RAINBOWBADGE` | `UnusableItem` | Battle reject. |
| `$19` | `SOULBADGE` | `UnusableItem` | Battle reject. |
| `$1A` | `MARSHBADGE` | `UnusableItem` | Battle reject. |
| `$1B` | `VOLCANOBADGE` | `UnusableItem` | Battle reject. |
| `$1C` | `EARTHBADGE` | `UnusableItem` | Battle reject. |
| `$1D` | `ESCAPE_ROPE` | `ItemUseEscapeRope` | Battle reject. |
| `$1E` | `REPEL` | `ItemUseRepel` | Battle reject. |
| `$1F` | `OLD_AMBER` | `UnusableItem` | Battle reject. |
| `$20` | `FIRE_STONE` | `ItemUseEvoStone` | Battle reject. |
| `$21` | `THUNDER_STONE` | `ItemUseEvoStone` | Battle reject. |
| `$22` | `WATER_STONE` | `ItemUseEvoStone` | Battle reject. |
| `$23` | `HP_UP` | `ItemUseVitamin` | Battle reject. |
| `$24` | `PROTEIN` | `ItemUseVitamin` | Battle reject. |
| `$25` | `IRON` | `ItemUseVitamin` | Battle reject. |
| `$26` | `CARBOS` | `ItemUseVitamin` | Battle reject. |
| `$27` | `CALCIUM` | `ItemUseVitamin` | Battle reject. |
| `$28` | `RARE_CANDY` | `ItemUseVitamin` | Battle reject before the routine falls through to medicine logic. |
| `$29` | `DOME_FOSSIL` | `UnusableItem` | Battle reject. |
| `$2A` | `HELIX_FOSSIL` | `UnusableItem` | Battle reject. |
| `$2B` | `SECRET_KEY` | `UnusableItem` | Battle reject. |
| `$2C` | `ITEM_2C` | `UnusableItem` | Battle reject. |
| `$2D` | `BIKE_VOUCHER` | `UnusableItem` | Battle reject. |
| `$2E` | `X_ACCURACY` | `ItemUseXAccuracy` | Battle use; repeated use still removes the item and commits the action. |
| `$2F` | `LEAF_STONE` | `ItemUseEvoStone` | Battle reject. |
| `$30` | `CARD_KEY` | `ItemUseCardKey` | Battle reject in stock code; the source-annotated routine is broken and falls to `ItemUseNotTime`. |
| `$31` | `NUGGET` | `UnusableItem` | Battle reject. |
| `$32` | `ITEM_32` | `UnusableItem` | Battle reject. |
| `$33` | `POKE_DOLL` | `ItemUsePokeDoll` | Contextual: succeeds only when `wIsInBattle == 1`; normal wild menu commits escape/removal, sets only the escape flag, and normally leaves raw result zero. |
| `$34` | `FULL_HEAL` | `ItemUseMedicine` | Battle use if target has any nonvolatile status. |
| `$35` | `REVIVE` | `ItemUseMedicine` | Battle use on a fainted target; restores its gain-EXP bit iff its fought-current-enemy bit survived fainting. |
| `$36` | `MAX_REVIVE` | `ItemUseMedicine` | Battle use on a fainted target; restores its gain-EXP bit iff its fought-current-enemy bit survived fainting. |
| `$37` | `GUARD_SPEC` | `ItemUseGuardSpec` | Battle use; repeated use still removes/commits. |
| `$38` | `SUPER_REPEL` | `ItemUseSuperRepel` | Battle reject. |
| `$39` | `MAX_REPEL` | `ItemUseMaxRepel` | Battle reject. |
| `$3A` | `DIRE_HIT` | `ItemUseDireHit` | Battle use; repeated use still removes/commits. |
| `$3B` | `COIN` | `UnusableItem` | Battle reject. |
| `$3C` | `FRESH_WATER` | `ItemUseMedicine` | Battle use on a living, non-full-HP target. |
| `$3D` | `SODA_POP` | `ItemUseMedicine` | Battle use on a living, non-full-HP target. |
| `$3E` | `LEMONADE` | `ItemUseMedicine` | Battle use on a living, non-full-HP target. |
| `$3F` | `S_S_TICKET` | `UnusableItem` | Battle reject. |
| `$40` | `GOLD_TEETH` | `UnusableItem` | Battle reject. |
| `$41` | `X_ATTACK` | `ItemUseXStat` | Battle use; item is removed before stat-effect success/cap handling. |
| `$42` | `X_DEFEND` | `ItemUseXStat` | Battle use; item is removed before stat-effect success/cap handling. |
| `$43` | `X_SPEED` | `ItemUseXStat` | Battle use; item is removed before stat-effect success/cap handling. |
| `$44` | `X_SPECIAL` | `ItemUseXStat` | Battle use; item is removed before stat-effect success/cap handling. |
| `$45` | `COIN_CASE` | `ItemUseCoinCase` | Battle reject. |
| `$46` | `OAKS_PARCEL` | `ItemUseOaksParcel` | Battle reject as “not yours to use.” |
| `$47` | `ITEMFINDER` | `ItemUseItemfinder` | Battle reject. |
| `$48` | `SILPH_SCOPE` | `UnusableItem` | Battle reject; possession is checked separately by ghost battle logic. |
| `$49` | `POKE_FLUTE` | `ItemUsePokeFlute` | Battle use; scans six fixed party slots and both active statuses, and commits even on its no-effect message path. |
| `$4A` | `LIFT_KEY` | `UnusableItem` | Battle reject. |
| `$4B` | `EXP_ALL` | `UnusableItem` | Battle reject; passive possession changes faint-time EXP handling. |
| `$4C` | `OLD_ROD` | `ItemUseOldRod` | Battle reject through `FishingInit`. |
| `$4D` | `GOOD_ROD` | `ItemUseGoodRod` | Battle reject through `FishingInit`. |
| `$4E` | `SUPER_ROD` | `ItemUseSuperRod` | Battle reject through `FishingInit`. |
| `$4F` | `PP_UP` | `ItemUsePPUp` | Battle reject. |
| `$50` | `ETHER` | `ItemUsePPRestore` | Battle use with party/move target when PP can be restored. |
| `$51` | `MAX_ETHER` | `ItemUsePPRestore` | Battle use; full-byte PP-Up comparison affects no-effect detection. |
| `$52` | `ELIXER` | `ItemUsePPRestore` | Battle use with party target when any move PP can be restored. |
| `$53` | `MAX_ELIXER` | `ItemUsePPRestore` | Battle use; full-byte PP-Up comparison affects per-slot no-effect detection. |

## IDs outside the table

- `NO_ITEM = $00` underflows the table index if dispatched directly.
- Floor/menu constants `$54`–`$61` and the remaining `$62`–`$C3` gap are below `HM01` but beyond the 83-entry pointer table. `UseItem_` therefore reads a pointer from unrelated following ROM bytes for such malformed bag IDs.
- HM/TM IDs `$C4` and above branch to `ItemUseTMHM`, which rejects use while `wIsInBattle != 0`.

Canonical bag/action validation should admit indexed ordinary items and valid HM/TM IDs according to the selected inventory policy, reject the malformed gap at the API boundary, and leave arbitrary-byte behavior to low-level/raw-state theorems.

## Cross-cutting proof obligations

- Link, Safari, Old Man, and normal bag reachability are proved separately from handler behavior.
- Rejection, cancellation, item removal, and turn consumption are separate outputs.
- Player status cures preserve the branch-specific active-stat and Toxic bugs.
- Revive/Max Revive preserve the two-byte participation protocol: faint clears gain eligibility but not fought memory, and revival conditionally restores gain eligibility for the same enemy.
- Poke Doll's zero-result escape reaches the non-link Pay Day/evolution scan, unlike ordinary Run.
- Old Man Ball restores `wPlayerName` from the aliased `wGrassRate`/link-name buffer but leaves that wild-encounter buffer overwritten; it skips storage and bag removal.
- Successful balls retain equality-only party/box capacity tests, capture naming, pre-name partial storage/resource state, party append versus slot-1 box insertion/shifts, and exact post-name construction; malformed counts remain raw-state cases.
- Raw-only Pokédex/Surfboard/badge-alias paths receive explicit coverage dispositions even if legal inventory generators never emit them.
- All table rows and the HM/TM boundary are decoded from ROM and covered by byte-equality theorems.
