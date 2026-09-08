# battle-training

Search-assisted training and inference for the Lean full-party battle simulator.
Lean owns immutable battle states, legal actions, chance forks, and mechanics.
Python owns the BF16 transformer, independent controllers, replay, and training.
Rust and fused Triton CUDA kernels solve the simultaneous action matrices.

The current lineage is `transformer-variable-party-v33-independent-win-search`.
See the [controller design](../../docs/explanation/search-assisted-controller.md)
and [validation report](../../docs/research/v33-search-validation.md). The
[learning-signal investigation](../../docs/research/learning-signal-investigation.md)
records the implementation replaced by this lineage.

## Train and verify

From the repository root:

```sh
nix develop -c python packages/battle-training/train.py transformer-smoke \
  --output artifacts/training/v33-smoke --device cuda --precision bf16 \
  --inference-engine eager

nix develop -c python packages/battle-training/train.py verify \
  artifacts/training/v33-smoke
```

The smoke profile exercises collection, optimization, evaluation, checkpointing,
manifests, and byte-identical replay of its first collection shard. Its small
model and four battles cannot establish playing strength. Its 256-decision
horizon lets both original reset pairs finish without splitting a pair across
training and held-out diagnostics. Use a new output directory for each run.

Production keeps BF16 neural arithmetic, FP32 parameters and optimizer state,
and FP32 losses and reductions:

```sh
nix develop -c python packages/battle-training/train.py transformer-train \
  --output artifacts/training/v33-run-001 --device cuda --precision bf16

nix develop -c python packages/battle-training/train.py transformer-resume \
  --output artifacts/training/v33-run-001
```

Production defaults are 30 iterations, 16,384 battles per iteration, a 256-wide
six-layer transformer, search depth two, four chance worlds per legal root pair,
three actions per side at interior nodes, and two interior chance worlds. Every
neural decision uses search. Full transformer evaluation is the default;
`--leaf-evaluator distilled` is an explicit approximation to evaluate separately.

Evaluation defaults to four workers and at most sixteen simultaneous battles
per worker. Search frontiers live in CPU RAM as well as GPU tensors; increasing
worker count or battle batch width multiplies that memory. Use a cgroup RAM
limit when launching long runs. The [OOM investigation](../../docs/research/v33-oom-and-division-freezes.md)
records the measured limits and the cartridge-backed charging fix.

`--solver-backend auto --solver-precision fp32` batches compatible games on CUDA
when measurements justify the transfer and launch cost, and uses Rust FP64
otherwise. `--solver-backend rust` selects the reference path.
`--solver-backend cuda` explicitly requires CUDA support;
`--solver-precision fp64` selects the more expensive CUDA numerical reference.
Solver precision is separate from neural BF16 precision.

Compiled inference has substantial startup cost. Live serving must warm all
relevant shapes before accepting timed turns. `--inference-engine eager`
avoids compilation startup. Training uses fixed search work, including during
compilation, so machine speed cannot change its target generation.

Older lineages cannot resume into v33: their targets and promotion decisions
used different controller semantics. Checkpoints remain inspectable with
explicit state selection.

## Play with a three-second budget

```python
from battle_training.decision import decide_battle
from battle_training.network import load_network

network = load_network(checkpoint_path, device, state="deployed")
network.configure_inference("eager")
decision = decide_battle(
    server, network, snapshot,
    side="player", budget_seconds=3.0, seed=turn_seed,
)
action = decision.action
```

The server and snapshot use the existing native protocol. Each decision first
completes a shallow matrix covering every legal root action. Further complete
searches are admitted when measured cost predicts they will fit. The controller
samples once from the last valid mixed strategy. Enemy decisions use the
enemy's canonical observation and value convention.

Three seconds is the admission target, not a hard preemption guarantee:
in-flight native batches or CUDA operations can overrun. Results report elapsed
time, overruns, completed and failed passes, selected depth, and chance samples.
Server startup and checkpoint loading are outside this timing boundary.
`warm_decision_network(network, snapshot, search_config=config)` prepares compiled inference
before timing; see its API documentation for setup telemetry.

A native timeout raises `DecisionSearchError`. Recreate the server and restore
the battle before another native request. Training and arena gates use fixed
search work; timed serving uses the same evaluator and solver with adaptive
completed passes.

## Inspect what actually learned

Checkpoints distinguish the deployed incumbent (`model`) from the continuing
learner (`learner_model`). Rejected promotion can leave deployment unchanged
while the learner updates. Select the intended state explicitly:

```sh
nix develop -c python packages/battle-training/train.py arena \
  --candidate artifacts/training/v33-run-001/checkpoints/policy-001.pt \
  --candidate-state learner \
  --baseline artifacts/training/v33-run-001/checkpoints/policy-000.pt \
  --baseline-state deployed \
  --output artifacts/training/v33-learner-arena \
  --games 256 --device cuda --inference-engine eager
```

Reports record checkpoint paths, hashes, selected states, and neural precision.
`--policy-only` is a diagnostic ablation. Production promotion requires the
current candidate's search-assisted paired confidence bound to exceed 0.5,
plus the applicable quality and probe gates. Raw-policy wins, pooled older
candidates, and bootstrap waivers cannot replace that evidence.

Held-out diagnostics preserve both side-swapped legs and all replay descendants
of an originating reset. Policy agreement handles both heads and fractional
example weights. A read-only monitor follows a run:

```sh
nix develop -c python packages/battle-training/train.py monitor \
  --run artifacts/training/v33-run-001 --open
```

## Reproduce checks

```sh
nix develop -c python -m unittest discover -s packages/battle-training/tests
nix develop -c python tools/benchmark-cuda-solver.py --help
nix develop -c python tools/benchmark-battle-decision.py \
  --device cuda --precision bf16 --engine eager --budget-seconds 3 \
  --output output/local-battle-decision.json
```

CUDA tests compare against Rust and analytical games with sparse masks, extreme
priors, and long iteration counts. Benchmarks distinguish complete host-to-host
solving from kernel-only time. The validation report records hardware, inputs,
numerical tolerances, and full decision measurements.

## Boundaries

The profile is `full-link-party-1to6-perfect-v2`: one-to-six-member parties,
known declared policy state, and hidden future randomness. The 13-action
dictionary includes four moves, six switches, typed no-action, Struggle, and
the profile-disabled run slot. Lean normalizes replacement and Mimic requests.

Search samples fresh chance independently of the episode's hidden RNG. It
solves complete legal root matrices and restricted interior matrices with
learned continuation values. This finite-horizon simultaneous search does not
establish an exact equilibrium of a complete battle.

Only finished episodes receive terminal value labels. Semantic divergence,
horizon truncation, and mechanics timeouts remain distinguishable failures.
Failed searches do not produce fabricated policy or terminal-value targets.

The synchronized full-party model does not establish paired-cartridge
equivalence or complete browser deployment. See [CHECKLIST.md](CHECKLIST.md),
[web exhibition](../../docs/explanation/web-random-6v6-exhibition.md), and
[campaign integration](../../docs/explanation/campaign-trainer-link-ai.md).
