# Full-party training precision benchmark

## Decision

The production transformer now uses BF16 autocast for encoder and head compute.
Parameters, gradients, AdamW state, logits returned to search, policy
normalization, losses, and reductions remain FP32. `--precision fp32` is retained
for differential checks, and checkpoints written before precision was explicit
continue to load as FP32.

## RTX 3080 Ti result

The benchmark used the 938,638-parameter, four-layer, 128-wide model, the
478-field input, batch size 128, deterministic PyTorch algorithms, ten warmup
steps, and three interleaved 40-step repetitions. The raw run is reproducible
with:

```sh
nix develop -c python tools/benchmark-full6v6-precision.py \
  --output /tmp/full6v6-precision.json
```

| Compute | Training examples/s | Peak allocation | Relative training throughput |
|---|---:|---:|---:|
| FP32 | 876 | 2.24 GiB | 1.00x |
| BF16 autocast | 3,304 | 1.26 GiB | 3.77x |

Inference speed depended on batch size:

| Inference batch | BF16 / FP32 throughput |
|---:|---:|
| 1 | 0.53x |
| 8 | 2.07x |
| 32 | 3.10x |
| 96 | 3.36x |
| 128 | 3.55x |

The singleton regression does not outweigh the batched gain. A matched
16-episode actor workload at the zero-head initialization, with FP32 outputs
used for policy normalization, produced byte-identical shards and took 9.82
seconds in FP32 versus 7.29 seconds in BF16, a 1.35x end-to-end speedup. This
establishes equal-work timing, not general output equivalence after learning.

A 20-epoch fit of one real 898-example shard remained finite in both modes. BF16
took 6.08 seconds versus 21.26 seconds. Strict-FP32 evaluation of the resulting
master weights gave total losses of 1.3536 and 1.3611 for the BF16-trained and
FP32-trained models respectively. This small fit checks numerical stability; it
is not evidence of equal gameplay strength.

On a fixed nonzero model and 32 probe states, BF16 had maximum absolute logit
and value differences of 0.0129 and 0.0044, mean policy KL of `6.3e-6`, and no
argmax disagreements. These differences can still alter sampled trajectories.
Promotion therefore continues to require the full paired 1,024-game confidence
gate and held-out probes.

Batch 512 succeeded under BF16 with a 4.76 GiB peak allocation, but improved
training throughput by only 10.5% over BF16 batch 128. Batch 128 remains the
production default for memory headroom and concurrent actor inference.
