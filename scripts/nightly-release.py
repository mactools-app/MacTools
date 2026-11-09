#!/usr/bin/env python3
"""Deterministic helpers for the public MacTools Nightly release workflow."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import plistlib
import posixpath
import re
import stat
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import xml.sax.saxutils as xml
import zipfile
from typing import Any, Dict, Iterable, List, Optional


VERSION_PATTERN = re.compile(
    r"^\s*(MARKETING_VERSION|CURRENT_PROJECT_VERSION)\s*=\s*(\S+)\s*$",
    re.MULTILINE,
)
BUILD_PATTERN = re.compile(r"^[0-9]+(?:\.[0-9]+)*$")
SHA_PATTERN = re.compile(r"^[0-9a-fA-F]{7,40}$")
NIGHTLY_TAG_PATTERN = re.compile(r"^nightly-([0-9]+)-([0-9]+)$")
REPOSITORY_PATTERN = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
ASSET_VERSION_PATTERN = re.compile(r"^[0-9]+(?:\.[0-9]+){1,3}$")
RELEASE_DOWNLOAD_TAG_PATTERN = re.compile(
    r"/releases/download/(nightly-[0-9]+-[0-9]+)/"
)
MAX_CLI_SIZE_BYTES = 64 * 1024 * 1024
CLI_ARCHITECTURES = ("arm64",)
CLI_DEPLOYMENT_TARGET = "14.0"
CLI_LICENSE_PATH = pathlib.Path(__file__).resolve().parents[1] / "LICENSE"
NIGHTLY_RELEASE_INTERFACE_VERSION = 4
DEPENDENCY_LINE_PATTERN = re.compile(
    r"^[ \t]+(.+) \(compatibility version [0-9]+(?:\.[0-9]+){0,2}, "
    r"current version [0-9]+(?:\.[0-9]+){0,2}"
    r"(?:, (?:weak|reexport|upward))?\)$"
)


def fail(message: str) -> None:
    raise SystemExit(message)


def validate_repository(repository: str) -> str:
    if not REPOSITORY_PATTERN.fullmatch(repository):
        fail("repository must use owner/name form")
    return repository


def read_app_version(config_path: pathlib.Path) -> Dict[str, str]:
    values = dict(VERSION_PATTERN.findall(config_path.read_text(encoding="utf-8")))
    if not values.get("MARKETING_VERSION"):
        fail(f"MARKETING_VERSION is missing from {config_path}")
    return values


def discover_plugin_metadata(source_dir: pathlib.Path) -> Dict[str, str]:
    manifests = sorted(source_dir.glob("*/plugin.json"))
    if not manifests:
        fail(f"No plugin manifests found under {source_dir}")

    versions = set()
    for manifest_path in manifests:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        versions.add(int(manifest["pluginKitVersion"]))
    if len(versions) != 1:
        fail("Nightly plugins must use exactly one PluginKit version")

    return {
        "PLUGIN_KIT_VERSION": str(next(iter(versions))),
        "PLUGIN_COUNT": str(len(manifests)),
    }


def make_metadata(
    config_path: pathlib.Path,
    plugins_dir: pathlib.Path,
    repository: str,
    source_sha: str,
    run_number: str,
    run_attempt: str,
) -> Dict[str, str]:
    if not run_number.isdigit() or int(run_number) <= 0:
        fail("run number must be a positive integer")
    if not run_attempt.isdigit() or int(run_attempt) <= 0:
        fail("run attempt must be a positive integer")
    if not SHA_PATTERN.fullmatch(source_sha):
        fail("source SHA must contain 7 to 40 hexadecimal characters")
    validate_repository(repository)

    version = read_app_version(config_path)["MARKETING_VERSION"]
    if not ASSET_VERSION_PATTERN.fullmatch(version):
        fail("app version is not safe for a Nightly asset name")
    build_number = f"{run_number}.{run_attempt}"
    tag = f"nightly-{run_number}-{run_attempt}"
    artifact_root = f"build/nightly/{tag}"
    cli_archive_name = f"mactools-cli-{version}-{build_number}-macos-arm64.zip"
    metadata = {
        "SCHEME": "MacTools",
        "CONFIGURATION": "Nightly",
        "VERSION": version,
        "BUILD_NUMBER": build_number,
        "TAG": tag,
        "SOURCE_SHA": source_sha.lower(),
        "SHORT_SHA": source_sha[:8].lower(),
        "ARTIFACT_ROOT": artifact_root,
        "DMG_PATH": f"{artifact_root}/MacTools-Nightly.dmg",
        "SHA256_PATH": f"{artifact_root}/MacTools-Nightly.sha256",
        "CLI_ARCHIVE_PATH": f"{artifact_root}/{cli_archive_name}",
        "CLI_SHA256_PATH": f"{artifact_root}/{cli_archive_name}.sha256",
        "PLUGIN_BUILD_DIR": f"{artifact_root}/PluginBuild",
        "PLUGIN_ASSETS_DIR": f"{artifact_root}/PluginAssets",
        "PLUGIN_CATALOG_PATH": f"{artifact_root}/catalog.json",
        "SIGNED_PLUGIN_CATALOG_PATH": f"{artifact_root}/catalog.signed.json",
        "PLUGIN_ASSET_BASE_URL": (
            f"https://github.com/{repository}/releases/download/{tag}"
        ),
        "PLUGIN_RELEASE_NOTES_URL": (
            f"https://github.com/{repository}/releases/tag/{tag}"
        ),
        "NIGHTLY_APPCAST_RELATIVE_PATH": "docs/nightly/appcast.xml",
    }
    metadata.update(discover_plugin_metadata(plugins_dir))
    metadata["NIGHTLY_PLUGIN_CATALOG_RELATIVE_PATH"] = (
        "docs/nightly/plugins/"
        f"v{metadata['PLUGIN_KIT_VERSION']}/catalog.json"
    )
    return metadata


def write_github_env(metadata: Dict[str, str], output_path: pathlib.Path) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("a", encoding="utf-8") as output:
        for key, value in metadata.items():
            if "\n" in value or "\r" in value:
                fail(f"metadata value for {key} contains a newline")
            output.write(f"{key}={value}\n")


def publication_decision(
    event_name: str,
    source_sha: str,
    previous_source_sha: str,
    repository_path: pathlib.Path = pathlib.Path("."),
) -> Dict[str, str]:
    """Skip only a conclusively unchanged scheduled run; manual runs force publication."""
    if event_name != "schedule":
        return {"decision": "publish", "reason": "Manual run: forced Nightly publication."}
    if not re.fullmatch(r"[0-9a-fA-F]{40}", previous_source_sha):
        return {"decision": "publish", "reason": "No usable advertised Nightly source; publishing normally."}
    if not re.fullmatch(r"[0-9a-fA-F]{40}", source_sha):
        return {"decision": "publish", "reason": "Current source is indeterminate; publishing normally."}

    try:
        comparison = subprocess.run(
            [
                "git", "diff", "--quiet", "--no-ext-diff", "--no-textconv",
                previous_source_sha, source_sha, "--", ".", ":(exclude)docs/nightly/**",
            ],
            cwd=repository_path,
            capture_output=True,
            timeout=30,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return {"decision": "publish", "reason": "Source comparison unavailable; publishing normally."}

    if comparison.returncode == 0:
        return {
            "decision": "unchanged",
            "reason": f"No changes outside docs/nightly/** since advertised source {previous_source_sha}.",
        }
    if comparison.returncode == 1:
        return {"decision": "publish", "reason": "Source changes found since the advertised Nightly."}
    return {"decision": "publish", "reason": "Source comparison failed; publishing normally."}


def write_release_notes(
    output_path: pathlib.Path,
    repository: str,
    version: str,
    build_number: str,
    source_sha: str,
) -> None:
    validate_repository(repository)
    if not BUILD_PATTERN.fullmatch(build_number):
        fail("build number must contain only numeric components")
    notes = f"""> [!WARNING]
