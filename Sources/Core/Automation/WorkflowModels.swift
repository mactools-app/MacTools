import Foundation
import MacToolsPluginKit

enum WorkflowStepErrorPolicy: String, Codable, CaseIterable, Sendable {
    case stop
    case continueRunning
}

struct WorkflowStep: Codable, Equatable, Sendable, Identifiable {
    static let maximumDelaySeconds: Double = 3_600
    static let maximumLabelByteCount = 120

    let id: UUID
    var reference: ActionReference
    var label: String?
    var delaySeconds: Double
    var errorPolicy: WorkflowStepErrorPolicy

    init(
        id: UUID = UUID(),
        reference: ActionReference,
        label: String? = nil,
        delaySeconds: Double = 0,
        errorPolicy: WorkflowStepErrorPolicy = .stop
    ) {
        self.id = id
        self.reference = reference
        self.label = label
        self.delaySeconds = delaySeconds
        self.errorPolicy = errorPolicy
    }
}

struct WorkflowDefinition: Codable, Equatable, Sendable, Identifiable {
    static let currentFormatVersion = 1
    static let maximumNameByteCount = 80
    static let maximumStepCount = 64

    let formatVersion: Int
    let id: UUID
    var name: String
    var systemImage: String
    var isEnabled: Bool
    var steps: [WorkflowStep]
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        systemImage: String = "bolt.horizontal.circle",
        isEnabled: Bool = true,
        steps: [WorkflowStep] = [],
        createdAt: Date = .now,
        updatedAt: Date = .now,
        formatVersion: Int = currentFormatVersion
    ) {
        self.formatVersion = formatVersion
        self.id = id
        self.name = name
        self.systemImage = systemImage
        self.isEnabled = isEnabled
        self.steps = steps
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var actionKey: ActionKey {
        ActionKey(
            providerID: AutomationController.providerID,
            actionID: "workflow.\(id.uuidString.lowercased())"
        )
    }

    var actionReference: ActionReference {
        ActionReference(key: actionKey)
    }
}

enum WorkflowRunSource: Codable, Equatable, Sendable {
    case manual
    case test
    case publishedAction(ActionExecutionSource)
    case automatic(ruleID: UUID, triggerKind: String)

    var requiresUnattendedExecution: Bool {
        switch self {
        case .automatic, .publishedAction(.automaticRule):
            true
        case .manual, .test, .publishedAction:
            false
        }
    }
}

enum WorkflowRunStatus: String, Codable, Equatable, Sendable {
    case running
    case succeeded
    case failed
    case cancelled
    case interrupted
    case skipped
}

enum WorkflowStepRunStatus: String, Codable, Equatable, Sendable {
    case succeeded
    case failed
    case cancelled
    case timedOut
    case unavailable
    case skipped
}

enum WorkflowHistoryLocalizationKey: String, Codable, Equatable, Sendable {
    case recursiveInvocation = "检测到递归工作流调用。"
    case maximumDepthExceeded = "工作流嵌套层级已达上限。"
    case workflowCancelled = "工作流已取消。"
    case requiredActionUnavailable = "必需操作不可用。"
    case stoppedAtFailedStep = "工作流在失败步骤处停止。"
    case completedWithFailures = "工作流已完成，但部分步骤失败。"
    case completed = "工作流已完成。"
    case actionVersionUnavailable = "操作版本不可用。"
    case actionFailed = "操作未能完成。"
    case actionCancelled = "操作已取消。"
    case actionTimedOut = "操作超时。"
    case actionUnavailable = "操作当前不可用。"
    case actionDidNotStart = "操作未能开始。"
    case notRun = "未执行。"
    case interruptedByExit = "MacTools 上次退出时，工作流仍在运行。"

    var localizedText: String {
        switch self {
        case .recursiveInvocation: FeatureL10n.string("检测到递归工作流调用。")
        case .maximumDepthExceeded: FeatureL10n.string("工作流嵌套层级已达上限。")
        case .workflowCancelled: FeatureL10n.string("工作流已取消。")
        case .requiredActionUnavailable: FeatureL10n.string("必需操作不可用。")
        case .stoppedAtFailedStep: FeatureL10n.string("工作流在失败步骤处停止。")
        case .completedWithFailures: FeatureL10n.string("工作流已完成，但部分步骤失败。")
        case .completed: FeatureL10n.string("工作流已完成。")
        case .actionVersionUnavailable: FeatureL10n.string("操作版本不可用。")
        case .actionFailed: FeatureL10n.string("操作未能完成。")
        case .actionCancelled: FeatureL10n.string("操作已取消。")
        case .actionTimedOut: FeatureL10n.string("操作超时。")
        case .actionUnavailable: FeatureL10n.string("操作当前不可用。")
        case .actionDidNotStart: FeatureL10n.string("操作未能开始。")
        case .notRun: FeatureL10n.string("未执行。")
        case .interruptedByExit: FeatureL10n.string("MacTools 上次退出时，工作流仍在运行。")
        }
    }
}

