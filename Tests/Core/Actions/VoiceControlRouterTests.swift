import MacToolsPluginKit
import SwiftUI
import XCTest
@testable import MacTools

@MainActor
final class VoiceControlRouterTests: XCTestCase {
    func testDiscoveryExecutesCanonicalActionAndRejectsInventedOrRevokedIDs() async throws {
        let fixture = Fixture()
        let context = fixture.router.context(owner: "voice-control")
        let session = try XCTUnwrap(context.beginSession())
        let reply = await context.request(.search("fixture"), sessionID: session)
        let command = try XCTUnwrap(reply.capabilities.first { $0.kind == .action })
        let result = await context.request(.perform(capabilityID: command.id, parameters: .empty), sessionID: session)
        XCTAssertEqual(result.status, "ok")
        XCTAssertEqual(fixture.plugin.executions, 1)
        let invented = await context.request(.perform(capabilityID: "invented", parameters: .empty), sessionID: session)
        XCTAssertEqual(invented.status, "staleCapability")
        context.endSession(session)
        let stopped = await context.request(.perform(capabilityID: command.id, parameters: .empty), sessionID: session)
        XCTAssertEqual(stopped.status, "sessionEnded")
        XCTAssertEqual(fixture.plugin.executions, 1)
    }

    func testExcludedProvidersAndReplacedInstancesCannotBeUsed() async throws {
        let fixture = Fixture()
        let context = fixture.router.context(owner: "voice-control")
        let excluded = try XCTUnwrap(context.beginSession(excludingPluginIDs: ["fixture"]))
        let empty = await context.request(.search(""), sessionID: excluded)
        XCTAssertTrue(empty.capabilities.isEmpty)
        let session = try XCTUnwrap(context.beginSession())
        let reply = await context.request(.search(""), sessionID: session)
        let command = try XCTUnwrap(reply.capabilities.first { $0.kind == .action })
        fixture.plugin = VoiceFixturePlugin()
        fixture.register()
        let result = await context.request(.perform(capabilityID: command.id, parameters: .empty), sessionID: session)
        XCTAssertEqual(result.status, "staleCapability")
        XCTAssertEqual(fixture.plugin.executions, 0)
        XCTAssertNil(fixture.router.context(owner: "other-plugin").beginSession())
    }

    func testTypedParametersAreValidatedByCanonicalExecutor() async throws {
        let fixture = Fixture()
        fixture.plugin.parameterized = true
        fixture.register()
        let context = fixture.router.context(owner: "voice-control")
        let session = try XCTUnwrap(context.beginSession())
        let reply = await context.request(.search(""), sessionID: session)
        let command = try XCTUnwrap(reply.capabilities.first { !$0.parameters.isEmpty })
        let invalid = await context.request(.perform(capabilityID: command.id,
            parameters: try ActionParameterSet(["value": .string("wrong type")])), sessionID: session)
        XCTAssertEqual(invalid.status, "unavailable")
        XCTAssertEqual(fixture.plugin.executions, 0)
        let valid = await context.request(.perform(capabilityID: command.id,
            parameters: try ActionParameterSet(["value": .integer(35)])), sessionID: session)
        XCTAssertEqual(valid.status, "ok")
        XCTAssertEqual(fixture.plugin.executions, 1)
    }

    func testPrivateQueryRequiresNativeApprovalAndStopPreventsRead() async throws {
        let fixture = Fixture()
        fixture.plugin.privateQuery = true
        let context = fixture.router.context(owner: "voice-control")
        let session = try XCTUnwrap(context.beginSession())
        let reply = await context.request(.search(""), sessionID: session)
        let query = try XCTUnwrap(reply.capabilities.first { $0.kind == .query })
        fixture.confirmation.operation = { context.endSession(session); return true }
        let result = await context.request(.perform(capabilityID: query.id, parameters: .empty), sessionID: session)
        XCTAssertEqual(result.status, "cancelled")
        XCTAssertEqual(fixture.confirmation.requests, 1)
        XCTAssertEqual(fixture.plugin.reads, 0)
    }

    func testQueryPolicyChangesDuringApprovalInvalidateRequest() async throws {
        let fixture = Fixture()
        fixture.plugin.privateQuery = true
        let context = fixture.router.context(owner: "voice-control")
        let session = try XCTUnwrap(context.beginSession())
        let reply = await context.request(.search(""), sessionID: session)
        let query = try XCTUnwrap(reply.capabilities.first { $0.kind == .query })
        fixture.confirmation.operation = { fixture.plugin.privateQuery = false; return true }
        let stale = await context.request(.perform(capabilityID: query.id, parameters: .empty), sessionID: session)
        XCTAssertEqual(stale.status, "staleCapability")
        XCTAssertEqual(fixture.plugin.reads, 0)
        let fresh = await context.request(.search(""), sessionID: session)
        let freshQuery = try XCTUnwrap(fresh.capabilities.first { $0.kind == .query })
        let value = await context.request(.perform(capabilityID: freshQuery.id, parameters: .empty), sessionID: session)
        XCTAssertEqual(value.payload, "{\"value\":35}")
    }

