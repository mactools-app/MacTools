import AppKit
import ApplicationServices
import OSLog

// Ordinary cross-process AX messaging runs on this serial executor. Lifecycle
// restoration is synchronous so plugin unload and app exit cannot abandon alerts.
@globalActor
actor IslandAXExecutor {
    static let shared = IslandAXExecutor()
}

struct IslandAXElement: @unchecked Sendable {
    let value: AXUIElement
}

@IslandAXExecutor
enum IslandAX {
    static func run<T: Sendable>(_ operation: @IslandAXExecutor @Sendable () -> T) -> T { operation() }

    @discardableResult
    nonisolated static func setMessagingTimeout(_ element: AXUIElement, timeout: Float = 0.05) -> Bool {
        // Elements returned by AX reads and callbacks do not inherit the app timeout.
        return AXUIElementSetMessagingTimeout(element, timeout) == .success
    }

    nonisolated static func value(_ element: AXUIElement, _ attribute: String, timeout: Float = 0.05) -> CFTypeRef? {
        guard setMessagingTimeout(element, timeout: timeout) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String {
        value(element, attribute) as? String ?? ""
    }

    static func children(_ element: AXUIElement, timeout: Float = 0.05) -> [AXUIElement]? {
        guard setMessagingTimeout(element, timeout: timeout) else { return nil }
        var result: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &result)
        if error == .noValue || error == .attributeUnsupported { return [] }
        guard error == .success else { return nil }
        return result as? [AXUIElement]
    }

    static func containingWindow(_ element: AXUIElement) -> AXUIElement? {
        if string(element, kAXRoleAttribute) == kAXWindowRole { return element }
        guard let raw = value(element, kAXWindowAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(raw, to: AXUIElement.self)
    }

    nonisolated static func isInvalid(_ element: AXUIElement) -> Bool {
        guard setMessagingTimeout(element) else { return false }
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &result) == .invalidUIElement
    }

    nonisolated static func position(_ element: AXUIElement, timeout: Float = 0.05) -> CGPoint? {
        guard let raw = value(element, kAXPositionAttribute, timeout: timeout), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = unsafeDowncast(raw, to: AXValue.self)
        var point = CGPoint.zero
        guard AXValueGetType(value) == .cgPoint, AXValueGetValue(value, .cgPoint, &point),
              point.x.isFinite, point.y.isFinite else { return nil }
        return point
    }

    nonisolated static func move(_ window: AXUIElement, to point: CGPoint) -> Bool {
        guard setMessagingTimeout(window) else { return false }
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success
    }

    nonisolated static func frame(_ element: AXUIElement) -> CGRect? {
        guard let origin = position(element),
              let raw = value(element, kAXSizeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = unsafeDowncast(raw, to: AXValue.self)
        var size = CGSize.zero
        guard AXValueGetType(value) == .cgSize, AXValueGetValue(value, .cgSize, &size),
              size.width.isFinite, size.height.isFinite else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Display rectangles in the global top-left coordinates AX positions use.
    nonisolated static func displayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    /// nil when the frame can't be read: unknown is never treated as off screen.
    nonisolated static func isOnAnyDisplay(_ window: AXUIElement) -> Bool? {
        guard let frame = frame(window) else { return nil }
        let displays = displayBounds()
        guard !displays.isEmpty else { return nil }
        return displays.contains { $0.intersects(frame) }
    }

    enum OffScreenMove: Sendable {
        /// Moved, and confirmed to be on no display. `from` is where it was.
        case moved(from: CGPoint)
        /// Already on no display (moved earlier); `at` is where it sits now.
        case alreadyOff(at: CGPoint)
        case failed
    }

    /// Moves a NotificationCenter window off screen and re-reads it to confirm. A window that ignores
    /// the move, or still lands on a display, is put back where it was and reported as failed.
    nonisolated static func moveOffScreen(_ window: AXUIElement, to offscreen: CGPoint) -> OffScreenMove {
        let displays = displayBounds()
        guard let before = frame(window), !displays.isEmpty else { return .failed }
        guard displays.contains(where: { $0.intersects(before) }) else { return .alreadyOff(at: before.origin) }
        guard isPositionSettable(window), move(window, to: offscreen) else { return .failed }
        guard isOnAnyDisplay(window) == false else {
            _ = move(window, to: before.origin)
            return .failed
        }
        return .moved(from: before.origin)
    }

    /// Puts a window MacTools moved back where it was, unless NotificationCenter already placed it
    /// again itself or it is gone. Returns false only when a needed move failed.
    @discardableResult
    nonisolated static func restore(_ window: AXUIElement, to original: CGPoint) -> Bool {
        guard !isInvalid(window), isOnAnyDisplay(window) == false else { return true }
        return move(window, to: original)
    }

    /// Notification Centre has a focused window only while its own panel is open; banners never take
    /// focus (AXFocusedWindow is AXNoValue while one shows). nil = the query failed: unknown.
    nonisolated static func hasFocusedWindow(_ application: AXUIElement) -> Bool? {
        guard setMessagingTimeout(application) else { return nil }
        var result: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &result)
        if error == .noValue { return false }
        guard error == .success, let result, CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return true
    }

    /// Synchronous so stop, unload and quit never leave a window off screen.
    nonisolated static func restoreMovedWindows(_ records: [IslandMovedWindow]) {
        for record in records where !restore(record.window, to: record.original) {
            Logger(subsystem: "MacTools.IslandNotifications", category: "lifecycle")
                .error("Could not put back a moved notification window")
        }
    }

    // The caller must finish restoration before returning from deactivate/quit.
    // Every remote operation below uses the same 0.05-second element timeout.
    nonisolated static func restorePersistentWindows(_ notifications: [IslandNotification], desktopMinX: CGFloat) {
        let logger = Logger(subsystem: "MacTools.IslandNotifications", category: "lifecycle")
        var restored: [AXUIElement] = []
        for notification in notifications where notification.style == .persistent {
            guard !restored.contains(where: { CFEqual($0, notification.window) }),
                  !isInvalid(notification.element) else { continue }
            if let position = position(notification.window), position.x >= desktopMinX - 5000 { continue }
            if !move(notification.window, to: notification.originalPosition) {
                logger.error("Could not restore a hidden persistent notification window")
            }
            restored.append(notification.window)
        }
    }

    static func perform(_ name: String, on element: AXUIElement) -> Bool {
        perform(anyOf: [name], on: element)
    }

    /// Performs the first action whose name is one of `names` (a custom action reads "Name:<name>\n…").
    static func perform(anyOf names: Set<String>, on element: AXUIElement) -> Bool {
        guard setMessagingTimeout(element) else { return false }
        var raw: CFArray?
        guard AXUIElementCopyActionNames(element, &raw) == .success,
              let actions = raw as? [String],
              let action = actions.first(where: { action in
                  names.contains(action) || names.contains { action.hasPrefix("Name:\($0)\n") }
              }) else { return false }
        return AXUIElementPerformAction(element, action as CFString) == .success
    }

    /// A Notification Centre action ("Close", "Show", "Clear All") under every name it has in the
    /// languages Notification Centre ships, read from its own strings: the action is named in the
    /// system language ("Schließen", "閉じる"), whatever language MacTools runs in.
    nonisolated static func centerAction(_ key: String) -> Set<String> {
        centerActionNames[key] ?? [key]
    }

    private nonisolated static let centerActionNames: [String: Set<String>] = {
        let path = "/System/Library/CoreServices/NotificationCenter.app/Contents/Resources/Localizable.loctable"
        guard let data = FileManager.default.contents(atPath: path),
              let table = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [String: Any]]
        else { return [:] }
        var names: [String: Set<String>] = [:]
        for key in ["Close", "Show", "Clear All"] {
            names[key] = Set(table.values.compactMap { $0[key] as? String }).union([key])
        }
        return names
    }()

