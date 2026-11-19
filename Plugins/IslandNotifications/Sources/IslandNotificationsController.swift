import AppKit
import Combine
import ApplicationServices
import MacToolsPluginKit
import OSLog
import SwiftUI
import UserNotifications

/// A NotificationCenter window MacTools moved off screen. `taken`: the island shows its banner.
struct IslandMovedWindow: @unchecked Sendable {
    let window: AXUIElement
    let original: CGPoint
    let since: TimeInterval
    var taken: Bool
}

@MainActor
final class IslandNotificationsController {
    var onStateChange: (() -> Void)?
    private(set) var enabled: Bool
    private(set) var trusted = AXIsProcessTrusted()
    private(set) var hasDisplay = false
    private var active = false
    private let storage: any PluginStorage
    private let localization: PluginLocalization
    private let observer = IslandNotificationObserver()
    private let activities = IslandLiveActivityObserver()
    private var placement = IslandLiveActivityPlacement.camera
    private var preparing = false
    private var fallingBack = false
    private let presenter: IslandNotificationPresenter
    private let logger = Logger(subsystem: "MacTools.IslandNotifications", category: "lifecycle")
    private var queue = IslandNotificationQueue<IslandNotification>()
    private let claudeTurns = IslandClaudeTurnWatcher()
    /// What the panel's Notifications list shows.
    let history = IslandNotificationHistory()
    /// The Notifications widget's height in panel rows: it fits its list, up to a limit, then scrolls.
    private(set) var historySpan = PluginPanelWidgetLayoutMetrics.default.heightSpan(fittingContentHeight: IslandHistoryLayout.emptyHeight)
    /// MacTools is opening Notification Centre out of sight for the list: its opening isn't the user's.
    private var centerPressing = false
    private var currentShownAt: TimeInterval = 0
    private var replaceWork: DispatchWorkItem?
    private var lastRescan: TimeInterval = 0
    /// Every banner already turned into a card. macOS keeps a banner in its (hidden) window for a
    /// while after the card is gone; re-reading the window must not show it again.
    private var seen: [IslandNotification] = []
    private var loggedHistoryAccess = false
    private var hidden: [IslandNotification] = []
    private var moved: [IslandMovedWindow] = []
    /// Notification Centre's own panel is open.
    private var centerOpen = false
    /// How long a window moved on arrival may wait for its banner before it goes back.
    private static let prehideGrace: TimeInterval = 0.5
    private var ignored: [IslandAXElement] = []
    private var receiving: [IslandAXElement] = []
    /// Windows whose next read adopts what it finds: banners already there when MacTools started,
    /// or that came while a read was skipped. Their arrival time is unknown.
    private var adopting: [IslandAXElement] = []
    private var pending: [IslandAXElement] = []
    private var generation = 0
    private var ready = false
    private var lifetime: IslandNotificationLifetime?
    private var closing = false
    private var anchor: CGRect?
    private var trustTimer: Timer?
    private var hoverTimer: Timer?
    private var lifetimeTimer: Timer?
    private var blocked = false
    private var localeSubscription: AnyCancellable?
    private var appObservers: [NSObjectProtocol] = []
    private var workspaceObserver: NSObjectProtocol?

