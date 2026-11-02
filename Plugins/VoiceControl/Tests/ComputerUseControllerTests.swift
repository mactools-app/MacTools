import Foundation
import MacToolsPluginKit
import XCTest
@testable import VoiceControlPlugin

@MainActor
final class ComputerUseControllerTests: XCTestCase {
    func testProtectedOrUnclassifiedControlsAreNotPublishedOrActionable() async throws {
        let runtime = ComputerFixtureRuntime()
        await runtime.useProtectedFixtures()
        let environment = ComputerFixtureEnvironment()
        let controller = ComputerUseController(runtime: runtime, environment: environment)
        let result = try await controller.perform("inspect-app", parameters: .init(["app": .string("Fixture")]), inspectionTarget: environment.target)
        XCTAssertFalse(result.message.contains("private-value"))
        XCTAssertFalse(result.message.contains("unclassified-value"))
        XCTAssertFalse(result.message.contains("unknown-role-value"))
        XCTAssertFalse(result.message.contains("missing-role-value"))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any])
        let id = try XCTUnwrap(payload["observationID"] as? String)
        do {
            _ = try await controller.perform("set-control-value", parameters: .init([
                "observationID": .string(id), "controlID": .string("s00000001:2"), "value": .string("must not write")]))
            XCTFail("Protected controls cannot be addressed")
        } catch ComputerUseError.staleObservation {}
        let calls = await runtime.calls
        XCTAssertFalse(calls.contains("set_value"))
    }

    func testApprovalBindsTheInspectionWindowAndDescribesTheProposedWrite() async throws {
        let environment = ComputerFixtureEnvironment()
        let controller = ComputerUseController(runtime: ComputerFixtureRuntime(), environment: environment)
        let parameters = try ActionParameterSet(["app": .string("Fixture")])
        let approval = try controller.prepareApproval("inspect-app", parameters: parameters)
        let target = try XCTUnwrap(controller.preparedInspectionTarget(parameters))
        environment.target = .init(pid: target.pid, windowID: 789, name: target.name, launched: target.launched)
        let changed = try controller.prepareApproval("inspect-app", parameters: parameters)
        XCTAssertNotEqual(approval.identity, changed.identity)
        do {
            _ = try await controller.perform("inspect-app", parameters: parameters, inspectionTarget: target)
            XCTFail("A replaced approved window must not be inspected")
        } catch ComputerUseError.staleObservation {}
        environment.target = target
        let result = try await controller.perform("inspect-app", parameters: parameters, inspectionTarget: target)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any])
        let write = try ActionParameterSet(["observationID": .string(try XCTUnwrap(payload["observationID"] as? String)),
            "controlID": .string("s00000001:1"), "value": .string("tea at three")])
        let description = try controller.prepareApproval("set-control-value", parameters: write)
        XCTAssertTrue(description.summary.contains("Fixture"))
        XCTAssertTrue(description.summary.contains("Field"))
        XCTAssertTrue(description.summary.contains("tea at three"))
        XCTAssertFalse(description.identity.contains("tea at three"))
    }

    func testDuplicateControlsNeedDistinctVisibleApprovalContext() async throws {
        let runtime = ComputerFixtureRuntime()
        let environment = ComputerFixtureEnvironment()
        let controller = ComputerUseController(runtime: runtime, environment: environment)
        await runtime.useDuplicateControls(["First item", "Other item"])
        func inspectID() async throws -> String {
            let result = try await controller.perform("inspect-app", parameters: .init(["app": .string("Fixture")]), inspectionTarget: environment.target)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any])
            return try XCTUnwrap(payload["observationID"] as? String)
        }
        let id = try await inspectID()
        let first = try controller.prepareApproval("click-control", parameters: .init(["observationID": .string(id), "controlID": .string("s00000001:1")]))
        let other = try controller.prepareApproval("click-control", parameters: .init(["observationID": .string(id), "controlID": .string("s00000001:2")]))
        XCTAssertTrue(first.summary.contains("First item"))
        XCTAssertTrue(other.summary.contains("Other item"))
        XCTAssertNotEqual(first.summary, other.summary)
        await runtime.useDuplicateControls([nil, nil])
        let ambiguousID = try await inspectID()
        XCTAssertThrowsError(try controller.prepareApproval("click-control", parameters: .init([
            "observationID": .string(ambiguousID), "controlID": .string("s00000001:1")])))
        let calls = await runtime.calls
        XCTAssertFalse(calls.contains("click"))
    }

    func testIncompleteProofBlocksInputAndToolbarScopeSurvivesFollowUp() async throws {
        let runtime = ComputerFixtureRuntime()
        let environment = ComputerFixtureEnvironment()
        let controller = ComputerUseController(runtime: runtime, environment: environment)
        for proof in [false, nil] as [Bool?] {
            await runtime.useCompleteness(proof)
            let read = try await controller.perform("inspect-app", parameters: .init(["app": .string("Fixture")]), inspectionTarget: environment.target)
            let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(read.message.utf8)) as? [String: Any])
            XCTAssertEqual(state["complete"] as? Bool, false)
            let click = try ActionParameterSet(["observationID": .string(try XCTUnwrap(state["observationID"] as? String)), "controlID": .string("s00000001:1")])
            XCTAssertThrowsError(try controller.prepareApproval("click-control", parameters: click))
            do { _ = try await controller.perform("click-control", parameters: click); XCTFail("Incomplete observations cannot dispatch") }
            catch ComputerUseError.unavailable {}
        }
        let refusedCalls = await runtime.calls
        XCTAssertFalse(refusedCalls.contains("click"))
        await runtime.useCompleteness(true)
        let read = try await controller.perform("inspect-app", parameters: .init(["app": .string("Fixture"), "scope": .string("toolbar")]), inspectionTarget: environment.target)
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(read.message.utf8)) as? [String: Any])
        let click = try ActionParameterSet(["observationID": .string(try XCTUnwrap(state["observationID"] as? String)), "controlID": .string("s00000001:1")])
        _ = try controller.prepareApproval("click-control", parameters: click)
        _ = try await controller.perform("click-control", parameters: click)
        let scopes = await runtime.scopes
        XCTAssertEqual(Array(scopes.suffix(2)), ["toolbar", "toolbar"])
    }

    func testNativeErrorsExplainReadRefusalsButKeepWriteFailuresUncertain() async throws {
        let runtime = ComputerFixtureRuntime()
        let environment = ComputerFixtureEnvironment()
        let controller = ComputerUseController(runtime: runtime, environment: environment)
        let reason = "Fixture provider refused inspection"
        await runtime.failNext("get_window_state", reason: reason)
        do {
            _ = try await controller.perform("inspect-app", parameters: .init(["app": .string("Fixture")]), inspectionTarget: environment.target)
            XCTFail("An explicit read refusal must be reported")
        } catch ComputerUseError.unavailable(let message) { XCTAssertTrue(message.contains(reason)) }
        let read = try await controller.perform("inspect-app", parameters: .init(["app": .string("Fixture")]), inspectionTarget: environment.target)
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(read.message.utf8)) as? [String: Any])
        await runtime.failNext("set_value", reason: "Fixture write result is uncertain")
        do {
            _ = try await controller.perform("set-control-value", parameters: .init([
                "observationID": .string(try XCTUnwrap(state["observationID"] as? String)),
                "controlID": .string("s00000001:1"), "value": .string("must remain uncertain")]))
            XCTFail("A native error is not a confirmed write")
        } catch ComputerUseError.unverified {}
    }

    func testNativeClipboardAndBrowserActionsValidateInputsWithoutStartingCua() async throws {
        let runtime = ComputerFixtureRuntime()
        let environment = ComputerFixtureEnvironment()
        let controller = ComputerUseController(runtime: runtime, environment: environment)
        _ = try await controller.perform("copy-text", parameters: .init(["text": .string("Siri 的收购价格")]))
        _ = try await controller.perform("search-web", parameters: .init(["query": .string("Siri 收购价格 & history"), "browser": .string("Chrome")]))
        XCTAssertEqual(environment.copied, ["Siri 的收购价格"])
        let url = try XCTUnwrap(environment.opened.first)
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "Siri 收购价格 & history")
        for raw in ["file:///tmp/test", "javascript:alert(1)", "https://user:password@example.com", "https://"] {
            XCTAssertThrowsError(try ComputerUseController.webURL(raw))
        }
        let calls = await runtime.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testWritesRequireFreshControlAndConfirmedReadback() async throws {
        let runtime = ComputerFixtureRuntime()
        let environment = ComputerFixtureEnvironment()
        let controller = ComputerUseController(runtime: runtime, environment: environment)
        let read = try await controller.perform("inspect-app", parameters: .init(["app": .string("Fixture")]), inspectionTarget: environment.target)
        let observation = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(read.message.utf8)) as? [String: Any])
        let id = try XCTUnwrap(observation["observationID"] as? String)
        let parameters = try ActionParameterSet(["observationID": .string(id), "controlID": .string("s00000001:1"), "value": .string("茶 ✅")])
        let result = try await controller.perform("set-control-value", parameters: parameters)
        XCTAssertTrue(result.verified)
        do {
            _ = try await controller.perform("set-control-value", parameters: parameters)
            XCTFail("The consumed observation must not dispatch another write")
        } catch ComputerUseError.staleObservation {}
        let calls = await runtime.calls
        XCTAssertEqual(calls.filter { $0 == "set_value" }.count, 1)
    }

    func testUnverifiedDispatchIsNotReportedAsSuccessAndTargetReplacementStopsWrites() async throws {
        let runtime = ComputerFixtureRuntime()
        let environment = ComputerFixtureEnvironment()
        let controller = ComputerUseController(runtime: runtime, environment: environment)
        let read = try await controller.perform("inspect-app", parameters: .init(["app": .string("Fixture")]), inspectionTarget: environment.target)
        let observation = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(read.message.utf8)) as? [String: Any])
        let id = try XCTUnwrap(observation["observationID"] as? String)
        let result = try await controller.perform("click-control", parameters: .init(["observationID": .string(id), "controlID": .string("s00000001:1")]))
        XCTAssertFalse(result.verified)
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.message.utf8)) as? [String: Any])
        let after = try XCTUnwrap(response["observation"] as? [String: Any])
        environment.current = false
        do {
            _ = try await controller.perform("set-control-value", parameters: .init([
                "observationID": .string(try XCTUnwrap(after["observationID"] as? String)),
                "controlID": .string("s00000001:1"), "value": .string("must not write")]))
            XCTFail("A replaced process/window must be rejected")
        } catch ComputerUseError.staleObservation {}
        let calls = await runtime.calls
        XCTAssertFalse(calls.contains("set_value"))
    }

    func testStopRejectsAnObservationThatCompletesLate() async throws {
        let runtime = ComputerFixtureRuntime()
        await runtime.blockNextRead()
        let environment = ComputerFixtureEnvironment()
        let controller = ComputerUseController(runtime: runtime, environment: environment)
        let task = Task { try await controller.perform("inspect-app", parameters: .init(["app": .string("Fixture")]), inspectionTarget: environment.target) }
        for _ in 0..<1000 {
            if await runtime.waiting { break }
            await Task.yield()
        }
        let waiting = await runtime.waiting
        XCTAssertTrue(waiting)
        controller.stop()
        await runtime.releaseRead()
        do { _ = try await task.value; XCTFail("A stopped request cannot publish an observation") }
        catch is CancellationError {}
    }
}

