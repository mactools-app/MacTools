import AppKit
import ApplicationServices
import MacToolsPluginKit
import XCTest
@testable import WindowSwitcherPlugin

private final class ControlledSwitcherTap: WindowSwitcherShortcutListening {
    var onShortcutPressed: @MainActor @Sendable (Bool, Bool, Bool) -> Void = { _, _, _ in }
    var onShortcutReleased: @MainActor @Sendable () -> Void = {}
    var onEscape: @MainActor @Sendable () -> Void = {}
    var onAccessibilityRevoked: @MainActor @Sendable () -> Void = {}
    var isRunning = false
    var isEditing = false
    func start() { isRunning = true }
    func stop() { isRunning = false }
    var allBinding: ShortcutBinding?
    var currentAppBinding: ShortcutBinding?
    func configure(allBinding: ShortcutBinding?, currentAppBinding: ShortcutBinding?) {
        self.allBinding = allBinding; self.currentAppBinding = currentAppBinding
    }
    func setEditing(_ value: Bool) { isEditing = value }
    func setSessionActive(_ value: Bool) {}
}

@MainActor
private final class ControlledSwitcherCatalog: WindowSwitcherCatalog {
    var onChange: (() -> Void)?
    var focusedWindowID: String? = "a"
    var isInitialDiscoveryComplete = true
    var invocationReady: Bool?
    var isInvocationReady: Bool { invocationReady ?? isInitialDiscoveryComplete }
    var prepareInvocation: (() -> Void)?
    func prepareForInvocation(sortMode: WindowSwitcherSortMode) { prepareInvocation?() }
    var canOpenAtDeadline = false
    var openingOverride: WindowSwitcherOpening?
    func opening(sortMode: WindowSwitcherSortMode, deadlineReached: Bool) -> WindowSwitcherOpening? {
        guard isInvocationReady || (deadlineReached && canOpenAtDeadline), !windows.isEmpty else { return nil }
        defer { openingOverride = nil }
        return openingOverride ?? WindowSwitcherOpening(entries: windows, focusedWindowID: focusedWindowID)
    }
    var windows: [WindowSwitcherAppEntry] = []
    var activated: [String] = []
    var activationResult: WindowSwitcherActionResult = .succeeded
    var isRunning = false
    func start() { isRunning = true }
    func stop() { isRunning = false }
    var refreshCount = 0
    func refresh() { refreshCount += 1 }
    func entries(sortMode: WindowSwitcherSortMode) -> [WindowSwitcherAppEntry] { windows }
    func activate(_ entry: WindowSwitcherAppEntry, intent: WindowSwitcherActivationIntent) async -> WindowSwitcherActionResult {
        activated.append(entry.id)
        return activationResult
    }
    func closeWindow(_ entry: WindowSwitcherAppEntry) async -> WindowSwitcherActionResult { .requested }
    func quitApplication(_ entry: WindowSwitcherAppEntry) -> WindowSwitcherActionResult { .requested }
}

@MainActor
final class WindowSwitcherLifecycleTests: XCTestCase {

    func testQuickReleaseWaitsForFreshNonemptyInvocationAndKeepsNavigation() async {
        let catalog = ControlledSwitcherCatalog(), tap = ControlledSwitcherTap()
        catalog.windows = [entry("a"), entry("b"), entry("c")]
        catalog.prepareInvocation = { catalog.invocationReady = false }
        let plugin = plugin(catalog: catalog, tap: tap)
        defer { plugin.deactivate(reason: .hostShutdown) }
        tap.onShortcutPressed(false, false, false)
        tap.onShortcutPressed(false, false, true)
        tap.onShortcutReleased()
        XCTAssertNotNil(plugin.pendingInvocation)
        XCTAssertTrue(catalog.activated.isEmpty)
        catalog.windows = [entry("a"), entry("d"), entry("e")]
        catalog.invocationReady = true
        catalog.onChange?()
        await eventually { !catalog.activated.isEmpty }
        XCTAssertEqual(catalog.activated, ["e"])
        XCTAssertNil(plugin.pendingInvocation)
    }

