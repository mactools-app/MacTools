import AppKit
import OSLog
import QuartzCore
import MacToolsPluginKit

@MainActor
final class IslandNotificationPresenter {
    private final class Panel: NSPanel {
        /// Only a card with a reply field takes keyboard focus, and only without activating MacTools.
        var allowsKey = false
        override var canBecomeKey: Bool { allowsKey }
        override var canBecomeMain: Bool { false }
    }

    /// Fixed-size window root. The window is allocated at the card's largest (expanded) size so
    /// it never resizes; the morph surface is pinned to the top and sized to the current card.
    private final class Root: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            let hit = super.hitTest(point)
            return hit === self ? nil : hit
        }
    }

    private(set) var window: NSPanel?
    private var surface: NotchMorphView?
    private var splitSurface: IslandSplitMorphView?
    private var splitGeometry: IslandSplitGeometry?
    private var reduceMotion = false
    private var animationRevision = 0
    private var card: IslandNotificationCard?
    private var model = NotchMorphModel()
    private var metrics: NotchMorphMetrics?
    private var link: CADisplayLink?
    private let target = NotchDisplayLinkTarget()
    private var timestamp: CFTimeInterval?
    private var completion: (() -> Void)?
    private let localization: PluginLocalization
    private var anchor: CGRect = .zero
    private var activity: CGRect?
    private var compactSize: CGSize = .zero
    private var fullSize: CGSize = .zero
    private var windowSizeFrame: CGRect = .zero
    /// 0 = compact card, 1 = full message.
    private var size = NotchMorphModel.Spring()
    private var sizeTarget: Double = 0
    private var closeHandler: (() -> Void)?
    private var keyObservers: [NSObjectProtocol] = []
    var onHoverChange: (() -> Void)?
    /// The user pressed Send (or Return) in the reply field.
    var onReply: ((String) -> Void)?
    /// A click anywhere outside an open (expanded) card.
    var onOutsideClick: (() -> Void)?
    private var outsideClickMonitor: Any?
    var isSendingReply: Bool { card?.isSendingReply ?? false }
    /// Swiping down holds a card on screen (opening it if it can grow) until the user dismisses it,
    /// like pulling down an iOS banner. Only swiping up dismisses.
    private(set) var isHeld = false

    /// Typing, or a reply is being sent: the card must stay.
    var isReplying: Bool { card?.isReplying ?? false }
    /// Unsent text in the reply field.
    var hasDraft: Bool { card?.hasDraft ?? false }
    var isHovered: Bool { card?.isHovered ?? false }
    var isExpanded: Bool { sizeTarget > 0.5 }
    static let defaultPreviewLines = 4
    static let previewLineRange = 1...10
    /// Message lines a card shows before it is expanded (a setting). Applies to the next card.
    var previewLines = defaultPreviewLines
    private var canExpand: Bool { fullSize.height > compactSize.height + 0.5 }

    init(localization: PluginLocalization) {
        self.localization = localization
        target.onFrame = { [weak self] in self?.step($0) }
    }

    func present(_ notification: IslandNotification, anchor: CGRect, activity: CGRect? = nil, waiting: Int,
                 replyable: Bool = false,
                 onOpen: @escaping () -> Void, onClose: @escaping () -> Void) {
        hide()
        // iOS-style pill: "now" beside the camera, the title line just below it.
        let housing = NotchMorphMetrics(anchor: anchor, contentSize: .zero, contentTopInset: 0)
        let islandCenter = housing.housingOffset + housing.housingSize.height / 2
        let islandBottom = housing.housingOffset + housing.housingSize.height
        typealias Layout = IslandNotificationCard.Layout
        let pill = Layout.fitsOneLine(title: notification.title, body: notification.body)
        compactSize = CGSize(width: Layout.width,
                             height: Layout.height(islandBottom: islandBottom, title: notification.title, body: notification.body,
                                                   lines: previewLines))
        // A pill already shows its whole message; a longer card can grow to show all of it,
        // up to half the visible screen height.
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main
        let maxHeight = (screen?.visibleFrame.height ?? 800) * 0.5
        // A card with a reply field always expands (iOS: the expanded notification holds the reply).
        maxCardHeight = maxHeight
        naturalFullHeight = pill && !replyable ? compactSize.height
            : Layout.expandedHeight(islandBottom: islandBottom, body: notification.displayBody, maxHeight: .greatestFiniteMagnitude, reply: replyable)
        replyExtra = 0
        fullSize = CGSize(width: Layout.width, height: fullHeight)
        self.anchor = anchor
        self.activity = activity
        compactIsPill = pill
        self.closeHandler = onClose
        size = NotchMorphModel.Spring(); sizeTarget = 0
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        updateGeometry(height: compactSize.height)
        // Room for the reply field to grow to its line limit without resizing the window.
        windowSizeFrame = frame(height: replyable
            ? max(fullSize.height, min(naturalFullHeight + Layout.replyMaxExtra, maxCardHeight)) : fullSize.height)
        let card = IslandNotificationCard(notification: notification, localization: localization, previewLines: previewLines,
                                          replyable: replyable,
                                          islandCenter: islandCenter, islandBottom: islandBottom,
                                          onOpen: onOpen, onClose: onClose, onHoverChange: { [weak self] in self?.onHoverChange?() })
        card.updateCount(waiting)
        card.onSend = { [weak self] text in self?.onReply?(text) }
        card.onCancelReply = { [weak self] in
            guard let self else { return }
            // Esc with an empty reply closes the card; with unsent text it only hands typing back.
            if self.card?.hasDraft == true { self.returnKeyboard() } else { self.closeHandler?() }
        }
        card.onReplyHeightChange = { [weak self] extra in self?.replyHeightChanged(extra) }
        card.onPullOpen = { [weak self] in self?.pullOpen() }
        card.onPushDismiss = { [weak self] in self?.pushDismiss() }
        card.onExpandRequest = { [weak self] on in
            guard let self, on ? self.canExpand && !self.isExpanded : self.isExpanded else { return false }
            self.setExpanded(on); return true
        }
        self.card = card
        card.updateExpandActions(canExpand: canExpand, expanded: isExpanded)
        card.showsGrabber = canExpand
        let root = Root(frame: CGRect(origin: .zero, size: windowSizeFrame.size))
        if splitGeometry != nil {
            let split = IslandSplitMorphView(content: card)
            splitSurface = split
            root.addSubview(split)
        } else {
            let surface = NotchMorphView(content: card)
            self.surface = surface
            root.addSubview(surface)
        }
        let panel = Panel(contentRect: windowSizeFrame, styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // The system island composites above app windows at every tested level.
        // Split geometry starts behind it and emerges below its bottom edge.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.contentView = root
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.allowsKey = replyable
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            keyObservers.append(NotificationCenter.default.addObserver(forName: name, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onHoverChange?() }
            })
        }
        self.window = panel
        model = NotchMorphModel()
        render()
        panel.orderFrontRegardless()
        expand(true)
    }

    func updateCount(_ count: Int) { card?.updateCount(count) }

    /// Rebuilds the morph geometry for a card of the given height. Both geometries keep their
    /// top edge fixed, so only the bottom of the shape moves.
    private func updateGeometry(height: CGFloat) {
        let content = CGSize(width: compactSize.width, height: height)
        var metrics = NotchMorphMetrics(anchor: anchor, contentSize: content, contentTopInset: 0)
        // One-line notifications keep the compact pill; longer ones use the expanded island shape.
        // A pill that expands relaxes its corners continuously into the card radius.
        let opened = min(max(size.value, 0), 1)
        metrics.staysPill = compactIsPill && opened <= 0.0001
        metrics.pillAmount = compactIsPill ? 1 - opened : 0
        self.metrics = metrics
        splitGeometry = activity.map {
            var geometry = IslandSplitGeometry(activity: $0, expandedSize: metrics.expandedSize)
            geometry.staysPill = metrics.staysPill
            geometry.pillAmount = metrics.pillAmount
            return geometry
        }
    }

    private var compactIsPill = false
    private var naturalFullHeight: CGFloat = 0
    private var maxCardHeight: CGFloat = 0
    /// Extra height of a reply field grown past one line.
    private var replyExtra: CGFloat = 0
    private var fullHeight: CGFloat {
        max(compactSize.height, min(naturalFullHeight + replyExtra, max(maxCardHeight, compactSize.height)))
    }

    /// The reply field grew or shrank by a line: the card follows, its top staying put.
    private func replyHeightChanged(_ extra: CGFloat) {
        guard extra != replyExtra else { return }
        replyExtra = extra
        fullSize.height = fullHeight
        render()
    }

    private func frame(height: CGFloat) -> CGRect {
        let content = CGSize(width: compactSize.width, height: height)
        let metrics = NotchMorphMetrics(anchor: anchor, contentSize: content, contentTopInset: 0)
        return activity.map { IslandSplitGeometry(activity: $0, expandedSize: metrics.expandedSize).windowFrame } ?? metrics.windowFrame
    }

    /// Pulling a compact card opens it (reply box included); if there is nothing more to show it
    /// is held on screen until dismissed, like pulling down an iOS banner.
    private func pullOpen() {
        if canExpand, !isExpanded {
            setExpanded(true)
        } else if !isHeld {
            isHeld = true
            watchOutsideClicks(true)
            onHoverChange?()
        }
    }

    /// Pushing a compact card up sends it back into the island.
    private func pushDismiss() {
        guard !isExpanded, let card, !card.hasDraft, !card.isSendingReply else { return }
        closeHandler?()
    }

    private func setExpanded(_ on: Bool) {
        guard let card, window != nil, completion == nil else { return }
        sizeTarget = on ? 1 : 0
        // An open card is held until dismissed; folding it back lets it time out as usual.
        isHeld = on
        watchOutsideClicks(on)
        card.isOpen = on
        if on {
            card.setExpandedMode(true)
            // iOS: opening a message notification puts the cursor straight in the reply field.
            card.focusReply()
        } else { returnKeyboard() }
        card.updateExpandActions(canExpand: canExpand, expanded: on)
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion {
            size = NotchMorphModel.Spring(value: sizeTarget)
            render(); finish()
        } else { startLink() }
        onHoverChange?()
    }

    func refreshLocalization() { card?.refreshLocalization() }

    func setReplySending() { card?.setReplySending() }
    func showReplySent() { card?.showReplySent() }
    func showReplyError(_ message: String) { card?.showReplyError(message) }

    /// Hands typing back to the app the user was in. MacTools never became active, so
    /// re-activating the frontmost app restores its key window.
    func returnKeyboard() {
        guard let panel = window as? Panel, panel.isKeyWindow else { return }
        card?.endEditing()
        // Ordering the key panel out (unable to take key back) resigns it, so the window server
        // returns typing to the active app's window; the card reappears in the same frame.
        let allowed = panel.allowsKey
        panel.allowsKey = false
        panel.orderOut(nil)
        panel.orderFrontRegardless()
        panel.allowsKey = allowed
        NSWorkspace.shared.frontmostApplication?.activate()
    }

    func announce(_ notification: IslandNotification) {
        guard let card else { return }
        NSAccessibility.post(element: card, notification: .announcementRequested, userInfo: [
            .announcement: [notification.appName, notification.title, notification.body].compactMap { $0 }.joined(separator: ". "),
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    func dismiss(completion: @escaping () -> Void) {
        guard window != nil else { completion(); return }
        self.completion = completion
        window?.ignoresMouseEvents = true
        expand(false)
    }

    /// Clicks in other apps close an open card, like tapping away on iOS. A global monitor only
    /// sees events for other apps, so every click it reports is outside the card.
    private func watchOutsideClicks(_ on: Bool) {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        guard on else { return }
        // Left clicks only: a two-finger tap (secondary click) must not close the card.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                // The window is sized for the fully open card and is mostly transparent; only a click
                // on the visible card counts as inside.
                guard let self, !self.visibleCardContains(NSEvent.mouseLocation) else { return }
                self.onOutsideClick?()
            }
        }
    }

    /// Whether a screen point lies on the card as drawn (not the larger transparent window).
    private func visibleCardContains(_ point: NSPoint) -> Bool {
        guard let card, let window = card.window else { return false }
        let onScreen = window.convertToScreen(card.convert(card.bounds, to: nil))
        return onScreen.insetBy(dx: -4, dy: -4).contains(point)
    }

    func hide() {
        isHeld = false
        watchOutsideClicks(false)
        returnKeyboard()
        for observer in keyObservers { NotificationCenter.default.removeObserver(observer) }
        keyObservers.removeAll()
        link?.invalidate(); link = nil; timestamp = nil
        window?.orderOut(nil)
        surface?.releaseContent()
        splitSurface?.releaseContent()
        splitSurface = nil; splitGeometry = nil
        window = nil; surface = nil; card = nil; completion = nil; closeHandler = nil
        size = NotchMorphModel.Spring(); sizeTarget = 0
    }

    isolated deinit { hide() }

    private func expand(_ expanded: Bool) {
        animationRevision += 1
        let revision = animationRevision
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        model.target = expanded ? 1 : 0
        if reduceMotion, splitGeometry != nil, let panel = window {
            model.snapToTarget(); render()
            panel.alphaValue = expanded ? 0 : 1
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                panel.animator().alphaValue = expanded ? 1 : 0
            } completionHandler: { [weak self, weak panel] in
                Task { @MainActor in
                    guard let self, let panel, self.window === panel, self.animationRevision == revision else { return }
                    self.finish()
                }
            }
        } else if reduceMotion {
            model.snapToTarget(); render(); finish()
        } else { startLink() }
    }

    private func startLink() {
        guard link == nil, let root = window?.contentView else { return }
        let link = root.displayLink(target: target, selector: #selector(NotchDisplayLinkTarget.step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func step(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let elapsed = timestamp.map { now - $0 } ?? (link.targetTimestamp - link.timestamp)
        timestamp = now
        let dt = min(max(elapsed, 0), 1.0 / 30.0)
        model.advance(by: dt)
        var remaining = dt
        while remaining > 0 {
            let slice = min(remaining, 1.0 / 480.0)
            size.step(toward: sizeTarget, response: 0.42, dampingRatio: 0.84, dt: slice)
            remaining -= slice
        }
        render(); finish()
    }

    private func render() {
        guard card != nil else { return }
        let height = NotchMorphMetrics.lerp(compactSize.height, fullSize.height, max(size.value, 0))
        if metrics?.contentSize.height != height { updateGeometry(height: height) }
        card?.expansion = CGFloat(min(max(size.value, 0), 1))
        guard let metrics else { return }
        let current = frame(height: height).offsetBy(dx: -windowSizeFrame.minX, dy: -windowSizeFrame.minY)
        let morph: NSView? = splitSurface ?? surface
        if morph?.frame != current { morph?.frame = current }
        if let splitGeometry {
            splitSurface?.apply(model: model, geometry: splitGeometry, contentSize: metrics.contentSize, reduceMotion: reduceMotion)
        } else { surface?.apply(model: model, metrics: metrics) }
    }

    private func finish() {
        guard model.isSettled, size.isSettled(at: sizeTarget) else { return }
        model.snapToTarget()
        size = NotchMorphModel.Spring(value: sizeTarget)
        if sizeTarget == 0 { card?.setExpandedMode(false) }
        render()
        link?.invalidate(); link = nil; timestamp = nil
        if model.target == 0, let completion {
            hide(); completion()
        }
    }
}

