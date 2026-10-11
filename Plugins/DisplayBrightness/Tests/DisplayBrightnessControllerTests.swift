import AppKit
import CoreGraphics
import XCTest
import MacToolsPluginKit
@testable import DisplayBrightnessPlugin

@MainActor
final class DisplayBrightnessControllerTests: XCTestCase {
    func testSystemBuilderPreservesSoftwareFallbackWhenMainDisplayChanges() async {
        let display = makeTestDisplay(id: 19, name: "Apple Display", vendorNumber: 0x610)
        let provider = MutableDisplayProvider(displays: [display])
        let native = UnavailableNativeBrightnessBackend(display: display)
        let software = ScriptedBrightnessBackend(display: display, results: [.success(())], suspendsFirstWrite: false, kind: .gamma)
        let builder = SystemDisplayBrightnessBackendBuilder(
            resolveArm64Services: { _ in [:] }, appleFactory: { _ in native },
            ddcFactory: { _, _ in nil }, gammaFactory: { _ in software }, shadeFactory: { _ in nil }
        )
        let controller = DisplayBrightnessController(
            displayProvider: provider, backendBuilder: builder, shortWriteDelay: 0, minimumWriteInterval: 0
        )
        controller.refresh()
        await waitUntil { controller.snapshot().displays.first?.isReady == true }
        let result = await controller.setBrightnessAndWait(0.4, for: display.id)
        XCTAssertEqual(result, .succeeded)

        provider.displays = [makeTestDisplay(id: display.id, name: display.name, isMain: true, vendorNumber: 0x610)]
        controller.refresh()
        await controller.waitForScheduledReadsForTests()
        XCTAssertEqual(controller.snapshot().displays.first?.brightness, 0.4)
        XCTAssertEqual(software.display.isMain, true)
        XCTAssertEqual(software.cleanupCount, 0)
        controller.cancelOutstandingWrites()
        XCTAssertEqual(software.cleanupCount, 1)
    }

    func testReplacementWaitsForOldWriteAndDoesNotRetryItsFailure() async {
        let display = makeTestDisplay(id: 21, name: "Display")
        let old = ScriptedBrightnessBackend(display: display, results: [.failure(TestWriteError.failed)], suspendsFirstWrite: true)
        let replacement = ScriptedBrightnessBackend(display: display, results: [], suspendsFirstWrite: false)
        let unexpectedFallback = ScriptedBrightnessBackend(display: display, results: [.success(())], suspendsFirstWrite: false, kind: .gamma)
        let controller = DisplayBrightnessController(
            displayProvider: StaticDisplayProvider(display: display),
            backendBuilder: SequencedBrightnessBackendBuilder(backends: [old, replacement], fallback: unexpectedFallback),
            shortWriteDelay: 0, minimumWriteInterval: 0
        )
        controller.refresh()
        await waitUntil { controller.snapshot().displays.first?.isReady == true }
        let write = Task { await controller.setBrightnessAndWait(0.4, for: display.id) }
        await waitUntil { old.firstWriteStarted }
        controller.refresh()
        XCTAssertEqual(old.cleanupCount, 0)
        old.releaseFirstWrite()
        let result = await write.value
        await waitUntil { controller.snapshot().displays.first?.isReady == true }
        guard case .failed = result else { return XCTFail("Expected the old target's failure") }
        XCTAssertTrue(unexpectedFallback.writeValues.isEmpty)
        XCTAssertEqual(old.cleanupCount, 1)
        XCTAssertEqual(controller.snapshot().displays.first?.brightness, 1)
        controller.cancelOutstandingWrites()
        XCTAssertEqual(replacement.cleanupCount, 1)
    }

    func testRefreshDuringFailedWritePreservesCommittedBrightness() async {
        let display = makeTestDisplay(id: 23, name: "Display")
        let backend = ScriptedBrightnessBackend(display: display, results: [.failure(TestWriteError.failed)], suspendsFirstWrite: true)
        let controller = makeController(display: display, backend: backend)
        controller.refresh()
        await waitUntil { controller.snapshot().displays.first?.isReady == true }
        let write = Task { await controller.setBrightnessAndWait(0.4, for: display.id) }
        await waitUntil { backend.firstWriteStarted }
        controller.refresh()
        backend.releaseFirstWrite()
        guard case .failed = await write.value else { return XCTFail("Expected the hardware write to fail") }

        XCTAssertEqual(controller.snapshot().displays.first?.brightness, 1)
        XCTAssertEqual(controller.snapshot().displays.first?.isReady, true)
    }

