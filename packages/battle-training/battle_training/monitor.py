"""Read-only web dashboard and atomic live-status files for training runs."""

from __future__ import annotations

import json
import math
import os
import tempfile
import threading
import webbrowser
from datetime import UTC, datetime
from hashlib import sha256 as hash_bytes
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlparse

from .artifacts import sha256
from .replay import build_replay_manifest

_STATIC_DIR = Path(__file__).with_name("web")
_STATIC_FILES = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/index.html": ("index.html", "text/html; charset=utf-8"),
    "/app.css": ("app.css", "text/css; charset=utf-8"),
    "/app.js": ("app.js", "text/javascript; charset=utf-8"),
    "/emulator-player.js": ("emulator-player.js", "text/javascript; charset=utf-8"),
    "/sameboy-worker.js": ("sameboy-worker.js", "text/javascript; charset=utf-8"),
    "/sameboy-core.js": ("sameboy-core.js", "text/javascript; charset=utf-8"),
    "/sameboy-core.wasm": ("sameboy-core.wasm", "application/wasm"),
    "/sameboy-LICENSE.txt": ("sameboy-LICENSE.txt", "text/plain; charset=utf-8"),
}


def _now() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def atomic_monitor_json(path: Path, payload: dict[str, Any]) -> None:
    """Replace mutable monitor state atomically without weakening run artifacts."""
    path.parent.mkdir(parents=True, exist_ok=True)
    data = (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode()
    temporary_name: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w+b",
            prefix=f".{path.name}.",
            suffix=".tmp",
            dir=path.parent,
            delete=False,
        ) as temporary:
            temporary_name = temporary.name
            temporary.write(data)
            temporary.flush()
            os.fsync(temporary.fileno())
        os.replace(temporary_name, path)
        temporary_name = None
    finally:
        if temporary_name is not None:
            Path(temporary_name).unlink(missing_ok=True)


def write_monitor_state(
    root: Path, stage: str, iteration: int | None = None, **details: Any
) -> None:
    path = root / "monitor-state.json"
    previous: dict[str, Any] = {}
    if path.is_file():
        try:
            previous = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            previous = {}
    payload = {
        "started_at": previous.get("started_at", _now()),
        "updated_at": _now(),
        "pid": os.getpid(),
        "stage": stage,
        "iteration": iteration,
        **details,
    }
    atomic_monitor_json(path, payload)


def write_actor_progress(
    path: Path,
    process: int,
    completed: int,
    total: int,
    **details: Any,
) -> None:
    atomic_monitor_json(
        path,
        {
            "updated_at": _now(),
            "process": process,
            "completed": completed,
            "total": total,
            **details,
        },
    )


def _read_json(path: Path) -> dict[str, Any] | None:
    if not path.is_file():
        return None
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


def _process_alive(pid: object) -> bool:
    if not isinstance(pid, int) or pid <= 0:
        return True
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _iteration_number(path: Path) -> int:
    return int(path.stem.removeprefix("iteration-"))


def _checkpoint_number(path: Path) -> int:
    return int(path.stem.removeprefix("policy-"))


