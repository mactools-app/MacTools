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
    private(set) var isClosing = false

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
        guard !isClosing, size != metrics.contentSize else { return }
        applyContentSize(size)
        render()
        startDisplayLinkIfNeeded()
    }

    func reopen() {
        guard isClosing else { return }
        isClosing = false
        closeCompletion = nil
        window.ignoresMouseEvents = false
        setExpanded(true)
    }

    func dismiss(animated: Bool, completion: @escaping @MainActor () -> Void) {
        guard animated else {
            stopDisplayLink()
            isClosing = true
            closeCompletion = nil
            completion()
            return
        }
        guard !isClosing else { return }
        isClosing = true
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
        let tabsWidth = MenuBarPanelTabLayout.contentWidth(count: tabCount)
        let actionsWidth = MenuBarPanelTabLayout.contentWidth(count: 2, width: MenuBarPanelLayout.headerAccessoryWidth)
        let requiredWidth = max(tabsWidth, actionsWidth) + MenuBarPanelLayout.notchHeaderHorizontalPadding
        let availableWidth = (panelWidth - notchWidth) / 2 - NotchMorphMetrics.islandClearance
        return requiredWidth <= availableWidth
    }

    /// Extra top inset that moves the header from the island's row to just below it.
    static func headerBelowIslandOffset(anchor: CGRect) -> CGFloat {
        let metrics = NotchMorphMetrics(anchor: anchor, contentSize: .zero)
        let belowIsland = metrics.housingOffset + metrics.housingSize.height + NotchMorphMetrics.contentGap
        return max(belowIsland - metrics.contentTopInset - MenuBarPanelLayout.panelTopPadding, 0)
    }

    // MARK: - Animation

    private func applyContentSize(_ size: CGSize) {
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
        model.advance(by: min(max(elapsed, 0), 1.0 / 30.0))
        render()
        finishIfSettled()
    }

    private func finishIfSettled() {
        guard model.isSettled else { return }
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

// MARK: - Spring model

/// Two critically tuned springs: width leads on the way out and height leads on
/// the way back, which produces the "widen, then deepen" feel of the system island.
struct NotchMorphModel {
    struct Spring {
        var value: Double = 0
        var velocity: Double = 0

        mutating func step(toward target: Double, response: Double, dampingRatio: Double, dt: Double) {
            let stiffness = pow(2 * Double.pi / response, 2)
            let damping = 4 * Double.pi * dampingRatio / response
            velocity += (-stiffness * (value - target) - damping * velocity) * dt
            value += velocity * dt
        }

        func isSettled(at target: Double) -> Bool {
            abs(value - target) < 0.001 && abs(velocity) < 0.01
        }
    }

    private static let substep = 1.0 / 480.0

    var target: Double = 0
    private(set) var width = Spring()
    private(set) var height = Spring()
    private(set) var contentOpacity: Double = 0

    var isSettled: Bool {
        width.isSettled(at: target) && height.isSettled(at: target)
            && abs(contentOpacity - target) < 0.01
    }

    mutating func snapToTarget() {
        width = Spring(value: target)
        height = Spring(value: target)
        contentOpacity = target
    }

    mutating func advance(by elapsed: Double) {
        var remaining = elapsed
        while remaining > 0 {
            let dt = min(Self.substep, remaining)
            remaining -= dt
            if target > 0.5 {
                width.step(toward: target, response: 0.36, dampingRatio: 0.76, dt: dt)
                height.step(toward: target, response: 0.46, dampingRatio: 0.82, dt: dt)
            } else {
                width.step(toward: target, response: 0.34, dampingRatio: 1, dt: dt)
                height.step(toward: target, response: 0.27, dampingRatio: 1, dt: dt)
            }
            // Content follows the surface in, but leaves ahead of it so nothing is
            // still legible while the shape folds back into the camera housing.
            let opacityTarget = target > 0.5 ? Self.smoothstep(0.42, 0.92, height.value) : 0
            let timeConstant = target > 0.5 ? 0.035 : 0.045
            contentOpacity += (opacityTarget - contentOpacity) * (1 - exp(-dt / timeConstant))
        }
    }

    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

// MARK: - Geometry

/// Geometry in window coordinates (origin at the bottom left). The window's top
/// edge is aligned with the top of the expanded surface.
struct NotchMorphMetrics {
    /// The housing sits a few points below the top of the screen.
    static let housingTopInset: CGFloat = 6
    /// The system draws its own island around the housing and grows it upward
    /// (to about 4pt) while the pointer is on it, so the expanded surface rises
    /// above that to keep the island inside it in every state.
    static let expandedTopInset: CGFloat = 3
    static let contentGap: CGFloat = 4
    /// Space kept between the header capsules and the island on each side.
    static let islandClearance: CGFloat = 12
    static let bottomInset: CGFloat = 6
    static let expandedCornerRadius: CGFloat = 26
    /// Room for spring overshoot and the soft drop shadow.
    static let margin: CGFloat = 28

    let anchor: CGRect
    let contentSize: CGSize
    let housingSize: CGSize
    let collapsedSize: CGSize
    let expandedSize: CGSize
    /// Distance from the window top (the expanded surface top) to the housing top.
    let housingOffset: CGFloat
    /// Distance from the window top to the top of the hosted content.
    let contentTopInset: CGFloat

    init(anchor: CGRect, contentSize: CGSize) {
        self.anchor = anchor
        self.contentSize = contentSize
        let housingInset = min(Self.housingTopInset, anchor.height * 0.2)
        let expandedInset = min(Self.expandedTopInset, housingInset)
        housingOffset = housingInset - expandedInset
        housingSize = CGSize(width: anchor.width, height: max(anchor.height - housingInset, 1))
        // Start one point inside the housing so the first frame is hidden by it.
        collapsedSize = CGSize(width: max(housingSize.width - 2, 2), height: max(housingSize.height - 2, 2))
        // The content's header row is centered on the island, beside it.
        let islandCenter = housingOffset + housingSize.height / 2
        contentTopInset = max(
            islandCenter - (MenuBarPanelLayout.panelTopPadding + MenuBarPanelLayout.headerHeight / 2), 0
        )
        expandedSize = CGSize(
            width: max(contentSize.width, housingSize.width),
            height: contentTopInset + contentSize.height + Self.bottomInset
        )
    }

    var windowFrame: CGRect {
        let width = expandedSize.width + Self.margin * 2
        let height = expandedSize.height + Self.margin
        let top = anchor.maxY - (anchor.height - housingSize.height) + housingOffset
        return CGRect(x: (anchor.midX - width / 2).rounded(), y: (top - height).rounded(),
                      width: width.rounded(), height: height.rounded())
    }

    var windowSize: CGSize { windowFrame.size }


    func surfaceRect(for model: NotchMorphModel) -> CGRect {
        surfaceRect(widthFraction: model.width.value, heightFraction: model.height.value)
    }

    func surfaceRect(expandedFraction fraction: Double) -> CGRect {
        surfaceRect(widthFraction: fraction, heightFraction: fraction)
    }

    func surfaceRect(widthFraction: Double, heightFraction: Double) -> CGRect {
        let size = windowSize
        let width = max(Self.lerp(collapsedSize.width, expandedSize.width, widthFraction), 2)
        let height = max(Self.lerp(collapsedSize.height, expandedSize.height, heightFraction), 2)
        // Rises from inside the housing to the expanded top as the surface deepens.
        let collapsedTop = housingOffset + (housingSize.height - collapsedSize.height) / 2
        let topInset = Self.lerp(collapsedTop, 0, min(max(heightFraction, 0), 1))
        return CGRect(x: size.width / 2 - width / 2, y: size.height - topInset - height,
                      width: width, height: height)
    }

    /// Stays a pill while the surface is shallow, then relaxes toward the
    /// expanded radius as it deepens, so the corners change continuously.
    func cornerRadius(for rect: CGRect, heightFraction: Double) -> CGFloat {
        let pill = min(rect.height, rect.width) / 2
        let settle = NotchMorphModel.smoothstep(0.12, 1, heightFraction)
        return min(Self.lerp(pill, Self.expandedCornerRadius, settle), pill)
    }

    func screenRect(fromSurfaceRect rect: CGRect) -> CGRect {
        rect.offsetBy(dx: windowFrame.minX, dy: windowFrame.minY)
    }

    static func lerp(_ from: CGFloat, _ to: CGFloat, _ fraction: Double) -> CGFloat {
        from + (to - from) * CGFloat(fraction)
    }
}

enum NotchSurfacePath {
    /// A rounded rectangle whose corners ease into the straight edges
    /// (continuous curvature) when there is room, and become exact circular
    /// arcs as the shape approaches a pill, so morphing never changes the
    /// path structure.
    static func make(in rect: CGRect, radius requestedRadius: CGFloat) -> CGPath {
        let limit = min(rect.width, rect.height) / 2
        let radius = max(min(requestedRadius, limit), 0)
        let path = CGMutablePath()
        guard radius > 0 else {
            path.addRect(rect)
            return path
        }

        let smoothing = min(max((limit / radius - 1) / 0.4, 0), 1)
        let extent = radius * (1 + 0.4 * smoothing)
        let handle = extent * (0.5523 + (0.8 - 0.5523) * smoothing)
        let minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY

        path.move(to: CGPoint(x: minX + extent, y: maxY))
        path.addLine(to: CGPoint(x: maxX - extent, y: maxY))
        path.addCurve(to: CGPoint(x: maxX, y: maxY - extent),
                      control1: CGPoint(x: maxX - extent + handle, y: maxY),
                      control2: CGPoint(x: maxX, y: maxY - extent + handle))
        path.addLine(to: CGPoint(x: maxX, y: minY + extent))
        path.addCurve(to: CGPoint(x: maxX - extent, y: minY),
                      control1: CGPoint(x: maxX, y: minY + extent - handle),
                      control2: CGPoint(x: maxX - extent + handle, y: minY))
        path.addLine(to: CGPoint(x: minX + extent, y: minY))
        path.addCurve(to: CGPoint(x: minX, y: minY + extent),
                      control1: CGPoint(x: minX + extent - handle, y: minY),
                      control2: CGPoint(x: minX, y: minY + extent - handle))
        path.addLine(to: CGPoint(x: minX, y: maxY - extent))
        path.addCurve(to: CGPoint(x: minX + extent, y: maxY),
                      control1: CGPoint(x: minX, y: maxY - extent + handle),
                      control2: CGPoint(x: minX + extent - handle, y: maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Views

/// Root view: a shadow behind a black, shape-masked surface that hosts the content.
@MainActor
final class NotchMorphView: NSView {
    private static let contentLift: CGFloat = 10

    private let shadowView = NSView()
    private let surfaceView = NSView()
    private let surfaceMask = CAShapeLayer()
    private weak var content: NSView?
    private var surfacePath: CGPath?

    init(content: NSView) {
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false

        shadowView.wantsLayer = true
        shadowView.layer?.shadowColor = NSColor.black.cgColor
        shadowView.layer?.shadowRadius = 16
        shadowView.layer?.shadowOffset = CGSize(width: 0, height: -6)
        shadowView.layer?.shadowOpacity = 0
        shadowView.layer?.masksToBounds = false
        addSubview(shadowView)

        surfaceView.wantsLayer = true
        surfaceView.layer?.backgroundColor = NSColor.black.cgColor
        surfaceView.layer?.mask = surfaceMask
        addSubview(surfaceView)

        content.wantsLayer = true
        content.autoresizingMask = []
        content.alphaValue = 0
        surfaceView.addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }

    /// Clicks outside the visible surface must not land on hidden content.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard let surfacePath, surfacePath.contains(local) else { return nil }
        return super.hitTest(point)
    }

    func releaseContent() {
        content?.removeFromSuperview()
        content = nil
    }

    func apply(model: NotchMorphModel, metrics: NotchMorphMetrics) {
        let rect = metrics.surfaceRect(for: model)
        let radius = metrics.cornerRadius(for: rect, heightFraction: model.height.value)
        let path = NotchSurfacePath.make(in: rect, radius: radius)
        surfacePath = path

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadowView.frame = bounds
        surfaceView.frame = bounds
        surfaceMask.frame = surfaceView.bounds
        surfaceMask.path = path
        shadowView.layer?.shadowPath = path
        let reveal = NotchMorphModel.smoothstep(0.2, 1, model.height.value)
        shadowView.layer?.shadowOpacity = Float(0.38 * reveal)

        if let content {
            let size = metrics.contentSize
            let lift = Self.contentLift * CGFloat(1 - min(max(model.height.value, 0), 1))
            let top = bounds.height - metrics.contentTopInset + lift
            let origin = CGPoint(x: ((bounds.width - size.width) / 2).rounded(), y: (top - size.height).rounded())
            if content.frame.size != size {
                content.frame = CGRect(origin: origin, size: size)
            } else if content.frame.origin != origin {
                content.setFrameOrigin(origin)
            }
            content.alphaValue = CGFloat(min(max(model.contentOpacity, 0), 1))
        }
        CATransaction.commit()
    }
}

@MainActor
private final class NotchDisplayLinkTarget: NSObject {
    var onFrame: ((CADisplayLink) -> Void)?

    @objc func step(_ link: CADisplayLink) {
        onFrame?(link)
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
