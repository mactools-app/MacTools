import AppKit
import ApplicationServices
import XCTest
@testable import WindowSwitcherPlugin

private final class CatalogAXAccess: WindowSwitcherAXAccess, @unchecked Sendable {
    struct State {
        var number: CGWindowID?
        var focused = false
        var exposesWindowNumber = true
        var exposesSecondaryWindowNumber = true
        var includesSecondaryWindow = true
        var focusesSecondaryWindow = false
        var secondaryWindowIsSmall = false
        var secondaryWindowIsFloating = false
        var secondaryMetadataUnavailable = false
        var windowListUnavailable = false
        var beforeRead: (() -> Void)?
        var reads = 0
        var actions: [String] = []
    }
    private let lock = NSLock()
    private var state: State
    private let window: AXUIElement
    private let replacement: AXUIElement?
    private let replacementNumber: CGWindowID?
    private let emptyDialog: AXUIElement?
    private let emptyDialogNumber: CGWindowID?
    private let secondaryWindow: AXUIElement?
    private let secondaryWindowNumber: CGWindowID?
    let observesSystemNotifications = false

    init(number: CGWindowID?, elementPID: pid_t, replacementNumber: CGWindowID? = nil,
         emptyDialogNumber: CGWindowID? = nil, secondaryWindowNumber: CGWindowID? = nil) {
        state = State(number: number)
        window = AXUIElementCreateApplication(elementPID)
        self.replacementNumber = replacementNumber
        replacement = replacementNumber.map { _ in AXUIElementCreateApplication(elementPID + 100) }
        self.emptyDialogNumber = emptyDialogNumber
        emptyDialog = emptyDialogNumber.map { _ in AXUIElementCreateApplication(elementPID + 200) }
        self.secondaryWindowNumber = secondaryWindowNumber
        secondaryWindow = secondaryWindowNumber.map { _ in AXUIElementCreateApplication(elementPID + 300) }
    }
    func update(_ body: (inout State) -> Void) { lock.lock(); defer { lock.unlock() }; body(&state) }
    func read<T>(_ body: (State) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(state) }
    func windows(of application: AXUIElement) -> [AXUIElement]? {
        update { $0.reads += 1 }
        read { $0.beforeRead }?()
        return read { state in
            guard !state.windowListUnavailable else { return nil }
            let main = state.number.map { $0 == replacementNumber ? replacement ?? window : window }
            let other = state.includesSecondaryWindow && state.number != secondaryWindowNumber ? secondaryWindow : nil
            return [main, emptyDialog, other].compactMap { $0 }
        }
    }
    func element(_ owner: AXUIElement, attribute: String) -> AXUIElement? {
        if attribute == kAXFocusedWindowAttribute {
            return read { state in
                if state.focusesSecondaryWindow { return secondaryWindow }
                return state.focused ? window : nil
            }
        }
        return attribute == kAXCloseButtonAttribute ? owner : nil
    }
    func windowAttributes(_ window: AXUIElement) -> [Any]? {
        let isDialog = emptyDialog.map { CFEqual($0, window) } == true
        let isSecondary = secondaryWindow.map { CFEqual($0, window) } == true
        if isSecondary, read({ $0.secondaryMetadataUnavailable }) { return nil }
        var point = CGPoint(x: 20, y: 20)
        if isDialog { point = CGPoint(x: 30, y: 30) }
        if isSecondary { point = CGPoint(x: 60, y: 60) }
        var size = isDialog ? CGSize(width: 400, height: 300) : CGSize(width: 800, height: 600)
        if isSecondary, read({ $0.secondaryWindowIsSmall }) { size = CGSize(width: 40, height: 30) }
        let subrole = isDialog ? kAXDialogSubrole
            : isSecondary && read({ $0.secondaryWindowIsFloating }) ? "AXFloatingWindow" : kAXStandardWindowSubrole
        return [kAXWindowRole, subrole, isDialog ? "" : "Fixture", false,
                AXValueCreate(.cgPoint, &point)!, AXValueCreate(.cgSize, &size)!]
    }
    func windowNumber(_ window: AXUIElement) -> CGWindowID? {
        if emptyDialog.map({ CFEqual($0, window) }) == true { return emptyDialogNumber }
        if secondaryWindow.map({ CFEqual($0, window) }) == true {
            return read { $0.exposesSecondaryWindowNumber ? secondaryWindowNumber : nil }
        }
        return read { $0.exposesWindowNumber ? $0.number : nil }
    }
    func boolValue(_ window: AXUIElement, attribute: String) -> Bool? {
        emptyDialog.map { CFEqual($0, window) } == true ? false : nil
    }
    func childCount(_ window: AXUIElement) -> Int? { emptyDialog.map { CFEqual($0, window) } == true ? 0 : nil }
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

    func testColdLaunchRecapturesWindowServerWhenNeitherSourceHasAWindowYet() async throws {
        try await verifyRetryUsesNewVisibility(initialRecords: [])
    }

    func testRetryReplacesSplashVisibilityBeforeInferringFocus() async throws {
        let splash = WindowSwitcherWindowRecord(windowNumber: 9, processIdentifier: 43, title: "",
            isOnScreen: true, bounds: CGRect(x: 20, y: 20, width: 800, height: 600), titleIsAvailable: false)
        try await verifyRetryUsesNewVisibility(initialRecords: [splash])
    }

    private func verifyRetryUsesNewVisibility(initialRecords: [WindowSwitcherWindowRecord]) async throws {
        let previous = CatalogAXAccess(number: 7, elementPID: 201)
        previous.update { $0.focused = true }
        let launched = CatalogAXAccess(number: nil, elementPID: 202)
        let emptyCaptures = DispatchSemaphore(value: 2)
        defer { emptyCaptures.signal(); emptyCaptures.signal() }
        let record = WindowSwitcherWindowRecord(windowNumber: 8, processIdentifier: 43, title: "Launched",
            isOnScreen: true, bounds: CGRect(x: 20, y: 20, width: 800, height: 600))
        let retryCaptureStarted = DispatchSemaphore(value: 0)
        let finishRetryCapture = DispatchSemaphore(value: 0)
        defer { finishRetryCapture.signal() }
        var foregroundPID: pid_t = 42
        let catalog = WindowSwitcherAppCatalog(notificationCenter: NotificationCenter(),
            accessFactory: { $0 == 42 ? previous : launched },
            allSpacesCatalog: .init(windowRecordProvider: {
                if emptyCaptures.wait(timeout: .now()) == .success { return initialRecords }
                retryCaptureStarted.signal()
                _ = finishRetryCapture.wait(timeout: .now() + 1)
                launched.update { $0.number = 8; $0.focused = initialRecords.isEmpty }
                return [record]
            }), discovery: .init(applications: {
                let prior = WindowSwitcherAppCatalog.Application(
                    processIdentifier: 42, bundleIdentifier: "previous", localizedName: "Previous")
                let new = WindowSwitcherAppCatalog.Application(
                    processIdentifier: 43, bundleIdentifier: "launched", localizedName: "Launched",
                    isFinishedLaunching: false)
                return foregroundPID == 43 ? [prior, new] : [prior]
            }, foregroundProcessIdentifier: { foregroundPID }, isAccessibilityTrusted: { true }, isDragging: { false }))
        defer { catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }

        foregroundPID = 43
        catalog.prepareForInvocation()
        try await waitUntil { retryCaptureStarted.wait(timeout: .now()) == .success }
        XCTAssertEqual(launched.read { $0.reads }, 1)
        finishRetryCapture.signal()
        try await waitUntil { catalog.isInvocationReady }
        let entries = catalog.entries(sortMode: .recentUse)
        XCTAssertEqual(entries.compactMap(\.windowNumber), [8, 7])
        XCTAssertEqual(catalog.focusedWindowID, entries.first?.id)
        XCTAssertEqual(launched.read { $0.reads }, 2)
    }

    func testSingleForegroundAXWindowWithoutNumberDoesNotNeedAnExtraScan() async throws {
        let previous = CatalogAXAccess(number: 7, elementPID: 201)
        previous.update { $0.focused = true }
        let launched = CatalogAXAccess(number: 8, elementPID: 202)
        launched.update { $0.exposesWindowNumber = false }
        var foregroundPID: pid_t = 42
        let catalog = WindowSwitcherAppCatalog(notificationCenter: NotificationCenter(),
            accessFactory: { $0 == 42 ? previous : launched },
            allSpacesCatalog: .init(windowRecordProvider: {
                [.init(windowNumber: 8, processIdentifier: 43, title: "Foreground", isOnScreen: true,
                       bounds: CGRect(x: 20, y: 20, width: 800, height: 600))]
            }), discovery: .init(applications: {
                let previous = WindowSwitcherAppCatalog.Application(
                    processIdentifier: 42, bundleIdentifier: "previous", localizedName: "Previous")
                let new = WindowSwitcherAppCatalog.Application(
                    processIdentifier: 43, bundleIdentifier: "foreground", localizedName: "Foreground")
                return foregroundPID == 43 ? [previous, new] : [previous]
            }, foregroundProcessIdentifier: { foregroundPID }, isAccessibilityTrusted: { true }, isDragging: { false }))
        defer { catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }

        foregroundPID = 43
        for reportedFocus in [false, true] {
            let readsBeforeInvocation = launched.read { $0.reads }
            launched.update { $0.focused = reportedFocus }
            catalog.prepareForInvocation()
            try await waitUntil { catalog.isInvocationReady }
            let entries = catalog.entries(sortMode: .recentUse)
            XCTAssertEqual(entries.map(\.processIdentifier), [43, 42])
            XCTAssertEqual(catalog.focusedWindowID, entries.first?.id)
            XCTAssertNil(entries.first?.windowNumber)
            XCTAssertEqual(launched.read { $0.reads }, readsBeforeInvocation + 1)
        }
    }

