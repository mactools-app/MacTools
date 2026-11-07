import Foundation

@main
enum QuitProtectionGestureTests {
    private typealias Gesture = QuitProtectionGesture<Int>
    private static let q: UInt16 = 12
    private static let w: UInt16 = 13
    private static let target = 42
    private static let otherTarget = 84
    private static let start = ContinuousClock.now
    private static let duration: Duration = .milliseconds(800)

    static func main() {
        appScopesKeepTheirOwnLists()
        earlyReleaseAndCancelDrainOnlyTheClaimedKey()
        validHoldConfirmsExactlyOnce()
        lostTargetOrKeyStateDiscardsTheAttempt()
        missedReleaseAndStaleDeadlineCannotAffectANewHold()
        doublePressRequiresTwoFreshPressesAfterRelease()
        doublePressCancelsOnInterveningInputOrTargetChange()
        extraModifierRequiresItsOwnFreshPress()
        unverifiedModifierLeavesBothShortcutsNative()
        earlyReleaseCannotBeMadeLateByCallbackDelay()
        chromeQuitRequiresTheExactEnabledBinding()
        print("Passed 11 Quit Protection behavior checks.")
    }

    private static func chromeQuitRequiresTheExactEnabledBinding() {
        precondition(QuitProtectionChromeQuit.isQuitBinding(identifier: "terminate:", character: "Q", modifiers: 0, isEnabled: true))
        precondition(!QuitProtectionChromeQuit.isQuitBinding(identifier: "_logOutRequested:", character: "Q", modifiers: 0, isEnabled: true))
        precondition(!QuitProtectionChromeQuit.isQuitBinding(identifier: "_lockScreenRequested:", character: "Q", modifiers: 0, isEnabled: true))
        precondition(!QuitProtectionChromeQuit.isQuitBinding(identifier: "terminate:", character: "Q", modifiers: 1, isEnabled: true))
        precondition(!QuitProtectionChromeQuit.isQuitBinding(identifier: "terminate:", character: "X", modifiers: 0, isEnabled: true))
        precondition(!QuitProtectionChromeQuit.isQuitBinding(identifier: "terminate:", character: "Q", modifiers: 0, isEnabled: false))
    }

    private static func appScopesKeepTheirOwnLists() {
        var rule = QuitProtectionRule()
        rule.selectedApps = ["example.first"]
        rule.excludedApps = ["example.second"]
        precondition(!rule.includes(bundleIdentifier: "example.first"))

        rule.isEnabled = true
        precondition(rule.includes(bundleIdentifier: "example.first"))
        precondition(!rule.includes(bundleIdentifier: "example.second"))

        rule.scope = .all
        precondition(rule.includes(bundleIdentifier: "example.second"))
        precondition(!rule.includes(bundleIdentifier: nil))

        rule.scope = .allExcept
        precondition(rule.includes(bundleIdentifier: "example.first"))
        precondition(!rule.includes(bundleIdentifier: "example.second"))

        rule.scope = .selected
        precondition(rule.includes(bundleIdentifier: "example.first"))
        let data = try! JSONEncoder().encode(rule)
        let decoded = try! JSONDecoder().decode(QuitProtectionRule.self, from: data)
        precondition(decoded == rule)
    }

    private static func earlyReleaseAndCancelDrainOnlyTheClaimedKey() {
        var hold = Gesture()
        let first = begin(&hold)
        precondition(!hold.keyUp(keyCode: w, at: start))
        precondition(hold.keyUp(keyCode: q, at: start))
        precondition(finish(&hold, first) == nil)

        let second = begin(&hold)
        hold.cancel()
        precondition(finish(&hold, second) == nil)
        precondition(hold.keyDown(keyCode: q, isRepeat: true, intent: nil, at: start) == .suppress)
        precondition(hold.keyUp(keyCode: q, at: start))
    }

    private static func validHoldConfirmsExactlyOnce() {
        var hold = Gesture()
        let attempt = begin(&hold)
        precondition(hold.confirmHold(generation: attempt.generation, at: start, target: target, chordStillHeld: true) == nil)
        precondition(finish(&hold, attempt) == target)
        precondition(finish(&hold, attempt) == nil)
        precondition(hold.keyUp(keyCode: q, at: attempt.deadline))
    }

    private static func lostTargetOrKeyStateDiscardsTheAttempt() {
        var hold = Gesture()
        let moved = begin(&hold)
        precondition(finish(&hold, moved, target: otherTarget) == nil)
        precondition(finish(&hold, moved) == nil)
        precondition(hold.keyUp(keyCode: q, at: moved.deadline))

        let released = begin(&hold)
        precondition(finish(&hold, released, chordStillHeld: false) == nil)
        precondition(finish(&hold, released) == nil)
    }

    private static func missedReleaseAndStaleDeadlineCannotAffectANewHold() {
        var hold = Gesture()
        let first = begin(&hold)
        hold.resetObservation()
        precondition(hold.keyDown(keyCode: q, isRepeat: true, intent: .hold(target, duration: duration), at: start) == .passThrough)
        precondition(hold.keyDown(keyCode: q, isRepeat: false, intent: nil, at: start) == .passThrough)
        let second = begin(&hold)
        precondition(finish(&hold, first) == nil)
        precondition(finish(&hold, second) == target)
    }

