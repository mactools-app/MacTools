import AppKit
import ApplicationServices
import XCTest
@testable import WindowSwitcherPlugin

private final class CatalogAXAccess: WindowSwitcherAXAccess, @unchecked Sendable {
    struct State {
        var number: CGWindowID?
        var focused = false
        var replacesWindow = false
        var listUnavailable = false
        var metadataUnavailable = false
        var hasUnreadableSecondary = false
        var beforeRead: (() -> Void)?
        var reads = 0
        var actions: [String] = []
    }
    private let lock = NSLock()
    private var state: State
    private let window: AXUIElement
    private let replacement: AXUIElement
    let observesSystemNotifications = false

    init(number: CGWindowID?, elementPID: pid_t) {
        state = State(number: number)
        window = AXUIElementCreateApplication(elementPID)
        replacement = AXUIElementCreateApplication(elementPID + 100)
    }
    func update(_ body: (inout State) -> Void) { lock.lock(); defer { lock.unlock() }; body(&state) }
    func read<T>(_ body: (State) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(state) }
    func windows(of application: AXUIElement) -> [AXUIElement]? {
        update { $0.reads += 1 }
        read { $0.beforeRead }?()
        return read {
            guard !$0.listUnavailable else { return nil }
            if $0.hasUnreadableSecondary { return [window, replacement] }
            return $0.number == nil ? [] : [$0.replacesWindow ? replacement : window]
        }
    }
    func element(_ owner: AXUIElement, attribute: String) -> AXUIElement? {
        if attribute == kAXFocusedWindowAttribute {
            return read { $0.focused ? ($0.replacesWindow ? replacement : window) : nil }
        }
        return attribute == kAXCloseButtonAttribute ? owner : nil
    }
    func windowAttributes(_ window: AXUIElement) -> [Any]? {
        guard !read({ $0.metadataUnavailable || ($0.hasUnreadableSecondary && CFEqual(window, replacement)) }) else {
            return nil
        }
        var point = CGPoint(x: 20, y: 20)
        var size = CGSize(width: 800, height: 600)
        return [kAXWindowRole, kAXStandardWindowSubrole, "Fixture", false,
                AXValueCreate(.cgPoint, &point)!, AXValueCreate(.cgSize, &size)!]
    }
    func windowNumber(_ window: AXUIElement) -> CGWindowID? { read { $0.number } }
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

    func testSlowLaunchRanksFirstAfterOneForegroundRetry() async throws {
        let previous = CatalogAXAccess(number: 6, elementPID: 201)
        previous.update { $0.focused = true }
        let launched = CatalogAXAccess(number: nil, elementPID: 202)
        let launchDate = Date().addingTimeInterval(-30)
        var isRunning = false
        var foreground: pid_t = 42
        let catalog = WindowSwitcherAppCatalog(notificationCenter: NotificationCenter(),
            accessFactory: { $0 == 42 ? previous : launched },
            allSpacesCatalog: .init(windowRecordProvider: { [] }),
            discovery: .init(applications: {
                let prior = WindowSwitcherAppCatalog.Application(processIdentifier: 42, localizedName: "Previous",
                    isActive: foreground == 42)
                guard isRunning else { return [prior] }
                // The inventory can still report inactive after the foreground handoff.
                return [prior, .init(processIdentifier: 43, localizedName: "Launched", launchDate: launchDate)]
            }, isAccessibilityTrusted: { true }, isDragging: { false }, foregroundPID: { foreground }))
        defer { catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }
        XCTAssertEqual(fixtureWindowNumbers(in: catalog.entries(sortMode: .recentUse)), [6])

        isRunning = true
        catalog.prepareForInvocation(sortMode: .fixed)
        try await waitUntil { catalog.isInvocationReady }
        let reads = launched.read { $0.reads }
        let otherReads = previous.read { $0.reads }
        launched.update { $0.beforeRead = {
            if launched.read({ $0.reads }) == reads + 2 {
                launched.update { $0.number = 7; $0.focused = true }
            }
        } }
        defer { launched.update { $0.beforeRead = nil } }
        foreground = 43
        catalog.prepareForInvocation(sortMode: .recentUse)
        try await waitUntil { catalog.isInvocationReady }
        XCTAssertNil(catalog.opening(sortMode: .recentUse))
        var opening: WindowSwitcherOpening?
        try await waitUntil {
            if opening == nil { opening = catalog.opening(sortMode: .recentUse) }
            return opening != nil
        }
        let rows = try XCTUnwrap(opening)
        XCTAssertEqual(fixtureWindowNumbers(in: rows.entries), [7, 6])
        XCTAssertEqual(rows.entries.first?.windowNumber, 7)
        XCTAssertEqual(rows.focusedWindowID, rows.entries.first?.id)
        XCTAssertEqual(launched.read { $0.reads }, reads + 2)
        XCTAssertEqual(previous.read { $0.reads }, otherReads + 1)
    }

