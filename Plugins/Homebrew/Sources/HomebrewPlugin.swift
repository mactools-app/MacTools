import AppKit
import Foundation
import SwiftUI
import MacToolsPluginKit

public final class HomebrewPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        HomebrewPluginProvider(context: context)
    }
}

@MainActor
private struct HomebrewPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        let localization = PluginLocalization(bundle: context.resourceBundle)
        let controller = HomebrewController(localization: localization)
        return [HomebrewPlugin(
            controller: controller,
            localization: localization
        )]
    }
}

@MainActor
public final class HomebrewPlugin: MacToolsPlugin, PluginSettingsPresenting, PluginSettingsSearchFocusing, PluginSettingsSearchFocusMetadataProviding, PluginActionProviding {
    public var panelItems: [PluginPanelItem] {
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

    private enum ActionID {
        static let update = "update"
        static let upgradeAll = "upgrade-all"
        static let doctor = "doctor"
        static let cleanup = "cleanup"
    }

    public enum ControlID {
        static let manage = "execute"
    }

    public var metadata: PluginMetadata {
        PluginMetadata(
            id: "homebrew",
            title: localization.string("metadata.title", defaultValue: "Homebrew"),
            iconName: "shippingbox.fill",
            iconTint: Color(nsColor: .systemOrange),
            order: 92,
            defaultDescription: localization.string("metadata.description", defaultValue: "Manage Homebrew packages, repositories, and perform diagnostics")
        )
    }
    public let rowDescriptor: PluginPanelRowDescriptor

    public var onStateChange: (() -> Void)?
    public var requestPermissionGuidance: ((String) -> Void)?
    public var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    public var requestSettingsPresentation: (() -> Void)?

    private let controller: HomebrewController
    private let localization: PluginLocalization
    private let settingsSearchFocusController = HomebrewSettingsSearchFocusController()

    public init(
        controller: HomebrewController,
        localization: PluginLocalization
    ) {
        self.controller = controller
        self.localization = localization
        self.rowDescriptor = PluginPanelRowDescriptor(
            controlStyle: .button,
            menuActionBehavior: .dismissBeforeHandling,
            buttonTitleProvider: { localization.string("panel.action.manage", defaultValue: "管理") }
        )
        

        self.controller.onStateChange = { [weak self] in
            self?.onStateChange?()
        }
    }

    public func activate(context: PluginRuntimeContext) {
        onStateChange?()
    }

    public func deactivate(reason: PluginDeactivationReason) {
        controller.cancelCurrentOperation()
    }

    public func refresh() {
        onStateChange?()
    }

    public var rowState: PluginPanelRowState {
        PluginPanelRowState(
            subtitle: subtitleText,
            isOn: controller.isBusy,
            isEnabled: true,
            isAvailable: true,
            detail: nil,
            errorMessage: controller.isBrewAvailable
                ? nil
                : localization.string("panel.error.brewPathRequired", defaultValue: "需要配置 brew 路径")
        )
    }

    public var permissionRequirements: [PluginPermissionRequirement] { [] }
    public var shortcutDefinitions: [PluginShortcutDefinition] { [] }
    public var actionDefinitions: [ActionDefinition] {
        [
            maintenanceDefinition(
                id: ActionID.update,
                titleKey: "detail.diagnostics.update.title",
                title: "更新软件源",
                descriptionKey: "detail.diagnostics.update.desc",
                description: "同步 Homebrew formula 和 cask 列表。",
                systemImage: "arrow.clockwise.circle.fill"
            ),
            maintenanceDefinition(
                id: ActionID.upgradeAll,
                titleKey: "detail.diagnostics.upgrade.title",
                title: "更新所有包",
                descriptionKey: "detail.diagnostics.upgrade.desc",
                description: "更新当前检测到的过期包。",
                systemImage: "arrow.up.circle.fill",
                risk: .confirmationRequired,
                confirmation: ActionConfirmation(
                    title: localization.string("detail.confirm.upgradeAll.title", defaultValue: "确认更新所有包？"),
                    message: localization.string(
                        "detail.confirm.upgradeAll.message",
                        defaultValue: "将执行 brew upgrade，更新所有可升级的 Homebrew 包。此操作可能修改已安装软件。"
                    ),
                    confirmButtonTitle: localization.string("detail.confirm.upgradeAll.button", defaultValue: "更新全部")
                )
            ),
            maintenanceDefinition(
                id: ActionID.doctor,
                titleKey: "detail.diagnostics.doctor.title",
                title: "运行诊断",
                descriptionKey: "detail.diagnostics.doctor.desc",
                description: "检查环境变量、权限和构建路径。",
                systemImage: "heart.text.square.fill"
            ),
            maintenanceDefinition(
                id: ActionID.cleanup,
                titleKey: "detail.diagnostics.cleanup.title",
                title: "清理缓存",
                descriptionKey: "detail.diagnostics.cleanup.desc",
                description: "移除旧版本下载和缓存。",
                systemImage: "trash.circle.fill",
                risk: .confirmationRequired,
                confirmation: ActionConfirmation(
                    title: localization.string("detail.confirm.cleanup.title", defaultValue: "确认清理 Homebrew 缓存？"),
                    message: localization.string(
                        "detail.confirm.cleanup.message",
                        defaultValue: "将执行 brew cleanup，删除 Homebrew 旧版本和下载缓存。"
                    ),
                    confirmButtonTitle: localization.string("detail.confirm.cleanup.button", defaultValue: "清理")
                )
            ),
        ]
    }

    public func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        guard actionDefinitions.contains(where: { $0.key == reference.key }) else {
            return .unavailable(PluginKitLocalization.actionUnavailable)
        }
        guard controller.isBrewAvailable else {
            return .unavailable(localization.string(
                "panel.error.brewPathRequired",
                defaultValue: "需要配置 brew 路径"
            ))
        }
        return controller.isBusy
            ? .unavailable(controller.currentOperationName)
            : .available
    }

