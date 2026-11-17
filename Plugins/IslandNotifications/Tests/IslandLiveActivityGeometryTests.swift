import XCTest
@testable import IslandNotificationsPlugin

final class IslandLiveActivityGeometryTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1732, height: 1120)
    private let anchor = CGRect(x: 836, y: 1080, width: 60, height: 40)
    private let activityAX = CGRect(x: 799, y: 6, width: 134, height: 34)

    func testPlacementConvertsAXAndAttachesBehindAnActualCapsule() {
        XCTAssertEqual(resolve([]), .camera)
        XCTAssertEqual(resolve([activityAX]), .split(CGRect(x: 799, y: 1080, width: 134, height: 34)))
        // Reported MenuBarAgent geometry: only the 134x34 child is an activity;
        // the 1736x1133 AXUnknown window is a structural wrapper.
        let probeScreen = CGRect(x: 0, y: 0, width: 1736, height: 1133)
        XCTAssertEqual(IslandLiveActivityPlacement.resolve(axFrames: [activityAX], complete: true,
            desktopTop: 1133, screen: probeScreen, anchor: anchor.offsetBy(dx: 0, dy: 13)),
            .split(CGRect(x: 799, y: 1093, width: 134, height: 34)))
        let second = CGRect(x: 940, y: 6, width: 40, height: 34)
        XCTAssertEqual(resolve([activityAX, second]), resolve([activityAX]))
        let lower = CGRect(x: 940, y: 6, width: 70, height: 40)
        XCTAssertEqual(resolve([activityAX, lower]), .split(CGRect(x: 940, y: 1074, width: 70, height: 40)))
        XCTAssertEqual(resolve([CGRect(x: -1000, y: 6, width: 134, height: 34)]), .camera)
        // AX's desktop origin stays on the primary screen with another screen above it.
        let upperScreen = CGRect(x: 0, y: 1120, width: 1732, height: 1120)
        XCTAssertEqual(IslandLiveActivityPlacement.resolve(axFrames: [CGRect(x: 799, y: -1114, width: 134, height: 34)],
            complete: true, desktopTop: 1120, screen: upperScreen, anchor: anchor.offsetBy(dx: 0, dy: 1120)),
            .split(CGRect(x: 799, y: 2200, width: 134, height: 34)))
    }

    func testUnreadableExpandedAndInvalidActivitiesKeepNativeBanners() {
        XCTAssertEqual(resolve([nil]), .native)
        XCTAssertEqual(resolve([activityAX], complete: false), .native)
        for frame in [CGRect(x: 799, y: 6, width: 134, height: 61),
                      CGRect(x: 799, y: 6, width: 0, height: 34),
                      CGRect(x: 799, y: 6, width: CGFloat.infinity, height: 34),
                      CGRect(x: 799, y: 200, width: 134, height: 34)] {
            XCTAssertEqual(resolve([frame]), .native)
        }
    }

    func testSplitStartsOccludedThenConnectsAndDetachesAndCanReverse() {
        let geometry = IslandSplitGeometry(activity: CGRect(x: 799, y: 1080, width: 134, height: 34),
                                           expandedSize: CGSize(width: 370, height: 80))
        XCTAssertEqual(geometry.capsule(widthFraction: 0, heightFraction: 0), geometry.source)
        XCTAssertEqual(geometry.capsule(widthFraction: 1, heightFraction: 1), geometry.destination)
        XCTAssertEqual(geometry.source.minY - geometry.destination.maxY, IslandSplitGeometry.gap)
        let pouring = geometry.capsule(widthFraction: 0.8, heightFraction: 0.7)
        let bridgePoint = CGPoint(x: geometry.source.midX, y: (geometry.source.minY + pouring.maxY) / 2)
        XCTAssertLessThan(pouring.maxY, geometry.source.minY)
        XCTAssertTrue(geometry.path(widthFraction: 0.8, heightFraction: 0.7).contains(bridgePoint))
        let gapPoint = CGPoint(x: geometry.source.midX, y: (geometry.source.minY + geometry.destination.maxY) / 2)
        XCTAssertFalse(geometry.path(widthFraction: 1, heightFraction: 1).contains(gapPoint))
        XCTAssertGreaterThan(geometry.neckWidth(heightFraction: 0.7, reduceMotion: false),
                             geometry.neckWidth(heightFraction: 0.9, reduceMotion: false))
        XCTAssertEqual(geometry.neckWidth(heightFraction: 0.7, reduceMotion: true), 0)
        XCTAssertFalse(geometry.path(widthFraction: 0.8, heightFraction: 0.7, reduceMotion: true).contains(gapPoint))
        var closing = NotchMorphModel()
        closing.target = 1; closing.snapToTarget(); closing.target = 0
        while closing.height.value > 0.8 { closing.advance(by: 1.0 / 480.0) }
        let reconnecting = geometry.capsule(widthFraction: closing.width.value, heightFraction: closing.height.value)
        let reconnectPoint = CGPoint(x: geometry.source.midX, y: (geometry.source.minY + reconnecting.maxY) / 2)
        XCTAssertLessThan(reconnecting.maxY, geometry.source.minY)
        XCTAssertTrue(geometry.path(widthFraction: closing.width.value, heightFraction: closing.height.value).contains(reconnectPoint))
    }

    private func resolve(_ frames: [CGRect?], complete: Bool = true) -> IslandLiveActivityPlacement {
        .resolve(axFrames: frames, complete: complete, desktopTop: 1120, screen: screen, anchor: anchor)
    }
}