    func testLaunchCheckDeadlineUsesReadyCatalogForQuickSwitch() async {
        let catalog = ControlledSwitcherCatalog(), tap = ControlledSwitcherTap()
        catalog.windows = [entry("a"), entry("b")]
        let plugin = plugin(catalog: catalog, tap: tap)
        defer { plugin.deactivate(reason: .hostShutdown) }
        catalog.prepareInvocation = {
            catalog.invocationReady = false
            catalog.canOpenAtDeadline = true
        }
        tap.onShortcutPressed(false, false, false)
        tap.onShortcutReleased()

        await eventually { !catalog.activated.isEmpty }
        XCTAssertEqual(catalog.activated, ["b"])
        XCTAssertNil(plugin.pendingInvocation)
    }

    func testLaunchPromotionAnchorsOnlyTheInitialChooser() {
        let catalog = ControlledSwitcherCatalog(), tap = ControlledSwitcherTap()
        catalog.windows = [entry("b"), entry("c"), entry("a")]
        catalog.focusedWindowID = "b"
        catalog.openingOverride = WindowSwitcherOpening(
            entries: [entry("a"), entry("b"), entry("c")], focusedWindowID: "a")
        let plugin = plugin(catalog: catalog, tap: tap)
        defer { plugin.deactivate(reason: .hostShutdown) }

        tap.onShortcutPressed(false, false, false)
        XCTAssertEqual(plugin.session?.originalWindowID, "a")
        XCTAssertEqual(plugin.session?.selectedID, "b")
        XCTAssertEqual(catalog.focusedWindowID, "b")

        catalog.onChange?()
        XCTAssertEqual(plugin.session?.entries.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(plugin.session?.selectedID, "b")
    }

    func testCatalogUpdatesReconcileLiveSessionWithoutInvalidatingHost() {
        let catalog = ControlledSwitcherCatalog(), tap = ControlledSwitcherTap()
        catalog.windows = [entry("a"), entry("b")]
        let plugin = plugin(catalog: catalog, tap: tap)
        defer { plugin.deactivate(reason: .hostShutdown) }
        tap.onShortcutPressed(false, false, false)
        var hostUpdates = 0
        plugin.onStateChange = { hostUpdates += 1 }
        catalog.windows = [entry("a"), entry("c")]
        catalog.onChange?()

        XCTAssertEqual(Set(plugin.session?.entries.map(\.id) ?? []), ["a", "c"])
        XCTAssertEqual(hostUpdates, 0)
    }

    func testRetainedPendingRowUsesCurrentDirectKeyAssignment() throws {
        func window(_ number: CGWindowID, owner: pid_t, name: String, hasAX: Bool = true) -> WindowSwitcherAppEntry {
            WindowSwitcherAppEntry(id: "window:\(number)", processIdentifier: owner, bundleIdentifier: "fixture.\(owner)",
                appName: name, windowTitle: name, icon: nil,
                windowElement: hasAX ? AXUIElementCreateApplication(owner) : nil,
                isMinimized: false, windowNumber: number, shortcutToken: nil)
        }

        let original = window(7, owner: 42, name: "Fixture")
        let other = window(8, owner: 43, name: "Second")
        let arriving = window(9, owner: 44, name: "Third")
        let originalKey = try XCTUnwrap(WindowSwitcherShortcutAssignment.assignShortcuts(to: [original]).first?.shortcutToken)
        let storage = WindowSwitcherMemoryStorage()
        let bindings = WindowSwitcherShortcutBindingState(manual: [arriving.appIdentifier: originalKey])
        storage.set(try JSONEncoder().encode(bindings), forKey: "shortcut-bindings")

        let catalog = ControlledSwitcherCatalog(), tap = ControlledSwitcherTap()
        catalog.windows = [original, other]
        catalog.focusedWindowID = original.id
        let plugin = plugin(catalog: catalog, tap: tap, storage: storage)
        plugin.store.setMode(.keyWindow)
        defer { plugin.deactivate(reason: .hostShutdown) }
        tap.onShortcutPressed(false, false, false)
        XCTAssertEqual(plugin.session?.selected?.shortcutToken, originalKey)

        var pending = window(7, owner: 42, name: "Fixture", hasAX: false)
        pending.isAwaitingWindowConfirmation = true
        catalog.windows = [pending, other, arriving]
        catalog.onChange?()

        XCTAssertEqual(plugin.session?.entries.map(\.id), [original.id, other.id, arriving.id])
        XCTAssertEqual(plugin.session?.selectedID, original.id)
        XCTAssertEqual(plugin.session?.results.first { $0.shortcutToken == originalKey }?.id, arriving.id)
    }

    func testCatalogPermissionRevocationStillNotifiesHostAndStopsListening() {
        let permission = PermissionFixture()
        let catalog = ControlledSwitcherCatalog(), tap = ControlledSwitcherTap()
        let plugin = plugin(catalog: catalog, tap: tap, trusted: { permission.granted })
        defer { plugin.deactivate(reason: .hostShutdown) }
        var hostUpdates = 0
        plugin.onStateChange = { hostUpdates += 1 }
        permission.granted = false
        catalog.onChange?()

        XCTAssertEqual(hostUpdates, 1)
        XCTAssertFalse(tap.isRunning)
        XCTAssertFalse(catalog.isRunning)
        XCTAssertFalse(plugin.permissionState(for: WindowSwitcherConstants.accessibilityPermissionID).isGranted)
    }

    func testLateCallbacksAndRecorderCompletionCannotRestartDeactivatedPlugin() {
        let catalog = ControlledSwitcherCatalog(), tap = ControlledSwitcherTap()
        catalog.windows = [entry("a"), entry("b")]
        let plugin = plugin(catalog: catalog, tap: tap)
        plugin.deactivate(reason: .disabled)
        tap.onShortcutReleased(); tap.onShortcutPressed(false, false, false)
        plugin.setShortcutRecording(false); plugin.refresh()
        XCTAssertNil(plugin.session)
        XCTAssertFalse(tap.isRunning); XCTAssertFalse(catalog.isRunning)
        XCTAssertTrue(plugin.store.configuration.isEnabled)
    }

    private final class PermissionFixture {
        var granted = true
    }
    private func entry(_ id: String) -> WindowSwitcherAppEntry {
        WindowSwitcherAppEntry(id: id, processIdentifier: 100, bundleIdentifier: "org.example.test", appName: "Fixture",
                               windowTitle: id, icon: nil, windowElement: nil, isMinimized: false, shortcutToken: nil)
    }
    private func plugin(catalog: ControlledSwitcherCatalog, tap: ControlledSwitcherTap,
                        overlay: WindowSwitcherOverlayController? = nil,
                        storage: WindowSwitcherMemoryStorage = WindowSwitcherMemoryStorage(),
                        trusted: @escaping @MainActor @Sendable () -> Bool = { true }) -> WindowSwitcherPlugin {
        let plugin = WindowSwitcherPlugin(context: PluginRuntimeContext(pluginID: WindowSwitcherConstants.pluginID,
            storage: storage), appCatalog: catalog, overlayController: overlay ?? WindowSwitcherOverlayController(), shortcutTap: tap,
            discoveryTimeout: .milliseconds(30), accessibilityTrusted: trusted)
        // Most lifecycle scenarios below exercise release-to-activate cycling.
        // Search and legacy scenarios opt into their respective mode explicitly.
        plugin.store.setMode(.directCycle)
        plugin.shortcutBindingResolver = { id in
            id == WindowSwitcherConstants.shortcutDefinitionID
                ? WindowSwitcherShortcutBindingStore.defaultBinding : WindowSwitcherShortcutBindingStore.currentAppBinding
        }
        plugin.activate(context: PluginRuntimeContext(pluginID: WindowSwitcherConstants.pluginID, storage: WindowSwitcherMemoryStorage()))
        return plugin
    }
    private func eventually(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(predicate(), file: file, line: line)
    }

    func testRecentUseSearchStartsAtNextWindowAndFailureDoesNotReopen() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MACTOOLS_RUN_DESKTOP_TESTS"] == "1",
            "Requires an active desktop; run with TEST_RUNNER_MACTOOLS_RUN_DESKTOP_TESTS=1."
        )
        let catalog = ControlledSwitcherCatalog(), tap = ControlledSwitcherTap()
        catalog.windows = [entry("a"), entry("b")]
        catalog.activationResult = .failed
        let overlay = WindowSwitcherOverlayController()
        let plugin = plugin(catalog: catalog, tap: tap, overlay: overlay)
        defer { plugin.deactivate(reason: .hostShutdown) }
        plugin.store.setMode(.searchSelect)
        plugin.store.setSortMode(.recentUse)
        let previousApplicationPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        tap.onShortcutPressed(false, false, false)
        XCTAssertEqual(plugin.session?.selectedID, "b")
        await eventually { overlay.isVisible }
        XCTAssertNotNil(plugin.session, "The session must remain open until a user selection")
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, previousApplicationPID)
        XCTAssertTrue(overlay.isEditingSearch, "Search Select must focus search when the panel opens")
        XCTAssertTrue(tap.isEditing)
        let panel = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "WindowSwitcherChooser" && $0.isVisible })
        _ = try XCTUnwrap(panel.firstResponder as? NSTextView)
        let text = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "b", charactersIgnoringModifiers: "b",
            isARepeat: false, keyCode: 11))
        panel.sendEvent(text)
        XCTAssertEqual(plugin.session?.query, "b", "Typing must reach search without clicking or pressing Find")
        XCTAssertEqual(plugin.session?.selectedID, "b")
        overlay.onSelect?(catalog.windows[1])
        await eventually { catalog.activated == ["b"] }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(plugin.session)
        XCTAssertFalse(overlay.isVisible)
    }

    func testHostResolvedNilAndCustomBindingsAreAuthoritative() {
        let catalog = ControlledSwitcherCatalog(), tap = ControlledSwitcherTap()
        let plugin = plugin(catalog: catalog, tap: tap)
        defer { plugin.deactivate(reason: .hostShutdown) }
        let custom = ShortcutBinding(keyCode: 48, modifiers: [.control, .option])
        plugin.shortcutBindingResolver = { id in id == WindowSwitcherConstants.shortcutDefinitionID ? custom : nil }
        XCTAssertEqual(tap.allBinding, custom)
        XCTAssertNil(tap.currentAppBinding)
        plugin.shortcutBindingResolver = { _ in nil }
        plugin.shortcutBindingDidChange(id: WindowSwitcherConstants.shortcutDefinitionID, binding: nil)
        XCTAssertNil(tap.allBinding)
        XCTAssertNil(tap.currentAppBinding)
    }

    func testPersistentSessionCyclesWithRepeatedTabWithoutClosing() {
        let catalog = ControlledSwitcherCatalog(), tap = ControlledSwitcherTap()
        catalog.windows = [entry("a"), entry("b"), entry("c")]
        let plugin = plugin(catalog: catalog, tap: tap)
        defer { plugin.deactivate(reason: .hostShutdown) }
        plugin.store.setMode(.searchSelect)
        plugin.shortcutBindingResolver = { _ in WindowSwitcherShortcutBindingStore.legacyBinding }
        tap.onShortcutPressed(false, false, false)
        XCTAssertTrue(plugin.session?.isPersistent == true)
        let first = plugin.session?.selectedID
        tap.onShortcutPressed(false, false, false)
        XCTAssertNotEqual(plugin.session?.selectedID, first)
        tap.onShortcutPressed(true, false, false)
        XCTAssertEqual(plugin.session?.selectedID, first)
        tap.onShortcutReleased()
        XCTAssertNotNil(plugin.session)
        XCTAssertTrue(catalog.activated.isEmpty)
    }

    func testCycleKeepsCompactSearchUntilFindOpensIt() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MACTOOLS_RUN_DESKTOP_TESTS"] == "1",
            "Requires an active desktop; run with TEST_RUNNER_MACTOOLS_RUN_DESKTOP_TESTS=1."
        )
        let catalog = ControlledSwitcherCatalog(), tap = ControlledSwitcherTap()
        catalog.windows = [entry("a"), entry("b")]
        let overlay = WindowSwitcherOverlayController()
        let plugin = plugin(catalog: catalog, tap: tap, overlay: overlay)
        defer { plugin.deactivate(reason: .hostShutdown) }

        tap.onShortcutPressed(false, false, false)
        await eventually { overlay.isVisible }
        XCTAssertFalse(overlay.isEditingSearch)
        XCTAssertEqual(plugin.session?.isPersistent, false)
        XCTAssertEqual(plugin.session?.query, "")
        XCTAssertFalse(tap.isEditing)

        tap.onShortcutReleased()
        await eventually { catalog.activated == ["b"] }
        await eventually { plugin.session == nil }

        tap.onShortcutPressed(false, false, false)
        await eventually { overlay.isVisible }
        let find = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: 0, context: nil, characters: "f", charactersIgnoringModifiers: "f",
            isARepeat: false, keyCode: 3))
        XCTAssertTrue(overlay.handleChooserShortcut(find))
        XCTAssertTrue(overlay.isEditingSearch)
        XCTAssertEqual(plugin.session?.query, "")
        XCTAssertEqual(plugin.session?.isPersistent, true)
        XCTAssertTrue(tap.isEditing)
        tap.onShortcutReleased()
        XCTAssertTrue(overlay.isVisible)
    }

    func testModeIndicatorCyclesSavedBehaviorWhileChooserStaysOpen() async throws {
        let catalog = ControlledSwitcherCatalog(), tap = ControlledSwitcherTap()
        catalog.windows = [entry("a"), entry("b")]
        let overlay = WindowSwitcherOverlayController()
        let plugin = plugin(catalog: catalog, tap: tap, overlay: overlay)
        defer { plugin.deactivate(reason: .hostShutdown) }
        plugin.store.setMode(.searchSelect)
        tap.onShortcutPressed(false, false, false)
        await eventually { overlay.isVisible }

        let panel = try XCTUnwrap(NSApp.windows.first {
            $0.identifier?.rawValue == "WindowSwitcherChooser" && $0.isVisible
        })
        func modeButton(in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.identifier?.rawValue == "window-switcher-mode" { return button }
            return view.subviews.lazy.compactMap(modeButton).first
        }
        let button = try XCTUnwrap(panel.contentView.flatMap(modeButton))

        button.performClick(nil)
        XCTAssertEqual(plugin.store.configuration.mode, .directCycle)
        XCTAssertTrue(overlay.isVisible)
        XCTAssertEqual(overlay.session?.isPersistent, true)
        tap.onShortcutReleased()
        XCTAssertTrue(catalog.activated.isEmpty)

        button.performClick(nil)
        XCTAssertEqual(plugin.store.configuration.mode, .keyWindow)
        XCTAssertEqual(overlay.session?.usesDirectKeys, true)
        XCTAssertTrue(tap.isEditing)

        button.performClick(nil)
        XCTAssertEqual(plugin.store.configuration.mode, .searchSelect)
        XCTAssertEqual(overlay.session?.usesDirectKeys, false)
        XCTAssertTrue(overlay.isVisible)
    }

    func testColdInvocationWaitsForInitialProcessesInsteadOfFirstFastApp() async {
        let catalog = ControlledSwitcherCatalog(), tap = ControlledSwitcherTap()
        catalog.isInitialDiscoveryComplete = false
        let plugin = plugin(catalog: catalog, tap: tap)
        defer { plugin.deactivate(reason: .hostShutdown) }
        tap.onShortcutPressed(false, false, false)
        catalog.windows = [entry("other")]
        catalog.onChange?()
        XCTAssertNil(plugin.session)
        XCTAssertNotNil(plugin.pendingInvocation)
        catalog.windows = [entry("a"), entry("b"), entry("other")]
        catalog.isInitialDiscoveryComplete = true
        catalog.onChange?()
        XCTAssertEqual(plugin.session?.selectedID, "b")
    }

    func testCanonicalActionReportsDiscoveryTimeoutInsteadOfSuccess() async throws {
        let catalog = ControlledSwitcherCatalog(), tap = ControlledSwitcherTap()
        let plugin = plugin(catalog: catalog, tap: tap)
        defer { plugin.deactivate(reason: .hostShutdown) }
        let handle = try plugin.beginAction(ActionInvocation(reference: ActionReference(key: plugin.actionDefinitions[0].key),
                                                             source: .test, mode: .foreground))
        let result = await handle.result()
        guard case .failed = result else { return XCTFail("Empty discovery must not report presentation success") }
        XCTAssertNil(plugin.pendingInvocation)
        XCTAssertNil(plugin.session)
    }

    func testQuickReleaseDuringDiscoveryCommitsExactlyOnceWhenSnapshotArrives() async {
        let catalog = ControlledSwitcherCatalog(), tap = ControlledSwitcherTap()
        let plugin = plugin(catalog: catalog, tap: tap)
        defer { plugin.deactivate(reason: .hostShutdown) }
        tap.onShortcutPressed(false, false, false)
        tap.onShortcutReleased()
        XCTAssertTrue(catalog.activated.isEmpty)
        catalog.windows = [entry("a"), entry("b")]
        catalog.onChange?()
        await eventually { catalog.activated == ["b"] }
        tap.onShortcutReleased()
        XCTAssertEqual(catalog.activated, ["b"])
    }

    func testCancelWhileDiscoveringCannotActivateLateResult() async {
        let catalog = ControlledSwitcherCatalog(), tap = ControlledSwitcherTap()
        let plugin = plugin(catalog: catalog, tap: tap)
        defer { plugin.deactivate(reason: .hostShutdown) }
        tap.onShortcutPressed(false, false, false)
        tap.onShortcutReleased()
        tap.onEscape()
        catalog.windows = [entry("a"), entry("b")]
        catalog.onChange?()
        await Task.yield()
        XCTAssertNil(plugin.session)
        XCTAssertNil(plugin.pendingInvocation)
        XCTAssertTrue(catalog.activated.isEmpty)
    }

    func testModifierReleaseAfterEnteringSearchDoesNotCommit() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MACTOOLS_RUN_DESKTOP_TESTS"] == "1",
            "Requires an active desktop; run with TEST_RUNNER_MACTOOLS_RUN_DESKTOP_TESTS=1."
        )
        let catalog = ControlledSwitcherCatalog(), tap = ControlledSwitcherTap()
        let overlay = WindowSwitcherOverlayController()
        catalog.windows = [entry("a"), entry("b")]
        let plugin = plugin(catalog: catalog, tap: tap, overlay: overlay)
        defer { plugin.deactivate(reason: .hostShutdown) }
        plugin.shortcutBindingResolver = { _ in WindowSwitcherShortcutBindingStore.legacyBinding }
        tap.onShortcutPressed(false, false, false)
        await eventually { overlay.isVisible }
        let find = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: 0, context: nil, characters: "f", charactersIgnoringModifiers: "f",
            isARepeat: false, keyCode: 3))
        XCTAssertTrue(overlay.handleChooserShortcut(find))
        tap.onShortcutReleased()
        await Task.yield()
        XCTAssertTrue(catalog.activated.isEmpty)
        XCTAssertTrue(plugin.session?.isPersistent == true)
        XCTAssertEqual(plugin.session?.query, "")
        XCTAssertTrue(overlay.isVisible)
        XCTAssertTrue(overlay.isEditingSearch)
        XCTAssertTrue(tap.isEditing)
    }

    func testPermissionRevocationCancelsOpenSessionAndStopsWorkers() {
        let catalog = ControlledSwitcherCatalog(), tap = ControlledSwitcherTap()
        catalog.windows = [entry("a"), entry("b")]
        let permission = PermissionFixture()
        let plugin = plugin(catalog: catalog, tap: tap, trusted: { permission.granted })
        defer { plugin.deactivate(reason: .hostShutdown) }
        tap.onShortcutPressed(false, false, false)
        XCTAssertNotNil(plugin.session)
        permission.granted = false
        catalog.onChange?()
        XCTAssertNil(plugin.session)
        XCTAssertFalse(catalog.isRunning)
        XCTAssertFalse(tap.isRunning)
        tap.onShortcutReleased()
        XCTAssertTrue(catalog.activated.isEmpty)
    }

    func testReleaseRechecksPermissionBeforeAnyCatalogNotification() async {
        let catalog = ControlledSwitcherCatalog(), tap = ControlledSwitcherTap()
        let permission = PermissionFixture()
        catalog.windows = [entry("a"), entry("b")]
        let plugin = plugin(catalog: catalog, tap: tap, trusted: { permission.granted })
        defer { plugin.deactivate(reason: .hostShutdown) }
        tap.onShortcutPressed(false, false, false)
        permission.granted = false
        tap.onShortcutReleased()
        await Task.yield()
        XCTAssertTrue(catalog.activated.isEmpty)
        XCTAssertNil(plugin.session)
        XCTAssertFalse(tap.isRunning)
    }

}
