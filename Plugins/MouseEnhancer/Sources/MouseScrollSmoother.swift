import AppKit
@preconcurrency import CoreGraphics
import Foundation
import OSLog

/// Pure scroll-glide state: accumulates wheel tick targets and emits
/// frame-rate-independent exponential decay toward them.
struct MouseScrollGlideAccumulator: Equatable, Sendable {
    static let drainEpsilon = 0.5

    private(set) var bufferY = 0.0
    private(set) var bufferX = 0.0
    private(set) var currentY = 0.0
    private(set) var currentX = 0.0
    private var emittedY = 0.0
    private var emittedX = 0.0

    var isDrained: Bool {
        abs(bufferY - currentY) < Self.drainEpsilon && abs(bufferX - currentX) < Self.drainEpsilon
    }

    /// Same-direction ticks extend the glide; a direction flip (or a zero tick on
    /// an axis) restarts that axis from the new target, mirroring Mos semantics.
    mutating func add(tickY: Double, tickX: Double) {
        if tickY == 0 || tickY * bufferY <= 0 {
            bufferY = tickY
            currentY = 0
            emittedY = 0
        } else {
            bufferY += tickY
        }

        if tickX == 0 || tickX * bufferX <= 0 {
            bufferX = tickX
            currentX = 0
            emittedX = 0
        } else {
            bufferX += tickX
        }
    }

    /// Emits the per-frame delta for each axis. The decay fraction is derived
    /// from the measured frame period, so the glide duration is identical on
    /// 60 Hz and high-refresh displays without refresh-rate self-correction.
    mutating func advance(framePeriod: TimeInterval, duration: TimeInterval) -> (y: Double, x: Double) {
        let tau = max(duration / 3, 0.05)
        let alpha = -expm1(-min(max(framePeriod, 0), 1) / tau)

        let frameY = (bufferY - currentY) * alpha
        let frameX = (bufferX - currentX) * alpha
        currentY += frameY
        currentX += frameX

        if abs(bufferY - currentY) < Self.drainEpsilon { currentY = bufferY }
        if abs(bufferX - currentX) < Self.drainEpsilon { currentX = bufferX }
        // Quantize cumulative positions, not individual frame deltas, so
        // subpixel movement carries into later frames instead of being lost.
        let nextY = currentY.rounded()
        let nextX = currentX.rounded()
        let output = (nextY - emittedY, nextX - emittedX)
        emittedY = nextY
        emittedX = nextX
        return output
    }

    mutating func reset() {
        self = MouseScrollGlideAccumulator()
    }
}

/// Holds the posting template captured from the last intercepted wheel event.
/// Stale frames are dropped by generation and TTL, mirroring Mos's dispatch
/// context guards against focus changes and stopped glides.
final class MouseScrollGlideTemplateStore: @unchecked Sendable {
    struct Snapshot: Sendable {
        let event: CGEvent
        let targetProcessID: pid_t
        let isChromiumTarget: Bool
        let pixelsPerLine: Double
        let generation: UInt64
        let createdAt: TimeInterval
    }

    private let lock = NSLock()
    private var template: CGEvent?
    private var targetProcessID: pid_t = 0
    private var isChromiumTarget = false
    private var pixelsPerLine = 10.0
    private var generation: UInt64 = 0
    private var createdAt: TimeInterval = 0
    private var chromiumCache: [pid_t: Bool] = [:]

    private let timeToLive: TimeInterval

    init(timeToLive: TimeInterval = 5) {
        self.timeToLive = timeToLive
    }

    @discardableResult
    func capture(event: CGEvent, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard let pid = pid_t(exactly: event.getIntegerValueField(.eventTargetUnixProcessID)),
              pid > 0, let copy = event.copy() else { return false }
        let isChromium = chromiumTarget(for: pid)
        let sourcePixelsPerLine = CGEventSource(event: event)?.pixelsPerLine ?? 10

        lock.lock()
        defer { lock.unlock() }
        template = copy
        targetProcessID = pid
        isChromiumTarget = isChromium
        pixelsPerLine = sourcePixelsPerLine.isFinite && sourcePixelsPerLine > 0 ? sourcePixelsPerLine : 10
        createdAt = now
        return true
    }

    func makeSnapshot(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let template,
              let clone = template.copy(),
              now - createdAt <= timeToLive,
              targetProcessID != 0 else {
            return nil
        }
        return Snapshot(
            event: clone,
            targetProcessID: targetProcessID,
            isChromiumTarget: isChromiumTarget,
            pixelsPerLine: pixelsPerLine,
            generation: generation,
            createdAt: createdAt
        )
    }