    func testIncompleteLaunchRetryKeepsClosedWindowOutOfOpening() async throws {
        let previous = CatalogAXAccess(number: 6, elementPID: 201)
        let closing = CatalogAXAccess(number: nil, elementPID: 202)
        var foreground: pid_t = 42
        var running = false
        let catalog = WindowSwitcherAppCatalog(notificationCenter: NotificationCenter(),
            accessFactory: { $0 == 42 ? previous : closing },
            allSpacesCatalog: .init(windowRecordProvider: {
                [.init(windowNumber: 7, processIdentifier: 43, title: "Closed", isOnScreen: true,
                       bounds: CGRect(x: 20, y: 20, width: 800, height: 600))]
            }), discovery: .init(applications: {
                let prior = WindowSwitcherAppCatalog.Application(processIdentifier: 42, localizedName: "Previous")
                return running ? [prior, .init(processIdentifier: 43, localizedName: "Launched")] : [prior]
            }, isAccessibilityTrusted: { true }, isDragging: { false }, foregroundPID: { foreground }))
        defer { catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }
        closing.update { $0.beforeRead = {
            if closing.read({ $0.reads }) == 2 { closing.update { $0.listUnavailable = true } }
        } }
        defer { closing.update { $0.beforeRead = nil } }
        running = true
        foreground = 43
        catalog.prepareForInvocation(sortMode: .recentUse)
        try await waitUntil { catalog.isInvocationReady }
        XCTAssertNil(catalog.opening(sortMode: .recentUse))
        try await waitUntil { catalog.unavailableApplicationCount == 1 }
        XCTAssertNil(catalog.opening(sortMode: .recentUse))
        let rows = try XCTUnwrap(catalog.opening(sortMode: .recentUse, deadlineReached: true))
        XCTAssertEqual(fixtureWindowNumbers(in: rows.entries), [6])
        XCTAssertEqual(closing.read { $0.reads }, 2)
    }

    func testPartialLaunchRetryPromotesVerifiedFocusAndKeepsEarlierExclusions() async throws {
        let launched = CatalogAXAccess(number: nil, elementPID: 202)
        let catalog = try await startLaunchInvocation(launched, records: [launchRecord(9)])
        defer { catalog.stop() }
        launched.update { $0.beforeRead = {
            launched.update { $0.number = 7; $0.focused = true; $0.hasUnreadableSecondary = true }
        } }
        defer { launched.update { $0.beforeRead = nil } }
        XCTAssertNil(catalog.opening(sortMode: .recentUse))

        let opening = try await waitForOpening(catalog)
        XCTAssertEqual(fixtureWindowNumbers(in: opening.entries), [7, 6])
        XCTAssertEqual(opening.entries.first?.windowNumber, 7)
        XCTAssertEqual(opening.focusedWindowID, opening.entries.first?.id)
        XCTAssertEqual(launched.read { $0.reads }, 2)
    }

