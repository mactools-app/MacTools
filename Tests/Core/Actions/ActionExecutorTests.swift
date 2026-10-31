import MacToolsPluginKit
import XCTest
@testable import MacTools

@MainActor
final class ActionExecutorTests: XCTestCase {
    func testExecutorAppliesAvailabilityModeAndExternalPoliciesBeforeBegin() async {
        let registry = ActionRegistry()
        let provider = ActionExecutorTestProvider()
        let foregroundOnly = makeActionDefinition(
            externalPolicy: .unavailable,
            capabilities: [.foregroundInteractive]
        )
        registry.synchronize([provider.registration(definition: foregroundOnly)])
        let executor = ActionExecutor(registry: registry)
        let reference = ActionReference(key: foregroundOnly.key)

        let backgroundOutcome = await executor.execute(
            ActionInvocation(reference: reference, source: .workflow, mode: .background)
        )
        XCTAssertEqual(backgroundOutcome, .rejected(.backgroundExecutionUnsupported))

        let runLinkOutcome = await executor.execute(
            ActionInvocation(reference: reference, source: .runLink, mode: .foreground)
        )
        XCTAssertEqual(runLinkOutcome, .rejected(.externalInvocationUnavailable))

        provider.availability = .unavailable("未连接显示器")
        let unavailableOutcome = await executor.execute(
            ActionInvocation(reference: reference, source: .unifiedSearch, mode: .foreground)
        )
        XCTAssertEqual(unavailableOutcome, .rejected(.unavailable("未连接显示器")))
        XCTAssertEqual(provider.beginCount, 0)
    }

    func testRunLinkRejectsSuppliedSensitiveParameterBeforeProviderBegins() async throws {
        let registry = ActionRegistry()
        let provider = ActionExecutorTestProvider()
        let definition = makeActionDefinition(parameters: [
            ActionParameterDefinition(
                id: "token",
                title: "Token",
                kind: .string,
                privacy: .sensitive
            ),
        ])
        registry.synchronize([provider.registration(definition: definition)])
        let reference = ActionReference(
            key: definition.key,
            parameters: try ActionParameterSet(["token": .string("secret")])
        )

        let outcome = await ActionExecutor(registry: registry).execute(
            ActionInvocation(reference: reference, source: .runLink, mode: .foreground)
        )

        XCTAssertEqual(outcome, .rejected(.externalInvocationUnavailable))
        XCTAssertEqual(provider.beginCount, 0)
    }

    func testExecutorConfirmsThenRevalidatesProviderGeneration() async {
        let registry = ActionRegistry()
        let provider = ActionExecutorTestProvider()
        let definition = makeActionDefinition(
            risk: .confirmationRequired,
            confirmation: ActionConfirmation(
                title: "确认",
                message: "继续操作？",
                confirmButtonTitle: "继续"
            )
        )
        registry.synchronize([provider.registration(definition: definition)])

        let confirmation = ActionExecutorConfirmationService {
            let changed = ActionDefinition(
                key: definition.key,
                title: "已变化",
                description: definition.description,
                systemImage: definition.systemImage,
                externalInvocationPolicy: .allowed,
                capabilities: [.background, .foregroundInteractive]
            )
            registry.synchronize([provider.registration(definition: changed)])
            return true
        }
        let executor = ActionExecutor(registry: registry, confirmationService: confirmation)

        let outcome = await executor.execute(
            ActionInvocation(
                reference: ActionReference(key: definition.key),
                source: .unifiedSearch,
                mode: .foreground
            )
        )
        XCTAssertEqual(outcome, .rejected(.providerChanged))
        XCTAssertEqual(provider.beginCount, 0)
    }

    func testAppIntentExecutionEnforcesProviderExposurePolicy() async {
        let registry = ActionRegistry()
        let provider = ActionExecutorTestProvider()
        provider.exposurePolicy = .excluded
        let definition = makeActionDefinition()
        registry.synchronize([provider.registration(definition: definition)])

        let outcome = await ActionExecutor(registry: registry).execute(
            ActionInvocation(
                reference: ActionReference(key: definition.key),
                source: .appIntent,
                mode: .foreground
            )
        )

        XCTAssertEqual(outcome, .rejected(.systemExposureUnavailable))
        XCTAssertEqual(provider.beginCount, 0)
    }

