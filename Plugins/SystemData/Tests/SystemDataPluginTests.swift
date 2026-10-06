import Foundation
import MacToolsPluginKit
import XCTest
@testable import SystemDataPlugin

@MainActor
final class SystemDataPluginTests: XCTestCase {
    // MARK: - Manifest contract

    func testManifestMatchesRuntimeIdentityAndCapabilities() throws {
        let manifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // SystemData/
            .appendingPathComponent("plugin.json")
        let data = try Data(contentsOf: manifestURL)
        let manifest = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        let scanner = SystemDataManualScanner()
        let plugin = makePlugin(scanner: scanner)

        XCTAssertEqual(manifest["id"] as? String, plugin.metadata.id)
        XCTAssertEqual(manifest["pluginKitVersion"] as? Int, 7)
        XCTAssertEqual(manifest["bundleRelativePath"] as? String, "SystemData.bundle")

        let capabilities = try XCTUnwrap(manifest["capabilities"] as? [String: Any])
        XCTAssertEqual(
            try XCTUnwrap(capabilities["panelItems"] as? [String]).sorted(),
            ["row", "widget"]
        )
        XCTAssertEqual(capabilities["settings"] as? String, "workspace")
        XCTAssertEqual(try XCTUnwrap(manifest["permissions"] as? [String]), ["full-disk-access"])

        // Manifest action surface: this plugin exposes no canonical actions.
        XCTAssertNil(manifest["actions"])
        XCTAssertTrue(
            (plugin as? PluginActionProviding)?.actionDefinitions.isEmpty ?? true
        )
    }

    // MARK: - Panel surface

    func testPanelItemsExposeRowAndWidget() throws {
        let plugin = makePlugin(scanner: SystemDataManualScanner())
        let items = plugin.panelItems

        XCTAssertEqual(items.map(\.id), ["summary", "overview"])
        guard case let .row(row) = try XCTUnwrap(items.first?.content) else {
            return XCTFail("expected a row item")
        }
        XCTAssertTrue(row.state.subtitle.isEmpty == false)
        XCTAssertNil(row.state.detail, "collapsed row must not publish details")

        guard case let .widget(widget) = try XCTUnwrap(items.last?.content) else {
            return XCTFail("expected a widget item")
        }
        XCTAssertEqual(widget.descriptor.span.width, 4)
        // The allocated cell must cover the card content without leaving a
        // full extra grid unit of empty space.
        let metrics = PluginPanelWidgetLayoutMetrics.default
        let allocated = metrics.itemHeight(forSpanHeight: widget.descriptor.span.height)
        XCTAssertGreaterThanOrEqual(allocated, SystemDataWidgetLayout.cardContentHeight)
        XCTAssertLessThan(
            allocated,
            SystemDataWidgetLayout.cardContentHeight + metrics.cellHeight
        )
        XCTAssertNotNil(widget.makeDetail)
    }

    func testExpandedRowOffersRescanAndSettingsActions() async throws {
        let scanner = SystemDataManualScanner()
        let plugin = makePlugin(scanner: scanner)
        var presentedSettings = false
        plugin.requestSettingsPresentation = { presentedSettings = true }

        let row = try XCTUnwrap(
            plugin.panelItems.first.flatMap { item -> PluginPanelRow? in
                if case let .row(row) = item.content { return row }
                return nil
            }
        )

        row.action(.setDisclosureExpanded(true))
        let expanded = try XCTUnwrap(
            plugin.panelItems.first.flatMap { item -> PluginPanelRow? in
                if case let .row(row) = item.content { return row }
                return nil
            }
        )
        let controls = expanded.state.detail?.primaryControls ?? []
        XCTAssertEqual(controls.map(\.id), ["system-data-rescan", "system-data-open-details"])
        XCTAssertTrue(controls[0].isEnabled, "rescan must be enabled while idle")
        XCTAssertFalse(presentedSettings)

        // Rescan starts a scan through the controller.
        expanded.action(.invokeAction(controlID: "system-data-rescan"))
        try await waitUntil { scanner.ids.count == 1 }

        expanded.action(.invokeAction(controlID: "system-data-open-details"))
        XCTAssertTrue(presentedSettings)

        // Settle the scan started by the rescan control so it does not leak.
        scanner.finish(id: scanner.ids[0], result: SystemDataTestFixtures.result())
    }

    func testWidgetDetailContentIsProvidedForOverview() throws {
        let plugin = makePlugin(scanner: SystemDataManualScanner())
        guard case let .widget(widget) = try XCTUnwrap(
            plugin.panelItems.first { item in
                if case .widget = item.content { return true }
                return false
            }?.content
        ) else {
            return XCTFail("expected a widget item")
        }

        let detail = widget.makeDetail?("overview", {})
        XCTAssertNotNil(detail)
        XCTAssertEqual(detail?.id, "overview")
        XCTAssertEqual(
            detail?.title.isEmpty,
            false
        )
        XCTAssertNil(widget.makeDetail?("other-id", {}))
    }

