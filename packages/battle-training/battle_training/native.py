"""Persistent client for Lean-owned immutable full-party search states."""

from __future__ import annotations

import json
import subprocess
from dataclasses import dataclass
from typing import Any, Self

from . import FULL_ACTION_COUNT, FULL_PARTY_SIZE, FULL_PROFILE, FULL_SCHEMA
from .worker import LEAN_PACKAGE, REPO_ROOT

SEARCH_SERVER = LEAN_PACKAGE / ".lake" / "build" / "bin" / "battleSearchServer"


@dataclass(frozen=True)
class Snapshot:
    handle: int
    player_features: tuple[int, ...]
    enemy_features: tuple[int, ...]
    player_mask: int
    enemy_mask: int
    player_hash: str
    enemy_hash: str
    turn: int
    terminal: bool
    done: bool
    terminal_return: int | None
    request: str

    @classmethod
    def from_response(cls, response: dict[str, Any]) -> Snapshot:
        return cls(
            handle=response["handle"],
            player_features=tuple(response["player_features"]),
            enemy_features=tuple(response["enemy_features"]),
            player_mask=response["player_mask"],
            enemy_mask=response["enemy_mask"],
            player_hash=response["player_hash"],
            enemy_hash=response["enemy_hash"],
            turn=response["turn"],
            terminal=response["terminal"],
            done=response["done"],
            terminal_return=response["return"],
            request=response["request"],
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


class SearchServer:
    """Owns one Lean process and addresses immutable states by integer handle."""

    def __init__(self) -> None:
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
        hello = self._request("ping")
        if (
            hello["profile"] != FULL_PROFILE
            or hello["schema"] != FULL_SCHEMA
            or hello["chance"] != "fresh-root-v1"
            or hello["action_count"] != FULL_ACTION_COUNT
            or hello["party_size"] != FULL_PARTY_SIZE
        ):
            self.close()
            raise ValueError(f"native search protocol mismatch: {hello}")
        self.feature_count = int(hello["feature_count"])
        self.action_count = int(hello["action_count"])

    def _request(self, command: str) -> dict[str, Any]:
        if self.process.stdin is None or self.process.stdout is None:
            raise RuntimeError("search server pipes are unavailable")
        self._request_id += 1
        request = str(self._request_id)
        operation, *arguments = command.split("|")
        wire = "|".join((operation, request, *arguments))
        self.process.stdin.write(wire + "\n")
        self.process.stdin.flush()
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

    def reset(self, root_seed: int, episode: int) -> Snapshot:
        return self._snapshot(self._request(f"reset|{root_seed}|{episode}"))

    def search_step(
        self, handle: int, player_action: int, enemy_action: int, chance_seed: int
    ) -> Snapshot:
        return self._snapshot(
            self._request(
                f"step|{handle}|{player_action}|{enemy_action}|fresh|{chance_seed}"
            )
        )

    def search_steps(self, requests: list[tuple[int, int, int, int]]) -> list[Snapshot]:
        if not requests:
            return []
        payload = ";".join(
            f"{handle},{player},{enemy},{seed}"
            for handle, player, enemy, seed in requests
        )
        response = self._request(f"batch|{payload}")
        snapshots = [self._snapshot(row) for row in response["snapshots"]]
        if len(snapshots) != len(requests):
            raise RuntimeError("native batch response length mismatch")
        return snapshots

    def episode_step(
        self, handle: int, player_action: int, enemy_action: int
    ) -> Snapshot:
        return self._snapshot(
            self._request(f"step|{handle}|{player_action}|{enemy_action}|episode|0")
        )

    def inspect(self, handle: int) -> dict[str, Any]:
        return self._request(f"inspect|{handle}")

    def compact(self, handle: int) -> Snapshot:
        return self._snapshot(self._request(f"compact|{handle}"))

    def close(self) -> None:
        if self.process.poll() is None:
            try:
                self._request("quit")
            except (BrokenPipeError, RuntimeError):
                self.process.terminate()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()

    def __enter__(self) -> Self:
        return self

    def __exit__(self, *_: object) -> None:
        self.close()
