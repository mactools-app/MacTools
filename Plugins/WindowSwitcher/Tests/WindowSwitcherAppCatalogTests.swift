import AppKit
import ApplicationServices
import XCTest
@testable import WindowSwitcherPlugin

private final class CatalogAXAccess: WindowSwitcherAXAccess, @unchecked Sendable {
    struct State {
        var number: CGWindowID?
        var focused = false
        var beforeRead: (() -> Void)?
        var reads = 0
        var actions: [String] = []
    }
    private let lock = NSLock()
    private var state: State
    private let window: AXUIElement
    private let replacement: AXUIElement?
    private let replacementNumber: CGWindowID?
    let observesSystemNotifications = false

    init(number: CGWindowID?, elementPID: pid_t, replacementNumber: CGWindowID? = nil) {
        state = State(number: number)
        window = AXUIElementCreateApplication(elementPID)
        self.replacementNumber = replacementNumber
        replacement = replacementNumber.map { _ in AXUIElementCreateApplication(elementPID + 100) }
    }
    func update(_ body: (inout State) -> Void) { lock.lock(); defer { lock.unlock() }; body(&state) }
    func read<T>(_ body: (State) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(state) }
    func windows(of application: AXUIElement) -> [AXUIElement]? {
        update { $0.reads += 1 }
        read { $0.beforeRead }?()
        return read { state in
            guard let number = state.number else { return [] }
            return [number == replacementNumber ? replacement ?? window : window]
        }
    }
    func element(_ owner: AXUIElement, attribute: String) -> AXUIElement? {
        if attribute == kAXFocusedWindowAttribute, read({ $0.focused }) { return window }
        return attribute == kAXCloseButtonAttribute ? owner : nil
    }
    func windowAttributes(_ window: AXUIElement) -> [Any]? {
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
        catalog.prepareForInvocation()
        XCTAssertFalse(catalog.isInvocationReady)
        XCTAssertEqual(numbers(catalog), [7])
        try await waitUntil { catalog.isInvocationReady }
        XCTAssertEqual(numbers(catalog), [9])
    }

    func testNewlyLaunchedForegroundWindowRanksFirstBeforeAccessibilityReportsFocus() async throws {
        let first = CatalogAXAccess(number: 7, elementPID: 201)
        first.update { $0.focused = true }
        let launched = CatalogAXAccess(number: 8, elementPID: 202)
        var launchedExists = false
        var foregroundPID: pid_t = 42
        let catalog = WindowSwitcherAppCatalog(notificationCenter: NotificationCenter(),
            accessFactory: { $0 == 42 ? first : launched },
            allSpacesCatalog: .init(windowRecordProvider: { [] }),
            discovery: .init(applications: {
                let first = WindowSwitcherAppCatalog.Application(
                    processIdentifier: 42, bundleIdentifier: "first", localizedName: "First", isActive: true)
                let launched = WindowSwitcherAppCatalog.Application(
                    processIdentifier: 43, bundleIdentifier: "launched", localizedName: "Launched")
                return launchedExists ? [first, launched] : [first]
            }, foregroundProcessIdentifier: { foregroundPID }, isAccessibilityTrusted: { true }, isDragging: { false }))
        defer { catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }

        launchedExists = true
        foregroundPID = 43
        catalog.prepareForInvocation()
        try await waitUntil { catalog.isInvocationReady }
        let entries = catalog.entries(sortMode: .recentUse)
        XCTAssertEqual(entries.compactMap(\.windowNumber), [8, 7])
        XCTAssertEqual(catalog.focusedWindowID, entries.first?.id)

        foregroundPID = 42
        catalog.prepareForInvocation()
        try await waitUntil { catalog.isInvocationReady }
        XCTAssertEqual(catalog.entries(sortMode: .recentUse).compactMap(\.windowNumber), [7, 8])
    }

