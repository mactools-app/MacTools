import XCTest
import MacToolsPluginKit
@testable import MiddleClickPlugin

@MainActor
private final class MiddleClickMemoryStorage: PluginStorage {
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
private final class MockMiddleClickSession: MiddleClickSessionManaging {
    var requiredFingerCount = 3 {
        didSet { assignedFingerCounts.append(requiredFingerCount) }
    }

    private(set) var assignedFingerCounts: [Int] = []
    private(set) var activateCallCount = 0
    private(set) var deactivateCallCount = 0
    private(set) var inputIsPaused = false

    func activate() {
        activateCallCount += 1
    }

    func deactivate() {
        deactivateCallCount += 1
    }

    func setInputPaused(_ isPaused: Bool) { inputIsPaused = isPaused }
}

@MainActor
final class MiddleClickPluginTests: XCTestCase {
    func testThreeFingerTapRecognizesAfterAllContactsRelease() {
        var recognizer = MiddleClickTapRecognizer(fingerCount: 3)

        XCTAssertFalse(recognizer.process(frame(at: 1.00, contacts: [contact(1)])))
        XCTAssertFalse(recognizer.process(frame(
            at: 1.03,
            contacts: [contact(1), contact(2), contact(3)]
        )))
        XCTAssertFalse(recognizer.process(frame(
            at: 1.12,
            contacts: [contact(2), contact(3)]
        )))
        XCTAssertTrue(recognizer.process(frame(at: 1.16, contacts: [])))
    }

    func testTapRejectsMovementAndExcessDuration() {
        var movingRecognizer = MiddleClickTapRecognizer(fingerCount: 3)
        XCTAssertFalse(movingRecognizer.process(frame(
            at: 1.00,
            contacts: [contact(1), contact(2), contact(3)]
        )))
        XCTAssertFalse(movingRecognizer.process(frame(
            at: 1.08,
            contacts: [contact(1, x: 0.20), contact(2), contact(3)]
        )))
        XCTAssertFalse(movingRecognizer.process(frame(at: 1.10, contacts: [])))

        var slowRecognizer = MiddleClickTapRecognizer(fingerCount: 3)
        XCTAssertFalse(slowRecognizer.process(frame(
            at: 2.00,
            contacts: [contact(1), contact(2), contact(3)]
        )))
        XCTAssertFalse(slowRecognizer.process(frame(at: 2.31, contacts: [])))
    }

    func testNativeClickRewriteSuppressesSyntheticClickForSameEpisode() {
        let pipeline = MiddleClickTapPipeline(fingerCount: 3)
        XCTAssertFalse(pipeline.process(frame(
            at: 1.00,
            contacts: [contact(1), contact(2), contact(3)]
        )))

        XCTAssertEqual(
            pipeline.handleNativeMouseEvent(.down(.left)),
            .rewriteAsMiddle
        )
        XCTAssertEqual(
            pipeline.handleNativeMouseEvent(.up(.left)),
            .rewriteAsMiddle
        )
        XCTAssertFalse(pipeline.process(frame(at: 1.10, contacts: [])))
    }

    func testNativeClickPassesThroughWithoutConfiguredTrackpadContacts() {
        let pipeline = MiddleClickTapPipeline(fingerCount: 3)

        XCTAssertEqual(
            pipeline.handleNativeMouseEvent(.down(.left)),
            .passThrough
        )
        XCTAssertEqual(
            pipeline.handleNativeMouseEvent(.up(.left)),
            .passThrough
        )
    }

