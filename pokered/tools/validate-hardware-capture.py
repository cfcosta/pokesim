#!/usr/bin/env python3
"""Validate a DMG-CPU B hardware-capture manifest and retained artifacts."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path, PurePosixPath
from typing import Any

SHA256 = re.compile(r"^[0-9a-f]{64}$")
BOOT_SHA256 = "cf053eccb4ccafff9e67339d4e78e98dce7d1ed59be819d2a1ba2232c6fce1c7"
GROUPS = {
    "phase", "read-fold", "reset", "halt", "stop", "interrupt",
    "invalid-lock", "oam-idu", "canonical-red",
}
REQUIRED_CHANNELS = {"PHI", "/RD", "/WR", "/CS", "RESET"}
REQUIRED_CHANNELS |= {f"A{i}" for i in range(16)}
REQUIRED_CHANNELS |= {f"D{i}" for i in range(8)}
CLASSIFICATIONS = {"deterministic-fixture", "family-relation", "negative", "inconclusive"}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def require_keys(value: dict[str, Any], required: set[str], allowed: set[str], where: str) -> None:
    require(required <= value.keys(), f"{where}: missing {sorted(required - value.keys())}")
    require(value.keys() <= allowed, f"{where}: unexpected {sorted(value.keys() - allowed)}")


def require_sha(value: Any, where: str) -> str:
    require(isinstance(value, str) and SHA256.fullmatch(value) is not None, f"{where}: invalid SHA-256")
    return value


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def resolve_artifact(root: Path, relative: Any, where: str) -> Path:
    require(isinstance(relative, str) and relative, f"{where}: empty path")
    pure = PurePosixPath(relative)
    require(not pure.is_absolute() and ".." not in pure.parts, f"{where}: path escapes artifact root")
    path = root.joinpath(*pure.parts)
    require(path.is_file(), f"{where}: missing artifact {path}")
    return path


def validate(manifest: dict[str, Any], artifact_root: Path) -> tuple[int, int]:
    top_required = {"schemaVersion", "profile", "fixture", "environment", "program", "captureSetup", "runs", "analysis"}
    require_keys(manifest, top_required, top_required | {"signature"}, "manifest")
    require(manifest["schemaVersion"] == 1, "manifest: unsupported schemaVersion")
    require(manifest["profile"] == "DmgCpuBCommonBoot", "manifest: wrong profile")

    fixture = manifest["fixture"]
    require(isinstance(fixture, dict), "fixture: expected object")
    fixture_required = {"id", "consoleSerial", "socMarking", "socPhotoSha256", "mainboardRevision", "partMarkings"}
    require_keys(fixture, fixture_required, fixture_required | {"packageType"}, "fixture")
    require(fixture["socMarking"] == "DMG-CPU B", "fixture: SoC marking must be DMG-CPU B")
    require_sha(fixture["socPhotoSha256"], "fixture.socPhotoSha256")
    require(isinstance(fixture["partMarkings"], dict) and len(fixture["partMarkings"]) >= 2,
            "fixture.partMarkings: identify at least RAM and VRAM")

    environment = manifest["environment"]
    require(isinstance(environment, dict), "environment: expected object")
    environment_required = {"capturedAt", "operator", "supplyMillivolts", "temperatureCelsius"}
    require_keys(environment, environment_required, environment_required | {"notes"}, "environment")
    require(4500 <= environment["supplyMillivolts"] <= 5500, "environment: supply outside profile bounds")
    require(0 <= environment["temperatureCelsius"] <= 50, "environment: temperature outside profile bounds")

    program = manifest["program"]
    require(isinstance(program, dict), "program: expected object")
    program_keys = {"sourceSha256", "romSha256", "bootRomSha256", "toolchain"}
    require_keys(program, program_keys, program_keys, "program")
    require_sha(program["sourceSha256"], "program.sourceSha256")
    require_sha(program["romSha256"], "program.romSha256")
    require(program["bootRomSha256"] == BOOT_SHA256, "program: wrong DMG boot-ROM identity")
    require(isinstance(program["toolchain"], dict) and program["toolchain"], "program.toolchain: empty")

    setup = manifest["captureSetup"]
    require(isinstance(setup, dict), "captureSetup: expected object")
    setup_required = {"interposerRevision", "fpgaBitstreamSha256", "analyzer", "digitalSampleRateHz", "channels", "calibrationSha256"}
    require_keys(setup, setup_required, setup_required | {"analogSampleRateHz", "probeLoading"}, "captureSetup")
    require_sha(setup["fpgaBitstreamSha256"], "captureSetup.fpgaBitstreamSha256")
    require_sha(setup["calibrationSha256"], "captureSetup.calibrationSha256")
    require(isinstance(setup["digitalSampleRateHz"], int) and setup["digitalSampleRateHz"] >= 100_000_000,
            "captureSetup: digital sample rate below 100 MS/s")
    channels = setup["channels"]
    require(isinstance(channels, list) and len(channels) == len(set(channels)), "captureSetup.channels: duplicate/non-list")
    require(REQUIRED_CHANNELS <= set(channels), f"captureSetup.channels: missing {sorted(REQUIRED_CHANNELS - set(channels))}")

    runs = manifest["runs"]
    require(isinstance(runs, list) and runs, "runs: expected nonempty array")
    run_ids: set[str] = set()
    run_group: dict[str, str] = {}
    artifact_count = 0
    for index, run in enumerate(runs):
        where = f"runs[{index}]"
        require(isinstance(run, dict), f"{where}: expected object")
        required = {"id", "group", "repetition", "stimulus", "rawFiles", "expectedRelation"}
        require_keys(run, required, required | {"notes"}, where)
        run_id = run["id"]
        require(isinstance(run_id, str) and run_id and run_id not in run_ids, f"{where}: duplicate/empty id")
        run_ids.add(run_id)
        require(run["group"] in GROUPS, f"{where}: unknown group")
        run_group[run_id] = run["group"]
        require(isinstance(run["repetition"], int) and run["repetition"] >= 1, f"{where}: bad repetition")
        require(isinstance(run["stimulus"], dict), f"{where}: stimulus must be object")
        require(isinstance(run["expectedRelation"], str) and run["expectedRelation"], f"{where}: empty relation")
        files = run["rawFiles"]
        require(isinstance(files, list) and files, f"{where}: no raw files")
        for file_index, item in enumerate(files):
            file_where = f"{where}.rawFiles[{file_index}]"
            require(isinstance(item, dict), f"{file_where}: expected object")
            require_keys(item, {"path", "sha256", "format"}, {"path", "sha256", "format"}, file_where)
            expected = require_sha(item["sha256"], f"{file_where}.sha256")
            path = resolve_artifact(artifact_root, item["path"], file_where)
            require(file_sha256(path) == expected, f"{file_where}: artifact hash mismatch")
            artifact_count += 1

    analysis = manifest["analysis"]
    require(isinstance(analysis, dict), "analysis: expected object")
    analysis_keys = {"scriptSha256", "independentAnalysisSha256", "claims"}
    require_keys(analysis, analysis_keys, analysis_keys, "analysis")
    primary = require_sha(analysis["scriptSha256"], "analysis.scriptSha256")
    independent = require_sha(analysis["independentAnalysisSha256"], "analysis.independentAnalysisSha256")
    require(primary != independent, "analysis: independent analysis must be a distinct artifact")
    claims = analysis["claims"]
    require(isinstance(claims, list), "analysis.claims: expected array")
    claim_ids: set[str] = set()
    for index, claim in enumerate(claims):
        where = f"analysis.claims[{index}]"
        require(isinstance(claim, dict), f"{where}: expected object")
        keys = {"id", "classification", "runIds", "statement"}
        require_keys(claim, keys, keys, where)
        claim_id = claim["id"]
        require(isinstance(claim_id, str) and claim_id and claim_id not in claim_ids, f"{where}: duplicate/empty id")
        claim_ids.add(claim_id)
        require(claim["classification"] in CLASSIFICATIONS, f"{where}: bad classification")
        refs = claim["runIds"]
        require(isinstance(refs, list) and refs and len(refs) == len(set(refs)), f"{where}: bad runIds")
        require(set(refs) <= run_ids, f"{where}: unknown runIds {sorted(set(refs) - run_ids)}")
        require(isinstance(claim["statement"], str) and claim["statement"], f"{where}: empty statement")
        if claim["classification"] == "deterministic-fixture":
            require(len(refs) >= 2, f"{where}: deterministic claim needs repeated runs")
        if any(run_group[run_id] == "reset" for run_id in refs) and claim["classification"] == "deterministic-fixture":
            require(len(refs) >= 256, f"{where}: deterministic reset claim needs 256 runs")

    if "signature" in manifest:
        signature = manifest["signature"]
        require(isinstance(signature, dict), "signature: expected object")
        keys = {"algorithm", "publicKeyId", "value"}
        require_keys(signature, keys, keys, "signature")
        for key in keys:
            require(isinstance(signature[key], str) and signature[key], f"signature.{key}: empty")

    return len(runs), artifact_count


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--artifact-root", type=Path)
    args = parser.parse_args()
    manifest_path = args.manifest.resolve()
    artifact_root = (args.artifact_root or manifest_path.parent).resolve()
    manifest = json.loads(manifest_path.read_text())
    require(isinstance(manifest, dict), "manifest root must be an object")
    run_count, artifact_count = validate(manifest, artifact_root)
    print(f"PASS profile=DmgCpuBCommonBoot runs={run_count} retained_artifacts={artifact_count}")


if __name__ == "__main__":
    main()
