"""Persistent client for Lean-owned immutable full-party search states."""

from __future__ import annotations

import base64
import hashlib
import json
import selectors
import struct
import subprocess
import threading
from contextlib import suppress
from dataclasses import dataclass
from typing import Any, Self

import numpy as np
from numpy.typing import NDArray

from . import (
    FULL_ACTION_COUNT,
    FULL_CAMPAIGN_COUNT,
    FULL_PARTY_SIZE,
    FULL_PROFILE,
    FULL_SCHEMA,
)
from .worker import LEAN_PACKAGE, REPO_ROOT

SEARCH_SERVER = LEAN_PACKAGE / ".lake" / "build" / "bin" / "battleSearchServer"


class NativeRequestTimeout(RuntimeError):
    def __init__(self, operation: str, seconds: float) -> None:
        super().__init__(
            f"native search operation {operation!r} exceeded {seconds:.1f}s"
        )
        self.operation = operation
        self.seconds = seconds

    def __reduce__(self) -> tuple[type[NativeRequestTimeout], tuple[str, float]]:
        return type(self), (self.operation, self.seconds)


def _lineage_digest(*parts: bytes) -> bytes:
    digest = hashlib.blake2b(digest_size=16)
    for part in parts:
        digest.update(len(part).to_bytes(4, "little"))
        digest.update(part)
    return digest.digest()


def _root_lineage(command: str) -> bytes:
    return _lineage_digest(b"root", command.encode("ascii"))


def _search_lineage(parent: bytes, player: int, enemy: int, seed: int) -> bytes:
    return _lineage_digest(b"search", parent, struct.pack("<QQQ", player, enemy, seed))


def _episode_lineage(parent: bytes, player: int, enemy: int) -> bytes:
    return _lineage_digest(b"episode", parent, struct.pack("<QQ", player, enemy))


def _decode_features(response: dict[str, Any], side: str) -> NDArray[np.integer[Any]]:
    values = response[f"{side}_features"]
    encoding = response.get("feature_encoding", "json-nat-array")
    if encoding == "json-nat-array":
        result = np.asarray(values, dtype=np.int64)
    else:
        if encoding != "u16le-base64" or not isinstance(values, str):
            raise ValueError(f"unsupported native feature encoding: {encoding!r}")
        packed = base64.b64decode(values, validate=True)
        if len(packed) % 2:
            raise ValueError("packed native features have odd byte length")
        result = np.frombuffer(packed, dtype="<u2")
    if result.ndim != 1:
        raise ValueError("native features must be a one-dimensional array")
    result.flags.writeable = False
    return result


@dataclass(frozen=True)
class Snapshot:
    handle: int
    player_features: NDArray[np.integer[Any]]
    enemy_features: NDArray[np.integer[Any]]
    player_mask: int
    enemy_mask: int
    player_hash: str
    enemy_hash: str
    turn: int
    terminal: bool
    done: bool
    terminal_return: int | None
    request: str
    divergence: str | None
    player_popular: bool = False
    enemy_popular: bool = False

    def with_handle(self, handle: int) -> Snapshot:
        return Snapshot(
            handle=handle,
            player_features=self.player_features,
            enemy_features=self.enemy_features,
            player_mask=self.player_mask,
            enemy_mask=self.enemy_mask,
            player_hash=self.player_hash,
            enemy_hash=self.enemy_hash,
            turn=self.turn,
            terminal=self.terminal,
            done=self.done,
            terminal_return=self.terminal_return,
            request=self.request,
            divergence=self.divergence,
            player_popular=self.player_popular,
            enemy_popular=self.enemy_popular,
        )

    @classmethod
    def from_response(cls, response: dict[str, Any]) -> Snapshot:
        return cls(
            handle=response["handle"],
            player_features=_decode_features(response, "player"),
            enemy_features=_decode_features(response, "enemy"),
            player_mask=response["player_mask"],
            enemy_mask=response["enemy_mask"],
            player_hash=response["player_hash"],
            enemy_hash=response["enemy_hash"],
            turn=response["turn"],
            terminal=response["terminal"],
            done=response["done"],
            terminal_return=response["return"],
            request=response["request"],
            divergence=response.get("divergence"),
            player_popular=bool(response.get("player_popular", False)),
            enemy_popular=bool(response.get("enemy_popular", False)),
        )


