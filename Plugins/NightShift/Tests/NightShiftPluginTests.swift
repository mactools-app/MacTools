import XCTest
import MacToolsPluginKit
@testable import NightShiftPlugin

@MainActor
final class NightShiftPluginTests: XCTestCase {
    func testVoiceDistinguishesFreshStatusFromUnavailableReadback() async throws {
        let client = MockCoreBrightnessClient(enabled: false)
        let plugin = NightShiftPlugin(controller: CBNightShiftController(client: client))
        client.enabled = true
        let value = try JSONSerialization.jsonObject(with: Data(try await plugin.readVoiceQuery(id: "night-shift-state").utf8)) as? [String: Any]
        XCTAssertEqual(value?["enabled"] as? Bool, true)
        client.enabled = nil
        do { _ = try await plugin.readVoiceQuery(id: "night-shift-state"); XCTFail("Unavailable must not be reported as disabled") }
        catch {}
    }


    private final class MockController: NightShiftControlling {
        var status: Bool
        var setEnabledResult: Bool

        init(status: Bool, setEnabledResult: Bool = true) {
            self.status = status
            self.setEnabledResult = setEnabledResult
        }

        func getStatus() -> Bool { status }
        func setEnabled(_ enabled: Bool) -> Bool {
            if setEnabledResult {
                status = enabled
            }
            return setEnabledResult
        }
    }

    private final class MockCoreBrightnessClient: NightShiftCoreBrightnessCalling {
        var enabled: Bool?
        var acceptsWrites: Bool
        var appliesWrites: Bool

        init(
            enabled: Bool?,
            acceptsWrites: Bool = true,
            appliesWrites: Bool = true
        ) {
            self.enabled = enabled
            self.acceptsWrites = acceptsWrites
            self.appliesWrites = appliesWrites
        }

        func isEnabled() -> Bool? {
            enabled
        }

        func setEnabled(_ enabled: Bool) -> Bool {
            guard acceptsWrites else {
                return false
            }
            if appliesWrites {
                self.enabled = enabled
            }
            return true
        }
    }

    func testStatusLayoutUsesRuntimeEncodedSizeAndEnabledOffset() throws {
        let armLayout = try XCTUnwrap(NightShiftStatusBufferLayout.resolve(
            argumentType: "^{?=BBBi{?={?=ii}{?=ii}}QB}"
        ))
        let intelLayout = try XCTUnwrap(NightShiftStatusBufferLayout.resolve(
            argumentType: "^{?=ccci{?={?=ii}{?=ii}}Qc}"
        ))

        XCTAssertEqual(armLayout.byteCount, 40)
        XCTAssertEqual(armLayout.alignment, 8)
        XCTAssertEqual(armLayout.enabledOffset, 1)
        XCTAssertEqual(intelLayout.enabledOffset, 1)
        XCTAssertGreaterThanOrEqual(intelLayout.byteCount, 33)
    }

    func testStatusLayoutRejectsIncompatibleOrInvalidEncodings() {
        XCTAssertNil(NightShiftStatusBufferLayout.resolve(
            argumentType: "^{?=iBf{?={?=ii}{?=ii}}Q}"
        ))
        XCTAssertNil(NightShiftStatusBufferLayout.resolve(argumentType: "^v"))
        XCTAssertNil(NightShiftStatusBufferLayout.resolve(argumentType: "B"))
    }

    func testControllerVerifiesAppliedRuntimeState() {
        let applied = MockCoreBrightnessClient(enabled: false)
        let ignored = MockCoreBrightnessClient(
            enabled: false,
            appliesWrites: false
        )
        let rejected = MockCoreBrightnessClient(
            enabled: false,
            acceptsWrites: false
        )

        XCTAssertTrue(CBNightShiftController(client: applied).setEnabled(true))
        XCTAssertFalse(CBNightShiftController(client: ignored).setEnabled(true))
        XCTAssertFalse(CBNightShiftController(client: rejected).setEnabled(true))
        XCTAssertTrue(CBNightShiftController(client: applied).getStatus())
    }

    func testPanelStateReflectsControllerStatus() {
        let disabled = NightShiftPlugin(controller: MockController(status: false))
        let enabled = NightShiftPlugin(controller: MockController(status: true))

        XCTAssertFalse(disabled.rowState.isOn)
        XCTAssertEqual(disabled.rowState.subtitle, "已关闭")
        XCTAssertTrue(enabled.rowState.isOn)
        XCTAssertEqual(enabled.rowState.subtitle, "已开启")
    }

    func testSwitchUpdatesPanelState() {
        let plugin = NightShiftPlugin(controller: MockController(status: false))

        plugin.handleAction(.setSwitch(true))

        XCTAssertTrue(plugin.rowState.isOn)
        XCTAssertNil(plugin.rowState.errorMessage)
    }

    func testSwitchFailureKeepsStateAndReportsError() {
        let plugin = NightShiftPlugin(
            controller: MockController(status: true, setEnabledResult: false)
        )

        plugin.handleAction(.setSwitch(false))

        XCTAssertTrue(plugin.rowState.isOn)
        XCTAssertNotNil(plugin.rowState.errorMessage)
    }

    func testActionCatalogProvidesIdempotentNightShiftChoices() async throws {
        let plugin = NightShiftPlugin(controller: MockController(status: false))
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        let result = try await plugin.beginAction(
            ActionInvocation(reference: reference, source: .test, mode: .background)
        ).result()

        XCTAssertEqual(plugin.actionDefinitions.map(\.key.actionID), ["toggle", "set-enabled"])
        XCTAssertEqual(plugin.actionCatalogEntries.map(\.title), ["停用夜览", "启用夜览", "停用夜览"])
        XCTAssertEqual(plugin.actionCatalogEntries.first?.presentationState, .active)
        XCTAssertEqual(result, .succeeded())
        XCTAssertTrue(plugin.rowState.isOn)
    }

    private func makeLocalization(
        _ valuesByLanguage: [String: [String: String]]
    ) throws -> (PluginLocalization, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundleURL = directory.appendingPathComponent("NightShiftTests.bundle", isDirectory: true)
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
