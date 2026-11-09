import AppKit
import CoreGraphics
import XCTest
import os
import MacToolsPluginKit
@testable import DisplayBrightnessPlugin

@MainActor
final class DisplayBrightnessControllerTests: XCTestCase {
    func testBuiltInExactBrightnessRequiresNativeReadback() async {
        let display = makeTestDisplay(id: 42, name: "Built-in fixture", isBuiltin: true, isMain: true)
        for observed in [0.7, 0.6] {
            let backend = ScriptedBrightnessBackend(
                display: display, results: [], suspendsFirstWrite: false, readbackAfterWrite: observed
            )
            let controller = DisplayBrightnessController(
                displayProvider: StaticDisplayProvider(display: display),
                isBuiltInDisplayEligible: { _ in true },
                backendBuilder: StaticBrightnessBackendBuilder(backend: backend),
                minimumWriteInterval: 0
            )
            controller.refresh()
            await waitUntil { controller.snapshot().displays.first?.isReady == true }
            let result = await controller.setBuiltInBrightnessAndWait(0.7)
            if observed == 0.7 {
                XCTAssertEqual(result, .succeeded)
            } else if case .succeeded = result {
                XCTFail("Mismatched native readback must fail")
            }
            XCTAssertEqual(controller.snapshot().displays.first?.brightness, observed)
            XCTAssertEqual(backend.writeValues, [0.7])
        }
    }

    func testBuiltInWriteRechecksEligibilityAfterNativeProbe() async {
        let display = makeTestDisplay(id: 42, name: "Built-in fixture", isBuiltin: true, isMain: true)
        let backend = ScriptedBrightnessBackend(display: display, results: [], suspendsFirstWrite: false)
        defer { backend.releaseRead() }
        let eligible = OSAllocatedUnfairLock(initialState: true)
        let controller = DisplayBrightnessController(
            displayProvider: StaticDisplayProvider(display: display),
            isBuiltInDisplayEligible: { _ in eligible.withLock { $0 } },
            backendBuilder: StaticBrightnessBackendBuilder(backend: backend),
            minimumWriteInterval: 0
        )
        controller.refresh()
        await waitUntil { controller.snapshot().displays.first?.isReady == true }
        backend.suspendNextRead()
        let scheduled = Task { await controller.setBuiltInBrightnessAndWait(0.7) }
        await waitUntil { backend.readStarted }
        eligible.withLock { $0 = false }
        backend.releaseRead()

        guard case .failed = await scheduled.value else {
            return XCTFail("A target that became ineligible must fail before writing")
        }
        XCTAssertTrue(backend.writeValues.isEmpty)
    }

    func testUnverifiedBuiltInWriteRequiresFreshBrightnessBeforeControlsResume() async {
        let display = makeTestDisplay(id: 42, name: "Built-in fixture", isBuiltin: true, isMain: true)
        for cancel in [false, true] {
            let backend = ScriptedBrightnessBackend(display: display, results: [], suspendsFirstWrite: true)
            let controller = DisplayBrightnessController(
                displayProvider: StaticDisplayProvider(display: display),
                isBuiltInDisplayEligible: { _ in true },
                backendBuilder: StaticBrightnessBackendBuilder(backend: backend),
                minimumWriteInterval: 0
            )
            defer { backend.releaseFirstWrite(); backend.releaseRead() }
            controller.refresh()
            await waitUntil { controller.snapshot().displays.first?.isReady == true }
            let scheduled = Task { await controller.setBuiltInBrightnessAndWait(0.7) }
            await waitUntil { backend.firstWriteStarted }
            if !cancel { backend.failNextReads(3) }
            backend.suspendNextRead()
            if cancel { scheduled.cancel() }
            backend.releaseFirstWrite()
            guard case .failed = await scheduled.value else {
                return XCTFail("An unverified write must fail")
            }
            await waitUntil { backend.readStarted }
            XCTAssertEqual(controller.snapshot().displays.first?.isReady, false)
            backend.releaseRead()
            await waitUntil { controller.snapshot().displays.first?.isReady == true }
            XCTAssertEqual(controller.snapshot().displays.first?.brightness, 0.7)
        }
    }

