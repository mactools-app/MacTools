import CoreGraphics
import XCTest
@testable import ScreenshotPlugin

final class RecordingZoomTests: XCTestCase {
    private let full = CGRect(x: 0, y: 0, width: 1, height: 1)
    private let center = CGPoint(x: 0.5, y: 0.5)

    func testClickEntersSmoothlyAndReturnsToOverviewAfterInactivity() {
        let plan = RecordingZoomPlan(events: [
            .init(time: 1, kind: .click, point: center), .init(time: 1.1, kind: .release)
        ], duration: 5)
        XCTAssertTrue(plan.hasZoom)
        XCTAssertEqual(plan.crop(at: 1), full)
        XCTAssertLessThan(plan.crop(at: 1.15).width, 1)
        XCTAssertGreaterThan(plan.crop(at: 1.15).width, 0.625)
        XCTAssertEqual(plan.crop(at: 1.5).width, 0.625, accuracy: 0.000001)
        XCTAssertEqual(plan.crop(at: 3.7), full)
    }

    func testInputEventsNeverRestartOrReverseCameraVelocity() {
        let traces: [[RecordingZoomEvent]] = [
            [.init(time: 1, kind: .click, point: center),
             .init(time: 1.15, kind: .move, point: CGPoint(x: 0.85, y: 0.5))],
            [.init(time: 1, kind: .click, point: center), .init(time: 1.05, kind: .release),
             .init(time: 1.18, kind: .click, point: CGPoint(x: 0.65, y: 0.5))],
            [.init(time: 1, kind: .click, point: center), .init(time: 1.18, kind: .reset)],
        ]
        let epsilon = 0.00001
        for events in traces {
            let plan = RecordingZoomPlan(events: events, duration: 6)
            for time in events.flatMap({ event in (0...6).map { event.time + Double($0) / 60 } }) {
                let before = plan.crop(at: time - epsilon), current = plan.crop(at: time), after = plan.crop(at: time + epsilon)
                for (a, b, c) in [(before.midX, current.midX, after.midX), (before.width, current.width, after.width)] {
                    XCTAssertLessThan(abs((c - b) / epsilon - (b - a) / epsilon), 0.01)
                }
            }
        }
    }

    func testHeldDragOutlivesTheIdleTimeoutAndResetReturnsToOverview() {
        let events: [RecordingZoomEvent] = [
            .init(time: 1, kind: .click, point: center),
            .init(time: 4, kind: .move, point: CGPoint(x: 0.9, y: 0.1)),
            .init(time: 5, kind: .release),
        ]
        let plan = RecordingZoomPlan(events: events, duration: 9)
        XCTAssertEqual(plan.crop(at: 4.5).width, 0.625)
        XCTAssertEqual(plan.crop(at: 6.5).width, 0.625)
        XCTAssertEqual(plan.crop(at: 7.6), full)

        let reset = RecordingZoomPlan(events: events + [.init(time: 4.2, kind: .reset)], duration: 9)
        XCTAssertEqual(reset.crop(at: 4.8), full)
    }

    func testDenseDragKeepsTheCursorInsideTheCrop() {
        var events: [RecordingZoomEvent] = [.init(time: 1, kind: .click, point: CGPoint(x: 0.1, y: 0.5))]
        for index in 0...20 {
            events.append(.init(time: 2 + Double(index) * 0.05, kind: .move,
                                point: CGPoint(x: 0.1 + Double(index) * 0.04, y: 0.5)))
        }
        let plan = RecordingZoomPlan(events: events, duration: 6)
        for event in events.dropFirst() {
            XCTAssertTrue(plan.crop(at: event.time).contains(event.point!))
        }
    }

    func testInvalidEventsAreIgnoredAndCropsStayInsideTheRecording() {
        let invalid: [RecordingZoomEvent] = [
            .init(time: .nan, kind: .click, point: center),
            .init(time: -1, kind: .click, point: center),
            .init(time: 1, kind: .click, point: CGPoint(x: 1.1, y: 0)),
            .init(time: 1, kind: .click),
            .init(time: 20, kind: .click, point: center),
        ]
        XCTAssertFalse(RecordingZoomPlan(events: invalid, duration: 5).hasZoom)
        XCTAssertFalse(RecordingZoomPlan(events: [.init(time: 0, kind: .click, point: center)], duration: 0.2).hasZoom,
                       "A clip too short to enter and leave keeps the full view")

        let plan = RecordingZoomPlan(events: [
            .init(time: 0, kind: .click, point: CGPoint(x: 0, y: 1)),
            .init(time: 0, kind: .release),
            .init(time: 1, kind: .scroll, point: CGPoint(x: 1, y: 0)),
        ] + invalid, duration: 5)
        for step in 0...150 {
            let crop = plan.crop(at: Double(step) / 30)
            XCTAssertTrue(crop.minX >= 0 && crop.minY >= 0 && crop.maxX <= 1.000001 && crop.maxY <= 1.000001)
            XCTAssertTrue(crop.width >= 0.625 && crop.width <= 1 && crop.width == crop.height)
        }
        XCTAssertEqual(plan.crop(at: 3.6), full, "A same-time release must not leave the button held")
    }
}
