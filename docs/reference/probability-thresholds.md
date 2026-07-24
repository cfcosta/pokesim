# Battle probability thresholds

<!-- mode: reference -->

**Baseline:** `pret/pokered` commit `405b6246372d7e5a2cb029cbb65219b13286b8c9`.

The RGBDS macro is textual arithmetic:

```text
percent = * $ff / 100
```

For an integer `n`, `n percent` is `floor(n × 255 / 100)`. The source then adds or subtracts constants and chooses a comparison polarity. The expression alone does not define the event probability.

## Literal expressions used by core, effects, and AI

| Source expression | Byte threshold |
|---|---:|
| `8 percent` | 20 |
| `10 percent` | 25 |
| `10 percent + 1` | 26 |
| `13 percent - 1` | 32 |
| `20 percent + 1` | 52 |
| `25 percent` | 63 |
| `25 percent + 1` | 64 |
| `30 percent + 1` | 77 |
| `33 percent + 1` | 85 |
| `40 percent + 1` | 103 |
| `50 percent` | 127 |
| `50 percent + 1` | 128 |
| `75 percent - 1` | 190 |
| `85 percent + 1` | 217 |

## Move-record accuracy bytes

The `move` macro applies the same floor to its fifth argument. Across all 165 canonical move records:

| Nominal accuracy | ROM byte | Move count |
|---:|---:|---:|
| 30 | 76 | 3 |
| 55 | 140 | 4 |
| 60 | 153 | 1 |
| 65 | 165 | 1 |
| 70 | 178 | 4 |
| 75 | 191 | 11 |
| 80 | 204 | 5 |
| 85 | 216 | 15 |
| 90 | 229 | 11 |
| 95 | 242 | 6 |
| 100 | 255 | 104 |

The stored byte, not the nominal decimal argument, enters `CalcHitChance`. Even an unmodified nominal-100 move is therefore subject to the final byte-255 miss unless an earlier gate such as Swift or X Accuracy returns.

## Mechanics call sites

| Mechanic | Comparison/event | Accepted byte count |
|---|---|---:|
| Equal-Speed order | `< 128` selects one side; `>= 128` the other | 128 / 128 |
| Enemy move slot 1 | `< 63` | 63 |
| Enemy move slot 2 | `>= 63` and `< 127` | 64 |
| Enemy move slot 3 | `>= 127` and `< 190` | 63 |
| Enemy move slot 4 | `>= 190` | 66 |
| Confusion self-hit | `>= 128` | 128 |
| Full paralysis | `< 63` | 63 |
| Damage factor after `rrca` | accept `>= 217`; otherwise retry | 39 per draw |
| Poison side effect 1 | `< 52` | 52 |
| Poison side effect 2 | `< 103` | 103 |
| Burn/freeze/paralysis side effect 1 | `< 26` | 26 |
| Burn/freeze/paralysis side effect 2 | `< 77` | 77 |
| Flinch side effect 1 | `< 26` | 26 |
| Flinch side effect 2 | `< 77` | 77 |
| Confusion side effect | `< 25` | 25 |
| Extra non-link enemy stat-down handler failure | `< 64` means failure before effect classification | 64 |
| Damaging stat-down side-effect draw | `< 85` means effect succeeds after prior gates | 85 |

A player damaging stat-down side effect uses the single `< 85` draw. A non-link enemy side effect first requires an independent byte `>= 64`, then (if no Substitute) a second byte `< 85`: 192 × 85 accepted pairs out of 65,536. Failure of the first gate consumes no second byte, so this cannot be replaced by one combined threshold.

Blank or disabled enemy move slots restart sampling, so the eventual slot distribution depends on the occupied candidate set and consumes a variable number of bytes.

## Move accuracy threshold

`CalcHitChance` applies the attacker's accuracy ratio and reflected target-evasion ratio in two separate multiply/divide steps. It floors and enforces a minimum of one after each step, caps the final threshold at 255, and writes it back to the loaded move-accuracy byte. `MoveHitTest` then hits iff `BattleRandom < threshold`.

Thus a raw/scaled threshold of zero becomes one and accepts byte zero, while threshold 255 accepts 255 bytes and still misses on byte 255. Swift and an applicable X Accuracy return before this random draw, subject to the earlier gates documented in the fifth-pass audit.

## Trainer action AI

Trainer action AI consumes ordinary `Random`; all other rows above use `BattleRandom`. Its unique gates are:

| Source comparison | Event bytes |
|---|---:|
| `< 20` (`AgathaAI` switch branch) | 20 |
| `< 32` (`13 percent - 1`) | 32 |
| `< 64` (`25 percent + 1`) | 64 |
| `< 128` (`50 percent + 1`) | 128 |

The class routine may perform additional HP/party tests after passing the random gate. Failed later tests do not refund the draw or decrement `wAICount`. Cooltrainer F consumes a byte but its commented-out return makes the random comparison behaviorally ineffective; Brock consumes a byte and ignores its value. Exact class rows are in [Trainer AI dispatch](trainer-ai-dispatch.md).

## Proof obligations

- Decode all 165 move-record accuracy bytes from ROM and prove the nominal-value/expanded-byte count table; do not re-evaluate source percentages in the runtime model.
- Represent each comparison with its exact unsigned polarity and boundary.
- Preserve rejection loops and repeated draws rather than sampling directly from a conditional distribution.
- Label ordinary trainer-AI draws separately from `BattleRandom` mechanics draws.
- Include move-accuracy boundary regressions for expanded thresholds `76`, `140`, `153`, `165`, `178`, `191`, `204`, `216`, `229`, `242`, and `255` after stage scaling.
- Include event boundary regressions at `19/20`, `24/25`, `25/26`, `31/32`, `51/52`, `62/63`, `63/64`, `76/77`, `84/85`, `102/103`, `126/127`, `127/128`, `189/190`, `216/217`, and `255` where reachable.
