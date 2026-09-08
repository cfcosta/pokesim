"""PyO3 adapter for Rust-owned simultaneous tree orchestration.

Python supplies existing batched simulator/evaluator/solver services and RNGs.
Rust owns nodes, expansion, chance request scheduling, leaf collection, backup,
and split-half matrices. There is no fallback to Python when Rust is requested.
"""

from __future__ import annotations

import hashlib
import importlib.machinery
import importlib.util
import os
import sys
from functools import lru_cache
from pathlib import Path
from types import SimpleNamespace

from .joint_search import SimultaneousTreeSearch, _dirichlet_noised_priors


class NativeSearchError(RuntimeError):
    pass


@lru_cache(maxsize=1)
def _library():
    suffix = "dylib" if sys.platform == "darwin" else "so"
    filename = "battle_search.dll" if os.name == "nt" else f"libbattle_search.{suffix}"
    configured = os.environ.get("BATTLE_SEARCH_LIB")
    if not configured:
        try:
            import battle_search
        except ModuleNotFoundError as error:
            if error.name != "battle_search":
                raise NativeSearchError(str(error)) from error
        except ImportError as error:
            raise NativeSearchError(str(error)) from error
        else:
            # Maturin wheels re-export the extension from a package __init__.
            battle_search = getattr(battle_search, "battle_search", battle_search)
            if getattr(battle_search, "API_VERSION", None) != 1:
                raise NativeSearchError("incompatible installed Rust search API")
            return battle_search
    root = Path(__file__).resolve().parents[2] / "search-rs" / "target"
    candidates = ([Path(configured)] if configured else []) + [
        root / p / filename for p in ("release", "debug")
    ]
    # An explicitly configured path is authoritative, never silently bypassed.
    if configured:
        candidates = [
            Path(configured) / filename
            if Path(configured).is_dir()
            else Path(configured)
        ]
    errors = []
    for path in candidates:
        try:
            spec = importlib.util.spec_from_file_location(
                "battle_search",
                path,
                loader=importlib.machinery.ExtensionFileLoader(
                    "battle_search", str(path)
                ),
            )
            if spec is None or spec.loader is None:
                raise ImportError("cannot load Python extension")
            lib = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(lib)
            if lib.API_VERSION != 1:
                raise NativeSearchError("incompatible Rust search API")
            return lib
        except (ImportError, OSError, AttributeError, NativeSearchError) as error:
            errors.append(f"{path}: {error}")
    raise NativeSearchError(
        "Rust search unavailable; build packages/search-rs or set BATTLE_SEARCH_LIB. "
        + "; ".join(errors)
    )


def orchestration_metadata(backend):
    if backend == "python":
        return {"backend": "python-matrix-tree-v1"}
    if backend != "rust":
        raise ValueError("orchestration_backend must be python or rust")
    library = _library()
    path = Path(library.__file__).resolve()
    return {
        "backend": "rust-matrix-tree-v1",
        "api": library.API_VERSION,
        "bridge": "pyo3",
        "library": str(path),
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    }


def native_available():
    try:
        _library()
    except NativeSearchError:
        return False
    return True


def _metas(snapshots):
    return [
        (
            s.handle,
            s.player_mask,
            s.enemy_mask,
            int(s.done),
            int(s.divergence is not None),
        )
        for s in snapshots
    ]


def _seeds(searches, roots, interior):
    return [
        seed
        for root in roots
        for seed in searches[root]._chance_seeds(
            searches[root].config.interior_chance_samples
            if interior
            else searches[root].config.chance_samples_per_joint
        )
    ]


