#!/usr/bin/env python3
"""Reproduce learning-signal audit findings without changing training state.

The small examples isolate code behavior; they are not trained-model benchmarks.
Optional native sampling measures a frozen, zero-value heuristic controller.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import random
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace

import numpy as np
import torch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "packages" / "battle-training"))

from battle_training.cli import parser as training_parser
from battle_training.joint_search import (
    JointSearchConfig,
    SimultaneousTreeSearch,
    _tactical_potential,
)
from battle_training.native import SEARCH_SERVER, SearchServer
from battle_training.transformer_pipeline import (
    _heldout_diagnostics,
    _HeuristicNetwork,
    _load_partitioned_examples,
    _rows_to_examples,
)


class PerfectPolicy(torch.nn.Module):
    def __init__(self):
        super().__init__()
        self.anchor = torch.nn.Parameter(torch.zeros(()))
        self.config = SimpleNamespace(
            joint_policy_heads=True,
            distilled_leaf_policy=False,
            distilled_leaf_evaluator=False,
        )

    def forward_joint(self, features):
        logits = torch.tensor([[10.0, 0.0]]).repeat(len(features), 1)
        return logits, logits, torch.zeros(len(features))


def example(episode):
    return {
        "type": "example",
        "episode": episode,
        "pair": episode // 2,
        "features": [episode // 2],
        "policy": [1.0, 0.0],
        "opponent_policy": [1.0, 0.0],
        "value": 0.0,
        "legal_mask": 3,
        "opponent_legal_mask": 3,
    }


def isolated_checks():
    rows = [example(i) for i in range(20)]
    with tempfile.TemporaryDirectory(prefix="learning-signal-audit-") as temporary:
        path = Path(temporary) / "iteration-001.jsonl"
        path.write_text("".join(json.dumps(row) + "\n" for row in rows))
        training, heldout, _ = _load_partitioned_examples([path])
    train_pairs = set(training[0][:, 0].tolist())
    heldout_pairs = set(heldout[0][:, 0].tolist())
    metric = {}
    for weight in (1.0, 0.25):
        tensors = list(_rows_to_examples(rows))
        tensors[-1].fill_(weight)
        report = _heldout_diagnostics(
            PerfectPolicy(), tuple(tensors), [(1, i) for i in range(20)], 20
        )
        metric[str(weight)] = report["policy_top_action_agreement"]

    toy_network = SimpleNamespace(config=SimpleNamespace(action_count=2))
    search = SimultaneousTreeSearch(
        None,
        toy_network,
        toy_network,
        JointSearchConfig(chance_samples_per_joint=2, split_half_reliability=True),
        random.Random(1),
        random.Random(2),
    )
    node = search._make_node(
        SimpleNamespace(handle=0, player_mask=3, enemy_mask=1),
        ([0.5, 0.5], [1.0, 0.0], 0.0),
    )
    for half, payoffs in enumerate(((0.9, 0.1), (-0.5, 0.1))):
        for action, value in enumerate(payoffs):
            search._record_value(node, action, 0, value, half)
    mean_solve = search._solve_matrix(node, node.payoff)
    published = search._root_equilibrium(node)

    leaf_network = SimpleNamespace(
        config=SimpleNamespace(action_count=13),
        evaluate_leaf=lambda features: [0.8] * len(features),
    )
    snapshot = SimpleNamespace(
        player_features=np.zeros(492, dtype=np.int64),
        enemy_features=np.zeros(492, dtype=np.int64),
    )
    leaf_values = {}
    for label, opponent in (
        ("mirror", leaf_network),
        ("heuristic", _HeuristicNetwork("aggressive")),
    ):
        probe = SimultaneousTreeSearch(
            None,
            leaf_network,
            opponent,
            JointSearchConfig(),
            random.Random(1),
            random.Random(2),
        )
        values, _, _ = SimultaneousTreeSearch._pooled_leaf_values(
            [(0, probe, [snapshot])]
        )
        leaf_values[label] = values[0][0]

    nonterminal = SimpleNamespace(done=False)
    better = search._shaped_leaf_value(0.0, nonterminal, 0.6, -0.2)
    worse = search._shaped_leaf_value(0.0, nonterminal, 0.4, 0.2)
    args = training_parser().parse_args(["transformer-train", "--output", "unused"])
    return {
        "scope": "synthetic inputs through current production functions",
        "heldout_pair_leakage": {
            "training_rows": len(training[0]),
            "heldout_rows": len(heldout[0]),
            "heldout_pair_ids": sorted(heldout_pairs),
            "heldout_pairs_also_in_training": sorted(train_pairs & heldout_pairs),
        },
        "perfect_policy_reported_agreement_by_row_weight": metric,
        "same_candidate_leaf_value_by_opponent_kind": leaf_values,
        "shaping_rank_reversal": {
            "better_action_true_value": 0.6,
            "better_action_potential_delta": -0.2,
            "better_action_search_score": better,
            "worse_action_true_value": 0.4,
            "worse_action_potential_delta": 0.2,
            "worse_action_search_score": worse,
        },
        "split_half_changes_mean_matrix_solution": {
            "chance_world_payoffs": [[0.9, 0.1], [-0.5, 0.1]],
            "mean_payoffs": [0.2, 0.1],
            "anchor_temperature": 0.02,
            "mean_matrix_player_policy": mean_solve[0],
            "published_player_policy": published[0],
            "mean_matrix_value": mean_solve[2],
            "published_value": published[2],
            "published_exploitability": published[3],
        },
        "current_cli_defaults": {
            key: getattr(args, key)
            for key in (
                "search_depth",
                "chance_samples_per_joint",
                "interior_chance_samples",
                "interior_actions_per_side",
                "split_half_reliability",
                "policy_reliability_floor",
                "shadow_opponent_window",
                "collection_epsilon",
                "collection_dirichlet_alpha",
                "collection_dirichlet_total",
                "promotion_policy_games",
            )
        },
    }


def native_sampling(roots):
    network = _HeuristicNetwork("aggressive")
    records = []
    with SearchServer(popular_gate=64) as server:
        for episode in range(roots):
            snapshot = server.reset(
                20260908, episode, 6, 6, level100=True, balanced_final_species=True
            )
            root_potential = _tactical_potential(snapshot.player_features)

            def solve(samples, chance_seed, state=snapshot):
                search = SimultaneousTreeSearch(
                    server,
                    network,
                    network,
                    JointSearchConfig(
                        max_depth=1,
                        chance_samples_per_joint=samples,
                        split_half_reliability=True,
                        redundant_action_prior_scale=0.25,
                    ),
                    random.Random(123),
                    random.Random(chance_seed),
                )
                return search.search(state, sample_actions=False)

            reference = solve(64, 900000 + episode)
            if reference.failure:
                records.append({"episode": episode, "failure": reference.failure})
                continue
            matrix = np.asarray(reference.payoff_matrix)
            opponent = np.asarray(reference.enemy_policy)
            action_values = matrix @ opponent
            legal = [a for a in range(13) if snapshot.player_mask & (1 << a)]
            trials = []
            for repeat in range(4):
                result = solve(2, 10000 * episode + repeat)
                if result.failure:
                    trials.append({"failure": result.failure})
                    continue
                policy = np.asarray(result.player_policy)
                diagnostics = result.diagnostics or {}
                trials.append(
                    {
                        "argmax": int(policy.argmax()),
                        "tv_vs_reference": float(
                            0.5 * np.abs(policy - reference.player_policy).sum()
                        ),
                        "reference_matrix_best_response_gap": float(
                            max(action_values[legal]) - policy @ action_values
                        ),
                        "split_half_distance": diagnostics.get(
                            "root_split_half_distance"
                        ),
                    }
                )
            records.append(
                {
                    "episode": episode,
                    "root_potential": root_potential,
                    "reference_argmax": int(np.argmax(reference.player_policy)),
                    "reference_own_best_response_gap": float(
                        max(action_values[legal])
                        - np.asarray(reference.player_policy) @ action_values
                    ),
                    "trials": trials,
                }
            )
            print(f"native root {episode + 1}/{roots}", file=sys.stderr, flush=True)
    trials = [t for r in records for t in r.get("trials", []) if "failure" not in t]
    return {
        "scope": "level-100 6v6 initial roots; frozen aggressive priors, zero leaf value; depth 1; Python reference anchored solver; 64-world estimate is not ground truth",
        "roots": records,
        "aggregate": {
            "trials": len(trials),
            "argmax_disagreements": sum(
                t["argmax"] != r["reference_argmax"]
                for r in records
                for t in r.get("trials", [])
                if "failure" not in t
            ),
            **(
                {
                    key: float(np.mean([t[key] for t in trials]))
                    for key in (
                        "tv_vs_reference",
                        "reference_matrix_best_response_gap",
                        "split_half_distance",
                    )
                }
                if trials
                else {}
            ),
        },
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--native-roots", type=int, default=0)
    args = parser.parse_args()
    torch.set_num_threads(1)
    report = isolated_checks()
    sources = [
        ROOT / "packages/battle-training/battle_training" / name
        for name in (
            "transformer_pipeline.py",
            "joint_search.py",
            "network.py",
            "cli.py",
        )
    ]
    if args.native_roots:
        sources.append(SEARCH_SERVER)
    report["source_sha256"] = {
        str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sources
    }
    if args.native_roots:
        report["native_sampling"] = native_sampling(args.native_roots)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
