import MacToolsAppIntents
import MacToolsPluginKit
import XCTest
@testable import MacTools

@MainActor
final class MacToolsAppIntentCoordinatorTests: XCTestCase {

    func testCatalogConservativelyFiltersRiskModeAutomationExposureAndPortability() throws {
        let registry = ActionRegistry()
        let provider = AppIntentActionTestProvider()
        provider.excludedActionIDs = ["excluded"]
        provider.unavailableActionIDs = ["unavailable"]

        let eligible = provider.definition(actionID: "eligible")
        let unavailable = provider.definition(actionID: "unavailable")
        let confirmation = provider.definition(
            actionID: "confirmation",
            risk: .confirmationRequired
        )
        let interactive = provider.definition(
            actionID: "interactive",
            capabilities: [.automatic, .foregroundInteractive]
        )
        let attendedOnly = provider.definition(
            actionID: "attended-only",
            capabilities: [.background, .foregroundInteractive]
        )
        let excluded = provider.definition(actionID: "excluded")
        let local = provider.definition(
            actionID: "local",
            parameters: [
                ActionParameterDefinition(
                    id: "device",
                    title: "Device",
                    kind: .string,
                    portability: .localOnly
                ),
            ]
        )
        let localReference = ActionReference(
            key: local.key,
            parameters: try ActionParameterSet(["device": .string("this-mac")])
        )
        let definitions = [
            eligible,
            unavailable,
            confirmation,
            interactive,
            attendedOnly,
            excluded,
            local,
        ]
        let entries = definitions.map { definition in
            ActionCatalogEntry(
                reference: definition.key == local.key
                    ? localReference
                    : ActionReference(key: definition.key),
                title: definition.title
            )
        }

        XCTAssertTrue(registry.synchronize([
            provider.registration(definitions: definitions, entries: entries),
        ]).isEmpty)

        let catalog = MacToolsAppIntentActionCatalog(registry: registry)
        XCTAssertEqual(
            catalog.actions(includeUnavailable: false).map(\.title),
            [eligible.title]
        )
        XCTAssertEqual(
            Set(catalog.actions(includeUnavailable: true).map(\.title)),
            Set([eligible.title, unavailable.title])
        )
    }

    func testRuntimeWaitsForRegistryPreparationBeforeReturningChoices() async {
        let runtime = MacToolsAppIntentRuntime()
        var providerCallCount = 0
        var activityCount = 0
        let expected = MacToolsAppIntentAction(
            id: "ready",
            title: "Ready",
            systemImage: "checkmark"
        )
        runtime.configure(
            actionProvider: { _ in
                providerCallCount += 1
                return [expected]
            },
            actionExecutor: { _ in .succeeded(message: "Done") },
            activityHandler: { activityCount += 1 }
        )

        let choices = Task { @MainActor in
            await runtime.actions(includeUnavailable: false)
        }
        await Task.yield()
        XCTAssertEqual(providerCallCount, 0)
        // Spotlight parameter lookups must suppress the reopen Settings recovery.
        XCTAssertEqual(activityCount, 1)

        runtime.markReady()
        let resolvedChoices = await choices.value
        XCTAssertEqual(resolvedChoices, [expected])
        XCTAssertEqual(providerCallCount, 1)
    }

    func testCircuitBreakerSharesBudgetAcrossInstancesAndRecoversAfterWindow() async {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacToolsAppIntentCircuitBreakerTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let stateURL = directoryURL.appendingPathComponent("state.json")
        let clock = AppIntentCircuitBreakerTestClock(Date(timeIntervalSince1970: 1_000))
        let first = MacToolsAppIntentCircuitBreaker(
            stateURL: stateURL,
            window: 10,
            maximumInvocationCountPerAction: 2,
            maximumGlobalInvocationCount: 4,
            now: { clock.value }
        )
        let second = MacToolsAppIntentCircuitBreaker(
            stateURL: stateURL,
            window: 10,
            maximumInvocationCountPerAction: 2,
            maximumGlobalInvocationCount: 4,
            now: { clock.value }
        )

        let firstAdmission = await first.admitInvocation(actionIdentifier: "same")
        let secondAdmission = await second.admitInvocation(actionIdentifier: "same")
        let blockedAdmission = await first.admitInvocation(actionIdentifier: "same")
        XCTAssertEqual(firstAdmission, .admitted)
        XCTAssertEqual(secondAdmission, .admitted)
        XCTAssertEqual(blockedAdmission, .rateLimited)

        clock.advance(by: 11)
        let recoveredAdmission = await second.admitInvocation(actionIdentifier: "same")
        XCTAssertEqual(recoveredAdmission, .admitted)
    }

