import AppKit
import CoreFoundation
import CoreGraphics
import Darwin
import Foundation
import IOKit
@preconcurrency import IOKit.hid
import MacToolsPluginKit
import OSLog

@MainActor
protocol MultitouchFrameListening: AnyObject {
    var deviceCount: Int { get }
    var connectedDeviceIDs: Set<UInt64> { get }
    @discardableResult
    func start(handler: @escaping @Sendable (TrackpadContactFrame) -> Void) -> Bool
    func stop()
}

@MainActor
protocol TrackpadListenerLeaseManaging: AnyObject {
    var shouldRetryAfterFailedAcquisition: Bool { get }
    func acquire() -> Bool
    func release()
}

@MainActor
private final class TrackpadInProcessListenerLease: TrackpadListenerLeaseManaging {
    var shouldRetryAfterFailedAcquisition: Bool { true }
    func acquire() -> Bool { true }
    func release() {}
}

final class MultitouchFrameDeliveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    func beginGeneration() -> UInt64 {
        lock.withLock {
            generation &+= 1
            return generation
        }
    }

    @discardableResult
    func deliver(
        generation expectedGeneration: UInt64,
        _ body: @Sendable () -> Void
    ) -> Bool {
        lock.withLock {
            guard generation == expectedGeneration else { return false }
            // Invalidation must wait through both snapshot mutation and recognition enqueue.
            body()
            return true
        }
    }

    func invalidate(_ body: () -> Void) {
        lock.withLock {
            generation &+= 1
            body()
        }
    }

    func synchronize(_ body: () -> Void) {
        lock.withLock(body)
    }
}

final class TrackpadRecognitionAdmissionGate: @unchecked Sendable {
    private let lock = NSLock()

    func synchronize<T>(_ body: () throws -> T) rethrows -> T {
        try lock.withLock(body)
    }
}

final class TrackpadContactOccupancyTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var activeDeviceIDs = Set<UInt64>()

    func observe(_ frame: TrackpadContactFrame) {
        lock.withLock {
            if frame.contacts.isEmpty {
                activeDeviceIDs.remove(frame.deviceID)
            } else {
                activeDeviceIDs.insert(frame.deviceID)
            }
        }
    }

    func snapshot() -> Set<UInt64> {
        lock.withLock { activeDeviceIDs }
    }

    func reset() {
        lock.withLock { activeDeviceIDs.removeAll() }
    }
}

final class TrackpadLifecycleContactResetGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isActive = false
    private var outstandingDeviceIDs = Set<UInt64>()
    private var boundaryCompletionPending = false
    private var hasObservedSuppressedZero = false

    func beginSuppression(activeDeviceIDs: Set<UInt64>) {
        lock.withLock {
            if !isActive {
                hasObservedSuppressedZero = false
            }
            isActive = true
            boundaryCompletionPending = false
            outstandingDeviceIDs.formUnion(activeDeviceIDs)
        }
    }

    func shouldSuppress(_ frame: TrackpadContactFrame) -> Bool {
        lock.withLock {
            guard isActive else { return false }
            if frame.contacts.isEmpty {
                hasObservedSuppressedZero = true
                outstandingDeviceIDs.remove(frame.deviceID)
                boundaryCompletionPending = outstandingDeviceIDs.isEmpty
            } else {
                outstandingDeviceIDs.insert(frame.deviceID)
                boundaryCompletionPending = false
            }
            return true
        }
    }

    func completeSuppressedFrameProcessing() {
        lock.withLock {
            guard boundaryCompletionPending, outstandingDeviceIDs.isEmpty else { return }
            boundaryCompletionPending = false
            hasObservedSuppressedZero = false
            isActive = false
        }
    }

    func confirmConnectedDeviceIDs(_ connectedDeviceIDs: Set<UInt64>) {
        lock.withLock {
            guard isActive else { return }
            let hadOutstandingDevices = !outstandingDeviceIDs.isEmpty
            outstandingDeviceIDs.formIntersection(connectedDeviceIDs)
            if hadOutstandingDevices,
               outstandingDeviceIDs.isEmpty,
               hasObservedSuppressedZero {
                boundaryCompletionPending = false
                hasObservedSuppressedZero = false
                isActive = false
            }
        }
    }

    var isSuppressing: Bool {
        lock.withLock { isActive }
    }

    func reset() {
        lock.withLock {
            isActive = false
            boundaryCompletionPending = false
            hasObservedSuppressedZero = false
            outstandingDeviceIDs.removeAll()
        }
    }
}

final class TrackpadContactResetGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waitingForZeroDeviceIDs = Set<UInt64>()

    func beginSuppression(activeDeviceIDs: Set<UInt64>) {
        lock.withLock {
            waitingForZeroDeviceIDs.formUnion(activeDeviceIDs)
        }
    }

    func shouldSuppress(
        _ frame: TrackpadContactFrame,
        while suppressionIsActive: Bool
    ) -> Bool {
        lock.withLock {
            let wasBlocked = suppressionIsActive || !waitingForZeroDeviceIDs.isEmpty
            if wasBlocked, !frame.contacts.isEmpty {
                waitingForZeroDeviceIDs.insert(frame.deviceID)
            }
            if frame.contacts.isEmpty {
                waitingForZeroDeviceIDs.remove(frame.deviceID)
            }
            return wasBlocked
        }
    }

    func reset() {
        lock.withLock {
            waitingForZeroDeviceIDs.removeAll()
        }
    }
}

final class TrackpadRecognitionDeliveryRelay: @unchecked Sendable {
    typealias Handler = @Sendable (
        TrackpadGesture,
        UInt64,
        TrackpadGestureRecognitionDeliveryToken,
        TrackpadGestureRecognitionEvidence?,
        TimeInterval?
    ) -> Void

    private let lock = NSLock()
    private var handler: Handler?

    func activate(_ handler: @escaping Handler) {
        lock.withLock { self.handler = handler }
    }

    func deliver(
        _ gesture: TrackpadGesture,
        deviceID: UInt64,
        token: TrackpadGestureRecognitionDeliveryToken,
        evidence: TrackpadGestureRecognitionEvidence?,
        timestamp: TimeInterval?
    ) {
        let currentHandler: Handler? = lock.withLock { self.handler }
        currentHandler?(gesture, deviceID, token, evidence, timestamp)
    }
}

final class TrackpadTestingSnapshotDeliveryRelay: @unchecked Sendable {
    typealias Handler = @Sendable (TrackpadGestureTestSnapshotEmission) -> Void

    private let lock = NSLock()
    private var handler: Handler?

    func activate(_ handler: @escaping Handler) {
        lock.withLock { self.handler = handler }
    }

    func deliver(_ emission: TrackpadGestureTestSnapshotEmission) {
        let currentHandler: Handler? = lock.withLock { self.handler }
        currentHandler?(emission)
    }
}

final class TrackpadTipTapEpisodeDeliveryRelay: @unchecked Sendable {
    typealias Handler = @Sendable (TrackpadTipTapEpisodeID) -> Void

    private let lock = NSLock()
    private var handler: Handler?

    func activate(_ handler: @escaping Handler) {
        lock.withLock { self.handler = handler }
    }

    func deliver(_ episodeID: TrackpadTipTapEpisodeID) {
        let currentHandler: Handler? = lock.withLock { self.handler }
        currentHandler?(episodeID)
    }
}

