import AppKit
import XCTest
import MacToolsPluginKit
@testable import DisplayVolumePlugin

private final class VolumeTestTransport: DDCVolumeTransport, @unchecked Sendable {
    struct State {
        var value: DDCVolumeValue?
        var failWrites = false
        var writes: [UInt16] = []
        var readDelay: TimeInterval = 0
        var mainThreadReads = 0
        var readCount = 0
        var readGate: DispatchSemaphore?
    }
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
        guard let value = request.value else {
            throw DisplayVolumeControllerError.failed(message: "GET unavailable")
        }
        return value
    }
    func writeVolume(_ value: UInt16) throws {
        if read({ $0.failWrites }) { throw DisplayVolumeControllerError.failed(message: "SET failed") }
        update {
            $0.writes.append(value)
            if let current = $0.value { $0.value = .init(current: value, maximum: current.maximum) }
        }
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
    var key: String { "ddc-volume-\(id)" }
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
    func testMuteSurvivesRestartAndDecreaseDoesNotRaiseVolume() async throws {
        let cache = VolumeTestCache(value: 0.4)
        defer { cache.restore() }
        let display = display(cache)
        let transport = VolumeTestTransport()
        let original = try XCTUnwrap(DDCVolumeBackend(display: display, transport: transport))
        try original.writeVolume(0)
        XCTAssertEqual(transport.read { $0.writes.last }, 0)
        let restarted = try XCTUnwrap(DDCVolumeBackend(display: display, transport: transport))
        let controller = controller(display, backend: restarted)
        defer { controller.cancelOutstandingWrites() }
        controller.refresh()
        XCTAssertEqual(controller.snapshot().displays.first?.volume, 0)
        let plugin = DisplayVolumePlugin(controller: controller, mouseDisplayIDProvider: { display.id })
        try await decrease(plugin)
        XCTAssertEqual(transport.read { $0.writes.last }, 0, "Decrease after restart must not unmute to 14 percent")
    }

    func testSuccessfulWritePersistsWhenGETIsUnavailable() throws {
        let cache = VolumeTestCache(value: 0.4)
        defer { cache.restore() }
        let transport = VolumeTestTransport()
        let backend = try XCTUnwrap(DDCVolumeBackend(display: display(cache), transport: transport))
        try backend.writeVolume(0.6)
        let restarted = try XCTUnwrap(DDCVolumeBackend(display: display(cache), transport: transport))
        XCTAssertEqual(try restarted.readVolume(), 0.6)
    }

    func testBackgroundVolumeCachePublishesWithoutBlockingSnapshotReads() async throws {
        let cache = VolumeTestCache(value: 0.15)
        defer { cache.restore() }
        let transport = VolumeTestTransport()
        transport.update { $0.value = .init(current: 40, maximum: 100) }
        let backend = try XCTUnwrap(DDCVolumeBackend(display: display(cache), transport: transport))
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
        let restarted = try XCTUnwrap(DDCVolumeBackend(display: display(cache), transport: transport))
        XCTAssertEqual(restarted.cachedVolume, 0.6)
    }

    func testFailedWriteDoesNotBecomeCommittedAfterRefresh() async throws {
        let cache = VolumeTestCache(value: 0.4)
        defer { cache.restore() }
        let transport = VolumeTestTransport()
        transport.update { $0.failWrites = true }
        let backend = try XCTUnwrap(DDCVolumeBackend(display: display(cache), transport: transport))
        let controller = controller(display(cache), backend: backend)
        defer { controller.cancelOutstandingWrites() }
        controller.refresh()
        let result = await controller.setVolumeAndWait(0.9, for: cache.id)
        guard case .failed = result else { return XCTFail("The injected SET failure must reach the caller") }
        XCTAssertEqual(controller.snapshot().displays.first?.volume, 0.4)
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
        let backend = try XCTUnwrap(DDCVolumeBackend(display: display(cache), transport: transport))
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
        let backend = try XCTUnwrap(DDCVolumeBackend(display: display, transport: transport))
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
        let backend = try XCTUnwrap(DDCVolumeBackend(display: display(cache), transport: transport))
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
        let backend = try XCTUnwrap(DDCVolumeBackend(display: display(cache), transport: transport))
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
        let backend = try XCTUnwrap(DDCVolumeBackend(display: display(cache), transport: transport))
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
        let backend = try XCTUnwrap(DDCVolumeBackend(display: display(cache), transport: transport))
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