    func testCircuitBreakerAppliesGlobalEmergencyCapToDistinctActions() async {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacToolsAppIntentCircuitBreakerGlobal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let breaker = MacToolsAppIntentCircuitBreaker(
            stateURL: directoryURL.appendingPathComponent("state.json"),
            maximumInvocationCountPerAction: 2,
            maximumGlobalInvocationCount: 3
        )

        for index in 0..<3 {
            let admission = await breaker.admitInvocation(actionIdentifier: "action-\(index)")
            XCTAssertEqual(admission, .admitted)
        }
        let blocked = await breaker.admitInvocation(actionIdentifier: "action-3")
        XCTAssertEqual(blocked, .rateLimited)
    }

    func testExecutionUsesStableReferenceAppIntentSourceAndBackgroundMode() async throws {
        let registry = ActionRegistry()
        let provider = AppIntentActionTestProvider()
        let definition = provider.definition(actionID: "execute")
        let reference = ActionReference(key: definition.key)
        registry.synchronize([provider.registration(
            definitions: [definition],
            entries: [ActionCatalogEntry(reference: reference, title: definition.title)]
        )])
        let runtime = MacToolsAppIntentRuntime()
        let coordinator = MacToolsAppIntentCoordinator(
            registry: registry,
            executor: ActionExecutor(registry: registry),
            runtime: runtime,
            circuitBreaker: AllowingAppIntentCircuitBreaker()
        )
        coordinator.beginPreparation()
        coordinator.actionRegistryDidBecomeReady()
        let actions = await runtime.actions(includeUnavailable: false)
        let action = try XCTUnwrap(actions.first)

        let result = await runtime.execute(identifier: action.id)
        XCTAssertEqual(result, .succeeded(message: "Completed"))
        XCTAssertEqual(provider.lastInvocation?.reference, reference)
        XCTAssertEqual(provider.lastInvocation?.source, .appIntent)
        XCTAssertEqual(provider.lastInvocation?.mode, .background)
    }

    func testShortcutParametersRefreshOnlyWhenOfferedActionsChange() {
        let registry = ActionRegistry()
        let provider = AppIntentActionTestProvider()
        let definition = provider.definition(actionID: "eligible")
        let reference = ActionReference(key: definition.key)
        registry.synchronize([provider.registration(
            definitions: [definition],
            entries: [ActionCatalogEntry(reference: reference, title: definition.title)]
        )])
        var refreshCount = 0
        let coordinator = MacToolsAppIntentCoordinator(
            registry: registry,
            executor: ActionExecutor(registry: registry),
            runtime: MacToolsAppIntentRuntime(),
            circuitBreaker: AllowingAppIntentCircuitBreaker(),
            refreshShortcutParameters: { refreshCount += 1 }
        )
        coordinator.beginPreparation()
        coordinator.actionRegistryDidBecomeReady()
        XCTAssertEqual(refreshCount, 1)

        // Plugin state churn invalidates availability without changing the offered actions.
        for _ in 0..<5 {
            registry.invalidateAvailability()
            coordinator.actionCatalogDidChange()
        }
        XCTAssertEqual(refreshCount, 1)

        provider.unavailableActionIDs = [definition.key.actionID]
        coordinator.actionCatalogDidChange()
        XCTAssertEqual(refreshCount, 2)
    }

