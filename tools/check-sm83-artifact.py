#!/usr/bin/env python3
"""Verify the immutable source identity of the standalone sm83-lean candidate."""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "packages" / "sm83-lean"
MANIFEST = ROOT / "artifacts" / "sm83-lean" / "candidate-manifest.json"


def source_files() -> list[Path]:
    return sorted(
        path
        for path in PACKAGE.rglob("*")
        if path.is_file() and ".lake" not in path.parts
    )


def tree_digest(files: list[Path]) -> str:
    digest = hashlib.sha256()
    for path in files:
        relative = path.relative_to(PACKAGE).as_posix().encode()
        digest.update(relative)
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def fail(message: str) -> None:
    print(f"FAIL {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> int:
    manifest = json.loads(MANIFEST.read_text())
    files = source_files()
    actual_paths = [path.relative_to(PACKAGE).as_posix() for path in files]
    expected = manifest["files"]
    expected_paths = sorted(expected)
    if set(actual_paths) != set(expected_paths):
        missing = sorted(set(expected_paths) - set(actual_paths))
        extra = sorted(set(actual_paths) - set(expected_paths))
        fail(f"source set differs: missing={missing}, extra={extra}")

    for path in files:
        relative = path.relative_to(PACKAGE).as_posix()
        actual = hashlib.sha256(path.read_bytes()).hexdigest()
        if actual != expected[relative]:
            fail(f"{relative}: sha256={actual}, expected={expected[relative]}")

    actual_tree = tree_digest(files)
    if actual_tree != manifest["tree_sha256"]:
        fail(f"tree sha256={actual_tree}, expected={manifest['tree_sha256']}")
    if (PACKAGE / "lean-toolchain").read_text().strip() != manifest["lean_toolchain"]:
        fail("Lean toolchain differs from candidate manifest")
    if manifest["status"] != "clean-room-candidate-specification":
        fail("manifest status must remain candidate specification")

    print(
        "PASS immutable sm83-lean candidate: "
        f"version={manifest['version']}, files={len(files)}, tree_sha256={actual_tree}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
