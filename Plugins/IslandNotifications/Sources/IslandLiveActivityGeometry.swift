import CoreGraphics

/// All frames here use AppKit's desktop coordinates, except at the AX conversion boundary.
enum IslandLiveActivityPlacement: Equatable {
    case camera
    case split(CGRect)
    case native

    static func resolve(axFrames: [CGRect?], complete: Bool, desktopTop: CGFloat,
                        screen: CGRect, anchor: CGRect) -> Self {
        evaluate(axFrames: axFrames, complete: complete, desktopTop: desktopTop, screen: screen, anchor: anchor).placement
    }

    static func evaluate(axFrames: [CGRect?], complete: Bool, desktopTop: CGFloat,
                         screen: CGRect, anchor: CGRect) -> (placement: Self, reason: String) {
        guard complete else { return (.native, "incomplete-ax-tree") }
        guard desktopTop.isFinite else { return (.native, "invalid-primary-screen-height") }
        var activities: [CGRect] = []
        for raw in axFrames {
            guard let raw, raw.origin.x.isFinite, raw.origin.y.isFinite,
                  raw.width.isFinite, raw.height.isFinite, raw.width > 0, raw.height > 0 else { return (.native, "unreadable-or-invalid-activity-frame") }
            let frame = CGRect(x: raw.minX, y: desktopTop - raw.maxY, width: raw.width, height: raw.height)
            guard frame.intersects(screen) else { continue }
            // Only the island at the camera can be an attachment. Expanded activities
            // and unexpected positions must not strand a native banner off screen.
            guard frame.height <= 60, frame.width <= screen.width * 0.8 else { return (.native, "expanded-activity") }
            guard screen.contains(frame),
                  frame.minY >= anchor.minY - 60, frame.maxY <= screen.maxY,
                  abs(frame.midX - anchor.midX) <= screen.width * 0.25 else { return (.native, "activity-outside-camera-region") }
            activities.append(frame)
        }
        guard let first = activities.first else { return (.camera, "no-visible-activity-on-screen") }
        let union = activities.dropFirst().reduce(first) { $0.union($1) }
        guard union.height <= 60, union.width <= screen.width * 0.8 else { return (.native, "expanded-activity-envelope") }
        // Use an actual capsule, never an envelope across separate activities:
        // an envelope would paint visible black into the system's gaps at rest.
        // The lowest capsule keeps the destination below every visible activity.
        let attachment = activities.min {
            if $0.minY != $1.minY { return $0.minY < $1.minY }
            return abs($0.midX - anchor.midX) < abs($1.midX - anchor.midX)
        } ?? first
        return (.split(attachment), "compact-live-activity")
    }
}

struct IslandSplitGeometry {
    static let gap: CGFloat = 6
    static let margin: CGFloat = 28
    let activity: CGRect
    let expandedSize: CGSize
    /// Matches camera mode: one-line cards stay a pill, longer cards relax to the expanded radius.
    var staysPill = true
    /// See `NotchMorphMetrics.pillAmount`.
    var pillAmount: Double = 0

    func radius(for rect: CGRect, heightFraction: Double) -> CGFloat {
        let pill = min(rect.width, rect.height) / 2
        guard !staysPill else { return pill }
        let settle = NotchMorphModel.smoothstep(0.12, 1, heightFraction)
        let radius = min(NotchMorphMetrics.lerp(pill, NotchMorphMetrics.expandedCornerRadius, settle), pill)
        return pillAmount > 0 ? NotchMorphMetrics.lerp(radius, pill, min(pillAmount, 1)) : radius
    }

    var windowFrame: CGRect {
        let width = max(activity.width, expandedSize.width) + Self.margin * 2
        let height = activity.height + Self.gap + expandedSize.height + Self.margin * 2
        return CGRect(x: activity.midX - width / 2, y: activity.maxY + Self.margin - height,
                      width: width, height: height)
    }

    var source: CGRect { activity.offsetBy(dx: -windowFrame.minX, dy: -windowFrame.minY) }
    var destination: CGRect {
        CGRect(x: source.midX - expandedSize.width / 2, y: source.minY - Self.gap - expandedSize.height,
               width: expandedSize.width, height: expandedSize.height)
    }

    func capsule(widthFraction: Double, heightFraction: Double) -> CGRect {
        let h = max(0, heightFraction)
        // Move the top ahead of the growing height so a visible neck stretches
        // before detachment. The spring's small overshoot survives at the endpoint.
        let travel = h + 0.35 * sin(.pi * min(h, 1))
        // Widen only as the capsule travels out from under the system pill, so it never
        // shows black "ears" beside the music island while still overlapping it.
        let width = max(2, NotchMorphMetrics.lerp(source.width, destination.width, min(widthFraction, h)))
        let height = max(2, NotchMorphMetrics.lerp(source.height, destination.height, h))
        let top = NotchMorphMetrics.lerp(source.maxY, destination.maxY, travel)
        return CGRect(x: source.midX - width / 2, y: top - height, width: width, height: height)
    }

    func neckWidth(heightFraction: Double, reduceMotion: Bool) -> CGFloat {
        guard !reduceMotion else { return 0 }
        return min(source.width * 0.34, expandedSize.width * 0.2)
            * CGFloat(1 - NotchMorphModel.smoothstep(0.5, 0.94, heightFraction))
    }

    func path(widthFraction: Double, heightFraction: Double, reduceMotion: Bool = false) -> CGPath {
        let lower = reduceMotion ? destination : capsule(widthFraction: widthFraction, heightFraction: heightFraction)
        let path = CGMutablePath()
        path.addPath(NotchSurfacePath.make(in: lower, radius: radius(for: lower, heightFraction: reduceMotion ? 1 : heightFraction)))
        // The hidden copy of the system pill is only needed while the neck attaches the card.
        // Dropping it once detached avoids a stray black capsule if the system island changes.
        guard !reduceMotion, heightFraction < 0.97 else { return path }
        // This capsule is occluded by the system island, including at both endpoints.
        path.addPath(NotchSurfacePath.make(in: source, radius: min(source.width, source.height) / 2))
        let width = neckWidth(heightFraction: heightFraction, reduceMotion: false)
        guard width > 0.01, lower.maxY < source.minY else { return path }
        let x = source.midX
        let top = source.minY + 0.5, bottom = lower.maxY - 0.5
        let mid = (top + bottom) / 2
        let shoulder = min(max(source.width / 2 - source.height / 2, source.width * 0.15), width * 0.9)
        let waist = width * 0.18
        // Clockwise contour, matching the capsules' winding: concave sides
        // tighten to zero, then disappear. Dismissal traverses the same geometry.
        path.move(to: CGPoint(x: x - shoulder, y: top))
        path.addLine(to: CGPoint(x: x + shoulder, y: top))
        path.addCurve(to: CGPoint(x: x + waist, y: mid),
                      control1: CGPoint(x: x + waist, y: top), control2: CGPoint(x: x + waist, y: top))
        path.addCurve(to: CGPoint(x: x + shoulder, y: bottom),
                      control1: CGPoint(x: x + waist, y: bottom), control2: CGPoint(x: x + waist, y: bottom))
        path.addLine(to: CGPoint(x: x - shoulder, y: bottom))
        path.addCurve(to: CGPoint(x: x - waist, y: mid),
                      control1: CGPoint(x: x - waist, y: bottom), control2: CGPoint(x: x - waist, y: bottom))
        path.addCurve(to: CGPoint(x: x - shoulder, y: top),
                      control1: CGPoint(x: x - waist, y: top), control2: CGPoint(x: x - waist, y: top))
        path.closeSubpath()
        return path
    }
}
