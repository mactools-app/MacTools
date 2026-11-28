from __future__ import annotations

import json
import pathlib
import subprocess
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
GENERATOR = REPO_ROOT / "scripts/plugins/generate-plugin-project-config.rb"


def write_manifest(root: pathlib.Path, name: str, manifest: dict, project_yml: str | None = None) -> None:
    plugin_dir = root / name
    plugin_dir.mkdir(parents=True, exist_ok=True)
    (plugin_dir / "plugin.json").write_text(json.dumps(manifest), encoding="utf-8")
    if project_yml is not None:
        (plugin_dir / "project.yml").write_text(project_yml, encoding="utf-8")


class GeneratorPrintSchemesTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.plugins_dir = pathlib.Path(self.temporary_directory.name) / "Plugins"
        self.plugins_dir.mkdir()
        write_manifest(
            self.plugins_dir,
            "FanControl",
            {"id": "fan-control", "bundleRelativePath": "FanControl.bundle", "build": {"scheme": "FanControlPlugin"}},
        )
        write_manifest(
            self.plugins_dir,
            "DemoPlugin",
            {"id": "com.example.demo", "bundleRelativePath": "Demo.bundle"},
        )
        # A plugin whose scheme is overridden only in project.yml.
        write_manifest(
            self.plugins_dir,
            "YmlOverride",
            {"id": "yml-override", "bundleRelativePath": "YmlOverride.bundle"},
            project_yml="build:\n  scheme: ProjectYmlScheme\n",
        )
        # A plugin whose bundle target differs from its declared scheme.
        write_manifest(
            self.plugins_dir,
            "BundleOverride",
            {
                "id": "bundle-override",
                "bundleRelativePath": "BundleOverride.bundle",
                "build": {"scheme": "BaseScheme", "bundleTarget": "ActualBundleTarget"},
            },
        )

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def print_schemes(self, plugin: str, *extra: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["ruby", str(GENERATOR), "--print-schemes", "--plugin", plugin,
             "--source-dir", str(self.plugins_dir), *extra],
            capture_output=True,
            text=True,
            check=False,
        )

    def test_resolves_scheme_by_directory_name(self) -> None:
        result = self.print_schemes("FanControl")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "FanControlPlugin")

    def test_resolves_scheme_by_plugin_id(self) -> None:
        result = self.print_schemes("fan-control")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "FanControlPlugin")

    def test_honors_project_yml_scheme_override(self) -> None:
        result = self.print_schemes("yml-override")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "ProjectYmlScheme")

    def test_honors_bundle_target_override(self) -> None:
        result = self.print_schemes("bundle-override")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "ActualBundleTarget")

    def test_derives_default_scheme_from_plugin_id(self) -> None:
        result = self.print_schemes("com.example.demo")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "ComExampleDemoPlugin")

    def test_rejects_unknown_plugin(self) -> None:
        result = self.print_schemes("Missing")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unknown plugin", result.stderr)

    def test_rejects_unknown_plugin_within_list(self) -> None:
        result = self.print_schemes("FanControl,Missing")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Missing", result.stderr)

    def test_rejects_empty_plugin_list(self) -> None:
        result = self.print_schemes(",")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No plugin requested", result.stderr)

    def test_lists_one_scheme_per_line_for_comma_separated_plugins(self) -> None:
        result = self.print_schemes("FanControl,com.example.demo")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            sorted(result.stdout.splitlines()), ["ComExampleDemoPlugin", "FanControlPlugin"]
        )

    def test_custom_plugin_source_directory_is_honored(self) -> None:
        result = self.print_schemes("yml-override")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "ProjectYmlScheme")


def other_ldflags(generated: str, target: str) -> str:
    lines = generated.splitlines()
    header = f"  {target}:"
    for index, line in enumerate(lines):
        if line != header:
            continue
        for follower in lines[index + 1 :]:
            if follower.startswith("  ") and not follower.startswith("   "):
                break
            marker = "OTHER_LDFLAGS:"
            if marker in follower:
                return follower.split(marker, 1)[1].strip()
    raise AssertionError(f"{target} does not declare OTHER_LDFLAGS")


class ScreenshotScreenCaptureKitLinkTests(unittest.TestCase):
    def test_screenshot_targets_weak_link_screen_capture_kit(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = pathlib.Path(temporary) / "GeneratedPlugins.yml"
            result = subprocess.run(
                [
                    "ruby",
                    str(GENERATOR),
                    "--source-dir",
                    str(REPO_ROOT / "Plugins"),
                    "--output",
                    str(output),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            generated = output.read_text(encoding="utf-8")

        screenshot_frameworks = (
            "Vision",
            "CoreImage",
            "UniformTypeIdentifiers",
            "QuartzCore",
            "VideoToolbox",
        )
        for target in ("ScreenshotPluginCore", "ScreenshotPlugin", "MacToolsTests"):
            flags = other_ldflags(generated, target)
            self.assertIn("-weak_framework ScreenCaptureKit", flags)
            self.assertNotIn("-framework ScreenCaptureKit", flags)
            self.assertEqual(flags.count("-weak_framework ScreenCaptureKit"), 1)
            if target != "MacToolsTests":
                for framework in screenshot_frameworks:
                    self.assertIn(f"-framework {framework}", flags)


if __name__ == "__main__":
    unittest.main()
