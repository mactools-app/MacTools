import Foundation
import MacToolsPluginKit
import XCTest
@testable import MacTools

@MainActor
final class WorkflowRunnerTests: XCTestCase {
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "WorkflowRunnerTests.\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testRunnerExecutesSeriallyHonorsDelayAndContinuesAfterConfiguredFailure() async throws {
        let harness = try makeHarness(actionIDs: ["first", "second"])
        harness.provider.results["first"] = .failed(message: "provider-private-detail")
        let workflow = try saveWorkflow(
            in: harness.store,
            steps: [
                WorkflowStep(
                    reference: harness.reference("first"),
                    delaySeconds: 0.5,
                    errorPolicy: .continueRunning
                ),
                WorkflowStep(reference: harness.reference("second")),
            ]
        )

        let execution = try harness.runner.makeExecutionHandle(
            workflowID: workflow.id,
            source: .manual,
            mode: .foreground
        ).get()
        let result = await execution.actionHandle.result()
        let run = try XCTUnwrap(harness.store.history(workflowID: workflow.id).first)

        XCTAssertEqual(result, .failed(message: FeatureL10n.string("部分步骤失败。")))
        XCTAssertEqual(harness.provider.invocations.map(\.reference.key.actionID), ["first", "second"])
        XCTAssertEqual(harness.sleeper.requestedSeconds, [0.5])
        XCTAssertEqual(run.status, .failed)
        XCTAssertEqual(run.stepResults.map(\.status), [.failed, .succeeded])
        XCTAssertFalse(
            String(decoding: try JSONEncoder().encode(run), as: UTF8.self)
                .contains("provider-private-detail")
        )
    }

    func testSameWorkflowCannotStartTwiceUntilTrackedRunFinishes() async throws {
        let harness = try makeHarness(actionIDs: ["slow"])
        harness.provider.nonCooperativeActionIDs.insert("slow")
        let workflow = try saveWorkflow(
            in: harness.store,
            steps: [WorkflowStep(reference: harness.reference("slow"))]
        )
        let first = try harness.runner.makeExecutionHandle(
            workflowID: workflow.id,
            source: .manual,
            mode: .foreground
        ).get()

        guard case let .failure(error) = harness.runner.makeExecutionHandle(
            workflowID: workflow.id,
            source: .manual,
            mode: .foreground
        ) else {
            return XCTFail("Expected duplicate workflow run to be rejected")
        }
        XCTAssertEqual(error, .alreadyRunning)

        first.actionHandle.cancel()
        let result = await first.actionHandle.result()
        XCTAssertEqual(result, .cancelled)
    }

    func testExecutedSensitiveParametersAreRedactedFromPersistedHistory() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = WorkflowStore(userDefaults: defaults)
        let registry = ActionRegistry()
        let provider = WorkflowRunnerTestProvider(actionIDs: [], timeout: 30)
        let key = ActionKey(providerID: "sensitive-history", actionID: "authenticate")
        let secret = "history-execution-secret-\(UUID().uuidString)"
        let reference = ActionReference(
            key: key,
            parameters: try ActionParameterSet(["token": .string(secret)])
        )
        let definition = ActionDefinition(
            key: key,
            title: "Authenticate",
            description: "",
            systemImage: "key",
            parameters: [
                ActionParameterDefinition(
                    id: "token",
                    title: "Token",
                    kind: .string,
                    privacy: .sensitive
                ),
            ],
            capabilities: [.background]
        )
        registry.synchronize([
            ActionProviderRegistration(
                providerID: key.providerID,
                identity: ObjectIdentifier(provider),
                definitions: [definition],
                catalogEntries: [
                    ActionCatalogEntry(reference: reference, title: "Authenticate \(secret)"),
                ],
                availability: { _ in .available },
                begin: { _ in
                    .success(ActionExecutionHandle(operation: { .succeeded() }))
                }
            ),
        ])
        let executor = ActionExecutor(registry: registry)
        let runner = WorkflowRunner(store: store, registry: registry, executor: executor)
        let workflow = try saveWorkflow(
            in: store,
            steps: [WorkflowStep(reference: reference)]
        )

        let execution = try runner.makeExecutionHandle(
            workflowID: workflow.id,
            source: .manual,
            mode: .foreground
        ).get()
        _ = await execution.actionHandle.result()
        let run = try XCTUnwrap(store.history(workflowID: workflow.id).first)

        XCTAssertEqual(
            run.stepResults.first?.actionReference,
            ActionReference(key: key, schemaVersion: reference.schemaVersion)
        )
        XCTAssertFalse(
            String(
                decoding: try XCTUnwrap(defaults.data(forKey: "automation.history.v1")),
                as: UTF8.self
            ).contains(secret)
        )
    }

    func testCopiedDiagnosticsPreservePercentageWithoutLocalDisplay() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = WorkflowStore(userDefaults: defaults)
        let registry = ActionRegistry()
        let provider = WorkflowRunnerTestProvider(actionIDs: [], timeout: 30)
        let key = ActionKey(providerID: "display-test", actionID: "set")
        let monitorID = "private-monitor-identifier"
        let monitorLabel = "Private monitor label"
        let reference = ActionReference(
            key: key,
            parameters: try ActionParameterSet([
                DisplayActionTarget.parameterID: .string(monitorID),
                ActionPercentage.parameterID: .integer(23),
            ])
        )
        let definition = ActionDefinition(
            key: key,
            title: "Set Display Brightness",
            description: "",
            systemImage: "sun.max",
            parameters: [
                ActionParameterDefinition(id: DisplayActionTarget.parameterID, title: "Display", kind: .string,
                                          portability: .localOnly),
                ActionPercentage.parameter,
            ],
            capabilities: [.background]
        )
        registry.synchronize([
            ActionProviderRegistration(
                providerID: key.providerID,
                identity: ObjectIdentifier(provider),
                definitions: [definition],
                catalogEntries: [
                    ActionCatalogEntry(reference: reference,
                                       title: ActionPercentage.title(definition.title, target: monitorLabel, value: 23)),
                ],
                availability: { _ in .available },
                begin: { _ in .success(ActionExecutionHandle(operation: { .succeeded() })) }
            ),
        ])
        let runner = WorkflowRunner(store: store, registry: registry, executor: ActionExecutor(registry: registry))
        let workflow = try saveWorkflow(in: store, steps: [WorkflowStep(reference: reference)])
        let execution = try runner.makeExecutionHandle(workflowID: workflow.id, source: .manual, mode: .foreground).get()
        _ = await execution.actionHandle.result()

        let run = try XCTUnwrap(WorkflowStore(userDefaults: defaults).history(workflowID: workflow.id).first)
        let diagnostics = WorkflowRunPresentation.diagnosticText(run, registry: registry)
        XCTAssertTrue(diagnostics.contains(ActionPercentage.title(definition.title, value: 23)))
        XCTAssertFalse(diagnostics.contains(monitorLabel))
        let stored = String(decoding: try XCTUnwrap(defaults.data(forKey: "automation.history.v1")), as: UTF8.self)
        XCTAssertFalse(stored.contains(monitorID))
        XCTAssertFalse(stored.contains(monitorLabel))
    }

    func testStopOnErrorSkipsRemainingSteps() async throws {
        let harness = try makeHarness(actionIDs: ["first", "second"])
        harness.provider.results["first"] = .failed(message: "failure")
        let workflow = try saveWorkflow(
            in: harness.store,
            steps: [
                WorkflowStep(reference: harness.reference("first"), errorPolicy: .stop),
                WorkflowStep(reference: harness.reference("second")),
            ]
        )

        let execution = try harness.runner.makeExecutionHandle(
            workflowID: workflow.id,
            source: .manual,
            mode: .foreground
        ).get()
        _ = await execution.actionHandle.result()
        let run = try XCTUnwrap(harness.store.history(workflowID: workflow.id).first)

        XCTAssertEqual(harness.provider.invocations.map(\.reference.key.actionID), ["first"])
        XCTAssertEqual(run.stepResults.map(\.status), [.failed, .skipped])
    }

    func testCancellationDuringDelayMarksCurrentAndRemainingSteps() async throws {
        let harness = try makeHarness(actionIDs: ["first", "second"])
        harness.sleeper.shouldBlock = true
        let workflow = try saveWorkflow(
            in: harness.store,
            steps: [
                WorkflowStep(reference: harness.reference("first"), delaySeconds: 10),
                WorkflowStep(reference: harness.reference("second")),
            ]
        )
        let execution = try harness.runner.makeExecutionHandle(
            workflowID: workflow.id,
            source: .manual,
            mode: .foreground
        ).get()
        let resultTask = Task { @MainActor in await execution.actionHandle.result() }
        await harness.sleeper.waitUntilSleeping()

        execution.actionHandle.cancel()
        let result = await resultTask.value
        let run = try XCTUnwrap(harness.store.history(workflowID: workflow.id).first)

        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(run.status, .cancelled)
        XCTAssertEqual(run.stepResults.map(\.status), [.cancelled, .skipped])
        XCTAssertTrue(harness.provider.invocations.isEmpty)
    }

    func testNonCooperativeActionStillTimesOutAndReceivesCancellation() async throws {
        let harness = try makeHarness(actionIDs: ["slow"], timeout: 0.01)
        harness.provider.nonCooperativeActionIDs.insert("slow")
        let workflow = try saveWorkflow(
            in: harness.store,
            steps: [WorkflowStep(reference: harness.reference("slow"))]
        )
        let execution = try harness.runner.makeExecutionHandle(
            workflowID: workflow.id,
            source: .manual,
            mode: .foreground
        ).get()

        let result = await execution.actionHandle.result()
        harness.provider.resumeNonCooperativeActions()
        let run = try XCTUnwrap(harness.store.history(workflowID: workflow.id).first)

        XCTAssertEqual(
            result,
            .failed(message: FeatureL10n.string("工作流在失败步骤处停止。"))
        )
        XCTAssertEqual(run.stepResults.first?.status, .timedOut)
        XCTAssertTrue(harness.provider.cancelledActionIDs.contains("slow"))
    }

    func testMissingProviderDuringRunStopsAndPreservesStepReference() async throws {
        let harness = try makeHarness(actionIDs: ["first", "second"])
        harness.provider.onBegin["first"] = {
            harness.registry.synchronize([])
        }
        let second = harness.reference("second")
        let workflow = try saveWorkflow(
            in: harness.store,
            steps: [
                WorkflowStep(reference: harness.reference("first")),
                WorkflowStep(reference: second),
            ]
        )
        let execution = try harness.runner.makeExecutionHandle(
            workflowID: workflow.id,
            source: .manual,
            mode: .foreground
        ).get()

        _ = await execution.actionHandle.result()
        let run = try XCTUnwrap(harness.store.history(workflowID: workflow.id).first)

        XCTAssertEqual(run.stepResults.map(\.status), [.succeeded, .unavailable])
        XCTAssertEqual(harness.store.workflow(id: workflow.id)?.steps[1].reference, second)
    }

    func testPublishedWorkflowActionsRejectIndirectRecursiveInvocation() async throws {
        let harness = try makeHarness(actionIDs: [])
        let first = try saveWorkflow(in: harness.store, steps: [])
        let second = try harness.store.upsert(
            WorkflowDefinition(name: "第二个工作流")
        ).get()
        var firstRecursive = first
        firstRecursive.steps = [WorkflowStep(reference: second.actionReference)]
        _ = try harness.store.upsert(firstRecursive).get()
        var secondRecursive = second
        secondRecursive.steps = [WorkflowStep(reference: first.actionReference)]
        _ = try harness.store.upsert(secondRecursive).get()
        let controller = AutomationController(
            store: harness.store,
            registry: harness.registry,
            executor: harness.executor,
            runner: harness.runner
        )
        harness.registry.synchronize([controller.actionRegistration()])

        let outcome = await harness.executor.execute(
            ActionInvocation(
                reference: first.actionReference,
                source: .unifiedSearch,
                mode: .foreground
            )
        )

        guard case let .rejected(.unavailable(reason)) = outcome else {
            return XCTFail("Expected recursive workflow rejection, got \(outcome)")
        }
        XCTAssertEqual(reason, FeatureL10n.string("检测到递归工作流调用。"))
        XCTAssertTrue(harness.store.history().isEmpty)

        guard case let .failure(startError) = harness.runner.makeExecutionHandle(
            workflowID: first.id,
            source: .manual,
            mode: .foreground
        ) else {
            return XCTFail("Expected recursive workflow preflight rejection")
        }
        XCTAssertEqual(startError, .recursiveInvocation)
        XCTAssertTrue(harness.store.history().isEmpty)
    }

    func testBackgroundRunRejectsNestedForegroundOnlyActionBeforeStarting() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = WorkflowStore(userDefaults: defaults)
        let registry = ActionRegistry()
        let provider = WorkflowRunnerTestProvider(actionIDs: [], timeout: 30)
        let key = ActionKey(providerID: "foreground-only", actionID: "show")
        registry.synchronize([ActionProviderRegistration(
            providerID: key.providerID,
            identity: ObjectIdentifier(provider),
            definitions: [ActionDefinition(
                key: key,
                title: "Show",
                description: "",
                systemImage: "rectangle.on.rectangle",
                capabilities: [.foregroundInteractive]
            )],
            catalogEntries: [],
            availability: { _ in .available },
            begin: { _ in .success(ActionExecutionHandle(operation: { .succeeded() })) }
        )])
        let child = try saveWorkflow(
            in: store,
            steps: [WorkflowStep(reference: ActionReference(key: key))]
        )
        let parent = try store.upsert(WorkflowDefinition(
            name: "Parent",
            steps: [WorkflowStep(reference: child.actionReference)]
        )).get()
        let runner = WorkflowRunner(
            store: store,
            registry: registry,
            executor: ActionExecutor(registry: registry)
        )

        guard case let .failure(error) = runner.makeExecutionHandle(
            workflowID: parent.id,
            source: .automatic(ruleID: UUID(), triggerKind: "schedule"),
            mode: .background
        ) else {
            return XCTFail("Expected background preflight rejection")
        }
        XCTAssertEqual(error, .backgroundExecutionUnsupported)
        XCTAssertTrue(store.history().isEmpty)
    }

    func testAutomaticRunRejectsNestedConfirmationRequiredActionBeforeStarting() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = WorkflowStore(userDefaults: defaults)
        let registry = ActionRegistry()
        let provider = WorkflowRunnerTestProvider(actionIDs: [], timeout: 30)
        let key = ActionKey(providerID: "confirmation-required", actionID: "run")
        var invocationCount = 0
        let confirmationRegistration = ActionProviderRegistration(
            providerID: key.providerID,
            identity: ObjectIdentifier(provider),
            definitions: [ActionDefinition(
                key: key,
                title: "Confirm",
                description: "",
                systemImage: "exclamationmark.shield",
                risk: .confirmationRequired,
                confirmation: ActionConfirmation(
                    title: "Confirm",
                    message: "Confirm action",
                    confirmButtonTitle: "Run"
                ),
                capabilities: [.background, .foregroundInteractive]
            )],
            catalogEntries: [],
            availability: { _ in .available },
            begin: { _ in
                invocationCount += 1
                return .success(ActionExecutionHandle(operation: { .succeeded() }))
            }
        )
        registry.synchronize([confirmationRegistration])
        let child = try saveWorkflow(
            in: store,
            steps: [WorkflowStep(reference: ActionReference(key: key))]
        )
        let parent = try store.upsert(WorkflowDefinition(
            name: "Parent",
            steps: [WorkflowStep(reference: child.actionReference)]
        )).get()
        let executor = ActionExecutor(
            registry: registry,
            confirmationService: ApprovedActionConfirmationService()
        )
        let runner = WorkflowRunner(
            store: store,
            registry: registry,
            executor: executor
        )
        let controller = AutomationController(
            store: store,
            registry: registry,
            executor: executor,
            runner: runner
        )
        registry.synchronize([
            confirmationRegistration,
            controller.actionRegistration(),
        ])

        guard case let .failure(error) = runner.makeExecutionHandle(
            workflowID: parent.id,
            source: .automatic(ruleID: UUID(), triggerKind: "schedule"),
            mode: .background
        ) else {
            return XCTFail("Expected unattended preflight rejection")
        }
        XCTAssertEqual(error, .confirmationRequiredForAutomaticExecution)
        XCTAssertEqual(invocationCount, 0)
        XCTAssertTrue(store.history().isEmpty)

        let manual = try runner.makeExecutionHandle(
            workflowID: parent.id,
            source: .manual,
            mode: .background
        ).get()
        let manualResult = await manual.actionHandle.result()
        XCTAssertEqual(manualResult, .succeeded())
        XCTAssertEqual(invocationCount, 1)
    }

    func testRunLinkRejectsNestedSensitiveParameterBeforeAnyStepRuns() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = WorkflowStore(userDefaults: defaults)
        let registry = ActionRegistry()
        let provider = WorkflowRunnerTestProvider(actionIDs: ["safe"], timeout: 30)
        let sensitiveKey = ActionKey(providerID: "sensitive-leaf", actionID: "authenticate")
        let sensitiveReference = ActionReference(
            key: sensitiveKey,
            parameters: try ActionParameterSet(["token": .string("secret")])
        )
        var sensitiveInvocationCount = 0
        let sensitiveRegistration = ActionProviderRegistration(
            providerID: sensitiveKey.providerID,
            identity: ObjectIdentifier(provider),
            definitions: [ActionDefinition(
                key: sensitiveKey,
                title: "Authenticate",
                description: "",
                systemImage: "key",
                parameters: [ActionParameterDefinition(
                    id: "token",
                    title: "Token",
                    kind: .string,
                    privacy: .sensitive
                )],
                capabilities: [.background, .foregroundInteractive]
            )],
            catalogEntries: [],
            availability: { _ in .available },
            begin: { _ in
                sensitiveInvocationCount += 1
                return .success(ActionExecutionHandle(operation: { .succeeded() }))
            }
        )
        registry.synchronize([provider.registration(), sensitiveRegistration])
        let child = try saveWorkflow(
            in: store,
            steps: [WorkflowStep(reference: sensitiveReference)]
        )
        let parent = try saveWorkflow(
            in: store,
            steps: [
                WorkflowStep(reference: ActionReference(key: provider.definitions[0].key)),
                WorkflowStep(reference: child.actionReference),
            ]
        )
        let executor = ActionExecutor(registry: registry)
        let runner = WorkflowRunner(store: store, registry: registry, executor: executor)
        let controller = AutomationController(
            store: store,
            registry: registry,
            executor: executor,
            runner: runner
        )
        registry.synchronize([
            provider.registration(),
            sensitiveRegistration,
            controller.actionRegistration(),
        ])

        let outcome = await executor.execute(ActionInvocation(
            reference: parent.actionReference,
            source: .runLink,
            mode: .foreground
        ))

        XCTAssertEqual(outcome, .rejected(.externalInvocationUnavailable))
        XCTAssertTrue(provider.invocations.isEmpty)
        XCTAssertEqual(sensitiveInvocationCount, 0)
        XCTAssertTrue(store.history().isEmpty)
    }

    private struct Harness {
        let registry: ActionRegistry
        let provider: WorkflowRunnerTestProvider
        let store: WorkflowStore
        let sleeper: WorkflowRunnerTestSleeper
        let executor: ActionExecutor
        let runner: WorkflowRunner

        func reference(_ actionID: String) -> ActionReference {
            ActionReference(
                key: ActionKey(providerID: WorkflowRunnerTestProvider.providerID, actionID: actionID)
            )
        }
    }

    private func makeHarness(
        actionIDs: [String],
        timeout: Double = 30,
        nonCancellableActionIDs: Set<String> = [],
        terminalCheckpoint: WorkflowRunnerTerminalCheckpoint? = nil
    ) throws -> Harness {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = WorkflowStore(userDefaults: defaults)
        let registry = ActionRegistry()
        let provider = WorkflowRunnerTestProvider(
            actionIDs: actionIDs,
            timeout: timeout,
            nonCancellableActionIDs: nonCancellableActionIDs
        )
        registry.synchronize([provider.registration()])
        let executor = ActionExecutor(
            registry: registry,
            confirmationService: ApprovedActionConfirmationService(),
            confirmationTimeout: .milliseconds(50)
        )
        let sleeper = WorkflowRunnerTestSleeper()
        let runner = WorkflowRunner(
            store: store,
            registry: registry,
            executor: executor,
            sleeper: sleeper,
            terminalPersistenceCheckpoint: {
                await terminalCheckpoint?.suspend()
            }
        )
        return Harness(
            registry: registry,
            provider: provider,
            store: store,
            sleeper: sleeper,
            executor: executor,
            runner: runner
        )
    }

    private func saveWorkflow(
        in store: WorkflowStore,
        enabled: Bool = true,
        steps: [WorkflowStep]
    ) throws -> WorkflowDefinition {
        try store.upsert(
            WorkflowDefinition(name: "测试工作流", isEnabled: enabled, steps: steps)
        ).get()
    }

}

