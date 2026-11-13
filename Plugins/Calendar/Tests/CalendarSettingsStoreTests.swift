import XCTest
import MacToolsPluginKit
@testable import MacTools
@testable import CalendarPlugin

@MainActor
final class CalendarSettingsStoreTests: XCTestCase {
    func testPortableSettingsPreserveExplicitCalendarAcrossLanguages() throws {
        let source = CalendarSettingsStore(storage: CalendarSettingsMemoryStorage(), languageIdentifier: "en")
        source.setWeekStartDay(.monday)
        source.setAgendaRange(CalendarAgendaRange(dayCount: 5, direction: .past))
        source.setShowsRecentAgenda(false)
        source.setShowsReminders(false)
        let storage = CalendarSettingsMemoryStorage()
        storage.set("private", forKey: "local-calendar")
        let destination = CalendarSettingsStore(storage: storage, languageIdentifier: "zh-Hans")
        XCTAssertTrue(destination.restorePortableBackup(try XCTUnwrap(source.portableBackup())))
        let reloaded = CalendarSettingsStore(storage: storage, languageIdentifier: "zh-Hans")
        XCTAssertEqual(reloaded.alternateCalendar, .none)
        XCTAssertEqual(reloaded.weekStartDay, .monday)
        XCTAssertFalse(reloaded.showsRecentAgenda)
        XCTAssertFalse(reloaded.showsReminders)
        XCTAssertEqual(reloaded.agendaRange, CalendarAgendaRange(dayCount: 5, direction: .past))
        XCTAssertEqual(storage.string(forKey: "local-calendar"), "private")
    }


    func testWeekStartPersistsAndReloads() {
        let storage = CalendarSettingsMemoryStorage()
        let store = CalendarSettingsStore(storage: storage)

        store.setWeekStartDay(.thursday)

        XCTAssertEqual(storage.string(forKey: "settings.week-start-day"), "thursday")
        XCTAssertEqual(CalendarSettingsStore(storage: storage).weekStartDay, .thursday)
    }

    func testInvalidWeekStartFallsBackToSunday() {
        let storage = CalendarSettingsMemoryStorage()
        storage.set("invalid", forKey: "settings.week-start-day")

        XCTAssertEqual(CalendarSettingsStore(storage: storage).weekStartDay, .sunday)
    }

    func testAgendaRangeDefaultsToThreeFutureDaysAndPersists() {
        let storage = CalendarSettingsMemoryStorage()
        let store = CalendarSettingsStore(storage: storage)
        XCTAssertEqual(store.agendaRange, CalendarAgendaRange(dayCount: 3, direction: .future))

        store.setAgendaRange(CalendarAgendaRange(dayCount: 7, direction: .surrounding))

        XCTAssertEqual(CalendarSettingsStore(storage: storage).agendaRange,
                       CalendarAgendaRange(dayCount: 7, direction: .surrounding))
    }

    func testRemindersDefaultToVisibleAndPersist() {
        let storage = CalendarSettingsMemoryStorage()
        let store = CalendarSettingsStore(storage: storage)
        XCTAssertTrue(store.showsReminders)
        XCTAssertEqual(storage.object(forKey: "settings.shows-reminders") as? Bool, true)

        store.setShowsReminders(false)

        XCTAssertFalse(CalendarSettingsStore(storage: storage).showsReminders)
    }

    func testRemindersToggleSignalsPersistentChange() {
        let storage = CalendarSettingsMemoryStorage()
        let store = CalendarSettingsStore(storage: storage)
        var changeCount = 0
        store.onPersistentPreferencesChange = { changeCount += 1 }

        store.setShowsReminders(false)
        XCTAssertEqual(changeCount, 1)
        store.setShowsReminders(false)
        XCTAssertEqual(changeCount, 1, "An unchanged value must not emit a change")

        store.setShowsReminders(true)
        XCTAssertEqual(changeCount, 2)
    }

    func testInvalidRangeSettingsAreBounded() {
        let storage = CalendarSettingsMemoryStorage()
        storage.set(99, forKey: "settings.agenda-day-count")
        storage.set("invalid", forKey: "settings.agenda-direction")
        XCTAssertEqual(CalendarSettingsStore(storage: storage).agendaRange,
                       CalendarAgendaRange(dayCount: 7, direction: .future))
        storage.set(-1, forKey: "settings.agenda-day-count")
        XCTAssertEqual(CalendarSettingsStore(storage: storage).agendaRange.dayCount, 1)
    }

    func testAlternateCalendarDefaultsFromLanguageOnceAndPersistsSelection() {
        for (language, expected) in [("zh-Hans", CalendarAlternateCalendar.chinese), ("zh-Hant", .chinese), ("en", .none)] {
            let storage = CalendarSettingsMemoryStorage()
            let store = CalendarSettingsStore(storage: storage, languageIdentifier: language)
            XCTAssertEqual(store.alternateCalendar, expected)
            XCTAssertEqual(storage.string(forKey: "settings.alternate-calendar"), expected.rawValue)
            XCTAssertEqual(CalendarSettingsStore(storage: storage, languageIdentifier: "ja").alternateCalendar, expected)
            for selection in CalendarAlternateCalendar.allCases {
                store.setAlternateCalendar(selection)
                XCTAssertEqual(CalendarSettingsStore(storage: storage, languageIdentifier: "zh-Hans").alternateCalendar, selection)
            }
        }
    }

    func testInvalidAlternateCalendarFallsBackToLanguageDefault() {
        let storage = CalendarSettingsMemoryStorage()
        storage.set("invalid", forKey: "settings.alternate-calendar")
        XCTAssertEqual(CalendarSettingsStore(storage: storage, languageIdentifier: "en_CN").alternateCalendar, .none)
    }
}

@MainActor
private final class CalendarSettingsMemoryStorage: PluginStorage {
    private var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? {
        values[key]
    }

    func data(forKey key: String) -> Data? {
        values[key] as? Data
    }

    func string(forKey key: String) -> String? {
        values[key] as? String
    }

    func stringArray(forKey key: String) -> [String]? {
        values[key] as? [String]
    }

    func integer(forKey key: String) -> Int {
        values[key] as? Int ?? 0
    }

    func bool(forKey key: String) -> Bool {
        values[key] as? Bool ?? false
    }

    func set(_ value: Any?, forKey key: String) {
        values[key] = value
    }

    func removeObject(forKey key: String) {
        values.removeValue(forKey: key)
    }

    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {
        guard values[key] == nil, let value = values.removeValue(forKey: legacyKey) else {
            return
        }
        values[key] = value
    }
}
