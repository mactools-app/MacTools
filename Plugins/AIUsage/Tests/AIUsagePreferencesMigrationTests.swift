import Foundation
import MacToolsPluginKit
import XCTest
@testable import AIUsagePlugin

/// Choices made in the earlier AI Usage plugin survive the new page: an agent turned off there
/// stays off, and a backup taken before the update still restores.
@MainActor
final class AIUsagePreferencesMigrationTests: XCTestCase {
    private final class Storage: PluginStorage {
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

    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        suite = "AIUsagePreferencesMigrationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func legacy(codex: Bool, claude: Bool) -> Data {
        let json = #"{"allowsCredentialAccess":true,"allowsClaudeKeychain":false,"codexEnabled":\#(codex),"claudeEnabled":\#(claude),"refreshInterval":300,"showsMenuBar":true}"#
        return Data(json.utf8)
    }

    func testEarlierProviderChoicesCarryOverOnce() {
        let storage = Storage()
        storage.set(legacy(codex: false, claude: true), forKey: AIUsagePreferencesBackup.legacyPreferencesKey)
        XCTAssertTrue(AIUsagePreferencesBackup.migrateLegacyPreferences(from: storage, to: defaults))
        let providers = AIUsagePreferencesBackup.current(in: defaults).providers
        XCTAssertEqual(providers["codex"], false)
        XCTAssertEqual(providers["claude"], true)
        // The earlier record stays for an older MacTools, and nothing is carried over twice.
        XCTAssertNotNil(storage.data(forKey: AIUsagePreferencesBackup.legacyPreferencesKey))
        defaults.set(true, forKey: NotchAgentSupport.key(for: .codex))
        XCTAssertFalse(AIUsagePreferencesBackup.migrateLegacyPreferences(from: storage, to: defaults))
        XCTAssertEqual(AIUsagePreferencesBackup.current(in: defaults).providers["codex"], true)
    }

    func testAChoiceAlreadyMadeOnThePageWins() {
        let storage = Storage()
        storage.set(legacy(codex: false, claude: false), forKey: AIUsagePreferencesBackup.legacyPreferencesKey)
        defaults.set(true, forKey: NotchAgentSupport.key(for: .codex))
        AIUsagePreferencesBackup.migrateLegacyPreferences(from: storage, to: defaults)
        let providers = AIUsagePreferencesBackup.current(in: defaults).providers
        XCTAssertEqual(providers["codex"], true)
        XCTAssertEqual(providers["claude"], false)
    }

    func testNoEarlierRecordChangesNothing() {
        let storage = Storage()
        XCTAssertFalse(AIUsagePreferencesBackup.migrateLegacyPreferences(from: storage, to: defaults))
        XCTAssertNil(defaults.object(forKey: NotchAgentSupport.key(for: .codex)))
    }

    func testEarlierBackupRestoresItsTwoProviders() throws {
        let current = AIUsagePreferencesBackup.current(in: defaults)
        let old = Data(#"{"formatVersion":1,"codexEnabled":false,"claudeEnabled":true,"refreshInterval":900,"showsMenuBar":true}"#.utf8)
        let restored = try XCTUnwrap(AIUsagePreferencesBackup.fromLegacy(old, onto: current))
        XCTAssertEqual(restored.providers["codex"], false)
        XCTAssertEqual(restored.providers["claude"], true)
        XCTAssertEqual(restored.period, current.period)
        // Not an earlier backup, or a later format: refused.
        XCTAssertNil(AIUsagePreferencesBackup.fromLegacy(Data(#"{"formatVersion":2,"codexEnabled":true,"claudeEnabled":true}"#.utf8), onto: current))
        XCTAssertNil(AIUsagePreferencesBackup.fromLegacy(Data("{}".utf8), onto: current))
    }
}
