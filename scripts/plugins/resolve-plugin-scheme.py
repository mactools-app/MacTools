#!/usr/bin/env python3
"""Resolve the xcodebuild scheme(s) for one or more plugins.

Accepts plugin directory names or plugin IDs via --plugin (repeatable or a
comma-separated list), scans Plugins/*/plugin.json, and prints the scheme
configured in build.scheme (or the derived default <CamelCaseId>Plugin,
matching the projection in scripts/plugins/generate-plugin-project-config.rb).

With --list each resolved scheme is printed on its own line so the caller can
build every selected plugin. Without it, exactly one plugin must be requested.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
PLUGINS_DIR = REPO_ROOT / "Plugins"


def camelize_id(value: str) -> str:
    """Mirror the Ruby generator's camelize_id: split on non-alphanumerics."""
    parts = [part for part in re.split(r"[^A-Za-z0-9]+", value) if part]
    return "".join(part[0].upper() + part[1:] for part in parts)


def plugin_scheme(manifest: dict) -> str:
    scheme = (manifest.get("build") or {}).get("scheme")
    if scheme:
        return scheme
    return camelize_id(manifest.get("id", "")) + "Plugin"


def load_plugins(plugins_dir: pathlib.Path) -> list[tuple[str, dict]]:
    records: list[tuple[str, dict]] = []
    for manifest_path in sorted(plugins_dir.iterdir()):
        manifest_file = manifest_path / "plugin.json"
        if not manifest_file.is_file():
            continue
        try:
            data = json.loads(manifest_file.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        records.append((manifest_path.name, data))
    return records


def resolve_filter(filters: list[str], plugins: list[tuple[str, dict]]) -> list[str]:
    resolved: list[str] = []
    for plugin_filter in filters:
        matched = next(
            (
                data
                for name, data in plugins
                if name == plugin_filter or data.get("id", "") == plugin_filter
            ),
            None,
        )
        if matched is None:
            print(
                f"No plugin matched '{plugin_filter}' in {PLUGINS_DIR}",
                file=sys.stderr,
            )
            raise SystemExit(1)
        scheme = plugin_scheme(matched)
        if not scheme:
            print(
                f"Could not derive a scheme for plugin '{plugin_filter}'",
                file=sys.stderr,
            )
            raise SystemExit(1)
        resolved.append(scheme)
    return resolved


def split_filters(raw: str) -> list[str]:
    return [item.strip() for item in raw.split(",") if item.strip()]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--plugin",
        required=True,
        action="append",
        help="Plugin directory name or plugin ID (repeatable or comma-separated)",
    )
    parser.add_argument(
        "--plugins-dir",
        default=str(PLUGINS_DIR),
        help="Plugin source directory (default: <repo>/Plugins)",
    )
    parser.add_argument(
        "--list",
        action="store_true",
        help="Print one scheme per line for every requested plugin",
    )
    args = parser.parse_args()

    plugins_dir = pathlib.Path(args.plugins_dir)
    if not plugins_dir.is_dir():
        print(f"Plugin source directory not found: {plugins_dir}", file=sys.stderr)
        return 1

    filters: list[str] = []
    for value in args.plugin:
        filters.extend(split_filters(value))
    if not filters:
        print("At least one --plugin value is required.", file=sys.stderr)
        return 1
    if not args.list and len(filters) != 1:
        print(
            "Exactly one --plugin is required without --list; "
            "use --list for multiple plugins.",
            file=sys.stderr,
        )
        return 1

    plugins = load_plugins(plugins_dir)
    for scheme in resolve_filter(filters, plugins):
        print(scheme)
    return 0


if __name__ == "__main__":
    sys.exit(main())
