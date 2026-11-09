from __future__ import annotations

import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import textwrap
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

    def test_local_publish_paths_stop_before_upload_when_catalog_is_missing(self) -> None:
        for flags, build in (
            (["--publish-existing"], "83"),
            (["--publish", "--skip-build", "--skip-sign", "--build-number", "84"], "84"),
        ):
            with self.subTest(flags=flags), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                for directory in ("bin", "Configs", "scripts/plugins", "tmp", "build/release/v2.2.5",
                                  "build/DerivedData/Build/Products/Release/MacTools.app"):
                    (root / directory).mkdir(parents=True)
                release = root / "scripts/release-local.sh"
                shutil.copyfile(ROOT_DIR / "scripts/release-local.sh", release)
                (root / "Configs/AppVersion.xcconfig").write_text(
                    "MARKETING_VERSION = 2.2.5\nCURRENT_PROJECT_VERSION = 83\n"
                )
                (root / "build/release/v2.2.5/MacTools.dmg").write_text("fixture")
                (root / "Info.plist").write_bytes(plistlib.dumps({
                    "CFBundleShortVersionString": "2.2.5", "CFBundleVersion": build,
                }))
                stubs = {
                    "spctl": "exit 0",
                    "git": 'echo "unexpected git" >> "$PROBE_LOG"; exit 1',
                    "gh": 'echo "unexpected upload" >> "$PROBE_LOG"; exit 1',
                    "hdiutil": r'''case "$1" in
  create) for final do :; done; echo fixture > "$final";;
  attach)
    [ "$2" = "-readonly" ] && [ "$3" = "-nobrowse" ] && [ "$4" = "-mountpoint" ] || exit 3
    mkdir -p "$5/MacTools.app/Contents"
    cp "$PROBE_ROOT/Info.plist" "$5/MacTools.app/Contents/Info.plist";;
  detach) rm -r "$2/MacTools.app";;
  *) exit 4;;
esac''',
                    "../scripts/plugins/preflight-app-plugin-catalog.swift": (
                        '[ "$5" = "--artifact-info-plist" ] && [ -f "$6" ] || exit 42; '
                        'printf "preflight %s %s %s %s\\n" "$1" "$2" "$3" "$4" >> "$PROBE_LOG"; exit 41'
                    ),
                }
                for relative, body in stubs.items():
                    stub = root / "bin" / relative
                    stub.write_text("#!/bin/sh\nset -eu\n" + body + "\n")
                    stub.chmod(0o700)
                log = root / "requests.log"
                result = subprocess.run(
                    ["/bin/zsh", str(release), *flags], cwd=root, capture_output=True, text=True,
                    env={"PATH": str(root / "bin") + ":/usr/bin:/bin:/usr/sbin",
                         "TMPDIR": str(root / "tmp"), "ZDOTDIR": str(root),
                         "PROBE_ROOT": str(root), "PROBE_LOG": str(log)},
                )
                self.assertEqual(result.returncode, 41, result.stdout + result.stderr)
                self.assertEqual(log.read_text().splitlines(), [f"preflight --app-version 2.2.5 --build-number {build}"])
                self.assertFalse((root / "docs/appcast.xml").exists())

    def test_preflight_rejects_wrong_stable_artifact_metadata_before_checking_catalog(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            info = Path(temporary) / "Info.plist"
            required = {
                "CFBundleShortVersionString": "2.2.5",
                "CFBundleVersion": "83",
                "MTReleaseChannel": "stable",
                "MTPluginCatalogURL": "https://mactools.ggbond.app/plugins/v7/host-2.2.5/catalog.json",
                "MTPluginCatalogPublicKey": TEST_PUBLIC_KEY_BASE64,
            }
            for key, value, message in (
                ("CFBundleShortVersionString", "2.2.4", "DMG app version"),
                ("CFBundleVersion", "82", "DMG app build number"),
                ("CFBundleVersion", None, "DMG app build number"),
                ("MTReleaseChannel", "nightly", "Expected stable"),
                ("MTPluginCatalogURL", "https://mactools.ggbond.app/plugins/v7/catalog.json", "overrides"),
                ("MTPluginCatalogURL", None, "must declare"),
                ("MTPluginCatalogURL", "", "must declare"),
                ("MTPluginCatalogURL", "$(PLUGIN_CATALOG_URL)", "must declare"),
                ("MTPluginCatalogPublicKey", "wrong", "does not match the release key"),
            ):
                with self.subTest(key=key, value=value):
                    fields = {**required, key: value} if value is not None else {
                        name: entry for name, entry in required.items() if name != key
                    }
                    info.write_bytes(plistlib.dumps(fields))
                    result = self.run_preflight(
                        "--required-plugin-kit-version", "7", "--app-version", "2.2.5", "--build-number", "83",
                        "--artifact-info-plist", str(info), "--public-key-base64", TEST_PUBLIC_KEY_BASE64,
                    )
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(message, result.stderr)

    def test_stable_build_route_matches_the_app_version(self) -> None:
        for version, suffix in (("2.2.4", ""), ("2.2.5", "host-2.2.5/")):
            with self.subTest(version=version):
                result = self.run_preflight("--required-plugin-kit-version", "7", "--app-version", version,
                                            "--print-required-catalog-url")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), f"https://mactools.ggbond.app/plugins/v7/{suffix}catalog.json")

    def test_stable_build_step_can_recover_tagged_legacy_source(self) -> None:
        workflow = (ROOT_DIR / ".github/workflows/release.yml").read_text()
        step = workflow.split("      - name: Build unsigned Release app\n        run: |\n", 1)[1]
        body = textwrap.dedent(step.split("\n      - name:", 1)[0])
        catalog_url = "https://mactools.ggbond.app/plugins/v7/host-2.2.5/catalog.json"
        for supports_routing in (False, True):
            with self.subTest(supports_routing=supports_routing), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                (root / "scripts/plugins").mkdir(parents=True)
                preflight = root / "scripts/plugins/preflight-app-plugin-catalog.swift"
                preflight.write_text(
                    '#!/bin/sh\n[ "$3" = "--print-required-catalog-url" ] || exit 42\n'
                    f"printf '%s\\n' '{catalog_url}'\n" if supports_routing else "#!/bin/sh\nexit 41\n"
                )
                preflight.chmod(0o700)
                build = root / "scripts/xcodebuild-filtered.sh"
                build.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
                build.chmod(0o700)
                result = subprocess.run(
                    ["/bin/bash", "-ec", body], cwd=root, capture_output=True, text=True,
                    env={"PATH": "/usr/bin:/bin", "VERSION": "2.2.5" if supports_routing else "2.2.4"},
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                settings = [line for line in result.stdout.splitlines() if line.startswith("PLUGIN_CATALOG_URL=")]
                self.assertEqual(settings, [f"PLUGIN_CATALOG_URL={catalog_url}"] if supports_routing else [])

    def test_hosted_publish_retry_rechecks_catalog_and_candidate_before_upload(self) -> None:
        workflow = (ROOT_DIR / ".github/workflows/release.yml").read_text()
        publish = workflow.split("\n  publish:\n", 1)[1]
        verify_step = "      - name: Recheck production catalog before publishing"
        upload_step = "      - name: Create or update GitHub Release"
        self.assertLess(publish.index("Download verified immutable release candidate"), publish.index(verify_step))
        self.assertLess(publish.index(verify_step), publish.index(upload_step))

        def body(step: str) -> str:
            block = publish.split(step, 1)[1].split("\n      - name:", 1)[0]
            return textwrap.dedent(block.split("\n        run: |\n", 1)[1])

        for artifact_check, valid_catalog in ((True, False), (True, True), (False, True)):
            with self.subTest(artifact_check=artifact_check, valid_catalog=valid_catalog), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "bin").mkdir()
                (root / "scripts/plugins").mkdir(parents=True)
                verifier = root / "scripts/plugins/preflight-app-plugin-catalog.swift"
                verifier.write_text(
                    '#!/bin/sh\n'
                    + ('[ "$3" = "--artifact-info-plist" ] && [ -f "$4" ] && '
                       '[ "$5" = "--build-number" ] && [ "$6" = 83 ] && '
                       '[ "$7" = "--use-current-catalog" ] || exit 42\n'
                       if artifact_check else '[ "$#" = 2 ] || exit 42\n')
                    + 'printf "verify %s %s\\n" "$1" "$2" >> "$PROBE_LOG"\n'
                    + f'exit {0 if valid_catalog else 41}\n'
                )
                mount = root / "bin/hdiutil"
                mount.write_text(
                    '#!/bin/sh\ncase "$1" in\n'
                    'attach) [ "$2" = "-readonly" ] && [ "$3" = "-nobrowse" ] && '
                    '[ "$4" = "-mountpoint" ] || exit 42; '
                    'mkdir -p "$5/MacTools.app/Contents"; touch "$5/MacTools.app/Contents/Info.plist";;\n'
                    'detach) rm -r "$2/MacTools.app";;\n'
                    '*) exit 42;;\nesac\n'
                )
                gh = root / "bin/gh"
                gh.write_text(
                    '#!/bin/sh\n[ "$2" = view ] && exit 1\n'
                    'printf "gh %s %s\\n" "$1" "$2" >> "$PROBE_LOG"\n'
                )
                git = root / "bin/git"
                git.write_text(
                    '#!/bin/sh\n[ "$*" = "fetch --no-tags origin +refs/heads/main:refs/remotes/origin/main" ] || exit 43\n'
                    'echo "refresh origin/main" >> "$PROBE_LOG"\n'
                )
                for executable in (verifier, mount, gh, git):
                    executable.chmod(0o700)
                log = root / "calls.log"
                result = subprocess.run(
                    ["/bin/bash", "-ec", f"(\n{body(verify_step)}\n)\n{body(upload_step)}"],
                    cwd=root, text=True, capture_output=True,
                    env={"PATH": f"{root / 'bin'}:/usr/bin:/bin", "RUNNER_TEMP": str(root),
                         "PROBE_LOG": str(log), "PROJECT_NAME": "MacTools", "VERSION": "2.2.5",
                         "BUILD_NUMBER": "83", "TAG": "v2.2.5", "PRERELEASE": "false", "CLI_ENABLED": "false",
                         "DMG_PATH": "candidate/MacTools.dmg", "SHA256_PATH": "candidate/MacTools.sha256",
                         "RELEASE_NOTES_PATH": "candidate/release-notes.md"},
                )
                self.assertEqual(result.returncode, 0 if valid_catalog else 41, result.stderr)
                expected = ["refresh origin/main"] if artifact_check else []
                expected.append("verify --app-version 2.2.5")
                if valid_catalog:
                    expected.append("gh release create")
                self.assertEqual(log.read_text().splitlines(), expected)
                self.assertFalse(list(root.glob("mactools-catalog-check.*")))

    def test_current_committed_catalog_can_advance_without_stranding_tagged_app(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            current = root / "docs/plugins/v7/host-2.2.5/catalog.json"
            current.parent.mkdir(parents=True)
            tagged = root / "tagged.json"
            unsigned = root / "unsigned.json"
            package = {
                "id": "example",
                "version": "1.0.0",
                "minimumHostVersion": "2.2.5",
                "pluginKitVersion": 7,
                "package": {"url": "https://example.invalid/package.zip", "sha256": "0" * 64, "size": 1},
            }
            catalog = {
                "schemaVersion": 3, "catalogID": "com.ggbond.mactools.plugins", "minimumHostVersion": "2.2.5",
                "pluginKitVersion": 7, "plugins": [package], "revoked": [],
            }

            def sign(destination: Path, *entries: dict, revoked: list[dict] | None = None) -> None:
                unsigned.write_text(json.dumps({**catalog, "plugins": entries, "revoked": revoked or []}))
                subprocess.run(
                    [str(SIGN_SCRIPT_PATH), "--input", str(unsigned), "--output", str(destination)],
                    check=True, capture_output=True, text=True,
                    env={**os.environ, "PLUGIN_CATALOG_PRIVATE_KEY_BASE64": TEST_PRIVATE_KEY_BASE64},
                )

            def git(*arguments: str) -> None:
                subprocess.run(["/usr/bin/git", *arguments], cwd=root, check=True, capture_output=True, text=True)

            def commit_current() -> None:
                git("add", str(current))
                git("-c", "user.name=Catalog Test", "-c", "user.email=fixture@example.invalid",
                    "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "-m", "catalog")
                git("update-ref", "refs/remotes/origin/main", "HEAD")

            def verify(deployed: Path) -> subprocess.CompletedProcess[str]:
                return subprocess.run(
                    [str(self.executable), "--app-version", "2.2.5", "--required-plugin-kit-version", "7",
                     "--expected-catalog", str(tagged), "--deployed-catalog", str(deployed),
                     "--public-key-base64", TEST_PUBLIC_KEY_BASE64, "--use-current-catalog"],
                    cwd=root, capture_output=True, text=True,
                )

            git("init", "-q")
            sign(tagged, {**package, "version": "1", "minimumHostVersion": "2.2"})
            sign(current, package)
            commit_current()
            equivalent = verify(current)
            self.assertEqual(equivalent.returncode, 0, equivalent.stderr)

            sign(current, {**package, "version": "1.1.0"})
            commit_current()
            advanced = verify(current)
            self.assertEqual(advanced.returncode, 0, advanced.stderr)
            stale_deployment = verify(tagged)
            self.assertNotEqual(stale_deployment.returncode, 0)
            self.assertIn("does not match origin/main:", stale_deployment.stderr)

            sign(current, {**package, "version": "1.2.0", "minimumHostVersion": "2.2.6"})
            commit_current()
            incompatible = verify(current)
            self.assertNotEqual(incompatible.returncode, 0)
            self.assertIn("does not preserve tagged package coverage", incompatible.stderr)

            extra = {**package, "id": "revoked-extra", "minimumHostVersion": "2.2.6"}
            sign(current, package, extra, revoked=[{"id": "revoked-extra", "versions": ["1.0.0"]}])
            commit_current()
            contradictory = verify(current)
            self.assertNotEqual(contradictory.returncode, 0)
            self.assertIn("advertises revoked package revoked-extra", contradictory.stderr)

    def test_catalog_routing_cli_uses_prerelease_base_version(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "Configs").mkdir()
            (root / "scripts").mkdir()
            routing = root / "scripts/plugin_catalog_routing.py"
            shutil.copyfile(ROOT_DIR / "scripts/plugin_catalog_routing.py", routing)
            for version, prefix in (("2.2.4-beta.1", ""), ("2.2.5-beta.1", "host-2.2.5/")):
                with self.subTest(version=version):
                    (root / "Configs/AppVersion.xcconfig").write_text(f"MARKETING_VERSION = {version}\n")
                    result = subprocess.run(
                        [sys.executable, "-B", str(routing), "--kit", "7"],
                        capture_output=True, text=True,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout.strip(), f"docs/plugins/v7/{prefix}catalog.json")

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
                            "version": "1.0.0",
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

    def test_v7_host_uses_the_compatible_catalog_path(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            for host, path in (("2.2.4", "v7/catalog.json"), ("2.2.5", "v7/host-2.2.5/catalog.json")):
                with self.subTest(host=host):
                    result = subprocess.run(
                        [str(self.executable), "--required-plugin-kit-version", "7", "--app-version", host,
                         "--public-key-base64", TEST_PUBLIC_KEY_BASE64],
                        cwd=directory, check=False, text=True, capture_output=True,
                    )
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(f"Required plugin catalog is missing: docs/plugins/{path}", result.stderr)

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
