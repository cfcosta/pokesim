# Campaign trainer battles controlled by the learned link policy

<!-- mode: explanation -->

## Decision

The campaign deployment replaces the opponent controller in campaign **trainer
battles only**. Wild encounters, Safari encounters, the Old Man tutorial, and
ordinary cartridge-to-cartridge link sessions retain their stock controllers
and flows.

A replaced trainer battle uses link-battle combat semantics rather than ordinary
trainer-battle combat semantics. The patched cartridge keeps the campaign as the
outer shell, but the battle itself uses:

- `wLinkState = LINK_STATE_BATTLING`;
- the stock link `BattleRandom` list and update rule;
- simultaneous move and switch commitments through the link action dictionary;
- link-mode ordering, status, switching, and damage behavior;
- no player or trainer items;
- no voluntary trainer or player forfeit in the initial profile;
- no battle EXP, prize money, badge boosts, or stock trainer action AI.

Campaign progression is composed outside that link battle. A win must return to
the trainer script in a form that marks the trainer defeated and permits the
map script to continue. Level progression can be supplied outside battle with
Rare Candies or another explicitly versioned reward rule. The reward mechanism,
trainer-party rebalance, and loss/blackout policy remain product decisions.

The deployment profile is named `campaign-trainer-link-ai-v1`. It is a patched
single-cartridge profile, not the stock paired-cartridge profile and not an
ordinary trainer battle with only its RNG replaced.

The faster browser-first target is the separate
[`web-random-6v6-link-ai-v1`](web-random-6v6-exhibition.md) exhibition profile.
It boots directly into a random level-100 6v6 battle and reuses the same model,
link action bridge, and emulator adapter without campaign progression.

## Why the stock trainer AI is not the integration boundary

Pokémon Red does not have one routine that owns every enemy decision.
`AIEnemyTrainerChooseMoves` scores move slots, while `TrainerAI` may replace a
selected move with an item or switch immediately before enemy execution. In
link mode, `TrainerAI` returns without acting. In ordinary trainer mode these
routines also run after the player has interacted with the battle menu, and the
execution-time action AI may run after the player's move.

Hooking `TrainerAI` would therefore miss ordinary move selection, retain
trainer-specific item behavior, and risk conditioning the model on a player
action that should still be hidden.

The important canonical symbols are:

| Symbol | Address | Role |
|---|---:|---|
| `MainInBattleLoop` | `0f:4233` | turn-level battle loop |
| `DisplayBattleMenu` | `0f:4eb3` | player decision UI |
| `MoveSelectionMenu` | `0f:5219` | player move-slot UI |
| `SelectEnemyMove` | `0f:5564` | stock enemy/link action selection |
| `LinkBattleExchangeData` | `0f:5605` | link action exchange and wire encoding |
| `ReplaceFaintedEnemyMon` | `0f:4664` | opposing forced replacement |
| `ChooseNextMon` | `0f:47d8` | local forced replacement UI |
| `TrainerAI` | `0e:652e` | non-link item/switch substitution |

The patched profile creates the model request at a pre-player-action checkpoint,
caches the response, and makes `LinkBattleExchangeData` consume the cached
remote action instead of waiting for a physical serial peer. Forced replacement
and typed nested requests require their own request classifications; they must
not be inferred from a generic move-selection hook.

## Runtime architecture

The intended runtime has one patched ROM in one browser emulator and direct
network inference on a backend:

```text
browser worker
  patched Pokémon Red in SameBoy/WASM
  video, audio, save RAM, and human joypad input
  symbol/request monitor and ROM-state projection
  cached remote action bridge
          |
          | versioned observation request over WebSocket
          v
backend
  ROM observation validation
  492-field side-canonical feature vector and legal mask
  policy/value checkpoint inference
  legal sampled or selected action
```

Tree search remains a training-time teacher by default. Promotion and deployment
use the distilled network policy directly, so a playable turn requires one
backend inference rather than hundreds of emulator branches.

SameBoy is the preferred emulator core because it is the project's pinned
independent DMG-B differential oracle, is Expat/MIT licensed, supports link
serial callbacks, and exposes ROM loading, joypad control, memory inspection,
execution callbacks, video, audio, battery saves, and save states. It does not
provide the required product-specific browser bridge; a small pinned
Emscripten/WASM wrapper remains necessary.

## Action timing and information boundary

The model must never receive the player's current menu selection. A normal
request has this ordering:

1. The patched ROM reaches the trainer-AI request checkpoint before displaying
   or accepting the player's action.
2. The adapter projects the model observation and legal action mask.
3. The backend returns and the ROM caches one enemy action.
4. The player chooses a move or switch.
5. The patched link exchange supplies both committed actions to the stock link
   battle path.

This preserves simultaneous choice even though one cartridge renders the whole
battle. Reading `wPlayerSelectedMove` after menu interaction and then querying
the model is forbidden. Tests must deliberately vary the player's later action
while asserting that the previously emitted model request is byte-identical.

The current policy is perfect-information. It receives both complete parties,
including information a human cannot see through the battle UI. This matches the
training profile and must be disclosed as part of the initial exhibition
profile. A fair player-information policy is a separate future profile.

## ROM patch boundary

The canonical base ROM is identified by:

| Artifact | Value |
|---|---|
| Size | 1,048,576 bytes |
| SHA-1 | `ea9bcae617fdf159b045185467ae58b2e4a48b9a` |
| SHA-256 | `5ca7ba01642a3b27b0cc0b5349b52792795b62d3ed977e98a09390659af96b7b` |