    func testExecutionReportsCurrentAvailabilityFailureForPreviouslyResolvedEntity() async throws {
        let registry = ActionRegistry()
        let provider = AppIntentActionTestProvider()
        let definition = provider.definition(actionID: "permission")
        let reference = ActionReference(key: definition.key)
        registry.synchronize([provider.registration(
            definitions: [definition],
            entries: [ActionCatalogEntry(reference: reference, title: definition.title)]
        )])
        let runtime = MacToolsAppIntentRuntime()
        let coordinator = MacToolsAppIntentCoordinator(
            registry: registry,
            executor: ActionExecutor(registry: registry),
            runtime: runtime,
            circuitBreaker: AllowingAppIntentCircuitBreaker()
        )
        coordinator.beginPreparation()
        coordinator.actionRegistryDidBecomeReady()
        let actions = await runtime.actions(includeUnavailable: false)
        let action = try XCTUnwrap(actions.first)
        provider.unavailableActionIDs = [definition.key.actionID]

        let result = await runtime.execute(identifier: action.id)
        XCTAssertEqual(result, .failed(message: "Permission required"))
        XCTAssertNil(provider.lastInvocation)
    }

    func testExecutionRejectsEligibleButUnpublishedReference() async throws {
        let registry = ActionRegistry()
        let provider = AppIntentActionTestProvider()
        let definition = provider.definition(actionID: "unpublished")
        let reference = ActionReference(key: definition.key)
        registry.synchronize([provider.registration(definitions: [definition], entries: [])])
        let runtime = MacToolsAppIntentRuntime()
        let coordinator = MacToolsAppIntentCoordinator(
            registry: registry,
            executor: ActionExecutor(registry: registry),
            runtime: runtime,
            circuitBreaker: AllowingAppIntentCircuitBreaker()
        )
        coordinator.beginPreparation()
        coordinator.actionRegistryDidBecomeReady()
        let identifier = try XCTUnwrap(AppIntentActionIdentifierCodec.encode(reference))

        let resolved = await runtime.actions(for: [identifier])
        XCTAssertTrue(resolved.isEmpty)
        let result = await runtime.execute(identifier: identifier)
        XCTAssertEqual(result, .failed(message: FeatureL10n.string("操作不可用。")))
        XCTAssertNil(provider.lastInvocation)
    }

    func testExecutionStopsWhenTheCircuitBreakerRejectsReentry() async throws {
        let registry = ActionRegistry()
        let provider = AppIntentActionTestProvider()
        let definition = provider.definition(actionID: "loop")
        let reference = ActionReference(key: definition.key)
        registry.synchronize([provider.registration(
            definitions: [definition],
            entries: [ActionCatalogEntry(reference: reference, title: definition.title)]
        )])
        let runtime = MacToolsAppIntentRuntime()
        let coordinator = MacToolsAppIntentCoordinator(
            registry: registry,
            executor: ActionExecutor(registry: registry),
            runtime: runtime,
            circuitBreaker: RejectingAppIntentCircuitBreaker()
        )
        coordinator.beginPreparation()
        coordinator.actionRegistryDidBecomeReady()
        let actions = await runtime.actions(includeUnavailable: false)
        let action = try XCTUnwrap(actions.first)

        let result = await runtime.execute(identifier: action.id)

        XCTAssertEqual(
            result,
            .failed(message: FeatureL10n.string(
                "短时间内运行的 MacTools 操作过多。为防止循环，已停止执行。"
            ))
        )
        XCTAssertNil(provider.lastInvocation)
    }

    func testExecutionRechecksEligibilityAfterCircuitBreakerSuspension() async throws {
        let registry = ActionRegistry()
        let provider = AppIntentActionTestProvider()
        let eligible = provider.definition(actionID: "eligibility-race")
        let reference = ActionReference(key: eligible.key)
        registry.synchronize([provider.registration(
            definitions: [eligible],
            entries: [ActionCatalogEntry(reference: reference, title: eligible.title)]
        )])
        let runtime = MacToolsAppIntentRuntime()
        let breaker = PausingAppIntentCircuitBreaker()
        let coordinator = MacToolsAppIntentCoordinator(
            registry: registry,
            executor: ActionExecutor(registry: registry),
            runtime: runtime,
            circuitBreaker: breaker
        )
        coordinator.beginPreparation()
        coordinator.actionRegistryDidBecomeReady()
        let actions = await runtime.actions(includeUnavailable: false)
        let action = try XCTUnwrap(actions.first)

        let execution = Task { @MainActor in
            await runtime.execute(identifier: action.id)
        }
        await breaker.waitUntilAdmissionIsPending()
        let confirmationRequired = provider.definition(
            actionID: "eligibility-race",
            risk: .confirmationRequired
        )
        registry.synchronize([provider.registration(
            definitions: [confirmationRequired],
            entries: [ActionCatalogEntry(
                reference: reference,
                title: confirmationRequired.title
            )]
        )])
        await breaker.resumeAdmission()

        let result = await execution.value
        XCTAssertEqual(result, .failed(message: FeatureL10n.string("操作不可用。")))
        XCTAssertNil(provider.lastInvocation)
    }
}

