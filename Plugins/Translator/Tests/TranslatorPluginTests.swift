import Carbon
import MacToolsPluginKit
import XCTest
@testable import TranslatorPlugin

@MainActor
final class TranslatorPluginTests: XCTestCase {
    func testOmittedTextPreservesDestinationOnlyTemplateRegardlessOfExportOptIn() throws {
        let source = makePlugin()
        let payload = try XCTUnwrap(source.makePortablePreferencesBackup())
        for optedIn in [false, true] {
            let storage = TranslatorInMemoryPluginStorage()
            let destination = makePlugin(storage: storage)
            let original = TranslatorProviderProfile.defaultProfile()
            let draft = TranslatorProviderProfile(id: "private-draft", name: "Private draft", isEnabled: false,
                baseURL: "", model: "", promptTemplate: "Destination-only private {{text}}")
            XCTAssertNil(destination.saveConfiguration(profiles: [original, draft], apiKeys: [:],
                languagePair: .init(first: .english, second: .simplifiedChinese)))
            destination.handleSettingsAction(.setBoolean(controlID: "preferences-backup.include-prompt-text", value: optedIn))

            XCTAssertTrue(destination.restorePortablePreferencesReportingResult(from: payload))
            XCTAssertEqual(TranslatorProviderProfileStore(storage: storage).loadProfiles(), [original, draft])
            XCTAssertEqual(storage.bool(forKey: "preferences-backup.include-prompt-text"), optedIn)
        }
    }

    func testPortableRestoreRejectsInvalidEnabledMergedTemplateWithoutMutation() throws {
        let storage = TranslatorInMemoryPluginStorage()
        let secret = CountingTranslatorSecretStore(apiKey: "local-key")
        let destination = makePlugin(storage: storage, secretStore: secret)
        let active = TranslatorProviderProfile.defaultProfile()
        let draft = TranslatorProviderProfile(id: "draft", name: "Draft", isEnabled: false,
            promptTemplate: "Unfinished private template")
        XCTAssertNil(destination.saveConfiguration(profiles: [active, draft], apiKeys: [:],
            languagePair: .init(first: .english, second: .simplifiedChinese)))
        let before = storage.data(forKey: TranslatorConstants.StorageKey.providerProfiles)
        var enabled = draft
        enabled.isEnabled = true
        enabled.promptTemplate = "Translate {{text}}"
        let sourceStorage = TranslatorInMemoryPluginStorage()
        try TranslatorProviderProfileStore(storage: sourceStorage).saveProfiles([active, enabled])
        let source = makePlugin(storage: sourceStorage)
        let payload = try XCTUnwrap(source.makePortablePreferencesBackup())

        XCTAssertFalse(destination.restorePortablePreferencesReportingResult(from: payload))
        XCTAssertEqual(storage.data(forKey: TranslatorConstants.StorageKey.providerProfiles), before)
        XCTAssertEqual(secret.loadCount, 0)
        XCTAssertEqual(secret.saveCount, 0)

        enabled.isEnabled = false
        try TranslatorProviderProfileStore(storage: sourceStorage).saveProfiles([active, enabled])
        let disabledPayload = try XCTUnwrap(makePlugin(storage: sourceStorage).makePortablePreferencesBackup())
        XCTAssertTrue(destination.restorePortablePreferencesReportingResult(from: disabledPayload))
        XCTAssertEqual(TranslatorProviderProfileStore(storage: storage).loadProfiles().first { $0.id == draft.id }, draft)
    }