def build_search_server() -> None:
    result = subprocess.run(
        ["lake", "-d", str(LEAN_PACKAGE), "build", "battleSearchServer"],
        cwd=REPO_ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode:
        raise RuntimeError(
            f"search server build failed\n{result.stdout}\n{result.stderr}"
        )
    if not SEARCH_SERVER.is_file():
        raise RuntimeError(f"search server missing after build: {SEARCH_SERVER}")


def _require_popular_gate_support(popular_gate: int, hello: dict[str, Any]) -> None:
    """Reject stale binaries that would silently ignore a non-legacy gate.

    Old servers never read the optional gate token, so without this check a
    raised gate degrades to the legacy 26/256 share with no error anywhere.
    """
    if popular_gate != 26 and hello.get("popular_gate") != "parametrized-v1":
        raise ValueError(
            "the Lean search server predates popular_gate parametrization; "
            "rebuild battleSearchServer before changing the gate from 26"
        )


class SearchServer:
    """Owns one Lean process and addresses immutable states by integer handle."""

    def __init__(
        self,
        request_timeout: float = 60.0,
        popular_gate: int = 26,
        transport_backend: str = "python",
    ) -> None:
        if request_timeout <= 0:
            raise ValueError("request_timeout must be positive")
        if not 0 <= popular_gate <= 256:
            raise ValueError("popular_gate must be in [0, 256]")
        if transport_backend not in {"python", "rust"}:
            raise ValueError("transport_backend must be python or rust")
        if transport_backend == "rust":
            from .simulator_transport import library

            library()  # Reject stale deployments before starting a child.
        self.transport_backend = transport_backend
        self.request_timeout = request_timeout
        self.popular_gate = popular_gate
        # Deterministic engine: states with equal construction lineage are
        # identical, so duplicate search rows inside one decision (mirrored
        # evaluation legs) can share a single native transition.
        self._lineage: dict[int, bytes] = {}
        self._dedup_window: dict[bytes, Snapshot] = {}
        self.search_rows_requested = 0
        self.search_rows_deduplicated = 0
        self.process = subprocess.Popen(
            [str(SEARCH_SERVER)],
            cwd=REPO_ROOT,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        self._request_id = 0
        self._request_lock = threading.Lock()
        try:
            hello = self._request("ping")
            if (
                hello["profile"] != FULL_PROFILE
                or hello["schema"] != FULL_SCHEMA
                or hello["chance"] != "fresh-root-v1"
                or hello["action_count"] != FULL_ACTION_COUNT
                or hello["party_size"] != FULL_PARTY_SIZE
                or hello["campaign_count"] != FULL_CAMPAIGN_COUNT
            ):
                raise ValueError(f"native search protocol mismatch: {hello}")
            _require_popular_gate_support(popular_gate, hello)
            self.feature_count = int(hello["feature_count"])
            self.action_count = int(hello["action_count"])
            self.campaign_count = int(hello["campaign_count"])
        except BaseException:
            # Keep the initialization failure if a malformed shutdown response
            # also fails; close() still reaps and releases its streams.
            with suppress(Exception):
                self.close()
            raise

    def _request(self, command: str) -> dict[str, Any]:
        with self._request_lock:
            return self._request_unlocked(command)

    def _request_unlocked(self, command: str) -> dict[str, Any]:
        if self.process.stdin is None or self.process.stdout is None:
            raise RuntimeError("search server pipes are unavailable")
        self._request_id += 1
        request = str(self._request_id)
        operation, *arguments = command.split("|")
        wire = "|".join((operation, request, *arguments))
        self.process.stdin.write(wire + "\n")
        self.process.stdin.flush()
        selector = selectors.DefaultSelector()
        selector.register(self.process.stdout, selectors.EVENT_READ)
        try:
            ready = selector.select(self.request_timeout)
        finally:
            selector.close()
        if not ready:
            self.process.kill()
            self.process.wait()
            self._close_streams()
            raise NativeRequestTimeout(operation, self.request_timeout)
        line = self.process.stdout.readline()
        if not line:
            stderr = self.process.stderr.read() if self.process.stderr else ""
            raise RuntimeError(f"search server exited unexpectedly: {stderr}")
        response = json.loads(line)
        if response.get("id") != request:
            raise RuntimeError(f"search response ID mismatch: {response}")
        if not response.get("ok"):
            raise RuntimeError(f"native search operation failed: {response['error']}")
        return response

    def _snapshot(self, response: dict[str, Any]) -> Snapshot:
        snapshot = Snapshot.from_response(response)
        if (
            len(snapshot.player_features) != self.feature_count
            or len(snapshot.enemy_features) != self.feature_count
        ):
            raise ValueError("native search state feature count differs from schema")
        return snapshot

    def reset(
        self,
        root_seed: int,
        episode: int,
        player_size: int = FULL_PARTY_SIZE,
        enemy_size: int = FULL_PARTY_SIZE,
        *,
        level100: bool = False,
        swapped: bool = False,
        balanced_final_species: bool = False,
    ) -> Snapshot:
        return self._reset_pair(
            root_seed,
            episode,
            player_size,
            enemy_size,
            level100=level100,
            swapped=swapped,
            balanced_final_species=balanced_final_species,
            append=False,
        )

    def reset_append(
        self,
        root_seed: int,
        episode: int,
        player_size: int = FULL_PARTY_SIZE,
        enemy_size: int = FULL_PARTY_SIZE,
        *,
        level100: bool = False,
        swapped: bool = False,
        balanced_final_species: bool = False,
    ) -> Snapshot:
        return self._reset_pair(
            root_seed,
            episode,
            player_size,
            enemy_size,
            level100=level100,
            swapped=swapped,
            balanced_final_species=balanced_final_species,
            append=True,
        )

    def _reset_pair(
        self,
        root_seed: int,
        episode: int,
        player_size: int,
        enemy_size: int,
        *,
        level100: bool,
        swapped: bool,
        balanced_final_species: bool,
        append: bool,
    ) -> Snapshot:
        if level100:
            operation = "reset-level100-swapped" if swapped else "reset-level100"
        else:
            operation = "reset-swapped" if swapped else "reset"
        arguments = (
            f"{root_seed}|{episode}|{player_size}|{enemy_size}"
            f"|{int(balanced_final_species)}"
        )
        # The optional gate token rides only on commands where it is meaningful
        # and non-legacy, keeping historical wire strings byte-identical.
        if level100 and balanced_final_species and self.popular_gate != 26:
            arguments = f"{arguments}|{self.popular_gate}"
        return self._reset_snapshot(operation, arguments, append)

    def reset_campaign(
        self,
        root_seed: int,
        episode: int,
        campaign: int,
        *,
        balanced_final_species: bool = False,
    ) -> Snapshot:
        return self._reset_campaign(
            root_seed, episode, campaign, balanced_final_species, append=False
        )

    def reset_campaign_append(
        self,
        root_seed: int,
        episode: int,
        campaign: int,
        *,
        balanced_final_species: bool = False,
    ) -> Snapshot:
        return self._reset_campaign(
            root_seed, episode, campaign, balanced_final_species, append=True
        )

    def _reset_campaign(
        self,
        root_seed: int,
        episode: int,
        campaign: int,
        balanced_final_species: bool,
        *,
        append: bool,
    ) -> Snapshot:
        if not 0 <= campaign < self.campaign_count:
            raise ValueError("campaign team index is out of range")
        return self._reset_snapshot(
            "reset-campaign",
            f"{root_seed}|{episode}|{campaign}|{int(balanced_final_species)}",
            append,
        )

    def _reset_snapshot(self, operation: str, arguments: str, append: bool) -> Snapshot:
        suffix = "-append" if append else ""
        snapshot = self._snapshot(self._request(f"{operation}{suffix}|{arguments}"))
        if not append:
            self._lineage.clear()
        self._dedup_window.clear()
        # Lineage keys on the append-stripped command so the first game of a
        # batch (plain reset) and its mirror leg (reset-append) share a root.
        self._lineage[snapshot.handle] = _root_lineage(f"{operation}|{arguments}")
        return snapshot

    def search_step(
        self, handle: int, player_action: int, enemy_action: int, chance_seed: int
    ) -> Snapshot:
        return self.search_steps([(handle, player_action, enemy_action, chance_seed)])[
            0
        ]

    def search_steps(self, requests: list[tuple[int, int, int, int]]) -> list[Snapshot]:
        if not requests:
            return []
        self.search_rows_requested += len(requests)
        plan: list[int | Snapshot] = []
        lineages: list[bytes | None] = []
        pending: dict[bytes, int] = {}
        unique: list[tuple[int, int, int, int]] = []
        for handle, player, enemy, seed in requests:
            parent = self._lineage.get(handle)
            lineage = (
                None if parent is None else _search_lineage(parent, player, enemy, seed)
            )
            lineages.append(lineage)
            if lineage is not None:
                cached = self._dedup_window.get(lineage)
                if cached is not None:
                    plan.append(cached)
                    continue
                repeated = pending.get(lineage)
                if repeated is not None:
                    plan.append(repeated)
                    continue
                pending[lineage] = len(unique)
            plan.append(len(unique))
            unique.append((handle, player, enemy, seed))
        fresh = self._search_steps_native(unique)
        self.search_rows_deduplicated += len(requests) - len(unique)
        snapshots: list[Snapshot] = []
        for entry, lineage in zip(plan, lineages, strict=True):
            snapshot = entry if isinstance(entry, Snapshot) else fresh[entry]
            if lineage is not None:
                self._lineage[snapshot.handle] = lineage
                self._dedup_window[lineage] = snapshot
            snapshots.append(snapshot)
        return snapshots

    def _search_steps_native(
        self, requests: list[tuple[int, int, int, int]]
    ) -> list[Snapshot]:
        if not requests:
            return []
        if getattr(self, "transport_backend", "python") == "rust":
            return self._rust_batch(requests, episode=False)
        payload = ";".join(
            f"{handle},{player},{enemy},{seed}"
            for handle, player, enemy, seed in requests
        )
        response = self._request(f"batch|{payload}")
        snapshots = [self._snapshot(row) for row in response["snapshots"]]
        if len(snapshots) != len(requests):
            raise RuntimeError("native batch response length mismatch")
        return snapshots

    def _rust_batch(self, requests, *, episode):
        from .simulator_transport import TransportTimeout, batch

        operation = "batch-episode" if episode else "batch"
        with self._request_lock:
            if self.process.stdin is None or self.process.stdout is None:
                raise RuntimeError("search server pipes are unavailable")
            # Administrative requests still use the synchronous Python reader.
            # There is exactly one response per request and no pipelining, so
            # its text buffer has no unread next response when ownership passes.
            self.process.stdin.flush()
            self._request_id += 1
            try:
                return batch(
                    self.process.stdin.fileno(),
                    self.process.stdout.fileno(),
                    self._request_id,
                    episode,
                    requests,
                    self.feature_count,
                    self.request_timeout,
                )
            except TransportTimeout:
                self.process.kill()
                self.process.wait()
                self._close_streams()
                raise NativeRequestTimeout(operation, self.request_timeout) from None
            except RuntimeError:
                # A failed exchange may have consumed only part of a response.
                # Do not reuse a potentially desynchronized stream or block on
                # Python's administrative reader during shutdown.
                if self.process.poll() is None:
                    self.process.kill()
                self.process.wait()
                self._close_streams()
                raise

    def episode_step(
        self, handle: int, player_action: int, enemy_action: int
    ) -> Snapshot:
        return self.episode_steps([(handle, player_action, enemy_action)])[0]

    def episode_steps(self, requests: list[tuple[int, int, int]]) -> list[Snapshot]:
        if not requests:
            return []
        if getattr(self, "transport_backend", "python") == "rust":
            snapshots = self._rust_batch(
                [(handle, player, enemy, 0) for handle, player, enemy in requests],
                episode=True,
            )
        else:
            payload = ";".join(
                f"{handle},{player},{enemy},0" for handle, player, enemy in requests
            )
            response = self._request(f"batch-episode|{payload}")
            snapshots = [self._snapshot(row) for row in response["snapshots"]]
        if len(snapshots) != len(requests):
            raise RuntimeError("native episode batch response length mismatch")
        self._dedup_window.clear()
        for (handle, player, enemy), snapshot in zip(requests, snapshots, strict=True):
            parent = self._lineage.get(handle)
            if parent is not None:
                self._lineage[snapshot.handle] = _episode_lineage(parent, player, enemy)
        return snapshots

    def inspect(self, handle: int) -> dict[str, Any]:
        return self._request(f"inspect|{handle}")

    def inspect_many(self, handles: list[int]) -> list[dict[str, Any]]:
        if not handles:
            return []
        response = self._request(
            "inspect-many|" + ",".join(str(handle) for handle in handles)
        )
        inspections = response["inspections"]
        if [row["handle"] for row in inspections] != handles:
            raise RuntimeError("native inspect-many response ordering mismatch")
        return inspections

    def compact(self, snapshot: Snapshot) -> Snapshot:
        return self.compact_many([snapshot])[0]

    def compact_many(self, snapshots: list[Snapshot]) -> list[Snapshot]:
        if not snapshots:
            raise ValueError("compact_many requires at least one snapshot")
        response = self._request(
            "compact-handles|"
            + ",".join(str(snapshot.handle) for snapshot in snapshots)
        )
        handles = response["handles"]
        if handles != list(range(len(snapshots))):
            raise RuntimeError("native compact-handles response mapping mismatch")
        compacted = [
            snapshot.with_handle(handle)
            for snapshot, handle in zip(snapshots, handles, strict=True)
        ]
        self._lineage = {
            renumbered.handle: self._lineage[original.handle]
            for original, renumbered in zip(snapshots, compacted, strict=True)
            if original.handle in self._lineage
        }
        self._dedup_window.clear()
        return compacted

    def _close_streams(self) -> None:
        """Release pipe objects after reaping, including broken buffered stdin."""
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            if stream is not None and not stream.closed:
                with suppress(OSError):
                    stream.close()

    def close(self) -> None:
        try:
            if self.process.poll() is None:
                try:
                    self._request("quit")
                except (BrokenPipeError, RuntimeError):
                    if self.process.poll() is None:
                        self.process.terminate()
        finally:
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
            finally:
                self._close_streams()

    def __enter__(self) -> Self:
        return self

    def __exit__(self, *_: object) -> None:
        self.close()