    nonisolated static func isPositionSettable(_ window: AXUIElement) -> Bool {
        guard setMessagingTimeout(window) else { return false }
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &settable) == .success && settable.boolValue
    }
}

// AX handles and captured content are immutable; UI metadata stays on MainActor.
final class IslandNotification: @unchecked Sendable {
    let element: AXUIElement
    let window: AXUIElement
    let originalPosition: CGPoint
    let style: IslandNotificationStyle
    let title: String
    let body: String
    let identityHints: [String]
    /// Text lines in the banner. A third line is a subtitle, which group conversations use.
    let lineCount: Int
    /// When MacTools received it (system uptime).
    let arrivedAt = ProcessInfo.processInfo.systemUptime
    /// The same moment on the clock, which Messages' history dates are compared with.
    let arrivalDate = Date()
    /// False for a banner that was already on screen when the island first read it (at start, or
    /// after a read it missed): when it really arrived is unknown, so Messages' history can't be
    /// matched to it. Such a card has no reply field and opens Messages itself.
    @MainActor var arrivalConfirmed = true
    /// The Messages conversation this card's message was found in, once found: replies and opening
    /// keep to it.
    @MainActor var messagesChat: IslandMessagesChat.Conversation?
    /// Its entry in the panel's list.
    @MainActor var historyID: UUID?
    /// For a Claude card: MacTools' own notice behind it.
    @MainActor var claudeRequestID: String?
    /// A header label from the banner, e.g. "TIME-SENSITIVE".
    @MainActor var label: String?
    @MainActor var appURL: URL?
    @MainActor var appName: String?
    @MainActor var appIcon: NSImage?
    @MainActor var bundleIdentifier: String? { appURL.flatMap { Bundle(url: $0)?.bundleIdentifier } }
    /// Set for a card made from a finished Claude chat turn (no system banner behind it).
    @MainActor var claudeChat: IslandClaudeChat?
    /// Claude chat cards and Messages banners get the inline reply field. Messages replies go only
    /// to the exact conversation id from Messages' history, so they need that history to be readable
    /// and a confirmed arrival to match it against.
    @MainActor var canReply: Bool {
        claudeChat != nil || (bundleIdentifier == "com.apple.MobileSMS" && arrivalConfirmed && IslandMessagesChat.isAvailable)
    }

    /// A banner with a third line has a subtitle between the title and the message: for a group
    /// conversation, the group's name. Apple draws it in the title's weight, the message in grey.
    @MainActor var subtitle: String? {
        guard lineCount > 2, let first = body.components(separatedBy: "\n").first, !first.isEmpty else { return nil }
        return first
    }

    /// The message alone, without the subtitle line.
    @MainActor var message: String {
        guard let subtitle else { return displayBody }
        return String(displayBody.dropFirst(subtitle.count)).trimmingCharacters(in: .newlines)
    }

    /// Banners carry at most 1,024 characters; a body cut at that limit ends with "…".
    @MainActor var displayBody: String {
        claudeChat == nil && body.count == 1024 ? body + "…" : body
    }

    init(element: AXUIElement, window: AXUIElement, originalPosition: CGPoint,
         style: IslandNotificationStyle, title: String, body: String, identityHints: [String], lineCount: Int = 2) {
        self.element = element
        self.window = window
        self.originalPosition = originalPosition
        self.style = style
        self.title = title
        self.body = body
        self.identityHints = identityHints
        self.lineCount = lineCount
    }

    /// The marks Notification Centre puts between the parts of a description, in every language it
    /// ships: "Messages, Alex, Hi", "メッセージ、Alex、Hi", "信息，Alex，Hi", Arabic "،" with direction marks.
    nonisolated static let descriptionSeparators = CharacterSet(charactersIn: ",、，،\u{200E}\u{200F}").union(.whitespaces)

    /// Extracts the sending app from a banner description: the app comes first, then the title.
    nonisolated static func appName(fromDescription description: String, title: String, body: String) -> String? {
        let trimmed = description.trimmingCharacters(in: descriptionSeparators)
        guard !trimmed.isEmpty else { return nil }
        if !title.isEmpty {
            // The title where it starts a part (after a separator), not inside the app's own name.
            var from = trimmed.startIndex
            while let range = trimmed.range(of: title, range: from..<trimmed.endIndex) {
                // Only where a list mark comes before it: a space alone is part of a name.
                let before = trimmed[..<range.lowerBound]
                let gap = before.reversed().prefix { $0.unicodeScalars.allSatisfy(descriptionSeparators.contains) }
                if gap.contains(where: { ",、，،".contains($0) }) {
                    let app = String(before).trimmingCharacters(in: descriptionSeparators)
                    if !app.isEmpty { return app }
                }
                from = range.upperBound
            }
        }
        let first = trimmed.split(whereSeparator: { $0.unicodeScalars.allSatisfy { ",、，،".unicodeScalars.contains($0) } })
            .first.map { String($0).trimmingCharacters(in: descriptionSeparators) } ?? ""
        return first.isEmpty || first == title ? nil : first
    }

