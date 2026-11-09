import AppKit
import CoreGraphics
import Foundation
import MacToolsPluginKit

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

final class SystemDisplayBrightnessBackendBuilder: DisplayBrightnessBackendBuilding {
    typealias Arm64ServiceResolver = ([DisplayInfo]) -> [CGDirectDisplayID: Arm64DDCServiceMatcher.Binding]
    typealias AppleBackendFactory = (DisplayInfo) -> (any DisplayBrightnessBackend)?
    typealias DDCBackendFactory = (DisplayInfo, Arm64DDCServiceMatcher.Binding?) -> (any DisplayBrightnessBackend)?
    typealias SoftwareBackendFactory = (DisplayInfo) -> (any DisplayBrightnessBackend)?

    private enum BackendCandidate: Equatable {
        case appleNative
        case ddc
        case gamma
        case shade

        init(kind: DisplayBrightnessBackendKind) {
            switch kind {
            case .appleNative:
                self = .appleNative
            case .ddc:
                self = .ddc
            case .gamma:
                self = .gamma
            case .shade:
                self = .shade
            }
        }
    }

    private let resolveArm64Services: Arm64ServiceResolver
    private let appleFactory: AppleBackendFactory
    private let ddcFactory: DDCBackendFactory
    private let gammaFactory: SoftwareBackendFactory
    private let shadeFactory: SoftwareBackendFactory

    init(
        resolveArm64Services: @escaping Arm64ServiceResolver = Arm64DDCServiceMatcher.resolveServices,
        appleFactory: AppleBackendFactory? = nil,
        ddcFactory: DDCBackendFactory? = nil,
        gammaFactory: SoftwareBackendFactory? = nil,
        shadeFactory: SoftwareBackendFactory? = nil
    ) {
        let displayServicesBridge = DisplayServicesBrightnessBridge()

        self.resolveArm64Services = resolveArm64Services
        self.appleFactory = appleFactory ?? { display in
            AppleNativeBrightnessBackend(
                display: display,
                bridge: displayServicesBridge
            )
        }
        self.ddcFactory = ddcFactory ?? { display, matchedService in
            if let transport = Arm64DDCTransport(display: display, service: nil) {
                return DDCBrightnessBackend(display: display, transport: transport)
            }

            if let matchedService,
               let transport = Arm64DDCTransport(
                   display: display,
                   service: matchedService.service,
                   verifiedDiscovery: matchedService.verified,
                   registryEntryID: matchedService.registryEntryID,
                   bindingGeneration: matchedService.generation
               ) {
                return DDCBrightnessBackend(display: display, transport: transport)
            }

            if let transport = IntelDDCTransport(display: display) {
                return DDCBrightnessBackend(display: display, transport: transport)
            }

            return nil
        }
        self.gammaFactory = gammaFactory ?? { display in
            GammaBrightnessBackend(display: display)
        }
        self.shadeFactory = shadeFactory ?? { display in
            ShadeBrightnessBackend(display: display)
        }
    }

    func backends(
        for displays: [DisplayInfo],
        previous: [CGDirectDisplayID: any DisplayBrightnessBackend]
    ) -> [CGDirectDisplayID: any DisplayBrightnessBackend] {
        var arm64Services: [CGDirectDisplayID: Arm64DDCServiceMatcher.Binding]?
        var result: [CGDirectDisplayID: any DisplayBrightnessBackend] = [:]

        for display in displays {
            // Keep an established fallback until the display's identity or capabilities change.
            if let backend = previous[display.id], hasSameControlIdentity(backend.display, display),
               backendCandidates(for: display).contains(BackendCandidate(kind: backend.kind)) {
                backend.display = display
                result[display.id] = backend
                continue
            }
            for candidate in backendCandidates(for: display) {
                guard let backend = makeBackend(
                    candidate,
                    for: display,
                    in: displays,
                    previous: previous,
                    cache: &arm64Services
                ) else {
                    continue
                }

                result[display.id] = backend
                break
            }
        }

        return result
    }

