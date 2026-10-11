import AppKit
import CoreFoundation
import Darwin
import Foundation
import IOKit
import MacToolsPluginKit
import MultitouchSupport
import OSLog

typealias TrackpadContactFrame = TrackpadSensorFrame
typealias TrackpadContactSnapshot = TrackpadSensorContact
typealias MultitouchDeviceDescriptor = TrackpadSensorDevice
typealias MultitouchDeviceTransport = TrackpadSensorTransport

@MainActor
protocol MultitouchFrameListening: AnyObject {
    var deviceCount: Int { get }
    var connectedDeviceIDs: Set<UInt64> { get }
    @discardableResult
    func start(handler: @escaping @Sendable (TrackpadContactFrame) -> Void) -> Bool
    func stop()
}

final class MultitouchFrameCallbackGate: @unchecked Sendable {
    typealias Handler = @Sendable (TrackpadContactFrame) -> Void

    private struct Registration {
        let deviceIDsByCallbackSource: [UInt64: UInt64]
        let handler: Handler
    }

    private let lock = NSLock()
    private var registration: Registration?

    func activate(
        deviceIDsByCallbackSource: [UInt64: UInt64],
        handler: @escaping Handler
    ) {
        lock.withLock {
            registration = Registration(
                deviceIDsByCallbackSource: deviceIDsByCallbackSource,
                handler: handler
            )
        }
    }

    func invalidate() {
        lock.withLock {
            registration = nil
        }
    }

    @discardableResult
    func deliver(_ frame: TrackpadContactFrame) -> Bool {
        lock.withLock {
            guard let registration,
                  let stableDeviceID = registration.deviceIDsByCallbackSource[frame.deviceID]
            else {
                return false
            }
            // Keep registration valid through delivery so stop() cannot release the device after
            // admission but before its frame reaches the session-level generation gate.
            registration.handler(TrackpadContactFrame(
                deviceID: stableDeviceID,
                timestamp: frame.timestamp,
                contacts: frame.contacts
            ))
            return true
        }
    }
}

final class MultitouchCallbackContextRegistry: @unchecked Sendable {
    static let shared = MultitouchCallbackContextRegistry()

    private let lock = NSLock()
    private var nextToken: UInt = 1
    private var gates: [UInt: MultitouchFrameCallbackGate] = [:]

    private init() {}

    func insert(_ gate: MultitouchFrameCallbackGate) -> UnsafeMutableRawPointer {
        lock.withLock {
            var token = nextToken
            while token == 0 || gates[token] != nil {
                token &+= 1
            }
            nextToken = token &+ 1
            if nextToken == 0 {
                nextToken = 1
            }
            gates[token] = gate
            return UnsafeMutableRawPointer(bitPattern: token)!
        }
    }

    func gate(for refcon: UnsafeMutableRawPointer?) -> MultitouchFrameCallbackGate? {
        guard let refcon else { return nil }
        return lock.withLock { gates[UInt(bitPattern: refcon)] }
    }

    func remove(_ refcon: UnsafeMutableRawPointer?) {
        guard let refcon else { return }
        _ = lock.withLock {
            gates.removeValue(forKey: UInt(bitPattern: refcon))
        }
    }
}

struct MultitouchDeviceEntry {
    let device: MTDevice
    let descriptor: MultitouchDeviceDescriptor
}

final class MultitouchDeviceCollection: @unchecked Sendable {
    let entries: [MultitouchDeviceEntry]
    private let lifetimeOwner: AnyObject?

    init(entries: [MultitouchDeviceEntry], lifetimeOwner: AnyObject? = nil) {
        self.entries = entries
        self.lifetimeOwner = lifetimeOwner
    }
}

struct MultitouchDeviceDiagnostics: Equatable, Sendable {
    let descriptor: MultitouchDeviceDescriptor
    let deliveredFrameCount: UInt64
    let lastFrameTimestamp: TimeInterval?
}

final class MultitouchDeviceDiagnosticsTracker: @unchecked Sendable {
    private struct State {
        let descriptor: MultitouchDeviceDescriptor
        var deliveredFrameCount: UInt64
        var lastFrameTimestamp: TimeInterval?
    }

    private let lock = NSLock()
    private var states: [UInt64: State] = [:]

