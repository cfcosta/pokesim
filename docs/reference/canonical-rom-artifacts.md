# Canonical ROM artifacts

<!-- mode: reference -->

## Pinned inputs

| Input | Value |
|---|---|
| `pret/pokered` commit | `405b6246372d7e5a2cb029cbb65219b13286b8c9` |
| RGBDS revision | `3b1606c63c1671fd6675747507fe95d7f72da2d9` (`v1.0.2+hotfix`) |
| RGBDS source SHA-256 | `sha256-+f+fQDQPTFWmX6szB3wWixQ0VhQr37J4QPNvTKaspFg=` |
| Red ROM SHA-1 | `ea9bcae617fdf159b045185467ae58b2e4a48b9a` |
| Red ROM SHA-256 | `5ca7ba01642a3b27b0cc0b5349b52792795b62d3ed977e98a09390659af96b7b` |
| ROM size | 1,048,576 bytes (64 banks) |

The ROM is rebuilt and hash-checked but is not retained in this repository.

## Retained files

| File | SHA-256 | Lines |
|---|---|---:|
| [`artifacts/pokered/pokered.sym`](../../artifacts/pokered/pokered.sym) | `4dc25c1c467a947c2b0aa18628ddd048b4d1de50166a58e190db885e5577c33f` | 21,137 |
| [`artifacts/pokered/pokered.map`](../../artifacts/pokered/pokered.map) | `2bc9e32847add776618f3a5cb98c383c85842fa52f9f5d48474f32f32738c9fb` | 20,559 |
| [`artifacts/pokered/build-manifest.json`](../../artifacts/pokered/build-manifest.json) | manifest-owned | n/a |
| [`artifacts/pokered/closure-manifest.json`](../../artifacts/pokered/closure-manifest.json) | manifest-owned | n/a |

## Verification commands

```sh
python3 tools/check-pokered-build.py
python3 tools/check-pokered-closure.py
nix develop -c python3 tools/check-pokered-build.py --rebuild --jobs 4
nix develop -c python3 tools/check-pokered-build.py --rebuild --output-rom /tmp/pokered.gbc
nix develop -c lake -d packages/battle-lean exe battleRomFixture /tmp/pokered.gbc
```

`--rebuild` copies the pristine source to a temporary directory, builds
`pokered.gbc`, verifies both ROM digests, and byte-compares the generated symbol
and map files with the retained artifacts. It also verifies three retained
16-byte entry witnesses. `--output-rom` optionally copies that verified build to
a caller-selected temporary path for the battle fixture runner. The repository
and Lake package never retain the ROM; proof modules continue to require
explicit byte-window witnesses rather than turning an IO check into a theorem.

## Retained entry-byte witnesses

| Symbol | Physical ROM offset | First 16 bytes |
|---|---:|---|
| `InitOpponent` | `0x3ef18` | `fa59d0ea91cfead8cf181afa32d7cb4f` |
| `_InitBattleCommon` | `0x3efeb` | `0600cdef3dcd4c40afe0ba214a70cd49` |
| `StartBattle` | `0x3c11e` | `afea58d0eaf5ccea6acd3cea1dd121a5` |

The witnesses are metadata inside the hash-identified build manifest and are
checked against every rebuilt or caller-supplied ROM. Lean callers provide
`Rom.Closure.RequiredEntryBytes`; this is deliberate because an uninterpreted
caller-supplied hash function cannot by itself prove individual array values.
`DriverInvariant.atInitOpponent_shape` then proves that the fetched canonical
entry byte is `$FA`, decoded as `LD A,(a16)`. The stronger
`AtInitOpponentReady` checkpoint also records IR, next PC, physical schedule,
latches, interrupt slot, boundary PC, and HALT-bug state. Half-edge stability
then proves the first two physical reads consume `$59` at `$6F19` and `$D0` at
`$6F1A`. WRAM stability discharges the `$D059` data window, and canonical ROM
stability supplies successor byte `$EA` at `$6F1B`. The four-cycle theorem
commits `A := read($D059)` and preserves the retirement boundary even when a
pending interrupt takes the overlapped successor fetch. Under the explicit
no-interrupt-accepted branch, the proof also establishes the exact next fetched
IR: `$EA` (`LD (a16),A`) at `$6F1B`, with next PC `$6F1C` and reset latches.
Execution then remains in the same fetched-IR stream: it consumes `$91 $CF`,
commits the supplied opponent to WRAM `$CF91` at T3R, fetches the next `$EA`
at `$6F1E`, and establishes its exact hidden checkpoint without bootstrap
reinitialization. The same stream then consumes `$D8 $CF`, drives the supplied
opponent to `$CFD8`, and installs canonical `JR $1A` (`$18`) at `$6F21` after the
third retirement. The live jump then consumes `$1A`, completes its internal IDU
cycle, and proves the next opcode bus intent targets canonical
`InitBattleCommon` at `$6F3D`.

## Address closure

The first closure is a conservative whole-machine overapproximation:

- all 64 ROM banks;
- all four 8-KiB external RAM banks;
- a contiguous, non-overlapping partition of all 65,536 CPU addresses;
- the complete fixed bank and all interrupt vectors;
- every indirect address represented by the memory model;
- explicit open-bus behavior for selected ROM banks outside the 64-bank image.

`Battle.Rom.Closure.classify_sound` proves total CPU-address classification.
`romOffset_in_image` proves that an in-range bank/window pair indexes the
canonical ROM. Episode invariants must still prove that executable targets are
fetchable, the selected MBC3 bank remains below 64, and canonical execution does
not fetch invalid opcodes or STOP.