    func testExcludedLegacyPromptSizeDoesNotBlockPortableExport() throws {
        let storage = TranslatorInMemoryPluginStorage()
        var profile = TranslatorProviderProfile.defaultProfile()
        profile.promptTemplate = String(repeating: "x", count: 1_048_577) + " {{text}}"
        try TranslatorProviderProfileStore(storage: storage).saveProfiles([profile])
        let raw = storage.data(forKey: TranslatorConstants.StorageKey.providerProfiles)
        let plugin = makePlugin(storage: storage)

        let backup = try XCTUnwrap(plugin.makePortablePreferencesBackup())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: backup) as? [String: Any])
        let profiles = try XCTUnwrap(object["profiles"] as? [[String: Any]])
        XCTAssertTrue(profiles.allSatisfy { $0["promptTemplate"] == nil })
        XCTAssertEqual(storage.data(forKey: TranslatorConstants.StorageKey.providerProfiles), raw)
        plugin.handleSettingsAction(.setBoolean(controlID: "preferences-backup.include-prompt-text", value: true))
        XCTAssertNil(plugin.makePortablePreferencesBackup())
        plugin.handleSettingsAction(.setBoolean(controlID: "preferences-backup.include-prompt-text", value: false))

        storage.set(Data(), forKey: "preferences-backup.restore.v2")
        XCTAssertNil(plugin.makePortablePreferencesBackup())
        storage.removeObject(forKey: "preferences-backup.restore.v2")
        XCTAssertNotNil(plugin.makePortablePreferencesBackup())
        XCTAssertEqual(storage.data(forKey: TranslatorConstants.StorageKey.providerProfiles), raw)
    }


    func testPrimaryPanelReflectsPermissionAndSetupState() {
        XCTAssertEqual(
            makePlugin(accessibilityTrustProvider: { false }).rowState.subtitle,
            "启用前需要辅助功能授权"
        )

        let storage = TranslatorInMemoryPluginStorage()
        let plugin = makePlugin(storage: storage, secretStore: CountingTranslatorSecretStore(apiKey: nil))
        let message = plugin.saveConfiguration(
            OpenAICompatibleConfiguration(
                baseURL: "https://gateway.example.com",
                model: "gpt-test",
                promptTemplate: "{{text}}"
            ),
            apiKey: "",
            languagePair: TranslatorLanguagePair(first: .english, second: .simplifiedChinese)
        )

        XCTAssertEqual(message, "API Key 不能为空。")
        XCTAssertEqual(plugin.rowState.subtitle, "需要配置翻译服务")
    }

    func testSavingBlankAPIKeyPreservesExistingKey() {
        let secretStore = CountingTranslatorSecretStore(apiKey: "sk-existing")
        let plugin = makePlugin(secretStore: secretStore)

        let message = plugin.saveConfiguration(
            OpenAICompatibleConfiguration(
                baseURL: TranslatorProviderProfile.defaultProfile().baseURL,
                model: "gpt-test",
                promptTemplate: "{{text}}"
            ),
            apiKey: "",
            languagePair: TranslatorLanguagePair(first: .english, second: .simplifiedChinese)
        )

        XCTAssertNil(message)
        XCTAssertEqual(secretStore.saveCount, 0)
        XCTAssertEqual(plugin.rowState.subtitle, "按 ⌥D 划词，⌥S 截图")
    }

    func testCredentialUpgradePreservesActiveServiceBesideIncompleteDisabledDraft() throws {
        for endpoint in ["https://gateway.example/v1", "HTTPS://gateway.example/v1?api-version=2026-01-01"] {
            let storage = TranslatorInMemoryPluginStorage()
            let secret = CountingTranslatorSecretStore(apiKey: "existing-local-key")
            var active = TranslatorProviderProfile.defaultProfile()
            active.baseURL = endpoint
            let draft = TranslatorProviderProfile(id: "draft", name: "Draft", isEnabled: false, baseURL: "")
            let profiles = [active, draft]
            storage.set(try JSONEncoder().encode(profiles), forKey: TranslatorConstants.StorageKey.providerProfiles)
            let plugin = makePlugin(storage: storage, secretStore: secret)

            let grants = PortableCredentialAuthorization(storage: storage)
            XCTAssertTrue(grants.isInitialized)
            XCTAssertTrue(grants.allows(profileID: active.id, baseURL: endpoint))
            XCTAssertFalse(grants.allows(profileID: draft.id, baseURL: draft.baseURL))
            XCTAssertNil(plugin.saveConfiguration(profiles: profiles, apiKeys: [:],
                languagePair: .init(first: .english, second: .simplifiedChinese)))
            XCTAssertEqual(try JSONDecoder().decode([TranslatorProviderProfile].self,
                from: XCTUnwrap(storage.data(forKey: TranslatorConstants.StorageKey.providerProfiles))), profiles)
            XCTAssertEqual(secret.loadCount, 0)
            XCTAssertEqual(secret.saveCount, 0)
        }
    }

    func testSavedIncompleteDisabledDraftTransfersWithoutCredentialAccess() throws {
        let source = makePlugin()
        let active = TranslatorProviderProfile.defaultProfile()
        let draft = TranslatorProviderProfile(id: "draft", name: "", isEnabled: false, baseURL: "https://", model: "")
        XCTAssertNil(source.saveConfiguration(profiles: [active, draft], apiKeys: [:],
            languagePair: .init(first: .english, second: .simplifiedChinese)))
        let data = try XCTUnwrap(source.makePortablePreferencesBackup())
        let storage = TranslatorInMemoryPluginStorage()
        let secret = CountingTranslatorSecretStore(apiKey: "local-secret")
        let destination = makePlugin(storage: storage, secretStore: secret)
        XCTAssertTrue(destination.restorePortablePreferencesReportingResult(from: data))
        let saved = try XCTUnwrap(storage.data(forKey: TranslatorConstants.StorageKey.providerProfiles))
        let profiles = try JSONDecoder().decode([TranslatorProviderProfile].self, from: saved)
        XCTAssertEqual(profiles.first { $0.id == draft.id }, draft)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var incoming = try XCTUnwrap(object["profiles"] as? [[String: Any]])
        incoming[1]["isEnabled"] = true
        object["profiles"] = incoming
        XCTAssertFalse(destination.restorePortablePreferencesReportingResult(from: try JSONSerialization.data(withJSONObject: object)))
        incoming[1]["isEnabled"] = false
        incoming[1]["baseURL"] = "https://user:secret@gateway.example/v1"
        object["profiles"] = incoming
        XCTAssertFalse(destination.restorePortablePreferencesReportingResult(from: try JSONSerialization.data(withJSONObject: object)))
        XCTAssertEqual(storage.data(forKey: TranslatorConstants.StorageKey.providerProfiles), saved)
        XCTAssertEqual(secret.loadCount, 0)
        XCTAssertEqual(secret.saveCount, 0)
    }

    func testPrimaryPanelTogglePersistsDisabledStateAndNotifies() {
        let storage = TranslatorInMemoryPluginStorage()
        let plugin = makePlugin(storage: storage)
        var didNotify = false
        plugin.onStateChange = { didNotify = true }

        plugin.handleAction(.setSwitch(false))

        XCTAssertEqual(storage.bool(forKey: "translator.shortcut.enabled"), false)
        XCTAssertTrue(didNotify)
        XCTAssertFalse(plugin.rowState.isOn)
    }

    func testActionsReuseTranslationStartersAndMigrateLegacyBindings() async throws {
        var selectStartCount = 0
        let plugin = makePlugin(selectTranslationStarter: { selectStartCount += 1 })
        plugin.shortcutBindingResolver = { shortcutID in
            shortcutID == "translator.select-translation"
                ? ShortcutBinding(keyCode: UInt16(kVK_ANSI_D), modifiers: [.option])
                : nil
        }
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        let result = try await plugin.beginAction(
            ActionInvocation(reference: reference, source: .test, mode: .foreground)
        ).result()

        XCTAssertEqual(plugin.actionDefinitions.map(\.key.actionID), [
            "select-translation",
            "screenshot-translation",
        ])
        XCTAssertEqual(plugin.legacyActionShortcutAssignments.count, 1)
        XCTAssertEqual(
            plugin.legacyActionShortcutAssignments.first?.legacyShortcutDefinitionID,
            "translator.select-translation"
        )
        XCTAssertEqual(result, .succeeded())
        XCTAssertEqual(selectStartCount, 1)
    }

    func testImportedEndpointRemainsQuarantinedWithoutChangingLocalConsentOrKeys() throws {
        for endpoint in ["https://imported.example/v1", "http://10.0.0.10:8000/gateway/v1", "http://[fd12::1]:8000/v1"] {
            let storage = TranslatorInMemoryPluginStorage()
            let secret = CountingTranslatorSecretStore(apiKey: "local-secret")
            let plugin = makePlugin(storage: storage, secretStore: secret)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(plugin.makePortablePreferencesBackup())) as? [String: Any])
            var profiles = try XCTUnwrap(object["profiles"] as? [[String: Any]])
            profiles[0]["baseURL"] = endpoint
            object["profiles"] = profiles
            let incoming = try JSONSerialization.data(withJSONObject: object)
            XCTAssertTrue(plugin.restorePortablePreferencesReportingResult(from: incoming))
            XCTAssertTrue(plugin.restorePortablePreferencesReportingResult(from: incoming))
            XCTAssertNotNil(plugin.makePortablePreferencesBackup())
            let reloaded = makePlugin(storage: storage, secretStore: secret)
            let id = try XCTUnwrap(profiles[0]["id"] as? String)
            XCTAssertFalse(PortableCredentialAuthorization(storage: storage).allows(profileID: id, baseURL: endpoint))
            XCTAssertEqual(secret.loadCount, 0)
            XCTAssertEqual(secret.saveCount, 0)
            XCTAssertFalse(storage.bool(forKey: "preferences-backup.include-prompt-text"))
            XCTAssertNotNil(reloaded.saveConfiguration(OpenAICompatibleConfiguration(baseURL: endpoint, model: "test", promptTemplate: "{{text}}"), apiKey: "", languagePair: .init(first: .english, second: .simplifiedChinese)))
        }
    }

    func testFailedCredentialReplacementPreservesOnlyVerifiedUnchangedAccess() throws {
        for (changesKey, readFails) in [(false, false), (true, false), (false, true)] {
            let storage = TranslatorInMemoryPluginStorage()
            let secret = CountingTranslatorSecretStore(apiKey: "original-local-key")
            let plugin = makePlugin(storage: storage, secretStore: secret)
            let profile = TranslatorProviderProfile.defaultProfile()
            var edited = profile
            edited.baseURL = "https://changed.example/v1"
            secret.saveFailure = (changesKey, readFails)
            XCTAssertNotNil(plugin.saveConfiguration(profiles: [edited], apiKeys: [edited.id: "replacement-local-key"],
                languagePair: .init(first: .english, second: .simplifiedChinese)))
            let authorization = PortableCredentialAuthorization(storage: storage)
            let preservesAccess = !changesKey && !readFails
            XCTAssertEqual(authorization.allows(profileID: profile.id, baseURL: profile.baseURL), preservesAccess)
            XCTAssertFalse(authorization.allows(profileID: edited.id, baseURL: edited.baseURL))
            secret.saveFailure = nil
            let reloaded = makePlugin(storage: storage, secretStore: secret)
            XCTAssertEqual(TranslatorProviderProfileStore(storage: storage).loadProfiles(), [profile])
            XCTAssertEqual(reloaded.saveConfiguration(profiles: [profile], apiKeys: [:],
                languagePair: .init(first: .english, second: .simplifiedChinese)) == nil, preservesAccess)
        }
    }

    func testDisabledImportedProfileCannotAuthorizeUnsavedReplacementKey() throws {
        let storage = TranslatorInMemoryPluginStorage()
        let secret = CountingTranslatorSecretStore(apiKey: "existing-destination-secret")
        var local = TranslatorProviderProfile.defaultProfile()
        local.isEnabled = false
        let other = TranslatorProviderProfile(id: "other", name: "Other", baseURL: "https://other.example/v1")
        storage.set(try JSONEncoder().encode([local, other]), forKey: TranslatorConstants.StorageKey.providerProfiles)
        let plugin = makePlugin(storage: storage, secretStore: secret)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(plugin.makePortablePreferencesBackup())) as? [String: Any])
        var profiles = try XCTUnwrap(object["profiles"] as? [[String: Any]])
        local.baseURL = "https://imported.example/v1"
        profiles[0]["baseURL"] = local.baseURL
        object["profiles"] = profiles
        let incoming = try JSONSerialization.data(withJSONObject: object)
        XCTAssertTrue(plugin.restorePortablePreferencesReportingResult(from: incoming))

        XCTAssertNil(plugin.saveConfiguration(profiles: [local, other], apiKeys: [local.id: "replacement-key"],
            languagePair: .init(first: .english, second: .simplifiedChinese)))
        XCTAssertEqual(secret.saveCount, 0)
        XCTAssertFalse(PortableCredentialAuthorization(storage: storage).allows(profileID: local.id, baseURL: local.baseURL))

        let reopened = makePlugin(storage: storage, secretStore: secret)
        local.isEnabled = true
        XCTAssertNotNil(reopened.saveConfiguration(profiles: [local, other], apiKeys: [:],
            languagePair: .init(first: .english, second: .simplifiedChinese)))
        XCTAssertEqual(secret.loadCount, 0)
        XCTAssertEqual(secret.saveCount, 0)
        XCTAssertFalse(PortableCredentialAuthorization(storage: storage).allows(profileID: local.id, baseURL: local.baseURL))

        XCTAssertNil(reopened.saveConfiguration(profiles: [local, other], apiKeys: [local.id: "replacement-key"],
            languagePair: .init(first: .english, second: .simplifiedChinese)))
        XCTAssertEqual(secret.saveCount, 1)
        XCTAssertTrue(PortableCredentialAuthorization(storage: storage).allows(profileID: local.id, baseURL: local.baseURL))
    }

    func testCredentialValidationPrecedesAllProviderWrites() throws {
        for scenario in ["A-first-B-blank", "B-first-B-blank", "both-keys-present", "B-write-fails"] {
            let storage = TranslatorInMemoryPluginStorage()
            let profile = TranslatorProviderProfile.defaultProfile()
            let other = TranslatorProviderProfile(id: "other", name: "Other", baseURL: "https://other.example/v1")
            let secret = ValidationScopedTranslatorSecrets(legacy: nil, scoped: [profile.id: "original-local-key"])
            let plugin = makePlugin(storage: storage, secretStore: secret)
            XCTAssertNil(plugin.saveConfiguration(profiles: [profile], apiKeys: [:],
                languagePair: .init(first: .english, second: .simplifiedChinese)))
            let profiles = scenario == "B-first-B-blank" ? [other, profile] : [profile, other]
            var keys = [profile.id: "original-local-key"]
            if scenario == "both-keys-present" || scenario == "B-write-fails" { keys[other.id] = "other-key" }
            if scenario == "B-write-fails" { secret.rejectedProfileID = other.id }
            let error = plugin.saveConfiguration(profiles: profiles, apiKeys: keys,
                languagePair: .init(first: .english, second: .simplifiedChinese))
            let authorization = PortableCredentialAuthorization(storage: storage)
            let allowed = authorization.allows(profileID: profile.id, baseURL: profile.baseURL)
            XCTAssertEqual(error != nil, scenario != "both-keys-present")
            XCTAssertTrue(allowed)
            XCTAssertEqual(try secret.loadAPIKey(forProfileID: profile.id), "original-local-key")
            if error != nil { XCTAssertEqual(TranslatorProviderProfileStore(storage: storage).loadProfiles(), [profile]) }
            let reloaded = makePlugin(storage: storage, secretStore: secret)
            let retryError = reloaded.saveConfiguration(profiles: [profile], apiKeys: [:],
                languagePair: .init(first: .english, second: .simplifiedChinese))
            XCTAssertNil(retryError)

        }
    }

    func testFailedScopedReplacementVerifiesEffectiveLegacyKey() throws {
        for scenario in ["legacy-only-fail-before-write", "scoped-fail-before-write", "legacy-success", "legacy-partial-write-failure"] {
            let storage = TranslatorInMemoryPluginStorage()
            let profile = TranslatorProviderProfile.defaultProfile()
            let isScoped = scenario == "scoped-fail-before-write"
            let secret = ValidationScopedTranslatorSecrets(legacy: isScoped ? nil : "original-local-key",
                scoped: isScoped ? [profile.id:"original-local-key"] : [:])
            let plugin = makePlugin(storage: storage, secretStore: secret)
            XCTAssertNil(plugin.saveConfiguration(profiles: [profile], apiKeys: [:],
                languagePair: .init(first: .english, second: .simplifiedChinese)))
            secret.writeMode = scenario == "legacy-success" ? .success
                : scenario == "legacy-partial-write-failure" ? .writeThenFail : .failBeforeWrite
            let error = plugin.saveConfiguration(profiles: [profile], apiKeys: [profile.id:"replacement-local-key"],
                languagePair: .init(first: .english, second: .simplifiedChinese))
            let allowed = PortableCredentialAuthorization(storage: storage).allows(profileID: profile.id, baseURL: profile.baseURL)
            XCTAssertEqual(error != nil, scenario != "legacy-success")
            XCTAssertEqual(allowed, scenario != "legacy-partial-write-failure")
            if !isScoped { XCTAssertEqual(try secret.loadAPIKey(), "original-local-key") }
            if scenario == "legacy-only-fail-before-write" { XCTAssertNil(try secret.loadAPIKey(forProfileID: profile.id)) }
            let reloaded = makePlugin(storage: storage, secretStore: secret)
            let retryError = reloaded.saveConfiguration(profiles: [profile], apiKeys: [:],
                languagePair: .init(first: .english, second: .simplifiedChinese))
            XCTAssertEqual(retryError != nil, !allowed)

        }
    }

    private func makePlugin(
        storage: TranslatorInMemoryPluginStorage? = nil,
        accessibilityTrustProvider: @escaping () -> Bool = { true },
        secretStore: (any TranslatorSecretStoring)? = nil,
        selectTranslationStarter: (() -> Void)? = nil
    ) -> TranslatorPlugin {
        let storage = storage ?? TranslatorInMemoryPluginStorage()
        return TranslatorPlugin(
            context: PluginRuntimeContext(pluginID: "translator", storage: storage),
            accessibilityTrustProvider: accessibilityTrustProvider,
            accessibilityTrustRequester: { _ in true },
            screenRecordingPermissionProvider: { true },
            selectTranslationStarter: selectTranslationStarter,
            secretStore: secretStore ?? CountingTranslatorSecretStore(apiKey: "sk-test"),
            panelController: RecordingTranslatorPanelController(),
            selectedTextCapturePipeline: SelectedTextCapturePipeline(strategies: [])
        )
    }
}

