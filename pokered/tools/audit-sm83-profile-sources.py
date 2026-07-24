#!/usr/bin/env python3
"""Audit pinned SM83 profile/physical-timing evidence.

This script checks source identity and the exact evidence used by the
DMG-CPU B profile contract. It does not treat an emulator or reverse-engineered
HDL model as an authority; it makes their scope and TODOs auditable.
"""

from __future__ import annotations

import argparse
import hashlib
import html
import re
import subprocess
from pathlib import Path

COMMITS = {
    "gb-research": "59088f486f579a69fd86bd86a55181b937e769e0",
    "SameBoy": "213a12ce93d66b105a113debd9396306066a7cfc",
    "GBMicrotest": "463eb6bc0fe31d61781ef63060ad6d74090c0255",
}

HASHES = {
    "gb-research": {
        "README.markdown": "9af95aaa7ccc0154a5beb68b702b39ab2571a9b49be64107890028b7a0f296c8",
        ".reuse/dep5": "fbca6699b5de83bcd06702ad9bd9127f84744c064e998f313400f8be7371ba65",
        "sm83-cpu-core/README.markdown": "ab64a430afa6c29568cef9da1042e3ec976ce681a2aa1850c7e7c1374022a01d",
        "sm83-cpu-core/hdl/cpu_core.vhd": "46133341fd6bb16530fc74fc8bf6431c398c9a812f13e9c8dbcb68620443fcac",
        "sm83-cpu-core/hdl/control_unit.vhd": "360238e51457e1d19e49975683eeb152464a7e5673a04259884c9b72b17d69ed",
        "sm83-cpu-core/hdl/interrupts.vhd": "a3554bd04b615617cb4ec7459e6f10da19f3db24c0c4a01879498c2a96691cf3",
        "sm83-cpu-core/hdl/regfile.vhd": "b3e808e9baa03e391c02bd7cadf1576bd48669a4e67b3a9ed8597faad55fb222",
        "sm83-cpu-core/hdl/idu.vhd": "e6a62bc9b4c37f44b5fca2d9923950bf9a436d10cebbb583b08466d62119b71d",
        "sm83-cpu-core/hdl/decoder.vhd": "dcfd9d25633c3c65fb5a81dc86d0c7449b63554695efb13c4e40c59ad586ffb5",
        "sm83-cpu-core/hdl/simulation/test_soc.vhd": "2d400ca79043aabc76d3d2a98e8d38ba87990e1be9745220dd398f794a78fc8a",
    },
    "SameBoy": {
        "LICENSE": "875b2c940181c315fa99ce5292326b985a43cdc4e878b38995066d6b495ff151",
        "README.md": "ed38cc86037338827fe3f5668e18737153ab2b64d6573504a06ebf2362aee2d5",
        "Core/model.h": "55073a6aca591a4aefa1511745d8cf1c95d476708879a0b3c8f13752a9822024",
        "Core/sm83_cpu.c": "380a19c6ca32cdbd6c22735b54e4cb9a017cee3a3e949499abd8733977bb2b4f",
        "Core/timing.c": "79243f0cadff8336a8b80edd9664d450a1ce1e950c8a7e82b57babf92ed7df3b",
        "Core/memory.c": "fca194c0168863086a18a589048c563b094dda44bbb43b438d99c3ebcf31ec63",
    },
    "GBMicrotest": {
        "LICENSE": "0b3557142dfcce65428fafb9c8254d9d59c027a008af4810867efd7342b77c25",
        "README.md": "15610d3e922658503b5250f1e9e0106d3ad6bdee7ff43003147f5871a81a3b92",
        "build.sh": "c726ca6214cb3861fef0da43da2eebc69f7c63e944b61746be5ec028db977488",
        "tests/halt_op_dupe_delay.s": "a82de60a55d5dc96ea54284b71248278d87c9067d24cb0971386bf8d332559f4",
        "tests/halt_op_dupe.s": "0dbdec94a748394ca9dab1ffa22b97bb0479435352093f4d0119c7d0dc71a5e2",
    },
}