def _aggregate_actor_progress(actors: list[dict[str, Any]]) -> dict[str, Any] | None:
    if not actors:
        return None
    summed = (
        "completed",
        "total",
        "finished",
        "truncated",
        "semantic_divergences",
        "transitions",
        "examples",
        "player_wins",
        "enemy_wins",
        "draws",
        "candidate_wins",
        "candidate_losses",
        "candidate_draws",
        "voluntary_switches",
        "setup_uses",
        "ordinary_actions",
        "major_status_attempts",
        "redundant_status_same",
        "redundant_status_other",
        "stat_setup_attempts",
        "capped_stat_setup",
        "ohko_attempts",
        "ohko_into_faster",
        "deep_search_decisions",
        "root_only_decisions",
        "forced_router_samples",
        "forced_router_false_negatives",
        "mirror_episodes",
        "opponent_episodes",
        "model_opponent_episodes",
        "heuristic_opponent_episodes",
        "six_vs_six_battles",
        "level100_six_vs_six_battles",
    )
    result = {name: sum(int(actor.get(name, 0)) for actor in actors) for name in summed}
    result["forced_router_false_negative_rate"] = result[
        "forced_router_false_negatives"
    ] / max(1, result["forced_router_samples"])
    completed = result["completed"]
    result["mean_decisions"] = (
        sum(
            float(actor.get("mean_decisions", 0.0)) * int(actor.get("completed", 0))
            for actor in actors
        )
        / completed
        if completed
        else 0.0
    )
    result["voluntary_switch_rate"] = result["voluntary_switches"] / max(
        1, result["ordinary_actions"]
    )
    result["setup_use_rate"] = result["setup_uses"] / max(1, result["ordinary_actions"])
    result["redundant_status_rate"] = (
        result["redundant_status_same"] + result["redundant_status_other"]
    ) / max(1, result["major_status_attempts"])
    result["capped_stat_setup_rate"] = result["capped_stat_setup"] / max(
        1, result["stat_setup_attempts"]
    )
    result["ohko_into_faster_rate"] = result["ohko_into_faster"] / max(
        1, result["ohko_attempts"]
    )
    versions = {
        str(actor["decision_quality_version"])
        for actor in actors
        if actor.get("decision_quality_version")
    }
    result["decision_quality_version"] = (
        next(iter(versions)) if len(versions) == 1 else None
    )
    species_schedules = {
        str(actor["species_schedule"])
        for actor in actors
        if actor.get("species_schedule")
    }
    result["species_schedule"] = (
        next(iter(species_schedules)) if len(species_schedules) == 1 else None
    )
    for field in (
        "party_size_counts",
        "opponent_counts",
        "setup_move_counts",
        "species_counts",
    ):
        counts: dict[str, int] = {}
        for actor in actors:
            for name, value in actor.get(field, {}).items():
                counts[name] = counts.get(name, 0) + int(value)
        result[field] = counts
    species_values = list(result["species_counts"].values())
    result["distinct_species"] = len(species_values)
    result["minimum_species_appearances"] = min(species_values, default=0)
    result["maximum_species_appearances"] = max(species_values, default=0)
    recent = [battle for actor in actors for battle in actor.get("recent_battles", [])]
    result["recent_battles"] = [
        {
            name: value
            for name, value in battle.items()
            if name not in {"initial", "final", "timeline"}
        }
        for battle in sorted(
            recent, key=lambda battle: int(battle.get("episode", -1)), reverse=True
        )[:20]
    ]
    result["iteration"] = max(
        (int(actor.get("iteration", 0)) for actor in actors), default=0
    )
    result["updated_at"] = max(
        (str(actor.get("updated_at", "")) for actor in actors), default=""
    )
    return result


def _aggregate_arena_progress(
    reports: list[dict[str, Any]], stage: object, iteration: object
) -> dict[str, Any] | None:
    active = [
        report
        for report in reports
        if report.get("stage") == stage and report.get("iteration") == iteration
    ]
    if not active:
        return None
    summed = (
        "completed",
        "finished",
        "wins",
        "losses",
        "draws",
        "truncated",
        "semantic_divergences",
        "mechanics_timeouts",
        "score_sum",
        "pair_score_sum",
        "pair_score_sumsq",
        "pairs",
    )
    result = {name: sum(report.get(name, 0) for report in active) for name in summed}
    total = max((int(report.get("arena_games", 0)) for report in active), default=0)
    completed = int(result["completed"])
    result.update(
        {
            "live": True,
            "stage": stage,
            "iteration": iteration,
            "games": total,
            "total": total,
            "score_with_nonfinishes_as_losses": (
                float(result["score_sum"]) / completed if completed else None
            ),
            "updated_at": max(
                (str(report.get("updated_at", "")) for report in active), default=""
            ),
        }
    )
    pairs = int(result["pairs"])
    if pairs:
        mean = float(result["pair_score_sum"]) / pairs
        if pairs < 2:
            low = high = mean
        else:
            variance = (
                float(result["pair_score_sumsq"])
                - float(result["pair_score_sum"]) ** 2 / pairs
            ) / (pairs - 1)
            radius = 1.96 * math.sqrt(max(0.0, variance) / pairs)
            low, high = max(0.0, mean - radius), min(1.0, mean + radius)
        result["paired_score_ci95"] = [low, high]
    else:
        result["paired_score_ci95"] = [None, None]
    recent = [
        battle for report in active for battle in report.get("recent_battles", [])
    ]
    result["battles"] = sorted(recent, key=lambda battle: battle["game"])[-40:]
    return result