    func testRevokedContextCannotCreateAnotherSession() throws {
        let fixture = Fixture()
        let context = fixture.router.context(owner: "voice-control")
        XCTAssertNotNil(context.beginSession())
        fixture.router.revoke(owner: "voice-control")
        XCTAssertNil(context.beginSession())
    }

    func testExposureRevokedDuringApprovalPreventsMutation() async throws {
        let fixture = Fixture()
        fixture.plugin.confirmAction = true
        fixture.register()
        let context = fixture.router.context(owner: "voice-control")
        let session = try XCTUnwrap(context.beginSession())
        let reply = await context.request(.search(""), sessionID: session)
        let command = try XCTUnwrap(reply.capabilities.first { $0.kind == .action })
        fixture.confirmation.operation = { fixture.plugin.excluded = true; return true }
        let result = await context.request(.perform(capabilityID: command.id, parameters: .empty), sessionID: session)
        XCTAssertEqual(result.status, "unavailable")
        XCTAssertEqual(fixture.plugin.executions, 0)
    }

    func testStopDuringActionConfirmationPreventsMutation() async throws {
        let fixture = Fixture()
        fixture.plugin.confirmAction = true
        fixture.register()
        let context = fixture.router.context(owner: "voice-control")
        let session = try XCTUnwrap(context.beginSession())
        let reply = await context.request(.search(""), sessionID: session)
        let command = try XCTUnwrap(reply.capabilities.first { $0.kind == .action })
        fixture.confirmation.operation = { context.endSession(session); return true }
        _ = await context.request(.perform(capabilityID: command.id, parameters: .empty), sessionID: session)
        XCTAssertEqual(fixture.plugin.executions, 0)
    }

    func testApplicationsOpenWithoutLauncherPluginsAndKeepSessionPermissionBoundary() async throws {
        let fixture = Fixture()
        fixture.applications.targets = [
            .init(name: "Google Chrome", url: URL(fileURLWithPath: "/Applications/Google Chrome.app"), bundleIdentifier: "com.google.Chrome"),
            .init(name: "Safari", url: URL(fileURLWithPath: "/Applications/Safari.app"), bundleIdentifier: "com.apple.Safari")
        ]
        let context = fixture.router.context(owner: "voice-control")
        XCTAssertTrue(context.providers().contains { $0.id == VoiceControlRouter.applicationProviderID })
        let session = try XCTUnwrap(context.beginSession())
        let reply = await context.request(.search("Chrome browser"), sessionID: session)
        let app = try XCTUnwrap(reply.capabilities.first { $0.title.contains("Google Chrome") })
        XCTAssertFalse(reply.capabilities.contains { $0.title.contains("Safari") })
        let invalid = await context.request(.perform(capabilityID: app.id,
            parameters: try ActionParameterSet(["path": .string("/tmp/untrusted.app")])), sessionID: session)
        XCTAssertEqual(invalid.status, "invalidParameters")
        XCTAssertTrue(fixture.applications.opened.isEmpty)
        let result = await context.request(.perform(capabilityID: app.id, parameters: .empty), sessionID: session)
        XCTAssertEqual(result.status, "ok")
        XCTAssertEqual(fixture.applications.opened.map(\.name), ["Google Chrome"])
        let excluded = try XCTUnwrap(context.beginSession(excludingPluginIDs: [VoiceControlRouter.applicationProviderID]))
        let reads = fixture.applications.reads
        let denied = await context.request(.search("Chrome"), sessionID: excluded)
        XCTAssertFalse(denied.capabilities.contains { $0.title.contains("Chrome") })
        XCTAssertEqual(fixture.applications.reads, reads)
        let reused = await context.request(.perform(capabilityID: app.id, parameters: .empty), sessionID: excluded)
        XCTAssertEqual(reused.status, "staleCapability")
        XCTAssertEqual(fixture.applications.opened.count, 1)
    }

    func testStopDuringApplicationDiscoveryCannotIssueCapabilities() async throws {
        let fixture = Fixture()
        let context = fixture.router.context(owner: "voice-control")
        let session = try XCTUnwrap(context.beginSession())
        var pending: CheckedContinuation<[VoiceApplicationTarget], Never>?
        fixture.applications.operation = { await withCheckedContinuation { pending = $0 } }
        let task = Task { await context.request(.search("Safari"), sessionID: session) }
        for _ in 0..<100 where pending == nil { await Task.yield() }
        let continuation = try XCTUnwrap(pending)
        context.endSession(session)
        continuation.resume(returning: [.init(name: "Safari", url: URL(fileURLWithPath: "/Applications/Safari.app"), bundleIdentifier: "com.apple.Safari")])
        let result = await task.value
        XCTAssertEqual(result.status, "sessionEnded")
        XCTAssertTrue(result.capabilities.isEmpty)
        XCTAssertTrue(fixture.applications.opened.isEmpty)
    }

