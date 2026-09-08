# Self-play training pipeline

<!-- mode: explanation -->

For the current executable v33 contracts and defaults, use the
[search-assisted controller](search-assisted-controller.md). The implementation
snapshots and performance claims below describe earlier lineages; in particular,
the shared evaluator, split-half policy averaging, and distilled defaults have
been replaced.

This page proposes a training architecture around the theorem-backed high-level `Battle` model. It describes boundaries and sequencing; it is not an implementation guide. The supporting literature survey is [Self-play, reinforcement learning, and search research](../research/self-play-rl-search-literature.md).

## Decision

Build an actor–learner pipeline in which native Battle workers own mechanics state and search, a batched accelerator service evaluates policy/value leaves, immutable episode shards feed an external learner, and a league controls opponent sampling.

The first serious game profile is perfect-information, stochastic, simultaneous-action link battle. Restricted one-mon battles that use the link RNG are the plumbing test; full generated link parties are the target. The deployment target is a policy controlling one cartridge perspective through an emulator's virtual link cable. Player-view hidden-information training follows as a different profile rather than silently changing the observation contract.

## Why this shape

### Inversion

The project fails if training labels can confuse truncation with a terminal result, search can inspect future battle RNG, invalid actions are silently repaired, latest-policy self-play forgets old counters, or an optimized mirror simulator drifts from `Battle`. The architecture therefore keeps mechanics, search entropy, terminal provenance, and population evaluation explicit.

### The map is not the territory

The high-level model is extensively theorem-backed but is not yet unconditionally equivalent to continuous cartridge execution. A generated team distribution is not the competitive metagame, a perfect-information observation is not a player observation, and Pokémon Showdown is not Pokémon Red. Every artifact carries mechanics, observation, action, generator, and training-profile versions so results cannot cross those boundaries unnoticed.

### Theory of constraints

A five-run native smoke benchmark currently executes 9,620 full-model transitions in a median 62.4 ms per 100-episode run, about 154,000 transitions/second on this machine. That number includes process startup and random-policy overhead and is not a search microbenchmark. MCTS multiplies mechanics work by simulation depth and count; after batching, accelerator inference and inter-process transport are likely to become the bottleneck. Search therefore remains beside the native state, while only tensors and predictions cross the inference boundary.

### Feedback loops

Self-play changes the data distribution that trains the next opponent. Latest-policy mirror play can cycle or become narrowly adapted to itself. A replay window, frozen checkpoints, fixed heuristics, exploiters, held-out teams, and a payoff matrix make that feedback loop observable and provide negative feedback against forgetting.

### Multiplication by zero

A single semantic zero invalidates the whole result: leaked RNG makes search strength fake; a non-Markov "perfect" observation makes value targets ambiguous; missing nested decisions means the agent is not controlling the claimed game; a repaired invalid action trains on a transition the policy never selected. Contract work precedes scale because no amount of actor throughput repairs a corrupted target.

### Where the lenses disagree

AlphaZero-style simplicity argues for starting self-play immediately with the existing observation and paired `step`. Inversion and multiplication-by-zero argue that the current API is not yet a stable training boundary. Theory of constraints argues against spending months on a maximal codec before measuring search. The compromise is narrow but strict: close only the contracts needed by the restricted profile, build a complete end-to-end loop there, then widen one profile at a time.

The dominant lens is **multiplication by zero**. Training starts only after the selected profile has complete decision, observation, action, chance, terminal, and replay contracts.

## Current usable substrate

The repository already provides:

- `Battle.RL.Environment`: progression-witnessed one-mon teams, ordinary damaging moves, legal masks, perfect/player observations, explicit settlement, and typed execution failures;
- `Battle.RL.SelfPlay`: independent generator, battle, and per-policy entropy; deterministic random/first policies; replay transitions; and honest truncation;
- `Battle.Full.Environment`: generated parties of one to six, full move effects, switching, forced replacement, progression, and nested request results;
- `Battle.Full.SelfPlay`: full-party model self-play with random and damaging baselines;
- `Battle.RL.Adapter`: reward noninterference, typed transcript commands, and action-commit versus full-selection separation;
- deterministic Pokémon Showdown team and protocol renderers for inspection.

`packages/battle-training` now runs the one-to-six-member full-party profile. `battleSearchServer` owns immutable Lean states, typed forced-replacement and Mimic requests, fresh search chance, multi-root retention, and batched episode transitions. A 492-field side-canonical transformer learns policy/value targets from simultaneous matrix trees. The first search shard is regenerated byte for byte from checkpoint zero; the old sequential Exp3 solver has been removed.