    func testAutomaticRuleRejectsInteractiveConfirmationWithoutRequestingIt() async {
        let registry = ActionRegistry()
        let provider = ActionExecutorTestProvider()
        let definition = makeActionDefinition(
            risk: .confirmationRequired,
            confirmation: ActionConfirmation(
                title: "Confirm",
                message: "Continue?",
                confirmButtonTitle: "Continue"
            ),
            capabilities: [.background]
        )
        registry.synchronize([provider.registration(definition: definition)])
        var confirmationCount = 0
        let confirmation = ActionExecutorConfirmationService {
            confirmationCount += 1
            return true
        }

        let outcome = await ActionExecutor(
            registry: registry,
            confirmationService: confirmation
        ).execute(ActionInvocation(
            reference: ActionReference(key: definition.key),
            source: .automaticRule,
            mode: .background
        ))

        XCTAssertEqual(outcome, .rejected(.confirmationRequiredForAutomaticExecution))
        XCTAssertEqual(confirmationCount, 0)
        XCTAssertEqual(provider.beginCount, 0)
    }

    func testAutomaticRuleRequiresExplicitProviderOptIn() async {
        let registry = ActionRegistry()
        let provider = ActionExecutorTestProvider()
        let definition = makeActionDefinition(
            capabilities: [.background, .foregroundInteractive]
        )
        registry.synchronize([provider.registration(definition: definition)])

        let outcome = await ActionExecutor(registry: registry).execute(
            ActionInvocation(
                reference: ActionReference(key: definition.key),
                source: .automaticRule,
                mode: .background
            )
        )

        XCTAssertEqual(outcome, .rejected(.automaticExecutionUnsupported))
        XCTAssertEqual(provider.beginCount, 0)
    }

