# battle-training

`battle-training` is the external actor–learner and evaluation project for the
verified Lean battle model. Lean owns team generation, immutable search states,
chance forks, and mechanics. Python owns the transformer, simultaneous search,
replay shards, optimization, checkpoints, and evaluation.

The primary executable profile is `full-link-party-1to6-perfect-v2`. Training
cycles through all 36 ordered combinations of two independently generated,
progression-witnessed parties sized one through six. Policies choose from the
complete 13-action link dictionary: four moves, six
switch slots, typed no-action, Struggle, and the profile-disabled run slot.
Forced replacement and Mimic are normalized as one-side requests.

## Transformer + simultaneous-search smoke training

From the repository root:

```sh
nix develop -c python packages/battle-training/train.py transformer-smoke \
  --output artifacts/training/transformer-smoke

nix develop -c python packages/battle-training/train.py verify \
  artifacts/training/transformer-smoke
```

The smoke command performs the complete loop:

1. builds and starts the persistent Lean search server;
2. initializes a side-canonical transformer policy/value network;
3. periodically builds a persistent simultaneous tree with complete root coverage;
4. couples independent `fresh-root-v1` chance samples across joint actions for
   lower-variance payoff comparisons without reading the episode RNG suffix;
5. runs persistent regret matching+ at every expanded typed request and records
   average-strategy targets alongside witnessed terminal values;
6. optimizes policy cross-entropy plus value MSE with AdamW;
7. publishes model and optimizer checkpoints;
8. runs a side-swapped final-versus-initial arena;
9. writes SHA-256 manifests; and
10. regenerates the first search shard byte for byte from checkpoint zero.

Default training searches every real decision with an adaptive
192–320-transition matrix-valued simultaneous tree. It may stop after eight
stable average-strategy updates once the full depth has been reached. The root
evaluates every legal joint action; deeper nodes begin with two cyclic
joint-action rotations that cover every legal move and switch, then sample
additional pairs and fresh chance outcomes under persistent regret matching+.
Except for typed search fallbacks, every completed training decision therefore
carries an RM+ average-strategy policy target. `--search-every` remains available
for explicit sparse-search experiments, but it is not the production default.
This preserves complete action consideration without top-k pruning.
`transformer-train` is the production profile:
30 iterations of 2,048 training battles, or 61,440 independently reset random
variable-party battles. Exactly one quarter of generated battles are 6v6; the
remaining schedule cycles through every other ordered party-size matchup. It uses
depth-four simultaneous trees, the
940,430-parameter four-layer, 128-wide model, BF16 autocast, one epoch per iteration, a
CUDA-safe batch size of 128, and a 2,048-game final arena. The policy objective
adds value MSE at weight 0.25, reducing the effective value-trunk gradient
imbalance observed in v15. Parameters, gradients, AdamW state, policy
normalization, losses, and reductions remain FP32. The tree
uses up to 320 native transitions per searched root and was 1.31× slower than
disposable depth-four rollouts in a 24-root benchmark. The former every-tenth
profile had an approximately nine-hour strict-FP32 estimate and completed a
15-iteration BF16 run in under five hours. Searching every move creates roughly
ten times as many search roots; a complete all-move production run has not yet
established its wall-clock time:

```sh
nix develop -c python packages/battle-training/train.py transformer-train \
  --output artifacts/training/run-001
```

An interrupted run resumes from its last complete checkpoint without repeating
accepted work or changing its saved configuration:

```sh
nix develop -c python packages/battle-training/train.py transformer-resume \
  --output artifacts/training/run-001
```

## Training monitor

A read-only web dashboard can follow an active run or inspect a completed one:

```sh
nix develop -c python packages/battle-training/train.py monitor \
  --run artifacts/training/run-001 \
  --open
```

The server binds to `127.0.0.1:8765` by default. Use `--host` and `--port` to
change the listener. The page polls local artifacts every two seconds and shows:

- live stage, iteration, and per-actor collection progress;
- checkpoint identity, architecture, precision, device, and parameter count;
- policy/value losses, trunk-gradient conflict, whole-battle held-out value and
  policy diagnostics, and promotion confidence history;
- live self-play results, recent battle outcomes, opponents, turns, examples,
  native transitions, battle length, switching, search, and 36-party-size coverage;
