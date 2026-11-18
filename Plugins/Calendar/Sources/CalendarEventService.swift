import AppKit
import EventKit
import Foundation
import MacToolsPluginKit

@MainActor
enum CalendarEventAuthorization: Equatable {
    case notDetermined
    case fullAccess
    case denied(String)

    var isFullAccess: Bool {
        if case .fullAccess = self {
            return true
        }

        return false
    }

    var isDenied: Bool {
        if case .denied = self {
            return true
        }

        return false
    }
}

@MainActor
protocol CalendarEventServicing: AnyObject {
    var authorization: CalendarEventAuthorization { get }
    var remindersAuthorization: CalendarEventAuthorization { get }
    /// Whether the host bundle declares the Reminders privacy description
    /// required to request full access. Older hosts or Nightlies built before
    /// the descriptions existed report a compatible version but lack the key.
    var hostProvidesReminderPrivacyDescription: Bool { get }

    func requestAccess() async -> CalendarEventAuthorization
    func requestReminderAccess() async -> CalendarEventAuthorization
    func events(from startDate: Date, to endDate: Date) async throws -> [CalendarEventInput]
    func reminders(from startDate: Date, to endDate: Date) async -> [CalendarEventInput]
    func refreshReminders() async
    func invalidateReminderSnapshot()
    func openSystemCalendar(at date: Date)
}

@MainActor
final class CalendarEventService: CalendarEventServicing {
    private var eventStore = EKEventStore()
    private let localization: PluginLocalization
    private let remindersUsageDescriptionProvider: () -> Bool
    /// Snapshot of reminders mapped into Sendable inputs. Date-range requests
    /// filter this snapshot instead of fetching the full reminder library, so
    /// rapid month switching does not repeat the full-library EventKit read.
    private var reminderSnapshot: [CalendarEventInput] = []
    /// Whether the snapshot no longer reflects EventKit state and must be
    /// rebuilt before the next date-range filter.
    private var reminderSnapshotIsStale = true
    /// Monotonic token so a superseded fetch never overwrites a newer snapshot.
    private var reminderFetchGeneration = 0
    /// The active `fetchReminders` request, cancelled and resumed when a newer
    /// fetch supersedes it.
    private var activeReminderFetch: ReminderFetchWaiter?

    init(
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        remindersUsageDescriptionProvider: @escaping () -> Bool = {
            Bundle.main.object(forInfoDictionaryKey: "NSRemindersFullAccessUsageDescription") != nil
        }
    ) {
        self.localization = localization
        self.remindersUsageDescriptionProvider = remindersUsageDescriptionProvider
    }

    var hostProvidesReminderPrivacyDescription: Bool { remindersUsageDescriptionProvider() }

    var authorization: CalendarEventAuthorization {
        Self.authorization(
            from: EKEventStore.authorizationStatus(for: .event),
            entity: .event,
            localization: localization
        )
    }

    var remindersAuthorization: CalendarEventAuthorization {
        Self.authorization(
            from: EKEventStore.authorizationStatus(for: .reminder),
            entity: .reminder,
            localization: localization
        )
    }

    func requestAccess() async -> CalendarEventAuthorization {
        guard authorization == .notDetermined else {
            return authorization
        }

        do {
            _ = try await requestFullAccess(to: .event)
            eventStore = EKEventStore()
            invalidateReminderSnapshot()
            return authorization
        } catch {
            eventStore = EKEventStore()
            invalidateReminderSnapshot()
            return .denied(error.localizedDescription)
        }
    }

    func requestReminderAccess() async -> CalendarEventAuthorization {
        guard hostProvidesReminderPrivacyDescription else {
            return .denied(localization.string(
                "permission.reminders.hostUpdateRequired",
                defaultValue: "访问提醒事项需要更新版本的 MacTools。"
            ))
        }

        guard remindersAuthorization == .notDetermined else {
            return remindersAuthorization
        }

        do {
            _ = try await requestFullAccess(to: .reminder)
            eventStore = EKEventStore()
            invalidateReminderSnapshot()
            return remindersAuthorization
        } catch {
            eventStore = EKEventStore()
            invalidateReminderSnapshot()
            return .denied(error.localizedDescription)
        }
    }

    private func requestFullAccess(to entity: EKEntityType) async throws -> Bool {
        let eventStore = eventStore

        return try await withCheckedThrowingContinuation { continuation in
            let completion: @Sendable (Bool, (any Error)?) -> Void = { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                continuation.resume(returning: granted)
            }
            switch entity {
            case .event:
                eventStore.requestFullAccessToEvents(completion: completion)
            case .reminder:
                eventStore.requestFullAccessToReminders(completion: completion)
            @unknown default:
                continuation.resume(returning: false)
            }
        }
    }

