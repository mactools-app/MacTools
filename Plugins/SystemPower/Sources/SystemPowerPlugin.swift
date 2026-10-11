import AppKit
import Foundation
import OSLog
import SwiftUI
import MacToolsPluginKit

public final class SystemPowerPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        SystemPowerPluginProvider(context: context)
    }
}

@MainActor
private struct SystemPowerPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [SystemPowerPlugin(localization: PluginLocalization(bundle: context.resourceBundle))]
    }
}

@MainActor
final class SystemPowerPlugin:
    MacToolsPlugin, PluginActionProviding, PluginActionPermissionProviding {
    var panelItems: [PluginPanelItem] {
        return [
            .row(id: "control", initialPlacement: .featurePanel,
                 descriptor: rowDescriptor, state: rowState,
                 action: { [weak self] in self?.handleAction($0) }),
        ]
    }

    static let pluginID = "system-power"

    private enum PermissionID {
        static let automation = "automation"
    }

    var metadata: PluginMetadata {
        PluginMetadata(
            id: Self.pluginID,
            title: localization.string("metadata.title", defaultValue: "电源操作"),
            iconName: "power",
            iconTint: Color(nsColor: .systemRed),
            order: 99,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "让 Mac 睡眠、退出登录、重新启动或关机"
            )
        )
    }
    let rowDescriptor: PluginPanelRowDescriptor

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let localization: PluginLocalization
    private let presentationPreparation: @MainActor @Sendable () -> Void
    private let performOperation: @MainActor @Sendable (SystemPowerOperation) async -> SystemPowerOperationResult
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "SystemPowerPlugin"
    )
    private var isExpanded = false
    private var lastErrorMessage: String?
    private var wasAutomationPermissionDenied = false

    init(
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        presentationPreparation: @escaping @MainActor @Sendable () -> Void = {
            PluginPresentationSafety.prepareForWindowOrdering()
        },
        performOperation: @escaping @MainActor @Sendable (SystemPowerOperation) async -> SystemPowerOperationResult = {
            await SystemPowerController.perform($0)
        }
    ) {
        self.localization = localization
        self.presentationPreparation = presentationPreparation
        self.performOperation = performOperation
        self.rowDescriptor = PluginPanelRowDescriptor(
            controlStyle: .disclosure,
            menuActionBehavior: .keepPresented
        )
    }

    var rowState: PluginPanelRowState {
        PluginPanelRowState(
            subtitle: metadata.defaultDescription,
            isOn: false,
            isEnabled: true,
            isAvailable: true,
            detail: panelDetail,
            errorMessage: lastErrorMessage
        )
    }

    var actionDefinitions: [ActionDefinition] {
        SystemPowerOperation.allCases.map(actionDefinition)
    }

    var permissionRequirements: [PluginPermissionRequirement] {
        [
            PluginPermissionRequirement(
                id: PermissionID.automation,
                kind: .automation,
                title: localization.string(
                    "permission.automation.title",
                    defaultValue: "自动化授权"
                ),
                description: localization.string(
                    "permission.automation.description",
                    defaultValue: "用于显示 macOS 退出登录、重新启动和关机确认。"
                )
            )
        ]
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        guard permissionID == PermissionID.automation else {
            return PluginPermissionState(isGranted: true, footnote: nil)
        }

        if wasAutomationPermissionDenied {
            return PluginPermissionState(
                isGranted: false,
                footnote: localization.string(
                    "permission.automation.deniedFootnote",
                    defaultValue: "前往系统设置 → 隐私与安全性 → 自动化，允许 MacTools 控制系统事件。"
                )
            )
        }

        return PluginPermissionState(
            isGranted: true,
            footnote: localization.string(
                "permission.automation.footnote",
                defaultValue: "macOS 会在首次执行相关操作时请求自动化授权。"
            ),
            statusText: localization.string(
                "permission.automation.status",
                defaultValue: "按需确认"
            ),
            statusSystemImage: "sparkles",
            statusTone: .neutral
        )
    }

    func handlePermissionAction(id: String) {
        guard id == PermissionID.automation,
              let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
              )
        else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func permissionRequirementIDs(for actionKey: ActionKey) -> [String] {
        guard actionKey.providerID == metadata.id,
              let operation = SystemPowerOperation(rawValue: actionKey.actionID),
              operation != .sleep
        else {
            return []
        }
        return [PermissionID.automation]
    }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        operation(for: reference) == nil
            ? .unavailable(PluginKitLocalization.actionUnavailable)
            : .available
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        guard let operation = operation(for: invocation.reference) else {
            return ActionExecutionHandle {
                .failed(message: PluginKitLocalization.actionInvalidParameters)
            }
        }

        return ActionExecutionHandle { [weak self] in
            guard let self else { return .cancelled }
            return await self.execute(operation)
        }
    }

    func handleAction(_ action: PluginPanelAction) {
        switch action {
        case let .setDisclosureExpanded(expanded):
            isExpanded = expanded
            onStateChange?()
        case let .invokeAction(controlID):
            guard let operation = SystemPowerOperation(rawValue: controlID) else {
                return
            }
            Task { @MainActor [weak self] in
                _ = await self?.execute(operation)
            }
        case .setSwitch,
             .setSelection,
             .setNavigationSelection,
             .clearNavigationSelection,
             .setDate,
             .setSlider:
            break
        }
    }

    private var panelDetail: PluginPanelDetail {
        PluginPanelDetail(
            primaryControls: SystemPowerOperation.allCases.map { operation in
                PluginPanelControl(
                    id: operation.rawValue,
                    kind: .actionRow,
                    options: [],
                    selectedOptionID: nil,
                    dateValue: nil,
                    minimumDate: nil,
                    displayedComponents: nil,
                    datePickerStyle: nil,
                    sectionTitle: nil,
                    actionTitle: title(for: operation),
                    actionIconSystemName: iconName(for: operation),
                    actionBehavior: .dismissBeforeHandling,
                    showsLeadingDivider: operation == .logOut,
                    isEnabled: true
                )
            },
            secondaryPanel: nil
        )
    }

    private func actionDefinition(for operation: SystemPowerOperation) -> ActionDefinition {
        let title = title(for: operation)
        let description = description(for: operation)
        return ActionDefinition(
            key: ActionKey(providerID: metadata.id, actionID: operation.rawValue),
            title: title,
            description: description,
            keywords: [title, description, operation.rawValue, "power", "电源"],
            systemImage: iconName(for: operation),
            externalInvocationPolicy: .unavailable,
            capabilities: [.foregroundInteractive],
            concurrencyPolicy: .rejectWhileRunning
        )
    }

    private func operation(for reference: ActionReference) -> SystemPowerOperation? {
        guard reference.key.providerID == metadata.id,
              reference.schemaVersion == 1,
              reference.parameters == .empty
        else {
            return nil
        }
        return SystemPowerOperation(rawValue: reference.key.actionID)
    }

    private func execute(_ operation: SystemPowerOperation) async -> ActionExecutionResult {
        let hadVisibleError = lastErrorMessage != nil
        lastErrorMessage = nil
        presentationPreparation()
        let result = await performOperation(operation)
        switch result {
        case .succeeded:
            let permissionStateChanged = wasAutomationPermissionDenied && operation != .sleep
            if operation != .sleep {
                wasAutomationPermissionDenied = false
            }
            if hadVisibleError || permissionStateChanged {
                onStateChange?()
            }
            logger.info("Requested system power operation=\(operation.rawValue, privacy: .public)")
            return .succeeded()
        case .automationPermissionDenied:
            wasAutomationPermissionDenied = true
            let message = localization.string(
                "error.automationDenied",
                defaultValue: "需要自动化授权，请前往系统设置允许 MacTools 控制系统事件。"
            )
            lastErrorMessage = message
            onStateChange?()
            requestPermissionGuidance?(PermissionID.automation)
            logger.error(
                "System power operation denied by Automation permission operation=\(operation.rawValue, privacy: .public)"
            )
            return .failed(message: message)
        case .failed:
            let message = failureMessage(for: operation)
            lastErrorMessage = message
            onStateChange?()
            logger.error("System power operation failed operation=\(operation.rawValue, privacy: .public)")
            return .failed(message: message)
        }
    }

    private func title(for operation: SystemPowerOperation) -> String {
        switch operation {
        case .sleep:
            localization.string("action.sleep.title", defaultValue: "Mac 睡眠")
        case .logOut:
            localization.string("action.logOut.title", defaultValue: "退出登录…")
        case .restart:
            localization.string("action.restart.title", defaultValue: "重新启动 Mac…")
        case .shutDown:
            localization.string("action.shutDown.title", defaultValue: "将 Mac 关机…")
        }
    }

    private func description(for operation: SystemPowerOperation) -> String {
        switch operation {
        case .sleep:
            localization.string("action.sleep.description", defaultValue: "立即让 Mac 进入睡眠")
        case .logOut:
            localization.string("action.logOut.description", defaultValue: "显示 macOS 退出登录确认")
        case .restart:
            localization.string("action.restart.description", defaultValue: "显示 macOS 重新启动确认")
        case .shutDown:
            localization.string("action.shutDown.description", defaultValue: "显示 macOS 关机确认")
        }
    }

    private func failureMessage(for operation: SystemPowerOperation) -> String {
        switch operation {
        case .sleep:
            localization.string("error.sleep", defaultValue: "无法让 Mac 进入睡眠。")
        case .logOut:
            localization.string("error.logOut", defaultValue: "无法显示退出登录确认。")
        case .restart:
            localization.string("error.restart", defaultValue: "无法显示重新启动确认。")
        case .shutDown:
            localization.string("error.shutDown", defaultValue: "无法显示关机确认。")
        }
    }

    private func iconName(for operation: SystemPowerOperation) -> String {
        switch operation {
        case .sleep:
            "moon.zzz"
        case .logOut:
            "rectangle.portrait.and.arrow.right"
        case .restart:
            "arrow.clockwise"
        case .shutDown:
            "power"
        }
    }
}
