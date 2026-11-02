import XCTest
import MacToolsPluginKit
@testable import AppearancePlugin

@MainActor
final class AppearancePluginTests: XCTestCase {
    private final class VoiceAppearanceController: SystemAppearanceControlling {
        var snapshot = SystemAppearanceSnapshot(mode: .auto, isDark: false)
        func read() throws -> SystemAppearanceSnapshot { snapshot }
        func setMode(_ mode: SystemAppearanceMode) throws { XCTFail("A voice query must not write appearance") }
    }
    func testVoiceReadsFreshPolicyAndRenderedTheme() async throws {
        let controller = VoiceAppearanceController()
        let plugin = AppearancePlugin(appearanceController: controller)
        controller.snapshot = .init(mode: .auto, isDark: true)
        let value = try JSONSerialization.jsonObject(with: Data(try await plugin.readVoiceQuery(id: "appearance-state").utf8)) as? [String: Any]
        XCTAssertEqual(value?["mode"] as? String, "auto")
        XCTAssertEqual(value?["isDark"] as? Bool, true)
    }

    func testManifestActionsMatchRuntimePolicy() throws {
        let plugin = AppearancePlugin()

        try PluginManifestActionAssertions.assertConsistency(
            pluginDirectoryName: "Appearance",
            definitions: plugin.actionDefinitions,
            permissionIDs: plugin.permissionRequirementIDs(for:)
        )
    }

    func testPublishesIdempotentLightAndDarkActions() {
        let plugin = AppearancePlugin()

        XCTAssertEqual(plugin.actionDefinitions.map(\.key.actionID), ["toggle", "set-enabled", "set-mode"])
        XCTAssertEqual(Array(plugin.actionCatalogEntries.dropFirst().prefix(2).map(\.title)), [
            "启用深色模式",
            "启用浅色模式",
        ])
        XCTAssertEqual(
            plugin.actionCatalogEntries.first?.presentationState,
            plugin.rowState.isOn ? .active : .inactive
        )
        XCTAssertTrue(
            plugin.actionDefinitions[0].capabilities.contains(.background)
        )
        XCTAssertEqual(
            plugin.actionDefinitions[0].externalInvocationPolicy,
            .allowed
        )
    }

    func testAutomationPermissionIsReportedAsOnDemand() {
        let state = AppearancePlugin().permissionState(for: "automation")

        XCTAssertFalse(state.isGranted)
        XCTAssertEqual(state.statusText, "按需确认")
        XCTAssertEqual(state.statusTone, .neutral)
    }
}
