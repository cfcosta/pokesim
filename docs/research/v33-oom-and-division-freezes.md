# V33 evaluation OOM and division-freeze investigation

The September 8 run stopped at 03:41:39 America/Sao_Paulo during its first
promotion evaluation. The journal reports `oom-kill` and a 119 GiB training
cgroup peak. The desktop session stopped and the homelab VM was also OOM-killed
in the same incident. Training remains stopped; the original run is preserved at
`/media/pokemon-training/v33-bf16-20260908-021523/run`.

## The two search failures

Episodes 868 and 869 are opposite controller assignments on generated pair 434:
reset seed `9161383714335430984`, reset episode 434, two six-member parties.
Both were recorded as `search-semantic-divergence`. Before changing the engine,
we replayed every recorded action and verified both sides' state hashes at every
step: three decisions for episode 868 and 45 for episode 869. Instrumenting
native search exposed the underlying reason, `division-freeze`, two plies into
the hypothetical search tree. These failures were encountered while evaluating
possible actions; the recorded real battle had not executed the freezing branch.

Both witnesses involve Zapdos (Attack 163) and Mewtwo, whose base Defense 171
becomes 513 after two Barriers. Reflect doubles Defense to 1,026. The canonical
GetDamageVarsForPlayerAttack routine shifts both stats right twice and retains
only the low byte: Attack becomes 40 and Defense becomes `256 mod 256 = 0`.
The cartridge's divide routine does not terminate on that divisor. The existing
`DamageStats.resolve` models this deliberately; silently replacing zero with one
would change cartridge behavior.

There is also an engine ordering defect. Episode 868's witness attempts the
*first*, charging turn of Sky Attack. The cartridge's
CheckIfPlayerNeedsToChargeUp / CheckIfEnemyNeedsToChargeUp branches go directly
to JumpMoveEffect before critical-hit RNG, damage, accuracy, or PP decrement.
The engine previously calculated all of those before recognizing charge setup,
so it could freeze one turn too early and consume RNG that the cartridge does
not consume. Episode 869's witness is already releasing Sky Attack: the
zero-divisor arithmetic is legitimate at that stage.

The fix dispatches initial charge setup before the damage pipeline. It covers
Razor Wind, Fly, SolarBeam, Dig, Skull Bash and Sky Attack, including generated
moves. Retained `.noAction` releases still enter the damage path. A native
regression uses the recorded episode 868 prefix, proves charging preserves PP
and the RNG cursor, and proves a subsequent non-critical release still freezes.
The old episode 869 recording reflects the earlier RNG behavior and is retained
as forensic evidence, not a recording expected to match the corrected engine.

`Battle.Rom.ChargeDispatchRoutine` executes the canonical 15-byte dispatch
windows at bank $0f:$569a and $0f:$66fc for both sides and all 256 effect bytes in
the functional and physical SM83 cores. Its theorem connects those branches to
`Full.Engine.startsCharging`. It checks the real boundary opcode prefetch and
excludes writes, RNG accesses and calls inside the dispatch window. The shared
effect dispatcher/presentation is an explicit boundary; the existing
`ChargeRoutine` separately proves setup writes and continuation clearing.
The ROM fixture now checks these additional windows in the hash-verified ROM.
This is routine-boundary evidence, not a claim of whole-battle ROM bisimulation.

## Why RAM reached 119 GiB

Promotion used 12 spawned evaluation workers. The nominal 128-game ceiling and
2048-game schedule selected **86 simultaneous battles per worker**: 1,032 live
battles and 2,064 independent neural controller roots. Each worker owns its Python
search trees/inference caches, native Lean snapshot pool, model copies and
compiler processes. Search breadth and chance worlds multiply CPU-side state
storage. BF16 only reduces relevant neural tensors; it does not halve those
Lean states and Python objects.

The health log recorded training cgroup usage as follows:

| Local time | Stage | RAM |
|---|---|---:|
| 03:39:43 | Collection completed | 7.38 GiB |
| 03:40:13 | Promotion | 14.15 GiB |
| 03:40:43 | Promotion | 50.32 GiB |
| 03:41:13 | Promotion | 117.24 GiB |
| 03:41:39 | Kernel OOM termination | 119 GiB recorded peak |

A single original-size worker reproduced an 8.8 GiB peak during its first search.
That probe completed search but its reporting script then referenced a nonexistent
counter; its report and failure are retained separately from the clean comparison.
Twelve workers at that scale, plus the coordinator and other applications, exceed
this host's 124 GiB RAM. The launcher had only a disk-space guard and no cgroup
RAM limit. Defaulting to twelve workers without measuring aggregate RAM was an
operational error. The observed spike is explained by simultaneous evaluation
frontiers; these measurements do not establish the absence of every possible
long-duration leak.

The defaults now use four evaluation workers and at most sixteen battles per
worker in both fast and traced evaluation. All requested games and paired legs
are preserved. The maximum live evaluation population falls to 64 battles / 128
controller roots; neural inference batch size and search depth are unchanged.

A bounded comparison ran one search decision over the **same 86 games**, using
the initial checkpoint and corrected engine, once in an 86-game batch and once
in batches of at most 16. Each process had a 14 GiB cgroup hard limit and no swap.

| Batch size | Peak cgroup RAM | Total search time |
|---|---:|---:|
| 86 | 8.06 GiB | 42.43 s |
| 16 | 4.21 GiB | 51.38 s |

This reduces measured peak RAM by 47.8% at a 21.1% time cost in this single-worker
sample. Both runs performed exactly 176,402 native search transitions and selected
identical actions; maximum policy difference was 2.42e-6. Model loading/initialization
is included in peak RAM; search timing surrounds controller search calls. Compilation,
desktop and game activity affect timing. These are capacity measurements and a
numerical comparison, not proof of optimal throughput or a full-run RAM upper bound.
The trained candidate was lost in the OOM, so the initial checkpoint is a clearly
identified proxy for its model shape, not an exact replay of its learned weights.

The real four-process evaluation pool was also exercised with the corrected
engine, BF16, compiled inference and the production search shape. It processed
one decision for 64 games with zero semantic divergences, peaking at **11.94 GiB**
under a 32 GiB cgroup hard limit (36.2 seconds including startup/shutdown). This
validates aggregate startup capacity for the new defaults. It does not replace
long-run measurement or a RAM limit on a future training service.

## Recovery and evidence

Collection saved 2,048 episode records and 105,384 examples. It had 2,045 normal
finishes, one 512-decision truncation and the two search failures above. One training
epoch completed, but checkpoint publication follows evaluation, so no learned
checkpoint survived. The existing resume path archives an incomplete iteration
and recollects it. Moving durable learner checkpointing before evaluation remains
a separate recovery improvement; this investigation does not claim it is fixed.

A future run should collect fresh data under the corrected charging semantics
and run inside an explicit cgroup RAM limit. Reduced batch sizes are not a
substitute for that host-level guard. No training was restarted during this work.

[Investigation metadata](../../output/v33-incident-20260908/investigation.json),
[memory comparison](../../output/v33-incident-20260908/memory-comparison.json),
[memory timeline](../../output/v33-incident-20260908/memory-timeline.json), and the
raw replay/probe evidence in the same directory preserve measurement boundaries.
The original replay script targets the pre-fix source/binary; the native regression
test checks the corrected behavior.

Validation completed: 462 Python tests with zero skips; 279 Lean build targets;
10/10 model fixtures; the actual 1 MiB canonical ROM fixture including the new
charge-dispatch windows; Ruff and whitespace checks.
