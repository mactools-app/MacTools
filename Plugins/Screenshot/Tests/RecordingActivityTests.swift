import AppKit
import XCTest
@testable import ScreenshotPlugin

@MainActor
final class RecordingActivityTests: XCTestCase {
    func testQuartzCoordinatesHandleCropsAndDisplaysAboveAndLeftOfPrimary() {
        for origin in [CGPoint.zero, CGPoint(x: -1920, y: -1080), CGPoint(x: 1512, y: 200)] {
            let coordinates = RecordingCoordinates(
                displayBounds: CGRect(origin: origin, size: CGSize(width: 1920, height: 1080)),
                sourceRect: CGRect(x: 100, y: 50, width: 800, height: 600))
            XCTAssertEqual(coordinates.normalize(CGPoint(x: origin.x + 100, y: origin.y + 50)), .zero)
            XCTAssertEqual(coordinates.normalize(CGPoint(x: origin.x + 500, y: origin.y + 350)), CGPoint(x: 0.5, y: 0.5))
            XCTAssertNil(coordinates.normalize(CGPoint(x: origin.x + 99, y: origin.y + 50)))
            XCTAssertNil(coordinates.normalize(CGPoint(x: CGFloat.nan, y: 0)))
        }
    }

    func testPointerMovementDoesNotSuppressDeliberateScrolling() throws {
        let activity = RecordingActivity(displayBounds: CGRect(x: 0, y: 0, width: 800, height: 600),
                                         sourceRect: CGRect(x: 0, y: 0, width: 800, height: 600))
        for index in 0..<10 {
            let time = 1 + Double(index) * 0.06
            let point = CGPoint(x: 100 + index * 8, y: 100)
            let move = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                             mouseCursorPosition: point, mouseButton: .left))
            move.timestamp = UInt64(time * 1_000_000_000)
            activity.receive(try XCTUnwrap(NSEvent(cgEvent: move)))
            let scroll = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                               wheel1: 10, wheel2: 0, wheel3: 0))
            scroll.location = point
            scroll.timestamp = UInt64((time + 0.01) * 1_000_000_000)
            activity.receive(try XCTUnwrap(NSEvent(cgEvent: scroll)))
        }
        let events = activity.snapshot(startTime: 0)
        XCTAssertEqual(events.filter { $0.kind == .scroll }.count, 10)
        XCTAssertTrue(RecordingZoomPlan(events: events, duration: 5).hasZoom)
    }

    func testEventsAreRelativeToTheFirstVideoFrame() {
        let events: [RecordingZoomEvent] = [
            .init(time: 100, kind: .click, point: .zero),
            .init(time: 102, kind: .click, point: CGPoint(x: 0.2, y: 0.3)),
            .init(time: .nan, kind: .reset),
        ]
        let result = RecordingActivity.relativeEvents(events, startTime: 101.5)
        XCTAssertEqual(result.map(\.time), [0.5])
        XCTAssertTrue(RecordingActivity.relativeEvents(events, startTime: .nan).isEmpty)
    }

    func testSwitchingWindowsResetsButMenusKeepTheCurrentInteraction() {
        let activity = RecordingActivity(displayBounds: CGRect(x: 0, y: 0, width: 800, height: 600),
                                         sourceRect: CGRect(x: 0, y: 0, width: 800, height: 600))
        let point = CGPoint(x: 0.5, y: 0.5)
        activity.receiveClick(at: 1, point: point, window: 1)
        let menu = RecordingActivity.ordinaryWindow(at: CGPoint(x: 100, y: 100),
                                                    windows: [window(id: 3, layer: 101), window(id: 1)])
        XCTAssertNil(menu)
        activity.receiveClick(at: 2, point: point, window: menu)
        let other = RecordingActivity.ordinaryWindow(at: CGPoint(x: 100, y: 100), eventWindow: 2,
                                                     windows: [window(id: 1), window(id: 2)])
        activity.receiveClick(at: 3, point: point, window: other)
        XCTAssertEqual(activity.snapshot(startTime: 0).map(\.kind), [.click, .click, .reset])
    }

    private func window(id: CGWindowID, layer: Int = 0) -> [String: Any] {
        [kCGWindowNumber as String: NSNumber(value: id), kCGWindowLayer as String: layer,
         kCGWindowBounds as String: CGRect(x: 0, y: 0, width: 200, height: 200).dictionaryRepresentation]
    }
}
