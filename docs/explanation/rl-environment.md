# RL environment design

<!-- mode: explanation -->

The RL environment should be a thin client of the verified high-level battle semantics. Training concerns such as reward shaping, curriculum, opponent sampling, and tensor layout must not leak into the mechanics core. The proposed actor–learner and search system built around this boundary is described in [Self-play training pipeline](self-play-training-pipeline.md).

## Environment boundary

The battle core is a pure request/response machine:

```text
initial configuration
  → pending request + legal responses + observation
  → validated response
  → zero or more automatic mechanics transitions
  → next battle request, ending/epilogue request, or returned episode result
```

A request can ask for:

- a player battle action;
- a link opponent action;
- an item target, including a move slot for Ether/Max Ether;
- the target move copied by ordinary player Mimic;
- a replacement after fainting or the wild-battle choice to try running instead;
- a shift-style response before the next trainer Pokémon;
- a move to forget or a decision not to learn;
- the nickname/default-name result for a successfully captured party/box member;
- whether to cancel an evolution reached by the battle driver;
- a mechanics-visible selection edit such as move or bag reordering;
- an ordinary mechanics-random byte.

Link `BattleRandom` is not an external per-draw request: reset supplies each cartridge perspective's post-setup ten-byte block, and each draw/first-nine update is a deterministic mechanics transition recorded in events/transcripts. A synchronized pair may share storage as an optimization only while a proved invariant permits it.

Trainer AI and wild enemy move selection are internal controller policies implemented from the ROM. Self-play can replace those policies with external action requests, but that is an explicit battle configuration.

The returned state is the battle-driver boundary. It precedes caller-specific behavior such as cable-club `HealParty`, blackout money/heal/warp, trainer map flags, and Old Man script cleanup. An integration adapter may compose those transitions, but must label the wider endpoint explicitly. See [End-to-end closure](../reference/end-to-end-closure.md).

## Action space

Use a structured action internally and a stable integer encoding at the adapter boundary.

```lean
inductive ItemTarget
  | none
  | partyMon (partyIndex : Fin 6)
  | partyMove (partyIndex : Fin 6) (moveSlot : Fin 4)

inductive Action
  | useMove (slot : Fin 4)
  | continueLockedFight
  | switch (partyIndex : Fin 6)
  | useItem (bagSlot : BagIndex) (target : ItemTarget)
  | run
  | safariBall
  | safariBait
  | safariRock
  | safariRun

inductive DecisionResponse
  | chooseReplacement (partyIndex : Fin 6)
  | tryRunAfterFaint
  | chooseMimicMove (slot : Fin 4)
  | switchBeforeTrainerSendOut (partyIndex : Fin 6)
  | stayBeforeTrainerSendOut
  | forgetMove (slot : Fin 4)
  | declineMove
  | setCaptureNickname (name : NicknameBytes)
  | useDefaultCaptureName
  | allowEvolution
  | cancelEvolution
  | highlightMove (slot : Fin 4)
  | cancelMoveMenu
  | highlightBagEntry (slot : BagIndex)
  | cancelBag
  | swapMoveSlots (left right : Fin 4)
  | swapBagSlots (left right : BagIndex)
```

Not every constructor is legal in every phase or battle kind. The core returns a finite legal set and proves it agrees with the high-level preconditions established from ROM behavior.

The integer protocol should reserve ranges by action kind rather than collapse different semantic choices into context-sensitive aliases. A schema version and action dictionary accompany snapshots and datasets.

### Protocol-invalid versus cartridge-ineffective

An out-of-range response or action of the wrong request kind is a caller error. It must not consume RNG, mutate state, or be converted to a random legal action.

A cartridge-selectable but ineffective attempt is different. Examples include a medicine with no effect, a full-box ball attempt, a prohibited trainer-battle run attempt, or canceling a submenu. These execute their exact failure/return branch and often produce another action request without consuming the turn. Legal masks should represent selectable responses; a separate `willCommitTurn` diagnostic may help agents but is not a mechanics rule.

Optional exploration wrappers may resample protocol-invalid outputs, but they remain outside the verified core.