    public func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        guard let command = maintenanceCommand(for: invocation.reference.key.actionID) else {
            return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionUnavailable) }
        }
        let controller = controller
        return ActionExecutionHandle(
            operation: {
                let success = await controller.runMaintenanceAction(name: command.name, args: command.arguments)
                if Task.isCancelled {
                    return .cancelled
                }
                return success
                    ? .succeeded()
                    : .failed(message: controller.logs.last(where: \.isError)?.text ?? PluginKitLocalization.actionUnavailable)
            },
            cancel: {
                controller.cancelCurrentOperation()
            }
        )
    }

    public var settingsPage: PluginSettingsPage? {
        let controller = self.controller
        let localization = self.localization
        return .workspace(description: metadata.defaultDescription, scrolling: .selfManaged) { _ in
            HomebrewDetailView(
                controller: controller,
                localization: localization,
                showsHeader: false,
                contentPadding: 0,
                minimumContentHeight: 480,
                searchFocusController: self.settingsSearchFocusController
            )
        }
    }

    public func focusSettingsSearch() {
        settingsSearchFocusController.requestFocus()
    }

    public var isSettingsSearchAvailable: Bool {
        controller.isBrewAvailable
    }

    public func handleAction(_ action: PluginPanelAction) {
        switch action {
        case let .invokeAction(controlID):
            handleInvoke(controlID: controlID)
        default:
            break
        }
    }

    public func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    public func handlePermissionAction(id: String) {}
    public func handleSettingsAction(_ action: PluginSettingsAction) {}
    public func handleShortcutAction(id: String) {}

    // MARK: - Private

    private var subtitleText: String {
        guard controller.isBrewAvailable else {
            return localization.string("panel.error.brewPathRequired", defaultValue: "需要配置 brew 路径")
        }
        if controller.isBusy {
            return controller.currentOperationName
        }
        return localization.string("panel.subtitle.manage", defaultValue: "管理包、软件源与诊断")
    }

    private func handleInvoke(controlID: String) {
        switch controlID {
        case ControlID.manage:
            requestSettingsPresentation?()
        default:
            break
        }
    }

    private func maintenanceDefinition(
        id: String,
        titleKey: String,
        title: String,
        descriptionKey: String,
        description: String,
        systemImage: String,
        risk: ActionRisk = .safe,
        confirmation: ActionConfirmation? = nil
    ) -> ActionDefinition {
        let localizedTitle = localization.string(titleKey, defaultValue: title)
        return ActionDefinition(
            key: ActionKey(providerID: metadata.id, actionID: id),
            title: localizedTitle,
            description: localization.string(descriptionKey, defaultValue: description),
            keywords: [metadata.title, localizedTitle, "brew", "Homebrew"],
            systemImage: systemImage,
            risk: risk,
            confirmation: confirmation,
            externalInvocationPolicy: .unavailable,
            capabilities: [.automatic, .background, .foregroundInteractive, .cancellable, .reportsProgress],
            executionTimeoutSeconds: 7_200
        )
    }

    private func maintenanceCommand(for actionID: String) -> (name: String, arguments: [String])? {
        switch actionID {
        case ActionID.update:
            return (
                localization.string("operation.updateBrew", defaultValue: "正在更新 Homebrew 源..."),
                ["update"]
            )
        case ActionID.upgradeAll:
            return (
                localization.string("operation.upgradeAll", defaultValue: "正在更新所有包..."),
                ["upgrade"]
            )
        case ActionID.doctor:
            return (
                localization.string("operation.doctor", defaultValue: "正在运行 Homebrew 诊断..."),
                ["doctor"]
            )
        case ActionID.cleanup:
            return (
                localization.string("operation.cleanup", defaultValue: "正在清理 Homebrew 缓存..."),
                ["cleanup"]
            )
        default:
            return nil
        }
    }
}
