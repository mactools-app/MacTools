import AppKit
import Carbon.HIToolbox
import CoreGraphics
import XCTest
import MacToolsPluginKit
@testable import MacTools
@testable import WindowSwitcherPlugin

@MainActor
final class WindowSwitcherMemoryStorage: PluginStorage {
    var values: [String: Any] = [:]

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
        guard values[key] == nil, let value = values[legacyKey] else {
            return
        }

        values[key] = value
        values.removeValue(forKey: legacyKey)
    }
}

@MainActor
private final class WindowSwitcherApplicationHarness: WindowSwitcherApplicationControlling {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let launchDate: Date?
    var isTerminated = false
    private(set) var unhideCount = 0
    private(set) var activationOptions: NSApplication.ActivationOptions?
    private(set) var terminateCount = 0

    init(
        processIdentifier: pid_t,
        bundleIdentifier: String? = "com.example.window-switcher",
        launchDate: Date? = nil
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.launchDate = launchDate
    }

    @discardableResult
    func unhide() -> Bool {
        unhideCount += 1
        return true
    }

    @discardableResult
    func activate(options: NSApplication.ActivationOptions) -> Bool {
        activationOptions = options
        return true
    }

    @discardableResult
    func terminate() -> Bool {
        terminateCount += 1
        isTerminated = true
        return true
    }
}

@MainActor
final class WindowSwitcherPluginTests: XCTestCase {

    func testPublishesForegroundCanonicalActionWithAccessibilityRequirement() throws {
        let plugin = WindowSwitcherPlugin(
            context: PluginRuntimeContext(
                pluginID: WindowSwitcherConstants.pluginID,
                storage: WindowSwitcherMemoryStorage()
            ),
            accessibilityTrusted: { true }
        )
        let definition = try XCTUnwrap(plugin.actionDefinitions.first)

        XCTAssertEqual(definition.key.actionID, WindowSwitcherConstants.shortcutActionID)
        XCTAssertEqual(definition.capabilities, [.foregroundInteractive, .opensInterface])
        XCTAssertEqual(definition.externalInvocationPolicy, .unavailable)
        XCTAssertEqual(
            plugin.permissionRequirementIDs(for: definition.key),
            [WindowSwitcherConstants.accessibilityPermissionID]
        )
        XCTAssertEqual(
            plugin.actionAvailability(for: ActionReference(key: definition.key)),
            .available
        )
    }

    func testCanonicalActionIsUnavailableWhenWindowSwitcherIsDisabled() throws {
        let plugin = WindowSwitcherPlugin(
            context: PluginRuntimeContext(
                pluginID: WindowSwitcherConstants.pluginID,
                storage: WindowSwitcherMemoryStorage()
            ),
            accessibilityTrusted: { true }
        )
        plugin.store.setEnabled(false)
        let definition = try XCTUnwrap(plugin.actionDefinitions.first)

        XCTAssertFalse(
            plugin.actionAvailability(for: ActionReference(key: definition.key)).isAvailable
        )
    }

    func testWindowRecordsKeepInactiveSpaceAndSameApplicationWindowsDistinct() {
        let records = WindowSwitcherWindowRecord.parse([
            windowInfo(
                number: 101,
                ownerPID: 321,
                title: "Finder — Space 1",
                isOnscreen: true,
                bounds: CGRect(x: 20, y: 40, width: 900, height: 700)
            ),
            windowInfo(
                number: 102,
                ownerPID: 321,
                title: "Finder — Space 2",
                isOnscreen: false,
                bounds: CGRect(x: 40, y: 60, width: 900, height: 700)
            ),
        ])

        XCTAssertEqual(records.map(\.windowNumber), [101, 102])
        XCTAssertEqual(records.map(\.processIdentifier), [321, 321])
        XCTAssertEqual(records.map(\.title), ["Finder — Space 1", "Finder — Space 2"])
        XCTAssertEqual(records.map(\.isOnScreen), [true, false])
    }

