"""Checked C-ABI adapter for Rust-owned simultaneous tree orchestration.

Python supplies existing batched simulator/evaluator/solver services and RNGs.
Rust owns nodes, expansion, chance request scheduling, leaf collection, backup,
and split-half matrices. There is no fallback to Python when Rust is requested.
"""

from __future__ import annotations

import ctypes as C
import hashlib
import os
import sys
from functools import lru_cache
from pathlib import Path
from types import SimpleNamespace

import numpy as np

from .joint_search import SimultaneousTreeSearch, _dirichlet_noised_priors

U = C.c_uint64
F = C.c_double
P = C.c_void_p


def _struct(name, fields):
    return type(name, (C.Structure,), {"_fields_": fields})


Config = _struct(
    "Config",
    [
        (n, U)
        for n in (
            "owner",
            "depth",
            "root_width",
            "interior_width",
            "root_chances",
            "interior_chances",
            "split",
            "initial_divergences",
        )
    ],
)
SnapshotMeta = _struct(
    "SnapshotMeta",
    [(n, U) for n in ("handle", "player_mask", "enemy_mask", "done", "divergent")],
)
Row = _struct("Row", [("root", U), ("snapshot", U)])
Request = _struct("Request", [(n, U) for n in ("handle", "player", "enemy", "seed")])
Job = _struct("Job", [(n, U) for n in ("root", "node", "half")])
Status = _struct(
    "Status", [(n, U) for n in ("stage", "rows", "requests", "jobs", "seed_count")]
)
RootStatus = _struct(
    "RootStatus",
    [
        (n, U)
        for n in (
            "good",
            "transitions",
            "root_leaves",
            "expanded",
            "possible_pairs",
            "sampled_pairs",
            "chance_outcomes",
            "interior_nodes",
            "interior_divergences",
        )
    ],
)
NodeView = _struct(
    "NodeView",
    [(n, U) for n in ("root", "snapshot", "player_len", "enemy_len")]
    + [(n, C.POINTER(F)) for n in ("player", "enemy")]
    + [(n, C.POINTER(U)) for n in ("legal_player", "legal_enemy")]
    + [("payoff", C.POINTER(F)), ("counts", C.POINTER(U))]
    + [(n, C.POINTER(F)) for n in ("half0", "half1")]
    + [(n, C.POINTER(U)) for n in ("counts0", "counts1")]
    + [(n, F) for n in ("leaf", "value", "exploitability")],
)


class NativeSearchError(RuntimeError):
    pass


