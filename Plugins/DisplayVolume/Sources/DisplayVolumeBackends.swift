import AppKit
import CoreGraphics
import Foundation
import MacToolsPluginKit
import OSLog

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

final class SystemDisplayVolumeBackendBuilder: DisplayVolumeBackendBuilding {
    typealias Arm64ServiceResolver = ([DisplayInfo]) -> [CGDirectDisplayID: Arm64DDCServiceMatcher.Binding]
    typealias DDCBackendFactory = (DisplayInfo, Arm64DDCServiceMatcher.Binding?) -> (any DisplayVolumeBackend)?

    private let resolveArm64Services: Arm64ServiceResolver
    private let ddcFactory: DDCBackendFactory

    init(
        resolveArm64Services: @escaping Arm64ServiceResolver = Arm64DDCServiceMatcher.resolveServices,
        ddcFactory: DDCBackendFactory? = nil
    ) {
        self.resolveArm64Services = resolveArm64Services
        self.ddcFactory = ddcFactory ?? { display, matchedService in
            let generation = DisplayDDCIdentity.bindingGeneration
            let identifier = DisplayActionTarget.identifier(for: display.id)
            guard let transport = Arm64DDCTransport(display: display, service: nil) ?? matchedService.flatMap({ binding in
                Arm64DDCTransport(
                    display: display,
                    service: binding.service,
                    verifiedDiscovery: binding.verified,
                    registryEntryID: binding.registryEntryID,
                    bindingGeneration: binding.generation
                )
            }) else { return nil }
            let canCache = generation == DisplayDDCIdentity.bindingGeneration && transport.isDiscoveryCurrent
            return DDCVolumeBackend(display: display, transport: transport, identifier: canCache ? identifier : nil)
        }
    }

    func backends(
        for displays: [DisplayInfo],
        previous: [CGDirectDisplayID: any DisplayVolumeBackend]
    ) -> [CGDirectDisplayID: any DisplayVolumeBackend] {
        var arm64Services: [CGDirectDisplayID: Arm64DDCServiceMatcher.Binding]?
        var result: [CGDirectDisplayID: any DisplayVolumeBackend] = [:]

        for display in displays {
            guard let backend = ddcBackend(
                for: display,
                in: displays,
                previous: previous,
                cache: &arm64Services
            ) else {
                continue
            }

            result[display.id] = backend
        }

        return result
    }

    private func ddcBackend(
        for display: DisplayInfo,
        in displays: [DisplayInfo],
        previous: [CGDirectDisplayID: any DisplayVolumeBackend],
        cache arm64Services: inout [CGDirectDisplayID: Arm64DDCServiceMatcher.Binding]?
    ) -> (any DisplayVolumeBackend)? {
        guard let backend = reuse(previous[display.id], display: display)
            ?? ddcFactory(display, resolvedArm64Service(for: display, in: displays, cache: &arm64Services)) else {
            return nil
        }

        Logger(subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools", category: "DisplayVolumeBackend").debug(
            "selected DDC volume backend for \(display.name, privacy: .public)"
        )
        return backend
    }

    private func resolvedArm64Service(
        for display: DisplayInfo,
        in displays: [DisplayInfo],
        cache arm64Services: inout [CGDirectDisplayID: Arm64DDCServiceMatcher.Binding]?
    ) -> Arm64DDCServiceMatcher.Binding? {
        if arm64Services == nil {
            arm64Services = resolveArm64Services(displays)
        }

        return arm64Services?[display.id]
    }

    private func reuse(
        _ previous: (any DisplayVolumeBackend)?,
        display: DisplayInfo
    ) -> (any DisplayVolumeBackend)? {
        guard let backend = previous else {
            return nil
        }

        backend.display = display
        return backend
    }
}

final class DDCVolumeBackend: DisplayVolumeBackend, @unchecked Sendable {
    struct CachedState {
        let registryEntryID: UInt64
        let maximum: UInt16?
        let level: Double
    }

    let kind: DisplayVolumeBackendKind = .ddc

