import XCTest
import MacToolsPluginKit
@testable import MacTools
@testable import DisplayVolumePlugin

@MainActor
final class DisplayVolumePluginTests: XCTestCase {

    func testPanelItemDefaultsToCollapsedRowAndRoutesSliderActions() throws {
        let controller = MockDisplayVolumeController()
        controller.snapshotValue = DisplayVolumeSnapshot(
            displays: [makeVolumeDisplay(id: 7, name: "Display", volume: 0.5)], errorMessage: nil
        )
        let plugin = DisplayVolumePlugin(controller: controller)
        let item = try XCTUnwrap(plugin.panelItems.first)
        XCTAssertEqual(plugin.panelItems.map(\.id), ["control"])
        XCTAssertEqual(item.initialPlacement, .featurePanel)
        guard case let .row(row) = item.content else { return XCTFail("Expected a row") }
        XCTAssertEqual(row.descriptor.controlStyle, .disclosure)
        XCTAssertEqual(row.descriptor.menuActionBehavior, .keepPresented)
        XCTAssertNil(row.state.detail)
        XCTAssertTrue(row.state.isEnabled)

        var notifications = 0
        plugin.onStateChange = { notifications += 1 }
        row.action(.setDisclosureExpanded(true))
        XCTAssertEqual(plugin.rowState.detail?.primaryControls.count, 1)
        let sliderID = try XCTUnwrap(plugin.rowState.detail?.primaryControls.first?.id)
        row.action(.setSlider(controlID: sliderID, value: 0.6, phase: .changed))
        row.action(.setSlider(controlID: sliderID, value: 0.6, phase: .ended))
        XCTAssertEqual(controller.volumeWrites, [
            .init(value: 0.6, displayID: 7, phase: .changed),
            .init(value: 0.6, displayID: 7, phase: .ended)
        ])
        row.action(.setDisclosureExpanded(false))
        XCTAssertNil(plugin.rowState.detail)
        XCTAssertEqual(notifications, 4)
    }

    func testSliderGestureDoesNotTransferToReplacementAtSameID() throws {
        let controller = MockDisplayVolumeController()
        controller.snapshotValue = .init(
            displays: [makeVolumeDisplay(id: 7, name: "Original", volume: 0.7)], errorMessage: nil
        )
        let plugin = DisplayVolumePlugin(controller: controller)
        plugin.handleAction(.setDisclosureExpanded(true))
        let previous = try XCTUnwrap(plugin.rowState.detail?.primaryControls.first?.id)
        plugin.handleAction(.setSlider(controlID: previous, value: 0.6, phase: .changed))

        controller.actionIdentifiers[7] = "replacement"
        controller.snapshotValue = .init(
            displays: [makeVolumeDisplay(id: 7, name: "Replacement", volume: 0.4)], errorMessage: nil
        )
        let current = try XCTUnwrap(plugin.rowState.detail?.primaryControls.first?.id)
        XCTAssertNotEqual(current, previous)
        plugin.handleAction(.setSlider(controlID: previous, value: 0.6, phase: .ended))
        plugin.handleAction(.setSlider(controlID: current, value: 0.3, phase: .ended))
        XCTAssertEqual(controller.volumeWrites.map(\.value), [0.6, 0.3])
    }

    func testActionAvailabilityRequiresDisplays() {
        let controller = MockDisplayVolumeController()
        controller.snapshotValue = DisplayVolumeSnapshot(displays: [], errorMessage: nil)

        let plugin = DisplayVolumePlugin(controller: controller)

        let reference = ActionReference(
            key: ActionKey(providerID: "display-volume", actionID: "display-volume.increase")
        )
        let availability = plugin.actionAvailability(for: reference)

        XCTAssertFalse(availability.isAvailable)
        XCTAssertEqual(availability.reason, "未检测到可调节音量的显示器。")
    }

