#!/usr/bin/env python3
from __future__ import annotations

import contextlib
import functools
import importlib.util
import io
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPTS_DIR = Path(__file__).resolve().parents[1]
RELEASE_SCRIPT_PATH = SCRIPTS_DIR / "release.py"
PLAN_SCRIPT_PATH = SCRIPTS_DIR / "plugins" / "plan-plugin-release.py"

RELEASE_SPEC = importlib.util.spec_from_file_location("mactools_release", RELEASE_SCRIPT_PATH)
assert RELEASE_SPEC is not None and RELEASE_SPEC.loader is not None
release = importlib.util.module_from_spec(RELEASE_SPEC)
sys.modules[RELEASE_SPEC.name] = release
RELEASE_SPEC.loader.exec_module(release)


class InteractiveReleasePlanningTests(unittest.TestCase):
    def test_plugin_release_keeps_committed_website_versions_current(self) -> None:
        for dry_run, invalid_manifest in ((False, False), (True, False), (False, True)):
            with (
                self.subTest(dry_run=dry_run, invalid_manifest=invalid_manifest),
                tempfile.TemporaryDirectory() as directory,
            ):
                root = Path(directory)
                source = root / "Plugins"
                manifest_path = source / "AutoHideDock/plugin.json"
                manifest_path.parent.mkdir(parents=True)
                shutil.copytree(
                    SCRIPTS_DIR.parent / "Plugins/AutoHideDock/Resources",
                    manifest_path.parent / "Resources",
                )
                manifest = json.loads(
                    (SCRIPTS_DIR.parent / "Plugins/AutoHideDock/plugin.json").read_text()
                )
                manifest["version"] = "1.0.0"
                manifest_path.write_text(json.dumps(manifest))
                baseline = root / "docs/plugins/v7/catalog.json"
                baseline.parent.mkdir(parents=True)
                baseline.write_text(json.dumps({"pluginKitVersion": 7, "plugins": [manifest]}))
                plugin_scripts = root / "scripts/plugins"
                plugin_scripts.mkdir(parents=True)
                for name in ("generate_website_plugin_data.py", "plugin_source_manifest.py"):
                    shutil.copy2(SCRIPTS_DIR / "plugins" / name, plugin_scripts / name)
                # Match the repository when CI and the helper use different Python versions.
                (root / ".gitignore").write_text("__pycache__/\n")

                def command(*args: str) -> str:
                    return subprocess.run(
                        args, cwd=root, check=True, capture_output=True, text=True,
                    ).stdout.strip()

                command(sys.executable, "scripts/plugins/generate_website_plugin_data.py")
                (root / "site/public/generated/plugin-assets").mkdir(parents=True)
                command("git", "init", "-q")
                command("git", "config", "user.name", "Test")
                command("git", "config", "user.email", "test@example.invalid")
                command("git", "add", ".")
                command("git", "commit", "-qm", "baseline")
                before_commit = command("git", "rev-parse", "HEAD")
                website_path = root / "site/src/generated/plugins.json"
                before_website = website_path.read_bytes()
                if invalid_manifest:
                    manifest["presentation"]["screenshots"] = "invalid"
                    manifest_path.write_text(json.dumps(manifest))

                args = mock.Mock(
                    plugin_mode="all", plugin=[], version="1.0.1", level="patch",
                    remote="origin", branch="main", dry_run=dry_run, skip_check=True, yes=True,
                )
                with (
                    mock.patch.object(release, "ROOT_DIR", root),
                    mock.patch.object(release, "PLUGIN_SOURCE_DIR", source),
                    mock.patch.object(release, "run", functools.partial(release.run, cwd=root)),
                    mock.patch.object(release, "latest_tag_version", return_value="1.0.0"),
                    mock.patch.object(release, "check_tag_available"),
                    mock.patch.object(release, "confirm"),
                    mock.patch.object(release, "sync_branch_after_confirm"),
                    mock.patch.object(release, "validate_changelog"),
                    mock.patch.object(release, "changelog_status_label", return_value="pending"),
                    mock.patch.object(release, "prepare_changelog", return_value=[]),
                    mock.patch.object(release, "push_branch_and_tag") as publish,
                    contextlib.redirect_stdout(io.StringIO()),
                ):
                    if invalid_manifest:
                        with self.assertRaises(release.ReleaseError):
                            release.release_plugin(args)
                        publish.assert_not_called()
                    else:
                        release.release_plugin(args)
                        publish.assert_called_once_with("origin", "main", "plugins-1.0.1", dry_run)

                if dry_run or invalid_manifest:
                    self.assertEqual(command("git", "rev-parse", "HEAD"), before_commit)
                    self.assertEqual(website_path.read_bytes(), before_website)
                    if dry_run:
                        self.assertEqual(json.loads(manifest_path.read_text())["version"], "1.0.0")
                else:
                    committed = json.loads(command("git", "show", "HEAD:site/src/generated/plugins.json"))
                    self.assertEqual(committed["plugins"][0]["version"], "1.0.1")
                    self.assertEqual(json.loads(manifest_path.read_text())["version"], "1.0.1")
                    self.assertEqual(command("git", "status", "--porcelain"), "")
                    command(sys.executable, "scripts/plugins/generate_website_plugin_data.py", "--check")

    def test_plugin_kit6_migration_leaves_package_bumps_to_release(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "Plugins"
            for plugin_id, version in (("existing", "1.0.0"), ("bumped", "1.1.0"), ("new", "1.0.0")):
                plugin = source / plugin_id
                plugin.mkdir(parents=True)
                (plugin / "plugin.json").write_text(json.dumps({
                    "id": plugin_id, "displayName": plugin_id, "version": version,
                    "pluginKitVersion": 6, "minHostVersion": "1.3.0",
                }))
            baseline = root / "docs/plugins/v5/catalog.json"
            baseline.parent.mkdir(parents=True)
            baseline.write_text(json.dumps({
                "pluginKitVersion": 5,
                "plugins": [{"id": plugin_id, "version": "1.0.0", "pluginKitVersion": 5}
                            for plugin_id in ("existing", "bumped")],
            }))
            before = {path: path.read_bytes() for path in source.glob("*/plugin.json")}
            args = mock.Mock(
                plugin_mode="auto", plugin=[], version="1.3.0", level="minor",
                remote="origin", branch="main", dry_run=True, skip_check=False, yes=True,
            )
            with (
                mock.patch.object(release, "ROOT_DIR", root),
                mock.patch.object(release, "PLUGIN_SOURCE_DIR", source),
                mock.patch.object(release, "latest_tag_version", return_value="1.2.0"),
                mock.patch.object(release, "check_tag_available"),
                mock.patch.object(release, "confirm"),
                mock.patch.object(release, "sync_branch_after_confirm"),
                mock.patch.object(release, "validate_changelog"),
                mock.patch.object(release, "changelog_status_label", return_value="pending"),
                mock.patch.object(release, "run_plugin_generate_check"),
                mock.patch.object(release, "run_plugin_plan_check") as plan,
                mock.patch.object(release, "prepare_changelog", return_value=[]),
                mock.patch.object(release, "commit_if_needed"),
                mock.patch.object(release, "push_branch_and_tag"),
                mock.patch.object(release, "write_plugin_versions", wraps=release.write_plugin_versions) as bump,
                contextlib.redirect_stdout(io.StringIO()),
            ):
                self.assertEqual(release.previous_plugin_catalog_path(), baseline)
                self.assertEqual(release.plugin_catalog_path(6), root / "docs/plugins/v6/catalog.json")
                release.release_plugin(args)
                plan.assert_called_once_with("all", [], False, True)
                self.assertEqual([plugin.id for plugin in bump.call_args.args[0]], ["existing"])
                self.assertEqual(bump.call_count, 1)
                self.assertEqual(set(release.analyze_plugins("all", []).selected_ids), {"existing", "bumped", "new"})
            self.assertEqual({path: path.read_bytes() for path in before}, before)

    def test_plugin_kit4_release_uses_versioned_catalog_path(self) -> None:
        self.assertEqual(
            release.plugin_catalog_path(4),
            release.ROOT_DIR / "docs/plugins/v4/catalog.json",
        )

    def test_plugin_kit5_release_uses_schema3_compatibility_path(self) -> None:
        self.assertEqual(
            release.plugin_catalog_path(5),
            release.ROOT_DIR / "docs/plugins/v5/schema3/catalog.json",
        )

    def test_first_plugin_kit5_schema3_release_uses_schema2_baseline(self) -> None:
        with (
            mock.patch.object(release, "read_plugins", return_value={}),
            mock.patch.object(release, "current_plugin_kit_version", return_value=5),
            mock.patch.object(Path, "exists", autospec=True) as exists,
        ):
            exists.side_effect = lambda path: path == release.ROOT_DIR / "docs/plugins/v5/catalog.json"

            self.assertEqual(
                release.previous_plugin_catalog_path(),
                release.ROOT_DIR / "docs/plugins/v5/catalog.json",
            )

    def test_schema3_workflow_uses_same_abi_baseline_and_forces_full_release(self) -> None:
        workflow = (release.ROOT_DIR / ".github/workflows/plugin-release.yml").read_text(
            encoding="utf-8"
        )

        self.assertIn("origin/main:docs/plugins/v5/catalog.json", workflow)
        self.assertIn('echo "PLUGIN_RELEASE_MODE=all"', workflow)
        self.assertIn('echo "PLUGIN_RELEASE_REQUIRE_VERSION_BUMP=true"', workflow)
        self.assertIn("plan_args+=(--require-version-bump)", workflow)

    def test_plugin_release_verifies_catalog_key_without_python_signing_dependency(self) -> None:
        workflow = (release.ROOT_DIR / ".github/workflows/plugin-release.yml").read_text(
            encoding="utf-8"
        )

        self.assertIn("Verify plugin catalog signing key", workflow)
        self.assertIn("verify-plugin-catalog-key-pair.sh", workflow)
        self.assertNotIn("pip install cryptography", workflow)

    def test_selected_mode_cannot_skip_same_abi_migration_rebuild(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            schema3_catalog = root / "docs/plugins/v5/schema3/catalog.json"
            schema2_catalog = root / "docs/plugins/v5/catalog.json"
            args = mock.Mock(plugin_mode="selected", plugin=["demo"], skip_check=True)

            with (
                mock.patch.object(release, "read_plugins", return_value={}),
                mock.patch.object(release, "current_plugin_kit_version", return_value=5),
                mock.patch.object(release, "plugin_catalog_path", return_value=schema3_catalog),
                mock.patch.object(
                    release,
                    "same_abi_catalog_migration_baseline_path",
                    return_value=schema2_catalog,
                ),
                mock.patch.object(
                    release,
                    "previous_plugin_catalog_path",
                    return_value=schema2_catalog,
                ),
                mock.patch.object(
                    release,
                    "read_previous_catalog",
                    return_value={"pluginKitVersion": 5},
                ),
                mock.patch.object(release, "write_plugin_versions") as write_versions,
                mock.patch.object(release, "commit_if_needed") as commit,
                mock.patch.object(release, "push_branch_and_tag") as push,
            ):
                with self.assertRaisesRegex(
                    release.ReleaseError,
                    "plugin-mode selected.*plugin-mode all",
                ):
                    release.release_plugin(args)

            write_versions.assert_not_called()
            commit.assert_not_called()
            push.assert_not_called()

    def test_legacy_plugin_kit_release_is_rejected_before_tagging(self) -> None:
        with self.assertRaisesRegex(release.ReleaseError, "catalog 已冻结"):
            release.ensure_plugin_kit_releasable(4)

        release.ensure_plugin_kit_releasable(5)
        release.ensure_plugin_kit_releasable(6)

    def test_predeclared_app_version_is_the_default_release_target(self) -> None:
        with mock.patch.object(release, "choose_level") as choose_level:
            target, level, uses_declared_version = release.resolve_app_release_target(
                current_version="1.2.0",
                latest_tag="1.1.6",
                requested_version=None,
                requested_level=None,
            )

        self.assertEqual(target, "1.2.0")
        self.assertEqual(level, "minor")
        self.assertTrue(uses_declared_version)
        choose_level.assert_not_called()

    def test_requested_version_may_match_predeclared_version(self) -> None:
        target, level, uses_declared_version = release.resolve_app_release_target(
            current_version="1.2.0",
            latest_tag="1.1.6",
            requested_version="1.2.0",
            requested_level=None,
        )

        self.assertEqual(target, "1.2.0")
        self.assertEqual(level, "minor")
        self.assertFalse(uses_declared_version)

    def test_app_release_target_cannot_precede_declared_version(self) -> None:
        with self.assertRaisesRegex(
            release.ReleaseError,
            "不能低于 AppVersion.xcconfig 已声明的版本",
        ):
            release.resolve_app_release_target(
                current_version="1.2.0",
                latest_tag="1.1.6",
                requested_version="1.1.7",
                requested_level=None,
            )

    def test_app_release_target_must_exceed_latest_tag(self) -> None:
        with self.assertRaisesRegex(release.ReleaseError, "必须高于最新 app tag"):
            release.resolve_app_release_target(
                current_version="1.1.6",
                latest_tag="1.1.6",
                requested_version="1.1.6",
                requested_level=None,
            )

    def test_explicit_major_release_can_advance_past_declared_version(self) -> None:
        target, level, uses_declared_version = release.resolve_app_release_target(
            current_version="1.2.0",
            latest_tag="1.1.6",
            requested_version=None,
            requested_level="major",
        )

        self.assertEqual(target, "2.0.0")
        self.assertEqual(level, "major")
        self.assertFalse(uses_declared_version)

    def test_release_preflight_skips_confirmation_without_plugin_kit_changes(self) -> None:
        with (
            mock.patch.object(release, "latest_tag_version", return_value="1.1.3"),
            mock.patch.object(release, "changed_paths_since", return_value=[]),
            mock.patch.object(release, "confirm") as confirm,
        ):
            release.confirm_plugin_kit_changes_before_release()

        confirm.assert_not_called()

    def test_release_preflight_confirms_plugin_kit_changes(self) -> None:
        changed_paths = [
            "Sources/MacToolsPluginKit/PluginModels.swift",
            "Sources/MacToolsPluginKit/PluginInterfaces.swift",
        ]

        with (
            mock.patch.object(release, "latest_tag_version", return_value="1.1.3"),
            mock.patch.object(release, "changed_paths_since", return_value=changed_paths),
            mock.patch.object(release, "confirm") as confirm,
            mock.patch("builtins.print"),
        ):
            release.confirm_plugin_kit_changes_before_release()

        confirm.assert_called_once_with(
            "确认已检查这些 PluginKit 改动是否需要提升 pluginKitVersion，并继续发布？",
            False,
            noninteractive_error=(
                "检测到 PluginKit 代码变化，非交互发布无法完成兼容性确认。"
                "请在交互终端运行 `make release`，检查 pluginKitVersion 后确认。"
            ),
        )

    def test_plugin_kit_changes_are_package_relevant_for_every_plugin(self) -> None:
        plugin = release.PluginInfo(
            id="demo",
            directory_name="Demo",
            display_name="Demo",
            path=release.PLUGIN_SOURCE_DIR / "Demo",
            manifest_path=release.PLUGIN_SOURCE_DIR / "Demo" / "plugin.json",
            version="1.0.0",
            plugin_kit_version=3,
        )

        def changed_paths(_ref: str, path: Path) -> list[str]:
            if path == release.PLUGIN_SHARED_PATHS[0]:
                return ["Sources/MacToolsPluginKit/PluginModels.swift"]
            return []

        with mock.patch.object(release, "changed_paths_since", side_effect=changed_paths):
            changes = release.plugin_package_relevant_changes_since("plugins-1.0.0", plugin)

        self.assertEqual(changes, ["Sources/MacToolsPluginKit/PluginModels.swift"])

    def test_app_release_preflight_invokes_catalog_verifier_for_target_version(self) -> None:
        with mock.patch.object(release, "run") as run:
            release.preflight_app_plugin_catalog("1.2.0")

        run.assert_called_once_with(
            [
                "xcrun",
                "swift",
                "scripts/plugins/preflight-app-plugin-catalog.swift",
                "--app-version",
                "1.2.0",
            ]
        )


class WorkflowReleasePlanningTests(unittest.TestCase):
    def test_compatibility_migration_rejects_equal_published_versions(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            plugin_directory = root / "Plugins" / "Demo"
            plugin_directory.mkdir(parents=True)
            manifest_path = plugin_directory / "plugin.json"
            manifest = {
                "id": "demo",
                "displayName": "Demo",
                "version": "1.0.0",
                "pluginKitVersion": 5,
            }
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            previous_catalog = root / "catalog.json"
            previous_catalog.write_text(
                json.dumps(
                    {
                        "pluginKitVersion": 5,
                        "plugins": [
                            {
                                "id": "demo",
                                "version": "1.0.0",
                                "pluginKitVersion": 5,
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )
            output = root / "plan.json"
            command = [
                sys.executable,
                str(PLAN_SCRIPT_PATH),
                "--mode", "all",
                "--require-version-bump",
                "--source-dir", "Plugins",
                "--previous-catalog", str(previous_catalog),
                "--output", str(output),
            ]

            rejected = subprocess.run(
                command,
                cwd=root,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn("compatibility migration requires a version bump", rejected.stderr)

            manifest["version"] = "1.0.1"
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            accepted = subprocess.run(
                command,
                cwd=root,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(accepted.returncode, 0, accepted.stderr)
            plan = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(plan["selectedPluginIDs"], ["demo"])

    def test_default_plan_rejects_unbumped_plugin_after_plugin_kit_change(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            plugin_directory = root / "Plugins" / "Demo"
            plugin_kit_directory = root / "Sources" / "MacToolsPluginKit"
            plugin_directory.mkdir(parents=True)
            plugin_kit_directory.mkdir(parents=True)

            manifest = {
                "id": "demo",
                "displayName": "Demo",
                "version": "1.0.0",
                "pluginKitVersion": 3,
            }
            (plugin_directory / "plugin.json").write_text(
                json.dumps(manifest),
                encoding="utf-8",
            )
            shared_source = plugin_kit_directory / "PluginModels.swift"
            shared_source.write_text("public struct PluginConfiguration {}\n", encoding="utf-8")

            previous_catalog = root / "catalog.json"
            previous_catalog.write_text(
                json.dumps(
                    {
                        "pluginKitVersion": 3,
                        "plugins": [
                            {
                                "id": "demo",
                                "version": "1.0.0",
                                "pluginKitVersion": 3,
                                "package": {
                                    "url": (
                                        "https://example.invalid/releases/download/"
                                        "plugins-1.0.0/demo.zip"
                                    )
                                },
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )

            subprocess.run(["git", "init", "-q"], cwd=root, check=True)
            subprocess.run(["git", "config", "user.name", "Test"], cwd=root, check=True)
            subprocess.run(
                ["git", "config", "user.email", "test@example.invalid"],
                cwd=root,
                check=True,
            )
            subprocess.run(["git", "add", "."], cwd=root, check=True)
            subprocess.run(["git", "commit", "-qm", "baseline"], cwd=root, check=True)
            subprocess.run(["git", "tag", "plugins-1.0.0"], cwd=root, check=True)

            shared_source.write_text(
                "public struct PluginConfiguration { public let value: Int }\n",
                encoding="utf-8",
            )
            subprocess.run(["git", "add", "."], cwd=root, check=True)
            subprocess.run(["git", "commit", "-qm", "change plugin kit"], cwd=root, check=True)

            result = subprocess.run(
                [
                    sys.executable,
                    str(PLAN_SCRIPT_PATH),
                    "--mode",
                    "auto",
                    "--source-dir",
                    "Plugins",
                    "--previous-catalog",
                    str(previous_catalog),
                    "--shared-path",
                    "Sources/OtherShared",
                    "--output",
                    str(root / "plan.json"),
                ],
                cwd=root,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Sources/MacToolsPluginKit/PluginModels.swift", result.stderr)
            self.assertIn("version is still 1.0.0", result.stderr)

    def test_selected_plan_cannot_bypass_shared_plugin_kit_rebuild(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            plugin_kit_directory = root / "Sources" / "MacToolsPluginKit"
            plugin_kit_directory.mkdir(parents=True)
            previous_plugins = []
            for directory, plugin_id, version in (
                ("Demo", "demo", "1.0.1"),
                ("Other", "other", "1.0.0"),
            ):
                plugin_directory = root / "Plugins" / directory
                plugin_directory.mkdir(parents=True)
                (plugin_directory / "plugin.json").write_text(
                    json.dumps(
                        {
                            "id": plugin_id,
                            "displayName": directory,
                            "version": version,
                            "pluginKitVersion": 3,
                        }
                    ),
                    encoding="utf-8",
                )
                previous_plugins.append(
                    {
                        "id": plugin_id,
                        "version": "1.0.0",
                        "pluginKitVersion": 3,
                        "package": {
                            "url": (
                                "https://example.invalid/releases/download/"
                                f"plugins-1.0.0/{plugin_id}.zip"
                            )
                        },
                    }
                )
            shared_source = plugin_kit_directory / "PluginModels.swift"
            shared_source.write_text("public struct Model {}\n", encoding="utf-8")
            previous_catalog = root / "catalog.json"
            previous_catalog.write_text(
                json.dumps({"pluginKitVersion": 3, "plugins": previous_plugins}),
                encoding="utf-8",
            )

            subprocess.run(["git", "init", "-q"], cwd=root, check=True)
            subprocess.run(["git", "config", "user.name", "Test"], cwd=root, check=True)
            subprocess.run(
                ["git", "config", "user.email", "test@example.invalid"],
                cwd=root,
                check=True,
            )
            subprocess.run(["git", "add", "."], cwd=root, check=True)
            subprocess.run(["git", "commit", "-qm", "baseline"], cwd=root, check=True)
            subprocess.run(["git", "tag", "plugins-1.0.0"], cwd=root, check=True)
            shared_source.write_text(
                "public struct Model { public let value: Int }\n",
                encoding="utf-8",
            )
            subprocess.run(["git", "add", "."], cwd=root, check=True)
            subprocess.run(["git", "commit", "-qm", "shared change"], cwd=root, check=True)

            result = subprocess.run(
                [
                    sys.executable,
                    str(PLAN_SCRIPT_PATH),
                    "--mode", "selected",
                    "--plugins", "demo",
                    "--source-dir", "Plugins",
                    "--previous-catalog", str(previous_catalog),
                    "--output", str(root / "plan.json"),
                ],
                cwd=root,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Use --mode all", result.stderr)
            self.assertIn("Sources/MacToolsPluginKit/PluginModels.swift", result.stderr)


if __name__ == "__main__":
    unittest.main()
