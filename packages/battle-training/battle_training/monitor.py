"""Read-only web dashboard and atomic live-status files for training runs."""

from __future__ import annotations

import json
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
from urllib.parse import urlparse

from .artifacts import sha256

_STATIC_DIR = Path(__file__).with_name("web")
_STATIC_FILES = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/index.html": ("index.html", "text/html; charset=utf-8"),
    "/app.css": ("app.css", "text/css; charset=utf-8"),
    "/app.js": ("app.js", "text/javascript; charset=utf-8"),
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
        "ordinary_actions",
        "deep_search_decisions",
        "root_only_decisions",
        "mirror_episodes",
        "opponent_episodes",
    )
    result = {
        name: sum(int(actor.get(name, 0)) for actor in actors) for name in summed
    }
    completed = result["completed"]
    result["mean_decisions"] = (
        sum(
            float(actor.get("mean_decisions", 0.0))
            * int(actor.get("completed", 0))
            for actor in actors
        )
        / completed
        if completed
        else 0.0
    )
    result["voluntary_switch_rate"] = result["voluntary_switches"] / max(
        1, result["ordinary_actions"]
    )
    for field in ("party_size_counts", "opponent_counts"):
        counts: dict[str, int] = {}
        for actor in actors:
            for name, value in actor.get(field, {}).items():
                counts[name] = counts.get(name, 0) + int(value)
        result[field] = counts
    recent = [battle for actor in actors for battle in actor.get("recent_battles", [])]
    result["recent_battles"] = sorted(
        recent, key=lambda battle: int(battle.get("episode", -1)), reverse=True
    )[:20]
    result["updated_at"] = max(
        (str(actor.get("updated_at", "")) for actor in actors), default=""
    )
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
        (root / ".monitor").glob("actor-*.json")
        if (root / ".monitor").is_dir()
        else []
    )
    actors = [value for path in actor_paths if (value := _read_json(path)) is not None]
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
        "actors": actors,
        "collection": live_collection or (latest or {}).get("collection"),
        "iterations": iterations,
        "latest": latest,
    }


class DashboardStore:
    def __init__(self, root: Path) -> None:
        self.root = root.resolve()
        self._lock = threading.Lock()
        self._signature: tuple[tuple[str, int, int], ...] = ()
        self._snapshot: dict[str, Any] | None = None

    def _artifact_signature(self) -> tuple[tuple[str, int, int], ...]:
        paths = [
            self.root / "run.json",
            self.root / "summary.json",
            self.root / "monitor-state.json",
        ]
        paths.extend(sorted((self.root / "metrics").glob("iteration-*.json")))
        paths.extend(sorted((self.root / "checkpoints").glob("policy-*.pt")))
        paths.extend(sorted((self.root / ".monitor").glob("actor-*.json")))
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
            "default-src 'self'; script-src 'self'; style-src 'self'; "
            "img-src 'self' data:; connect-src 'self'; base-uri 'none'; "
            "frame-ancestors 'none'",
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
            "default-src 'self'; script-src 'self'; style-src 'self'; "
            "img-src 'self' data:; connect-src 'self'; base-uri 'none'; "
            "frame-ancestors 'none'",
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
