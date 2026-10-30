import MacToolsPluginKit
import XCTest
@testable import VoiceControlPlugin

@MainActor
final class VoiceFeatureAccessTests: XCTestCase {
    private let providers: [PluginVoiceProvider] = [
        .init(id: "brightness", title: "Display Brightness"),
        .init(id: "volume", title: "Display Volume"),
        .init(id: "power", title: "Power Status")
    ]

    func testFilteredBatchEditsPreserveHiddenChoicesUntilCommit() {
        let draft = VoiceFeatureAccessDraft(providers: providers, excludedPluginIDs: ["power", "unloaded"])
        let matches = draft.matches(" display ")
        XCTAssertEqual(Set(matches.map(\.id)), ["brightness", "volume"])
        draft.setAllowed(false, for: matches)
        XCTAssertEqual(draft.allowedCount, 0)
        XCTAssertEqual(draft.changes, ["brightness": false, "volume": false])
        draft.setAllowed(true, for: matches)
        XCTAssertEqual(draft.access, ["brightness": true, "volume": true, "power": false])
        XCTAssertTrue(draft.excludedPluginIDs.contains("unloaded"))
        XCTAssertTrue(draft.changes.isEmpty, "Untouched or reverted choices must not overwrite newer preferences")
        draft.setAllowed(true, for: draft.matches("no matches"))
        XCTAssertEqual(draft.allowedCount, 2)
    }

    func testCommitPreservesUnavailableExclusionsAndNotifiesBackupOnce() {
        let storage = VoiceCredentialTestStorage()
        storage.set(["volume", "unloaded"], forKey: "excludedProviders")
        let plugin = makePlugin(storage: storage)
        var backups = 0
        var hostRebuilds = 0
        plugin.onPersistentPreferencesChange = { backups += 1 }
        plugin.onStateChange = { hostRebuilds += 1 }
        let access = ["brightness": false, "volume": true, "unloaded": true, "unknown": false]
        plugin.setProviderAccess(access)
        XCTAssertEqual(plugin.conversation.excludedPluginIDs, ["brightness", "unloaded"])
        XCTAssertEqual(storage.stringArray(forKey: "excludedProviders"), ["brightness", "unloaded"])
        XCTAssertEqual(backups, 1)
        XCTAssertEqual(hostRebuilds, 0)
        plugin.setProviderAccess(access)
        XCTAssertEqual(backups, 1, "Unchanged selections must not trigger another backup")
    }

    func testConversationStartedWhileEditingRejectsTheDraft() {
        let storage = VoiceCredentialTestStorage()
        storage.set("keychain", forKey: "credentialSource")
        let plugin = makePlugin(storage: storage)
        var backups = 0
        plugin.onPersistentPreferencesChange = { backups += 1 }
        // Stop before yielding: beginSession returns nil, so no credentials or audio are read.
        plugin.conversation.start()
        XCTAssertTrue(plugin.conversation.active)
        plugin.setProviderAccess(["brightness": false])
        XCTAssertTrue(plugin.conversation.excludedPluginIDs.isEmpty)
        XCTAssertNil(storage.stringArray(forKey: "excludedProviders"))
        XCTAssertEqual(backups, 0)
        plugin.conversation.stop()
    }

    private func makePlugin(storage: VoiceCredentialTestStorage) -> VoiceControlPlugin {
        let plugin = VoiceControlPlugin(context: .init(pluginID: "voice-control", storage: storage))
        plugin.voiceControlHostContext = .init(providers: { [providers] in providers },
            begin: { _ in nil }, end: { _ in }, request: { _, _ in .init(status: "sessionEnded") })
        return plugin
    }
}
