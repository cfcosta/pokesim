#!/usr/bin/env python3
"""Audit the pinned gbdev/gb-opcodes metadata used by the SM83 specification.

This checks the exact reviewed artifact and its structural invariants. It does not
promote display-oriented JSON fields into processor semantics; known limitations
are reported explicitly in docs/reference/sm83-implementation-spec.md.
"""

from __future__ import annotations

import argparse
import collections
import hashlib
import json
import subprocess
from pathlib import Path
from typing import Any

EXPECTED_COMMIT = "376f61c86fdac2048f7ce5fe838ae756b306017e"
EXPECTED_OPCODES_SHA256 = "e7e3cd657d8e87b44570474eb3a6ed735501c9a00520f3d6937881203c823bc5"
EXPECTED_DESCRIPTIONS_SHA256 = "ac0eeea25360ea93555ba8e53d8f49f25ee4bfb7ab052466053b18abe94ec079"
EXPECTED_SINGLE_STEP_COMMIT = "f9c30210245dd691661db39f5ace022c465ecc2f"
EXPECTED_INVALID = [0xD3, 0xDB, 0xDD, 0xE3, 0xE4, 0xEB, 0xEC, 0xED, 0xF4, 0xFC, 0xFD]
FLAG_TOKENS = {"-", "0", "1", "Z", "N", "H", "C"}
ENTRY_FIELDS = {"mnemonic", "bytes", "cycles", "operands", "immediate", "flags"}
OPERAND_FIELDS = {"name", "bytes", "immediate", "increment", "decrement"}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def opcode_keys() -> list[str]:
    return [f"0x{i:02X}" for i in range(256)]


def classify_base(op: int) -> str:
    """Encoding-family partition, independent of the JSON mnemonic strings."""
    x, y, z = op >> 6, (op >> 3) & 7, op & 7
    p, q = y >> 1, y & 1
    if x == 0:
        if z == 0:
            return ["nop", "ld_abs_sp", "stop", "jr", "jr_cond", "jr_cond", "jr_cond", "jr_cond"][y]
        if z == 1:
            return "ld_r16_imm" if q == 0 else "add_hl_r16"
        if z == 2:
            return "ld_mem_r16_a" if q == 0 else "ld_a_mem_r16"
        if z == 3:
            return "inc_r16" if q == 0 else "dec_r16"
        if z == 4:
            return "inc_r8"
        if z == 5:
            return "dec_r8"
        if z == 6:
            return "ld_r8_imm"
        return "acc_misc"
    if x == 1:
        return "halt" if y == 6 and z == 6 else "ld_r8_r8"
    if x == 2:
        return "alu_a_r8"

    if z == 0:
        return "ret_cond" if y < 4 else ["ldh_mem_imm_a", "add_sp_rel", "ldh_a_mem_imm", "ld_hl_sp_rel"][y - 4]
    if z == 1:
        if q == 0:
            return "pop"
        return ["ret", "reti", "jp_hl", "ld_sp_hl"][p]
    if z == 2:
        return "jp_cond" if y < 4 else ["ldh_mem_c_a", "ld_mem_abs_a", "ldh_a_mem_c", "ld_a_mem_abs"][y - 4]
    if z == 3:
        return ["jp", "prefix", "invalid", "invalid", "invalid", "invalid", "di", "ei"][y]
    if z == 4:
        return "call_cond" if y < 4 else "invalid"
    if z == 5:
        if q == 0:
            return "push"
        return "call" if p == 0 else "invalid"
    if z == 6:
        return "alu_a_imm"
    return "rst"


def classify_cb(op: int) -> str:
    x, y = op >> 6, (op >> 3) & 7
    if x == 0:
        return ["rlc", "rrc", "rl", "rr", "sla", "sra", "swap", "srl"][y]
    return ["bit", "res", "set"][x - 1]


