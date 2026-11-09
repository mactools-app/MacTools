import Foundation
import XCTest
@testable import MacTools
import MacToolsPluginKit
import ActionGridPlugin
import ActivityBarPlugin
import AIAssistantPlugin
import AppHotkeyPlugin
import AppVolumePlugin
import AppearancePlugin
import AppleShortcutsPlugin
import AutoHideDockPlugin
import AutoHideMenuBarPlugin
import AutoInputPlugin
import BatteryChargeLimitPlugin
import ClipboardClearPlugin
import ClipboardHistoryPlugin
import CloudflareR2Plugin
import DiskCleanPlugin
import DisplayBrightnessPlugin
import DisplayResolutionPlugin
import DisplaySleepPlugin
import DisplayTrueColorPlugin
import DisplayVolumePlugin
import DockLockPlugin
import EjectDiskPlugin
import EmptyTrashPlugin
import FanControlPlugin
import FixDamagedAppPlugin
import HideNotchPlugin
import HomebrewPlugin
import IPOverviewPlugin
import KeepAwakePlugin
import LaunchControlPlugin
import LaunchpadPlugin
import LockScreenPlugin
import MacSettingsPlugin
import MenuBarHiddenPlugin
import MicrophoneMutePlugin
import MiddleClickPlugin
import NightShiftPlugin
import PhysicalCleanModePlugin
import QuitAppsPlugin
import SavedScriptsPlugin
import ScreenshotPlugin
import SiriPlugin
import SidecarPlugin
import StageManagerPlugin
import SystemMutePlugin
import SystemPowerPlugin
import SystemSoftRestartPlugin
import TranslatorPlugin
import WindowLayoutsPlugin
import WindowSwitcherPlugin
import XcodeCleanPlugin

@MainActor
final class PluginRuntimeActionSnapshotTests: XCTestCase {
    func testEveryRuntimeActionProviderMatchesManifestDescriptors() throws {
        for registration in Self.registrations {
            let context = PluginRuntimeContext(
                pluginID: registration.pluginID,
                storage: SnapshotPluginStorage()
            )
            let provider = try registration.makeProvider(context)
            let plugins = provider.makePlugins()
            XCTAssertEqual(plugins.count, 1, registration.pluginID)
            let definitions = plugins
                .compactMap { $0 as? any PluginActionProviding }
                .flatMap(\.actionDefinitions)
            try assertManifestConsistency(
                pluginID: registration.pluginID,
                plugin: try XCTUnwrap(plugins.first),
                definitions: definitions
            )
        }
    }