    @MainActor func resolveIdentity() {
        guard identityHints.contains(where: { !$0.isEmpty }) else { return }
        let runningApplications = NSWorkspace.shared.runningApplications
        for hint in identityHints where !hint.isEmpty {
            let running = runningApplications.first {
                $0.bundleIdentifier != "com.apple.notificationcenterui" &&
                    ($0.bundleIdentifier == hint || $0.localizedName == hint)
            }
            let url = running?.bundleURL
                ?? (hint.contains(".") && !hint.contains(" ") ? NSWorkspace.shared.urlForApplication(withBundleIdentifier: hint) : nil)
                ?? Self.installedApplication(named: hint)
            guard let url, url.path != "/System/Library/CoreServices/NotificationCenter.app" else { continue }
            appURL = url
            // Finder's display name keeps ".app" when extensions are shown; the app name never does.
            let fileName = FileManager.default.displayName(atPath: url.path)
            appName = running?.localizedName ?? (fileName.hasSuffix(".app") ? String(fileName.dropLast(4)) : fileName)
            appIcon = running?.icon ?? NSWorkspace.shared.icon(forFile: url.path)
            return
        }
        // Keep the name from the description even when no bundle is found.
        if let first = identityHints.first, !first.isEmpty, !first.contains(", ") { appName = first }
    }

    /// Finds a not-running app by display name in the standard application folders.
    private static func installedApplication(named name: String) -> URL? {
        guard !name.isEmpty, !name.contains("/") else { return nil }
        let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                       NSHomeDirectory() + "/Applications", "/System/Library/CoreServices"]
        for folder in folders {
            let url = URL(fileURLWithPath: folder).appendingPathComponent(name + ".app")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
}

/// A complete structural read is required before moving a full-screen AX window.
struct IslandAXWindowSnapshot: @unchecked Sendable {
    struct Group {
        var lines = 2
        /// A small all-caps header above the title, e.g. "TIME-SENSITIVE".
        var label: String?
        /// The sending app as the banner names it, when its description gives one.
        var app: String?
        let element: AXUIElement
        let style: IslandNotificationStyle
        let title: String
        let body: String
        let hints: [String]
    }
    var groups: [Group] = []
    var unexpected = false
    var complete = true

    @IslandAXExecutor init(window: AXUIElement) {
        var budget = 300
        func card(_ element: AXUIElement, style: IslandNotificationStyle, children: [AXUIElement]) {
            var text: [String] = []
            var hints = [kAXDescriptionAttribute, kAXTitleAttribute, kAXIdentifierAttribute].map { IslandAX.string(element, $0) }
            for child in children {
                let role = IslandAX.string(child, kAXRoleAttribute)
                if role == kAXStaticTextRole {
                    text.append(IslandAX.string(child, kAXValueAttribute))
                } else if role == kAXImageRole {
                    hints += [kAXDescriptionAttribute, kAXTitleAttribute, kAXIdentifierAttribute].map { IslandAX.string(child, $0) }
                }
            }
            guard !text.isEmpty, text.contains(where: { !$0.isEmpty }) else { complete = false; return }
            // Time Sensitive (and similar) banners put a short all-caps label above the title.
            var label: String?
            if text.count >= 3, let first = text.first, first.count <= 24,
               first.rangeOfCharacter(from: .letters) != nil, first.rangeOfCharacter(from: .lowercaseLetters) == nil {
                label = first
                text.removeFirst()
            }
            let title = text.first ?? ""
            let body = text.dropFirst().joined(separator: "\n")
            // macOS 27 describes a banner as "<App>, <title>, <body>"; the app comes first.
            let app = IslandNotification.appName(fromDescription: hints.first ?? "", title: title, body: body)
            if let app { hints.insert(app, at: 0) }
            var group = Group(element: element, style: style, title: title, body: body, hints: hints)
            group.app = app
            group.lines = text.count
            group.label = label
            groups.append(group)
        }
        /// `stack` is set inside a grouped stack: a plain group there that directly holds the text is
        /// one complete card of that stack (Vorssaint's findStackCards does the same).
        func walk(_ element: AXUIElement, depth: Int, stack: IslandNotificationStyle? = nil) {
            guard complete, !unexpected else { return }
            guard budget > 0, depth < 20 else { complete = false; return }
            budget -= 1
            let role = IslandAX.string(element, kAXRoleAttribute)
            let subrole = IslandAX.string(element, kAXSubroleAttribute)
            if role == kAXGroupRole, let stackStyle = IslandNotificationStyle(stackSubrole: subrole) {
                guard let children = IslandAX.children(element) else { complete = false; return }
                // A stack that holds the text itself is a single card; otherwise descend into its cards.
                if children.contains(where: { IslandAX.string($0, kAXRoleAttribute) == kAXStaticTextRole }) {
                    card(element, style: stackStyle, children: children)
                    return
                }
                for child in children {
                    walk(child, depth: depth + 1, stack: stackStyle)
                    if unexpected || !complete { return }
                }
                return
            }
            if role == kAXGroupRole, let style = IslandNotificationStyle(subrole: subrole) {
                guard let children = IslandAX.children(element) else { complete = false; return }
                card(element, style: style, children: children)
                return
            }
            if let stack, role == kAXGroupRole, subrole.isEmpty {
                guard let children = IslandAX.children(element) else { complete = false; return }
                if children.contains(where: { IslandAX.string($0, kAXRoleAttribute) == kAXStaticTextRole }) {
                    card(element, style: stack, children: children)
                    return
                }
                for child in children {
                    walk(child, depth: depth + 1, stack: stack)
                    if unexpected || !complete { return }
                }
                return
            }
            // Structural wrappers are allowed; history, controls and unrelated text aren't.
            // macOS 27 wraps banners in a SwiftUI hosting container (AXGroup/AXHostingView) under the window.
            // Since 2026-11-16 the banner scroll area can also be AXScrollArea/AXScrollAreaAutoFocus.
            let structuralSubrole = subrole.isEmpty || subrole == "AXSystemDialog" || (role == kAXGroupRole && subrole == "AXHostingView")
                || (role == kAXScrollAreaRole && subrole == "AXScrollAreaAutoFocus")
            guard [kAXWindowRole, kAXGroupRole, kAXScrollAreaRole].contains(role), structuralSubrole else {
                unexpected = true; return
            }
            guard let children = IslandAX.children(element) else { complete = false; return }
            for child in children {
                walk(child, depth: depth + 1)
                if unexpected || !complete { return }
            }
        }
        guard IslandAX.string(window, kAXRoleAttribute) == kAXWindowRole,
              IslandAX.string(window, kAXSubroleAttribute) == "AXSystemDialog" else {
            unexpected = true
            return
        }
        walk(window, depth: 0)
    }
}

// The run-loop source is managed on main; registration and removal can message
// the remote process, so they belong to the AX executor too.
private final class IslandAXSession: @unchecked Sendable {
    let observer: AXObserver
    let application: AXUIElement
    init(observer: AXObserver, application: AXUIElement) {
        self.observer = observer; self.application = application
    }
}

@MainActor
final class IslandNotificationObserver {
    var onWindow: ((IslandAXElement) -> Void)?
    var onRemoved: ((IslandAXElement) -> Void)?
    /// Notification Centre's focused window changed: its panel opened or closed.
    var onFocusChanged: (() -> Void)?
    private var session: IslandAXSession?
    private var generation = 0
    private var starting = false
    private var retry: DispatchWorkItem?
    private var processSource: DispatchSourceProcess?
    private(set) var pid: pid_t?
    private var pendingElements: [IslandAXElement] = []
    private var flush: DispatchWorkItem?

