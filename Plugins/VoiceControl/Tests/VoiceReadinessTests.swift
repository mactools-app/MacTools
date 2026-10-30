import Foundation
import MacToolsPluginKit
import XCTest
@testable import VoiceControlPlugin

@MainActor
final class VoiceReadinessTests: XCTestCase {
    func testQuotaFailureStopsAudioAndRevokesControlWithoutRetry() async throws {
        let (model, factory, audio, grants) = try await makeModel()
        let socket = try await start(model, factory)
        socket.feed(["type": "error", "error": ["code": "insufficient_quota", "message": "Never display an untrusted service message"]])
        await settle { !model.active }
        XCTAssertFalse(model.active)
        XCTAssertTrue(audio.stopped)
        XCTAssertEqual(grants.ended.count, 1)
        XCTAssertEqual(factory.connections.count, 1)
        XCTAssertEqual(model.status, VoiceServiceFailure.quota.message)
        socket.feed(["type": "session.closed", "reason": "close_requested", "usage": ["seconds": 2.5]])
        await settle { model.recentSessionMetrics.last?.finalized == true }
        XCTAssertEqual(model.recentSessionMetrics.last?.voiceSeconds, 2.5)
        XCTAssertEqual(model.recentSessionMetrics.last?.finalized, true)
    }

    func testOldPendingToolCannotClearNewConversationActivity() async throws {
        let (model, factory, _, _) = try await makeModel()
        var pending: [CheckedContinuation<PluginVoiceReply, Never>] = []
        var completed = 0
        var currentTitle = ""
        model.context = .init(begin: { _ in UUID() }, end: { _ in }, request: { _, request in
            switch request {
            case .search:
                return .init(capabilities: [.init(id: "fixture", kind: .action, title: currentTitle,
                    pluginTitle: "Fixture", description: "Fixture action")])
            case .perform:
                let result = await withCheckedContinuation { pending.append($0) }
                completed += 1
                return result
            }
        })
        let old = try await start(model, factory)
        currentTitle = "Previous action"
        old.call("discover-old", name: "discover_capabilities", arguments: "{\"query\":\"fixture\"}")
        await settle { old.outputs == 1 }
        old.call("perform-old", name: "perform_capability", arguments: "{\"capabilityID\":\"fixture\",\"parameters\":[]}")
        await settle { pending.count == 1 }
        model.stop()
        let current = try await start(model, factory)
        currentTitle = "Current action"
        current.call("discover-new", name: "discover_capabilities", arguments: "{\"query\":\"fixture\"}")
        await settle { current.outputs == 1 }
        current.call("perform-new", name: "perform_capability", arguments: "{\"capabilityID\":\"fixture\",\"parameters\":[]}")
        await settle { pending.count == 2 }
        guard pending.count == 2 else { model.stop(); old.cancel(); current.cancel(); return XCTFail("Host requests did not suspend") }
        XCTAssertEqual(model.activity, "Current action")
        pending[0].resume(returning: .init(status: "sessionEnded"))
        await settle { completed == 1 }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(model.activity, "Current action")
        pending[1].resume(returning: .init())
        await settle { current.outputs == 2 }
        model.stop(); old.cancel(); current.cancel()
    }

    func testDisconnectStopsCaptureAndRequiresExplicitRestart() async throws {
        let (model, factory, audio, grants) = try await makeModel()
        let socket = try await start(model, factory)
        socket.cancel()
        await settle { !model.active }
        XCTAssertFalse(model.active)
        XCTAssertTrue(audio.stopped)
        XCTAssertEqual(grants.ended.count, 1)
        XCTAssertEqual(factory.connections.count, 1)
    }

