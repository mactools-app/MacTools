import AppKit
import Carbon.HIToolbox
import XCTest
import MacToolsPluginKit
import MultitouchSupport
@testable import TrackpadGesturesPlugin

@MainActor
private final class MutableBool {
    var value: Bool

    init(_ value: Bool) {
        self.value = value
    }
}

private final class LockedTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: TimeInterval = 0

    var value: TimeInterval {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}

@MainActor
private final class TrackpadGestureMemoryStorage: PluginStorage {
    var values: [String: Any] = [:]
    var blockedSetKeys: Set<String> = []

    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) {
        guard !blockedSetKeys.contains(key) else { return }
        values[key] = value
    }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {
        guard values[key] == nil, let value = values[legacyKey] else { return }
        values[key] = value
        values.removeValue(forKey: legacyKey)
    }
}

@MainActor
private final class MockMultitouchDeviceSession: MultitouchDeviceSessionManaging,
    MultitouchDeviceTestingSessionManaging {
    var onRecognized: ((
        TrackpadGesture,
        UInt64,
        TimeInterval?,
        TrackpadGestureRecognitionEvidence?
    ) -> Void)?
    var onAvailabilityChange: ((Bool) -> Void)?
    var onTestingSnapshot: ((TrackpadGestureTestSnapshot) -> Void)?
    var onTestingReset: (() -> Void)?
    var testingDeviceDescriptors: [MultitouchDeviceDescriptor] = []
    private(set) var isActive = false
    var deviceCount = 1
    private(set) var activations: [Set<TrackpadGesture>] = []
    private(set) var updates: [Set<TrackpadGesture>] = []
    private(set) var deactivateCount = 0
    private(set) var middleClickGestureUpdates: [Set<TrackpadGesture>] = []
    private(set) var resolvedMiddleClicks: [(TrackpadGesture, UInt64)] = []
    private(set) var nativeClickResolutionUpdates: [[TrackpadGesture: TrackpadNativeClickResolution]] = []
    private(set) var typingProtectionUpdates: [(Bool, TimeInterval)] = []
    private(set) var configurationDeliveryInvalidationCount = 0
    var activationSucceeds = true
    var resolvesMiddleClicks = false
    var acceptsNativeClickResolution = true
    private(set) var testingModeUpdates: [TrackpadGestureTestingMode?] = []
    private(set) var currentTestingMode: TrackpadGestureTestingMode?

    func activate(gestures: Set<TrackpadGesture>) -> Bool {
        activations.append(gestures)
        isActive = activationSucceeds
        return activationSucceeds
    }

    func update(gestures: Set<TrackpadGesture>) {
        updates.append(gestures)
    }

    func invalidatePendingDeliveriesForConfigurationChange() {
        configurationDeliveryInvalidationCount += 1
    }

    func updateMiddleClickGestures(_ gestures: Set<TrackpadGesture>) {
        middleClickGestureUpdates.append(gestures)
    }

    func resolveMiddleClick(for gesture: TrackpadGesture, deviceID: UInt64) -> Bool {
        resolvedMiddleClicks.append((gesture, deviceID))
        return resolvesMiddleClicks
    }

    func updateNativeClickResolutions(
        _ resolutions: [TrackpadGesture: TrackpadNativeClickResolution]
    ) {
        nativeClickResolutionUpdates.append(resolutions)
        middleClickGestureUpdates.append(Set(resolutions.compactMap { gesture, resolution in
            resolution == .middleClick ? gesture : nil
        }))
    }

    func resolveNativeClick(
        for gesture: TrackpadGesture,
        deviceID: UInt64,
        evidence: TrackpadGestureRecognitionEvidence?
    ) -> TrackpadNativeClickResolution? {
        resolvedMiddleClicks.append((gesture, deviceID))
        guard acceptsNativeClickResolution else { return nil }
        guard resolvesMiddleClicks else {
            return nativeClickResolutionUpdates.last?[gesture] == .consume ? .consume : nil
        }
        return nativeClickResolutionUpdates.last?[gesture]
    }

    func updateTestingMode(_ mode: TrackpadGestureTestingMode?) {
        currentTestingMode = mode
        testingModeUpdates.append(mode)
    }

    func updateTypingProtection(isEnabled: Bool, gracePeriod: TimeInterval) {
        typingProtectionUpdates.append((isEnabled, gracePeriod))
    }

    func deactivate() {
        deactivateCount += 1
        isActive = false
        currentTestingMode = nil
    }

    func recognize(_ gesture: TrackpadGesture, deviceID: UInt64 = 1) {
        onRecognized?(gesture, deviceID, nil, nil)
    }

    func reportAvailability(_ available: Bool) {
        isActive = available
        onAvailabilityChange?(available)
    }

    func reportTestingSnapshot(_ snapshot: TrackpadGestureTestSnapshot) {
        onTestingSnapshot?(snapshot)
    }

    func reportTestingReset() {
        onTestingReset?()
    }
}

