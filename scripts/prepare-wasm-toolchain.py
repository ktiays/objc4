#!/usr/bin/env python3
"""Download the pinned SDK, patch Clang, and build the Wasm compiler tools."""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import shutil
import subprocess
import sys
import tarfile
import urllib.request


if sys.version_info < (3, 12):
    for interpreter in ("python3.14", "python3.13", "python3.12"):
        executable = shutil.which(interpreter)
        if executable:
            os.execv(executable, [executable, *sys.argv])
    sys.exit("Python 3.12 or newer is required for safe archive extraction")


REPOSITORY = Path(__file__).resolve().parent.parent
TOOLCHAIN = REPOSITORY / "toolchains" / "wasm"


def run(arguments, **kwargs):
    print("+ " + shlex.join(str(value) for value in arguments), flush=True)
    subprocess.run(arguments, check=True, **kwargs)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download(specification, downloads):
    archive = downloads / specification["archive"]
    if archive.exists():
        if sha256(archive) != specification["sha256"]:
            raise RuntimeError(f"Checksum mismatch: {archive}")
        return archive
    partial = archive.with_name(archive.name + ".partial")
    print(f"Downloading {specification['url']}", flush=True)
    with urllib.request.urlopen(specification["url"], timeout=120) as source:
        with partial.open("wb") as destination:
            shutil.copyfileobj(source, destination, 1024 * 1024)
    if sha256(partial) != specification["sha256"]:
        partial.unlink()
        raise RuntimeError(f"Checksum mismatch: {archive.name}")
    partial.replace(archive)
    return archive


def extract(archive, destination, expected_directory):
    marker = destination / ".archive-sha256"
    checksum = sha256(archive)
    if marker.exists():
        if marker.read_text().strip() != checksum:
            raise RuntimeError(f"Archive changed; use a fresh toolchain directory: {destination}")
        return
    if expected_directory.exists():
        raise RuntimeError(f"Unverified extraction already exists: {expected_directory}")
    temporary = destination.with_name(destination.name + ".extracting")
    if temporary.exists():
        shutil.rmtree(temporary)
    temporary.mkdir(parents=True)
    print(f"Extracting {archive.name}", flush=True)
    with tarfile.open(archive) as source:
        source.extractall(temporary, filter="data")
    (temporary / ".archive-sha256").write_text(checksum + "\n")
    if destination.exists():
        destination.rmdir()
    temporary.replace(destination)


def patch_sources(source, patch_files):
    for patch in patch_files:
        # Check the reverse first so an interrupted preparation can resume.
        reverse = subprocess.run(
            ["git", "apply", "--reverse", "--check", str(patch)],
            cwd=source, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        if reverse.returncode == 0:
            continue
        run(["git", "apply", "--check", str(patch)], cwd=source)
        run(["git", "apply", str(patch)], cwd=source)


def input_fingerprint():
    names = (TOOLCHAIN / "patches" / "series").read_text().splitlines()
    patches = [TOOLCHAIN / "patches" / name.strip()
               for name in names if name.strip() and not name.startswith("#")]
    digest = hashlib.sha256((TOOLCHAIN / "versions.json").read_bytes())
    digest.update(Path(__file__).read_bytes())
    for patch in patches:
        digest.update(patch.read_bytes())
    return patches, digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=REPOSITORY / "build" / "wasm-toolchain")
    parser.add_argument("--jobs", type=int, default=min(os.cpu_count() or 1, 8))
    parser.add_argument("--node", default=shutil.which("node"))
    parser.add_argument("--download-only", action="store_true")
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--check", action="store_true", help="Check the build fingerprint without downloading or building")
    options = parser.parse_args()
    if options.jobs < 1:
        parser.error("--jobs must be positive")
    if not options.node:
        parser.error("Node.js is required; pass --node /path/to/node")

    root = options.root.resolve()
    patches, fingerprint = input_fingerprint()
    if options.check:
        marker = root / "build-fingerprint"
        ready = marker.exists() and marker.read_text().strip() == fingerprint
        ready = ready and (root / "llvm-build/bin/clang").is_file() and (root / "env.sh").is_file()
        sys.exit(0 if ready else 1)
    root.mkdir(parents=True, exist_ok=True)
    with (root / ".prepare.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        versions = json.loads((TOOLCHAIN / "versions.json").read_text())
        host = f"{platform.system()}-{platform.machine()}"
        if host not in versions["sdk"]:
            raise RuntimeError(f"No checksum-pinned SDK for {host}")
        downloads = root / "downloads"
        downloads.mkdir(exist_ok=True)
        sdk_archive = download(versions["sdk"][host], downloads)
        llvm_archive = download(versions["llvm"], downloads)
        if options.download_only:
            return

        sdk = root / "sdk"
        sources = root / "sources"
        llvm = sources / versions["llvm"]["directory"]
        extract(sdk_archive, sdk, sdk / "install")
        extract(llvm_archive, sources, llvm)
        patch_sources(llvm, patches)
        build = root / "llvm-build"
        configuration = root / "emscripten-config.py"
        configuration.write_text(
            f"LLVM_ROOT = {str(build / 'bin')!r}\n"
            f"BINARYEN_ROOT = {str(sdk / 'install')!r}\n"
            f"NODE_JS = [{str(Path(options.node).resolve())!r}]\n"
            f"CACHE = {str(root / 'cache' / fingerprint[:16])!r}\n"
        )
        environment = root / "env.sh"
        binaries = root / "bin"
        binaries.mkdir(exist_ok=True)
        python = binaries / "python3"
        if python.is_symlink():
            python.unlink()
        if not python.exists():
            python.symlink_to(Path(sys.executable).resolve())
        environment.write_text(
            "# Source this file to use the project compiler and Emscripten.\n"
            f"export EM_CONFIG={shlex.quote(str(configuration))}\n"
            f"export PATH={shlex.quote(str(sdk / 'install' / 'emscripten'))}:"
            f"{shlex.quote(str(binaries))}:\"$PATH\"\n"
        )
        if options.prepare_only:
            return

        run([
            "cmake", "-S", str(llvm / "llvm"), "-B", str(build), "-G", "Ninja",
            "-DCMAKE_BUILD_TYPE=Release", "-DLLVM_ENABLE_PROJECTS=clang;lld",
            "-DLLVM_TARGETS_TO_BUILD=WebAssembly", "-DLLVM_ENABLE_ASSERTIONS=ON",
            "-DLLVM_INCLUDE_TESTS=OFF", "-DLLVM_INCLUDE_EXAMPLES=OFF",
            "-DLLVM_INCLUDE_BENCHMARKS=OFF", "-DCLANG_INCLUDE_TESTS=OFF",
            f"-DLLVM_FORCE_VC_REVISION={versions['llvm']['commit']}",
            "-DLLVM_FORCE_VC_REPOSITORY=https://github.com/llvm/llvm-project",
            "-DLLVM_ENABLE_ZSTD=OFF", "-DLLVM_ENABLE_ZLIB=OFF",
            "-DLLVM_ENABLE_LIBXML2=OFF",
        ])
        run([
            "cmake", "--build", str(build), "--parallel", str(options.jobs),
            "--target", "clang", "lld", "llvm-ar", "llvm-ranlib", "llvm-nm", "llvm-objcopy",
            "llvm-strip",
            "llvm-readobj", "llvm-dis", "FileCheck",
        ])
        (root / "build-fingerprint").write_text(fingerprint + "\n")
        print(f"Toolchain ready. Run: source {shlex.quote(str(environment))}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
