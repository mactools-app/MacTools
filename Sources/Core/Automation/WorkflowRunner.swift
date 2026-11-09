import Foundation
import MacToolsPluginKit

@MainActor
protocol WorkflowSleeping: AnyObject {
    func sleep(seconds: Double) async throws
}

@MainActor
final class SystemWorkflowSleeper: WorkflowSleeping {
    func sleep(seconds: Double) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }
}

@MainActor
final class WorkflowRunner {
    private let store: WorkflowStore
    private let registry: ActionRegistry
    private let executor: ActionExecutor
    private let sleeper: any WorkflowSleeping
    private let now: () -> Date
    private let terminalPersistenceCheckpoint: @MainActor @Sendable () async -> Void
    private var cancelledRunIDs: Set<UUID> = []
    private var enteredRunIDs: Set<UUID> = []
    private(set) var activeRunIDs: Set<UUID> = []
    private var executionHandles: [UUID: ActionExecutionHandle] = [:]
    private var workflowIDsByRunID: [UUID: UUID] = [:]

    var onRunChange: (() -> Void)?

    init(
        store: WorkflowStore,
        registry: ActionRegistry,
        executor: ActionExecutor,
        sleeper: any WorkflowSleeping = SystemWorkflowSleeper(),
        now: @escaping () -> Date = Date.init,
        terminalPersistenceCheckpoint: @escaping @MainActor @Sendable () async -> Void = {}
    ) {
        self.store = store
        self.registry = registry
        self.executor = executor
        self.sleeper = sleeper
        self.now = now
        self.terminalPersistenceCheckpoint = terminalPersistenceCheckpoint
    }

    func makeExecutionHandle(
        workflowID: UUID,
        source: WorkflowRunSource,
        mode: ActionExecutionMode
    ) -> Result<WorkflowExecutionHandle, WorkflowStartError> {
        guard let workflow = store.workflow(id: workflowID) else {
            return .failure(.workflowNotFound)
        }
        guard workflow.isEnabled || source == .test else {
            return .failure(.workflowDisabled)
        }
        guard !workflow.steps.isEmpty else {
            return .failure(.emptyWorkflow)
        }
        guard !workflowIDsByRunID.values.contains(workflowID) else {
            return .failure(.alreadyRunning)
        }
        if let error = WorkflowExecutionAnalysis.structuralStartError(
            workflowID: workflowID,
            store: store
        ) {
            return .failure(error)
        }
        if mode == .background {
            let analysis = WorkflowExecutionAnalysis.analyze(
                workflowID: workflowID,
                store: store,
                definition: registry.definition(for:)
            )
            guard analysis.supportsBackground else {
                return .failure(.backgroundExecutionUnsupported)
            }
            if source.requiresUnattendedExecution,
               !analysis.supportsUnattendedExecution {
                return .failure(
                    analysis.requiresConfirmation
                        ? .confirmationRequiredForAutomaticExecution
                        : .automaticExecutionUnsupported
                )
            }
        }

        let runID = UUID()
        let actionHandle = ActionExecutionHandle(
            operation: { [weak self] in
                guard let self else {
                    return .failed(message: FeatureL10n.string("工作流运行器不可用。"))
                }
                return await self.execute(
                    runID: runID,
                    workflowID: workflowID,
                    source: source,
                    mode: mode
                )
            },
            cancel: { [weak self] in
                self?.requestCancellation(runID: runID)
            }
        )
        executionHandles[runID] = actionHandle
        workflowIDsByRunID[runID] = workflowID
        onRunChange?()
        return .success(WorkflowExecutionHandle(runID: runID, actionHandle: actionHandle))
    }

    func cancel(runID: UUID) {
        executionHandles[runID]?.cancel()
    }

    func activeRunIDs(for workflowID: UUID) -> [UUID] {
        workflowIDsByRunID.compactMap { runID, trackedWorkflowID in
            trackedWorkflowID == workflowID && activeRunIDs.contains(runID) ? runID : nil
        }
    }

    func trackedRunIDs(for workflowID: UUID) -> [UUID] {
        workflowIDsByRunID.compactMap { runID, trackedWorkflowID in
            trackedWorkflowID == workflowID ? runID : nil
        }
    }

    var trackedRunIDs: Set<UUID> {
        Set(workflowIDsByRunID.keys)
    }

