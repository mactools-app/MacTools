#!/usr/bin/env python3
"""Validate localization contracts and inventory English fallback coverage.

Static lookup discovery covers host tables, PluginKit, Finder Sync, and plugin
wrappers. Computed keys and user-authored content still need manual review.
Translation gaps are reported separately from broken lookups. The repository
validation gate uses --require-complete to reject missing supported languages.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
from collections import Counter

ROOT = Path(__file__).resolve().parents[1]
LOCALES = frozenset("en zh-Hans zh-Hant es fr ru pt de ja ko ar tr".split())
TABLES = {
    "settings": "Settings", "plugins": "Plugins", "search": "Search",
    "preferencesBackup": "PreferencesBackup", "feature": "FeatureUI",
}
LITERAL = r'"((?:\\.|[^"\\])*)"'
FORMAT = re.compile(r'%(?:(\d+)\$)?[-+#0 ]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(hh|ll|[hljztqL])?([@diuoxXfFeEgGcsSpaA%])')


def literal(value: str) -> str:
    return json.loads('"' + value + '"')


def source_without_comments(source: str) -> str:
    # Preserve string literals and line numbers, including comment-like URLs.
    pattern = re.compile(r'"""[\s\S]*?"""|"(?:\\.|[^"\\])*"|//[^\n]*|/\*[\s\S]*?\*/')
    return pattern.sub(lambda m: m[0] if m[0].startswith('"') else re.sub(r'[^\n]', ' ', m[0]), source)


def string_units(value: dict):
    if "stringUnit" in value:
        yield value["stringUnit"]
    for children in value.get("variations", {}).values():
        for child in children.values():
            yield from string_units(child)
    for substitution in value.get("substitutions", {}).values():
        yield from string_units(substitution)


def format_signature(value: str) -> dict[int, str]:
    result = {}
    next_index = 1
    for match in FORMAT.finditer(value):
        if match[3] == "%":
            continue
        index = int(match[1]) if match[1] else next_index
        conversion = match[3]
        # Signedness does not change the ABI; widths and pointer types do.
        conversion = "d" if conversion in "diuoxX" else conversion
        result[index] = (match[2] or "") + conversion
        next_index = index + 1
    return result


def load_catalogs(root: Path) -> dict[str, dict]:
    catalogs = {}
    for directory in (root / "Sources", root / "Plugins"):
        for path in sorted(directory.rglob("*.xcstrings")):
            catalogs[str(path.relative_to(root))] = json.loads(path.read_text())["strings"]
        # System Soft Restart deliberately ships hand-authored .strings tables.
        for path in sorted(directory.rglob("*.lproj/*.strings")):
            table = str(path.parent.parent.relative_to(root) / (path.stem + ".xcstrings"))
            language = path.parent.stem
            entries = catalogs.setdefault(table, {})
            for match in re.finditer(LITERAL + r'\s*=\s*' + LITERAL + r'\s*;', path.read_text()):
                entries.setdefault(literal(match[1]), {}).setdefault("localizations", {})[language] = {
                    "stringUnit": {"state": "translated", "value": literal(match[2])}
                }
    return catalogs


def references(path: str, source: str):
    source = source_without_comments(source)
    parts = Path(path).parts
    plugin_catalog = str(Path(*parts[:2]) / "Resources/Localizable.xcstrings") if parts[0] == "Plugins" else None

    def matches(pattern: str, catalog: str, prefix: str = ""):
        for match in re.finditer(pattern, source):
            raw = match[match.lastindex]
            # A literal prefix of a computed expression is not a complete key.
            if "\\(" in raw or re.match(r'\s*\+', source[match.end():]):
                continue
            yield {"path": path, "line": source[:match.start()].count("\n") + 1,
                   "catalog": catalog, "key": prefix + literal(raw)}

    for method, table in TABLES.items():
        yield from matches(r'AppL10n\.' + method + r'(?:PluralFormat|Format)?\(\s*' + LITERAL,
                           f"Sources/Resources/Localization/{table}.xcstrings")
    yield from matches(r'FeatureL10n\.(?:string|format)\(\s*' + LITERAL,
                       "Sources/Resources/Localization/FeatureUI.xcstrings")
    yield from matches(r'RightClickLocalization\.(?:string|format)\(\s*' + LITERAL,
                       "Sources/Core/RightClick/RightClick.xcstrings")
    if path == "Sources/Extensions/RightClickFinderSync/RightClickFinderSync.swift":
        yield from matches(r'\blocalized\(\s*' + LITERAL,
                           "Sources/Core/RightClick/RightClick.xcstrings")
    if path == "Sources/App/MarketplacePluginDetailView.swift":
        yield from matches(r'detailSection\(\s*' + LITERAL, "Sources/Resources/Localization/Plugins.xcstrings")
    if path == "Sources/App/PanelLayoutEditingSession.swift":
        yield from matches(r'\btext\(\s*' + LITERAL, "Sources/Resources/Localization/Settings.xcstrings", "panel.layout.")
    if path == "Sources/App/CommandPaletteAliasSettings.swift":
        yield from matches(r'\blabel\(\s*' + LITERAL, "Sources/Resources/Localization/Settings.xcstrings", "actionInput.alias.")
    if path == "Sources/App/MarketplacePluginDetailCopy.swift":
        for match in re.finditer(LITERAL + r'\s*:\s*' + LITERAL, source):
            yield {"path": path, "line": source[:match.start()].count("\n") + 1,
                   "catalog": "Sources/Resources/Localization/Plugins.xcstrings",
                   "key": "plugin.marketplace.label." + literal(match[1])}
    if parts[:2] == ("Sources", "MacToolsPluginKit"):
        yield from matches(r'\bstring\(\s*' + LITERAL + r'(?=\s*,\s*defaultValue:)',
                           "Sources/MacToolsPluginKit/Resources/Localizable.xcstrings")
    if parts[:2] == ("Sources", "MacToolsAppIntents"):
        yield from matches(r'(?:String\(\s*localized:|LocalizedStringResource\s*=|IntentDescription\(|TypeDisplayRepresentation\(\s*name:|@Parameter\(title:|shortTitle:)\s*' + LITERAL,
                           "Sources/MacToolsAppIntents/Resources/Localizable.xcstrings")
    if plugin_catalog:
        yield from matches(r'(?:localization|l10n|\w+Localization)\.(?:string|format)\(\s*' + LITERAL,
                           plugin_catalog)
        if path != "Plugins/DiskClean/Sources/DiskCleanRuleModels.swift":
            yield from matches(r'\b(?:localized|localizedFormat|localizedKey)\(\s*' + LITERAL, plugin_catalog)
        if parts[1] == "DiskClean":
            for match in re.finditer(r'localizationKeyPrefix:\s*' + LITERAL, source):
                for field in ("whyMatched", "consequence", "regeneration"):
                    yield {"path": path, "line": source[:match.start()].count("\n") + 1,
                           "catalog": plugin_catalog, "key": literal(match[1]) + "." + field}
        if parts[1] in {"AIUsage", "Screenshot", "DisplayBrightness", "WindowSwitcher", "StorageExplorer"}:
            prefix = "storageExplorer." if parts[1] == "StorageExplorer" else ""
            yield from matches(r'\b(?:text|string|format)\(\s*' + LITERAL + r'(?=\s*,\s*")', plugin_catalog, prefix)
        if parts[1] == "MacSettings":
            yield from matches(r'MacSettingsStrings\.(?:text|format)\(\s*' + LITERAL,
                               "Plugins/MacSettings/Resources/MacSettings.xcstrings")
        if parts[1] == "Siri":
            yield from matches(r'\btext\(\s*' + LITERAL, plugin_catalog)


def vocabulary_references(root: Path):
    """Check computed Marketplace keys against the manifest's closed vocabularies."""
    path = root / "docs/plugins/plugin-manifest.schema.json"
    if not path.exists():
        return
    schema = json.loads(path.read_text())
    definitions = schema["$defs"]
    privacy = schema["properties"]["privacy"]["properties"]
    groups = {
        "risk": definitions["actionPolicy"]["properties"]["risk"]["enum"],
        "surface": definitions["surface"]["enum"],
        "permission": definitions["permission"]["enum"],
        "network": privacy["networkUse"]["enum"],
        "data.telemetry": privacy["telemetry"]["enum"],
        "retention": privacy["retention"]["properties"]["policy"]["enum"],
    }
    for group, values in groups.items():
        for value in values:
            yield {"path": str(path.relative_to(root)),
                   "catalog": "Sources/Resources/Localization/Plugins.xcstrings",
                   "key": f"plugin.marketplace.{group}.{value}"}