    func testOwnerExposesOnlyDeclaredFixedSelfControlsWithCanonicalApproval() async throws {
        let fixture = Fixture()
        fixture.owner.voiceSelfActionIDs = ["change"]
        fixture.owner.confirmAction = true
        fixture.register()
        let context = fixture.router.context(owner: "voice-control")
        let session = try XCTUnwrap(context.beginSession(excludingPluginIDs: ["fixture"]))
        let reply = await context.request(.search("fixture"), sessionID: session)
        XCTAssertEqual(reply.capabilities.count, 1, "Owner features, queries, and undeclared actions stay private")
        let command = try XCTUnwrap(reply.capabilities.first)
        XCTAssertTrue(command.requiresConfirmation)
        fixture.owner.voiceSelfActionIDs = []
        let revoked = await context.request(.perform(capabilityID: command.id, parameters: .empty), sessionID: session)
        XCTAssertEqual(revoked.status, "unavailable")
        XCTAssertEqual(fixture.owner.executions, 0)
        fixture.owner.voiceSelfActionIDs = ["change"]
        let result = await context.request(.perform(capabilityID: command.id, parameters: .empty), sessionID: session)
        XCTAssertEqual(result.status, "ok")
        XCTAssertEqual(fixture.confirmation.requests, 1)
        XCTAssertEqual(fixture.owner.executions, 1)
    }
}

@MainActor
private final class VoiceFixtureApplications: VoiceApplicationControlling {
    var targets: [VoiceApplicationTarget] = []
    var opened: [VoiceApplicationTarget] = []
    var reads = 0
    var operation: (() async -> [VoiceApplicationTarget])?
    func applications() async -> [VoiceApplicationTarget] {
        reads += 1
        return if let operation { await operation() } else { targets }
    }
    func open(_ target: VoiceApplicationTarget) async throws { opened.append(target) }
}

@MainActor
private final class VoiceFixtureConfirmation: ActionConfirmationRequesting {
    var requests = 0
    var operation: () async -> Bool = { true }
    func confirm(_ request: ActionConfirmationRequest) async -> Bool {
        requests += 1
        return await operation()
    }
}

@MainActor
private final class Fixture {
    let registry = ActionRegistry()
    let confirmation = VoiceFixtureConfirmation()
    let applications = VoiceFixtureApplications()
    var plugin = VoiceFixturePlugin()
    let owner = VoiceFixturePlugin(id: "voice-control")
    lazy var router = VoiceControlRouter(registry: registry,
        executor: ActionExecutor(registry: registry, confirmationService: confirmation),
        confirmation: confirmation, plugins: { [unowned self] in [plugin, owner] }, openFeature: { _ in }, applications: applications)
    init() { register() }
    func register() {
        registry.synchronize([plugin, owner].map { provider in .init(providerID: provider.metadata.id, identity: ObjectIdentifier(provider),
            definitions: provider.actionDefinitions, catalogEntries: provider.actionCatalogEntries,
            availability: { _ in .available }, exposurePolicy: { _, _ in provider.excluded ? .excluded : .automatic }, begin: { invocation in
                .success(ActionExecutionHandle { provider.executions += 1; return .succeeded() })
            }) })
    }
}

@MainActor
private final class VoiceFixturePlugin: MacToolsPlugin, PluginActionProviding,
    PluginVoiceQueryProviding, PluginVoiceParameterizedActionProviding, PluginVoiceSelfActionProviding {
    let metadata: PluginMetadata
    init(id: String = "fixture") {
        metadata = PluginMetadata(id: id, title: "Fixture", iconName: "bolt", iconTint: .blue,
                                  order: 0, defaultDescription: "Fixture controls")
    }
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var excluded = false
    var parameterized = false
    var confirmAction = false
    var privateQuery = false
    var executions = 0
    var reads = 0
    var voiceParameterizedActionIDs: Set<String> { parameterized ? ["change"] : [] }
    var voiceSelfActionIDs: Set<String> = []
    var actionDefinitions: [ActionDefinition] {
        [.init(key: .init(providerID: metadata.id, actionID: "change"), title: "Change fixture",
               description: "A fixture command", systemImage: "bolt",
               parameters: parameterized ? [.init(id: "value", title: "Value", kind: .integer)] : [],
               risk: confirmAction ? .confirmationRequired : .safe,
               confirmation: confirmAction ? prompt : nil, capabilities: [.foregroundInteractive])]
    }
    var actionCatalogEntries: [ActionCatalogEntry] {
        parameterized ? [] : [.init(reference: .init(key: actionDefinitions[0].key), title: "Change fixture")]
    }
    var voiceQueries: [PluginVoiceQuery] {
        [.init(id: "state", title: "Fixture state", description: "Current value",
               includesPrivateContent: privateQuery, confirmation: privateQuery ? prompt : nil)]
    }
    var prompt: ActionConfirmation { .init(title: "Review", message: "Allow?", confirmButtonTitle: "Allow") }
    func readVoiceQuery(id: String) async throws -> String { reads += 1; return "{\"value\":35}" }
    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle { .init { .succeeded() } }
}