    func testMainDisplayChangeDuringWriteKeepsControlsReady() async {
        let display = makeTestDisplay(id: 25, name: "Display")
        let provider = MutableDisplayProvider(displays: [display])
        let backend = ScriptedBrightnessBackend(display: display, results: [.success(())], suspendsFirstWrite: true)
        let controller = makeController(display: display, backend: backend, displayProvider: provider)
        controller.refresh()
        await waitUntil { controller.snapshot().displays.first?.isReady == true }
        let write = Task { await controller.setBrightnessAndWait(0.4, for: display.id) }
        await waitUntil { backend.firstWriteStarted }
        provider.displays = [makeTestDisplay(id: display.id, name: display.name, isMain: true)]
        controller.refresh()
        backend.releaseFirstWrite()
        let result = await write.value

        XCTAssertEqual(result, .succeeded)
        XCTAssertEqual(controller.snapshot().displays.first?.display.isMain, true)
        XCTAssertEqual(controller.snapshot().displays.first?.isReady, true)
        XCTAssertEqual(controller.snapshot().displays.first?.brightness, 0.4)
    }

    func testWriteFallbackUsesMonitorNativeBrightnessRange() async throws {
        let display = makeTestDisplay(id: 27, name: "Apple Display", vendorNumber: 0x610)
        let native = ScriptedBrightnessBackend(display: display, results: [.failure(TestWriteError.failed)], suspendsFirstWrite: false)
        let transport = ScalingDDCBrightnessTransport()
        let ddc = try XCTUnwrap(DDCBrightnessBackend(display: display, transport: transport))
        let builder = SystemDisplayBrightnessBackendBuilder(
            resolveArm64Services: { _ in [:] },
            appleFactory: { _ in native },
            ddcFactory: { _, _ in ddc },
            gammaFactory: { _ in nil }, shadeFactory: { _ in nil }
        )
        let controller = DisplayBrightnessController(
            displayProvider: StaticDisplayProvider(display: display), backendBuilder: builder,
            shortWriteDelay: 0, minimumWriteInterval: 0
        )
        controller.refresh()
        await waitUntil { controller.snapshot().displays.first?.isReady == true }
        let result = await controller.setBrightnessAndWait(0.75, for: display.id)

        XCTAssertEqual(result, .succeeded)
        XCTAssertEqual(transport.currentValue, 150)
        XCTAssertEqual(controller.snapshot().displays.first?.brightness, 0.75)
    }

    func testDDCReadFailureKeepsHardwareWritesUntilWriteFails() async throws {
        let display = makeTestDisplay(id: 35, name: "External Display")
        let transport = ScalingDDCBrightnessTransport(failsReads: true)
        let ddc = try XCTUnwrap(DDCBrightnessBackend(display: display, transport: transport))
        let software = ScriptedBrightnessBackend(
            display: display, results: [.success(())], suspendsFirstWrite: false, kind: .gamma
        )
        let builder = SystemDisplayBrightnessBackendBuilder(
            resolveArm64Services: { _ in [:] }, appleFactory: { _ in nil },
            ddcFactory: { _, _ in ddc }, gammaFactory: { _ in software }, shadeFactory: { _ in nil }
        )
        let controller = DisplayBrightnessController(
            displayProvider: StaticDisplayProvider(display: display), backendBuilder: builder,
            shortWriteDelay: 0, minimumWriteInterval: 0
        )
        controller.refresh()
        await waitUntil { controller.snapshot().displays.first?.isReady == true }
        XCTAssertEqual(controller.snapshot().displays.first?.brightness, 1)
        let firstResult = await controller.setBrightnessAndWait(0.75, for: display.id)
        XCTAssertEqual(firstResult, .succeeded)
        XCTAssertEqual(transport.writeValues, [75])
        XCTAssertTrue(software.writeValues.isEmpty)

        controller.refresh()
        await controller.waitForScheduledReadsForTests()
        XCTAssertEqual(controller.snapshot().displays.first?.isReady, true)
        XCTAssertEqual(controller.snapshot().displays.first?.brightness, 0.75)
        let refreshedResult = await controller.setBrightnessAndWait(0.6, for: display.id)
        XCTAssertEqual(refreshedResult, .succeeded)
        XCTAssertEqual(transport.writeValues, [75, 60])
        XCTAssertTrue(software.writeValues.isEmpty)

        transport.failNextWrite()
        let fallbackResult = await controller.setBrightnessAndWait(0.4, for: display.id)
        XCTAssertEqual(fallbackResult, .succeeded)
        XCTAssertEqual(transport.writeValues, [75, 60, 40])
        XCTAssertEqual(software.writeValues, [0.4])
        XCTAssertEqual(controller.snapshot().displays.first?.brightness, 0.4)
        controller.cancelOutstandingWrites()
    }