- clickable self-play and promotion battles with complete party move slots,
  PP/status, pinned remote Red/Blue sprites, named move and switch choices,
  effects, outcomes, search summaries, and recorded initial/final state;
- promotion strata, campaign cases, and skill probes;
- accepted/rejected updates and every promotion quality gate.

Training updates `monitor-state.json` and `.monitor/actor-*.json` atomically. The
monitor never imports mechanics state, mutates checkpoints, or controls the
trainer. These transient files are removed before the immutable final manifest;
a completed dashboard is reconstructed from `summary.json` and iteration metrics.
Detailed timelines are loaded only when a battle row is opened, keeping the
two-second dashboard poll compact.

Each checkpoint is published atomically and contains the post-promotion model,
AdamW state, RNG state, collection metrics, and training metrics. Resume checks
the contiguous checkpoint/shard prefix and their hashes, rebuilds the historical
opponent window, and restarts at the next iteration. If interruption occurred
after collection but before checkpoint publication, the incomplete shard and
failure metric are moved under `attempts/` for audit and that iteration is
regenerated deterministically. Mid-battle continuation is intentionally not
claimed; only complete iterations are committed restart boundaries.

Strict-FP32 batch size 512 exceeded the card's 11.63 GiB capacity. Under BF16,
batch 128 peaked at 1.26 GiB and delivered 3.77× the strict-FP32 training
throughput. BF16 batch 512 fit at 4.76 GiB but was only 10.5% faster than BF16
batch 128, so 128 remains the production default.

Use `--device cpu`, `--device cuda`, or `--device auto`. BF16 is the default;
`--precision fp32` remains available for differential checks and older
checkpoints without precision metadata retain their original FP32 contract.
The v16 pipeline defaults `--inference-engine auto`: CUDA uses bucketed compiled
inference through static batches up to 256 while CPU uses eager execution.
`--inference-engine eager` remains available for differential checks and
historical artifact verification. Production collection defaults to two spawned
actor processes; `--actor-processes 1..4` controls the versioned choice, while
smoke runs stay single-process to avoid startup overhead.
`--warm-start-checkpoint PATH` copies same-schema checkpoints exactly. For the
older 478-field v3 schema it copies every compatible parameter and the existing
positional rows into the extended 492-field v4 model. Warm starts establish a
new optimizer and artifact lineage rather than importing AdamW state. The uv2nix development
environment is generated from `uv.lock`; on supported Linux hosts it includes
the CUDA PyTorch wheel and the NixOS runtime-library fixes required to use the
GPU.

A run can mix mirror self-play with one or more hash-recorded fixed checkpoints.
For a 50/50 mixture, fixed opponents are round-robined, the candidate alternates
cartridge sides, and only the candidate side contributes policy examples from
those battles:

```sh
nix develop -c python packages/battle-training/train.py transformer-train \
  --output artifacts/training/fixed-opponent-run \
  --opponent-checkpoint artifacts/training/baseline-a.pt \
  --opponent-checkpoint artifacts/training/baseline-b.pt \
  --opponent-fraction 0.5
```

