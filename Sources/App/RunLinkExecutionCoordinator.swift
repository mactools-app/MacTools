import AppKit
import Foundation
import SwiftUI
import MacToolsPluginKit

struct RunLinkExecutionFeedback: Equatable, Sendable {
    enum Tone: Equatable, Sendable {
        case success
        case failure
        case progress
    }

    enum Presentation: Equatable, Sendable {
        case standard
        case compact

        var size: NSSize {
            switch self {
            case .standard: NSSize(width: 360, height: 86)
            case .compact: NSSize(width: 280, height: 58)
            }
        }
    }

    enum BackgroundStyle: Equatable, Sendable {
        case runLinkMaterial
        case floatingPanel
    }

    let tone: Tone
    let title: String
    let message: String
    let presentation: Presentation
    let backgroundStyle: BackgroundStyle
    let dismissDelay: Duration?

    var accessibilityLabel: String {
        switch presentation {
        case .standard:
            FeatureL10n.joined([title, message])
        case .compact:
            title
        }
    }

    init(
        tone: Tone,
        title: String,
        message: String,
        presentation: Presentation = .standard,
        backgroundStyle: BackgroundStyle = .runLinkMaterial,
        dismissDelay: Duration? = nil
    ) {
        self.tone = tone
        self.title = title
        self.message = message
        self.presentation = presentation
        self.backgroundStyle = backgroundStyle
        self.dismissDelay = dismissDelay
    }
}

@MainActor
protocol RunLinkFeedbackPresenting: AnyObject {
    func present(_ feedback: RunLinkExecutionFeedback)
}

@MainActor
final class SystemRunLinkFeedbackPresenter: RunLinkFeedbackPresenting {
    static let panelIdentifier = NSUserInterfaceItemIdentifier("mactools.run-link.feedback")

    private let dismissDelay: Duration
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    init(dismissDelay: Duration = .seconds(4)) {
        self.dismissDelay = dismissDelay
    }

    func present(_ feedback: RunLinkExecutionFeedback) {
        guard let screen = NSScreen.main else { return }
        let size = feedback.presentation.size
        let visibleFrame = screen.visibleFrame
        let frame = NSRect(
            x: visibleFrame.maxX - size.width - 18,
            y: visibleFrame.maxY - size.height - 18,
            width: size.width,
            height: size.height
        )
        let panel: NSPanel
        if let existing = self.panel {
            panel = existing
            panel.setFrame(frame, display: true)
        } else {
            panel = NSPanel(
                contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            panel.identifier = Self.panelIdentifier
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.level = .statusBar
            panel.collectionBehavior = [
                .canJoinAllSpaces,
                .fullScreenAuxiliary,
                .transient,
                .ignoresCycle,
            ]
            self.panel = panel
        }
        panel.setAccessibilityLabel(feedback.accessibilityLabel)
        panel.contentView = NSHostingView(
            rootView: RuntimeLocalizedContent(content: RunLinkFeedbackView(feedback: feedback))
        )
        PluginPresentationSafety.prepareForWindowOrdering(panel)
        panel.orderFrontRegardless()

        dismissTask?.cancel()
        let effectiveDismissDelay = feedback.dismissDelay ?? dismissDelay
        dismissTask = Task { @MainActor [weak self, effectiveDismissDelay] in
            try? await Task.sleep(for: effectiveDismissDelay)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    isolated deinit {
        dismissTask?.cancel()
        panel?.close()
    }
}

private struct RunLinkFeedbackView: View {
    let feedback: RunLinkExecutionFeedback
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: feedback.tone.systemImage)
                .font(.title2)
                .foregroundStyle(feedback.tone.color)

            VStack(alignment: .leading, spacing: 4) {
                Text(feedback.title)
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                if feedback.presentation == .standard {
                    Text(feedback.message)
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(feedback.presentation == .compact ? 12 : 14)
        .frame(
            width: feedback.presentation.size.width,
            height: feedback.presentation.size.height
        )
        .background {
            background
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(feedback.accessibilityLabel)
    }

    @ViewBuilder
    private var background: some View {
        switch feedback.backgroundStyle {
        case .runLinkMaterial:
            RoundedRectangle(cornerRadius: 14)
                .fill(
                    reduceTransparency
                        ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
                        : AnyShapeStyle(.regularMaterial)
                )
        case .floatingPanel:
            PluginFloatingPanelSurface(
                shape: .roundedRectangle(cornerRadius: 14)
            )
        }
    }
}

private extension RunLinkExecutionFeedback.Tone {
    var systemImage: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .failure: "exclamationmark.triangle.fill"
        case .progress: "clock.arrow.circlepath"
        }
    }

    var color: Color {
        switch self {
        case .success: .green
        case .failure: .red
        case .progress: .accentColor
        }
    }
}

enum WindowLayoutActionFeedback {
    static func feedback(
        actionTitle: String?,
        outcome: ActionExecutionOutcome
    ) -> RunLinkExecutionFeedback? {
        let actionTitle = actionTitle ?? FeatureL10n.string("窗口布局")
        switch outcome {
        case let .completed(.succeeded(message)):
            guard let message else { return nil }
            return RunLinkExecutionFeedback(
                tone: .success,
                title: message,
                message: actionTitle,
                presentation: .compact,
                backgroundStyle: .floatingPanel,
                dismissDelay: .milliseconds(1_100)
            )
        case let .completed(.failed(message)):
            return RunLinkExecutionFeedback(
                tone: .failure,
                title: actionTitle,
                message: message,
                backgroundStyle: .floatingPanel
            )
        case .completed(.cancelled):
            return RunLinkExecutionFeedback(
                tone: .failure,
                title: actionTitle,
                message: FeatureL10n.string("操作已取消。"),
                backgroundStyle: .floatingPanel
            )
        case let .rejected(rejection):
            return RunLinkExecutionFeedback(
                tone: .failure,
                title: actionTitle,
                message: ActionSurfaceExecutionSupport.message(for: rejection),
                backgroundStyle: .floatingPanel
            )
        }
    }
}

@MainActor
final class AppActionConfirmationSheetSession {
    typealias Start = (@escaping (Bool) -> Void) -> Void

    private let start: Start
    private let dismiss: () -> Void
    private var continuation: CheckedContinuation<Bool, Never>?
    private var resolvedResult: Bool?

    init(start: @escaping Start, dismiss: @escaping () -> Void) {
        self.start = start
        self.dismiss = dismiss
    }

    func response() async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let resolvedResult {
                    continuation.resume(returning: resolvedResult)
                    return
                }
                self.continuation = continuation
                start { [weak self] result in
                    self?.finish(result)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel()
            }
        }
    }

