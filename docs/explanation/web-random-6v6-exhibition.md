# Browser exhibition with random level-100 teams

<!-- mode: explanation -->

## Decision

The browser's quickest playable mode is a dedicated exhibition ROM profile that
boots directly into a model-controlled battle. It does not show the title menu,
load a campaign save, or require the player to walk to an encounter.

Every new match has:

- exactly six Pokémon on the human side and six on the model side;
- every Pokémon at level 100 and full HP;
- independently generated, legal Gen-I parties;
- patched synchronized link-battle mechanics;
- no items, EXP, money, capture, or voluntary forfeit;
- one human controller and one backend policy controller;
- a replayable server trace of teams, committed actions, events, and outcome;
- a result screen followed by a one-button rematch with a new seed and teams.

This deployment profile is `web-random-6v6-link-ai-v1`. It is separate from
`campaign-trainer-link-ai-v1`: both profiles share the action bridge, model
adapter, link RNG, and inference service, but only the campaign profile has
trainer event flags, overworld continuation, saves, and progression rewards.
The exhibition should be implemented first because it exercises the difficult
battle and inference boundary without also requiring campaign-script surgery.

## Boot and match lifecycle

"Boot directly into battle" still requires a short setup handshake because the
browser must connect to inference and obtain replayable teams. The patched ROM
therefore boots to a minimal `PREPARING BATTLE` state rather than to the stock
intro. The intended lifecycle is:

1. The page hash-checks the user-supplied canonical ROM, applies the exhibition
   BPS patch, and starts SameBoy in a worker.
2. The wrapper chooses a session seed and requests a versioned match manifest.
3. The team service deterministically creates two six-member level-100 parties,
   an independent link battle RNG list, and a virtual clock role.
4. At a patched setup rendezvous, the wrapper copies the manifest into a reserved
   staging block. The ROM validates its profile, length, and checksum before
   constructing the two stock party representations.
5. The ROM enters `wLinkState = LINK_STATE_BATTLING`, sends out both leads, and
   reaches the pre-player-action model request checkpoint.
6. Battle decisions use the same cached backend-action bridge as the campaign
   profile.
7. A terminal result produces `YOU WIN` or `YOU LOSE`. The backend finalizes the
   immutable trace with terminal or interruption provenance.
8. Rematch returns to step 2 without entering the overworld or reading save RAM.

The page must not mutate arbitrary battle WRAM after setup. A narrow, versioned
staging protocol gives the ROM one auditable place to accept external party and
RNG data. Its exact address is assigned from the patched linker's `.sym` and
`.map` outputs rather than hard-coded against the canonical ROM.

If inference or team setup is unavailable, the ROM remains on the preparation
screen and the page reports the connection failure. It must not silently fall
back to stock trainer AI or start a battle with a partial party.

## Random-team contract

The initial distribution is a fixed-level variant of the existing
progression-witnessed legal-team generator:

- party size is fixed at six;
- origin level is fixed at 100 rather than sampled;
- species, DVs, evolution outcomes, ordered TM/HM teachings, replacement slots,
  and PP Ups are seed-derived;
- moves begin with the exact level-100 `WriteMonMoves` result and change only
  through replayable compatible machine-teaching events;
- each side receives its own explicit party-wide ledger of one copy of every TM,
  all HMs, and eighteen PP Ups;
- initial status and stat stages are clear, HP and PP are full, and stat
  experience is zero;
- duplicate species remain legal, matching Gen-I party rules;
- both sides are sampled independently from the same versioned distribution.

"Random" does not imply mathematically uniform species, teams, movesets, or
matchups. The generator manifest records its algorithm version and stream IDs,
and the UI should describe the teams as seed-generated unless uniformity is
separately established.

Team entropy and battle entropy are separate. A seed expands into disjoint
streams for the human party, model party, initial shared link random list, and
virtual clock role. A battle can then be reproduced from the profile version,
generator version, checkpoint hash, and root seed. Neither side gets to reroll a
team after seeing the matchup; rematch always creates a fresh complete match.