@MainActor
private final class MockTrackpadGestureActionExecutor: TrackpadGestureActionExecuting {
    private(set) var actions: [TrackpadGestureAction] = []
    func execute(_ action: TrackpadGestureAction) { actions.append(action) }
}

@MainActor
private final class MockMultitouchFrameListener: MultitouchFrameListening {
    var deviceCount = 1
    var connectedDeviceIDs: Set<UInt64> = [1]
    var startSucceeds = true
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var handler: (@Sendable (TrackpadContactFrame) -> Void)?
    private var retainedHandlers: [@Sendable (TrackpadContactFrame) -> Void] = []

    func start(handler: @escaping @Sendable (TrackpadContactFrame) -> Void) -> Bool {
        startCount += 1
        self.handler = startSucceeds ? handler : nil
        if startSucceeds {
            retainedHandlers.append(handler)
        }
        return startSucceeds
    }

    func stop() {
        stopCount += 1
        handler = nil
    }

    func send(_ frame: TrackpadContactFrame, usingStart index: Int? = nil) {
        if let index {
            retainedHandlers[index](frame)
        } else {
            handler?(frame)
        }
    }

    func currentHandlerForTests() -> (@Sendable (TrackpadContactFrame) -> Void)? {
        handler
    }
}

@MainActor
final class TrackpadGestureStoreTests: XCTestCase {
    func testPortableViewPreferencesRoundTripAndLegacyPayloadPreservesDestination() throws {
        let source = TrackpadGestureStore(storage: TrackpadGestureMemoryStorage(), legacyMiddleClick: nil)
        source.setMappingSort(.addedOrder)
        source.setMappingStatusFilter(.disabled)
        source.setMappingActionFilter(.singleKey)
        let destination = TrackpadGestureStore(storage: TrackpadGestureMemoryStorage(), legacyMiddleClick: nil)
        let data = try XCTUnwrap(source.portableBackup())
        XCTAssertTrue(destination.restorePortableBackup(data))
        XCTAssertEqual(destination.mappingSort, .addedOrder)
        XCTAssertEqual(destination.mappingStatusFilter, .disabled)
        XCTAssertEqual(destination.mappingActionFilter, .singleKey)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["mappingSort", "mappingStatusFilter", "mappingActionFilter"] { legacy.removeValue(forKey: key) }
        destination.setMappingSort(.actionName)
        XCTAssertTrue(destination.restorePortableBackup(try JSONSerialization.data(withJSONObject: legacy)))
        XCTAssertEqual(destination.mappingSort, .actionName)
    }


    func testAddEditToggleDeleteAndPersistence() throws {
        let storage = TrackpadGestureMemoryStorage()
        let store = TrackpadGestureStore(storage: storage, legacyMiddleClick: nil)
        let shortcut = ShortcutBinding(keyCode: 0, modifiers: [.command, .option])
        var mapping = TrackpadGestureMapping(
            gesture: .tipTapLeftOneFixed,
            action: .keyboardShortcut(shortcut)
        )

        XCTAssertTrue(store.save(mapping))
        mapping.isEnabled = false
        XCTAssertTrue(store.save(mapping))
        XCTAssertFalse(store.mappings[0].isEnabled)

        store.setEnabled(true, id: mapping.id)
        let reloaded = TrackpadGestureStore(storage: storage, legacyMiddleClick: nil)
        XCTAssertEqual(reloaded.mappings, [TrackpadGestureMapping(
            id: mapping.id,
            gesture: mapping.gesture,
            action: mapping.action,
            isEnabled: true
        )])

        reloaded.delete(id: mapping.id)
        XCTAssertTrue(TrackpadGestureStore(storage: storage, legacyMiddleClick: nil).mappings.isEmpty)
    }