    var bookkeepingRunIDs: Set<UUID> {
        Set(executionHandles.keys)
            .union(workflowIDsByRunID.keys)
            .union(activeRunIDs)
            .union(enteredRunIDs)
            .union(cancelledRunIDs)
    }

    private func execute(
        runID: UUID,
        workflowID: UUID,
        source: WorkflowRunSource,
        mode: ActionExecutionMode
    ) async -> ActionExecutionResult {
        enteredRunIDs.insert(runID)
        defer {
            cancelledRunIDs.remove(runID)
            enteredRunIDs.remove(runID)
            activeRunIDs.remove(runID)
            executionHandles.removeValue(forKey: runID)
            workflowIDsByRunID.removeValue(forKey: runID)
            onRunChange?()
        }
        guard !isCancelled(runID: runID) else {
            return .cancelled
        }
        guard let workflow = store.workflow(id: workflowID) else {
            return .failed(message: FeatureL10n.string("找不到工作流。"))
        }
        if case .publishedAction(.runLink) = source {
            let analysis = WorkflowExecutionAnalysis.analyze(
                workflowID: workflowID,
                store: store,
                definition: registry.definition(for:)
            )
            guard analysis.allowsExternalInvocation else {
                return .failed(message: FeatureL10n.string("此操作不能通过运行链接调用。"))
            }
        }
        let stack = WorkflowExecutionContext.workflowStack
        if stack.contains(workflowID) {
            await recordRejectedRun(
                runID: runID,
                workflow: workflow,
                source: source,
                summaryLocalizationKey: .recursiveInvocation
            )
            return .failed(message: FeatureL10n.string("检测到递归工作流调用。"))
        }
        if stack.count >= WorkflowExecutionLimits.maximumDepth {
            await recordRejectedRun(
                runID: runID,
                workflow: workflow,
                source: source,
                summaryLocalizationKey: .maximumDepthExceeded
            )
            return .failed(message: FeatureL10n.string("工作流嵌套层级已达上限。"))
        }

        return await WorkflowExecutionContext.$workflowStack.withValue(stack + [workflowID]) {
            await executeSteps(
                runID: runID,
                workflow: workflow,
                source: source,
                mode: mode
            )
        }
    }

    private func executeSteps(
        runID: UUID,
        workflow: WorkflowDefinition,
        source: WorkflowRunSource,
        mode: ActionExecutionMode
    ) async -> ActionExecutionResult {
        var run = WorkflowRun(
            id: runID,
            workflowID: workflow.id,
            workflowName: workflow.name,
            source: source,
            startedAt: now()
        )
        _ = await store.record(run)
        activeRunIDs.insert(runID)
        onRunChange?()

        var hadFailure = false
        for (index, originalStep) in workflow.steps.enumerated() {
            if isCancelled(runID: runID) {
                appendCancelledAndSkipped(
                    currentStep: originalStep,
                    remainingSteps: workflow.steps.dropFirst(index + 1),
                    to: &run
                )
                await finish(&run, status: .cancelled, summaryLocalizationKey: .workflowCancelled)
                return .cancelled
            }

            if originalStep.delaySeconds > 0 {
                do {
                    try await sleeper.sleep(seconds: originalStep.delaySeconds)
                } catch {
                    appendCancelledAndSkipped(
                        currentStep: originalStep,
                        remainingSteps: workflow.steps.dropFirst(index + 1),
                        to: &run
                    )
                    await finish(&run, status: .cancelled, summaryLocalizationKey: .workflowCancelled)
                    return .cancelled
                }
            }

            let stepStart = now()
            let reference: ActionReference
            switch registry.migrate(originalStep.reference) {
            case let .success(migrated):
                reference = migrated
            case .failure:
                let result = stepResult(
                    for: originalStep,
                    startedAt: stepStart,
                    status: .unavailable,
                    messageLocalizationKey: .actionVersionUnavailable
                )
                run.stepResults.append(result)
                _ = await store.record(run, persistenceMode: .coalesced)
                onRunChange?()
                hadFailure = true
                if originalStep.errorPolicy == .stop {
                    appendSkipped(workflow.steps.dropFirst(index + 1), to: &run)
                    if await finishNonCancelledTerminal(
                        &run,
                        runID: runID,
                        status: .failed,
                        summaryLocalizationKey: .requiredActionUnavailable
                    ) {
                        return .cancelled
                    }
                    return .failed(message: FeatureL10n.string("必需操作不可用。"))
                }
                continue
            }

            let stepMode = executionMode(for: reference, requestedMode: mode)
            let outcome = await executor.execute(ActionInvocation(
                reference: reference,
                source: actionExecutionSource(for: source),
                mode: stepMode
            ))
            let result = stepResult(
                for: originalStep,
                startedAt: stepStart,
                outcome: outcome
            )
            run.stepResults.append(result)
            if isCancelled(runID: runID) {
                appendSkipped(workflow.steps.dropFirst(index + 1), to: &run)
                await finish(&run, status: .cancelled, summaryLocalizationKey: .workflowCancelled)
                return .cancelled
            }
            _ = await store.record(run, persistenceMode: .coalesced)
            onRunChange?()
            if isCancelled(runID: runID) {
                appendSkipped(workflow.steps.dropFirst(index + 1), to: &run)
                await finish(&run, status: .cancelled, summaryLocalizationKey: .workflowCancelled)
                return .cancelled
            }

            switch result.status {
            case .succeeded:
                continue
            case .cancelled:
                appendSkipped(workflow.steps.dropFirst(index + 1), to: &run)
                await finish(&run, status: .cancelled, summaryLocalizationKey: .workflowCancelled)
                return .cancelled
            case .failed, .timedOut, .unavailable, .skipped:
                hadFailure = true
                if originalStep.errorPolicy == .stop {
                    appendSkipped(workflow.steps.dropFirst(index + 1), to: &run)
                    if await finishNonCancelledTerminal(
                        &run,
                        runID: runID,
                        status: .failed,
                        summaryLocalizationKey: .stoppedAtFailedStep
                    ) {
                        return .cancelled
                    }
                    return .failed(message: FeatureL10n.string("工作流在失败步骤处停止。"))
                }
            }
        }

        if hadFailure {
            if await finishNonCancelledTerminal(
                &run,
                runID: runID,
                status: .failed,
                summaryLocalizationKey: .completedWithFailures
            ) {
                return .cancelled
            }
            return .failed(message: FeatureL10n.string("部分步骤失败。"))
        }
        if await finishNonCancelledTerminal(
            &run,
            runID: runID,
            status: .succeeded,
            summaryLocalizationKey: .completed
        ) {
            return .cancelled
        }
        return .succeeded()
    }

