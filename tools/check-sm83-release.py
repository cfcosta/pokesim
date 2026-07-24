#!/usr/bin/env python3
"""Fail-closed static release checks for the public sm83-lean package."""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "packages" / "sm83-lean"
PUBLIC_ROOT = PACKAGE / "Sm83.lean"
FORBIDDEN = re.compile(r"\b(?:sorry|admit|axiom)\b|#eval")
FORBIDDEN_IMPORTS = ("pokered", "pokemon", "mbc3", "ConformanceMain")
EXPECTED_MODULES = {
    "Alu", "Basic", "Byte", "Catalogue", "Clock", "CoreState", "Cycle",
    "Decode", "Encode", "Flags", "FlatAdapter", "FlatMemory", "Functional",
    "HalfEdge", "Hoare", "Instruction", "Interrupt", "Pipeline", "Profile",
    "Program", "Registers", "Relation", "Reset", "Run",
}


def fail(message: str) -> None:
    print(f"FAIL {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> int:
    lean_files = sorted((PACKAGE / "Sm83").rglob("*.lean")) + [PUBLIC_ROOT]
    for path in lean_files:
        text = path.read_text(encoding="utf-8")
        if path.name != "ConformanceMain.lean" and FORBIDDEN.search(text):
            fail(f"forbidden proof escape in {path.relative_to(ROOT)}")
        if path != PUBLIC_ROOT and path.name != "ConformanceMain.lean":
            if "Licensed under the Apache License, Version 2.0" not in text:
                fail(f"missing license header in {path.relative_to(ROOT)}")

    root_text = PUBLIC_ROOT.read_text(encoding="utf-8")
    lowered = root_text.lower()
    for name in FORBIDDEN_IMPORTS:
        if name.lower() in lowered:
            fail(f"public root imports forbidden dependency {name}")

    present = {path.stem for path in (PACKAGE / "Sm83").glob("*.lean")}
    missing = EXPECTED_MODULES - present
    if missing:
        fail(f"missing public implementation modules: {', '.join(sorted(missing))}")

    lake = (PACKAGE / "lakefile.toml").read_text(encoding="utf-8")
    if "[[require]]" in lake:
        fail("unexpected external Lake dependency")
    if not (PACKAGE / "LICENSE").is_file():
        fail("missing package LICENSE")

    print(f"PASS {len(lean_files)} Lean sources: no sorry/admit/axiom/#eval")
    print("PASS public proof root excludes test parser and system-specific dependencies")
    print("PASS standalone Apache-2.0 package boundary")
    return 0


if __name__ == "__main__":
    sys.exit(main())