    func start(onAttached: @escaping () -> Void, onExit: @escaping () -> Void) {
        guard session == nil, !starting, retry == nil else { return }
        attach(remaining: 10, generation: generation, onAttached: onAttached, onExit: onExit)
    }

    private func attach(remaining: Int, generation: Int,
                        onAttached: @escaping () -> Void, onExit: @escaping () -> Void) {
        guard self.generation == generation, AXIsProcessTrusted() else { return }
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleURL?.path == "/System/Library/CoreServices/NotificationCenter.app"
        }) else {
            scheduleRetry(remaining: remaining, generation: generation, onAttached: onAttached, onExit: onExit)
            return
        }
        starting = true
        let pid = app.processIdentifier
        // Keep self alive until registration either attaches or removes its context.
        let context = UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque())
        Task {
            let next = await IslandAX.run { () -> IslandAXSession? in
                let application = AXUIElementCreateApplication(pid)
                guard IslandAX.setMessagingTimeout(application) else { return nil }
                var observer: AXObserver?
                let status = AXObserverCreate(pid, islandAXObserverCallback, &observer)
                guard status == .success, let observer,
                      AXObserverAddNotification(observer, application, kAXCreatedNotification as CFString,
                                                UnsafeMutableRawPointer(bitPattern: context)) == .success else { return nil }
                // Optional: without it, every read still checks focus first.
                _ = AXObserverAddNotification(observer, application, kAXFocusedWindowChangedNotification as CFString,
                                              UnsafeMutableRawPointer(bitPattern: context))
                return IslandAXSession(observer: observer, application: application)
            }
            guard self.generation == generation else {
                if let next { await Self.remove(next) }
                return
            }
            starting = false
            guard let next else {
                scheduleRetry(remaining: remaining, generation: generation, onAttached: onAttached, onExit: onExit)
                return
            }
            session = next
            self.pid = pid
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(next.observer), .commonModes)
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
            source.setEventHandler { [weak owner = self] in
                MainActor.assumeIsolated {
                    guard let owner, owner.generation == generation else { return }
                    owner.stop()
                    onExit()
                }
            }
            processSource = source
            source.resume()
            onAttached()
        }
    }

    private func scheduleRetry(remaining: Int, generation: Int,
                               onAttached: @escaping () -> Void, onExit: @escaping () -> Void) {
        guard remaining > 1, self.generation == generation else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == generation else { return }
            self.retry = nil
            self.attach(remaining: remaining - 1, generation: generation, onAttached: onAttached, onExit: onExit)
        }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200), execute: work)
    }

    func windows() async -> [IslandAXElement] {
        guard let session else { return [] }
        return await IslandAX.run {
            (IslandAX.value(session.application, kAXWindowsAttribute) as? [AXUIElement] ?? []).map { IslandAXElement(value: $0) }
        }
    }

    /// Whether Notification Centre's own panel is open. nil when unknown (not attached, or the query failed).
    func centerFocus() async -> Bool? {
        guard let session else { return nil }
        return await IslandAX.run { IslandAX.hasFocusedWindow(session.application) }
    }

    fileprivate func focusChanged() { onFocusChanged?() }

    func observeRemoval(of elements: [IslandAXElement]) async {
        guard let session else { return }
        let context = UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque())
        await IslandAX.run {
            for element in elements where IslandAX.setMessagingTimeout(element.value) {
                _ = AXObserverAddNotification(session.observer, element.value, kAXUIElementDestroyedNotification as CFString,
                                              UnsafeMutableRawPointer(bitPattern: context))
            }
        }
    }

    fileprivate func created(_ element: AXUIElement) {
        if !pendingElements.contains(where: { CFEqual($0.value, element) }) { pendingElements.append(IslandAXElement(value: element)) }
        guard flush == nil else { return }
        let generation = generation
        // Fixed from the first event: a busy event stream must not postpone hiding.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.session != nil, self.generation == generation else { return }
            let elements = self.pendingElements
            self.pendingElements.removeAll()
            self.flush = nil
            Task {
                let windows = await IslandAX.run {
                    var windows: [IslandAXElement] = []
                    for element in elements {
                        if let window = IslandAX.containingWindow(element.value),
                           !windows.contains(where: { CFEqual($0.value, window) }) {
                            windows.append(IslandAXElement(value: window))
                        }
                    }
                    return windows
                }
                guard self.generation == generation else { return }
                for window in windows { self.onWindow?(window) }
            }
        }
        flush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(2), execute: work)
    }

    private static func remove(_ session: IslandAXSession) async {
        await IslandAX.run {
            if IslandAX.setMessagingTimeout(session.application) {
                AXObserverRemoveNotification(session.observer, session.application, kAXCreatedNotification as CFString)
                AXObserverRemoveNotification(session.observer, session.application, kAXFocusedWindowChangedNotification as CFString)
            }
        }
    }

    func stop() {
        generation += 1; starting = false
        retry?.cancel(); retry = nil
        processSource?.cancel(); processSource = nil
        flush?.cancel(); flush = nil; pendingElements.removeAll()
        if let session {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(session.observer), .commonModes)
            Task { await Self.remove(session) }
        }
        session = nil; pid = nil
    }

    isolated deinit { stop() }
}