@MainActor
private final class IslandNotificationCard: NSView {
    /// iOS notification pill, adapted to the Mac island: icon on the left, "now" beside the
    /// camera, then one line with the bold title and grey message below the camera.
    enum Layout {
        static let width: CGFloat = 450
        static let iconSize: CGFloat = 46
        static let iconToText: CGFloat = 12
        static let metaHeight: CGFloat = 16
        static let lineHeight: CGFloat = 19
        static let belowIsland: CGFloat = 2
        static let badgeSize: CGFloat = 18

        /// The two text lines form one block: "now" sits low beside the camera and the title
        /// line starts just below it. The pill is as tall as that block plus equal padding
        /// above and below, so the block and the icon are centred and the icon is concentric
        /// with the pill's round end.
        static func metaTop(islandBottom: CGFloat) -> CGFloat { islandBottom - metaHeight - 1 }
        static func lineTop(islandBottom: CGFloat) -> CGFloat { islandBottom + belowIsland }
        static var metaFont: NSFont { NSFont.systemFont(ofSize: 12, weight: .semibold) }
        static var titleFont: NSFont { NSFont.systemFont(ofSize: 14, weight: .semibold) }
        static var bodyFont: NSFont { NSFont.systemFont(ofSize: 14, weight: .regular) }

        static let bodyGap: CGFloat = 3
        static let bottomPadding: CGFloat = 18
        static let approxTextLeading: CGFloat = 20 + 46 + 12