    func testUnsupportedSingleKeyMappingIsRejectedAndFilteredFromPersistence() throws {
        let storage = TrackpadGestureMemoryStorage()
        let invalid = TrackpadGestureMapping(
            gesture: .threeFingerTap,
            action: .keyTap(KeyboardKeyTap(keyCode: .max))
        )
        let store = TrackpadGestureStore(storage: storage, legacyMiddleClick: nil)

        XCTAssertFalse(store.save(invalid))
        storage.set(try JSONEncoder().encode([invalid]), forKey: "mappings")
        XCTAssertTrue(
            TrackpadGestureStore(storage: storage, legacyMiddleClick: nil).mappings.isEmpty
        )
    }

    func testMappingMutationsPublishOnlyAfterDurablePersistence() throws {
        let storage = TrackpadGestureMemoryStorage()
        let store = TrackpadGestureStore(storage: storage, legacyMiddleClick: nil)
        let mapping = TrackpadGestureMapping(
            gesture: .threeFingerTap,
            action: .middleClick
        )
        XCTAssertTrue(store.save(mapping))
        storage.blockedSetKeys = ["mappings"]
        var edited = mapping
        edited.action = .action(ActionReference(
            key: ActionKey(providerID: "test", actionID: "blocked-edit")
        ))

        XCTAssertFalse(store.save(edited))
        XCTAssertFalse(store.setEnabled(false, id: mapping.id))
        XCTAssertFalse(store.delete(id: mapping.id))
        XCTAssertEqual(store.mappings, [mapping])
        XCTAssertEqual(store.enabledGestures, [mapping.gesture])

        storage.blockedSetKeys = []
        let reloaded = TrackpadGestureStore(storage: storage, legacyMiddleClick: nil)
        XCTAssertEqual(reloaded.mappings, [mapping])
    }

    func testMacToolsActionPersistsMigratesAndPortableBackupRoundTrips() throws {
        let storage = TrackpadGestureMemoryStorage()
        let store = TrackpadGestureStore(storage: storage, legacyMiddleClick: nil)
        let original = ActionReference(
            key: ActionKey(providerID: "example", actionID: "run"),
            schemaVersion: 1
        )
        XCTAssertTrue(store.save(TrackpadGestureMapping(
            gesture: .fourFingerLongTouch,
            action: .action(original)
        )))

        let reloaded = TrackpadGestureStore(storage: storage, legacyMiddleClick: nil)
        XCTAssertEqual(reloaded.mapping(for: .fourFingerLongTouch)?.action, .action(original))
        let context = TrackpadActionHostContext(
            catalog: { [] },
            item: { _ in nil },
            migrate: { reference in
                ActionReference(
                    key: reference.key,
                    schemaVersion: 2,
                    parameters: reference.parameters
                )
            },
            execute: { _ in }
        )
        XCTAssertTrue(reloaded.migrateActions(using: context))
        guard case let .action(migrated)? = reloaded.mapping(for: .fourFingerLongTouch)?.action else {
            return XCTFail("Expected a canonical action mapping")
        }
        XCTAssertEqual(migrated.schemaVersion, 2)

        let backup = try XCTUnwrap(reloaded.portableBackup())
        let restored = TrackpadGestureStore(
            storage: TrackpadGestureMemoryStorage(),
            legacyMiddleClick: nil
        )
        XCTAssertTrue(restored.restorePortableBackup(backup))
        XCTAssertEqual(restored.mappings, reloaded.mappings)
    }

    func testPortableBackupWriteFailureRollsBackAllSettings() throws {
        let source = TrackpadGestureStore(
            storage: TrackpadGestureMemoryStorage(),
            legacyMiddleClick: nil
        )
        XCTAssertTrue(source.save(TrackpadGestureMapping(
            gesture: .threeFingerTap,
            action: .middleClick
        )))
        source.setTypingGracePeriod(1.2)
        let backup = try XCTUnwrap(source.portableBackup())

        let storage = TrackpadGestureMemoryStorage()
        let destination = TrackpadGestureStore(storage: storage, legacyMiddleClick: nil)
        let original = TrackpadGestureMapping(
            gesture: .fourFingerTap,
            action: .middleClick
        )
        XCTAssertTrue(destination.save(original))
        destination.setIgnoresGesturesWhileTyping(false)
        destination.setTypingGracePeriod(0.8)
        storage.blockedSetKeys = ["ignore-while-typing"]

        XCTAssertFalse(destination.restorePortableBackup(backup))
        storage.blockedSetKeys = []
        let reloaded = TrackpadGestureStore(storage: storage, legacyMiddleClick: nil)
        XCTAssertEqual(reloaded.mappings, [original])
        XCTAssertFalse(reloaded.ignoresGesturesWhileTyping)
        XCTAssertEqual(reloaded.typingGracePeriod, 0.8)
    }

