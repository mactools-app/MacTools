import AppKit
import ApplicationServices
import OSLog

// MARK: Layout
//
// Apple's compact Live Activity puts a leading element (the glyph) and a trailing element (here the
// percentage) on either side of the camera, inside one black capsule that continues the island. When
// there isn't room it steps down like the minimal presentation: the glyph alone on one side. It never
// covers a menu or a status item: macOS doesn't lay the menu bar out around it, so the free space on
// each side of the island is measured and the activity uses only what is free.

enum DownloadIslandLayout: Equatable {
    /// Glyph (and the file name, when there is room) left of the island, percentage right of it.
    case compact(capsule: CGRect, island: CGRect, leadingWidth: CGFloat)
    /// Glyph only, on the leading side.
    case leading(capsule: CGRect, island: CGRect)
    /// Glyph only, on the trailing side.
    case trailing(capsule: CGRect, island: CGRect)
    /// A system activity already holds the island: a detached bubble beside it, as macOS 27 shows
    /// its own second Live Activity.
    case minimal(capsule: CGRect, island: CGRect)
    case hidden

    var capsule: CGRect? {
        switch self {
        case .compact(let capsule, _, _), .leading(let capsule, _), .trailing(let capsule, _), .minimal(let capsule, _): capsule
        case .hidden: nil
        }
    }

    var island: CGRect? {
        switch self {
        case .compact(_, let island, _), .leading(_, let island), .trailing(_, let island), .minimal(_, let island): island
        case .hidden: nil
        }
    }

    var showsPercent: Bool { if case .compact = self { true } else { false } }
    var isDetached: Bool { if case .minimal = self { true } else { false } }
    var leadingWidth: CGFloat { if case .compact(_, _, let width) = self { width } else { DownloadIslandMetrics.glyphWing } }

    /// `leftLimit`/`rightLimit`: the nearest menu, status item or system activity on each side (x).
    /// `nameWidth`: the file name's width, shown beside the glyph only when that much is free.
    static func resolve(island: CGRect, systemActivity: Bool, nameWidth: CGFloat?,
                        leftLimit: CGFloat, rightLimit: CGFloat) -> Self {
        let glyph = DownloadIslandMetrics.glyphWing
        let trailing = DownloadIslandMetrics.percentWing
        let clearance = DownloadIslandMetrics.clearance
        let leftFree = island.minX - leftLimit - clearance
        let rightFree = rightLimit - island.maxX - clearance
        if systemActivity {
            let size = island.height, gap = DownloadIslandMetrics.detachedGap
            if rightFree >= gap + size {
                return .minimal(capsule: CGRect(x: island.maxX + gap, y: island.minY, width: size, height: size), island: island)
            }
            if leftFree >= gap + size {
                return .minimal(capsule: CGRect(x: island.minX - gap - size, y: island.minY, width: size, height: size), island: island)
            }
            return .hidden
        }
        if leftFree >= glyph, rightFree >= trailing {
            var leading = glyph
            if let nameWidth {
                let named = min(DownloadIslandMetrics.maximumNamedWing,
                                (DownloadIslandMetrics.glyphWing + nameWidth + DownloadIslandMetrics.namePadding).rounded(.up))
                // The name widens the leading wing only; the trailing wing keeps the percentage.
                if leftFree >= named, named >= DownloadIslandMetrics.minimumNamedWing { leading = named }
            }
            return .compact(capsule: CGRect(x: island.minX - leading, y: island.minY,
                                            width: island.width + leading + trailing, height: island.height),
                            island: island, leadingWidth: leading)
        }
        if leftFree >= glyph {
            return .leading(capsule: CGRect(x: island.minX - glyph, y: island.minY,
                                            width: island.width + glyph, height: island.height), island: island)
        }
        if rightFree >= glyph {
            return .trailing(capsule: CGRect(x: island.minX, y: island.minY,
                                             width: island.width + glyph, height: island.height), island: island)
        }
        return .hidden
    }
}

