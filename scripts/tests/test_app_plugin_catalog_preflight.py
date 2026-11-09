from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parents[2]
SCRIPT_PATH = ROOT_DIR / "scripts/plugins/preflight-app-plugin-catalog.swift"
SIGN_SCRIPT_PATH = ROOT_DIR / "scripts/plugins/sign-plugin-catalog.sh"
VERIFY_KEY_PAIR_SCRIPT_PATH = ROOT_DIR / "scripts/plugins/verify-plugin-catalog-key-pair.sh"
SIGNED_CATALOG = ROOT_DIR / "docs/plugins/v4/catalog.json"
TEST_PRIVATE_KEY_BASE64 = "nWGxne/9WmC6hEr0kuwsxERJxWl7MmkZcDusAxyuf2A="
TEST_PUBLIC_KEY_BASE64 = "11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo="


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("xcrun"), "requires macOS and Xcode")
class AppPluginCatalogPreflightTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temporary_directory = tempfile.TemporaryDirectory()
        cls.executable = Path(cls.temporary_directory.name) / "catalog-preflight"
        subprocess.run(
            ["xcrun", "swiftc", str(SCRIPT_PATH), "-o", str(cls.executable)],
            cwd=ROOT_DIR,
            check=True,
            text=True,
            capture_output=True,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        cls.temporary_directory.cleanup()

    def run_preflight(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                str(self.executable),
                "--required-plugin-kit-version",
                "4",
                "--required-schema-version",
                "2",
                *arguments,
            ],
            cwd=ROOT_DIR,
            check=False,
            text=True,
            capture_output=True,
        )

    def test_schema3_source_cannot_reuse_the_released_1_2_version(self) -> None:
        result = self.run_preflight("--app-version", "1.2.0")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot be released as MacTools 1.2.0", result.stderr)
        self.assertIn("Raise the app version to 1.2.1", result.stderr)

    def test_plugin_kit6_requires_host_1_3_before_checking_catalog(self) -> None:
        result = self.run_preflight(
            "--required-plugin-kit-version", "6", "--app-version", "1.2.1"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Raise the app version to 1.3.0", result.stderr)

    def test_current_source_requires_plugin_kit7_catalog(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            plugin = root / "Plugins/Demo"
            plugin.mkdir(parents=True)
            source = next((ROOT_DIR / "Plugins").glob("*/plugin.json"))
            (plugin / "plugin.json").write_bytes(source.read_bytes())
            result = subprocess.run(
                [str(self.executable), "--app-version", "1.3.1",
                 "--public-key-base64", TEST_PUBLIC_KEY_BASE64],
                cwd=root, text=True, capture_output=True,
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("docs/plugins/v7/catalog.json", result.stderr)

    def test_matching_committed_and_deployed_signed_catalog_passes(self) -> None:
        result = self.run_preflight(
            "--app-version",
            "1.2.1",
            "--expected-catalog",
            str(SIGNED_CATALOG),
            "--deployed-catalog",
            str(SIGNED_CATALOG),
            "--catalog-url",
            "https://example.invalid/catalog.json",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Verified signed PluginKit 4 catalog", result.stdout)

    def test_signer_matches_runtime_canonicalization_for_schema3_actions(self) -> None:
        input_catalog = Path(self.temporary_directory.name) / "schema3-input.json"
        signed_catalog = Path(self.temporary_directory.name) / "schema3-signed.json"
        input_catalog.write_text(
            json.dumps(
                {
                    "schemaVersion": 3,
                    "catalogID": "com.ggbond.mactools.plugins",
                    "generatedAt": "2026-08-28T00:00:00Z",
                    "minimumHostVersion": "1.2.1",
                    "pluginKitVersion": 6,
                    "plugins": [
                        {
                            "id": "example",
                            "pluginKitVersion": 6,
                            "package": {
                                "url": "https://example.invalid/example.mactoolsplugin.zip",
                                "sha256": "0" * 64,
                                "size": 1,
                            },
                            "actions": {
                                "static": [
                                    {
                                        "id": "example.run",
                                        "parameters": [{"id": "text", "type": "string"}],
                                        "parameterSummary": {"en": "Text", "zh-Hans": "文本"},
                                    }
                                ]
                            },
                        }
                    ],
                    "revoked": [],
                },
                ensure_ascii=False,
            ),
            encoding="utf-8",
        )
        environment = os.environ.copy()
        environment["PLUGIN_CATALOG_PRIVATE_KEY_BASE64"] = TEST_PRIVATE_KEY_BASE64

        key_result = subprocess.run(
            [
                str(VERIFY_KEY_PAIR_SCRIPT_PATH),
                "--public-key-base64",
                TEST_PUBLIC_KEY_BASE64,
            ],
            cwd=ROOT_DIR,
            env=environment,
            check=False,
            text=True,
            capture_output=True,
        )
        self.assertEqual(key_result.returncode, 0, key_result.stderr)

        sign_result = subprocess.run(
            [
                str(SIGN_SCRIPT_PATH),
                "--input",
                os.path.relpath(input_catalog, ROOT_DIR),
                "--output",
                os.path.relpath(signed_catalog, ROOT_DIR),
            ],
            cwd=ROOT_DIR,
            env=environment,
            check=False,
            text=True,
            capture_output=True,
        )
        self.assertEqual(sign_result.returncode, 0, sign_result.stderr)

        result = self.run_preflight(
            "--required-plugin-kit-version",
            "6",
            "--required-schema-version",
            "3",
            "--app-version",
            "1.3.0",
            "--expected-catalog",
            str(signed_catalog),
            "--deployed-catalog",
            str(signed_catalog),
            "--catalog-url",
            "https://example.invalid/catalog.json",
            "--public-key-base64",
            TEST_PUBLIC_KEY_BASE64,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Verified signed PluginKit 6 catalog", result.stdout)

    def test_schema3_hosts_derive_the_current_plugin_kit_compatibility_line(self) -> None:
        source = SCRIPT_PATH.read_text(encoding="utf-8")
        self.assertIn('sourcePluginKitVersion()', source)
        self.assertIn('v5/schema3/catalog.json', source)
        self.assertIn('requiredSchemaVersion ?? 3', source)

    def test_versioned_plugin_kits_default_to_their_own_catalog(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            for version in (6, 7):
                with self.subTest(plugin_kit_version=version):
                    result = subprocess.run(
                        [
                            str(self.executable),
                            "--required-plugin-kit-version", str(version),
                            "--app-version", "1.3.1",
                            "--public-key-base64", TEST_PUBLIC_KEY_BASE64,
                        ],
                        cwd=directory,
                        check=False,
                        text=True,
                        capture_output=True,
                    )

                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(
                        f"Required plugin catalog is missing: docs/plugins/v{version}/catalog.json",
                        result.stderr,
                    )

    def test_default_preflight_rejects_schema2_on_the_schema3_line(self) -> None:
        result = subprocess.run(
            [
                str(self.executable),
                "--required-plugin-kit-version", "4",
                "--app-version", "1.2.1",
                "--expected-catalog", str(SIGNED_CATALOG),
                "--deployed-catalog", str(SIGNED_CATALOG),
            ],
            cwd=ROOT_DIR,
            check=False,
            text=True,
            capture_output=True,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must use catalog schema 3", result.stderr)

    def test_missing_catalog_fails_with_release_order_guidance(self) -> None:
        missing = Path(self.temporary_directory.name) / "missing.json"
        result = self.run_preflight(
            "--app-version",
            "1.2.1",
            "--expected-catalog",
            str(missing),
            "--deployed-catalog",
            str(missing),
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Publish the plugin batch first", result.stderr)
        self.assertIn("Release order:", result.stderr)

    def test_invalid_signature_fails_closed(self) -> None:
        catalog = json.loads(SIGNED_CATALOG.read_text(encoding="utf-8"))
        catalog["generatedAt"] = "2099-01-01T00:00:00Z"
        tampered = Path(self.temporary_directory.name) / "tampered.json"
        tampered.write_text(json.dumps(catalog), encoding="utf-8")
        result = self.run_preflight(
            "--app-version",
            "1.2.1",
            "--expected-catalog",
            str(tampered),
            "--deployed-catalog",
            str(tampered),
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("signature does not match", result.stderr)

    def test_wrong_catalog_id_fails_closed(self) -> None:
        catalog = json.loads(SIGNED_CATALOG.read_text(encoding="utf-8"))
        catalog["catalogID"] = "example.wrong.catalog"
        invalid = Path(self.temporary_directory.name) / "wrong-id.json"
        invalid.write_text(json.dumps(catalog), encoding="utf-8")
        result = self.run_preflight(
            "--app-version",
            "1.2.1",
            "--expected-catalog",
            str(invalid),
            "--deployed-catalog",
            str(invalid),
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must use catalog ID com.ggbond.mactools.plugins", result.stderr)

    def test_malformed_minimum_host_version_fails_closed(self) -> None:
        catalog = json.loads(SIGNED_CATALOG.read_text(encoding="utf-8"))
        catalog["minimumHostVersion"] = "future"
        invalid = Path(self.temporary_directory.name) / "malformed-floor.json"
        invalid.write_text(json.dumps(catalog), encoding="utf-8")
        result = self.run_preflight(
            "--app-version",
            "1.2.1",
            "--expected-catalog",
            str(invalid),
            "--deployed-catalog",
            str(invalid),
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Invalid app version: future", result.stderr)

    def test_catalog_requiring_newer_host_fails_closed(self) -> None:
        catalog = json.loads(SIGNED_CATALOG.read_text(encoding="utf-8"))
        catalog["minimumHostVersion"] = "1.3.0"
        invalid = Path(self.temporary_directory.name) / "future-floor.json"
        invalid.write_text(json.dumps(catalog), encoding="utf-8")
        result = self.run_preflight(
            "--app-version",
            "1.2.1",
            "--expected-catalog",
            str(invalid),
            "--deployed-catalog",
            str(invalid),
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires MacTools 1.3.0", result.stderr)
        self.assertIn("target app 1.2.1", result.stderr)


if __name__ == "__main__":
    unittest.main()
