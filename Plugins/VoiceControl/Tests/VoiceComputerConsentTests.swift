import Foundation
import MacToolsPluginKit
import XCTest
@testable import VoiceControlPlugin

@MainActor
final class VoiceComputerConsentTests: XCTestCase {
    func testLegacyFeatureSwitchAndPortableBackupDoNotGrantReadingConsent() throws {
        let storage = VoiceCredentialTestStorage()
        storage.set(true, forKey: "computerInteractionEnabled")
        let plugin = makePlugin(storage)
        XCTAssertTrue(plugin.computerUse.enabled)
        XCTAssertFalse(plugin.allowsAppReading)
        let read = ActionReference(key: .init(providerID: "voice-control", actionID: "computer-inspect-app"),
            parameters: try .init(["app": .string("Chrome")]))
        XCTAssertFalse(plugin.actionAvailability(for: read).isAvailable)
        XCTAssertThrowsError(try plugin.beginAction(.init(reference: read, source: .test, mode: .foreground)))
        plugin.setAppReadingConsent(true)
        XCTAssertTrue(makePlugin(storage).allowsAppReading)
        let backup = try XCTUnwrap(plugin.makePortablePreferencesBackup())
        let other = makePlugin(VoiceCredentialTestStorage())
        XCTAssertTrue(other.restorePortablePreferencesReportingResult(from: backup))
        XCTAssertFalse(other.allowsAppReading)
        plugin.setAppReadingConsent(false)
        XCTAssertFalse(makePlugin(storage).allowsAppReading)
    }

    func testReadConsentNeedsAnActiveConversationAndRevocationStopsIt() {
        let storage = VoiceCredentialTestStorage()
        storage.set("keychain", forKey: "credentialSource")
        let plugin = makePlugin(storage)
        plugin.setAppReadingConsent(true)
        XCTAssertFalse(plugin.canReadAppContent)
        plugin.conversation.start()
        defer { plugin.conversation.stop() }
        // Stop before yielding: no credential, microphone or network work can run.
        XCTAssertTrue(plugin.canReadAppContent)
        plugin.conversation.setReadingApp("Chrome")
        XCTAssertEqual(plugin.conversation.readingApp, "Chrome")
        plugin.setAppReadingConsent(false)
        XCTAssertFalse(plugin.conversation.active)
        XCTAssertFalse(plugin.canReadAppContent)
        XCTAssertNil(plugin.conversation.readingApp)
        plugin.conversation.setReadingApp("Late app")
        XCTAssertNil(plugin.conversation.readingApp)
    }

    func testReadsHaveNoPerRequestPromptButInputKeepsNativeApproval() throws {
        let storage = VoiceCredentialTestStorage()
        storage.set("keychain", forKey: "credentialSource")
        let plugin = makePlugin(storage)
        let read = try XCTUnwrap(plugin.actionDefinitions.first { $0.key.actionID == "computer-inspect-app" })
        XCTAssertEqual(read.risk, .safe)
        XCTAssertNil(read.confirmation)
        for id in ["computer-click-control", "computer-set-control-value", "computer-scroll-control"] {
            let action = try XCTUnwrap(plugin.actionDefinitions.first { $0.key.actionID == id })
            XCTAssertEqual(action.risk, .confirmationRequired)
            XCTAssertNotNil(action.confirmation)
        }
        plugin.conversation.start()
        defer { plugin.conversation.stop() }
        plugin.setAppReadingConsent(true)
        XCTAssertFalse(plugin.allowsAppReading, "Setup consent cannot expand an active conversation")
    }

    private func makePlugin(_ storage: VoiceCredentialTestStorage) -> VoiceControlPlugin {
        let context = PluginRuntimeContext(pluginID: "voice-control", storage: storage)
        let model = VoiceConversation(context: context, secrets: VoiceCredentialTestSecrets())
        return VoiceControlPlugin(context: context, conversation: model)
    }
}
