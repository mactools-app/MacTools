import Foundation
import MacToolsPluginKit
import OSLog

protocol ActionConfirmationRequesting: AnyObject, Sendable {
    @MainActor
    func confirm(_ request: ActionConfirmationRequest) async -> Bool
}

struct ActionConfirmationRequest: Equatable, Sendable {
    let reference: ActionReference
    let confirmation: ActionConfirmation
    let source: ActionExecutionSource
}

@MainActor
final class RejectingActionConfirmationService: ActionConfirmationRequesting {
    func confirm(_ request: ActionConfirmationRequest) async -> Bool {
        false
    }
}

@MainActor
final class ApprovedActionConfirmationService: ActionConfirmationRequesting {
    func confirm(_ request: ActionConfirmationRequest) async -> Bool {
        true
    }
}

@MainActor
final class MatchingApprovedActionConfirmationService: ActionConfirmationRequesting {
    private let expectedRequest: ActionConfirmationRequest

    init(expectedRequest: ActionConfirmationRequest) {
        self.expectedRequest = expectedRequest
    }

    func confirm(_ request: ActionConfirmationRequest) async -> Bool {
        request == expectedRequest
    }
}

@MainActor
final class ActionConfirmationRouter: ActionConfirmationRequesting {
    typealias Handler = @MainActor @Sendable (ActionConfirmationRequest) async -> Bool

    private var handler: Handler?

    func setHandler(_ handler: Handler?) {
        self.handler = handler
    }

    func confirm(_ request: ActionConfirmationRequest) async -> Bool {
        guard let handler else {
            return false
        }
        return await handler(request)
    }
}

enum ActionExecutionRejection: Error, Equatable, Sendable {
    case unknownAction(ActionKey)
    case invalidParameters(String)
    case unavailable(String?)
    case backgroundExecutionUnsupported
    case foregroundExecutionUnsupported
    case automaticExecutionUnsupported
    case confirmationRequiredForAutomaticExecution
    case externalInvocationUnavailable
    case systemExposureUnavailable
    case confirmationUnavailable
    case confirmationDenied
    case confirmationTimedOut
    case actionAlreadyRunning
    case providerChanged
    case providerFailure(String)
    case executionTimedOut
}

enum ActionExecutionOutcome: Equatable, Sendable {
    case completed(ActionExecutionResult)
    case rejected(ActionExecutionRejection)
}

enum ContinuingActionStartOutcome: Equatable, Sendable {
    case started
    case cancelled
    case rejected(ActionExecutionRejection)
}

struct ContinuingActionStartResult {
    let outcome: ContinuingActionStartOutcome
    let completion: Task<Void, Never>?
}

struct SurfaceIndependentActionStartResult {
    let outcome: ContinuingActionStartOutcome
    let completion: AsyncStream<ActionExecutionOutcome>?
}

@MainActor
final class ActionExecutor {
    @MainActor
    private final class ConcurrencyCoordinator {
        private struct Waiter {
            let id: UUID
            let continuation: CheckedContinuation<Bool, Never>
        }

        private var activeReferences: Set<ActionReference> = []
        private var waiters: [ActionReference: [Waiter]] = [:]

        func acquire(
            _ reference: ActionReference,
            policy: ActionConcurrencyPolicy
        ) async -> Bool {
            switch policy {
            case .allowConcurrent:
                return true
            case .rejectWhileRunning:
                guard activeReferences.insert(reference).inserted else { return false }
                return true
            case .serialize:
                guard !activeReferences.contains(reference) else {
                    let waiterID = UUID()
                    return await withTaskCancellationHandler {
                        await withCheckedContinuation { continuation in
                            if Task.isCancelled {
                                continuation.resume(returning: false)
                            } else {
                                waiters[reference, default: []].append(
                                    Waiter(id: waiterID, continuation: continuation)
                                )
                            }
                        }
                    } onCancel: {
                        Task { @MainActor [weak self] in
                            self?.cancelWaiter(id: waiterID, reference: reference)
                        }
                    }
                }
                activeReferences.insert(reference)
                return true
            }
        }