typealias MultitouchDeviceTransport = TrackpadSensorTransport
typealias MultitouchDeviceDescriptor = TrackpadSensorDevice

struct TrackpadNativeClickRegistryEntry: Equatable, Sendable {
    let registryID: UInt64
    let ancestorRegistryIDs: Set<UInt64>

    func isRelated(to other: Self) -> Bool {
        registryID == other.registryID
            || ancestorRegistryIDs.contains(other.registryID)
            || other.ancestorRegistryIDs.contains(registryID)
    }
}

struct TrackpadNativeClickSourceInventorySnapshot: Equatable, Sendable {
    let mouseEntries: [TrackpadNativeClickRegistryEntry]
    let trackpadEntries: [TrackpadNativeClickRegistryEntry]

    var allowsContactInference: Bool {
        guard !mouseEntries.isEmpty, !trackpadEntries.isEmpty else { return false }
        return mouseEntries.allSatisfy { mouseEntry in
            trackpadEntries.contains { mouseEntry.isRelated(to: $0) }
        }
    }
}

enum TrackpadNativeClickSourceInventory {
    struct HIDUsagePair: Equatable, Sendable {
        let page: Int
        let usage: Int
    }

    enum HIDUsagePairs: Equatable, Sendable {
        case valid([HIDUsagePair])
        case containsPointingDevice
        case missing
        case malformed
    }

    struct HIDUsageMetadata: Equatable, Sendable {
        let primaryUsagePage: Int?
        let primaryUsage: Int?
        let usagePairs: HIDUsagePairs
    }

    enum ServiceRelevance: Equatable, Sendable {
        case relevant
        case irrelevant
        case indeterminate
    }

    enum RegistryEnumeration: Equatable, Sendable {
        case complete([TrackpadNativeClickRegistryEntry])
        case incomplete

        var entries: [TrackpadNativeClickRegistryEntry]? {
            guard case let .complete(entries) = self else { return nil }
            return entries
        }
    }

    static func computeAllowsContactInference() -> Bool {
        guard let mouseEntries = copyRegistryEntries(
            matchingClass: "IOHIDDevice",
            relevance: mouseServiceRelevance
        ).entries,
        let trackpadEntries = copyRegistryEntries(
            matchingClass: "AppleMultitouchDevice",
            relevance: { _ in .relevant }
        ).entries else {
            return false
        }
        return TrackpadNativeClickSourceInventorySnapshot(
            mouseEntries: mouseEntries,
            trackpadEntries: trackpadEntries
        ).allowsContactInference
    }

    private static func copyRegistryEntries(
        matchingClass: String,
        relevance: (io_service_t) -> ServiceRelevance
    ) -> RegistryEnumeration {
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching(matchingClass),
              IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
                == KERN_SUCCESS else {
            return .incomplete
        }
        defer {
            if iterator != 0 {
                IOObjectRelease(iterator)
            }
        }

        var entries: [TrackpadNativeClickRegistryEntry] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            switch relevance(service) {
            case .irrelevant:
                continue
            case .indeterminate:
                return .incomplete
            case .relevant:
                guard let entry = registryEntry(for: service) else { return .incomplete }
                entries.append(entry)
            }
        }
        guard iterator == 0 || IOIteratorIsValid(iterator) != 0 else {
            return .incomplete
        }
        return .complete(entries)
    }

    static func mouseServiceRelevance(for metadata: HIDUsageMetadata) -> ServiceRelevance {
        if let primaryUsagePage = metadata.primaryUsagePage,
           let primaryUsage = metadata.primaryUsage,
           isMouseEventCapable(page: primaryUsagePage, usage: primaryUsage) {
            return .relevant
        }
        switch metadata.usagePairs {
        case .containsPointingDevice:
            return .relevant
        case let .valid(pairs) where !pairs.isEmpty:
            return pairs.contains(where: {
                isMouseEventCapable(page: $0.page, usage: $0.usage)
            })
                ? .relevant
                : .irrelevant
        case .valid, .missing, .malformed:
            return .indeterminate
        }
    }

    static func enumerationResult(
        relevance: ServiceRelevance,
        entry: TrackpadNativeClickRegistryEntry?
    ) -> RegistryEnumeration {
        switch relevance {
        case .irrelevant:
            return .complete([])
        case .indeterminate:
            return .incomplete
        case .relevant:
            guard let entry else { return .incomplete }
            return .complete([entry])
        }
    }

    private static func mouseServiceRelevance(_ service: io_service_t) -> ServiceRelevance {
        mouseServiceRelevance(for: HIDUsageMetadata(
            primaryUsagePage: integerProperty(kIOHIDPrimaryUsagePageKey, of: service),
            primaryUsage: integerProperty(kIOHIDPrimaryUsageKey, of: service),
            usagePairs: usagePairsProperty(of: service)
        ))
    }

    private static func usagePairsProperty(of service: io_service_t) -> HIDUsagePairs {
        guard let value = IORegistryEntryCreateCFProperty(
            service,
            kIOHIDDeviceUsagePairsKey as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() else {
            return .missing
        }
        guard let pairs = value as? [Any], !pairs.isEmpty else {
            return .malformed
        }
        var parsed: [HIDUsagePair] = []
        var foundMalformedPair = false
        for value in pairs {
            guard let pair = value as? [String: Any],
                  let page = pair[kIOHIDDeviceUsagePageKey as String] as? NSNumber,
                  let usage = pair[kIOHIDDeviceUsageKey as String] as? NSNumber else {
                foundMalformedPair = true
                continue
            }
            let usagePair = HIDUsagePair(page: page.intValue, usage: usage.intValue)
            if isMouseEventCapable(page: usagePair.page, usage: usagePair.usage) {
                return .containsPointingDevice
            }
            parsed.append(usagePair)
        }
        return foundMalformedPair ? .malformed : .valid(parsed)
    }

    private static func isMouseEventCapable(page: Int, usage: Int) -> Bool {
        // Generic Desktop Pointer/Mouse and Digitizer collections can all surface ordinary
        // CoreGraphics mouse-button events. Treat the full Digitizer page conservatively because
        // pen tip, barrel, eraser, puck, and touch contacts may expose button semantics.
        (page == 0x01 && (usage == 0x01 || usage == 0x02)) || page == 0x0D
    }

    private static func integerProperty(_ key: String, of service: io_service_t) -> Int? {
        (IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? NSNumber)?.intValue
    }

    private static func registryEntry(
        for service: io_service_t
    ) -> TrackpadNativeClickRegistryEntry? {
        var registryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &registryID) == KERN_SUCCESS,
              registryID != 0 else {
            return nil
        }

        var ancestorRegistryIDs = Set<UInt64>()
        var iterator: io_iterator_t = 0
        let options = IOOptionBits(kIORegistryIterateParents | kIORegistryIterateRecursively)
        guard IORegistryEntryCreateIterator(
            service,
            kIOServicePlane,
            options,
            &iterator
        ) == KERN_SUCCESS else {
            return nil
        }
        defer {
            if iterator != 0 {
                IOObjectRelease(iterator)
            }
        }
        while true {
            let parent = IOIteratorNext(iterator)
            guard parent != 0 else { break }
            defer { IOObjectRelease(parent) }
            var parentRegistryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(parent, &parentRegistryID) == KERN_SUCCESS,
                  parentRegistryID != 0 else {
                return nil
            }
            ancestorRegistryIDs.insert(parentRegistryID)
        }
        guard iterator == 0 || IOIteratorIsValid(iterator) != 0 else { return nil }
        return TrackpadNativeClickRegistryEntry(
            registryID: registryID,
            ancestorRegistryIDs: ancestorRegistryIDs
        )
    }
}

