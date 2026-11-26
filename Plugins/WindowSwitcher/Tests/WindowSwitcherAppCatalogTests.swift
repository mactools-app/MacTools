import AppKit
import ApplicationServices
import XCTest
@testable import WindowSwitcherPlugin

private final class CatalogAXAccess: WindowSwitcherAXAccess, @unchecked Sendable {
    struct State {
        var number: CGWindowID?
        var focused = false
        var focusesExcludedPanel = false
        var secondWindowNumber: CGWindowID?
        var focusesSecondWindow = false
        var windowListUnavailable = false
        var windowMetadataUnavailable = false
        var beforeRead: (() -> Void)?
        var afterReadingFocus: (() -> Void)?
        var reads = 0
        var actions: [String] = []
    }
    private let lock = NSLock()
    private var state: State
    private let window: AXUIElement
    private let secondWindow: AXUIElement
    let observesSystemNotifications = false

    init(number: CGWindowID?, elementPID: pid_t) {
        state = State(number: number)
        window = AXUIElementCreateApplication(elementPID)
        secondWindow = AXUIElementCreateApplication(elementPID + 100)
    }
    func update(_ body: (inout State) -> Void) { lock.lock(); defer { lock.unlock() }; body(&state) }
    func read<T>(_ body: (State) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(state) }
    func windows(of application: AXUIElement) -> [AXUIElement]? {
        update { $0.reads += 1 }
        read { $0.beforeRead }?()
        return read { state in
            guard !state.windowListUnavailable else { return nil }
            let windows = state.number == nil ? [] : [window]
            return state.focusesExcludedPanel || state.secondWindowNumber != nil ? windows + [secondWindow] : windows
        }
    }
    func element(_ owner: AXUIElement, attribute: String) -> AXUIElement? {
        if attribute == kAXFocusedWindowAttribute {
            let focused = read { $0.focusesExcludedPanel || $0.focusesSecondWindow ? secondWindow : ($0.focused ? window : nil) }
            read { $0.afterReadingFocus }?()
            return focused
        }
        return attribute == kAXCloseButtonAttribute ? owner : nil
    }
    func windowAttributes(_ window: AXUIElement) -> [Any]? {
        guard !read({ $0.windowMetadataUnavailable }) else { return nil }
        var point = CGPoint(x: 20, y: 20)
        var size = CGSize(width: 800, height: 600)
        let isPanel = CFEqual(window, secondWindow) && read { $0.focusesExcludedPanel }
        let subrole = isPanel ? "AXFloatingWindow" : kAXStandardWindowSubrole
        return [kAXWindowRole, subrole, "Fixture", false,
                AXValueCreate(.cgPoint, &point)!, AXValueCreate(.cgSize, &size)!]
    }
    func windowNumber(_ window: AXUIElement) -> CGWindowID? {
        read { CFEqual(window, secondWindow) ? $0.secondWindowNumber : $0.number }
    }
    func minimized(_ window: AXUIElement) -> Bool? { false }
    func set(_ element: AXUIElement, attribute: String, value: Bool) -> AXError { .success }
    func perform(_ element: AXUIElement, action: String) -> AXError {
        update { $0.actions.append(action) }
        return .success
    }
}

@MainActor
final class WindowSwitcherAppCatalogTests: XCTestCase {
    func testPublishedWindowCarriesOnlyCatalogVerifiedPreviewProcesses() {
        let entry = WindowSwitcherAppEntry(id: "window", processIdentifier: 42,
            bundleIdentifier: "fixture", appName: "Fixture", windowTitle: "Window", icon: nil,
            windowElement: AXUIElementCreateApplication(42), isMinimized: false,
            windowNumber: 7, shortcutToken: nil)
        var publication = WindowSwitcherPublishedWindows()
        publication.update(snapshots: [42: [entry]], records: [], recordsAreFresh: true,
            helperProcessIdentifiers: [42: [43, 44]])

        XCTAssertEqual(publication.entries.first?.previewProcessIdentifiers, [42, 43, 44])
    }

    func testTitlelessAXSurfaceWithoutSpaceIsNotPublished() {
        func entry(_ number: CGWindowID, title: String) -> WindowSwitcherAppEntry {
            WindowSwitcherAppEntry(id: "window-\(number)", processIdentifier: 42,
                bundleIdentifier: "fixture", appName: "Fixture", windowTitle: title, icon: nil,
                windowElement: AXUIElementCreateApplication(42), isMinimized: false,
                windowNumber: number, shortcutToken: nil)
        }
        var ghost = WindowSwitcherWindowRecord(windowNumber: 7, processIdentifier: 42,
            title: "", isOnScreen: nil, bounds: CGRect(x: 0, y: 0, width: 500, height: 500))
        ghost.hasSpace = false
        var real = WindowSwitcherWindowRecord(windowNumber: 8, processIdentifier: 42,
            title: "", isOnScreen: true, bounds: CGRect(x: 20, y: 20, width: 800, height: 600))
        real.hasSpace = true

        let published = WindowSwitcherAppCatalog.mergeAllSpacesEntries(
            [entry(7, title: ""), entry(8, title: "")], records: [ghost, real])
        XCTAssertEqual(published.compactMap(\.windowNumber), [8])
    }

    func testSoleTitlelessAXSurfaceWithoutSpaceIsNotPublished() {
        let entry = WindowSwitcherAppEntry(id: "ghost", processIdentifier: 42,
            bundleIdentifier: "fixture", appName: "Fixture", windowTitle: "", icon: nil,
            windowElement: AXUIElementCreateApplication(42), isMinimized: false,
            windowNumber: 7, shortcutToken: nil)
        var ghost = WindowSwitcherWindowRecord(windowNumber: 7, processIdentifier: 42,
            title: "", isOnScreen: false, bounds: CGRect(x: 0, y: 0, width: 500, height: 500))
        ghost.hasSpace = false
        var publication = WindowSwitcherPublishedWindows()

        publication.update(snapshots: [42: [entry]], records: [ghost], recordsAreFresh: true)

        XCTAssertTrue(publication.entries.isEmpty)
    }

    func testMinimizedWindowUsesRestorePathUnlessExplicitlyOnAnotherSpace() {
        var minimized = WindowSwitcherAppEntry(id: "minimized", processIdentifier: 42,
            bundleIdentifier: "fixture", appName: "Fixture", windowTitle: "Window", icon: nil,
            windowElement: AXUIElementCreateApplication(42), isMinimized: true,
            windowNumber: 7, shortcutToken: nil)
        minimized.windowOwnerPID = 43
        var record = WindowSwitcherWindowRecord(windowNumber: 7, processIdentifier: 43,
            title: "Window", isOnScreen: false, bounds: CGRect(x: 20, y: 20, width: 800, height: 600))
        record.hasSpace = true
        record.isOnActiveSpace = true
        XCTAssertFalse(WindowSwitcherAppCatalog.needsExactSpaceReveal(minimized, records: [record]))

        record.isOnActiveSpace = nil
        XCTAssertFalse(WindowSwitcherAppCatalog.needsExactSpaceReveal(minimized, records: [record]))

        record.isOnActiveSpace = false
        XCTAssertTrue(WindowSwitcherAppCatalog.needsExactSpaceReveal(minimized, records: [record]))

        var visibleEntry = WindowSwitcherAppEntry(id: "other-space", processIdentifier: 42,
            bundleIdentifier: "fixture", appName: "Fixture", windowTitle: "Window", icon: nil,
            windowElement: AXUIElementCreateApplication(42), isMinimized: false,
            windowNumber: 7, shortcutToken: nil)
        visibleEntry.windowOwnerPID = 43
        XCTAssertTrue(WindowSwitcherAppCatalog.needsExactSpaceReveal(visibleEntry, records: [record]))
    }