Bag validation also needs an item-domain policy. IDs `$01`–`$53` have table entries, HM/TM IDs take a separate rejecting path in battle, and the `$54`–`$C3` gap would index beyond `ItemUsePtrTable` if injected into a malformed bag. Canonical reset modes should reject that gap; raw machine-state theorems preserve its control flow. See [Item dispatch](../reference/item-dispatch.md).

### Selection fidelity modes

`PrintMenuItem` updates selected-move scratch while the cursor merely highlights a move, and SELECT can reorder moves or bag entries. The core therefore retains a mechanics-visible selection state.

The default high-throughput adapter may offer **canonical commit mode**: each structured action is translated to one proved, minimal cartridge selection trace. A separate **full selection mode** exposes browse/cancel/reorder responses. Claims for canonical mode cover that controller subset; the unqualified ROM refinement theorem covers the full selection state machine.

## Forced and skipped actions

The top-level battle menu is fully bypassed for Rage, recharge, Thrash/Petal Dance, and charge-move continuation. Those paths can advance automatically.

Sleep, freeze, Bide, the player's trapping continuation, and being trapped are different: the cartridge still displays the top-level menu, so switch, item, and run remain possible. Choosing Fight in such a state commits `continueLockedFight` without asking for a move slot; status/lock execution then determines what happens.

Other nonstandard decision points include mandatory replacement, the wild-faint run-or-replace choice, post-KO shift style, Mimic target selection, capture naming, move learning/forgetting, and evolution cancellation. The wild-faint run response uses stored party-slot-1 Speed without active paralysis/stage/badge changes, not the fainted or prospective replacement member; the legal-action adapter must not “correct” that input.

Capture naming occurs after the owned Pokédex write/optional data display, before the capture action returns, and in the middle of storage mutation. At that request, an ordinary bag ball has not yet been removed, whereas the Safari Ball count was decremented before the throw. Party capture has already incremented count, appended species/terminator, and written OT when `AskName` begins, but builds the party record afterward. Box capture has already inserted/shifted species, OT names, and nicknames when `AskName` begins, but shifts/builds box records afterward. The request state therefore needs a pending capture transaction relating these partial byte layouts to one logical result. A canonical nickname response needs a proved naming-screen trace; the full cartridge theorem retains arbitrary valid controller traces and their timing.

Switch is likewise not one atomic array-index replacement in the cartridge proof. The concrete trace synchronizes outgoing HP/status, chooses variable recall text, mutates participation flags, performs a segmented active-state load, partially resets scratch/volatile state, and sends out the incoming member. The high-level switch response may collapse presentation only after proving that retained selected/loaded move scratch and low-level timing are preserved by projection.

Move learning is also a nested protocol rather than one flat choice. An empty slot learns automatically. A full moveset asks whether to learn, permits repeated slot selection, rejects HM deletion, lets B cancel back to an abandon-confirmation prompt, and can loop back to learning if abandonment is declined. Canonical `forgetMove`/`declineMove` responses require separate refinements to those concrete traces.

The environment should run automatic transitions only until a genuine cartridge decision point. It must still expose semantic events and random requests encountered along the way. Treating every round as one player action plus one opponent action is not sufficient. A terminal cause is witnessed when `StartBattle` exits and moves the state to `ending`, but the episode does not set `done` until payout, every `EvolutionAfterBattle`/move-learning decision, cleanup, restored caller fields, and outer return have completed. Simultaneous active faint is an event/order witness and may continue through reserves; it is not itself sufficient for `done`.

## Observations

Provide at least two explicit views.

### Perfect-information view

Used for debugging, planning, and symmetric self-play. It contains:

- both serialized parties;
- active indexes and active battle data;
- all status flags, counters, stages, screens, substitutes, and locked moves;
- move IDs and PP for both sides;
- battle kind, side to act, and phase (`battling`, `ending`, or returned); an ending terminal witness is distinct from final `done`;
- ordered inventory, badges, trainer AI state, run count, Safari factors, trainer prize/Pay Day totals, Pokédex flags, and evolution flags;
- mechanics-visible selection scratch, including highlighted/loaded move and slot-index state when priority, Counter, or PP mutation can observe it;
- RNG cursor metadata but not future random bytes; full link views expose both perspective cursors and synchronization status.

### Player-information view

