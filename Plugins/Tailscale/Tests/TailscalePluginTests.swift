import AppKit
import Foundation
import MacToolsPluginKit
import XCTest
@testable import TailscalePlugin

@MainActor
final class TailscalePluginTests: XCTestCase {
    func testWakeRefreshesStatusAndClearsDeviceActionsAfterLogout() async throws {
        let cli = FakeCLI()
        let plugin = makePlugin(cli)
        let state = try context()
        defer { state.defaults.removePersistentDomain(forName: state.domain) }
        plugin.activate(context: state.context)
        defer { plugin.deactivate(reason: .disabled) }

        await waitUntil { plugin.rowState.isOn }
        let localCopy = try XCTUnwrap(plugin.rowState.detail?.controls.first { $0.id.hasPrefix("copy.local/") })
        cli.status = .init(succeeded: true, output: Data(#"{"BackendState":"NeedsLogin"}"#.utf8))
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        await waitUntil { plugin.rowDescriptor.controlStyle == .button && plugin.rowState.isEnabled }
        plugin.handleAction(.invokeAction(controlID: localCopy.id))
        XCTAssertTrue(cli.copied.isEmpty)
        XCTAssertFalse(plugin.rowState.isOn)
    }

    func testLoginRequestsAndOpensTheDeviceAuthorizationURL() async throws {
        let cli = FakeCLI()
        cli.status = .init(succeeded: true, output: Data(#"{"BackendState":"NeedsLogin","AuthURL":"https://login.tailscale.com.example.com/a/fixture"}"#.utf8))
        cli.loginStatus = .init(succeeded: true, output: Data(#"{"BackendState":"NeedsLogin","AuthURL":"https://login.tailscale.com/a/fixture"}"#.utf8))
        let plugin = makePlugin(cli)
        let state = try context()
        defer { state.defaults.removePersistentDomain(forName: state.domain) }
        plugin.activate(context: state.context)
        defer { plugin.deactivate(reason: .disabled) }

        await waitUntil { plugin.rowDescriptor.controlStyle == .button }
        plugin.handleAction(.invokeAction(controlID: "execute"))
        await waitUntil { !cli.opened.isEmpty }
        XCTAssertEqual(cli.writes, [["up", "--timeout=10s"]])
        XCTAssertEqual(cli.opened.map(\.absoluteString), ["https://login.tailscale.com/a/fixture"])
    }

    func testPinPersistsAndDeviceCopyUsesCurrentSnapshot() async throws {
        let cli = FakeCLI()
        let plugin = makePlugin(cli)
        let state = try context()
        defer { state.defaults.removePersistentDomain(forName: state.domain) }
        plugin.activate(context: state.context)
        await waitUntil { plugin.rowState.isOn }
        let panel = try XCTUnwrap(plugin.rowState.detail?.secondaryPanel(controlID: "peers", optionID: "peer"))
        let copy = try XCTUnwrap(panel.controls.first { $0.id.hasSuffix("/server.example.ts.net") })
        plugin.handleAction(.invokeAction(controlID: copy.id))
        XCTAssertEqual(cli.copied, ["server.example.ts.net"])
        let pin = try XCTUnwrap(panel.controls.first { $0.id.hasPrefix("pin.") })
        plugin.handleAction(.invokeAction(controlID: pin.id))
        plugin.deactivate(reason: .disabled)

        let reloaded = makePlugin(cli)
        reloaded.activate(context: state.context)
        defer { reloaded.deactivate(reason: .disabled) }
        await waitUntil { reloaded.rowState.isOn }
        XCTAssertNotNil(reloaded.rowState.detail?.secondaryPanel(controlID: "favorites", optionID: "peer"))
    }

    func testExitNodeShowsVerifiedStateAndCanBeDisabled() async throws {
        let cli = FakeCLI()
        let plugin = makePlugin(cli)
        let state = try context()
        defer { state.defaults.removePersistentDomain(forName: state.domain) }
        plugin.activate(context: state.context)
        defer { plugin.deactivate(reason: .disabled) }
        await waitUntil { plugin.rowState.isOn }
        let panel = try XCTUnwrap(plugin.rowState.detail?.secondaryPanel(controlID: "exit-nodes", optionID: "peer"))
        let select = try XCTUnwrap(panel.controls.first)

        plugin.handleAction(.invokeAction(controlID: select.id))
        await waitUntil { cli.writes.count == 1 && plugin.rowState.isEnabled }
        XCTAssertEqual(cli.writes, [["set", "--exit-node=100.64.0.2"]])
        XCTAssertNotNil(plugin.rowState.errorMessage)

        cli.applyExitChange = true
        plugin.handleAction(.invokeAction(controlID: select.id))
        await waitUntil { cli.writes.count == 2 && plugin.rowState.isEnabled }
        XCTAssertNil(plugin.rowState.errorMessage)
        XCTAssertNil(plugin.rowState.detail?.secondaryPanel(controlID: "exit-nodes", optionID: "peer"))
        let disable = try XCTUnwrap(plugin.rowState.detail?.controls.first { $0.id == "exit-off" && $0.isEnabled })
        plugin.handleAction(.invokeAction(controlID: disable.id))
        await waitUntil { cli.writes.count == 3 && plugin.rowState.isEnabled }
        XCTAssertEqual(cli.writes.last, ["set", "--exit-node="])
        XCTAssertNil(plugin.rowState.errorMessage)
        XCTAssertNotNil(plugin.rowState.detail?.secondaryPanel(controlID: "exit-nodes", optionID: "peer"))
    }

    func testPingRecognizesRelayEvenWhenDirectConnectionFails() {
        let relay = "pong from server (100.64.0.2) via DERP(fra) in 40ms\n"
        let direct = "pong from server (100.64.0.2) via [2001:db8::1]:41641 in 4ms\n"
        XCTAssertEqual(TailscalePingResult(.init(succeeded: false, output: Data(relay.utf8),
                                                error: "direct connection not established")), .derp)
        XCTAssertEqual(TailscalePingResult(.init(succeeded: true, output: Data((relay + direct).utf8))), .direct)
        XCTAssertEqual(TailscalePingResult(.init(succeeded: false, error: "no reply")), .noReply)
        XCTAssertEqual(TailscalePingResult(.init(succeeded: false, error: "permission denied")), .failed)
    }

    private func makePlugin(_ cli: FakeCLI) -> TailscalePlugin {
        TailscalePlugin(locateCLI: { "/fake/tailscale" }, runCLI: { _, arguments in
            cli.run(arguments)
        }, copy: { cli.copied.append($0) }, openURL: {
            cli.opened.append($0)
            return true
        })
    }

    private func context() throws -> (context: PluginRuntimeContext, defaults: UserDefaults, domain: String) {
        let domain = "TailscalePluginTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let storage = UserDefaultsPluginStorage(pluginID: "tailscale", userDefaults: defaults)
        return (PluginRuntimeContext(pluginID: "tailscale", storage: storage), defaults, domain)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(15))
        }
        XCTAssertTrue(condition(), "Expected plugin state did not arrive")
    }
}

private final class FakeCLI {
    var status = FakeCLI.connected()
    var writes: [[String]] = []
    var copied: [String] = []
    var opened: [URL] = []
    var loginStatus: TailscaleCommandResult?
    var applyExitChange = false

    func run(_ arguments: [String]) -> TailscaleCommandResult {
        if arguments == ["status", "--json"] { return status }
        writes.append(arguments)
        if arguments == ["up", "--timeout=10s"], let loginStatus { status = loginStatus }
        if applyExitChange, arguments.first == "set" {
            status = Self.connected(exit: arguments.last != "--exit-node=")
        }
        return .init(succeeded: true)
    }

    private static func connected(exit: Bool = false) -> TailscaleCommandResult {
        let exitNode = exit ? #""ExitNodeStatus":{"ID":"peer","Online":true},"# : ""
        let json = """
            {"BackendState":"Running",\(exitNode)
             "Self":{"ID":"local","TailscaleIPs":["100.64.0.1"]},
             "Peer":{"nodekey:example":{"ID":"peer","HostName":"server","DNSName":"server.example.ts.net.",
                     "Online":true,"ExitNodeOption":true,"TailscaleIPs":["100.64.0.2"]}}}
            """
        return .init(succeeded: true, output: Data(json.utf8))
    }
}