    func testPermissionDeniedDetectsPolicyDenialsOnly() {
        // TCC-style EPERM differs from ordinary races and permission bits.
        XCTAssertTrue(SystemDataScanner.isPermissionDenied(POSIXError(.EPERM)))
        XCTAssertFalse(SystemDataScanner.isPermissionDenied(POSIXError(.EACCES)))
        XCTAssertFalse(SystemDataScanner.isPermissionDenied(POSIXError(.ENOENT)))
        XCTAssertFalse(SystemDataScanner.isPermissionDenied(POSIXError(.ELOOP)))
    }

    func testUnreadableRuleSparesDeeperDenialsAndPermissionRaces() {
        // WeChat-style: the location's only subdirectory is policy-blocked,
        // so any total would hide the payload — report unreadable.
        XCTAssertTrue(
            SystemDataScanner.shouldReportUnreadable(policyDeniedChildren: 1, readableChildren: 0)
        )
        // /Library/Caches-style: some direct children are TCC-blocked but
        // others open — keep measuring the readable portion.
        XCTAssertFalse(
            SystemDataScanner.shouldReportUnreadable(policyDeniedChildren: 3, readableChildren: 2)
        )
        // No policy denials at all (deeper EPERM, EACCES, races) → measure.
        XCTAssertFalse(
            SystemDataScanner.shouldReportUnreadable(policyDeniedChildren: 0, readableChildren: 0)
        )
        XCTAssertFalse(
            SystemDataScanner.shouldReportUnreadable(policyDeniedChildren: 0, readableChildren: 5)
        )
    }

    // MARK: - Full Disk Access card

    func testFullDiskAccessPermissionRequirementIsDeclared() {
        let plugin = makePlugin(scanner: SystemDataManualScanner())
        XCTAssertEqual(plugin.permissionRequirements.map(\.id), ["full-disk-access"])
        // Unknown permission ids stay granted so no card appears for them.
        let fallback = plugin.permissionState(for: "something-else")
        XCTAssertTrue(fallback.isGranted)
        XCTAssertNil(fallback.footnote)
    }

    // MARK: - Display preferences

    func testShowAllItemsPreferenceDefaultsOffAndPersistsAcrossActivation() {
        let storage = PluginTestStorage()
        let plugin = makePlugin(scanner: SystemDataManualScanner())
        plugin.activate(context: PluginRuntimeContext(
            pluginID: plugin.metadata.id,
            storage: storage
        ))
        XCTAssertFalse(plugin.preferences.showAllItems, "show all must default to off")
        XCTAssertNil(storage.stored[SystemDataDisplayPreferences.showAllItemsKey])

        plugin.preferences.showAllItems = true
        XCTAssertEqual(
            storage.stored[SystemDataDisplayPreferences.showAllItemsKey] as? Bool,
            true
        )

        // A fresh plugin instance restores the stored value at activation.
        let second = makePlugin(scanner: SystemDataManualScanner())
        second.activate(context: PluginRuntimeContext(
            pluginID: second.metadata.id,
            storage: storage
        ))
        XCTAssertTrue(second.preferences.showAllItems)
    }

    // MARK: - Lifecycle

    func testActivateStartsScanAndDeactivateCancels() async throws {
        let scanner = SystemDataManualScanner()
        let plugin = makePlugin(scanner: scanner)
        let context = PluginRuntimeContext(
            pluginID: plugin.metadata.id,
            storage: PluginTestStorage()
        )

        plugin.activate(context: context)
        try await waitUntil { scanner.ids.count == 1 }
        XCTAssertTrue(plugin.panelItems.contains { item in
            if case let .row(row) = item.content { return row.state.isOn }
            return false
        })

        plugin.deactivate(reason: .hostShutdown)
        XCTAssertFalse(plugin.panelItems.contains { item in
            if case let .row(row) = item.content { return row.state.isOn }
            return false
        })

        // The cancelled scan settles with an error the generation guard drops.
        scanner.fail(id: scanner.ids[0], error: CancellationError())
    }

    // MARK: - Helpers

    private func makePlugin(scanner: SystemDataScanning) -> SystemDataPlugin {
        SystemDataPlugin(
            controller: SystemDataController(
                scanner: scanner,
                definitions: SystemDataTestFixtures.definitions
            ),
            localization: PluginLocalization(bundle: .main)
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ predicate: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        if predicate() { return }
        XCTFail("condition not met within \(timeout)s", file: file, line: line)
    }
}

// MARK: - Storage stub

/// In-memory storage that records writes, so persistence tests can assert
/// what the plugin actually stored.
private final class PluginTestStorage: PluginStorage {
    var stored: [String: Any] = [:]

    func object(forKey key: String) -> Any? { stored[key] }
    func data(forKey key: String) -> Data? { stored[key] as? Data }
    func string(forKey key: String) -> String? { stored[key] as? String }
    func stringArray(forKey key: String) -> [String]? { stored[key] as? [String] }
    func integer(forKey key: String) -> Int { stored[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { stored[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) {
        if let value {
            stored[key] = value
        } else {
            stored.removeValue(forKey: key)
        }
    }
    func removeObject(forKey key: String) { stored.removeValue(forKey: key) }
    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {
        guard stored[key] == nil, let legacy = stored.removeValue(forKey: legacyKey) else { return }
        stored[key] = legacy
    }
}