    func testRelativeAvailabilityMatchesExecutionWhenTargetLevelIsUnknown() async throws {
        let controller = MockDisplayVolumeController()
        var display = makeVolumeDisplay(id: 7, name: "Display", volume: 0.5)
        display.isReady = false
        controller.snapshotValue = .init(displays: [display], errorMessage: nil)
        let plugin = DisplayVolumePlugin(controller: controller)
        let reference = ActionReference(key: .init(providerID: "display-volume", actionID: "display-volume.decrease"))

        let availability = plugin.actionAvailability(for: reference)
        let reason = try XCTUnwrap(availability.reason)
        XCTAssertFalse(availability.isAvailable)
        XCTAssertTrue(reason.contains(display.display.name))
        let handle = try plugin.beginAction(.init(reference: reference, source: .test, mode: .background))
        let result = await handle.result()
        XCTAssertEqual(result, .failed(message: reason))
        XCTAssertTrue(controller.volumeWrites.isEmpty)
    }

    func testAllDisplaysVolumeRequiresEveryTargetBeforeChangingAny() async throws {
        let controller = MockDisplayVolumeController()
        let ready = makeVolumeDisplay(id: 7, name: "Ready", volume: 0.5)
        var waiting = makeVolumeDisplay(id: 8, name: "Waiting", volume: 0.6)
        waiting.isReady = false
        controller.snapshotValue = .init(displays: [ready, waiting], errorMessage: nil)
        let preferences = DisplayVolumeShortcutPreferences(storage: DisplayVolumeMemoryStorage())
        preferences.targetMode = .allDisplays
        let plugin = DisplayVolumePlugin(controller: controller, shortcutPreferences: preferences)
        let reference = ActionReference(key: .init(providerID: "display-volume", actionID: "display-volume.decrease"))
        let invocation = ActionInvocation(reference: reference, source: .test, mode: .background)

        let availability = plugin.actionAvailability(for: reference)
        XCTAssertFalse(availability.isAvailable)
        let reason = try XCTUnwrap(availability.reason)
        XCTAssertTrue(reason.contains(waiting.display.name))
        let blocked = try plugin.beginAction(invocation)
        let blockedResult = await blocked.result()
        XCTAssertEqual(blockedResult, .failed(message: reason))
        plugin.handleShortcutEvent(id: reference.key.actionID, phase: .pressed)
        XCTAssertTrue(controller.volumeWrites.isEmpty)

        waiting.isReady = true
        controller.snapshotValue = .init(displays: [ready, waiting], errorMessage: nil)
        XCTAssertTrue(plugin.actionAvailability(for: reference).isAvailable)
        let action = try plugin.beginAction(invocation)
        let result = await action.result()
        XCTAssertEqual(result, .succeeded())
        XCTAssertEqual(controller.volumeWrites.map(\.displayID), [7, 8])
    }

    func testAllDisplaysVolumeDoesNotAdjustReplacementDuringAction() async throws {
        let controller = MockDisplayVolumeController()
        controller.snapshotValue = .init(displays: [
            makeVolumeDisplay(id: 7, name: "First", volume: 0.5),
            makeVolumeDisplay(id: 8, name: "Second", volume: 0.6),
        ], errorMessage: nil)
        controller.onCompletedWrite = { [weak controller] in
            controller?.actionIdentifiers[8] = "replacement"
        }
        let preferences = DisplayVolumeShortcutPreferences(storage: DisplayVolumeMemoryStorage())
        preferences.targetMode = .allDisplays
        let plugin = DisplayVolumePlugin(controller: controller, shortcutPreferences: preferences)
        let reference = ActionReference(key: .init(providerID: "display-volume", actionID: "display-volume.decrease"))
        let handle = try plugin.beginAction(.init(reference: reference, source: .test, mode: .background))
        guard case .failed = await handle.result() else { return XCTFail("A replaced target should fail") }
        XCTAssertEqual(controller.volumeWrites.map(\.displayID), [7])
    }

