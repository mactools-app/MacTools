import CoreGraphics
import XCTest
import MacToolsPluginKit
@testable import MacTools
@testable import DisplayBrightnessPlugin

@MainActor
final class DisplayBrightnessPluginTests: XCTestCase {
    func testPendingMouseDisplayDoesNotRedirectShortcutToAnotherDisplay() {
        let controller = MockDisplayBrightnessController()
        var pending = makeBrightnessDisplay(id: 9, name: "Pending Display", brightness: 1)
        pending.isReady = false
        controller.snapshotValue = DisplayBrightnessSnapshot(
            displays: [makeBrightnessDisplay(id: 7, name: "Ready Display", brightness: 0.5), pending], errorMessage: nil
        )
        let preferences = DisplayBrightnessShortcutPreferences(storage: DisplayBrightnessMemoryStorage())
        preferences.targetMode = .followsMouse
        let plugin = DisplayBrightnessPlugin(
            controller: controller, shortcutPreferences: preferences, mouseDisplayIDProvider: { 9 }
        )
        plugin.handleShortcutEvent(id: "display-brightness.increase", phase: .pressed)
        XCTAssertTrue(controller.brightnessWrites.isEmpty)
        preferences.targetMode = .allDisplays
        plugin.handleShortcutEvent(id: "display-brightness.increase", phase: .pressed)
        XCTAssertTrue(controller.brightnessWrites.isEmpty)
        let reference = plugin.actionCatalogEntries.first { $0.reference.key.actionID == "display-brightness.increase" }!.reference
        XCTAssertFalse(plugin.actionAvailability(for: reference).isAvailable)
    }


    func testDiscreteBrightnessActionUsesConfiguredTargetAndCommits() async throws {
        let controller = MockDisplayBrightnessController()
        controller.snapshotValue = DisplayBrightnessSnapshot(
            displays: [makeBrightnessDisplay(id: 7, name: "Studio Display", brightness: 0.72)],
            errorMessage: nil
        )
        let plugin = DisplayBrightnessPlugin(
            controller: controller,
            mouseDisplayIDProvider: { 7 }
        )
        let reference = try XCTUnwrap(
            plugin.actionCatalogEntries.first {
                $0.reference.key.actionID == "display-brightness.increase"
            }?.reference
        )

        let result = try await plugin.beginAction(
            ActionInvocation(reference: reference, source: .test, mode: .background)
        ).result()

        XCTAssertEqual(result, .succeeded())
        XCTAssertEqual(controller.brightnessWrites.map(\.phase), [.ended])
        XCTAssertEqual(controller.brightnessWrites.first?.value ?? 0, 0.73, accuracy: 0.0001)
        let definition = try XCTUnwrap(
            plugin.actionDefinitions.first { $0.key == reference.key }
        )
        XCTAssertTrue(definition.capabilities.contains(.cancellable))
    }

    func testDeactivationCancelsOutstandingControllerWrites() {
        let controller = MockDisplayBrightnessController()
        let plugin = DisplayBrightnessPlugin(controller: controller)

        plugin.deactivate(reason: .updating)

        XCTAssertEqual(controller.cancelOutstandingWritesCount, 1)
    }

    func testDiscreteBrightnessActionReportsBackendFailure() async throws {
        let controller = MockDisplayBrightnessController()
        controller.snapshotValue = DisplayBrightnessSnapshot(
            displays: [makeBrightnessDisplay(id: 7, name: "Studio Display", brightness: 0.72)],
            errorMessage: nil
        )
        controller.writeResults[7] = .failed(message: "DDC write failed")
        let plugin = DisplayBrightnessPlugin(
            controller: controller,
            mouseDisplayIDProvider: { 7 }
        )
        let reference = try XCTUnwrap(
            plugin.actionCatalogEntries.first {
                $0.reference.key.actionID == "display-brightness.increase"
            }?.reference
        )

        let result = try await plugin.beginAction(ActionInvocation(
            reference: reference,
            source: .test,
            mode: .background
        )).result()

        XCTAssertEqual(result, .failed(message: "DDC write failed"))
        XCTAssertEqual(controller.brightnessWrites.map(\.phase), [.ended])
    }

    func testDiscreteBrightnessActionWaitsForEveryDisplayAndAggregatesFailures() async throws {
        let controller = MockDisplayBrightnessController()
        controller.snapshotValue = DisplayBrightnessSnapshot(
            displays: [
                makeBrightnessDisplay(id: 7, name: "Studio Display", brightness: 0.72),
                makeBrightnessDisplay(id: 9, name: "LG UltraFine", brightness: 0.41),
            ],
            errorMessage: nil
        )
        controller.writeResults[7] = .failed(message: "first failed")
        controller.writeResults[9] = .failed(message: "second failed")
        let preferences = DisplayBrightnessShortcutPreferences(
            storage: DisplayBrightnessMemoryStorage()
        )
        preferences.targetMode = .allDisplays
        let plugin = DisplayBrightnessPlugin(
            controller: controller,
            shortcutPreferences: preferences
        )
        let reference = try XCTUnwrap(
            plugin.actionCatalogEntries.first {
                $0.reference.key.actionID == "display-brightness.decrease"
            }?.reference
        )

        let result = try await plugin.beginAction(ActionInvocation(
            reference: reference,
            source: .test,
            mode: .background
        )).result()

        XCTAssertEqual(result, .failed(message: "first failed；second failed"))
        XCTAssertEqual(controller.brightnessWrites.map(\.displayID), [7, 9])
    }