    func testOpenChooserKeepsSelectionWhileWindowMovesToAnotherSpace() throws {
        func entry(_ number: CGWindowID?, owner: pid_t) -> WindowSwitcherAppEntry {
            WindowSwitcherAppEntry(id: number.map { "window:\($0)" } ?? "app:\(owner)", processIdentifier: owner,
                bundleIdentifier: "fixture.\(owner)", appName: "Fixture", windowTitle: number.map { "Window \($0)" }, icon: nil,
                windowElement: number.map { _ in AXUIElementCreateApplication(owner) }, isMinimized: false,
                windowNumber: number, shortcutToken: nil)
        }

        let moving = entry(7, owner: 42)
        let otherWindows = [entry(6, owner: 43), entry(8, owner: 43)]
        let otherRecords = [visibleRecord(6, owner: 43), visibleRecord(8, owner: 43)]
        let previousRecords = otherRecords + [visibleRecord(7, owner: 42)]
        let previousCapture = ContinuousClock.now
        let newerAXList = previousCapture.advanced(by: .milliseconds(10))
        let completeWindowLists: [pid_t: WindowSwitcherPublishedWindows.CompleteWindowList] = [
            42: .init(startedAt: newerAXList, windowNumbers: [], isEmpty: true)
        ]
        let nextCapture = newerAXList.advanced(by: .milliseconds(10))
        var publication = WindowSwitcherPublishedWindows()
        publication.update(snapshots: [42: [moving], 43: otherWindows], records: previousRecords,
                           recordsAreFresh: true, recordsStartedAt: previousCapture)
        let initialRows = publication.entries.sorted { ($0.windowNumber ?? 0) < ($1.windowNumber ?? 0) }
        var session = WindowSwitcherSession(entries: initialRows, selectedID: moving.id,
                                            isPersistent: true, originalWindowID: moving.id)
        session.query = "Window 7"

        let snapshots: [pid_t: [WindowSwitcherAppEntry]] = [42: [entry(nil, owner: 42)], 43: otherWindows]
        publication.update(snapshots: snapshots, records: previousRecords, recordsAreFresh: true,
                           completeWindowLists: completeWindowLists, recordsStartedAt: previousCapture)
        let unconfirmed = try XCTUnwrap(publication.entries.first { $0.id == moving.id })
        XCTAssertTrue(unconfirmed.isAwaitingWindowConfirmation)
        XCTAssertNil(unconfirmed.windowElement)
        session.reconcile(publication.entries)
        XCTAssertEqual(session.entries.compactMap(\.windowNumber), [6, 7, 8])
        XCTAssertEqual(session.selectedID, moving.id)

        var laterSession = WindowSwitcherSession(entries: otherWindows, selectedID: nil,
                                                 isPersistent: true, originalWindowID: nil)
        laterSession.reconcile(publication.entries)
        XCTAssertEqual(laterSession.entries.compactMap(\.windowNumber), [6, 8])

        let unknownPlacement = WindowSwitcherWindowRecord(windowNumber: 7, processIdentifier: 42, title: "Window 7",
            isOnScreen: nil, bounds: unconfirmed.bounds)
        publication.update(snapshots: snapshots, records: otherRecords + [unknownPlacement], recordsAreFresh: true,
                           completeWindowLists: completeWindowLists, recordsStartedAt: nextCapture)
        XCTAssertEqual(publication.entries.first { $0.id == moving.id }?.isAwaitingWindowConfirmation, true)
        session.reconcile(publication.entries)
        laterSession.reconcile(publication.entries)
        XCTAssertEqual(session.selectedID, moving.id)
        XCTAssertEqual(laterSession.entries.compactMap(\.windowNumber), [6, 8])

        let moved = WindowSwitcherWindowRecord(windowNumber: 7, processIdentifier: 42, title: "Window 7",
            isOnScreen: false, bounds: unconfirmed.bounds, hasSpace: true, isOnActiveSpace: false)
        publication.update(snapshots: snapshots, records: otherRecords + [moved], recordsAreFresh: true,
                           completeWindowLists: completeWindowLists, recordsStartedAt: nextCapture.advanced(by: .milliseconds(10)))
        session.reconcile(publication.entries)
        XCTAssertEqual(session.entries.compactMap(\.windowNumber), [6, 7, 8])
        XCTAssertEqual(session.selectedID, moving.id)
        XCTAssertEqual(session.selected?.isOnOtherDesktop, true)
        XCTAssertEqual(session.selected?.isAwaitingWindowConfirmation, false)
        laterSession.reconcile(publication.entries)
        XCTAssertEqual(laterSession.entries.compactMap(\.windowNumber), [6, 8, 7])

        publication.update(snapshots: snapshots, records: otherRecords, recordsAreFresh: true,
                           completeWindowLists: completeWindowLists, recordsStartedAt: nextCapture.advanced(by: .milliseconds(20)))
        session.reconcile(publication.entries)
        XCTAssertEqual(session.entries.compactMap(\.windowNumber), [6, 8])
    }

    func testReplacementWindowCannotInheritPendingSelection() throws {
        let original = catalogRow("original", owner: 42, number: 7, elementPID: 201)
        let replacement = catalogRow("replacement", owner: 42, number: 7, elementPID: 202)
        let other = catalogRow("other", owner: 43, number: 8, elementPID: 203)
        let application = catalogRow("app", owner: 42)
        let oldCapture = ContinuousClock.now
        let records = [visibleRecord(7, owner: 42), visibleRecord(8, owner: 43)]
        var publication = WindowSwitcherPublishedWindows()
        publication.update(snapshots: [42: [original], 43: [other]], records: records,
                           recordsAreFresh: true, recordsStartedAt: oldCapture)
        var session = WindowSwitcherSession(entries: publication.entries, selectedID: original.id,
                                            isPersistent: true, originalWindowID: original.id)

        publication.update(snapshots: [42: [application], 43: [other]], records: records, recordsAreFresh: true,
                           completeWindowLists: [42: .init(startedAt: oldCapture + .milliseconds(10), windowNumbers: [], isEmpty: true)],
                           recordsStartedAt: oldCapture)
        session.reconcile(publication.entries)
        XCTAssertEqual(session.selectedID, original.id)

        publication.update(snapshots: [42: [replacement], 43: [other]], records: records, recordsAreFresh: true,
                           completeWindowLists: [42: .init(startedAt: oldCapture + .milliseconds(20), windowNumbers: [7], isEmpty: false)],
                           recordsStartedAt: oldCapture)
        session.reconcile(publication.entries)
        XCTAssertEqual(session.entries.map(\.id), [other.id, replacement.id])
        XCTAssertEqual(session.selectedID, other.id)
    }

    func testCompleteWindowMembershipSurvivesAnIncompleteRead() throws {
        let first = catalogRow("first", owner: 42, number: 7, elementPID: 201)
        let second = catalogRow("second", owner: 42, number: 8, elementPID: 202)
        let records = [visibleRecord(7, owner: 42), visibleRecord(8, owner: 42)]
        let oldCapture = ContinuousClock.now
        let completeWindowLists: [pid_t: WindowSwitcherPublishedWindows.CompleteWindowList] = [
            42: .init(startedAt: oldCapture + .milliseconds(10), windowNumbers: [7, 8], isEmpty: false)
        ]
        var publication = WindowSwitcherPublishedWindows()
        publication.update(snapshots: [42: [first, second]], records: records, recordsAreFresh: true,
                           completeWindowLists: completeWindowLists, recordsStartedAt: oldCapture)
        publication.update(snapshots: [42: [first]], records: records, recordsAreFresh: false,
                           completeWindowLists: completeWindowLists, recordsStartedAt: oldCapture)

        let retained = try XCTUnwrap(publication.entries.first { $0.id == second.id })
        XCTAssertFalse(retained.isAwaitingWindowConfirmation)
    }

    func testPendingSelectedWindowSurvivesIncompleteMetadataRead() async throws {
        let moving = CatalogAXAccess(number: 7, elementPID: 201)
        let captures = CatalogAXAccess(number: nil, elementPID: 203)
        let catalog = catalogWithLingeringWindow(moving, captures: captures)
        defer { catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }
        let initial = fixtureEntries(catalog)
        let selected = try XCTUnwrap(initial.first { $0.windowNumber == 7 })
        var session = WindowSwitcherSession(entries: initial, selectedID: selected.id,
                                            isPersistent: true, originalWindowID: selected.id)
        moving.update { $0.number = nil }
        catalog.invalidate(processIdentifiers: [42], windowRecords: false)
        try await waitUntil {
            self.fixtureEntries(catalog).contains { $0.id == selected.id && $0.isAwaitingWindowConfirmation }
        }
        session.reconcile(fixtureEntries(catalog))

        moving.update { $0.number = 9; $0.windowMetadataUnavailable = true }
        catalog.invalidate(processIdentifiers: [42], windowRecords: false)
        try await waitUntil { catalog.unavailableApplicationCount == 1 }
        // Opening drains any completed publication without asking WindowServer for another capture.
        let opening = try XCTUnwrap(catalog.opening(sortMode: .fixed))
        XCTAssertEqual(fixtureEntries(opening).compactMap(\.windowNumber), [8])
        XCTAssertEqual(captures.read { $0.reads }, 1)
        session.reconcile(fixtureEntries(catalog))
        XCTAssertEqual(session.entries.compactMap(\.windowNumber), [7, 8])
        XCTAssertEqual(session.selectedID, selected.id)
    }

    func testPendingSelectionCannotActivateUntilWindowIsConfirmed() async throws {
        let moving = CatalogAXAccess(number: 7, elementPID: 201)
        let catalog = catalogWithLingeringWindow(moving)
        defer { catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }
        let rows = fixtureEntries(catalog)
        let original = try XCTUnwrap(rows.first { $0.windowNumber == 7 })
        var session = WindowSwitcherSession(entries: rows, selectedID: original.id,
                                            isPersistent: true, originalWindowID: original.id)
        XCTAssertTrue(catalog.canActivate(original))

        moving.update { $0.number = nil }
        catalog.invalidate(processIdentifiers: [42], windowRecords: false)
        try await waitUntil {
            self.fixtureEntries(catalog).contains { $0.id == original.id && $0.isAwaitingWindowConfirmation }
        }
        session.reconcile(fixtureEntries(catalog))
        let retainedSelection = try XCTUnwrap(session.selected)
        XCTAssertEqual(retainedSelection.id, original.id)
        XCTAssertFalse(catalog.canActivate(retainedSelection))

        moving.update { $0.number = 7 }
        catalog.invalidate(processIdentifiers: [42], windowRecords: false)
        try await waitUntil {
            self.fixtureEntries(catalog).contains { $0.id == original.id && !$0.isAwaitingWindowConfirmation }
        }
        XCTAssertTrue(catalog.canActivate(retainedSelection))
    }

    func testIncompleteMetadataReadCannotRepublishSuppressedWindow() async throws {
        let closed = CatalogAXAccess(number: nil, elementPID: 201)
        let captures = CatalogAXAccess(number: nil, elementPID: 203)
        let catalog = catalogWithLingeringWindow(closed, captures: captures)
        defer { catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }
        let initial = try XCTUnwrap(catalog.opening(sortMode: .fixed))
        XCTAssertEqual(fixtureEntries(initial).compactMap(\.windowNumber), [8])

        closed.update { $0.number = 9; $0.windowMetadataUnavailable = true }
        catalog.invalidate(processIdentifiers: [42], windowRecords: false)
        try await waitUntil { catalog.unavailableApplicationCount == 1 }
        let afterPartialRead = try XCTUnwrap(catalog.opening(sortMode: .fixed))
        XCTAssertEqual(fixtureEntries(afterPartialRead).compactMap(\.windowNumber), [8])
        XCTAssertEqual(captures.read { $0.reads }, 1)
    }

    private func catalogWithLingeringWindow(_ first: CatalogAXAccess, captures: CatalogAXAccess? = nil)
        -> WindowSwitcherAppCatalog {
        let other = CatalogAXAccess(number: 8, elementPID: 202)
        return WindowSwitcherAppCatalog(notificationCenter: NotificationCenter(),
            accessFactory: { $0 == 42 ? first : other },
            allSpacesCatalog: .init(windowRecordProvider: {
                captures?.update { $0.reads += 1 }
                return [visibleRecord(7, owner: 42), visibleRecord(8, owner: 43)]
            }), discovery: .init(applications: {
                [.init(processIdentifier: 42, localizedName: "First"),
                 .init(processIdentifier: 43, localizedName: "Other")]
            }, foregroundPID: { 43 }, isLaunching: { _ in false },
               isAccessibilityTrusted: { true }, isDragging: { false }))
    }

