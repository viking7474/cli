#!/usr/bin/env python3
"""Bundle Swift back-deployment dylibs required by the iOS 13 CLI.

Swift concurrency is back-deployed to iOS 13 by Xcode as an @rpath dylib. A
normal app gets that dylib copied into its Frameworks directory by Xcode, but
icli is a bare rootful executable. Put any referenced back-deployment Swift
runtime dylibs in /usr/lib/icli and rely on the legacy executable's private
@executable_path/../lib/icli rpath.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess


def output(*args: str) -> str:
    return subprocess.check_output(list(args), text=True)


def linked_libraries(binary: Path) -> list[str]:
    return [line.strip().split(" (")[0] for line in output("otool", "-L", str(binary)).splitlines()[1:]]


def minimum_ios(binary: Path) -> tuple[int, ...]:
    text = output("xcrun", "vtool", "-show-build", str(binary))
    match = re.search(r"\bminos\s+(\d+(?:\.\d+){0,2})", text)
    if not match:
        legacy = re.search(
            r"cmd\s+LC_VERSION_MIN_IPHONEOS.*?\bversion\s+(\d+(?:\.\d+){0,2})",
            text,
            re.S,
        )
        match = legacy
    if not match:
        raise RuntimeError(f"could not determine deployment target for {binary}:\n{text}")
    return tuple(int(part) for part in match.group(1).split("."))


def version_at_most(actual: tuple[int, ...], requested: tuple[int, ...]) -> bool:
    width = max(len(actual), len(requested))
    return actual + (0,) * (width - len(actual)) <= requested + (0,) * (width - len(requested))


def rpaths(binary: Path) -> list[str]:
    text = output("otool", "-l", str(binary))
    paths: list[str] = []
    lines = text.splitlines()
    for index, line in enumerate(lines):
        if line.strip() != "cmd LC_RPATH":
            continue
        for candidate in lines[index + 1:index + 5]:
            match = re.search(r"\bpath\s+(.+?)\s+\(offset", candidate.strip())
            if match:
                paths.append(match.group(1))
                break
    return paths


def backdeploy_candidates(toolchain: Path, name: str) -> list[Path]:
    lib = toolchain / "usr/lib"
    candidates = sorted(lib.glob(f"swift-*/iphoneos/{name}"))
    return [candidate for candidate in candidates if candidate.is_file()]


def choose_candidate(toolchain: Path, name: str, target: tuple[int, ...]) -> Path | None:
    compatible: list[tuple[tuple[int, ...], Path]] = []
    for candidate in backdeploy_candidates(toolchain, name):
        candidate_min = minimum_ios(candidate)
        if version_at_most(candidate_min, target):
            compatible.append((candidate_min, candidate))
    if not compatible:
        return None
    # Prefer the lowest deployment floor; for equal floors prefer the newest
    # toolchain compatibility directory name deterministically.
    compatible.sort(key=lambda item: (item[0], str(item[1])))
    floor = compatible[0][0]
    return [path for minos, path in compatible if minos == floor][-1]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("stage", type=Path, help="Root of the DEB staging tree")
    parser.add_argument("--minimum-ios", default="13.0")
    parser.add_argument("--manifest", type=Path, default=Path(".build/swift-runtime-ios13.json"))
    args = parser.parse_args()

    binary = args.binary.resolve()
    stage = args.stage.resolve()
    target = tuple(int(part) for part in args.minimum_ios.split("."))
    if not binary.is_file():
        raise SystemExit(f"binary not found: {binary}")

    swift = Path(output("xcrun", "--find", "swift").strip()).resolve()
    toolchain = swift.parents[2]
    destination = stage / "usr/lib/icli"

    initial = [name.removeprefix("@rpath/") for name in linked_libraries(binary)
               if name.startswith("@rpath/libswift") and name.endswith(".dylib")]
    queue = list(dict.fromkeys(initial))
    copied: dict[str, dict[str, object]] = {}
    system_runtime: list[str] = []

    while queue:
        name = queue.pop(0)
        if name in copied or name in system_runtime:
            continue
        candidate = choose_candidate(toolchain, name, target)
        if candidate is None:
            system_runtime.append(name)
            continue

        destination.mkdir(parents=True, exist_ok=True)
        installed = destination / name
        shutil.copy2(candidate, installed)
        subprocess.check_call(["ldid", "-S", str(installed)])
        installed.chmod(0o755)
        minos = minimum_ios(candidate)
        copied[name] = {
            "file": f"/usr/lib/icli/{name}",
            "minimum_ios": ".".join(map(str, minos)),
            "sha256": hashlib.sha256(installed.read_bytes()).hexdigest(),
        }
        for dependency in linked_libraries(candidate):
            if dependency.startswith("@rpath/libswift") and dependency.endswith(".dylib"):
                child = dependency.removeprefix("@rpath/")
                if child not in copied and child not in queue:
                    queue.append(child)

    if "libswift_Concurrency.dylib" in initial and "libswift_Concurrency.dylib" not in copied:
        raise SystemExit(
            "legacy binary references @rpath/libswift_Concurrency.dylib but Xcode did not provide "
            "an iOS 13-compatible back-deployment copy"
        )

    required_rpath = "@executable_path/../lib/icli"
    binary_rpaths = rpaths(binary)
    if copied and required_rpath not in binary_rpaths:
        raise SystemExit(
            f"legacy binary needs bundled Swift runtime but is missing LC_RPATH {required_rpath}; "
            f"found: {binary_rpaths}"
        )

    manifest = {
        "minimum_ios": args.minimum_ios,
        "binary": str(binary),
        "rpaths": binary_rpaths,
        "referenced_swift_rpath_libraries": initial,
        "bundled": [dict(name=name, **metadata) for name, metadata in sorted(copied.items())],
        "system_runtime": sorted(system_runtime),
    }
    args.manifest.parent.mkdir(parents=True, exist_ok=True)
    args.manifest.write_text(json.dumps(manifest, indent=2) + "\n")
    print(
        "Swift runtime: bundled "
        + (", ".join(sorted(copied)) if copied else "none")
        + "; system "
        + (", ".join(sorted(system_runtime)) if system_runtime else "none")
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