        func release(_ reference: ActionReference, policy: ActionConcurrencyPolicy) {
            guard policy != .allowConcurrent else { return }
            if policy == .serialize, var queued = waiters[reference], !queued.isEmpty {
                let next = queued.removeFirst()
                waiters[reference] = queued.isEmpty ? nil : queued
                next.continuation.resume(returning: true)
                return
            }
            activeReferences.remove(reference)
        }

        private func cancelWaiter(id: UUID, reference: ActionReference) {
            guard var queued = waiters[reference],
                  let index = queued.firstIndex(where: { $0.id == id }) else { return }
            let waiter = queued.remove(at: index)
            waiters[reference] = queued.isEmpty ? nil : queued
            waiter.continuation.resume(returning: false)
        }
    }

    @MainActor
    private final class ConcurrencyLease {
        private weak var coordinator: ConcurrencyCoordinator?
        private let reference: ActionReference
        private let policy: ActionConcurrencyPolicy
        private var isReleased = false

        init(
            coordinator: ConcurrencyCoordinator,
            reference: ActionReference,
            policy: ActionConcurrencyPolicy
        ) {
            self.coordinator = coordinator
            self.reference = reference
            self.policy = policy
        }

        func release() {
            guard !isReleased else { return }
            isReleased = true
            coordinator?.release(reference, policy: policy)
        }
    }
    @MainActor
    private final class Race<Value: Sendable> {
        private var resolution: Value?
        private var continuation: CheckedContinuation<Value, Never>?
        private var tasks: [Task<Void, Never>] = []

        func add(_ task: Task<Void, Never>) {
            guard resolution == nil else {
                task.cancel()
                return
            }
            tasks.append(task)
        }

        func resolve(_ value: Value) {
            guard resolution == nil else {
                return
            }
            resolution = value
            continuation?.resume(returning: value)
            continuation = nil
            tasks.forEach { $0.cancel() }
            tasks.removeAll()
        }

        func wait() async -> Value {
            if let resolution {
                return resolution
            }
            return await withCheckedContinuation { continuation in
                if let resolution {
                    continuation.resume(returning: resolution)
                } else {
                    self.continuation = continuation
                }
            }
        }
    }

    private enum ConfirmationRace: Sendable {
        case response(Bool)
        case timedOut
        case cancelled
    }

    private enum ExecutionRace: Sendable {
        case result(ActionExecutionResult)
        case timedOut
        case cancelled
    }

    private enum CLIExecutionDeadlineRace: Sendable {
        case outcome(ActionExecutionOutcome)
        case timedOut
        case cancelled
    }

    private struct PreparedExecution {
        let definition: ActionDefinition
        let handle: ActionExecutionHandle
        let concurrencyLease: ConcurrencyLease
    }

    private enum PreparationOutcome {
        case prepared(PreparedExecution)
        case completed(ActionExecutionResult)
        case rejected(ActionExecutionRejection)
    }

    private let registry: ActionRegistry
    private let confirmationService: any ActionConfirmationRequesting
    private let confirmationTimeout: Duration
    private let presentationPreparation: @MainActor @Sendable () -> Void
    private let concurrencyCoordinator = ConcurrencyCoordinator()
    private var continuingExecutionTasks: [UUID: Task<Void, Never>] = [:]
    private var surfaceIndependentExecutionTasks: [UUID: Task<Void, Never>] = [:]

    init(
        registry: ActionRegistry,
        confirmationService: any ActionConfirmationRequesting = RejectingActionConfirmationService(),
        confirmationTimeout: Duration = .seconds(60),
        presentationPreparation: @escaping @MainActor @Sendable () -> Void = {
            PluginPresentationSafety.prepareForWindowOrdering()
        }
    ) {
        self.registry = registry
        self.confirmationService = confirmationService
        self.confirmationTimeout = confirmationTimeout
        self.presentationPreparation = presentationPreparation
    }

    func execute(
        _ invocation: ActionInvocation,
        confirmationService overrideConfirmationService: (any ActionConfirmationRequesting)? = nil,
        exposureSurface: ActionExposureSurface? = nil,
        admissionCheck: (@MainActor () -> Bool)? = nil
    ) async -> ActionExecutionOutcome {
        switch await prepare(
            invocation,
            confirmationService: overrideConfirmationService,
            expectedDefinition: nil,
            exposureSurface: exposureSurface,
            admissionCheck: admissionCheck
        ) {
        case let .prepared(execution):
            return await executionOutcome(
                for: execution,
                forceTaskCancellation: invocation.source == .cli
            )
        case let .completed(result):
            return .completed(result)
        case let .rejected(rejection):
            return .rejected(rejection)
        }
    }