    func isCurrent(_ snapshot: Snapshot, now: TimeInterval) -> Bool {
        lock.withLock {
            snapshot.generation == generation && now - snapshot.createdAt <= timeToLive
        }
    }

    /// Bumps the generation so frames already queued for the previous glide are dropped.
    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        template = nil
        targetProcessID = 0
    }

    private func chromiumTarget(for pid: pid_t) -> Bool {
        guard pid != 0 else { return false }
        lock.lock()
        if let cached = chromiumCache[pid] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        // Mos sends the terminal zero-delta event only to com.google.Chrome;
        // extend the family only if other targets demonstrate the same stuck-scroll.
        let isChromium = NSRunningApplication(processIdentifier: pid)?
            .bundleIdentifier == "com.google.Chrome"

        lock.lock()
        defer { lock.unlock() }
        if chromiumCache.count > 32 {
            chromiumCache.removeAll()
        }
        chromiumCache[pid] = isChromium
        return isChromium
    }
}

/// Re-emits intercepted mouse wheel ticks as a continuous, display-paced scroll
/// stream, modeled on Mos's smooth scrolling engine (GPLv3, same license).
final class MouseScrollSmoother: @unchecked Sendable {
    static let syntheticEventMarker: Int64 = 0x4D61_6354_6F6F_6C53 // "MacToolS"

    private enum Timing {
        static let stalledFrameTimeout: TimeInterval = 0.5
        static let retryDelay: TimeInterval = 0.5
    }

