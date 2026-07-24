# Battle state model

<!-- mode: reference -->

This page maps assembly state into the proposed typed Lean state. It describes the pinned source; concrete addresses will be filled from the canonical `.sym` file during M0.

## Structural constants

| Constant | Value | Source |
|---|---:|---|
| Maximum level | 100 | `pokered/constants/battle_constants.asm` |
| Moves per Pokémon | 4 | `pokered/constants/battle_constants.asm` |
| Party capacity | 6 | `pokered/constants/pokemon_data_constants.asm` |
| Base stat-stage value | 7 | `pokered/constants/battle_constants.asm` |
| Maximum stat-stage value | 13 | `pokered/constants/battle_constants.asm` |
| Maximum calculated stat | 999 | `pokered/constants/battle_constants.asm` |
| Party Pokémon bytes | 44 (`$2C`) | `PARTYMON_STRUCT_LENGTH` |
| Box Pokémon bytes | 33 (`$21`) | `BOXMON_STRUCT_LENGTH` |
| Active battle Pokémon bytes | 29 | `battle_struct` in `pokered/macros/ram.asm` |
| Move-record bytes | 6 | `MOVE_LENGTH` |

Multi-byte Pokémon stats, HP, experience fields, and battle damage are manipulated in the ordering used by their assembly routines. The active and party two-byte numeric paths store high byte followed by low byte; DVs are two independently nibble-packed bytes rather than one big-endian integer. The CPU stack and instruction immediates follow SM83 little-endian rules; these are distinct concerns.

## Persistent party member

The party structure is defined by `party_struct`, which extends `box_struct`.

| Offset name | Width | Meaning |
|---|---:|---|
| `MON_SPECIES` | 1 | Internal species index |
| `MON_HP` | 2 | Current HP |
| `MON_BOX_LEVEL` | 1 | Box-level field; retained in party layout |
| `MON_STATUS` | 1 | Nonvolatile status byte |
| `MON_TYPE1`, `MON_TYPE2` | 2 | Stored types |
| `MON_CATCH_RATE` | 1 | Catch rate |
| `MON_MOVES` | 4 | Move IDs |
| `MON_OTID` | 2 | Original trainer ID |
| `MON_EXP` | 3 | Experience |
| five stat-experience fields | 10 | HP/Attack/Defense/Speed/Special stat experience |
| `MON_DVS` | 2 | Attack/Defense and Speed/Special nibbles |
| `MON_PP` | 4 | Current PP plus PP Up bits |
| `MON_LEVEL` | 1 | Current level |
| `MON_MAXHP` | 2 | Maximum HP |
| `MON_ATK` | 2 | Attack |
| `MON_DEF` | 2 | Defense |
| `MON_SPD` | 2 | Speed |
| `MON_SPC` | 2 | Special |

The party also has separate species-list, original-trainer-name, and nickname arrays. A party is not just `Array Mon`: its serialized representation includes count, species terminator, six fixed slots, OT strings, and nickname strings. Successful party capture appends across these parallel arrays after `AskName`; current-box capture instead inserts at slot 1 and shifts every parallel box array.

### PP byte

The low six bits are current PP. The high two bits count PP Up applications:

```text
bits 7..6: PP Up count
bits 5..0: current PP
```

Some routines correctly mask with `PP_MASK`; others inspect or mutate the full byte. The high-level model must preserve the raw byte and expose interpreted accessors.

### DVs

Two bytes contain four 4-bit DVs:

```text
byte 0 high nibble: Attack
byte 0 low nibble:  Defense
byte 1 high nibble: Speed
byte 1 low nibble:  Special
```

HP DV is reconstructed from the low bit of each of the four other DVs. Trainer Pokémon use fixed bytes `$98` and `$88`; ordinary wild Pokémon receive two random bytes.

## Active battle member

`battle_struct` contains:

| Field | Width | Notes |
|---|---:|---|
| species | 1 | Mutable under Transform |
| current HP | 2 | Copied to/from party at selected boundaries |
| party-position/box-level byte | 1 | Same offset has both labels; player loads copy the party `MON_BOX_LEVEL`, while the authoritative player index is `wPlayerMonNumber`; enemy send-out code writes `wEnemyMonPartyPos` explicitly |
| status | 1 | Nonvolatile status |
| types | 2 | Mutable under Conversion/Transform |
| copied catch rate | 1 | Part of the active structure, but capture/Safari use the separate `wEnemyMonActualCatchRate` byte |
| moves | 4 | Mutable under Mimic/Transform |
| DVs | 2 | Mutable under Transform |
| level | 1 | Current level |
| max HP, Attack, Defense, Speed, Special | 10 | Current in-battle stats |
| PP | 4 | Active move PP |

Player fields use the `wBattleMon*` prefix. Enemy fields use `wEnemyMon*`. `ReadPlayerMonCurHPAndStatus` and `SwitchEnemyMon` copy four contiguous bytes beginning at HP; consequently the aliased active byte is written back to `MON_BOX_LEVEL`. The enemy path stores its party index there. The complete phase/reset matrix is in [Switch, faint, and participation flow](switch-faint-and-participation.md).

Additional active metadata is stored outside the structure:

- `wBattleMonSpecies2`/`wEnemyMonSpecies2` identity fields, distinct from Transform-mutable active species;
- authoritative player/enemy party indexes;
- nickname buffers;
- enemy base stats, separate actual catch rate, and base experience;
- player/enemy selected move, selected slot, and menu/list indexes that may disagree after cancellation or disobedience;
- move-learning and capture-naming menu/input scratch while those nested protocols are active;
- pending capture-construction phase, including the owned Pokédex flag, deferred ordinary-ball removal versus prior Safari decrement, and pre-name partial party/box arrays;
- loaded six-byte player/enemy move records, including `CalcHitChance`'s destructive scaled-accuracy write;
- unmodified level/stats;
- six meaningful stat modifiers plus two padding slots;
- volatile status flags and counters.

## Nonvolatile status byte

| Bits | Constant | Meaning |
|---|---|---|
| 0–2 | `SLP_MASK` | Remaining sleep turns, values 0–7 |
| 3 | `PSN` | Poison |
| 4 | `BRN` | Burn |
| 5 | `FRZ` | Freeze |
| 6 | `PAR` | Paralysis |
| 7 | — | Unused by normal status definitions |

The implementation expects one nonvolatile status at a time, but the low-level byte model must permit malformed combinations for complete machine semantics.

## Volatile flags

### Battle status 1

| Bit | Name | Meaning |
|---:|---|---|
| 0 | `STORING_ENERGY` | Bide |
| 1 | `THRASHING_ABOUT` | Thrash/Petal Dance |
| 2 | `ATTACKING_MULTIPLE_TIMES` | Multi-hit action in progress |
| 3 | `FLINCHED` | Cannot act when checked |
| 4 | `CHARGING_UP` | Unbound continuation bit; the next path reloads retained selected slot rather than a stored generating move |
| 5 | `USING_TRAPPING_MOVE` | Wrap/Bind/Fire Spin/Clamp continuation |
| 6 | `INVULNERABLE` | Fly/Dig charging state |
| 7 | `CONFUSED` | Confusion active |

### Battle status 2

| Bit | Name | Meaning |
|---:|---|---|
| 0 | `USING_X_ACCURACY` | Bypass accuracy/evasion test |
| 1 | `PROTECTED_BY_MIST` | Mist/Guard Spec |
| 2 | `GETTING_PUMPED` | Focus Energy/Dire Hit |
| 3 | unused | Preserve raw value |
| 4 | `HAS_SUBSTITUTE_UP` | Substitute exists |
| 5 | `NEEDS_TO_RECHARGE` | Hyper Beam recharge |
| 6 | `USING_RAGE` | Rage lock |
| 7 | `SEEDED` | Leech Seed |