def expected_base_metadata(op: int) -> tuple[str, int, tuple[int, ...], str]:
    """Expected mnemonic, bytes, T-cycles, and ZNHC policy from encoding families."""
    x, y, z = op >> 6, (op >> 3) & 7, op & 7
    p, q = y >> 1, y & 1
    if x == 0:
        if z == 0:
            rows = [
                ("NOP", 1, (4,), "----"), ("LD", 3, (20,), "----"),
                ("STOP", 2, (4,), "----"), ("JR", 2, (12,), "----"),
                ("JR", 2, (12, 8), "----"), ("JR", 2, (12, 8), "----"),
                ("JR", 2, (12, 8), "----"), ("JR", 2, (12, 8), "----"),
            ]
            return rows[y]
        if z == 1:
            return ("LD", 3, (12,), "----") if q == 0 else ("ADD", 1, (8,), "-0HC")
        if z == 2:
            return "LD", 1, (8,), "----"
        if z == 3:
            return ("INC" if q == 0 else "DEC"), 1, (8,), "----"
        if z == 4:
            return "INC", 1, ((12,) if y == 6 else (4,)), "Z0H-"
        if z == 5:
            return "DEC", 1, ((12,) if y == 6 else (4,)), "Z1H-"
        if z == 6:
            return "LD", 2, ((12,) if y == 6 else (8,)), "----"
        names = ["RLCA", "RRCA", "RLA", "RRA", "DAA", "CPL", "SCF", "CCF"]
        flags = ["000C", "000C", "000C", "000C", "Z-0C", "-11-", "-001", "-00C"]
        return names[y], 1, (4,), flags[y]
    if x == 1:
        if y == 6 and z == 6:
            return "HALT", 1, (4,), "----"
        return "LD", 1, ((8,) if y == 6 or z == 6 else (4,)), "----"
    if x == 2:
        names = ["ADD", "ADC", "SUB", "SBC", "AND", "XOR", "OR", "CP"]
        flags = ["Z0HC", "Z0HC", "Z1HC", "Z1HC", "Z010", "Z000", "Z000", "Z1HC"]
        # The catalogue specializes four A-on-A cases whose flags are statically
        # simpler than the generic family policy.
        specialized = {0x97: "1100", 0x9F: "Z1H-", 0xAF: "1000", 0xBF: "1100"}
        return names[y], 1, ((8,) if z == 6 else (4,)), specialized.get(op, flags[y])

    if z == 0:
        if y < 4:
            return "RET", 1, (20, 8), "----"
        return [
            ("LDH", 2, (12,), "----"), ("ADD", 2, (16,), "00HC"),
            ("LDH", 2, (12,), "----"), ("LD", 2, (12,), "00HC"),
        ][y - 4]
    if z == 1:
        if q == 0:
            return "POP", 1, (12,), ("ZNHC" if p == 3 else "----")
        return [
            ("RET", 1, (16,), "----"), ("RETI", 1, (16,), "----"),
            ("JP", 1, (4,), "----"), ("LD", 1, (8,), "----"),
        ][p]
    if z == 2:
        if y < 4:
            return "JP", 3, (16, 12), "----"
        return [
            ("LDH", 1, (8,), "----"), ("LD", 3, (16,), "----"),
            ("LDH", 1, (8,), "----"), ("LD", 3, (16,), "----"),
        ][y - 4]
    if z == 3:
        if y == 0:
            return "JP", 3, (16,), "----"
        if y == 1:
            return "PREFIX", 1, (4,), "----"
        if y == 6:
            return "DI", 1, (4,), "----"
        if y == 7:
            return "EI", 1, (4,), "----"
        return f"ILLEGAL_{op:02X}", 1, (4,), "----"
    if z == 4:
        if y < 4:
            return "CALL", 3, (24, 12), "----"
        return f"ILLEGAL_{op:02X}", 1, (4,), "----"
    if z == 5:
        if q == 0:
            return "PUSH", 1, (16,), "----"
        if p == 0:
            return "CALL", 3, (24,), "----"
        return f"ILLEGAL_{op:02X}", 1, (4,), "----"
    if z == 6:
        names = ["ADD", "ADC", "SUB", "SBC", "AND", "XOR", "OR", "CP"]
        flags = ["Z0HC", "Z0HC", "Z1HC", "Z1HC", "Z010", "Z000", "Z000", "Z1HC"]
        return names[y], 2, (8,), flags[y]
    return "RST", 1, (16,), "----"


def expected_cb_metadata(op: int) -> tuple[str, int, tuple[int, ...], str]:
    x, y, z = op >> 6, (op >> 3) & 7, op & 7
    if x == 0:
        name = ["RLC", "RRC", "RL", "RR", "SLA", "SRA", "SWAP", "SRL"][y]
        cycles = (16,) if z == 6 else (8,)
        flags = "Z000" if y == 6 else "Z00C"
        return name, 2, cycles, flags
    name = ["BIT", "RES", "SET"][x - 1]
    cycles = ((12,) if z == 6 else (8,)) if x == 1 else ((16,) if z == 6 else (8,))
    flags = "Z01-" if x == 1 else "----"
    return name, 2, cycles, flags


def check_entry(set_name: str, key: str, entry: dict[str, Any]) -> None:
    assert set(entry) == ENTRY_FIELDS, (set_name, key, set(entry))
    assert isinstance(entry["mnemonic"], str) and entry["mnemonic"]
    assert entry["bytes"] in (1, 2, 3)
    assert isinstance(entry["cycles"], list) and len(entry["cycles"]) in (1, 2)
    assert all(isinstance(c, int) and c > 0 and c % 4 == 0 for c in entry["cycles"])
    assert isinstance(entry["operands"], list)
    assert isinstance(entry["immediate"], bool)
    assert list(entry["flags"]) == list("ZNHC")
    assert all(v in FLAG_TOKENS for v in entry["flags"].values())
    for operand in entry["operands"]:
        assert set(operand) <= OPERAND_FIELDS and {"name", "immediate"} <= set(operand), (set_name, key, operand)
        assert isinstance(operand["name"], str)
        assert isinstance(operand["immediate"], bool)
        if "bytes" in operand:
            assert operand["bytes"] in (1, 2)
        for field in ("increment", "decrement"):
            if field in operand:
                assert operand[field] is True
        assert not (operand.get("increment") and operand.get("decrement"))


