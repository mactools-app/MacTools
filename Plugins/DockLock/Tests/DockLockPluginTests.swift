import CoreGraphics
import MacToolsPluginKit
import XCTest
@testable import DockLockPlugin

@MainActor
final class DockLockPluginTests: XCTestCase {
    func testCursorAtBottomIsClampedWithoutChangingHorizontalPosition() {
        let location = CGPoint(x: 1_800, y: 1_000)

        let result = DockLockCursorBoundary.clampedQuartzLocation(
            for: location,
            primaryDisplayHeight: 1_000,
            screens: [
                screen(
                    frame: CGRect(x: 0, y: 0, width: 1_440, height: 1_000),
                    bottomDockInset: 80
                ),
                screen(frame: CGRect(x: 1_440, y: 0, width: 1_000, height: 800)),
            ]
        )

        XCTAssertEqual(result, CGPoint(x: 1_800, y: 996))
    }

    func testSingleDisplayIsNeverClamped() {
        let result = DockLockCursorBoundary.clampedQuartzLocation(
            for: CGPoint(x: 400, y: 1_000),
            primaryDisplayHeight: 1_000,
            screens: [
                screen(
                    frame: CGRect(x: 0, y: 0, width: 1_440, height: 1_000),
                    bottomDockInset: 80
                ),
            ]
        )

        XCTAssertNil(result)
    }

    func testCurrentDockDisplayIsNeverClamped() {
        let result = DockLockCursorBoundary.clampedQuartzLocation(
            for: CGPoint(x: 400, y: 1_000),
            primaryDisplayHeight: 1_000,
            screens: [
                screen(
                    frame: CGRect(x: 0, y: 0, width: 1_440, height: 1_000),
                    bottomDockInset: 80
                ),
                screen(frame: CGRect(x: 1_440, y: 0, width: 1_000, height: 800)),
            ]
        )

        XCTAssertNil(result)
    }

    func testSharedEdgeWithDisplayBelowIsNotClamped() {
        let result = DockLockCursorBoundary.clampedQuartzLocation(
            for: CGPoint(x: 1_800, y: 1_000),
            primaryDisplayHeight: 1_000,
            screens: [
                screen(
                    frame: CGRect(x: 0, y: 0, width: 1_440, height: 1_000),
                    bottomDockInset: 80
                ),
                screen(frame: CGRect(x: 1_440, y: 0, width: 1_000, height: 800)),
                screen(frame: CGRect(x: 1_440, y: -800, width: 1_000, height: 800)),
            ]
        )

        XCTAssertNil(result)
    }

    func testUnknownDockDisplayFailsOpen() {
        let result = DockLockCursorBoundary.clampedQuartzLocation(
            for: CGPoint(x: 1_800, y: 1_000),
            primaryDisplayHeight: 1_000,
            screens: [
                screen(frame: CGRect(x: 0, y: 0, width: 1_440, height: 1_000)),
                screen(frame: CGRect(x: 1_440, y: 0, width: 1_000, height: 800)),
            ]
        )

        XCTAssertNil(result)
    }

    func testMissingDockOrientationDefaultsToBottomAndInvalidValuesFailClosed() {
        XCTAssertTrue(DockLockDockOrientation.isBottom(preferenceValue: nil))
        XCTAssertFalse(DockLockDockOrientation.isBottom(preferenceValue: 1))
        XCTAssertFalse(DockLockDockOrientation.isBottom(preferenceValue: "left"))
        XCTAssertTrue(DockLockDockOrientation.isBottom(preferenceValue: "bottom"))
    }

    func testActivationStartsMonitorWhenPermissionIsGranted() {
        let monitor = MockDockLockMonitor()
        let context = makeContext(isEnabled: true)
        let plugin = DockLockPlugin(context: context, monitor: monitor, accessibilityTrusted: { true })

        plugin.activate(context: context)

        XCTAssertEqual(monitor.startCallCount, 1)
        XCTAssertTrue(plugin.rowState.isOn)
        XCTAssertNil(plugin.rowState.errorMessage)
    }

    func testDisablingStopsMonitorAndPersistsState() {
        let monitor = MockDockLockMonitor()
        let context = makeContext(isEnabled: true)
        let plugin = DockLockPlugin(context: context, monitor: monitor, accessibilityTrusted: { true })
        plugin.activate(context: context)

        plugin.handleAction(.setSwitch(false))

        XCTAssertEqual(monitor.stopCallCount, 1)
        XCTAssertFalse(plugin.rowState.isOn)
    }

    func testMissingPermissionDoesNotStartMonitor() {
        let monitor = MockDockLockMonitor()
        let context = makeContext(isEnabled: true)
        let plugin = DockLockPlugin(
            context: context,
            monitor: monitor,
            accessibilityTrusted: { false },
            requestAccessibilityTrust: { _ in false }
        )

        plugin.activate(context: context)

        XCTAssertEqual(monitor.startCallCount, 0)
        XCTAssertNotNil(plugin.rowState.errorMessage)
    }

    func testCanonicalEnableAndDisableActionsUseTheSharedMutationPath() async throws {
        let monitor = MockDockLockMonitor()
        let plugin = DockLockPlugin(
            context: makeContext(),
            monitor: monitor,
            accessibilityTrusted: { true }
        )
        let enable = try XCTUnwrap(plugin.actionCatalogEntries.dropFirst().first?.reference)
        let disable = try XCTUnwrap(plugin.actionCatalogEntries.last?.reference)

        let enableResult = try await plugin.beginAction(
            ActionInvocation(reference: enable, source: .test, mode: .background)
        ).result()
        XCTAssertEqual(enableResult, .succeeded())
        XCTAssertTrue(plugin.rowState.isOn)
        XCTAssertEqual(plugin.actionCatalogEntries.first?.presentationState, .active)

        let disableResult = try await plugin.beginAction(
            ActionInvocation(reference: disable, source: .test, mode: .background)
        ).result()
        XCTAssertEqual(disableResult, .succeeded())
        XCTAssertFalse(plugin.rowState.isOn)
        XCTAssertGreaterThanOrEqual(monitor.stopCallCount, 1)
    }

    private func makeContext(isEnabled: Bool? = nil) -> PluginRuntimeContext {
        let storage = DockLockMemoryStorage()
        if let isEnabled {
            storage.set(isEnabled, forKey: "dock-lock.enabled")
        }
        return PluginRuntimeContext(pluginID: "dock-lock", storage: storage)
    }

    private func screen(
        frame: CGRect,
        bottomDockInset: CGFloat = 0
    ) -> DockLockCursorBoundary.ScreenGeometry {
        DockLockCursorBoundary.ScreenGeometry(
            frame: frame,
            visibleFrame: CGRect(
                x: frame.minX,
                y: frame.minY + bottomDockInset,
                width: frame.width,
                height: frame.height - bottomDockInset
            )
        )
    }
}

@MainActor
private final class MockDockLockMonitor: @preconcurrency DockLockMonitoring {
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0

    func start() -> Bool {
        startCallCount += 1
        return true
    }

    func stop() {
        stopCallCount += 1
    }
}

@MainActor
private final class DockLockMemoryStorage: PluginStorage {
    private var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }

    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {
        guard values[key] == nil, let value = values[legacyKey] else {
            return
        }
        values[key] = value
        values.removeValue(forKey: legacyKey)
    }
}