    func testAllSpaceRecordsPreferAXMetadataAndKeepCoreGraphicsWindows() {
        let records = WindowSwitcherWindowRecord.parse([
            windowInfo(
                number: 301,
                ownerPID: 321,
                title: "Shared title",
                isOnscreen: true,
                bounds: CGRect(x: 20, y: 40, width: 900, height: 700)
            ),
            windowInfo(
                number: 302,
                ownerPID: 321,
                title: "Inactive Space window",
                isOnscreen: false,
                bounds: CGRect(x: 40, y: 60, width: 900, height: 700)
            ),
        ])
        let axSnapshot = WindowSwitcherAllSpacesWindowSnapshot(
            element: nil,
            windowNumber: nil,
            title: "Shared title",
            isMinimized: true,
            position: CGPoint(x: 20, y: 40),
            size: CGSize(width: 900, height: 700)
        )

        let merged = WindowSwitcherAllSpacesCatalog.mergeWindowSnapshots(
            axSnapshots: [axSnapshot],
            records: records
        )

        XCTAssertEqual(merged.map(\.windowNumber), [301, 302])
        XCTAssertEqual(merged.map(\.title), ["Shared title", "Inactive Space window"])
        XCTAssertTrue(merged[0].isMinimized)
        XCTAssertNil(merged[1].element)

        let entries = WindowSwitcherAllSpacesCatalog.windowEntries(
            processIdentifier: 321,
            bundleIdentifier: "com.example.Finder",
            appName: "Finder",
            icon: nil,
            windows: merged
        )
        XCTAssertEqual(entries.map(\.id), ["window:321:cg:301", "window:321:cg:302"])
        XCTAssertTrue(entries.allSatisfy(\.isWindowEntry))

        let mixedEntries = WindowSwitcherAllSpacesCatalog.windowEntries(
            processIdentifier: 321,
            bundleIdentifier: "com.example.Finder",
            appName: "Finder",
            icon: nil,
            windows: [
                merged[0],
                WindowSwitcherAllSpacesWindowSnapshot(
                    element: nil,
                    windowNumber: nil,
                    title: "AX-only window",
                    isMinimized: false,
                    position: CGPoint(x: 60, y: 80),
                    size: CGSize(width: 900, height: 700)
                ),
            ]
        )
        XCTAssertEqual(mixedEntries.map(\.id), ["window:321:cg:301", "window:321:ax:1"])
        XCTAssertEqual(Set(mixedEntries.map(\.id)).count, mixedEntries.count)

        let applicationEntry = WindowSwitcherAllSpacesCatalog.applicationEntry(
            id: "bundle:com.example.Finder",
            processIdentifier: 321,
            bundleIdentifier: "com.example.Finder",
            appName: "Finder",
            icon: nil
        )
        XCTAssertFalse(applicationEntry.isWindowEntry)
        XCTAssertEqual(applicationEntry.displayName, "Finder")
    }

    func testAXFallbackLookupRejectsAmbiguousMatches() {
        let candidate = AXUIElementCreateSystemWide()
        let snapshot = WindowSwitcherAllSpacesWindowSnapshot(
            element: candidate,
            windowNumber: nil,
            title: "requested title",
            isMinimized: false,
            position: CGPoint(x: 80, y: 100),
            size: CGSize(width: 900, height: 700)
        )
        var snapshotCallCount = 0

        let result = WindowSwitcherAllSpacesCatalog.firstMatchingWindow(
            in: [candidate, candidate],
            title: "requested title",
            bounds: CGRect(x: 80, y: 100, width: 900, height: 700),
            deadline: Date().addingTimeInterval(1),
            now: { Date() },
            snapshotProvider: { _ in
                snapshotCallCount += 1
                return snapshot
            }
        )

        XCTAssertNil(result)
        XCTAssertEqual(snapshotCallCount, 2)
    }

    func testActivationRejectsAReusedProcessBeforeAnyApplicationSideEffect() async {
        let processIdentifier: pid_t = 323
        let currentLaunchDate = Date(timeIntervalSince1970: 2_000)
        let application = WindowSwitcherApplicationHarness(
            processIdentifier: processIdentifier,
            launchDate: currentLaunchDate
        )
        let catalog = WindowSwitcherAllSpacesCatalog(
            notificationCenter: NotificationCenter(),
            windowRecordProvider: { [] },
            applicationProvider: { _ in application }
        )
        let entry = WindowSwitcherAppEntry(
            id: "app:323",
            processIdentifier: processIdentifier,
            bundleIdentifier: "com.example.window-switcher",
            appName: "Window Switcher test app",
            windowTitle: nil,
            icon: nil,
            windowElement: nil,
            isMinimized: false,
            windowNumber: nil,
            windowBounds: nil,
            applicationLaunchDate: currentLaunchDate.addingTimeInterval(-1),
            shortcutToken: nil
        )

        await catalog.activate(entry)

        XCTAssertEqual(application.unhideCount, 0)
        XCTAssertNil(application.activationOptions)
    }

