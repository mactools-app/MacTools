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
    private struct ManagedDisplay {
        var display: DisplayInfo
        var backend: any DisplayVolumeBackend
        var currentVolume: Double
        var lastCommittedVolume: Double
        var pendingVolume: Double?
        var pendingWriteID: UInt64?
        var writeInFlight = false
        var inFlightWriteID: UInt64?
        var scheduledFlush: DispatchWorkItem?
        var pendingReadbackAfterWrite = false
        var lastWriteError: String?
    }

    private enum RetiredWriteResolution {
        case actualOutcome
        case invalidated
    }

    private struct RetiredInFlightWrite {
        let backend: any DisplayVolumeBackend
        var resolution: RetiredWriteResolution
    }

    var onStateChange: (() -> Void)?

    private let displayProvider: DisplayProviding
    private let backendBuilder: DisplayVolumeBackendBuilding
    private let localization: PluginLocalization
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools", category: "DisplayVolumeController")
    private let shortWriteDelay: TimeInterval
    private let minimumWriteInterval: TimeInterval
    private let writeTimeout: Duration
    private let writeGate = VolumeWriteGate()

    private var managedDisplays: [CGDirectDisplayID: ManagedDisplay] = [:]
    private var displayOrder: [CGDirectDisplayID] = []
    private var readTasks: [CGDirectDisplayID: (id: UUID, task: Task<Void, Never>)] = [:]
    private var lastErrorMessage: String?
    private var nextWriteID: UInt64 = 0
    private var writeWaiters: [UInt64: CheckedContinuation<DisplayVolumeWriteResult, Never>] = [:]
    private var writeTimeoutTasks: [UInt64: Task<Void, Never>] = [:]
    private var waiterDisplayIDs: [UInt64: CGDirectDisplayID] = [:]
    private var retiredInFlightWrites: [UInt64: RetiredInFlightWrite] = [:]
    private var invalidatedInFlightWriteIDs: Set<UInt64> = []
    private var terminateObserver: NSObjectProtocol?

    var pendingWriteTimeoutCount: Int { writeTimeoutTasks.count }
    var pendingReadCount: Int { readTasks.count }

    init(
        displayProvider: DisplayProviding = SystemDisplayService(),
        backendBuilder: DisplayVolumeBackendBuilding? = nil,
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        shortWriteDelay: TimeInterval = 0.08,
        minimumWriteInterval: TimeInterval = 0.08,
        writeTimeout: Duration = .seconds(10)
    ) {
        self.displayProvider = displayProvider
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
        let displays = displayProvider.listConnectedDisplays()
        let previousBackends = Dictionary(
            uniqueKeysWithValues: managedDisplays.map { ($0.key, $0.value.backend) }
        )
        let nextBackends = backendBuilder.backends(for: displays, previous: previousBackends)
        let nextDisplayIDs = Set(nextBackends.keys)

        cleanupDisconnectedDisplays(keeping: nextDisplayIDs)

        var nextManagedDisplays: [CGDirectDisplayID: ManagedDisplay] = [:]
        var nextDisplayOrder: [CGDirectDisplayID] = []

        for display in displays {
            guard let backend = nextBackends[display.id] else {
                continue
            }

            let previous = managedDisplays[display.id]
            let hasOutstandingWrite = previous?.pendingVolume != nil || previous?.writeInFlight == true
            let cachedVolume = Self.clamp(backend.cachedVolume)
            let volume = hasOutstandingWrite ? (previous?.lastCommittedVolume ?? cachedVolume) : cachedVolume

            nextManagedDisplays[display.id] = ManagedDisplay(
                display: display,
                backend: backend,
                currentVolume: hasOutstandingWrite ? (previous?.currentVolume ?? volume) : volume,
                lastCommittedVolume: volume,
                pendingVolume: previous?.pendingVolume,
                pendingWriteID: previous?.pendingWriteID,
                writeInFlight: previous?.writeInFlight ?? false,
                inFlightWriteID: previous?.inFlightWriteID,
                scheduledFlush: previous?.scheduledFlush,
                pendingReadbackAfterWrite: previous?.pendingReadbackAfterWrite ?? false,
                lastWriteError: previous?.lastWriteError
            )
            nextDisplayOrder.append(display.id)
        }

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
                isPendingWrite: managedDisplay.pendingVolume != nil || managedDisplay.writeInFlight
            )
        }

        return DisplayVolumeSnapshot(
            displays: displays,
            errorMessage: lastErrorMessage
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
        let writeID = makeWriteID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
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
                    writeID: writeID
                )
            }
        } onCancel: {
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
        cancelAllReads()
        for (_, managedDisplay) in Array(managedDisplays) {
            managedDisplay.scheduledFlush?.cancel()
            if let writeID = managedDisplay.pendingWriteID {
                resolveWrite(
                    writeID,
                    with: .failed(message: PluginKitLocalization.actionUnavailable)
                )
            }
            if let writeID = managedDisplay.inFlightWriteID {
                retireInFlightWrite(
                    writeID,
                    backend: managedDisplay.backend,
                    resolution: .actualOutcome
                )
            } else {
                managedDisplay.backend.cleanup()
            }
        }
        managedDisplays.removeAll()
        displayOrder.removeAll()
        lastErrorMessage = nil
        onStateChange?()
    }

    private func enqueueVolume(
        _ value: Double,
        for displayID: CGDirectDisplayID,
        phase: PluginPanelAction.SliderPhase,
        writeID: UInt64
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
              !managedDisplay.writeInFlight else { return }

        let readID = UUID()
        let backend = managedDisplay.backend
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let volume = try? backend.readVolume()
            guard !Task.isCancelled else { return }
            await self?.finishRead(volume, for: displayID, readID: readID, backend: backend)
        }
        readTasks[displayID] = (readID, task)
    }

    private func finishRead(
        _ volume: Double?,
        for displayID: CGDirectDisplayID,
        readID: UUID,
        backend: any DisplayVolumeBackend
    ) {
        guard readTasks[displayID]?.id == readID else { return }
        readTasks.removeValue(forKey: displayID)
        guard var managedDisplay = managedDisplays[displayID],
              managedDisplay.backend === backend,
              managedDisplay.pendingVolume == nil,
              !managedDisplay.writeInFlight,
              let volume else { return }

        let clamped = Self.clamp(volume)
        let changed = managedDisplay.currentVolume != clamped
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
              let targetValue = managedDisplay.pendingVolume,
              let writeID = managedDisplay.pendingWriteID else {
            return
        }

        managedDisplay.writeInFlight = true
        managedDisplay.inFlightWriteID = writeID
        managedDisplay.pendingVolume = nil
        managedDisplay.pendingWriteID = nil
        managedDisplay.scheduledFlush = nil
        let needsReadback = managedDisplay.pendingReadbackAfterWrite
        managedDisplay.pendingReadbackAfterWrite = false
        let backend = managedDisplay.backend
        let displayName = managedDisplay.display.name
        let controllerRef = WeakVolumeControllerRef(self)
        managedDisplays[displayID] = managedDisplay

        DispatchQueue.global(qos: .userInitiated).async(
            execute: Self.makeWriteWorkItem(
                controllerRef: controllerRef,
                backend: backend,
                displayID: displayID,
                writeID: writeID,
                targetValue: targetValue,
                needsReadback: needsReadback,
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
        displayName: String,
        result: Result<Void, Error>
    ) {
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

        if invalidatedInFlightWriteIDs.remove(writeID) != nil {
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
            }
            return
        }

        switch result {
        case .success:
            let committedVolume = readbackValue.map(Self.clamp) ?? targetValue
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
            if let writeID = managedDisplay.inFlightWriteID {
                retireInFlightWrite(
                    writeID,
                    backend: managedDisplay.backend,
                    resolution: .actualOutcome
                )
            } else {
                managedDisplay.backend.cleanup()
            }
        }
    }

    private func cleanupAll() {
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
            managedDisplay.scheduledFlush?.cancel()
            managedDisplay.scheduledFlush = nil
            managedDisplay.pendingVolume = nil
            managedDisplay.pendingWriteID = nil
            managedDisplay.currentVolume = managedDisplay.lastCommittedVolume
            managedDisplays[displayID] = managedDisplay
            onStateChange?()
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

    private func retireInFlightWrite(
        _ writeID: UInt64,
        backend: any DisplayVolumeBackend,
        resolution: RetiredWriteResolution
    ) {
        writeTimeoutTasks.removeValue(forKey: writeID)?.cancel()
        invalidatedInFlightWriteIDs.remove(writeID)
        retiredInFlightWrites[writeID] = RetiredInFlightWrite(
            backend: backend,
            resolution: resolution
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
        displayName: String,
        writeGate: VolumeWriteGate,
        minimumWriteInterval: TimeInterval
    ) -> DispatchWorkItem {
        DispatchWorkItem {
            let result: Result<Void, Error>
            var readbackValue: Double?

            do {
                writeGate.waitTurn(for: displayID, minimumInterval: minimumWriteInterval)
                try backend.writeVolume(targetValue)
                if needsReadback {
                    readbackValue = try? backend.readVolume()
                }
                result = .success(())
            } catch {
                result = .failure(error)
            }

            Task { @MainActor in
                controllerRef.value?.finishWrite(
                    for: displayID,
                    writeID: writeID,
                    targetValue: targetValue,
                    readbackValue: readbackValue,
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
