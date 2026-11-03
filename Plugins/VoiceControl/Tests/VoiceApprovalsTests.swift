import Foundation
import MacToolsPluginKit
import XCTest
@testable import VoiceControlPlugin

@MainActor
final class VoiceApprovalsTests: XCTestCase {
    func testExtendedApprovalCoversLaterRequestsButNotButtonOnlyConsent() async {
        let approvals = VoiceApprovals(makeDetector: { ApprovalDetector() }) { _ in XCTFail("No transcription needed"); return "confirm" }
        let first = request()
        let response = Task { await approvals.confirm(first) }
        await settle { approvals.pending != nil }
        approvals.resolve(true, requestID: first.id, scope: .process)
        let accepted = await response.value
        XCTAssertTrue(accepted)
        let later = await approvals.confirm(.init(title: "Run command", message: "printf fixture", confirmButtonTitle: "Allow", allowsSpokenConfirmation: true))
        XCTAssertTrue(later)
        XCTAssertNil(approvals.pending)
        let protectedRequest = request(voice: false)
        let protectedReply = Task { await approvals.confirm(protectedRequest) }
        await settle { approvals.pending != nil }
        XCTAssertEqual(approvals.pending?.id, protectedRequest.id)
        approvals.resolve(false, requestID: protectedRequest.id)
        let declined = await protectedReply.value
        XCTAssertFalse(declined)
        approvals.revokeExtendedApproval()
        approvals.resolve(true, requestID: first.id, scope: .process)
        XCTAssertEqual(approvals.scope, .once, "A retired UI choice cannot restore a revoked grant")
        let buttonOnly = request(voice: false)
        let buttonReply = Task { await approvals.confirm(buttonOnly) }
        await settle { approvals.pending != nil }
        approvals.resolve(true, requestID: buttonOnly.id, scope: .process)
        let buttonAccepted = await buttonReply.value
        XCTAssertTrue(buttonAccepted)
        XCTAssertEqual(approvals.scope, .once, "Button-only consent never grants broader action approval")
        let fresh = VoiceApprovals(makeDetector: { ApprovalDetector() }) { _ in "confirm" }
        XCTAssertEqual(fresh.scope, .once, "No approval is restored into a new process/plugin instance")
    }

    func testCompletedDecisionsRejectNegationsAndAdditionalInstructions() {
        for text in ["Confirm.", "Yes, quit it.", "确认", "確認", "Sí", "Onayla"] { XCTAssertEqual(VoiceApprovalDecision.parse(text), .allow(.once)) }
        for text in ["Allow all for this conversation.", "Allow all for this session", "本次对话全部允许", "本次對話允許所有操作"] {
            XCTAssertEqual(VoiceApprovalDecision.parse(text), .allow(.conversation))
        }
        for text in ["Allow all until MacTools quits.", "Allow all until Mac Tools quits", "MacTools 退出前全部允许", "MacTools 結束前允許所有操作"] {
            XCTAssertEqual(VoiceApprovalDecision.parse(text), .allow(.process))
        }
        for text in ["Cancel", "İptal", "No, open Safari instead", "Yes, don't do it", "确认，不要执行", "Don't allow all for this conversation", "Allow all until MacTools quits, no, cancel"] {
            XCTAssertEqual(VoiceApprovalDecision.parse(text), .cancel)
        }
        for text in ["maybe", "yes but change the target", "confirm then delete everything", "", "allow all", "always allow", "allow all for this conversation then delete everything", "you said allow all until MacTools quits"] {
            XCTAssertNil(VoiceApprovalDecision.parse(text))
        }
        var capture = VoiceApprovalCapture()
        for _ in 0..<80 {
            if case .waiting = capture.append(Data(count: 4800), speech: false) {} else { XCTFail("Silence must not yield a clip") }
        }
        var tooLong = false
        for _ in 0..<70 {
            if case .tooLong = capture.append(Data(repeating: 1, count: 4800), speech: true) { tooLong = true; break }
        }
        XCTAssertTrue(tooLong, "A long utterance must be refused, never truncated into an approval")
    }

    func testSpokenRepliesResolveOnlyAfterQuestionAndWholeClip() async throws {
        for (text, expected, scope) in [("Confirm", true, VoiceApprovals.Scope.once), ("Yes, don't do it", false, .once),
            ("Allow all for this conversation", true, .conversation), ("Allow all until MacTools quits", true, .process)] {
            let detector = ApprovalDetector()
            var clips = 0
            let approvals = VoiceApprovals(makeDetector: { detector }, playbackSettle: .zero) { clip in
                XCTAssertGreaterThan(clip.count, 28_800); clips += 1; return text
            }
            let request = request()
            let response = Task { await approvals.confirm(request) }
            await settle { approvals.pending != nil }
            await approvals.receiveAudio(Data(repeating: 1, count: 4800))
            XCTAssertEqual(clips, 0, "Pre-question microphone content cannot approve a request")
            await arm(approvals)
            await reply(approvals)
            await settle { approvals.pending == nil }
            let approved = await response.value
            XCTAssertEqual(approved, expected)
            XCTAssertEqual(approvals.scope, scope)
            XCTAssertEqual(clips, 1)
            approvals.resolve(true, requestID: request.id)
        }
    }