    func testStopDrainsUsageButRejectsLateWorkWhileNewConversationRuns() async throws {
        let (model, factory, audio, grants) = try await makeModel()
        let first = try await start(model, factory)
        let firstID = model.sessionMetrics.id
        model.stop()
        _ = try await start(model, factory)
        let secondID = model.sessionMetrics.id
        first.feed(["type": "session.output_audio.delta", "delta": Data([0, 1]).base64EncodedString()])
        first.feed(["type": "response.event", "event": ["type": "response.output_item.done", "response_id": "late",
            "item": ["type": "function_call", "call_id": "late", "name": "discover_capabilities", "arguments": "{\"query\":\"brightness\"}"]]])
        first.feed(["type": "response.event", "event": ["type": "response.completed", "response": ["id": "late"]]])
        first.feed(["type": "session.closed", "reason": "close_requested", "usage": ["seconds": 1.25]])
        await settle { model.recentSessionMetrics.first(where: { $0.id == firstID })?.finalized == true }
        XCTAssertEqual(model.recentSessionMetrics.first(where: { $0.id == firstID })?.voiceSeconds, 1.25)
        XCTAssertTrue(model.active)
        XCTAssertEqual(model.sessionMetrics.id, secondID)
        XCTAssertEqual(audio.played, 0)
        XCTAssertEqual(grants.requests, 0)
        XCTAssertEqual(grants.ended.count, 1)
        model.stop()
        factory.connections.last?.cancel()
    }

    func testInactivityStopsWithoutDismissingOrAutomaticallyRestarting() async throws {
        for timeout in [VoiceIdleTimeout.thirtySeconds, .fiveMinutes] {
            let (model, factory, audio, grants) = try await makeModel()
            model.idleTimeout = timeout
            let socket = try await start(model, factory)
            model.stopIfIdle(at: .now.advanced(by: timeout.duration - .seconds(1)))
            XCTAssertTrue(model.active)
            model.stopIfIdle(at: .now.advanced(by: timeout.duration + .seconds(1)))
            XCTAssertFalse(model.active)
            XCTAssertTrue(audio.stopped)
            XCTAssertEqual(grants.ended.count, 1)
            XCTAssertEqual(factory.connections.count, 1)
            socket.cancel()
        }
    }

    func testInactivityWaitsForBackendAndSpokenPlaybackToFinish() async throws {
        let (model, factory, audio, _) = try await makeModel()
        let socket = try await start(model, factory)
        socket.feed(["type": "response.event", "event": ["type": "response.created", "response": ["id": "thinking"]]])
        socket.feed(["type": "session.usage.updated", "usage": ["seconds": 1.0]])
        await settle { model.sessionMetrics.voiceSeconds == 1 }
        model.stopIfIdle(at: .now.advanced(by: .seconds(120)))
        XCTAssertTrue(model.active, "Pending delegated work keeps its conversation")
        socket.feed(["type": "response.event", "event": ["type": "response.completed", "response": ["id": "thinking"]]])
        socket.feed(["type": "session.output_audio.delta", "delta": Data([0, 64, 0, 64]).base64EncodedString()])
        await settle { audio.played == 1 }
        model.stopIfIdle(at: .now.advanced(by: .seconds(120)))
        XCTAssertTrue(model.active, "Queued spoken audio must finish before idle closure")
        audio.finishPlayback()
        model.stopIfIdle(at: .now.advanced(by: .seconds(59)))
        XCTAssertTrue(model.active, "The idle interval starts after speech playback finishes")
        model.stopIfIdle(at: .now.advanced(by: .seconds(61)))
        XCTAssertFalse(model.active)
        socket.cancel()
    }

    func testSilentOutputIsNotSpeechAndCannotPreventInactivityStop() async throws {
        let (model, factory, audio, _) = try await makeModel()
        let socket = try await start(model, factory)
        socket.feed(["type": "session.output_audio.delta", "delta": Data(count: 4800).base64EncodedString()])
        await settle { audio.played == 1 }
        XCTAssertNotNil(model.startupTimings["firstOutputAudio"])
        XCTAssertNil(model.startupTimings["firstOutputSpeech"])
        // A queued buffer can still be draining even when it contains no speech.
        XCTAssertTrue(model.speaking)
        model.stopIfIdle(at: .now.advanced(by: .seconds(240)))
        XCTAssertFalse(model.active)
        socket.cancel()
    }

    func testUsageDeduplicatesBackendResponsesAndRequiresFinalCloseUsage() {
        var metrics = VoiceSessionMetrics(id: UUID())
        metrics.observe(["type": "session.usage.updated", "usage": ["seconds": 3.0]])
        let response: [String: Any] = ["type": "response.event", "event": ["type": "response.completed",
            "response": ["id": "response-one", "usage": ["input_tokens": 100, "output_tokens": 20, "input_tokens_details": ["cached_tokens": 40]]]]]
        metrics.observe(response); metrics.observe(response)
        XCTAssertEqual(metrics.responses.count, 1)
        XCTAssertEqual(metrics.responses["response-one"]?.cachedInput, 40)
        metrics.observe(["type": "session.closed", "reason": "close_requested"])
        XCTAssertFalse(metrics.finalized)
        XCTAssertEqual(metrics.voiceSeconds, 3)
        metrics.observe(["type": "session.closed", "reason": "close_requested", "usage": ["seconds": 3.25]])
        XCTAssertTrue(metrics.finalized)
        XCTAssertEqual(metrics.voiceSeconds, 3.25)
    }

