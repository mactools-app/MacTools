import AppKit
import QuartzCore

/// Plugin-owned surface: the shared host morph and its layout stay unchanged.
@MainActor
final class IslandSplitMorphView: NSView {
    private let mask = CAShapeLayer()
    private let surface = NSView()
    private let shadowView = NSView()
    private weak var content: NSView?
    private var path: CGPath?

    init(content: NSView) {
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        shadowView.wantsLayer = true
        shadowView.layer?.shadowColor = NSColor.black.cgColor
        shadowView.layer?.shadowRadius = 16
        shadowView.layer?.shadowOffset = CGSize(width: 0, height: -6)
        shadowView.layer?.masksToBounds = false
        addSubview(shadowView)
        surface.wantsLayer = true
        surface.layer?.backgroundColor = NSColor.black.cgColor
        surface.layer?.mask = mask
        addSubview(surface)
        content.wantsLayer = true
        surface.addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let path, path.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }

    func releaseContent() { content?.removeFromSuperview(); content = nil }

    func apply(model: NotchMorphModel, geometry: IslandSplitGeometry, contentSize: CGSize, reduceMotion: Bool) {
        let capsule = reduceMotion ? geometry.destination
            : geometry.capsule(widthFraction: model.width.value, heightFraction: model.height.value)
        let path = geometry.path(widthFraction: model.width.value, heightFraction: model.height.value, reduceMotion: reduceMotion)
        self.path = path
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.frame = bounds
        shadowView.frame = bounds
        // Only the emerging capsule casts a shadow; the system owns the upper pill.
        shadowView.layer?.shadowPath = NotchSurfacePath.make(in: capsule, radius: geometry.radius(for: capsule, heightFraction: reduceMotion ? 1 : model.height.value))
        shadowView.layer?.shadowOpacity = Float(0.38 * NotchMorphModel.smoothstep(0.2, 1, model.height.value))
        mask.frame = bounds
        mask.path = path
        content?.frame = CGRect(x: capsule.midX - contentSize.width / 2,
                                y: capsule.maxY - contentSize.height, width: contentSize.width, height: contentSize.height)
        content?.alphaValue = reduceMotion ? 1 : CGFloat(min(max(model.contentOpacity, 0), 1))
        CATransaction.commit()
    }
}