    func fallbackBackend(
        after failedBackend: any DisplayBrightnessBackend,
        for display: DisplayInfo,
        previous: [CGDirectDisplayID: any DisplayBrightnessBackend]
    ) -> (any DisplayBrightnessBackend)? {
        let candidates = backendCandidates(for: display)
        guard let failedIndex = candidates.firstIndex(of: BackendCandidate(kind: failedBackend.kind)) else {
            return nil
        }

        var arm64Services: [CGDirectDisplayID: Arm64DDCServiceMatcher.Binding]?
        for candidate in candidates.dropFirst(failedIndex + 1) {
            guard let backend = makeBackend(
                candidate,
                for: display,
                in: [display],
                previous: previous.filter { $0.key != display.id },
                cache: &arm64Services
            ) else {
                continue
            }

            return backend
        }

        return nil
    }

    private func hasSameControlIdentity(_ lhs: DisplayInfo, _ rhs: DisplayInfo) -> Bool {
        lhs.id == rhs.id && lhs.isBuiltin == rhs.isBuiltin
            && lhs.vendorNumber == rhs.vendorNumber && lhs.modelNumber == rhs.modelNumber
            && lhs.serialNumber == rhs.serialNumber
            && lhs.supportsAppleNativeBrightness == rhs.supportsAppleNativeBrightness
    }

    private func backendCandidates(for display: DisplayInfo) -> [BackendCandidate] {
        if display.isBuiltin {
            return [.appleNative, .gamma, .shade]
        }

        if display.supportsAppleNativeBrightness {
            return [.appleNative, .ddc, .gamma, .shade]
        }

        return [.ddc, .gamma, .shade]
    }

    private func makeBackend(
        _ candidate: BackendCandidate,
        for display: DisplayInfo,
        in displays: [DisplayInfo],
        previous: [CGDirectDisplayID: any DisplayBrightnessBackend],
        cache arm64Services: inout [CGDirectDisplayID: Arm64DDCServiceMatcher.Binding]?
    ) -> (any DisplayBrightnessBackend)? {
        switch candidate {
        case .appleNative:
            return appleBackend(for: display, previous: previous)
        case .ddc:
            return ddcBackend(
                for: display,
                in: displays,
                previous: previous,
                cache: &arm64Services
            )
        case .gamma:
            return softwareBackend(
                kind: .gamma,
                label: "Gamma",
                for: display,
                previous: previous,
                factory: gammaFactory
            )
        case .shade:
            return softwareBackend(
                kind: .shade,
                label: "Shade",
                for: display,
                previous: previous,
                factory: shadeFactory
            )
        }
    }

    private func appleBackend(
        for display: DisplayInfo,
        previous: [CGDirectDisplayID: any DisplayBrightnessBackend]
    ) -> (any DisplayBrightnessBackend)? {
        guard display.isAppleDisplay else {
            return nil
        }

        guard let backend = reuse(previous[display.id], kind: .appleNative, display: display)
            ?? appleFactory(display) else {
            return nil
        }

        DisplayBrightnessLog.backend.debug(
            "selected Apple native brightness backend for \(display.name, privacy: .public)"
        )
        return backend
    }

    private func softwareBackend(
        kind: DisplayBrightnessBackendKind,
        label: String,
        for display: DisplayInfo,
        previous: [CGDirectDisplayID: any DisplayBrightnessBackend],
        factory: SoftwareBackendFactory
    ) -> (any DisplayBrightnessBackend)? {
        guard let backend = reuse(previous[display.id], kind: kind, display: display)
            ?? factory(display) else {
            return nil
        }

        DisplayBrightnessLog.backend.info(
            "using \(label, privacy: .public) software brightness fallback for \(display.name, privacy: .public)"
        )
        return backend
    }

