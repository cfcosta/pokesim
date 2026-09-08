"""Independent simultaneous controllers sharing batched mechanics and inference."""

from __future__ import annotations

import random
from dataclasses import dataclass, replace
from typing import Any

from .joint_search import SearchResult, SimultaneousTreeSearch, legal_actions
from .native import Snapshot


@dataclass(frozen=True)
class ControllerDecision:
    """Each controller's private solve, in physical player/enemy coordinates.

    The two strategies need not be an equilibrium of any shared payoff matrix.
    Training must take both policy targets and diagnostics from the learner's
    own solve. Only the executed actions are assembled across controllers.
    """

    player: SearchResult
    enemy: SearchResult

    @property
    def failure(self) -> str | None:
        return self.player.failure or self.enemy.failure

    def executed(self) -> SearchResult:
        diagnostics: dict[str, float | int | str] = {}
        for side, result in (("player", self.player), ("enemy", self.enemy)):
            diagnostics[f"{side}_solver"] = result.solver
            if result.payoff_matrix is not None:
                diagnostics[f"{side}_root_value"] = result.root_value
                if result.exploitability is not None:
                    diagnostics[f"{side}_exploitability"] = result.exploitability
            for key, value in (result.diagnostics or {}).items():
                diagnostics[f"{side}_{key}"] = value
        return SearchResult(
            player_policy=self.player.player_policy,
            enemy_policy=self.enemy.enemy_policy,
            player_action=self.player.player_action,
            enemy_action=self.enemy.enemy_action,
            root_value=0.0,
            nodes=self.player.nodes + self.enemy.nodes,
            solver="independent-simultaneous-controllers-v1",
            exploitability=None,
            payoff_spread=None,
            payoff_matrix=None,
            diagnostics=diagnostics,
            failure=self.failure,
        )


def _choose(
    policy: tuple[float, ...], mask: int, rng: random.Random, sample: bool
) -> int:
    legal = legal_actions(mask, len(policy))
    if not legal:
        raise ValueError("controller requires a legal action")
    if not sample:
        return max(legal, key=lambda action: (policy[action], -action))
    total = sum(policy[action] for action in legal)
    if total <= 0.0:
        raise ValueError("controller policy has no legal probability mass")
    threshold = rng.random() * total
    cumulative = 0.0
    for action in legal:
        cumulative += policy[action]
        if threshold < cumulative:
            return action
    return legal[-1]


def _direct_policy(network: Any, snapshot: Snapshot, side: str) -> SearchResult:
    policies, _ = network.evaluate(
        [getattr(snapshot, f"{side}_features")],
        [getattr(snapshot, f"{side}_mask")],
    )
    policy = tuple(policies[0])
    unused = tuple(0.0 for _ in policy)
    return SearchResult(
        player_policy=policy if side == "player" else unused,
        enemy_policy=policy if side == "enemy" else unused,
        player_action=None,
        enemy_action=None,
        root_value=0.0,
        nodes=0,
        solver="direct-controller-policy-v1",
        exploitability=None,
        payoff_spread=None,
        payoff_matrix=None,
    )


def search_controllers_many(
    templates: list[SimultaneousTreeSearch],
    snapshots: list[Snapshot],
    sample_actions: bool = True,
) -> list[ControllerDecision]:
    """Commit independent actions after all controllers finish thinking.

    Both controllers simulate common fresh chance worlds. The parent streams
    consume a fixed number of seeds per decision, so changing the opponent's
    model, search width, or controller kind cannot change our random stream.
    Even mirrors evaluate both canonical perspectives: network heads are not
    assumed to be exactly equivariant under exchanging players.
    """
    if not templates or len(templates) != len(snapshots):
        raise ValueError("controller search requires one template per snapshot")
    staged: list[SimultaneousTreeSearch] = []
    roots: list[Snapshot] = []
    destinations: list[tuple[int, int]] = []
    outputs: list[list[SearchResult | None]] = [[None, None] for _ in templates]
    selection_streams: list[list[random.Random]] = []
    for index, (template, snapshot) in enumerate(
        zip(templates, snapshots, strict=True)
    ):
        if snapshot.done:
            raise ValueError("cannot select actions in a terminal state")
        selection = [
            random.Random(template.selection_rng.getrandbits(64)) for _ in range(2)
        ]
        selection_streams.append(selection)
        chance_seed = template.chance_rng.getrandbits(64)
        noise = template.prior_noise
        noise_seeds = [noise.rng.getrandbits(64) for _ in range(2)] if noise else []
        for slot, (side, network) in enumerate(
            (("player", template.player_network), ("enemy", template.enemy_network))
        ):
            if not getattr(network, "search_assisted", True):
                outputs[index][slot] = _direct_policy(network, snapshot, side)
                continue
            staged.append(
                SimultaneousTreeSearch(
                    template.server,
                    network,
                    network,
                    template.config,
                    selection[slot],
                    random.Random(chance_seed),
                    None
                    if noise is None
                    else replace(noise, rng=random.Random(noise_seeds[slot])),
                    evaluation_side=side,
                )
            )
            roots.append(snapshot)
            destinations.append((index, slot))
    if staged:
        results = SimultaneousTreeSearch.search_many(
            staged, roots, sample_actions=False
        )
        for (index, slot), result in zip(destinations, results, strict=True):
            outputs[index][slot] = result
    decisions = []
    for index, snapshot in enumerate(snapshots):
        player, enemy = outputs[index]
        if player is None or enemy is None:
            raise RuntimeError("controller batch left an unfinished decision")
        if player.failure is None and enemy.failure is None:
            player = replace(
                player,
                player_action=_choose(
                    player.player_policy,
                    snapshot.player_mask,
                    selection_streams[index][0],
                    sample_actions,
                ),
            )
            enemy = replace(
                enemy,
                enemy_action=_choose(
                    enemy.enemy_policy,
                    snapshot.enemy_mask,
                    selection_streams[index][1],
                    sample_actions,
                ),
            )
        decisions.append(ControllerDecision(player, enemy))
    return decisions
