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

private final class BuiltInBrightnessRequest: @unchecked Sendable {
    let setterDeadline: ContinuousClock.Instant
    private let isEligible: @Sendable () -> Bool
    private let lock = NSLock()
    private var cancelled = false
    private var writeStarted = false
    @MainActor var continuation: CheckedContinuation<BuiltInBrightnessOutcome, Never>?

    init(setterDeadline: ContinuousClock.Instant, isEligible: @escaping @Sendable () -> Bool) {
        self.setterDeadline = setterDeadline
        self.isEligible = isEligible
    }

    func cancel(beforeWriteOnly: Bool = false) -> Bool {
        lock.withLock {
            if beforeWriteOnly, writeStarted { return false }
            cancelled = true
            return !writeStarted
        }
    }

    func beginWrite(timeoutMessage: String) throws {
        guard isEligible() else { throw CancellationError() }
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            guard ContinuousClock.now < setterDeadline else {
                throw DisplayBrightnessControllerError.failed(message: timeoutMessage)
            }
            writeStarted = true
        }
    }

    @MainActor
    func complete(_ outcome: BuiltInBrightnessOutcome) {
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(returning: outcome)
    }

    @MainActor
    func completeBeforeWrite(with error: any Error) {
        complete(BuiltInBrightnessOutcome(result: .failure(error), observed: nil, attemptedWrite: false))
    }

    @MainActor
    func invalidate() {
        if cancel() { completeBeforeWrite(with: CancellationError()) }
    }

    func validate() throws {
        guard isEligible(), !lock.withLock({ cancelled }) else { throw CancellationError() }
    }
}

private struct BuiltInBrightnessOutcome: Sendable {
    let result: Result<Void, Error>
    let observed: Double?
    let attemptedWrite: Bool
}

@MainActor
final class DisplayBrightnessController: DisplayBrightnessControlling {
    private struct ManagedDisplay {
        let connectionID: UUID
        let eventGeneration: UInt64?
        var display: DisplayInfo
        var backend: any DisplayBrightnessBackend
        var currentBrightness: Double
        var lastCommittedBrightness: Double
        var pendingBrightness: Double?
        var pendingWriteID: UInt64?
        var writeInFlight = false
        var inFlightWriteID: UInt64?
        var scheduledFlush: DispatchWorkItem?
        var pendingReadbackAfterWrite = false
        var lastWriteError: String?
        var hasBrightnessValue = false
        var readID: UInt64?
    }

    private enum RetiredWriteResolution {
        case actualOutcome
        case invalidated
    }

    private struct RetiredInFlightWrite {
        let backend: any DisplayBrightnessBackend
        var resolution: RetiredWriteResolution
    }

    // Dispatched hardware writes can outlive the plugin instance that started them.
    private static var reservedDisplays: Set<CGDirectDisplayID> = []
    private static var waitingControllers: [CGDirectDisplayID: [ObjectIdentifier: WeakBrightnessControllerRef]] = [:]

    var onStateChange: (() -> Void)?

    private let displayProvider: DisplayProviding
    private let connectionEvents: DisplayBrightnessConnectionEvents
    private let isBuiltInDisplayEligible: @Sendable (CGDirectDisplayID) -> Bool
    private let backendBuilder: DisplayBrightnessBackendBuilding
    private let localization: PluginLocalization
    private let logger = DisplayBrightnessLog.controller
    private let shortWriteDelay: TimeInterval
    private let minimumWriteInterval: TimeInterval
    private let writeTimeout: Duration
    private let writeGate = BrightnessWriteGate()
    private let readQueue = DispatchQueue(label: "cc.ggbond.mactools.brightness.read", qos: .userInitiated)
    private let builtInReadQueue = DispatchQueue(label: "cc.ggbond.mactools.brightness.built-in-read", qos: .userInitiated)
    private var readWorkItems: [CGDirectDisplayID: DispatchWorkItem] = [:]
    private var nextReadID: UInt64 = 0

    private var managedDisplays: [CGDirectDisplayID: ManagedDisplay] = [:]
    private var displayOrder: [CGDirectDisplayID] = []
    private var lastErrorMessage: String?
    private var nextWriteID: UInt64 = 0
    private var writeGeneration: UInt64 = 0
    private var writeWaiters: [UInt64: CheckedContinuation<DisplayBrightnessWriteResult, Never>] = [:]
    private var writeTimeoutTasks: [UInt64: Task<Void, Never>] = [:]
    private var waiterDisplayIDs: [UInt64: CGDirectDisplayID] = [:]
    private var retiredInFlightWrites: [UInt64: RetiredInFlightWrite] = [:]
    private var builtInWrites: [CGDirectDisplayID: BuiltInBrightnessRequest] = [:]
    private var replacedBackendsAwaitingWrites: [UInt64: [any DisplayBrightnessBackend]] = [:]
    private var invalidatedInFlightWriteIDs: Set<UInt64> = []
    private var terminateObserver: NSObjectProtocol?