    func events(from startDate: Date, to endDate: Date) async throws -> [CalendarEventInput] {
        guard authorization.isFullAccess else {
            return []
        }

        let calendars = eventStore.calendars(for: .event)
        guard !calendars.isEmpty else {
            return []
        }

        let predicate = eventStore.predicateForEvents(
            withStart: startDate,
            end: endDate,
            calendars: calendars
        )

        return eventStore.events(matching: predicate).map { Self.input(from: $0, localization: localization) }
    }

    func reminders(from startDate: Date, to endDate: Date) async -> [CalendarEventInput] {
        if reminderSnapshotIsStale {
            await refreshReminders()
        }
        return reminderSnapshot.filter { $0.startDate < endDate && $0.endDate > startDate }
    }

    func refreshReminders() async {
        guard remindersAuthorization.isFullAccess else {
            cancelActiveReminderFetch()
            reminderSnapshot = []
            reminderSnapshotIsStale = false
            return
        }

        let calendars = eventStore.calendars(for: .reminder)
        guard !calendars.isEmpty else {
            cancelActiveReminderFetch()
            reminderSnapshot = []
            reminderSnapshotIsStale = false
            return
        }

        let predicate = eventStore.predicateForReminders(in: calendars)
        let calendar = CalendarComponentCalendars.gregorian()
        reminderFetchGeneration += 1
        let generation = reminderFetchGeneration
        cancelActiveReminderFetch()
        let box = await withCheckedContinuation { continuation in
            let waiter = ReminderFetchWaiter(continuation)
            activeReminderFetch = waiter
            let request = eventStore.fetchReminders(matching: predicate) { reminders in
                waiter.complete(ReminderListBox(reminders: reminders ?? []))
            }
            waiter.attachRequest(request)
        }
        // Drop a finished waiter so a later cancel never touches a completed request.
        if let waiter = activeReminderFetch, waiter.isComplete {
            activeReminderFetch = nil
        }
        guard generation == reminderFetchGeneration else {
            return
        }
        reminderSnapshot = box.reminders.compactMap { Self.input(from: $0, calendar: calendar) }
        reminderSnapshotIsStale = false
    }

    func invalidateReminderSnapshot() {
        // Bump the generation before cancelling so the superseded fetch discards
        // its result and the snapshot stays stale until the next refresh.
        reminderFetchGeneration += 1
        cancelActiveReminderFetch()
        reminderSnapshot = []
        reminderSnapshotIsStale = true
    }

    private func cancelActiveReminderFetch() {
        guard let waiter = activeReminderFetch else {
            return
        }
        activeReminderFetch = nil
        waiter.cancel(using: eventStore)
    }