    private func catalogRow(_ id: String, owner: pid_t, number: CGWindowID? = nil, elementPID: pid_t? = nil)
        -> WindowSwitcherAppEntry {
        WindowSwitcherAppEntry(id: id, processIdentifier: owner, bundleIdentifier: "fixture.\(owner)",
            appName: "Fixture", windowTitle: number.map { "Window \($0)" }, icon: nil,
            windowElement: elementPID.map { AXUIElementCreateApplication($0) },
            isMinimized: false, windowNumber: number, shortcutToken: nil)
    }

    func testInvalidationRefreshesChangedWindowsWithoutScanningOtherHosts() async throws {
        let first = CatalogAXAccess(number: 7, elementPID: 201)
        let second = CatalogAXAccess(number: 8, elementPID: 202)
        let cgReads = CatalogAXAccess(number: nil, elementPID: 203)
        let catalog = twoHostCatalog(first, second, cgReads: cgReads)
        defer { catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }
        let secondReads = second.read { $0.reads }
        let recordReads = cgReads.read { $0.reads }
        first.update { $0.number = 9 }
        catalog.invalidate(processIdentifiers: [42], windowRecords: false)
        try await waitUntil { self.numbers(catalog) == [9] }
        XCTAssertEqual(second.read { $0.reads }, secondReads)
        XCTAssertEqual(cgReads.read { $0.reads }, recordReads)
    }

    func testInvocationReconcilesANonemptyCacheBeforeBecomingReady() async throws {
        let first = CatalogAXAccess(number: 7, elementPID: 201)
        let second = CatalogAXAccess(number: 8, elementPID: 202)
        let catalog = twoHostCatalog(first, second)
        defer { catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }
        first.update { $0.number = 9 }
        catalog.prepareForInvocation(sortMode: .fixed)
        XCTAssertFalse(catalog.isInvocationReady)
        XCTAssertEqual(numbers(catalog), [7])
        try await waitUntil { catalog.isInvocationReady }
        XCTAssertEqual(numbers(catalog), [9])
    }

    func testRecentUseLaunchRetriesOnceAndConsumesInferredFocusWithoutRecordingIt() async throws {
        let previous = CatalogAXAccess(number: 7, elementPID: 201)
        previous.update { $0.focused = true }
        let launched = CatalogAXAccess(number: nil, elementPID: 202)
        launched.update {
            $0.beforeRead = { [weak launched] in
                launched?.update { if $0.reads == 2 { $0.number = 8 } }
            }
        }
        let captures = CatalogAXAccess(number: nil, elementPID: 203)
        var foreground: pid_t = 42
        let catalog = launchCatalog(previous: previous, launched: launched, foreground: { foreground }) {
            captures.update { $0.reads += 1 }
            return [visibleRecord(8, owner: 43)]
        }
        defer { catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }
        foreground = 43
        catalog.prepareForInvocation(sortMode: .recentUse)
        try await waitUntil { catalog.isInvocationReady }
        let opening = try XCTUnwrap(catalog.opening(sortMode: .recentUse))
        let rows = fixtureEntries(opening)
        XCTAssertEqual(rows.compactMap(\.windowNumber), [8, 7])
        XCTAssertEqual(opening.focusedWindowID, rows.first?.id)
        XCTAssertEqual(launched.read { $0.reads }, 2)
        XCTAssertEqual(captures.read { $0.reads }, 3)

        XCTAssertEqual(fixtureEntries(catalog).compactMap(\.windowNumber), [7, 8])
        XCTAssertNotEqual(catalog.focusedWindowID, rows.first?.id)
    }

    func testLaunchRetryDoesNotAdoptFocusAfterForegroundHandoff() async throws {
        let previous = CatalogAXAccess(number: 7, elementPID: 201)
        previous.update { $0.focused = true }
        let launched = CatalogAXAccess(number: nil, elementPID: 202)
        let next = CatalogAXAccess(number: 9, elementPID: 203)
        let captures = CatalogAXAccess(number: nil, elementPID: 204)
        let releaseCapture = DispatchSemaphore(value: 0)
        var foreground: pid_t = 42
        let catalog = WindowSwitcherAppCatalog(notificationCenter: NotificationCenter(), accessFactory: { pid in
            if pid == 42 { return previous }
            return pid == 43 ? launched : next
        }, allSpacesCatalog: .init(windowRecordProvider: {
            captures.update { $0.reads += 1 }
            if captures.read({ $0.reads }) == 3 {
                _ = releaseCapture.wait(timeout: .now() + 1)
                return [visibleRecord(8, owner: 43), visibleRecord(9, owner: 44)]
            }
            return [visibleRecord(8, owner: 43)]
        }), discovery: .init(applications: {
            var apps = [WindowSwitcherAppCatalog.Application(processIdentifier: 42, localizedName: "Previous",
                                                             isActive: foreground == 42),
                        .init(processIdentifier: 44, localizedName: "Next", isActive: foreground == 44)]
            if foreground != 42 {
                apps.append(.init(processIdentifier: 43, localizedName: "Launched", isActive: foreground == 43))
            }
            return apps
        }, foregroundPID: { foreground }, isLaunching: { $0 == 43 },
           isAccessibilityTrusted: { true }, isDragging: { false }))
        defer { releaseCapture.signal(); catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }
        foreground = 43
        catalog.prepareForInvocation(sortMode: .recentUse)
        try await waitUntil { captures.read { $0.reads } >= 3 }
        foreground = 44
        launched.update { $0.number = 8; $0.focused = true }
        releaseCapture.signal()
        try await waitUntil { catalog.isInvocationReady }
        XCTAssertEqual(fixtureEntries(catalog).first?.windowNumber, 7)
        XCTAssertEqual(captures.read { $0.reads }, 3)
    }

    func testLaunchCheckEndsAfterForegroundDepartsAndReturns() async throws {
        let previous = CatalogAXAccess(number: 7, elementPID: 201)
        previous.update { $0.focused = true }
        let launched = CatalogAXAccess(number: nil, elementPID: 202)
        launched.update {
            $0.beforeRead = { [weak launched] in
                launched?.update { if $0.reads == 2 { $0.number = 8 } }
            }
        }
        let captures = CatalogAXAccess(number: nil, elementPID: 203)
        let releaseCapture = DispatchSemaphore(value: 0)
        let center = NotificationCenter()
        var foreground: pid_t = 42
        let catalog = launchCatalog(previous: previous, launched: launched, notificationCenter: center,
                                    foreground: { foreground }) {
            captures.update { $0.reads += 1 }
            if captures.read({ $0.reads }) == 2 { _ = releaseCapture.wait(timeout: .now() + 1) }
            return [visibleRecord(8, owner: 43)]
        }
        defer { releaseCapture.signal(); catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }
        foreground = 43
        catalog.prepareForInvocation(sortMode: .recentUse)
        try await waitUntil { captures.read { $0.reads } == 2 && launched.read { $0.reads } == 1 }
        foreground = ProcessInfo.processInfo.processIdentifier
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil,
                    userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
        foreground = 43
        releaseCapture.signal()
        try await waitUntil { catalog.isInvocationReady }
        XCTAssertEqual(fixtureEntries(catalog).compactMap(\.windowNumber), [7])
        XCTAssertEqual(launched.read { $0.reads }, 1)
        XCTAssertEqual(captures.read { $0.reads }, 2)
    }

    func testDeliveredForegroundDepartureInvalidatesQueuedLaunchPublication() async throws {
        let previous = CatalogAXAccess(number: 7, elementPID: 201)
        previous.update { $0.focused = true }
        let launched = CatalogAXAccess(number: 8, elementPID: 202)
        let focusRead = CatalogAXAccess(number: nil, elementPID: 203)
        launched.update {
            $0.focused = true
            $0.afterReadingFocus = { focusRead.update { $0.reads += 1 } }
        }
        let center = NotificationCenter()
        var foreground: pid_t = 42
        let catalog = launchCatalog(previous: previous, launched: launched, notificationCenter: center,
                                    foreground: { foreground })
        defer { catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }
        foreground = 43
        catalog.prepareForInvocation(sortMode: .recentUse)
        try await waitUntil { focusRead.read { $0.reads } == 1 }
        await Task.yield()
        XCTAssertFalse(catalog.isInvocationReady)

        // Let the coalesced publication become runnable while this actor still owns the turn.
        usleep(30_000)
        foreground = ProcessInfo.processInfo.processIdentifier
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil,
                    userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
        foreground = 43
        try await waitUntil { catalog.isInvocationReady }

        XCTAssertEqual(fixtureEntries(catalog).compactMap(\.windowNumber), [7, 8])
    }

    func testDeliveredSpaceChangeInvalidatesFocusBeforeOpening() async throws {
        let previous = CatalogAXAccess(number: 7, elementPID: 201)
        previous.update { $0.focused = true }
        let launched = CatalogAXAccess(number: 8, elementPID: 202)
        launched.update { $0.focused = true }
        let center = NotificationCenter()
        var foreground: pid_t = 42
        let catalog = launchCatalog(previous: previous, launched: launched, notificationCenter: center,
                                    foreground: { foreground }) {
            [visibleRecord(8, owner: 43)]
        }
        defer { catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }
        foreground = 43
        catalog.prepareForInvocation(sortMode: .recentUse)
        try await waitUntil { catalog.isInvocationReady }

        launched.update { $0.focused = false }
        center.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        let opening = try XCTUnwrap(catalog.opening(sortMode: .recentUse, deadlineReached: true))
        XCTAssertEqual(fixtureEntries(opening).compactMap(\.windowNumber), [7, 8])
        XCTAssertNil(opening.focusedWindowID)
    }

