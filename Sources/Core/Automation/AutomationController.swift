import Combine
import Foundation
import MacToolsPluginKit

@MainActor
final class AutomationController: ObservableObject {
    private enum ErrorState: Equatable {
        case cannotDeleteRelatedRules
        case cannotDeleteWorkflow
        case cannotMoveWorkflow
        case workflowNotFound
        case workflowStore(WorkflowStoreError)
        case ruleStore(AutomationRuleStoreError)
        case workflowStart(WorkflowStartError)
    }

    nonisolated static let providerID = "automation"

    @Published private(set) var workflows: [WorkflowDefinition] = []
    @Published private(set) var rules: [AutomationRule] = []
    @Published private(set) var history: [WorkflowRun] = []
    @Published private(set) var activeRunIDs: Set<UUID> = []
    @Published private var lastError: ErrorState?

    var lastErrorMessage: String? {
        lastError.map(localizedMessage(for:))
    }

    var definitionLoadErrorMessage: String? {
        if store.workflowLoadError != nil {
            return FeatureL10n.string("无法读取工作流数据；请先导入备份恢复。")
        }
        if ruleStore.loadError != nil {
            return FeatureL10n.string("无法读取自动规则数据；请先导入备份恢复。")
        }
        return nil
    }

    var canEditDefinitions: Bool {
        definitionLoadErrorMessage == nil
    }

    private let store: WorkflowStore
    private let ruleStore: AutomationRuleStore
    private let registry: ActionRegistry
    private let runner: WorkflowRunner
    private var runtime: AutomationRuntime?
    private let calendarProvider: SystemCalendarAutomationTriggerProvider?
    private var startedHandles: [UUID: ActionExecutionHandle] = [:]

    var onCatalogChange: (() -> Void)?
    var actionReferencePortability: ((ActionReference) -> ActionReferencePortability)?

    init(
        store: WorkflowStore,
        ruleStore: AutomationRuleStore? = nil,
        registry: ActionRegistry,
        executor: ActionExecutor,
        runner: WorkflowRunner? = nil,
        systemServices: SystemAutomationServices? = nil
    ) {
        self.store = store
        self.ruleStore = ruleStore ?? AutomationRuleStore(
            definitionStore: store.definitionStore
        )
        self.registry = registry
        self.runner = runner ?? WorkflowRunner(
            store: store,
            registry: registry,
            executor: executor
        )
        self.calendarProvider = systemServices?.calendarProvider
        if let systemServices {
            self.runtime = AutomationRuntime(
                ruleStore: self.ruleStore,
                workflowStore: store,
                workflowStarter: self.runner,
                snapshotProvider: systemServices.snapshotProvider,
                providers: systemServices.providers
            )
        }
        self.runner.onRunChange = { [weak self] in
            self?.reloadRuntimeSnapshots()
        }
        self.runtime?.onChange = { [weak self] in
            self?.reloadRuntimeSnapshots()
        }
        reloadAll()
    }

    func startAutomaticRules() {
        runtime?.start()
    }

    func stopAutomaticRules() {
        runtime?.stop()
    }

    @discardableResult
    func createWorkflow() -> WorkflowDefinition? {
        switch store.create() {
        case let .success(workflow):
            finishDefinitionMutation()
            return workflow
        case let .failure(error):
            record(error)
            return nil
        }
    }

    @discardableResult
    func duplicateWorkflow(id: UUID) -> WorkflowDefinition? {
        switch store.duplicate(id: id) {
        case let .success(workflow):
            finishDefinitionMutation()
            return workflow
        case let .failure(error):
            record(error)
            return nil
        }
    }

    @discardableResult
    func deleteWorkflow(id: UUID) -> Bool {
        let runsToCancel = runner.trackedRunIDs(for: id)
        let existingWorkflows = store.workflows()
        let retainedWorkflows = existingWorkflows.filter { $0.id != id }
        guard retainedWorkflows.count != existingWorkflows.count,
              store.definitionStore.sharesStorage(with: ruleStore.definitionStore) else {
            lastError = .cannotDeleteWorkflow
            return false
        }
        let existingRules = ruleStore.rules()
        let retainedRules = existingRules.filter { $0.workflowID != id }
        guard store.replaceDefinitions(
            workflows: retainedWorkflows,
            rules: retainedRules,
            allowsRecovery: false
        ) else {
            lastError = .cannotDeleteWorkflow
            return false
        }
        runsToCancel.forEach(cancel(runID:))
        finishDefinitionMutation()
        return true
    }