    private func ddcBackend(
        for display: DisplayInfo,
        in displays: [DisplayInfo],
        previous: [CGDirectDisplayID: any DisplayBrightnessBackend],
        cache arm64Services: inout [CGDirectDisplayID: Arm64DDCServiceMatcher.Binding]?
    ) -> (any DisplayBrightnessBackend)? {
        guard let backend = reuse(previous[display.id], kind: .ddc, display: display)
            ?? ddcFactory(display, resolvedArm64Service(for: display, in: displays, cache: &arm64Services)) else {
            return nil
        }

        DisplayBrightnessLog.backend.debug(
            "selected DDC brightness backend for \(display.name, privacy: .public)"
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
        _ previous: (any DisplayBrightnessBackend)?,
        kind: DisplayBrightnessBackendKind,
        display: DisplayInfo
    ) -> (any DisplayBrightnessBackend)? {
        guard let backend = previous, backend.kind == kind else {
            return nil
        }

        backend.display = display
        return backend
    }
}

final class AppleNativeBrightnessBackend: DisplayBrightnessBackend, @unchecked Sendable {
    let kind: DisplayBrightnessBackendKind = .appleNative

    private let lock = NSLock()
    private var _display: DisplayInfo
    var display: DisplayInfo {
        get { lock.withLock { _display } }
        set { lock.withLock { _display = newValue } }
    }

    private let bridge: DisplayServicesBrightnessBridge

    init(
        display: DisplayInfo,
        bridge: DisplayServicesBrightnessBridge
    ) {
        self._display = display
        self.bridge = bridge
    }

    func readBrightness() throws -> Double {
        let displayID = lock.withLock { _display.id }
        return try bridge.readBrightness(displayID: displayID)
    }

    func readVerifiedBrightness() throws -> Double {
        let displayID = lock.withLock { _display.id }
        let value = try bridge.readRawBrightness(displayID: displayID)
        guard value.isFinite, (0...1).contains(value) else { throw DisplayBrightnessExactError.readbackUnavailable }
        return value
    }

    func writeBrightness(_ value: Double) throws {
        try writeBrightness(value, permit: nil)
    }

    func writeBrightness(_ value: Double, permit: DisplayActionWritePermit?) throws {
        let displayID = lock.withLock { _display.id }
        try bridge.writeBrightness(value, displayID: displayID, permit: permit)
    }

    func writeExactBrightness(_ value: Double, permit: DisplayActionWritePermit) throws -> Double? {
        try writeBrightness(value, permit: permit)
        return nil
    }

    func cleanup() {}
}

final class DDCBrightnessBackend: DisplayBrightnessBackend, @unchecked Sendable {
    struct CachedState {
        let registryEntryID: UInt64
        let maximum: UInt16?
        let level: Double
    }

    let kind: DisplayBrightnessBackendKind = .ddc

    private let lock = NSLock()
    private var _display: DisplayInfo
    var display: DisplayInfo {
        get { lock.withLock { _display } }
        set { lock.withLock { _display = newValue } }
    }

    private let transport: any DDCBrightnessTransport
    private var maximumValue: UInt16?

    init?(display: DisplayInfo, transport: any DDCBrightnessTransport) {
        guard !display.isBuiltin else {
            return nil
        }

        self._display = display
        self.transport = transport
        // The controller reads the hardware asynchronously before enabling controls.
        self.maximumValue = nil
    }

    func cachedState(level: Double) -> CachedState? {
        guard let registryEntryID = transport.registryEntryID else { return nil }
        return lock.withLock { CachedState(registryEntryID: registryEntryID, maximum: maximumValue, level: level) }
    }

    func reuseCachedState(_ state: CachedState) -> Bool {
        // Ordinary controls retain their measured or default scale on the same endpoint.
        guard transport.registryEntryID == state.registryEntryID, transport.isDiscoveryCurrent else { return false }
        lock.withLock { maximumValue = state.maximum }
        return true
    }

