import AppKit
import QuartzCore

/// Hosts the menu-bar panel content inside a black surface that grows out of the
/// camera housing and folds back into it.
///
/// The surface is driven by interruptible springs on a display link instead of
/// fixed-duration Core Animation keyframes, so hovering back in mid-close reverses
/// the motion from wherever it currently is, with its current velocity.
@MainActor
final class NotchMenuBarPanel {
    static let minimumFeatureContentHeight: CGFloat = 76

    private final class Window: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    let window: NSPanel
    private let content: NSViewController
    private let morphView: NotchMorphView
    let anchor: CGRect
    private let contentWasLayerBacked: Bool
    private let contentAutoresizingMask: NSView.AutoresizingMask
    private var model = NotchMorphModel()
    private var metrics: NotchMorphMetrics
    private var displayLink: CADisplayLink?
    private let displayLinkTarget = NotchDisplayLinkTarget()
    private var lastFrameTimestamp: CFTimeInterval?
    private var closeCompletion: (@MainActor () -> Void)?
    private var systemPanelMonitor: DispatchSourceTimer?
    /// The content size the surface shows while the panel changes size; nil when settled.
    private var sizeSpring: (width: NotchMorphModel.Spring, height: NotchMorphModel.Spring)?
    private(set) var isClosing = false
    /// Why the panel is closing. Only a close because the pointer left can be undone by the pointer
    /// coming back; Escape, a click elsewhere or a system panel closes it for good.
    enum CloseReason { case pointerLeft, dismissed }
    private(set) var closeReason: CloseReason?
    /// The latest size asked for while closing, applied if the panel reopens.
    private var pendingSize: CGSize?

    var canReopenOnHover: Bool { isClosing && closeReason == .pointerLeft }
    var contentSize: CGSize { metrics.contentSize }

    init(anchor: CGRect, content: NSViewController) {
        self.anchor = anchor
        self.content = content
        metrics = NotchMorphMetrics(anchor: anchor, contentSize: .zero)
        contentWasLayerBacked = content.view.wantsLayer
        contentAutoresizingMask = content.view.autoresizingMask

        window = Window(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isFloatingPanel = true
        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]

        morphView = NotchMorphView(content: content.view)
        let controller = NSViewController()
        controller.view = morphView
        controller.addChild(content)
        window.contentViewController = controller

        displayLinkTarget.onFrame = { [weak self] link in self?.step(link) }
    }

    isolated deinit {
        systemPanelMonitor?.cancel()
        displayLink?.invalidate()
    }

    // MARK: - Presentation

    func present(size: CGSize) {
        applyContentSize(size)
        model = NotchMorphModel()
        render()
        window.orderFrontRegardless()
        setExpanded(true)
    }