    func testLaterSchedulesReprobeNativeBrightnessWithoutRemovingSoftwareDimming() async {
        let display = makeTestDisplay(id: 42, name: "Built-in fixture", isBuiltin: true, isMain: true)
        let native = ScriptedBrightnessBackend(
            display: display, results: [.failure(TestWriteError.failed)], suspendsFirstWrite: false
        )
        native.failNextReads(1)
        let gamma = ScriptedBrightnessBackend(display: display, results: [], suspendsFirstWrite: false, kind: .gamma)
        let builder = SystemDisplayBrightnessBackendBuilder(
            resolveArm64Services: { _ in [:] },
            appleFactory: { _ in native },
            gammaFactory: { _ in gamma }
        )
        let controller = DisplayBrightnessController(
            displayProvider: StaticDisplayProvider(display: display),
            isBuiltInDisplayEligible: { _ in true },
            backendBuilder: builder,
            minimumWriteInterval: 0
        )
        controller.refresh()
        await waitUntil { controller.snapshot().displays.first?.isReady == true }
        XCTAssertTrue(controller.canSetBuiltInBrightness)
        let manual = await controller.setBrightnessAndWait(0.4, for: display.id)
        XCTAssertEqual(manual, .succeeded)
        XCTAssertEqual(gamma.writeValues, [0.4])

        native.failNextReads(1)
        guard case .failed = await controller.setBuiltInBrightnessAndWait(0.7) else {
            return XCTFail("An unavailable native probe must fail before the write")
        }
        XCTAssertTrue(native.writeValues.isEmpty)
        guard case .failed = await controller.setBuiltInBrightnessAndWait(0.7) else {
            return XCTFail("The first native write must report the transient failure")
        }
        XCTAssertEqual(gamma.cleanupCount, 0)
        XCTAssertEqual(controller.snapshot().displays.first?.brightness, 0.4)
        gamma.failNextRestore()
        guard case .failed = await controller.setBuiltInBrightnessAndWait(0.7) else {
            return XCTFail("A verified native write must fail when software dimming cannot be removed")
        }
        XCTAssertEqual(gamma.cleanupCount, 0)
        XCTAssertEqual(controller.snapshot().displays.first?.brightness, 0.4)
        let scheduled = await controller.setBuiltInBrightnessAndWait(0.7)
        XCTAssertEqual(scheduled, .succeeded)
        XCTAssertEqual(native.writeValues, [0.7, 0.7, 0.7])
        XCTAssertEqual(gamma.cleanupCount, 1)
    }

    func testBuiltInWriteCanVerifyWhileAnExternalReadIsBlocked() async {
        let display = makeTestDisplay(id: 42, name: "Built-in fixture", isBuiltin: true)
        let external = makeTestDisplay(id: 43, name: "External fixture", isMain: true)
        let native = ScriptedBrightnessBackend(display: display, results: [], suspendsFirstWrite: false)
        let ddc = BlockingReadBrightnessBackend(display: external)
        ddc.suspendNextRead()
        defer { ddc.releaseRead() }
        let controller = DisplayBrightnessController(
            displayProvider: MutableDisplayProvider(displays: [external, display]),
            isBuiltInDisplayEligible: { _ in true },
            backendBuilder: SystemDisplayBrightnessBackendBuilder(
                resolveArm64Services: { _ in [:] },
                appleFactory: { _ in native },
                ddcFactory: { _, _ in ddc }
            ),
            minimumWriteInterval: 0
        )
        controller.refresh()
        await waitUntil { ddc.readStarted }

        let result = await controller.setBuiltInBrightnessAndWait(0.7)
        XCTAssertEqual(result, .succeeded)
        XCTAssertEqual(native.writeValues, [0.7])
    }

