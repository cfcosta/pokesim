#!/usr/bin/env python3
"""Audit pinned SM83 microarchitecture references and fixture inventories.

This script records source identity and finite, mechanically checkable facts. The
references remain validation inputs, not theorem premises. In particular, it
does not import CC BY-SA gb-ctr prose or timing tables into generated Lean code.
"""

from __future__ import annotations

import argparse
import collections
import hashlib
import html
import json
import re
import subprocess
import tomllib
import xml.etree.ElementTree as ET
from pathlib import Path

COMMITS = {
    "pandocs": "fe246067b695b5404a4a6a47efb4fd6d921ececb",
    "gb_ctr": "d164e64678841d2e4d768850810a89d0b9964187",
    "single_step": "f9c30210245dd691661db39f5ace022c465ecc2f",
    "mooneye": "31510e12eea6286d36eea060a6adde755e1067aa",
    "cpu_internals": "8efa6645473411e78dd917169141c16c0d306ce1",
}

HASHES = {
    "pandocs": {
        "src/CPU_Instruction_Set.md": "720bd402a14b8312c2d8e0778ad029ea566e9d4169511e8b3897bbab0391b728",
        "src/Interrupts.md": "dc9bed9237ec7f4840e38bc5c1403d243cbb3a6d1c53548474efd0c30e34be98",
        "src/halt.md": "506f8839aa8bdb8df61645e0adeeb00ae353df7de964844df6f9bdc3ed1ee006",
        "src/OAM_Corruption_Bug.md": "342423fad4fcc868f614a9b2b25aa1e0067cd50e8a2aa6fd3c55a0973b44a09b",
        "src/Reducing_Power_Consumption.md": "04bd92bbccbac2fa6819b8f30f6d239ddd8f5e78fe477b7ce7fd89fd0154a7a2",
        "src/CGB_Registers.md": "df0c3b0885b5ee0b8068c88979dcfe65ff45d209023307d6014cebc74a005f9b",
        "src/imgs/stop_diagram.drawio": "a0ab07ee43351863ffc1aefd1e386673930e436e7e63deb338d47caa6e66b562",
    },
    "gb_ctr": {
        "opcodes.toml": "c6fdbf62efdceb083adffe61dd22f762a1baba5f3f3a239da930537379f19d86",
        "chapter/cpu/instruction-set.typ": "31c419f149b594ca47d53f6fb301310f54fa5ee7a035d0632b057a4f98c38e6d",
        "chapter/cpu/timing.typ": "0a1914e9fd34961b2666809b75a25bdfee187f03537edee17d00efd5d4d1321f",
        "chapter/cpu/simple.typ": "ea38e7d663372213dabccf32e52da73de2f8933eae9ba09fa1188d0638ba9d4d",
        "chapter/console/clocks.typ": "fa3e2bad00a934116c12eedb6d15eba961ed3a1dbf130f2b2324429ab23a8c20",
    },
    "single_step": {
        "README.MD": "d36e08d5f4227a15ab07b1afdd1bee0ce2fd7d83de4d8a3759170fd74c1824c0",
    },
    "cpu_internals": {
        "DMGCPU.MD": "4cb192b351ee77707103c754accd8b71460eac19ce845caaa543d4c521357d26",
    },
    "mooneye": {
        "acceptance/instr/daa.s": "37341fe47cd19b36a2b8f0b041dd6213dc1d7952fc89f70399bc59112426508a",
        "acceptance/interrupts/ie_push.s": "2f33ed6af272f0e5945277d654882b5c48df7d336e95f3cefdd6ad49a46025d3",
        "acceptance/ei_sequence.s": "1d98529081aad78d34c65d11a940d8968844ea41ba634e2fa46e285305d90384",
        "acceptance/rapid_di_ei.s": "7e32310e3eeea13d1dee692e4fd33d5c52a30b67533e4688c547821354b42cc2",
        "acceptance/halt_ime0_ei.s": "fef85d2a68ed71ab2cff8bd5fbe88b055b86bea9a58f946c8413ae2537e3d1b5",
        "acceptance/intr_timing.s": "804aaf344bc9d482c429d4cccb28ac572bb80a33be047a4a1abe312a2f747086",
        "acceptance/reti_intr_timing.s": "6dce4600b2652a663834164f05eb590f5b5859ef530cf1ea453ec742305dcc36",
        "madness/mgb_oam_dma_halt_sprites.s": "e0c2b36639d1846f37b42ba69b6ad98e7396166d4fae64e562bb717c02c97c34",
    },
}

