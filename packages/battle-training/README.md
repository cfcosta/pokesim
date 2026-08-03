# battle-training

`battle-training` is the external actor–learner and evaluation project for the
verified Lean battle model. Lean owns team generation, immutable search states,
chance forks, and mechanics. Python owns the transformer, batched search
scheduler, replay shards, optimization, checkpoints, and evaluation. A pinned
Rust C-ABI library owns the deterministic dense RM+/CFR+ arithmetic only.

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
3. builds a persistent simultaneous tree at every neural-model decision;
4. couples independent `fresh-root-v1` chance samples across joint actions for
   lower-variance payoff comparisons without reading the episode RNG suffix;
5. runs native CFR+-accelerated regret matching at every expanded typed request
   and records linearly weighted average-strategy targets alongside witnessed
   terminal values;
6. optimizes policy cross-entropy plus value MSE with AdamW;
7. publishes model and optimizer checkpoints;
8. runs a side-swapped final-versus-initial arena;
9. writes SHA-256 manifests; and
10. regenerates the first search shard byte for byte from checkpoint zero.

Default training searches every real decision with a matrix-valued
simultaneous tree. The root always evaluates every legal joint action. After one
full-search calibration iteration, a learned budget head predicts whether the
320-transition teacher would materially change the complete-root RM+ target.
High root exploitability or joint-payoff uncertainty forces deep search, and a
separate budget RNG forces 10% of otherwise skipped decisions deep to keep
measuring false negatives. Deep searches may also stop after eight stable
average-strategy updates once full depth is reached. Deeper nodes begin with two cyclic
joint-action rotations that cover every legal move and switch, then sample
additional pairs and fresh chance outcomes under persistent regret matching+.
Every completed neural-model decision therefore carries an RM+ average-strategy
policy target. `--search-every` is fixed at one; sparse raw-policy action
selection has been removed. If a search encounters semantic divergence before
it can produce an RM+ strategy, the episode fails closed without selecting or
labeling a raw-policy action. This preserves complete action consideration
without top-k pruning.
V18 makes this selector a lineage invariant. V22 additionally changes the
encoder, policy/value heads, leaf evaluator, and search-budget controller, so no
earlier checkpoint can resume or warm-start into it. V23 keeps that model but
changes the controller: the final current root matrix receives a fresh 2,048-step
RM+ solve, chance resampling decays with evidence, and learned priors provide
progressive deeper exploration. V24 pools the full policy/value evaluations
needed when distilled successors become expanded nodes; mirror children now use
the intended joint dual-policy head instead of two synchronous canonical rows.
V26 moves the unchanged dense solver surface to a versioned Rust C ABI and
enables CFR+'s alternating updates and linear averaging. The root still runs
2,048 iterations; no action pruning, root noise, tolerance stop, chance, tree,
or neural code moved into Rust. Each controller decision still ends in
simultaneous RM+ over the complete root; adaptive routing changes only whether
deeper refinements are requested.

`transformer-train` is the production profile:
30 iterations of 2,048 training battles, or 61,440 independently reset random
variable-party battles. One third of generated battles are 6v6; the remaining
schedule cycles through every other ordered party-size matchup. V18 selects the
displayed final species with a bounded two-byte map whose 151 fibers contain
434 or 435 words each. This removes the prior 2:1 byte-modulo bias and the
funneling of several evolutionary-family entries into one final form while
retaining all 151 species and fixed entropy consumption. For 6v6 level-100
party draws, 26 of 256 gate values (10.15625%) instead select one of the top 200
exact Generation-I teams reconstructed from public Showdown replays. Repeated
matches with the same composition supply four canonical moves per species; the
result is an explicitly marked competitive preset with maximum DVs and PP. Generated
parties retain ordered legal move histories and resource witnesses.
`--weighted-final-species` retains the legacy distribution for differential
runs. It uses
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
across eight root seeds. Every generated arena and collection schedule assigns
one third of pairs to 6v6. One third of those 6v6 pairs use two fully level-100
teams; the remaining generated teams retain the ROM-floor-to-100 level
distribution. Collection artifacts and the dashboard report all 151 species
counts from one canonical leg per pair so paired replays do not inflate coverage.
Production collection groups every two
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
remain reported diagnostics but do not gate promotion. Major-status moves into
an occupied status slot, stat boosts selected at +6, and OHKO moves selected
against a currently faster target are also observational diagnostics only. They
are excluded from the gated type/status denominators and do not reject
collection or promotion. It also reports and gates 1–2, 3–4,
5–6, and unequal-party strata, plus a nine-team fixed campaign suite covering
Brock through Giovanni and Lance. The campaign teams use canonical natural
moves and fixed DVs inside the link quotient; they do not claim trainer AI or
item equivalence. The v16–v23 pipelines separate a persistent shadow learner from the
quality-gated deployed incumbent. Inconclusive evaluations retain the incumbent
but carry the learner parameters and AdamW state into the next collection
iteration, allowing small updates to compound without weakening deployment. Each
checkpoint stores both lineages; ordinary checkpoint loading returns the deployed
model, while resume restores the shadow learner and its optimizer explicitly.
Search gives the three statically redundant action classes a 0.25 neural-prior
multiplier while preserving nonzero mass and evaluating every legal joint action.
This is intentionally not a legal-mask rule: simultaneous switching can make a
status or OHKO choice useful against the incoming target, and exact joint payoffs
remain authoritative.
A new same-schema lineage can pass the exported shadow to
`--warm-start-checkpoint` and the prior quality-gated checkpoint to
`--warm-start-incumbent-checkpoint`. This preserves the accumulated learner
without silently deploying it; the new optimizer lineage starts fresh.