WEB_HASHES = {
    "mem_patterns.html": "8616eaf3c9f8eea6b165646c66132e3c21995893bb433744948a24ea8aee6716",
    "dmg_cpu_connections.html": "e070435eecf2136ea1485ef81c61e27c08885369ff49902fd8cd2cb582ee94db",
    "bootroms-readme.txt": "ae9fe35ce9d20ac1b869095645c7c3f7bb3858e36ae2ee0aee14218e84dc62ab",
}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def clean_text(raw: str) -> str:
    raw = re.sub(r"<script.*?</script>|<style.*?</style>", " ", raw, flags=re.DOTALL | re.IGNORECASE)
    raw = re.sub(r"<[^>]+>", " ", raw)
    return re.sub(r"\s+", " ", html.unescape(raw)).strip()


def check_checkout(name: str, root: Path) -> None:
    commit = subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()
    status = subprocess.check_output(["git", "-C", str(root), "status", "--porcelain"], text=True)
    assert commit == COMMITS[name], (name, commit, COMMITS[name])
    assert not status, (name, status)
    for relative, expected in HASHES[name].items():
        path = root / relative
        assert path.is_file(), path
        assert sha256(path) == expected, (path, sha256(path), expected)


def audit_gb_research(root: Path) -> None:
    readme = (root / "sm83-cpu-core/README.markdown").read_text()
    assert "SGB-CPU 01" in readme and "DMG-CPU B" in readme
    assert "non-synthesizable" in readme
    assert "implementation of propagation delays" in readme

    core = (root / "sm83-cpu-core/hdl/cpu_core.vhd").read_text()
    for port in (
        "reset_async", "reset_sync", "mclk_pulse", "phi", "writeback", "writeback_ext",
        "reset_ack", "wake", "nmi", "irq", "irq_ack", "m1", "wr", "rd", "memrq",
        "addr", "cpuclk_en", "sysclk_en",
    ):
        assert re.search(rf"\b{port}\b", core), port

    control = (root / "sm83-cpu-core/hdl/control_unit.vhd").read_text()
    required_control = (
        "cpuclk_shdn_req <= halt_req or stop_req or reset_async",
        "cpuclk_en <= not cpuclk_shdn",
        "sysclk_en <= not sysclk_shdn",
        "op_boundary <= (decoder.m1 and not phi and not decoder.op_cb_s0xx) or reset_op_int",
        "irq_begin <= not (",
        "op_di or",
        "startup_delay_m0 <= reset_ack nand reset_sync_n",
    )
    for fragment in required_control:
        assert fragment in control, fragment

    interrupts = (root / "sm83-cpu-core/hdl/interrupts.vhd").read_text()
    assert "irq_ack <= irq_prio and int_s110" in interrupts
    assert "intr_wake <= (or irq_latch) or nmi_dispatch" in interrupts
    assert "addr_ffff <= '1' when addr ?= X\"FFFF\"" in interrupts

    regfile = (root / "sm83-cpu-core/hdl/regfile.vhd").read_text()
    assert regfile.count("reset_sync") == 2  # port and the sole PC reset connection
    assert "set => reset_sync" in regfile

    soc = (root / "sm83-cpu-core/hdl/simulation/test_soc.vhd").read_text()
    phase_vectors = {
        "SEQ_CLK": "01111111",
        "SEQ_PHI": "11110000",
        "SEQ_MCLK_PULSE": "10000000",
        "SEQ_WRITEBACK": "00000011",
        "SEQ_WRITEBACK_EXT": "10000011",
    }
    for name, bits in phase_vectors.items():
        assert re.search(rf'{name}.*?:= "{bits}"', soc), (name, bits)


def audit_sameboy(root: Path) -> None:
    model = (root / "Core/model.h").read_text()
    assert "GB_MODEL_DMG_B = 0x002" in model
    assert "// GB_MODEL_DMG_C = 0x003" in model

    cpu = (root / "Core/sm83_cpu.c").read_text()
    required = (
        "speed_switch_halt_countdown = 0x20008",
        "Speed switch timing needs far more tests",
        "Timing is completely unverified",
        "TODO: verify the timing!",
        "Illegal Opcode. Halting.",
        "gb->interrupt_enable = 0",
        "gb->halt_bug = true",
        "cycle_write_if",
    )
    for fragment in required:
        assert fragment in cpu, fragment

    timing = (root / "Core/timing.c").read_text()
    assert "PHI does not run in halt nor stop mode" in timing
    assert "TODO: Verify what happens in STOP mode" in timing

    memory = (root / "Core/memory.c").read_text()
    for function in (
        "bitwise_glitch", "bitwise_glitch_read", "bitwise_glitch_read_secondary",
        "bitwise_glitch_tertiary_read_1", "bitwise_glitch_quaternary_read_dmg",
    ):
        assert f"{function}(" in memory
    assert "revision and instance specific" in memory
    assert "some cases are non-deterministic" in memory