    func testInvocationRetriesForegroundDiscoveryOnceWhenWindowServerSeesAWindow() async throws {
        let previous = CatalogAXAccess(number: 7, elementPID: 201)
        previous.update { $0.focused = true }
        let launched = CatalogAXAccess(number: nil, elementPID: 202)
        launched.update {
            $0.beforeRead = { [weak launched] in
                launched?.update { state in
                    guard state.reads == 2 else { return }
                    state.number = 8
                    state.focused = true
                }
            }
        }
        var launchedExists = false
        var foregroundPID: pid_t = 42
        let catalog = WindowSwitcherAppCatalog(notificationCenter: NotificationCenter(),
            accessFactory: { $0 == 42 ? previous : launched },
            allSpacesCatalog: .init(windowRecordProvider: {
                [.init(windowNumber: 8, processIdentifier: 43, title: "Launched", isOnScreen: true,
                       bounds: CGRect(x: 20, y: 20, width: 800, height: 600))]
            }),
            discovery: .init(applications: {
                let previous = WindowSwitcherAppCatalog.Application(
                    processIdentifier: 42, bundleIdentifier: "previous", localizedName: "Previous")
                let launched = WindowSwitcherAppCatalog.Application(
                    processIdentifier: 43, bundleIdentifier: "launched", localizedName: "Launched")
                return launchedExists ? [previous, launched] : [previous]
            }, foregroundProcessIdentifier: { foregroundPID }, isAccessibilityTrusted: { true }, isDragging: { false }))
        defer { catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }

        launchedExists = true
        foregroundPID = 43
        catalog.prepareForInvocation()
        try await waitUntil { catalog.isInvocationReady }
        XCTAssertEqual(launched.read { $0.reads }, 2)
        XCTAssertEqual(catalog.entries(sortMode: .recentUse).compactMap(\.windowNumber), [8, 7])

        launched.update {
            $0.number = nil
            $0.focused = false
            $0.beforeRead = nil
        }
        catalog.prepareForInvocation()
        try await waitUntil { catalog.isInvocationReady }
        XCTAssertEqual(launched.read { $0.reads }, 4)
        XCTAssertEqual(catalog.entries(sortMode: .recentUse).compactMap(\.windowNumber), [7])
    }

    func testOffscreenAXWindowDoesNotSuppressRetryForAnUnlistedOnscreenWindow() async throws {
        let previous = CatalogAXAccess(number: 7, elementPID: 201)
        previous.update { $0.focused = true }
        let launched = CatalogAXAccess(number: 8, elementPID: 202)
        launched.update {
            $0.beforeRead = { [weak launched] in
                launched?.update { state in
                    guard state.reads == 2 else { return }
                    state.number = 9
                    state.focused = true
                }
            }
        }
        var foregroundPID: pid_t = 42
        let catalog = WindowSwitcherAppCatalog(notificationCenter: NotificationCenter(),
            accessFactory: { $0 == 42 ? previous : launched },
            allSpacesCatalog: .init(windowRecordProvider: {
                [.init(windowNumber: 8, processIdentifier: 43, title: "Restoring", isOnScreen: false,
                       bounds: CGRect(x: 20, y: 20, width: 800, height: 600), isOnActiveSpace: true),
                 .init(windowNumber: 9, processIdentifier: 43, title: "", isOnScreen: true,
                       bounds: CGRect(x: 40, y: 40, width: 800, height: 600), titleIsAvailable: false)]
            }),
            discovery: .init(applications: {
                let prior = WindowSwitcherAppCatalog.Application(
                    processIdentifier: 42, bundleIdentifier: "previous", localizedName: "Previous")
                let new = WindowSwitcherAppCatalog.Application(
                    processIdentifier: 43, bundleIdentifier: "launched", localizedName: "Launched")
                return foregroundPID == 43 ? [prior, new] : [prior]
            }, foregroundProcessIdentifier: { foregroundPID }, isAccessibilityTrusted: { true }, isDragging: { false }))
        defer { catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }

        foregroundPID = 43
        catalog.prepareForInvocation()
        try await waitUntil { catalog.isInvocationReady }
        XCTAssertEqual(launched.read { $0.reads }, 2)
        XCTAssertEqual(catalog.entries(sortMode: .recentUse).compactMap(\.windowNumber), [9, 7])
    }

