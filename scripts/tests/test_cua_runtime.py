"""Exercise production Swift admission at the C ABI without desktop or API calls."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == "darwin", "Native Swift/C ABI check requires macOS")
class CuaRuntimeTests(unittest.TestCase):
    def test_cancel_during_load_prevents_native_dispatch(self):
        vendor = ROOT / "Plugins/VoiceControl/Vendor/CuaDriverABI"
        source = ROOT / "Plugins/VoiceControl/Sources/ComputerUse"
        fixture = ROOT / "scripts/fixtures/cua-abi-cancel"
        with tempfile.TemporaryDirectory(prefix="cua-admission-") as directory:
            directory = Path(directory)
            environment = {key: os.environ[key] for key in ("PATH", "HOME", "USER", "DEVELOPER_DIR", "TMPDIR") if key in os.environ}
            library = directory / "stub.dylib"
            executable = directory / "probe"
            commands = [
                ["/usr/bin/xcrun", "clang", "-dynamiclib", "-std=c11", "-I", str(vendor), str(fixture / "stub.c"), "-o", str(library)],
                ["/usr/bin/xcrun", "swiftc", "-parse-as-library", "-module-cache-path", str(directory / "modules"), "-I", str(vendor),
                 str(source / "CuaRuntime.swift"), str(source / "ComputerUseError.swift"), str(fixture / "Main.swift"), "-o", str(executable)],
                [str(executable), str(library)],
            ]
            for command in commands:
                result = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=120)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