    func testPartialLaunchRetryRemovesClosedWindowDespiteLingeringServerRecord() async throws {
        let launched = CatalogAXAccess(number: 7, elementPID: 202)
        var offSpace = launchRecord(9, isOnScreen: false)
        offSpace.hasSpace = true
        offSpace.isOnActiveSpace = false
        let records = [launchRecord(7), launchRecord(8, title: ""), offSpace]
        let catalog = try await startLaunchInvocation(launched, records: records)
        defer { catalog.stop() }
        XCTAssertTrue(catalog.entries(sortMode: .recentUse).contains { $0.windowNumber == 7 && $0.windowElement != nil })
        launched.update { $0.beforeRead = {
            launched.update { $0.replacesWindow = true; $0.number = 8; $0.metadataUnavailable = true }
        } }
        defer { launched.update { $0.beforeRead = nil } }
        XCTAssertNil(catalog.opening(sortMode: .recentUse))

        try await waitUntil { catalog.unavailableApplicationCount == 1 }
        let opening = try XCTUnwrap(catalog.opening(sortMode: .recentUse, deadlineReached: true))
        XCTAssertEqual(Set(fixtureWindowNumbers(in: opening.entries)), [6, 9])
        XCTAssertEqual(launched.read { $0.reads }, 2)
    }

    func testQueuedLaunchRefreshKeepsClosedWindowOutOfTheOpening() async throws {
        let launched = CatalogAXAccess(number: 7, elementPID: 202)
        let catalog = try await startLaunchInvocation(launched, records: [launchRecord(7), launchRecord(8, title: "")])
        let release = DispatchSemaphore(value: 0)
        defer { release.signal(); catalog.stop() }
        launched.update { $0.beforeRead = {
            switch launched.read({ $0.reads }) {
            case 2:
                _ = release.wait(timeout: .now() + 2)
                launched.update { $0.replacesWindow = true; $0.number = 8; $0.metadataUnavailable = true }
            case 3:
                launched.update { $0.focused = true; $0.metadataUnavailable = false }
            default: break
            }
        } }
        defer { launched.update { $0.beforeRead = nil } }
        XCTAssertNil(catalog.opening(sortMode: .recentUse))
        try await waitUntil { launched.read { $0.reads } == 2 }
        catalog.invalidate(processIdentifiers: [43], windowRecords: true, eventKind: .windows)
        release.signal()

        let opening = try await waitForOpening(catalog)
        XCTAssertEqual(opening.entries.first?.windowNumber, 8)
        XCTAssertEqual(fixtureWindowNumbers(in: opening.entries), [8, 6])
        XCTAssertEqual(launched.read { $0.reads }, 3)
    }

    func testVisibleLaunchWindowWaitsForAccessibilityAfterEmptyRetry() async throws {
        try await checkLateLaunchOpening()
    }

    func testVisibleLaunchWindowWaitsAfterUnavailableWindowList() async throws {
        try await checkLateLaunchOpening { $0.listUnavailable = true }
    }

    func testVisibleLaunchWindowWaitsAfterUnreadableWindowMetadata() async throws {
        try await checkLateLaunchOpening { $0.number = 7; $0.metadataUnavailable = true }
    }

    func testVisibleLaunchWindowWaitsAfterUnmatchedFocusedElement() async throws {
        try await checkLateLaunchOpening { $0.focused = true }
    }

    func testTitleChangeDuringRetryPreservesVerifiedFocus() async throws {
        try await checkFocusAfterLaunchInvalidation(.metadata, expectedReads: 2)
    }

    func testWindowCreationDuringRetryWaitsForQueuedFocusRefresh() async throws {
        try await checkFocusAfterLaunchInvalidation(.windows, expectedReads: 3)
    }

    func testCanceledOpeningLeavesLaunchRetryForReplacementInvocation() async throws {
        let launched = CatalogAXAccess(number: nil, elementPID: 202)
        let catalog = try await startLaunchInvocation(launched)
        defer { catalog.stop() }
        launched.update { $0.beforeRead = {
            if launched.read({ $0.reads }) == 3 { launched.update { $0.number = 7; $0.focused = true } }
        } }
        defer { launched.update { $0.beforeRead = nil } }
        XCTAssertNil(catalog.opening(sortMode: .recentUse))
        catalog.cancelInvocation()
        catalog.prepareForInvocation(sortMode: .recentUse)

        let opening = try await waitForOpening(catalog)
        XCTAssertEqual(fixtureWindowNumbers(in: opening.entries), [7, 6])
        XCTAssertEqual(opening.entries.first?.windowNumber, 7)
        XCTAssertEqual(opening.focusedWindowID, opening.entries.first?.id)
        XCTAssertEqual(launched.read { $0.reads }, 3)
    }