        /// True when "Title  Message" fits the single pill line next to the close button.
        static func fitsOneLine(title: String, body: String) -> Bool {
            let available = width - approxTextLeading - 22
            let titleWidth = (title as NSString).size(withAttributes: [.font: titleFont]).width
            let bodyText = body.replacingOccurrences(of: "\n", with: " ")
            let bodyWidth = bodyText.isEmpty ? 0 : ("  " + bodyText as NSString).size(withAttributes: [.font: bodyFont]).width
            return ceil(titleWidth + bodyWidth) <= available
        }

        static var bodyWidth: CGFloat { width - (20 + 46 + 14) - 22 }

        static func bodyHeight(_ body: String, lines: Int) -> CGFloat {
            guard !body.isEmpty else { return 0 }
            let line = ceil(bodyFont.ascender - bodyFont.descender + bodyFont.leading)
            let measured = (body as NSString).boundingRect(
                with: CGSize(width: bodyWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: bodyFont]).height
            return min(ceil(measured), line * CGFloat(lines))
        }

        static func height(islandBottom: CGFloat, title: String, body: String, lines: Int) -> CGFloat {
            if fitsOneLine(title: title, body: body) { return height(islandBottom: islandBottom) }
            let bodyBlock = body.isEmpty ? 0 : bodyGap + bodyHeight(body, lines: lines)
            return lineTop(islandBottom: islandBottom) + lineHeight + bodyBlock + bottomPadding
        }

        /// Height that shows the whole message, capped (e.g. at half the screen).
        static func expandedHeight(islandBottom: CGFloat, body: String, maxHeight: CGFloat, reply: Bool) -> CGFloat {
            let text = body
            let measured = text.isEmpty ? 0 : (text as NSString).boundingRect(
                with: CGSize(width: bodyWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: bodyFont]).height
            let bodyBlock = text.isEmpty ? 0 : bodyGap + ceil(measured)
            let bottom = reply ? replyGap + replyHeight + replyBottom : bottomPadding
            let full = lineTop(islandBottom: islandBottom) + lineHeight + bodyBlock + bottom
            return min(full, maxHeight)
        }

