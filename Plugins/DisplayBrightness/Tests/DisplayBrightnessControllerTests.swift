import AppKit
import CoreGraphics
import XCTest
import os
import MacToolsPluginKit
@testable import DisplayBrightnessPlugin

@MainActor
final class DisplayBrightnessControllerTests: XCTestCase {
    func testQueuedExactBrightnessDoesNotTransferToReplacementAtSameID() async throws {
        let oldDisplay = makeTestDisplay(id: 21, name: "Monitor", vendorNumber: 1, modelNumber: 2, serialNumber: 3)
        let replacement = makeTestDisplay(id: 21, name: "Monitor", vendorNumber: 1, modelNumber: 2, serialNumber: 3)
        let identity = OSAllocatedUnfairLock(initialState: "monitor-a")
        let oldBackend = ScriptedBrightnessBackend(
            display: oldDisplay, results: [.success(())], suspendsFirstWrite: true, kind: .ddc
        )
        let replacementTransport = ScalingDDCBrightnessTransport(maximum: 100, hasVerifiedDisplayBinding: false)
        let newBackend = try XCTUnwrap(DDCBrightnessBackend(display: replacement, transport: replacementTransport))
        let controller = DisplayBrightnessController(
            displayProvider: StaticDisplayProvider(display: oldDisplay),
            displayIdentifier: { _ in identity.withLock { $0 } },
            backendBuilder: SystemDisplayBrightnessBackendBuilder(
                resolveArm64Services: { _ in [:] },
                ddcFactory: { _, _ in
                    if identity.withLock({ $0 == "monitor-a" }) { return oldBackend }
                    return newBackend
                }
            ),
            shortWriteDelay: 0,
            minimumWriteInterval: 0
        )
        controller.refresh()
        let first = Task { await controller.setExactBrightnessAndWait(0.2, for: oldDisplay.id, identifier: "monitor-a") }
        await waitUntil { oldBackend.firstWriteStarted }
        let queued = Task { await controller.setExactBrightnessAndWait(0.7, for: oldDisplay.id, identifier: "monitor-a") }
        await waitUntil { controller.snapshot().displays.first?.brightness == 0.7 }

        identity.withLock { $0 = "monitor-b" }
        controller.refresh()
        XCTAssertEqual(controller.snapshot().displays.first?.canAdjustRelative, false)
        oldBackend.releaseFirstWrite()
        guard case .failed = await queued.value, case .failed = await first.value else {
            return XCTFail("The old target's writes must be retired")
        }
        XCTAssertEqual(controller.actionIdentifier(for: replacement.id), "monitor-b")
        XCTAssertTrue(replacementTransport.writeValues.isEmpty)
        let stale = await controller.setExactBrightnessAndWait(0.7, for: replacement.id, identifier: "monitor-a")
        guard case .failed = stale else { return XCTFail("A stale saved identity must fail") }
        XCTAssertTrue(replacementTransport.writeValues.isEmpty)
        await waitUntil { controller.snapshot().displays.first?.canAdjustRelative == true }
        let adjustment = await controller.adjustBrightnessAndWait(by: -0.01, for: replacement.id)
        XCTAssertEqual(adjustment, .succeeded)
        XCTAssertEqual(replacementTransport.writeValues, [49])
    }

    func testExactBrightnessReadbackPrecedesNextWriteAndReconcilesMismatch() async {
        let display = makeTestDisplay(id: 22, name: "Fixture")
        let backend = ReadbackBrightnessBackend(display: display)
        let controller = DisplayBrightnessController(
            displayProvider: StaticDisplayProvider(display: display),
            displayIdentifier: { _ in "fixture" },
            backendBuilder: StaticBrightnessBackendBuilder(backend: backend),
            shortWriteDelay: 0,
            minimumWriteInterval: 0
        )
        controller.refresh()
        await waitUntil { controller.snapshot().displays.first?.isReady == true }
        let first = Task { await controller.setExactBrightnessAndWait(0.7, for: display.id, identifier: "fixture") }
        await waitUntil { backend.verificationStarted }
        let second = Task { await controller.setExactBrightnessAndWait(0.4, for: display.id, identifier: "fixture") }
        await waitUntil { controller.snapshot().displays.first?.brightness == 0.4 }
        XCTAssertEqual(backend.writeValues, [0.7], "A pending write must wait for the active write's verification")
        backend.releaseVerification()
        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertEqual(firstResult, .succeeded)
        XCTAssertEqual(secondResult, .succeeded)

        backend.ignoreNextWrite()
        let mismatch = await controller.setExactBrightnessAndWait(0.8, for: display.id, identifier: "fixture")
        guard case .failed = mismatch else { return XCTFail("A verified mismatch must fail") }
        XCTAssertEqual(controller.snapshot().displays.first?.brightness, 0.4)
    }

    func testRelativeBrightnessWaitsForAnIndependentVerifiedBaseline() async throws {
        let display = makeTestDisplay(id: 22, name: "Fixture")
        let backend = ReadbackBrightnessBackend(display: display)
        let controller = DisplayBrightnessController(
            displayProvider: StaticDisplayProvider(display: display),
            displayIdentifier: { _ in "fixture" },
            backendBuilder: StaticBrightnessBackendBuilder(backend: backend),
            shortWriteDelay: 0,
            minimumWriteInterval: 0
        )
        controller.refresh()
        await waitUntil { controller.snapshot().displays.first?.isReady == true }
        backend.ignoreNextWrite()
        let exact = Task { await controller.setExactBrightnessAndWait(0.7, for: display.id, identifier: "fixture") }
        await waitUntil { backend.verificationStarted }
        let cancelled = Task { await controller.setBrightnessAndWait(0.4, for: display.id) }
        await waitUntil { controller.snapshot().displays.first?.brightness == 0.4 }
        cancelled.cancel()
        guard case .failed = await cancelled.value else {
            return XCTFail("The cancelled absolute write must leave the active exact write as the pending baseline")
        }
        XCTAssertEqual(controller.snapshot().displays.first?.brightness, 0.7)
        let relative = await controller.adjustBrightnessAndWait(by: 0.01, for: display.id)
        backend.releaseVerification()

        guard case .failed = await exact.value, case .failed = relative else {
            return XCTFail("A relative write cannot use an unverified exact target as its baseline")
        }
        XCTAssertEqual(controller.snapshot().displays.first?.brightness, 0.2)
        XCTAssertEqual(backend.writeValues, [0.7])
        let adjustment = await controller.adjustBrightnessAndWait(by: 0.01, for: display.id)
        XCTAssertEqual(adjustment, .succeeded)
        XCTAssertEqual(try XCTUnwrap(backend.writeValues.last), 0.21, accuracy: 0.000_001)
    }