enum WorkflowStepTitleSource: String, Codable, Equatable, Sendable {
    case action
    case custom
}

struct AutomationSkippedRunSummary: Codable, Equatable, Sendable {
    let ruleName: String
    let reason: AutomationRunSkipReason

    var localizedText: String {
        FeatureL10n.format(
            "规则“%@”未运行：%@",
            ruleName,
            reason.localizedText
        )
    }
}

struct WorkflowStepRunResult: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let stepID: UUID
    let actionKey: ActionKey
    var title: String
    var titleSource: WorkflowStepTitleSource?
    var actionReference: ActionReference?
    let startedAt: Date?
    let finishedAt: Date
    let status: WorkflowStepRunStatus
    let message: String?
    var messageLocalizationKey: WorkflowHistoryLocalizationKey?

    init(
        id: UUID = UUID(),
        stepID: UUID,
        actionKey: ActionKey,
        title: String,
        titleSource: WorkflowStepTitleSource? = nil,
        actionReference: ActionReference? = nil,
        startedAt: Date?,
        finishedAt: Date,
        status: WorkflowStepRunStatus,
        message: String? = nil,
        messageLocalizationKey: WorkflowHistoryLocalizationKey? = nil
    ) {
        self.id = id
        self.stepID = stepID
        self.actionKey = actionKey
        self.title = title
        self.titleSource = titleSource
        self.actionReference = actionReference
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.message = messageLocalizationKey?.localizedText ?? message
        self.messageLocalizationKey = messageLocalizationKey
    }

    var localizedMessage: String? {
        messageLocalizationKey?.localizedText ?? message
    }
}

struct WorkflowRun: Codable, Equatable, Sendable, Identifiable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let id: UUID
    let workflowID: UUID
    let workflowName: String
    let source: WorkflowRunSource
    let startedAt: Date
    var finishedAt: Date?
    var status: WorkflowRunStatus
    var stepResults: [WorkflowStepRunResult]
    var summary: String?
    var summaryLocalizationKey: WorkflowHistoryLocalizationKey?
    var automationSkippedSummary: AutomationSkippedRunSummary?

    init(
        id: UUID = UUID(),
        workflowID: UUID,
        workflowName: String,
        source: WorkflowRunSource,
        startedAt: Date = .now,
        finishedAt: Date? = nil,
        status: WorkflowRunStatus = .running,
        stepResults: [WorkflowStepRunResult] = [],
        summary: String? = nil,
        summaryLocalizationKey: WorkflowHistoryLocalizationKey? = nil,
        automationSkippedSummary: AutomationSkippedRunSummary? = nil,
        formatVersion: Int = currentFormatVersion
    ) {
        self.formatVersion = formatVersion
        self.id = id
        self.workflowID = workflowID
        self.workflowName = workflowName
        self.source = source
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.stepResults = stepResults
        self.summary = summaryLocalizationKey?.localizedText ?? summary
        self.summaryLocalizationKey = summaryLocalizationKey
        self.automationSkippedSummary = automationSkippedSummary
    }

    var localizedSummary: String? {
        automationSkippedSummary?.localizedText
            ?? summaryLocalizationKey?.localizedText
            ?? summary
    }
}

enum WorkflowStoreError: Error, Equatable {
    case invalidWorkflow(String)
    case workflowNotFound
    case maximumWorkflowCountReached
    case persistenceFailed
    case recoveryRequired
    case unsafeForExport
    case invalidImport
}

enum WorkflowStartError: Error, Equatable {
    case workflowNotFound
    case workflowDisabled
    case emptyWorkflow
    case recursiveInvocation
    case maximumDepthExceeded
    case backgroundExecutionUnsupported
    case automaticExecutionUnsupported
    case confirmationRequiredForAutomaticExecution
    case alreadyRunning
}

struct WorkflowExecutionHandle {
    let runID: UUID
    let actionHandle: ActionExecutionHandle
}

enum WorkflowExecutionContext {
    @TaskLocal static var workflowStack: [UUID] = []
}