    func testWeighingDrainsHeldNativeClickBeforeStoppingEventTap() async {
        let buttons: [(MiddleClickNativeButton, MiddleClickNativeButton)] = [(.left, .right), (.right, .left)]
        for (button, otherButton) in buttons {
            let pipeline = MiddleClickTapPipeline(fingerCount: 3)
            var eventTapIsRunning = false
            var didStop = false
            let stopped = expectation(description: "Owned native release drains the paused event tap")
            let session = MiddleClickSession(tapPipeline: pipeline,
                eventTapStart: { eventTapIsRunning = true },
                eventTapStop: {
                    eventTapIsRunning = false
                    if !didStop { didStop = true; stopped.fulfill() }
                }, observesSystemEvents: false)
            let storage = MiddleClickMemoryStorage()
            storage.values["middle-click.enabled"] = true
            let plugin = makePlugin(storage: storage, session: session)
            plugin.activate(context: PluginRuntimeContext(pluginID: "middle-click"))
            XCTAssertFalse(pipeline.process(frame(at: 1, contacts: [contact(1), contact(2), contact(3)])))
            XCTAssertEqual(session.handleNativeMouseEvent(.down(button)), .rewriteAsMiddle)

            plugin.trackpadInputPauseDidChange(true)
            XCTAssertTrue(eventTapIsRunning)
            XCTAssertFalse(pipeline.process(frame(at: 1.1, contacts: [])))
            XCTAssertEqual(session.handleNativeMouseEvent(.down(otherButton)), .passThrough)
            XCTAssertEqual(session.handleNativeMouseEvent(.up(otherButton)), .passThrough)
            if button == .right {
                plugin.handleSettingsAction(.setSelection(controlID: "finger-count", optionID: "4"))
                plugin.trackpadInputPauseDidChange(false)
                plugin.trackpadInputPauseDidChange(true)
            }
            XCTAssertTrue(pipeline.hasPendingNativeUp)
            XCTAssertEqual(session.handleNativeMouseEvent(.up(button)), .rewriteAsMiddle)
            await fulfillment(of: [stopped], timeout: 2)
            XCTAssertFalse(eventTapIsRunning)
            XCTAssertFalse(pipeline.hasPendingNativeUp)

            plugin.trackpadInputPauseDidChange(false)
            XCTAssertTrue(eventTapIsRunning)
            let contacts = (1...plugin.store.requiredFingerCount).map { contact($0) }
            XCTAssertFalse(pipeline.process(frame(at: 2, contacts: contacts)))
            XCTAssertTrue(pipeline.process(frame(at: 2.1, contacts: [])))
            XCTAssertTrue(plugin.store.isEnabled)
            plugin.deactivate(reason: .updating)
        }
    }

    func testActivateRestoresEnabledSessionAndFingerCount() {
        let storage = MiddleClickMemoryStorage()
        storage.values["middle-click.enabled"] = true
        storage.values["middle-click.required-finger-count"] = 5
        let session = MockMiddleClickSession()
        let plugin = makePlugin(storage: storage, session: session)

        plugin.activate(context: PluginRuntimeContext(pluginID: "middle-click"))

        XCTAssertEqual(session.activateCallCount, 1)
        XCTAssertEqual(session.requiredFingerCount, 5)
        XCTAssertTrue(plugin.store.isEnabled)
    }

    func testWeighingPausesAndRestoresWithoutChangingEnabledPreference() {
        let storage = MiddleClickMemoryStorage()
        storage.values["middle-click.enabled"] = true
        let session = MockMiddleClickSession()
        let plugin = makePlugin(storage: storage, session: session)
        plugin.activate(context: PluginRuntimeContext(pluginID: "middle-click"))
        plugin.trackpadInputPauseDidChange(true)
        XCTAssertTrue(session.inputIsPaused)
        XCTAssertTrue(plugin.store.isEnabled)
        plugin.refresh()
        XCTAssertEqual(session.activateCallCount, 1)
        plugin.trackpadInputPauseDidChange(false)
        XCTAssertFalse(session.inputIsPaused)
        XCTAssertEqual(storage.values["middle-click.enabled"] as? Bool, true)
    }