    func testCancelledApplicationActivationDoesNotPerformSideEffects() async {
        let processIdentifier: pid_t = 330
        let application = WindowSwitcherApplicationHarness(processIdentifier: processIdentifier)
        let catalog = WindowSwitcherAllSpacesCatalog(
            notificationCenter: NotificationCenter(),
            applicationProvider: { _ in application }
        )
        let entry = WindowSwitcherAllSpacesCatalog.applicationEntry(
            id: "app:330",
            processIdentifier: processIdentifier,
            bundleIdentifier: "com.example.window-switcher",
            appName: "Window Switcher test app",
            icon: nil
        )
        let task = Task { @MainActor in
            await Task.yield()
            await catalog.activate(entry)
        }

        task.cancel()
        await task.value

        XCTAssertEqual(application.unhideCount, 0)
        XCTAssertNil(application.activationOptions)
    }

    func testActivationRejectsStaleCoreGraphicsWindowBeforeUnhiding() async {
        let processIdentifier: pid_t = 324
        let launchDate = Date(timeIntervalSince1970: 3_002)
        let expectedBounds = CGRect(x: 80, y: 100, width: 900, height: 700)
        let application = WindowSwitcherApplicationHarness(
            processIdentifier: processIdentifier,
            launchDate: launchDate
        )
        let catalog = WindowSwitcherAllSpacesCatalog(
            notificationCenter: NotificationCenter(),
            windowRecordProvider: {
                [
                    WindowSwitcherWindowRecord(
                        windowNumber: 703,
                        processIdentifier: processIdentifier,
                        title: "Current title",
                        isOnScreen: true,
                        bounds: CGRect(x: 90, y: 110, width: 900, height: 700)
                    ),
                ]
            },
            applicationProvider: { _ in application }
        )
        let entry = WindowSwitcherAppEntry(
            id: "window:324:cg:703",
            processIdentifier: processIdentifier,
            bundleIdentifier: "com.example.window-switcher",
            appName: "Window Switcher test app",
            windowTitle: "Current title",
            icon: nil,
            windowElement: nil,
            isMinimized: false,
            windowNumber: 703,
            windowBounds: expectedBounds,
            applicationLaunchDate: launchDate,
            shortcutToken: nil
        )

        await catalog.activate(entry)

        XCTAssertEqual(application.unhideCount, 0)
        XCTAssertNil(application.activationOptions)
    }

    func testWindowRecordsIgnoreNonSwitchableOrTransparentWindows() {
        var missingAlpha = windowInfo(
            number: 204,
            ownerPID: 321,
            title: "Missing alpha",
            isOnscreen: true,
            bounds: CGRect(x: 20, y: 40, width: 900, height: 700)
        )
        missingAlpha.removeValue(forKey: kCGWindowAlpha as String)
        var booleanNumber = windowInfo(
            number: 205,
            ownerPID: 321,
            title: "Boolean number",
            isOnscreen: true,
            bounds: CGRect(x: 20, y: 40, width: 900, height: 700)
        )
        booleanNumber[kCGWindowNumber as String] = true
        let nonFiniteBounds = windowInfo(
            number: 206,
            ownerPID: 321,
            title: "Non-finite bounds",
            isOnscreen: true,
            bounds: CGRect(x: CGFloat.infinity, y: 40, width: 900, height: 700)
        )

        let records = WindowSwitcherWindowRecord.parse([
            windowInfo(
                number: 201,
                ownerPID: 321,
                title: "Too small",
                isOnscreen: true,
                bounds: CGRect(x: 20, y: 40, width: 79, height: 60)
            ),
            windowInfo(
                number: 202,
                ownerPID: 321,
                title: "Transparent",
                isOnscreen: false,
                bounds: CGRect(x: 20, y: 40, width: 900, height: 700),
                alpha: 0
            ),
            windowInfo(
                number: 203,
                ownerPID: 321,
                title: "Menu",
                isOnscreen: true,
                bounds: CGRect(x: 20, y: 40, width: 900, height: 700),
                layer: 1
            ),
            missingAlpha,
            booleanNumber,
            nonFiniteBounds,
        ])

        XCTAssertTrue(records.isEmpty)
    }

    func testEnabledStatePersists() {
        let storage = WindowSwitcherMemoryStorage()
        let store = WindowSwitcherStore(storage: storage)

        store.setEnabled(false)

        let loaded = WindowSwitcherStore(storage: storage)
        XCTAssertFalse(loaded.configuration.isEnabled)
    }

