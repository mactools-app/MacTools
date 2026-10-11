import CoreGraphics
import XCTest
@testable import MouseEnhancerPlugin

@MainActor
final class MouseScrollSmootherTests: XCTestCase {
    func testUnavailableSmoothingPreservesWheelReversalAndGain() throws {
        for (pid, canStart) in [(Int64(0), true), (-1, true), (Int64.max, true), (1001, false)] {
            let harness = Harness()
            harness.driver.canStart = canStart
            let event = try harness.event(pixels: 40, target: pid)

            let forwarded = try XCTUnwrap(harness.session.handleScrollEvent(event))

            XCTAssertEqual(forwarded.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -80)
            harness.flush()
            XCTAssertTrue(harness.output.events.isEmpty)
        }
    }

    func testReadySmoothingDeliversAllMotionToOriginalTarget() throws {
        let harness = Harness()
        XCTAssertNil(harness.session.handleScrollEvent(try harness.event(pixels: 40)))
        harness.finishGlide()

        XCTAssertEqual(harness.output.events.reduce(0) { $0 + $1.pixels }, -80)
        XCTAssertTrue(harness.output.events.allSatisfy {
            $0.pid == 1001 && $0.continuous && $0.marker == MouseScrollSmoother.syntheticEventMarker
        })

        // Natural completion must also allow the next wheel tick to start.
        harness.output.clear()
        XCTAssertNil(harness.session.handleScrollEvent(try harness.event(pixels: 10)))
        harness.finishGlide()
        XCTAssertEqual(harness.output.events.reduce(0) { $0 + $1.pixels }, -20)
    }

    func testFailedAndStalledDriversRecoverWithoutReplayingOldInput() throws {
        for stallsAfterStarting in [false, true] {
            let harness = Harness()
            harness.driver.canStart = stallsAfterStarting
            let initial = try harness.event(pixels: 40)
            let result = harness.session.handleScrollEvent(initial)
            let oldCallback = harness.driver.callback
            if stallsAfterStarting {
                XCTAssertNil(result)
                harness.clock.advance(by: 2)
                let forwarded = try XCTUnwrap(harness.session.handleScrollEvent(try harness.event(pixels: 40)))
                XCTAssertEqual(forwarded.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -80)
            } else {
                XCTAssertNotNil(result)
            }

            // During the retry interval input remains ordinary wheel input.
            XCTAssertNotNil(harness.session.handleScrollEvent(try harness.event(pixels: 40)))
            harness.driver.canStart = true
            harness.clock.advance(by: 1)
            XCTAssertNil(harness.session.handleScrollEvent(try harness.event(pixels: 10)))
            oldCallback?()
            harness.finishGlide()

            XCTAssertEqual(harness.output.events.reduce(0) { $0 + $1.pixels }, -20)
        }
    }

    func testResetAndDisableCancelAlreadyQueuedOutput() throws {
        for disables in [false, true] {
            let harness = Harness()
            harness.postQueue.suspend()
            do {
                defer { harness.postQueue.resume() }
                XCTAssertNil(harness.session.handleScrollEvent(try harness.event(pixels: 40)))
                harness.driver.callback?()
                harness.flushFrames()
                if disables {
                    harness.smoother.updateConfiguration(isEnabled: false, duration: 0.3)
                } else {
                    harness.smoother.reset()
                }
            }
            harness.flush()
            XCTAssertTrue(harness.output.events.isEmpty)
        }
    }

    func testTargetChangeDoesNotTransferPendingMotion() throws {
        let harness = Harness()
        XCTAssertNil(harness.session.handleScrollEvent(try harness.event(pixels: 40, target: 1001)))
        XCTAssertNil(harness.session.handleScrollEvent(try harness.event(pixels: 10, target: 1002)))
        harness.finishGlide()

        XCTAssertEqual(harness.output.events.reduce(0) { $0 + $1.pixels }, -20)
        XCTAssertTrue(harness.output.events.allSatisfy { $0.pid == 1002 })
    }
}

@MainActor
private final class Harness {
    let driver = TestFrameDriver()
    let clock = TestClock()
    let output = TestScrollOutput()
    let postQueue = DispatchQueue(label: "mouse-scroll-tests.post")
    let smoother: MouseScrollSmoother
    let session: MouseEnhancerSession

    init() {
        let clock = clock
        let output = output
        smoother = MouseScrollSmoother(
            defaultDuration: 0.3,
            frameDriver: driver,
            postQueue: postQueue,
            clock: { clock.now },
            postEvent: { output.record($0, pid: $1) }
        )
        session = MouseEnhancerSession(configuration: MouseEnhancerConfiguration(
            reverseMouseHorizontal: false, reverseMouseVertical: true,
            reverseTrackpadHorizontal: false, reverseTrackpadVertical: false,
            mouseScrollGain: 2, smoothScrollingEnabled: true, mouseScrollDuration: 0.3
        ), smoother: smoother)
    }

    func event(pixels: Int32, target: Int64 = 1001) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
            wheel1: pixels, wheel2: 0, wheel3: 0
        ))
        event.setIntegerValueField(.eventTargetUnixProcessID, value: target)
        return event
    }

    func flushFrames() {
        // The zero tick is never absorbed; it waits for prior frame work without
        // changing the configuration or emitting any real input.
        guard let idle = CGEvent(source: nil) else { return XCTFail("Cannot create idle event") }
        XCTAssertFalse(smoother.ingest(event: idle, tickY: 0, tickX: 0))
    }

    func flush() {
        flushFrames()
        postQueue.sync {}
    }

    func finishGlide() {
        for _ in 0..<180 {
            guard let callback = driver.callback else { break }
            clock.advance(by: 1.0 / 60.0)
            callback()
            flush()
        }
        XCTAssertNil(driver.callback, "The simulated glide should finish")
    }
}

private final class TestFrameDriver: MouseScrollFrameDriving, @unchecked Sendable {
    private let lock = NSLock()
    private var available = true
    private var handler: (@Sendable () -> Void)?

    var canStart: Bool {
        get { lock.withLock { available } }
        set { lock.withLock { available = newValue } }
    }

    var callback: (@Sendable () -> Void)? { lock.withLock { handler } }

    func start(frame: @escaping @Sendable () -> Void) -> Bool {
        lock.withLock {
            guard available else { return false }
            handler = frame
            return true
        }
    }

    func stop() { lock.withLock { handler = nil } }
    func invalidate() { stop() }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 100
    var now: TimeInterval { lock.withLock { value } }
    func advance(by interval: TimeInterval) { lock.withLock { value += interval } }
}

private final class TestScrollOutput: @unchecked Sendable {
    struct Event {
        let pid: pid_t
        let pixels: Int64
        let continuous: Bool
        let marker: Int64
    }

    private let lock = NSLock()
    private var recorded: [Event] = []
    var events: [Event] { lock.withLock { recorded } }
    func clear() { lock.withLock { recorded = [] } }

    func record(_ event: CGEvent, pid: pid_t) {
        lock.withLock {
            recorded.append(Event(
                pid: pid,
                pixels: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1),
                continuous: event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
                marker: event.getIntegerValueField(.eventSourceUserData)
            ))
        }
    }
}
