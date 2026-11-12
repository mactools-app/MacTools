#!/usr/bin/env python3
"""Safely remove the locally installed Debug app and installed plugin packages.

This is the helper behind 'make clean-installed'. It is intentionally separate
from 'make clean', which stays local to the checkout.

Every path is realpath-normalized and must resolve strictly inside the user's
home directory. All roots and all candidate targets are validated before
anything is deleted, so a bad override (including a trailing-slash or dot/..
variant of the home directory, an ancestor such as '/Users', or a symlink that
redirects a store directory) aborts with nothing removed. Only the configured
Debug app (ending in '.app') and identifiable '.mactoolsplugin' packages inside
the plugin store and its sibling Quarantined directory are removed.
"""
from __future__ import annotations

import argparse
import os
import pathlib
import shutil
import sys


def resolve(path: str) -> str:
    """Canonicalize a path, resolving '.', '..', symlinks and trailing slashes."""
    return os.path.realpath(os.path.abspath(os.path.expanduser(path)))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, help="Installed Debug app bundle path")
    parser.add_argument("--plugins-dir", required=True, help="Installed plugin store directory")
    args = parser.parse_args()

    home = resolve("~")
    app = resolve(args.app)
    plugins_dir = resolve(args.plugins_dir)
    quarantined = resolve(os.path.join(os.path.dirname(args.plugins_dir), "Quarantined"))

    def unsafe(path: str) -> bool:
        return (not path) or path == os.sep or path == home or not path.startswith(home + os.sep)

    # Preflight every root before touching the disk.
    roots = (("Debug app", app), ("plugin store", plugins_dir), ("Quarantined store", quarantined))
    for label, path in roots:
        if unsafe(path):
            print(f"Refusing to remove unsafe {label} path: {path}", file=sys.stderr)
            return 1

    if not app.endswith(".app"):
        print(f"Refusing to remove non-app bundle path: {app}", file=sys.stderr)
        return 1

    # Collect only identifiable targets; never delete the store directories
    # themselves (only .mactoolsplugin packages inside them).
    targets: list[pathlib.Path] = [pathlib.Path(app)]
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
        owner = target.parent if target != pathlib.Path(app) else None
        if owner is not None and not resolved.startswith(resolve(str(owner)) + os.sep):
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