    func openSystemCalendar(at date: Date) {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            _ = await requestAccess()
            openSystemCalendarAfterAccessCheck(at: date)
        }
    }

    private func openSystemCalendarAfterAccessCheck(at date: Date) {
        let script = Self.openingScript(for: date)
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)

        if error != nil {
            openCalendarApplication()
        }
    }

    private static func authorization(
        from status: EKAuthorizationStatus,
        entity: EKEntityType,
        localization: PluginLocalization
    ) -> CalendarEventAuthorization {
        let isReminder = entity == .reminder
        switch status {
        case .notDetermined:
            return .notDetermined
        case .fullAccess:
            return .fullAccess
        case .denied:
            return .denied(
                localization.string(
                    isReminder ? "authorization.reminders.denied" : "authorization.denied",
                    defaultValue: isReminder ? "未获得提醒事项访问权限" : "未获得日历访问权限"
                )
            )
        case .restricted:
            return .denied(
                localization.string(
                    isReminder ? "authorization.reminders.restricted" : "authorization.restricted",
                    defaultValue: isReminder ? "系统限制了提醒事项访问" : "系统限制了日历访问"
                )
            )
        case .writeOnly:
            return .denied(
                localization.string(
                    isReminder ? "authorization.reminders.writeOnly" : "authorization.writeOnly",
                    defaultValue: isReminder
                        ? "仅允许写入提醒事项，无法读取提醒"
                        : "仅允许写入日历，无法读取日程"
                )
            )
        @unknown default:
            return .denied(
                localization.string(
                    isReminder ? "authorization.reminders.unknown" : "authorization.unknown",
                    defaultValue: isReminder ? "当前系统不允许读取提醒事项" : "当前系统不允许读取日历"
                )
            )
        }
    }

    private static func input(from event: EKEvent, localization: PluginLocalization) -> CalendarEventInput {
        CalendarEventInput(
            id: event.eventIdentifier ?? event.calendarItemIdentifier,
            title: event.title ?? localization.string("event.untitled", defaultValue: "未命名日程"),
            startDate: event.startDate,
            endDate: event.endDate,
            isAllDay: event.isAllDay,
            color: CalendarEventColor(nsColor: event.calendar.color),
            calendarTitle: event.calendar.title
        )
    }

    private static func input(
        from reminder: EKReminder,
        calendar: Calendar
    ) -> CalendarEventInput? {
        guard let dueDateComponents = reminder.dueDateComponents,
              let dueDate = dueDate(from: dueDateComponents, calendar: calendar) else {
            return nil
        }

        let isAllDay = dueDateComponents.hour == nil
            && dueDateComponents.minute == nil
            && dueDateComponents.second == nil

        return CalendarEventInput(
            id: reminder.calendarItemIdentifier,
            title: reminder.title ?? "",
            startDate: dueDate,
            endDate: calendar.date(byAdding: .minute, value: 1, to: dueDate) ?? dueDate,
            isAllDay: isAllDay,
            color: CalendarEventColor(nsColor: reminder.calendar.color),
            calendarTitle: reminder.calendar.title,
            kind: .reminder,
            isCompleted: reminder.isCompleted
        )
    }

    private static func dueDate(from components: DateComponents, calendar: Calendar) -> Date? {
        var calendar = calendar
        if let timeZone = components.timeZone {
            calendar.timeZone = timeZone
        }
        return calendar.date(from: components)
    }

    static func openingScript(for date: Date) -> String {
        openingScript(for: date, dateFormatter: appleScriptDateFormatter())
    }

    static func openingScript(for date: Date, dateFormatter: DateFormatter) -> String {
        let dateText = appleScriptEscapedString(dateFormatter.string(from: date))

        return """
        tell application "Calendar"
          activate
          switch view to day view
          view calendar at date "\(dateText)"
        end tell
        """
    }

    private static func appleScriptDateFormatter() -> DateFormatter {
        let calendar = CalendarComponentCalendars.gregorian()
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter
    }

    private static func appleScriptEscapedString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func openCalendarApplication() {
        let calendarURL = URL(fileURLWithPath: "/System/Applications/Calendar.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: calendarURL, configuration: configuration) { runningApplication, error in
            if error != nil {
                NSWorkspace.shared.open(calendarURL)
                Task { @MainActor in
                    Self.activateRunningCalendarApplication()
                }
                return
            }

            runningApplication?.activate(options: [.activateAllWindows])
        }
    }

    private static func activateRunningCalendarApplication() {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.iCal")
            .first?
            .activate(options: [.activateAllWindows])
    }
}

/// Carries the non-Sendable `EKReminder` array back to the main actor, where
/// the value is mapped into Sendable snapshots before any actor boundary.
private struct ReminderListBox: @unchecked Sendable {
    let reminders: [EKReminder]
}

/// Resumes a `fetchReminders` continuation exactly once, whether the fetch
/// completes normally or is cancelled. EventKit skips the completion callback
/// after `cancelFetchRequest`, so cancellation must resume the waiting task
/// itself; the lock guarantees only one of `complete`/`cancel` resumes it.
private final class ReminderFetchWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ReminderListBox, Never>?
    private var request: Any?

    init(_ continuation: CheckedContinuation<ReminderListBox, Never>) {
        self.continuation = continuation
    }

    func attachRequest(_ request: Any) {
        lock.lock()
        self.request = request
        lock.unlock()
    }

    func complete(_ box: ReminderListBox) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        self.request = nil
        lock.unlock()
        continuation?.resume(returning: box)
    }

    func cancel(using eventStore: EKEventStore) {
        lock.lock()
        let continuation = self.continuation
        let request = self.request
        self.continuation = nil
        self.request = nil
        lock.unlock()
        if let request {
            eventStore.cancelFetchRequest(request)
        }
        continuation?.resume(returning: ReminderListBox(reminders: []))
    }

    var isComplete: Bool {
        lock.lock()
        let complete = self.continuation == nil
        lock.unlock()
        return complete
    }
}

private extension CalendarEventColor {
    init(nsColor: NSColor?) {
        guard let color = nsColor?.usingColorSpace(.deviceRGB) else {
            self = .accent
            return
        }

        self.init(
            red: Double(color.redComponent),
            green: Double(color.greenComponent),
            blue: Double(color.blueComponent),
            alpha: Double(color.alphaComponent)
        )
    }
}
