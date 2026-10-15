import CoreGraphics
import Foundation

struct RecordingZoomEvent: Sendable {
    enum Kind: Sendable { case click, move, release, scroll, reset }

    let time: Double
    let kind: Kind
    /// Normalized coordinates with a top-left origin, relative to the recorded area.
    let point: CGPoint?

    init(time: Double, kind: Kind, point: CGPoint? = nil) {
        self.time = time
        self.kind = kind
        self.point = point
    }
}

/// An immutable camera path, independent of capture and export queues.
struct RecordingZoomPlan: Sendable {
    private static let full = CGRect(x: 0, y: 0, width: 1, height: 1)
    private static let zoomIn = 0.35
    private static let zoomOut = 0.45
    private static let idle = 2.0
    private static let focusedSize = 1.0 / 1.6
    private static let smoothingStep = 0.025
    private static let settlingTime = smoothingStep * 4

    private struct Keyframe: Sendable {
        let time: Double
        let end: Double
        let source: CGRect
        let target: CGRect
        let followsCursor: Bool
    }

    private var keyframes: [Keyframe] = []
    private let duration: Double

    var hasZoom: Bool {
        keyframes.contains { $0.source != Self.full || $0.target != Self.full }
    }

    init(events: [RecordingZoomEvent], duration: Double) {
        self.duration = duration.isFinite ? max(0, duration) : 0
        guard self.duration > 0 else { return }

        // Preserve input order for a press/release or reset occurring at the same timestamp.
        let ordered = events.enumerated().filter {
            $0.element.time.isFinite && $0.element.time >= 0 && $0.element.time < self.duration
        }.sorted {
            $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time
        }
        var focus: CGRect?
        var pressed = false
        var idleAt: Double?
        var lastInteraction = 0.0
        var followAfter = 0.0
        var focusReadyAt = 0.0

        for (_, event) in ordered {
            let active = focus != nil && (pressed || event.time < (idleAt ?? .infinity))
            switch event.kind {
            case .click, .scroll:
                guard let point = Self.validPoint(event.point) else { continue }
                // Avoid a zoom pulse with no time to enter and leave near the end of a clip.
                guard active || self.duration - event.time >= Self.zoomIn + Self.zoomOut + Self.settlingTime else { continue }
                let next = Self.focused(around: point)
                let current = plannedCrop(at: event.time)
                if active, let idleAt { removeTransitions(from: idleAt) }
                let far = active && current.width < 0.95 &&
                    max(abs(next.midX - current.midX), abs(next.midY - current.midY)) > 0.3
                if active, next == focus {
                    // Repeated scrolling/clicks refresh dwell without restarting the camera's entry.
                } else if far {
                    transition(to: Self.full, at: event.time, over: Self.zoomOut)
                    transition(to: next, at: event.time + Self.zoomOut, over: Self.zoomIn)
                    followAfter = event.time + Self.zoomOut
                    focusReadyAt = followAfter + Self.zoomIn
                } else {
                    if !active || event.time >= focusReadyAt { focusReadyAt = event.time + Self.zoomIn }
                    transition(to: next, at: event.time, over: focusReadyAt - event.time)
                    followAfter = event.time
                }
                focus = next
                pressed = pressed || event.kind == .click
                lastInteraction = event.time
                idleAt = pressed ? nil : event.time + Self.idle
                if let idleAt { transition(to: Self.full, at: idleAt, over: Self.zoomOut) }

            case .move:
                guard active, event.time >= followAfter, let point = Self.validPoint(event.point),
                      let previous = focus else { continue }
                let tolerance = previous.width * 0.12
                let dx = point.x - previous.midX
                let dy = point.y - previous.midY
                let center = CGPoint(
                    x: previous.midX + Self.outsideTolerance(dx, tolerance),
                    y: previous.midY + Self.outsideTolerance(dy, tolerance))
                let next = Self.focused(around: center)
                guard next != previous else { continue }
                let length = event.time < focusReadyAt ? focusReadyAt - event.time : 0.15
                transition(to: next, at: event.time, over: length, followsCursor: true)
                focus = next
                // Passive motion follows the camera but cannot postpone the deliberate-activity timeout.
                if let idleAt { transition(to: Self.full, at: idleAt, over: Self.zoomOut) }

            case .release:
                guard active, pressed else { continue }
                pressed = false
                lastInteraction = event.time
                idleAt = event.time + Self.idle
                transition(to: Self.full, at: event.time + Self.idle, over: Self.zoomOut)

            case .reset:
                transition(to: Self.full, at: event.time, over: Self.zoomOut)
                focus = nil
                pressed = false
                idleAt = nil
            }
        }

        // Use a quiet tail to finish at overview, without zooming out during a held drag.
        if focus != nil, !pressed, self.duration - lastInteraction >= Self.zoomOut + Self.settlingTime + 0.15 {
            let start = self.duration - Self.zoomOut - Self.settlingTime
            if plannedCrop(at: start) != Self.full {
                transition(to: Self.full, at: start, over: Self.zoomOut)
            }
        }
    }