    private let lock = NSLock()
    private let ioLock = NSLock()
    private var cacheRevision: UInt64 = 0
    private var _display: DisplayInfo
    var display: DisplayInfo {
        get { lock.withLock { _display } }
        set { lock.withLock { _display = newValue } }
    }

    private let transport: any DDCVolumeTransport
    private var maximumValue: UInt16?
    private var localVolume: Double?
    private var cachedVolumeHint: Double?
    private var writePending = false
    private var retired = false
    private let cacheKey: String?

    private static let displayPlaceholder = 0.15

    var cachedVolume: Double { lock.withLock { localVolume ?? cachedVolumeHint ?? Self.displayPlaceholder } }
    var hasKnownVolume: Bool { lock.withLock { localVolume != nil } }

    init?(display: DisplayInfo, transport: any DDCVolumeTransport, identifier: String? = nil) {
        guard !display.isBuiltin else {
            return nil
        }

        self._display = display
        self.transport = transport
        self.cacheKey = identifier.map { "ddc-volume-target-\($0)" }

        if let cacheKey, let cached = UserDefaults.standard.object(forKey: cacheKey) as? Double,
           cached.isFinite {
            // The display UUID can outlive its DDC endpoint. A saved level is
            // useful for display, but relative writes need a current baseline.
            self.cachedVolumeHint = max(0, min(cached, 1))
        }
    }

    func cachedState(level: Double) -> CachedState? {
        guard let entryID = transport.registryEntryID else { return nil }
        return lock.withLock {
            guard !writePending, localVolume != nil else { return nil }
            return CachedState(registryEntryID: entryID, maximum: maximumValue, level: level)
        }
    }

    func reuseCachedState(_ state: CachedState) -> Bool {
        guard transport.registryEntryID == state.registryEntryID else { return false }
        lock.withLock {
            maximumValue = state.maximum
            localVolume = state.level
        }
        return true
    }

    func readVolume() throws -> Double { try readVolume(allowCached: true) }

    func readFreshVolume() throws -> Double { try readVolume(allowCached: false) }

    func readVerifiedVolume() throws -> Double {
        guard hasVerifiedDisplayBinding else { throw DisplayVolumeControllerError.unverifiedDisplayBinding }
        return try readFreshVolume()
    }

    private func readVolume(allowCached: Bool) throws -> Double {
        let revision = lock.withLock { cacheRevision }
        let result = try ioLock.withLock { () -> (volume: Double, updated: Bool) in
            try Task.checkCancellation()
            let observation = readHardwareVolume()
            guard transport.isDiscoveryCurrent else {
                if allowCached { return (cachedVolume, false) }
                throw CancellationError()
            }
            guard let volume = observation else {
                guard allowCached else { throw DisplayVolumeControllerError.volumeUnavailable(displayName: display.name) }
                return (cachedVolume, false)
            }
            return try lock.withLock {
                guard !Task.isCancelled, revision == cacheRevision else {
                    guard allowCached else { throw CancellationError() }
                    return (localVolume ?? cachedVolumeHint ?? Self.displayPlaceholder, false)
                }
                let level = Double(volume.current) / Double(volume.maximum)
                maximumValue = volume.maximum
                localVolume = level
                return (level, true)
            }
        }
        if result.updated { persistCachedVolume() }
        return result.volume
    }

    func writeVolume(_ value: Double) throws {
        try writeVolume(value, permit: nil)
    }

    func writeVolume(_ value: Double, permit: DisplayActionWritePermit?) throws {
        let clampedValue = max(0, min(value, 1))
        var didCommitLevel = false
        defer { completeCachedWrite(didAttempt: permit?.didAttemptWrite == true, knowsLevel: didCommitLevel) }
        lock.withLock { cacheRevision &+= 1 }
        try ioLock.withLock {
            guard permit?.canWrite != false, transport.isDiscoveryCurrent else { throw CancellationError() }
            let knownMaximum = lock.withLock { maximumValue } ?? readHardwareVolume()?.maximum
            let maximum = knownMaximum ?? 100
            let rawValue = UInt16((Double(maximum) * clampedValue).rounded())
            try transport.writeVolume(rawValue, permit: permit)
            guard permit?.canWrite != false, transport.isDiscoveryCurrent else { throw CancellationError() }
            lock.withLock {
                maximumValue = knownMaximum
                localVolume = clampedValue
            }
            didCommitLevel = true
        }
    }