    func testCancelledLaunchRetryCannotRecordLateFocus() async throws {
        let previous = CatalogAXAccess(number: 7, elementPID: 201)
        previous.update { $0.focused = true }
        let launched = CatalogAXAccess(number: 8, elementPID: 202)
        let capturedFocus = CatalogAXAccess(number: nil, elementPID: 203)
        let captures = CatalogAXAccess(number: nil, elementPID: 204)
        let releaseFocus = DispatchSemaphore(value: 0)
        launched.update {
            $0.beforeRead = { [weak launched] in
                launched?.update {
                    if $0.reads == 2 {
                        $0.focused = true
                        $0.secondWindowNumber = 9
                    }
                }
            }
            $0.afterReadingFocus = { [weak launched] in
                guard launched?.read({ $0.reads }) == 2 else { return }
                capturedFocus.update { $0.reads += 1 }
                _ = releaseFocus.wait(timeout: .now() + 0.2)
            }
        }
        let center = NotificationCenter()
        var foreground: pid_t = 42
        let catalog = launchCatalog(previous: previous, launched: launched, notificationCenter: center,
                                    foreground: { foreground }) {
            captures.update { $0.reads += 1 }
            return captures.read { $0.reads } >= 3 ? [visibleRecord(8, owner: 43)] : []
        }
        defer { releaseFocus.signal(); catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }
        foreground = 43
        catalog.prepareForInvocation(sortMode: .recentUse)
        try await waitUntil { capturedFocus.read { $0.reads } == 1 }
        foreground = ProcessInfo.processInfo.processIdentifier
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil,
                    userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
        foreground = 43
        launched.update { $0.focused = false }
        try await waitUntil { catalog.isInvocationReady }
        XCTAssertEqual(fixtureEntries(catalog).compactMap(\.windowNumber), [7, 8])
        releaseFocus.signal()
        // The added row confirms that the blocked read completed and published.
        try await waitUntil { self.fixtureEntries(catalog).contains { $0.windowNumber == 9 } }

        let rows = fixtureEntries(catalog)
        XCTAssertEqual(rows.compactMap(\.windowNumber), [7, 8, 9])
        XCTAssertFalse(rows.contains { $0.id == catalog.focusedWindowID })
        XCTAssertEqual(launched.read { $0.reads }, 2)
    }

    func testLaunchCheckIgnoresActivationReceivedBeforeInvocation() async throws {
        let previous = CatalogAXAccess(number: 7, elementPID: 201)
        previous.update { $0.focused = true }
        let launched = CatalogAXAccess(number: 8, elementPID: 202)
        let center = NotificationCenter()
        var foreground: pid_t = 42
        let catalog = launchCatalog(previous: previous, launched: launched, notificationCenter: center,
                                    foreground: { foreground }) {
            [visibleRecord(8, owner: 43)]
        }
        defer { catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }
        foreground = ProcessInfo.processInfo.processIdentifier
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil,
                    userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
        foreground = 43
        catalog.prepareForInvocation(sortMode: .recentUse)
        try await waitUntil { catalog.isInvocationReady }

        let opening = try XCTUnwrap(catalog.opening(sortMode: .recentUse))
        let rows = fixtureEntries(opening)
        XCTAssertEqual(rows.compactMap(\.windowNumber), [8, 7])
        XCTAssertEqual(opening.focusedWindowID, rows.first?.id)
    }

    func testLaunchRetriesFocusThatIsNotYetInTheAXWindowList() async throws {
        let previous = CatalogAXAccess(number: 7, elementPID: 201)
        previous.update { $0.focused = true }
        let launched = CatalogAXAccess(number: 8, elementPID: 202)
        launched.update {
            $0.focusesSecondWindow = true
            $0.beforeRead = { [weak launched] in
                launched?.update { if $0.reads == 2 { $0.secondWindowNumber = 9 } }
            }
        }
        var foreground: pid_t = 42
        let catalog = launchCatalog(previous: previous, launched: launched, foreground: { foreground }) {
            [visibleRecord(8, owner: 43), visibleRecord(9, owner: 43)]
        }
        defer { catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }
        foreground = 43
        catalog.prepareForInvocation(sortMode: .recentUse)
        try await waitUntil { catalog.isInvocationReady }

        let opening = try XCTUnwrap(catalog.opening(sortMode: .recentUse))
        let rows = fixtureEntries(opening)
        XCTAssertEqual(rows.first?.windowNumber, 9)
        XCTAssertEqual(opening.focusedWindowID, rows.first?.id)
        XCTAssertEqual(launched.read { $0.reads }, 2)
    }

    func testLaunchInferenceRejectsAnotherVisibleOrUnclassifiedWindow() async throws {
        for (helperOwnsSecondWindow, helperAXAvailable) in [(false, true), (true, true), (true, false)] {
            let previous = CatalogAXAccess(number: 7, elementPID: 201)
            previous.update { $0.focused = true }
            let launched = CatalogAXAccess(number: 8, elementPID: 202)
            let helper = helperOwnsSecondWindow ? CatalogAXAccess(number: 9, elementPID: 203) : nil
            helper?.update { $0.windowListUnavailable = !helperAXAvailable }
            if helper == nil { launched.update { $0.secondWindowNumber = 9 } }
            var foreground: pid_t = 42
            let catalog = launchCatalog(previous: previous, launched: launched, helper: helper, foreground: { foreground }) {
                let direct = visibleRecord(8, owner: 43)
                return helperOwnsSecondWindow
                    ? [direct, visibleRecord(9, owner: 44, titleIsAvailable: helperAXAvailable)] : [direct]
            }
            defer { catalog.stop() }
            catalog.start()
            try await waitUntil { catalog.isInvocationReady }
            foreground = 43
            catalog.prepareForInvocation(sortMode: .recentUse)
            try await waitUntil { catalog.isInvocationReady }

            let opening = try XCTUnwrap(catalog.opening(sortMode: .recentUse))
            let rows = fixtureEntries(opening)
            XCTAssertEqual(rows.first?.windowNumber, 7)
            XCTAssertEqual(Set(rows.compactMap(\.windowNumber)), helperAXAvailable ? [7, 8, 9] : [7, 8])
            XCTAssertFalse(rows.contains { $0.id == opening.focusedWindowID })
        }
    }

    func testLaunchRetryDoesNotPromoteDocumentWhenAXReportsAnExcludedPanel() async throws {
        let previous = CatalogAXAccess(number: 7, elementPID: 201)
        previous.update { $0.focused = true }
        let launched = CatalogAXAccess(number: nil, elementPID: 202)
        launched.update {
            $0.beforeRead = { [weak launched] in
                launched?.update {
                    if $0.reads == 2 {
                        $0.number = 8
                        $0.focusesExcludedPanel = true
                    }
                }
            }
        }
        var foreground: pid_t = 42
        let catalog = launchCatalog(previous: previous, launched: launched, foreground: { foreground }) {
            [visibleRecord(8, owner: 43)]
        }
        defer { catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }
        foreground = 43
        catalog.prepareForInvocation(sortMode: .recentUse)
        try await waitUntil { catalog.isInvocationReady }
        let opening = try XCTUnwrap(catalog.opening(sortMode: .recentUse))
        let rows = fixtureEntries(opening)
        XCTAssertEqual(rows.compactMap(\.windowNumber), [7, 8])
        XCTAssertFalse(rows.contains { $0.id == opening.focusedWindowID })
        XCTAssertEqual(launched.read { $0.reads }, 2)
    }

    func testLaunchRetryUsesOneAXReadAfterWindowServerDiscoversWindow() async throws {
        for panelFocused in [false, true] {
            let previous = CatalogAXAccess(number: 7, elementPID: 201)
            previous.update { $0.focused = true }
            let launched = CatalogAXAccess(number: nil, elementPID: 202)
            launched.update {
                $0.beforeRead = { [weak launched] in
                    launched?.update {
                        if $0.reads == 2 {
                            $0.number = 8
                            $0.focusesExcludedPanel = panelFocused
                        }
                    }
                }
            }
            let captures = CatalogAXAccess(number: nil, elementPID: 203)
            let releaseCapture = DispatchSemaphore(value: 0)
            var foreground: pid_t = 42
            let catalog = launchCatalog(previous: previous, launched: launched, foreground: { foreground }) {
                captures.update { $0.reads += 1 }
                guard captures.read({ $0.reads }) == 3 else { return [] }
                _ = releaseCapture.wait(timeout: .now() + 1)
                return [visibleRecord(8, owner: 43)]
            }
            defer { releaseCapture.signal(); catalog.stop() }
            catalog.start()
            try await waitUntil { catalog.isInvocationReady }
            foreground = 43
            catalog.prepareForInvocation(sortMode: .recentUse)
            try await waitUntil { captures.read { $0.reads } == 3 }
            XCTAssertEqual(launched.read { $0.reads }, 1)
            releaseCapture.signal()
            try await waitUntil { catalog.isInvocationReady }

            let opening = try XCTUnwrap(catalog.opening(sortMode: .recentUse))
            let rows = fixtureEntries(opening)
            XCTAssertEqual(rows.compactMap(\.windowNumber), panelFocused ? [7, 8] : [8, 7])
            XCTAssertEqual(rows.first { $0.id == opening.focusedWindowID }?.windowNumber, panelFocused ? nil : 8)
            XCTAssertEqual(launched.read { $0.reads }, 2)
            XCTAssertEqual(captures.read { $0.reads }, 3)
        }
    }

    func testLaunchWindowChangeInvalidatesInferenceBeforeDebounce() async throws {
        let previous = CatalogAXAccess(number: 7, elementPID: 201)
        previous.update { $0.focused = true }
        let launched = CatalogAXAccess(number: 8, elementPID: 202)
        let sampledAX = CatalogAXAccess(number: nil, elementPID: 203)
        let releaseAX = DispatchSemaphore(value: 0)
        launched.update {
            $0.afterReadingFocus = { [weak launched] in
                guard launched?.read({ $0.reads }) == 1 else { return }
                sampledAX.update { $0.reads += 1 }
                _ = releaseAX.wait(timeout: .now() + 0.2)
            }
        }
        let captures = CatalogAXAccess(number: nil, elementPID: 204)
        var foreground: pid_t = 42
        let catalog = launchCatalog(previous: previous, launched: launched, foreground: { foreground }) {
            captures.update { $0.reads += 1 }
            let first = visibleRecord(8, owner: 43)
            return captures.read { $0.reads } > 2 ? [first, visibleRecord(9, owner: 43)] : [first]
        }
        defer { releaseAX.signal(); catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }
        foreground = 43
        catalog.prepareForInvocation(sortMode: .recentUse)
        try await waitUntil { sampledAX.read { $0.reads } == 1 && captures.read { $0.reads } == 2 }
        launched.update { $0.secondWindowNumber = 9 }
        catalog.invalidate(processIdentifiers: [43], windowRecords: true)
        releaseAX.signal()
        try await waitUntil { catalog.isInvocationReady }

        let opening = try XCTUnwrap(catalog.opening(sortMode: .recentUse))
        let rows = fixtureEntries(opening)
        XCTAssertEqual(rows.first?.windowNumber, 7)
        XCTAssertTrue(rows.contains { $0.windowNumber == 9 })
        XCTAssertFalse(rows.contains { $0.id == opening.focusedWindowID })
    }

