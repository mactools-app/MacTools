import AppKit
import QuartzCore

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
    /// The compact island sits a few points below the top of the screen.
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
    /// A wide camera cutout reaches the display edge, so the surface grows from
    /// that edge with square top corners instead of floating below it.
    let meetsDisplayTop: Bool

    init(anchor: CGRect, contentSize: CGSize, contentTopInset: CGFloat) {
        self.anchor = anchor
        self.contentSize = contentSize
        // AppKit reports the housing rectangle. A wide camera cutout reaches the
        // display edge, while the compact island has space above it.
        let isWideCameraCutout = anchor.width >= anchor.height * 3
        let housingInset = isWideCameraCutout ? 0 : min(Self.housingTopInset, anchor.height * 0.2)
        let expandedInset = min(Self.expandedTopInset, housingInset)
        meetsDisplayTop = expandedInset == 0
        housingOffset = housingInset - expandedInset
        housingSize = CGSize(width: anchor.width, height: max(anchor.height - housingInset, 1))
        // Start one point inside the housing so the first frame is hidden by it.
        collapsedSize = CGSize(width: max(housingSize.width - 2, 2), height: max(housingSize.height - 2, 2))
        self.contentTopInset = contentTopInset
        expandedSize = CGSize(
            width: max(contentSize.width, housingSize.width),
            height: contentTopInset + contentSize.height + Self.bottomInset
        )
    }

    /// While the host panel changes size, its window keeps the larger of the two sizes and the
    /// surface shows `revealedContentSize` of the content, so the change can be one motion.
    var windowContentSize: CGSize?
    var revealedContentSize: CGSize?

    /// The expanded surface: all of the content, or the part being revealed.
    var expandedWidth: CGFloat {
        revealedContentSize.map { max($0.width, housingSize.width) } ?? expandedSize.width
    }
    var expandedHeight: CGFloat {
        revealedContentSize.map { contentTopInset + $0.height + Self.bottomInset } ?? expandedSize.height
    }

    var windowFrame: CGRect {
        let width = (windowContentSize.map { max($0.width, housingSize.width) } ?? expandedSize.width) + Self.margin * 2
        let contentHeight = windowContentSize.map { contentTopInset + $0.height + Self.bottomInset } ?? expandedSize.height
        let height = (contentHeight + Self.margin).rounded()
        let top = anchor.maxY - (anchor.height - housingSize.height) + housingOffset
        return CGRect(x: (anchor.midX - width / 2).rounded(), y: top - height,
                      width: width.rounded(), height: height)
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
        let width = max(Self.lerp(collapsedSize.width, expandedWidth, widthFraction), 2)
        let height = max(Self.lerp(collapsedSize.height, expandedHeight, heightFraction), 2)
        // Rises from inside the housing to the expanded top as the surface deepens.
        // A surface that meets the display edge stays pinned to it.
        let collapsedTop = meetsDisplayTop ? 0 : housingOffset + (housingSize.height - collapsedSize.height) / 2
        let topInset = Self.lerp(collapsedTop, 0, min(max(heightFraction, 0), 1))
        return CGRect(x: size.width / 2 - width / 2, y: size.height - topInset - height,
                      width: width, height: height)
    }

    /// Stays a pill while the surface is shallow, then relaxes toward the
    /// expanded radius as it deepens, so the corners change continuously.
    /// Set to stay a full pill at every stage (island notifications). The host
    /// panel leaves it off and relaxes to `expandedCornerRadius`.
    var staysPill = false

    /// Blends the corners back toward a full pill (0 = normal, 1 = pill) so a pill-shaped
    /// notification can ease into a larger card. The host panel never sets it.
    var pillAmount: Double = 0

    func cornerRadius(for rect: CGRect, heightFraction: Double) -> CGFloat {
        let pill = min(rect.height, rect.width) / 2
        if staysPill { return pill }
        let settle = NotchMorphModel.smoothstep(0.12, 1, heightFraction)
        let radius = min(Self.lerp(pill, Self.expandedCornerRadius, settle), pill)
        return pillAmount > 0 ? Self.lerp(radius, pill, min(pillAmount, 1)) : radius
    }

    func topCornerRadius(for rect: CGRect, heightFraction: Double) -> CGFloat {
        meetsDisplayTop ? 0 : cornerRadius(for: rect, heightFraction: heightFraction)
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
    /// arcs as the shape approaches a pill. The top corners can use a smaller
    /// radius, down to square, for a surface that meets the display edge.
    static func make(in rect: CGRect, radius: CGFloat, topRadius: CGFloat? = nil) -> CGPath {
        let limit = min(rect.width, rect.height) / 2
        let bottom = Corner(radius: radius, limit: limit)
        let top = Corner(radius: topRadius ?? radius, limit: limit)
        let minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        let path = CGMutablePath()

        path.move(to: CGPoint(x: minX + top.extent, y: maxY))
        path.addLine(to: CGPoint(x: maxX - top.extent, y: maxY))
        path.addCurve(to: CGPoint(x: maxX, y: maxY - top.extent),
                      control1: CGPoint(x: maxX - top.extent + top.handle, y: maxY),
                      control2: CGPoint(x: maxX, y: maxY - top.extent + top.handle))
        path.addLine(to: CGPoint(x: maxX, y: minY + bottom.extent))
        path.addCurve(to: CGPoint(x: maxX - bottom.extent, y: minY),
                      control1: CGPoint(x: maxX, y: minY + bottom.extent - bottom.handle),
                      control2: CGPoint(x: maxX - bottom.extent + bottom.handle, y: minY))
        path.addLine(to: CGPoint(x: minX + bottom.extent, y: minY))
        path.addCurve(to: CGPoint(x: minX, y: minY + bottom.extent),
                      control1: CGPoint(x: minX + bottom.extent - bottom.handle, y: minY),
                      control2: CGPoint(x: minX, y: minY + bottom.extent - bottom.handle))
        path.addLine(to: CGPoint(x: minX, y: maxY - top.extent))
        path.addCurve(to: CGPoint(x: minX + top.extent, y: maxY),
                      control1: CGPoint(x: minX, y: maxY - top.extent + top.handle),
                      control2: CGPoint(x: minX + top.extent - top.handle, y: maxY))
        path.closeSubpath()
        return path
    }

    /// One corner's reach along each edge and its Bézier handle length.
    private struct Corner {
        let extent: CGFloat
        let handle: CGFloat

        init(radius requested: CGFloat, limit: CGFloat) {
            let radius = max(min(requested, limit), 0)
            guard radius > 0 else {
                extent = 0
                handle = 0
                return
            }
            let smoothing = min(max((limit / radius - 1) / 0.4, 0), 1)
            extent = radius * (1 + 0.4 * smoothing)
            handle = extent * (0.5523 + (0.8 - 0.5523) * smoothing)
        }
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
        let path = NotchSurfacePath.make(
            in: rect, radius: radius,
            topRadius: metrics.topCornerRadius(for: rect, heightFraction: model.height.value)
        )
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
            // While the surface is shorter than its content, the content ends where the surface does.
            if metrics.revealedContentSize != nil {
                content.wantsLayer = true
                let mask = (content.layer?.mask as? CAShapeLayer) ?? CAShapeLayer()
                mask.frame = content.bounds
                // Into the content's own coordinates, which SwiftUI's hosting view flips.
                var shift = content.isFlipped
                    ? CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: -content.frame.minX,
                                        ty: content.bounds.height + content.frame.minY)
                    : CGAffineTransform(translationX: -content.frame.minX, y: -content.frame.minY)
                mask.path = path.copy(using: &shift)
                content.layer?.mask = mask
            } else if content.layer?.mask != nil {
                content.layer?.mask = nil
            }
        }
        CATransaction.commit()
    }
}

@MainActor
final class NotchDisplayLinkTarget: NSObject {
    var onFrame: ((CADisplayLink) -> Void)?

    @objc func step(_ link: CADisplayLink) {
        onFrame?(link)
    }
}