enum DownloadIslandMetrics {
    static let glyphWing: CGFloat = 32
    static let glyphSize: CGFloat = 17
    /// Room for "100 %" in the widest language format at full size.
    static let percentWing: CGFloat = 58
    static let minimumNamedWing: CGFloat = 64
    static let maximumNamedWing: CGFloat = 150
    static let namePadding: CGFloat = 8
    /// Space kept free next to a menu or status item.
    static let clearance: CGFloat = 6
    /// The gap macOS 27 leaves between the island and a detached activity.
    static let detachedGap: CGFloat = 8
    static var percentFont: NSFont { NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold) }
    static var nameFont: NSFont { NSFont.systemFont(ofSize: 11, weight: .medium) }
    /// The blue Vorssaint gives Downloads, as Apple tints a compact activity with its app's colour.
    static let tint = NSColor.systemBlue

    static func nameWidth(_ name: String) -> CGFloat {
        ceil((name as NSString).size(withAttributes: [.font: nameFont]).width)
    }
}

// MARK: Accessibility reads

/// The island, the menu bar and MenuBarAgent's Live Activities as one read, off the main thread.
struct DownloadIslandSurroundings {
    /// The system island to attach to, in AppKit coordinates.
    let island: CGRect
    /// A compact system Live Activity holds the island.
    let systemActivity: Bool
    let leftLimit: CGFloat
    let rightLimit: CGFloat
    /// The status item nearest the island, watched for moves and resizes.
    let nearestItem: AXUIElement?
}

enum DownloadIslandAX {
    static let queue = DispatchQueue(label: "MacTools.IslandDownloads.ax", qos: .userInitiated)

    static func value(_ element: AXUIElement, _ attribute: String, timeout: Float = 0.1) -> CFTypeRef? {
        guard AXUIElementSetMessagingTimeout(element, timeout) == .success else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String {
        value(element, attribute) as? String ?? ""
    }

    static func children(_ element: AXUIElement, timeout: Float = 0.1) -> [AXUIElement]? {
        guard AXUIElementSetMessagingTimeout(element, timeout) == .success else { return nil }
        var result: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &result)
        if error == .noValue || error == .attributeUnsupported { return [] }
        guard error == .success else { return nil }
        return result as? [AXUIElement]
    }

    /// A frame in AX's top-left desktop coordinates.
    static func frame(_ element: AXUIElement, timeout: Float = 0.1) -> CGRect? {
        guard let rawPoint = value(element, kAXPositionAttribute, timeout: timeout),
              CFGetTypeID(rawPoint) == AXValueGetTypeID(),
              let rawSize = value(element, kAXSizeAttribute, timeout: timeout),
              CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(rawPoint, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeDowncast(rawSize, to: AXValue.self), .cgSize, &size),
              point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite else { return nil }
        return CGRect(origin: point, size: size)
    }

    static func isMenuBarAgent(_ app: NSRunningApplication) -> Bool {
        app.executableURL?.lastPathComponent == "MenuBarAgent" || app.localizedName == "MenuBarAgent"
            || app.bundleURL?.lastPathComponent == "MenuBarAgent.app"
    }

