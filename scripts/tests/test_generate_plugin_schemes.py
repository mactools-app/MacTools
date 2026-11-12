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
        self.assertIn("No plugin matched", result.stderr)

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


if __name__ == "__main__":
    unittest.main()