Used when hidden information matters. It contains only information observable or remembered by the configured player model. Exact hidden-information policy must be versioned; Generation I's UI reveals some values and not others.

The mechanics theorem applies to full state. Observation correctness is a separate projection theorem:

```lean
observe (restore (snapshot s)) = observe s
```

No observation should include an uninitialized union interpretation.

## Events

Transitions return a semantic event stream, for example:

```text
ActionChosen
MoveUsed
MoveMissed
CriticalHit
DamageApplied
StatusApplied
StatStageChanged
ItemUsed
Switched
Fainted
ExperienceGained
MoveLearned
EvolutionStarted
Evolved
EvolutionCancelled
Captured
CaptureNamed
PokedexFlagSet
MoneyChanged
Escaped
BattleEnded
```

Events are not a replacement for state. They are useful for replay, diagnostics, curricula, and reward wrappers. Event ordering must follow the cartridge transition order.

An internal `TerminalWitnessed` transition retains the recognized edge while epilogue requests continue. `BattleEnded` is emitted only at returned episode completion and contains the terminal cause, optional simultaneous-faint ordering, raw result byte, pre-cleanup escape flag, and optional mode-specific verdict. This evidence cannot be reconstructed from final WRAM after `EndOfBattle` clears mode/escape fields. Rendering text and animation IDs may be optional metadata, but the stable event schema should not depend on English strings or tile routines. Cartridge divergence and adapter timeout are runner outcomes with diagnostics, not semantic battle events or outcomes.

## Rewards

No reward belongs in `Battle.step`. Separate wrappers can define:

- sparse win/loss reward;
- HP-difference shaping;
- capture reward;
- switch/action costs;
- curriculum-specific rewards;
- zero-sum self-play rewards.

This separation ensures that changing a training objective cannot change verified mechanics or invalidate replay transcripts.

## Randomness and replay

A training run provides an ordinary byte provider and, for link mode, the two post-setup cartridge seed blocks. Every episode can record:

- initial configuration hash;
- initial snapshot;
- external actions;
- ordinary random bytes and site labels;
- per-perspective link random responses/state and serial-choice exchanges;
- item-target, Mimic, capture-naming, selection browse/cancel/reorder, shift, move-learning, replacement, and evolution responses;
- terminal control-flow cause, raw/pre-cleanup fields, final outcome, and state hash.

Replay feeds this transcript back into the pure core. A mismatch reports the first divergent request, response index, event, and state field.

A seeded modern PRNG is acceptable for training. It gives deterministic game-mechanics execution, not physical Game Boy timing equivalence. See [RNG and time](rng-and-time.md).

## Team legality modes

Random teams need a named predicate. “Any species with four moves” is not enough.

### Battle-valid

The state satisfies battle-engine structural invariants:

- party count 1–6;
- active index in range;
- required living member for nonterminal reset;
- level/stat/HP fields fit their byte widths;
- move and type values are accepted by the selected raw-state policy;
- PP layout is structurally valid.

This mode may include MissingNo. indexes, impossible moves, malformed status combinations, or stats not reachable in ordinary play. It is for fuzzing and glitch research.

### Canonical species

Adds:

- one of the 151 ordinary species;
- level 1–100;
- valid base-derived types;
- derived stats and HP bounds;
- ordinary move IDs in a contiguous nonzero prefix followed by zero slots.

The contiguous-prefix rule matters to enemy move scoring after Transform: malformed leading-zero lists can diverge in the minimum-score loop. It does not require a history that could teach the selected moves.

### Learnset-legal

Adds a witness for every move:

- base move;
- level-up move available by the selected level;
- TM/HM compatibility;
- retained pre-evolution move through a supplied evolution history.

Stats are derived from level, DVs, and stat experience with the cartridge algorithm. PP is derived from move base PP and PP Up count.

This should be the default RL mode.

### Progression-witnessed

Adds a constructive history from a supplied initial roster/resource ledger:

- origin metadata;
- experience/training transitions;
- evolution transitions;
- move-learning/forgetting decisions;
- TM consumption, including one-use TM constraints across the whole party;
- supplied HM availability;
- item/badge resource state.

