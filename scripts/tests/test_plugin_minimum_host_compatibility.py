#!/usr/bin/env python3
from __future__ import annotations

import json
import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
PLUGINS_ROOT = REPO_ROOT / "Plugins"
LEGACY_V4_CATALOG = REPO_ROOT / "docs/plugins/v4/catalog.json"
PLUGIN_RELEASE_WORKFLOW = REPO_ROOT / ".github/workflows/plugin-release.yml"
MAKEFILE = REPO_ROOT / "Makefile"
ACTION_MODELS = REPO_ROOT / "Sources/MacToolsPluginKit/ActionModels.swift"
COMPONENT_THEME_MODELS = REPO_ROOT / "Sources/MacToolsPluginKit/PluginComponentTheme.swift"
PLUGIN_PALETTE_COMPONENTS = REPO_ROOT / "Sources/MacToolsPluginKit/PluginPaletteComponents.swift"
PLUGIN_MODELS = REPO_ROOT / "Sources/MacToolsPluginKit/PluginModels.swift"
PLUGIN_INTERFACES = REPO_ROOT / "Sources/MacToolsPluginKit/PluginInterfaces.swift"
PLUGIN_SETTINGS_MODELS = REPO_ROOT / "Sources/MacToolsPluginKit/PluginSettingsModels.swift"
APP_VERSION_CONFIG = REPO_ROOT / "Configs/AppVersion.xcconfig"
NEW_API_MINIMUM_HOSTS = {
    "PluginTypography": "2.0.1",
    "PluginMetricValue": "2.0.1",
    "PluginPanelWidgetGrid": "1.3.1",
    "PluginPanelIconControl": "1.3.1",
    "iconWidget": "1.3.1",
    "PluginPanelItem": "1.3.1",
    "PluginPanelItemKind": "1.3.1",
    "PluginPanelInitialPlacement": "1.3.1",
    "PluginPanelContent": "1.3.1",
    "PluginPanelRow": "1.3.1",
    "PluginPanelWidget": "1.3.1",
    "PluginPanelRowDescriptor": "1.3.1",
    "PluginPanelRowState": "1.3.1",
    "PluginPanelRowIndicator": "1.3.1",
    "PluginPanelRowCompactIndicator": "1.3.1",
    "PluginPanelRowIndicatorIcon": "1.3.1",
    "PluginPanelWidgetDescriptor": "1.3.1",
    "PluginPanelWidgetState": "1.3.1",
    "PluginPanelWidgetContext": "1.3.1",
    "PluginPanelWidgetSpan": "1.3.1",
    "PluginPanelWidgetLayoutMetrics": "1.3.1",
    "PluginPanelDetailContent": "1.3.1",
    "PluginPanelPresentation": "1.3.1",
    "PluginPanelFocusRestoration": "1.3.1",
    "PluginPanelDismissalMonitor": "1.3.1",
    "PluginObservedContent": "1.3.1",
    "pluginPresentationIsVisible": "1.3.1",
    "PluginShortcutResetRequesting": "1.3.1",
    # Plugin-scoped, exclusive primary menu-bar icon placement.
    "PluginMenuBarIconPlacement": "1.3.1",
    "PluginMenuBarIconDescriptor": "1.3.1",
    "PluginMenuBarIconOwner": "1.3.1",
    "PluginMenuBarIconPlacementError": "1.3.1",
    "PluginMenuBarIconRenderContext": "1.3.1",
    "PluginMenuBarIconSnapshot": "1.3.1",
    "PluginMenuBarIconProviding": "1.3.1",
    "PluginMenuBarIconHostContext": "1.3.1",
    "PluginMenuBarIconHostContextConsuming": "1.3.1",
    "ActionInputDescriptor": "1.3.1",
    "ActionInputSession": "1.3.1",
    "PluginActionInputProviding": "1.3.1",
    "PluginActionInputPresentationRequesting": "1.3.1",

    # Centered guide APIs were added after the released 1.3.0 host.
    "WindowSnapGuideRole": "1.3.1",
    "WindowSnapGuideOrientation": "1.3.1",
    "WindowSnapGuide": "1.3.1",
    "WindowSnapResult": "1.3.1",
    "WindowSnapGeometry": "1.3.1",
    "WindowSnapOverlayController": "1.3.1",
    "PluginWindowSnapCoordinator": "1.3.1",

    # Canonical action registry, execution, discovery, and surface bridges.
    "ActionKey": "1.2.0",
    "ActionParameterSet": "1.2.0",
    "ActionParameterDefinition": "1.2.0",
    "ActionDefinition": "1.2.0",
    "ActionReference": "1.2.0",
    "ActionCatalogEntry": "1.2.0",
    "ActionAvailability": "1.2.0",
    "ActionRisk": "1.2.0",
    "ActionExternalInvocationPolicy": "1.2.0",
    "ActionExecutionCapabilities": "1.2.0",
    "ActionConfirmation": "1.2.0",
    "ActionInvocation": "1.2.0",
    "ActionExecutionResult": "1.2.0",
    "ActionExecutionHandle": "1.2.0",
    "ActionExecutionSource": "1.2.0",
    "ActionExposureSurface": "1.2.0",
    "ActionExposurePolicy": "1.2.0",
    "PluginActionProviding": "1.2.0",
    "PluginActionShortcutSettingsConfiguration": "1.2.0",
    "PluginActionShortcutSettingsProviding": "1.2.0",
    "PluginShortcutSettingsGroupConfiguration": "1.3.0",
    "PluginGroupedShortcutSettingsProviding": "1.3.0",
    "PluginShortcutSettingsGroupPresentationProviding": "1.3.0",
    "PluginRetiredActionShortcutProviding": "1.2.0",
    "PluginActionShortcutPresetPreviewItem": "1.2.0",
    "PluginActionShortcutPresetPreview": "1.2.0",
    "PluginActionShortcutPresetApplying": "1.2.0",
    "PluginActionShortcutReplacementTransactionApplying": "1.2.1",
    "PluginActionShortcutAssignmentChangeHandling": "1.2.0",
    "PluginActionExecutionRevisionProviding": "1.2.0",
    "PluginActionExposureProviding": "1.2.0",
    "PluginActionPermissionProviding": "1.2.0",
    "LegacyActionShortcutAssignment": "1.2.0",
    "PluginLegacyActionShortcutProviding": "1.2.0",
    "ActionSurfaceCatalogItem": "1.2.0",
    "ActionGridPresentationEntry": "1.2.0",
    "ActionGridHostContext": "1.2.0",
    "ActionGridHostContextConsuming": "1.2.0",
    "TrackpadActionHostContext": "1.2.0",
    "TrackpadActionHostContextConsuming": "1.2.0",
    "PluginActionHostExecutionResult": "1.2.1",
    "PluginActionExecutionHostContext": "1.2.1",
    "PluginActionExecutionHostContextConsuming": "1.2.1",
    "ActionSurfaceAssignmentSummary": "1.2.0",
    "ActionSurfaceAssignmentSummarizing": "1.2.0",
    # Portable preferences and input ownership added with the shared surfaces.
    "PluginPortablePreferencesRestorationReporting": "1.2.0",
    "PluginPortablePreferencesActionReferencesProviding": "1.2.0",
    "PluginActionReferenceBackupDisposition": "1.2.0",
    "PluginActionReferenceBackupProviding": "1.2.0",
    "PluginInputGestureClaim": "1.2.0",
    "PluginInputGestureConflict": "1.2.0",
    "PluginInputGestureClaimProviding": "1.2.0",
    "PluginInputGestureConflictConsuming": "1.2.0",
    # Shared lifecycle and presentation helpers introduced in host 1.2.
    "PluginCallbackContext": "1.2.0",
    "PluginPresentationSafety": "1.2.0",
    "PluginDashboardPresenting": "1.2.1",
    "PluginProcessGroupLease": "1.2.0",
    "PluginSystemImage": "1.2.0",
    # Contextual plugin-settings search contracts introduced in host 1.2.1.
    "PluginSettingsSearchFocusing": "1.2.1",
    "PluginSettingsSearchFocusMetadataProviding": "1.2.1",
    "PluginSettingsSearchTarget": "1.2.1",
    # Side-aware atomic keyboard output introduced in host 1.2.1.
    "KeyboardKeyTap": "1.2.1",
    "KeyboardKeyTapFormatter": "1.2.1",
    "MacToolsSyntheticInputEvent": "1.2.1",
    "KeyboardKeyTapEventTransition": "1.2.1",
    "KeyboardKeyTapEventPoster": "1.2.1",
    "PluginKeyTapPicker": "1.2.1",
    # New accessors on the pre-existing PluginKitLocalization type.
    "keyboardKeyLeft": "1.2.1",
    "keyboardKeyRight": "1.2.1",
    "keyboardKeyTapPickerHelp": "1.2.1",
    "keyboardKeyTapUnset": "1.2.1",
    "keyboardKeyTapUnsupportedHelp": "1.2.1",
    "keyboardKeyGroupModifiers": "1.2.1",
    "keyboardKeyGroupNavigation": "1.2.1",
    "keyboardKeyGroupKeypad": "1.2.1",
    "keyboardKeyGroupOther": "1.2.1",
    # Shared component-panel theme surfaces introduced in host 1.2.
    "PluginComponentTheme": "1.2.0",
    "PluginComponentCardBackground": "1.2.0",
    "PluginActionSafetyStateChangeProviding": "1.2.0",
    # Shared palette, shortcut-recorder, and private-data APIs introduced after v1.2.0.
    "PluginPaletteMetrics": "1.3.0",
    "PluginPaletteColors": "1.3.1",
    "PluginPaletteChrome": "1.3.1",
    "PluginPaletteSearchChrome": "1.3.1",
    "PluginPaletteSearchCommand": "1.3.0",
    "PluginPaletteSearchField": "1.3.0",
    "PluginPaletteSearchBar": "1.3.0",
    "PluginPaletteSearchToolbar": "1.3.0",
    "PluginPaletteSurface": "1.3.0",
    "PluginFloatingPanelAppearance": "2.0.1",
    "PluginFloatingPanelShape": "2.0.1",
    "PluginFloatingPanelSurface": "2.0.1",
    "PluginPaletteSelectableRowModifier": "1.3.0",
    "pluginPaletteSelectableRow": "1.3.0",
    "PluginPaletteToolbarControlStyle": "1.3.0",
    "PluginPaletteKeyboardHint": "1.3.0",
    "PluginPaletteFooter": "1.3.0",
    "PluginPrivateDataKeychainIdentity": "1.3.0",
    "PluginSettingsActionShortcutItem": "1.3.0",
    "PluginSettingsItem": "1.3.1",
    "PluginInlineShortcutSettingsContextConsuming": "1.3.0",
    "PluginShortcutBindingValidating": "1.3.0",
    "actionShortcutItem": "1.3.0",
    "actionShortcutItems": "1.3.0",
    "recordActionShortcut": "1.3.0",
    "clearActionShortcut": "1.3.0",
    "PluginSettingsShortcutRecorderControl": "1.3.0",
    "PluginShortcutRecordingAnchor": "1.3.0",
    "PluginWindowLayoutTargetProviding": "1.3.0",
    # Finder-extension permission presentation introduced after host 1.2.0.
    ".finderExtension": "1.2.1",
}