@MainActor
private final class WorkflowRunnerTerminalCheckpoint {
    private var reached = false
    private var continuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        reached = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilReached() async {
        while !reached {
            await Task.yield()
        }
    }

    func resume() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }
}

@MainActor
private final class WorkflowRunnerTestSleeper: WorkflowSleeping {
    private(set) var requestedSeconds: [Double] = []
    var shouldBlock = false
    var onSleep: ((Double) -> Void)?
    private var didStart = false

    func sleep(seconds: Double) async throws {
        requestedSeconds.append(seconds)
        onSleep?(seconds)
        didStart = true
        if shouldBlock {
            try await Task.sleep(for: .seconds(60))
        }
    }

    func waitUntilSleeping() async {
        while !didStart {
            await Task.yield()
        }
    }
}

@MainActor
private final class WorkflowRunnerTestProvider {
    nonisolated static let providerID = "workflow-runner-tests"

    let definitions: [ActionDefinition]
    var results: [String: ActionExecutionResult] = [:]
    var onBegin: [String: () -> Void] = [:]
    var nonCooperativeActionIDs: Set<String> = []
    private(set) var invocations: [ActionInvocation] = []
    private(set) var cancelledActionIDs: Set<String> = []
    private var continuations: [CheckedContinuation<ActionExecutionResult, Never>] = []