    var pendingWriteTimeoutCount: Int { writeTimeoutTasks.count }

    #if DEBUG
    func waitForScheduledReadsForTests() async {
        let builtInReadQueue = builtInReadQueue
        await withCheckedContinuation { continuation in
            readQueue.async {
                builtInReadQueue.async {
                    Task { @MainActor in continuation.resume() }
                }
            }
        }
    }
    #endif

    init(
        displayProvider: DisplayProviding = SystemDisplayService(),
        isBuiltInDisplayEligible: @escaping @Sendable (CGDirectDisplayID) -> Bool = { id in
            CGDisplayIsBuiltin(id) != 0 && CGDisplayIsActive(id) != 0
                && (CGDisplayIsInMirrorSet(id) == 0 || CGDisplayIsMain(id) != 0)
        },
        connectionEvents: DisplayBrightnessConnectionEvents = DisplayBrightnessConnectionEvents(),
        backendBuilder: DisplayBrightnessBackendBuilding? = nil,
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        shortWriteDelay: TimeInterval = 0.08,
        minimumWriteInterval: TimeInterval = 0.08,
        writeTimeout: Duration = .seconds(10)
    ) {
        self.displayProvider = displayProvider
        self.isBuiltInDisplayEligible = isBuiltInDisplayEligible
        self.connectionEvents = connectionEvents
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
        let displays = displayProvider.listConnectedDisplays()
        let previousBackends = Dictionary(
            uniqueKeysWithValues: managedDisplays.map { ($0.key, $0.value.backend) }
        )
        let nextBackends = backendBuilder.backends(for: displays, previous: previousBackends)
        let nextDisplayIDs = Set(displays.map(\.id)).intersection(nextBackends.keys)

        cleanupDisconnectedDisplays(keeping: nextDisplayIDs)

        var nextManagedDisplays: [CGDirectDisplayID: ManagedDisplay] = [:]
        var nextDisplayOrder: [CGDirectDisplayID] = []

        for display in displays {
            guard let backend = nextBackends[display.id] else {
                continue
            }

            let eventGeneration = connectionEvents.generation(for: display.id)
            var previous = managedDisplays[display.id]
            let previousConnectionID = previous.flatMap {
                $0.eventGeneration == eventGeneration && $0.display.hasSameBrightnessControlIdentity(as: display)
                    ? $0.connectionID : nil
            }
            let canReuseBackend = previous?.backend === backend
            let canReuseReading = previousConnectionID != nil && canReuseBackend
            if !canReuseReading {
                builtInWrites[display.id]?.invalidate()
                readWorkItems.removeValue(forKey: display.id)?.cancel()
            }
            if previousConnectionID == nil, var oldDisplay = previous {
                discardPendingWrite(&oldDisplay)
                if let writeID = oldDisplay.inFlightWriteID {
                    invalidatedInFlightWriteIDs.insert(writeID)
                }
                previous = oldDisplay
            }
            if let previous, !canReuseBackend {
                if let writeID = previous.inFlightWriteID {
                    replacedBackendsAwaitingWrites[writeID, default: []].append(previous.backend)
                } else {
                    previous.backend.cleanup()
                }
            }
            let brightness = previous?.currentBrightness ?? 1

            nextManagedDisplays[display.id] = ManagedDisplay(
                connectionID: previousConnectionID ?? UUID(),
                eventGeneration: eventGeneration,
                display: display,
                backend: backend,
                currentBrightness: previous?.pendingBrightness ?? brightness,
                lastCommittedBrightness: previous?.lastCommittedBrightness ?? brightness,
                pendingBrightness: previous?.pendingBrightness,
                pendingWriteID: previous?.pendingWriteID,
                writeInFlight: previous?.writeInFlight ?? false,
                inFlightWriteID: previous?.inFlightWriteID,
                scheduledFlush: previous?.scheduledFlush,
                pendingReadbackAfterWrite: previous?.pendingReadbackAfterWrite ?? false,
                lastWriteError: previous?.lastWriteError,
                hasBrightnessValue: canReuseReading && previous?.hasBrightnessValue == true,
                readID: canReuseReading ? previous?.readID : nil
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
                isPendingWrite: managedDisplay.pendingBrightness != nil || isWriting(displayID),
                isReady: managedDisplay.hasBrightnessValue
            )
        }

        return DisplayBrightnessSnapshot(
            displays: displays,
            errorMessage: lastErrorMessage
        )
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
        let pendingAtStart = managed.pendingBrightness != nil || isWriting(displayID)
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
            isPendingWrite: pendingAtStart || current.pendingBrightness != nil || isWriting(displayID)
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
                enqueueBrightness(
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

    var canSetBuiltInBrightness: Bool {
        guard let displayID = builtInDisplayID else { return false }
        return connectionEvents.generation(for: displayID) != nil
    }

    private var builtInDisplayID: CGDirectDisplayID? {
        displayOrder.first { managedDisplays[$0]?.display.isBuiltin == true && isBuiltInDisplayEligible($0) }
    }

    func setBuiltInBrightnessAndWait(_ value: Double) async -> DisplayBrightnessWriteResult {
        guard let displayID = builtInDisplayID, let connectionID = managedDisplays[displayID]?.connectionID,
              let eventGeneration = connectionEvents.generation(for: displayID), (0...1).contains(value) else {
            return .failed(message: PluginKitLocalization.actionUnavailable)
        }

        let generation = writeGeneration
        let waitDeadline = ContinuousClock.now.advanced(by: .milliseconds(250))
        while let display = managedDisplays[displayID], display.connectionID == connectionID,
              display.eventGeneration == eventGeneration,
              builtInDisplayID == displayID, connectionEvents.generation(for: displayID) == eventGeneration,
              generation == writeGeneration, !Task.isCancelled {
            guard ContinuousClock.now < waitDeadline else { return .failed(message: writeTimeoutMessage) }
            if !isWriting(displayID), display.pendingBrightness == nil, display.readID == nil {
                return await writeBuiltInBrightness(value, for: display, eventGeneration: eventGeneration)
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return .failed(message: PluginKitLocalization.actionUnavailable)
    }

    private func writeBuiltInBrightness(
        _ value: Double,
        for display: ManagedDisplay,
        eventGeneration: UInt64
    ) async -> DisplayBrightnessWriteResult {
        let displayID = display.display.id
        let previousBackend = display.backend
        guard let backend = previousBackend.kind == .appleNative
            ? previousBackend : backendBuilder.nativeBackend(forBuiltInDisplay: display.display),
            backend.kind == .appleNative else {
            return writeResult(from: .failure(DisplayBrightnessControllerError.nativeAPINotAvailable))
        }

        let request = BuiltInBrightnessRequest(setterDeadline: ContinuousClock.now.advanced(by: writeTimeout)) {
            [isBuiltInDisplayEligible, connectionEvents] in
            isBuiltInDisplayEligible(displayID) && connectionEvents.generation(for: displayID) == eventGeneration
        }
        Self.reservedDisplays.insert(displayID)
        builtInWrites[displayID] = request
        _ = makeWriteID() // Invalidate observations that started before the write.

        let writeGate = writeGate
        let minimumWriteInterval = minimumWriteInterval
        let timeoutMessage = writeTimeoutMessage
        let timeoutTask = Task { @MainActor in
            do {
                try await Task.sleep(until: request.setterDeadline, clock: .continuous)
            } catch {
                return
            }
            if request.cancel(beforeWriteOnly: true) {
                request.completeBeforeWrite(with: DisplayBrightnessControllerError.failed(message: timeoutMessage))
            }
        }
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                request.continuation = continuation
                onStateChange?()
                DispatchQueue.global(qos: .userInitiated).async {
                    writeGate.waitTurn(for: displayID, minimumInterval: minimumWriteInterval)
                    let outcome = Self.verifyBuiltInWrite(
                        value, backend: backend, request: request, timeoutMessage: timeoutMessage
                    )
                    Task { @MainActor in request.complete(outcome) }
                }
            }
        } onCancel: {
            if request.cancel() {
                Task { @MainActor in request.completeBeforeWrite(with: CancellationError()) }
            }
        }
        var shouldResume = true
        defer {
            timeoutTask.cancel()
            builtInWrites.removeValue(forKey: displayID)
            releaseWriteReservation(for: displayID)
            if shouldResume { resumeDisplayWork(for: displayID) }
            onStateChange?()
        }

        if !outcome.attemptedWrite, case .failure(let error as DisplayBrightnessControllerError) = outcome.result,
           case .failed = error {
            return writeResult(from: outcome.result)
        }

        guard var current = managedDisplays[displayID], current.backend === previousBackend,
              (try? request.validate()) != nil else {
            if outcome.attemptedWrite, managedDisplays[displayID]?.backend === backend {
                managedDisplays[displayID]?.hasBrightnessValue = false
            }
            return .failed(message: PluginKitLocalization.actionUnavailable)
        }

        if case .success = outcome.result {
            if backend !== previousBackend {
                do {
                    try previousBackend.restoreForNativeHandoff()
                } catch {
                    return writeResult(from: .failure(error))
                }
            }
            current.backend = backend
            current.lastWriteError = nil
            lastErrorMessage = nil
        }
        if current.backend === backend {
            if let observed = outcome.observed {
                current.lastCommittedBrightness = observed
                if current.pendingBrightness == nil { current.currentBrightness = observed }
                current.hasBrightnessValue = true
            } else if outcome.attemptedWrite {
                current.hasBrightnessValue = false
            }
        }
        managedDisplays[displayID] = current
        shouldResume = current.pendingBrightness != nil || !current.hasBrightnessValue
        return writeResult(from: outcome.result)
    }

    private func isWriting(_ displayID: CGDirectDisplayID) -> Bool {
        Self.reservedDisplays.contains(displayID)
    }

    private func registerForReservationRelease(for displayID: CGDirectDisplayID) {
        Self.waitingControllers[displayID, default: [:]][ObjectIdentifier(self)] = WeakBrightnessControllerRef(self)
    }

    private func releaseWriteReservation(for displayID: CGDirectDisplayID) {
        Self.reservedDisplays.remove(displayID)
        guard let waiters = Self.waitingControllers.removeValue(forKey: displayID) else { return }
        for waiter in waiters.values {
            if let controller = waiter.value, controller !== self {
                controller.resumeDisplayWork(for: displayID)
            }
        }
    }

    private func resumeDisplayWork(for displayID: CGDirectDisplayID) {
        if managedDisplays[displayID]?.pendingBrightness != nil {
            scheduleWrite(for: displayID, delay: 0)
        } else {
            scheduleRead(for: displayID)
        }
    }

    func cancelOutstandingWrites() {
        writeGeneration &+= 1
        for request in builtInWrites.values { request.invalidate() }
        cancelReads()
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

    private func enqueueBrightness(
        _ value: Double,
        for displayID: CGDirectDisplayID,
        phase: PluginPanelAction.SliderPhase,
        writeID: UInt64
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

        guard managedDisplay.hasBrightnessValue else {
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
        managedDisplay.lastWriteError = nil
        lastErrorMessage = nil
        managedDisplays[displayID] = managedDisplay

        let delay = phase == .ended ? 0 : shortWriteDelay
        scheduleWrite(for: displayID, delay: delay)

        onStateChange?()
    }

    private func scheduleRead(for displayID: CGDirectDisplayID) {
        guard var managedDisplay = managedDisplays[displayID],
              builtInWrites[displayID] == nil,
              managedDisplay.readID == nil,
              managedDisplay.pendingBrightness == nil,
              !managedDisplay.writeInFlight else { return }
        guard !isWriting(displayID) else {
            registerForReservationRelease(for: displayID)
            return
        }

        nextReadID &+= 1
        let readID = nextReadID
        managedDisplay.readID = readID
        managedDisplays[displayID] = managedDisplay
        let backend = managedDisplay.backend

        // Shade reads only cached state and may touch AppKit overlay geometry.
        if backend.kind == .shade {
            finishRead(for: displayID, readID: readID, result: Result { try backend.readBrightness() })
            return
        }
        let workItem = Self.makeReadWorkItem(
            controllerRef: WeakBrightnessControllerRef(self),
            backend: backend,
            displayID: displayID,
            readID: readID
        )
        readWorkItems[displayID] = workItem
        let queue = managedDisplay.display.isBuiltin ? builtInReadQueue : readQueue
        queue.async(execute: workItem)
    }

    private func finishRead(for displayID: CGDirectDisplayID, readID: UInt64, result: Result<Double, Error>) {
        guard var managedDisplay = managedDisplays[displayID],
              managedDisplay.readID == readID else { return }
        readWorkItems.removeValue(forKey: displayID)
        managedDisplay.readID = nil
        switch result {
        case .success(let value):
            let brightness = Self.clamp(value)
            managedDisplay.currentBrightness = brightness
            managedDisplay.lastCommittedBrightness = brightness
            managedDisplay.hasBrightnessValue = true
        case .failure(let error):
            if !managedDisplay.hasBrightnessValue {
                if managedDisplay.backend.kind == .ddc {
                    // Some monitors accept Set VCP without replying to Get VCP.
                    // Keep cached/default brightness usable until a write proves unavailable.
                    managedDisplay.hasBrightnessValue = true
                } else if let fallback = fallbackBackend(for: displayID, failedBackend: managedDisplay.backend) {
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

        guard let targetValue = managedDisplay.pendingBrightness,
              let writeID = managedDisplay.pendingWriteID else {
            return
        }
        guard connectionEvents.generation(for: displayID) == managedDisplay.eventGeneration else {
            discardPendingWrite(&managedDisplay)
            managedDisplays[displayID] = managedDisplay
            refresh()
            return
        }
        guard Self.reservedDisplays.insert(displayID).inserted else {
            registerForReservationRelease(for: displayID)
            return
        }

        managedDisplay.writeInFlight = true
        managedDisplay.inFlightWriteID = writeID
        managedDisplay.pendingBrightness = nil
        managedDisplay.pendingWriteID = nil
        managedDisplay.scheduledFlush = nil
        let needsReadback = managedDisplay.pendingReadbackAfterWrite
        managedDisplay.pendingReadbackAfterWrite = false
        let backend = managedDisplay.backend
        let displayName = managedDisplay.display.name
        managedDisplays[displayID] = managedDisplay

        DispatchQueue.global(qos: .userInitiated).async(
            execute: Self.makeWriteWorkItem(
                controller: self,
                backend: backend,
                displayID: displayID,
                writeID: writeID,
                targetValue: targetValue,
                needsReadback: needsReadback,
                displayName: displayName,
                connectionEvents: connectionEvents,
                eventGeneration: managedDisplay.eventGeneration,
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
        let replacedBackends = replacedBackendsAwaitingWrites.removeValue(forKey: writeID) ?? []
        for backend in replacedBackends {
            backend.cleanup()
        }
        if let retired = retiredInFlightWrites.removeValue(forKey: writeID) {
            retired.backend.cleanup()
            releaseWriteReservation(for: displayID)
            switch retired.resolution {
            case .actualOutcome:
                resolveWrite(writeID, with: writeResult(from: result))
            case .invalidated:
                resolveWrite(
                    writeID,
                    with: .failed(message: PluginKitLocalization.actionUnavailable)
                )
            }
            resumeDisplayWork(for: displayID)
            onStateChange?()
            return
        }
        // The rest of completion is synchronous on the main actor.
        releaseWriteReservation(for: displayID)

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

        if invalidatedInFlightWriteIDs.remove(writeID) != nil {
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
            managedDisplay.lastCommittedBrightness = committedBrightness
            if managedDisplay.pendingBrightness == nil {
                managedDisplay.currentBrightness = committedBrightness
            }
            lastErrorMessage = nil
            managedDisplay.lastWriteError = nil
            resolveWrite(writeID, with: .succeeded)
        case .failure(let error):
            let localizedDescription = localizedDescription(for: error)
            logger.error(
                "write failed for \(displayName, privacy: .public): \(localizedDescription, privacy: .public)"
            )

            if let fallbackBackend = fallbackBackend(for: displayID, failedBackend: managedDisplay.backend) {
                logger.info(
                    "retrying brightness write for \(displayName, privacy: .public) with \(String(describing: fallbackBackend.kind), privacy: .public) fallback"
                )
                managedDisplay.backend.cleanup()
                managedDisplay.backend = fallbackBackend
                if managedDisplay.pendingWriteID == nil {
                    managedDisplay.pendingBrightness = targetValue
                    managedDisplay.pendingWriteID = writeID
                    managedDisplay.pendingReadbackAfterWrite = true
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
            builtInWrites[displayID]?.invalidate()
            readWorkItems.removeValue(forKey: displayID)?.cancel()
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
        writeGeneration &+= 1
        for request in builtInWrites.values { request.invalidate() }
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
        writeTimeoutTasks.removeValue(forKey: writeID)?.cancel()
        waiterDisplayIDs.removeValue(forKey: writeID)
        writeWaiters.removeValue(forKey: writeID)?.resume(returning: result)
    }

    private var writeTimeoutMessage: String {
        localization.string("error.adjustTimedOut", defaultValue: "亮度调节超时。")
    }

    private func timeOutWrite(_ writeID: UInt64) {
        failWriteUnlessInFlight(
            writeID,
            message: writeTimeoutMessage,
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
            managedDisplay.pendingBrightness = nil
            managedDisplay.pendingWriteID = nil
            managedDisplay.currentBrightness = managedDisplay.lastCommittedBrightness
            managedDisplays[displayID] = managedDisplay
            if !managedDisplay.hasBrightnessValue { scheduleRead(for: displayID) }
            onStateChange?()
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

    private func discardPendingWrite(_ display: inout ManagedDisplay) {
        guard display.pendingWriteID != nil else { return }
        failOutstandingWrites(for: display.display.id, managedDisplay: display)
        display.scheduledFlush?.cancel()
        display.scheduledFlush = nil
        display.pendingBrightness = nil
        display.pendingWriteID = nil
        display.pendingReadbackAfterWrite = false
        display.currentBrightness = display.lastCommittedBrightness
    }

    private func retireInFlightWrite(
        _ writeID: UInt64,
        backend: any DisplayBrightnessBackend,
        resolution: RetiredWriteResolution
    ) {
        writeTimeoutTasks.removeValue(forKey: writeID)?.cancel()
        invalidatedInFlightWriteIDs.remove(writeID)
        retiredInFlightWrites[writeID] = RetiredInFlightWrite(
            backend: backend,
            resolution: resolution
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
        readID: UInt64
    ) -> DispatchWorkItem {
        DispatchWorkItem {
            let result = Result { try backend.readBrightness() }
            Task { @MainActor in
                controllerRef.value?.finishRead(for: displayID, readID: readID, result: result)
            }
        }
    }

    nonisolated private static func verifyBuiltInWrite(
        _ value: Double,
        backend: any DisplayBrightnessBackend,
        request: BuiltInBrightnessRequest,
        timeoutMessage: String
    ) -> BuiltInBrightnessOutcome {
        var observed: Double?
        var attemptedWrite = false
        do {
            try request.validate()
            guard (0...1).contains(try backend.readBrightness()) else {
                throw DisplayBrightnessControllerError.genericBrightnessUnavailable
            }
            try request.beginWrite(timeoutMessage: timeoutMessage)
            attemptedWrite = true
            try backend.writeBrightness(value)
            let requestedPercent = (value * 100).rounded()
            for delay in [0.0, 0.15, 0.30] {
                if delay > 0 { Thread.sleep(forTimeInterval: delay) }
                try request.validate()
                guard let level = try? backend.readBrightness(), (0...1).contains(level) else { continue }
                if (level * 100).rounded() == requestedPercent {
                    return BuiltInBrightnessOutcome(result: .success(()), observed: level, attemptedWrite: true)
                }
                observed = level
            }
            guard let observed else { throw DisplayBrightnessControllerError.genericBrightnessUnavailable }
            throw DisplayBrightnessControllerError.nativeBrightnessReadbackMismatch(requested: value, observed: observed)
        } catch {
            return BuiltInBrightnessOutcome(result: .failure(error), observed: observed, attemptedWrite: attemptedWrite)
        }
    }

    nonisolated private static func makeWriteWorkItem(
        controller: DisplayBrightnessController,
        backend: any DisplayBrightnessBackend,
        displayID: CGDirectDisplayID,
        writeID: UInt64,
        targetValue: Double,
        needsReadback: Bool,
        displayName: String,
        connectionEvents: DisplayBrightnessConnectionEvents,
        eventGeneration: UInt64?,
        writeGate: BrightnessWriteGate,
        minimumWriteInterval: TimeInterval
    ) -> DispatchWorkItem {
        DispatchWorkItem {
            let result: Result<Void, Error>
            var readbackValue: Double?

            do {
                writeGate.waitTurn(for: displayID, minimumInterval: minimumWriteInterval)
                guard connectionEvents.generation(for: displayID) == eventGeneration else {
                    throw DisplayBrightnessControllerError.displayUnavailable(displayID: displayID)
                }
                try backend.writeBrightness(targetValue)
                if needsReadback {
                    readbackValue = try? backend.readBrightness()
                }
                result = .success(())
            } catch {
                result = .failure(error)
            }

            Task { @MainActor in
                if case .failure = result,
                   controller.managedDisplays[displayID]?.inFlightWriteID == writeID,
                   connectionEvents.generation(for: displayID) != eventGeneration {
                    controller.invalidatedInFlightWriteIDs.insert(writeID)
                }
                controller.finishWrite(
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
