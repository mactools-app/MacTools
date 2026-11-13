from __future__ import annotations

import os
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts/plugins/clean-installed-debug.py"
EXPECTED_BUNDLE_ID = "com.example.mactools.dev"


def write_app_bundle(app: pathlib.Path, bundle_id: str) -> None:
    (app / "Contents").mkdir(parents=True, exist_ok=True)
    with (app / "Contents" / "Info.plist").open("wb") as info_file:
        plistlib.dump({"CFBundleIdentifier": bundle_id}, info_file)


class CleanInstalledDebugTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.home = pathlib.Path(self.temporary_directory.name)
        self.app = self.home / "Applications" / "MacTools Dev.app"
        self.plugins_dir = self.home / "Library/Application Support/MacTools Dev/Plugins/Installed"
        self.plugins_dir.mkdir(parents=True, exist_ok=True)
        write_app_bundle(self.app, EXPECTED_BUNDLE_ID)
        (self.plugins_dir / "calendar.mactoolsplugin").mkdir()

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def clean(self, *extra: str) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env["HOME"] = str(self.home)
        return subprocess.run(
            [
                str(SCRIPT),
                "--app",
                str(self.app),
                "--plugins-dir",
                str(self.plugins_dir),
                "--expected-bundle-id",
                EXPECTED_BUNDLE_ID,
                *extra,
            ],
            capture_output=True,
            text=True,
            check=False,
            env=env,
        )

    def test_removes_debug_app_and_packages(self) -> None:
        result = self.clean()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.app.exists())
        self.assertFalse((self.plugins_dir / "calendar.mactoolsplugin").exists())

    def test_keeps_store_directory_and_unrelated_files(self) -> None:
        (self.plugins_dir / "README.txt").write_text("keep", encoding="utf-8")
        result = self.clean()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.plugins_dir.exists())
        self.assertTrue((self.plugins_dir / "README.txt").exists())

    def test_refuses_symlinked_app(self) -> None:
        target = self.home / "Applications" / "Other.app"
        write_app_bundle(target, EXPECTED_BUNDLE_ID)
        shutil.rmtree(self.app)
        os.symlink(target, self.app)
        result = self.clean()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("symlinked app", result.stderr)
        self.assertTrue(target.exists())

    def test_refuses_app_with_unexpected_bundle_identifier(self) -> None:
        write_app_bundle(self.app, "com.other.app")
        result = self.clean()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unexpected bundle identifier", result.stderr)
        self.assertTrue(self.app.exists())

    def test_refuses_app_without_expected_bundle_identifier(self) -> None:
        result = self.clean("--expected-bundle-id", "")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("without an expected bundle identifier", result.stderr)
        self.assertTrue(self.app.exists())

    def test_removes_packages_when_app_not_installed(self) -> None:
        shutil.rmtree(self.app)
        result = self.clean()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.plugins_dir / "calendar.mactoolsplugin").exists())

    def test_refuses_package_symlink_escaping_home(self) -> None:
        outside = self.home / "outside"
        outside.mkdir()
        (outside / "secret.txt").write_text("secret", encoding="utf-8")
        os.symlink(outside, self.plugins_dir / "evil.mactoolsplugin")
        result = self.clean()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing to remove", result.stderr)
        self.assertTrue((outside / "secret.txt").exists())
        self.assertTrue(self.app.exists())

    def test_refuses_home_ancestor(self) -> None:
        result = self.clean("--app", str(self.home / ".."), "--plugins-dir", str(self.plugins_dir))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsafe", result.stderr)


if __name__ == "__main__":
    unittest.main()
