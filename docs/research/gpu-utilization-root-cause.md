# Training-search GPU utilization root cause

Date: 2026-08-01

## Question

Why does the RTX 3080 Ti report roughly 14–25% utilization during production
self-play evaluation even though the process has ample device memory?

This investigation paused the active frozen V22 service with `SIGSTOP`, ran
controlled profiles against its immutable checkpoint and source, then resumed
it. No training state or entropy stream advanced during the profile. The second
pause exceeded the native request wall-clock timeout; completed iterations 1–2
remained atomic, while incomplete iteration 3 was restarted from its beginning.
That event also exposed a non-pickleable `NativeRequestTimeout`; V24 gives the
exception an explicit reduction so actor-process timeouts preserve their real
cause instead of surfacing as `BrokenProcessPool`.

## Live evidence

During iteration-2 probes and campaign evaluation:

```text
GPU SM utilization       typically 19–34%
GPU memory               about 4.0 / 12.3 GiB
memory-controller use    typically 1–5%
power                    about 131–140 / 350 W
```

The workload was search-based evaluation, not the short 456-minibatch optimizer
epoch. Iteration-2 collection took about 33 minutes; its 2,048-game promotion
arena then took about 65 minutes before probes and campaigns. Search evaluation,
not optimizer throughput, was the dominant wall-time target.

## Primary defect: expanded-node inference escaped the frontier scheduler

Distilled successor evaluation correctly entered `_InferenceFrontier` and was
pooled across roots. When a successor was later promoted into an expanded tree
node, however, `_simulate_frontier()` called `_make_node(successor)` directly.
The missing full policy/value evaluation then executed synchronously through
`_evaluate_many([successor])`.

Consequences:

1. Each expanded child issued one full transformer request immediately instead
   of waiting for other roots.
2. Mirror search evaluated two canonical rows in a batch of exactly two,
   bypassing V20's joint dual-policy physical-state evaluator.
3. Candidate/incumbent evaluation issued two separate batch-one requests.
4. Native work and Python RM+ coordination created gaps between those very
   short kernels, starving the GPU despite thousands of total rows.

At 64 simultaneous roots, the frozen V22 topology measured:

| Controller topology | Full child calls | Mean full batch | Full-child time |
|---|---:|---:|---:|
| Mirror/self-play | 1,727 | 2.00 | 1.254 s |
| Distinct candidate/incumbent | 3,456 | 1.04 | 3.019 s |

This was the root cause of the low-utilization inference pattern.

## Fix

V24 adds a separate `_NodeInferenceFrontier`. A child cannot be constructed
without a pooled full evaluation. The cross-root scheduler holds these
frontiers until the other roots reach the same barrier, then calls the existing
network-identity pooling code. Mirror roots use `evaluate_joint`; distinct
models each receive their own batched canonical rows. A synchronous missing
node evaluation now raises rather than silently reintroducing batch-one work.

New diagnostics record full-node inference calls, rows, waves, and mean batch.

## Controlled benchmark

Both profiles used production depth 4, budget 320, compiled inference, exact
Lean transitions, 64 roots, and the same V22 checkpoint on the RTX 3080 Ti.
V24 also includes the already-committed fresh-root/chance-quality semantics, so
paired strength gates remain required; the call-count diagnosis itself is
directly attributable to the new frontier.

| Mode | Frozen V22 | V24 pooled node | Throughput gain |
|---|---:|---:|---:|
| Mirror milliseconds/root | 82.76 | 46.43 | 1.78× |
| Mirror roots/second | 12.08 | 21.54 | 1.78× |
| Distinct milliseconds/root | 124.33 | 61.14 | 2.03× |
| Distinct roots/second | 8.04 | 16.35 | 2.03× |

After the fix:

| Controller topology | Full calls | Mean full batch | Full time |
|---|---:|---:|---:|
| Mirror/self-play | 50 joint | 28.16 | 0.059 s |
| Distinct candidate/incumbent | 100 canonical | 28.16 | 0.099 s |

There were no fallback batch-one/two canonical calls. The mirror path reduced
full-node inference time 21.4×; the distinct path reduced it 30.6×.

Raw profiles:

```text
/tmp/v22-rootcause-profile-v2.json
/tmp/v24-rootcause-profile.json
```

## Why GPU utilization falls after the fix

The corrected 64-root profiles report only 9.8% mirror and 4.3% distinct GPU
utilization while completing 1.8–2.0× faster. Utilization fell because the
system stopped launching thousands of redundant tiny full-model kernels. GPU
percentage is therefore not the optimization objective.

The corrected distinct profile attributes wall time approximately as follows:

```text
Python RM+/frontier coordination     52.6%
exact native mechanics               35.7%
neural inference                     11.7%
```

A standalone uninterrupted batch-256 joint model reaches only 56–61% SM use at
about 139,000 rows/s. The distilled leaf model is smaller still. A 937,949-
parameter, 32-token transformer does not contain enough arithmetic per launch
to sustain 80% on this GPU with one stream.

Increasing the root cohort from 64 to 128 did not help: corrected mirror
throughput fell from 21.54 to 18.12 roots/s. Increasing self-play battles would
only repeat the same pipeline longer.

## Remaining throughput work

The next limiting resources are now explicit:

1. Reduce Python RM+ and generator-scheduler coordination without changing the
   simultaneous equilibrium. V26 subsequently moved dense solver arithmetic to
   Rust and enabled CFR+; see the [native solver review](rust-rmplus-cfrplus.md).
2. Improve native mechanics throughput and overlap across independent cohorts.
3. Only then test multiple deterministic 64-root lanes feeding one GPU. Select
   by games/second and decision quality, not by utilization percentage.

Artificially adding model work or oversized optimizer batches could raise GPU
utilization while making the lineage slower or weaker. Production acceptance
continues to require exact action coverage, deterministic replay, divergence
failure, paired arenas, probes, strata, and campaigns.