    /// Executes the narrow CLI surface with a caller-owned upper timeout.
    /// CLI cancellation must be terminal even when a provider did not advertise
    /// interactive cancellation, so the handle is always cancelled with the task.
    func executeForCLI(
        _ invocation: ActionInvocation,
        expectedDefinition: ActionDefinition,
        deadline: ContinuousClock.Instant
    ) async -> ActionExecutionOutcome {
        guard ContinuousClock.now < deadline else {
            return .rejected(.executionTimedOut)
        }
        let operation = Task { @MainActor in
            await self.cliExecutionOutcome(
                invocation,
                expectedDefinition: expectedDefinition,
                deadline: deadline
            )
        }
        let race = Race<CLIExecutionDeadlineRace>()
        race.add(Task { @MainActor in
            race.resolve(.outcome(await operation.value))
        })
        race.add(Task { @MainActor in
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else {
                race.resolve(.timedOut)
                return
            }
            do {
                try await Task.sleep(for: remaining)
                race.resolve(.timedOut)
            } catch {}
        })
        let result = await withTaskCancellationHandler {
            await race.wait()
        } onCancel: {
            Task { @MainActor in race.resolve(.cancelled) }
        }
        switch result {
        case let .outcome(outcome):
            return outcome
        case .timedOut:
            operation.cancel()
            _ = await operation.value
            return .rejected(.executionTimedOut)
        case .cancelled:
            operation.cancel()
            _ = await operation.value
            return .completed(.cancelled)
        }
    }

    private func cliExecutionOutcome(
        _ invocation: ActionInvocation,
        expectedDefinition: ActionDefinition,
        deadline: ContinuousClock.Instant
    ) async -> ActionExecutionOutcome {
        switch await prepare(
            invocation,
            confirmationService: nil,
            expectedDefinition: expectedDefinition
        ) {
        case let .prepared(execution):
            let remaining = ContinuousClock.now.duration(to: deadline)
            return await executionOutcome(
                for: execution,
                timeoutLimit: max(.zero, remaining),
                forceTaskCancellation: true
            )
        case let .completed(result):
            return .completed(result)
        case let .rejected(rejection):
            return .rejected(rejection)
        }
    }

    /// Starts an action whose provider owns durable progress and cancellation UI.
    /// Validation and confirmation finish before this returns `.started`; the
    /// provider result then outlives cancellation of the invoking surface task.
    func startContinuing(
        _ invocation: ActionInvocation,
        expectedDefinition: ActionDefinition,
        confirmationService overrideConfirmationService: (any ActionConfirmationRequesting)? = nil
    ) async -> ContinuingActionStartOutcome {
        await startContinuingTrackingCompletion(
            invocation,
            expectedDefinition: expectedDefinition,
            confirmationService: overrideConfirmationService
        ).outcome
    }

    /// Starts a durable action and also returns a task that completes when the provider does.
    /// Callers may use that task to retain recursion/capacity bookkeeping without awaiting it.
    func startContinuingTrackingCompletion(
        _ invocation: ActionInvocation,
        expectedDefinition: ActionDefinition,
        confirmationService overrideConfirmationService: (any ActionConfirmationRequesting)? = nil
    ) async -> ContinuingActionStartResult {
        guard expectedDefinition.capabilities.contains(.reportsProgress) else {
            return ContinuingActionStartResult(
                outcome: .rejected(.providerChanged),
                completion: nil
            )
        }
        switch await prepare(
            invocation,
            confirmationService: overrideConfirmationService,
            expectedDefinition: expectedDefinition
        ) {
        case let .prepared(execution):
            guard execution.definition.capabilities.contains(.reportsProgress) else {
                execution.handle.cancel()
                execution.concurrencyLease.release()
                return ContinuingActionStartResult(
                    outcome: .rejected(.providerChanged),
                    completion: nil
                )
            }
            let executionID = UUID()
            let task = Task { @MainActor [weak self] in
                guard let self else {
                    execution.handle.cancel()
                    execution.concurrencyLease.release()
                    return
                }
                _ = await executionOutcome(for: execution)
                continuingExecutionTasks[executionID] = nil
            }
            continuingExecutionTasks[executionID] = task
            return ContinuingActionStartResult(outcome: .started, completion: task)
        case .completed(.cancelled):
            return ContinuingActionStartResult(outcome: .cancelled, completion: nil)
        case .completed:
            return ContinuingActionStartResult(outcome: .cancelled, completion: nil)
        case let .rejected(rejection):
            return ContinuingActionStartResult(
                outcome: .rejected(rejection),
                completion: nil
            )
        }
    }

