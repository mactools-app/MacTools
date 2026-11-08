import Dispatch

enum QuitProtectionEventClock {
    static var now: Duration { .nanoseconds(DispatchTime.now().uptimeNanoseconds) }

    /// Keep Quartz event times and deadlines on the same uptime clock.
    static func instant(
        for timestamp: UInt64,
        sampledUptime: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> Duration? {
        guard timestamp > 0, timestamp <= sampledUptime else { return nil }
        return .nanoseconds(timestamp)
    }

    static func sleep(until deadline: Duration) async throws {
        try await Task.sleep(for: max(.zero, deadline - now), clock: .suspending)
    }
}

struct QuitProtectionGesture<Target: Equatable> {
    enum Intent {
        case hold(Target, duration: Duration)
        case doublePress(Target, interval: Duration)
        case extraModifier(Target, confirmed: Bool)
    }

    struct Hold: Equatable {
        let generation: UInt64
        let target: Target
        let deadline: Duration
        let keyCode: UInt16
    }

    enum PressResult: Equatable {
        case passThrough
        case suppress
        case startedHold(Hold)
        case startedDoublePress
        case needsExtraModifier
        case confirmed(Target)
    }

    private enum Pending {
        case hold(Hold)
        case firstPress(Target, keyCode: UInt16, interval: Duration)
        case secondPress(Target, keyCode: UInt16, deadline: Duration)
    }

    private var generation: UInt64 = 0
    private var claimedKeys: Set<UInt16> = []
    private var pending: Pending?
    private(set) var usesVoiceOverTiming = false

    var hasPendingConfirmation: Bool { pending != nil }
    var hasClaimedKeys: Bool { !claimedKeys.isEmpty }
    var hasPendingDoublePress: Bool {
        switch pending {
        case .firstPress, .secondPress: true
        case .hold, nil: false
        }
    }

    /// Returns whether a pending attempt was cancelled and its cue must close.
    mutating func updateVoiceOverTiming(_ enabled: Bool) -> Bool {
        guard enabled != usesVoiceOverTiming else { return false }
        usesVoiceOverTiming = enabled
        guard hasPendingDoublePress else { return false }
        cancel()
        return true
    }

    /// The paused tap may have missed a release during an interruption.
    mutating func discardReleasedClaims(isKeyDown: (UInt16) -> Bool) {
        claimedKeys = claimedKeys.filter(isKeyDown)
    }

    var doublePressDeadline: Duration? {
        guard case let .secondPress(_, _, deadline) = pending else { return nil }
        return deadline
    }

    var pendingTarget: Target? {
        switch pending {
        case let .hold(hold): hold.target
        case let .firstPress(target, _, _), let .secondPress(target, _, _): target
        case nil: nil
        }
    }

    var pendingHold: Hold? {
        guard case let .hold(hold) = pending else { return nil }
        return hold
    }

    mutating func keyDown(
        keyCode: UInt16, isRepeat: Bool, intent: Intent?, at now: Duration
    ) -> PressResult {
        if isRepeat { return claimedKeys.contains(keyCode) ? .suppress : .passThrough }
        // A new physical down proves that we missed the release of this key.
        if claimedKeys.remove(keyCode) != nil { cancel() }
        guard let intent else {
            cancelDoublePress()
            return .passThrough
        }

        claimedKeys.insert(keyCode)
        switch intent {
        case let .hold(target, duration):
            generation += 1
            let hold = Hold(generation: generation, target: target, deadline: now + duration, keyCode: keyCode)
            pending = .hold(hold)
            return .startedHold(hold)
        case let .doublePress(target, interval):
            if case let .secondPress(previousTarget, previousKey, deadline) = pending,
               previousTarget == target, previousKey == keyCode, now <= deadline {
                cancel()
                return .confirmed(target)
            }
            pending = .firstPress(target, keyCode: keyCode, interval: interval)
            return .startedDoublePress
        case let .extraModifier(target, confirmed):
            cancel()
            return confirmed ? .confirmed(target) : .needsExtraModifier
        }
    }

    mutating func expireDoublePress(at now: Duration) -> Bool {
        guard case let .secondPress(_, _, deadline) = pending, now > deadline else { return false }
        cancel()
        return true
    }

    mutating func keyUp(keyCode: UInt16, at now: Duration) -> Bool {
        guard claimedKeys.remove(keyCode) != nil else { return false }
        switch pending {
        case let .hold(hold) where keyCode == hold.keyCode:
            cancel()
        case let .firstPress(target, pendingKey, interval) where keyCode == pendingKey:
            pending = .secondPress(target, keyCode: pendingKey, deadline: now + interval)
        default:
            break
        }
        return true
    }

    mutating func cancelDoublePress() {
        switch pending {
        case .firstPress, .secondPress: cancel()
        case .hold, nil: break
        }
    }

    /// A cancelled gesture still owns the releases of the key-downs it suppressed.
    mutating func cancel() {
        pending = nil
    }

    /// Recovering taps retain ownership of swallowed keys until release or a fresh down.
    mutating func resetObservation(preservingClaimedKeys: Bool = false) {
        if !preservingClaimedKeys { claimedKeys.removeAll() }
        cancel()
    }

    mutating func confirmHold(
        generation: UInt64, at now: Duration, target: Target?, chordStillHeld: Bool
    ) -> Target? {
        guard let hold = pendingHold, hold.generation == generation, now >= hold.deadline else { return nil }
        cancel()
        guard chordStillHeld, target == hold.target else { return nil }
        return hold.target
    }
}
