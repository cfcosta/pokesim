# Self-play training pipeline

<!-- mode: explanation -->

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

The restricted profile now also has a complete executable training slice in `packages/battle-training`: `battleSearchServer` owns immutable Lean states and batches independent branches, `fresh-root-v1` forks hidden search chance, exhaustive root search solves a sampled joint-action payoff matrix with regret matching+, and a CUDA-capable transformer learns policy/value targets. Sequential Exp3 MCTS remains a comparison solver. The first search shard is regenerated byte for byte from checkpoint zero.

These pieces are still not a complete **full-party** training API:

1. `Battle.Full.Environment.Observation` omits PP, stages, volatile counters, screens, substitutes, loaded/selected move scratch, inventories, and other mechanics-visible state. It is neither a full Markov state nor a hidden-information history.
2. The full self-play loop requests a pair of actions even at boundaries where only one player has a real decision, such as forced replacement. Nested Mimic, external random, learning, and evolution requests do not share one normalized decision protocol.
3. `Battle.RL.Adapter.OrdinarySnapshot` round-trips a policy observation, not the complete mechanics state required to pause, clone, and resume arbitrary search nodes.
4. The restricted profile has stable action IDs, a 100-field tensor, immutable branch handles, and native batch stepping. The full profile still lacks the corresponding schema, binary episode format, and batch stepping API.
5. The full observation exposes both generated teams and active moves. It is useful for centralized debugging but cannot be called a player-information policy.
6. `Battle.RL.SelfPlay.seedFrom` is a smoke-test constructor, not a production seed expander. After byte truncation it has only 256 distinct, linearly related ten-byte blocks regardless of the input `Nat`.

## Game profiles

Training claims attach to a named profile.

| Profile | Mechanics | Information | Purpose |
|---|---|---|---|
| `ordinary-link-1v1-perfect-v1` | Restricted ordinary-move kernel in link mode | Complete active state, future RNG hidden | Plumbing, exact search tests, throughput baselines |
| `full-link-perfect-v1` | Synchronized full-party quotient, moves and switches, no bag items | Complete mechanics state, future RNG hidden | First serious search-guided self-play |
| `full-link-paired-player-v1` | Two cartridge perspectives, serial actions, clock roles, and desynchronization | Own team plus observed opponent history | Emulator deployment profile |
| `red-driver-audit-v1` | Sampled ROM-linked episodes | Profile-specific | Differential audit only; never the training hot path |

Team construction is initially outside the policy. `DynamicGenerator` supplies progression-witnessed parties from independent entropy. Later work may train team builders in an outer population game, but mixing team construction and battle control in the first loop would make failures difficult to localize.

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

The perfect-information tensor must include every field needed to predict the distribution of subsequent policy-visible states after future random bytes are sampled. At minimum this includes:

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

At an ordinary decision, legal actions form a payoff matrix `Q[playerAction, enemyAction]`. The production search is `simultaneous-matrix-tree-rmplus-v1`: a persistent depth-four tree with a 320-native-transition budget. Root expansion evaluates every legal joint action under common-random-number chance. Deeper node expansion uses two cyclic joint-action rotations, which give every legal move and switch initial support without paying for every pair, and progressively samples additional pairs selected by the local equilibrium and exploration policy.

Every expanded node retains empirical joint returns, counts, immutable chance children, cumulative RM+ regrets, and average strategies. Regret updates occur after expansion, fresh chance samples, and backed-up descendant values. Unvisited deeper joint pairs carry the neural state-value prior until sampled; artifacts therefore report sampled joint coverage rather than presenting the progressive matrix as exhaustive. The root's average strategies become the two policy targets, not alternating-player visit distributions. The sequential Exp3 implementation has been removed.

### Genuine simultaneous tree search

The implemented tree makes each expanded ordinary, forced-replacement, or Mimic request a typed node. Selection samples both sides from an exploration-safe regret-matched strategy; ordinary alternating-player PUCT is not an equilibrium solver for these nodes. A simulation alternates simultaneous decision nodes and explicit chance outcomes. Search-derived chance keys remain independent of the episode's unseen RNG suffix. Terminal results back up `+1/-1/0`; horizon stops, semantic divergence, blocked requests, and mechanics timeouts remain unlabeled.

All legal ordinary actions receive initial support. Policy-ranked top-k removal is not admissible: the measured speedup comes from failing to consider legal actions. The progressive deeper matrix distinguishes neural-prior entries from mechanics-sampled entries and reports tree nodes, successful simulations, maximum reached depth, chance outcomes, root solves, and sampled joint coverage. Exact matrix tests and a two-stage stochastic toy game check equilibrium solving and deeper backup behavior.

The remaining practical bottleneck is cross-root batching. The native server now provides `reset-append` and `compact-many`, so several episode roots can remain live without rebuilding mechanics state. The actor still needs a scheduler that collects frontier expansions from those roots into shared native-transition and accelerator-inference batches. Tree state remains handle-local; transposition merging requires a collision-resistant identity over every mechanics-relevant field except freshly sampled future chance, which the 477-field policy fingerprint is not yet proved to provide.

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