    func testLaunchCannotRuleOutAXWindowUsingEarlierOffscreenCapture() async throws {
        let previous = CatalogAXAccess(number: 7, elementPID: 201)
        previous.update { $0.focused = true }
        let launched = CatalogAXAccess(number: 8, elementPID: 202)
        let releaseAX = DispatchSemaphore(value: 0)
        launched.update {
            $0.beforeRead = { [weak launched] in
                guard launched?.read({ $0.reads }) == 1 else { return }
                _ = releaseAX.wait(timeout: .now() + 0.2)
                launched?.update { $0.secondWindowNumber = 9 }
            }
        }
        let captures = CatalogAXAccess(number: nil, elementPID: 203)
        var foreground: pid_t = 42
        let catalog = launchCatalog(previous: previous, launched: launched, foreground: { foreground }) {
            captures.update { $0.reads += 1 }
            let second = WindowSwitcherWindowRecord(windowNumber: 9, processIdentifier: 43, title: "Second",
                isOnScreen: captures.read { $0.reads } > 2, bounds: CGRect(x: 50, y: 50, width: 800, height: 600),
                hasSpace: true, isOnActiveSpace: true)
            return [visibleRecord(8, owner: 43), second]
        }
        defer { releaseAX.signal(); catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }
        foreground = 43
        catalog.prepareForInvocation(sortMode: .recentUse)
        try await waitUntil { captures.read { $0.reads } == 2 }
        releaseAX.signal()
        try await waitUntil { catalog.isInvocationReady }

        let opening = try XCTUnwrap(catalog.opening(sortMode: .recentUse))
        let rows = fixtureEntries(opening)
        XCTAssertEqual(rows.first?.windowNumber, 7)
        XCTAssertTrue(rows.contains { $0.windowNumber == 9 })
        XCTAssertFalse(rows.contains { $0.id == opening.focusedWindowID })
    }

    func testLaunchRanksExactHelperOwnedWindowWithStaleAppActivity() async throws {
        let previous = CatalogAXAccess(number: 7, elementPID: 201)
        previous.update { $0.focused = true }
        let launched = CatalogAXAccess(number: 8, elementPID: 202)
        launched.update { $0.focused = true }
        let helper = CatalogAXAccess(number: nil, elementPID: 203)
        var foreground: pid_t = 42
        let catalog = launchCatalog(previous: previous, launched: launched, helper: helper,
                                    launchAppIsActive: false, foreground: { foreground }) {
            [visibleRecord(8, owner: 44)]
        }
        defer { catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }
        foreground = 43
        catalog.prepareForInvocation(sortMode: .recentUse)
        try await waitUntil { catalog.isInvocationReady }

        let opening = try XCTUnwrap(catalog.opening(sortMode: .recentUse))
        let rows = fixtureEntries(opening)
        let target = try XCTUnwrap(rows.first { $0.windowNumber == 8 })
        XCTAssertEqual(target.axWorkerPID, 43)
        XCTAssertEqual(target.owningProcessIdentifier, 44)
        XCTAssertEqual(rows.first?.id, target.id)
        XCTAssertEqual(opening.focusedWindowID, target.id)
        var session = WindowSwitcherSession(entries: rows, selectedID: opening.focusedWindowID,
                                            isPersistent: false, originalWindowID: opening.focusedWindowID)
        session.normalizeSelection()
        session.advance(-1)
        XCTAssertEqual(session.selected?.windowNumber, 7)
    }

    func testLaunchRetryPublishesTerminatedAppRemovalBeforeReadiness() async throws {
        let previous = CatalogAXAccess(number: 7, elementPID: 201)
        previous.update { $0.focused = true }
        let launched = CatalogAXAccess(number: 8, elementPID: 202)
        var foreground: pid_t = 42
        let catalog = launchCatalog(previous: previous, launched: launched, foreground: { foreground })
        defer { catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }
        var firstRows: [CGWindowID]?
        catalog.onChange = {
            if catalog.isInvocationReady, firstRows == nil {
                firstRows = self.fixtureEntries(catalog).compactMap(\.windowNumber)
            }
        }
        foreground = 43
        catalog.prepareForInvocation(sortMode: .recentUse)
        try await waitUntil {
            !catalog.isInvocationReady && self.fixtureEntries(catalog).contains { $0.windowNumber == 8 }
        }
        foreground = 42
        try await waitUntil { firstRows != nil }
        XCTAssertEqual(firstRows, [7])
    }

    func testLaunchDeadlineUsesReadyRowsWithPendingRemoval() async throws {
        let previous = CatalogAXAccess(number: 7, elementPID: 201)
        previous.update { $0.focused = true }
        let launched = CatalogAXAccess(number: 8, elementPID: 202)
        let captures = CatalogAXAccess(number: nil, elementPID: 203)
        let releaseCapture = DispatchSemaphore(value: 0)
        var foreground: pid_t = 42
        let catalog = launchCatalog(previous: previous, launched: launched, foreground: { foreground }) {
            captures.update { $0.reads += 1 }
            if captures.read({ $0.reads }) == 3 { _ = releaseCapture.wait(timeout: .now() + 1) }
            return []
        }
        defer { releaseCapture.signal(); catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }
        foreground = 43
        catalog.prepareForInvocation(sortMode: .recentUse)
        try await waitUntil { captures.read { $0.reads } == 3 }
        XCTAssertEqual(fixtureEntries(catalog).compactMap(\.windowNumber), [7, 8])
        foreground = 42
        catalog.refresh()

        let opening = try XCTUnwrap(catalog.opening(sortMode: .recentUse, deadlineReached: true))
        XCTAssertEqual(fixtureEntries(opening).compactMap(\.windowNumber), [7])
    }

    func testLaunchDeadlineAppliesConfirmedWindowClosureBeforeQuickSwitch() async throws {
        try await checkLaunchDeadlineAfterWindowOmission(isOnScreen: true)
    }

    func testLaunchDeadlineKeepsWindowPendingAfterFailedAccessibilityRead() async throws {
        try await checkLaunchDeadlineAfterWindowOmission(isOnScreen: true, followUpFails: true)
    }

    func testLaunchDeadlineExcludesPendingActiveSpaceWindowWithUnknownVisibility() async throws {
        try await checkLaunchDeadlineAfterWindowOmission(isOnScreen: nil)
    }

    private func checkLaunchDeadlineAfterWindowOmission(isOnScreen: Bool?, followUpFails: Bool = false) async throws {
        let previous = CatalogAXAccess(number: 6, elementPID: 201)
        previous.update { $0.focused = true; $0.secondWindowNumber = 7 }
        let launched = CatalogAXAccess(number: 8, elementPID: 202)
        let captures = CatalogAXAccess(number: nil, elementPID: 203)
        let releaseCapture = DispatchSemaphore(value: 0)
        let releaseFollowUp = DispatchSemaphore(value: 0)
        let priorWindow = visibleRecord(6, owner: 42)
        let omittedWindow = WindowSwitcherWindowRecord(windowNumber: 7, processIdentifier: 42, title: priorWindow.title,
            isOnScreen: isOnScreen, bounds: priorWindow.bounds, hasSpace: true, isOnActiveSpace: true)
        var foreground: pid_t = 42
        let catalog = launchCatalog(previous: previous, launched: launched,
                                    launchAppIsActive: false, foreground: { foreground }) {
            captures.update { $0.reads += 1 }
            if captures.read({ $0.reads }) == 3 { _ = releaseCapture.wait(timeout: .now() + 1) }
            return [priorWindow, omittedWindow]
        }
        defer { releaseCapture.signal(); releaseFollowUp.signal(); catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }
        foreground = 43
        catalog.prepareForInvocation(sortMode: .recentUse)
        try await waitUntil { captures.read { $0.reads } == 3 }
        let readsBeforeClosure = previous.read { $0.reads }
        previous.update {
            $0.secondWindowNumber = nil
            $0.beforeRead = { [weak previous] in
                if previous?.read({ $0.reads }) == readsBeforeClosure + 2 {
                    _ = releaseFollowUp.wait(timeout: .now() + 0.2)
                }
            }
        }
        catalog.refresh()
        try await waitUntil { previous.read { $0.reads } == readsBeforeClosure + 1 }
        catalog.refresh()
        // This read starts only after the catalog has collected the closure.
        try await waitUntil { previous.read { $0.reads } == readsBeforeClosure + 2 }

        if followUpFails {
            try await waitUntil {
                self.fixtureEntries(catalog).contains { $0.windowNumber == 7 && $0.isAwaitingWindowConfirmation }
            }
            previous.update { $0.windowListUnavailable = true }
            releaseFollowUp.signal()
            try await waitUntil { catalog.unavailableApplicationCount == 1 }
        }

        let opening = try XCTUnwrap(catalog.opening(sortMode: .recentUse, deadlineReached: true))
        let rows = fixtureEntries(opening)
        XCTAssertEqual(rows.compactMap(\.windowNumber), [6, 8])
        XCTAssertEqual(fixtureEntries(catalog).first { $0.windowNumber == 7 }?.isAwaitingWindowConfirmation, true)
        var session = WindowSwitcherSession(entries: rows, selectedID: opening.focusedWindowID,
                                            isPersistent: false, originalWindowID: opening.focusedWindowID)
        session.normalizeSelection()
        session.advance(1)
        XCTAssertEqual(session.selected?.windowNumber, 8)
    }