@MainActor
private final class ComputerFixtureEnvironment: ComputerUseEnvironment {
    var copied: [String] = []
    var opened: [URL] = []
    var current = true
    var target = ComputerUseTarget(pid: 123, windowID: 456, name: "Fixture", launched: Date(timeIntervalSince1970: 1))
    func resolve(app: String, windowID: Int?) throws -> ComputerUseTarget { target }
    func isCurrent(_ target: ComputerUseTarget) -> Bool { current && target == self.target }
    func copy(_ text: String) throws { copied.append(text) }
    func open(_ url: URL, browser: String?) async throws { opened.append(url) }
}

private actor ComputerFixtureRuntime: CuaRuntimeCalling {
    var calls: [String] = []
    private var blockRead = false
    private var pending: CheckedContinuation<Data, Error>?
    private var pendingData = Data()
    private var protectedFixtures = false
    private var duplicateContexts: [String?]?
    private var completeness: Bool? = true
    private var failures: [String: String] = [:]
    func failNext(_ tool: String, reason: String) { failures[tool] = reason }
    var scopes: [String] = []
    func useCompleteness(_ proof: Bool?) { completeness = proof }
    func useDuplicateControls(_ contexts: [String?]) { duplicateContexts = contexts }
    func useProtectedFixtures() { protectedFixtures = true }
    var waiting: Bool { pending != nil }
    func blockNextRead() { blockRead = true }
    func releaseRead() { pending?.resume(returning: pendingData); pending = nil }
    func shutdown() {}
    func invoke(_ tool: String, arguments: Data) async throws -> Data {
        calls.append(tool)
        if let failure = failures.removeValue(forKey: tool) {
            return try JSONSerialization.data(withJSONObject: ["isError": true, "content": [["type": "text", "text": failure]]])
        }
        let arguments = try JSONSerialization.jsonObject(with: arguments) as? [String: Any] ?? [:]
        let scope = arguments["mactools_scope"] as? String ?? "window"
        if tool == "get_window_state" { scopes.append(scope) }
        func response(_ structured: [String: Any]) throws -> Data {
            var value = structured
            if tool == "get_window_state" {
                value["mactools_scope"] = scope
                value["truncated"] = false
                value["mactools_complete"] = completeness
            }
            return try JSONSerialization.data(withJSONObject: ["structuredContent": value])
        }
        let structured: [String: Any]
        if tool == "get_window_state" {
            if let duplicateContexts {
                let elements: [[String: Any]] = duplicateContexts.enumerated().map { index, context in
                    var element: [String: Any] = ["element_token": "s00000001:\(index + 1)", "role": "AXButton", "label": "Delete", "security_checked": true, "secure": false, "native_input_ready": true]
                    if let context { element["context"] = context }
                    return element
                }
                return try response(["pid": 123, "window_id": 456, "elements": elements])
            }
            structured = ["pid": 123, "window_id": 456, "elements": [["element_token": "s00000001:1", "role": "AXTextField", "label": "Field", "value": "fixture", "security_checked": true, "secure": false, "native_input_ready": true]]]
            if protectedFixtures {
                return try response(["pid": 123, "window_id": 456, "elements": [
                    ["element_token": "s00000001:2", "role": "AXTextField", "value": "private-value", "security_checked": true, "secure": true],
                    ["element_token": "s00000001:3", "role": "AXTextField", "value": "unclassified-value"],
                    ["element_token": "s00000001:4", "role": "AXUnknown", "value": "unknown-role-value", "security_checked": true, "secure": false, "native_input_ready": true],
                    ["element_token": "s00000001:5", "value": "missing-role-value", "security_checked": true, "secure": false, "native_input_ready": true]
                ]])
            }
        } else { structured = ["effect": tool == "set_value" ? "confirmed" : "dispatched"] }
        let data = try response(structured)
        if tool == "get_window_state", blockRead {
            blockRead = false; pendingData = data
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        return data
    }
}