    func readBrightness() throws -> Double {
        guard transport.isDiscoveryCurrent else { throw CancellationError() }
        let brightness = try transport.readBrightness()
        guard transport.isDiscoveryCurrent else { throw CancellationError() }
        return lock.withLock {
            let maximum = Self.validMaximum(brightness.maximum) ?? maximumValue ?? 100
            maximumValue = maximum
            return Double(brightness.current) / Double(maximum)
        }
    }

    func writeBrightness(_ value: Double) throws {
        try writeBrightness(value, permit: nil)
    }

    func writeBrightness(_ value: Double, permit: DisplayActionWritePermit?) throws {
        guard permit?.canWrite != false else { throw CancellationError() }
        // A write fallback can reach DDC before the controller's first read.
        // This runs on the write worker and preserves the monitor's native range.
        if lock.withLock({ maximumValue == nil }) {
            _ = try? readBrightness()
        }
        let clampedValue = max(0, min(value, 1))
        let maximum = lock.withLock { maximumValue ?? 100 }
        let rawValue = UInt16((Double(maximum) * clampedValue).rounded())
        try transport.writeBrightness(rawValue, permit: permit)
        lock.withLock { maximumValue = maximumValue ?? maximum }
    }

    var hasVerifiedDisplayBinding: Bool { transport.hasVerifiedDisplayBinding }
    var usesDiscoveredService: Bool { transport.usesDiscoveredService }

    func writeExactBrightness(_ value: Double, permit: DisplayActionWritePermit) throws -> Double? {
        guard hasVerifiedDisplayBinding else { throw DisplayBrightnessExactError.unverifiedTarget }
        guard permit.canWrite else { throw CancellationError() }
        guard let initial = readHardwareRange(verified: true) else {
            throw DisplayBrightnessExactError.rangeUnavailable
        }
        guard let step = ActionPercentage.hardwareStep(for: value, maximum: initial.maximum) else {
            guard permit.isTargetCurrent, transport.isDiscoveryCurrent else { throw CancellationError() }
            throw DisplayBrightnessExactError.unsupportedHardwareLevel(
                observed: Double(initial.current) / Double(initial.maximum)
            )
        }
        try transport.writeVerifiedBrightness(step, permit: permit)

        var lastObserved: Double?
        for delay in [0.0, 0.15, 0.30] {
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            guard permit.canWrite else { throw CancellationError() }
            guard let observed = readHardwareRange(verified: true) else { continue }
            guard permit.canWrite else { throw CancellationError() }
            let level = Double(observed.current) / Double(observed.maximum)
            if ActionPercentage.matchesHardwareLevel(raw: observed.current, maximum: observed.maximum, requested: value) {
                return level
            }
            lastObserved = level
        }
        guard permit.canWrite else { throw CancellationError() }
        guard let lastObserved else { throw DisplayBrightnessExactError.readbackUnavailable }
        throw DisplayBrightnessExactError.mismatch(requested: value, observed: lastObserved)
    }

    func readFreshBrightness() throws -> Double {
        guard let reading = readHardwareRange(verified: false) else { throw DisplayBrightnessExactError.readbackUnavailable }
        return Double(reading.current) / Double(reading.maximum)
    }

    func readVerifiedBrightness() throws -> Double {
        guard hasVerifiedDisplayBinding else { throw DisplayBrightnessExactError.unverifiedTarget }
        guard let reading = readHardwareRange(verified: true) else { throw DisplayBrightnessExactError.readbackUnavailable }
        return Double(reading.current) / Double(reading.maximum)
    }

    private func readHardwareRange(verified: Bool) -> DDCBrightnessValue? {
        guard transport.isDiscoveryCurrent else { return nil }
        let result = verified ? try? transport.readVerifiedBrightness() : try? transport.readBrightness()
        guard let reading = result,
              reading.maximum > 0, reading.current <= reading.maximum,
              transport.isDiscoveryCurrent else { return nil }
        lock.withLock { maximumValue = reading.maximum }
        return reading
    }

    func cleanup() {}

