import Carbon.HIToolbox
import CoreGraphics
import XCTest
@testable import QuitProtectionPlugin

final class QuitProtectionInputSafetyTests: XCTestCase {
    func testVoiceOverDoublePressUsesItsOwnAdjustableInterval() throws {
        let q = UInt16(kVK_ANSI_Q)
        let pressedAt = Duration.seconds(1)
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
        let now = Duration.seconds(1)
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
        let down = try XCTUnwrap(QuitProtectionEventClock.instant(
            for: 1_000_000_000, sampledUptime: 1_200_000_000
        ))
        let released = try XCTUnwrap(QuitProtectionEventClock.instant(
            for: 1_100_000_000, sampledUptime: 1_250_000_000
        ))
        for (offset, expected) in [
            (UInt64(0), QuitProtectionGesture<Int>.PressResult.confirmed(1)),
            (UInt64(1), .startedDoublePress)
        ] {
            var gesture = QuitProtectionGesture<Int>()
            let intent = QuitProtectionGesture<Int>.Intent.doublePress(1, interval: .seconds(3))
            XCTAssertEqual(gesture.keyDown(keyCode: q, isRepeat: false, intent: intent, at: down), .startedDoublePress)
            XCTAssertTrue(gesture.keyUp(keyCode: q, at: released))
            XCTAssertEqual(gesture.doublePressDeadline, .milliseconds(4_100))
            let secondPress = try XCTUnwrap(QuitProtectionEventClock.instant(
                for: 4_100_000_000 + offset, sampledUptime: 4_220_000_000
            ))
            XCTAssertEqual(gesture.keyDown(keyCode: q, isRepeat: false, intent: intent, at: secondPress), expected)
        }
    }

    func testEarlyHoldReleaseCannotConfirmAfterDelayedCallback() throws {
        let q = UInt16(kVK_ANSI_Q)
        var gesture = QuitProtectionGesture<Int>()
        let intent = QuitProtectionGesture<Int>.Intent.hold(1, duration: .milliseconds(800))
        let down = try XCTUnwrap(QuitProtectionEventClock.instant(
            for: 1_000_000_000, sampledUptime: 1_001_000_000
        ))
        guard case let .startedHold(hold) = gesture.keyDown(keyCode: q, isRepeat: false, intent: intent, at: down) else {
            return XCTFail("Expected an armed hold")
        }
        let released = try XCTUnwrap(QuitProtectionEventClock.instant(
            for: 1_799_999_999, sampledUptime: 1_900_000_000
        ))
        XCTAssertNil(gesture.confirmHold(generation: hold.generation, at: released, target: 1, chordStillHeld: true))
        XCTAssertTrue(gesture.keyUp(keyCode: q, at: released))
    }

    @MainActor
    func testAnyDeskBundleIDsStayOutOfQuitProtection() {
        for id in ["com.philandro.anydesk", "com.philandro.anydesk.Frontend", "com.philandro.anydesk-example"] {
            XCTAssertTrue(QuitProtectionSession.forwardingApp(id))
        }
        XCTAssertFalse(QuitProtectionSession.forwardingApp("com.philandro.anydeskexample"))
    }

    @MainActor
    func testMoonlightStreamingClientStaysOutOfQuitProtection() {
        XCTAssertTrue(QuitProtectionSession.forwardingApp("com.moonlight-stream.Moonlight"))
        XCTAssertFalse(QuitProtectionSession.forwardingApp("com.moonlight-stream.MoonlightHelper"))
    }

    func testSuspensionCancelsHoldAndRetainsOnlyKeysStillDownOnResume() {
        let now = Duration.seconds(1)
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
        let pressedAt = Duration.seconds(1)
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