INVALID = {0xD3, 0xDB, 0xDD, 0xE3, 0xE4, 0xEB, 0xEC, 0xED, 0xF4, 0xFC, 0xFD}
NON_DETAILED_GB_CTR = {"CB", "undefined", "HALT", "STOP"}

NORMALIZED_TEMPLATES = {
    "one_cycle": {
        "LD_r_r", "ADD_r", "ADC_r", "SUB_r", "SBC_r", "AND_r", "XOR_r", "OR_r", "CP_r",
        "INC_r", "DEC_r", "CCF", "SCF", "DAA", "CPL", "RLCA", "RRCA", "RLA", "RRA", "DI", "EI", "NOP",
    },
    "mem_read": {"LD_r_hl", "ADD_hl", "ADC_hl", "SUB_hl", "SBC_hl", "AND_hl", "XOR_hl", "OR_hl", "CP_hl"},
    "mem_write": {"LD_hl_r"},
    "mem_rmw": {"INC_hl", "DEC_hl"},
    "imm8": {"LD_r_n", "ADD_n", "ADC_n", "SUB_n", "SBC_n", "AND_n", "XOR_n", "OR_n", "CP_n"},
    "imm8_store": {"LD_hl_n"},
    "imm16_load": {"LD_rr_nn"},
    "pair_mem": {"LD_a_bc", "LD_a_de", "LD_bc_a", "LD_de_a"},
    "hli_hld": {"LD_a_hli", "LD_a_hld", "LD_hli_a", "LD_hld_a"},
    "pair_idu": {"INC_rr", "DEC_rr"},
    "add_hl": {"ADD_hl_rr"},
    "ld_sp_hl": {"LD_sp_hl"},
    "abs_sp_store": {"LD_nn_sp"},
    "abs_a": {"LD_a_nn", "LD_nn_a"},
    "ldh_imm": {"LDH_a_n", "LDH_n_a"},
    "ldh_c": {"LDH_a_c", "LDH_c_a"},
    "signed_sp_hl": {"LD_hl_sp_e"},
    "signed_sp": {"ADD_sp_e"},
    "jr": {"JR"},
    "jr_cond": {"JR_cc"},
    "jp": {"JP"},
    "jp_cond": {"JP_cc"},
    "jp_hl": {"JP_hl"},
    "push": {"PUSH_rr"},
    "pop": {"POP_rr"},
    "call": {"CALL"},
    "call_cond": {"CALL_cc"},
    "rst": {"RST"},
    "ret": {"RET", "RETI"},
    "ret_cond": {"RET_cc"},
    "cb_reg": {"RLC_r", "RRC_r", "RL_r", "RR_r", "SLA_r", "SRA_r", "SWAP_r", "SRL_r", "BIT_b_r", "RES_b_r", "SET_b_r"},
    "cb_bit_mem": {"BIT_b_hl"},
    "cb_rmw_mem": {"RLC_hl", "RRC_hl", "RL_hl", "RR_hl", "SLA_hl", "SRA_hl", "SWAP_hl", "SRL_hl", "RES_b_hl", "SET_b_hl"},
}


