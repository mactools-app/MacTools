import AppKit
import ApplicationServices
import OSLog

private final class IslandActivitySession: @unchecked Sendable {
    let pid: pid_t
    let application: AXUIElement
    let observer: AXObserver?
    var observed: [AXUIElement] = []
    init(pid: pid_t, application: AXUIElement, observer: AXObserver?) {
        self.pid = pid; self.application = application; self.observer = observer
    }
}

/// Notifications are best effort: some macOS versions do not publish layout
/// changes. Every incoming banner and queued presentation also reads on demand.
@MainActor
final class IslandLiveActivityObserver {
    var onChange: (() -> Void)?
    private var session: IslandActivitySession?
    private var generation = 0
    private var reading: Task<IslandLiveActivityPlacement, Never>?
    private var change: DispatchWorkItem?
    /// MenuBarAgent, found once and kept while it runs: finding it checks every running app's path.
    private var agent: NSRunningApplication?
    /// When the last change was handed on (system uptime). Changes arriving faster are coalesced, so
    /// a Live Activity that redraws constantly costs at most two reads a second.
    private var lastChange: TimeInterval = 0
    private static let minimumChangeInterval: TimeInterval = 0.5
    nonisolated private static let logger = Logger(subsystem: "MacTools.IslandNotifications", category: "liveactivity")
    nonisolated private static let messagingTimeout: Float = 0.2

    nonisolated static func isMenuBarAgent(_ app: NSRunningApplication) -> Bool {
        app.executableURL?.lastPathComponent == "MenuBarAgent" || app.localizedName == "MenuBarAgent" ||
            app.bundleURL?.lastPathComponent == "MenuBarAgent.app"
    }