    /// nil when anything needed can't be read: unknown space is never assumed free, and an
    /// expanded system activity owns the island.
    static func surroundings(restingIsland: CGRect, screen: CGRect, desktopTop: CGFloat,
                             frontPID: pid_t?, agentPID: pid_t?) -> DownloadIslandSurroundings? {
        guard let agentPID else { return nil }
        let agent = AXUIElementCreateApplication(agentPID)
        guard let windows = value(agent, kAXWindowsAttribute, timeout: 0.2) as? [AXUIElement] else { return nil }

        // MenuBarAgent hosts Live Activities in a full-screen AXUnknown window.
        var activities: [CGRect] = []
        var budget = 250
        var complete = true
        func walk(_ element: AXUIElement, depth: Int) {
            guard complete else { return }
            guard budget > 0, depth < 16 else { complete = false; return }
            budget -= 1
            let subrole = string(element, kAXSubroleAttribute)
            if subrole == "AXLiveActivity" {
                if (value(element, "AXHidden") as? Bool) == true { return }
                guard let raw = frame(element, timeout: 0.2), raw.width > 0, raw.height > 0 else { complete = false; return }
                activities.append(CGRect(x: raw.minX, y: desktopTop - raw.maxY, width: raw.width, height: raw.height))
                return
            }
            guard let children = children(element, timeout: 0.2) else { complete = false; return }
            for child in children { walk(child, depth: depth + 1) }
        }
        for window in windows where string(window, kAXSubroleAttribute) == "AXUnknown" { walk(window, depth: 0) }
        guard complete else { return nil }
        let visible = activities.filter { $0.intersects(screen) }
        // An expanded system activity owns the island and the space around it.
        guard visible.allSatisfy({ $0.height <= 60 && $0.width <= screen.width * 0.8 }) else { return nil }
        let attached = visible.filter {
            $0.minY >= restingIsland.minY - 60 && abs($0.midX - restingIsland.midX) <= restingIsland.width
        }.min { $0.minY != $1.minY ? $0.minY < $1.minY : abs($0.midX - restingIsland.midX) < abs($1.midX - restingIsland.midX) }
        let island = attached ?? restingIsland

        var left = screen.minX
        if let frontPID {
            let app = AXUIElementCreateApplication(frontPID)
            var raw: CFTypeRef?
            guard AXUIElementSetMessagingTimeout(app, 0.1) == .success else { return nil }
            let error = AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &raw)
            if error == .success, let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() {
                guard let menus = children(unsafeDowncast(raw, to: AXUIElement.self)) else { return nil }
                for menu in menus {
                    guard let frame = frame(menu) else { return nil }
                    if frame.width > 0, frame.midX < island.midX { left = max(left, frame.maxX) }
                }
            } else if error != .noValue, error != .attributeUnsupported {
                return nil
            }
        }
        var right = screen.maxX
        var nearest: AXUIElement?
        // MenuBarAgent hosts every status item as a group in its menu-bar-high AXDialog window.
        for window in windows where string(window, kAXSubroleAttribute) == "AXDialog" {
            guard let groups = children(window, timeout: 0.2) else { return nil }
            for group in groups {
                guard let frame = frame(group) else { return nil }
                if frame.width > 0, frame.midX > island.midX, frame.minX < right { right = frame.minX; nearest = group }
            }
        }
        // The system's own detached activities are obstacles too.
        for frame in visible where !frame.intersects(island.insetBy(dx: 2, dy: 0)) {
            if frame.midX < island.midX { left = max(left, frame.maxX) } else { right = min(right, frame.minX) }
        }
        return DownloadIslandSurroundings(island: island, systemActivity: attached != nil,
                                          leftLimit: left, rightLimit: right, nearestItem: nearest)
    }
}

/// Reports status items and Live Activities appearing or disappearing in MenuBarAgent, and the
/// nearest status item moving or resizing. Runs only while a download shows; there is no polling.
@MainActor
final class DownloadMenuBarWatcher {
    var onChange: (() -> Void)?
    private var observer: AXObserver?
    private var application: AXUIElement?
    private var observed: AXUIElement?
    private var pending: DispatchWorkItem?
    private(set) var pid: pid_t?

    private static let appNotifications = [kAXCreatedNotification, kAXUIElementDestroyedNotification]
    private static let itemNotifications = [kAXMovedNotification, kAXResizedNotification]

    func start(pid: pid_t) {
        guard observer == nil || self.pid != pid else { return }
        stop()
        var created: AXObserver?
        guard AXObserverCreate(pid, downloadMenuBarCallback, &created) == .success, let created else { return }
        let application = AXUIElementCreateApplication(pid)
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        for name in Self.appNotifications { _ = AXObserverAddNotification(created, application, name as CFString, context) }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        observer = created
        self.application = application
        self.pid = pid
    }

    /// Follows this status item's moves and resizes; nothing changes when it is the same item.
    func observe(_ item: AXUIElement?) {
        guard let observer else { return }
        if let item, let observed, CFEqual(item, observed) { return }
        if item == nil, observed == nil { return }
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        if let observed {
            for name in Self.itemNotifications { AXObserverRemoveNotification(observer, observed, name as CFString) }
        }
        observed = item
        if let item {
            for name in Self.itemNotifications { _ = AXObserverAddNotification(observer, item, name as CFString, context) }
        }
    }