    func testNewSpeechDiscardsLateRecognitionAndCannotApproveNextRequest() async throws {
        let detector = ApprovalDetector()
        var transcription: CheckedContinuation<String, Error>?
        let approvals = VoiceApprovals(makeDetector: { detector }, playbackSettle: .zero) { _ in
            try await withCheckedThrowingContinuation { transcription = $0 }
        }
        let first = request(), second = request()
        let old = Task { await approvals.confirm(first) }
        await settle { approvals.pending != nil }
        await arm(approvals); await reply(approvals)
        await settle { transcription != nil }
        await approvals.receiveAudio(Data(repeating: 1, count: 4800))
        let declined = await old.value
        XCTAssertFalse(declined)
        let current = Task { await approvals.confirm(second) }
        await settle { approvals.pending?.id == second.id }
        transcription?.resume(returning: "Allow all until MacTools quits")
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(approvals.pending?.id, second.id)
        XCTAssertEqual(approvals.scope, .once, "Late recognition cannot expand a later request's scope")
        approvals.resolve(true, requestID: first.id)
        XCTAssertEqual(approvals.pending?.id, second.id)
        approvals.resolve(true, requestID: second.id)
        let accepted = await current.value
        XCTAssertTrue(accepted)
    }

    func testButtonOnlyApprovalAndTaskCancellationNeverUseVoice() async {
        let approvals = VoiceApprovals(makeDetector: { ApprovalDetector() }, playbackSettle: .zero) { _ in XCTFail("No upload expected"); return "Allow all until MacTools quits" }
        let request = request(voice: false)
        let response = Task { await approvals.confirm(request) }
        await settle { approvals.pending != nil }
        approvals.playbackChanged(true); approvals.playbackChanged(false)
        await reply(approvals)
        XCTAssertFalse(approvals.listening)
        XCTAssertEqual(approvals.scope, .once)
        response.cancel()
        let result = await response.value
        XCTAssertFalse(result)
        XCTAssertNil(approvals.pending)
        let expired = VoiceApprovals(makeDetector: { ApprovalDetector() }, timeout: .zero, playbackSettle: .zero) { _ in XCTFail("No upload expected"); return "confirm" }
        let timedOut = await expired.confirm(self.request())
        XCTAssertFalse(timedOut)
    }

    func testMutedApprovalKeepsButtonsAvailableWithoutUploadingSpeech() async {
        var uploads = 0
        let approvals = VoiceApprovals(makeDetector: { ApprovalDetector() }, playbackSettle: .zero) { _ in uploads += 1; return "confirm" }
        let request = request()
        let response = Task { await approvals.confirm(request) }
        await settle { approvals.pending != nil }
        await arm(approvals)
        approvals.setMuted(true)
        await reply(approvals)
        XCTAssertEqual(uploads, 0)
        XCTAssertEqual(approvals.pending?.id, request.id)
        approvals.resolve(true, requestID: request.id)
        let approved = await response.value
        XCTAssertTrue(approved)
    }

    private func request(voice: Bool = true) -> PluginVoiceConfirmationRequest {
        .init(title: "Fixture approval", message: "Operate only the fixture", confirmButtonTitle: "Allow", allowsSpokenConfirmation: voice)
    }
    private func arm(_ approvals: VoiceApprovals) async {
        // The detector is prepared before the actual question is announced.
        for _ in 0..<100 { await Task.yield() }
        approvals.playbackChanged(true); approvals.playbackChanged(false)
        await settle { approvals.listening }
        XCTAssertTrue(approvals.listening)
    }
    private func reply(_ approvals: VoiceApprovals) async {
        approvals.playbackChanged(false)
        await approvals.receiveAudio(Data(repeating: 1, count: 4800))
        for _ in 0..<6 {
            approvals.playbackChanged(false) // The real output player also reports silence buffers.
            await approvals.receiveAudio(Data(count: 4800))
        }
    }
    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { await Task.yield() }
    }
}

private actor ApprovalDetector: VoiceSpeechDetecting {
    func prepare() {}
    func reset() {}
    func detectsSpeech(in pcm: Data) -> Bool { pcm.first == 1 }
}
