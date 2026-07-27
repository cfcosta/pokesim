# Self-play, reinforcement learning, and search research

<!-- mode: explanation -->

This note surveys work relevant to training agents against `Battle`. It is a design input, not evidence that an algorithm is correct for Generation-I Pokémon.

## Research method

A Docbert hybrid search of the local research corpus surfaced the complete AlphaZero paper. Its useful details were the joint policy/value network, MCTS visit distribution as a policy target, terminal outcome as a value target, legal-action masking, and the original 800-simulation configuration. Searches for Pokémon, simultaneous-action search, NFSP, PSRO, MuZero, and imperfect-information search did not return comparably relevant local papers, so those topics were checked against primary web sources.

The central finding is that Pokémon is not the game assumed by ordinary AlphaZero. A battle combines simultaneous choices, stochastic transitions, hidden information, non-transitive strategies, and a generated-team distribution. AlphaZero remains a useful training pattern, but its search and self-play rules need to be replaced rather than copied verbatim.

## Direct Pokémon work

### Metamon

[Grigsby et al., 2025](https://arxiv.org/abs/2504.04395), *Human-Level Competitive Pokémon via Scalable Offline Reinforcement Learning with Transformers*, is the closest published system to the intended application.

Metamon reconstructed about 475,000 historical Generation 1–4 Pokémon Showdown battles into roughly 950,000 player-perspective trajectories and 38 million timesteps. It trained recurrent and Transformer policies with imitation and offline-RL objectives, then expanded the data with local self-play. Its observation design relies on history to infer the hidden opponent team. The reported policy has nine battle actions: four move slots and five switch slots.

The most useful result is negative. Fine-tuning on realistic latest-policy self-play made the model much better against itself but produced inconsistent gains against humans; replay inspection suggested that it learned to expect its own policy. More diverse synthetic teams and a mixture of imitation opponents transferred better. For `Battle`, this argues against latest-checkpoint mirror play as the only data source. Team diversity, historical opponents, exploiters, and fixed baselines should be part of the training distribution from the beginning.

Metamon is not a fidelity oracle for this repository. It targets Pokémon Showdown formats and learns from reconstructed spectator logs, while `Battle` preserves the hash-profiled Red mechanics and cartridge bugs.

### Earlier self-play and community engines

[Huang and Lee, 2019](https://ieee-cog.org/2019/papers/paper_175.pdf), *A Self-Play Policy Optimization Approach to Battling Pokémon*, demonstrates that large-scale Pokémon self-play is practical on modest infrastructure. Its ruleset and simulator differ from `Battle`, so it is precedent for workload shape rather than a mechanics reference.

[poke-env](https://poke-env.readthedocs.io/en/latest/examples/self_play.html) exposes Pokémon Showdown through PettingZoo's parallel multi-agent API. Its documented baseline shares one masked PPO policy between both players and contributes both perspectives to training. That is a useful compatibility baseline, but shared latest-policy PPO does not address cycling, opponent overfitting, sound hidden-information search, or cartridge fidelity.

[Foul Play](https://github.com/pmariglia/foul-play) and its `poke-engine` dependency are useful examples of domain-specific Pokémon search. They also show why search performance depends on a compact simulator. They are not clean-room sources for definitions, and their approximated Showdown mechanics are not a substitute for `Battle`.

## Search-guided self-play

### AlphaZero

[Silver et al., 2017](https://arxiv.org/abs/1712.01815) train a network

```text
(policy, value) = f(state)
```

from self-play. MCTS turns the network prior into an improved root policy; training minimizes policy cross-entropy against that search distribution and value error against the final game outcome. Illegal actions are masked. This is the right outer loop for a first search-guided `Battle` agent because the repository already owns an executable high-level transition model.

The direct algorithm assumes alternating actions and perfect information. Applying ordinary PUCT independently to each Pokémon player would instead learn against the searcher's current opponent model. It would not compute an equilibrium strategy for a simultaneous-choice node.

### Simultaneous-move MCTS

[Kovařík and Lisý, 2013](https://arxiv.org/abs/1310.8613) study MCTS in zero-sum perfect-information games with simultaneous moves. Their convergence result uses selection procedures that are Hannan-consistent in the local matrix game, with regret matching and Exp3 as examples. This is more directly applicable to a Pokémon turn than alternating-player UCT.

A normal battle decision should therefore be represented as a matrix over the two legal-action sets. Search samples or evaluates joint actions, while each player's improved target is a mixed strategy from the local matrix solver. A search that samples the opponent from a fixed policy is still useful as a best-response baseline, but it should not be described as equilibrium MCTS.

### Stochastic transitions

MCTS surveys treat stochastic dynamics as chance nodes, usually through expectimax, sparse sampling, or sampled outcomes. Pokémon has dense chance branching: move order ties, criticals, damage factors, accuracy, status effects, durations, and rejection loops can all consume randomness.

Enumerating raw random-byte branches is unnecessary and usually intractable. Search should sample complete semantic transitions from independent simulation entropy. The real episode's future RNG bytes must remain hidden. Cloning the actual battle RNG into every simulation would let search exploit a deterministic future that the policy is not allowed to observe.

### MuZero and Gumbel planning

[MuZero](https://arxiv.org/abs/1911.08265) learns only the reward, policy, and value quantities needed by tree search instead of receiving game rules. `Battle` already provides the transition function, so replacing it with a latent learned dynamics model would initially add model error and weaken auditability.

[Gumbel AlphaZero/MuZero](https://openreview.net/forum?id=bERaNdoegnO) is relevant later because it targets policy improvement with few simulations. [Sampled MuZero](https://arxiv.org/abs/2104.06303) addresses action spaces too large to enumerate. Ordinary link battles expose at most a small move/switch/special set, so sampled actions are not an early requirement. Low-simulation Gumbel policy improvement may become useful once neural inference, rather than mechanics, dominates actor cost.

## Imperfect information and game-theoretic self-play

### NFSP and PSRO

[Neural Fictitious Self-Play](https://arxiv.org/abs/1603.01121) was motivated by the failure of ordinary deep RL to approach equilibrium in imperfect-information games. It learns against an approximation of the historical average strategy rather than only the latest opponent.

[Policy-Space Response Oracles](https://arxiv.org/abs/1711.00832) generalize this idea: train approximate best responses to mixtures of existing policies, estimate a payoff matrix, and derive a meta-strategy over the population. This directly addresses Pokémon's non-transitive teams and policies. It also separates two questions that plain Elo conflates: whether a checkpoint beats the current champion and whether it is robust to the policy population.

[AlphaStar's league](https://www.nature.com/articles/s41586-019-1724-z) provides the large-scale precedent. Main agents, historical checkpoints, and exploiters prevent the system from repeatedly forgetting how to beat older strategies. A small `Battle` league can use the same roles without reproducing AlphaStar's infrastructure.

### ReBeL and Student of Games

[ReBeL](https://arxiv.org/abs/2007.13544) combines self-play learning and search in two-player zero-sum imperfect-information games using public belief states. [Student of Games](https://arxiv.org/abs/2112.03178) combines guided search, self-play, and game-theoretic reasoning across perfect- and imperfect-information games.

These works establish the direction for player-view Pokémon search, but they are not first milestones. A naive determinization search can leak hidden team information into action choices or produce strategy fusion: the resulting policy acts as though it can choose a different strategy for each hidden state. The first search system should use perfect-information mechanics while keeping future RNG hidden. Player-view search should be a separately named profile with an explicit belief model and leakage tests.

## APIs and evaluation tools

[PettingZoo's Parallel API](https://pettingzoo.farama.org/api/parallel/) is a reasonable Python compatibility surface because it steps all live agents at once and distinguishes per-agent observations from a centralized state. It is not rich enough to be the canonical semantics API: `Battle` also has forced single-player replacement requests, automatic continuations, nested Mimic/learning/evolution protocols, terminal witnesses, and divergence results.

[OpenSpiel](https://openspiel.readthedocs.io/en/latest/algorithms.html) includes MCTS, IS-MCTS, CFR variants, NFSP, PSRO, AlphaZero, best response, exploitability, and population evaluation. It is useful as an algorithmic oracle on small exported abstractions. Rewriting all of `Battle` into OpenSpiel would create a second simulator and should be avoided.

[Nagarajan et al., 2018](https://arxiv.org/abs/1809.05676) show that individual sources of deep-RL nondeterminism can materially affect reported performance. `Battle` already separates generator, battle, and policy entropy. Search entropy, replay sampling, model initialization, data-loader ordering, and evaluation pairing need the same treatment.

## Adopt, adapt, or defer

| Idea | Decision | Reason |
|---|---|---|
| Shared policy/value network | Adopt | Side-canonical encoding permits one zero-sum policy for both players. |
| Search policy and terminal value targets | Adopt | Uses exact mechanics and avoids reward shaping in the first objective. |
| Ordinary alternating-player PUCT | Replace | Pokémon normally chooses both actions simultaneously. |
| Regret-matching/Exp3 simultaneous MCTS | Adopt for the first serious search | Matches the local matrix-game structure. |
| Exact future episode RNG in search | Reject | It leaks hidden chance outcomes. |
| Learned MuZero dynamics | Defer | The verified high-level simulator already exists. |
| Gumbel policy improvement | Evaluate later | Promising when only a small simulation budget is affordable. |
| Latest-policy-only mirror self-play | Reject as the sole curriculum | It cycles and overfits to its own policy. |
| Historical league and exploiters | Adopt incrementally | Provides diversity and regression pressure. |
| Naive hidden-team determinization | Experimental only | It can leak information and produce strategy fusion. |
| ReBeL/Student-of-Games belief search | Long-term direction | More principled, but substantially more complex. |
| PettingZoo adapter | Optional | Useful ecosystem bridge, not the proof or replay boundary. |
| OpenSpiel reimplementation | Reject | It would duplicate mechanics; use it only for algorithm checks. |

## Research conclusion

The best first target is not "AlphaZero for Pokémon" without qualification. It is perfect-information, stochastic, simultaneous-move AlphaZero-style training over the theorem-backed high-level `Battle` model, with regret-based search, hidden future RNG, immutable replay records, and a historical opponent mixture. Hidden-team play, team construction, and belief-state search should follow only after that loop is reproducible and measurably stronger than fixed baselines.