    func testLocalSpeechConnectsOnceAndPreservesBufferedAudioInOrder() async throws {
        let detector = ReadinessSpeechDetector()
        let (model, factory, audio, _) = try await makeModel(detector: detector)
        model.start()
        await settle { model.listeningLocally }
        XCTAssertTrue(model.capturing)
        XCTAssertTrue(factory.connections.isEmpty)
        let silence = Data(repeating: 1, count: 2400)
        let onset = Data(repeating: 2, count: 2400)
        let handshake = Data(repeating: 3, count: 2400)
        audio.push(silence)
        for _ in 0..<100 where await detector.processed == 0 { await Task.yield() }
        XCTAssertTrue(factory.connections.isEmpty)
        await detector.setSpeech(true)
        audio.push(onset)
        await settle { factory.connections.count == 1 }
        let socket = try XCTUnwrap(factory.connections.first)
        audio.push(handshake)
        for _ in 0..<10 { await Task.yield() }
        socket.feed(["type": "session.started"])
        await settle { model.connected }
        XCTAssertEqual(socket.inputAudio.reduce(Data(), +), silence + onset + handshake)
        XCTAssertFalse(model.listeningLocally)
        XCTAssertEqual(factory.connections.count, 1)
        model.stop(); socket.cancel()
    }

    func testLocalIdleEndsCaptureWithoutOpeningOrAccountingForAPISession() async throws {
        let (model, factory, audio, grants) = try await makeModel(detector: ReadinessSpeechDetector())
        model.start()
        await settle { model.listeningLocally }
        model.stopIfIdle(at: .now.advanced(by: .seconds(61)))
        XCTAssertFalse(model.active)
        XCTAssertTrue(audio.stopped)
        XCTAssertEqual(grants.ended.count, 1)
        XCTAssertTrue(factory.connections.isEmpty)
        XCTAssertTrue(model.recentSessionMetrics.isEmpty)
    }

    func testStopDuringLocalPreparationCannotConnectAfterCompletion() async throws {
        let detector = ReadinessSpeechDetector(holdPreparation: true)
        let (model, factory, audio, grants) = try await makeModel(detector: detector)
        model.start()
        await settle { model.capturing }
        model.stop()
        await detector.releasePreparation()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(audio.stopped)
        XCTAssertFalse(model.active)
        XCTAssertFalse(model.listeningLocally)
        XCTAssertEqual(grants.ended.count, 1)
        XCTAssertTrue(factory.connections.isEmpty)
    }

    func testMuteInvalidatesInFlightSpeechAndRequiresFreshUnmutedInput() async throws {
        let detector = ReadinessSpeechDetector()
        await detector.holdDetection()
        let (model, factory, audio, _) = try await makeModel(detector: detector)
        model.start()
        await settle { model.listeningLocally }
        audio.push(Data(repeating: 1, count: 2400))
        for _ in 0..<100 where await detector.processed == 0 { await Task.yield() }
        model.toggleMute()
        await detector.releaseDetection()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(factory.connections.isEmpty)
        model.toggleMute()
        audio.push(Data(repeating: 2, count: 2400))
        await settle { factory.connections.count == 1 }
        let socket = try XCTUnwrap(factory.connections.first)
        socket.feed(["type": "session.started"])
        await settle { model.connected }
        XCTAssertEqual(socket.inputAudio.reduce(Data(), +), Data(repeating: 2, count: 2400))
        model.stop(); socket.cancel()
    }