private final class CountingTranslatorSecretStore: TranslatorSecretStoring, @unchecked Sendable {
    private var apiKey: String?
    private(set) var saveCount = 0
    private(set) var loadCount = 0
    var saveFailure: (changesKey: Bool, readFails: Bool)?

    init(apiKey: String?) {
        self.apiKey = apiKey
    }

    func containsAPIKey() throws -> Bool {
        apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    func containsAPIKey(forProfileID _: String) throws -> Bool {
        try containsAPIKey()
    }

    func loadAPIKey() throws -> String? {
        loadCount += 1
        if saveCount > 0, saveFailure?.readFails == true { throw CocoaError(.fileReadUnknown) }
        return apiKey
    }

    func loadAPIKey(forProfileID _: String) throws -> String? {
        loadCount += 1
        if saveCount > 0, saveFailure?.readFails == true { throw CocoaError(.fileReadUnknown) }
        return apiKey
    }

    func saveAPIKey(_ apiKey: String) throws {
        saveCount += 1
        if let saveFailure {
            if saveFailure.changesKey { self.apiKey = apiKey }
            throw CocoaError(.fileWriteUnknown)
        }
        self.apiKey = apiKey
    }

    func saveAPIKey(_ apiKey: String, forProfileID _: String) throws {
        try saveAPIKey(apiKey)
    }

    func deleteAPIKey() throws {
        apiKey = nil
    }

    func deleteAPIKey(forProfileID _: String) throws {
        try deleteAPIKey()
    }
}

@MainActor
private final class RecordingTranslatorPanelController: TranslatorPanelControlling {
    var onAction: ((TranslatorPanelAction) -> Void)?