    func cancel() {
        finish(false)
    }

    private func finish(_ result: Bool) {
        guard resolvedResult == nil else { return }
        resolvedResult = result
        dismiss()
        continuation?.resume(returning: result)
        continuation = nil
    }
}

@MainActor
final class AppActionConfirmationService: ActionConfirmationRequesting {
    private let windowProvider: @MainActor () -> NSWindow?

    init(windowProvider: @escaping @MainActor () -> NSWindow?) {
        self.windowProvider = windowProvider
    }

    func confirm(_ request: ActionConfirmationRequest) async -> Bool {
        guard let window = windowProvider() else {
            return false
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = request.confirmation.title
        alert.informativeText = request.confirmation.message
        alert.addButton(withTitle: request.confirmation.confirmButtonTitle)
        alert.addButton(withTitle: FeatureL10n.string("取消"))
        let session = AppActionConfirmationSheetSession(
            start: { completion in
                PluginPresentationSafety.prepareForWindowOrdering()
                alert.beginSheetModal(for: window) { response in
                    completion(response == .alertFirstButtonReturn)
                }
            },
            dismiss: {
                if window.attachedSheet === alert.window {
                    window.endSheet(alert.window, returnCode: .abort)
                }
            }
        )
        return await session.response()
    }
}

@MainActor
final class RunLinkExecutionCoordinator {
    private let registry: ActionRegistry
    private let executor: ActionExecutor
    private let runLinkService: ActionRunLinkService
    private let confirmationService: any ActionConfirmationRequesting
    private let feedbackPresenter: any RunLinkFeedbackPresenting

    init(
        registry: ActionRegistry,
        executor: ActionExecutor,
        runLinkService: ActionRunLinkService,
        confirmationService: any ActionConfirmationRequesting,
        feedbackPresenter: any RunLinkFeedbackPresenting
    ) {
        self.registry = registry
        self.executor = executor
        self.runLinkService = runLinkService
        self.confirmationService = confirmationService
        self.feedbackPresenter = feedbackPresenter
    }

    @discardableResult
    func execute(_ request: ActionRunLinkRequest) async -> AppURLActionHandlingDisposition {
        await execute(runLinkService.resolve(request))
    }

    func presentRoutingRejection(_ error: AppURLRoutingError) {
        let message: String
        switch error {
        case .actionAlreadyRunning:
            message = FeatureL10n.string("此操作已在等待或运行。")
        case .recursiveActionInvocation:
            message = FeatureL10n.string("已阻止递归运行链接。")
        default:
            message = FeatureL10n.string("操作未能开始。")
        }
        feedbackPresenter.present(
            RunLinkExecutionFeedback(
                tone: .failure,
                title: FeatureL10n.string("运行链接不可用"),
                message: message
            )
        )
    }