def expected_gb_ctr_base_category(op: int) -> str:
    x, y, z = op >> 6, (op >> 3) & 7, op & 7
    p, q = y >> 1, y & 1
    if x == 0:
        if z == 0:
            return ["NOP", "LD_nn_sp", "STOP", "JR", "JR_cc", "JR_cc", "JR_cc", "JR_cc"][y]
        if z == 1:
            return "LD_rr_nn" if q == 0 else "ADD_hl_rr"
        if z == 2:
            stores = ["LD_bc_a", "LD_de_a", "LD_hli_a", "LD_hld_a"]
            loads = ["LD_a_bc", "LD_a_de", "LD_a_hli", "LD_a_hld"]
            return (stores if q == 0 else loads)[p]
        if z == 3:
            return "INC_rr" if q == 0 else "DEC_rr"
        if z == 4:
            return "INC_hl" if y == 6 else "INC_r"
        if z == 5:
            return "DEC_hl" if y == 6 else "DEC_r"
        if z == 6:
            return "LD_hl_n" if y == 6 else "LD_r_n"
        return ["RLCA", "RRCA", "RLA", "RRA", "DAA", "CPL", "SCF", "CCF"][y]
    if x == 1:
        if y == 6 and z == 6:
            return "HALT"
        if y == 6:
            return "LD_hl_r"
        if z == 6:
            return "LD_r_hl"
        return "LD_r_r"
    if x == 2:
        stem = ["ADD", "ADC", "SUB", "SBC", "AND", "XOR", "OR", "CP"][y]
        return f"{stem}_{'hl' if z == 6 else 'r'}"
    if z == 0:
        return "RET_cc" if y < 4 else ["LDH_n_a", "ADD_sp_e", "LDH_a_n", "LD_hl_sp_e"][y - 4]
    if z == 1:
        if q == 0:
            return "POP_rr"
        return ["RET", "RETI", "JP_hl", "LD_sp_hl"][p]
    if z == 2:
        return "JP_cc" if y < 4 else ["LDH_c_a", "LD_nn_a", "LDH_a_c", "LD_a_nn"][y - 4]
    if z == 3:
        return ["JP", "CB", "undefined", "undefined", "undefined", "undefined", "DI", "EI"][y]
    if z == 4:
        return "CALL_cc" if y < 4 else "undefined"
    if z == 5:
        if q == 0:
            return "PUSH_rr"
        return "CALL" if p == 0 else "undefined"
    if z == 6:
        return f"{['ADD', 'ADC', 'SUB', 'SBC', 'AND', 'XOR', 'OR', 'CP'][y]}_n"
    return "RST"


def expected_gb_ctr_cb_category(op: int) -> str:
    x, y, z = op >> 6, (op >> 3) & 7, op & 7
    suffix = "hl" if z == 6 else "r"
    if x == 0:
        return f"{['RLC', 'RRC', 'RL', 'RR', 'SLA', 'SRA', 'SWAP', 'SRL'][y]}_{suffix}"
    return f"{['BIT_b', 'RES_b', 'SET_b'][x - 1]}_{suffix}"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def commit(root: Path) -> str:
    return subprocess.check_output(
        ["git", "-C", str(root), "rev-parse", "HEAD"], text=True
    ).strip()


def check_identity(name: str, root: Path) -> None:
    actual = commit(root)
    status = subprocess.check_output(
        ["git", "-C", str(root), "status", "--porcelain"], text=True
    )
    assert not status, (name, root, status)
    assert actual == COMMITS[name], (name, actual, COMMITS[name])
    for relative, expected in HASHES[name].items():
        actual_hash = sha256(root / relative)
        assert actual_hash == expected, (name, relative, actual_hash, expected)


def clean_markup(value: str | None) -> str:
    value = html.unescape((value or "").replace("&nbsp;", " "))
    return " ".join(re.sub(r"<[^>]+>", " ", value).split())


def audit_cpu_internals(root: Path) -> None:
    text = (root / "DMGCPU.MD").read_text()
    for fragment in (
        "fetch is always the *last* part of the instruction",
        "Program Counter is always ahead (+1)",
        "IR = [PC+]`, except for HALT",
        "interrupt servicing happens *after* fetching the next opcode",
        "M0 | IDU PC-",
        "Because the $CB prefix lacks the generic fetch bit",
    ):
        assert fragment in text
    assert text.count("generic fetch") >= 15