    init(storage: any PluginStorage, localization: PluginLocalization) {
        self.storage = storage
        self.localization = localization
        enabled = storage.bool(forKey: "enabled")
        claudeCards = storage.bool(forKey: "claudeCards")
        presenter = IslandNotificationPresenter(localization: localization)
        let lines = storage.integer(forKey: "previewLines")
        if IslandNotificationPresenter.previewLineRange.contains(lines) { presenter.previewLines = lines }
        activities.onChange = { [weak self] in self?.activityChanged() }
        observer.onWindow = { [weak self] in self?.receive($0) }
        observer.onFocusChanged = { [weak self] in self?.centerFocusChanged() }
        observer.onRemoved = { [weak self] element in
            self?.hidden.removeAll { CFEqual($0.element, element.value) }
            self?.seen.removeAll { CFEqual($0.element, element.value) }
            self?.ignored.removeAll { CFEqual($0.value, element.value) }
        }
        presenter.onHoverChange = { [weak self] in self?.updateLifetime() }
        presenter.onReply = { [weak self] text in self?.reply(text) }
        presenter.onOutsideClick = { [weak self] in
            guard let self, !self.presenter.isSendingReply else { return }
            self.finishCurrent(dismissNative: false, reason: "outside click")
        }
        claudeTurns.onTurn = { [weak self] turn in self?.receive(turn) }
        localeSubscription = PluginRuntimeLocalization.source.$revision.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.presenter.refreshLocalization() }
        }
    }

    func activate() {
        guard !active else { return }
        active = true
        for name in [NSApplication.didChangeScreenParametersNotification, NSApplication.didBecomeActiveNotification, NSApplication.willTerminateNotification] {
            appObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let isTermination = note.name == NSApplication.willTerminateNotification
                MainActor.assumeIsolated {
                    if isTermination { self?.deactivate() }
                    else { self?.refresh() }
                }
            })
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleURL?.path == "/System/Library/CoreServices/NotificationCenter.app" || IslandLiveActivityObserver.isMenuBarAgent(app) else { return }
            MainActor.assumeIsolated { self?.refresh(); self?.activityChanged() }
        }
        refresh()
    }

    var previewLines: Int { presenter.previewLines }

    func setPreviewLines(_ value: Int) {
        guard IslandNotificationPresenter.previewLineRange.contains(value) else { return }
        presenter.previewLines = value; storage.set(value, forKey: "previewLines")
        onStateChange?()
    }

    /// Off by default: reading Claude Code's session logs is its own choice.
    private(set) var claudeCards = false
    private var claudePosts = IslandClaudePosts()

    func setClaudeCards(_ value: Bool) {
        claudeCards = value; storage.set(value, forKey: "claudeCards")
        if value { IslandClaudeNotice.requestAuthorization() }
        refresh(); onStateChange?()
    }

    func setEnabled(_ value: Bool) {
        enabled = value; storage.set(value, forKey: "enabled")
        refresh(); onStateChange?()
    }

    func refresh() {
        trusted = AXIsProcessTrusted()
        let nextAnchor = Self.notchAnchor()
        hasDisplay = nextAnchor != nil
        if nextAnchor != anchor { stop(); anchor = nextAnchor }
        guard active, enabled else {
            stop(); onStateChange?(); return
        }
        updateTimer()
        guard trusted, anchor != nil else { stop(); onStateChange?(); return }
        // Claude's session logs are read only while Claude chat cards are on.
        if claudeCards { claudeTurns.start() } else { claudeTurns.stop() }
        if !loggedHistoryAccess {
            loggedHistoryAccess = true
            let logger = logger
            Task.detached(priority: .utility) {
                logger.notice("messages history readable=\(IslandMessagesChat.isAvailable, privacy: .public)")
            }
        }
        if observer.pid == nil {
            observer.start(onAttached: { [weak self] in self?.recoverStrandedWindows() }, onExit: { [weak self] in
                guard let self else { return }
                self.stop()
                self.refresh()
            })
        }
        onStateChange?()
    }

    private func recoverStrandedWindows() {
        guard let anchor, let normalPosition = Self.normalPosition(for: anchor) else { return }
        let desktopMinX = Self.desktopMinX
        let generation = generation
        let logger = logger
        Task {
            let windows = await observer.windows()
            await IslandAX.run {
                for window in windows {
                    let snapshot = IslandAXWindowSnapshot(window: window.value)
                    if IslandMovePolicy.allowsRecovery(position: IslandAX.position(window.value), desktopMinX: desktopMinX,
                                                       notificationCount: snapshot.groups.count,
                                                       hasUnexpectedContent: snapshot.unexpected, complete: snapshot.complete) {
                        if IslandAX.move(window.value, to: normalPosition) { logger.info("Recovered a stranded notification window") }
                        else { logger.error("Could not recover a stranded notification window") }
                    }
                }
            }
            guard self.generation == generation else { return }
            ready = true
            // Notifications already on screen when MacTools starts become cards too. macOS keeps them
            // in one window with any that arrive later, so skipping them would leave those native.
            for window in windows { receive(window, adopting: true) }
        }
    }

    private func updateTimer() {
        let waitingForTrust = active && enabled && !trusted
        if !waitingForTrust { trustTimer?.invalidate(); trustTimer = nil }
        else if trustTimer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            timer.tolerance = 0.2
            RunLoop.main.add(timer, forMode: .common)
            trustTimer = timer
        }
        let hasCards = queue.current != nil || !queue.waiting.isEmpty
        guard active, enabled, trusted, anchor != nil, hasCards else {
            hoverTimer?.invalidate(); hoverTimer = nil
            return
        }
        guard hoverTimer == nil else { return }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.04
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    private func updateLifetime() {
        lifetimeTimer?.invalidate(); lifetimeTimer = nil
        let hovered = presenter.isHovered
        guard !closing, queue.current != nil else { return }
        // The pointer left or the card was released: a waiting newer notification can take over.
        replaceCurrentIfIdle()
        guard !closing else { return }
        // A held card (swiped down / opened) stays until dismissed; unsent reply text, typing or
        // sending keep a card up too.
        let paused = blocked || hovered || presenter.isHeld || presenter.isReplying || presenter.hasDraft
        if lifetime?.advance(to: ProcessInfo.processInfo.systemUptime, paused: paused) == true {
            finishCurrent(dismissNative: false, reason: "timed out")
            return
        }
        guard !paused, let remaining = lifetime?.remaining else { return }
        let timer = Timer(timeInterval: remaining, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateLifetime() }
        }
        RunLoop.main.add(timer, forMode: .common)
        lifetimeTimer = timer
    }

    func deactivate() {
        active = false
        for token in appObservers { NotificationCenter.default.removeObserver(token) }
        appObservers.removeAll()
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        workspaceObserver = nil
        stop()
    }

    isolated deinit { deactivate() }

    private func stop() {
        generation += 1; ready = false; receiving.removeAll(); pending.removeAll(); adopting.removeAll()
        replaceWork?.cancel(); replaceWork = nil
        observer.stop()
        claudeTurns.stop()
        activities.stop()
        preparing = false; fallingBack = false; placement = .camera
        presenter.hide()
        // Every window MacTools moved goes back now: with no card on screen its banner is shown natively.
        IslandAX.restoreMovedWindows(moved)
        IslandAX.restorePersistentWindows(hidden, desktopMinX: Self.desktopMinX)
        moved.removeAll(); centerOpen = false
        // `seen` survives a restart of the pipeline so banners already shown aren't shown again;
        // its entries are pruned once macOS removes them.
        self.hidden.removeAll(); ignored.removeAll(); queue.removeAll()
        lifetimeTimer?.invalidate(); lifetimeTimer = nil
        lifetime = nil; closing = false; blocked = false
        updateTimer()
    }

    /// A Claude chat finished a turn while the user is elsewhere. Claude posts its own notices without
    /// a banner, so MacTools posts one and its banner becomes the card: MacTools' notification
    /// settings, Focus and hidden previews then apply as for any app.
    private func receive(_ turn: IslandClaudeTurnWatcher.Turn) {
        guard active, enabled, claudeCards, trusted, anchor != nil,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier != IslandClaudeReply.bundleIdentifier,
              !claudePosts.isWaiting(turn.chat, message: turn.message) else { return }
        let requestID = UUID().uuidString
        // Waiting before the request goes out, so a quick banner finds it; claiming it also needs
        // macOS to have delivered this request (see makeNotification).
        claudePosts.add(turn.chat, message: turn.message, posted: IslandClaudeNotice.postedText(turn),
                        requestID: requestID, at: ProcessInfo.processInfo.systemUptime)
        Task {
            if await !IslandClaudeNotice.post(turn, requestID: requestID) { claudePosts.remove(requestID: requestID) }
        }
    }

    /// A banner, or MacTools' own notice of a Claude turn: then the card is that chat's, with the
    /// whole reply (the banner showed its preview) and a reply field. Only MacTools' own banner,
    /// showing the posted text, for one waiting turn whose request macOS delivered, counts; any
    /// other banner keeps its own content.
    private func makeNotification(_ group: IslandAXWindowSnapshot.Group, window: AXUIElement,
                                  original: CGPoint, adopted: Bool) async -> IslandNotification {
        let fromMacTools = group.app.map { IslandClaudeNotice.ownNames.contains($0) } ?? false
        let waiting = !claudePosts.posts.isEmpty
        let post = claudePosts.take(title: group.title, body: group.body, fromMacTools: fromMacTools,
                                    at: ProcessInfo.processInfo.systemUptime)
        let delivered = if let post { await IslandClaudeNotice.isDelivered(post.requestID) } else { false }
        if waiting {
            logger.notice("claude banner fromMacTools=\(fromMacTools, privacy: .public) matched=\(post != nil, privacy: .public) delivered=\(delivered, privacy: .public)")
        }
        if let post, delivered {
            let notification = IslandNotification(element: group.element, window: window, originalPosition: original,
                                                  style: group.style, title: post.chat.title, body: post.message,
                                                  identityHints: [IslandClaudeReply.bundleIdentifier] + group.hints)
            notification.claudeChat = post.chat
            notification.claudeRequestID = post.requestID
            return notification
        }
        let notification = IslandNotification(element: group.element, window: window, originalPosition: original,
                                              style: group.style, title: group.title, body: group.body,
                                              identityHints: group.hints, lineCount: group.lines)
        notification.arrivalConfirmed = !adopted
        return notification
    }

    /// `adopting`: this window may hold banners that came while the island wasn't reading it.
    private func receive(_ window: IslandAXElement, adopting adopt: Bool = false) {
        if adopt, !adopting.contains(where: { CFEqual($0.value, window.value) }) { adopting.append(window) }
        guard active, ready, !fallingBack else { return }
        guard !centerPressing else {
            // Banners arriving now are read later, when their arrival time is no longer known.
            if !adopting.contains(where: { CFEqual($0.value, window.value) }) { adopting.append(window) }
            return
        }
        if receiving.contains(where: { CFEqual($0.value, window.value) }) {
            if !pending.contains(where: { CFEqual($0.value, window.value) }) { pending.append(window) }
            return
        }
        receiving.append(window)
        let generation = generation
        Task {
            defer {
                if self.generation == generation {
                    receiving.removeAll { CFEqual($0.value, window.value) }
                    if pending.contains(where: { CFEqual($0.value, window.value) }) {
                        pending.removeAll { CFEqual($0.value, window.value) }
                        receive(window)
                    }
                }
            }
            // While Notification Centre's own panel is open its list is not new banners: hands off.
            // A failed query is unknown, never "closed".
            let focus = await observer.centerFocus()
            guard self.generation == generation, active else { return }
            guard focus == false else {
                // Not read now: what this window holds is read later, its arrival time unknown.
                if !adopting.contains(where: { CFEqual($0.value, window.value) }) { adopting.append(window) }
                if focus == true { await centerOpened() }
                return
            }
            centerOpen = false
            // Hide a new banner window at once, before reading it, so the banner never draws its first
            // frames natively. A window the island doesn't take comes back (see settleUntaken).
            let offscreen = Self.offscreenPosition
            let early = await IslandAX.run { () -> IslandAX.OffScreenMove? in
                guard AXIsProcessTrusted(), IslandAX.string(window.value, kAXRoleAttribute) == kAXWindowRole,
                      IslandAX.string(window.value, kAXSubroleAttribute) == "AXSystemDialog" else { return nil }
                return IslandAX.moveOffScreen(window.value, to: offscreen)
            }
            switch early {
            case .moved(let from)?:
                remember(window.value, original: from, taken: false)
                guard self.generation == generation, active, !fallingBack else { await release(window.value); return }
                try? await Task.sleep(for: .milliseconds(30))
            case .failed?:
                logger.error("Could not hide a new notification window; it stays native")
                return
            case .alreadyOff?, nil:
                break
            }
            let snapshot = await IslandAX.run { IslandAXWindowSnapshot(window: window.value) }
            // Check live hardware/permission immediately before submitting the mutation.
            guard self.generation == generation, active else { return }
            let currentTrust = AXIsProcessTrusted()
            let nextAnchor = Self.notchAnchor()
            if currentTrust != trusted || nextAnchor != anchor {
                logger.notice("receive refresh trust=\(currentTrust, privacy: .public) anchorChanged=\(nextAnchor != self.anchor, privacy: .public)")
                refresh(); return
            }
            await pruneStaleElements()
            guard self.generation == generation else { return }
            if snapshot.complete, !snapshot.unexpected {
                hidden.removeAll { item in
                    item.style == .temporary && CFEqual(item.window, window.value) &&
                        !snapshot.groups.contains { CFEqual($0.element, item.element) }
                }
            }
            let ignoredHit = snapshot.groups.contains { group in ignored.contains { CFEqual($0.value, group.element) } }
            let taken = movedIndex(window.value).map { moved[$0].taken } ?? false
            if !taken, snapshot.unexpected || !snapshot.complete {
                logger.notice("banner left native groups=\(snapshot.groups.count, privacy: .public) complete=\(snapshot.complete, privacy: .public) unexpected=\(snapshot.unexpected, privacy: .public) hidden=\(self.hidden.count, privacy: .public) seen=\(self.seen.count, privacy: .public)")
            }
            guard let nextAnchor, let normalPosition = Self.normalPosition(for: nextAnchor),
                  IslandMovePolicy.allowsMove(enabled: enabled, trusted: currentTrust, hasNotch: true,
                                             notificationCount: snapshot.groups.count,
                                             hasUnexpectedContent: snapshot.unexpected, complete: snapshot.complete),
                  !ignoredHit else {
                // A new window the island can't read comes straight back on screen; one still filling in
                // gets until the end of the grace. A window already taken stays hidden: while a banner
                // is being removed macOS strips its subrole, and putting that back would flash it.
                await settleUntaken(window, definitive: snapshot.unexpected || ignoredHit || !enabled)
                return
            }
            let adopted = adopting.contains { CFEqual($0.value, window.value) }
            let fresh = snapshot.groups.filter { group in
                !hidden.contains { CFEqual($0.element, group.element) } && !seen.contains { CFEqual($0.element, group.element) }
            }
            // macOS shows one banner per app and updates it in place when a newer notification from
            // that app arrives. A held banner whose text changed is that newer notification.
            var replacements: [IslandNotification] = []
            for group in snapshot.groups {
                guard let old = hidden.first(where: { CFEqual($0.element, group.element) })
                        ?? seen.last(where: { CFEqual($0.element, group.element) }),
                      old.title != group.title || old.body != group.body else { continue }
                let original = movedIndex(window.value).map { moved[$0].original } ?? old.originalPosition
                let notification = await makeNotification(group, window: window.value, original: original, adopted: adopted)
                guard self.generation == generation, !centerOpen else { return }
                notification.label = group.label
                notification.resolveIdentity()
                hidden.removeAll { $0 === old }
                seen.removeAll { $0 === old }
                hidden.append(notification)
                seen.append(notification)
                dropWaiting { $0 === old }
                record(notification)
                replacements.append(notification)
            }
            if !replacements.isEmpty {
                if let index = movedIndex(window.value) { moved[index].taken = true }
                enqueue(replacements)
            }
            // Read in full: later banners in this window are seen as they come.
            if snapshot.complete, !snapshot.unexpected, fresh.isEmpty { adopting.removeAll { CFEqual($0.value, window.value) } }
            guard !fresh.isEmpty else {
                // Nothing new for the island in a window moved on arrival: it goes straight back.
                if replacements.isEmpty { await settleUntaken(window, definitive: true) }
                return
            }
            // Read before any mutation: a failed or expanded system activity keeps
            // the native banner visible. Never rely on an idle geometry cache.
            let nextPlacement = await activities.refresh(anchor: nextAnchor)
            guard self.generation == generation, !fallingBack else { return }
            guard nextPlacement != .native else {
                // Nothing held yet: just give this banner back. Otherwise every card goes native.
                if hidden.isEmpty { await release(window.value) } else { await fallBackToNative() }
                return
            }
            // A visible card keeps its place (and any typed reply); the next card uses the new one.
            placement = nextPlacement
            let prior = movedIndex(window.value).map { moved[$0].original }
                ?? hidden.first(where: { CFEqual($0.window, window.value) })?.originalPosition
            let desktopMinX = Self.desktopMinX
            // Confirmed move: a window that ignores it, or still lands on a display, goes back and
            // no card is made, so the native banner and a card never show together.
            let result = await IslandAX.run { () -> IslandAX.OffScreenMove in
                guard AXIsProcessTrusted() else { return .failed }
                return IslandAX.moveOffScreen(window.value, to: offscreen)
            }
            let original: CGPoint
            switch result {
            case .moved(let from): original = from
            case .alreadyOff(let at):
                original = IslandMovePolicy.originalPosition(position: at, prior: prior,
                                                             desktopMinX: desktopMinX, normalPosition: normalPosition)
            case .failed:
                logger.error("A notification window did not leave the screen; it stays native")
                await release(window.value)
                return
            }
            guard self.generation == generation, !fallingBack else {
                // Disable/display changes or native fallback can race an in-flight move. Roll it back.
                _ = await IslandAX.run { IslandAX.restore(window.value, to: original) }
                return
            }
            var made: [(IslandAXWindowSnapshot.Group, IslandNotification)] = []
            for group in fresh {
                made.append((group, await makeNotification(group, window: window.value, original: original, adopted: adopted)))
            }
            // Confirming a Claude notice's delivery is a short wait; anything can have changed.
            guard self.generation == generation, !fallingBack, !centerOpen else {
                _ = await IslandAX.run { IslandAX.restore(window.value, to: original) }
                return
            }
            remember(window.value, original: original, taken: true)
            var arrivals: [IslandNotification] = []
            adopting.removeAll { CFEqual($0.value, window.value) }
            for (group, notification) in made {
                notification.label = group.label
                hidden.append(notification)
                seen.append(notification)
                notification.resolveIdentity()
                record(notification)
                arrivals.append(notification)
            }
            await observer.observeRemoval(of: fresh.map { IslandAXElement(value: $0.element) })
            guard self.generation == generation else { return }
            enqueue(arrivals)
        }
    }

    // MARK: Windows MacTools moved off screen
    //
    // Every NotificationCenter window MacTools moved is recorded with where it was, so it can always
    // go back: when its banner isn't for the island, when Notification Centre opens, on fallback to
    // native banners and on stop. A window moved on arrival ("untaken") gets `prehideGrace` for its
    // banner to fill in; one the island took stays off screen until macOS removes it.

    private func movedIndex(_ window: AXUIElement) -> Int? { moved.firstIndex { CFEqual($0.window, window) } }

    private func remember(_ window: AXUIElement, original: CGPoint, taken: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        if let index = movedIndex(window) {
            moved[index] = IslandMovedWindow(window: window, original: original, since: taken ? moved[index].since : now,
                                             taken: taken || moved[index].taken)
        } else {
            moved.append(IslandMovedWindow(window: window, original: original, since: now, taken: taken))
        }
    }

    /// Puts a moved window back and drops the cards made from it: its banners are visible again.
    private func release(_ window: AXUIElement) async {
        guard let index = movedIndex(window) else { return }
        let record = moved.remove(at: index)
        let restored = await IslandAX.run { IslandAX.restore(record.window, to: record.original) }
        if !restored { logger.error("Could not put back a notification window") }
        dropWaiting { CFEqual($0.window, window) }
        hidden.removeAll { CFEqual($0.window, window) }
        if let current = queue.current, current.claudeChat == nil, CFEqual(current.window, window) {
            finishCurrent(dismissNative: false, reason: "banner back to native")
        }
    }

    /// A window moved on arrival that the island didn't take goes back: at once when nothing in it is
    /// for the island, otherwise when the grace ends (its banner may still be filling in).
    private func settleUntaken(_ window: IslandAXElement, definitive: Bool) async {
        guard let index = movedIndex(window.value), !moved[index].taken else { return }
        let waited = ProcessInfo.processInfo.systemUptime - moved[index].since
        if definitive || waited >= Self.prehideGrace { await release(window.value); return }
        let generation = generation
        Task {
            try? await Task.sleep(for: .seconds(Self.prehideGrace - waited + 0.02))
            guard self.generation == generation, let index = movedIndex(window.value), !moved[index].taken else { return }
            receive(window)
        }
    }

    /// Notification Centre's panel opened: every moved window goes back (its list may live in the
    /// same window as the banners) and cards close, like banners do when the centre opens on iPhone.
    private func centerOpened() async {
        guard !centerOpen, !centerPressing else { return }
        centerOpen = true
        logger.notice("Notification Centre opened; native windows restored")
        replaceWork?.cancel(); replaceWork = nil
        lifetimeTimer?.invalidate(); lifetimeTimer = nil
        presenter.hide()
        queue.removeAll(); hidden.removeAll()
        lifetime = nil; closing = false
        let records = moved
        moved.removeAll()
        await IslandAX.run {
            for record in records where !IslandAX.restore(record.window, to: record.original) {
                Logger(subsystem: "MacTools.IslandNotifications", category: "lifecycle")
                    .error("Could not put back a notification window for Notification Centre")
            }
        }
        updateTimer()
    }

    private func centerFocusChanged() {
        guard active, ready, !centerPressing else { return }
        Task {
            let focus = await observer.centerFocus()
            if focus == true { await centerOpened() } else if focus == false { centerOpen = false }
        }
    }

    private func pruneStaleElements() async {
        let hidden = hidden
        let ignored = ignored
        let seen = seen
        let generation = generation
        let moved = moved
        let (invalid, invalidIgnored, invalidSeen, invalidMoved) = await IslandAX.run {
            (hidden.filter { IslandAX.isInvalid($0.element) }, ignored.filter { IslandAX.isInvalid($0.value) },
             seen.filter { IslandAX.isInvalid($0.element) }, moved.filter { IslandAX.isInvalid($0.window) })
        }
        guard self.generation == generation else { return }
        self.moved.removeAll { item in invalidMoved.contains { CFEqual($0.window, item.window) } }
        self.seen.removeAll { item in invalidSeen.contains { $0 === item } }
        self.hidden.removeAll { item in invalid.contains { $0 === item } }
        self.ignored.removeAll { item in invalidIgnored.contains { CFEqual($0.value, item.value) } }
    }

    // MARK: Several notifications (Apple: one banner at a time, the newest wins)
    //
    // - A new notification replaces a small card that is just sitting there, once that card has been
    //   up for at least 1 s (so a burst doesn't strobe). Older temporary ones that never got shown are
    //   skipped; they stay in Notification Centre like any other.
    // - The pointer on the card, an open or held card, typing or sending: nothing is interrupted.
    //   The newest arrival waits; when the card closes it shows only if it's still fresh (6 s).
    // - Persistent alerts are never skipped or replaced; they wait their turn.
    // - No count on the card: neither iPhone nor Mac banners show one. Grouped stacks live in
    //   Notification Centre, which is left untouched.

    private func enqueue(_ arrivals: [IslandNotification]) {
        guard !arrivals.isEmpty else { return }
        dropWaiting { $0.style == .temporary }
        for notification in arrivals { queue.append(notification) }
        // Only the newest temporary arrival of a batch is worth showing.
        let newest = arrivals.last
        dropWaiting { $0.style == .temporary && $0 !== newest }
        replaceCurrentIfIdle()
        presentNext()
    }

    /// Skipped notifications stay in Notification Centre; temporary banners expire on their own.
    private func dropWaiting(where shouldDrop: (IslandNotification) -> Bool) {
        let dropped = queue.removeWaiting(where: shouldDrop)
        hidden.removeAll { item in dropped.contains { $0 === item } }
    }

    /// The card is in use: pointer on it, opened or held, typing, a draft, or a reply sending.
    private var presenterIsBusy: Bool {
        presenter.isHovered || presenter.isHeld || presenter.isReplying || presenter.hasDraft || presenter.isSendingReply
    }

    /// Replaces an idle small card with the newest waiting notification (after its first second).
    private func replaceCurrentIfIdle() {
        replaceWork?.cancel(); replaceWork = nil
        guard let current = queue.current, !closing, current.style == .temporary, !presenterIsBusy,
              queue.waiting.contains(where: { $0.style == .temporary }) else { return }
        let shownFor = ProcessInfo.processInfo.systemUptime - currentShownAt
        guard shownFor >= 1 else {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.replaceCurrentIfIdle() }
            }
            replaceWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (1 - shownFor), execute: work)
            return
        }
        finishCurrent(dismissNative: false, reason: "replaced by newer")
    }

    private func presentNext(checkBlocking: Bool = true) {
        guard let anchor, !closing, !preparing, !fallingBack, queue.current == nil else { updateTimer(); return }
        if checkBlocking { blocked = hoverPanelVisible(over: anchor) }
        guard !blocked, !queue.waiting.isEmpty else { updateTimer(); return }
        preparing = true
        let generation = generation
        Task {
            let nextPlacement = await activities.refresh(anchor: anchor)
            guard self.generation == generation, !fallingBack else { return }
            preparing = false
            guard nextPlacement != .native else { await fallBackToNative(); return }
            placement = nextPlacement
            blocked = hoverPanelVisible(over: anchor)
            // After an open or held card, only a fresh arrival is still worth showing.
            let now = ProcessInfo.processInfo.systemUptime
            dropWaiting { $0.style == .temporary && now - $0.arrivedAt > 6 }
            guard let notification = queue.presentNext(blocked: blocked) else { updateTimer(); return }
            lifetime = IslandNotificationLifetime(style: notification.style, now: ProcessInfo.processInfo.systemUptime)
            show(notification, anchor: anchor)
            presenter.announce(notification)
            updateLifetime()
            updateTimer()
        }
    }

    private func show(_ notification: IslandNotification, anchor: CGRect) {
        let activity: CGRect?
        if case .split(let frame) = placement { activity = frame } else { activity = nil }
        currentShownAt = ProcessInfo.processInfo.systemUptime
        presenter.present(notification, anchor: anchor, activity: activity, waiting: 0,
                          replyable: notification.canReply,
                          onOpen: { [weak self] in self?.openCurrent() },
                          onClose: { [weak self] in self?.finishCurrent(dismissNative: true, reason: "closed") })
    }

    private func activityChanged() {
        // No AX traversal or polling while idle. The next banner always refreshes.
        guard active, !fallingBack, !closing, let anchor, queue.current != nil else { return }
        let generation = generation
        Task {
            let next = await activities.refresh(anchor: anchor)
            guard self.generation == generation, !fallingBack, !closing else { return }
            guard next != .native else { await fallBackToNative(); return }
            // A card that is on screen keeps the place it appeared in: pausing or starting music
            // must not flip it between the camera and the Live Activity. The next card re-reads it.
            guard presenter.window == nil else { return }
            placement = next
            // A Live Activity appearing or ending moves the card; keep it expanded if it was.
            if let current = queue.current, !blocked { show(current, anchor: anchor) }
        }
    }

    private func fallBackToNative() async {
        guard !fallingBack else { return }
        fallingBack = true
        logger.notice("falling back to native banners hidden=\(self.hidden.count, privacy: .public)")
        presenter.hide()
        lifetimeTimer?.invalidate(); lifetimeTimer = nil
        let records = moved
        let notifications = hidden
        let generation = generation
        let desktopMinX = Self.desktopMinX
        await IslandAX.run {
            IslandAX.restoreMovedWindows(records)
            // Windows moved before they were recorded (none normally) go to their saved position.
            for item in notifications where !records.contains(where: { CFEqual($0.window, item.window) }) {
                if let position = IslandAX.position(item.window), position.x < desktopMinX - 5000 {
                    _ = IslandAX.move(item.window, to: item.originalPosition)
                }
            }
        }
        guard self.generation == generation else { return }
        moved.removeAll()
        // Reattach. Recovery re-reads the windows; while the placement is native, each banner found
        // is simply left (or put back) on screen, since nothing is held.
        stop()
        refresh()
    }

    private func reply(_ text: String) {
        guard !closing, let notification = queue.current else { return }
        presenter.setReplySending()
        updateLifetime()
        let generation = generation
        Task {
            let outcome = if let chat = notification.claudeChat {
                await IslandClaudeReply.send(text, to: chat)
            } else {
                await Self.replyInMessages(text, to: notification)
            }
            guard self.generation == generation, queue.current === notification, !closing else { return }
            logger.notice("reply outcome=\(String(describing: outcome), privacy: .public)")
            switch outcome {
            case .sent:
                // The check shows for a moment, then the card folds straight back into the island.
                // Typing stops now; the keyboard returns to the app once the card has gone, so the
                // card never blinks out and back while it closes.
                presenter.showReplySent()
                presenter.stopEditing()
                try? await Task.sleep(for: .milliseconds(450))
                guard self.generation == generation, queue.current === notification else { return }
                finishCurrent(dismissNative: true, reason: "replied")
                clearReplied(notification)
            case .noConversation:
                presenter.showReplyError(localization.string("reply.error.conversation", defaultValue: "找不到这个对话。点按卡片以打开“信息”。"))
            case .notAuthorized:
                presenter.showReplyError(localization.string("reply.error.permission", defaultValue: "请在“隐私与安全性 > 自动化”中允许 MacTools 控制“信息”。"))
            case .claudeDraft:
                presenter.showReplyError(localization.string("reply.error.claudeDraft", defaultValue: "这个对话在 Claude 中有未发送的文字。点按卡片以打开。"))
            case .ambiguousChat:
                presenter.showReplyError(localization.string("reply.error.duplicateChat", defaultValue: "有多个 Claude 对话使用这个名称。点按卡片以打开 Claude。"))
            case .failed:
                presenter.showReplyError(localization.string("reply.error.failed", defaultValue: "无法发送。点按卡片以打开应用。"))
            }
            updateLifetime()
        }
    }

    /// The exact conversation comes from Messages' history; the message may land there a moment
    /// after its banner. No match (or no access) means no reply, never a guess. Until the banner's
    /// own message has surely been written (`settledAfter`), only messages from around its arrival
    /// count; after that the whole window, where a second conversation with the same text makes the
    /// match ambiguous. Only a banner whose arrival MacTools saw is looked up at all.
    private static func messagesConversation(body: String, lineCount: Int, arrivedAt arrival: Date) async -> IslandMessagesChat.Lookup {
        let isGroup = lineCount > 2
        var lookup = IslandMessagesChat.Lookup.notFound
        var attempts = 0
        repeat {
            let settled = Date().timeIntervalSince(arrival) >= IslandMessagesChat.settledAfter
            lookup = await Task.detached(priority: .userInitiated) {
                IslandMessagesChat.resolve(body: body, isGroupBanner: isGroup, arrivedAt: arrival, recentOnly: !settled)
            }.value
            guard lookup == .notFound else { break }
            if settled, attempts >= 3 { break }
            attempts += 1
            try? await Task.sleep(for: .milliseconds(500))
        } while true
        return lookup
    }

    /// The card's conversation: found once, then kept, so a reply and an open go to the same one.
    private static func conversation(for notification: IslandNotification) async -> IslandMessagesChat.Lookup {
        guard notification.arrivalConfirmed else { return .notFound }
        if let chat = notification.messagesChat { return .found(chat) }
        let lookup = await messagesConversation(body: notification.body, lineCount: notification.lineCount,
                                                arrivedAt: notification.arrivalDate)
        if case .found(let chat) = lookup { notification.messagesChat = chat }
        return lookup
    }

    private static func replyInMessages(_ text: String, to notification: IslandNotification) async -> IslandReplyOutcome {
        guard case .found(let chat) = await conversation(for: notification) else { return .noConversation }
        return await IslandMessagesReply.send(text, toChat: chat)
    }

    private func openCurrent() {
        guard !closing, let notification = queue.current else { return }
        closing = true
        lifetimeTimer?.invalidate(); lifetimeTimer = nil
        let generation = generation
        if let link = notification.claudeChat?.link {
            // A Claude chat card opens its chat with Claude's own link.
            NSWorkspace.shared.open(link)
            closing = false
            finishCurrent(dismissNative: false, reason: "opened")
            return
        }
        Task {
            // The banner's own click: macOS hands the app this exact notification, so Mail, Spark,
            // Messages and the rest open the item it is about. macOS 27 names it AXPress; earlier
            // releases offered "Show". A banner lives about 5 s; after that only the app can open.
            let opened = await IslandAX.run { () -> Bool in
                IslandAX.perform(kAXPressAction as String, on: notification.element)
                    || IslandAX.perform(anyOf: IslandAX.centerAction("Show"), on: notification.element)
            }
            logger.notice("card open banner=\(opened, privacy: .public)")
            guard self.generation == generation else { return }
            // macOS removes a banner after a few seconds; a Messages card that outlives it still
            // opens its conversation, found the same way replies are (one adopted from before
            // MacTools saw it opens Messages itself).
            if !opened, notification.bundleIdentifier == "com.apple.MobileSMS",
               case .found(let chat) = await Self.conversation(for: notification),
               let url = chat.openURL, NSWorkspace.shared.open(url) {
                // Opened the exact conversation.
            } else if !opened, let url = notification.appURL {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            }
            closing = false
            finishCurrent(dismissNative: !opened, reason: "opened")
        }
    }

    /// Replying from a notification itself marks the chat read, and its notification goes: a reply
    /// sent from a card removes it from the list and from Notification Centre the same way.
    private func clearReplied(_ notification: IslandNotification) {
        let entry = history.entries.first { $0.id == notification.historyID }
        if let entry {
            // On the list's spring, in case the panel is open.
            let motion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : IslandHistoryLayout.motion
            withAnimation(motion) { history.remove(entry) }
        }
        if let requestID = notification.claudeRequestID {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [requestID])
            return
        }
        // An alert is closed with the card (finishCurrent), which takes it out of Notification Centre.
        guard notification.style == .temporary else { return }
        let desktopMinX = Self.desktopMinX
        let generation = generation
        Task {
            // Still a banner, off screen: closing it there takes it out of Notification Centre too.
            let closed = await IslandAX.run { () -> Bool in
                guard let position = IslandAX.position(notification.window), position.x < desktopMinX - 5000 else { return false }
                return IslandAX.perform(anyOf: IslandAX.centerAction("Close"), on: notification.element)
            }
            logger.notice("replied notification closed banner=\(closed, privacy: .public)")
            guard !closed, let entry, entry.centerApp != nil else { return }
            // Filed in Notification Centre by now: its row is cleared there, as the list's Clear does,
            // once the card has folded away.
            try? await Task.sleep(for: .seconds(1))
            guard self.generation == generation else { return }
            let cleared = await inCenter(.clear, entry)
            logger.notice("replied notification cleared inCentre=\(cleared, privacy: .public)")
        }
    }

    // MARK: The panel's Notifications list
    //
    // Opening or clearing an entry acts on its row in Notification Centre, out of sight, as a click
    // there would (see IslandCenterPress); the list and Notification Centre stay one record.

    private func record(_ notification: IslandNotification) {
        // The description is the longest hint: it holds the app, the title and the message.
        let description = notification.identityHints.max { $0.count < $1.count } ?? ""
        let centerApp = notification.claudeChat == nil
            ? IslandNotification.appName(fromDescription: description, title: notification.title, body: notification.body)
            : nil
        let entry = IslandHistoryEntry(date: notification.arrivalDate, appName: notification.appName ?? centerApp ?? notification.title,
                                       centerApp: centerApp, appURL: notification.appURL,
                                       bundleIdentifier: notification.bundleIdentifier,
                                       title: notification.title, body: notification.body,
                                       claudeChat: notification.claudeChat, lineCount: notification.lineCount,
                                       arrivalConfirmed: notification.arrivalConfirmed)
        notification.historyID = entry.id
        history.add(entry)
    }

    func setHistoryContentHeight(_ height: CGFloat) {
        // The list and its "No Notifications" line can both report as the panel opens, the line
        // after the list has measured itself, so what the list holds decides which one counts.
        let total: CGFloat
        if history.entries.isEmpty {
            total = IslandHistoryLayout.emptyHeight
        } else if height > 0 {
            total = min(IslandHistoryLayout.maximumHeight, height)
        } else {
            return
        }
        let span = PluginPanelWidgetLayoutMetrics.default.heightSpan(fittingContentHeight: total)
        // At once, both ways: the panel glides to the new height on the same spring the list
        // uses, and the list waits the panel's short update delay (see IslandHistoryLayout.motion).
        guard span != historySpan else { return }
        historySpan = span
        onStateChange?()
    }

    /// The list only measures itself while it is on screen, so a list that changed while the panel
    /// was shut asks the host again for its size as the panel shows it.
    func historyBecameVisible() {
        onStateChange?()
    }

    func openHistory(_ entry: IslandHistoryEntry) {
        logger.notice("list open inCentre=\(entry.centerApp != nil, privacy: .public) claude=\(entry.claudeChat != nil, privacy: .public)")
        history.remove(entry)
        if let link = entry.claudeChat?.link { NSWorkspace.shared.open(link); return }
        Task {
            var opened = await inCenter(.open, entry)
            // Gone from Notification Centre (the app withdrew it, or it was cleared there).
            // An entry adopted from before MacTools saw it opens Messages itself.
            if !opened, entry.bundleIdentifier == "com.apple.MobileSMS", entry.arrivalConfirmed,
               case .found(let chat) = await Self.messagesConversation(body: entry.body, lineCount: entry.lineCount, arrivedAt: entry.date),
               let url = chat.openURL {
                opened = NSWorkspace.shared.open(url)
            }
            if !opened, let url = entry.appURL {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            }
        }
    }

    func clearHistory(_ entries: [IslandHistoryEntry]) {
        for entry in entries { history.remove(entry) }
        Task {
            for entry in entries { _ = await inCenter(.clear, entry) }
        }
    }

    /// One at a time: each opens Notification Centre out of sight and closes it again.
    private func inCenter(_ action: IslandCenterPress.Action, _ entry: IslandHistoryEntry) async -> Bool {
        guard let app = entry.centerApp else { return false }
        while centerPressing { try? await Task.sleep(for: .milliseconds(50)) }
        centerPressing = true
        defer { centerPressing = false }
        return await IslandCenterPress.perform(action, on: IslandCenterPress.Target(app: app, title: entry.title, body: entry.body))
    }

    private func finishCurrent(dismissNative: Bool, reason: String) {
        guard !closing, let notification = queue.current else { return }
        logger.notice("card closed reason=\(reason, privacy: .public) held=\(self.presenter.isHeld, privacy: .public) hovered=\(self.presenter.isHovered, privacy: .public)")
        closing = true
        lifetimeTimer?.invalidate(); lifetimeTimer = nil
        let generation = generation
        let desktopMinX = Self.desktopMinX
        Task {
            if dismissNative, notification.style == .persistent {
                await IslandAX.run {
                    if let position = IslandAX.position(notification.window), position.x < desktopMinX - 5000,
                       !IslandAX.perform(anyOf: IslandAX.centerAction("Close"), on: notification.element) {
                        _ = IslandAX.move(notification.window, to: notification.originalPosition)
                    }
                }
            }
            guard self.generation == generation else { return }
            presenter.dismiss { [weak controller = self] in
                guard let self = controller, self.generation == generation else { return }
                if notification.style == .temporary { self.hidden.removeAll { $0 === notification } }
                self.queue.finish(); self.lifetime = nil; self.closing = false
                self.presentNext()
            }
        }
    }

    private var lastActivityCheck: TimeInterval = 0

    private func tick() {
        guard active else { return }
        guard enabled, trusted, let anchor else { return }
        // macOS swaps a newer notification from the same app into its existing banner without any
        // creation event, so re-read the shown card's hidden banner window twice a second.
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastRescan >= 0.5, let current = queue.current, current.claudeChat == nil, !closing {
            lastRescan = now
            receive(IslandAXElement(value: current.window))
        }
        let wasBlocked = blocked
        blocked = hoverPanelVisible(over: anchor)
        if !closing, queue.current != nil {
            // Hiding rebuilds the card later as a small card, so one in use stays: an opened or held
            // card (iOS keeps an expanded notification until it is dismissed) or a reply in progress.
            if blocked, presenter.window != nil, !presenter.isHeld, !presenter.isReplying, !presenter.hasDraft {
                logger.notice("card hidden under a hover panel")
                presenter.hide()
            }
            else if !blocked, presenter.window == nil, now - lastActivityCheck >= 0.5 {
                // A hidden card waits for its place to come back; looking twice a second is enough.
                lastActivityCheck = now
                activityChanged()
            }
            if blocked != wasBlocked { updateLifetime() }
        } else { presentNext(checkBlocking: false) }
    }

    private static var desktopMinX: CGFloat { NSScreen.screens.map(\.frame.minX).min() ?? 0 }
    private static var offscreenPosition: CGPoint { CGPoint(x: desktopMinX - 100_000, y: -100_000) }

    private static func normalPosition(for anchor: CGRect) -> CGPoint? {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }),
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return CGDisplayBounds(id.uint32Value).origin
    }

    /// These features are built for the floating camera island of the MacBook Pro that came with
    /// macOS 27: a short pill just below the top of the display. A classic notch (wide, reaching
    /// the display edge) is not one, and neither is an earlier macOS; there the feature stays off.
    static func isCameraIsland(_ anchor: CGRect) -> Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))
            && anchor.width < anchor.height * 3
    }

    private static func notchAnchor() -> CGRect? {
        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  CGDisplayIsBuiltin(id.uint32Value) != 0, CGDisplayIsActive(id.uint32Value) != 0,
                  let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
                  !left.isEmpty, !right.isEmpty else { continue }
            let height = max(left.height, right.height)
            let width = screen.frame.width - left.width - right.width
            guard height > 0, width > 0 else { continue }
            let anchor = CGRect(x: screen.frame.minX + left.width, y: screen.frame.maxY - height, width: width, height: height)
            return isCameraIsland(anchor) ? anchor : nil
        }
        return nil
    }

    private func hoverPanelVisible(over anchor: CGRect) -> Bool {
        // Host-owned hover panels and this plugin's panel share the process. No
        // public PluginKit layout change or host coordination hook is necessary.
        let area = anchor.insetBy(dx: 0, dy: -64)
        return NSApp.windows.contains { window in
            window !== presenter.window && window.isVisible && window is NSPanel &&
                window.styleMask.contains(.nonactivatingPanel) && window.frame.width >= 260 &&
                window.frame.height > 64 && window.frame.intersects(area)
        }
    }
}