The remaining API limits are narrower but still material:

1. The v3 field audit fixed a missing Mimic continuation, but tensor injectivity and transition-kernel sufficiency are not yet universal Lean theorems.
2. Learning, evolution, naming, external non-link random input, and full menu traces remain outside the named link-training profile.
3. The synchronized environment is one-state link quotient execution, not `Battle.Full.Link.Pair` with two cartridge perspectives and clock roles.
4. JSONL is deterministic and hash-checked, but there is no versioned binary episode format.
5. The tensor exposes both generated teams and active moves. It is a perfect-information policy and cannot be reused as a player-information policy.
6. `fresh-root-v1` is independent of the hidden episode suffix but is not the stronger posterior over stock nine-byte link blocks conditioned on visible history.

## Game profiles

Training claims attach to a named profile.

| Profile | Mechanics | Information | Purpose |
|---|---|---|---|
| `ordinary-link-1v1-perfect-v1` | Restricted ordinary-move kernel in link mode | Complete active state, future RNG hidden | Plumbing, exact search tests, throughput baselines |
| `full-link-party-1to6-perfect-v2` | Synchronized one-to-six-member quotient, moves and switches, no bag items | Complete declared policy state, explicit party shape, future RNG hidden | Current search-guided self-play |
| `full-link-paired-player-v1` | Two cartridge perspectives, serial actions, clock roles, and desynchronization | Own team plus observed opponent history | Emulator deployment profile |
| `red-driver-audit-v1` | Sampled ROM-linked episodes | Profile-specific | Differential audit only; never the training hot path |

Team construction is initially outside the policy. `DynamicGenerator` supplies parties from independent entropy. V17 maps two already-consumed entropy bytes to the displayed final species; across all 65,536 words, each of the 151 species has 434 or 435 preimages. It skips the older evolutionary-family promotion funnel, which had made common final evolutions appear over twenty times as often as the least frequent base forms in completed v16 collections. Generated species still start replayable ordered acquisition/machine/PP-Up histories under the same party-wide ledger. For full level-100 parties, a separate 26-of-256 gate selects a near-uniform member of the top 200 exact teams reconstructed from public Generation-I Showdown replays. Those canonical competitive presets include inferred four-move sets and are explicitly distinguished from progression histories. The old evolution-weighted profile remains available for artifact replay and differential runs. Later work may train team builders in an outer population game, but mixing team construction and battle control in the first loop would make failures difficult to localize.

## Emulator deployment

The clean deployment path uses a real link battle. Two stock ROM instances can be connected through the emulator's virtual serial cable, with the policy driving joypad input on one instance. A single emulator can instead implement the remote serial peer, including party exchange, action nybbles, clock role, and RNG-list setup. Neither design needs to pretend that an ordinary trainer battle is a link battle.

`Battle.Full.Link.Pair` already states the right semantic shape: each cartridge owns its local player party, a disposable mirror of the remote party, a link RNG cursor, and a clock role. The synchronized one-state environment is a useful hot-path quotient, but it is valid only while mirrored active state, RNG, and terminal phase agree. Psywave, Bide faint cleanup, generated trapping wrappers, setup quirks, and later discoveries can force the paired profile to continue without that quotient.

A real link setup generates ten bytes with hardware `Random`, rejecting values greater than or equal to `$FD`. The internal-clock cartridge keeps its list; the external-clock cartridge copies it. The receiver incorrectly skips a legitimate leading zero, so a generated block beginning with zero can break synchronization. Training entropy for the stock-link profile must reproduce this setup law, randomize clock roles, and either model the leading-zero mismatch or declare and enforce a synchronized-setup precondition.

### Link mode is not an RNG switch

Setting `wLinkState := LINK_STATE_BATTLING` changes more than `BattleRandom`:

- enemy actions come from serial exchange rather than wild or trainer AI;
- battle items have no link action encoding;
- badge stat boosts are disabled;
- the ordinary enemy stat-down 25% failure branch is disabled;
- experience gain and trainer payout are skipped;
- faint replacement, run, text, result, evolution, cleanup, and party persistence follow link paths;
- equal-Speed order depends on which cartridge owns the internal clock.

Globally forcing that byte inside ordinary wild or trainer battles would create a hybrid with poorly defined control flow. It is not an acceptable shortcut.