def build_dashboard_snapshot(root: Path) -> dict[str, Any]:
    """Project immutable and live artifacts into one dashboard response."""
    root = root.resolve()
    run = _read_json(root / "run.json") or {}
    summary = _read_json(root / "summary.json")
    status = _read_json(root / "monitor-state.json") or {
        "stage": "completed" if summary is not None else "waiting",
        "iteration": summary.get("iterations") if summary else None,
        "updated_at": None,
    }
    if status.get("stage") not in {"completed", "failed"} and not _process_alive(
        status.get("pid")
    ):
        status = {
            **status,
            "last_stage": status.get("stage"),
            "stage": "failed",
            "message": "Training process exited before completing the iteration",
        }
    metric_paths = sorted(
        (root / "metrics").glob("iteration-*.json")
        if (root / "metrics").is_dir()
        else [],
        key=_iteration_number,
    )
    iterations = []
    for path in metric_paths:
        metric = _read_json(path)
        if metric is not None:
            iterations.append({"iteration": _iteration_number(path), **metric})
    checkpoint_paths = sorted(
        (root / "checkpoints").glob("policy-*.pt")
        if (root / "checkpoints").is_dir()
        else [],
        key=_checkpoint_number,
    )
    checkpoint = None
    if checkpoint_paths:
        latest_checkpoint = checkpoint_paths[-1]
        checkpoint = {
            "iteration": _checkpoint_number(latest_checkpoint),
            "path": latest_checkpoint.relative_to(root).as_posix(),
            "bytes": latest_checkpoint.stat().st_size,
            "sha256": sha256(latest_checkpoint),
        }
    actor_paths = sorted(
        (root / ".monitor").glob("actor-*.json") if (root / ".monitor").is_dir() else []
    )
    actors = [value for path in actor_paths if (value := _read_json(path)) is not None]
    arena_paths = sorted(
        (root / ".monitor").glob("arena-*.json") if (root / ".monitor").is_dir() else []
    )
    arena_reports = [
        value for path in arena_paths if (value := _read_json(path)) is not None
    ]
    live_arena = _aggregate_arena_progress(
        arena_reports, status.get("stage"), status.get("iteration")
    )
    if live_arena is not None and live_arena["updated_at"] > str(
        status.get("updated_at", "")
    ):
        status = {
            **status,
            "updated_at": live_arena["updated_at"],
            "completed": live_arena["completed"],
            "games": live_arena["games"],
            "message": (
                f"Running paired promotion games: "
                f"{live_arena['completed']:,} / {live_arena['games']:,}"
            ),
        }
    public_actors = [
        {name: value for name, value in actor.items() if name != "recent_battles"}
        for actor in actors
    ]
    latest = iterations[-1] if iterations else None
    live_collection = _aggregate_actor_progress(actors)
    return {
        "generated_at": _now(),
        "root": str(root),
        "run": run,
        "status": status,
        "summary": summary,
        "model": {
            "network": run.get("network", {}),
            "parameter_count": run.get("parameter_count"),
            "device": run.get("device"),
            "device_name": run.get("device_name"),
            "pipeline": run.get("pipeline"),
            "profile": run.get("profile"),
            "schema": run.get("schema"),
            "learning_lineage": run.get("learning_lineage"),
            "deployment_lineage": run.get("deployment_lineage"),
            "checkpoint": checkpoint,
        },
        "actors": public_actors,
        "collection": live_collection or (latest or {}).get("collection"),
        "evaluation": live_arena,
        "iterations": iterations,
        "latest": latest,
    }