def audit_microtests(root: Path) -> None:
    readme = (root / "README.md").read_text()
    assert "checked on real hardware" in readme
    assert "DMG-CPU-08 I believe" in readme
    sources = sorted((root / "tests").glob("*.s"))
    binaries = sorted((root / "bin").glob("*.gb"))
    assert len(sources) == 513, len(sources)
    assert len(list((root / "tests").iterdir())) == 515
    assert len(binaries) == 513, len(binaries)
    names = {path.stem for path in sources}
    for name in ("halt_op_dupe", "halt_op_dupe_delay", "poweron_div_004", "int_hblank_halt_scx4"):
        assert name in names


def audit_web_snapshots(root: Path) -> None:
    for name, expected in WEB_HASHES.items():
        path = root / name
        assert path.is_file(), path
        assert sha256(path) == expected, (path, sha256(path), expected)

    memory = clean_text((root / "mem_patterns.html").read_text(errors="replace"))
    for edge in ("T1F:", "T1R:", "T2F:", "T2R:", "T3F:", "T3R:", "T4F:", "T4R:"):
        assert edge in memory, edge
    assert "D0-D7 get sampled during read" in memory
    assert "All measurements were done on a DMG-CPU B" in memory
    assert "57358 clock cycles" in memory

    connections = clean_text((root / "dmg_cpu_connections.html").read_text(errors="replace"))
    required = (
        "The rising edge of this clock updates the DFF that stores the effective IME",
        "Registers and flags are written during the high phase of this clock",
        "CLK (T9) and CLK (T10) are the only clock inputs that are ticking during HALT mode",
        "program counter (PC) and the interrupt enable register (IE) are both reset to 0",
        "Other registers will have random values, including the instruction register",
        "Directly connected to an input pad at the top of the die, which is not bonded",
        "data on the bus is sampled for much longer",
        "works like an AND operation over time",
        "Wakes CPU from STOP mode",
    )
    for fragment in required:
        assert fragment in connections, fragment

    boot = (root / "bootroms-readme.txt").read_text(errors="replace")
    assert "cf053eccb4ccafff9e67339d4e78e98dce7d1ed59be819d2a1ba2232c6fce1c7  dmg_boot.bin" in boot


def main() -> None:
    if not __debug__:
        raise RuntimeError("audit assertions are disabled; do not run with python -O")
    parser = argparse.ArgumentParser()
    parser.add_argument("--gb-research-root", type=Path, required=True)
    parser.add_argument("--sameboy-root", type=Path, required=True)
    parser.add_argument("--microtest-root", type=Path, required=True)
    parser.add_argument("--web-snapshot-root", type=Path, required=True)
    args = parser.parse_args()

    roots = {
        "gb-research": args.gb_research_root,
        "SameBoy": args.sameboy_root,
        "GBMicrotest": args.microtest_root,
    }
    for name, root in roots.items():
        check_checkout(name, root)

    audit_gb_research(args.gb_research_root)
    audit_sameboy(args.sameboy_root)
    audit_microtests(args.microtest_root)
    audit_web_snapshots(args.web_snapshot_root)

    source_hashes = sum(len(files) for files in HASHES.values()) + len(WEB_HASHES)
    print(f"PASS three clean commits and {source_hashes} exact profile-source hashes")
    print("PASS DMG-CPU B reset, clock gates, IRQ/NMI, and eight half-edge bus anchors")
    print("PASS gb-research five phase vectors and processor/SoC port inventory")
    print("PASS SameBoy selected as DMG-B differential oracle with STOP/IF/OAM TODO quarantine")
    print("PASS GBMicrotest inventory: 513 test sources, 513 prebuilt real-hardware fixtures")
    print("PASS canonical DMG boot ROM SHA-256 identity anchor")
    print("NOTE DMG-CPU C is no longer the first profile; CGB STOP and lock-pin levels remain measured-evidence work")


if __name__ == "__main__":
    main()
