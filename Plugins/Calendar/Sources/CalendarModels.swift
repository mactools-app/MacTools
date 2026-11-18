import Foundation
import MacToolsPluginKit

struct CalendarEventColor: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    static let accent = CalendarEventColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1.0)
}

enum CalendarItemKind: String, Equatable, Sendable {
    case event
    case reminder
}

struct CalendarEventInput: Equatable, Sendable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let color: CalendarEventColor
    var calendarTitle: String = ""
    var kind: CalendarItemKind = .event
    var isCompleted: Bool = false
}

struct CalendarEventSummary: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let timeText: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let color: CalendarEventColor
    var calendarTitle: String = ""
    var kind: CalendarItemKind = .event
    var isCompleted: Bool = false
}

enum CalendarHolidayKind: Int, Equatable, Sendable {
    case workday = 1
    case holiday = 2

    func badgeText(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        switch self {
        case .workday:
            return localization.string("holiday.badge.workday", defaultValue: "班")
        case .holiday:
            return localization.string("holiday.badge.holiday", defaultValue: "休")
        }
    }
}

struct CalendarDayModel: Identifiable, Equatable, Sendable {
    let id: String
    let date: Date
    let dayNumber: String
    let alternateCalendarText: String
    let alternateCalendarDateText: String
    let isInDisplayedMonth: Bool
    let isToday: Bool
    let isWeekend: Bool
    let holidayKind: CalendarHolidayKind?
    let events: [CalendarEventSummary]

    var visibleEvents: [CalendarEventSummary] {
        Array(events.prefix(Self.maximumVisibleEvents))
    }

    static let maximumVisibleEvents = 3
}

struct CalendarMonthModel: Equatable, Sendable {
    let displayedMonthStart: Date
    let title: String
    let weekdaySymbols: [String]
    let days: [CalendarDayModel]
}

enum CalendarComponentCalendars {
    static func gregorian(firstWeekday: Int = CalendarWeekStartDay.sunday.calendarFirstWeekday) -> Calendar {
        let current = Calendar.autoupdatingCurrent
        var calendar = current.identifier == .gregorian ? current : Calendar(identifier: .gregorian)
        calendar.locale = .autoupdatingCurrent
        calendar.timeZone = current.timeZone
        calendar.firstWeekday = min(max(firstWeekday, 1), 7)
        return calendar
    }

    static func monthStart(containing date: Date, calendar: Calendar) -> Date {
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: components) ?? calendar.startOfDay(for: date)
    }

    static func dayID(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d%02d%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}

struct CalendarMonthModelBuilder {
    private let calendar: Calendar
    private let lunarCalendar: Calendar
    private let holidayProvider: CalendarHolidayProvider
    private let localization: PluginLocalization
    private let showsHolidayBadges: Bool
    private let alternateCalendar: CalendarAlternateCalendar
    private let displayLocale: Locale

    init(
        calendar: Calendar = CalendarComponentCalendars.gregorian(),
        holidayProvider: CalendarHolidayProvider = .empty,
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        alternateCalendar: CalendarAlternateCalendar = .none,
        displayLocale: Locale = PluginRuntimeLocalization.locale
    ) {
        self.calendar = calendar
        self.holidayProvider = holidayProvider
        self.localization = localization
        self.displayLocale = displayLocale
        self.alternateCalendar = alternateCalendar
        var lunarCalendar = Calendar(identifier: .chinese)
        lunarCalendar.locale = Locale(identifier: "zh_Hans_CN")
        lunarCalendar.timeZone = calendar.timeZone
        self.lunarCalendar = lunarCalendar
        let regionalLocale = calendar.locale ?? .autoupdatingCurrent
        self.showsHolidayBadges = CalendarDisplayPolicy.showsMainlandHolidayBadges(in: regionalLocale)
    }

    func makeMonth(
        containing monthDate: Date,
        today: Date = Date(),
        eventsByDay: [Date: [CalendarEventSummary]] = [:]
    ) -> CalendarMonthModel {
        let monthStart = CalendarComponentCalendars.monthStart(containing: monthDate, calendar: calendar)
        let title = monthTitle(for: monthStart, calendar: calendar)
        let days = makeDays(displayedMonthStart: monthStart, today: today, eventsByDay: eventsByDay)

        return CalendarMonthModel(
            displayedMonthStart: monthStart,
            title: title,
            weekdaySymbols: weekdaySymbols(),
            days: days
        )
    }