def audit_pandocs(root: Path) -> None:
    instruction_set = (root / "src/CPU_Instruction_Set.md").read_text()
    invalid_paragraph = instruction_set.split("The following opcodes are **invalid**", 1)[1].split("## \\$CB", 1)[0]
    found_invalid = {int(x, 16) for x in re.findall(r"\\\$([0-9A-F]{2})", invalid_paragraph)}
    assert found_invalid == INVALID, found_invalid

    interrupts = (root / "src/Interrupts.md").read_text()
    assert "lasts 5 M-cycles" in interrupts
    assert "Bit 0 (VBlank) has the highest priority" in interrupts
    halt = (root / "src/halt.md").read_text()
    assert "pc` fails to be normally incremented" in halt
    assert "preceded by a `ei` and followed by a `rst`" in halt

    oam = (root / "src/OAM_Corruption_Bug.md").read_text()
    assert "increment and decrement unit (IDU)" in oam
    assert "$FE00–$FEFF" in oam
    assert re.search(r"`pop` will trigger the\s+bug only 3 times", oam)

    tree = ET.parse(root / "src/imgs/stop_diagram.drawio").getroot()
    labels = {
        clean_markup(node.attrib.get("value"))
        for node in tree.iter("mxCell")
        if clean_markup(node.attrib.get("value"))
    }
    outcomes = {label for label in labels if label.startswith("STOP is") or label.startswith("The CPU glitches")}
    assert len(outcomes) == 7, outcomes
    required_fragments = {
        "1-byte opcode, mode doesn't change, DIV doesn't reset",
        "2-byte opcode, HALT mode is entered, DIV is not reset",
        "2-byte opcode, STOP mode is entered, DIV is reset",
        "1-byte opcode, STOP mode is entered, DIV is reset",
        "2-byte opcode, HALT mode is entered, DIV is reset, CPU speed changes",
        "glitches non-deterministically",
        "1-byte opcode, mode doesn't change, DIV is reset CPU speed changes",
    }
    for fragment in required_fragments:
        assert any(fragment in outcome for outcome in outcomes), fragment
    cgb = (root / "src/CGB_Registers.md").read_text()
    assert "2050 M-cycles (= 8200 T-cycles)" in cgb
    assert "TODO: confirm whether interrupts can occur" in cgb
    stop_xml = (root / "src/imgs/stop_diagram.drawio").read_text()
    assert "0x20000 T-cycles" in html.unescape(stop_xml)