class _Engine:
    """Exception-safe ownership of one native tree; borrowed buffers never escape."""

    def __init__(self, searches, snapshots, evaluations):
        self.lib = _library()
        self.handle = None
        self.snapshots = list(snapshots)
        self.actions = searches[0].action_count
        owners = {}
        configs = []
        for i, search in enumerate(searches):
            c = search.config
            configs.append(
                (
                    owners.setdefault(id(search), i),
                    c.max_depth,
                    c.max_actions_per_side,
                    c.interior_actions_per_side,
                    c.chance_samples_per_joint,
                    c.interior_chance_samples,
                    int(c.split_half_reliability),
                    search._interior_divergences,
                )
            )
        if any(
            len(p) != self.actions or len(e) != self.actions for p, e, _ in evaluations
        ):
            raise NativeSearchError(
                "evaluation action count does not match search schema"
            )
        data = [v for p, e, value in evaluations for v in (*p, *e, value)]
        seeds = _seeds(searches, range(len(searches)), False)
        try:
            self.handle = self.lib.Engine(
                self.actions, configs, _metas(snapshots), data, seeds
            )
        except (RuntimeError, ValueError, TypeError, OverflowError) as error:
            raise NativeSearchError(str(error)) from error

    def call(self, method, *args):
        if self.handle is None:
            raise NativeSearchError("native search is closed")
        try:
            return getattr(self.handle, method)(*args)
        except (RuntimeError, ValueError, TypeError, OverflowError) as error:
            raise NativeSearchError(str(error)) from error

    def close(self):
        if self.handle is not None:
            self.handle.close()
            self.handle = None

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def view(self):
        return self.call("view")

    def node(self, index, full=False):
        fields = self.call("node", index, full)
        fields["snapshot"] = self.snapshots[fields["snapshot"]]
        return SimpleNamespace(
            **fields,
            online_exploitability=0.0,
            solve_count=0,
            solve_backend="",
        )

    def submit_doubles(self, kind, values):
        self.call(kind, values)


def _groups(searches, snapshots, rows):
    groups = {}
    for root, index in rows:
        groups.setdefault(root, []).append(snapshots[index])
    return [(root, searches[root], values) for root, values in groups.items()]


def _ordered_evaluations(evaluations, rows):
    slots = {}
    result = []
    for root, _ in rows:
        slot = slots.get(root, 0)
        slots[root] = slot + 1
        p, e, v = evaluations[root]
        result.append((p[slot], e[slot], v[slot]))
    return result


