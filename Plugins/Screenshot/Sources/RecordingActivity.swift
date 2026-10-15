import AppKit
import ScreenCaptureKit

/// Observes the first encoded frame's clock without retaining any captured pixels.
final class RecordingClock: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var firstTime: Double?

    var startTime: Double? { lock.withLock { firstTime } }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              status == SCFrameStatus.complete.rawValue else { return }
        let host = CMClockGetHostTimeClock()
        let time: Double
        if let captureClock = stream.synchronizationClock {
            time = CMSyncConvertTime(sampleBuffer.presentationTimeStamp, from: captureClock, to: host).seconds
        } else if let ticks = attachments.first?[.displayTime] as? UInt64 {
            time = CMClockMakeHostTimeFromSystemUnits(ticks).seconds
        } else {
            return
        }
        guard time.isFinite else { return }
        lock.withLock { if firstTime == nil { firstTime = time } }
    }
}

/// Converts global Quartz points to recording-relative points, independent of Retina scale.
struct RecordingCoordinates {
    let rect: CGRect

    init(displayBounds: CGRect, sourceRect: CGRect) {
        rect = sourceRect.offsetBy(dx: displayBounds.minX, dy: displayBounds.minY)
    }

    func normalize(_ point: CGPoint) -> CGPoint? {
        guard rect.width > 0, rect.height > 0, point.x.isFinite, point.y.isFinite,
              rect.contains(point) else { return nil }
        return CGPoint(x: (point.x - rect.minX) / rect.width,
                       y: (point.y - rect.minY) / rect.height)
    }
}

/// Stores sparse mouse metadata only. It never intercepts input or records keyboard text.
@MainActor
final class RecordingActivity {
    private let coordinates: RecordingCoordinates
    private var monitor: Any?
    private var localMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var events: [RecordingZoomEvent] = []
    private var lastMoveTime = -Double.infinity
    private var lastScrollTime = -Double.infinity
    private var lastPoint: CGPoint?
    private var lastWindow: CGWindowID?
    private var wasInside = false
    private var suppressClickUntil = -Double.infinity

    init(displayBounds: CGRect, sourceRect: CGRect) {
        coordinates = RecordingCoordinates(displayBounds: displayBounds, sourceRect: sourceRect)
    }

    func start() -> Bool {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .rightMouseDown,
            .rightMouseUp, .otherMouseDown, .otherMouseUp, .mouseMoved,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]
        // AppKit delivers both monitors on the main thread.
        monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.receive(event) }
        }
        // MacTools controls are excluded from the video and must not create zoom targets.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.reset(at: event.timestamp) }
            return event
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                let time = CMClockGetTime(CMClockGetHostTimeClock()).seconds
                self?.reset(at: time)
                self?.suppressClickUntil = time + 0.3
                self?.lastWindow = nil
            }
        }
        return monitor != nil
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        monitor = nil
        localMonitor = nil
        activationObserver = nil
    }

    func snapshot(startTime: Double) -> [RecordingZoomEvent] {
        Self.relativeEvents(events, startTime: startTime)
    }

    static func relativeEvents(_ events: [RecordingZoomEvent], startTime: Double) -> [RecordingZoomEvent] {
        guard startTime.isFinite else { return [] }
        return events.compactMap { event in
            let time = event.time - startTime
            guard time.isFinite, time >= 0 else { return nil }
            return RecordingZoomEvent(time: time, kind: event.kind, point: event.point)
        }
    }

    func receive(_ event: NSEvent) {
        guard let cgEvent = event.cgEvent else { return }
        let time = event.timestamp
        guard time.isFinite else { return }
        guard let point = coordinates.normalize(cgEvent.location) else {
            if wasInside { reset(at: time) }
            wasInside = false
            return
        }
        wasInside = true
        let kind: RecordingZoomEvent.Kind
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            receiveClick(at: time, point: point, window: Self.window(for: cgEvent))
            return
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: kind = .release
        case .scrollWheel:
            guard abs(event.scrollingDeltaX) + abs(event.scrollingDeltaY) > 0 else { return }
            // Momentum does not count as another deliberate operation.
            if event.momentumPhase != [] { return }
            guard time - lastScrollTime >= 0.05 else { return }
            lastScrollTime = time
            kind = .scroll
        default:
            guard time - lastMoveTime >= 0.05 else { return }
            if let lastPoint, hypot(point.x - lastPoint.x, point.y - lastPoint.y) < 0.003 { return }
            lastMoveTime = time
            lastPoint = point
            kind = .move
        }
        events.append(RecordingZoomEvent(time: time, kind: kind, point: point))
    }

    func receiveClick(at time: Double, point: CGPoint, window: CGWindowID?) {
        let changedWindow = lastWindow != nil && window != nil && window != lastWindow
        if let window { lastWindow = window }
        guard time >= suppressClickUntil, !changedWindow else { reset(at: time); return }
        events.append(RecordingZoomEvent(time: time, kind: .click, point: point))
    }

    private func reset(at time: Double) {
        guard events.last?.kind != .reset else { return }
        events.append(RecordingZoomEvent(time: time, kind: .reset, point: nil))
    }

    private static func window(for event: CGEvent) -> CGWindowID? {
        let handling = event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent)
        let underPointer = event.getIntegerValueField(.mouseEventWindowUnderMousePointer)
        let eventWindow = CGWindowID(exactly: handling > 0 ? handling : underPointer) ?? 0
        // 事件已带窗口号时只查这一个窗口,不必在每次点击时枚举全部窗口
        let windows = (eventWindow != 0
            ? CGWindowListCopyWindowInfo(.optionIncludingWindow, eventWindow)
            : CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID))
            as? [[String: Any]] ?? []
        return ordinaryWindow(at: event.location, eventWindow: eventWindow, windows: windows)
    }

    static func ordinaryWindow(at point: CGPoint, eventWindow: CGWindowID = 0,
                               windows: [[String: Any]]) -> CGWindowID? {
        // Do not look through menus or popovers to an unrelated window behind them.
        let hit = windows.first { window in
            if eventWindow != 0 {
                return (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value == eventWindow
            }
            guard ((window[kCGWindowAlpha as String] as? Double) ?? 1) > 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            return rect.contains(point)
        }
        guard let hit, (hit[kCGWindowLayer as String] as? Int) == 0 else { return nil }
        return (hit[kCGWindowNumber as String] as? NSNumber)?.uint32Value
    }
}
