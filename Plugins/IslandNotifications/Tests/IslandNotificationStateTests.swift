import XCTest
import ApplicationServices
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

    func testOnlyMacToolsOwnBannerShowingAClaudeTurnBecomesItsCard() {
        var posts = IslandClaudePosts()
        let chat = IslandClaudeChat(localID: "local_a", title: "Fix the build")
        let reply = "Done. The build passes:\n\nall 42 tests green."
        posts.add(chat, message: reply, posted: reply, requestID: "r1", at: 100)
        // A banner with its preview hidden shows neither the chat's title nor the reply.
        XCTAssertNil(posts.take(title: "MacTools", body: "Notification", fromMacTools: true, at: 101))
        // Another app's banner with the same title and text is not this turn.
        XCTAssertNil(posts.take(title: "Fix the build", body: "Done. The build passes: all 42 tests green.", fromMacTools: false, at: 101))
        // MacTools' own banner with other text is not this turn.
        XCTAssertNil(posts.take(title: "Fix the build", body: "Something else entirely", fromMacTools: true, at: 101))
        // The banner shortens and rewraps the reply; it still names the turn, once.
        XCTAssertEqual(posts.take(title: "Fix the build", body: "Done. The build passes: all 42…", fromMacTools: true, at: 102)?.chat, chat)
        XCTAssertNil(posts.take(title: "Fix the build", body: "Done. The build passes: all 42…", fromMacTools: true, at: 102))
    }

    func testAShortBannerMustShowTheWholePostedText() {
        var posts = IslandClaudePosts()
        let chat = IslandClaudeChat(localID: "local_a", title: "Notes")
        posts.add(chat, message: "Done. I saved the notes and the summary.", posted: "Done. I saved the notes and the summary.",
                  requestID: "r1", at: 0)
        // "Notes / Done." from anywhere, even MacTools, is not this turn: it shows only the start.
        XCTAssertNil(posts.take(title: "Notes", body: "Done.", fromMacTools: true, at: 1))
        XCTAssertNil(posts.take(title: "Notes", body: "Done.…", fromMacTools: true, at: 1))
        XCTAssertEqual(posts.take(title: "Notes", body: "Done. I saved the notes and the summary.", fromMacTools: true, at: 1)?.chat, chat)
    }

    func testTwoWaitingTurnsABannerCouldBeAreNeitherTaken() {
        var posts = IslandClaudePosts()
        let first = IslandClaudeChat(localID: "local_a", title: "Notes")
        let second = IslandClaudeChat(localID: "local_b", title: "Notes")
        posts.add(first, message: "Done. The first summary is ready.", posted: "Done. The first summary is ready.", requestID: "r1", at: 0)
        posts.add(second, message: "Done. The first draft is ready.", posted: "Done. The first draft is ready.", requestID: "r2", at: 0)
        // Shortened to a start both share: no card takes either reply.
        XCTAssertNil(posts.take(title: "Notes", body: "Done. The first…", fromMacTools: true, at: 1))
        XCTAssertEqual(posts.posts.count, 2)
        // The whole text tells them apart.
        XCTAssertEqual(posts.take(title: "Notes", body: "Done. The first draft is ready.", fromMacTools: true, at: 1)?.chat, second)
    }

    func testAReplysThinkingLineIsNotTheReply() {
        // Claude writes a reply with thinking as two turn-ending lines: the thinking, then the text.
        XCTAssertNil(IslandClaudeTranscriptReader.replyText([["type": "thinking", "thinking": "…"]], lastMessage: { "Earlier reply" }))
        XCTAssertEqual(IslandClaudeTranscriptReader.replyText([["type": "text", "text": "The reply"]], lastMessage: { nil }), "The reply")
        // A turn that ends after tools, with no text of its own, reports the last reply.
        XCTAssertEqual(IslandClaudeTranscriptReader.replyText([], lastMessage: { "Last reply" }), "Last reply")
    }

    func testAReplyAlreadyWaitingIsNotPostedAgainAndTwoChatsAreNotGuessed() {
        var posts = IslandClaudePosts()
        let chat = IslandClaudeChat(localID: "local_a", title: "Notes")
        let reply = "You're right, the threshold was too high."
        posts.add(chat, message: reply, posted: reply, requestID: "r1", at: 0)
        // The controller doesn't post a reply that already waits, so it shows once.
        XCTAssertTrue(posts.isWaiting(chat, message: reply))
        XCTAssertFalse(posts.isWaiting(IslandClaudeChat(localID: "local_b", title: "Notes"), message: reply))
        XCTAssertEqual(posts.take(title: "Notes", body: reply, fromMacTools: true, at: 1)?.requestID, "r1")
        // The same reply from two different chats with one title: neither is taken.
        posts.add(chat, message: reply, posted: reply, requestID: "r3", at: 2)
        posts.add(IslandClaudeChat(localID: "local_b", title: "Notes"), message: reply, posted: reply, requestID: "r4", at: 2)
        XCTAssertNil(posts.take(title: "Notes", body: reply, fromMacTools: true, at: 3))
    }

    func testAClaudeTurnMacOSRefusedOrThatNeverShowedIsNotTaken() {
        var posts = IslandClaudePosts()
        posts.add(IslandClaudeChat(localID: "local_a", title: "Notes"), message: "Saved the file.", posted: "Saved the file.",
                  requestID: "r1", at: 0)
        posts.remove(requestID: "r1")
        XCTAssertNil(posts.take(title: "Notes", body: "Saved the file.", fromMacTools: true, at: 1))
        posts.add(IslandClaudeChat(localID: "local_a", title: "Notes"), message: "Saved the file.", posted: "Saved the file.",
                  requestID: "r2", at: 0)
        // Focus kept the banner from showing; a later banner with the same text is not this turn.
        XCTAssertNil(posts.take(title: "Notes", body: "Saved the file.", fromMacTools: true, at: IslandClaudePosts.wait + 1))
    }

    func testABannerMatchesOnlyTheStartOfAMessageWhenMacOSShortenedIt() {
        typealias Banner = IslandMessagesChat.BannerText
        // A whole banner is not the start of someone else's longer message.
        let full = Banner(body: "See you tomorrow", isGroup: false)
        XCTAssertTrue(full.matches("See you tomorrow"))
        XCTAssertFalse(full.matches("See you tomorrow at noon"))
        // Shortened with "…", or cut at the 1,024-character limit, a long enough start counts.
        XCTAssertTrue(Banner(body: "See you tomorrow at the…", isGroup: false).matches("See you tomorrow at the station"))
        let long = String(repeating: "word ", count: 300)
        XCTAssertTrue(Banner(body: String(long.prefix(1024)), isGroup: false).matches(long))
        XCTAssertFalse(Banner(body: "Hi…", isGroup: false).matches("Hi there, how are you?"))
    }

    func testAGroupBannersMessageMatchesWithoutTheGroupsName() {
        let banner = IslandMessagesChat.BannerText(body: "The team\nFirst line\nsecond line", isGroup: true)
        XCTAssertTrue(banner.matches("First line\nsecond line"))
        XCTAssertFalse(banner.matches("First line and more"))
        // A photo's placeholder in the message is not text the banner shows.
        XCTAssertTrue(IslandMessagesChat.BannerText(body: "Look at this", isGroup: false).matches("\u{FFFC}Look at this"))
    }

    func testUntilTheHistoryHasSettledOnlyMessagesFromAroundTheArrivalCount() {
        let arrival = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let window = IslandMessagesChat.dateWindow(around: arrival, recentOnly: true)
        let nanoseconds = { (offset: TimeInterval) in Int64((arrival.timeIntervalSinceReferenceDate + offset) * 1_000_000_000) }
        XCTAssertTrue(window.contains(nanoseconds(-20)))
        XCTAssertTrue(window.contains(nanoseconds(25)))
        // Someone else's identical message from three minutes earlier is not this banner's.
        XCTAssertFalse(window.contains(nanoseconds(-180)))
    }

    func testAClaudeCardsBannerIsNotTakenForANewerNotification() {
        let element = AXUIElementCreateApplication(getpid())
        // The card shows the whole reply; its banner showed the start.
        let card = IslandNotification(element: element, window: element, originalPosition: .zero, style: .temporary,
                                      title: "Notes", body: "Done. The whole reply, with every paragraph.",
                                      identityHints: [], bannerTitle: "Notes", bannerBody: "Done. The whole…")
        XCTAssertFalse(card.bannerChanged(title: "Notes", body: "Done. The whole…"))
        XCTAssertTrue(card.bannerChanged(title: "Notes", body: "Something newer"))
    }

    @MainActor
    func testAnAlertAdoptedFromBeforeMacToolsSawItHasNoMessagesReply() {
        let element = AXUIElementCreateApplication(getpid())
        let notification = IslandNotification(element: element, window: element, originalPosition: .zero, style: .persistent,
                                              title: "Alice", body: "See you there", identityHints: [])
        notification.appURL = URL(fileURLWithPath: "/System/Applications/Messages.app")
        XCTAssertEqual(notification.canReply, IslandMessagesChat.isAvailable)
        notification.arrivalConfirmed = false
        XCTAssertFalse(notification.canReply)
    }
}