        /// iOS-style reply field: a capsule under the message with a round send button.
        static let replyHeight: CGFloat = 34
        /// The field grows to five lines (Apple's lineLimit pattern), then scrolls inside.
        static let replyMaxLines = 5
        static var replyLineHeight: CGFloat {
            let font = NSFont.systemFont(ofSize: 14)
            return ceil(font.ascender - font.descender + font.leading)
        }
        static var replyMaxExtra: CGFloat { CGFloat(replyMaxLines - 1) * replyLineHeight }
        static let replyGap: CGFloat = 12
        static let replyBottom: CGFloat = 16
        static let replyStatusHeight: CGFloat = 18

        static func smoothstep(_ edge0: CGFloat, _ edge1: CGFloat, _ x: CGFloat) -> CGFloat {
            let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
            return t * t * (3 - 2 * t)
        }

        static func height(islandBottom: CGFloat) -> CGFloat {
            let blockBottom = lineTop(islandBottom: islandBottom) + lineHeight
            return blockBottom + metaTop(islandBottom: islandBottom)
        }
    }

    private let onOpen: () -> Void
    private let onClose: () -> Void
    private let onHoverChange: () -> Void
    private let localization: PluginLocalization
    private let islandCenter: CGFloat
    private let islandBottom: CGFloat
    private let icon = NSImageView()
    private let now = NSTextField(labelWithString: "")
    private let line = NSTextField(labelWithString: "")
    /// Title-only line that cross-fades over the one-line pill text as a pill expands.
    private let titleLine = NSTextField(labelWithString: "")
    private let reply: IslandReplyBar?
    private let replyStatus = NSTextField(labelWithString: "")
    var onSend: ((String) -> Void)?
    var onCancelReply: (() -> Void)?
    var onReplyHeightChange: ((CGFloat) -> Void)?
    var isReplying: Bool { reply?.isActive ?? false }
    var hasDraft: Bool { reply?.hasDraft ?? false }
    var isSendingReply: Bool { reply?.isSendingReply ?? false }
    private let bodyField = NSTextField(wrappingLabelWithString: "")
    /// The message scrolls inside the expanded card when it is taller than the card can grow.
    private let bodyScroll = IslandBodyScrollView()
    private let singleLine: Bool
    private let compactHeight: CGFloat
    private let previewLines: Int
    private lazy var previewBodyHeight = Layout.bodyHeight(bodyField.stringValue, lines: previewLines)
    /// Full message height for the last measured width; layout runs every animation frame.
    private var measuredBody: (width: CGFloat, height: CGFloat)?
    private var combinedText = NSAttributedString()
    private var titleText = NSAttributedString()
    /// True while showing (or animating to/from) the full message.
    private(set) var expandedMode = false
    /// 0 = compact layout, 1 = fully expanded; driven by the presenter's size spring.
    var expansion: CGFloat = 0 { didSet { needsLayout = true } }
    /// Scroll gestures (true = fingers up) and explicit expand/collapse requests (VoiceOver).
    /// Gesture results; the card's router decides them (see `route`).
    var onPullOpen: (() -> Void)?
    var onPushDismiss: (() -> Void)?
    /// Set by the presenter: an open card only scrolls its message, never opens or dismisses.
    var isOpen = false
    /// The "pull to open" hint, shown when the card has more (cut-off text or a reply box).
    var showsGrabber = false { didSet { needsLayout = true } }
    private let grabber = NSView()
    var onExpandRequest: ((Bool) -> Bool)?
    private let close = NSButton()
    private let count = NSTextField(labelWithString: "")
    private(set) var isHovered = false
    private var tracking: NSTrackingArea?
    private var waiting = 0

    override var isFlipped: Bool { true }

    init(notification: IslandNotification, localization: PluginLocalization, previewLines: Int, replyable: Bool,
         islandCenter: CGFloat, islandBottom: CGFloat,
         onOpen: @escaping () -> Void, onClose: @escaping () -> Void, onHoverChange: @escaping () -> Void) {
        self.onHoverChange = onHoverChange
        self.onOpen = onOpen; self.onClose = onClose; self.localization = localization
        self.islandCenter = islandCenter; self.islandBottom = islandBottom
        singleLine = Layout.fitsOneLine(title: notification.title, body: notification.body)
        self.previewLines = previewLines
        reply = replyable ? IslandReplyBar(placeholder: localization.string("reply.placeholder", defaultValue: "信息"),
                                           sendLabel: localization.string("reply.send", defaultValue: "发送")) : nil
        compactHeight = Layout.height(islandBottom: islandBottom, title: notification.title, body: notification.body,
                                      lines: previewLines)
        super.init(frame: CGRect(x: 0, y: 0, width: Layout.width, height: compactHeight))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel([notification.appName, notification.title, notification.body]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ". "))
        updateActions()

