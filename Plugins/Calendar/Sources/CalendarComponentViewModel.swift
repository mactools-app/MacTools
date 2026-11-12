import AppKit
import Combine
import EventKit
import Foundation
import MacToolsPluginKit

@MainActor
final class CalendarComponentViewModel: ObservableObject {
    @Published private(set) var month: CalendarMonthModel
    @Published private(set) var selectedDay: CalendarDayModel?
    @Published private(set) var todayDay: CalendarDayModel?
    @Published private(set) var agendaDays: [CalendarDayModel] = []
    @Published private(set) var agendaDates: [Date] = []
    @Published private(set) var authorization: CalendarEventAuthorization
    @Published private(set) var remindersAuthorization: CalendarEventAuthorization
    @Published private(set) var isLoadingEvents = false
    @Published private(set) var eventLoadingError: String?

    var onStateChange: (() -> Void)?

    var hasAgendaContent: Bool {
        !agendaDays.isEmpty
            || !authorization.isFullAccess
            || (showsReminders && remindersAuthorization.isDenied)
            || eventLoadingError != nil
    }

    private let eventService: CalendarEventServicing
    private let holidayProvider: CalendarHolidayProvider
    private var calendar: Calendar
    private let localization: PluginLocalization
    private let now: () -> Date
    private let notificationCenter: NotificationCenter
    private let calendarProvider: (() -> Calendar)?
    private var alternateCalendar: CalendarAlternateCalendar
    private var observation: AnyCancellable?
    private var agendaRange: CalendarAgendaRange
    private var showsRecentAgenda: Bool
    private var showsReminders: Bool
    private var displayedMonthStart: Date
    private var selectedDate: Date
    private var todayDate: Date
    private var eventsByDay: [Date: [CalendarEventSummary]] = [:]
    private var loadTask: Task<Void, Never>?
    private var isStarted = false

    init(
        eventService: CalendarEventServicing = CalendarEventService(),
        holidayProvider: CalendarHolidayProvider,
        calendar: Calendar = CalendarComponentCalendars.gregorian(),
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        agendaRange: CalendarAgendaRange = CalendarAgendaRange(),
        showsRecentAgenda: Bool = true,
        showsReminders: Bool = true,
        alternateCalendar: CalendarAlternateCalendar = .none,
        calendarProvider: (() -> Calendar)? = nil,
        notificationCenter: NotificationCenter = .default,
        today: Date = Date(),
        now: @escaping () -> Date = Date.init
    ) {
        self.eventService = eventService
        self.holidayProvider = holidayProvider
        self.calendar = calendar
        self.localization = localization
        self.now = now
        self.agendaRange = agendaRange
        self.showsRecentAgenda = showsRecentAgenda
        self.showsReminders = showsReminders
        self.notificationCenter = notificationCenter
        self.alternateCalendar = alternateCalendar
        self.calendarProvider = calendarProvider
        let initialToday = calendar.startOfDay(for: today)
        self.displayedMonthStart = CalendarComponentCalendars.monthStart(containing: initialToday, calendar: calendar)
        self.selectedDate = initialToday
        self.todayDate = initialToday
        self.authorization = eventService.authorization
        self.remindersAuthorization = eventService.remindersAuthorization
        let initialMonth = CalendarMonthModelBuilder(
            calendar: calendar,
            holidayProvider: holidayProvider,
            localization: localization,
            alternateCalendar: alternateCalendar
        ).makeMonth(containing: initialToday, today: initialToday)
        self.month = initialMonth
        self.selectedDay = initialMonth.days.first { calendar.isDate($0.date, inSameDayAs: selectedDate) }
        self.todayDay = initialMonth.days.first { $0.isToday }
        self.agendaDates = agendaRange.dates(relativeTo: initialToday, calendar: calendar)
    }