    func testReplacementOpeningDoesNotRepeatAnInFlightLaunchRetry() async throws {
        let launched = CatalogAXAccess(number: nil, elementPID: 202)
        let catalog = try await startLaunchInvocation(launched)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal(); catalog.stop() }
        launched.update { $0.beforeRead = {
            if launched.read({ $0.reads }) == 2 { _ = release.wait(timeout: .now() + 2) }
        } }
        defer { launched.update { $0.beforeRead = nil } }
        XCTAssertNil(catalog.opening(sortMode: .recentUse))
        try await waitUntil { launched.read { $0.reads } == 2 }
        catalog.cancelInvocation()
        catalog.prepareForInvocation(sortMode: .recentUse)
        release.signal()

        let opening = try await waitForOpening(catalog)
        XCTAssertEqual(fixtureWindowNumbers(in: opening.entries), [6])
        XCTAssertEqual(launched.read { $0.reads }, 3)
    }

    func testStaleAXCloseRejectsWindowThatReusedItsWindowServerNumber() async throws {
        let host = CatalogAXAccess(number: 7, elementPID: 201)
        let other = CatalogAXAccess(number: 8, elementPID: 202)
        let placement = CatalogAXAccess(number: nil, elementPID: 203)
        let catalog = WindowSwitcherAppCatalog(notificationCenter: NotificationCenter(),
            accessFactory: { $0 == 42 ? host : other },
            allSpacesCatalog: .init(windowRecordProvider: {
                let onScreen = placement.read { $0.number == nil }
                return [.init(windowNumber: 7, processIdentifier: 42, title: "Fixture", isOnScreen: onScreen,
                    bounds: CGRect(x: 20, y: 20, width: 800, height: 600), hasSpace: true, isOnActiveSpace: onScreen)]
            }), discovery: .init(applications: {
                [.init(processIdentifier: 42, localizedName: "First"),
                 .init(processIdentifier: 43, localizedName: "Other")]
            }, isAccessibilityTrusted: { true }, isDragging: { false }))
        defer { catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }
        func row() -> WindowSwitcherAppEntry? { catalog.entries(sortMode: .fixed).first { $0.windowNumber == 7 } }
        let original = try XCTUnwrap(row())
        let originalAX = try XCTUnwrap(original.windowElement)

        placement.update { $0.number = 7 }
        catalog.prepareForInvocation(sortMode: .fixed)
        try await waitUntil { catalog.isInvocationReady && row()?.isOnOtherDesktop == true }
        host.update { $0.number = nil }
        catalog.invalidate(processIdentifiers: [42], windowRecords: false)
        try await waitUntil { row()?.id == original.id && row()?.windowElement == nil }

        host.update { $0.number = 7; $0.replacesWindow = true }
        catalog.invalidate(processIdentifiers: [42], windowRecords: false)
        try await waitUntil { row()?.windowElement.map { !CFEqual($0, originalAX) } == true }

        placement.update { $0.number = nil }
        catalog.prepareForInvocation(sortMode: .fixed)
        try await waitUntil { catalog.isInvocationReady && row()?.isOnOtherDesktop == false }
        host.update { $0.number = nil }
        catalog.invalidate(processIdentifiers: [42], windowRecords: false)
        try await waitUntil { row()?.windowElement == nil }
        placement.update { $0.number = 7 }
        catalog.prepareForInvocation(sortMode: .fixed)
        try await waitUntil { catalog.isInvocationReady && row()?.isOnOtherDesktop == true && row()?.windowElement == nil }
        host.update { $0.number = 7 }

        let result = await catalog.closeWindow(original)
        XCTAssertEqual(result, .unavailable)
        XCTAssertTrue(host.read { $0.actions.isEmpty })
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

    private func startLaunchInvocation(_ launched: CatalogAXAccess, records: [WindowSwitcherWindowRecord] = []) async throws
        -> WindowSwitcherAppCatalog {
        let previous = CatalogAXAccess(number: 6, elementPID: 201)
        previous.update { $0.focused = true }
        var foreground: pid_t = 42
        let catalog = WindowSwitcherAppCatalog(notificationCenter: NotificationCenter(),
            accessFactory: { $0 == 42 ? previous : launched },
            allSpacesCatalog: .init(windowRecordProvider: { records }),
            discovery: .init(applications: {
                let prior = WindowSwitcherAppCatalog.Application(processIdentifier: 42, localizedName: "Previous",
                    isActive: foreground == 42)
                guard foreground == 43 else { return [prior] }
                return [prior, .init(processIdentifier: 43, localizedName: "Launched")]
            }, isAccessibilityTrusted: { true }, isDragging: { false }, foregroundPID: { foreground }))
        catalog.start()
        do {
            try await waitUntil { catalog.isInvocationReady }
            foreground = 43
            catalog.prepareForInvocation(sortMode: .recentUse)
            try await waitUntil { catalog.isInvocationReady }
            return catalog
        } catch {
            catalog.stop()
            throw error
        }
    }

    private func launchRecord(_ number: CGWindowID, title: String = "Fixture",
                              isOnScreen: Bool = true) -> WindowSwitcherWindowRecord {
        .init(windowNumber: number, processIdentifier: 43, title: title, isOnScreen: isOnScreen,
              bounds: CGRect(x: 20, y: 20, width: 800, height: 600))
    }

    private func checkLateLaunchOpening(retryReply: @escaping (inout CatalogAXAccess.State) -> Void = { _ in }) async throws {
        let launched = CatalogAXAccess(number: nil, elementPID: 202)
        let catalog = try await startLaunchInvocation(launched, records: [launchRecord(7)])
        defer { catalog.onChange = nil; launched.update { $0.beforeRead = nil }; catalog.stop() }
        launched.update { $0.beforeRead = {
            if launched.read({ $0.reads }) == 2 { launched.update(retryReply) }
        } }
        var firstOpening: WindowSwitcherOpening?
        var deliveredEvent = false
        catalog.onChange = {
            guard launched.read({ $0.reads }) >= 2 else { return }
            if firstOpening == nil { firstOpening = catalog.opening(sortMode: .recentUse) }
            if !deliveredEvent {
                deliveredEvent = true
                launched.update {
                    $0.number = 7
                    $0.focused = true
                    $0.listUnavailable = false
                    $0.metadataUnavailable = false
                }
                catalog.invalidate(processIdentifiers: [43], windowRecords: true, eventKind: .windows)
            }
        }
        XCTAssertNil(catalog.opening(sortMode: .recentUse))
        try await waitUntil {
            firstOpening != nil && catalog.entries(sortMode: .recentUse).contains { $0.windowNumber == 7 }
        }
        let opening = try XCTUnwrap(firstOpening)
        XCTAssertEqual(fixtureWindowNumbers(in: opening.entries), [7, 6])
        XCTAssertEqual(opening.entries.first?.windowNumber, 7)
        XCTAssertEqual(opening.focusedWindowID, opening.entries.first?.id)
        XCTAssertEqual(launched.read { $0.reads }, 3)
    }

    private func checkFocusAfterLaunchInvalidation(_ kind: WindowSwitcherProcessEvent.Kind, expectedReads: Int) async throws {
        let launched = CatalogAXAccess(number: nil, elementPID: 202)
        let catalog = try await startLaunchInvocation(launched)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal(); catalog.stop() }
        launched.update { $0.beforeRead = {
            if launched.read({ $0.reads }) == 2 { _ = release.wait(timeout: .now() + 2) }
        } }
        defer { launched.update { $0.beforeRead = nil } }
        XCTAssertNil(catalog.opening(sortMode: .recentUse))
        try await waitUntil { launched.read { $0.reads } == 2 }
        catalog.invalidate(processIdentifiers: [43], windowRecords: kind.requiresWindowRecords, eventKind: kind)
        launched.update { $0.number = 7; $0.focused = true }
        release.signal()

        let opening = try await waitForOpening(catalog)
        XCTAssertEqual(fixtureWindowNumbers(in: opening.entries), [7, 6])
        XCTAssertEqual(opening.entries.first?.windowNumber, 7)
        XCTAssertEqual(opening.focusedWindowID, opening.entries.first?.id)
        XCTAssertEqual(launched.read { $0.reads }, expectedReads)
    }

    private func waitForOpening(_ catalog: WindowSwitcherAppCatalog) async throws -> WindowSwitcherOpening {
        var opening: WindowSwitcherOpening?
        try await waitUntil {
            if opening == nil { opening = catalog.opening(sortMode: .recentUse) }
            return opening != nil
        }
        return try XCTUnwrap(opening)
    }

    private func numbers(_ catalog: WindowSwitcherAppCatalog) -> Set<CGWindowID> {
        Set(catalog.entries(sortMode: .fixed).filter { $0.processIdentifier == 42 }.compactMap(\.windowNumber))
    }

    private func fixtureWindowNumbers(in entries: [WindowSwitcherAppEntry]) -> [CGWindowID] {
        let hostPID = ProcessInfo.processInfo.processIdentifier
        return entries.filter { $0.processIdentifier != hostPID }.compactMap(\.windowNumber)
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
            return catalog.focusedWindowID != nil
        }
        let focused = try XCTUnwrap(catalog.focusedWindowID)
        XCTAssertEqual(catalog.entries(sortMode: .recentUse).first?.id, focused)
        XCTAssertEqual(catalog.entries(sortMode: .recentUse).first?.axWorkerPID, 43)
    }

    func testEndedLaunchCheckPublishesExistingVerifiedHelperFocus() async throws {
        let prior = CatalogAXAccess(number: 6, elementPID: 201)
        prior.update { $0.focused = true }
        let host = CatalogAXAccess(number: nil, elementPID: 202)
        let helper = CatalogAXAccess(number: 8, elementPID: 203)
        let release = DispatchSemaphore(value: 0)
        helper.update { $0.focused = true; $0.beforeRead = { _ = release.wait(timeout: .now() + 2) } }
        let center = NotificationCenter()
        var foreground: pid_t = 42
        var helperActivityLoaded = false
        let record = WindowSwitcherWindowRecord(windowNumber: 8, processIdentifier: 44, title: "Helper",
            isOnScreen: true, bounds: CGRect(x: 20, y: 20, width: 800, height: 600))
        let catalog = WindowSwitcherAppCatalog(notificationCenter: center, accessFactory: {
            switch $0 {
            case 42: return prior
            case 43: return host
            default: return helper
            }
        }, allSpacesCatalog: .init(windowRecordProvider: { [record] }), discovery: .init(applications: {
            let previous = WindowSwitcherAppCatalog.Application(processIdentifier: 42, localizedName: "Previous",
                isActive: foreground == 42)
            guard foreground != 42 else { return [previous] }
            if foreground == 44 { helperActivityLoaded = true }
            return [previous, .init(processIdentifier: 43, bundleIdentifier: "fixture.host", bundlePath: "/Fixture.app",
                localizedName: "Host", isActive: foreground == 43),
                .init(processIdentifier: 44, bundleIdentifier: "fixture.host.helper", bundlePath: "/Fixture.app/Helper.app",
                    localizedName: "Helper", isRegular: false, isActive: foreground == 44)]
        }, isAccessibilityTrusted: { true }, isDragging: { false }, foregroundPID: { foreground }))
        defer { release.signal(); helper.update { $0.beforeRead = nil }; catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }
        foreground = 43
        catalog.prepareForInvocation(sortMode: .recentUse)
        try await waitUntil { helper.read { $0.reads } == 1 }
        foreground = 44
        // The activation callback reloads the inventory supplied by the fixture.
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil,
            userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
        try await waitUntil { helperActivityLoaded }
        release.signal()

        let opening = try await waitForOpening(catalog)
        let helperRow = try XCTUnwrap(opening.entries.first { $0.windowNumber == 8 && $0.axWorkerPID == 44 })
        XCTAssertEqual(fixtureWindowNumbers(in: opening.entries), [8, 6])
        XCTAssertEqual(opening.entries.first?.id, helperRow.id)
        XCTAssertEqual(opening.focusedWindowID, helperRow.id)
    }
}