class RustSimultaneousTreeSearch(SimultaneousTreeSearch):
    @classmethod
    def search_many(cls, searches, snapshots, sample_actions=True):
        if not searches or len(searches) != len(snapshots):
            raise ValueError("search_many requires one search per snapshot")
        if any(s.done for s in snapshots):
            raise ValueError("cannot search a terminal state")
        first = searches[0]
        if any(
            s.server is not first.server or s.action_count != first.action_count
            for s in searches[1:]
        ):
            raise ValueError("cross-root batches require one server and action schema")
        _library()  # Fail before inference or RNG consumption if deployment is incomplete.
        evaluated, _, _ = cls._pooled_evaluate(
            [(i, s, [snapshots[i]]) for i, s in enumerate(searches)]
        )
        evaluations = _ordered_evaluations(
            evaluated, [(i, i) for i in range(len(searches))]
        )
        for i, (search, snapshot) in enumerate(zip(searches, snapshots, strict=True)):
            p, e, value = evaluations[i]
            if search.prior_noise is not None:
                p = _dirichlet_noised_priors(
                    p, snapshot.player_mask, search.prior_noise
                )
                e = _dirichlet_noised_priors(e, snapshot.enemy_mask, search.prior_noise)
            evaluations[i] = (p, e, value)
            search._evaluation_cache[snapshot.handle] = evaluations[i]
        root_solutions, root_backends = {}, {}
        with _Engine(searches, snapshots, evaluations) as engine:
            while True:
                stage, rows = engine.view()
                if stage == 5:
                    break
                if stage == 1:
                    successors = first.server.search_steps(rows)
                    engine.call("steps", _metas(successors))
                    engine.snapshots.extend(successors)
                elif stage == 2:
                    groups = _groups(searches, engine.snapshots, rows)
                    distilled = [
                        g
                        for g in groups
                        if g[1].config.leaf_evaluator == "distilled"
                        and all(
                            bool(getattr(n.config, "distilled_leaf_policy", False))
                            for n in (g[1].player_network, g[1].enemy_network)
                        )
                    ]
                    distilled_ids = {g[0] for g in distilled}
                    full = [g for g in groups if g[0] not in distilled_ids]
                    evaluated = {}
                    if distilled:
                        result, _, _ = cls._pooled_leaf_evaluate(distilled)
                        evaluated.update(result)
                    if full:
                        result, _, _ = cls._pooled_evaluate(full)
                        evaluated.update(result)
                    ordered = _ordered_evaluations(evaluated, rows)
                    seeds = _seeds(searches, [g[0] for g in groups], True)
                    for (root, index), evaluation in zip(rows, ordered, strict=True):
                        searches[root]._evaluation_cache[
                            engine.snapshots[index].handle
                        ] = evaluation
                    data = [v for p, e, value in ordered for v in (*p, *e, value)]
                    engine.call("evaluations", data, seeds)
                elif stage == 3:
                    result, _, _ = cls._pooled_successor_values(
                        _groups(searches, engine.snapshots, rows)
                    )
                    slots, values = {}, []
                    for root, _ in rows:
                        slot = slots.get(root, 0)
                        slots[root] = slot + 1
                        values.append(result[root][slot][0])
                    engine.submit_doubles("values", values)
                elif stage == 4:
                    nodes, jobs = {}, []
                    for root, index, half in rows:
                        if index not in nodes:
                            nodes[index] = engine.node(
                                index, full=index < len(searches)
                            )
                        node = nodes[index]
                        jobs.append(
                            (
                                searches[root],
                                node,
                                node.payoff
                                if half == 0
                                else node.half_payoff[half - 1],
                            )
                        )
                    solutions = cls._solve_matrices(jobs)
                    for (root, index, half), solution in zip(
                        rows, solutions, strict=True
                    ):
                        if index < len(searches):
                            root_solutions.setdefault(root, {})[half] = solution
                            root_backends[root] = nodes[index].solve_backend
                    engine.submit_doubles(
                        "solutions", [v for solution in solutions for v in solution[2:]]
                    )
                else:
                    raise NativeSearchError(f"unknown native search phase {stage}")
            # Counters are cumulative on a search object, including when an object
            # is reused across calls or appears more than once in the same batch.
            statuses, updated = [], set()
            for i, search in enumerate(searches):
                status = SimpleNamespace(**engine.call("root", i))
                statuses.append(status)
                if id(search) not in updated:
                    updated.add(id(search))
                    for name, field in (
                        ("_expanded_nodes", "expanded"),
                        ("_possible_joint_pairs", "possible_pairs"),
                        ("_sampled_joint_pairs", "sampled_pairs"),
                        ("_chance_outcomes", "chance_outcomes"),
                        ("_interior_nodes", "interior_nodes"),
                    ):
                        setattr(
                            search, name, getattr(search, name) + getattr(status, field)
                        )
                    search._interior_divergences = status.interior_divergences
            results = []
            for i, (search, status) in enumerate(zip(searches, statuses, strict=True)):
                search._cross_root_batch_size = len(searches)
                search._cross_root_root_leaves = status.root_leaves
                if not status.good:
                    results.append(
                        search._fallback(*evaluations[i], status.root_leaves)
                    )
                    continue
                node = engine.node(i, full=True)
                node.solve_backend = root_backends[i]
                solutions = root_solutions[i]
                p, e, value, exploitability = search._root_equilibrium(
                    node,
                    solutions[0],
                    [solutions[h] for h in (1, 2)] if 1 in solutions else None,
                )
                node.player_policy, node.enemy_policy = list(p), list(e)
                node.root_value, node.exploitability = value, exploitability
                node.solve_count = search.config.regret_iterations
                results.append(
                    search._finish_root(node, status.transitions, sample_actions)
                )
            return results