### Battle status 3

| Bit | Name | Meaning |
|---:|---|---|
| 0 | `BADLY_POISONED` | Toxic behavior |
| 1 | `HAS_LIGHT_SCREEN_UP` | Light Screen |
| 2 | `HAS_REFLECT_UP` | Reflect |
| 3 | `TRANSFORMED` | Transform active |
| 4–7 | unspecified here | Preserve raw value and classify during coverage audit |

## Counters and per-side transient values

Each side has or shares values for:

- number of attacks left;
- confusion counter;
- Toxic counter;
- disabled move and remaining turns packed into one byte;
- disabled move ID;
- Bide accumulated damage;
- multi-hit count;
- Substitute HP;
- last used move;
- selected move, selected slot, and loaded six-byte move record, including stale values left by cursor browsing;
- disobedience flag and action-selection cursor state;
- minimized display state, which affects animation but may also select presentation branches.

Send-out clears the volatile flag block and Disable bytes but leaves several counters stale; flags determine whether those counters are live. The Bide accumulated-damage storage aliases multi-hit scratch through WRAM unions. Those values are not simultaneously live under intended control flow. The low-level model keeps the bytes; the high-level invariant states which interpretation is live in each phase.

## Shared battle state

The following values are not naturally owned by one active Pokémon:

| State | Meaning |
|---|---|
| `wIsInBattle` | 0 none, 1 wild, 2 trainer; `$FF` is written later by overworld blackout dispatch, outside the selected battle-episode boundary |
| `wBattleType` | normal, Old Man, or Safari |
| `wBattleResult` | context-sensitive raw result byte; capture, Run, link draw, loss, and several zero-valued victory/escape paths cannot be decoded from this byte without mode and a control-flow witness |
| `hWhoseTurn` | 0 player, 1 enemy |
| `wActionResultOrTookBattleTurn` | item/switch/run action consumed player turn |
| `wDamage` | shared damage scratch; may be nominal, capped, stale, Substitute-related, or replaced by drain's half-damage value depending on phase |
| `wDamageMultipliers` | high bit STAB marker; low bits hold the most recently stored matchup-table multiplier, not necessarily net dual-type effectiveness |
| `wCriticalHitOrOHKO` | normal/critical/successful OHKO/failed OHKO |
| `wMoveMissed`, `wMoveDidntMiss` | shared move outcome flags |
| `wEscapedFromBattle` | move/Poke Doll escape flag, distinct from ordinary Run's result-byte writes |
| `wPartyGainExpFlags` | current EXP eligibility; faint clears a bit and Revive restores it only from the fought byte |
| `wPartyFoughtCurrentEnemyFlags` | participation memory for the current enemy; survives a member faint until enemy change/award completion |
| `wAICount` | remaining trainer action-AI uses for current Pokémon |
| `wAILayer2Encouragement` | enemy-execution counter used only when exactly 1; forced replacement clears it, voluntary AI switch retains it |
| `wLastSwitchInEnemyMonHP` | enemy send-out HP used by wrapped/dividing player-recall text selection and its timing |
| `wAmountMoneyWon` | three-byte BCD trainer prize computed from base payout and final enemy level |
| `wTotalPayDayMoney` | three-byte accumulated Pay Day money |
| `wNumRunAttempts` | wild escape attempt count |
| `wSafariEscapeFactor`, `wSafariBaitFactor` | Safari modifiers/durations |
| `wLinkBattleRandomNumberListIndex` | this cartridge perspective's link RNG cursor |
| `wLinkBattleRandomNumberList` | this cartridge's post-setup list; battle code cycles the first nine entries while retaining a tenth byte |

The exact terminal write matrix is in [Battle outcomes](battle-outcomes.md).

Several shared variables are intentionally reused across player and enemy actions. `wDamage`, for example, contributes to Counter and Bide behavior. `wPlayerSelectedMove` and most loaded player move-record bytes survive player send-out even though the selected-slot index and loaded move number are cleared; they can describe an outgoing or merely highlighted move and still affect same-turn Quick Attack/Counter order and Counter damage eligibility. These values must not be replaced by apparently cleaner per-side or last-committed-action fields without a proof.