## Selected symbols

| Symbol | Bank:address |
|---|---:|
| `InitBattle` | `0f:6f12` |
| `InitOpponent` | `0f:6f18` |
| `_InitBattleCommon` | `0f:6feb` |
| `StartBattle` | `0f:411e` |
| `EndOfBattle` | `04:77aa` |
| `InitBattleVariables` | `14:65af` |
| `BattleRandom` | `0f:6e9b` |
| `Random_` | `04:7a8f` |
| `DelayFrame` | `00:20af` |
| `VBlank` | `00:2024` |
| `wBattleResult` | `00:cf0b` |
| `wIsInBattle` | `00:d057` |
| `Moves` | `0e:4000` |
| `BaseStats` (150 ordinary rows) | `0e:43de` |
| `MewBaseStats` | `01:425b` |
| `EvosMovesPointerTable` | `0e:705c` |
| first evolution/learnset payload | `0e:71d8` |
| `PokedexOrder` | `10:5024` |
| `ResidualEffects1` | `0f:4000` |
| `SetDamageEffects` | `0f:4011` |
| `ResidualEffects2` | `0f:4014` |
| `AlwaysHappenSideEffects` | `0f:4030` |
| `SpecialEffects` / `SpecialEffectsCont` | `0f:403b` / `0f:4049` |
| `MoveEffectPointerTable` | `0f:7150` |
| `HighCriticalMoves` | `0f:608e` |
| `TypeEffects` | `0f:6474` |
| `StatModifierRatios` | `0f:76cb` |

`Rom.Closure.TableLayout` proves the fixed ranges: 165 six-byte move rows,
150 28-byte ordinary base-stat rows plus Mew's detached row, 190 two-byte
evolution/learnset pointers, and 190 internal-index order bytes.
`Battle.Rom.Tables` supplies lossless universal row codecs and canonical decoders.
It follows the variable evolution payloads and reconstructs the 191 internal-slot
learn pools from level-one moves, level-up moves, TM/HM flags, and transitive
pre-evolutions. It also certifies internal-index growth-rate IDs, initial moves,
exact level/item/trade evolution records, and ordered level/move pairs against
`Battle.Data.Progression`. `RequiredTableBytes` exposes the caller-supplied proof
boundary; the temporary ROM fixture checks agreement with all independently
authored `Battle.Data` arrays.

`Battle.Rom.Effects` additionally decodes all six terminated effect-phase tables
and all 86 little-endian handler pointers. It compares their exact byte order,
terminators, and pointer target classes with `Battle.Full.EffectPlan`; unknown
pointer addresses do not collapse to `NULL`. `Battle.Rom.Mechanics` combines
whole-ROM hash identity, `RequiredTableBytes`, and `RequiredEffectBytes` into the
proof-facing `CanonicalMechanicsBytes` certificate. Its
`canonical_mechanics_exact` theorem establishes exact battle-relevant species
headers, all 165 move rows, bounded effect IDs, and all handler selections for
any caller-supplied ROM satisfying that certificate.
`Battle.Rom.Mechanics.move_routes_exact` additionally quantifies over all 165
ROM-decoded move rows: effect zero selects ordinary damage, and every nonzero
effect indexes the ROM pointer whose classified target is exactly the independent
plan's handler.

`Battle.Rom.EffectRoutines.CanonicalLeafEffectsBytes` adds exact code-window
witnesses for `HyperBeamEffect` (`0f:79c1`), shared `ClearHyperBeam`
(`0f:79cf`), and `RageEffect` (`0f:79df`). Its headline theorem decodes those
supplied ROM bytes and proves the complete 18/20-M-cycle set-bit and 25/27-M-cycle
clear-bit player/enemy bus traces and status summaries universally over all
incoming status-byte pairs. The same routines are composed continuously through
the flat fetched-IR adapter: each physical trace equals the functional trace
plus one successor-fetch overlap and projects to the same registers/WRAM. Full
Game Boy device-adapter reachability remains separate.

`Battle.Rom.EffectPrefixes` adds exact banked windows for `FocusEnergyEffect_`
(`09:7f86`) and `MistEffect_` (`0c:7f2b`). Universal execution reaches either
the exact post-mutation presentation boundary or the already-active failure
boundary and proves acting-side-only status writes before presentation code.
Both prefixes additionally compose through continuous flat fetched-IR execution
with one successor-fetch overlap.

`Battle.Rom.ExplodeRoutine` adds the exact `ExplodeEffect` window at `0f:72f1`.
Its complete functional and continuous fetched-IR summaries prove acting-side
HP/status zeroing, Seeded-bit clearing, caller return, and other-side framing for
all status-2 byte pairs.

`Battle.Rom.ConversionRoutine` retains the `ConversionEffect_` mechanics window
at `04:79a3`. Its exact summaries cover both acting sides, both normalized
invulnerability outcomes, and every target type-byte pair through either the
animation-call or failure-presentation boundary.

`Battle.Rom.OhkoRoutine` retains the full `OneHitKOEffect_` window at `0c:7f57`
and proves that its low-byte `SUB` followed by high-byte `SBC` accepts exactly
unsigned attacker Speed greater than or equal to target Speed. This is a
universal arithmetic summary, not yet a complete handler cycle trace.

`Battle.Rom.CombatTables` closes three more mechanics-critical data seams: the
four high-critical move IDs and terminator, all 82 ordered type-effect triples
and terminator, and all 13 numerator/denominator stat-stage ratios. These are
included in `CanonicalMechanicsBytes` and the canonical fixture rather than
remaining source transcriptions.