    func testInitialReadFailureSelectsAndPreservesWorkingFallback() async {
        let display = makeTestDisplay(id: 29, name: "Apple Display", vendorNumber: 0x610)
        let unavailable = UnavailableNativeBrightnessBackend(display: display)
        let fallback = BlockingReadBrightnessBackend(display: display)
        let builder = SystemDisplayBrightnessBackendBuilder(
            resolveArm64Services: { _ in [:] },
            appleFactory: { _ in unavailable },
            ddcFactory: { _, _ in fallback },
            gammaFactory: { _ in nil },
            shadeFactory: { _ in nil }
        )
        let controller = DisplayBrightnessController(
            displayProvider: StaticDisplayProvider(display: display), backendBuilder: builder,
            shortWriteDelay: 0, minimumWriteInterval: 0
        )
        controller.refresh()
        await waitUntil { controller.snapshot().displays.first?.isReady == true }
        XCTAssertEqual(controller.snapshot().displays.first?.brightness, 0.5)
        let result = await controller.setBrightnessAndWait(0.7, for: display.id)
        XCTAssertEqual(result, .succeeded)

        controller.refresh()
        XCTAssertEqual(controller.snapshot().displays.first?.isReady, true)
        await controller.waitForScheduledReadsForTests()
        XCTAssertEqual(controller.snapshot().displays.first?.brightness, 0.7)
    }

    func testInitialHardwareReadKeepsMainThreadResponsiveAndControlsPending() async {
        let display = makeTestDisplay(id: 31, name: "External Display")
        let backend = BlockingReadBrightnessBackend(display: display)
        backend.suspendNextRead()
        let controller = makeController(display: display, backend: backend)

        controller.refresh()
        await waitUntil { backend.readStarted }
        XCTAssertFalse(backend.readWasOnMainThread)
        XCTAssertEqual(controller.snapshot().displays.first?.isReady, false)
        backend.releaseRead()
        await waitUntil { controller.snapshot().displays.first?.isReady == true }
        XCTAssertEqual(controller.snapshot().displays.first?.brightness, 0.5)
    }

    func testLateRefreshDoesNotUndoNewerBrightnessWriteOrReviveDisconnectedDisplay() async {
        let display = makeTestDisplay(id: 33, name: "External Display")
        let provider = MutableDisplayProvider(displays: [display])
        let backend = BlockingReadBrightnessBackend(display: display)
        let controller = makeController(display: display, backend: backend, displayProvider: provider)
        controller.refresh()
        await waitUntil { controller.snapshot().displays.first?.isReady == true }

        backend.suspendNextRead()
        controller.refresh()
        await waitUntil { backend.readStarted }
        let write = await controller.setBrightnessAndWait(0.8, for: display.id)
        XCTAssertEqual(write, .succeeded)
        backend.releaseRead()
        await controller.waitForScheduledReadsForTests()
        XCTAssertEqual(controller.snapshot().displays.first?.brightness, 0.8)

        backend.suspendNextRead()
        controller.refresh()
        await waitUntil { backend.readStarted }
        provider.displays = []
        controller.refresh()
        backend.releaseRead()
        await controller.waitForScheduledReadsForTests()
        XCTAssertTrue(controller.snapshot().displays.isEmpty)
    }

