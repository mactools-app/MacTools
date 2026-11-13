#!/usr/bin/env python3
"""Safely remove the locally installed Debug app and installed plugin packages.

This is the helper behind 'make clean-installed'. It is intentionally separate
from 'make clean', which stays local to the checkout.

Every path is realpath-normalized and must resolve strictly inside the user's
home directory. All roots and all candidate targets are validated before
anything is deleted, so a bad override (including a trailing-slash or dot/..
variant of the home directory, an ancestor such as '/Users', or a symlink that
redirects a store directory) aborts with nothing removed.

The Debug app must itself be a real bundle (not a symlink, so a symlinked
'MacTools Dev.app' cannot redirect deletion to another app) and its
CFBundleIdentifier must match --expected-bundle-id. Only the configured Debug
app and identifiable '.mactoolsplugin' packages inside the plugin store and its
sibling Quarantined directory are removed.
"""
from __future__ import annotations

import argparse
import os
import pathlib
import plistlib
import shutil
import sys


def resolve(path: str) -> str:
    """Canonicalize a path, resolving '.', '..', symlinks and trailing slashes."""
    return os.path.realpath(os.path.abspath(os.path.expanduser(path)))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, help="Installed Debug app bundle path")
    parser.add_argument("--plugins-dir", required=True, help="Installed plugin store directory")
    parser.add_argument(
        "--expected-bundle-id",
        default="",
        help="Expected Debug app CFBundleIdentifier (empty disables app removal)",
    )
    args = parser.parse_args()

    home = resolve("~")
    app_resolved = resolve(args.app)
    plugins_dir = resolve(args.plugins_dir)
    quarantined = resolve(os.path.join(os.path.dirname(args.plugins_dir), "Quarantined"))

    def unsafe(path: str) -> bool:
        return (not path) or path == os.sep or path == home or not path.startswith(home + os.sep)

    # Preflight every root before touching the disk.
    roots = (("plugin store", plugins_dir), ("Quarantined store", quarantined))
    for label, path in roots:
        if unsafe(path):
            print(f"Refusing to remove unsafe {label} path: {path}", file=sys.stderr)
            return 1

    if os.path.islink(args.app):
        print(f"Refusing to remove symlinked app path: {args.app}", file=sys.stderr)
        return 1
    if unsafe(app_resolved):
        print(f"Refusing to remove unsafe Debug app path: {app_resolved}", file=sys.stderr)
        return 1
    if not app_resolved.endswith(".app"):
        print(f"Refusing to remove non-app bundle path: {app_resolved}", file=sys.stderr)
        return 1

    # Collect identifiable targets; never delete the store directories
    # themselves (only .mactoolsplugin packages inside them).
    targets: list[pathlib.Path] = []
    if os.path.exists(app_resolved):
        if not args.expected_bundle_id:
            print(
                "Refusing to remove Debug app without an expected bundle identifier: "
                f"{app_resolved}",
                file=sys.stderr,
            )
            return 1
        actual_bundle_id: object | None = None
        try:
            with open(os.path.join(app_resolved, "Contents", "Info.plist"), "rb") as info_file:
                actual_bundle_id = plistlib.load(info_file).get("CFBundleIdentifier")
        except OSError:
            actual_bundle_id = None
        if actual_bundle_id != args.expected_bundle_id:
            print(
                f"Refusing to remove Debug app with unexpected bundle identifier: "
                f"{actual_bundle_id!r} (expected {args.expected_bundle_id!r})",
                file=sys.stderr,
            )
            return 1
        targets.append(pathlib.Path(app_resolved))

    for store in (pathlib.Path(plugins_dir), pathlib.Path(quarantined)):
        if not store.is_dir():
            continue
        for entry in sorted(store.iterdir()):
            if entry.name.endswith(".mactoolsplugin"):
                targets.append(entry)

    # Preflight every target: it must stay strictly inside home and inside its
    # owning store root (so a symlinked package cannot redirect deletion).
    for target in targets:
        resolved = resolve(str(target))
        if unsafe(resolved):
            print(f"Refusing to remove unsafe path: {target} (resolves to {resolved})", file=sys.stderr)
            return 1
        if target.suffix != ".app":
            owner = target.parent
            if not resolved.startswith(resolve(str(owner)) + os.sep):
                print(
                    f"Refusing to remove path outside its store: {target} (resolves to {resolved})",
                    file=sys.stderr,
                )
                return 1

    # All validation passed; remove the collected targets.
    for target in targets:
        if not os.path.lexists(str(target)):
            continue
        if os.path.islink(str(target)) or os.path.isfile(str(target)):
            os.remove(str(target))
        else:
            shutil.rmtree(str(target))
        print(f"Removed {target}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
