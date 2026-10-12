#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Verify packet bytes, MII CRC/IFG, ADC ordering, overflow and PHY setup."""
import argparse
import datetime
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import zlib

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("ad9226_receive", ROOT / "host/receive.py")
receiver = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = receiver
spec.loader.exec_module(receiver)


def checksum(data):
    if len(data) % 2:
        data += b"\0"
    value = sum(struct.unpack(f"!{len(data)//2}H", data))
    while value >> 16:
        value = (value & 0xffff) + (value >> 16)
    return (~value) & 0xffff


def check_network(frame):
    if len(frame) < 42:
        raise AssertionError("Ethernet/IP/UDP headers truncated")
    assert frame[:6] == bytes.fromhex("020000000002"), "Wrong destination MAC"
    assert frame[6:12] == bytes.fromhex("020000000001"), "Wrong source MAC"
    assert frame[12:14] == b"\x08\x00", "Unexpected EtherType (ARP is not permitted)"
    ip = frame[14:34]
    assert ip[0] == 0x45 and ip[9] == 17, "Wrong IPv4 version/IHL/protocol"
    assert checksum(ip) == 0, "Invalid IPv4 header checksum"
    assert ip[12:20] == bytes.fromhex("c0a80a02c0a80a01"), "Wrong IP addresses"
    ip_length = struct.unpack_from("!H", ip, 2)[0]
    assert ip_length == len(frame)-14, f"IPv4 length {ip_length} != actual {len(frame)-14}"
    source_port, dest_port, udp_length, udp_checksum = struct.unpack_from("!HHHH", frame, 34)
    assert source_port == 0 and dest_port == 5000, "Wrong UDP ports"
    assert udp_checksum == 0, "Expected IPv4 UDP checksum disabled"
    assert udp_length == len(frame)-34, f"UDP length {udp_length} != actual {len(frame)-34}"
    assert ip_length <= 1500, "IPv4 datagram exceeds MTU 1500"
    return frame[42:]


