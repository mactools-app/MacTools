import Foundation
import MacToolsPluginKit

/// Owns the shared-input subscription, including recovery after listener contention.
@MainActor
final class MiddleClickInputSubscription {
    typealias RetryScheduler = (@escaping @MainActor @Sendable () -> Void) -> Void

    private let handler: @Sendable (TrackpadSensorEvent) -> Void
    private let scheduleRetry: RetryScheduler
    private var service: (any TrackpadInputService)?
    private var subscriptionID: UUID?
    private var generation = UUID()

    init(scheduleRetry: @escaping RetryScheduler = { work in
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }, handler: @escaping @Sendable (TrackpadSensorEvent) -> Void) {
        self.scheduleRetry = scheduleRetry
        self.handler = handler
    }

    isolated deinit {
        if let subscriptionID { service?.unsubscribe(subscriptionID) }
    }

    func start(service: any TrackpadInputService) {
        if let current = self.service, current === service { return }
        stop()
        self.service = service
        subscribe()
    }

    func stop() {
        generation = UUID()
        if let subscriptionID { service?.unsubscribe(subscriptionID) }
        subscriptionID = nil
        service = nil
    }

    private func subscribe() {
        guard let service, subscriptionID == nil else { return }
        subscriptionID = service.subscribe(purpose: .gestures, handler: handler)
        guard subscriptionID == nil else { return }
        let generation = generation
        scheduleRetry { [weak self] in
            guard let self, self.generation == generation else { return }
            self.subscribe()
        }
    }
}