    func show(snapshot _: TranslatorPanelSnapshot) {}
    func update(snapshot _: TranslatorPanelSnapshot) {}
    func close() {}
}

private final class ValidationScopedTranslatorSecrets: TranslatorSecretStoring, @unchecked Sendable {
    enum WriteMode { case success, failBeforeWrite, writeThenFail }
    private var legacy: String?
    private var scoped: [String: String]
    var rejectedProfileID: String?
    var writeMode = WriteMode.success
    private(set) var scopedWriteCount = 0
    init(legacy: String?, scoped: [String: String]) { self.legacy = legacy; self.scoped = scoped }
    func containsAPIKey() throws -> Bool { legacy != nil }
    func containsAPIKey(forProfileID profileID: String) throws -> Bool { scoped[profileID] != nil }
    func loadAPIKey() throws -> String? { legacy }
    func loadAPIKey(forProfileID profileID: String) throws -> String? { scoped[profileID] }
    func saveAPIKey(_ apiKey: String) throws { legacy = apiKey }
    func saveAPIKey(_ apiKey: String, forProfileID profileID: String) throws {
        scopedWriteCount += 1
        if profileID == rejectedProfileID || writeMode == .failBeforeWrite { throw CocoaError(.fileWriteUnknown) }
        scoped[profileID] = apiKey
        if writeMode == .writeThenFail { throw CocoaError(.fileWriteUnknown) }
    }
    func deleteAPIKey() throws { legacy = nil }
    func deleteAPIKey(forProfileID profileID: String) throws { scoped.removeValue(forKey: profileID) }
}