    func testUpdateDeactivationStopsSessionWithoutClearingEnabledPreference() {
        let storage = MiddleClickMemoryStorage()
        storage.values["middle-click.enabled"] = true
        let session = MockMiddleClickSession()
        let plugin = makePlugin(storage: storage, session: session)
        plugin.activate(context: PluginRuntimeContext(pluginID: "middle-click"))

        plugin.deactivate(reason: .updating)

        XCTAssertEqual(session.deactivateCallCount, 1)
        XCTAssertTrue(plugin.store.isEnabled)
        XCTAssertEqual(storage.values["middle-click.enabled"] as? Bool, true)

        plugin.activate(context: PluginRuntimeContext(pluginID: "middle-click"))
        XCTAssertEqual(session.activateCallCount, 2)
    }

    func testCanonicalActionTogglesStateAndPublishesPresentation() async throws {
        let storage = MiddleClickMemoryStorage()
        let session = MockMiddleClickSession()
        let plugin = makePlugin(storage: storage, session: session)
        let definition = try XCTUnwrap(plugin.actionDefinitions.first)
        let reference = ActionReference(key: definition.key)

        XCTAssertEqual(definition.key.actionID, "toggle")
        XCTAssertEqual(definition.externalInvocationPolicy, .unavailable)
        XCTAssertEqual(plugin.actionCatalogEntries.first?.title, "开启模拟鼠标中键")
        XCTAssertEqual(plugin.actionCatalogEntries.first?.presentationState, .inactive)

        let enable = try plugin.beginAction(ActionInvocation(
            reference: reference,
            source: .actionGrid,
            mode: .foreground
        ))
        let enableResult = await enable.result()
        XCTAssertEqual(enableResult, .succeeded())
        XCTAssertTrue(plugin.store.isEnabled)
        XCTAssertEqual(plugin.actionCatalogEntries.first?.title, "关闭模拟鼠标中键")
        XCTAssertEqual(plugin.actionCatalogEntries.first?.presentationState, .active)

        let disable = try plugin.beginAction(ActionInvocation(
            reference: reference,
            source: .unifiedSearch,
            mode: .foreground
        ))
        let disableResult = await disable.result()
        XCTAssertEqual(disableResult, .succeeded())
        XCTAssertFalse(plugin.store.isEnabled)
        XCTAssertEqual(session.activateCallCount, 1)
        XCTAssertEqual(session.deactivateCallCount, 1)
    }

    func testCanonicalActionRequiresAccessibilityBeforeEnabling() throws {
        let plugin = makePlugin(
            accessibilityTrusted: false,
            requestAccessibilityTrust: false
        )
        let reference = ActionReference(key: try XCTUnwrap(plugin.actionDefinitions.first).key)

        XCTAssertFalse(plugin.actionAvailability(for: reference).isAvailable)
        XCTAssertEqual(
            plugin.permissionRequirementIDs(for: reference.key),
            ["accessibility"]
        )
    }

    func testTrackpadGestureClaimPausesAndRestoresEnabledSession() {
        let storage = MiddleClickMemoryStorage()
        let session = MockMiddleClickSession()
        let plugin = makePlugin(storage: storage, session: session)
        plugin.handleSettingsAction(.setBoolean(controlID: "enabled", value: true))

        plugin.inputGestureConflictsDidChange([
            PluginInputGestureConflict(
                claim: PluginInputGestureClaim(id: "trackpad.tap.3", title: "Three-Finger Tap"),
                ownerPluginID: "trackpad-gestures",
                ownerPluginTitle: "Trackpad Gestures"
            ),
        ])

        XCTAssertTrue(plugin.store.isEnabled)
        XCTAssertEqual(session.deactivateCallCount, 1)
        XCTAssertNotNil(settingsRows(for: plugin).first?.error)
        XCTAssertEqual(plugin.actionCatalogEntries.first?.presentationState, .inactive)

        plugin.inputGestureConflictsDidChange([])

        XCTAssertEqual(session.activateCallCount, 2)
        XCTAssertNil(settingsRows(for: plugin).first?.error)
    }