    func testFreshOrdinaryOpeningsExcludePendingWindows() async throws {
        for sortMode in [WindowSwitcherSortMode.fixed, .recentUse] {
            let closing = CatalogAXAccess(number: 7, elementPID: 201)
            let remaining = CatalogAXAccess(number: 8, elementPID: 202)
            let captures = CatalogAXAccess(number: nil, elementPID: 203)
            let releaseAX = DispatchSemaphore(value: 0)
            let catalog = WindowSwitcherAppCatalog(notificationCenter: NotificationCenter(),
                accessFactory: { $0 == 42 ? closing : remaining },
                allSpacesCatalog: .init(windowRecordProvider: {
                    captures.update { $0.reads += 1 }
                    return [visibleRecord(7, owner: 42), visibleRecord(8, owner: 43)]
                }), discovery: .init(applications: {
                    [.init(processIdentifier: 42, localizedName: "Closing"),
                     .init(processIdentifier: 43, localizedName: "Remaining")]
                }, foregroundPID: { 43 }, isLaunching: { _ in false },
                    isAccessibilityTrusted: { true }, isDragging: { false }))
            defer { releaseAX.signal(); catalog.stop() }
            catalog.start()
            try await waitUntil { catalog.isInvocationReady }
            XCTAssertEqual(fixtureEntries(catalog).compactMap(\.windowNumber), [7, 8])

            let nextRead = closing.read { $0.reads } + 1
            closing.update {
                $0.number = nil
                $0.beforeRead = { [weak closing] in
                    if closing?.read({ $0.reads }) == nextRead {
                        _ = releaseAX.wait(timeout: .now() + 0.2)
                    }
                }
            }
            catalog.invalidate(processIdentifiers: [42], windowRecords: false)
            try await waitUntil { closing.read { $0.reads } == nextRead }
            catalog.prepareForInvocation(sortMode: sortMode)
            try await waitUntil { captures.read { $0.reads } == 2 }
            releaseAX.signal()
            try await waitUntil { catalog.isInvocationReady }

            let opening = try XCTUnwrap(catalog.opening(sortMode: sortMode))
            XCTAssertEqual(fixtureEntries(opening).compactMap(\.windowNumber), [8])
            XCTAssertEqual(fixtureEntries(catalog).filter(\.isAwaitingWindowConfirmation).compactMap(\.windowNumber), [7])
        }
    }

    func testLaunchDeadlineKeepsOrdinaryReadinessAfterUnrelatedAppAppears() async throws {
        let previous = CatalogAXAccess(number: 7, elementPID: 201)
        previous.update { $0.focused = true }
        let launched = CatalogAXAccess(number: nil, elementPID: 202)
        let unrelated = CatalogAXAccess(number: 10, elementPID: 203)
        let releaseUnrelated = DispatchSemaphore(value: 0)
        unrelated.update { $0.beforeRead = { _ = releaseUnrelated.wait(timeout: .now() + 0.2) } }
        let captures = CatalogAXAccess(number: nil, elementPID: 204)
        let releaseCapture = DispatchSemaphore(value: 0)
        var foreground: pid_t = 42
        var unrelatedRunning = false
        let catalog = WindowSwitcherAppCatalog(notificationCenter: NotificationCenter(), accessFactory: { pid in
            if pid == 42 { return previous }
            return pid == 43 ? launched : unrelated
        }, allSpacesCatalog: .init(windowRecordProvider: {
            captures.update { $0.reads += 1 }
            if captures.read({ $0.reads }) == 3 { _ = releaseCapture.wait(timeout: .now() + 1) }
            return []
        }), discovery: .init(applications: {
            var apps = [WindowSwitcherAppCatalog.Application(processIdentifier: 42, localizedName: "Previous",
                                                             isActive: foreground == 42)]
            if foreground == 43 { apps.append(.init(processIdentifier: 43, localizedName: "Launched", isActive: true)) }
            if unrelatedRunning { apps.append(.init(processIdentifier: 44, localizedName: "Unrelated")) }
            return apps
        }, foregroundPID: { foreground }, isLaunching: { $0 == 43 },
           isAccessibilityTrusted: { true }, isDragging: { false }))
        defer { releaseCapture.signal(); releaseUnrelated.signal(); catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }
        foreground = 43
        catalog.prepareForInvocation(sortMode: .recentUse)
        try await waitUntil { captures.read { $0.reads } == 3 }
        unrelatedRunning = true
        catalog.refresh()
        try await waitUntil { !catalog.isInitialDiscoveryComplete && unrelated.read { $0.reads } == 1 }

        let opening = try XCTUnwrap(catalog.opening(sortMode: .recentUse, deadlineReached: true))
        XCTAssertEqual(fixtureEntries(opening).compactMap(\.windowNumber), [7])
    }

    func testLaunchCheckRejectsReplacementWithTheSamePID() async throws {
        let previous = CatalogAXAccess(number: 7, elementPID: 201)
        previous.update { $0.focused = true }
        let original = CatalogAXAccess(number: 8, elementPID: 202)
        let replacement = CatalogAXAccess(number: 9, elementPID: 203)
        replacement.update { $0.focused = true }
        let workers = CatalogAXAccess(number: nil, elementPID: 204)
        let releaseOriginal = DispatchSemaphore(value: 0)
        original.update { $0.beforeRead = { _ = releaseOriginal.wait(timeout: .now() + 0.2) } }
        var foreground: pid_t = 42
        var lifetime = UUID()
        let catalog = WindowSwitcherAppCatalog(notificationCenter: NotificationCenter(), accessFactory: { pid in
            if pid == 42 { return previous }
            workers.update { $0.reads += 1 }
            return workers.read { $0.reads } == 1 ? original : replacement
        }, allSpacesCatalog: .init(windowRecordProvider: { [visibleRecord(9, owner: 43)] }), discovery: .init(applications: {
            let prior = WindowSwitcherAppCatalog.Application(processIdentifier: 42, localizedName: "Previous",
                                                             isActive: foreground == 42)
            return foreground == 43
                ? [prior, .init(processIdentifier: 43, localizedName: "Launched", lifetime: lifetime)] : [prior]
        }, foregroundPID: { foreground }, isLaunching: { $0 == 43 },
           isAccessibilityTrusted: { true }, isDragging: { false }))
        defer { releaseOriginal.signal(); catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }
        foreground = 43
        catalog.prepareForInvocation(sortMode: .recentUse)
        try await waitUntil { original.read { $0.reads } == 1 }
        lifetime = UUID()
        catalog.refresh()
        releaseOriginal.signal()
        try await waitUntil { catalog.isInvocationReady }

        let opening = try XCTUnwrap(catalog.opening(sortMode: .recentUse))
        let rows = fixtureEntries(opening)
        let replacementRow = try XCTUnwrap(rows.first { $0.windowNumber == 9 })
        XCTAssertEqual(rows.compactMap(\.windowNumber), [7, 9])
        XCTAssertNotEqual(opening.focusedWindowID, replacementRow.id)
        XCTAssertEqual(workers.read { $0.reads }, 2)
    }

    func testLaunchRetryPrefersVerifiedActiveHelperOverHostFocus() async throws {
        let previous = CatalogAXAccess(number: 7, elementPID: 201)
        previous.update { $0.focused = true }
        let launched = CatalogAXAccess(number: 8, elementPID: 202)
        launched.update { $0.focused = true }
        let helper = CatalogAXAccess(number: 9, elementPID: 203)
        helper.update {
            $0.beforeRead = { [weak helper] in
                helper?.update { $0.focused = $0.reads >= 2 }
            }
        }
        var foreground: pid_t = 42
        let catalog = launchCatalog(previous: previous, launched: launched, helper: helper,
                                    launchAppIsActive: false, helperIsActive: true, foreground: { foreground }) {
            [visibleRecord(9, owner: 44), visibleRecord(8, owner: 43)]
        }
        defer { catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }
        foreground = 43
        catalog.prepareForInvocation(sortMode: .recentUse)
        try await waitUntil { catalog.isInvocationReady }

        let opening = try XCTUnwrap(catalog.opening(sortMode: .recentUse))
        let rows = fixtureEntries(opening)
        XCTAssertEqual(rows.compactMap(\.windowNumber), [9, 7, 8])
        XCTAssertEqual(rows.first?.axWorkerPID, 44)
        XCTAssertEqual(opening.focusedWindowID, rows.first?.id)
        XCTAssertEqual(helper.read { $0.reads }, 2)
        var session = WindowSwitcherSession(entries: rows, selectedID: opening.focusedWindowID,
                                            isPersistent: false, originalWindowID: opening.focusedWindowID)
        session.normalizeSelection()
        session.advance(1)
        XCTAssertEqual(session.selected?.windowNumber, 7)
    }

    func testLaunchRanksSharedWindowWhenActiveHelperReportsExactFocus() async throws {
        let previous = CatalogAXAccess(number: 7, elementPID: 201)
        previous.update { $0.focused = true }
        let launched = CatalogAXAccess(number: 8, elementPID: 202)
        let helper = CatalogAXAccess(number: 8, elementPID: 203)
        helper.update { $0.focused = true }
        var foreground: pid_t = 42
        let catalog = launchCatalog(previous: previous, launched: launched, helper: helper,
                                    helperIsActive: true, foreground: { foreground }) {
            [visibleRecord(8, owner: 44)]
        }
        defer { catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }
        foreground = 43
        catalog.prepareForInvocation(sortMode: .recentUse)
        try await waitUntil { catalog.isInvocationReady }

        let opening = try XCTUnwrap(catalog.opening(sortMode: .recentUse))
        let rows = fixtureEntries(opening)
        XCTAssertEqual(rows.compactMap(\.windowNumber), [8, 7])
        XCTAssertEqual(opening.focusedWindowID, rows.first?.id)
        XCTAssertEqual(rows.first?.axWorkerPID, 43)
        XCTAssertEqual(rows.first?.owningProcessIdentifier, 44)
        XCTAssertEqual(helper.read { $0.reads }, 1)
    }