    func testVisibilityCountsNumberedAndUnnumberedOnscreenRowsAsSeparateCandidates() async throws {
        try await verifyTwoAXWindows(secondaryOnscreen: true, secondaryNumbered: true)
    }

    func testVisibilityCanIdentifyTheOnlyOnscreenUnnumberedAXWindow() async throws {
        try await verifyTwoAXWindows(secondaryOnscreen: false, secondaryNumbered: false)
    }

    private func verifyTwoAXWindows(secondaryOnscreen: Bool, secondaryNumbered: Bool) async throws {
        let previous = CatalogAXAccess(number: 7, elementPID: 201)
        previous.update { $0.focused = true }
        let launched = CatalogAXAccess(number: 8, elementPID: 202, secondaryWindowNumber: 9)
        launched.update {
            $0.exposesWindowNumber = false
            $0.exposesSecondaryWindowNumber = secondaryNumbered
        }
        var foregroundPID: pid_t = 42
        let catalog = WindowSwitcherAppCatalog(notificationCenter: NotificationCenter(),
            accessFactory: { $0 == 42 ? previous : launched },
            allSpacesCatalog: .init(windowRecordProvider: {
                [
                    .init(windowNumber: 8, processIdentifier: 43, title: "First", isOnScreen: true,
                          bounds: CGRect(x: 20, y: 20, width: 800, height: 600)),
                    .init(windowNumber: 9, processIdentifier: 43, title: "Second", isOnScreen: secondaryOnscreen,
                          bounds: CGRect(x: 60, y: 60, width: 800, height: 600), hasSpace: true,
                          isOnActiveSpace: secondaryOnscreen),
                ]
            }), discovery: .init(applications: {
                let prior = WindowSwitcherAppCatalog.Application(
                    processIdentifier: 42, bundleIdentifier: "previous", localizedName: "Previous")
                return foregroundPID == 43
                    ? [prior, .init(processIdentifier: 43, bundleIdentifier: "foreground", localizedName: "Foreground")]
                    : [prior]
            }, foregroundProcessIdentifier: { foregroundPID }, isAccessibilityTrusted: { true }, isDragging: { false }))
        defer { catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }

        foregroundPID = 43
        catalog.prepareForInvocation()
        try await waitUntil { catalog.isInvocationReady }
        let entries = catalog.entries(sortMode: .recentUse)
        if secondaryOnscreen {
            XCTAssertNil(catalog.focusedWindowID)
            XCTAssertEqual(entries.first?.windowNumber, 7)
        } else {
            XCTAssertEqual(catalog.focusedWindowID, entries.first?.id)
            XCTAssertEqual(entries.first?.processIdentifier, 43)
            XCTAssertEqual(entries.first?.bounds.origin, CGPoint(x: 20, y: 20))
            XCTAssertNil(entries.first?.windowNumber)
        }
    }

    func testInvocationReconcilesForegroundAppThatJoinsInventoryAfterPreparation() async throws {
        try await verifyLateForegroundEligibility(startsAsAccessory: false)
    }

    func testInvocationReconcilesAccessoryAppThatBecomesRegularDuringLaunch() async throws {
        try await verifyLateForegroundEligibility(startsAsAccessory: true)
    }

    private func verifyLateForegroundEligibility(startsAsAccessory: Bool) async throws {
        let previous = CatalogAXAccess(number: 7, elementPID: 201)
        previous.update { $0.focused = true }
        let launched = CatalogAXAccess(number: 8, elementPID: 202)
        launched.update { $0.focused = true }
        var foregroundPID: pid_t = 42
        var isRegular = false
        let catalog = WindowSwitcherAppCatalog(notificationCenter: NotificationCenter(),
            accessFactory: { $0 == 42 ? previous : launched }, allSpacesCatalog: .init(windowRecordProvider: { [] }),
            discovery: .init(applications: {
                let previous = WindowSwitcherAppCatalog.Application(
                    processIdentifier: 42, bundleIdentifier: "previous", localizedName: "Previous")
                let new = WindowSwitcherAppCatalog.Application(
                    processIdentifier: 43, bundleIdentifier: "launched", localizedName: "Launched", isRegular: isRegular)
                return isRegular || startsAsAccessory ? [previous, new] : [previous]
            }, foregroundProcessIdentifier: { foregroundPID }, isAccessibilityTrusted: { true }, isDragging: { false }))
        defer { catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }
        XCTAssertNotNil(catalog.focusedWindowID)

        foregroundPID = 43
        catalog.prepareForInvocation()
        isRegular = true
        try await waitUntil { catalog.isInvocationReady }
        let entries = catalog.entries(sortMode: .recentUse)
        XCTAssertEqual(entries.compactMap(\.windowNumber), [8, 7])
        XCTAssertEqual(catalog.focusedWindowID, entries.first?.id)
        XCTAssertEqual(launched.read { $0.reads }, 1)
    }

    func testUnnumberedAXWindowWithAmbiguousBoundsCannotBecomeAnchor() async throws {
        let previous = CatalogAXAccess(number: 7, elementPID: 201)
        previous.update { $0.focused = true }
        let restoring = CatalogAXAccess(number: 8, elementPID: 202)
        restoring.update { $0.exposesWindowNumber = false }
        let bounds = CGRect(x: 20, y: 20, width: 800, height: 600)
        var foregroundPID: pid_t = 42
        let catalog = WindowSwitcherAppCatalog(notificationCenter: NotificationCenter(),
            accessFactory: { $0 == 42 ? previous : restoring },
            allSpacesCatalog: .init(windowRecordProvider: {
                [
                    .init(windowNumber: 8, processIdentifier: 43, title: "Restoring", isOnScreen: false,
                          bounds: bounds, hasSpace: true, isOnActiveSpace: false),
                    .init(windowNumber: 9, processIdentifier: 43, title: "Foreground", isOnScreen: true,
                          bounds: bounds, hasSpace: true, isOnActiveSpace: true),
                ]
            }), discovery: .init(applications: {
                let previous = WindowSwitcherAppCatalog.Application(
                    processIdentifier: 42, bundleIdentifier: "previous", localizedName: "Previous")
                let new = WindowSwitcherAppCatalog.Application(
                    processIdentifier: 43, bundleIdentifier: "foreground", localizedName: "Foreground")
                return foregroundPID == 43 ? [previous, new] : [previous]
            }, foregroundProcessIdentifier: { foregroundPID }, isAccessibilityTrusted: { true }, isDragging: { false }))
        defer { catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }

        foregroundPID = 43
        catalog.prepareForInvocation()
        try await waitUntil { catalog.isInvocationReady }
        XCTAssertEqual(catalog.entries(sortMode: .recentUse).first?.windowNumber, 7)
        XCTAssertNil(catalog.focusedWindowID)
        XCTAssertEqual(restoring.read { $0.reads }, 2)
    }

    func testBackgroundExactFocusIgnoresVisibilityAwaitingReplacement() async throws {
        try await verifyBackgroundExactFocus(refreshesVisibility: true)
    }

    func testBackgroundFocusOnlyEventIgnoresStaleVisibility() async throws {
        try await verifyBackgroundExactFocus(refreshesVisibility: false)
    }

    func testFollowupAXRefreshKeepsFocusNewerThanVisibility() async throws {
        try await verifyBackgroundExactFocus(refreshesVisibility: false, followsUpWithoutVisibility: true)
    }

    private func verifyBackgroundExactFocus(refreshesVisibility: Bool, followsUpWithoutVisibility: Bool = false) async throws {
        let foreground = CatalogAXAccess(number: 9, elementPID: 201,
                                        secondaryWindowNumber: followsUpWithoutVisibility ? 10 : nil)
        foreground.update {
            $0.focused = true
            $0.includesSecondaryWindow = false
        }
        let initialCapture = DispatchSemaphore(value: 1)
        let releaseCapture = DispatchSemaphore(value: 0)
        let bounds = CGRect(x: 20, y: 20, width: 800, height: 600)
        let catalog = WindowSwitcherAppCatalog(notificationCenter: NotificationCenter(),
            accessFactory: { _ in foreground },
            allSpacesCatalog: .init(windowRecordProvider: {
                let initial = initialCapture.wait(timeout: .now()) == .success
                if !initial { _ = releaseCapture.wait(timeout: .now() + 2) }
                let current: CGWindowID = initial ? 9 : 8
                return [8, 9].map { number in
                    .init(windowNumber: number, processIdentifier: 42, title: "Window", isOnScreen: number == current,
                          bounds: bounds, hasSpace: true, isOnActiveSpace: number == current)
                }
            }), discovery: .init(applications: {
                [.init(processIdentifier: 42, bundleIdentifier: "foreground", localizedName: "Foreground")]
            }, foregroundProcessIdentifier: { 42 }, isAccessibilityTrusted: { true }, isDragging: { false }))
        defer { initialCapture.signal(); releaseCapture.signal(); catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }

        foreground.update { $0.number = 8 }
        if refreshesVisibility {
            catalog.refresh()
        } else {
            catalog.invalidate(processIdentifiers: [42], windowRecords: false, focusChanged: true)
        }
        try await waitUntil {
            catalog.entries(sortMode: .fixed).contains { $0.windowNumber == 8 && $0.windowElement != nil }
        }
        let focused = catalog.entries(sortMode: .recentUse).first { $0.id == catalog.focusedWindowID }
        XCTAssertEqual(focused?.windowNumber, 8)

        if followsUpWithoutVisibility {
            foreground.update { $0.includesSecondaryWindow = true }
            catalog.invalidate(processIdentifiers: [42], windowRecords: false)
            try await waitUntil {
                catalog.entries(sortMode: .fixed).contains { $0.windowNumber == 10 && $0.windowElement != nil }
            }
            XCTAssertEqual(catalog.focusedWindowID, focused?.id)
        }
    }

