import Foundation
import MacToolsPluginKit
import XCTest
@testable import VoiceControlPlugin

@MainActor
final class VoiceToolsTests: XCTestCase {
    func testFunctionAliasesCannotHijackBuiltinToolsOrChooseAmbiguousTargets() async {
        let capabilities = ["one", "two"].map { id in
            PluginVoiceCapability(id: id, kind: .action, title: id, pluginTitle: "Fixture", description: "Fixture action",
                parameters: [.init(id: "goal", title: "Goal", kind: .string)])
        }
        var names = ["one": "computer_task_begin", "two": "computer_task_begin"]
        var performed: [String] = []
        let context = PluginVoiceControlHostContext(begin: { _ in UUID() }, end: { _ in }, request: { _, request in
            switch request {
            case .search:
                let data = try! JSONSerialization.data(withJSONObject: ["voiceFunctions": names])
                return .init(capabilities: capabilities, payload: String(decoding: data, as: UTF8.self))
            case let .perform(id, _): performed.append(id); return .init()
            }
        })
        let tools = VoiceTools(context: context, sessionID: UUID())
        await tools.prepareTaskCapabilities()
        _ = await tools.call(name: "computer_task_begin", arguments: "{\"goal\":\"fixture\"}")
        XCTAssertTrue(performed.isEmpty)
        names = ["one": "perform_capability", "two": "computer_task_step"]
        await tools.prepareTaskCapabilities()
        _ = await tools.call(name: "perform_capability", arguments: "{\"goal\":\"fixture\"}")
        XCTAssertTrue(performed.isEmpty, "Metadata cannot replace a built-in tool's contract")
        _ = await tools.call(name: "computer_task_step", arguments: "{\"goal\":\"fixture\"}")
        XCTAssertEqual(performed, ["two"])
    }

    func testInterfaceCannotBePerformedAsAnAppOperation() async throws {
        let picker = PluginVoiceCapability(id: "picker", kind: .feature, title: "Choose apps", pluginTitle: "Fixture", description: "Show a chooser")
        let action = PluginVoiceCapability(id: "action", kind: .action, title: "Change fixture", pluginTitle: "Fixture", description: "A real action")
        var writes = 0
        let context = PluginVoiceControlHostContext(begin: { _ in UUID() }, end: { _ in }, request: { _, request in
            switch request {
            case .search: return .init(capabilities: [picker, action])
            case .perform: writes += 1; return .init(status: "interfaceOpened")
            }
        })
        let tools = VoiceTools(context: context, sessionID: UUID())
        _ = await tools.call(name: "discover_capabilities", arguments: "{\"query\":\"close fixture app\"}")
        let arguments = "{\"capabilityID\":\"picker\",\"parameters\":[]}"
        let rejected = await tools.call(name: "perform_capability", arguments: arguments)
        XCTAssertTrue(rejected.contains("interfaceOnly"))
        XCTAssertEqual(writes, 0, "A mistaken picker selection must not even open its UI")
        _ = await tools.call(name: "open_interface", arguments: arguments.replacingOccurrences(of: "picker", with: "action"))
        XCTAssertEqual(writes, 0)
        let opened = await tools.call(name: "open_interface", arguments: arguments)
        XCTAssertTrue(opened.contains("interfaceOpened"))
        XCTAssertEqual(writes, 1, "Explicit navigation remains supported")
    }