def audit(root: Path) -> dict:
    catalogs = load_catalogs(root)
    errors = []
    gaps = []
    all_references = []
    for directory in (root / "Sources", root / "Plugins"):
        for path in sorted(directory.rglob("*.swift")):
            if "Tests" in path.parts:
                continue
            for ref in references(str(path.relative_to(root)), path.read_text()):
                all_references.append(ref)
    all_references.extend(vocabulary_references(root))
    for ref in all_references:
        entry = catalogs.get(ref["catalog"], {}).get(ref["key"])
        if entry is None or not list(string_units(entry.get("localizations", {}).get("en", {}))):
            errors.append({"kind": "missing_english_resource", **ref})
    for path, entries in catalogs.items():
        for key, entry in entries.items():
            localizations = entry.get("localizations", {})
            missing = sorted(LOCALES - set(localizations))
            if missing:
                gaps.append({"catalog": path, "key": key, "languages": missing})
            for language, localization in localizations.items():
                units = list(string_units(localization))
                if not units or any(not unit.get("value") or unit.get("state") != "translated" for unit in units):
                    errors.append({"kind": "unfinished_translation", "catalog": path, "key": key, "language": language})
            # Only format resources are checked. Plain copy can contain literal
            # percentages such as "100% per core", which are not printf inputs.
            english = list(string_units(localizations.get("en", {})))
            if any(re.search(r'%(?:\d+\$)?(?:[-+#0 ]*\d*(?:\.\d+)?)(?:hh|ll|[hljztqL])?[@diuoxXfFeEgGcsS](?![a-zA-Z])', unit["value"]) for unit in english):
                other = localizations.get("en", {}).get("variations", {}).get("plural", {}).get("other", {})
                # Prefer the required catch-all form when branches have the
                # same number of arguments; a count-free form can have fewer.
                expected = max((format_signature(unit["value"]) for unit in [*string_units(other), *english]), key=len)
                for language, localization in localizations.items():
                    units = list(string_units(localization))
                    allowed = [expected]
                    if "plural" in localization.get("variations", {}) and expected.get(1) in {"d", "ld", "lld", "hd", "hhd", "jd", "zd", "td", "qd"}:
                        # Some plural forms express the count in words. Other
                        # arguments must retain their original positions/types.
                        allowed.append({index: kind for index, kind in expected.items() if index != 1})
                    for unit in units:
                        if format_signature(unit["value"]) not in allowed:
                            errors.append({"kind": "format_mismatch", "catalog": path, "key": key, "language": language})
    return {"catalog_count": len(catalogs), "key_count": sum(map(len, catalogs.values())),
            "reference_count": len(all_references), "errors": errors, "translation_gaps": gaps}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--json", action="store_true", help="Include every finding for review")
    parser.add_argument("--require-complete", action="store_true", help="Fail when a supported language is missing")
    args = parser.parse_args()
    result = audit(args.root)
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        print(f"Audited {result['catalog_count']} catalogs, {result['key_count']} keys, and {result['reference_count']} resource references.")
        for error in result["errors"]:
            print("ERROR: " + json.dumps(error, ensure_ascii=False))
        for path, count in sorted(Counter(gap["catalog"] for gap in result["translation_gaps"]).items()):
            print(f"English fallback: {path}: {count} partially translated keys")
    return bool(result["errors"] or (args.require_complete and result["translation_gaps"]))


if __name__ == "__main__":
    raise SystemExit(main())
