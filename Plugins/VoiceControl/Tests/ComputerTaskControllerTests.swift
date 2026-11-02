import Foundation
import MacToolsPluginKit
import XCTest
@testable import VoiceControlPlugin

@MainActor
final class ComputerTaskControllerTests: XCTestCase {
    func testApprovedTaskComposesStepsAndRequiresFreshVerification() async throws {
        let environment = TaskFixtureEnvironment()
        let controller = makeController(environment)
        defer { controller.stop() }
        let begin = try params(["goal": "Edit the document through its menus and keyboard", "apps": "[\"Fixture\"]"])
        do { _ = try await controller.perform("task-begin", begin); XCTFail("Approval is required") } catch {}
        _ = try controller.approval("task-begin", begin)
        let started = try object(await controller.perform("task-begin", begin, admission: controller.admission("task-begin", begin)))
        let id = try XCTUnwrap(started["taskID"] as? String)
        let read = try params(["taskID": id, "app": "Fixture"])
        let input = try params(["taskID": id, "app": "Fixture", "stepID": "one", "operation": "key", "payload": "{\"keys\":[\"command\",\"a\"]}"])
        do { _ = try await controller.perform("task-step", input); XCTFail("Observe before writing") } catch {}
        XCTAssertEqual(environment.inputs.count, 0)
        _ = try await controller.perform("task-observe", read)
        let outside = try params(["taskID": id, "app": "Other", "stepID": "one", "operation": "key", "payload": "{\"keys\":[\"return\"]}"])
        do { _ = try await controller.perform("task-step", outside); XCTFail("Do not expand approved apps") } catch {}
        _ = try await controller.perform("task-step", input)
        let finish = try params(["taskID": id, "outcome": "completed"])
        do { _ = try await controller.perform("task-finish", finish); XCTFail("Dispatch is not verified completion") } catch {}
        _ = try await controller.perform("task-observe", read)
        do { _ = try await controller.perform("task-step", input); XCTFail("A consumed write cannot be replayed") } catch {}
        let text = try params(["taskID": id, "app": "Fixture", "stepID": "two", "operation": "type", "payload": "{\"text\":\"A new sentence\"}"])
        _ = try await controller.perform("task-step", text)
        _ = try await controller.perform("task-observe", read)
        XCTAssertEqual(environment.inputs.count, 2)
        let finished = try object(await controller.perform("task-finish", finish))
        XCTAssertEqual(finished["status"] as? String, "completed")
        do { _ = try await controller.perform("task-step", text); XCTFail("Finished grants are revoked") } catch {}
    }

    func testStopAndExpiryRejectLateObservations() async throws {
        let environment = TaskFixtureEnvironment()
        var date = Date()
        let controller = makeController(environment, now: { date })
        let begin = try params(["goal": "Read the current window", "apps": "[\"Fixture\"]"])
        func start() async throws -> String {
            _ = try controller.approval("task-begin", begin)
            let reply = try object(await controller.perform("task-begin", begin, admission: controller.admission("task-begin", begin)))
            return try XCTUnwrap(reply["taskID"] as? String)
        }
        let id = try await start()
        environment.blockMenus = true
        let observation = Task { try await controller.perform("task-observe", params(["taskID": id, "app": "Fixture"])) }
        for _ in 0..<1000 { if environment.pending != nil { break }; await Task.yield() }
        XCTAssertNotNil(environment.pending)
        controller.stop()
        environment.pending?.resume(returning: "{\"items\":[]}"); environment.pending = nil
        do { _ = try await observation.value; XCTFail("A stopped read cannot publish") } catch {}
        environment.blockMenus = false
        let next = try await start()
        date = date.addingTimeInterval(301)
        do { _ = try await controller.perform("task-observe", params(["taskID": next, "app": "Fixture"])); XCTFail("Expired grants cannot read") } catch {}
        controller.stop()
    }

    func testObservedAppMenusCanCreateItsFirstVisibleWindow() async throws {
        let environment = TaskFixtureEnvironment()
        environment.hasWindow = false
        let controller = makeController(environment)
        defer { controller.stop() }
        let begin = try params(["goal": "Open a window and enter text", "apps": "[\"Fixture\"]"])
        _ = try controller.approval("task-begin", begin)
        let reply = try object(await controller.perform("task-begin", begin, admission: controller.admission("task-begin", begin)))
        let id = try XCTUnwrap(reply["taskID"] as? String)
        let read = try params(["taskID": id, "app": "Fixture"])
        let empty = try object(await controller.perform("task-observe", read))
        XCTAssertEqual(empty["windowID"] as? Int, 0)
        let type = try params(["taskID": id, "app": "Fixture", "stepID": "text", "operation": "type", "payload": "{\"text\":\"hello\"}"])
        do { _ = try await controller.perform("task-step", type); XCTFail("Keyboard input needs a visible window") } catch {}
        _ = try await controller.perform("task-step", params(["taskID": id, "app": "Fixture", "stepID": "window", "operation": "menu", "payload": "{\"menuID\":\"new-window\"}"]))
        let visible = try object(await controller.perform("task-observe", read))
        XCTAssertEqual(visible["windowID"] as? Int, 456)
        _ = try await controller.perform("task-step", type)
        XCTAssertEqual(environment.inputs.count, 2)
    }