    func testMatchingBrightnessReadbackCannotCrossAReusedDisplayID() async {
        let display = makeTestDisplay(id: 22, name: "Fixture")
        let backend = ReadbackBrightnessBackend(display: display)
        let identity = OSAllocatedUnfairLock(initialState: "monitor-a")
        let controller = DisplayBrightnessController(
            displayProvider: StaticDisplayProvider(display: display),
            displayIdentifier: { _ in identity.withLock { $0 } },
            backendBuilder: StaticBrightnessBackendBuilder(backend: backend),
            shortWriteDelay: 0,
            minimumWriteInterval: 0
        )
        controller.refresh()
        await waitUntil { controller.snapshot().displays.first?.isReady == true }
        let exact = Task { await controller.setExactBrightnessAndWait(0.7, for: display.id, identifier: "monitor-a") }
        await waitUntil { backend.verificationStarted }

        let relative = await controller.adjustBrightnessAndWait(by: 0.01, for: display.id)
        identity.withLock { $0 = "monitor-b" }
        backend.releaseVerification()
        guard case .failed = await exact.value, case .failed = relative else {
            return XCTFail("Matching readback cannot authorize work on a replacement target")
        }
        XCTAssertEqual(backend.writeValues, [0.7])
        XCTAssertEqual(controller.actionIdentifier(for: display.id), "monitor-b")
    }

    func testNativeExactBrightnessRejectsAdjacentPercentage() async {
        let display = makeTestDisplay(id: 22, name: "Fixture")
        let backend = ReadbackBrightnessBackend(display: display, brightness: Double(Float(0.21)))
        let controller = DisplayBrightnessController(
            displayProvider: StaticDisplayProvider(display: display),
            displayIdentifier: { _ in "fixture" },
            backendBuilder: StaticBrightnessBackendBuilder(backend: backend),
            shortWriteDelay: 0,
            minimumWriteInterval: 0
        )
        controller.refresh()
        await waitUntil { controller.snapshot().displays.first?.isReady == true }
        backend.ignoreNextWrite()
        guard case .failed = await controller.setExactBrightnessAndWait(0.2, for: display.id, identifier: "fixture") else {
            return XCTFail("An unchanged 21% reading cannot verify a 20% request")
        }
        XCTAssertEqual(controller.snapshot().displays.first?.brightness, Double(Float(0.21)))
    }

    func testNativeExactBrightnessRejectsOutOfRangeReadbackAtEndpoints() async {
        let samples: [(Double, DisplayServicesBrightnessBridge.GetBrightnessFunction)] = [
            (0, { _, reading in
                reading.pointee = -0.2
                return 0
            }),
            (1, { _, reading in
                reading.pointee = 1.2
                return 0
            }),
        ]
        for (target, getter) in samples {
            let display = makeTestDisplay(id: 22, name: "Fixture")
            let bridge = DisplayServicesBrightnessBridge(getBrightness: getter, setBrightness: { _, _ in 0 })
            let backend = AppleNativeBrightnessBackend(display: display, bridge: bridge)
            let controller = DisplayBrightnessController(
                displayProvider: StaticDisplayProvider(display: display),
                displayIdentifier: { _ in "fixture" },
                backendBuilder: StaticBrightnessBackendBuilder(backend: backend),
                shortWriteDelay: 0,
                minimumWriteInterval: 0
            )
            controller.refresh()
            await waitUntil { controller.snapshot().displays.first?.isReady == true }
            XCTAssertEqual(controller.snapshot().displays.first?.brightness, target)

            let exact = await controller.setExactBrightnessAndWait(target, for: display.id, identifier: "fixture")
            guard case .failed = exact else { return XCTFail("An invalid reading cannot verify an endpoint") }
            XCTAssertEqual(controller.snapshot().displays.first?.isReady, false)
        }
    }

    func testExactBrightnessFallsBackWhenNativeSetterIsMissing() async {
        let display = makeTestDisplay(id: 22, name: "Fixture", vendorNumber: 0x610)
        let bridge = DisplayServicesBrightnessBridge(
            getBrightness: { _, value in
                value.pointee = 0.5
                return 0
            },
            setBrightness: nil
        )
        let native = AppleNativeBrightnessBackend(display: display, bridge: bridge)
        let fallback = ScriptedBrightnessBackend(display: display, results: [], suspendsFirstWrite: false, kind: .gamma)
        let controller = DisplayBrightnessController(
            displayProvider: StaticDisplayProvider(display: display),
            displayIdentifier: { _ in "fixture" },
            backendBuilder: SystemDisplayBrightnessBackendBuilder(
                resolveArm64Services: { _ in [:] },
                appleFactory: { _ in native },
                ddcFactory: { _, _ in nil },
                gammaFactory: { _ in fallback }
            ),
            shortWriteDelay: 0,
            minimumWriteInterval: 0
        )
        controller.refresh()
        await waitUntil { controller.snapshot().displays.first?.brightness == 0.5 }
        let result = await controller.setExactBrightnessAndWait(0.2, for: display.id, identifier: "fixture")
        XCTAssertEqual(result, .succeeded)
        XCTAssertEqual(fallback.writeValues, [0.2])
    }

    func testNativeSetterFailureRecordsAnAttempt() {
        let display = makeTestDisplay(id: 22, name: "Fixture")
        let bridge = DisplayServicesBrightnessBridge(getBrightness: nil, setBrightness: { _, _ in 1 })
        let native = AppleNativeBrightnessBackend(display: display, bridge: bridge)
        let permit = DisplayActionWritePermit { true }

        XCTAssertThrowsError(try native.writeExactBrightness(0.2, permit: permit))
        XCTAssertTrue(permit.didAttemptWrite)
    }