    func testDeniedPermissionKeepsFeatureOffAndRequestsGuidance() {
        let storage = MiddleClickMemoryStorage()
        let session = MockMiddleClickSession()
        let plugin = makePlugin(
            storage: storage,
            session: session,
            accessibilityTrusted: false,
            requestAccessibilityTrust: false
        )
        var requestedPermissionID: String?
        plugin.requestPermissionGuidance = { requestedPermissionID = $0 }

        plugin.handleSettingsAction(.setBoolean(controlID: "enabled", value: true))

        XCTAssertEqual(session.activateCallCount, 0)
        XCTAssertNil(storage.values["middle-click.enabled"])
        XCTAssertEqual(requestedPermissionID, "accessibility")
        XCTAssertFalse(plugin.store.isEnabled)
        XCTAssertNotNil(settingsRows(for: plugin).first?.error)
    }

    func testFingerCountSettingUpdatesStorageAndRunningSession() {
        let storage = MiddleClickMemoryStorage()
        let session = MockMiddleClickSession()
        let plugin = makePlugin(storage: storage, session: session)
        plugin.handleSettingsAction(.setBoolean(controlID: "enabled", value: true))

        plugin.handleSettingsAction(.setSelection(controlID: "finger-count", optionID: "4"))

        XCTAssertEqual(plugin.store.requiredFingerCount, 4)
        XCTAssertEqual(storage.values["middle-click.required-finger-count"] as? Int, 4)
        XCTAssertEqual(session.requiredFingerCount, 4)
    }

    func testPermissionRevocationStopsSessionAndTurnsFeatureOff() {
        let storage = MiddleClickMemoryStorage()
        let session = MockMiddleClickSession()
        var isTrusted = true
        let plugin = makePlugin(
            storage: storage,
            session: session,
            accessibilityTrustedProvider: { isTrusted }
        )
        plugin.handleSettingsAction(.setBoolean(controlID: "enabled", value: true))

        isTrusted = false
        plugin.refreshAccessibilityPermission()

        XCTAssertEqual(session.deactivateCallCount, 1)
        XCTAssertEqual(storage.values["middle-click.enabled"] as? Bool, false)
        XCTAssertFalse(plugin.store.isEnabled)
        XCTAssertFalse(plugin.permissionState(for: "accessibility").isGranted)
    }

    private func makePlugin(
        storage: MiddleClickMemoryStorage? = nil,
        session: (any MiddleClickSessionManaging)? = nil,
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        accessibilityTrusted: Bool = true,
        requestAccessibilityTrust: Bool = true,
        accessibilityTrustedProvider: (() -> Bool)? = nil
    ) -> MiddleClickPlugin {
        let storage = storage ?? MiddleClickMemoryStorage()
        let session = session ?? MockMiddleClickSession()
        return MiddleClickPlugin(
            context: PluginRuntimeContext(pluginID: "middle-click", storage: storage),
            localization: localization,
            makeSession: { session },
            accessibilityTrusted: {
                accessibilityTrustedProvider?() ?? accessibilityTrusted
            },
            requestAccessibilityTrust: { _ in requestAccessibilityTrust }
        )
    }

    private func settingsRows(for plugin: MiddleClickPlugin) -> [PluginSettingsRow] {
        guard case let .form(sections) = plugin.settingsPage?.body,
              case let .rows(rows) = sections.first?.content
        else {
            XCTFail("Expected declarative settings rows")
            return []
        }
        return rows
    }

    private func contact(
        _ identifier: Int,
        x: Double? = nil,
        y: Double = 0.50
    ) -> MiddleClickContactSnapshot {
        MiddleClickContactSnapshot(
            identifier: identifier,
            x: x ?? (0.30 + Double(identifier) * 0.10),
            y: y
        )
    }

    private func frame(
        deviceID: UInt64 = 1,
        at timestamp: TimeInterval,
        contacts: [MiddleClickContactSnapshot]
    ) -> MiddleClickContactFrame {
        MiddleClickContactFrame(
            deviceID: deviceID,
            timestamp: timestamp,
            contacts: contacts
        )
    }
}
