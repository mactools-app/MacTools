import Carbon.HIToolbox
import CoreGraphics
import XCTest
@testable import QuitProtectionPlugin

final class QuitProtectionInputSafetyTests: XCTestCase {
    func testVoiceOverDoublePressUsesItsOwnAdjustableInterval() throws {
        let q = UInt16(kVK_ANSI_Q)
        let pressedAt = ContinuousClock.now
        let releasedAt = pressedAt + .milliseconds(100)
        let target = 42
        var rule = QuitProtectionRule()
        rule.confirmation = .doublePress(.milliseconds(600))

        func secondPress(spokenFeedback: Bool, delay: Duration) -> QuitProtectionGesture<Int>.PressResult {
            var gesture = QuitProtectionGesture<Int>()
            let intent = rule.intent(
                for: target, additionalModifier: nil, verifiedExtraModifier: nil,
                needsTimeForSpokenFeedback: spokenFeedback
            )
            XCTAssertEqual(gesture.keyDown(keyCode: q, isRepeat: false, intent: intent, at: pressedAt), .startedDoublePress)
            XCTAssertTrue(gesture.keyUp(keyCode: q, at: releasedAt))
            return gesture.keyDown(keyCode: q, isRepeat: false, intent: intent, at: releasedAt + delay)
        }
        XCTAssertEqual(secondPress(spokenFeedback: true, delay: .milliseconds(2_999)), .confirmed(target))
        XCTAssertEqual(secondPress(spokenFeedback: true, delay: .milliseconds(3_001)), .startedDoublePress)
        XCTAssertEqual(secondPress(spokenFeedback: false, delay: .milliseconds(601)), .startedDoublePress)

        rule.voiceOverDoublePressInterval = .seconds(4)
        rule = try JSONDecoder().decode(QuitProtectionRule.self, from: JSONEncoder().encode(rule))
        XCTAssertEqual(secondPress(spokenFeedback: true, delay: .milliseconds(3_500)), .confirmed(target))
        XCTAssertEqual(secondPress(spokenFeedback: false, delay: .milliseconds(601)), .startedDoublePress)
    }

    func testVoiceOverChangeCancelsPendingDoublePressAndKeepsTheClaimedRelease() {
        let now = ContinuousClock.now
        let q = UInt16(kVK_ANSI_Q)
        for initiallyEnabled in [false, true] {
            var gesture = QuitProtectionGesture<Int>()
            XCTAssertFalse(gesture.updateVoiceOverTiming(initiallyEnabled))
            let intent = QuitProtectionGesture<Int>.Intent.doublePress(1, interval: .seconds(3))
            XCTAssertEqual(gesture.keyDown(keyCode: q, isRepeat: false, intent: intent, at: now), .startedDoublePress)
            XCTAssertTrue(gesture.updateVoiceOverTiming(!initiallyEnabled))
            XCTAssertTrue(gesture.keyUp(keyCode: q, at: now))
            XCTAssertNil(gesture.doublePressDeadline)

            XCTAssertEqual(gesture.keyDown(keyCode: q, isRepeat: false, intent: intent, at: now), .startedDoublePress)
            XCTAssertTrue(gesture.keyUp(keyCode: q, at: now))
            XCTAssertTrue(gesture.updateVoiceOverTiming(initiallyEnabled))
            XCTAssertEqual(
                gesture.keyDown(keyCode: q, isRepeat: false, intent: intent, at: now + .milliseconds(300)),
                .startedDoublePress
            )
        }
    }

    func testDoublePressDeadlineUsesPhysicalReleaseDespiteDelayedCallback() throws {
        let q = UInt16(kVK_ANSI_Q)
        let origin = ContinuousClock.now
        var gesture = QuitProtectionGesture<Int>()
        let down = try XCTUnwrap(QuitProtectionEventClock.instant(
            for: 1_000_000_000, sampledUptime: 1_200_000_000, sampledAt: origin + .milliseconds(200)
        ))
        let released = try XCTUnwrap(QuitProtectionEventClock.instant(
            for: 1_100_000_000, sampledUptime: 1_250_000_000, sampledAt: origin + .milliseconds(250)
        ))
        let intent = QuitProtectionGesture<Int>.Intent.doublePress(1, interval: .milliseconds(600))
        XCTAssertEqual(gesture.keyDown(keyCode: q, isRepeat: false, intent: intent, at: down), .startedDoublePress)
        XCTAssertTrue(gesture.keyUp(keyCode: q, at: released))
        XCTAssertEqual(gesture.doublePressDeadline, origin + .milliseconds(700))
        let late = origin + .milliseconds(750)
        XCTAssertEqual(gesture.keyDown(keyCode: q, isRepeat: false, intent: intent, at: late), .startedDoublePress)
    }

