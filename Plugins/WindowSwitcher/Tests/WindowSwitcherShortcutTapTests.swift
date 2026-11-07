import AppKit
import Carbon.HIToolbox
import os
import XCTest
import MacToolsPluginKit
@testable import WindowSwitcherPlugin

@MainActor
final class WindowSwitcherShortcutTapTests: XCTestCase {

    func testClaimedShortcutNotifiesBeforeChooserPresentation() throws {
        let tap = WindowSwitcherShortcutTap(accessibilityTrusted: { true })
        tap.configure(allBinding: WindowSwitcherShortcutBindingStore.legacyBinding, currentAppBinding: nil)
        let claims = OSAllocatedUnfairLock(initialState: 0)
        let observer = NotificationCenter.default.addObserver(
            forName: WindowSwitcherShortcutTap.willHandleShortcut, object: nil, queue: nil
        ) { _ in claims.withLock { $0 += 1 } }
        defer { NotificationCenter.default.removeObserver(observer) }

        XCTAssertTrue(tap.handle(type: .keyDown, event: try event(kVK_Tab, flags: .maskControl)) != nil)
        XCTAssertEqual(claims.withLock { $0 }, 0)
        XCTAssertTrue(tap.handle(type: .keyDown, event: try event(kVK_Tab, flags: .maskCommand)) == nil)
        XCTAssertEqual(claims.withLock { $0 }, 1)
    }

    func testStoppedListenerDropsQueuedReleaseEscapeAndRevocation() async throws {
        let tap = WindowSwitcherShortcutTap(accessibilityTrusted: { true })
        tap.configure(allBinding: WindowSwitcherShortcutBindingStore.defaultBinding, currentAppBinding: nil)
        var callbacks = 0
        tap.onShortcutReleased = { callbacks += 1 }; tap.onEscape = { callbacks += 1 }
        _ = tap.handle(type: .keyDown, event: try event(kVK_Tab, flags: .maskAlternate))
        _ = tap.handle(type: .flagsChanged, event: try event(kVK_Option))
        tap.setSessionActive(true)
        _ = tap.handle(type: .keyDown, event: try event(kVK_Escape))
        tap.stop()
        let denied = WindowSwitcherShortcutTap(accessibilityTrusted: { false })
        denied.onAccessibilityRevoked = { callbacks += 1 }
        _ = denied.handle(type: .keyDown, event: try event(kVK_Tab))
        denied.stop()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(callbacks, 0)
    }

    func testQuickReleaseSurvivesSessionSetupInvalidation() async throws {
        let tap = WindowSwitcherShortcutTap(accessibilityTrusted: { true })
        tap.configure(allBinding: WindowSwitcherShortcutBindingStore.defaultBinding, currentAppBinding: nil)
        var phases: [String] = []
        tap.onShortcutPressed = { _, _, _ in
            tap.setSessionActive(false); tap.setSessionActive(true)
            phases.append("press")
        }
        tap.onShortcutReleased = { phases.append("release") }
        _ = tap.handle(type: .keyDown, event: try event(kVK_Tab, flags: .maskAlternate))
        _ = tap.handle(type: .flagsChanged, event: try event(kVK_Option))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(phases, ["press", "release"])
    }