A narrower ROM variant could make `BattleRandom` always enter the shared-list body while leaving `wLinkState` and `wIsInBattle` unchanged. That requires initializing the ten-byte list and index at every battle. It still would not route every battle-related random call through the list: trainer action AI, capture, Safari behavior, setup, and VBlank call hardware `Random` directly. Such a ROM is an **ordinary-battle deterministic-RNG variant**, not the stock link profile. It needs its own ROM hash, patch certificate, mechanics profile, and evaluation suite.

| Deployment | ROM changes | Mechanics match | Recommendation |
|---|---:|---|---|
| Two emulator instances with virtual cable | None | Stock paired link battle | Primary reference deployment |
| One emulator plus a virtual serial peer | None | Stock paired link battle if the peer implements setup/exchange exactly | Best product path after the reference works |
| Hook only `BattleRandom` and seed its WRAM list | Yes, or an emulator PC/WRAM hook | Ordinary battle with deterministic combat RNG | Separate experiment, useful for campaign agents |
| Force `wLinkState` globally | Yes | Accidental hybrid of link and ordinary paths | Reject |

## Decision protocol

A policy acts on decision requests, not nominal turns. A request identifies:

- the acting participants: player, enemy, or both;
- the typed decision kind: paired battle action, forced replacement, Mimic target, run response, learning, evolution, naming, or selection trace;
- one observation and legal mask per participant;
- an opaque mechanics-state handle owned by the worker;
- transcript and state hashes.

The worker executes automatic mechanics until it reaches the next genuine request, an `ending` witness, a returned result, or a typed open/divergent outcome. Automatic charge/trapping continuations and generated-move continuations do not create policy samples. A forced replacement does not train the waiting side on an ignored action.

For the initial link profiles, the fixed battle-action dictionary can reserve IDs for four fight slots, six switch slots, Struggle, no-action continuation, and run/forfeit. Legal masks, not context-dependent reinterpretation, determine availability. Nested protocols use separate typed dictionaries and schema versions.

## Information contract

### Central mechanics state

Search workers retain the complete `Full.Environment.State`. This state is the transition input and audit source. It is not automatically a policy observation.

### Perfect-information policy state

The perfect-information tensor must include every field needed to predict the distribution of subsequent policy-visible states after future random bytes are sampled. The field audit is recorded in [Full-link training-state audit](../research/full-training-markov-audit.md); it found and fixed a missing Mimic continuation action in schema v3. At minimum this includes:

- both parties and active indexes;
- level, HP, stats, types, status, moves, packed PP, DVs, and relevant persistent fields;
- stages, unmodified stats, volatile flags/counters, screens, substitutes, Disable, Bide, trapping, charge, recharge, and seeded state;
- selected and loaded move scratch where it affects priority, Counter, PP, or continuation;
- battle mode, phase, forced replacement, turn, and terminal witness;
- inventories and trainer/controller fields for profiles that expose them.

Future random bytes and simulation seeds are excluded. Although the executable environment contains a deterministic RNG cursor for replay, it is latent chance from the policy's perspective.

### Player-information state

The player profile observes its complete own side and only opponent facts revealed by battle events. A recurrent model receives the ordered observation/action/event history. Hidden team composition, moves, PP, DVs, and future RNG remain absent.

A centralized critic may consume privileged state during experiments, but its use must be named. An evaluation policy must execute from the declared player view alone.

## Search semantics

### Simultaneous decision nodes

At an ordinary decision, legal actions form a payoff matrix `Q[playerAction, enemyAction]`. The production search is `simultaneous-matrix-tree-rust-cfrplus-pooled-node-split-half-v5`: a persistent depth-four tree with a 320-native-transition budget. Its final root policy averages the mean-matrix solve with two common-random-number split-half solves, reducing brittle action flips when sampled payoffs are near-tied. Root expansion evaluates every legal joint action under common-random-number chance. Deeper node expansion uses two cyclic joint-action rotations, which give every legal move and switch initial support without paying for every pair, and progressively samples additional pairs selected by the local equilibrium and a decaying neural-prior exploration mixture.

Every expanded node retains empirical joint returns, counts, immutable chance children, cumulative nonnegative regrets, and linearly weighted average strategies. Online CFR+-style regret updates occur after expansion, fresh chance samples, and backed-up descendant values. They guide traversal while the matrix changes; they are not published as the final root equilibrium. Once the root-only or deep budget ends, a fresh deterministic 2,048-update CFR+-accelerated RM+ solve computes both policy targets from the current complete root matrix. No post-solver switch cap or other semantic strategy override is applied. Unvisited deeper joint pairs carry the neural state-value prior until sampled; artifacts therefore report sampled joint coverage rather than presenting the progressive matrix as exhaustive. Collection, promotion, campaign evaluation, skill probes, final arenas, and replay-producing neural battles run this search at every real decision. Sparse network-policy action rollout and the sequential Exp3 implementation have been removed. Neural inference still supplies RM+ priors and leaf values; it never directly selects a semantic action. If semantic divergence prevents construction of an RM+ strategy, execution fails closed without selecting or labeling a raw-policy fallback.

