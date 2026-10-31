import Foundation
import MacToolsPluginKit
import XCTest
@testable import VoiceControlPlugin

@MainActor
final class VoiceToolsTests: XCTestCase {
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
