import Foundation
import MacToolsPluginKit
import XCTest
@testable import VoiceControlPlugin

@MainActor
final class VoiceCredentialsTests: XCTestCase {
    private let userKey = "sk-user-fixture-not-an-actual-api-key"
    private let developmentKey = "sk-dev-fixture-not-an-actual-api-key"

    func testOwnKeyIsRequiredAndSavedOnlyInSecretStore() async throws {
        let storage = VoiceCredentialTestStorage()
        let secrets = VoiceCredentialTestSecrets()
        let credentials = VoiceCredentialConfiguration(storage: storage, secrets: secrets)
        XCTAssertFalse(credentials.isConfigured)
        await assertUnreadable(credentials)
        try await credentials.save("  \(userKey)\n")
        XCTAssertEqual(secrets.key, userKey)
        try await assertKey(credentials, equals: userKey)
        XCTAssertEqual(credentials.source, .keychain)
        XCTAssertFalse(storage.values.values.contains { ($0 as? String) == userKey })
        let reloaded = VoiceCredentialConfiguration(storage: storage, secrets: secrets)
        try await assertKey(reloaded, equals: userKey)
    }

    func testMissingOrRemovedUserKeyNeverFallsBack() async throws {
        let storage = VoiceCredentialTestStorage()
        let secrets = VoiceCredentialTestSecrets()
        let credentials = VoiceCredentialConfiguration(storage: storage, secrets: secrets)
        await assertUnreadable(credentials)
        try await credentials.save(userKey)
        try await assertKey(credentials, equals: userKey)
        secrets.key = nil
        await assertUnreadable(credentials)
        secrets.shouldFail = true
        await assertUnreadable(credentials)
        secrets.shouldFail = false
        try await credentials.forget()
        XCTAssertFalse(credentials.isConfigured)
        await assertUnreadable(credentials)
        let reloaded = VoiceCredentialConfiguration(storage: storage, secrets: secrets)
        XCTAssertFalse(reloaded.isConfigured)
        await assertUnreadable(reloaded)
    }

    func testFailedSecretChangesPreservePreviousConfiguration() async throws {
        let storage = VoiceCredentialTestStorage()
        let secrets = VoiceCredentialTestSecrets()
        let credentials = VoiceCredentialConfiguration(storage: storage, secrets: secrets)
        try await credentials.save(userKey)
        do { try await credentials.save("invalid"); XCTFail("Invalid keys must be rejected") } catch {}
        try await assertKey(credentials, equals: userKey)
        secrets.shouldFail = true
        do { try await credentials.save(developmentKey); XCTFail("A rejected write must fail") } catch {}
        do { try await credentials.forget(); XCTFail("A rejected delete must fail") } catch {}
        XCTAssertEqual(credentials.source, .keychain)
        secrets.shouldFail = false
        try await assertKey(credentials, equals: userKey)
    }

    private func assertKey(_ credentials: VoiceCredentialConfiguration, equals expected: String) async throws {
        let key = try await credentials.loadForConversation()
        XCTAssertEqual(key, expected)
    }
    private func assertUnreadable(_ credentials: VoiceCredentialConfiguration) async {
        do { _ = try await credentials.loadForConversation(); XCTFail("No credential may be returned") } catch {}
    }

    func testLegacyFileReferenceIsRemovedWithoutLoadingOrImporting() async throws {
        let storage = VoiceCredentialTestStorage()
        storage.set("/unread-prototype-key-file", forKey: "credentialFile")
        storage.set("file", forKey: "credentialSource")
        let secrets = VoiceCredentialTestSecrets()
        let credentials = VoiceCredentialConfiguration(storage: storage, secrets: secrets)
        XCTAssertFalse(credentials.isConfigured)
        XCTAssertEqual(credentials.source, .none)
        XCTAssertNil(storage.object(forKey: "credentialFile"))
        XCTAssertNil(secrets.key)
        await assertUnreadable(credentials)
    }

}

@MainActor final class VoiceCredentialTestStorage: PluginStorage {
    var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values[key] = nil }
    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {}
}

final class VoiceCredentialTestSecrets: VoiceSecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storedKey: String?
    private var failing = false
    var key: String? { get { lock.withLock { storedKey } } set { lock.withLock { storedKey = newValue } } }
    var shouldFail: Bool { get { lock.withLock { failing } } set { lock.withLock { failing = newValue } } }
    private struct Failure: Error {}
    func load() throws -> String? { XCTAssertFalse(Thread.isMainThread); if shouldFail { throw Failure() }; return key }
    func save(_ key: String) throws { XCTAssertFalse(Thread.isMainThread); if shouldFail { throw Failure() }; self.key = key }
    func remove() throws { XCTAssertFalse(Thread.isMainThread); if shouldFail { throw Failure() }; key = nil }
}