    func testManualWriteWaitsForBuiltInVerificationWithoutUsingItsUnverifiedTarget() async {
        let display = makeTestDisplay(id: 42, name: "Built-in fixture", isBuiltin: true, isMain: true)
        let backend = ScriptedBrightnessBackend(display: display, results: [], suspendsFirstWrite: true)
        backend.seedBrightness(0.5)
        defer { backend.releaseFirstWrite() }
        let controller = DisplayBrightnessController(
            displayProvider: StaticDisplayProvider(display: display),
            isBuiltInDisplayEligible: { _ in true },
            backendBuilder: StaticBrightnessBackendBuilder(backend: backend),
            shortWriteDelay: 0,
            minimumWriteInterval: 0
        )
        let plugin = DisplayBrightnessPlugin(controller: controller, mouseDisplayIDProvider: { display.id })
        controller.refresh()
        await waitUntil { controller.snapshot().displays.first?.isReady == true }
        let scheduled = Task { await controller.setBuiltInBrightnessAndWait(0.7) }
        await waitUntil { backend.firstWriteStarted }
        XCTAssertEqual(controller.snapshot().displays.first?.brightness, 0.5)

        plugin.handleShortcutEvent(id: "display-brightness.increase", phase: .pressed)
        plugin.handleShortcutEvent(id: "display-brightness.increase", phase: .released)
        XCTAssertEqual(controller.snapshot().displays.first?.brightness, 0.51)
        backend.releaseFirstWrite()

        let scheduledResult = await scheduled.value
        XCTAssertEqual(scheduledResult, .succeeded)
        await waitUntil { controller.snapshot().displays.first?.isPendingWrite == false }
        XCTAssertEqual(backend.writeValues, [0.7, 0.51])
    }

    func testBuiltInWriteLeavesBusyDisplayAloneAcrossReactivation() async {
        let display = makeTestDisplay(id: 42, name: "Built-in fixture", isBuiltin: true, isMain: true)
        let backend = ScriptedBrightnessBackend(display: display, results: [], suspendsFirstWrite: true)
        defer { backend.releaseFirstWrite() }
        let provider = MutableDisplayProvider(displays: [display])
        let controller = DisplayBrightnessController(
            displayProvider: provider,
            isBuiltInDisplayEligible: { _ in true },
            backendBuilder: StaticBrightnessBackendBuilder(backend: backend),
            minimumWriteInterval: 0
        )
        controller.refresh()
        await waitUntil { controller.snapshot().displays.first?.isReady == true }
        let manual = Task { await controller.setBrightnessAndWait(0.4, for: display.id) }
        await waitUntil { backend.firstWriteStarted }

        provider.displays = []
        controller.refresh()
        provider.displays = [display]
        controller.refresh()
        guard case .failed = await controller.setBuiltInBrightnessAndWait(0.7) else {
            return XCTFail("A display with an unfinished write must stay busy after reactivation")
        }
        XCTAssertEqual(backend.writeValues, [0.4])

        backend.releaseFirstWrite()
        let manualResult = await manual.value
        XCTAssertEqual(manualResult, .succeeded)
        let scheduledResult = await controller.setBuiltInBrightnessAndWait(0.7)
        XCTAssertEqual(scheduledResult, .succeeded)
        XCTAssertEqual(backend.writeValues, [0.4, 0.7])
    }