The pipeline copies fixed checkpoints into the immutable run and anchors half
of default collection against the scratch initialization, a rolling historical
window, an aggressive tactical heuristic, a deliberately switch-heavy
heuristic, and all 47 canonical Red trainer-class rows. The class heuristics
preserve the cartridge move-scoring layers, biased `63/64/63/66` move-slot
buckets, first-match AI type-effectiveness bug, and switch branches representable
by the 13-action link profile. Trainer items and the per-send-out action counter
are absent from that profile, so item decisions project to ordinary move
selection; the exact stateful behavior remains in
`Battle.Full.TrainerController`. On opponent episodes the candidate still
receives an all-action RM+ policy target, but the opposing real action is sampled
from the named heuristic rather than the tree's opponent strategy.
`--no-heuristic-opponents` disables all deterministic heuristics for ablations.
Shards record every opponent identity and deterministic regeneration
reconstructs the same population order. In v16, half of all pairs remain mirror
self-play. Of the other half, exactly half are reserved for deployed/historical
model opponents and half cycle over the 49 heuristics. This gives direct model
comparisons 25% of collection without dropping broad trainer-class coverage.
Human traces remain external until the server-authoritative replay and search-
relabeling importer in
[the trace contract](../../docs/explanation/human-battle-trace-training.md) is
implemented. Each production update receives 2,048 held-out games against its
incumbent, grouped into 1,024 same-reset pairs with a complete model-side swap
across eight root seeds. Every generated arena and collection schedule reserves
at least 25% of games for 6v6. Exactly 25% of the scheduled generated 6v6
pairs use two fully level-100 teams; the remaining generated teams retain the
ROM-floor-to-100 level distribution. Production collection groups every two
games into one same-reset pair. Fixed/checkpoint/heuristic opponents exchange
candidate controller sides on the second leg while retaining physical team
placement, so each controller uses both teams. In mirror self-play, where the
same model already owns both controllers, the second leg instead swaps the exact
two generated teams across physical sides and uses independent policy/search
sampling. Pair identity and leg are stored in every episode and example row,
and collection rejects missing, mismatched, or unswapped pairs. The
production horizon is 512 real decisions; reaching it remains an unlabeled
truncation rather than a fabricated
terminal result. Truncations and semantic cycles score zero. Promotion requires a point score of at least 50%,
a paired 95% confidence lower bound of at least 50%, and passing separate
held-out type and status probes. Switching rate, completion, and matchup-change
remain reported diagnostics but do not gate promotion. It also reports and gates 1–2, 3–4,
5–6, and unequal-party strata, plus a nine-team fixed campaign suite covering
Brock through Giovanni and Lance. The campaign teams use canonical natural
moves and fixed DVs inside the link quotient; they do not claim trainer AI or
item equivalence. The v16 pipeline separates a persistent shadow learner from the
quality-gated deployed incumbent. Inconclusive evaluations retain the incumbent
but carry the learner parameters and AdamW state into the next collection
iteration, allowing small updates to compound without weakening deployment. Each
checkpoint stores both lineages; ordinary checkpoint loading returns the deployed
model, while resume restores the shadow learner and its optimizer explicitly.
A new same-schema lineage can pass the exported shadow to
`--warm-start-checkpoint` and the prior quality-gated checkpoint to
`--warm-start-incumbent-checkpoint`. This preserves the accumulated learner
without silently deploying it; the new optimizer lineage starts fresh.

## Model

Each mechanics scalar is encoded as low- and high-byte embeddings plus a learned
field-position embedding. A learned CLS token attends over all 492
side-canonical variable-party fields. The quality-gated `--token-group-size`
option can mean-pool adjacent scalar embeddings before attention; group eight
reduces the sequence from 493 to 63 tokens but remains opt-in pending full
promotion evidence. The v4 schema retains v3's move descriptors,
current type-effectiveness values, offensive/incoming matchup scores, and Mimic
continuation action. It appends both party counts and twelve presence bits while
zeroing every absent party and switch descriptor; present fainted members retain
presence `1` with HP `0`. This
keeps small networks from having to rediscover static ROM tables from terminal
labels. Two heads predict:

- logits for all 13 stable link action IDs; and
- a bounded terminal value in `[-1, 1]`.

Encoder and head matrix operations run under BF16 autocast. Both head outputs
are immediately promoted to FP32 before masks, softmax, RM+ search, losses, or
reductions, and all trainable parameters and optimizer state stay FP32. Native
UInt16 rows use reusable pinned buffers, legal masks come from a device lookup,
and CUDA inference uses static compiled batch buckets. Exact feature/mask cache
keys suppress duplicate forwards without claiming mechanics-state equivalence.

Search and policy loss mask illegal actions. Every expanded node retains an
empirical joint payoff matrix, cumulative RM+ regrets, average strategies,
explicit chance outcomes, and immutable child handles. The root matrix is
complete; progressive deeper matrices represent unvisited pairs with the neural
leaf prior while mandatory exploration gives every legal action initial support.
A dense,
antisymmetric HP/faint/status delta stabilizes one-step leaf estimates, and an
adaptive 10–30% aggregate switch cap applies only to voluntary-switch targets;
all six switch actions remain evaluated and retain nonzero support. Common
random numbers couple sampled chance seeds across actions only inside the estimator;
each action retains the required `fresh-root-v1` marginal distribution. The old
sequential Exp3 path and its replay compatibility have been removed.
Search-selection entropy, search-chance entropy, real battle entropy, and
team-generation entropy remain separate.

