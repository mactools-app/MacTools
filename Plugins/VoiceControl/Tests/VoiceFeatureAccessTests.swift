import Foundation
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
        let storage = VoiceCredentialTestStorage()
        let plugin = makePlugin(storage: storage)
        XCTAssertEqual(plugin.conversation.idleTimeout, .oneMinute)
        plugin.setIdleTimeout(.fiveMinutes)
        XCTAssertEqual(makePlugin(storage: storage).conversation.idleTimeout, .fiveMinutes)
        plugin.setProviderAccess(["volume": false], automaticallyAllowNewPlugins: false)
        let data = try XCTUnwrap(plugin.makePortablePreferencesBackup())
        let copy = makePlugin(storage: VoiceCredentialTestStorage())
        XCTAssertTrue(copy.restorePortablePreferencesReportingResult(from: data))
        XCTAssertEqual(copy.conversation.featureAccess, plugin.conversation.featureAccess)
        XCTAssertEqual(copy.conversation.idleTimeout, .fiveMinutes)
        XCTAssertFalse(copy.conversation.featureAccess.isAllowed("later"))
        let legacy = Data(#"{"version":1,"excludedProviders":["volume"]}"#.utf8)
        XCTAssertTrue(copy.restorePortablePreferencesReportingResult(from: legacy))
        XCTAssertTrue(copy.conversation.featureAccess.isAllowed("later"))
        XCTAssertEqual(copy.conversation.idleTimeout, .fiveMinutes, "Older backups preserve the current idle choice")
        XCTAssertFalse(copy.conversation.featureAccess.isAllowed("volume"))
        let malformed = Data(#"{"version":2,"excludedProviders":[],"automaticallyAllowNewPlugins":false}"#.utf8)
        XCTAssertFalse(copy.restorePortablePreferencesReportingResult(from: malformed))
        XCTAssertFalse(copy.conversation.featureAccess.isAllowed("volume"), "Malformed backups must not change access")
        let invalidTimeout = Data(#"{"version":3,"excludedProviders":[],"automaticallyAllowNewPlugins":true,"approvedProviders":[],"idleTimeoutSeconds":0}"#.utf8)
        XCTAssertFalse(copy.restorePortablePreferencesReportingResult(from: invalidTimeout))
        XCTAssertFalse(copy.conversation.featureAccess.isAllowed("volume"))
        XCTAssertEqual(copy.conversation.idleTimeout, .fiveMinutes)
    }

    func testVoicePolicyControlsPreserveActiveGrantAndRequireApprovalToEnable() async throws {
        let storage = VoiceCredentialTestStorage()
        let context = PluginRuntimeContext(pluginID: "voice-control", storage: storage)
        var permission: CheckedContinuation<Bool, Never>?
        let model = VoiceConversation(context: context, audio: FeatureAccessNoAudio(),
            requestMicrophone: { await withCheckedContinuation { permission = $0 } }, secrets: VoiceCredentialTestSecrets())
        let plugin = VoiceControlPlugin(context: context, conversation: model)
        var available = providers
        plugin.voiceControlHostContext = .init(providers: { available }, begin: { _ in UUID() },
            end: { _ in }, request: { _, _ in .init() })
        let saved = await model.saveKey("sk-unit-test-fixture-not-a-real-key")
        XCTAssertTrue(saved)
        var backups = 0
        plugin.onPersistentPreferencesChange = { backups += 1 }
        model.start()
        defer { model.stop(); permission?.resume(returning: false) }
        for _ in 0..<100 where permission == nil { await Task.yield() }
        XCTAssertNotNil(permission)
        let original = Set(model.allowedProviders.map(\.id))
        let enable = try XCTUnwrap(plugin.actionDefinitions.first { $0.confirmation != nil })
        XCTAssertEqual(enable.risk, .confirmationRequired)
        let disable = try XCTUnwrap(plugin.actionDefinitions.first { $0.confirmation == nil })
        let handle = try plugin.beginAction(.init(reference: .init(key: disable.key), source: .test, mode: .foreground))
        guard case .succeeded = await handle.result() else { return XCTFail("Expected a saved policy change") }
        XCTAssertFalse(model.featureAccess.automaticallyAllowNewPlugins)
        XCTAssertTrue(model.active)
        available.append(.init(id: "later", title: "Later Plugin"))
        XCTAssertEqual(Set(model.allowedProviders.map(\.id)), original)
        XCTAssertFalse(model.featureAccess.isAllowed("later"))
        XCTAssertEqual(backups, 1)
        XCTAssertFalse(storage.bool(forKey: "automaticallyAllowNewPlugins"))
    }

    private func makePlugin(storage: VoiceCredentialTestStorage) -> VoiceControlPlugin {
        let plugin = VoiceControlPlugin(context: .init(pluginID: "voice-control", storage: storage))
        plugin.voiceControlHostContext = .init(providers: { [providers] in providers },
            begin: { _ in nil }, end: { _ in }, request: { _, _ in .init(status: "sessionEnded") })
        return plugin
    }
}

@MainActor
private final class FeatureAccessNoAudio: VoiceAudioIO {
    func start() throws -> AsyncThrowingStream<Data, Error> { XCTFail("No microphone capture expected"); throw VoiceFailure.audio }
    func play(_ data: Data) throws { XCTFail("No playback expected") }
    func stop() {}
}