    // The tap synchronously decides whether to swallow an event. Frames and
    // lifecycle changes share this queue, never the display link's callback thread.
    private let queue = DispatchQueue(label: "mactools.mouse-enhancer.smoother", qos: .userInteractive)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let templates = MouseScrollGlideTemplateStore()
    private let frameDriver: any MouseScrollFrameDriving
    private let postQueue: DispatchQueue
    private let clock: @Sendable () -> TimeInterval
    private let postEvent: @Sendable (CGEvent, pid_t) -> Void
    private var accumulator = MouseScrollGlideAccumulator()
    private var isEnabled = false
    private var duration: TimeInterval
    private var isRunning = false
    private var frameGeneration: UInt64 = 0
    private var targetProcessID: Int64 = 0
    private var startedAt: TimeInterval = 0
    private var lastFrameTime: TimeInterval?
    private var retryAfter: TimeInterval = 0
    private var watchdog: DispatchSourceTimer?

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "MouseScrollSmoother"
    )

    init(
        defaultDuration: TimeInterval,
        frameDriver: any MouseScrollFrameDriving = MouseScrollFrameDriver(),
        postQueue: DispatchQueue = DispatchQueue(label: "mactools.mouse-enhancer.smoother.post", qos: .userInteractive),
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        postEvent: @escaping @Sendable (CGEvent, pid_t) -> Void = { $0.postToPid($1) }
    ) {
        duration = defaultDuration
        self.frameDriver = frameDriver
        self.postQueue = postQueue
        self.clock = clock
        self.postEvent = postEvent
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit { withState { cancelGlide() } }

    /// Only swallow input after both its destination and frame driver are ready.
    /// Returning false leaves reversal and tuning to the ordinary event path.
    func ingest(event: CGEvent, tickY: Double, tickX: Double) -> Bool {
        withState {
            guard isEnabled, tickY.isFinite, tickX.isFinite, tickY != 0 || tickX != 0 else { return false }
            let now = clock()
            guard !recoverStalledDriver(now: now), now >= retryAfter else { return false }

            let pid = event.getIntegerValueField(.eventTargetUnixProcessID)
            if isRunning, pid != targetProcessID { cancelGlide() }
            guard templates.capture(event: event, now: now) else {
                cancelGlide()
                return false
            }

            if !isRunning {
                frameGeneration &+= 1
                let generation = frameGeneration
                let frameWork: @Sendable () -> Void = { [weak self] in self?.frame(generation: generation) }
                // Do not retain/release the smoother on the real-time thread:
                // its final release could otherwise stop the link from within its callback.
                guard frameDriver.start(frame: { [queue] in
                    queue.async(execute: frameWork)
                }) else {
                    cancelGlide()
                    retryAfter = now + Timing.retryDelay
                    logger.error("smooth scrolling frame driver failed; passing through wheel events")
                    return false
                }
                isRunning = true
                startedAt = now
                lastFrameTime = nil
                startWatchdog()
            }
            targetProcessID = pid
            accumulator.add(tickY: tickY, tickX: tickX)
            return true
        }
    }

    func updateConfiguration(isEnabled: Bool, duration: TimeInterval) {
        withState {
            self.duration = duration
            guard isEnabled != self.isEnabled else { return }
            self.isEnabled = isEnabled
            cancelGlide()
            retryAfter = 0
        }
    }

    /// Wake, display changes, permission loss, and teardown invalidate all queued
    /// output and recreate the display link before accepting another glide.
    func reset() {
        withState {
            cancelGlide()
            retryAfter = 0
        }
    }

    private func withState<Result>(_ body: () -> Result) -> Result {
        if DispatchQueue.getSpecific(key: queueKey) == true { return body() }
        return queue.sync(execute: body)
    }

    private func cancelGlide() {
        isRunning = false
        frameGeneration &+= 1
        accumulator.reset()
        targetProcessID = 0
        lastFrameTime = nil
        templates.invalidate()
        watchdog?.cancel()
        watchdog = nil
        frameDriver.invalidate()
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            _ = self.recoverStalledDriver(now: self.clock())
        }
        watchdog = timer
        timer.resume()
    }

    @discardableResult
    private func recoverStalledDriver(now: TimeInterval) -> Bool {
        guard isRunning, now - (lastFrameTime ?? startedAt) > Timing.stalledFrameTimeout else { return false }
        cancelGlide()
        retryAfter = now + Timing.retryDelay
        logger.error("smooth scrolling frame driver stalled; passing through wheel events until retry")
        return true
    }

    private func frame(generation: UInt64) {
        guard isRunning, generation == frameGeneration else { return }
        let now = clock()
        let framePeriod = lastFrameTime.map { min(max(now - $0, 0), 1) } ?? (1.0 / 60.0)
        lastFrameTime = now
        let deltas = accumulator.advance(framePeriod: framePeriod, duration: duration)
        let drained = accumulator.isDrained

        if deltas.y != 0 || deltas.x != 0, let snapshot = templates.makeSnapshot(now: now) {
            post(snapshot, deltaY: deltas.y, deltaX: deltas.x)
        }
        if drained {
            // Natural completion preserves queued displacement, unlike reset.
            if let snapshot = templates.makeSnapshot(now: now) {
                post(snapshot, deltaY: 0, deltaX: 0)
            }
            isRunning = false
            accumulator.reset()
            lastFrameTime = nil
            watchdog?.cancel()
            watchdog = nil
            frameDriver.stop()
        }
    }

    private func post(_ snapshot: MouseScrollGlideTemplateStore.Snapshot, deltaY: Double, deltaX: Double) {
        postQueue.async { [templates, clock, postEvent] in
            guard templates.isCurrent(snapshot, now: clock()) else { return }
            snapshot.event.applySmoothScrollDeltas(deltaY: deltaY, deltaX: deltaX, pixelsPerLine: snapshot.pixelsPerLine)
            postEvent(snapshot.event, snapshot.targetProcessID)
        }
    }
}

extension CGEvent {
    /// Matches native pixel-unit scroll events while preserving the captured
    /// event's location, modifiers, and destination. Inputs are whole pixels.
    func applySmoothScrollDeltas(deltaY: Double, deltaX: Double, pixelsPerLine: Double) {
        let fixedY = deltaY / pixelsPerLine
        let fixedX = deltaX / pixelsPerLine
        // Native events truncate line deltas but keep nonzero pixel motion at
        // least one line. Set lines first because CoreGraphics derives other fields.
        let lineY = fixedY == 0 ? 0 : copysign(max(abs(fixedY.rounded(.towardZero)), 1), fixedY)
        let lineX = fixedX == 0 ? 0 : copysign(max(abs(fixedX.rounded(.towardZero)), 1), fixedX)
        setDoubleValueField(.scrollWheelEventDeltaAxis1, value: lineY)
        setDoubleValueField(.scrollWheelEventDeltaAxis2, value: lineX)
        setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: fixedY)
        setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: fixedX)
        setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: deltaY)
        setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: deltaX)
        setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        setIntegerValueField(.eventSourceUserData, value: MouseScrollSmoother.syntheticEventMarker)
    }
}