    private func assertManifestConsistency(
        pluginID: String,
        plugin: any MacToolsPlugin,
        definitions: [ActionDefinition]
    ) throws {
        let manifest = try sourceManifest(pluginID: pluginID)
        let actions = try XCTUnwrap(manifest["actions"] as? [String: Any], pluginID)
        let providers = try XCTUnwrap(actions["providers"] as? [[String: Any]], pluginID)
        let provider = try XCTUnwrap(
            providers.first { $0["id"] as? String == pluginID },
            pluginID
        )
        let staticActions = provider["staticActions"] as? [[String: Any]] ?? []
        let dynamicTemplates = provider["dynamicTemplates"] as? [[String: Any]] ?? []
        let expectedKind: String
        if staticActions.isEmpty {
            expectedKind = "dynamic"
        } else if dynamicTemplates.isEmpty {
            expectedKind = "static"
        } else {
            expectedKind = "mixed"
        }
        XCTAssertEqual(provider["kind"] as? String, expectedKind, pluginID)

        let runtimeByID = Dictionary(
            uniqueKeysWithValues: definitions.map { ($0.key.actionID, $0) }
        )
        XCTAssertEqual(
            Set(staticActions.compactMap { $0["id"] as? String }),
            Set(runtimeByID.keys.filter { actionID in
                dynamicTemplateID(pluginID: pluginID, actionID: actionID) == nil
            }),
            pluginID
        )

        for definition in definitions {
            let actionID = definition.key.actionID
            let descriptor: [String: Any]
            let isStatic: Bool
            if let value = staticActions.first(where: { $0["id"] as? String == actionID }) {
                descriptor = value
                isStatic = true
            } else {
                let templateID = try XCTUnwrap(
                    dynamicTemplateID(pluginID: pluginID, actionID: actionID),
                    "Missing dynamic classification for \(pluginID)/\(actionID)"
                )
                descriptor = try XCTUnwrap(
                    dynamicTemplates.first { $0["id"] as? String == templateID },
                    "Missing dynamic template for \(pluginID)/\(actionID)"
                )
                isStatic = false
            }
            let riskVariesByEntry = descriptor["riskVariesByEntry"] as? Bool == true
            let automaticEligibilityVariesByEntry =
                descriptor["automaticEligibilityVariesByEntry"] as? Bool == true
            if !riskVariesByEntry {
                XCTAssertEqual(descriptor["risk"] as? String, definition.risk.rawValue, definition.key.id)
            }
            if descriptor["externalInvocation"] as? String == "configurable" {
                XCTAssertTrue(
                    definition.externalInvocationPolicy == .allowed
                        || definition.externalInvocationPolicy == .confirmAlways
                        || definition.externalInvocationPolicy == .unavailable,
                    definition.key.id
                )
            } else {
                XCTAssertEqual(
                    descriptor["externalInvocation"] as? String,
                    definition.externalInvocationPolicy.rawValue,
                    definition.key.id
                )
            }
            if !automaticEligibilityVariesByEntry {
                XCTAssertEqual(
                    descriptor["automaticEligible"] as? Bool,
                    definition.capabilities.contains(.automatic),
                    definition.key.id
                )
            }
            let surfaces = Set(descriptor["surfaces"] as? [String] ?? [])
            let supportsUnattendedExecution = definition.risk == .safe
                && definition.capabilities.contains(.automatic)
                && definition.capabilities.contains(.background)
            let canBeSafe = descriptor["risk"] as? String == "safe" || riskVariesByEntry
            let canBeAutomatic = descriptor["automaticEligible"] as? Bool == true
                || automaticEligibilityVariesByEntry
            if !canBeSafe || !canBeAutomatic {
                XCTAssertFalse(surfaces.contains("automatic-rule"), definition.key.id)
            } else if riskVariesByEntry || automaticEligibilityVariesByEntry {
                if supportsUnattendedExecution {
                    XCTAssertTrue(surfaces.contains("automatic-rule"), definition.key.id)
                }
            } else {
                XCTAssertEqual(
                    surfaces.contains("automatic-rule"),
                    supportsUnattendedExecution,
                    definition.key.id
                )
            }
            let hasOnlyPortableParameters = definition.parameters.allSatisfy {
                $0.portability == .portable
            }
            let hasLocalOnlyIdentity = !isStatic
                && (descriptor["localOnlyIdentity"] as? Bool) == true
            let exposurePolicy = (plugin as? any PluginActionExposureProviding)?
                .exposurePolicy(
                    for: ActionReference(key: definition.key),
                    on: .appIntents
                ) ?? .automatic
            let supportsAppIntent = supportsUnattendedExecution
                && hasOnlyPortableParameters
                && !hasLocalOnlyIdentity
                && exposurePolicy != .excluded
            if !canBeSafe || !canBeAutomatic || !hasOnlyPortableParameters || hasLocalOnlyIdentity {
                XCTAssertFalse(surfaces.contains("app-intent"), definition.key.id)
            } else if riskVariesByEntry || automaticEligibilityVariesByEntry {
                if supportsAppIntent {
                    XCTAssertTrue(surfaces.contains("app-intent"), definition.key.id)
                }
            } else {
                XCTAssertEqual(
                    surfaces.contains("app-intent"),
                    supportsAppIntent,
                    definition.key.id
                )
            }
            let manifestPermissionIDs = Set(descriptor["permissionIDs"] as? [String] ?? [])
            if !manifestPermissionIDs.isEmpty {
                guard let permissionProvider = plugin as? any PluginActionPermissionProviding else {
                    XCTFail(
                        "\(definition.key.id) declares action permissions without a runtime provider"
                    )
                    continue
                }
                XCTAssertEqual(
                    manifestPermissionIDs,
                    Set(permissionProvider.permissionRequirementIDs(for: definition.key)),
                    definition.key.id
                )
            } else if let permissionProvider = plugin as? any PluginActionPermissionProviding {
                XCTAssertEqual(
                    manifestPermissionIDs,
                    Set(permissionProvider.permissionRequirementIDs(for: definition.key)),
                    definition.key.id
                )
            }
            if isStatic {
                XCTAssertEqual(
                    descriptor["systemImage"] as? String,
                    definition.systemImage,
                    definition.key.id
                )
            }
            let manifestParameters = descriptor["parameters"] as? [[String: Any]] ?? []
            XCTAssertEqual(
                manifestParameters.compactMap { $0["id"] as? String },
                definition.parameters.map(\.id),
                definition.key.id
            )
            for parameter in definition.parameters {
                let value = try XCTUnwrap(
                    manifestParameters.first { $0["id"] as? String == parameter.id },
                    definition.key.id
                )
                XCTAssertEqual(value["kind"] as? String, parameter.kind.rawValue, definition.key.id)
                XCTAssertEqual(value["isRequired"] as? Bool, parameter.isRequired, definition.key.id)
                XCTAssertEqual(
                    value["portability"] as? String,
                    parameter.portability.rawValue,
                    definition.key.id
                )
            }
        }
    }