    func testFailedBrightnessAcknowledgmentReconcilesAppliedLevelWithoutFallback() async throws {
        let display = makeTestDisplay(id: 22, name: "Fixture")
        let transport = ScalingDDCBrightnessTransport(maximum: 100)
        let backend = try XCTUnwrap(DDCBrightnessBackend(display: display, transport: transport))
        let fallback = ScriptedBrightnessBackend(display: display, results: [], suspendsFirstWrite: false, kind: .gamma)
        let controller = DisplayBrightnessController(
            displayProvider: StaticDisplayProvider(display: display),
            displayIdentifier: { _ in "fixture" },
            backendBuilder: SystemDisplayBrightnessBackendBuilder(
                resolveArm64Services: { _ in [:] },
                ddcFactory: { _, _ in backend },
                gammaFactory: { _ in fallback }
            ),
            shortWriteDelay: 0,
            minimumWriteInterval: 0
        )
        controller.refresh()
        await waitUntil { controller.snapshot().displays.first?.isReady == true }
        transport.failNextWrite(applyBeforeFailure: true)
        guard case .failed = await controller.setExactBrightnessAndWait(0.2, for: display.id, identifier: "fixture") else {
            return XCTFail("The transport error must still be reported")
        }
        XCTAssertEqual(controller.snapshot().displays.first?.brightness, 0.2)
        XCTAssertTrue(fallback.writeValues.isEmpty)
        let adjustment = await controller.adjustBrightnessAndWait(by: 0.01, for: display.id)
        XCTAssertEqual(adjustment, .succeeded)
        XCTAssertEqual(transport.writeValues, [20, 21])
    }

    func testBrightnessVerificationSurvivesReplacementOfDiscoveredBackend() async throws {
        let display = makeTestDisplay(id: 22, name: "Fixture")
        let original = ScalingDDCBrightnessTransport(maximum: 100, usesDiscoveredService: true)
        let replacement = ScalingDDCBrightnessTransport(maximum: 100, hasVerifiedDisplayBinding: false)
        let originalBackend = try XCTUnwrap(DDCBrightnessBackend(display: display, transport: original))
        let replacementBackend = try XCTUnwrap(DDCBrightnessBackend(display: display, transport: replacement))
        var rediscovered = false
        let controller = DisplayBrightnessController(
            displayProvider: StaticDisplayProvider(display: display),
            displayIdentifier: { _ in "fixture" },
            backendBuilder: SystemDisplayBrightnessBackendBuilder(
                resolveArm64Services: { _ in [:] },
                ddcFactory: { _, _ in rediscovered ? replacementBackend : originalBackend }
            ),
            shortWriteDelay: 0,
            minimumWriteInterval: 0
        )
        controller.refresh()
        await waitUntil { controller.snapshot().displays.first?.isReady == true }
        original.failReadsAfterNextWrite(10)
        guard case .failed = await controller.setExactBrightnessAndWait(0.2, for: display.id, identifier: "fixture") else {
            return XCTFail("Failed readback must leave the level unverified")
        }

        rediscovered = true
        controller.refreshDisplayTopology()
        await controller.waitForScheduledReadsForTests()
        XCTAssertEqual(controller.snapshot().displays.first?.isReady, false)
        guard case .failed = await controller.adjustBrightnessAndWait(by: -0.01, for: display.id) else {
            return XCTFail("A valid GET on an unverified backend must not enable relative writes")
        }
        XCTAssertTrue(replacement.writeValues.isEmpty)
    }

    func testShadeExactAvailabilityAndExecutionAgreeOnMinimum() async {
        let display = makeTestDisplay(id: 24, name: "Shade fixture")
        let backend = ScriptedBrightnessBackend(display: display, results: [], suspendsFirstWrite: false, kind: .shade)
        let controller = DisplayBrightnessController(
            displayProvider: StaticDisplayProvider(display: display),
            displayIdentifier: { _ in "fixture" },
            backendBuilder: StaticBrightnessBackendBuilder(backend: backend),
            shortWriteDelay: 0,
            minimumWriteInterval: 0
        )
        controller.refresh()

        let belowMinimum = controller.exactBrightnessAvailability(0.07, for: display.id)
        XCTAssertFalse(belowMinimum.isAvailable)
        let rejected = await controller.setExactBrightnessAndWait(0.07, for: display.id, identifier: "fixture")
        guard case let .failed(message) = rejected else { return XCTFail("Shade must reject 7%") }
        XCTAssertTrue(message.contains(belowMinimum.reason ?? "missing range reason"))
        XCTAssertTrue(backend.writeValues.isEmpty)

        XCTAssertTrue(controller.exactBrightnessAvailability(0.08, for: display.id).isAvailable)
        let applied = await controller.setExactBrightnessAndWait(0.08, for: display.id, identifier: "fixture")
        XCTAssertEqual(applied, .succeeded)
        XCTAssertEqual(backend.writeValues, [0.08])
    }

    func testArm64BrightnessTransportChecksPermitBeforeEverySend() throws {
        let display = makeTestDisplay(id: 26, name: "External fixture")
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
        XCTAssertThrowsError(try transport.writeBrightness(50, permit: permit)) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(sends, 1, "Cancellation after the first send must prevent the retry")
        XCTAssertTrue(permit.didAttemptWrite)
        let cancelledBeforeSend = DisplayActionWritePermit { true }
        cancelledBeforeSend.cancel()
        XCTAssertThrowsError(try transport.writeBrightness(50, permit: cancelledBeforeSend))
        XCTAssertFalse(cancelledBeforeSend.didAttemptWrite)
        XCTAssertEqual(sends, 1)
    }

    func testTopologyChangeInvalidatesCachedDDCTransportBeforeRefresh() throws {
        let display = makeTestDisplay(id: 26, name: "External fixture")
        var sends = 0
        let cached = try XCTUnwrap(Arm64DDCTransport(
            display: display, service: "fixture" as NSString,
            sendPacket: { _, _ in
                sends += 1
                return 0
            }
        ))
        XCTAssertTrue(cached.isDiscoveryCurrent)

        DisplayDDCIdentity.invalidateBindings()
        let permit = DisplayActionWritePermit { true }
        XCTAssertThrowsError(try cached.writeBrightness(50, permit: permit)) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(permit.didAttemptWrite)
        XCTAssertEqual(sends, 0)
        let rebuilt = try XCTUnwrap(Arm64DDCTransport(
            display: display, service: "fixture" as NSString,
            sendPacket: { _, _ in
                sends += 1
                return 0
            }
        ))
        XCTAssertTrue(rebuilt.isDiscoveryCurrent)
        let topologyChangesDuringCheck = DisplayActionWritePermit {
            DisplayDDCIdentity.invalidateBindings()
            return true
        }
        XCTAssertThrowsError(try rebuilt.writeBrightness(50, permit: topologyChangesDuringCheck)) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(sends, 0, "Binding invalidation during the final identity check must block the SET")
    }