    func start() {
        isStarted = true
        if observation == nil {
            observation = Publishers.MergeMany([
                notificationCenter.publisher(for: .EKEventStoreChanged),
                notificationCenter.publisher(for: .NSCalendarDayChanged),
                notificationCenter.publisher(for: NSLocale.currentLocaleDidChangeNotification),
                notificationCenter.publisher(for: .NSSystemTimeZoneDidChange),
                notificationCenter.publisher(for: NSApplication.didBecomeActiveNotification)
            ])
            .handleEvents(receiveOutput: { [weak self] notification in
                // Mark the snapshot stale the moment an EventKit change arrives,
                // before debouncing. If the widget is activated within the debounce
                // window, the merged event would otherwise be only the activation,
                // and the next refresh would reuse an outdated snapshot. A system
                // time-zone change also invalidates it so dates are recalculated
                // in the new local time zone.
                guard notification.name == .EKEventStoreChanged
                    || notification.name == .NSSystemTimeZoneDidChange else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.showsReminders else { return }
                    self.eventService.invalidateReminderSnapshot()
                }
            })
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] notification in
                Task { @MainActor [weak self] in
                    guard let self, self.isStarted else { return }
                    // Rebuild the cached reminder snapshot before reloading so
                    // date-range reads reuse fresh data without a full refetch.
                    if notification.name == .EKEventStoreChanged, self.showsReminders {
                        await self.eventService.refreshReminders()
                        // The widget may have closed while the refresh was in
                        // flight; a closed widget must not start another fetch.
                        guard self.isStarted else { return }
                    }
                    self.refresh()
                }
            }
        }
        refresh()
    }

    func stop() {
        isStarted = false
        observation = nil
        loadTask?.cancel()
        loadTask = nil
        isLoadingEvents = false
        // A hidden widget may miss EventKit changes, so the next open must
        // refetch rather than reuse a snapshot that could be stale.
        eventService.invalidateReminderSnapshot()
    }

    func refresh() {
        if var updated = calendarProvider?() {
            updated.firstWeekday = calendar.firstWeekday
            if updated != calendar {
                let displayedMonth = calendar.dateComponents([.year, .month], from: displayedMonthStart)
                // Only time-zone changes invalidate day-start keys. Locale and
                // week-layout changes can keep the last complete event snapshot.
                if updated.timeZone != calendar.timeZone { eventsByDay = [:] }
                calendar = updated
                displayedMonthStart = calendar.date(from: displayedMonth) ?? displayedMonthStart
            }
        }
        todayDate = calendar.startOfDay(for: now())
        rebuildMonth()
        reloadEvents()
    }

    func refreshIfVisible() {
        if isStarted { refresh() }
    }

    func configureAgenda(
        range: CalendarAgendaRange,
        isVisible: Bool,
        showsReminders: Bool? = nil
    ) {
        let nextShowsReminders = showsReminders ?? self.showsReminders
        let remindersChanged = nextShowsReminders != self.showsReminders
        guard agendaRange != range || showsRecentAgenda != isVisible || remindersChanged else {
            return
        }
        agendaRange = range
        showsRecentAgenda = isVisible
        self.showsReminders = nextShowsReminders
        if remindersChanged {
            // Turning the setting back on must refetch rather than reuse a
            // snapshot that may have missed edits made while it was off.
            eventService.invalidateReminderSnapshot()
            if !nextShowsReminders {
                eventsByDay = eventsByDay.mapValues { summaries in
                    summaries.filter { $0.kind != .reminder }
                }
            }
        }
        rebuildMonth()
        if isStarted { reloadEvents() }
    }

    func setAlternateCalendar(_ display: CalendarAlternateCalendar) {
        guard alternateCalendar != display else { return }
        alternateCalendar = display
        rebuildMonth()
    }

    func setWeekStartDay(_ day: CalendarWeekStartDay) {
        guard calendar.firstWeekday != day.calendarFirstWeekday else {
            return
        }

        loadTask?.cancel()
        calendar.firstWeekday = day.calendarFirstWeekday
        rebuildMonth()
        if isStarted {
            reloadEvents()
        }
    }

    func moveMonth(by value: Int) {
        guard let nextMonth = calendar.date(byAdding: .month, value: value, to: displayedMonthStart) else {
            return
        }

        displayedMonthStart = CalendarComponentCalendars.monthStart(containing: nextMonth, calendar: calendar)
        selectedDate = displayedMonthStart
        // Recent events are anchored to today, not the browsed month. Keep the
        // last complete snapshot until both replacement queries have finished.
        rebuildMonth()
        reloadEvents()
    }

    func goToToday() {
        let today = calendar.startOfDay(for: now())
        todayDate = today
        displayedMonthStart = CalendarComponentCalendars.monthStart(containing: today, calendar: calendar)
        selectedDate = today
        rebuildMonth(today: today)
        reloadEvents()
    }

    func select(_ day: CalendarDayModel) {
        selectedDate = day.date
        selectedDay = day
    }

    func open(_ day: CalendarDayModel) {
        select(day)
        eventService.openSystemCalendar(at: day.date)
    }

    private func reloadEvents() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self, !Task.isCancelled else {
                return
            }

            authorization = eventService.authorization
            remindersAuthorization = eventService.remindersAuthorization
            let canLoadEvents = authorization.isFullAccess
            let canLoadReminders = showsReminders && remindersAuthorization.isFullAccess
            guard canLoadEvents || canLoadReminders else {
                eventsByDay = [:]
                eventLoadingError = nil
                isLoadingEvents = false
                rebuildMonth()
                return
            }

            let visibleDates = month.days.map(\.date)
            let requestedAgendaDates = showsRecentAgenda ? agendaDates : []
            guard let firstDate = visibleDates.first,
                  let lastDate = visibleDates.last,
                  let endDate = calendar.date(byAdding: .day, value: 1, to: lastDate) else {
                return
            }

            isLoadingEvents = true

            do {
                let events = try await loadItems(from: firstDate, to: endDate)
                guard !Task.isCancelled else {
                    return
                }

                var groupedEvents = CalendarEventGrouper.group(
                    events: events,
                    visibleDates: visibleDates,
                    calendar: calendar,
                    localization: localization
                )
                let outsideDates = requestedAgendaDates.filter { $0 < firstDate || $0 >= endDate }
                if let agendaStart = outsideDates.first,
                   let agendaLast = outsideDates.last,
                   let agendaEnd = calendar.date(byAdding: .day, value: 1, to: agendaLast) {
                    let agendaEvents = try await loadItems(from: agendaStart, to: agendaEnd)
                    guard !Task.isCancelled else {
                        return
                    }

                    // Only fill dates outside the grid so overlapping query results never duplicate events.
                    let outsideEvents = CalendarEventGrouper.group(
                        events: agendaEvents,
                        visibleDates: outsideDates,
                        calendar: calendar,
                        localization: localization
                    )
                    groupedEvents.merge(outsideEvents) { _, agenda in agenda }
                }
                eventsByDay = groupedEvents
                eventLoadingError = nil
                isLoadingEvents = false
                rebuildMonth()
            } catch {
                guard !Task.isCancelled else {
                    return
                }

                eventsByDay = [:]
                isLoadingEvents = false
                eventLoadingError = localization.string("agenda.error", defaultValue: "暂时无法读取日程")
                rebuildMonth()
            }
        }
    }

    private func loadItems(from startDate: Date, to endDate: Date) async throws -> [CalendarEventInput] {
        var items: [CalendarEventInput] = []
        if authorization.isFullAccess {
            items += try await eventService.events(from: startDate, to: endDate)
        }
        // Reminder failures should not hide readable calendar events.
        if showsReminders && remindersAuthorization.isFullAccess {
            items += await eventService.reminders(from: startDate, to: endDate)
        }
        return items
    }

    private func rebuildMonth(today: Date? = nil) {
        let referenceToday = today.map(calendar.startOfDay(for:)) ?? todayDate
        month = CalendarMonthModelBuilder(
            calendar: calendar,
            holidayProvider: holidayProvider,
            localization: localization,
            alternateCalendar: alternateCalendar
        ).makeMonth(
            containing: displayedMonthStart,
            today: referenceToday,
            eventsByDay: eventsByDay
        )

        selectedDay = month.days.first { calendar.isDate($0.date, inSameDayAs: selectedDate) }
            ?? month.days.first { $0.isToday }
            ?? month.days.first
        let builder = CalendarMonthModelBuilder(
            calendar: calendar,
            holidayProvider: holidayProvider,
            localization: localization,
            alternateCalendar: alternateCalendar
        )
        todayDay = builder.makeDay(
            for: referenceToday, today: referenceToday, events: eventsByDay[referenceToday] ?? []
        )
        agendaDates = agendaRange.dates(relativeTo: referenceToday, calendar: calendar)
        agendaDays = showsRecentAgenda ? agendaDates.compactMap { date in
            guard let events = eventsByDay[date], !events.isEmpty else { return nil }
            return builder.makeDay(for: date, today: referenceToday, events: events)
        } : []
        onStateChange?()
    }
}