        if let appIcon = notification.appIcon {
            icon.image = appIcon
        } else {
            icon.image = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: nil)
            icon.symbolConfiguration = .init(pointSize: 20, weight: .semibold)
            icon.contentTintColor = .white
        }
        icon.imageScaling = .scaleProportionallyUpOrDown

        let relative = RelativeDateTimeFormatter()
        relative.locale = PluginRuntimeLocalization.locale
        relative.dateTimeStyle = .named
        // The small tinted line names the sending app (the banner is always "now" while shown).
        // "Calendar · Time-Sensitive" when the banner carries a label, as iOS shows it.
        now.stringValue = [notification.appName ?? relative.localizedString(fromTimeInterval: 0),
                           notification.label?.capitalized].compactMap { $0 }.joined(separator: " · ")
        now.lineBreakMode = .byTruncatingTail
        now.font = Layout.metaFont
        now.textColor = Self.accent(from: notification.appIcon)
        count.font = Layout.metaFont
        count.textColor = NSColor.white.withAlphaComponent(0.5)
        count.alignment = .right

        // Title in bold, message in grey, on one truncating line like iOS.
        let text = NSMutableAttributedString(string: notification.title, attributes: [
            .font: Layout.titleFont, .foregroundColor: NSColor.white,
        ])
        if let subtitle = notification.subtitle {
            text.append(NSAttributedString(string: (notification.title.isEmpty ? "" : "  ") + subtitle, attributes: [
                .font: Layout.titleFont, .foregroundColor: NSColor.white,
            ]))
        }
        if !notification.message.isEmpty {
            let oneLine = notification.message.replacingOccurrences(of: "\n", with: " ")
            text.append(NSAttributedString(string: (text.length == 0 ? "" : "  ") + oneLine, attributes: [
                .font: Layout.bodyFont, .foregroundColor: NSColor.white.withAlphaComponent(0.55),
            ]))
        }
        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingTail
        text.addAttribute(.paragraphStyle, value: truncating, range: NSRange(location: 0, length: text.length))
        combinedText = text
        titleText = NSAttributedString(string: notification.title, attributes: [
            .font: Layout.titleFont, .foregroundColor: NSColor.white, .paragraphStyle: truncating,
        ])
        // macOS banners carry at most 1,024 characters; mark a body cut at that limit.
        bodyField.font = Layout.bodyFont
        bodyField.textColor = NSColor.white.withAlphaComponent(0.7)
        // A subtitle (a group's name) heads the message in the title's weight, as Apple draws it.
        let bodyText = NSMutableAttributedString()
        if let subtitle = notification.subtitle {
            bodyText.append(NSAttributedString(string: subtitle + (notification.message.isEmpty ? "" : "\n"), attributes: [
                .font: Layout.titleFont, .foregroundColor: NSColor.white,
            ]))
        }
        bodyText.append(NSAttributedString(string: notification.message, attributes: [
            .font: Layout.bodyFont, .foregroundColor: NSColor.white.withAlphaComponent(0.7),
        ]))
        bodyField.attributedStringValue = bodyText
        bodyField.maximumNumberOfLines = previewLines
        bodyField.lineBreakMode = .byWordWrapping
        bodyField.cell?.wraps = true
        bodyField.cell?.truncatesLastVisibleLine = true
        // Compact pill: title and message share one line. Compact card: title, then message.
        line.attributedStringValue = singleLine ? combinedText : titleText
        titleLine.attributedStringValue = titleText
        titleLine.lineBreakMode = .byTruncatingTail
        titleLine.isHidden = true
        bodyScroll.isHidden = singleLine || notification.body.isEmpty
        replyStatus.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        replyStatus.textColor = .systemOrange
        replyStatus.lineBreakMode = .byTruncatingTail
        replyStatus.isHidden = true
        line.lineBreakMode = .byTruncatingTail
        line.maximumNumberOfLines = 1
        line.toolTip = [notification.title, notification.body].filter { !$0.isEmpty }.joined(separator: "\n")

        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: localization.string("card.close", defaultValue: "关闭通知"))
        // macOS-style close badge: small, on the icon's top-left corner, only while hovered.
        close.symbolConfiguration = .init(pointSize: 7.5, weight: .heavy)
        close.contentTintColor = NSColor.white.withAlphaComponent(0.9)
        close.isBordered = false; close.target = self; close.action = #selector(dismissCard)
        close.wantsLayer = true
        close.layer?.cornerRadius = Layout.badgeSize / 2
        close.layer?.backgroundColor = NSColor(white: 0.24, alpha: 1).cgColor
        close.layer?.borderWidth = 0.5
        close.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        close.alphaValue = 0
        close.setAccessibilityLabel(localization.string("card.close", defaultValue: "关闭通知"))
        close.toolTip = localization.string("card.close", defaultValue: "关闭通知")
        bodyScroll.setContent(bodyField)
        bodyScroll.router = self
        grabber.wantsLayer = true
        grabber.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.35).cgColor
        grabber.layer?.cornerRadius = 2
        grabber.alphaValue = 0
        addSubview(grabber)
        for view in [icon, now, count, line, titleLine, bodyScroll, replyStatus, close] as [NSView] { addSubview(view) }
        if let reply {
            reply.onSend = { [weak self] text in self?.onSend?(text) }
            reply.router = self
            reply.onCancel = { [weak self] in self?.onCancelReply?() }
            reply.onHeightChange = { [weak self] height in
                self?.onReplyHeightChange?(height - Layout.replyHeight)
                self?.needsLayout = true
            }
            reply.isHidden = true
            addSubview(reply, positioned: .below, relativeTo: close)
        }
        layoutCard()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// A readable accent from the app icon's most saturated colour (Messages green, Reminders red).
    /// Icons without a real colour (Script Editor, System Settings) get the plain secondary grey,
    /// as Apple's own banners do.
    private static func accent(from image: NSImage?) -> NSColor {
        let fallback = NSColor.white.withAlphaComponent(0.6)
        guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return fallback }
        let side = 12
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return fallback }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        var best: (score: CGFloat, color: NSColor)?
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index + 3] > 200 {
            let color = NSColor(srgbRed: CGFloat(pixels[index]) / 255, green: CGFloat(pixels[index + 1]) / 255,
                                blue: CGFloat(pixels[index + 2]) / 255, alpha: 1)
            let score = color.saturationComponent * color.brightnessComponent
            if score > (best?.score ?? 0.25) { best = (score, color) }
        }
        guard let color = best?.color else { return fallback }
        return NSColor(hue: color.hueComponent, saturation: min(color.saturationComponent, 0.8),
                       brightness: max(color.brightnessComponent, 0.85), alpha: 1)
    }

    private func layoutCard() {
        let bleed: CGFloat = icon.image?.isTemplate == true ? 0 : 4
        let pillHeight = Layout.height(islandBottom: islandBottom)
        let e = min(max(expansion, 0), 1)
        // The grabber sits at the bottom centre and fades out as the card opens.
        grabber.frame = CGRect(x: ((bounds.width - 28) / 2).rounded(), y: bounds.height - 9, width: 28, height: 4)
        grabber.alphaValue = showsGrabber ? 1 - min(e * 2, 1) : 0
        // Compact pill: icon concentric with the round end. Compact card: icon centred on the
        // card with a 20 pt inset. Expanded (iOS): the icon's top lines up with the top of the
        // app-name text.
        let compactInset = singleLine ? (pillHeight - Layout.iconSize) / 2 : 20
        let compactTop = (singleLine ? pillHeight / 2 : compactHeight / 2) - Layout.iconSize / 2
        let metaFont = Layout.metaFont
        let textTop = Layout.metaTop(islandBottom: islandBottom) + (metaFont.ascender - metaFont.capHeight).rounded()
        let iconRect = CGRect(x: Self.lerp(compactInset, 20, e), y: Self.lerp(compactTop, textTop, e),
                              width: Layout.iconSize, height: Layout.iconSize)
        icon.frame = iconRect.insetBy(dx: -bleed, dy: -bleed)
        close.frame = CGRect(x: iconRect.minX - 5, y: iconRect.minY - 5, width: Layout.badgeSize, height: Layout.badgeSize)
        let compactLeading = singleLine ? compactInset + Layout.iconSize + Layout.iconToText : 20 + Layout.iconSize + 14
        let leading = Self.lerp(compactLeading, 20 + Layout.iconSize + 14, e)
        let rightEdge = bounds.width - 20
        now.frame = CGRect(x: leading, y: Layout.metaTop(islandBottom: islandBottom), width: 110, height: Layout.metaHeight)
        count.frame = CGRect(x: rightEdge - 34, y: Layout.metaTop(islandBottom: islandBottom), width: 34, height: Layout.metaHeight)
        line.frame = CGRect(x: leading, y: Layout.lineTop(islandBottom: islandBottom),
                            width: rightEdge - leading, height: Layout.lineHeight)
        titleLine.frame = line.frame
        // A pill swaps "Title  Message" for the title, with the message wrapping below it.
        let fade = Layout.smoothstep(0.05, 0.55, e)
        if singleLine {
            line.alphaValue = 1 - fade
            titleLine.alphaValue = fade
            bodyScroll.alphaValue = fade
        }
        // The reply field sits at the bottom of the expanded card and fades in as it opens.
        var bottomLimit = bounds.height - Layout.bottomPadding
        if let reply {
            let replyHeight = reply.preferredHeight
            let replyRect = CGRect(x: 20, y: bounds.height - Layout.replyBottom - replyHeight,
                                   width: bounds.width - 40, height: replyHeight)
            reply.frame = replyRect
            reply.alphaValue = Layout.smoothstep(0.5, 1, e)
            reply.isHidden = e < 0.01
            bottomLimit = replyRect.minY - Layout.replyGap
            if !replyStatus.isHidden {
                replyStatus.frame = CGRect(x: 22, y: replyRect.minY - Layout.replyStatusHeight - 4,
                                           width: replyRect.width - 4, height: Layout.replyStatusHeight)
                bottomLimit = replyStatus.frame.minY - 2
            }
        }
        guard !singleLine || expandedMode else { return }
        let bodyTop = Layout.lineTop(islandBottom: islandBottom) + Layout.lineHeight + Layout.bodyGap
        let preview = previewBodyHeight
        // Expanded: the message fills the growing card and is revealed as the shape opens. It never
        // shrinks below the preview, so the reply field fades in over space that is opening up.
        let height = expandedMode ? max(singleLine ? 0 : preview, bottomLimit - bodyTop) : preview
        let width = rightEdge - leading
        let visible = max(0, height)
        bodyScroll.frame = CGRect(x: leading, y: bodyTop, width: width, height: visible)
        // Expanded: the field is as tall as the whole message; the scroll view shows what fits.
        var full: CGFloat = 0
        if expandedMode {
            if measuredBody?.width != width {
                let size = bodyField.cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude))
                measuredBody = (width, ceil(size?.height ?? 0))
            }
            full = measuredBody?.height ?? 0
        }
        let fieldFrame = CGRect(x: 0, y: 0, width: width, height: max(visible, full))
        if bodyField.frame != fieldFrame {
            bodyField.frame = fieldFrame
            bodyField.preferredMaxLayoutWidth = width
            bodyScroll.documentView?.frame = CGRect(origin: .zero, size: fieldFrame.size)
        }
    }

    override func layout() {
        super.layout()
        layoutCard()
    }

    /// Switches between the compact text arrangement and the full message.
    func setExpandedMode(_ on: Bool) {
        guard on != expandedMode else { return }
        expandedMode = on
        if singleLine {
            titleLine.isHidden = !on
            bodyScroll.isHidden = !on || bodyField.stringValue.isEmpty
            if !on { line.alphaValue = 1 }
        }
        bodyField.maximumNumberOfLines = on ? 0 : previewLines
        if !on { bodyScroll.contentView.scroll(to: .zero) }
        needsLayout = true
    }

    private static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

    func endEditing() { reply?.endEditing() }
    func focusReply() { reply?.focus() }
    func setReplySending() {
        replyStatus.isHidden = true
        reply?.setSending(true)
        needsLayout = true
    }
    func showReplySent() { reply?.showSent(localization.string("reply.sent", defaultValue: "已发送")) }
    func showReplyError(_ message: String) {
        reply?.setSending(false)
        replyStatus.stringValue = message
        replyStatus.toolTip = message
        replyStatus.isHidden = false
        needsLayout = true
    }

    func updateCount(_ waiting: Int) {
        self.waiting = waiting
        count.stringValue = waiting == 0 ? "" : "+\(waiting)"
        count.setAccessibilityLabel(waiting == 0 ? nil : localization.format("card.waiting", defaultValue: "还有 %@ 条通知",
            waiting.formatted(.number.locale(PluginRuntimeLocalization.locale))))
    }

    func refreshLocalization() {
        close.setAccessibilityLabel(localization.string("card.close", defaultValue: "关闭通知"))
        close.toolTip = localization.string("card.close", defaultValue: "关闭通知")
        updateActions()
        updateCount(waiting)
    }

    private var canExpand = false
    private var showsFullMessage = false

    /// VoiceOver actions: open, dismiss, and Show More / Show Less when the message is cut off.
    func updateExpandActions(canExpand: Bool, expanded: Bool) {
        self.canExpand = canExpand; showsFullMessage = expanded
        updateActions()
    }

    private func updateActions() {
        var actions = [
            NSAccessibilityCustomAction(name: localization.string("card.open", defaultValue: "打开通知"), handler: { [weak self] in self?.onOpen(); return true }),
            NSAccessibilityCustomAction(name: localization.string("card.close", defaultValue: "关闭通知"), handler: { [weak self] in self?.onClose(); return true }),
        ]
        if canExpand {
            let expand = !showsFullMessage
            let name = expand ? localization.string("card.expand", defaultValue: "展开")
                              : localization.string("card.collapse", defaultValue: "收起")
            actions.append(NSAccessibilityCustomAction(name: name, handler: { [weak self] in
                self?.onExpandRequest?(expand) ?? false
            }))
        }
        setAccessibilityCustomActions(actions)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }

    /// One click opens the card, like Apple's banners. A card with a reply field can take key, so
    /// AppKit asks the clicked view whether that first click counts; the icon and grabber would
    /// say no, so they answer as the card.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === icon || hit === grabber ? self : hit
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) {
        armedAt = max(armedAt, ProcessInfo.processInfo.systemUptime + 0.3)
        isHovered = true; close.animator().alphaValue = 1; onHoverChange()
    }
    override func mouseExited(with event: NSEvent) { isHovered = false; close.animator().alphaValue = 0; onHoverChange() }
    override func mouseUp(with event: NSEvent) { onOpen() }

    // MARK: Gestures
    //
    // One rule: each gesture does one thing, decided when it starts, and keeps that owner to the
    // end (momentum included).
    //   Compact card: pull (content moves down) opens it, or holds it if there's nothing more;
    //                 push (content moves up) dismisses it into the island. 30 pt of net finger
    //                 travel acts; the glide after the fingers lift never counts.
    //   Open card:    a long message scrolls (bouncing at its ends); nothing else happens.
    // Directions come from the raw scrollingDeltaY, the same sign NSScrollView scrolls by.
    // A card arms 0.3 s after it appears and after the pointer arrives, so a scroll meant for the
    // app underneath can't hit it.
    private enum GestureOwner { case none, ignored, card, spent, scroll }
    private var gestureOwner = GestureOwner.none
    private weak var scrollOwner: IslandRoutedScrollView?
    private var travel: CGFloat = 0
    private var armedAt = ProcessInfo.processInfo.systemUptime + 0.3
    private var lastWheelTick: TimeInterval = 0
    private static let actTravel: CGFloat = 30
    private let gestureLog = Logger(subsystem: "MacTools.IslandNotifications", category: "gesture")

    override func scrollWheel(with event: NSEvent) { route(event, from: nil) }

    /// Every scroll over the card arrives here: from the card itself, the message and the reply field.
    func route(_ event: NSEvent, from source: IslandRoutedScrollView?) {
        let now = ProcessInfo.processInfo.systemUptime
        let wheel = event.phase.isEmpty && event.momentumPhase.isEmpty
        let starts = event.phase == .began || (wheel && now - lastWheelTick > 0.25)
        if wheel { lastWheelTick = now }
        if starts {
            travel = 0
            if now < armedAt {
                gestureOwner = .ignored
            } else if !isOpen {
                gestureOwner = .card
            } else if let source, source.canScroll {
                gestureOwner = .scroll
                scrollOwner = source
            } else {
                gestureOwner = .ignored
            }
        }
        switch gestureOwner {
        case .scroll:
            scrollOwner?.scrollContent(event)
        case .card:
            guard event.momentumPhase.isEmpty else { break }
            travel += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 10
            if travel >= Self.actTravel {
                gestureOwner = .spent
                gestureLog.notice("pull: open travel=\(Int(self.travel), privacy: .public)")
                onPullOpen?()
            } else if travel <= -Self.actTravel {
                gestureOwner = .spent
                gestureLog.notice("push: dismiss travel=\(Int(self.travel), privacy: .public)")
                // The card goes, but the fingers are still moving: the rest of this swipe must not
                // scroll whatever is under the card.
                if let window {
                    IslandScrollSink.hold(over: window.convertToScreen(convert(bounds, to: nil)), level: window.level)
                }
                onPushDismiss?()
            }
        case .none, .ignored, .spent:
            break
        }
        if event.phase == .ended || event.phase == .cancelled, gestureOwner == .card {
            gestureLog.notice("gesture ended without acting travel=\(Int(self.travel), privacy: .public)")
        }
        if (event.phase == .ended || event.phase == .cancelled) && gestureOwner != .scroll { gestureOwner = .none }
        if event.momentumPhase == .ended { gestureOwner = .none }
    }
    override func accessibilityPerformPress() -> Bool { onOpen(); return true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onClose() }
        else if event.keyCode == 36 || event.keyCode == 49 { onOpen() }
        else { super.keyDown(with: event) }
    }
    override var acceptsFirstResponder: Bool { true }
    @objc private func dismissCard() { onClose() }
}

