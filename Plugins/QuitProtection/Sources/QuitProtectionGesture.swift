struct QuitProtectionEventClock {
    private var anchor: (timestamp: UInt64, instant: ContinuousClock.Instant)?

    /// Use the event's time for confirmation, including when the main run
    /// loop processes an early release after the hold deadline.
    mutating func instant(for timestamp: UInt64, receivedAt: ContinuousClock.Instant) -> ContinuousClock.Instant? {
        guard timestamp > 0 else { return nil }
        if let anchor {
            guard timestamp >= anchor.timestamp,
                  let delta = Int64(exactly: timestamp - anchor.timestamp) else { return nil }
            return anchor.instant + .nanoseconds(delta)
        }
        anchor = (timestamp, receivedAt)
        return receivedAt
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
        let deadline: ContinuousClock.Instant
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
        case secondPress(Target, keyCode: UInt16, deadline: ContinuousClock.Instant)
    }

    private var generation: UInt64 = 0
    private var claimedKeys: Set<UInt16> = []
    private var pending: Pending?

    var hasPendingConfirmation: Bool { pending != nil }
    var hasClaimedKeys: Bool { !claimedKeys.isEmpty }

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
        keyCode: UInt16, isRepeat: Bool, intent: Intent?, at now: ContinuousClock.Instant
    ) -> PressResult {
        if claimedKeys.contains(keyCode) { return .suppress }
        guard !isRepeat else { return .passThrough }
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

    mutating func keyUp(keyCode: UInt16, at now: ContinuousClock.Instant) -> Bool {
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

    /// Call when the input observer may have missed those releases.
    mutating func resetObservation() {
        claimedKeys.removeAll()
        cancel()
    }

    mutating func confirmHold(
        generation: UInt64, at now: ContinuousClock.Instant, target: Target?, chordStillHeld: Bool
    ) -> Target? {
        guard let hold = pendingHold, hold.generation == generation, now >= hold.deadline else { return nil }
        cancel()
        guard chordStillHeld, target == hold.target else { return nil }
        return hold.target
    }
}