    func testLaunchRetryUsesNewerFocusAlreadyReadByOrdinaryRefresh() async throws {
        let previous = CatalogAXAccess(number: 7, elementPID: 201)
        previous.update { $0.focused = true }
        let launched = CatalogAXAccess(number: nil, elementPID: 202)
        let releaseRetry = DispatchSemaphore(value: 0)
        launched.update {
            $0.beforeRead = { [weak launched] in
                guard let launched else { return }
                let read = launched.read { $0.reads }
                if read == 2 { _ = releaseRetry.wait(timeout: .now() + 1) }
                guard read >= 2 else { return }
                launched.update {
                    $0.number = 8
                    $0.secondWindowNumber = 9
                    $0.focused = read == 2
                    $0.focusesSecondWindow = read >= 3
                }
            }
        }
        var foreground: pid_t = 42
        let catalog = launchCatalog(previous: previous, launched: launched, foreground: { foreground }) {
            [visibleRecord(8, owner: 43), visibleRecord(9, owner: 43)]
        }
        defer { releaseRetry.signal(); catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }
        foreground = 43
        catalog.prepareForInvocation(sortMode: .recentUse)
        try await waitUntil { launched.read { $0.reads } == 2 }
        catalog.refresh()
        releaseRetry.signal()
        try await waitUntil { catalog.isInvocationReady }

        let opening = try XCTUnwrap(catalog.opening(sortMode: .recentUse))
        let rows = fixtureEntries(opening)
        XCTAssertEqual(rows.compactMap(\.windowNumber), [9, 7, 8])
        XCTAssertEqual(opening.focusedWindowID, rows.first?.id)
    }

    func testLaunchRetriesWhenMissingFocusComesWithANewWindow() async throws {
        let previous = CatalogAXAccess(number: 7, elementPID: 201)
        previous.update { $0.focused = true }
        let launched = CatalogAXAccess(number: 8, elementPID: 202)
        launched.update { $0.focused = true }
        let captures = CatalogAXAccess(number: nil, elementPID: 203)
        let releaseCapture = DispatchSemaphore(value: 0)
        var foreground: pid_t = 42
        let catalog = launchCatalog(previous: previous, launched: launched, foreground: { foreground }) {
            captures.update { $0.reads += 1 }
            let prior = visibleRecord(7, owner: 42)
            let read = captures.read { $0.reads }
            if read == 1 { return [prior] }
            if read == 2 { _ = releaseCapture.wait(timeout: .now() + 0.7) }
            return [prior, visibleRecord(8, owner: 43), visibleRecord(9, owner: 43)]
        }
        defer { releaseCapture.signal(); catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }
        foreground = 43
        catalog.prepareForInvocation(sortMode: .recentUse)
        try await waitUntil {
            captures.read { $0.reads } == 2 && self.fixtureEntries(catalog).contains { $0.windowNumber == 8 }
        }
        launched.update {
            $0.focused = false
            $0.secondWindowNumber = 9
            $0.beforeRead = { [weak launched] in
                launched?.update { $0.focusesSecondWindow = $0.reads >= 3 }
            }
        }
        releaseCapture.signal()
        try await waitUntil { catalog.isInvocationReady }

        let opening = try XCTUnwrap(catalog.opening(sortMode: .recentUse))
        let rows = fixtureEntries(opening)
        XCTAssertEqual(rows.compactMap(\.windowNumber), [9, 7, 8])
        XCTAssertEqual(opening.focusedWindowID, rows.first?.id)
        XCTAssertEqual(launched.read { $0.reads }, 3)
        XCTAssertEqual(captures.read { $0.reads }, 3)
    }

    func testActiveHelperExcludedFocusPreventsHostInference() async throws {
        let previous = CatalogAXAccess(number: 7, elementPID: 201)
        previous.update { $0.focused = true }
        let launched = CatalogAXAccess(number: 8, elementPID: 202)
        let helper = CatalogAXAccess(number: nil, elementPID: 203)
        helper.update { $0.focusesExcludedPanel = true }
        var foreground: pid_t = 42
        let catalog = launchCatalog(previous: previous, launched: launched, helper: helper,
                                    helperIsActive: true, foreground: { foreground }) {
            let helperSurface = WindowSwitcherWindowRecord(windowNumber: 10, processIdentifier: 44, title: "",
                isOnScreen: false, bounds: CGRect(x: 20, y: 20, width: 800, height: 600), hasSpace: false,
                titleIsAvailable: false, isOnActiveSpace: false)
            return [visibleRecord(8, owner: 43), helperSurface]
        }
        defer { catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }
        foreground = 43
        catalog.prepareForInvocation(sortMode: .recentUse)
        try await waitUntil { catalog.isInvocationReady }

        let opening = try XCTUnwrap(catalog.opening(sortMode: .recentUse))
        let rows = fixtureEntries(opening)
        XCTAssertEqual(rows.compactMap(\.windowNumber), [7, 8])
        XCTAssertFalse(rows.contains { $0.id == opening.focusedWindowID })
        XCTAssertEqual(helper.read { $0.reads }, 1)
    }

    func testFixedOrderRescansAfterSupersedingLaunchCapture() async throws {
        let previous = CatalogAXAccess(number: 7, elementPID: 201)
        previous.update { $0.focused = true }
        let launched = CatalogAXAccess(number: nil, elementPID: 202)
        let samples = CatalogAXAccess(number: nil, elementPID: 203)
        launched.update { $0.afterReadingFocus = { samples.update { $0.reads += 1 } } }
        let captures = CatalogAXAccess(number: nil, elementPID: 204)
        let releaseCapture = DispatchSemaphore(value: 0)
        var foreground: pid_t = 42
        let catalog = launchCatalog(previous: previous, launched: launched, foreground: { foreground }) {
            captures.update { $0.reads += 1 }
            let count = captures.read { $0.reads }
            if count < 3 { return [] }
            if count == 3 { _ = releaseCapture.wait(timeout: .now() + 1) }
            return [visibleRecord(8, owner: 43)]
        }
        defer { releaseCapture.signal(); catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }
        foreground = 43
        catalog.prepareForInvocation(sortMode: .recentUse)
        try await waitUntil { captures.read { $0.reads } == 3 && samples.read { $0.reads } == 1 }

        catalog.prepareForInvocation(sortMode: .fixed)
        try await waitUntil { samples.read { $0.reads } == 2 }
        launched.update { $0.number = 8 }
        releaseCapture.signal()
        try await waitUntil { catalog.isInvocationReady }

        let rows = fixtureEntries(catalog, sortMode: .fixed)
        let window = try XCTUnwrap(rows.first { $0.windowNumber == 8 })
        XCTAssertNotNil(window.windowElement)
        XCTAssertEqual(launched.read { $0.reads }, 3)
        XCTAssertEqual(captures.read { $0.reads }, 4)
    }

    func testConfirmedLaunchFocusSurvivesHelperDiscoveryAndMissingAXFocus() async throws {
        try await checkHelperDiscoveredDuringInvocation(sortMode: .recentUse)
    }

    func testLatestVerifiedHelperFocusReplacesEarlierHostFocus() async throws {
        try await checkHelperDiscoveredDuringInvocation(sortMode: .recentUse, helperFocused: true)
    }

    func testFixedOrderWaitsForHelperDiscoveredDuringInvocation() async throws {
        try await checkHelperDiscoveredDuringInvocation(sortMode: .fixed)
    }

    private func checkHelperDiscoveredDuringInvocation(sortMode: WindowSwitcherSortMode, helperFocused: Bool = false) async throws {
        let previous = CatalogAXAccess(number: 7, elementPID: 201)
        previous.update { $0.focused = true }
        let launched = CatalogAXAccess(number: 8, elementPID: 202)
        launched.update {
            $0.focused = true
            $0.beforeRead = { [weak launched] in
                launched?.update { if $0.reads == 2 { $0.focused = false } }
            }
        }
        let helper = CatalogAXAccess(number: 9, elementPID: 203)
        let captures = CatalogAXAccess(number: nil, elementPID: 204)
        let releaseCapture = DispatchSemaphore(value: 0)
        let releaseHelper = DispatchSemaphore(value: 0)
        helper.update {
            $0.focused = helperFocused
            $0.beforeRead = {
                _ = releaseHelper.wait(timeout: .now() + 0.2)
            }
        }
        var foreground: pid_t = 42
        let catalog = WindowSwitcherAppCatalog(notificationCenter: NotificationCenter(), accessFactory: { pid in
            if pid == 42 { return previous }
            return pid == 43 ? launched : helper
        }, allSpacesCatalog: .init(windowRecordProvider: {
            captures.update { $0.reads += 1 }
            switch captures.read({ $0.reads }) {
            case 1: return []
            case 2:
                _ = releaseCapture.wait(timeout: .now() + 1)
                return [visibleRecord(8, owner: 43), visibleRecord(9, owner: 44, titleIsAvailable: false)]
            default: return nil
            }
        }), discovery: .init(applications: {
            let prior = WindowSwitcherAppCatalog.Application(processIdentifier: 42, localizedName: "A Previous",
                                                             isActive: foreground == 42)
            return foreground == 42 ? [prior] : [
                prior,
                .init(processIdentifier: 43, bundleIdentifier: "fixture.launched", bundlePath: "/Fixture.app",
                      localizedName: "B Launched", isActive: true),
                .init(processIdentifier: 44, bundleIdentifier: "fixture.launched.helper",
                      bundlePath: "/Fixture.app/Helper.app", localizedName: "Helper",
                      isRegular: false, isActive: helperFocused)
            ]
        }, foregroundPID: { foreground }, isLaunching: { $0 == 43 },
           isAccessibilityTrusted: { true }, isDragging: { false }))
        defer { releaseCapture.signal(); releaseHelper.signal(); catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }
        var opening: WindowSwitcherOpening?
        catalog.onChange = {
            if opening == nil {
                opening = catalog.opening(sortMode: sortMode)
            }
        }
        foreground = 43
        catalog.prepareForInvocation(sortMode: sortMode)
        try await waitUntil { self.fixtureEntries(catalog).contains { $0.windowNumber == 8 } }
        releaseCapture.signal()
        try await waitUntil { helper.read { $0.reads } > 0 }
        XCTAssertFalse(catalog.isInvocationReady)
        releaseHelper.signal()
        try await waitUntil { opening != nil }
        let ready = try XCTUnwrap(opening)
        let rows = fixtureEntries(ready)
        let firstRows = rows.compactMap(\.windowNumber)
        XCTAssertEqual(captures.read { $0.reads }, 2)
        if sortMode == .fixed {
            XCTAssertEqual(firstRows.first, 7)
            XCTAssertEqual(Set(firstRows), [7, 8, 9])
        } else {
            XCTAssertEqual(Array(firstRows.prefix(2)), helperFocused ? [9, 7] : [8, 7])
            let focused = try XCTUnwrap(ready.focusedWindowID)
            var session = WindowSwitcherSession(entries: rows, selectedID: focused, isPersistent: false,
                                                originalWindowID: focused)
            XCTAssertEqual(session.selected?.windowNumber, helperFocused ? 9 : 8)
            session.advance(1)
            XCTAssertEqual(session.selected?.windowNumber, 7)
        }
    }

