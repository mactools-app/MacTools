import AppKit
import Foundation
import SwiftUI
import MacToolsPluginKit

public final class SystemSoftRestartPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        SystemSoftRestartPluginProvider(context: context)
    }
}

@MainActor
private struct SystemSoftRestartPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        let localization = PluginLocalization(bundle: context.resourceBundle)
        let helperURL = context.resourceBundle.resourceURL?
            .appendingPathComponent("RestartHelper", isDirectory: true)
            .appendingPathComponent("mactools-system-soft-restart-helper", isDirectory: false)
        let runner = SystemSoftRestartRunner(
            helperURL: helperURL,
            supportDirectory: context.supportDirectory,
            temporaryDirectory: context.temporaryDirectory,
            localization: localization
        )
        return [SystemSoftRestartPlugin(
            storage: context.storage,
            runner: runner,
            presenter: SystemSoftRestartWindowPresenter(localization: localization),
            localization: localization
        )]
    }
}

@MainActor
final class SystemSoftRestartPlugin:
    MacToolsPlugin, DropZoneAnchorProviding, PluginActionProviding {
    var panelItems: [PluginPanelItem] {
        let state = rowState
        let descriptor = rowDescriptor
        return [
            .row(id: "control", initialPlacement: .featurePanel,
                 descriptor: descriptor, state: state,
                 action: { [weak self] in self?.handleAction($0) }),
            .iconWidget(
                id: "quick-control",
                title: localization.string("metadata.title", defaultValue: metadata.title),
                systemImage: metadata.iconName,
                control: .button,
                state: state,
                menuActionBehavior: descriptor.menuActionBehavior,
                action: { [weak self] in self?.handleAction($0) }
            ),
        ]
    }

    static let pluginID = "system-soft-restart"

    private enum StorageKey {
        static let reopensApplications = "reopens-applications"
        static let preservesDockLayout = "preserves-dock-layout"
    }

    private enum ControlID {
        static let execute = "execute"
        static let reopensApplications = "reopens-applications"
        static let preservesDockLayout = "preserves-dock-layout"
    }

    private enum ActionID {
        static let restart = "restart-user-services"
    }

    var metadata: PluginMetadata {
        PluginMetadata(
            id: Self.pluginID,
            title: localization.string("metadata.title", defaultValue: "系统软重启"),
            iconName: "arrow.clockwise.circle.fill",
            iconTint: Color(nsColor: .systemOrange),
            order: 98,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "重启 macOS 用户服务，尝试恢复输入法、音频、AirDrop 等运行时异常"
            )
        )
    }
    let rowDescriptor: PluginPanelRowDescriptor

    var anchorRectProvider: (() -> NSRect?)?
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let storage: PluginStorage
    private let runner: SystemSoftRestartRunning
    private let presenter: SystemSoftRestartPresenting
    private let localization: PluginLocalization
    private let applicationURLProvider: () -> [URL]
    private var isExecuting = false
    private var currentPhase: SystemSoftRestartPhase?
    private var lastErrorMessage: String?
    private var executionTask: Task<Void, Never>?

    init(
        storage: PluginStorage = UserDefaultsPluginStorage(pluginID: SystemSoftRestartPlugin.pluginID),
        runner: SystemSoftRestartRunning,
        presenter: SystemSoftRestartPresenting,
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        applicationURLProvider: (() -> [URL])? = nil
    ) {
        self.storage = storage
        self.runner = runner
        self.presenter = presenter
        self.localization = localization
        self.applicationURLProvider = applicationURLProvider ?? {
            SystemSoftRestartApplicationScanner().runningApplicationURLs(
                excludingProcessIdentifier: ProcessInfo.processInfo.processIdentifier
            )
        }
        self.rowDescriptor = PluginPanelRowDescriptor(
            controlStyle: .button,
            menuActionBehavior: .dismissBeforeHandling,
            buttonTitleProvider: {
                localization.string("panel.button.restart", defaultValue: "修复")
            }
        )

        if storage.object(forKey: StorageKey.reopensApplications) == nil {
            storage.set(true, forKey: StorageKey.reopensApplications)
        }
        if storage.object(forKey: StorageKey.preservesDockLayout) == nil {
            storage.set(true, forKey: StorageKey.preservesDockLayout)
        }
    }

    var permissionRequirements: [PluginPermissionRequirement] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    var actionDefinitions: [ActionDefinition] {
        [
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.restart),
                title: metadata.title,
                description: metadata.defaultDescription,
                keywords: [metadata.title, "soft restart", "launchd", "repair", "修复", "重启服务"],
                systemImage: metadata.iconName,
                risk: .confirmationRequired,
                confirmation: ActionConfirmation(
                    title: localization.string("confirm.title", defaultValue: "重启用户服务？"),
                    message: localization.string(
                        "confirm.message",
                        defaultValue: "运行中的应用将立即退出，未保存的内容可能丢失。"
                    ),
                    confirmButtonTitle: localization.string("confirm.action", defaultValue: "重启用户服务")
                ),
                externalInvocationPolicy: .unavailable,
                capabilities: [.foregroundInteractive, .reportsProgress],
                concurrencyPolicy: .rejectWhileRunning,
                executionTimeoutSeconds: 120
            ),
        ]
    }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        guard reference.key.actionID == ActionID.restart else {
            return .unavailable(PluginKitLocalization.actionUnavailable)
        }
        guard runner.isAvailable else {
            return .unavailable(localization.string(
                "error.helperUnavailable",
                defaultValue: "当前插件包缺少系统软重启组件。"
            ))
        }
        return isExecuting
            ? .unavailable(localization.string("status.running", defaultValue: "系统软重启正在进行"))
            : .available
    }

    var rowState: PluginPanelRowState {
        PluginPanelRowState(
            subtitle: panelSubtitle,
            isOn: isExecuting,
            isEnabled: runner.isAvailable && !isExecuting,
            isAvailable: true,
            detail: nil,
            errorMessage: lastErrorMessage
        )
    }

    var settingsPage: PluginSettingsPage? {
        .form(
            description: metadata.defaultDescription,
            sections: [
                PluginSettingsSection(
                    id: "behavior",
                    title: localization.string("settings.behavior.title", defaultValue: "恢复行为"),
                    systemImage: "arrow.clockwise",
                    rows: [
                        PluginSettingsRow(
                            id: ControlID.reopensApplications,
                            title: localization.string(
                                "settings.reopenApps.title",
                                defaultValue: "重新打开应用"
                            ),
                            description: localization.string(
                                "settings.reopenApps.description",
                                defaultValue: "软重启完成后，重新打开执行前正在运行的应用。"
                            ),
                            systemImage: "square.stack.3d.up",
                            isEnabled: !isExecuting,
                            control: .toggle(isOn: reopensApplications)
                        ),
                        PluginSettingsRow(
                            id: ControlID.preservesDockLayout,
                            title: localization.string(
                                "settings.preserveDock.title",
                                defaultValue: "保留 Dock 布局"
                            ),
                            description: localization.string(
                                "settings.preserveDock.description",
                                defaultValue: "重启服务前备份 Dock 设置，并在完成后恢复。"
                            ),
                            systemImage: "dock.rectangle",
                            isEnabled: !isExecuting,
                            control: .toggle(isOn: preservesDockLayout)
                        ),
                    ]
                ),
                PluginSettingsSection(
                    id: "safety",
                    title: localization.string("settings.safety.title", defaultValue: "安全"),
                    systemImage: "exclamationmark.shield",
                    footer: localization.string(
                        "settings.safety.footer",
                        defaultValue: "此操作不会重载内核，也不能修复硬件故障。执行前请保存所有工作。"
                    ),
                    rows: [
                        PluginSettingsRow(
                            id: "confirmation-policy",
                            title: localization.string(
                                "settings.confirmation.title",
                                defaultValue: "运行前始终确认"
                            ),
                            description: localization.string(
                                "settings.confirmation.description",
                                defaultValue: "确认提示无法关闭，也不会在自动化中静默运行。"
                            ),
                            systemImage: "hand.raised.fill",
                            control: .status(
                                text: localization.string("settings.confirmation.status", defaultValue: "已启用"),
                                systemImage: "checkmark.shield.fill",
                                tone: .positive,
                                actionTitle: nil
                            )
                        ),
                    ]
                ),
            ]
        )
    }

    func refresh() {}

    func deactivate(reason _: PluginDeactivationReason) {
        if !isExecuting {
            presenter.dismiss()
            executionTask?.cancel()
            executionTask = nil
        }
    }

    func handleAction(_ action: PluginPanelAction) {
        guard case let .invokeAction(controlID) = action,
              controlID == ControlID.execute,
              !isExecuting
        else {
            return
        }
        presentConfirmation()
    }

    func handleSettingsAction(_ action: PluginSettingsAction) {
        guard !isExecuting,
              case let .setBoolean(controlID, value) = action
        else {
            return
        }

        switch controlID {
        case ControlID.reopensApplications:
            storage.set(value, forKey: StorageKey.reopensApplications)
        case ControlID.preservesDockLayout:
            storage.set(value, forKey: StorageKey.preservesDockLayout)
        default:
            return
        }
        onStateChange?()
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        guard invocation.reference.key.actionID == ActionID.restart else {
            return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionInvalidParameters) }
        }

        return ActionExecutionHandle { [weak self] in
            guard let self else { return .cancelled }
            guard !self.isExecuting else {
                return .failed(message: self.localization.string(
                    "status.running",
                    defaultValue: "系统软重启正在进行"
                ))
            }

            let plan = self.makePlan()
            self.presenter.presentProgress(plan: plan, anchorRect: self.anchorRectProvider?())
            return await self.execute(plan: plan)
        }
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleShortcutAction(id: String) {}

    private var reopensApplications: Bool {
        storage.bool(forKey: StorageKey.reopensApplications)
    }

    private var preservesDockLayout: Bool {
        storage.bool(forKey: StorageKey.preservesDockLayout)
    }

    private var panelSubtitle: String {
        if let currentPhase {
            return phaseText(currentPhase)
        }
        if !runner.isAvailable {
            return localization.string("status.unavailable", defaultValue: "软重启组件不可用")
        }
        return metadata.defaultDescription
    }

    private func presentConfirmation() {
        let plan = makePlan()
        presenter.presentConfirmation(
            plan: plan,
            anchorRect: anchorRectProvider?(),
            onConfirm: { [weak self] in
                guard let self else { return }
                self.executionTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    _ = await self.execute(plan: plan)
                    self.executionTask = nil
                }
            },
            onCancel: {}
        )
    }

    private func makePlan() -> SystemSoftRestartPlan {
        let shouldReopenApplications = reopensApplications
        return SystemSoftRestartPlan(
            applicationURLs: shouldReopenApplications ? applicationURLProvider() : [],
            reopensApplications: shouldReopenApplications,
            preservesDockLayout: preservesDockLayout
        )
    }

    private func execute(plan: SystemSoftRestartPlan) async -> ActionExecutionResult {
        guard !isExecuting else {
            return .failed(message: localization.string("status.running", defaultValue: "系统软重启正在进行"))
        }

        isExecuting = true
        currentPhase = .preparing
        lastErrorMessage = nil
        onStateChange?()

        do {
            let result = try await runner.run(plan: plan) { [weak self] event in
                guard let self else { return }
                self.currentPhase = event.phase
                self.presenter.update(event: event)
                self.onStateChange?()
            }
            isExecuting = false
            currentPhase = nil
            presenter.complete(result: result)
            onStateChange?()
            return .succeeded(message: localization.string(
                "complete.title",
                defaultValue: "系统软重启已完成"
            ))
        } catch {
            let message = error.localizedDescription
            isExecuting = false
            currentPhase = nil
            lastErrorMessage = message
            presenter.fail(message: message)
            onStateChange?()
            return .failed(message: message)
        }
    }

    private func phaseText(_ phase: SystemSoftRestartPhase) -> String {
        switch phase {
        case .preparing:
            return localization.string("progress.preparing", defaultValue: "正在准备软重启…")
        case .backingUpDock:
            return localization.string("progress.backingUpDock", defaultValue: "正在备份 Dock 布局…")
        case .restartingServices:
            return localization.string("progress.restartingServices", defaultValue: "正在重启用户服务…")
        case .waitingForServices:
            return localization.string("progress.waitingForServices", defaultValue: "正在等待系统服务恢复…")
        case .reopeningApplications:
            return localization.string("progress.reopeningApplications", defaultValue: "正在重新打开应用…")
        case .restoringDock:
            return localization.string("progress.restoringDock", defaultValue: "正在恢复 Dock 布局…")
        case .completed:
            return localization.string("progress.completed", defaultValue: "系统软重启已完成。")
        }
    }
}
