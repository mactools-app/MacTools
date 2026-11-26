import CoreGraphics
import XCTest
@testable import NotchHoverPanelPlugin

final class NotchHoverPanelGeometryTests: XCTestCase {
    private let screenFrame = CGRect(x: 0, y: 0, width: 1_512, height: 982)
    private let leftArea = CGRect(x: 0, y: 950, width: 620, height: 32)
    private let rightArea = CGRect(x: 892, y: 950, width: 620, height: 32)

    func testDisplayWithoutCameraHousingHasNoHoverTrigger() {
        let screen = NotchHoverScreenSnapshot(
            displayID: 1,
            frame: screenFrame,
            auxiliaryTopLeftArea: nil,
            auxiliaryTopRightArea: nil,
            isBuiltin: true,
            isMain: true,
            isInMirrorSet: false
        )

        XCTAssertNil(NotchHoverGeometry.display(for: screen, triggerWidth: 52, verticalTriggerReach: 72))
    }

    func testDefaultTriggerIsOnlyTheIsland() throws {
        let display = try XCTUnwrap(makeDisplay(
            triggerWidth: NotchHoverGeometry.defaultTriggerWidth,
            verticalTriggerReach: NotchHoverGeometry.defaultVerticalTriggerReach
        ))

        XCTAssertEqual(display.triggerRects, [display.notchFrame])
        let withBelowTriggerDisabled = try XCTUnwrap(
            makeDisplay(triggerWidth: 0, enableBelowTrigger: false)
        )
        XCTAssertEqual(withBelowTriggerDisabled.triggerRects, [withBelowTriggerDisabled.notchFrame])
        for point in [CGPoint(x: 610, y: 960), CGPoint(x: 900, y: 960), CGPoint(x: 756, y: 940)] {
            XCTAssertFalse(NotchHoverGeometry.isPointerActive(
                point,
                triggers: display.triggerRects,
                notchFrame: display.notchFrame,
                panelFrame: nil
            ), "Pointer just outside the island at \(point) must not open the panel.")
        }
    }

    func testTriggersStayImmediatelyBesideAndBelowTheNotch() throws {
        let display = try XCTUnwrap(makeDisplay(triggerWidth: 52, verticalTriggerReach: 72))

        XCTAssertEqual(display.notchFrame, CGRect(x: 620, y: 950, width: 272, height: 32))
        XCTAssertEqual(display.triggerRects.count, 3)
        XCTAssertEqual(display.triggerRects[0], CGRect(x: 568, y: 950, width: 52, height: 32))
        XCTAssertEqual(display.triggerRects[1], CGRect(x: 892, y: 950, width: 52, height: 32))
        XCTAssertEqual(
            display.triggerRects[2],
            CGRect(
                x: 620,
                y: 950 - 72,
                width: 272,
                height: 32 + 72
            )
        )

        // The rest of the menu bar must not trigger the notched panel.
        XCTAssertFalse(NotchHoverGeometry.isPointerActive(
            CGPoint(x: 300, y: 960),
            triggers: display.triggerRects,
            notchFrame: display.notchFrame,
            panelFrame: nil
        ))
        XCTAssertTrue(NotchHoverGeometry.isPointerActive(
            CGPoint(x: 600, y: 960),
            triggers: display.triggerRects,
            notchFrame: display.notchFrame,
            panelFrame: nil
        ))
    }

    func testMovingUpwardFromBelowTheNotchTriggersThePanel() throws {
        let display = try XCTUnwrap(makeDisplay(triggerWidth: 52, verticalTriggerReach: 72))

        XCTAssertTrue(NotchHoverGeometry.isPointerActive(
            CGPoint(x: 756, y: 900),
            triggers: display.triggerRects,
            notchFrame: display.notchFrame,
            panelFrame: nil
        ), "Pointer below the notch should trigger the panel.")
        XCTAssertFalse(NotchHoverGeometry.isPointerActive(
            CGPoint(x: 756, y: 860),
            triggers: display.triggerRects,
            notchFrame: display.notchFrame,
            panelFrame: nil
        ), "Pointer below the configured reach should not trigger the panel.")
        XCTAssertFalse(NotchHoverGeometry.isPointerActive(
            CGPoint(x: 500, y: 900),
            triggers: display.triggerRects,
            notchFrame: display.notchFrame,
            panelFrame: nil
        ), "The trigger below the notch stays within the notch width.")
    }

