import Foundation
import MacToolsPluginKit
import XCTest
@testable import VoiceControlPlugin

@MainActor
final class VoiceApprovalsTests: XCTestCase {
    func testDirectControlIsExplicitAndSetupStillNeedsButtons() async {
        let approvals = VoiceApprovals()
        XCTAssertFalse(approvals.directControlEnabled)
        let first = request()
        let answer = Task { await approvals.confirm(first) }
        await settle { approvals.pending != nil }
        approvals.resolve(true, requestID: first.id)
        let result0 = await answer.value
        XCTAssertTrue(result0)
        XCTAssertFalse(approvals.directControlEnabled, "Approving one request must not change the saved mode")

        approvals.setDirectControl(true)
        let result1 = await approvals.confirm(request())
        XCTAssertTrue(result1)
        XCTAssertNil(approvals.pending)
        let setup = request(direct: false)
        let setupAnswer = Task { await approvals.confirm(setup) }
        await settle { approvals.pending?.id == setup.id }
        XCTAssertEqual(approvals.pending?.id, setup.id)
        approvals.resolve(false, requestID: setup.id)
        let result2 = await setupAnswer.value
        XCTAssertFalse(result2)
        approvals.endConversation()
        XCTAssertTrue(approvals.directControlEnabled)
    }

    func testRetiredButtonAndCancellationCannotApproveAnotherRequest() async {
        let approvals = VoiceApprovals()
        let first = request(), second = request()
        let old = Task { await approvals.confirm(first) }
        await settle { approvals.pending != nil }
        old.cancel()
        let result3 = await old.value
        XCTAssertFalse(result3)
        let current = Task { await approvals.confirm(second) }
        await settle { approvals.pending?.id == second.id }
        approvals.resolve(true, requestID: first.id)
        XCTAssertEqual(approvals.pending?.id, second.id)
        approvals.resolve(true, requestID: second.id)
        let result4 = await current.value
        XCTAssertTrue(result4)
        let expired = VoiceApprovals(timeout: .zero)
        let result5 = await expired.confirm(request())
        XCTAssertFalse(result5)
    }

    private func request(direct: Bool = true) -> PluginVoiceConfirmationRequest {
        .init(title: "Fixture", message: "Operate only the fixture", confirmButtonTitle: "Allow", allowsDirectControl: direct)
    }
    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { await Task.yield() }
    }
}