The initial active Pokémon is slot zero on each generated team. Changing lead
selection into a simultaneous pre-battle decision is a future protocol change,
not an invisible generator tweak.

## Model boundary

The battle policy uses the existing `full-link-party-state-v4` observation and
13-action dictionary. Although the schema supports asymmetric parties from one
to six, every initial exhibition request has both party counts set to six and
all twelve presence bits set. Presence changes only when interpreting later
state; a fainted member remains present.

The model is queried before the player selects an action. The response is cached
and consumed through patched link action exchange after the player's commitment.
The model receives both full parties because the current checkpoint is
perfect-information. The human sees their own party through the stock battle
menus; the page should disclose that the AI knows both teams.

The production checkpoint needs an explicit held-out
`web-random-l100-6v6` promotion bucket. Variable-party aggregate strength is not
sufficient evidence that the model is strong on the exact public exhibition
distribution.

## Learning from user battles

The backend records each match under the versioned
[human battle trace contract](human-battle-trace-training.md). A trace includes
the exact generated teams, deployment and checkpoint hashes, pre-player model
request and response, later human commitment, legal masks, semantic events, RNG
transitions, state fingerprints, and terminal or interruption reason. It excludes
ROM bytes, save RAM, raw keypresses, video, audio, and unrelated browser data.
Collection must be disclosed before play.

User decisions are not blindly copied into the policy. Valid traces are replayed
through the Lean environment, and their encountered states are relabeled by the
same simultaneous matrix-tree search used for self-play. This lets humans expose
model weaknesses and useful states without teaching every misclick or pretending
that a human action used the model's perfect-information observation. Human
behavioral cloning is a separate player-view experiment.

Trace capture is asynchronous after each semantic transition and must not delay
battle input. A disconnect preserves a partial trace with no fabricated terminal
label. Only server-sequenced, legality-checked, deterministically replayed traces
can enter a bounded human-state replay mixture.

## Shared and profile-specific ROM work

The exhibition and campaign builds should come from the same patch source tree
with explicit build-time profiles, producing different BPS files and patched-ROM
hashes.

Shared code includes:

- external setup/request rendezvous conventions;
- stock link random-list initialization and virtual clock role;
- pre-player-action observation checkpoint;
- cached remote action validation and link wire decoding;
- forced replacement, no-action, Struggle, and typed nested requests;
- SameBoy/WASM callbacks and the backend inference protocol.

Exhibition-only code includes:

- bypassing intro, menus, save loading, and overworld initialization;
- accepting two generated parties through the setup staging block;
- entering a battle with no campaign trainer object;
- rendering a terminal result and requesting a rematch.

Campaign-only code includes encounter filtering, trainer presentation, event
flags, overworld restoration, loss handling, and external progression rewards.
Keeping the profiles separate prevents the exhibition boot shortcut from
becoming an undocumented campaign behavior.

## Verification gates

In addition to the shared deployment gates, the exhibition requires tests that:

- both decoded parties contain exactly six present level-100 Pokémon;
- every party replays from its recorded progression history and passes canonical
  legality;
- ROM party bytes and the Lean `MonState` values agree for species, stats, DVs,
  moves, packed PP, status, HP, and order;
- setup entropy cannot overlap the battle RNG stream;
- the same seed and version tuple reproduces the same complete match manifest;
- corrupt, truncated, stale-profile, and wrong-checksum manifests fail closed;
- the ROM cannot accept player input before the first model action is cached;
- win and loss both reach the rematch state without touching campaign save data;
- repeated rematches do not retain HP, status, PP, disabled moves, active slots,
  or random-list position from the previous match;
- server traces retain precommit ordering, replay exactly, and distinguish
  terminal results from disconnects and bridge failures;
- trace collection adds no blocking work to the joypad or rendering path;
- held-out human-versus-policy sessions meet latency, completion, and difficulty
  targets.

## Later options

A team preview, manual team builder, challenge seed, best-of series, hidden-team
policy, ranked ladder, or literal second cartridge can be added as separately
versioned modes. None is required for the first boot-to-battle exhibition.