def source_uses_symbol(source: str, symbol: str) -> bool:
    return re.search(rf"(?<![A-Za-z0-9_]){re.escape(symbol)}(?![A-Za-z0-9_])", source) is not None


def public_top_level_type_names(source: str) -> set[str]:
    return set(re.findall(
        r"^public\s+(?:final\s+)?(?:struct|enum|protocol|class|actor|typealias)\s+"
        r"([A-Za-z_][A-Za-z0-9_]*)",
        source,
        flags=re.MULTILINE,
    ))


def public_extension_function_names(source: str, extended_type: str) -> set[str]:
    names: set[str] = set()
    depth = 0
    inside_extension = False
    extension_pattern = re.compile(
        rf"^public\s+extension\s+{re.escape(extended_type)}\s*\{{"
    )
    for line in source.splitlines():
        if not inside_extension:
            if extension_pattern.search(line):
                inside_extension = True
                depth = line.count("{") - line.count("}")
            continue
        if depth == 1:
            match = re.match(r"^\s*func\s+([A-Za-z_][A-Za-z0-9_]*)", line)
            if match is not None:
                names.add(match.group(1))
        depth += line.count("{") - line.count("}")
        if depth == 0:
            inside_extension = False
    return names


def minimum_host_violations(plugin_id: str, declared: str, source: str) -> list[str]:
    return [
        f"{plugin_id} uses {symbol} but declares "
        f"minHostVersion {declared} (< {required})"
        for symbol, required in NEW_API_MINIMUM_HOSTS.items()
        if source_uses_symbol(source, symbol)
        and version_tuple(declared) < version_tuple(required)
    ]