    func testDuplicateGestureIsRejectedEvenWhenExistingMappingIsDisabled() {
        let store = TrackpadGestureStore(
            storage: TrackpadGestureMemoryStorage(),
            legacyMiddleClick: nil
        )
        let first = TrackpadGestureMapping(
            gesture: .fourFingerTap,
            action: .middleClick,
            isEnabled: false
        )
        let duplicate = TrackpadGestureMapping(
            gesture: .fourFingerTap,
            action: .keyboardShortcut(ShortcutBinding(keyCode: 1, modifiers: .command))
        )

        XCTAssertTrue(store.save(first))
        XCTAssertFalse(store.save(duplicate))
        XCTAssertEqual(store.conflictingMapping(for: .fourFingerTap)?.id, first.id)
    }

    func testLegacyMiddleClickMigratesOnceForUnchangedObservedPreferences() {
        let storage = TrackpadGestureMemoryStorage()
        let legacy = LegacyMiddleClickPreferences(isEnabled: true, fingerCount: 5)

        let store = TrackpadGestureStore(storage: storage, legacyMiddleClick: legacy)
        XCTAssertEqual(store.mappings.count, 1)
        XCTAssertEqual(store.mappings[0].gesture, .fiveFingerTap)
        XCTAssertEqual(store.mappings[0].action, .middleClick)
        XCTAssertNotNil(storage.data(forKey: "migration.mouse-enhancer-middle-click.v2"))
        XCTAssertTrue(store.didPersistPortablePreferencesDuringInitialization)

        let reloaded = TrackpadGestureStore(
            storage: storage,
            legacyMiddleClick: legacy
        )
        XCTAssertEqual(reloaded.mappings, store.mappings)
        XCTAssertFalse(reloaded.didPersistPortablePreferencesDuringInitialization)
    }

}

@MainActor
final class TrackpadGesturesPluginTests: XCTestCase {

    func testWeighingPausesAndRestoresMappingsWithoutSavedPreferenceChanges() {
        let fixture = makePlugin()
        let mapping = TrackpadGestureMapping(gesture: .threeFingerTap,
            action: .keyboardShortcut(ShortcutBinding(keyCode: 0, modifiers: [.command])))
        XCTAssertTrue(fixture.plugin.store.save(mapping))
        fixture.plugin.configurationDidChange()
        fixture.plugin.trackpadInputPauseDidChange(true)
        XCTAssertFalse(fixture.session.isActive)
        fixture.session.recognize(.threeFingerTap)
        XCTAssertTrue(fixture.executor.actions.isEmpty)
        XCTAssertEqual(fixture.plugin.store.mappings, [mapping])
        fixture.plugin.trackpadInputPauseDidChange(false)
        XCTAssertTrue(fixture.session.isActive)
        XCTAssertEqual(fixture.plugin.store.mappings, [mapping])
    }

    func testEnabledMappingExecutesEveryRepeatedRecognizedAction() {
        let fixture = makePlugin()
        let shortcut = ShortcutBinding(keyCode: 0, modifiers: [.command, .shift])
        let mapping = TrackpadGestureMapping(
            gesture: .tipTapRightOneFixed,
            action: .keyboardShortcut(shortcut)
        )
        XCTAssertTrue(fixture.plugin.store.save(mapping))

        fixture.plugin.configurationDidChange()
        XCTAssertEqual(fixture.session.activations, [[.tipTapRightOneFixed]])
        fixture.session.recognize(.tipTapRightOneFixed)
        fixture.session.recognize(.tipTapRightOneFixed)
        XCTAssertEqual(fixture.executor.actions, [
            .keyboardShortcut(shortcut),
            .keyboardShortcut(shortcut),
        ])
        XCTAssertEqual(
            fixture.session.nativeClickResolutionUpdates.last?[.tipTapRightOneFixed],
            .consume
        )
        XCTAssertEqual(fixture.session.typingProtectionUpdates.last?.0, true)
        XCTAssertEqual(fixture.session.typingProtectionUpdates.last?.1, 0.4)
    }