def build_match_detail(
    root: Path, kind: str, iteration: int, match: int
) -> dict[str, Any] | None:
    """Load one recorded match without projecting all timelines every poll."""
    root = root.resolve()
    if iteration < 1 or match < 0:
        raise ValueError("iteration and match must be nonnegative")
    if kind == "selfplay":
        for path in sorted((root / ".monitor").glob("actor-*.json")):
            actor = _read_json(path) or {}
            if int(actor.get("iteration", -1)) != iteration:
                continue
            for battle in actor.get("recent_battles", []):
                if int(battle.get("episode", -1)) == match:
                    return {"kind": kind, "iteration": iteration, **battle}
        shard = root / "shards" / f"iteration-{iteration:03d}.jsonl"
        try:
            with shard.open() as source:
                for line in source:
                    row = json.loads(line)
                    if row.get("type") == "episode" and row.get("episode") == match:
                        return {"kind": kind, "iteration": iteration, **row}
        except (FileNotFoundError, OSError, json.JSONDecodeError):
            return None
        return None
    if kind == "promotion":
        game = _read_json(
            root / "matches" / f"promotion-{iteration:03d}" / f"game-{match:05d}.json"
        )
        if game is not None and int(game.get("game", -1)) == match:
            return {"kind": kind, "iteration": iteration, **game}
        detail = _read_json(root / "matches" / f"promotion-{iteration:03d}.json")
        if detail is not None:
            for battle in detail.get("battles", []):
                if int(battle.get("game", -1)) == match:
                    return {"kind": kind, "iteration": iteration, **battle}
        metric = _read_json(root / "metrics" / f"iteration-{iteration:03d}.json")
        if metric is not None:
            for battle in metric.get("promotion", {}).get("battles", []):
                if int(battle.get("game", -1)) == match:
                    return {"kind": kind, "iteration": iteration, **battle}
        return None
    raise ValueError("match kind must be selfplay or promotion")


class DashboardStore:
    def __init__(self, root: Path) -> None:
        self.root = root.resolve()
        self._lock = threading.Lock()
        self._match_lock = threading.Lock()
        self._replay_lock = threading.Lock()
        self._signature: tuple[tuple[str, int, int], ...] = ()
        self._snapshot: dict[str, Any] | None = None
        self._matches: dict[tuple[str, int, int], dict[str, Any]] = {}
        self._replays: dict[tuple[str, int, int], dict[str, Any]] = {}

    def _artifact_signature(self) -> tuple[tuple[str, int, int], ...]:
        paths = [
            self.root / "run.json",
            self.root / "summary.json",
            self.root / "monitor-state.json",
        ]
        paths.extend(sorted((self.root / "metrics").glob("iteration-*.json")))
        paths.extend(sorted((self.root / "checkpoints").glob("policy-*.pt")))
        paths.extend(sorted((self.root / ".monitor").glob("actor-*.json")))
        paths.extend(sorted((self.root / ".monitor").glob("arena-*.json")))
        return tuple(
            (
                path.relative_to(self.root).as_posix(),
                path.stat().st_mtime_ns,
                path.stat().st_size,
            )
            for path in paths
            if path.is_file()
        )

    def snapshot(self) -> dict[str, Any]:
        with self._lock:
            signature = self._artifact_signature()
            if signature != self._signature or self._snapshot is None:
                self._snapshot = build_dashboard_snapshot(self.root)
                self._signature = signature
            return self._snapshot

    def match(self, kind: str, iteration: int, match: int) -> dict[str, Any] | None:
        key = (kind, iteration, match)
        with self._match_lock:
            cached = self._matches.get(key)
            if cached is not None:
                return cached
            detail = build_match_detail(self.root, kind, iteration, match)
            if detail is not None:
                self._matches[key] = detail
            return detail

    def replay(self, kind: str, iteration: int, match: int) -> dict[str, Any] | None:
        key = (kind, iteration, match)
        with self._replay_lock:
            cached = self._replays.get(key)
            if cached is not None:
                return cached
            detail = self.match(kind, iteration, match)
            if detail is None:
                return None
            run = _read_json(self.root / "run.json") or {}
            manifest = build_replay_manifest(run, detail)
            self._replays[key] = manifest
            return manifest


class _MonitorServer(ThreadingHTTPServer):
    daemon_threads = True
    store: DashboardStore


