import MacToolsPluginKit
import SwiftUI
import XCTest
@testable import MacTools

@MainActor
final class PluginHostPhysicalInputCompatibilityTests: XCTestCase {
    func testOlderCompanionBlocksProtectionEvenWithAnotherUpdatedCompanion() {
        for id in ["window-switcher", "input-remapping"] {
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
            Companion(id: "unrelated")
        ])
        XCTAssertEqual(consumer.isCompatible, true)
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
    }

    private final class ReportingCompanion: Companion, PluginPhysicalInputClaimReporting {}

    private final class Consumer: Companion, PluginPhysicalInputCompatibilityConsuming {
        private(set) var isCompatible: Bool?

        init() { super.init(id: "quit-protection") }

        func physicalInputCompatibilityDidChange(isCompatible: Bool) -> Bool {
            let changed = self.isCompatible != isCompatible
            self.isCompatible = isCompatible
            return changed
        }
    }
}