    func testMacToolsActionUsesSharedHostExecutorAndConsumesTipTapClick() {
        let fixture = makePlugin()
        let reference = ActionReference(
            key: ActionKey(providerID: "action-grid", actionID: "show")
        )
        var executed: [ActionReference] = []
        fixture.plugin.trackpadActionHostContext = TrackpadActionHostContext(
            catalog: { [] },
            item: { _ in nil },
            migrate: { $0 },
            execute: { executed.append($0) }
        )
        XCTAssertTrue(fixture.plugin.store.save(TrackpadGestureMapping(
            gesture: .tipTapRightOneFixed,
            action: .action(reference)
        )))

        fixture.plugin.configurationDidChange()
        fixture.session.recognize(.tipTapRightOneFixed)

        XCTAssertEqual(executed, [reference])
        XCTAssertTrue(fixture.executor.actions.isEmpty)
        XCTAssertEqual(
            fixture.session.nativeClickResolutionUpdates.last?[.tipTapRightOneFixed],
            .consume
        )
    }

    func testPhysicalClickShortcutConsumesNativeClickAndExecutesWithoutResolvingTwice() {
        let fixture = makePlugin()
        let shortcut = ShortcutBinding(keyCode: 0, modifiers: [.command, .shift])
        XCTAssertTrue(fixture.plugin.store.save(TrackpadGestureMapping(
            gesture: .twoFingerClick,
            action: .keyboardShortcut(shortcut)
        )))

        fixture.plugin.configurationDidChange()
        XCTAssertEqual(
            fixture.session.nativeClickResolutionUpdates.last?[.twoFingerClick],
            .consume
        )

        fixture.session.recognize(.twoFingerClick)

        XCTAssertEqual(fixture.executor.actions, [.keyboardShortcut(shortcut)])
        XCTAssertTrue(fixture.session.resolvedMiddleClicks.isEmpty)
    }

    func testPhysicalClickMappedToMiddleClickUsesNativeRewriteOnly() {
        let fixture = makePlugin()
        XCTAssertTrue(fixture.plugin.store.save(TrackpadGestureMapping(
            gesture: .threeFingerClick,
            action: .middleClick
        )))

        fixture.plugin.configurationDidChange()
        XCTAssertEqual(
            fixture.session.nativeClickResolutionUpdates.last?[.threeFingerClick],
            .middleClick
        )

        fixture.session.recognize(.threeFingerClick)

        XCTAssertTrue(fixture.executor.actions.isEmpty)
        XCTAssertTrue(fixture.session.resolvedMiddleClicks.isEmpty)
    }

    func testRecognitionAfterDeactivationDoesNotExecuteAction() {
        let fixture = makePlugin()
        XCTAssertTrue(fixture.plugin.store.save(TrackpadGestureMapping(
            gesture: .threeFingerTap,
            action: .middleClick
        )))
        fixture.plugin.configurationDidChange()

        fixture.plugin.deactivate(reason: .disabled)
        fixture.session.recognize(.threeFingerTap)

        XCTAssertTrue(fixture.executor.actions.isEmpty)
    }

    func testPermissionLossAtDeliveryStopsSessionAndDoesNotExecuteAction() {
        let accessibilityGranted = MutableBool(true)
        let fixture = makePlugin(accessibilityTrusted: { accessibilityGranted.value })
        XCTAssertTrue(fixture.plugin.store.save(TrackpadGestureMapping(
            gesture: .threeFingerTap,
            action: .middleClick
        )))
        fixture.plugin.configurationDidChange()

        accessibilityGranted.value = false
        fixture.session.recognize(.threeFingerTap)

        XCTAssertFalse(fixture.session.isActive)
        XCTAssertTrue(fixture.executor.actions.isEmpty)
        XCTAssertNotNil(fixture.plugin.rowState.errorMessage)
    }

