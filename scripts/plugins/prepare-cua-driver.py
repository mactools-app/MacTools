#!/usr/bin/env python3
"""Prepare the pinned in-process SDK. Never install or execute Cua's app/CLI."""
from __future__ import annotations
import argparse
import hashlib
import os
import json
import fcntl
import subprocess
from pathlib import Path
import shutil
import tarfile
import tempfile
import urllib.request

VERSION = "0.38.0"
ASSET = f"cua-driver-rs-{VERSION}-darwin-arm64.tar.gz"
ARCHIVE_SHA256 = "5f71191c082ca07c9dfc13b7c9a6eec60a82818c245a93534cc0eb7911471d72"
URL = f"https://github.com/trycua/cua/releases/download/cua-driver-rs-v{VERSION}/{ASSET}"
FILES = ("libcua_driver_sdk.dylib", "LICENSE", "THIRD_PARTY_NOTICES.md")
LIBRARY_SHA256 = "f627aa1c08544d954624b36ba2ddc76f08fea20f9b1d7ff0d0724c22c348354a"


def prepare_release_assets(destination: Path, archive: Path | None = None) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    # An interrupted extraction must never be treated as a completed SDK.
    marker = destination / "archive.sha256"
    if (marker.exists() and marker.read_text().strip() == ARCHIVE_SHA256
            and all((destination / f).is_file() for f in FILES)
            and hashlib.sha256((destination / FILES[0]).read_bytes()).hexdigest() == LIBRARY_SHA256):
        return
    with tempfile.TemporaryDirectory(prefix="cua-sdk-", dir=destination.parent) as scratch:
        scratch = Path(scratch)
        if archive is None:
            archive = scratch / ASSET
            request = urllib.request.Request(URL, headers={"User-Agent": "MacTools-build"})
            with urllib.request.urlopen(request, timeout=120) as response, archive.open("wb") as output:
                shutil.copyfileobj(response, output)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != ARCHIVE_SHA256:
            raise RuntimeError("Cua SDK archive checksum mismatch")
        with tarfile.open(archive, "r:gz") as package:
            for name in FILES:
                members = [m for m in package.getmembers() if Path(m.name).name == name and m.isfile() and len(Path(m.name).parts) == 2]
                if len(members) != 1:
                    raise RuntimeError(f"Expected one top-level SDK file: {name}")
                with package.extractfile(members[0]) as source, (scratch / name).open("wb") as output:
                    shutil.copyfileobj(source, output)
                os.replace(scratch / name, destination / name)
        temporary_marker = destination / "archive.sha256.tmp"
        temporary_marker.write_text(ARCHIVE_SHA256 + "\n")
        os.replace(temporary_marker, marker)


SOURCE_COMMIT = "85e2b1318bd77ccf3cfa88ccdf875a4bb7eaed19"
RUST_TOOLCHAIN = "1.97.1"
TARGETS = ("aarch64-apple-darwin", "x86_64-apple-darwin")
VENDOR = Path(__file__).resolve().parents[2] / "Plugins/VoiceControl/Vendor/CuaDriverABI"


def native_build_key() -> str:
    digest = hashlib.sha256(SOURCE_COMMIT.encode())
    for path in (Path(__file__), VENDOR / "mactools-native.patch", VENDOR / "mactools_native.rs", VENDOR / "mactools_semantics.rs"):
        digest.update(path.read_bytes())
    return digest.hexdigest()


