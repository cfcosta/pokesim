#!/usr/bin/env python3
"""Check Lean DAA against all pinned Mooneye A/ZNHC rows."""

from __future__ import annotations

import argparse
import hashlib
import re
import subprocess
import sys
from pathlib import Path

EXPECTED_COMMIT = "31510e12eea6286d36eea060a6adde755e1067aa"
EXPECTED_SHA256 = "37341fe47cd19b36a2b8f0b041dd6213dc1d7952fc89f70399bc59112426508a"
ROW = re.compile(r"^\.db \$([0-9a-f]{2}), %([01]{4}), \$([0-9a-f]{2}), %([01]{4})$", re.I)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("mooneye", type=Path)
    parser.add_argument(
        "--runner",
        type=Path,
        default=Path("packages/sm83-lean/.lake/build/bin/sm83-daa-conformance"),
    )
    args = parser.parse_args()

    commit = subprocess.check_output(
        ["git", "-C", str(args.mooneye), "rev-parse", "HEAD"], text=True
    ).strip()
    if commit != EXPECTED_COMMIT:
        raise SystemExit("Mooneye checkout does not match pinned commit")
    source = args.mooneye / "acceptance" / "instr" / "daa.s"
    if hashlib.sha256(source.read_bytes()).hexdigest() != EXPECTED_SHA256:
        raise SystemExit("Mooneye DAA source hash mismatch")

    rows = []
    for line in source.read_text(encoding="utf-8").splitlines():
        if match := ROW.fullmatch(line.strip()):
            rows.append(tuple(int(value, base) for value, base in zip(match.groups(), (16, 2, 16, 2))))
    expected_inputs = [(a, flags) for a in range(256) for flags in range(16)]
    if len(rows) != 4096 or [(a, flags) for a, flags, _, _ in rows] != expected_inputs:
        raise SystemExit("Mooneye DAA table is incomplete or reordered")
    if not args.runner.is_file():
        raise SystemExit(f"missing Lean runner: {args.runner}; build sm83-lean first")

    payload = "".join(f"{a} {flags} {result} {out_flags}\n" for a, flags, result, out_flags in rows)
    completed = subprocess.run([str(args.runner)], input=payload, text=True, check=False)
    if completed.returncode:
        return completed.returncode
    print(f"PASS Mooneye commit={EXPECTED_COMMIT}, daa_rows={len(rows)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