    func testTestModeRecognizesWithoutExecutingActions() {
        let fixture = makePlugin()
        XCTAssertTrue(fixture.plugin.store.save(TrackpadGestureMapping(
            gesture: .threeFingerTap,
            action: .middleClick
        )))
        fixture.plugin.store.setTesting(true)
        fixture.plugin.configurationDidChange()

        XCTAssertEqual(fixture.session.activations.last, Set(TrackpadGesture.allCases))
        XCTAssertEqual(
            fixture.session.nativeClickResolutionUpdates.last?[.twoFingerClick],
            .consume
        )
        XCTAssertEqual(
            fixture.session.nativeClickResolutionUpdates.last?[.threeFingerClick],
            .consume
        )
        XCTAssertEqual(
            fixture.session.nativeClickResolutionUpdates.last?[.tipTapMiddleTwoFixed],
            .consume
        )
        fixture.session.recognize(.threeFingerTap)
        XCTAssertEqual(fixture.plugin.store.lastTestGesture, .threeFingerTap)
        XCTAssertTrue(fixture.executor.actions.isEmpty)

        fixture.session.recognize(.fiveFingerDoubleTap)
        XCTAssertEqual(fixture.plugin.store.lastTestGesture, .fiveFingerDoubleTap)
        XCTAssertTrue(fixture.executor.actions.isEmpty)
    }

    func testInputMonitoringDenialPreventsActivationAndRequestsGuidance() {
        let fixture = makePlugin(inputMonitoringStatus: { .denied })
        var requestedPermission: String?
        fixture.plugin.requestPermissionGuidance = { requestedPermission = $0 }
        XCTAssertTrue(fixture.plugin.store.save(TrackpadGestureMapping(
            gesture: .fourFingerTap,
            action: .middleClick
        )))

        fixture.plugin.configurationDidChange()

        XCTAssertTrue(fixture.session.activations.isEmpty)
        XCTAssertEqual(requestedPermission, "input-monitoring")
    }

    func testDeactivationStopsListenerAndClearsTestMode() {
        let fixture = makePlugin()
        fixture.plugin.store.setTesting(true)
        fixture.plugin.configurationDidChange()
        fixture.plugin.deactivate(reason: .disabled)

        XCTAssertFalse(fixture.plugin.store.isTesting)
        XCTAssertFalse(fixture.session.isActive)
    }

    func testSessionRestartsDriverForWakeAndDeviceRecovery() {
        let driver = MockMultitouchFrameListener()
        var tapStarts = 0
        var tapStops = 0
        let session = MultitouchDeviceSession(
            driver: driver,
            testEventTapStart: { tapStarts += 1; return true },
            testEventTapStop: { tapStops += 1 }
        )

        XCTAssertTrue(session.activate(gestures: [.threeFingerTap]))
        session.simulateWakeRecoveryForTests()
        session.simulateDeviceRecoveryForTests()

        XCTAssertEqual(driver.startCount, 3)
        XCTAssertGreaterThanOrEqual(driver.stopCount, 2)
        XCTAssertEqual(tapStarts, 3)
        XCTAssertEqual(tapStops, 2)
        session.deactivate()
    }