    private func event(_ code: Int, flags: CGEventFlags = []) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true))
        event.flags = flags
        return event
    }

    func testDismissalInvalidatesQueuedShortcutPress() async throws {
        let tap = WindowSwitcherShortcutTap(accessibilityTrusted: { true })
        tap.configure(allBinding: WindowSwitcherShortcutBindingStore.defaultBinding, currentAppBinding: nil)
        tap.setSessionActive(true)
        var presses = 0
        tap.onShortcutPressed = { _, _, _ in presses += 1 }
        XCTAssertNil(tap.handle(type: .keyDown, event: try event(kVK_Tab, flags: .maskAlternate)))
        tap.setSessionActive(false)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(presses, 0)
        XCTAssertNil(tap.handle(type: .keyDown, event: try event(kVK_Tab, flags: .maskAlternate)))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(presses, 1)
    }

    func testCompanionLeavesNativeCommandTabAloneAndDeliversPressReleaseInOrder() async throws {
        let tap = WindowSwitcherShortcutTap(accessibilityTrusted: { true })
        tap.configure(allBinding: WindowSwitcherShortcutBindingStore.defaultBinding,
                      currentAppBinding: WindowSwitcherShortcutBindingStore.currentAppBinding)
        var phases: [String] = []
        tap.onShortcutPressed = { reverse, _, _ in phases.append(reverse ? "reverse" : "press") }
        tap.onShortcutReleased = { phases.append("release") }
        XCTAssertTrue(tap.handle(type: .keyDown, event: try event(kVK_Tab, flags: .maskCommand)) != nil)
        XCTAssertTrue(tap.handle(type: .keyDown, event: try event(kVK_Tab, flags: [.maskAlternate, .maskShift])) == nil)
        XCTAssertTrue(tap.handle(type: .flagsChanged, event: try event(kVK_Option)) != nil)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(phases, ["reverse", "release"])
    }

    func testPendingSessionEscapeWorksAfterModifierReleaseButEditingOwnsEscape() async throws {
        let tap = WindowSwitcherShortcutTap(accessibilityTrusted: { true })
        tap.setSessionActive(true)
        var escapes = 0
        tap.onEscape = { escapes += 1 }
        XCTAssertTrue(tap.handle(type: .keyDown, event: try event(kVK_Escape)) == nil)
        tap.setEditing(true)
        XCTAssertTrue(tap.handle(type: .keyDown, event: try event(kVK_Escape)) != nil)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(escapes, 1)
    }

    func testExplicitShiftBindingWinsOverImplicitReverseInEitherScope() async throws {
        for shiftedCurrentApp in [true, false] {
            let tap = WindowSwitcherShortcutTap(accessibilityTrusted: { true })
            let base = ShortcutBinding(keyCode: UInt16(kVK_Tab), modifiers: [.option])
            let shifted = ShortcutBinding(keyCode: UInt16(kVK_Tab), modifiers: [.option, .shift])
            tap.configure(allBinding: shiftedCurrentApp ? base : shifted, currentAppBinding: shiftedCurrentApp ? shifted : base)
            var scopes: [Bool] = [], reversals: [Bool] = []
            tap.onShortcutPressed = { reverse, _, currentApp in scopes.append(currentApp); reversals.append(reverse) }
            XCTAssertNil(tap.handle(type: .keyDown, event: try event(kVK_Tab, flags: [.maskAlternate, .maskShift])))
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertEqual(scopes, [shiftedCurrentApp])
            XCTAssertEqual(reversals, [false])
        }
    }

    func testRevokedPermissionReportsOnceIncludingDisabledTapEvents() async throws {
        for type in [CGEventType.keyDown, .tapDisabledByTimeout, .tapDisabledByUserInput] {
            let tap = WindowSwitcherShortcutTap(accessibilityTrusted: { false })
            var reports = 0
            tap.onAccessibilityRevoked = { reports += 1 }
            let key = try event(kVK_Tab, flags: .maskAlternate)
            XCTAssertNotNil(tap.handle(type: type, event: key))
            XCTAssertNotNil(tap.handle(type: type, event: key))
            let deadline = ContinuousClock.now + .seconds(1)
            while reports == 0, ContinuousClock.now < deadline { await Task.yield() }
            XCTAssertEqual(reports, 1)
        }
    }

    func testSearchSessionConsumesConfiguredCommandTabButPreservesTextEditing() async throws {
        let tap = WindowSwitcherShortcutTap(accessibilityTrusted: { true })
        tap.configure(allBinding: WindowSwitcherShortcutBindingStore.legacyBinding, currentAppBinding: nil)
        tap.setEditing(true)
        tap.setSessionActive(true)
        var reversals: [Bool] = []
        tap.onShortcutPressed = { reverse, _, _ in reversals.append(reverse) }
        XCTAssertNil(tap.handle(type: .keyDown, event: try event(kVK_Tab, flags: .maskCommand)))
        XCTAssertNil(tap.handle(type: .keyDown, event: try event(kVK_Tab, flags: [.maskCommand, .maskShift])))
        XCTAssertTrue(tap.handle(type: .keyDown, event: try event(kVK_ANSI_C, flags: .maskCommand)) != nil)
        XCTAssertTrue(tap.handle(type: .keyDown, event: try event(kVK_Tab)) != nil)
        XCTAssertTrue(tap.handle(type: .keyDown, event: try event(kVK_Escape)) != nil)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(reversals, [false, true])
    }

    func testSearchConsumesCurrentAppCommandGraveAndReverse() async throws {
        let tap = WindowSwitcherShortcutTap(accessibilityTrusted: { true })
        tap.configure(allBinding: WindowSwitcherShortcutBindingStore.defaultBinding,
                      currentAppBinding: WindowSwitcherShortcutBindingStore.currentAppBinding)
        tap.setEditing(true); tap.setSessionActive(true)
        var events: [Bool] = []
        tap.onShortcutPressed = { reverse, _, currentApp in
            XCTAssertTrue(currentApp); events.append(reverse)
        }
        XCTAssertNil(tap.handle(type: .keyDown, event: try event(kVK_ANSI_Grave, flags: .maskCommand)))
        XCTAssertNil(tap.handle(type: .keyDown, event: try event(kVK_ANSI_Grave, flags: [.maskCommand, .maskShift])))
        XCTAssertTrue(tap.handle(type: .keyDown, event: try event(kVK_ANSI_Grave)) != nil)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(events, [false, true])
    }

    func testDeniedPermissionAndClearedBindingsNeverConsumeKeys() throws {
        let denied = WindowSwitcherShortcutTap(accessibilityTrusted: { false })
        denied.configure(allBinding: WindowSwitcherShortcutBindingStore.defaultBinding, currentAppBinding: nil)
        XCTAssertTrue(denied.handle(type: .keyDown, event: try event(kVK_Tab, flags: .maskAlternate)) != nil)
        let cleared = WindowSwitcherShortcutTap(accessibilityTrusted: { true })
        cleared.configure(allBinding: nil, currentAppBinding: nil)
        XCTAssertTrue(cleared.handle(type: .keyDown, event: try event(kVK_Tab, flags: .maskAlternate)) != nil)
    }
}
