import Foundation
import MacToolsPluginKit
import XCTest
@testable import QuitProtectionPlugin

@MainActor
final class QuitProtectionPreferencesTests: XCTestCase {
    func testBackupRestoresSettingsWhileKeepingTheLocalActivation() throws {
        let source = try configuredSource()
        let backup = try XCTUnwrap(source.makePortablePreferencesBackup())
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: backup) as? [String: Any])
        XCTAssertNil(payload["isEnabled"])

        for isEnabled in [false, true] {
            var local = StoredSettings()
            local.isEnabled = isEnabled
            local.quit.isEnabled = isEnabled
            let storage = try TestStorage(local)
            let plugin = makePlugin(storage)
            var changes = 0
            plugin.onPersistentPreferencesChange = { changes += 1 }

            XCTAssertTrue(plugin.restorePortablePreferencesReportingResult(from: backup))
            let restored = try storage.readSettings()
            XCTAssertEqual(restored.isEnabled, isEnabled)
            XCTAssertEqual(restored.quit.isEnabled, isEnabled)
            XCTAssertFalse(restored.showsFeedback)
            XCTAssertEqual(restored.quit.confirmation, .doublePress(.milliseconds(1_200)))
            XCTAssertEqual(restored.quit.voiceOverDoublePressInterval, .milliseconds(3_400))
            XCTAssertEqual(restored.quit.scope, .allExcept)
            XCTAssertEqual(restored.quit.selectedApps, ["com.parallels.toolbox"])
            XCTAssertEqual(restored.quit.excludedApps, ["com.example.Editor"])
            XCTAssertEqual(changes, 1)

            XCTAssertTrue(plugin.restorePortablePreferencesReportingResult(from: backup))
            plugin.handleSettingsAction(.setBoolean(controlID: "master.enabled", value: !isEnabled))
            XCTAssertEqual(changes, 1)
            plugin.handleSettingsAction(.setSelection(controlID: "quit.mode", optionID: "hold"))
            XCTAssertEqual(changes, 2)
        }
    }

    func testInvalidAndUnwritableBackupsPreserveThePreviousSettings() throws {
        let backup = try XCTUnwrap(configuredSource().makePortablePreferencesBackup())
        let storage = try TestStorage(StoredSettings())
        let plugin = makePlugin(storage)
        let previous = storage.data(forKey: "settings")
        var changes = 0
        plugin.onPersistentPreferencesChange = { changes += 1 }

        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: backup) as? [String: Any])
        var appScope = try XCTUnwrap(payload["appScope"] as? [String: Any])
        appScope["selectedApps"] = ["/Applications/Editor.app"]
        payload["appScope"] = appScope
        let invalid = try JSONSerialization.data(withJSONObject: payload)
        XCTAssertFalse(plugin.restorePortablePreferencesReportingResult(from: invalid))

        storage.rejectWrites = true
        XCTAssertFalse(plugin.restorePortablePreferencesReportingResult(from: backup))
        XCTAssertEqual(storage.data(forKey: "settings"), previous)
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(try storage.readSettings().quit.confirmation, .hold(.milliseconds(800)))
    }

    func testAddingAppsRejectsUnsupportedIdentifiersAndListOverflow() throws {
        var local = StoredSettings()
        local.quit.selectedApps = Set((1...512).map { "com.example.App\($0)" })
        let storage = try TestStorage(local)
        let plugin = makePlugin(storage)
        let previous = storage.data(forKey: "settings")

        plugin.addApps(["com.example.App513"], to: .selected)
        plugin.addApps(["com.example.Local Tool"], to: .allExcept)
        XCTAssertEqual(storage.data(forKey: "settings"), previous)
        XCTAssertNotNil(plugin.makePortablePreferencesBackup())

        plugin.handleSettingsAction(.invoke(controlID: "quit.remove.com.example.App512"))
        plugin.addApps(["com.example.App513"], to: .selected)
        let saved = try storage.readSettings().quit.selectedApps
        XCTAssertEqual(saved.count, 512)
        XCTAssertTrue(saved.contains("com.example.App513"))
        XCTAssertNotNil(plugin.makePortablePreferencesBackup())
    }

    func testLegacyListsStayLocalWhileOtherSettingsTransfer() throws {
        let regularBackup = try XCTUnwrap(configuredSource().makePortablePreferencesBackup())
        for legacyIDs in [Set(["com.example.Local Tool"]), Set((1...513).map { "com.example.App\($0)" })] {
            var legacy = StoredSettings()
            legacy.quit.excludedApps = legacyIDs
            legacy.quit.confirmation = .hold(.milliseconds(1_400))
            let legacyStorage = try TestStorage(legacy)
            let legacyPlugin = makePlugin(legacyStorage)
            let backup = try XCTUnwrap(legacyPlugin.makePortablePreferencesBackup())
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: backup) as? [String: Any])
            XCTAssertNil(payload["appScope"])

            var destination = StoredSettings()
            destination.quit.scope = .allExcept
            destination.quit.excludedApps = ["com.example.Editor"]
            let storage = try TestStorage(destination)
            XCTAssertTrue(makePlugin(storage).restorePortablePreferencesReportingResult(from: backup))
            let restored = try storage.readSettings().quit
            XCTAssertEqual(restored.confirmation, .hold(.milliseconds(1_400)))
            XCTAssertEqual(restored.scope, .allExcept)
            XCTAssertEqual(restored.excludedApps, destination.quit.excludedApps)

            XCTAssertTrue(legacyPlugin.restorePortablePreferencesReportingResult(from: regularBackup))
            let retained = try legacyStorage.readSettings().quit
            XCTAssertEqual(retained.confirmation, .doublePress(.milliseconds(1_200)))
            XCTAssertEqual(retained.scope, .selected)
            XCTAssertEqual(retained.excludedApps, legacyIDs)
        }
    }

    func testUnreadableLocalSettingsArePreservedOnImport() throws {
        let backup = try XCTUnwrap(configuredSource().makePortablePreferencesBackup())
        let raw = Data(#"{"isEnabled":true,"showsFeedback":true,"quit":{"isEnabled":true,"scope":"selected","selectedApps":[],"excludedApps":[],"confirmation":{"futureMode":{}}}}"#.utf8)
        let storage = TestStorage(rawSettings: raw)
        let plugin = makePlugin(storage)
        XCTAssertNil(plugin.makePortablePreferencesBackup())
        XCTAssertFalse(plugin.restorePortablePreferencesReportingResult(from: backup))
        XCTAssertEqual(storage.data(forKey: "settings"), raw)
    }

    private func configuredSource() throws -> QuitProtectionPlugin {
        var settings = StoredSettings()
        settings.isEnabled = true
        settings.showsFeedback = false
        settings.quit.isEnabled = true
        settings.quit.confirmation = .doublePress(.milliseconds(1_200))
        settings.quit.voiceOverDoublePressInterval = .milliseconds(3_400)
        settings.quit.scope = .allExcept
        settings.quit.selectedApps = ["com.parallels.toolbox"]
        settings.quit.excludedApps = ["com.example.Editor"]
        return makePlugin(try TestStorage(settings))
    }

    private func makePlugin(_ storage: TestStorage) -> QuitProtectionPlugin {
        QuitProtectionPlugin(context: PluginRuntimeContext(pluginID: "quit-protection", storage: storage))
    }

    private struct StoredSettings: Codable {
        var isEnabled = false
        var showsFeedback = true
        var quit = QuitProtectionRule()
    }

    private final class TestStorage: PluginStorage {
        private var values: [String: Any]
        var rejectWrites = false

        init(_ settings: StoredSettings) throws {
            values = ["settings": try JSONEncoder().encode(settings)]
        }

        init(rawSettings: Data) {
            values = ["settings": rawSettings]
        }

        func readSettings() throws -> StoredSettings {
            try JSONDecoder().decode(StoredSettings.self, from: XCTUnwrap(data(forKey: "settings")))
        }

        func object(forKey key: String) -> Any? { values[key] }
        func data(forKey key: String) -> Data? { values[key] as? Data }
        func string(forKey key: String) -> String? { values[key] as? String }
        func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
        func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
        func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
        func set(_ value: Any?, forKey key: String) {
            if !rejectWrites { values[key] = value }
        }
        func removeObject(forKey key: String) { values.removeValue(forKey: key) }
        func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {}
    }
}
