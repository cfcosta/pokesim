# Game 2047 Swift/Dig audit

## Scope

This audit covers promotion iteration 4, game 2047 from
`/tmp/pokered-variable-party-shadow-v17-popular-teams-from-v16-iter3`.
The dashboard groups these generated evaluation games with self-play, but the
immutable source artifact is `matches/promotion-004/game-02047.json`.

At turn 23, enemy Golem selected Dig before player Sandslash selected Swift.
Dig's setup produced no damage. Swift then dealt 7 damage to Golem. That result
is correct for the canonical English Pokémon Red ROM.

The audit also found a separate model error earlier in the same game. Golem had
started Dig on turn 13, but Confusion damaged it on turn 14 before Dig's release.
The model set `CHARGING_UP` without setting `INVULNERABLE` for Dig. The corrected
replay makes Confusion miss while retaining Swift's later hit.

## Canonical ROM identity

The decoded bytes are from the 1 MiB English Pokémon Red ROM with SHA-256:

```text
5ca7ba01642a3b27b0cc0b5349b52792795b62d3ed977e98a09390659af96b7b
```

`Battle.Rom.SwiftRoutine.RequiredSwiftDigBytes` retains both windows as explicit
caller-supplied byte witnesses.

## Dig enters an invulnerable frame

`ChargeEffect.chargeEffect` is at bank `$0F:$78A1` (physical ROM offset
`$3F8A1`). Its retained window is:

```text
CB E6 1A 1B FE 2B 20 04 CB F6 06 64
1A FE 5B 20 04 CB F6 06 C0
```

The relevant decoded path is:

1. `CB E6`: set `CHARGING_UP` (status-1 bit 4).
2. Compare the effect byte with `FLY_EFFECT` (`$2B`).
3. Load the move ID and compare it with Dig (`$5B`).
4. `CB F6`: set `INVULNERABLE` (status-1 bit 6).

Dig shares effect `$27` with visible charge moves, so effect dispatch alone is
insufficient. The move-ID comparison is required.

`Battle.Rom.SwiftRoutine.dig_invulnerability_exact` executes this path for both
acting sides and every possible incoming status-1 byte. It proves agreement in
both the functional SM83 semantics and the physical half-edge adapter. The
resulting byte is the incoming byte OR `$50`.

## Swift returns before the invulnerability test

`MoveHitTest` starts at bank `$0F:$656B` (physical ROM offset `$3E56B`). At
`$658D`, its Swift path contains:

```text
1A FE 11 C8
```

These bytes decode as load move effect, compare with `SWIFT_EFFECT` (`$11`), and
`RET Z`. The Fly/Dig status test does not occur until `$65A0`:

```text
CB 76 C2 09 66
```

Therefore Swift returns successfully before reading status-1 bit 6. It also
consumes no accuracy RNG byte.

`Battle.Rom.SwiftRoutine.swift_invulnerability_exact` proves the complete
`MoveHitTest` entry-to-return path for both acting sides and both target
invulnerability states in the functional and physical SM83 models.
`Battle.Rom.SwiftRoutine.model_ordinary_misses_dig` and
`model_swift_hits_dig` link those decoded facts to the high-level engine:
corrected Dig setup has `INVULNERABLE = true`; ordinary accuracy resolution
returns a miss, while `resolveAccuracy .swift` still returns `(true, rng, [])`.

## Deterministic regression

`tools/check-episode-2047-swift-dig.py` reconstructs the arena coordinates and
action prefix. The corrected trace establishes:

- turn 13 Dig setup produces status `$50`;
- turn 14 ordinary Confusion misses and Dig clears both bits on release;
- turn 23 Dig setup again produces status `$50`;
- Swift still deals 7 damage without an accuracy draw;
- Dig PP remains unchanged on setup, decrements once on continuation, and both
  charge bits clear before release.

The corrected turn-14 miss leaves Golem with 23 more HP than the historical
high-level recording. The later Swift damage remains 7.

## Claim boundary

The two decoded control windows and their high-level projections are proved.
The full 24-turn prefix is a deterministic regression, not a universal
whole-battle ROM/model equivalence theorem.