    func testExcludedOnscreenDialogDoesNotPreventInferringTheForegroundWindow() async throws {
        try await verifyExcludedOnscreenSurface(floating: false)
    }

    func testExcludedFloatingPanelCannotBecomeInferredFocus() async throws {
        try await verifyExcludedOnscreenSurface(floating: true)
    }

    private func verifyExcludedOnscreenSurface(floating: Bool) async throws {
        let previous = CatalogAXAccess(number: 7, elementPID: 201)
        previous.update { $0.focused = true }
        let foreground = CatalogAXAccess(number: 8, elementPID: 202, emptyDialogNumber: floating ? nil : 9,
                                         secondaryWindowNumber: floating ? 9 : nil)
        foreground.update { $0.secondaryWindowIsFloating = floating }
        var foregroundPID: pid_t = 42
        let catalog = WindowSwitcherAppCatalog(notificationCenter: NotificationCenter(),
            accessFactory: { $0 == 42 ? previous : foreground },
            allSpacesCatalog: .init(windowRecordProvider: {
                [.init(windowNumber: 8, processIdentifier: 43, title: "Foreground", isOnScreen: !floating,
                       bounds: CGRect(x: 20, y: 20, width: 800, height: 600), hasSpace: true, isOnActiveSpace: !floating),
                 .init(windowNumber: 9, processIdentifier: 43, title: floating ? "Tools" : "", isOnScreen: true,
                       bounds: floating ? CGRect(x: 60, y: 60, width: 800, height: 600)
                           : CGRect(x: 30, y: 30, width: 400, height: 300))]
            }), discovery: .init(applications: {
                let prior = WindowSwitcherAppCatalog.Application(
                    processIdentifier: 42, bundleIdentifier: "previous", localizedName: "Previous")
                let new = WindowSwitcherAppCatalog.Application(
                    processIdentifier: 43, bundleIdentifier: "foreground", localizedName: "Foreground")
                return foregroundPID == 43 ? [prior, new] : [prior]
            }, foregroundProcessIdentifier: { foregroundPID }, isAccessibilityTrusted: { true }, isDragging: { false }))
        defer { catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }

        foregroundPID = 43
        catalog.prepareForInvocation()
        try await waitUntil { catalog.isInvocationReady }
        let entries = catalog.entries(sortMode: .recentUse)
        if floating {
            XCTAssertEqual(entries.first?.windowNumber, 7)
            XCTAssertNil(catalog.focusedWindowID)
        } else {
            XCTAssertEqual(entries.compactMap(\.windowNumber), [8, 7])
            XCTAssertEqual(catalog.focusedWindowID, entries.first?.id)
        }
        XCTAssertEqual(foreground.read { $0.reads }, 1)
    }

    func testMissingSplashInFreshVisibilityRetriesBeforeRecordingRecentUse() async throws {
        try await verifyLaunchFocusRecovery(partialAX: false, failsRetryCapture: false, omitsSplash: true)
    }

    func testForeignWindowServerOwnerCannotConfirmLaunchFocus() async throws {
        try await verifyLaunchFocusRecovery(partialAX: false, failsRetryCapture: false, splashHasForeignOwner: true)
    }

    func testOffscreenReportedFocusRetriesBeforeRecordingRecentUse() async throws {
        try await verifyLaunchFocusRecovery(partialAX: false, failsRetryCapture: false)
    }

    func testPartiallyReadableForegroundAXRetriesBeforeRelyingOnCGFallback() async throws {
        try await verifyLaunchFocusRecovery(partialAX: true, failsRetryCapture: false)
    }

    func testFailedRetryCaptureDoesNotConfirmRepeatedOffscreenAXFocus() async throws {
        try await verifyLaunchFocusRecovery(partialAX: false, failsRetryCapture: true)
    }

    func testReportedLaunchFocusRetriesWhenVisibilityOnlyShowsAnOlderListedWindow() async throws {
        let splash = WindowSwitcherWindowRecord(windowNumber: 8, processIdentifier: 43, title: "Splash",
            isOnScreen: true, bounds: CGRect(x: 20, y: 20, width: 800, height: 600))
        try await verifyLaunchWindowRetry(records: [splash])
    }

    func testIncompleteLaunchAXRetriesWhenVisibilityOnlyShowsAnOlderListedWindow() async throws {
        let splash = WindowSwitcherWindowRecord(windowNumber: 8, processIdentifier: 43, title: "Splash",
            isOnScreen: true, bounds: CGRect(x: 20, y: 20, width: 800, height: 600))
        try await verifyLaunchWindowRetry(records: [splash], partialInitialAXRead: true)
    }

    func testReportedLaunchFocusRetriesWhenVisibilityCaptureFails() async throws {
        try await verifyLaunchWindowRetry(records: nil)
    }

    func testLaunchRetriesWhenBothInitialWindowSourcesFail() async throws {
        try await verifyLaunchWindowRetry(records: nil, failsInitialAXRead: true)
    }

    func testLaunchRetriesWhenAccessibilityListsTwoWindowsWithoutFocus() async throws {
        let records: [WindowSwitcherWindowRecord] = [
            .init(windowNumber: 8, processIdentifier: 43, title: "Primary",
                  isOnScreen: true, bounds: CGRect(x: 20, y: 20, width: 800, height: 600)),
            .init(windowNumber: 9, processIdentifier: 43, title: "Document",
                  isOnScreen: true, bounds: CGRect(x: 60, y: 60, width: 800, height: 600)),
        ]
        try await verifyLaunchWindowRetry(records: records, waitsForFocus: true)
    }

    func testLaunchRetriesWhenVisibilityFailsAndAccessibilityReturnsAnEmptyList() async throws {
        try await verifyLaunchWindowRetry(records: nil, initiallyEmpty: true)
    }

    func testLaunchFocusOnAnAlreadyExcludedWindowDoesNotRetry() async throws {
        let primary = WindowSwitcherWindowRecord(windowNumber: 8, processIdentifier: 43, title: "Primary",
            isOnScreen: true, bounds: CGRect(x: 20, y: 20, width: 800, height: 600))
        try await verifyLaunchWindowRetry(records: [primary], secondaryWindowIsSmall: true)
    }

    func testUncorroboratedLaunchSplashStillAllowsTheRetry() async throws {
        try await verifyLaunchFocusAppearingAfterRetryCapture(.inferredSplash)
    }

    func testOffSpaceLaunchFocusDoesNotEnterHistoryBeforeRetry() async throws {
        try await verifyLaunchFocusAppearingAfterRetryCapture(.offSpaceRestoration)
    }

    func testOffSpaceFocusReportedOnRetryDoesNotEnterLaunchHistory() async throws {
        try await verifyLaunchFocusAppearingAfterRetryCapture(.offSpaceFocusOnRetry)
    }

    func testUnnumberedSplashDoesNotDisplaceAnAXBackedLaunchDocument() async throws {
        try await verifyLaunchFocusAppearingAfterRetryCapture(.unnumberedSplash)
    }

    private enum LaunchFocusFixture {
        case inferredSplash, offSpaceRestoration, offSpaceFocusOnRetry, unnumberedSplash
    }

