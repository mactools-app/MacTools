import XCTest
@testable import IslandNotificationsPlugin

final class IslandNotificationHistoryTests: XCTestCase {
    /// Opening or clearing acts on the row in Notification Centre this matches, so a wrong match
    /// would open or delete a different notification.
    func testCentreRowMatchesOnlyTheSameAppTitleAndText() {
        let row = "Spark Desktop, 💬 Yannis › Please Respond: New Booking, Confirmed on Viator."
        XCTAssertTrue(IslandCenterMatch.row(row, matchesApp: "Spark Desktop", title: "💬 Yannis › Please Respond: New Booking",
                                            body: "Confirmed on Viator."))
        // Banners and Notification Centre may wrap or shorten the text differently.
        XCTAssertTrue(IslandCenterMatch.row(row, matchesApp: "Spark Desktop", title: "💬 Yannis › Please Respond: New Booking",
                                            body: "Confirmed\non Viator.…"))
        XCTAssertFalse(IslandCenterMatch.row(row, matchesApp: "Mail", title: "💬 Yannis › Please Respond: New Booking",
                                             body: "Confirmed on Viator."))
        XCTAssertFalse(IslandCenterMatch.row(row, matchesApp: "Spark Desktop", title: "💬 Yannis › Please Respond",
                                             body: "Confirmed on Viator."))
        XCTAssertFalse(IslandCenterMatch.row(row, matchesApp: "Spark Desktop", title: "💬 Yannis › Please Respond: New Booking",
                                             body: "Cancelled."))
        XCTAssertTrue(IslandCenterMatch.stack(row, isApp: "Spark Desktop"))
        XCTAssertFalse(IslandCenterMatch.stack(row, isApp: "Spark"))
    }

    /// Notification Centre separates the parts of a description the way the system language does.
    func testDescriptionsInOtherLanguagesStillMatchAndNameTheApp() {
        let rows = ["メッセージ、Alex、明日会える？", "信息，Alex，明日会える？",
                    "\u{200F}الرسائل،\u{200F} Alex،明日会える？"]
        for (row, app) in zip(rows, ["メッセージ", "信息", "الرسائل"]) {
            XCTAssertTrue(IslandCenterMatch.row(row, matchesApp: app, title: "Alex", body: "明日会える？"), row)
            XCTAssertTrue(IslandCenterMatch.stack(row, isApp: app), row)
            XCTAssertEqual(IslandNotification.appName(fromDescription: row, title: "Alex", body: "明日会える？"), app)
        }
        // The title inside the app's own name is not where the title starts.
        XCTAssertEqual(IslandNotification.appName(fromDescription: "Mail Plus, Mail, Hello", title: "Mail", body: "Hello"),
                       "Mail Plus")
        XCTAssertEqual(IslandNotification.appName(fromDescription: "Spark Desktop, Desktop, Hi", title: "Desktop", body: "Hi"),
                       "Spark Desktop")
    }

    @MainActor
    func testListGroupsByAppNewestFirstAndKeepsALimit() {
        let history = IslandNotificationHistory()
        func entry(_ app: String, _ title: String) -> IslandHistoryEntry {
            IslandHistoryEntry(date: Date(), appName: app, centerApp: app, appURL: nil, bundleIdentifier: app,
                               title: title, body: "", claudeChat: nil, lineCount: 2)
        }
        history.add(entry("Mail", "1"))
        history.add(entry("Messages", "2"))
        history.add(entry("Mail", "3"))
        let groups = IslandNotificationHistory.groups(history.entries)
        XCTAssertEqual(groups.map(\.id), ["Mail", "Messages"])
        XCTAssertEqual(groups[0].entries.map(\.title), ["3", "1"])
        for index in 0..<(IslandNotificationHistory.limit + 5) { history.add(entry("Mail", "\(index)")) }
        XCTAssertEqual(history.entries.count, IslandNotificationHistory.limit)
    }
}