    func testInvocationPublishesBeforeQueuedBackgroundVisibilityReadCompletes() async throws {
        let access = CatalogAXAccess(number: 7, elementPID: 201)
        let blockRead = DispatchSemaphore(value: 0)
        let readStarted = DispatchSemaphore(value: 0)
        let releaseRead = DispatchSemaphore(value: 0)
        let catalog = WindowSwitcherAppCatalog(notificationCenter: NotificationCenter(),
            accessFactory: { _ in access },
            allSpacesCatalog: .init(windowRecordRefreshTimeout: 5, windowRecordProvider: {
                if blockRead.wait(timeout: .now()) == .success {
                    readStarted.signal()
                    _ = releaseRead.wait(timeout: .now() + 5)
                }
                return []
            }),
            discovery: .init(applications: {
                [.init(processIdentifier: 42, bundleIdentifier: "fixture", localizedName: "Fixture")]
            }, foregroundProcessIdentifier: { 42 }, isAccessibilityTrusted: { true }, isDragging: { false }))
        defer { releaseRead.signal(); releaseRead.signal(); catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }

        blockRead.signal()
        blockRead.signal()
        catalog.prepareForInvocation()
        try await waitUntil { readStarted.wait(timeout: .now()) == .success }
        XCTAssertFalse(catalog.isInvocationReady)
        catalog.refresh()
        releaseRead.signal()

        try await waitUntil { readStarted.wait(timeout: .now()) == .success }
        try await waitUntil { catalog.isInvocationReady }
        let entries = catalog.entries(sortMode: .recentUse)
        XCTAssertEqual(entries.first?.windowNumber, 7)
        XCTAssertEqual(catalog.focusedWindowID, entries.first?.id)
    }

    func testInvocationStartsFreshCaptureAndUsesOnlyOneVisibilityDrivenRetry() async throws {
        let previous = CatalogAXAccess(number: 7, elementPID: 201)
        previous.update { $0.focused = true }
        let launched = CatalogAXAccess(number: 8, elementPID: 202)
        let holdOlderCapture = DispatchSemaphore(value: 0)
        let olderCaptureStarted = DispatchSemaphore(value: 0)
        let releaseOlderCapture = DispatchSemaphore(value: 0)
        let holdInvocationCapture = DispatchSemaphore(value: 0)
        let invocationCaptureStarted = DispatchSemaphore(value: 0)
        let releaseInvocationCapture = DispatchSemaphore(value: 0)
        let reader = WindowSwitcherWindowRecords(windowRecordRefreshTimeout: 5, windowRecordProvider: {
            if holdOlderCapture.wait(timeout: .now()) == .success {
                olderCaptureStarted.signal()
                _ = releaseOlderCapture.wait(timeout: .now() + 5)
                return []
            }
            guard holdInvocationCapture.wait(timeout: .now()) == .success else { return [] }
            invocationCaptureStarted.signal()
            _ = releaseInvocationCapture.wait(timeout: .now() + 5)
            return [.init(windowNumber: 8, processIdentifier: 43, title: "Restoring", isOnScreen: false,
                          bounds: CGRect(x: 20, y: 20, width: 800, height: 600)),
                    .init(windowNumber: 9, processIdentifier: 43, title: "", isOnScreen: true,
                          bounds: CGRect(x: 40, y: 40, width: 800, height: 600), titleIsAvailable: false)]
        })
        var foregroundPID: pid_t = 42
        let catalog = WindowSwitcherAppCatalog(notificationCenter: NotificationCenter(),
            accessFactory: { $0 == 42 ? previous : launched }, allSpacesCatalog: reader,
            discovery: .init(applications: {
                let previous = WindowSwitcherAppCatalog.Application(
                    processIdentifier: 42, bundleIdentifier: "previous", localizedName: "Previous")
                let launched = WindowSwitcherAppCatalog.Application(
                    processIdentifier: 43, bundleIdentifier: "launched", localizedName: "Launched")
                return foregroundPID == 43 ? [previous, launched] : [previous]
            }, foregroundProcessIdentifier: { foregroundPID }, isAccessibilityTrusted: { true }, isDragging: { false }))
        defer {
            releaseOlderCapture.signal()
            releaseInvocationCapture.signal()
            catalog.stop()
        }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }

        holdOlderCapture.signal()
        let activation = Task { await reader.freshRecordsForActivation() }
        try await waitUntil { olderCaptureStarted.wait(timeout: .now()) == .success }
        activation.cancel()

        holdInvocationCapture.signal()
        foregroundPID = 43
        catalog.prepareForInvocation()
        try await waitUntil { invocationCaptureStarted.wait(timeout: .now()) == .success }
        try await waitUntil { catalog.entries(sortMode: .fixed).contains { $0.windowNumber == 8 } }
        XCTAssertEqual(launched.read { $0.reads }, 1)
        XCTAssertFalse(catalog.isInvocationReady)
        releaseInvocationCapture.signal()