    private func verifyLaunchFocusAppearingAfterRetryCapture(_ fixture: LaunchFocusFixture) async throws {
        let previous = CatalogAXAccess(number: 7, elementPID: 201)
        previous.update { $0.focused = true }
        let launched = CatalogAXAccess(number: 8, elementPID: 202, replacementNumber: 9, secondaryWindowNumber: 9)
        launched.update {
            $0.focused = fixture == .offSpaceRestoration || fixture == .unnumberedSplash
            $0.exposesWindowNumber = fixture != .unnumberedSplash
            $0.includesSecondaryWindow = fixture == .unnumberedSplash
        }
        let initialCaptures = DispatchSemaphore(value: 2)
        defer { initialCaptures.signal(); initialCaptures.signal() }
        var foregroundPID: pid_t = 42
        let catalog = WindowSwitcherAppCatalog(notificationCenter: NotificationCenter(),
            accessFactory: { $0 == 42 ? previous : launched },
            allSpacesCatalog: .init(windowRecordProvider: {
                let restored = WindowSwitcherWindowRecord(windowNumber: 8, processIdentifier: 43, title: "Restored elsewhere",
                    isOnScreen: false, bounds: CGRect(x: 20, y: 20, width: 800, height: 600),
                    hasSpace: true, isOnActiveSpace: false)
                let origin = fixture == .inferredSplash ? CGPoint(x: 20, y: 20) : CGPoint(x: 60, y: 60)
                let document = WindowSwitcherWindowRecord(windowNumber: 9, processIdentifier: 43, title: "Actual window",
                    isOnScreen: true, bounds: CGRect(origin: origin, size: CGSize(width: 800, height: 600)))
                let restoredWindows = fixture == .offSpaceRestoration || fixture == .offSpaceFocusOnRetry ? [restored] : []
                if initialCaptures.wait(timeout: .now()) == .success {
                    return fixture == .unnumberedSplash ? [document] : restoredWindows
                }
                if fixture == .offSpaceFocusOnRetry {
                    launched.update { $0.focused = true }
                    return restoredWindows
                }
                launched.update {
                    if fixture == .inferredSplash {
                        $0.number = 9
                    } else {
                        $0.includesSecondaryWindow = true
                        $0.focusesSecondaryWindow = true
                    }
                }
                return restoredWindows + [document]
            }), discovery: .init(applications: {
                let prior = WindowSwitcherAppCatalog.Application(processIdentifier: 42, localizedName: "Previous")
                guard foregroundPID == 43 else { return [prior] }
                return [prior, .init(processIdentifier: 43, localizedName: "Launched", isFinishedLaunching: false)]
            }, foregroundProcessIdentifier: { foregroundPID }, isAccessibilityTrusted: { true }, isDragging: { false }))
        defer { catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }

        foregroundPID = 43
        catalog.prepareForInvocation()
        try await waitUntil { catalog.isInvocationReady }
        let entries = catalog.entries(sortMode: .recentUse)
        if fixture == .offSpaceFocusOnRetry {
            XCTAssertEqual(entries.compactMap(\.windowNumber), [7, 8])
            XCTAssertNil(catalog.focusedWindowID)
        } else {
            XCTAssertEqual(entries.compactMap(\.windowNumber), fixture == .offSpaceRestoration ? [9, 7, 8] : [9, 7])
            XCTAssertEqual(catalog.focusedWindowID, entries.first?.id)
        }
        XCTAssertEqual(launched.read { $0.reads }, 2)
    }

    private func verifyLaunchWindowRetry(records: [WindowSwitcherWindowRecord]?,
                                         secondaryWindowIsSmall: Bool = false,
                                         failsInitialAXRead: Bool = false,
                                         partialInitialAXRead: Bool = false, waitsForFocus: Bool = false,
                                         initiallyEmpty: Bool = false) async throws {
        let previous = CatalogAXAccess(number: 7, elementPID: 201)
        previous.update { $0.focused = true }
        let launched = CatalogAXAccess(number: initiallyEmpty ? nil : 8, elementPID: 202, secondaryWindowNumber: 9)
        launched.update {
            $0.includesSecondaryWindow = secondaryWindowIsSmall || partialInitialAXRead || waitsForFocus
            $0.focusesSecondaryWindow = !partialInitialAXRead && !waitsForFocus && !initiallyEmpty
            $0.secondaryWindowIsSmall = secondaryWindowIsSmall
            $0.secondaryMetadataUnavailable = partialInitialAXRead
            $0.windowListUnavailable = failsInitialAXRead
            $0.beforeRead = { [weak launched] in
                launched?.update { state in
                    if state.reads == 2 {
                        state.number = 8
                        state.windowListUnavailable = false
                        state.includesSecondaryWindow = true
                        state.secondaryMetadataUnavailable = false
                        state.focusesSecondaryWindow = true
                    }
                }
            }
        }
        var foregroundPID: pid_t = 42
        let catalog = WindowSwitcherAppCatalog(notificationCenter: NotificationCenter(),
            accessFactory: { $0 == 42 ? previous : launched },
            allSpacesCatalog: .init(windowRecordProvider: { records }), discovery: .init(applications: {
                let prior = WindowSwitcherAppCatalog.Application(
                    processIdentifier: 42, bundleIdentifier: "previous", localizedName: "Previous")
                let new = WindowSwitcherAppCatalog.Application(
                    processIdentifier: 43, bundleIdentifier: "launched", localizedName: "Launched",
                    isFinishedLaunching: false)
                return foregroundPID == 43 ? [prior, new] : [prior]
            }, foregroundProcessIdentifier: { foregroundPID }, isAccessibilityTrusted: { true }, isDragging: { false }))
        defer { catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }

        foregroundPID = 43
        catalog.prepareForInvocation()
        try await waitUntil { catalog.isInvocationReady }
        let entries = catalog.entries(sortMode: .recentUse)
        if secondaryWindowIsSmall {
            XCTAssertEqual(entries.compactMap(\.windowNumber), [7, 8])
            XCTAssertNil(catalog.focusedWindowID)
            XCTAssertEqual(launched.read { $0.reads }, 1)
        } else {
            XCTAssertEqual(entries.compactMap(\.windowNumber), [9, 7, 8])
            XCTAssertEqual(catalog.focusedWindowID, entries.first?.id)
            XCTAssertEqual(launched.read { $0.reads }, 2)
        }
    }

