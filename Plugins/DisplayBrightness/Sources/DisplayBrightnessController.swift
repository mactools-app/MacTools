import AppKit
import CoreGraphics
import Foundation
import MacToolsPluginKit

private final class WeakBrightnessControllerRef: @unchecked Sendable {
    weak var value: DisplayBrightnessController?

    init(_ value: DisplayBrightnessController?) {
        self.value = value
    }
}

private final class BrightnessWriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private var nextWriteDate: [CGDirectDisplayID: Date] = [:]

    func waitTurn(for displayID: CGDirectDisplayID, minimumInterval: TimeInterval) {
        let delay = lock.withLock { () -> TimeInterval in
            let now = Date()
            let scheduledDate = max(now, nextWriteDate[displayID] ?? now)
            nextWriteDate[displayID] = scheduledDate.addingTimeInterval(minimumInterval)
            return max(0, scheduledDate.timeIntervalSince(now))
        }

        guard delay > 0 else {
            return
        }

        Thread.sleep(forTimeInterval: delay)
    }
}

@MainActor
final class DisplayBrightnessController: DisplayBrightnessControlling {
    private enum ReadRequirement: Int, Comparable, Sendable {
        case none
        case fresh
        case verified

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        func read(from backend: any DisplayBrightnessBackend) throws -> Double {
            switch self {
            case .none: try backend.readBrightness()
            case .fresh: try backend.readFreshBrightness()
            case .verified: try backend.readVerifiedBrightness()
            }
        }
    }

    private struct OrdinaryWrite: Sendable {
        let generation: UInt64
        let requiresKnownLevel: Bool
    }

    private struct ManagedDisplay {
        var display: DisplayInfo
        let actionIdentifier: String?
        var backend: any DisplayBrightnessBackend
        var currentBrightness: Double
        var lastCommittedBrightness: Double
        var pendingBrightness: Double?
        var pendingWriteID: UInt64?
        var writeInFlight = false
        var inFlightWriteID: UInt64?
        var inFlightTarget: Double?
        var scheduledFlush: DispatchWorkItem?
        var pendingReadbackAfterWrite = false
        var pendingOrdinaryWrite: OrdinaryWrite?
        var lastWriteError: String?
        var hasBrightnessValue = false
        var readRequirement: ReadRequirement = .none
        var readID: UInt64?

        var reusableDDCState: DDCBrightnessBackend.CachedState? {
            guard hasBrightnessValue, readRequirement == .none, pendingWriteID == nil, !writeInFlight else {
                return nil
            }
            return (backend as? DDCBrightnessBackend)?.cachedState(level: lastCommittedBrightness)
        }

        mutating func clearPendingWrite() {
            scheduledFlush?.cancel()
            scheduledFlush = nil
            pendingBrightness = nil
            pendingWriteID = nil
            pendingReadbackAfterWrite = false
            pendingOrdinaryWrite = nil
        }
    }

    private enum RetiredWriteResolution {
        case actualOutcome
        case invalidated
    }

    private struct RetiredInFlightWrite {
        let backend: any DisplayBrightnessBackend
        let displayID: CGDirectDisplayID
        let actionIdentifier: String?
        let readRequirement: ReadRequirement
        var resolution: RetiredWriteResolution

        func matches(displayID: CGDirectDisplayID, identifier: String?) -> Bool {
            self.displayID == displayID || (identifier != nil && actionIdentifier == identifier)
        }

        func recoveryRequirement(for identifier: String?) -> ReadRequirement {
            if readRequirement == .verified && (identifier == nil || actionIdentifier != identifier) {
                return .fresh
            }
            return readRequirement
        }
    }

    var onStateChange: (() -> Void)?

    private let displayProvider: DisplayProviding
    private let displayIdentifier: @Sendable (CGDirectDisplayID) -> String?
    private let backendBuilder: DisplayBrightnessBackendBuilding
    private let localization: PluginLocalization
    private let logger = DisplayBrightnessLog.controller
    private let shortWriteDelay: TimeInterval
    private let minimumWriteInterval: TimeInterval
    private let writeTimeout: Duration
    private let writeGate = BrightnessWriteGate()
    private let readQueue = DispatchQueue(label: "cc.ggbond.mactools.brightness.read", qos: .userInitiated)
    private var readWorkItems: [CGDirectDisplayID: DispatchWorkItem] = [:]
    private var nextReadID: UInt64 = 0

    private var previousDisplays: [CGDirectDisplayID: DisplayInfo] = [:]
    private var previousIdentifiers: [CGDirectDisplayID: String] = [:]
    private var previouslyManagedDisplayIDs: Set<CGDirectDisplayID> = []
    private var previouslyManagedDDCIdentifiers: Set<String> = []
    private var disconnectedDDCStates: [String: DDCBrightnessBackend.CachedState] = [:]
    private var managedDisplays: [CGDirectDisplayID: ManagedDisplay] = [:]
    private var displayOrder: [CGDirectDisplayID] = []
    private var lastErrorMessage: String?
    private var nextWriteID: UInt64 = 0
    private var writePermits: [UInt64: DisplayActionWritePermit] = [:]
    private var writeWaiters: [UInt64: CheckedContinuation<DisplayBrightnessWriteResult, Never>] = [:]
    private var writeTimeoutTasks: [UInt64: Task<Void, Never>] = [:]
    private var waiterDisplayIDs: [UInt64: CGDirectDisplayID] = [:]
    private var retiredReadRequirements: [String: ReadRequirement] = [:]
    private var retiredInFlightWrites: [UInt64: RetiredInFlightWrite] = [:]
    private var replacedBackendsAwaitingWrites: [UInt64: [any DisplayBrightnessBackend]] = [:]
    private var invalidatedInFlightWriteIDs: Set<UInt64> = []
    private var terminateObserver: NSObjectProtocol?

    var pendingWriteTimeoutCount: Int { writeTimeoutTasks.count }

    #if DEBUG
    func waitForScheduledReadsForTests() async {
        await withCheckedContinuation { continuation in
            readQueue.async {
                Task { @MainActor in continuation.resume() }
            }
        }
    }
    #endif