final class TrackpadNativeClickSourceInventoryCache: @unchecked Sendable {
    private let lock = NSLock()
    private let refreshQueue: DispatchQueue
    private let loadVerdict: @Sendable () -> Bool
    private let requiresMonitoring: Bool
    private var isMonitoringAvailable: Bool
    private var verdict = false
    private var refreshGeneration: UInt64 = 0

    init(
        requiresMonitoring: Bool = false,
        refreshQueue: DispatchQueue = DispatchQueue(
            label: "cc.ggbond.mactools.trackpad-gestures.hid-inventory",
            qos: .utility
        ),
        loadVerdict: @escaping @Sendable () -> Bool = {
            TrackpadNativeClickSourceInventory.computeAllowsContactInference()
        }
    ) {
        self.requiresMonitoring = requiresMonitoring
        isMonitoringAvailable = !requiresMonitoring
        self.refreshQueue = refreshQueue
        self.loadVerdict = loadVerdict
    }

    func allowsContactInference() -> Bool {
        lock.withLock { verdict }
    }

    func invalidate() {
        lock.withLock {
            verdict = false
            refreshGeneration &+= 1
        }
    }

    func setMonitoringAvailable(_ isAvailable: Bool) {
        lock.withLock {
            isMonitoringAvailable = isAvailable
            if !isAvailable {
                verdict = false
                refreshGeneration &+= 1
            }
        }
    }

    func invalidateAndRefresh() {
        let generation: UInt64? = lock.withLock {
            verdict = false
            refreshGeneration &+= 1
            guard !requiresMonitoring || isMonitoringAvailable else { return nil }
            return refreshGeneration
        }
        guard let generation else { return }
        refreshQueue.async { [weak self] in
            guard let self else { return }
            let refreshedVerdict = loadVerdict()
            lock.withLock {
                guard refreshGeneration == generation,
                      !requiresMonitoring || isMonitoringAvailable else {
                    return
                }
                verdict = refreshedVerdict
            }
        }
    }

    #if DEBUG
    func waitUntilIdleForTests() {
        refreshQueue.sync {}
    }
    #endif
}

enum TrackpadNativeEventOriginClassifier {
    static func origin(
        for event: CGEvent,
        allowsContactInference: () -> Bool = { false }
    ) -> TrackpadMiddleClickArbiter.NativeEventOrigin {
        // A process-owned event is synthetic rather than an unattributed hardware event.
        guard event.getIntegerValueField(.eventSourceUnixProcessID) == 0 else {
            return .external
        }
        return allowsContactInference() ? .contactInferenceAllowed : .unknown
    }
}

@MainActor
protocol MultitouchDeviceSessionManaging: AnyObject {
    var onRecognized: ((
        TrackpadGesture,
        UInt64,
        TimeInterval?,
        TrackpadGestureRecognitionEvidence?
    ) -> Void)? { get set }
    var onAvailabilityChange: ((Bool) -> Void)? { get set }
    var isActive: Bool { get }
    var deviceCount: Int { get }

    @discardableResult
    func activate(gestures: Set<TrackpadGesture>) -> Bool
    func update(gestures: Set<TrackpadGesture>)
    func invalidatePendingDeliveriesForConfigurationChange()
    func updateNativeClickResolutions(_ resolutions: [TrackpadGesture: TrackpadNativeClickResolution])
    func resolveNativeClick(
        for gesture: TrackpadGesture,
        deviceID: UInt64,
        evidence: TrackpadGestureRecognitionEvidence?
    ) -> TrackpadNativeClickResolution?
    func updateTypingProtection(isEnabled: Bool, gracePeriod: TimeInterval)
    func updateMiddleClickGestures(_ gestures: Set<TrackpadGesture>)
    func resolveMiddleClick(for gesture: TrackpadGesture, deviceID: UInt64) -> Bool
    func deactivate()
}

extension MultitouchDeviceSessionManaging {
    func invalidatePendingDeliveriesForConfigurationChange() {}
    func updateNativeClickResolutions(
        _ resolutions: [TrackpadGesture: TrackpadNativeClickResolution]
    ) {}
    func resolveNativeClick(
        for gesture: TrackpadGesture,
        deviceID: UInt64,
        evidence: TrackpadGestureRecognitionEvidence? = nil
    ) -> TrackpadNativeClickResolution? { nil }
    func updateTypingProtection(isEnabled: Bool, gracePeriod: TimeInterval) {}
    func updateMiddleClickGestures(_ gestures: Set<TrackpadGesture>) {}
    func resolveMiddleClick(for gesture: TrackpadGesture, deviceID: UInt64) -> Bool { false }
}

@MainActor
protocol MultitouchDeviceTestingSessionManaging: AnyObject {
    var onTestingSnapshot: ((TrackpadGestureTestSnapshot) -> Void)? { get set }
    var onTestingReset: (() -> Void)? { get set }
    var testingDeviceDescriptors: [MultitouchDeviceDescriptor] { get }
    func updateTestingMode(_ mode: TrackpadGestureTestingMode?)
}

