import json
import pathlib
import subprocess
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts/plugins/resolve-plugin-scheme.py"


def write_manifest(root: pathlib.Path, name: str, manifest: dict) -> None:
    plugin_dir = root / name
    plugin_dir.mkdir(parents=True, exist_ok=True)
    (plugin_dir / "plugin.json").write_text(
        json.dumps(manifest), encoding="utf-8"
    )


class ResolvePluginSchemeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.plugins_dir = pathlib.Path(self.temporary_directory.name) / "Plugins"
        self.plugins_dir.mkdir()
        write_manifest(
            self.plugins_dir,
            "FanControl",
            {"id": "fan-control", "build": {"scheme": "FanControlPlugin"}},
        )
        write_manifest(
            self.plugins_dir,
            "DemoPlugin",
            {"id": "com.example.demo"},
        )
        write_manifest(
            self.plugins_dir,
            "Other",
            {"id": "other", "build": {"scheme": "CustomScheme"}},
        )

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def resolve(self, plugin: str, *extra: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(SCRIPT), "--plugin", plugin, "--plugins-dir", str(self.plugins_dir), *extra],
            capture_output=True,
            text=True,
            check=False,
        )

    def test_resolves_scheme_by_directory_name(self) -> None:
        result = self.resolve("FanControl")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "FanControlPlugin")

    def test_resolves_scheme_by_plugin_id(self) -> None:
        result = self.resolve("fan-control")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "FanControlPlugin")

    def test_resolves_explicit_scheme_override(self) -> None:
        result = self.resolve("Other")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "CustomScheme")

    def test_derives_default_scheme_from_plugin_id(self) -> None:
        result = self.resolve("com.example.demo")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "ComExampleDemoPlugin")

    def test_rejects_unknown_plugin(self) -> None:
        result = self.resolve("Missing")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No plugin matched", result.stderr)

    def test_lists_one_scheme_per_line_for_comma_separated_plugins(self) -> None:
        result = self.resolve("FanControl,com.example.demo", "--list")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["FanControlPlugin", "ComExampleDemoPlugin"])

    def test_rejects_multiple_plugins_without_list(self) -> None:
        result = self.resolve("FanControl,com.example.demo")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--list", result.stderr)


if __name__ == "__main__":
    unittest.main()