    func testAwaitedWriteReportsItsOwnFailureWhenLaterWriteSucceeds() async {
        let display = makeTestDisplay(id: 7, name: "Studio Display")
        let backend = ScriptedBrightnessBackend(
            display: display,
            results: [.failure(TestWriteError.failed), .success(())],
            suspendsFirstWrite: true
        )
        let controller = makeController(display: display, backend: backend)
        controller.refresh()
        await waitUntil { controller.snapshot().displays.allSatisfy(\.isReady) }

        let actionResult = Task {
            await controller.setBrightnessAndWait(0.4, for: display.id)
        }
        await waitUntil { backend.firstWriteStarted }
        controller.setBrightness(0.8, for: display.id, phase: .ended)
        backend.releaseFirstWrite()

        let result = await actionResult.value
        await waitUntil { backend.writeValues.count == 2 }

        guard case .failed = result else {
            return XCTFail("Expected the failed 0.4 write to fail its own waiter")
        }
        XCTAssertEqual(backend.writeValues, [0.4, 0.8])
    }

    func testAwaitedPendingWriteFailsWhenSupersededBeforeItStarts() async {
        let display = makeTestDisplay(id: 9, name: "LG UltraFine")
        let backend = ScriptedBrightnessBackend(
            display: display,
            results: [.success(()), .success(())],
            suspendsFirstWrite: true
        )
        let controller = makeController(display: display, backend: backend)
        controller.refresh()
        await waitUntil { controller.snapshot().displays.allSatisfy(\.isReady) }
        controller.setBrightness(0.2, for: display.id, phase: .ended)
        await waitUntil { backend.firstWriteStarted }

        let actionResult = Task {
            await controller.setBrightnessAndWait(0.4, for: display.id)
        }
        await waitUntil {
            controller.snapshot().displays.first?.brightness == 0.4
        }
        controller.setBrightness(0.8, for: display.id, phase: .ended)
        backend.releaseFirstWrite()

        let result = await actionResult.value
        await waitUntil { backend.writeValues.count == 2 }

        guard case .failed = result else {
            return XCTFail("Expected the superseded 0.4 write to fail")
        }
        XCTAssertEqual(backend.writeValues, [0.2, 0.8])
    }

    func testInFlightWriteWaitsForActualOutcomePastTimeout() async {
        let display = makeTestDisplay(id: 11, name: "Pro Display XDR")
        let backend = ScriptedBrightnessBackend(
            display: display,
            results: [.success(())],
            suspendsFirstWrite: true
        )
        let controller = makeController(
            display: display,
            backend: backend,
            writeTimeout: .milliseconds(20)
        )
        controller.refresh()
        await waitUntil { controller.snapshot().displays.allSatisfy(\.isReady) }
        var observedResult: DisplayBrightnessWriteResult?

        let actionResult = Task { @MainActor in
            let result = await controller.setBrightnessAndWait(0.4, for: display.id)
            observedResult = result
            return result
        }
        await waitUntil { backend.firstWriteStarted }
        await waitUntil { controller.pendingWriteTimeoutCount == 0 }

        XCTAssertNil(observedResult, "an in-flight backend write must not report timeout before its real outcome")
        backend.releaseFirstWrite()
        let result = await actionResult.value

        XCTAssertEqual(result, .succeeded)
        XCTAssertEqual(
            controller.snapshot().displays.first?.brightness ?? -1,
            0.4,
            accuracy: 0.0001
        )
    }

    func testPendingWriteStillTimesOutBeforeBackendDispatch() async {
        let display = makeTestDisplay(id: 13, name: "Studio Display")
        let backend = ScriptedBrightnessBackend(
            display: display,
            results: [.success(()), .success(())],
            suspendsFirstWrite: true
        )
        let controller = makeController(
            display: display,
            backend: backend,
            writeTimeout: .milliseconds(20)
        )
        controller.refresh()
        await waitUntil { controller.snapshot().displays.allSatisfy(\.isReady) }
        controller.setBrightness(0.2, for: display.id, phase: .ended)
        await waitUntil { backend.firstWriteStarted }

        let result = await controller.setBrightnessAndWait(0.8, for: display.id)

        guard case .failed = result else {
            backend.releaseFirstWrite()
            return XCTFail("Expected a queued write to time out, got \(result)")
        }
        XCTAssertEqual(backend.writeValues, [0.2], "a timed-out pending write must never reach the backend")
        backend.releaseFirstWrite()
    }

