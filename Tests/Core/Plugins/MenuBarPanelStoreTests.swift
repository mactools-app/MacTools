import MacToolsPluginKit
import XCTest
@testable import MacTools

@MainActor
final class MenuBarPanelStoreTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var store: MenuBarPanelStore!

    override func setUp() {
        super.setUp()
        suite = "MenuBarPanelStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        store = MenuBarPanelStore(userDefaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        store = nil
        defaults = nil
        super.tearDown()
    }

    private func key(_ plugin: String = "example", _ item: String = "control") -> PluginPanelItemKey {
        PluginPanelItemKey(pluginID: plugin, itemID: item)
    }

    func testMigrationRetiresLegacyStoreOnlyAfterBothNewStoresAreWritten() throws {
        let data = Data(#"{"version":1,"orderedPluginIDs":["example"],"hiddenPluginIDs":["example"]}"#.utf8)
        defaults.set(data, forKey: MenuBarPanelStore.legacyDisplayStorageKey)
        let migrated = MenuBarPanelStore(userDefaults: defaults)
        XCTAssertNil(migrated.loadError)
        XCTAssertNotNil(defaults.data(forKey: MenuBarPanelStore.storageKey))
        XCTAssertEqual(defaults.stringArray(forKey: PluginOrderingStore.storageKey), ["example"])
        XCTAssertNil(defaults.object(forKey: MenuBarPanelStore.legacyDisplayStorageKey))
        XCTAssertEqual(migrated.configuration.legacySeed?.dashboardHidden, ["example"])
    }

    func testInitialPlacementIsAppliedOnceIncludingLibraryOnlyItems() throws {
        let row = key()
        let widget = key("example", "widget")
        XCTAssertTrue(store.reconcile([(row, .featurePanel), (widget, nil)]))
        let placement = try XCTUnwrap(store.configuration.placementsByPanelID["features"]?.first)
        XCTAssertEqual(placement.item, row)
        XCTAssertEqual(store.configuration.initializedItems, [row, widget])
        store.removePlacement(id: placement.id)
        XCTAssertFalse(store.reconcile([(row, .dashboard), (widget, .dashboard)]))
        XCTAssertTrue(store.configuration.placementsByPanelID.values.flatMap { $0 }.isEmpty)
        let reloaded = MenuBarPanelStore(userDefaults: defaults)
        XCTAssertFalse(reloaded.reconcile([(row, .featurePanel), (widget, .dashboard)]))
        XCTAssertEqual(reloaded.configuration.initializedItems, [row, widget])
    }

    func testManualAdditionAcknowledgesDefaultAndCopiesHaveIndependentIDs() throws {
        let first = try XCTUnwrap(store.addItem(key(), to: "components"))
        let second = try XCTUnwrap(store.addItem(key(), to: "components"))
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertFalse(store.reconcile([(key(), .featurePanel)]))
        store.movePlacement(id: first.id, to: "features", visibleOrder: [first.id])
        XCTAssertEqual(store.configuration.panelID(for: first.id), "features")
        XCTAssertEqual(store.configuration.panelID(for: second.id), "components")
        store.removePlacement(id: first.id)
        XCTAssertEqual(store.configuration.placementsByPanelID["components"], [second])
    }

    func testReorderPreservesUnavailableSlotsAcrossRelaunch() throws {
        let first = try XCTUnwrap(store.addItem(key("first"), to: "features"))
        let missing = try XCTUnwrap(store.addItem(key("missing"), to: "features"))
        let last = try XCTUnwrap(store.addItem(key("last"), to: "features"))
        store.setOrder([last.id, first.id], panelID: "features")
        let reloaded = MenuBarPanelStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.configuration.placementsByPanelID["features"], [last, missing, first])
    }

    func testDeletingCustomPanelPreservesEveryPlacementAndSelectionFallsBack() throws {
        let panel = try XCTUnwrap(store.addPanel())
        let row = try XCTUnwrap(store.addItem(key(), to: panel))
        let missing = try XCTUnwrap(store.addItem(key("missing", "widget"), to: panel))
        store.rememberSelection(id: panel)
        store.deletePanel(id: panel)
        XCTAssertEqual(store.configuration.placementsByPanelID["components"], [row, missing])
        XCTAssertEqual(store.lastSelectedPanelID, "components")
        store.deletePanel(id: "components")
        XCTAssertTrue(store.configuration.panels.contains { $0.id == "components" })
    }

    func testFutureAndCorruptPayloadsArePreservedUntilExplicitReset() throws {
        for data in [Data(#"{"version":99,"panels":[]}"#.utf8), Data("not JSON".utf8)] {
            defaults.set(data, forKey: MenuBarPanelStore.storageKey)
            let unreadable = MenuBarPanelStore(userDefaults: defaults)
            XCTAssertNotNil(unreadable.loadError)
            XCTAssertFalse(unreadable.reconcile([(key(), .featurePanel)]))
            XCTAssertNil(unreadable.addPanel())
            XCTAssertEqual(defaults.data(forKey: MenuBarPanelStore.storageKey), data)
            XCTAssertTrue(unreadable.replace(MenuBarPanelConfiguration(), replacingUnreadable: true))
            XCTAssertNil(unreadable.loadError)
        }
    }

    func testMigrationPreservesMixedOrderCopiesAndMissingPlugins() throws {
        let copyID = UUID()
        let legacy: [String: Any] = [
            "version": 2,
            "panels": [
                ["id": "components", "name": "", "systemImage": "square.grid.2x2", "isHidden": false],
                ["id": "features", "name": "", "systemImage": "switch.2", "isHidden": false],
                ["id": "custom", "name": "Custom", "systemImage": "star", "isHidden": false],
            ],
            "assignments": ["dashboard:missing": "custom", "featurePanel:row": "custom",
                            "instance:\(copyID.uuidString)": "custom"],
            "orders": ["custom": ["featurePanel:row", "dashboard:missing", "instance:\(copyID.uuidString)"]],
            "instances": [["pluginID": "missing", "surface": "dashboard", "instanceID": copyID.uuidString]],
            "removedDefaultEntries": ["featurePanel:removed"],
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: MenuBarPanelStore.storageKey)
        let migrated = MenuBarPanelStore(userDefaults: defaults)
        let placements = try XCTUnwrap(migrated.configuration.placementsByPanelID["custom"])
        XCTAssertEqual(placements.map(\.item), [key("row"), key("missing", "widget"), key("missing", "widget")])
        XCTAssertEqual(placements.last?.id, copyID)
        XCTAssertTrue(migrated.configuration.initializedItems.contains(key("removed")))
        XCTAssertFalse(migrated.reconcile([(key("removed"), .featurePanel)]))
        XCTAssertEqual(MenuBarPanelStore(userDefaults: defaults).configuration, migrated.configuration)
    }

    func testVersionThreeMigratesAndAdaptivePreferencesSurviveMissingPluginsAndMoves() throws {
        var original = MenuBarPanelConfiguration()
        let placement = MenuBarPanelPlacement(item: key("missing"))
        original.placementsByPanelID["features"] = [placement]
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object["version"] = 3
        object.removeValue(forKey: "preferredWidth")
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: MenuBarPanelStore.storageKey)
        let migrated = MenuBarPanelStore(userDefaults: defaults)
        XCTAssertNil(migrated.loadError)
        XCTAssertEqual(migrated.configuration.preferredWidth, 316)
        XCTAssertEqual(migrated.configuration.placementsByPanelID["features"], [placement])
        var adaptive = migrated.configuration
        adaptive.preferredWidth = 1600
        adaptive.placementsByPanelID["features"]?[0].presentation = "future-presentation"
        adaptive.placementsByPanelID["features"]?[0].width = .custom(720)
        XCTAssertTrue(migrated.replace(adaptive))
        migrated.movePlacement(id: placement.id, to: "components", visibleOrder: [placement.id])
        let reloaded = MenuBarPanelStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.configuration.preferredWidth, 1600)
        XCTAssertEqual(reloaded.configuration.placementsByPanelID["components"]?.first?.presentation, "future-presentation")
        XCTAssertEqual(reloaded.configuration.placementsByPanelID["components"]?.first?.id, placement.id)
        XCTAssertEqual(reloaded.configuration.placementsByPanelID["components"]?.first?.width, .custom(720))
        var invalid = reloaded.configuration
        invalid.preferredWidth = .infinity
        invalid.placementsByPanelID["components"]?[0].width = .custom(.infinity)
        XCTAssertTrue(reloaded.replace(invalid))
        XCTAssertEqual(reloaded.configuration.preferredWidth, 316)
        XCTAssertNil(reloaded.configuration.placementsByPanelID["components"]?.first?.width)
    }

    func testNewBackupEncodesOnlyCanonicalLayoutAndManagementOrder() throws {
        store.reconcile([(key(), .featurePanel)])
        let backup = PluginDisplayPreferencesBackup(orderedPluginIDs: ["example"], hiddenPluginIDs: [],
                                                   panelConfiguration: store.configuration)
        let data = try JSONEncoder().encode(backup)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["orderedPluginIDs", "panelConfiguration"])
        let restored = try JSONDecoder().decode(PluginDisplayPreferencesBackup.self, from: data)
        XCTAssertEqual(restored.panelConfiguration, store.configuration)
    }

}