A generated history is its proof witness. It proves reachability under that ledger, not reachability from a new-game save. Proving the latter would require the out-of-scope map, gift, trade, capture-location, and item-acquisition systems.

### Trainer-defined

Builds exactly the enemy party that `ReadTrainer` constructs from trainer class/number, including:

- shared-level versus per-member-level formats;
- fixed trainer DVs;
- default level-derived moves;
- Gym Leader `LoneMoves` patches;
- Elite Four/champion `TeamMoves` patches;
- stale enemy-party PP bytes left by those post-construction patches and active PP regeneration on send-out;
- class AI count and move-choice layers.

## Generator design

Separate legality from distribution:

```lean
structure TeamDistribution where
  teamSizeWeights : ...
  speciesWeights : ...
  levelRange : ...
  dvPolicy : ...
  statExpPolicy : ...
  moveSelectionPolicy : ...
  duplicatePolicy : ...

Generator.generate :
  TeamDistribution → RandomBytes →
  Except GeneratorError { team : Team // LearnsetLegal team }
```

The theorem states generated teams are legal. It does not claim uniformity unless a separate probability proof is supplied.

The default sampler is `Battle.RL.DynamicGenerator.sample`. It consumes the
deterministic link RNG and samples party size, species, DVs, ordered machine
teachings, replacement slots, and PP Up counts. Each level-100 origin starts with
the exact ordered result of `WriteMonMoves`; later moves can arise only from a
compatible TM/HM event. One caller-supplied party-wide ledger consumes TMs once,
requires but does not consume HMs, and bounds PP Ups. `sampleSizedWithLedger`
returns both `{team // teamLegal Dex.gen1 .canonical team = true}` and a
`historyReplays` proof that the complete history reconstructs exactly that team
and its remaining ledger. Level 100 ensures every ordered level-up offer has
occurred; it no longer licenses arbitrary subsets of an unordered move pool. A
fail-closed, explicitly flagged recovery history prevents malformed entropy or a
future generator regression from emitting an unwitnessed episode reset.

Useful distributions include:

- uniform species, fixed level;
- base-stat-bucket balanced;
- type-balanced;
- trainer-party distribution;
- curriculum by team size and level;
- competitive fixed-level with constrained move quality;
- adversarial edge-case distribution for proof/differential testing.

Avoid rejection loops with unknown runtime in the hot path when a constructive sampler is available. If rejection sampling is used, record its generator transcript separately from the battle RNG transcript.

## Battle configurations

Recommended reset presets:

| Preset | Player controller | Opponent controller | Mechanics mode |
|---|---|---|---|
| `wild` | external agent | cartridge random move policy | ordinary wild battle |
| `trainer` | external agent | cartridge trainer AI | trainer battle |
| `selfPlay` | external | external | explicitly selected ordinary or paired-link mechanics; never assumed symmetric internally |
| `linkReplay` | transcript | transcript | paired cartridge perspectives, serial choices, and per-perspective link RNG |
| `safari` | external | cartridge Safari escape loop | Safari |
| `mechanicsFuzz` | scripted/property driver | scripted/property driver | battle-valid raw state |

`selfPlay` must not be called cartridge trainer AI. It is an environment controller configuration around the same move mechanics.

The first executable mechanics profile is `Battle.Ordinary`. It deliberately
admits only fresh active mons using nonzero-power `NO_ADDITIONAL_EFFECT` moves.
Within that boundary it retains exact move priority, Speed ties, PP decrement,
base-Speed critical thresholds, critical RNG rotation, damage-byte `rrca` and
`≥217` rejection, STAB/type adjustment, the 1/256 accuracy ceiling, HP
subtraction, and faint interruption. Unsupported effects, empty slots, zero PP,
and an exhausted RNG search are explicit results rather than approximated moves.

## Snapshot protocol

Snapshots should use a canonical, versioned byte format defined in Lean.

Required properties:

- `decode (encode s) = some s`;
- deterministic bytes for equal states;
- schema/version prefix;
- source ROM/mechanics version identifier;
- pending request and phase included;
- no host pointers, closures, or PRNG objects;
- ordinary provider state or semantic-transcript cursor stored by the adapter, while each link perspective's ten-byte block/index remains mechanics state;
- invalid or old snapshots fail explicitly.