    func testAbsoluteVolumeWritesSelectedDisplayAndReportsBackendFailure() async throws {
        let controller = MockDisplayVolumeController()
        controller.snapshotValue = .init(
            displays: [
                makeVolumeDisplay(id: 7, name: "Monitor", volume: 0.1, vendorNumber: 1, modelNumber: 2, serialNumber: 3),
                makeVolumeDisplay(id: 8, name: "Monitor", volume: 0.9, vendorNumber: 1, modelNumber: 2, serialNumber: 4),
            ],
            errorMessage: nil
        )
        let plugin = DisplayVolumePlugin(controller: controller)
        let entries = plugin.actionCatalogEntries.filter { $0.reference.key.actionID == "set-display-volume" }
        XCTAssertEqual(Set(entries.map(\.title)).count, 2)
        let entry = try XCTUnwrap(entries.last)
        let definition = try XCTUnwrap(plugin.actionDefinitions.first { $0.key == entry.reference.key })
        XCTAssertTrue(definition.capabilities.contains([.automatic, .background]))
        XCTAssertNil(ActionPercentage.setting(101, in: entry.reference))
        let voice = ActionExposureSurface(rawValue: "voice-control")
        XCTAssertEqual(plugin.exposurePolicy(for: entry.reference, on: voice), .excluded)
        let relative = ActionReference(key: .init(providerID: "display-volume", actionID: "display-volume.increase"))
        XCTAssertEqual(plugin.exposurePolicy(for: relative, on: voice), .automatic)
        let reference = try XCTUnwrap(ActionPercentage.setting(63, in: entry.reference))
        controller.writeResults[8] = .failed(message: "Display write failed")

        let handle = try plugin.beginAction(.init(reference: reference, source: .automaticRule, mode: .background))
        let result = await handle.result()
        XCTAssertEqual(result, .failed(message: "Display write failed"))
        XCTAssertEqual(controller.volumeWrites, [.init(value: 0.63, displayID: 8, phase: .ended)])
    }

    func testBeginActionIncreasesVolumeByOnePercent() async throws {
        let controller = MockDisplayVolumeController()
        controller.snapshotValue = DisplayVolumeSnapshot(
            displays: [
                makeVolumeDisplay(id: 7, name: "Studio Display", volume: 0.50)
            ],
            errorMessage: nil
        )

        let plugin = DisplayVolumePlugin(controller: controller)

        let invocation = ActionInvocation(
            reference: ActionReference(
                key: ActionKey(providerID: "display-volume", actionID: "display-volume.increase")
            ),
            source: .test,
            mode: .background
        )
        let handle = try plugin.beginAction(invocation)
        let result = await handle.result()

        XCTAssertEqual(result, .succeeded())
        XCTAssertEqual(controller.volumeWrites.last?.value ?? 0, 0.51, accuracy: 0.001)
    }

    func testBeginActionDecreasesVolumeByOnePercent() async throws {
        let controller = MockDisplayVolumeController()
        controller.snapshotValue = DisplayVolumeSnapshot(
            displays: [
                makeVolumeDisplay(id: 7, name: "Studio Display", volume: 0.50)
            ],
            errorMessage: nil
        )

        let plugin = DisplayVolumePlugin(controller: controller)

        let invocation = ActionInvocation(
            reference: ActionReference(
                key: ActionKey(providerID: "display-volume", actionID: "display-volume.decrease")
            ),
            source: .test,
            mode: .background
        )
        let handle = try plugin.beginAction(invocation)
        let result = await handle.result()

        XCTAssertEqual(result, .succeeded())
        XCTAssertEqual(controller.volumeWrites.last?.value ?? 0, 0.49, accuracy: 0.001)
    }

    func testDeactivateCancelsOutstandingWrites() {
        let controller = MockDisplayVolumeController()
        let plugin = DisplayVolumePlugin(controller: controller)

        plugin.deactivate(reason: .updating)

        XCTAssertEqual(controller.cancelOutstandingWritesCount, 1)
    }

}
