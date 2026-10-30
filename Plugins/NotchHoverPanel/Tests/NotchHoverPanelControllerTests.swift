import AppKit
import MacToolsPluginKit
import XCTest
@testable import NotchHoverPanelPlugin

@MainActor
private final class NotchHoverMemoryStorage: PluginStorage {
    var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {
        guard legacyKey != key, values[key] == nil, let value = values[legacyKey] else { return }
        values[key] = value
        values.removeValue(forKey: legacyKey)
    }
}

@MainActor
private final class TestState<Value> {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}

@MainActor
final class NotchHoverPanelControllerTests: XCTestCase {
    func testMenuBarIconDefaultsToVisibleWithoutOverridingSavedPreferences() {
        for savedPreference: Bool? in [nil, false, true] {
            let storage = NotchHoverMemoryStorage()
            storage.set(savedPreference, forKey: "notch-hover.show-menu-bar-icon")
            let controller = makeController(storage: storage)
            var requests: [Bool] = []
            controller.requestAppMenuBarIconVisibility = { requests.append($0) }

            controller.refresh()

            XCTAssertTrue(controller.snapshot.isEnabled)
            XCTAssertEqual(controller.snapshot.showsMenuBarIcon, savedPreference ?? true)
            XCTAssertEqual(requests, [savedPreference ?? true])
            XCTAssertEqual(storage.object(forKey: "notch-hover.show-menu-bar-icon") as? Bool, savedPreference)
        }
    }

    func testMenuBarIconPreferenceRequestsHostVisibilityAndPersists() {
        let storage = NotchHoverMemoryStorage()
        let controller = makeController(storage: storage)
        var requests: [Bool] = []
        controller.requestAppMenuBarIconVisibility = { requests.append($0) }

        controller.setShowsMenuBarIcon(false)

        XCTAssertEqual(requests, [false])
        XCTAssertFalse(controller.snapshot.showsMenuBarIcon)
        XCTAssertEqual(storage.object(forKey: "notch-hover.show-menu-bar-icon") as? Bool, false)
        XCTAssertFalse(makeController(storage: storage).snapshot.showsMenuBarIcon)

        controller.setEnabled(false)

        XCTAssertEqual(requests, [false, true], "Disabling the plugin must restore the host icon.")
    }

    func testResetToDefaultsRestoresInitialPreferences() {
        let storage = NotchHoverMemoryStorage()
        let controller = makeController(storage: storage)
        controller.setShowsMenuBarIcon(false)
        controller.setTriggerWidth(NotchHoverGeometry.allowedTriggerWidthRange.upperBound)
        controller.setVerticalTriggerReach(NotchHoverGeometry.allowedVerticalTriggerReachRange.upperBound)
        controller.setShowDelay(0.8)
        controller.setHideDelay(1)

        controller.resetToDefaults()

        let snapshot = controller.snapshot
        XCTAssertTrue(snapshot.isEnabled)
        XCTAssertTrue(snapshot.showsMenuBarIcon)
        XCTAssertEqual(snapshot.triggerWidth, Double(NotchHoverGeometry.defaultTriggerWidth))
        XCTAssertEqual(
            snapshot.verticalTriggerReach,
            Double(NotchHoverGeometry.defaultVerticalTriggerReach)
        )
        XCTAssertEqual(snapshot.showDelay, 0.18)
        XCTAssertEqual(snapshot.hideDelay, 0.28)
        XCTAssertTrue(storage.bool(forKey: "notch-hover.show-menu-bar-icon"))
    }

    func testDisplayRemovalRestoresMenuBarIconVisibility() {
        let screens = TestState([Self.notchScreenSnapshot()])
        let controller = NotchHoverPanelController(
            storage: NotchHoverMemoryStorage(),
            screensProvider: { screens.value },
            mouseLocationProvider: { .zero }
        )
        controller.setShowsMenuBarIcon(false)
        var requests: [Bool] = []
        controller.requestAppMenuBarIconVisibility = { requests.append($0) }

        XCTAssertTrue(controller.snapshot.hasSupportedDisplay)
        controller.refresh()
        XCTAssertEqual(
            requests,
            [false],
            "With a supported display the host icon follows the user's hidden preference."
        )

        screens.value = []
        controller.refresh()

        XCTAssertFalse(controller.snapshot.hasSupportedDisplay)
        XCTAssertEqual(
            requests,
            [false, true],
            "Removing the last supported display must restore the host icon."
        )
    }

    func testRejectedDismissalKeepsOwnershipAndRetriesOnNextHover() {
        let mouse = TestState(NSPoint.zero)
        let controller = NotchHoverPanelController(
            storage: NotchHoverMemoryStorage(),
            screensProvider: { [Self.notchScreenSnapshot()] },
            mouseLocationProvider: { mouse.value }
        )
        controller.setShowDelay(0)
        controller.setHideDelay(0.05)

        var isPanelVisible = false
        var dismissalRequests = 0
        controller.isPresentedMenuBarPanelVisible = { isPanelVisible }
        controller.requestMenuBarPanelPresentation = { _ in
            isPanelVisible = true
            return true
        }
        // Simulates the host rejecting dismissal while the layout is edited.
        controller.requestMenuBarPanelDismissal = { _ in
            dismissalRequests += 1
            return false
        }

        mouse.value = Self.triggerPoint
        controller.handlePointerLocation(mouse.value)
        waitForScheduledWork()

        XCTAssertTrue(
            controller.snapshot.isPanelVisible,
            "Hovering the trigger should take ownership of the panel."
        )

        mouse.value = NSPoint(x: 40, y: 40)
        controller.handlePointerLocation(mouse.value)
        waitForScheduledWork()

        XCTAssertEqual(dismissalRequests, 1)
        XCTAssertTrue(
            controller.snapshot.isPanelVisible,
            "A dismissal rejected by the host must keep plugin ownership."
        )

        // Hovering again must still be able to restore or keep the panel.
        mouse.value = Self.triggerPoint
        controller.handlePointerLocation(mouse.value)
        XCTAssertTrue(controller.snapshot.isPanelVisible)

        mouse.value = NSPoint(x: 40, y: 40)
        controller.handlePointerLocation(mouse.value)
        waitForScheduledWork()

        XCTAssertEqual(
            dismissalRequests,
            2,
            "Ownership should let a later pointer update retry the dismissal."
        )
        XCTAssertTrue(controller.snapshot.isPanelVisible)
    }

    private func makeController(storage: NotchHoverMemoryStorage) -> NotchHoverPanelController {
        NotchHoverPanelController(
            storage: storage,
            screensProvider: { [Self.notchScreenSnapshot()] },
            mouseLocationProvider: { .zero }
        )
    }

    private static let triggerPoint = NSPoint(x: 700, y: 960)

    private func waitForScheduledWork() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    }

    private static func notchScreenSnapshot() -> NotchHoverScreenSnapshot {
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        // 220 pt of usable menu bar on each side of a 180 pt notch.
        let leftArea = CGRect(x: 0, y: frame.maxY - 32, width: 666, height: 32)
        let rightArea = CGRect(x: 846, y: frame.maxY - 32, width: 666, height: 32)
        return NotchHoverScreenSnapshot(
            displayID: 1,
            frame: frame,
            auxiliaryTopLeftArea: leftArea,
            auxiliaryTopRightArea: rightArea,
            isBuiltin: true,
            isMain: true,
            isInMirrorSet: false
        )
    }
}