    private func verifyLaunchFocusRecovery(partialAX: Bool, failsRetryCapture: Bool, omitsSplash: Bool = false,
                                           splashHasForeignOwner: Bool = false) async throws {
        let previous = CatalogAXAccess(number: 7, elementPID: 201)
        previous.update { $0.focused = true }
        let launched = CatalogAXAccess(number: 8, elementPID: 202, secondaryWindowNumber: partialAX ? 9 : nil)
        let initialCaptures = DispatchSemaphore(value: 2)
        defer { initialCaptures.signal(); initialCaptures.signal() }
        launched.update {
            $0.focused = !partialAX
            $0.secondaryMetadataUnavailable = partialAX
            $0.beforeRead = { [weak launched] in
                launched?.update { state in
                    guard state.reads == 2, !failsRetryCapture else { return }
                    state.number = 9
                    state.focused = true
                }
            }
        }
        var foregroundPID: pid_t = 42
        let catalog = WindowSwitcherAppCatalog(notificationCenter: NotificationCenter(),
            accessFactory: { $0 == 42 ? previous : launched },
            allSpacesCatalog: .init(windowRecordProvider: {
                if initialCaptures.wait(timeout: .now()) != .success, failsRetryCapture { return nil }
                let splash = WindowSwitcherWindowRecord(windowNumber: 8,
                    processIdentifier: splashHasForeignOwner ? 44 : 43, title: "Restoring",
                    isOnScreen: splashHasForeignOwner, bounds: CGRect(x: 20, y: 20, width: 800, height: 600),
                    hasSpace: true, isOnActiveSpace: splashHasForeignOwner)
                let document = WindowSwitcherWindowRecord(windowNumber: 9, processIdentifier: 43, title: "Launched",
                    isOnScreen: true, bounds: CGRect(x: 40, y: 40, width: 800, height: 600))
                return omitsSplash ? [document] : [splash, document]
            }),
            discovery: .init(applications: {
                let prior = WindowSwitcherAppCatalog.Application(
                    processIdentifier: 42, bundleIdentifier: "previous", localizedName: "Previous")
                let new = WindowSwitcherAppCatalog.Application(
                    processIdentifier: 43, bundleIdentifier: "launched", localizedName: "Launched",
                    isFinishedLaunching: !omitsSplash && !splashHasForeignOwner)
                return foregroundPID == 43 ? [prior, new] : [prior]
            }, foregroundProcessIdentifier: { foregroundPID }, isAccessibilityTrusted: { true }, isDragging: { false }))
        defer { catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }

        foregroundPID = 43
        catalog.prepareForInvocation()
        try await waitUntil { catalog.isInvocationReady }
        XCTAssertEqual(launched.read { $0.reads }, 2)
        let entries = catalog.entries(sortMode: .recentUse)
        if failsRetryCapture {
            XCTAssertEqual(entries.first?.windowNumber, 7)
            XCTAssertNil(catalog.focusedWindowID)
        } else {
            XCTAssertEqual(entries.compactMap(\.windowNumber), omitsSplash || splashHasForeignOwner ? [9, 7] : [9, 7, 8])
            XCTAssertEqual(catalog.focusedWindowID, entries.first?.id)
        }
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

    func testVisibilityChangeWithConfirmedFocusRefreshesOtherWindowAfterReadiness() async throws {
        try await verifyVisibilityChangeRefreshesAfterReadiness(hasPriorSnapshot: true)
    }

    func testVisibilityChangeDuringFirstAXReadRefreshesOtherWindowAfterReadiness() async throws {
        try await verifyVisibilityChangeRefreshesAfterReadiness(hasPriorSnapshot: false)
    }

    func testVisibilityChangeDuringCancelledFirstAXReadStillRefreshesOtherWindow() async throws {
        try await verifyVisibilityChangeRefreshesAfterReadiness(hasPriorSnapshot: false, cancelsInvocation: true)
    }

    private func verifyVisibilityChangeRefreshesAfterReadiness(hasPriorSnapshot: Bool,
                                                               cancelsInvocation: Bool = false) async throws {
        let previous = CatalogAXAccess(number: 6, elementPID: 200)
        previous.update { $0.focused = true }
        let app = CatalogAXAccess(number: 7, elementPID: 201, secondaryWindowNumber: 8)
        let firstAXStarted = DispatchSemaphore(value: 0)
        let releaseFirstAX = DispatchSemaphore(value: 0)
        app.update {
            $0.focused = true
            $0.includesSecondaryWindow = false
        }
        let initialCapture = DispatchSemaphore(value: 1)
        let captureStarted = DispatchSemaphore(value: 0)
        let releaseCapture = DispatchSemaphore(value: 0)
        let primary = WindowSwitcherWindowRecord(windowNumber: 7, processIdentifier: 42, title: "Document",
            isOnScreen: true, bounds: CGRect(x: 20, y: 20, width: 800, height: 600))
        let secondary = WindowSwitcherWindowRecord(windowNumber: 8, processIdentifier: 42, title: "", isOnScreen: true,
            bounds: CGRect(x: 60, y: 60, width: 800, height: 600), titleIsAvailable: false)
        let priorBounds = CGRect(x: 100, y: 100, width: 800, height: 600)
        let priorVisible = WindowSwitcherWindowRecord(windowNumber: 6, processIdentifier: 41, title: "Prior",
            isOnScreen: true, bounds: priorBounds)
        let priorOffscreen = WindowSwitcherWindowRecord(windowNumber: 6, processIdentifier: 41, title: "Prior",
            isOnScreen: false, bounds: priorBounds, hasSpace: true, isOnActiveSpace: false)
        var foregroundPID: pid_t = hasPriorSnapshot ? 42 : 41
        let catalog = WindowSwitcherAppCatalog(notificationCenter: NotificationCenter(),
            accessFactory: { $0 == 42 ? app : previous },
            allSpacesCatalog: .init(windowRecordProvider: {
                if initialCapture.wait(timeout: .now()) == .success {
                    return hasPriorSnapshot ? [primary] : [priorVisible]
                }
                captureStarted.signal()
                _ = releaseCapture.wait(timeout: .now() + 1)
                return hasPriorSnapshot ? [primary, secondary] : [priorOffscreen, primary, secondary]
            }), discovery: .init(applications: {
                let host = WindowSwitcherAppCatalog.Application(
                    processIdentifier: 42, bundleIdentifier: "fixture", localizedName: "Fixture")
                if hasPriorSnapshot { return [host] }
                let prior = WindowSwitcherAppCatalog.Application(
                    processIdentifier: 41, bundleIdentifier: "prior", localizedName: "Prior")
                return foregroundPID == 42 ? [prior, host] : [prior]
            }, foregroundProcessIdentifier: { foregroundPID }, isAccessibilityTrusted: { true }, isDragging: { false }))
        defer { initialCapture.signal(); releaseCapture.signal(); releaseFirstAX.signal(); catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }
        // Startup can already have reconciled an AX read with WindowServer.
        let discoveryRead = app.read { $0.reads } + 1
        app.update {
            $0.beforeRead = { [weak app] in
                if !hasPriorSnapshot, app?.read({ $0.reads }) == discoveryRead {
                    firstAXStarted.signal()
                    _ = releaseFirstAX.wait(timeout: .now() + 1)
                }
                app?.update { state in
                    if state.reads > discoveryRead { state.includesSecondaryWindow = true }
                }
            }
        }

        var windowsAtReadiness: [CGWindowID]?
        catalog.onChange = { [weak catalog] in
            guard let catalog, catalog.isInvocationReady, windowsAtReadiness == nil else { return }
            windowsAtReadiness = catalog.entries(sortMode: .recentUse).compactMap(\.windowNumber)
        }
        foregroundPID = 42
        catalog.prepareForInvocation()
        try await waitUntil { captureStarted.wait(timeout: .now()) == .success }
        if hasPriorSnapshot {
            try await waitUntil { app.read { $0.reads } == discoveryRead }
        } else {
            try await waitUntil { firstAXStarted.wait(timeout: .now()) == .success }
        }
        if cancelsInvocation { catalog.cancelInvocation() }
        releaseCapture.signal()
        if !hasPriorSnapshot {
            try await waitUntil {
                catalog.entries(sortMode: .fixed).contains { $0.windowNumber == 6 && $0.isOnOtherDesktop }
            }
            releaseFirstAX.signal()
        }

        let expectedAtReadiness: [CGWindowID] = hasPriorSnapshot ? [7] : [7, 6]
        try await waitUntil {
            catalog.entries(sortMode: .recentUse).compactMap(\.windowNumber) == expectedAtReadiness + [8]
        }
        if !cancelsInvocation { XCTAssertEqual(windowsAtReadiness, expectedAtReadiness) }
        XCTAssertEqual(app.read { $0.reads }, discoveryRead + 1)
    }

    func testCancellingInvocationLetsAQueuedVisibilityRefreshRunWhileAXIsPending() async throws {
        let access = CatalogAXAccess(number: 7, elementPID: 201)
        let axStarted = DispatchSemaphore(value: 0)
        let releaseAX = DispatchSemaphore(value: 0)
        let recordsStarted = DispatchSemaphore(value: 0)
        let catalog = WindowSwitcherAppCatalog(notificationCenter: NotificationCenter(),
            accessFactory: { _ in access }, allSpacesCatalog: .init(windowRecordProvider: {
                recordsStarted.signal()
                return []
            }), discovery: .init(applications: {
                [.init(processIdentifier: 42, bundleIdentifier: "fixture", localizedName: "Fixture")]
            }, foregroundProcessIdentifier: { 42 }, isAccessibilityTrusted: { true }, isDragging: { false }))
        defer { releaseAX.signal(); catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }
        try await waitUntil { recordsStarted.wait(timeout: .now()) == .success }

        access.update {
            $0.beforeRead = {
                axStarted.signal()
                _ = releaseAX.wait(timeout: .now() + 5)
            }
        }
        catalog.prepareForInvocation()
        try await waitUntil { axStarted.wait(timeout: .now()) == .success }
        try await waitUntil { recordsStarted.wait(timeout: .now()) == .success }
        XCTAssertFalse(catalog.isInvocationReady)
        catalog.refresh()
        catalog.cancelInvocation()

        try await waitUntil { recordsStarted.wait(timeout: .now()) == .success }
        access.update { $0.beforeRead = nil }
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
            if holdInvocationCapture.wait(timeout: .now()) == .success {
                invocationCaptureStarted.signal()
                _ = releaseInvocationCapture.wait(timeout: .now() + 5)
            } else if launched.read({ $0.reads }) == 0 {
                return []
            }
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
        catalog.refresh()
        try await waitUntil { olderCaptureStarted.wait(timeout: .now()) == .success }

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

    func testForegroundChangeUsesNewFocusBeforeInvocationBecomesReady() async throws {
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
        XCTAssertEqual(entries.first?.windowNumber, 10)
        XCTAssertEqual(catalog.focusedWindowID, entries.first?.id)
        var session = WindowSwitcherSession(entries: entries, selectedID: catalog.focusedWindowID,
            isPersistent: false, originalWindowID: catalog.focusedWindowID)
        session.advance(1)
        XCTAssertEqual(session.selected?.windowNumber, 7)
    }

    func testFocusChangeAfterInitialReadUsesRetryBeforeInvocationBecomesReady() async throws {
        let previous = CatalogAXAccess(number: 7, elementPID: 201)
        previous.update { $0.focused = true }
        let launched = CatalogAXAccess(number: 8, elementPID: 202, secondaryWindowNumber: 9)
        launched.update { $0.focused = true }
        let slow = CatalogAXAccess(number: 10, elementPID: 203)
        let releaseScan = DispatchSemaphore(value: 0)
        var foregroundPID: pid_t = 42
        let catalog = WindowSwitcherAppCatalog(notificationCenter: NotificationCenter(),
            accessFactory: { pid in
                switch pid {
                case 42: previous
                case 43: launched
                default: slow
                }
            }, allSpacesCatalog: .init(windowRecordProvider: {
                [.init(windowNumber: 8, processIdentifier: 43, title: "First", isOnScreen: true,
                       bounds: CGRect(x: 20, y: 20, width: 800, height: 600), hasSpace: true, isOnActiveSpace: true),
                 .init(windowNumber: 9, processIdentifier: 43, title: "Second", isOnScreen: true,
                       bounds: CGRect(x: 60, y: 60, width: 800, height: 600), hasSpace: true, isOnActiveSpace: true)]
            }), discovery: .init(applications: {
                let previous = WindowSwitcherAppCatalog.Application(processIdentifier: 42, localizedName: "Previous")
                let other = WindowSwitcherAppCatalog.Application(processIdentifier: 44, localizedName: "Other")
                guard foregroundPID == 43 else { return [previous, other] }
                return [previous, other,
                        .init(processIdentifier: 43, localizedName: "Launched", isFinishedLaunching: false)]
            }, foregroundProcessIdentifier: { foregroundPID }, isAccessibilityTrusted: { true }, isDragging: { false }))
        defer { releaseScan.signal(); catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }

        slow.update { $0.beforeRead = { _ = releaseScan.wait(timeout: .now() + 2) } }
        foregroundPID = 43
        catalog.prepareForInvocation()
        try await waitUntil {
            catalog.entries(sortMode: .recentUse).first { $0.id == catalog.focusedWindowID }?.windowNumber == 8
        }
        XCTAssertFalse(catalog.isInvocationReady)

        launched.update { $0.focusesSecondaryWindow = true }
        catalog.invalidate(processIdentifiers: [43], windowRecords: false, focusChanged: true)
        slow.update { $0.beforeRead = nil }
        releaseScan.signal()
        try await waitUntil { catalog.isInvocationReady }

        let entries = catalog.entries(sortMode: .recentUse)
        XCTAssertEqual(entries.compactMap(\.windowNumber), [9, 8, 7, 10])
        XCTAssertEqual(catalog.focusedWindowID, entries.first?.id)
        XCTAssertEqual(launched.read { $0.reads }, 2)
    }

    func testCancelledInvocationKeepsConfirmedForegroundHistory() async throws {
        let previous = CatalogAXAccess(number: 7, elementPID: 201)
        previous.update { $0.focused = true }
        let launched = CatalogAXAccess(number: 8, elementPID: 202)
        launched.update { $0.focused = true }
        let next = CatalogAXAccess(number: 9, elementPID: 203)
        next.update { $0.focused = true }
        let scanStarted = DispatchSemaphore(value: 0)
        let releaseScan = DispatchSemaphore(value: 0)
        var foregroundPID: pid_t = 42
        var didLaunch = false
        let catalog = WindowSwitcherAppCatalog(notificationCenter: NotificationCenter(),
            accessFactory: { pid in
                switch pid {
                case 42: previous
                case 43: launched
                default: next
                }
            }, allSpacesCatalog: .init(windowRecordProvider: { [] }),
            discovery: .init(applications: {
                let pids: [pid_t] = didLaunch ? [42, 43, 44] : [42, 44]
                return pids.map { .init(processIdentifier: $0, localizedName: "Fixture \($0)") }
            }, foregroundProcessIdentifier: { foregroundPID }, isAccessibilityTrusted: { true }, isDragging: { false }))
        defer { releaseScan.signal(); catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }

        launched.update {
            $0.beforeRead = {
                scanStarted.signal()
                _ = releaseScan.wait(timeout: .now() + 2)
            }
        }
        didLaunch = true
        foregroundPID = 43
        catalog.prepareForInvocation()
        try await waitUntil { scanStarted.wait(timeout: .now()) == .success }
        catalog.cancelInvocation()
        launched.update { $0.beforeRead = nil }
        releaseScan.signal()
        try await waitUntil { catalog.entries(sortMode: .fixed).contains { $0.windowNumber == 8 } }
        XCTAssertEqual(catalog.entries(sortMode: .recentUse).first?.windowNumber, 8)

        foregroundPID = 44
        catalog.prepareForInvocation()
        try await waitUntil { catalog.isInvocationReady }
        let entries = catalog.entries(sortMode: .recentUse)
        XCTAssertEqual(entries.compactMap(\.windowNumber), [9, 8, 7])
        var session = WindowSwitcherSession(entries: entries, selectedID: catalog.focusedWindowID,
            isPersistent: false, originalWindowID: catalog.focusedWindowID)
        session.advance(1)
        XCTAssertEqual(session.selected?.windowNumber, 8)
    }

    func testRoutineRefreshDoesNotRestoreOffscreenFocus() async throws {
        try await verifyFocusAfterQueuedRefresh(cancelsInvocation: false)
    }

    func testCancelledFocusStillUsesItsVisibilityAfterQueuedRefresh() async throws {
        try await verifyFocusAfterQueuedRefresh(cancelsInvocation: true)
    }

    func testCoalescedFocusEventUsesFreshVisibilityFromRoutineRefresh() async throws {
        try await verifyFocusAfterQueuedRefresh(cancelsInvocation: false, coalescesFocusChange: true)
    }

    func testNewVisibilityCanRejectFocusFromCancelledInvocation() async throws {
        try await verifyFocusAfterQueuedRefresh(cancelsInvocation: true, wasOnscreenAtInvocation: true)
    }

    func testCancelledFocusUsesNewerAXEventWhenQueuedVisibilityPredatesIt() async throws {
        try await verifyFocusAfterQueuedRefresh(cancelsInvocation: true, focusChangesAfterQueuedCapture: true)
    }

    private func verifyFocusAfterQueuedRefresh(cancelsInvocation: Bool, coalescesFocusChange: Bool = false,
                                               wasOnscreenAtInvocation: Bool = false,
                                               focusChangesAfterQueuedCapture: Bool = false) async throws {
        let previous = CatalogAXAccess(number: 7, elementPID: 201)
        previous.update { $0.focused = true }
        let launched = CatalogAXAccess(number: 8, elementPID: 202, secondaryWindowNumber: 9)
        launched.update {
            $0.focused = true
            $0.includesSecondaryWindow = false
        }
        let holdCapture = DispatchSemaphore(value: 0)
        let invocationCaptureStarted = DispatchSemaphore(value: 0)
        let releaseCapture = DispatchSemaphore(value: 0)
        let showBackgroundCapture = DispatchSemaphore(value: 0)
        let axStarted = DispatchSemaphore(value: 0)
        let holdFirstAX = DispatchSemaphore(value: 1)
        let releaseAX = DispatchSemaphore(value: 0)
        let releaseFollowupAX = DispatchSemaphore(value: 0)
        let bounds = CGRect(x: 20, y: 20, width: 800, height: 600)
        var foregroundPID: pid_t = 42
        let catalog = WindowSwitcherAppCatalog(notificationCenter: NotificationCenter(),
            accessFactory: { $0 == 42 ? previous : launched },
            allSpacesCatalog: .init(windowRecordProvider: {
                let background = showBackgroundCapture.wait(timeout: .now()) == .success
                if holdCapture.wait(timeout: .now()) == .success {
                    invocationCaptureStarted.signal()
                    _ = releaseCapture.wait(timeout: .now() + 2)
                }
                let reportedWindowIsOnscreen = focusChangesAfterQueuedCapture || (wasOnscreenAtInvocation && !background)
                return [.init(windowNumber: 7, processIdentifier: 42, title: "Previous", isOnScreen: !background,
                              bounds: bounds, hasSpace: true, isOnActiveSpace: !background),
                        .init(windowNumber: 8, processIdentifier: 43, title: "Restoring", isOnScreen: reportedWindowIsOnscreen,
                              bounds: bounds, hasSpace: true, isOnActiveSpace: reportedWindowIsOnscreen),
                        .init(windowNumber: 9, processIdentifier: 43, title: "Launched", isOnScreen: !reportedWindowIsOnscreen,
                              bounds: bounds, hasSpace: true, isOnActiveSpace: !reportedWindowIsOnscreen)]
            }), discovery: .init(applications: {
                let pids: [pid_t] = foregroundPID == 43 ? [42, 43] : [42]
                return pids.map { .init(processIdentifier: $0, localizedName: "Fixture \($0)") }
            }, foregroundProcessIdentifier: { foregroundPID }, isAccessibilityTrusted: { true }, isDragging: { false }))
        defer {
            catalog.stop()
            releaseCapture.signal()
            releaseAX.signal()
            releaseFollowupAX.signal()
            holdFirstAX.signal()
        }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }

        let holdFocusScan = {
            launched.update {
                $0.beforeRead = {
                    if holdFirstAX.wait(timeout: .now()) == .success {
                        axStarted.signal()
                        _ = releaseAX.wait(timeout: .now() + 2)
                    } else {
                        _ = releaseFollowupAX.wait(timeout: .now() + 2)
                    }
                }
            }
        }
        foregroundPID = 43
        if cancelsInvocation {
            holdCapture.signal()
            holdFocusScan()
        }
        catalog.prepareForInvocation()
        if cancelsInvocation {
            try await waitUntil { invocationCaptureStarted.wait(timeout: .now()) == .success }
            try await waitUntil { axStarted.wait(timeout: .now()) == .success }
            showBackgroundCapture.signal()
            catalog.invalidate(processIdentifiers: [], windowRecords: true)
            catalog.cancelInvocation()
            releaseCapture.signal()
        } else {
            try await waitUntil { catalog.isInvocationReady }
            XCTAssertEqual(catalog.entries(sortMode: .recentUse).first?.windowNumber, 7)
            holdFocusScan()
            showBackgroundCapture.signal()
            if coalescesFocusChange {
                catalog.invalidate(processIdentifiers: [43], windowRecords: false, focusChanged: true)
            }
            catalog.refresh()
            try await waitUntil { axStarted.wait(timeout: .now()) == .success }
        }
        try await waitUntil {
            catalog.entries(sortMode: .fixed).contains { $0.windowNumber == 7 && $0.isOnOtherDesktop }
        }
        launched.update {
            $0.includesSecondaryWindow = true
            $0.focusesSecondaryWindow = focusChangesAfterQueuedCapture
        }
        if focusChangesAfterQueuedCapture {
            catalog.invalidate(processIdentifiers: [43], windowRecords: false, focusChanged: true)
        }
        releaseAX.signal()
        try await waitUntil {
            catalog.entries(sortMode: .fixed).contains { $0.windowNumber == 9 && $0.windowElement != nil }
        }
        XCTAssertEqual(catalog.entries(sortMode: .recentUse).first?.windowNumber, focusChangesAfterQueuedCapture ? 9 : 7)
    }

    func testForegroundHandoffWhileWaitingForRetryUsesNewForeground() async throws {
        try await verifyForegroundHandoff(duringRetryCapture: false)
    }

    func testForegroundHandoffDuringRetryCaptureUsesNewForeground() async throws {
        try await verifyForegroundHandoff(duringRetryCapture: true)
    }

    private func verifyForegroundHandoff(duringRetryCapture: Bool) async throws {
        let previous = CatalogAXAccess(number: 7, elementPID: 201)
        previous.update { $0.focused = true }
        let launched = CatalogAXAccess(number: 8, elementPID: 202, secondaryWindowNumber: 11)
        launched.update {
            $0.focusesSecondaryWindow = true
            $0.includesSecondaryWindow = false
        }
        let next = CatalogAXAccess(number: 9, elementPID: 203)
        let releaseLaunchScan = DispatchSemaphore(value: 0)
        let initialCaptures = DispatchSemaphore(value: 2)
        let retryCaptureStarted = DispatchSemaphore(value: 0)
        let releaseCapture = DispatchSemaphore(value: 0)
        var foregroundPID: pid_t = 42
        var didLaunch = false
        let catalog = WindowSwitcherAppCatalog(notificationCenter: NotificationCenter(),
            accessFactory: { pid in
                switch pid {
                case 42: previous
                case 43: launched
                default: next
                }
            }, allSpacesCatalog: .init(windowRecordProvider: {
                if duringRetryCapture, initialCaptures.wait(timeout: .now()) != .success {
                    retryCaptureStarted.signal()
                    _ = releaseCapture.wait(timeout: .now() + 2)
                }
                return []
            }),
            discovery: .init(applications: {
                let pids: [pid_t] = didLaunch ? [42, 43, 44] : [42, 44]
                return pids.map {
                    .init(processIdentifier: $0, localizedName: "Fixture \($0)", isFinishedLaunching: $0 != 43)
                }
            }, foregroundProcessIdentifier: { foregroundPID }, isAccessibilityTrusted: { true }, isDragging: { false }))
        defer {
            catalog.stop()
            releaseLaunchScan.signal()
            initialCaptures.signal()
            initialCaptures.signal()
            releaseCapture.signal()
        }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }
        let initialReads = next.read { $0.reads }

        launched.update { $0.beforeRead = { _ = releaseLaunchScan.wait(timeout: .now() + 2) } }
        next.update { $0.number = 10 }
        catalog.onChange = { [weak catalog] in
            guard let catalog else { return }
            let numbers = catalog.entries(sortMode: .fixed).compactMap(\.windowNumber)
            if numbers.contains(10) { releaseLaunchScan.signal() }
            if !duringRetryCapture, foregroundPID == 43, numbers.contains(8), !catalog.isInvocationReady {
                foregroundPID = 44
                next.update { $0.focused = true }
            }
        }
        didLaunch = true
        foregroundPID = 43
        catalog.prepareForInvocation()
        if duringRetryCapture {
            try await waitUntil { retryCaptureStarted.wait(timeout: .now()) == .success }
            foregroundPID = 44
            next.update { $0.focused = true }
            releaseCapture.signal()
        }
        try await waitUntil { catalog.isInvocationReady }
        let entries = catalog.entries(sortMode: .recentUse)
        XCTAssertEqual(foregroundPID, 44)
        XCTAssertEqual(entries.first?.windowNumber, 10)
        XCTAssertEqual(catalog.focusedWindowID, entries.first?.id)
        XCTAssertEqual(next.read { $0.reads }, initialReads + 2)
        XCTAssertEqual(launched.read { $0.reads }, 1)
    }

