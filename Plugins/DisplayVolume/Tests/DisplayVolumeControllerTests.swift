import AppKit
import XCTest
import MacToolsPluginKit
import os
@testable import DisplayVolumePlugin

private final class VolumeTestTransport: DDCVolumeTransport, @unchecked Sendable {
    struct State {
        var value: DDCVolumeValue?
        var failWrites = false
        var ignoreWrites = false
        var failReadsAfterWrite = false
        var writes: [UInt16] = []
        var readDelay: TimeInterval = 0
        var mainThreadReads = 0
        var readCount = 0
        var readGate: DispatchSemaphore?
        var writeGate: DispatchSemaphore?
        var beforeWriteGate: DispatchSemaphore?
        var writeStarted = false
        var didWrite: (@Sendable (UInt16) -> Void)?
    }
    let hasVerifiedDisplayBinding: Bool
    let usesDiscoveredService: Bool
    let registryEntryID: UInt64?
    private let bindingGeneration: UInt64?

    init(verified: Bool = true, usesDiscoveredService: Bool = false, registryEntryID: UInt64? = nil,
         bindingGeneration: UInt64? = nil) {
        hasVerifiedDisplayBinding = verified
        self.usesDiscoveredService = usesDiscoveredService
        self.registryEntryID = registryEntryID
        self.bindingGeneration = bindingGeneration
    }

    var isDiscoveryCurrent: Bool { bindingGeneration.map { $0 == DisplayDDCIdentity.bindingGeneration } ?? true }

    private let lock = NSLock()
    private var state = State()
    func update(_ body: (inout State) -> Void) { lock.lock(); defer { lock.unlock() }; body(&state) }
    func read<T>(_ body: (State) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(state) }
    func readVolume() throws -> DDCVolumeValue {
        update {
            if Thread.isMainThread { $0.mainThreadReads += 1 }
            $0.readCount += 1
        }
        let request = read { $0 }
        if request.readDelay > 0 { Thread.sleep(forTimeInterval: request.readDelay) }
        if let gate = request.readGate { _ = gate.wait(timeout: .now() + 3) }
        guard let value = request.value, !request.failReadsAfterWrite || request.writes.isEmpty else {
            throw DisplayVolumeControllerError.failed(message: "GET unavailable")
        }
        return value
    }
    func writeVolume(_ value: UInt16) throws {
        update { $0.writeStarted = true }
        if let gate = read({ $0.beforeWriteGate }) { _ = gate.wait(timeout: .now() + 3) }
        if read({ $0.failWrites }) { throw DisplayVolumeControllerError.failed(message: "SET failed") }
        update {
            $0.writes.append(value)
            if !$0.ignoreWrites, let current = $0.value { $0.value = .init(current: value, maximum: current.maximum) }
        }
        read { $0.didWrite }?(value)
        if let gate = read({ $0.writeGate }) { _ = gate.wait(timeout: .now() + 3) }
    }
}

private final class VolumeTestDisplays: DisplayProviding {
    var displays: [DisplayInfo]
    init(displays: [DisplayInfo]) { self.displays = displays }
    func listConnectedDisplays() -> [DisplayInfo] { displays }
    func screen(for displayID: CGDirectDisplayID) -> NSScreen? { nil }
}

private struct VolumeTestBuilder: DisplayVolumeBackendBuilding {
    let backend: any DisplayVolumeBackend
    func backends(for displays: [DisplayInfo], previous: [CGDirectDisplayID: any DisplayVolumeBackend]) -> [CGDirectDisplayID: any DisplayVolumeBackend] {
        Dictionary(uniqueKeysWithValues: displays.map { ($0.id, backend) })
    }
}