    func configure(_ descriptors: [MultitouchDeviceDescriptor]) {
        lock.withLock {
            states = Dictionary(uniqueKeysWithValues: descriptors.map {
                ($0.deviceID, State(
                    descriptor: $0,
                    deliveredFrameCount: 0,
                    lastFrameTimestamp: nil
                ))
            })
        }
    }

    @discardableResult
    func observe(_ frame: TrackpadContactFrame) -> Bool {
        lock.withLock {
            guard var state = states[frame.deviceID] else { return false }
            let isFirstFrame = state.deliveredFrameCount == 0
            state.deliveredFrameCount &+= 1
            state.lastFrameTimestamp = frame.timestamp
            states[frame.deviceID] = state
            return isFirstFrame
        }
    }

    func snapshot() -> [MultitouchDeviceDiagnostics] {
        lock.withLock {
            states.values
                .map {
                    MultitouchDeviceDiagnostics(
                        descriptor: $0.descriptor,
                        deliveredFrameCount: $0.deliveredFrameCount,
                        lastFrameTimestamp: $0.lastFrameTimestamp
                    )
                }
                .sorted { $0.descriptor.deviceID < $1.descriptor.deviceID }
        }
    }

    func transportLabel(for deviceID: UInt64) -> String {
        lock.withLock {
            states[deviceID]?.descriptor.transport.rawValue
                ?? MultitouchDeviceTransport.unknown.rawValue
        }
    }

    func reset() {
        lock.withLock { states.removeAll() }
    }
}

protocol MultitouchRuntimeProviding: AnyObject {
    func createDeviceCollection() -> MultitouchDeviceCollection?
    func register(
        _ device: MTDevice,
        callback: MTFrameCallbackWithRefconFunction,
        refcon: UnsafeMutableRawPointer
    )
    func unregister(_ device: MTDevice, callback: MTFrameCallbackWithRefconFunction)
    func start(_ device: MTDevice)
    func stop(_ device: MTDevice)
}

final class MultitouchSupportRuntime: MultitouchRuntimeProviding, @unchecked Sendable {
    typealias CreateDeviceListFunction = @convention(c) () -> Unmanaged<CFMutableArray>?
    typealias RegisterCallbackFunction = @convention(c) (
        MTDevice,
        MTFrameCallbackWithRefconFunction,
        UnsafeMutableRawPointer?
    ) -> Void
    typealias UnregisterCallbackFunction = @convention(c) (
        MTDevice,
        MTFrameCallbackWithRefconFunction
    ) -> Void
    typealias StartDeviceFunction = @convention(c) (MTDevice, Int32) -> Void
    typealias StopDeviceFunction = @convention(c) (MTDevice) -> Void
    typealias GetDeviceIDFunction = @convention(c) (
        MTDevice,
        UnsafeMutablePointer<UInt64>
    ) -> Int32
    typealias IsBuiltInFunction = @convention(c) (MTDevice) -> Bool
    typealias GetServiceFunction = @convention(c) (MTDevice) -> io_service_t

    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"

    private let libraryHandle: UnsafeMutableRawPointer
    private let createDeviceListFunction: CreateDeviceListFunction
    private let registerCallbackFunction: RegisterCallbackFunction
    private let unregisterCallbackFunction: UnregisterCallbackFunction
    private let startDeviceFunction: StartDeviceFunction
    private let stopDeviceFunction: StopDeviceFunction
    private let getDeviceIDFunction: GetDeviceIDFunction?
    private let isBuiltInFunction: IsBuiltInFunction?
    private let supportsForceFunction: IsBuiltInFunction?
    private let getServiceFunction: GetServiceFunction?

