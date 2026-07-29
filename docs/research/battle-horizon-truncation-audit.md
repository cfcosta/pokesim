# Battle-horizon truncation audit

<!-- mode: explanation -->

## Question

Generated battles sometimes stop as `truncated`, especially when a match appears
large or tactically stalled. This audit distinguishes a mechanics failure from an
explicit actor horizon.

## Evidence

The completed v8 shards contain 10,500 episode records across 21 iterations.
Among them:

- 120 episodes were truncated: **1.14%**;
- every truncated episode reached exactly the configured 256-decision horizon;
- semantic divergence remained a separate stop category;
- finished episodes had mean length 17.44 decisions, 95th percentile 51, and
  99th percentile 123.19;
- some valid battles finished on decision 256, showing that the old boundary
  censored both terminal and still-live tails.

Truncation was not confined to large parties. Examples included `1v1`, `1v4`,
`2v2`, and `6v6`. The observed rates included 5/292 for `1v1`, 3/292 for `1v4`,
8/291 for `6v5`, and 2/291 for `6v6`. Grouping by total party members likewise
showed no monotonic size relationship. Heuristic-opponent episodes accounted for
69 of the 120 truncations, mirror self-play for 37, and checkpoint opponents for
14.

The interrupted v11 collection showed the same pattern at a smaller scale: 6 of
592 completed episodes reached 256 decisions, with zero semantic divergences.
One visible truncated example was only `1v4` against the aggressive heuristic.

## Interpretation

These records do not indicate that large mechanics states broke. The native
worker continued returning valid, nonterminal states until Python applied its
configured horizon. Long tails can arise from low-damage move sets, healing,
status blocking, voluntary switches, forced replacements, trapping sequences,
or simply the finite PP available across several party members. Larger parties
provide more possible PP and replacements, but higher generated levels can also
make them end faster. Party size alone is therefore a poor horizon rule.

A horizon remains necessary because cartridge-faithful reactive battles may
fail to return. Raising it must not turn exhaustion into a draw, win, loss, or
training value. The existing contract already keeps such episodes unlabeled and
records `stop = truncated`.

## Change

The v12 production and standalone-arena decision horizon is **512**, doubled
from 256. Smoke tests retain their short explicit horizon. Only the long tail
pays the additional mechanics/search cost; the historical mean battle ended far
below either boundary. Existing quality gates remain in force: excessive mean
length, switching, nonreturn rate, timeout, or semantic divergence can still
reject a collection or promotion.

The v12 detail record also preserves complete initial/final parties and every
post-turn event. Any episode that reaches 512 can therefore be inspected for its
actual move, status, PP, switching, HP, and request history rather than being
classified from party size alone.

## Limits

The historical v8 truncated states cannot be resumed because completed
iterations, not mid-battle snapshots, are the transaction boundary, and the old
shards intentionally omitted unlabeled pending decision rows. The effect of the
512 horizon must therefore be measured prospectively. A remaining 512-decision
stop is still a truncation, not evidence of a cartridge terminal result.
