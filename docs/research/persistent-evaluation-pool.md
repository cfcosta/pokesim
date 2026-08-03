# Persistent evaluation pool and GPU throughput

## Scope

V27 changes evaluation orchestration only. Promotion, held-out probes, and the
campaign suite now share one spawned process pool for an iteration. Each worker
loads the candidate and incumbent once, retains compiled inference graphs across
all three stages, and then exits before the next self-play collection. Search
semantics remain complete-root simultaneous matrix-tree CFR+ with exact Lean
transitions.

The evaluation topology is identified as:

```text
persistent-process-pool-full-utilization-v1
transformer-variable-party-bf16-rmplus-v27-persistent-eval
```

V27 is an incompatible run lineage. Changing process count and cross-root batch
composition can change floating-point reduction order, deeper traversal, and
therefore paired outcomes even though every pair retains its seed and complete
side swap.

## Why evaluation looked serial

V26 did use `ProcessPoolExecutor`, but every gate created a new pool and loaded
and compiled both models again. The 2,048-game promotion used all eight configured
workers. The 256-game traced probe had only four 64-game spans, while the
288-game campaign had only three 128-game spans. Their remaining workers had no
work, and the monitor exposed only stage transitions rather than completed game
counts.

V27 chooses an even, pair-preserving batch size that creates balanced waves for
all configured workers without exceeding the previous 128-game fast-arena or
64-game traced-arena ceilings. Completion of each worker partition updates the
transient monitor. The pool remains resident across promotion, probes, and
campaign, eliminating two process/model/compile startups.

## GPU/process benchmark

The benchmark used checkpoint `policy-003.pt`, compiled BF16 inference, exact
Lean transitions, depth four, budget 320, and 1,568 evaluation games: 1,024
promotion, 256 probe, and 288 campaign games. It measured the complete three-stage
suite, excluding promotion timeline serialization.

| Topology | Processes | Wall seconds | Mean GPU | Peak VRAM MiB | Speedup |
|---|---:|---:|---:|---:|---:|
| Separate pools | 8 | 352.40 | 47.6% | 7,571 | 1.00× |
| Persistent pool | 8 | 331.43 | 50.7% | 7,403 | 1.06× |
| Persistent pool | 10 | 279.92 | 63.0% | 8,305 | 1.26× |
| Persistent pool | 12 | **277.89** | 69.2% | 9,167 | **1.27×** |
| Persistent pool | 14 | 293.02 | 70.2% | 9,803 | 1.20× |

Twelve processes were fastest. Fourteen consumed another 636 MiB and raised GPU
utilization by one point but reduced decisions per second by 5.2% relative to
twelve. Production therefore defaults to twelve evaluation processes. VRAM
utilization is a constraint and diagnostic, not the objective; the selected
configuration leaves roughly 3 GiB for the parent model, optimizer residue,
CUDA libraries, and workload variance.

Persistent eight-process evaluation reproduced the separate-pool finished counts
and scores exactly. Higher process counts deliberately change batch topology and
must pass the normal same-reset, side-swapped quality gates; lower matrix
exploitability or higher GPU occupancy is not a playing-strength result.

Raw benchmark reports:

```text
/tmp/eval-separate-8.json
/tmp/eval-persistent-8.json
/tmp/eval-persistent-10.json
/tmp/eval-persistent-12.json
/tmp/eval-persistent-14.json
```