@MainActor
final class MultitouchDeviceSession: MultitouchDeviceSessionManaging,
    MultitouchDeviceTestingSessionManaging, @unchecked Sendable {
    private typealias CallbackContext = PluginCallbackContext<MultitouchDeviceSession>

    var onRecognized: ((
        TrackpadGesture,
        UInt64,
        TimeInterval?,
        TrackpadGestureRecognitionEvidence?
    ) -> Void)?
    var onAvailabilityChange: ((Bool) -> Void)?
    var onTestingSnapshot: ((TrackpadGestureTestSnapshot) -> Void)?
    var onTestingReset: (() -> Void)?

    private(set) var isActive = false
    var deviceCount: Int { driver.deviceCount }
    var testingDeviceDescriptors: [MultitouchDeviceDescriptor] {
        (driver as? SharedMultitouchFrameListener)?.devices ?? []
    }

    private let driver: any MultitouchFrameListening
    private let listenerLease: any TrackpadListenerLeaseManaging
    nonisolated private let middleClickCandidateTimeline: TrackpadMiddleClickCandidateTimeline
    // The CGEvent tap is delivered synchronously by the main CFRunLoop. That
    // callback runs on the main thread, but it is not entered through Swift's
    // MainActor executor on newer macOS releases. Keep the event processor
    // nonisolated so it can return the native event synchronously without an
    // unsafe MainActor.assumeIsolated hop.
    nonisolated private let middleClickCoordinator: TrackpadMiddleClickCoordinator
    private var nativeClickResolutions: [TrackpadGesture: TrackpadNativeClickResolution] = [:]
    nonisolated private let typingSuppressionGate = TrackpadTypingSuppressionGate()
    nonisolated private let recognitionGeneration: TrackpadGestureRecognitionGeneration
    nonisolated private let frameDeliveryGate = MultitouchFrameDeliveryGate()
    nonisolated private let recognitionAdmissionGate = TrackpadRecognitionAdmissionGate()
    nonisolated private let contactOccupancyTracker = TrackpadContactOccupancyTracker()
    nonisolated private let lifecycleContactResetGate = TrackpadLifecycleContactResetGate()
    nonisolated private let contactResetGate = TrackpadContactResetGate()
    nonisolated private let frameIngestionClock: @Sendable () -> TimeInterval
    nonisolated private let recognitionBeforeFrameProcessing: (@Sendable () -> Void)?
    nonisolated private let recognitionAfterCandidatePublication: (@Sendable () -> Void)?
    nonisolated private let recognitionWorker: TrackpadGestureRecognitionWorker
    nonisolated private let testingSnapshotRelay: TrackpadGestureTestSnapshotRelay
    nonisolated private let nativeClickSourceInventoryCache:
        TrackpadNativeClickSourceInventoryCache?

    private var configuredGestures = Set<TrackpadGesture>()
    private var testingMode: TrackpadGestureTestingMode?
    private struct PendingTipTapRecognition {
        let gesture: TrackpadGesture
        let deviceID: UInt64
        let deliveryToken: TrackpadGestureRecognitionDeliveryToken
        let episodeID: TrackpadTipTapEpisodeID
        let timestamp: TimeInterval?
    }

    private var pendingTipTapRecognitions: [TrackpadTipTapEpisodeID: PendingTipTapRecognition] = [:]
    private var isActivationRequested = false
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var eventTapCallbackPointer: UnsafeMutableRawPointer?
    private var wakeObserver: NSObjectProtocol?
    private var ioNotificationPort: IONotificationPortRef?
    private var ioNotificationSource: CFRunLoopSource?
    private var ioArrivalIterator: io_iterator_t = 0
    private var ioTerminationIterator: io_iterator_t = 0
    private var ioHIDArrivalIterator: io_iterator_t = 0
    private var ioHIDTerminationIterator: io_iterator_t = 0
    private var ioCallbackPointer: UnsafeMutableRawPointer?
    private var displayCallbackRegistered = false
    private var displayCallbackPointer: UnsafeMutableRawPointer?
    private var restartWorkItem: DispatchWorkItem?
    private var deviceObserverRetryWorkItem: DispatchWorkItem?
    private var isDeferringEventTapStop = false
    private let testEventTapStart: (@MainActor () -> Bool)?
    private let testEventTapStop: (@MainActor () -> Void)?
    private let wakeRestartDelay: TimeInterval
    private let deviceChangeRestartDelay: TimeInterval

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "MultitouchDeviceSession"
    )

    private static let recoveryRetryDelay: TimeInterval = 2

    init(
        driver: (any MultitouchFrameListening)? = nil,
        listenerLease: (any TrackpadListenerLeaseManaging)? = nil,
        testEventTapStart: (@MainActor () -> Bool)? = nil,
        testEventTapStop: (@MainActor () -> Void)? = nil,
        wakeRestartDelay: TimeInterval = 10,
        deviceChangeRestartDelay: TimeInterval = 2,
        recognitionBeforeFrameProcessing: (@Sendable () -> Void)? = nil,
        recognitionAfterCandidatePublication: (@Sendable () -> Void)? = nil,
        middleClickClock: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        synthesizeMiddleClick: @escaping () -> Void = {
            TrackpadMiddleClickEventPoster.postClick()
        },
        releaseMiddleButton: @escaping () -> Void = {
            TrackpadMiddleClickEventPoster.postButtonUp(
                eventSourceMarker: TrackpadMiddleClickCoordinator.replayMarker
            )
        },
        postMiddleClickEvent: @escaping (CGEvent) -> Void = {
            $0.post(tap: .cghidEventTap)
        },
        middleClickAllowsContactInference: (@Sendable () -> Bool)? = nil,
        middleClickEventOrigin: ((CGEvent) -> TrackpadMiddleClickArbiter.NativeEventOrigin)? = nil
    ) {
        let candidateTimeline = TrackpadMiddleClickCandidateTimeline()
        let inventoryCache = middleClickAllowsContactInference == nil
            ? TrackpadNativeClickSourceInventoryCache(requiresMonitoring: true)
            : nil
        let allowsContactInference: @Sendable () -> Bool = middleClickAllowsContactInference
            ?? { inventoryCache?.allowsContactInference() == true }
        let recognitionGeneration = TrackpadGestureRecognitionGeneration()
        let recognitionDeliveryRelay = TrackpadRecognitionDeliveryRelay()
        let tipTapCommitDeliveryRelay = TrackpadTipTapEpisodeDeliveryRelay()
        let tipTapAbandonmentDeliveryRelay = TrackpadTipTapEpisodeDeliveryRelay()
        let testingDeliveryRelay = TrackpadTestingSnapshotDeliveryRelay()
        let testingSnapshotRelay = TrackpadGestureTestSnapshotRelay {
            testingDeliveryRelay.deliver($0)
        }
        let recognitionWorker = TrackpadGestureRecognitionWorker(
            generation: recognitionGeneration,
            beforeFrameProcessing: recognitionBeforeFrameProcessing,
            testingSnapshotRelay: testingSnapshotRelay
        ) { gesture, deviceID, token, evidence, timestamp in
            recognitionDeliveryRelay.deliver(
                gesture,
                deviceID: deviceID,
                token: token,
                evidence: evidence,
                timestamp: timestamp
            )
        }
        self.driver = driver ?? SharedMultitouchFrameListener()
        self.listenerLease = listenerLease
            ?? TrackpadInProcessListenerLease()
        middleClickCandidateTimeline = candidateTimeline
        nativeClickSourceInventoryCache = inventoryCache
        self.recognitionGeneration = recognitionGeneration
        self.recognitionWorker = recognitionWorker
        self.testingSnapshotRelay = testingSnapshotRelay
        frameIngestionClock = middleClickClock
        self.recognitionBeforeFrameProcessing = recognitionBeforeFrameProcessing
        self.recognitionAfterCandidatePublication = recognitionAfterCandidatePublication
        middleClickCoordinator = TrackpadMiddleClickCoordinator(
            clock: middleClickClock,
            synthesizeMiddleClick: synthesizeMiddleClick,
            releaseMiddleButton: releaseMiddleButton,
            postEvent: postMiddleClickEvent,
            candidateTimeline: candidateTimeline,
            recognizePhysicalClick: { gesture, deviceID in
                recognitionWorker.recognizeNativeClick(gesture, deviceID: deviceID)
            },
            commitTipTapRecognition: { episodeID in
                tipTapCommitDeliveryRelay.deliver(episodeID)
            },
            abandonTipTapRecognition: { episodeID in
                tipTapAbandonmentDeliveryRelay.deliver(episodeID)
            },
            allowsContactInference: allowsContactInference,
            eventOrigin: middleClickEventOrigin
                ?? {
                    TrackpadNativeEventOriginClassifier.origin(
                        for: $0,
                        allowsContactInference: allowsContactInference
                    )
                }
        )
        self.testEventTapStart = testEventTapStart
        self.testEventTapStop = testEventTapStop
        self.wakeRestartDelay = wakeRestartDelay
        self.deviceChangeRestartDelay = deviceChangeRestartDelay
        recognitionDeliveryRelay.activate {
            [weak self] gesture, deviceID, token, evidence, timestamp in
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.isActive,
                      self.recognitionWorker.isCurrent(token) else {
                    return
                }
                if gesture.tipTapConfiguration != nil {
                    guard let tipTapEpisodeID = evidence?.tipTapEpisodeID else { return }
                    guard token.frameGeneration != nil else { return }
                    guard let resolution = self.nativeClickResolutions[gesture] else { return }
                    self.pendingTipTapRecognitions[tipTapEpisodeID] = PendingTipTapRecognition(
                        gesture: gesture,
                        deviceID: deviceID,
                        deliveryToken: token,
                        episodeID: tipTapEpisodeID,
                        timestamp: timestamp
                    )
                    guard self.middleClickCoordinator.recognize(
                        gesture: gesture,
                        deviceID: deviceID,
                        evidence: .tipTapEpisode(tipTapEpisodeID),
                        resolution: resolution
                    ) else {
                        self.pendingTipTapRecognitions.removeValue(forKey: tipTapEpisodeID)
                        return
                    }
                    return
                }
                self.onRecognized?(gesture, deviceID, timestamp, evidence)
            }
        }
        tipTapCommitDeliveryRelay.activate { [weak self] episodeID in
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      let pending = self.pendingTipTapRecognitions.removeValue(
                          forKey: episodeID
                      ) else {
                    return
                }
                guard self.isActive,
                      self.recognitionWorker.isCurrent(pending.deliveryToken) else {
                    return
                }
                self.onRecognized?(
                    pending.gesture,
                    pending.deviceID,
                    pending.timestamp,
                    .tipTapEpisode(pending.episodeID)
                )
            }
        }
        tipTapAbandonmentDeliveryRelay.activate { [weak self] episodeID in
            DispatchQueue.main.async { [weak self] in
                self?.pendingTipTapRecognitions.removeValue(forKey: episodeID)
            }
        }
        testingDeliveryRelay.activate { [weak self, testingSnapshotRelay] emission in
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.isActive,
                      self.recognitionWorker.isCurrent(.frame(
                          globalGeneration: emission.recognitionGeneration,
                          deviceID: emission.snapshot.deviceID,
                          deviceGeneration: emission.recognitionDeviceGeneration
                      )),
                      testingSnapshotRelay.isCurrent(emission.token) else {
                    return
                }
                let snapshot = emission.snapshot
                let descriptor = self.testingDeviceDescriptors.first {
                    $0.deviceID == snapshot.deviceID
                }
                self.onTestingSnapshot?(snapshot.withDescriptor(descriptor))
            }
        }
    }

    func setInputService(_ service: any TrackpadInputService) {
        (driver as? SharedMultitouchFrameListener)?.service = service
    }

    @discardableResult
    func activate(gestures: Set<TrackpadGesture>) -> Bool {
        configuredGestures = gestures
        isActivationRequested = true
        recognitionWorker.configure(gestures: gestures, reset: true)
        observeSystemWake()
        ensureMultitouchDeviceObservation()
        observeDisplayReconfiguration()

        if isActive {
            return true
        }
        guard listenerLease.acquire() else {
            logger.error("multitouch listener is unavailable to this MacTools process")
            onAvailabilityChange?(false)
            if listenerLease.shouldRetryAfterFailedAcquisition {
                scheduleRestart(after: Self.recoveryRetryDelay, reason: "listenerLeaseRetry")
            }
            return false
        }
        guard startEventTap() else {
            logger.error("failed to create event-tap lifecycle monitor")
            listenerLease.release()
            onAvailabilityChange?(false)
            scheduleRestart(after: Self.recoveryRetryDelay, reason: "initialRetry")
            return false
        }

        guard startDriver() else {
            logger.error("failed to register or start multitouch contact callbacks")
            stopEventTap(preservingTerminalNativePairs: true)
            listenerLease.release()
            onAvailabilityChange?(false)
            scheduleRestart(after: Self.recoveryRetryDelay, reason: "driverRetry")
            return false
        }
        cancelPendingRestart()
        isActive = true
        onAvailabilityChange?(true)
        logger.info("multitouch session started deviceCount=\(self.driver.deviceCount, privacy: .public)")
        return true
    }

    func update(gestures: Set<TrackpadGesture>) {
        guard configuredGestures != gestures else { return }
        if !pendingTipTapRecognitions.isEmpty {
            middleClickCoordinator.reset()
            pendingTipTapRecognitions.removeAll()
        }
        configuredGestures = gestures
        recognitionWorker.configure(gestures: gestures)
    }

    func invalidatePendingDeliveriesForConfigurationChange() {
        recognitionWorker.invalidateDeliveriesPreservingRecognizerState()
        middleClickCoordinator.invalidatePendingRecognitionsForConfigurationChange(
            episodeIDs: Set(pendingTipTapRecognitions.keys)
        )
        pendingTipTapRecognitions.removeAll()
    }

    func updateTestingMode(_ mode: TrackpadGestureTestingMode?) {
        guard testingMode != mode else { return }
        testingMode = mode
        beginContactSuppression()
        testingSnapshotRelay.update(mode: mode)
    }

    func updateMiddleClickGestures(_ gestures: Set<TrackpadGesture>) {
        updateNativeClickResolutions(
            Dictionary(uniqueKeysWithValues: gestures.map { ($0, .middleClick) })
        )
    }

    func resolveMiddleClick(for gesture: TrackpadGesture, deviceID: UInt64) -> Bool {
        resolveNativeClick(for: gesture, deviceID: deviceID) == .middleClick
    }

    func updateNativeClickResolutions(
        _ resolutions: [TrackpadGesture: TrackpadNativeClickResolution]
    ) {
        guard nativeClickResolutions != resolutions else { return }
        pendingTipTapRecognitions.removeAll()
        nativeClickResolutions = resolutions
        middleClickCoordinator.updateClickResolutions(resolutions)
    }

    func resolveNativeClick(
        for gesture: TrackpadGesture,
        deviceID: UInt64,
        evidence: TrackpadGestureRecognitionEvidence? = nil
    ) -> TrackpadNativeClickResolution? {
        // TipTap is finalized internally and delivered through onRecognized only after exact
        // native correlation. This synchronous compatibility path is for non-TipTap gestures.
        guard gesture.tipTapConfiguration == nil else { return nil }
        guard let resolution = nativeClickResolutions[gesture] else { return nil }
        return middleClickCoordinator.recognize(
            gesture: gesture,
            deviceID: deviceID,
            evidence: evidence,
            resolution: resolution
        )
            ? resolution
            : nil
    }

    func updateTypingProtection(isEnabled: Bool, gracePeriod: TimeInterval) {
        typingSuppressionGate.update(isEnabled: isEnabled, gracePeriod: gracePeriod)
    }

    func deactivate() {
        pendingTipTapRecognitions.removeAll()
        isActivationRequested = false
        cancelPendingRestart()
        removeDisplayReconfigurationObserver()
        removeMultitouchDeviceObserver()
        removeSystemWakeObserver()
        invalidateDriverCallbacks()
        driver.stop()
        stopEventTap(preservingTerminalNativePairs: true)
        listenerLease.release()
        typingSuppressionGate.reset()
        contactResetGate.reset()
        lifecycleContactResetGate.reset()
        recognitionWorker.configure(gestures: [], reset: true)
        testingMode = nil
        testingSnapshotRelay.update(mode: nil)
        isActive = false
        logger.info("multitouch session stopped")
    }

    private func startEventTap() -> Bool {
        cancelDeferredEventTapStop()
        if let testEventTapStart {
            return testEventTapStart()
        }
        if let eventTap, CFMachPortIsValid(eventTap) {
            return true
        }

        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDragged.rawValue)
            | (1 << CGEventType.rightMouseUp.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        let callback: CGEventTapCallBack = { proxy, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }
            let context = Unmanaged<CallbackContext>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                context.withOwner { session in
                    DispatchQueue.main.async { [weak session] in
                        session?.recoverFromEventTapDisable()
                    }
                }
                return Unmanaged.passUnretained(event)
            }

            return context.withOwner {
                $0.handleEventTapEvent(type: type, event: event, proxy: proxy)
            } ?? Unmanaged.passUnretained(event)
        }

        let context = CallbackContext(owner: self)
        let callbackPointer = Unmanaged.passRetained(context).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: callbackPointer
        ) else {
            context.invalidate()
            Unmanaged<CallbackContext>.fromOpaque(callbackPointer).release()
            return false
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            context.invalidate()
            Unmanaged<CallbackContext>.fromOpaque(callbackPointer).release()
            return false
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        eventTapSource = source
        eventTapCallbackPointer = callbackPointer
        return true
    }

    private func recoverFromEventTapDisable() {
        beginContactSuppression()
        pendingTipTapRecognitions.removeAll()
        typingSuppressionGate.reset()
        reenableEventTap()
    }

    private func reenableEventTap() {
        guard let eventTap, CFMachPortIsValid(eventTap) else {
            return
        }
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    private func stopEventTap(preservingTerminalNativePairs: Bool = false) {
        middleClickCoordinator.reset(
            preservingTerminalNativePairs: preservingTerminalNativePairs
        )
        typingSuppressionGate.reset()
        if preservingTerminalNativePairs,
           middleClickCoordinator.hasTerminalNativePairsAwaitingUp {
            beginDeferredEventTapStop()
            return
        }
        stopEventTapImmediately()
    }

    private func stopEventTapImmediately() {
        cancelDeferredEventTapStop()
        if let testEventTapStop {
            testEventTapStop()
            return
        }
        guard let eventTap else {
            eventTapSource = nil
            releaseEventTapCallbackContext()
            return
        }
        callbackContext(from: eventTapCallbackPointer)?.invalidate()
        CGEvent.tapEnable(tap: eventTap, enable: false)
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
        }
        CFMachPortInvalidate(eventTap)
        self.eventTap = nil
        eventTapSource = nil
        releaseEventTapCallbackContext()
    }

    private func beginDeferredEventTapStop() {
        // A consumed or converted Down owns its exact Up. Stopping on a timer would leak an
        // unmatched original Up; the bounded ownership table provides the fail-open path.
        isDeferringEventTapStop = true
    }

    private func finishDeferredEventTapStopIfPossible() {
        guard isDeferringEventTapStop,
              !middleClickCoordinator.hasTerminalNativePairsAwaitingUp else {
            return
        }
        stopEventTapImmediately()
    }

    private func cancelDeferredEventTapStop() {
        isDeferringEventTapStop = false
    }

    private func releaseEventTapCallbackContext() {
        guard let eventTapCallbackPointer else { return }
        callbackContext(from: eventTapCallbackPointer)?.invalidate()
        Unmanaged<CallbackContext>.fromOpaque(eventTapCallbackPointer).release()
        self.eventTapCallbackPointer = nil
    }

    private func beginLifecycleSuppression() {
        pendingTipTapRecognitions.removeAll()
        testingSnapshotRelay.update(mode: testingMode)
        onTestingReset?()
        frameDeliveryGate.synchronize {
            recognitionAdmissionGate.synchronize {
                lifecycleContactResetGate.beginSuppression(
                    activeDeviceIDs: contactOccupancyTracker.snapshot()
                )
            }
        }
        contactResetGate.reset()
        recognitionWorker.beginLifecycleSuppression()
        invalidateDriverCallbacks()
        middleClickCoordinator.reset(preservingTerminalNativePairs: true)
        typingSuppressionGate.reset()
    }

    private func restartListeners(reason: String) {
        guard isActivationRequested else {
            return
        }
        cancelPendingRestart()
        logger.info("restarting listeners reason=\(reason, privacy: .public)")
        beginLifecycleSuppression()
        ensureMultitouchDeviceObservation()
        isActive = false
        driver.stop()
        stopEventTap(preservingTerminalNativePairs: true)
        recognitionWorker.prepareLifecycleRestart(gestures: configuredGestures)
        guard listenerLease.acquire() else {
            logger.error("multitouch listener lease is owned by another MacTools process")
            onAvailabilityChange?(false)
            scheduleRestart(after: Self.recoveryRetryDelay, reason: "listenerLeaseRetry")
            return
        }
        guard startEventTap() else {
            logger.error("event tap could not be restored")
            listenerLease.release()
            onAvailabilityChange?(false)
            scheduleRestart(after: Self.recoveryRetryDelay, reason: "eventTapRetry")
            return
        }
        guard startDriver() else {
            logger.error("multitouch contact callbacks could not be restored")
            stopEventTap(preservingTerminalNativePairs: true)
            listenerLease.release()
            onAvailabilityChange?(false)
            scheduleRestart(after: Self.recoveryRetryDelay, reason: "driverRetry")
            return
        }
        isActive = true
        onAvailabilityChange?(true)
    }

    private func startDriver() -> Bool {
        let callbackGeneration = frameDeliveryGate.beginGeneration()
        let frameDeliveryGate = frameDeliveryGate
        let recognitionAdmissionGate = recognitionAdmissionGate
        let candidateTimeline = middleClickCandidateTimeline
        let typingSuppressionGate = typingSuppressionGate
        let contactOccupancyTracker = contactOccupancyTracker
        let lifecycleContactResetGate = lifecycleContactResetGate
        let contactResetGate = contactResetGate
        let frameIngestionClock = frameIngestionClock
        let recognitionWorker = recognitionWorker
        let recognitionAfterCandidatePublication = recognitionAfterCandidatePublication
        let middleClickCoordinator = middleClickCoordinator
        let started = driver.start(handler: {
            [
                frameDeliveryGate,
                recognitionAdmissionGate,
                candidateTimeline,
                typingSuppressionGate,
                contactOccupancyTracker,
                lifecycleContactResetGate,
                contactResetGate,
                frameIngestionClock,
                recognitionWorker,
                recognitionAfterCandidatePublication,
                middleClickCoordinator,
            ] frame in
            frameDeliveryGate.deliver(generation: callbackGeneration) {
                contactOccupancyTracker.observe(frame)
                let now = frameIngestionClock()
                let isTypingSuppressed = typingSuppressionGate.shouldSuppress(at: now)
                recognitionAdmissionGate.synchronize {
                    let lifecycleSuppressed = lifecycleContactResetGate.shouldSuppress(frame)
                    let suppressRecognition = lifecycleSuppressed
                        || contactResetGate.shouldSuppress(
                            frame,
                            while: isTypingSuppressed
                        )
                    if suppressRecognition {
                        if frame.contacts.isEmpty {
                            // Native clicks that pass through during suppression must not
                            // quarantine the first fresh post-reset candidate. Clear stale
                            // correlation state, then record the zero boundary for TipTap.
                            candidateTimeline.reset()
                            _ = candidateTimeline.observe(frame: frame, at: now)
                        } else {
                            candidateTimeline.reset()
                        }
                    } else {
                        let observation = candidateTimeline.observe(frame: frame, at: now)
                        recognitionAfterCandidatePublication?()
                        if observation.shouldNotifyCoordinator {
                            DispatchQueue.main.async {
                                middleClickCoordinator.candidateTimelineDidUpdate()
                            }
                        }
                        recognitionWorker.process(
                            frame,
                            suppressRecognition: false,
                            contactEpisodeID: observation.contactEpisodeID,
                            tipTapRecognitionIDs: observation.tipTapRecognitionIDs
                        )
                    }
                    if suppressRecognition {
                        recognitionWorker.process(frame, suppressRecognition: true)
                    }
                    if lifecycleSuppressed {
                        // Keep native-event admission closed until candidate cleanup and worker
                        // admission for the closing zero are both complete.
                        lifecycleContactResetGate.completeSuppressedFrameProcessing()
                    }
                }
            }
        })
        if !started {
            invalidateDriverCallbacks()
        } else {
            frameDeliveryGate.synchronize {
                recognitionAdmissionGate.synchronize {
                    lifecycleContactResetGate.confirmConnectedDeviceIDs(
                        driver.connectedDeviceIDs
                    )
                }
            }
        }
        return started
    }

    private func invalidateDriverCallbacks() {
        frameDeliveryGate.invalidate {
            recognitionAdmissionGate.synchronize {
                middleClickCandidateTimeline.reset()
                contactOccupancyTracker.reset()
            }
        }
    }

    private nonisolated func handleEventTapEvent(
        type: CGEventType,
        event: CGEvent,
        proxy: CGEventTapProxy? = nil
    ) -> Unmanaged<CGEvent>? {
        if type == .keyDown || type == .keyUp {
            if MacToolsSyntheticInputEvent.isMarked(event) {
                return Unmanaged.passUnretained(event)
            }

            let now = frameIngestionClock()
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            if type == .keyDown {
                typingSuppressionGate.observeKeyDown(keyCode: keyCode, at: now)
            } else {
                typingSuppressionGate.observeKeyUp(keyCode: keyCode, at: now)
            }
            if typingSuppressionGate.shouldSuppress(at: now) {
                beginContactSuppression()
            }
            return Unmanaged.passUnretained(event)
        }
        let result = recognitionAdmissionGate.synchronize {
            if lifecycleContactResetGate.isSuppressing {
                return middleClickCoordinator.handleLifecycleSuppressedNativeEvent(
                    type: type,
                    event: event
                )
            }
            return middleClickCoordinator.handleNativeEvent(type: type, event: event, proxy: proxy)
        }
        if result == nil, type == .leftMouseDown || type == .rightMouseDown,
           event.getIntegerValueField(.eventSourceUnixProcessID) == 0,
           !MacToolsSyntheticInputEvent.isMarked(event) {
            // The session tap never sees a physical down swallowed at HID.
            // Report it synchronously, outside the recognition lock.
            NotificationCenter.default.post(name: .macToolsWillClaimPhysicalInput, object: nil)
        }
        if !middleClickCoordinator.hasTerminalNativePairsAwaitingUp {
            DispatchQueue.main.async { [weak self] in
                self?.finishDeferredEventTapStopIfPossible()
            }
        }
        return result
    }

    private nonisolated func beginContactSuppression() {
        frameDeliveryGate.synchronize {
            recognitionAdmissionGate.synchronize {
                let activeDeviceIDs = contactOccupancyTracker.snapshot()
                contactResetGate.beginSuppression(activeDeviceIDs: activeDeviceIDs)
                recognitionWorker.beginSuppression(activeDeviceIDs: activeDeviceIDs)
                middleClickCoordinator.reset(preservingTerminalNativePairs: true)
            }
        }
    }

    private func scheduleRestart(after delay: TimeInterval, reason: String) {
        cancelPendingRestart()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.restartWorkItem = nil
            self.restartListeners(reason: reason)
        }
        restartWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelPendingRestart() {
        restartWorkItem?.cancel()
        restartWorkItem = nil
    }

    private func observeSystemWake() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.handleSystemWake()
            }
        }
    }

    private func handleSystemWake() {
        guard isActivationRequested else { return }
        beginLifecycleSuppression()
        scheduleRestart(after: wakeRestartDelay, reason: "systemWake")
    }

    private func removeSystemWakeObserver() {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    private func ensureMultitouchDeviceObservation() {
        let isAvailable = observeMultitouchDeviceChanges()
        nativeClickSourceInventoryCache?.setMonitoringAvailable(isAvailable)
        guard isAvailable else {
            scheduleDeviceObserverRetry()
            return
        }
        deviceObserverRetryWorkItem?.cancel()
        deviceObserverRetryWorkItem = nil
        nativeClickSourceInventoryCache?.invalidateAndRefresh()
    }

    private func scheduleDeviceObserverRetry() {
        guard isActivationRequested, deviceObserverRetryWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.deviceObserverRetryWorkItem = nil
            guard self.isActivationRequested else { return }
            self.ensureMultitouchDeviceObservation()
        }
        deviceObserverRetryWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.recoveryRetryDelay,
            execute: work
        )
    }

    @discardableResult
    private func observeMultitouchDeviceChanges() -> Bool {
        if ioNotificationPort != nil {
            return true
        }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            return false
        }
        guard let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() else {
            IONotificationPortDestroy(port)
            return false
        }

        let context = CallbackContext(owner: self)
        let callbackPointer = Unmanaged.passRetained(context).toOpaque()
        var arrivalIterator: io_iterator_t = 0
        let arrivalResult = IOServiceAddMatchingNotification(
            port,
            kIOFirstMatchNotification,
            IOServiceMatching("AppleMultitouchDevice"),
            { userData, iterator in
                MultitouchDeviceSession.drain(iterator)
                guard let userData else { return }
                let context = Unmanaged<CallbackContext>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                context.withOwner { session in
                    session.invalidateHIDInventoryForTopologyChange()
                    DispatchQueue.main.async { [weak session] in
                        session?.handleMultitouchDeviceChange(reason: "deviceArrived")
                    }
                }
            },
            callbackPointer,
            &arrivalIterator
        )

        guard arrivalResult == KERN_SUCCESS else {
            context.invalidate()
            Unmanaged<CallbackContext>.fromOpaque(callbackPointer).release()
            IONotificationPortDestroy(port)
            return false
        }

        var terminationIterator: io_iterator_t = 0
        let terminationResult = IOServiceAddMatchingNotification(
            port,
            kIOTerminatedNotification,
            IOServiceMatching("AppleMultitouchDevice"),
            { userData, iterator in
                MultitouchDeviceSession.drain(iterator)
                guard let userData else { return }
                let context = Unmanaged<CallbackContext>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                context.withOwner { session in
                    session.invalidateHIDInventoryForTopologyChange()
                    DispatchQueue.main.async { [weak session] in
                        session?.handleMultitouchDeviceChange(reason: "deviceRemoved")
                    }
                }
            },
            callbackPointer,
            &terminationIterator
        )

        guard terminationResult == KERN_SUCCESS else {
            context.invalidate()
            IOObjectRelease(arrivalIterator)
            IONotificationPortDestroy(port)
            Unmanaged<CallbackContext>.fromOpaque(callbackPointer).release()
            return false
        }

        var hidArrivalIterator: io_iterator_t = 0
        let hidArrivalResult = IOServiceAddMatchingNotification(
            port,
            kIOFirstMatchNotification,
            IOServiceMatching("IOHIDDevice"),
            { userData, iterator in
                MultitouchDeviceSession.drain(iterator)
                guard let userData else { return }
                let context = Unmanaged<CallbackContext>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                context.withOwner { session in
                    session.invalidateHIDInventoryForTopologyChange()
                    DispatchQueue.main.async { [weak session] in
                        session?.handleHIDInventoryChange()
                    }
                }
            },
            callbackPointer,
            &hidArrivalIterator
        )
        guard hidArrivalResult == KERN_SUCCESS else {
            context.invalidate()
            IOObjectRelease(arrivalIterator)
            IOObjectRelease(terminationIterator)
            IONotificationPortDestroy(port)
            Unmanaged<CallbackContext>.fromOpaque(callbackPointer).release()
            return false
        }

        var hidTerminationIterator: io_iterator_t = 0
        let hidTerminationResult = IOServiceAddMatchingNotification(
            port,
            kIOTerminatedNotification,
            IOServiceMatching("IOHIDDevice"),
            { userData, iterator in
                MultitouchDeviceSession.drain(iterator)
                guard let userData else { return }
                let context = Unmanaged<CallbackContext>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                context.withOwner { session in
                    session.invalidateHIDInventoryForTopologyChange()
                    DispatchQueue.main.async { [weak session] in
                        session?.handleHIDInventoryChange()
                    }
                }
            },
            callbackPointer,
            &hidTerminationIterator
        )
        guard hidTerminationResult == KERN_SUCCESS else {
            context.invalidate()
            IOObjectRelease(arrivalIterator)
            IOObjectRelease(terminationIterator)
            IOObjectRelease(hidArrivalIterator)
            IONotificationPortDestroy(port)
            Unmanaged<CallbackContext>.fromOpaque(callbackPointer).release()
            return false
        }

        Self.drain(arrivalIterator)
        Self.drain(terminationIterator)
        Self.drain(hidArrivalIterator)
        Self.drain(hidTerminationIterator)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        ioNotificationPort = port
        ioNotificationSource = source
        ioArrivalIterator = arrivalIterator
        ioTerminationIterator = terminationIterator
        ioHIDArrivalIterator = hidArrivalIterator
        ioHIDTerminationIterator = hidTerminationIterator
        ioCallbackPointer = callbackPointer
        return true
    }

    private func removeMultitouchDeviceObserver() {
        deviceObserverRetryWorkItem?.cancel()
        deviceObserverRetryWorkItem = nil
        nativeClickSourceInventoryCache?.setMonitoringAvailable(false)
        callbackContext(from: ioCallbackPointer)?.invalidate()
        if ioArrivalIterator != 0 {
            IOObjectRelease(ioArrivalIterator)
            ioArrivalIterator = 0
        }
        if ioTerminationIterator != 0 {
            IOObjectRelease(ioTerminationIterator)
            ioTerminationIterator = 0
        }
        if ioHIDArrivalIterator != 0 {
            IOObjectRelease(ioHIDArrivalIterator)
            ioHIDArrivalIterator = 0
        }
        if ioHIDTerminationIterator != 0 {
            IOObjectRelease(ioHIDTerminationIterator)
            ioHIDTerminationIterator = 0
        }
        if let ioNotificationSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), ioNotificationSource, .commonModes)
            self.ioNotificationSource = nil
        }
        if let ioNotificationPort {
            IONotificationPortDestroy(ioNotificationPort)
            self.ioNotificationPort = nil
        }
        if let ioCallbackPointer {
            Unmanaged<CallbackContext>.fromOpaque(ioCallbackPointer).release()
            self.ioCallbackPointer = nil
        }
    }

    private func handleMultitouchDeviceChange(reason: String) {
        guard isActivationRequested else { return }
        beginLifecycleSuppression()
        nativeClickSourceInventoryCache?.invalidateAndRefresh()
        scheduleRestart(after: deviceChangeRestartDelay, reason: reason)
    }

    private func handleHIDInventoryChange() {
        nativeClickSourceInventoryCache?.invalidateAndRefresh()
    }

    private nonisolated func invalidateHIDInventoryForTopologyChange() {
        nativeClickSourceInventoryCache?.invalidate()
    }

    private nonisolated static func drain(_ iterator: io_iterator_t) {
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { return }
            IOObjectRelease(service)
        }
    }

    private nonisolated static let displayCallback: CGDisplayReconfigurationCallBack = {
        _, flags, userInfo in
        let relevant: CGDisplayChangeSummaryFlags = [.setModeFlag, .addFlag, .removeFlag, .disabledFlag]
        guard !flags.intersection(relevant).isEmpty, let userInfo else {
            return
        }
        let context = Unmanaged<CallbackContext>
            .fromOpaque(userInfo)
            .takeUnretainedValue()
        context.withOwner { session in
            DispatchQueue.main.async { [weak session] in
                session?.scheduleRestart(after: 2, reason: "displayReconfigured")
            }
        }
    }

    private func observeDisplayReconfiguration() {
        guard !displayCallbackRegistered else { return }
        let context = CallbackContext(owner: self)
        let callbackPointer = Unmanaged.passRetained(context).toOpaque()
        if CGDisplayRegisterReconfigurationCallback(
            Self.displayCallback,
            callbackPointer
        ) == .success {
            displayCallbackRegistered = true
            displayCallbackPointer = callbackPointer
        } else {
            context.invalidate()
            Unmanaged<CallbackContext>.fromOpaque(callbackPointer).release()
        }
    }

    private func removeDisplayReconfigurationObserver() {
        guard displayCallbackRegistered else { return }
        callbackContext(from: displayCallbackPointer)?.invalidate()
        CGDisplayRemoveReconfigurationCallback(
            Self.displayCallback,
            displayCallbackPointer
        )
        displayCallbackRegistered = false
        if let displayCallbackPointer {
            Unmanaged<CallbackContext>.fromOpaque(displayCallbackPointer).release()
            self.displayCallbackPointer = nil
        }
    }

    private nonisolated func callbackContext(
        from pointer: UnsafeMutableRawPointer?
    ) -> CallbackContext? {
        guard let pointer else { return nil }
        return Unmanaged<CallbackContext>.fromOpaque(pointer).takeUnretainedValue()
    }

    #if DEBUG
    func restartImmediatelyForTests() {
        restartListeners(reason: "test")
    }

    func simulateWakeRecoveryForTests() {
        restartListeners(reason: "systemWakeTest")
    }

    func simulateWakeNotificationForTests() {
        handleSystemWake()
    }

    func simulateDeviceRecoveryForTests() {
        restartListeners(reason: "deviceReenumeratedTest")
    }

    func simulateDeviceRemovalNotificationForTests() {
        handleMultitouchDeviceChange(reason: "deviceRemovedTest")
    }

    nonisolated func handleNativeEventForTests(type: CGEventType, event: CGEvent) -> Bool {
        handleEventTapEvent(type: type, event: event) == nil
    }

    func simulateEventTapDisableForTests() {
        recoverFromEventTapDisable()
    }

    func waitForRecognitionForTests() {
        recognitionWorker.waitUntilIdleForTests()
    }

    var pendingTipTapRecognitionCountForTests: Int {
        pendingTipTapRecognitions.count
    }

    func expireMiddleClickStateForTests() {
        middleClickCoordinator.candidateTimelineDidUpdate()
    }
    #endif
}
