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
        socket.cancel()
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
        let (model, factory, audio, grants) = try await makeModel()
        let socket = try await start(model, factory)
        model.stopIfIdle(at: .now.advanced(by: .seconds(240)))
        XCTAssertFalse(model.active)
        XCTAssertTrue(audio.stopped)
        XCTAssertEqual(grants.ended.count, 1)
        XCTAssertEqual(factory.connections.count, 1)
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

    private func makeModel() async throws -> (VoiceConversation, ReadinessConnections, ReadinessAudio, ReadinessGrants) {
        let factory = ReadinessConnections(), audio = ReadinessAudio(), grants = ReadinessGrants()
        let model = VoiceConversation(context: .init(pluginID: "voice-control", storage: VoiceCredentialTestStorage()),
            audio: audio, requestMicrophone: { true }, secrets: VoiceCredentialTestSecrets(),
            makeConnection: { _ in factory.make() })
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
    func resume() {}
    func send(_ event: [String: Any]) async throws { if cancelled { throw URLError(.cancelled) } }
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
    func start() throws -> AsyncThrowingStream<Data, Error> {
        stopped = false
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        continuation = pair.continuation
        return pair.stream
    }
    func play(_ data: Data) throws { played += 1 }
    func stop() { stopped = true; continuation?.finish(); continuation = nil }
}
@MainActor private final class ReadinessGrants {
    var ended: [UUID] = []
    var requests = 0
}
