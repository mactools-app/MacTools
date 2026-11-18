import Foundation
import MacToolsPluginKit
import XCTest
@testable import ClipboardHistoryPlugin

@MainActor
final class ClipboardHistorySettingsStoreTests: XCTestCase {
    private let deferralKey = "retention-restoration-deferred.v1"

    func testRememberPreferenceTransfersWithoutLocalFilterSnapshotAndRejectsFailedWrite() throws {
        let source = ClipboardHistorySettingsStore(storage: RetentionSettingsStorage())
        source.setRemembersPanelFilters(true, current: .init(scope: .history, type: .image))
        let storage = RetentionSettingsStorage()
        let destination = ClipboardHistorySettingsStore(storage: storage)
        XCTAssertTrue(destination.restorePortableBackup(try XCTUnwrap(source.portableBackup())))
        XCTAssertTrue(destination.remembersPanelFilters)
        XCTAssertEqual(destination.openingPanelFilters, .defaults)
        storage.blockedKeys = ["remember-panel-filters"]
        destination.setRemembersPanelFilters(false, current: .defaults)
        XCTAssertTrue(destination.remembersPanelFilters)
        XCTAssertTrue(ClipboardHistorySettingsStore(storage: storage).remembersPanelFilters)
    }

    func testPanelPreviewPreferencePersistsRestoresAndRollsBackFailedWrites() throws {
        let storage = RetentionSettingsStorage()
        let settings = ClipboardHistorySettingsStore(storage: storage)
        XCTAssertTrue(settings.showsPanelPreview)
        settings.showsPanelPreview = false
        XCTAssertFalse(ClipboardHistorySettingsStore(storage: storage).showsPanelPreview)
        let destination = ClipboardHistorySettingsStore(storage: RetentionSettingsStorage())
        XCTAssertTrue(destination.restorePortableBackup(try XCTUnwrap(settings.portableBackup())))
        XCTAssertFalse(destination.showsPanelPreview)

        storage.blockedKeys = ["history-panel-show-preview"]
        settings.showsPanelPreview = true
        XCTAssertFalse(settings.showsPanelPreview)
        XCTAssertFalse(ClipboardHistorySettingsStore(storage: storage).showsPanelPreview)
        storage.blockedKeys = []
        settings.showsPanelPreview = true
        XCTAssertTrue(ClipboardHistorySettingsStore(storage: storage).showsPanelPreview)
    }

    func testPortableRetentionDeferralIsDurableAndNeverTransfers() throws {
        let source = ClipboardHistorySettingsStore(storage: RetentionSettingsStorage())
        source.expiration = .oneDay
        let storage = RetentionSettingsStorage()
        storage.set(0, forKey: "expiration-days")
        let destination = ClipboardHistorySettingsStore(storage: storage)
        XCTAssertTrue(destination.restorePortableBackup(try XCTUnwrap(source.portableBackup())))
        XCTAssertTrue(ClipboardHistorySettingsStore(storage: storage).isRetentionDeferred)
        let backup = try XCTUnwrap(destination.portableBackup())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: backup) as? [String: Any])
        var values = try XCTUnwrap(object["values"] as? [String: Any])
        XCTAssertNil(values[deferralKey])
        values[deferralKey] = try XCTUnwrap(values["sequential-hud-hide-preview"])
        object["values"] = values
        XCTAssertFalse(destination.restorePortableBackup(try JSONSerialization.data(withJSONObject: object)))
        destination.expiration = .sevenDays
        XCTAssertFalse(ClipboardHistorySettingsStore(storage: storage).isRetentionDeferred)
    }

    func testFailedDeferralWriteRollsBackImportedRetention() throws {
        let source = ClipboardHistorySettingsStore(storage: RetentionSettingsStorage())
        source.expiration = .oneDay
        let storage = RetentionSettingsStorage()
        storage.set(0, forKey: "expiration-days")
        let destination = ClipboardHistorySettingsStore(storage: storage)
        let previous = destination.expiration
        storage.blockedKeys = [deferralKey]
        XCTAssertFalse(destination.restorePortableBackup(try XCTUnwrap(source.portableBackup())))
        XCTAssertEqual(destination.expiration, previous)
        XCTAssertEqual(ClipboardHistorySettingsStore(storage: storage).expiration, previous)
    }

    func testFailedResumeAndPendingRecoveryKeepRetentionDeferred() throws {
        let source = ClipboardHistorySettingsStore(storage: RetentionSettingsStorage())
        source.expiration = .oneDay
        let storage = RetentionSettingsStorage()
        storage.set(0, forKey: "expiration-days")
        let destination = ClipboardHistorySettingsStore(storage: storage)
        XCTAssertTrue(destination.restorePortableBackup(try XCTUnwrap(source.portableBackup())))
        storage.blockedKeys = [deferralKey]
        XCTAssertFalse(destination.setRetentionDeferred(false))
        destination.expiration = .sevenDays
        XCTAssertEqual(destination.expiration, .oneDay)
        XCTAssertTrue(ClipboardHistorySettingsStore(storage: storage).isRetentionDeferred)
        storage.set(Data(), forKey: "preferences-backup.restore.v2")
        XCTAssertTrue(ClipboardHistorySettingsStore(storage: storage).isRetentionDeferred)
    }
}

@MainActor
private final class RetentionSettingsStorage: PluginStorage {
    private var values: [String: Any] = [:]
    var blockedKeys: Set<String> = []
    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) { if !blockedKeys.contains(key) { values[key] = value } }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {}
}
