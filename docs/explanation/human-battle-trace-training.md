# Learning from browser battle traces

<!-- mode: explanation -->

## Decision

The browser exhibition records replayable human-versus-model battle traces so
those encounters can improve later checkpoints. Collection is part of the
`web-random-6v6-link-ai-v1` deployment contract, while ingestion is an offline,
versioned training stage. Live user traffic never updates the production model
in place.

A trace captures semantically committed battle decisions, not raw controller
keypresses. Completed, forfeited, disconnected, and failed matches are retained
with different terminal provenance. Partial traces can supply replayable states,
but they cannot be mislabeled as wins, losses, or draws.

The page must disclose collection before play. Consent version, retention,
delete policy, and any account association are product metadata. The training
artifact must not contain ROM images, BPS output, save RAM, video, audio, IP
addresses, browser fingerprints, or unrelated emulator memory.

## Authoritative trace boundary

The backend already owns the match manifest and every model inference. It should
therefore assemble the authoritative trace rather than trusting a complete file
uploaded by the browser after the match.

For each match:

1. The server creates a match ID, signed setup token, deterministic team
   manifest, battle seed, and model/checkpoint identity.
2. Each pre-player-action request receives a monotonic decision ID and nonce.
   The server records the model observation, legal mask, policy/value result,
   chosen action, and response time before the player acts.
3. The browser reports the later committed human action and resulting ROM state
   hash against that decision ID. The server rejects stale, duplicate, illegal,
   or out-of-order responses.
4. Semantic events, RNG cursor transitions, and next-request fingerprints are
   appended as the ROM advances.
5. The terminal record names a proved battle result or the exact interruption,
   timeout, bridge error, or differential mismatch.
6. The immutable completed object receives a content hash and is queued for
   replay validation. Training only reads validated objects.

The client remains an untrusted source. A modified page can report a human
choice, but it cannot choose teams, rewrite the model's earlier action, forge a
terminal outcome, or supply the feature vector used for training.

## Logical trace schema

The storage encoding can later move from JSONL to a measured binary format, but
its logical fields are stable and versioned.

### Header

- trace schema and consent versions;
- opaque match and optional rotating player IDs;
- base-ROM, BPS patch, emulator, deployment profile, mechanics, observation,
  action-dictionary, generator, and reward versions;
- checkpoint and model file SHA-256;
- root seed plus separate human-team, model-team, battle-RNG, and clock-role
  stream labels;
- exact party manifests, progression histories, and legality-witness hashes;
- virtual internal/external clock role and initial link random-list hash;
- server creation time and coarse client latency class where needed.

### Decision record

- monotonic decision ID, typed request, acting side, and turn coordinate;
- canonical mechanics-state fingerprint and ROM-state fingerprint;
- 492-field side-canonical observation, legal mask, and schema hash;
- model logits or normalized policy, value, selected action, checkpoint ID, and
  inference latency, recorded before the human commitment;
- human's later legal action and decision latency;
- semantic events, RNG cursor/list hashes, and resulting state fingerprint;
- explicit flags for forced replacement, no-action, Struggle, and nested
  requests.

### Trailer

- win/loss result with side orientation, or an exact nonterminal stop reason;
- final ROM and mechanics hashes;
- decision and turn counts;
- replay, projection, legality, and differential-validation status;
- content hash and any quarantine reason.

Full observations make audits and future import independent of a running
browser. Exact manifests, actions, and RNG transitions must still be sufficient
to regenerate those observations; stored tensors are checked data, not a second
source of mechanics truth.

## How traces become training data

Raw imitation is not the default. A player may be inexperienced, may misclick,
and acts with less information than the current perfect-information model. Blind
behavioral cloning would teach those errors and would falsely pair a
player-view choice with privileged opponent data.

The primary importer uses **search relabeling**:

1. Replay the complete action/event transcript through the synchronized Lean
   environment and reject the trace at its first mismatch.
2. Reconstruct each eligible pre-decision state without exposing future RNG.
3. Run the current simultaneous matrix-tree search from that state using fresh,
   independently derived search entropy.
4. Store the search strategies and root values as ordinary policy/value targets.
5. Add the resulting shard to a bounded human-state component of the replay
   mixture.

This uses people to discover relevant states, tactics, and failure modes while
retaining the same search teacher as self-play. A normal simultaneous root can
produce targets for both sides even though only one side was human-controlled.
Completed replay-valid outcomes may contribute terminal value targets; partial
matches contribute no terminal label.

Human actions remain useful metadata. They support disagreement analysis,
interface diagnosis, difficulty measurement, and optional auxiliary imitation.
Behavioral-cloning loss is allowed only in a separately named experiment using a
player-view observation, or after an explicit filter such as search endorsement.
It is never silently mixed into the perfect-information policy target.

High-value import candidates include model losses, novel state fingerprints,
high human/model disagreement, rare forced or nested requests, and positions
where post-hoc search assigns high regret to the deployed action. Sampling must
also retain ordinary matches so prioritization does not turn the corpus into an
unrepresentative collection of failures.

## Data split and poisoning resistance

Browser volume must not overwhelm theorem-backed self-play or let one user steer
the model. The importer applies:

- match-level and rotating-player-level train/validation/test splits before
  extracting positions;
- held-out seeds and users that never enter optimization;
- per-match, per-player, per-checkpoint, and repeated-state caps;
- content-hash deduplication;
- server-token, sequence, legality, manifest, and deterministic replay checks;
- quarantine for modified clients, impossible timings, malformed actions,
  mismatched state hashes, stale schemas, or ROM/Lean divergence;
- a declared maximum human-state fraction and loss weight in every run manifest.

The exact mixture weight is an experiment parameter, not a deployment constant.
Promotion must still pass fixed mechanics probes, historical opponents,
held-out generators, campaign teams, and a held-out human-trace suite. An
improvement on the imported training corpus alone cannot promote a checkpoint.

## Privacy and lifecycle

Trace collection should be understandable without reading a privacy policy. A
short notice can say that battle teams, decisions, timings, and outcomes are
saved to improve the opponent, while ROM/save contents and raw inputs are not.
If collection is mandatory for the exhibition, acceptance occurs before a match
ID is issued; if an opt-out mode is offered, it must skip server trace creation
rather than merely setting a client flag.

Opaque player IDs should rotate unless persistent identity is needed for a
rating or longitudinal evaluation. Persistent accounts require an export/delete
path and a deletion tombstone that prevents the same source object from being
re-imported. Raw trace retention and derived training-shard retention are
separate declared periods. Published datasets require a separate consent and
license decision; consent to improve the hosted model does not automatically
permit public redistribution.

## Evaluation questions

Every human-data experiment should report:

- accepted, rejected, quarantined, partial, and replay-divergent match counts;
- unique players, matches, state fingerprints, and checkpoint versions;
- source and matchup distribution before and after sampling;
- search endorsement/regret of human and deployed-model actions;
- self-play-only versus human-state-relabel ablations under identical compute;
- held-out human-state policy loss and value calibration;
- win rate and confidence intervals on fixed nonhuman gates;
- human rematch rate, completion rate, decision latency, and win rate;
- whether gains persist when the human-state replay fraction returns to zero.

These measurements distinguish learning useful human-discovered states from
memorizing one traffic distribution or merely imitating weak play.
