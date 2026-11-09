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
        row.action(.setSlider(controlID: "display.7.volume", value: 0.6, phase: .changed))
        row.action(.setSlider(controlID: "display.7.volume", value: 0.6, phase: .ended))
        XCTAssertEqual(controller.volumeWrites, [
            .init(value: 0.6, displayID: 7, phase: .changed),
            .init(value: 0.6, displayID: 7, phase: .ended)
        ])
        row.action(.setDisclosureExpanded(false))
        XCTAssertNil(plugin.rowState.detail)
        XCTAssertEqual(notifications, 4)
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
