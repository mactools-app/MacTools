import AppKit
import Foundation
import IOKit
import MacToolsPluginKit

/// Synchronous gesture delivery preserves the existing recognition/event-tap timing.
/// Consumers copy or coalesce values before hopping to their actor.
private final class TrackpadSensorDeliveryRelay: @unchecked Sendable {
    typealias Handler = @Sendable (TrackpadSensorEvent) -> Void
    private let lock = NSLock()
    private var handlers: [UUID: (TrackpadInputPurpose, Handler)] = [:]
    private var waitingForZero = Set<UInt64>()
    private var activeDeviceIDs = Set<UInt64>()
    private var generation: UInt64 = 0

    func configure(_ handlers: [UUID: (TrackpadInputPurpose, Handler)],
                   requiringContactRelease deviceIDs: Set<UInt64>? = nil) {
        lock.withLock {
            // Native callbacks must see the release gate and subscriber change together.
            if let deviceIDs {
                waitingForZero.formIntersection(deviceIDs)
                activeDeviceIDs.formIntersection(deviceIDs)
                waitingForZero.formUnion(activeDeviceIDs)
            }
            self.handlers = handlers
        }
    }

    func requireContactRelease(deviceIDs: Set<UInt64>, observedContactsOnly: Bool) {
        lock.withLock {
            waitingForZero.formIntersection(deviceIDs)
            activeDeviceIDs.formIntersection(deviceIDs)
            waitingForZero.formUnion(observedContactsOnly ? activeDeviceIDs : deviceIDs)
        }
    }

    func begin() -> UInt64 {
        lock.withLock { generation &+= 1; return generation }
    }

    func invalidate() {
        lock.withLock { generation &+= 1 }
    }

    func deliver(_ frame: TrackpadSensorFrame, generation expected: UInt64) {
        lock.withLock {
            guard expected == generation else { return }
            if frame.contacts.isEmpty { activeDeviceIDs.remove(frame.deviceID) }
            else { activeDeviceIDs.insert(frame.deviceID) }
            let weighing = handlers.values.contains { $0.0 == .weighing }
            if frame.contacts.isEmpty { waitingForZero.remove(frame.deviceID) }
            let blocked = waitingForZero.contains(frame.deviceID)
            for (purpose, handler) in handlers.values {
                if purpose == .gestures && (weighing || blocked) { continue }
                handler(.frame(frame))
            }
        }
    }
}

@MainActor
final class SharedTrackpadInputService: TrackpadInputService {
    typealias WakeRecoveryScheduler = (@escaping @MainActor @Sendable () -> Void) -> Void

    private let driver: any MultitouchFrameListening
    private let lease: any TrackpadSensorLeaseManaging
    private let inventory: () -> [TrackpadSensorDevice]
    private let relay = TrackpadSensorDeliveryRelay()
    private var subscribers: [UUID: (TrackpadInputPurpose, @Sendable (TrackpadSensorEvent) -> Void)] = [:]
    private var listening = false
    private var suspended = false
    private var isShuttingDown = false
    private var topologyIsChanging = false
    private var performingTopologyUpdate = false
    private let scheduleWakeRecovery: WakeRecoveryScheduler
    private var needsWakeRecovery = false
    private var wakeRecoveryIsScheduled = false
    private var wakeRecoveryGeneration = UUID()
    private let observesDevices: Bool
    private var port: IONotificationPortRef?
    private var arrivalIterator: io_iterator_t = 0
    private var removalIterator: io_iterator_t = 0
    private var observationContext: UnsafeMutableRawPointer?
    private var topologyUpdate: DispatchWorkItem?
    private(set) var devices: [TrackpadSensorDevice] = []
    var onGesturePauseChange: ((Bool) -> Void)?
    var canBeginWeighing: () -> Bool = { true }
    var gesturesArePaused: Bool { suspended || needsWakeRecovery || isShuttingDown || topologyIsChanging || subscribers.values.contains { $0.0 == .weighing } }

    init(driver: (any MultitouchFrameListening)? = nil,
         lease: (any TrackpadSensorLeaseManaging)? = nil,
         inventory: (() -> [TrackpadSensorDevice])? = nil,
         observesDevices: Bool = true,
         scheduleWakeRecovery: @escaping WakeRecoveryScheduler = { work in
             // Native input can report successful registration before recovering
             // from long sleep. Preserve the existing ten-second driver delay.
             DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
         }) {
        self.observesDevices = observesDevices
        self.scheduleWakeRecovery = scheduleWakeRecovery
        let nativeDriver = driver ?? MultitouchDeviceDriver()
        self.driver = nativeDriver
        self.lease = lease ?? TrackpadSensorProcessLease()
        self.inventory = inventory ?? { (nativeDriver as? MultitouchDeviceDriver)?.availableDevices() ?? [] }
    }

