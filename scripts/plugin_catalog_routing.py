#!/usr/bin/env python3
"""Routes newly built PluginKit catalogs without replacing an older host's endpoint."""

from __future__ import annotations

import argparse
from pathlib import Path
import re

V7_HOST_FLOOR = "2.2.5"


def v7_host_specific_catalog(kit: int, host_version: str) -> bool:
    if kit != 7:
        return False
    base_version = host_version.partition("-")[0]
    if re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", base_version) is None:
        raise ValueError(f"Invalid host version: {host_version}")
    version = tuple(int(part) for part in base_version.split("."))
    return version >= (2, 2, 5)


def catalog_path(kit: int, host_version: str, *, nightly: bool = False) -> str:
    base = "docs/nightly/plugins" if nightly else "docs/plugins"
    if v7_host_specific_catalog(kit, host_version):
        return f"{base}/v7/host-{V7_HOST_FLOOR}/catalog.json"
    if not nightly and kit == 2:
        return f"{base}/catalog.json"
    if not nightly and kit == 5:
        return f"{base}/v5/schema3/catalog.json"
    return f"{base}/v{kit}/catalog.json"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kit", required=True, type=int)
    parser.add_argument("--minimum-host", action="store_true")
    parser.add_argument("--nightly", action="store_true")
    args = parser.parse_args()
    config = Path(__file__).resolve().parents[1] / "Configs/AppVersion.xcconfig"
    version = re.search(r"(?m)^MARKETING_VERSION[ \t]*=[ \t]*([^\s#]+)", config.read_text())
    if version is None:
        parser.error("MARKETING_VERSION is missing from AppVersion.xcconfig")
    host_version = version.group(1)
    if args.minimum_host:
        print(V7_HOST_FLOOR if v7_host_specific_catalog(args.kit, host_version) else "1.2.1")
    else:
        print(catalog_path(args.kit, host_version, nightly=args.nightly))


if __name__ == "__main__":
    main()