    func moveWorkflow(id: UUID, offset: Int) {
        guard store.move(id: id, offset: offset) else {
            lastError = .cannotMoveWorkflow
            return
        }
        finishDefinitionMutation()
    }

    @discardableResult
    func createRule(workflowID: UUID) -> AutomationRule? {
        switch ruleStore.create(workflowID: workflowID) {
        case let .success(rule):
            finishRuleMutation()
            return rule
        case let .failure(error):
            record(error)
            return nil
        }
    }

    @discardableResult
    func duplicateRule(id: UUID) -> AutomationRule? {
        switch ruleStore.duplicate(id: id) {
        case let .success(rule):
            finishRuleMutation()
            return rule
        case let .failure(error):
            record(error)
            return nil
        }
    }

    func deleteRule(id: UUID) {
        guard ruleStore.delete(id: id) else { return }
        finishRuleMutation()
    }

    func saveRule(_ rule: AutomationRule) {
        switch ruleStore.upsert(rule) {
        case .success:
            finishRuleMutation()
        case let .failure(error):
            record(error)
        }
    }

    func rules(workflowID: UUID) -> [AutomationRule] {
        rules.filter { $0.workflowID == workflowID }
    }

    func triggerAvailability(for kind: AutomationTriggerKind) -> AutomationTriggerAvailability {
        runtime?.availability(for: kind) ?? .unavailable(FeatureL10n.string("触发器服务未启动。"))
    }

    func requestCalendarAccess() async {
        _ = await calendarProvider?.requestAccess()
        runtime?.refreshProviders()
        objectWillChange.send()
    }

    func setWorkflowEnabled(_ isEnabled: Bool, id: UUID) {
        mutateWorkflow(id: id) { $0.isEnabled = isEnabled }
    }

    func renameWorkflow(id: UUID, name: String) {
        mutateWorkflow(id: id) { $0.name = name }
    }

    func setWorkflowIcon(id: UUID, systemImage: String) {
        mutateWorkflow(id: id) { $0.systemImage = systemImage }
    }

    func addStep(workflowID: UUID, reference: ActionReference) {
        mutateWorkflow(id: workflowID) { workflow in
            guard workflow.steps.count < WorkflowDefinition.maximumStepCount else {
                return
            }
            workflow.steps.append(WorkflowStep(reference: reference))
        }
    }

    func replaceStepReference(
        workflowID: UUID,
        stepID: UUID,
        reference: ActionReference
    ) {
        mutateStep(workflowID: workflowID, stepID: stepID) { step in
            step.reference = reference
        }
    }

    func updateStep(
        workflowID: UUID,
        stepID: UUID,
        label: String?,
        delaySeconds: Double,
        errorPolicy: WorkflowStepErrorPolicy
    ) {
        mutateStep(workflowID: workflowID, stepID: stepID, rebuildCatalog: false) { step in
            let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
            step.label = trimmed?.isEmpty == false ? trimmed : nil
            step.delaySeconds = min(
                max(0, delaySeconds),
                WorkflowStep.maximumDelaySeconds
            )
            step.errorPolicy = errorPolicy
        }
    }

    func removeStep(workflowID: UUID, stepID: UUID) {
        mutateWorkflow(id: workflowID) { workflow in
            workflow.steps.removeAll { $0.id == stepID }
        }
    }

    func moveStep(workflowID: UUID, stepID: UUID, offset: Int) {
        mutateWorkflow(id: workflowID) { workflow in
            guard let source = workflow.steps.firstIndex(where: { $0.id == stepID }) else {
                return
            }
            let destination = source + offset
            guard workflow.steps.indices.contains(destination) else {
                return
            }
            let step = workflow.steps.remove(at: source)
            workflow.steps.insert(step, at: destination)
        }
    }

