import EventKit
import XCTest
@testable import MacTools
@testable import CalendarPlugin

@MainActor
final class CalendarComponentViewModelTests: XCTestCase {
    func testChangingWeekStartReloadsEventsForNewGridRange() async throws {
        let calendar = Self.makeCalendar()
        let service = MockCalendarEventService()
        service.authorization = .fullAccess
        let targetDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 15)))
        let viewModel = CalendarComponentViewModel(
            eventService: service,
            holidayProvider: .empty,
            calendar: calendar,
            today: targetDate,
            now: { targetDate }
        )
        let sundayRequest = expectation(description: "Sunday-first event range loaded")
        service.onEventsRequest = sundayRequest.fulfill

        viewModel.start()
        await fulfillment(of: [sundayRequest], timeout: 1)

        let mondayRequest = expectation(description: "Monday-first event range loaded")
        service.onEventsRequest = mondayRequest.fulfill
        viewModel.setWeekStartDay(.monday)
        await fulfillment(of: [mondayRequest], timeout: 1)

        XCTAssertEqual(service.eventRanges.count, 2)
        XCTAssertEqual(
            service.eventRanges.map { CalendarComponentCalendars.dayID(for: $0.start, calendar: calendar) },
            ["20260329", "20260330"]
        )
        XCTAssertEqual(
            service.eventRanges.map { CalendarComponentCalendars.dayID(for: $0.end, calendar: calendar) },
            ["20260510", "20260511"]
        )
    }

    func testChangingWeekStartWhileStoppedDoesNotReloadEvents() async throws {
        let calendar = Self.makeCalendar()
        let service = MockCalendarEventService()
        service.authorization = .fullAccess
        let targetDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 15)))
        let viewModel = CalendarComponentViewModel(
            eventService: service,
            holidayProvider: .empty,
            calendar: calendar,
            today: targetDate,
            now: { targetDate }
        )
        let initialRequest = expectation(description: "Visible calendar loads events")
        service.onEventsRequest = initialRequest.fulfill
        viewModel.start()
        await fulfillment(of: [initialRequest], timeout: 1)
        viewModel.stop()

        let unexpectedRequest = expectation(description: "Hidden calendar should not load events")
        unexpectedRequest.isInverted = true
        service.onEventsRequest = unexpectedRequest.fulfill

        viewModel.setWeekStartDay(.monday)
        await fulfillment(of: [unexpectedRequest], timeout: 0.1)

        XCTAssertEqual(service.eventRanges.count, 1)
        XCTAssertEqual(viewModel.month.weekdaySymbols.first, "一")

        let resumedRequest = expectation(description: "Calendar reloads events when shown again")
        service.onEventsRequest = resumedRequest.fulfill
        viewModel.start()
        await fulfillment(of: [resumedRequest], timeout: 1)

        XCTAssertEqual(
            service.eventRanges.map { CalendarComponentCalendars.dayID(for: $0.start, calendar: calendar) },
            ["20260329", "20260330"]
        )
    }

    func testChangingWeekStartImmediatelyRebuildsMonthAndKeepsSelection() throws {
        let calendar = Self.makeCalendar()
        let service = MockCalendarEventService()
        let targetDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 15)))
        let viewModel = CalendarComponentViewModel(
            eventService: service,
            holidayProvider: .empty,
            calendar: calendar,
            today: targetDate
        )

        XCTAssertEqual(viewModel.month.days.first?.id, "20260329")
        XCTAssertEqual(viewModel.month.weekdaySymbols.first, "日")

        viewModel.setWeekStartDay(.monday)

        XCTAssertEqual(viewModel.month.days.first?.id, "20260330")
        XCTAssertEqual(viewModel.month.weekdaySymbols.first, "一")
        XCTAssertEqual(viewModel.selectedDay?.id, "20260415")
    }

    func testOpenSelectsDayAndDelegatesToSystemCalendar() throws {
        let calendar = Self.makeCalendar()
        let service = MockCalendarEventService()
        let targetDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 29)))
        let viewModel = CalendarComponentViewModel(
            eventService: service,
            holidayProvider: .empty,
            calendar: calendar,
            today: targetDate
        )
        let targetDay = CalendarDayModel(
            id: "20260429",
            date: targetDate,
            dayNumber: "29",
            alternateCalendarText: "十三",
            alternateCalendarDateText: "四月十三",
            isInDisplayedMonth: true,
            isToday: true,
            isWeekend: false,
            holidayKind: nil,
            events: []
        )

        viewModel.open(targetDay)

        XCTAssertEqual(viewModel.selectedDay?.id, "20260429")
        XCTAssertEqual(service.openedDates, [targetDate])
    }

    func testSelectingDayDoesNotChangeTheTodayDetailSource() throws {
        let calendar = Self.makeCalendar()
        let service = MockCalendarEventService()
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 15)))
        let targetDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 29)))
        let event = CalendarEventSummary(
            id: "event-1",
            title: "Planning",
            timeText: "10:00",
            startDate: targetDate,
            endDate: targetDate,
            isAllDay: false,
            color: .accent
        )
        let viewModel = CalendarComponentViewModel(
            eventService: service,
            holidayProvider: .empty,
            calendar: calendar,
            today: today
        )
        let targetDay = CalendarDayModel(
            id: "20260429",
            date: targetDate,
            dayNumber: "29",
            alternateCalendarText: "十三",
            alternateCalendarDateText: "四月十三",
            isInDisplayedMonth: true,
            isToday: false,
            isWeekend: false,
            holidayKind: nil,
            events: [event]
        )

        viewModel.select(targetDay)

        XCTAssertEqual(viewModel.selectedDay, targetDay)
        XCTAssertEqual(viewModel.todayDay?.id, "20260415")
        XCTAssertNotEqual(viewModel.todayDay?.id, targetDay.id)
    }

    func testRefreshUpdatesTodayDetailAfterDayBoundary() throws {
        let calendar = Self.makeCalendar()
        var now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 15)))
        let viewModel = CalendarComponentViewModel(
            eventService: MockCalendarEventService(),
            holidayProvider: .empty,
            calendar: calendar,
            today: now,
            now: { now }
        )
        now = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: now))

        viewModel.refresh()

        XCTAssertEqual(viewModel.todayDay?.id, "20260416")
    }

    func testCrossDayEventAppearsOnceWhenTodayIsOutsideTheMonthGrid() async throws {
        let calendar = Self.makeCalendar()
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 25)))
        let endDate = try XCTUnwrap(calendar.date(byAdding: .day, value: 3, to: today))
        let service = MockCalendarEventService()
        service.authorization = .fullAccess
        service.eventInputs = [CalendarEventInput(
            id: "vacation",
            title: "Vacation",
            startDate: today,
            endDate: endDate,
            isAllDay: true,
            color: .accent
        )]
        let requests = expectation(description: "Month grid and today loaded")
        requests.expectedFulfillmentCount = 2
        service.onEventsRequest = requests.fulfill
        let viewModel = CalendarComponentViewModel(
            eventService: service,
            holidayProvider: .empty,
            calendar: calendar,
            today: today,
            now: { today }
        )
        defer { viewModel.stop() }

        viewModel.moveMonth(by: 1)
        await fulfillment(of: [requests], timeout: 1)

        XCTAssertEqual(service.eventRanges.count, 2)
        XCTAssertEqual(viewModel.todayDay?.events.map(\.title), ["Vacation"])
        let nextDay = try XCTUnwrap(viewModel.month.days.first { $0.id == "20260426" })
        XCTAssertEqual(nextDay.events.map(\.title), ["Vacation"])
    }

    func testDistantMonthKeepsQueriesBoundedAndPreservesTodaysEvents() async throws {
        let calendar = Self.makeCalendar()
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 15)))
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: today))
        let distantDate = try XCTUnwrap(calendar.date(byAdding: .year, value: 10, to: today))
        let distantEnd = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: distantDate))
        let service = MockCalendarEventService()
        service.authorization = .fullAccess
        service.eventInputs = [
            CalendarEventInput(id: "today", title: "Today", startDate: today,
                               endDate: tomorrow, isAllDay: true, color: .accent),
            CalendarEventInput(id: "future", title: "Future", startDate: distantDate,
                               endDate: distantEnd, isAllDay: true, color: .accent)
        ]
        let requests = expectation(description: "Only the month grid and today are queried")
        requests.expectedFulfillmentCount = 2
        service.onEventsRequest = requests.fulfill
        let viewModel = CalendarComponentViewModel(
            eventService: service,
            holidayProvider: .empty,
            calendar: calendar,
            today: today,
            now: { today }
        )
        defer { viewModel.stop() }

        viewModel.moveMonth(by: 120)
        await fulfillment(of: [requests], timeout: 1)

        XCTAssertEqual(service.eventRanges.count, 2)
        XCTAssertEqual(service.eventRanges.map {
            calendar.dateComponents([.day], from: $0.start, to: $0.end).day
        }, [42, 3])
        XCTAssertEqual(viewModel.todayDay?.events.map(\.title), ["Today"])
        let distantDay = try XCTUnwrap(viewModel.month.days.first {
            calendar.isDate($0.date, inSameDayAs: distantDate)
        })
        XCTAssertEqual(distantDay.events.map(\.title), ["Future"])
    }

    func testAgendaMergesRemindersAndStopsLoadingThemWhenDisabled() async throws {
        let calendar = Self.makeCalendar()
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 15)))
        let service = MockCalendarEventService()
        service.authorization = .fullAccess
        service.remindersAuthorization = .fullAccess
        service.eventInputs = [CalendarEventInput(
            id: "meeting",
            title: "Meeting",
            startDate: try XCTUnwrap(calendar.date(byAdding: .hour, value: 10, to: today)),
            endDate: try XCTUnwrap(calendar.date(byAdding: .hour, value: 11, to: today)),
            isAllDay: false,
            color: .accent
        )]
        service.reminderInputs = [CalendarEventInput(
            id: "reminder",
            title: "Pay bill",
            startDate: try XCTUnwrap(calendar.date(byAdding: .hour, value: 9, to: today)),
            endDate: try XCTUnwrap(calendar.date(byAdding: .hour, value: 9, to: today)),
            isAllDay: false,
            color: .accent,
            calendarTitle: "Home",
            kind: .reminder
        )]
        let initialEvents = expectation(description: "Events loaded")
        let initialReminders = expectation(description: "Reminders loaded")
        service.onEventsRequest = initialEvents.fulfill
        service.onRemindersRequest = initialReminders.fulfill
        let model = CalendarComponentViewModel(
            eventService: service,
            holidayProvider: .empty,
            calendar: calendar,
            today: today,
            now: { today }
        )
        defer { model.stop() }

        model.start()
        await fulfillment(of: [initialEvents, initialReminders], timeout: 1)

        XCTAssertEqual(model.agendaDays.first?.events.map(\.title), ["Pay bill", "Meeting"])
        XCTAssertEqual(model.agendaDays.first?.events.map(\.kind), [.reminder, .event])

        let reloadedEvents = expectation(description: "Reminder change reloads calendar events")
        service.onEventsRequest = reloadedEvents.fulfill
        service.onRemindersRequest = nil
        model.configureAgenda(
            range: CalendarAgendaRange(),
            isVisible: true,
            showsReminders: false
        )
        await fulfillment(of: [reloadedEvents], timeout: 1)

        XCTAssertEqual(model.agendaDays.first?.events.map(\.kind), [.event])
        XCTAssertEqual(service.reminderRanges.count, 1, "Disabled reminders must not be queried again")
    }

    func testRemindersLoadWhenCalendarAccessIsUnavailable() async throws {
        let calendar = Self.makeCalendar()
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 15)))
        let service = MockCalendarEventService()
        service.authorization = .denied("未授权")
        service.remindersAuthorization = .fullAccess
        service.reminderInputs = [CalendarEventInput(
            id: "reminder",
            title: "Water plants",
            startDate: today,
            endDate: try XCTUnwrap(calendar.date(byAdding: .minute, value: 1, to: today)),
            isAllDay: true,
            color: .accent,
            kind: .reminder
        )]
        let reminders = expectation(description: "Reminders loaded without calendar access")
        service.onRemindersRequest = reminders.fulfill
        let model = CalendarComponentViewModel(
            eventService: service,
            holidayProvider: .empty,
            calendar: calendar,
            today: today,
            now: { today }
        )
        defer { model.stop() }

        model.start()
        await fulfillment(of: [reminders], timeout: 1)

        XCTAssertTrue(service.eventRanges.isEmpty)
        XCTAssertEqual(model.agendaDays.first?.events.map(\.kind), [.reminder])
    }

    private static func makeCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 1
        return calendar
    }

    func testAgendaGroupsAllEventsByDayAndReconfiguresWhileVisible() async throws {
        let calendar = Self.makeCalendar()
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 12, day: 31)))
        let service = MockCalendarEventService()
        service.authorization = .fullAccess
        service.eventInputs = (-3...3).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: today)!
            return CalendarEventInput(id: "\(offset)", title: "Event \(offset)", startDate: date,
                                      endDate: date.addingTimeInterval(3600), isAllDay: false, color: .accent,
                                      calendarTitle: "Work")
        }
        let model = CalendarComponentViewModel(eventService: service, holidayProvider: .empty,
                                                calendar: calendar, today: today, now: { today })
        defer { model.stop() }
        let initial = expectation(description: "Future agenda loaded")
        service.onEventsRequest = initial.fulfill
        model.start()
        await fulfillment(of: [initial], timeout: 1)
        XCTAssertEqual(model.agendaDays.map(\.id), ["20261231", "20270101", "20270102"])
        XCTAssertEqual(model.agendaDays.first?.events.first?.calendarTitle, "Work")

        let changed = expectation(description: "Surrounding agenda loaded")
        service.onEventsRequest = changed.fulfill
        model.configureAgenda(range: CalendarAgendaRange(dayCount: 3, direction: .surrounding), isVisible: true)
        await fulfillment(of: [changed], timeout: 1)
        XCTAssertEqual(model.agendaDays.map(\.id), ["20261230", "20261231", "20270101"])
        model.select(try XCTUnwrap(model.month.days.first))
        XCTAssertEqual(model.agendaDays.map(\.id), ["20261230", "20261231", "20270101"])
        model.open(try XCTUnwrap(model.agendaDays.last))
        XCTAssertEqual(service.openedDates.last, model.agendaDays.last?.date)
    }

    func testEventStoreNotificationsRefreshAndStopWithVisibility() async throws {
        let calendar = Self.makeCalendar()
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 15)))
        let service = MockCalendarEventService()
        service.authorization = .fullAccess
        let center = NotificationCenter()
        let model = CalendarComponentViewModel(eventService: service, holidayProvider: .empty, calendar: calendar,
                                                notificationCenter: center, today: today, now: { today })
        let initial = expectation(description: "Initial request")
        service.onEventsRequest = initial.fulfill
        model.start()
        await fulfillment(of: [initial], timeout: 1)

        service.eventInputs = [CalendarEventInput(id: "new", title: "New", startDate: today,
            endDate: today.addingTimeInterval(3600), isAllDay: false, color: .accent)]
        let updated = expectation(description: "Store change reloads agenda")
        service.onEventsRequest = updated.fulfill
        for _ in 0..<3 { center.post(name: .EKEventStoreChanged, object: nil) }
        await fulfillment(of: [updated], timeout: 1)
        XCTAssertEqual(service.eventRanges.count, 2, "Store notifications should coalesce")
        XCTAssertEqual(model.agendaDays.first?.events.map(\.title), ["New"])

        model.stop()
        let hidden = expectation(description: "Hidden calendar should not reload")
        hidden.isInverted = true
        service.onEventsRequest = hidden.fulfill
        center.post(name: .EKEventStoreChanged, object: nil)
        await fulfillment(of: [hidden], timeout: 0.25)
    }

    func testReminderSnapshotIsReusedAcrossMonthChangesAndRefreshedOnStoreChange() async throws {
        let calendar = Self.makeCalendar()
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 15)))
        let service = MockCalendarEventService()
        service.authorization = .fullAccess
        service.remindersAuthorization = .fullAccess
        service.reminderInputs = [CalendarEventInput(
            id: "reminder",
            title: "Pay bill",
            startDate: today,
            endDate: try XCTUnwrap(calendar.date(byAdding: .minute, value: 1, to: today)),
            isAllDay: false,
            color: .accent,
            kind: .reminder
        )]
        let center = NotificationCenter()
        let model = CalendarComponentViewModel(
            eventService: service,
            holidayProvider: .empty,
            calendar: calendar,
            notificationCenter: center,
            today: today,
            now: { today }
        )
        defer { model.stop() }
        let initial = expectation(description: "Initial reminders loaded")
        service.onRemindersRequest = initial.fulfill
        model.start()
        await fulfillment(of: [initial], timeout: 1)
        service.onRemindersRequest = nil
        let initialRefreshCount = service.reminderRefreshCount
        XCTAssertGreaterThan(initialRefreshCount, 0)

        // Browsing another month reuses the cached snapshot instead of refetching
        // the full reminder library for every date range.
        let monthChange = expectation(description: "Month change reloads events")
        monthChange.expectedFulfillmentCount = 2
        service.onEventsRequest = monthChange.fulfill
        model.moveMonth(by: 1)
        await fulfillment(of: [monthChange], timeout: 1)
        XCTAssertEqual(
            service.reminderRefreshCount,
            initialRefreshCount,
            "Month navigation must reuse the cached reminder snapshot"
        )

        // EventKit changes rebuild the snapshot before the next date-range read.
        service.reminderInputs = [CalendarEventInput(
            id: "reminder-2",
            title: "Updated reminder",
            startDate: today,
            endDate: try XCTUnwrap(calendar.date(byAdding: .minute, value: 1, to: today)),
            isAllDay: false,
            color: .accent,
            kind: .reminder
        )]
        let refresh = expectation(description: "Store change refreshes the reminder snapshot")
        service.onRemindersRefresh = refresh.fulfill
        let updated = expectation(description: "Store change reloads events")
        updated.expectedFulfillmentCount = 2
        service.onEventsRequest = updated.fulfill
        center.post(name: .EKEventStoreChanged, object: nil)
        await fulfillment(of: [refresh, updated], timeout: 1)
        XCTAssertEqual(service.reminderRefreshCount, initialRefreshCount + 1)
        XCTAssertEqual(model.agendaDays.first?.events.map(\.title), ["Updated reminder"])
    }

    func testEventStoreChangeMarksSnapshotStaleBeforeDebouncedActivation() async throws {
        let calendar = Self.makeCalendar()
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 15)))
        let service = MockCalendarEventService()
        service.authorization = .fullAccess
        service.remindersAuthorization = .fullAccess
        service.reminderInputs = [CalendarEventInput(
            id: "reminder",
            title: "Old title",
            startDate: today,
            endDate: try XCTUnwrap(calendar.date(byAdding: .minute, value: 1, to: today)),
            isAllDay: false,
            color: .accent,
            kind: .reminder
        )]
        let center = NotificationCenter()
        let model = CalendarComponentViewModel(
            eventService: service,
            holidayProvider: .empty,
            calendar: calendar,
            notificationCenter: center,
            today: today,
            now: { today }
        )
        defer { model.stop() }
        let initial = expectation(description: "Initial reminders loaded")
        service.onRemindersRequest = initial.fulfill
        model.start()
        await fulfillment(of: [initial], timeout: 1)
        XCTAssertEqual(model.agendaDays.first?.events.map(\.title), ["Old title"])

        // An EventKit change followed by activation within the debounce window
        // merges into only the activation, but the snapshot must still be marked
        // stale so the next refresh refetches the edited reminder.
        service.reminderInputs = [CalendarEventInput(
            id: "reminder-2",
            title: "New title",
            startDate: today,
            endDate: try XCTUnwrap(calendar.date(byAdding: .minute, value: 1, to: today)),
            isAllDay: false,
            color: .accent,
            kind: .reminder
        )]
        service.onRemindersRequest = nil
        let refresh = expectation(description: "Snapshot refreshed after merged activation")
        service.onRemindersRefresh = refresh.fulfill
        center.post(name: .EKEventStoreChanged, object: nil)
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await fulfillment(of: [refresh], timeout: 1)
        XCTAssertEqual(model.agendaDays.first?.events.map(\.title), ["New title"])
    }

    func testClosingDuringReminderRefreshDoesNotStartAnotherFetch() async throws {
        let calendar = Self.makeCalendar()
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 15)))
        let service = MockCalendarEventService()
        service.authorization = .fullAccess
        service.remindersAuthorization = .fullAccess
        service.reminderInputs = [CalendarEventInput(
            id: "reminder",
            title: "Pay bill",
            startDate: today,
            endDate: try XCTUnwrap(calendar.date(byAdding: .minute, value: 1, to: today)),
            isAllDay: false,
            color: .accent,
            kind: .reminder
        )]
        let center = NotificationCenter()
        let model = CalendarComponentViewModel(
            eventService: service,
            holidayProvider: .empty,
            calendar: calendar,
            notificationCenter: center,
            today: today,
            now: { today }
        )
        let initial = expectation(description: "Initial reminders loaded")
        service.onRemindersRequest = initial.fulfill
        model.start()
        await fulfillment(of: [initial], timeout: 1)
        service.onRemindersRequest = nil
        service.onEventsRequest = nil

        // Suspend the reminder refresh so the notification handler is mid-flight
        // when the widget closes.
        service.suspendRemindersRefresh = true
        let refreshStarted = expectation(description: "Reminder refresh started")
        service.onRemindersRefresh = refreshStarted.fulfill
        center.post(name: .EKEventStoreChanged, object: nil)
        await fulfillment(of: [refreshStarted], timeout: 1)

        let rangesBeforeStop = service.eventRanges.count
        model.stop()
        service.suspendRemindersRefresh = false
        service.remindersRefreshContinuation?.resume()
        service.remindersRefreshContinuation = nil

        // A closed widget must not refresh again after the in-flight refresh
        // completes.
        let extraFetch = expectation(description: "No extra fetch while closed")
        extraFetch.isInverted = true
        service.onEventsRequest = extraFetch.fulfill
        try await Task.sleep(nanoseconds: 300_000_000)
        await fulfillment(of: [extraFetch], timeout: 0.2)
        XCTAssertEqual(service.eventRanges.count, rangesBeforeStop)
        model.stop()
    }

    func testStopMarksReminderSnapshotStaleAndReopenRefreshes() async throws {
        let calendar = Self.makeCalendar()
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 15)))
        let service = MockCalendarEventService()
        service.authorization = .fullAccess
        service.remindersAuthorization = .fullAccess
        service.reminderInputs = [CalendarEventInput(
            id: "reminder",
            title: "Old title",
            startDate: today,
            endDate: try XCTUnwrap(calendar.date(byAdding: .minute, value: 1, to: today)),
            isAllDay: false,
            color: .accent,
            kind: .reminder
        )]
        let model = CalendarComponentViewModel(
            eventService: service,
            holidayProvider: .empty,
            calendar: calendar,
            today: today,
            now: { today }
        )
        let initial = expectation(description: "Initial reminders loaded")
        service.onRemindersRequest = initial.fulfill
        model.start()
        await fulfillment(of: [initial], timeout: 1)
        XCTAssertEqual(model.agendaDays.first?.events.map(\.title), ["Old title"])
        let initialRefreshCount = service.reminderRefreshCount

        // The reminder library changes while the widget is hidden.
        model.stop()
        service.reminderInputs = [CalendarEventInput(
            id: "reminder-2",
            title: "New title",
            startDate: today,
            endDate: try XCTUnwrap(calendar.date(byAdding: .minute, value: 1, to: today)),
            isAllDay: false,
            color: .accent,
            kind: .reminder
        )]
        service.onRemindersRequest = nil

        // Reopening must refetch rather than reuse the cached snapshot.
        let reloaded = expectation(description: "Reopen reloads events")
        service.onEventsRequest = reloaded.fulfill
        let refreshed = expectation(description: "Reopen refreshes the reminder snapshot")
        service.onRemindersRefresh = refreshed.fulfill
        model.start()
        await fulfillment(of: [reloaded, refreshed], timeout: 1)
        XCTAssertGreaterThan(service.reminderRefreshCount, initialRefreshCount)
        XCTAssertEqual(model.agendaDays.first?.events.map(\.title), ["New title"])
        model.stop()
    }

    func testReminderAccessPromptsHostUpdateWhenUsageDescriptionMissing() async {
        let service = CalendarEventService(remindersUsageDescriptionProvider: { false })
        XCTAssertFalse(service.hostProvidesReminderPrivacyDescription)
        let authorization = await service.requestReminderAccess()
        guard case .denied = authorization else {
            XCTFail("Requesting reminder access without a host usage description must be denied")
            return
        }
    }

    func testHiddenAgendaDoesNotQueryDistantDates() async throws {
        let calendar = Self.makeCalendar()
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 15)))
        let service = MockCalendarEventService()
        service.authorization = .fullAccess
        let model = CalendarComponentViewModel(eventService: service, holidayProvider: .empty,
            calendar: calendar, showsRecentAgenda: false, today: today, now: { today })
        let request = expectation(description: "Only the month grid loads")
        service.onEventsRequest = request.fulfill
        model.moveMonth(by: 120)
        await fulfillment(of: [request], timeout: 1)
        XCTAssertEqual(service.eventRanges.count, 1)
        XCTAssertTrue(model.agendaDays.isEmpty)
        model.stop()
    }

    func testRegionChangesRefreshBadgesWithoutChangingSelectedAlternateCalendar() async throws {
        var regionalCalendar = Self.makeCalendar()
        let today = try XCTUnwrap(regionalCalendar.date(from: DateComponents(year: 2026, month: 1, day: 4)))
        let service = MockCalendarEventService()
        service.authorization = .fullAccess
        service.eventInputs = [CalendarEventInput(id: "event", title: "Planning", startDate: today,
            endDate: today.addingTimeInterval(3600), isAllDay: false, color: .accent)]
        let center = NotificationCenter()
        let holidays = try CalendarHolidayProvider(data: Data(#"{"2026":{"0104":1}}"#.utf8))
        let model = CalendarComponentViewModel(eventService: service, holidayProvider: holidays,
            calendar: regionalCalendar, calendarProvider: { regionalCalendar }, notificationCenter: center,
            today: today, now: { today })
        defer { model.stop() }
        let initial = expectation(description: "Initial events loaded")
        service.onEventsRequest = initial.fulfill
        model.start()
        await fulfillment(of: [initial], timeout: 1)
        XCTAssertTrue(try XCTUnwrap(model.agendaDays.first).alternateCalendarText.isEmpty)

        regionalCalendar.locale = Locale(identifier: "en_CN")
        let changed = expectation(description: "Region change reloads calendar")
        service.onEventsRequest = changed.fulfill
        center.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)
        await fulfillment(of: [changed], timeout: 1)
        for day in [model.selectedDay, model.todayDay, model.agendaDays.first] {
            XCTAssertTrue(try XCTUnwrap(day).alternateCalendarText.isEmpty)
            XCTAssertEqual(day?.holidayKind, .workday)
        }
        let requestCount = service.eventRanges.count
        model.setAlternateCalendar(.chinese)
        XCTAssertTrue(model.month.days.allSatisfy { !$0.alternateCalendarText.isEmpty && !$0.alternateCalendarDateText.isEmpty })
        XCTAssertFalse(try XCTUnwrap(model.agendaDays.first).alternateCalendarText.isEmpty)
        XCTAssertEqual(model.agendaDays.first?.events.first?.title, "Planning")
        XCTAssertEqual(model.todayDay?.holidayKind, .workday)
        XCTAssertEqual(service.eventRanges.count, requestCount, "A presentation preference must not requery events")

        model.stop()
        regionalCalendar.locale = Locale(identifier: "en_US")
        let resumed = expectation(description: "New region applied on reopening")
        service.onEventsRequest = resumed.fulfill
        model.start()
        await fulfillment(of: [resumed], timeout: 1)
        XCTAssertFalse(try XCTUnwrap(model.todayDay).alternateCalendarText.isEmpty)
        XCTAssertNil(model.todayDay?.holidayKind)
    }

    func testQueryFailureClearsAgendaAndRetryRecovers() async throws {
        let calendar = Self.makeCalendar()
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 15)))
        let service = MockCalendarEventService()
        service.authorization = .fullAccess
        service.shouldFail = true
        let model = CalendarComponentViewModel(eventService: service, holidayProvider: .empty,
                                                calendar: calendar, today: today, now: { today })
        let failed = expectation(description: "Request failed")
        service.onEventsRequest = failed.fulfill
        model.start()
        await fulfillment(of: [failed], timeout: 1)
        XCTAssertNotNil(model.eventLoadingError)
        XCTAssertTrue(model.agendaDays.isEmpty)
        XCTAssertTrue(model.hasAgendaContent, "Read failures must retain retry guidance")

        let retry = expectation(description: "Retry succeeds")
        service.onEventsRequest = retry.fulfill
        service.shouldFail = false
        model.refresh()
        await fulfillment(of: [retry], timeout: 1)
        XCTAssertNil(model.eventLoadingError)
        XCTAssertFalse(model.hasAgendaContent, "A successfully loaded empty agenda must leave only the month")
        model.stop()
    }
}