### Genuine simultaneous tree search

The implemented tree makes each expanded ordinary, forced-replacement, or Mimic request a typed node. Selection samples both sides from an exploration-safe regret-matched strategy; ordinary alternating-player PUCT is not an equilibrium solver for these nodes. A simulation alternates simultaneous decision nodes and explicit chance outcomes. Search-derived chance keys remain independent of the episode's unseen RNG suffix. Terminal results back up `+1/-1/0`; horizon stops, semantic divergence, blocked requests, and mechanics timeouts remain unlabeled.

All legal ordinary actions receive initial support. Policy-ranked top-k removal is not admissible: the measured speedup comes from failing to consider legal actions. The progressive deeper matrix distinguishes neural-prior entries from mechanics-sampled entries and reports tree nodes, successful simulations, maximum reached depth, chance outcomes, root solves, and sampled joint coverage. Exact matrix tests and a two-stage stochastic toy game check equilibrium solving and deeper backup behavior.

Each actor process retains up to 16 live episodes with `reset-append` and handle-only compaction. Complete roots and deeper recursion are represented as resumable native/inference frontiers. Every deterministic round pools native requests into one `search_steps` call and leaf rows by network identity; pooled ordinary and dual-policy inference apply the same observational redundant-action prior shaping before caching. V24 additionally represents promotion of a distilled successor into an expanded node as a full-inference frontier. The scheduler holds those frontiers to a cross-root barrier, so mirror nodes use the dual-policy joint evaluator and candidate/incumbent nodes batch by model identity instead of issuing one or two synchronous canonical rows. V26 moves only dense RM+/CFR+ arithmetic behind a hashed Rust C ABI; the Python scheduler, Lean batches, CUDA inference, complete root, chance streams, and divergence handling remain outside Rust. Staggered cohorts overlap the trailing Lean batch with the leading GPU batch. Eight- and sixteen-root comparisons retained identical policies, values, actions, and transition counts. The 16-root frontier scheduler raised mean neural batches from 61.6 to 84.2 before double-buffering; overlap then improved its median wall time by 1.29×. Production uses eight spawned actor processes with separate Lean servers and deterministic episode-indexed shard merging. V27 separately uses twelve persistent evaluation workers and balanced pair-preserving spans; fourteen workers consumed more VRAM but reduced evaluation throughput. Exact observation memoization remains separate from mechanics transposition merging, which still requires a proved mechanics identity. See [Variable-party tree-search performance](../research/variable-party-tree-search-performance.md), the [persistent evaluation-pool review](../research/persistent-evaluation-pool.md), and the [production search-quality review](../research/production-simultaneous-mcts-quality-review.md).

### Chance

Each simulation receives a search RNG stream derived from the experiment seed, episode ID, root decision index, worker, and simulation index. A counter-based PRNG or versioned hash expands that identity, then the stock-link profile rejection-samples setup bytes below `$FD`; the existing correlated `seedFrom` helper is not used. Search samples semantic outcomes through the `Battle` high-level mechanics. It never reads or clones the episode's unseen future RNG bytes.

Mid-battle resampling needs an explicit chance model. Fresh root resampling is a practical first approximation, but visible hits, misses, damage, and side effects contain information about previously consumed bytes, and link-list regeneration can correlate that information with later bytes. A stronger profile maintains particles over initial blocks and conditions them on the public action/event history. Episode artifacts therefore name the chance model, such as `fresh-root-v1` or `link-posterior-v1`; neither is silently presented as access to the concrete episode's hidden RNG state.

Generator, episode mechanics, player exploration, enemy exploration, search, replay sampling, model initialization, and evaluation pairing remain independent streams. Their derivation tree and expansion algorithms are stored in the run manifest.

### Single-participant and nested nodes

Forced replacements and menu responses are ordinary one-player decision nodes. Automatic mechanics are collapsed only to the next request while preserving events and chance consumption. Search must support these nodes before the corresponding mechanic is enabled in a profile.

### Imperfect information