    static func load() -> MultitouchSupportRuntime? {
        guard let handle = dlopen(frameworkPath, RTLD_LAZY | RTLD_LOCAL) else {
            return nil
        }
        guard
            let createDeviceList: CreateDeviceListFunction = loadSymbol(
                "MTDeviceCreateList", from: handle
            ),
            let registerCallback: RegisterCallbackFunction = loadSymbol(
                "MTRegisterContactFrameCallbackWithRefcon", from: handle
            ),
            let unregisterCallback: UnregisterCallbackFunction = loadSymbol(
                "MTUnregisterContactFrameCallback", from: handle
            ),
            let startDevice: StartDeviceFunction = loadSymbol("MTDeviceStart", from: handle),
            let stopDevice: StopDeviceFunction = loadSymbol("MTDeviceStop", from: handle)
        else {
            dlclose(handle)
            return nil
        }
        return MultitouchSupportRuntime(
            libraryHandle: handle,
            createDeviceListFunction: createDeviceList,
            registerCallbackFunction: registerCallback,
            unregisterCallbackFunction: unregisterCallback,
            startDeviceFunction: startDevice,
            stopDeviceFunction: stopDevice,
            getDeviceIDFunction: loadSymbol("MTDeviceGetDeviceID", from: handle),
            isBuiltInFunction: loadSymbol("MTDeviceIsBuiltIn", from: handle),
            supportsForceFunction: loadSymbol("MTDeviceSupportsForce", from: handle),
            getServiceFunction: loadSymbol("MTDeviceGetService", from: handle)
        )
    }

    private static func loadSymbol<Function>(
        _ name: String,
        from handle: UnsafeMutableRawPointer
    ) -> Function? {
        guard let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: Function.self)
    }

    private init(
        libraryHandle: UnsafeMutableRawPointer,
        createDeviceListFunction: CreateDeviceListFunction,
        registerCallbackFunction: RegisterCallbackFunction,
        unregisterCallbackFunction: UnregisterCallbackFunction,
        startDeviceFunction: StartDeviceFunction,
        stopDeviceFunction: StopDeviceFunction,
        getDeviceIDFunction: GetDeviceIDFunction?,
        isBuiltInFunction: IsBuiltInFunction?,
        supportsForceFunction: IsBuiltInFunction?,
        getServiceFunction: GetServiceFunction?
    ) {
        self.libraryHandle = libraryHandle
        self.createDeviceListFunction = createDeviceListFunction
        self.registerCallbackFunction = registerCallbackFunction
        self.unregisterCallbackFunction = unregisterCallbackFunction
        self.startDeviceFunction = startDeviceFunction
        self.stopDeviceFunction = stopDeviceFunction
        self.getDeviceIDFunction = getDeviceIDFunction
        self.isBuiltInFunction = isBuiltInFunction
        self.supportsForceFunction = supportsForceFunction
        self.getServiceFunction = getServiceFunction
    }

    deinit {
        dlclose(libraryHandle)
    }

    func createDeviceCollection() -> MultitouchDeviceCollection? {
        guard let retainedList = createDeviceListFunction()?.takeRetainedValue() else {
            return nil
        }
        let devices = retainedList as? [MTDevice] ?? []
        let entries = devices.map { device in
            MultitouchDeviceEntry(
                device: device,
                descriptor: descriptor(for: device)
            )
        }
        return MultitouchDeviceCollection(
            entries: entries,
            lifetimeOwner: retainedList
        )
    }

    func register(
        _ device: MTDevice,
        callback: MTFrameCallbackWithRefconFunction,
        refcon: UnsafeMutableRawPointer
    ) {
        registerCallbackFunction(device, callback, refcon)
    }

    func unregister(_ device: MTDevice, callback: MTFrameCallbackWithRefconFunction) {
        unregisterCallbackFunction(device, callback)
    }

    func start(_ device: MTDevice) {
        startDeviceFunction(device, 0)
    }

    func stop(_ device: MTDevice) {
        stopDeviceFunction(device)
    }

    private func descriptor(for device: MTDevice) -> MultitouchDeviceDescriptor {
        let service = getServiceFunction?(device) ?? 0
        let isBuiltIn = isBuiltInFunction?(device)
        return MultitouchDeviceDescriptor(
            deviceID: stableDeviceID(for: device, service: service),
            isBuiltIn: isBuiltIn,
            transport: transport(for: service, isBuiltIn: isBuiltIn),
            supportsForce: supportsForceFunction?(device),
            hasPersistentIdentity: stableDeviceIdentityAvailable(for: device, service: service)
        )
    }

    private func stableDeviceIdentityAvailable(for device: MTDevice, service: io_service_t) -> Bool {
        var deviceID: UInt64 = 0
        // Only the native device ID is retained across launches. Registry/pointer fallbacks
        // identify the current connection but must not key persisted calibration.
        return getDeviceIDFunction?(device, &deviceID) == 0 && deviceID != 0
    }

    private func stableDeviceID(for device: MTDevice, service: io_service_t) -> UInt64 {
        var deviceID: UInt64 = 0
        if let getDeviceIDFunction,
           getDeviceIDFunction(device, &deviceID) == 0,
           deviceID != 0 {
            return deviceID
        }
        if service != 0,
           IORegistryEntryGetRegistryEntryID(service, &deviceID) == KERN_SUCCESS,
           deviceID != 0 {
            return deviceID
        }
        return Self.callbackSourceID(device)
    }

    private func transport(
        for service: io_service_t,
        isBuiltIn: Bool?
    ) -> MultitouchDeviceTransport {
        if isBuiltIn == true {
            return .builtIn
        }
        guard service != 0,
              let value = IORegistryEntrySearchCFProperty(
                  service,
                  kIOServicePlane,
                  "Transport" as CFString,
                  kCFAllocatorDefault,
                  IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
              ) as? String
        else {
            return isBuiltIn == false ? .external : .unknown
        }
        let normalized = value.lowercased()
        if normalized.contains("bluetooth") {
            return .bluetooth
        }
        if normalized.contains("usb") {
            return .usb
        }
        return isBuiltIn == false ? .external : .unknown
    }

    private static func callbackSourceID(_ device: MTDevice) -> UInt64 {
        UInt64(UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque()))
    }
}

