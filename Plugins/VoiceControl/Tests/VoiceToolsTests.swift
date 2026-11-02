import Foundation
import MacToolsPluginKit
import XCTest
@testable import VoiceControlPlugin

@MainActor
final class VoiceToolsTests: XCTestCase {
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
        pending?.resume(returning: .init(capabilities: [capability])); pending = nil
        await prepare.value
        let configuration = tools.configuration(providers: [], taskUnavailableReason: "fixture consent missing")
        let delegation = try XCTUnwrap(configuration["delegation"] as? [String: Any])
        let backend = try XCTUnwrap(delegation["responses"] as? [String: Any])
        let instructions = try XCTUnwrap(backend["instructions"] as? String)
        let declarations = try XCTUnwrap(backend["tools"] as? [[String: Any]])
        XCTAssertTrue(declarations.contains { $0["name"] as? String == "computer_action_0" })
        XCTAssertTrue(instructions.contains("fixture consent missing"))
        for arguments in ["{\"goal\":null}", "{\"goal\":\"fixture goal\",\"count\":true}",
                          "{\"goal\":\"fixture goal\",\"flag\":1}", "{\"goal\":\"fixture goal\",\"unknown\":1}"] {
            _ = await tools.call(name: "computer_action_0", arguments: arguments)
        }
        XCTAssertEqual(operations, 0)
        _ = await tools.call(name: "computer_action_0", arguments: "{\"goal\":\"fixture goal\",\"count\":3,\"flag\":null}")
        XCTAssertEqual(operations, 1, "Bootstrap must make host-issued IDs executable without a second discovery")
        XCTAssertEqual(received, try .init(["goal": .string("fixture goal"), "count": .integer(3)]))

        let late = Task { await tools.prepareTaskCapabilities() }
        while pending == nil { await Task.yield() }
        tools.stop()
        pending?.resume(returning: .init(capabilities: [capability]))
        await late.value
        let stopped = tools.configuration(providers: [], taskUnavailableReason: nil)
        let stoppedBackend = (stopped["delegation"] as? [String: Any])?["responses"] as? [String: Any]
        XCTAssertFalse((stoppedBackend?["tools"] as? [[String: Any]] ?? []).contains { $0["name"] as? String == "computer_action_0" })
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