private final class VolumeTestCache {
    let id = CGDirectDisplayID.random(in: 0xF0000000...0xFFFFFFFE)
    var identifier: String { "fixture-\(id)" }
    var key: String { "ddc-volume-target-\(identifier)" }
    private var original: Any?
    init(value: Double) {
        original = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(value, forKey: key)
    }
    func restore() {
        if let original { UserDefaults.standard.set(original, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }
}

@MainActor
final class DisplayVolumeControllerTests: XCTestCase {
    private func display(_ cache: VolumeTestCache) -> DisplayInfo {
        DisplayInfo(id: cache.id, name: "Review display", isBuiltin: false, isMain: true,
                    vendorNumber: 1, modelNumber: 2, serialNumber: 3)
    }
    private func controller(_ display: DisplayInfo, backend: any DisplayVolumeBackend) -> DisplayVolumeController {
        DisplayVolumeController(displayProvider: VolumeTestDisplays(displays: [display]),
                                backendBuilder: VolumeTestBuilder(backend: backend),
                                shortWriteDelay: 0, minimumWriteInterval: 0)
    }
    private func decrease(_ plugin: DisplayVolumePlugin) async throws {
        let invocation = ActionInvocation(reference: ActionReference(key:
            ActionKey(providerID: "display-volume", actionID: "display-volume.decrease")), source: .test, mode: .background)
        let handle = try plugin.beginAction(invocation)
        let result = await handle.result()
        XCTAssertEqual(result, .succeeded())
    }
    func testArm64VolumeTransportChecksPermitBeforeEverySend() throws {
        let display = makeVolumeTestDisplay(id: 26, name: "External fixture")
        let permit = DisplayActionWritePermit { true }
        var sends = 0
        let transport = try XCTUnwrap(Arm64DDCTransport(
            display: display, service: "fixture" as NSString,
            sendPacket: { _, _ in
                sends += 1
                permit.cancel()
                return 0
            }
        ))
        XCTAssertThrowsError(try transport.writeVolume(50, permit: permit)) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(sends, 1, "Cancellation after the first send must prevent the retry")
        let topologyChangesDuringCheck = DisplayActionWritePermit {
            DisplayDDCIdentity.invalidateBindings()
            return true
        }
        XCTAssertThrowsError(try transport.writeVolume(50, permit: topologyChangesDuringCheck)) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(sends, 1, "Binding invalidation during the final identity check must block the SET")
    }

    func testDiscoveredVolumeBindingRequiresUniqueCorroboratedIdentity() throws {
        let display = DisplayInfo(id: 26, name: "Fixture", isBuiltin: false, isMain: true,
                                  vendorNumber: 1, modelNumber: 2, serialNumber: 3)
        let identity = try XCTUnwrap(DisplayDDCIdentity(vendor: 1, product: 2, serial: 3))
        let candidate = Arm64DDCServiceMatcher.CandidateService(
            service: "fixture" as NSString, vendorNumber: 1, serialNumber: 3, productID: 2
        )
        let verified = Arm64DDCServiceMatcher.resolveServices(
            for: [display], candidates: [candidate], onlineIdentities: [display.id: identity]
        )
        XCTAssertEqual(verified[display.id]?.verified, true)
        let ambiguousDisplay = Arm64DDCServiceMatcher.resolveServices(
            for: [display], candidates: [candidate], onlineIdentities: [display.id: identity, 27: identity]
        )
        XCTAssertEqual(ambiguousDisplay[display.id]?.verified, false)
        let ambiguousService = Arm64DDCServiceMatcher.resolveServices(
            for: [display], candidates: [candidate, candidate], onlineIdentities: [display.id: identity]
        )
        XCTAssertEqual(ambiguousService[display.id]?.verified, false)
        let stale = DisplayInfo(id: 27, name: "Fixture", isBuiltin: false, isMain: false,
                                vendorNumber: 1, modelNumber: 2, serialNumber: 3)
        let inconsistent = Arm64DDCServiceMatcher.resolveServices(
            for: [display, stale], candidates: [candidate], onlineIdentities: [display.id: identity]
        )
        XCTAssertTrue(inconsistent.values.allSatisfy { !$0.verified })
    }

    func testExactVolumeRejectsAnUnverifiedMonitorBinding() throws {
        let cache = VolumeTestCache(value: 0.4)
        defer { cache.restore() }
        let display = display(cache)
        let transport = try XCTUnwrap(Arm64DDCTransport(display: display, service: "fixture" as NSString, sendPacket: { _, _ in XCTFail("Unverified binding must not issue I/O"); return -1 }))
        let backend = try XCTUnwrap(DDCVolumeBackend(display: display, transport: transport, identifier: cache.identifier))
        XCTAssertThrowsError(try backend.writeExactVolume(0.5, permit: DisplayActionWritePermit { true })) { error in
            guard case DisplayVolumeControllerError.unverifiedDisplayBinding = error else {
                return XCTFail("Expected an unverified binding error, got \(error)")
            }
        }
    }

    func testValidReadFromUnverifiedVolumeBindingCannotVerifyLevel() throws {
        let cache = VolumeTestCache(value: 0.4)
        defer { cache.restore() }
        let transport = VolumeTestTransport(verified: false)
        transport.update { $0.value = .init(current: 60, maximum: 100) }
        let backend = try XCTUnwrap(DDCVolumeBackend(display: display(cache), transport: transport, identifier: cache.identifier))

        XCTAssertEqual(try backend.readVolume(), 0.6)
        XCTAssertThrowsError(try backend.readVerifiedVolume()) { error in
            guard case DisplayVolumeControllerError.unverifiedDisplayBinding = error else {
                return XCTFail("Expected an unverified binding error, got \(error)")
            }
        }
    }

    func testExactVolumeLearnsHardwareScaleBeforeItsFirstWriteAndChecksReadback() async throws {
        let cache = VolumeTestCache(value: 0.4)
        defer { cache.restore() }
        let transport = VolumeTestTransport()
        transport.update { $0.value = .init(current: 60, maximum: 200) }
        let backend = try XCTUnwrap(DDCVolumeBackend(display: display(cache), transport: transport, identifier: cache.identifier))
        let permit = DisplayActionWritePermit { true }

        let applied = try await Task.detached { try backend.writeExactVolume(0.5, permit: permit) }.value
        XCTAssertEqual(applied, 0.5)
        XCTAssertEqual(transport.read { $0.writes }, [100])

        transport.update { $0.ignoreWrites = true }
        do {
            _ = try await Task.detached { try backend.writeExactVolume(0.8, permit: permit) }.value
            XCTFail("An acknowledged SET with mismatched readback must fail")
        } catch DisplayVolumeControllerError.ddcWriteFailed {
            XCTAssertEqual(transport.read { $0.writes }, [100, 160])
        }

        permit.cancel()
        XCTAssertThrowsError(try backend.writeExactVolume(0.2, permit: permit))
        XCTAssertEqual(transport.read { $0.writes }, [100, 160])
    }

    func testExactDDCVolumeRejectsUnrepresentableLevelBeforeWrite() throws {
        let cache = VolumeTestCache(value: 0.5)
        defer { cache.restore() }
        let transport = VolumeTestTransport()
        transport.update { $0.value = .init(current: 2, maximum: 4) }
        let backend = try XCTUnwrap(DDCVolumeBackend(display: display(cache), transport: transport, identifier: cache.identifier))
        let permit = DisplayActionWritePermit { true }

        XCTAssertThrowsError(try backend.writeExactVolume(0.89, permit: permit))
        XCTAssertFalse(permit.didAttemptWrite)
        XCTAssertTrue(transport.read { $0.writes }.isEmpty)
        XCTAssertEqual(try backend.writeExactVolume(0.75, permit: permit), 0.75)
        XCTAssertEqual(transport.read { $0.writes }, [3])
    }

    func testRejectedExactVolumeReconcilesLevelAndScaleAfterCancellingInitialRead() async throws {
        let cache = VolumeTestCache(value: 0.15)
        defer { cache.restore() }
        let display = display(cache)
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let transport = VolumeTestTransport()
        transport.update { $0.value = .init(current: 0, maximum: 15); $0.readGate = gate }
        let backend = try XCTUnwrap(DDCVolumeBackend(display: display, transport: transport, identifier: cache.identifier))
        let controller = DisplayVolumeController(
            displayProvider: VolumeTestDisplays(displays: [display]),
            displayIdentifier: { _ in "fixture" },
            backendBuilder: VolumeTestBuilder(backend: backend),
            shortWriteDelay: 0,
            minimumWriteInterval: 0
        )
        controller.refresh()
        try await waitUntil { transport.read { $0.readCount == 1 } }
        let exact = Task { await controller.setExactVolumeAndWait(0.37, for: display.id, identifier: "fixture") }
        try await waitUntil { controller.pendingReadCount == 0 }
        transport.update { $0.readGate = nil }
        gate.signal()

        guard case .failed = await exact.value else { return XCTFail("Expected exact 37% to be unsupported") }
        XCTAssertTrue(transport.read { $0.writes }.isEmpty)
        XCTAssertEqual(controller.snapshot().displays.first?.volume, 0)
        let decrease = await controller.adjustVolumeAndWait(by: -0.01, for: display.id)
        XCTAssertEqual(decrease, .succeeded)
        let increase = await controller.adjustVolumeAndWait(by: 0.07, for: display.id)
        XCTAssertEqual(increase, .succeeded)
        XCTAssertEqual(transport.read { $0.writes }, [0, 1])
    }

    func testExactVolumeDoesNotWriteWithInvalidRange() throws {
        let cache = VolumeTestCache(value: 0.4)
        defer { cache.restore() }
        let transport = VolumeTestTransport()
        transport.update { $0.value = .init(current: 200, maximum: 20) }
        let backend = try XCTUnwrap(DDCVolumeBackend(display: display(cache), transport: transport, identifier: cache.identifier))

        XCTAssertThrowsError(try backend.writeExactVolume(0.5, permit: DisplayActionWritePermit { true }))
        XCTAssertEqual(transport.read { $0.writes }, [])
    }

    func testUnverifiedExactVolumeBlocksRelativeWritesButAllowsAbsoluteSet() async throws {
        let cache = VolumeTestCache(value: 0.95)
        defer { cache.restore() }
        let display = display(cache)
        let gate = DispatchSemaphore(value: 0)
        let transport = VolumeTestTransport()
        transport.update {
            $0.value = .init(current: 95, maximum: 100)
            $0.writeGate = gate
            $0.failReadsAfterWrite = true
        }
        let backend = try XCTUnwrap(DDCVolumeBackend(display: display, transport: transport, identifier: cache.identifier))
        let controller = DisplayVolumeController(
            displayProvider: VolumeTestDisplays(displays: [display]),
            displayIdentifier: { _ in "fixture" },
            backendBuilder: VolumeTestBuilder(backend: backend),
            shortWriteDelay: 0,
            minimumWriteInterval: 0
        )
        controller.refresh()
        try await waitUntil { controller.pendingReadCount == 0 }
        let exact = Task { await controller.setExactVolumeAndWait(0, for: display.id, identifier: "fixture") }
        try await waitUntil { transport.read { $0.writes == [0] } }
        XCTAssertNil(UserDefaults.standard.object(forKey: cache.key))
        let relative = await controller.adjustVolumeAndWait(by: -0.01, for: display.id)
        transport.update { $0.writeGate = nil }
        gate.signal()

        guard case .failed = await exact.value, case .failed = relative else {
            return XCTFail("A relative write cannot use the optimistic exact target")
        }
        XCTAssertEqual(controller.snapshot().displays.first?.isReady, false)
        guard case .failed = await controller.adjustVolumeAndWait(by: -0.01, for: display.id) else {
            return XCTFail("An unknown level must block a new relative write")
        }
        let restarted = try XCTUnwrap(DDCVolumeBackend(display: display, transport: transport, identifier: cache.identifier))
        let restartedController = self.controller(display, backend: restarted)
        defer { restartedController.cancelOutstandingWrites() }
        restartedController.refresh()
        try await waitUntil { restartedController.pendingReadCount == 0 }
        guard case .failed = await restartedController.adjustVolumeAndWait(by: -0.01, for: display.id) else {
            return XCTFail("Decrease after restart must not use the level cached before the unverified mute")
        }
        XCTAssertEqual(transport.read { $0.writes }, [0])
        let slider = await controller.setVolumeAndWait(0.4, for: display.id)
        XCTAssertEqual(slider, .succeeded)
        XCTAssertEqual(transport.read { $0.writes }, [0, 40])
    }

    func testSliderLearnsScaleWhenItCancelsInitialRead() async throws {
        let cache = VolumeTestCache(value: 0.5)
        defer { cache.restore() }
        let display = display(cache)
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let transport = VolumeTestTransport()
        transport.update {
            $0.value = .init(current: 10, maximum: 20)
            $0.readGate = gate
        }
        let backend = try XCTUnwrap(DDCVolumeBackend(display: display, transport: transport, identifier: cache.identifier))
        let controller = controller(display, backend: backend)
        defer { controller.cancelOutstandingWrites() }
        controller.refresh()
        try await waitUntil { transport.read { $0.readCount == 1 } }
        let slider = Task { await controller.setVolumeAndWait(0.1, for: display.id) }
        try await waitUntil { controller.pendingReadCount == 0 }
        transport.update { $0.readGate = nil }
        gate.signal()

        let result = await slider.value
        XCTAssertEqual(result, .succeeded)
        XCTAssertEqual(transport.read { $0.writes }, [2])
    }

    func testOrdinaryVolumeReadCannotCommitAfterBindingInvalidationBeforeRefresh() async throws {
        let cache = VolumeTestCache(value: 0.15)
        defer { cache.restore() }
        let display = display(cache)
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let transport = VolumeTestTransport(bindingGeneration: DisplayDDCIdentity.bindingGeneration)
        transport.update { $0.value = .init(current: 90, maximum: 100); $0.readGate = gate }
        let backend = try XCTUnwrap(DDCVolumeBackend(display: display, transport: transport, identifier: cache.identifier))
        let controller = controller(display, backend: backend)
        controller.refresh()
        try await waitUntil { transport.read { $0.readCount == 1 } }

        DisplayDDCIdentity.invalidateBindings()
        gate.signal()
        try await waitUntil { controller.pendingReadCount == 0 }
        XCTAssertEqual(controller.snapshot().displays.first?.volume, 0.15)
        XCTAssertEqual(backend.cachedVolume, 0.15)
        XCTAssertEqual(UserDefaults.standard.double(forKey: cache.key), 0.15)
    }

    func testQueuedVolumeSliderDropsInvalidatedBindingBeforeFirstSET() async throws {
        let cache = VolumeTestCache(value: 0.5)
        defer { cache.restore() }
        let display = display(cache)
        let transport = VolumeTestTransport()
        transport.update { $0.value = .init(current: 50, maximum: 100) }
        let backend = try XCTUnwrap(DDCVolumeBackend(display: display, transport: transport, identifier: cache.identifier))
        let controller = controller(display, backend: backend)
        controller.refresh()
        try await waitUntil { controller.pendingReadCount == 0 }

        controller.setVolume(0.4, for: display.id, phase: .changed)
        XCTAssertEqual(controller.snapshot().displays.first?.isPendingWrite, true)
        DisplayDDCIdentity.invalidateBindings()
        try await waitUntil { controller.snapshot().displays.first?.isPendingWrite == false }
        XCTAssertTrue(transport.read { $0.writes }.isEmpty)
        XCTAssertEqual(controller.snapshot().displays.first?.volume, 0.5)
    }

    func testInterruptedRelativeVolumeRequiresAFreshLevelAfterFirstSET() async throws {
        let cache = VolumeTestCache(value: 0.95)
        defer { cache.restore() }
        let display = display(cache)
        let transport = VolumeTestTransport()
        transport.update {
            $0.value = .init(current: 95, maximum: 100)
            $0.failReadsAfterWrite = true
            $0.didWrite = { _ in DisplayDDCIdentity.invalidateBindings() }
        }
        let backend = try XCTUnwrap(DDCVolumeBackend(display: display, transport: transport, identifier: cache.identifier))
        let controller = controller(display, backend: backend)
        controller.refresh()
        try await waitUntil { controller.pendingReadCount == 0 }
        let interrupted = await controller.adjustVolumeAndWait(by: -1, for: display.id)
        guard case .failed = interrupted else { return XCTFail("Expected topology to interrupt the write") }
        try await waitUntil { controller.pendingReadCount == 0 }
        XCTAssertEqual(controller.snapshot().displays.first?.isReady, false)
        let stale = await controller.adjustVolumeAndWait(by: -0.01, for: display.id)
        guard case .failed = stale else { return XCTFail("Relative adjustment requires a fresh level") }
        let restarted = try XCTUnwrap(DDCVolumeBackend(display: display, transport: transport, identifier: cache.identifier))
        let restartedController = self.controller(display, backend: restarted)
        defer { restartedController.cancelOutstandingWrites() }
        restartedController.refresh()
        try await waitUntil { restartedController.pendingReadCount == 0 }
        guard case .failed = await restartedController.adjustVolumeAndWait(by: -0.01, for: display.id) else {
            return XCTFail("Decrease after restart must not use the level cached before the interrupted mute")
        }
        XCTAssertEqual(transport.read { $0.writes }, [0])
    }

    func testExactVolumeMismatchUsesObservedBaselineForNextRelativeWrite() async throws {
        let cache = VolumeTestCache(value: 0.8)
        defer { cache.restore() }
        let display = display(cache)
        let gate = DispatchSemaphore(value: 0)
        let transport = VolumeTestTransport()
        transport.update {
            $0.value = .init(current: 80, maximum: 100)
            $0.writeGate = gate
            $0.ignoreWrites = true
        }
        let backend = try XCTUnwrap(DDCVolumeBackend(display: display, transport: transport, identifier: cache.identifier))
        let controller = DisplayVolumeController(
            displayProvider: VolumeTestDisplays(displays: [display]),
            displayIdentifier: { _ in "fixture" },
            backendBuilder: VolumeTestBuilder(backend: backend),
            shortWriteDelay: 0,
            minimumWriteInterval: 0
        )
        controller.refresh()
        try await waitUntil { controller.pendingReadCount == 0 }
        let exact = Task { await controller.setExactVolumeAndWait(0.2, for: display.id, identifier: "fixture") }
        try await waitUntil { transport.read { $0.writes == [20] } }
        let relative = await controller.adjustVolumeAndWait(by: 0.01, for: display.id)
        transport.update { $0.writeGate = nil }
        gate.signal()

        guard case .failed = await exact.value, case .failed = relative else {
            return XCTFail("A relative write cannot use an unverified exact target as its baseline")
        }
        XCTAssertEqual(controller.snapshot().displays.first?.volume, 0.8)
        XCTAssertEqual(transport.read { $0.writes }, [20])
        transport.update { $0.ignoreWrites = false }
        let adjustment = await controller.adjustVolumeAndWait(by: 0.01, for: display.id)
        XCTAssertEqual(adjustment, .succeeded)
        XCTAssertEqual(transport.read { $0.writes }, [20, 81])
    }

    func testChangedDirectVolumeEndpointRequiresFreshLevelWithSameDisplayIdentity() async throws {
        let cache = VolumeTestCache(value: 0.95)
        defer { cache.restore() }
        let display = display(cache)
        let original = VolumeTestTransport(registryEntryID: 42)
        original.update { $0.value = .init(current: 95, maximum: 100) }
        let replacement = VolumeTestTransport(registryEntryID: 43)
        var rediscovered = false
        let controller = DisplayVolumeController(
            displayProvider: VolumeTestDisplays(displays: [display]),
            displayIdentifier: { _ in "fixture" },
            backendBuilder: SystemDisplayVolumeBackendBuilder(
                resolveArm64Services: { _ in [:] },
                ddcFactory: { display, _ in
                    DDCVolumeBackend(display: display, transport: rediscovered ? replacement : original, identifier: cache.identifier)
                }
            ),
            shortWriteDelay: 0,
            minimumWriteInterval: 0
        )
        controller.refresh()
        try await waitUntil { controller.pendingReadCount == 0 }
        XCTAssertTrue(controller.snapshot().displays.first?.canAdjustRelative == true)

        rediscovered = true
        controller.refreshDisplayTopology()
        try await waitUntil { controller.pendingReadCount == 0 }
        let blocked = await controller.adjustVolumeAndWait(by: -0.01, for: display.id)
        guard case .failed = blocked else { return XCTFail("A replacement must not use the old cache as a baseline") }
        XCTAssertTrue(replacement.read { $0.writes }.isEmpty)

        let manual = await controller.setVolumeAndWait(0.4, for: display.id)
        XCTAssertEqual(manual, .succeeded)
        XCTAssertTrue(controller.snapshot().displays.first?.canAdjustRelative == true)
        XCTAssertEqual(replacement.read { $0.writes }, [40])

        replacement.update { $0.value = .init(current: 40, maximum: 200) }
        controller.refresh()
        try await waitUntil { controller.snapshot().displays.first?.volume == 0.2 }
        let relative = await controller.adjustVolumeAndWait(by: -0.01, for: display.id)
        XCTAssertEqual(relative, .succeeded)
        let exact = await controller.setExactVolumeAndWait(0.3, for: display.id, identifier: "fixture")
        XCTAssertEqual(exact, .succeeded)
        XCTAssertTrue(original.read { $0.writes }.isEmpty)
        XCTAssertEqual(replacement.read { $0.writes }, [40, 38, 60])
    }

    func testVolumeRediscoveryPreservesScaleForSameEndpointWithoutFreshRead() async throws {
        let samples: [(DDCVolumeValue?, UInt16?, UInt16)] = [
            (.init(current: 80, maximum: 200), 80, 78),
            (nil, 40, 39),
        ]
        for (initialReading, setValue, relativeValue) in samples {
            try await assertVolumeRediscoveryPreservesScale(initialReading, setValue: setValue, relativeValue: relativeValue)
        }
    }

    func testWriteOnlyVolumeEndpointPreservesLevelAcrossTemporaryDisconnect() async throws {
        try await assertVolumeRediscoveryPreservesScale(nil, setValue: 40, relativeValue: 39, disconnect: true)
    }

    private func assertVolumeRediscoveryPreservesScale(
        _ initialReading: DDCVolumeValue?,
        setValue: UInt16?,
        relativeValue: UInt16,
        disconnect: Bool = false
    ) async throws {
        let cache = VolumeTestCache(value: 0.95)
        defer { cache.restore() }
        let display = display(cache)
        let original = VolumeTestTransport(verified: false, usesDiscoveredService: true, registryEntryID: 42)
        original.update { $0.value = initialReading }
        let replacement = VolumeTestTransport(verified: false, usesDiscoveredService: true, registryEntryID: 42)
        var rediscovered = false
        let displays = VolumeTestDisplays(displays: [display])
        let controller = DisplayVolumeController(
            displayProvider: displays,
            displayIdentifier: { _ in "fixture" },
            backendBuilder: SystemDisplayVolumeBackendBuilder(
                resolveArm64Services: { _ in [:] },
                ddcFactory: { display, _ in
                    DDCVolumeBackend(display: display, transport: rediscovered ? replacement : original, identifier: cache.identifier)
                }
            ),
            shortWriteDelay: 0,
            minimumWriteInterval: 0
        )
        controller.refresh()
        try await waitUntil { controller.pendingReadCount == 0 }
        if let setValue {
            let set = await controller.setVolumeAndWait(0.4, for: display.id)
            XCTAssertEqual(set, .succeeded)
            XCTAssertEqual(original.read { $0.writes }, [setValue])
        } else {
            XCTAssertTrue(original.read { $0.writes }.isEmpty)
        }

        if disconnect {
            displays.displays = []
            controller.refreshDisplayTopology()
            XCTAssertTrue(controller.snapshot().displays.isEmpty)
            displays.displays = [display]
        }
        rediscovered = true
        controller.refreshDisplayTopology()
        try await waitUntil { controller.pendingReadCount == 0 }
        XCTAssertFalse(controller.exactVolumeAvailability(for: display.id).isAvailable)
        let relative = await controller.adjustVolumeAndWait(by: -0.01, for: display.id)
        XCTAssertEqual(relative, .succeeded)
        XCTAssertEqual(replacement.read { $0.writes }, [relativeValue])
    }

    func testTopologyRefreshRevalidatesDiscoveredVolumeBindingWithUnchangedDisplayID() async throws {
        let cache = VolumeTestCache(value: 0.4)
        defer { cache.restore() }
        let display = display(cache)
        let verified = VolumeTestTransport(usesDiscoveredService: true)
        let ambiguous = VolumeTestTransport(verified: false, usesDiscoveredService: true)
        verified.update { $0.value = .init(current: 40, maximum: 100) }
        ambiguous.update { $0.value = .init(current: 40, maximum: 100) }
        var discoveryIsUnique = true
        let builder = SystemDisplayVolumeBackendBuilder(
            resolveArm64Services: { _ in [:] },
            ddcFactory: { display, _ in
                DDCVolumeBackend(display: display, transport: discoveryIsUnique ? verified : ambiguous, identifier: cache.identifier)
            }
        )
        let controller = DisplayVolumeController(
            displayProvider: VolumeTestDisplays(displays: [display]),
            displayIdentifier: { _ in "fixture" },
            backendBuilder: builder,
            shortWriteDelay: 0,
            minimumWriteInterval: 0
        )
        controller.refresh()
        XCTAssertTrue(controller.exactVolumeAvailability(for: display.id).isAvailable)
        discoveryIsUnique = false
        controller.refresh()
        XCTAssertTrue(controller.exactVolumeAvailability(for: display.id).isAvailable)
        controller.refreshDisplayTopology()
        XCTAssertFalse(controller.exactVolumeAvailability(for: display.id).isAvailable)
        let exact = await controller.setExactVolumeAndWait(0.5, for: display.id, identifier: "fixture")
        guard case .failed = exact else { return XCTFail("An ambiguous binding must reject exact actions") }
        let slider = await controller.setVolumeAndWait(0.5, for: display.id)
        XCTAssertEqual(slider, .succeeded)
        XCTAssertEqual(verified.read { $0.writes }, [])
        XCTAssertEqual(ambiguous.read { $0.writes }, [50])
    }

    func testTopologyReplacementWaitsForRetiredExactVolumeAndFreshRead() async throws {
        let cache = VolumeTestCache(value: 0.95)
        defer { cache.restore() }
        let display = display(cache)
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let original = VolumeTestTransport(usesDiscoveredService: true)
        original.update {
            $0.value = .init(current: 95, maximum: 100)
            $0.writeGate = gate
        }
        let replacement = VolumeTestTransport()
        var rediscovered = false
        let controller = DisplayVolumeController(
            displayProvider: VolumeTestDisplays(displays: [display]),
            displayIdentifier: { _ in "fixture" },
            backendBuilder: SystemDisplayVolumeBackendBuilder(
                resolveArm64Services: { _ in [:] },
                ddcFactory: { display, _ in
                    DDCVolumeBackend(display: display, transport: rediscovered ? replacement : original, identifier: cache.identifier)
                }
            ),
            shortWriteDelay: 0,
            minimumWriteInterval: 0
        )
        controller.refresh()
        try await waitUntil { controller.pendingReadCount == 0 }
        let exact = Task { await controller.setExactVolumeAndWait(0.2, for: display.id, identifier: "fixture") }
        try await waitUntil { original.read { $0.writes == [20] } }

        rediscovered = true
        controller.refreshDisplayTopology()
        XCTAssertEqual(controller.snapshot().displays.first?.isReady, false)
        XCTAssertEqual(replacement.read { $0.readCount }, 0)
        gate.signal()
        guard case .failed = await exact.value else {
            return XCTFail("Topology refresh must invalidate the old exact action")
        }
        try await waitUntil { controller.pendingReadCount == 0 }
        XCTAssertGreaterThan(replacement.read { $0.readCount }, 0)
        guard case .failed = await controller.adjustVolumeAndWait(by: -0.01, for: display.id) else {
            return XCTFail("A failed GET on the replacement backend must not enable relative writes")
        }
        XCTAssertTrue(replacement.read { $0.writes }.isEmpty)

        replacement.update { $0.value = .init(current: 20, maximum: 100) }
        controller.refresh()
        try await waitUntil { controller.snapshot().displays.first?.isReady == true }
        let adjustment = await controller.adjustVolumeAndWait(by: -0.01, for: display.id)
        XCTAssertEqual(adjustment, .succeeded)
        XCTAssertEqual(replacement.read { $0.writes }, [19])
    }

    func testReusedVolumeIDWaitsForOldWriteWithoutInheritingItsVerification() async throws {
        let cache = VolumeTestCache(value: 0.95)
        defer { cache.restore() }
        let display = display(cache)
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let identity = OSAllocatedUnfairLock(initialState: "monitor-a")
        let original = VolumeTestTransport()
        original.update {
            $0.value = .init(current: 95, maximum: 100)
            $0.writeGate = gate
        }
        let replacement = VolumeTestTransport(verified: false)
        replacement.update { $0.value = .init(current: 60, maximum: 100) }
        let reconnected = VolumeTestTransport(verified: false)
        reconnected.update { $0.value = .init(current: 20, maximum: 100) }
        var initialConnection = true
        let controller = DisplayVolumeController(
            displayProvider: VolumeTestDisplays(displays: [display]),
            displayIdentifier: { _ in identity.withLock { $0 } },
            backendBuilder: SystemDisplayVolumeBackendBuilder(
                resolveArm64Services: { _ in [:] },
                ddcFactory: { display, _ in
                    let transport: VolumeTestTransport
                    if initialConnection {
                        transport = original
                    } else if identity.withLock({ $0 == "monitor-a" }) {
                        transport = reconnected
                    } else {
                        transport = replacement
                    }
                    return DDCVolumeBackend(display: display, transport: transport, identifier: cache.identifier)
                }
            ),
            shortWriteDelay: 0,
            minimumWriteInterval: 0
        )
        controller.refresh()
        try await waitUntil { controller.pendingReadCount == 0 }
        let exact = Task { await controller.setExactVolumeAndWait(0.2, for: display.id, identifier: "monitor-a") }
        try await waitUntil { original.read { $0.writes == [20] } }

        initialConnection = false
        identity.withLock { $0 = "monitor-b" }
        controller.refreshDisplayTopology()
        XCTAssertEqual(replacement.read { $0.readCount }, 0)
        XCTAssertEqual(controller.snapshot().displays.first?.canAdjustRelative, false)
        gate.signal()

        guard case .failed = await exact.value else {
            return XCTFail("Replacing the saved monitor must invalidate its action")
        }
        try await waitUntil { controller.snapshot().displays.first?.canAdjustRelative == true }
        let replacementAdjustment = await controller.adjustVolumeAndWait(by: -0.01, for: display.id)
        XCTAssertEqual(replacementAdjustment, .succeeded)
        XCTAssertEqual(replacement.read { $0.writes }, [59])

        identity.withLock { $0 = "monitor-a" }
        controller.refreshDisplayTopology()
        try await waitUntil { controller.pendingReadCount == 0 }
        XCTAssertEqual(controller.snapshot().displays.first?.canAdjustRelative, false)
        let originalAdjustment = await controller.adjustVolumeAndWait(by: -0.01, for: display.id)
        guard case .failed = originalAdjustment else {
            return XCTFail("The original monitor still requires verified readback")
        }
        XCTAssertTrue(reconnected.read { $0.writes }.isEmpty)
    }

    func testRetiredSliderWriteLetsHeuristicVolumeResumeAfterFreshRead() async throws {
        let cache = VolumeTestCache(value: 0.95)
        defer { cache.restore() }
        let display = display(cache)
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let original = VolumeTestTransport(verified: false, usesDiscoveredService: true)
        original.update {
            $0.value = .init(current: 95, maximum: 100)
            $0.beforeWriteGate = gate
        }
        let replacement = VolumeTestTransport(verified: false)
        replacement.update { $0.value = .init(current: 60, maximum: 100) }
        var rediscovered = false
        let controller = DisplayVolumeController(
            displayProvider: VolumeTestDisplays(displays: [display]),
            displayIdentifier: { _ in "fixture" },
            backendBuilder: SystemDisplayVolumeBackendBuilder(
                resolveArm64Services: { _ in [:] },
                ddcFactory: { display, _ in
                    DDCVolumeBackend(display: display, transport: rediscovered ? replacement : original, identifier: cache.identifier)
                }
            ),
            shortWriteDelay: 0,
            minimumWriteInterval: 0
        )
        controller.refresh()
        try await waitUntil { controller.pendingReadCount == 0 }
        let slider = Task { await controller.setVolumeAndWait(0.8, for: display.id) }
        try await waitUntil { original.read { $0.writeStarted } }

        rediscovered = true
        controller.refreshDisplayTopology()
        XCTAssertEqual(controller.snapshot().displays.first?.isReady, false)
        XCTAssertEqual(replacement.read { $0.readCount }, 0)
        gate.signal()
        let sliderResult = await slider.value
        XCTAssertEqual(sliderResult, .succeeded)
        try await waitUntil { controller.snapshot().displays.first?.isReady == true }
        let adjustment = await controller.adjustVolumeAndWait(by: -0.01, for: display.id)
        XCTAssertEqual(adjustment, .succeeded)
        XCTAssertEqual(original.read { $0.writes }, [80])
        XCTAssertEqual(replacement.read { $0.writes }, [59])
    }

    func testReplacementExactVolumeWaitsForRetiredSliderWrite() async throws {
        let cache = VolumeTestCache(value: 0.95)
        defer { cache.restore() }
        let display = display(cache)
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let writeOrder = VolumeTestTransport()
        let original = VolumeTestTransport(usesDiscoveredService: true)
        original.update {
            $0.value = .init(current: 95, maximum: 100)
            $0.beforeWriteGate = gate
            $0.didWrite = { value in writeOrder.update { $0.writes.append(value) } }
        }
        let replacement = VolumeTestTransport()
        replacement.update {
            $0.value = .init(current: 95, maximum: 100)
            $0.didWrite = { value in writeOrder.update { $0.writes.append(value) } }
        }
        var rediscovered = false
        let controller = DisplayVolumeController(
            displayProvider: VolumeTestDisplays(displays: [display]),
            displayIdentifier: { _ in "fixture" },
            backendBuilder: SystemDisplayVolumeBackendBuilder(
                resolveArm64Services: { _ in [:] },
                ddcFactory: { display, _ in
                    DDCVolumeBackend(display: display, transport: rediscovered ? replacement : original, identifier: cache.identifier)
                }
            ),
            shortWriteDelay: 0,
            minimumWriteInterval: 0
        )
        controller.refresh()
        try await waitUntil { controller.pendingReadCount == 0 }
        let slider = Task { await controller.setVolumeAndWait(0.8, for: display.id) }
        try await waitUntil { original.read { $0.writeStarted } }

        rediscovered = true
        controller.refreshDisplayTopology()
        let exact = Task { await controller.setExactVolumeAndWait(0.4, for: display.id, identifier: "fixture") }
        try await waitUntil { controller.snapshot().displays.first?.volume == 0.4 }
        XCTAssertFalse(replacement.read { $0.writeStarted })
        XCTAssertEqual(replacement.read { $0.readCount }, 0)
        gate.signal()

        let sliderResult = await slider.value
        let exactResult = await exact.value
        XCTAssertEqual(sliderResult, .succeeded)
        XCTAssertEqual(exactResult, .succeeded)
        XCTAssertEqual(writeOrder.read { $0.writes }, [80, 40])
    }

    func testCancelledExactVolumeReconcilesAnInFlightWrite() async throws {
        let cache = VolumeTestCache(value: 0.95)
        defer { cache.restore() }
        let display = display(cache)
        let gate = DispatchSemaphore(value: 0)
        let transport = VolumeTestTransport()
        transport.update {
            $0.value = .init(current: 95, maximum: 100)
            $0.writeGate = gate
        }
        let backend = try XCTUnwrap(DDCVolumeBackend(display: display, transport: transport, identifier: cache.identifier))
        let controller = DisplayVolumeController(
            displayProvider: VolumeTestDisplays(displays: [display]),
            displayIdentifier: { _ in "fixture" },
            backendBuilder: VolumeTestBuilder(backend: backend),
            shortWriteDelay: 0,
            minimumWriteInterval: 0
        )
        controller.refresh()
        try await waitUntil { controller.pendingReadCount == 0 }
        let initialReadCount = transport.read { $0.readCount }
        let write = Task { await controller.setExactVolumeAndWait(0.2, for: display.id, identifier: "fixture") }
        try await waitUntil { transport.read { $0.writes == [20] } }
        write.cancel()
        gate.signal()

        guard case .failed = await write.value else { return XCTFail("Cancelled action must fail") }
        XCTAssertGreaterThanOrEqual(transport.read { $0.readCount }, initialReadCount + 2)
        XCTAssertEqual(controller.snapshot().displays.first?.volume, 0.2)
    }

    func testRestartRejectsCachedLevelFromDifferentEndpointWithSameUUID() async throws {
        let cache = VolumeTestCache(value: 0.95)
        defer { cache.restore() }
        let display = display(cache)
        let original = try XCTUnwrap(DDCVolumeBackend(
            display: display, transport: VolumeTestTransport(registryEntryID: 42), identifier: cache.identifier
        ))
        try original.writeVolume(0.95)
        let replacement = VolumeTestTransport(registryEntryID: 43)
        let restarted = try XCTUnwrap(DDCVolumeBackend(display: display, transport: replacement, identifier: cache.identifier))
        let controller = controller(display, backend: restarted)
        defer { controller.cancelOutstandingWrites() }
        controller.refresh()
        try await waitUntil { controller.pendingReadCount == 0 }
        XCTAssertEqual(controller.snapshot().displays.first?.volume, 0.95)
        guard case .failed = await controller.adjustVolumeAndWait(by: -0.01, for: display.id) else {
            return XCTFail("Decrease must require a level from the current endpoint")
        }
        XCTAssertTrue(replacement.read { $0.writes }.isEmpty)

        let mute = await controller.setVolumeAndWait(0, for: display.id)
        XCTAssertEqual(mute, .succeeded)
        let plugin = DisplayVolumePlugin(controller: controller, mouseDisplayIDProvider: { display.id })
        try await decrease(plugin)
        XCTAssertEqual(replacement.read { $0.writes }, [0, 0])
    }

    func testSuccessfulWritePersistsWhenGETIsUnavailable() throws {
        let cache = VolumeTestCache(value: 0.4)
        defer { cache.restore() }
        let transport = VolumeTestTransport()
        let backend = try XCTUnwrap(DDCVolumeBackend(display: display(cache), transport: transport, identifier: cache.identifier))
        try backend.writeVolume(0.6)
        let restarted = try XCTUnwrap(DDCVolumeBackend(display: display(cache), transport: transport, identifier: cache.identifier))
        XCTAssertEqual(try restarted.readVolume(), 0.6)
        XCTAssertFalse(restarted.hasKnownVolume)
    }

    func testWriteOnlyDisplayRequiresKnownVolumeAfterLegacyCacheUpgrade() async throws {
        let cache = VolumeTestCache(value: 0.4)
        let newIdentifier = "\(cache.identifier)-replacement"
        let legacyKey = "ddc-volume-\(cache.id)"
        let priorLegacyValue = UserDefaults.standard.object(forKey: legacyKey)
        UserDefaults.standard.set(0.0, forKey: legacyKey)
        defer {
            cache.restore()
            UserDefaults.standard.removeObject(forKey: "ddc-volume-target-\(newIdentifier)")
            if let priorLegacyValue {
                UserDefaults.standard.set(priorLegacyValue, forKey: legacyKey)
            } else {
                UserDefaults.standard.removeObject(forKey: legacyKey)
            }
        }
        let display = display(cache)
        let original = try XCTUnwrap(DDCVolumeBackend(
            display: display, transport: VolumeTestTransport(), identifier: cache.identifier
        ))
        try original.writeVolume(0.9)
        let replacementTransport = VolumeTestTransport()
        let replacement = try XCTUnwrap(DDCVolumeBackend(
            display: display, transport: replacementTransport, identifier: newIdentifier
        ))
        let controller = controller(display, backend: replacement)
        defer { controller.cancelOutstandingWrites() }
        controller.refresh()
        try await waitUntil { controller.pendingReadCount == 0 }
        XCTAssertEqual(controller.snapshot().displays.first?.isReady, false)
        let rejected = await controller.adjustVolumeAndWait(by: -0.01, for: display.id)
        guard case .failed = rejected else { return XCTFail("Decrease must not use an unknown level") }
        XCTAssertTrue(replacementTransport.read { $0.writes }.isEmpty)
        let established = await controller.setVolumeAndWait(0, for: display.id)
        XCTAssertEqual(established, .succeeded)
        try await decrease(DisplayVolumePlugin(controller: controller, mouseDisplayIDProvider: { display.id }))
        XCTAssertEqual(replacementTransport.read { $0.writes }, [0, 0])
        XCTAssertEqual(UserDefaults.standard.double(forKey: cache.key), 0.9)
    }

    func testBackgroundVolumeCachePublishesWithoutBlockingSnapshotReads() async throws {
        let cache = VolumeTestCache(value: 0.15)
        defer { cache.restore() }
        let transport = VolumeTestTransport()
        transport.update { $0.value = .init(current: 40, maximum: 100) }
        let backend = try XCTUnwrap(DDCVolumeBackend(display: display(cache), transport: transport, identifier: cache.identifier))
        let cacheKey = cache.key
        let displayID = cache.id
        let readPublished = expectation(description: "Read cache published")
        let writePublished = expectation(description: "Write cache published")
        let observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: nil
        ) { _ in
            let volume = UserDefaults.standard.double(forKey: cacheKey)
            guard volume == 0.4 || volume == 0.6 else { return }
            XCTAssertTrue(Thread.isMainThread, "Preference notifications must not wait for SwiftUI from a worker")
            guard Thread.isMainThread else { return }
            // A synchronous observer can read the same snapshots used by a
            // Settings refresh without reentering a held backend lock.
            XCTAssertEqual(backend.cachedVolume, volume)
            XCTAssertEqual(backend.display.id, displayID)
            if volume == 0.4 { readPublished.fulfill() }
            else { writePublished.fulfill() }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let volume = try await Task.detached { try backend.readVolume() }.value
        XCTAssertEqual(volume, 0.4)
        await fulfillment(of: [readPublished], timeout: 3)
        try await Task.detached { try backend.writeVolume(0.6) }.value
        await fulfillment(of: [writePublished], timeout: 3)
        let restarted = try XCTUnwrap(DDCVolumeBackend(display: display(cache), transport: transport, identifier: cache.identifier))
        XCTAssertEqual(restarted.cachedVolume, 0.6)
    }

    func testFailedWriteDoesNotBecomeCommittedAfterRefresh() async throws {
        let cache = VolumeTestCache(value: 0.4)
        defer { cache.restore() }
        let transport = VolumeTestTransport()
        transport.update {
            $0.value = .init(current: 40, maximum: 100)
            $0.failWrites = true
        }
        let backend = try XCTUnwrap(DDCVolumeBackend(display: display(cache), transport: transport, identifier: cache.identifier))
        let controller = controller(display(cache), backend: backend)
        defer { controller.cancelOutstandingWrites() }
        controller.refresh()
        let result = await controller.setVolumeAndWait(0.9, for: cache.id)
        guard case .failed = result else { return XCTFail("The injected SET failure must reach the caller") }
        XCTAssertEqual(controller.snapshot().displays.first?.volume, 0.4)
        try await waitUntil { controller.pendingReadCount == 0 }
        controller.refresh()
        XCTAssertEqual(controller.snapshot().displays.first?.volume, 0.4,
                       "Refresh must retain the last committed value, not the failed 90 percent request")
        XCTAssertEqual(UserDefaults.standard.double(forKey: cache.key), 0.4)
    }

    func testDDCRefreshDoesNotBlockTheMainThread() async throws {
        let first = VolumeTestCache(value: 0.4)
        let second = VolumeTestCache(value: 0.4)
        defer { first.restore(); second.restore() }
        let transport = VolumeTestTransport()
        transport.update { $0.readDelay = 0.13; $0.value = .init(current: 40, maximum: 100) }
        let builder = SystemDisplayVolumeBackendBuilder(resolveArm64Services: { _ in [:] }, ddcFactory: { display, _ in
            DDCVolumeBackend(display: display, transport: transport)
        })
        let controller = DisplayVolumeController(displayProvider: VolumeTestDisplays(displays: [display(first), display(second)]),
                                                 backendBuilder: builder)
        defer { controller.cancelOutstandingWrites() }
        let start = ProcessInfo.processInfo.systemUptime
        controller.refresh()
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        XCTAssertEqual(transport.read { $0.mainThreadReads }, 0,
                       "DDC reads ran on the main thread; refresh elapsed \(elapsed) seconds")
        try await Task.sleep(for: .milliseconds(350))
    }

    func testCancelledTopologyRefreshDoesNotRepopulateDeactivatedController() async throws {
        let cache = VolumeTestCache(value: 0.4)
        defer { cache.restore() }
        let transport = VolumeTestTransport()
        let backend = try XCTUnwrap(DDCVolumeBackend(display: display(cache), transport: transport, identifier: cache.identifier))
        let controller = controller(display(cache), backend: backend)
        let plugin = DisplayVolumePlugin(controller: controller)
        defer { plugin.deactivate(reason: .updating) }
        plugin.refreshDisplayTopology()
        XCTAssertFalse(controller.snapshot().displays.isEmpty)
        plugin.deactivate(reason: .updating)
        XCTAssertTrue(controller.snapshot().displays.isEmpty)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(controller.snapshot().displays.isEmpty,
                      "The cancelled topology task must not refresh a deactivated plugin")
    }

    func testBackgroundReadUpdatesSnapshotBeforeDecrease() async throws {
        let cache = VolumeTestCache(value: 0.15)
        defer { cache.restore() }
        let transport = VolumeTestTransport()
        transport.update { $0.value = .init(current: 5, maximum: 100) }
        let display = display(cache)
        let backend = try XCTUnwrap(DDCVolumeBackend(display: display, transport: transport, identifier: cache.identifier))
        let controller = controller(display, backend: backend)
        let plugin = DisplayVolumePlugin(controller: controller, mouseDisplayIDProvider: { display.id })
        defer { plugin.deactivate(reason: .updating) }
        var notifications = 0
        plugin.onStateChange = { notifications += 1 }
        plugin.refresh()

        // Wait for evidence that the backend has processed the successful GET.
        for _ in 0..<100 {
            if UserDefaults.standard.double(forKey: cache.key) == 0.05 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(UserDefaults.standard.double(forKey: cache.key), 0.05)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(controller.snapshot().displays.first?.volume, 0.05,
                       "A completed background GET must publish the real volume to the controller")
        XCTAssertGreaterThan(notifications, 0, "The host must be notified when the fetched volume becomes available")
        try await decrease(plugin)
        XCTAssertEqual(transport.read { $0.writes.last }, 4,
                       "Decrease must change the known hardware value from 5 to 4, not use the stale 15 percent estimate")
        try await Task.sleep(for: .milliseconds(50))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for the background operation")
    }

    func testReadMaximumIsUsedForSubsequentWrites() async throws {
        let cache = VolumeTestCache(value: 0.15)
        defer { cache.restore() }
        let transport = VolumeTestTransport()
        transport.update { $0.value = .init(current: 40, maximum: 200) }
        let backend = try XCTUnwrap(DDCVolumeBackend(display: display(cache), transport: transport, identifier: cache.identifier))
        let controller = controller(display(cache), backend: backend)
        defer { controller.cancelOutstandingWrites() }
        controller.refresh()
        try await waitUntil { controller.pendingReadCount == 0 }
        XCTAssertEqual(controller.snapshot().displays.first?.volume, 0.2)
        let result = await controller.setVolumeAndWait(0.5, for: cache.id)
        XCTAssertEqual(result, .succeeded)
        XCTAssertEqual(transport.read { $0.writes.last }, 100)
        XCTAssertEqual(controller.snapshot().displays.first?.volume, 0.5)
    }

    func testRepeatedRefreshCoalescesHardwareReads() async throws {
        let cache = VolumeTestCache(value: 0.15)
        defer { cache.restore() }
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let transport = VolumeTestTransport()
        transport.update { $0.value = .init(current: 5, maximum: 100); $0.readGate = gate }
        let backend = try XCTUnwrap(DDCVolumeBackend(display: display(cache), transport: transport, identifier: cache.identifier))
        let controller = controller(display(cache), backend: backend)
        defer { controller.cancelOutstandingWrites() }
        controller.refresh()
        try await waitUntil { transport.read { $0.readCount } == 1 }
        for _ in 0..<20 { controller.refresh() }
        XCTAssertEqual(controller.pendingReadCount, 1)
        XCTAssertEqual(transport.read { $0.readCount }, 1)
        gate.signal()
        try await waitUntil { controller.pendingReadCount == 0 }
        XCTAssertEqual(controller.snapshot().displays.first?.volume, 0.05)
        XCTAssertEqual(transport.read { $0.mainThreadReads }, 0)
    }

    func testPendingWriteDiscardsOlderReadAndSurvivesRefresh() async throws {
        let cache = VolumeTestCache(value: 0.15)
        defer { cache.restore() }
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let transport = VolumeTestTransport()
        transport.update { $0.value = .init(current: 5, maximum: 100); $0.readGate = gate }
        let backend = try XCTUnwrap(DDCVolumeBackend(display: display(cache), transport: transport, identifier: cache.identifier))
        let controller = DisplayVolumeController(
            displayProvider: VolumeTestDisplays(displays: [display(cache)]),
            backendBuilder: VolumeTestBuilder(backend: backend),
            shortWriteDelay: 60, minimumWriteInterval: 0
        )
        defer { controller.cancelOutstandingWrites() }
        controller.refresh()
        try await waitUntil { transport.read { $0.readCount } == 1 }
        controller.setVolume(0.9, for: cache.id, phase: .changed)
        transport.update { $0.value = nil; $0.readGate = nil }
        gate.signal()
        // A second read drains the backend I/O lock without supplying new volume data.
        _ = try await Task.detached { try backend.readVolume() }.value
        XCTAssertEqual(backend.cachedVolume, 0.15)
        controller.refresh()
        XCTAssertEqual(controller.snapshot().displays.first?.volume, 0.9)
        XCTAssertEqual(controller.snapshot().displays.first?.isPendingWrite, true)
        let result = await controller.setVolumeAndWait(0.9, for: cache.id)
        XCTAssertEqual(result, .succeeded)
        XCTAssertEqual(controller.snapshot().displays.first?.volume, 0.9)
        XCTAssertEqual(backend.cachedVolume, 0.9)
    }

    func testDeactivationDiscardsInFlightReadAndCacheUpdate() async throws {
        try await assertRetiredReadIsDiscarded(disconnect: false)
    }

    func testDisconnectDiscardsInFlightReadAndCacheUpdate() async throws {
        try await assertRetiredReadIsDiscarded(disconnect: true)
    }

    private func assertRetiredReadIsDiscarded(disconnect: Bool) async throws {
        let cache = VolumeTestCache(value: 0.15)
        defer { cache.restore() }
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let transport = VolumeTestTransport()
        transport.update { $0.value = .init(current: 5, maximum: 100); $0.readGate = gate }
        let backend = try XCTUnwrap(DDCVolumeBackend(display: display(cache), transport: transport, identifier: cache.identifier))
        let displays = VolumeTestDisplays(displays: [display(cache)])
        let controller = DisplayVolumeController(displayProvider: displays, backendBuilder: VolumeTestBuilder(backend: backend))
        let plugin = DisplayVolumePlugin(controller: controller)
        defer { plugin.deactivate(reason: .updating) }
        plugin.refresh()
        try await waitUntil { transport.read { $0.readCount } == 1 }
        if disconnect {
            displays.displays = []
            plugin.refresh()
        } else {
            plugin.deactivate(reason: .updating)
        }
        var notifications = 0
        plugin.onStateChange = { notifications += 1 }
        transport.update { $0.value = nil; $0.readGate = nil }
        gate.signal()
        _ = try await Task.detached { try backend.readVolume() }.value
        XCTAssertTrue(controller.snapshot().displays.isEmpty)
        XCTAssertEqual(controller.pendingReadCount, 0)
        XCTAssertEqual(backend.cachedVolume, 0.15)
        XCTAssertEqual(UserDefaults.standard.double(forKey: cache.key), 0.15)
        XCTAssertEqual(notifications, 0)
    }
}