    func testEventTapDisableBalancesRewrittenDownAndSuppressesItsOriginalUp() throws {
        let driver = MockMultitouchFrameListener()
        let clock = LockedTestClock()
        var releaseCount = 0
        let session = makeMiddleClickSession(
            driver: driver,
            now: { clock.value },
            releaseMiddleButton: { releaseCount += 1 }
        )
        session.updateMiddleClickGestures([.threeFingerTap])
        XCTAssertTrue(session.activate(gestures: [.threeFingerTap]))
        driver.send(makeThreeContactFrame())
        clock.value = 0.01
        XCTAssertTrue(session.resolveMiddleClick(for: .threeFingerTap, deviceID: 1))
        clock.value = 0.02
        XCTAssertFalse(session.handleNativeEventForTests(
            type: .leftMouseDown,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, eventNumber: 201))
        ))

        session.simulateEventTapDisableForTests()

        XCTAssertEqual(releaseCount, 1)
        XCTAssertTrue(session.handleNativeEventForTests(
            type: .leftMouseUp,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseUp, eventNumber: 201))
        ))
        session.deactivate()
    }

    func testConsumedPhysicalClickReportsInputOwnershipBeforeReturning() throws {
        let driver = MockMultitouchFrameListener()
        let clock = LockedTestClock()
        let session = makeMiddleClickSession(driver: driver, now: { clock.value }, releaseMiddleButton: {})
        session.updateNativeClickResolutions([.threeFingerTap: .consume])
        XCTAssertTrue(session.activate(gestures: [.threeFingerTap]))
        defer { session.deactivate() }
        let reported = MutableBool(false)
        let observer = NotificationCenter.default.addObserver(
            forName: .macToolsWillClaimPhysicalInput, object: nil, queue: nil
        ) { _ in
            MainActor.assumeIsolated { reported.value = true }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        driver.send(makeThreeContactFrame())
        clock.value = 0.01
        XCTAssertEqual(session.resolveNativeClick(for: .threeFingerTap, deviceID: 1), .consume)
        clock.value = 0.02
        let down = try XCTUnwrap(makeMouseEvent(type: .leftMouseDown, eventNumber: 202))
        down.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        XCTAssertTrue(session.handleNativeEventForTests(type: .leftMouseDown, event: down))
        XCTAssertTrue(reported.value)

        reported.value = false
        let up = try XCTUnwrap(makeMouseEvent(type: .leftMouseUp, eventNumber: 202))
        up.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        XCTAssertTrue(session.handleNativeEventForTests(type: .leftMouseUp, event: up))
        XCTAssertFalse(reported.value)
    }

    private func makeMiddleClickSession(
        driver: MockMultitouchFrameListener,
        now: @escaping @Sendable () -> TimeInterval,
        releaseMiddleButton: @escaping @Sendable @MainActor () -> Void,
        wakeRestartDelay: TimeInterval = 10,
        deviceChangeRestartDelay: TimeInterval = 2
    ) -> MultitouchDeviceSession {
        MultitouchDeviceSession(
            driver: driver,
            testEventTapStart: { true },
            testEventTapStop: {},
            wakeRestartDelay: wakeRestartDelay,
            deviceChangeRestartDelay: deviceChangeRestartDelay,
            middleClickClock: now,
            synthesizeMiddleClick: {},
            releaseMiddleButton: releaseMiddleButton,
            postMiddleClickEvent: { _ in },
            middleClickAllowsContactInference: { true },
            middleClickEventOrigin: { _ in .trackpad(deviceID: 1) }
        )
    }

    private func makeThreeContactFrame(timestamp: TimeInterval = 0) -> TrackpadContactFrame {
        TrackpadContactFrame(
            deviceID: 1,
            timestamp: timestamp,
            contacts: [
                .init(identifier: 1, x: 0.2, y: 0.5),
                .init(identifier: 2, x: 0.5, y: 0.5),
                .init(identifier: 3, x: 0.8, y: 0.5),
            ]
        )
    }

    private func makeMouseEvent(type: CGEventType, eventNumber: Int64 = 0) -> CGEvent? {
        let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: CGPoint(x: 100, y: 100),
            mouseButton: .left
        )
        event?.setIntegerValueField(.mouseEventNumber, value: eventNumber)
        return event
    }

    private func makePlugin(
        storage: TrackpadGestureMemoryStorage? = nil,
        accessibilityTrusted: @escaping @Sendable @MainActor () -> Bool = { true },
        inputMonitoringStatus: @escaping @Sendable @MainActor () -> TrackpadInputMonitoringStatus = {
            .granted
        }
    ) -> (
        plugin: TrackpadGesturesPlugin,
        session: MockMultitouchDeviceSession,
        executor: MockTrackpadGestureActionExecutor
    ) {
        let session = MockMultitouchDeviceSession()
        let executor = MockTrackpadGestureActionExecutor()
        let plugin = TrackpadGesturesPlugin(
            context: PluginRuntimeContext(
                pluginID: "trackpad-gestures",
                storage: storage ?? TrackpadGestureMemoryStorage()
            ),
            legacyMiddleClick: nil,
            session: session,
            actionExecutor: executor,
            accessibilityTrusted: accessibilityTrusted,
            requestAccessibilityTrust: { _ in accessibilityTrusted() },
            inputMonitoringStatus: inputMonitoringStatus,
            openURL: { _ in }
        )
        return (plugin, session, executor)
    }
}
