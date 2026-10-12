#!/usr/bin/env python3
"""Fetch pinned dependencies outside the KB and prepare reproducible HDL inputs."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def execute(command, **kwargs):
    result = subprocess.run([str(x) for x in command], text=True, encoding="utf-8",
                            errors="replace", capture_output=True, **kwargs)
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}): {command}\n{result.stdout}\n{result.stderr}")
    return result


def git(path, *args):
    return execute(["git", "-c", f"safe.directory={path.as_posix()}", "-C", path, *args])


def checkout(cache, name, entry):
    path = cache / name
    if not path.exists():
        cache.mkdir(parents=True, exist_ok=True)
        execute(["git", "clone", "--filter=blob:none", "--no-checkout", entry["repository"], path])
        git(path, "checkout", "--detach", entry["revision"])
    if git(path, "rev-parse", "HEAD").stdout.strip() != entry["revision"]:
        raise RuntimeError(f"{path}: wrong revision; use a separate --deps-dir (existing checkout preserved)")
    if git(path, "status", "--porcelain", "--untracked-files=no").stdout.strip():
        raise RuntimeError(f"{path}: modified dependency; refusing an unrecorded source change")
    return path


def taxi_sources(root, roots):
    """Resolve upstream .f recipes, including Git symlinks materialized as files on Windows."""
    sources, seen = [], set()

    def visit(path):
        path = path.resolve()
        if not path.is_relative_to(root.resolve()):
            raise ValueError(f"Dependency recipe escapes checkout: {path}")
        if path in seen:
            return
        seen.add(path)
        if path.suffix == ".f":
            for line in path.read_text(encoding="utf-8").splitlines():
                line = line.split("#", 1)[0].strip()
                if not line:
                    continue
                if "lib/taxi/" in line:
                    child = root / line.split("lib/taxi/", 1)[1]
                else:
                    child = path.parent / line
                visit(child)
        else:
            if not path.is_file():
                raise ValueError(f"Missing upstream source: {path}")
            sources.append(path)

    for recipe in roots:
        visit(root / recipe)
    # Interface definitions precede modules; order of the remaining files is stable.
    sources.sort(key=lambda p: (p.name != "taxi_axis_if.sv", p.as_posix()))
    return sources


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--deps-dir", type=Path,
                        default=Path(tempfile.gettempdir()) / "gateware-ad9226-deps")
    parser.add_argument("--build-dir", type=Path, default=ROOT / "build")
    parser.add_argument("--unpatched", action="store_true", help="Reproduce upstream defects; not a production build")
    parser.add_argument("--ghdl", default=shutil.which("ghdl"))
    args = parser.parse_args()
    if not args.ghdl:
        raise RuntimeError("GHDL with Verilog synthesis output is required; add ghdl to PATH")
    cache = args.deps_dir.resolve()
    if cache.is_relative_to(ROOT.parents[1].resolve()):
        raise ValueError("Third-party checkouts must remain outside the knowledge-base repository")
    build = args.build_dir.resolve()
    build.mkdir(parents=True, exist_ok=True)
    lock = json.loads((ROOT / "dependencies.json").read_text(encoding="utf-8"))
    dependencies = {name: checkout(cache, name, entry) for name, entry in lock.items()}
    sources = taxi_sources(dependencies["taxi"], lock["taxi"]["roots"])
    upstream = dependencies["wzab-hdl-library"] / lock["wzab-hdl-library"]["source"]
    source = upstream.read_text(encoding="utf-8")
    patch = ROOT / "patches/fifo_to_udp.patch.json"
    if not args.unpatched:
        for change in json.loads(patch.read_text(encoding="utf-8"))["changes"]:
            if source.count(change["old"]) != change["count"]:
                raise ValueError(f"Patch context mismatch: {change['old']!r}")
            source = source.replace(change["old"], change["new"])
    derived = build / "fifo_to_udp.vhd"
    derived.write_text(source, encoding="utf-8", newline="\n")
    result = execute([args.ghdl, "--synth", "--std=08", "--out=verilog", "-gcount_width=12",
                      derived, "-e", "fifo_to_udp"], cwd=build)
    converted = build / "fifo_to_udp.v"
    converted.write_text(result.stdout, encoding="utf-8", newline="\n")
    (build / "ghdl-synthesis.log").write_text(result.stderr, encoding="utf-8")
    local_sources = [ROOT / "rtl" / name for name in
                     ("ad9226_frame_source.sv", "ad9226_udp_core.sv", "dp83848_init.sv", "arty_ad9226_udp.sv")]
    all_sources = sources + [converted] + local_sources
    (build / "sources.f").write_text("\n".join(p.as_posix() for p in all_sources) + "\n", encoding="utf-8")
    tcl = "set ad9226_sources {\n" + "".join(f"    {{{p.as_posix()}}}\n" for p in all_sources) + "}\n"
    tcl += f"set taxi_root {{{dependencies['taxi'].as_posix()}}}\n"
    (build / "sources.tcl").write_text(tcl, encoding="utf-8")
    manifest = {
        "dependencies": lock,
        "patched": not args.unpatched,
        "upstream_vhdl_sha256": sha256(upstream),
        "patch_sha256": sha256(patch),
        "derived_vhdl_sha256": sha256(derived),
        "derived_verilog_sha256": sha256(converted),
        "ghdl_version": execute([args.ghdl, "--version"]).stdout.strip(),
        "taxi_sources": [{"path": p.relative_to(dependencies["taxi"]).as_posix(),
                          "sha256": sha256(p),
                          "license_notice": p.read_text(encoding="utf-8").splitlines()[0]} for p in sources],
        "local_sources": [{"path": p.relative_to(ROOT).as_posix(), "sha256": sha256(p)} for p in local_sources],
    }
    (build / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"Prepared {len(sources)} pinned Taxi source files and {'unpatched' if args.unpatched else 'patched'} WZab packetizer.")
    print(f"Build inputs: {build}")


if __name__ == "__main__":
    main()
