#!/usr/bin/env python3
"""Verify that the nested pokered import remains byte-for-byte pristine."""

from __future__ import annotations

import hashlib
import stat
import sys
from pathlib import Path

EXPECTED_COMMIT = "405b6246372d7e5a2cb029cbb65219b13286b8c9"
EXPECTED_FILES = 2874
EXPECTED_MANIFEST_SHA256 = "f5890088a5806da5b8517addfa8de4aa8626c9483ae6dbbbb7637cf647cef1c9"


def main() -> int:
    root = Path(__file__).resolve().parents[1] / "pokered"
    files = sorted(path for path in root.rglob("*") if path.is_file())
    digest = hashlib.sha256()
    for path in files:
        relative = path.relative_to(root).as_posix()
        executable = "x" if path.stat().st_mode & stat.S_IXUSR else "-"
        digest.update(relative.encode("utf-8") + b"\0")
        digest.update(executable.encode("ascii") + b"\0")
        digest.update(hashlib.sha256(path.read_bytes()).digest())

    actual = digest.hexdigest()
    if len(files) != EXPECTED_FILES or actual != EXPECTED_MANIFEST_SHA256:
        print(
            f"FAIL pokered import drift: files={len(files)} manifest={actual}",
            file=sys.stderr,
        )
        return 1
    print(
        f"PASS pokered commit={EXPECTED_COMMIT}, files={EXPECTED_FILES}, "
        f"manifest_sha256={actual}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
