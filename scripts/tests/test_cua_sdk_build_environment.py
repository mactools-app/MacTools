"""Check that sanitized native builds still have the selected Apple SDK."""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("prepare_cua_driver", ROOT / "scripts/plugins/prepare-cua-driver.py")
BUILDER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILDER)


class CuaSDKBuildEnvironmentTests(unittest.TestCase):
    def test_selected_sdk_and_compilers_survive_credential_sanitization(self):
        sdk = "/Applications/Xcode.app/SDKs/MacOSX.sdk"
        clang = "/Applications/Xcode.app/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
        inherited = {"PATH": "/usr/bin:/bin", "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
                     "SDKROOT": "/wrong/sdk", "CC": "/wrong/compiler", "OPENAI_API_KEY": "test-secret",
                     "GITHUB_TOKEN": "test-token"}
        with patch.dict(os.environ, inherited, clear=True), patch.object(BUILDER.subprocess, "check_output", side_effect=[sdk, clang, clang + "++"]):
            environment = BUILDER.build_environment(Path("/tmp/owned-sdk"))
        self.assertEqual(environment["SDKROOT"], sdk)
        self.assertEqual(environment["CC"], clang)
        self.assertEqual(environment["CXX"], clang + "++")
        self.assertNotIn("OPENAI_API_KEY", environment)
        self.assertNotIn("GITHUB_TOKEN", environment)

    @unittest.skipUnless(sys.platform == "darwin", "Apple SDK headers require macOS")
    def test_c_and_cpp_standard_headers_compile_for_both_apple_targets(self):
        with tempfile.TemporaryDirectory(prefix="cua-sdk-headers-") as temporary:
            environment = BUILDER.build_environment(Path(temporary))
            self.assertIn(".xctoolchain/", environment["CC"])
            for target in ["arm64-apple-macosx14.0", "x86_64-apple-macosx14.0"]:
                for language, compiler, source in [
                    ("c", environment["CC"], "#include <stdlib.h>\nint smoke(void) { return EXIT_SUCCESS; }\n"),
                    ("c++", environment["CXX"], "#include <string>\nstd::string smoke() { return {}; }\n"),
                ]:
                    with self.subTest(target=target, language=language):
                        result = subprocess.run([compiler, "--target=" + target, "-isysroot", environment["SDKROOT"],
                            "-fsyntax-only", "-x", language, "-"], input=source, env=environment,
                            capture_output=True, text=True, timeout=60)
                        self.assertEqual(result.returncode, 0, result.stderr)