### Replay storage

Each episode header records:

- schema, mechanics commit, profile, observation, action, generator, and reward versions;
- team histories and resource-relative legality witnesses or their stable artifact hashes;
- checkpoint IDs and league sampling probabilities;
- independent entropy roots and derivation labels;
- initial state and transcript hashes.

Each decision records observations, masks, chosen actions, search targets, root values, semantic events, and resulting hashes for every real participant. The trailer records terminal provenance or the exact nonterminal stop reason. Full audit transcripts can live beside compact learner tensors; the compact record must be derivable from the audit form.

Physical storage may use Arrow IPC, Parquet, or a custom binary frame after measurement. The logical schema and deterministic round trip come first.

## League and data mixture

The actor scheduler samples from a declared mixture rather than always pairing the newest checkpoint with itself:

- current main policy;
- recent and milestone historical checkpoints;
- random, first-legal, damaging, and later domain heuristics;
- exploiters trained against the main-policy mixture;
- approximate best responses used for evaluation;
- fixed mechanics/adversarial teams;
- broad progression-witnessed generated teams;
- held-out team distributions that never feed training.

A payoff matrix tracks policy-by-policy and profile-by-profile results. A PSRO-style meta-solver can later choose opponent probabilities. Elo or Glicko is a presentation statistic, not the sole promotion criterion, because a single rating hides cycles.

## Evaluation

Every promoted checkpoint is evaluated with paired teams, paired randomness, and swapped sides. Reports include confidence intervals and at least:

- win rate against fixed baselines;
- round-robin payoff matrix against historical checkpoints;
- resistance to trained exploiters or approximate best responses;
- held-out generator distributions and fixed competitive teams;
- 1v1, 3v3, and 6v6 slices;
- short/long battle and mechanics-edge-case slices;
- search-budget scaling and network-only versus search-assisted strength;
- transition, inference, and end-to-end actor throughput;
- terminal, truncation, blocked, RNG-stuck, division-freeze, and nested-open counts;
- exact transcript replay success.

Two leakage checks are mandatory. First, states with the same policy information but different hidden future battle RNG must produce the same network output and, for a fixed search seed, the same search distribution. Second, changing hidden opponent data outside a player information set must not change a player-view decision unless the belief sampler's public inputs changed.

## Dependency-ordered milestones

### M0: Training contracts

Define one normalized decision-request machine, a full perfect-information tensor projection, a stable link-action dictionary, complete state pause/clone semantics, stock-link setup entropy, clock-role handling, an explicit search chance-fork model, deterministic transcript hashes, and exact terminal/truncation labels for `ordinary-link-1v1-perfect-v1`.

### M1: Reproducible baseline arena

Produce immutable episode shards from random, first-legal, and damaging policies. Add paired-seed tournaments, side swapping, confidence intervals, payoff matrices, and deterministic replay. This milestone measures the native worker and storage path without neural inference.

### M2: Native simultaneous search

The restricted implementation now has sampled stochastic simultaneous MCTS with independent selection/chance entropy, Exp3 node strategies, transformer leaf values, and `fresh-root-v1`. Shallow exhaustive joint-action checks, regret matching, exploitability proxies, and simulation-scaling evaluation remain open.

### M3: AlphaZero-style learner

The restricted implementation now trains a side-canonical transformer with search-policy cross-entropy, terminal-value MSE, AdamW, replay shards, and model/optimizer checkpoints. Multi-worker batched inference, replay-window sampling, resumption, and comparisons against network-only, best-response PUCT, and regret MCTS remain open.

### M4: League training

Add historical mixtures, main exploiters, league exploiters, payoff-matrix sampling, and promotion gates. Expand from ordinary 1v1 to the normalized full-link perfect-information request machine, then 3v3 and 6v6.

### M5: Player-view training

Define observable-event memory, hidden-team priors, and recurrent policy state. Train model-free player-view baselines before adding determinization or belief search. Treat sound imperfect-information search as a separate research result.

### M6: ROM-linked audit sampling

Replay a statistically useful sample of generated episodes through the eventual concrete ROM-linked fixture. Processor execution remains outside self-play and inference. A mismatch blocks the affected mechanics profile but does not silently alter training data.

## First implementation slice

The implemented slice closes the restricted portions of M0–M3 on `ordinary-link-1v1-perfect-v1`: immutable Lean search handles, a hidden-future-free chance fork, Exp3 simultaneous MCTS, a small transformer, terminal-backed targets, checkpoints, an arena, manifests, and deterministic shard replay. It deliberately does not introduce MuZero, hidden teams, or a duplicate Python simulator. Before calling a policy deployable, full-party requests must be normalized and the synchronized quotient must replay through `Battle.Full.Link.Pair` with both clock roles and explicit desynchronization outcomes.