    func testManualShortcutTakesPriorityOverConflictingAutomaticShortcut() {
        let entries = [
            makeEntry(index: 0, appName: "Safari", bundleIdentifier: "com.apple.Safari"),
            makeEntry(index: 1, appName: "Finder", bundleIdentifier: "com.apple.finder"),
        ]
        let state = WindowSwitcherShortcutBindingState(
            manual: ["bundle:com.apple.Safari": "f"],
            automatic: ["bundle:com.apple.finder": "f"]
        )

        let result = WindowSwitcherShortcutAssignment.assignShortcuts(
            to: entries,
            bindingState: state
        )

        XCTAssertEqual(result.entries[0].shortcutToken, "f")
        XCTAssertEqual(result.entries[1].shortcutToken, "j")
        XCTAssertEqual(result.bindingState.manual["bundle:com.apple.Safari"], "f")
        XCTAssertEqual(result.bindingState.automatic["bundle:com.apple.finder"], "j")
    }

    func testManualShortcutRejectsConflictWithRunningEntry() {
        let store = WindowSwitcherStore(storage: WindowSwitcherMemoryStorage())
        let entries = store.assignShortcuts(to: [
            makeEntry(index: 0, appName: "Safari", bundleIdentifier: "com.apple.Safari"),
            makeEntry(index: 1, appName: "Finder", bundleIdentifier: "com.apple.finder"),
        ])
        let finderToken = entries[1].shortcutToken
        let bindingsBeforeConflict = store.shortcutBindings

        let result = store.setManualShortcut(finderToken, for: entries[0].id, in: entries)

        guard case .conflict = result else {
            return XCTFail("Expected an active shortcut conflict.")
        }
        XCTAssertEqual(store.shortcutBindings, bindingsBeforeConflict)
        XCTAssertEqual(store.assignShortcuts(to: entries), entries)
    }

    func testManualShortcutPersistsAndSurvivesSortingChanges() {
        let storage = WindowSwitcherMemoryStorage()
        let store = WindowSwitcherStore(storage: storage)
        let entries = store.assignShortcuts(to: [
            makeEntry(index: 0, appName: "Safari", bundleIdentifier: "com.apple.Safari"),
            makeEntry(index: 1, appName: "Finder", bundleIdentifier: "com.apple.finder"),
        ])

        let result = store.setManualShortcut("q", for: entries[0].id, in: entries)
        guard case let .updated(updatedEntries) = result else {
            return XCTFail("Expected a saved manual shortcut.")
        }

        XCTAssertEqual(updatedEntries[0].shortcutToken, "q")
        let loaded = WindowSwitcherStore(storage: storage)
        let reordered = loaded.assignShortcuts(to: [entries[1], entries[0]])
        XCTAssertEqual(reordered[0].shortcutToken, entries[1].shortcutToken)
        XCTAssertEqual(reordered[1].shortcutToken, "q")
        XCTAssertEqual(loaded.shortcutBindings.manual["bundle:com.apple.Safari"], "q")
    }

    func testClearingManualShortcutRestoresAutomaticShortcut() {
        let store = WindowSwitcherStore(storage: WindowSwitcherMemoryStorage())
        let entries = store.assignShortcuts(to: [
            makeEntry(index: 0, appName: "Safari", bundleIdentifier: "com.apple.Safari"),
        ])
        XCTAssertEqual(entries[0].shortcutToken, "s")
        guard case let .updated(customized) = store.setManualShortcut(
            "q",
            for: entries[0].id,
            in: entries
        ) else {
            return XCTFail("Expected a saved manual shortcut.")
        }

        let result = store.setManualShortcut(nil, for: customized[0].id, in: customized)

        guard case let .updated(restored) = result else {
            return XCTFail("Expected the manual shortcut to be cleared.")
        }
        XCTAssertEqual(restored[0].shortcutToken, "s")
        XCTAssertTrue(store.shortcutBindings.manual.isEmpty)
        XCTAssertEqual(store.shortcutBindings.automatic["bundle:com.apple.Safari"], "s")
    }

    func testMultiWindowEntriesUseDistinctPersistentBindingIdentities() {
        let store = WindowSwitcherStore(storage: WindowSwitcherMemoryStorage())
        let entries = store.assignShortcuts(to: [
            makeEntry(index: 0, appName: "Safari", bundleIdentifier: "com.apple.Safari"),
            makeEntry(index: 1, appName: "Safari", bundleIdentifier: "com.apple.Safari"),
        ])

        let result = store.setManualShortcut("q", for: entries[1].id, in: entries)

        guard case let .updated(updated) = result else {
            return XCTFail("Expected a saved shortcut for the second window.")
        }
        XCTAssertEqual(updated[0].shortcutToken, "s")
        XCTAssertEqual(updated[1].shortcutToken, "q")
        XCTAssertEqual(
            store.shortcutBindings.manual["bundle:com.apple.Safari#window:2"],
            "q"
        )
    }