def write_pcap(path, frames):
    with path.open("wb") as output:
        output.write(struct.pack("<IHHIIII", 0xa1b2c3d4, 2, 4, 0, 0, 65535, 1))
        for i, frame in enumerate(frames):
            output.write(struct.pack("<IIII", 0, i, len(frame), len(frame)))
            output.write(frame)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verilator", default=shutil.which("verilator_bin") or shutil.which("verilator"))
    parser.add_argument("--build-dir", type=Path, default=ROOT / "build")
    parser.add_argument("--case", help="Run one named case")
    parser.add_argument("--unpatched", action="store_true", help="Run negative upstream reproduction cases")
    args = parser.parse_args()
    if not args.verilator:
        raise RuntimeError("Verilator with --binary and a C++20 compiler are required")
    build = args.build_dir.resolve()
    if not (build / "manifest.json").exists():
        raise RuntimeError("Run scripts/prepare.py first")
    manifest = json.loads((build / "manifest.json").read_text(encoding="utf-8"))
    if args.unpatched == manifest["patched"]:
        raise RuntimeError("--unpatched must agree with the prepared dependency manifest")
    env = dict(os.environ)
    verilator = Path(args.verilator).resolve()
    bundled_root = verilator.parent.parent / "share/verilator"
    if bundled_root.is_dir():
        env.setdefault("VERILATOR_ROOT", bundled_root.as_posix())
    if os.name == "nt":
        # OSS CAD Suite's Windows binary needs a modern compiler, not an old
        # MinGW installation that may precede MSYS2 in PATH.
        for prefix in (Path("C:/msys64/ucrt64/bin"), Path("C:/msys64/mingw64/bin")):
            if (prefix / "g++.exe").exists():
                env["PATH"] = str(prefix) + os.pathsep + env["PATH"]
                break
    common_sources = (build / "sources.f").read_text(encoding="utf-8").splitlines()
    cases = [
        ("packetizer_lengths", "tb_packetizer", {}),
        ("packetizer_backpressure", "tb_packetizer", {"STALL": 1}),
        ("nominal", "tb_ad9226_udp", {}),
        ("non_power_decimation", "tb_ad9226_udp", {"DECIMATION": 13, "SAMPLES": 64}),
        ("small_packet", "tb_ad9226_udp", {"DECIMATION": 256, "SAMPLES": 2}),
        ("large_packet", "tb_ad9226_udp", {"SAMPLES": 720, "TARGET_FRAMES": 4}),
        ("test_ramp", "tb_ad9226_udp", {"TEST_PATTERN": 1, "SAMPLES": 64}),
        ("whole_frame_overflow", "tb_ad9226_udp", {"DECIMATION": 8, "SAMPLES": 64,
            "SAMPLE_FIFO_BYTES": 1024, "TX_FIFO_BYTES": 512, "HOLD_TX_CYCLES": 50000, "TARGET_FRAMES": 24}),
        ("reset_during_frame", "tb_ad9226_udp", {"RESET_DURING_FRAME": 1, "SAMPLES": 64}),
        ("phy_mdio", "tb_dp83848", {}),
    ]
    if args.unpatched:
        cases = cases[:2]
    if args.case:
        cases = [case for case in cases if case[0] == args.case]
        if not cases:
            raise ValueError("Unknown case name")
    results = []
    report = {
        "date": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "manifest": manifest,
        "verilator": subprocess.run([str(verilator), "--version"], env=env, capture_output=True, text=True).stdout.strip(),
        "scope": "RTL simulation: core to MII wire bytes and MDIO model; no FPGA hardware execution",
        "cases": results,
    }
    sim_root = build / "sim"
    sim_root.mkdir(exist_ok=True)
    failures = 0
    for name, top, params in cases:
        directory = sim_root / name
        directory.mkdir(exist_ok=True)
        source = ROOT / "tests" / f"{top}.sv"
        sources = [(ROOT / "rtl/dp83848_init.sv").as_posix()] if top == "tb_dp83848" else common_sources
        command = [str(verilator), "--binary", "--timing", "--assert", "-j", "2", "-Wno-fatal",
                   "-Wno-PINMISSING", "-Wno-WIDTHEXPAND", "-Wno-WIDTHTRUNC",
                   "--top-module", top, "--Mdir", directory.as_posix()]
        command += [f"-G{key}={value}" for key, value in params.items()]
        command += sources + [source.as_posix()]
        case = {"name": name, "parameters": params, "command": command, "status": "failed"}
        results.append(case)
        print(f"Building/running {name}", flush=True)
        try:
            compiled = subprocess.run(command, cwd=ROOT, env=env, capture_output=True, text=True, errors="replace")
            (directory / "compile.log").write_text(compiled.stdout + compiled.stderr, encoding="utf-8")
            case["compile_exit"] = compiled.returncode
            if compiled.returncode:
                raise RuntimeError("Compilation failed; see compile.log")
            executable = directory / f"V{top}{'.exe' if os.name == 'nt' else ''}"
            capture = directory / "frames.hex"
            run_command = [str(executable), f"+OUTPUT={capture.as_posix()}"]
            case["run_command"] = run_command
            run = subprocess.run(run_command, cwd=directory, env=env, capture_output=True, text=True, errors="replace")
            (directory / "run.log").write_text(run.stdout + run.stderr, encoding="utf-8")
            case["run_exit"] = run.returncode
            case["output"] = run.stdout + run.stderr
            if run.returncode:
                raise RuntimeError("RTL assertion failed; see run.log")
            if top == "tb_packetizer":
                frame = bytes.fromhex(capture.read_text(encoding="utf-8").strip())
                payload = check_network(frame)
                assert payload == bytes.fromhex("00000123456789abcdef"), "Wrong packetizer payload/ordering"
                case["frame_bytes"] = len(frame)
            elif top == "tb_ad9226_udp":
                frames, block_ids = [], []
                expected_samples = params.get("SAMPLES", 512)
                decimation = params.get("DECIMATION", 16)
                for line in capture.read_text(encoding="utf-8").splitlines():
                    if "RESET" in line:
                        assert params.get("RESET_DURING_FRAME"), "Unexpected aborted frame"
                        continue
                    wire_frame = bytes.fromhex(line)
                    assert wire_frame[:8] == b"\x55" * 7 + b"\xd5", "Bad Ethernet preamble/SFD"
                    frame, fcs = wire_frame[8:-4], wire_frame[-4:]
                    assert len(frame) >= 60, "Ethernet frame not padded to minimum length"
                    assert fcs == struct.pack("<I", zlib.crc32(frame)), "Bad Ethernet CRC32/FCS"
                    payload = check_network(frame)
                    block = receiver.decode_payload(payload)
                    assert len(block.samples) == expected_samples and block.decimation == decimation
                    assert block.udp_sequence == len(frames) % 65536, "UDP packet sequence discontinuity"
                    assert block.first_index == (block.block_sequence * expected_samples * decimation) & 0xffffffff
                    for i, word in enumerate(block.samples):
                        index = (block.first_index + i * decimation) & 0xffffffff
                        if params.get("TEST_PATTERN"):
                            expected = 0x2000 | (index & 0xfff)
                        else:
                            expected = ((index & 0xfff) ^ 0x5a5) | (((index >> 5) & 1) << 12)
                        assert word == expected, f"Corrupt/reordered ADC sample at index {index}: {word:04x}!={expected:04x}"
                    if block_ids:
                        assert block.block_sequence > block_ids[-1], "Duplicate or reordered acquisition block"
                    block_ids.append(block.block_sequence)
                    frames.append(frame)
                match = re.search(r"dropped_blocks=(\d+)", run.stdout)
                drops = int(match.group(1)) if match else 0
                if name == "whole_frame_overflow":
                    assert drops > 0 and any(b-a > 1 for a, b in zip(block_ids, block_ids[1:])), "Whole-frame loss was not exercised"
                else:
                    assert drops == 0, "Unexpected FIFO overflow"
                assert len(frames) == params.get("TARGET_FRAMES", 8)
                write_pcap(directory / "capture.pcap", frames)
                case.update(frames=len(frames), samples_verified=len(frames)*expected_samples,
                            dropped_blocks=drops, block_ids=block_ids)
            case["status"] = "passed"
            print(f"PASS {name}", flush=True)
        except (RuntimeError, AssertionError, ValueError) as error:
            failures += 1
            case["error"] = str(error)
            print(f"FAIL {name}: {error}", flush=True)
        (build / "simulation.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"{len(cases)-failures}/{len(cases)} passed; report: {build / 'simulation.json'}", flush=True)
    return bool(failures)


if __name__ == "__main__":
    sys.exit(main())
