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
    typealias Arm64ServiceResolver = ([DisplayInfo]) -> [CGDirectDisplayID: CFTypeRef]
    typealias DDCBackendFactory = (DisplayInfo, CFTypeRef?) -> (any DisplayVolumeBackend)?

    private let resolveArm64Services: Arm64ServiceResolver
    private let ddcFactory: DDCBackendFactory

    init(
        resolveArm64Services: @escaping Arm64ServiceResolver = Arm64DDCServiceMatcher.resolveServices,
        ddcFactory: DDCBackendFactory? = nil
    ) {
        self.resolveArm64Services = resolveArm64Services
        self.ddcFactory = ddcFactory ?? { display, matchedService in
            if let transport = Arm64DDCTransport(display: display, service: nil) {
                return DDCVolumeBackend(display: display, transport: transport)
            }

            if let matchedService,
               let transport = Arm64DDCTransport(display: display, service: matchedService) {
                return DDCVolumeBackend(display: display, transport: transport)
            }

            return nil
        }
    }

    func backends(
        for displays: [DisplayInfo],
        previous: [CGDirectDisplayID: any DisplayVolumeBackend]
    ) -> [CGDirectDisplayID: any DisplayVolumeBackend] {
        var arm64Services: [CGDirectDisplayID: CFTypeRef]?
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
        cache arm64Services: inout [CGDirectDisplayID: CFTypeRef]?
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
        cache arm64Services: inout [CGDirectDisplayID: CFTypeRef]?
    ) -> CFTypeRef? {
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
    private var maximumValue: UInt16
    private var localVolume: Double
    private let cacheKey: String

    var cachedVolume: Double { lock.withLock { localVolume } }

    init?(display: DisplayInfo, transport: any DDCVolumeTransport) {
        guard !display.isBuiltin else {
            return nil
        }

        self._display = display
        self.transport = transport
        self.maximumValue = 100
        self.cacheKey = "ddc-volume-\(display.id)"

        if let cached = UserDefaults.standard.object(forKey: cacheKey) as? Double,
           cached.isFinite {
            self.localVolume = max(0, min(cached, 1))
        } else {
            self.localVolume = 0.15
        }
    }

    func readVolume() throws -> Double {
        let revision = lock.withLock { cacheRevision }
        let result = try ioLock.withLock { () -> (volume: Double, updated: Bool) in
            try Task.checkCancellation()
            guard let volume = try? transport.readVolume(),
                  volume.maximum > 0,
                  volume.current <= volume.maximum else {
                return (cachedVolume, false)
            }
            return lock.withLock {
                guard !Task.isCancelled, revision == cacheRevision else { return (localVolume, false) }
                maximumValue = volume.maximum
                localVolume = Double(volume.current) / Double(volume.maximum)
                return (localVolume, true)
            }
        }
        if result.updated { persistCachedVolume() }
        return result.volume
    }

    func writeVolume(_ value: Double) throws {
        let clampedValue = max(0, min(value, 1))
        lock.withLock { cacheRevision &+= 1 }
        try ioLock.withLock {
            let rawValue = lock.withLock {
                UInt16((Double(maximumValue) * clampedValue).rounded())
            }
            try transport.writeVolume(rawValue)
            lock.withLock {
                localVolume = clampedValue
            }
        }
        persistCachedVolume()
    }

    private func persistCachedVolume() {
        // Defaults notifications enter SwiftUI synchronously. Publish on the main
        // queue after releasing both locks, so UI snapshot reads cannot deadlock.
        // Read the latest cache when publishing so queued reads cannot overwrite
        // a newer completed write.
        if Thread.isMainThread {
            UserDefaults.standard.set(cachedVolume, forKey: cacheKey)
        } else {
            DispatchQueue.main.async { [self] in
                UserDefaults.standard.set(cachedVolume, forKey: cacheKey)
            }
        }
    }

    func cleanup() {
        lock.withLock { cacheRevision &+= 1 }
    }
}
