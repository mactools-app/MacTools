import AppKit
import MacToolsPluginKit
import XCTest
@testable import VoiceControlPlugin

@MainActor
final class VoiceAssistantPanelTests: XCTestCase {
    func testStopLeavesNativePanelVisibleAndToggleDismissesIt() throws {
        _ = NSApplication.shared
        let storage = VoiceCredentialTestStorage()
        storage.set("none", forKey: "credentialSource")
        let model = VoiceConversation(context: .init(pluginID: "voice-control", storage: storage),
                                      secrets: VoiceCredentialTestSecrets())
        let presenter = VoiceAssistantPanel(conversation: model)
        defer { presenter.tearDown() }
        presenter.toggle()
        let window = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "voice-control.assistant" })
        XCTAssertTrue(window.isVisible)
        model.stop()
        XCTAssertTrue(window.isVisible)
        presenter.toggleExpanded()
        XCTAssertTrue(presenter.expanded)
        XCTAssertTrue(window.isVisible)
        presenter.toggle()
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(model.active)
    }
}