    private func executionMode(
        for reference: ActionReference,
        requestedMode: ActionExecutionMode
    ) -> ActionExecutionMode {
        guard requestedMode == .foreground,
              let definition = registry.definition(for: reference.key),
              definition.capabilities.contains(.foregroundInteractive) else {
            return .background
        }
        return .foreground
    }

    private func actionExecutionSource(for source: WorkflowRunSource) -> ActionExecutionSource {
        if case let .publishedAction(actionSource) = source {
            return actionSource
        }
        if case .automatic = source {
            return .automaticRule
        }
        return .workflow
    }

    private func stepResult(
        for step: WorkflowStep,
        startedAt: Date,
        outcome: ActionExecutionOutcome
    ) -> WorkflowStepRunResult {
        switch outcome {
        case .completed(.succeeded):
            return stepResult(for: step, startedAt: startedAt, status: .succeeded)
        case .completed(.failed):
            return stepResult(
                for: step,
                startedAt: startedAt,
                status: .failed,
                messageLocalizationKey: .actionFailed
            )
        case .completed(.cancelled):
            return stepResult(
                for: step,
                startedAt: startedAt,
                status: .cancelled,
                messageLocalizationKey: .actionCancelled
            )
        case .rejected(.executionTimedOut), .rejected(.confirmationTimedOut):
            return stepResult(
                for: step,
                startedAt: startedAt,
                status: .timedOut,
                messageLocalizationKey: .actionTimedOut
            )
        case .rejected(.unknownAction), .rejected(.unavailable),
             .rejected(.backgroundExecutionUnsupported),
             .rejected(.foregroundExecutionUnsupported),
             .rejected(.automaticExecutionUnsupported),
             .rejected(.confirmationRequiredForAutomaticExecution),
             .rejected(.externalInvocationUnavailable),
             .rejected(.actionAlreadyRunning),
             .rejected(.providerChanged):
            return stepResult(
                for: step,
                startedAt: startedAt,
                status: .unavailable,
                messageLocalizationKey: .actionUnavailable
            )
        case .rejected:
            return stepResult(
                for: step,
                startedAt: startedAt,
                status: .failed,
                messageLocalizationKey: .actionDidNotStart
            )
        }
    }