    isolated deinit {
        stopListening()
        removeDeviceObservation()
    }

    func subscribe(purpose: TrackpadInputPurpose,
                   handler: @escaping @Sendable (TrackpadSensorEvent) -> Void) -> UUID? {
        guard !suspended, !needsWakeRecovery, !isShuttingDown else { return nil }
        devices = inventory()
        guard !devices.isEmpty,
              purpose != .weighing || (canBeginWeighing() && !gesturesArePaused && devices.contains(where: \.supportsWeighing))
        else { return nil }
        let id = UUID()
        subscribers[id] = (purpose, handler)
        relay.configure(subscribers)
        // Install the weighing subscription before pausing the gesture plugin: its
        // unsubscribe must not tear down the listener we are about to use.
        if purpose == .weighing { onGesturePauseChange?(true) }
        guard listening || startListening() else {
            unsubscribe(id)
            return nil
        }
        observeDevices()
        return id
    }

    func unsubscribe(_ subscriptionID: UUID) {
        guard let removed = subscribers.removeValue(forKey: subscriptionID) else { return }
        relay.configure(subscribers,
                        requiringContactRelease: removed.0 == .weighing ? Set(devices.map(\.deviceID)) : nil)
        if removed.0 == .weighing { onGesturePauseChange?(gesturesArePaused) }
        if subscribers.isEmpty {
            stopListening()
            removeDeviceObservation()
            if topologyIsChanging, !performingTopologyUpdate {
                topologyIsChanging = false
                onGesturePauseChange?(gesturesArePaused)
            }
        }
    }

    private func startListening() -> Bool {
        guard !suspended, !needsWakeRecovery, !isShuttingDown,
              !subscribers.isEmpty, lease.acquire() else { return false }
        let generation = relay.begin()
        let relay = relay
        listening = driver.start { frame in relay.deliver(frame, generation: generation) }
        if !listening { relay.invalidate(); lease.release() }
        return listening
    }

    private func stopListening() {
        relay.invalidate()
        driver.stop()
        listening = false
        lease.release()
    }

    /// Interrupt before re-enumerating; a weighing consumer must explicitly restart
    /// and tare again. Gesture subscriptions can recover without saved-setting changes.
    func interrupt() {
        // Contacts may begin while callbacks are stopped, so every recovered
        // device must establish an empty frame before recognizing gestures.
        relay.requireContactRelease(deviceIDs: Set(devices.map(\.deviceID)), observedContactsOnly: false)
        stopListening()
        let callbacks = Array(subscribers.values.map(\.1))
        callbacks.forEach { $0(.interrupted) }
    }

    func refreshWeighingAvailability() {
        guard !canBeginWeighing(), subscribers.values.contains(where: { $0.0 == .weighing }) else { return }
        interrupt()
    }

    func deviceTopologyDidChange() {
        performingTopologyUpdate = true
        // Reset recognizers and native event taps before a new device generation.
        topologyIsChanging = true
        onGesturePauseChange?(true)
        interrupt()
        devices = inventory()
        relay.requireContactRelease(deviceIDs: Set(devices.map(\.deviceID)), observedContactsOnly: false)
        if !suspended, !isShuttingDown { _ = startListening() }
        topologyIsChanging = false
        performingTopologyUpdate = false
        onGesturePauseChange?(gesturesArePaused)
    }

    func setActivityState(_ state: PluginApplicationActivityState) {
        guard !isShuttingDown else { return }
        if state == .systemSleeping {
            needsWakeRecovery = true
            wakeRecoveryGeneration = UUID()
            wakeRecoveryIsScheduled = false
        } else if state == .waking {
            needsWakeRecovery = true
            scheduleWakeRecoveryIfNeeded()
        }
        let shouldSuspend = state != .interactive
        guard suspended != shouldSuspend else { return }
        suspended = shouldSuspend
        if suspended {
            onGesturePauseChange?(true)
            interrupt()
        } else if needsWakeRecovery {
            // Also recover if the activity source skipped its waking state.
            scheduleWakeRecoveryIfNeeded()
        } else { deviceTopologyDidChange() }
    }