def audit_gb_ctr(root: Path) -> None:
    catalogue = tomllib.loads((root / "opcodes.toml").read_text())
    assert len(catalogue["opcodes"]) == 256
    assert len(catalogue["cb_opcodes"]) == 256
    assert len(catalogue["categories"]) == 105
    assert {i for i, row in enumerate(catalogue["opcodes"]) if row["category"] == "undefined"} == INVALID
    for op, row in enumerate(catalogue["opcodes"]):
        assert row["category"] == expected_gb_ctr_base_category(op), (op, row["category"])
    for op, row in enumerate(catalogue["cb_opcodes"]):
        assert row["category"] == expected_gb_ctr_cb_category(op), (op, row["category"])

    text = (root / "chapter/cpu/instruction-set.typ").read_text()
    anchors = set(re.findall(r"<op:([^>]+)>", text))
    categories = set(catalogue["categories"])
    assert anchors == categories
    detailed = set(re.findall(r"#instruction\(.*?<op:([^>]+)>", text, re.DOTALL))
    assert categories - detailed == NON_DETAILED_GB_CTR, categories - detailed
    template_members = [category for members in NORMALIZED_TEMPLATES.values() for category in members]
    assert len(template_members) == len(set(template_members))
    assert set(template_members) == detailed, (set(template_members) - detailed, detailed - set(template_members))
    assert len(NORMALIZED_TEMPLATES) == 33
    assert text.count("#instruction(") == 101
    starts = [match.start() for match in re.finditer(r"^#instruction\(", text, re.MULTILINE)] + [len(text)]
    duration_shapes: collections.Counter[tuple[int, ...]] = collections.Counter()
    for start, end in zip(starts, starts[1:]):
        block = text[start:end]
        anchor = re.search(r"<op:([^>]+)>", block)
        assert anchor is not None and anchor[1] in detailed
        durations = tuple(int(value) for value in re.findall(r"\bduration: (\d+)", block))
        assert durations
        duration_shapes[durations] += 1
        for field in ("mem_rw:", "addr:", "data:", "idu_op:", "alu_op:", "misc_op:"):
            assert field in block, (anchor[1], field)
    assert duration_shapes == {
        (1,): 23, (2,): 44, (3,): 10, (4,): 18, (5,): 1, (6,): 1,
        (4, 3): 1, (3, 2): 1, (6, 3): 1, (5, 2): 1,
    }

    timing = (root / "chapter/cpu/timing.typ").read_text()
    assert "fetch/execute overlap" in timing
    assert "fetch stage of an instruction always overlaps" in timing
    clocks = (root / "chapter/console/clocks.typ").read_text()
    for edge in ("T1R", "T1F", "T2R", "T2F", "T3R", "T3F", "T4R", "T4F"):
        assert edge in clocks


def daa(a: int, flags: int) -> tuple[int, int]:
    n = bool(flags & 0b0100)
    h = bool(flags & 0b0010)
    c = bool(flags & 0b0001)
    if n:
        correction = (0x06 if h else 0) + (0x60 if c else 0)
        result = (a - correction) & 0xFF
        carry = c
    else:
        correction = 0
        if h or (a & 0x0F) > 9:
            correction |= 0x06
        if c or a > 0x99:
            correction |= 0x60
        result = (a + correction) & 0xFF
        carry = c or a > 0x99
    result_flags = (0b1000 if result == 0 else 0) | (0b0100 if n else 0) | (1 if carry else 0)
    return result, result_flags


def audit_mooneye(root: Path) -> None:
    acceptance = list((root / "acceptance").rglob("*.s"))
    assert len(acceptance) == 75

    daa_rows: list[tuple[int, int, int, int]] = []
    pattern = re.compile(r"\.db \$([0-9A-Fa-f]{2}), %([01]{4}), \$([0-9A-Fa-f]{2}), %([01]{4})")
    for line in (root / "acceptance/instr/daa.s").read_text().splitlines():
        match = pattern.match(line.strip())
        if match:
            daa_rows.append(
                (int(match[1], 16), int(match[2], 2), int(match[3], 16), int(match[4], 2))
            )
    assert len(daa_rows) == 4096
    assert len({(a, flags) for a, flags, _, _ in daa_rows}) == 4096
    assert all(daa(a, flags) == (result, result_flags) for a, flags, result, result_flags in daa_rows)

    ie_push = (root / "acceptance/interrupts/ie_push.s").read_text()
    for fragment in (
        "PC is set to $0000",
        "late to cancel the interrupt dispatch",
        "STAT interrupt is dispatched normally",
        "IME should be 0 after a cancellation",
    ):
        assert fragment in ie_push
    ei_sequence = (root / "acceptance/ei_sequence.s").read_text()
    assert ".repeat 17" in ei_sequence and "assert_c $A2" in ei_sequence
    halt_dma = (root / "madness/mgb_oam_dma_halt_sprites.s").read_text()
    assert "OAM DMA is in the middle of OAM access" in halt_dma
    assert "but not proceeding with it" in halt_dma