    func testTaskBootstrapUsesIssuedIDsAndStopDiscardsLateDiscovery() async throws {
        let capability = PluginVoiceCapability(id: "host-task", kind: .action, title: "Task", pluginTitle: "Assistant",
            description: "A scoped task", parameters: [.init(id: "goal", title: "Goal", kind: .string),
                .init(id: "count", title: "Count", kind: .integer, isRequired: false),
                .init(id: "flag", title: "Flag", kind: .boolean, isRequired: false)])
        var operations = 0
        var received: ActionParameterSet?
        var pending: CheckedContinuation<PluginVoiceReply, Never>?
        let context = PluginVoiceControlHostContext(begin: { _ in UUID() }, end: { _ in }, request: { _, request in
            switch request {
            case .search: return await withCheckedContinuation { pending = $0 }
            case let .perform(_, parameters): operations += 1; received = parameters; return .init()
            }
        })
        let tools = VoiceTools(context: context, sessionID: UUID())
        let prepare = Task { await tools.prepareTaskCapabilities() }
        while pending == nil { await Task.yield() }
        pending?.resume(returning: .init(capabilities: [capability], payload: "{\"voiceFunctions\":{\"host-task\":\"computer_task_begin\"}}")); pending = nil
        await prepare.value
        let configuration = tools.configuration(providers: [], taskUnavailableReason: "fixture consent missing")
        let delegation = try XCTUnwrap(configuration["delegation"] as? [String: Any])
        let backend = try XCTUnwrap(delegation["responses"] as? [String: Any])
        let instructions = try XCTUnwrap(backend["instructions"] as? String)
        let declarations = try XCTUnwrap(backend["tools"] as? [[String: Any]])
        XCTAssertTrue(declarations.contains { $0["name"] as? String == "computer_task_begin" })
        XCTAssertTrue(instructions.contains("fixture consent missing"))
        for arguments in ["{\"goal\":null}", "{\"goal\":\"fixture goal\",\"count\":true}",
                          "{\"goal\":\"fixture goal\",\"flag\":1}", "{\"goal\":\"fixture goal\",\"unknown\":1}"] {
            _ = await tools.call(name: "computer_task_begin", arguments: arguments)
        }
        XCTAssertEqual(operations, 0)
        _ = await tools.call(name: "computer_task_begin", arguments: "{\"goal\":\"fixture goal\",\"count\":3,\"flag\":null}")
        XCTAssertEqual(operations, 1, "Bootstrap must make host-issued IDs executable without a second discovery")
        XCTAssertEqual(received, try .init(["goal": .string("fixture goal"), "count": .integer(3)]))

        let late = Task { await tools.prepareTaskCapabilities() }
        while pending == nil { await Task.yield() }
        tools.stop()
        pending?.resume(returning: .init(capabilities: [capability]))
        await late.value
        let stopped = tools.configuration(providers: [], taskUnavailableReason: nil)
        let stoppedBackend = (stopped["delegation"] as? [String: Any])?["responses"] as? [String: Any]
        XCTAssertFalse((stoppedBackend?["tools"] as? [[String: Any]] ?? []).contains { $0["name"] as? String == "computer_task_begin" })
        XCTAssertEqual(operations, 1)
    }

    func testDiscoveredTypedCapabilityIsRequiredAndStopRevokesIt() async throws {
        let capability = PluginVoiceCapability(id: "host-issued", kind: .action, title: "Set value", pluginTitle: "Fixture",
            description: "Set a value", parameters: [.init(id: "value", title: "Value", kind: .integer)])
        var values: [ActionParameterSet] = []
        var ended = false
        let context = PluginVoiceControlHostContext(begin: { _ in UUID() }, end: { _ in ended = true }, request: { _, request in
            switch request {
            case .search: return .init(capabilities: [capability])
            case let .perform(_, parameters): values.append(parameters); return .init()
            }
        })
        let tools = VoiceTools(context: context, sessionID: UUID())
        let arguments = "{\"capabilityID\":\"host-issued\",\"parameters\":[{\"name\":\"value\",\"value\":\"35\"}]}"
        _ = await tools.call(name: "perform_capability", arguments: arguments)
        XCTAssertTrue(values.isEmpty)
        _ = await tools.call(name: "discover_capabilities", arguments: "{\"query\":\"value\"}")
        _ = await tools.call(name: "perform_capability", arguments: arguments.replacingOccurrences(of: "35", with: "true"))
        XCTAssertTrue(values.isEmpty)
        _ = await tools.call(name: "perform_capability", arguments: arguments)
        XCTAssertEqual(values, [try ActionParameterSet(["value": .integer(35)])])
        tools.stop()
        _ = await tools.call(name: "perform_capability", arguments: arguments)
        XCTAssertEqual(values.count, 1)
        XCTAssertTrue(ended)
    }
}