Perfect-information trees key nodes by complete observable mechanics state excluding future chance. Player-view trees key by information history or a proved sufficient statistic. Root-sampling hidden teams is allowed only under an explicitly experimental determinization profile. Search actions must be invariant to hidden details that are outside the sampled player's information set; otherwise the implementation has leaked information or fused strategies.

## Policy/value model

One side-canonical network is shared by both players. Swapping sides converts an enemy request into the same “self/opponent” representation used for a player request.

The first network should be smaller than the simulator workload, not modeled after a large language system:

- categorical embeddings for species, moves, types, status flags, and action kind;
- per-Pokémon and per-move encoders with slot markers;
- a party/entity aggregator;
- global battle features;
- a masked policy head over the stable action dictionary;
- one zero-sum scalar value head in `[-1, 1]`.

The implemented restricted baseline uses a transformer despite the small state: every scalar becomes low/high-byte embeddings plus a field-position embedding, and a learned CLS token feeds four-action policy and scalar value heads. This establishes the same model family intended for later observable histories. It is deliberately small—two layers in smoke runs and four in the first training default—rather than modeled after a language model. Auxiliary heads may later predict revealed opponent properties or immediate events, but they do not replace the terminal value objective.

The initial loss follows the AlphaZero pattern:

```text
L = policy_cross_entropy(search_policy, network_policy)
  + value_loss(terminal_outcome, network_value)
  + regularization
```

Terminal win/loss/draw from the acting side gives `+1/-1/0`. Horizon truncation, blocked requests, RNG-stuck states, and division freezes do not receive fabricated terminal labels. Sparse terminal reward is the primary objective. Any HP or event shaping is logged as a separate wrapper and evaluated for policy distortion.

## Runtime architecture

```text
team/profile sampler ─────┐
league opponent sampler ──┼──> native actor / Battle worker
checkpoint registry ──────┘        │
                                   ├─ owns immutable mechanics states
                                   ├─ owns MCTS nodes and simulation RNG
                                   ├─ batches leaf tensors ───────┐
                                   │                              v
                                   │                    accelerator inference
                                   │                              │
                                   └─ receives policy/value <─────┘
                                            │
                                            v
                                  immutable episode shards
                                            │
                         ┌──────────────────┴──────────────────┐
                         v                                     v
                   replay sampler                      audit/replay checker
                         │
                         v
                  policy/value learner
                         │
                         v
                  checkpoint registry
                         │
                         v
                league and evaluation arena
```

### Native actors

The native worker keeps state cloning and tree expansion in-process. Lean's immutable values can share unchanged structure between branches. A heuristic evaluator and rollout search can be implemented before any accelerator protocol exists.

When neural evaluation is added, workers send batches of leaf tensors and legal masks to an inference service. They do not send full mechanics states for every edge. A framed binary process protocol is the first transport candidate; a C ABI or shared memory is justified only after profiling. JSON and Pokémon Showdown text remain diagnostics, not hot-path formats.

### Learner

The learner may be implemented in PyTorch or another external ML stack. It does not import, mutate, or reimplement mechanics. It consumes versioned shards, samples replay positions, updates the network, and publishes immutable checkpoints with optimizer state and run metadata.

The v4 tensor appends own/opponent party counts and twelve side-canonical presence bits to the 478 v3 fields. Absent party and switch descriptors are zero; a fainted member remains present with HP zero. Training rotates through every ordered `1v1` through `6v6` size pair, so equal-size self-play cannot hide one-sided roster disadvantages. Promotion separately gates 1–2, 3–4, 5–6, unequal-party, and fixed campaign-team results.

The v12 production runner keeps two explicit lineages. A persistent shadow learner and its AdamW state accumulate every completed update; a deployed incumbent changes only after promotion. Each atomic checkpoint stores the deployed model, shadow model, learner optimizer, RNG state, and metrics needed to reconstruct the completed prefix. `transformer-resume` validates checkpoint and shard continuity, restores both model lineages and the historical-opponent window, and continues at the next iteration under the immutable saved configuration. An uncommitted partial iteration is archived and replayed from its beginning; the system does not claim mid-battle checkpointing. A new same-schema lineage may initialize its learner and incumbent from separate immutable checkpoints: the latest shadow remains the learner while the last promoted model remains deployed, and a fresh optimizer prevents incompatible objective state from crossing the lineage boundary.