    init(
        displayProvider: DisplayProviding = SystemDisplayService(),
        displayIdentifier: @escaping @Sendable (CGDirectDisplayID) -> String? = DisplayActionTarget.identifier(for:),
        backendBuilder: DisplayBrightnessBackendBuilding? = nil,
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        shortWriteDelay: TimeInterval = 0.08,
        minimumWriteInterval: TimeInterval = 0.08,
        writeTimeout: Duration = .seconds(10)
    ) {
        self.displayProvider = displayProvider
        self.displayIdentifier = displayIdentifier
        self.localization = localization
        self.backendBuilder = backendBuilder ?? SystemDisplayBrightnessBackendBuilder(
            resolveArm64Services: Arm64DDCServiceMatcher.resolveServices
        )
        self.shortWriteDelay = shortWriteDelay
        self.minimumWriteInterval = minimumWriteInterval
        self.writeTimeout = writeTimeout

        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.cleanupAll()
            }
        }
    }

    func refresh() {
        refresh(topologyChanged: false)
    }

    func refreshDisplayTopology() {
        refresh(topologyChanged: true)
    }

    private func refresh(topologyChanged: Bool) {
        if topologyChanged {
            // A retained native or Gamma backend can still have a read from the old topology.
            cancelReads()
        }
        let displays = displayProvider.listConnectedDisplays()
        let identifiers = Dictionary(uniqueKeysWithValues: displays.compactMap { display in
            displayIdentifier(display.id).map { (display.id, $0) }
        })
        let displayInventory = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) })
        let rediscoverServices = topologyChanged || displayInventory != previousDisplays || identifiers != previousIdentifiers
        previousDisplays = displayInventory
        previousIdentifiers = identifiers
        let reusableDisplays = managedDisplays.filter { id, previous in
            guard let display = displayInventory[id],
                  !(topologyChanged && previous.backend.kind == .ddc),
                  !(rediscoverServices && previous.backend.usesDiscoveredService) else { return false }
            if let identifier = identifiers[id] {
                return previous.actionIdentifier == identifier
            }
            return previous.actionIdentifier == nil
                && DisplayActionTarget.sameDisplayWithoutUUID(previous.display, display)
        }
        // Cancel old exact permits before potentially slow hardware discovery.
        for (id, previous) in managedDisplays where reusableDisplays[id] == nil {
            if let writeID = previous.inFlightWriteID { writePermits[writeID]?.cancel() }
        }
        let previousBackends = reusableDisplays.mapValues(\.backend)
        let nextBackends = backendBuilder.backends(for: displays, previous: previousBackends)
        let nextDisplayIDs = Set(displays.map(\.id)).intersection(nextBackends.keys)

        let retainedDisplays = reusableDisplays.filter { id, previous in
            guard nextDisplayIDs.contains(id), let backend = nextBackends[id] else { return false }
            // An exact write owns its backend through verification.
            return previous.backend === backend || previous.inFlightWriteID.flatMap { writePermits[$0] } == nil
        }
        for (id, old) in managedDisplays where displayInventory[id] == nil {
            if let identifier = old.actionIdentifier, let state = old.reusableDDCState, state.maximum != nil {
                disconnectedDDCStates[identifier] = state
            }
        }
        cleanupDisconnectedDisplays(keeping: Set(retainedDisplays.keys))

        var nextManagedDisplays: [CGDirectDisplayID: ManagedDisplay] = [:]
        var nextDisplayOrder: [CGDirectDisplayID] = []

        for display in displays {
            guard let backend = nextBackends[display.id] else {
                continue
            }

            let previous = retainedDisplays[display.id]
            let identifier = identifiers[display.id]
            let old = managedDisplays[display.id]
            let canReuseReading = previous.map { $0.backend === backend } ?? false
            let disconnectedState = identifier.flatMap { disconnectedDDCStates.removeValue(forKey: $0) }
            let oldState = canReuseReading ? nil : old.flatMap { old -> DDCBrightnessBackend.CachedState? in
                guard old.actionIdentifier == identifier,
                      identifier != nil || DisplayActionTarget.sameDisplayWithoutUUID(old.display, display) else {
                    return nil
                }
                return old.reusableDDCState
            }
            let preservedBrightness: Double?
            if !canReuseReading, let state = oldState ?? disconnectedState,
               let newDDC = backend as? DDCBrightnessBackend,
               newDDC.reuseCachedState(state) {
                preservedBrightness = state.level
            } else {
                preservedBrightness = nil
            }
            let retiredRequirement = identifier.flatMap { retiredReadRequirements[$0] } ?? .none
            var readRequirement = max(previous?.readRequirement ?? .none, retiredRequirement)
            for write in retiredInFlightWrites.values where write.matches(displayID: display.id, identifier: identifier) {
                readRequirement = max(readRequirement, write.recoveryRequirement(for: identifier))
            }
            let knownDDCIdentifier = identifier.map { previouslyManagedDDCIdentifiers.contains($0) } == true
            let knownNumericID = previouslyManagedDisplayIDs.contains(display.id)
            let needsDDCBaseline = (backend.kind == .ddc && (knownNumericID || knownDDCIdentifier))
                || (knownNumericID && old?.backend.kind == .ddc)
            if !canReuseReading && preservedBrightness == nil && needsDDCBaseline {
                readRequirement = max(readRequirement, .fresh)
            }
            if !canReuseReading {
                readWorkItems.removeValue(forKey: display.id)?.cancel()
                if let previous {
                    if let writeID = previous.inFlightWriteID {
                        replacedBackendsAwaitingWrites[writeID, default: []].append(previous.backend)
                    } else {
                        previous.backend.cleanup()
                    }
                }
            }
            let brightness = previous?.currentBrightness ?? preservedBrightness ?? 1

            nextManagedDisplays[display.id] = ManagedDisplay(
                display: display,
                actionIdentifier: identifier,
                backend: backend,
                currentBrightness: previous?.pendingBrightness ?? brightness,
                lastCommittedBrightness: previous?.lastCommittedBrightness ?? brightness,
                pendingBrightness: previous?.pendingBrightness,
                pendingWriteID: previous?.pendingWriteID,
                writeInFlight: previous?.writeInFlight ?? false,
                inFlightWriteID: previous?.inFlightWriteID,
                inFlightTarget: previous?.inFlightTarget,
                scheduledFlush: previous?.scheduledFlush,
                pendingReadbackAfterWrite: previous?.pendingReadbackAfterWrite ?? false,
                pendingOrdinaryWrite: previous?.pendingOrdinaryWrite,
                lastWriteError: previous?.lastWriteError,
                hasBrightnessValue: readRequirement == .none
                    && (preservedBrightness != nil || (canReuseReading && previous?.hasBrightnessValue == true)),
                readRequirement: readRequirement,
                readID: canReuseReading ? previous?.readID : nil
            )
            nextDisplayOrder.append(display.id)
        }

        for identifier in nextManagedDisplays.values.compactMap(\.actionIdentifier) {
            retiredReadRequirements.removeValue(forKey: identifier)
        }
        previouslyManagedDisplayIDs.formUnion(nextManagedDisplays.keys)
        previouslyManagedDDCIdentifiers.formUnion(nextManagedDisplays.values.compactMap {
            $0.backend.kind == .ddc ? $0.actionIdentifier : nil
        })
        managedDisplays = nextManagedDisplays
        displayOrder = nextDisplayOrder

        if !nextManagedDisplays.isEmpty {
            lastErrorMessage = nil
        }
        for displayID in displayOrder {
            scheduleRead(for: displayID)
        }
        onStateChange?()
    }

    func snapshot() -> DisplayBrightnessSnapshot {
        let displays = displayOrder.compactMap { displayID -> DisplayBrightnessDisplay? in
            guard let managedDisplay = managedDisplays[displayID] else {
                return nil
            }

            return DisplayBrightnessDisplay(
                display: managedDisplay.display,
                brightness: managedDisplay.currentBrightness,
                isPendingWrite: managedDisplay.pendingBrightness != nil || managedDisplay.writeInFlight,
                isReady: managedDisplay.hasBrightnessValue,
                needsReadBeforeRelative: managedDisplay.readRequirement != .none,
                isSettingExactLevel: hasExactWrite(for: managedDisplay)
            )
        }

        return DisplayBrightnessSnapshot(
            displays: displays,
            errorMessage: lastErrorMessage
        )
    }

    func actionIdentifier(for displayID: CGDirectDisplayID) -> String? {
        managedDisplays[displayID]?.actionIdentifier
    }

    func exactBrightnessAvailability(_ value: Double, for displayID: CGDirectDisplayID) -> ActionAvailability {
        guard let backend = managedDisplays[displayID]?.backend else {
            return .unavailable(PluginKitLocalization.actionUnavailable)
        }
        if let error = backend.exactActionError(for: value) {
            return .unavailable(error.message(localization: localization))
        }
        return .available
    }

    func isDisplayConnected(_ display: DisplayInfo) -> Bool {
        displayProvider.listConnectedDisplays().contains(display)
    }

    /// Reads the active backend without presenting a cached or requested value as an observation.
    /// The backend may change or disappear while the read is running.
    func observeBrightness(for displayID: CGDirectDisplayID) async -> DisplayBrightnessObservation? {
        guard let managed = managedDisplays[displayID] else { return nil }
        let backend = managed.backend
        let writeRevision = nextWriteID
        let pendingAtStart = managed.pendingBrightness != nil || managed.writeInFlight
        let read: @Sendable () -> Double? = {
            guard let value = try? backend.readBrightness(), value.isFinite,
                  (0...1).contains(value) else { return nil }
            return value
        }
        let observed: Double?
        if backend.kind == .shade {
            // Shade refreshes AppKit overlays while reading. Keep the same ordering
            // and pending-write exclusion as scheduleRead instead of detaching it.
            observed = pendingAtStart ? nil : read()
        } else {
            observed = await Task.detached(priority: .userInitiated, operation: read).value
        }
        guard nextWriteID == writeRevision,
              let current = managedDisplays[displayID], current.backend === backend,
              current.display == managed.display, isDisplayConnected(managed.display) else { return nil }
        return DisplayBrightnessObservation(
            value: observed,
            backend: backend.kind,
            isPendingWrite: pendingAtStart || current.pendingBrightness != nil || current.writeInFlight
        )
    }

    func adjustBrightness(by delta: Double, for displayID: CGDirectDisplayID, phase: PluginPanelAction.SliderPhase) {
        guard let managed = managedDisplays[displayID], managed.hasBrightnessValue && managed.readRequirement == .none else { return }
        enqueueBrightness(managed.currentBrightness + delta, for: displayID, phase: phase,
                      writeID: makeWriteID(), requiresKnownLevel: true)
    }

    func adjustBrightnessAndWait(by delta: Double, for displayID: CGDirectDisplayID) async -> DisplayBrightnessWriteResult {
        guard let managed = managedDisplays[displayID], managed.hasBrightnessValue && managed.readRequirement == .none else {
            return .failed(message: PluginKitLocalization.actionUnavailable)
        }
        return await setBrightnessAndWait(
            managed.currentBrightness + delta, for: displayID, permit: nil, requiresKnownLevel: true
        )
    }

    func setBrightness(
        _ value: Double,
        for displayID: CGDirectDisplayID,
        phase: PluginPanelAction.SliderPhase
    ) {
        enqueueBrightness(
            value,
            for: displayID,
            phase: phase,
            writeID: makeWriteID()
        )
    }

    func setBrightnessAndWait(
        _ value: Double,
        for displayID: CGDirectDisplayID
    ) async -> DisplayBrightnessWriteResult {
        await setBrightnessAndWait(value, for: displayID, permit: nil)
    }

    func setExactBrightnessAndWait(
        _ value: Double,
        for displayID: CGDirectDisplayID,
        identifier: String
    ) async -> DisplayBrightnessWriteResult {
        let permit = DisplayActionWritePermit { [displayIdentifier] in
            displayIdentifier(displayID) == identifier
        }
        guard actionIdentifier(for: displayID) == identifier, permit.canWrite, !Task.isCancelled else {
            return .failed(message: PluginKitLocalization.actionUnavailable)
        }
        return await setBrightnessAndWait(value, for: displayID, permit: permit)
    }

    private func setBrightnessAndWait(
        _ value: Double,
        for displayID: CGDirectDisplayID,
        permit: DisplayActionWritePermit?,
        requiresKnownLevel: Bool = false
    ) async -> DisplayBrightnessWriteResult {
        let writeID = makeWriteID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                writePermits[writeID] = permit
                writeWaiters[writeID] = continuation
                waiterDisplayIDs[writeID] = displayID
                let timeout = writeTimeout
                writeTimeoutTasks[writeID] = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    self?.timeOutWrite(writeID)
                }
                enqueueBrightness(
                    value,
                    for: displayID,
                    phase: .ended,
                    writeID: writeID,
                    requiresKnownLevel: requiresKnownLevel
                )
            }
        } onCancel: {
            permit?.cancel()
            Task { @MainActor [weak self] in
                self?.failWriteUnlessInFlight(
                    writeID,
                    message: PluginKitLocalization.actionUnavailable,
                    invalidateAfterDispatch: true
                )
            }
        }
    }

    func cancelOutstandingWrites() {
        for permit in writePermits.values { permit.cancel() }
        cancelReads()
        for (_, managedDisplay) in Array(managedDisplays) {
            managedDisplay.scheduledFlush?.cancel()
            if let writeID = managedDisplay.pendingWriteID {
                resolveWrite(
                    writeID,
                    with: .failed(message: PluginKitLocalization.actionUnavailable)
                )
            }
            retireDisplay(managedDisplay)
        }
        managedDisplays.removeAll()
        disconnectedDDCStates.removeAll()
        displayOrder.removeAll()
        lastErrorMessage = nil
        onStateChange?()
    }

    private func enqueueBrightness(
        _ value: Double,
        for displayID: CGDirectDisplayID,
        phase: PluginPanelAction.SliderPhase,
        writeID: UInt64,
        requiresKnownLevel: Bool = false
    ) {
        if managedDisplays[displayID] == nil {
            refresh()
        }

        guard var managedDisplay = managedDisplays[displayID] else {
            let message = DisplayBrightnessControllerError.displayUnavailable(
                displayID: displayID
            ).localizedDescription(localization: localization)
            lastErrorMessage = message
            resolveWrite(writeID, with: .failed(message: message))
            onStateChange?()
            return
        }

        guard managedDisplay.hasBrightnessValue || writePermits[writeID] != nil
                || (managedDisplay.readRequirement != .none && !requiresKnownLevel) else {
            resolveWrite(writeID, with: .failed(message: PluginKitLocalization.actionUnavailable))
            return
        }
        // Relative adjustments cannot use an exact write's optimistic target.
        if requiresKnownLevel && (hasExactWrite(for: managedDisplay) || !isCurrentTarget(managedDisplay)) {
            resolveWrite(writeID, with: .failed(message: PluginKitLocalization.actionUnavailable))
            return
        }
        readWorkItems.removeValue(forKey: displayID)?.cancel()
        managedDisplay.readID = nil

        if let supersededWriteID = managedDisplay.pendingWriteID {
            resolveWrite(
                supersededWriteID,
                with: .failed(message: PluginKitLocalization.actionUnavailable)
            )
        }
        let clampedValue = Self.clamp(value)
        managedDisplay.currentBrightness = clampedValue
        managedDisplay.pendingBrightness = clampedValue
        managedDisplay.pendingWriteID = writeID
        managedDisplay.scheduledFlush?.cancel()
        managedDisplay.scheduledFlush = nil
        managedDisplay.pendingReadbackAfterWrite = phase == .ended
        managedDisplay.pendingOrdinaryWrite = writePermits[writeID] == nil
            ? OrdinaryWrite(generation: DisplayDDCIdentity.bindingGeneration, requiresKnownLevel: requiresKnownLevel)
            : nil
        managedDisplay.lastWriteError = nil
        lastErrorMessage = nil
        managedDisplays[displayID] = managedDisplay

        let delay = phase == .ended ? 0 : shortWriteDelay
        scheduleWrite(for: displayID, delay: delay)

        onStateChange?()
    }

    private func scheduleRead(for displayID: CGDirectDisplayID) {
        guard var managedDisplay = managedDisplays[displayID],
              managedDisplay.readID == nil,
              managedDisplay.pendingBrightness == nil,
              !hasRetiredWrite(for: managedDisplay),
              !managedDisplay.writeInFlight else { return }

        nextReadID &+= 1
        let readID = nextReadID
        let generation = DisplayDDCIdentity.bindingGeneration
        managedDisplay.readID = readID
        managedDisplays[displayID] = managedDisplay
        let backend = managedDisplay.backend

        // Shade reads only cached state and may touch AppKit overlay geometry.
        if backend.kind == .shade {
            finishRead(for: displayID, readID: readID, generation: generation,
                       result: Result { try backend.readBrightness() })
            return
        }
        let workItem = Self.makeReadWorkItem(
            controllerRef: WeakBrightnessControllerRef(self),
            backend: backend,
            displayID: displayID,
            readID: readID,
            generation: generation,
            readRequirement: managedDisplay.readRequirement
        )
        readWorkItems[displayID] = workItem
        readQueue.async(execute: workItem)
    }

    private func finishRead(for displayID: CGDirectDisplayID, readID: UInt64, generation: UInt64,
                            result: Result<Double, Error>) {
        guard var managedDisplay = managedDisplays[displayID],
              managedDisplay.readID == readID else { return }
        readWorkItems.removeValue(forKey: displayID)
        managedDisplay.readID = nil
        guard generation == DisplayDDCIdentity.bindingGeneration else {
            managedDisplays[displayID] = managedDisplay
            return
        }
        guard isCurrentTarget(managedDisplay) else {
            managedDisplays[displayID] = managedDisplay
            refresh()
            return
        }
        switch result {
        case .success(let value):
            let brightness = Self.clamp(value)
            managedDisplay.currentBrightness = brightness
            managedDisplay.lastCommittedBrightness = brightness
            managedDisplay.hasBrightnessValue = true
            managedDisplay.readRequirement = .none
        case .failure(let error):
            if !managedDisplay.hasBrightnessValue {
                if managedDisplay.backend.kind == .ddc {
                    // Some monitors accept Set VCP without replying to Get VCP.
                    // A replacement endpoint still needs a known level for relative writes.
                    managedDisplay.hasBrightnessValue = managedDisplay.readRequirement == .none
                } else if managedDisplay.readRequirement != .verified,
                          let fallback = fallbackBackend(for: displayID, failedBackend: managedDisplay.backend) {
                    guard isCurrentTarget(managedDisplay) else {
                        managedDisplays[displayID] = managedDisplay
                        refresh()
                        return
                    }
                    managedDisplay.backend.cleanup()
                    managedDisplay.backend = fallback
                    managedDisplays[displayID] = managedDisplay
                    scheduleRead(for: displayID)
                    return
                }
            }
            logger.error("failed to read brightness for \(managedDisplay.display.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            lastErrorMessage = localizedDescription(for: error)
        }
        managedDisplays[displayID] = managedDisplay
        onStateChange?()
    }

    private func cancelReads() {
        for workItem in readWorkItems.values { workItem.cancel() }
        readWorkItems.removeAll()
        for displayID in Array(managedDisplays.keys) {
            managedDisplays[displayID]?.readID = nil
        }
    }

    private func scheduleWrite(for displayID: CGDirectDisplayID, delay: TimeInterval) {
        guard var managedDisplay = managedDisplays[displayID] else {
            return
        }

        let controllerRef = WeakBrightnessControllerRef(self)
        let workItem = Self.makeScheduledWriteWorkItem(
            controllerRef: controllerRef,
            displayID: displayID
        )

        managedDisplay.scheduledFlush = workItem
        managedDisplays[displayID] = managedDisplay

        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + delay,
            execute: workItem
        )
    }

    private func beginWriteIfNeeded(for displayID: CGDirectDisplayID) {
        guard var managedDisplay = managedDisplays[displayID] else {
            return
        }

        guard !managedDisplay.writeInFlight,
              !hasRetiredWrite(for: managedDisplay),
              let targetValue = managedDisplay.pendingBrightness,
              let writeID = managedDisplay.pendingWriteID else {
            return
        }

        let ordinaryWrite = managedDisplay.pendingOrdinaryWrite
        let identifier = managedDisplay.actionIdentifier
        let displayIdentifier = self.displayIdentifier
        let ordinaryPermit = ordinaryWrite.map { write in
            DisplayActionWritePermit {
                DisplayDDCIdentity.bindingGeneration == write.generation && displayIdentifier(displayID) == identifier
            }
        }
        if ordinaryPermit?.canWrite == false
            || (ordinaryWrite?.requiresKnownLevel == true && managedDisplay.readRequirement != .none) {
            managedDisplay.clearPendingWrite()
            managedDisplay.currentBrightness = managedDisplay.lastCommittedBrightness
            managedDisplays[displayID] = managedDisplay
            resolveWrite(writeID, with: .failed(message: PluginKitLocalization.actionUnavailable))
            scheduleRead(for: displayID)
            onStateChange?()
            return
        }

        managedDisplay.writeInFlight = true
        managedDisplay.inFlightWriteID = writeID
        managedDisplay.inFlightTarget = targetValue
        managedDisplay.pendingBrightness = nil
        managedDisplay.pendingWriteID = nil
        managedDisplay.scheduledFlush = nil
        let needsReadback = managedDisplay.pendingReadbackAfterWrite
        managedDisplay.pendingReadbackAfterWrite = false
        managedDisplay.pendingOrdinaryWrite = nil
        let backend = managedDisplay.backend
        let displayName = managedDisplay.display.name
        let controllerRef = WeakBrightnessControllerRef(self)
        managedDisplays[displayID] = managedDisplay

        DispatchQueue.global(qos: .userInitiated).async(
            execute: Self.makeWriteWorkItem(
                controllerRef: controllerRef,
                backend: backend,
                displayID: displayID,
                writeID: writeID,
                targetValue: targetValue,
                needsReadback: needsReadback,
                readRequirement: managedDisplay.readRequirement,
                permit: writePermits[writeID],
                ordinaryPermit: ordinaryPermit,
                ordinaryWrite: ordinaryWrite,
                displayName: displayName,
                writeGate: writeGate,
                minimumWriteInterval: minimumWriteInterval
            )
        )
    }

    private func finishWrite(
        for displayID: CGDirectDisplayID,
        writeID: UInt64,
        targetValue: Double,
        readbackValue: Double?,
        ordinaryPermit: DisplayActionWritePermit?,
        ordinaryWrite: OrdinaryWrite?,
        displayName: String,
        result: Result<Void, Error>
    ) {
        let ordinaryStillCurrent = ordinaryPermit?.canWrite != false
        let result = ordinaryStillCurrent ? result : .failure(CancellationError())
        let readbackValue = ordinaryStillCurrent ? readbackValue : nil
        let replacedBackends = replacedBackendsAwaitingWrites.removeValue(forKey: writeID) ?? []
        for backend in replacedBackends {
            backend.cleanup()
        }
        if let retired = retiredInFlightWrites.removeValue(forKey: writeID) {
            retired.backend.cleanup()
            switch retired.resolution {
            case .actualOutcome:
                resolveWrite(writeID, with: writeResult(from: result))
            case .invalidated:
                resolveWrite(
                    writeID,
                    with: .failed(message: PluginKitLocalization.actionUnavailable)
                )
            }
            for (id, display) in managedDisplays where retired.matches(displayID: id, identifier: display.actionIdentifier) {
                if display.pendingBrightness != nil {
                    scheduleWrite(for: id, delay: 0)
                } else {
                    scheduleRead(for: id)
                }
            }
            onStateChange?()
            return
        }

        guard var managedDisplay = managedDisplays[displayID],
              managedDisplay.inFlightWriteID == writeID else {
            resolveWrite(
                writeID,
                with: .failed(message: DisplayBrightnessControllerError.displayUnavailable(
                    displayID: displayID
                ).localizedDescription(localization: localization))
            )
            return
        }

        managedDisplay.writeInFlight = false
        managedDisplay.inFlightWriteID = nil
        managedDisplay.inFlightTarget = nil

        let invalidated = invalidatedInFlightWriteIDs.remove(writeID) != nil
        let permit = writePermits[writeID]
        if let permit, !permit.isTargetCurrent {
            if let pendingID = managedDisplay.pendingWriteID {
                managedDisplay.clearPendingWrite()
                resolveWrite(pendingID, with: .failed(message: PluginKitLocalization.actionUnavailable))
            }
            // The old observation belongs to another display. Rebuild the target
            // snapshot before making the replacement available for relative controls.
            managedDisplay.readRequirement = .verified
            managedDisplay.hasBrightnessValue = false
            managedDisplay.currentBrightness = managedDisplay.lastCommittedBrightness
            managedDisplays[displayID] = managedDisplay
            resolveWrite(writeID, with: .failed(message: PluginKitLocalization.actionUnavailable))
            refresh()
            return
        }
        let canReconcileExactWrite = permit?.didAttemptWrite == true
        if case let .failure(error) = result, error is CancellationError, ordinaryPermit?.didAttemptWrite == true {
            // A DDC packet may already have applied before topology invalidated the write.
            managedDisplay.readRequirement = max(managedDisplay.readRequirement, .fresh)
            managedDisplay.hasBrightnessValue = false
        }
        if invalidated {
            if canReconcileExactWrite || (permit != nil && readbackValue != nil) {
                if let readbackValue {
                    managedDisplay.lastCommittedBrightness = Self.clamp(readbackValue)
                }
                managedDisplay.hasBrightnessValue = readbackValue != nil
                managedDisplay.readRequirement = readbackValue == nil ? .verified : .none
            }
            if managedDisplay.pendingBrightness == nil {
                managedDisplay.currentBrightness = managedDisplay.lastCommittedBrightness
            }
            managedDisplays[displayID] = managedDisplay
            resolveWrite(
                writeID,
                with: .failed(message: PluginKitLocalization.actionUnavailable)
            )
            onStateChange?()
            if managedDisplay.pendingBrightness != nil {
                scheduleWrite(for: displayID, delay: 0)
            } else if !managedDisplay.hasBrightnessValue {
                scheduleRead(for: displayID)
            }
            return
        }

        if !replacedBackends.isEmpty {
            // Finish the old target's outcome without retrying it through a replacement backend.
            if managedDisplay.pendingBrightness == nil {
                managedDisplay.currentBrightness = managedDisplay.lastCommittedBrightness
            }
            managedDisplays[displayID] = managedDisplay
            resolveWrite(writeID, with: writeResult(from: result))
            onStateChange?()
            if managedDisplay.pendingBrightness != nil {
                scheduleWrite(for: displayID, delay: 0)
            } else {
                scheduleRead(for: displayID)
            }
            return
        }

        switch result {
        case .success:
            let committedBrightness = readbackValue.map(Self.clamp) ?? targetValue
            if readbackValue != nil || (permit == nil && managedDisplay.readRequirement == .fresh
                && managedDisplay.backend.kind == .ddc) {
                managedDisplay.readRequirement = .none
            }
            managedDisplay.hasBrightnessValue = managedDisplay.readRequirement == .none
            managedDisplay.lastCommittedBrightness = committedBrightness
            if managedDisplay.pendingBrightness == nil {
                managedDisplay.currentBrightness = committedBrightness
            }
            lastErrorMessage = nil
            managedDisplay.lastWriteError = nil
            resolveWrite(writeID, with: .succeeded)
        case .failure(let error):
            if canReconcileExactWrite && readbackValue == nil {
                managedDisplay.hasBrightnessValue = false
                managedDisplay.readRequirement = .verified
            }
            let localizedDescription = localizedDescription(for: error)
            logger.error(
                "write failed for \(displayName, privacy: .public): \(localizedDescription, privacy: .public)"
            )

            let canRetryOrdinary = ordinaryPermit?.canWrite != false
            if !(error is CancellationError),
               !(error is DisplayBrightnessExactError),
               writePermits[writeID]?.didAttemptWrite != true,
               writePermits[writeID]?.canWrite != false,
               canRetryOrdinary,
               let fallbackBackend = fallbackBackend(for: displayID, failedBackend: managedDisplay.backend) {
                logger.info(
                    "retrying brightness write for \(displayName, privacy: .public) with \(String(describing: fallbackBackend.kind), privacy: .public) fallback"
                )
                managedDisplay.backend.cleanup()
                managedDisplay.backend = fallbackBackend
                if managedDisplay.pendingWriteID == nil {
                    managedDisplay.pendingBrightness = targetValue
                    managedDisplay.pendingWriteID = writeID
                    managedDisplay.pendingReadbackAfterWrite = true
                    managedDisplay.pendingOrdinaryWrite = ordinaryWrite
                    managedDisplay.currentBrightness = targetValue
                    lastErrorMessage = nil
                    managedDisplay.lastWriteError = nil
                } else {
                    let message = localization.format(
                        "error.adjustFailedFormat",
                        defaultValue: "调节失败：%@",
                        localizedDescription
                    )
                    resolveWrite(writeID, with: .failed(message: message))
                }
            } else {
                if let readbackValue, !(error is CancellationError) || canReconcileExactWrite {
                    managedDisplay.lastCommittedBrightness = Self.clamp(readbackValue)
                    managedDisplay.hasBrightnessValue = true
                    managedDisplay.readRequirement = .none
                }
                if managedDisplay.pendingBrightness == nil {
                    managedDisplay.currentBrightness = managedDisplay.lastCommittedBrightness
                }

                lastErrorMessage = localization.format(
                    "error.adjustFailedFormat",
                    defaultValue: "调节失败：%@",
                    localizedDescription
                )
                managedDisplay.lastWriteError = lastErrorMessage
                resolveWrite(
                    writeID,
                    with: .failed(message: lastErrorMessage ?? localizedDescription)
                )
            }
        }

        managedDisplays[displayID] = managedDisplay
        onStateChange?()

        if managedDisplay.pendingBrightness != nil {
            scheduleWrite(for: displayID, delay: 0)
        } else if !managedDisplay.hasBrightnessValue {
            scheduleRead(for: displayID)
        }
    }

    private func localizedDescription(for error: Error) -> String {
        if let exactError = error as? DisplayBrightnessExactError {
            return exactError.message(localization: localization)
        }
        guard let brightnessError = error as? DisplayBrightnessControllerError else {
            return error.localizedDescription
        }

        return brightnessError.localizedDescription(localization: localization)
    }

    private func fallbackBackend(
        for displayID: CGDirectDisplayID,
        failedBackend: any DisplayBrightnessBackend
    ) -> (any DisplayBrightnessBackend)? {
        guard let managedDisplay = managedDisplays[displayID] else {
            return nil
        }

        let previousBackends = Dictionary(
            uniqueKeysWithValues: managedDisplays.map { ($0.key, $0.value.backend) }
        )
        return backendBuilder.fallbackBackend(
            after: failedBackend,
            for: managedDisplay.display,
            previous: previousBackends
        )
    }

    private func cleanupDisconnectedDisplays(keeping displayIDs: Set<CGDirectDisplayID>) {
        for (displayID, managedDisplay) in managedDisplays where !displayIDs.contains(displayID) {
            readWorkItems.removeValue(forKey: displayID)?.cancel()
            managedDisplay.scheduledFlush?.cancel()
            failOutstandingWrites(for: displayID, managedDisplay: managedDisplay)
            retireDisplay(managedDisplay)
        }
    }

    private func cleanupAll() {
        for permit in writePermits.values { permit.cancel() }
        cancelReads()
        for (_, managedDisplay) in managedDisplays {
            managedDisplay.scheduledFlush?.cancel()
            managedDisplay.backend.cleanup()
        }
        for (_, retiredWrite) in retiredInFlightWrites {
            retiredWrite.backend.cleanup()
        }
        for backends in replacedBackendsAwaitingWrites.values {
            for backend in backends { backend.cleanup() }
        }
        replacedBackendsAwaitingWrites.removeAll()
        retiredInFlightWrites.removeAll()
        invalidatedInFlightWriteIDs.removeAll()
        for writeID in Array(writeWaiters.keys) {
            resolveWrite(
                writeID,
                with: .failed(message: PluginKitLocalization.actionUnavailable)
            )
        }
    }

    private func makeWriteID() -> UInt64 {
        nextWriteID &+= 1
        return nextWriteID
    }

    private func resolveWrite(
        _ writeID: UInt64,
        with result: DisplayBrightnessWriteResult
    ) {
        writePermits.removeValue(forKey: writeID)?.cancel()
        writeTimeoutTasks.removeValue(forKey: writeID)?.cancel()
        waiterDisplayIDs.removeValue(forKey: writeID)
        writeWaiters.removeValue(forKey: writeID)?.resume(returning: result)
    }

    private func timeOutWrite(_ writeID: UInt64) {
        failWriteUnlessInFlight(
            writeID,
            message: localization.string(
                "error.adjustTimedOut",
                defaultValue: "亮度调节超时。"
            ),
            invalidateAfterDispatch: false
        )
    }

    private func failWriteUnlessInFlight(
        _ writeID: UInt64,
        message: String,
        invalidateAfterDispatch: Bool
    ) {
        writePermits[writeID]?.cancel()
        if retiredInFlightWrites[writeID] != nil {
            if invalidateAfterDispatch {
                retiredInFlightWrites[writeID]?.resolution = .invalidated
            }
            writeTimeoutTasks.removeValue(forKey: writeID)?.cancel()
            return
        }
        guard let displayID = waiterDisplayIDs[writeID],
              var managedDisplay = managedDisplays[displayID] else {
            resolveWrite(writeID, with: .failed(message: message))
            return
        }

        if managedDisplay.inFlightWriteID == writeID {
            if invalidateAfterDispatch {
                invalidatedInFlightWriteIDs.insert(writeID)
            }
            writeTimeoutTasks.removeValue(forKey: writeID)?.cancel()
            logger.info(
                "write for \(managedDisplay.display.name, privacy: .public) exceeded its waiter deadline after dispatch; awaiting the backend outcome"
            )
            return
        }

        if managedDisplay.pendingWriteID == writeID {
            managedDisplay.clearPendingWrite()
            managedDisplay.currentBrightness = managedDisplay.inFlightTarget ?? managedDisplay.lastCommittedBrightness
            managedDisplays[displayID] = managedDisplay
            onStateChange?()
            if !managedDisplay.hasBrightnessValue { scheduleRead(for: displayID) }
        }
        resolveWrite(writeID, with: .failed(message: message))
    }

    private func failOutstandingWrites(
        for displayID: CGDirectDisplayID,
        managedDisplay: ManagedDisplay
    ) {
        let message = DisplayBrightnessControllerError.displayUnavailable(
            displayID: displayID
        ).localizedDescription(localization: localization)
        if let writeID = managedDisplay.pendingWriteID {
            resolveWrite(writeID, with: .failed(message: message))
        }
    }

    private func hasExactWrite(for display: ManagedDisplay) -> Bool {
        display.pendingWriteID.flatMap { writePermits[$0] } != nil
            || display.inFlightWriteID.flatMap { writePermits[$0] } != nil
    }

    private func isCurrentTarget(_ display: ManagedDisplay) -> Bool {
        guard let identifier = display.actionIdentifier else { return true }
        return displayIdentifier(display.display.id) == identifier
    }

    private func hasRetiredWrite(for display: ManagedDisplay) -> Bool {
        retiredInFlightWrites.values.contains {
            $0.matches(displayID: display.display.id, identifier: display.actionIdentifier)
        }
    }

    private func retireDisplay(_ display: ManagedDisplay) {
        let permit = display.inFlightWriteID.flatMap { writePermits[$0] }
        permit?.cancel()
        // Once cancelled, an exact permit cannot begin another SET.
        let mutationRequirement: ReadRequirement
        if let permit {
            mutationRequirement = permit.didAttemptWrite ? .verified : .none
        } else {
            mutationRequirement = display.inFlightWriteID == nil ? .none : .fresh
        }
        if let identifier = display.actionIdentifier {
            let requirement = max(display.readRequirement, mutationRequirement, retiredReadRequirements[identifier] ?? .none)
            if requirement != .none { retiredReadRequirements[identifier] = requirement }
        }
        guard let writeID = display.inFlightWriteID else {
            display.backend.cleanup()
            return
        }
        writeTimeoutTasks.removeValue(forKey: writeID)?.cancel()
        invalidatedInFlightWriteIDs.remove(writeID)
        retiredInFlightWrites[writeID] = RetiredInFlightWrite(
            backend: display.backend,
            displayID: display.display.id,
            actionIdentifier: display.actionIdentifier,
            readRequirement: mutationRequirement,
            resolution: permit == nil ? .actualOutcome : .invalidated
        )
    }

    private func writeResult(from result: Result<Void, Error>) -> DisplayBrightnessWriteResult {
        switch result {
        case .success:
            return .succeeded
        case .failure(let error):
            let description = localizedDescription(for: error)
            return .failed(message: localization.format(
                "error.adjustFailedFormat",
                defaultValue: "调节失败：%@",
                description
            ))
        }
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    nonisolated private static func makeScheduledWriteWorkItem(
        controllerRef: WeakBrightnessControllerRef,
        displayID: CGDirectDisplayID
    ) -> DispatchWorkItem {
        DispatchWorkItem {
            Task { @MainActor in
                controllerRef.value?.beginWriteIfNeeded(for: displayID)
            }
        }
    }

    nonisolated private static func makeReadWorkItem(
        controllerRef: WeakBrightnessControllerRef,
        backend: any DisplayBrightnessBackend,
        displayID: CGDirectDisplayID,
        readID: UInt64,
        generation: UInt64,
        readRequirement: ReadRequirement
    ) -> DispatchWorkItem {
        DispatchWorkItem {
            let result = Result {
                try readRequirement.read(from: backend)
            }
            Task { @MainActor in
                controllerRef.value?.finishRead(for: displayID, readID: readID, generation: generation, result: result)
            }
        }
    }

    nonisolated private static func makeWriteWorkItem(
        controllerRef: WeakBrightnessControllerRef,
        backend: any DisplayBrightnessBackend,
        displayID: CGDirectDisplayID,
        writeID: UInt64,
        targetValue: Double,
        needsReadback: Bool,
        readRequirement: ReadRequirement,
        permit: DisplayActionWritePermit?,
        ordinaryPermit: DisplayActionWritePermit?,
        ordinaryWrite: OrdinaryWrite?,
        displayName: String,
        writeGate: BrightnessWriteGate,
        minimumWriteInterval: TimeInterval
    ) -> DispatchWorkItem {
        DispatchWorkItem {
            let result: Result<Void, Error>
            var readbackValue: Double?

            do {
                writeGate.waitTurn(for: displayID, minimumInterval: minimumWriteInterval)
                if let permit {
                    if let error = backend.exactActionError(for: targetValue) { throw error }
                    readbackValue = try backend.writeExactBrightness(targetValue, permit: permit)
                    if backend.kind == .appleNative {
                        // Keep readback in this write's slot so a later write cannot change the result.
                        for delay in [0.0, 0.15, 0.30] {
                            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
                            guard permit.canWrite else { throw CancellationError() }
                            guard let observed = try? backend.readVerifiedBrightness() else { continue }
                            readbackValue = observed
                            if ActionPercentage.matchesHardwareLevel(observed, requested: targetValue) { break }
                        }
                        guard permit.canWrite else { throw CancellationError() }
                        guard let readbackValue else { throw DisplayBrightnessExactError.readbackUnavailable }
                        guard ActionPercentage.matchesHardwareLevel(readbackValue, requested: targetValue) else {
                            throw DisplayBrightnessExactError.mismatch(requested: targetValue, observed: readbackValue)
                        }
                    }
                    guard permit.canWrite else { throw CancellationError() }
                } else {
                    try backend.writeBrightness(targetValue, permit: ordinaryPermit)
                    guard ordinaryPermit?.canWrite != false else { throw CancellationError() }
                    if needsReadback || readRequirement != .none {
                        readbackValue = try? readRequirement.read(from: backend)
                    }
                }
                result = .success(())
            } catch {
                if let observed = (error as? DisplayBrightnessExactError)?.observedLevel {
                    readbackValue = observed
                } else if permit?.isTargetCurrent == true, permit?.didAttemptWrite == true,
                          readbackValue == nil, backend.kind != .shade {
                    // Keep the failed outcome, but reconcile the level before releasing the write slot.
                    readbackValue = try? backend.readVerifiedBrightness()
                }
                result = .failure(error)
            }

            Task { @MainActor in
                controllerRef.value?.finishWrite(
                    for: displayID,
                    writeID: writeID,
                    targetValue: targetValue,
                    readbackValue: readbackValue,
                    ordinaryPermit: ordinaryPermit,
                    ordinaryWrite: ordinaryWrite,
                    displayName: displayName,
                    result: result
                )
            }
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer {
            unlock()
        }

        return try body()
    }
}
