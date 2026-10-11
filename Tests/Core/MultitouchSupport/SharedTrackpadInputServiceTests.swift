import Foundation
import XCTest
import MacToolsPluginKit
import MultitouchSupport
@testable import MacTools
@testable import TrackpadGesturesPlugin
@testable import MiddleClickPlugin

@MainActor
private final class SensorTestDriver: MacTools.MultitouchFrameListening {
    var startCount = 0
    var stopCount = 0
    var deviceCount = 1
    var connectedDeviceIDs: Set<UInt64> = [1]
    var handlers: [@Sendable (TrackpadSensorFrame) -> Void] = []
    func start(handler: @escaping @Sendable (TrackpadSensorFrame) -> Void) -> Bool {
        startCount += 1
        handlers.append(handler)
        return true
    }
    func stop() { stopCount += 1 }
    func send(_ contacts: [TrackpadSensorContact] = [], timestamp: TimeInterval = 1, deviceID: UInt64 = 1) {
        handlers.last?(TrackpadSensorFrame(deviceID: deviceID, timestamp: timestamp, contacts: contacts))
    }
}

@MainActor
private final class SensorTestLease: TrackpadSensorLeaseManaging {
    var allowsAcquisition = true
    var shouldRetryAfterFailedAcquisition: Bool { false }
    var owned = false
    func acquire() -> Bool { owned = allowsAcquisition; return owned }
    func release() { owned = false }
}

private final class SensorTestEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    private var interruptions = 0
    func receive(_ event: TrackpadSensorEvent) {
        lock.withLock {
            switch event {
            case .frame: frames += 1
            case .interrupted: interruptions += 1
            }
        }
    }
    var counts: (Int, Int) { lock.withLock { (frames, interruptions) } }
}

private final class SensorTestLongTouch: @unchecked Sendable {
    private let lock = NSLock()
    private var recognizer = LongTouchRecognizer(fingerCount: 3)
    private var actions = 0
    func reset() { lock.withLock { recognizer = LongTouchRecognizer(fingerCount: 3) } }
    func receive(_ event: TrackpadSensorEvent) {
        lock.withLock {
            if case let .frame(frame) = event, recognizer.process(frame) { actions += 1 }
        }
    }
    var count: Int { lock.withLock { actions } }
}

private final class SensorTestMiddleClick: @unchecked Sendable {
    private let pipeline = MiddleClickTapPipeline(fingerCount: 3)
    private let lock = NSLock()
    private var actions = 0
    func reset() { pipeline.reset() }
    func receive(_ event: TrackpadSensorEvent) {
        switch event {
        case .interrupted: reset()
        case let .frame(frame):
            let contacts = frame.contacts.map {
                MiddleClickContactSnapshot(identifier: $0.identifier, x: $0.x, y: $0.y)
            }
            if pipeline.process(MiddleClickContactFrame(deviceID: frame.deviceID,
                timestamp: frame.timestamp, contacts: contacts)) {
                lock.withLock { actions += 1 }
            }
        }
    }
    var count: Int { lock.withLock { actions } }
}

@MainActor
private final class SensorTestWakeScheduler {
    private var work: [@MainActor @Sendable () -> Void] = []
    func enqueue(_ action: @escaping @MainActor @Sendable () -> Void) { work.append(action) }
    func runNext() { work.removeFirst()() }
}

@MainActor
private class SensorTestLegacyPlugin: MacToolsPlugin {
    let metadata: PluginMetadata
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    init(id: String) {
        metadata = PluginMetadata(id: id, title: id, iconName: "hand.point.up", iconTint: .primary,
                                  order: 0, defaultDescription: "")
    }
}

@MainActor
private final class SensorTestModernPlugin: SensorTestLegacyPlugin, TrackpadInputServiceConsuming {
    func setTrackpadInputService(_ service: any TrackpadInputService) {}
}

@MainActor
final class SharedTrackpadInputServiceTests: XCTestCase {
    private let device = TrackpadSensorDevice(deviceID: 1, isBuiltIn: true, transport: .builtIn,
                                              supportsForce: true, hasPersistentIdentity: true)