/// The reply capsule, like the Messages input on iOS: it grows a line at a time up to
/// `replyMaxLines`, then scrolls inside. Return sends, Shift- or Option-Return adds a line,
/// Esc hands typing back to the previous app.
@MainActor
private final class IslandReplyBar: NSView, NSTextViewDelegate {
    private final class TextView: NSTextView {
        // The first click on a non-key panel goes straight into the field.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private static var font: NSFont { NSFont.systemFont(ofSize: 14) }
    private static let verticalPadding: CGFloat = 8.5
    private let scroll = IslandRoutedScrollView()
    weak var router: IslandNotificationCard? {
        get { scroll.router }
        set { scroll.router = newValue }
    }
    private let textView = TextView()
    private let placeholder = NSTextField(labelWithString: "")
    private let send = NSButton()
    private var isSending = false
    private(set) var preferredHeight = IslandNotificationCard.Layout.replyHeight
    var onSend: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onHeightChange: ((CGFloat) -> Void)?

    override var isFlipped: Bool { true }

    /// Typing in the field, or a reply is on its way.
    var isActive: Bool {
        isSending || (window?.isKeyWindow == true && window?.firstResponder === textView)
    }

    init(placeholder text: String, sendLabel: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.1).cgColor

        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.font = Self.font
        textView.textColor = .white
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.isAutomaticQuoteSubstitutionEnabled = true
        textView.delegate = self
        textView.setAccessibilityLabel(text)
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScrollElasticity = .none

