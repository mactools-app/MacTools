#!/usr/bin/env python3
"""On-demand native policy check. Opens only an owned background AppKit fixture."""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]


def verify(products: Path, library: Path) -> None:
    if sys.platform != "darwin":
        raise RuntimeError("The native policy fixture requires macOS")
    if not (products / "MacToolsPluginKit.framework").is_dir() or not library.is_file():
        raise RuntimeError("Build MacTools and Voice Assistant before running this native check")
    with tempfile.TemporaryDirectory(prefix="mactools-native-policy-") as temporary:
        scratch = Path(temporary)
        (scratch / "profile").mkdir()
        environment = {key: os.environ[key] for key in ("HOME", "USER", "LOGNAME", "DEVELOPER_DIR", "TMPDIR") if key in os.environ}
        environment.update(PATH="/usr/bin:/bin:/usr/sbin:/sbin", CFFIXED_USER_HOME=str(scratch / "profile"))
        fixture_sources = ROOT / "scripts/fixtures/cua-native-policy"
        source = ROOT / "Plugins/VoiceControl/Sources/ComputerUse"
        fault_library = scratch / "failed-action-read.dylib"
        commands = [
            ["/usr/bin/xcrun", "clang", "-dynamiclib", "-std=c11", "-framework", "ApplicationServices",
             "-framework", "CoreFoundation", str(fixture_sources / "FailedActionRead.c"), "-o", str(fault_library)],
            ["/usr/bin/xcrun", "swiftc", "-parse-as-library", "-module-cache-path", str(scratch / "modules"),
             str(fixture_sources / "Fixture.swift"), "-o", str(scratch / "fixture")],
            ["/usr/bin/xcrun", "swiftc", "-parse-as-library", "-module-cache-path", str(scratch / "modules"),
             "-I", str(ROOT / "Plugins/VoiceControl/Vendor/CuaDriverABI"), "-F", str(products),
             "-framework", "MacToolsPluginKit", "-Xlinker", "-rpath", "-Xlinker", str(products),
             *[str(source / name) for name in ("ComputerUseError.swift", "ComputerUseEnvironment.swift", "ComputerUseController.swift", "CuaRuntime.swift")],
             str(fixture_sources / "Probe.swift"), "-o", str(scratch / "probe")],
        ]
        for command in commands:
            subprocess.run(command, env=environment, check=True, timeout=120)
        state = scratch / "fixture.json"
        with (scratch / "fixture.log").open("w") as log:
            fixture = subprocess.Popen([str(scratch / "fixture"), str(state)], env=environment, stdout=log, stderr=subprocess.STDOUT)
            try:
                deadline = time.monotonic() + 10
                while not state.exists():
                    if time.monotonic() > deadline or fixture.poll() is not None:
                        details = (scratch / "fixture.log").read_text(errors="replace")
                        raise RuntimeError(f"Owned native fixture did not start (exit={fixture.poll()}):\n" + details)
                    time.sleep(0.05)
                probe_environment = dict(environment, DYLD_INSERT_LIBRARIES=str(fault_library), MACTOOLS_POLICY_FIXTURE_PID=str(fixture.pid))
                subprocess.run([str(scratch / "probe"), str(library), str(fixture.pid), str(state)], env=probe_environment, check=True, timeout=45)
                deadline = time.monotonic() + 3
                while True:
                    result = json.loads(state.read_text())
                    if result["note"] == "Native policy: 茶 ✅" and result["checked"] and result["clicks"] == 1 and result["otherClicks"] == 0:
                        break
                    if time.monotonic() > deadline:
                        raise RuntimeError("Fixture did not observe the expected single effect")
                    time.sleep(0.05)
            finally:
                if fixture.poll() is None:
                    fixture.terminate()
                    try:
                        fixture.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        fixture.kill()
                        fixture.wait(timeout=5)
        print("PASS: secure exclusion, zero descendant reads after ancestor failure, distinct approvals, no keep-awake assertion, fault-injected peer refusal, stale toolbar document/address and control/row/URL refusal, foreign-window exclusion, incomplete-scope refusal, unverified web echoes, and fresh single effects.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--products-dir", type=Path, required=True)
    parser.add_argument("--library", type=Path, default=ROOT / "build/Dependencies/CuaDriver/0.38.0/libcua_driver_sdk.dylib")
    arguments = parser.parse_args()
    verify(arguments.products_dir.resolve(), arguments.library.resolve())