    @discardableResult
    func startWorkflow(
        id: UUID,
        test: Bool = false,
        mode: ActionExecutionMode = .foreground
    ) -> UUID? {
        let source: WorkflowRunSource = test ? .test : .manual
        switch runner.makeExecutionHandle(workflowID: id, source: source, mode: mode) {
        case let .success(execution):
            startedHandles[execution.runID] = execution.actionHandle
            Task { @MainActor [weak self] in
                _ = await execution.actionHandle.result()
                self?.startedHandles.removeValue(forKey: execution.runID)
                self?.reloadRuntimeSnapshots()
            }
            reloadRuntimeSnapshots()
            return execution.runID
        case let .failure(error):
            lastError = .workflowStart(error)
            return nil
        }
    }

    func cancel(runID: UUID) {
        runner.cancel(runID: runID)
    }

    func activeRunIDs(for workflowID: UUID) -> [UUID] {
        runner.activeRunIDs(for: workflowID)
    }

    func recentRuns(workflowID: UUID, limit: Int = 20) -> [WorkflowRun] {
        Array(history.lazy.filter { $0.workflowID == workflowID }.prefix(max(0, limit)))
    }

    func preferencesBackupSnapshot() -> (workflows: [WorkflowDefinition], rules: [AutomationRule]) {
        (store.workflows(), ruleStore.rules())
    }

    @discardableResult
    func restorePreferences(
        workflows importedWorkflows: [WorkflowDefinition],
        rules importedRules: [AutomationRule]
    ) -> Bool {
        let workflowIDs = Set(importedWorkflows.map(\.id))
        guard importedRules.allSatisfy({ workflowIDs.contains($0.workflowID) }) else {
            return false
        }
        guard store.definitionStore.sharesStorage(with: ruleStore.definitionStore),
              store.replaceDefinitions(
                  workflows: importedWorkflows,
                  rules: importedRules,
                  allowsRecovery: true
              ) else {
            return false
        }

        runner.trackedRunIDs.forEach(cancel(runID:))
        lastError = nil
        reloadAll()
        runtime?.refreshProviders()
        onCatalogChange?()
        return true
    }

    func definition(for reference: ActionReference) -> ActionDefinition? {
        registry.definition(for: reference.key)
    }

    func catalogEntry(for reference: ActionReference) -> ActionCatalogEntry? {
        guard case let .success(action) = registry.registeredAction(for: reference) else {
            return nil
        }
        return action.catalogEntry
    }

    func availability(for reference: ActionReference) -> ActionAvailability {
        registry.availability(for: reference)
    }

    func actionRegistration(
        definitionLookup: ((ActionKey) -> ActionDefinition?)? = nil
    ) -> ActionProviderRegistration {
        let definitionLookup = definitionLookup ?? { [registry] key in
            registry.definition(for: key)
        }
        let enabled = workflows.filter(\.isEnabled)
        let definitions = enabled.map { workflow in
            let analysis = WorkflowExecutionAnalysis.analyze(
                workflowID: workflow.id,
                store: store,
                definition: definitionLookup
            )
            var capabilities: ActionExecutionCapabilities = [
                .foregroundInteractive,
                .cancellable,
                .reportsProgress,
            ]
            if analysis.supportsBackground {
                capabilities.insert(.background)
            }
            if analysis.supportsUnattendedExecution {
                capabilities.insert(.automatic)
            }
            return ActionDefinition(
                key: workflow.actionKey,
                title: FeatureL10n.format("运行“%@”", workflow.name),
                description: FeatureL10n.format(
                    "依次执行 %d 个工作流步骤。",
                    workflow.steps.count
                ),
                keywords: [FeatureL10n.string("工作流"), FeatureL10n.string("自动化"), workflow.name],
                systemImage: workflow.systemImage,
                externalInvocationPolicy: analysis.allowsExternalInvocation
                    ? .allowed
                    : .unavailable,
                capabilities: capabilities,
                executionTimeoutSeconds: 86_400
            )
        }
        let catalogEntries = enabled.map { workflow in
            ActionCatalogEntry(
                reference: workflow.actionReference,
                title: FeatureL10n.format("运行“%@”", workflow.name),
                subtitle: FeatureL10n.format(
                    "自动化 · %d 个步骤",
                    workflow.steps.count
                )
            )
        }
        return ActionProviderRegistration(
            providerID: Self.providerID,
            identity: ObjectIdentifier(self),
            definitions: definitions,
            catalogEntries: catalogEntries,
            availability: { [weak self] reference in
                self?.workflowActionAvailability(reference)
                    ?? .unavailable(FeatureL10n.string("自动化服务不可用。"))
            },
            exposurePolicy: { [weak self] reference, surface in
                self?.workflowActionExposurePolicy(reference, surface: surface) ?? .excluded
            },
            begin: { [weak self] invocation in
                guard let self,
                      let workflowID = self.workflowID(for: invocation.reference.key) else {
                    return .failure(.providerFailure(FeatureL10n.string("找不到工作流。")))
                }
                let source = WorkflowRunSource.publishedAction(invocation.source)
                switch self.runner.makeExecutionHandle(
                    workflowID: workflowID,
                    source: source,
                    mode: invocation.mode
                ) {
                case let .success(execution):
                    return .success(execution.actionHandle)
                case let .failure(error):
                    return .failure(.providerFailure(self.message(for: error)))
                }
            }
        )
    }