    func testConfirmedHandoffDuringRetryAXSurvivesPublication() async throws {
        let previous = CatalogAXAccess(number: 7, elementPID: 201)
        previous.update { $0.focused = true }
        let launched = CatalogAXAccess(number: nil, elementPID: 202)
        let next = CatalogAXAccess(number: 10, elementPID: 203)
        let retryStarted = DispatchSemaphore(value: 0)
        let releaseRetry = DispatchSemaphore(value: 0)
        launched.update {
            $0.beforeRead = { [weak launched] in
                guard launched?.read({ $0.reads }) == 2 else { return }
                retryStarted.signal()
                _ = releaseRetry.wait(timeout: .now() + 2)
            }
        }
        var foregroundPID: pid_t = 42
        var didLaunch = false
        let catalog = WindowSwitcherAppCatalog(notificationCenter: NotificationCenter(), accessFactory: { pid in
            switch pid {
            case 42: previous
            case 43: launched
            default: next
            }
        }, allSpacesCatalog: .init(windowRecordProvider: { [] }), discovery: .init(applications: {
            let pids: [pid_t] = didLaunch ? [42, 43, 44] : [42, 44]
            return pids.map { .init(processIdentifier: $0, localizedName: "Fixture \($0)", isFinishedLaunching: $0 != 43) }
        }, foregroundProcessIdentifier: { foregroundPID }, isAccessibilityTrusted: { true }, isDragging: { false }))
        defer { releaseRetry.signal(); catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }

        foregroundPID = 43
        didLaunch = true
        catalog.prepareForInvocation()
        try await waitUntil { retryStarted.wait(timeout: .now()) == .success }
        foregroundPID = 44
        next.update { $0.number = 11; $0.focused = true }
        catalog.refresh()
        try await waitUntil { catalog.entries(sortMode: .fixed).contains { $0.windowNumber == 11 } }
        XCTAssertFalse(catalog.isInvocationReady)
        releaseRetry.signal()
        try await waitUntil { catalog.isInvocationReady }

        let entries = catalog.entries(sortMode: .recentUse)
        XCTAssertEqual(entries.compactMap(\.windowNumber), [11, 7])
        XCTAssertEqual(catalog.focusedWindowID, entries.first?.id)
    }

