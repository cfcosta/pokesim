# Pokémon Showdown Gen-I 1v1 reconstruction study

## Source boundary

The inspected source is [`HolidayOugi/pokemon-showdown-replays`](https://huggingface.co/datasets/HolidayOugi/pokemon-showdown-replays), repository revision `bc76388c2119f8a5694adf643c640610b157ee1c`. The `[Gen 1] 1V1.parquet` object inspected locally has SHA-256 `b7a89573c8b4646931e0ba1cb3f65b570ad9de55c3ce156f3e9931354db4c0cc` and contains 572 replay records according to the dataset card.

No licence field or licence file was detected in the dataset metadata or README. No replay log is vendored. This study retains only replay identifiers and a compact factual projection of three public battles.

## Reconstruction profile

`Battle.RL.ReplayExamples` constructs one-member level-100 link duels with maximum DVs and maximum stat experience. This is an explicit hypothesis: the replay records expose displayed percentage HP, species, used moves, action order, critical markers, secondary effects, and winner, but not exact DVs, stat experience, full move sets, or simulator RNG state.

Each reconstruction uses a named ten-byte `Battle.Rng.LinkRng` witness found by deterministic search. The witness reproduces an event projection; it is not inferred Pokémon Showdown entropy. Processor and ROM execution remain outside these fixtures.

## Results

| Replay | Observed battle projection | Lean reconstruction | Agreement |
|---|---|---|---|
| `gen11v1-2115019340` | Starmie mirror. Enemy Thunderbolt first leaves displayed 53%; player critical Thunderbolt leaves 14%; player critical Thunderbolt wins on turn 2. | `starmieMirror`, witness `44737`. Turn 1 exact HP is `171/323` and `48/323`; turn 2 ends at `171/323` versus `0`. | Same action order, normal/critical/critical pattern, no secondary status/stat event, turn count, and winner. Model ratios are approximately 52.9% and 14.9%. |
| `gen11v1-2134948894` | Tauros critical Body Slam leaves Slowbro at 55%; Surf leaves Tauros at 68%. A second critical Body Slam leaves 9%; Counter knocks out Tauros on turn 2. | `slowbroTaurosCounter`, witness `340`. Exact HP progresses from `393/353` to `209/237`, then `32/0`. | Same order, critical/noncritical/critical pattern, Counter knockout, no paralysis, turn count, and winner. Model ratios are approximately 53.2%, 67.1%, and 8.1%. |
| `gen11v1-2134954677` | Alakazam Psychic leaves Machamp at 4%; Earthquake leaves Alakazam at 54%; the second Psychic wins on turn 2. | `machampAlakazam`, witness `288`. Exact HP progresses from `383/313` to `14/167`, then `0/167`. | Same action order, all-noncritical pattern, no Special drop, turn count, and winner. Model ratios are approximately 3.7% and 53.4%. |

The three fixtures are theorem-checked with `native_decide`. Their exact HP, status bytes, first actor, secondary-effect absence, and terminal phase are explicit propositions rather than runtime transcript assertions.

## Interpretation

The compact traces reproduce the mechanics shape closely, but they are not exact source-replay proofs. A displayed Showdown percentage identifies a range of possible cartridge HP values, and the hidden team parameters can change both maximum HP and damage. A searched model RNG witness establishes existence of a matching model path; it does not establish that Showdown consumed equivalent randomness.

The source format also differs from the cartridge profile:

- Gen-I 1v1 uses three-member team preview followed by one selected combatant; the fixtures begin at the selected one-member duel.
- Showdown applies format clauses and simulator modifications, including Desync Clause Mod and HP Percentage Mod.
- The Lean fixtures use Red-shaped link battle mechanics and preserve cartridge bugs rather than adopting every Showdown modification.
- Chat, timer, join/leave, nickname, and presentation records are outside the mechanics projection.
- Exact model-versus-Showdown equivalence would require full team exports, hidden stats, exact simulator version, initial PRNG state, and a stated relation between Showdown clauses and cartridge behavior.

These examples are differential leads and regression fixtures. They do not strengthen the existing cartridge-equivalence claim boundary.