## Model

The v23 model retains the v22 encoder, which maps the 492-field observation into 31 bound semantic entity
tokens plus CLS: twelve party members, two active states, eight move
descriptors, six switch matchups, two selection records, and one global record.
Field-specific projections preserve value-to-field binding inside each entity;
species and move embeddings retain categorical identity. This replaces the
493-token scalar self-attention path while leaving it available as
`--token-layout scalar-v1` for differential checks. The production semantic
network has 937,949 parameters and a 32-token sequence. The v4 schema retains
v3's move descriptors,
current type-effectiveness values, offensive/incoming matchup scores, and Mimic
continuation action. It appends both party counts and twelve presence bits while
zeroing every absent party and switch descriptor; present fainted members retain
presence `1` with HP `0`. This
keeps small networks from having to rediscover static ROM tables from terminal
labels. Three heads predict:

- logits for the canonical player's 13 stable link action IDs;
- logits for the opposing side's 13 action IDs from the same physical state;
- one bounded zero-sum value in `[-1, 1]`, whose opposing value is exactly its
  negation.

Mirror search therefore encodes one physical state rather than evaluating two
swapped canonical rows. Distinct candidate/incumbent controllers still each
encode their own canonical view, preserving each model's policy and value.
Ordinary successor leaves use a 64-hidden-unit MLP trained against both terminal
returns and the detached main value. Roots and expanded nodes still use the full
semantic encoder for priors and values. The distilled leaf is an estimator only;
Lean remains the transition and terminal authority. A one-logit budget head is
trained only from witnessed full-search disagreement and is consumed after the
complete root matrix has already been solved.

Encoder and head matrix operations run under BF16 autocast. Both head outputs
are immediately promoted to FP32 before masks, softmax, RM+ search, losses, or
reductions, and all trainable parameters and optimizer state stay FP32. Native
UInt16 rows use reusable pinned buffers, legal masks come from a device lookup,
and CUDA inference uses static compiled batch buckets. Exact feature/mask cache
keys suppress duplicate forwards without claiming mechanics-state equivalence.

Search and policy loss mask illegal actions. Every expanded node retains an
empirical joint payoff matrix, cumulative RM+ regrets, average strategies,
explicit chance outcomes, and immutable child handles. Full expanded-node
inference is a mandatory pooled frontier: a missing evaluation fails rather
than falling back to synchronous batch-one inference. The root matrix is
complete; progressive deeper matrices represent unvisited pairs with the neural
leaf prior while mandatory exploration gives every legal action initial support.
A dense,
antisymmetric HP/faint/status delta stabilizes one-step leaf estimates. No
post-solver switch cap or other semantic policy override remains: the fresh
2,048-update RM+ solve alone determines final move and switch mass. Online RM+
still guides deeper traversal, but the published root target never averages
strategies from obsolete payoff matrices. Common random numbers couple initial
sampled chance seeds across actions only inside the estimator; each action
retains the required `fresh-root-v1` marginal distribution. Additional chance
sampling follows `max(0.10, 1/sqrt(n))` for pair evidence `n`, and deeper
exploration progressively mixes RM+ with the normalized neural prior rather
than uniform noise. The old sequential Exp3 path and its replay compatibility
have been removed.
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
root leaf inference, RM+ decisions, and real episode transitions are batched
across compatible independent roots. Deeper progressive simulations are
resumable frontiers: native requests and leaf rows are pooled across roots and
model identities, then deterministic cohorts overlap Lean mechanics with GPU
inference. Independent search, chance, and deep-tier RNG streams are retained.
Random deep-search tiers have been removed. `--deep-search-fraction` is fixed at
1.0 for compatibility, while the learned router labels full-search examples by
whether depth changed an argmax, moved the two-side policy by at least 0.25, or
changed root value by at least 0.10. Root-only decisions receive no fabricated
counterfactual label. Positive examples receive 4× classifier weight; held-out
recall, precision, Brier score, and forced-calibration outcomes remain explicit.

Promotion, campaign, probe, and final arenas use the same RM+ tree parameters
and every-decision action selector as collection. They keep live games on one
Lean server while batching inference, episode steps, and handle compaction.
Probe arenas use 64-game
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