## Native boundary

`battleSearchServer` stores immutable `Battle.Full.Environment.State` values and
typed Mimic continuations behind integer handles. `step ... fresh ...` installs
a named search chance fork;
`batch` derives many such successors in one native request; `reset-append` and
`compact-handles` retain and remap several live episode roots without returning
unchanged observations; `batch-episode` advances several real trajectories with
their existing hidden RNG. The compatibility `compact-many` command still emits
full snapshots for external protocol probes. Python cannot
mutate or resolve battle state itself. Actors run in groups of 16. Root matrices,
root leaf inference, network-only decisions, and real episode transitions are
batched across compatible independent roots. Deeper progressive simulations are
resumable frontiers: native requests and leaf rows are pooled across roots and
model identities, then deterministic cohorts overlap Lean mechanics with GPU
inference. Independent search, chance, and deep-tier RNG streams are retained.
`--deep-search-fraction` optionally stops a randomized fraction after the complete
root while labeling those targets `joint-regret-root`; its default remains 1.0
pending equal-budget quality gates.

Promotion and campaign arenas keep hundreds of live games on one Lean server,
batching inference, episode steps, and handle compaction. Probe arenas use 64-game
batches and carry each post-step inspection into the next decision. A timed-out
batch is discarded and the server is respawned. Arena directories contain
Showdown-style `.log` replays plus aggregate metrics
for damage-move effectiveness relative to the best legal damaging move, status
success/block/waste counts, voluntary-switch rate/completion/matchup improvement,
and setup-move counts/rates by move. Setup means self stat boosts, Mist, screens,
Focus Energy, Conversion, and Substitute; charge turns, healing, opponent status,
Haze, Mimic, Metronome, and Transform are excluded. Production promotion rejects statistically inconclusive updates and
gated type/status probe regressions. Switch diagnostics are observational: neither
switch frequency nor measured matchup change can reject a candidate or collection.
The expanded data gate rejects collection with more than 1% horizon truncation or
semantic divergence, below 98% completion, or mean length above 96 decisions;
evaluation nonfinishes are capped at 2%. These remain versioned diagnostics, not
claims of strategic optimality.

The earlier terminal-return move table remains available as `tabular-smoke` and
`tabular-train`. It is a restricted protocol baseline, not the intended learner.

## Boundaries

- Only `finished` episodes produce value targets.
- Horizon truncation, classified silent divergence, and mechanics timeouts never
  receive fabricated terminal labels.
- Every native request has a 15-second process-level timeout. Arena episodes
  restart with a fresh server after timeout and report `mechanics_timeouts`;
  collection timeouts kill the worker, write a failed iteration metric, and
  reject the run.
- Generated Mirror Move against a recorded Mirror Move is classified as
  `nested-mirror-move-cycle` silent divergence rather than consuming host CPU
  indefinitely. RNG-stuck states and cartridge-faithful division freezes are
  likewise returned as typed divergences: search falls back without labeling
  the branch, while a real episode stops without a terminal value target.
- The synchronized full-party profile is still a hot-path quotient, not the
  paired-cartridge emulator deployment profile.
- Cross-root batching covers complete roots, progressive deep frontiers, native
  mechanics, and model-identity inference pools. Exact neural memoization still
  does not license mechanics transposition merging.
- Deeper matrices use progressive joint sampling rather than exhaustive pair
  coverage. Artifacts report sampled-joint coverage separately from mandatory
  legal-action coverage.
- Forced replacement and Mimic are normalized; other profile-excluded nested
  protocols remain blocked before widening beyond stock link battle control.
- This training pipeline is theorem-backed model execution, not a proof of
  behavioral equivalence to the Pokémon Red battle ROM.

See [`CHECKLIST.md`](CHECKLIST.md) for the remaining paired-cartridge and patched
browser deployment gates. The browser-first target is the
[random level-100 6v6 exhibition](../../docs/explanation/web-random-6v6-exhibition.md);
the later campaign integration is described in
[Campaign trainer battles controlled by the learned link policy](../../docs/explanation/campaign-trainer-link-ai.md).