        placeholder.stringValue = text
        placeholder.font = Self.font
        placeholder.textColor = NSColor.white.withAlphaComponent(0.4)

        send.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: sendLabel)
        send.symbolConfiguration = .init(pointSize: 12, weight: .bold)
        send.imagePosition = .imageOnly
        send.isBordered = false
        send.wantsLayer = true
        send.contentTintColor = .white
        send.target = self
        send.action = #selector(sendTapped)
        send.toolTip = sendLabel
        send.setAccessibilityLabel(sendLabel)
        for view in [scroll, placeholder, send] as [NSView] { addSubview(view) }
        updateSend()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let h = bounds.height
        // A pill while it is one line; a rounded rectangle with the same corners as it grows.
        layer?.cornerRadius = IslandNotificationCard.Layout.replyHeight / 2
        let button = IslandNotificationCard.Layout.replyHeight - 8
        // The send button stays at the bottom right, beside the last line (iOS).
        send.frame = CGRect(x: bounds.width - 4 - button, y: h - 4 - button, width: button, height: button)
        send.layer?.cornerRadius = button / 2
        let textFrame = CGRect(x: 14, y: Self.verticalPadding, width: send.frame.minX - 20,
                               height: max(0, h - Self.verticalPadding * 2))
        if scroll.frame != textFrame {
            scroll.frame = textFrame
            textView.frame.size.width = textFrame.width
            textView.textContainer?.containerSize = CGSize(width: textFrame.width, height: .greatestFiniteMagnitude)
            updateHeight()
        }
        placeholder.frame = CGRect(x: 14, y: Self.verticalPadding, width: textFrame.width, height: IslandNotificationCard.Layout.replyLineHeight)
    }

    // Clicks on the capsule focus the field and never fall through to "open the app".
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { focus() }
    override func mouseUp(with event: NSEvent) {}

    func focus() {
        guard !isSending else { return }
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(textView)
    }

    func endEditing() {
        if window?.firstResponder === textView { window?.makeFirstResponder(nil) }
    }

    func setSending(_ sending: Bool) {
        isSending = sending
        textView.isEditable = !sending
        textView.textColor = sending ? NSColor.white.withAlphaComponent(0.5) : .white
        updateSend()
    }

    func showSent(_ label: String) {
        isSending = true
        textView.isEditable = false
        textView.string = ""
        placeholder.stringValue = label
        placeholder.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        placeholder.textColor = NSColor.white.withAlphaComponent(0.75)
        placeholder.isHidden = false
        send.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: label)
        send.layer?.backgroundColor = NSColor.systemGreen.cgColor
        send.isEnabled = false
        updateHeight()
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: label, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private var trimmed: String { textView.string.trimmingCharacters(in: .whitespacesAndNewlines) }
    var hasDraft: Bool { !isSending && !trimmed.isEmpty }
    var isSendingReply: Bool { isSending }

    private func updateSend() {
        let ready = !trimmed.isEmpty && !isSending
        send.isEnabled = ready
        send.layer?.backgroundColor = (ready ? NSColor.systemBlue : NSColor.white.withAlphaComponent(0.16)).cgColor
    }

    /// One line up to `replyMaxLines`; past that the field keeps its height and scrolls.
    private func updateHeight() {
        guard let container = textView.textContainer, let manager = textView.layoutManager else { return }
        manager.ensureLayout(for: container)
        let line = IslandNotificationCard.Layout.replyLineHeight
        let content = max(line, ceil(manager.usedRect(for: container).height))
        let visible = min(content, line * CGFloat(IslandNotificationCard.Layout.replyMaxLines))
        let height = max(IslandNotificationCard.Layout.replyHeight, visible + Self.verticalPadding * 2)
        textView.scrollRangeToVisible(textView.selectedRange())
        guard height != preferredHeight else { return }
        preferredHeight = height
        onHeightChange?(height)
    }

    func textDidChange(_ notification: Notification) {
        placeholder.isHidden = !textView.string.isEmpty
        updateSend()
        updateHeight()
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            // Shift-Return adds a line; Option-Return arrives as insertNewlineIgnoringFieldEditor.
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return false }
            sendTapped(); return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) { onCancel?(); return true }
        return false
    }

    @objc private func sendTapped() {
        let text = trimmed
        guard !text.isEmpty, !isSending else { return }
        onSend?(text)
    }
}