    func resize(to size: CGSize) {
        guard size != metrics.contentSize else { pendingSize = nil; return }
        // While closing the shape keeps the size it is folding from; the new one waits for a reopen.
        guard !isClosing else { pendingSize = size; return }
        let shown = sizeSpring.map { CGSize(width: $0.width.value, height: $0.height.value) } ?? metrics.contentSize
        // Size changes (a list growing, a wider panel) glide on a spring from wherever the surface
        // is now. Reduce Motion, or a panel still opening or closing, just applies the new size.
        guard model.isSettled, model.target == 1, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            applyContentSize(size)
            render()
            startDisplayLinkIfNeeded()
            return
        }
        sizeSpring = (NotchMorphModel.Spring(value: Double(shown.width), velocity: sizeSpring?.width.velocity ?? 0),
                      NotchMorphModel.Spring(value: Double(shown.height), velocity: sizeSpring?.height.velocity ?? 0))
        metrics = NotchMorphMetrics(anchor: anchor, contentSize: size)
        metrics.windowContentSize = CGSize(width: max(shown.width, size.width), height: max(shown.height, size.height))
        metrics.revealedContentSize = shown
        let frame = metrics.windowFrame
        if window.frame != frame { window.setFrame(frame, display: false) }
        render()
        startDisplayLinkIfNeeded()
    }

    func reopen() {
        guard isClosing else { return }
        isClosing = false
        closeReason = nil
        closeCompletion = nil
        if let pendingSize {
            self.pendingSize = nil
            applyContentSize(pendingSize)
            render()
        }
        window.ignoresMouseEvents = false
        setExpanded(true)
    }

    func dismiss(animated: Bool, reason: CloseReason = .dismissed, completion: @escaping @MainActor () -> Void) {
        guard animated else {
            stopDisplayLink()
            isClosing = true
            closeReason = reason
            closeCompletion = nil
            completion()
            return
        }
        guard !isClosing else {
            // A close that becomes explicit stays explicit.
            if reason == .dismissed { closeReason = .dismissed }
            return
        }
        isClosing = true
        closeReason = reason
        // A size change in progress stops where it is; the surface folds away from there.
        sizeSpring = nil
        closeCompletion = completion
        window.ignoresMouseEvents = true
        setExpanded(false)
    }

    func detachContent() {
        stopWatchingForSystemPanel()
        stopDisplayLink()
        window.orderOut(nil)
        morphView.releaseContent()
        content.view.alphaValue = 1
        content.view.autoresizingMask = contentAutoresizingMask
        content.view.wantsLayer = contentWasLayerBacked
        content.removeFromParent()
    }

    /// The screen area the hover controller should treat as part of the panel.
    /// While opening it is the final surface so the pointer can travel ahead of
    /// the animation; while closing it is only what is still visible.
    var interactiveScreenFrame: CGRect {
        let rect = isClosing ? metrics.surfaceRect(for: model) : metrics.surfaceRect(expandedFraction: 1)
        return metrics.screenRect(fromSurfaceRect: rect)
    }

    /// Both header groups must fit in the space beside the camera housing.
    static func headerFitsBesideIsland(tabCount: Int, panelWidth: CGFloat, notchWidth: CGFloat) -> Bool {
        panelWidth >= minimumWidthForHeaderBesideIsland(tabCount: tabCount, notchWidth: notchWidth)
    }

    static func minimumWidthForHeaderBesideIsland(tabCount: Int, notchWidth: CGFloat) -> CGFloat {
        let tabsWidth = MenuBarPanelTabLayout.contentWidth(count: tabCount)
        let actionsWidth = MenuBarPanelTabLayout.contentWidth(count: 2, width: MenuBarPanelLayout.headerAccessoryWidth)
        let sideWidth = max(tabsWidth, actionsWidth) + MenuBarPanelLayout.notchHeaderHorizontalPadding
            + NotchMorphMetrics.islandClearance
        return (notchWidth + sideWidth * 2).rounded(.up)
    }

    /// Extra top inset that moves the header from the island's row to just below it.
    static func headerBelowIslandOffset(anchor: CGRect) -> CGFloat {
        let metrics = NotchMorphMetrics(anchor: anchor, contentSize: .zero)
        let belowIsland = metrics.housingOffset + metrics.housingSize.height + NotchMorphMetrics.contentGap
        return max(belowIsland - metrics.contentTopInset - MenuBarPanelLayout.panelTopPadding, 0)
    }

    // MARK: - Animation

    private func applyContentSize(_ size: CGSize) {
        sizeSpring = nil
        metrics = NotchMorphMetrics(anchor: anchor, contentSize: size)
        let frame = metrics.windowFrame
        if window.frame != frame {
            window.setFrame(frame, display: false)
        }
    }

    private func setExpanded(_ expanded: Bool) {
        model.target = expanded ? 1 : 0
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            model.snapToTarget()
            render()
            finishIfSettled()
            return
        }
        startDisplayLinkIfNeeded()
    }

    private func startDisplayLinkIfNeeded() {
        guard displayLink == nil else { return }
        let link = morphView.displayLink(target: displayLinkTarget, selector: #selector(NotchDisplayLinkTarget.step(_:)))
        link.add(to: .main, forMode: .common)
        lastFrameTimestamp = nil
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        lastFrameTimestamp = nil
    }

    private func step(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let elapsed = lastFrameTimestamp.map { now - $0 } ?? (link.targetTimestamp - link.timestamp)
        lastFrameTimestamp = now
        let dt = min(max(elapsed, 0), 1.0 / 30.0)
        model.advance(by: dt)
        if var springs = sizeSpring {
            let target = metrics.contentSize
            // The spring SwiftUI content in the panel uses, so a panel following its content keeps pace.
            springs.width.step(toward: Double(target.width), response: 0.36, dampingRatio: 0.86, dt: dt)
            springs.height.step(toward: Double(target.height), response: 0.36, dampingRatio: 0.86, dt: dt)
            func settled(_ spring: NotchMorphModel.Spring, _ value: CGFloat) -> Bool {
                abs(spring.value - Double(value)) < 0.5 && abs(spring.velocity) < 1
            }
            if settled(springs.width, target.width), settled(springs.height, target.height) {
                sizeSpring = nil
                metrics.revealedContentSize = nil
                metrics.windowContentSize = nil
                let frame = metrics.windowFrame
                if window.frame != frame { window.setFrame(frame, display: false) }
            } else {
                sizeSpring = springs
                metrics.revealedContentSize = CGSize(width: springs.width.value, height: springs.height.value)
            }
        }
        render()
        finishIfSettled()
    }

    private func finishIfSettled() {
        guard model.isSettled, sizeSpring == nil else { return }
        model.snapToTarget()
        render()
        stopDisplayLink()
        guard model.target == 0, isClosing, let completion = closeCompletion else { return }
        closeCompletion = nil
        completion()
    }

    private func render() {
        morphView.apply(model: model, metrics: metrics)
    }

    // MARK: - System panel coordination

    static func systemPanelDetector(over anchor: CGRect) -> NotchSystemPanelDetector {
        NotchSystemPanelDetector(
            anchor: CGRect(x: anchor.minX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - anchor.maxY,
                           width: anchor.width, height: anchor.height)
        )
    }

    func watchForSystemPanel(_ detector: NotchSystemPanelDetector,
                             onPresentation: @escaping @MainActor () -> Void) {
        // Spotlight can take keyboard input without sending this panel a key-window
        // notification. Check only while the panel is on screen, off the UI thread.
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100),
                       leeway: .milliseconds(20))
        timer.setEventHandler { @Sendable [weak self] in
            guard detector.isVisible else { return }
            Task { @MainActor [weak self] in
                guard let self, self.systemPanelMonitor != nil else { return }
                self.stopWatchingForSystemPanel()
                onPresentation()
            }
        }
        systemPanelMonitor = timer
        timer.activate()
    }

    private func stopWatchingForSystemPanel() {
        systemPanelMonitor?.cancel()
        systemPanelMonitor = nil
    }
}

