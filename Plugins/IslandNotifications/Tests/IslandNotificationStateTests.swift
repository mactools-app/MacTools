import XCTest
@testable import IslandNotificationsPlugin

final class IslandNotificationStateTests: XCTestCase {
    func testFIFOBlocksForHoverPanelAndKeepsCurrentUntilFinished() {
        var queue = IslandNotificationQueue<String>()
        queue.append("first"); queue.append("second")
        XCTAssertNil(queue.presentNext(blocked: true))
        XCTAssertEqual(queue.waiting.count, 2)
        XCTAssertEqual(queue.presentNext(blocked: false), "first")
        XCTAssertNil(queue.presentNext(blocked: false))
        queue.finish()
        XCTAssertEqual(queue.presentNext(blocked: false), "second")
        queue.removeAll()
        XCTAssertNil(queue.current)
        XCTAssertTrue(queue.waiting.isEmpty)
    }

    func testOnlyKnownBannerStylesMayMoveAndAllSafetyGatesAreRequired() {
        XCTAssertEqual(IslandNotificationStyle(subrole: "AXNotificationCenterBanner"), .temporary)
        XCTAssertEqual(IslandNotificationStyle(subrole: "AXNotificationCenterAlert"), .persistent)
        XCTAssertNil(IslandNotificationStyle(subrole: "AXNotificationCenter"))
        XCTAssertTrue(IslandMovePolicy.allowsMove(enabled: true, trusted: true, hasNotch: true, notificationCount: 1, hasUnexpectedContent: false, complete: true))
        for gate in 0..<6 {
            XCTAssertFalse(IslandMovePolicy.allowsMove(enabled: gate != 0, trusted: gate != 1, hasNotch: gate != 2,
                                                     notificationCount: gate == 3 ? 0 : 1,
                                                     hasUnexpectedContent: gate == 4, complete: gate != 5))
        }
    }

    func testTemporaryTimePausesAndPersistentNeverExpires() {
        var temporary = IslandNotificationLifetime(style: .temporary, now: 10)
        XCTAssertFalse(temporary.advance(to: 12, paused: true))
        XCTAssertFalse(temporary.advance(to: 100, paused: true))
        XCTAssertEqual(temporary.remaining, 3)
        XCTAssertFalse(temporary.advance(to: 100, paused: false))
        XCTAssertFalse(temporary.advance(to: 102, paused: false))
        XCTAssertTrue(temporary.advance(to: 103, paused: false))
        var persistent = IslandNotificationLifetime(style: .persistent, now: 10)
        XCTAssertFalse(persistent.advance(to: 1000, paused: false))
        XCTAssertNil(persistent.remaining)
    }

    func testRestorePositionPreservesKnownOriginAndRecoversAnAlreadyHiddenWindow() {
        let normal = CGPoint(x: -8000, y: 400)
        let hidden = CGPoint(x: -108_000, y: -100_000)
        let original = CGPoint(x: -7900, y: 500)
        XCTAssertEqual(IslandMovePolicy.originalPosition(position: hidden, prior: nil, desktopMinX: -8000,
                                                         normalPosition: normal), normal)
        XCTAssertEqual(IslandMovePolicy.originalPosition(position: hidden, prior: original, desktopMinX: -8000,
                                                         normalPosition: normal), original)
        XCTAssertEqual(IslandMovePolicy.originalPosition(position: original, prior: nil, desktopMinX: -8000,
                                                         normalPosition: normal), original)
    }

    func testRecoveryRequiresOffscreenPositionAndSafeNotificationSnapshot() {
        let hidden = CGPoint(x: -108_000, y: -100_000)
        XCTAssertTrue(IslandMovePolicy.allowsRecovery(position: hidden, desktopMinX: -8000,
                                                     notificationCount: 1, hasUnexpectedContent: false, complete: true))
        for position in [nil, CGPoint(x: -13_000, y: 0), .zero, CGPoint(x: -.infinity, y: 0)] as [CGPoint?] {
            XCTAssertFalse(IslandMovePolicy.allowsRecovery(position: position, desktopMinX: -8000,
                                                          notificationCount: 1, hasUnexpectedContent: false, complete: true))
        }
        for gate in 0..<3 {
            XCTAssertFalse(IslandMovePolicy.allowsRecovery(position: hidden, desktopMinX: -8000,
                                                          notificationCount: gate == 0 ? 0 : 1,
                                                          hasUnexpectedContent: gate == 1, complete: gate != 2))
        }
    }
}