    func testDisconnectedInFlightWriteReportsActualSuccess() async {
        let display = makeTestDisplay(id: 15, name: "Studio Display")
        let provider = MutableDisplayProvider(displays: [display])
        let backend = ScriptedBrightnessBackend(
            display: display,
            results: [.success(())],
            suspendsFirstWrite: true
        )
        let controller = makeController(
            display: display,
            backend: backend,
            writeTimeout: .milliseconds(20),
            displayProvider: provider
        )
        controller.refresh()
        await waitUntil { controller.snapshot().displays.allSatisfy(\.isReady) }
        var observedResult: DisplayBrightnessWriteResult?
        let resultTask = Task { @MainActor in
            let result = await controller.setBrightnessAndWait(0.4, for: display.id)
            observedResult = result
            return result
        }
        await waitUntil { backend.firstWriteStarted }

        provider.displays = []
        controller.refresh()
        await waitUntil { controller.snapshot().displays.allSatisfy(\.isReady) }
        await waitUntil { controller.pendingWriteTimeoutCount == 0 }

        XCTAssertNil(observedResult)
        XCTAssertTrue(controller.snapshot().displays.isEmpty)
        backend.releaseFirstWrite()

        let result = await resultTask.value
        XCTAssertEqual(result, .succeeded)
    }

    func testDisconnectedInFlightWriteReportsActualFailure() async {
        let display = makeTestDisplay(id: 17, name: "Studio Display")
        let provider = MutableDisplayProvider(displays: [display])
        let backend = ScriptedBrightnessBackend(
            display: display,
            results: [.failure(TestWriteError.failed)],
            suspendsFirstWrite: true
        )
        let controller = makeController(
            display: display,
            backend: backend,
            displayProvider: provider
        )
        controller.refresh()
        await waitUntil { controller.snapshot().displays.allSatisfy(\.isReady) }
        var observedResult: DisplayBrightnessWriteResult?
        let resultTask = Task { @MainActor in
            let result = await controller.setBrightnessAndWait(0.4, for: display.id)
            observedResult = result
            return result
        }
        await waitUntil { backend.firstWriteStarted }

        provider.displays = []
        controller.refresh()
        await waitUntil { controller.snapshot().displays.allSatisfy(\.isReady) }
        XCTAssertNil(observedResult)
        backend.releaseFirstWrite()

        guard case .failed = await resultTask.value else {
            return XCTFail("Expected the disconnected backend failure to be reported")
        }
    }

    func testLifecycleCancellationDropsPendingWriteBeforeDispatch() async {
        let display = makeTestDisplay(id: 19, name: "Studio Display")
        let backend = ScriptedBrightnessBackend(
            display: display,
            results: [.success(()), .success(())],
            suspendsFirstWrite: true
        )
        let controller = makeController(display: display, backend: backend)
        controller.refresh()
        await waitUntil { controller.snapshot().displays.allSatisfy(\.isReady) }
        controller.setBrightness(0.2, for: display.id, phase: .ended)
        await waitUntil { backend.firstWriteStarted }
        let pendingResult = Task {
            await controller.setBrightnessAndWait(0.8, for: display.id)
        }
        await waitUntil {
            controller.snapshot().displays.first?.brightness == 0.8
        }

        controller.cancelOutstandingWrites()
        guard case .failed = await pendingResult.value else {
            backend.releaseFirstWrite()
            return XCTFail("Expected the pending write to be cancelled")
        }
        XCTAssertEqual(backend.writeValues, [0.2])
        backend.releaseFirstWrite()
    }