    var continuingExecutionCountForTests: Int {
        continuingExecutionTasks.count
    }

    /// Completes validation and confirmation in the caller's task, then transfers
    /// ownership to the executor once the provider has accepted the action.
    /// Cancelling a surface's completion observer never cancels the accepted action.
    /// The executor-owned completion observer still receives the accepted action's final outcome.
    func startSurfaceIndependentTrackingCompletion(
        _ invocation: ActionInvocation,
        expectedDefinition: ActionDefinition,
        confirmationService overrideConfirmationService: (any ActionConfirmationRequesting)? = nil,
        completionObserver: (@MainActor (ActionExecutionOutcome) -> Void)? = nil
    ) async -> SurfaceIndependentActionStartResult {
        switch await prepare(
            invocation,
            confirmationService: overrideConfirmationService,
            expectedDefinition: expectedDefinition
        ) {
        case let .prepared(execution):
            let executionID = UUID()
            let (stream, continuation) = AsyncStream.makeStream(
                of: ActionExecutionOutcome.self,
                bufferingPolicy: .bufferingNewest(1)
            )
            let task = Task { @MainActor [weak self] in
                guard let self else {
                    execution.handle.cancel()
                    execution.concurrencyLease.release()
                    continuation.yield(.completed(.cancelled))
                    continuation.finish()
                    return
                }
                let outcome = await executionOutcome(for: execution)
                completionObserver?(outcome)
                continuation.yield(outcome)
                continuation.finish()
                surfaceIndependentExecutionTasks[executionID] = nil
            }
            surfaceIndependentExecutionTasks[executionID] = task
            return SurfaceIndependentActionStartResult(
                outcome: .started,
                completion: stream
            )
        case .completed(.cancelled):
            return SurfaceIndependentActionStartResult(outcome: .cancelled, completion: nil)
        case .completed:
            return SurfaceIndependentActionStartResult(outcome: .cancelled, completion: nil)
        case let .rejected(rejection):
            return SurfaceIndependentActionStartResult(
                outcome: .rejected(rejection),
                completion: nil
            )
        }
    }

    var surfaceIndependentExecutionCountForTests: Int {
        surfaceIndependentExecutionTasks.count
    }

