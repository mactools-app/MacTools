import Foundation
import MacToolsPluginKit
import XCTest
@testable import VoiceControlPlugin

@MainActor
final class VoiceCredentialsTests: XCTestCase {
    private let userKey = "sk-user-fixture-not-an-actual-api-key"
    private let developmentKey = "sk-dev-fixture-not-an-actual-api-key"

    func testOwnKeyIsRequiredAndSavedOnlyInSecretStore() throws {
        let storage = VoiceCredentialTestStorage()
        let secrets = VoiceCredentialTestSecrets()
        let credentials = VoiceCredentialConfiguration(storage: storage, secrets: secrets, environment: [:])
        XCTAssertFalse(credentials.isConfigured)
        XCTAssertThrowsError(try credentials.load())
        try credentials.save("  \(userKey)\n")
        XCTAssertEqual(secrets.key, userKey)
        XCTAssertEqual(try credentials.load(), userKey)
        XCTAssertEqual(credentials.source, .keychain)
        XCTAssertFalse(storage.values.values.contains { ($0 as? String) == userKey })
        let reloaded = VoiceCredentialConfiguration(storage: storage, secrets: secrets, environment: [:])
        XCTAssertEqual(try reloaded.load(), userKey)
    }

    func testExplicitUserKeyNeverFallsBackToDevelopmentKey() throws {
        let storage = VoiceCredentialTestStorage()
        let secrets = VoiceCredentialTestSecrets()
        let environment = ["OPENAI_API_KEY": developmentKey]
        let credentials = VoiceCredentialConfiguration(storage: storage, secrets: secrets, environment: environment)
        #if DEBUG
        XCTAssertEqual(try credentials.load(), developmentKey)
        #else
        XCTAssertThrowsError(try credentials.load())
        #endif
        try credentials.save(userKey)
        XCTAssertEqual(try credentials.load(), userKey)
        secrets.key = nil
        XCTAssertThrowsError(try credentials.load())
        secrets.shouldFail = true
        XCTAssertThrowsError(try credentials.load())
        secrets.shouldFail = false
        try credentials.forget()
        XCTAssertFalse(credentials.isConfigured)
        XCTAssertThrowsError(try credentials.load())
        let reloaded = VoiceCredentialConfiguration(storage: storage, secrets: secrets, environment: environment)
        XCTAssertFalse(reloaded.isConfigured)
        XCTAssertThrowsError(try reloaded.load())
    }

    func testFailedSecretChangesPreservePreviousConfiguration() throws {
        let storage = VoiceCredentialTestStorage()
        let secrets = VoiceCredentialTestSecrets()
        let credentials = VoiceCredentialConfiguration(storage: storage, secrets: secrets, environment: [:])
        try credentials.save(userKey)
        XCTAssertThrowsError(try credentials.save("invalid"))
        XCTAssertEqual(try credentials.load(), userKey)
        secrets.shouldFail = true
        XCTAssertThrowsError(try credentials.save(developmentKey))
        XCTAssertThrowsError(try credentials.forget())
        XCTAssertEqual(credentials.source, .keychain)
        secrets.shouldFail = false
        XCTAssertEqual(try credentials.load(), userKey)
    }

    #if DEBUG
    func testChosenFileOverridesDevelopmentEnvironmentAndDoesNotImportKey() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(".env.local")
        try "OPENAI_API_KEY=\(userKey)\n".write(to: file, atomically: true, encoding: .utf8)
        let storage = VoiceCredentialTestStorage()
        storage.set(file.path, forKey: "credentialFile") // Existing prototype settings migrate without importing secrets.
        let secrets = VoiceCredentialTestSecrets()
        let credentials = VoiceCredentialConfiguration(storage: storage, secrets: secrets, environment: ["OPENAI_API_KEY": developmentKey])
        XCTAssertEqual(credentials.source, .file)
        XCTAssertEqual(try credentials.load(), userKey)
        let loaded = try await credentials.loadForConversation()
        XCTAssertEqual(loaded, userKey)
        XCTAssertNil(secrets.key)
        try credentials.forget()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertThrowsError(try credentials.load())
    }
    #endif
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

final class VoiceCredentialTestSecrets: VoiceSecretStoring {
    var key: String?
    var shouldFail = false
    private struct Failure: Error {}
    func load() throws -> String? { if shouldFail { throw Failure() }; return key }
    func save(_ key: String) throws { if shouldFail { throw Failure() }; self.key = key }
    func remove() throws { if shouldFail { throw Failure() }; key = nil }
}