    func testActivityRecoveryRejectsHeldMiddleClickAndAcceptsNextFreshTap() throws {
        for (contactsWereObserved, deviceWasReplaced) in [(true, false), (false, false), (false, true)] {
            let driver = SensorTestDriver()
            var inventory = [device]
            let service = SharedTrackpadInputService(driver: driver, lease: SensorTestLease(),
                inventory: { inventory }, observesDevices: false)
            let recognizer = SensorTestMiddleClick()
            var token = service.subscribe(purpose: .gestures) { recognizer.receive($0) }
            service.onGesturePauseChange = { [weak service] paused in
                guard let service else { return }
                if paused {
                    if let current = token { service.unsubscribe(current); token = nil }
                    recognizer.reset()
                } else {
                    token = service.subscribe(purpose: .gestures) { recognizer.receive($0) }
                }
            }
            let contacts = (1...3).map {
                TrackpadSensorContact(identifier: $0, x: 0.2 * Double($0), y: 0.5)
            }
            driver.send(contactsWereObserved ? contacts : [], timestamp: 1)
            driver.send(contactsWereObserved ? contacts : [], timestamp: 1.5)
            service.setActivityState(.sessionInactive)
            if deviceWasReplaced {
                inventory = [TrackpadSensorDevice(deviceID: 2, isBuiltIn: true, transport: .builtIn)]
            }
            let deviceID = try XCTUnwrap(inventory.first).deviceID
            service.setActivityState(.interactive)
            XCTAssertNotNil(token)
            driver.send(contacts, timestamp: 2, deviceID: deviceID)
            driver.send(timestamp: 2.1, deviceID: deviceID)
            XCTAssertEqual(recognizer.count, 0)
            driver.send(contacts, timestamp: 2.2, deviceID: deviceID)
            driver.send(timestamp: 2.3, deviceID: deviceID)
            XCTAssertEqual(recognizer.count, 1)
            service.unsubscribe(try XCTUnwrap(token))
        }
    }

    func testSubscribersShareListenerAndResumeOnlyAfterFingerLift() throws {
        let driver = SensorTestDriver()
        let lease = SensorTestLease()
        let device = device
        let service = SharedTrackpadInputService(driver: driver, lease: lease, inventory: { [device] }, observesDevices: false)
        let gestures = SensorTestEvents()
        let scale = SensorTestEvents()
        let gestureID = try XCTUnwrap(service.subscribe(purpose: .gestures, handler: { gestures.receive($0) }))
        let contact = TrackpadSensorContact(identifier: 1, x: 0.5, y: 0.5, pressure: 10)
        driver.send([contact])
        let scaleID = try XCTUnwrap(service.subscribe(purpose: .weighing, handler: { scale.receive($0) }))
        XCTAssertTrue(service.gesturesArePaused)
        XCTAssertNil(service.subscribe(purpose: .weighing, handler: { scale.receive($0) }))
        driver.send([contact])
        XCTAssertEqual(gestures.counts.0, 1)
        XCTAssertEqual(scale.counts.0, 1)
        XCTAssertEqual(driver.startCount, 1)
        service.unsubscribe(scaleID)
        XCTAssertFalse(service.gesturesArePaused)
        driver.send([contact])
        XCTAssertEqual(gestures.counts.0, 1)
        driver.send()
        driver.send([contact])
        XCTAssertEqual(gestures.counts.0, 3)
        service.unsubscribe(gestureID)
        XCTAssertFalse(lease.owned)
        let oldHandler = try XCTUnwrap(driver.handlers.last)
        oldHandler(TrackpadSensorFrame(deviceID: 1, timestamp: 2, contacts: [contact]))
        XCTAssertEqual(gestures.counts.0, 3)
        XCTAssertEqual(driver.stopCount, 1)
    }

    func testDisabledGesturesRepeatedWeighingAndInterruptedListening() throws {
        let driver = SensorTestDriver()
        let lease = SensorTestLease()
        let device = device
        let scheduler = SensorTestWakeScheduler()
        let service = SharedTrackpadInputService(driver: driver, lease: lease, inventory: { [device] },
            observesDevices: false, scheduleWakeRecovery: scheduler.enqueue)
        let events = SensorTestEvents()
        for _ in 0..<3 {
            let token = try XCTUnwrap(service.subscribe(purpose: .weighing, handler: { events.receive($0) }))
            driver.send()
            service.setActivityState(.systemSleeping)
            XCTAssertEqual(events.counts.1, driver.startCount)
            XCTAssertNil(service.subscribe(purpose: .weighing, handler: { events.receive($0) }))
            service.unsubscribe(token)
            service.setActivityState(.interactive)
            XCTAssertTrue(service.gesturesArePaused)
            scheduler.runNext()
            XCTAssertFalse(service.gesturesArePaused)
            XCTAssertFalse(lease.owned)
        }
        XCTAssertEqual(driver.startCount, 3)
        service.shutdown()
        XCTAssertNil(service.subscribe(purpose: .gestures, handler: { events.receive($0) }))
    }