    func testReactivationDoesNotLetRetiredFailureFallbackIntoNewDisplayState() async {
        let display = makeTestDisplay(id: 21, name: "Studio Display")
        let provider = MutableDisplayProvider(displays: [display])
        let retiredBackend = ScriptedBrightnessBackend(
            display: display,
            results: [.failure(TestWriteError.failed)],
            suspendsFirstWrite: true
        )
        let replacementBackend = ScriptedBrightnessBackend(
            display: display,
            results: [.success(())],
            suspendsFirstWrite: false
        )
        let builder = SequencedBrightnessBackendBuilder(
            backends: [retiredBackend, replacementBackend]
        )
        let controller = DisplayBrightnessController(
            displayProvider: provider,
            backendBuilder: builder,
            shortWriteDelay: 0,
            minimumWriteInterval: 0,
            writeTimeout: .seconds(10)
        )
        controller.refresh()
        await waitUntil { controller.snapshot().displays.allSatisfy(\.isReady) }
        let resultTask = Task {
            await controller.setBrightnessAndWait(0.4, for: display.id)
        }
        await waitUntil { retiredBackend.firstWriteStarted }

        controller.cancelOutstandingWrites()
        controller.refresh()
        await waitUntil { controller.snapshot().displays.allSatisfy(\.isReady) }
        retiredBackend.releaseFirstWrite()

        guard case .failed = await resultTask.value else {
            return XCTFail("Expected the retired backend's real failure")
        }
        await waitUntil { retiredBackend.cleanupCount == 1 }
        XCTAssertEqual(builder.fallbackCallCount, 0)
        XCTAssertTrue(replacementBackend.writeValues.isEmpty)
        XCTAssertEqual(
            controller.snapshot().displays.first?.brightness ?? -1,
            1,
            accuracy: 0.0001
        )
    }

    private func makeController(
        display: DisplayInfo,
        backend: any DisplayBrightnessBackend,
        writeTimeout: Duration = .seconds(10),
        displayProvider: (any DisplayProviding)? = nil
    ) -> DisplayBrightnessController {
        DisplayBrightnessController(
            displayProvider: displayProvider ?? StaticDisplayProvider(display: display),
            backendBuilder: StaticBrightnessBackendBuilder(backend: backend),
            shortWriteDelay: 0,
            minimumWriteInterval: 0,
            writeTimeout: writeTimeout
        )
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = ContinuousClock().now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock().now < deadline {
            await Task.yield()
        }
        XCTAssertTrue(condition())
    }
}

private final class MutableDisplayProvider: DisplayProviding {
    var displays: [DisplayInfo]

    init(displays: [DisplayInfo]) {
        self.displays = displays
    }

    func listConnectedDisplays() -> [DisplayInfo] { displays }
    func screen(for displayID: CGDirectDisplayID) -> NSScreen? { nil }
}

private struct StaticDisplayProvider: DisplayProviding {
    let display: DisplayInfo

    func listConnectedDisplays() -> [DisplayInfo] { [display] }
    func screen(for displayID: CGDirectDisplayID) -> NSScreen? { nil }
}

private struct StaticBrightnessBackendBuilder: DisplayBrightnessBackendBuilding {
    let backend: any DisplayBrightnessBackend

    func backends(
        for displays: [DisplayInfo],
        previous: [CGDirectDisplayID: any DisplayBrightnessBackend]
    ) -> [CGDirectDisplayID: any DisplayBrightnessBackend] {
        [backend.display.id: backend]
    }
}

private final class SequencedBrightnessBackendBuilder: DisplayBrightnessBackendBuilding {
    private let sequence: [ScriptedBrightnessBackend]
    private let fallback: ScriptedBrightnessBackend?
    private var buildIndex = 0
    private(set) var fallbackCallCount = 0

    init(backends: [ScriptedBrightnessBackend], fallback: ScriptedBrightnessBackend? = nil) {
        sequence = backends
        self.fallback = fallback
    }

    func backends(
        for displays: [DisplayInfo],
        previous: [CGDirectDisplayID: any DisplayBrightnessBackend]
    ) -> [CGDirectDisplayID: any DisplayBrightnessBackend] {
        guard let display = displays.first,
              !sequence.isEmpty else {
            return [:]
        }
        let backend = sequence[min(buildIndex, sequence.count - 1)]
        buildIndex += 1
        return [display.id: backend]
    }

    func fallbackBackend(
        after failedBackend: any DisplayBrightnessBackend,
        for display: DisplayInfo,
        previous: [CGDirectDisplayID: any DisplayBrightnessBackend]
    ) -> (any DisplayBrightnessBackend)? {
        fallbackCallCount += 1
        return fallback
    }
}

private enum TestWriteError: Error {
    case failed
}

private final class ScriptedBrightnessBackend: DisplayBrightnessBackend, @unchecked Sendable {
    let kind: DisplayBrightnessBackendKind
    var display: DisplayInfo