    func testRetryCaptureCannotContradictAnExactFocusEventFromTheNextSpace() async throws {
        try await verifyRetryFocusEvent(duringAccessibility: false)
    }

    func testRetryAXReadUsesAFocusChangeThatArrivesDuringEnumeration() async throws {
        try await verifyRetryFocusEvent(duringAccessibility: true)
    }

    private func verifyRetryFocusEvent(duringAccessibility: Bool) async throws {
        let previous = CatalogAXAccess(number: 7, elementPID: 201)
        previous.update { $0.focused = true }
        let launched = CatalogAXAccess(number: 8, elementPID: 202, secondaryWindowNumber: 9)
        let initialCaptures = DispatchSemaphore(value: 2)
        let retryStarted = DispatchSemaphore(value: 0)
        let releaseRetry = DispatchSemaphore(value: 0)
        launched.update {
            $0.windowListUnavailable = true
            if duringAccessibility {
                $0.beforeRead = { [weak launched] in
                    guard launched?.read({ $0.reads }) == 2 else { return }
                    retryStarted.signal()
                    _ = releaseRetry.wait(timeout: .now() + 2)
                }
            }
        }
        let changedSpace = DispatchSemaphore(value: 0)
        var foregroundPID: pid_t = 42
        let catalog = WindowSwitcherAppCatalog(notificationCenter: NotificationCenter(),
            accessFactory: { $0 == 42 ? previous : launched },
            allSpacesCatalog: .init(windowRecordProvider: {
                let onNextSpace = changedSpace.wait(timeout: .now()) == .success
                if !duringAccessibility, initialCaptures.wait(timeout: .now()) != .success, !onNextSpace {
                    retryStarted.signal()
                    _ = releaseRetry.wait(timeout: .now() + 2)
                }
                return [
                    .init(windowNumber: 8, processIdentifier: 43, title: "Previous Space", isOnScreen: !onNextSpace,
                          bounds: CGRect(x: 20, y: 20, width: 800, height: 600), hasSpace: true, isOnActiveSpace: !onNextSpace),
                    .init(windowNumber: 9, processIdentifier: 43, title: "Next Space", isOnScreen: onNextSpace,
                          bounds: CGRect(x: 60, y: 60, width: 800, height: 600), hasSpace: true, isOnActiveSpace: onNextSpace),
                ]
            }), discovery: .init(applications: {
                let prior = WindowSwitcherAppCatalog.Application(processIdentifier: 42, localizedName: "Previous")
                guard foregroundPID == 43 else { return [prior] }
                return [prior, .init(processIdentifier: 43, localizedName: "Launched", isFinishedLaunching: false)]
            }, foregroundProcessIdentifier: { foregroundPID }, isAccessibilityTrusted: { true }, isDragging: { false }))
        defer {
            catalog.stop()
            initialCaptures.signal()
            initialCaptures.signal()
            releaseRetry.signal()
        }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }

        foregroundPID = 43
        catalog.prepareForInvocation()
        try await waitUntil { retryStarted.wait(timeout: .now()) == .success }
        launched.update {
            $0.windowListUnavailable = false
            $0.focusesSecondaryWindow = true
        }
        changedSpace.signal()
        catalog.invalidate(processIdentifiers: [43], windowRecords: true, focusChanged: true)
        releaseRetry.signal()