The locally available `Pokemon Red (UE) [S][!].gb` member was checked against
both canonical digests. The ROM must not be committed to this repository. A
public deployment should accept a user-supplied canonical image, hash-check it
in the browser, and apply a versioned BPS patch. A private deployment may load
an authorized local image, but the patched result still needs its own SHA-256,
build manifest, symbols, and profile identifier.

The patch has four responsibilities:

1. Detect a normal campaign trainer encounter and enter the dedicated AI-link
   battle wrapper. Wild and existing link paths do not enter this wrapper.
2. Initialize the link random-number list under the stock rejection law, choose
   and record the virtual internal/external clock role used by equal-Speed
   ordering, and reset the list index.
3. Replace serial remote-action receipt with the cached backend action while
   retaining stock link action decoding and combat branches.
4. Translate the link terminal result back into campaign trainer-script control,
   clear bridge state, and preserve save/overworld invariants.

A single cartridge can reproduce the selected shared-list law and link combat
branches, but it does not literally execute two SM83 machines or stock cable
setup. Claims must therefore say "patched synchronized link battle", not
"unmodified paired-cartridge battle". Paired-cartridge trace comparison remains
an independent validation gate.

## Model and inference contract

The current training profile is `full-link-party-1to6-perfect-v2` with schema
`full-link-party-state-v4`. The network consumes 492 unsigned scalar fields and
a legal mask. V4 distinguishes absent and fainted party slots with two party
counts, twelve presence bits, and zero descriptors for absent members.

The stable action dictionary remains:

| IDs | Meaning | Campaign trainer deployment |
|---:|---|---|
| `0..3` | fight slots | enabled when legal |
| `4..9` | switch to party slots `0..5` | enabled when legal |
| `10` | typed no-action continuation | enabled only when forced |
| `11` | Struggle | enabled only when forced |
| `12` | run/forfeit | disabled initially |

Trainer items do not need a new output head because link mode makes them illegal.
The backend validates schema version, patched-ROM profile, checkpoint hash,
request identity, feature width, and legal mask before inference. The response
contains the same request identity and one legal action ID. Future RNG bytes are
never model input.

## Training consequences

The core training method does not change for campaign trainer deployment:

- simultaneous matrix-tree search with RM+ remains the policy-improvement
  operator;
- terminal win/loss remains the value target;
- the 13-action policy and scalar value heads remain sufficient;
- side-canonical encoding lets the same network control the ROM's enemy side;
- BF16 execution and FP32 losses, outputs, parameters, and optimizer state remain
  unchanged.

Variable party support is required because campaign parties are not always
six-member. It is now represented by the 492-field v4 schema. Production data
rotates through every ordered `1v1` through `6v6` pairing, zeroes absent party
and switch descriptors, and supplies explicit party counts and presence bits.
Promotion is stratified across 1–2, 3–4, 5–6, unequal-party, and fixed campaign
team buckets so aggregate 6v6 strength cannot hide smaller-team regressions.

Self-play strength and human difficulty are related but not identical. The
population includes historical checkpoints, aggressive and switch-heavy
heuristics, and one named policy projection for each of Red's 47 trainer-class
rows. These projections retain cartridge move scoring, biased slot selection,
and representable switch branches. They map trainer-item decisions back to move
selection because items and the stateful per-send-out action counter are outside
the 13-action link profile; `Battle.Full.TrainerController` remains the exact
trainer-mode model. Human transcripts can be added later under the same
observation contract. Team construction remains outside the battle-control
policy. Trainer rosters and levels will therefore be a separate difficulty
layer, and a weak one-member campaign roster can remain easy despite a strong
controller.

A 478-field v3 checkpoint can warm-start v4 by copying compatible tensors and
existing positional rows, but it is not directly compatible with the deployment
schema.

## Verification gates

A playable prototype is not yet evidence of ROM/model equivalence. The deployment
needs at least these executable gates:

- canonical base and patched ROM hash checks;
- exact request timing and player-selection noninterference tests;
- ROM-state projection tests against `FullTraining.featureVector`;
- action legality and wire-encoding tests for moves, voluntary switches, forced
  replacement, no-action, and Struggle;
- link random-list initialization, update, replay, and clock-role tests;
- turn-by-turn patched-ROM traces compared with the synchronized Lean model;
- terminal bridge tests for trainer win, player loss, simultaneous faint, and
  nonfinish/divergence;
- campaign script, event flag, save RAM, and overworld continuation tests;
- stratified policy promotion against held-out campaign parties;
- paired-cartridge differential tests for the known synchronized-quotient gap.

## Open product decisions

The following choices were deliberately not fixed by the architecture decision:

- whether every trainer keeps its stock roster, receives level scaling, or gets
  a curated larger party;
- how and when Rare Candies are granted;
- whether a loss uses ordinary blackout, restores the pre-battle save, or offers
  an immediate rematch;
- whether inference samples the policy or uses deterministic selection at each
  difficulty level;
- whether the UI shows policy probabilities, value, or model diagnostics;
- whether a later fair mode hides unseen opponent information;
- whether a later implementation replaces the patched action bridge with a
  literal second cartridge or a complete stock serial peer.

These choices change game design or claim scope. They do not change the initial
battle-control contract above.
