import CoreGraphics
import XCTest
@testable import DockClickMinimizePlugin

final class DockClickGestureTrackerTests: XCTestCase {
    private let previousApp = DockFrontmostApplication(bundleIdentifier: "test.previous", processIdentifier: 1)
    private let destinationApp = DockFrontmostApplication(bundleIdentifier: "test.destination", processIdentifier: 2)

    func testDelayedSwitchIsRejectedRegardlessOfActivationNotificationOrder() throws {
        for notificationArrived in [false, true] {
            var tracker = DockClickGestureTracker()
            tracker.reset(frontmostApplication: previousApp, at: 1_000_000_000)
            let down = try event(.leftMouseDown, at: 2_000_000_000)
            let up = try event(.leftMouseUp, at: 2_100_000_000)
            if notificationArrived {
                tracker.reset(frontmostApplication: destinationApp, at: 2_200_000_000)
            }

            // Dock has already activated the destination before either callback runs.
            XCTAssertNil(tracker.handle(type: .leftMouseDown, event: down,
                                        frontmostApplication: destinationApp, observedAt: 3_000_000_000))
            XCTAssertNil(tracker.handle(type: .leftMouseUp, event: up,
                                        frontmostApplication: destinationApp, observedAt: 3_000_000_000))
        }
    }

    func testEstablishedActiveApplicationClickCompletesExactlyOnceDespiteDelayedDelivery() throws {
        var tracker = DockClickGestureTracker()
        tracker.reset(frontmostApplication: destinationApp, at: 1_000_000_000)
        let down = try event(.leftMouseDown, at: 2_000_000_000)
        let up = try event(.leftMouseUp, at: 2_100_000_000)

        XCTAssertNil(tracker.handle(type: .leftMouseDown, event: down,
                                    frontmostApplication: destinationApp, observedAt: 3_000_000_000))
        XCTAssertEqual(tracker.handle(type: .leftMouseUp, event: up,
                                      frontmostApplication: destinationApp, observedAt: 3_000_000_000), destinationApp)
        XCTAssertNil(tracker.handle(type: .leftMouseUp, event: up,
                                    frontmostApplication: destinationApp, observedAt: 3_000_000_000))
    }

    func testApplicationChangeDuringClickCancelsEvenAfterReturning() throws {
        var tracker = DockClickGestureTracker()
        tracker.reset(frontmostApplication: previousApp, at: 1_000_000_000)
        _ = tracker.handle(type: .leftMouseDown, event: try event(.leftMouseDown, at: 2_000_000_000),
                           frontmostApplication: previousApp, observedAt: 2_000_000_001)
        tracker.reset(frontmostApplication: destinationApp, at: 2_010_000_000)
        tracker.reset(frontmostApplication: previousApp, at: 2_020_000_000)

        XCTAssertNil(tracker.handle(type: .leftMouseUp, event: try event(.leftMouseUp, at: 2_100_000_000),
                                    frontmostApplication: previousApp, observedAt: 2_100_000_001))
    }

    func testModifiedClicksDragsAndQueuedLongPressesAreRejected() throws {
        let rejectedGestures: [(downFlags: CGEventFlags, upFlags: CGEventFlags, drag: Bool, duration: UInt64)] = [
            (.maskCommand, [], false, 100_000_000),
            ([], .maskAlternate, false, 100_000_000),
            (.maskControl, [], false, 100_000_000),
            ([], .maskShift, false, 100_000_000),
            ([], [], true, 100_000_000),
            ([], [], false, 500_000_000),
        ]
        for gesture in rejectedGestures {
            var tracker = DockClickGestureTracker()
            tracker.reset(frontmostApplication: previousApp, at: 1_000_000_000)
            let down = try event(.leftMouseDown, at: 2_000_000_000, flags: gesture.downFlags)
            let up = try event(.leftMouseUp, at: 2_000_000_000 + gesture.duration, flags: gesture.upFlags)
            _ = tracker.handle(type: .leftMouseDown, event: down,
                               frontmostApplication: previousApp, observedAt: 3_000_000_000)
            if gesture.drag {
                _ = tracker.handle(type: .leftMouseDragged,
                                   event: try event(.leftMouseDragged, at: 2_050_000_000, location: CGPoint(x: 20, y: 20)),
                                   frontmostApplication: previousApp, observedAt: 3_000_000_000)
            }

            // Both callbacks run together; duration must still come from the events.
            XCTAssertNil(tracker.handle(type: .leftMouseUp, event: up,
                                        frontmostApplication: previousApp, observedAt: 3_000_000_000))
        }
    }

    func testClickPredatingMonitoringOrRecoveryIsRejected() throws {
        var tracker = DockClickGestureTracker()
        let down = try event(.leftMouseDown, at: 2_000_000_000)
        tracker.reset(frontmostApplication: previousApp, at: down.timestamp)
        _ = tracker.handle(type: .leftMouseDown, event: down,
                           frontmostApplication: previousApp, observedAt: 3_000_000_000)

        XCTAssertNil(tracker.handle(type: .leftMouseUp, event: try event(.leftMouseUp, at: 2_100_000_000),
                                    frontmostApplication: previousApp, observedAt: 3_000_000_000))
    }

    private func event(
        _ type: CGEventType,
        at timestamp: CGEventTimestamp,
        flags: CGEventFlags = [],
        location: CGPoint = .zero
    ) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: type,
                                         mouseCursorPosition: location, mouseButton: .left))
        event.timestamp = timestamp
        event.flags = flags
        return event
    }
}