    func testBrightnessParserRejectsVolumeReply() throws {
        func reply(code: UInt8) -> [UInt8] {
            let bytes: [UInt8] = [0x6E, 0x88, 0x02, 0, code, 0, 0, 100, 0, 50]
            return bytes + [bytes.reduce(0x50, ^)]
        }
        let brightness = try IntelDDCTransport.parseReply(reply(code: 0x10), displayName: "Fixture")
        XCTAssertEqual(brightness.current, 50)
        XCTAssertThrowsError(try IntelDDCTransport.parseReply(reply(code: 0x62), displayName: "Fixture"))
    }

    func testIntelExactBrightnessSelectsOnlyACorroboratedBus() throws {
        let reading = DDCBrightnessValue(current: 10, maximum: 20)
        let verified = try IntelDDCTransport.uniqueVerifiedBus(in: 0..<2) { index in
            index == 1 ? (reading, .init(index: index, registryEntryID: 42)) : nil
        }
        XCTAssertEqual(verified.bus, .init(index: 1, registryEntryID: 42))
        XCTAssertThrowsError(try IntelDDCTransport.uniqueVerifiedBus(in: 0..<2) { index in
            (reading, .init(index: index, registryEntryID: UInt64(index) + 42))
        })
        XCTAssertThrowsError(try IntelDDCTransport.uniqueVerifiedBus(in: 0..<1) { index in
            (reading, .init(index: index, registryEntryID: nil))
        })
    }

    func testOrdinaryBrightnessReadCannotCommitAfterBindingInvalidationBeforeRefresh() async throws {
        let display = makeTestDisplay(id: 26, name: "Fixture")
        let invalidateOnRead = OSAllocatedUnfairLock(initialState: false)
        let generation = DisplayDDCIdentity.bindingGeneration
        let transport = ScalingDDCBrightnessTransport(
            maximum: 100, bindingGeneration: generation,
            didRead: {
                if invalidateOnRead.withLock({ $0 }) { DisplayDDCIdentity.invalidateBindings() }
            }
        )
        let backend = try XCTUnwrap(DDCBrightnessBackend(display: display, transport: transport))
        let controller = DisplayBrightnessController(
            displayProvider: StaticDisplayProvider(display: display),
            displayIdentifier: { _ in "fixture" },
            backendBuilder: StaticBrightnessBackendBuilder(backend: backend),
            shortWriteDelay: 0,
            minimumWriteInterval: 0
        )
        controller.refresh()
        await waitUntil { controller.snapshot().displays.first?.brightness == 0.5 }
        transport.setCurrentValue(90)
        invalidateOnRead.withLock { $0 = true }
        controller.refresh()
        await controller.waitForScheduledReadsForTests()
        XCTAssertNotEqual(DisplayDDCIdentity.bindingGeneration, generation)
        XCTAssertEqual(controller.snapshot().displays.first?.brightness, 0.5)
    }

    func testQueuedBrightnessSliderDropsInvalidatedBindingBeforeFirstSET() async throws {
        let display = makeTestDisplay(id: 26, name: "Fixture")
        let transport = ScalingDDCBrightnessTransport(maximum: 100)
        let backend = try XCTUnwrap(DDCBrightnessBackend(display: display, transport: transport))
        let controller = makeController(display: display, backend: backend)
        controller.refresh()
        await waitUntil { controller.snapshot().displays.first?.isReady == true }

        controller.setBrightness(0.4, for: display.id, phase: .changed)
        XCTAssertEqual(controller.snapshot().displays.first?.isPendingWrite, true)
        DisplayDDCIdentity.invalidateBindings()
        await waitUntil { controller.snapshot().displays.first?.isPendingWrite == false }
        XCTAssertTrue(transport.writeValues.isEmpty)
        XCTAssertEqual(controller.snapshot().displays.first?.brightness, 0.5)
    }

    func testInterruptedRelativeBrightnessRequiresAFreshLevelAfterFirstSET() async throws {
        let display = makeTestDisplay(id: 26, name: "Fixture")
        let transport = ScalingDDCBrightnessTransport(maximum: 100, didWrite: DisplayDDCIdentity.invalidateBindings)
        let backend = try XCTUnwrap(DDCBrightnessBackend(display: display, transport: transport))
        let controller = DisplayBrightnessController(
            displayProvider: StaticDisplayProvider(display: display),
            displayIdentifier: { _ in "fixture" },
            backendBuilder: StaticBrightnessBackendBuilder(backend: backend),
            shortWriteDelay: 0,
            minimumWriteInterval: 0
        )
        controller.refresh()
        await waitUntil { controller.snapshot().displays.first?.isReady == true }
        transport.failReadsAfterNextWrite(3)
        let interrupted = await controller.adjustBrightnessAndWait(by: -0.1, for: display.id)
        guard case .failed = interrupted else { return XCTFail("Expected topology to interrupt the write") }
        await controller.waitForScheduledReadsForTests()
        XCTAssertEqual(controller.snapshot().displays.first?.isReady, false)
        let stale = await controller.adjustBrightnessAndWait(by: -0.01, for: display.id)
        guard case .failed = stale else { return XCTFail("Relative adjustment requires a fresh level") }
        XCTAssertEqual(transport.writeValues, [40])
    }

    func testExactDDCBrightnessRejectsUnrepresentableLevelAndInvalidReadback() throws {
        let display = makeTestDisplay(id: 26, name: "External fixture")
        let transport = ScalingDDCBrightnessTransport(maximum: 20)
        let backend = try XCTUnwrap(DDCBrightnessBackend(display: display, transport: transport))
        let permit = DisplayActionWritePermit { true }

        XCTAssertThrowsError(try backend.writeExactBrightness(0.52, permit: permit)) { error in
            guard case DisplayBrightnessExactError.unsupportedHardwareLevel = error else {
                return XCTFail("Expected unrepresentable level to fail, got \(error)")
            }
        }
        XCTAssertFalse(permit.didAttemptWrite)
        XCTAssertTrue(transport.writeValues.isEmpty)
        XCTAssertEqual(try backend.writeExactBrightness(0.55, permit: permit), 0.55)

        transport.invalidateRangeAfterNextWrite()
        XCTAssertThrowsError(try backend.writeExactBrightness(0.5, permit: permit)) { error in
            guard case DisplayBrightnessExactError.readbackUnavailable = error else {
                return XCTFail("Expected invalid hardware readback to fail, got \(error)")
            }
        }
        XCTAssertEqual(transport.writeValues, [11, 10])
    }