def version_tuple(value: str) -> tuple[int, ...]:
    return tuple(int(component) for component in value.split("."))


def declared_app_version() -> str:
    match = re.search(
        r"(?m)^\s*MARKETING_VERSION\s*=\s*([^\s#]+)",
        APP_VERSION_CONFIG.read_text(encoding="utf-8"),
    )
    if match is None:
        raise AssertionError("MARKETING_VERSION is missing")
    return match.group(1)


class PluginMinimumHostCompatibilityTests(unittest.TestCase):
    def test_legacy_v4_catalog_remains_compatible_with_shipped_1_1_6_verifier(self) -> None:
        catalog = json.loads(LEGACY_V4_CATALOG.read_text(encoding="utf-8"))
        self.assertEqual(catalog["minimumHostVersion"], "1.1.6")
        incompatible = [
            entry["id"]
            for entry in catalog["plugins"]
            if version_tuple(entry["minimumHostVersion"]) > version_tuple("1.1.6")
        ]
        self.assertEqual(incompatible, [])

    def test_plugin_kit5_schema3_release_targets_a_new_compatibility_catalog(self) -> None:
        workflow = PLUGIN_RELEASE_WORKFLOW.read_text(encoding="utf-8")
        makefile = MAKEFILE.read_text(encoding="utf-8")
        self.assertIn(
            'PLUGIN_CATALOG_RELATIVE_PATH="docs/plugins/v5/schema3/catalog.json"',
            workflow,
        )
        self.assertIn('PLUGIN_CATALOG_MINIMUM_HOST_VERSION="1.2.1"', workflow)
        self.assertIn(
            "PLUGIN_CATALOG_MINIMUM_HOST_VERSION ?= 1.2.1",
            makefile,
        )
        released_catalog = json.loads(
            (REPO_ROOT / "docs/plugins/v5/catalog.json").read_text(encoding="utf-8")
        )
        self.assertEqual(released_catalog["schemaVersion"], 2)

    def test_schema3_release_floor_applies_to_future_plugin_kit_versions(self) -> None:
        workflow = PLUGIN_RELEASE_WORKFLOW.read_text(encoding="utf-8")
        makefile = MAKEFILE.read_text(encoding="utf-8")
        self.assertIn(
            'PLUGIN_CATALOG_RELATIVE_PATH="docs/plugins/v${PLUGIN_KIT_VERSION}/catalog.json"',
            workflow,
        )
        self.assertGreaterEqual(workflow.count('PLUGIN_CATALOG_MINIMUM_HOST_VERSION="1.2.1"'), 2)
        self.assertIn("PluginKit versions below 5 use immutable legacy catalogs", workflow)
        self.assertIn("if (( PLUGIN_KIT_VERSION < 5 )); then", workflow)
        self.assertIn('case " 1 2 3 4 " in', makefile)

    def test_every_current_plugin_targets_plugin_kit7_and_host_1_3_1(self) -> None:
        compatibility = (REPO_ROOT / "Sources/MacToolsPluginKit/PluginKitCompatibility.swift").read_text()
        self.assertIn("currentVersion = 7", compatibility)
        incompatible = []
        for manifest_path in sorted(PLUGINS_ROOT.glob("*/plugin.json")):
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            if (
                manifest["pluginKitVersion"] != 7
                or version_tuple(manifest["minHostVersion"]) < version_tuple("1.3.1")
                or version_tuple(manifest["minHostVersion"])
                > version_tuple(declared_app_version())
            ):
                incompatible.append(manifest["id"])
        self.assertEqual(incompatible, [])

    def test_every_new_plugin_kit_api_is_exported_by_the_declared_app_version(self) -> None:
        app_version = declared_app_version()
        newer_symbols = {
            symbol: required
            for symbol, required in NEW_API_MINIMUM_HOSTS.items()
            if version_tuple(required) > version_tuple(app_version)
        }
        self.assertEqual(newer_symbols, {})

    def test_new_plugin_kit_api_consumers_require_compatible_host(self) -> None:
        violations: list[str] = []
        for manifest_path in sorted(PLUGINS_ROOT.glob("*/plugin.json")):
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            source = "\n".join(
                path.read_text(encoding="utf-8")
                for path in sorted((manifest_path.parent / "Sources").rglob("*.swift"))
            )
            declared = manifest.get("minHostVersion", "0")
            violations += minimum_host_violations(manifest["id"], declared, source)

        self.assertEqual(violations, [], "\n".join(violations))

    def test_plugin_permission_kind_preserves_released_case_order(self) -> None:
        source = PLUGIN_MODELS.read_text(encoding="utf-8")
        match = re.search(
            r"public enum PluginPermissionKind\s*\{(?P<body>.*?)\n\}",
            source,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(match)
        cases = re.findall(r"^\s*case\s+(\w+)", match.group("body"), flags=re.MULTILINE)
        self.assertEqual(
            cases[:6],
            [
                "accessibility",
                "inputMonitoring",
                "calendarFullAccess",
                "automation",
                "screenRecording",
                "finderExtension",
            ],
        )

    def test_action_model_inventory_covers_every_public_type_used_by_plugins(self) -> None:
        action_model_symbols = public_top_level_type_names(
            ACTION_MODELS.read_text(encoding="utf-8")
            + "\n" + ACTION_MODELS.with_name("ActionInputModels.swift").read_text(encoding="utf-8")
        )
        plugin_source = "\n".join(
            path.read_text(encoding="utf-8")
            for path in sorted(PLUGINS_ROOT.glob("*/Sources/**/*.swift"))
        )
        used_symbols = {
            symbol
            for symbol in action_model_symbols
            if source_uses_symbol(plugin_source, symbol)
        }
        self.assertEqual(
            used_symbols - NEW_API_MINIMUM_HOSTS.keys(),
            set(),
            "Public ActionModels types used by plugins must declare their minimum host",
        )

    def test_menu_bar_icon_inventory_covers_new_public_types(self) -> None:
        source = PLUGIN_INTERFACES.with_name("PluginMenuBarIcon.swift").read_text(encoding="utf-8")
        symbols = public_top_level_type_names(source)
        self.assertEqual(symbols - NEW_API_MINIMUM_HOSTS.keys(), set())
        for symbol in symbols:
            with self.subTest(symbol=symbol):
                self.assertTrue(minimum_host_violations("probe", "1.3.0", symbol))
                self.assertEqual(minimum_host_violations("probe", "1.3.1", symbol), [])

    def test_action_input_apis_reject_released_host_1_3_0(self) -> None:
        source = ACTION_MODELS.with_name("ActionInputModels.swift").read_text(encoding="utf-8")
        symbols = {
            "ActionInputDescriptor",
            "ActionInputSession",
            "PluginActionInputProviding",
            "PluginActionInputPresentationRequesting",
        }
        self.assertTrue(symbols <= public_top_level_type_names(source))
        for symbol in symbols:
            with self.subTest(symbol=symbol):
                self.assertEqual(NEW_API_MINIMUM_HOSTS[symbol], "1.3.1")
                self.assertEqual(len(minimum_host_violations("probe", "1.3.0", symbol)), 1)
                self.assertEqual(minimum_host_violations("probe", "1.3.1", symbol), [])

    def test_action_execution_bridge_inventory_requires_the_first_compatible_host(self) -> None:
        bridge = REPO_ROOT / "Sources/MacToolsPluginKit/PluginActionExecutionHostContext.swift"
        symbols = public_top_level_type_names(bridge.read_text(encoding="utf-8"))
        self.assertTrue(symbols)
        for symbol in symbols:
            with self.subTest(symbol=symbol):
                self.assertEqual(NEW_API_MINIMUM_HOSTS.get(symbol), "1.2.1")
                self.assertTrue(minimum_host_violations("legacy", "1.2.0", symbol))

    def test_dashboard_presentation_apis_reject_host_1_2_0(self) -> None:
        symbols = {
            "PluginDashboardPresenting",
        }
        interfaces = (REPO_ROOT / "Sources/MacToolsPluginKit/PluginInterfaces.swift").read_text(
            encoding="utf-8"
        )
        self.assertTrue(symbols <= public_top_level_type_names(interfaces))
        for symbol in symbols:
            self.assertEqual(NEW_API_MINIMUM_HOSTS[symbol], "1.2.1")
            self.assertEqual(len(minimum_host_violations("probe", "1.2.0", symbol)), 1)
            self.assertEqual(minimum_host_violations("probe", "1.2.1", symbol), [])

    def test_global_panel_inventory_requires_host_1_3_1(self) -> None:
        source = (REPO_ROOT / "Sources/MacToolsPluginKit/PluginPanelPresentation.swift").read_text(encoding="utf-8")
        for symbol in public_top_level_type_names(source):
            with self.subTest(symbol=symbol):
                self.assertEqual(NEW_API_MINIMUM_HOSTS.get(symbol), "1.3.1")
                self.assertTrue(minimum_host_violations("probe", "1.3.0", symbol))
                self.assertEqual(minimum_host_violations("probe", "1.3.1", symbol), [])

    def test_icon_widget_inventory_requires_host_1_3_1(self) -> None:
        for symbol in ("PluginPanelIconControl", "iconWidget"):
            self.assertEqual(NEW_API_MINIMUM_HOSTS[symbol], "1.3.1")
            self.assertTrue(minimum_host_violations("probe", "1.3.0", symbol))
            self.assertEqual(minimum_host_violations("probe", "1.3.1", symbol), [])

    def test_centered_window_snap_inventory_requires_host_1_3_1(self) -> None:
        for filename in ("WindowSnapGeometry.swift", "WindowSnapOverlayController.swift", "PluginWindowSnapCoordinator.swift"):
            source = (REPO_ROOT / "Sources/MacToolsPluginKit" / filename).read_text(encoding="utf-8")
            for symbol in public_top_level_type_names(source):
                self.assertEqual(NEW_API_MINIMUM_HOSTS[symbol], "1.3.1")
                self.assertTrue(minimum_host_violations("probe", "1.3.0", symbol))
                self.assertEqual(minimum_host_violations("probe", "1.3.1", symbol), [])

    def test_component_theme_inventory_covers_every_public_type_used_by_plugins(self) -> None:
        component_theme_symbols = public_top_level_type_names(
            COMPONENT_THEME_MODELS.read_text(encoding="utf-8")
            + "\n" + COMPONENT_THEME_MODELS.with_name("PluginTypography.swift").read_text(encoding="utf-8")
            + "\n" + COMPONENT_THEME_MODELS.with_name("PluginMetricValue.swift").read_text(encoding="utf-8")
        )
        plugin_source = "\n".join(
            path.read_text(encoding="utf-8")
            for path in sorted(PLUGINS_ROOT.glob("*/Sources/**/*.swift"))
        )
        used_symbols = {
            symbol
            for symbol in component_theme_symbols
            if source_uses_symbol(plugin_source, symbol)
        }
        self.assertEqual(
            used_symbols - NEW_API_MINIMUM_HOSTS.keys(),
            set(),
            "Public component-theme types used by plugins must declare their minimum host",
        )

    def test_palette_inventory_covers_every_public_api_used_by_plugins(self) -> None:
        source = PLUGIN_PALETTE_COMPONENTS.read_text(encoding="utf-8")
        palette_symbols = public_top_level_type_names(source)
        palette_symbols |= public_extension_function_names(source, "View")
        plugin_source = "\n".join(
            path.read_text(encoding="utf-8")
            for path in sorted(PLUGINS_ROOT.glob("*/Sources/**/*.swift"))
        )
        used_symbols = {
            symbol
            for symbol in palette_symbols
            if source_uses_symbol(plugin_source, symbol)
        }
        self.assertEqual(
            used_symbols - NEW_API_MINIMUM_HOSTS.keys(),
            set(),
            "Public palette APIs used by plugins must declare their minimum host",
        )

    def test_clipboard_shortcut_extension_apis_require_host_1_3(self) -> None:
        interfaces = PLUGIN_INTERFACES.read_text(encoding="utf-8")
        settings_models = PLUGIN_SETTINGS_MODELS.read_text(encoding="utf-8")
        symbols_by_source = {
            "PluginShortcutBindingValidating": interfaces,
            "actionShortcutItem": settings_models,
            "actionShortcutItems": settings_models,
            "recordActionShortcut": settings_models,
            "clearActionShortcut": settings_models,
        }
        for symbol, source in symbols_by_source.items():
            with self.subTest(symbol=symbol):
                self.assertTrue(source_uses_symbol(source, symbol))
                self.assertEqual(NEW_API_MINIMUM_HOSTS.get(symbol), "1.3.0")
                self.assertTrue(minimum_host_violations("legacy", "1.2.1", symbol))
    def test_symbol_matching_rejects_legacy_consumer_without_substring_false_positive(self) -> None:
        self.assertTrue(source_uses_symbol("let risk: ActionRisk = .safe", "ActionRisk"))
        self.assertFalse(source_uses_symbol("struct MyActionRiskWrapper {}", "ActionRisk"))
        self.assertEqual(
            minimum_host_violations(
                "synthetic-legacy-plugin",
                "1.1.6",
                "let risk: ActionRisk = .safe",
            ),
            [
                "synthetic-legacy-plugin uses ActionRisk but declares "
                "minHostVersion 1.1.6 (< 1.2.0)"
            ],
        )
        self.assertEqual(
            minimum_host_violations(
                "synthetic-legacy-plugin",
                "1.2.0",
                "final class Plugin: PluginInlineShortcutSettingsContextConsuming {}\n"
                "let anchor = PluginShortcutRecordingAnchor()",
            ),
            [
                "synthetic-legacy-plugin uses "
                "PluginInlineShortcutSettingsContextConsuming but declares "
                "minHostVersion 1.2.0 (< 1.3.0)",
                "synthetic-legacy-plugin uses PluginShortcutRecordingAnchor but declares "
                "minHostVersion 1.2.0 (< 1.3.0)",
            ],
        )


if __name__ == "__main__":
    unittest.main()