    @discardableResult
    func execute(
        _ resolution: Result<ActionReference, ActionRunLinkResolutionError>
    ) async -> AppURLActionHandlingDisposition {
        let reference: ActionReference
        switch resolution {
        case let .success(value):
            reference = value
        case let .failure(error):
            feedbackPresenter.present(
                RunLinkExecutionFeedback(
                    tone: .failure,
                    title: FeatureL10n.string("运行链接不可用"),
                    message: message(for: error)
                )
            )
            return .completed
        }

        guard case let .success(action) = registry.registeredAction(for: reference) else {
            feedbackPresenter.present(
                RunLinkExecutionFeedback(
                    tone: .failure,
                    title: FeatureL10n.string("运行链接不可用"),
                    message: FeatureL10n.string("操作提供方当前不可用。")
                )
            )
            return .completed
        }
        let mode: ActionExecutionMode = action.definition.capabilities
            .contains(.foregroundInteractive) ? .foreground : .background
        let invocation = ActionInvocation(reference: reference, source: .runLink, mode: mode)
        if action.definition.capabilities.contains(.reportsProgress) {
            let start = await executor.startContinuingTrackingCompletion(
                invocation,
                expectedDefinition: action.definition,
                confirmationService: confirmationService
            )
            feedbackPresenter.present(feedback(for: start.outcome))
            if let completion = start.completion {
                return .continuing(until: completion)
            }
            return .completed
        } else {
            let outcome = await executor.execute(
                invocation,
                confirmationService: confirmationService
            )
            feedbackPresenter.present(feedback(for: outcome))
            return .completed
        }
    }

    private func feedback(for outcome: ContinuingActionStartOutcome) -> RunLinkExecutionFeedback {
        switch outcome {
        case .started:
            RunLinkExecutionFeedback(
                tone: .progress,
                title: FeatureL10n.string("操作已开始"),
                message: FeatureL10n.string("操作将在后台继续运行。")
            )
        case .cancelled:
            RunLinkExecutionFeedback(
                tone: .failure,
                title: FeatureL10n.string("已取消"),
                message: FeatureL10n.string("操作已取消。")
            )
        case let .rejected(rejection):
            RunLinkExecutionFeedback(
                tone: .failure,
                title: FeatureL10n.string("操作未能开始。"),
                message: message(for: rejection)
            )
        }
    }

    private func feedback(for outcome: ActionExecutionOutcome) -> RunLinkExecutionFeedback {
        switch outcome {
        case .completed(.succeeded):
            return RunLinkExecutionFeedback(
                tone: .success,
                title: FeatureL10n.string("操作已完成"),
                message: FeatureL10n.string("运行链接执行成功。")
            )
        case .completed(.failed):
            return RunLinkExecutionFeedback(
                tone: .failure,
                title: FeatureL10n.string("失败"),
                message: FeatureL10n.string("操作未能完成。")
            )
        case .completed(.cancelled):
            return RunLinkExecutionFeedback(
                tone: .failure,
                title: FeatureL10n.string("已取消"),
                message: FeatureL10n.string("操作已取消。")
            )
        case let .rejected(rejection):
            return RunLinkExecutionFeedback(
                tone: .failure,
                title: FeatureL10n.string("操作未能开始。"),
                message: message(for: rejection)
            )
        }
    }

    private func message(for error: ActionRunLinkResolutionError) -> String {
        switch error {
        case .unknownAction:
            FeatureL10n.string("找不到对应操作。")
        case .unavailablePreset:
            FeatureL10n.string("运行链接预设不可用。")
        case .parameterizedDirectAction:
            FeatureL10n.string("此操作需要使用已保存的运行链接预设。")
        case .externalInvocationUnavailable:
            FeatureL10n.string("此操作不允许从外部调用。")
        case .sensitiveParametersUnsupported:
            FeatureL10n.string("包含敏感参数的预设不能通过运行链接调用。")
        }
    }

    private func message(for rejection: ActionExecutionRejection) -> String {
        switch rejection {
        case .unknownAction, .providerChanged:
            FeatureL10n.string("操作提供方已发生变化，请重试。")
        case .invalidParameters:
            FeatureL10n.string("运行链接参数无效。")
        case .providerFailure:
            FeatureL10n.string("操作未能开始。")
        case let .unavailable(reason):
            reason ?? FeatureL10n.string("操作当前不可用。")
        case .backgroundExecutionUnsupported, .foregroundExecutionUnsupported:
            FeatureL10n.string("操作不支持当前执行方式。")
        case .automaticExecutionUnsupported:
            FeatureL10n.string("此操作未获准自动运行。")
        case .confirmationRequiredForAutomaticExecution:
            FeatureL10n.string("工作流包含需要确认的操作，无法自动运行。")
        case .externalInvocationUnavailable:
            FeatureL10n.string("此操作不允许从外部调用。")
        case .systemExposureUnavailable:
            FeatureL10n.string("操作不可用。")
        case .confirmationUnavailable:
            FeatureL10n.string("此操作需要确认，但无法显示确认界面。")
        case .confirmationDenied:
            FeatureL10n.string("操作已取消。")
        case .confirmationTimedOut:
            FeatureL10n.string("确认已超时。")
        case .actionAlreadyRunning:
            FeatureL10n.string("此操作正在运行。")
        case .executionTimedOut:
            FeatureL10n.string("操作超时。")
        }
    }
}