@MainActor
private final class MockCalendarEventService: CalendarEventServicing {
    var authorization: CalendarEventAuthorization = .denied("未授权")
    var remindersAuthorization: CalendarEventAuthorization = .notDetermined
    private(set) var openedDates: [Date] = []
    private(set) var eventRanges: [(start: Date, end: Date)] = []
    private(set) var reminderRanges: [(start: Date, end: Date)] = []
    var onEventsRequest: (() -> Void)?
    var onRemindersRequest: (() -> Void)?
    var onRemindersRefresh: (() -> Void)?
    var eventInputs: [CalendarEventInput] = []
    var reminderInputs: [CalendarEventInput] = []
    var shouldFail = false
    var hostProvidesReminderPrivacyDescription = true
    var suspendRemindersRefresh = false
    var remindersRefreshContinuation: CheckedContinuation<Void, Never>?
    private(set) var reminderRefreshCount = 0
    private var reminderSnapshot: [CalendarEventInput] = []
    private var reminderSnapshotIsStale = true

    func requestAccess() async -> CalendarEventAuthorization {
        authorization
    }

    func requestReminderAccess() async -> CalendarEventAuthorization {
        remindersAuthorization
    }

    func events(from startDate: Date, to endDate: Date) async throws -> [CalendarEventInput] {
        eventRanges.append((startDate, endDate))
        onEventsRequest?()
        if shouldFail { throw CocoaError(.fileReadUnknown) }
        return eventInputs.filter { $0.startDate < endDate && $0.endDate > startDate }
    }

    func reminders(from startDate: Date, to endDate: Date) async -> [CalendarEventInput] {
        reminderRanges.append((startDate, endDate))
        onRemindersRequest?()
        if reminderSnapshotIsStale {
            await refreshReminders()
        }
        return reminderSnapshot.filter { $0.startDate < endDate && $0.endDate > startDate }
    }

    func refreshReminders() async {
        reminderRefreshCount += 1
        onRemindersRefresh?()
        if suspendRemindersRefresh {
            await withCheckedContinuation { remindersRefreshContinuation = $0 }
        }
        reminderSnapshot = reminderInputs
        reminderSnapshotIsStale = false
    }

    func invalidateReminderSnapshot() {
        reminderSnapshot = []
        reminderSnapshotIsStale = true
    }

    func openSystemCalendar(at date: Date) {
        openedDates.append(date)
    }
}