@MainActor
final class MultitouchDeviceDriver: MultitouchFrameListening, @unchecked Sendable {
    private var deviceCollection: MultitouchDeviceCollection?
    private var devices: [MultitouchDeviceEntry] = []
    private var callbackContext: UnsafeMutableRawPointer?
    private var callbackGate: MultitouchFrameCallbackGate?
    private let runtime: (any MultitouchRuntimeProviding)?
    nonisolated private let diagnosticsTracker = MultitouchDeviceDiagnosticsTracker()

    nonisolated private let logger = AppLog.trackpadSensor

    nonisolated private static let activeDriverLock = NSLock()
    nonisolated(unsafe) private static var activeDriver: MultitouchDeviceDriver?

    init(runtime: (any MultitouchRuntimeProviding)? = MultitouchSupportRuntime.load()) {
        self.runtime = runtime
    }

    private nonisolated static let touchCallback: MTFrameCallbackWithRefconFunction = {
        device, touches, touchCount, timestamp, _, refcon in
        guard touchCount >= 0, touchCount <= 64, timestamp.isFinite,
              (touchCount == 0 || touches != nil),
              let callbackGate = MultitouchCallbackContextRegistry.shared.gate(for: refcon)
        else {
            return
        }

        let pointer = Unmanaged.passUnretained(device).toOpaque()
        let deviceID = UInt64(UInt(bitPattern: pointer))
        let count = Int(touchCount)
        var contacts: [TrackpadContactSnapshot] = []
        contacts.reserveCapacity(count)
        if let touches {
            for index in 0..<count {
                let touch = touches[index]
                // MTPathStage raw values 3 and 4 are make-touch and touching. Break/hover contacts
                // remain in the private callback briefly and must not be treated as active fingers.
                guard touch.stage.rawValue == 3 || touch.stage.rawValue == 4 else {
                    continue
                }
                contacts.append(TrackpadContactSnapshot(
                    identifier: Int(touch.identifier),
                    x: Double(touch.normalizedVector.position.x),
                    y: Double(touch.normalizedVector.position.y),
                    pressure: Double(touch.pressure)
                ))
            }
        }

        callbackGate.deliver(TrackpadContactFrame(
            deviceID: deviceID,
            timestamp: timestamp,
            contacts: contacts
        ))
    }

    func availableDevices() -> [TrackpadSensorDevice] {
        guard let entries = runtime?.createDeviceCollection()?.entries else { return [] }
        return Self.entriesWithUniqueIDs(entries).map(\.descriptor)
    }

    var deviceCount: Int { devices.count }
    var connectedDeviceIDs: Set<UInt64> {
        Set(devices.map(\.descriptor.deviceID))
    }
    var deviceDiagnostics: [MultitouchDeviceDiagnostics] {
        diagnosticsTracker.snapshot()
    }