@lru_cache(maxsize=1)
def _library():
    suffix = "dylib" if sys.platform == "darwin" else "so"
    filename = "battle_search.dll" if os.name == "nt" else f"libbattle_search.{suffix}"
    configured = os.environ.get("BATTLE_SEARCH_LIB")
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
            lib = C.CDLL(str(path))
            signatures = {
                "abi": ([], U),
                "new": (
                    [
                        C.c_size_t,
                        P,
                        P,
                        C.c_size_t,
                        P,
                        C.c_size_t,
                        P,
                        C.c_size_t,
                        C.POINTER(P),
                    ],
                    C.c_int,
                ),
                "free": ([P], None),
                "steps": ([P, P, C.c_size_t], C.c_int),
                "values": ([P, P, C.c_size_t], C.c_int),
                "solutions": ([P, P, C.c_size_t], C.c_int),
                "evaluations": ([P, P, C.c_size_t, P, C.c_size_t], C.c_int),
                "view": ([P, P, P, P, P], C.c_int),
                "node": ([P, C.c_size_t, P], C.c_int),
                "root": ([P, C.c_size_t, P], C.c_int),
                "error": ([P, P, C.c_size_t], C.c_size_t),
            }
            for name, (args, result) in signatures.items():
                fn = getattr(lib, f"battle_search_{name}_v1")
                fn.argtypes, fn.restype = args, result
            if lib.battle_search_abi_v1() != 1:
                raise NativeSearchError("incompatible Rust search ABI")
            return lib
        except (OSError, AttributeError, NativeSearchError) as error:
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
    path = Path(library._name).resolve()
    return {
        "backend": "rust-matrix-tree-v1",
        "abi": library.battle_search_abi_v1(),
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
    return (SnapshotMeta * len(snapshots))(
        *(
            SnapshotMeta(
                s.handle,
                s.player_mask,
                s.enemy_mask,
                bool(s.done),
                s.divergence is not None,
            )
            for s in snapshots
        )
    )


def _doubles(values):
    return np.ascontiguousarray(values, dtype=np.float64)


def _seeds(searches, roots, interior):
    return np.asarray(
        [
            seed
            for root in roots
            for seed in searches[root]._chance_seeds(
                searches[root].config.interior_chance_samples
                if interior
                else searches[root].config.chance_samples_per_joint
            )
        ],
        dtype=np.uint64,
    )


class _Engine:
    """Exception-safe ownership of one native tree; borrowed buffers never escape."""

    def __init__(self, searches, snapshots, evaluations):
        self.lib = _library()
        self.handle = P()
        self.snapshots = list(snapshots)
        self.actions = searches[0].action_count
        owners = {}
        configs = []
        for i, search in enumerate(searches):
            c = search.config
            configs.append(
                Config(
                    owners.setdefault(id(search), i),
                    c.max_depth,
                    c.max_actions_per_side,
                    c.interior_actions_per_side,
                    c.chance_samples_per_joint,
                    c.interior_chance_samples,
                    c.split_half_reliability,
                    search._interior_divergences,
                )
            )
        if any(
            len(p) != self.actions or len(e) != self.actions for p, e, _ in evaluations
        ):
            raise NativeSearchError(
                "evaluation action count does not match search schema"
            )
        data = _doubles([v for p, e, value in evaluations for v in (*p, *e, value)])
        seeds = _seeds(searches, range(len(searches)), False)
        self.check(
            self.lib.battle_search_new_v1(
                self.actions,
                (Config * len(configs))(*configs),
                _metas(snapshots),
                len(searches),
                data.ctypes.data,
                data.size,
                seeds.ctypes.data,
                seeds.size,
                C.byref(self.handle),
            )
        )

    def check(self, code):
        if code:
            message = C.create_string_buffer(1024)
            self.lib.battle_search_error_v1(self.handle, message, len(message))
            raise NativeSearchError(
                message.value.decode()
                or f"native search rejected input (status {code})"
            )

    def close(self):
        if self.handle:
            self.lib.battle_search_free_v1(self.handle)
            self.handle = P()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def view(self):
        status = Status()
        rows, requests, jobs = C.POINTER(Row)(), C.POINTER(Request)(), C.POINTER(Job)()
        self.check(
            self.lib.battle_search_view_v1(
                self.handle,
                C.byref(status),
                C.byref(rows),
                C.byref(requests),
                C.byref(jobs),
            )
        )
        # Copy only the event payload before any mutation invalidates the views.
        if status.stage == 1:
            data = [
                (r.handle, r.player, r.enemy, r.seed)
                for r in requests[: status.requests]
            ]
        elif status.stage in (2, 3):
            data = [(r.root, r.snapshot) for r in rows[: status.rows]]
        elif status.stage == 4:
            data = [(j.root, j.node, j.half) for j in jobs[: status.jobs]]
        else:
            data = []
        return status.stage, data

    def node(self, index, full=False):
        view = NodeView()
        self.check(self.lib.battle_search_node_v1(self.handle, index, C.byref(view)))
        a = self.actions

        def vector(ptr, size):
            return np.ctypeslib.as_array(ptr, shape=(size,)).tolist()

        def matrix(ptr):
            return np.ctypeslib.as_array(ptr, shape=(a * a,)).reshape(a, a).tolist()

        node = SimpleNamespace(
            snapshot=self.snapshots[view.snapshot],
            player_priors=vector(view.player, a),
            enemy_priors=vector(view.enemy, a),
            player_legal=vector(view.legal_player, view.player_len),
            enemy_legal=vector(view.legal_enemy, view.enemy_len),
            payoff=matrix(view.payoff),
            leaf_value=view.leaf,
            root_value=view.value,
            exploitability=view.exploitability,
            online_exploitability=0.0,
            solve_count=0,
            solve_backend="",
            half_payoff=[],
            half_counts=[],
        )
        if full and view.half0:
            node.half_payoff = [matrix(view.half0), matrix(view.half1)]
            node.half_counts = [matrix(view.counts0), matrix(view.counts1)]
        return node

    def submit_doubles(self, kind, values):
        data = _doubles(values)
        self.check(
            getattr(self.lib, f"battle_search_{kind}_v1")(
                self.handle, data.ctypes.data, data.size
            )
        )


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
                    engine.check(
                        engine.lib.battle_search_steps_v1(
                            engine.handle, _metas(successors), len(successors)
                        )
                    )
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
                    data = _doubles(
                        [v for p, e, value in ordered for v in (*p, *e, value)]
                    )
                    engine.check(
                        engine.lib.battle_search_evaluations_v1(
                            engine.handle,
                            data.ctypes.data,
                            data.size,
                            seeds.ctypes.data,
                            seeds.size,
                        )
                    )
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
                status = RootStatus()
                engine.check(
                    engine.lib.battle_search_root_v1(engine.handle, i, C.byref(status))
                )
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