        try await waitUntil { catalog.isInvocationReady }
        let entries = catalog.entries(sortMode: .recentUse)
        XCTAssertEqual(entries.first?.windowNumber, 9)
        XCTAssertEqual(catalog.focusedWindowID, entries.first?.id)
        XCTAssertEqual(launched.read { $0.reads }, 2)
    }

    func testForegroundHandoffAndIncompleteAXShareOneRetry() async throws {
        let previous = CatalogAXAccess(number: 7, elementPID: 201)
        previous.update { $0.focused = true }
        let launched = CatalogAXAccess(number: nil, elementPID: 202)
        let holdInvocationCapture = DispatchSemaphore(value: 0)
        let invocationCaptureStarted = DispatchSemaphore(value: 0)
        let releaseCapture = DispatchSemaphore(value: 0)
        var foregroundPID: pid_t = 42
        let catalog = WindowSwitcherAppCatalog(notificationCenter: NotificationCenter(),
            accessFactory: { $0 == 42 ? previous : launched },
            allSpacesCatalog: .init(windowRecordProvider: {
                if holdInvocationCapture.wait(timeout: .now()) == .success {
                    invocationCaptureStarted.signal()
                    _ = releaseCapture.wait(timeout: .now() + 2)
                }
                return [.init(windowNumber: 8, processIdentifier: 43, title: "Launched", isOnScreen: true,
                              bounds: CGRect(x: 20, y: 20, width: 800, height: 600))]
            }), discovery: .init(applications: {
                [.init(processIdentifier: 42, bundleIdentifier: "previous", localizedName: "Previous"),
                 .init(processIdentifier: 43, bundleIdentifier: "launched", localizedName: "Launched")]
            }, foregroundProcessIdentifier: { foregroundPID }, isAccessibilityTrusted: { true }, isDragging: { false }))
        defer { releaseCapture.signal(); catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }
        let initialReads = launched.read { $0.reads }

        holdInvocationCapture.signal()
        catalog.prepareForInvocation()
        try await waitUntil { invocationCaptureStarted.wait(timeout: .now()) == .success }
        try await waitUntil { launched.read { $0.reads } == initialReads + 1 }
        foregroundPID = 43
        releaseCapture.signal()
        try await waitUntil { catalog.isInvocationReady }
        XCTAssertEqual(launched.read { $0.reads }, initialReads + 2)
        XCTAssertEqual(catalog.entries(sortMode: .recentUse).compactMap(\.windowNumber), [7])
        XCTAssertNil(catalog.focusedWindowID)
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

    func testActiveHelperExactFocusWinsAfterHostFocusIsContradicted() async throws {
        try await verifyForegroundHostWithActiveHelper(hostIsOffscreen: true)
    }

    func testBackgroundRefreshRecordsExactHelperFocusAfterHostFocusIsContradicted() async throws {
        try await verifyForegroundHostWithActiveHelper(hostIsOffscreen: true, refreshesInBackground: true)
    }

    func testUnnumberedHelperExactFocusCanUseItsUniqueVisibilityMatch() async throws {
        try await verifyForegroundHostWithActiveHelper(hostIsOffscreen: true, exposesHelperNumber: false)
    }

    func testVisibleHelperPreventsInferringHostFocus() async throws {
        try await verifyForegroundHostWithActiveHelper(hostIsOffscreen: false)
    }

    private func verifyForegroundHostWithActiveHelper(hostIsOffscreen: Bool, refreshesInBackground: Bool = false,
                                                      exposesHelperNumber: Bool = true) async throws {
        let previous = CatalogAXAccess(number: 7, elementPID: 201)
        previous.update { $0.focused = true }
        let host = CatalogAXAccess(number: 8, elementPID: 202)
        host.update { $0.focused = hostIsOffscreen }
        let helper = CatalogAXAccess(number: 9, elementPID: 203)
        helper.update {
            $0.focused = hostIsOffscreen
            $0.exposesWindowNumber = exposesHelperNumber
        }
        var foregroundPID: pid_t = 42
        let bounds = CGRect(x: 20, y: 20, width: 800, height: 600)
        let catalog = WindowSwitcherAppCatalog(notificationCenter: NotificationCenter(),
            accessFactory: { pid in
                switch pid {
                case 42: previous
                case 43: host
                default: helper
                }
            }, allSpacesCatalog: .init(windowRecordProvider: {
                [.init(windowNumber: 8, processIdentifier: 43, title: "Host", isOnScreen: !hostIsOffscreen,
                       bounds: bounds, hasSpace: true, isOnActiveSpace: !hostIsOffscreen),
                 .init(windowNumber: 9, processIdentifier: 44, title: "Helper", isOnScreen: true,
                       bounds: bounds, hasSpace: true, isOnActiveSpace: true)]
            }), discovery: .init(applications: {
                let prior = WindowSwitcherAppCatalog.Application(processIdentifier: 42, localizedName: "Previous")
                guard foregroundPID == 43 else { return [prior] }
                return [prior,
                        .init(processIdentifier: 43, bundleIdentifier: "host", bundlePath: "/Host.app", localizedName: "Host"),
                        .init(processIdentifier: 44, bundleIdentifier: "host.helper", bundlePath: "/Host.app/Helper.app",
                              localizedName: "Helper", isRegular: false, isActive: true)]
            }, foregroundProcessIdentifier: { foregroundPID }, isAccessibilityTrusted: { true }, isDragging: { false }))
        defer { catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }

        foregroundPID = 43
        if refreshesInBackground {
            catalog.refresh()
            try await waitUntil { catalog.entries(sortMode: .fixed).contains { $0.axWorkerPID == 44 } }
        } else {
            catalog.prepareForInvocation()
            try await waitUntil { catalog.isInvocationReady }
        }
        let entries = catalog.entries(sortMode: .recentUse)
        XCTAssertEqual(Set(entries.compactMap(\.windowNumber)), exposesHelperNumber ? [7, 8, 9] : [7, 8])
        XCTAssertEqual(entries.first?.windowNumber, hostIsOffscreen ? (exposesHelperNumber ? 9 : nil) : 7)
        if hostIsOffscreen {
            XCTAssertEqual(catalog.focusedWindowID, entries.first?.id)
            XCTAssertEqual(entries.first?.axWorkerPID, 44)
        } else {
            XCTAssertNil(catalog.focusedWindowID)
        }
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

    func testHelperDiscoveredDuringHostReadDoesNotCauseARedundantRetry() async throws {
        let host = CatalogAXAccess(number: 7, elementPID: 201)
        host.update { $0.focused = true }
        let helper = CatalogAXAccess(number: 8, elementPID: 202)
        let initialCapture = DispatchSemaphore(value: 1)
        let hostReadStarted = DispatchSemaphore(value: 0)
        let releaseHostRead = DispatchSemaphore(value: 0)
        let catalog = WindowSwitcherAppCatalog(notificationCenter: NotificationCenter(),
            accessFactory: { $0 == 42 ? host : helper },
            allSpacesCatalog: .init(windowRecordProvider: {
                if initialCapture.wait(timeout: .now()) == .success { return [] }
                return [
                    .init(windowNumber: 7, processIdentifier: 42, title: "Host", isOnScreen: true,
                          bounds: CGRect(x: 20, y: 20, width: 800, height: 600)),
                    .init(windowNumber: 8, processIdentifier: 43, title: "Helper", isOnScreen: true,
                          bounds: CGRect(x: 40, y: 40, width: 800, height: 600)),
                ]
            }), discovery: .init(applications: {
                [.init(processIdentifier: 42, bundleIdentifier: "fixture.host", bundlePath: "/Fixture.app",
                       localizedName: "Fixture"),
                 .init(processIdentifier: 43, bundleIdentifier: "fixture.host.helper",
                       bundlePath: "/Fixture.app/Helper.app", localizedName: "Helper", isRegular: false)]
            }, foregroundProcessIdentifier: { 42 }, isAccessibilityTrusted: { true }, isDragging: { false }))
        defer { initialCapture.signal(); releaseHostRead.signal(); catalog.stop() }
        catalog.start()
        try await waitUntil { catalog.isInvocationReady }
        let initialHostReads = host.read { $0.reads }
        host.update {
            $0.beforeRead = {
                hostReadStarted.signal()
                _ = releaseHostRead.wait(timeout: .now() + 1)
            }
        }

        catalog.prepareForInvocation()
        try await waitUntil { hostReadStarted.wait(timeout: .now()) == .success }
        try await waitUntil { catalog.entries(sortMode: .fixed).contains { $0.windowNumber == 8 } }
        host.update { $0.beforeRead = nil }
        releaseHostRead.signal()
        try await waitUntil { catalog.isInvocationReady }
        let entries = catalog.entries(sortMode: .recentUse)
        XCTAssertEqual(entries.compactMap(\.windowNumber), [7, 8])
        XCTAssertEqual(entries.first { $0.windowNumber == 8 }?.axWorkerPID, 43)
        XCTAssertEqual(host.read { $0.reads }, initialHostReads + 1)
        XCTAssertEqual(helper.read { $0.reads }, 1)
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