    func testDefaultConcurrencyPolicyRejectsOverlappingInvocation() async {
        let registry = ActionRegistry()
        let provider = ActionExecutorTestProvider()
        let definition = makeActionDefinition(timeout: 86_400)
        var continuation: CheckedContinuation<ActionExecutionResult, Never>?
        provider.operation = {
            await withCheckedContinuation { continuation = $0 }
        }
        registry.synchronize([provider.registration(definition: definition)])
        let executor = ActionExecutor(registry: registry)
        let invocation = ActionInvocation(
            reference: ActionReference(key: definition.key),
            source: .workflow,
            mode: .background
        )
        let first = Task { @MainActor in await executor.execute(invocation) }
        while continuation == nil { await Task.yield() }

        let overlapping = await executor.execute(invocation)

        XCTAssertEqual(overlapping, .rejected(.actionAlreadyRunning))
        XCTAssertEqual(provider.beginCount, 1)
        continuation?.resume(returning: .succeeded())
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .completed(.succeeded()))
    }

    func testSerializedConcurrencyWaitsForPriorInvocation() async {
        let registry = ActionRegistry()
        let provider = ActionExecutorTestProvider()
        let definition = makeActionDefinition(
            concurrencyPolicy: .serialize,
            timeout: 86_400
        )
        var continuations: [CheckedContinuation<ActionExecutionResult, Never>] = []
        provider.operation = {
            await withCheckedContinuation { continuations.append($0) }
        }
        registry.synchronize([provider.registration(definition: definition)])
        let executor = ActionExecutor(registry: registry)
        let invocation = ActionInvocation(
            reference: ActionReference(key: definition.key),
            source: .workflow,
            mode: .background
        )
        let first = Task { @MainActor in await executor.execute(invocation) }
        while continuations.isEmpty { await Task.yield() }
        let second = Task { @MainActor in await executor.execute(invocation) }
        for _ in 0 ..< 10 { await Task.yield() }
        XCTAssertEqual(provider.beginCount, 1)

        continuations.removeFirst().resume(returning: .succeeded(message: "first"))
        while continuations.isEmpty { await Task.yield() }
        continuations.removeFirst().resume(returning: .succeeded(message: "second"))

        let firstOutcome = await first.value
        let secondOutcome = await second.value
        XCTAssertEqual(firstOutcome, .completed(.succeeded(message: "first")))
        XCTAssertEqual(secondOutcome, .completed(.succeeded(message: "second")))
    }

    func testAllowConcurrentPolicyStartsOverlappingInvocations() async {
        let registry = ActionRegistry()
        let provider = ActionExecutorTestProvider()
        let definition = makeActionDefinition(
            concurrencyPolicy: .allowConcurrent,
            timeout: 86_400
        )
        var continuations: [CheckedContinuation<ActionExecutionResult, Never>] = []
        provider.operation = {
            await withCheckedContinuation { continuations.append($0) }
        }
        registry.synchronize([provider.registration(definition: definition)])
        let executor = ActionExecutor(registry: registry)
        let invocation = ActionInvocation(
            reference: ActionReference(key: definition.key),
            source: .workflow,
            mode: .background
        )
        let first = Task { @MainActor in await executor.execute(invocation) }
        let second = Task { @MainActor in await executor.execute(invocation) }
        while continuations.count < 2 { await Task.yield() }

        XCTAssertEqual(provider.beginCount, 2)
        continuations.removeFirst().resume(returning: .succeeded())
        continuations.removeFirst().resume(returning: .succeeded())
        let firstOutcome = await first.value
        let secondOutcome = await second.value
        XCTAssertEqual(firstOutcome, .completed(.succeeded()))
        XCTAssertEqual(secondOutcome, .completed(.succeeded()))
    }

    func testAdmissionCheckRejectsQueuedInvocationAndReleasesLease() async {
        let registry = ActionRegistry()
        let provider = ActionExecutorTestProvider()
        let definition = makeActionDefinition(
            risk: .confirmationRequired,
            confirmation: .init(title: "Confirm", message: "Continue?", confirmButtonTitle: "Continue"),
            concurrencyPolicy: .serialize,
            timeout: 86_400
        )
        var pending: CheckedContinuation<ActionExecutionResult, Never>?
        provider.operation = { await withCheckedContinuation { pending = $0 } }
        registry.synchronize([provider.registration(definition: definition)])
        let secondApproved = expectation(description: "Queued command approved")
        var approvals = 0
        let confirmation = ActionExecutorConfirmationService {
            approvals += 1
            if approvals == 2 { secondApproved.fulfill() }
            return true
        }
        let executor = ActionExecutor(registry: registry, confirmationService: confirmation)
        let invocation = ActionInvocation(reference: .init(key: definition.key), source: .manual, mode: .foreground)
        let first = Task { await executor.execute(invocation) }
        while pending == nil { await Task.yield() }
        var authorized = true
        let second = Task { await executor.execute(invocation, admissionCheck: { authorized }) }
        await fulfillment(of: [secondApproved], timeout: 2)
        authorized = false
        pending?.resume(returning: .succeeded())
        let firstOutcome = await first.value
        let secondOutcome = await second.value
        XCTAssertEqual(firstOutcome, .completed(.succeeded()))
        XCTAssertEqual(secondOutcome, .completed(.cancelled))
        XCTAssertEqual(provider.beginCount, 1)

        provider.operation = { .succeeded() }
        let next = await executor.execute(invocation, admissionCheck: { true })
        XCTAssertEqual(next, .completed(.succeeded()))
        XCTAssertEqual(provider.beginCount, 2)
    }

    func testSuccessfulExecutionReturnsProviderResult() async {
        let registry = ActionRegistry()
        let provider = ActionExecutorTestProvider()
        provider.operation = { .succeeded(message: "完成") }
        let definition = makeActionDefinition()
        registry.synchronize([provider.registration(definition: definition)])

        let outcome = await ActionExecutor(registry: registry).execute(
            ActionInvocation(
                reference: ActionReference(key: definition.key),
                source: .actionGrid,
                mode: .foreground
            )
        )

        XCTAssertEqual(outcome, .completed(.succeeded(message: "完成")))
        XCTAssertEqual(provider.beginCount, 1)
    }

    func testCancellationReturnsPromptlyForNonCooperativeOperation() async {
        let registry = ActionRegistry()
        let provider = ActionExecutorTestProvider()
        let definition = makeActionDefinition(
            capabilities: [.background, .foregroundInteractive, .cancellable],
            timeout: 86_400
        )
        provider.operation = {
            await withCheckedContinuation { continuation in
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(5))
                    continuation.resume(returning: .succeeded())
                }
            }
        }
        registry.synchronize([provider.registration(definition: definition)])
        let executor = ActionExecutor(registry: registry)
        let task = Task { @MainActor in
            await executor.execute(
                ActionInvocation(
                    reference: ActionReference(key: definition.key),
                    source: .workflow,
                    mode: .background
                )
            )
        }
        await Task.yield()

        task.cancel()
        let outcome = await task.value

        XCTAssertEqual(outcome, .completed(.cancelled))
        XCTAssertTrue(provider.didCancel)
    }

    func testNonCancellableActionTimesOutWithoutInvokingProviderCancellation() async {
        let registry = ActionRegistry()
        let provider = ActionExecutorTestProvider()
        let definition = makeActionDefinition(
            capabilities: [.background, .foregroundInteractive],
            timeout: 0.001
        )
        provider.operation = {
            try? await Task.sleep(for: .milliseconds(40))
            return .succeeded(message: "finished")
        }
        registry.synchronize([provider.registration(definition: definition)])
        let outcome = await ActionExecutor(registry: registry).execute(
            ActionInvocation(
                reference: ActionReference(key: definition.key),
                source: .workflow,
                mode: .background
            )
        )

        XCTAssertEqual(outcome, .rejected(.executionTimedOut))
        XCTAssertFalse(provider.didCancel)
    }

    func testContinuingExecutionReturnsAfterStartAndOutlivesCallerTask() async {
        let registry = ActionRegistry()
        let provider = ActionExecutorTestProvider()
        let definition = makeActionDefinition(
            capabilities: [
                .background,
                .foregroundInteractive,
                .cancellable,
                .reportsProgress,
            ],
            timeout: 86_400
        )
        var continuation: CheckedContinuation<ActionExecutionResult, Never>?
        provider.operation = {
            await withCheckedContinuation { continuation = $0 }
        }
        registry.synchronize([provider.registration(definition: definition)])
        let executor = ActionExecutor(registry: registry)
        let invocation = ActionInvocation(
            reference: ActionReference(key: definition.key),
            source: .actionGrid,
            mode: .foreground
        )

        let caller = Task { @MainActor in
            await executor.startContinuing(
                invocation,
                expectedDefinition: definition
            )
        }
        let outcome = await caller.value
        caller.cancel()
        for _ in 0 ..< 100 where continuation == nil {
            await Task.yield()
        }

        XCTAssertEqual(outcome, .started)
        XCTAssertEqual(executor.continuingExecutionCountForTests, 1)
        XCTAssertFalse(provider.didCancel)

        continuation?.resume(returning: .succeeded())
        for _ in 0 ..< 100 where executor.continuingExecutionCountForTests != 0 {
            await Task.yield()
        }

        XCTAssertEqual(executor.continuingExecutionCountForTests, 0)
        XCTAssertFalse(provider.didCancel)
    }

    func testExecutionHandleLatchesCancellationBeforeStartingAndOnlyCancelsOnce() async {
        var startCount = 0
        var cancelCount = 0
        let handle = ActionExecutionHandle(
            operation: {
                startCount += 1
                return .succeeded()
            },
            cancel: { cancelCount += 1 }
        )

        handle.cancel()
        handle.cancel()
        let result = await handle.result()

        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(startCount, 0)
        XCTAssertEqual(cancelCount, 1)
    }

}