/// AX delivers observer callbacks on the run loop that owns the observer's source, which is the
/// main run loop here. Declaring the callback at file scope keeps it nonisolated: written inside an
/// `@IslandAXExecutor` closure, Swift 6 would infer that actor's isolation and abort on the first
/// callback when its executor check fails on the main thread.
private func islandAXObserverCallback(_ observer: AXObserver, _ element: AXUIElement,
                                      _ notification: CFString, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let address = UInt(bitPattern: context)
    let wrapped = IslandAXElement(value: element)
    let removed = CFEqual(notification, kAXUIElementDestroyedNotification as CFString)
    let focus = CFEqual(notification, kAXFocusedWindowChangedNotification as CFString)
    MainActor.assumeIsolated {
        guard let context = UnsafeMutableRawPointer(bitPattern: address) else { return }
        let owner = Unmanaged<IslandNotificationObserver>.fromOpaque(context).takeUnretainedValue()
        if removed { owner.onRemoved?(wrapped) }
        else if focus { owner.focusChanged() }
        else { owner.created(wrapped.value) }
    }
}

/// Replies into a Claude Code chat in the desktop app without bringing Claude forward. Claude has no
/// scripting interface, so this drives its accessibility interface: when another chat is open, that
/// chat's sidebar entry is pressed in the background; nothing is typed until the window shows exactly
/// the expected chat; an unsent draft in Claude is never overwritten, and a failed send leaves the
/// box as it was. Claude is never brought forward: its own chat link (which always activates it) is
/// used only while Claude is already in front.
enum IslandClaudeReply {
    static let bundleIdentifier = "com.anthropic.claudefordesktop"
    /// Steps only, never message text.
    private static let logger = Logger(subsystem: "MacTools.IslandNotifications", category: "reply")

    /// One pass over Claude's focused window (a few hundred elements).
    fileprivate struct Scan: @unchecked Sendable {
        var chatTitle = ""
        var prompt: AXUIElement?
        var send: AXUIElement?
        var busy = false
        var sidebarEntries: [AXUIElement] = []
    }