class _MonitorHandler(BaseHTTPRequestHandler):
    server: _MonitorServer

    def _send(
        self,
        status: HTTPStatus,
        payload: bytes,
        content_type: str,
        *,
        cache: str = "no-store",
    ) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", cache)
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self'; "
            "img-src 'self' data: https://raw.githubusercontent.com; "
            "connect-src 'self'; worker-src 'self'; base-uri 'none'; frame-ancestors 'none'",
        )
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self) -> None:
        path = urlparse(self.path).path
        if path == "/api/dashboard":
            payload = json.dumps(
                self.server.store.snapshot(), separators=(",", ":")
            ).encode()
            self._send(HTTPStatus.OK, payload, "application/json; charset=utf-8")
            return
        if path == "/api/health":
            self._send(HTTPStatus.OK, b'{"ok":true}', "application/json")
            return
        if path == "/api/replay":
            query = parse_qs(urlparse(self.path).query)
            try:
                kind = query.get("kind", [""])[0]
                iteration = int(query.get("iteration", [""])[0])
                match = int(query.get("match", [""])[0])
                replay = self.server.store.replay(kind, iteration, match)
            except (KeyError, TypeError, ValueError) as error:
                payload = json.dumps({"error": str(error)}).encode()
                self._send(
                    HTTPStatus.UNPROCESSABLE_ENTITY,
                    payload,
                    "application/json; charset=utf-8",
                )
                return
            except (OSError, RuntimeError) as error:
                payload = json.dumps({"error": str(error)}).encode()
                self._send(
                    HTTPStatus.SERVICE_UNAVAILABLE,
                    payload,
                    "application/json; charset=utf-8",
                )
                return
            if replay is None:
                self._send(
                    HTTPStatus.NOT_FOUND,
                    b'{"error":"recorded replay unavailable"}',
                    "application/json",
                )
                return
            payload = json.dumps(replay, separators=(",", ":")).encode()
            self._send(HTTPStatus.OK, payload, "application/json; charset=utf-8")
            return
        if path == "/api/match":
            query = parse_qs(urlparse(self.path).query)
            try:
                kind = query.get("kind", [""])[0]
                iteration = int(query.get("iteration", [""])[0])
                match = int(query.get("match", [""])[0])
                detail = self.server.store.match(kind, iteration, match)
            except (TypeError, ValueError):
                self._send(
                    HTTPStatus.BAD_REQUEST,
                    b'{"error":"invalid match query"}',
                    "application/json",
                )
                return
            if detail is None:
                self._send(
                    HTTPStatus.NOT_FOUND,
                    b'{"error":"match detail unavailable"}',
                    "application/json",
                )
                return
            payload = json.dumps(detail, separators=(",", ":")).encode()
            self._send(HTTPStatus.OK, payload, "application/json; charset=utf-8")
            return
        static = _STATIC_FILES.get(path)
        if static is None:
            self._send(HTTPStatus.NOT_FOUND, b"not found\n", "text/plain")
            return
        file_name, content_type = static
        payload = (_STATIC_DIR / file_name).read_bytes()
        etag = hash_bytes(payload).hexdigest()[:16]
        if self.headers.get("If-None-Match") == etag:
            self.send_response(HTTPStatus.NOT_MODIFIED)
            self.end_headers()
            return
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "public, max-age=300")
        self.send_header("ETag", etag)
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self'; "
            "img-src 'self' data: https://raw.githubusercontent.com; "
            "connect-src 'self'; worker-src 'self'; base-uri 'none'; frame-ancestors 'none'",
        )
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, format: str, *args: Any) -> None:
        return


def serve_monitor(
    root: Path,
    host: str = "127.0.0.1",
    port: int = 8765,
    open_browser: bool = False,
) -> None:
    root = root.resolve()
    if not root.is_dir():
        raise FileNotFoundError(f"training run directory does not exist: {root}")
    if not all((_STATIC_DIR / name).is_file() for name, _ in _STATIC_FILES.values()):
        raise FileNotFoundError("training monitor web assets are missing")
    server = _MonitorServer((host, port), _MonitorHandler)
    server.store = DashboardStore(root)
    url = f"http://{host}:{server.server_port}/"
    print(f"Training monitor: {url}")
    print(f"Run: {root}")
    if open_browser:
        webbrowser.open(url)
    try:
        server.serve_forever(poll_interval=0.25)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