## External state required by battle mechanics

A battle reset cannot be defined from two arrays of Pokémon alone. Relevant environment includes:

- battle kind and trainer class/number;
- player ID and Pokémon OT IDs for traded EXP/disobedience;
- badges for obedience and badge stat boosts;
- battle style for replacement prompts;
- ordered inventory entries and quantities, because the battle bag permits reordering;
- money, trainer payout, and Pay Day BCD behavior;
- Pokédex seen/owned bitsets mutated on enemy load and capture;
- current box count, ordered species list, records, OT names, and nicknames for capture slot-1 insertion;
- battle-exit handoff bytes written inside the driver, including encounter cooldown, destination warp ID, and the loss-path always-on-bike flag clear;
- caller presentation fields saved/restored by the outer battle wrapper: letter-delay flags, map palette offset, and tile-animation state;
- `wCanEvolveFlags` and post-battle evolution scratch until `EndOfBattle` completes;
- link clock role, exchanged parties, per-perspective post-setup random blocks, and serial exchange state;
- map/ghost flags for special Ghost/Marowak behavior;
- options only where they select a mechanics-visible path or timing boundary;
- external random/timer/input response stream.

The RL configuration may provide safe defaults, but the verified `BattleState` must represent every in-scope value explicitly or prove it irrelevant. Its canonical reset image also initializes bytes that `InitBattleVariables` leaves to prior `EndOfBattle` cleanup, including residual battle-status data and the caller-selected normal/Old Man `wBattleType`.

## Proposed Lean shape

The high-level representation should be typed but retain raw encodings at the boundary:

```lean
structure PartyMon where
  species : SpeciesId
  hp : U16BE
  boxLevel : UInt8
  status : StatusByte
  types : TypeId × TypeId
  catchRate : UInt8
  moves : Vector MoveId 4
  otId : U16BE
  exp : U24BE
  statExp : Vector U16BE 5
  dvs : DVBytes
  pp : Vector PPByte 4
  level : UInt8
  stats : Stats

structure ActiveMon where
  raw : BattleMonBytes
  unmodified : UnmodifiedStats
  stages : StageBlock
  volatile : VolatileState

structure TerminalWitness where
  cause : TerminalCause
  mode : BattleMode
  perspective : Side
  edge : TerminalControlEdge
  rawResult : UInt8
  preCleanupEscaped : UInt8
  simultaneousDetectedFirst : Option Side

inductive EpisodePhase
  | battling
  | ending (witness : TerminalWitness)
  | returned

structure BattleState where
  playerParty : Party
  enemyParty : Party
  player : ActiveMon
  enemy : ActiveMon
  shared : SharedBattleState
  persistent : BattlePersistentState -- bag, money, Pokédex, current box
  selection : SelectionState       -- mechanics-visible menu/action/naming/learning state
  pendingCapture : Option CaptureBuildState -- partial parallel-array mutation around AskName
  environment : BattleEnvironment
  exitHandoff : BattleExitHandoff
  phase : BattlePhase             -- fine-grained mechanics phase while battling/ending
  episodePhase : EpisodePhase     -- battling, ending(witness), or returned

structure LinkBattleState where
  left : BattleState
  right : BattleState
  serial : LinkExchangeState
```

A synchronized link invariant can relate `left` and `right`, but the representation must not quotient them into one state: source-reachable paths can desynchronize RNG cursors and duplicated views.

`U16BE` and `U24BE` are proposed wrappers with proved byte codecs. They prevent accidental endianness changes while allowing bounded arithmetic views.

A simultaneous active faint can be nonterminal when reserves remain. It is recorded as an event and optional terminal provenance, never used alone to set `returned`.

## Checkpoint invariants

The initial refinement proof should establish and use phase-indexed invariants rather than one oversized global predicate.