Each training epoch reports separately backpropagated shared-trunk policy and value gradient norms, their raw and objective-weighted norm ratios, cosine, and negative-cosine frequency. A deterministic whole-battle split withholds complete shard/episode groups from optimization and reports equal-row and equal-battle value MSE against a zero predictor, plus held-out policy KL and top-action agreement. These diagnostics are written to stdout, immutable iteration metrics, and the read-only monitor; row-random validation is not used. V16 uses one epoch and weights value MSE by 0.25 after v15's second epoch worsened held-out value MSE in 14 of 17 completed iterations and raw value-trunk gradients were commonly five to eight times the policy gradients.

The every-decision RM+ selector defines the v18 controller lineage. V19
replaces scalar attention with bound semantic entity tokens, v20 adds dual
policy heads plus an exactly antisymmetric value interpretation, v21 adds a
distilled leaf evaluator, and v22 learns whether to refine beyond the complete
root. V23 retains that architecture but changes the incompatible controller to
a fresh final-matrix RM+ solve, evidence-decayed chance sampling, progressive
prior exploration, and a gated router false-negative audit. V24 routes every
expanded-node full evaluation back through the pooled frontier scheduler and
restores the intended joint dual-policy evaluator at mirror children. V26 moves
the dense solver to Rust and replaces uniform RM+ updates with CFR+ alternating
updates and linear averaging under a new controller lineage. V27 keeps one
balanced twelve-worker evaluation pool alive across promotion, probes, and
campaign, retaining compiled models and publishing live gate progress. Promotion
workers additionally publish atomic, one-second telemetry with completed games,
provisional paired confidence, and recent outcomes; this does not repartition
server batches or change deterministic arena reductions. Final reporting uses
the same process budget at the arena level: each independent
report retains its sequential game and reduction order while workers reuse the
deployed candidate. Earlier checkpoints
cannot resume or warm-start into these changed architectures or controller
semantics; v16/v17 also used different promotion and deployment controllers.

The production PyTorch implementation uses BF16 autocast for transformer and head matrix operations. Parameters, gradients, AdamW state, returned logits/values, masks, softmax, policy/value losses, and reductions remain FP32. On the RTX 3080 Ti this increased batch-128 training throughput by 3.77x and reduced peak allocation from 2.24 to 1.26 GiB. The inference path additionally uses NumPy `frombuffer` decoding, pinned UInt16 staging, a device legal-mask table, one fused output transfer, exact observation memoization, and compiled static buckets through 256 rows. Compiled and eager outputs were bit-identical on matched probes. V19 binds the observation into 31 semantic entity tokens plus CLS rather than attending over 492 independent scalars. Field-specific projections, species embeddings, and move embeddings preserve identity inside party, active, move, switch, selection, and global records. This reduced two compiled batch-96 forwards from 11.49 ms to 2.25 ms (5.11×) on the RTX 3080 Ti. V20 adds an opposing-policy head and interprets the single scalar value antisymmetrically. Mirror search obtains both policies and the zero-sum value from one physical-state encoding; distinct candidate/incumbent models still each evaluate their own canonical view. V21 adds a 64-hidden-unit MLP for unresolved successor values. It is trained against a blend of terminal targets and the detached semantic value, while roots and expanded nodes retain the full network. At compiled batch 256, this leaf path measured 0.372 ms versus 1.819 ms for the full joint model (4.89×). V22 adds a one-logit budget head trained from witnessed root-versus-deep policy, action, and value changes. The first iteration remains fully deep; later decisions always solve the complete root before the router and uncertainty guards decide whether to continue. Ten percent of otherwise skipped roots are forced deep with independent entropy to estimate false negatives. V23 moves that forced sample after all learned and deterministic guards, reports its witnessed false-negative rate, and gates collection above 10% once 128 samples exist. Positive disagreement labels receive 4× weight. The combined network has 937,949 parameters; one compiled joint batch-96 root evaluation measured 1.30 ms versus 2.30 ms for two side-canonical evaluations (1.78×). `--token-layout scalar-v1` and `--inference-engine eager` remain available for differential checks. See the [precision benchmark](../research/full6v6-precision-benchmark.md).

### Read-only monitoring

