import CoreGraphics
import XCTest
import MacToolsPluginKit
@testable import MacTools
@testable import DisplayBrightnessPlugin

@MainActor
final class DisplayBrightnessPluginTests: XCTestCase {
    func testVoiceUsesFreshReadbackAndRejectsStaleAbsoluteTargets() async throws {
        let controller = MockDisplayBrightnessController()
        let display = makeTestDisplay(id: 7, name: "Display", isBuiltin: true)
        controller.snapshotValue = .init(displays: [.init(display: display, brightness: 0.8, isPendingWrite: true)], errorMessage: nil)
        controller.observations[7] = .init(value: 0.35, backend: .appleNative, isPendingWrite: false)
        let plugin = DisplayBrightnessPlugin(controller: controller)
        for definition in plugin.actionDefinitions where definition.key.actionID.hasPrefix("display-brightness.") {
            XCTAssertEqual(plugin.exposurePolicy(for: .init(key: definition.key), on: .init(rawValue: "voice-control")), .excluded)
        }
        let source = try await plugin.readVoiceQuery(id: "display-state")
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(source.utf8)) as? [String: Any])
        let generation = try XCTUnwrap(state["generation"] as? String)
        let observed = try XCTUnwrap((state["displays"] as? [[String: Any]])?.first)
        XCTAssertEqual(observed["observedPercent"] as? Double, 35)
        XCTAssertEqual(observed["hardwareVerified"] as? Bool, true)
        let reference = ActionReference(key: .init(providerID: plugin.metadata.id, actionID: "set-brightness"),
            parameters: try ActionParameterSet(["display-id": .string("7"), "generation": .string(generation), "percent": .double(35)]))
        let handle = try plugin.beginAction(.init(reference: reference, source: .manual, mode: .foreground))
        let result = await handle.result()
        guard case .succeeded = result else { return XCTFail("Matching hardware readback must succeed") }
        XCTAssertEqual(controller.brightnessWrites.last?.value, 0.35)
        let mismatch = ActionReference(key: reference.key, parameters: try ActionParameterSet([
            "display-id": .string("7"), "generation": .string(generation), "percent": .double(50)]))
        let mismatched = try plugin.beginAction(.init(reference: mismatch, source: .manual, mode: .foreground))
        let mismatchResult = await mismatched.result()
        guard case .failed = mismatchResult else { return XCTFail("A different hardware reading must not be reported as verified success") }
        plugin.refreshDisplayTopology()
        XCTAssertFalse(plugin.actionAvailability(for: reference).isAvailable)
        let stale = try plugin.beginAction(.init(reference: reference, source: .manual, mode: .foreground))
        _ = await stale.result()
        XCTAssertEqual(controller.brightnessWrites.count, 2)
    }

    func testTopologyReplacementDuringWriteCannotVerifyNewDisplay() async throws {
        let controller = MockDisplayBrightnessController()
        let display = makeTestDisplay(id: 8, name: "Original")
        controller.snapshotValue = .init(displays: [.init(display: display, brightness: 0.35, isPendingWrite: false)], errorMessage: nil)
        controller.observations[8] = .init(value: 0.35, backend: .appleNative, isPendingWrite: false)
        let plugin = DisplayBrightnessPlugin(controller: controller)
        let source = try await plugin.readVoiceQuery(id: "display-state")
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(source.utf8)) as? [String: Any])
        let generation = try XCTUnwrap(state["generation"] as? String)
        let reference = ActionReference(key: .init(providerID: plugin.metadata.id, actionID: "set-brightness"),
            parameters: try ActionParameterSet(["display-id": .string("8"), "generation": .string(generation), "percent": .double(35)]))
        controller.onCompletedWrite = { [weak controller, weak plugin] in
            let replacement = makeTestDisplay(id: 8, name: "Replacement")
            controller?.snapshotValue = .init(displays: [.init(display: replacement, brightness: 0.35, isPendingWrite: false)], errorMessage: nil)
            plugin?.refreshDisplayTopology()
        }
        let handle = try plugin.beginAction(.init(reference: reference, source: .manual, mode: .foreground))
        let result = await handle.result()
        guard case .failed = result else { return XCTFail("A replacement must not verify the original target's write") }
    }

    func testPortableTargetModeIsDurableAndDoesNotWriteHardware() throws {
        let source = DisplayBrightnessShortcutPreferences(storage: DisplayBrightnessMemoryStorage())
        source.targetMode = .allDisplays
        let storage = DisplayBrightnessMemoryStorage()
        storage.set("local-device", forKey: "recovery")
        let preferences = DisplayBrightnessShortcutPreferences(storage: storage)
        let controller = MockDisplayBrightnessController()
        let plugin = DisplayBrightnessPlugin(controller: controller, shortcutPreferences: preferences)
        var changes = 0
        plugin.onPersistentPreferencesChange = { changes += 1 }
        let data = try XCTUnwrap(source.portableBackup())
        XCTAssertTrue(plugin.restorePortablePreferencesReportingResult(from: data))
        XCTAssertEqual(preferences.targetMode, .allDisplays)
        XCTAssertEqual(changes, 1)
        XCTAssertTrue(plugin.restorePortablePreferencesReportingResult(from: data))
        XCTAssertEqual(changes, 1)
        XCTAssertTrue(controller.brightnessWrites.isEmpty)
        XCTAssertEqual(storage.string(forKey: "recovery"), "local-device")
        XCTAssertEqual(DisplayBrightnessShortcutPreferences(storage: storage).targetMode, .allDisplays)
    }

    func testPortableTransactionRejectsFuturePayloadAndRollsBackFailedWrite() throws {
        let storage = DisplayBrightnessMemoryStorage()
        let preferences = DisplayBrightnessShortcutPreferences(storage: storage)
        let source = DisplayBrightnessShortcutPreferences(storage: DisplayBrightnessMemoryStorage())
        source.targetMode = .allDisplays
        let data = try XCTUnwrap(source.portableBackup())
        storage.rejectedWriteKey = "shortcutTargetMode"
        XCTAssertFalse(preferences.restorePortableBackup(data))
        XCTAssertEqual(preferences.targetMode, .followsMouse)
        XCTAssertNil(storage.object(forKey: "shortcutTargetMode"))
        XCTAssertNil(storage.object(forKey: "preferences-backup.restore.v1"))
        storage.rejectedWriteKey = nil
        var future = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        future["formatVersion"] = 99
        XCTAssertFalse(preferences.restorePortableBackup(try JSONSerialization.data(withJSONObject: future)))
        XCTAssertEqual(preferences.targetMode, .followsMouse)
    }

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