### Driver-entry/setup checkpoint

- PC/bank/stack/interrupt/hardware state forms a valid `InitOpponent` call frame;
- mode-specific reset bytes distinguish caller inputs from prior-cleanup invariants;
- trainer/wild/link loading and transition ranges have a coverage disposition;
- the first semantic state relation is established before `StartBattle` without pretending setup was external.

### Action-selection checkpoint

- ordinary/link move-selection phases have two nonzero active HP values; Safari/tutorial phases use their separate mode invariant;
- active party indexes are within counts where that mode has sent out an active member;
- active species match their selected party member unless transformed;
- current HP and nonvolatile status have been synchronized as required by the last transition;
- stages are within 1–13 for ordinary reachable play;
- phase-specific scratch aliases have one valid interpretation;
- pending action flags distinguish full-menu bypass from post-menu Fight-without-slot states;
- move/bag ordering, selected slot/list index, and loaded scratch reflect any prior browse, cancel, disabled-highlight, or reorder edits;
- `wNumRunAttempts` reflects whether Fight has been entered since the last failed run.

### Move-execution checkpoint

- selected move is a valid move ID, `STRUGGLE`, or `CANNOT_MOVE` as allowed by phase;
- selected slot points to that move when the action came from a slot;
- loaded move record corresponds to the phase's effective record after disobedience/Mirror Move/Metronome substitution; an unbound charge continuation instead reloads and executes the retained selected slot;
- `hWhoseTurn` selects the correct side;
- ordinary semantic-trace coupling and link RNG cursor/state agree with the high-level phase.

### Switch checkpoint

- outgoing HP/status and the aliased active party-position/box-level byte have been copied exactly where the source does so;
- incoming member is living and not already active;
- incoming active data is derived from the chosen party entry;
- new stat stages are 7 while the two padding bytes retain their source values;
- volatile flags/Disable reset while inactive counters and selected/loaded scratch follow the exact partial-reset matrix;
- participation flags distinguish ordinary switch accumulation from Shift/new-enemy reset;
- non-link enemy destination is the first living slot other than the outgoing index; link destination has a validated received selection.

### Pre-cleanup terminal checkpoint

- a recognized terminal control edge supplies a `TerminalWitness` and sets phase to `ending`, not returned;
- raw result and pre-cleanup escape bytes agree with the witness, without pretending they uniquely encode its cause;
- active state has been synchronized where that path calls `ReadPlayerMonCurHPAndStatus`, including player-faint status clearing; enemy-faint party status follows its separate path;
- no item target, Mimic, capture-naming, replacement, or shift request is pending.

### Post-epilogue return checkpoint

- final party HP/status/PP, experience, move order, and completed evolution mutations agree;
- ordered inventory, captured party/box data, Pokédex flags, trainer prize money, Pay Day, trainer-end-text/sprite handoff, and Old Man name/wild-buffer writes agree;
- the terminal witness is retained by the runner even though cleanup erased mode/escape discriminators;
- in link mode, each local player party is authoritative; the disposable mirrored enemy party reflects `EndOfBattle`'s status-only active-to-party copy rather than a fabricated HP synchronization;
- `EndOfBattle` cleanup, restored `wLetterPrintingDelayFlags`/`wMapPalOffset`/`hTileAnimations`, carry, bank/stack return, and battle-exit handoff fields agree;
- phase changes to `returned`; caller-specific blackout, trainer-map, cable auto-heal, and tutorial cleanup have not been fabricated into driver output;
- no move-learning or evolution request is pending.

## Codec proof obligations

For every projected structure:

1. decoding canonical well-formed bytes succeeds;
2. `decode (encode x) = some x` for typed values;
3. `encode (decode bytes) = bytes` under the byte-level well-formedness predicate;
4. field offsets match symbol-derived layout constants;
5. writes outside a field's byte range preserve its decode;
6. active/party copy routines imply the checkpoint synchronization relation.
