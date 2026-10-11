#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import shutil
import subprocess
import tempfile
import sys
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).resolve().parents[1] / "changelog.py"
SPEC = importlib.util.spec_from_file_location("mactools_changelog", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
changelog = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = changelog
SPEC.loader.exec_module(changelog)


class ChangelogValidationCommandTests(unittest.TestCase):
    def test_local_command_accepts_limit_and_rejects_overlong_current_fragment(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "scripts").mkdir()
            (root / "changes" / "unreleased").mkdir(parents=True)
            (root / "CHANGELOG.md").write_text("# Changelog\n", encoding="utf-8")
            resources = root / "Sources" / "Resources"
            resources.mkdir(parents=True)
            (resources / "ReleaseHistory.json").write_text(
                changelog.render_release_history("# Changelog\n"), encoding="utf-8"
            )
            shutil.copy2(SCRIPT_PATH, root / "scripts" / "changelog.py")
            shutil.copy2(SCRIPT_PATH.parent / "audit-localization.py", root / "scripts" / "audit-localization.py")
            shutil.copy2(SCRIPT_PATH.parent.parent / "Makefile", root / "Makefile")
            # The real script-tests target also verifies generated website data.
            # Give this minimal checkout a valid empty plugin projection.
            plugin_scripts = root / "scripts" / "plugins"
            plugin_scripts.mkdir()
            for name in ["generate_website_plugin_data.py", "plugin_source_manifest.py"]:
                shutil.copy2(SCRIPT_PATH.parent / "plugins" / name, plugin_scripts / name)
            subprocess.run(
                [sys.executable, str(plugin_scripts / "generate_website_plugin_data.py")],
                cwd=root, capture_output=True, text=True, check=True,
            )
            fragment = root / "changes" / "unreleased" / "example.md"
            # Exercise real local entry points with current files, not only the parser.
            for target in ["validate-changelog", "script-tests"]:
                for length in [220, 221]:
                    with self.subTest(target=target, length=length):
                        fragment.write_text(
                            "---\nrelease: plugin\ntype: fixed\n---\n\n"
                            + "A" * (length - 1) + ".\n",
                            encoding="utf-8",
                        )
                        (root / "scripts" / "tests").mkdir(exist_ok=True)
                        (root / "scripts" / "tests" / "test_fixture.py").write_text(
                            "import unittest\nclass FixtureTests(unittest.TestCase):\n"
                            "    def test_command_reached_suite(self): self.assertTrue(True)\n",
                            encoding="utf-8",
                        )
                        result = subprocess.run(
                            ["make", target, f"PYTHON3={sys.executable}", "SHELL=/bin/sh"],
                            cwd=root, capture_output=True, text=True, check=False,
                        )
                        if length == 220:
                            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                        else:
                            self.assertNotEqual(result.returncode, 0)
                            self.assertIn("entry is too long (221 chars, max 220)", result.stderr)
                            self.assertNotIn("Ran 1 test", result.stderr)


class ComposeSparkleNotesTests(unittest.TestCase):
    def test_includes_plugin_releases_since_previous_app_release(self) -> None:
        content = """# Changelog

## [v1.2.0] - 2026-07-11

### Added

- Added the app feature.

## [plugins-1.4.0] - 2026-07-10

### Added

- Added the first plugin feature.

### Fixed

- Fixed a shared plugin issue.

## [plugins-1.3.0] - 2026-07-09

### Changed

- Improved another plugin.

### Fixed

- Fixed a shared plugin issue.

## [v1.1.0] - 2026-07-08

### Fixed

- Fixed the previous app.

## [plugins-1.2.0] - 2026-07-07

### Added

- This plugin update is too old.
"""

        notes = changelog.compose_sparkle_notes(content, "v1.2.0", "### Added\n\n- Added the app feature.\n")

        self.assertIn("## App Updates", notes)
        self.assertIn("## Plugin Updates", notes)
        self.assertIn("- Added the first plugin feature.", notes)
        self.assertIn("- Improved another plugin.", notes)
        self.assertEqual(notes.count("- Fixed a shared plugin issue."), 1)
        self.assertNotIn("This plugin update is too old", notes)

    def test_omits_plugin_heading_when_no_plugin_release_intervened(self) -> None:
        content = """# Changelog

## [v1.2.0] - 2026-07-11

### Fixed

- Fixed the app.

## [v1.1.0] - 2026-07-08

### Fixed

- Fixed the previous app.
"""

        notes = changelog.compose_sparkle_notes(content, "v1.2.0", "Release highlight.\n")

        self.assertEqual(notes, "## App Updates\n\nRelease highlight.\n")

    def test_rejects_plugin_tag_as_sparkle_app_release(self) -> None:
        with self.assertRaisesRegex(changelog.ChangelogError, "require an app tag"):
            changelog.compose_sparkle_notes("", "plugins-1.2.0", "Plugin notes.")


class ReleaseHistoryTests(unittest.TestCase):
    def test_exports_app_and_plugin_releases_in_changelog_order(self) -> None:
        content = """# Changelog

## [v1.2.0] - 2026-07-11

### Added

- Added the app feature.

### Fixed

- Fixed the app issue.

## [plugins-1.4.0] - 2026-07-10

### Changed

- Improved a plugin.
"""

        history = changelog.release_history_from_content(content)

        self.assertEqual(history["schemaVersion"], 1)
        self.assertEqual(
            history["releases"],
            [
                {
                    "id": "v1.2.0",
                    "kind": "app",
                    "version": "1.2.0",
                    "date": "2026-07-11",
                    "sections": [
                        {"kind": "added", "entries": ["Added the app feature."]},
                        {"kind": "fixed", "entries": ["Fixed the app issue."]},
                    ],
                },
                {
                    "id": "plugins-1.4.0",
                    "kind": "plugin",
                    "version": "1.4.0",
                    "date": "2026-07-10",
                    "sections": [
                        {"kind": "changed", "entries": ["Improved a plugin."]},
                    ],
                },
            ],
        )

    def test_requires_release_dates_for_bundled_history(self) -> None:
        content = """# Changelog

## [v1.2.0]

### Added

- Added the app feature.
"""

        with self.assertRaisesRegex(changelog.ChangelogError, "release date"):
            changelog.release_history_from_content(content)


if __name__ == "__main__":
    unittest.main()