    func testReplacementControllerWaitsForDispatchedWriteAndCleanup() async {
        let display = makeTestDisplay(id: 42, name: "Built-in fixture", isBuiltin: true, isMain: true)
        let backend = ScriptedBrightnessBackend(display: display, results: [], suspendsFirstWrite: true)
        defer { backend.releaseFirstWrite() }
        func makeBuiltInController() -> DisplayBrightnessController {
            DisplayBrightnessController(
                displayProvider: StaticDisplayProvider(display: display),
                isBuiltInDisplayEligible: { _ in true },
                backendBuilder: StaticBrightnessBackendBuilder(backend: backend),
                shortWriteDelay: 0,
                minimumWriteInterval: 0
            )
        }

        var original: DisplayBrightnessController? = makeBuiltInController()
        original?.refresh()
        await waitUntil { original?.snapshot().displays.first?.isReady == true }
        original?.setBrightness(0.4, for: display.id, phase: .ended)
        await waitUntil { backend.firstWriteStarted }
        original?.cancelOutstandingWrites()
        original = nil

        let replacement = makeBuiltInController()
        replacement.refresh()
        await waitUntil { replacement.snapshot().displays.first?.isReady == true }
        guard case .failed = await replacement.setBuiltInBrightnessAndWait(0.7) else {
            return XCTFail("A replacement controller must wait for an older hardware write")
        }
        XCTAssertEqual(backend.writeValues, [0.4])

        replacement.setBrightness(0.6, for: display.id, phase: .ended)
        backend.releaseFirstWrite()
        await waitUntil { replacement.snapshot().displays.first?.isPendingWrite == false }
        XCTAssertEqual(backend.cleanupCount, 1)
        XCTAssertEqual(backend.writeValues, [0.4, 0.6])

        let result = await replacement.setBuiltInBrightnessAndWait(0.7)
        XCTAssertEqual(result, .succeeded)
        XCTAssertEqual(backend.writeValues, [0.4, 0.6, 0.7])
    }

    func testCancelOutstandingWritesCancelsWorkflowWaitingForTheDisplay() async {
        let display = makeTestDisplay(id: 42, name: "Built-in fixture", isBuiltin: true, isMain: true)
        let backend = ScriptedBrightnessBackend(display: display, results: [], suspendsFirstWrite: true)
        defer { backend.releaseFirstWrite() }
        let controller = DisplayBrightnessController(
            displayProvider: StaticDisplayProvider(display: display),
            isBuiltInDisplayEligible: { _ in true },
            backendBuilder: StaticBrightnessBackendBuilder(backend: backend),
            minimumWriteInterval: 0
        )
        controller.refresh()
        await waitUntil { controller.snapshot().displays.first?.isReady == true }
        let manual = Task { await controller.setBrightnessAndWait(0.4, for: display.id) }
        await waitUntil { backend.firstWriteStarted }
        var started = false
        let scheduled = Task {
            started = true
            return await controller.setBuiltInBrightnessAndWait(0.7)
        }
        await waitUntil { started }
        controller.cancelOutstandingWrites()
        controller.refresh()
        backend.releaseFirstWrite()

        guard case .failed = await scheduled.value else {
            return XCTFail("Cancelling outstanding work must invalidate the earlier workflow")
        }
        let manualResult = await manual.value
        XCTAssertEqual(manualResult, .succeeded)
        XCTAssertEqual(backend.writeValues, [0.4])
    }

    func testMismatchMessageRoundsTheReadbackTheSameWayAsVerification() {
        let localization = DisplayBrightnessLocalization.fallback
        let message = DisplayBrightnessControllerError.nativeBrightnessReadbackMismatch(requested: 0.12, observed: 0.125)
            .localizedDescription(localization: localization)
        XCTAssertEqual(message, localization.format(
            "voice.mismatch", defaultValue: "请求 %.0f%%，硬件读回 %.0f%%。", 12.0, 13.0
        ))
    }