    func makeDays(
        displayedMonthStart: Date,
        today: Date = Date(),
        eventsByDay: [Date: [CalendarEventSummary]] = [:]
    ) -> [CalendarDayModel] {
        guard let gridStart = gridStartDate(for: displayedMonthStart) else {
            return []
        }

        return (0..<42).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: gridStart) else {
                return nil
            }

            return makeDay(
                for: date, today: today, displayedMonthStart: displayedMonthStart,
                events: eventsByDay[calendar.startOfDay(for: date)] ?? []
            )
        }
    }

    func makeDay(
        for date: Date,
        today: Date,
        displayedMonthStart: Date? = nil,
        events: [CalendarEventSummary] = []
    ) -> CalendarDayModel {
        let dayStart = calendar.startOfDay(for: date)
        let components = calendar.dateComponents([.year, .month, .day], from: dayStart)
        let holidayKind = showsHolidayBadges ? holidayProvider.kind(for: dayStart, calendar: calendar) : nil
        let alternateDate = alternateDateText(for: dayStart)
        return CalendarDayModel(
            id: CalendarComponentCalendars.dayID(for: dayStart, calendar: calendar),
            date: dayStart,
            dayNumber: String(components.day ?? 0),
            alternateCalendarText: alternateDate.compact,
            alternateCalendarDateText: alternateDate.full,
            isInDisplayedMonth: calendar.isDate(
                dayStart, equalTo: displayedMonthStart ?? date, toGranularity: .month
            ),
            isToday: calendar.isDate(dayStart, inSameDayAs: today),
            isWeekend: calendar.isDateInWeekend(dayStart),
            holidayKind: holidayKind,
            events: events
        )
    }

    private func gridStartDate(for displayedMonthStart: Date) -> Date? {
        let weekday = calendar.component(.weekday, from: displayedMonthStart)
        let leadingDays = (weekday - calendar.firstWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: -leadingDays, to: displayedMonthStart)
    }

    private func weekdaySymbols() -> [String] {
        let symbols = [
            localization.string("weekday.sunday.short", defaultValue: "日"),
            localization.string("weekday.monday.short", defaultValue: "一"),
            localization.string("weekday.tuesday.short", defaultValue: "二"),
            localization.string("weekday.wednesday.short", defaultValue: "三"),
            localization.string("weekday.thursday.short", defaultValue: "四"),
            localization.string("weekday.friday.short", defaultValue: "五"),
            localization.string("weekday.saturday.short", defaultValue: "六")
        ]
        let startIndex = max(calendar.firstWeekday - 1, 0) % symbols.count
        return Array(symbols[startIndex..<symbols.count] + symbols[0..<startIndex])
    }

    private func alternateDateText(for date: Date) -> (compact: String, full: String) {
        switch alternateCalendar {
        case .none: ("", "")
        case .chinese: (chineseCalendarText(for: date), chineseCalendarDateText(for: date))
        }
    }

    private func chineseCalendarText(for date: Date) -> String {
        let components = lunarCalendar.dateComponents([.year, .month, .day, .isLeapMonth], from: date)
        let month = components.month ?? 1
        let day = components.day ?? 1

        if isLastDayOfLunarYear(date) {
            return localization.string("lunar.festival.newYearsEve", defaultValue: "除夕")
        }

        if components.isLeapMonth != true, let festival = lunarFestival(month: month, day: day) {
            return festival
        }

        if day == 1 {
            let prefix = components.isLeapMonth == true
                ? localization.string("lunar.leapPrefix", defaultValue: "闰")
                : ""
            return prefix + lunarMonthName(month)
        }

        return lunarDayName(day)
    }

    private func chineseCalendarDateText(for date: Date) -> String {
        let components = lunarCalendar.dateComponents([.month, .day, .isLeapMonth], from: date)
        let month = components.month ?? 1
        let day = components.day ?? 1
        let prefix = components.isLeapMonth == true
            ? localization.string("lunar.leapPrefix", defaultValue: "闰")
            : ""

        return prefix + lunarMonthName(month) + lunarDayName(day)
    }

    private func isLastDayOfLunarYear(_ date: Date) -> Bool {
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: date) else {
            return false
        }

        let year = lunarCalendar.component(.year, from: date)
        let nextYear = lunarCalendar.component(.year, from: nextDay)
        return year != nextYear
    }

    private func lunarFestival(month: Int, day: Int) -> String? {
        switch (month, day) {
        case (1, 1):
            return localization.string("lunar.festival.springFestival", defaultValue: "春节")
        case (1, 15):
            return localization.string("lunar.festival.lanternFestival", defaultValue: "元宵")
        case (5, 5):
            return localization.string("lunar.festival.dragonBoat", defaultValue: "端午")
        case (7, 7):
            return localization.string("lunar.festival.qixi", defaultValue: "七夕")
        case (8, 15):
            return localization.string("lunar.festival.midAutumn", defaultValue: "中秋")
        case (9, 9):
            return localization.string("lunar.festival.doubleNinth", defaultValue: "重阳")
        case (12, 8):
            return localization.string("lunar.festival.laba", defaultValue: "腊八")
        case (12, 23):
            return localization.string("lunar.festival.littleNewYear", defaultValue: "小年")
        default:
            return nil
        }
    }

    private func monthTitle(for date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = displayLocale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("yMMMM")
        return formatter.string(from: date)
    }

    private func lunarMonthName(_ month: Int) -> String {
        let names = [
            localization.string("lunar.month.1", defaultValue: "正月"),
            localization.string("lunar.month.2", defaultValue: "二月"),
            localization.string("lunar.month.3", defaultValue: "三月"),
            localization.string("lunar.month.4", defaultValue: "四月"),
            localization.string("lunar.month.5", defaultValue: "五月"),
            localization.string("lunar.month.6", defaultValue: "六月"),
            localization.string("lunar.month.7", defaultValue: "七月"),
            localization.string("lunar.month.8", defaultValue: "八月"),
            localization.string("lunar.month.9", defaultValue: "九月"),
            localization.string("lunar.month.10", defaultValue: "十月"),
            localization.string("lunar.month.11", defaultValue: "冬月"),
            localization.string("lunar.month.12", defaultValue: "腊月")
        ]
        guard (1...names.count).contains(month) else {
            return localization.string("lunar.month.fallback", defaultValue: "月")
        }

        return names[month - 1]
    }

    private func lunarDayName(_ day: Int) -> String {
        let names = [
            localization.string("lunar.day.1", defaultValue: "初一"),
            localization.string("lunar.day.2", defaultValue: "初二"),
            localization.string("lunar.day.3", defaultValue: "初三"),
            localization.string("lunar.day.4", defaultValue: "初四"),
            localization.string("lunar.day.5", defaultValue: "初五"),
            localization.string("lunar.day.6", defaultValue: "初六"),
            localization.string("lunar.day.7", defaultValue: "初七"),
            localization.string("lunar.day.8", defaultValue: "初八"),
            localization.string("lunar.day.9", defaultValue: "初九"),
            localization.string("lunar.day.10", defaultValue: "初十"),
            localization.string("lunar.day.11", defaultValue: "十一"),
            localization.string("lunar.day.12", defaultValue: "十二"),
            localization.string("lunar.day.13", defaultValue: "十三"),
            localization.string("lunar.day.14", defaultValue: "十四"),
            localization.string("lunar.day.15", defaultValue: "十五"),
            localization.string("lunar.day.16", defaultValue: "十六"),
            localization.string("lunar.day.17", defaultValue: "十七"),
            localization.string("lunar.day.18", defaultValue: "十八"),
            localization.string("lunar.day.19", defaultValue: "十九"),
            localization.string("lunar.day.20", defaultValue: "二十"),
            localization.string("lunar.day.21", defaultValue: "廿一"),
            localization.string("lunar.day.22", defaultValue: "廿二"),
            localization.string("lunar.day.23", defaultValue: "廿三"),
            localization.string("lunar.day.24", defaultValue: "廿四"),
            localization.string("lunar.day.25", defaultValue: "廿五"),
            localization.string("lunar.day.26", defaultValue: "廿六"),
            localization.string("lunar.day.27", defaultValue: "廿七"),
            localization.string("lunar.day.28", defaultValue: "廿八"),
            localization.string("lunar.day.29", defaultValue: "廿九"),
            localization.string("lunar.day.30", defaultValue: "三十")
        ]
        guard (1...names.count).contains(day) else {
            return ""
        }

        return names[day - 1]
    }

}