    @discardableResult
    func migrateReferencesIfNeeded() -> Bool {
        guard store.migrateReferences(using: registry) else {
            return false
        }
        workflows = store.workflows()
        objectWillChange.send()
        return true
    }

    func exportWorkflow(id: UUID) -> Result<Data, WorkflowStoreError> {
        store.exportWorkflow(
            id: id,
            registry: registry,
            referencePortability: actionReferencePortability
        )
    }

    @discardableResult
    func importWorkflow(_ data: Data) -> WorkflowDefinition? {
        switch store.importWorkflow(data) {
        case let .success(workflow):
            finishDefinitionMutation()
            return workflow
        case let .failure(error):
            record(error)
            return nil
        }
    }

    private func mutateWorkflow(
        id: UUID,
        rebuildCatalog: Bool = true,
        mutation: (inout WorkflowDefinition) -> Void
    ) {
        guard var workflow = store.workflow(id: id) else {
            lastError = .workflowNotFound
            return
        }
        mutation(&workflow)
        switch store.upsert(workflow) {
        case .success:
            finishDefinitionMutation(rebuildCatalog: rebuildCatalog)
        case let .failure(error):
            record(error)
        }
    }

    private func mutateStep(
        workflowID: UUID,
        stepID: UUID,
        rebuildCatalog: Bool = true,
        mutation: (inout WorkflowStep) -> Void
    ) {
        mutateWorkflow(id: workflowID, rebuildCatalog: rebuildCatalog) { workflow in
            guard let index = workflow.steps.firstIndex(where: { $0.id == stepID }) else {
                return
            }
            mutation(&workflow.steps[index])
        }
    }

    private func finishDefinitionMutation(rebuildCatalog: Bool = true) {
        lastError = nil
        reloadAll()
        if rebuildCatalog {
            onCatalogChange?()
        }
    }

    private func finishRuleMutation() {
        lastError = nil
        rules = ruleStore.rules()
        runtime?.refreshProviders()
    }

    private func reloadAll() {
        workflows = store.workflows()
        rules = ruleStore.rules()
        reloadRuntimeSnapshots()
    }

    private func reloadRuntimeSnapshots() {
        history = store.history()
        activeRunIDs = runner.activeRunIDs
    }

    private func workflowActionAvailability(_ reference: ActionReference) -> ActionAvailability {
        guard let currentWorkflowID = workflowID(for: reference.key) else {
            return .unavailable(FeatureL10n.string("工作流已停用或不存在。"))
        }
        return WorkflowExecutionAnalysis.analyze(
            workflowID: currentWorkflowID,
            store: store,
            definition: registry.definition(for:),
            availability: registry.availability(for:)
        ).availability
    }

    private func workflowActionExposurePolicy(
        _ reference: ActionReference,
        surface: ActionExposureSurface
    ) -> ActionExposurePolicy {
        guard surface == .appIntents else { return .automatic }
        guard let currentWorkflowID = workflowID(for: reference.key) else {
            return .excluded
        }
        return WorkflowExecutionAnalysis.allLeafActions(
            in: currentWorkflowID,
            store: store
        ) { [registry] leafReference in
            AppIntentActionEligibility.isDirectlyEligible(
                leafReference,
                registry: registry,
                requireAvailability: false
            )
        } ? .automatic : .excluded
    }