private actor AllowingAppIntentCircuitBreaker: MacToolsAppIntentCircuitBreaking {
    func admitInvocation(
        actionIdentifier _: String
    ) async -> MacToolsAppIntentCircuitBreakerAdmission { .admitted }
}

private actor RejectingAppIntentCircuitBreaker: MacToolsAppIntentCircuitBreaking {
    func admitInvocation(
        actionIdentifier _: String
    ) async -> MacToolsAppIntentCircuitBreakerAdmission { .rateLimited }
}

private actor PausingAppIntentCircuitBreaker: MacToolsAppIntentCircuitBreaking {
    private var admissionContinuation: CheckedContinuation<
        MacToolsAppIntentCircuitBreakerAdmission,
        Never
    >?
    private var pendingWaiters: [CheckedContinuation<Void, Never>] = []

    func admitInvocation(
        actionIdentifier _: String
    ) async -> MacToolsAppIntentCircuitBreakerAdmission {
        pendingWaiters.forEach { $0.resume() }
        pendingWaiters.removeAll()
        return await withCheckedContinuation { continuation in
            admissionContinuation = continuation
        }
    }

    func waitUntilAdmissionIsPending() async {
        guard admissionContinuation == nil else { return }
        await withCheckedContinuation { pendingWaiters.append($0) }
    }

    func resumeAdmission() {
        admissionContinuation?.resume(returning: .admitted)
        admissionContinuation = nil
    }
}

private final class AppIntentCircuitBreakerTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) {
        self.date = date
    }

    var value: Date {
        lock.withLock { date }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { date = date.addingTimeInterval(interval) }
    }
}

@MainActor
private final class AppIntentActionTestProvider {
    let providerID = "app-intent-tests"
    var excludedActionIDs: Set<String> = []
    var unavailableActionIDs: Set<String> = []
    private(set) var lastInvocation: ActionInvocation?

    func reference(actionID: String) -> ActionReference {
        ActionReference(key: ActionKey(providerID: providerID, actionID: actionID))
    }

    func definition(
        actionID: String,
        title: String? = nil,
        schemaVersion: Int = 1,
        risk: ActionRisk = .safe,
        capabilities: ActionExecutionCapabilities = [
            .automatic,
            .background,
            .foregroundInteractive,
        ],
        parameters: [ActionParameterDefinition] = []
    ) -> ActionDefinition {
        ActionDefinition(
            key: ActionKey(providerID: providerID, actionID: actionID),
            parameterSchemaVersion: schemaVersion,
            title: title ?? actionID,
            description: "Test action",
            systemImage: "bolt",
            parameters: parameters,
            risk: risk,
            confirmation: risk == .confirmationRequired
                ? ActionConfirmation(
                    title: "Confirm",
                    message: "Continue?",
                    confirmButtonTitle: "Run"
                )
                : nil,
            capabilities: capabilities
        )
    }

    func registration(
        definitions: [ActionDefinition],
        entries: [ActionCatalogEntry],
        migrate: @escaping (ActionReference, Int) -> ActionReference? = { reference, version in
            reference.schemaVersion == version ? reference : nil
        }
    ) -> ActionProviderRegistration {
        ActionProviderRegistration(
            providerID: providerID,
            identity: ObjectIdentifier(self),
            definitions: definitions,
            catalogEntries: entries,
            availability: { [weak self] reference in
                self?.unavailableActionIDs.contains(reference.key.actionID) == true
                    ? .unavailable("Permission required")
                    : .available
            },
            exposurePolicy: { [weak self] reference, surface in
                guard surface == .appIntents else { return .automatic }
                return self?.excludedActionIDs.contains(reference.key.actionID) == true
                    ? .excluded
                    : .automatic
            },
            migrate: migrate,
            begin: { [weak self] invocation in
                self?.lastInvocation = invocation
                return .success(ActionExecutionHandle(operation: {
                    .succeeded(message: "Completed")
                }))
            }
        )
    }
}