    private let lock = NSLock()
    private let firstWriteGate = DispatchSemaphore(value: 0)
    private var brightness = 1.0
    private var results: [Result<Void, Error>]
    private let suspendsFirstWrite: Bool
    private var didStartFirstWrite = false
    private var writes: [Double] = []
    private var cleanups = 0

    init(
        display: DisplayInfo,
        results: [Result<Void, Error>],
        suspendsFirstWrite: Bool,
        kind: DisplayBrightnessBackendKind = .appleNative
    ) {
        self.kind = kind
        self.display = display
        self.results = results
        self.suspendsFirstWrite = suspendsFirstWrite
    }

    var firstWriteStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didStartFirstWrite
    }

    var writeValues: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return writes
    }

    var cleanupCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cleanups
    }

    func readBrightness() throws -> Double {
        lock.lock()
        defer { lock.unlock() }
        return brightness
    }

    func writeBrightness(_ value: Double) throws {
        lock.lock()
        let writeIndex = writes.count
        writes.append(value)
        if writeIndex == 0 {
            didStartFirstWrite = true
        }
        let result = results.isEmpty ? .success(()) : results.removeFirst()
        lock.unlock()

        if writeIndex == 0, suspendsFirstWrite {
            firstWriteGate.wait()
        }
        try result.get()

        lock.lock()
        brightness = value
        lock.unlock()
    }

    func releaseFirstWrite() {
        firstWriteGate.signal()
    }

    func cleanup() {
        lock.lock()
        cleanups += 1
        lock.unlock()
    }
}

private final class BlockingReadBrightnessBackend: DisplayBrightnessBackend, @unchecked Sendable {
    let kind: DisplayBrightnessBackendKind = .ddc
    var display: DisplayInfo
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var brightness = 0.5
    private var suspendRead = false
    private var started = false
    private var wasOnMainThread = false

    init(display: DisplayInfo) { self.display = display }

    var readStarted: Bool { lock.withLock { started } }
    var readWasOnMainThread: Bool { lock.withLock { wasOnMainThread } }

    func suspendNextRead() {
        lock.withLock { suspendRead = true; started = false }
    }

    func releaseRead() { gate.signal() }

    func readBrightness() throws -> Double {
        let snapshot = lock.withLock { () -> (Double, Bool) in
            let shouldSuspend = suspendRead
            suspendRead = false
            started = true
            wasOnMainThread = Thread.isMainThread
            return (brightness, shouldSuspend)
        }
        if snapshot.1 { gate.wait() }
        return snapshot.0
    }

    func writeBrightness(_ value: Double) throws { lock.withLock { brightness = value } }
    func cleanup() {}
}

private final class UnavailableNativeBrightnessBackend: DisplayBrightnessBackend, @unchecked Sendable {
    let kind: DisplayBrightnessBackendKind = .appleNative
    var display: DisplayInfo
    init(display: DisplayInfo) { self.display = display }
    func readBrightness() throws -> Double { throw DisplayBrightnessControllerError.nativeAPINotAvailable }
    func writeBrightness(_ value: Double) throws { throw DisplayBrightnessControllerError.nativeBrightnessWriteFailed }
    func cleanup() {}
}

private final class ScalingDDCBrightnessTransport: DDCBrightnessTransport {
    private let lock = NSLock()
    private let failsReads: Bool
    private var current: UInt16 = 100
    private var writes: [UInt16] = []
    private var shouldFailNextWrite = false

    init(failsReads: Bool = false) { self.failsReads = failsReads }

    var currentValue: UInt16 { lock.withLock { current } }
    var writeValues: [UInt16] { lock.withLock { writes } }

    func readBrightness() throws -> DDCBrightnessValue {
        if failsReads { throw DisplayBrightnessControllerError.genericBrightnessUnavailable }
        return lock.withLock { DDCBrightnessValue(current: current, maximum: 200) }
    }

    func failNextWrite() { lock.withLock { shouldFailNextWrite = true } }

    func writeBrightness(_ value: UInt16) throws {
        try lock.withLock {
            writes.append(value)
            if shouldFailNextWrite {
                shouldFailNextWrite = false
                throw TestWriteError.failed
            }
            current = value
        }
    }
}
