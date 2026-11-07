import Carbon.HIToolbox
import CoreGraphics
import XCTest
@testable import QuitProtectionPlugin

final class QuitProtectionInputSafetyTests: XCTestCase {
    func testSpokenDoublePressCueAllowsTimeToRespond() {
        let q = UInt16(kVK_ANSI_Q)
        let pressedAt = ContinuousClock.now
        let releasedAt = pressedAt + .milliseconds(100)
        let target = 42
        var rule = QuitProtectionRule()
        rule.confirmation = .doublePress(.milliseconds(600))

        for (spokenFeedback, delay, expected) in [
            (false, Duration.seconds(2), QuitProtectionGesture<Int>.PressResult.startedDoublePress),
            (true, .seconds(2), .confirmed(target)),
            (true, .milliseconds(5_001), .startedDoublePress)
        ] {
            var gesture = QuitProtectionGesture<Int>()
            let intent = rule.intent(
                for: target, additionalModifier: nil, verifiedExtraModifier: nil,
                needsTimeForSpokenFeedback: spokenFeedback
            )
            XCTAssertEqual(gesture.keyDown(keyCode: q, isRepeat: false, intent: intent, at: pressedAt), .startedDoublePress)
            XCTAssertTrue(gesture.keyUp(keyCode: q, at: releasedAt))
            XCTAssertEqual(
                gesture.keyDown(keyCode: q, isRepeat: false, intent: intent, at: releasedAt + delay),
                expected
            )
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