    @MainActor
    func testAnyDeskBundleIDsStayOutOfQuitProtection() {
        for id in ["com.philandro.anydesk", "com.philandro.anydesk.Frontend", "com.philandro.anydesk-example"] {
            XCTAssertTrue(QuitProtectionSession.forwardingApp(id))
        }
        XCTAssertFalse(QuitProtectionSession.forwardingApp("com.philandro.anydeskexample"))
    }

    func testSuspensionCancelsHoldAndRetainsOnlyKeysStillDownOnResume() {
        let now = ContinuousClock.now
        let q = UInt16(kVK_ANSI_Q)
        for heldOnResume in [false, true] {
            var gesture = QuitProtectionGesture<Int>()
            _ = gesture.keyDown(keyCode: q, isRepeat: false, intent: .hold(1, duration: .seconds(1)), at: now)
            gesture.resetObservation(preservingClaimedKeys: true)
            gesture.discardReleasedClaims { $0 == q && heldOnResume }
            XCTAssertNil(gesture.pendingHold)
            XCTAssertEqual(
                gesture.keyDown(keyCode: q, isRepeat: true, intent: nil, at: now + .seconds(2)),
                heldOnResume ? .suppress : .passThrough
            )
            XCTAssertEqual(gesture.keyUp(keyCode: q, at: now + .seconds(2)), heldOnResume)
        }
    }

    func testRemappedCommandTabDoesNotDisarmQuitInEitherStartOrder() {
        for observerStartsLast in [false, true] {
            for remapperConsumesTab in [false, true] {
                var routing = QuitProtectionInputRouting()
                routing.observeModifiers(commandIsDown: true, beganWithLocalCommandKey: true)

                // Both plugins use the session tap. The remapper inserts at
                // the head and a consumed event never reaches later taps.
                let observerRunsFirst = QuitProtectionInputRouting.sessionTapPlacement == .headInsertEventTap
                    && observerStartsLast
                if observerRunsFirst || !remapperConsumesTab {
                    _ = routing.observeKeyDown(
                        keyCode: UInt16(kVK_Tab), flags: .maskCommand, isQuit: false, isLocal: true
                    )
                }

                let canProtect = routing.observeKeyDown(
                    keyCode: UInt16(kVK_ANSI_Q), flags: .maskCommand, isQuit: true, isLocal: true
                )
                XCTAssertEqual(canProtect, remapperConsumesTab, "Observer started last: \(observerStartsLast)")
            }
        }
    }

    func testPauseKeepsHeldQuitClaimAcrossDrainChecks() {
        let q = UInt16(kVK_ANSI_Q)
        let pressedAt = ContinuousClock.now
        for releaseIsObserved in [true, false] {
            var gesture = QuitProtectionGesture<Int>()
            _ = gesture.keyDown(keyCode: q, isRepeat: false, intent: .hold(42, duration: .seconds(1)), at: pressedAt)
            gesture.cancel()

            let heldAt = pressedAt + .seconds(4)
            gesture.discardReleasedClaims { $0 == q }
            XCTAssertNil(gesture.pendingHold)
            XCTAssertEqual(gesture.keyDown(keyCode: q, isRepeat: true, intent: nil, at: heldAt), .suppress)

            if releaseIsObserved {
                XCTAssertTrue(gesture.keyUp(keyCode: q, at: heldAt))
            } else {
                gesture.discardReleasedClaims { _ in false }
            }
            XCTAssertFalse(gesture.hasClaimedKeys)
            XCTAssertEqual(gesture.keyDown(keyCode: q, isRepeat: false, intent: nil, at: heldAt), .passThrough)
        }
    }
}