For debugging, provide a structured JSON view derived from the canonical snapshot. JSON is not the proof boundary or high-throughput transport.

## Batching and performance

The instruction-level machine interpreter is too expensive for routine RL stepping. Training uses the extracted high-level Lean core whose equivalence has been proved.

Performance work should follow this order:

1. benchmark pure native Lean single-environment transitions;
2. benchmark snapshot encode/decode;
3. add in-process arrays of environments and `stepBatch`;
4. profile allocation in events and immutable structures;
5. choose transport based on measured overhead;
6. add a Python binding only after the batch API is stable.

Possible transports:

- native executable with a binary protocol;
- C ABI wrapper around compiled Lean;
- Python extension through a narrow C layer;
- shared-memory worker processes for large batches.

The adapter is allowed to optimize storage, but it must round-trip to the canonical `BattleState` and pass differential replay tests. An optimized mirror state must not become a second unverified simulator.

## Parallelism

Battles are independent between reset and step requests. Parallelize across environments, not inside one battle transition. Each ordinary environment owns one canonical state/snapshot, one ordinary random provider or semantic-transcript cursor, one event buffer, and one pending request.

A full link battle remains one schedulable environment but owns a **pair** of cartridge-perspective states, two link RNG blocks/cursors, and serial-exchange state. A synchronized quotient may accelerate common paths, but the canonical snapshot must expand to the pair so setup bugs and in-battle desynchronization remain representable.

## Training API sketch

A language-neutral batch request can look like:

```text
ResetRequest {
  mechanics_version
  battle_config
  player_team_spec
  opponent_team_spec
  generator_seed
  battle_rng_seed
  link_post_setup_blocks?  // two ten-byte blocks for link replay
}

StepBatchRequest {
  environment_ids[]
  action_ids[]
}

StepResult {
  observation
  legal_action_mask
  events
  terminal_outcome
  state_hash
  transcript_position
}
```

Keep generator and battle RNG seeds separate. Team sampling must not perturb battle randomness.

`Battle.RL.Environment` now provides the single-environment form of this API for
the ordinary one-mon profile: `reset`, `observe`, `legalActions`, `step`, `settle`,
and `done`. Reset teaches compatible ordinary TM/HM moves over exact natural
acquisition rows until all four slots are supported, retaining the replay proof
and remaining shared ledger in `ResetSide`; it never slices an unordered learn
pool. Legal masks contain only supported nonempty fight slots; invalid, inactive,
and RNG-stuck outcomes
are distinct. A faint enters `ending`, and only the separate no-op profile
cleanup `settle` enters `returned` and makes `done = true`.

`Battle.RL.SelfPlay` runs two policies over that interface with independent
exploration RNGs and records replay transitions. Its decision budget produces a
separate `truncated` stop reason and can never manufacture a battle terminal.
The `battleSelfPlay` executable runs 100 independently seeded random-policy
mirrors and fails on repaired reset, blocking, invalid action, or RNG-stuck
state.

`Battle.Full.Environment` and `Battle.Full.SelfPlay` provide the party-aware
protocol. Resets dynamically sample two proof-carrying parties of size 1–6;
legal actions include forced replacement, and same-action Mirror Move,
Metronome, and Mimic continuations do not consume another policy decision. The
`battleFullSelfPlay` smoke matrix accounts for every episode as either a returned
finite behavior or an explicitly horizon-open behavior. On the pinned matrix,
94 return and six remain open after 4,096 decisions; neither is relabeled as a
battle terminal.

## RL release checks

Before exposing a stable API:

- every action and decision-response ID has a documented typed meaning;
- legal masks agree with core validation for all reachable request types;
- protocol-invalid and cartridge-ineffective responses are tested as distinct outcomes;
- canonical commit mode is proved to implement its documented selection trace;
- snapshots round-trip by theorem and adapter test;
- transcript replay is deterministic;
- sampled episodes replay through the ROM-linked reference runner;
- reward wrappers do not import or mutate internal mechanics modules;
- batch and single-step outcomes are identical;
- terminal witnesses retain control cause/raw fields through `ending`; only returned outcomes set `done`, and both remain distinct from cartridge divergence;
- benchmark results include transitions/second, latency, allocations, and memory per environment.