    init(
        actionIDs: [String],
        timeout: Double,
        nonCancellableActionIDs: Set<String> = []
    ) {
        definitions = actionIDs.map { actionID in
            ActionDefinition(
                key: ActionKey(providerID: Self.providerID, actionID: actionID),
                title: actionID,
                description: "",
                systemImage: "bolt",
                externalInvocationPolicy: .allowed,
                capabilities: nonCancellableActionIDs.contains(actionID)
                    ? [.automatic, .background, .foregroundInteractive]
                    : [.automatic, .background, .foregroundInteractive, .cancellable],
                executionTimeoutSeconds: timeout
            )
        }
    }

    func registration() -> ActionProviderRegistration {
        ActionProviderRegistration(
            providerID: Self.providerID,
            identity: ObjectIdentifier(self),
            definitions: definitions,
            catalogEntries: definitions.map {
                ActionCatalogEntry(reference: ActionReference(key: $0.key), title: $0.title)
            },
            availability: { _ in .available },
            begin: { [weak self] invocation in
                guard let self else {
                    return .failure(.providerFailure("missing"))
                }
                self.invocations.append(invocation)
                let actionID = invocation.reference.key.actionID
                self.onBegin[actionID]?()
                if self.nonCooperativeActionIDs.contains(actionID) {
                    return .success(
                        ActionExecutionHandle(
                            operation: { [weak self] in
                                guard let self else { return .cancelled }
                                return await withCheckedContinuation { continuation in
                                    self.continuations.append(continuation)
                                }
                            },
                            cancel: { [weak self] in
                                self?.cancelledActionIDs.insert(actionID)
                            }
                        )
                    )
                }
                let result = self.results[actionID] ?? .succeeded()
                return .success(ActionExecutionHandle(operation: { result }))
            }
        )
    }

    func waitUntilNonCooperativeActionStarts() async {
        while continuations.isEmpty {
            await Task.yield()
        }
    }

    func resumeNonCooperativeActions(with result: ActionExecutionResult = .cancelled) {
        let continuations = continuations
        self.continuations.removeAll()
        continuations.forEach { $0.resume(returning: result) }
    }
}