    func testShadeObservationKeepsPresentationOnMainAndSkipsInFlightWrites() async {
        let display = makeTestDisplay(id: 42, name: "Shade Display")
        let backend = ScriptedBrightnessBackend(display: display, results: [.success(())],
            suspendsFirstWrite: true, kind: .shade)
        let controller = makeController(display: display, backend: backend)
        controller.refresh()
        let initial = await controller.observeBrightness(for: display.id)
        XCTAssertEqual(initial?.value, 1)
        XCTAssertTrue(backend.readWasOnMainThread, "Shade reads refresh overlays and must retain main-actor ordering")
        let write = Task { await controller.setBrightnessAndWait(0.4, for: display.id) }
        await waitUntil { backend.firstWriteStarted }
        let readsBeforeObservation = backend.readCount
        let pending = await controller.observeBrightness(for: display.id)
        XCTAssertNil(pending?.value)
        XCTAssertEqual(pending?.isPendingWrite, true)
        XCTAssertEqual(backend.readCount, readsBeforeObservation, "A voice query must not enqueue stale Shade presentation during a write")
        backend.releaseFirstWrite()
        let result = await write.value
        XCTAssertEqual(result, .succeeded)
        let current = await controller.observeBrightness(for: display.id)
        XCTAssertEqual(current?.value, 0.4)
        XCTAssertTrue(backend.readWasOnMainThread)
    }

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

    func testVoiceObservationStartingDuringWriteRemainsUnverifiedAfterWriteCompletes() async {
        let display = makeTestDisplay(id: 35, name: "External Display")
        let backend = ScriptedBrightnessBackend(display: display, results: [.success(())], suspendsFirstWrite: true)
        let controller = makeController(display: display, backend: backend)
        controller.refresh()
        await waitUntil { controller.snapshot().displays.first?.isReady == true }
        let write = Task { await controller.setBrightnessAndWait(0.8, for: display.id) }
        await waitUntil { backend.firstWriteStarted }
        backend.suspendNextRead()
        defer { backend.releaseRead(); backend.releaseFirstWrite(); controller.cancelOutstandingWrites() }
        let read = Task { await controller.observeBrightness(for: display.id) }
        await waitUntil { backend.readStarted }
        backend.releaseFirstWrite()
        let writeResult = await write.value
        XCTAssertEqual(writeResult, .succeeded)
        backend.releaseRead()
        let observation = await read.value
        XCTAssertFalse(observation?.isHardwareReadback == true, "A read overlapping a write must remain unverified even after the write completes")
    }