/// A scroll view whose scroll gestures go through the card's router, so the card decides once per
/// gesture whether the content scrolls or nothing happens.
@MainActor
private class IslandRoutedScrollView: NSScrollView {
    weak var router: IslandNotificationCard?

    var canScroll: Bool {
        (documentView?.frame.height ?? 0) > contentView.bounds.height + 1
    }

    override func scrollWheel(with event: NSEvent) {
        if let router { router.route(event, from: self) } else { super.scrollWheel(with: event) }
    }

    func scrollContent(_ event: NSEvent) { super.scrollWheel(with: event) }

    // Clicks travel up to the card, so the first one must count (see the card's hitTest).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The message inside an expanded card. Open cards scroll it; clicks always reach the card.
@MainActor
private final class IslandBodyScrollView: IslandRoutedScrollView {
    private final class Document: NSView {
        override var isFlipped: Bool { true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        horizontalScrollElasticity = .none
        verticalScrollElasticity = .allowed
        contentView.drawsBackground = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Hosts the message in a flipped document, so a long message starts at its first line.
    func setContent(_ view: NSView) {
        let document = Document()
        document.addSubview(view)
        documentView = document
    }

    override func tile() {
        super.tile()
        guard let document = documentView, let content = document.subviews.first else { return }
        if document.frame.size != content.frame.size { document.frame = CGRect(origin: .zero, size: content.frame.size) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Keep the scroller draggable; everything else is the scroll view itself, so clicks and
        // unscrollable gestures travel up to the card.
        let hit = super.hitTest(point)
        return hit is NSScroller ? hit : (hit == nil ? nil : self)
    }

    override func mouseDown(with event: NSEvent) { nextResponder?.mouseDown(with: event) }
    override func mouseUp(with event: NSEvent) { nextResponder?.mouseUp(with: event) }
}

/// Catches the rest of a swipe that dismissed a card. macOS sends scroll events to the window under
/// the pointer; once the card is gone that is the app behind it, which would scroll with the end of
/// the swipe and its momentum. This invisible window sits where the card was until the swipe ends.
@MainActor
final class IslandScrollSink {
    private static var panel: NSPanel?
    private static var release: DispatchWorkItem?

    static func hold(over rect: NSRect, level: NSWindow.Level) {
        let panel = Self.panel ?? {
            let panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            panel.contentView = SinkView()
            return panel
        }()
        Self.panel = panel
        // Clear windows let events through unless they are asked to take them.
        panel.ignoresMouseEvents = false
        panel.level = level
        panel.setFrame(rect.insetBy(dx: -24, dy: -24), display: false)
        panel.orderFrontRegardless()
        // However the swipe ends, the window never stays long.
        endSoon(after: 2)
    }

    fileprivate static func endSoon(after delay: TimeInterval) {
        release?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { end() } }
        release = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    static func end() {
        release?.cancel(); release = nil
        panel?.orderOut(nil)
    }

    private final class SinkView: NSView {
        override func scrollWheel(with event: NSEvent) {
            if event.momentumPhase == .ended || event.momentumPhase == .cancelled {
                IslandScrollSink.end()
            } else if event.phase == .ended || event.phase == .cancelled {
                // Momentum, if any, starts right after the fingers lift.
                IslandScrollSink.endSoon(after: 0.15)
            } else if event.phase.isEmpty && event.momentumPhase.isEmpty {
                // A mouse wheel: done once the ticks stop.
                IslandScrollSink.endSoon(after: 0.3)
            } else if !event.momentumPhase.isEmpty {
                IslandScrollSink.endSoon(after: 2)
            }
        }
        // Anything but scrolling means the swipe is over; the click goes nowhere, so step aside first.
        override func mouseDown(with event: NSEvent) { IslandScrollSink.end() }
        override func rightMouseDown(with event: NSEvent) { IslandScrollSink.end() }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}