    func testRejectedExactBrightnessUsesObservedBaselineForNextRelativeWrite() async throws {
        let display = makeTestDisplay(id: 26, name: "Fixture")
        let transport = ScalingDDCBrightnessTransport(maximum: 20)
        let backend = try XCTUnwrap(DDCBrightnessBackend(display: display, transport: transport))
        let controller = DisplayBrightnessController(
            displayProvider: StaticDisplayProvider(display: display),
            displayIdentifier: { _ in "fixture" },
            backendBuilder: StaticBrightnessBackendBuilder(backend: backend),
            shortWriteDelay: 0,
            minimumWriteInterval: 0
        )
        controller.refresh()
        await waitUntil { controller.snapshot().displays.first?.brightness == 0.5 }
        transport.setCurrentValue(0)

        let exact = await controller.setExactBrightnessAndWait(0.52, for: display.id, identifier: "fixture")
        guard case .failed = exact else { return XCTFail("Expected exact 52% to be unsupported") }
        XCTAssertTrue(transport.writeValues.isEmpty)
        XCTAssertEqual(controller.snapshot().displays.first?.brightness, 0)
        let decrease = await controller.adjustBrightnessAndWait(by: -0.01, for: display.id)
        XCTAssertEqual(decrease, .succeeded)
        XCTAssertEqual(transport.writeValues, [0])
    }

    func testUnverifiedExactBrightnessDoesNotExposeTheOldLevel() async throws {
        let display = makeTestDisplay(id: 26, name: "Fixture")
        let transport = ScalingDDCBrightnessTransport(maximum: 100)
        let backend = try XCTUnwrap(DDCBrightnessBackend(display: display, transport: transport))
        let controller = DisplayBrightnessController(
            displayProvider: StaticDisplayProvider(display: display),
            displayIdentifier: { _ in "fixture" },
            backendBuilder: StaticBrightnessBackendBuilder(backend: backend),
            shortWriteDelay: 0,
            minimumWriteInterval: 0
        )
        controller.refresh()
        await waitUntil { controller.snapshot().displays.first?.isReady == true }

        transport.failReadsAfterNextWrite(3)
        guard case .failed = await controller.setExactBrightnessAndWait(0.2, for: display.id, identifier: "fixture") else {
            return XCTFail("Unverified action must fail even if reconciliation succeeds")
        }
        XCTAssertEqual(controller.snapshot().displays.first?.brightness, 0.2)

        transport.failReadsAfterNextWrite(5)
        guard case .failed = await controller.setExactBrightnessAndWait(0.3, for: display.id, identifier: "fixture") else {
            return XCTFail("Unverified action must fail")
        }
        XCTAssertEqual(controller.snapshot().displays.first?.isReady, false)
        let adjustment = await controller.adjustBrightnessAndWait(by: 0.01, for: display.id)
        guard case .failed = adjustment else { return XCTFail("An unknown level must block a relative write") }
        XCTAssertEqual(transport.writeValues, [20, 30])
        let slider = await controller.setBrightnessAndWait(0.4, for: display.id)
        XCTAssertEqual(slider, .succeeded)
        XCTAssertEqual(transport.writeValues, [20, 30, 40])
    }

    func testCancelledExactBrightnessReconcilesAnInFlightWrite() async {
        let display = makeTestDisplay(id: 22, name: "Fixture")
        let backend = ScriptedBrightnessBackend(display: display, results: [.success(())], suspendsFirstWrite: true)
        let controller = DisplayBrightnessController(
            displayProvider: StaticDisplayProvider(display: display),
            displayIdentifier: { _ in "fixture" },
            backendBuilder: StaticBrightnessBackendBuilder(backend: backend),
            shortWriteDelay: 0,
            minimumWriteInterval: 0
        )
        controller.refresh()
        await waitUntil { controller.snapshot().displays.first?.isReady == true }
        let initialReadCount = backend.readCount
        let write = Task { await controller.setExactBrightnessAndWait(0.2, for: display.id, identifier: "fixture") }
        await waitUntil { backend.firstWriteStarted }
        write.cancel()
        backend.releaseFirstWrite()

        guard case .failed = await write.value else { return XCTFail("Cancelled action must fail") }
        XCTAssertGreaterThan(backend.readCount, initialReadCount)
        XCTAssertEqual(controller.snapshot().displays.first?.brightness, 0.2)
    }

