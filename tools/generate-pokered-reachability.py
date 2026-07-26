#!/usr/bin/env python3
"""Generate/validate an address-based conservative Pokémon Red battle closure.

The ROM is caller supplied and hash checked before decoding.  The retained JSON
contains addresses, edge provenance, and hashes, but never cartridge bytes.
Static direct control flow is decoded from the ROM.  RGBDS farcall/homecall and
predef call-site encodings are recognized from bytes.  Genuinely dynamic jumps
are closed conservatively over every retained ROM section and remain visibly
labelled `conservative-rom-overapproximation` rather than guessed away.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from collections import deque
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS = ROOT / "artifacts" / "pokered"
BUILD = ARTIFACTS / "build-manifest.json"
SYMBOLS = ARTIFACTS / "pokered.sym"
MAP = ARTIFACTS / "pokered.map"
OUTPUT = ARTIFACTS / "reachability-manifest.json"

SYM_RE = re.compile(r"^([0-9a-fA-F]{2}):([0-9a-fA-F]{4}) (\S+)$")
BANK_RE = re.compile(r"^ROM(?:0|X) bank #(\d+):$")
SECTION_RE = re.compile(
    r'^\s*SECTION: \$([0-9a-fA-F]{4})(?:-\$([0-9a-fA-F]{4}))? '
    r'\(\$([0-9a-fA-F]+) bytes?\) \["([^"]+)"\]$'
)

ROOT_NAMES = [
    "InitBattle", "InitOpponent", "_InitBattleCommon", "StartBattle",
    "MainInBattleLoop", "EndOfBattle", "VBlank",
]
INTERRUPT_VECTORS = [0x40, 0x48, 0x50, 0x58, 0x60]
DYNAMIC_BANKED_CALLS = {
    # VBlank selects wAudioROMBank, then branches to one of these known banks.
    0x2080: 0x02,
    0x2089: 0x08,
    0x208C: 0x08,
    0x2091: 0x1F,
    # PlaySound dispatches through wAudioROMBank after exact bank comparisons.
    0x23F8: 0x02,
    0x2402: 0x08,
    0x2408: 0x1F,
}

SUMMARY_NAMES = {
    "Bankswitch": "mbc-aware-far-call",
    "Predef": "predef-table-dispatch",
    "PrintText": "presentation-contract-required",
    "PrintPredefTextID": "text-predef-table-dispatch",
}


def digest(path: Path, algorithm: str = "sha256") -> str:
    value = hashlib.new(algorithm)
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def offset(bank: int, address: int) -> int:
    return address if address < 0x4000 else bank * 0x4000 + address - 0x4000


def target_bank(current: int, address: int) -> int:
    return 0 if address < 0x4000 else current


def signed(byte: int) -> int:
    return byte - 256 if byte >= 128 else byte


def instruction_length(opcode: int) -> int:
    x, y, z = opcode >> 6, (opcode >> 3) & 7, opcode & 7
    if x == 0:
        if z == 0:
            return 3 if y == 1 else 2 if y >= 2 else 1
        if z == 1:
            return 3 if y % 2 == 0 else 1
        if z == 6:
            return 2
        return 1
    if x in (1, 2):
        return 1
    if z == 0:
        return 2 if y >= 4 else 1
    if z == 2:
        return 3 if y <= 3 or y in (5, 7) else 1
    if z == 3:
        return 3 if y == 0 else 2 if y == 1 else 1
    if z == 4:
        return 3 if y <= 3 else 1
    if z == 5:
        return 3 if y == 1 else 1
    if z == 6:
        return 2
    return 1


@dataclass(frozen=True, order=True)
class Address:
    # Live selected ROM bank. Fixed-window execution retains this hidden state.
    bank: int
    address: int

    @property
    def physical_bank(self) -> int:
        return 0 if self.address < 0x4000 else self.bank

    def text(self) -> str:
        physical = f"{self.physical_bank:02x}:{self.address:04x}"
        return f"{physical}@rombank={self.bank:02x}" if self.address < 0x4000 else physical


def load_symbols() -> tuple[dict[str, Address], dict[Address, list[str]]]:
    by_name: dict[str, Address] = {}
    by_address: dict[Address, list[str]] = {}
    for line in SYMBOLS.read_text().splitlines()[1:]:
        match = SYM_RE.fullmatch(line)
        if not match:
            continue
        location = Address(int(match.group(1), 16), int(match.group(2), 16))
        name = match.group(3)
        by_name[name] = location
        by_address.setdefault(location, []).append(name)
    return by_name, by_address


def load_sections() -> list[dict[str, object]]:
    result: list[dict[str, object]] = []
    bank: int | None = None
    for line in MAP.read_text().splitlines():
        bank_match = BANK_RE.fullmatch(line)
        if bank_match:
            bank = int(bank_match.group(1))
            continue
        section_match = SECTION_RE.fullmatch(line)
        if not section_match or bank is None:
            continue
        start = int(section_match.group(1), 16)
        explicit_end = section_match.group(2)
        size = int(section_match.group(3), 16)
        end = int(explicit_end, 16) + 1 if explicit_end else start + size
        if size == 0:
            continue
        if end - start != size:
            raise AssertionError(f"map section size mismatch: {line}")
        result.append({
            "bank": bank,
            "start": start,
            "end_exclusive": end,
            "name": section_match.group(4),
        })
    return result


def u16(rom: bytes, bank: int, address: int) -> int:
    base = offset(bank, address)
    return rom[base + 1] | rom[base + 2] << 8


def macro_target(rom: bytes, bank: int, pc: int, control_target: int) -> tuple[str, Address] | None:
    """Recognize exact emitted farcall/farjp/predef/homecall prefixes."""
    base = offset(bank, pc)
    # farcall: ld b,n; ld hl,nn; call/jp Bankswitch
    if pc >= 5 and rom[base - 5] == 0x06 and rom[base - 3] == 0x21:
        return "far-call", Address(rom[base - 4], rom[base - 2] | rom[base - 1] << 8)
    # callfar: ld hl,nn; ld b,n; call/jp Bankswitch
    if pc >= 5 and rom[base - 5] == 0x21 and rom[base - 2] == 0x06:
        return "far-call", Address(rom[base - 1], rom[base - 4] | rom[base - 3] << 8)
    # predef: ld a,id; call/jp Predef. The table is bank + little-endian pointer.
    if pc >= 2 and rom[base - 2] == 0x3E:
        return "predef", Address(-1, rom[base - 1])
    # A direct call into the switchable window immediately after
    # `ld a,bank; ldh [hLoadedROMBank],a; ld [rROMB],a`.
    if control_target >= 0x4000 and pc >= 7:
        prefix = rom[base - 7:base]
        if prefix[0] == 0x3E and prefix[2] == 0xE0 and prefix[4:] == bytes([0xEA, 0x00, 0x20]):
            return "home-call", Address(prefix[1], control_target)
    return None


def predef_target(rom: bytes, symbols: dict[str, Address], predef_id: int) -> Address | None:
    table = symbols.get("PredefPointers")
    if table is None:
        return None
    location = offset(table.bank, table.address) + predef_id * 3
    if location + 3 > len(rom):
        return None
    return Address(rom[location], rom[location + 1] | rom[location + 2] << 8)


def generate(rom_path: Path) -> dict[str, object]:
    build = json.loads(BUILD.read_text())
    if rom_path.stat().st_size != int(build["rom"]["size"]):
        raise AssertionError("ROM size mismatch")
    if digest(rom_path) != build["rom"]["sha256"]:
        raise AssertionError("ROM SHA-256 mismatch")
    if digest(rom_path, "sha1") != build["rom"]["sha1"]:
        raise AssertionError("ROM SHA-1 mismatch")

    rom = rom_path.read_bytes()
    symbols, labels = load_symbols()
    sections = load_sections()
    roots = [
        Address(0x0F, symbols[name].address) if symbols[name].address < 0x4000
        else symbols[name]
        for name in ROOT_NAMES
    ]
    roots.extend(Address(0x0F, vector) for vector in INTERRUPT_VECTORS)
    summary_addresses = {symbols[name]: disposition for name, disposition in SUMMARY_NAMES.items()}
    bankswitch = symbols["Bankswitch"].address
    predef = symbols["Predef"].address

    queue: deque[Address] = deque(roots)
    visited: set[Address] = set()
    instructions: dict[Address, dict[str, object]] = {}
    edges: set[tuple[str, str, str, str]] = set()
    indirect_sites: list[dict[str, object]] = []
    non_rom_targets: dict[Address, str] = {}
    predecessor: dict[Address, tuple[Address, str]] = {}

    def path_to(address: Address) -> str:
        steps: list[tuple[Address, str, Address]] = []
        while address in predecessor and len(steps) < 20000:
            child = address
            address, kind = predecessor[address]
            steps.append((address, kind, child))
        ordered = list(reversed(steps))
        transitions = [
            f"{parent.text()} -{kind}-> {child.text()}"
            for parent, kind, child in ordered if parent.bank != child.bank
        ]
        transition_index = next((index for index, (parent, _, child) in enumerate(ordered)
            if parent.bank != child.bank and child.bank == 7), max(0, len(ordered) - 30))
        tail = ordered[transition_index:transition_index + 120]
        rendered_tail = " ".join(
            f"{parent.text()} -{kind}-> {child.text()}" for parent, kind, child in tail
        )
        return "bank transitions: " + " | ".join(transitions) + "; source suffix: " + rendered_tail

    def resolve_direct(source: Address, absolute: int) -> Address | None:
        if absolute < 0x4000 or source.address >= 0x4000:
            return Address(source.bank, absolute)
        candidates = sorted({location.bank for location in labels
            if location.address == absolute and location.bank != 0})
        if source.bank in candidates:
            return Address(source.bank, absolute)
        if len(candidates) == 1:
            return Address(candidates[0], absolute)
        return None

    def enqueue(source: Address, target: Address, kind: str, resolution: str = "decoded") -> None:
        if not (0 <= target.bank < 64 and 0 <= target.address <= 0xFFFF):
            raise AssertionError(f"invalid target {target} from {source.text()} ({kind})")
        if target.address >= 0x8000:
            if 0xC000 <= target.address < 0xFE00:
                region = "wram-or-echo-executable"
            elif 0xFF80 <= target.address < 0xFFFF:
                region = "hram-executable"
            else:
                raise AssertionError(
                    f"non-fetchable target {target} from {source.text()} ({kind}); "
                    f"path: {path_to(source)}"
                )
            edges.add((source.text(), target.text(), kind, region))
            non_rom_targets[target] = region
            return
        edges.add((source.text(), target.text(), kind, resolution))
        if target not in visited:
            predecessor.setdefault(target, (source, kind))
            queue.append(target)
        if target.bank != source.bank:
            for vector in INTERRUPT_VECTORS:
                interrupt = Address(target.bank, vector)
                if interrupt not in visited:
                    queue.append(interrupt)

    while queue:
        current = queue.popleft()
        if current in visited:
            continue
        if not (0 <= current.bank < 64 and 0 <= current.address < 0x8000):
            continue
        visited.add(current)
        physical_key = Address(current.physical_bank, current.address)
        matched_summary = next((disposition for location, disposition in summary_addresses.items()
            if location.address == current.address and
              (current.address < 0x4000 or location.bank == current.bank)), None)
        if matched_summary is not None:
            instructions[current] = {
                "opcode": None,
                "length": 0,
                "labels": sorted(labels.get(physical_key, [])),
                "summary": matched_summary,
            }
            continue
        physical = offset(current.bank, current.address)
        if physical >= len(rom):
            raise AssertionError(f"instruction outside ROM: {current.text()}")
        opcode = rom[physical]
        length = instruction_length(opcode)
        if physical + length > len(rom):
            raise AssertionError(f"truncated instruction: {current.text()}")
        raw = rom[physical:physical + length]
        instructions[current] = {
            "opcode": opcode,
            "length": length,
            "bytes_sha256": hashlib.sha256(raw).hexdigest(),
            "labels": sorted(labels.get(physical_key, [])),
        }
        fall_address = (current.address + length) & 0xFFFF
        fall = Address(current.bank, fall_address)

        # JR / JR cc
        if opcode == 0x18 or opcode in (0x20, 0x28, 0x30, 0x38):
            target = Address(current.bank, (fall_address + signed(raw[1])) & 0xFFFF)
            enqueue(current, target, "relative-jump")
            if opcode != 0x18:
                enqueue(current, fall, "conditional-fallthrough")
            continue
        # JP / JP cc
        if opcode == 0xC3 or opcode in (0xC2, 0xCA, 0xD2, 0xDA):
            absolute = raw[1] | raw[2] << 8
            special = macro_target(rom, current.bank, current.address, absolute)
            if absolute == bankswitch and special and special[0] == "far-call":
                enqueue(current, special[1], "far-jump", "rgbds-farjp-encoding")
            elif absolute == predef and special and special[0] == "predef":
                target = predef_target(rom, symbols, special[1].address)
                if target is None:
                    raise AssertionError(f"invalid predef at {current.text()}")
                enqueue(current, target, "predef-jump", "PredefPointers")
            else:
                target = resolve_direct(current, absolute)
                if target is None:
                    indirect_sites.append({
                        "source": current.text(), "kind": "fixed-window-jump",
                        "resolution": "conservative-rom-overapproximation",
                        "target_address": f"{absolute:04x}", "target_domain": "all-rom-banks",
                    })
                else:
                    enqueue(current, target, "absolute-jump", "symbol-bank-disambiguation")
            if opcode != 0xC3:
                enqueue(current, fall, "conditional-fallthrough")
            continue
        # CALL / CALL cc
        if opcode == 0xCD or opcode in (0xC4, 0xCC, 0xD4, 0xDC):
            absolute = raw[1] | raw[2] << 8
            special = macro_target(rom, current.bank, current.address, absolute)
            dynamic_bank = DYNAMIC_BANKED_CALLS.get(current.address) if current.address < 0x4000 else None
            if dynamic_bank is not None:
                enqueue(current, Address(dynamic_bank, absolute), "banked-device-call",
                    "VBlank-audio-bank-dispatch")
            elif absolute == bankswitch and special and special[0] == "far-call":
                enqueue(current, special[1], "far-call", "rgbds-farcall-encoding")
            elif absolute == predef and special and special[0] == "predef":
                target = predef_target(rom, symbols, special[1].address)
                if target is None:
                    raise AssertionError(f"invalid predef at {current.text()}")
                enqueue(current, target, "predef-call", "PredefPointers")
            elif special and special[0] == "home-call":
                enqueue(current, special[1], "home-call", "rgbds-homecall-encoding")
            else:
                target = resolve_direct(current, absolute)
                if target is None:
                    indirect_sites.append({
                        "source": current.text(), "kind": "fixed-window-call",
                        "resolution": "conservative-rom-overapproximation",
                        "target_address": f"{absolute:04x}", "target_domain": "all-rom-banks",
                    })
                else:
                    enqueue(current, target, "call", "symbol-bank-disambiguation")
            enqueue(current, fall, "return-continuation")
            continue
        # JP HL is intentionally an explicit conservative closure site.
        if opcode == 0xE9:
            indirect_sites.append({
                "source": current.text(),
                "kind": "jp-hl",
                "resolution": "conservative-rom-overapproximation",
                "target_domain": "all-retained-rom-sections",
            })
            continue
        # RET/RETI and unconditional invalid lock slots have no local successor.
        if opcode in (0xC9, 0xD9) or opcode in (0xD3, 0xDB, 0xDD, 0xE3, 0xE4, 0xEB, 0xEC, 0xED, 0xF4, 0xFC, 0xFD):
            continue
        # Conditional return has the not-taken successor.
        if opcode in (0xC0, 0xC8, 0xD0, 0xD8):
            enqueue(current, fall, "conditional-return-fallthrough")
            continue
        # RST enters fixed bank and then returns.
        if opcode & 0xC7 == 0xC7:
            enqueue(current, Address(current.bank, opcode & 0x38), "rst")
            enqueue(current, fall, "return-continuation")
            continue
        enqueue(current, fall, "fallthrough")

    section_records: list[dict[str, object]] = []
    decoded_by_section: dict[tuple[int, int, int], int] = {}
    for address in visited:
        for section in sections:
            if section["bank"] == address.physical_bank and section["start"] <= address.address < section["end_exclusive"]:
                key = (address.physical_bank, int(section["start"]), int(section["end_exclusive"]))
                decoded_by_section[key] = decoded_by_section.get(key, 0) + 1
                break
    for section in sections:
        key = (int(section["bank"]), int(section["start"]), int(section["end_exclusive"]))
        decoded = decoded_by_section.get(key, 0)
        record = dict(section)
        record["classification"] = "reachable-code" if decoded else "retained-rom-range"
        record["decoded_instruction_starts"] = decoded
        section_records.append(record)

    # Compact contiguous decoded byte coverage. Fallthrough is represented by
    # range continuity; only control-transfer edges are retained below.
    spans: dict[tuple[int, int], list[tuple[int, int]]] = {}
    summaries: list[dict[str, object]] = []
    for address, instruction in instructions.items():
        length = int(instruction["length"])
        if length == 0:
            summaries.append({"address": address.text(), **instruction})
            continue
        spans.setdefault((address.bank, address.physical_bank), []).append(
            (address.address, address.address + length)
        )
    reachable_ranges: list[dict[str, object]] = []
    for (selected_bank, physical_bank), intervals in sorted(spans.items()):
        merged: list[list[int]] = []
        for start, end in sorted(intervals):
            if merged and start <= merged[-1][1]:
                merged[-1][1] = max(merged[-1][1], end)
            else:
                merged.append([start, end])
        for start, end in merged:
            payload_bytes = rom[offset(physical_bank, start):offset(physical_bank, end)]
            boundary_labels = sorted(labels.get(Address(physical_bank, start), []))
            reachable_ranges.append({
                "selected_bank": selected_bank,
                "physical_bank": physical_bank,
                "start": start,
                "end_exclusive": end,
                "entry_symbols": boundary_labels,
                "bytes_sha256": hashlib.sha256(payload_bytes).hexdigest(),
                "classification": "decoded-reachable-code",
            })
    omitted_edge_kinds = {
        "fallthrough", "conditional-fallthrough", "return-continuation",
        "conditional-return-fallthrough",
    }
    edge_records = [
        {"source": source, "target": target, "kind": kind, "resolution": resolution}
        for source, target, kind, resolution in sorted(edges)
        if kind not in omitted_edge_kinds
    ]
    bank_ranges = [
        {
            "bank": bank,
            "start": 0 if bank == 0 else 0x4000,
            "end_exclusive": 0x4000 if bank == 0 else 0x8000,
            "classification": "canonical-rom-byte-range",
        }
        for bank in range(64)
    ]
    payload: dict[str, object] = {
        "schema_version": 1,
        "strategy": "decoded-static-flow-plus-conservative-dynamic-overapproximation",
        "rom_sha1": build["rom"]["sha1"],
        "rom_sha256": build["rom"]["sha256"],
        "symbols_sha256": build["symbols"]["sha256"],
        "map_sha256": build["map"]["sha256"],
        "roots": [root.text() for root in roots],
        "counts": {
            "sections": len(section_records),
            "instruction_starts": len(instructions),
            "reachable_ranges": len(reachable_ranges),
            "control_edges": len(edge_records),
            "all_decoded_edges": len(edges),
            "indirect_sites": len(indirect_sites),
            "unresolved_edges": 0,
        },
        "dynamic_policy": {
            "jp_hl": "all retained ROM sections; sites remain explicit",
            "returns": "typed stack continuation; each decoded call retains its continuation",
            "interrupts": "all five fixed-bank vectors are roots",
            "assets": "every used map section is retained and classified",
        },
        "bank_ranges": bank_ranges,
        "sections": section_records,
        "reachable_ranges": reachable_ranges,
        "summaries": sorted(summaries, key=lambda item: str(item["address"])),
        "control_edges": edge_records,
        "indirect_sites": sorted(indirect_sites, key=lambda item: str(item["source"])),
        "non_rom_executable_targets": [
            {"address": address.text(), "classification": non_rom_targets[address]}
            for address in sorted(non_rom_targets)
        ],
    }
    return payload


def canonical_json(payload: dict[str, object]) -> str:
    return json.dumps(payload, indent=2, sort_keys=True) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rom", required=True, type=Path, help="temporary canonical Red ROM")
    parser.add_argument("--write", action="store_true", help="replace the retained manifest")
    args = parser.parse_args()
    payload = generate(args.rom)
    encoded = canonical_json(payload)
    if args.write:
        OUTPUT.write_text(encoded)
        mode = "wrote"
    else:
        if not OUTPUT.is_file():
            raise AssertionError("missing retained reachability manifest; run with --write")
        if OUTPUT.read_text() != encoded:
            raise AssertionError("reachability manifest differs from canonical ROM decode")
        mode = "validated"
    counts = payload["counts"]
    assert isinstance(counts, dict)
    print(
        f"PASS {mode} battle reachability: sections={counts['sections']}, "
        f"instructions={counts['instruction_starts']}, edges={counts['control_edges']}, "
        f"indirect={counts['indirect_sites']}, unresolved={counts['unresolved_edges']}"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as error:
        print(f"FAIL {error}")
        raise SystemExit(1)
