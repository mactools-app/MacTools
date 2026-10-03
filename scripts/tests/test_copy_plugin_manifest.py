import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts/plugins/copy-plugin-manifest.py"
SYNC_SCRIPT = REPO_ROOT / "scripts/plugins/sync-debug-plugins.sh"
APP_VERSION_CONFIG = REPO_ROOT / "Configs/AppVersion.xcconfig"
SUPPORTED_LOCALES = (
    "ar", "de", "en", "es", "fr", "ja", "ko", "pt", "ru", "tr", "zh-Hans", "zh-Hant"
)


def runtime_envelope(**overrides: object) -> dict[str, object]:
    manifest: dict[str, object] = {
        "id": "example",
        "displayName": "Example",
        "version": "1.0.0",
        "minHostVersion": "2.0",
        "pluginKitVersion": 5,
        "bundleRelativePath": "Example.bundle",
        "capabilities": {
            "primaryPanel": False,
            "componentPanel": False,
            "settings": "none",
        },
        "permissions": [],
        "category": "other",
    }
    manifest.update(overrides)
    return manifest


class CopyPluginManifestTests(unittest.TestCase):
    def test_nightly_helper_disclosures_match_isolated_paths_without_changing_stable(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            for directory, plugin_id in [("FanControl", "fan-control"), ("BatteryChargeLimit", "battery-charge-limit")]:
                source = REPO_ROOT / "Plugins" / directory / "plugin.json"
                original = source.read_bytes()
                base_path = f"/Library/PrivilegedHelperTools/cc.ggbond.mactools.{plugin_id}.smc-helper"
                for configuration in ["Release", "Nightly"]:
                    with self.subTest(plugin=plugin_id, configuration=configuration):
                        destination = root / f"{directory}-{configuration}.json"
                        subprocess.run([
                            sys.executable, str(SCRIPT), "copy", "--source", str(source),
                            "--destination", str(destination), "--configuration", configuration,
                            "--app-version-config", str(APP_VERSION_CONFIG),
                        ], check=True)
                        manifest = json.loads(destination.read_text(encoding="utf-8"))
                        step = next(step for step in manifest["setup"]["steps"] if step["id"] == "install-privileged-helper")
                        for description in step["description"].values():
                            self.assertIn(base_path + (".nightly" if configuration == "Nightly" else ""), description)
                            if configuration == "Release":
                                self.assertNotIn(base_path + ".nightly", description)
                self.assertEqual(source.read_bytes(), original)

    def test_debug_copy_uses_local_host_version(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            source = root / "plugin.json"
            destination = root / "copied.json"
            config = root / "AppVersion.xcconfig"
            source.write_text(
                json.dumps(runtime_envelope(minHostVersion="99.0")),
                encoding="utf-8",
            )
            config.write_text("MARKETING_VERSION = 1.2.3\n", encoding="utf-8")

            subprocess.run(
                [
                    sys.executable, str(SCRIPT), "copy",
                    "--source", str(source),
                    "--destination", str(destination),
                    "--configuration", "Debug",
                    "--app-version-config", str(config),
                ],
                check=True,
            )

            self.assertEqual(
                json.loads(destination.read_text(encoding="utf-8"))["minHostVersion"],
                "1.2.3",
            )

    def test_release_copy_projects_out_build_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            source = root / "plugin.json"
            destination = root / "copied.json"
            config = root / "AppVersion.xcconfig"
            original = json.dumps(runtime_envelope(
                build={"project": "../../MacTools.xcodeproj", "scheme": "Example"},
                package={"signPaths": ["Example.bundle/Contents/Resources/helper"]},
                presentation={"publisher": "Example"},
            )).encode() + b"\n"
            source.write_bytes(original)
            config.write_text("MARKETING_VERSION = 1.2.3\n", encoding="utf-8")

            subprocess.run(
                [
                    sys.executable, str(SCRIPT), "copy",
                    "--source", str(source),
                    "--destination", str(destination),
                    "--configuration", "Release",
                    "--app-version-config", str(config),
                ],
                check=True,
            )

            projected = json.loads(destination.read_text(encoding="utf-8"))
            self.assertNotIn("build", projected)
            self.assertEqual(projected["package"], {
                "signPaths": ["Example.bundle/Contents/Resources/helper"],
            })
            self.assertEqual(projected["presentation"], {"publisher": "Example"})

    def test_release_copy_preserves_valid_manifest_bytes_without_build_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            source = root / "plugin.json"
            destination = root / "copied.json"
            config = root / "AppVersion.xcconfig"
            original = (json.dumps(runtime_envelope(), separators=(",", ":")) + "\n").encode()
            source.write_bytes(original)
            config.write_text("MARKETING_VERSION = 1.2.3\n", encoding="utf-8")

            subprocess.run(
                [
                    sys.executable, str(SCRIPT), "copy",
                    "--source", str(source),
                    "--destination", str(destination),
                    "--configuration", "Release",
                    "--app-version-config", str(config),
                ],
                check=True,
            )

            self.assertEqual(destination.read_bytes(), original)

    def test_nightly_copy_derives_valid_monotonic_version_without_changing_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            source = root / "plugin.json"
            destination = root / "copied.json"
            config = root / "AppVersion.xcconfig"
            source.write_text(
                json.dumps(runtime_envelope(
                    version="1.4.2",
                    minHostVersion="1.2.0",
                )),
                encoding="utf-8",
            )
            original = source.read_bytes()
            config.write_text("MARKETING_VERSION = 1.2.3\n", encoding="utf-8")

            subprocess.run(
                [
                    sys.executable, str(SCRIPT), "copy",
                    "--source", str(source),
                    "--destination", str(destination),
                    "--configuration", "Nightly",
                    "--app-version-config", str(config),
                    "--nightly-build-number", "412.2",
                ],
                check=True,
            )

            copied = json.loads(destination.read_text(encoding="utf-8"))
            self.assertEqual(copied["version"], "1.412.2")
            self.assertEqual(copied["minHostVersion"], "1.2.0")
            self.assertEqual(source.read_bytes(), original)

    def test_nightly_copy_rejects_invalid_build_number(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            source = root / "plugin.json"
            destination = root / "copied.json"
            config = root / "AppVersion.xcconfig"
            source.write_text(
                json.dumps(runtime_envelope()),
                encoding="utf-8",
            )
            config.write_text("MARKETING_VERSION = 1.2.3\n", encoding="utf-8")

            result = subprocess.run(
                [
                    sys.executable, str(SCRIPT), "copy",
                    "--source", str(source),
                    "--destination", str(destination),
                    "--configuration", "Nightly",
                    "--app-version-config", str(config),
                    "--nightly-build-number", "412-beta",
                ],
                capture_output=True,
                text=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("numeric run.attempt components", result.stderr)

    def test_nightly_packaging_reuses_aggregate_build_products(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            source = root / "Source"
            plugin_root = source / "Example"
            products = root / "Products"
            output = root / "Output"
            bundle = products / "Example.bundle"
            plugin_root.mkdir(parents=True)
            bundle.mkdir(parents=True)
            (bundle / "payload").write_text("nightly bundle", encoding="utf-8")
            (plugin_root / "plugin.json").write_text(
                json.dumps(runtime_envelope(
                    id="example-nightly-plugin",
                    version="1.3.0",
                    minHostVersion="1.2.0",
                )),
                encoding="utf-8",
            )

            subprocess.run(
                [
                    str(REPO_ROOT / "scripts/plugins/build-local-plugins.sh"),
                    "--source-dir", str(source),
                    "--output-dir", str(output),
                    "--configuration", "Nightly",
                    "--products-dir", str(products),
                    "--nightly-build-number", "512.1",
                    "--skip-catalog",
                ],
                check=True,
                capture_output=True,
                text=True,
            )

            package = output / "Packages/example-nightly-plugin.mactoolsplugin"
            manifest = json.loads((package / "plugin.json").read_text(encoding="utf-8"))
            self.assertEqual(manifest["version"], "1.512.1")
            self.assertEqual(
                (package / "Example.bundle/payload").read_text(encoding="utf-8"),
                "nightly bundle",
            )

    def test_release_copy_expands_source_localization_references(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            source = root / "plugin.json"
            destination = root / "copied.json"
            config = root / "AppVersion.xcconfig"
            localized_metadata = {
                locale: {"displayName": "Example", "summary": "Example summary"}
                for locale in SUPPORTED_LOCALES
            }
            source.write_text(json.dumps(runtime_envelope(
                displayName="示例",
                summary="示例摘要",
                localizedMetadata=localized_metadata,
                productStrings={"summary": "@summary"},
                presentation={"longDescription": "@productStrings.summary"},
            )), encoding="utf-8")
            config.write_text("MARKETING_VERSION = 1.2.3\n", encoding="utf-8")

            subprocess.run(
                [
                    sys.executable, str(SCRIPT), "copy",
                    "--source", str(source),
                    "--destination", str(destination),
                    "--configuration", "Release",
                    "--app-version-config", str(config),
                ],
                check=True,
            )

            projected = json.loads(destination.read_text(encoding="utf-8"))
            description = projected["presentation"]["longDescription"]
            self.assertEqual(description["en"], "Example summary")
            self.assertEqual(description["ar"], "Example summary")
            self.assertNotIn("productStrings", projected)

    def test_release_copy_is_stable_across_python_hash_seeds(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            source = root / "plugin.json"
            config = root / "AppVersion.xcconfig"
            localized_metadata = {
                locale: {"displayName": "Example", "summary": "Example summary"}
                for locale in SUPPORTED_LOCALES
            }
            source.write_text(json.dumps(runtime_envelope(
                displayName="示例",
                summary="示例摘要",
                localizedMetadata=localized_metadata,
                productStrings={"summary": "@summary"},
                presentation={"longDescription": "@productStrings.summary"},
            )), encoding="utf-8")
            config.write_text("MARKETING_VERSION = 1.2.3\n", encoding="utf-8")
            outputs = []
            for seed in ("1", "2"):
                destination = root / f"copied-{seed}.json"
                subprocess.run(
                    [
                        sys.executable, str(SCRIPT), "copy",
                        "--source", str(source),
                        "--destination", str(destination),
                        "--configuration", "Release",
                        "--app-version-config", str(config),
                    ],
                    check=True,
                    env={**os.environ, "PYTHONHASHSEED": seed},
                )
                outputs.append(destination.read_bytes())

            self.assertEqual(outputs[0], outputs[1])

    def test_copy_rejects_invalid_runtime_envelope(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            config = root / "AppVersion.xcconfig"
            config.write_text("MARKETING_VERSION = 1.2.3\n", encoding="utf-8")
            mutations = {
                "reserved-id": {"id": "marketplace"},
                "empty-display-name": {"displayName": ""},
                "string-plugin-kit": {"pluginKitVersion": "5"},
                "traversal-path": {"bundleRelativePath": "../Bad.bundle"},
                "array-capabilities": {"capabilities": []},
                "numeric-summary": {"summary": 4},
                "array-localized-metadata": {"localizedMetadata": []},
                "numeric-release-channel": {"releaseChannel": 4},
                "invalid-release-notes-url": {"releaseNotesURL": "not-a-url"},
                "release-notes-host-whitespace": {
                    "releaseNotesURL": "https://bad host/path"
                },
                "release-notes-invalid-port": {
                    "releaseNotesURL": "https://example.com:abc/x"
                },
            }
            for name, overrides in mutations.items():
                source = root / f"{name}.json"
                destination = root / f"{name}-copied.json"
                source.write_text(json.dumps(runtime_envelope(**overrides)), encoding="utf-8")
                result = subprocess.run(
                    [
                        sys.executable,
                        str(SCRIPT),
                        "copy",
                        "--source",
                        str(source),
                        "--destination",
                        str(destination),
                        "--configuration",
                        "Release",
                        "--app-version-config",
                        str(config),
                    ],
                    capture_output=True,
                    text=True,
                )
                with self.subTest(mutation=name):
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse(destination.exists())

    def test_debug_copy_accepts_runtime_decodable_v3_and_v4_envelopes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            config = root / "AppVersion.xcconfig"
            config.write_text("MARKETING_VERSION = 1.2.3\n", encoding="utf-8")
            fixtures = (
                (3, {"primaryPanel": True, "configuration": True}),
                (4, {"componentPanel": True, "settings": "form"}),
            )
            for plugin_kit_version, capabilities in fixtures:
                source = root / f"v{plugin_kit_version}.json"
                destination = root / f"v{plugin_kit_version}-copied.json"
                source.write_text(
                    json.dumps({
                        "id": f"legacy-v{plugin_kit_version}",
                        "displayName": "Legacy",
                        "version": "1.0.0",
                        "minHostVersion": "1.0.0",
                        "pluginKitVersion": plugin_kit_version,
                        "bundleRelativePath": "Legacy.bundle",
                        "capabilities": capabilities,
                        "permissions": [],
                    }),
                    encoding="utf-8",
                )

                subprocess.run(
                    [
                        sys.executable,
                        str(SCRIPT),
                        "copy",
                        "--source", str(source),
                        "--destination", str(destination),
                        "--configuration", "Debug",
                        "--allow-sparse-legacy",
                        "--app-version-config", str(config),
                    ],
                    check=True,
                )

                with self.subTest(pluginKitVersion=plugin_kit_version):
                    copied = json.loads(destination.read_text(encoding="utf-8"))
                    self.assertEqual(copied["capabilities"], capabilities)
                    self.assertEqual(copied["permissions"], [])
                    self.assertNotIn("category", copied)

    def test_debug_sync_normalizes_and_caches_packaged_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            source = root / "Source"
            plugin_root = source / "Example"
            products = root / "Products"
            output = root / "Output"
            bundle = products / "Example.bundle"
            plugin_root.mkdir(parents=True)
            bundle.mkdir(parents=True)
            (bundle / "payload").write_text("debug bundle", encoding="utf-8")
            (plugin_root / "plugin.json").write_text(
                json.dumps(
                    {
                        "id": "example-debug-plugin",
                        "displayName": "Example",
                        "version": "1.0.0",
                        "minHostVersion": "99.0.0",
                        "pluginKitVersion": 3,
                        "bundleRelativePath": "Example.bundle",
                        "capabilities": {
                            "primaryPanel": False,
                            "componentPanel": False,
                            "configuration": False,
                        },
                        "permissions": [],
                    }
                ),
                encoding="utf-8",
            )

            command = [
                str(SYNC_SCRIPT),
                "--source-dir", str(source),
                "--products-dir", str(products),
                "--output-dir", str(output),
                "--skip-install",
            ]
            first_run = subprocess.run(
                command,
                check=True,
                capture_output=True,
                text=True,
            )
            second_run = subprocess.run(
                command,
                check=True,
                capture_output=True,
                text=True,
            )

            host_version = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "host-version",
                    "--app-version-config",
                    str(APP_VERSION_CONFIG),
                ],
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()
            packaged_manifest = json.loads(
                (
                    output
                    / "Packages/example-debug-plugin.mactoolsplugin/plugin.json"
                ).read_text(encoding="utf-8")
            )
            catalog = json.loads(
                (output / "catalog.dev.json").read_text(encoding="utf-8")
            )

            self.assertIn("Synced 1 changed", first_run.stdout)
            self.assertIn("skipped 1 unchanged", second_run.stdout)
            self.assertEqual(packaged_manifest["minHostVersion"], host_version)
            self.assertEqual(
                catalog["plugins"][0]["minimumHostVersion"],
                host_version,
            )

    def test_debug_sync_repairs_stale_installed_package(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            source = root / "Source"
            products = root / "Products"
            output = root / "Output"
            install = root / "Installed"
            bundle = products / "Example.bundle"
            source.mkdir()
            bundle.mkdir(parents=True)
            (bundle / "payload").write_text("debug bundle", encoding="utf-8")
            (source / "plugin.json").write_text(
                json.dumps(
                    {
                        "id": "example-debug-plugin",
                        "displayName": "Example",
                        "version": "1.0.0",
                        "minHostVersion": "99.0.0",
                        "pluginKitVersion": 3,
                        "bundleRelativePath": "Example.bundle",
                        "capabilities": {
                            "primaryPanel": False,
                            "componentPanel": False,
                            "configuration": False,
                        },
                        "permissions": [],
                    }
                ),
                encoding="utf-8",
            )

            command = [
                str(SYNC_SCRIPT),
                "--source-dir", str(source),
                "--products-dir", str(products),
                "--output-dir", str(output),
                "--install-dir", str(install),
            ]
            subprocess.run(command, check=True, capture_output=True, text=True)

            installed_manifest = (
                install
                / "example-debug-plugin.mactoolsplugin/plugin.json"
            )
            stale_manifest = json.loads(installed_manifest.read_text(encoding="utf-8"))
            stale_manifest["minHostVersion"] = "999.0.0"
            installed_manifest.write_text(
                json.dumps(stale_manifest),
                encoding="utf-8",
            )

            repaired = subprocess.run(
                command,
                check=True,
                capture_output=True,
                text=True,
            )
            packaged_manifest = (
                output
                / "Packages/example-debug-plugin.mactoolsplugin/plugin.json"
            )

            self.assertIn("skipped 1 unchanged", repaired.stdout)
            self.assertIn("Installed 1 debug plugin package", repaired.stdout)
            self.assertEqual(
                installed_manifest.read_bytes(),
                packaged_manifest.read_bytes(),
            )

    def test_full_debug_sync_quarantines_package_missing_from_checkout(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            source = root / "Source"
            plugin_root = source / "Example"
            products = root / "Products"
            output = root / "Output"
            install = root / "Plugins/Installed"
            bundle = products / "Example.bundle"
            stale_package = install / "stale-debug-plugin.mactoolsplugin"
            plugin_root.mkdir(parents=True)
            bundle.mkdir(parents=True)
            stale_package.mkdir(parents=True)
            (bundle / "payload").write_text("debug bundle", encoding="utf-8")
            (stale_package / "plugin.json").write_text(
                json.dumps({"id": "stale-debug-plugin"}),
                encoding="utf-8",
            )
            (plugin_root / "plugin.json").write_text(
                json.dumps(
                    {
                        "id": "example-debug-plugin",
                        "displayName": "Example",
                        "version": "1.0.0",
                        "minHostVersion": "99.0.0",
                        "pluginKitVersion": 3,
                        "bundleRelativePath": "Example.bundle",
                        "capabilities": {
                            "primaryPanel": False,
                            "componentPanel": False,
                            "configuration": False,
                        },
                        "permissions": [],
                    }
                ),
                encoding="utf-8",
            )

            result = subprocess.run(
                [
                    str(SYNC_SCRIPT),
                    "--source-dir", str(source),
                    "--products-dir", str(products),
                    "--output-dir", str(output),
                    "--install-dir", str(install),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            quarantined = root / "Plugins/Quarantined/stale-debug-plugin.mactoolsplugin"

            self.assertIn("Quarantined 1 stale debug plugin package", result.stdout)
            self.assertFalse(stale_package.exists())
            self.assertTrue(quarantined.is_dir())
            self.assertTrue(
                (install / "example-debug-plugin.mactoolsplugin").is_dir()
            )

    def test_full_debug_sync_removes_stale_output_and_regenerates_catalog(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            source = root / "Source"
            products = root / "Products"
            output = root / "Output"
            for name, plugin_id in (("First", "first"), ("Second", "second")):
                plugin_root = source / name
                bundle = products / f"{name}.bundle"
                plugin_root.mkdir(parents=True)
                bundle.mkdir(parents=True)
                (bundle / "payload").write_text(name, encoding="utf-8")
                (plugin_root / "plugin.json").write_text(
                    json.dumps(
                        {
                            "id": plugin_id,
                            "displayName": name,
                            "version": "1.0.0",
                            "minHostVersion": "1.0.0",
                            "pluginKitVersion": 3,
                            "bundleRelativePath": f"{name}.bundle",
                            "capabilities": {
                                "primaryPanel": False,
                                "componentPanel": False,
                                "configuration": False,
                            },
                            "permissions": [],
                        }
                    ),
                    encoding="utf-8",
                )

            command = [
                str(SYNC_SCRIPT),
                "--source-dir", str(source),
                "--products-dir", str(products),
                "--output-dir", str(output),
                "--skip-install",
            ]
            subprocess.run(command, check=True, capture_output=True, text=True)
            second_package = output / "Packages/second.mactoolsplugin"
            second_state = output / ".sync-state/second.sha256"
            self.assertTrue(second_package.is_dir())
            self.assertTrue(second_state.is_file())

            second_source = source / "Second"
            for path in sorted(second_source.rglob("*"), reverse=True):
                path.unlink() if path.is_file() else path.rmdir()
            second_source.rmdir()
            result = subprocess.run(
                command,
                check=True,
                capture_output=True,
                text=True,
            )

            catalog = json.loads(
                (output / "catalog.dev.json").read_text(encoding="utf-8")
            )
            self.assertIn("Removed 1 stale debug output package", result.stdout)
            self.assertFalse(second_package.exists())
            self.assertFalse(second_state.exists())
            self.assertEqual([entry["id"] for entry in catalog["plugins"]], ["first"])

    def test_partial_debug_sync_preserves_unrelated_installed_package(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            source = root / "Source"
            products = root / "Products"
            output = root / "Output"
            install = root / "Plugins/Installed"
            bundle = products / "Example.bundle"
            unrelated_package = install / "unrelated-debug-plugin.mactoolsplugin"
            source.mkdir()
            bundle.mkdir(parents=True)
            unrelated_package.mkdir(parents=True)
            (bundle / "payload").write_text("debug bundle", encoding="utf-8")
            (unrelated_package / "plugin.json").write_text(
                json.dumps({"id": "unrelated-debug-plugin"}),
                encoding="utf-8",
            )
            (source / "plugin.json").write_text(
                json.dumps(
                    {
                        "id": "example-debug-plugin",
                        "displayName": "Example",
                        "version": "1.0.0",
                        "minHostVersion": "99.0.0",
                        "pluginKitVersion": 3,
                        "bundleRelativePath": "Example.bundle",
                        "capabilities": {
                            "primaryPanel": False,
                            "componentPanel": False,
                            "configuration": False,
                        },
                        "permissions": [],
                    }
                ),
                encoding="utf-8",
            )

            command = [
                str(SYNC_SCRIPT),
                "--source-dir", str(source),
                "--products-dir", str(products),
                "--output-dir", str(output),
                "--install-dir", str(install),
            ]
            filtered_result = subprocess.run(
                [*command, "--plugin", "example-debug-plugin"],
                check=True,
                capture_output=True,
                text=True,
            )
            single_plugin_result = subprocess.run(
                command,
                check=True,
                capture_output=True,
                text=True,
            )

            self.assertIn(
                "Quarantined 0 stale debug plugin package",
                filtered_result.stdout,
            )
            self.assertIn(
                "Quarantined 0 stale debug plugin package",
                single_plugin_result.stdout,
            )
            self.assertTrue(unrelated_package.is_dir())
            self.assertFalse((root / "Plugins/Quarantined").exists())


if __name__ == "__main__":
    unittest.main()