    private func scheduleWakeRecoveryIfNeeded() {
        guard needsWakeRecovery, !wakeRecoveryIsScheduled else { return }
        wakeRecoveryIsScheduled = true
        let generation = wakeRecoveryGeneration
        scheduleWakeRecovery { [weak self] in
            guard let self, !self.isShuttingDown, self.wakeRecoveryGeneration == generation else { return }
            self.wakeRecoveryIsScheduled = false
            self.needsWakeRecovery = false
            if !self.suspended { self.deviceTopologyDidChange() }
        }
    }

    func shutdown() {
        isShuttingDown = true
        wakeRecoveryGeneration = UUID()
        interrupt()
        subscribers.removeAll()
        relay.configure([:])
        removeDeviceObservation()
        onGesturePauseChange?(true)
    }

    private func observeDevices() {
        guard observesDevices, port == nil,
              let newPort = IONotificationPortCreate(kIOMainPortDefault) else { return }
        guard let source = IONotificationPortGetRunLoopSource(newPort)?.takeUnretainedValue() else {
            IONotificationPortDestroy(newPort)
            return
        }
        let context = Unmanaged.passRetained(PluginCallbackContext(owner: self)).toOpaque()
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            var changed = false
            while case let entry = IOIteratorNext(iterator), entry != 0 {
                IOObjectRelease(entry)
                changed = true
            }
            guard changed,
                  let refcon
            else { return }
            let box = Unmanaged<PluginCallbackContext<SharedTrackpadInputService>>.fromOpaque(refcon).takeUnretainedValue()
            box.withOwner { owner in
                DispatchQueue.main.async { owner.scheduleTopologyUpdate() }
            }
        }
        let arrival = IOServiceAddMatchingNotification(newPort, kIOFirstMatchNotification,
            IOServiceMatching("AppleMultitouchDevice"), callback, context, &arrivalIterator)
        let removal = IOServiceAddMatchingNotification(newPort, kIOTerminatedNotification,
            IOServiceMatching("AppleMultitouchDevice"), callback, context, &removalIterator)
        guard arrival == KERN_SUCCESS, removal == KERN_SUCCESS else {
            Unmanaged<PluginCallbackContext<SharedTrackpadInputService>>.fromOpaque(context)
                .takeUnretainedValue().invalidate()
            if arrivalIterator != 0 { IOObjectRelease(arrivalIterator); arrivalIterator = 0 }
            if removalIterator != 0 { IOObjectRelease(removalIterator); removalIterator = 0 }
            IONotificationPortDestroy(newPort)
            Unmanaged<PluginCallbackContext<SharedTrackpadInputService>>.fromOpaque(context).release()
            return
        }
        // Drain initial matches to arm notifications without interrupting the new session.
        for iterator in [arrivalIterator, removalIterator] {
            while case let entry = IOIteratorNext(iterator), entry != 0 { IOObjectRelease(entry) }
        }
        observationContext = context
        port = newPort
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    private func scheduleTopologyUpdate() {
        guard !subscribers.isEmpty, !isShuttingDown else { return }
        // Invalidate immediately; only re-enumeration is debounced.
        performingTopologyUpdate = true
        topologyIsChanging = true
        onGesturePauseChange?(true)
        interrupt()
        performingTopologyUpdate = false
        topologyUpdate?.cancel()
        let update = DispatchWorkItem { [weak self] in
            self?.topologyUpdate = nil
            self?.deviceTopologyDidChange()
        }
        topologyUpdate = update
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: update)
    }

    private func removeDeviceObservation() {
        if let observationContext {
            Unmanaged<PluginCallbackContext<SharedTrackpadInputService>>.fromOpaque(observationContext)
                .takeUnretainedValue().invalidate()
        }
        topologyUpdate?.cancel()
        topologyUpdate = nil
        if arrivalIterator != 0 { IOObjectRelease(arrivalIterator); arrivalIterator = 0 }
        if removalIterator != 0 { IOObjectRelease(removalIterator); removalIterator = 0 }
        if let port {
            if let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            IONotificationPortDestroy(port)
            self.port = nil
        }
        if let observationContext {
            let box = Unmanaged<PluginCallbackContext<SharedTrackpadInputService>>.fromOpaque(observationContext)
            box.takeUnretainedValue().invalidate()
            box.release()
        }
        observationContext = nil
    }
}