    private func stepResult(
        for step: WorkflowStep,
        startedAt: Date?,
        status: WorkflowStepRunStatus,
        message: String? = nil,
        messageLocalizationKey: WorkflowHistoryLocalizationKey? = nil
    ) -> WorkflowStepRunResult {
        WorkflowStepRunResult(
            stepID: step.id,
            actionKey: step.reference.key,
            title: step.label?.isEmpty == false ? step.label! : actionTitle(for: step.reference),
            titleSource: step.label?.isEmpty == false ? .custom : .action,
            actionReference: ActionReference(
                key: step.reference.key,
                schemaVersion: step.reference.schemaVersion
            ),
            startedAt: startedAt,
            finishedAt: now(),
            status: status,
            message: message,
            messageLocalizationKey: messageLocalizationKey
        )
    }

    private func actionTitle(for reference: ActionReference) -> String {
        guard case let .success(action) = registry.registeredAction(for: reference) else {
            return reference.key.id
        }
        let parametersByID = Dictionary(
            uniqueKeysWithValues: action.definition.parameters.map { ($0.id, $0) }
        )
        if reference.parameters.entries.contains(where: {
            parametersByID[$0.name]?.privacy == .sensitive
        }) {
            return action.definition.title
        }
        return action.catalogEntry?.title ?? action.definition.title
    }

    private func requestCancellation(runID: UUID) {
        if enteredRunIDs.contains(runID) {
            cancelledRunIDs.insert(runID)
        } else {
            cancelledRunIDs.remove(runID)
        }
        guard !activeRunIDs.contains(runID) else { return }
        executionHandles.removeValue(forKey: runID)
        workflowIDsByRunID.removeValue(forKey: runID)
        onRunChange?()
    }

    private func appendCancelledAndSkipped(
        currentStep: WorkflowStep,
        remainingSteps: ArraySlice<WorkflowStep>,
        to run: inout WorkflowRun
    ) {
        run.stepResults.append(
            stepResult(
                for: currentStep,
                startedAt: nil,
                status: .cancelled,
                messageLocalizationKey: .workflowCancelled
            )
        )
        appendSkipped(remainingSteps, to: &run)
    }

    private func appendSkipped(
        _ steps: ArraySlice<WorkflowStep>,
        to run: inout WorkflowRun
    ) {
        for step in steps {
            run.stepResults.append(
                stepResult(
                    for: step,
                    startedAt: nil,
                    status: .skipped,
                    messageLocalizationKey: .notRun
                )
            )
        }
    }

    private func finish(
        _ run: inout WorkflowRun,
        status: WorkflowRunStatus,
        summaryLocalizationKey: WorkflowHistoryLocalizationKey
    ) async {
        run.status = status
        run.finishedAt = now()
        run.summary = summaryLocalizationKey.localizedText
        run.summaryLocalizationKey = summaryLocalizationKey
        _ = await store.record(run)
        onRunChange?()
    }

    private func finishNonCancelledTerminal(
        _ run: inout WorkflowRun,
        runID: UUID,
        status: WorkflowRunStatus,
        summaryLocalizationKey: WorkflowHistoryLocalizationKey
    ) async -> Bool {
        if isCancelled(runID: runID) {
            await finish(
                &run,
                status: .cancelled,
                summaryLocalizationKey: .workflowCancelled
            )
            return true
        }
        await finish(
            &run,
            status: status,
            summaryLocalizationKey: summaryLocalizationKey
        )
        await terminalPersistenceCheckpoint()
        guard isCancelled(runID: runID) else {
            return false
        }
        await finish(
            &run,
            status: .cancelled,
            summaryLocalizationKey: .workflowCancelled
        )
        return true
    }

    private func recordRejectedRun(
        runID: UUID,
        workflow: WorkflowDefinition,
        source: WorkflowRunSource,
        summaryLocalizationKey: WorkflowHistoryLocalizationKey
    ) async {
        let timestamp = now()
        _ = await store.record(
            WorkflowRun(
                id: runID,
                workflowID: workflow.id,
                workflowName: workflow.name,
                source: source,
                startedAt: timestamp,
                finishedAt: timestamp,
                status: .failed,
                summaryLocalizationKey: summaryLocalizationKey
            )
        )
        onRunChange?()
    }

    private func isCancelled(runID: UUID) -> Bool {
        Task.isCancelled || cancelledRunIDs.contains(runID)
    }
}