    func testFirstLongTouchAfterWeighingUsesTheObservedFingerLift() throws {
        let driver = SensorTestDriver()
        let device = device
        let service = SharedTrackpadInputService(driver: driver, lease: SensorTestLease(),
            inventory: { [device] }, observesDevices: false)
        let recognizer = SensorTestLongTouch()
        var gestureToken = service.subscribe(purpose: .gestures) { recognizer.receive($0) }
        service.onGesturePauseChange = { [weak service] paused in
            guard let service else { return }
            recognizer.reset()
            if paused {
                if let token = gestureToken { service.unsubscribe(token); gestureToken = nil }
            } else {
                gestureToken = service.subscribe(purpose: .gestures) { recognizer.receive($0) }
            }
        }
        let token = try XCTUnwrap(service.subscribe(purpose: .weighing) { _ in })
        let contact = TrackpadSensorContact(identifier: 1, x: 0.5, y: 0.5, pressure: 10)
        driver.send([contact], timestamp: 0)
        service.unsubscribe(token)
        driver.send([contact], timestamp: 0.05)
        XCTAssertEqual(recognizer.count, 0)
        // Some devices send only this single zero frame before the next gesture.
        driver.send(timestamp: 0.1)
        let contacts = (1...3).map {
            TrackpadSensorContact(identifier: $0, x: Double($0) * 0.2, y: 0.5, pressure: 10)
        }
        for index in 0..<14 { driver.send(contacts, timestamp: 0.2 + Double(index) * 0.05) }
        XCTAssertEqual(recognizer.count, 1)
        service.shutdown()
    }

    func testWakeWaitsForRecoveryAndCancelsAfterAnotherSleepOrShutdown() throws {
        let driver = SensorTestDriver()
        let lease = SensorTestLease()
        let scheduler = SensorTestWakeScheduler()
        let device = device
        let service = SharedTrackpadInputService(driver: driver, lease: lease, inventory: { [device] },
            observesDevices: false, scheduleWakeRecovery: scheduler.enqueue)
        var gestureToken = service.subscribe(purpose: .gestures) { _ in }
        service.onGesturePauseChange = { [weak service] paused in
            guard let service else { return }
            if paused {
                if let token = gestureToken { service.unsubscribe(token); gestureToken = nil }
            } else {
                gestureToken = service.subscribe(purpose: .gestures) { _ in }
            }
        }
        service.setActivityState(.systemSleeping)
        service.setActivityState(.waking)
        service.setActivityState(.interactive)
        service.deviceTopologyDidChange()
        XCTAssertTrue(service.gesturesArePaused)
        XCTAssertNil(gestureToken)
        XCTAssertFalse(lease.owned)
        scheduler.runNext()
        XCTAssertFalse(service.gesturesArePaused)
        XCTAssertNotNil(gestureToken)
        XCTAssertTrue(lease.owned)

        service.setActivityState(.systemSleeping)
        service.setActivityState(.waking)
        service.setActivityState(.systemSleeping)
        service.setActivityState(.waking)
        service.setActivityState(.interactive)
        scheduler.runNext()
        XCTAssertTrue(service.gesturesArePaused)
        XCTAssertFalse(lease.owned)
        scheduler.runNext()
        XCTAssertNotNil(gestureToken)
        XCTAssertTrue(lease.owned)

        service.setActivityState(.systemSleeping)
        service.setActivityState(.waking)
        service.setActivityState(.interactive)
        service.shutdown()
        scheduler.runNext()
        XCTAssertTrue(service.gesturesArePaused)
        XCTAssertNil(gestureToken)
        XCTAssertFalse(lease.owned)
    }

    func testHostBlocksLegacyGesturePackagesButAllowsUpdatedAndUnrelatedPackages() throws {
        for id in ["middle-click", "trackpad-gestures", "unrelated-plugin"] {
            for isModern in [false, true] {
                let plugin: any MacToolsPlugin = isModern
                    ? SensorTestModernPlugin(id: id) : SensorTestLegacyPlugin(id: id)
                let driver = SensorTestDriver()
                let lease = SensorTestLease()
                let device = device
                let service = SharedTrackpadInputService(driver: driver, lease: lease,
                    inventory: { [device] }, observesDevices: false)
                let scale = SensorTestModernPlugin(id: "trackpad-scale")
                let suite = "SharedTrackpadInputServiceTests.\(UUID().uuidString)"
                let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
                defer { defaults.removePersistentDomain(forName: suite) }
                let host = PluginHost(plugins: [plugin, scale],
                    shortcutStore: ShortcutStore(userDefaults: defaults),
                    pluginOrderingStore: PluginOrderingStore(userDefaults: defaults),
                    preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
                    globalShortcutManager: GlobalShortcutManager(), makeTrackpadInputService: { service })
                let token = service.subscribe(purpose: .weighing) { _ in }
                let allowed = isModern || id == "unrelated-plugin"
                XCTAssertEqual(token != nil, allowed)
                XCTAssertEqual(lease.owned, allowed)
                if let token { service.unsubscribe(token) }
                withExtendedLifetime(host) {}
            }
        }
    }