@MainActor
final class ActionExecutorConfirmationService: ActionConfirmationRequesting {
    let operation: @MainActor @Sendable () async -> Bool

    init(operation: @escaping @MainActor @Sendable () async -> Bool) {
        self.operation = operation
    }

    func confirm(_ request: ActionConfirmationRequest) async -> Bool {
        await operation()
    }
}

@MainActor
final class ActionExecutorTestProvider {
    var availability: ActionAvailability = .available
    var exposurePolicy: ActionExposurePolicy = .automatic
    var operation: @MainActor @Sendable () async -> ActionExecutionResult = { .succeeded() }
    var beginCount = 0
    var executionRevision: UInt64 = 0
    var didCancel = false
    var onBegin: (() -> Void)?

    func registration(definition: ActionDefinition) -> ActionProviderRegistration {
        ActionProviderRegistration(
            providerID: definition.key.providerID,
            identity: ObjectIdentifier(self),
            definitions: [definition],
            catalogEntries: [
                ActionCatalogEntry(
                    reference: ActionReference(key: definition.key),
                    title: definition.title
                ),
            ],
            executionRevision: { [weak self] in self?.executionRevision ?? .max },
            availability: { [weak self] _ in
                self?.availability ?? .unavailable("missing")
            },
            exposurePolicy: { [weak self] _, _ in
                self?.exposurePolicy ?? .excluded
            },
            begin: { [weak self] _ in
                guard let self else {
                    return .failure(.providerFailure("missing"))
                }
                self.onBegin?()
                self.beginCount += 1
                let operation = self.operation
                return .success(
                    ActionExecutionHandle(
                        operation: operation,
                        cancel: { [weak self] in self?.didCancel = true }
                    )
                )
            }
        )
    }
}
