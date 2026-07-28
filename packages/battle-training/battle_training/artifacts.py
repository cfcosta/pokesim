"""Immutable artifact writes and SHA-256 manifests."""

from __future__ import annotations

import hashlib
import json
import os
import tempfile
from pathlib import Path
from typing import Any


def canonical_json(value: Any) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()


def write_new(path: Path, data: bytes) -> None:
    """Publish immutable bytes atomically, leaving no partial final artifact."""
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        raise FileExistsError(path)
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
        try:
            os.link(temporary_name, path)
        except FileExistsError as error:
            raise FileExistsError(path) from error
    finally:
        if temporary_name is not None:
            Path(temporary_name).unlink(missing_ok=True)


def write_json(path: Path, value: Any) -> None:
    write_new(path, canonical_json(value))


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def build_manifest(root: Path) -> dict[str, Any]:
    files = []
    for path in sorted(root.rglob("*")):
        if path.is_file() and path.name != "manifest.json":
            files.append(
                {
                    "path": path.relative_to(root).as_posix(),
                    "bytes": path.stat().st_size,
                    "sha256": sha256(path),
                }
            )
    return {"algorithm": "sha256", "files": files}


def verify_manifest(root: Path) -> list[str]:
    manifest = json.loads((root / "manifest.json").read_text())
    errors: list[str] = []
    expected_paths = {entry["path"] for entry in manifest["files"]}
    actual_paths = {
        path.relative_to(root).as_posix()
        for path in root.rglob("*")
        if path.is_file() and path.name != "manifest.json"
    }
    if actual_paths != expected_paths:
        errors.append(
            f"manifest paths differ: missing={sorted(expected_paths - actual_paths)} "
            f"extra={sorted(actual_paths - expected_paths)}"
        )
    for entry in manifest["files"]:
        path = root / entry["path"]
        if not path.is_file():
            continue
        if path.stat().st_size != entry["bytes"]:
            errors.append(f"size mismatch: {entry['path']}")
        if sha256(path) != entry["sha256"]:
            errors.append(f"sha256 mismatch: {entry['path']}")
    return errors