    private static func validMaximum(_ maximum: UInt16) -> UInt16? {
        maximum == 0 ? nil : maximum
    }
}

final class GammaBrightnessBackend: DisplayBrightnessBackend, @unchecked Sendable {
    private struct TransferTable {
        let red: [CGGammaValue]
        let green: [CGGammaValue]
        let blue: [CGGammaValue]
    }

    let kind: DisplayBrightnessBackendKind = .gamma

    private let lock = NSLock()
    private var _display: DisplayInfo
    var display: DisplayInfo {
        get { lock.withLock { _display } }
        set { lock.withLock { _display = newValue } }
    }

    private let actionIdentifier: String?
    private var originalTransferTable: TransferTable?
    private var currentBrightness = 1.0

    init?(display: DisplayInfo) {
        guard Self.canControl(displayID: display.id) else {
            return nil
        }

        self._display = display
        self.actionIdentifier = DisplayActionTarget.identifier(for: display.id)
    }

    func readBrightness() throws -> Double {
        lock.withLock { currentBrightness }
    }

    func writeBrightness(_ value: Double) throws {
        try writeBrightness(value, permit: nil)
    }

    func writeExactBrightness(_ value: Double, permit: DisplayActionWritePermit) throws -> Double? {
        try writeBrightness(value, permit: permit)
        return value
    }

    func writeBrightness(_ value: Double, permit: DisplayActionWritePermit?) throws {
        guard permit?.canWrite != false else { throw CancellationError() }
        let clampedValue = max(0, min(value, 1))
        let (displayID, transferTable) = try loadOriginalTransferTableIfNeeded()
        let red = transferTable.red.map { $0 * Float(clampedValue) }
        let green = transferTable.green.map { $0 * Float(clampedValue) }
        let blue = transferTable.blue.map { $0 * Float(clampedValue) }

        guard permit?.beginWrite() != false else { throw CancellationError() }
        let result = CGSetDisplayTransferByTable(
            displayID,
            UInt32(red.count),
            red,
            green,
            blue
        )

        guard result == .success else {
            throw DisplayBrightnessControllerError.softwareBrightnessFailed
        }

        lock.withLock { currentBrightness = clampedValue }
    }

    func cleanup() {
        let snapshot: (id: CGDirectDisplayID, table: TransferTable)? = lock.withLock {
            guard let originalTransferTable else { return nil }
            return (_display.id, originalTransferTable)
        }

        guard let snapshot else { return }

        if let actionIdentifier,
           DisplayActionTarget.onlineIdentifier(for: snapshot.id) != actionIdentifier { return }

        _ = CGSetDisplayTransferByTable(
            snapshot.id,
            UInt32(snapshot.table.red.count),
            snapshot.table.red,
            snapshot.table.green,
            snapshot.table.blue
        )
        lock.withLock { currentBrightness = 1 }
    }

    private func loadOriginalTransferTableIfNeeded() throws -> (CGDirectDisplayID, TransferTable) {
        // The first-time capture must be atomic w.r.t. concurrent writeBrightness()
        // calls: if the read of the live LUT happened outside the lock, a racing
        // writer could have already dimmed the display, and we'd cache that dimmed
        // LUT as the "original" — cleanup() would then restore the wrong curve and
        // never return the display to full brightness. Capture under the lock; it is
        // a one-time cost (subsequent calls hit the cache and return immediately).
        return try lock.withLock {
            let displayID = _display.id
            let displayName = _display.name

            if let cachedTable = originalTransferTable {
                return (displayID, cachedTable)
            }

            let transferTable = try Self.readTransferTable(displayID: displayID, displayName: displayName)
            originalTransferTable = transferTable
            return (displayID, transferTable)
        }
    }

