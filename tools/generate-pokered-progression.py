#!/usr/bin/env python3
"""Generate independently authored Lean progression rows from canonical Red.

The ROM must be a caller-supplied temporary rebuild; this tool never vendors it.
"""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path

EXPECTED_SHA256 = "5ca7ba01642a3b27b0cc0b5349b52792795b62d3ed977e98a09390659af96b7b"

# TM01..TM50 followed by HM01..HM05, in the cartridge bitfield order.
TMHM_MOVES = [
    5, 13, 14, 18, 25, 92, 32, 34, 36, 38,
    61, 55, 58, 59, 63, 6, 66, 68, 69, 99,
    72, 76, 82, 85, 87, 89, 90, 91, 94, 100,
    102, 104, 115, 117, 118, 120, 121, 126, 129, 130,
    135, 138, 143, 156, 86, 149, 153, 157, 161, 164,
    15, 19, 57, 70, 148,
]


def offset(bank: int, address: int) -> int:
    return address if bank == 0 else bank * 0x4000 + address - 0x4000


def arr(values: list[int]) -> str:
    return "#[" + ", ".join(str(value) for value in values) + "]"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rom", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    rom = args.rom.read_bytes()
    digest = hashlib.sha256(rom).hexdigest()
    if digest != EXPECTED_SHA256:
        raise SystemExit(f"wrong ROM SHA-256: {digest}")

    base = offset(0x0E, 0x43DE)
    mew = offset(0x01, 0x425B)
    rows = [rom[base + i * 28 : base + (i + 1) * 28] for i in range(150)]
    rows.append(rom[mew : mew + 28])
    assert [row[0] for row in rows] == list(range(1, 152))

    order_at = offset(0x10, 0x5024)
    order = [0] + list(rom[order_at : order_at + 190])
    growth = [0]
    initial: list[list[int]] = [[]]
    tmhm_flags: list[list[int]] = [[]]
    for internal in range(1, 191):
        dex = order[internal]
        if dex == 0:
            growth.append(0)
            initial.append([])
            tmhm_flags.append([])
        else:
            row = rows[dex - 1]
            growth.append(row[19])
            initial.append([move for move in row[15:19] if move])
            tmhm_flags.append(list(row[20:27]))

    pointers_at = offset(0x0E, 0x705C)
    progression: list[tuple[list[tuple[int, ...]], list[tuple[int, int]]]] = [([], [])]
    for internal in range(190):
        lo = rom[pointers_at + internal * 2]
        hi = rom[pointers_at + internal * 2 + 1]
        cursor = offset(0x0E, lo | (hi << 8))
        evolutions: list[tuple[int, ...]] = []
        while rom[cursor] != 0:
            tag = rom[cursor]
            if tag == 1:
                evolutions.append((tag, rom[cursor + 1], rom[cursor + 2]))
                cursor += 3
            elif tag == 2:
                evolutions.append((tag, rom[cursor + 1], rom[cursor + 2], rom[cursor + 3]))
                cursor += 4
            elif tag == 3:
                evolutions.append((tag, rom[cursor + 1], rom[cursor + 2]))
                cursor += 3
            else:
                raise SystemExit(f"bad evolution tag {tag} for internal {internal + 1}")
        cursor += 1
        moves: list[tuple[int, int]] = []
        while rom[cursor] != 0:
            moves.append((rom[cursor], rom[cursor + 1]))
            cursor += 2
        progression.append((evolutions, moves))

    lines = [
        "/-",
        "Copyright 2026 Cainã Costa",
        'Licensed under the Apache License, Version 2.0 (the "License").',
        "-/",
        "import Battle.Types",
        "",
        "/-! Generated from the hash-checked canonical ROM by",
        "`tools/generate-pokered-progression.py`. Index is internal species ID;",
        "entry zero is `NO_MON`. The ROM itself is not vendored. -/",
        "",
        "namespace Battle.Data.Progression",
        "",
        "inductive EvolutionMethod where",
        "  | level (level : UInt8)",
        "  | item (item minimumLevel : UInt8)",
        "  | trade (minimumLevel : UInt8)",
        "  deriving Repr, DecidableEq, BEq",
        "",
        "structure Evolution where",
        "  method : EvolutionMethod",
        "  target : SpeciesId",
        "  deriving Repr, DecidableEq, BEq",
        "",
        "structure LevelMove where",
        "  level : UInt8",
        "  move : MoveId",
        "  deriving Repr, DecidableEq, BEq",
        "",
        "structure Row where",
        "  evolutions : Array Evolution",
        "  levelMoves : Array LevelMove",
        "  deriving Repr, DecidableEq, BEq",
        "",
        "/-- Base-header growth-rate IDs for internal species `$00..$BE`. -/",
        f"def growthRates : Array UInt8 := {arr(growth)}",
        "",
        "/-- Nonblank level-one moves from each base-stat row. -/",
        "def initialMoves : Array (Array MoveId) := #[",
    ]
    for internal, moves in enumerate(initial):
        lines.append(f"  {arr(moves)}, -- ${internal:02X}")
    lines += [
        "]",
        "",
        "/-- `TM01..TM50`, then `HM01..HM05`, in base-stat flag order. -/",
        f"def tmhmMoves : Array MoveId := {arr(TMHM_MOVES)}",
        "",
        "/-- Seven compatibility bytes from every base-stat row, by internal species ID. -/",
        "def tmhmFlags : Array (Array UInt8) := #[",
    ]
    for internal, flags in enumerate(tmhm_flags):
        lines.append(f"  {arr(flags)}, -- ${internal:02X}")
    lines += [
        "]",
        "",
        "/-- Whether an internal species accepts a machine index (`0..49` TM, `50..54` HM). -/",
        "def machineCompatible (species : SpeciesId) (index : Nat) : Bool :=",
        "  if index < tmhmMoves.size then",
        "    let flags := tmhmFlags.getD species.toNat #[]",
        "    (flags.getD (index / 8) 0).toNat.testBit (index % 8)",
        "  else false",
        "",
        "/-- Evolution methods and exact level-up rows. -/",
        "def rows : Array Row := #[",
    ]
    for internal, (evolutions, moves) in enumerate(progression):
        evo_terms = []
        for evo in evolutions:
            if evo[0] == 1:
                evo_terms.append(f"{{ method := .level {evo[1]}, target := {evo[2]} }}")
            elif evo[0] == 2:
                evo_terms.append(
                    f"{{ method := .item {evo[1]} {evo[2]}, target := {evo[3]} }}"
                )
            else:
                evo_terms.append(f"{{ method := .trade {evo[1]}, target := {evo[2]} }}")
        move_terms = [f"{{ level := {level}, move := {move} }}" for level, move in moves]
        lines.append(
            f"  {{ evolutions := #[{', '.join(evo_terms)}], "
            f"levelMoves := #[{', '.join(move_terms)}] }}, -- ${internal:02X}"
        )
    lines += [
        "]",
        "",
        "@[simp] theorem growthRates_size : growthRates.size = 191 := by native_decide",
        "@[simp] theorem initialMoves_size : initialMoves.size = 191 := by native_decide",
        "@[simp] theorem tmhmMoves_size : tmhmMoves.size = 55 := by native_decide",
        "@[simp] theorem tmhmFlags_size : tmhmFlags.size = 191 := by native_decide",
        "@[simp] theorem rows_size : rows.size = 191 := by native_decide",
        "",
        "end Battle.Data.Progression",
        "",
    ]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("\n".join(lines))
    print(f"PASS progression rows: species={len(progression)}, sha256={digest}")


if __name__ == "__main__":
    main()
