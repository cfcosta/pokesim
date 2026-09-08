import json
import random
import sys
from pathlib import Path

sys.path.insert(0, "/home/cfcosta/Code/_tmp/pokemon/gpt/packages/battle-training")
import torch
from battle_training.controller import search_controllers_many
from battle_training.native import SearchServer
from battle_training.network import load_network
from battle_training.transformer_pipeline import (
    TransformerPipelineConfig,
    _HeuristicNetwork,
    _new_search,
)

BASE = Path(__file__).resolve().parent
OUT = BASE / "reproduction"
OUT.mkdir(exist_ok=True)
RUN = Path("/media/pokemon-training/v33-bf16-20260908-021523/run")
config = TransformerPipelineConfig(
    **json.loads((RUN / "run.json").read_text())["config"]
)
torch.set_num_threads(1)
network = load_network(RUN / "checkpoints/policy-000.pt", torch.device("cuda"))
network.configure_inference("eager")


class Found(Exception):
    pass


class Probe(SearchServer):
    def search_steps(self, requests):
        requests = list(requests)
        out = super().search_steps(requests)
        for req, snap in zip(requests, out):
            self.parents[snap.handle] = req
        for req, snap in zip(requests, out):
            if snap.divergence:
                chain = []
                h = snap.handle
                while h in self.parents:
                    parent, p, e, seed = self.parents[h]
                    chain.append(
                        {
                            "parent": parent,
                            "player_action": p,
                            "enemy_action": e,
                            "chance_seed": seed,
                        }
                    )
                    h = parent
                report = {
                    "episode": self.episode,
                    "divergence": snap.divergence,
                    "chain": list(reversed(chain)),
                    "before": self.inspect(req[0]),
                    "after": self.inspect(snap.handle),
                }
                (OUT / f"failure-{self.episode}.json").write_text(
                    json.dumps(report, indent=2) + "\n"
                )
                print(
                    json.dumps(
                        {
                            "episode": self.episode,
                            "divergence": snap.divergence,
                            "chain": report["chain"],
                        }
                    ),
                    flush=True,
                )
                raise Found
        return out


for episode in [868, 869]:
    rec = json.loads((BASE / f"episode-{episode}.json").read_text())
    with Probe(popular_gate=64) as server:
        server.parents = {}
        server.episode = episode
        root = server.reset(
            rec["reset_seed"],
            rec["reset_episode"],
            6,
            6,
            level100=False,
            balanced_final_species=True,
        )
        for t in rec["timeline"]:
            assert root.player_hash == t["player_state_hash"], (
                episode,
                t["turn"],
                "player hash",
            )
            assert root.enemy_hash == t["enemy_state_hash"], (
                episode,
                t["turn"],
                "enemy hash",
            )
            root = server.episode_steps(
                [(root.handle, t["player_action"], t["enemy_action"])]
            )[0]
        print(
            "Replayed exact hashes",
            episode,
            "decisions",
            len(rec["timeline"]),
            "root",
            root.handle,
            flush=True,
        )
        (OUT / f"root-{episode}.json").write_text(
            json.dumps(server.inspect(root.handle), indent=2) + "\n"
        )
        heuristic = _HeuristicNetwork("red-trainer-46-agatha")
        player, enemy = (
            (network, heuristic)
            if rec["candidate_side"] == "player"
            else (heuristic, network)
        )
        for seed in range(8):
            try:
                search = _new_search(
                    server,
                    player,
                    enemy,
                    config,
                    random.Random(seed),
                    random.Random(seed),
                )
                result = search_controllers_many([search], [root], sample_actions=True)
                print("search clean", episode, seed, flush=True)
            except Found:
                break
            root = server.compact_many([root])[0]
            server.parents = {}
