#!/usr/bin/env python3
"""Audit self-play reset and controller entropy coordinates for collisions."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(
    0, str(Path(__file__).resolve().parents[1] / "packages/battle-training")
)

from battle_training.transformer_pipeline import (
    _ACTOR_ENTROPY_VERSION,
    _CHANCE_DOMAIN,
    _EXPLORATION_DOMAIN,
    _OPPONENT_DOMAIN,
    _PRIOR_NOISE_DOMAIN,
    _RESET_DOMAIN,
    _SELECTION_DOMAIN,
    _TIER_DOMAIN,
    _splitmix64,
    _training_entropy_seed,
)

_UINT64_MASK = (1 << 64) - 1
_LINK_STREAM_OFFSET = 0x632BE59BD9B4E019

_DOMAINS = {
    "selection": _SELECTION_DOMAIN,
    "chance": _CHANCE_DOMAIN,
    "opponent": _OPPONENT_DOMAIN,
    "tier": _TIER_DOMAIN,
    "exploration": _EXPLORATION_DOMAIN,
    "prior_noise": _PRIOR_NOISE_DOMAIN,
}


def _link_rng_block(root: int, episode: int, stream: int) -> bytes:
    accepted = []
    for counter in range(512):
        word = _splitmix64(
            root
            ^ _splitmix64(episode)
            ^ _splitmix64((stream + _LINK_STREAM_OFFSET) & _UINT64_MASK)
            ^ _splitmix64(counter)
        )
        candidate = word & 0xFF
        if candidate < 0xFD:
            accepted.append(candidate)
            if len(accepted) == 10:
                return bytes(accepted)
    return bytes((accepted + [0] * 10)[:10])


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--seed", type=int, default=20260726)
    parser.add_argument("--iterations", type=int, default=30)
    parser.add_argument("--episodes", type=int, default=16384)
    parser.add_argument("--output", type=Path)
    return parser.parse_args()


def main() -> int:
    arguments = parse_args()
    if arguments.iterations < 1 or arguments.episodes < 2 or arguments.episodes % 2:
        raise ValueError(
            "iterations must be positive and episodes must be positive and even"
        )

    reset_roots = {
        _training_entropy_seed(arguments.seed, iteration, 0, _RESET_DOMAIN)
        for iteration in range(1, arguments.iterations + 1)
    }
    pairs = arguments.episodes // 2
    expected_resets = arguments.iterations * pairs

    global_seeds: dict[int, str] = {}
    streams: dict[str, dict[str, int]] = {}
    cross_domain_collisions = 0
    for name, domain in _DOMAINS.items():
        seeds = {
            _training_entropy_seed(arguments.seed, iteration, episode, domain)
            for iteration in range(1, arguments.iterations + 1)
            for episode in range(arguments.episodes)
        }
        expected = arguments.iterations * arguments.episodes
        streams[name] = {
            "coordinates": expected,
            "unique_seeds": len(seeds),
            "collisions": expected - len(seeds),
        }
        for seed in seeds:
            if seed in global_seeds:
                cross_domain_collisions += 1
            else:
                global_seeds[seed] = name

    link_blocks: dict[str, dict[str, int]] = {}
    all_link_blocks: set[bytes] = set()
    cross_link_collisions = 0
    for name, stream in (("generator", 1), ("battle", 2)):
        blocks = {
            _link_rng_block(root, pair, stream)
            for root in reset_roots
            for pair in range(pairs)
        }
        link_blocks[name] = {
            "coordinates": expected_resets,
            "unique_blocks": len(blocks),
            "collisions": expected_resets - len(blocks),
        }
        cross_link_collisions += len(all_link_blocks & blocks)
        all_link_blocks.update(blocks)

    report = {
        "version": _ACTOR_ENTROPY_VERSION,
        "root_seed": arguments.seed,
        "iterations": arguments.iterations,
        "episodes_per_iteration": arguments.episodes,
        "pairs_per_iteration": pairs,
        "pair_legs_share_reset": True,
        "reset_coordinates": expected_resets,
        "unique_reset_roots": len(reset_roots),
        "reset_root_collisions": arguments.iterations - len(reset_roots),
        "link_rng_streams": link_blocks,
        "cross_link_stream_collisions": cross_link_collisions,
        "controller_streams": streams,
        "cross_domain_seed_collisions": cross_domain_collisions,
    }
    payload = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if arguments.output is not None:
        arguments.output.write_text(payload)
    print(payload, end="")

    failures = (
        report["reset_root_collisions"]
        + cross_domain_collisions
        + cross_link_collisions
    )
    failures += sum(stream["collisions"] for stream in streams.values())
    failures += sum(stream["collisions"] for stream in link_blocks.values())
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