    @MainActor
    static func send(_ text: String, to card: IslandClaudeChat) async -> IslandReplyOutcome {
        // The card's chat as Claude records it now: a chat opened or renamed since the card arrived
        // may share its title, and the title is all the window shows.
        let localID = card.localID
        guard let chat = await Task.detached(priority: .userInitiated, operation: {
            IslandClaudeTurnWatcher.desktopChat(localID: localID)
        }).value else { return .failed }
        guard chat.isUnique else { return .ambiguousChat }
        guard let claude = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
            return .failed
        }
        let pid = claude.processIdentifier
        // Electron exposes its page only while asked to. It stays on afterwards: switching it off
        // makes every later reply wait about two seconds while Claude rebuilds its page.
        await IslandAX.run { enableWebAccessibility(pid: pid) }
        return await deliver(text, pid: pid, chat: chat)
    }

    /// The page title is exactly "<chat title> - Claude Code" (so "Foo" never matches "Foo bar").
    nonisolated static func isShowing(_ title: String, in pageTitle: String) -> Bool {
        pageTitle == title + " - Claude Code" || pageTitle == title + " - Claude"
    }

    @MainActor
    private static func deliver(_ text: String, pid: pid_t, chat: IslandClaudeChat) async -> IslandReplyOutcome {
        let title = chat.title
        // Right after accessibility is switched on, Claude needs a moment to expose its page.
        var scan = IslandClaudeReply.Scan()
        var attempts = 0
        while attempts < 16 {
            attempts += 1
            scan = await IslandAX.run { read(pid: pid, sidebarTitle: title) }
            if scan.prompt != nil, !scan.chatTitle.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(150))
        }
        logger.notice("claude page ready=\(scan.prompt != nil, privacy: .public) attempts=\(attempts, privacy: .public) showing=\(isShowing(title, in: scan.chatTitle), privacy: .public) entries=\(scan.sidebarEntries.count, privacy: .public)")
        guard scan.prompt != nil, !scan.chatTitle.isEmpty else { return .failed }
        guard scan.sidebarEntries.count <= 1 else { logger.notice("claude sidebar has the title twice"); return .ambiguousChat }
        if !isShowing(title, in: scan.chatTitle) {
            if scan.sidebarEntries.count == 1, let entry = scan.sidebarEntries.first.map(IslandAXElement.init) {
                _ = await IslandAX.run { AXUIElementPerformAction(entry.value, kAXPressAction as CFString) == .success }
            } else if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, let link = chat.link {
                // Claude's link always brings Claude forward, so it is used only when Claude is
                // already in front. Otherwise the reply fails and the card offers to open the chat:
                // Claude never flashes up behind a reply.
                _ = try? await NSWorkspace.shared.open(link)
            } else {
                logger.notice("claude chat not in the sidebar")
                return .failed
            }
            // Wait until the chat has opened and stayed open for two checks in a row.
            var matches = 0
            for _ in 0..<20 where matches < 2 {
                try? await Task.sleep(for: .milliseconds(150))
                scan = await IslandAX.run { read(pid: pid, sidebarTitle: nil) }
                matches = scan.prompt != nil && isShowing(title, in: scan.chatTitle) ? matches + 1 : 0
            }
            logger.notice("claude chat opened=\(matches >= 2, privacy: .public)")
            guard matches >= 2 else { return .failed }
        }
        guard let prompt = scan.prompt.map(IslandAXElement.init) else { return .failed }
        // "Stop" is the English label; the session's own log says the same in every language.
        let localID = chat.localID
        let working = await Task.detached(priority: .userInitiated) { IslandClaudeTurnWatcher.isWorking(localID: localID) }.value
        let busy = scan.busy || working
        // Never overwrite text the user left unsent in that chat.
        let existing = await IslandAX.run { promptText(prompt.value) }
        guard let existing else { return .failed }
        guard existing.isEmpty else { logger.notice("claude chat has an unsent draft"); return .claudeDraft }
        // Still that chat, and still the only one with its title, just before the text goes in.
        guard await stillTarget(chat, pid: pid) else { return .ambiguousChat }
        let filled = await IslandAX.run { () -> Bool in
            guard AXUIElementSetAttributeValue(prompt.value, kAXValueAttribute as CFString, text as CFString) == .success else { return false }
            return AXUIElementSetAttributeValue(prompt.value, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
        }
        guard filled else { return .failed }
        try? await Task.sleep(for: .milliseconds(150))
        // Idle: press Claude's Send button (it appears once there is text). Working: Command-Return
        // queues the reply instead of interrupting. Both work with Claude in the background.
        // The window can change chat while the text goes in; then nothing is sent and the text is taken back.
        let final = await IslandAX.run { read(pid: pid, sidebarTitle: nil) }
        guard isShowing(title, in: final.chatTitle) else {
            logger.notice("claude chat changed before sending")
            await takeBack(text, from: prompt)
            return .failed
        }
        let pressed = busy ? false : await IslandAX.run { () -> Bool in
            guard let send = final.send else { return false }
            return AXUIElementPerformAction(send, kAXPressAction as CFString) == .success
        }
        if !pressed {
            let source = CGEventSource(stateID: .privateState)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: down)
                if busy { event?.flags = .maskCommand }
                event?.postToPid(pid)
            }
        }
        logger.notice("claude submit busy=\(busy, privacy: .public) sendButton=\(pressed, privacy: .public)")
        // Sent (or queued) once the message box has emptied.
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(150))
            if await IslandAX.run({ promptText(prompt.value) })?.isEmpty == true { return .sent }
        }
        logger.notice("claude send not confirmed")
        await takeBack(text, from: prompt)
        return .failed
    }

    /// Not sent: the box goes back to empty, as it was, but only while it still holds just this
    /// reply, so nothing typed there meanwhile is lost.
    private static func takeBack(_ text: String, from prompt: IslandAXElement) async {
        _ = await IslandAX.run { () -> Bool in
            guard promptText(prompt.value) == text else { return false }
            return AXUIElementSetAttributeValue(prompt.value, kAXValueAttribute as CFString, "" as CFString) == .success
        }
    }

    /// The chat on screen is still this one, the sidebar shows its title at most once, and Claude's
    /// records still give no other open chat that title.
    private static func stillTarget(_ chat: IslandClaudeChat, pid: pid_t) async -> Bool {
        let scan = await IslandAX.run { read(pid: pid, sidebarTitle: chat.title) }
        guard isShowing(chat.title, in: scan.chatTitle), scan.sidebarEntries.count <= 1 else { return false }
        let localID = chat.localID
        let now = await Task.detached(priority: .userInitiated) { IslandClaudeTurnWatcher.desktopChat(localID: localID) }.value
        return now?.title == chat.title && now?.isUnique == true
    }

    @IslandAXExecutor
    private static func promptText(_ prompt: AXUIElement) -> String? {
        (IslandAX.value(prompt, kAXValueAttribute, timeout: 0.5) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let manualAccessibility = "AXManualAccessibility"

    @IslandAXExecutor
    fileprivate static func enableWebAccessibility(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        IslandAX.setMessagingTimeout(app, timeout: 0.5)
        if (IslandAX.value(app, manualAccessibility, timeout: 0.5) as? Bool) == true { return }
        AXUIElementSetAttributeValue(app, manualAccessibility as CFString, kCFBooleanTrue)
    }

    /// Reads the open chat's title, the message box, the Send button, whether Claude is working and
    /// (when `sidebarTitle` is set) the sidebar entries for that chat: "<title>" or "<title> Running".
    /// Reads structure only.
    @IslandAXExecutor
    fileprivate static func read(pid: pid_t, sidebarTitle: String?) -> Scan {
        let app = AXUIElementCreateApplication(pid)
        IslandAX.setMessagingTimeout(app, timeout: 0.5)
        var scan = Scan()
        guard let window = IslandAX.value(app, kAXFocusedWindowAttribute, timeout: 0.5) else { return scan }
        var budget = 3000
        func walk(_ element: AXUIElement, depth: Int) {
            guard budget > 0, depth < 60 else { return }
            budget -= 1
            let role = IslandAX.value(element, kAXRoleAttribute, timeout: 0.5) as? String ?? ""
            switch role {
            case "AXWebArea" where scan.chatTitle.isEmpty:
                // The outer web area has no title; the chat page inside it does.
                scan.chatTitle = IslandAX.value(element, kAXTitleAttribute, timeout: 0.5) as? String ?? ""
            case "AXTextArea":
                // Claude's message box is its ProseMirror editor; "Prompt" is its English label.
                let classes = IslandAX.value(element, "AXDOMClassList", timeout: 0.5) as? [String] ?? []
                if classes.contains("ProseMirror")
                    || IslandAX.value(element, kAXDescriptionAttribute, timeout: 0.5) as? String == "Prompt" { scan.prompt = element }
                return
            case "AXButton":
                let label = IslandAX.value(element, kAXDescriptionAttribute, timeout: 0.5) as? String ?? ""
                if label == "Stop" { scan.busy = true }
                if label == "Send" { scan.send = element }
                if let sidebarTitle, let title = IslandAX.value(element, kAXTitleAttribute, timeout: 0.5) as? String,
                   title.hasPrefix(sidebarTitle), entryTitle(element) == sidebarTitle {
                    scan.sidebarEntries.append(element)
                }
                return
            case "AXStaticText", "AXImage":
                return
            default:
                break
            }
            for child in IslandAX.children(element, timeout: 0.5) ?? [] { walk(child, depth: depth + 1) }
        }
        walk(window as! AXUIElement, depth: 0)
        return scan
    }

    /// A sidebar entry is a button around a label whose first text is the chat's title; status text
    /// such as "Running" or "Forked from …" follows it. Links to a chat inside a transcript have no
    /// such label, so they never count as its entry.
    @IslandAXExecutor
    private static func entryTitle(_ button: AXUIElement) -> String? {
        guard let label = IslandAX.children(button, timeout: 0.5)?.first,
              IslandAX.value(label, kAXRoleAttribute, timeout: 0.5) as? String == kAXGroupRole,
              let text = IslandAX.children(label, timeout: 0.5)?.first,
              IslandAX.value(text, kAXRoleAttribute, timeout: 0.5) as? String == kAXStaticTextRole else { return nil }
        return IslandAX.value(text, kAXValueAttribute, timeout: 0.5) as? String
    }
}

/// A Claude Code chat in the desktop app: its app-side id (for Claude's own chat link) and title.
struct IslandClaudeChat: Equatable, Sendable {
    let localID: String
    let title: String
    /// False when another open chat has the same title: the chat could not be told apart on screen.
    var isUnique = true

    var link: URL? {
        var components = URLComponents(string: "claude://code/continue")
        components?.queryItems = [URLQueryItem(name: "session", value: localID), URLQueryItem(name: "source", value: "desktop_action")]
        return components?.url
    }
}

/// Follows Claude Code's own session logs (`~/.claude/projects/<project>/<session>.jsonl`), which every
/// session writes, terminal and desktop alike, so nothing needs setting up. macOS reports changes
/// to those files (FSEvents); nothing is polled, and only the lines added since the last read are
/// decoded. Claude's reply that ends a turn becomes a card.
@MainActor
final class IslandClaudeTurnWatcher {
    struct Turn: Sendable {
        let chat: IslandClaudeChat
        let message: String
    }

    /// The folder the old Stop-hook route wrote to; removed so a leftover hook stops writing.
    static var legacyDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacTools/ClaudeTurns", isDirectory: true)
    }

    nonisolated static var logRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [".claude/projects", ".config/claude/projects"].map { home.appendingPathComponent($0, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    var onTurn: ((Turn) -> Void)?
    private var stream: FSEventStreamRef?
    private var reader: IslandClaudeTranscriptReader?
    private let queue = DispatchQueue(label: "MacTools.IslandNotifications.ClaudeLogs", qos: .utility)
    /// Bumped by every stop, so a turn read just before it is not shown after it.
    private var generation = 0

    func start() {
        guard stream == nil else { return }
        try? FileManager.default.removeItem(at: Self.legacyDirectory)
        let roots = Self.logRoots
        guard !roots.isEmpty else { return }
        let generation = generation
        let reader = IslandClaudeTranscriptReader(roots: roots) { [weak self] turn in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.generation == generation else { return }
                    self.onTurn?(turn)
                }
            }
        }
        guard let stream = Self.makeStream(paths: roots.map(\.path), reader: reader, queue: queue) else { return }
        self.reader = reader
        self.stream = stream
    }

    /// Built outside the main actor: FSEvents calls back on `queue`.
    nonisolated private static func makeStream(paths: [String], reader: IslandClaudeTranscriptReader,
                                               queue: DispatchQueue) -> FSEventStreamRef? {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(reader).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let reader = Unmanaged<IslandClaudeTranscriptReader>.fromOpaque(info).takeUnretainedValue()
            let paths = (unsafeBitCast(eventPaths, to: NSArray.self) as? [String]) ?? []
            reader.changed(paths)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                                             | kFSEventStreamCreateFlagNoDefer)
        // 0.3 s coalesces Claude's bursts of writes into one read.
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, paths as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else { return nil }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
            return nil
        }
        return stream
    }

    func stop() {
        generation += 1
        if let stream {
            FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
            // FSEvents holds the reader unretained. A callback already queued may still run, so the
            // queue keeps the reader until it has; the main thread never waits for a log read.
            if let reader { queue.async { withExtendedLifetime(reader) {} } }
        }
        stream = nil; reader = nil
    }

    isolated deinit { stop() }

    /// Whether this desktop chat is in the middle of a turn, from its Claude Code session log: the
    /// last entry is not Claude's reply that ends a turn, and the log moved in the last 15 minutes.
    nonisolated static func isWorking(localID: String) -> Bool {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return false }
        var session: String?
        for case let file as URL in enumerator where file.lastPathComponent.hasPrefix("local_") && file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  info["sessionId"] as? String == localID else { continue }
            session = info["cliSessionId"] as? String ?? info["lastAssistantCliSessionId"] as? String
            break
        }
        guard let session else { return false }
        for root in logRoots {
            guard let projects = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for project in projects {
                let log = project.appendingPathComponent(session + ".jsonl")
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: log.path),
                      let modified = attributes[.modificationDate] as? Date else { continue }
                guard Date().timeIntervalSince(modified) < 15 * 60, let handle = try? FileHandle(forReadingFrom: log) else { return false }
                defer { try? handle.close() }
                let size = (attributes[.size] as? UInt64) ?? 0
                try? handle.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
                let tail = handle.readDataToEndOfFile()
                for line in tail.split(separator: 0x0A).reversed() {
                    guard let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                          let type = entry["type"] as? String else { continue }
                    if type == "assistant" {
                        let stop = (entry["message"] as? [String: Any])?["stop_reason"] as? String
                        return !["end_turn", "stop_sequence", "max_tokens", "refusal"].contains(stop ?? "")
                    }
                    if type == "user" {
                        return !String(decoding: line, as: UTF8.self).contains("[Request interrupted")
                    }
                }
                return false
            }
        }
        return false
    }

    /// One open chat in Claude's records: its app-side id, title and the Claude Code sessions it ran.
    struct DesktopSession: Equatable, Sendable {
        let localID: String
        let title: String
        let cliSessionIDs: [String]
    }

    nonisolated static func desktopSessions() -> [DesktopSession] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var sessions: [DesktopSession] = []
        for case let file as URL in enumerator where file.lastPathComponent.hasPrefix("local_") && file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (info["isArchived"] as? Bool) != true,
                  let localID = info["sessionId"] as? String else { continue }
            let cli = [info["cliSessionId"], info["lastAssistantCliSessionId"]].compactMap { $0 as? String }
            sessions.append(DesktopSession(localID: localID, title: info["title"] as? String ?? "Claude", cliSessionIDs: cli))
        }
        return sessions
    }

    /// The chat found by `matches`, unique only while no other open chat has its title: the title is
    /// all Claude's window shows to tell chats apart.
    nonisolated static func desktopChat(in sessions: [DesktopSession], where matches: (DesktopSession) -> Bool) -> IslandClaudeChat? {
        guard let session = sessions.first(where: matches) else { return nil }
        var chat = IslandClaudeChat(localID: session.localID, title: session.title)
        chat.isUnique = sessions.filter { $0.title == session.title }.count == 1
        return chat
    }

    /// The desktop chat that runs this Claude Code session (none for terminal sessions).
    nonisolated static func desktopChat(forSession sessionID: String) -> IslandClaudeChat? {
        desktopChat(in: desktopSessions()) { $0.cliSessionIDs.contains(sessionID) }
    }

    /// The same chat as it is now: its current title, and whether another chat has taken that title since.
    nonisolated static func desktopChat(localID: String) -> IslandClaudeChat? {
        desktopChat(in: desktopSessions()) { $0.localID == localID }
    }

    /// The text of the last assistant entry in a Claude Code transcript (JSON lines), read from its tail.
    nonisolated static func lastAssistantMessage(in path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 512_000 ? size - 512_000 : 0)
        guard let data = try? handle.readToEnd(), let tail = String(data: data, encoding: .utf8) else { return nil }
        for line in tail.split(separator: "\n").reversed() {
            guard line.contains("\"assistant\""),
                  let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  entry["type"] as? String == "assistant",
                  let message = entry["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        }
        return nil
    }

    /// Plain text for the card: Markdown marks removed, links reduced to their text, and extremely
    /// long messages cut (the card scrolls; the full message stays in Claude).
    nonisolated static func cleaned(_ markdown: String) -> String {
        var text = markdown
        let replacements: [(String, String)] = [
            (#"\[([^\]]+)\]\([^)]+\)"#, "$1"),
            (#"(?m)^#{1,6}\s+"#, ""),
            (#"(?m)^\s*[-*]\s+"#, "• "),
            (#"\*\*|__|`"#, ""),
            (#"\n{3,}"#, "\n\n"),
        ]
        for (pattern, template) in replacements {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > 12000 ? String(text.prefix(12000)) + "…" : text
    }
}

/// Reads the lines Claude Code appends to its session logs. Used only on the watcher's queue.
final class IslandClaudeTranscriptReader: @unchecked Sendable {
    /// Only this much of an existing log is read the first time it changes (once per session per launch).
    private static let firstReadLimit: UInt64 = 1024 * 1024

    private struct LogFile {
        var offset: UInt64
        /// Lines older than this were written before MacTools was watching: not new.
        var notBefore: Date?
    }

    private let roots: [String]
    private let deliver: @Sendable (IslandClaudeTurnWatcher.Turn) -> Void
    private let started = Date()
    private var files: [String: LogFile] = [:]
    private let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(roots: [URL], deliver: @escaping @Sendable (IslandClaudeTurnWatcher.Turn) -> Void) {
        self.roots = roots.map { $0.standardizedFileURL.path }
        self.deliver = deliver
    }

    /// Called with the paths FSEvents reported.
    func changed(_ paths: [String]) {
        for path in Set(paths) where isSessionLog(path) { read(path) }
    }

    /// `<root>/<project>/<session>.jsonl` only: subagent logs live one folder deeper.
    private func isSessionLog(_ path: String) -> Bool {
        guard path.hasSuffix(".jsonl"), let root = roots.first(where: { path.hasPrefix($0 + "/") }) else { return false }
        let parts = path.dropFirst(root.count + 1).split(separator: "/")
        return parts.count == 2 && !parts[0].hasPrefix(".")
    }

    private func read(_ path: String) {
        guard let handle = FileHandle(forReadingAtPath: path) else { files[path] = nil; return }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return }
        let firstSight = files[path] == nil
        var file = files[path] ?? Self.firstSight(path, size: size, started: started)
        if size < file.offset { file = LogFile(offset: 0, notBefore: nil) }
        guard size > file.offset else { files[path] = file; return }
        try? handle.seek(toOffset: file.offset)
        guard let data = try? handle.read(upToCount: Int(size - file.offset)),
              let lastNewline = data.lastIndex(of: 0x0A) else { files[path] = file; return }
        // A line still being written stays for the next read.
        let complete = data[data.startIndex...lastNewline]
        var lines = complete.split(separator: 0x0A, omittingEmptySubsequences: true)
        if firstSight, file.offset > 0, !lines.isEmpty { lines.removeFirst() } // cut mid-line
        file.offset += UInt64(complete.count)
        files[path] = file
        let fallbackSession = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        for line in lines { apply(line, path: path, fallbackSession: fallbackSession, notBefore: file.notBefore) }
    }

    private static func firstSight(_ path: String, size: UInt64, started: Date) -> LogFile {
        let created = (try? FileManager.default.attributesOfItem(atPath: path)[.creationDate] as? Date) ?? .distantPast
        // A log created while watching is read whole; an older one only from near its end, and only
        // its lines written since MacTools started count.
        if created >= started.addingTimeInterval(-2) { return LogFile(offset: 0, notBefore: nil) }
        return LogFile(offset: size > firstReadLimit ? size - firstReadLimit : 0, notBefore: started)
    }

    /// Claude's reply that ends a turn (`stop_reason` end_turn and the like) becomes a card.
    private func apply(_ line: Data.SubSequence, path: String, fallbackSession: String, notBefore: Date?) {
        // Cheap test before decoding anything.
        guard line.range(of: Data("\"type\":\"assistant\"".utf8)) != nil,
              line.range(of: Data("\"stop_reason\":\"".utf8)) != nil,
              let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              entry["type"] as? String == "assistant", entry["isSidechain"] as? Bool != true,
              let message = entry["message"] as? [String: Any],
              let stop = message["stop_reason"] as? String,
              ["end_turn", "stop_sequence", "max_tokens", "refusal"].contains(stop) else { return }
        if let notBefore {
            let time = (entry["timestamp"] as? String).flatMap { timestampFormatter.date(from: $0) } ?? .distantPast
            guard time >= notBefore else { return }
        }
        let session = entry["sessionId"] as? String ?? fallbackSession
        let blocks = message["content"] as? [[String: Any]] ?? []
        var text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = IslandClaudeTurnWatcher.lastAssistantMessage(in: path) ?? ""
        }
        let cleaned = IslandClaudeTurnWatcher.cleaned(text)
        // Only desktop chats get a card: a reply goes into the chat in the Claude app.
        guard !cleaned.isEmpty, let chat = IslandClaudeTurnWatcher.desktopChat(forSession: session) else { return }
        deliver(IslandClaudeTurnWatcher.Turn(chat: chat, message: cleaned))
    }
}
