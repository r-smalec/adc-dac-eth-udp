#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Retain scoped build/test evidence in the knowledge base, excluding HDL copies."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]
KB = ROOT.parents[1]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def copy_cases(build, destination):
    report = json.loads((build / "simulation.json").read_text(encoding="utf-8"))
    for case in report["cases"]:
        source = build / "sim" / case["name"]
        target = destination / case["name"]
        target.mkdir(parents=True, exist_ok=True)
        for name in ("compile.log", "run.log", "frames.hex", "capture.pcap"):
            if (source / name).is_file():
                shutil.copy2(source / name, target / name)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-commit", required=True, help="Local Git commit containing the tested example")
    args = parser.parse_args()
    if len(args.source_commit) != 40 or any(c not in "0123456789abcdef" for c in args.source_commit):
        raise ValueError("--source-commit must be a full Git commit hash")
    build = ROOT / "build"
    target = KB / "reports/ad9226-udp"
    target.mkdir(parents=True, exist_ok=True)
    patched = copy_cases(build, target / "simulation")
    negative = copy_cases(build / "unpatched", target / "unpatched")
    if len(patched["cases"]) != 10 or any(c["status"] != "passed" for c in patched["cases"]):
        raise ValueError("Expected all ten patched simulation cases to pass")
    if len(negative["cases"]) != 2 or any(c["status"] != "failed" for c in negative["cases"]):
        raise ValueError("Expected two failed reproductions of unmodified upstream")
    shutil.copy2(build / "simulation.json", target / "simulation.json")
    shutil.copy2(build / "unpatched/simulation.json", target / "unpatched-simulation.json")
    shutil.copy2(build / "manifest.json", target / "dependency-manifest.json")
    vivado = target / "vivado"
    vivado.mkdir(exist_ok=True)
    for path in (build / "vivado").glob("*.rpt"):
        shutil.copy2(path, vivado / path.name)
    log = ROOT / "vivado.log"
    if "AD9226_BUILD_COMPLETE stage=bitstream" not in log.read_text(encoding="utf-8", errors="replace"):
        raise ValueError("Vivado did not complete the bitstream stage")
    shutil.copy2(log, vivado / "vivado.log")
    bitstream = build / "vivado/arty_ad9226_udp.bit"
    inputs = [ROOT / "config.tcl", ROOT / "dependencies.json", ROOT / "patches/fifo_to_udp.patch.json"]
    for directory, pattern in (("rtl", "*.sv"), ("constraints", "*"), ("tests", "*.sv"),
                               ("scripts", "*.py"), ("scripts", "*.tcl"), ("host", "*.py")):
        inputs.extend(p for p in (ROOT / directory).glob(pattern) if p.is_file())
    summary = {
        "date": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "source_commit": args.source_commit,
        "publication": "Local Git commit; no push or remote availability is claimed",
        "fpga": "xc7a35ticsg324-1L, Arty A7-35T",
        "vivado": "Vivado 2024.2, Build 5239630",
        "build_command": "vivado -mode batch -source scripts/build.tcl -tclargs xc7a35ticsg324-1L bitstream",
        "build_cwd": "examples/ad9226-udp",
        "hardware_execution": False,
        "source_files": [{"path": p.relative_to(KB).as_posix(), "sha256": digest(p)} for p in sorted(set(inputs))],
        "bitstream": {"path": bitstream.relative_to(KB).as_posix(), "bytes": bitstream.stat().st_size,
                      "sha256": digest(bitstream), "retained_in_git": False},
    }
    (target / "build-manifest.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    artifacts = [{"path": p.relative_to(target).as_posix(), "sha256": digest(p)}
                 for p in sorted(target.rglob("*")) if p.is_file() and p.name != "artifact-manifest.json"]
    (target / "artifact-manifest.json").write_text(json.dumps(artifacts, indent=2) + "\n", encoding="utf-8")
    print(f"Retained {len(artifacts)} artifacts in {target}")


if __name__ == "__main__":
    main()
