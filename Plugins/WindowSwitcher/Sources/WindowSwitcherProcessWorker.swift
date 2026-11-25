import AppKit
import ApplicationServices
import Foundation

/// AX objects are opaque handles. All reads and actions on them are serialized by
/// their owning process worker; only immutable snapshots cross to the main actor.
struct WindowSwitcherWindowSnapshot: @unchecked Sendable {
    let id: String
    let element: AXUIElement
    var title: String
    var minimized: Bool
    var bounds: CGRect
    var windowNumber: CGWindowID? = nil
    var unavailable: Bool = false
    var isFullscreen: Bool = false
}

struct WindowSwitcherScan: Sendable {
    var windows: [WindowSwitcherWindowSnapshot]
    var focusedID: String?
    var unavailable: Bool
    var windowListReadSucceeded = true
    var reportedFocusedWindow = false
}

struct WindowSwitcherAXIdentity: Hashable {
    let element: AXUIElement
    static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.element, rhs.element) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
}

struct WindowSwitcherWindowIdentities {
    private var live: [WindowSwitcherAXIdentity: String] = [:]

    mutating func reconcile(_ elements: [AXUIElement]) -> [String] {
        reconcile(elements, shouldContinue: { true })!
    }

    mutating func reconcile(_ elements: [AXUIElement], shouldContinue: () -> Bool) -> [String]? {
        var next: [WindowSwitcherAXIdentity: String] = [:]
        var result: [String] = []
        for element in elements {
            guard shouldContinue() else { return nil }
            let key = WindowSwitcherAXIdentity(element: element)
            let id = next[key] ?? live[key] ?? "window:\(UUID())"
            next[key] = id
            result.append(id)
        }
        live = next
        return result
    }
}

enum WindowSwitcherActionResult: Equatable, Sendable {
    case succeeded, requested, unavailable, failed, cancelled
    var message: String? {
        switch self {
        case .succeeded, .cancelled: nil
        case .requested: "已发送请求；窗口可能需要确认保存。"
        case .unavailable: "窗口已关闭或暂时无法访问，请重新选择。"
        case .failed: "未能确认目标窗口，请重试或检查辅助功能权限。"
        }
    }
}

/// One bounded queue per application prevents a hung process from blocking the UI
/// or another application's discovery. Notifications coalesce with a polling fallback.
final class WindowSwitcherProcessWorker: @unchecked Sendable {
    let pid: pid_t
    let launchDate: Date?
    let applicationLifetime: UUID?
    let lifetime = UUID()
    private let queue: DispatchQueue
    private let app: AXUIElement
    private let access: any WindowSwitcherAXAccess
    private let requestWindowActivation: @Sendable (CGWindowID, pid_t, WindowSwitcherActionCancellation) -> Bool
    private let windowIsRevealable: @Sendable (CGWindowID, pid_t) -> Bool
    private let windowIsOnScreen: @Sendable (CGWindowID, pid_t) -> Bool
    private let windowIsOnActiveSpace: @Sendable (CGWindowID) -> Bool?
    private var records: [WindowSwitcherWindowSnapshot] = []
    private var identities = WindowSwitcherWindowIdentities()
    private var offSpaceResolver = WindowSwitcherOffSpaceResolver()
    private var observer: AXObserver?
    private var windowSubscriptions: [WindowSwitcherAXIdentity: [String: WindowSwitcherNotificationRegistration]] = [:]
    private var applicationSubscriptions: [String: WindowSwitcherNotificationRegistration] = [:]
    private var observerRegistration = WindowSwitcherNotificationRegistration()
    private let uptime: @Sendable () -> TimeInterval
    private var cursor = 0
    private var stopped = false
    private let invalidated: @Sendable (WindowSwitcherProcessEvent) -> Void