def main() -> None:
    if not __debug__:
        raise RuntimeError("audit assertions are disabled; do not run with python -O")
    parser = argparse.ArgumentParser()
    parser.add_argument("root", nargs="?", type=Path, default=Path("../gb-opcodes"))
    parser.add_argument("--single-step-root", type=Path, help="optional pinned SingleStepTests/sm83 checkout")
    args = parser.parse_args()
    root = args.root.resolve()
    opcodes_path = root / "Opcodes.json"
    descriptions_path = root / "OpcodeDescriptions.json"

    commit = subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()
    status = subprocess.check_output(["git", "-C", str(root), "status", "--porcelain"], text=True)
    assert not status, (root, status)
    assert commit == EXPECTED_COMMIT, (commit, EXPECTED_COMMIT)
    assert sha256(opcodes_path) == EXPECTED_OPCODES_SHA256
    assert sha256(descriptions_path) == EXPECTED_DESCRIPTIONS_SHA256

    data = json.loads(opcodes_path.read_text())
    assert list(data) == ["unprefixed", "cbprefixed"]
    for set_name in data:
        assert list(data[set_name]) == opcode_keys()
        assert len(data[set_name]) == 256
        for key, entry in data[set_name].items():
            check_entry(set_name, key, entry)

    base = data["unprefixed"]
    cb = data["cbprefixed"]
    for op in range(256):
        key = f"0x{op:02X}"
        entry = base[key]
        actual = (entry["mnemonic"], entry["bytes"], tuple(entry["cycles"]), "".join(entry["flags"][f] for f in "ZNHC"))
        assert actual == expected_base_metadata(op), (key, actual, expected_base_metadata(op))
        entry = cb[key]
        actual = (entry["mnemonic"], entry["bytes"], tuple(entry["cycles"]), "".join(entry["flags"][f] for f in "ZNHC"))
        assert actual == expected_cb_metadata(op), ("CB " + key, actual, expected_cb_metadata(op))
    invalid = [int(key, 16) for key, entry in base.items() if entry["mnemonic"].startswith("ILLEGAL_")]
    assert invalid == EXPECTED_INVALID
    assert base["0xCB"]["mnemonic"] == "PREFIX"
    assert base["0x10"]["mnemonic"] == "STOP"
    assert base["0x10"]["bytes"] == 2 and base["0x10"]["cycles"] == [4]
    assert base["0x76"]["mnemonic"] == "HALT" and base["0x76"]["cycles"] == [4]

    expected_base_families = {
        "nop": 1, "ld_abs_sp": 1, "stop": 1, "jr": 1, "jr_cond": 4,
        "ld_r16_imm": 4, "add_hl_r16": 4, "ld_mem_r16_a": 4,
        "ld_a_mem_r16": 4, "inc_r16": 4, "dec_r16": 4, "inc_r8": 8,
        "dec_r8": 8, "ld_r8_imm": 8, "acc_misc": 8, "halt": 1,
        "ld_r8_r8": 63, "alu_a_r8": 64, "ret_cond": 4, "ldh_mem_imm_a": 1,
        "add_sp_rel": 1, "ldh_a_mem_imm": 1, "ld_hl_sp_rel": 1, "pop": 4,
        "ret": 1, "reti": 1, "jp_hl": 1, "ld_sp_hl": 1, "jp_cond": 4,
        "ldh_mem_c_a": 1, "ld_mem_abs_a": 1, "ldh_a_mem_c": 1,
        "ld_a_mem_abs": 1, "jp": 1, "prefix": 1, "invalid": 11, "di": 1,
        "ei": 1, "call_cond": 4, "push": 4, "call": 1, "alu_a_imm": 8,
        "rst": 8,
    }
    assert collections.Counter(classify_base(i) for i in range(256)) == expected_base_families
    assert collections.Counter(classify_cb(i) for i in range(256)) == {
        "rlc": 8, "rrc": 8, "rl": 8, "rr": 8, "sla": 8, "sra": 8,
        "swap": 8, "srl": 8, "bit": 64, "res": 64, "set": 64,
    }

    assert collections.Counter(entry["bytes"] for entry in base.values()) == {1: 213, 2: 26, 3: 17}
    assert collections.Counter(tuple(entry["cycles"]) for entry in base.values()) == {
        (4,): 145, (8,): 60, (12,): 15, (16,): 18, (20,): 1, (24,): 1,
        (12, 8): 4, (20, 8): 4, (16, 12): 4, (24, 12): 4,
    }
    assert collections.Counter(entry["bytes"] for entry in cb.values()) == {2: 256}
    assert collections.Counter(tuple(entry["cycles"]) for entry in cb.values()) == {
        (8,): 224, (12,): 8, (16,): 24,
    }

    conditional = {key: entry for key, entry in base.items() if len(entry["cycles"]) == 2}
    assert len(conditional) == 16
    assert all(entry["cycles"][0] > entry["cycles"][1] for entry in conditional.values())

    for key, entry in base.items():
        encoded_operand_bytes = sum(operand.get("bytes", 0) for operand in entry["operands"])
        assert encoded_operand_bytes == entry["bytes"] - 1, (key, entry)
    assert all(entry["bytes"] == 2 for entry in cb.values())
    assert all(sum(operand.get("bytes", 0) for operand in entry["operands"]) == 0 for entry in cb.values())

    # The display-oriented immediate fields happen to satisfy this relation, but
    # they are intentionally not interpreted as semantic immediate-mode tags.
    assert all(entry["immediate"] == all(op["immediate"] for op in entry["operands"]) for entry in base.values())
    assert all(entry["immediate"] == all(op["immediate"] for op in entry["operands"]) for entry in cb.values())

    # Known open issue #39: this is a rendering hack, not SP mutation semantics.
    f8 = base["0xF8"]
    assert len(f8["operands"]) == 3
    assert f8["operands"][1] == {"name": "SP", "increment": True, "immediate": True}

    descriptions = json.loads(descriptions_path.read_text())
    assert list(descriptions) == ["unprefixed"]
    assert set(descriptions["unprefixed"]) == {"nop", "ld_r16_n16"}
    described_ops = sum(len(group["ops"]) for group in descriptions["unprefixed"].values())
    assert described_ops == 5

    print(f"PASS gb-opcodes commit={commit}")
    print(f"PASS Opcodes.json sha256={sha256(opcodes_path)}")
    print("PASS 256 base rows, 256 CB rows, exact schema/key order")
    print("PASS base partition: 244 legal + PREFIX + 11 ILLEGAL")
    print("PASS every row matches encoding-derived mnemonic/length/T-cycle/flag metadata")
    print("PASS cycle/length/family distributions and operand-byte accounting")
    print("NOTE STOP/HALT/PREFIX/ILLEGAL timing is metadata, not completion semantics")
    print("NOTE operand/top-level 'immediate' and F8 'increment' are display-oriented and rejected as semantic inputs")
    print("NOTE OpcodeDescriptions.json describes only 5 base opcodes and no CB opcodes")

    if args.single_step_root is not None:
        vectors_root = args.single_step_root.resolve()
        vectors_commit = subprocess.check_output(
            ["git", "-C", str(vectors_root), "rev-parse", "HEAD"], text=True
        ).strip()
        vectors_status = subprocess.check_output(
            ["git", "-C", str(vectors_root), "status", "--porcelain"], text=True
        )
        assert not vectors_status, (vectors_root, vectors_status)
        assert vectors_commit == EXPECTED_SINGLE_STEP_COMMIT, (vectors_commit, EXPECTED_SINGLE_STEP_COMMIT)
        vector_dir = vectors_root / "v1"
        files = list(vector_dir.glob("*.json"))
        assert len(files) == 500
        checked_cases = 0
        for set_name, prefix in (("unprefixed", ""), ("cbprefixed", "cb ")):
            for key, entry in data[set_name].items():
                if set_name == "unprefixed" and (
                    entry["mnemonic"] == "PREFIX" or entry["mnemonic"].startswith("ILLEGAL_")
                ):
                    continue
                path = vector_dir / f"{prefix}{key[2:].lower()}.json"
                assert path.exists(), path
                cases = json.loads(path.read_text())
                assert len(cases) == 1000, path
                observed = {len(case["cycles"]) * 4 for case in cases}
                if set_name == "unprefixed" and key in ("0x10", "0x76"):
                    assert observed == {12}, (key, observed)
                    assert {
                        (case["final"]["pc"] - case["initial"]["pc"]) % 65536 for case in cases
                    } == {1}
                else:
                    assert observed == set(entry["cycles"]), (set_name, key, observed, entry["cycles"])
                checked_cases += len(cases)
        assert checked_cases == 500_000
        print(f"PASS SingleStep commit={vectors_commit}, cases={checked_cases}")
        print("NOTE only HALT/STOP disagree on ordinary cycle totals: vectors use 12 T-cycles and PC+1 placeholders")


if __name__ == "__main__":
    main()