    func testWakeAndSpaceChangesDoNotResumeAnInactiveSession() async throws {
        let first = CatalogAXAccess(number: 7, elementPID: 201)
        let second = CatalogAXAccess(number: 8, elementPID: 202)
        let center = NotificationCenter()
        let catalog = twoHostCatalog(first, second, notificationCenter: center)
        defer { catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }
        center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        try await Task.sleep(for: .milliseconds(20))
        let reads = first.read { $0.reads }
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        center.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        catalog.refresh()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(first.read { $0.reads }, reads)
        center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        try await waitUntil { first.read { $0.reads } > reads }
    }

    private func twoHostCatalog(_ first: CatalogAXAccess, _ second: CatalogAXAccess,
                                cgReads: CatalogAXAccess? = nil,
                                notificationCenter: NotificationCenter = NotificationCenter(),
                                isDragging: @escaping () -> Bool = { false }) -> WindowSwitcherAppCatalog {
        WindowSwitcherAppCatalog(notificationCenter: notificationCenter, accessFactory: { $0 == 42 ? first : second },
            allSpacesCatalog: .init(windowRecordProvider: { cgReads?.update { $0.reads += 1 }; return [] }),
            discovery: .init(applications: {
                [.init(processIdentifier: 42, bundleIdentifier: "first", bundlePath: "/First.app", localizedName: "First"),
                 .init(processIdentifier: 43, bundleIdentifier: "second", bundlePath: "/Second.app", localizedName: "Second")]
            }, isAccessibilityTrusted: { true }, isDragging: isDragging))
    }

    private func launchCatalog(previous: CatalogAXAccess, launched: CatalogAXAccess, helper: CatalogAXAccess? = nil,
                               notificationCenter: NotificationCenter = NotificationCenter(), launchAppIsActive: Bool = true,
                               helperIsActive: Bool = false,
                               foreground: @escaping () -> pid_t,
                               records: @escaping @Sendable () -> [WindowSwitcherWindowRecord]? = { [] })
        -> WindowSwitcherAppCatalog {
        WindowSwitcherAppCatalog(notificationCenter: notificationCenter, accessFactory: { pid in
            if pid == 42 { return previous }
            if pid == 44, let helper { return helper }
            return launched
        }, allSpacesCatalog: .init(windowRecordProvider: records), discovery: .init(applications: {
            let prior = WindowSwitcherAppCatalog.Application(processIdentifier: 42, localizedName: "Previous",
                                                             isActive: foreground() == 42)
            guard foreground() == 43 else { return [prior] }
            var apps = [prior, .init(processIdentifier: 43, bundleIdentifier: "fixture.launched", bundlePath: "/Fixture.app",
                                     localizedName: "Launched", isActive: launchAppIsActive)]
            if helper != nil {
                apps.append(.init(processIdentifier: 44, bundleIdentifier: "fixture.launched.helper",
                                  bundlePath: "/Fixture.app/Helper.app", localizedName: "Helper",
                                  isRegular: false, isActive: helperIsActive))
            }
            return apps
        }, foregroundPID: { foreground() }, isLaunching: { $0 == 43 },
           isAccessibilityTrusted: { true }, isDragging: { false }))
    }

    private func fixtureEntries(_ opening: WindowSwitcherOpening) -> [WindowSwitcherAppEntry] {
        opening.entries.filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    }

    private func fixtureEntries(_ catalog: WindowSwitcherAppCatalog, sortMode: WindowSwitcherSortMode = .recentUse)
        -> [WindowSwitcherAppEntry] {
        let hostPID = ProcessInfo.processInfo.processIdentifier
        return catalog.entries(sortMode: sortMode).filter { $0.processIdentifier != hostPID }
    }

    private func makeCatalog(host: CatalogAXAccess, helper: CatalogAXAccess,
                             helperIsActive: Bool = false,
                             accessFactory: (@Sendable (pid_t) -> any WindowSwitcherAXAccess)? = nil) -> WindowSwitcherAppCatalog {
        let records = WindowSwitcherWindowRecords(windowRecordProvider: {
            guard let number = helper.read({ $0.number }) else { return [] }
            return [.init(windowNumber: number, processIdentifier: 43, title: "Fixture", isOnScreen: true,
                          bounds: CGRect(x: 20, y: 20, width: 800, height: 600))]
        })
        return WindowSwitcherAppCatalog(notificationCenter: NotificationCenter(),
            accessFactory: accessFactory ?? { $0 == 42 ? host : helper }, allSpacesCatalog: records,
            discovery: .init(applications: {
                [.init(processIdentifier: 42, bundleIdentifier: "fixture.host", bundlePath: "/Fixture.app", localizedName: "Fixture"),
                 .init(processIdentifier: 43, bundleIdentifier: "fixture.host.helper", bundlePath: "/Fixture.app/Helper.app",
                       localizedName: "Helper", isRegular: false, isActive: helperIsActive)]
            }, isAccessibilityTrusted: { true }, isDragging: { false }))
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    private func numbers(_ catalog: WindowSwitcherAppCatalog) -> Set<CGWindowID> {
        Set(catalog.entries(sortMode: .fixed).filter { $0.processIdentifier == 42 }.compactMap(\.windowNumber))
    }

    func testStopDuringHelperScanDoesNotRepublishWindows() async throws {
        let host = CatalogAXAccess(number: 7, elementPID: 201)
        let helper = CatalogAXAccess(number: 8, elementPID: 202)
        let release = DispatchSemaphore(value: 0)
        helper.update { $0.beforeRead = { _ = release.wait(timeout: .now() + 5) } }
        let catalog = makeCatalog(host: host, helper: helper)
        defer { release.signal(); catalog.stop() }
        var callbacks = 0
        catalog.onChange = { callbacks += 1 }
        catalog.start()
        try await waitUntil { catalog.refresh(); return helper.read { $0.reads > 0 } }
        catalog.stop()
        let callbacksAtStop = callbacks
        XCTAssertTrue(catalog.entries(sortMode: .fixed).isEmpty)
        release.signal()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(catalog.entries(sortMode: .fixed).isEmpty)
        XCTAssertEqual(callbacks, callbacksAtStop)
    }

    func testHostAXRecordKeepsItsWorkerWhenCompositorOwnerIsHelper() async throws {
        let host = CatalogAXAccess(number: 7, elementPID: 201)
        let helper = CatalogAXAccess(number: 7, elementPID: 202)
        let catalog = makeCatalog(host: host, helper: helper)
        defer { catalog.stop() }
        catalog.start()
        try await waitUntil {
            catalog.entries(sortMode: .fixed).contains { $0.processIdentifier == 42 && $0.owningProcessIdentifier == 43 }
        }
        let entry = try XCTUnwrap(catalog.entries(sortMode: .fixed).first { $0.processIdentifier == 42 })
        XCTAssertEqual(entry.owningProcessIdentifier, 43)
        XCTAssertEqual(entry.axWorkerPID, 42)
        let result = await catalog.closeWindow(entry)
        XCTAssertEqual(result, .requested)
        XCTAssertEqual(host.read { $0.actions }, [kAXPressAction])
        XCTAssertTrue(helper.read { $0.actions.isEmpty })
    }

    func testHelperAXRecordUsesHelperWorkerForClose() async throws {
        let host = CatalogAXAccess(number: nil, elementPID: 201)
        let helper = CatalogAXAccess(number: 8, elementPID: 202)
        let catalog = makeCatalog(host: host, helper: helper)
        defer { catalog.stop() }
        catalog.start()
        try await waitUntil {
            catalog.refresh()
            return catalog.entries(sortMode: .fixed).contains { $0.axWorkerPID == 43 }
        }
        let entry = try XCTUnwrap(catalog.entries(sortMode: .fixed).first { $0.axWorkerPID == 43 })
        let result = await catalog.closeWindow(entry)
        XCTAssertEqual(result, .requested)
        XCTAssertEqual(helper.read { $0.actions }, [kAXPressAction])
        XCTAssertTrue(host.read { $0.actions.isEmpty })
    }

    func testActiveVerifiedHelperRecordsItsFocusedWindowAsRecentUse() async throws {
        let host = CatalogAXAccess(number: nil, elementPID: 201)
        let helper = CatalogAXAccess(number: 8, elementPID: 202)
        helper.update { $0.focused = true }
        let catalog = makeCatalog(host: host, helper: helper, helperIsActive: true)
        defer { catalog.stop() }
        catalog.start()

        try await waitUntil {
            catalog.refresh()
            return self.fixtureEntries(catalog).contains { $0.id == catalog.focusedWindowID }
        }
        let focused = try XCTUnwrap(catalog.focusedWindowID)
        XCTAssertEqual(fixtureEntries(catalog).first?.id, focused)
        XCTAssertEqual(fixtureEntries(catalog).first?.axWorkerPID, 43)
    }
}

private func visibleRecord(_ number: CGWindowID, owner: pid_t, titleIsAvailable: Bool = true) -> WindowSwitcherWindowRecord {
    .init(windowNumber: number, processIdentifier: owner, title: titleIsAvailable ? "Fixture" : "",
          isOnScreen: true, bounds: CGRect(x: 20, y: 20, width: 800, height: 600),
          hasSpace: true, titleIsAvailable: titleIsAvailable, isOnActiveSpace: true)
}