    private func makeModel(detector: ReadinessSpeechDetector? = nil) async throws -> (VoiceConversation, ReadinessConnections, ReadinessAudio, ReadinessGrants) {
        let factory = ReadinessConnections(), audio = ReadinessAudio(), grants = ReadinessGrants()
        let model = VoiceConversation(context: .init(pluginID: "voice-control", storage: VoiceCredentialTestStorage()),
            audio: audio, requestMicrophone: { true }, secrets: VoiceCredentialTestSecrets(),
            makeConnection: { _ in factory.make() }, makeSpeechDetector: { detector ?? ReadinessSpeechDetector() })
        model.connectOnSpeech = detector != nil
        let saved = await model.saveKey("sk-readiness-fixture-not-an-actual-api-key")
        XCTAssertTrue(saved)
        model.context = .init(begin: { _ in UUID() }, end: { grants.ended.append($0) },
            request: { _, _ in grants.requests += 1; return .init() })
        return (model, factory, audio, grants)
    }
    private func start(_ model: VoiceConversation, _ factory: ReadinessConnections) async throws -> ReadinessConnection {
        let index = factory.connections.count
        model.start()
        await settle { factory.connections.count > index }
        let socket = try XCTUnwrap(factory.connections.last)
        socket.feed(["type": "session.started"])
        await settle { model.connected }
        XCTAssertTrue(model.connected)
        return socket
    }
    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(1)) }
    }
}

@MainActor private final class ReadinessConnections {
    var connections: [ReadinessConnection] = []
    func make() -> ReadinessConnection { let value = ReadinessConnection(); connections.append(value); return value }
}
@MainActor private final class ReadinessConnection: VoiceConnection {
    var httpStatus: Int? { nil }
    private var events: [[String: Any]] = []
    private var waiter: CheckedContinuation<[String: Any], Error>?
    private var cancelled = false
    var outputs = 0
    var inputAudio: [Data] = []
    func resume() {}
    func send(_ event: [String: Any]) async throws {
        if cancelled { throw URLError(.cancelled) }
        if event["type"] as? String == "session.input_audio.append", let encoded = event["audio"] as? String, let data = Data(base64Encoded: encoded) { inputAudio.append(data) }
        if event["type"] as? String == "response.item.create" { outputs += 1 }
    }
    func call(_ id: String, name: String, arguments: String) {
        feed(["type": "response.event", "event": ["type": "response.output_item.done", "response_id": id,
            "item": ["type": "function_call", "call_id": id, "name": name, "arguments": arguments]]])
        feed(["type": "response.event", "event": ["type": "response.completed", "response": ["id": id]]])
    }
    func receive() async throws -> [String: Any] {
        if !events.isEmpty { return events.removeFirst() }
        if cancelled { throw URLError(.cancelled) }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func feed(_ event: [String: Any]) {
        if let waiter { self.waiter = nil; waiter.resume(returning: event) } else { events.append(event) }
    }
    func cancel() { cancelled = true; waiter?.resume(throwing: URLError(.cancelled)); waiter = nil }
}
@MainActor private final class ReadinessAudio: VoiceAudioIO {
    var stopped = false
    var played = 0
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var playback: ((Bool) -> Void)?
    func observePlayback(_ observer: @escaping (Bool) -> Void) { playback = observer }
    func start() throws -> AsyncThrowingStream<Data, Error> {
        stopped = false
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        continuation = pair.continuation
        return pair.stream
    }
    func push(_ data: Data) { continuation?.yield(data) }
    func play(_ data: Data) throws { played += 1; playback?(true) }
    func finishPlayback() { playback?(false) }
    func stop() { stopped = true; continuation?.finish(); continuation = nil; playback?(false) }
}
@MainActor private final class ReadinessGrants {
    var ended: [UUID] = []
    var requests = 0
}

private actor ReadinessSpeechDetector: VoiceSpeechDetecting {
    private var holdPreparation: Bool
    private var preparation: CheckedContinuation<Void, Never>?
    private var detection: CheckedContinuation<Bool, Never>?
    private var holdingDetection = false
    private var speech = false
    private(set) var processed = 0
    init(holdPreparation: Bool = false) { self.holdPreparation = holdPreparation }
    func prepare() async throws {
        if holdPreparation { await withCheckedContinuation { preparation = $0 } }
    }
    func releasePreparation() { holdPreparation = false; preparation?.resume(); preparation = nil }
    func holdDetection() { holdingDetection = true }
    func releaseDetection() { holdingDetection = false; speech = true; detection?.resume(returning: true); detection = nil }
    func setSpeech(_ value: Bool) { speech = value }
    func detectsSpeech(in pcm: Data) async throws -> Bool {
        processed += 1
        if holdingDetection { return await withCheckedContinuation { detection = $0 } }
        return speech
    }
    func reset() {}
}
