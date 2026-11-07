import Carbon.HIToolbox
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

    @MainActor static func main() async {
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
        ordinaryShortcutDoesNotBypassFreshQuit()
        appSwitcherChordDefersUntilCommandIsPressedAgain()
        modifiedTabDoesNotBypassQuit()
        windowSwitcherOwnsQuitBeforeClaimAndBeforeDelivery()
        expiredDoublePressLeavesNothingForEscapeToCancel()
        freshPressAfterMissedReleaseCannotConfirmOldHold()
        keyboardLayoutChangeInvalidatesTheClaimedKey()
        await secureInputCancelsWithoutAnotherKeyEvent()
        chromeLookupDistinguishesAnUnavailableMenu()
        recoveredHoldConsumesRepeatUntilItsReleaseOrFreshDown()
        chromePressGuidanceRequiresDefinitiveFailure()
        print("Passed 22 Quit Protection behavior checks.")
    }

    private static func recoveredHoldConsumesRepeatUntilItsReleaseOrFreshDown() {
        for releaseIsObserved in [true, false] {
            var gesture = Gesture()
            let attempt = begin(&gesture)
            gesture.resetObservation(preservingClaimedKeys: true)
            precondition(gesture.keyDown(keyCode: q, isRepeat: true, intent: nil, at: attempt.deadline) == .suppress)
            precondition(gesture.confirmHold(generation: attempt.generation, at: attempt.deadline,
                                            target: target, chordStillHeld: true) == nil)
            if releaseIsObserved {
                precondition(gesture.keyUp(keyCode: q, at: attempt.deadline))
            } else {
                precondition(gesture.keyDown(keyCode: q, isRepeat: false, intent: nil, at: attempt.deadline) == .passThrough)
            }
            precondition(!gesture.hasClaimedKeys)
            precondition(gesture.keyDown(keyCode: q, isRepeat: true, intent: nil, at: attempt.deadline) == .passThrough)
        }
    }

    private static func chromePressGuidanceRequiresDefinitiveFailure() {
        precondition(QuitProtectionChromeQuit.requiresRecoveryGuidance(afterPress: .invalidUIElement))
        precondition(QuitProtectionChromeQuit.requiresRecoveryGuidance(afterPress: .actionUnsupported))
        precondition(!QuitProtectionChromeQuit.requiresRecoveryGuidance(afterPress: .success))
        precondition(!QuitProtectionChromeQuit.requiresRecoveryGuidance(afterPress: .cannotComplete))
    }

    @MainActor
    private static func secureInputCancelsWithoutAnotherKeyEvent() async {
        var gesture = Gesture()
        let intent = Gesture.Intent.doublePress(target, interval: duration)
        precondition(gesture.keyDown(keyCode: q, isRepeat: false, intent: intent, at: start) == .startedDoublePress)
        precondition(gesture.keyUp(keyCode: q, at: start))
        var samples = 0
        let interrupted = await QuitProtectionInputWatch.wasInterrupted(
            whilePending: { gesture.hasPendingConfirmation },
            secureInputIsEnabled: { samples == 2 },
            waitForSample: { samples += 1; precondition(samples <= 2) }
        )
        precondition(interrupted)
        gesture.resetObservation()
        precondition(gesture.keyDown(keyCode: q, isRepeat: false, intent: intent,
                                     at: start + .milliseconds(100)) == .startedDoublePress)
    }

    private static func keyboardLayoutChangeInvalidatesTheClaimedKey() {
        func layout(_ id: String) -> QuitProtectionKeyboardLayout {
            let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
            guard let results = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
                  let source = results.first,
                  let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
            else { preconditionFailure("Missing built-in layout: \(id)") }
            return .init(inputSourceID: id, layoutSourceID: id,
                         data: Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data,
                         keyboardType: UInt32(kKeyboardANSI))
        }
        let dvorak = layout("com.apple.keylayout.Dvorak")
        let us = layout("com.apple.keylayout.US")
        let dvorakQ = UInt16(kVK_ANSI_X)
        precondition(dvorak.isQuitKey(dvorakQ))
        precondition(us.isQuitKey(q))
        precondition(dvorak != us && !us.isQuitKey(dvorakQ))
    }

    private static func chromeLookupDistinguishesAnUnavailableMenu() {
        guard case .unavailable = QuitProtectionChromeQuit.lookup(in: getpid()) else {
            preconditionFailure("A fixture with no menu must not deliver Quit or replay its shortcut")
        }
    }

    private static func ordinaryShortcutDoesNotBypassFreshQuit() {
        var routing = QuitProtectionInputRouting()
        routing.observeModifiers(commandIsDown: true, beganWithLocalCommandKey: true)
        // The same physical Command press covers both Save and Quit.
        precondition(!routing.observeKeyDown(keyCode: UInt16(kVK_ANSI_S), flags: .maskCommand,
                                             isQuit: false, isLocal: true))
        let eligible = routing.observeKeyDown(keyCode: q, flags: .maskCommand, isQuit: true, isLocal: true)
        var gesture = Gesture()
        let intent: Gesture.Intent? = eligible ? .hold(target, duration: duration) : nil
        guard case .startedHold = gesture.keyDown(keyCode: q, isRepeat: false, intent: intent, at: start) else {
            preconditionFailure("Fresh Quit after Save must be intercepted")
        }
        precondition(gesture.keyUp(keyCode: q, at: start + .milliseconds(50)))
        precondition(!gesture.hasPendingConfirmation)
    }

    private static func appSwitcherChordDefersUntilCommandIsPressedAgain() {
        for flags: CGEventFlags in [.maskCommand, [.maskCommand, .maskShift]] {
            var routing = QuitProtectionInputRouting()
            routing.observeModifiers(commandIsDown: true, beganWithLocalCommandKey: true)
            precondition(!routing.observeKeyDown(keyCode: UInt16(kVK_Tab), flags: flags, isQuit: false, isLocal: true))
            precondition(!routing.observeKeyDown(keyCode: q, flags: .maskCommand, isQuit: true, isLocal: true))
            routing.observeModifiers(commandIsDown: false, beganWithLocalCommandKey: false)
            routing.observeModifiers(commandIsDown: true, beganWithLocalCommandKey: true)
            precondition(routing.observeKeyDown(keyCode: q, flags: .maskCommand, isQuit: true, isLocal: true))
        }
    }

    private static func modifiedTabDoesNotBypassQuit() {
        var routing = QuitProtectionInputRouting()
        routing.observeModifiers(commandIsDown: true, beganWithLocalCommandKey: true)
        precondition(!routing.observeKeyDown(keyCode: UInt16(kVK_Tab), flags: [.maskCommand, .maskControl],
                                             isQuit: false, isLocal: true))
        precondition(routing.observeKeyDown(keyCode: q, flags: .maskCommand, isQuit: true, isLocal: true))
    }

    private static func windowSwitcherOwnsQuitBeforeClaimAndBeforeDelivery() {
        // An activating chooser and ordinary host UI have the same PID.
        func targetsHost(chooserVisible: Bool) -> Bool {
            QuitProtectionInputRouting.matchesDestination(
                Int32(target), frontmostPID: Int32(target), windowSwitcherIsVisible: chooserVisible
            )
        }
        var gesture = Gesture()
        let intent: Gesture.Intent? = targetsHost(chooserVisible: true) ? .hold(target, duration: duration) : nil
        precondition(gesture.keyDown(keyCode: q, isRepeat: false, intent: intent, at: start) == .passThrough)
        precondition(!gesture.keyUp(keyCode: q, at: start))

        precondition(targetsHost(chooserVisible: false))
        let hold = begin(&gesture)
        // Opening the chooser makes the destination ambiguous even without a PID change.
        let destination = targetsHost(chooserVisible: true) ? target : nil
        precondition(gesture.confirmHold(generation: hold.generation, at: hold.deadline,
                                        target: destination, chordStillHeld: true) == nil)
        precondition(gesture.keyUp(keyCode: q, at: hold.deadline))
    }

    private static func expiredDoublePressLeavesNothingForEscapeToCancel() {
        var gesture = Gesture()
        let interval = Duration.milliseconds(600)
        precondition(gesture.keyDown(keyCode: q, isRepeat: false,
                                     intent: .doublePress(target, interval: interval), at: start) == .startedDoublePress)
        precondition(gesture.keyUp(keyCode: q, at: start))
        precondition(!gesture.expireDoublePress(at: start + interval))
        precondition(gesture.expireDoublePress(at: start + interval + .milliseconds(1)))
        precondition(!gesture.hasPendingConfirmation)
    }

    private static func freshPressAfterMissedReleaseCannotConfirmOldHold() {
        var gesture = Gesture()
        let first = begin(&gesture)
        let fresh = first.deadline + .seconds(1)
        guard case let .startedHold(second) = gesture.keyDown(
            keyCode: q, isRepeat: false, intent: .hold(target, duration: duration), at: fresh
        ) else { preconditionFailure("A fresh press should replace the interrupted hold") }
        let release = fresh + .milliseconds(50)
        precondition(gesture.confirmHold(generation: first.generation, at: release,
                                        target: target, chordStillHeld: true) == nil)
        precondition(gesture.confirmHold(generation: second.generation, at: release,
                                        target: target, chordStillHeld: true) == nil)
        precondition(gesture.keyUp(keyCode: q, at: release))
    }

    private static func chromeQuitRequiresTheExactEnabledBinding() {
        precondition(QuitProtectionChromeQuit.binding(character: "Q", modifiers: 0, isEnabled: true) == .standard)
        precondition(QuitProtectionChromeQuit.binding(character: "Q", modifiers: 1, isEnabled: true) == .reassigned)
        precondition(QuitProtectionChromeQuit.binding(character: "X", modifiers: 0, isEnabled: true) == .reassigned)
        precondition(QuitProtectionChromeQuit.binding(character: "", modifiers: nil, isEnabled: true) == .reassigned)
        precondition(QuitProtectionChromeQuit.binding(character: "Q", modifiers: 0, isEnabled: false) == .unavailable)
        precondition(QuitProtectionChromeQuit.binding(character: nil, modifiers: nil, isEnabled: true) == .unavailable)
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
        let down = QuitProtectionEventClock.instant(for: 1_000_000_000, sampledUptime: 1_000_000_000, sampledAt: start)!
        let up = QuitProtectionEventClock.instant(for: 1_300_000_000, sampledUptime: 3_000_000_000, sampledAt: start + .seconds(2))!
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
