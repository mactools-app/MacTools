import XCTest
@testable import MacTools
@testable import CalendarPlugin

final class CalendarEventGrouperTests: XCTestCase {
    func testGroupsAllDayTimedAndCrossDayEventsByOverlappingDates() throws {
        let calendar = Self.makeCalendar()
        let april1 = try Self.date(year: 2026, month: 4, day: 1, hour: 0, calendar: calendar)
        let april2 = try Self.date(year: 2026, month: 4, day: 2, hour: 0, calendar: calendar)
        let april3 = try Self.date(year: 2026, month: 4, day: 3, hour: 0, calendar: calendar)
        let visibleDates = [april1, april2, april3]
        let events = [
            CalendarEventInput(
                id: "timed",
                title: "Timed",
                startDate: try Self.date(year: 2026, month: 4, day: 1, hour: 10, calendar: calendar),
                endDate: try Self.date(year: 2026, month: 4, day: 1, hour: 11, calendar: calendar),
                isAllDay: false,
                color: .accent
            ),
            CalendarEventInput(
                id: "all-day",
                title: "All Day",
                startDate: april2,
                endDate: april3,
                isAllDay: true,
                color: .accent
            ),
            CalendarEventInput(
                id: "cross-day",
                title: "Cross Day",
                startDate: try Self.date(year: 2026, month: 4, day: 1, hour: 23, calendar: calendar),
                endDate: try Self.date(year: 2026, month: 4, day: 3, hour: 1, calendar: calendar),
                isAllDay: false,
                color: .accent
            )
        ]

        let grouped = CalendarEventGrouper.group(events: events, visibleDates: visibleDates, calendar: calendar)

        XCTAssertEqual(grouped[april1]?.map(\.title), ["Timed", "Cross Day"])
        XCTAssertEqual(grouped[april2]?.map(\.title), ["All Day", "Cross Day"])
        XCTAssertEqual(grouped[april3]?.map(\.title), ["Cross Day"])
    }

    func testZeroDurationEventsRemainVisibleOnStartDay() throws {
        let calendar = Self.makeCalendar()
        let april2 = try Self.date(year: 2026, month: 4, day: 2, hour: 0, calendar: calendar)
        let noon = try Self.date(year: 2026, month: 4, day: 2, hour: 12, calendar: calendar)
        let event = CalendarEventInput(
            id: "zero",
            title: "Zero",
            startDate: noon,
            endDate: noon,
            isAllDay: false,
            color: .accent
        )

        let grouped = CalendarEventGrouper.group(events: [event], visibleDates: [april2], calendar: calendar)

        XCTAssertEqual(grouped[april2]?.map(\.title), ["Zero"])
    }

    func testRemindersKeepTheirKindAndAllDayPresentation() throws {
        let calendar = Self.makeCalendar()
        let april2 = try Self.date(year: 2026, month: 4, day: 2, hour: 0, calendar: calendar)
        let reminder = CalendarEventInput(
            id: "reminder",
            title: "Pay bill",
            startDate: april2,
            endDate: try Self.date(year: 2026, month: 4, day: 2, hour: 0, minute: 1, calendar: calendar),
            isAllDay: true,
            color: .accent,
            calendarTitle: "Home",
            kind: .reminder
        )

        let grouped = CalendarEventGrouper.group(events: [reminder], visibleDates: [april2], calendar: calendar)
        let summary = try XCTUnwrap(grouped[april2]?.first)

        XCTAssertEqual(summary.kind, .reminder)
        XCTAssertEqual(summary.timeText, "全天")
        XCTAssertEqual(summary.calendarTitle, "Home")
    }

    func testCompletedRemindersAreMarkedAndSortLast() throws {
        let calendar = Self.makeCalendar()
        let april2 = try Self.date(year: 2026, month: 4, day: 2, hour: 0, calendar: calendar)
        let completed = CalendarEventInput(
            id: "completed",
            title: "Done",
            startDate: april2,
            endDate: try Self.date(year: 2026, month: 4, day: 2, hour: 0, minute: 1, calendar: calendar),
            isAllDay: true,
            color: .accent,
            kind: .reminder,
            isCompleted: true
        )
        let pending = CalendarEventInput(
            id: "pending",
            title: "Pending",
            startDate: april2,
            endDate: try Self.date(year: 2026, month: 4, day: 2, hour: 0, minute: 1, calendar: calendar),
            isAllDay: true,
            color: .accent,
            kind: .reminder
        )

        let grouped = CalendarEventGrouper.group(
            events: [completed, pending],
            visibleDates: [april2],
            calendar: calendar
        )
        let items = try XCTUnwrap(grouped[april2])

        XCTAssertEqual(items.map(\.title), ["Pending", "Done"])
        XCTAssertEqual(items.map(\.isCompleted), [false, true])
    }

    func testTimedReminderShowsOnlyStartTime() throws {
        let calendar = Self.makeCalendar()
        let april2 = try Self.date(year: 2026, month: 4, day: 2, hour: 0, calendar: calendar)
        let reminder = CalendarEventInput(
            id: "timed-reminder",
            title: "Call dentist",
            startDate: try Self.date(year: 2026, month: 4, day: 2, hour: 10, calendar: calendar),
            endDate: try Self.date(year: 2026, month: 4, day: 2, hour: 10, minute: 1, calendar: calendar),
            isAllDay: false,
            color: .accent,
            kind: .reminder
        )

        let grouped = CalendarEventGrouper.group(events: [reminder], visibleDates: [april2], calendar: calendar)
        let summary = try XCTUnwrap(grouped[april2]?.first)

        // A timed reminder has only a due time, so it must not render a range.
        XCTAssertFalse(summary.timeText.contains("–"), "Reminder must not show an end-time range")
        XCTAssertTrue(summary.timeText.contains("10:00"), "Reminder should show its start time")
        XCTAssertFalse(summary.timeText.contains("10:01"), "Reminder must not append a synthetic end time")
    }

    func testZeroDurationEventShowsOnlyStartTime() throws {
        let calendar = Self.makeCalendar()
        let april2 = try Self.date(year: 2026, month: 4, day: 2, hour: 0, calendar: calendar)
        let event = CalendarEventInput(
            id: "point-event",
            title: "Standup",
            startDate: try Self.date(year: 2026, month: 4, day: 2, hour: 9, calendar: calendar),
            endDate: try Self.date(year: 2026, month: 4, day: 2, hour: 9, calendar: calendar),
            isAllDay: false,
            color: .accent
        )

        let grouped = CalendarEventGrouper.group(events: [event], visibleDates: [april2], calendar: calendar)
        let summary = try XCTUnwrap(grouped[april2]?.first)

        // An event that has only a start time must not render a one-minute range.
        XCTAssertFalse(summary.timeText.contains("–"), "Start-only event must not show an end-time range")
        XCTAssertTrue(summary.timeText.contains("09:00"), "Start-only event should show its start time")
        XCTAssertFalse(summary.timeText.contains("09:01"), "Start-only event must not append a synthetic end time")
    }

    private static func makeCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func date(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int = 0,
        calendar: Calendar
    ) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute
        )))
    }
}
