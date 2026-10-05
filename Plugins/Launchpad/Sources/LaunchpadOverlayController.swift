import AppKit
import MacToolsPluginKit
import OSLog
import SwiftUI

/// A borderless overlay window cannot become key/main by default, which would stop
/// the search field and keyboard navigation from working. Override both.
final class LaunchpadOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private struct LaunchpadOverlayRootView: View {
    @ObservedObject private var runtimeLocale = PluginRuntimeLocalization.source
    let grid: LaunchpadGridView
    let onLocaleChange: () -> Void

    var body: some View {
        let _ = runtimeLocale.revision
        grid
            .environment(\.locale, runtimeLocale.locale)
            // Paging offsets, keyboard arrows, and AppKit hit testing share physical coordinates.
            .environment(\.layoutDirection, .leftToRight)
            .onChange(of: runtimeLocale.revision, initial: true) { _, _ in onLocaleChange() }
    }
}

/// Holds the AppKit monitor/observer tokens. Kept in a separate, non–actor-isolated
/// class so its `deinit` can remove them as a backstop (Codex P2 #5) without tripping
/// Swift 6's "non-Sendable access from nonisolated deinit" rule. `removeMonitor` /
/// `removeObserver` are safe to call from any thread.
private final class DismissHandlerTokens {
    var keyMonitor: Any?
    var screenObserver: NSObjectProtocol?
    var resignObserver: NSObjectProtocol?
    var resignKeyObserver: NSObjectProtocol?

    func removeAll() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        for observer in [screenObserver, resignObserver, resignKeyObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        screenObserver = nil
        resignObserver = nil
        resignKeyObserver = nil
    }

    deinit { removeAll() }
}

/// Owns the fullscreen grid overlay window: creation, multi-display placement,
/// dismissal and clean teardown. Mirrors the repo's `PhysicalCleanModeSession`
/// teardown discipline; window config follows the LaunchNext-proven recipe.
@MainActor
final class LaunchpadOverlayController: NSObject, NSWindowDelegate {
    private var window: LaunchpadOverlayWindow?
    private let tokens = DismissHandlerTokens()
    private var isTearingDown = false
    /// App that was frontmost before we activated, so dismissal can hand focus back
    /// (Codex P1 #3). Cleared on launch (the launched app should win focus).
    private var previousApp: NSRunningApplication?