    func testVoiceObservationCrossingWriteIsNotVerified() async {
        let display = makeTestDisplay(id: 34, name: "External Display")
        let backend = BlockingReadBrightnessBackend(display: display)
        let controller = makeController(display: display, backend: backend)
        controller.refresh()
        await waitUntil { controller.snapshot().displays.first?.isReady == true }
        backend.suspendNextRead()
        defer { backend.releaseRead(); controller.cancelOutstandingWrites() }
        let read = Task { await controller.observeBrightness(for: display.id) }
        await waitUntil { backend.readStarted }
        let write = await controller.setBrightnessAndWait(0.8, for: display.id)
        XCTAssertEqual(write, .succeeded)
        backend.releaseRead()
        let observation = await read.value
        XCTAssertNil(observation)
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

    func testBuiltInDeadlinePreventsAnUnstartedSetterAndPreservesVerificationAfterStart() async {
        let display = makeTestDisplay(id: 42, name: "Built-in fixture", isBuiltin: true, isMain: true)
        for expiresBeforeSetter in [true, false] {
            let backend = ScriptedBrightnessBackend(
                display: display, results: [], suspendsFirstWrite: !expiresBeforeSetter
            )
            defer {
                backend.releaseFirstWrite()
                backend.releaseRead()
            }
            let controller = DisplayBrightnessController(
                displayProvider: StaticDisplayProvider(display: display),
                isBuiltInDisplayEligible: { _ in true },
                backendBuilder: StaticBrightnessBackendBuilder(backend: backend),
                minimumWriteInterval: 0,
                writeTimeout: .milliseconds(150)
            )
            controller.refresh()
            await waitUntil { controller.snapshot().displays.first?.isReady == true }
            if expiresBeforeSetter { backend.suspendNextRead() }
            let write = Task { await controller.setBuiltInBrightnessAndWait(0.7) }
            await waitUntil { expiresBeforeSetter ? backend.readStarted : backend.firstWriteStarted }
            try? await Task.sleep(for: .milliseconds(250))

            if expiresBeforeSetter {
                backend.releaseRead()
                guard case .failed = await write.value else {
                    return XCTFail("The expired request must fail before writing")
                }
                XCTAssertTrue(backend.writeValues.isEmpty)
            } else {
                backend.releaseFirstWrite()
                let result = await write.value
                XCTAssertEqual(result, .succeeded)
                XCTAssertEqual(backend.writeValues, [0.7])
                XCTAssertEqual(controller.snapshot().displays.first?.brightness, 0.7)
            }
        }
    }

    func testNativeBridgeRejectsMalformedReadings() throws {
        let bridge = DisplayServicesBrightnessBridge(
            getBrightness: { displayID, value in
                if displayID == 7 { return 0 }
                let samples: [Float] = [.nan, -.infinity, .infinity, -0.1, 1.1, 0, 1]
                value.pointee = samples[Int(displayID)]
                return 0
            },
            setBrightness: nil
        )
        for displayID: CGDirectDisplayID in 0..<5 {
            XCTAssertThrowsError(try bridge.readBrightness(displayID: displayID))
        }
        XCTAssertEqual(try bridge.readBrightness(displayID: 5), 0)
        XCTAssertEqual(try bridge.readBrightness(displayID: 6), 1)
        XCTAssertThrowsError(try bridge.readBrightness(displayID: 7))
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
    private let readGate = DispatchSemaphore(value: 0)
    private var suspendRead = false
    private var startedRead = false
    private var brightness = 1.0
    private var results: [Result<Void, Error>]
    private let suspendsFirstWrite: Bool
    private let readbackAfterWrite: Double?
    private var didStartFirstWrite = false
    private var writes: [Double] = []
    private var cleanups = 0
    private var reads = 0
    private var readFailuresRemaining = 0
    private var restoreShouldFail = false
    private var lastReadOnMainThread = false

    init(
        display: DisplayInfo,
        results: [Result<Void, Error>],
        suspendsFirstWrite: Bool,
        kind: DisplayBrightnessBackendKind = .appleNative,
        readbackAfterWrite: Double? = nil
    ) {
        self.kind = kind
        self.display = display
        self.results = results
        self.suspendsFirstWrite = suspendsFirstWrite
        self.readbackAfterWrite = readbackAfterWrite
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

    var readStarted: Bool { lock.withLock { startedRead } }
    var readCount: Int { lock.withLock { reads } }
    var readWasOnMainThread: Bool { lock.withLock { lastReadOnMainThread } }
    func seedBrightness(_ value: Double) { lock.withLock { brightness = value } }
    func failNextReads(_ count: Int) { lock.withLock { readFailuresRemaining = count } }
    func failNextRestore() { lock.withLock { restoreShouldFail = true } }
    func suspendNextRead() { lock.withLock { suspendRead = true; startedRead = false } }
    func releaseRead() { readGate.signal() }
    func readBrightness() throws -> Double {
        let snapshot = try lock.withLock { () throws -> (Double, Bool) in
            reads += 1; lastReadOnMainThread = Thread.isMainThread
            if readFailuresRemaining > 0 {
                readFailuresRemaining -= 1
                throw DisplayBrightnessControllerError.genericBrightnessUnavailable
            }
            let suspend = suspendRead
            suspendRead = false; startedRead = true
            return (brightness, suspend)
        }
        if snapshot.1 { readGate.wait() }
        return snapshot.0
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
        brightness = readbackAfterWrite ?? value
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

    func restoreForNativeHandoff() throws {
        let shouldFail = lock.withLock {
            defer { restoreShouldFail = false }
            return restoreShouldFail
        }
        if shouldFail { throw TestWriteError.failed }
        cleanup()
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
