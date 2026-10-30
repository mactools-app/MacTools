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
        let draft = VoiceFeatureAccessDraft(providers: providers,
            featureAccess: .init(excludedPluginIDs: ["power", "unloaded"]))
        let matches = draft.matches(" display ")
        XCTAssertEqual(Set(matches.map(\.id)), ["brightness", "volume"])
        draft.setAllowed(false, for: matches)
        XCTAssertEqual(draft.allowedCount, 0)
        XCTAssertEqual(draft.changes, ["brightness": false, "volume": false])
        draft.setAllowed(true, for: matches)
        XCTAssertEqual(draft.access, ["brightness": true, "volume": true, "power": false])
        XCTAssertTrue(draft.featureAccess.excludedPluginIDs.contains("unloaded"))
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
        plugin.setProviderAccess(["brightness": false], automaticallyAllowNewPlugins: false)
        XCTAssertTrue(plugin.conversation.excludedPluginIDs.isEmpty)
        XCTAssertTrue(plugin.conversation.featureAccess.automaticallyAllowNewPlugins)
        XCTAssertNil(storage.stringArray(forKey: "excludedProviders"))
        XCTAssertEqual(backups, 0)
        plugin.conversation.stop()
    }

    func testAutomaticPolicyKeepsCurrentChoicesAndRequiresApprovalForLaterProviders() {
        let storage = VoiceCredentialTestStorage()
        storage.set(["volume"], forKey: "excludedProviders")
        let plugin = makePlugin(storage: storage)
        var available = providers
        plugin.voiceControlHostContext = .init(providers: { available },
            begin: { _ in nil }, end: { _ in }, request: { _, _ in .init() })
        XCTAssertTrue(plugin.conversation.featureAccess.automaticallyAllowNewPlugins, "Existing settings keep automatic access")
        plugin.setProviderAccess([:], automaticallyAllowNewPlugins: false)
        available.append(.init(id: "later", title: "Later Plugin"))
        XCTAssertEqual(Set(plugin.conversation.allowedProviders.map(\.id)), ["brightness", "power"])
        let restored = makePlugin(storage: storage)
        XCTAssertEqual(restored.conversation.featureAccess, plugin.conversation.featureAccess)
        plugin.setProviderAccess(["later": true])
        XCTAssertTrue(plugin.conversation.allowedProviders.contains { $0.id == "later" })
        plugin.setProviderAccess([:], automaticallyAllowNewPlugins: true)
        available.append(.init(id: "newest", title: "Newest Plugin"))
        XCTAssertTrue(plugin.conversation.allowedProviders.contains { $0.id == "newest" })
        XCTAssertFalse(plugin.conversation.allowedProviders.contains { $0.id == "volume" })
    }

    func testBatchSelectionDoesNotChangeAutomaticPolicy() {
        let plugin = makePlugin(storage: VoiceCredentialTestStorage())
        plugin.setProviderAccess([:], automaticallyAllowNewPlugins: false)
        let draft = VoiceFeatureAccessDraft(providers: providers, featureAccess: plugin.conversation.featureAccess)
        draft.setAllowed(false, for: draft.providers)
        XCTAssertEqual(plugin.conversation.allowedProviders.count, providers.count, "Draft changes remain local until Done")
        plugin.setProviderAccess(draft.changes)
        XCTAssertFalse(plugin.conversation.featureAccess.automaticallyAllowNewPlugins)
        XCTAssertTrue(plugin.conversation.allowedProviders.isEmpty)
        plugin.setProviderAccess(Dictionary(uniqueKeysWithValues: providers.map { ($0.id, true) }))
        XCTAssertFalse(plugin.conversation.featureAccess.automaticallyAllowNewPlugins)
        XCTAssertFalse(plugin.conversation.featureAccess.isAllowed("later"))
    }

    func testPortablePreferencesPreserveManualApprovalsAndReadLegacyDefaults() throws {
        let plugin = makePlugin(storage: VoiceCredentialTestStorage())
        plugin.setProviderAccess(["volume": false], automaticallyAllowNewPlugins: false)
        let data = try XCTUnwrap(plugin.makePortablePreferencesBackup())
        let copy = makePlugin(storage: VoiceCredentialTestStorage())
        XCTAssertTrue(copy.restorePortablePreferencesReportingResult(from: data))
        XCTAssertEqual(copy.conversation.featureAccess, plugin.conversation.featureAccess)
        XCTAssertFalse(copy.conversation.featureAccess.isAllowed("later"))
        let legacy = Data(#"{"version":1,"excludedProviders":["volume"]}"#.utf8)
        XCTAssertTrue(copy.restorePortablePreferencesReportingResult(from: legacy))
        XCTAssertTrue(copy.conversation.featureAccess.isAllowed("later"))
        XCTAssertFalse(copy.conversation.featureAccess.isAllowed("volume"))
        let malformed = Data(#"{"version":2,"excludedProviders":[],"automaticallyAllowNewPlugins":false}"#.utf8)
        XCTAssertFalse(copy.restorePortablePreferencesReportingResult(from: malformed))
        XCTAssertFalse(copy.conversation.featureAccess.isAllowed("volume"), "Malformed backups must not change access")
    }

    private func makePlugin(storage: VoiceCredentialTestStorage) -> VoiceControlPlugin {
        let plugin = VoiceControlPlugin(context: .init(pluginID: "voice-control", storage: storage))
        plugin.voiceControlHostContext = .init(providers: { [providers] in providers },
            begin: { _ in nil }, end: { _ in }, request: { _, _ in .init(status: "sessionEnded") })
        return plugin
    }
}
