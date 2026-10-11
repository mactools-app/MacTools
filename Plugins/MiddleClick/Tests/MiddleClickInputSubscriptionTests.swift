import Foundation
import XCTest
import MacToolsPluginKit
@testable import MiddleClickPlugin

@MainActor
private final class InputTestService: TrackpadInputService {
    var devices: [TrackpadSensorDevice] = []
    var gesturesArePaused = false
    var allowsSubscription = false
    var handlers: [UUID: @Sendable (TrackpadSensorEvent) -> Void] = [:]

    func subscribe(purpose: TrackpadInputPurpose,
                   handler: @escaping @Sendable (TrackpadSensorEvent) -> Void) -> UUID? {
        guard allowsSubscription else { return nil }
        let id = UUID()
        handlers[id] = handler
        return id
    }

    func unsubscribe(_ subscriptionID: UUID) { handlers.removeValue(forKey: subscriptionID) }
    func send() {
        let frame = TrackpadSensorFrame(deviceID: 1, timestamp: 1, contacts: [])
        handlers.values.forEach { $0(.frame(frame)) }
    }
}

private final class InputTestEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    func receive(_ event: TrackpadSensorEvent) {
        if case .frame = event { lock.withLock { frames += 1 } }
    }
    var count: Int { lock.withLock { frames } }
}

@MainActor
private final class InputTestScheduler {
    private var work: [@MainActor @Sendable () -> Void] = []
    func enqueue(_ body: @escaping @MainActor @Sendable () -> Void) { work.append(body) }
    func runPending() {
        let pending = work
        work.removeAll()
        pending.forEach { $0() }
    }
}

@MainActor
final class MiddleClickInputSubscriptionTests: XCTestCase {
    func testRecoversWhenInputBecomesAvailableAndReleasesOnStop() {
        let service = InputTestService()
        let scheduler = InputTestScheduler()
        let events = InputTestEvents()
        let subscription = MiddleClickInputSubscription(scheduleRetry: scheduler.enqueue) {
            events.receive($0)
        }
        subscription.start(service: service)
        scheduler.runPending()
        service.send()
        XCTAssertEqual(events.count, 0)

        service.allowsSubscription = true
        scheduler.runPending()
        subscription.start(service: service)
        service.send()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(service.handlers.count, 1)

        subscription.stop()
        scheduler.runPending()
        service.send()
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(service.handlers.isEmpty)
    }

    func testStopAndServiceReplacementCancelPendingRecovery() {
        let first = InputTestService()
        let second = InputTestService()
        let scheduler = InputTestScheduler()
        let events = InputTestEvents()
        let subscription = MiddleClickInputSubscription(scheduleRetry: scheduler.enqueue) {
            events.receive($0)
        }
        subscription.start(service: first)
        subscription.stop()
        first.allowsSubscription = true
        scheduler.runPending()
        XCTAssertTrue(first.handlers.isEmpty)

        first.allowsSubscription = false
        subscription.start(service: first)
        second.allowsSubscription = true
        subscription.start(service: second)
        first.allowsSubscription = true
        scheduler.runPending()
        first.send()
        second.send()
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(first.handlers.isEmpty)
        subscription.stop()
        XCTAssertTrue(second.handlers.isEmpty)
    }
}