    private func dynamicTemplateID(pluginID: String, actionID: String) -> String? {
        if Self.dynamicActionIDs[pluginID]?.contains(actionID) == true {
            return actionID
        }
        if pluginID == "sidecar", actionID.hasPrefix("device.") {
            return "device"
        }
        if pluginID == "window-layouts", actionID.hasPrefix("custom.") {
            return "custom-command"
        }
        return nil
    }

    private func sourceManifest(pluginID: String) throws -> [String: Any] {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let paths = try FileManager.default.contentsOfDirectory(
            at: repositoryRoot.appendingPathComponent("Plugins", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        for path in paths {
            let manifestURL = path.appendingPathComponent("plugin.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let manifest = object as? [String: Any],
                  manifest["id"] as? String == pluginID else { continue }
            return manifest
        }
        throw XCTSkip("Missing source manifest for \(pluginID)")
    }

    private struct Registration {
        let pluginID: String
        let makeProvider: (PluginRuntimeContext) throws -> any PluginProvider
    }

    private static let registrations: [Registration] = [
        .init(pluginID: "action-grid", makeProvider: ActionGridPluginFactory.makeProvider),
        .init(pluginID: "activity-bar", makeProvider: ActivityBarPluginFactory.makeProvider),
        .init(pluginID: "ai-assistant", makeProvider: AIAssistantPluginFactory.makeProvider),
        .init(pluginID: "app-hotkey", makeProvider: AppHotkeyPluginFactory.makeProvider),
        .init(pluginID: "app-volume", makeProvider: AppVolumePluginFactory.makeProvider),
        .init(pluginID: "appearance", makeProvider: AppearancePluginFactory.makeProvider),
        .init(pluginID: "apple-shortcuts", makeProvider: AppleShortcutsPluginFactory.makeProvider),
        .init(pluginID: "auto-hide-dock", makeProvider: AutoHideDockPluginFactory.makeProvider),
        .init(pluginID: "auto-hide-menu-bar", makeProvider: AutoHideMenuBarPluginFactory.makeProvider),
        .init(pluginID: "auto-input", makeProvider: AutoInputPluginFactory.makeProvider),
        .init(pluginID: "battery-charge-limit", makeProvider: BatteryChargeLimitPluginFactory.makeProvider),
        .init(pluginID: "clipboard-clear", makeProvider: ClipboardClearPluginFactory.makeProvider),
        .init(pluginID: "clipboard", makeProvider: ClipboardHistoryPluginFactory.makeProvider),
        .init(pluginID: "cloudflare-r2", makeProvider: CloudflareR2PluginFactory.makeProvider),
        .init(pluginID: "disk-clean", makeProvider: DiskCleanPluginFactory.makeProvider),
        .init(pluginID: "display-brightness", makeProvider: DisplayBrightnessPluginFactory.makeProvider),
        .init(pluginID: "display-resolution", makeProvider: DisplayResolutionPluginFactory.makeProvider),
        .init(pluginID: "display-sleep", makeProvider: DisplaySleepPluginFactory.makeProvider),
        .init(pluginID: "display-true-color", makeProvider: DisplayTrueColorPluginFactory.makeProvider),
        .init(pluginID: "display-volume", makeProvider: DisplayVolumePluginFactory.makeProvider),
        .init(pluginID: "dock-lock", makeProvider: DockLockPluginFactory.makeProvider),
        .init(pluginID: "eject-disk", makeProvider: EjectDiskPluginFactory.makeProvider),
        .init(pluginID: "empty-trash", makeProvider: EmptyTrashPluginFactory.makeProvider),
        .init(pluginID: "fan-control", makeProvider: FanControlPluginFactory.makeProvider),
        .init(pluginID: "fix-damaged-app", makeProvider: FixDamagedAppPluginFactory.makeProvider),
        .init(pluginID: "hide-notch", makeProvider: HideNotchPluginFactory.makeProvider),
        .init(pluginID: "homebrew", makeProvider: HomebrewPluginFactory.makeProvider),
        .init(pluginID: "ip-overview", makeProvider: IPOverviewPluginFactory.makeProvider),
        .init(pluginID: "keep-awake", makeProvider: KeepAwakePluginFactory.makeProvider),
        .init(pluginID: "launch-control", makeProvider: LaunchControlPluginFactory.makeProvider),
        .init(pluginID: "launchpad", makeProvider: LaunchpadPluginFactory.makeProvider),
        .init(pluginID: "lock-screen", makeProvider: LockScreenPluginFactory.makeProvider),
        .init(pluginID: "mac-settings", makeProvider: MacSettingsPluginFactory.makeProvider),
        .init(pluginID: "menu-bar-hidden", makeProvider: MenuBarHiddenPluginFactory.makeProvider),
        .init(pluginID: "microphone-mute", makeProvider: MicrophoneMutePluginFactory.makeProvider),
        .init(pluginID: "middle-click", makeProvider: MiddleClickPluginFactory.makeProvider),
        .init(pluginID: "night-shift", makeProvider: NightShiftPluginFactory.makeProvider),
        .init(pluginID: "physical-clean-mode", makeProvider: PhysicalCleanModePluginFactory.makeProvider),
        .init(pluginID: "quit-apps", makeProvider: QuitAppsPluginFactory.makeProvider),
        .init(pluginID: "saved-scripts", makeProvider: SavedScriptsPluginFactory.makeProvider),
        .init(pluginID: "screenshot", makeProvider: ScreenshotPluginFactory.makeProvider),
        .init(pluginID: "siri", makeProvider: SiriPluginFactory.makeProvider),
        .init(pluginID: "sidecar", makeProvider: SidecarPluginFactory.makeProvider),
        .init(pluginID: "stage-manager", makeProvider: StageManagerPluginFactory.makeProvider),
        .init(pluginID: "system-mute", makeProvider: SystemMutePluginFactory.makeProvider),
        .init(pluginID: "system-power", makeProvider: SystemPowerPluginFactory.makeProvider),
        .init(pluginID: "system-soft-restart", makeProvider: SystemSoftRestartPluginFactory.makeProvider),
        .init(pluginID: "translator", makeProvider: TranslatorPluginFactory.makeProvider),
        .init(pluginID: "window-layouts", makeProvider: WindowLayoutsPluginFactory.makeProvider),
        .init(pluginID: "window-switcher", makeProvider: WindowSwitcherPluginFactory.makeProvider),
        .init(pluginID: "xcode-clean", makeProvider: XcodeCleanPluginFactory.makeProvider),
    ]

    private static let dynamicActionIDs: [String: Set<String>] = [
        "app-hotkey": ["launch"],
        "app-volume": ["set-volume"],
        "auto-input": ["select-input-source"],
        "battery-charge-limit": ["set-limit"],
        "display-resolution": ["set-resolution"],
        "fan-control": ["apply-preset"],
        "launch-control": ["start-favorite", "stop-favorite", "restart-favorite"],
    ]
}

@MainActor
private final class SnapshotPluginStorage: PluginStorage {
    private var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {
        guard values[key] == nil, let value = values.removeValue(forKey: legacyKey) else { return }
        values[key] = value
    }
}