> **MacTools Nightly is unstable.** It may contain unfinished features, regressions, or data-format changes. Keep the stable app installed and do not rely on Nightly for critical workflows.

This prerelease is an automated snapshot of the current MacTools source. It installs alongside stable MacTools and uses isolated preferences, Application Support data, plugins, URL routing, and update metadata.

- App version: `{version}`
- Nightly build: `{build_number}`
- Source commit: [`{source_sha}`](https://github.com/{repository}/commit/{source_sha})
- Optional CLI: `mactools-cli-{version}-{build_number}-macos-arm64.zip`

The CLI is a separate, optional download and requires the matching Nightly app's Command-Line Integration. Follow the [download and verification guide](https://github.com/{repository}/blob/{source_sha}/docs/testing/cli-nightly-distribution.md) before running it. To roll back, publish a known-good source commit that supports Nightly release interface v{NIGHTLY_RELEASE_INTERFACE_VERSION}. Signed assets for an existing Nightly tag are never replaced.
"""
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(notes, encoding="utf-8")


def write_appcast(
    output_path: pathlib.Path,
    repository: str,
    tag: str,
    version: str,
    build_number: str,
    signature: str,
    file_size: int,
    publication_date: str,
    release_notes: str,
) -> None:
    validate_repository(repository)
    if not NIGHTLY_TAG_PATTERN.fullmatch(tag):
        fail("Nightly tag must use nightly-<run>-<attempt>")
    if not BUILD_PATTERN.fullmatch(build_number):
        fail("build number must contain only numeric components")
    if file_size <= 0:
        fail("DMG file size must be positive")
    if not signature.strip():
        fail("Sparkle signature must not be empty")

    release_url = f"https://github.com/{repository}/releases/tag/{tag}"
    download_url = (
        f"https://github.com/{repository}/releases/download/"
        f"{tag}/MacTools-Nightly.dmg"
    )
    cdata_notes = release_notes.replace("]]>", "]]]]><![CDATA[>")
    content = f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>MacTools Nightly Releases</title>
    <description>Unstable public Nightly updates for MacTools.</description>
    <language>en</language>
    <item>
      <title>MacTools Nightly {xml.escape(version)} ({xml.escape(build_number)})</title>
      <link>{xml.escape(release_url)}</link>
      <sparkle:version>{xml.escape(build_number)}</sparkle:version>
      <sparkle:shortVersionString>{xml.escape(version)}</sparkle:shortVersionString>
      <description sparkle:format="markdown"><![CDATA[{cdata_notes}]]></description>
      <sparkle:fullReleaseNotesLink>{xml.escape(release_url)}</sparkle:fullReleaseNotesLink>
      <pubDate>{xml.escape(publication_date)}</pubDate>
      <enclosure url="{xml.escape(download_url)}" length="{file_size}" type="application/octet-stream" sparkle:edSignature="{xml.escape(signature)}" />
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
    </item>
  </channel>
</rss>
'''
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(content, encoding="utf-8")
    ET.parse(output_path)


def executable_bundle_identifier(path: pathlib.Path) -> str:
    # Use the same CFBundle API as CLIServiceConfiguration, including unsigned Mach-O plists.
    script = '''import Foundation
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let info = CFBundleCopyInfoDictionaryForURL(url as CFURL) as? [String: Any]
print(info?["CFBundleIdentifier"] as? String ?? "")
'''
    try:
        result = subprocess.run(
            ["xcrun", "swift", "-e", script, str(path)],
            capture_output=True, text=True, check=True, timeout=60,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        fail(f"Cannot read the embedded Nightly executable Info.plist: {path}")
    return result.stdout.strip()


def executable_bundle_versions(path: pathlib.Path) -> tuple[str, str]:
    script = '''import Foundation
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let info = CFBundleCopyInfoDictionaryForURL(url as CFURL) as? [String: Any]
print(info?["CFBundleShortVersionString"] as? String ?? "")
print(info?["CFBundleVersion"] as? String ?? "")
'''
    try:
        result = subprocess.run(
            ["xcrun", "swift", "-e", script, str(path)],
            capture_output=True, text=True, check=True, timeout=60,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        fail(f"Cannot read the embedded Nightly executable versions: {path}")
    values = result.stdout.splitlines()
    if len(values) != 2 or not all(values):
        fail(f"Nightly executable versions are missing: {path}")
    return values[0], values[1]


def read_cli_license() -> bytes:
    try:
        license_bytes = CLI_LICENSE_PATH.read_bytes()
    except OSError:
        fail("Repository GPL license is missing or unreadable")
    if not license_bytes:
        fail("Repository GPL license is empty")
    return license_bytes


def create_cli_archive(cli_path: pathlib.Path, output_path: pathlib.Path) -> None:
    if not cli_path.is_file() or not cli_path.stat().st_mode & stat.S_IXUSR:
        fail(f"Nightly CLI is missing or not executable: {cli_path}")
    if not 0 < cli_path.stat().st_size <= MAX_CLI_SIZE_BYTES:
        fail(f"Nightly CLI has an invalid size: {cli_path}")
    contents = [
        ("mactools", cli_path.read_bytes(), 0o755),
        ("LICENSE", read_cli_license(), 0o644),
    ]
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output_path, "w") as archive:
        for name, data, mode in contents:
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 3
            info.external_attr = (stat.S_IFREG | mode) << 16
            archive.writestr(info, data)


def verify_sha256(path: pathlib.Path, checksum_path: pathlib.Path) -> None:
    if not path.is_file() or not checksum_path.is_file():
        fail("Nightly CLI archive or checksum is missing")
    expected_line = checksum_path.read_text(encoding="utf-8").strip()
    match = re.fullmatch(r"([0-9a-f]{64})  ([^/\r\n]+)", expected_line)
    if match is None or match.group(2) != path.name:
        fail("Nightly CLI checksum file has an invalid format or filename")
    digest = hashlib.sha256()
    with path.open("rb") as archive:
        while chunk := archive.read(1024 * 1024):
            digest.update(chunk)
    actual = digest.hexdigest()
    if actual != match.group(1):
        fail("Nightly CLI archive checksum does not match")


def verify_cli_signature(
    cli_path: pathlib.Path,
    expected_identifier: str,
    expected_team_identifier: str,
) -> None:
    def requirement_literal(value: str) -> str:
        return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'

    requirement = (
        f"anchor apple generic and identifier {requirement_literal(expected_identifier)} "
        f"and certificate leaf[subject.OU] = {requirement_literal(expected_team_identifier)} "
        "and certificate 1[field.1.2.840.113635.100.6.2.6] exists "
        "and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
    )
    try:
        subprocess.run(
            [
                "/usr/bin/codesign", "--verify", "--strict", "--verbose=2",
                "--all-architectures", f"-R={requirement}", str(cli_path),
            ],
            capture_output=True, text=True, check=True, timeout=30,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        fail("Nightly CLI signature verification failed")

    for architecture in CLI_ARCHITECTURES:
        try:
            signature = subprocess.run(
                [
                    "/usr/bin/codesign", "--display", "--verbose=4",
                    "--arch", architecture, str(cli_path),
                ],
                capture_output=True, text=True, check=True, timeout=30,
            ).stderr
        except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
            fail(f"Cannot inspect Nightly CLI {architecture} signature")
        identifiers = re.findall(r"^Identifier=(.+)$", signature, re.MULTILINE)
        teams = re.findall(r"^TeamIdentifier=(.+)$", signature, re.MULTILINE)
        if identifiers != [expected_identifier] or teams != [expected_team_identifier]:
            fail(
                f"Nightly CLI {architecture} signature identity does not match "
                "the Nightly broker policy"
            )
        if not re.search(r"^Authority=Developer ID Application:", signature, re.MULTILINE):
            fail(f"Nightly CLI {architecture} is not signed with Developer ID Application")
        if not re.search(r"^CodeDirectory .+\(runtime\)", signature, re.MULTILINE):
            fail(f"Nightly CLI {architecture} signature does not enable the hardened runtime")


def verify_cli_architectures(cli_path: pathlib.Path) -> None:
    try:
        result = subprocess.run(
            ["/usr/bin/lipo", "-archs", str(cli_path)],
            capture_output=True, text=True, check=True, timeout=30,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        fail("Cannot inspect Nightly CLI architectures")
    if set(result.stdout.split()) != set(CLI_ARCHITECTURES):
        fail("Nightly CLI must contain exactly the arm64 architecture")


def verify_cli_slice_metadata(
    cli_path: pathlib.Path,
    expected_identifier: str,
    expected_version: str,
    expected_build_number: str,
) -> None:
    architecture = CLI_ARCHITECTURES[0]
    if executable_bundle_identifier(cli_path) != expected_identifier:
        fail(f"Nightly CLI {architecture} embedded identifier does not match")
    if executable_bundle_versions(cli_path) != (
        expected_version, expected_build_number,
    ):
        fail(f"Nightly CLI {architecture} embedded version does not match")


def verify_cli_dependencies(cli_path: pathlib.Path) -> None:
    try:
        result = subprocess.run(
            ["/usr/bin/otool", "-L", str(cli_path)],
            capture_output=True, text=True, check=True, timeout=30,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        fail("Cannot inspect Nightly CLI dynamic-library dependencies")
    lines = result.stdout.splitlines()
    expected_headers = {
        f"{cli_path}:",
        f"{cli_path} (architecture {CLI_ARCHITECTURES[0]}):",
    }
    if not lines or lines[0] not in expected_headers:
        fail("Nightly CLI dynamic-library dependency output is malformed")
    dependencies = []
    for line in lines[1:]:
        if not line.strip():
            fail("Nightly CLI dynamic-library dependency output is malformed")
        match = DEPENDENCY_LINE_PATTERN.fullmatch(line)
        if match is None:
            fail("Nightly CLI dynamic-library dependency output is malformed")
        dependency = match.group(1)
        if any(ord(character) < 32 or ord(character) == 127 for character in dependency):
            fail("Nightly CLI dynamic-library dependency output is malformed")
        dependencies.append(dependency)
    if not dependencies:
        fail("Nightly CLI dynamic-library dependency output is malformed")
    unexpected = [
        dependency for dependency in dependencies
        if dependency != posixpath.normpath(dependency)
        or not dependency.startswith(("/System/Library/", "/usr/lib/"))
    ]
    if unexpected:
        fail(f"Nightly CLI has unexpected dynamic-library dependencies: {unexpected}")


def verify_cli_deployment_target(cli_path: pathlib.Path) -> None:
    try:
        result = subprocess.run(
            ["xcrun", "vtool", "-show-build", str(cli_path)],
            capture_output=True, text=True, check=True, timeout=30,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        fail("Cannot inspect Nightly CLI deployment target")
    platforms = re.findall(r"^\s+platform (\S+)$", result.stdout, re.MULTILINE)
    minimum_versions = re.findall(r"^\s+minos (\S+)$", result.stdout, re.MULTILINE)
    if platforms != ["MACOS"] or minimum_versions != [CLI_DEPLOYMENT_TARGET]:
        fail(
            "Nightly CLI must target macOS "
            f"{CLI_DEPLOYMENT_TARGET}; found platform={platforms}, minos={minimum_versions}"
        )


def verify_cli_version_output(
    cli_path: pathlib.Path,
    expected_version: str,
    expected_build_number: str,
) -> None:
    try:
        result = subprocess.run(
            [str(cli_path), "version", "--json"],
            capture_output=True, text=True, check=True, timeout=5,
        )
        output = json.loads(result.stdout)
    except (
        OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired,
        json.JSONDecodeError,
    ):
        fail("Nightly CLI version --json smoke test failed")
    if not isinstance(output, dict):
        fail("Nightly CLI version output does not match its release metadata")
    data = output.get("data")
    if (
        output.get("command") != "version"
        or output.get("outcome") != "completed"
        or not isinstance(data, dict)
        or data.get("cliVersion") != expected_version
        or data.get("cliBuild") != expected_build_number
    ):
        fail("Nightly CLI version output does not match its release metadata")


def verify_notarization_result(result_path: pathlib.Path) -> None:
    try:
        result = json.loads(result_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        fail("Nightly notarization result is missing or malformed")
    if not isinstance(result, dict) or result.get("status") != "Accepted":
        fail("Nightly notarization status is not Accepted")
    if not isinstance(result.get("id"), str) or not result["id"].strip():
        fail("Nightly notarization result is missing its request ID")


def verify_cli_archive(
    archive_path: pathlib.Path,
    checksum_path: pathlib.Path,
    bundle_identifier_prefix: str,
    team_identifier: str,
    version: str,
    build_number: str,
    execute: bool = True,
    channel: str = "nightly",
) -> None:
    if channel not in ("nightly", "stable"):
        fail("Unsupported CLI release channel")
    verify_sha256(archive_path, checksum_path)
    expected_license = read_cli_license()
    try:
        with zipfile.ZipFile(archive_path) as archive:
            entries = archive.infolist()
            if len(entries) != 2 or {entry.filename for entry in entries} != {"mactools", "LICENSE"}:
                fail("Nightly CLI archive must contain only mactools and LICENSE")
            entry = archive.getinfo("mactools")
            if entry.flag_bits & 0x1:
                fail("Nightly CLI archive must not encrypt the executable")
            mode = entry.external_attr >> 16
            if not stat.S_ISREG(mode) or mode & 0o777 != 0o755:
                fail("Nightly CLI archive executable must use mode 0755")
            if not 0 < entry.file_size <= MAX_CLI_SIZE_BYTES:
                fail("Nightly CLI archive executable has an invalid size")
            license_entry = archive.getinfo("LICENSE")
            license_mode = license_entry.external_attr >> 16
            if (
                license_entry.flag_bits & 0x1
                or not stat.S_ISREG(license_mode)
                or license_mode & 0o777 != 0o644
                or license_entry.file_size != len(expected_license)
                or archive.read(license_entry) != expected_license
            ):
                fail("Nightly CLI archive GPL license is missing, modified, or has invalid metadata")
            cli_bytes = archive.read(entry)
    except (OSError, zipfile.BadZipFile, RuntimeError):
        fail("Nightly CLI archive cannot be read")

    with tempfile.TemporaryDirectory() as temporary_directory:
        cli_path = pathlib.Path(temporary_directory) / "mactools"
        cli_path.write_bytes(cli_bytes)
        cli_path.chmod(0o755)
        suffix = ".mactools.nightly.cli" if channel == "nightly" else ".mactools.cli"
        expected_identifier = bundle_identifier_prefix + suffix
        verify_cli_architectures(cli_path)
        verify_cli_deployment_target(cli_path)
        verify_cli_slice_metadata(
            cli_path, expected_identifier, version, build_number,
        )
        verify_cli_signature(cli_path, expected_identifier, team_identifier)
        verify_cli_dependencies(cli_path)
        if execute:
            verify_cli_version_output(cli_path, version, build_number)


def verify_nightly_cli(
    app_path: pathlib.Path, bundle_identifier_prefix: str,
    cli_path: pathlib.Path | None = None, signed: bool = False,
) -> None:
    host_identifier = f"{bundle_identifier_prefix}.mactools.nightly"
    broker_identifier = f"{host_identifier}.cli-broker"
    agent_path = app_path / "Contents/Library/LaunchAgents/app.ggbond.MacTools.cli-broker.plist"
    if not agent_path.is_file():
        fail("Nightly CLI broker LaunchAgent is missing")
    with agent_path.open("rb") as file:
        agent = plistlib.load(file)
    expected = {
        "Label": broker_identifier,
        "MachServices": {broker_identifier: True},
        "BundleProgram": "Contents/MacOS/MacToolsCLIBroker",
    }
    for key, value in expected.items():
        if agent.get(key) != value:
            fail(f"Nightly CLI LaunchAgent {key} is not isolated: {agent.get(key)!r}")
    broker_path = app_path / "Contents/MacOS/MacToolsCLIBroker"
    executables = [(broker_path, broker_identifier)]
    if cli_path is not None:
        executables.append((cli_path, f"{host_identifier}.cli"))
    for path, identifier in executables:
        if not path.is_file() or executable_bundle_identifier(path) != identifier:
            fail(f"Nightly executable must embed {identifier}: {path}")
    if signed:
        try:
            signature = subprocess.run(
                ["/usr/bin/codesign", "--display", "--verbose=4", str(broker_path)],
                capture_output=True, text=True, check=True,
            )
        except (OSError, subprocess.CalledProcessError):
            fail("Cannot inspect the signed Nightly CLI broker")
        if re.findall(r"^Identifier=(.+)$", signature.stderr, re.MULTILINE) != [broker_identifier]:
            fail("Nightly CLI broker signing identifier is not isolated")


def verify_nightly_app(
    app_path: pathlib.Path,
    bundle_identifier_prefix: str,
    version: str,
    build_number: str,
    plugin_kit_version: int,
    cli_path: pathlib.Path | None = None,
    signed: bool = False,
) -> None:
    if plugin_kit_version < 1:
        fail("PluginKit version must be positive")
    app_info_path = app_path / "Contents/Info.plist"
    extension_info_path = (
        app_path
        / "Contents/PlugIns/RightClickFinderSync.appex/Contents/Info.plist"
    )
    if not app_info_path.is_file() or not extension_info_path.is_file():
        fail(f"Nightly app or Finder Sync Info.plist is missing under {app_path}")

    with app_info_path.open("rb") as file:
        app_info = plistlib.load(file)
    with extension_info_path.open("rb") as file:
        extension_info = plistlib.load(file)

    expected_app_values = {
        "CFBundleDisplayName": "MacTools Nightly",
        "CFBundleIdentifier": f"{bundle_identifier_prefix}.mactools.nightly",
        "CFBundleShortVersionString": version,
        "CFBundleVersion": build_number,
        "MTApplicationSupportDirectoryName": "MacTools Nightly",
        "MTReleaseChannel": "nightly",
        "MTPluginCatalogURL": (
            "https://mactools.ggbond.app/nightly/plugins/"
            f"v{plugin_kit_version}/catalog.json"
        ),
        "MTRightClickConfigurationHomeRelativePath": (
            "Library/Application Support/MacTools Nightly/right-click-menu.json"
        ),
        "SUFeedURL": "https://mactools.ggbond.app/nightly/appcast.xml",
    }
    for key, expected in expected_app_values.items():
        if app_info.get(key) != expected:
            fail(f"Nightly app {key} is {app_info.get(key)!r}; expected {expected!r}")

    schemes = [
        scheme
        for item in app_info.get("CFBundleURLTypes", [])
        for scheme in item.get("CFBundleURLSchemes", [])
    ]
    if schemes != ["mactools-nightly"]:
        fail(f"Nightly URL schemes are {schemes!r}; expected ['mactools-nightly']")

    verify_nightly_cli(app_path, bundle_identifier_prefix, cli_path, signed)

    expected_extension_values = {
        "CFBundleDisplayName": "MacTools Nightly 右键工具",
        "CFBundleIdentifier": (
            f"{bundle_identifier_prefix}.mactools.nightly.right-click.finder-sync"
        ),
        "CFBundleShortVersionString": version,
        "CFBundleVersion": build_number,
        "MTRightClickHostURLScheme": "mactools-nightly",
        "MTRightClickToolbarItemName": "MacTools Nightly",
        "MTRightClickConfigurationHomeRelativePath": (
            "Library/Application Support/MacTools Nightly/right-click-menu.json"
        ),
    }
    for key, expected in expected_extension_values.items():
        if extension_info.get(key) != expected:
            fail(
                f"Nightly Finder Sync {key} is {extension_info.get(key)!r}; "
                f"expected {expected!r}"
            )


def verify_nightly_catalog(
    catalog_path: pathlib.Path,
    plugins_dir: pathlib.Path,
    repository: str,
    tag: str,
    build_number: str,
) -> None:
    validate_repository(repository)
    catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    source_manifests = {
        json.loads(path.read_text(encoding="utf-8"))["id"]: json.loads(
            path.read_text(encoding="utf-8")
        )
        for path in plugins_dir.glob("*/plugin.json")
    }
    entries = {entry["id"]: entry for entry in catalog.get("plugins", [])}
    if set(entries) != set(source_manifests):
        missing = sorted(set(source_manifests) - set(entries))
        extra = sorted(set(entries) - set(source_manifests))
        fail(f"Nightly catalog plugin set differs; missing={missing}, extra={extra}")

    expected_url_prefix = (
        f"https://github.com/{repository}/releases/download/"
        f"{tag}/"
    )
    for plugin_id, entry in entries.items():
        source = source_manifests[plugin_id]
        source_major = str(source["version"]).split(".", maxsplit=1)[0]
        if entry["version"] != f"{source_major}.{build_number}":
            fail(f"Nightly version mismatch for {plugin_id}")
        if entry["pluginKitVersion"] != source["pluginKitVersion"]:
            fail(f"Nightly PluginKit mismatch for {plugin_id}")
        if not entry["package"]["url"].startswith(expected_url_prefix):
            fail(f"Nightly package URL mismatch for {plugin_id}")
    signature = catalog.get("signature") or {}
    if signature.get("algorithm") != "ed25519" or not signature.get("value"):
        fail("Nightly catalog is not signed with Ed25519")


def read_nightly_appcast_tag(appcast_path: pathlib.Path) -> str:
    try:
        root = ET.parse(appcast_path).getroot()
    except (ET.ParseError, OSError) as error:
        fail(f"Nightly appcast cannot be parsed: {appcast_path}: {error}")
    for enclosure in root.iter("enclosure"):
        match = RELEASE_DOWNLOAD_TAG_PATTERN.search(enclosure.attrib.get("url", ""))
        if match:
            return match.group(1)
    fail(f"Nightly appcast does not contain a valid release tag: {appcast_path}")


def verify_nightly_helper_signatures(packages_dir: pathlib.Path, bundle_identifier_prefix: str) -> None:
    helpers = [
        ("fan-control", "FanControl", "mactools-fan-smc-helper"),
        ("battery-charge-limit", "BatteryChargeLimit", "mactools-battery-smc-helper"),
    ]
    for plugin_id, bundle_name, helper_name in helpers:
        helper = (
            packages_dir / f"{plugin_id}.mactoolsplugin" / f"{bundle_name}.bundle"
            / "Contents/Resources/SMCHelper" / helper_name
        )
        try:
            signature = subprocess.run(
                ["/usr/bin/codesign", "--display", "--verbose=4", str(helper)],
                capture_output=True, text=True, check=True,
            )
        except (OSError, subprocess.CalledProcessError):
            fail(f"Cannot inspect the signed Nightly helper for {plugin_id}")
        expected = f"{bundle_identifier_prefix}.mactools.plugins.{plugin_id}.smc-helper.nightly"
        identifiers = re.findall(r"^Identifier=(.+)$", signature.stderr, re.MULTILINE)
        if identifiers != [expected]:
            fail(f"Nightly helper signing identifier is not isolated for {plugin_id}")


def stale_nightly_tags(
    releases: Iterable[Dict[str, Any]],
    keep: int,
    preserve_tags: Iterable[str] = (),
) -> List[str]:
    if keep < 1:
        fail("retention count must be positive")
    preserved = set(preserve_tags)
    for tag in preserved:
        if not NIGHTLY_TAG_PATTERN.fullmatch(tag):
            fail(f"preserved Nightly tag is invalid: {tag}")
    nightly = [
        release
        for release in releases
        if release.get("isPrerelease") is True
        and release.get("isDraft") is not True
        and NIGHTLY_TAG_PATTERN.fullmatch(str(release.get("tagName", "")))
    ]
    nightly.sort(key=lambda release: str(release.get("publishedAt", "")), reverse=True)
    return [
        str(release["tagName"])
        for release in nightly[keep:]
        if str(release["tagName"]) not in preserved
    ]


def stale_nightly_draft_ids(releases: Iterable[Dict[str, Any]]) -> List[int]:
    draft_ids: List[int] = []
    for release in releases:
        if release.get("isDraft") is not True or release.get("isPrerelease") is not True:
            continue
        if not NIGHTLY_TAG_PATTERN.fullmatch(str(release.get("tagName", ""))):
            continue
        release_id = release.get("databaseId")
        if isinstance(release_id, bool) or not isinstance(release_id, int) or release_id <= 0:
            fail("Nightly draft release ID must be a positive integer")
        draft_ids.append(release_id)
    return draft_ids


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser()
    subparsers = root.add_subparsers(dest="command", required=True)

    metadata = subparsers.add_parser("metadata")
    metadata.add_argument("--app-version-config", type=pathlib.Path, required=True)
    metadata.add_argument("--plugins-dir", type=pathlib.Path, required=True)
    metadata.add_argument("--repository", required=True)
    metadata.add_argument("--source-sha", required=True)
    metadata.add_argument("--run-number", required=True)
    metadata.add_argument("--run-attempt", required=True)
    metadata.add_argument("--github-env", type=pathlib.Path)

    notes = subparsers.add_parser("notes")
    notes.add_argument("--output", type=pathlib.Path, required=True)
    notes.add_argument("--repository", required=True)
    notes.add_argument("--version", required=True)
    notes.add_argument("--build-number", required=True)
    notes.add_argument("--source-sha", required=True)

    appcast = subparsers.add_parser("appcast")
    appcast.add_argument("--output", type=pathlib.Path, required=True)
    appcast.add_argument("--repository", required=True)
    appcast.add_argument("--tag", required=True)
    appcast.add_argument("--version", required=True)
    appcast.add_argument("--build-number", required=True)
    appcast.add_argument("--signature", required=True)
    appcast.add_argument("--file-size", required=True, type=int)
    appcast.add_argument("--publication-date", required=True)
    appcast.add_argument("--release-notes", type=pathlib.Path, required=True)

    verify_app = subparsers.add_parser("verify-app")
    verify_app.add_argument("--app", type=pathlib.Path, required=True)
    verify_app.add_argument("--bundle-identifier-prefix", required=True)
    verify_app.add_argument("--version", required=True)
    verify_app.add_argument("--build-number", required=True)
    verify_app.add_argument("--plugin-kit-version", required=True, type=int)
    verify_app.add_argument("--cli", type=pathlib.Path, help="Also verify the separately built CLI prototype")
    verify_app.add_argument("--signed", action="store_true", help="Also verify the broker signing identifier")

    verify_catalog = subparsers.add_parser("verify-catalog")
    verify_catalog.add_argument("--catalog", type=pathlib.Path, required=True)
    verify_catalog.add_argument("--plugins-dir", type=pathlib.Path, required=True)
    verify_catalog.add_argument("--repository", required=True)
    verify_catalog.add_argument("--tag", required=True)
    verify_catalog.add_argument("--build-number", required=True)

    verify_helpers = subparsers.add_parser("verify-helper-signatures")
    verify_helpers.add_argument("--packages-dir", type=pathlib.Path, required=True)
    verify_helpers.add_argument("--bundle-identifier-prefix", required=True)

    package_cli = subparsers.add_parser("package-cli")
    package_cli.add_argument("--cli", type=pathlib.Path, required=True)
    package_cli.add_argument("--output", type=pathlib.Path, required=True)

    verify_cli = subparsers.add_parser("verify-cli-archive")
    verify_cli.add_argument("--channel", choices=("nightly", "stable"), default="nightly")
    verify_cli.add_argument("--archive", type=pathlib.Path, required=True)
    verify_cli.add_argument("--checksum", type=pathlib.Path, required=True)
    verify_cli.add_argument("--bundle-identifier-prefix", required=True)
    verify_cli.add_argument("--team-identifier", required=True)
    verify_cli.add_argument("--version", required=True)
    verify_cli.add_argument("--build-number", required=True)
    verify_cli.add_argument(
        "--skip-execution", action="store_true",
        help="Perform static artifact checks without launching the CLI",
    )

    verify_notarization = subparsers.add_parser("verify-notarization")
    verify_notarization.add_argument("--input", type=pathlib.Path, required=True)

    stale_tags = subparsers.add_parser("stale-tags")
    stale_tags.add_argument("--input", type=pathlib.Path, required=True)
    stale_tags.add_argument("--keep", type=int, default=14)
    stale_tags.add_argument("--preserve-tag", action="append", default=[])

    stale_drafts = subparsers.add_parser("stale-draft-ids")
    stale_drafts.add_argument("--input", type=pathlib.Path, required=True)

    appcast_tag = subparsers.add_parser("appcast-tag")
    appcast_tag.add_argument("--input", type=pathlib.Path, required=True)

    plugin_kit_version = subparsers.add_parser("plugin-kit-version")
    plugin_kit_version.add_argument("--plugins-dir", type=pathlib.Path, required=True)

    subparsers.add_parser("release-interface-version")

    decision = subparsers.add_parser("publication-decision")
    decision.add_argument("--event-name", required=True)
    decision.add_argument("--source-sha", required=True)
    decision.add_argument("--previous-source-sha", default="")
    decision.add_argument("--github-output", type=pathlib.Path, required=True)
    decision.add_argument("--github-step-summary", type=pathlib.Path, required=True)
    return root


def main() -> None:
    args = parser().parse_args()
    if args.command == "metadata":
        metadata = make_metadata(
            config_path=args.app_version_config,
            plugins_dir=args.plugins_dir,
            repository=args.repository,
            source_sha=args.source_sha,
            run_number=args.run_number,
            run_attempt=args.run_attempt,
        )
        if args.github_env:
            write_github_env(metadata, args.github_env)
        else:
            for key, value in metadata.items():
                print(f"{key}={value}")
    elif args.command == "notes":
        write_release_notes(
            args.output,
            args.repository,
            args.version,
            args.build_number,
            args.source_sha,
        )
    elif args.command == "appcast":
        write_appcast(
            output_path=args.output,
            repository=args.repository,
            tag=args.tag,
            version=args.version,
            build_number=args.build_number,
            signature=args.signature,
            file_size=args.file_size,
            publication_date=args.publication_date,
            release_notes=args.release_notes.read_text(encoding="utf-8"),
        )
    elif args.command == "verify-app":
        verify_nightly_app(
            args.app,
            args.bundle_identifier_prefix,
            args.version,
            args.build_number,
            args.plugin_kit_version,
            args.cli,
            args.signed,
        )
    elif args.command == "verify-catalog":
        verify_nightly_catalog(
            args.catalog,
            args.plugins_dir,
            args.repository,
            args.tag,
            args.build_number,
        )
    elif args.command == "verify-helper-signatures":
        verify_nightly_helper_signatures(args.packages_dir, args.bundle_identifier_prefix)
    elif args.command == "package-cli":
        create_cli_archive(args.cli, args.output)
    elif args.command == "verify-cli-archive":
        verify_cli_archive(
            args.archive,
            args.checksum,
            args.bundle_identifier_prefix,
            args.team_identifier,
            args.version,
            args.build_number,
            execute=not args.skip_execution, channel=args.channel,
        )
    elif args.command == "verify-notarization":
        verify_notarization_result(args.input)
    elif args.command == "stale-tags":
        releases = json.loads(args.input.read_text(encoding="utf-8"))
        for tag in stale_nightly_tags(releases, args.keep, args.preserve_tag):
            print(tag)
    elif args.command == "stale-draft-ids":
        releases = json.loads(args.input.read_text(encoding="utf-8"))
        for release_id in stale_nightly_draft_ids(releases):
            print(release_id)
    elif args.command == "appcast-tag":
        print(read_nightly_appcast_tag(args.input))
    elif args.command == "plugin-kit-version":
        print(discover_plugin_metadata(args.plugins_dir)["PLUGIN_KIT_VERSION"])
    elif args.command == "release-interface-version":
        print(NIGHTLY_RELEASE_INTERFACE_VERSION)
    elif args.command == "publication-decision":
        decision = publication_decision(args.event_name, args.source_sha, args.previous_source_sha)
        write_github_env(decision, args.github_output)
        with args.github_step_summary.open("a", encoding="utf-8") as summary:
            summary.write(f"Nightly decision: **{decision['decision']}**. {decision['reason']}\n")
        print(decision["reason"])


if __name__ == "__main__":
    main()