    private func prepare(
        _ invocation: ActionInvocation,
        confirmationService overrideConfirmationService: (any ActionConfirmationRequesting)?,
        expectedDefinition: ActionDefinition?,
        exposureSurface: ActionExposureSurface? = nil,
        admissionCheck: (@MainActor () -> Bool)? = nil
    ) async -> PreparationOutcome {
        guard !Task.isCancelled else {
            return .completed(.cancelled)
        }
        let initial: RegisteredAction
        switch registry.registeredAction(for: invocation.reference) {
        case let .success(action):
            initial = action
        case let .failure(error):
            return .rejected(Self.rejection(for: error))
        }
        if let expectedDefinition, initial.definition != expectedDefinition {
            return .rejected(.providerChanged)
        }

        if let rejection = policyRejection(for: initial.definition, invocation: invocation) {
            return .rejected(rejection)
        }
        if let rejection = exposureRejection(for: invocation, additionalSurface: exposureSurface) {
            return .rejected(rejection)
        }
        let availability = registry.availability(for: invocation.reference)
        guard availability.isAvailable else {
            return .rejected(.unavailable(availability.reason))
        }

        let needsConfirmation = initial.definition.risk == .confirmationRequired
            || (invocation.source == .runLink
                && initial.definition.externalInvocationPolicy == .confirmAlways)
        if needsConfirmation {
            guard let confirmation = initial.definition.confirmation else {
                return .rejected(.confirmationUnavailable)
            }
            switch await confirmationResponse(
                ActionConfirmationRequest(
                    reference: invocation.reference,
                    confirmation: confirmation,
                    source: invocation.source
                ),
                using: overrideConfirmationService ?? confirmationService
            ) {
            case .response(true):
                break
            case .response(false):
                return .rejected(.confirmationDenied)
            case .timedOut:
                return .rejected(.confirmationTimedOut)
            case .cancelled:
                return .completed(.cancelled)
            }
        }

        guard !Task.isCancelled else {
            return .completed(.cancelled)
        }

        let revalidated: RegisteredAction
        switch registry.registeredAction(for: invocation.reference) {
        case let .success(action):
            revalidated = action
        case let .failure(error):
            return .rejected(Self.rejection(for: error))
        }
        guard revalidated.providerGeneration == initial.providerGeneration,
              revalidated.providerExecutionRevision == initial.providerExecutionRevision,
              revalidated.definition == initial.definition else {
            return .rejected(.providerChanged)
        }
        let currentAvailability = registry.availability(for: invocation.reference)
        guard currentAvailability.isAvailable else {
            return .rejected(.unavailable(currentAvailability.reason))
        }
        if let rejection = exposureRejection(for: invocation, additionalSurface: exposureSurface) {
            return .rejected(rejection)
        }

        guard await concurrencyCoordinator.acquire(
            invocation.reference,
            policy: revalidated.definition.concurrencyPolicy
        ) else {
            return Task.isCancelled
                ? .completed(.cancelled)
                : .rejected(.actionAlreadyRunning)
        }
        let concurrencyLease = ConcurrencyLease(
            coordinator: concurrencyCoordinator,
            reference: invocation.reference,
            policy: revalidated.definition.concurrencyPolicy
        )

        guard !Task.isCancelled else {
            concurrencyLease.release()
            return .completed(.cancelled)
        }

        let admitted: RegisteredAction
        switch registry.registeredAction(for: invocation.reference) {
        case let .success(action):
            admitted = action
        case let .failure(error):
            concurrencyLease.release()
            return .rejected(Self.rejection(for: error))
        }
        guard admitted.providerGeneration == revalidated.providerGeneration,
              admitted.providerExecutionRevision == revalidated.providerExecutionRevision,
              admitted.definition == revalidated.definition else {
            concurrencyLease.release()
            return .rejected(.providerChanged)
        }
        let admittedAvailability = registry.availability(for: invocation.reference)
        guard admittedAvailability.isAvailable else {
            concurrencyLease.release()
            return .rejected(.unavailable(admittedAvailability.reason))
        }
        if let rejection = exposureRejection(for: invocation, additionalSurface: exposureSurface) {
            concurrencyLease.release()
            return .rejected(rejection)
        }

        if admitted.definition.capabilities.contains(.changesDisplayConfiguration) {
            presentationPreparation()
        }

        // Caller-owned authorization may change while approval or serialization waits.
        guard admissionCheck?() != false else {
            concurrencyLease.release()
            return .completed(.cancelled)
        }

        let handle: ActionExecutionHandle
        let beginStartedAt = ContinuousClock.now
        switch registry.begin(
            invocation,
            expectedProviderGeneration: revalidated.providerGeneration,
            expectedProviderExecutionRevision: revalidated.providerExecutionRevision
        ) {
        case let .success(value):
            handle = value
        case let .failure(error):
            concurrencyLease.release()
            return .rejected(Self.rejection(for: error))
        }
        let beginDuration = beginStartedAt.duration(to: .now)
        if beginDuration > .milliseconds(100) {
            AppLog.actionExecution.warning(
                "Action provider begin was slow for \(invocation.reference.key.id, privacy: .public)"
            )
        }

        return .prepared(PreparedExecution(
            definition: admitted.definition,
            handle: handle,
            concurrencyLease: concurrencyLease
        ))
    }

    private func executionOutcome(
        for execution: PreparedExecution,
        timeoutLimit: Duration? = nil,
        forceTaskCancellation: Bool = false
    ) async -> ActionExecutionOutcome {
        defer { execution.concurrencyLease.release() }
        let isCancellable = forceTaskCancellation
            || execution.definition.capabilities.contains(.cancellable)
        let providerTimeout = Duration.seconds(execution.definition.executionTimeoutSeconds)
        let timeout = timeoutLimit.map { min(providerTimeout, $0) } ?? providerTimeout
        switch await executionResult(
            handle: execution.handle,
            timeout: timeout,
            isCancellable: isCancellable
        ) {
        case let .result(result):
            return .completed(result)
        case .timedOut:
            if isCancellable {
                execution.handle.cancel()
            }
            return .rejected(.executionTimedOut)
        case .cancelled:
            execution.handle.cancel()
            return .completed(.cancelled)
        }
    }