    func testExactBrightnessRejectsAnUnverifiedMonitorBinding() throws {
        let display = makeTestDisplay(id: 26, name: "External fixture")
        let transport = try XCTUnwrap(Arm64DDCTransport(display: display, service: "fixture" as NSString, sendPacket: { _, _ in XCTFail("Unverified binding must not issue I/O"); return -1 }))
        let backend = try XCTUnwrap(DDCBrightnessBackend(display: display, transport: transport))
        XCTAssertThrowsError(try backend.writeExactBrightness(0.5, permit: DisplayActionWritePermit { true })) { error in
            guard case DisplayBrightnessExactError.unverifiedTarget = error else {
                return XCTFail("Expected an unverified binding error, got \(error)")
            }
        }
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

    func testRediscoveryPreservesCommittedBrightnessAndScaleWhenReadbackIsUnavailable() async throws {
        try await assertRediscoveryPreservesBrightness(initialGETWorks: true, expectedLevel: 0.4, expectedWrite: 8)
        try await assertRediscoveryPreservesBrightness(initialGETWorks: false, expectedLevel: 1, expectedWrite: 99)
    }

    func testCorroboratedBrightnessRediscoveryPreservesOrdinaryLevelWithoutSavedIdentifier() async throws {
        try await assertRediscoveryPreservesBrightness(
            initialGETWorks: true, expectedLevel: 0.4, expectedWrite: 8, identifier: nil
        )
    }

    private func assertRediscoveryPreservesBrightness(
        initialGETWorks: Bool,
        expectedLevel: Double,
        expectedWrite: UInt16,
        identifier: String? = "fixture"
    ) async throws {
        let display = makeTestDisplay(id: 35, name: "External Display")
        let maximum: UInt16 = initialGETWorks ? 20 : 100
        let original = ScalingDDCBrightnessTransport(
            failsReads: !initialGETWorks, maximum: maximum, usesDiscoveredService: true, hasVerifiedDisplayBinding: false,
            registryEntryID: 42
        )
        let replacement = ScalingDDCBrightnessTransport(
            failsReads: true, maximum: maximum, usesDiscoveredService: true, hasVerifiedDisplayBinding: false,
            registryEntryID: 42
        )
        let originalBackend = try XCTUnwrap(DDCBrightnessBackend(display: display, transport: original))
        let replacementBackend = try XCTUnwrap(DDCBrightnessBackend(display: display, transport: replacement))
        var rediscovered = false
        let controller = DisplayBrightnessController(
            displayProvider: StaticDisplayProvider(display: display),
            displayIdentifier: { _ in identifier },
            backendBuilder: SystemDisplayBrightnessBackendBuilder(
                resolveArm64Services: { _ in [:] },
                ddcFactory: { _, _ in rediscovered ? replacementBackend : originalBackend }
            ),
            shortWriteDelay: 0,
            minimumWriteInterval: 0
        )
        controller.refresh()
        await waitUntil { controller.snapshot().displays.first?.isReady == true }
        if initialGETWorks {
            let initialWrite = await controller.setBrightnessAndWait(0.4, for: display.id)
            XCTAssertEqual(initialWrite, .succeeded)
            XCTAssertEqual(original.writeValues, [8])
        } else {
            XCTAssertTrue(original.writeValues.isEmpty)
        }

        rediscovered = true
        controller.refreshDisplayTopology()
        await controller.waitForScheduledReadsForTests()
        XCTAssertEqual(controller.snapshot().displays.first?.brightness, expectedLevel)
        XCTAssertFalse(controller.exactBrightnessAvailability(0.4, for: display.id).isAvailable)
        let adjustment = await controller.adjustBrightnessAndWait(by: -0.01, for: display.id)
        XCTAssertEqual(adjustment, .succeeded)
        XCTAssertEqual(replacement.writeValues, [expectedWrite])
    }

    func testDetachedBrightnessFollowsKnownDisplayOnlyOnTheSameEndpoint() async throws {
        for registryID in [UInt64(42), 43] {
            let original = makeTestDisplay(id: 35, name: "External Display")
            let returning = makeTestDisplay(id: 36, name: "External Display")
            let provider = MutableDisplayProvider(displays: [original])
            let originalTransport = ScalingDDCBrightnessTransport(failsReads: true, maximum: 100, registryEntryID: 42)
            let returningTransport = ScalingDDCBrightnessTransport(failsReads: true, maximum: 100, registryEntryID: registryID)
            let controller = DisplayBrightnessController(
                displayProvider: provider,
                displayIdentifier: { _ in "same-display" },
                backendBuilder: SystemDisplayBrightnessBackendBuilder(
                    resolveArm64Services: { _ in [:] },
                    ddcFactory: { display, _ in
                        DDCBrightnessBackend(display: display, transport: display.id == original.id ? originalTransport : returningTransport)
                    }
                ),
                shortWriteDelay: 0,
                minimumWriteInterval: 0
            )
            controller.refresh()
            await waitUntil { controller.snapshot().displays.first?.isReady == true }
            let initial = await controller.setBrightnessAndWait(0.4, for: original.id)
            XCTAssertEqual(initial, .succeeded)
            provider.displays = []
            controller.refreshDisplayTopology()
            XCTAssertTrue(controller.snapshot().displays.isEmpty)
            provider.displays = [returning]
            controller.refreshDisplayTopology()
            await controller.waitForScheduledReadsForTests()

            let adjustment = await controller.adjustBrightnessAndWait(by: -0.01, for: returning.id)
            if registryID == 42 {
                XCTAssertEqual(adjustment, .succeeded)
                XCTAssertEqual(returningTransport.writeValues, [39])
            } else {
                guard case .failed = adjustment else { return XCTFail("Changed endpoint requires a known level") }
                XCTAssertTrue(returningTransport.writeValues.isEmpty)
                let explicit = await controller.setBrightnessAndWait(0.3, for: returning.id)
                XCTAssertEqual(explicit, .succeeded)
                XCTAssertEqual(returningTransport.writeValues, [30])
            }
        }
    }

    func testIdleHeuristicRediscoveryRequiresAFreshLevelWithoutExactBinding() async throws {
        let display = makeTestDisplay(id: 35, name: "External Display")
        let original = ScalingDDCBrightnessTransport(
            maximum: 100, usesDiscoveredService: true, hasVerifiedDisplayBinding: false
        )
        let replacement = ScalingDDCBrightnessTransport(
            failsReads: true, maximum: 100, usesDiscoveredService: true, hasVerifiedDisplayBinding: false
        )
        let originalBackend = try XCTUnwrap(DDCBrightnessBackend(display: display, transport: original))
        let replacementBackend = try XCTUnwrap(DDCBrightnessBackend(display: display, transport: replacement))
        var rediscovered = false
        let controller = DisplayBrightnessController(
            displayProvider: StaticDisplayProvider(display: display),
            displayIdentifier: { _ in "fixture" },
            backendBuilder: SystemDisplayBrightnessBackendBuilder(
                resolveArm64Services: { _ in [:] },
                ddcFactory: { _, _ in rediscovered ? replacementBackend : originalBackend },
                gammaFactory: { _ in nil },
                shadeFactory: { _ in nil }
            ),
            shortWriteDelay: 0,
            minimumWriteInterval: 0
        )
        controller.refresh()
        await waitUntil { controller.snapshot().displays.first?.isReady == true }
        rediscovered = true
        controller.refreshDisplayTopology()
        await controller.waitForScheduledReadsForTests()
        XCTAssertEqual(controller.snapshot().displays.first?.isReady, false)
        XCTAssertTrue(replacement.writeValues.isEmpty)

        replacement.allowReads()
        controller.refresh()
        await waitUntil { controller.snapshot().displays.first?.isReady == true }
        XCTAssertFalse(controller.exactBrightnessAvailability(0.4, for: display.id).isAvailable)
        let adjustment = await controller.adjustBrightnessAndWait(by: -0.01, for: display.id)
        XCTAssertEqual(adjustment, .succeeded)
        XCTAssertEqual(replacement.writeValues, [49])
    }

    func testChangedWriteOnlyDDCEndpointResumesRelativeWritesAfterExplicitSet() async throws {
        try await assertChangedWriteOnlyDDCEndpoint(initialID: "fixture", replacementID: "fixture", registryID: 43)
    }

    func testIdleWriteOnlyReplacementCannotInheritBrightnessAtReusedID() async throws {
        try await assertChangedWriteOnlyDDCEndpoint(initialID: "old", replacementID: "new", registryID: 42)
    }

    func testUncorroboratedWriteOnlyBrightnessRediscoveryWithoutSavedIdentifierNeedsLevel() async throws {
        try await assertChangedWriteOnlyDDCEndpoint(initialID: nil, replacementID: nil, registryID: 43)
    }

    private func assertChangedWriteOnlyDDCEndpoint(initialID: String?, replacementID: String?, registryID: UInt64) async throws {
        let display = makeTestDisplay(id: 35, name: "External Display")
        let original = ScalingDDCBrightnessTransport(
            failsReads: true, maximum: 100,
            registryEntryID: 42
        )
        let replacement = ScalingDDCBrightnessTransport(
            failsReads: true, maximum: 100,
            registryEntryID: registryID
        )
        let originalBackend = try XCTUnwrap(DDCBrightnessBackend(display: display, transport: original))
        let replacementBackend = try XCTUnwrap(DDCBrightnessBackend(display: display, transport: replacement))
        let fallback = ScriptedBrightnessBackend(display: display, results: [], suspendsFirstWrite: false, kind: .gamma)
        var rediscovered = false
        let identifier = OSAllocatedUnfairLock(initialState: initialID)
        let controller = DisplayBrightnessController(
            displayProvider: StaticDisplayProvider(display: display),
            displayIdentifier: { _ in identifier.withLock { $0 } },
            backendBuilder: SystemDisplayBrightnessBackendBuilder(
                resolveArm64Services: { _ in [:] },
                ddcFactory: { _, _ in rediscovered ? replacementBackend : originalBackend },
                gammaFactory: { _ in fallback },
                shadeFactory: { _ in nil }
            ),
            shortWriteDelay: 0,
            minimumWriteInterval: 0
        )
        controller.refresh()
        await waitUntil { controller.snapshot().displays.first?.isReady == true }
        let initialWrite = await controller.setBrightnessAndWait(0.4, for: display.id)
        XCTAssertEqual(initialWrite, .succeeded)
        XCTAssertEqual(original.writeValues, [40])

        rediscovered = true
        identifier.withLock { $0 = replacementID }
        controller.refreshDisplayTopology()
        await controller.waitForScheduledReadsForTests()
        XCTAssertEqual(controller.snapshot().displays.first?.isReady, false)
        let unknownLevelAdjustment = await controller.adjustBrightnessAndWait(by: -0.01, for: display.id)
        guard case .failed = unknownLevelAdjustment else { return XCTFail("A relative write requires a known level") }
        XCTAssertTrue(replacement.writeValues.isEmpty)

        let absoluteWrite = await controller.setBrightnessAndWait(0.6, for: display.id)
        XCTAssertEqual(absoluteWrite, .succeeded)
        XCTAssertEqual(controller.snapshot().displays.first?.isReady, true)
        let adjustment = await controller.adjustBrightnessAndWait(by: -0.01, for: display.id)
        XCTAssertEqual(adjustment, .succeeded)
        XCTAssertEqual(replacement.writeValues, [60, 59])
        XCTAssertTrue(fallback.writeValues.isEmpty)
    }

    func testRetiredSliderWriteLetsHeuristicBrightnessResumeAfterFreshRead() async throws {
        let display = makeTestDisplay(id: 35, name: "External Display")
        let started = OSAllocatedUnfairLock(initialState: false)
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let original = ScalingDDCBrightnessTransport(
            maximum: 100, usesDiscoveredService: true, hasVerifiedDisplayBinding: false,
            beforeWrite: {
                started.withLock { $0 = true }
                _ = gate.wait(timeout: .now() + 5)
            }
        )
        let replacement = ScalingDDCBrightnessTransport(
            maximum: 100, usesDiscoveredService: true, hasVerifiedDisplayBinding: false
        )
        let originalBackend = try XCTUnwrap(DDCBrightnessBackend(display: display, transport: original))
        let replacementBackend = try XCTUnwrap(DDCBrightnessBackend(display: display, transport: replacement))
        var rediscovered = false
        let controller = DisplayBrightnessController(
            displayProvider: StaticDisplayProvider(display: display),
            displayIdentifier: { _ in "fixture" },
            backendBuilder: SystemDisplayBrightnessBackendBuilder(
                resolveArm64Services: { _ in [:] },
                ddcFactory: { _, _ in rediscovered ? replacementBackend : originalBackend }
            ),
            shortWriteDelay: 0,
            minimumWriteInterval: 0
        )
        controller.refresh()
        await waitUntil { controller.snapshot().displays.first?.isReady == true }
        let slider = Task { await controller.setBrightnessAndWait(0.7, for: display.id) }
        await waitUntil { started.withLock { $0 } }

        rediscovered = true
        controller.refreshDisplayTopology()
        XCTAssertEqual(controller.snapshot().displays.first?.isReady, false)
        gate.signal()
        let sliderResult = await slider.value
        XCTAssertEqual(sliderResult, .succeeded)
        await waitUntil { controller.snapshot().displays.first?.isReady == true }
        let adjustment = await controller.adjustBrightnessAndWait(by: -0.01, for: display.id)
        XCTAssertEqual(adjustment, .succeeded)
        XCTAssertEqual(original.writeValues, [70])
        XCTAssertEqual(replacement.writeValues, [49])
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
            displayProvider: StaticDisplayProvider(display: display), displayIdentifier: { _ in "fixture" }, backendBuilder: builder,
            shortWriteDelay: 0, minimumWriteInterval: 0
        )
        controller.refresh()
        await waitUntil { controller.snapshot().displays.first?.isReady == true }
        XCTAssertEqual(controller.snapshot().displays.first?.brightness, 1)
        let firstResult = await controller.setBrightnessAndWait(0.75, for: display.id)
        XCTAssertEqual(firstResult, .succeeded)
        XCTAssertEqual(transport.writeValues, [75])
        XCTAssertTrue(software.writeValues.isEmpty)

        let exact = await controller.setExactBrightnessAndWait(0.5, for: display.id, identifier: "fixture")
        guard case .failed = exact else { return XCTFail("Exact brightness requires a known hardware range") }
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

    func testTopologyRefreshReplacesBlockedReadOnRetainedNativeBackend() async throws {
        let display = makeTestDisplay(id: 31, name: "Native Display")
        let backend = BlockingReadBrightnessBackend(display: display, kind: .appleNative)
        backend.suspendNextRead()
        defer { backend.releaseRead() }
        let controller = makeController(display: display, backend: backend)

        controller.refresh()
        await waitUntil { backend.readStarted }
        XCTAssertEqual(controller.snapshot().displays.first?.isReady, false)

        DisplayDDCIdentity.invalidateBindings()
        try backend.writeBrightness(0.8)
        controller.refreshDisplayTopology()
        backend.releaseRead()

        await waitUntil { controller.snapshot().displays.first?.isReady == true }
        XCTAssertEqual(controller.snapshot().displays.first?.brightness, 0.8)
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
        XCTAssertEqual(controller.snapshot().displays.first?.isReady, false)
        retiredBackend.releaseFirstWrite()

        guard case .failed = await resultTask.value else {
            return XCTFail("Expected the retired backend's real failure")
        }
        await waitUntil { retiredBackend.cleanupCount == 1 && controller.snapshot().displays.first?.isReady == true }
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
    private var didStartFirstWrite = false
    private var writes: [Double] = []
    private var cleanups = 0
    private var reads = 0
    private var lastReadOnMainThread = false

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

    var readStarted: Bool { lock.withLock { startedRead } }
    var readCount: Int { lock.withLock { reads } }
    var readWasOnMainThread: Bool { lock.withLock { lastReadOnMainThread } }
    func suspendNextRead() { lock.withLock { suspendRead = true; startedRead = false } }
    func releaseRead() { readGate.signal() }
    func readBrightness() throws -> Double {
        let snapshot = lock.withLock { () -> (Double, Bool) in
            let suspend = suspendRead
            suspendRead = false; startedRead = true
            reads += 1; lastReadOnMainThread = Thread.isMainThread
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
    let kind: DisplayBrightnessBackendKind
    var display: DisplayInfo
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var brightness = 0.5
    private var suspendRead = false
    private var started = false
    private var wasOnMainThread = false

    init(display: DisplayInfo, kind: DisplayBrightnessBackendKind = .ddc) {
        self.display = display
        self.kind = kind
    }

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
    private var failsReads: Bool
    private var current: UInt16
    private var maximum: UInt16
    private var shouldInvalidateRange = false
    private var nextReadFailures = 0
    private var readFailures = 0

    func failReadsAfterNextWrite(_ count: Int) { lock.withLock { nextReadFailures = count } }
    private var writes: [UInt16] = []
    private var shouldFailNextWrite = false
    private var applyBeforeFailure = false
    let usesDiscoveredService: Bool
    let hasVerifiedDisplayBinding: Bool
    let registryEntryID: UInt64?
    private let bindingGeneration: UInt64?
    private let didRead: () -> Void
    private let didWrite: () -> Void
    private let beforeWrite: () -> Void

    init(
        failsReads: Bool = false,
        maximum: UInt16 = 200,
        usesDiscoveredService: Bool = false,
        hasVerifiedDisplayBinding: Bool = true,
        registryEntryID: UInt64? = nil,
        bindingGeneration: UInt64? = nil,
        didRead: @escaping () -> Void = {},
        didWrite: @escaping () -> Void = {},
        beforeWrite: @escaping () -> Void = {}
    ) {
        self.failsReads = failsReads
        self.usesDiscoveredService = usesDiscoveredService
        self.hasVerifiedDisplayBinding = hasVerifiedDisplayBinding
        self.registryEntryID = registryEntryID
        self.bindingGeneration = bindingGeneration
        self.didRead = didRead
        self.didWrite = didWrite
        self.beforeWrite = beforeWrite
        self.maximum = maximum
        self.current = maximum / 2
    }

    func invalidateRangeAfterNextWrite() { lock.withLock { shouldInvalidateRange = true } }

    var currentValue: UInt16 { lock.withLock { current } }
    func setCurrentValue(_ value: UInt16) { lock.withLock { current = value } }
    var writeValues: [UInt16] { lock.withLock { writes } }

    func allowReads() { lock.withLock { failsReads = false } }

    var isDiscoveryCurrent: Bool { bindingGeneration.map { $0 == DisplayDDCIdentity.bindingGeneration } ?? true }

    func readBrightness() throws -> DDCBrightnessValue {
        let observation = try lock.withLock {
            if failsReads { throw DisplayBrightnessControllerError.genericBrightnessUnavailable }
            if readFailures > 0 {
                readFailures -= 1
                throw DisplayBrightnessControllerError.genericBrightnessUnavailable
            }
            return DDCBrightnessValue(current: current, maximum: maximum)
        }
        didRead()
        return observation
    }

    func failNextWrite(applyBeforeFailure: Bool = false) {
        lock.withLock {
            shouldFailNextWrite = true
            self.applyBeforeFailure = applyBeforeFailure
        }
    }

    func writeBrightness(_ value: UInt16) throws {
        beforeWrite()
        try lock.withLock {
            writes.append(value)
            if shouldFailNextWrite {
                shouldFailNextWrite = false
                if applyBeforeFailure { current = value }
                throw TestWriteError.failed
            }
            current = value
            if shouldInvalidateRange { maximum = 0 }
            readFailures = nextReadFailures
            nextReadFailures = 0
        }
        didWrite()
    }
}


private final class ReadbackBrightnessBackend: DisplayBrightnessBackend, @unchecked Sendable {
    let kind: DisplayBrightnessBackendKind = .appleNative
    var display: DisplayInfo
    private let lock = NSLock()
    private let verificationGate = DispatchSemaphore(value: 0)
    private var values: [Double] = []
    private var brightness: Double
    private var shouldIgnoreWrite = false
    private var heldFirstRead = false

    init(display: DisplayInfo, brightness: Double = 0.2) {
        self.display = display
        self.brightness = brightness
    }

    var verificationStarted: Bool { lock.withLock { heldFirstRead } }
    var writeValues: [Double] { lock.withLock { values } }

    func readBrightness() throws -> Double {
        let hold = lock.withLock {
            guard values == [0.7], !heldFirstRead else { return false }
            heldFirstRead = true
            return true
        }
        if hold, verificationGate.wait(timeout: .now() + 5) != .success {
            throw TestWriteError.failed
        }
        return lock.withLock { brightness }
    }

    func releaseVerification() { verificationGate.signal() }
    func ignoreNextWrite() { lock.withLock { shouldIgnoreWrite = true } }

    func writeBrightness(_ value: Double) throws {
        lock.withLock {
            values.append(value)
            if !shouldIgnoreWrite { brightness = value }
            shouldIgnoreWrite = false
        }
    }

    func cleanup() {}
}