def audit_single_step(root: Path) -> None:
    vector_dir = root / "v1"
    files = sorted(vector_dir.glob("*.json"))
    assert len(files) == 500
    expected_case_keys = ("name", "initial", "final", "cycles")
    expected_initial_keys = ("pc", "sp", "a", "b", "c", "d", "e", "f", "h", "l", "ime", "ie", "ram")
    ordinary_final_keys = ("a", "b", "c", "d", "e", "f", "h", "l", "pc", "sp", "ime", "ram")
    ei_final_keys = ordinary_final_keys[:-1] + ("ei", "ram")

    signal_counts: collections.Counter[str] = collections.Counter()
    cycle_lengths: collections.Counter[int] = collections.Counter()
    sequences: set[tuple[str, ...]] = set()
    total = 0
    for path in files:
        cases = json.loads(path.read_text())
        assert len(cases) == 1000, path
        is_ei = path.name == "fb.json"
        for case in cases:
            total += 1
            assert tuple(case) == expected_case_keys
            assert tuple(case["initial"]) == expected_initial_keys
            assert tuple(case["final"]) == (ei_final_keys if is_ei else ordinary_final_keys)
            assert case["initial"]["f"] & 0x0F == 0
            assert case["final"]["f"] & 0x0F == 0
            initial_ram = case["initial"]["ram"]
            final_ram = case["final"]["ram"]
            assert len(initial_ram) == len({address for address, _ in initial_ram})
            assert len(final_ram) == len({address for address, _ in final_ram})

            cycles = case["cycles"]
            assert cycles and cycles[0][2] == "r-m"
            assert cycles[0][0] == case["initial"]["pc"]
            assert cycles[0][1] == (0xCB if path.name.startswith("cb ") else int(path.stem, 16))
            sequence = tuple(cycle[2] for cycle in cycles)
            sequences.add(sequence)
            cycle_lengths[len(cycles)] += 1
            for address, data, signal in cycles:
                assert address is not None and data is not None
                assert signal in {"r-m", "-wm", "---"}
                signal_counts[signal] += 1

    assert total == 500_000
    assert signal_counts == {"r-m": 887_060, "-wm": 72_854, "---": 48_942}
    assert cycle_lengths == {1: 131_000, 2: 287_950, 3: 31_128, 4: 43_965, 5: 3_030, 6: 2_927}
    assert len(sequences) == 16


def main() -> None:
    if not __debug__:
        raise RuntimeError("audit assertions are disabled; do not run with python -O")
    parser = argparse.ArgumentParser()
    parser.add_argument("--pandocs-root", type=Path, required=True)
    parser.add_argument("--gb-ctr-root", type=Path, required=True)
    parser.add_argument("--single-step-root", type=Path, required=True)
    parser.add_argument("--mooneye-root", type=Path, required=True)
    parser.add_argument("--cpu-internals-root", type=Path, required=True)
    args = parser.parse_args()
    roots = {
        "pandocs": args.pandocs_root.resolve(),
        "gb_ctr": args.gb_ctr_root.resolve(),
        "single_step": args.single_step_root.resolve(),
        "mooneye": args.mooneye_root.resolve(),
        "cpu_internals": args.cpu_internals_root.resolve(),
    }
    for name, root in roots.items():
        check_identity(name, root)

    audit_cpu_internals(roots["cpu_internals"])
    audit_pandocs(roots["pandocs"])
    audit_gb_ctr(roots["gb_ctr"])
    audit_single_step(roots["single_step"])
    audit_mooneye(roots["mooneye"])

    source_hashes = sum(len(files) for files in HASHES.values())
    print(f"PASS five pinned SM83 reference commits and {source_hashes} exact source hashes")
    print("PASS gb-ctr: 256+256 rows, 105 categories, 101 timings mapped once into 33 templates")
    print("PASS SingleStep: 500 files, 500000 cases, exact schemas/signals/cycle distributions")
    print("PASS Mooneye: 75 acceptance sources and all 4096 DAA A/ZNHC states")
    print("PASS Pan Docs: invalid set, interrupt/HALT/OAM facts, and seven STOP outcomes")
    print("NOTE fetch overlap, idle address drive, IDU/OAM effects, and clock gating exceed gb-opcodes metadata")


if __name__ == "__main__":
    main()
