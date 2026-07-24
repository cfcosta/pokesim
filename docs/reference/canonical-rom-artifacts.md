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
```

`--rebuild` copies the pristine source to a temporary directory, builds
`pokered.gbc`, verifies both ROM digests, and byte-compares the generated symbol
and map files with the retained artifacts. It leaves `pokered/` unchanged.

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