def build_environment(destination: Path) -> dict[str, str]:
    # Cargo runs in the prepared source tree, not necessarily the caller's directory.
    destination = destination.resolve()
    environment = {key: os.environ[key] for key in ("PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "DEVELOPER_DIR") if key in os.environ}
    # Cargo's C dependencies must use the selected Xcode SDK even when Xcode
    # invokes this script with a PATH entry named only "cc". The absolute
    # toolchain path also makes cc-rs add its explicit Apple sysroot flags.
    def xcode_tool(*arguments: str) -> str:
        return subprocess.check_output(["/usr/bin/xcrun", "--sdk", "macosx", *arguments],
            env=environment, text=True).strip()

    sdk = xcode_tool("--show-sdk-path")
    clang = xcode_tool("--find", "clang")
    clangxx = xcode_tool("--find", "clang++")
    environment.update(CARGO_HOME=str(destination / "cargo"), CARGO_TARGET_DIR=str(destination / "target"),
        SDKROOT=sdk, CC=clang, CXX=clangxx,
        MACOSX_DEPLOYMENT_TARGET="14.0", GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1",
        GIT_TERMINAL_PROMPT="0", GIT_CONFIG_COUNT="1", GIT_CONFIG_KEY_0="credential.helper", GIT_CONFIG_VALUE_0="",
        CARGO_PROFILE_RELEASE_STRIP="none", CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_STRIP="none",
        CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_DEBUG="2")
    return environment


def prepare_source(destination: Path, key: str, environment: dict[str, str]) -> Path:
    source = destination / ("source-" + key)
    rust = source / "libs/cua-driver/rust"
    if (source / ".prepared").is_file():
        return rust
    if os.environ.get("MACTOOLS_BUILD_OFFLINE") == "1":
        raise RuntimeError("Prepare the native Cua SDK cache before an offline build")
    git = destination / "source.git"
    if not git.exists():
        subprocess.run(["git", "init", "--bare", str(git)], check=True, env=environment)
    for name, value in (("remote.origin.url", "https://github.com/trycua/cua.git"),
                        ("remote.origin.promisor", "true"), ("remote.origin.partialclonefilter", "blob:none")):
        subprocess.run(["git", "-C", str(git), "config", name, value], check=True, env=environment)
    subprocess.run(["git", "-C", str(git), "fetch", "--depth=1", "--filter=blob:none", "origin", SOURCE_COMMIT], check=True, env=environment)
    actual = subprocess.check_output(["git", "-C", str(git), "rev-parse", "FETCH_HEAD"], env=environment).decode().strip()
    if actual != SOURCE_COMMIT:
        raise RuntimeError("Cua source revision mismatch")
    with tempfile.TemporaryDirectory(prefix="cua-source-", dir=destination) as temporary:
        archive = Path(temporary) / "source.tar"
        with archive.open("wb") as output:
            subprocess.run(["git", "-C", str(git), "archive", "FETCH_HEAD", "libs/cua-driver/rust",
                "libs/cua/Cargo.toml", "libs/cua/Cargo.lock", "libs/cua/crates"], check=True, stdout=output, env=environment)
        source.mkdir(parents=True, exist_ok=True)
        with tarfile.open(archive) as package:
            for member in package:
                path = Path(member.name)
                if path.is_absolute() or ".." in path.parts:
                    raise RuntimeError("Unsafe Cua source archive path")
                if not member.isfile():
                    continue
                output = source / path
                output.parent.mkdir(parents=True, exist_ok=True)
                with package.extractfile(member) as data, output.open("wb") as stream:
                    shutil.copyfileobj(data, stream)
        subprocess.run(["/usr/bin/patch", "-p1", "--batch", "--forward", "--dry-run", "-i", str(VENDOR / "mactools-native.patch")], cwd=rust, env=environment, check=True)
        subprocess.run(["/usr/bin/patch", "-p1", "--batch", "--forward", "-i", str(VENDOR / "mactools-native.patch")], cwd=rust, env=environment, check=True)
        for name in ("mactools_native.rs", "mactools_semantics.rs"):
            shutil.copy2(VENDOR / name, rust / "crates/platform-macos/src/tools" / name)
        (source / ".prepared").write_text(key)
    return rust


def prepare(destination: Path, archive: Path | None = None) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    with (destination / "native.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        key = native_build_key()
        manifest = destination / "native-build.json"
        library = destination / "libcua_driver_sdk.dylib"
        if manifest.is_file() and library.is_file():
            saved = json.loads(manifest.read_text())
            if (saved.get("input_key") == key and saved.get("library_sha256") == hashlib.sha256(library.read_bytes()).hexdigest()
                    and all((destination / name).is_file() for name in FILES[1:])):
                return
        environment = build_environment(destination)
        rustup = shutil.which("rustup") or str(Path.home() / ".cargo/bin/rustup")
        tools = {}
        for tool in ("cargo", "rustc"):
            try:
                tools[tool] = subprocess.check_output([rustup, "which", "--toolchain", RUST_TOOLCHAIN, tool], env=environment).decode().strip()
            except (OSError, subprocess.CalledProcessError) as error:
                raise RuntimeError("Install the official Rust 1.97.1 toolchain and both Apple Darwin targets to build Voice Assistant") from error
        environment["RUSTC"] = tools["rustc"]
        for target in TARGETS:
            libdir = subprocess.check_output([tools["rustc"], "--print", "target-libdir", "--target", target], env=environment).decode().strip()
            if not Path(libdir).is_dir():
                raise RuntimeError("Install Rust targets: rustup target add --toolchain 1.97.1 aarch64-apple-darwin x86_64-apple-darwin")
        rust = prepare_source(destination, key, environment)
        prepare_release_assets(destination / "upstream-release", archive)
        libraries = []
        for target in TARGETS:
            command = [tools["cargo"], "build", "--locked", "--release", "-p", "cua-driver-sdk", "--lib", "--target", target, "--jobs", "4"]
            if os.environ.get("MACTOOLS_BUILD_OFFLINE") == "1":
                command.append("--offline")
            subprocess.run(command, cwd=rust, env=environment, check=True)
            libraries.append(str(destination / "target" / target / "release/libcua_driver_sdk.dylib"))
        temporary_library = destination / "libcua_driver_sdk.pending.dylib"
        subprocess.run(["/usr/bin/lipo", "-create", *libraries, "-output", str(temporary_library)], check=True, env=environment)
        os.replace(temporary_library, library)
        for name in FILES[1:]:
            shutil.copy2(destination / "upstream-release" / name, destination / name)
        data = {"input_key": key, "source_commit": SOURCE_COMMIT, "policy_version": 3,
            "library_sha256": hashlib.sha256(library.read_bytes()).hexdigest(), "targets": list(TARGETS), "rust": RUST_TOOLCHAIN}
        temporary_manifest = destination / "native-build.pending.json"
        temporary_manifest.write_text(json.dumps(data, indent=2) + "\n")
        os.replace(temporary_manifest, manifest)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--archive", type=Path)
    args = parser.parse_args()
    prepare(args.destination, args.archive)
