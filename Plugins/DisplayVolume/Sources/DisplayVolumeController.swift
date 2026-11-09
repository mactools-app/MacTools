import AppKit
import CoreGraphics
import Foundation
import MacToolsPluginKit
import OSLog

private final class WeakVolumeControllerRef: @unchecked Sendable {
    weak var value: DisplayVolumeController?

    init(_ value: DisplayVolumeController?) {
        self.value = value
    }
}

private final class VolumeWriteGate: @unchecked Sendable {
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
final class DisplayVolumeController: DisplayVolumeControlling {
    private enum ReadRequirement: Int, Comparable, Sendable {
        case none
        case fresh
        case verified

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        func read(from backend: any DisplayVolumeBackend) throws -> Double {
            switch self {
            case .none: try backend.readVolume()
            case .fresh: try backend.readFreshVolume()
            case .verified: try backend.readVerifiedVolume()
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
        var backend: any DisplayVolumeBackend
        var currentVolume: Double
        var lastCommittedVolume: Double
        var pendingVolume: Double?
        var pendingWriteID: UInt64?
        var writeInFlight = false
        var inFlightWriteID: UInt64?
        var inFlightTarget: Double?
        var scheduledFlush: DispatchWorkItem?
        var pendingReadbackAfterWrite = false
        var pendingOrdinaryWrite: OrdinaryWrite?
        var lastWriteError: String?
        var readRequirement: ReadRequirement = .none

        var reusableDDCState: DDCVolumeBackend.CachedState? {
            guard actionIdentifier != nil, readRequirement == .none, pendingWriteID == nil, !writeInFlight else {
                return nil
            }
            return (backend as? DDCVolumeBackend)?.cachedState(level: lastCommittedVolume)
        }

        mutating func clearPendingWrite() {
            scheduledFlush?.cancel()
            scheduledFlush = nil
            pendingVolume = nil
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
        let backend: any DisplayVolumeBackend
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
    private let backendBuilder: DisplayVolumeBackendBuilding
    private let localization: PluginLocalization
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools", category: "DisplayVolumeController")
    private let shortWriteDelay: TimeInterval
    private let minimumWriteInterval: TimeInterval
    private let writeTimeout: Duration
    private let writeGate = VolumeWriteGate()

    private var previousDisplays: [CGDirectDisplayID: DisplayInfo] = [:]
    private var previousIdentifiers: [CGDirectDisplayID: String] = [:]
    private var previouslyManagedDisplayIDs: Set<CGDirectDisplayID> = []
    private var managedDisplays: [CGDirectDisplayID: ManagedDisplay] = [:]
    private var disconnectedDDCStates: [String: DDCVolumeBackend.CachedState] = [:]
    private var displayOrder: [CGDirectDisplayID] = []
    private var readTasks: [CGDirectDisplayID: (id: UUID, task: Task<Void, Never>)] = [:]
    private var lastErrorMessage: String?
    private var nextWriteID: UInt64 = 0
    private var writePermits: [UInt64: DisplayActionWritePermit] = [:]
    private var writeWaiters: [UInt64: CheckedContinuation<DisplayVolumeWriteResult, Never>] = [:]
    private var writeTimeoutTasks: [UInt64: Task<Void, Never>] = [:]
    private var waiterDisplayIDs: [UInt64: CGDirectDisplayID] = [:]
    private var retiredReadRequirements: [String: ReadRequirement] = [:]
    private var retiredInFlightWrites: [UInt64: RetiredInFlightWrite] = [:]
    private var invalidatedInFlightWriteIDs: Set<UInt64> = []
    private var terminateObserver: NSObjectProtocol?

    var pendingWriteTimeoutCount: Int { writeTimeoutTasks.count }
    var pendingReadCount: Int { readTasks.count }

    init(
        displayProvider: DisplayProviding = SystemDisplayService(),
        displayIdentifier: @escaping @Sendable (CGDirectDisplayID) -> String? = DisplayActionTarget.identifier(for:),
        backendBuilder: DisplayVolumeBackendBuilding? = nil,
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        shortWriteDelay: TimeInterval = 0.08,
        minimumWriteInterval: TimeInterval = 0.08,
        writeTimeout: Duration = .seconds(10)
    ) {
        self.displayProvider = displayProvider
        self.displayIdentifier = displayIdentifier
        self.localization = localization
        self.backendBuilder = backendBuilder ?? SystemDisplayVolumeBackendBuilder(
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
        let nextDisplayIDs = Set(nextBackends.keys)

        let retainedDisplays = reusableDisplays.filter { id, previous in
            guard nextDisplayIDs.contains(id), let backend = nextBackends[id] else { return false }
            // An exact write owns its backend through verification.
            return previous.backend === backend || previous.inFlightWriteID.flatMap { writePermits[$0] } == nil
        }
        for (id, previous) in managedDisplays where displayInventory[id] == nil {
            if let identifier = previous.actionIdentifier {
                disconnectedDDCStates[identifier] = previous.reusableDDCState
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
            let changedBackend = previous.map { $0.backend !== backend } ?? true
            if changedBackend { cancelRead(for: display.id) }
            let disconnectedState = identifier.flatMap { disconnectedDDCStates.removeValue(forKey: $0) }
            let oldState = changedBackend && old?.actionIdentifier == identifier ? old?.reusableDDCState : nil
            let canPreserveLevel: Bool
            if changedBackend, let state = oldState ?? disconnectedState, let newDDC = backend as? DDCVolumeBackend {
                canPreserveLevel = newDDC.reuseCachedState(state)
            } else {
                canPreserveLevel = false
            }
            let retiredRequirement = identifier.flatMap { retiredReadRequirements[$0] } ?? .none
            var readRequirement = max(previous?.readRequirement ?? .none, retiredRequirement)
            for write in retiredInFlightWrites.values where write.matches(displayID: display.id, identifier: identifier) {
                readRequirement = max(readRequirement, write.recoveryRequirement(for: identifier))
            }
            let needsInitialLevel = (backend as? DDCVolumeBackend)?.hasKnownVolume == false
            if changedBackend && !canPreserveLevel
                && (needsInitialLevel || previouslyManagedDisplayIDs.contains(display.id) || disconnectedState != nil) {
                readRequirement = max(readRequirement, .fresh)
            }
            let hasOutstandingWrite = previous?.pendingVolume != nil || previous?.writeInFlight == true
            let cachedVolume = Self.clamp(backend.cachedVolume)
            let volume = hasOutstandingWrite ? (previous?.lastCommittedVolume ?? cachedVolume) : cachedVolume

            nextManagedDisplays[display.id] = ManagedDisplay(
                display: display,
                actionIdentifier: identifier,
                backend: backend,
                currentVolume: hasOutstandingWrite ? (previous?.currentVolume ?? volume) : volume,
                lastCommittedVolume: volume,
                pendingVolume: previous?.pendingVolume,
                pendingWriteID: previous?.pendingWriteID,
                writeInFlight: previous?.writeInFlight ?? false,
                inFlightWriteID: previous?.inFlightWriteID,
                inFlightTarget: previous?.inFlightTarget,
                scheduledFlush: previous?.scheduledFlush,
                pendingReadbackAfterWrite: previous?.pendingReadbackAfterWrite ?? false,
                pendingOrdinaryWrite: previous?.pendingOrdinaryWrite,
                lastWriteError: previous?.lastWriteError,
                readRequirement: readRequirement
            )
            nextDisplayOrder.append(display.id)
        }

        for identifier in nextManagedDisplays.values.compactMap(\.actionIdentifier) {
            retiredReadRequirements.removeValue(forKey: identifier)
        }
        previouslyManagedDisplayIDs.formUnion(nextManagedDisplays.keys)
        managedDisplays = nextManagedDisplays
        displayOrder = nextDisplayOrder

        if !nextManagedDisplays.isEmpty {
            lastErrorMessage = nil
        }
        for displayID in displayOrder {
            scheduleRead(for: displayID)
        }
    }

    func snapshot() -> DisplayVolumeSnapshot {
        let displays = displayOrder.compactMap { displayID -> DisplayVolumeDisplay? in
            guard let managedDisplay = managedDisplays[displayID] else {
                return nil
            }


            return DisplayVolumeDisplay(
                display: managedDisplay.display,
                volume: managedDisplay.currentVolume,
                isPendingWrite: managedDisplay.pendingVolume != nil || managedDisplay.writeInFlight,
                isReady: managedDisplay.readRequirement == .none,
                isSettingExactLevel: hasExactWrite(for: managedDisplay)
            )
        }

        return DisplayVolumeSnapshot(
            displays: displays,
            errorMessage: lastErrorMessage
        )
    }

    func actionIdentifier(for displayID: CGDirectDisplayID) -> String? {
        managedDisplays[displayID]?.actionIdentifier
    }

    func exactVolumeAvailability(for displayID: CGDirectDisplayID) -> ActionAvailability {
        guard let backend = managedDisplays[displayID]?.backend else {
            return .unavailable(PluginKitLocalization.actionUnavailable)
        }
        return backend.hasVerifiedDisplayBinding ? .available : .unavailable(
            DisplayVolumeControllerError.unverifiedDisplayBinding.localizedDescription(localization: localization)
        )
    }

    func adjustVolume(by delta: Double, for displayID: CGDirectDisplayID, phase: PluginPanelAction.SliderPhase) {
        guard let managed = managedDisplays[displayID], managed.readRequirement == .none else { return }
        enqueueVolume(managed.currentVolume + delta, for: displayID, phase: phase,
                      writeID: makeWriteID(), requiresKnownLevel: true)
    }

    func adjustVolumeAndWait(by delta: Double, for displayID: CGDirectDisplayID) async -> DisplayVolumeWriteResult {
        guard let managed = managedDisplays[displayID], managed.readRequirement == .none else {
            return .failed(message: PluginKitLocalization.actionUnavailable)
        }
        return await setVolumeAndWait(
            managed.currentVolume + delta, for: displayID, permit: nil, requiresKnownLevel: true
        )
    }

    func setVolume(
        _ value: Double,
        for displayID: CGDirectDisplayID,
        phase: PluginPanelAction.SliderPhase
    ) {
        enqueueVolume(
            value,
            for: displayID,
            phase: phase,
            writeID: makeWriteID()
        )
    }

    func setVolumeAndWait(
        _ value: Double,
        for displayID: CGDirectDisplayID
    ) async -> DisplayVolumeWriteResult {
        await setVolumeAndWait(value, for: displayID, permit: nil)
    }

    func setExactVolumeAndWait(
        _ value: Double,
        for displayID: CGDirectDisplayID,
        identifier: String
    ) async -> DisplayVolumeWriteResult {
        let permit = DisplayActionWritePermit { [displayIdentifier] in
            displayIdentifier(displayID) == identifier
        }
        guard actionIdentifier(for: displayID) == identifier, permit.canWrite, !Task.isCancelled else {
            return .failed(message: PluginKitLocalization.actionUnavailable)
        }
        return await setVolumeAndWait(value, for: displayID, permit: permit)
    }

    private func setVolumeAndWait(
        _ value: Double,
        for displayID: CGDirectDisplayID,
        permit: DisplayActionWritePermit?,
        requiresKnownLevel: Bool = false
    ) async -> DisplayVolumeWriteResult {
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
                enqueueVolume(
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
        cancelAllReads()
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

    private func enqueueVolume(
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
            let message = DisplayVolumeControllerError.displayUnavailable(
                displayID: displayID
            ).localizedDescription(localization: localization)
            lastErrorMessage = message
            resolveWrite(writeID, with: .failed(message: message))
            onStateChange?()
            return
        }

        guard !requiresKnownLevel || managedDisplay.readRequirement == .none else {
            resolveWrite(writeID, with: .failed(message: PluginKitLocalization.actionUnavailable))
            return
        }
        // Relative adjustments cannot use an exact write's optimistic target.
        if requiresKnownLevel && (hasExactWrite(for: managedDisplay) || !isCurrentTarget(managedDisplay)) {
            resolveWrite(writeID, with: .failed(message: PluginKitLocalization.actionUnavailable))
            return
        }
        cancelRead(for: displayID)
        if let supersededWriteID = managedDisplay.pendingWriteID {
            resolveWrite(
                supersededWriteID,
                with: .failed(message: PluginKitLocalization.actionUnavailable)
            )
        }
        let clampedValue = Self.clamp(value)
        managedDisplay.currentVolume = clampedValue
        managedDisplay.pendingVolume = clampedValue
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
        guard readTasks[displayID] == nil,
              let managedDisplay = managedDisplays[displayID],
              managedDisplay.pendingVolume == nil,
              !hasRetiredWrite(for: managedDisplay),
              !managedDisplay.writeInFlight else { return }

        let readID = UUID()
        let generation = DisplayDDCIdentity.bindingGeneration
        let backend = managedDisplay.backend
        let readRequirement = managedDisplay.readRequirement
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let volume = try? readRequirement.read(from: backend)
            guard !Task.isCancelled else { return }
            await self?.finishRead(volume, for: displayID, readID: readID, generation: generation, backend: backend)
        }
        readTasks[displayID] = (readID, task)
    }

    private func finishRead(
        _ volume: Double?,
        for displayID: CGDirectDisplayID,
        readID: UUID,
        generation: UInt64,
        backend: any DisplayVolumeBackend
    ) {
        guard readTasks[displayID]?.id == readID else { return }
        readTasks.removeValue(forKey: displayID)
        guard var managedDisplay = managedDisplays[displayID],
              managedDisplay.backend === backend,
              generation == DisplayDDCIdentity.bindingGeneration, isCurrentTarget(managedDisplay),
              managedDisplay.pendingVolume == nil,
              !managedDisplay.writeInFlight,
              let volume else { return }

        let clamped = Self.clamp(volume)
        let changed = managedDisplay.currentVolume != clamped || managedDisplay.readRequirement != .none
        managedDisplay.readRequirement = .none
        managedDisplay.currentVolume = clamped
        managedDisplay.lastCommittedVolume = clamped
        managedDisplays[displayID] = managedDisplay
        if changed { onStateChange?() }
    }

    private func cancelRead(for displayID: CGDirectDisplayID) {
        readTasks.removeValue(forKey: displayID)?.task.cancel()
    }

    private func cancelAllReads() {
        for read in readTasks.values { read.task.cancel() }
        readTasks.removeAll()
    }

    private func scheduleWrite(for displayID: CGDirectDisplayID, delay: TimeInterval) {
        guard var managedDisplay = managedDisplays[displayID] else {
            return
        }

        let controllerRef = WeakVolumeControllerRef(self)
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
              let targetValue = managedDisplay.pendingVolume,
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
            managedDisplay.currentVolume = managedDisplay.lastCommittedVolume
            managedDisplays[displayID] = managedDisplay
            resolveWrite(writeID, with: .failed(message: PluginKitLocalization.actionUnavailable))
            scheduleRead(for: displayID)
            onStateChange?()
            return
        }

        managedDisplay.writeInFlight = true
        managedDisplay.inFlightWriteID = writeID
        managedDisplay.inFlightTarget = targetValue
        managedDisplay.pendingVolume = nil
        managedDisplay.pendingWriteID = nil
        managedDisplay.scheduledFlush = nil
        let needsReadback = managedDisplay.pendingReadbackAfterWrite
        managedDisplay.pendingReadbackAfterWrite = false
        managedDisplay.pendingOrdinaryWrite = nil
        let backend = managedDisplay.backend
        let displayName = managedDisplay.display.name
        let permit = writePermits[writeID]
        let controllerRef = WeakVolumeControllerRef(self)
        managedDisplays[displayID] = managedDisplay
        (backend as? DDCVolumeBackend)?.prepareWrite()

        DispatchQueue.global(qos: .userInitiated).async(
            execute: Self.makeWriteWorkItem(
                controllerRef: controllerRef,
                backend: backend,
                displayID: displayID,
                writeID: writeID,
                targetValue: targetValue,
                needsReadback: needsReadback,
                readRequirement: managedDisplay.readRequirement,
                permit: permit,
                ordinaryPermit: ordinaryPermit,
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
        displayName: String,
        result: Result<Void, Error>
    ) {
        let ordinaryStillCurrent = ordinaryPermit?.canWrite != false
        let result = ordinaryStillCurrent ? result : .failure(CancellationError())
        let readbackValue = ordinaryStillCurrent ? readbackValue : nil
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
                if display.pendingVolume != nil {
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
                with: .failed(message: DisplayVolumeControllerError.displayUnavailable(
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
            managedDisplay.currentVolume = managedDisplay.lastCommittedVolume
            managedDisplays[displayID] = managedDisplay
            resolveWrite(writeID, with: .failed(message: PluginKitLocalization.actionUnavailable))
            refresh()
            return
        }
        let canReconcileExactWrite = permit?.didAttemptWrite == true
        if case .failure = result, ordinaryPermit?.didAttemptWrite == true {
            // A DDC packet may already have applied before the write failed.
            managedDisplay.readRequirement = max(managedDisplay.readRequirement, .fresh)
        }
        if invalidated {
            if canReconcileExactWrite || (permit != nil && readbackValue != nil) {
                if let readbackValue { managedDisplay.lastCommittedVolume = Self.clamp(readbackValue) }
                managedDisplay.readRequirement = readbackValue == nil ? .verified : .none
            }
            if managedDisplay.pendingVolume == nil {
                managedDisplay.currentVolume = managedDisplay.lastCommittedVolume
            }
            managedDisplays[displayID] = managedDisplay
            resolveWrite(
                writeID,
                with: .failed(message: PluginKitLocalization.actionUnavailable)
            )
            onStateChange?()
            if managedDisplay.pendingVolume != nil {
                scheduleWrite(for: displayID, delay: 0)
            } else if managedDisplay.readRequirement != .none {
                scheduleRead(for: displayID)
            }
            return
        }

        switch result {
        case .success:
            let committedVolume = readbackValue.map(Self.clamp) ?? targetValue
            if readbackValue != nil || (permit == nil && managedDisplay.readRequirement == .fresh) {
                managedDisplay.readRequirement = .none
            }
            managedDisplay.lastCommittedVolume = committedVolume
            if managedDisplay.pendingVolume == nil {
                managedDisplay.currentVolume = committedVolume
            }
            lastErrorMessage = nil
            managedDisplay.lastWriteError = nil
            resolveWrite(writeID, with: .succeeded)
        case .failure(let error):
            let localizedDescription = localizedDescription(for: error)
            logger.error(
                "write failed for \(displayName, privacy: .public): \(localizedDescription, privacy: .public)"
            )

            if canReconcileExactWrite || readbackValue != nil {
                if let readbackValue { managedDisplay.lastCommittedVolume = Self.clamp(readbackValue) }
                managedDisplay.readRequirement = readbackValue == nil ? .verified : .none
            }
            if managedDisplay.pendingVolume == nil {
                managedDisplay.currentVolume = managedDisplay.lastCommittedVolume
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

        managedDisplays[displayID] = managedDisplay
        onStateChange?()

        if managedDisplay.pendingVolume != nil {
            scheduleWrite(for: displayID, delay: 0)
        } else if managedDisplay.readRequirement != .none {
            scheduleRead(for: displayID)
        }
    }

    private func localizedDescription(for error: Error) -> String {
        guard let volumeError = error as? DisplayVolumeControllerError else {
            return error.localizedDescription
        }

        return volumeError.localizedDescription(localization: localization)
    }

    private func cleanupDisconnectedDisplays(keeping displayIDs: Set<CGDirectDisplayID>) {
        for (displayID, managedDisplay) in managedDisplays where !displayIDs.contains(displayID) {
            cancelRead(for: displayID)
            managedDisplay.scheduledFlush?.cancel()
            failOutstandingWrites(for: displayID, managedDisplay: managedDisplay)
            retireDisplay(managedDisplay)
        }
    }

    private func cleanupAll() {
        for permit in writePermits.values { permit.cancel() }
        cancelAllReads()
        for (_, managedDisplay) in managedDisplays {
            managedDisplay.scheduledFlush?.cancel()
            managedDisplay.backend.cleanup()
        }
        for (_, retiredWrite) in retiredInFlightWrites {
            retiredWrite.backend.cleanup()
        }
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
        with result: DisplayVolumeWriteResult
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
                defaultValue: "音量调节超时。"
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
            managedDisplay.currentVolume = managedDisplay.inFlightTarget ?? managedDisplay.lastCommittedVolume
            managedDisplays[displayID] = managedDisplay
            onStateChange?()
            if managedDisplay.readRequirement != .none { scheduleRead(for: displayID) }
        }
        resolveWrite(writeID, with: .failed(message: message))
    }

    private func failOutstandingWrites(
        for displayID: CGDirectDisplayID,
        managedDisplay: ManagedDisplay
    ) {
        let message = DisplayVolumeControllerError.displayUnavailable(
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

    private func writeResult(from result: Result<Void, Error>) -> DisplayVolumeWriteResult {
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
        controllerRef: WeakVolumeControllerRef,
        displayID: CGDirectDisplayID
    ) -> DispatchWorkItem {
        DispatchWorkItem {
            Task { @MainActor in
                controllerRef.value?.beginWriteIfNeeded(for: displayID)
            }
        }
    }

    nonisolated private static func makeWriteWorkItem(
        controllerRef: WeakVolumeControllerRef,
        backend: any DisplayVolumeBackend,
        displayID: CGDirectDisplayID,
        writeID: UInt64,
        targetValue: Double,
        needsReadback: Bool,
        readRequirement: ReadRequirement,
        permit: DisplayActionWritePermit?,
        ordinaryPermit: DisplayActionWritePermit?,
        displayName: String,
        writeGate: VolumeWriteGate,
        minimumWriteInterval: TimeInterval
    ) -> DispatchWorkItem {
        DispatchWorkItem {
            let result: Result<Void, Error>
            var readbackValue: Double?

            do {
                writeGate.waitTurn(for: displayID, minimumInterval: minimumWriteInterval)
                if let permit {
                    readbackValue = try backend.writeExactVolume(targetValue, permit: permit)
                    guard permit.canWrite else { throw CancellationError() }
                } else {
                    try backend.writeVolume(targetValue, permit: ordinaryPermit)
                    guard ordinaryPermit?.canWrite != false else { throw CancellationError() }
                    if needsReadback || readRequirement != .none {
                        readbackValue = try? readRequirement.read(from: backend)
                    }
                }
                result = .success(())
            } catch {
                if let volumeError = error as? DisplayVolumeControllerError,
                   case let .unsupportedHardwareLevel(observed) = volumeError {
                    readbackValue = observed
                } else if permit?.isTargetCurrent == true, permit?.didAttemptWrite == true, readbackValue == nil {
                    readbackValue = try? backend.readVerifiedVolume()
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
