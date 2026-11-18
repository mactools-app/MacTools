import CoreGraphics
import os

final class DisplayBrightnessConnectionEvents: Sendable {
    private struct State {
        var isAvailable: Bool
        var generations: [CGDirectDisplayID: UInt64] = [:]
    }

    private let state: OSAllocatedUnfairLock<State>

    init(isAvailable: Bool = true) {
        state = OSAllocatedUnfairLock(initialState: State(isAvailable: isAvailable))
    }

    func generation(for displayID: CGDirectDisplayID) -> UInt64? {
        state.withLock { $0.isAvailable ? $0.generations[displayID, default: 0] : nil }
    }

    func record(_ flags: CGDisplayChangeSummaryFlags, for displayID: CGDirectDisplayID) {
        guard flags.contains(.removeFlag) || flags.contains(.disabledFlag) else { return }
        state.withLock { $0.generations[displayID, default: 0] &+= 1 }
    }

    fileprivate func setAvailable(_ isAvailable: Bool) {
        state.withLock { $0.isAvailable = isAvailable }
    }
}

@MainActor
final class SystemDisplayBrightnessConnectionObserver {
    nonisolated static let events = DisplayBrightnessConnectionEvents(isAvailable: false)
    private static var activeCount = 0
    private var isActive = false

    func start() {
        guard !isActive else { return }
        if Self.activeCount == 0 {
            let result = CGDisplayRegisterReconfigurationCallback(Self.callback, nil)
            guard result == .success else {
                DisplayBrightnessLog.controller.error(
                    "failed to register brightness display observer: \(result.rawValue, privacy: .public)"
                )
                return
            }
            Self.events.setAvailable(true)
        }
        Self.activeCount += 1
        isActive = true
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        Self.activeCount -= 1
        if Self.activeCount == 0 {
            Self.events.setAvailable(false)
            CGDisplayRemoveReconfigurationCallback(Self.callback, nil)
        }
    }

    isolated deinit {
        stop()
    }

    // Use a shared registration without a callback pointer to a plugin instance.
    private nonisolated static let callback: CGDisplayReconfigurationCallBack = { displayID, flags, _ in
        events.record(flags, for: displayID)
    }
}