    private func policyRejection(
        for definition: ActionDefinition,
        invocation: ActionInvocation
    ) -> ActionExecutionRejection? {
        switch invocation.mode {
        case .background where !definition.capabilities.contains(.background):
            return .backgroundExecutionUnsupported
        case .foreground where !definition.capabilities.contains(.foregroundInteractive):
            return .foregroundExecutionUnsupported
        default:
            break
        }

        if invocation.source == .automaticRule || invocation.source == .cli {
            guard definition.risk != .confirmationRequired else {
                return .confirmationRequiredForAutomaticExecution
            }
            guard definition.capabilities.contains(.automatic) else {
                return .automaticExecutionUnsupported
            }
        }

        if invocation.source == .runLink {
            guard definition.externalInvocationPolicy != .unavailable,
                  !ActionRegistry.containsSensitiveParameters(
                      invocation.reference,
                      for: definition
                  ) else {
                return .externalInvocationUnavailable
            }
        }
        return nil
    }

    private func exposureRejection(
        for invocation: ActionInvocation, additionalSurface: ActionExposureSurface? = nil
    ) -> ActionExecutionRejection? {
        if let additionalSurface, registry.exposurePolicy(for: invocation.reference, on: additionalSurface) == .excluded {
            return .systemExposureUnavailable
        }
        let surface: ActionExposureSurface
        switch invocation.source {
        case .appIntent:
            surface = .appIntents
        case .cli:
            guard invocation.reference.parameters.entries.isEmpty,
                  case let .success(action) = registry.registeredAction(for: invocation.reference),
                  action.catalogEntry != nil,
                  action.definition.parameters.isEmpty,
                  registry.portability(of: invocation.reference) == .portable else {
                return .systemExposureUnavailable
            }
            surface = ActionExposureSurface(rawValue: "cli")
        default:
            return nil
        }

        guard registry.exposurePolicy(for: invocation.reference, on: surface) != .excluded else {
            return .systemExposureUnavailable
        }
        return nil
    }

    private func confirmationResponse(
        _ request: ActionConfirmationRequest,
        using confirmationService: any ActionConfirmationRequesting
    ) async -> ConfirmationRace {
        let race = Race<ConfirmationRace>()
        race.add(Task { @MainActor in
            let response = await confirmationService.confirm(request)
            race.resolve(.response(response))
        })
        race.add(Task { @MainActor [confirmationTimeout] in
            do {
                try await Task.sleep(for: confirmationTimeout)
                race.resolve(.timedOut)
            } catch {}
        })
        return await withTaskCancellationHandler {
            await race.wait()
        } onCancel: {
            Task { @MainActor in race.resolve(.cancelled) }
        }
    }

    private func executionResult(
        handle: ActionExecutionHandle,
        timeout: Duration?,
        isCancellable: Bool
    ) async -> ExecutionRace {
        let race = Race<ExecutionRace>()
        race.add(Task { @MainActor in
            race.resolve(.result(await handle.result()))
        })
        if let timeout {
            race.add(Task { @MainActor in
                do {
                    try await Task.sleep(for: timeout)
                    race.resolve(.timedOut)
                } catch {}
            })
        }
        return await withTaskCancellationHandler {
            await race.wait()
        } onCancel: {
            guard isCancellable else { return }
            Task { @MainActor in race.resolve(.cancelled) }
        }
    }

    private static func rejection(for error: ActionRegistryError) -> ActionExecutionRejection {
        switch error {
        case let .unknownAction(key):
            return .unknownAction(key)
        case .schemaVersionMismatch, .migrationUnavailable, .invalidMigration:
            return .invalidParameters("action-schema-version")
        case let .invalidParameters(reason):
            return .invalidParameters(reason)
        case .providerChanged:
            return .providerChanged
        case let .providerFailure(message):
            return .providerFailure(message)
        }
    }
}