    private let catalog = LaunchpadAppCatalog()
    private let preferences: LaunchpadPreferences
    /// Custom-order layout shared with the grid as `@ObservedObject` so a reorder /
    /// reset re-renders the open overlay (the grid does NOT observe `onStateChange`).
    private let layoutStore: LaunchpadLayoutStore
    /// Folder-eject handoff (the floating icon rides in its own child NSWindow). Controller-owned
    /// so `close()` can abort an in-flight eject deterministically — that floating window is NOT
    /// part of the overlay window and would survive it otherwise. Internal (not private) so tests
    /// can drive a carry through the controller's PRODUCTION storeApplier/close wiring (§10-④).
    let dragCoordinator = LaunchpadDragCoordinator()
    private let localization: PluginLocalization
    /// Window mode captured at `open()`. The grid content is rendered against this
    /// snapshot, so frame recomputation (screen changes) must use it too — not live
    /// `preferences`, which could drift mid-session and desync frame vs. content (Codex P2).
    private var sessionMode: LaunchpadPreferences.WindowMode = .fullscreen
    /// Grid metrics resolved from the appearance preferences at `open()` (design §1.4).
    ///
    /// INVARIANT — metrics are constant for the whole overlay session: every consumer
    /// (SwiftUI pager, AppKit page grids, folder panel, carry floating window, compact
    /// frame) reads THIS snapshot, so a settings change can only take effect on the next
    /// summon. Mid-carry appearance changes are therefore unreachable by construction
    /// (the settings window taking key closes the overlay via `resignKeyObserver`);
    /// the only mid-session geometry mutations left are window resize / screen swaps,
    /// already fail-safed by `cancelCarry(.geometryChanged)` in `syncGeometry`.
    private var sessionMetrics = LaunchpadGridMetrics()
    /// Compact scale captured at `open()` alongside `sessionMode` — screen-change frame
    /// recomputation must not read live preferences either (same snapshot discipline).
    private var sessionCompactScale = LaunchpadPreferences.defaultCompactScale
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "LaunchpadOverlay"
    )

    init(
        preferences: LaunchpadPreferences,
        layoutStore: LaunchpadLayoutStore,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.preferences = preferences
        self.layoutStore = layoutStore
        self.localization = localization
        super.init()
        // The synchronous mouseUp data path (design §1.3): the controller owns both the store and
        // the coordinator, so the commit writes the store directly — never through a SwiftUI
        // `@Published` token a torn-down view could fail to consume (the resign-active data-loss
        // race). Captures the store/localization directly: no reference back to self, no cycle.
        dragCoordinator.storeApplier = { [layoutStore, localization] action, frozenOrder in
            let folderName = localization.string("folder.defaultName", defaultValue: "未命名")
            return Self.apply(action, frozenOrder: frozenOrder, to: layoutStore, folderName: folderName)
        }
    }

    /// Maps a resolved carry commit onto the layout store, returning the landing id the visual
    /// channel re-selects. Mirrors the per-result handlers that previously lived in the grid view
    /// (`handleMoveOutOfFolder` and friends) — the store mutation semantics are unchanged.
    /// Internal (not private) so tests drive the production mapping directly (design §10-⑤).
    static func apply(
        _ action: CarryStoreAction,
        frozenOrder: [LaunchpadDisplayCell],
        to store: LaunchpadLayoutStore,
        folderName: String
    ) -> String? {
        // Materialize/extend the layout from the order frozen at drag start, not a live read a
        // mid-carry catalog reload may have changed (constraint 15).
        let rootApps = frozenOrder.compactMap { cell -> LaunchpadAppItem? in
            if case .app(let item) = cell { return item }
            return nil
        }
        switch action {
        case .none:
            return nil
        case .move(let id, let target):
            store.captureVisibleOrder(rootApps)
            switch target {
            case .before(let targetID):
                store.move(id: id, before: targetID)
            case .after(let targetID):
                store.move(id: id, after: targetID)
            case nil:
                // Global tail. resolveCarryCommit only emits nil targets once the virtual tail
                // page lands (step 6); defensive mapping in the meantime.
                if let last = frozenOrder.last?.layoutID, last != id { store.move(id: id, after: last) }
            }
            return id
        case .makeFolder(let targetAppID, let draggedID):
            store.captureVisibleOrder(rootApps)
            let newID = UUID().uuidString
            store.makeFolder(target: targetAppID, dragged: draggedID, name: folderName, id: newID)
            return newID
        case .addToFolder(let folderID, let appID):
            store.captureVisibleOrder(rootApps)
            store.addToFolder(folderID, app: appID)
            return folderID
        case .moveOutOfFolder(let folderID, let appID, let result):
            store.captureVisibleOrder(rootApps)
            switch result {
            case .reorder(let target):
                store.moveOutOfFolder(folderID, app: appID, to: target)
                return appID
            case .makeFolder(let targetAppID):
                let newID = UUID().uuidString
                store.ejectIntoNewFolder(source: folderID, app: appID, target: targetAppID,
                                         name: folderName, id: newID)
                return newID
            case .addToFolder(let destFolderID):
                store.ejectIntoFolder(source: folderID, app: appID, destination: destFolderID)
                return destFolderID
            }
        }
    }

    var isShown: Bool { window != nil }

    func toggle() {
        isShown ? close() : open()
    }

    /// Warm the app catalog ahead of the first open so the grid shows icons
    /// immediately instead of a spinner: the disk scan runs in the background
    /// now (on plugin activation) rather than on the critical path when the
    /// user summons the launcher. Idempotent — `reload()`'s generation guard
    /// drops a stale scan, and a later `open()` reload supersedes this one for
    /// freshness — so calling it more than once is safe.
    func prewarm() {
        catalog.reload()
    }

    func open() {
        guard window == nil else { return }
        // Restore the *user's* app on dismiss, not ourselves. When triggered from the
        // menu bar, frontmost may already be MacTools; capturing that would make
        // dismissal a no-op (Codex P2). The global-hotkey path captures the real app.
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = (front == .current) ? nil : front
        catalog.reload()
        sessionMode = preferences.windowMode      // snapshot for this session
        sessionMetrics = LaunchpadGridMetrics.resolve(preferences.appearance)
        sessionCompactScale = preferences.compactScalePercent
        let screen = activeScreen()
        let isCompact = sessionMode == .compact
        let frame = targetFrame(on: screen)

        let win = LaunchpadOverlayWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        win.delegate = self
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = isCompact                  // a floating panel reads better with a shadow
        win.isMovable = false
        win.isReleasedWhenClosed = false          // don't dealloc mid-session
        // Cover the menu bar + Dock + the current (possibly fullscreen) Space, but stay
        // a *launcher*, not a screen-saver shroud. `.popUpMenu` (101) sits above the
        // menu bar (24) and Dock (20) yet well below `.screenSaver` (1000), which Codex
        // (P1 #1) flagged as too heavy for this semantic. `.canJoinAllApplications +
        // .fullScreenAuxiliary` is what lets it join another app's fullscreen Space.
        // Verified on Tahoe covering the full active display (menu bar + Dock) without
        // shrouding the other screen. Coverage over a *fullscreen-app* Space (Safari /
        // video / Metal games) and Stage Manager warrants a wider device sweep; raise the
        // level only if a real fullscreen Space is found to peek through.
        win.level = .popUpMenu
        win.collectionBehavior = [.canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        win.setFrame(frame, display: true)
        let host = NSHostingView(rootView: LaunchpadOverlayRootView(grid: LaunchpadGridView(
            catalog: catalog,
            layoutStore: layoutStore,
            dragCoordinator: dragCoordinator,
            columns: preferences.columns,
            isCompact: isCompact,
            // The session metrics snapshot (design §1.4): the SwiftUI pager, the AppKit
            // page grids and the folder panel all derive from this one injection.
            metrics: sessionMetrics,
            hiddenAppIDs: preferences.hiddenAppIDs,
            // Snapshot, same discipline as `sessionMode`: settings changes apply on the
            // next summon (the settings window taking key closes the overlay anyway).
            backgroundRecipe: preferences.backgroundRecipe,
            localization: localization,
            onActivate: { [weak self] app in self?.launch(app) },
            onReveal: { [weak self] app in self?.reveal(app) },
            onHide: { [weak self] app in self?.preferences.hide(app.id) },
            onDismiss: { [weak self] in self?.close() }
        ), onLocaleChange: { [weak win, localization] in
            guard let win else { return }
            win.title = localization.string("metadata.title", defaultValue: "启动台")
            win.setAccessibilityLabel(win.title)
        }))
        win.contentView = host
        if isCompact {
            // Round the floating panel. This layer mask clips the in-process SwiftUI
            // content (icons, labels, dim layer, legacy ultraThinMaterial); the glass
            // recipes additionally round the behind-window blur itself via the backdrop's
            // maskImage with the SAME shared radius (see LaunchpadGlassBackdrop).
            // TODO(G5): on macOS 26+ wrap the compact panel in NSGlassEffectView (with an
            // NSGlassEffectContainerView shared with the folder panel when both are visible).
            // `#available` gated, separate commit, Tahoe screenshots.
            host.wantsLayer = true
            host.layer?.cornerRadius = LaunchpadCompactPanelMetrics.cornerRadius
            host.layer?.masksToBounds = true
        }

        PluginPresentationSafety.prepareForWindowOrdering(win)
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        window = win
        installDismissHandlers(for: win)
    }

    /// - Parameter restoringFocus: hand focus back to the previously frontmost app.
    ///   `true` for user dismissal (Esc / background / app switch); `false` when an app
    ///   was just launched (it should come forward instead).
    func close(restoringFocus: Bool = true) {
        guard !isTearingDown else { return }
        // A carry may be mid-flight (mouse still down): drop its floating icon window before the
        // overlay goes — it's a separate window and would outlive us. Ahead of the window guard
        // (nil-safe and idempotent) so no close request can ever leave a floating icon behind.
        // Fully synchronous; if a commit already landed, its data hit the store in mouseUp and
        // only visuals are skipped.
        dragCoordinator.cancelCarry(.overlayClosed)
        guard let win = window else { return }
        isTearingDown = true
        removeDismissHandlers()
        // A folder rename may be mid-edit on ANY whole-window teardown path (Cmd+Tab
        // resign-active, the Settings window taking key, launching an app from inside a
        // folder). SwiftUI only contracts `dismantleNSView` for diffing removals — an
        // NSHostingView deallocated together with its window may never get one — so resign
        // first responder HERE: the field editor ends editing and the rename coordinator
        // commits synchronously on this event stack (design §2.3 "unmount → commit, no data
        // loss"). Idempotent for every other responder (search field has no end-editing
        // hooks) and the session latch keeps any later dismantle call inert.
        win.makeFirstResponder(nil)
        win.delegate = nil
        win.orderOut(nil)
        win.close()
        window = nil
        if restoringFocus, let previousApp, previousApp != .current {
            previousApp.activate()
        }
        previousApp = nil
        isTearingDown = false
    }

    private func launch(_ app: LaunchpadAppItem) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        let logger = logger
        // Dismiss immediately for a Launchpad-snappy feel (we only ever list validated
        // bundles, so failures are rare). On the rare failure, beep + log so the click
        // isn't silent (Codex P1) — the launched app, on success, wins focus itself.
        NSWorkspace.shared.openApplication(at: app.url, configuration: config) { _, error in
            if let error {
                // Privacy: never log the full path (it can contain ~/<user>); the bundle
                // name is enough, and the error may itself embed the path so keep it private.
                logger.error("launch failed for \(app.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .private)")
                NSSound.beep()
            }
        }
        close(restoringFocus: false)
    }

    private func reveal(_ app: LaunchpadAppItem) {
        // Reveal brings Finder forward, so close without restoring focus (Finder wins).
        NSWorkspace.shared.activateFileViewerSelecting([app.url])
        close(restoringFocus: false)
    }

    /// v1 decision: open on the screen under the mouse (NOT NSScreen.main, NOT all
    /// screens). Documented single-display behavior.
    private func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    /// Window frame for the current mode: the whole screen (fullscreen) or a centered
    /// floating panel (compact). Used for both initial placement and screen changes.
    private func targetFrame(on screen: NSScreen) -> NSRect {
        guard sessionMode == .compact else { return screen.frame }
        // P2 (ruling A5): the scaled branch — user-tunable percentage, a 4×3 grid floor
        // that rises with the icon size, and NO 960×680 hard cap any more. Deliberate
        // behaviour change whose scope is wider than "large screens" (final-review
        // correction): the old cap bound on any visibleFrame over ~1333×829pt, which
        // includes every modern built-in laptop display — those users get a ~13% larger
        // default panel; the new window-size slider is the dial for that.
        return LaunchpadLayoutMath.compactFrame(
            visible: screen.visibleFrame,
            scalePercent: sessionCompactScale,
            metrics: sessionMetrics,
            legacyCap: false
        )
    }

    // MARK: - Dismissal (Codex P0 #4)

    /// Where an Esc keystroke lands — the design §2.4 ladder: cancel the rename (route the
    /// event to the field editor) → close the open folder → close the launcher. Static and
    /// value-typed so the whole ladder is unit-testable without a window or a key event.
    enum EscapeResolution: Equatable {
        case routeToFieldEditor, closeFolder, closeOverlay
    }

    static func resolveEscape(firstResponder: NSResponder?,
                              isFolderOpen: Bool,
                              carryLive: Bool) -> EscapeResolution {
        // Mid-IME-composition Esc must cancel the candidate window: let the event through
        // to the field editor (Codex P1). Its own `cancelOperation` handles the rest.
        if let editor = firstResponder as? NSTextView, editor.hasMarkedText() {
            return .routeToFieldEditor
        }
        // A folder rename being edited owns Esc — the rename field editor's `cancelOperation`
        // restores the original name. Checked BEFORE the folder rung so cancelling the edit
        // never closes the folder underneath it.
        if LaunchpadFolderRenameField.shouldRouteEsc(to: firstResponder) {
            return .routeToFieldEditor
        }
        // Middle rung: an open folder closes before the launcher does. Skipped while a carry
        // session is live (carrying OR settling) — Esc mid-carry keeps the historical
        // abort-everything semantics (`close()` → `cancelCarry`), and during an eject the
        // panel is already zoomed shut anyway.
        if isFolderOpen, !carryLive {
            return .closeFolder
        }
        return .closeOverlay
    }

    /// Close on Esc / app deactivation only — NOT on every key/main loss. IME candidate
    /// windows, permission dialogs and Space switches steal key status and must not
    /// dismiss the launcher. Background clicks are handled inside the SwiftUI content.
    ///
    /// Both observers are bound to `session` (the window live when they were installed):
    /// if the user closes and instantly reopens, a queued notification from the old
    /// session no longer matches `self.window` and is dropped (Codex P1 #2). The search
    /// field's own `cancelOperation` is a second Esc path when the field is first
    /// responder, covering activation-failure cases (Codex P2 #4).
    private func installDismissHandlers(for session: LaunchpadOverlayWindow) {
        tokens.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            // Esc — resolved through the §2.4 ladder rule below (unit-tested): cancel an
            // IME composition / a live rename first, then close an open folder, and only
            // then the launcher itself.
            if event.keyCode == 53 {
                guard let self else { return event }
                switch Self.resolveEscape(firstResponder: self.window?.firstResponder,
                                          isFolderOpen: self.dragCoordinator.isFolderOpen,
                                          carryLive: self.dragCoordinator.carrySession != nil) {
                case .routeToFieldEditor:
                    return event
                case .closeFolder:
                    // The grid view owns the close choreography (commit a live rename, zoom
                    // out), so publish a request instead of mutating SwiftUI state from here.
                    self.dragCoordinator.requestFolderClose()
                    return nil
                case .closeOverlay:
                    self.close()
                    return nil
                }
            }
            return event
        }
        tokens.screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let win = self.window, win === session else { return }
                win.setFrame(self.targetFrame(on: self.activeScreen()), display: true)
            }
        }
        tokens.resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.window === session else { return }
                // The user switched away (Cmd+Tab / clicked another app): don't yank focus
                // back to the previously-frontmost app and fight their intent. Only the
                // explicit Esc / background-click paths restore focus.
                self.close(restoringFocus: false)
            }
        }
        // Another window of *this* app took key focus (e.g. the Settings window opened, or the
        // user clicked it behind a compact panel). The app stays active, so `didResignActive`
        // never fires — dismiss here instead, but ONLY when an ordinary titled window takes key.
        // Menus, IME candidate windows and alert panels aren't titled, so right-click menus and
        // CJK composition won't close the launcher.
        tokens.resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: session, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.window === session, !self.isTearingDown else { return }
                if let key = NSApp.keyWindow, key !== session,
                   !(key is NSPanel), key.styleMask.contains(.titled) {
                    self.close(restoringFocus: false)
                }
            }
        }
    }

    private func removeDismissHandlers() {
        tokens.removeAll()
    }
}
