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

    /// An archived string the way Messages stores one: the "NSString" class marker, then "+" and
    /// a length-prefixed UTF-8 run (one byte, or 0x81 and two bytes).
    private func archivedText(_ text: String) -> Data {
        let utf8 = Array(text.utf8)
        let length: [UInt8] = utf8.count < 0x80 ? [UInt8(utf8.count)] : [0x81, UInt8(utf8.count & 0xFF), UInt8(utf8.count >> 8)]
        return Data([0x04, 0x0B] + Array("streamtyped".utf8) + Array("NSString".utf8) + [0x01, 0x94, 0x84, 0x01, 0x2B] + length + utf8 + [0x86])
    }

    func testEditedMessageKeepsEveryVersionForMatchingTheBanner() throws {
        let original = "See you at the station"
        let edited = String(repeating: "Running late, ", count: 10) + original
        let info: [String: Any] = [
            "ec": ["0": [["t": archivedText(original), "d": 1.0], ["t": archivedText(edited), "d": 2.0]]],
            "ust": true
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
        XCTAssertEqual(IslandMessagesChat.editedVersions(data), [original, edited])
        XCTAssertEqual(IslandMessagesChat.attributedBodyText(archivedText(edited)), edited)
    }

    func testUneditedMessageHasNoEarlierVersions() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: ["amc": 0], format: .binary, options: 0)
        XCTAssertEqual(IslandMessagesChat.editedVersions(data), [])
        XCTAssertEqual(IslandMessagesChat.editedVersions(Data([0x00, 0x01])), [])
    }

    func testMessagesLookupWindowStaysFixedToTheBannersArrival() {
        let arrival = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let window = IslandMessagesChat.dateWindow(around: arrival)
        let nanoseconds = { (offset: TimeInterval) in Int64((arrival.timeIntervalSinceReferenceDate + offset) * 1_000_000_000) }
        XCTAssertTrue(window.contains(nanoseconds(-299)))
        XCTAssertTrue(window.contains(nanoseconds(25)))
        // A message from someone else ten minutes later never matches a card that is still open.
        XCTAssertFalse(window.contains(nanoseconds(600)))
        XCTAssertFalse(window.contains(nanoseconds(-301)))
    }

    func testClaudeChatIsUniqueOnlyWhileNoOtherChatHasItsTitle() {
        typealias Session = IslandClaudeTurnWatcher.DesktopSession
        let card = Session(localID: "local_a", title: "Fix the build", cliSessionIDs: ["cli-a"])
        let other = Session(localID: "local_b", title: "Notes", cliSessionIDs: ["cli-b"])
        let unique = IslandClaudeTurnWatcher.desktopChat(in: [card, other]) { $0.localID == "local_a" }
        XCTAssertEqual(unique?.title, "Fix the build")
        XCTAssertEqual(unique?.isUnique, true)
        // A chat opened later with the same title makes the card's chat ambiguous at send time.
        let later = Session(localID: "local_c", title: "Fix the build", cliSessionIDs: ["cli-c"])
        XCTAssertEqual(IslandClaudeTurnWatcher.desktopChat(in: [card, other, later]) { $0.localID == "local_a" }?.isUnique, false)
        // The session found by its Claude Code id, and a chat that has gone.
        XCTAssertEqual(IslandClaudeTurnWatcher.desktopChat(in: [card, other]) { $0.cliSessionIDs.contains("cli-b") }?.localID, "local_b")
        XCTAssertNil(IslandClaudeTurnWatcher.desktopChat(in: [other]) { $0.localID == "local_a" })
    }
}
