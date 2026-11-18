import Foundation
import MacToolsPluginKit
import SwiftUI
import XCTest
@testable import MacTools

@MainActor
final class PluginHostPhysicalInputCompatibilityTests: XCTestCase {
    func testOlderCompanionBlocksProtectionEvenWithAnotherUpdatedCompanion() {
        for id in ["window-switcher", "input-remapping", "trackpad-gestures"] {
            let consumer = Consumer()
            let otherID = id == "window-switcher" ? "input-remapping" : "window-switcher"
            let host = makePluginHostForTests(plugins: [consumer, Companion(id: id), ReportingCompanion(id: otherID)])
            XCTAssertEqual(consumer.isCompatible, false)
            withExtendedLifetime(host) {}
        }
    }

    func testUpdatedCompanionsAndUnrelatedPluginsAllowProtection() {
        let consumer = Consumer()
        let host = makePluginHostForTests(plugins: [
            consumer, ReportingCompanion(id: "window-switcher"), ReportingCompanion(id: "input-remapping"),
            ReportingCompanion(id: "trackpad-gestures"), Companion(id: "unrelated")
        ])
        XCTAssertEqual(consumer.isCompatible, true)
        withExtendedLifetime(host) {}
    }

    func testOrdinaryRefreshReusesCompatibilityUntilACompanionIsIsolated() {
        let consumer = Consumer()
        let companion = FailingCompanion(id: "input-remapping")
        let host = makePluginHostForTests(plugins: [consumer, companion])
        XCTAssertEqual(consumer.compatibilityUpdates, [false])

        host.refreshAll()
        XCTAssertEqual(consumer.compatibilityUpdates, [false])

        companion.failsOnRefresh = true
        host.refreshAll()
        XCTAssertEqual(consumer.compatibilityUpdates, [false, true])
    }

    func testCompatibilityReusesIdenticalDynamicInstancesAndChecksReplacements() throws {
        let suiteName = "PluginHostPhysicalInputCompatibilityTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suiteName)
        }
        let manager = DynamicPluginManager(packageStore: PluginPackageStore(rootDirectory: root, userDefaults: defaults))
        let consumer = Consumer()
        let host = makePluginHostForTests(plugins: [consumer], dynamicPluginManager: manager)
        let older = Companion(id: "input-remapping")

        manager.onPluginsChanged?([older])
        manager.onPluginsChanged?([older])
        XCTAssertEqual(consumer.compatibilityUpdates, [true, false])

        manager.onPluginsChanged?([ReportingCompanion(id: "input-remapping")])
        XCTAssertEqual(consumer.compatibilityUpdates, [true, false, true])
        withExtendedLifetime(host) {}
    }

    private class Companion: MacToolsPlugin {
        let metadata: PluginMetadata
        var onStateChange: (() -> Void)?
        var requestPermissionGuidance: ((String) -> Void)?
        var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

        init(id: String) {
            metadata = PluginMetadata(id: id, title: id, iconName: "keyboard", iconTint: Color.primary,
                                      order: 0, defaultDescription: "")
        }

        func refresh() {}
    }

    private final class ReportingCompanion: Companion, PluginPhysicalInputClaimReporting {}

    private final class FailingCompanion: Companion {
        var failsOnRefresh = false

        override func refresh() {
            if failsOnRefresh { raiseTestPluginException(reason: "companion refresh failed") }
        }
    }

    private final class Consumer: Companion, PluginPhysicalInputCompatibilityConsuming {
        private(set) var isCompatible: Bool?
        private(set) var compatibilityUpdates: [Bool] = []

        init() { super.init(id: "quit-protection") }

        func physicalInputCompatibilityDidChange(isCompatible: Bool) -> Bool {
            compatibilityUpdates.append(isCompatible)
            let changed = self.isCompatible != isCompatible
            self.isCompatible = isCompatible
            return changed
        }
    }
}
