#!/usr/bin/env python3
"""Validate the conservative canonical-ROM address/range closure manifest."""

from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS = ROOT / "artifacts" / "pokered"
CLOSURE = ARTIFACTS / "closure-manifest.json"
REACHABILITY = ARTIFACTS / "reachability-manifest.json"
BUILD = ARTIFACTS / "build-manifest.json"
SYMBOLS = ARTIFACTS / "pokered.sym"
MAP = ARTIFACTS / "pokered.map"
ADDRESS_RE = re.compile(r"^([0-9a-fA-F]{2}):([0-9a-fA-F]{4})$")
GRAPH_ADDRESS_RE = re.compile(
    r"^([0-9a-fA-F]{2}):([0-9a-fA-F]{4})(?:@rombank=([0-9a-fA-F]{2}))?$"
)


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


def parse_graph_address(value: str) -> tuple[int, int, int]:
    match = GRAPH_ADDRESS_RE.fullmatch(value)
    if not match:
        raise AssertionError(f"malformed graph address: {value}")
    physical = int(match.group(1), 16)
    address = int(match.group(2), 16)
    selected = int(match.group(3), 16) if match.group(3) else physical
    if address < 0x4000 and physical != 0:
        raise AssertionError(f"fixed-window graph address has nonzero bank: {value}")
    if address >= 0x4000 and address < 0x8000 and selected != physical:
        raise AssertionError(f"switchable graph address bank mismatch: {value}")
    return physical, address, selected


def validate_reachability(build: dict[str, object]) -> dict[str, int]:
    graph = json.loads(REACHABILITY.read_text())
    if graph["rom_sha1"] != build["rom"]["sha1"]:
        raise AssertionError("reachability/build ROM SHA-1 mismatch")
    if graph["rom_sha256"] != build["rom"]["sha256"]:
        raise AssertionError("reachability/build ROM SHA-256 mismatch")
    if graph["symbols_sha256"] != build["symbols"]["sha256"]:
        raise AssertionError("reachability/build symbol hash mismatch")
    if graph["map_sha256"] != build["map"]["sha256"]:
        raise AssertionError("reachability/build map hash mismatch")

    bank_ranges = graph["bank_ranges"]
    if len(bank_ranges) != 64:
        raise AssertionError("reachability must classify all 64 canonical ROM banks")
    for bank, record in enumerate(bank_ranges):
        expected_start = 0 if bank == 0 else 0x4000
        expected_end = 0x4000 if bank == 0 else 0x8000
        if record != {
            "bank": bank,
            "classification": "canonical-rom-byte-range",
            "end_exclusive": expected_end,
            "start": expected_start,
        }:
            raise AssertionError(f"incorrect canonical bank range {bank}")

    range_keys: list[tuple[int, int, int, int]] = []
    for record in graph["reachable_ranges"]:
        selected = int(record["selected_bank"])
        physical = int(record["physical_bank"])
        start = int(record["start"])
        end = int(record["end_exclusive"])
        if not 0 <= selected < 64 or not 0 <= physical < 64:
            raise AssertionError("reachable range bank out of bounds")
        if physical == 0:
            if not 0 <= start < end <= 0x4000:
                raise AssertionError("fixed reachable range out of bounds")
        elif physical != selected or not 0x4000 <= start < end <= 0x8000:
            raise AssertionError("switchable reachable range out of bounds")
        if not re.fullmatch(r"[0-9a-f]{64}", record["bytes_sha256"]):
            raise AssertionError("reachable range missing byte hash")
        range_keys.append((physical, selected, start, end))

    summary_addresses = {record["address"] for record in graph["summaries"]}
    non_rom = {record["address"] for record in graph["non_rom_executable_targets"]}

    def represented(value: str) -> bool:
        if value in summary_addresses or value in non_rom:
            return True
        physical, address, selected = parse_graph_address(value)
        return any(
            bank == physical and live == selected and start <= address < end
            for bank, live, start, end in range_keys
        )

    for root in graph["roots"]:
        if not represented(root):
            raise AssertionError(f"unclassified reachability root: {root}")
    for edge in graph["control_edges"]:
        if not represented(edge["source"]):
            raise AssertionError(f"unclassified control source: {edge['source']}")
        if not represented(edge["target"]):
            raise AssertionError(f"unclassified control target: {edge['target']}")
    for site in graph["indirect_sites"]:
        if site["resolution"] != "conservative-rom-overapproximation":
            raise AssertionError(f"unresolved indirect site: {site['source']}")
        if not represented(site["source"]):
            raise AssertionError(f"unclassified indirect source: {site['source']}")
    counts = graph["counts"]
    if counts["unresolved_edges"] != 0:
        raise AssertionError("reachable graph has unresolved edges")
    if counts["reachable_ranges"] != len(graph["reachable_ranges"]):
        raise AssertionError("reachable range count mismatch")
    if counts["control_edges"] != len(graph["control_edges"]):
        raise AssertionError("control edge count mismatch")
    if counts["indirect_sites"] != len(graph["indirect_sites"]):
        raise AssertionError("indirect-site count mismatch")
    return {key: int(value) for key, value in counts.items()}


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

    graph_counts = validate_reachability(build)
    print(
        "PASS canonical closure: "
        f"cpu_bytes=65536, rom_banks={closure['rom_banks']}, "
        f"sram_banks={closure['external_ram_banks']}, entries={len(closure['entry_symbols'])}, "
        f"decoded_instructions={graph_counts['instruction_starts']}, "
        f"control_edges={graph_counts['control_edges']}, "
        f"unresolved={graph_counts['unresolved_edges']}"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as error:
        print(f"FAIL {error}")
        raise SystemExit(1)