    private static func doublePressRequiresTwoFreshPressesAfterRelease() {
        var gesture = Gesture()
        let intent = Gesture.Intent.doublePress(target, interval: .milliseconds(600))
        precondition(gesture.keyDown(keyCode: q, isRepeat: false, intent: intent, at: start) == .startedDoublePress)
        precondition(gesture.keyDown(keyCode: q, isRepeat: true, intent: intent, at: start) == .suppress)
        let release = start + .seconds(1)
        precondition(gesture.keyUp(keyCode: q, at: release))
        precondition(gesture.keyDown(keyCode: q, isRepeat: false, intent: intent, at: release + .milliseconds(599)) == .confirmed(target))
        precondition(gesture.keyUp(keyCode: q, at: release + .milliseconds(600)))

        let nextPress = release + .seconds(2)
        precondition(gesture.keyDown(keyCode: q, isRepeat: false, intent: intent, at: nextPress) == .startedDoublePress)
        precondition(gesture.keyUp(keyCode: q, at: nextPress))
        precondition(gesture.keyDown(keyCode: q, isRepeat: false, intent: intent, at: nextPress + .milliseconds(601)) == .startedDoublePress)
    }

    private static func doublePressCancelsOnInterveningInputOrTargetChange() {
        var gesture = Gesture()
        let intent = Gesture.Intent.doublePress(target, interval: .milliseconds(600))
        precondition(gesture.keyDown(keyCode: q, isRepeat: false, intent: intent, at: start) == .startedDoublePress)
        precondition(gesture.keyUp(keyCode: q, at: start))
        precondition(gesture.keyDown(keyCode: w, isRepeat: false, intent: nil, at: start) == .passThrough)
        precondition(gesture.keyDown(keyCode: q, isRepeat: false, intent: intent, at: start) == .startedDoublePress)
        precondition(gesture.keyUp(keyCode: q, at: start))
        let different = Gesture.Intent.doublePress(otherTarget, interval: .milliseconds(600))
        precondition(gesture.keyDown(keyCode: q, isRepeat: false, intent: different, at: start) == .startedDoublePress)
    }

    private static func extraModifierRequiresItsOwnFreshPress() {
        var gesture = Gesture()
        let plain = Gesture.Intent.extraModifier(target, confirmed: false)
        let modified = Gesture.Intent.extraModifier(target, confirmed: true)
        precondition(gesture.keyDown(keyCode: q, isRepeat: false, intent: nil, at: start) == .passThrough)
        precondition(gesture.keyDown(keyCode: q, isRepeat: false, intent: plain, at: start) == .needsExtraModifier)
        precondition(gesture.keyDown(keyCode: q, isRepeat: true, intent: modified, at: start) == .suppress)
        precondition(gesture.keyUp(keyCode: q, at: start))
        precondition(gesture.keyDown(keyCode: q, isRepeat: false, intent: modified, at: start) == .confirmed(target))
        precondition(gesture.keyDown(keyCode: q, isRepeat: true, intent: modified, at: start) == .suppress)
        precondition(gesture.keyUp(keyCode: q, at: start))
    }

    private static func unverifiedModifierLeavesBothShortcutsNative() {
        var rule = QuitProtectionRule()
        rule.confirmation = .extraModifier(.option)
        precondition(rule.intent(for: target, additionalModifier: nil, verifiedExtraModifier: nil) == nil)
        precondition(rule.intent(for: target, additionalModifier: .option, verifiedExtraModifier: nil) == nil)
        precondition(rule.intent(for: target, additionalModifier: .control, verifiedExtraModifier: .option) == nil)
        guard case .extraModifier(target, confirmed: true) = rule.intent(
            for: target, additionalModifier: .option, verifiedExtraModifier: .option
        ) else { preconditionFailure("Expected a verified confirmation chord") }
    }

    private static func earlyReleaseCannotBeMadeLateByCallbackDelay() {
        var eventClock = QuitProtectionEventClock()
        let down = eventClock.instant(for: 1_000_000_000, receivedAt: start)!
        let up = eventClock.instant(for: 1_300_000_000, receivedAt: start + .seconds(2))!
        var gesture = Gesture()
        guard case let .startedHold(hold) = gesture.keyDown(
            keyCode: q, isRepeat: false, intent: .hold(target, duration: duration), at: down
        ) else { preconditionFailure("Expected a new hold") }
        precondition(gesture.confirmHold(generation: hold.generation, at: up, target: target, chordStillHeld: true) == nil)
        precondition(gesture.keyUp(keyCode: q, at: up))
    }

    private static func begin(_ hold: inout Gesture) -> Gesture.Hold {
        guard case let .startedHold(attempt) = hold.keyDown(
            keyCode: q, isRepeat: false, intent: .hold(target, duration: duration), at: start
        ) else { preconditionFailure("Expected a new hold") }
        return attempt
    }

    private static func finish(
        _ hold: inout Gesture,
        _ attempt: Gesture.Hold,
        target: Int = target,
        chordStillHeld: Bool = true
    ) -> Int? {
        hold.confirmHold(generation: attempt.generation, at: attempt.deadline, target: target, chordStillHeld: chordStillHeld)
    }
}