    func testSliderPowerButtonTurnsItsDisplayOffAndBackOn() async throws {
        let controller = MockDisplayBrightnessController()
        controller.snapshotValue = DisplayBrightnessSnapshot(
            displays: [
                makeBrightnessDisplay(id: 7, name: "Studio Display", brightness: 0.72),
                makeBrightnessDisplay(id: 9, name: "LG UltraFine", brightness: 0.41),
            ],
            errorMessage: nil
        )
        let coordinator = MockDisplayDisableCoordinator(entries: [
            DisplayDisableEntry(id: 7, name: "Studio Display", isBuiltin: false, isDisabled: false,
                                isDisableAllowed: true, unavailableReason: nil),
            DisplayDisableEntry(id: 9, name: "LG UltraFine", isBuiltin: false, isDisabled: false,
                                isDisableAllowed: false, unavailableReason: "last"),
            DisplayDisableEntry(id: 1, name: "Built-in Display", isBuiltin: true, isDisabled: true,
                                isDisableAllowed: false, unavailableReason: nil),
        ])
        let plugin = DisplayBrightnessPlugin(controller: controller, displayDisableCoordinator: coordinator)
        plugin.handleAction(.setDisclosureExpanded(true))

        let controls = try XCTUnwrap(plugin.rowState.detail?.primaryControls)
        // A display switched off by MacTools keeps a greyed slider whose button turns it back on.
        XCTAssertEqual(
            controls.map(\.id),
            ["display.7.brightness", "display.9.brightness", "display.1.brightness"]
        )
        XCTAssertEqual(controls.map(\.actionIconSystemName), ["power", nil, "power"])
        XCTAssertEqual(controls.map(\.isEnabled), [true, true, false])

        plugin.handleAction(.invokeAction(controlID: "display.1.brightness"))
        XCTAssertEqual(coordinator.restoredDisplayIDs, [1])

        let disabled = expectation(description: "display switched off")
        coordinator.onDisable = { _ in disabled.fulfill() }
        plugin.handleAction(.invokeAction(controlID: "display.7.brightness"))
        await fulfillment(of: [disabled], timeout: 1)

        XCTAssertEqual(coordinator.disabledDisplayIDs, [7])
    }

    func testShortcutFollowingMouseAdjustsOnlyMouseDisplay() throws {
        let controller = MockDisplayBrightnessController()
        controller.snapshotValue = DisplayBrightnessSnapshot(
            displays: [
                makeBrightnessDisplay(id: 7, name: "Studio Display", brightness: 0.72),
                makeBrightnessDisplay(id: 9, name: "LG UltraFine", brightness: 0.41)
            ],
            errorMessage: nil
        )
        let preferences = DisplayBrightnessShortcutPreferences(storage: DisplayBrightnessMemoryStorage())
        preferences.targetMode = .followsMouse
        let plugin = DisplayBrightnessPlugin(
            controller: controller,
            shortcutPreferences: preferences,
            mouseDisplayIDProvider: { 9 }
        )

        plugin.handleShortcutEvent(id: "display-brightness.increase", phase: .pressed)

        XCTAssertEqual(controller.brightnessWrites.count, 1)
        let write = try XCTUnwrap(controller.brightnessWrites.first)
        XCTAssertEqual(write.displayID, 9)
        XCTAssertEqual(write.value, 0.42, accuracy: 0.0001)
        XCTAssertEqual(write.phase, .changed)
    }

    func testShortcutAllDisplaysAdjustsEveryDisplay() {
        let controller = MockDisplayBrightnessController()
        controller.snapshotValue = DisplayBrightnessSnapshot(
            displays: [
                makeBrightnessDisplay(id: 7, name: "Studio Display", brightness: 0.72),
                makeBrightnessDisplay(id: 9, name: "LG UltraFine", brightness: 0.41)
            ],
            errorMessage: nil
        )
        let preferences = DisplayBrightnessShortcutPreferences(storage: DisplayBrightnessMemoryStorage())
        preferences.targetMode = .allDisplays
        let plugin = DisplayBrightnessPlugin(
            controller: controller,
            shortcutPreferences: preferences,
            mouseDisplayIDProvider: { 9 }
        )

        plugin.handleShortcutEvent(id: "display-brightness.decrease", phase: .pressed)

        XCTAssertEqual(controller.brightnessWrites.count, 2)
        XCTAssertEqual(controller.brightnessWrites.map(\.displayID), [7, 9])
        XCTAssertEqual(controller.brightnessWrites.map(\.phase), [.changed, .changed])
        XCTAssertEqual(controller.brightnessWrites[0].value, 0.71, accuracy: 0.0001)
        XCTAssertEqual(controller.brightnessWrites[1].value, 0.40, accuracy: 0.0001)
    }

}

@MainActor
private final class MockDisplayDisableCoordinator: DisplayDisableCoordinating {
    private(set) var snapshot: DisplayDisableSnapshot
    var onSnapshotChange: (() -> Void)?
    var onDisable: ((CGDirectDisplayID) -> Void)?
    private(set) var disabledDisplayIDs: [CGDirectDisplayID] = []
    private(set) var restoredDisplayIDs: [CGDirectDisplayID] = []

    init(entries: [DisplayDisableEntry]) {
        snapshot = DisplayDisableSnapshot(isSupported: true, entries: entries, message: nil)
    }

    func refreshSnapshot() {}

    func disableDisplay(_ displayID: CGDirectDisplayID) async {
        disabledDisplayIDs.append(displayID)
        onDisable?(displayID)
    }

    func restoreDisplay(_ displayID: CGDirectDisplayID) {
        restoredDisplayIDs.append(displayID)
    }

    func restoreAllDisplays() {}
    func reconcileTopology() {}
    func deactivate(restoringDisplays: Bool) {}
}