// Header placement belongs to the menu-bar panel, not the shared surface.
extension NotchMorphMetrics {
    init(anchor: CGRect, contentSize: CGSize) {
        let housing = Self(anchor: anchor, contentSize: contentSize, contentTopInset: 0)
        let islandCenter = housing.housingOffset + housing.housingSize.height / 2
        let inset = max(
            islandCenter - (MenuBarPanelLayout.panelTopPadding + MenuBarPanelLayout.headerHeight / 2),
            -MenuBarPanelLayout.panelTopPadding
        )
        self.init(anchor: anchor, contentSize: contentSize, contentTopInset: inset)
    }
}

struct NotchSystemPanelDetector: Sendable {
    let anchor: CGRect

    var isVisible: Bool {
        guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
                  as? [[String: Any]] else { return false }
        return windows.contains { info in
            guard let owner = info[kCGWindowOwnerName as String] as? String,
                  owner == "Siri" || owner == "Spotlight" || owner == "Siri AI",
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let app = NSRunningApplication(processIdentifier: pid),
                  let path = app.bundleURL?.path,
                  path.hasPrefix("/System/Library/") || path.hasPrefix("/System/Applications/"),
                  let bounds = info[kCGWindowBounds as String] as? [String: Double],
                  let x = bounds["X"], let y = bounds["Y"],
                  let width = bounds["Width"], let height = bounds["Height"],
                  height > max(anchor.height, 64), width >= 260 else { return false }
            return CGRect(x: x, y: y, width: width, height: height).intersects(anchor)
        }
    }
}
