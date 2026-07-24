#!/usr/bin/env python3
"""Stream pinned SingleStep fixtures through the Lean functional runner."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

EXPECTED_COMMIT = "f9c30210245dd691661db39f5ace022c465ecc2f"
EXPECTED_FILES = 500
EXPECTED_CASES = 498_000
QUARANTINED = {"10.json", "76.json"}  # STOP and HALT need system context.


def git_head(root: Path) -> str:
    return subprocess.check_output(
        ["git", "-C", str(root), "rev-parse", "HEAD"], text=True
    ).strip()


def encode_case(case: dict) -> str:
    initial = case["initial"]
    final = case["final"]
    values = [
        initial[key]
        for key in ("pc", "sp", "a", "b", "c", "d", "e", "f", "h", "l", "ime")
    ]
    values += [len(initial["ram"]), *(n for pair in initial["ram"] for n in pair)]
    values += [
        final[key]
        for key in ("a", "b", "c", "d", "e", "f", "h", "l", "pc", "sp", "ime")
    ]
    values += [len(final["ram"]), *(n for pair in final["ram"] for n in pair)]
    active: list[int] = []
    for address, value, kind in case["cycles"]:
        if kind in ("r-m", "-wm"):
            active += [0 if kind == "r-m" else 1, address, value]
    values += [len(active) // 3, *active]
    return " ".join(map(str, values)) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("corpus", type=Path)
    parser.add_argument(
        "--runner",
        type=Path,
        default=Path("packages/sm83-lean/.lake/build/bin/sm83-conformance"),
    )
    args = parser.parse_args()

    if git_head(args.corpus) != EXPECTED_COMMIT:
        raise SystemExit("SingleStep checkout does not match pinned commit")
    files = sorted((args.corpus / "v1").glob("*.json"))
    if len(files) != EXPECTED_FILES:
        raise SystemExit(f"expected {EXPECTED_FILES} fixture files, found {len(files)}")
    if not args.runner.is_file():
        raise SystemExit(f"missing Lean runner: {args.runner}; build sm83-lean first")

    process = subprocess.Popen([str(args.runner)], stdin=subprocess.PIPE, text=True)
    assert process.stdin is not None
    count = 0
    try:
        for path in files:
            if path.name in QUARANTINED:
                continue
            with path.open(encoding="utf-8") as source:
                cases = json.load(source)
            for case in cases:
                process.stdin.write(encode_case(case))
                count += 1
    except BrokenPipeError:
        pass
    finally:
        try:
            process.stdin.close()
        except BrokenPipeError:
            pass

    status = process.wait()
    if count != EXPECTED_CASES:
        raise SystemExit(f"expected {EXPECTED_CASES} streamed cases, found {count}")
    if status:
        return status
    print(f"PASS SingleStep commit={EXPECTED_COMMIT}, cases={count}")
    print("NOTE HALT and STOP are quarantined from context-free completion vectors")
    return 0


if __name__ == "__main__":
    sys.exit(main())