    func testDisablingBelowTriggerKeepsTheIslandAndSideTriggers() throws {
        let display = try XCTUnwrap(
            makeDisplay(triggerWidth: 52, verticalTriggerReach: 72, enableBelowTrigger: false)
        )

        XCTAssertEqual(display.triggerRects.count, 3)
        XCTAssertEqual(display.triggerRects.last, display.notchFrame)
        XCTAssertEqual(display.triggerRects[0], CGRect(x: 568, y: 950, width: 52, height: 32))
        XCTAssertEqual(display.triggerRects[1], CGRect(x: 892, y: 950, width: 52, height: 32))
        XCTAssertFalse(NotchHoverGeometry.isPointerActive(
            CGPoint(x: 756, y: 900),
            triggers: display.triggerRects,
            notchFrame: display.notchFrame,
            panelFrame: nil
        ), "Pointer below the notch must not trigger when the lower trigger is disabled.")
        XCTAssertTrue(NotchHoverGeometry.isPointerActive(
            CGPoint(x: 600, y: 960),
            triggers: display.triggerRects,
            notchFrame: display.notchFrame,
            panelFrame: nil
        ), "Side triggers keep working when the lower trigger is disabled.")
    }

    func testVerticalTriggerReachIsClampedAndRespected() throws {
        let minimum = try XCTUnwrap(makeDisplay(triggerWidth: 52, verticalTriggerReach: -10))
        let maximum = try XCTUnwrap(makeDisplay(triggerWidth: 52, verticalTriggerReach: 500))

        XCTAssertEqual(
            minimum.triggerRects[2].height,
            32 + NotchHoverGeometry.minimumVerticalTriggerReach
        )
        XCTAssertEqual(
            maximum.triggerRects[2].height,
            32 + NotchHoverGeometry.maximumVerticalTriggerReach
        )
        XCTAssertTrue(NotchHoverGeometry.isPointerActive(
            CGPoint(x: 756, y: 810),
            triggers: maximum.triggerRects,
            notchFrame: maximum.notchFrame,
            panelFrame: nil
        ))
    }

    func testTriggerWidthIsClampedToSupportedRange() throws {
        // Below the minimum, the side areas disappear and only the island remains.
        let minimum = try XCTUnwrap(makeDisplay(triggerWidth: -10))
        XCTAssertEqual(minimum.triggerRects, [minimum.notchFrame])
        XCTAssertEqual(
            try XCTUnwrap(makeDisplay(triggerWidth: 500)).triggerRects[0].width,
            NotchHoverGeometry.maximumTriggerWidth
        )
    }

    func testMirroredSecondaryScreenDoesNotCreateAnotherTrigger() {
        let mirrored = NotchHoverScreenSnapshot(
            displayID: 2,
            frame: screenFrame,
            auxiliaryTopLeftArea: leftArea,
            auxiliaryTopRightArea: rightArea,
            isBuiltin: true,
            isMain: false,
            isInMirrorSet: true
        )

        XCTAssertNil(NotchHoverGeometry.display(for: mirrored, triggerWidth: 52))
    }

    func testPointerStaysActiveInsidePresentedPanelAndTransitionCorridor() throws {
        let display = try XCTUnwrap(makeDisplay(triggerWidth: 52))
        let panelFrame = CGRect(x: 600, y: 600, width: 320, height: 120)

        XCTAssertTrue(NotchHoverGeometry.isPointerActive(
            CGPoint(x: 700, y: 650),
            triggers: display.triggerRects,
            notchFrame: display.notchFrame,
            panelFrame: panelFrame
        ), "Pointer inside the shown panel should keep it visible.")
        XCTAssertTrue(NotchHoverGeometry.isPointerActive(
            CGPoint(x: 700, y: 760),
            triggers: display.triggerRects,
            notchFrame: display.notchFrame,
            panelFrame: panelFrame
        ), "Pointer in the gap between the panel and notch should keep it visible.")
        XCTAssertFalse(NotchHoverGeometry.isPointerActive(
            CGPoint(x: 700, y: 400),
            triggers: display.triggerRects,
            notchFrame: display.notchFrame,
            panelFrame: panelFrame
        ))
    }

    private func makeDisplay(
        triggerWidth: CGFloat,
        verticalTriggerReach: CGFloat = NotchHoverGeometry.defaultVerticalTriggerReach,
        enableBelowTrigger: Bool = true
    ) -> NotchHoverDisplay? {
        NotchHoverGeometry.display(
            for: NotchHoverScreenSnapshot(
                displayID: 1,
                frame: screenFrame,
                auxiliaryTopLeftArea: leftArea,
                auxiliaryTopRightArea: rightArea,
                isBuiltin: true,
                isMain: true,
                isInMirrorSet: false
            ),
            triggerWidth: triggerWidth,
            verticalTriggerReach: verticalTriggerReach,
            enableBelowTrigger: enableBelowTrigger
        )
    }
}