    private static func readTransferTable(
        displayID: CGDirectDisplayID,
        displayName: String
    ) throws -> TransferTable {
        var sampleCount: UInt32 = 0
        let countResult = CGGetDisplayTransferByTable(displayID, 0, nil, nil, nil, &sampleCount)

        guard countResult == .success, sampleCount > 0 else {
            throw DisplayBrightnessControllerError.brightnessUnavailable(displayName: displayName)
        }

        let red = UnsafeMutablePointer<CGGammaValue>.allocate(capacity: Int(sampleCount))
        let green = UnsafeMutablePointer<CGGammaValue>.allocate(capacity: Int(sampleCount))
        let blue = UnsafeMutablePointer<CGGammaValue>.allocate(capacity: Int(sampleCount))
        defer {
            red.deallocate()
            green.deallocate()
            blue.deallocate()
        }

        let readResult = CGGetDisplayTransferByTable(
            displayID,
            sampleCount,
            red,
            green,
            blue,
            &sampleCount
        )

        guard readResult == .success else {
            throw DisplayBrightnessControllerError.brightnessUnavailable(displayName: displayName)
        }

        return TransferTable(
            red: Array(UnsafeBufferPointer(start: red, count: Int(sampleCount))),
            green: Array(UnsafeBufferPointer(start: green, count: Int(sampleCount))),
            blue: Array(UnsafeBufferPointer(start: blue, count: Int(sampleCount)))
        )
    }

    private static func canControl(displayID: CGDirectDisplayID) -> Bool {
        var sampleCount: UInt32 = 0
        return CGGetDisplayTransferByTable(displayID, 0, nil, nil, nil, &sampleCount) == .success
            && sampleCount > 0
    }
}

final class ShadeBrightnessBackend: DisplayBrightnessBackend, @unchecked Sendable {
    let kind: DisplayBrightnessBackendKind = .shade

    private let lock = NSLock()
    private var _display: DisplayInfo
    var display: DisplayInfo {
        get { lock.withLock { _display } }
        set { lock.withLock { _display = newValue } }
    }

    private let overlayController = ShadeOverlayController()
    private let actionIdentifier: String?
    private var currentBrightness = 1.0

    init?(display: DisplayInfo) {
        guard Self.screen(for: display.id) != nil else {
            return nil
        }

        self._display = display
        self.actionIdentifier = DisplayActionTarget.identifier(for: display.id)
    }

    func readBrightness() throws -> Double {
        refreshOverlayFrameIfNeeded()
        return lock.withLock { currentBrightness }
    }

    func writeBrightness(_ value: Double) throws {
        let clampedValue = max(0, min(value, 1))
        let displayID = lock.withLock { _display.id }
        guard Self.screen(for: displayID) != nil else {
            throw DisplayBrightnessControllerError.displayUnavailable(displayID: displayID)
        }

        applyOverlay(brightness: clampedValue)
        lock.withLock { currentBrightness = clampedValue }
    }

    func writeExactBrightness(_ value: Double, permit: DisplayActionWritePermit) throws -> Double? {
        guard value >= DisplayBrightnessBackendKind.shadeMinimumBrightness else {
            throw DisplayBrightnessExactError.shadeRange
        }
        try writeBrightness(value, permit: permit)
        return value
    }

    func writeBrightness(_ value: Double, permit: DisplayActionWritePermit?) throws {
        guard let permit else { return try writeBrightness(value) }
        let clampedValue = max(0, min(value, 1))
        let displayID = display.id
        let apply: @MainActor @Sendable () throws -> Void = { [self] in
            guard let screen = Self.screen(for: displayID) else {
                throw DisplayBrightnessControllerError.displayUnavailable(displayID: displayID)
            }
            guard permit.beginWrite() else { throw CancellationError() }
            overlayController.apply(brightness: clampedValue, on: screen)
            lock.withLock { currentBrightness = clampedValue }
        }
        if Thread.isMainThread {
            try MainActor.assumeIsolated(apply)
        } else {
            try DispatchQueue.main.sync(execute: apply)
        }
    }

    func cleanup() {
        hideOverlay()
        lock.withLock { currentBrightness = 1 }
    }