    init(pid: pid_t, launchDate: Date?, applicationLifetime: UUID? = nil,
         access: any WindowSwitcherAXAccess = SystemWindowSwitcherAXAccess(),
         uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         requestWindowActivation: @escaping @Sendable (CGWindowID, pid_t, WindowSwitcherActionCancellation) -> Bool = { WindowSwitcherWindowServer.activate($0, pid: $1, cancellation: $2) },
         windowIsRevealable: @escaping @Sendable (CGWindowID, pid_t) -> Bool = { WindowSwitcherWindowServer.isRevealable($0, pid: $1) },
         windowIsOnScreen: @escaping @Sendable (CGWindowID, pid_t) -> Bool = { WindowSwitcherWindowServer.isOnScreen($0, pid: $1) },
         windowIsOnActiveSpace: @escaping @Sendable (CGWindowID) -> Bool? = { WindowSwitcherSpaceMembership.isOnActiveSpace($0) },
         invalidated: @escaping @Sendable (WindowSwitcherProcessEvent) -> Void) {
        self.access = access
        self.requestWindowActivation = requestWindowActivation
        self.windowIsRevealable = windowIsRevealable
        self.windowIsOnScreen = windowIsOnScreen
        self.windowIsOnActiveSpace = windowIsOnActiveSpace
        self.uptime = uptime
        self.pid = pid
        self.launchDate = launchDate
        self.applicationLifetime = applicationLifetime
        self.invalidated = invalidated
        queue = DispatchQueue(label: "WindowSwitcher.AX.\(pid)", qos: .userInitiated)
        app = AXUIElementCreateApplication(pid)
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            windowSubscriptions.removeAll()
            applicationSubscriptions.removeAll()
            records.removeAll()
            // Keep the callback context alive until removal on the callback's
            // own run loop; an in-progress main-thread callback cannot race free.
            DispatchQueue.main.async { [self] in
                if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
                observer = nil
            }
        }
    }

    func scan() async -> WindowSwitcherScan {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: read()) }
        }
    }

    private func read() -> WindowSwitcherScan {
        guard !stopped else { return WindowSwitcherScan(windows: [], unavailable: true, windowListReadSucceeded: false) }
        let deadline = uptime() + 0.25
        func incomplete() -> WindowSwitcherScan {
            WindowSwitcherScan(windows: records.map { var r = $0; r.unavailable = true; return r },
                               unavailable: true, windowListReadSucceeded: false)
        }
        AXUIElementSetMessagingTimeout(app, 0.06)
        installObserver()
        guard let windows = copyWindows(shouldContinue: { self.uptime() < deadline }) else { return incomplete() }
        let live = Set(windows.map { WindowSwitcherAXIdentity(element: $0) })
        guard uptime() < deadline,
              let windowIDs = identities.reconcile(windows, shouldContinue: { self.uptime() < deadline }) else { return incomplete() }
        records.removeAll { !live.contains(WindowSwitcherAXIdentity(element: $0.element)) }
        // Deferred observer removal retains ownership until a later scan can finish it.
        for old in Array(windowSubscriptions.keys) where !live.contains(old) {
            guard uptime() < deadline else { break }
            if let observer {
                for (name, registration) in windowSubscriptions[old] ?? [:] where registration.isRegistered {
                    AXObserverRemoveNotification(observer, old.element, name as CFString)
                }
            }
            windowSubscriptions.removeValue(forKey: old)
        }
        var indexes = Dictionary(uniqueKeysWithValues: records.enumerated().map { (WindowSwitcherAXIdentity(element: $0.element.element), $0.offset) })
        var excluded = Set<String>()
        var didRead = 0
        var metadataFailed = false
        let count = windows.count
        for offset in 0..<count {
            guard uptime() < deadline else { break }
            let index = (cursor + offset) % count
            let window = windows[index]
            let key = WindowSwitcherAXIdentity(element: window)
            AXUIElementSetMessagingTimeout(window, 0.06)
            let oldIndex = indexes[key]
            switch snapshot(window, id: windowIDs[index]) {
            case let .eligible(snapshot):
                if let oldIndex { records[oldIndex] = snapshot }
                else { indexes[key] = records.count; records.append(snapshot) }
                if uptime() < deadline { observe(window) }
            case .excluded:
                if let oldIndex { excluded.insert(records[oldIndex].id) }
            case .unavailable:
                metadataFailed = true
                if let oldIndex { records[oldIndex].unavailable = true }
            }
            didRead += 1
        }
        records.removeAll { excluded.contains($0.id) }
        cursor = count == 0 ? 0 : (cursor + didRead) % count
        let focused = uptime() < deadline ? copyElement(app, kAXFocusedWindowAttribute) : nil
        let focusedID = focused.flatMap { element in records.first { CFEqual($0.element, element) }?.id }
        return WindowSwitcherScan(windows: records, focusedID: focusedID,
            unavailable: metadataFailed || didRead < count, reportedFocusedWindow: focused != nil)
    }

    private enum Admission { case eligible(WindowSwitcherWindowSnapshot), excluded, unavailable }
    private func snapshot(_ window: AXUIElement, id: String) -> Admission {
        guard let values = access.windowAttributes(window), values.count == 6,
              let role = values[0] as? String else { return .unavailable }
        // A process root masquerading as a window is invalid AX data, not
        // evidence that the app has no user windows.
        if role == kAXApplicationRole as String { return .unavailable }
        guard role == kAXWindowRole as String else { return .excluded }
        if let subrole = values[1] as? String,
           ![kAXStandardWindowSubrole as String, kAXDialogSubrole as String, "AXFullScreenWindow"].contains(subrole) {
            return .excluded
        }
        guard let minimized = values[3] as? Bool,
              let point = decodePoint(values[4]),
              let size = decodeSize(values[5]) else { return .unavailable }
        guard point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite,
              size.width >= 0, size.height >= 0 else { return .unavailable }
        guard minimized || (size.width >= 80 && size.height >= 60) else { return .excluded }
        let title = values[2] as? String ?? ""
        if !minimized,
           values[1] as? String == kAXDialogSubrole as String,
           title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           access.childCount(window) == 0,
           access.boolValue(window, attribute: kAXMainAttribute as String) == false,
           access.boolValue(window, attribute: kAXFocusedAttribute as String) == false {
            // Some apps expose empty, unfocused compositor surfaces as AX
            // dialogs even while WindowServer marks them visible. A dialog
            // with content or foreground status remains a selectable window.
            return .excluded
        }
        let snapshot = WindowSwitcherWindowSnapshot(id: id, element: window, title: title,
                                                       minimized: minimized, bounds: CGRect(origin: point, size: size),
                                                       windowNumber: access.windowNumber(window),
                                                       isFullscreen: access.isFullscreen(window) == true)
        return .eligible(snapshot)
    }

    private func decodePoint(_ raw: Any) -> CGPoint? {
        let value = raw as CFTypeRef
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var result = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &result) else { return nil }
        return result
    }

    private func decodeSize(_ raw: Any) -> CGSize? {
        let value = raw as CFTypeRef
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var result = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &result) else { return nil }
        return result
    }

    private func copyWindows(shouldContinue: () -> Bool = { true }) -> [AXUIElement]? {
        guard let values = access.windows(of: app), shouldContinue() else { return nil }
        var seen = Set<WindowSwitcherAXIdentity>()
        var result: [AXUIElement] = []
        for window in values {
            guard shouldContinue(), !CFEqual(window, app) else { return nil }
            if seen.insert(WindowSwitcherAXIdentity(element: window)).inserted { result.append(window) }
        }
        return result
    }

    private func copyElement(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        access.element(element, attribute: name)
    }

    /// Cooperative app activation can be declined when handing focus from the
    /// chooser to the selected window's application. Request the
    /// app's Accessibility foreground state once, then observe it before raising.
    func requestApplicationActivation(cancellation: WindowSwitcherActionCancellation = WindowSwitcherActionCancellation()) async -> AXError {
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return .cannotComplete }
            return await withCheckedContinuation { continuation in
                queue.async { [self] in
                    guard !stopped, !cancellation.isCancelled else {
                        continuation.resume(returning: .cannotComplete); return
                    }
                    continuation.resume(returning: access.set(app, attribute: kAXFrontmostAttribute, value: true))
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    func validate(_ id: String) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: liveWindow(id, retryUnavailable: true) != nil) }
        }
    }

    private func liveWindow(_ id: String, cancellation: WindowSwitcherActionCancellation? = nil,
                            retryUnavailable: Bool = false) -> AXUIElement? {
        guard !stopped, let record = records.first(where: { $0.id == id }) else { return nil }
        for attempt in 0..<(retryUnavailable ? 3 : 1) {
            guard cancellation?.isCancelled != true else { return nil }
            if let windows = copyWindows() {
                // A successful read excluding the target is authoritative.
                return windows.contains(where: { CFEqual($0, record.element) }) ? record.element : nil
            }
            if retryUnavailable && attempt < 2 { Thread.sleep(forTimeInterval: 0.04) }
        }
        return nil
    }

    private func minimizedBeforeAction(_ window: AXUIElement, cancellation: WindowSwitcherActionCancellation) -> Bool? {
        for attempt in 0..<3 {
            guard !cancellation.isCancelled else { return nil }
            if let value = access.minimized(window) { return value }
            if attempt < 2 { Thread.sleep(forTimeInterval: 0.04) }
        }
        return nil
    }

    func resolveOffSpaceWindow(_ number: CGWindowID, ownerPID: pid_t? = nil, cancellation: WindowSwitcherActionCancellation) async -> WindowSwitcherResolvedWindow? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard !stopped, !cancellation.isCancelled else { continuation.resume(returning: nil); return }
                var candidates = records.map(\.element)
                candidates += [copyElement(app, kAXFocusedWindowAttribute), copyElement(app, kAXMainWindowAttribute)].compactMap { $0 }
                let element = offSpaceResolver.resolve(pid: pid, number: number, access: access,
                    candidates: candidates, shouldContinue: { !self.stopped && !cancellation.isCancelled })
                continuation.resume(returning: element.map { WindowSwitcherResolvedWindow(number: number, element: $0, ownerPID: ownerPID ?? self.pid) })
            }
        }
    }

    private func ownerPID(of target: WindowSwitcherResolvedWindow) -> pid_t {
        target.ownerPID ?? pid
    }

    func focusOffSpaceWindow(_ target: WindowSwitcherResolvedWindow, cancellation: WindowSwitcherActionCancellation) async -> WindowSwitcherActionResult {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    guard !stopped, !cancellation.isCancelled else { continuation.resume(returning: .cancelled); return }
                    guard isExactWindow(target), windowIsRevealable(target.number, ownerPID(of: target)) else {
                        continuation.resume(returning: .unavailable); return
                    }
                    if access.minimized(target.element) == true {
                        guard !cancellation.isCancelled else { continuation.resume(returning: .cancelled); return }
                        guard access.set(target.element, attribute: kAXMinimizedAttribute, value: false) == .success else {
                            continuation.resume(returning: .failed); return
                        }
                        waitForOffSpaceRestore(target, attempts: 12, cancellation: cancellation, continuation: continuation)
                    } else {
                        submitOffSpaceFocus(target, cancellation: cancellation, continuation: continuation)
                    }
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    private func waitForOffSpaceRestore(_ target: WindowSwitcherResolvedWindow, attempts: Int,
                                        cancellation: WindowSwitcherActionCancellation,
                                        continuation: CheckedContinuation<WindowSwitcherActionResult, Never>) {
        queue.asyncAfter(deadline: .now() + 0.1) { [self] in
            guard !stopped, !cancellation.isCancelled else { continuation.resume(returning: .cancelled); return }
            guard isExactWindow(target), windowIsRevealable(target.number, ownerPID(of: target)) else {
                continuation.resume(returning: .unavailable); return
            }
            if access.minimized(target.element) == false {
                submitOffSpaceFocus(target, cancellation: cancellation, continuation: continuation)
            } else if attempts > 1 {
                waitForOffSpaceRestore(target, attempts: attempts - 1, cancellation: cancellation, continuation: continuation)
            } else {
                continuation.resume(returning: .failed)
            }
        }
    }

    private func submitOffSpaceFocus(_ target: WindowSwitcherResolvedWindow,
                                     cancellation: WindowSwitcherActionCancellation,
                                     continuation: CheckedContinuation<WindowSwitcherActionResult, Never>) {
        guard !stopped, !cancellation.isCancelled else { continuation.resume(returning: .cancelled); return }
        guard isExactWindow(target), windowIsRevealable(target.number, ownerPID(of: target)) else {
            continuation.resume(returning: .unavailable); return
        }
        // Keep exact fronting and AX focus adjacent on this queue.
        // App-only activation in between can restore a different window.
        let owner = target.ownerPID ?? pid
        guard requestWindowActivation(target.number, owner, cancellation) else { continuation.resume(returning: .failed); return }
        guard !cancellation.isCancelled else { continuation.resume(returning: .cancelled); return }
        _ = access.set(app, attribute: kAXMainWindowAttribute, window: target.element)
        guard !cancellation.isCancelled else { continuation.resume(returning: .cancelled); return }
        _ = access.set(app, attribute: kAXFocusedWindowAttribute, window: target.element)
        guard !cancellation.isCancelled else { continuation.resume(returning: .cancelled); return }
        _ = access.set(target.element, attribute: kAXMainAttribute, value: true)
        guard !cancellation.isCancelled else { continuation.resume(returning: .cancelled); return }
        _ = access.set(target.element, attribute: kAXFocusedAttribute, value: true)
        guard !cancellation.isCancelled else { continuation.resume(returning: .cancelled); return }
        _ = access.perform(target.element, action: kAXRaiseAction)
        verifyOffSpaceFocus(target, attempts: 24, cancellation: cancellation, continuation: continuation)
    }

    private func isExactWindow(_ target: WindowSwitcherResolvedWindow) -> Bool {
        access.windowNumber(target.element) == target.number
            && access.windowAttributes(target.element)?.first as? String == kAXWindowRole
    }

    private func verifyOffSpaceFocus(_ target: WindowSwitcherResolvedWindow, attempts: Int,
                                    cancellation: WindowSwitcherActionCancellation,
                                    continuation: CheckedContinuation<WindowSwitcherActionResult, Never>) {
        queue.asyncAfter(deadline: .now() + 0.05) { [self] in
            guard !stopped, !cancellation.isCancelled else { continuation.resume(returning: .cancelled); return }
            guard isExactWindow(target), windowIsRevealable(target.number, ownerPID(of: target)) else {
                continuation.resume(returning: .unavailable); return
            }
            let focused = copyElement(app, kAXFocusedWindowAttribute)
            let exactFocus = focused.map {
                access.windowNumber($0) == target.number
                    && access.windowAttributes($0)?.first as? String == kAXWindowRole
            } ?? false
            // AX focus can change before Mission Control finishes its transition.
            // Require this exact window onscreen and on an active display Space.
            // During an animation the compositor can expose both Spaces at once.
            if exactFocus && windowIsOnScreen(target.number, ownerPID(of: target)) && windowIsOnActiveSpace(target.number) != false {
                continuation.resume(returning: .succeeded)
            } else if attempts > 1 {
                verifyOffSpaceFocus(target, attempts: attempts - 1, cancellation: cancellation, continuation: continuation)
            } else {
                continuation.resume(returning: .failed)
            }
        }
    }

    func perform(_ id: String, close: Bool, cancellation: WindowSwitcherActionCancellation = WindowSwitcherActionCancellation()) async -> WindowSwitcherActionResult {
        return await withTaskCancellationHandler {
            if Task.isCancelled { cancellation.cancel() }
            return await withCheckedContinuation { continuation in
                queue.async { [self] in
                    guard !cancellation.isCancelled else { continuation.resume(returning: .cancelled); return }
                    guard let window = liveWindow(id, cancellation: cancellation, retryUnavailable: true) else {
                        continuation.resume(returning: cancellation.isCancelled ? .cancelled : .unavailable); return
                    }
                    guard !cancellation.isCancelled else { continuation.resume(returning: .cancelled); return }
                    if close {
                        guard let button = copyElement(window, kAXCloseButtonAttribute) else {
                            continuation.resume(returning: .unavailable); return
                        }
                        guard !cancellation.isCancelled else { continuation.resume(returning: .cancelled); return }
                        let result = access.perform(button, action: kAXPressAction)
                        continuation.resume(returning: result == .success ? .requested : .failed)
                        return
                    }
                    guard let minimized = minimizedBeforeAction(window, cancellation: cancellation) else {
                        continuation.resume(returning: cancellation.isCancelled ? .cancelled : .unavailable); return
                    }
                    guard !cancellation.isCancelled else { continuation.resume(returning: .cancelled); return }
                    if minimized {
                        guard access.set(window, attribute: kAXMinimizedAttribute, value: false) == .success else {
                            continuation.resume(returning: .failed); return
                        }
                        waitForRestore(id, window: window, attempts: 12, cancellation: cancellation, continuation: continuation)
                    } else {
                        raise(id, window: window, cancellation: cancellation, continuation: continuation)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func waitForRestore(_ id: String, window: AXUIElement, attempts: Int,
                                cancellation: WindowSwitcherActionCancellation,
                                continuation: CheckedContinuation<WindowSwitcherActionResult, Never>) {
        // This handle stays on the worker's serial queue across restore polls.
        nonisolated(unsafe) let window = window
        queue.asyncAfter(deadline: .now() + 0.1) { [self] in
            guard !cancellation.isCancelled else { continuation.resume(returning: .cancelled); return }
            guard !stopped else { continuation.resume(returning: .unavailable); return }
            // macOS may accept deminiaturization before its animation completes.
            // Observe readiness without resubmitting the restore request.
            if access.minimized(window) == false {
                guard liveWindow(id, cancellation: cancellation, retryUnavailable: true) != nil else {
                    continuation.resume(returning: cancellation.isCancelled ? .cancelled : .unavailable); return
                }
                raise(id, window: window, cancellation: cancellation, continuation: continuation)
            } else if attempts > 1 {
                waitForRestore(id, window: window, attempts: attempts - 1, cancellation: cancellation, continuation: continuation)
            } else {
                continuation.resume(returning: .failed)
            }
        }
    }

    private func raise(_ id: String, window: AXUIElement, cancellation: WindowSwitcherActionCancellation,
                       continuation: CheckedContinuation<WindowSwitcherActionResult, Never>) {
        // Writable main/focus are hints; read-back verification is authoritative
        // for apps which implement only the raise action. App-level main/focused
        // window attributes are required by some multi-window apps.
        guard !cancellation.isCancelled else { continuation.resume(returning: .cancelled); return }
        _ = access.set(app, attribute: kAXMainWindowAttribute, window: window)
        guard !cancellation.isCancelled else { continuation.resume(returning: .cancelled); return }
        _ = access.set(app, attribute: kAXFocusedWindowAttribute, window: window)
        guard !cancellation.isCancelled else { continuation.resume(returning: .cancelled); return }
        _ = access.set(window, attribute: kAXMainAttribute, value: true)
        guard !cancellation.isCancelled else { continuation.resume(returning: .cancelled); return }
        _ = access.set(window, attribute: kAXFocusedAttribute, value: true)
        guard !cancellation.isCancelled else { continuation.resume(returning: .cancelled); return }
        // Some apps report an unsupported/failed raise after accepting main or
        // focus. Observe exact focus before deciding whether switching failed.
        _ = access.perform(window, action: kAXRaiseAction)
        verifyFocus(id, attempts: 12, cancellation: cancellation, continuation: continuation)
    }

    private func verifyFocus(_ id: String, attempts: Int, cancellation: WindowSwitcherActionCancellation,
                             continuation: CheckedContinuation<WindowSwitcherActionResult, Never>) {
        queue.asyncAfter(deadline: .now() + 0.1) { [self] in
            guard !cancellation.isCancelled else { continuation.resume(returning: .cancelled); return }
            guard !stopped, let record = records.first(where: { $0.id == id }) else {
                continuation.resume(returning: .unavailable); return
            }
            // An unavailable AX list is not evidence that the target closed.
            // Spend the existing verification budget observing, without raising again.
            guard let windows = copyWindows() else {
                if attempts > 1 {
                    verifyFocus(id, attempts: attempts - 1, cancellation: cancellation, continuation: continuation)
                } else {
                    continuation.resume(returning: .failed)
                }
                return
            }
            guard windows.contains(where: { CFEqual($0, record.element) }) else {
                continuation.resume(returning: .unavailable); return
            }
            let live = record.element
            if let focused = copyElement(app, kAXFocusedWindowAttribute), CFEqual(focused, live) {
                continuation.resume(returning: .succeeded)
            } else if attempts > 1 {
                // Retry only the observation, never resubmit an action.
                verifyFocus(id, attempts: attempts - 1, cancellation: cancellation, continuation: continuation)
            } else {
                continuation.resume(returning: .failed)
            }
        }
    }

    static let windowNotifications: [String] =
        [kAXUIElementDestroyedNotification, kAXTitleChangedNotification, kAXWindowMiniaturizedNotification,
         kAXWindowDeminiaturizedNotification, kAXMovedNotification, kAXResizedNotification]
    private func installObserver() {
        guard access.observesSystemNotifications else { return }
        if observer == nil {
            var result: AXObserver?
            let callback: AXObserverCallback = { _, _, notification, context in
                guard let context else { return }
                let worker = Unmanaged<WindowSwitcherProcessWorker>.fromOpaque(context).takeUnretainedValue()
                worker.invalidated(.init(processIdentifier: worker.pid, lifetime: worker.lifetime,
                                         kind: .init(notification: notification as String)))
            }
            observerRegistration.attempt(at: uptime()) {
                AXObserverCreate(pid, callback, &result)
            }
            guard let result else { return }
            observer = result
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(result), .commonModes)
        }
        guard let observer else { return }
        for name in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] {
            applicationSubscriptions[name, default: .init()].attempt(at: uptime()) {
                AXObserverAddNotification(observer, app, name as CFString, Unmanaged.passUnretained(self).toOpaque())
            }
            if applicationSubscriptions[name]?.requiresObserverReset == true { resetObserver(); return }
        }
    }
    private func observe(_ window: AXUIElement) {
        guard let observer else { return }
        let identity = WindowSwitcherAXIdentity(element: window)
        for name in Self.windowNotifications {
            windowSubscriptions[identity, default: [:]][name, default: .init()].attempt(at: uptime()) {
                AXObserverAddNotification(observer, window, name as CFString, Unmanaged.passUnretained(self).toOpaque())
            }
            if windowSubscriptions[identity]?[name]?.requiresObserverReset == true { resetObserver(); return }
        }
    }

    private func resetObserver() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil
        observerRegistration = .init()
        applicationSubscriptions.removeAll()
        windowSubscriptions.removeAll()
    }
}