    fileprivate func changed() {
        guard pending == nil else { return }
        // Coalesce: a status item that updates its text resizes often; measuring once a second is plenty.
        let work = DispatchWorkItem { [weak self] in
            self?.pending = nil
            self?.onChange?()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func stop() {
        pending?.cancel(); pending = nil
        if let observer {
            if let observed {
                for name in Self.itemNotifications { AXObserverRemoveNotification(observer, observed, name as CFString) }
            }
            if let application {
                for name in Self.appNotifications { AXObserverRemoveNotification(observer, application, name as CFString) }
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil; application = nil; observed = nil; pid = nil
    }
}

private func downloadMenuBarCallback(_ observer: AXObserver, _ element: AXUIElement,
                                     _ notification: CFString, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let address = UInt(bitPattern: context)
    MainActor.assumeIsolated {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return }
        Unmanaged<DownloadMenuBarWatcher>.fromOpaque(pointer).takeUnretainedValue().changed()
    }
}

// MARK: View

/// The compact download activity beside the island: Vorssaint's arrow and percentage, drawn as a
/// Live Activity of the system island. Draws nothing and runs no timer while hidden; while shown it
/// changes only when the download reports progress.
@MainActor
final class DownloadIslandIndicator {
    var onClick: (() -> Void)?
    private var panel: NSPanel?
    private let root = DownloadIndicatorRoot()
    private let shape = CAShapeLayer()
    private let glyph = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let percent = NSTextField(labelWithString: "")
    private(set) var layout: DownloadIslandLayout = .hidden
    private static let bytes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        // "48 MB", not "48.3 MB": the wing holds a short reading that changes every tick.
        formatter.isAdaptive = true
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter
    }()

    var isVisible: Bool { panel != nil }

    init() {
        root.wantsLayer = true
        shape.fillColor = NSColor.black.cgColor
        root.layer?.addSublayer(shape)
        glyph.imageScaling = .scaleProportionallyUpOrDown
        glyph.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: DownloadIslandMetrics.glyphSize, weight: .regular))
        glyph.contentTintColor = DownloadIslandMetrics.tint
        name.font = DownloadIslandMetrics.nameFont
        name.textColor = .white
        name.lineBreakMode = .byTruncatingMiddle
        percent.font = DownloadIslandMetrics.percentFont
        percent.textColor = DownloadIslandMetrics.tint
        percent.alignment = .center
        root.addSubview(glyph)
        root.addSubview(name)
        root.addSubview(percent)
        root.onClick = { [weak self] in self?.onClick?() }
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.button)
    }

    /// Updates the readings without touching the shape: progress ticks must stay cheap.
    /// A download of unknown size reads the bytes received so far, as the Downloads page does.
    func update(name text: String, fraction: Double?, receivedBytes: Int64?, accessibility: String) {
        if name.stringValue != text { name.stringValue = text }
        let reading: String
        if let fraction { reading = fraction.formatted(.percent.precision(.fractionLength(0))) }
        else if let bytes = receivedBytes, bytes > 0 { reading = Self.bytes.string(fromByteCount: bytes) }
        else { reading = "…" }
        if percent.stringValue != reading { percent.stringValue = reading }
        root.setAccessibilityLabel(accessibility)
        root.setAccessibilityValue(reading)
    }

    func show(_ next: DownloadIslandLayout) {
        guard let capsule = next.capsule, let island = next.island else { hide(); return }
        let previous = panel == nil ? nil : layout.capsule
        layout = next
        // The window covers the old and new capsule while it animates, and nothing else.
        let frame = (previous.map { $0.union(capsule) } ?? capsule).insetBy(dx: -1, dy: -1).integral
        let panel = self.panel ?? makePanel()
        panel.setFrame(frame, display: false)
        root.frame = CGRect(origin: .zero, size: frame.size)
        let local = capsule.offsetBy(dx: -frame.minX, dy: -frame.minY)
        let islandLocal = island.offsetBy(dx: -frame.minX, dy: -frame.minY)
        root.hitRects = next.isDetached ? [local] : wingRects(capsule: local, island: islandLocal)
        let target = CGPath(roundedRect: local, cornerWidth: local.height / 2, cornerHeight: local.height / 2, transform: nil)
        let from: CGPath
        if let previous {
            let old = previous.offsetBy(dx: -frame.minX, dy: -frame.minY)
            from = CGPath(roundedRect: old, cornerWidth: old.height / 2, cornerHeight: old.height / 2, transform: nil)
        } else if next.isDetached {
            // A detached bubble grows from its own centre.
            let seed = local.insetBy(dx: local.width / 2 - 1, dy: local.height / 2 - 1)
            from = CGPath(roundedRect: seed, cornerWidth: 1, cornerHeight: 1, transform: nil)
        } else {
            // Grows out of the island.
            from = CGPath(roundedRect: islandLocal, cornerWidth: islandLocal.height / 2, cornerHeight: islandLocal.height / 2, transform: nil)
        }
        animate(from: from, to: target)
        placeContent(capsule: local, island: islandLocal, appearing: previous == nil)
        if self.panel == nil { self.panel = panel; panel.orderFrontRegardless() }
    }

    func hide() {
        guard let panel else { layout = .hidden; return }
        self.panel = nil
        let finished = layout
        layout = .hidden
        guard let island = finished.island, let capsule = finished.capsule else { panel.orderOut(nil); return }
        var local = island.offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY)
        if finished.isDetached {
            let bubble = capsule.offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY)
            local = bubble.insetBy(dx: bubble.width / 2 - 1, dy: bubble.height / 2 - 1)
        }
        let target = CGPath(roundedRect: local, cornerWidth: local.height / 2, cornerHeight: local.height / 2, transform: nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            glyph.animator().alphaValue = 0
            name.animator().alphaValue = 0
            percent.animator().alphaValue = 0
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.panel == nil else { return }
                panel.orderOut(nil)
            }
        }
        animate(from: shape.path ?? target, to: target)
        CATransaction.commit()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // The hover panel's level: the system island composites above it, so the capsule's middle
        // sits under the island and only the wings show. The hover panel and the notification
        // cards order above it when they open, as a banner covers an activity on iPhone.
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = root
        return panel
    }

    private func animate(from: CGPath, to: CGPath) {
        let spring = CASpringAnimation(keyPath: "path")
        spring.fromValue = from
        spring.toValue = to
        spring.mass = 1; spring.stiffness = 260; spring.damping = 26
        spring.duration = spring.settlingDuration
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { spring.duration = 0.01 }
        shape.path = to
        shape.add(spring, forKey: "path")
    }

    private func wingRects(capsule: CGRect, island: CGRect) -> [CGRect] {
        var rects: [CGRect] = []
        if capsule.minX < island.minX { rects.append(CGRect(x: capsule.minX, y: capsule.minY, width: island.minX - capsule.minX, height: capsule.height)) }
        if capsule.maxX > island.maxX { rects.append(CGRect(x: island.maxX, y: capsule.minY, width: capsule.maxX - island.maxX, height: capsule.height)) }
        return rects
    }

    private func placeContent(capsule: CGRect, island: CGRect, appearing: Bool) {
        let size = DownloadIslandMetrics.glyphSize
        let leadingSide = capsule.minX < island.minX
        let showsName = layout.showsPercent && layout.leadingWidth > DownloadIslandMetrics.glyphWing
        let glyphMidX: CGFloat
        if layout.isDetached { glyphMidX = capsule.midX }
        else if showsName { glyphMidX = capsule.minX + capsule.height / 2 + 1 }
        else if leadingSide { glyphMidX = (capsule.minX + island.minX) / 2 + 2 }
        else { glyphMidX = (island.maxX + capsule.maxX) / 2 - 2 }
        glyph.frame = CGRect(x: (glyphMidX - size / 2).rounded(), y: (capsule.midY - size / 2).rounded(), width: size, height: size)
        let labelHeight: CGFloat = 16
        if showsName {
            let start = glyph.frame.maxX + 5
            name.frame = CGRect(x: start, y: (capsule.midY - labelHeight / 2).rounded(),
                                width: max(0, island.minX - start - 4), height: labelHeight)
        }
        if layout.showsPercent {
            percent.frame = CGRect(x: island.maxX, y: (capsule.midY - labelHeight / 2).rounded(),
                                   width: capsule.maxX - island.maxX - 4, height: labelHeight)
        }
        let nameAlpha: CGFloat = showsName ? 1 : 0, percentAlpha: CGFloat = layout.showsPercent ? 1 : 0
        if appearing {
            glyph.alphaValue = 0; name.alphaValue = 0; percent.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                glyph.animator().alphaValue = 1
                name.animator().alphaValue = nameAlpha
                percent.animator().alphaValue = percentAlpha
            }
        } else {
            glyph.alphaValue = 1; name.alphaValue = nameAlpha; percent.alphaValue = percentAlpha
        }
    }
}

/// Takes clicks only on the wings; the island in the middle belongs to the system.
private final class DownloadIndicatorRoot: NSView {
    var hitRects: [CGRect] = []
    var onClick: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return hitRects.contains { $0.contains(local) } ? self : nil
    }

    override func mouseUp(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if hitRects.contains(where: { $0.contains(local) }) { onClick?() }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