    func testHostDisplayRecoveryRestartsNativeInputWithTwoConsumers() throws {
        let driver = SensorTestDriver()
        let device = device
        let service = SharedTrackpadInputService(driver: driver, lease: SensorTestLease(),
            inventory: { [device] }, observesDevices: false)
        let suite = "SharedTrackpadInputServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = PluginHost(plugins: [SensorTestModernPlugin(id: "middle-click"),
                                       SensorTestModernPlugin(id: "trackpad-gestures")],
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginOrderingStore: PluginOrderingStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager(), makeTrackpadInputService: { service })
        let first = SensorTestEvents()
        let second = SensorTestEvents()
        let firstToken = try XCTUnwrap(service.subscribe(purpose: .gestures) { first.receive($0) })
        let secondToken = try XCTUnwrap(service.subscribe(purpose: .gestures) { second.receive($0) })
        let oldCallback = try XCTUnwrap(driver.handlers.last)
        driver.send()
        host.refreshDisplayTopology()
        oldCallback(TrackpadSensorFrame(deviceID: 1, timestamp: 2, contacts: []))
        driver.send(timestamp: 3)
        XCTAssertEqual(driver.startCount, 2)
        XCTAssertEqual(first.counts.0, 2)
        XCTAssertEqual(second.counts.0, 2)
        XCTAssertEqual(first.counts.1, 1)
        XCTAssertEqual(second.counts.1, 1)
        service.unsubscribe(firstToken)
        service.unsubscribe(secondToken)
        withExtendedLifetime(host) {}
    }

    func testLegacyConsumerArrivalInterruptsAnExistingWeighingSession() throws {
        let driver = SensorTestDriver()
        let lease = SensorTestLease()
        let device = device
        let service = SharedTrackpadInputService(driver: driver, lease: lease,
            inventory: { [device] }, observesDevices: false)
        var plugins: [any MacToolsPlugin] = [SensorTestModernPlugin(id: "middle-click")]
        service.canBeginWeighing = { TrackpadInputCompatibility.canWeigh(with: plugins) }
        let events = SensorTestEvents()
        let token = try XCTUnwrap(service.subscribe(purpose: .weighing) { events.receive($0) })
        let oldCallback = try XCTUnwrap(driver.handlers.last)
        plugins = [SensorTestLegacyPlugin(id: "middle-click")]
        service.refreshWeighingAvailability()
        oldCallback(TrackpadSensorFrame(deviceID: 1, timestamp: 2, contacts: []))
        XCTAssertEqual(events.counts.1, 1)
        XCTAssertEqual(events.counts.0, 0)
        XCTAssertFalse(lease.owned)
        XCTAssertNil(service.subscribe(purpose: .weighing) { _ in })
        service.unsubscribe(token)
    }

    func testPauseCallbackCanUnsubscribeAndRestoreGestureConsumer() throws {
        let driver = SensorTestDriver()
        let device = device
        let service = SharedTrackpadInputService(driver: driver, lease: SensorTestLease(), inventory: { [device] }, observesDevices: false)
        let recognizer = SensorTestMiddleClick()
        let contacts = (1...3).map {
            TrackpadSensorContact(identifier: $0, x: 0.2 * Double($0), y: 0.5)
        }
        var gestureToken = service.subscribe(purpose: .gestures, handler: { recognizer.receive($0) })
        service.onGesturePauseChange = { paused in
            if paused {
                if let token = gestureToken { service.unsubscribe(token); gestureToken = nil }
                recognizer.reset()
            } else {
                gestureToken = service.subscribe(purpose: .gestures, handler: { recognizer.receive($0) })
                driver.send(contacts, timestamp: 2)
            }
        }
        let token = try XCTUnwrap(service.subscribe(purpose: .weighing, handler: { _ in }))
        driver.send(contacts, timestamp: 1)
        service.unsubscribe(token)
        XCTAssertNotNil(gestureToken)
        XCTAssertEqual(driver.startCount, 1)
        driver.send(timestamp: 2.1)
        XCTAssertEqual(recognizer.count, 0)
        driver.send(contacts, timestamp: 2.2)
        driver.send(timestamp: 2.3)
        XCTAssertEqual(recognizer.count, 1)
        service.shutdown()
    }

    func testDeviceChangesInterruptAndDiscardOldCallbacks() throws {
        let driver = SensorTestDriver()
        var inventory = [device]
        let service = SharedTrackpadInputService(driver: driver, lease: SensorTestLease(),
            inventory: { inventory }, observesDevices: false)
        let events = SensorTestEvents()
        let token = try XCTUnwrap(service.subscribe(purpose: .weighing, handler: { events.receive($0) }))
        let staleCallback = try XCTUnwrap(driver.handlers.last)
        inventory = [TrackpadSensorDevice(deviceID: 2, isBuiltIn: true, transport: .builtIn,
                                          supportsForce: true, hasPersistentIdentity: true)]
        service.deviceTopologyDidChange()
        XCTAssertEqual(events.counts.1, 1)
        XCTAssertEqual(service.devices.map(\.deviceID), [2])
        staleCallback(TrackpadSensorFrame(deviceID: 1, timestamp: 2, contacts: []))
        XCTAssertEqual(events.counts.0, 0)
        service.unsubscribe(token)
        XCTAssertFalse(service.gesturesArePaused)
    }

    func testUnsupportedCapabilitiesAndFailedLeaseDoNotPauseGestures() {
        let driver = SensorTestDriver()
        let unsupported = TrackpadSensorDevice(deviceID: 1, isBuiltIn: true, transport: .builtIn)
        let service = SharedTrackpadInputService(driver: driver, lease: SensorTestLease(), inventory: { [unsupported] }, observesDevices: false)
        XCTAssertNil(service.subscribe(purpose: .weighing) { _ in })
        XCTAssertFalse(service.gesturesArePaused)
        XCTAssertEqual(driver.startCount, 0)
        let lease = SensorTestLease()
        lease.allowsAcquisition = false
        let device = device
        let denied = SharedTrackpadInputService(driver: driver, lease: lease, inventory: { [device] }, observesDevices: false)
        XCTAssertNil(denied.subscribe(purpose: .weighing) { _ in })
        XCTAssertFalse(denied.gesturesArePaused)
        XCTAssertFalse(lease.owned)
        let native = MultitouchDeviceDriver(runtime: nil)
        XCTAssertFalse(native.start { _ in })
        XCTAssertEqual(native.deviceCount, 0)
    }

    func testNativeTouchPressureLayoutRemainsCompatible() {
        XCTAssertEqual(MemoryLayout<MTTouch>.stride, 96)
        XCTAssertEqual(MemoryLayout<MTTouch>.offset(of: \.pressure), 52)
    }

    func testCallbackRegistryRejectsUnregisteredAndUnknownSources() {
        let events = SensorTestEvents()
        let gate = MultitouchFrameCallbackGate()
        gate.activate(deviceIDsByCallbackSource: [4: 1]) { frame in events.receive(.frame(frame)) }
        let refcon = MultitouchCallbackContextRegistry.shared.insert(gate)
        XCTAssertNotNil(MultitouchCallbackContextRegistry.shared.gate(for: refcon))
        XCTAssertFalse(gate.deliver(TrackpadSensorFrame(deviceID: 5, timestamp: 1, contacts: [])))
        XCTAssertTrue(gate.deliver(TrackpadSensorFrame(deviceID: 4, timestamp: 1, contacts: [])))
        gate.invalidate()
        MultitouchCallbackContextRegistry.shared.remove(refcon)
        XCTAssertNil(MultitouchCallbackContextRegistry.shared.gate(for: refcon))
        XCTAssertFalse(gate.deliver(TrackpadSensorFrame(deviceID: 4, timestamp: 2, contacts: [])))
        XCTAssertEqual(events.counts.0, 1)
    }

    func testProcessLeaseHonorsDisabledPolicy() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let denied = TrackpadSensorProcessLease(temporaryDirectory: directory, isAcquisitionAllowed: false)
        let allowed = TrackpadSensorProcessLease(temporaryDirectory: directory, isAcquisitionAllowed: true)
        XCTAssertFalse(denied.acquire())
        XCTAssertTrue(allowed.acquire())
        allowed.release()
    }
}