    func supportsAutomaticRules(workflowID: UUID) -> Bool {
        automaticRuleAvailability(workflowID: workflowID).isAvailable
    }

    func automaticRuleAvailability(workflowID: UUID) -> ActionAvailability {
        let analysis = WorkflowExecutionAnalysis.analyze(
            workflowID: workflowID,
            store: store,
            definition: registry.definition(for:),
            availability: registry.availability(for:)
        )
        guard analysis.availability.isAvailable else { return analysis.availability }
        guard analysis.supportsBackground else {
            return .unavailable(FeatureL10n.string(
                "此工作流包含需要交互的操作，不能由自动规则在后台运行。"
            ))
        }
        guard analysis.supportsUnattendedExecution else {
            return .unavailable(
                analysis.requiresConfirmation
                    ? FeatureL10n.string("工作流包含需要确认的操作，无法自动运行。")
                    : FeatureL10n.string("工作流包含未获准自动运行的操作。")
            )
        }
        return .available
    }

    private func workflowID(for key: ActionKey) -> UUID? {
        guard key.providerID == Self.providerID,
              key.actionID.hasPrefix("workflow.") else {
            return nil
        }
        return UUID(uuidString: String(key.actionID.dropFirst("workflow.".count)))
    }

    private func record(_ error: WorkflowStoreError) {
        lastError = .workflowStore(error)
    }

    private func record(_ error: AutomationRuleStoreError) {
        lastError = .ruleStore(error)
    }

    private func localizedMessage(for state: ErrorState) -> String {
        switch state {
        case .cannotDeleteRelatedRules:
            FeatureL10n.string("无法删除相关自动规则。")
        case .cannotDeleteWorkflow:
            FeatureL10n.string("无法删除工作流。")
        case .cannotMoveWorkflow:
            FeatureL10n.string("无法调整工作流顺序。")
        case .workflowNotFound:
            FeatureL10n.string("找不到工作流。")
        case let .workflowStore(error):
            switch error {
        case let .invalidWorkflow(reason): FeatureL10n.format("工作流无效：%@", reason)
        case .workflowNotFound: FeatureL10n.string("找不到工作流。")
        case .maximumWorkflowCountReached: FeatureL10n.string("工作流数量已达上限。")
        case .persistenceFailed: FeatureL10n.string("无法保存工作流。")
        case .recoveryRequired: FeatureL10n.string("无法读取工作流数据；请先导入备份恢复。")
        case .unsafeForExport: FeatureL10n.string("工作流包含不可安全导出的参数。")
        case .invalidImport: FeatureL10n.string("工作流文件无效。")
            }
        case let .ruleStore(error):
            switch error {
        case let .invalidRule(reason): FeatureL10n.format("自动规则无效：%@", reason)
        case .ruleNotFound: FeatureL10n.string("找不到自动规则。")
        case .maximumRuleCountReached: FeatureL10n.string("自动规则数量已达上限。")
        case .persistenceFailed: FeatureL10n.string("无法保存自动规则。")
        case .recoveryRequired: FeatureL10n.string("无法读取自动规则数据；请先导入备份恢复。")
            }
        case let .workflowStart(error):
            message(for: error)
        }
    }

    private func message(for error: WorkflowStartError) -> String {
        switch error {
        case .workflowNotFound: FeatureL10n.string("找不到工作流。")
        case .workflowDisabled: FeatureL10n.string("工作流已停用。")
        case .emptyWorkflow: FeatureL10n.string("工作流尚未添加步骤。")
        case .recursiveInvocation: FeatureL10n.string("检测到递归工作流调用。")
        case .maximumDepthExceeded: FeatureL10n.string("工作流嵌套层级已达上限。")
        case .backgroundExecutionUnsupported:
            FeatureL10n.string("工作流包含只能交互运行的操作。")
        case .automaticExecutionUnsupported:
            FeatureL10n.string("工作流包含未获准自动运行的操作。")
        case .confirmationRequiredForAutomaticExecution:
            FeatureL10n.string("工作流包含需要确认的操作，无法自动运行。")
        case .alreadyRunning:
            FeatureL10n.string("此工作流正在运行。")
        }
    }
}
