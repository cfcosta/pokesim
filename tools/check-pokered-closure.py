#!/usr/bin/env python3
"""Validate the conservative canonical-ROM address/range closure manifest."""

from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS = ROOT / "artifacts" / "pokered"
CLOSURE = ARTIFACTS / "closure-manifest.json"
BUILD = ARTIFACTS / "build-manifest.json"
SYMBOLS = ARTIFACTS / "pokered.sym"
MAP = ARTIFACTS / "pokered.map"
ADDRESS_RE = re.compile(r"^([0-9a-fA-F]{2}):([0-9a-fA-F]{4})$")


def load_symbols() -> dict[str, str]:
    result: dict[str, str] = {}
    for number, line in enumerate(SYMBOLS.read_text().splitlines()[1:], 2):
        location, separator, symbol = line.partition(" ")
        if not separator:
            raise AssertionError(f"malformed symbol line {number}")
        if ":" in location:
            if not ADDRESS_RE.fullmatch(location):
                raise AssertionError(f"malformed address at symbol line {number}")
            result[symbol] = location.lower()
    return result


def main() -> int:
    closure = json.loads(CLOSURE.read_text())
    build = json.loads(BUILD.read_text())
    if closure["rom_sha1"] != build["rom"]["sha1"]:
        raise AssertionError("closure/build ROM SHA-1 mismatch")
    if closure["rom_sha256"] != build["rom"]["sha256"]:
        raise AssertionError("closure/build ROM SHA-256 mismatch")
    if closure["rom_banks"] * closure["rom_bank_size"] != build["rom"]["size"]:
        raise AssertionError("ROM bank closure does not cover the canonical image")

    cursor = 0
    kinds: set[str] = set()
    for region in closure["cpu_ranges"]:
        start = int(region["start"], 16)
        end = int(region["end_exclusive"], 16)
        if start != cursor:
            raise AssertionError(f"CPU closure gap/overlap before {start:04x}")
        if not start < end <= 0x10000:
            raise AssertionError(f"invalid CPU range {start:04x}-{end:05x}")
        cursor = end
        kinds.add(region["kind"])
    if cursor != 0x10000:
        raise AssertionError(f"CPU closure ends at {cursor:05x}, expected 10000")
    if len(kinds) != len(closure["cpu_ranges"]):
        raise AssertionError("CPU range kinds must be unique")

    symbols = load_symbols()
    for symbol, expected in closure["entry_symbols"].items():
        actual = symbols.get(symbol)
        if actual != expected:
            raise AssertionError(f"{symbol}: {actual}, expected {expected}")

    map_text = MAP.read_text()
    required_summary = [
        "ROM0: 16228 bytes used / 156 free",
        "ROMX: 559197 bytes used / 161699 free in 44 banks",
        "SRAM: 25122 bytes used / 7646 free in 4 banks",
        "WRAM0: 8162 bytes used / 30 free",
        "HRAM: 127 bytes used / 0 free",
    ]
    for line in required_summary:
        if line not in map_text:
            raise AssertionError(f"missing map summary: {line}")

    print(
        "PASS canonical closure: "
        f"cpu_bytes=65536, rom_banks={closure['rom_banks']}, "
        f"sram_banks={closure['external_ram_banks']}, entries={len(closure['entry_symbols'])}"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as error:
        print(f"FAIL {error}")
        raise SystemExit(1)