    @discardableResult
    func start(handler: @escaping @Sendable (TrackpadContactFrame) -> Void) -> Bool {
        guard let runtime else {
            logger.error("multitouch runtime is unavailable")
            return false
        }
        if let previous = Self.takeActiveDriver(), previous !== self {
            previous.stop()
        }
        stop()
        guard let collection = runtime.createDeviceCollection(),
              !collection.entries.isEmpty
        else {
            logger.error("multitouch runtime returned no devices")
            return false
        }
        deviceCollection = collection
        devices = Self.entriesWithUniqueIDs(collection.entries)
        let deviceIDsByCallbackSource = Dictionary(uniqueKeysWithValues: devices.map {
            (Self.callbackSourceID($0.device), $0.descriptor.deviceID)
        })
        diagnosticsTracker.configure(devices.map(\.descriptor))
        let diagnosticsTracker = diagnosticsTracker
        let logger = logger
        let callbackGate = MultitouchFrameCallbackGate()
        callbackGate.activate(
            deviceIDsByCallbackSource: deviceIDsByCallbackSource
        ) { frame in
            if diagnosticsTracker.observe(frame) {
                logger.info("received first multitouch frame transport=\(diagnosticsTracker.transportLabel(for: frame.deviceID), privacy: .public)")
            }
            handler(frame)
        }
        let callbackContext = MultitouchCallbackContextRegistry.shared.insert(callbackGate)
        self.callbackGate = callbackGate
        self.callbackContext = callbackContext
        Self.setActiveDriver(self)
        for entry in devices {
            runtime.register(
                entry.device,
                callback: Self.touchCallback,
                refcon: callbackContext
            )
            runtime.start(entry.device)
        }
        let builtInCount = devices.count { $0.descriptor.isBuiltIn == true }
        let externalCount = devices.count { $0.descriptor.isBuiltIn == false }
        logger.info("registered multitouch callbacks deviceCount=\(self.devices.count, privacy: .public) builtIn=\(builtInCount, privacy: .public) external=\(externalCount, privacy: .public)")
        return true
    }

    func stop() {
        callbackGate?.invalidate()
        MultitouchCallbackContextRegistry.shared.remove(callbackContext)
        callbackContext = nil
        Self.activeDriverLock.withLock {
            if Self.activeDriver === self {
                Self.activeDriver = nil
            }
        }
        devices.forEach { entry in
            runtime?.unregister(entry.device, callback: Self.touchCallback)
            runtime?.stop(entry.device)
        }
        devices.removeAll()
        deviceCollection = nil
        callbackGate = nil
        diagnosticsTracker.reset()
    }

    private nonisolated static func callbackSourceID(_ device: MTDevice) -> UInt64 {
        UInt64(UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque()))
    }

    private static func entriesWithUniqueIDs(
        _ entries: [MultitouchDeviceEntry]
    ) -> [MultitouchDeviceEntry] {
        var allocatedIDs = Set<UInt64>()
        return entries.map { entry in
            var deviceID = entry.descriptor.deviceID
            if deviceID == 0 || allocatedIDs.contains(deviceID) {
                deviceID = callbackSourceID(entry.device) | (UInt64(1) << 63)
                while deviceID == 0 || allocatedIDs.contains(deviceID) {
                    deviceID &+= 1
                }
            }
            allocatedIDs.insert(deviceID)
            return MultitouchDeviceEntry(
                device: entry.device,
                descriptor: MultitouchDeviceDescriptor(
                    deviceID: deviceID,
                    isBuiltIn: entry.descriptor.isBuiltIn,
                    transport: entry.descriptor.transport,
                    supportsForce: entry.descriptor.supportsForce,
                    hasPersistentIdentity: entry.descriptor.hasPersistentIdentity
                        && deviceID == entry.descriptor.deviceID
                )
            )
        }
    }

    private static func takeActiveDriver() -> MultitouchDeviceDriver? {
        activeDriverLock.withLock {
            defer { activeDriver = nil }
            return activeDriver
        }
    }

    private static func setActiveDriver(_ driver: MultitouchDeviceDriver) {
        activeDriverLock.withLock {
            activeDriver = driver
        }
    }
}
