from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import subprocess
import sys

SPEC = importlib.util.spec_from_file_location("localization_audit", Path(__file__).parents[1] / "audit-localization.py")
audit_module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(audit_module)


class LocalizationAuditTests(unittest.TestCase):
    def test_missing_lookup_fails_but_english_fallback_is_reported(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            resources = root / "Sources/Resources/Localization"
            resources.mkdir(parents=True)
            (root / "Sources/App.swift").write_text(
                'AppL10n.plugins("present", defaultValue: "fallback")\n'
                'AppL10n.plugins("missing", defaultValue: "fallback")\n'
                '// AppL10n.plugins("comment", defaultValue: "fallback")\n'
            )
            (resources / "Plugins.xcstrings").write_text(json.dumps({"strings": {
                "present": {"localizations": {"en": {"stringUnit": {"state": "translated", "value": "value"}}}}
            }}))
            result = audit_module.audit(root)
            self.assertEqual([error["key"] for error in result["errors"]], ["missing"])
            self.assertEqual(result["translation_gaps"][0]["languages"], sorted(audit_module.LOCALES - {"en"}))
            # Complete-catalog validation makes a new fallback gap a build failure.
            (root / "Sources/App.swift").write_text('AppL10n.plugins("present", defaultValue: "fallback")')
            command = [sys.executable, str(SPEC.origin), "--root", str(root)]
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 0)
            self.assertNotEqual(subprocess.run(command + ["--require-complete"], capture_output=True).returncode, 0)

    def test_lookup_tables_wrappers_and_computed_prefixes(self):
        refs = list(audit_module.references("Sources/App/MarketplacePluginDetailView.swift", '''
            AppL10n.settingsFormat("host", defaultValue: "%@", name)
            detailSection("detail", defaultValue: "fallback", systemImage: "info.circle")
            FeatureL10n.string("source key")
            AppL10n.plugins("prefix." + identifier, defaultValue: "fallback")
        '''))
        self.assertEqual([ref["key"] for ref in refs], ["host", "source key", "detail"])
        self.assertEqual({ref["catalog"] for ref in refs}, {
            "Sources/Resources/Localization/Settings.xcstrings",
            "Sources/Resources/Localization/Plugins.xcstrings",
            "Sources/Resources/Localization/FeatureUI.xcstrings",
        })
        plugin = list(audit_module.references("Plugins/Sample/Sources/View.swift", 'localization.string("key", defaultValue: "value")'))
        self.assertEqual(plugin[0]["catalog"], "Plugins/Sample/Resources/Localizable.xcstrings")

    def test_positional_format_reordering_preserves_argument_types(self):
        signature = audit_module.format_signature
        self.assertEqual(signature("%@ %lld %%"), signature("%2$lld %1$@ %%"))
        self.assertNotEqual(signature("%@ %lld"), signature("%@ %d"))
        self.assertNotEqual(signature("%@ %d"), signature("%@ %@"))

    def test_format_type_mismatch_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            resources = root / "Plugins/Sample/Resources"
            resources.mkdir(parents=True)
            (resources / "Localizable.xcstrings").write_text(json.dumps({"strings": {
                "format": {"localizations": {
                    "en": {"stringUnit": {"state": "translated", "value": "%@ %lld"}},
                    "fr": {"stringUnit": {"state": "translated", "value": "%@ %d"}},
                }}
            }}))
            errors = audit_module.audit(root)["errors"]
            self.assertEqual([error["kind"] for error in errors], ["format_mismatch"])
            self.assertEqual(errors[0]["language"], "fr")

    def test_legacy_strings_resources_participate_in_audit(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            resources = root / "Plugins/Sample/Resources/en.lproj"
            resources.mkdir(parents=True)
            (resources / "Localizable.strings").write_text('"key" = "value";')
            sources = root / "Plugins/Sample/Sources"
            sources.mkdir()
            (sources / "Plugin.swift").write_text('localization.string("key", defaultValue: "fallback")')
            result = audit_module.audit(root)
            self.assertEqual(result["errors"], [])
            self.assertEqual(result["catalog_count"], 1)

    def test_finder_wrapper_missing_resource_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sources = root / "Sources/Extensions/RightClickFinderSync"
            sources.mkdir(parents=True)
            source = '''
                localized("finder.copyFileName", defaultValue: "Copy File Name", configuration: configuration)
                localized("finder." + identifier, defaultValue: "Fallback", configuration: configuration)
                // localized("finder.comment", defaultValue: "Comment", configuration: configuration)
            '''
            (sources / "RightClickFinderSync.swift").write_text(source)
            result = audit_module.audit(root)
            self.assertEqual(result["reference_count"], 1)
            self.assertEqual([(error["kind"], error["key"], error["catalog"]) for error in result["errors"]], [
                ("missing_english_resource", "finder.copyFileName", "Sources/Core/RightClick/RightClick.xcstrings")
            ])
            self.assertEqual(list(audit_module.references("Sources/App/Other.swift", source)), [])

    def test_plural_formats_preserve_types_and_non_count_arguments(self):
        def plural(**forms):
            return {"variations": {"plural": {
                name: {"stringUnit": {"state": "translated", "value": value}}
                for name, value in forms.items()
            }}}

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            resources = root / "Sources/Resources/Localization"
            resources.mkdir(parents=True)
            path = resources / "PreferencesBackup.xcstrings"
            localizations = {
                "en": plural(one="%d snapshot · %@", other="%d snapshots · %@"),
                "ar": plural(zero="%2$@", one="%2$@ · %1$d", two="%d snapshots · %@", other="%d snapshots · %@"),
            }

            def errors():
                path.write_text(json.dumps({"strings": {"history": {"localizations": localizations}}}))
                return audit_module.audit(root)["errors"]

            self.assertEqual(errors(), [])
            for invalid in ("%@ snapshots · %@", "%lld snapshots · %@", "%d snapshots", "%@"):
                with self.subTest(translation=invalid):
                    localizations["ar"] = plural(other=invalid)
                    result = errors()
                    self.assertEqual([(error["kind"], error["language"]) for error in result], [
                        ("format_mismatch", "ar")
                    ])
            # An invalid source branch must fail too, even if another branch is correct.
            localizations["ar"] = plural(other="%d snapshots · %@")
            localizations["en"] = plural(one="%@ snapshot · %@", other="%d snapshots · %@")
            self.assertEqual([(error["kind"], error["language"]) for error in errors()], [
                ("format_mismatch", "en")
            ])


if __name__ == "__main__":
    unittest.main()