    private func refreshOverlayFrameIfNeeded() {
        let (displayID, brightness): (CGDirectDisplayID, Double) = lock.withLock {
            (_display.id, currentBrightness)
        }
        guard brightness < 0.999, Self.screen(for: displayID) != nil else {
            return
        }

        applyOverlay(brightness: brightness)
    }

    private func applyOverlay(brightness: Double) {
        let displayID = display.id
        let overlayController = self.overlayController

        DispatchQueue.main.async { [actionIdentifier] in
            if let actionIdentifier,
               DisplayActionTarget.identifier(for: displayID) != actionIdentifier { return }
            guard let screen = Self.screen(for: displayID) else {
                return
            }

            overlayController.apply(brightness: brightness, on: screen)
        }
    }

    private func hideOverlay() {
        let overlayController = self.overlayController

        DispatchQueue.main.async {
            overlayController.hide()
        }
    }

    private static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        })
    }
}

@MainActor
private final class ShadeOverlayController {
    private var window: NSWindow?

    func apply(brightness: Double, on screen: NSScreen) {
        let alpha = max(0, min(1 - brightness, 1 - DisplayBrightnessBackendKind.shadeMinimumBrightness))

        guard alpha > 0.001 else {
            hide()
            return
        }

        let window = self.window ?? self.makeWindow(screen: screen)
        window.setFrame(screen.frame, display: true)
        window.alphaValue = alpha
        PluginPresentationSafety.prepareForWindowOrdering(window)
        window.orderFrontRegardless()
        self.window = window
    }

    func hide() {
        guard let window else {
            return
        }

        window.orderOut(nil)
        self.window = nil
    }

    private func makeWindow(screen: NSScreen) -> NSWindow {
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = .screenSaver
        window.backgroundColor = .black
        window.isOpaque = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.hasShadow = false
        return window
    }
}

final class DisplayServicesBrightnessBridge: @unchecked Sendable {
    typealias GetBrightnessFunction = @convention(c) (
        CGDirectDisplayID,
        UnsafeMutablePointer<Float>
    ) -> Int32
    typealias SetBrightnessFunction = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private let getBrightness: GetBrightnessFunction?
    private let setBrightness: SetBrightnessFunction?

    convenience init() {
        let handle = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            RTLD_LAZY
        )
        self.init(
            getBrightness: Self.loadSymbol("DisplayServicesGetBrightness", from: handle),
            setBrightness: Self.loadSymbol("DisplayServicesSetBrightness", from: handle)
        )
    }

    init(getBrightness: GetBrightnessFunction?, setBrightness: SetBrightnessFunction?) {
        self.getBrightness = getBrightness
        self.setBrightness = setBrightness
    }

    func readBrightness(displayID: CGDirectDisplayID) throws -> Double {
        let value = try readRawBrightness(displayID: displayID)
        return max(0, min(value, 1))
    }

    func readRawBrightness(displayID: CGDirectDisplayID) throws -> Double {
        guard let getBrightness else {
            throw DisplayBrightnessControllerError.nativeAPINotAvailable
        }

        var value: Float = 0
        guard getBrightness(displayID, &value) == 0 else {
            throw DisplayBrightnessControllerError.genericBrightnessUnavailable
        }

        return Double(value)
    }

    func writeBrightness(
        _ value: Double,
        displayID: CGDirectDisplayID,
        permit: DisplayActionWritePermit? = nil
    ) throws {
        guard let setBrightness else {
            throw DisplayBrightnessControllerError.nativeAPINotAvailable
        }

        guard permit?.beginWrite() != false else { throw CancellationError() }
        guard setBrightness(displayID, Float(max(0, min(value, 1)))) == 0 else {
            throw DisplayBrightnessControllerError.nativeBrightnessWriteFailed
        }
    }

    private static func loadSymbol<T>(
        _ symbol: String,
        from handle: UnsafeMutableRawPointer?
    ) -> T? {
        guard let symbolPointer = dlsym(handle, symbol) else {
            return nil
        }

        return unsafeBitCast(symbolPointer, to: T.self)
    }
}