    func crop(at time: Double) -> CGRect {
        guard time.isFinite, time > 0, !keyframes.isEmpty else { return Self.full }
        let position = min(time, duration) / Self.smoothingStep
        let index = floor(position)
        let u = CGFloat(position - index)
        let u2 = u * u
        let u3 = u2 * u
        // A causal cubic B-spline keeps velocity and acceleration continuous across input events.
        // Its positive weights preserve the capture boundary, with only 50 ms of camera delay.
        let weights: [CGFloat] = [pow(1 - u, 3) / 6, (3 * u3 - 6 * u2 + 4) / 6,
                                 (-3 * u3 + 3 * u2 + 3 * u + 1) / 6, u3 / 6]
        let samples = (0..<4).map { plannedCrop(at: (index - 3 + Double($0)) * Self.smoothingStep) }
        let base = samples[0]
        var x = base.minX
        var y = base.minY
        var size = base.width
        for i in 1..<4 {
            x += (samples[i].minX - base.minX) * weights[i]
            y += (samples[i].minY - base.minY) * weights[i]
            size += (samples[i].width - base.width) * weights[i]
        }
        size = min(1, max(Self.focusedSize, size))
        return CGRect(x: min(1 - size, max(0, x)), y: min(1 - size, max(0, y)), width: size, height: size)
    }

    private func plannedCrop(at time: Double) -> CGRect {
        guard time.isFinite, time > 0, !keyframes.isEmpty else { return Self.full }
        let time = min(time, duration)
        var lower = 0
        var upper = keyframes.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if keyframes[middle].time <= time { lower = middle + 1 }
            else { upper = middle }
        }
        guard lower > 0 else { return Self.full }
        let frame = keyframes[lower - 1]
        guard time < frame.end else { return frame.target }
        let progress = CGFloat(max(0, min(1, (time - frame.time) / (frame.end - frame.time))))
        // Cursor following needs an immediate response; restarting an ease-in at 20 Hz loses the cursor.
        let weight = frame.followsCursor ? progress * (2 - progress) : progress * progress * (3 - 2 * progress)
        return CGRect(
            x: frame.source.minX + (frame.target.minX - frame.source.minX) * weight,
            y: frame.source.minY + (frame.target.minY - frame.source.minY) * weight,
            width: frame.source.width + (frame.target.width - frame.source.width) * weight,
            height: frame.source.height + (frame.target.height - frame.source.height) * weight)
    }

    private mutating func transition(to target: CGRect, at time: Double, over length: Double,
                                     followsCursor: Bool = false) {
        guard time < duration else { return }
        let source = plannedCrop(at: time)
        // Keep the previous transition intact before its interruption, including its original easing.
        removeTransitions(from: time)
        // A stop/reset near the last frame must not compress the normal animation into a flash.
        keyframes.append(Keyframe(time: time, end: time + length,
                                  source: source, target: target, followsCursor: followsCursor))
    }

    private mutating func removeTransitions(from time: Double) {
        while let last = keyframes.last, last.time >= time { keyframes.removeLast() }
    }

    private static func validPoint(_ point: CGPoint?) -> CGPoint? {
        guard let point, point.x.isFinite, point.y.isFinite,
              (0...1).contains(point.x), (0...1).contains(point.y) else { return nil }
        return point
    }

    private static func focused(around point: CGPoint) -> CGRect {
        let size = focusedSize
        return CGRect(x: min(1 - size, max(0, point.x - size / 2)),
                      y: min(1 - size, max(0, point.y - size / 2)), width: size, height: size)
    }

    private static func outsideTolerance(_ distance: CGFloat, _ tolerance: CGFloat) -> CGFloat {
        if distance > tolerance { return distance - tolerance }
        if distance < -tolerance { return distance + tolerance }
        return 0
    }
}