    func testFocusStillRaisesWindowWhenFocusedAttributeIsReadOnly() {
        let window = AXUIElementCreateSystemWide()
        var writtenAttributes: [String] = []
        var didRaise = false

        WindowSwitcherAllSpacesCatalog.focusWindow(
            window,
            isMinimized: false,
            deadline: Date().addingTimeInterval(1),
            writeAttribute: { _, attribute, _, _ in
                writtenAttributes.append(attribute as String)
                return attribute as String != kAXFocusedAttribute as String
            },
            performRaise: { _, _ in
                didRaise = true
                return true
            }
        )

        XCTAssertEqual(
            writtenAttributes,
            [kAXMainAttribute as String, kAXFocusedAttribute as String]
        )
        XCTAssertTrue(didRaise)
    }

    func testPortableCanonicalAppBindingSurvivesDifferentProcessAndWindowIdentities() throws {
        let source = WindowSwitcherStore(storage: WindowSwitcherMemoryStorage())
        let app = makeEntry(index: 0, appName: "Editor", bundleIdentifier: "com.example.editor")
        _ = source.setManualShortcut("q", for: app.id, in: [app])
        let data = try XCTUnwrap(source.portableBackup())
        let storage = WindowSwitcherMemoryStorage()
        let destination = WindowSwitcherStore(storage: storage)
        XCTAssertTrue(destination.restorePortableBackup(data))
        var firstWindow = app
        firstWindow.windowNumber = 42
        XCTAssertEqual(destination.assignShortcuts(to: [firstWindow]).first?.shortcutToken, "q")
        XCTAssertEqual(destination.portableBackup(), data)
        let reloaded = WindowSwitcherStore(storage: storage)
        var secondWindow = makeEntry(index: 20, appName: "Editor", bundleIdentifier: "com.example.editor")
        secondWindow.windowNumber = 900
        let entries = reloaded.assignShortcuts(to: [secondWindow])
        XCTAssertEqual(entries.first?.shortcutToken, "q")
        XCTAssertEqual(reloaded.portableBackup(), data)
        _ = reloaded.setManualShortcut(nil, for: secondWindow.id, in: entries)
        XCTAssertNil(reloaded.shortcutBindings.manual["bundle:com.example.editor"])
    }

    func testFailedManualWriteReportsFailureAndInactiveDuplicateTokensRemainPortable() throws {
        let storage = FakePluginStorage()
        let store = WindowSwitcherStore(storage: storage)
        let a = makeEntry(index: 0, appName: "A", bundleIdentifier: "com.example.a")
        let b = makeEntry(index: 1, appName: "B", bundleIdentifier: "com.example.b")
        _ = store.setManualShortcut("q", for: a.id, in: [a])
        _ = store.setManualShortcut("q", for: b.id, in: [b])
        XCTAssertNotNil(store.portableBackup())
        let before = store.shortcutBindings
        var signals = 0
        store.onPersistentPreferencesChange = { signals += 1 }
        storage.rejectedKeys.insert("shortcut-bindings")
        if case .updated = store.setManualShortcut("w", for: b.id, in: [b]) { XCTFail("Failed write reported success") }
        XCTAssertEqual(store.shortcutBindings, before)
        XCTAssertEqual(signals, 0)
    }

    private func makeEntry(
        index: Int,
        appName: String,
        bundleIdentifier: String? = nil
    ) -> WindowSwitcherAppEntry {
        WindowSwitcherAppEntry(
            id: "app-\(index)",
            processIdentifier: pid_t(index + 100),
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            windowTitle: nil,
            icon: nil,
            windowElement: nil,
            isMinimized: false,
            windowNumber: nil,
            windowBounds: nil,
            shortcutToken: nil
        )
    }

    private func windowInfo(
        number: Int,
        ownerPID: Int,
        title: String,
        isOnscreen: Bool,
        bounds: CGRect,
        layer: Int = 0,
        alpha: Double = 1
    ) -> [String: Any] {
        [
            kCGWindowNumber as String: number,
            kCGWindowOwnerPID as String: ownerPID,
            kCGWindowLayer as String: layer,
            kCGWindowAlpha as String: alpha,
            kCGWindowName as String: title,
            kCGWindowIsOnscreen as String: isOnscreen,
            kCGWindowBounds as String: bounds.dictionaryRepresentation,
        ]
    }
}
