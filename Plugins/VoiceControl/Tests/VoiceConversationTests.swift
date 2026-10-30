import Foundation
import MacToolsPluginKit
import XCTest
@testable import VoiceControlPlugin

@MainActor
final class VoiceConversationTests: XCTestCase {
    func testExcludedProvidersReachHostBeforeMicrophoneAccess() async {
        let model = await makeModel()
        model.excludedPluginIDs = ["clipboard"]
        var requested: Set<String>?
        model.context = .init(begin: { requested = $0; return nil }, end: { _ in },
                              request: { _, _ in .init(status: "sessionEnded") })
        model.start()
        for _ in 0..<100 where requested == nil { await Task.yield() }
        XCTAssertEqual(requested, ["clipboard"])
        XCTAssertFalse(model.active)
    }

    func testDeniedMicrophoneRevokesHostSession() async {
        let model = await makeModel()
        let session = UUID()
        var revoked = false
        model.context = .init(begin: { _ in session }, end: { revoked = $0 == session },
                              request: { _, _ in XCTFail("Denied capture must not run tools"); return .init() })
        model.start()
        for _ in 0..<100 where !revoked { await Task.yield() }
        XCTAssertTrue(revoked)
        XCTAssertFalse(model.active)
        XCTAssertFalse(model.connected)
    }

    func testManualApprovalExcludesNewProvidersFromHostGrantBeforeAudioSetup() async {
        let model = await makeModel()
        model.featureAccess = .init(automaticallyAllowNewPlugins: false,
            excludedPluginIDs: ["blocked"], approvedPluginIDs: ["existing"])
        var exclusions: Set<String>?
        model.context = .init(providers: { [
            .init(id: "existing", title: "Existing"), .init(id: "new", title: "New"),
            .init(id: "blocked", title: "Blocked")
        ] }, begin: { exclusions = $0; return nil }, end: { _ in }, request: { _, _ in .init() })
        model.start()
        for _ in 0..<100 where exclusions == nil { await Task.yield() }
        XCTAssertEqual(exclusions, ["new", "blocked"])
        XCTAssertFalse(model.active)
    }

    func testStopWhileAwaitingMicrophoneCannotRestartCapture() async {
        var permission: CheckedContinuation<Bool, Never>?
        let model = VoiceConversation(context: .init(pluginID: "voice-control", storage: VoiceCredentialTestStorage()),
            audio: NoCaptureAudio(), requestMicrophone: { await withCheckedContinuation { permission = $0 } },
            secrets: VoiceCredentialTestSecrets())
        let saved = await model.saveKey("sk-unit-test-fixture-not-a-real-key")
        XCTAssertTrue(saved)
        var revoked = false
        model.context = .init(begin: { _ in UUID() }, end: { _ in revoked = true }, request: { _, _ in .init() })
        model.start()
        for _ in 0..<100 where permission == nil { await Task.yield() }
        XCTAssertNotNil(permission)
        model.stop()
        permission?.resume(returning: true)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(revoked)
        XCTAssertFalse(model.active)
        XCTAssertFalse(model.capturing)
    }

    private func makeModel() async -> VoiceConversation {
        let model = VoiceConversation(context: .init(pluginID: "voice-control", storage: VoiceCredentialTestStorage()),
            audio: NoCaptureAudio(), requestMicrophone: { false }, secrets: VoiceCredentialTestSecrets())
        let saved = await model.saveKey("sk-unit-test-fixture-not-a-real-key")
        XCTAssertTrue(saved)
        return model
    }
}

@MainActor private final class NoCaptureAudio: VoiceAudioIO {
    func start() throws -> AsyncThrowingStream<Data, Error> { XCTFail("Must not capture"); throw VoiceFailure.audio }
    func play(_ data: Data) throws { XCTFail("Must not play") }
    func stop() {}
}
