import AppKit
import ApplicationServices
import OSLog

/// Opens or clears a notification the way a click in Notification Centre does, without showing
/// Notification Centre. Only Notification Centre can hand an app the notification it posted, which
/// is how Mail, Spark and the rest open the exact item; once a banner has gone, its row there is the
/// only way in.
///
/// Notification Centre opens through its own accessibility action (the one VoiceOver uses). Its
/// window appears about 70 ms later, before its panel starts sliding in, and moves off screen as it
/// appears, so nothing is seen. Its rows stay pressable off screen. macOS makes a new window every
/// time it opens, so nothing needs putting back.
///
/// The whole press runs on a short-lived thread of its own, whose run loop also receives the window
/// notification: Accessibility calls to Notification Centre never wait on the main thread, and every
/// one of them is bounded by a messaging timeout.
enum IslandCenterPress {
    enum Action: Sendable { case open, clear }

    struct Target: Sendable {
        let app: String
        let title: String
        let body: String
    }

    private static let logger = Logger(subsystem: "MacTools.IslandNotifications", category: "center")
    private static let bundleIdentifier = "com.apple.notificationcenterui"
    private static let timeout: Float = 0.3

    /// True when Notification Centre had the notification and acted on it.
    @MainActor
    static func perform(_ action: Action, on target: Target) async -> Bool {
        guard AXIsProcessTrusted(),
              let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first?.processIdentifier
        else { return false }
        // Screens are AppKit state, so where the window goes is worked out here.
        let minX = NSScreen.screens.map(\.frame.minX).min() ?? 0
        let offscreen = CGPoint(x: minX - 100_000, y: -100_000)
        return await withCheckedContinuation { continuation in
            let thread = Thread {
                continuation.resume(returning: run(action, target: target, pid: pid, offscreen: offscreen))
            }
            thread.name = "MacTools.IslandNotifications.center"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    /// Moves Notification Centre's new window off screen. Lives on the press thread only.
    fileprivate final class WindowMover: @unchecked Sendable {
        let offscreen: CGPoint
        var moved = false
        init(offscreen: CGPoint) { self.offscreen = offscreen }
    }

    /// The press itself, on its own thread.
    private static func run(_ action: Action, target: Target, pid: pid_t, offscreen: CGPoint) -> Bool {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, timeout)
        let wasOpen = value(application, "AXExpanded") as? Bool == true
        let mover = WindowMover(offscreen: offscreen)
        let runLoop = CFRunLoopGetCurrent()
        var observer: AXObserver?
        if !wasOpen {
            // Without the observer the window could not be hidden in time: leave Notification Centre shut.
            guard AXObserverCreate(pid, islandCenterWindowCreated, &observer) == .success, let observer,
                  AXObserverAddNotification(observer, application, kAXWindowCreatedNotification as CFString,
                                            Unmanaged.passUnretained(mover).toOpaque()) == .success
            else { logger.error("Could not watch Notification Centre"); return false }
            CFRunLoopAddSource(runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        defer {
            if let observer {
                AXObserverRemoveNotification(observer, application, kAXWindowCreatedNotification as CFString)
                CFRunLoopRemoveSource(runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
            }
            withExtendedLifetime(mover) {}
        }
        let started = ProcessInfo.processInfo.systemUptime
        if !wasOpen {
            // The action reports an error although it opens the centre, so the window is what counts.
            _ = AXUIElementPerformAction(application, "AXToggleUI" as CFString)
            // Nothing is read until the window is off screen; if it never moves, the centre closes again.
            while !mover.moved, ProcessInfo.processInfo.systemUptime - started < 0.5 {
                CFRunLoopRunInMode(.defaultMode, 0.01, false)
            }
            guard mover.moved else {
                logger.error("Notification Centre's window did not move off screen")
                _ = AXUIElementPerformAction(application, "AXCloseNotificationCenter" as CFString)
                return false
            }
        }
        let names: Set<String> = action == .open ? [kAXPressAction as String] : IslandAX.centerAction("Close")
        let done = findRow(application, target: target).map { perform(anyOf: names, on: $0) } ?? false
        let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
        logger.notice("center \(action == .open ? "open" : "clear", privacy: .public) found=\(done, privacy: .public) ms=\(elapsed, privacy: .public) wasOpen=\(wasOpen, privacy: .public)")
        guard !wasOpen else { return done }
        // A press closes the centre itself; anything else leaves it shut, as it was found.
        if !(done && action == .open) {
            _ = AXUIElementPerformAction(application, "AXCloseNotificationCenter" as CFString)
        }
        // Return once it has closed, so its closing isn't taken for the user opening it.
        for _ in 0..<20 where value(application, "AXExpanded") as? Bool == true {
            CFRunLoopRunInMode(.defaultMode, 0.05, false)
        }
        return done
    }

    /// Waits for the centre's rows, then the notification: a single row, or inside its app's stack,
    /// which a press expands as it does on screen.
    private static func findRow(_ application: AXUIElement, target: Target) -> AXUIElement? {
        // Rows before the stack was pressed; nil until then.
        var before: Int?
        let deadline = ProcessInfo.processInfo.systemUptime + 1.5
        while ProcessInfo.processInfo.systemUptime < deadline {
            let rows = rows(application)
            let matches = rows.filter { $0.single && IslandCenterMatch.row($0.description, matchesApp: target.app,
                                                                          title: target.title, body: target.body) }
            // Two rows that read the same can't be told apart: neither is opened or cleared.
            if matches.count > 1 { logger.notice("center rows ambiguous count=\(matches.count, privacy: .public)"); return nil }
            if let row = matches.first { return row.element }
            if let before {
                // The stack opened and the notification isn't in it.
                if rows.count != before { return nil }
            } else if !rows.isEmpty {
                guard let stack = rows.first(where: { !$0.single && IslandCenterMatch.stack($0.description, isApp: target.app) }),
                      perform(anyOf: [kAXPressAction as String], on: stack.element) else { return nil }
                before = rows.count
            }
            CFRunLoopRunInMode(.defaultMode, 0.04, false)
        }
        return nil
    }

    private struct Row {
        let element: AXUIElement
        let description: String
        let single: Bool
    }

    private static func rows(_ application: AXUIElement) -> [Row] {
        guard let window = (value(application, kAXWindowsAttribute as String) as? [AXUIElement])?.first else { return [] }
        var found: [Row] = []
        var budget = 600
        func walk(_ element: AXUIElement, depth: Int) {
            budget -= 1
            guard budget > 0, depth < 14 else { return }
            let subrole = value(element, kAXSubroleAttribute as String) as? String ?? ""
            let description = { value(element, kAXDescriptionAttribute as String) as? String ?? "" }
            if IslandNotificationStyle(subrole: subrole) != nil {
                found.append(Row(element: element, description: description(), single: true))
                return
            }
            if IslandNotificationStyle(stackSubrole: subrole) != nil {
                found.append(Row(element: element, description: description(), single: false))
            }
            for child in value(element, kAXChildrenAttribute as String) as? [AXUIElement] ?? [] { walk(child, depth: depth + 1) }
        }
        walk(window, depth: 0)
        return found
    }

    /// An attribute, waiting at most `timeout` for Notification Centre to answer.
    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, timeout)
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }

    /// Performs the first action named in `names` (a custom action reads "Name:<name>\n…").
    private static func perform(anyOf names: Set<String>, on element: AXUIElement) -> Bool {
        AXUIElementSetMessagingTimeout(element, timeout)
        var raw: CFArray?
        guard AXUIElementCopyActionNames(element, &raw) == .success, let actions = raw as? [String],
              let action = actions.first(where: { action in
                  names.contains(action) || names.contains { action.hasPrefix("Name:\($0)\n") }
              }) else { return false }
        return AXUIElementPerformAction(element, action as CFString) == .success
    }
}

/// Notification Centre's window appeared: off screen at once, before its panel draws. Runs on the
/// press thread's run loop; `context` is that press's WindowMover.
private func islandCenterWindowCreated(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString,
                                       _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let mover = Unmanaged<IslandCenterPress.WindowMover>.fromOpaque(context).takeUnretainedValue()
    var point = mover.offscreen
    guard let value = AXValueCreate(.cgPoint, &point) else { return }
    if AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success { mover.moved = true }
}