    func testManagedCommandsReportOutputExitAndCancelOwnedProcesses() async throws {
        let commands = ComputerCommandSessions()
        defer { commands.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = try ComputerCommandRequest(command: "printf 'output'; printf 'error' >&2; test -z \"${OPENAI_API_KEY+x}\" || exit 9; exit 7", directory: directory.path, timeout: 5)
        let started = try object(await commands.start(request))
        let id = try XCTUnwrap(started["commandID"] as? String)
        var result = started
        for _ in 0..<300 {
            result = try object(commands.snapshot(id))
            if result["status"] as? String == "failed" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(result["exitCode"] as? Int, 7)
        XCTAssertEqual(result["stdout"] as? String, "output")
        XCTAssertEqual(result["stderr"] as? String, "error")
        let running = try object(await commands.start(.init(command: "sleep 30 & wait", directory: directory.path, timeout: 10)))
        let runningID = try XCTUnwrap(running["commandID"] as? String)
        _ = try commands.cancel(runningID)
        for _ in 0..<300 {
            result = try object(commands.snapshot(runningID))
            if result["status"] as? String == "cancelled" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(result["status"] as? String, "cancelled")
        XCTAssertEqual(try object(commands.snapshot(id))["exitCode"] as? Int, 7)
        let deadline = try object(await commands.start(.init(command: "sleep 30", directory: directory.path, timeout: 1)))
        let deadlineID = try XCTUnwrap(deadline["commandID"] as? String)
        let expired = try object(await commands.waitForSnapshot(deadlineID))
        XCTAssertEqual(expired["status"] as? String, "timed_out")
        commands.stop()
        XCTAssertThrowsError(try commands.snapshot(id))
    }

    func testKeyChordsAndCommandApprovalAreConcrete() throws {
        XCTAssertNoThrow(try ComputerTaskKeyChord(["command", "shift", "t"]))
        XCTAssertThrowsError(try ComputerTaskKeyChord(["command", "command", "q"]))
        XCTAssertThrowsError(try ComputerTaskKeyChord(["script", "return"]))
        XCTAssertThrowsError(try ComputerCommandRequest(command: "echo ok", directory: "/", timeout: 0))
        let controller = makeController(TaskFixtureEnvironment())
        defer { controller.stop() }
        let first = try params(["command": "printf first"])
        let second = try params(["command": "printf second"])
        let approval = try XCTUnwrap(controller.approval("command-start", first))
        XCTAssertTrue(approval.summary.contains("printf first"))
        XCTAssertThrowsError(try controller.admission("command-start", second))
        XCTAssertNotNil(try controller.admission("command-start", first))
    }

    private func makeController(_ env: TaskFixtureEnvironment, now: @escaping () -> Date = Date.init) -> ComputerTaskController {
        ComputerTaskController(computer: .init(runtime: TaskFixtureRuntime(), environment: env), environment: env, now: now)
    }
    private func params(_ values: [String: String]) throws -> ActionParameterSet { try .init(values.mapValues(ActionParameterValue.string)) }
    private func object(_ json: String) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) }
}

@MainActor
private final class TaskFixtureEnvironment: ComputerTaskEnvironment, ComputerUseEnvironment {
    let target = ComputerUseTarget(pid: 123, windowID: 456, name: "Fixture", launched: Date(timeIntervalSince1970: 1))
    var inputs: [ComputerTaskInput] = []
    var hasWindow = true
    var blockMenus = false
    var pending: CheckedContinuation<String, Error>?
    func resolveApplications(_ names: [String]) throws -> [ComputerTaskApplication] {
        [.init(pid: 123, name: "Fixture", bundleID: "fixture", launched: target.launched)]
    }
    func isRunning(_ app: ComputerTaskApplication) -> Bool { true }
    func windows(_ app: ComputerTaskApplication) -> [ComputerUseTarget] { hasWindow ? [target] : [] }
    func menus(_ target: ComputerUseTarget, path: [String]) async throws -> String {
        if blockMenus { return try await withCheckedThrowingContinuation { pending = $0 } }
        return "{\"items\":[],\"complete\":true}"
    }
    func input(_ operation: ComputerTaskInput, target: ComputerUseTarget) async throws {
        inputs.append(operation)
        if case .menu = operation { hasWindow = true }
    }
    func stop() {}
    func resolve(app: String, windowID: Int?) throws -> ComputerUseTarget { target }
    func isCurrent(_ target: ComputerUseTarget) -> Bool { target == self.target }
    func copy(_ text: String) throws {}
    func open(_ url: URL, browser: String?) async throws {}
}
private actor TaskFixtureRuntime: CuaRuntimeCalling {
    func shutdown() {}
    func invoke(_ tool: String, arguments: Data) async throws -> Data {
        let args = try JSONSerialization.jsonObject(with: arguments) as? [String: Any] ?? [:]
        return try JSONSerialization.data(withJSONObject: ["structuredContent": ["pid": 123, "window_id": 456,
            "mactools_scope": args["mactools_scope"] as? String ?? "window", "elements": [], "mactools_complete": true, "truncated": false]])
    }
}