        try await waitUntil { catalog.isInvocationReady }
        XCTAssertEqual(launched.read { $0.reads }, 2)
        XCTAssertEqual(catalog.entries(sortMode: .recentUse).compactMap(\.windowNumber), [7, 8])
        XCTAssertNil(catalog.focusedWindowID)
    }

    func testForegroundChangeDropsInferenceBeforeInvocationBecomesReady() async throws {
        let previous = CatalogAXAccess(number: 7, elementPID: 201)
        previous.update { $0.focused = true }
        let first = CatalogAXAccess(number: 8, elementPID: 202)
        let second = CatalogAXAccess(number: 9, elementPID: 203)
        let slow = CatalogAXAccess(number: 11, elementPID: 204)
        let release = DispatchSemaphore(value: 0)
        var foregroundPID: pid_t = 41
        let catalog = WindowSwitcherAppCatalog(notificationCenter: NotificationCenter(),
            accessFactory: { pid in
                switch pid {
                case 41: previous
                case 42: first
                case 43: second
                default: slow
                }
            }, allSpacesCatalog: .init(windowRecordProvider: { [] }),
            discovery: .init(applications: {
                (41...44).map { pid in
                    .init(processIdentifier: pid_t(pid), bundleIdentifier: "fixture.\(pid)", localizedName: "Fixture \(pid)")
                }
            }, foregroundProcessIdentifier: { foregroundPID }, isAccessibilityTrusted: { true }, isDragging: { false }))
        defer { release.signal(); catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }

        slow.update { $0.beforeRead = { _ = release.wait(timeout: .now() + 2) } }
        second.update {
            $0.number = 10
            $0.focused = true
        }
        foregroundPID = 42
        catalog.prepareForInvocation()
        try await waitUntil { catalog.entries(sortMode: .fixed).contains { $0.windowNumber == 10 } }
        XCTAssertFalse(catalog.isInvocationReady)

        foregroundPID = 43
        catalog.invalidate(processIdentifiers: [43], windowRecords: true)
        release.signal()
        try await waitUntil { catalog.isInvocationReady }
        let entries = catalog.entries(sortMode: .recentUse)
        XCTAssertNotEqual(entries.first?.windowNumber, 8)
        XCTAssertNotEqual(catalog.focusedWindowID, entries.first { $0.windowNumber == 8 }?.id)
    }

    func testRecentUseWaitsForVisibilityAndKeepsInferenceOutOfHistory() async throws {
        let previous = CatalogAXAccess(number: 7, elementPID: 201)
        previous.update { $0.focused = true }
        let launched = CatalogAXAccess(number: nil, elementPID: 202)
        let failNextRead = DispatchSemaphore(value: 0)
        let delayNextRead = DispatchSemaphore(value: 0)
        let releaseRead = DispatchSemaphore(value: 0)
        var foregroundPID: pid_t = 42
        let catalog = WindowSwitcherAppCatalog(notificationCenter: NotificationCenter(),
            accessFactory: { $0 == 42 ? previous : launched },
            allSpacesCatalog: .init(windowRecordRefreshTimeout: 2, windowRecordProvider: {
                if failNextRead.wait(timeout: .now()) == .success { return nil }
                if delayNextRead.wait(timeout: .now()) == .success {
                    _ = releaseRead.wait(timeout: .now() + 2)
                }
                return [.init(windowNumber: 9, processIdentifier: 43, title: "Onscreen", isOnScreen: true,
                       bounds: CGRect(x: 40, y: 40, width: 800, height: 600))]
            }),
            discovery: .init(applications: {
                [.init(processIdentifier: 42, bundleIdentifier: "previous", localizedName: "Previous"),
                 .init(processIdentifier: 43, bundleIdentifier: "launched", localizedName: "Launched")]
            }, foregroundProcessIdentifier: { foregroundPID }, isAccessibilityTrusted: { true }, isDragging: { false }))
        defer { releaseRead.signal(); catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }

        failNextRead.signal()
        catalog.prepareForInvocation()
        try await waitUntil { catalog.isInvocationReady }
        XCTAssertEqual(catalog.entries(sortMode: .recentUse).last?.metadataUnavailable, true)

        foregroundPID = 43
        launched.update { $0.number = 8 }
        delayNextRead.signal()
        catalog.prepareForInvocation()
        try await waitUntil { catalog.entries(sortMode: .fixed).contains { $0.windowNumber == 8 } }
        XCTAssertFalse(catalog.isInvocationReady)
        XCTAssertEqual(catalog.entries(sortMode: .recentUse).first?.windowNumber, 7)
        releaseRead.signal()
        try await waitUntil { catalog.isInvocationReady }
        XCTAssertEqual(catalog.entries(sortMode: .recentUse).compactMap(\.windowNumber), [9, 7, 8])

        catalog.prepareForInvocation()
        try await waitUntil { catalog.isInvocationReady }
        XCTAssertEqual(catalog.entries(sortMode: .recentUse).first?.windowNumber, 9)

        launched.update { $0.focused = true }
        catalog.prepareForInvocation()
        try await waitUntil { catalog.isInvocationReady }
        let entries = catalog.entries(sortMode: .recentUse)
        XCTAssertEqual(entries.compactMap(\.windowNumber), [8, 7, 9])
        XCTAssertEqual(catalog.focusedWindowID, entries.first?.id)
        var session = WindowSwitcherSession(entries: entries, selectedID: catalog.focusedWindowID,
            isPersistent: false, originalWindowID: catalog.focusedWindowID)
        session.advance(1)
        XCTAssertEqual(session.selected?.windowNumber, 7)
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
            }, foregroundProcessIdentifier: { nil }, isAccessibilityTrusted: { true }, isDragging: isDragging))
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
            }, foregroundProcessIdentifier: { helperIsActive ? 42 : nil },
                isAccessibilityTrusted: { true }, isDragging: { false }))
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Condition was not met before the deadline", file: file, line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
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
            return catalog.focusedWindowID != nil
        }
        let focused = try XCTUnwrap(catalog.focusedWindowID)
        XCTAssertEqual(catalog.entries(sortMode: .recentUse).first?.id, focused)
        XCTAssertEqual(catalog.entries(sortMode: .recentUse).first?.axWorkerPID, 43)
    }

    func testCachedHelperActivationDoesNotOverrideExactForegroundHostFocus() async throws {
        let host = CatalogAXAccess(number: 7, elementPID: 201)
        host.update { $0.focused = true }
        let helper = CatalogAXAccess(number: 8, elementPID: 202)
        let catalog = makeCatalog(host: host, helper: helper, helperIsActive: true)
        defer { catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }

        catalog.prepareForInvocation()
        try await waitUntil { catalog.isInvocationReady }
        let entries = catalog.entries(sortMode: .recentUse)
        XCTAssertEqual(entries.compactMap(\.windowNumber), [7, 8])
        XCTAssertEqual(catalog.focusedWindowID, entries.first?.id)
    }

    func testUnlistedHostFocusRetriesBeforeConsideringCachedHelperFocus() async throws {
        let previous = CatalogAXAccess(number: 7, elementPID: 201)
        previous.update { $0.focused = true }
        let launched = CatalogAXAccess(number: nil, elementPID: 202)
        launched.update {
            $0.focused = true
            $0.beforeRead = { [weak launched] in
                launched?.update { state in
                    if state.reads == 2 { state.number = 9 }
                }
            }
        }
        let helper = CatalogAXAccess(number: 8, elementPID: 203)
        helper.update { $0.focused = true }
        var foregroundPID: pid_t = 42
        let catalog = WindowSwitcherAppCatalog(notificationCenter: NotificationCenter(),
            accessFactory: { pid in
                switch pid {
                case 42: previous
                case 43: launched
                default: helper
                }
            }, allSpacesCatalog: .init(windowRecordProvider: {
                [.init(windowNumber: 9, processIdentifier: 43, title: "New foreground window", isOnScreen: true,
                       bounds: CGRect(x: 40, y: 40, width: 800, height: 600)),
                 .init(windowNumber: 8, processIdentifier: 44, title: "Helper", isOnScreen: true,
                       bounds: CGRect(x: 20, y: 20, width: 800, height: 600))]
            }), discovery: .init(applications: {
                let previous = WindowSwitcherAppCatalog.Application(
                    processIdentifier: 42, bundleIdentifier: "previous", localizedName: "Previous")
                guard foregroundPID == 43 else { return [previous] }
                return [previous,
                        .init(processIdentifier: 43, bundleIdentifier: "launched", bundlePath: "/Launched.app",
                              localizedName: "Launched"),
                        .init(processIdentifier: 44, bundleIdentifier: "launched.helper",
                              bundlePath: "/Launched.app/Helper.app", localizedName: "Helper", isRegular: false, isActive: true)]
            }, foregroundProcessIdentifier: { foregroundPID }, isAccessibilityTrusted: { true }, isDragging: { false }))
        defer { catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }

        foregroundPID = 43
        catalog.prepareForInvocation()
        try await waitUntil { catalog.isInvocationReady }
        XCTAssertEqual(launched.read { $0.reads }, 2)
        XCTAssertEqual(catalog.entries(sortMode: .recentUse).compactMap(\.windowNumber), [9, 7, 8])
    }

    func testPreviouslyAXListedWindowCannotBecomeAnchorAfterItsAXRowDisappears() async throws {
        let previous = CatalogAXAccess(number: 7, elementPID: 201)
        previous.update { $0.focused = true }
        let foreground = CatalogAXAccess(number: 9, elementPID: 202, replacementNumber: 8)
        var foregroundPID: pid_t = 42
        let catalog = WindowSwitcherAppCatalog(notificationCenter: NotificationCenter(),
            accessFactory: { $0 == 42 ? previous : foreground },
            allSpacesCatalog: .init(windowRecordProvider: {
                [.init(windowNumber: 8, processIdentifier: 43, title: "Offscreen", isOnScreen: false,
                       bounds: CGRect(x: 20, y: 20, width: 800, height: 600), hasSpace: true),
                 .init(windowNumber: 9, processIdentifier: 43, title: "Previously listed window", isOnScreen: true,
                       bounds: CGRect(x: 40, y: 40, width: 800, height: 600), hasSpace: true)]
            }),
            discovery: .init(applications: {
                [.init(processIdentifier: 42, bundleIdentifier: "previous", localizedName: "Previous"),
                 .init(processIdentifier: 43, bundleIdentifier: "foreground", localizedName: "Foreground")]
            }, foregroundProcessIdentifier: { foregroundPID }, isAccessibilityTrusted: { true }, isDragging: { false }))
        defer { catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }
        XCTAssertNotNil(catalog.entries(sortMode: .fixed).first { $0.windowNumber == 9 }?.windowElement)

        foreground.update { $0.number = 8 }
        foregroundPID = 43
        catalog.prepareForInvocation()
        try await waitUntil { catalog.isInvocationReady }
        let entries = catalog.entries(sortMode: .recentUse)
        let fallback = try XCTUnwrap(entries.first { $0.windowNumber == 9 })
        XCTAssertNil(fallback.windowElement)
        XCTAssertNil(catalog.focusedWindowID)
        XCTAssertEqual(entries.first?.windowNumber, 7)
    }

    func testForegroundHelperUsesOnlyWindowsTiedToItsProcess() async throws {
        let host = CatalogAXAccess(number: 7, elementPID: 201)
        let helper = CatalogAXAccess(number: nil, elementPID: 202)
        let catalog = WindowSwitcherAppCatalog(notificationCenter: NotificationCenter(),
            accessFactory: { $0 == 42 ? host : helper },
            allSpacesCatalog: .init(windowRecordProvider: {
                [.init(windowNumber: 8, processIdentifier: 43, title: "", isOnScreen: true,
                       bounds: CGRect(x: 20, y: 20, width: 800, height: 600), titleIsAvailable: false)]
            }),
            discovery: .init(applications: {
                [.init(processIdentifier: 42, bundleIdentifier: "fixture.host", bundlePath: "/Fixture.app",
                       localizedName: "Fixture"),
                 .init(processIdentifier: 43, bundleIdentifier: "fixture.host.helper", bundlePath: "/Fixture.app/Helper.app",
                       localizedName: "Helper", isRegular: false)]
            }, foregroundProcessIdentifier: { 43 }, isAccessibilityTrusted: { true }, isDragging: { false }))
        defer { catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }
        XCTAssertEqual(catalog.entries(sortMode: .recentUse).compactMap(\.windowNumber), [7])
        XCTAssertNil(catalog.focusedWindowID)

        host.update { $0.number = 8 }
        catalog.prepareForInvocation()
        try await waitUntil { catalog.isInvocationReady }
        let entry = try XCTUnwrap(catalog.entries(sortMode: .recentUse).first)
        XCTAssertEqual(entry.owningProcessIdentifier, 43)
        XCTAssertEqual(entry.axWorkerPID, 42)
        XCTAssertEqual(catalog.focusedWindowID, entry.id)

        helper.update { $0.focused = true }
        catalog.prepareForInvocation()
        try await waitUntil { catalog.isInvocationReady }
        XCTAssertNil(catalog.focusedWindowID)

        helper.update { $0.number = 8 }
        catalog.prepareForInvocation()
        try await waitUntil { catalog.isInvocationReady }
        XCTAssertEqual(catalog.focusedWindowID, entry.id)
    }
}
