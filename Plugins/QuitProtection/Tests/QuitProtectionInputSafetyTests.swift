import Carbon.HIToolbox
import CoreGraphics
import XCTest
@testable import QuitProtectionPlugin

final class QuitProtectionInputSafetyTests: XCTestCase {
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