    var hasVerifiedDisplayBinding: Bool { transport.hasVerifiedDisplayBinding }
    var usesDiscoveredService: Bool { transport.usesDiscoveredService }

    @MainActor
    func prepareWrite() {
        // A SET can take effect even if a retry or readback fails. Clear the
        // durable baseline before the worker can reach the transport.
        lock.withLock {
            writePending = true
            cacheRevision &+= 1
            cachedVolumeHint = nil
        }
        if let cacheKey { UserDefaults.standard.removeObject(forKey: cacheKey) }
    }

    func writeExactVolume(_ value: Double, permit: DisplayActionWritePermit) throws -> Double {
        var hasObservation = false
        defer { completeCachedWrite(didAttempt: permit.didAttemptWrite, knowsLevel: hasObservation) }
        guard hasVerifiedDisplayBinding else { throw DisplayVolumeControllerError.unverifiedDisplayBinding }
        lock.withLock { cacheRevision &+= 1 }
        return try ioLock.withLock {
            guard permit.canWrite, transport.isDiscoveryCurrent else { throw CancellationError() }
            guard let initial = readHardwareVolume() else {
                throw DisplayVolumeControllerError.volumeUnavailable(displayName: display.name)
            }
            guard let step = ActionPercentage.hardwareStep(for: value, maximum: initial.maximum) else {
                guard permit.isTargetCurrent, transport.isDiscoveryCurrent else { throw CancellationError() }
                let level = Double(initial.current) / Double(initial.maximum)
                lock.withLock {
                    maximumValue = initial.maximum
                    localVolume = level
                }
                hasObservation = true
                throw DisplayVolumeControllerError.unsupportedHardwareLevel(observed: level)
            }
            try transport.writeVolume(step, permit: permit)

            for delay in [0.0, 0.15, 0.30] {
                if delay > 0 { Thread.sleep(forTimeInterval: delay) }
                guard permit.canWrite, transport.isDiscoveryCurrent else { throw CancellationError() }
                guard let observed = readHardwareVolume() else { continue }
                guard permit.isTargetCurrent, transport.isDiscoveryCurrent else { throw CancellationError() }
                let level = Double(observed.current) / Double(observed.maximum)
                lock.withLock {
                    maximumValue = observed.maximum
                    localVolume = level
                }
                hasObservation = true
                if ActionPercentage.matchesHardwareLevel(raw: observed.current, maximum: observed.maximum, requested: value) {
                    return level
                }
            }
            throw DisplayVolumeControllerError.ddcWriteFailed(displayName: display.name)
        }
    }

    private func completeCachedWrite(didAttempt: Bool, knowsLevel: Bool) {
        let wasPrepared = lock.withLock {
            let wasPrepared = writePending
            writePending = false
            if didAttempt, !knowsLevel { localVolume = nil }
            return wasPrepared
        }
        if wasPrepared || knowsLevel { persistCachedVolume() }
    }

    private func readHardwareVolume() -> DDCVolumeValue? {
        guard transport.isDiscoveryCurrent, let value = try? transport.readVolume(),
              transport.isDiscoveryCurrent, value.maximum > 0, value.current <= value.maximum else { return nil }
        return value
    }

    private func persistCachedVolume() {
        // Defaults notifications enter SwiftUI synchronously. Publish on the main
        // queue after releasing both locks, so UI snapshot reads cannot deadlock.
        // Read the latest cache when publishing so queued reads cannot overwrite
        // a newer completed write.
        guard let cacheKey else { return }
        let publish = { @Sendable [self] in
            let volume = lock.withLock { retired || writePending ? nil : localVolume }
            guard let volume, transport.isDiscoveryCurrent else { return }
            UserDefaults.standard.set(volume, forKey: cacheKey)
        }
        if Thread.isMainThread {
            publish()
        } else {
            DispatchQueue.main.async(execute: publish)
        }
    }

    func cleanup() {
        lock.withLock {
            retired = true
            cacheRevision &+= 1
        }
    }
}
