import XCTest
import MacToolsPluginKit
@testable import SystemMutePlugin

@MainActor
final class SystemMutePluginTests: XCTestCase {
    func testVoiceDistinguishesFreshMuteStateFromUnavailableDevice() async throws {
        let controller = MockController(muteState: false)
        let plugin = SystemMutePlugin(controller: controller)
        controller.muteState = true
        let value = try JSONSerialization.jsonObject(with: Data(try await plugin.readVoiceQuery(id: "system-output-state").utf8)) as? [String: Any]
        XCTAssertEqual(value?["muted"] as? Bool, true)
        controller.observationAvailable = false
        do { _ = try await plugin.readVoiceQuery(id: "system-output-state"); XCTFail("Unavailable must not be reported as unmuted") }
        catch {}
    }

    private final class MockController: SystemAudioControlling {
        var muteState: Bool
        var observationAvailable = true
        var setMuteResult: Bool

        init(muteState: Bool, setMuteResult: Bool = true) {
            self.muteState = muteState
            self.setMuteResult = setMuteResult
        }

        func readMuteState() -> Bool { muteState }
        func observedMuteState() -> Bool? { observationAvailable ? muteState : nil }
        func setMuteState(_ muted: Bool) -> Bool {
            if setMuteResult {
                muteState = muted
            }
            return setMuteResult
        }
    }

    func testPanelStateReflectsMuteState() {
        let unmuted = SystemMutePlugin(controller: MockController(muteState: false))
        let muted = SystemMutePlugin(controller: MockController(muteState: true))

        XCTAssertFalse(unmuted.rowState.isOn)
        XCTAssertEqual(unmuted.rowState.subtitle, "未静音")
        XCTAssertTrue(muted.rowState.isOn)
        XCTAssertEqual(muted.rowState.subtitle, "已静音")
    }

    func testSwitchUpdatesStateAndNotifiesHost() {
        let plugin = SystemMutePlugin(controller: MockController(muteState: false))
        var notificationCount = 0
        plugin.onStateChange = { notificationCount += 1 }

        plugin.handleAction(.setSwitch(true))

        XCTAssertTrue(plugin.rowState.isOn)
        XCTAssertNil(plugin.rowState.errorMessage)
        XCTAssertEqual(notificationCount, 1)
    }

    func testSwitchFailureKeepsStateAndReportsError() {
        let plugin = SystemMutePlugin(
            controller: MockController(muteState: false, setMuteResult: false)
        )

        plugin.handleAction(.setSwitch(true))

        XCTAssertFalse(plugin.rowState.isOn)
        XCTAssertNotNil(plugin.rowState.errorMessage)
    }

    func testFailureRelocalizesAndClearsOnSamePluginInstance() async throws {
        let original = UserDefaults.standard.string(
            forKey: PluginRuntimeLocalization.preferenceUserDefaultsKey
        )
        defer { PluginRuntimeLocalization.source.setPreference(original) }
        let (localization, directory) = try makeLocalization([
            "en": ["error.muteFailed": "Failed to mute audio."],
            "ar": ["error.muteFailed": "فشل كتم الصوت."],
        ])
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = MockController(muteState: false, setMuteResult: false)
        let plugin = SystemMutePlugin(
            controller: controller,
            localization: localization
        )

        PluginRuntimeLocalization.source.setPreference("en")
        plugin.handleAction(.setSwitch(true))
        XCTAssertEqual(plugin.rowState.errorMessage, "Failed to mute audio.")

        PluginRuntimeLocalization.source.setPreference("ar")
        XCTAssertEqual(plugin.rowState.errorMessage, "فشل كتم الصوت.")
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)
        let failure = try await plugin.beginAction(
            ActionInvocation(reference: reference, source: .test, mode: .background)
        ).result()
        XCTAssertEqual(failure, .failed(message: "فشل كتم الصوت."))

        controller.setMuteResult = true
        plugin.handleAction(.setSwitch(true))
        XCTAssertTrue(plugin.rowState.isOn)
        XCTAssertNil(plugin.rowState.errorMessage)
    }

    func testRefreshDoesNotNotifyWhenStateIsUnchanged() {
        let plugin = SystemMutePlugin(controller: MockController(muteState: false))
        var notificationCount = 0
        plugin.onStateChange = { notificationCount += 1 }

        plugin.refresh()

        XCTAssertEqual(notificationCount, 0)
    }

    func testActionCatalogProvidesIdempotentMuteChoices() async throws {
        let plugin = SystemMutePlugin(controller: MockController(muteState: false))
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        let result = try await plugin.beginAction(
            ActionInvocation(reference: reference, source: .test, mode: .background)
        ).result()

        XCTAssertEqual(plugin.actionDefinitions.map(\.key.actionID), ["toggle", "set-enabled"])
        XCTAssertEqual(
            plugin.actionCatalogEntries.map(\.title),
            ["恢复系统音频", "静音系统音频", "恢复系统音频"]
        )
        XCTAssertEqual(plugin.actionCatalogEntries.first?.presentationState, .active)
        XCTAssertEqual(result, .succeeded())
        XCTAssertTrue(plugin.rowState.isOn)
    }

    private func makeLocalization(
        _ valuesByLanguage: [String: [String: String]]
    ) throws -> (PluginLocalization, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundleURL = directory.appendingPathComponent("SystemMuteTests.bundle", isDirectory: true)
        for (language, values) in valuesByLanguage {
            let languageURL = bundleURL.appendingPathComponent("\(language).lproj", isDirectory: true)
            try FileManager.default.createDirectory(at: languageURL, withIntermediateDirectories: true)
            try values.map { "\"\($0.key)\" = \"\($0.value)\";" }
                .joined(separator: "\n")
                .write(
                    to: languageURL.appendingPathComponent("Localizable.strings"),
                    atomically: true,
                    encoding: .utf8
                )
        }
        return (
            PluginLocalization(bundle: try XCTUnwrap(Bundle(url: bundleURL))),
            directory
        )
    }
}