    func refresh(anchor: CGRect) async -> IslandLiveActivityPlacement {
        if agent?.isTerminated != false {
            agent = NSWorkspace.shared.runningApplications.first(where: Self.isMenuBarAgent)
        }
        guard let app = agent else {
            Self.logger.debug("appFound=false decision=native reason=menubaragent-not-found")
            return .native
        }
        Self.logger.debug("appFound=true pid=\(app.processIdentifier, privacy: .public)")
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }),
              let desktopTop = NSScreen.screens.first?.frame.maxY else {
            Self.logger.debug("decision=native reason=anchor-screen-not-found")
            return .native
        }
        let screenFrame = screen.frame
        let pid = app.processIdentifier
        if let reading { return await reading.value }
        if session?.pid != pid { stop() }
        let revision = generation
        let task = Task { await read(pid: pid, screen: screenFrame, desktopTop: desktopTop, anchor: anchor) }
        reading = task
        let result = await task.value
        if generation == revision { reading = nil }
        return result
    }

    private func read(pid: pid_t, screen: CGRect, desktopTop: CGFloat, anchor: CGRect) async -> IslandLiveActivityPlacement {
        let currentGeneration = generation
        let context = UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque())
        let existing = session
        let result = await IslandAX.run { () -> (IslandActivitySession, [CGRect?], Bool) in
            let active: IslandActivitySession
            if let existing { active = existing }
            else {
                let application = AXUIElementCreateApplication(pid)
                _ = IslandAX.setMessagingTimeout(application, timeout: Self.messagingTimeout)
                var observer: AXObserver?
                _ = AXObserverCreate(pid, islandActivityCallback, &observer)
                active = IslandActivitySession(pid: pid, application: application, observer: observer)
            }
            // Subscriptions change only where the elements did. Registering again for elements already
            // watched makes MenuBarAgent report changes that start another read, so a read never
            // re-registers what it already watches.
            let previous = active.observed
            active.observed = [active.application]
            var frames: [CGRect?] = []
            var complete = true
            var budget = 250
            // Every helper otherwise resets the element timeout to 0.05 seconds.
            // Scope the probe's 0.2-second allowance to MenuBarAgent on the AX executor.
            @IslandAXExecutor func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
                IslandAX.value(element, attribute, timeout: Self.messagingTimeout)
            }
            @IslandAXExecutor func walk(_ element: AXUIElement, depth: Int) {
                guard complete else { return }
                guard budget > 0, depth < 16 else {
                    Self.logger.debug("scanIncomplete reason=traversal-limit depth=\(depth, privacy: .public)")
                    complete = false; return
                }
                budget -= 1
                guard let role = value(element, kAXRoleAttribute) as? String else {
                    Self.logger.debug("scanIncomplete reason=role-unreadable depth=\(depth, privacy: .public)")
                    complete = false; return
                }
                // AXUnknown windows and missing structural subroles are valid wrappers.
                let subrole = value(element, kAXSubroleAttribute) as? String ?? ""
                if depth <= 1 || subrole == "AXLiveActivity" {
                    Self.logger.debug("item depth=\(depth, privacy: .public) role=\(role, privacy: .public) subrole=\(subrole, privacy: .public)")
                }
                if subrole == "AXLiveActivity" {
                    if (value(element, "AXHidden") as? Bool) == true {
                        Self.logger.debug("activity hidden=true")
                        return
                    }
                    active.observed.append(element)
                    guard let point = IslandAX.position(element, timeout: Self.messagingTimeout),
                          let raw = value(element, kAXSizeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else {
                        Self.logger.debug("activity frame=unreadable")
                        frames.append(nil); return
                    }
                    let value = unsafeDowncast(raw, to: AXValue.self)
                    var size = CGSize.zero
                    guard AXValueGetType(value) == .cgSize, AXValueGetValue(value, .cgSize, &size) else {
                        Self.logger.debug("activity frame=invalid-size")
                        frames.append(nil); return
                    }
                    frames.append(CGRect(origin: point, size: size))
                    Self.logger.debug("activity AXFrame x=\(point.x, privacy: .public) y=\(point.y, privacy: .public) width=\(size.width, privacy: .public) height=\(size.height, privacy: .public)")
                    return
                }
                visitChildren(element, depth: depth)
            }
            @IslandAXExecutor func visitChildren(_ element: AXUIElement, depth: Int) {
                guard let children = IslandAX.children(element, timeout: Self.messagingTimeout) else {
                    Self.logger.debug("scanIncomplete reason=children-unreadable depth=\(depth, privacy: .public)")
                    complete = false; return
                }
                for child in children { walk(child, depth: depth + 1) }
            }
            if let windows = value(active.application, kAXWindowsAttribute) as? [AXUIElement] {
                Self.logger.debug("windows=\(windows.count, privacy: .public) timeout=0.2")
                // Live Activities live only in MenuBarAgent's full-screen AXUnknown host window. Its other
                // windows (e.g. an AXDialog of groups) are unrelated and may contain unreadable elements,
                // which must not veto the decision.
                for window in windows where (value(window, kAXSubroleAttribute) as? String) == "AXUnknown" {
                    active.observed.append(window)
                    walk(window, depth: 0)
                }
            } else {
                Self.logger.debug("scanIncomplete reason=windows-unreadable timeout=0.2")
                complete = false
            }
            Self.logger.debug("activities=\(frames.count, privacy: .public) nodes=\(250 - budget, privacy: .public) complete=\(complete, privacy: .public)")
            if let observer = active.observer {
                let contains = { (list: [AXUIElement], element: AXUIElement) in list.contains { CFEqual($0, element) } }
                for element in previous where !contains(active.observed, element) {
                    for name in Self.notifications { AXObserverRemoveNotification(observer, element, name as CFString) }
                }
                for element in active.observed where !contains(previous, element) {
                    for name in Self.notifications {
                        _ = AXObserverAddNotification(observer, element, name as CFString,
                                                      UnsafeMutableRawPointer(bitPattern: context))
                    }
                }
            }
            return (active, frames, complete)
        }
        // The initial stop for a changed process is intentional; a subsequent stop
        // invalidates this result and prevents an unloaded observer reattaching.
        guard generation == currentGeneration else {
            await Self.remove(result.0)
            Self.logger.debug("decision=native reason=observer-stopped-during-read")
            return .native
        }
        if session == nil {
            session = result.0
            if let observer = result.0.observer {
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
        }
        let decision = IslandLiveActivityPlacement.evaluate(axFrames: result.1, complete: result.2,
            desktopTop: desktopTop, screen: screen, anchor: anchor)
        switch decision.placement {
        case .split(let frame):
            Self.logger.debug("decision=split reason=\(decision.reason, privacy: .public) AppKitFrame x=\(frame.minX, privacy: .public) y=\(frame.minY, privacy: .public) width=\(frame.width, privacy: .public) height=\(frame.height, privacy: .public) primaryTop=\(desktopTop, privacy: .public)")
        case .camera:
            Self.logger.debug("decision=camera reason=\(decision.reason, privacy: .public)")
        case .native:
            Self.logger.debug("decision=native reason=\(decision.reason, privacy: .public)")
        }
        return decision.placement
    }

    nonisolated private static let notifications = [kAXCreatedNotification, kAXUIElementDestroyedNotification,
                                                   kAXLayoutChangedNotification, kAXMovedNotification, kAXResizedNotification]

    fileprivate func changed() {
        guard change == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.change = nil
            self.lastChange = ProcessInfo.processInfo.systemUptime
            self.onChange?()
        }
        change = work
        let sinceLast = ProcessInfo.processInfo.systemUptime - lastChange
        let delay = max(0.02, Self.minimumChangeInterval - sinceLast)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private static func remove(_ session: IslandActivitySession) async {
        await IslandAX.run {
            guard let observer = session.observer else { return }
            for element in session.observed {
                for name in notifications { AXObserverRemoveNotification(observer, element, name as CFString) }
            }
        }
    }

    func stop() {
        generation += 1
        agent = nil
        reading?.cancel(); reading = nil
        change?.cancel(); change = nil
        if let session {
            if let observer = session.observer {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
            Task { await Self.remove(session) }
        }
        session = nil
    }

    isolated deinit { stop() }
}

private func islandActivityCallback(_ observer: AXObserver, _ element: AXUIElement,
                                    _ notification: CFString, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let address = UInt(bitPattern: context)
    MainActor.assumeIsolated {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return }
        Unmanaged<IslandLiveActivityObserver>.fromOpaque(pointer).takeUnretainedValue().changed()
    }
}