The trainer atomically publishes a small mutable stage file, one progress file
per self-play actor, and one live telemetry file per active promotion worker while
an iteration is open. Promotion telemetry is refreshed at most once per second
and reports completed games, provisional score/confidence, and recent outcomes.
Completed metrics, checkpoints, promotion battles, campaign cases, probes, and
replay summaries remain the authoritative immutable artifacts. The `monitor` command projects both sets into a loopback web
dashboard; it has no mechanics handles, trainer control endpoint, or write API.
Transient heartbeats are removed before the final manifest, after which the
same dashboard is reconstructed from immutable summaries and iteration metrics.
Self-play and promotion episode rows retain compact initial/final parties and
search/action timelines. Every party row includes all four move slots, current
PP, PP Ups, status, and HP. Each real turn names the acting Pokémon, selected
move or switch target, post-turn events, HP, and leading search policies. The UI
loads pinned Red/Blue sprites from the PokeAPI sprites repository without
vendoring them into the Apache package and falls back to text if unavailable.
Promotion detail is published as one immutable artifact per game. The monitor
loads one detail record on demand when a table row is opened instead of parsing
or transferring every timeline in its polling response. This remains a read-only
artifact projection, not a second mechanics implementation or a claim of
Showdown replay equivalence.

### Replay storage

Each episode header records:

- schema, mechanics commit, profile, observation, action, generator, and reward versions;
- team histories and resource-relative legality witnesses or their stable artifact hashes;
- checkpoint IDs and league sampling probabilities;
- independent entropy roots and derivation labels;
- initial state and transcript hashes.

Each decision records observations, masks, chosen actions, search targets, root values, semantic events, and resulting hashes for every real participant. The trailer records terminal provenance or the exact nonterminal stop reason. Full audit transcripts can live beside compact learner tensors; the compact record must be derivable from the audit form.

Physical storage may use Arrow IPC, Parquet, or a custom binary frame after measurement. The logical schema and deterministic round trip come first.

Browser matches use a stricter server-authoritative envelope described in
[Learning from browser battle traces](human-battle-trace-training.md). They are
replayed and search-relabeled offline before entering a bounded replay component;
raw human choices are not automatically treated as perfect-information policy
targets, and partial matches never receive fabricated terminal labels.

## League and data mixture

The actor scheduler samples from a declared mixture rather than always pairing the newest checkpoint with itself:

- current main policy;
- recent and milestone historical checkpoints;
- random, first-legal, damaging, and later domain heuristics;
- exploiters trained against the main-policy mixture;
- approximate best responses used for evaluation;
- fixed mechanics/adversarial teams;
- broad progression-witnessed generated teams;
- validated, search-relabeled human-encountered states from the training split;
- held-out team and human-trace distributions that never feed training.

A payoff matrix tracks policy-by-policy and profile-by-profile results. A PSRO-style meta-solver can later choose opponent probabilities. Elo or Glicko is a presentation statistic, not the sole promotion criterion, because a single rating hides cycles.

Collection itself is paired rather than only promotion. Two adjacent games share
the generated parties, levels, battle reset, and opponent identity. Candidate
and fixed opponent controllers exchange physical sides while team placement
stays fixed, preventing a favorable generated team from being credited only to
one controller. Because mirror self-play already has one model on both
controllers, its second leg instead installs the exact two generated teams in
opposite physical positions and uses independent policy/search sampling. Pair
legs intentionally share one reset coordinate; different non-frontier pairs may
not. V29 derives the reset root and each controller RNG from a versioned,
SplitMix64-domain-separated tuple of run seed, iteration, global episode, and
stream identity. Spawned actors receive disjoint global episode indices rather
than local counters. Artifacts retain reset, pair, and leg IDs and reject
incomplete, mismatched, incorrectly swapped, or cross-pair-reused coordinates
before training. V16 keeps half of generated pairs as
mirror self-play and half as fixed-opponent pairs. Within the latter half, an
exact deterministic scheduler reserves 50% for deployed/recent model opponents
and 50% for the complete 49-member heuristic population. Thus model opponents
receive 25% of all collection pairs rather than being diluted by a uniform
round-robin over every heuristic identity.

## Evaluation

Every v23 candidate is evaluated through the same every-decision RM+ controller used in collection and deployment, against the deployed incumbent, with 2,048 games formed from 1,024 same-reset pairs. Each pair contains exactly one candidate-player and one candidate-enemy game, and validation fails if that complete side swap is absent. The larger paired arena narrows the interval for the roughly 51–52% candidates that were inconclusive in v15 without weakening the 50% lower-confidence-bound requirement. One third of every generated collection, promotion, probe, and final-arena schedule is 6v6, to within the unavoidable one-pair rounding boundary; fixed campaign fixtures remain their declared canonical sizes. One third of scheduled generated 6v6 pairs set both progression-witnessed parties to level 100. The ordinary level byte is still consumed to preserve generator-stream shape, while the other generated teams retain their ROM-floor-to-100 distribution. Type and status probes remain promotion gates. Switch frequency, completion, and matchup-change measurements are observational because a strategically sound policy may switch more often than its incumbent. Setup use is also observational, with aggregate rates and per-move counts for self boosts, screens, and persistent defensive/utility setup. Three additional non-gating probes count pure major-status moves into the same or a different occupied major-status slot, stat-stage setup at the +6 cap, and OHKO selections against a currently faster active target. They inspect the exact side-canonical active status, stage, and effective-speed fields rather than inferring outcomes from misses. These choices are excluded from the gated type/status probe denominators, so the new observations cannot reject promotion indirectly. Search multiplies only the corresponding neural priors by 0.25 and renormalizes while retaining every legal action. It does not hard-mask them because the opponent's simultaneous switch can make the move valid against the incoming target; exhaustive joint payoff evaluation and RM+ remain authoritative. Collection artifacts count initial species from one canonical leg per pair and the monitor reports distinct coverage plus the minimum/maximum appearance range. Reports include confidence intervals and at least:

- win rate against fixed baselines;
- round-robin payoff matrix against historical checkpoints;
- resistance to trained exploiters or approximate best responses;
- held-out generator distributions and fixed competitive teams;
- 1v1, 3v3, and 6v6 slices;
- short/long battle and mechanics-edge-case slices;
- search-budget scaling and network-only versus search-assisted strength;
- transition, inference, and end-to-end actor throughput;
- terminal, truncation, blocked, RNG-stuck, division-freeze, and nested-open counts;
- exact transcript replay success;
- accepted, quarantined, partial, and divergent browser trace counts, with
  self-play-only versus human-state-relabel ablations.

Two leakage checks are mandatory. First, states with the same policy information but different hidden future battle RNG must produce the same network output and, for a fixed search seed, the same search distribution. Second, changing hidden opponent data outside a player information set must not change a player-view decision unless the belief sampler's public inputs changed.

## Dependency-ordered milestones

### M0: Training contracts

Define one normalized decision-request machine, a full perfect-information tensor projection, a stable link-action dictionary, complete state pause/clone semantics, stock-link setup entropy, clock-role handling, an explicit search chance-fork model, deterministic transcript hashes, and exact terminal/truncation labels for `ordinary-link-1v1-perfect-v1`.

### M1: Reproducible baseline arena

Produce immutable episode shards from random, first-legal, and damaging policies. Add paired-seed tournaments, side swapping, confidence intervals, payoff matrices, and deterministic replay. This milestone measures the native worker and storage path without neural inference.

### M2: Native simultaneous search

The restricted implementation now has sampled stochastic simultaneous MCTS with independent selection/chance entropy, Exp3 node strategies, transformer leaf values, and `fresh-root-v1`. Shallow exhaustive joint-action checks, regret matching, exploitability proxies, and simulation-scaling evaluation remain open.

### M3: AlphaZero-style learner

The restricted implementation now trains a side-canonical transformer with search-policy cross-entropy, terminal-value MSE, AdamW, replay shards, resumable model/optimizer checkpoints, and replay-window sampling. Multi-worker batched inference and comparisons against network-only, best-response PUCT, and regret MCTS remain open.

### M4: League training

Historical checkpoint mixtures, aggressive and switch-heavy deterministic opponents, all 47 canonical trainer-class policy projections, variable one-to-six-member requests, and stratified promotion gates are implemented. The trainer projections preserve move scoring and representable switching, while item actions and their finite per-send-out counter remain outside the link action profile. Main exploiters, league exploiters, server-authoritative human-trace replay/search relabeling, and payoff-matrix population sampling remain open.

### M5: Player-view training

Define observable-event memory, hidden-team priors, and recurrent policy state. Train model-free player-view baselines before adding determinization or belief search. Treat sound imperfect-information search as a separate research result.

### M6: ROM-linked audit sampling

Replay a statistically useful sample of generated episodes through the eventual concrete ROM-linked fixture. Processor execution remains outside self-play and inference. A mismatch blocks the affected mechanics profile but does not silently alter training data.

## First implementation slice

The implemented slice closes the restricted portions of M0–M3 on `ordinary-link-1v1-perfect-v1`: immutable Lean search handles, a hidden-future-free chance fork, Exp3 simultaneous MCTS, a small transformer, terminal-backed targets, checkpoints, an arena, manifests, and deterministic shard replay. It deliberately does not introduce MuZero, hidden teams, or a duplicate Python simulator. Before calling a policy deployable, full-party requests must be normalized and the synchronized quotient must replay through `Battle.Full.Link.Pair` with both clock roles and explicit desynchronization outcomes.
